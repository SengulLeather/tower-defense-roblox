--!strict
-- EnemyNet — compact binary encoding for the batch of enemy events the
-- server sends to clients once per simulation tick.
--
-- Why: the server simulates enemies as data (see PathMath) and clients
-- render them. Instead of replicating Parts, the server sends "keyframes":
--
--   distance(now) = d0 + speed * (now - t0)        -- computed on the client
--
-- A new keyframe is only needed when an enemy spawns or its speed changes
-- (slow, stun, haste, game-speed change), so traffic stays tiny even with
-- hundreds of enemies on screen.
--
-- Send the encoded buffer through a RELIABLE RemoteEvent (spawns/removes
-- must never be dropped), one FireAllClients per tick, never one call per
-- enemy. Use workspace:GetServerTimeNow() as `serverTime` on the server
-- and as `now` on the client — it is synchronised across machines.
--
-- Pure Luau (buffer library only), unit-testable under Lune.

export type Kind = "Spawn" | "Motion" | "Health" | "Remove"

export type Event = {
	kind: Kind,
	id: number, -- u32, unique per match
	defIndex: number?, -- Spawn: u16 index into your EnemyDefs array
	distance: number?, -- Spawn/Motion: d0, studs along the path at serverTime
	speed: number?, -- Spawn/Motion: studs per second (already multiplied by game speed)
	health01: number?, -- Spawn/Health: health fraction 0..1 (quantised to u16)
	reason: number?, -- Remove: one of EnemyNet.REMOVE_*
}

local EnemyNet = {}

EnemyNet.REMOVE_DIED = 0
EnemyNet.REMOVE_LEAKED = 1
EnemyNet.REMOVE_DESPAWNED = 2

-- Wire codes for each kind (u8).
local CODE_SPAWN, CODE_MOTION, CODE_HEALTH, CODE_REMOVE = 1, 2, 3, 4

local HEADER_SIZE = 10 -- f64 serverTime + u16 count
local SPAWN_SIZE = 17 -- u8 kind, u32 id, u16 def, f32 d0, f32 speed, u16 health
local MOTION_SIZE = 13 -- u8 kind, u32 id, f32 d0, f32 speed
local HEALTH_SIZE = 7 -- u8 kind, u32 id, u16 health
local REMOVE_SIZE = 6 -- u8 kind, u32 id, u8 reason
local MAX_EVENTS = 65535

local function sizeOf(kind: Kind): number
	if kind == "Spawn" then
		return SPAWN_SIZE
	elseif kind == "Motion" then
		return MOTION_SIZE
	elseif kind == "Health" then
		return HEALTH_SIZE
	end
	return REMOVE_SIZE
end

local function quantise01(value: number): number
	return math.round(math.clamp(value, 0, 1) * 65535)
end

local function required(value: number?, message: string): number
	if value == nil then
		error(message, 3)
	end
	return value
end

-- Bytes the encoded batch will take (useful for budgeting bandwidth).
function EnemyNet.size(events: { Event }): number
	local total = HEADER_SIZE
	for _, event in events do
		total += sizeOf(event.kind)
	end
	return total
end

function EnemyNet.encode(serverTime: number, events: { Event }): buffer
	assert(#events <= MAX_EVENTS, "EnemyNet.encode: too many events in one batch")
	local packet = buffer.create(EnemyNet.size(events))
	buffer.writef64(packet, 0, serverTime)
	buffer.writeu16(packet, 8, #events)
	local offset = HEADER_SIZE
	for _, event in events do
		local kind: Kind = event.kind
		local eventSize = sizeOf(kind)
		buffer.writeu32(packet, offset + 1, event.id)
		if kind == "Spawn" then
			buffer.writeu8(packet, offset, CODE_SPAWN)
			buffer.writeu16(packet, offset + 5, required(event.defIndex, "Spawn needs defIndex"))
			buffer.writef32(packet, offset + 7, required(event.distance, "Spawn needs distance"))
			buffer.writef32(packet, offset + 11, required(event.speed, "Spawn needs speed"))
			buffer.writeu16(packet, offset + 15, quantise01(event.health01 or 1))
		elseif kind == "Motion" then
			buffer.writeu8(packet, offset, CODE_MOTION)
			buffer.writef32(packet, offset + 5, required(event.distance, "Motion needs distance"))
			buffer.writef32(packet, offset + 9, required(event.speed, "Motion needs speed"))
		elseif kind == "Health" then
			buffer.writeu8(packet, offset, CODE_HEALTH)
			buffer.writeu16(
				packet,
				offset + 5,
				quantise01(required(event.health01, "Health needs health01"))
			)
		else
			buffer.writeu8(packet, offset, CODE_REMOVE)
			buffer.writeu8(packet, offset + 5, event.reason or EnemyNet.REMOVE_DIED)
		end
		offset += eventSize
	end
	return packet
end

-- Returns serverTime and the decoded events (in send order). Errors on a
-- malformed packet; wrap in pcall if the source is untrusted.
function EnemyNet.decode(packet: buffer): (number, { Event })
	local length = buffer.len(packet)
	assert(length >= HEADER_SIZE, "EnemyNet.decode: packet too short")
	local serverTime = buffer.readf64(packet, 0)
	local count = buffer.readu16(packet, 8)
	local events: { Event } = table.create(count)
	local offset = HEADER_SIZE
	for _ = 1, count do
		assert(offset + REMOVE_SIZE <= length, "EnemyNet.decode: truncated event")
		local code = buffer.readu8(packet, offset)
		local id = buffer.readu32(packet, offset + 1)
		local event: Event
		if code == CODE_SPAWN then
			assert(offset + SPAWN_SIZE <= length, "EnemyNet.decode: truncated event")
			event = {
				kind = "Spawn",
				id = id,
				defIndex = buffer.readu16(packet, offset + 5),
				distance = buffer.readf32(packet, offset + 7),
				speed = buffer.readf32(packet, offset + 11),
				health01 = buffer.readu16(packet, offset + 15) / 65535,
			}
		elseif code == CODE_MOTION then
			assert(offset + MOTION_SIZE <= length, "EnemyNet.decode: truncated event")
			event = {
				kind = "Motion",
				id = id,
				distance = buffer.readf32(packet, offset + 5),
				speed = buffer.readf32(packet, offset + 9),
			}
		elseif code == CODE_HEALTH then
			assert(offset + HEALTH_SIZE <= length, "EnemyNet.decode: truncated event")
			event =
				{ kind = "Health", id = id, health01 = buffer.readu16(packet, offset + 5) / 65535 }
		elseif code == CODE_REMOVE then
			event = { kind = "Remove", id = id, reason = buffer.readu8(packet, offset + 5) }
		else
			error("EnemyNet.decode: unknown event kind " .. code)
		end
		offset += sizeOf(event.kind)
		table.insert(events, event)
	end
	return serverTime, events
end

return EnemyNet
