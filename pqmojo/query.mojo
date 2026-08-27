"""pqmojo.query — parameterized execution over TEXT protocol.

exec_params binds every parameter as TEXT (paramTypes=NULL, paramLengths=NULL,
paramFormats=NULL, resultFormat=0), exactly like the proven hot path: Postgres
parses the text into whatever column type the statement wants. Results stay
PG text until an accessor scans them. PgResult and the scalar renderers live
in their own modules (pqmojo.result / pqmojo.args) so prepared statements can
share the exact same machinery; both are re-exported here unchanged.
"""

from std.ffi import c_size_t, c_ssize_t, external_call
from std.memory import Pointer

from .args import format_f64, format_i64
from .conn import PgConn
from .ffi import CharPtr, PgSymbols, c_free, c_string, text_of
from .result import PgResult
from .stmt import execute_prepared_on


def execute_prepared(
    conn: PgConn, name: String, params: List[String]
) raises -> PgResult:
    """Bind + Execute a prepared statement BY NAME on this conn; strict.

    The checkout-facing twin of pool plans (`pool.prepare_all`,
    `pool.prepare_on_acquire`): statements live on each backend session and
    are addressed by name on whatever healthy conn the pool hands over.
    Binding semantics are byte-identical to execute() — all params ride TEXT.
    """
    if conn.handle == 0:
        raise Error("pqmojo: cannot execute on a closed connection")
    return execute_prepared_on(conn.handle, conn.syms, name, params)


def _wrap(addr: Int, syms: PgSymbols) -> PgResult:
    """Package a raw PQresult pointer with this connection's bound accessors."""
    return PgResult(
        addr,
        syms.ntuples,
        syms.nfields,
        syms.getvalue,
        syms.getisnull,
        syms.clear,
        syms.result_status,
        syms.result_error_message,
    )


def exec_params(
    conn: PgConn, sql: String, params: List[String]
) raises -> PgResult:
    """Run one parameterized statement; all params bind as TEXT.

    Raises carrying PQerrorMessage when libpq returns no result. The returned
    PgResult owns its handle — clear() it explicitly.
    """
    var sql_buf = c_string(sql)
    var n = len(params)

    if n == 0:
        var res0 = conn.syms.exec_params(
            conn.handle, sql_buf, Int32(0), Int(0),
            Int(0), Int(0), Int(0), Int32(0)
        )
        c_free(sql_buf)
        if res0 == 0:
            raise Error("pqmojo: PQexecParams failed: "
                        + text_of(conn.syms.error_message(conn.handle)))
        return _wrap(res0, conn.syms)

    var addr_arr = Int(0)
    var bufs = List[CharPtr]()
    if n > 0:
        addr_arr = Int(external_call["malloc", CharPtr](c_size_t(n * 8)))
        var slots = Pointer[Int64, MutAnyOrigin](
            unsafe_from_address=addr_arr
        )
        for i in range(n):
            var b = c_string(params[i])
            bufs.append(b)
            slots[unsafe_offset=i] = Int64(Int(b))

    var res = conn.syms.exec_params(
        conn.handle, sql_buf, Int32(n), Int(0),
        addr_arr, Int(0), Int(0), Int32(0)
    )
    for i in range(len(bufs)):
        c_free(bufs[i])
    if addr_arr != 0:
        _ = external_call["free", c_ssize_t](
            CharPtr(unsafe_from_address=addr_arr)
        )
    c_free(sql_buf)

    if res == 0:
        raise Error("pqmojo: PQexecParams failed: "
                    + text_of(conn.syms.error_message(conn.handle)))

    return _wrap(res, conn.syms)


def execute(conn: PgConn, sql: String) raises -> PgResult:
    """One blocking round trip, no params; raises on SQL errors.

    Like exec_params but enforces result status: a statement the server
    rejects raises carrying the server's message instead of returning an
    empty-looking PgResult.
    """
    var res = exec_params(conn, sql, List[String]())
    res.check_ok()
    return res^


def execute(conn: PgConn, sql: String, params: List[String]) raises -> PgResult:
    """execute with TEXT params; raises on SQL errors."""
    var res = exec_params(conn, sql, params)
    res.check_ok()
    return res^


def row_exists(conn: PgConn, sql: String, params: List[String]) raises -> Bool:
    """True when the SELECT yields at least one row (EXISTS-shaped checks).

    Raises on SQL errors (unlike hand-rolled rows()>0 checks that silently
    treat failures as false). Clears the result internally.
    """
    var res = execute(conn, sql, params)
    var found = res.rows() > 0
    res.clear()
    return found


def row_exists(conn: PgConn, sql: String) raises -> Bool:
    """row_exists without params."""
    return row_exists(conn, sql, List[String]())


def scalar_i64(
    conn: PgConn, sql: String, params: List[String]
) raises -> Optional[Int64]:
    """First cell of the first row as Int64; Optional.None on zero rows.

    Raises when zero columns come back or the server rejects the statement.
    """
    var res = execute(conn, sql, params)
    var out = Optional[Int64]()
    if res.rows() > 0:
        if res.cols() < 1:
            res.clear()
            raise Error("pqmojo: scalar_i64 needs at least one column")
        out = Optional[Int64](res.int64(0, 0))
    res.clear()
    return out^


def scalar_i64(conn: PgConn, sql: String) raises -> Optional[Int64]:
    """scalar_i64 without params."""
    return scalar_i64(conn, sql, List[String]())
