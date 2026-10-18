--!strict
-- compressed_float_test.luau — TestSerializeCompressedFloat
-- (serialize-luau-compressed-float): the compressed_float family (DESIGN.md
-- (a), (e), (g) and (h); STANDARD.md, Floating Point, "compressed_float").
--
-- It pins:
--   1. every record of conformance/compressed_float.txt as a reader must:
--      accepted vectors decode bit-exactly and consume exactly `consumed`
--      bits; refused vectors leave the destination untouched and the stream
--      terminal. The record count is printed and must equal the file's count;
--   2. the writer's integer clamp witnesses (STANDARD.md compressed_float,
--      "The integer clamp is normative"): [0, 8388609] and [0, 16777215] at
--      resolution 1, writing max, emit the largest legal code, not one past;
--   3. the writer's two-roundings witnesses (STANDARD.md compressed_float):
--      over [0,10] at resolution 0.01, 0.005 -> 1, 0.025 -> 3, 0.105 -> 11
--      and 9.995 -> 1000 (a widened writer yields 0, 2, 10, 999);
--   4. serialize.go's TestCompressedFloatValidation misuse rules: min >= max
--      or resolution <= 0 raises; bad precomputed constants raise; a
--      non-finite write raises.

local serialize = require("./serialize")
local WriteStream = serialize.WriteStream
local ReadStream = serialize.ReadStream
local BitReader = serialize.BitReader

local T = {}

local function raises(f: () -> (), want: string): string
	local ok, err = pcall(f)
	if ok then
		error("expected a raise containing " .. want, 2)
	end
	local msg = tostring(err)
	if string.find(msg, want, 1, true) == nil then
		error("raise was " .. msg .. ", want it to contain " .. want, 2)
	end
	return msg
end

local function f32bits(x: number): number
	local b = buffer.create(4)
	buffer.writef32(b, 0, x)
	return buffer.readu32(b, 0)
end

