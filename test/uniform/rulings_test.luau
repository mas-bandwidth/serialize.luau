--!strict
-- rulings_test.luau — the 2.1.1 rulings of IMPLEMENTING.md (serialize v2.1.1):
-- U9 (one write-misuse mechanism, the trap), U6 (a measure makes every check a
-- write makes, by the same trap, and latches nothing) and U15
-- (serialize_copy_string's exact byte rule, and the exports beyond the
-- reference operations), plus the module hygiene rule that no src module
-- leaks a global.
--
-- This port has no unchecked build, so it is a checked build always and traps
-- in every run (U9). Its trap is a raised Luau error (error()); a trap is not
-- a refusal: the stream records nothing, returns nothing, and the next
-- operation behaves as if the misuse had never happened.

local serialize = require("./serialize")

local T = {}

local function check(cond: any, what: string)
	if not cond then
		error("rulings: " .. what, 2)
	end
end

local function i128(lo: integer, hi: integer): any
	return serialize.Int128.new(lo, hi)
end

-- traps runs op on stream and requires a raise (the trap), then requires that
-- the stream recorded nothing (U9: write misuse never latches), moved no bit,
-- and that the next operation on it succeeds (no later failure).
local function traps(what: string, stream: any, op: (any) -> any)
	local before = stream:bitsProcessed()
	local ok, err = pcall(op, stream)
	check(not ok, what .. ": did not trap (returned " .. tostring(err) .. ", stream error " .. tostring(stream:error()) .. ")")
	check(string.find(tostring(err), "serialize:", 1, true) ~= nil, what .. ": the trap is not serialize's own: " .. tostring(err))
	check(stream:error() == nil and stream:ok(), what .. ": latched " .. tostring(stream:error()))
	check(stream:bitsProcessed() == before, what .. ": moved " .. (stream:bitsProcessed() - before) .. " bits before trapping")
end

-- nextOpWorks requires that a fresh one-bit write on stream succeeds.
local function nextOpWorks(what: string, stream: any)
	check(stream:serializeBits({ value = 1 }, 1) == true, what .. ": a later operation failed after the trap")
end

-- The write misuse U9 names, as operations on a stream with room to spare.
-- Each entry is a name and the operation; every one must trap on a write
-- stream and on a measure stream (U6: every check a write makes except room).
local FLT_MAX = 3.4028234663852886e38
local TOP = 3 * 2 ^ 103 -- [TOP, FLT_MAX] at resolution 2^104: top decode rounds to +inf

