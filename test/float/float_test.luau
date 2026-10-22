--!strict
-- float_test.luau — TestSerializeFloat (serialize-luau-float). It runs every
-- record of conformance/float.txt and conformance/double.txt, comparing BIT
-- PATTERNS (STANDARD.md, "Finite values only, every one bit exact": a value
-- comparison cannot see the sign of zero or a flushed subnormal) and every
-- refusal's reason, and checks fround against a table computed by Go's
-- float32() from a tiny program in .ref (never by the code under test). The
-- finite rule's write half is pinned here too: a non-finite value, including
-- a finite double that narrows to an infinity, refuses as non_finite_float.

local serialize = require("./serialize")
local float = serialize._family("float")
local inputs = require("./inputs")

local FROUND = {
	{ math.huge, 0x7F800000 },
	{ -math.huge, 0xFF800000 },
	{ 3.4028234663852886e+38, 0x7F7FFFFF },
	{ 3.4028235677973366e+38, 0x7F800000 },
	{ 3.4028233649732406e+38, 0x7F7FFFFE },
	{ 1.1754943508222875e-38, 0x00800000 },
	{ 1.1754943508222874e-38, 0x00800000 },
	{ 1.1754942106924411e-38, 0x007FFFFF },
	{ 1.175494210692441e-38, 0x007FFFFF },
	{ -0.0, 0x80000000 },
	{ 1, 0x3F800000 },
	{ -1, 0xBF800000 },
	{ 1.0000000596046448, 0x3F800000 },
	{ 1.0000001788139343, 0x3F800002 },
	{ 1.0000000596046448, 0x3F800000 },
	{ 1.0000001788139343, 0x3F800002 },
	{ 1.401298464324817e-45, 0x00000001 },
	{ 0.0002678411527236562, 0x398C6D08 },
	{ -1.2519148940668696e+16, 0xDA31E866 },
	{ -1.3986445598598553e+14, 0xD6FE6976 },
	{ 1.5034755941288156e-10, 0x2F254F13 },
	{ -2.805400086411562e-14, 0xA8FCB01F },
	{ -760.4613614059563, 0xC43E1D87 },
	{ 2.5110621897699263e-14, 0x28E22D27 },
	{ -164385.46780851617, 0xC820885E },
	{ 1.4136612591915833e-08, 0x3272DD7B },
	{ -2.734985482341452e+13, 0xD5C6FF13 },
	{ 3.592497382781912e+08, 0x4DAB4DBA },
	{ 2.0227926355803949e+06, 0x49F6EC45 },
	{ 1.4564413941060463e-17, 0x23865540 },
	{ 4.390078467439737e-18, 0x22A1F71E },
	{ 1.4041442675323924e+16, 0x5A478A79 },
	{ 3.1045457719554375e+12, 0x5434B556 },
	{ -0.11262658405327636, 0xBDE6A8C4 },
	{ 3.2291076174760623e-06, 0x3658B3A5 },
	{ -6.680814767511948e-10, 0xB037A40E },
	{ -8.303733458542234e+06, 0xCAFD68EB },
	{ -1.8108097258485538, 0xBFE7C89D },
	{ -6.478733616546246e+10, 0xD1715A05 },
	{ -5.376780437582317e-08, 0xB366EE53 },
	{ 111523.53879770826, 0x47D9D1C5 },
	{ -1.1252850933776216e-14, 0xA84AB69E },
	{ -1.6405237487719916e-09, 0xB0E178CC },
	{ 7.19877199896715e+14, 0x5823AE5E },
	{ 4.2943742605175436e-13, 0x2AF1C075 },
	{ 0.017875328581944017, 0x3C926F48 },
	{ 0.17100778241421788, 0x3E2F1CAA },
	{ 289.7900064451103, 0x4390E51F },
	{ -514393.0020200232, 0xC8FB2B20 },
	{ -2.054127023630824e+15, 0xD8E986F7 },
	{ -60.82350837253783, 0xC2734B46 },
	{ 7.4415356846019775e+06, 0x4AE318FF },
	{ -1.631539216359644e+15, 0xD8B97C0A },
	{ 1.8467594954773714e-15, 0x270512B3 },
	{ -7.8953884407966e-13, 0xAB5E3C45 },
	{ -9.178374347413046e-13, 0xAB812C94 },
	{ 491.94860346083715, 0x43F5F96C },
	{ -4.023964768805035e+16, 0xDB0EF5BF },
	{ -4.754284681841548e-19, 0xA10C525C },
	{ 7.623614728591525e-06, 0x36FFCE5A },
	{ -3.535231855649922e-12, 0xAC78C513 },
	{ 2.0073571556193633e+12, 0x53E9AFE8 },
	{ -1.6441883458455235e+07, 0xCB7AE21B },
	{ -6.8893030474447986e-12, 0xACF26553 },
	{ 1.4098597052132946e+10, 0x505215E1 },
	{ -1.3309960706888372e+06, 0xC9A279A1 },
	{ 2.46025367745636e+15, 0x590BD967 },
	{ -8.336792416461339e+08, 0xCE46C3BE },
	{ 4.7229887001564216e-17, 0x2459CF35 },
	{ 5.60371433274855e-17, 0x2481367E },
	{ 2.9080590618501283, 0x403A1DA4 },
	{ 1.923931102901039e+12, 0x53DFF99D },
	{ 5.491887682810725e-16, 0x261E4AFB },
	{ 0.0057918290023015705, 0x3BBDC962 },
	{ -0.9768065067108962, 0xBF7A0FFE },
	{ -1.5227894042463988e+07, 0xCB685BF6 },
	{ -2.889430257122661e+15, 0xD9243EBF },
	{ -1.0614182366455592e-13, 0xA9EF0298 },
	{ 0.024246920163111918, 0x3CC6A17A },
	{ 1.3294563708289908e+11, 0x51F7A16B },
	{ 933.904098659074, 0x446979DD },
}

