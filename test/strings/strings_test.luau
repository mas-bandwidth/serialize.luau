--!strict
-- strings_test.luau — TestSerializeStrings (serialize-luau-strings): bytes
-- and string (DESIGN.md (a), (g), (h); STANDARD.md, Bytes and Strings,
-- Reader Obligations, The vector format).
--
-- It pins:
--   1. every record of conformance/bytes.txt and string.txt, as a runner
--      must: accepted reads decode the stated value, byte for byte, and
--      consume the stated bits; refused reads are refused for their stated
--      reason, leave a scalar destination untouched and leave the stream
--      terminal; every `writer canonical` record is reproduced byte for byte;
--   2. the string length fit check at its boundary
--      (TestStringLengthValidatedBeforeNarrowing);
--   3. the writer traps on what a reader refuses, naming the same reason, in
--      the same order, and latches nothing (IMPLEMENTING.md U9)
--      (TestStringWriterRefusesWhatReadersRefuse);
--   4. a wire-claimed length is checked against the bytes left before
--      anything that size is allocated (TestStringClaimCheckedBeforeAllocation).

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
				local reason = string.match(rest, "^refused (%S+)$")
				if reason ~= nil then
					rec.expect_kind = "refused"
					rec.reason = reason
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
		return require("./serialize_stream").family("bitpacker")
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
		else
			error("unknown operation " .. op .. " in " .. rec.name)
		end
		check(not ok, rec.name .. ": a refused vector was accepted")
		check(errorIs(read, rec.reason), rec.name .. ": refused for " .. tostring(read:error()) .. ", the vector states " .. tostring(rec.reason))
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
	else
		error("unknown operation " .. op .. " in " .. rec.name)
	end
	check(ok, rec.name .. ": an accepted vector was refused (" .. tostring(read:error()) .. ")")
	if op == "bytes" then
		check(sameBytes(got, hexBytes(rec.expect_text)), rec.name .. ": decoded bytes differ")
	else
		check(got == stringFromBytes(hexBytes(rec.expect_text)), rec.name .. ": decoded string differs")
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
		else
			local bufferSize = tonumber(rec.params.buffer_size) :: number
			wok = write:serializeString({ value = stringFromBytes(hexBytes(rec.expect_text)) }, bufferSize)
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
	local files = { "bytes", "string" }
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

-- trapsWith requires op to trap (IMPLEMENTING.md U9) with a raise naming
-- want, latch nothing on stream and move no bit.
local function trapsWith(stream: any, op: () -> any, want: string, what: string)
	local before = stream:bitsProcessed()
	local ok, err = pcall(op)
	check(not ok, what .. ": did not trap")
	check(string.find(tostring(err), want, 1, true) ~= nil, what .. ": trapped with " .. tostring(err) .. ", want " .. want)
	check(stream:error() == nil, what .. ": latched " .. tostring(stream:error()))
	check(stream:bitsProcessed() == before, what .. ": moved bits")
end

function T.TestStringLengthValidatedBeforeNarrowing()
	-- The fit check is length < bufferSize at the caller's own width, before
	-- the length field is formed. Each out of range case carries its negative
	-- control, a length one step inside the buffer.
	local bufferSize = 8
	local fits = string.rep("a", bufferSize - 1)
	local over = string.rep("a", bufferSize)

	local write = serialize.WriteStream.new(buffer.create(256))
	check(write:serializeString({ value = fits }, bufferSize),
		"a length of " .. (bufferSize - 1) .. " must fit a buffer of " .. bufferSize)
	trapsWith(write, function()
		return write:serializeString({ value = over }, bufferSize)
	end, "buffer size - 1", "a length of " .. bufferSize .. " in a buffer of " .. bufferSize)

	local measure = serialize.MeasureStream.new()
	check(measure:serializeString({ value = fits }, bufferSize), "the fitting measure was refused")
	trapsWith(measure, function()
		return measure:serializeString({ value = over }, bufferSize)
	end, "buffer size - 1", "the over-length measure")

	-- bufferSize itself has serialize.go's panicBufferSize domain, which is
	-- what makes the 32-bit length field total.
	local ok = pcall(function()
		serialize.WriteStream.new(buffer.create(64)):serializeString({ value = "" }, 2 ^ 31)
	end)
	check(not ok, "bufferSize 2^31 was accepted")
	local ok0 = pcall(function()
		serialize.WriteStream.new(buffer.create(64)):serializeString({ value = "" }, 0)
	end)
	check(not ok0, "bufferSize 0 was accepted")
end

function T.TestStringWriterRefusesWhatReadersRefuse()
	-- A writer is handed well-formed UTF-8 with no zero byte (STANDARD.md
	-- string). Handed anything else it traps (IMPLEMENTING.md U9), naming the
	-- reason a reader would give the same payload, NUL first, writes nothing
	-- and latches nothing; a measure traps the same way (U6).
	local cases = {
		{ "a\0b", serialize.SerializeError.EmbeddedNul },
		{ "\0", serialize.SerializeError.EmbeddedNul },
		{ "\xFF\0", serialize.SerializeError.EmbeddedNul },
		{ "\xFF", serialize.SerializeError.InvalidUtf8 },
		{ "\xC0\xAF", serialize.SerializeError.InvalidUtf8 },
		{ "\xED\xA0\x80", serialize.SerializeError.InvalidUtf8 },
		{ "\xE2\x82", serialize.SerializeError.InvalidUtf8 },
	}
	for i, case in cases do
		local write = serialize.WriteStream.new(buffer.create(64))
		trapsWith(write, function()
			return write:serializeString({ value = case[1] }, 64)
		end, case[2], "writer case " .. i)
		local measure = serialize.MeasureStream.new()
		trapsWith(measure, function()
			return measure:serializeString({ value = case[1] }, 64)
		end, case[2], "measure case " .. i)
	end
	-- Real text in every script travels: the writer accepts it and the reader
	-- hands back exactly the bytes, with no normalization.
	local text = "e\u{301} \u{E9} \u{56F2}\u{7881} \u{BC14}\u{B451} \u{627}\u{644} \u{FEFF}\u{FFFF} \u{1F600} \u{20000} \u{10FFFF}"
	local write = serialize.WriteStream.new(buffer.create(128))
	check(write:serializeString({ value = text }, 128), "real text was refused by the writer")
	write:flush()
	local read = serialize.ReadStream.new(write:data())
	local holder = { value = "" }
	check(read:serializeString(holder, 128), "real text was refused by the reader")
	check(holder.value == text, "real text did not round trip byte for byte")
end

function T.TestStringClaimCheckedBeforeAllocation()
	-- A wire-claimed length is checked against the bytes left BEFORE anything
	-- the size of the claim is allocated: a 4-byte stream claiming 2^31 - 2
	-- bytes under the largest buffer size is refused as past_end, never a
	-- raise from allocating the claim (a Luau buffer that large cannot be
	-- created at all, so allocating first raises here).
	local b = buffer.create(4)
	buffer.writeu32(b, 0, 0x7FFFFFFE)
	local read = serialize.ReadStream.new(b)
	local holder = { value = "UNTOUCHED" }
	local ok, result = pcall(function()
		return read:serializeString(holder, 0x7FFFFFFF)
	end)
	check(ok, "a huge claimed length raised: " .. tostring(result))
	check(result == false, "a huge claimed length was accepted")
	check(errorIs(read, serialize.SerializeError.PastEnd), "a huge claimed length refused for " .. tostring(read:error()))
	check(holder.value == "UNTOUCHED", "a huge claimed length wrote its destination")
end

return T
