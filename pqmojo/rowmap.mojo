"""pqmojo.rowmap — typed row mapping: declare a struct once, read whole rows.

The sqlx FromRow pattern for Mojo 1.0 (no proc-macros, no attributes): a row
struct declares its column mapping ONCE through the FromRow protocol —

    struct Person(FromRow, Defaultable, Movable):
        var id: Int64
        var name: String
        var score: Optional[Float64]

        def __init__(out self):
            self.id = 0
            self.name = String("")
            self.score = Optional[Float64]()

        @staticmethod
        def row_columns() -> RowColumns:
            var t = RowColumns()
            t.add("id")
            t.add("name")
            t.add("score")
            return t^

— and the query_as family builds List[Person] from any result:

    var people = query_as[Person](conn, "SELECT id, name, score FROM ...", [])

Field types drive the readers, mirroring PgResult's own accessors: Int64 and
Int32 fields scan decimal text (text mode) or big-endian wire ints (binary
mode), Float64 fields scan strtod text or route by column type OID (float8
bitcast / numeric base-10000 rebuild, bit-identical by construction), String
fields copy text, Bool fields read 't'/'f' or the one wire byte, List[Int32] /
List[Int64] / List[String] fields split or decode 1-D arrays. Optional[T]
fields turn SQL NULL into absent — the row struct's nullability lives at the
declaration site, not in per-query is_null plumbing.

RowColumns entries resolve BY NAME through PQfnumber (case-insensitive, SQL
folding rules) with the name-to-index pass run once per result; an empty ""
entry resolves positionally instead. A missing column raises naming the
struct, the field and the expected column. The table is exactly what a
codegen script emits from trailing `# db "column_name"` comments.

BINARY results are strict where TEXT is lenient: the column's type OID
decides the decoder (a Float64 field over a numeric column runs the numeric
reader, over float8 the bitcast), and an OID the field type cannot read
raises naming the column and its OID instead of reinterpreting wire bytes.
"""

from std.collections.array import InlineArray
from std.memory import Pointer, bitcast
from std.reflection import reflect
from std.builtin.rebind import downcast, rebind

from .conn import PgConn
from .ffi import PgSymbols, text_of
from .pgarray import (
    split_postgres_int32_array,
    split_postgres_int64_array,
    split_postgres_text_array,
)
from .pool import ConnectionPool
from .query import execute, execute_binary, execute_prepared
from .result import PgResult


comptime OID_INT2: Int = 21
comptime OID_INT4: Int = 23
comptime OID_INT8: Int = 20
comptime OID_FLOAT4: Int = 700
comptime OID_FLOAT8: Int = 701
comptime OID_BOOL: Int = 16
comptime OID_NUMERIC: Int = 1700
comptime OID_TEXT: Int = 25
comptime OID_CHAR: Int = 18
comptime OID_NAME: Int = 19
comptime OID_BPCHAR: Int = 1042
comptime OID_VARCHAR: Int = 1043
comptime OID_INT4_ARRAY: Int = 1007
comptime OID_INT8_ARRAY: Int = 1016
comptime OID_TEXT_ARRAY: Int = 1009


@always_inline
def _some_of[E: Movable](var v: E, out dest: Optional[E]) raises:
    dest = Optional[E](v^)


trait RowValue(Deinitable, Movable):
    """One field type's cell readers, dispatched by conformance.

    Conformed through __extension for the stdlib scalars/containers the
    reflected walker meets, so row structs never implement this themselves;
    a custom single-column wrapper type may conform to join a table."""

    @staticmethod
    @always_inline
    def read_text_cell(res: PgResult, row: Int, col: Int, out s: Self) raises:
        ...

    @staticmethod
    @always_inline
    def read_binary_cell(
        res: PgResult,
        row: Int,
        col: Int,
        syms: PgSymbols,
        out s: Self,
    ) raises:
        ...


def _column_oid(syms: PgSymbols, res: PgResult, col: Int) raises -> Int:
    """Server type OID of one result column (the binary reader router)."""
    return Int(syms.column_type(res.handle, Int32(col)))


def _column_label(syms: PgSymbols, res: PgResult, col: Int) raises -> String:
    """'name' (type OID N) for diagnostics; index form when unnamed."""
    var nm = text_of(syms.column_name(res.handle, Int32(col)))
    var oid = _column_oid(syms, res, col)
    if nm.byte_length() == 0:
        nm = String("#") + String(col)
    return "'" + nm + "' (type OID " + String(oid) + ")"


