# serialize.luau: the design every card copies

serialize.luau ports serialize, the open-source bitpacking serializer, to Luau.
It is the bottom layer under the schema script ports: schema's Luau type wire
calls this library instead of a private bit reader and writer, and vendors
these files unchanged. This page fixes every decision; each family card after
it creates one file and decides nothing. Sections (a) to (i) are the contract.

**The oracle.** serialize.go v1.15.1 (`963f6dfe2327163053301bac16f55bc281902f9a`)
is the reference implementation, matched byte for byte, refusal for refusal.
serialize.js (`ff765a1a89a89dc3f6e818e553baabf189241b4e`) is the closest
worked example and supplies the spelling. Both are read, never imported.

**The vendored standard.** `STANDARD.md` and `conformance/*.txt` are copied
VERBATIM from mas-bandwidth/serialize at tag v1.17.0
(`56a1b590af814474b56ff72b0d05d4be4d7cf41b`). They are the same bytes as
serialize.go v1.15.1's own copies: `diff -r conformance <serialize v1.17.0>/conformance`,
`diff -r conformance <serialize.go v1.15.1>/conformance` and `cmp STANDARD.md
<serialize.go v1.15.1>/STANDARD.md` are all empty (checked 2026-10-17 on hulk).
Neither file is edited here; a change arrives by re-vendoring from a new tag.

**The pin.** Luau 0.741, the same pin as schema's Luau leg (schema
`docs/PORT-LUAU.md`, branch `sprint/schema-luau-port-design.w1.g1.e21`,
`448797ed5e8721783a570a47dd0dde02889624c3`): `make dist-luau`, (i).

## (a) THE API

`local serialize = require("./serialize")` returns a frozen table. Names are
serialize.js's spelling (src/index.js, src/streams.js) of everything
serialize.go v1.15.1 exports. Values move through HOLDERS, `{ value = ... }`,
as serialize.js's refs do: a write reads `holder.value`, a read assigns it only
on success. Every serialize method returns a boolean: `true` on success,
`false` on a refusal.

### Entry fields

| name | serialize.go | family file |
|---|---|---|
| `FORMAT_VERSION` | format version 1.1 | entry (`"1.1"`) |
| `SerializeError` | `ErrOverflow`, `ErrValueOutOfRange`, `ErrAlign` | stream |
| `WriteStream`, `ReadStream`, `MeasureStream` | the three streams | stream |
| `Continue(stream, holder)`, `Until(stream, holder)` | `Continue`, `Until` | stream |
| `BitWriter`, `BitReader` | `BitWriter`, `BitReader` | bitpacker |
| `bitsRequired(min, max)` | `BitsRequired` | bits |
| `bitsRequired64(min, max)` | `BitsRequired64` | bits |
| `signedToUnsigned(n)`, `unsignedToSigned(n)` | `SignedToUnsigned`, `UnsignedToSigned` | bits |
| `Int128`, `Uint128` | `Int128`, `Uint128` and their methods | int128 |
| `bitsRequired128(min, max)` | `BitsRequired128` | int128 |
| `compressedFloatParams(min, max, resolution)` | `CompressedFloatParams` | compressed_float |

`_family(name)` is the lazy loader, exposed for test/smoke only.

### SerializeError: the latched kinds

| kind | value | serialize.go |
|---|---|---|
| `SerializeError.Overflow` | `"overflow"` | `ErrOverflow`: a read past the end of the data, or a write past the end of the buffer |
| `SerializeError.ValueOutOfRange` | `"value_out_of_range"` | `ErrValueOutOfRange`: a value outside the range it is serialized with, and every string refusal |
| `SerializeError.Align` | `"align"` | `ErrAlign`: nonzero padding bits in an align |

`stream:error()` returns the first latched kind or `nil`; `stream:ok()` is
`stream:error() == nil`. The first error sticks; every later call returns
`false`, consumes nothing and writes nothing to its destination (g). Only
`reset` clears it. Deviation: serialize.js's `InvalidString` is absent, because
serialize.go refuses a malformed string with `ErrValueOutOfRange` and Go is the
oracle.

