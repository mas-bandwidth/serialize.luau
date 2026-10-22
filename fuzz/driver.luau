--!strict
-- driver.luau — the fuzz differential driver. The Go test writes a batch of
-- programs as the module inputs.luau (a string) into a temp run directory with
-- a copy of src/, runs this driver under the pinned Luau interpreter, and
-- compares the driver's output against serialize.go's. Each program is a
-- sequence of steps; the driver writes it, reports the bytes, reads them back
-- and (when the program is mutated) reads a mutated copy, printing results as
-- lowercase hex lines for the Go side to compare. Every read ends with
-- serializeEnd (Z when accepted), and a refusal is E: and its reason.

local S = require("./serialize")
local FLT = require("./serialize_float")

local BUFSIZE = 4096

local function bufToHex(buf)
	local n = buffer.len(buf)
	local parts = {}
	for i = 0, n - 1 do
		parts[i + 1] = string.format("%02x", buffer.readu8(buf, i))
	end
	return table.concat(parts)
end

local function hexToBuf(h)
	local n = #h // 2
	local buf = buffer.create(n)
	for i = 0, n - 1 do
		buffer.writeu8(buf, i, tonumber(string.sub(h, i * 2 + 1, i * 2 + 2), 16))
	end
	return buf
end

local function hexToStr(h)
	local buf = hexToBuf(h)
	return buffer.tostring(buf)
end

local function strToHex(s)
	return bufToHex(buffer.fromstring(s))
end

local function bin64(lo, hi)
	return integer.bor(integer.lshift(integer.create(hi), 32i), integer.create(lo))
end

local function split64(x)
	return integer.tonumber(integer.band(x, 0xffffffffi)), integer.tonumber(integer.rshift(x, 32i))
end

local function hex64(x)
	local lo, hi = split64(x)
	return "h" .. tostring(lo) .. ":" .. tostring(hi)
end

local function n128(w)
	return S.Int128.new(bin64(w[1], w[2]), bin64(w[3], w[4]))
end

local function hex128(v)
	local l1, l2 = split64(v.lo)
	local h1, h2 = split64(v.hi)
	return "H" .. tostring(l1) .. ":" .. tostring(l2) .. ":" .. tostring(h1) .. ":" .. tostring(h2)
end

local function dbl(lo, hi)
	local b = buffer.create(8)
	buffer.writeu32(b, 0, lo)
	buffer.writeu32(b, 4, hi)
	return buffer.readf64(b, 0)
end

local function dblWords(x)
	local b = buffer.create(8)
	buffer.writef64(b, 0, x)
	return buffer.readu32(b, 0), buffer.readu32(b, 4)
end

local function i32(u)
	if u >= 2147483648 then
		return u - 4294967296
	end
	return u
end

local function applyMutation(data, tokens)
	local kind = tokens[1]
	if kind == "F" then
		local bi = tonumber(tokens[2])
		local bit = tonumber(tokens[3])
		local buf = buffer.create(buffer.len(data))
		buffer.copy(buf, 0, data, 0, buffer.len(data))
		if bi < buffer.len(buf) then
			local b = buffer.readu8(buf, bi)
			buffer.writeu8(buf, bi, bit32.bxor(b, bit32.lshift(1, bit)))
		end
		return buf
	elseif kind == "T" then
		local k = tonumber(tokens[2])
		if k > buffer.len(data) then
			k = buffer.len(data)
		end
		local buf = buffer.create(k)
		buffer.copy(buf, 0, data, 0, k)
		return buf
	else
		local n = tonumber(tokens[2])
		local buf = buffer.create(buffer.len(data) + n)
		buffer.copy(buf, 0, data, 0, buffer.len(data))
		for i = 0, n - 1 do
			buffer.writeu8(buf, buffer.len(data) + i, 0)
		end
		return buf
	end
end

