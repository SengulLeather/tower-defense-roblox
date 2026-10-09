--!strict
-- PathMath — distance-along-path math for tower defense enemies.
--
-- An enemy is simulated as ONE number: how many studs it has travelled
-- along the path. World position, facing, "first/last" targeting order and
-- leak detection are all derived from that number with these helpers — on
-- the server and on every client — so nobody has to replicate enemy Parts
-- every frame.
--
-- Pure logic: only Vector3 math and no Roblox services, so it runs under
-- Lune unit tests (the test kit injects Lune's Vector3 implementation).
-- Drop it in ReplicatedStorage (e.g. src/shared/PathMath.luau).

export type Path = {
	points: { Vector3 },
	-- cumulative[i] = studs from points[1] to points[i] (cumulative[1] == 0)
	cumulative: { number },
	length: number,
}

local PathMath = {}

-- Build a path from an ordered list of waypoints (spawn -> base).
-- Duplicate consecutive waypoints are allowed; they become zero-length
-- segments and are skipped when sampling.
function PathMath.new(points: { Vector3 }): Path
	assert(#points >= 2, "PathMath.new: a path needs at least two waypoints")
	local cumulative = table.create(#points, 0)
	local total = 0
	for i = 2, #points do
		total += (points[i] - points[i - 1]).Magnitude
		cumulative[i] = total
	end
	return {
		points = table.freeze(table.clone(points)),
		cumulative = table.freeze(cumulative),
		length = total,
	}
end

-- Index i of the segment points[i] -> points[i + 1] that contains
-- `distance` (binary search; distance must already be clamped).
local function segmentIndex(path: Path, distance: number): number
	local cumulative = path.cumulative
	local lo, hi = 1, #cumulative - 1
	while lo < hi do
		local mid = (lo + hi + 1) // 2
		if cumulative[mid] <= distance then
			lo = mid
		else
			hi = mid - 1
		end
	end
	return lo
end

-- World position and unit travel direction `distance` studs along the path.
-- Out-of-range distances clamp to the endpoints. Use the direction for
-- facing: CFrame.lookAt(position, position + direction).
function PathMath.sample(path: Path, distance: number): (Vector3, Vector3)
	local d = math.clamp(distance, 0, path.length)
	local i = segmentIndex(path, d)
	local a, b = path.points[i], path.points[i + 1]
	local segmentLength = path.cumulative[i + 1] - path.cumulative[i]
	if segmentLength <= 0 then
		return a, Vector3.zero
	end
	local t = (d - path.cumulative[i]) / segmentLength
	return a + (b - a) * t, (b - a) / segmentLength
end

-- 0..1 progress along the path (handy for UI progress bars).
function PathMath.progress(path: Path, distance: number): number
	if path.length <= 0 then
		return 1
	end
	return math.clamp(distance / path.length, 0, 1)
end

-- True once an enemy has walked the whole path (it leaked into the base).
function PathMath.reachedEnd(path: Path, distance: number): boolean
	return distance >= path.length
end

-- Shortest distance from `point` to the path on the XZ plane (height is
-- ignored), plus how far along the path that closest point is. Use it on
-- the server to reject tower placements on/too close to the path:
--   if PathMath.distanceToPath(path, pos) < PATH_HALF_WIDTH + footprint then reject end
-- On sloped paths the along-distance is an approximation (XZ projection).
function PathMath.distanceToPath(path: Path, point: Vector3): (number, number)
	local best, bestAlong = math.huge, 0
	local px, pz = point.X, point.Z
	local points, cumulative = path.points, path.cumulative
	for i = 1, #points - 1 do
		local a, b = points[i], points[i + 1]
		local abx, abz = b.X - a.X, b.Z - a.Z
		local lengthSq = abx * abx + abz * abz
		local t = 0
		if lengthSq > 0 then
			t = math.clamp(((px - a.X) * abx + (pz - a.Z) * abz) / lengthSq, 0, 1)
		end
		local dx, dz = px - (a.X + abx * t), pz - (a.Z + abz * t)
		local dist = math.sqrt(dx * dx + dz * dz)
		if dist < best then
			best = dist
			bestAlong = cumulative[i] + (cumulative[i + 1] - cumulative[i]) * t
		end
	end
	return best, bestAlong
end

-- The stretches of the path (as along-distance intervals { from, to })
-- that lie within `range` of `center` on the XZ plane. Exact (circle vs
-- segment intersection), sorted, and merged across corners.
--
-- Towers and the path don't move, so compute this ONCE when a tower is
-- placed (or its range changes). Then "is this ground enemy in range?"
-- becomes a cheap 1-D test on its path distance (PathMath.inIntervals)
-- instead of a 3-D distance check, and with enemies sorted by distance the
-- "First" target is the furthest enemy inside the last interval.
function PathMath.rangeIntervals(path: Path, center: Vector3, range: number): { { number } }
	local intervals: { { number } } = {}
	local cx, cz = center.X, center.Z
	local rangeSq = range * range
	local points, cumulative = path.points, path.cumulative
	for i = 1, #points - 1 do
		local segmentLength = cumulative[i + 1] - cumulative[i]
		if segmentLength <= 0 then
			continue
		end
		local a, b = points[i], points[i + 1]
		local dx, dz = b.X - a.X, b.Z - a.Z
		local fx, fz = a.X - cx, a.Z - cz
		local qa = dx * dx + dz * dz
		local qc = fx * fx + fz * fz - rangeSq
		local t0, t1
		if qa <= 0 then
			-- Purely vertical segment: inside iff its XZ point is inside.
			if qc > 0 then
				continue
			end
			t0, t1 = 0, 1
		else
			local qb = 2 * (fx * dx + fz * dz)
			local discriminant = qb * qb - 4 * qa * qc
			if discriminant < 0 then
				continue
			end
			local root = math.sqrt(discriminant)
			t0 = math.max((-qb - root) / (2 * qa), 0)
			t1 = math.min((-qb + root) / (2 * qa), 1)
			if t0 > t1 then
				continue
			end
		end
		local from = cumulative[i] + segmentLength * t0
		local to = cumulative[i] + segmentLength * t1
		local last = intervals[#intervals]
		if last and from - last[2] <= 1e-6 then
			last[2] = math.max(last[2], to)
		else
			table.insert(intervals, { from, to })
		end
	end
	return intervals
end

-- Is `distance` inside any of the intervals from PathMath.rangeIntervals?
function PathMath.inIntervals(intervals: { { number } }, distance: number): boolean
	for _, interval in intervals do
		if distance >= interval[1] and distance <= interval[2] then
			return true
		end
	end
	return false
end

-- How long (seconds) an enemy moving at `speed` along the path stays within
-- `range` of `towerPosition`. Balancing helper:
--   damage one tower can deal to one enemy ~= dps * timeInRange(...)
function PathMath.timeInRange(
	path: Path,
	towerPosition: Vector3,
	range: number,
	speed: number
): number
	if speed <= 0 then
		return math.huge
	end
	local inside = 0
	for _, interval in PathMath.rangeIntervals(path, towerPosition, range) do
		inside += interval[2] - interval[1]
	end
	return inside / speed
end

return PathMath
