"""Prepared-statement STRESS: fork()ed workers hammer pooled conns that
carry registered statement plans — every checkout binds by NAME, SELECT-only,
and every worker exits nonzero on any failure.

Each forked worker builds its OWN pool AFTER fork (the fork contract) with a
plan mixing a details-shaped point lookup and an aggregate; strict result
checks prove server-side plans survive real concurrent checkout churn
across processes.

Run: pixi run mojo run -I . tests/test_prepared_stress.mojo
"""

from std.ffi import c_size_t, external_call
from std.memory import Pointer

from tests.common import DSN, check
from tests.fixture import setup_fixture, teardown_fixture

from pqmojo import (
    ConnectionPool,
    PoolConfig,
    connect,
    execute,
    execute_prepared,
    format_i64,
)
from pqmojo.ffi import CharPtr


comptime WORKERS = 8
comptime ITER_PER_WORKER = 60




def build_plan() -> List[Tuple[String, String]]:
    var out = List[Tuple[String, String]]()
    out.append((
        "pq_stress_details",
        "SELECT id, title FROM pqmojo_test_items WHERE id = $1 LIMIT 1",
    ))
    out.append((
        "pq_stress_count",
        "SELECT count(*)::int8 AS n FROM pqmojo_test_items WHERE is_active",
    ))
    return out^


def _shared_zeroed(nbytes: Int) -> Int:
    """MAP_SHARED|MAP_ANON zero-filled page(s): unlike malloc'd memory this
    stays SHARED with fork()ed children instead of copy-on-write, so their
    completion writes are visible to the parent after waitpid."""
    comptime PROT_READ_WRITE: Int32 = 3
    comptime MAP_SHARED: Int32 = 1
    comptime MAP_ANON: Int32 = 4096
    var p = external_call["mmap", Int](
        Int(0), nbytes, PROT_READ_WRITE,
        MAP_SHARED | MAP_ANON, Int32(-1), Int32(0), Int64(0)
    )
    var bp = Pointer[Byte, MutAnyOrigin](unsafe_from_address=p)
    for i in range(nbytes):
        bp[unsafe_offset=i] = 0
    return p


def hammer(
    dsn: String, iters: Int, seed: Int, done_slot_addr: Int
) raises -> Int:
    """Churn checkouts binding prepared statements by name; zero-tolerance."""
    var failures = 0
    # NO raw connect() here: post-fork raw connects ride libpq's GSS probe,
    # whose Heimdal/xpc state is exactly what macOS kills forked children
    # for (sig 9). The pool's gssencmode=disable DSN sidesteps it — same
    # reason every other fleet in this suite only ever drives pooled conns.
    var pool = ConnectionPool(PoolConfig(dsn, max_size=3, min_idle=1))
    pool.prepare_on_acquire(build_plan())

    var item_id: Int64 = 0
    var boot_ok = True
    var boot = pool.acquire()
    try:
        var idr = execute(boot,
                          "SELECT id FROM pqmojo_test_items ORDER BY id LIMIT 1",
                          [])
        check(idr.rows() == 1, "worker boot query saw the fixture table")
        item_id = idr.col_i64(0, 0)
        idr.clear()
    except:
        boot_ok = False
    pool.release(boot^)   # ALWAYS back, clean or dirty
    check(boot_ok, "worker boot round trip")

    for i in range(iters):
        try:
            var c = pool.acquire()
            var ok = True
            try:
                var r = execute_prepared(c, "pq_stress_details",
                                         [format_i64(item_id)])
                if not (r.rows() == 1 and r.col_i64(0, 0) == item_id):
                    failures += 1
                r.clear()
                var rc = execute_prepared(c, "pq_stress_count", [])
                if not (rc.rows() == 1 and rc.col_i64(0, 0) >= 0):
                    failures += 1
                rc.clear()
            except:
                ok = False
            pool.release(c^)   # ALWAYS back, clean or dirty
            if not ok:
                failures += 1
        except:
            failures += 1
    var st = pool.stats()
    var clean = st.in_use == 0 and st.total_open <= 4  # one stale-swap slack
    pool.close()
    if failures != 0 or not clean:
        print("[prepstress] worker", seed, "failures =", failures,
              "stats clean =", clean)
        return 100 + failures
    return 0


def run_fleet(
    count: Int, iters: Int, mut kids: List[Int], status_addr: Int,
    done_addr: Int,
) raises -> Int:
    """Fork count hammerers; decodes raw wait status so both signaled deaths
    (macOS objc fork-abort => sig 9) and failing hammers count as bad."""
    var bad = 0
    var status = Pointer[Int32, MutAnyOrigin](unsafe_from_address=status_addr)
    for w in range(count):
        var pid = external_call["fork", Int32]()
        check(pid >= 0, "fork succeeded")
        if pid == 0:
            var rc = hammer(DSN, iters, w, done_addr)
            _ = external_call["_exit", NoneType](rc & 0xFF)
        kids.append(Int(pid))
    for j in range(count):
        _ = external_call["waitpid", Int32](
            Int32(kids[len(kids) - count + j]), status, 0
        )
        var sig = status[unsafe_offset=0] & 0x7F
        var code = (status[unsafe_offset=0] >> 8) & 0xFF
        if sig != 0 or code != 0:
            bad += 1
            print("[prepstress] worker exited sig =", sig, "code =", code)
    return bad


def main() raises:
    setup_fixture()   # BEFORE any fork: workers only query, never create
    var kids = List[Int]()
    var status_addr = _shared_zeroed(4)
    var done_addr = _shared_zeroed(WORKERS * 4)

    var bad1 = run_fleet(WORKERS, ITER_PER_WORKER, kids, status_addr,
                         done_addr)
    check(bad1 == 0, "all prepared-statement hammerers completed flawlessly")
    print("[prepstress]", WORKERS, "x", ITER_PER_WORKER,
          "prepared bind-by-name checkouts across processes: zero failures")

    var done_addr2 = _shared_zeroed((WORKERS // 2) * 4)
    var bad2 = run_fleet(WORKERS // 2, 30, kids, status_addr, done_addr2)
    check(bad2 == 0, "smaller burst still clean")
    print("[prepstress] second fleet clean")

    # PARENT-side plan registration sanity ONLY after all forks are joined:
    # touching libpq pre-fork initializes ObjC runtime state whose fork()
    # abort kills children on macOS (same reason pool_stress never connects
    # in the parent).
    var pre = ConnectionPool(PoolConfig(DSN, max_size=2, min_idle=1))
    pre.prepare_on_acquire(build_plan())
    var c = pre.acquire()
    var r = execute_prepared(c, "pq_stress_count", [])
    check(r.rows() == 1, "stress plan count works")
    r.clear()
    pre.release(c^)
    pre.close()

    teardown_fixture()
    print("TEST_PREPARED_STRESS PASS")
