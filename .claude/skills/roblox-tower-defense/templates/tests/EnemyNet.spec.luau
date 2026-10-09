--!strict
local T = require("./TestKit")
local EnemyNet = T.load(T.TEMPLATES .. "/EnemyNet.luau")

T.section("EnemyNet")

local events: { any } = {
	{ kind = "Spawn", id = 70000, defIndex = 3, distance = 0, speed = 8.5, health01 = 1 },
	{ kind = "Motion", id = 12, distance = 41.25, speed = 3.4 },
	{ kind = "Health", id = 12, health01 = 0.5 },
	{ kind = "Remove", id = 9, reason = EnemyNet.REMOVE_LEAKED },
}

T.test("size adds header and per-event sizes", function()
	T.eq(EnemyNet.size(events), 10 + 17 + 13 + 7 + 6)
	T.eq(buffer.len(EnemyNet.encode(1, events)), EnemyNet.size(events))
end)

T.test("round trip preserves every field", function()
	local serverTime, decoded = EnemyNet.decode(EnemyNet.encode(123456.789, events))
	T.near(serverTime, 123456.789, 1e-9)
	T.eq(#decoded, 4)
	T.eq(decoded[1].kind, "Spawn")
	T.eq(decoded[1].id, 70000)
	T.eq(decoded[1].defIndex, 3)
	T.near(decoded[1].speed :: number, 8.5)
	T.near(decoded[1].health01 :: number, 1)
	T.eq(decoded[2].kind, "Motion")
	T.near(decoded[2].distance :: number, 41.25)
	T.near(decoded[2].speed :: number, 3.4, 1e-5)
	T.near(decoded[3].health01 :: number, 0.5, 1 / 65535)
	T.eq(decoded[4].kind, "Remove")
	T.eq(decoded[4].reason, EnemyNet.REMOVE_LEAKED)
end)

T.test("health is clamped to 0..1", function()
	local _, decoded =
		EnemyNet.decode(EnemyNet.encode(0, { { kind = "Health", id = 1, health01 = 7 } }))
	T.near(decoded[1].health01 :: number, 1)
end)

T.test("empty batch encodes to just the header", function()
	local serverTime, decoded = EnemyNet.decode(EnemyNet.encode(5, {}))
	T.eq(serverTime, 5)
	T.eq(#decoded, 0)
end)

T.test("truncated packets are rejected", function()
	local packet = EnemyNet.encode(1, events)
	local short = buffer.create(buffer.len(packet) - 3)
	buffer.copy(short, 0, packet, 0, buffer.len(short))
	T.throws(function()
		EnemyNet.decode(short)
	end)
end)

T.test("missing required fields fail loudly on encode", function()
	T.throws(function()
		EnemyNet.encode(0, { { kind = "Motion", id = 1 } })
	end)
end)

T.test("200 spawns fit comfortably in one reliable event", function()
	local many = {}
	for i = 1, 200 do
		table.insert(
			many,
			{ kind = "Spawn", id = i, defIndex = 1, distance = 0, speed = 6, health01 = 1 }
		)
	end
	T.eq(EnemyNet.size(many), 10 + 200 * 17)
end)

return nil
