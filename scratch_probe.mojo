from std.reflection import reflect
from std.builtin.rebind import downcast, rebind


trait RowValue(Movable):
    @staticmethod
    def text_cell(tag: Int) raises -> Self: ...


__extension SIMD(RowValue):
    @staticmethod
    def text_cell(tag: Int) raises -> Self:
        comptime if Self.dtype.is_floating_point():
            return Self(Float64(tag).cast[Self.dtype]())
        else:
            return Self(Int64(tag).cast[Self.dtype]())


__extension Bool(RowValue):
    @staticmethod
    def text_cell(tag: Int) raises -> Self:
        return tag % 2 == 0


__extension String(RowValue):
    @staticmethod
    def text_cell(tag: Int) raises -> Self:
        return String("col") + String(tag)


__extension Optional(RowValue):
    @staticmethod
    def text_cell(tag: Int) raises -> Self:
        if tag % 3 == 0:
            return Self()
        var v = downcast[Self.T, RowValue].text_cell(tag)
        return Self(v)


__extension List(RowValue):
    @staticmethod
    def text_cell(tag: Int) raises -> Self:
        comptime assert False, "list probe"


struct Kit(Defaultable, Movable):
    var a: Int64
    var b: String
    var c: Optional[Int32]
    var d: Optional[Int32]
    var e: Bool
    var f: Float64

    def __init__(out self):
        self.a = 0
        self.b = String("")
        self.c = Optional[Int32]()
        self.d = Optional[Int32]()
        self.e = False
        self.f = 0.0


def build_row[T: Defaultable & Movable](base: Int) raises -> T:
    comptime r = reflect[T]
    comptime types = r.field_types()
    var dest = T()
    comptime for i in range(r.field_count()):
        comptime FT = types[i]
        ref field = rebind[downcast[FT, RowValue]](r.field_ref[i](dest))
        field = downcast[FT, RowValue].text_cell(base + i)
    return dest^


def main() raises:
    var k = build_row[Kit](10)
    print(k.a, k.b, k.c, k.d, k.e, k.f)
