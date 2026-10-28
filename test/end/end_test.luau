--!strict
-- end_test.luau — TestSerializeEnd: the end of the object (STANDARD.md end;
-- DESIGN.md (a)). It pins the read order (a failed stream keeps its first
-- reason, then trailing data, then padding), that an accepted end leaves the
-- stream exactly consumed and no bit can be read after it while a zero-bit
-- read still succeeds, and that a writer's end emits nothing and a measure's
-- costs nothing.

local serialize = require("./serialize")

local T = {}

local function check(cond: any, what: string)
	if not cond then
		error("TestSerializeEnd: " .. what, 2)
	end
end

local function bytes(list: { number }): buffer
	local b = buffer.create(#list)
	for i, v in list do
		buffer.writeu8(b, i - 1, v)
	end
	return b
end

function T.TestSerializeEnd()
	local reasons = serialize.SerializeError

	-- the empty object over an empty stream
	local r = serialize.ReadStream.new(buffer.create(0))
	check(r:serializeEnd(), "an empty stream ends")
	check(r:bitsProcessed() == 0, "an empty end consumes nothing")

	-- three bits, then five bits of zero padding: accepted, the whole byte consumed
	r = serialize.ReadStream.new(bytes({ 0x07 }))
	local h = { value = 0 }
	check(r:serializeBits(h, 3) and h.value == 7, "the field's bits are the field's")
	check(r:serializeEnd(), "clean padding ends")
	check(r:bitsProcessed() == 8, "an accepted end leaves the stream at 8 * bytes")
	check(r:serializeBits({ value = 0 }, 1) == false, "no bit can be read after an accepted end")
	check(r:error() == reasons.PastEnd, "a read after the end is past_end")

	-- a zero-bit read still succeeds on an exactly consumed stream
	r = serialize.ReadStream.new(bytes({ 0x07 }))
	check(r:serializeBits({ value = 0 }, 3) and r:serializeEnd(), "three bits and an end")
	local degenerate = { value = 0 }
	check(r:serializeInt(degenerate, 5, 5) and degenerate.value == 5, "a zero-bit read succeeds after an accepted end")

	-- every padding bit alone is nonzero_padding
	for bit = 3, 7 do
		r = serialize.ReadStream.new(bytes({ 0x05 + 2 ^ bit }))
		check(r:serializeBits({ value = 0 }, 3), "padding case " .. bit .. " field")
		check(r:serializeEnd() == false, "padding bit " .. bit .. " was accepted")
		check(r:error() == reasons.NonzeroPadding, "padding bit " .. bit .. " refused for " .. tostring(r:error()))
	end

	-- a whole byte after the object, zero or not, is trailing_data, checked
	-- before the padding: bits 3 then end over 0D 00 is trailing_data
	for _, case in { { 0x00 }, { 0xFF }, { 0x05, 0x00 }, { 0x0D, 0x00 } } do
		r = serialize.ReadStream.new(bytes(case))
		if #case == 2 then
			check(r:serializeBits({ value = 0 }, 3), "trailing case field")
		end
		check(r:serializeEnd() == false, "a trailing byte was accepted")
		check(r:error() == reasons.TrailingData, "a trailing byte refused for " .. tostring(r:error()))
	end

	-- a failed stream refuses its end with the first refusal's reason
	r = serialize.ReadStream.new(bytes({ 0xFF }))
	check(r:serializeInt({ value = 0 }, 0, 4) == false, "an out-of-range int refuses")
	check(r:serializeEnd() == false and r:error() == reasons.ValueOutOfRange, "the end keeps the first reason")

	-- a writer's end emits nothing; a measure's costs nothing; on either it is a
	-- no-op returning true, after a trap too (IMPLEMENTING.md U12; a write
	-- that does not fit traps and latches nothing, U9)
	local w = serialize.WriteStream.new(buffer.create(8))
	check(w:serializeBits({ value = 5 }, 3) and w:serializeEnd(), "a writer ends")
	check(w:bitsProcessed() == 3, "a writer's end wrote bits")
	w:flush()
	check(buffer.len(w:data()) == 1 and buffer.readu8(w:data(), 0) == 0x05, "a writer's end changed the bytes")
	local m = serialize.MeasureStream.new()
	check(m:serializeEnd() and m:bitsProcessed() == 0, "a measure's end cost bits")
	local full = serialize.WriteStream.new(buffer.create(8))
	check(full:serializeUint64({ value = 0i }), "the writer fills")
	check(not pcall(function()
		return full:serializeBool({ value = true })
	end), "a write past the end did not trap")
	check(full:serializeEnd() == true and full:error() == nil and full:bitsProcessed() == 64, "a full writer's end is not a no-op returning true")
end

return T
