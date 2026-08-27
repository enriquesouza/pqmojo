"""pqmojo.ffi — runtime-loaded libpq surface, pure C FFI, no Python interop.

libpq is never linked at build time. The dylib is found by probing
LIBPQ_CANDIDATES in order through dlopen (RTLD_NOW), and every PQ symbol is
bound with `ExternalFunction[name, type].load()`, which is dlsym under the
hood. PGconn*/PGresult*/char* cross the boundary as opaque Int addresses with
0 for NULL — Mojo pointers are non-nullable by design.
"""

from std.collections.span import Span
from std.ffi import c_size_t, c_ssize_t, dlopen, external_call
from std.memory import Pointer, stack_allocation
from std.python._cpython import ExternalFunction, _DLHandle


comptime CharPtr = Pointer[Byte, MutAnyOrigin]

comptime RTLD_NOW: Int32 = 2

comptime CONNECTION_OK: Int32 = 0

# PGresult status codes (libpq libpq-fe.h PGRES_*).
comptime PGRES_EMPTY_QUERY: Int32 = 0
comptime PGRES_COMMAND_OK: Int32 = 1
comptime PGRES_TUPLES_OK: Int32 = 2


def libpq_candidates() -> List[String]:
    """Probe order for the runtime dlopen of libpq."""
    var out = List[String](capacity=7)
    out.append("/opt/homebrew/lib/libpq.dylib")
    out.append("/opt/homebrew/opt/postgresql@16/lib/libpq.dylib")
    out.append("/opt/homebrew/opt/postgresql@17/lib/libpq.dylib")
    out.append("/opt/homebrew/opt/postgresql@14/lib/libpq.dylib")
    out.append("/usr/local/lib/libpq.dylib")
    out.append("/usr/lib/libpq.dylib")
    out.append("libpq.dylib")
    return out^


comptime _FnConnectdb = def(CharPtr) thin abi("C") -> Int
comptime _FnStatus = def(Int) thin abi("C") -> Int32
comptime _FnErrorMessage = def(Int) thin abi("C") -> Int
comptime _FnExecParams = def(
    Int, CharPtr, Int32, Int, Int, Int, Int, Int32
) thin abi("C") -> Int
comptime _FnNtuples = def(Int) thin abi("C") -> Int32
comptime _FnNfields = def(Int) thin abi("C") -> Int32
comptime _FnGetvalue = def(Int, Int32, Int32) thin abi("C") -> Int
comptime _FnGetisnull = def(Int, Int32, Int32) thin abi("C") -> Int32
comptime _FnClear = def(Int) thin abi("C") -> NoneType
comptime _FnFinish = def(Int) thin abi("C") -> NoneType
comptime _FnParameterStatus = def(Int, CharPtr) thin abi("C") -> Int
comptime _FnSendQuery = def(Int, CharPtr) thin abi("C") -> Int32
comptime _FnSendQueryParams = def(
    Int, CharPtr, Int32, Int, Int, Int, Int, Int32
) thin abi("C") -> Int32
comptime _FnPrepare = def(Int, CharPtr, CharPtr, Int32, Int) thin abi("C") -> Int
comptime _FnExecPrepared = def(
    Int, CharPtr, Int32, Int, Int, Int, Int32
) thin abi("C") -> Int
comptime _FnSendQueryPrepared = def(
    Int, CharPtr, Int32, Int, Int, Int, Int32
) thin abi("C") -> Int32
comptime _FnGetResult = def(Int) thin abi("C") -> Int
comptime _FnConsumeInput = def(Int) thin abi("C") -> Int32
comptime _FnIsBusy = def(Int) thin abi("C") -> Int32
comptime _FnSocket = def(Int) thin abi("C") -> Int32
comptime _FnResultStatus = def(Int) thin abi("C") -> Int32
comptime _FnResultErrorMessage = def(Int) thin abi("C") -> Int

