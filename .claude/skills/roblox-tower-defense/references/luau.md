# Luau for Roblox

Luau is Roblox's Lua 5.1-derived language with gradual types, extra syntax,
and a fast VM. Sources: Creator Docs `luau/*`, `luau.org`, engine library
reference (October 2026), plus tool tests done while writing this skill.

## Contents
1. Type-check modes and the type solver
2. Syntax beyond Lua 5.1
3. Types cheat sheet
4. Tables, strings, buffers, math
5. Modules and class patterns
6. Errors and threads
7. Gotchas
8. Style conventions
9. Performance idioms

---

## 1. Type-check modes and the type solver

- First line of a file: `--!strict` (check everything, use this for new
  code), `--!nonstrict` (only annotated things), `--!nocheck`.
  `Workspace.LuauTypeCheckMode` sets the default for Studio.
- Roblox's **new type solver** is the default in 2026 (the legacy solver is
  being removed). It infers more precisely; occasionally it widens a local
  you later compare against string literals — annotate the local
  (`local kind: Kind = event.kind`) if you see "expected '"A" | "B"', got
  'string'".
- Run the checker outside Studio with **luau-lsp**:
  `luau-lsp analyze --platform=roblox --definitions=@roblox=globalTypes.d.luau
  --sourcemap=sourcemap.json src` (generate the sourcemap with
  `rojo sourcemap -o sourcemap.json`; the definitions file ships with
  luau-lsp releases / the VS Code extension).
- `--!native` (whole script) or `@native` (one function) compiles to
  machine code on the server. Use only on profiled hot code (math-heavy
  simulation loops); it costs compile time/memory. Type-annotate
  `Vector3` parameters in native code so the compiler specializes them.

## 2. Syntax beyond Lua 5.1

```lua
local x = 10
x += 5                      -- compound assignment: += -= *= /= //= %= ^= ..=
local half = 7 // 2         -- floor division → 3
local label = if x > 10 then "big" else "small"   -- if-expression
local msg = `Wave {wave} starts in {seconds}s`    -- string interpolation
for i, item in items do     -- generalized iteration (no pairs/ipairs needed)
	if not item.enabled then
		continue            -- continue keyword
	end
end
local function add(a: number, b: number): number -- annotations
	return a + b
end
local n = tonumber(text) :: number                -- type cast (assertion)
```

`const NAME = value` (non-reassignable binding) is the newest addition to
Luau and Roblox supports it, **but** StyLua 2.4, selene 0.30 and Lune 0.10
cannot parse it yet (verified). Don't use `const` unless the project's
toolchain has been upgraded and checked; use `local` + SCREAMING_CASE.

## 3. Types cheat sheet

```lua
type Point = { x: number, y: number }                 -- table type
export type TowerDef = {                               -- visible to requirers
	name: string,
	cost: number,
	splash: number?,                                   -- optional (number | nil)
	targets: { "Ground" | "Air" },                      -- array of singleton union
}
type Mode = "First" | "Last" | "Strongest"             -- singleton/literal union
type Callback = (player: Player, amount: number) -> boolean
type Map<K, V> = { [K]: V }                            -- generics
local function first<T>(list: { T }): T? return list[1] end

local value: unknown = getValue()                      -- must refine before use
if type(value) == "number" then ... end                -- refinement
if typeof(inst) == "Instance" and inst:IsA("BasePart") then ... end

local TowerDefs = require(script.Parent.TowerDefs)
type Def = TowerDefs.TowerDef                          -- use exported type
type Self = typeof(setmetatable({} :: Fields, Class))  -- class instance type
```

- `any` disables checking; `unknown` forces a check — prefer `unknown` for
  data coming from remotes or DataStores.
- `typeof(expr)` in a type position gives the type of a value.
- Roblox types: `Instance`, `Part`, `BasePart`, `Model`, `Player`,
  `Vector3`, `CFrame`, `RBXScriptConnection`, `RemoteEvent`, enums like
  `Enum.Material`. Note: in the type checker the Luau `vector` library type
  is distinct from `Vector3`; use Vector3 APIs (`.Magnitude`,
  `Vector3.zero`, `:Dot`, `:Cross`) in Roblox code.
- `table.freeze(t)` makes a table read-only (good for config tables).

## 4. Tables, strings, buffers, math

Tables:
- Arrays are 1-based; `#t` is only reliable without holes; never store
  `nil` in the middle of an array.
- `table.insert(t, v)`, `table.insert(t, i, v)`, `table.remove(t, i)`
  (shifts — O(n); for unordered removal swap with last and pop),
  `table.find(t, v)`, `table.clear(t)` (reuse allocations),
  `table.clone(t)` (shallow), `table.create(n, fill)`, `table.move`,
  `table.sort(t, cmp)`, `table.concat`, `table.freeze/isfrozen`.
- Sets: `{ [key] = true }`; counting a dictionary requires a loop.
- Iterating while assigning existing keys is fine; adding keys during
  iteration is not.

