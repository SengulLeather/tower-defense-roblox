--!strict
-- RemoteGuard — argument validation and per-player rate limiting for
-- RemoteEvent / RemoteFunction handlers on the SERVER.
--
-- Exploiters can fire any remote, at any rate, with any arguments (wrong
-- types, NaN, ±inf, giant strings, tables pretending to be Instances).
-- Every OnServerEvent / OnServerInvoke handler should:
--   1. rate-limit the caller,
--   2. type- and range-check every argument (these helpers),
--   3. check permission/context against SERVER state (owns the tower?
--      enough cash? match still running?), then act.
--
-- The validators and the limiter are pure Luau (unit-testable under Lune);
-- only RemoteGuard.connect touches Roblox APIs.

local RemoteGuard = {}

-- A real, finite number (rejects NaN, inf, -inf and non-numbers).
-- NaN passes `typeof(x) == "number"` and fails every comparison, so a
-- naive `if x > balance then reject end` lets it straight through.
function RemoteGuard.isFiniteNumber(value: unknown): boolean
	return type(value) == "number" and value == value and value ~= math.huge and value ~= -math.huge
end

function RemoteGuard.isNumberInRange(value: unknown, min: number, max: number): boolean
	return RemoteGuard.isFiniteNumber(value)
		and (value :: number) >= min
		and (value :: number) <= max
end

function RemoteGuard.isInteger(value: unknown, min: number, max: number): boolean
	return RemoteGuard.isNumberInRange(value, min, max) and math.floor(value :: number) == value
end

-- A string no longer than maxLength bytes (and valid UTF-8 if requireUtf8).
function RemoteGuard.isString(value: unknown, maxLength: number, requireUtf8: boolean?): boolean
	if type(value) ~= "string" or #value > maxLength then
		return false
	end
	return not requireUtf8 or utf8.len(value) ~= nil
end

-- `value` is a string key present in `allowed` (e.g. a TowerDefs table).
-- Safer than `allowed[value]` alone, which also accepts any non-nil key type.
function RemoteGuard.isKeyOf(value: unknown, allowed: { [string]: any }): boolean
	return type(value) == "string" and allowed[value :: string] ~= nil
end

-- A Vector3 with finite components, optionally within maxMagnitude studs of
-- the origin. (Roblox-only: typeof() is "Vector3" for Vector3 values.)
function RemoteGuard.isVector3(value: unknown, maxMagnitude: number?): boolean
	if typeof(value) ~= "Vector3" then
		return false
	end
	local v = value :: Vector3
	if
		not (
			RemoteGuard.isFiniteNumber(v.X)
			and RemoteGuard.isFiniteNumber(v.Y)
			and RemoteGuard.isFiniteNumber(v.Z)
		)
	then
		return false
	end
	return maxMagnitude == nil or v.Magnitude <= maxMagnitude
end

-- An Instance of `className` that lives under `ancestor` (prevents clients
-- passing look-alike tables or instances from somewhere unexpected).
function RemoteGuard.isInstanceUnder(value: unknown, className: string, ancestor: Instance): boolean
	return typeof(value) == "Instance"
		and (value :: Instance):IsA(className)
		and (value :: Instance):IsDescendantOf(ancestor)
end

-- Token-bucket rate limiter. Each key (usually a Player) gets `capacity`
-- tokens that refill at `refillPerSecond`; every request spends one.
-- Allows short bursts (clicking fast) but caps the sustained rate.
export type RateLimiter = {
	allow: (self: RateLimiter, key: any) -> boolean,
	forget: (self: RateLimiter, key: any) -> (),
}

type Bucket = { tokens: number, updatedAt: number }

function RemoteGuard.newRateLimiter(
	capacity: number,
	refillPerSecond: number,
	clock: (() -> number)?
): RateLimiter
	local now = clock or os.clock
	local buckets: { [any]: Bucket } = {}
	local limiter = {}

	function limiter.allow(_self: RateLimiter, key: any): boolean
		local t = now()
		local bucket = buckets[key]
		if bucket == nil then
			bucket = { tokens = capacity, updatedAt = t }
			buckets[key] = bucket
		end
		bucket.tokens = math.min(capacity, bucket.tokens + (t - bucket.updatedAt) * refillPerSecond)
		bucket.updatedAt = t
		if bucket.tokens < 1 then
			return false
		end
		bucket.tokens -= 1
		return true
	end

	-- Call from Players.PlayerRemoving so the table doesn't grow forever.
	function limiter.forget(_self: RateLimiter, key: any)
		buckets[key] = nil
	end

	return limiter :: any
end

-- Connect a server handler that is only called when the caller is under
-- the rate limit AND `validate(...)` returns true for the raw arguments.
-- Rejected calls are dropped silently: never error back to an exploiter.
--
--   RemoteGuard.connect(Remotes.PlaceTower, placeLimiter, function(towerId, position)
--       return RemoteGuard.isKeyOf(towerId, TowerDefs) and RemoteGuard.isVector3(position, 2048)
--   end, function(player, towerId, position) ... end)
function RemoteGuard.connect(
	remote: RemoteEvent,
	limiter: RateLimiter,
	validate: (...unknown) -> boolean,
	handler: (Player, ...any) -> ()
): RBXScriptConnection
	return remote.OnServerEvent:Connect(function(player: Player, ...)
		if not limiter:allow(player) then
			return
		end
		if not validate(...) then
			return
		end
		handler(player, ...)
	end)
end

return RemoteGuard
