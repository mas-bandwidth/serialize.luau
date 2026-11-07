--!strict
-- uniform_test.luau — the uniform rules of IMPLEMENTING.md (U1 to U16,
-- serialize standard 2.1), one test per rule this port proves, each citing its
-- number, and the 2026-10-27 audit findings (AUDIT-LEDGER.md, luau). The read
-- side never raises: caller misuse on a read stream refuses value_out_of_range
-- (U7, U16), the failure state checked first. The write and measure side has
-- one write-misuse mechanism, the trap (U9): a raise naming the rule, which
-- latches nothing (DESIGN.md (a)); test/uniform/rulings_test.luau proves it.

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

-- U3, U4: the writer and the measure trap on text a reader would refuse,
-- naming the reader's reason, NUL first, and latch nothing (U9, U6); nothing
-- differing from the value is sent.
function T.TestU3MeasureStringRefusesWhatTheWriterRefuses()
	for _, case in { { "a\0b", reasons.EmbeddedNul }, { "\xff", reasons.InvalidUtf8 }, { "\xed\xa0\x80", reasons.InvalidUtf8 } } do
		local w = serialize.WriteStream.new(buffer.create(16))
		raises(function()
			return w:serializeString({ value = case[1] }, 16)
		end, case[2])
		check(w:ok() and w:bitsProcessed() == 0, "the writer latched or sent bits for refused text")
		local m = serialize.MeasureStream.new()
		raises(function()
			return m:serializeString({ value = case[1] }, 16)
		end, case[2])
		check(m:ok() and m:bitsProcessed() == 0, "the measure latched or counted refused text")
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
	check(w:serializeBits64({ value = 0i }, 64), "the writer fills")
	raises(function()
		return w:serializeBits({ value = 0 }, 1)
	end, "room left")
	check(w:serializeEnd() == true and w:bitsProcessed() == 64, "a full writer's end is not a no-op returning true")
	local m = serialize.MeasureStream.new()
	check(m:serializeObject({ serialize = function(): boolean
		return false
	end }) == false, "a failing object on a measure did not return false")
	check(m:serializeEnd() == true and m:bitsProcessed() == 0, "a measure's end after a failing object is not a no-op returning true")
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

-- a latched read stream refuses an object before it resolves the object's
-- serialize method: a table whose lookup counts calls sees none, the first
-- reason is kept and nothing is returned but false.
function T.TestReadFailedObjectSkipsLookup()
	local lookups = 0
	local counted = setmetatable({}, {
		__index = function(_, _key: any): any
			lookups += 1
			return function(): boolean
				return true
			end
		end,
	})
	local r = serialize.ReadStream.new(buffer.create(8))
	check(r:fail(reasons.TrailingData) == false, "the first refusal returns false")
	check(r:serializeObject(counted) == false, "a failed stream accepted an object")
	check(lookups == 0, "a failed stream resolved the object's method " .. lookups .. " times")
	check(r:error() == reasons.TrailingData, "the first reason was replaced by " .. tostring(r:error()))
end

-- the same refusal for every reason of the closed list as the first one, and
-- for objects of every shape: none is looked into, and the reason stays.
function T.TestReadFailedObjectSeeds()
	local lookups = 0
	local counted = setmetatable({}, {
		__index = function(_, _key: any): any
			lookups += 1
			return nil
		end,
	})
	local called = false
	local shapes: { any } = {
		counted,
		{},
		{ serialize = 5 },
		{ serialize = function(): boolean
			called = true
			return true
		end },
		"text",
		7,
	}
	for _, reason in
		{
			reasons.PastEnd,
			reasons.ValueOutOfRange,
			reasons.NonzeroPadding,
			reasons.TrailingData,
			reasons.NonFiniteFloat,
			reasons.InvalidUtf8,
			reasons.EmbeddedNul,
			reasons.NonCanonical,
			reasons.Rejected,
		}
	do
		for i, shape in shapes do
			local r = serialize.ReadStream.new(buffer.create(8))
			r:fail(reason)
			check(r:serializeObject(shape) == false, "shape " .. i .. " was accepted after " .. tostring(reason))
			check(r:error() == reason, "shape " .. i .. " replaced " .. tostring(reason) .. " by " .. tostring(r:error()))
		end
	end
	check(lookups == 0, "a failed stream resolved a method " .. lookups .. " times")
	check(not called, "a failed stream ran an object")
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

