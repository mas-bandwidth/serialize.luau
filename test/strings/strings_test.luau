--!strict
-- strings_test.luau — TestSerializeStrings (serialize-luau-strings): bytes,
-- string and wstring (DESIGN.md (a), (g), (h); STANDARD.md, Bytes and Strings,
-- Reader Obligations, The vector format).
--
-- It pins:
--   1. every record of conformance/bytes.txt, string.txt and wstring.txt, as a
--      runner must: accepted reads decode the stated value and consume the
--      stated bits; refused reads are refused, leave a scalar destination
--      untouched and leave the stream terminal; every `writer canonical`
--      record is reproduced byte for byte;
--   2. serialize.go v1.15.1's TestSerializeWideStringFamilyPin bytes;
--   3. the wstring length fit check at its boundary
--      (TestWideStringLengthValidatedBeforeNarrowing).

local serialize = require("./serialize")
local inputs = require("./inputs")

local T = {}

local function check(cond: any, what: string)
	if not cond then
		error("TestSerializeStrings: " .. what, 2)
	end
end

local function hexBytes(text: string): { number }
	local out = {}
	if text == "" then
		return out
	end
	for pair in string.gmatch(text, "%x%x") do
		out[#out + 1] = tonumber(pair, 16) :: number
	end
	return out
end

local function hexUnits(text: string): { number }
	local out = {}
	for unit in string.gmatch(text, "%x+") do
		out[#out + 1] = tonumber(unit, 16) :: number
	end
	return out
end

local function bufferFromBytes(bytes: { number }): buffer
	local out = buffer.create(#bytes)
	for i = 1, #bytes do
		buffer.writeu8(out, i - 1, bytes[i])
	end
	return out
end

local function bufferToBytes(b: buffer): { number }
	local out = {}
	for i = 0, buffer.len(b) - 1 do
		out[#out + 1] = buffer.readu8(b, i)
	end
	return out
end

local function sameBytes(a: { number }, b: { number }): boolean
	if #a ~= #b then
		return false
	end
	for i = 1, #a do
		if a[i] ~= b[i] then
			return false
		end
	end
	return true
end

local function bytesText(bytes: { number }): string
	local parts = {}
	for i = 1, #bytes do
		parts[i] = string.format("%02X", bytes[i])
	end
	return table.concat(parts, " ")
end

local function stringFromBytes(bytes: { number }): string
	return buffer.tostring(bufferFromBytes(bytes))
end

-- unitsToString recombines a UTF-16 code unit sequence into a Luau string
-- (astral code points become one UTF-8 sequence).
local function unitsToString(units: { number }): string
	local parts = {}
	local i = 1
	while i <= #units do
		local unit = units[i]
		if unit >= 0xD800 and unit <= 0xDBFF then
			local low = units[i + 1]
			check(low ~= nil and low >= 0xDC00 and low <= 0xDFFF, "test fixture has an unpaired high surrogate")
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

-- Records (STANDARD.md, The vector format).
local function parseRecords(text: string): { any }
	local records = {}
	local current = {}
	local function flush()
		if #current == 0 then
			return
		end
		local rec: any = { params = {}, bytes = "", writer = false }
		for _, line in ipairs(current) do
			local key, rest = string.match(line, "^(%S+)%s*(.*)$")
			if key == "operation" then
				rec.operation = rest
			elseif key == "name" then
				rec.name = rest
			elseif key == "param" then
				local pname, pvalue = string.match(rest, "^(%S+)%s*=%s*(.*)$")
				check(pname ~= nil, "bad param line: " .. line)
				rec.params[pname] = pvalue
			elseif key == "bytes" then
				rec.bytes = rest
			elseif key == "expect" then
				if rest == "refused" then
					rec.expect_kind = "refused"
				else
					local kind, value = string.match(rest, "^(%S+)%s*=%s*(.*)$")
					check(kind ~= nil, "bad expect line: " .. line)
					rec.expect_kind = kind
					rec.expect_text = value
				end
			elseif key == "consumed" then
				rec.consumed = tonumber(rest)
			elseif key == "writer" then
				rec.writer = (rest == "canonical")
			end
		end
		check(rec.operation ~= nil and rec.name ~= nil, "record without operation/name")
		records[#records + 1] = rec
		current = {}
	end
	for line in string.gmatch(text .. "\n", "(.-)\n") do
		if line == "" then
			flush()
		elseif string.sub(line, 1, 1) ~= "#" then
			current[#current + 1] = line
		end
	end
	flush()
	return records
end

local function countOperations(text: string): number
	local n = 0
	for line in string.gmatch(text .. "\n", "(.-)\n") do
		if string.match(line, "^operation%f[%s]") then
			n += 1
		end
	end
	return n
end

-- setPosition places the operation at a non-aligned starting bit index. When
-- the bitpacker is present it is the stream's own bit path that advances; on a
-- base without it the raw bit index is set directly.
local function setPosition(stream: any, bits: number)
	if bits == 0 then
		return
	end
	local hasBitpacker = pcall(function()
		return serialize._family("bitpacker")
	end)
	if hasBitpacker then
		if stream:isReading() then
			stream:_readBits(bits)
		else
			stream:_writeBits(buffer.readbits(stream._data, 0, bits), bits)
		end
	else
		stream._bits = bits
	end
end

local function errorIs(stream: any, kind: string): boolean
	return stream:error() == kind
end

-- runRecord runs one vector. Returns true when the record exercised the
-- operation it names.
local function runRecord(rec: any)
	local op = rec.operation
	local bytes = hexBytes(rec.bytes)
	local preceding = tonumber(rec.params.preceding_bits or "0") :: number

	if rec.expect_kind == "refused" then
		local read = serialize.ReadStream.new(bufferFromBytes(bytes))
		setPosition(read, preceding)
		local ok: boolean
		local destination: any
		if op == "bytes" then
			local count = tonumber(rec.params.count) :: number
			destination = buffer.create(count)
			ok = read:serializeBytes(destination)
		elseif op == "string" then
			local bufferSize = tonumber(rec.params.buffer_size) :: number
			destination = { value = "UNTOUCHED" }
			ok = read:serializeString(destination, bufferSize)
		elseif op == "wstring" then
			local bufferSize = tonumber(rec.params.buffer_size) :: number
			destination = { value = "UNTOUCHED" }
			ok = read:serializeWideString(destination, bufferSize)
		else
			error("unknown operation " .. op .. " in " .. rec.name)
		end
		check(not ok, rec.name .. ": a refused vector was accepted")
		check(read:error() ~= nil, rec.name .. ": a refusal latched no error")
		if op ~= "bytes" then
			check(destination.value == "UNTOUCHED", rec.name .. ": a refusal wrote its destination")
		end
		-- Terminality by behavior: a later read fails, consumes nothing and
		-- writes nothing to its own destination.
		local before = read:bitsProcessed()
		local probe = buffer.create(1)
		buffer.writeu8(probe, 0, 0x5A)
		check(read:serializeBytes(probe) == false, rec.name .. ": the stream was not terminal")
		check(read:bitsProcessed() == before, rec.name .. ": a terminal read consumed bits")
		check(buffer.readu8(probe, 0) == 0x5A, rec.name .. ": a terminal read wrote its destination")
		return true
	end

	check(rec.expect_kind == "value", rec.name .. ": unsupported expect kind " .. tostring(rec.expect_kind))

	-- The read.
	local read = serialize.ReadStream.new(bufferFromBytes(bytes))
	setPosition(read, preceding)
	local got: any
	local ok: boolean
	if op == "bytes" then
		local count = tonumber(rec.params.count) :: number
		local dst = buffer.create(count)
		ok = read:serializeBytes(dst)
		got = bufferToBytes(dst)
	elseif op == "string" then
		local bufferSize = tonumber(rec.params.buffer_size) :: number
		local holder = { value = "UNTOUCHED" }
		ok = read:serializeString(holder, bufferSize)
		got = holder.value
	elseif op == "wstring" then
		local bufferSize = tonumber(rec.params.buffer_size) :: number
		local holder = { value = "UNTOUCHED" }
		ok = read:serializeWideString(holder, bufferSize)
		got = holder.value
	else
		error("unknown operation " .. op .. " in " .. rec.name)
	end
	check(ok, rec.name .. ": an accepted vector was refused (" .. tostring(read:error()) .. ")")
	if op == "bytes" then
		check(sameBytes(got, hexBytes(rec.expect_text)), rec.name .. ": decoded bytes differ")
	elseif op == "string" then
		check(got == stringFromBytes(hexBytes(rec.expect_text)), rec.name .. ": decoded string differs")
	else
		check(got == unitsToString(hexUnits(rec.expect_text)), rec.name .. ": decoded wide string differs")
	end
	local consumed = read:bitsProcessed()
	check(consumed == rec.consumed, rec.name .. ": consumed " .. consumed .. " bits, want " .. tostring(rec.consumed))

	-- The canonical writer. Seed the buffer with the record's own stream so
	-- the bits before the operation (an unaligned start) are the ones the
	-- record states, then emit the value and compare byte for byte.
	if rec.writer then
		local expected = bytes
		local size = math.max(8, math.ceil(#expected / 8) * 8)
		local buf = buffer.create(size)
		if #expected > 0 then
			buffer.copy(buf, 0, bufferFromBytes(expected), 0, #expected)
		end
		local write = serialize.WriteStream.new(buf)
		setPosition(write, preceding)
		local wok: boolean
		if op == "bytes" then
			wok = write:serializeBytes(bufferFromBytes(hexBytes(rec.expect_text)))
		elseif op == "string" then
			local bufferSize = tonumber(rec.params.buffer_size) :: number
			wok = write:serializeString({ value = stringFromBytes(hexBytes(rec.expect_text)) }, bufferSize)
		else
			local bufferSize = tonumber(rec.params.buffer_size) :: number
			wok = write:serializeWideString({ value = unitsToString(hexUnits(rec.expect_text)) }, bufferSize)
		end
		check(wok, rec.name .. ": the canonical write was refused (" .. tostring(write:error()) .. ")")
		write:flush()
		local actual = bufferToBytes(write:data())
		check(sameBytes(actual, expected),
			rec.name .. ": writer emitted " .. bytesText(actual) .. ", want " .. bytesText(expected))
	end
	return true
end

function T.TestSerializeStrings()
	local files = { "bytes", "string", "wstring" }
	local total = 0
	for _, file in ipairs(files) do
		local text = (inputs :: any)[file]
		check(type(text) == "string", "inputs." .. file .. " is missing")
		local records = parseRecords(text)
		local expected = countOperations(text)
		print(string.format("%s.txt: %d records", file, #records))
		check(#records == expected,
			file .. ".txt: parsed " .. #records .. " records, the file has " .. expected)
		check(#records > 0, file .. ".txt has no records")
		for _, rec in ipairs(records) do
			runRecord(rec)
		end
		total += #records
	end
	print(string.format("strings: %d records", total))
end

function T.TestSerializeWideStringFamilyPin()
	-- the family's pinned bytes: length 3 in a 3 bit field, then 0xD83D,
	-- 0xDE00, 0x0041 as 32 bit groups — 99 bits, 13 bytes.
	local pinned = {
		0xEB, 0xC1, 0x06, 0x00, 0x00, 0xF0, 0x06, 0x00, 0x08, 0x02, 0x00, 0x00, 0x00,
	}
	local value = utf8.char(0x1F600) .. "A"

	-- the wire spelled with raw bit operations must reproduce the pin.
	local raw = buffer.create(64)
	buffer.writebits(raw, 0, 3, 3)
	local bit = 3
	for _, group in ipairs({ 0xD83D, 0xDE00, 0x0041 }) do
		buffer.writebits(raw, bit, 32, group)
		bit += 32
	end
	local rawBytes = {}
	for i = 0, #pinned - 1 do
		rawBytes[#rawBytes + 1] = buffer.readu8(raw, i)
	end
	check(sameBytes(rawBytes, pinned), "raw bit operations disagree with the pinned bytes")

	local write = serialize.WriteStream.new(buffer.create(64))
	check(write:serializeWideString({ value = value }, 8), "family pin write refused")
	check(write:bitsProcessed() == 3 + 3 * 32, "family pin has the wrong bit count")
	write:flush()
	check(sameBytes(bufferToBytes(write:data()), pinned), "family pin write bytes differ")

	local measure = serialize.MeasureStream.new()
	check(measure:serializeWideString({ value = value }, 8), "family pin measure refused")
	check(measure:bitsProcessed() == write:bitsProcessed(), "family pin measure disagrees with write")

	local read = serialize.ReadStream.new(bufferFromBytes(pinned))
	local holder = { value = "" }
	check(read:serializeWideString(holder, 8), "family pin read refused")
	check(holder.value == value, "family pin read did not recombine the surrogate pair")
end

function T.TestWideStringLengthValidatedBeforeNarrowing()
	-- The fit check is length < bufferSize at the caller's own width, before
	-- the length field is formed. Each out of range case carries its negative
	-- control, a length one step inside the buffer.
	local bufferSize = 8
	local fits = string.rep("a", bufferSize - 1)
	local over = string.rep("a", bufferSize)

	local write = serialize.WriteStream.new(buffer.create(256))
	check(write:serializeWideString({ value = fits }, bufferSize),
		"a length of " .. (bufferSize - 1) .. " must fit a buffer of " .. bufferSize)
	check(write:serializeWideString({ value = over }, bufferSize) == false,
		"a length of " .. bufferSize .. " must not fit a buffer of " .. bufferSize)
	check(errorIs(write, serialize.SerializeError.ValueOutOfRange),
		"the over-length latch is not ValueOutOfRange")

	local measure = serialize.MeasureStream.new()
	check(measure:serializeWideString({ value = fits }, bufferSize), "the fitting measure was refused")
	check(measure:serializeWideString({ value = over }, bufferSize) == false,
		"the over-length measure was accepted")
	check(errorIs(measure, serialize.SerializeError.ValueOutOfRange),
		"the measure latch is not ValueOutOfRange")

	-- bufferSize itself has serialize.go's panicBufferSize domain, which is
	-- what makes the 32-bit length field total; the Go test's 2^32+5 lengths
	-- cannot be materialized as a Luau string, and this port forms no narrower
	-- integer before the fit comparison (the length is a double throughout).
	local ok = pcall(function()
		serialize.WriteStream.new(buffer.create(64)):serializeWideString({ value = "" }, 2 ^ 31)
	end)
	check(not ok, "bufferSize 2^31 was accepted")
	local ok0 = pcall(function()
		serialize.WriteStream.new(buffer.create(64)):serializeWideString({ value = "" }, 0)
	end)
	check(not ok0, "bufferSize 0 was accepted")
end

return T
