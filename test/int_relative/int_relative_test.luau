--!strict
-- int_relative_test.luau — TestSerializeIntRelative (DESIGN.md (h), (i);
-- STANDARD.md int_relative). Every record of conformance/int_relative.txt is
-- run as the vector format directs, accepted reads and every refusal alike,
-- plus serialize.go's TestIntRelativeValidation cases. The record count is
-- printed and checked against the file's own count.

local T = {}

local serialize = require("./serialize")
local inputs = require("./inputs")

local INT_RELATIVE_MAX = 2147483647
local PANIC_DOMAIN = "serialize: int relative previous must be in [0,2147483647]"

local function check(cond: boolean, what: string)
	if not cond then
		error("TestSerializeIntRelative: " .. what, 2)
	end
end

local function raises(f: () -> (), want: string)
	local ok, err = pcall(f)
	check(not ok, "expected a raise containing " .. want)
	local msg = tostring(err)
	check(string.find(msg, want, 1, true) ~= nil, "raise was " .. msg .. ", want it to contain " .. want)
end

local function splitLines(text: string): { string }
	local lines = {}
	for line in string.gmatch(text .. "\n", "([^\n]*)\n") do
		table.insert(lines, line)
	end
	return lines
end

local function parseValue(v: string): any
	local hex = string.match(v, "^0x(%x+)$")
	if hex ~= nil then
		return tonumber(hex, 16)
	end
	return tonumber(v)
end

type Record = {
	name: string,
	previous: number,
	bytes: string,
	kind: string,
	value: number?,
	consumed: number?,
	writer: boolean,
}

local function parse(text: string): ({ Record }, number)
	local records: { Record } = {}
	local expected = 0
	local current: any = nil
	local function flush()
		if current ~= nil then
			check(current.operation == "int_relative", "record " .. tostring(current.name) .. " operation")
			check(current.previous ~= nil, "record " .. tostring(current.name) .. " previous")
			check(current.expect ~= nil, "record " .. tostring(current.name) .. " expect")
			local kind, value, hexbits = string.match(current.expect, "^(%S+)%s*=?%s*(.*)$")
			local rec: Record = {
				name = current.name or "?",
				previous = current.previous,
				bytes = current.bytes or "",
				kind = kind or "?",
				value = nil,
				consumed = if current.consumed ~= nil then parseValue(current.consumed) else nil,
				writer = current.writer == "canonical",
			}
			if kind == "value" then
				rec.value = parseValue(value)
			elseif kind == "bits" then
				local pattern = string.match(value, "^0x(%x+)$")
				check(pattern ~= nil, "record " .. rec.name .. " bits pattern")
				rec.value = tonumber(pattern, 16)
				rec.kind = "bits"
			else
				check(kind == "refused", "record " .. rec.name .. " expect kind " .. tostring(kind))
				rec.kind = "refused"
			end
			table.insert(records, rec)
			current = nil
		end
	end
	for _, raw in splitLines(text) do
		local line = string.match(raw, "^%s*(.-)%s*$") or ""
		if line == "" then
			flush()
		elseif string.sub(line, 1, 1) ~= "#" then
			if string.match(line, "^operation%f[%s]") then
				expected += 1
			end
			local key, value = string.match(line, "^(%S+)%s*(.*)$")
			if key == "param" then
				local pname, pval = string.match(value, "^(%S+)%s*=%s*(%S+)$")
				check(pname == "previous", "only the previous parameter is used: " .. line)
				current = current or {}
				current.previous = parseValue(pval)
			else
				current = current or {}
				current[key] = value
				if key == "bytes" then
					current.bytes = string.gsub(value, "%s+", "")
				end
			end
		end
	end
	flush()
	return records, expected
end

local function bytesOf(hex: string): buffer
	local chars = {}
	for i = 1, #hex, 2 do
		table.insert(chars, string.char(tonumber(string.sub(hex, i, i + 1), 16)))
	end
	return buffer.fromstring(table.concat(chars))
end

local function hexOf(data: buffer): string
	return string.upper(buffer.tostring(data))
end

local function hexString(data: buffer): string
	local out = {}
	for i = 0, buffer.len(data) - 1 do
		table.insert(out, string.format("%02X", buffer.readu8(data, i)))
	end
	return table.concat(out)
end

local function writeCurrent(previous: number, current: number): (buffer, any)
	local w = serialize.WriteStream.new(buffer.create(8))
	local h = { value = current }
	check(w:serializeIntRelative(previous, h), "write previous " .. previous .. " current " .. current)
	w:flush()
	return w:data(), w
end

local function readCurrent(previous: number, data: buffer): (boolean, any, any)
	local r = serialize.ReadStream.new(data)
	local h = { value = -1 }
	local ok = r:serializeIntRelative(previous, h)
	return ok, h, r
end