-- A read stream built or reset over something that is not a buffer is installed
-- already refused as value_out_of_range, never a raise, with no bits and no
-- state left from the stream's earlier input; a later valid reset reads
-- normally.
function T.TestReadInvalidBufferRefused()
	local function valid(): buffer
		local d = buffer.create(8)
		buffer.writeu8(d, 0, 0x2A)
		return d
	end
	local function readsNormally(r: any)
		check(r:ok() and r:error() == nil, "the valid reset left a failure latched")
		local h: any = { value = 0 }
		check(r:serializeBits(h, 8), "the read after a valid reset refused " .. tostring(r:error()))
		check(h.value == 0x2A, "the value read after a valid reset was " .. tostring(h.value))
		check(r:bitsProcessed() == 8, "the bit index after a valid reset was " .. r:bitsProcessed())
	end
	local bad: { any } = { false, 7, "text", {} }
	for _, v in bad do
		local ok, r = pcall(serialize.ReadStream.new, v)
		check(ok, "new over " .. typeof(v) .. " raised: " .. tostring(r))
		check(r:error() == OUT, "new over " .. typeof(v) .. " refused as " .. tostring(r:error()))
		check(r:bitsProcessed() == 0, "new over " .. typeof(v) .. " counted bits")
		local h: any = { value = 99 }
		check(r:serializeBits(h, 8) == false and h.value == 99, "a read on a refused stream was accepted")
		local ok2, err2 = pcall(r.reset, r, valid())
		check(ok2, "valid reset raised: " .. tostring(err2))
		readsNormally(r)
	end
	do
		local ok, r = pcall(serialize.ReadStream.new, nil)
		check(ok, "new over nil raised: " .. tostring(r))
		check(r:error() == OUT and r:bitsProcessed() == 0, "new over nil was not refused")
		r:reset(valid())
		readsNormally(r)
	end
	for _, v in { false, 7, "text", {}, (nil :: any) } do
		local r = serialize.ReadStream.new(valid())
		local h: any = { value = 0 }
		check(r:serializeBits(h, 8), "the first read refused")
		check(r:bitsProcessed() == 8, "the first read moved no bits")
		local ok, err = pcall(r.reset, r, v)
		check(ok, "reset over " .. typeof(v) .. " raised: " .. tostring(err))
		check(r:error() == OUT, "reset over " .. typeof(v) .. " refused as " .. tostring(r:error()))
		check(r:bitsProcessed() == 0, "reset over " .. typeof(v) .. " kept " .. r:bitsProcessed() .. " bits")
		local g: any = { value = 99 }
		check(r:serializeBits(g, 8) == false and g.value == 99, "a read on a refused stream was accepted")
		r:reset(valid())
		readsNormally(r)
	end
end

