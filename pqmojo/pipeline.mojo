"""pqmojo.pipeline — OVERLAP: keep K prepared queries in flight from ONE
thread across K pooled connections, poll(2)-multiplexed.

GO and RUST multiplex concurrent DB ops through async runtimes; Mojo has no
async runtime, but overlap does not need one: it needs K sockets with work
in flight and a readiness-driven collector. This module is that collector.

    var pipe = pool.checkout_pipeline(2)          # 2 plan-armed conns
    var a = pipe.submit("details", [id_a])        # request id 0, in flight
    var b = pipe.submit("details", [id_b])        # request id 1, in flight
    var first = pipe.collect()                    # WHICHEVER finishes first
    var second = pipe.collect()
    first.result.col_text(0, 1)                   # status-checked PgResult
    ...
    pool.release_pipeline(pipe^)                  # drain + return conns

The one-liner shape:

    var rs = pool.execute_batch("details", jobs, 2)   # submission-ordered

Threading model (honest version): this is a SINGLE-THREAD multiplexer, not
a worker thread. Every libpq call happens on the owning thread, one
connection at a time — libpq's thread-safety rule is satisfied trivially
and there is no shared mutable state to lock. A route worker overlaps DB
wait across K connections (and the server parallelizes behind them); it
does not run Mojo code "while" one query runs — submit/do-own-work/collect
on a single conn is what send_query/poll_result in pqmojo.asyncq offer.

Mechanics: submit() Bind/Executes (PQsendQueryPrepared) on the next
round-robin connection with a free slot and returns a pipeline-wide
request id. collect() poll(2)s ALL in-flight fds AT ONCE, PQconsumeInputs
every ready socket, and the first socket that reaches !PQisBusy yields its
PQgetResult wrapped in a status-checked PgResult tagged with the request id
and serving slot. Results per connection arrive in that connection's
submission order (protocol guarantee), so request ids pair results with
requests deterministically even though COMPLETION order is arbitrary.

Window contract: K slots = K simultaneous in-flight statements, one per
connection (libpq forbids overlapping submits on one socket — the window
never violates this). submit() raises once every slot is busy — collect()
to free a slot. collect() with nothing in flight raises. On collect
timeout the queries keep running server-side: either collect() again with
a fresh budget or give the pipeline back — release_pipeline()/drain()
recycles fully-drained conns and CLOSES any conn with a still-running
query (pool health checks reseal closed slots automatically).

The pipeline owns its K connections (checked out from the pool or handed
in directly); like PgConn it is Movable, never Copyable, and not
thread-safe — one pipeline per worker thread, built AFTER fork.
"""

from std.ffi import c_int, c_size_t, c_ssize_t, external_call
from std.memory import Pointer
from std.time import perf_counter

from .asyncq import send_prepared, send_prepared_binary
from .conn import PgConn
from .ffi import (
    CharPtr,
    PGRES_COMMAND_OK,
    PGRES_EMPTY_QUERY,
    PGRES_TUPLES_OK,
    PgSymbols,
    text_of,
)
from .result import PgResult, _first_line


comptime POLLIN: Int16 = 0x0001
comptime POLLERR: Int16 = 0x0008
comptime POLLHUP: Int16 = 0x0010
comptime POLLNVAL: Int16 = 0x0020

comptime MAX_PIPELINE_SLOTS: Int = 64


def _wrap_on(addr: Int, syms: PgSymbols) -> PgResult:
    """Package a raw PQresult pointer with this conn's bound accessors."""
    return PgResult(
        addr,
        syms.ntuples,
        syms.nfields,
        syms.getvalue,
        syms.getisnull,
        syms.getlength,
        syms.clear,
        syms.result_status,
        syms.result_error_message,
    )


def _now_ms() -> Int:
    return Int(Float64(perf_counter()) * 1000.0)


def _extract_at(mut lst: List[PgResult], p: Int) -> PgResult:
    """Move the element at position p out of lst, preserving every other
    element's position (tail pops + push-back). O(len - p); batch sizes
    here are small, so the constant wins over anything cleverer."""
    var tmp = List[PgResult]()
    while len(lst) - 1 > p:
        tmp.append(lst.pop())
    var r = lst.pop()
    while len(tmp) > 0:
        lst.append(tmp.pop())
    return r^


struct PipelineResult(Movable):
    """One collect() outcome: a status-checked result plus its identity.

    `request_id` is the value submit() returned for THIS result — the join
    key when completion order differs from submission order. `slot` is the
    connection index (0..k-1) inside the pipeline that served it. Use the
    result IN PLACE (result.col_i64(...)); it cannot be moved out of the
    wrapper, and clear() it when done, house style.
    """

    var request_id: Int
    var slot: Int
    var result: PgResult

    def __init__(out self, request_id: Int, slot: Int, var result: PgResult):
        self.request_id = request_id
        self.slot = slot
        self.result = result^


