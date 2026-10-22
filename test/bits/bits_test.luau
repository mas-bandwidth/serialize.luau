--!strict
-- bits_test.luau — TestSerializeBits (serialize-luau-bits): the bits family,
-- bits, bits64, bool, uint8/16/32/64, against the conformance corpus
-- (bits.txt, bool.txt, align.txt), plus serialize.go's Continue/Until round
-- trips and the MeasureStream bit counts.
--
-- The bits card's scope is the bits family (DESIGN.md (h)). uint128 and object
-- conformance belong to the int128 and strings cards, which are not
-- dependencies of this card.

local serialize = require("./serialize")

local T = {}

local function fail(what: string)
	error("TestSerializeBits: " .. what, 3)
end

-- ---------------------------------------------------------------------------
-- The vector file parser (STANDARD.md, The vector format).

local function splitHex(s: string): { number }
	local out = {}
	for pair in s:gmatch("%x%x") do
		table.insert(out, tonumber("0x" .. pair))
	end
	return out
end

local function countOps(text: string): number
	local n = 0
	for line in text:gmatch("[^\n]+") do
		if line:match("^operation %w+") then
			n = n + 1
		end
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
	for _, line in string.split(text, "\n") do
		local trimmed = line:gsub("^%s+", ""):gsub("%s+$", "")
		if trimmed == "" then
			flush()
		elseif trimmed:sub(1, 1) == "#" then
			-- comment
		elseif cur == nil then
			local op = trimmed:match("^operation (%w+)$")
			if op == nil then
				fail("vector line before a record: " .. trimmed)
			end
			cur = { op = op, name = "", params = {}, bytes = {}, expect = nil, consumed = nil, writer = false }
		else
			local v
			v = trimmed:match("^name (.+)$")
			if v ~= nil then
				cur.name = v
			end
			local pk, pv = trimmed:match("^param ([%w_]+) = (.+)$")
			if pk ~= nil then
				cur.params[pk] = pv
			end
			if trimmed == "bytes" then
				cur.bytes = {}
			else
				v = trimmed:match("^bytes (.*)$")
				if v ~= nil then
					cur.bytes = splitHex(v)
				end
			end
			v = trimmed:match("^expect (.*)$")
			if v ~= nil then
				if v == "refused" then
					cur.expect = { refused = true }
				else
					local want = v:match("^value = (.*)$")
					if want == nil then
						fail("bad expect in " .. cur.name .. ": " .. v)
					end
					cur.expect = { refused = false, value = want }
				end
			end
			v = trimmed:match("^consumed (%-?%d+)$")
			if v ~= nil then
				cur.consumed = tonumber(v)
			end
			if trimmed == "writer canonical" then
				cur.writer = true
			end
		end
	end
	flush()
	return records
end

local function bytesToBuffer(bytes: { number }): buffer
	local s = {}
	for _, b in bytes do
		table.insert(s, string.char(b))
	end
	return buffer.fromstring(table.concat(s))
end

local function sameBytes(want: { number }, got: buffer): boolean
	if #want ~= buffer.len(got) then
		return false
	end
	for i = 1, #want do
		if buffer.readu8(got, i - 1) ~= want[i] then
			return false
		end
	end
	return true
end

-- decimal text -> a 64-bit integer (the unsigned bit pattern).
local function decToInt(s: string): integer
	local hi = 0
	local lo = 0
	for i = 1, #s do
		local d = tonumber(s:sub(i, i))
		local v = lo * 10 + d
		local carry = math.floor(v / 4294967296)
		lo = v % 4294967296
		hi = hi * 10 + carry
	end
	return integer.bor(integer.lshift(integer.create(hi), 32i), integer.create(lo))
end

local function checkTerminal(r: any)
	local h = { value = 0 }
	if not r:serializeBits(h, 1) then
		return
	end
	fail("a refused stream is not terminal")
end

-- ---------------------------------------------------------------------------
-- The bits record: read and, when canonical, write.

