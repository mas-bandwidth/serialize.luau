--!strict
-- conformance_test.luau — TestConformanceCorpus: the whole serialize
-- conformance corpus (STANDARD.md, The vector format, What a runner checks),
-- the cross-language instrument over every conformance/*.txt. It discovers
-- the directory (the runner plants each file as a string in inputs.luau),
-- never a fixed list, and fails unless every record ran.
--
-- Every record runs on its own; a record that fails is collected by name,
-- never stops the run. A refused record must refuse for the reason it states
-- (STANDARD.md, Refusal reasons: the stream's FIRST refusal), leave its
-- scalar destination unwritten and leave the stream terminal.
--
-- control.luau (planted by tools/luaurun) names the run. In the ordinary run
-- its name is empty and no record may fail. In a NEGATIVE CONTROL run
-- (STANDARD.md, "A gate nobody has seen go red"; tools/controls/controls.tsv)
-- the unit's source has one refusal rule deleted, or the corpus has
-- conformance-controls/unknown-operation.txt added, and the records that fail
-- must be EXACTLY the control's conformance-controls/<name>.expected list.

local serialize = require("./serialize")
local inputs = require("./inputs")
local control = require("./control")

local T = {}

local function fail(what: string): never
	error("TestConformanceCorpus: " .. what, 2)
end

local function check(cond: any, what: string)
	if not cond then
		fail(what)
	end
end

-- The closed list of refusal reasons, spelled as STANDARD.md, Refusal reasons
-- spells them. A refused record that states no reason, or a reason not in
-- this list, is a malformed vector, and the run is red.
local REASONS: { [string]: boolean } = {
	past_end = true,
	value_out_of_range = true,
	nonzero_padding = true,
	trailing_data = true,
	non_finite_float = true,
	invalid_utf8 = true,
	embedded_nul = true,
	non_canonical = true,
}

-- UNTOUCHED is the marker a refused read's destination starts with: no reader
-- could plausibly write it, so a refusal that writes its destination is seen.
-- The float steps, whose outcome is traced as bits, use 12345.0 instead.
local UNTOUCHED = "UNTOUCHED"

-- The keys a record may carry (STANDARD.md, The vector format). Any other key
-- makes the vector malformed and the run red: a key a runner skips is a check
-- nobody ran.
local KEYS: { [string]: boolean } = {
	operation = true,
	name = true,
	param = true,
	bytes = true,
	expect = true,
	consumed = true,
	writer = true,
	writer_input = true,
	measure_at_least = true,
}

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

local function parseStep(s: string): { string }
	local out = {}
	for w in s:gmatch("%S+") do
		out[#out + 1] = w
	end
	return out
end

local function parseVecFile(text: string): { any }
	local records = {}
	local cur: any = nil
	local function flush()
		if cur ~= nil then
			if cur.expect == nil then
				fail("malformed vector " .. cur.name .. ": no expect line")
			end
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
			cur = { op = op, name = "", params = {}, bytes = {}, expect = nil, consumed = nil, writer = false, writerInput = nil, measure = nil, steps = {} }
		else
			local key = trimmed:match("^(%S+)")
			if key == nil or not KEYS[key] or key == "operation" then
				fail("malformed vector " .. cur.name .. ": unknown key in " .. trimmed)
			end
			if key == "writer" and trimmed ~= "writer canonical" then
				fail("malformed vector " .. cur.name .. ": " .. trimmed)
			end
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
				if v:match("^refused") then
					local reason = v:match("^refused (%S+)$")
					if reason == nil or not REASONS[reason] then
						fail("malformed vector " .. cur.name .. ": expect " .. v .. " states no reason from the closed list")
					end
					cur.expect = { refused = true, reason = reason }
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
			v = trimmed:match("^writer_input (.*)$")
			if v ~= nil then
				local bits = v:match("^bits = (0x%x+)$")
				if bits == nil then
					fail("malformed vector " .. cur.name .. ": writer_input " .. v)
				end
				cur.writerInput = bits
			end
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
	local negative = string.sub(s, 1, 1) == "-"
	if negative then
		s = string.sub(s, 2)
	end
	local hi = 0
	local lo = 0
	for i = 1, #s do
		local d = tonumber(s:sub(i, i)) :: number
		local v = lo * 10 + d
		local carry = math.floor(v / 4294967296)
		lo = v % 4294967296
		hi = hi * 10 + carry
	end
	local result = integer.bor(integer.lshift(integer.create(hi), 32i), integer.create(lo))
	if negative then
		result = integer.sub(0i, result)
	end
	return result
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
	local h: { value: any } = { value = UNTOUCHED }
	local before = r:bitsProcessed()
	local failed: boolean
	if op == "bits" then
		failed = not r:serializeBits(h, 1)
	elseif op == "bool" then
		failed = not r:serializeBool(h)
	else
		failed = not r:serializeBits64(h, 1)
	end
	check(failed, "a refused stream is not terminal")
	check(r:bitsProcessed() == before, "a read after a refusal consumed bits")
	check(h.value == UNTOUCHED, "a read after a refusal wrote its destination")
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
		local h: { value: any } = { value = UNTOUCHED }
		check(not readOp(h), rec.name .. ": bits refused read succeeded")
		check(h.value == UNTOUCHED, rec.name .. ": refused bits read changed its holder")
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
		local h: { value: any } = { value = UNTOUCHED }
		check(not r:serializeBool(h), rec.name .. ": bool refused read succeeded")
		check(h.value == UNTOUCHED, rec.name .. ": refused bool read changed its holder")
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
	local h: { value: any } = { value = if rec.expect.refused then UNTOUCHED else min }
	local ok = r[k.open](r, h, min, max)
	if rec.expect.refused then
		check(not ok, rec.name .. ": " .. kind .. " refused read succeeded")
		check(r:error() ~= nil, rec.name .. ": " .. kind .. " refusal latched no error")
		check(h.value == UNTOUCHED, rec.name .. ": " .. kind .. " refusal changed its holder")
		local before = r:bitsProcessed()
		local h2: { value: any } = { value = UNTOUCHED }
		check(not r[k.open](r, h2, min, max), rec.name .. ": " .. kind .. " stream was not terminal")
		check(r:bitsProcessed() == before, rec.name .. ": " .. kind .. " terminal read consumed bits")
		check(h2.value == UNTOUCHED, rec.name .. ": " .. kind .. " terminal read wrote its holder")
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
	local h: { value: any } = { value = if rec.expect.refused then UNTOUCHED else Int128.new(0i, 0i) }
	local ok = r:serializeUint128(h)
	if rec.expect.refused then
		check(not ok, rec.name .. ": uint128 refused read succeeded")
		check(r:error() ~= nil, rec.name .. ": uint128 refusal latched no error")
		check(h.value == UNTOUCHED, rec.name .. ": uint128 refusal changed its holder")
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
		check(h.value == 12345.0, rec.name .. ": a refused float read wrote its destination")
		local h2 = { value = 12345.0 }
		local before = r:bitsProcessed()
		check(not r:serializeFloat(h2), rec.name .. ": float stream not terminal")
		check(r:bitsProcessed() == before and h2.value == 12345.0, rec.name .. ": a float read after a refusal consumed bits or wrote its destination")
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
		check(h.value == 12345.0, rec.name .. ": a refused double read wrote its destination")
		local h2 = { value = 12345.0 }
		local before = r:bitsProcessed()
		check(not r:serializeDouble(h2), rec.name .. ": double stream not terminal")
		check(r:bitsProcessed() == before and h2.value == 12345.0, rec.name .. ": a double read after a refusal consumed bits or wrote its destination")
		return
	end
	local h = { value = 12345.0 }
	check(r:serializeDouble(h), rec.name .. ": double accepted read refused")
	local hex = rec.expect.value:match("0x(%x+)") :: string
	local padded = string.rep("0", 16 - #hex) .. hex
	local wantHi = tonumber(string.sub(padded, 1, 8), 16) :: number
	local wantLo = tonumber(string.sub(padded, 9, 16), 16) :: number
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
	local integerBits = tonumber(rec.params.integer_bits) :: number
	local fractionBits = tonumber(rec.params.fraction_bits) :: number
	local min = decToInt(rec.params.min)
	local max = decToInt(rec.params.max)
	if integerBits + fractionBits <= 64 then
		local h: { value: any } = { value = if rec.expect.refused then UNTOUCHED else 0i }
		local ok = r:serializeFixed64(h, integerBits, fractionBits, min, max)
		if rec.expect.refused then
			check(not ok, rec.name .. ": fixed64 refused read succeeded")
			check(h.value == UNTOUCHED, rec.name .. ": fixed64 refusal changed its holder")
			check(r:error() ~= nil, rec.name .. ": fixed64 refusal latched no error")
			checkTerminal(r, "bits", {})
			return
		end
		local want = decToInt(rec.expect.value)
		check(ok, rec.name .. ": fixed64 accepted read refused")
		check(h.value == want, rec.name .. ": fixed64 value mismatch")
		check(r:bitsProcessed() == rec.consumed, rec.name .. ": fixed64 consumed")
		if rec.writer then
			local w = serialize.WriteStream.new(buffer.create(32))
			check(w:serializeFixed64({ value = want }, integerBits, fractionBits, min, max), rec.name .. ": fixed64 write refused")
			w:flush()
			check(sameBytes(rec.bytes, w:data()), rec.name .. ": fixed64 writer bytes mismatch")
		end
	else
		local h: { value: any } = { value = if rec.expect.refused then UNTOUCHED else Int128.new(0i, 0i) }
		local ok = r:serializeFixed128(h, integerBits, fractionBits, min, max)
		if rec.expect.refused then
			check(not ok, rec.name .. ": fixed128 refused read succeeded")
			check(h.value == UNTOUCHED, rec.name .. ": fixed128 refusal changed its holder")
			check(r:error() ~= nil, rec.name .. ": fixed128 refusal latched no error")
			checkTerminal(r, "bits", {})
			return
		end
		local want = parse128(rec.expect.value)
		check(ok, rec.name .. ": fixed128 accepted read refused")
		check(Int128.cmp(h.value, want) == 0, rec.name .. ": fixed128 value mismatch")
		check(r:bitsProcessed() == rec.consumed, rec.name .. ": fixed128 consumed")
		if rec.writer then
			local w = serialize.WriteStream.new(buffer.create(32))
			check(w:serializeFixed128({ value = want }, integerBits, fractionBits, min, max), rec.name .. ": fixed128 write refused")
			w:flush()
			check(sameBytes(rec.bytes, w:data()), rec.name .. ": fixed128 writer bytes mismatch")
		end
	end
end

local function runCompressedFloat(r: any, rec: any)
	local min = tonumber(rec.params.min) :: number
	local max = tonumber(rec.params.max) :: number
	local res = tonumber(rec.params.res) :: number
	local h = { value = 12345.0 }
	local ok = r:serializeCompressedFloat(h, min, max, res)
	if rec.expect.refused then
		check(not ok, rec.name .. ": compressed_float refused read succeeded")
		check(h.value == 12345.0, rec.name .. ": compressed_float refusal changed its holder")
		check(r:error() ~= nil, rec.name .. ": compressed_float refusal latched no error")
		checkTerminal(r, "bits", {})
		return
	end
	check(ok, rec.name .. ": compressed_float accepted read refused")
	local want = hexToBits32(rec.expect.value)
	check(serialize._family("float").f32bits(h.value) == want, rec.name .. ": compressed_float read bits differ")
	check(r:bitsProcessed() == rec.consumed, rec.name .. ": compressed_float consumed")
	check(not rec.writer, rec.name .. ": compressed_float has no canonical writer value")
end

-- runWriterInput hands the writer the record's writer_input float32 and
-- requires the record's bytes exactly (STANDARD.md, What a runner checks). It
-- runs on any record that carries one, refused records included.
local function runWriterInput(rec: any)
	check(rec.op == "compressed_float", rec.name .. ": writer_input on " .. rec.op)
	local w = serialize.WriteStream.new(buffer.create(16))
	local value = serialize._family("float").f32frombits(hexToBits32(rec.writerInput))
	check(w:serializeCompressedFloat({ value = value }, tonumber(rec.params.min), tonumber(rec.params.max), tonumber(rec.params.res)),
		rec.name .. ": writer_input write refused (" .. tostring(w:error()) .. ")")
	w:flush()
	check(sameBytes(rec.bytes, w:data()), rec.name .. ": writer_input bytes mismatch")
end

-- runEnd is end alone (STANDARD.md end): an accepted end consumes the whole
-- stream, a writer's end emits nothing and a measure's costs nothing.
local function runEnd(r: any, rec: any)
	if rec.expect.refused then
		check(not r:serializeEnd(), rec.name .. ": end refused read succeeded")
		checkTerminal(r, "bits", {})
		return
	end
	check(rec.expect.value == "0", rec.name .. ": an end's value is 0")
	check(r:serializeEnd(), rec.name .. ": accepted end refused (" .. tostring(r:error()) .. ")")
	check(r:bitsProcessed() == rec.consumed, rec.name .. ": end consumed")
	if rec.writer then
		local w = serialize.WriteStream.new(buffer.create(8))
		check(w:serializeEnd(), rec.name .. ": end write refused")
		check(w:bitsProcessed() == 0, rec.name .. ": a writer's end wrote bits")
		w:flush()
		check(sameBytes(rec.bytes, w:data()), rec.name .. ": end writer bytes mismatch")
		local m = serialize.MeasureStream.new()
		check(m:serializeEnd() and m:bitsProcessed() == 0, rec.name .. ": a measure's end cost bits")
	end
end

-- ---------------------------------------------------------------------------
-- Sequence steps (sequence.txt, object.txt, message.txt; STANDARD.md The
-- vector format, A sequence vector).

local function parseOneStep(r: any, st: { string }, out: { any }): boolean
	local op = st[1]
	local dec = st.decoded
	if op == "bits" then
		local n = tonumber(st[2]) :: number
		local base = if dec ~= nil then dec elseif r:isReading() then UNTOUCHED else 0
		local h = { value = base }
		local ok
		if n <= 32 then
			ok = r:serializeBits(h, n)
		else
			ok = r:serializeBits64(h, n)
		end
		table.insert(out, { op = op, ok = ok, value = h.value })
		if ok then st.decoded = h.value else check(h.value == base, "a refused bits step changed its holder") end
		return ok
	elseif op == "bool" then
		local base: any = if dec ~= nil then dec elseif r:isReading() then UNTOUCHED else false
		local h = { value = base }
		local ok = r:serializeBool(h)
		table.insert(out, { op = op, ok = ok, value = h.value })
		if ok then st.decoded = h.value else check(h.value == base, "a refused bool step changed its holder") end
		return ok
	elseif op == "align" then
		local ok = r:serializeAlign()
		table.insert(out, { op = op, ok = ok, value = nil })
		return ok
	elseif op == "end" then
		check(#st == 1, "the end step takes no parameters")
		local ok = r:serializeEnd()
		table.insert(out, { op = op, ok = ok, value = nil })
		return ok
	elseif op == "float" then
		local base = if dec ~= nil then dec else 12345.0
		local h = { value = base }
		local ok = r:serializeFloat(h)
		table.insert(out, { op = op, ok = ok, bits = serialize._family("float").f32bits(h.value) })
		if ok then st.decoded = h.value else check(h.value == base, "a refused float step changed its holder") end
		return ok
	elseif op == "double" then
		local base = if dec ~= nil then dec else 12345.0
		local h = { value = base }
		local ok = r:serializeDouble(h)
		local lo, hi = doubleBits(h.value)
		table.insert(out, { op = op, ok = ok, dlo = lo, dhi = hi })
		if ok then st.decoded = h.value else check(h.value == base, "a refused double step changed its holder") end
		return ok
	elseif op == "bytes" then
		local n = tonumber(st[2]) :: number
		if dec ~= nil then
			local ok = r:serializeBytes(bytesToBuffer(dec))
			table.insert(out, { op = op, ok = ok, bytes = dec })
			return ok
		end
		local dst = buffer.create(n)
		local ok = r:serializeBytes(dst)
		local decoded = bufToBytes(dst)
		table.insert(out, { op = op, ok = ok, bytes = decoded })
		if ok then
			st.decoded = decoded
		else
			for j = 0, n - 1 do
				check(buffer.readu8(dst, j) == 0, "a refused bytes step touched its destination")
			end
		end
		return ok
	elseif op == "string" then
		local n = tonumber(st[2]) :: number
		local base = if dec ~= nil then dec elseif r:isReading() then UNTOUCHED else ""
		local h = { value = base }
		local ok = r:serializeString(h, n)
		table.insert(out, { op = op, ok = ok, str = h.value })
		if ok then st.decoded = h.value else check(h.value == base, "a refused string step wrote its destination") end
		return ok
	elseif op == "uint128" then
		local base = if dec ~= nil then dec elseif r:isReading() then UNTOUCHED else Int128.new(0i, 0i)
		local h = { value = base }
		local ok = r:serializeUint128(h)
		table.insert(out, { op = op, ok = ok, u128 = h.value })
		if ok then st.decoded = h.value else check(h.value == base, "a refused uint128 step changed its holder") end
		return ok
	elseif op == "int" then
		local mn = tonumber(st[2]) :: number
		local mx = tonumber(st[3]) :: number
		local base = if dec ~= nil then dec elseif r:isReading() then UNTOUCHED else mn
		local h = { value = base }
		local ok = r:serializeInt(h, mn, mx)
		table.insert(out, { op = op, ok = ok, value = h.value })
		if ok then st.decoded = h.value else check(h.value == base, "a refused int step changed its holder") end
		return ok
	elseif op == "int64" then
		local mn = decToInt(st[2])
		local mx = decToInt(st[3])
		local base = if dec ~= nil then dec elseif r:isReading() then UNTOUCHED else mn
		local h = { value = base }
		local ok = r:serializeInt64(h, mn, mx)
		table.insert(out, { op = op, ok = ok, i64 = h.value })
		if ok then st.decoded = h.value else check(h.value == base, "a refused int64 step changed its holder") end
		return ok
	elseif op == "int128" then
		local mn = parse128(st[2])
		local mx = parse128(st[3])
		local base = if dec ~= nil then dec elseif r:isReading() then UNTOUCHED else mn
		local h = { value = base }
		local ok = r:serializeInt128(h, mn, mx)
		table.insert(out, { op = op, ok = ok, i128 = h.value })
		if ok then st.decoded = h.value else check(h.value == base, "a refused int128 step changed its holder") end
		return ok
	elseif op == "int_relative" then
		local prev = tonumber(st[2]) :: number
		local base = if dec ~= nil then dec elseif r:isReading() then UNTOUCHED else -1
		local h = { value = base }
		local ok = r:serializeIntRelative(prev, h)
		table.insert(out, { op = op, ok = ok, value = h.value })
		if ok then st.decoded = h.value else check(h.value == base, "a refused int_relative step changed its holder") end
		return ok
	elseif op == "fixed" then
		local ib = tonumber(st[2]) :: number
		local fb = tonumber(st[3]) :: number
		local mn = decToInt(st[4])
		local mx = decToInt(st[5])
		if ib + fb <= 64 then
			local base = if dec ~= nil then dec elseif r:isReading() then UNTOUCHED else 0i
			local h = { value = base }
			local ok = r:serializeFixed64(h, ib, fb, mn, mx)
			table.insert(out, { op = op, ok = ok, value = h.value })
			if ok then st.decoded = h.value else check(h.value == base, "a refused fixed64 step changed its holder") end
			return ok
		else
			local base = if dec ~= nil then dec elseif r:isReading() then UNTOUCHED else Int128.new(0i, 0i)
			local h = { value = base }
			local ok = r:serializeFixed128(h, ib, fb, mn, mx)
			table.insert(out, { op = op, ok = ok, i128 = h.value })
			if ok then st.decoded = h.value else check(h.value == base, "a refused fixed128 step changed its holder") end
			return ok
		end
	elseif op == "compressed_float" then
		local mn = tonumber(st[2]) :: number
		local mx = tonumber(st[3]) :: number
		local res = tonumber(st[4]) :: number
		local base = if dec ~= nil then dec elseif r:isReading() then 12345.0 else 0.0
		local h = { value = base }
		local ok = r:serializeCompressedFloat(h, mn, mx, res)
		table.insert(out, { op = op, ok = ok, bits = serialize._family("float").f32bits(h.value) })
		if ok then st.decoded = h.value else check(h.value == base, "a refused compressed_float step changed its holder") end
		return ok
	else
		fail("sequence step has no runner: " .. op)
	end
	return false
end

-- runSteps walks a sequence's steps in order. poison is true for a refused
-- (expect refused) record: STANDARD.md, What a runner checks, requires a
-- refusal to be terminal, so after the first failing step every later step
-- must also fail, consume no bits, and leave its destination untouched — the
-- runner must check that by behavior, not by an accessor.
local function runSteps(r: any, steps: { { string } }, out: { any }, poison: boolean): boolean
	local i = 1
	local failed = false
	local bitsAtFailure = 0
	local function noteFail()
		if failed then
			if poison then
				check(r:bitsProcessed() == bitsAtFailure,
					"a step after a refusal consumed bits")
			end
		else
			failed = true
			bitsAtFailure = r:bitsProcessed()
		end
	end
	while i <= #steps do
		local st = steps[i]
		if st[1] == "object" then
			local n = tonumber(st[2]) :: number
			table.insert(out, { op = "object", ok = true, value = nil })
			local inner = {}
			for j = 1, n do
				local sub = steps[i + j]
				check(sub ~= nil, "object step outruns the step list")
				local beforeFailed = failed
				local okStep = parseOneStep(r, sub, inner)
				if not okStep then
					noteFail()
				elseif beforeFailed and poison then
					check(false, "a step after a refusal succeeded")
				end
			end
			i += n
			for _, e in inner do
				table.insert(out, e)
			end
		else
			local beforeFailed = failed
			local okStep = parseOneStep(r, st, out)
			if not okStep then
				noteFail()
			elseif beforeFailed and poison then
				check(false, "a step after a refusal succeeded")
			end
		end
		i += 1
	end
	return not failed
end

local function hexToBits64(hex: string): (number, number)
	local s = hex:match("0x(%x+)") :: string
	s = string.rep("0", 16 - #s) .. s
	local hi = tonumber(string.sub(s, 1, 8), 16) :: number
	local lo = tonumber(string.sub(s, 9, 16), 16) :: number
	return lo, hi
end

-- checkSeqValue compares one step's decoded outcome against its `expect value`
-- entry, in the vector file's own spelling (STANDARD.md, What a runner checks:
-- the decoded value equals the value the record states).
local function checkSeqValue(rec: any, entry: any, want: string)
	if want == "-" then return end
	local op = entry.op
	if op == "bits" then
		if typeof(entry.value) == "integer" then
			check(decToInt(want) == entry.value, rec.name .. ": sequence bits (64-bit) value mismatch")
		else
			check(tonumber(want) == entry.value, rec.name .. ": sequence bits value mismatch")
		end
	elseif op == "int" or op == "int_relative" then
		check(tonumber(want) == entry.value, rec.name .. ": sequence " .. op .. " value mismatch")
	elseif op == "bool" then
		check(entry.value == (want == "true"), rec.name .. ": sequence bool mismatch")
	elseif op == "int64" then
		check(decToInt(want) == entry.i64, rec.name .. ": sequence int64 value mismatch")
	elseif op == "int128" then
		check(Int128.cmp(parse128(want), entry.i128) == 0, rec.name .. ": sequence int128 value mismatch")
	elseif op == "uint128" then
		check(Int128.cmp(parse128(want), entry.u128) == 0, rec.name .. ": sequence uint128 value mismatch")
	elseif op == "float" or op == "compressed_float" then
		check(hexToBits32(want) == entry.bits, rec.name .. ": sequence " .. op .. " bits mismatch")
	elseif op == "double" then
		local wantLo, wantHi = hexToBits64(want)
		check(entry.dlo == wantLo and entry.dhi == wantHi, rec.name .. ": sequence double bits mismatch")
	elseif op == "bytes" then
		check(arraySame(entry.bytes, splitHex(want)), rec.name .. ": sequence bytes mismatch")
	elseif op == "string" then
		check(entry.str == buffer.tostring(bytesToBuffer(splitHex(want))), rec.name .. ": sequence string mismatch")
	elseif op == "fixed" then
		if entry.i128 ~= nil then
			check(Int128.cmp(parse128(want), entry.i128) == 0, rec.name .. ": sequence fixed128 value mismatch")
		else
			check(decToInt(want) == entry.value, rec.name .. ": sequence fixed64 value mismatch")
		end
	elseif op == "align" or op == "object" or op == "end" then
		check(false, rec.name .. ": unexpected expect value for " .. op)
	end
end

local function runSequence(r: any, rec: any)
	local steps = rec.steps
	local out = {}
	local ok = runSteps(r, steps, out, rec.expect.refused)
	if rec.expect.refused then
		check(not ok, rec.name .. ": refused sequence was accepted")
	else
		check(ok, rec.name .. ": accepted sequence was refused (" .. tostring(r:error()) .. ")")
		local entries = string.split(rec.expect.value, " | ")
		check(#entries == #out, rec.name .. ": expect value lists " .. #entries .. " entries, ran " .. #out .. " steps")
		for i = 1, #entries do
			checkSeqValue(rec, out[i], entries[i])
		end
		check(r:bitsProcessed() == rec.consumed,
			rec.name .. ": sequence consumed " .. tostring(r:bitsProcessed()) .. " != " .. tostring(rec.consumed))
	end
	if rec.measure ~= nil then
		local m = serialize.MeasureStream.new()
		runSteps(m, steps, {}, false)
		check(m:bitsProcessed() >= rec.measure,
			rec.name .. ": measure " .. tostring(m:bitsProcessed()) .. " < floor " .. tostring(rec.measure))
	end
	if rec.writer then
		local w = serialize.WriteStream.new(buffer.create(128))
		check(runSteps(w, steps, {}, false), rec.name .. ": canonical sequence write was refused")
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
	elseif op == "end" then
		runEnd(r, rec)
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
	if rec.expect.refused then
		check(r:error() == rec.expect.reason,
			rec.name .. ": refused for " .. tostring(r:error()) .. ", the vector states " .. rec.expect.reason)
	end
	if rec.writerInput ~= nil then
		runWriterInput(rec)
	end
end

-- runFile runs every record of one corpus file, each on its own: a record
-- that fails is recorded in failures (name -> what failed) and the run goes
-- on. A name already seen anywhere in the corpus is malformed: names are
-- unique across the corpus (STANDARD.md, The vector format).
local function runFile(name: string, seen: { [string]: string }, failures: { [string]: string }): number
	local text = (inputs :: any)[name]
	check(type(text) == "string", "inputs." .. name .. " is missing")
	local records = parseVecFile(text)
	local expected = countOps(text)
	check(#records == expected, name .. ".txt: parsed " .. #records .. " records, the file has " .. expected)
	check(#records > 0, name .. ".txt has no records")
	for _, rec in records do
		check(rec.name ~= "", name .. ".txt has a record with no name")
		check(seen[rec.name] == nil, "vector name " .. rec.name .. " is in both " .. tostring(seen[rec.name]) .. ".txt and " .. name .. ".txt")
		seen[rec.name] = name
		local r = serialize.ReadStream.new(bytesToBuffer(rec.bytes))
		local ok, err = pcall(runRecord, r, rec)
		if not ok then
			failures[rec.name] = tostring(err)
		end
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

-- testMalformedVectors: a vector the runner cannot fully check is malformed
-- and makes the run red, never a skip: an unknown key (a writer_input the
-- runner did not know would be skipped without a sound), a refusal with no
-- reason or a reason off the closed list, and a record with no expect.
local function testMalformedVectors()
	local cases = {
		{ "operation bool\nname m1\nbytes 01\nexpect value = true\nconsumed 1\nwriter_inputs bits = 0x0\n", "unknown key" },
		{ "operation bool\nname m2\nbytes\nexpect refused\n", "states no reason" },
		{ "operation bool\nname m3\nbytes\nexpect refused overflow\n", "states no reason" },
		{ "operation bool\nname m4\nbytes 01\nconsumed 1\n", "no expect line" },
		{ "operation bool\nname m5\nbytes 01\nexpect value = true\nconsumed 1\nwriter maybe\n", "writer maybe" },
	}
	for _, case in cases do
		local ok, err = pcall(parseVecFile, case[1])
		check(not ok and string.find(tostring(err), case[2], 1, true) ~= nil,
			"a malformed vector was accepted (" .. case[2] .. "): " .. tostring(err))
	end
end

local function sortedInputNames(): { string }
	local names = {}
	for k in (inputs :: any) do
		table.insert(names, k)
	end
	table.sort(names)
	return names
end

local function sortedKeys(set: { [string]: any }): { string }
	local out = {}
	for k in set do
		table.insert(out, k)
	end
	table.sort(out)
	return out
end

-- expectedSet parses a conformance-controls/<name>.expected list: one vector
-- name per line, # comments and blank lines ignored.
local function expectedSet(text: string): { [string]: boolean }
	local out = {}
	for _, line in ipairs(string.split(text, "\n")) do
		local trimmed = line:gsub("^%s+", ""):gsub("%s+$", "")
		if trimmed ~= "" and trimmed:sub(1, 1) ~= "#" then
			out[trimmed] = true
		end
	end
	return out
end

function T.TestConformanceCorpus()
	local names = sortedInputNames()
	check(#names > 0, "no conformance files discovered: an empty corpus is a failure, not a pass")
	local total = 0
	local seen: { [string]: string } = {}
	local failures: { [string]: string } = {}
	for _, f in names do
		local n = runFile(f, seen, failures)
		print(f .. ".txt: " .. n .. " records")
		total += n
	end
	print("conformance total: " .. total .. " records")
	local failed = sortedKeys(failures)
	if control.name == "" then
		if #failed > 0 then
			local lines = {}
			for _, name in failed do
				table.insert(lines, failures[name])
			end
			fail(#failed .. " of " .. total .. " vectors failed:\n" .. table.concat(lines, "\n"))
		end
		print("conformance: " .. total .. " of " .. total .. " vectors pass")
		testUnknownOperationControl()
		testMalformedVectors()
		return
	end
	-- A NEGATIVE CONTROL run: the failures must be exactly the expected list.
	local want = expectedSet(control.expected)
	local wanted = sortedKeys(want)
	check(#wanted > 0, "control " .. control.name .. ": the expected list is empty")
	local wrong = {}
	for _, name in failed do
		if not want[name] then
			table.insert(wrong, "  failed but not expected: " .. name .. " (" .. failures[name] .. ")")
		end
	end
	for _, name in wanted do
		if failures[name] == nil then
			table.insert(wrong, "  expected but passed: " .. name)
		end
	end
	if #wrong > 0 then
		fail("control " .. control.name .. " did not fail exactly its expected list:\n" .. table.concat(wrong, "\n"))
	end
	print("control " .. control.name .. ": exactly the " .. #wanted .. " expected vectors failed")
end

return T

