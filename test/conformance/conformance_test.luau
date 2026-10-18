--!strict
-- conformance_test.luau — TestConformanceCorpus: the whole serialize
-- conformance corpus (STANDARD.md, The vector format, What a runner checks),
-- the cross-language instrument over every conformance/*.txt. It discovers
-- the directory (the runner plants each file as a string in inputs.luau),
-- never a fixed list, and fails unless every record ran.

local serialize = require("./serialize")
local inputs = require("./inputs")

local T = {}

local function fail(what: string): never
	error("TestConformanceCorpus: " .. what, 2)
end

local function check(cond: any, what: string)
	if not cond then
		fail(what)
	end
end

local function countOps(text: string): number
	local n = 0
	for line in text:gmatch("[^\n]+") do
		if line:match("^operation [%w_]+") then
			n += 1
		end
	end
	return n
end

-- ---------------------------------------------------------------------------
-- The parser (STANDARD.md, The vector format).

local function splitHex(s: string): { number }
	local out = {}
	for pair in s:gmatch("%x%x") do
		out[#out + 1] = tonumber("0x" .. pair) :: number
	end
	return out
end

local function countSpaces(s: string): number
	local n = 0
	for _ in s:gmatch(" ") do
		n += 1
	end
	return n
end

local function parseVecFile(text: string): { any }
	local records = {}
	local cur: any = nil
	local function flush()
		if cur ~= nil then
			table.insert(records, cur)
			cur = nil
		end
	end
	for _, line in ipairs(string.split(text, "\n")) do
		local trimmed = line:gsub("^%s+", ""):gsub("%s+$", "")
		if trimmed == "" then
			flush()
		elseif trimmed:sub(1, 1) == "#" then
		elseif cur == nil then
			local op = trimmed:match("^operation ([%w_]+)$")
			if op == nil then
				fail("vector line before a record: " .. trimmed)
			end
			cur = { op = op, name = "", params = {}, bytes = {}, expect = nil, consumed = nil, writer = false, measure = nil, steps = {} }
		else
			local v = trimmed:match("^name (.+)$")
			if v ~= nil then cur.name = v end
			local pk, pv = trimmed:match("^param ([%w_]+) = (.+)$")
			if pk == "step" then
				cur.steps[#cur.steps + 1] = parseStep(pv)
			elseif pk ~= nil then
				cur.params[pk] = pv
			end
			if trimmed == "bytes" then
				cur.bytes = {}
			else
				v = trimmed:match("^bytes (.*)$")
				if v ~= nil then cur.bytes = splitHex(v) end
			end
			v = trimmed:match("^expect (.*)$")
			if v ~= nil then
				if v == "refused" then
					cur.expect = { refused = true }
				else
					local bits = v:match("^bits = (0x%x+)$")
					if bits ~= nil then
						cur.expect = { refused = false, kind = "bits", value = bits }
					else
						local want = v:match("^value = ?(.*)$")
						if want ~= nil then
							cur.expect = { refused = false, kind = "value", value = want }
						else
							fail("bad expect in " .. cur.name .. ": " .. v)
						end
					end
				end
			end
			v = trimmed:match("^consumed (%-?%d+)$")
			if v ~= nil then cur.consumed = tonumber(v) end
			if trimmed == "writer canonical" then cur.writer = true end
			v = trimmed:match("^measure_at_least (%d+)$")
			if v ~= nil then cur.measure = tonumber(v) end
		end
	end
	flush()
	return records
end

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

local function sameBytes(want: { number }, got: buffer): boolean
	if #want ~= buffer.len(got) then return false end
	for i = 1, #want do
		if buffer.readu8(got, i - 1) ~= want[i] then return false end
	end
	return true
end

local function arraySame(a: { number }, b: { number }): boolean
	if #a ~= #b then return false end
	for i = 1, #a do
		if a[i] ~= b[i] then return false end
	end
	return true
end

local function decToInt(s: string): integer
	local hi = 0
	local lo = 0
	for i = 1, #s do
		local d = tonumber(s:sub(i, i)) :: number
		local v = lo * 10 + d
		local carry = math.floor(v / 4294967296)
		lo = v % 4294967296
		hi = hi * 10 + carry
	end
	return integer.bor(integer.lshift(integer.create(hi), 32i), integer.create(lo))
end

local Int128 = serialize.Int128

local function digitValue(ch: string): integer
	local byte = string.byte(ch) :: number
	if byte >= 48 and byte <= 57 then return integer.create(byte - 48) end
	if byte >= 97 and byte <= 102 then return integer.create(byte - 87) end
	if byte >= 65 and byte <= 70 then return integer.create(byte - 55) end
	fail("not a digit: " .. ch)
	return 0i
end

local function parse128(text: string): any
	local negative = string.sub(text, 1, 1) == "-"
	local body = if negative then string.sub(text, 2) else text
	local base = 10i
	if string.sub(body, 1, 2) == "0x" or string.sub(body, 1, 2) == "0X" then
		base = 16i
		body = string.sub(body, 3)
	end
	local acc = Int128.new(0i, 0i)
	for i = 1, #body do
		acc = Int128.add(Int128.mul(acc, Int128.from64(base)), Int128.from64(digitValue(body:sub(i, i))))
	end
	if negative then acc = Int128.neg(acc) end
	return acc
end

local function floor128(x: any): integer
	if Int128.cmp(x, Int128.from64(0i)) < 0 then
		return Int128.neg(Int128.floor(Int128.neg(x)))
	end
	return Int128.floor(x)
end

-- ---------------------------------------------------------------------------
-- Helpers for accepted/refused record checks (STANDARD.md, What a runner
-- checks).

local function checkTerminal(r: any, op: string, args: { any })
	local h = { value = 0 }
	local failed: boolean
	if op == "bits" then
		failed = not r:serializeBits(h, 1)
	elseif op == "bool" then
		failed = not r:serializeBool(h)
	else
		failed = not r:serializeBits64(h, 1)
	end
	check(failed, "a refused stream is not terminal")
end

local function runAcceptRead(r: any, rec: any, want: any, reader: (any) -> boolean)
	check(reader(r), rec.name .. ": accepted read refused (" .. tostring(r:error()) .. ")")
	check(r:bitsProcessed() == rec.consumed,
		rec.name .. ": consumed " .. tostring(r:bitsProcessed()) .. " != " .. tostring(rec.consumed))
end

-- ---------------------------------------------------------------------------
-- The single-operation runners.

local function runBits(r: any, rec: any)
	local bits = tonumber(rec.params.bits) :: number
	local function readOp(h: any): boolean
		if bits <= 32 then return r:serializeBits(h, bits) end
		return r:serializeBits64(h, bits)
	end
	if rec.expect.refused then
		local h = { value = 0 }
		check(not readOp(h), rec.name .. ": bits refused read succeeded")
		check(h.value == 0, rec.name .. ": refused bits read changed its holder")
		checkTerminal(r, "bits", {})
		return
	end
	if bits > 32 then
		local h = { value = 0i }
		check(readOp(h), rec.name .. ": accepted bits64 read refused")
		local want = decToInt(rec.expect.value)
		check(h.value == want, rec.name .. ": bits64 pattern mismatch")
		check(r:bitsProcessed() == rec.consumed, rec.name .. ": bits64 consumed")
	else
		local h = { value = 0 }
		check(readOp(h), rec.name .. ": accepted bits read refused")
		local want = tonumber(rec.expect.value) :: number
		check(h.value == want, rec.name .. ": bits value mismatch")
		check(r:bitsProcessed() == rec.consumed, rec.name .. ": bits consumed")
	end
	if rec.writer then
		local w = serialize.WriteStream.new(buffer.create(16))
		if bits <= 32 then
			check(w:serializeBits({ value = tonumber(rec.expect.value) }, bits), rec.name .. ": bits write refused")
		else
			check(w:serializeBits64({ value = decToInt(rec.expect.value) }, bits), rec.name .. ": bits64 write refused")
		end
		w:flush()
		check(sameBytes(rec.bytes, w:data()), rec.name .. ": bits writer bytes mismatch")
	end
end

local function runBool(r: any, rec: any)
	if rec.expect.refused then
		local h = { value = false }
		check(not r:serializeBool(h), rec.name .. ": bool refused read succeeded")
		check(h.value == false, rec.name .. ": refused bool read changed its holder")
		checkTerminal(r, "bool", {})
		return
	end
	local h = { value = false }
	check(r:serializeBool(h), rec.name .. ": accepted bool read refused")
	local want = rec.expect.value == "true"
	check(h.value == want, rec.name .. ": bool value mismatch")
	check(r:bitsProcessed() == rec.consumed, rec.name .. ": bool consumed")
	if rec.writer then
		local w = serialize.WriteStream.new(buffer.create(16))
		check(w:serializeBool({ value = want }), rec.name .. ": bool write refused")
		w:flush()
		check(sameBytes(rec.bytes, w:data()), rec.name .. ": bool writer bytes mismatch")
	end
end

local function runAlign(r: any, rec: any)
	local preceding = tonumber(rec.params.preceding_bits or "0") :: number
	if preceding > 0 then
		local discard = { value = 0 }
		check(r:serializeBits(discard, preceding), rec.name .. ": align preceding bits refused")
	end
	if rec.expect.refused then
		check(not r:serializeAlign(), rec.name .. ": align refused read succeeded")
		check(r:error() == serialize.SerializeError.Align, rec.name .. ": align refusal is not Align")
		checkTerminal(r, "bits", {})
		return
	end
	check(r:serializeAlign(), rec.name .. ": accepted align read refused")
	check(r:bitsProcessed() == rec.consumed, rec.name .. ": align consumed")
	if rec.writer then
		local w = serialize.WriteStream.new(buffer.create(16))
		if preceding > 0 then
			local v = rec.bytes[1] % (2 ^ preceding)
			check(w:serializeBits({ value = v }, preceding), rec.name .. ": align writer preceding refused")
		end
		check(w:serializeAlign(), rec.name .. ": align writer refused")
		w:flush()
		check(sameBytes(rec.bytes, w:data()), rec.name .. ": align writer bytes mismatch")
	end
end

local rangeKinds = {
	int = { parse = tonumber, open = "serializeInt" },
	int64 = { parse = decToInt, open = "serializeInt64" },
	int128 = { parse = parse128, open = "serializeInt128" },
}

local function equalVal(kind: string, a: any, b: any): boolean
	if kind == "int128" then return Int128.cmp(a, b) == 0 end
	return a == b
end

local function runRange(r: any, rec: any, kind: string)
	local k = rangeKinds[kind]
	local min = k.parse(rec.params.min)
	local max = k.parse(rec.params.max)
	local h = { value = min }
	local ok = r[k.open](r, h, min, max)
	if rec.expect.refused then
		check(not ok, rec.name .. ": " .. kind .. " refused read succeeded")
		check(r:error() ~= nil, rec.name .. ": " .. kind .. " refusal latched no error")
		check(equalVal(kind, h.value, min), rec.name .. ": " .. kind .. " refusal changed its holder")
		local before = r:bitsProcessed()
		local h2 = { value = min }
		check(not r[k.open](r, h2, min, max), rec.name .. ": " .. kind .. " stream was not terminal")
		check(r:bitsProcessed() == before, rec.name .. ": " .. kind .. " terminal read consumed bits")
		return
	end
	local want = k.parse(rec.expect.value)
	check(ok, rec.name .. ": " .. kind .. " accepted read refused")
	check(equalVal(kind, h.value, want), rec.name .. ": " .. kind .. " value mismatch")
	check(r:bitsProcessed() == rec.consumed, rec.name .. ": " .. kind .. " consumed")
	if rec.writer then
		local w = serialize.WriteStream.new(buffer.create(32))
		check(w[k.open](w, { value = want }, min, max), rec.name .. ": " .. kind .. " write refused")
		w:flush()
		check(sameBytes(rec.bytes, w:data()), rec.name .. ": " .. kind .. " writer bytes mismatch")
	end
end

local function runInt128(r: any, rec: any)
	runRange(r, rec, "int128")
end

local function runUint128(r: any, rec: any)
	local h = { value = Int128.new(0i, 0i) }
	local ok = r:serializeUint128(h)
	if rec.expect.refused then
		check(not ok, rec.name .. ": uint128 refused read succeeded")
		check(r:error() ~= nil, rec.name .. ": uint128 refusal latched no error")
		check(Int128.cmp(h.value, Int128.new(0i, 0i)) == 0, rec.name .. ": uint128 refusal changed its holder")
		local before = r:bitsProcessed()
		check(not r:serializeUint128({ value = Int128.new(0i, 0i) }), rec.name .. ": uint128 stream not terminal")
		check(r:bitsProcessed() == before, rec.name .. ": uint128 terminal read consumed bits")
		return
	end
	local want = parse128(rec.expect.value)
	check(ok, rec.name .. ": uint128 accepted read refused")
	check(Int128.cmp(h.value, want) == 0, rec.name .. ": uint128 value mismatch")
	check(r:bitsProcessed() == rec.consumed, rec.name .. ": uint128 consumed")
	if rec.writer then
		local w = serialize.WriteStream.new(buffer.create(16))
		check(w:serializeUint128({ value = want }), rec.name .. ": uint128 write refused")
		w:flush()
		check(sameBytes(rec.bytes, w:data()), rec.name .. ": uint128 writer bytes mismatch")
	end
end

local function hexToBits32(hex: string): number
	return (tonumber(hex:match("0x(%x+)") :: string, 16) :: number)
end

local function runFloat(r: any, rec: any)
	if rec.expect.refused then
		local h = { value = 12345.0 }
		check(not r:serializeFloat(h), rec.name .. ": float refused read succeeded")
		check(r:error() == serialize.SerializeError.Overflow, rec.name .. ": float refusal is not Overflow")
		local h2 = { value = 12345.0 }
		check(not r:serializeFloat(h2), rec.name .. ": float stream not terminal")
		return
	end
	local h = { value = 12345.0 }
	check(r:serializeFloat(h), rec.name .. ": float accepted read refused")
	local want = hexToBits32(rec.expect.value)
	local ff = serialize._family("float")
	check(ff.f32bits(h.value) == want, rec.name .. ": float read bits differ")
	check(r:bitsProcessed() == rec.consumed, rec.name .. ": float consumed")
	if rec.writer then
		local w = serialize.WriteStream.new(buffer.create(8))
		check(w:serializeFloat({ value = ff.f32frombits(want) }), rec.name .. ": float write refused")
		w:flush()
		check(sameBytes(rec.bytes, w:data()), rec.name .. ": float writer bytes mismatch")
	end
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

local function runDouble(r: any, rec: any)
	if rec.expect.refused then
		local h = { value = 12345.0 }
		check(not r:serializeDouble(h), rec.name .. ": double refused read succeeded")
		check(r:error() == serialize.SerializeError.Overflow, rec.name .. ": double refusal is not Overflow")
		local h2 = { value = 12345.0 }
		check(not r:serializeDouble(h2), rec.name .. ": double stream not terminal")
		return
	end
	local h = { value = 12345.0 }
	check(r:serializeDouble(h), rec.name .. ": double accepted read refused")
	local hex = rec.expect.value:match("0x(%x+)") :: string
	local padded = string.rep("0", 16 - #hex) .. hex
	local wantLo = tonumber(string.sub(padded, 1, 8), 16) :: number
	local wantHi = tonumber(string.sub(padded, 9, 16), 16) :: number
	local gotLo, gotHi = doubleBits(h.value)
	check(gotLo == wantLo and gotHi == wantHi, rec.name .. ": double read bits differ")
	check(r:bitsProcessed() == rec.consumed, rec.name .. ": double consumed")
	if rec.writer then
		local w = serialize.WriteStream.new(buffer.create(8))
		check(w:serializeDouble({ value = doubleFromBits(wantLo, wantHi) }), rec.name .. ": double write refused")
		w:flush()
		check(sameBytes(rec.bytes, w:data()), rec.name .. ": double writer bytes mismatch")
	end
end

local function skipBits(r: any, n: number)
	if n > 0 then
		local h = { value = 0 }
		check(r:serializeBits(h, n), "preceding_bits refused")
	end
end

local function newWrite(rec: any): any
	local preceding = tonumber(rec.params.preceding_bits or "0") :: number
	if preceding == 0 then
		return serialize.WriteStream.new(buffer.create(64))
	end
	local w = serialize.WriteStream.new(buffer.create(64))
	local v = rec.bytes[1] % (2 ^ preceding)
	check(w:serializeBits({ value = v }, preceding), "writer preceding bits refused")
	return w
end

local function runBytes(r: any, rec: any)
	local count = tonumber(rec.params.count) :: number
	skipBits(r, tonumber(rec.params.preceding_bits or "0") :: number)
	local dst = buffer.create(count)
	if rec.expect.refused then
		check(not r:serializeBytes(dst), rec.name .. ": bytes refused read succeeded")
		check(r:error() ~= nil, rec.name .. ": bytes refusal latched no error")
		local probe = buffer.create(1)
		buffer.writeu8(probe, 0, 0x5A)
		check(not r:serializeBytes(probe), rec.name .. ": bytes stream not terminal")
		return
	end
	local expectBytes = splitHex(rec.expect.value)
	check(r:serializeBytes(dst), rec.name .. ": bytes accepted read refused")
	check(arraySame(bufToBytes(dst), expectBytes), rec.name .. ": bytes decoded differ")
	check(r:bitsProcessed() == rec.consumed, rec.name .. ": bytes consumed")
	if rec.writer then
		local w = newWrite(rec)
		check(w:serializeBytes(bytesToBuffer(expectBytes)), rec.name .. ": bytes write refused")
		w:flush()
		check(sameBytes(rec.bytes, w:data()), rec.name .. ": bytes writer bytes mismatch")
	end
end

local function runString(r: any, rec: any)
	local bufferSize = tonumber(rec.params.buffer_size) :: number
	skipBits(r, tonumber(rec.params.preceding_bits or "0") :: number)
	local h = { value = "UNTOUCHED" }
	local ok = r:serializeString(h, bufferSize)
	if rec.expect.refused then
		check(not ok, rec.name .. ": string refused read succeeded")
		check(h.value == "UNTOUCHED", rec.name .. ": string refusal wrote its destination")
		check(r:error() ~= nil, rec.name .. ": string refusal latched no error")
		local probe = buffer.create(1)
		buffer.writeu8(probe, 0, 0x5A)
		check(not r:serializeBytes(probe), rec.name .. ": string stream not terminal")
		return
	end
	local want = buffer.tostring(bytesToBuffer(splitHex(rec.expect.value)))
	check(ok, rec.name .. ": string accepted read refused")
	check(h.value == want, rec.name .. ": string decoded differs")
	check(r:bitsProcessed() == rec.consumed, rec.name .. ": string consumed")
	if rec.writer then
		local w = newWrite(rec)
		check(w:serializeString({ value = want }, bufferSize), rec.name .. ": string write refused")
		w:flush()
		check(sameBytes(rec.bytes, w:data()), rec.name .. ": string writer bytes mismatch")
	end
end

local function unitsToString(units: { number }): string
	local parts = {}
	local i = 1
	while i <= #units do
		local unit = units[i]
		if unit >= 0xD800 and unit <= 0xDBFF then
			local low = units[i + 1] :: number
			local cp = 0x10000 + (unit - 0xD800) * 0x400 + (low - 0xDC00)
			parts[#parts + 1] = utf8.char(cp)
			i += 2
		else
			parts[#parts + 1] = utf8.char(unit)
			i += 1
		end
	end
	return table.concat(parts)
end

local function runWstring(r: any, rec: any)
	local bufferSize = tonumber(rec.params.buffer_size) :: number
	skipBits(r, tonumber(rec.params.preceding_bits or "0") :: number)
	local h = { value = "UNTOUCHED" }
	local ok = r:serializeWideString(h, bufferSize)
	if rec.expect.refused then
		check(not ok, rec.name .. ": wstring refused read succeeded")
		check(h.value == "UNTOUCHED", rec.name .. ": wstring refusal wrote its destination")
		check(r:error() ~= nil, rec.name .. ": wstring refusal latched no error")
		local probe = buffer.create(1)
		buffer.writeu8(probe, 0, 0x5A)
		check(not r:serializeBytes(probe), rec.name .. ": wstring stream not terminal")
		return
	end
	local units = {}
	for u in rec.expect.value:gmatch("%x+") do
		units[#units + 1] = tonumber(u, 16) :: number
	end
	local want = unitsToString(units)
	check(ok, rec.name .. ": wstring accepted read refused")
	check(h.value == want, rec.name .. ": wstring decoded differs")
	check(r:bitsProcessed() == rec.consumed, rec.name .. ": wstring consumed")
	if rec.writer then
		local w = newWrite(rec)
		check(w:serializeWideString({ value = want }, bufferSize), rec.name .. ": wstring write refused")
		w:flush()
		check(sameBytes(rec.bytes, w:data()), rec.name .. ": wstring writer bytes mismatch")
	end
end

local function runIntRelative(r: any, rec: any)
	local prev = tonumber(rec.params.previous) :: number
	local h = { value = -1 }
	local ok = r:serializeIntRelative(prev, h)
	if rec.expect.refused then
		check(not ok, rec.name .. ": int_relative refused read succeeded")
		check(h.value == -1, rec.name .. ": int_relative refusal wrote its destination")
		check(r:error() ~= nil, rec.name .. ": int_relative refusal latched no error")
		local again = { value = -1 }
		check(not r:serializeIntRelative(prev, again), rec.name .. ": int_relative stream not terminal")
		return
	end
	local want = tonumber(rec.expect.value) :: number
	check(ok, rec.name .. ": int_relative accepted read refused")
	check(h.value == want, rec.name .. ": int_relative decoded differs")
	check(r:bitsProcessed() == rec.consumed, rec.name .. ": int_relative consumed")
	if rec.writer then
		local w = serialize.WriteStream.new(buffer.create(16))
		check(w:serializeIntRelative(prev, { value = want }), rec.name .. ": int_relative write refused")
		w:flush()
		check(sameBytes(rec.bytes, w:data()), rec.name .. ": int_relative writer bytes mismatch")
	end
end

local function missingFamily(op: string)
	fail("operation " .. op .. " has no runner: src/serialize_" .. op .. ".luau is absent")
end

local function runFixed(r: any, rec: any)
	missingFamily("fixed")
end

local function runCompressedFloat(r: any, rec: any)
	missingFamily("compressed_float")
end

-- ---------------------------------------------------------------------------
-- Sequence steps (sequence.txt, object.txt, message.txt; STANDARD.md The
-- vector format, A sequence vector).

local function parseStep(s: string): { string }
	local out = {}
	for w in s:gmatch("%S+") do
		out[#out + 1] = w
	end
	return out
end

local function parseOneStep(r: any, st: { string }, out: { any }): boolean
	local op = st[1]
	if op == "bits" then
		local n = tonumber(st[2]) :: number
		local h = { value = 0 }
		local ok = r:serializeBits(h, n)
		table.insert(out, { ok = ok, value = h.value })
		return ok
	elseif op == "bool" then
		local h = { value = false }
		local ok = r:serializeBool(h)
		table.insert(out, { ok = ok, value = h.value })
		return ok
	elseif op == "align" then
		local ok = r:serializeAlign()
		table.insert(out, { ok = ok, value = nil })
		return ok
	elseif op == "float" then
		local h = { value = 12345.0 }
		local ok = r:serializeFloat(h)
		table.insert(out, { ok = ok, bits = serialize._family("float").f32bits(h.value) })
		return ok
	elseif op == "double" then
		local h = { value = 12345.0 }
		local ok = r:serializeDouble(h)
		local lo, hi = doubleBits(h.value)
		table.insert(out, { ok = ok, dlo = lo, dhi = hi })
		return ok
	elseif op == "bytes" then
		local n = tonumber(st[2]) :: number
		local dst = buffer.create(n)
		local ok = r:serializeBytes(dst)
		table.insert(out, { ok = ok, bytes = bufToBytes(dst) })
		return ok
	elseif op == "string" then
		local n = tonumber(st[2]) :: number
		local h = { value = "" }
		local ok = r:serializeString(h, n)
		table.insert(out, { ok = ok, str = h.value })
		return ok
	elseif op == "wstring" then
		local n = tonumber(st[2]) :: number
		local h = { value = "" }
		local ok = r:serializeWideString(h, n)
		local units = {}
		for u in utf8.codes(h.value) do
			if u >= 0x10000 then
				u = u - 0x10000
				units[#units + 1] = 0xD800 + math.floor(u / 0x400)
				units[#units + 1] = 0xDC00 + (u % 0x400)
			else
				units[#units + 1] = u
			end
		end
		table.insert(out, { ok = ok, wunits = units })
		return ok
	elseif op == "uint128" then
		local h = { value = Int128.new(0i, 0i) }
		local ok = r:serializeUint128(h)
		table.insert(out, { ok = ok, u128 = h.value })
		return ok
	elseif op == "int" then
		local mn = tonumber(st[2]) :: number
		local mx = tonumber(st[3]) :: number
		local h = { value = mn }
		local ok = r:serializeInt(h, mn, mx)
		table.insert(out, { ok = ok, value = h.value })
		return ok
	elseif op == "int64" then
		local mn = decToInt(st[2])
		local mx = decToInt(st[3])
		local h = { value = mn }
		local ok = r:serializeInt64(h, mn, mx)
		table.insert(out, { ok = ok, i64 = h.value })
		return ok
	elseif op == "int128" then
		local mn = parse128(st[2])
		local mx = parse128(st[3])
		local h = { value = mn }
		local ok = r:serializeInt128(h, mn, mx)
		table.insert(out, { ok = ok, i128 = h.value })
		return ok
	elseif op == "int_relative" then
		local prev = tonumber(st[2]) :: number
		local h = { value = -1 }
		local ok = r:serializeIntRelative(prev, h)
		table.insert(out, { ok = ok, value = h.value })
		return ok
	elseif op == "fixed" then
		missingFamily("fixed")
	elseif op == "compressed_float" then
		missingFamily("compressed_float")
	else
		fail("sequence step has no runner: " .. op)
	end
	return false
end

local function runSteps(r: any, steps: { { string } }, out: { any }): boolean
	local i = 1
	while i <= #steps do
		local st = steps[i]
		if st[1] == "object" then
			local n = tonumber(st[2]) :: number
			table.insert(out, { ok = true, value = nil })
			local inner = {}
			local ok = true
			for j = 1, n do
				local sub = steps[i + j]
				check(sub ~= nil, "object step outruns the step list")
				if not parseOneStep(r, sub, inner) then
					ok = false
				end
			end
			i += n
			if not ok then
				return false
			end
			for _, e in inner do
				table.insert(out, e)
			end
		else
			if not parseOneStep(r, st, out) then
				return false
			end
		end
		i += 1
	end
	return true
end

local function runSequence(r: any, rec: any)
	local steps = rec.steps
	local ok = runSteps(r, steps, {})
	if rec.expect.refused then
		check(not ok, rec.name .. ": refused sequence was accepted")
	else
		check(ok, rec.name .. ": accepted sequence was refused (" .. tostring(r:error()) .. ")")
	end
	if rec.measure ~= nil then
		local m = serialize.MeasureStream.new()
		runSteps(m, steps, {})
		check(m:bitsProcessed() >= rec.measure,
			rec.name .. ": measure " .. tostring(m:bitsProcessed()) .. " < floor " .. tostring(rec.measure))
	end
	if rec.writer then
		local w = serialize.WriteStream.new(buffer.create(128))
		check(runSteps(w, steps, {}), rec.name .. ": canonical sequence write was refused")
		w:flush()
		check(sameBytes(rec.bytes, w:data()), rec.name .. ": sequence writer bytes mismatch")
	end
end

local function runRecord(r: any, rec: any)
	local op = rec.op
	if op == "bits" then
		runBits(r, rec)
	elseif op == "bool" then
		runBool(r, rec)
	elseif op == "align" then
		runAlign(r, rec)
	elseif op == "int" then
		runRange(r, rec, "int")
	elseif op == "int64" then
		runRange(r, rec, "int64")
	elseif op == "int128" then
		runRange(r, rec, "int128")
	elseif op == "uint128" then
		runUint128(r, rec)
	elseif op == "float" then
		runFloat(r, rec)
	elseif op == "double" then
		runDouble(r, rec)
	elseif op == "bytes" then
		runBytes(r, rec)
	elseif op == "string" then
		runString(r, rec)
	elseif op == "wstring" then
		runWstring(r, rec)
	elseif op == "int_relative" then
		runIntRelative(r, rec)
	elseif op == "fixed" then
		runFixed(r, rec)
	elseif op == "compressed_float" then
		runCompressedFloat(r, rec)
	elseif op == "sequence" then
		runSequence(r, rec)
	else
		fail("no runner for operation " .. op .. " in " .. rec.name)
	end
end

local function runFile(name: string): number
	local text = (inputs :: any)[name]
	check(type(text) == "string", "inputs." .. name .. " is missing")
	local records = parseVecFile(text)
	local expected = countOps(text)
	check(#records == expected, name .. ".txt: parsed " .. #records .. " records, the file has " .. expected)
	check(#records > 0, name .. ".txt has no records")
	for _, rec in records do
		local r = serialize.ReadStream.new(bytesToBuffer(rec.bytes))
		runRecord(r, rec)
	end
	return #records
end

local function testUnknownOperationControl()
	local scratch = "operation widget\nname x\nbytes 00\nexpect value = 1\nconsumed 8\n"
	local records = parseVecFile(scratch)
	check(#records == 1, "scratch corpus has one record")
	local r = serialize.ReadStream.new(bytesToBuffer({ 0 }))
	local raised = false
	local ok, err = pcall(function()
		runRecord(r, records[1])
	end)
	if not ok and string.find(tostring(err), "no runner for operation widget", 1, true) ~= nil then
		raised = true
	end
	check(raised, "an operation with no runner must be REJECTED, not skipped")
end

local FILES = {
	"align", "bits", "bool", "bytes", "compressed_float", "double", "fixed",
	"float", "int", "int128", "int64", "int_relative", "message", "object",
	"sequence", "string", "uint128", "wstring",
}

function T.TestConformanceCorpus()
	local total = 0
	for _, f in FILES do
		local n = runFile(f)
		print(f .. ".txt: " .. n .. " records")
		total += n
	end
	print("conformance total: " .. total .. " records")
	testUnknownOperationControl()
end

return T