local function runBits(r: any, rec: any)
	local bits = tonumber(rec.params.bits)
	if bits == nil then
		fail("bits record without a bits param: " .. rec.name)
	end

	local function readOp(h: any): boolean
		if bits <= 32 then
			return r:serializeBits(h, bits)
		end
		return r:serializeBits64(h, bits)
	end

	if rec.expect.refused then
		local h = { value = 0 }
		if readOp(h) then
			fail("bits refused read succeeded: " .. rec.name)
		end
		if h.value ~= 0 then
			fail("refused bits read left its holder changed: " .. rec.name)
		end
		checkTerminal(r)
		return
	end

	if bits <= 32 then
		local h = { value = 0 }
		if not readOp(h) then
			fail("accepted bits read refused: " .. rec.name)
		end
		local want = tonumber(rec.expect.value)
		if h.value ~= want then
			fail("bits value " .. tostring(h.value) .. " != " .. rec.expect.value .. " (" .. rec.name .. ")")
		end
		if r:bitsProcessed() ~= rec.consumed then
			fail("bits consumed " .. tostring(r:bitsProcessed()) .. " != " .. tostring(rec.consumed) .. " (" .. rec.name .. ")")
		end
	else
		local h = { value = 0i }
		if not readOp(h) then
			fail("accepted bits64 read refused: " .. rec.name)
		end
		local want = decToInt(rec.expect.value)
		if h.value ~= want then
			fail("bits64 pattern mismatch (" .. rec.name .. ")")
		end
		if r:bitsProcessed() ~= rec.consumed then
			fail("bits64 consumed " .. tostring(r:bitsProcessed()) .. " != " .. tostring(rec.consumed) .. " (" .. rec.name .. ")")
		end
	end

	if rec.writer then
		local w = serialize.WriteStream.new(buffer.create(16))
		if bits <= 32 then
			w:serializeBits({ value = tonumber(rec.expect.value) }, bits)
		else
			w:serializeBits64({ value = decToInt(rec.expect.value) }, bits)
		end
		w:flush()
		if not sameBytes(rec.bytes, w:data()) then
			fail("bits writer bytes mismatch (" .. rec.name .. ")")
		end
	end
end

-- ---------------------------------------------------------------------------
-- The bool record.

local function runBool(r: any, rec: any)
	if rec.expect.refused then
		local h = { value = false }
		if r:serializeBool(h) then
			fail("bool refused read succeeded: " .. rec.name)
		end
		if h.value ~= false then
			fail("refused bool read left its holder changed: " .. rec.name)
		end
		checkTerminal(r)
		return
	end

	local h = { value = false }
	if not r:serializeBool(h) then
		fail("accepted bool read refused: " .. rec.name)
	end
	local want = rec.expect.value == "true"
	if h.value ~= want then
		fail("bool value mismatch (" .. rec.name .. ")")
	end
	if r:bitsProcessed() ~= rec.consumed then
		fail("bool consumed " .. tostring(r:bitsProcessed()) .. " != " .. tostring(rec.consumed) .. " (" .. rec.name .. ")")
	end

	if rec.writer then
		local w = serialize.WriteStream.new(buffer.create(16))
		w:serializeBool({ value = want })
		w:flush()
		if not sameBytes(rec.bytes, w:data()) then
			fail("bool writer bytes mismatch (" .. rec.name .. ")")
		end
	end
end

-- ---------------------------------------------------------------------------
-- The align record.

local function runAlign(r: any, rec: any)
	local preceding = tonumber(rec.params.preceding_bits) or 0
	if preceding > 0 then
		local discard = { value = 0 }
		if not r:serializeBits(discard, preceding) then
			fail("align preceding bits refused: " .. rec.name)
		end
	end

	if rec.expect.refused then
		if r:serializeAlign() then
			fail("align refused read succeeded: " .. rec.name)
		end
		if r:error() ~= serialize.SerializeError.Align then
			fail("align refusal is not the Align error: " .. rec.name)
		end
		checkTerminal(r)
		return
	end

	if not r:serializeAlign() then
		fail("accepted align read refused: " .. rec.name)
	end
	if r:bitsProcessed() ~= rec.consumed then
		fail("align consumed " .. tostring(r:bitsProcessed()) .. " != " .. tostring(rec.consumed) .. " (" .. rec.name .. ")")
	end

	if rec.writer then
		local w = serialize.WriteStream.new(buffer.create(16))
		if preceding > 0 then
			local firstByte = rec.bytes[1]
			local v = firstByte % (2 ^ preceding)
			w:serializeBits({ value = v }, preceding)
		end
		if not w:serializeAlign() then
			fail("align writer refused: " .. rec.name)
		end
		w:flush()
		if not sameBytes(rec.bytes, w:data()) then
			fail("align writer bytes mismatch (" .. rec.name .. ")")
		end
	end
