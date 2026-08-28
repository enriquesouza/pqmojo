"""pqmojo.binary — BINARY result format (resultFormat=1): execution core and
typed big-endian decoders.

Postgres ships results in two wire encodings. TEXT (resultFormat=0) renders
every value as server-side text that the client re-parses per column per row
— the encode/parse pair that dominates MOJO's per-request CPU on wide
SELECTs. BINARY (resultFormat=1) ships the raw wire bytes instead: int8/int4
arrive as big-endian two's complement, float8 as big-endian IEEE754 (a
bitcast, not a parse), text as raw UTF8 with no escaping, arrays as a typed
header plus length-prefixed elements, NULLs through the same null map.

Params ride TEXT in BOTH modes — only the result flag flips. Binding
semantics, type inference and server behavior are byte-identical; the
existing text paths are untouched (zero breakage by construction).

Wire layouts decoded here (verified against the server byte-for-byte by the
test suite):

    int8:    8 bytes BE two's complement          int4:  4 bytes BE
    float8:  8 bytes BE IEEE754 bitcast            bool:  1 byte, nonzero = true
    text:    raw UTF8 bytes, no escaping
    numeric: ndigits:int16 BE | weight:int16 BE | sign:uint16 BE |
             dscale:uint16 BE | ndigits x int16 BE base-10000 digit groups
             sign 0x0000 pos, 0x4000 neg, 0xC000 NaN, 0xD000 +Inf, 0xF000 -Inf
    int4[]/text[]: ndim:int32 | flags:int32 | elemtype:int32 |
             [nelems:int32 | lbound:int32] x ndim |
             elements: int32 byte-length + raw bytes (-1 length = NULL)

Numeric -> Float64 reconstructs the exact decimal string from the base-10000
groups and runs libc strtod — the same correctly-rounded conversion the text
path uses, so results are BIT-IDENTICAL to the text path by construction
(the suite dual-parses every distinct numeric in the fixture table to prove it).

Decoders are strict: a cell whose byte length does not match its layout
raises rather than reinterpreting garbage. A NULL cell never reaches a
decoder — the PgResult bin_* accessors short-circuit to the same zero values
the text readers use.
"""

from std.collections.span import Span
from std.ffi import c_size_t, c_ssize_t, external_call
from std.memory import bitcast

from .ffi import CharPtr, PgSymbols, c_free, c_string, text_of


comptime FORMAT_TEXT: Int32 = 0
comptime FORMAT_BINARY: Int32 = 1

comptime NUMERIC_POS: UInt16 = 0x0000
comptime NUMERIC_NEG: UInt16 = 0x4000
comptime NUMERIC_NAN: UInt16 = 0xC000
comptime NUMERIC_PINF: UInt16 = 0xD000
comptime NUMERIC_NINF: UInt16 = 0xF000


def _read_u16_be(p: CharPtr, off: Int) -> UInt16:
    var hi = UInt16(p[unsafe_offset=off])
    var lo = UInt16(p[unsafe_offset=off + 1])
    return (hi << 8) | lo


def _read_u32_be(p: CharPtr, off: Int) -> UInt32:
    var b0 = UInt32(p[unsafe_offset=off])
    var b1 = UInt32(p[unsafe_offset=off + 1])
    var b2 = UInt32(p[unsafe_offset=off + 2])
    var b3 = UInt32(p[unsafe_offset=off + 3])
    return (b0 << 24) | (b1 << 16) | (b2 << 8) | b3


def _read_u64_be(p: CharPtr, off: Int) -> UInt64:
    var v = UInt64(0)
    for i in range(8):
        v = (v << 8) | UInt64(p[unsafe_offset=off + i])
    return v


def _read_i32_be(p: CharPtr, off: Int) -> Int32:
    return bitcast[src_dtype=DType.uint32, src_width=1, dtype=DType.int32](
        Scalar[DType.uint32](_read_u32_be(p, off))
    )


def _read_i16_be(p: CharPtr, off: Int) -> Int:
    """Signed 16-bit big-endian read (numeric's weight can be negative)."""
    var u = _read_u16_be(p, off)
    if (u & 0x8000) != 0:
        return Int(u) - 65536
    return Int(u)


