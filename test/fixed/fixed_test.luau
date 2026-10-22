--!strict
-- fixed_test.luau — TestSerializeFixed (serialize-luau-fixed): the fixed point
-- family (DESIGN.md (a), (c), (g), (h); STANDARD.md "fixed (Q format, ranged)").
--
-- It pins:
--   1. every record of conformance/fixed.txt, read in the read direction (expect
--      value / expect refused, with the consumed bit count), and in the write
--      direction for the records that carry `writer canonical`, byte for byte;
--      it prints the record count and fails unless it equals the file's count;
--   2. the misuse raises serialize.go panics on: a bad Q format and inverted or
--      unrepresentable whole-unit bounds (panicFixedParams, panicFixedBounds);
--   3. byte identity with the int64 ranged path for three Q formats, against an
--      independent BitWriter oracle written by this test.

local serialize = require("./serialize")
local inputs = require("./inputs")
local ReadStream = serialize.ReadStream
local WriteStream = serialize.WriteStream

local T = {}

local FIXED_RECORDS = 34

local function raises(f: () -> (), want: string)
	local ok, err = pcall(f)
	if ok then
		error("expected a raise containing " .. want, 2)
	end
	if string.find(tostring(err), want, 1, true) == nil then
		error("raise was " .. tostring(err) .. ", want it to contain " .. want, 2)
	end
end