local function parseProgram(lines)
	local prog = {}
	for _, ln in ipairs(lines) do
		local tokens = {}
		for tok in string.gmatch(ln, "%S+") do
			tokens[#tokens + 1] = tok
		end
		local op = tokens[1]
		local words = {}
		for k = 2, #tokens do
			local t = tonumber(tokens[k])
			if t then
				words[#words + 1] = t
			end
		end
		local st = { op = op, words = words }
		if op == "b" or op == "b64" then
			st.bits = words[#words]
		end
		if op == "s" then
			st.bufsize = words[1]
			st.hex = tokens[3]
		end
		if op == "by" then
			st.hex = tokens[2]
		end
		prog[#prog + 1] = st
	end
	return prog
end

local function writeProgram(prog)
	local buf = buffer.create(BUFSIZE)
	local ws = S.WriteStream.new(buf)
	local lastop = "?"
	for _, st in ipairs(prog) do
		local op = st.op
		local w = st.words
		lastop = op
		if op == "b" then
			ws:serializeBits({ value = w[1] }, st.bits)
		elseif op == "b64" then
			ws:serializeBits64({ value = bin64(w[1], w[2]) }, st.bits)
		elseif op == "bl" then
			ws:serializeBool({ value = w[1] == 1 })
		elseif op == "u8" then
			ws:serializeUint8({ value = w[1] })
		elseif op == "u16" then
			ws:serializeUint16({ value = w[1] })
		elseif op == "u32" then
			ws:serializeUint32({ value = w[1] })
		elseif op == "u64" then
			ws:serializeUint64({ value = bin64(w[1], w[2]) })
		elseif op == "i" then
			ws:serializeInt({ value = i32(w[1]) }, i32(w[2]), i32(w[3]))
		elseif op == "i64" then
			ws:serializeInt64({ value = bin64(w[1], w[2]) }, bin64(w[3], w[4]), bin64(w[5], w[6]))
		elseif op == "i128" then
			ws:serializeInt128({ value = n128(w) }, n128({ w[5], w[6], w[7], w[8] }), n128({ w[9], w[10], w[11], w[12] }))
		elseif op == "u128" then
			ws:serializeUint128({ value = n128(w) })
		elseif op == "fx" then
			ws:serializeFixed64({ value = bin64(w[1], w[2]) }, w[3], w[4], bin64(w[5], w[6]), bin64(w[7], w[8]))
		elseif op == "f128" then
			ws:serializeFixed128({ value = S.Int128.new(bin64(w[1], w[2]), bin64(w[3], w[4])) }, w[5], w[6], bin64(w[7], w[8]), bin64(w[9], w[10]))
		elseif op == "cf" then
			ws:serializeCompressedFloat({ value = FLT.f32frombits(w[1]) }, FLT.f32frombits(w[2]), FLT.f32frombits(w[3]), FLT.f32frombits(w[4]))
		elseif op == "ir" then
			ws:serializeIntRelative(i32(w[1]), { value = i32(w[2]) })
		elseif op == "f" then
			ws:serializeFloat({ value = FLT.f32frombits(w[1]) })
		elseif op == "d" then
			ws:serializeDouble({ value = dbl(w[1], w[2]) })
		elseif op == "by" then
			ws:serializeBytes(hexToBuf(st.hex))
		elseif op == "s" then
			ws:serializeString({ value = hexToStr(st.hex) }, st.bufsize)
		elseif op == "al" then
			ws:serializeAlign()
		elseif op == "ob" then
			ws:serializeObject({
				serialize = function(self, stream)
					stream:serializeBool({ value = w[1] == 1 })
					stream:serializeInt({ value = i32(w[2]) }, i32(w[3]), i32(w[4]))
					return stream:ok()
				end,
			})
		end
		if not ws:ok() then
			break
		end
	end
	ws:serializeEnd()
	ws:flush()
	local data = ws:data()
	if ws:ok() then
		return data, nil
	end
	return data, ws:error() .. " " .. lastop
end

local function readProgram(prog, data)
	local rs = S.ReadStream.new(data)
	local toks = {}
	for _, st in ipairs(prog) do
		local op = st.op
		local w = st.words
		local ok
		local tok
		if op == "b" then
			local h = { value = 0 }
			ok = rs:serializeBits(h, st.bits)
			tok = "d" .. tostring(h.value)
		elseif op == "b64" then
			local h = { value = 0i }
			ok = rs:serializeBits64(h, st.bits)
			tok = hex64(h.value)
		elseif op == "bl" then
			local h = { value = false }
			ok = rs:serializeBool(h)
			tok = h.value and "t" or "f"
		elseif op == "u8" then
			local h = { value = 0 }
			ok = rs:serializeUint8(h)
			tok = "d" .. tostring(h.value)
		elseif op == "u16" then
			local h = { value = 0 }
			ok = rs:serializeUint16(h)
			tok = "d" .. tostring(h.value)
		elseif op == "u32" then
			local h = { value = 0 }
			ok = rs:serializeUint32(h)
			tok = "d" .. tostring(h.value)
		elseif op == "u64" then
			local h = { value = 0i }
			ok = rs:serializeUint64(h)
			tok = hex64(h.value)
		elseif op == "i" then
			local h = { value = 0 }
			ok = rs:serializeInt(h, i32(w[2]), i32(w[3]))
			tok = "d" .. tostring(h.value)
		elseif op == "i64" then
			local h = { value = 0i }
			ok = rs:serializeInt64(h, bin64(w[3], w[4]), bin64(w[5], w[6]))
			tok = hex64(h.value)
		elseif op == "i128" then
			local h = { value = S.Int128.new(0i, 0i) }
			ok = rs:serializeInt128(h, n128({ w[5], w[6], w[7], w[8] }), n128({ w[9], w[10], w[11], w[12] }))
			tok = hex128(h.value)
		elseif op == "u128" then
			local h = { value = S.Int128.new(0i, 0i) }
			ok = rs:serializeUint128(h)
			tok = hex128(h.value)
		elseif op == "fx" then
			local h = { value = 0i }
			ok = rs:serializeFixed64(h, w[3], w[4], bin64(w[5], w[6]), bin64(w[7], w[8]))
			tok = hex64(h.value)
		elseif op == "f128" then
			local h = { value = S.Int128.new(0i, 0i) }
			ok = rs:serializeFixed128(h, w[5], w[6], bin64(w[7], w[8]), bin64(w[9], w[10]))
			tok = hex128(h.value)
		elseif op == "cf" then
			local h = { value = 0 }
			ok = rs:serializeCompressedFloat(h, FLT.f32frombits(w[2]), FLT.f32frombits(w[3]), FLT.f32frombits(w[4]))
			tok = "f" .. string.format("%08x", FLT.f32bits(h.value))
		elseif op == "ir" then
			local h = { value = 0 }
			ok = rs:serializeIntRelative(i32(w[1]), h)
			tok = "d" .. tostring(h.value)
		elseif op == "f" then
			local h = { value = 0 }
			ok = rs:serializeFloat(h)
			tok = "f" .. string.format("%08x", FLT.f32bits(h.value))
		elseif op == "d" then
			local h = { value = 0 }
			ok = rs:serializeDouble(h)
			local lo, hi = dblWords(h.value)
			tok = "D" .. tostring(lo) .. ":" .. tostring(hi)
		elseif op == "by" then
			local dst = buffer.create(#st.hex // 2)
			ok = rs:serializeBytes(dst)
			tok = "B" .. bufToHex(dst)
		elseif op == "s" then
			local h = { value = "" }
			ok = rs:serializeString(h, st.bufsize)
			tok = "S" .. strToHex(h.value)
		elseif op == "al" then
			ok = rs:serializeAlign()
			tok = "A"
		elseif op == "ob" then
			local bv = false
			local nv = 0
			ok = rs:serializeObject({
				serialize = function(self, stream)
					local bh = { value = false }
					stream:serializeBool(bh)
					bv = bh.value
					local nh = { value = 0 }
					stream:serializeInt(nh, i32(w[3]), i32(w[4]))
					nv = nh.value
					return stream:ok()
				end,
			})
			tok = "O" .. (bv and "t" or "f") .. ":" .. tostring(nv)
		end
		if not ok then
			toks[#toks + 1] = "E:" .. tostring(rs:error())
			return table.concat(toks, " ")
		end
		toks[#toks + 1] = tok
	end
	if rs:serializeEnd() then
		toks[#toks + 1] = "Z"
	else
		toks[#toks + 1] = "E:" .. tostring(rs:error())
	end
	return table.concat(toks, " ")
end

local input = require("./inputs")
local lines = {}
for ln in string.gmatch(input, "[^\n]+") do
	lines[#lines + 1] = ln
end

local i = 1
local n = #lines
local base = 1
while base <= n do
	if lines[base] == "P" then
		local progLines = {}
		local mutateTokens = nil
		local cur = base + 1
		while cur <= n and lines[cur] ~= "P" do
			if lines[cur] == "E" then
				cur = cur + 1
				break
			end
			if string.sub(lines[cur], 1, 2) == "M " then
				mutateTokens = {}
				for tok in string.gmatch(lines[cur], "%S+") do
					if tok ~= "M" then
						mutateTokens[#mutateTokens + 1] = tok
					end
				end
				cur = cur + 1
				break
			end
			progLines[#progLines + 1] = lines[cur]
			cur = cur + 1
		end
		local prog = parseProgram(progLines)
		local data, werr = writeProgram(prog)
		if werr ~= nil then
			print("WE " .. werr)
		else
			print("W " .. bufToHex(data))
		end
		print("R " .. readProgram(prog, data))
		if mutateTokens ~= nil then
			local mutated = applyMutation(data, mutateTokens)
			print("M " .. readProgram(prog, mutated))
		end
		base = cur
	else
		base = base + 1
	end
end
