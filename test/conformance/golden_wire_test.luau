--!strict
-- golden_wire_test.luau — TestGoldenWireFormat: serialize.go's
-- TestGoldenWireFormat golden bytes (goldenWireBytes in .ref/serialize.go/
-- serialize_test.go, pasted below as literals) are read and re-written byte
-- for byte, and every single-bit flip of a consumed bit is refused or decoded
-- differently (STANDARD.md, the golden message and "Bit transparency — both
-- directions").

local serialize = require("./serialize")

local T = {}

local Int128 = serialize.Int128

local goldenBytes = {
	0x5D, 0xDA, 0xF7, 0xE6, 0xD5, 0x77, 0xDF, 0x56, 0xEF, 0x9F, 0x75, 0x19,
	0x52, 0xBC, 0xDA, 0x0F, 0x49, 0x40, 0xF4, 0x55, 0x55, 0x55, 0x55, 0x55,
	0x55, 0x55, 0xFF, 0xFC, 0xD1, 0x48, 0xE0, 0x59, 0xD1, 0x48, 0xC0, 0x7B,
	0xF3, 0x6A, 0xE2, 0x59, 0xD1, 0x48, 0x84, 0xB7, 0x06, 0xDE, 0xAD, 0xBE,
	0xEF, 0xCA, 0xFE, 0x01, 0x06, 0x67, 0x6F, 0x6C, 0x64, 0x65, 0x6E, 0xE3,
	0x21, 0x00, 0x00, 0xC0, 0x21, 0x00, 0x00, 0x00, 0x22, 0x00, 0x00, 0x00,
	0xC0, 0x60, 0x00, 0x80, 0xA2, 0x7C, 0xFC, 0xEC, 0x26, 0xCB, 0xFF, 0xFF,
	0x4B, 0x1D, 0x1F, 0xEF, 0xD2, 0x1A, 0x1F, 0x01, 0xE9, 0xFF, 0xFF, 0x09,
	0x19, 0x2A, 0x3B, 0x4C, 0x5D, 0x6E, 0x7F, 0x78, 0x6F, 0x5E, 0x4D, 0x3C,
	0x2B, 0x1A, 0x09, 0x04,
}

local CONSUMED_BITS = 891
local MIN_INT64 = integer.lshift(1i, 63i)
local MAX_INT64 = integer.sub(integer.lshift(1i, 63i), 1i)

local function bytesToBuffer(bytes: { number }): buffer
	local s = {}
	for _, b in bytes do
		s[#s + 1] = string.char(b)
	end
	return buffer.fromstring(table.concat(s))
end

local function bufToBytes(b: buffer): { number }
	local out = {}
	for i = 0, buffer.len(b) - 1 do
		out[#out + 1] = buffer.readu8(b, i)
	end
	return out
end

local function fail(what: string): never
	error("TestGoldenWireFormat: " .. what, 2)
end

local function check(cond: any, what: string)
	if not cond then
		fail(what)
	end
end

local function goldenData()
	return {
		bits4 = 0, bits11 = 0, bits24 = 0, bits32 = 0,
		intSmall = 0, intFull = 0, flag = false,
		floatValue = 0.0, compressedFloatValue = 0.0, doubleValue = 0.0,
		uint8Value = 0, uint16Value = 0, uint32Value = 0, uint64Value = 0i,
		relativeNear = 0, relativeFar = 0,
		bytes = { 0, 0, 0, 0, 0, 0, 0 },
		str = "", wstr = "",
		fixedQ8_8 = 0i, fixedQ16_16 = 0i, fixedQ48_16 = 0i, fixedQ16_16Unsigned = 0i,
		fixedQ112_16Wide = Int128.new(0i, 0i), fixedQ64_64Wide = Int128.new(0i, 0i),
	}
end

local function expectedData()
	local d = goldenData()
	d.bits4 = 13
	d.bits11 = 1445
	d.bits24 = 11259375
	d.bits32 = 0xDEADBEEF
	d.intSmall = -37
	d.intFull = -123456789
	d.flag = true
	d.floatValue = serialize._family("float").f32frombits(serialize._family("float").f32bits(3.1415926))
	d.compressedFloatValue = 5.0
	d.doubleValue = 1.0 / 3.0
	d.uint8Value = 0x7F
	d.uint16Value = 0x1234
	d.uint32Value = 0x12345678
	d.uint64Value = 0x123456789ABCDEF0i
	d.relativeNear = 101
	d.relativeFar = 2100
	d.bytes = { 0xDE, 0xAD, 0xBE, 0xEF, 0xCA, 0xFE, 0x01 }
	d.str = "golden"
	d.wstr = "мир"
	d.fixedQ8_8 = -832i
	d.fixedQ16_16 = 80904192i
	d.fixedQ48_16 = -3559993401i
	d.fixedQ16_16Unsigned = 1966079999i
	d.fixedQ112_16Wide = Int128.from64(-6472691358699745i)
	d.fixedQ64_64Wide = Int128.new(0x0FEDCBA987654321i, 0x0123456789ABCDEFi)
	return d
end

local function same(a: any, b: any): boolean
	if a.bits4 ~= b.bits4 or a.bits11 ~= b.bits11 or a.bits24 ~= b.bits24 or a.bits32 ~= b.bits32 then return false end
	if a.intSmall ~= b.intSmall or a.intFull ~= b.intFull or a.flag ~= b.flag then return false end
	if a.floatValue ~= b.floatValue or a.compressedFloatValue ~= b.compressedFloatValue or a.doubleValue ~= b.doubleValue then return false end
	if a.uint8Value ~= b.uint8Value or a.uint16Value ~= b.uint16Value or a.uint32Value ~= b.uint32Value or a.uint64Value ~= b.uint64Value then return false end
	if a.relativeNear ~= b.relativeNear or a.relativeFar ~= b.relativeFar then return false end
	for i = 1, 7 do
		if a.bytes[i] ~= b.bytes[i] then return false end
	end
	if a.str ~= b.str or a.wstr ~= b.wstr then return false end
	if a.fixedQ8_8 ~= b.fixedQ8_8 or a.fixedQ16_16 ~= b.fixedQ16_16 or a.fixedQ48_16 ~= b.fixedQ48_16 or a.fixedQ16_16Unsigned ~= b.fixedQ16_16Unsigned then return false end
	if Int128.cmp(a.fixedQ112_16Wide, b.fixedQ112_16Wide) ~= 0 then return false end
	if Int128.cmp(a.fixedQ64_64Wide, b.fixedQ64_64Wide) ~= 0 then return false end
	return true
end

local function drive(stream: any, d: any): boolean
	local ok = true
	local function step(fn: any, holder: any, ...: any)
		if ok then
			ok = fn(stream, holder, ...)
		end
	end
	local h4 = { value = d.bits4 }
	step(stream.serializeBits, h4, 4)
	d.bits4 = h4.value
	local h11 = { value = d.bits11 }
	step(stream.serializeBits, h11, 11)
	d.bits11 = h11.value
	local h24 = { value = d.bits24 }
	step(stream.serializeBits, h24, 24)
	d.bits24 = h24.value
	local h32 = { value = d.bits32 }
	step(stream.serializeBits, h32, 32)
	d.bits32 = h32.value
	local hSmall = { value = d.intSmall }
	step(stream.serializeInt, hSmall, -100, 100)
	d.intSmall = hSmall.value
	local hFull = { value = d.intFull }
	step(stream.serializeInt, hFull, -2147483648, 2147483647)
	d.intFull = hFull.value
	local hFlag = { value = d.flag }
	step(stream.serializeBool, hFlag)
	d.flag = hFlag.value
	local hFloat = { value = d.floatValue }
	step(stream.serializeFloat, hFloat)
	d.floatValue = hFloat.value
	local hCmp = { value = d.compressedFloatValue }
	step(stream.serializeCompressedFloat, hCmp, 0.0, 10.0, 0.01)
	d.compressedFloatValue = hCmp.value
	local hDouble = { value = d.doubleValue }
	step(stream.serializeDouble, hDouble)
	d.doubleValue = hDouble.value
	local hU8 = { value = d.uint8Value }
	step(stream.serializeUint8, hU8)
	d.uint8Value = hU8.value
	local hU16 = { value = d.uint16Value }
	step(stream.serializeUint16, hU16)
	d.uint16Value = hU16.value
	local hU32 = { value = d.uint32Value }
	step(stream.serializeUint32, hU32)
	d.uint32Value = hU32.value
	local hU64 = { value = d.uint64Value }
	step(stream.serializeUint64, hU64)
	d.uint64Value = hU64.value
	local hNear = { value = d.relativeNear }
	if ok then ok = stream:serializeIntRelative(100, hNear) end
	d.relativeNear = hNear.value
	local hFar = { value = d.relativeFar }
	if ok then ok = stream:serializeIntRelative(100, hFar) end
	d.relativeFar = hFar.value
	step(stream.serializeAlign, { value = nil })
	local hBytes
	if stream._kind == "write" then
		hBytes = bytesToBuffer(d.bytes)
		step(stream.serializeBytes, hBytes)
	else
		hBytes = buffer.create(7)
		step(stream.serializeBytes, hBytes)
		d.bytes = bufToBytes(hBytes)
	end
	local hStr = { value = d.str }
	step(stream.serializeString, hStr, 16)
	d.str = hStr.value
	local hWstr = { value = d.wstr }
	step(stream.serializeWideString, hWstr, 8)
	d.wstr = hWstr.value
	step(stream.serializeAlign, { value = nil })
	local hF8 = { value = d.fixedQ8_8 }
	step(stream.serializeFixed64, hF8, 8, 8, -100i, 100i)
	d.fixedQ8_8 = hF8.value
	local hF16 = { value = d.fixedQ16_16 }
	step(stream.serializeFixed64, hF16, 16, 16, -2000i, 2000i)
	d.fixedQ16_16 = hF16.value
	local hF48 = { value = d.fixedQ48_16 }
	step(stream.serializeFixed64, hF48, 48, 16, -100000i, 100000i)
	d.fixedQ48_16 = hF48.value
	local hFU = { value = d.fixedQ16_16Unsigned }
	step(stream.serializeFixed64, hFU, 16, 16, 0i, 30000i)
	d.fixedQ16_16Unsigned = hFU.value
	step(stream.serializeAlign, { value = nil })
	local hW112 = { value = d.fixedQ112_16Wide }
	step(stream.serializeFixed128, hW112, 112, 16, -144115188075855872i, 144115188075855872i)
	d.fixedQ112_16Wide = hW112.value
	local hW64 = { value = d.fixedQ64_64Wide }
	step(stream.serializeFixed128, hW64, 64, 64, MIN_INT64, MAX_INT64)
	d.fixedQ64_64Wide = hW64.value
	return ok
end

function T.TestGoldenWireFormat()
	local expected = expectedData()

	-- write side: serializing the golden values must produce exactly the golden bytes
	do
		local w = serialize.WriteStream.new(buffer.create(128))
		check(drive(w, expectedData()), "golden write was refused")
		w:flush()
		local got = bufToBytes(w:data())
		check(#got == #goldenBytes, "golden write emitted " .. #got .. " bytes, expected " .. #goldenBytes)
		for i = 1, #goldenBytes do
			check(got[i] == goldenBytes[i], "golden write byte " .. i .. " differs")
		end
	end

	-- read side: the golden bytes must decode to the expected values
	local d = goldenData()
	do
		local r = serialize.ReadStream.new(bytesToBuffer(goldenBytes))
		check(drive(r, d), "golden read was refused")
		check(same(d, expected), "golden read decode differs")
	end

	-- every single-bit flip of a consumed bit is refused or decoded differently
	local masks = { 0x01, 0x02, 0x04, 0x08, 0x10, 0x20, 0x40, 0x80 }
	for bit = 0, CONSUMED_BITS - 1 do
		local bs = {}
		for i = 1, #goldenBytes do
			bs[i] = goldenBytes[i]
		end
		local byteIndex = math.floor(bit / 8) + 1
		local mask = masks[bit % 8 + 1]
		local cur = bs[byteIndex]
		if cur % (mask * 2) >= mask then
			bs[byteIndex] = cur - mask
		else
			bs[byteIndex] = cur + mask
		end
		local r = serialize.ReadStream.new(bytesToBuffer(bs))
		local dd = goldenData()
		local ok = drive(r, dd)
		if ok then
			check(not same(dd, expected), "bit " .. bit .. " flipped but decoded identically")
		end
	end
end

return T