local VALUE_MISUSE: { { any } } = {
	{ "int above max", function(s)
		return s:serializeInt({ value = 11 }, 0, 10)
	end },
	{ "int below min", function(s)
		return s:serializeInt({ value = -1 }, 0, 10)
	end },
	{ "int64 above max", function(s)
		return s:serializeInt64({ value = 11i }, 0i, 10i)
	end },
	{ "int128 above max", function(s)
		return s:serializeInt128({ value = i128(11i, 0i) }, i128(0i, 0i), i128(10i, 0i))
	end },
	{ "fixed64 above max", function(s)
		return s:serializeFixed64({ value = 0x100i }, 4, 4, 0i, 15i)
	end },
	{ "fixed128 above max", function(s)
		return s:serializeFixed128({ value = { lo = 0i, hi = 0x1000i } }, 64, 64, 0i, 15i)
	end },
	{ "int_relative current not above previous", function(s)
		return s:serializeIntRelative(5, { value = 5 })
	end },
	{ "int_relative current outside the domain", function(s)
		return s:serializeIntRelative(5, { value = 2147483648 })
	end },
	{ "bits over-wide", function(s)
		return s:serializeBits({ value = 8 }, 3)
	end },
	{ "bits64 over-wide", function(s)
		return s:serializeBits64({ value = 0x10000000000i }, 40)
	end },
	{ "bits64 not an integer", function(s)
		return s:serializeBits64({ value = 5 }, 40)
	end },
	{ "uint8 256", function(s)
		return s:serializeUint8({ value = 256 })
	end },
	{ "uint16 65536", function(s)
		return s:serializeUint16({ value = 65536 })
	end },
	{ "uint32 2^32", function(s)
		return s:serializeUint32({ value = 4294967296 })
	end },
	{ "uint64 a number", function(s)
		return s:serializeUint64({ value = 1 })
	end },
	{ "uint128 not a pair", function(s)
		return s:serializeUint128({ value = 1 })
	end },
	{ "float NaN", function(s)
		return s:serializeFloat({ value = 0 / 0 })
	end },
	{ "float +inf", function(s)
		return s:serializeFloat({ value = math.huge })
	end },
	{ "float above FLT_MAX narrows to inf", function(s)
		return s:serializeFloat({ value = 3.5e38 })
	end },
	{ "float not a number", function(s)
		return s:serializeFloat({ value = "1" })
	end },
	{ "double NaN", function(s)
		return s:serializeDouble({ value = 0 / 0 })
	end },
	{ "double -inf", function(s)
		return s:serializeDouble({ value = -math.huge })
	end },
	{ "compressed_float NaN value", function(s)
		return s:serializeCompressedFloat({ value = 0 / 0 }, 0, 10, 0.01)
	end },
	{ "compressed_float inf value", function(s)
		return s:serializeCompressedFloat({ value = math.huge }, 0, 10, 0.01)
	end },
	{ "compressed_float precomputed NaN value", function(s)
		return s:serializeCompressedFloatPrecomputed({ value = 0 / 0 }, 1000, 10, 10, 0)
	end },
	{ "compressed_float declaration delta / res not finite (0, 1e38, 1e-38)", function(s)
		return s:serializeCompressedFloat({ value = 0 }, 0, 1e38, 1e-38)
	end },
	{ "compressed_float declaration delta not finite (-3e38, 3e38, 1)", function(s)
		return s:serializeCompressedFloat({ value = 0 }, -3e38, 3e38, 1)
	end },
	{ "compressed_float declaration top decode not finite", function(s)
		return s:serializeCompressedFloat({ value = TOP }, TOP, FLT_MAX, 2 ^ 104)
	end },
	{ "compressed_float declaration min >= max", function(s)
		return s:serializeCompressedFloat({ value = 0 }, 1, 1, 0.1)
	end },
	{ "string with a NUL", function(s)
		return s:serializeString({ value = "a\0b" }, 16)
	end },
	{ "string not UTF-8", function(s)
		return s:serializeString({ value = "\xff" }, 16)
	end },
	{ "string a surrogate", function(s)
		return s:serializeString({ value = "\xed\xa0\x80" }, 16)
	end },
	{ "string longer than buffer_size - 1", function(s)
		return s:serializeString({ value = "abcd" }, 4)
	end },
	{ "string buffer_size 0", function(s)
		return s:serializeString({ value = "" }, 0)
	end },
	{ "reject on a write or measure", function(s)
		return s:reject()
	end },
}

-- U9: every write misuse traps at the call, records nothing, moves no bit and
-- leaves the stream usable.
function T.TestU9WriteMisuseTraps()
	for _, case in VALUE_MISUSE do
		local w = serialize.WriteStream.new(buffer.create(64))
		traps("write " .. case[1], w, case[2])
		nextOpWorks("write " .. case[1], w)
	end
end

-- U6: a measure makes every check a write makes, except room, by the same
-- trap, and latches nothing.
function T.TestU6MeasureMisuseTraps()
	for _, case in VALUE_MISUSE do
		local m = serialize.MeasureStream.new()
		traps("measure " .. case[1], m, case[2])
		nextOpWorks("measure " .. case[1], m)
		check(m:bitsProcessed() == 1, "measure " .. case[1] .. ": the measure after the trap counted " .. m:bitsProcessed() .. " bits, not 1")
	end
end

-- U9: an operation that does not fit the room left is write misuse: it traps,
-- before any bit of it is written (U10), and latches nothing.
local ROOM: { { any } } = {
	{ "bits", function(s)
		return s:serializeBits({ value = 1 }, 1)
	end },
	{ "bits64", function(s)
		return s:serializeBits64({ value = 1i }, 33)
	end },
	{ "bool", function(s)
		return s:serializeBool({ value = true })
	end },
	{ "uint8", function(s)
		return s:serializeUint8({ value = 1 })
	end },
	{ "uint16", function(s)
		return s:serializeUint16({ value = 1 })
	end },
	{ "uint32", function(s)
		return s:serializeUint32({ value = 1 })
	end },
	{ "uint64", function(s)
		return s:serializeUint64({ value = 1i })
	end },
	{ "uint128", function(s)
		return s:serializeUint128({ value = i128(1i, 0i) })
	end },
	{ "float", function(s)
		return s:serializeFloat({ value = 1 })
	end },
	{ "double", function(s)
		return s:serializeDouble({ value = 1 })
	end },
	{ "int", function(s)
		return s:serializeInt({ value = 1 }, 0, 10)
	end },
	{ "int64", function(s)
		return s:serializeInt64({ value = 1i }, 0i, 10i)
	end },
	{ "int128", function(s)
		return s:serializeInt128({ value = i128(1i, 0i) }, i128(0i, 0i), i128(10i, 0i))
	end },
	{ "fixed64", function(s)
		return s:serializeFixed64({ value = 1i }, 4, 4, 0i, 15i)
	end },
	{ "fixed128", function(s)
		return s:serializeFixed128({ value = { lo = 1i, hi = 0i } }, 64, 64, 0i, 15i)
	end },
	{ "int_relative", function(s)
		return s:serializeIntRelative(0, { value = 1 })
	end },
	{ "compressed_float", function(s)
		return s:serializeCompressedFloat({ value = 1 }, 0, 10, 0.01)
	end },
	{ "compressed_float precomputed", function(s)
		return s:serializeCompressedFloatPrecomputed({ value = 1 }, 1000, 10, 10, 0)
	end },
	{ "bytes", function(s)
		return s:serializeBytes(buffer.create(1))
	end },
	{ "string", function(s)
		return s:serializeString({ value = "a" }, 16)
	end },
}

