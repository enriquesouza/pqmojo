"""pqmojo.asyncq — libpq's NON-BLOCKING execution path for overlap-friendly callers.

send_query() submits parameterized TEXT and returns immediately;
poll_result(timeout_ms) drives PQconsumeInput/PQisBusy to completion,
waiting on the raw socket through poll(2) up to the given budget:

    send_query(conn, sql, params)
    ... overlap other work / other sockets here ...
    var res = poll_result(conn, 30_000)

One connection carries ONE in-flight statement: poll it to completion
before sending the next on the same socket (libpq forbids overlapping
submits; it has no automatic protocol pipelining). send_query() defensively
drains stale completed results first, so an abandoned-but-finished response
never wedges the next submit with "another command is already in
progress".

While data is unread the connection is BUSY: do not interleave execute().
On timeout the statement is still running server-side and the socket still
holds unread bytes — either call poll_result again with a fresh budget or
close() the connection.

Mojo has no green threads yet; this module is what lets a host event loop
overlap several conns from ONE thread (readiness waiting happens inside
poll_result, cheap and GIL-free). Most call sites should keep plain
execute()/exec_params().
"""

from std.ffi import c_size_t, c_ssize_t
from std.time import perf_counter

from .conn import PgConn
from .ffi import CharPtr, c_free, c_string, external_call, text_of
from .query import PgResult


comptime POLLIN: Int16 = 0x0001


def send_query(mut conn: PgConn, sql: String, params: List[String]) raises:
    """Submit one parameterized statement without blocking for its result.

    Stale completed results from forgotten polls are drained first so the
    submit itself can never fail with "another command already in progress"
    after an abandoned response. Raises immediately when libpq rejects the
    submission (bad state, closed conn).
    """
    _drain_completed(conn)
    var sql_buf = c_string(sql)
    var n = len(params)

    if n == 0:
        var rc = conn.syms.send_query_params(
            conn.handle, sql_buf, Int32(0), Int(0),
            Int(0), Int(0), Int(0), Int32(0)
        )
        c_free(sql_buf)
        if rc == 0:
            raise Error("pqmojo: PQsendQueryParams failed: "
                        + text_of(conn.syms.error_message(conn.handle)))
        return

    var addr_arr = Int(0)
    var bufs = List[CharPtr]()
    addr_arr = Int(external_call["malloc", CharPtr](c_size_t(n * 8)))
    var slots = Pointer[Int64, MutAnyOrigin](unsafe_from_address=addr_arr)
    for i in range(n):
        var b = c_string(params[i])
        bufs.append(b)
        slots[unsafe_offset=i] = Int64(Int(b))

    var rc2 = conn.syms.send_query_params(
        conn.handle, sql_buf, Int32(n), Int(0),
        addr_arr, Int(0), Int(0), Int32(0)
    )
    for i in range(len(bufs)):
        c_free(bufs[i])
    _ = external_call["free", c_ssize_t](
        CharPtr(unsafe_from_address=addr_arr)
    )
    c_free(sql_buf)
    if rc2 == 0:
        raise Error("pqmojo: PQsendQueryParams failed: "
                    + text_of(conn.syms.error_message(conn.handle)))


def _wait_readable(fd: Int32, timeout_ms: Int):
    """poll(2) one fd for readability; EINTR retries internally."""
    var pfd = external_call["malloc", CharPtr](c_size_t(16))
    var i32p = Pointer[Int32, MutAnyOrigin](unsafe_from_address=Int(pfd))
    var i16p = Pointer[Int16, MutAnyOrigin](unsafe_from_address=Int(pfd))
    i32p[unsafe_offset=0] = fd       # .fd
    i16p[unsafe_offset=2] = POLLIN   # .events (bytes 4..5)
    i16p[unsafe_offset=3] = 0        # .revents (bytes 6..7)
    var remaining = timeout_ms
    while True:
        var rc = external_call["poll", Int32](Int(pfd), 1, Int32(remaining))
        if rc > 0:
            break
        if rc == 0:
            break  # budget spent; caller re-checks its deadline
        # rc < 0: EINTR and friends — shrink budget, retry
        remaining = 1
    _ = external_call["free", c_ssize_t](pfd)


def poll_result(mut conn: PgConn, timeout_ms: Int) raises -> PgResult:
    """Next completed result for this connection, waiting up to timeout_ms.

    Results are handed back in submission order, one per call — pipelined
    sends are polled once each. The returned PgResult is status-checked.
    Timing out raises while leaving the query in flight; see the module
    docstring. Polling with nothing pending raises (a send_query() call is
    missing).
    """
    var deadline = Float64(perf_counter()) + Float64(timeout_ms) / 1000.0

    while True:
        if conn.syms.consume_input(conn.handle) == 0:
            raise Error("pqmojo: PQconsumeInput failed: "
                        + text_of(conn.syms.error_message(conn.handle)))
        var ready = conn.syms.is_busy(conn.handle) == 0
        if ready:
            # A result may or may not be pending; getResult disambiguates.
            var probe = conn.syms.get_result(conn.handle)
            if probe != 0:
                var res = _wrap(probe, conn)
                res.check_ok()
                return res^
            # NULL while not busy == nothing was pending at all.
            raise Error(
                "pqmojo: poll_result with no in-flight statement "
                + "(send_query missing?)"
            )
        var fd = Int(conn.syms.socket_fn(conn.handle))
        if fd < 0:
            raise Error("pqmojo: PQsocket returned no descriptor")
        var left_ms = Int(Float64(deadline - Float64(perf_counter())) * 1000.0)
        if left_ms <= 0:
            raise Error(
                "pqmojo: poll_result timed out after "
                + String(timeout_ms) + " ms (query still in flight)"
            )
        _wait_readable(Int32(fd), left_ms)


def _drain_completed(mut conn: PgConn):
    """Quietly clear any fully-received-but-unconsumed results so a new
    submit is always legal. Best effort: never raises."""
    try:
        while True:
            if conn.syms.consume_input(conn.handle) == 0:
                return
            if conn.syms.is_busy(conn.handle) != 0:
                return  # something genuinely in flight; leave it alone
            var extra_addr = conn.syms.get_result(conn.handle)
            if extra_addr == 0:
                return
            var extra = _wrap(extra_addr, conn)
            extra.clear()
    except:
        return


def _wrap(addr: Int, conn: PgConn) -> PgResult:
    """Package a raw PQresult pointer with this conn's bound accessors."""
    return PgResult(
        addr,
        conn.syms.ntuples,
        conn.syms.nfields,
        conn.syms.getvalue,
        conn.syms.getisnull,
        conn.syms.clear,
        conn.syms.result_status,
        conn.syms.result_error_message,
    )


def execute_nonblocking(
    mut conn: PgConn, sql: String, params: List[String]
) raises -> PgResult:
    """send_query + poll_result with a generous budget — the fully-blocking
    convenience built ON the non-blocking path (proves both halves share one
    code path)."""
    send_query(conn, sql, params)
    return poll_result(conn, 600_000)
