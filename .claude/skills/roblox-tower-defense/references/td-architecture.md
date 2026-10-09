# Tower Defense Architecture (Roblox)

How to build a TD game that is cheat-resistant, smooth on phones, and
handles hundreds of enemies. Templates referenced here live in
`../templates/` and are unit-tested under Lune.

## Contents
1. Authority split
2. Project layout
3. The simulation loop (server)
4. Enemies as data + keyframe replication
5. Towers: targeting, firing, projectiles, effects
6. Waves and match state machine
7. Placement, upgrade, sell — validation
8. Client: rendering enemies, placement preview, UI
9. Lobby ↔ match (multi-place) vs single place
10. Player data schema for TD
11. Performance budget and scaling
12. Testing the game

---

## 1. Authority split

| Server owns (authoritative) | Client owns (presentation) |
|---|---|
| Match state, wave number, timers, votes | Rendering enemies, projectiles, VFX, sounds |
| Cash, base HP, rewards, XP | Placement ghost, range circles, grid highlight |
| Enemy HP, path distance, speed, effects | Interpolating enemy positions from keyframes |
| Tower placement, upgrades, targeting, damage | Tower aim/turn animations, muzzle flashes |
| Persistent data, purchases | UI, camera, input, settings |

The client **requests** ("place archer at X", "upgrade tower 12", "vote
skip"); the server **validates and decides**. A client never reports
"I killed enemy 5" or "I have 900 cash".

## 2. Project layout

Rojo layout (matches the existing repo convention `src/shared|server|client`):

```
src/
  shared/                      -> ReplicatedStorage.Shared
    init.luau                  (aggregator, optional)
    Config.luau                (tunables; no secrets)
    TowerDefs.luau             (stats, costs, upgrade tables)
    EnemyDefs.luau             (array; index is the wire id for EnemyNet)
    WaveDefs.luau              (hand-authored waves + budget generator)
    MapDefs.luau               (waypoints, placement rules per map)
    PathMath.luau              (template)
    Targeting.luau             (template; server uses it, client may preview)
    EnemyNet.luau              (template; wire format)
    Remotes.luau               (creates/fetches RemoteEvents by name)
  server/                      -> ServerScriptService.Server
    init.server.luau           (bootstrap: requires services in order)
    PlayerData.luau            (ProfileStore wrapper, session locked)
    Purchases.luau             (ReceiptHandler + game passes)
    RemoteGuard.luau           (template)
    Match/
      Match.luau               (state machine, owns everything below)
      EnemySim.luau            (enemy data, movement, effects, keyframes)
      TowerSim.luau            (placement, targeting, firing, upgrades)
      WaveRunner.luau          (spawn queues, wave clear, rewards)
  client/                      -> StarterPlayerScripts.Client
    init.client.luau           (bootstrap)
    EnemyRenderer.luau         (decode EnemyNet, pool models, BulkMoveTo)
    TowerFx.luau               (shots, impacts, turret aim)
    Placement.luau             (ghost, raycast, grid snap, confirm on touch)
    Hud.luau / Ui/             (cash, wave, base HP, tower panel, shop)
assets/ or Studio-only:        Maps and models live in the place file
                               (ServerStorage/ReplicatedStorage), not in code
```

Models (enemy rigs, tower models, maps) are easier to author in Studio and
keep in the place file. With Rojo, either keep them in the `.rbxl` that you
`rojo serve` into, or export to `.rbxm` files referenced from
`default.project.json`.

## 3. The simulation loop (server)

Use one fixed-step loop per match. A fixed step keeps damage, cooldowns and
spawns identical at any frame rate and makes 2x speed trivial.

```lua
--!strict
local RunService = game:GetService("RunService")

local SIM_DT = 1 / 20 -- 20 Hz is plenty for TD; 30 Hz for very fast enemies
local MAX_STEPS_PER_FRAME = 4 -- never spiral if the server hitches

local accumulator = 0
RunService.Heartbeat:Connect(function(frameDt)
	accumulator += frameDt * match.gameSpeed -- 1, 2 or 3
	local steps = 0
	while accumulator >= SIM_DT and steps < MAX_STEPS_PER_FRAME do
		accumulator -= SIM_DT
		steps += 1
		match:step(SIM_DT) -- spawn → move → effects → towers → hits → deaths/leaks
	end
	if steps == MAX_STEPS_PER_FRAME then
		accumulator = 0 -- drop the backlog rather than fast-forwarding
	end
	match:flushNetwork() -- one EnemyNet batch + one cosmetic batch per frame
end)
```

Inside `step`, keep a deterministic order: spawn queue → move enemies →
tick status effects (DoT, slow expiry) → towers acquire/fire → resolve
scheduled hits → remove dead/leaked enemies → wave-clear check.

## 4. Enemies as data + keyframe replication

### Server representation
No Parts on the server. Each enemy is a table:

```lua
type Enemy = {
	id: number,          -- increasing integer per match (u32 on the wire)
	defIndex: number,    -- index into EnemyDefs
	hp: number, maxHp: number,
	distance: number,    -- studs along the path (PathMath)
	baseSpeed: number,   -- studs/s at 1x
	speedMultiplier: number, -- 1, or slow factor, or 0 when stunned
	effects: { [string]: { until: number, value: number } },
	flying: boolean, hidden: boolean,
}
```

Position, when needed (splash, range checks for flying enemies), is
`PathMath.sample(path, enemy.distance)`.

### Replication: keyframes, not Parts
Moving hundreds of server-side Models every Heartbeat (PivotTo/CFrame
writes) replicates every change to every client — this is the #1 reason TD
games lag. Instead, clients compute positions themselves:

```
distance(now) = d0 + speed * (now - t0)     -- now = workspace:GetServerTimeNow()
```

The server sends a keyframe (`templates/EnemyNet.luau` event) only when it
changes:
- **Spawn**: id, defIndex, d0, speed (already × gameSpeed), health.
- **Motion**: id, d0, speed — whenever the effective speed changes (slow
  applied/expired, stun, haste, game speed changed → re-keyframe all).
- **Health**: id, health fraction — batched, only enemies damaged this tick.
- **Remove**: id, reason (died, leaked, despawned).

Collect events during the frame, then send **one** buffer per frame with a
reliable `RemoteEvent:FireAllClients(EnemyNet.encode(workspace:GetServerTimeNow(), events))`.
Because both sides integrate the same constant speed between keyframes,
drift is negligible; a full re-sync is only needed for late joiners: on
join, send Spawn events for every living enemy with its *current* distance.

When the server moves an enemy it should advance `distance += baseSpeed *
speedMultiplier * dt` and, whenever `speedMultiplier` changes, push a Motion
keyframe with the current distance. Keep the multiplier rules simple (e.g.,
strongest slow wins, stuns set 0) so keyframes are rare.

For enemies that leave the path (knockback, flying free-roam), send their
position in the keyframe or use periodic snapshots over an
`UnreliableRemoteEvent` (payload ≤ 1000 bytes; chunk; include a sequence
number and drop stale packets).

### Range checks via path intervals
Towers and the path never move, so when a tower is placed compute
`tower.intervals = PathMath.rangeIntervals(path, tower.position, tower.range)`.
A ground enemy is in range iff `PathMath.inIntervals(tower.intervals,
enemy.distance)` — no vector math. If you keep enemies sorted by distance
(the order barely changes between ticks, so an insertion sort each tick is
cheap even though fast enemies overtake slow ones), "First" is the
furthest enemy inside the last interval. Use real positions
(`Targeting.pick`) for flying/off-path enemies.

## 5. Towers: targeting, firing, projectiles, effects

```lua
-- per tower, per sim step
tower.cooldown -= dt
if tower.cooldown <= 0 then
	local target = acquireTarget(tower) -- Targeting.pick or interval scan
	if target then
		tower.cooldown += 1 / tower.stats.fireRate -- += keeps cadence exact
		fire(tower, target)
	else
		tower.cooldown = 0 -- ready to fire the moment something enters range
	end
end
```

- **Hitscan** (instant) for bullets/lasers: apply damage immediately.
- **Travel-time projectiles**: schedule `{ hitAt = simTime + travelTime,
  targetId, damage, splash }` in a list; resolve when `simTime >= hitAt`
  (if the target died, either fizzle or hit its last position for splash).
  The client draws the projectile from the cosmetic event; the server never
  creates projectile Parts.
- **Splash**: `Targeting.inRadius(targetPosition, radius, candidates, query)`.
- **Chain**: `Targeting.chain(first, candidates, maxTargets, jumpRange, query)`.
- **Damage pipeline**: `final = max(1, raw * (1 - resist) - armor)`;
  apply multipliers from buffs; credit the owner for cash-per-damage.
- **Status effects**: store `until` in sim time. Slows: strongest wins (no
  multiplicative stacking unless designed). DoT: tick on a fixed cadence
  (e.g., every 0.5 s), not every step. Stun: speedMultiplier = 0.
- **Support towers**: recompute buffed stats when a buff tower is placed,
  upgraded or sold — not every tick.
- **Cosmetic fire events**: batch `{towerId, targetEnemyId, kind}` per frame
  and send with an `UnreliableRemoteEvent` (losing a muzzle flash is fine;
  keep each payload under 1000 bytes — use a buffer: u16 tower, u32 enemy).

## 6. Waves and match state machine

```
Lobby/Voting → Intermission(t) → WaveActive → WaveCleared → Intermission …
                     ↑ skip vote                     ↓ final wave
                                           Victory / Defeat → Results → Teleport/Return
```

- Wave definitions are data: `{ groups = { { enemy = "Runner", count = 12,
  interval = 0.6, delay = 0 }, ... }, bonus = 150 }`. The WaveRunner turns
  groups into a time-ordered spawn queue.
- A wave is cleared when its queue is empty **and** no enemies from it are
  alive. Pay the clear bonus once.
- Defeat when base HP ≤ 0 (process leaks in the same step as damage so a
  last-second kill counts).
- On Victory/Defeat: freeze the sim, compute rewards on the server, save
  them through the player-data layer (they're persistent), then show results.
- Keep the state on the server and replicate a compact summary (state,
  wave, timer end time as server time, base HP, each player's cash) with a
  reliable remote only when it changes, or via attributes on a match
  Folder (fine for low-frequency values).

## 7. Placement, upgrade, sell — validation

Client sends intent only: `PlaceTower(towerId: string, position: Vector3,
rotation: number?)`. Server:

```lua
local function tryPlace(player: Player, towerId: unknown, position: unknown)
	if not placeLimiter:allow(player) then return end
	if not RemoteGuard.isKeyOf(towerId, TowerDefs) then return end
	if not RemoteGuard.isVector3(position, MAP_RADIUS) then return end
	local def = TowerDefs[towerId :: string]
	local pos = position :: Vector3
	local state = match:getPlayerState(player)
	if not state or match.phase == "Ended" then return end
	if not PlayerData.ownsTower(player, towerId) then return end   -- loadout/meta check
	if state.cash < def.cost then return end
	if match:countTowers(player, towerId) >= def.placementLimit then return end
	-- must stand on a Placeable surface near the claimed height
	local hit = workspace:Raycast(pos + Vector3.new(0, 20, 0), Vector3.new(0, -40, 0), placementParams)
	if not hit or not hit.Instance:HasTag("Placeable") or math.abs(hit.Position.Y - pos.Y) > 1 then return end
	-- not on the path, not overlapping other towers
	if PathMath.distanceToPath(match.path, pos) < PATH_HALF_WIDTH + def.footprint then return end
	if match:overlapsTower(pos, def.footprint) then return end
	state.cash -= def.cost
	match:placeTower(player, towerId, hit.Position)
end
```

With a grid, validate integer cell coordinates instead
(`RemoteGuard.isInteger(gx, 0, GRID_SIZE - 1)`) and check an occupancy
table and a path-cell set.

Upgrade/sell/retarget: check the tower id exists in this match, belongs to
the player, the next level exists, cash suffices, the mode is one of
`Targeting.MODES`. Sell refunds a fraction of `tower.totalSpent`.

## 8. Client: rendering enemies, placement preview, UI

### EnemyRenderer
```lua
--!strict
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

type View = { root: BasePart, model: Model, t0: number, d0: number, speed: number, yOffset: number }
local views: { [number]: View } = {}

Remotes.EnemyEvents.OnClientEvent:Connect(function(packet: buffer)
	local serverTime, events = EnemyNet.decode(packet)
	for _, event in events do
		if event.kind == "Spawn" then
			local model = Pool.acquire(event.defIndex :: number) -- cloned once, reused
			views[event.id] = {
				model = model, root = model.PrimaryPart :: BasePart,
				t0 = serverTime, d0 = event.distance :: number, speed = event.speed :: number,
				yOffset = EnemyDefs[event.defIndex :: number].yOffset,
			}
		elseif event.kind == "Motion" then
			local view = views[event.id]
			if view then
				view.t0, view.d0, view.speed = serverTime, event.distance :: number, event.speed :: number
			end
		elseif event.kind == "Health" then
			-- update the health bar fill for views[event.id]
		elseif event.kind == "Remove" then
			local view = views[event.id]
			views[event.id] = nil
			if view then
				DeathFx.play(view, event.reason) -- then Pool.release(view.model)
			end
		end
	end
end)

local parts: { BasePart } = {}
local cframes: { CFrame } = {}
RunService.PreRender:Connect(function()
	local now = Workspace:GetServerTimeNow()
	table.clear(parts)
	table.clear(cframes)
	for _, view in views do
		local position, direction = PathMath.sample(path, view.d0 + view.speed * (now - view.t0))
		position += Vector3.new(0, view.yOffset, 0)
		local facing = if direction.Magnitude > 0 then direction else Vector3.zAxis
		table.insert(parts, view.root)
		table.insert(cframes, CFrame.lookAt(position, position + facing))
	end
	Workspace:BulkMoveTo(parts, cframes, Enum.BulkMoveMode.FireCFrameChanged)
end)
```

Model setup for pooled enemies: `PrimaryPart` anchored, every other part
welded to it (WeldConstraint), `Anchored = false`, `Massless = true`,
`CanCollide/CanQuery/CanTouch = false`, `CastShadow = false` on small parts.
Parent pooled models to a client-only folder in Workspace. Animate with an
`AnimationController` + `Animator` (client-side animations are fine for
client-only models); skip animations for far/off-screen enemies when counts
are high. Health bars: one pooled `BillboardGui` per enemy with
`MaxDistance`, update only on Health events; hide at full HP.

### Placement preview
- Raycast from the camera through the pointer/touch position
  (`camera:ViewportPointToRay`, `workspace:Raycast` with a whitelist of
  placeable surfaces), snap to grid, tint the ghost green/red using the same
  rules the server uses (share them in a module), draw a range circle.
- On touch devices: tap to position, then a **Confirm/Cancel** button —
  there is no hover on phones.
- Rotate with R/gamepad button via the Input Action System (see
  `ui-and-input.md`).

### UI
Cash, base HP, wave counter + next-wave timer, skip button, speed toggle,
tower hotbar (loadout) with costs and placement limits, tower panel
(upgrade with stat deltas, sell value, targeting mode, owner). Large touch
targets; test on phone, tablet, console in the Device Emulator.

## 9. Lobby ↔ match (multi-place) vs single place

**Multi-place universe** (TDS style; best for co-op and scale):
- Places: `Lobby` (start place) and `Match` (one place, maps loaded by
  name) in the same experience.
- Lobby: elevators/queues form a party (ProximityPrompt or zone), players
  vote map/difficulty, then the lobby server teleports them:

```lua
local TeleportService = game:GetService("TeleportService")

local function sendToMatch(players: { Player }, mapName: string, difficulty: string)
	local options = Instance.new("TeleportOptions")
	options.ShouldReserveServer = true -- fresh private server for this party
	options:SetTeleportData({ map = mapName, difficulty = difficulty })
	local ok, result = pcall(function()
		return TeleportService:TeleportAsync(MATCH_PLACE_ID, players, options)
	end)
	if not ok then
		warn("Teleport failed:", result) -- retry with backoff; tell the players
	end
end
TeleportService.TeleportInitFailed:Connect(function(player, result, message)
	-- retry or return the player to the queue
end)
```

- Match server: read `player:GetJoinData().TeleportData` for map and
  difficulty, **validate** against `MapDefs`/unlocks (teleport data passes
  through the client and is not secure); load player data from the
  DataStore (session-locked) — never trust loadouts from teleport data.
  For a stronger guarantee, reserve with `ReserveServerAsync` (returns
  access code + PrivateServerId) and store match settings in a
  MemoryStore hash keyed by that PrivateServerId.
- When the match ends, teleport everyone back with
  `TeleportAsync(LOBBY_PLACE_ID, players)`.
- **TeleportService does not work in Studio.** Make the match place
  runnable standalone: if `RunService:IsStudio()` (or no teleport data),
  start a default match (first map, Normal) so you can playtest it.
- Use `Workspace.StreamingEnabled = false` or set the map Model's
  `ModelStreamingMode = Persistent` on match servers: TD maps are small and
  the client needs the whole path loaded.

**Single place** (this repo's current approach): each player gets a
private arena at an offset, or the server runs one shared match. Simpler
and fully testable in Studio; set a low `Players.MaxPlayers` (e.g., 4–6)
because all arenas share one server. Move to multi-place when you need
co-op matchmaking or more concurrent enemies per player.

## 10. Player data schema for TD

```lua
local TEMPLATE = {
	schemaVersion = 1,
	coins = 0, gems = 0, xp = 0, level = 1,
	ownedTowers = { Archer = true },            -- set-like
	loadout = { "Archer", "", "", "", "" },     -- fixed slots
	skins = {}, equippedSkins = {},              -- towerId -> skinId
	stats = { wins = 0, matches = 0, bestEndlessWave = 0, enemiesKilled = 0 },
	clears = {},                                 -- ["Map:Difficulty"] = true
	quests = { day = 0, progress = {} },
	codesRedeemed = {},                          -- code -> true
	processedPurchaseIds = {},                   -- ReceiptHandler history
	settings = { music = 0.5, sfx = 0.8, showDamageNumbers = true },
	tutorialDone = false,
}
```

Use a session-locked store (ProfileStore) with `Reconcile` for new fields
and a `schemaVersion` migration step for renamed/removed fields. Save
match rewards at match end (and periodically), not per kill. See
`data-persistence.md`.

## 11. Performance budget and scaling

- Server: target < 4–6 ms of script time per Heartbeat with max enemies;
  measure with the MicroProfiler (server profile) and Script Profiler.
- Hot loops: avoid creating tables/closures per enemy per step; reuse
  arrays; after profiling, `@native` on tight server-side math functions
  (or `--!native` on the sim module); use squared distances.
- Client: pool models; `BulkMoveTo`; LOD (skip animation/billboards for
  distant enemies); limit particles; test on a low-end phone.
- Network: one EnemyNet batch per frame; cosmetics unreliable; don't
  replicate per-frame attributes/values.
- Spawn caps: hard-cap living enemies per match (e.g., 300) by merging
  late-wave enemies into fewer, tougher ones.

## 12. Testing the game

- **Pure modules** (PathMath, Targeting, EnemyNet, wave generator, damage
  formulas, economy math): Lune specs like `templates/tests/`, run in CI.
- **Balance**: a Lune script that loads TowerDefs/WaveDefs and prints DPS,
  cash efficiency and time-in-range per tower per map.
- **In Studio** (via the Studio MCP server if connected): start play, run
  `execute_luau` on the server to spawn waves / grant cash / skip to wave
  N, read `get_console_output`, take `screen_capture`s; test with 2–4
  players using Studio's multi-client test (Test → Clients and Servers).
- **Live**: publish to a private/limited test experience for teleports,
  purchases, and data stores; then roll out.
