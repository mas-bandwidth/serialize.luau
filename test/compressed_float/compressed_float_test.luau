--!strict
-- compressed_float_test.luau — TestSerializeCompressedFloat
-- (serialize-luau-compressed-float): the compressed_float family (DESIGN.md
-- (a), (e), (g) and (h); STANDARD.md, Floating Point, "compressed_float").
--
-- It pins:
--   1. every record of conformance/compressed_float.txt as a reader must:
--      accepted vectors decode bit-exactly and consume exactly `consumed`
--      bits; refused vectors refuse for their stated reason, leave the
--      destination untouched and the stream terminal; a record carrying
--      writer_input hands the writer that float32 and requires the record's
--      bytes. The record count is printed and must equal the file's count;
--   2. the writer's integer clamp witnesses (STANDARD.md compressed_float,
--      "The integer clamp is normative"): [0, 8388609] and [0, 16777215] at
--      resolution 1, writing max, emit the largest legal code, not one past;
--   3. the writer's two-roundings witnesses (STANDARD.md compressed_float):
--      over [0,10] at resolution 0.01, 0.005 -> 1, 0.025 -> 3, 0.105 -> 11
--      and 9.995 -> 1000 (a widened writer yields 0, 2, 10, 999);
--   4. serialize.go's TestCompressedFloatValidation misuse rules: min >= max
--      or resolution <= 0 raises; bad precomputed constants raise; a
--      non-finite write raises;
--   5. the finite decode (STANDARD.md compressed_float, "The decode must be
--      finite"): over [3*2^103, FLT_MAX] at resolution 2^104 the top integer
--      decodes to +inf, which a reader refuses as non_finite_float with its
--      destination untouched, and a writer raises on that declaration.

local serialize = require("./serialize")
local WriteStream = serialize.WriteStream
local ReadStream = serialize.ReadStream
local BitReader = serialize.BitReader
local BitWriter = serialize.BitWriter

local function check22(cond: boolean, what: string)
	if not cond then
		error(what, 3)
	end
end

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

local function f32frombits(u: number): number
	local b = buffer.create(4)
	buffer.writeu32(b, 0, u)
	return buffer.readf32(b, 0)
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
				local reason = val:match("^refused (%S+)$")
				if reason ~= nil then
					current.refused = true
					current.reason = reason
				else
					local hex = val:match("^bits = 0x(%x+)$")
					if hex == nil then
						error("bad expect line in " .. tostring(current.name) .. ": " .. val)
					end
					current.expectBits = tonumber(hex, 16)
				end
			elseif key == "writer_input" then
				local hex = val:match("^bits = 0x(%x+)$")
				if hex == nil then
					error("bad writer_input line in " .. tostring(current.name) .. ": " .. val)
				end
				current.writerInput = tonumber(hex, 16)
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
		if rs:error() ~= rec.reason then
			error(rec.name .. ": refused for " .. tostring(rs:error()) .. ", the vector states " .. tostring(rec.reason))
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
	if rec.writerInput ~= nil then
		local w = WriteStream.new(buffer.create(8))
		if not w:serializeCompressedFloat({ value = f32frombits(rec.writerInput) }, rec.min, rec.max, rec.res) then
			error("writer_input write refused for " .. rec.name)
		end
		w:flush()
		local got = w:data()
		local want = hexBytes(rec.bytesText)
		local same = buffer.len(got) == #want
		for i = 1, #want do
			same = same and buffer.readu8(got, i - 1) == want[i]
		end
		if not same then
			error("writer_input bytes mismatch for " .. rec.name)
		end
	end
end

local EXPECTED_RECORDS = 37

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

	-- the same precomputed validation on the read and measure streams; a read
	-- never raises, it refuses value_out_of_range (IMPLEMENTING.md U7, U16).
	do
		local r = ReadStream.new(buffer.create(8))
		local h = { value = 5 }
		if r:serializeCompressedFloatPrecomputed(h, 1000, 9, 10.0, 0) ~= false or r:error() ~= "value_out_of_range" or h.value ~= 5 or r:bitsProcessed() ~= 0 then
			error("a bad precomputed declaration on read was not refused as value_out_of_range", 2)
		end
	end

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

-- The finite decode witness (STANDARD.md compressed_float, "The decode must
-- be finite"): [3*2^103, FLT_MAX] at resolution 2^104 has delta 2^128 - 2^105
-- and 24 bits; the top integer 2^24 - 2 decodes to 2^128, +inf. The reader
-- refuses it as non_finite_float with its destination untouched; the integer
-- below it decodes finite and is accepted. The writer raises on the whole
-- declaration, even for a value that would decode finite.
local function testFiniteDecode()
	local min = 3 * 2 ^ 103
	local max = f32frombits(0x7F7FFFFF)
	local res = 2 ^ 104
	local maxIntegerValue, bits = serialize.compressedFloatParams(min, max, res)
	if maxIntegerValue ~= 2 ^ 24 - 2 or bits ~= 24 then
		error("finite decode witness params " .. maxIntegerValue .. " " .. bits, 2)
	end
	local function readCode(code: number): (boolean, number, any)
		local b = buffer.create(3)
		buffer.writeu8(b, 0, code % 256)
		buffer.writeu8(b, 1, (code // 256) % 256)
		buffer.writeu8(b, 2, code // 65536)
		local r = ReadStream.new(b)
		local h = { value = 12345.0 }
		local ok = r:serializeCompressedFloat(h, min, max, res)
		return ok, h.value, r
	end
	local ok, value, r = readCode(maxIntegerValue)
	if ok or value ~= 12345.0 then
		error("a decode to +inf was accepted or wrote its destination", 2)
	end
	if r:error() ~= serialize.SerializeError.NonFiniteFloat then
		error("a decode to +inf refused for " .. tostring(r:error()) .. ", want non_finite_float", 2)
	end
	local h2 = { value = 1.0 }
	if r:serializeCompressedFloat(h2, min, max, res) or r:error() ~= serialize.SerializeError.NonFiniteFloat then
		error("the stream is not terminal after a non-finite decode, or lost its first reason", 2)
	end
	local okBelow, below = readCode(maxIntegerValue - 1)
	if not okBelow or below ~= below or below == math.huge then
		error("the integer below the top did not decode finite", 2)
	end
	raises(function()
		local w = WriteStream.new(buffer.create(8))
		w:serializeCompressedFloat({ value = min }, min, max, res)
	end, "top integer must decode to a finite float32")
	raises(function()
		local w = WriteStream.new(buffer.create(8))
		local mi, b, d = serialize.compressedFloatParams(min, max, res)
		w:serializeCompressedFloatPrecomputed({ value = min }, mi, b, d, min)
	end, "top integer must decode to a finite float32")
end

-- The value and a precomputed delta are float32s, narrowed as Go's float32
-- parameters are, before any arithmetic: over [1, 2] at resolution 2^-22 the
-- double 1 + 2^-23 - 2^-40 narrows to 1 + 2^-23 and writes integer 1 (unnarrowed
-- it writes 0); a precomputed delta of 0.0685 decodes as float32(0.0685); a
-- precomputed delta past FLT_MAX is +inf as a float32 and raises; a finite
-- double past FLT_MAX is not a finite float32 and raises.
local function testFloat32Narrowing()
	local w = WriteStream.new(buffer.create(8))
	check22(w:serializeCompressedFloat({ value = 1 + 2 ^ -23 - 2 ^ -40 }, 1, 2, 2 ^ -22), "narrowing write refused")
	w:flush()
	local code = BitReader.new(w:data()):readBits(23)
	if code ~= 1 then
		error("the value was not narrowed to float32 before quantizing: code " .. code, 2)
	end
	local maxIntegerValue, bits = serialize.compressedFloatParams(0, 0.0685, 0.0000685)
	local b = buffer.create(8)
	local bw = BitWriter.new(b)
	bw:writeBits(186, bits)
	bw:flushBits()
	local r = ReadStream.new(b)
	local h = { value = 0 }
	check22(r:serializeCompressedFloatPrecomputed(h, maxIntegerValue, bits, 0.0685, 0.5), "narrowed delta read refused")
	local want = f32frombits(f32bits(f32frombits(f32bits(f32frombits(f32bits(186 / maxIntegerValue)) * f32frombits(f32bits(0.0685)))) + 0.5))
	if f32bits(h.value) ~= f32bits(want) then
		error("a precomputed delta was not narrowed to float32", 2)
	end
	raises(function()
		WriteStream.new(buffer.create(8)):serializeCompressedFloatPrecomputed({ value = 0 }, maxIntegerValue, bits, 1e39, 0)
	end, "precomputed compressed float constants must be exactly what CompressedFloatParams derives")
	local refused = ReadStream.new(buffer.create(8))
	if refused:serializeCompressedFloatPrecomputed({ value = 0 }, maxIntegerValue, bits, 1e39, 0) ~= false or refused:error() ~= "value_out_of_range" then
		error("a delta that narrows to infinity was not refused on read", 2)
	end
	raises(function()
		WriteStream.new(buffer.create(8)):serializeCompressedFloat({ value = 1e39 }, 0, 10, 0.01)
	end, "compressed float value must be finite")
end

function T.TestSerializeCompressedFloat()
	testConformance()
	testTopOfRangeClamp()
	testWriterTwoRoundings()
	testValidation()
	testRoundTripAndMeasure()
	testFiniteDecode()
	testFloat32Narrowing()
end

return T
