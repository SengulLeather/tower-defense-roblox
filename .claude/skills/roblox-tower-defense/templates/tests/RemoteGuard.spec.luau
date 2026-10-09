--!strict
local T = require("./TestKit")
local RemoteGuard = T.load(T.TEMPLATES .. "/RemoteGuard.luau")

T.section("RemoteGuard")

T.test("isFiniteNumber rejects NaN, inf and non-numbers", function()
	T.truthy(RemoteGuard.isFiniteNumber(1.5))
	T.falsy(RemoteGuard.isFiniteNumber(0 / 0), "NaN")
	T.falsy(RemoteGuard.isFiniteNumber(math.huge), "inf")
	T.falsy(RemoteGuard.isFiniteNumber(-math.huge), "-inf")
	T.falsy(RemoteGuard.isFiniteNumber("1"), "numeric string")
	T.falsy(RemoteGuard.isFiniteNumber(nil), "nil")
end)

T.test("isNumberInRange and isInteger", function()
	T.truthy(RemoteGuard.isNumberInRange(5, 0, 10))
	T.falsy(RemoteGuard.isNumberInRange(11, 0, 10))
	T.falsy(RemoteGuard.isNumberInRange(0 / 0, 0, 10), "NaN slips past naive range checks")
	T.truthy(RemoteGuard.isInteger(3, 1, 5))
	T.falsy(RemoteGuard.isInteger(3.5, 1, 5))
end)

T.test("isString enforces length and optional UTF-8", function()
	T.truthy(RemoteGuard.isString("hello", 10))
	T.falsy(RemoteGuard.isString(string.rep("a", 11), 10))
	T.falsy(RemoteGuard.isString("\255\254", 10, true), "invalid UTF-8")
	T.falsy(RemoteGuard.isString(42, 10))
end)

T.test("isKeyOf only accepts string keys that exist", function()
	local defs = { archer = {}, cannon = {} }
	T.truthy(RemoteGuard.isKeyOf("archer", defs))
	T.falsy(RemoteGuard.isKeyOf("wizard", defs))
	T.falsy(RemoteGuard.isKeyOf(1, defs))
end)

T.test("isVector3 accepts finite Vector3s within range", function()
	T.truthy(RemoteGuard.isVector3(T.Vector3.new(1, 2, 3)))
	T.truthy(RemoteGuard.isVector3(T.Vector3.new(10, 0, 0), 50))
	T.falsy(RemoteGuard.isVector3(T.Vector3.new(100, 0, 0), 50), "too far from the origin")
	T.falsy(RemoteGuard.isVector3(T.Vector3.new(0 / 0, 0, 0)), "NaN component")
	T.falsy(RemoteGuard.isVector3(T.Vector3.new(math.huge, 0, 0)), "inf component")
end)

T.test("isVector3 rejects look-alikes", function()
	T.falsy(RemoteGuard.isVector3({ X = 1, Y = 2, Z = 3 }), "table pretending to be a Vector3")
	T.falsy(RemoteGuard.isVector3("1,2,3"))
end)

T.test("rate limiter allows a burst, then refills over time", function()
	local now = 0
	local limiter = RemoteGuard.newRateLimiter(3, 1, function()
		return now
	end)
	T.truthy(limiter:allow("p"))
	T.truthy(limiter:allow("p"))
	T.truthy(limiter:allow("p"))
	T.falsy(limiter:allow("p"), "burst exhausted")
	T.truthy(limiter:allow("other"), "keys are independent")
	now = 1
	T.truthy(limiter:allow("p"), "one token refilled")
	T.falsy(limiter:allow("p"))
	now = 100
	limiter:forget("p")
	T.truthy(limiter:allow("p"), "forgotten keys start full")
end)

return nil