comptime _PQconnectdb = ExternalFunction["PQconnectdb", _FnConnectdb]
comptime _PQstatus = ExternalFunction["PQstatus", _FnStatus]
comptime _PQerrorMessage = ExternalFunction["PQerrorMessage", _FnErrorMessage]
comptime _PQexecParams = ExternalFunction["PQexecParams", _FnExecParams]
comptime _PQntuples = ExternalFunction["PQntuples", _FnNtuples]
comptime _PQnfields = ExternalFunction["PQnfields", _FnNfields]
comptime _PQgetvalue = ExternalFunction["PQgetvalue", _FnGetvalue]
comptime _PQgetisnull = ExternalFunction["PQgetisnull", _FnGetisnull]
comptime _PQclear = ExternalFunction["PQclear", _FnClear]
comptime _PQfinish = ExternalFunction["PQfinish", _FnFinish]
comptime _PQparameterStatus = ExternalFunction[
    "PQparameterStatus", _FnParameterStatus
]
comptime _PQsendQuery = ExternalFunction["PQsendQuery", _FnSendQuery]
comptime _PQsendQueryParams = ExternalFunction[
    "PQsendQueryParams", _FnSendQueryParams
]
comptime _PQprepare = ExternalFunction["PQprepare", _FnPrepare]
comptime _PQexecPrepared = ExternalFunction[
    "PQexecPrepared", _FnExecPrepared
]
comptime _PQsendQueryPrepared = ExternalFunction[
    "PQsendQueryPrepared", _FnSendQueryPrepared
]
comptime _PQgetResult = ExternalFunction["PQgetResult", _FnGetResult]
comptime _PQconsumeInput = ExternalFunction["PQconsumeInput", _FnConsumeInput]
comptime _PQisBusy = ExternalFunction["PQisBusy", _FnIsBusy]
comptime _PQsocket = ExternalFunction["PQsocket", _FnSocket]
comptime _PQresultStatus = ExternalFunction["PQresultStatus", _FnResultStatus]
comptime _PQresultErrorMessage = ExternalFunction[
    "PQresultErrorMessage", _FnResultErrorMessage
]


struct PgSymbols(Copyable, Movable):
    """The dlsym-bound PQ function set riding on one connection.

    Loaded functions live on the connection so there is no global mutable
    state anywhere: query calls take the conn, borrow its symbols, go.
    Copyable by design — this table is immutable function pointers; sharing
    it shares nothing. Only PgConn carries the live socket.
    """

    var connectdb: _PQconnectdb.type
    var status: _PQstatus.type
    var error_message: _PQerrorMessage.type
    var exec_params: _PQexecParams.type
    var ntuples: _PQntuples.type
    var nfields: _PQnfields.type
    var getvalue: _PQgetvalue.type
    var getisnull: _PQgetisnull.type
    var clear: _PQclear.type
    var finish: _PQfinish.type
    var parameter_status: _PQparameterStatus.type
    var send_query: _FnSendQuery
    var send_query_params: _FnSendQueryParams
    var prepare_fn: _FnPrepare
    var exec_prepared: _FnExecPrepared
    var send_query_prepared: _FnSendQueryPrepared
    var get_result: _FnGetResult
    var consume_input: _FnConsumeInput
    var is_busy: _FnIsBusy
    var socket_fn: _FnSocket
    var result_status: _FnResultStatus
    var result_error_message: _FnResultErrorMessage

    def __init__(
        out self,
        connectdb: _PQconnectdb.type,
        status: _PQstatus.type,
        error_message: _PQerrorMessage.type,
        exec_params: _PQexecParams.type,
        ntuples: _PQntuples.type,
        nfields: _PQnfields.type,
        getvalue: _PQgetvalue.type,
        getisnull: _PQgetisnull.type,
        clear: _PQclear.type,
        finish: _PQfinish.type,
        parameter_status: _PQparameterStatus.type,
        send_query: _FnSendQuery,
        send_query_params: _FnSendQueryParams,
        prepare_fn: _FnPrepare,
        exec_prepared: _FnExecPrepared,
        send_query_prepared: _FnSendQueryPrepared,
        get_result: _FnGetResult,
        consume_input: _FnConsumeInput,
        is_busy: _FnIsBusy,
        socket_fn: _FnSocket,
        result_status: _FnResultStatus,
        result_error_message: _FnResultErrorMessage,
    ):
        self.connectdb = connectdb
        self.status = status
        self.error_message = error_message
        self.exec_params = exec_params
        self.ntuples = ntuples
        self.nfields = nfields
        self.getvalue = getvalue
        self.getisnull = getisnull
        self.clear = clear
        self.finish = finish
        self.parameter_status = parameter_status
        self.send_query = send_query
        self.send_query_params = send_query_params
        self.prepare_fn = prepare_fn
        self.exec_prepared = exec_prepared
        self.send_query_prepared = send_query_prepared
        self.get_result = get_result
        self.consume_input = consume_input
        self.is_busy = is_busy
        self.socket_fn = socket_fn
        self.result_status = result_status
        self.result_error_message = result_error_message