def _reject_column(
    syms: PgSymbols,
    res: PgResult,
    col: Int,
    field_kind: String,
    wants: String,
) raises:
    """The actionable binary-mode mismatch: column identity + what fits."""
    raise Error(
        "pqmojo: column "
        + _column_label(syms, res, col)
        + " cannot feed a "
        + field_kind
        + " field in BINARY results; "
        + wants
    )


def _read_f32_cell(res: PgResult, row: Int, col: Int) raises -> Float64:
    """float4 wire cell (4B big-endian IEEE754 single) widened to Float64."""
    var b = res.bin_bytes(row, col)
    if len(b) != 4:
        raise Error(
            "pqmojo: binary float4 needs 4 bytes, got " + String(len(b))
        )
    var u = (UInt32(b[0]) << 24) | (UInt32(b[1]) << 16) | (
        UInt32(b[2]) << 8
    ) | UInt32(b[3])
    return bitcast[src_dtype=DType.uint32, src_width=1, dtype=DType.float32](
        Scalar[DType.uint32](u)
    ).cast[DType.float64]()


def _read_i2_cell(res: PgResult, row: Int, col: Int) raises -> Int64:
    """int2 wire cell (2B big-endian two's complement) sign-extended."""
    var b = res.bin_bytes(row, col)
    if len(b) != 2:
        raise Error(
            "pqmojo: binary int2 needs 2 bytes, got " + String(len(b))
        )
    var v = (Int(b[0]) << 8) | Int(b[1])
    if v >= 32768:
        v -= 65536
    return Int64(v)


__extension SIMD(RowValue):
    @staticmethod
    @always_inline
    def read_text_cell(res: PgResult, row: Int, col: Int, out s: Self) raises:
        comptime assert Self.length == 1, "pqmojo: row fields are scalars"
        comptime if Self.dtype.is_floating_point():
            s = Self(res.col_f64(row, col).cast[Self.dtype]())
        else:
            s = Self(res.col_i64(row, col).cast[Self.dtype]())

    @staticmethod
    @always_inline
    def read_binary_cell(
        res: PgResult,
        row: Int,
        col: Int,
        syms: PgSymbols,
        out s: Self,
    ) raises:
        comptime assert Self.length == 1, "pqmojo: row fields are scalars"
        var oid = _column_oid(syms, res, col)
        comptime if Self.dtype.is_floating_point():
            if oid == OID_FLOAT8:
                s = Self(res.bin_f64(row, col).cast[Self.dtype]())
            elif oid == OID_NUMERIC:
                s = Self(res.bin_numeric_to_f64(row, col).cast[Self.dtype]())
            elif oid == OID_FLOAT4:
                s = Self(_read_f32_cell(res, row, col).cast[Self.dtype]())
            else:
                _reject_column(
                    syms,
                    res,
                    col,
                    "float",
                    "float fields read float8/float4/numeric columns",
                )
                s = Self()
        else:
            if oid == OID_INT8:
                s = Self(res.bin_i64(row, col).cast[Self.dtype]())
            elif oid == OID_INT4:
                s = Self(res.bin_i32(row, col).cast[Self.dtype]())
            elif oid == OID_INT2:
                s = Self(_read_i2_cell(res, row, col).cast[Self.dtype]())
            else:
                _reject_column(
                    syms,
                    res,
                    col,
                    "int",
                    "int fields read int8/int4/int2 columns",
                )
                s = Self()


__extension Bool(RowValue):
    @staticmethod
    @always_inline
    def read_text_cell(res: PgResult, row: Int, col: Int, out s: Self) raises:
        s = res.col_bool(row, col)

    @staticmethod
    @always_inline
    def read_binary_cell(
        res: PgResult,
        row: Int,
        col: Int,
        syms: PgSymbols,
        out s: Self,
    ) raises:
        var oid = _column_oid(syms, res, col)
        if oid != OID_BOOL:
            _reject_column(
                syms, res, col, "Bool", "Bool fields read bool columns"
            )
            s = Self()
        s = res.bin_bool(row, col)


__extension String(RowValue):
    @staticmethod
    @always_inline
    def read_text_cell(res: PgResult, row: Int, col: Int, out s: Self) raises:
        s = res.col_text(row, col)

    @staticmethod
    @always_inline
    def read_binary_cell(
        res: PgResult,
        row: Int,
        col: Int,
        syms: PgSymbols,
        out s: Self,
    ) raises:
        var oid = _column_oid(syms, res, col)
        if (
            oid != OID_TEXT
            and oid != OID_VARCHAR
            and oid != OID_BPCHAR
            and oid != OID_NAME
            and oid != OID_CHAR
        ):
            _reject_column(
                syms,
                res,
                col,
                "String",
                "String fields read text/varchar/char/name columns",
            )
            s = Self()
        s = res.bin_text(row, col)


