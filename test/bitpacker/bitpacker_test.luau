--!strict
-- bitpacker_test.luau — TestBitpacker (serialize-luau-bitpacker): the bit
-- writer and bit reader (DESIGN.md (b), (g), (h); STANDARD.md General
-- Conventions, bits, align, bytes, Reader Obligations).
--
-- It pins:
--   1. every width 1..32 written at every starting bit offset 0..63,
--      compared with an independent bit-by-bit LSB-first oracle (the test
--      writes the oracle itself; never the code under test);
--   2. the byte-for-byte sequence of serialize.go's TestBitpacker
--      (.ref/serialize.go/serialize_test.go), byte for byte;
--   3. readBits round-trips of (1);
--   4. a read past the end is refused by wouldReadPastEnd and raises the bit
--      reader's misuse error, and data of 0..9 bytes never reads outside
--      itself;
--   5. readAlign refuses a nonzero padding bit.

local serialize = require("./serialize")
local BitWriter = serialize.BitWriter
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

-- The independent bit-by-bit LSB-first oracle: writes is an array of
-- {value, bits} pairs; returns an array of bytes (1-indexed) of the packed
-- stream, ceil(total bits / 8) of them.
local function oracleBytes(writes)
	local total = 0
	for _, w in writes do
		total += w[2]
	end
	local nbytes = math.ceil(total / 8)
	if nbytes == 0 then
		return {}
	end
	local bytes = {}
	for i = 1, nbytes do
		bytes[i] = 0
	end
	local bitpos = 0
	for _, w in writes do
		local value, bits = w[1], w[2]
		for i = 0, bits - 1 do
			local bit = math.floor(value / (2 ^ i)) % 2
			if bit == 1 then
				local b = math.floor(bitpos / 8) + 1
				bytes[b] = bytes[b] + (2 ^ (bitpos % 8))
			end
			bitpos += 1
		end
	end
	return bytes
end

local function bytesToBuffer(bytes): buffer
	local n = #bytes
	local out = buffer.create(n)
	for i = 1, n do
		buffer.writeu8(out, i - 1, bytes[i])
	end
	return out
end