function T.TestU9PastEndOnWriteTraps()
	for _, case in ROOM do
		local w = serialize.WriteStream.new(buffer.create(8))
		check(w:serializeBits64({ value = -1i }, 64), "filling the buffer")
		traps("write past the end: " .. case[1], w, case[2])
	end
	-- the whole operation's room is checked first: a string whose length
	-- field fits but whose payload does not writes nothing (U10)
	local w = serialize.WriteStream.new(buffer.create(8))
	check(w:serializeBits({ value = 0 }, 8), "a prefix")
	traps("write string payload past the end", w, function(s)
		return s:serializeString({ value = "abcdefgh" }, 16)
	end)
	check(w:serializeBits({ value = 0 }, 8), "a later write after the trap")
end

-- U9: fail on a write or a measure returns false and records nothing; a
-- nested object returning false on a write or a measure makes the object
-- operation return false and records nothing, and the stream keeps working.
function T.TestU9FailAndFailingObjectRecordNothing()
	local failing = { serialize = function(): boolean
		return false
	end }
	for _, stream in { serialize.WriteStream.new(buffer.create(16)), serialize.MeasureStream.new() } :: { any } do
		local kind = if stream:isReading() then "read" elseif stream.flush ~= nil then "write" else "measure"
		check(stream:fail(serialize.SerializeError.PastEnd) == false, kind .. ": fail did not return false")
		check(stream:ok() and stream:error() == nil, kind .. ": fail recorded " .. tostring(stream:error()))
		check(stream:serializeObject(failing) == false, kind .. ": a failing object did not return false")
		check(stream:ok() and stream:error() == nil, kind .. ": a failing object recorded " .. tostring(stream:error()))
		check(stream:serializeBits({ value = 1 }, 1) == true and stream:bitsProcessed() == 1, kind .. ": the stream stopped working after fail")
	end
end

-- U15 (2.1.1): serialize_copy_string on the source's UTF-8 bytes: the bytes
-- before the first NUL; if more than destSize - 1, the first destSize - 1,
-- then drop bytes from the end while the first byte left out is a
-- continuation byte. Luau strings are byte strings, so the two ill-formed
-- vectors apply. The reference test_copy_string's vectors, every one.
function T.TestU15CopyStringReferenceVectors()
	local vectors: { { any } } = {
		{ "abc", 8, "abc" },
		{ "a\0bc", 8, "a" },
		{ "abcdefghij", 4, "abc" },
		{ "\xC3\xA9\xC3\xA9", 4, "\xC3\xA9" },
		{ "\xC3\xA9\xC3\xA9", 3, "\xC3\xA9" },
		{ "a\xF0\x9F\x98\x80", 3, "a" },
		{ "a\xF0\x9F\x98\x80", 4, "a" },
		{ "a\xF0\x9F\x98\x80", 5, "a" },
		{ "a\xF0\x9F\x98\x80", 6, "a\xF0\x9F\x98\x80" },
		{ "ab\x80\x80", 4, "a" },
		{ "\xC3\xA9\xA9\xA9", 4, "" },
		{ "abc", 1, "" },
		{ "x\xE2\x82\xAC", 4, "x" },
	}
	for _, v in vectors do
		local got = serialize.copyString(v[1], v[2])
		check(got == v[3], string.format("copyString(%q, %d) = %q, want %q", v[1], v[2], got, v[3]))
	end
	-- the result is what serializeString with buffer_size = dest_size accepts
	local text = serialize.copyString("x\xE2\x82\xAC", 4)
	check(serialize.MeasureStream.new():serializeString({ value = text }, 4), "the copy is not accepted at buffer_size = dest_size")
	-- dest_size below 1 is write misuse: the trap
	for _, size in { 0, -1, 0.5, 0 / 0 } do
		local ok, err = pcall(serialize.copyString, "abc", size)
		check(not ok and string.find(tostring(err), "serialize:", 1, true) ~= nil, "copyString dest_size " .. tostring(size) .. " did not trap")
	end
