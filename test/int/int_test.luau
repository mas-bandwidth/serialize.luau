--!strict
-- test/int/int_test.luau — TestSerializeInt (the int, int64 and int128
-- families; STANDARD.md, Integers: int (ranged), int64 (ranged), int128
-- (ranged); DESIGN.md (h)).
--
-- The conformance files are read from inputs.luau, written by tools/luaurun:
-- every record checks the canonical writer bytes and bits consumed, the
-- measure count, the reader's value and bits consumed, and a refusal's
-- destination and terminality. The edge cases are serialize.go v1.15.1's
-- TestBitsRequired, TestBitsRequired64 and TestSerializeInt64FullRange, plus
-- the writer's ValueOutOfRange latch one past each bound.

local serialize = require("./serialize")
local int = require("./serialize_int")
local int128 = require("./serialize_int128")
local inputs = require("./inputs")

local Int128 = int128.Int128

local function fail(message: string): never
	error(message, 2)
end

local function eq(actual: any, expected: any, what: string)
	if actual ~= expected then
		fail(string.format("%s: expected %s, got %s", what, tostring(expected), tostring(actual)))
	end
end

local function parseRecords(text: string): ({ any }, number)
	local records: { any } = {}
	local count = 0
	local current: any = nil
	for line in string.gmatch(text .. "\n", "([^\n]*)\n") do
		local op = string.match(line, "^operation%s+(%S+)")
		if op ~= nil then
			count += 1
			current = { op = op, params = {}, bytes = {} }
			table.insert(records, current)
		elseif current ~= nil and string.sub(line, 1, 1) ~= "#" then
			local name = string.match(line, "^name%s+(.+)$")
			if name ~= nil then
				current.name = name
			end
			local pname, pvalue = string.match(line, "^param%s+(%w+)%s*=%s*(.+)$")
			if pname ~= nil then
				current.params[pname] = pvalue
			end
			local bytes = string.match(line, "^bytes%s*(.*)$")
			if bytes ~= nil then
				for token in string.gmatch(bytes, "%x%x") do
					table.insert(current.bytes, tonumber(token, 16))
				end
			end
			local expect = string.match(line, "^expect%s+(.+)$")
			if expect ~= nil then
				current.expect = expect
				local reason = string.match(expect, "^refused (%S+)$")
				if reason ~= nil then
					current.expect = "refused"
					current.reason = reason
				end
				local value = string.match(expect, "^value%s*=%s*(.+)$")
				if value ~= nil then
					current.expectValue = value
				end
			end
			local consumed = string.match(line, "^consumed%s+(%d+)")
			if consumed ~= nil then
				current.consumed = tonumber(consumed)
			end
			if string.match(line, "^writer%s+canonical") ~= nil then
				current.canonical = true
			end
		end
	end
	return records, count
end