local function writeBufferEquals(actual: buffer, bytes)
	if buffer.len(actual) ~= #bytes then
		error("byte length " .. buffer.len(actual) .. " != oracle " .. #bytes, 2)
	end
	for i = 1, #bytes do
		if buffer.readu8(actual, i - 1) ~= bytes[i] then
			error("byte " .. i - 1 .. " = " .. buffer.readu8(actual, i - 1) .. " != oracle " .. bytes[i], 2)
		end
	end
end

-- Test 1 + 3: every width 1..32 at every starting bit offset 0..63, against
-- the oracle, then a read round-trip. The value written is a distinct pattern
-- (alternating bits, rotated by the offset) so a value-bit-order or wrong-bit
-- bug diverges from the oracle instead of agreeing because every bit is 1.
local function patternedValue(w: number, o: number): number
	local base = (o % 2 == 0) and 0xAAAAAAAA or 0x55555555
	local v = bit32.rrotate(base, (o // 2) % 32)
	return bit32.band(v, (2 ^ w) - 1)
end

local function testWriterOracleAndRoundTrip()
	for o = 0, 63 do
		for w = 1, 32 do
			local writes = {}
			local k = 0
			while k < o do
				writes[#writes + 1] = { k % 2, 1 }
				k += 1
			end
			local value = patternedValue(w, o)
			writes[#writes + 1] = { value, w }

			local writer = BitWriter.new(buffer.create(128))
			for _, wr in writes do
				writer:writeBits(wr[1], wr[2])
			end
			writer:flushBits()

			local expect = oracleBytes(writes)
			if #expect == 0 then
				error("oracle produced no bytes for o=" .. o .. " w=" .. w, 2)
			end
			writeBufferEquals(writer:data(), expect)

			local reader = BitReader.new(writer:data())
			for i = 1, o do
				local bit = reader:readBits(1)
				if bit ~= (i - 1) % 2 then
					error("round-trip filler bit " .. i .. " mismatch at o=" .. o .. " w=" .. w, 2)
				end
			end
			local got = reader:readBits(w)
			if got ~= value then
				error("round-trip value mismatch at o=" .. o .. " w=" .. w .. ": " .. got .. " != " .. value, 2)
			end
		end
	end
end

-- Masking: high bits above the width are dropped, like Go.
local function testMasking()
	for w = 1, 32 do
		local writer = BitWriter.new(buffer.create(16))
		writer:writeBits(0xFFFFFFFF, w)
		writer:flushBits()
		local expect = oracleBytes({ { (2 ^ w) - 1, w } })
		writeBufferEquals(writer:data(), expect)
	end
end

-- Test 2: the byte-for-byte sequence of serialize.go's TestBitpacker.
local function testGoTestBitpacker()
	local writer = BitWriter.new(buffer.create(256))
	if writer:bitsWritten() ~= 0 or writer:bytesWritten() ~= 0 or writer:bitsAvailable() ~= 256 * 8 then
		error("bad initial writer state", 2)
	end
	writer:writeBits(0, 1)
	writer:writeBits(1, 1)
	writer:writeBits(10, 8)
	writer:writeBits(255, 8)
	writer:writeBits(1000, 10)
	writer:writeBits(50000, 16)
	writer:writeBits(9999999, 32)
	writer:flushBits()
	-- the byte-for-byte sequence of serialize.go's TestBitpacker (v1.15.1):
	-- 0,1,10,255,1000,50000,9999999 written at widths 1,1,8,8,10,16,32
	local golden = { 0x2A, 0xFC, 0xA3, 0x0F, 0x35, 0xFC, 0x67, 0x89, 0x09, 0x00 }
	writeBufferEquals(writer:data(), golden)
	local bitsWritten = 1 + 1 + 8 + 8 + 10 + 16 + 32
	if writer:bytesWritten() ~= 10 then
		error("expected 10 bytes written, got " .. writer:bytesWritten(), 2)
	end
	if writer:bitsWritten() ~= bitsWritten then
		error("expected " .. bitsWritten .. " bits written, got " .. writer:bitsWritten(), 2)
	end
	if writer:bitsAvailable() ~= 256 * 8 - bitsWritten then
		error("bad bits available", 2)
	end

	local bytesWritten = writer:bytesWritten()
	local reader = BitReader.new(writer:data())
	if reader:bitsRead() ~= 0 or reader:bitsRemaining() ~= bytesWritten * 8 then
		error("bad initial reader state", 2)
	end
	local a = reader:readBits(1)
	local b = reader:readBits(1)
	local c = reader:readBits(8)
	local d = reader:readBits(8)
	local e = reader:readBits(10)
	local f = reader:readBits(16)
	local g = reader:readBits(32)
	if a ~= 0 or b ~= 1 or c ~= 10 or d ~= 255 or e ~= 1000 or f ~= 50000 or g ~= 9999999 then
		error("read values do not match written values", 2)
	end
	if reader:bitsRead() ~= bitsWritten then
		error("bad bits read", 2)
	end
	if reader:bitsRemaining() ~= bytesWritten * 8 - bitsWritten then
		error("bad bits remaining", 2)
	end
	if reader:wouldReadPastEnd(reader:bitsRemaining()) then
		error("reading the remaining bits must not read past the end", 2)
	end
	if not reader:wouldReadPastEnd(reader:bitsRemaining() + 1) then
		error("reading past the remaining bits must report past the end", 2)
	end
end

-- Test 4: past the end is refused by wouldReadPastEnd and raises the reader's
-- misuse error; data of 0..9 bytes never reads outside itself.
local function fill(data: buffer, n: number)
	for i = 0, n - 1 do
		buffer.writeu8(data, i, (i * 7 + 3) % 256)
	end
end

local ALLOWED_RAISES = {
	"would read past the end of the buffer",
	"byte array serialization requires byte alignment",
	"bits must be in [1,32]",
}

local function expectNoHostError(f: () -> ())
	local ok, err = pcall(f)
	if ok then
		return
	end
	local msg = tostring(err)
	for _, pat in ALLOWED_RAISES do
		if string.find(msg, pat, 1, true) ~= nil then
			return
		end
	end
	error("hostile operation raised unexpectedly: " .. msg, 2)
end

local function testPastEndAndShortData()
	raises(function()
		BitReader.new(buffer.create(0)):readBits(1)
	end, "would read past the end of the buffer")

	for n = 0, 9 do
		local data = buffer.create(n)
		fill(data, n)
		local reader = BitReader.new(data)
		for k = 1, 32 do
			if reader:wouldReadPastEnd(k) then
				raises(function()
					reader:readBits(k)
				end, "would read past the end of the buffer")
			else
				expectNoHostError(function()
					reader:readBits(k)
				end)
			end
		end
		local r2 = BitReader.new(data)
		expectNoHostError(function()
			r2:readAlign()
		end)
		local r3 = BitReader.new(data)
		expectNoHostError(function()
			r3:readBytes(buffer.create(4))
		end)
	end
end

-- Test 5: readAlign refuses a nonzero padding bit, accepts zero padding.
local function testReadAlignRefuse()
	local bad = bytesToBuffer({ 0x03 })
	local r = BitReader.new(bad)
	if r:readBits(1) ~= 1 then
		error("expected first bit 1", 2)
	end
	if r:readAlign() then
		error("readAlign must refuse nonzero padding", 2)
	end

	local good = bytesToBuffer({ 0x01 })
	local g = BitReader.new(good)
	if g:readBits(1) ~= 1 then
		error("expected first bit 1", 2)
	end
	if not g:readAlign() then
		error("readAlign must accept zero padding", 2)
	end
	if g:alignBits() ~= 0 then
		error("alignBits must be 0 after an align", 2)
	end
end

-- writeBytes / readBytes with offsets and counts, and writer writeAlign.
local function testBytesApis()
	local src = bytesToBuffer({ 1, 2, 3, 4 })
	local w = BitWriter.new(buffer.create(32))
	w:writeBits(1, 1)
	w:writeAlign()
	w:writeBytes(src, 1, 2)
	w:flushBits()
	if w:bitsWritten() ~= 1 + 7 + 16 then
		error("bytes write bit count", 2)
	end
	local r = BitReader.new(w:data())
	if r:readBits(1) ~= 1 then
		error("bits before bytes", 2)
	end
	r:readAlign()
	local dst = buffer.create(4)
	r:readBytes(dst, 1, 2)
	if buffer.readu8(dst, 1) ~= 2 or buffer.readu8(dst, 2) ~= 3 then
		error("readBytes offset/count", 2)
	end
	raises(function()
		local w2 = BitWriter.new(buffer.create(16))
		w2:writeBits(1, 1)
		w2:writeBytes(src, 0, 1)
	end, "requires byte alignment")
end

-- The misuse raises the brief names, each with serialize.go's panic text.
local function testMisuse()
	raises(function()
		BitWriter.new(buffer.create(8)):writeBits(1, 0)
	end, "bits must be in [1,32]")
	raises(function()
		BitWriter.new(buffer.create(8)):writeBits(1, 33)
	end, "bits must be in [1,32]")
	raises(function()
		BitReader.new(buffer.create(8)):readBits(0)
	end, "bits must be in [1,32]")
	raises(function()
		BitReader.new(buffer.create(8)):readBits(33)
	end, "bits must be in [1,32]")

	-- writer overflow: 8 bytes is 64 bits; 32+32 fills it, one more overflows
	local w = BitWriter.new(buffer.create(8))
	w:writeBits(0xFFFFFFFF, 32)
	w:writeBits(0xFFFFFFFF, 32)
	raises(function()
		w:writeBits(1, 1)
	end, "bit writer overflow")

	-- buffer size not a multiple of 8 bytes
	raises(function()
		BitWriter.new(buffer.create(12))
	end, "buffer size must be a multiple of 8 bytes")

	-- readBytes on a stream that is not byte aligned; and a destination buffer
	-- too small for the count must raise before writing any byte
	raises(function()
		local r = BitReader.new(bytesToBuffer({ 0xFF }))
		r:readBits(1)
		r:readBytes(buffer.create(1))
	end, "byte array serialization requires byte alignment")
	raises(function()
		local r = BitReader.new(bytesToBuffer({ 1, 2, 3, 4 }))
		r:readBytes(buffer.create(2), 1, 2)
	end, "destination buffer too small")
end

function T.TestBitpacker()
	testWriterOracleAndRoundTrip()
	testMasking()
	testGoTestBitpacker()
	testPastEndAndShortData()
	testReadAlignRefuse()
	testBytesApis()
	testMisuse()
end

return T