def c_string(s: String) -> CharPtr:
    """NUL-terminated malloc'd copy of a Mojo String; release with c_free."""
    var b = s.as_bytes()
    var out = external_call["malloc", CharPtr](c_size_t(len(b) + 1))
    for i in range(len(b)):
        out[unsafe_offset=i] = b[i]
    out[unsafe_offset=len(b)] = 0
    return out


def c_free(p: CharPtr):
    _ = external_call["free", c_ssize_t](p)


def text_of(addr: Int) -> String:
    """Materialize a NUL-terminated C string as a Mojo String (copied)."""
    if addr == 0:
        return String("")
    var p = CharPtr(unsafe_from_address=addr)
    var n = 0
    while p[unsafe_offset=n] != 0:
        n += 1
    if n == 0:
        return String("")
    return String(unsafe_from_utf8=Span(unsafe_ptr=p, length=n))


def open_libpq() raises -> PgSymbols:
    """dlopen the first candidate that loads and bind the whole symbol table.

    Raises carrying dlerror output when every candidate path fails. Call
    AFTER fork only — see pqmojo.conn for the fork contract.
    """
    var handle = Int(0)
    var last_err = String("libpq.dylib not found in any candidate path")
    var candidates = libpq_candidates()
    for ci in range(len(candidates)):
        var buf = c_string(candidates[ci])
        var imm = Pointer[Int8, ImmUntrackedOrigin](unsafe_from_address=Int(buf))
        var h = dlopen(imm, RTLD_NOW)
        if h:
            handle = Int(h.value())
            c_free(buf)
            break
        var err_ptr = external_call["dlerror", Int]()
        if err_ptr != 0:
            last_err = text_of(err_ptr)
        c_free(buf)
    if handle == 0:
        raise Error("pqmojo: " + last_err)

    var dlh = _DLHandle(
        Pointer[NoneType, MutUntrackedOrigin](unsafe_from_address=handle)
    )
    return PgSymbols(
        connectdb=_PQconnectdb.load(dlh),
        status=_PQstatus.load(dlh),
        error_message=_PQerrorMessage.load(dlh),
        exec_params=_PQexecParams.load(dlh),
        ntuples=_PQntuples.load(dlh),
        nfields=_PQnfields.load(dlh),
        getvalue=_PQgetvalue.load(dlh),
        getisnull=_PQgetisnull.load(dlh),
        clear=_PQclear.load(dlh),
        finish=_PQfinish.load(dlh),
        parameter_status=_PQparameterStatus.load(dlh),
        send_query=_PQsendQuery.load(dlh),
        send_query_params=_PQsendQueryParams.load(dlh),
        prepare_fn=_PQprepare.load(dlh),
        exec_prepared=_PQexecPrepared.load(dlh),
        send_query_prepared=_PQsendQueryPrepared.load(dlh),
        get_result=_PQgetResult.load(dlh),
        consume_input=_PQconsumeInput.load(dlh),
        is_busy=_PQisBusy.load(dlh),
        socket_fn=_PQsocket.load(dlh),
        result_status=_PQresultStatus.load(dlh),
        result_error_message=_PQresultErrorMessage.load(dlh),
    )
