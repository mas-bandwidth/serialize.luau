--!strict
-- uniform_test.luau — the uniform rules of IMPLEMENTING.md (U1 to U16,
-- serialize standard 2.1), one test per rule this port proves, each citing its
-- number, and the 2026-10-27 audit findings (AUDIT-LEDGER.md, luau). The read
-- side never raises: caller misuse on a read stream refuses value_out_of_range
-- (U7, U16), the failure state checked first. The write and measure side keeps
-- this port's write-misuse mechanism: a raise naming the rule (DESIGN.md (a)).

local serialize = require("./serialize")

local T = {}

local reasons = serialize.SerializeError
local OUT = reasons.ValueOutOfRange

local function check(cond: any, what: string)
	if not cond then
		error("uniform: " .. what, 2)
	end
end

local function raises(f: () -> any, want: string)
	local ok, err = pcall(f)
	check(not ok, "expected a raise containing " .. want)
	check(string.find(tostring(err), want, 1, true) ~= nil, "raise was " .. tostring(err) .. ", want " .. want)
end

-- refuses runs one read on a fresh stream of eight 0xFF bytes and requires a
-- refusal as value_out_of_range, never a raise, no bits consumed and the holder
-- unwritten; then the same read on a stream already refused as rejected keeps
-- rejected (U7: the failure state is checked first).
local function refuses(what: string, read: (any, any) -> any)
	local data = buffer.create(8)
	buffer.fill(data, 0, 0xFF)
	local r = serialize.ReadStream.new(data)
	local h: any = { value = 99 }
	local ok, result = pcall(read, r, h)
	check(ok, what .. ": raised on read: " .. tostring(result))
	check(result == false, what .. ": the read was accepted")
	check(r:error() == OUT, what .. ": refused as " .. tostring(r:error()) .. ", not value_out_of_range")
	check(r:bitsProcessed() == 0, what .. ": consumed " .. r:bitsProcessed() .. " bits")
	check(h.value == 99, what .. ": wrote its holder")
	local again = serialize.ReadStream.new(data)
	again:reject()
	local ok2, result2 = pcall(read, again, { value = 99 })
	check(ok2 and result2 == false and again:error() == reasons.Rejected, what .. ": a failed stream did not keep its first reason")
end

local function i128(lo: integer, hi: integer): any
	return serialize.Int128.new(lo, hi)
end

-- U1: a write buffer is a multiple of 8 bytes, checked where write misuse is.
function T.TestU1WriteBufferMultipleOf8()
	raises(function()
		return serialize.WriteStream.new(buffer.create(12))
	end, "multiple of 8 bytes")
	raises(function()
		local w = serialize.WriteStream.new(buffer.create(8))
		w:reset(buffer.create(4))
	end, "multiple of 8 bytes")
end

-- U3, U4: the writer and the measure refuse text a reader would refuse, for
-- the reader's reason, NUL first; nothing differing from the value is sent.
function T.TestU3MeasureStringRefusesWhatTheWriterRefuses()
	for _, case in { { "a\0b", reasons.EmbeddedNul }, { "\xff", reasons.InvalidUtf8 }, { "\xed\xa0\x80", reasons.InvalidUtf8 } } do
		local w = serialize.WriteStream.new(buffer.create(16))
		check(w:serializeString({ value = case[1] }, 16) == false and w:error() == case[2], "write latched " .. tostring(w:error()))
		check(w:bitsProcessed() == 0, "the writer sent bits for refused text")
		local m = serialize.MeasureStream.new()
		check(m:serializeString({ value = case[1] }, 16) == false and m:error() == case[2], "measure latched " .. tostring(m:error()) .. ", want " .. case[2])
	end
end

-- U5: int bounds are int32; on read a bound outside int32 refuses.
function T.TestU5IntBoundsAreInt32()
	raises(function()
		return serialize.WriteStream.new(buffer.create(8)):serializeInt({ value = 0 }, -2147483649, 5)
	end, "int32")
	raises(function()
		return serialize.MeasureStream.new():serializeInt({ value = 0 }, 0, 2147483648)
	end, "int32")
	refuses("int min below int32", function(r, h)
		return r:serializeInt(h, -2147483649, 5)
	end)
	refuses("int max above int32", function(r, h)
		return r:serializeInt(h, 0, 2147483648)
	end)