Strings: `string.format("%d/%d", a, b)`, `string.split(s, ",")`,
`string.sub`, `string.find(s, pattern, init, plain)`, `string.rep`,
`string.lower/upper`, `utf8.len`, `utf8.char`. Use interpolation for
messages.

`buffer`: fixed-size mutable bytes (`buffer.create(n)`,
`buffer.writeu8/u16/u32/i32/f32/f64`, `readXX`, `buffer.len`,
`buffer.copy`, `buffer.writestring/readstring`). Ideal for network packets
(`templates/EnemyNet.luau`) and compact save data.

Math: `math.clamp`, `math.round`, `math.floor/ceil`, `math.sign`,
`math.lerp(a, b, t)`, `math.map(x, inMin, inMax, outMin, outMax)`,
`math.isfinite/isnan/isinf`, `math.noise`, `math.huge`, `math.pi`.
Vector3/CFrame math as in `roblox-platform.md` §7.

## 5. Modules and class patterns

Module returning a table of functions (most code should look like this):

```lua
--!strict
local WaveRunner = {}

local queue: { SpawnEntry } = {}

function WaveRunner.start(waveNumber: number) ... end
function WaveRunner.step(dt: number) ... end

return WaveRunner
```

Class with typed instances (one common pattern):

```lua
--!strict
local Tower = {}
Tower.__index = Tower

type Fields = {
	id: number,
	kind: string,
	level: number,
	cooldown: number,
}
export type Tower = typeof(setmetatable({} :: Fields, Tower))

function Tower.new(id: number, kind: string): Tower
	local self = setmetatable({} :: Fields, Tower)
	self.id = id
	self.kind = kind
	self.level = 0
	self.cooldown = 0
	return self
end

function Tower.upgrade(self: Tower)
	self.level += 1
end

return Tower
```

- Prefer composition and plain data + functions over deep inheritance.
- Keep pure logic (math, rules, balance) in modules without Roblox
  services so it can be unit-tested with Lune.
- `require` takes an Instance path in Roblox
  (`require(ReplicatedStorage.Shared.PathMath)`); string requires
  (`require("./PathMath")`) work in Lune and for some Roblox-provided
  packages (`require("@rbx/...")`).
- Avoid circular requires; pass dependencies into `init()` instead.

## 6. Errors and threads

- `pcall(fn, ...)` → `ok, resultOrError`; `xpcall(fn, handler, ...)`;
  `error(msg, level)`; `assert(cond, msg)` (returns all its arguments —
  wrap in parentheses when passing to a function expecting one value).
- Wrap **every** yielding web call (DataStores, MarketplaceService,
  BadgeService, TeleportService, HttpService, TextService, GroupService)
  in `pcall`; they fail routinely.
- Errors inside `task.spawn`/event handlers don't propagate to the caller;
  they print to output and kill that thread only.
- Coroutines exist, but `task.*` + signals cover nearly every need.

## 7. Gotchas

- `NaN ~= NaN`; any comparison with NaN is false — validate numbers
  (`math.isfinite`) from clients and old saves.
- `0` and `""` are truthy; only `nil` and `false` are falsy.
- `#` on dictionaries is 0; on arrays with holes it's unreliable.
- Tables compare by reference; copy before mutating shared config.
- Global variables are a typo trap — `--!strict` + selene catch them.
- Integer vs float: all numbers are doubles; IDs above 2^53 lose
  precision (UserIds and asset IDs are fine).
- `string.format("%d", 3.7)` errors; round first.
- A yielding call between "check" and "spend" lets two requests pass the
  same check — keep check-and-mutate free of yields.
- Modifying an array while iterating it with `table.remove` skips items —
  iterate backwards or build a new array.
- Closures created in loops capture a fresh loop variable per iteration
  (safe), but upvalues captured from outside the loop are shared.

## 8. Style conventions

- `--!strict` first line; services at the top
  (`local Players = game:GetService("Players")`), then requires, then
  constants (`SCREAMING_SNAKE_CASE`), then types, then state, then
  functions, then `return`.
- `PascalCase` for modules, classes, services, types; `camelCase` for
  locals, functions, fields.
- Match the repo's StyLua config (this repo: tabs, 100 columns, double
  quotes, always call parentheses) and run `stylua` before committing.

## 9. Performance idioms

- Profile first (MicroProfiler, Script Profiler) — see `performance.md`.
- Reuse tables in per-frame code (`table.clear`), avoid creating closures
  per enemy per frame, prefer numeric `for` loops in hot paths.
- Compare squared distances instead of `.Magnitude` in range checks.
- `table.create(n)` pre-sizes arrays you'll fill.
- Cache Instance lookups (`FindFirstChild`) outside loops.
- Builtins like `math.*`, `vector`/Vector3 arithmetic and `buffer.*` are
  fast-called by the VM; local aliasing them is unnecessary.