local T = {}

local function check(cond: boolean, what: string)
	if not cond then
		error("TestSerializeFloat: " .. what, 2)
	end
end

local function countOperations(text: string): number
	local n = 0
	for line in string.gmatch(text, "[^\n]+") do
		if string.match(line, "^%s*operation%s") then
			n += 1
		end
	end
	return n
end

local function parseRecords(text: string): { any }
	local out: { any } = {}
	local rec: any = nil
	for line in string.gmatch(text .. "\n", "([^\n]*)\n") do
		local trimmed = string.match(line, "^%s*(.-)%s*$") or line
		if trimmed == "" then
			if rec ~= nil then
				table.insert(out, rec)
				rec = nil
			end
		elseif string.sub(trimmed, 1, 1) ~= "#" then
			local key, rest = string.match(trimmed, "^(%S+)%s*(.*)$")
			if key == "operation" then
				rec = { operation = rest, bytes = {} }
			elseif rec ~= nil then
				if key == "name" then
					rec.name = rest
				elseif key == "bytes" then
					rec.bytes = {}
					for h in string.gmatch(rest, "%x%x") do
						table.insert(rec.bytes, tonumber(h, 16))
					end
				elseif key == "expect" then
					rec.expect = rest
				elseif key == "consumed" then
					rec.consumed = tonumber(rest)
				elseif key == "writer" then
					rec.writer = rest
				end
			end
		end
	end
	if rec ~= nil then
		table.insert(out, rec)
	end
	return out
end