end

-- U7, U16: caller misuse and bad declarations on read refuse
-- value_out_of_range, never raise, before any bit moves.
function T.TestU7ReadNeverTraps()
	refuses("bits 0", function(r, h)
		return r:serializeBits(h, 0)
	end)
	refuses("bits 33", function(r, h)
		return r:serializeBits(h, 33)
	end)
	refuses("bits64 65", function(r, h)
		return r:serializeBits64(h, 65)
	end)
	refuses("int min > max", function(r, h)
		return r:serializeInt(h, 5, 4)
	end)
	refuses("int64 min > max", function(r, h)
		return r:serializeInt64(h, 5i, 4i)
	end)
	refuses("int64 number bounds", function(r, h)
		return r:serializeInt64(h, 0 :: any, 4i)
	end)
	refuses("int128 min > max", function(r, h)
		return r:serializeInt128(h, i128(5i, 0i), i128(4i, 0i))
	end)
	refuses("fixed64 storage past 64", function(r, h)
		return r:serializeFixed64(h, 40, 30, 0i, 1i)
	end)
	refuses("fixed64 bounds outside the Q format", function(r, h)
		return r:serializeFixed64(h, 4, 4, 0i, 16i)
	end)
	refuses("fixed64 fractional integerBits", function(r, h)
		return r:serializeFixed64(h, 4.5, 4, 0i, 1i)
	end)
	refuses("fixed128 storage not 128", function(r, h)
		return r:serializeFixed128(h, 64, 32, 0i, 1i)
	end)
	refuses("int_relative previous -1", function(r, h)
		return r:serializeIntRelative(-1, h)
	end)
	refuses("int_relative previous 1.5", function(r, h)
		return r:serializeIntRelative(1.5, h)
	end)
	refuses("compressed float min >= max", function(r, h)
		return r:serializeCompressedFloat(h, 1, 1, 0.1)
	end)
	refuses("compressed float resolution 0", function(r, h)
		return r:serializeCompressedFloat(h, 0, 1, 0)
	end)
	refuses("string buffer size 0", function(r, h)
		return r:serializeString(h, 0)
	end)
	refuses("string buffer size 2.5", function(r, h)
		return r:serializeString(h, 2.5)
	end)
	refuses("bytes into a non-buffer", function(r, _h)
		return r:serializeBytes({} :: any)
	end)
	refuses("object without serialize", function(r, _h)
		return r:serializeObject({})
	end)
	-- write and measure keep the raise
	raises(function()
		return serialize.WriteStream.new(buffer.create(8)):serializeBits({ value = 0 }, 33)
	end, "bits must be in [1,32]")
	raises(function()
		return serialize.MeasureStream.new():serializeString({ value = "" }, 0)
	end, "string buffer size")
end

-- U8: a value too wide for its bit width is caught on write (this port is
-- always checked), never masked.
function T.TestU8OverWideValuesCaughtOnWrite()
	local function w(): any
		return serialize.WriteStream.new(buffer.create(32))
	end
	raises(function()
		return w():serializeBits({ value = 8 }, 3)
	end, "must fit in bits")
	raises(function()
		return w():serializeBits({ value = -1 }, 8)
	end, "must fit in bits")
	raises(function()
		return w():serializeBits({ value = 1.5 }, 8)
	end, "must fit in bits")
	raises(function()
		return w():serializeBits64({ value = 0x10000000000i }, 40)
	end, "must fit in bits")
	raises(function()
		return w():serializeUint8({ value = 256 })
	end, "serializeUint8 value")
	raises(function()
		return w():serializeUint16({ value = 65536 })
	end, "serializeUint16 value")
	raises(function()
		return w():serializeUint32({ value = 4294967296 })
	end, "serializeUint32 value")
	-- the widest values that fit are written
	local s = w()
	check(s:serializeBits({ value = 7 }, 3) and s:serializeBits64({ value = 0xffffffffffi }, 40), "fitting values")
	check(s:serializeUint8({ value = 255 }) and s:serializeUint32({ value = 4294967295 }), "fitting fixed widths")
	check(s:serializeBits64({ value = -1i }, 64), "all 64 bits")