### The streams

`WriteStream.new(buffer)` (the size must be a multiple of 8 bytes, else it
raises), `ReadStream.new(data)` (any length) and `MeasureStream.new()`. Every
stream carries every method below (Go's `Stream` interface plus the precomputed
compressed float, which Go's concrete streams all carry):

| method | holder value | serialize.go |
|---|---|---|
| `reset(buffer)` / `reset(data)` / `reset()` | | `Reset` |
| `isWriting()`, `isReading()` | | `IsWriting`, `IsReading` |
| `error()`, `ok()` | | `Err` |
| `serializeBits(h, bits)` | number in [0,2^32), bits in [1,32] | `SerializeBits` |
| `serializeBits64(h, bits)` | integer, bits in [1,64] | `SerializeBits64` |
| `serializeInt(h, min, max)` | number, int32 | `SerializeInt` |
| `serializeInt64(h, min, max)` | integer; min, max integer | `SerializeInt64` |
| `serializeInt128(h, min, max)` | Int128; min, max Int128 | `SerializeInt128` |
| `serializeUint128(h)` | Int128 pair read unsigned | `SerializeUint128` |
| `serializeFixed64(h, integerBits, fractionBits, min, max)` | integer raw; min, max integer whole units | `SerializeFixed64` |
| `serializeFixed128(h, integerBits, fractionBits, min, max)` | Int128 raw; min, max integer whole units | `SerializeFixed128` |
| `serializeUint8(h)`, `serializeUint16(h)`, `serializeUint32(h)` | number | `SerializeUint8/16/32` |
| `serializeUint64(h)` | integer (the bit pattern) | `SerializeUint64` |
| `serializeBool(h)` | boolean | `SerializeBool` |
| `serializeFloat(h)` | number (a float32 value) | `SerializeFloat32` |
| `serializeDouble(h)` | number | `SerializeFloat64` |
| `serializeCompressedFloat(h, min, max, resolution)` | number | `SerializeCompressedFloat32` |
| `serializeCompressedFloatPrecomputed(h, maxIntegerValue, bits, delta, min)` | number | `SerializeCompressedFloat32Precomputed` |
| `serializeBytes(data)` | a buffer, its whole length | `SerializeBytes` |
| `serializeString(h, bufferSize)` | string (bytes) | `SerializeString` |
| `serializeWideString(h, bufferSize)` | string (UTF-8) | `SerializeWideString` |
| `serializeAlign()` | | `SerializeAlign` |
| `serializeObject(object)` | a table with `serialize(self, stream)` | `SerializeObject` |
| `serializeIntRelative(previous, h)` | number; previous a number | `SerializeIntRelative` |
| `alignBits()`, `bitsProcessed()`, `bytesProcessed()` | | `AlignBits`, `BitsProcessed`, `BytesProcessed` |
| `setContext(v)`, `context()` | | `SetContext`, `Context` |

WriteStream also carries `flush()`, `data()` and `bitsAvailable()` (Go's
`Flush` and `Data`, serialize.js's `bitsAvailable`). `data()` returns a fresh
buffer of `bytesProcessed()` bytes, because a Luau buffer has no slices.

`Continue(stream, more)` serializes `more.value` as one bit and returns it,
`false` as soon as the stream has an error; `Until(stream, done)` is the
inverse polarity. A loop driven by either always terminates on hostile data.

Deviations from serialize.js's spelling, each with its reason:

- `serializeFixed64` and `serializeFixed128`, where serialize.js has one
  `serializeFixed`: Go's two entry points have different holders (integer and
  Int128) and different Q rules (a sum of at most 64, a sum of exactly 128), and
  Go is the oracle.
- `serializeObject`, `serializeCompressedFloatPrecomputed`, `setContext`,
  `context`, `Continue`, `Until`, `Int128`, `Uint128`,
  `compressedFloatParams` and `signedToUnsigned` exist in Go and not in
  serialize.js; they take serialize.js's casing, except `Continue` and
  `Until`, which keep Go's capital because `until` is a reserved word in Luau.
- `serializeObject`: `object:serialize(stream)` returns `true`, or `false` and
  optionally the caller's own error value. On `false` the stream latches that
  value, or the string `"object"` when none is given: serialize.go latches
  the caller's error, and a latch must hold something.
- Int128 and Uint128 operations are functions on the class tables, never
  operators, and the bitwise ones are spelled `band`, `bor`, `bxor`, `bnot`,
  because `and`, `or` and `not` are Luau keywords (the `integer` library's
  own names): `from64, int64, uint64, int128, uint128, isZero, isNegative,
  len, cmp, add, sub, mul, divMod, div, mod, neg, bnot, band, bor, bxor, lsh,
  rsh`, plus `new(lo, hi)`. Every operation returns a fresh pair.

API misuse raises, naming the rule, with serialize.go's panic text
(`serialize: bits must be in [1,32]`, `serialize: min must not be greater than
max`, ...), and a non-finite compressed float value on write (`serialize:
compressed float value must be finite`, STANDARD.md compressed_float, see
(e)), on every stream in every state, even after an error has latched,
because Go's panic check comes before its error check. A holder value or a
parameter that serialize.go's parameter TYPE could not hold (a non-integer, a
number outside the Go type's domain, a value of the wrong Luau type) is the
Luau form of a Go compile error: it raises `serialize: <method> <name> must be
<type>`. A value the type holds but the operation refuses (outside
`[min,max]`, a string too long for its buffer) latches, exactly where Go
latches.

## (b) BIT ORDER AND ENDIANNESS

Exactly as C++ and Go. STANDARD.md, General Conventions, quoted:

> All multi-byte quantities are **little-endian**.
>
> The stream is accumulated in a **64-bit scratch word**. Bits are packed
> **least-significant-bit first**: the first value written occupies the lowest
> bits of the first word. When the scratch fills, the 64-bit word is copied to
> the buffer in host byte order on little-endian machines, and byte-swapped on
> big-endian machines. The result is the same bytes on the wire everywhere.
>
> A value of `n` bits, written when the scratch already holds `s` bits, occupies
> bits `[s, s+n)` of the current word. A value that would cross the 64-bit
> boundary is split: the low `64-s` bits complete the current word, and the
> remainder begins the next.
>
> **Flush.** After the final value, any partially filled scratch word is written
> out. The stream therefore always occupies a whole number of 8-byte words in the
> writer's buffer, but the meaningful length is the number of bytes actually
> required, rounded up to a byte.

The rules for this library:

- The scratch is one 64-bit word; in Luau it is an `integer`, and each word is
  stored as 8 little-endian bytes with `buffer.writeinteger` (a `buffer` is
  little-endian by definition, so no store consults the host).
- `bits > 32` is written as the low 32 bits first, as a 32-bit group, then the
  `bits - 32` high bits (STANDARD.md bits); `serializeUint64` is the low 32
  then the high 32.
- A uint128 or Int128 offset is the low 64-bit half first, then the high half,
  each half as `serialize_bits(half, 64)` (STANDARD.md uint128, int128).
- `flush()` writes out the partial word. `bytesProcessed()` is
  `(bitsProcessed() + 7) // 8`, the meaningful length.
- Trailing bits: the writer writes zero (the flushed scratch beyond the bit
  index is zero by construction); a reader never looks at them (STANDARD.md,
  Reader Obligations, Trailing bits).
- `alignBits()` is `(8 - bit_index % 8) % 8`; an aligned align writes
  nothing.

## (c) THE NUMBER MODEL

Restated from schema docs/PORT-LUAU.md, 64-BIT AND 128-BIT INTEGERS, with no
change of substance:

- Luau numbers are doubles. A value of 32 bits or fewer (bits, int, uint8,
  uint16, uint32, int_relative, a quantized compressed float, a length) is a
  number holding an exact integer.
- A 64-bit value is Luau 0.741's native `integer`: a value, not an object, holding
  every 64-bit pattern, with `i`-suffixed literals (`5i`, `0xffffffffffffffffi`
  is the pattern of -1). Arithmetic operators do NOT apply to integers; the
  `integer` library does (`add sub mul div udiv rem urem band bor bxor bnot
  lshift rshift arshift lt le ult ule gt ge ugt uge tonumber create ...`). A
  shift count is itself an integer (`integer.rshift(v, 32i)`). An unsigned
  64-bit value (uint64, `serializeBits64`, the raw lanes) is its bit pattern in
  an integer, compared with `ult`/`ule`; signed values (int64, fixed raw) use
  `lt`/`le`. Never spell an unsigned value in decimal: `integer.fromstring`
  saturates at int64's maximum; use the hex pattern.
- A 128-bit value is the pair `{ lo: integer, hi: integer }`, the two's
  complement halves, bits 0..63 and 64..127 (Go's `{Lo, Hi}`, schema's
  `Int128`, the wire's own order). Int128 and Uint128 are the same pair read
  signed and unsigned, so `serialize.Int128` and `serialize.Uint128` take and
  return the one type `Int128` (src/serialize_stream.luau exports it).
- A Luau without the `integer` type refuses at require time, by name
  (`serialize: this Luau has no integer type ...`), never later as a wrong
  value. Whether Roblox's shipped Luau has it is not measured here, as in
  schema's page.

## (d) BYTES

Restated from schema docs/PORT-LUAU.md, BYTE BUFFERS: bytes are Luau's
`buffer`, fixed-size, mutable, 0-based, little-endian by definition. The
library uses `buffer.create`, `len`, `readu8 ... readu32`, `writeu8 ...
writeu32`, `readinteger`/`writeinteger` (the 64-bit words), `readf32`,
`readf64`, `writef32`, `writef64`, `copy`, `fill`, `readstring`/`writestring`
and `fromstring`/`tostring` at the edges. A write buffer's length is a
multiple of 8 (the writer stores whole words). A string's payload is its
bytes: `#s` is its byte length; a string holder moves through
`buffer.fromstring` and `buffer.readstring`.

## (e) FLOAT32

Restated from schema docs/PORT-LUAU.md, BYTE BUFFERS (the coordinator's
float32 ruling, 2026-10-17):

- A float32 holder stores a double. A write handed a double that is not
  exactly a float32 converts it THE WAY serialize.go's caller does,
  `float32(v)`: round to nearest, ties to even, a finite double past float32's
  range to ±infinity, ±infinity to itself, a NaN as Go converts it. Luau's
  `buffer.writef32` is that conversion; `fround(x)` (write with `writef32`,
  read back) exposes it. No write refuses a double for having more precision
  than a float32.
- A float32 READ never goes through a conversion: the 32 bits come off the
  wire with `_readBits(32)` and become the double by bit surgery (sign,
  rebiased exponent, mantissa shifted left 29, assembled as two u32 halves and
  read back with `readf64`; subnormals exactly, NaN payloads kept). A write of
  a double that is exactly a float32 value (every value a read produced, a NaN
  whose low 29 mantissa bits are zero included) moves its bits back by the
  inverse surgery, so a signalling NaN and its payload survive a round trip;
  every other double goes through `writef32`.
- A double moves by bits too: `writef64` then two `readu32`, and back.
- The same rule narrows the float32 PARAMETERS of compressed_float (`min`,
  `max`, `resolution`, `delta`): each is `fround`ed on entry, as Go's float32
  parameters are.
- compressed_float's arithmetic is float32, emulated by `fround` after every
  float32 operation, in serialize.go's order. Write: `n = fround(fround(v -
  min) / delta)`, clamped with the `not (n >= 0)` / `not (n <= 1)` form, then
  `math.floor(fround(fround(n * fround(maxIntegerValue)) + 0.5))`, then the
  integer clamp to `maxIntegerValue`. The `+ 0.5` is a float32 add: serialize.go
  v1.15.1 write_stream.go:386 is `uint32(math.Floor(float64(float32(n*float32(m))
  + 0.5)))`, and STANDARD.md, compressed_float, says the product rounds to
  float32 before 0.5 is added and "that sum rounds to float32 before the floor"
  (two roundings, so a float64 add is wrong: m = 16777215, n =
  8388609/16777215 writes 8388610 in Go, 8388609 with a float64 add). A
  non-finite input value (NaN, +inf, -inf) RAISES on write, `serialize:
  compressed float value must be finite`, before the latch check and before any
  arithmetic: STANDARD.md, compressed_float, Non-finite inputs are
  non-conforming ("should assert out on write too"), the same rule in the Luau,
  Lua and Squirrel ports. Go clamps a NaN to 0 here; this port does not, the
  one deliberate deviation from serialize.go's write arm, for STANDARD.md's
  ruling. The read and measure arms never see the value and are untouched.
  Read: `fround(fround(fround(i) /
  fround(maxIntegerValue)) * delta)` then `fround(that + min)`. Params:
  `delta = fround(max - min)`, `values = fround(delta / resolution)`, clamped
  to `[1, 4294967040]`, `maxIntegerValue = math.ceil(values)`. Each fround of
  a double operation on float32 operands equals the float32 operation (a double
  carries more than 2p+2 bits), so this is exact; and because the product is
  rounded by its own fround call before anything is added, no multiply-add can
  fuse across it.

## (f) LOADING

Restated from schema docs/PORT-LUAU.md, THE RUNTIME LAYOUT, the Security
paragraph:

- The unit directory REPLACES the module search path; it is never prepended
  to it. Luau's `require` has no search path: a bare name is refused by the
  interpreter, and a `./` path resolves relative to the requiring FILE, never
  the working directory.
- Every require in this library is `"./serialize_<name>"`, naming a module in
  the same directory: never a bare name, never `../`, never an `@alias` (an
  alias comes from a `.luaurc` the unit does not own). The entry requires
  `"./serialize_stream"` as a literal; a family module requires another family
  as a literal `require("./serialize_<name>")`.
- The ONE non-literal require is the stream's family loader
  (src/serialize_stream.luau, `family`): its path is always `"./serialize_" ..
  name`, with `name` matched against `^[a-z][a-z0-9_]*$` before require is
  called, so it cannot spell `../` or an alias. It goes through an `any` cast
  because luau-analyze refuses a require it cannot resolve, and a family file
  is absent until its card lands.
- No native modules load: the pinned interpreter has no `package`, `dofile`,
  `loadfile` or `io` and no C module loader. An embedding host (Virtual Go, the
  space game, lego) resolves `./` against the unit directory alone and refuses
  everything else.
- test/smoke holds it: a shadowing `serialize_stream.luau` planted in the
  working directory, one level above the unit, raises if loaded; the entry
  loads its own, and the control requires the shadow through `../` and sees it
  raise.

## (g) WRITER AND READER

**The writer is STRICT.** It writes exactly serialize.go v1.15.1's bytes for
the same values. It latches `ValueOutOfRange` or `Overflow` exactly where
serialize.go's WriteStream returns `ErrValueOutOfRange` or `ErrOverflow`, and
raises, naming the rule, exactly where serialize.go panics on API misuse (a).
It writes nothing on a refusal: every bounds check is of the whole operation's
width before any bit moves (a refused wide write leaves no dangling low
dword). Where serialize.go decodes a Go string, the Luau writer decodes the
same way: `serializeWideString` walks the bytes as Go's `for range` does
(each invalid byte becomes U+FFFD and advances one byte), and
`serializeString` writes the bytes as given (UTF-8 well-formedness is the
writer's contract, STANDARD.md string, and serialize.go does not check it).

**Reads are forgiving only where serialize.go's are and it is nearly free:**
trailing bits are ignored. Nothing else is forgiven.

**Security trumps** (STANDARD.md, Reader Obligations and Implementation Law):

- Every refusal STANDARD.md and serialize.go state is made: past the end,
  a decoded value outside `[min,max]`, an offset outside its range, nonzero
  align padding, an int_relative reconstruction outside `[0,2147483647]` or
  not greater than previous, a string with a NUL or malformed UTF-8 (a
  hand-written check equal to Go's `utf8.Valid`: overlong forms, surrogates
  D800-DFFF and values past U+10FFFF refused; Luau's `utf8.len` is not used, it
  is not that check), a wide string group above 0xFFFF, a zero group, or an
  unpaired surrogate.
- A refused primitive read leaves its holder unwritten: the value is
  checked, then assigned. A read into a caller's buffer (`serializeBytes`)
  leaves the buffer unspecified, as STANDARD.md allows.
- The stream is terminal after a refusal: the latch (a).
- Hostile bytes never raise. A raise is API misuse only, decided by the
  caller's own arguments, never by data.
- No read goes past the data's end: every read checks `bit_index + n >
  8 * bytes` before it loads, so the reader never indexes a buffer past its
  length (Luau would raise there).

## (h) THE FILE LAYOUT

| file | holds | card |
|---|---|---|
| `src/serialize.luau` | the entry: the API table (a) | serialize-luau-design (this card) |
| `src/serialize_stream.luau` | the three streams: latch, terminality, bit accounting, fixed-width read and measure gates, align, object, Continue, Until, the dispatch and the family loader | serialize-luau-design (this card) |
| `src/serialize_bitpacker.luau` | `BitWriter`, `BitReader` | serialize-luau-bitpacker |
| `src/serialize_bits.luau` | bits, bits64, uint8/16/32/64, bool; `bitsRequired`, `bitsRequired64`, zig-zag | serialize-luau-bits |
| `src/serialize_int.luau` | int, int64 | serialize-luau-int |
| `src/serialize_int128.luau` | int128, uint128; `Int128`, `Uint128`, `bitsRequired128` | serialize-luau-int |
| `src/serialize_fixed.luau` | fixed64, fixed128 | serialize-luau-fixed |
| `src/serialize_int_relative.luau` | int_relative | serialize-luau-int-relative |
| `src/serialize_float.luau` | float, double; `fround` and the float32 surgery | serialize-luau-float |
| `src/serialize_compressed_float.luau` | compressed_float, precomputed; `compressedFloatParams` | serialize-luau-compressed-float |
| `src/serialize_bytes.luau` | bytes, string, wstring | serialize-luau-strings |

Each card adds its tests in its own `test/<name>/` (one directory per card)
and any make target in its own `make/<card>.mk`; no two cards edit one file.
Every family module is `--!strict`, returns a frozen table, cites the
STANDARD.md section (and this page's section) from each function that
implements a rule, and requires only `"./serialize_<name>"` literals of the
families it names below.

### What the stream gives a family arm

An arm receives the stream object `s` and uses only these (all implemented in
src/serialize_stream.luau):

| primitive | stream | what |
|---|---|---|
| `s:_latched(): boolean` | all | an error is latched |
| `s:_fail(kind): false` | all | latch kind (first sticks), return false |
| `s:_available(): number` | all | bits left: `8*len - bit_index` (measure: `math.huge`) |
| `s:_alignBits(): number` | all | `(8 - bit_index % 8) % 8` |
| `s:_writeBits(value: number, bits)` | write | bits in [1,32], value masked, already checked |
| `s:_writeBits64(value: integer, bits)` | write | bits in [1,64], value masked, already checked; low 32 first |
| `s:_writeBytes(src: buffer, offset, count)` | write | an aligned run, already checked |
| `s:_readBits(bits): number` | read | bits in [1,32], already checked |
| `s:_readBits64(bits): integer` | read | bits in [1,64], already checked; low 32 first |
| `s:_readBytes(dst: buffer, offset, count)` | read | an aligned run, already checked |
| `s:_measure(bits): boolean` | measure | add bits; false when latched |
| `s:serializeX(...)` | all | an arm may call the stream's own methods (int_relative's bool and int, string's int and align), exactly as serialize.go does |

### The arms each family exports

For a DISPATCHED method the stream calls `family.write<X>(s, ...)`,
`family.read<X>(s, ...)` or `family.measure<X>(s, ...)` with the method's own
arguments, and returns what the arm returns. The arm does the whole operation
in serialize.go's order: raise on API misuse, refuse on a latched stream, the
refusals, the bounds check of the whole width, then the bits; a read assigns
its holder last.

| family | dispatched arms |
|---|---|
| bits | `writeBits(s, h, bits)`, `readBits`, `measureBits`; `writeBits64(s, h, bits)`, `readBits64`, `measureBits64` |
| int | `writeInt(s, h, min, max)`, `readInt`, `measureInt`; `writeInt64(s, h, min, max)`, `readInt64`, `measureInt64` |
| int128 | `writeInt128(s, h, min, max)`, `readInt128`, `measureInt128` |
| fixed | `writeFixed64(s, h, integerBits, fractionBits, min, max)`, `readFixed64`, `measureFixed64`; the same for `Fixed128` |
| int_relative | `writeIntRelative(s, previous, h)`, `readIntRelative`, `measureIntRelative` |
| compressed_float | `writeCompressedFloat(s, h, min, max, resolution)`, `readCompressedFloat`, `measureCompressedFloat`; `writeCompressedFloatPrecomputed(s, h, maxIntegerValue, bits, delta, min)`, `readCompressedFloatPrecomputed`, `measureCompressedFloatPrecomputed` |
| bytes | `writeBytes(s, data)`, `readBytes`, `measureBytes`; `writeString(s, h, bufferSize)`, `readString`, `measureString`; `writeWideString(s, h, bufferSize)`, `readWideString`, `measureWideString` |

For a FIXED-WIDTH method (no parameters, its width the operation's own) the
split is different. The WRITE arm is the family's, whole:
`family.write<X>(s, h)`. The READ gate is the stream's: refuse when latched,
refuse past the end with `Overflow`, and only then call `family.read<X>(s, h)`,
which reads exactly the width with `_readBits`/`_readBits64`, stores the
value and returns true. The MEASURE arm is the stream's alone (it adds the
width), so the family exports none.

| method | family | arms | width |
|---|---|---|---|
| `serializeBool` | bits | `writeBool`, `readBool` | 1 |
| `serializeUint8`, `16`, `32` | bits | `writeUint8`, `readUint8`, ... | 8, 16, 32 |
| `serializeUint64` | bits | `writeUint64`, `readUint64` | 64 |
| `serializeFloat` | float | `writeFloat`, `readFloat` | 32 |
| `serializeDouble` | float | `writeDouble`, `readDouble` | 64 |
| `serializeUint128` | int128 | `writeUint128`, `readUint128` | 128 |

The stream itself implements `serializeAlign`, `serializeObject`, `Continue`
and `Until`; no family is needed for them.

### The other exports

| family | exports beside the arms |
|---|---|
| bitpacker | `BitWriter`: `new(buffer)`, `reset(buffer)`, `writeBits(value, bits)` (masks, like Go), `writeAlign()`, `writeBytes(data, offset?, count?)`, `flushBits()`, `alignBits()`, `bitsWritten()`, `bitsAvailable()`, `bytesWritten()`, `data()`; `BitReader`: `new(data)`, `reset(data)`, `wouldReadPastEnd(bits)`, `readBits(bits)`, `readAlign()`, `readBytes(data, offset?, count?)`, `alignBits()`, `bitsRead()`, `bitsRemaining()`. Misuse (bits outside [1,32], past the end, unaligned bytes) raises with serialize.go's panic text, as Go's do. `offset` and `count` extend Go's `[]byte` because a buffer has no slices; omitted they are 0 and the buffer's length. The stream calls `new`, `writeBits`, `writeBytes`, `flushBits`, `readBits` and `readBytes` only. |
| bits | `bitsRequired(min, max)` (numbers, the unsigned domain), `bitsRequired64(min, max)` (integers), `signedToUnsigned(n)`, `unsignedToSigned(n)` |
| int128 | `Int128`, `Uint128` (a), `bitsRequired128(min, max)` |
| float | `fround(x)`, `f32bits(x): number` and `f32frombits(u: number): number` (the surgery, (e)) |
| compressed_float | `compressedFloatParams(min, max, resolution): (maxIntegerValue, bits, delta)` |

### Dependencies between families

A literal require of an absent file fails luau-analyze, so a family that
requires another depends on that card: int and int128 require bits (for
`bitsRequired`/`bitsRequired64`); fixed requires bits and int128;
compressed_float requires bits and float. Every family's tests need
bitpacker at run time (the stream packs through it), so every family card
depends on serialize-luau-bitpacker.

## (i) THE RUNNER

- `make dist-luau` fetches the luau-lang release `luau-ubuntu.zip`
  (https://github.com/luau-lang/luau/releases/download/0.741/luau-ubuntu.zip),
  REFUSES by name any archive whose sha256 is not
  `134dc762ad26232af83e43f98dec03ff6030dd3a4452f9408b9d50ccea025503`, before
  anything is unpacked, and unpacks it into `dist/luau-0.741/` (`luau`,
  `luau-analyze`, `luau-ast`, `luau-compile`). dist/ and build/ are gitignored.
  It is setup, run once, never from a test.
- `$LUAU` overrides the interpreter and `$LUAU_ANALYZE` the analyzer;
  `make toolchain-luau` refuses by name a pin that does not resolve.
- `make test` runs `luau-analyze` over `src/*.luau` (every src file is
  `--!strict`) and fails on any error, then runs every `test/*/`;
  `make test T=<name>` runs `test/<name>/` only.
- The `luau` CLI has no `io`, so the runner is a host shim,
  `tools/luaurun` (Go, standard library only, its own go.mod). For each
  `test/<name>/` it builds `build/run/<name>/`: the working directory the
  interpreter runs in, holding every file of `test/<name>/plant/` (planted one
  level above the unit, for the loading tests) and the unit `src/`, which holds
  a copy of `src/*.luau`, the `.luau` files of `test/<name>/`, `inputs.luau`
  (every `conformance/*.txt` as a string, keyed by base name:
  `require("./inputs").bool` is conformance/bool.txt) and the driver
  `_luaurun.luau`. It runs the pinned interpreter there and passes its stdout
  through.
- A test file is `test/<name>/<x>_test.luau`, `--!strict`, returning a table
  of functions named `Test<Name>`; a test fails by raising. The driver runs
  each in sorted order and prints `RUN Test<Name>`, then `--- PASS
  Test<Name>` or `--- FAIL Test<Name>` with the raise indented below. The
  runner exits nonzero on a FAIL, on an interpreter that exits nonzero, on a
  directory that runs no test, and on a missing or empty `test/<name>/`,
  naming it (`FAIL test/nosuch/ is missing`): never a skip. Its last line is
  `ok N test directories` or `FAIL k of N test directories`.
- Tests use no real time, no sockets, no network and no outside services; a
  test clock, where one is ever needed, is an argument starting at 1000.0.
- Conformance: a later card reads the vectors from `inputs.luau` and checks
  every record, byte for byte and refusal for refusal, against this library
  (STANDARD.md, The vector format).