end

-- U15 (2.1.1): the public surface is the reference operations, the three
-- streams, the refusal list and its name function, copyString, the allowed
-- extras and the reference's own public helpers; nothing else is exported
-- from the entry (Luau can hide a name, so it is hidden).
function T.TestU15ExportsOnlyTheAllowedSurface()
	local allowed: { [string]: string } = {
		FORMAT_VERSION = "the format version this library implements",
		SerializeError = "the refusal list (U14)",
		refusalName = "the refusal-name function (U14)",
		WriteStream = "stream",
		ReadStream = "stream",
		MeasureStream = "stream",
		copyString = "serialize_copy_string (U15)",
		Continue = "U15 extra",
		Until = "U15 extra",
		BitWriter = "reference helper",
		BitReader = "reference helper",
		Int128 = "reference 128-bit type",
		Uint128 = "reference 128-bit type",
		bitsRequired = "reference helper",
		bitsRequired64 = "reference helper",
		bitsRequired128 = "reference helper",
		signedToUnsigned = "reference helper",
		unsignedToSigned = "reference helper",
		compressedFloatParams = "reference helper",
	}
	for name in serialize :: any do
		check(allowed[name] ~= nil, "the entry exports " .. tostring(name) .. ", which U15 does not allow")
	end
	for name in allowed do
		check((serialize :: any)[name] ~= nil, "the entry does not export " .. name)
	end
end

-- U15 / the check model: compressedFloatParams is the reference's
-- compressed_float_params, which asserts a finite delta and a finite
-- delta / res; this port traps on them.
function T.TestU15CompressedFloatParamsTrapsNonFinite()
	for _, d in { { 0, 1e38, 1e-38 }, { -3e38, 3e38, 1 }, { 1, 1, 1 }, { 0, 1, 0 } } do
		local ok = pcall(serialize.compressedFloatParams, d[1], d[2], d[3])
		check(not ok, "compressedFloatParams(" .. d[1] .. ", " .. d[2] .. ", " .. d[3] .. ") did not trap")
	end
	local mi, bits = serialize.compressedFloatParams(0, 10, 0.01)
	check(mi == 1000 and bits == 10, "compressedFloatParams(0, 10, 0.01)")
end

-- The read side is untouched by the declaration rulings: a reader with a
-- non-finite compressed_float declaration never traps (U7; the corpus header
-- of compressed_float.txt: "the read path is untouched").
function T.TestU7ReadWithNonFiniteDeclarationNeverTraps()
	local r = serialize.ReadStream.new(buffer.create(8))
	local ok, result = pcall(function()
		return r:serializeCompressedFloat({ value = 0 }, 0, 1e38, 1e-38)
	end)
	check(ok, "the read trapped: " .. tostring(result))
end

-- Module hygiene: no src module assigns a global. A module's globals live in
-- its own environment (Luau's require sandboxes each module), so the test
-- reads that environment through a function the module exports: it must hold
-- no names of its own.
local MODULES = {
	"serialize",
	"serialize_stream",
	"serialize_bitpacker",
	"serialize_bits",
	"serialize_bytes",
	"serialize_compressed_float",
	"serialize_fixed",
	"serialize_float",
	"serialize_int",
	"serialize_int128",
	"serialize_int_relative",
}

local function findFunction(t: any, depth: number): any
	for _, v in t do
		if type(v) == "function" then
			return v
		end
	end
	if depth > 0 then
		for _, v in t do
			if type(v) == "table" then
				local f = findFunction(v, depth - 1)
				if f ~= nil then
					return f
				end
			end
		end
	end
	return nil
end

local requireModule: (string) -> any = require :: any

function T.TestNoModuleLeaksAGlobal()
	local leaks = {}
	for _, name in MODULES do
		local module = requireModule("./" .. name)
		local f = findFunction(module, 2)
		check(f ~= nil, name .. ": exports no function to read its environment through")
		local env = (getfenv :: any)(f)
		for key in env do
			table.insert(leaks, name .. ".luau: " .. tostring(key))
		end
	end
	check(#leaks == 0, "global leaks: " .. table.concat(leaks, ", "))
end

return T