end

-- U9, U6: fail on a write or measure stream returns false, never raises, and
-- a measure records nothing.
function T.TestU9FailOnWriteAndMeasure()
	local w = serialize.WriteStream.new(buffer.create(8))
	check(w:fail(reasons.PastEnd) == false, "write fail returns false")
	check(w:ok(), "write fail recorded " .. tostring(w:error()))
	local m = serialize.MeasureStream.new()
	check(m:fail(reasons.ValueOutOfRange) == false, "measure fail returns false")
	check(m:ok(), "measure fail recorded " .. tostring(m:error()))
end

-- U12: end on a write or a measure is a no-op returning true.
function T.TestU12EndOnWriteAndMeasure()
	local w = serialize.WriteStream.new(buffer.create(8))
	check(w:serializeBits64({ value = 0i }, 64) and w:serializeBits({ value = 0 }, 1) == false, "the writer latches past_end")
	check(w:serializeEnd() == true and w:bitsProcessed() == 64, "a latched writer's end is not a no-op returning true")
	local m = serialize.MeasureStream.new()
	m:serializeObject({ serialize = function(): boolean
		return false
	end })
	check(m:serializeEnd() == true and m:bitsProcessed() == 0, "a latched measure's end is not a no-op returning true")
end

-- U14: the refusal-name function, "none" for no refusal, and a public fail;
-- on a read, fail with no reason or one outside the closed list records
-- rejected, and an object's error value outside the list latches rejected.
function T.TestU14RefusalNameAndFail()
	check(serialize.refusalName(nil) == "none", "no refusal is none")
	for _, name in { "past_end", "value_out_of_range", "nonzero_padding", "trailing_data", "non_finite_float", "invalid_utf8", "embedded_nul", "non_canonical", "rejected" } do
		check(serialize.refusalName(name) == name, name .. " names itself")
	end
	local r = serialize.ReadStream.new(buffer.create(8))
	check(r:fail() == false and r:error() == reasons.Rejected and serialize.refusalName(r:error()) == "rejected", "fail() records rejected")
	r = serialize.ReadStream.new(buffer.create(8))
	check(r:fail("bogus") == false and r:error() == reasons.Rejected, "fail(bogus) records " .. tostring(r:error()))
	r = serialize.ReadStream.new(buffer.create(8))
	check(r:fail(reasons.TrailingData) == false and r:error() == reasons.TrailingData, "fail(trailing_data)")
	check(r:fail(reasons.PastEnd) == false and r:error() == reasons.TrailingData, "the first reason wins")
	check(r:serializeBits({ value = 0 }, 1) == false and r:bitsProcessed() == 0, "fail is terminal")
	r = serialize.ReadStream.new(buffer.create(8))
	check(r:serializeObject({ serialize = function(): (boolean, string)
		return false, "mine"
	end }) == false and r:error() == reasons.Rejected, "an object's own value latched " .. tostring(r:error()))
	r = serialize.ReadStream.new(buffer.create(8))
	check(r:serializeObject({ serialize = function(): (boolean, string)
		return false, reasons.NonCanonical
	end }) == false and r:error() == reasons.NonCanonical, "an object's closed-list reason is kept")
end

-- U15: serialize_copy_string, the reference helper: at most destSize - 1
-- bytes, stopping at a NUL, cut back to a UTF-8 boundary.
function T.TestU15CopyString()
	check(serialize.copyString("hello world!", 6) == "hello", "truncated to 5 bytes")
	check(serialize.copyString("hi", 16) == "hi", "short source")
	check(serialize.copyString("ab\0cd", 16) == "ab", "stops at a NUL")
	check(serialize.copyString("a\xc3\xa9", 3) == "a", "cut back to a character boundary")
	check(serialize.copyString("a\xc3\xa9", 4) == "a\xc3\xa9", "a whole character fits")
	check(serialize.copyString("x", 1) == "", "destSize 1 holds nothing")
	raises(function()
		return serialize.copyString("x", 0)
	end, "destination size")
