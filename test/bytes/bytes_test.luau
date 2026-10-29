--!strict
-- bytes_test.luau — TestBytesCounted: serializeBytes(data[, offset, count]),
-- the counted form (the reference's serialize_bytes( stream, data, count ),
-- with moo's offset). The count is the caller's declaration and is never
-- written (STANDARD.md bytes), so every counted form must put on the wire
-- exactly the bytes the whole-buffer form puts for the same bytes.

local serialize = require("./serialize")

local T = {}

local function check(cond: any, what: string)
	if not cond then
		error("TestBytesCounted: " .. what, 2)
	end
end

local function sample(n: number): buffer
	local b = buffer.create(n)
	for i = 0, n - 1 do
		buffer.writeu8(b, i, (i * 29 + 3) % 256)
	end
	return b
end

local function slice(b: buffer, off: number, n: number): buffer
	local out = buffer.create(n)
	if n > 0 then
		buffer.copy(out, 0, b, off, n)
	end
	return out
end

local function same(a: buffer, b: buffer): boolean
	return buffer.tostring(a) == buffer.tostring(b)
end

-- writeWith writes bits(3), then the bytes by `put`, then bits(5), and returns
-- the wire.
local function writeWith(put: (any) -> boolean): buffer
	local w = serialize.WriteStream.new(buffer.create(64))
	check(w:serializeBits({ value = 5 }, 3), "writer refused bits")
	check(put(w), "writer refused the bytes")
	check(w:serializeBits({ value = 21 }, 5), "writer refused the trailing bits")
	w:flush()
	return w:data()
end

function T.TestCountedFormWritesTheWholeFormsBytes()
	local src = sample(20)
	for off = 0, 20, 3 do
		for n = 0, 20 - off, 4 do
			local counted = writeWith(function(w: any)
				return w:serializeBytes(src, off, n)
			end)
			local whole = writeWith(function(w: any)
				return w:serializeBytes(slice(src, off, n))
			end)
			check(same(counted, whole), "counted bytes differ from the whole form at offset " .. off .. " count " .. n)
		end
	end
	-- the count alone, and an offset alone, take the stated range
	local a = writeWith(function(w: any)
		return w:serializeBytes(src, nil, 7)
	end)
	check(same(a, writeWith(function(w: any)
		return w:serializeBytes(slice(src, 0, 7))
	end)), "a count alone is the first count bytes")
	local b = writeWith(function(w: any)
		return w:serializeBytes(src, 5)
	end)
	check(same(b, writeWith(function(w: any)
		return w:serializeBytes(slice(src, 5, 15))
	end)), "an offset alone runs to the end")
end

function T.TestCountedFormReadsIntoARange()
	local src = sample(20)
	local wire = writeWith(function(w: any)
		return w:serializeBytes(src, 4, 9)
	end)
	local dst = buffer.create(16)
	local r = serialize.ReadStream.new(wire)
	check(r:serializeBits({ value = 0 }, 3), "reader refused bits")
	check(r:serializeBytes(dst, 2, 9), "reader refused the counted bytes")
	check(same(slice(dst, 2, 9), slice(src, 4, 9)), "counted bytes did not read into the range")
	check(buffer.readu8(dst, 0) == 0 and buffer.readu8(dst, 1) == 0 and buffer.readu8(dst, 11) == 0, "the read wrote outside its range")
	local h = { value = 0 }
	check(r:serializeBits(h, 5) and h.value == 21, "the trailing bits were not 21")
	check(r:serializeEnd(), "the end was refused")
end

function T.TestCountedFormZeroCountStillAligns()
	local counted = writeWith(function(w: any)
		return w:serializeBytes(sample(4), 2, 0)
	end)
	local whole = writeWith(function(w: any)
		return w:serializeBytes(buffer.create(0))
	end)
	check(same(counted, whole), "a zero count did not align like the empty form")
	check(buffer.len(counted) == 2, "a zero count then bits(5) is two bytes, got " .. buffer.len(counted))
end

function T.TestCountedFormMisuse()
	local src = sample(8)
	local bad: { { any } } = { { -1, 1 }, { 9, 0 }, { 0, 9 }, { 4, 5 }, { 0, -1 }, { 0.5, 1 }, { 0, 1.5 }, { "0", 1 }, { 0, "1" } }
	for _, c in bad do
		local off, n = c[1], c[2]
		local w = serialize.WriteStream.new(buffer.create(64))
		local ok = pcall(function()
			w:serializeBytes(src, off, n)
		end)
		check(not ok, "a write with a bad range raised nothing")
		local m = serialize.MeasureStream.new()
		check(not pcall(function()
			m:serializeBytes(src, off, n)
		end), "a measure with a bad range raised nothing")
		local r = serialize.ReadStream.new(sample(16))
		local okr, res = pcall(function()
			return r:serializeBytes(buffer.create(8), off, n)
		end)
		check(okr and res == false, "a read with a bad range raised or accepted")
		check(r:error() == serialize.SerializeError.ValueOutOfRange, "a read with a bad range refused for " .. tostring(r:error()))
	end
end

function T.TestCountedFormPastEndAndMeasure()
	local r = serialize.ReadStream.new(sample(4))
	local ok = r:serializeBytes(buffer.create(8), 0, 5)
	check(not ok and r:error() == serialize.SerializeError.PastEnd, "a count past the data was not past_end")
	local m = serialize.MeasureStream.new()
	check(m:serializeBytes(sample(10), 3, 6), "measure refused")
	check(m:bitsProcessed() == 7 + 48, "measure counted " .. m:bitsProcessed())
	local m2 = serialize.MeasureStream.new()
	check(m2:serializeBytes(sample(10)), "measure refused the whole form")
	check(m2:bitsProcessed() == 7 + 80, "the whole form measured " .. m2:bitsProcessed())
end

return T