local function runRecords()
	local text = inputs.int_relative
	check(type(text) == "string", "conformance/int_relative.txt is in inputs")
	local records, expected = parse(text)
	print(string.format("int_relative records: %d (file %d)", #records, expected))
	check(#records == expected, "the parsed record count equals the file's records")
	for _, rec in records do
		local data = bytesOf(rec.bytes)
		local ok, holder, reader = readCurrent(rec.previous, data)
		if rec.kind == "refused" then
			check(not ok, rec.name .. ": expected a refusal")
			check(reader:error() ~= nil, rec.name .. ": a refusal latches")
			check(holder.value == -1, rec.name .. ": a refused read leaves the holder unwritten")
			-- after a refusal the stream is terminal: a second read refuses too
			local again = { value = -1 }
			check(not reader:serializeIntRelative(rec.previous, again), rec.name .. ": the stream is terminal")
			check(again.value == -1, rec.name .. ": the terminal read writes nothing")
		else
			check(ok, rec.name .. ": expected " .. tostring(rec.value))
			check(holder.value == rec.value, rec.name .. ": decoded " .. tostring(holder.value) .. ", want " .. tostring(rec.value))
			if rec.kind == "value" then
				check(reader:bitsProcessed() == rec.consumed, rec.name .. ": consumed " .. reader:bitsProcessed())
			end
			if rec.writer then
				local written, w = writeCurrent(rec.previous, rec.value)
				check(hexString(written) == rec.bytes, rec.name .. ": writer bytes " .. hexString(written) .. ", want " .. rec.bytes)
				check(w:bitsProcessed() == rec.consumed, rec.name .. ": writer bits " .. w:bitsProcessed())
				local m = serialize.MeasureStream.new()
				local mh = { value = rec.value }
				check(m:serializeIntRelative(rec.previous, mh), rec.name .. ": measure")
				check(m:bitsProcessed() == rec.consumed, rec.name .. ": measured " .. m:bitsProcessed() .. ", want " .. tostring(rec.consumed))
			end
		end
	end
end

local function validation()
	-- the 32 bit fallback must reject values that violate previous < current
	do
		local b = buffer.create(8)
		buffer.writebits(b, 0, 6, 0)
		buffer.writebits(b, 6, 32, 50)
		local ok, holder, reader = readCurrent(100, b)
		check(not ok and reader:error() == serialize.SerializeError.ValueOutOfRange, "the absolute tier refuses a non-increasing current")
		check(holder.value == -1, "the refused absolute read leaves the destination unwritten")
	end

	-- a legitimate fallback round trip succeeds
	do
		local written, _ = writeCurrent(100, 100000)
		local ok, holder = readCurrent(100, written)
		check(ok and holder.value == 100000, "absolute tier round trip")
	end

	-- the widest gap the domain allows takes the absolute tier and round trips
	do
		local written, w = writeCurrent(0, INT_RELATIVE_MAX)
		check(w:bitsProcessed() == 38, "the widest gap is 38 bits")
		local ok, holder = readCurrent(0, written)
		check(ok and holder.value == INT_RELATIVE_MAX, "widest gap round trip")
	end

	-- the reconstruction is checked in EVERY tier against the domain, and a
	-- refusal leaves the destination unwritten
	do
		local differences = { 1, 5, 10, 100, 1000, 10000 }
		for _, difference in differences do
			local written, _ = writeCurrent(10, 10 + difference)
			local ok, holder, reader = readCurrent(INT_RELATIVE_MAX, written)
			check(not ok, "difference " .. difference .. " past the domain top is refused")
			check(reader:error() == serialize.SerializeError.ValueOutOfRange, "difference " .. difference .. " latches value out of range")
			check(holder.value == -1, "difference " .. difference .. " leaves the destination unwritten")
		end
	end

	-- a previous outside the domain is API misuse on every stream, raised with
	-- serialize.go's panicIntRelativeDomain text
	do
		local cases = {
			function()
				local r = serialize.ReadStream.new(buffer.create(8))
				r:serializeIntRelative(-1, { value = 5 })
			end,
			function()
				local w = serialize.WriteStream.new(buffer.create(8))
				w:serializeIntRelative(-1, { value = 5 })
			end,
			function()
				local m = serialize.MeasureStream.new()
				m:serializeIntRelative(-1, { value = 5 })
			end,
			function()
				local r = serialize.ReadStream.new(buffer.create(8))
				r:serializeIntRelative(2147483648, { value = 5 })
			end,
		}
		for _, f in cases do
			raises(f, PANIC_DOMAIN)
		end
	end

	-- a write past current's domain latches rather than wrapping
	do
		local w = serialize.WriteStream.new(buffer.create(8))
		local h = { value = 2147483648 }
		check(not w:serializeIntRelative(0, h), "a current above the domain is refused")
		check(w:error() == serialize.SerializeError.ValueOutOfRange, "a current above the domain latches value out of range")
		check(w:bitsProcessed() == 0, "a refused write writes nothing")
	end
end

function T.TestSerializeIntRelative()
	runRecords()
	validation()
end

return T
