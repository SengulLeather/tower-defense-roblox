--!strict
local T = require("./TestKit")
local PathMath = T.load(T.TEMPLATES .. "/PathMath.luau")

local v = T.Vector3.new

T.section("PathMath")

-- L-shaped path: 10 studs along +X, then 10 studs along +Z.
local path = PathMath.new({ v(0, 0, 0), v(10, 0, 0), v(10, 0, 10) })

T.test("length is the sum of segment lengths", function()
	T.near(path.length, 20)
end)

T.test("sample on the first segment", function()
	local position, direction = PathMath.sample(path, 5)
	T.near(position.X, 5)
	T.near(position.Z, 0)
	T.near(direction.X, 1)
end)

T.test("sample on the second segment", function()
	local position, direction = PathMath.sample(path, 15)
	T.near(position.X, 10)
	T.near(position.Z, 5)
	T.near(direction.Z, 1)
end)

T.test("sample clamps outside [0, length]", function()
	local before = PathMath.sample(path, -3)
	local after = PathMath.sample(path, 99)
	T.near(before.X, 0)
	T.near(after.Z, 10)
end)

T.test("zero-length segments are skipped", function()
	local dup = PathMath.new({ v(0, 0, 0), v(10, 0, 0), v(10, 0, 0), v(10, 0, 10) })
	T.near(dup.length, 20)
	local position = PathMath.sample(dup, 12)
	T.near(position.X, 10)
	T.near(position.Z, 2)
end)

T.test("progress and reachedEnd", function()
	T.near(PathMath.progress(path, 5), 0.25)
	T.falsy(PathMath.reachedEnd(path, 19.9))
	T.truthy(PathMath.reachedEnd(path, 20))
end)

T.test("distanceToPath ignores height and reports along-distance", function()
	local dist, along = PathMath.distanceToPath(path, v(5, 0, 3))
	T.near(dist, 3)
	T.near(along, 5)
	local dist2, along2 = PathMath.distanceToPath(path, v(12, 50, 5))
	T.near(dist2, 2)
	T.near(along2, 15)
end)

T.test("rangeIntervals: chord on one segment", function()
	-- Tower on the first segment with range 2 covers x in [3, 7].
	local intervals = PathMath.rangeIntervals(path, v(5, 0, 0), 2)
	T.eq(#intervals, 1)
	T.near(intervals[1][1], 3)
	T.near(intervals[1][2], 7)
	T.truthy(PathMath.inIntervals(intervals, 4))
	T.falsy(PathMath.inIntervals(intervals, 8))
end)

T.test("rangeIntervals: merged across a corner", function()
	local intervals = PathMath.rangeIntervals(path, v(10, 0, 0), 3)
	T.eq(#intervals, 1)
	T.near(intervals[1][1], 7)
	T.near(intervals[1][2], 13)
end)

T.test("rangeIntervals: a U-bend gives two separate stretches", function()
	-- Out along x = 0..20 at z = 0, back along z = 10.
	local u = PathMath.new({ v(0, 0, 0), v(20, 0, 0), v(20, 0, 10), v(0, 0, 10) })
	local intervals = PathMath.rangeIntervals(u, v(5, 0, 5), 6)
	T.eq(#intervals, 2)
	T.truthy(intervals[1][2] < intervals[2][1], "sorted and disjoint")
end)

T.test("rangeIntervals: tower far away covers nothing", function()
	T.eq(#PathMath.rangeIntervals(path, v(100, 0, 100), 5), 0)
end)

T.test("timeInRange = covered length / speed", function()
	T.near(PathMath.timeInRange(path, v(5, 0, 0), 2, 2), 2)
end)

T.test("new() rejects a single waypoint", function()
	T.throws(function()
		PathMath.new({ v(0, 0, 0) })
	end)
end)

return nil
