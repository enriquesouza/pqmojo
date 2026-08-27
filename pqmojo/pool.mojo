"""pqmojo.pool — a deadpool-style connection pool for fork/post-fork workers.

The Rust developer's deadpool-postgres analog:

    var pool = ConnectionPool(
        PoolConfig("postgres://user@localhost/app", max_size=8)
    )
    var conn = pool.acquire()             # blocks up to acquire_timeout_ms
    var res = execute(conn, sql, params)
    pool.release(conn^)

Guarantees:
  * max_size hard cap — extra acquirers park on a pthread condvar with a
    deadline, so oversubscribed bursts queue instead of erroring.
  * min_idle warmup — connections open eagerly at construction.
  * health-check ping ("SELECT 1") on REUSED connections; a stale socket is
    finished and transparently replaced within the same budget.
  * prepared-statement plan integration (deadpool StatementCache analog):
    register once via prepare_on_acquire([(name, sql), ...]) and every conn
    this pool ever serves — warm, grown, or health-replaced — self-prepares
    before checkout; execute_prepared(conn, name, params) binds by name.
    prepare_all(...) is the point-in-time fan-out variant for explicit
    warmups. Statements are session-local: they die with their socket and
    re-arm automatically through the same epoch markers.
  * safe across OS threads within one process: every operation rides a
    pthread mutex/condvar pair living in malloc'd C memory. Build the pool
    AFTER fork, once per worker, and share it with threads by ADDRESS
    (`Pointer[ConnectionPool](unsafe_from_address=...)`) exactly like mojoka
    states are shared — the fork contract in pqmojo.conn still governs.

Ownership contract: acquire transfers a live PgConn out; `release(conn^)`
moves it back. Handing `conn^` over makes later use a compile error wherever
the compiler can see it — structural protection against driving a returned-
to-idle socket concurrently. A conn whose release() is forgotten stays lent
forever (visible in stats()); the explicit, destructor-free house style is
deliberate — same rule as PgResult.clear(). close() retires the pool for
good: later acquires raise, later releases PQfinish instead of queuing.
"""

from std.ffi import c_size_t, c_ssize_t, external_call
from std.memory import Pointer
from std.time import perf_counter

from .conn import PgConn, connect
from .ffi import CharPtr
from .query import execute
from .stmt import prepare_on, prepare_or_replace_on


comptime ETIMEDOUT: Int32 = 60

comptime CTR_TOTAL: Int = 0
comptime CTR_CLOSED: Int = 1

comptime BUF_BYTES: Int = 128


# ---------------------------------------------------------------------------
# libc pthread primitives — buffers are malloc'd/zero-filled/explicitly
# initialized and reach every thread through raw addresses, because threads
# share the pool itself only by address.
# ---------------------------------------------------------------------------


def _malloc_zero(nbytes: Int) -> Int:
    var p = external_call["malloc", CharPtr](c_size_t(nbytes))
    var bp = Pointer[Byte, MutAnyOrigin](unsafe_from_address=Int(p))
    for i in range(nbytes):
        bp[unsafe_offset=i] = 0
    return Int(p)


def _c_free(addr: Int):
    _ = external_call["free", c_ssize_t](
        CharPtr(unsafe_from_address=addr)
    )


def _mutex_new() raises -> Int:
    var buf = _malloc_zero(BUF_BYTES)
    var rc = external_call["pthread_mutex_init", Int32](
        CharPtr(unsafe_from_address=buf), 0
    )
    if rc != 0:
        raise Error("pqmojo: pthread_mutex_init failed")
    return buf


def _cond_new() raises -> Int:
    var buf = _malloc_zero(BUF_BYTES)
    var rc = external_call["pthread_cond_init", Int32](
        CharPtr(unsafe_from_address=buf), 0
    )
    if rc != 0:
        raise Error("pqmojo: pthread_cond_init failed")
    return buf


def _lock(addr: Int):
    _ = external_call["pthread_mutex_lock", Int32](
        CharPtr(unsafe_from_address=addr)
    )


def _unlock(addr: Int):
    _ = external_call["pthread_mutex_unlock", Int32](
        CharPtr(unsafe_from_address=addr)
    )


