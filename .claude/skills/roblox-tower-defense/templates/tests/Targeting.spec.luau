--!strict
local T = require("./TestKit")
local Targeting = T.load(T.TEMPLATES .. "/Targeting.luau")

local v = T.Vector3.new

T.section("Targeting")

local function candidates(): { any }
	return {
		{ id = 1, position = v(0, 0, 0), distance = 10, health = 50 },
		{ id = 2, position = v(3, 0, 0), distance = 20, health = 10 },
		{ id = 3, position = v(1, 0, 0), distance = 5, health = 100, flying = true },
		{ id = 4, position = v(2, 0, 0), distance = 30, health = 70, hidden = true },
		{ id = 5, position = v(50, 0, 0), distance = 40, health = 10 }, -- out of range
		{ id = 6, position = v(0, 0, 0), distance = 50, health = 0 }, -- dead
	}
end

local function pick(mode: string, flying: boolean?, hidden: boolean?): number?
	local target = Targeting.pick({
		position = v(0, 0, 0),
		range = 5,
		mode = mode,
		canHitFlying = flying,
		canSeeHidden = hidden,
	}, candidates())
	return target and target.id
end

T.test("First = furthest along the path (skips hidden, flying, dead, out of range)", function()
	T.eq(pick("First"), 2)
end)

T.test("hidden detection unlocks stealth enemies", function()
	T.eq(pick("First", false, true), 4)
end)

T.test("Last = least far along the path", function()
	T.eq(pick("Last"), 1)
	T.eq(pick("Last", true), 3)
end)

T.test("Strongest / Weakest by health", function()
	T.eq(pick("Strongest"), 1)
	T.eq(pick("Strongest", true), 3)
	T.eq(pick("Weakest"), 2)
end)

T.test("Closest by flat distance", function()
	T.eq(pick("Closest"), 1)
end)

T.test("ties break toward the enemy nearest the base", function()
	local target = Targeting.pick({ position = v(0, 0, 0), range = 10, mode = "Strongest" }, {
		{ id = 1, position = v(1, 0, 0), distance = 3, health = 10 },
		{ id = 2, position = v(2, 0, 0), distance = 9, health = 10 },
	})
	T.eq(target and target.id, 2)
end)

T.test("height does not affect range", function()
	local target = Targeting.pick(
		{ position = v(0, 0, 0), range = 5, mode = "First", canHitFlying = true },
		{ { id = 9, position = v(1, 80, 1), distance = 1, health = 5, flying = true } }
	)
	T.eq(target and target.id, 9)
end)

T.test("nothing in range returns nil", function()
	T.eq(Targeting.pick({ position = v(100, 0, 0), range = 5, mode = "First" }, candidates()), nil)
end)

T.test("inRadius returns living candidates in the splash radius", function()
	local hits = Targeting.inRadius(v(0, 0, 0), 2.5, candidates())
	local ids = {}
	for _, hit in hits do
		ids[hit.id] = true
	end
	T.truthy(ids[1] and ids[3] and ids[4], "1, 3 and 4 are inside 2.5 studs")
	T.falsy(ids[2] or ids[6], "2 is outside, 6 is dead")
end)

T.test("chain hops to the nearest unhit target within jump range", function()
	local list = candidates()
	local hits = Targeting.chain(list[1], list, 3, 2.5)
	T.eq(#hits, 3)
	T.eq(hits[1].id, 1)
	T.eq(hits[2].id, 3) -- 1 stud away
	T.eq(hits[3].id, 4) -- 1 stud from #3
end)

return nil