def decode_i64(addr: Int, nbytes: Int32) raises -> Int64:
    """int8 wire bytes (8B big-endian two's complement) as Int64."""
    if nbytes != 8:
        raise Error(
            "pqmojo: binary int8 needs 8 bytes, got " + String(Int(nbytes))
        )
    var p = CharPtr(unsafe_from_address=addr)
    return bitcast[src_dtype=DType.uint64, src_width=1, dtype=DType.int64](
        Scalar[DType.uint64](_read_u64_be(p, 0))
    )


def decode_i32(addr: Int, nbytes: Int32) raises -> Int32:
    """int4 wire bytes (4B big-endian two's complement) as Int32."""
    if nbytes != 4:
        raise Error(
            "pqmojo: binary int4 needs 4 bytes, got " + String(Int(nbytes))
        )
    var p = CharPtr(unsafe_from_address=addr)
    return _read_i32_be(p, 0)


def decode_f64(addr: Int, nbytes: Int32) raises -> Float64:
    """float8 wire bytes (8B big-endian IEEE754) as Float64 — a bitcast,
    not a parse: bit-exact against the text path's strtod by construction."""
    if nbytes != 8:
        raise Error(
            "pqmojo: binary float8 needs 8 bytes, got " + String(Int(nbytes))
        )
    var p = CharPtr(unsafe_from_address=addr)
    return bitcast[src_dtype=DType.uint64, src_width=1, dtype=DType.float64](
        Scalar[DType.uint64](_read_u64_be(p, 0))
    )


def decode_bool(addr: Int, nbytes: Int32) raises -> Bool:
    """bool wire byte: nonzero is true."""
    if nbytes != 1:
        raise Error(
            "pqmojo: binary bool needs 1 byte, got " + String(Int(nbytes))
        )
    var p = CharPtr(unsafe_from_address=addr)
    return p[unsafe_offset=0] != 0


def decode_text(addr: Int, nbytes: Int32) -> String:
    """text wire bytes materialized as a Mojo String (raw UTF8 copy)."""
    if nbytes <= 0:
        return String("")
    var p = CharPtr(unsafe_from_address=addr)
    return String(unsafe_from_utf8=Span(unsafe_ptr=p, length=Int(nbytes)))


def decode_bytes(addr: Int, nbytes: Int32) -> Span[Byte, MutAnyOrigin]:
    """Zero-copy Span view over the cell's raw wire bytes.

    The span borrows libpq's buffer: valid until PgResult.clear()."""
    var p = CharPtr(unsafe_from_address=addr)
    return Span[Byte, MutAnyOrigin](unsafe_ptr=p, length=Int(nbytes))


def _strtod_bytes(chars: List[UInt8]) -> Float64:
    """NUL-terminate a digit buffer and hand it to libc strtod."""
    var n = len(chars)
    var mem = external_call["malloc", CharPtr](c_size_t(n + 1))
    for i in range(n):
        mem[unsafe_offset=i] = chars[i]
    mem[unsafe_offset=n] = 0
    var v = external_call["strtod", Float64](mem, 0)
    _ = external_call["free", c_ssize_t](mem)
    return v


