--!strict
-- smoke_test.luau — TestSmoke, the skeleton's test (DESIGN.md (a), (f), (g),
-- (h) and (i)). It stays green as the family cards land: it names only the
-- API and the stream machinery this card implements, and proves the lazy
-- dispatch through a test-only family name no card creates.

local T = {}

-- The API table DESIGN.md (a) lists, entry fields first.
local ENTRY = {
	"FORMAT_VERSION", "SerializeError",
	"WriteStream", "ReadStream", "MeasureStream",
	"BitWriter", "BitReader", "Int128", "Uint128",
	"bitsRequired", "bitsRequired64", "bitsRequired128",
	"signedToUnsigned", "unsignedToSigned",
	"compressedFloatParams", "Continue", "Until",
}

-- Every stream carries every one of these (Go's Stream interface plus the
-- precomputed compressed float, in serialize.js's spelling).
local METHODS = {
	"reset", "isWriting", "isReading", "error", "ok",
	"serializeBits", "serializeBits64",
	"serializeInt", "serializeInt64", "serializeInt128", "serializeUint128",
	"serializeFixed64", "serializeFixed128",
	"serializeUint8", "serializeUint16", "serializeUint32", "serializeUint64",
	"serializeBool", "serializeFloat", "serializeDouble",
	"serializeCompressedFloat", "serializeCompressedFloatPrecomputed",
	"serializeBytes", "serializeString",
	"serializeAlign", "serializeEnd", "serializeObject", "serializeIntRelative", "reject",
	"alignBits", "bitsProcessed", "bytesProcessed",
	"setContext", "context",
}

-- The write stream alone also carries these.
local WRITE_ONLY = { "flush", "data", "bitsAvailable" }

local function check(cond: boolean, what: string)
	if not cond then
		error("TestSmoke: " .. what, 2)
	end
end

local function raises(f: () -> (), want: string): string
	local ok, err = pcall(f)
	check(not ok, "expected a raise containing " .. want)
	local msg = tostring(err)
	check(string.find(msg, want, 1, true) ~= nil, "raise was " .. msg .. ", want it to contain " .. want)
	return msg
end

function T.TestSmoke()
	-- The entry loads: the shadowing serialize_stream.luau the runner planted
	-- one level above the unit (the working directory) raises if loaded, so a
	-- successful require is the proof it was not.
	local serialize = require("./serialize")
	check(type(serialize) == "table", "the entry returns a table")
	check(table.isfrozen(serialize), "the entry table is frozen")

	-- Every API name DESIGN.md (a) lists exists.
	for _, name in ENTRY do
		check(serialize[name] ~= nil, "entry name " .. name .. " exists")
	end
	check(serialize.FORMAT_VERSION == "2.0", "format version 2.0")
	-- The closed list of refusal reasons, spelled exactly as STANDARD.md,
	-- Refusal reasons spells them, and nothing else.
	local REASONS = {
		PastEnd = "past_end",
		ValueOutOfRange = "value_out_of_range",
		NonzeroPadding = "nonzero_padding",
		TrailingData = "trailing_data",
		NonFiniteFloat = "non_finite_float",
		InvalidUtf8 = "invalid_utf8",
		EmbeddedNul = "embedded_nul",
		NonCanonical = "non_canonical",
		Rejected = "rejected",
	}
	local listed = 0
	for key, value in serialize.SerializeError do
		check(REASONS[key] == value, "SerializeError." .. tostring(key) .. " is " .. tostring(value) .. ", not a reason the standard lists")
		listed += 1
	end
	check(listed == 9, "SerializeError lists the nine reasons, and no others")
	check(serialize.WriteStream.serializeWideString == nil, "wstring is gone (format 2.0)")

	local w = serialize.WriteStream.new(buffer.create(16))
	local r = serialize.ReadStream.new(buffer.create(0))
	local m = serialize.MeasureStream.new()
	for _, s in { w, r, m } do
		for _, name in METHODS do
			check(type((s :: any)[name]) == "function", "stream method " .. name .. " exists")
		end
	end
	for _, name in WRITE_ONLY do
		check(type((w :: any)[name]) == "function", "write stream method " .. name .. " exists")
	end
	check(w:isWriting() and not w:isReading(), "write stream modes")
	check(r:isReading() and not r:isWriting(), "read stream modes")
	check(m:isWriting() and not m:isReading(), "measure stream modes")

	-- A write buffer that is not a multiple of 8 bytes is API misuse: raised,
	-- naming the rule (serialize.go panicBufferBytes).
	raises(function()
		serialize.WriteStream.new(buffer.create(5))
	end, "serialize: bit writer buffer size must be a multiple of 8 bytes")

	-- THE LAZY DISPATCH: a family whose file is absent raises its
	-- not-implemented error by name, on the first call that needs it.
	raises(function()
		require("./serialize_stream").family("smoke_absent")
	end, "serialize: smoke_absent not implemented")
	-- A family name that is not a module name never reaches require.
	raises(function()
		require("./serialize_stream").family("../serialize_stream")
	end, "is not a family module name")
	-- A present family file loads, from the unit directory, once.
	local present = require("./serialize_stream").family("smoke_present")
	check(present.marker == "smoke_present from the unit", "the present family loads from the unit")
	check(require("./serialize_stream").family("smoke_present") == present, "a family loads once")

	-- THE LATCH (DESIGN.md (g); STANDARD.md, Reader Obligations): on a
	-- ReadStream over empty data a failing call latches; a later call fails,
	-- consumes nothing and leaves its holder unchanged.
	check(r:ok() and r:error() == nil, "a fresh read stream is healthy")
	local b = { value = true }
	check(r:serializeBool(b) == false, "a bool read past the end fails")
	check(b.value == true, "the refused read leaves its holder unchanged")
	check(r:error() == serialize.SerializeError.PastEnd, "the failure latches past_end")
	check(not r:ok(), "ok is false once latched")
	local u = { value = 7 }
	check(r:serializeUint32(u) == false, "a later read fails")
	check(u.value == 7, "the later read leaves its holder unchanged")
	check(r:serializeAlign() == false, "an aligned align fails once latched")
	check(r:serializeObject({ serialize = function(_, _): boolean
		error("serializeObject ran its object on a latched stream")
	end }) == false, "serializeObject refuses on a latched stream")
	local more = { value = true }
	check(serialize.Continue(r, more) == false and more.value == true, "Continue stops on a latched stream")
	local done = { value = false }
	check(serialize.Until(r, done) == false and done.value == false, "Until stops on a latched stream")
	check(r:serializeEnd() == false, "an end fails once latched")
	check(r:error() == serialize.SerializeError.PastEnd, "the first reason sticks")
	check(r:bitsProcessed() == 0 and r:bytesProcessed() == 0, "nothing was consumed")
	-- The FIRST reason sticks through an object: the object's inner read
	-- refuses with its own reason, and the object's own failure is an echo
	-- that keeps it.
	local o = serialize.ReadStream.new(buffer.create(1))
	check(o:serializeBits({ value = 0 }, 8), "the object's stream holds one byte")
	check(o:serializeObject({ serialize = function(_, stream): boolean
		return stream:serializeBool({ value = false })
	end }) == false, "an object whose read runs past the end refuses")
	check(o:error() == serialize.SerializeError.PastEnd, "the object's failure keeps the inner reason, not " .. tostring(o:error()))
	-- Reset clears the latch; the context is kept.
	r:setContext("ctx")
	r:reset(buffer.create(0))
	check(r:ok() and r:context() == "ctx", "reset clears the latch and keeps the context")

	-- The measure stream: fixed widths and the conservative align are bit
	-- accounting, no family needed.
	check(m:serializeBool({ value = false }) and m:serializeUint64({ value = 0i }), "measure fixed widths")
	check(m:serializeAlign(), "measure align")
	check(m:bitsProcessed() == 1 + 64 + 7 and m:bytesProcessed() == 9, "measured 72 bits")
	check(m:alignBits() == 7, "measure alignBits is the worst case 7")

	-- The write stream: nothing written yet, so flush and data need no family.
	check(w:bitsAvailable() == 128 and w:bitsProcessed() == 0, "write accounting")
	w:flush()
	check(buffer.len(w:data()) == 0, "an empty write's data is empty")
	check(w:serializeAlign() and w:alignBits() == 0, "an aligned write align writes nothing")

	-- LOADING IS CLOSED (DESIGN.md (f)): the shadow one level above the unit
	-- would raise if it were ever loaded; the control loads it through ../
	-- and sees it raise.
	raises(function()
		(require :: any)("../serialize_stream")
	end, "SHADOW serialize_stream.luau loaded from outside the unit")
end

return T
