--!strict
-- TestKit — a deliberately tiny test harness for running pure-logic Roblox
-- modules under Lune (https://lune-org.github.io/docs). No Studio needed.
--
-- TestKit.load(path) compiles a module with Roblox datatypes (Vector3,
-- CFrame, Color3, ...) from @lune/roblox injected as globals, so modules can
-- use idiomatic Roblox math while staying free of services/Instances.

local fs = require("@lune/fs")
local luau = require("@lune/luau")
local roblox = require("@lune/roblox") :: any

local TestKit = {}

-- Roblox datatypes exposed to loaded modules. Add more if a module needs them.
local ROBLOX_GLOBALS = {
	Vector3 = roblox.Vector3,
	Vector2 = roblox.Vector2,
	CFrame = roblox.CFrame,
	Color3 = roblox.Color3,
}

local cache: { [string]: any } = {}

-- Load a module file (path relative to the current working directory)
-- with Roblox datatypes available as globals. Results are cached.
function TestKit.load(path: string): any
	if cache[path] == nil then
		local source = fs.readFile(path)
		local environment = setmetatable(table.clone(ROBLOX_GLOBALS), { __index = getfenv(1) })
		local chunk = luau.load(source, { debugName = path, environment = environment })
		cache[path] = chunk()
	end
	return cache[path]
end

TestKit.Vector3 = roblox.Vector3

-- Directory holding the template modules, relative to the working directory.
-- run.luau overrides it from its first CLI argument.
TestKit.TEMPLATES = "templates"

local passed, failed = 0, 0

local function describe(value: any): string
	if type(value) == "string" then
		return string.format("%q", value)
	end
	return tostring(value)
end

function TestKit.test(name: string, fn: () -> ())
	local ok, err = pcall(fn)
	if ok then
		passed += 1
		print(`  ok   {name}`)
	else
		failed += 1
		print(`  FAIL {name}\n       {err}`)
	end
end

function TestKit.eq(actual: any, expected: any, label: string?)
	if actual ~= expected then
		error(
			`{label or "values differ"}: expected {describe(expected)}, got {describe(actual)}`,
			2
		)
	end
end

function TestKit.near(actual: number, expected: number, epsilon: number?, label: string?)
	local eps = epsilon or 1e-6
	if math.abs(actual - expected) > eps then
		error(`{label or "numbers differ"}: expected {expected} ± {eps}, got {actual}`, 2)
	end
end

function TestKit.truthy(value: any, label: string?)
	if not value then
		error(`{label or "expected a truthy value"}: got {describe(value)}`, 2)
	end
end

function TestKit.falsy(value: any, label: string?)
	if value then
		error(`{label or "expected a falsy value"}: got {describe(value)}`, 2)
	end
end

function TestKit.throws(fn: () -> (), label: string?)
	if pcall(fn) then
		error(`{label or "expected an error"}: call succeeded`, 2)
	end
end

function TestKit.section(name: string)
	print(`\n{name}`)
end

-- Returns the number of failed tests.
function TestKit.summary(): number
	print(`\n{passed} passed, {failed} failed`)
	return failed
end

return TestKit