struct StmtPipeline(Movable):
    """K connections driven as one readiness-multiplexed window.

    Build with `pool.checkout_pipeline(k)` (plan-armed pool conns) or
    `StmtPipeline(conns^)` (your own conns). Not Copyable, not
    thread-safe; one owner thread after fork. Give conns back with
    `pool.release_pipeline(pipe^)` — or `pipe.drain()` to reclaim them for
    manual close/release.
    """

    var k: Int                     # slot count (fixed at construction)
    var conns: List[PgConn]
    var fds: List[Int32]           # cached per-conn descriptor
    var pfds_addr: Int             # malloc'd compact pollfd scratch (k*8 B)
    var pending: List[List[Int]]   # per-slot in-flight request ids (FIFO)
    var heads: List[Int]           # per-slot FIFO front index
    var ready: List[Bool]          # consumed + !isBusy, result not yet taken
    var cursor: Int                # round-robin submit position
    var next_id: Int               # pipeline-wide request id counter
    var outstanding: Int           # total submissions awaiting collect()

    def __init__(out self, var conns: List[PgConn]) raises:
        self.k = len(conns)
        if self.k < 1:
            raise Error("pqmojo: StmtPipeline needs at least one connection")
        if self.k > MAX_PIPELINE_SLOTS:
            raise Error(
                "pqmojo: StmtPipeline window capped at "
                + String(MAX_PIPELINE_SLOTS) + " slots (got "
                + String(self.k) + ")"
            )
        self.conns = conns^
        self.fds = List[Int32](capacity=self.k)
        self.pending = List[List[Int]](capacity=self.k)
        self.heads = List[Int](capacity=self.k)
        self.ready = List[Bool](capacity=self.k)
        for i in range(self.k):
            var fd = self.conns[i].syms.socket_fn(self.conns[i].handle)
            if fd < 0:
                raise Error(
                    "pqmojo: pipeline conn "
                    + String(i) + " has no usable descriptor"
                )
            self.fds.append(fd)
            self.pending.append(List[Int]())
            self.heads.append(0)
            self.ready.append(False)
        self.pfds_addr = Int(external_call["malloc", CharPtr](
            c_size_t(self.k * 8)   # darwin pollfd = 8 bytes
        ))
        self.cursor = 0
        self.next_id = 0
        self.outstanding = 0

    # -- observability -----------------------------------------------------

    def slots(self) -> Int:
        """Window size k (one in-flight statement per slot)."""
        return self.k

    def in_flight(self) -> Int:
        """Submissions currently awaiting collect()."""
        return self.outstanding

    # -- submission --------------------------------------------------------

    def submit(mut self, name: String, params: List[String]) raises -> Int:
        """Bind/Execute a prepared statement on the next free slot, round
        robin; returns the pipeline-wide request id for collect() matching.

        Raises when the whole window is busy (collect first to free a slot)
        or when libpq rejects the submit. The ONE-in-flight-per-conn libpq
        rule is structural here: a slot is handed out only when its conn
        carries nothing in flight.
        """
        var slot = self._free_slot()
        if slot == -1:
            raise Error(
                "pqmojo: pipeline window full ("
                + String(self.k) + " in flight) — collect() first"
            )
        var rid = self.next_id
        send_prepared(self.conns[slot], name, params)
        self.next_id += 1
        self.outstanding += 1
        self.pending[slot].append(rid)
        self.cursor = (slot + 1) % self.k
        return rid

    def submit_binary(mut self, name: String, params: List[String]) raises -> Int:
        """submit() with results requested in Postgres BINARY format.

        Params ride TEXT identically (paramFormats untouched); only the
        resultFormat flag flips to 1, so the returned PgResult must be read
        through the bin_* accessors. Same window contract, request ids,
        collect() path and strict error behavior as submit().
        """
        var slot = self._free_slot()
        if slot == -1:
            raise Error(
                "pqmojo: pipeline window full ("
                + String(self.k) + " in flight) — collect() first"
            )
        var rid = self.next_id
        send_prepared_binary(self.conns[slot], name, params)
        self.next_id += 1
        self.outstanding += 1
        self.pending[slot].append(rid)
        self.cursor = (slot + 1) % self.k
        return rid

    def _free_slot(self) -> Int:
        var scanned = 0
        while scanned < self.k:
            var s = (self.cursor + scanned) % self.k
            if self.heads[s] == len(self.pending[s]):
                return s
            scanned += 1
        return -1

    # -- collection --------------------------------------------------------

    def collect(mut self, timeout_ms: Int = 30_000) raises -> PipelineResult:
        """Next completed result, poll(2)-multiplexed across ALL in-flight
        connections; completion order (arbitrary), identity attached.

        Raises on SQL errors (strict), socket trouble, or deadline expiry.
        On timeout the queries keep running server-side — collect() again
        with a fresh budget or release the pipeline (wedged conns close).
        Raises when nothing is in flight (a submit is missing).
        """
        var results = List[PgResult]()
        var rids = List[Int]()
        var slot_list = List[Int]()
        self._collect_into(results, rids, slot_list, timeout_ms)
        var r = results.pop()
        var rid = rids.pop()
        var slot = slot_list.pop()
        return PipelineResult(rid, slot, r^)

    def _collect_into(
        mut self,
        mut results: List[PgResult],
        mut rids: List[Int],
        mut slots: List[Int],
        timeout_ms: Int,
    ) raises:
        """Collect ONE completion, appending (result, request_id, slot)
        into the caller's lists. The whole readiness loop lives here so
        batch collection never moves results through struct fields.
        """
        if self.outstanding == 0:
            raise Error(
                "pqmojo: collect with nothing in flight (submit first)"
            )
        var deadline = _now_ms() + timeout_ms
        while True:
            var s = self._first_ready()
            if s != -1:
                self._serve_into(s, results, rids, slots)
                return
            var remaining = deadline - _now_ms()
            if remaining <= 0:
                raise Error(
                    "pqmojo: pipeline collect timed out after "
                    + String(timeout_ms) + " ms (queries still in flight)"
                )
            _ = self._poll_round(remaining)

    def _first_ready(mut self) -> Int:
        for s in range(self.k):
            if self.ready[s] and self.heads[s] < len(self.pending[s]):
                return s
        return -1

    def _serve_into(
        mut self,
        slot: Int,
        mut results: List[PgResult],
        mut rids: List[Int],
        mut slots: List[Int],
    ) raises:
        """Take the finished PQresult from a ready slot (FIFO front)."""
        var syms = self.conns[slot].syms.copy()
        var h = self.conns[slot].handle
        var addr = syms.get_result(h)
        var rid = self.pending[slot][self.heads[slot]]
        if addr == 0:
            # Ready flag promised a result; bookkeeping stays consistent
            # for the drain path, but this is a libpq contract break.
            self.ready[slot] = False
            self._drop_front(slot)
            self.outstanding -= 1
            raise Error(
                "pqmojo: pipeline slot " + String(slot)
                + " reported ready but PQgetResult returned NULL"
            )
        var r = _wrap_on(addr, syms)
        var st = r.status()
        var ok = (
            st == PGRES_COMMAND_OK or st == PGRES_TUPLES_OK
            or st == PGRES_EMPTY_QUERY
        )
        var msg = r.error_message()
        self.ready[slot] = False
        self._drop_front(slot)
        self.outstanding -= 1
        if not ok:
            r.clear()
            if msg.byte_length() == 0:
                msg = String("PQresultStatus " + String(st))
            raise Error("pqmojo: pipeline query failed: " + _first_line(msg))
        results.append(r^)
        rids.append(rid)
        slots.append(slot)

    def _drop_front(mut self, slot: Int):
        """Advance the per-slot FIFO; compact when the front gets long."""
        self.heads[slot] += 1
        if self.heads[slot] >= len(self.pending[slot]):
            self.pending[slot] = List[Int]()
            self.heads[slot] = 0
        elif self.heads[slot] >= 4096:
            var fresh = List[Int](
                capacity=len(self.pending[slot]) - self.heads[slot]
            )
            var i = self.heads[slot]
            while i < len(self.pending[slot]):
                fresh.append(self.pending[slot][i])
                i += 1
            self.pending[slot] = fresh^
            self.heads[slot] = 0

    def _poll_round(mut self, budget_ms: Int) raises -> Bool:
        """poll(2) every in-flight fd at once; PQconsumeInput each ready
        socket; mark slots that reached a completed result. Returns whether
        any fd fired (partial-data wakes stay in the collect loop)."""
        var active = List[Int]()
        for s in range(self.k):
            if self.heads[s] < len(self.pending[s]):
                active.append(s)
        if len(active) == 0:
            return False
        var i32p = Pointer[Int32, MutAnyOrigin](unsafe_from_address=self.pfds_addr)
        var i16p = Pointer[Int16, MutAnyOrigin](unsafe_from_address=self.pfds_addr)
        for j in range(len(active)):
            var s = active[j]
            i32p[unsafe_offset=2 * j + 0] = self.fds[s]   # .fd (stride 8B)
            i16p[unsafe_offset=4 * j + 2] = POLLIN        # .events
            i16p[unsafe_offset=4 * j + 3] = 0             # .revents
        var n = len(active)
        var rc = external_call["poll", c_int](self.pfds_addr, c_int(n), c_int(budget_ms))
        if rc < 0:
            raise Error("pqmojo: poll(2) failed in pipeline collect")
        if rc == 0:
            return False
        var fired = False
        for j in range(n):
            var s = active[j]
            var rev = i16p[unsafe_offset=4 * j + 3]
            if rev == 0:
                continue
            if (rev & (POLLNVAL | POLLERR | POLLHUP)) != 0 and (rev & POLLIN) == 0:
                raise Error(
                    "pqmojo: pipeline slot " + String(s)
                    + " socket error (revents " + String(Int(rev)) + ")"
                )
            var syms = self.conns[s].syms.copy()
            var h = self.conns[s].handle
            if syms.consume_input(h) == 0:
                raise Error(
                    "pqmojo: pipeline slot " + String(s)
                    + " PQconsumeInput failed: "
                    + text_of(syms.error_message(h))
                )
            fired = True
            if syms.is_busy(h) == 0:
                self.ready[s] = True
        return fired

    # -- batch -------------------------------------------------------------

    def execute_batch(
        mut self, name: String, jobs: List[List[String]], timeout_ms: Int = 60_000
    ) raises -> List[PgResult]:
        """Submit M prepared jobs round-robin through the window and return
        their results in SUBMISSION order (request ids re-sort completion
        order). Strict: the first SQL error raises.

        This is the whole-overlap one-liner: M identical-shape lookups ride
        k sockets; aggregate throughput scales toward the server ceiling
        while the caller blocks once, at the end. Budget covers the WHOLE
        batch (submission + collection).
        """
        var m = len(jobs)
        var completions = List[PgResult]()
        var ids = List[Int]()
        var slot_ids = List[Int]()
        var submitted = 0
        var deadline = _now_ms() + timeout_ms
        while len(completions) < m:
            while submitted < m and self._free_slot() != -1:
                _ = self.submit(name, jobs[submitted])
                submitted += 1
            var left = deadline - _now_ms()
            if left <= 0:
                raise Error(
                    "pqmojo: execute_batch timed out after "
                    + String(timeout_ms) + " ms with "
                    + String(m - len(completions)) + " results pending"
                )
            self._collect_into(completions, ids, slot_ids, left)
        # completion order -> submission order: select each request id in
        # turn (completion positions keep their indices; served slots are
        # flagged, not removed) and extract via tail pops.
        var ordered = List[PgResult](capacity=m)
        var taken = List[Bool](capacity=m)
        for _ in range(m):
            taken.append(False)
        for j in range(m):
            var p = 0
            while taken[p] or ids[p] != j:
                p += 1
            taken[p] = True
            ordered.append(_extract_at(completions, p))
        return ordered^

    # -- teardown ----------------------------------------------------------

    def drain(mut self) -> List[PgConn]:
        """Best-effort recycle path: quietly collect any fully-received
        results, CLOSE any conn whose query is still genuinely in flight,
        reset bookkeeping, and hand back every conn (closed or not).

        Closed conns are safe to pool.release(): the pool's health check
        fails them once and transparently replaces the slot within budget.
        """
        for s in range(self.k):
            var wedged = self.heads[s] < len(self.pending[s])
            if wedged:
                wedged = not self._quiet_drain(s)
            if wedged:
                self.conns[s].close()
            self.pending[s] = List[Int]()
            self.heads[s] = 0
            self.ready[s] = False
        self.outstanding = 0
        self.cursor = 0
        self.next_id = 0
        var out = List[PgConn](capacity=self.k)
        while len(self.conns) > 0:
            out.append(self.conns.pop())
        self.conns = List[PgConn]()
        return out^

    def _quiet_drain(mut self, slot: Int) -> Bool:
        """Consume everything already flowing on this slot; False when a
        query is still running server-side (conn must close). Never raises.
        """
        var syms = self.conns[slot].syms.copy()
        var h = self.conns[slot].handle
        while self.heads[slot] < len(self.pending[slot]):
            try:
                if syms.consume_input(h) == 0:
                    return False
                if syms.is_busy(h) != 0:
                    return False   # server still working; socket must close
                var addr = syms.get_result(h)
                if addr == 0:
                    return False   # contract break; play safe, close
                var r = _wrap_on(addr, syms)
                r.clear()
                self._drop_front(slot)
                self.outstanding -= 1
            except:
                return False
        return True