-- Every public read that takes a holder checks it before any bit moves: nil, a
-- number, a frozen table, a table whose store would reach __newindex and a
-- table whose lookup would reach __index are refused as value_out_of_range,
-- never a raise, with no bits consumed and no metamethod run, and a stream that
-- already failed keeps its first reason. A plain empty table and a table whose
-- `value` is a raw field (metatable or not) are still read into.
function T.TestReadHolderChecked()
	local calls = 0
	local function count(): any
		calls += 1
		return 0
	end
	local bad: { { any } } = {
		{ "nil", function(): any
			return nil
		end },
		{ "number", function(): any
			return 5
		end },
		{ "boolean", function(): any
			return false
		end },
		{ "string", function(): any
			return "holder"
		end },
		{ "frozen table", function(): any
			return table.freeze({ value = 0 })
		end },
		{ "frozen empty table", function(): any
			return table.freeze({})
		end },
		{ "__newindex table", function(): any
			return setmetatable({}, { __newindex = count })
		end },
		{ "__index table", function(): any
			return setmetatable({}, { __index = count })
		end },
		{ "metatable without __index or __newindex", function(): any
			return setmetatable({}, { __tostring = count })
		end },
		{ "protected metatable without a raw field", function(): any
			return setmetatable({}, { __metatable = "locked", __newindex = count })
		end },
	}
	local good: { { any } } = {
		{ "empty table", function(): any
			return {}
		end },
		{ "raw-field table", function(): any
			return setmetatable({ value = 0 }, { __newindex = count, __index = count })
		end },
	}
	local maxInt, bits, delta = serialize.compressedFloatParams(0, 1, 0.1)
	local reads: { { any } } = {
		{ "bits", function(r: any, h: any): any
			return r:serializeBits(h, 8)
		end },
		{ "bits64", function(r: any, h: any): any
			return r:serializeBits64(h, 40)
		end },
		{ "bool", function(r: any, h: any): any
			return r:serializeBool(h)
		end },
		{ "uint8", function(r: any, h: any): any
			return r:serializeUint8(h)
		end },
		{ "uint16", function(r: any, h: any): any
			return r:serializeUint16(h)
		end },
		{ "uint32", function(r: any, h: any): any
			return r:serializeUint32(h)
		end },
		{ "uint64", function(r: any, h: any): any
			return r:serializeUint64(h)
		end },
		{ "uint128", function(r: any, h: any): any
			return r:serializeUint128(h)
		end },
		{ "int", function(r: any, h: any): any
			return r:serializeInt(h, 0, 100)
		end },
		{ "int64", function(r: any, h: any): any
			return r:serializeInt64(h, 0i, 100i)
		end },
		{ "int128", function(r: any, h: any): any
			return r:serializeInt128(h, i128(0i, 0i), i128(100i, 0i))
		end },
		{ "fixed64", function(r: any, h: any): any
			return r:serializeFixed64(h, 8, 8, 0i, 1i)
		end },
		{ "fixed128", function(r: any, h: any): any
			return r:serializeFixed128(h, 64, 64, 0i, 1i)
		end },
		-- a first bit of 1 is previous + 1: zero bits read the absolute tier,
		-- whose 0 is not after previous
		{ "int_relative", function(r: any, h: any): any
			return r:serializeIntRelative(0, h)
		end, 1 },
		{ "compressed float", function(r: any, h: any): any
			return r:serializeCompressedFloat(h, 0, 1, 0.1)
		end },
		{ "compressed float precomputed", function(r: any, h: any): any
			return r:serializeCompressedFloatPrecomputed(h, maxInt, bits, delta, 0)
		end },
		{ "float", function(r: any, h: any): any
			return r:serializeFloat(h)
		end },
		{ "double", function(r: any, h: any): any
			return r:serializeDouble(h)
		end },
		{ "string", function(r: any, h: any): any
			return r:serializeString(h, 16)
		end },
		-- Continue wants a set sentinel bit; Until wants a clear one
		{ "continue", function(r: any, h: any): any
			return serialize.Continue(r, h)
		end, 1 },
		{ "until", function(r: any, h: any): any
			return serialize.Until(r, h)
		end },
	}
	-- data is 32 bytes, zero but for its first byte
	local function data(first: number?): buffer
		local d = buffer.create(32)
		buffer.writeu8(d, 0, first or 0)
		return d
	end
	for _, read in reads do
		local what, f = read[1], read[2]
		for _, holder in bad do
			-- the holder is refused even when the field itself would run past
			-- the end: an empty packet must refuse value_out_of_range, not
			-- past_end, and must still consume nothing
			for _, d in { data(read[3]), buffer.create(0) } do
				local label = what .. " into " .. holder[1]
				local r = serialize.ReadStream.new(d)
				local ok, result = pcall(f, r, holder[2]())
				check(ok, label .. ": raised: " .. tostring(result))
				check(result == false, label .. ": the read was accepted")
				check(r:error() == OUT, label .. ": refused as " .. tostring(r:error()) .. ", not value_out_of_range")
				check(r:bitsProcessed() == 0, label .. ": consumed " .. r:bitsProcessed() .. " bits")
				check(calls == 0, label .. ": ran " .. calls .. " metamethods")
				local again = serialize.ReadStream.new(d)
				again:reject()
				local ok2, result2 = pcall(f, again, holder[2]())
				check(ok2 and result2 == false, label .. ": a failed stream raised or accepted")
				check(again:error() == reasons.Rejected, label .. ": a failed stream did not keep its first reason")
				check(calls == 0, label .. ": ran " .. calls .. " metamethods on a failed stream")
			end
		end
		for _, holder in good do
			local label = what .. " into " .. holder[1]
			local r = serialize.ReadStream.new(data(read[3]))
			local h = holder[2]()
			local ok, result = pcall(f, r, h)
			check(ok, label .. ": raised: " .. tostring(result))
			check(result == true, label .. ": refused " .. tostring(r:error()))
			check(r:bitsProcessed() > 0, label .. ": consumed no bits")
			check(rawget(h, "value") ~= nil, label .. ": the value was not stored")
			check(calls == 0, label .. ": ran " .. calls .. " metamethods")
		end
	end
end

return T