def decode_numeric_to_f64(addr: Int, nbytes: Int32) raises -> Float64:
    """numeric wire bytes -> Float64, BIT-IDENTICAL to the text path.

    Reconstructs the exact decimal string from the base-10000 digit groups
    and runs libc strtod — the same correctly-rounded conversion the text
    path feeds on, so no dual representation can drift by even an ulp.
    """
    if Int(nbytes) < 8:
        raise Error(
            "pqmojo: binary numeric header truncated (" + String(Int(nbytes))
            + " bytes)"
        )
    var p = CharPtr(unsafe_from_address=addr)
    var ndigits = Int(_read_u16_be(p, 0))
    if Int(nbytes) != 8 + 2 * ndigits:
        raise Error("pqmojo: binary numeric length/ndigits mismatch")
    var weight = _read_i16_be(p, 2)
    var sign = _read_u16_be(p, 4)
    var dscale = Int(_read_u16_be(p, 6))

    if sign == NUMERIC_NAN:
        return _strtod_of("NaN")
    if sign == NUMERIC_PINF:
        return _strtod_of("Infinity")
    if sign == NUMERIC_NINF:
        return _strtod_of("-Infinity")
    if sign != NUMERIC_POS and sign != NUMERIC_NEG:
        raise Error(
            "pqmojo: binary numeric unknown sign " + String(Int(sign))
        )
    if ndigits == 0:
        return 0.0

    var chars = List[UInt8]()
    if sign == NUMERIC_NEG:
        chars.append(45)  # '-'
    if weight < 0:
        chars.append(48)  # '0'
    else:
        var g0 = _digit_group(p, 0, ndigits)
        var scale = 1000
        var started = False
        while scale > 0:
            var d = (g0 // scale) % 10
            if d != 0 or started:
                chars.append(UInt8(48 + d))
                started = True
            scale //= 10
        if not started:
            chars.append(48)  # '0'
        for gi in range(1, weight + 1):
            _append_group(chars, _digit_group(p, gi, ndigits))
    if dscale > 0:
        chars.append(46)  # '.'
        var produced = 0
        var gi = weight + 1
        while produced < dscale:
            var g = _digit_group(p, gi, ndigits)
            var k = 0
            while k < 4 and produced < dscale:
                var d = (g // 1000) % 10
                if k == 1:
                    d = (g // 100) % 10
                elif k == 2:
                    d = (g // 10) % 10
                elif k == 3:
                    d = g % 10
                chars.append(UInt8(48 + d))
                k += 1
                produced += 1
            gi += 1
    return _strtod_bytes(chars^)


def _strtod_of(s: String) -> Float64:
    """strtod of a static literal (NaN / Infinity specials)."""
    var buf = c_string(s)
    var v = external_call["strtod", Float64](buf, 0)
    c_free(buf)
    return v


def _digit_group(p: CharPtr, gi: Int, ndigits: Int) -> Int:
    """Base-10000 group gi (BE int16 at 8 + 2*gi); 0 past the last digit."""
    if gi < 0 or gi >= ndigits:
        return 0
    return Int(_read_u16_be(p, 8 + 2 * gi))


def _append_group(mut chars: List[UInt8], g: Int):
    """Emit one digit group as exactly 4 decimal chars."""
    chars.append(UInt8(48 + (g // 1000) % 10))
    chars.append(UInt8(48 + (g // 100) % 10))
    chars.append(UInt8(48 + (g // 10) % 10))
    chars.append(UInt8(48 + g % 10))


def decode_i4_array(addr: Int, nbytes: Int32) raises -> List[Int32]:
    """int4[] wire bytes -> List[Int32] (1-D).

    NULL elements are dropped, matching the text-path splitter. A non-1-D
    array raises — the api's array columns are flat.
    """
    var out = List[Int32]()
    if Int(nbytes) < 12:
        raise Error("pqmojo: binary array header truncated")
    var p = CharPtr(unsafe_from_address=addr)
    var ndim = Int(_read_i32_be(p, 0))
    if ndim == 0:
        return out^
    if ndim != 1:
        raise Error(
            "pqmojo: binary int4[] supports 1-D only (got ndim="
            + String(ndim) + ")"
        )
    if Int(nbytes) < 20:
        raise Error("pqmojo: binary array header truncated")
    var n = Int(_read_i32_be(p, 12))
    if n < 0:
        raise Error("pqmojo: binary array negative element count")
    var cursor = 20
    for _ in range(n):
        if cursor + 4 > Int(nbytes):
            raise Error("pqmojo: binary int4[] element header truncated")
        var elen = Int(_read_i32_be(p, cursor))
        cursor += 4
        if elen == -1:
            continue  # NULL element: dropped, parity with the text splitter
        if elen != 4:
            raise Error("pqmojo: binary int4[] element is not 4 bytes")
        if cursor + 4 > Int(nbytes):
            raise Error("pqmojo: binary int4[] element data truncated")
        out.append(_read_i32_be(p, cursor))
        cursor += 4
    return out^


def decode_i8_array(addr: Int, nbytes: Int32) raises -> List[Int64]:
    """int8[] wire bytes -> List[Int64] (1-D).

    Same header layout as int4[]; elements are 8-byte big-endian. NULL
    elements are dropped, parity with every other array reader."""
    var out = List[Int64]()
    if Int(nbytes) < 12:
        raise Error("pqmojo: binary array header truncated")
    var p = CharPtr(unsafe_from_address=addr)
    var ndim = Int(_read_i32_be(p, 0))
    if ndim == 0:
        return out^
    if ndim != 1:
        raise Error(
            "pqmojo: binary int8[] supports 1-D only (got ndim="
            + String(ndim) + ")"
        )
    if Int(nbytes) < 20:
        raise Error("pqmojo: binary array header truncated")
    var n = Int(_read_i32_be(p, 12))
    if n < 0:
        raise Error("pqmojo: binary array negative element count")
    var cursor = 20
    for _ in range(n):
        if cursor + 4 > Int(nbytes):
            raise Error("pqmojo: binary int8[] element header truncated")
        var elen = Int(_read_i32_be(p, cursor))
        cursor += 4
        if elen == -1:
            continue  # NULL element: dropped, parity with the text splitter
        if elen != 8:
            raise Error("pqmojo: binary int8[] element is not 8 bytes")
        if cursor + 8 > Int(nbytes):
            raise Error("pqmojo: binary int8[] element data truncated")
        out.append(bitcast[src_dtype=DType.uint64, src_width=1, dtype=DType.int64](
            Scalar[DType.uint64](_read_u64_be(p, cursor))
        ))
        cursor += 8
    return out^


def decode_text_array(addr: Int, nbytes: Int32) raises -> List[String]:
    """text[] wire bytes -> List[String] (1-D, raw UTF8 element copies).

    Elements are length-prefixed on the wire, so arbitrary UTF8 (commas,
    quotes, backslashes, newlines) decodes with zero unescaping. NULL
    elements are dropped, matching the text-path splitter.
    """
    var out = List[String]()
    if Int(nbytes) < 12:
        raise Error("pqmojo: binary array header truncated")
    var p = CharPtr(unsafe_from_address=addr)
    var ndim = Int(_read_i32_be(p, 0))
    if ndim == 0:
        return out^
    if ndim != 1:
        raise Error(
            "pqmojo: binary text[] supports 1-D only (got ndim="
            + String(ndim) + ")"
        )
    if Int(nbytes) < 20:
        raise Error("pqmojo: binary array header truncated")
    var n = Int(_read_i32_be(p, 12))
    if n < 0:
        raise Error("pqmojo: binary array negative element count")
    var cursor = 20
    for _ in range(n):
        if cursor + 4 > Int(nbytes):
            raise Error("pqmojo: binary text[] element header truncated")
        var elen = Int(_read_i32_be(p, cursor))
        cursor += 4
        if elen == -1:
            continue  # NULL element: dropped, parity with the text splitter
        if elen < 0 or cursor + elen > Int(nbytes):
            raise Error("pqmojo: binary text[] element data truncated")
        if elen == 0:
            out.append(String(""))
        else:
            out.append(String(unsafe_from_utf8=Span(
                unsafe_ptr=CharPtr(
                    unsafe_from_address=Int(p) + cursor
                ),
                length=elen,
            )))
        cursor += elen
    return out^


def exec_binary_on(
    handle: Int, syms: PgSymbols, sql: String, params: List[String]
) raises -> Int:
    """PQexecParams with resultFormat=1; returns the raw PQresult address.

    Param handling is byte-identical to the text path: every param rides
    TEXT (paramFormats=NULL), paramTypes stay NULL so the server infers
    exactly as before. Raises when libpq returns no result at all; result
    STATUS checking is the caller's (strict wrapper) choice.
    """
    if handle == 0:
        raise Error("pqmojo: cannot execute on a closed connection")
    var sql_buf = c_string(sql)
    var n = len(params)

    if n == 0:
        var res0 = syms.exec_params(
            handle, sql_buf, Int32(0), Int(0),
            Int(0), Int(0), Int(0), FORMAT_BINARY
        )
        c_free(sql_buf)
        if res0 == 0:
            raise Error("pqmojo: PQexecParams failed: "
                        + text_of(syms.error_message(handle)))
        return res0

    var addr_arr = Int(external_call["malloc", CharPtr](c_size_t(n * 8)))
    var slots = Pointer[Int64, MutAnyOrigin](unsafe_from_address=addr_arr)
    var bufs = List[CharPtr]()
    for i in range(n):
        var b = c_string(params[i])
        bufs.append(b)
        slots[unsafe_offset=i] = Int64(Int(b))

    var res = syms.exec_params(
        handle, sql_buf, Int32(n), Int(0),
        addr_arr, Int(0), Int(0), FORMAT_BINARY
    )
    for i in range(len(bufs)):
        c_free(bufs[i])
    _ = external_call["free", c_ssize_t](CharPtr(unsafe_from_address=addr_arr))
    c_free(sql_buf)

    if res == 0:
        raise Error("pqmojo: PQexecParams failed: "
                    + text_of(syms.error_message(handle)))
    return res
