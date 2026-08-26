"""pqmojo.conn — the worker-owned connection and its fork contract.

!!! warning "FORK CONTRACT"

    `PgConn` is NOT Copyable by design: each connection is single-owner, and
    each worker process MUST create its own. Call `connect()` AFTER fork,
    once per worker, never in the parent. A PQconn opened pre-fork shares one
    socket across children and corrupts the wire protocol. The symbol table
    binds to the connection itself, so nothing can be queried without a
    post-fork connect — the constraint is structural.
"""

from .ffi import CONNECTION_OK, CharPtr, PgSymbols, c_free, c_string, open_libpq, text_of


struct PgConn(Movable):
    """One libpq connection plus its bound symbol table.

    Create AFTER fork (see module docstring). Not Copyable: ownership moves,
    it never shares. `close()` is idempotent; a closed conn carries handle 0.
    """

    var handle: Int
    var syms: PgSymbols

    def __init__(out self, handle: Int, syms: PgSymbols):
        self.handle = handle
        self.syms = syms.copy()

    def close(mut self):
        """PQfinish; idempotent — a closed conn carries handle 0."""
        if self.handle != 0:
            self.syms.finish(self.handle)
            self.handle = 0

    def parameter_status(self, name: String) -> String:
        """Server runtime parameter reported at connect time ("" if absent).

        e.g. parameter_status("server_version") -> "16.4". libpq caches these
        during startup; this reads the cache, no round trip.
        """
        if self.handle == 0:
            return String("")
        var n = c_string(name)
        var v = self.syms.parameter_status(self.handle, n)
        c_free(n)
        return text_of(v)


def connect(conninfo: String) raises -> PgConn:
    """Open a libpq connection; raise carrying PQerrorMessage on failure.

    Probes libpq_candidates() in order under RTLD_NOW, binding every PQ
    symbol to THIS connection. CALL AFTER FORK ONLY — see the fork contract.
    """
    var syms = open_libpq()
    var dsn = c_string(conninfo)
    var handle = syms.connectdb(dsn)
    c_free(dsn)
    if syms.status(handle) != CONNECTION_OK:
        var msg = text_of(syms.error_message(handle))
        syms.finish(handle)
        raise Error("pqmojo: PQconnectdb failed: " + msg)
    return PgConn(handle, syms^)


def close_conn(mut conn: PgConn):
    """Module-level alias for conn.close(), for call sites that prefer free
    functions over methods."""
    conn.close()