local function hexBytes(s: string): { number }
	if s == "" then
		return {}
	end
	local out = {}
	for b in s:gmatch("%x%x") do
		out[#out + 1] = tonumber(b, 16)
	end
	return out
end

local function bytesToBuffer(bytes: { number }): buffer
	local n = #bytes
	local out = buffer.create(n)
	for i = 1, n do
		buffer.writeu8(out, i - 1, bytes[i])
	end
	return out
end

local function parseRecords(text: string): { any }
	local records = {}
	local current = nil
	for line in (text .. "\n"):gmatch("(.-)\n") do
		local trimmed = line:match("^%s*(.-)%s*$")
		if trimmed == "" then
			current = nil
		elseif trimmed:sub(1, 1) ~= "#" then
			if current == nil then
				current = {}
				records[#records + 1] = current
			end
			local key, val = trimmed:match("^(%S+)%s+(.+)$")
			if key == nil then
				key = trimmed
				val = ""
			end
			if key == "operation" then
				current.op = val
			elseif key == "name" then
				current.name = val
			elseif key == "param" then
				local pn, pv = val:match("^(%S+)%s*=%s*(.+)$")
				current[pn] = tonumber(pv)
			elseif key == "bytes" then
				current.bytesText = val
			elseif key == "expect" then
				if val == "refused" then
					current.refused = true
				else
					current.expectBits = tonumber(val:match("0x(%x+)"), 16)
				end
			elseif key == "consumed" then
				current.consumed = tonumber(val)
			end
		end
	end
	return records
end

local function runRecord(rec: any)
	local buf = bytesToBuffer(hexBytes(rec.bytesText))
	local rs = ReadStream.new(buf)
	local sentinel = 12345.678
	local h = { value = sentinel }
	local ok = rs:serializeCompressedFloat(h, rec.min, rec.max, rec.res)
	if rec.refused then
		if ok then
			error("expected refusal for " .. rec.name)
		end
		if h.value ~= sentinel then
			error("refusal changed destination for " .. rec.name)
		end
		local bitsBefore = rs:bitsProcessed()
		local h2 = { value = 777.0 }
		local ok2 = rs:serializeCompressedFloat(h2, rec.min, rec.max, rec.res)
		if ok2 then
			error("stream not terminal after refusal for " .. rec.name)
		end
		if rs:bitsProcessed() ~= bitsBefore then
			error("terminal read consumed bits for " .. rec.name)
		end
		if h2.value ~= 777.0 then
			error("terminal read wrote destination for " .. rec.name)
		end
	else
		if not ok then
			error("expected accept for " .. rec.name .. ": " .. tostring(rs:error()))
		end
		if rs:bitsProcessed() ~= rec.consumed then
			error("consumed mismatch for " .. rec.name .. ": " .. rs:bitsProcessed() .. " ~= " .. rec.consumed)
		end
		local got = f32bits(h.value)
		if got ~= rec.expectBits then
			error("bits mismatch for " .. rec.name .. ": " .. string.format("0x%08X", got) .. " ~= " .. string.format("0x%08X", rec.expectBits))
		end
	end
end

local EXPECTED_RECORDS = 29

local function testConformance()
	local text = require("./inputs").compressed_float
	local records = parseRecords(text)
	print("compressed_float records: " .. #records)
	if #records ~= EXPECTED_RECORDS then
		error("record count " .. #records .. " != " .. EXPECTED_RECORDS)
	end
	for _, rec in ipairs(records) do
		runRecord(rec)
	end
end

-- The writer's integer clamp witnesses (STANDARD.md compressed_float): writing
-- max emits exactly max_integer_value, the largest legal code.
local function testTopOfRangeClamp()
	local w = WriteStream.new(buffer.create(8))
	if not w:serializeCompressedFloat({ value = 8388609 }, 0, 8388609, 1) then
		error("clamp witness 8388609 write failed", 2)
	end
	w:flush()
	local d = w:data()
	if buffer.len(d) ~= 3 or buffer.readu8(d, 0) ~= 0x01 or buffer.readu8(d, 1) ~= 0x00 or buffer.readu8(d, 2) ~= 0x80 then
		error("clamp witness [0,8388609] bytes wrong", 2)
	end

	local w2 = WriteStream.new(buffer.create(8))
	if not w2:serializeCompressedFloat({ value = 16777215 }, 0, 16777215, 1) then
		error("clamp witness 16777215 write failed", 2)
	end
	w2:flush()
	local d2 = w2:data()
	if buffer.len(d2) ~= 3 or buffer.readu8(d2, 0) ~= 0xFF or buffer.readu8(d2, 1) ~= 0xFF or buffer.readu8(d2, 2) ~= 0xFF then
		error("clamp witness [0,16777215] bytes wrong", 2)
	end
end

-- The writer's two-roundings witnesses over [0,10] at resolution 0.01.
local function testWriterTwoRoundings()
	local cases = {
		{ 0.005, 1 },
		{ 0.025, 3 },
		{ 0.105, 11 },
		{ 9.995, 1000 },
	}
	for _, c in cases do
		local w = WriteStream.new(buffer.create(8))
		if not w:serializeCompressedFloat({ value = c[1] }, 0, 10, 0.01) then
			error("two-roundings write failed for " .. c[1], 2)
		end
		w:flush()
		local code = BitReader.new(w:data()):readBits(10)
		if code ~= c[2] then
			error("two-roundings code for " .. c[1] .. " = " .. code .. ", want " .. c[2], 2)
		end
	end
end

-- serialize.go's TestCompressedFloatValidation misuse rules: raises, naming the
-- rule (DESIGN.md (a) and (g)).
local function testValidation()
	raises(function()
		local w = WriteStream.new(buffer.create(8))
		w:serializeCompressedFloat({ value = 0 }, 10, 0, 1)
	end, "compressed float requires min < max and resolution > 0")

	raises(function()
		local w = WriteStream.new(buffer.create(8))
		w:serializeCompressedFloat({ value = 0 }, 0, 10, 0)
	end, "compressed float requires min < max and resolution > 0")

	raises(function()
		local w = WriteStream.new(buffer.create(8))
		w:serializeCompressedFloat({ value = 0 }, 0, 10, -1)
	end, "compressed float requires min < max and resolution > 0")

	-- precomputed constants that are not exactly what CompressedFloatParams
	-- derives, on the write stream: wrong bits, wrong delta, zero max.
	raises(function()
		local w = WriteStream.new(buffer.create(8))
		w:serializeCompressedFloatPrecomputed({ value = 5 }, 1000, 9, 10.0, 0)
	end, "precomputed compressed float constants must be exactly what CompressedFloatParams derives")

	raises(function()
		local w = WriteStream.new(buffer.create(8))
		w:serializeCompressedFloatPrecomputed({ value = 5 }, 1000, 10, 0.0, 0)
	end, "precomputed compressed float constants must be exactly what CompressedFloatParams derives")

	raises(function()
		local w = WriteStream.new(buffer.create(8))
		w:serializeCompressedFloatPrecomputed({ value = 5 }, 1000, 10, -10.0, 0)
	end, "precomputed compressed float constants must be exactly what CompressedFloatParams derives")

	raises(function()
		local w = WriteStream.new(buffer.create(8))
		w:serializeCompressedFloatPrecomputed({ value = 5 }, 0, 10, 10.0, 0)
	end, "precomputed compressed float constants must be exactly what CompressedFloatParams derives")

	-- the same precomputed validation on the read and measure streams.
	raises(function()
		local r = ReadStream.new(buffer.create(8))
		r:serializeCompressedFloatPrecomputed({ value = 5 }, 1000, 9, 10.0, 0)
	end, "precomputed compressed float constants must be exactly what CompressedFloatParams derives")

	raises(function()
		local m = serialize.MeasureStream.new()
		m:serializeCompressedFloatPrecomputed({ value = 5 }, 1000, 9, 10.0, 0)
	end, "precomputed compressed float constants must be exactly what CompressedFloatParams derives")

	-- a non-finite value raises on write, before the latch check.
	raises(function()
		local w = WriteStream.new(buffer.create(8))
		w:serializeCompressedFloat({ value = 0 / 0 }, 0, 10, 0.01)
	end, "compressed float value must be finite")

	raises(function()
		local w = WriteStream.new(buffer.create(8))
		w:serializeCompressedFloat({ value = math.huge }, 0, 10, 0.01)
	end, "compressed float value must be finite")

	raises(function()
		local w = WriteStream.new(buffer.create(8))
		w:serializeCompressedFloat({ value = -math.huge }, 0, 10, 0.01)
	end, "compressed float value must be finite")
end

-- A round trip and the measure stream agree with the write width.
local function testRoundTripAndMeasure()
	local w = WriteStream.new(buffer.create(8))
	if not w:serializeCompressedFloat({ value = 5.0 }, 0, 10, 0.01) then
		error("round-trip write failed", 2)
	end
	w:flush()
	local r = ReadStream.new(w:data())
	local h = { value = -1 }
	if not r:serializeCompressedFloat(h, 0, 10, 0.01) then
		error("round-trip read failed", 2)
	end
	if h.value ~= 5.0 then
		error("round-trip decode " .. h.value .. " ~= 5.0", 2)
	end
	if r:bitsProcessed() ~= 10 then
		error("round-trip consumed " .. r:bitsProcessed() .. " ~= 10", 2)
	end

	local m = serialize.MeasureStream.new()
	if not m:serializeCompressedFloat({ value = 5.0 }, 0, 10, 0.01) then
		error("measure failed", 2)
	end
	if m:bitsProcessed() ~= 10 then
		error("measure bits " .. m:bitsProcessed() .. " ~= 10", 2)
	end
end

function T.TestSerializeCompressedFloat()
	testConformance()
	testTopOfRangeClamp()
	testWriterTwoRoundings()
	testValidation()
	testRoundTripAndMeasure()
end

return T