__extension Optional(RowValue):
    @staticmethod
    @always_inline
    def read_text_cell(res: PgResult, row: Int, col: Int, out s: Self) raises:
        comptime assert conforms_to(Self.T, RowValue), (
            "pqmojo: Optional element type is not a row-readable cell type"
        )
        if res.is_null(row, col):
            s = Self()
        else:
            s = _some_of(
                downcast[Self.T, RowValue].read_text_cell(res, row, col)
            )

    @staticmethod
    @always_inline
    def read_binary_cell(
        res: PgResult,
        row: Int,
        col: Int,
        syms: PgSymbols,
        out s: Self,
    ) raises:
        comptime assert conforms_to(Self.T, RowValue), (
            "pqmojo: Optional element type is not a row-readable cell type"
        )
        if res.is_null(row, col):
            s = Self()
        else:
            s = _some_of(
                downcast[Self.T, RowValue].read_binary_cell(
                    res, row, col, syms
                )
            )


__extension List(RowValue):
    @staticmethod
    @always_inline
    def read_text_cell(res: PgResult, row: Int, col: Int, out s: Self) raises:
        comptime if Self.T == Int32:
            s = rebind_var[Self](
                split_postgres_int32_array(res.col_text(row, col))
            )
        else:
            comptime if Self.T == Int64:
                s = rebind_var[Self](
                    split_postgres_int64_array(res.col_text(row, col))
                )
            else:
                comptime if Self.T == String:
                    s = rebind_var[Self](
                        split_postgres_text_array(res.col_text(row, col))
                    )
                else:
                    comptime assert False, (
                        "pqmojo: List row fields hold Int32, Int64 or String"
                    )

    @staticmethod
    @always_inline
    def read_binary_cell(
        res: PgResult,
        row: Int,
        col: Int,
        syms: PgSymbols,
        out s: Self,
    ) raises:
        var oid = _column_oid(syms, res, col)
        comptime if Self.T == Int32:
            if oid != OID_INT4_ARRAY:
                _reject_column(
                    syms,
                    res,
                    col,
                    "List[Int32]",
                    "List[Int32] fields read int4[] columns",
                )
                s = Self()
            else:
                s = rebind_var[Self](res.bin_int32_array(row, col))
        else:
            comptime if Self.T == Int64:
                if oid != OID_INT8_ARRAY:
                    _reject_column(
                        syms,
                        res,
                        col,
                        "List[Int64]",
                        "List[Int64] fields read int8[] columns",
                    )
                    s = Self()
                else:
                    s = rebind_var[Self](res.bin_int64_array(row, col))
            else:
                comptime if Self.T == String:
                    if oid != OID_TEXT_ARRAY:
                        _reject_column(
                            syms,
                            res,
                            col,
                            "List[String]",
                            "List[String] fields read text[] columns",
                        )
                        s = Self()
                    else:
                        s = rebind_var[Self](res.bin_text_array(row, col))
                else:
                    comptime assert False, (
                        "pqmojo: List row fields hold Int32, Int64 or String"
                    )


struct RowColumns(Copyable, Movable):
    """The declaration-site column table: one entry per struct field, in
    field order. Non-empty entries name result columns (PQfnumber
    resolution, once per result); an empty entry takes the field's own
    position. Fixed capacity 64 — the documented v0.6 limit."""

    comptime CAP = 64

    var keys: InlineArray[StaticString, 64]
    var n: Int

    def __init__(out self):
        self.keys = InlineArray[StaticString, 64](fill="")
        self.n = 0

    def add(mut self, name: StaticString) raises:
        if self.n >= Self.CAP:
            raise Error(
                "pqmojo: RowColumns holds at most "
                + String(Self.CAP)
                + " columns"
            )
        self.keys[self.n] = name
        self.n += 1


trait FromRow(Deinitable, Movable):
    """A struct that maps one result row: fields in declaration order meet
    the columns row_columns() names. The struct needs a zero-value
    constructor (Defaultable); every field type must be row-readable
    (Int64/Int32/Float64/Bool/String/1-D Lists, Optional of any of those)."""

    @staticmethod
    def row_columns() raises -> RowColumns: ...


def _result_column_names(syms: PgSymbols, res: PgResult) -> String:
    """Comma-joined names of every column, for mismatch diagnostics."""
    var out = String("")
    for c in range(res.cols()):
        if c > 0:
            out += ", "
        var nm = text_of(syms.column_name(res.handle, Int32(c)))
        if nm.byte_length() == 0:
            nm = String("#") + String(c)
        out += nm
    return out