def _broadcast(addr: Int):
    _ = external_call["pthread_cond_broadcast", Int32](
        CharPtr(unsafe_from_address=addr)
    )


def _ctr_get(counts_addr: Int, idx: Int) -> Int64:
    var p = Pointer[Int64, MutAnyOrigin](unsafe_from_address=counts_addr)
    return p[unsafe_offset=idx]


def _ctr_set(counts_addr: Int, idx: Int, v: Int64):
    var p = Pointer[Int64, MutAnyOrigin](unsafe_from_address=counts_addr)
    p[unsafe_offset=idx] = v


def _abstime_after_ms(ts_addr: Int, ms: Int):
    """Fill {tv_sec:Int64, tv_nsec:Int64} at ts_addr with wallclock()+ms."""
    var tv_addr = _malloc_zero(16)
    var tv = Pointer[Int64, MutAnyOrigin](unsafe_from_address=tv_addr)
    tv[unsafe_offset=0] = 0
    tv[unsafe_offset=1] = 0
    _ = external_call["gettimeofday", Int32](
        CharPtr(unsafe_from_address=tv_addr), 0
    )
    # timeval = {tv_sec: long, tv_usec: int}; tv_usec sits at byte offset 8.
    var usec32 = Pointer[Int32, MutAnyOrigin](
        unsafe_from_address=tv_addr + 8
    )[unsafe_offset=0]
    var sec = tv[unsafe_offset=0] + Int64(ms // 1000)
    var usec = Int64(usec32) + Int64((ms % 1000) * 1000)
    if usec >= 1000000:
        sec += 1
        usec -= 1000000
    var ts = Pointer[Int64, MutAnyOrigin](unsafe_from_address=ts_addr)
    ts[unsafe_offset=0] = sec
    ts[unsafe_offset=1] = usec * 1000
    _c_free(tv_addr)


def _now_ms() -> Int:
    return Int(Float64(perf_counter()) * 1000.0)


# ---------------------------------------------------------------------------
# gssencmode absorption — port of production pq_connect: on macOS a forked
# worker's first PQconnectdb can die inside libpq's GSS credential probe.
# ---------------------------------------------------------------------------


def gss_safe_dsn(conninfo: String) -> String:
    """conninfo with gssencmode=disable appended unless already present."""
    if conninfo.find("gssencmode") != -1:
        return conninfo
    if (conninfo.find("postgres://") == 0)
        or (conninfo.find("postgresql://") == 0):
        if conninfo.find("?") == -1:
            return conninfo + "?gssencmode=disable"
        return conninfo + "&gssencmode=disable"
    return conninfo + " gssencmode=disable"


def _healthy(conn: PgConn) -> Bool:
    """Non-raising liveness probe: one strict 'SELECT 1' round trip."""
    try:
        var res = execute(conn, "SELECT 1", List[String]())
        var ok = res.rows() >= 0
        res.clear()
        return ok
    except:
        return False


def _copy_plan(
    plan: List[Tuple[String, String]]
) -> List[Tuple[String, String]]:
    """Deep copy of a (name, sql) plan so callers may mutate theirs after."""
    var out = List[Tuple[String, String]](capacity=len(plan))
    for t in plan:
        out.append((t[0], t[1]))
    return out^


def _validate_plan_loud(dsn: String, plan: List[Tuple[String, String]]) raises:
    """PREPARE every entry on a SHORT-LIVED probe connection and raise
    carrying the server's message on bad SQL/ambiguous params.

    Mojo exceptions cannot be re-thrown with their value intact, so pool
    fan-outs would otherwise lose the server's complaint; front-loading a
    throwaway-conn validation pass keeps registration loud while the later
    real fan-outs only ever fail on transient server issues."""
    if len(plan) == 0:
        return
    var probe = connect(gss_safe_dsn(dsn))
    for t in plan:
        prepare_on(probe.handle, probe.syms, t[0], t[1])
    probe.close()


# ---------------------------------------------------------------------------
# config + stats + pool
# ---------------------------------------------------------------------------


struct PoolConfig(Copyable, Movable):
    """deadpool-flavored knobs; constructor args carry these defaults."""

    var url: String
    var max_size: Int
    var min_idle: Int
    var acquire_timeout_ms: Int
    var health_check: Bool
    var macos_gss_safe: Bool

    def __init__(
        out self,
        url: String,
        max_size: Int = 8,
        min_idle: Int = 1,
        acquire_timeout_ms: Int = 2000,
        health_check: Bool = True,
        macos_gss_safe: Bool = True,
    ):
        self.url = String(url)
        var m = max_size
        if m < 1:
            m = 1
        var w = min_idle
        if w < 0:
            w = 0
        if w > m:
            w = m
        self.max_size = m
        self.min_idle = w
        self.acquire_timeout_ms = acquire_timeout_ms
        self.health_check = health_check
        self.macos_gss_safe = macos_gss_safe


struct PoolStats(Copyable, Movable):
    """Instantaneous occupancy snapshot."""

    var idle: Int
    var in_use: Int
    var total_open: Int

    def __init__(out self, idle: Int, in_use: Int, total_open: Int):
        self.idle = idle
        self.in_use = in_use
        self.total_open = total_open


struct ConnectionPool(Movable):
    """Build one per worker process after fork; share with threads by
    address. Not Copyable — copying would fork the idle queue."""

    var cfg: PoolConfig
    var dsn: String          # effective (gss-adjusted) conninfo
    var lock_addr: Int       # malloc'd pthread_mutex_t
    var cond_addr: Int       # malloc'd pthread_cond_t
    var ts_addr: Int         # malloc'd 16B timespec scratch
    var counts_addr: Int     # malloc'd {total_open, closed}
    var idle: List[PgConn]
    var plan: List[Tuple[String, String]]   # (name, sql) prepared on checkout
    var plan_epoch: Int      # bumps when a new plan registers

    def __init__(out self, cfg: PoolConfig) raises:
        self.cfg = cfg.copy()
        self.dsn = (
            gss_safe_dsn(self.cfg.url) if self.cfg.macos_gss_safe
            else String(self.cfg.url)
        )
        self.lock_addr = _mutex_new()
        self.cond_addr = _cond_new()
        self.ts_addr = _malloc_zero(16)
        self.counts_addr = _malloc_zero(16)
        self.idle = List[PgConn]()
        self.plan = List[Tuple[String, String]]()
        self.plan_epoch = 0
        for _ in range(self.cfg.min_idle):
            var c = connect(self.dsn)
            self.idle.append(c^)
        _ctr_set(self.counts_addr, CTR_TOTAL, Int64(len(self.idle)))

    # -- internal helpers --------------------------------------------------

    def _is_closed(self) -> Bool:
        return _ctr_get(self.counts_addr, CTR_CLOSED) != 0

    def _total(self) -> Int:
        return Int(_ctr_get(self.counts_addr, CTR_TOTAL))

    def _bump_total(self, delta: Int64):
        _ctr_set(
            self.counts_addr,
            CTR_TOTAL,
            _ctr_get(self.counts_addr, CTR_TOTAL) + delta,
        )

    def _park(mut self, deadline_ms: Int) raises -> Bool:
        """Wait on the condvar until broadcast or deadline (caller holds the
        lock; returns still holding it). False means time is up."""
        var left = deadline_ms - _now_ms()
        while left > 0:
            _abstime_after_ms(self.ts_addr, left)
            var rc = external_call["pthread_cond_timedwait", Int32](
                CharPtr(unsafe_from_address=self.cond_addr),
                CharPtr(unsafe_from_address=self.lock_addr),
                CharPtr(unsafe_from_address=self.ts_addr),
            )
            if rc == ETIMEDOUT:
                break
            if rc != 0:
                _unlock(self.lock_addr)
                raise Error("pqmojo: pthread_cond_timedwait failed")
            left = deadline_ms - _now_ms()
        return left > 0

    # -- prepared-statement plan integration -------------------------------

    def prepare_on_acquire(mut self, plan: List[Tuple[String, String]]) raises:
        """Register the ROLLING checkout plan and arm every pooled conn.

        The registered (name, sql) pairs are prepared automatically on every
        freshly-built or health-replaced connection during acquire() — the
        deadpool-postgres StatementCache analog. This single call also
        eagerly prepares the whole plan across all conns idle RIGHT NOW and
        on a temporary probe conn validates the SQL loudly first: bad SQL
        fails at setup with a named error, not on some later hot call.
        Arming replaces deliberately (internal DEALLOCATE + re-PREPARE), so
        duplicates never wedge it and re-registering bumps the epoch so
        every conn top-ups to the new plan on its next checkout.
        """
        var stored = _copy_plan(plan)
        _validate_plan_loud(self.dsn, stored)

        _lock(self.lock_addr)
        self.plan = List[Tuple[String, String]]()
        for t in stored:
            self.plan.append((t[0], t[1]))
        self.plan_epoch += 1
        var bumped = self.plan_epoch
        var armed = True
        var seen = 0
        var want = len(self.idle)
        while seen < want:
            var c = self.idle.pop()
            for t in stored:
                var ok = True
                try:
                    prepare_or_replace_on(c.handle, c.syms, t[0], t[1])
                except:
                    ok = False
                if not ok:
                    armed = False
                    break
            if armed:
                c.prepared_epoch = bumped
            self.idle.append(c^)
            seen += 1
        _unlock(self.lock_addr)
        if not armed:
            raise Error(
                "pqmojo: pool could not arm the statement plan on idle"
                + " conns (server issue mid-fan-out); unmarked conns retry"
                + " their top-up at next checkout"
            )

    def prepare_all(mut self, plan: List[Tuple[String, String]]) raises -> Int:
        """One-shot fan-out: PREPARE every (name, sql) pair on EVERY conn
        idle right now; returns how many conns were prepared.

        The post-fork lazy-warmup helper — call once after building the
        worker pool. Purely point-in-time by design: it registers NO policy,
        so conns grown or health-replaced later do NOT inherit these
        statements; combine with prepare_on_acquire(same plan) when rolling
        coverage is wanted (arming is idempotent via internal DEALLOCATE +
re-PREPARE). Zero idle conns returns 0
        (everything was checked out — race window). Bad SQL is rejected by
        the loud validation pass before any fan-out work starts.
        """
        var stored = _copy_plan(plan)
        _validate_plan_loud(self.dsn, stored)

        _lock(self.lock_addr)
        var seen = 0
        var want = len(self.idle)
        while seen < want:
            var c = self.idle.pop()
            for t in stored:
                prepare_or_replace_on(c.handle, c.syms, t[0], t[1])
            self.idle.append(c^)
            seen += 1
        _unlock(self.lock_addr)
        return want

    def _ensure_prepared(mut self, mut c: PgConn) raises:
        """Top-up the registered plan on a JUST-CHECKED-OUT conn (caller
        owns it exclusively; the pool lock is NOT held while the round trips
        run). No-op when no plan is registered or the conn already sits at
        the current epoch; health-replaced and newly-grown conns start at
        epoch 0, so replacements self-prepare automatically.

        On failure this raises carrying the server's message while leaving
        the conn open-but-unmarked; callers finish it, release its slot, and
        loop for a replacement within the same budget."""
        _lock(self.lock_addr)
        var need = self.plan_epoch != 0 and c.prepared_epoch != self.plan_epoch
        var copied = List[Tuple[String, String]]()
        if need:
            for t in self.plan:
                copied.append((t[0], t[1]))
        var epoch_target = self.plan_epoch
        _unlock(self.lock_addr)

        if not need:
            return
        for t in copied:
            prepare_or_replace_on(c.handle, c.syms, t[0], t[1])
        c.prepared_epoch = epoch_target

    def acquire(mut self, timeout_ms: Int = -1) raises -> PgConn:
        """Check a healthy conn out; park up to timeout when saturated.

        timeout_ms < 0 falls back to PoolConfig.acquire_timeout_ms. Raises
        when opening a NEW conn fails (carrying the dsn), on deadline expiry
        while others hold every slot, and after close().
        """
        var budget = self.cfg.acquire_timeout_ms
        if timeout_ms >= 0:
            budget = timeout_ms
        var deadline = _now_ms() + budget

        while True:
            if self._is_closed():
                raise Error("pqmojo: pool is closed")

            _lock(self.lock_addr)
            # 1) reuse an idle conn
            if len(self.idle) > 0:
                var c = self.idle.pop()
                _unlock(self.lock_addr)
                if self.cfg.health_check and not _healthy(c):
                    c.close()
                    _lock(self.lock_addr)
                    self._bump_total(Int64(-1))
                    _unlock(self.lock_addr)
                    continue  # loop replaces it within the same budget
                var up = True
                try:
                    self._ensure_prepared(c)
                except:
                    up = False   # failure carries the server complaint up
                if not up:
                    c.close()
                    _lock(self.lock_addr)
                    self._bump_total(Int64(-1))
                    _unlock(self.lock_addr)
                    continue     # replacement within the same budget
                return c^
            # 2) grow toward max_size (slot taken inside this same critical
            #    section so competing threads cannot overshoot the cap)
            if self._total() < self.cfg.max_size:
                self._bump_total(1)
                _unlock(self.lock_addr)
                return self._open_and_arm()
            # 3) saturated: park until someone releases or time runs out
            if deadline - _now_ms() <= 0:
                _unlock(self.lock_addr)
                break
            var woke_in_time = self._park(deadline)
            _unlock(self.lock_addr)
            if not woke_in_time:
                break
            # loop re-checks all predicates from the top

        raise Error(
            "pqmojo: pool.acquire timed out after " + String(budget)
            + " ms (max_size " + String(self.cfg.max_size) + ")"
        )

    def _open_and_arm(mut self) raises -> PgConn:
        """Open one fresh backend under an ALREADY-TAKEN slot and hand it
        out plan-armed. Restores counts and wakes waiters before raising;
        Mojo exceptions carry no catchable value, so connect vs top-up
        failure can only be told apart via boxed state."""
        var box = List[PgConn]()
        var connected = True
        try:
            var c = connect(self.dsn)
            box.append(c^)
        except:
            connected = False
        if not connected:
            _lock(self.lock_addr)
            self._bump_total(Int64(-1))
            _broadcast(self.cond_addr)
            _unlock(self.lock_addr)
            raise Error(
                "pqmojo: pool could not open a connection for "
                + self.dsn
            )
        var nc = box.pop()
        var up = True
        try:
            self._ensure_prepared(nc)
        except:
            up = False
        if not up:
            nc.close()
            _lock(self.lock_addr)
            self._bump_total(Int64(-1))
            _broadcast(self.cond_addr)
            _unlock(self.lock_addr)
            raise Error(
                "pqmojo: pool could not arm the statement plan on a fresh"
                + " connection; slot released, retry the acquire"
            )
        return nc^

    def release(mut self, var conn: PgConn):
        """Move a conn back to the idle queue: `pool.release(conn^)`.

        After close(), releases PQfinish the conn instead of queuing it.
        Single-release is the caller's structural obligation (see module
        docstring).
        """
        _lock(self.lock_addr)
        if self._is_closed():
            _unlock(self.lock_addr)
            conn.close()
            return
        self.idle.append(conn^)
        _unlock(self.lock_addr)
        _broadcast(self.cond_addr)

    def stats(self) -> PoolStats:
        """Occupancy snapshot; cheap enough for dashboards."""
        var idle_n = 0
        var total_n = 0
        _lock(self.lock_addr)
        idle_n = len(self.idle)
        total_n = self._total()
        _unlock(self.lock_addr)
        return PoolStats(idle_n, total_n - idle_n, total_n)

    def close(mut self):
        """Retire the pool permanently. Idle conns PQfinish here."""
        _lock(self.lock_addr)
        if self._is_closed():
            _unlock(self.lock_addr)
            return
        _ctr_set(self.counts_addr, CTR_CLOSED, 1)
        var dying = List[PgConn]()
        while len(self.idle) > 0:
            dying.append(self.idle.pop())
        _unlock(self.lock_addr)
        while len(dying) > 0:
            var c = dying.pop()
            c.close()
