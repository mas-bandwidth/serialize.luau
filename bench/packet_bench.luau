--!strict
-- packet_bench.luau: the smallest packet-wire read/write bench. A packet is a
-- mix of the fields a game packet carries (bool, small and wide bit groups,
-- ranged int, float, aligned bytes); it is written once, then read back N
-- times and written N times, timed apart with os.clock. A micro section times
-- BitReader.readBits alone at widths 1..32. The packet bytes are hashed and
-- printed so two builds can be proved to emit identical bytes.
--
-- usage: luau bench/packet_bench.luau [packets] [rounds]
-- Run it on a fleet bench, pinned to one core, runs interleaved between the
-- builds being compared (never the studio, never the host space).

local serialize = require("../src/serialize")

local N = 20000
local ROUNDS = 5
local args = { ... }
if args[1] ~= nil then N = tonumber(args[1]) or N end
if args[2] ~= nil then ROUNDS = tonumber(args[2]) or ROUNDS end

local BYTES = buffer.create(24)
for i = 0, 23 do
	buffer.writeu8(BYTES, i, (i * 37 + 11) % 256)
end

local function serializePacket(stream: any, seq: number, h: any, payload: buffer): boolean
	h.value = seq % 2 == 0 and 1 or 0
	if not stream:serializeBool(h) then return false end
	h.value = seq % 8
	if not stream:serializeBits(h, 3) then return false end
	h.value = (seq * 7) % 2048
	if not stream:serializeBits(h, 11) then return false end
	h.value = (seq * 2654435761) % 4294967296
	if not stream:serializeUint32(h) then return false end
	h.value = (seq * 13) % 1001
	if not stream:serializeInt(h, 0, 1000) then return false end
	h.value = (seq % 256) * 0.5
	if not stream:serializeFloat(h) then return false end
	h.value = seq % 65536
	if not stream:serializeUint16(h) then return false end
	h.value = seq % 32
	if not stream:serializeBits(h, 5) then return false end
	if not stream:serializeBytes(payload) then return false end
	h.value = (seq * 5) % 131072
	if not stream:serializeBits(h, 17) then return false end
	return true
end

local PACKET_BYTES = 128
local function fnv(buf: buffer, n: number): number
	local hash = 2166136261
	for i = 0, n - 1 do
		hash = bit32.bxor(hash, buffer.readu8(buf, i))
		hash = (hash * 16777619) % 4294967296
	end
	return hash
end

local function writePass(packets: number): (number, number)
	local buf = buffer.create(PACKET_BYTES)
	local h: any = { value = 0 }
	local payload = buffer.create(24)
	buffer.copy(payload, 0, BYTES, 0, 24)
	local stream = serialize.WriteStream.new(buf)
	local sum = 0
	local t0 = os.clock()
	for seq = 1, packets do
		stream:reset(buf)
		serializePacket(stream, seq, h, payload)
		stream:flush()
		if seq % 997 == 0 then
			sum = (sum + fnv(buf, 64)) % 4294967296
		end
	end
	return os.clock() - t0, sum
end

local function readPass(packets: number): (number, number)
	local buf = buffer.create(PACKET_BYTES)
	local h: any = { value = 0 }
	local payload = buffer.create(24)
	buffer.copy(payload, 0, BYTES, 0, 24)
	local w = serialize.WriteStream.new(buf)
	serializePacket(w, 12345, h, payload)
	w:flush()
	local used = math.floor((w:bitsProcessed() + 7) / 8)
	local wire = buffer.create(used)
	buffer.copy(wire, 0, buf, 0, used)
	local out = buffer.create(24)
	local stream = serialize.ReadStream.new(wire)
	local sum = 0
	local t0 = os.clock()
	for _ = 1, packets do
		stream:reset(wire)
		serializePacket(stream, 12345, h, out)
		sum = (sum + (h.value :: number)) % 4294967296
	end
	return os.clock() - t0, sum
end

local function microRead(iters: number): number
	local data = buffer.create(4096)
	for i = 0, 4095 do
		buffer.writeu8(data, i, (i * 131 + 7) % 256)
	end
	local reader = serialize.BitReader.new(data)
	local acc = 0
	local t0 = os.clock()
	for _ = 1, iters do
		reader:reset(data)
		for w = 1, 32 do
			-- 32 reads of widths 1..32: 528 bits, well inside the 32768
			acc = (acc + reader:readBits(w)) % 4294967296
		end
	end
	local dt = os.clock() - t0
	if acc < 0 then print(acc) end
	return dt
end

-- identity: the wire of one fixed packet, hashed
do
	local buf = buffer.create(PACKET_BYTES)
	local h: any = { value = 0 }
	local w = serialize.WriteStream.new(buf)
	serializePacket(w, 12345, h, BYTES)
	w:flush()
	print(string.format("wire-hash %d bits %d", fnv(buf, 64), w:bitsProcessed()))
	local _, checksum = readPass(1000)
	print(string.format("read-checksum %d", checksum))
end

writePass(2000)
readPass(2000)
microRead(200)
local bestW, bestR, bestM = math.huge, math.huge, math.huge
for r = 1, ROUNDS do
	local w = writePass(N)
	local rd = readPass(N)
	local m = microRead(N // 10)
	bestW = math.min(bestW, w)
	bestR = math.min(bestR, rd)
	bestM = math.min(bestM, m)
	print(string.format("round %d write %.1f ns/pkt read %.1f ns/pkt readBits-micro %.1f ns/read", r,
		w / N * 1e9, rd / N * 1e9, m / (N // 10 * 32) * 1e9))
end
print(string.format("BEST write %.1f ns/pkt read %.1f ns/pkt readBits-micro %.1f ns/read", bestW / N * 1e9,
	bestR / N * 1e9, bestM / (N // 10 * 32) * 1e9))
