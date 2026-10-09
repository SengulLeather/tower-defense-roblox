--!strict
-- Targeting — pick which enemy a tower shoots, plus splash and chain
-- helpers. Runs on the SERVER (the server decides every hit); clients only
-- draw the result.
--
-- Pure Luau (no Roblox services), so it is unit-testable under Lune.
-- Range checks are on the XZ plane: range circles are drawn flat on the
-- map, and a flying enemy should not escape range by being 10 studs up.

export type Mode = "First" | "Last" | "Strongest" | "Weakest" | "Closest"

export type Candidate = {
	id: number,
	position: Vector3,
	distance: number, -- studs travelled along the path; bigger = nearer the base
	health: number,
	flying: boolean?,
	hidden: boolean?, -- "stealth" enemies only detection towers can see
}

export type Query = {
	position: Vector3,
	range: number,
	mode: Mode,
	canHitFlying: boolean?,
	canSeeHidden: boolean?,
}

local Targeting = {}

local MODES: { Mode } = { "First", "Last", "Strongest", "Weakest", "Closest" }
Targeting.MODES = table.freeze(MODES)

local function flatDistanceSq(a: Vector3, b: Vector3): number
	local dx, dz = a.X - b.X, a.Z - b.Z
	return dx * dx + dz * dz
end

local function targetable(query: Query, candidate: Candidate): boolean
	if candidate.health <= 0 then
		return false
	end
	if candidate.flying and not query.canHitFlying then
		return false
	end
	if candidate.hidden and not query.canSeeHidden then
		return false
	end
	return true
end

-- Is `a` a better target than `b` for this mode? Ties fall back to "First"
-- (the enemy closest to the base), which is what players expect.
local function better(
	mode: Mode,
	a: Candidate,
	aDistSq: number,
	b: Candidate,
	bDistSq: number
): boolean
	if mode == "Last" then
		if a.distance ~= b.distance then
			return a.distance < b.distance
		end
	elseif mode == "Strongest" then
		if a.health ~= b.health then
			return a.health > b.health
		end
	elseif mode == "Weakest" then
		if a.health ~= b.health then
			return a.health < b.health
		end
	elseif mode == "Closest" then
		if aDistSq ~= bDistSq then
			return aDistSq < bDistSq
		end
	end
	return a.distance > b.distance
end

-- Best target in range for `query.mode`, or nil when nothing is in range.
function Targeting.pick(query: Query, candidates: { Candidate }): Candidate?
	local rangeSq = query.range * query.range
	local best: Candidate? = nil
	local bestDistSq = math.huge
	for _, candidate in candidates do
		if not targetable(query, candidate) then
			continue
		end
		local distSq = flatDistanceSq(candidate.position, query.position)
		if distSq > rangeSq then
			continue
		end
		if best == nil or better(query.mode, candidate, distSq, best, bestDistSq) then
			best = candidate
			bestDistSq = distSq
		end
	end
	return best
end

-- Every living candidate within `radius` of `center` (splash damage).
-- Pass `query` to apply the same flying/hidden rules as the shooting tower.
function Targeting.inRadius(
	center: Vector3,
	radius: number,
	candidates: { Candidate },
	query: Query?
): { Candidate }
	local radiusSq = radius * radius
	local hits = {}
	for _, candidate in candidates do
		if query then
			if not targetable(query, candidate) then
				continue
			end
		elseif candidate.health <= 0 then
			continue
		end
		if flatDistanceSq(candidate.position, center) <= radiusSq then
			table.insert(hits, candidate)
		end
	end
	return hits
end

-- Chain lightning: starting from `first`, repeatedly jump to the nearest
-- not-yet-hit candidate within `jumpRange`, up to `maxTargets` total hits.
function Targeting.chain(
	first: Candidate,
	candidates: { Candidate },
	maxTargets: number,
	jumpRange: number,
	query: Query?
): { Candidate }
	local hits = { first }
	local used = { [first.id] = true }
	local jumpSq = jumpRange * jumpRange
	local current = first
	while #hits < maxTargets do
		local nextTarget: Candidate? = nil
		local nextDistSq = math.huge
		for _, candidate in candidates do
			if used[candidate.id] or candidate.health <= 0 then
				continue
			end
			if query and not targetable(query, candidate) then
				continue
			end
			local distSq = flatDistanceSq(candidate.position, current.position)
			if distSq <= jumpSq and distSq < nextDistSq then
				nextTarget = candidate
				nextDistSq = distSq
			end
		end
		if nextTarget == nil then
			break
		end
		used[nextTarget.id] = true
		table.insert(hits, nextTarget)
		current = nextTarget
	end
	return hits
end

return Targeting