local function toBuffer(bytes: { number }): buffer
	local buf = buffer.create(#bytes)
	for i, b in bytes do
		buffer.writeu8(buf, i - 1, b)
	end
	return buf
end

local function sameBytes(buf: buffer, bytes: { number }): boolean
	if buffer.len(buf) ~= #bytes then
		return false
	end
	for i, b in bytes do
		if buffer.readu8(buf, i - 1) ~= b then
			return false
		end
	end
	return true
end

local function hex(bytes: { number }): string
	local parts = {}
	for _, b in bytes do
		table.insert(parts, string.format("%02X", b))
	end
	return table.concat(parts, " ")
end

local function bufferHex(buf: buffer): string
	local parts = {}
	for i = 0, buffer.len(buf) - 1 do
		table.insert(parts, string.format("%02X", buffer.readu8(buf, i)))
	end
	return table.concat(parts, " ")
end

local function parseInt32(text: string): number
	local value = tonumber(text)
	if value == nil or value % 1 ~= 0 then
		fail("not an int32: " .. text)
	end
	return value
end

local function parseInteger(text: string): integer
	local negative = string.sub(text, 1, 1) == "-"
	local body = if negative then string.sub(text, 2) else text
	local value: integer
	if string.sub(body, 1, 2) == "0x" or string.sub(body, 1, 2) == "0X" then
		value = integer.fromstring(string.sub(body, 3))
		if negative then
			value = integer.neg(value)
		end
	else
		value = integer.fromstring(text)
	end
	if value == nil then
		fail("not an integer: " .. text)
	end
	return value
end

local function digitValue(ch: string): integer
	local byte = string.byte(ch)
	if byte >= 48 and byte <= 57 then
		return integer.create(byte - 48)
	elseif byte >= 97 and byte <= 102 then
		return integer.create(byte - 87)
	elseif byte >= 65 and byte <= 70 then
		return integer.create(byte - 55)
	end
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
	for ch in string.gmatch(body, ".") do
		acc = Int128.add(Int128.mul(acc, Int128.from64(base)), Int128.from64(digitValue(ch)))
	end
	if negative then
		acc = Int128.neg(acc)
	end
	return acc
end

local function expectPair(actual: any, expected: any, what: string)
	if Int128.cmp(actual, expected) ~= 0 then
		fail(string.format("%s: Int128 mismatch", what))
	end
end

local kinds = {
	int = {
		opt = int,
		parse = parseInt32,
		equal = function(a: any, b: any): boolean
			return a == b
		end,
	},
	int64 = {
		opt = int,
		parse = parseInteger,
		equal = function(a: any, b: any): boolean
			return a == b
		end,
	},
	int128 = {
		opt = int128,
		parse = parse128,
		equal = function(a: any, b: any): boolean
			return Int128.cmp(a, b) == 0
		end,
	},
}

local armNames = {
	int = { write = "writeInt", read = "readInt", measure = "measureInt", open = "serializeInt", close = "serializeInt" },
	int64 = { write = "writeInt64", read = "readInt64", measure = "measureInt64", open = "serializeInt64", close = "serializeInt64" },
	int128 = { write = "writeInt128", read = "readInt128", measure = "measureInt128", open = "serializeInt128", close = "serializeInt128" },
}

local function runFile(file: string, label: string)
	local text = inputs[file]
	if text == nil then
		fail("inputs.luau has no " .. file)
	end
	local records, count = parseRecords(text)
	local operations = 0
	for _ in string.gmatch(text, "\noperation ") do
		operations += 1
	end
	print(string.format("test/int: %s has %d records", file, #records))
	if #records ~= count or count ~= operations then
		fail(string.format("%s: parsed %d records, declared %d, operation lines %d", file, #records, count, operations))
	end
	for _, record in records do
		local kind = kinds[record.op]
		local arms = armNames[record.op]
		if kind == nil then
			fail(label .. " " .. record.name .. ": unknown operation " .. record.op)
		end
		local min = kind.parse(record.params.min)
		local max = kind.parse(record.params.max)
		local buf = toBuffer(record.bytes)
		local what = file .. " " .. record.name
		if record.expectValue ~= nil then
			local expected = kind.parse(record.expectValue)
			local rs = serialize.ReadStream.new(buf)
			local holder = { value = min }
			local ok = rs[arms.open](rs, holder, min, max)
			if not ok then
				fail(what .. ": read refused: " .. tostring(rs:error()))
			end
			if not kind.equal(holder.value, expected) then
				fail(what .. ": read value mismatch")
			end
			eq(rs:bitsProcessed(), record.consumed, what .. ": read bits consumed")
			if record.canonical then
				local ws = serialize.WriteStream.new(buffer.create(32))
				local wh = { value = expected }
				if not ws[arms.open](ws, wh, min, max) then
					fail(what .. ": write refused: " .. tostring(ws:error()))
				end
				ws:flush()
				local data = ws:data()
				if not sameBytes(data, record.bytes) then
					fail(what .. ": canonical bytes expected [" .. hex(record.bytes) .. "] got [" .. bufferHex(data) .. "]")
				end
				eq(ws:bitsProcessed(), record.consumed, what .. ": write bits consumed")
				local ms = serialize.MeasureStream.new()
				if not ms[arms.open](ms, wh, min, max) then
					fail(what .. ": measure refused")
				end
				eq(ms:bitsProcessed(), record.consumed, what .. ": measured bits")
			end
		elseif record.expect == "refused" then
			local rs = serialize.ReadStream.new(buf)
			local sentinel = min
			local holder = { value = sentinel }
			local ok = rs[arms.open](rs, holder, min, max)
			if ok then
				fail(what .. ": expected a refusal, got a value")
			end
			if rs:error() ~= record.reason then
				fail(what .. ": refused for " .. tostring(rs:error()) .. ", the vector states " .. tostring(record.reason))
			end
			if not kind.equal(holder.value, sentinel) then
				fail(what .. ": refusal touched the destination")
			end
			local before = rs:bitsProcessed()
			if rs[arms.open](rs, holder, min, max) then
				fail(what .. ": stream was not terminal")
			end
			eq(rs:bitsProcessed(), before, what .. ": terminal read moved bits")
		else
			fail(what .. ": record has no value or refusal")
		end
	end
end

local function roundTrip(kindName: string, min: any, max: any, values: { any })
	local arms = armNames[kindName]
	for _, expected in values do
		local ws = serialize.WriteStream.new(buffer.create(16))
		local wh = { value = expected }
		if not ws[arms.open](ws, wh, min, max) then
			fail(kindName .. " write refused: " .. tostring(ws:error()))
		end
		ws:flush()
		local rs = serialize.ReadStream.new(ws:data())
		local holder = { value = min }
		if not rs[arms.open](rs, holder, min, max) then
			fail(kindName .. " read refused: " .. tostring(rs:error()))
		end
		if not kinds[kindName].equal(holder.value, expected) then
			fail(kindName .. " round trip mismatch")
		end
	end
end

local tests = {}

function tests.TestSerializeInt()
	runFile("int", "int")
	runFile("int64", "int64")
	runFile("int128", "int128")
end

function tests.TestBitsRequired()
	local cases = {
		{ 0, 0, 0 }, { 0, 1, 1 }, { 0, 2, 2 }, { 0, 3, 2 }, { 0, 4, 3 },
		{ 0, 5, 3 }, { 0, 6, 3 }, { 0, 7, 3 }, { 0, 8, 4 }, { 0, 255, 8 },
		{ 0, 65535, 16 }, { 0, 4294967295, 32 },
	}
	for _, c in cases do
		eq(int.bitsRequired(c[1], c[2]), c[3], string.format("bitsRequired(%d,%d)", c[1], c[2]))
	end
end

function tests.TestBitsRequired64()
	local minInt64 = integer.fromstring("-9223372036854775808")
	local maxInt64 = integer.fromstring("9223372036854775807")
	local negFiveBillion = integer.fromstring("-5000000000")
	local posFiveBillion = integer.fromstring("5000000000")
	local cases = {
		{ 0i, 0i, 0 }, { 0i, 1i, 1 }, { 0i, 255i, 8 }, { 0i, 4294967295i, 32 },
		{ 0i, 4294967296i, 33 }, { 0i, 1099511627776i, 41 },
		{ 0i, 0xffffffffffffffffi, 64 }, { minInt64, maxInt64, 64 },
		{ negFiveBillion, posFiveBillion, 34 },
	}
	for _, c in cases do
		eq(int.bitsRequired64(c[1], c[2]), c[3], "bitsRequired64")
	end
	eq(int128.bitsRequired128(Int128.from64(-5000000000i), Int128.from64(5000000000i)), 34, "bitsRequired128")
	eq(int128.bitsRequired128(Int128.from64(5i), Int128.from64(5i)), 0, "bitsRequired128 degenerate")
end

function tests.TestSerializeInt64FullRange()
	local minInt64 = integer.fromstring("-9223372036854775808")
	local maxInt64 = integer.fromstring("9223372036854775807")
	roundTrip("int64", minInt64, maxInt64, {
		minInt64,
		integer.add(minInt64, 1i),
		-1i,
		0i,
		1i,
		integer.sub(maxInt64, 1i),
		maxInt64,
	})
	local min = integer.fromstring("-5000000000")
	local max = integer.fromstring("5000000000")
	roundTrip("int64", min, max, {
		min,
		integer.add(min, 1i),
		-1i,
		0i,
		1i,
		4123456789i,
		integer.sub(max, 1i),
		max,
	})
	local ws = serialize.WriteStream.new(buffer.create(8))
	local h = { value = 55i }
	if not ws:serializeInt64(h, -100i, 100i) then
		fail("serializeInt64(-100,100) refused")
	end
	ws:flush()
	eq(ws:bitsProcessed(), 8, "serializeInt64(-100,100) bits")
	local rs = serialize.ReadStream.new(ws:data())
	local out = { value = 0i }
	if not rs:serializeInt64(out, -100i, 100i) or out.value ~= 55i then
		fail("serializeInt64(-100,100) round trip")
	end
end

function tests.TestIntBoundsLatch()
	local cases = {
		{ "int", 0, 7, 8, -1 },
		{ "int64", 0i, 7i, 8i, -1i },
		{ "int128", Int128.from64(0i), Int128.from64(7i), Int128.from64(8i), Int128.from64(-1i) },
	}
	for _, c in cases do
		local name, min, max, above, below = c[1], c[2], c[3], c[4], c[5]
		local arms = armNames[name]
		for _, value in { above, below } do
			local ws = serialize.WriteStream.new(buffer.create(8))
			local h = { value = value }
			if ws[arms.open](ws, h, min, max) then
				fail(name .. ": out of range value was written")
			end
			if ws:error() ~= "value_out_of_range" then
				fail(name .. ": expected value_out_of_range, got " .. tostring(ws:error()))
			end
			if ws:bitsProcessed() ~= 0 then
				fail(name .. ": refusal moved bits")
			end
			local ms = serialize.MeasureStream.new()
			if ms[arms.open](ms, h, min, max) then
				fail(name .. ": out of range value was measured")
			end
			eq(ms:error(), "value_out_of_range", name .. ": measure latch")
		end
	end
end

return tests