end

local function runFile(name: string)
	local text = (require("./inputs"))[name]
	local records = parseVecFile(text)
	local expected = countOps(text)
	if #records ~= expected then
		fail(name .. ".txt: parsed " .. tostring(#records) .. " records, expected " .. tostring(expected))
	end
	for _, rec in records do
		local r = serialize.ReadStream.new(bytesToBuffer(rec.bytes))
		if rec.op == "bits" then
			runBits(r, rec)
		elseif rec.op == "bool" then
			runBool(r, rec)
		elseif rec.op == "align" then
			runAlign(r, rec)
		else
			fail(name .. ".txt: unexpected operation " .. rec.op)
		end
	end
	print(name .. ".txt: " .. #records .. " records")
end

-- ---------------------------------------------------------------------------
-- Continue / Until (serialize.go TestContinue, TestUntil).

local function testContinue()
	local w = serialize.WriteStream.new(buffer.create(64))
	local items = { 10, 20, 30, 40, 50 }
	local more = { value = #items > 0 }
	local i = 0
	while serialize.Continue(w, more) do
		i = i + 1
		w:serializeBits({ value = items[i] }, 8)
		more.value = i < #items
	end
	w:flush()

	local r = serialize.ReadStream.new(w:data())
	local read = {}
	local more2 = { value = true }
	while serialize.Continue(r, more2) do
		local item = { value = 0 }
		r:serializeBits(item, 8)
		table.insert(read, item.value)
	end
	if #read ~= #items then
		fail("Continue read " .. tostring(#read) .. " items, want " .. tostring(#items))
	end
	for idx = 1, #items do
		if read[idx] ~= items[idx] then
			fail("Continue item " .. idx .. " mismatch")
		end
	end
end

local function testUntil()
	local w = serialize.WriteStream.new(buffer.create(64))
	local items = { 10, 20, 30, 40, 50 }
	local done = { value = #items == 0 }
	local i = 0
	while serialize.Until(w, done) do
		i = i + 1
		w:serializeBits({ value = items[i] }, 8)
		done.value = i == #items
	end
	w:flush()

	if w:bitsProcessed() ~= #items * 9 + 1 then
		fail("Until wrote " .. tostring(w:bitsProcessed()) .. " bits, want " .. tostring(#items * 9 + 1))
	end

	local r = serialize.ReadStream.new(w:data())
	local read = {}
	local done2 = { value = false }
	while serialize.Until(r, done2) do
		local item = { value = 0 }
		r:serializeBits(item, 8)
		table.insert(read, item.value)
	end
	if #read ~= #items then
		fail("Until read " .. tostring(#read) .. " items, want " .. tostring(#items))
	end
	for idx = 1, #items do
		if read[idx] ~= items[idx] then
			fail("Until item " .. idx .. " mismatch")
		end
	end

	local w2 = serialize.WriteStream.new(buffer.create(16))
	local d2 = { value = true }
	local n = 0
	while serialize.Until(w2, d2) do
		n = n + 1
	end
	w2:flush()
	if n ~= 0 or w2:bitsProcessed() ~= 1 then
		fail("Until empty sequence did not write one terminating bit")
	end
end

-- ---------------------------------------------------------------------------
-- MeasureStream bit counts for each bits-family operation.

local function testMeasure()
	local m = serialize.MeasureStream.new()
	m:serializeBits({ value = 0 }, 7)
	m:serializeBits64({ value = 0i }, 40)
	m:serializeBool({ value = true })
	m:serializeUint8({ value = 0 })
	m:serializeUint16({ value = 0 })
	m:serializeUint32({ value = 0 })
	m:serializeUint64({ value = 0i })
	m:serializeAlign()
	if m:bitsProcessed() ~= 7 + 40 + 1 + 8 + 16 + 32 + 64 + 7 then
		fail("measure bit counts: " .. tostring(m:bitsProcessed()))
	end
	if m:alignBits() ~= 7 then
		fail("measure alignBits is not the worst case 7")
	end
end

function T.TestSerializeBits()
	runFile("bits")
	runFile("bool")
	runFile("align")
	testContinue()
	testUntil()
	testMeasure()
end

return T