local function bytesBuffer(bytes: { number }): buffer
	local b = buffer.create(#bytes)
	for i, v in bytes do
		buffer.writeu8(b, i - 1, v)
	end
	return b
end

local function bits32(expect: string): number
	local h = string.match(expect, "0x(%x+)")
	check(h ~= nil, "bits expectation has a hex pattern: " .. expect)
	return (tonumber(h :: string, 16) :: number)
end

local function bits64(expect: string): (number, number)
	local h = string.match(expect, "0x(%x+)")
	check(h ~= nil, "bits expectation has a hex pattern: " .. expect)
	local padded = string.rep("0", 16 - #(h :: string)) .. (h :: string)
	local hi = tonumber(string.sub(padded, 1, 8), 16) :: number
	local lo = tonumber(string.sub(padded, 9, 16), 16) :: number
	return lo, hi
end

local function doubleBits(x: number): (number, number)
	local b = buffer.create(8)
	buffer.writef64(b, 0, x)
	return buffer.readu32(b, 0), buffer.readu32(b, 4)
end

local function doubleFromBits(lo: number, hi: number): number
	local b = buffer.create(8)
	buffer.writeu32(b, 0, lo)
	buffer.writeu32(b, 4, hi)
	return buffer.readf64(b, 0)
end

local function sameBytes(got: buffer, want: { number }, name: string)
	check(buffer.len(got) == #want, name .. ": byte length " .. buffer.len(got) .. ", want " .. #want)
	for i, v in want do
		check(buffer.readu8(got, i - 1) == v, name .. ": byte " .. (i - 1) .. " is not the canonical byte")
	end
end

local function runFloat(): number
	local text = inputs.float
	local records = parseRecords(text)
	local count = countOperations(text)
	print("float.txt: " .. #records .. " records")
	check(#records == count, "float.txt: parsed " .. #records .. " of " .. count .. " records")
	for _, rec in records do
		local name = "float " .. tostring(rec.name)
		local r = serialize.ReadStream.new(bytesBuffer(rec.bytes))
		local h = { value = 12345.0 }
		local ok = r:serializeFloat(h)
		local reason = string.match(rec.expect, "^refused (%S+)$")
		if reason ~= nil then
			check(not ok, name .. ": expected a refusal")
			check(h.value == 12345.0, name .. ": a refusal wrote its destination")
			check(r:error() == reason, name .. ": refused for " .. tostring(r:error()) .. ", the vector states " .. reason)
		else
			local want = bits32(rec.expect)
			check(ok, name .. ": read failed: " .. tostring(r:error()))
			check(float.f32bits(h.value) == want, name .. ": read bits differ")
			check(r:bitsProcessed() == rec.consumed, name .. ": consumed " .. r:bitsProcessed())
			if rec.writer == "canonical" then
				local w = serialize.WriteStream.new(buffer.create(8))
				check(w:serializeFloat({ value = float.f32frombits(want) }), name .. ": canonical write failed")
				w:flush()
				sameBytes(w:data(), rec.bytes, name)
			end
		end
	end
	return #records
end

local function runDouble(): number
	local text = inputs.double
	local records = parseRecords(text)
	local count = countOperations(text)
	print("double.txt: " .. #records .. " records")
	check(#records == count, "double.txt: parsed " .. #records .. " of " .. count .. " records")
	for _, rec in records do
		local name = "double " .. tostring(rec.name)
		local r = serialize.ReadStream.new(bytesBuffer(rec.bytes))
		local h = { value = 12345.0 }
		local ok = r:serializeDouble(h)
		local reason = string.match(rec.expect, "^refused (%S+)$")
		if reason ~= nil then
			check(not ok, name .. ": expected a refusal")
			check(h.value == 12345.0, name .. ": a refusal wrote its destination")
			check(r:error() == reason, name .. ": refused for " .. tostring(r:error()) .. ", the vector states " .. reason)
		else
			local wantLo, wantHi = bits64(rec.expect)
			check(ok, name .. ": read failed: " .. tostring(r:error()))
			local gotLo, gotHi = doubleBits(h.value)
			check(gotLo == wantLo and gotHi == wantHi, name .. ": read bits differ")
			check(r:bitsProcessed() == rec.consumed, name .. ": consumed " .. r:bitsProcessed())
			if rec.writer == "canonical" then
				local w = serialize.WriteStream.new(buffer.create(8))
				check(w:serializeDouble({ value = doubleFromBits(wantLo, wantHi) }), name .. ": canonical write failed")
				w:flush()
				sameBytes(w:data(), rec.bytes, name)
			end
		end
	end
	return #records
end

-- testFiniteWrites pins the write half of the finite rule (STANDARD.md,
-- "Finite values only, every one bit exact"): each non-finite value refuses as
-- non_finite_float, writes nothing and latches; a finite double above FLT_MAX
-- narrows to an infinity and refuses the same way, while FLT_MAX itself and
-- the largest double that rounds down to it are written. Negative zero and a
-- subnormal round trip bit exact.
local function testFiniteWrites()
	local NAN = 0 / 0
	local nonFinite = { NAN, -NAN, math.huge, -math.huge, 3.4028235677973366e+38, -1e39 }
	for i, value in nonFinite do
		local w = serialize.WriteStream.new(buffer.create(8))
		check(not w:serializeFloat({ value = value }), "float non-finite case " .. i .. " was written")
		check(w:error() == serialize.SerializeError.NonFiniteFloat, "float non-finite case " .. i .. " refused for " .. tostring(w:error()))
		check(w:bitsProcessed() == 0, "float non-finite case " .. i .. " wrote bits")
		check(not w:serializeFloat({ value = 1.0 }), "float non-finite case " .. i .. " did not latch")
	end
	for i, value in { NAN, -NAN, math.huge, -math.huge } do
		local w = serialize.WriteStream.new(buffer.create(8))
		check(not w:serializeDouble({ value = value }), "double non-finite case " .. i .. " was written")
		check(w:error() == serialize.SerializeError.NonFiniteFloat, "double non-finite case " .. i .. " refused for " .. tostring(w:error()))
		check(w:bitsProcessed() == 0, "double non-finite case " .. i .. " wrote bits")
	end
	for _, value in { 3.4028234663852886e+38, 3.4028235677973362e+38, -0.0, 1.401298464324817e-45 } do
		local w = serialize.WriteStream.new(buffer.create(8))
		check(w:serializeFloat({ value = value }), "finite float " .. tostring(value) .. " refused")
		w:flush()
		local r = serialize.ReadStream.new(w:data())
		local h = { value = 0.0 }
		check(r:serializeFloat(h), "finite float " .. tostring(value) .. " read refused")
		check(float.f32bits(h.value) == float.f32bits(value), "finite float " .. tostring(value) .. " is not bit exact")
	end
	local w = serialize.WriteStream.new(buffer.create(8))
	check(w:serializeDouble({ value = -0.0 }), "double -0 refused")
	w:flush()
	local r = serialize.ReadStream.new(w:data())
	local h = { value = 0.0 }
	check(r:serializeDouble(h), "double -0 read refused")
	local lo, hi = doubleBits(h.value)
	check(lo == 0 and hi == 0x80000000, "double -0 is not bit exact")
end

function T.TestSerializeFloat()
	local floats = runFloat()
	local doubles = runDouble()
	check(floats == 22, "float.txt record count is 22")
	check(doubles == 22, "double.txt record count is 22")

	local cases = 0
	for _, row in FROUND do
		local got = float.f32bits(float.fround(row[1]))
		check(got == row[2], string.format("fround(%s) bits 0x%08X, want 0x%08X", tostring(row[1]), got, row[2]))
		cases += 1
	end
	print("fround: " .. cases .. " cases")
	check(cases == 81, "fround table has 81 cases")

	local w = serialize.WriteStream.new(buffer.create(8))
	local ok, err = pcall(function()
		w:serializeFloat({ value = "nope" })
	end)
	check(not ok and string.find(tostring(err), "serialize: serializeFloat value must be a number", 1, true) ~= nil, "non-number float raises")
	ok, err = pcall(function()
		w:serializeDouble({ value = nil })
	end)
	check(not ok and string.find(tostring(err), "serialize: serializeDouble value must be a number", 1, true) ~= nil, "non-number double raises")

	local full = serialize.WriteStream.new(buffer.create(8))
	check(full:serializeFloat({ value = 1.0 }) and full:serializeFloat({ value = 2.0 }), "float writes")
	check(full:serializeDouble({ value = 1.0 }) == false, "a double past the end refuses")
	check(full:error() == serialize.SerializeError.PastEnd, "the refusal is PastEnd")
	check(full:bitsProcessed() == 64, "the refused wide write wrote nothing")

	testFiniteWrites()
end

return T