def _static_c_ptr(s: StaticString) -> Pointer[Byte, MutAnyOrigin]:
    """StaticString literal bytes as a C string — literals are laid out
    NUL-terminated, so PQfnumber reads them with zero copying."""
    return Pointer[Byte, MutAnyOrigin](unsafe_from_address=Int(s.unsafe_ptr()))


def _resolve_columns[T: FromRow](res: PgResult, syms: PgSymbols) raises -> List[Int]:
    """Per-field column indexes for THIS result: PQfnumber for named
    entries, own position for empty ones. Runs once per result, not per
    row."""
    comptime r = reflect[T]
    comptime count = r.field_count()
    var table = T.row_columns()
    if table.n != count:
        raise Error(
            "pqmojo: "
            + String(r.base_name())
            + ".row_columns() has "
            + String(table.n)
            + " entries for "
            + String(count)
            + " fields"
        )
    var out = List[Int](capacity=count)
    for i in range(count):
        var key = table.keys[i]
        if key.byte_length() == 0:
            if i >= res.cols():
                raise Error(
                    "pqmojo: "
                    + String(r.base_name())
                    + " field '"
                    + String(r.field_names()[i])
                    + "' maps positionally to column "
                    + String(i)
                    + " but the result has "
                    + String(res.cols())
                    + " columns"
                )
            out.append(i)
            continue
        var idx = Int(syms.column_index(res.handle, _static_c_ptr(key)))
        if idx < 0 or idx >= res.cols():
            raise Error(
                "pqmojo: "
                + String(r.base_name())
                + " field '"
                + String(r.field_names()[i])
                + "' expects column '"
                + String(key)
                + "'; the result's columns are: "
                + _result_column_names(syms, res)
            )
        out.append(idx)
    return out^


def _fill_row[T: Deinitable & Defaultable & Movable](
    mut dest: T, res: PgResult, row: Int, cols: List[Int]
) raises:
    comptime r = reflect[T]
    comptime types = r.field_types()
    comptime for i in range(r.field_count()):
        comptime FT = types[i]
        ref field = rebind[downcast[FT, RowValue]](r.field_ref[i](dest))
        field = downcast[FT, RowValue].read_text_cell(
            res, row, cols.unsafe_get(i)
        )


def _fill_row_binary[T: Deinitable & Defaultable & Movable](
    mut dest: T, res: PgResult, row: Int, cols: List[Int], syms: PgSymbols
) raises:
    comptime r = reflect[T]
    comptime types = r.field_types()
    comptime for i in range(r.field_count()):
        comptime FT = types[i]
        ref field = rebind[downcast[FT, RowValue]](r.field_ref[i](dest))
        field = downcast[FT, RowValue].read_binary_cell(
            res, row, cols.unsafe_get(i), syms
        )


def _map_rows[T: FromRow & Defaultable](
    res: PgResult, syms: PgSymbols, binary: Bool
) raises -> List[T]:
    var cols = _resolve_columns[T](res, syms)
    return _map_planned[T](res, syms, cols, binary)


def _map_planned[T: FromRow & Defaultable](
    res: PgResult, syms: PgSymbols, cols: List[Int], binary: Bool
) raises -> List[T]:
    var out = List[T](capacity=res.rows())
    if res.rows() == 0:
        return out^
    var width = res.cols()
    for c in range(len(cols)):
        if cols.unsafe_get(c) >= width:
            raise Error(
                "pqmojo: RowPlan does not match this result (field "
                + String(c)
                + " wants column "
                + String(cols.unsafe_get(c))
                + " of "
                + String(width)
                + ")"
            )
    for row in range(res.rows()):
        var dest = T()
        if binary:
            _fill_row_binary(dest, res, row, cols, syms)
        else:
            _fill_row(dest, res, row, cols)
        out.append(dest^)
    return out^


def _map_first[T: FromRow & Defaultable](
    res: PgResult, syms: PgSymbols, binary: Bool
) raises -> Optional[T]:
    if res.rows() == 0:
        return Optional[T]()
    var cols = _resolve_columns[T](res, syms)
    var dest = T()
    if binary:
        _fill_row_binary(dest, res, 0, cols, syms)
    else:
        _fill_row(dest, res, 0, cols)
    return Optional[T](dest^)


def map_rows_as[T: FromRow & Defaultable](
    res: PgResult, conn: PgConn
) raises -> List[T]:
    """Build List[T] from a TEXT PgResult the caller already holds.

    Ownership stays with the caller (clear() it afterwards). For results
    produced outside the query_as family — poll_result, pipelines, custom
    prepared wrappers."""
    return _map_rows[T](res, conn.syms, False)