end

-- U16 / ledger M: a non-integer bits declaration is refused on every stream
-- before any bit moves (targeted_test TestC_FractionalBitsParam).
function T.TestU16FractionalBits()
	refuses("bits 3.5", function(r, h)
		return r:serializeBits(h, 3.5)
	end)
	refuses("bits64 40.5", function(r, h)
		return r:serializeBits64(h, 40.5)
	end)
	refuses("bits NaN", function(r, h)
		return r:serializeBits(h, 0 / 0)
	end)
	raises(function()
		return serialize.WriteStream.new(buffer.create(8)):serializeBits({ value = 7 }, 3.5)
	end, "bits must be in [1,32]")
	raises(function()
		return serialize.WriteStream.new(buffer.create(8)):serializeBits64({ value = 5i }, 40.5)
	end, "bits must be in [1,64]")
	raises(function()
		return serialize.MeasureStream.new():serializeBits({ value = 7 }, 3.5)
	end, "bits must be in [1,32]")
end

-- U16 / ledger L: precomputed compressed_float constants are checked for
-- what can be checked: max_integer_value an integer in [1, 4294967040], bits
-- exactly bits_required(0, max_integer_value), delta positive and finite; the
-- width check never wraps at 2^32 (targeted_test TestD_PrecomputedBogusConstants).
function T.TestU16PrecomputedConstants()
	local bogus = {
		{ 4294967296, 0, 1 },
		{ -1, 32, 1 },
		{ 4294967041, 32, 1 },
		{ 1.5, 1, 1 },
		{ 0, 0, 1 },
		{ 255, 8, 0 },
		{ 255, 8, math.huge },
		{ 255, 7, 1 },
	}
	for _, c in bogus do
		local what = "precomputed " .. c[1] .. "," .. c[2] .. "," .. c[3]
		refuses(what, function(r, h)
			return r:serializeCompressedFloatPrecomputed(h, c[1], c[2], c[3], 0)
		end)
		raises(function()
			return serialize.WriteStream.new(buffer.create(8)):serializeCompressedFloatPrecomputed({ value = 0 }, c[1], c[2], c[3], 0)
		end, "precomputed compressed float constants")
		raises(function()
			return serialize.MeasureStream.new():serializeCompressedFloatPrecomputed({ value = 0 }, c[1], c[2], c[3], 0)
		end, "precomputed compressed float constants")
	end
	-- the widest legal constants are accepted
	local mi, bits, delta = serialize.compressedFloatParams(0, 4294967040, 1)
	check(mi == 4294967040 and bits == 32, "the clamp's top constants")
	local w = serialize.WriteStream.new(buffer.create(8))
	check(w:serializeCompressedFloatPrecomputed({ value = 0 }, mi, bits, delta, 0), "the top constants write")
end

-- ledger L: a uint128 read into an empty holder assigns the value
-- (targeted_test TestA_Uint128ReadEmptyHolder).
function T.TestLedgerUint128ReadEmptyHolder()
	local data = buffer.create(16)
	buffer.writeu8(data, 0, 7)
	buffer.writeu8(data, 8, 1)
	local r = serialize.ReadStream.new(data)
	local h: any = {}
	check(r:serializeUint128(h), "the read refused " .. tostring(r:error()))
	check(h.value.lo == 7i and h.value.hi == 1i, "the value read is not 7 + 2^64")
end

-- ledger L: a number where a 64-bit integer is required raises serialize's
-- own text naming the rule, never the integer library's raw error
-- (targeted_test TestB_Uint64WriteNumber).
function T.TestLedgerUint64WriteNumber()
	for _, v in { 1.5, -1, 2 ^ 63, 2 ^ 53 + 2, 1 } do
		raises(function()
			return serialize.WriteStream.new(buffer.create(16)):serializeUint64({ value = v })
		end, "serialize: serializeUint64 value must be an integer")
	end
	raises(function()
		return serialize.WriteStream.new(buffer.create(16)):serializeBits64({ value = 2 ^ 40 }, 64)
	end, "serialize: serializeBits64 value must be an integer")
end

return T