-- ---------------------------------------------------------------------------
-- 128-bit pair helpers (the test's own copy, independent of the library).
type U128 = { lo: integer, hi: integer }

local function addU(x: U128, y: U128): U128
	local lo = integer.add(x.lo, y.lo)
	local carry = if integer.ult(lo, x.lo) then 1i else 0i
	local hi = integer.add(integer.add(x.hi, y.hi), carry)
	return { lo = lo, hi = hi }
end

local function subU(x: U128, y: U128): U128
	local lo = integer.sub(x.lo, y.lo)
	local borrow = if integer.ult(x.lo, y.lo) then 1i else 0i
	local hi = integer.sub(integer.sub(x.hi, y.hi), borrow)
	return { lo = lo, hi = hi }
end

local function cmpU(x: U128, y: U128): number
	if x.hi ~= y.hi then
		return if integer.ult(x.hi, y.hi) then -1 else 1
	end
	if x.lo ~= y.lo then
		return if integer.ult(x.lo, y.lo) then -1 else 1
	end
	return 0
end

local function bitLen64(v: integer): number
	local n = 0
	while v ~= 0i do
		v = integer.rshift(v, 1i)
		n += 1
	end
	return n
end

local function parseU128(s: string): U128
	local neg = false
	if s:sub(1, 1) == "-" then
		neg = true
		s = s:sub(2)
	end
	local v = { lo = 0i, hi = 0i }
	for i = 1, #s do
		local d = tonumber(s:sub(i, i))
		local v10 = { lo = v.lo, hi = v.hi }
		for _ = 1, 9 do
			v10 = addU(v10, v)
		end
		v = addU(v10, { lo = integer.create(d), hi = 0i })
	end
	if neg then
		v = subU({ lo = 0i, hi = 0i }, v)
	end
	return v
end

local function toInteger(s: string): integer
	return integer.fromstring(s)
end

-- ---------------------------------------------------------------------------
-- The conformance/fixed.txt parser (STANDARD.md, "The vector format").
local function parseRecords(text: string): { any }
	local recs = {}
	local cur: any = nil
	for line in text:gmatch("[^\n]+") do
		if line == "" then
			if cur then
				recs[#recs + 1] = cur
				cur = nil
			end
		elseif line:sub(1, 1) ~= "#" then
			local k, v = line:match("^([%w_]+)%s+(.*)$")
			if k == "operation" then
				if cur then
					recs[#recs + 1] = cur
				end
				cur = { op = v, params = {}, bytes = {} }
			elseif cur then
				if k == "param" then
					local name, val = v:match("^([%w_]+)%s*=%s*(.-)$")
					if not name then
						error("nil param name on line: " .. line, 2)
					end
					cur.params[name] = val
				elseif k == "bytes" then
					for b in v:gmatch("%x%x") do
						cur.bytes[#cur.bytes + 1] = tonumber(b, 16)
					end
				elseif k == "expect" then
					if v:find("refused", 1, true) then
						cur.want = "refused"
					else
						cur.want = "value"
						cur.value = v:match("value%s*=%s*(%S+)$")
					end
				elseif k == "consumed" then
					cur.consumed = tonumber(v)
				elseif k == "writer" then
					cur.writer = true
				end
			end
		end
	end
	if cur then
		recs[#recs + 1] = cur
	end
	return recs
end

local function bufFromBytes(bytes: { number }): buffer
	local b = buffer.create(#bytes)
	for i = 1, #bytes do
		buffer.writeu8(b, i - 1, bytes[i])
	end
	return b
end

local function bufferEqualsBuf(actual: buffer, bytes: { number })
	if buffer.len(actual) ~= #bytes then
		error("byte length " .. buffer.len(actual) .. " != golden " .. #bytes, 2)
	end
	for i = 1, #bytes do
		if buffer.readu8(actual, i - 1) ~= bytes[i] then
			error("byte " .. i - 1 .. " = " .. buffer.readu8(actual, i - 1) .. " != golden " .. bytes[i], 2)
		end
	end
end

-- Run one record in the read direction.
local function runReadRecord(rec)
	local ib = tonumber(rec.params.integer_bits)
	local fb = tonumber(rec.params.fraction_bits)
	local mn = toInteger(rec.params.min)
	local mx = toInteger(rec.params.max)
	local data = bufFromBytes(rec.bytes)
	local sum = ib + fb

	if sum <= 64 then
		local h = { value = 0i }
		local ok, err = pcall(function()
			local s = ReadStream.new(data)
			local r = s:serializeFixed64(h, ib, fb, mn, mx)
			if rec.want == "value" then
				if not r then
					error("expected success, stream refused: " .. tostring(s:error()), 2)
				end
				if h.value ~= toInteger(rec.value) then
					error("value mismatch in " .. rec.name, 2)
				end
				if s:bitsProcessed() ~= rec.consumed then
					error("consumed " .. s:bitsProcessed() .. " ~= " .. rec.consumed, 2)
				end
				if not s:ok() then
					error("stream error after success: " .. tostring(s:error()), 2)
				end
			else
				if r then
					error("expected refusal but read succeeded", 2)
				end
				if s:ok() then
					error("refusal did not latch", 2)
				end
			end
		end)
		if not ok then
			error(rec.name .. ": " .. tostring(err), 2)
		end
	else
		local h = { value = { lo = 0i, hi = 0i } }
		local ok, err = pcall(function()
			local s = ReadStream.new(data)
			local r = s:serializeFixed128(h, ib, fb, mn, mx)
			if rec.want == "value" then
				if not r then
					error("expected success, stream refused: " .. tostring(s:error()), 2)
				end
				local want = parseU128(rec.value)
				if cmpU(h.value, want) ~= 0 then
					error("wide value mismatch in " .. rec.name, 2)
				end
				if s:bitsProcessed() ~= rec.consumed then
					error("consumed " .. s:bitsProcessed() .. " ~= " .. rec.consumed, 2)
				end
				if not s:ok() then
					error("stream error after success: " .. tostring(s:error()), 2)
				end
			else
				if r then
					error("expected refusal but read succeeded", 2)
				end
				if s:ok() then
					error("refusal did not latch", 2)
				end
			end
		end)
		if not ok then
			error(rec.name .. ": " .. tostring(err), 2)
		end
	end
end

-- Run one record in the write direction (only records carrying `writer canonical`).
local function runWriteRecord(rec)
	local ib = tonumber(rec.params.integer_bits)
	local fb = tonumber(rec.params.fraction_bits)
	local mn = toInteger(rec.params.min)
	local mx = toInteger(rec.params.max)
	local sum = ib + fb
	local size = math.max(8, math.ceil(#rec.bytes / 8) * 8)
	local w = WriteStream.new(buffer.create(size))

	local ok, err = pcall(function()
		if sum <= 64 then
			local h = { value = toInteger(rec.value) }
			if not w:serializeFixed64(h, ib, fb, mn, mx) then
				error("writer refused: " .. tostring(w:error()), 2)
			end
		else
			local h = { value = parseU128(rec.value) }
			if not w:serializeFixed128(h, ib, fb, mn, mx) then
				error("writer refused: " .. tostring(w:error()), 2)
			end
		end
		w:flush()
	end)
	if not ok then
		error(rec.name .. " write: " .. tostring(err), 2)
	end
	bufferEqualsBuf(w:data(), rec.bytes)
end

-- The misuse raises (serialize.go panicFixedParams, panicFixedBounds; DESIGN.md (g)).
local function testMisuse()
	raises(function()
		local s = ReadStream.new(buffer.create(16))
		s:serializeFixed64({ value = 0i }, 0, 8, -100i, 100i)
	end, "fixed point requires integer bits >= 1")

	raises(function()
		local s = ReadStream.new(buffer.create(16))
		s:serializeFixed64({ value = 0i }, 8, -1, -100i, 100i)
	end, "fixed point requires integer bits >= 1")

	raises(function()
		local s = ReadStream.new(buffer.create(16))
		s:serializeFixed64({ value = 0i }, 33, 32, 0i, 100i)
	end, "fixed point requires integer bits >= 1")

	raises(function()
		local s = ReadStream.new(buffer.create(16))
		s:serializeFixed64({ value = 0i }, 8, 8, 100i, -100i)
	end, "fixed point requires integer bits >= 1")

	raises(function()
		local s = ReadStream.new(buffer.create(16))
		s:serializeFixed128({ value = { lo = 0i, hi = 0i } }, 64, 63, -100i, 100i)
	end, "fixed point requires integer bits >= 1")

	raises(function()
		local s = ReadStream.new(buffer.create(16))
		s:serializeFixed64({ value = 0i }, 8, 8, -200i, 100i)
	end, "fixed point bounds in whole units do not fit the Q format")

	raises(function()
		local s = ReadStream.new(buffer.create(16))
		s:serializeFixed64({ value = 0i }, 8, 8, -100i, 200i)
	end, "fixed point bounds in whole units do not fit the Q format")
end

-- Byte identity with the int64 ranged path for three Q formats, against an
-- independent BitWriter oracle (STANDARD.md fixed: for storage of 64 bits or
-- fewer the bytes are identical to serialize_int64 over the raw bounds).
local function testInt64ByteIdentity()
	local bitWriter = serialize.BitWriter
	local function oracleBytes(rawMin: integer, rawMax: integer, rawValue: integer): buffer
		local numBits = bitLen64(integer.sub(rawMax, rawMin))
		local w = bitWriter.new(buffer.create(64))
		local v = integer.sub(rawValue, rawMin)
		local nb = numBits
		while nb > 32 do
			w:writeBits(integer.tonumber(integer.band(v, 0xffffffffi)), 32)
			v = integer.rshift(v, 32i)
			nb -= 32
		end
		if nb > 0 then
			w:writeBits(integer.tonumber(v), nb)
		end
		w:flushBits()
		return w:data()
	end

	local cases = {
		{ 32, 0, 0, 1000, 123 },
		{ 16, 16, 0, 100, 1234567 },
		{ 48, 16, 0, 131072, 4294967296 },
	}
	for _, c in cases do
		local ib, fb, mn, mx, raw = c[1], c[2], integer.create(c[3]), integer.create(c[4]), integer.create(c[5])
		local rawMin = integer.lshift(mn, integer.create(fb))
		local rawMax = integer.lshift(mx, integer.create(fb))
		local w = WriteStream.new(buffer.create(32))
		if not w:serializeFixed64({ value = raw }, ib, fb, mn, mx) then
			error("fixed write refused in identity case", 2)
		end
		w:flush()
		local got = w:data()
		local want = oracleBytes(rawMin, rawMax, raw)
		if buffer.len(got) ~= buffer.len(want) then
			error("identity length " .. buffer.len(got) .. " != " .. buffer.len(want), 2)
		end
		for i = 0, buffer.len(got) - 1 do
			if buffer.readu8(got, i) ~= buffer.readu8(want, i) then
				error("identity byte " .. i .. " differs", 2)
			end
		end
	end
end

function T.TestSerializeFixed()
	local records = parseRecords(inputs.fixed)
	print("fixed records: " .. #records)
	if #records ~= FIXED_RECORDS then
		error("record count " .. #records .. " != file count " .. FIXED_RECORDS, 2)
	end
	for _, rec in records do
		runReadRecord(rec)
		if rec.writer then
			runWriteRecord(rec)
		end
	end
	testMisuse()
	testInt64ByteIdentity()
end

return T