def map_rows_as_binary[T: FromRow & Defaultable](
    res: PgResult, conn: PgConn
) raises -> List[T]:
    """Build List[T] from a BINARY (fmt=1) PgResult the caller holds."""
    return _map_rows[T](res, conn.syms, True)


struct RowPlan(Copyable, Movable):
    """Resolved column indexes for one struct/statement pair, REUSABLE
    across results of the same shape: resolve once against any result of
    the SELECT, map every later result without re-resolving (the hot-path
    zero-resolution form of query_as). Mismatched results raise."""

    var cols: List[Int]

    def __init__(out self):
        self.cols = List[Int]()

    def __init__(out self, var cols: List[Int]):
        self.cols = cols^


def resolve_row_plan[T: FromRow](res: PgResult, conn: PgConn) raises -> RowPlan:
    """Name-resolve T's table against this result's columns once."""
    return RowPlan(_resolve_columns[T](res, conn.syms))


def map_rows_as_planned[T: FromRow & Defaultable](
    res: PgResult, conn: PgConn, plan: RowPlan
) raises -> List[T]:
    """List[T] from a TEXT result using a pre-resolved RowPlan."""
    return _map_planned[T](res, conn.syms, plan.cols, False)


def map_rows_as_binary_planned[T: FromRow & Defaultable](
    res: PgResult, conn: PgConn, plan: RowPlan
) raises -> List[T]:
    """List[T] from a BINARY result using a pre-resolved RowPlan."""
    return _map_planned[T](res, conn.syms, plan.cols, True)


def query_as[T: FromRow & Defaultable](
    conn: PgConn, sql: String, params: List[String]
) raises -> List[T]:
    """TEXT execution mapped to List[T]; the result is cleared internally."""
    var res = execute(conn, sql, params)
    var out = _map_rows[T](res, conn.syms, False)
    res.clear()
    return out^


def query_as[T: FromRow & Defaultable](conn: PgConn, sql: String) raises -> List[T]:
    """query_as without params."""
    return query_as[T](conn, sql, List[String]())


def query_as_binary[T: FromRow & Defaultable](
    conn: PgConn, sql: String, params: List[String]
) raises -> List[T]:
    """BINARY (fmt=1) execution mapped to List[T]; result cleared
    internally. Same struct, same values as the text twin — the suite
    proves equality on every fixture type."""
    var res = execute_binary(conn, sql, params)
    var out = _map_rows[T](res, conn.syms, True)
    res.clear()
    return out^


def query_as_binary[T: FromRow & Defaultable](
    conn: PgConn, sql: String
) raises -> List[T]:
    """query_as_binary without params."""
    return query_as_binary[T](conn, sql, List[String]())


def query_one_as[T: FromRow & Defaultable](
    conn: PgConn, sql: String, params: List[String]
) raises -> Optional[T]:
    """First row as Optional[T] — ErrNoRows semantics: absent when the
    result set is empty, raises on SQL errors and mapping mismatches."""
    var res = execute(conn, sql, params)
    var out = _map_first[T](res, conn.syms, False)
    res.clear()
    return out^


def query_one_as[T: FromRow & Defaultable](
    conn: PgConn, sql: String
) raises -> Optional[T]:
    """query_one_as without params."""
    return query_one_as[T](conn, sql, List[String]())


def query_one_as_binary[T: FromRow & Defaultable](
    conn: PgConn, sql: String, params: List[String]
) raises -> Optional[T]:
    """query_one_as over a BINARY result."""
    var res = execute_binary(conn, sql, params)
    var out = _map_first[T](res, conn.syms, True)
    res.clear()
    return out^


def query_one_as_binary[T: FromRow & Defaultable](
    conn: PgConn, sql: String
) raises -> Optional[T]:
    """query_one_as_binary without params."""
    return query_one_as_binary[T](conn, sql, List[String]())


def query_prepared_as[T: FromRow & Defaultable](
    conn: PgConn, name: String, params: List[String]
) raises -> List[T]:
    """Bind + Execute a TEXT prepared statement by name, mapped to
    List[T]."""
    var res = execute_prepared(conn, name, params)
    var out = _map_rows[T](res, conn.syms, False)
    res.clear()
    return out^


def query_prepared_as[T: FromRow & Defaultable](
    mut pool: ConnectionPool, name: String, params: List[String]
) raises -> List[T]:
    """Pool checkout twin: acquire, mapped prepared execute, release."""
    var conn = pool.acquire()
    try:
        var rows = query_prepared_as[T](conn, name, params)
        pool.release(conn^)
        return rows^
    except e:
        pool.release(conn^)
        raise e^
