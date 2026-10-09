# Roblox Platform Fundamentals

The engine concepts every Roblox feature builds on. Sources: Roblox Creator
Docs (projects/data-model, projects/client-server, scripting/*,
workspace/streaming, engine API reference; Studio 0.742, October 2026).

## Contents
1. The DataModel and services
2. Script types, RunContext, and where code runs
3. Replication rules
4. Events, signals, and the task scheduler
5. Instances, attributes, tags
6. Parts, physics, collisions, spatial queries
7. CFrame and moving things
8. Streaming
9. Characters and players
10. Time, randomness, IDs
11. Current vs deprecated APIs (2026)
12. Studio vs live server differences

---

## 1. The DataModel and services

`game` is the DataModel. Get services with `game:GetService("Name")` (never
`game.Name`). Containers and who sees them:

| Container | Server | Client | Use for |
|---|---|---|---|
| `Workspace` | ✓ | ✓ (replicated, may stream) | The 3D world: maps, towers, live models |
| `ReplicatedStorage` | ✓ | ✓ | Shared modules, remotes, templates both sides clone |
| `ReplicatedFirst` | ✓ | ✓ (first, before everything) | Loading screen script + minimal assets |
| `ServerScriptService` | ✓ | ✗ | Server code |
| `ServerStorage` | ✓ | ✗ | Server-only assets (maps cloned on demand, secrets in modules) |
| `StarterPlayer.StarterPlayerScripts` | copied | ✓ (per player, once) | Client entry scripts |
| `StarterPlayer.StarterCharacterScripts` | copied | ✓ (each respawn) | Character-bound client scripts |
| `StarterGui` | copied | ✓ → `PlayerGui` | UI (ScreenGuis); `ResetOnSpawn = false` for persistent UI |
| `StarterPack` | copied | ✓ → `Backpack` | Tools |
| `Lighting`, `SoundService`, `Teams`, `Players` | ✓ | ✓ | Environment, audio, teams, player list |

Anything that replicates to the client can be read (and decompiled) by an
exploiter. Server-only logic and data belong in ServerScriptService/
ServerStorage.

## 2. Script types, RunContext, and where code runs

- `Script` — runs on the server by default (`RunContext = Legacy`: only in
  server containers like ServerScriptService/Workspace). With `RunContext =
  Client` it runs on clients, including from ReplicatedStorage. With
  `RunContext = Server` it can run in more places (not recommended in
  replicated containers).
- `LocalScript` — client only; runs from StarterPlayerScripts,
  StarterCharacterScripts, StarterGui, StarterPack, or a player's character.
- `ModuleScript` — code library returned by `require`. Runs once per
  environment (the server and *each* client get their own copy/cache).

Roblox's recommendation: one server entry Script, one client entry script,
everything else in ModuleScripts with a `start()`/`init()` function, called
in a deliberate order. Use CollectionService tags instead of scripts inside
Workspace models.

File naming differs between tools — check which one the project uses:

| File on disk | **Rojo** creates | **Studio Script Sync** creates |
|---|---|---|
| `name.luau` | ModuleScript | ModuleScript |
| `name.server.luau` | Script | Script (RunContext Server) |
| `name.client.luau` | **LocalScript** | **Script (RunContext Client)** |
| `name.local.luau` | — | LocalScript |
| `folder/init.luau` | folder becomes a ModuleScript | Script/Module with children |
| `folder/init.server.luau` / `init.client.luau` | folder becomes Script / LocalScript | same idea, per rules above |

## 3. Replication rules

- Server changes to replicated Instances replicate to clients
  (properties, children, attributes, tags). Client changes do **not**
  replicate (FilteringEnabled is always on), except physics of parts the
  client has network ownership of (its character, unanchored parts it
  owns) and a few input-driven things (e.g., Animator tracks on its own
  character).
- Communicate everything else with remotes (`networking-and-security.md`).
- Replication is ordered per Instance but don't assume a child exists on
  the client when a remote referencing it arrives: use `WaitForChild` (with
  a timeout for optional things) or send the data in the remote itself.
- Instances parented to `nil` or ServerStorage are invisible to clients;
  passing them through a remote arrives as `nil`.

## 4. Events, signals, and the task scheduler

- Connect: `signal:Connect(fn)` returns an `RBXScriptConnection`; call
  `:Disconnect()` when done (or use a cleanup helper like Trove/Janitor).
  `:Once(fn)` auto-disconnects; `:Wait()` yields until the next fire.
- **Deferred events** (`Workspace.SignalBehavior = Deferred`, the
  default): handlers run at the next resumption point, not synchronously
  inside the property change/fire. Don't rely on a handler having run
  immediately after setting a property.
- Use the `task` library: `task.spawn(fn, ...)` (run now in a new thread),
  `task.defer(fn, ...)` (end of current resumption cycle),
  `task.delay(seconds, fn, ...)`, `task.wait(seconds)` (returns elapsed),
  `task.cancel(thread)`. Never use legacy `wait()`, `spawn()`, `delay()`.
- Frame events (`RunService`): `PreRender` (client, before rendering —
  camera/visual updates; replaces `RenderStepped`), `PreAnimation`,
  `PreSimulation` (before physics; replaces `Stepped`), `PostSimulation`
  (after physics; `Heartbeat` is equivalent and still common). Server
  game loops use `Heartbeat`/`PostSimulation` with a fixed-step
  accumulator.
- `RunService:IsServer()`, `IsClient()`, `IsStudio()`.
- Don't busy-wait (`while not x do task.wait() end`) when a signal exists.

## 5. Instances, attributes, tags

- Create: `local p = Instance.new("Part")`, set properties, set `Parent`
  **last** (parenting first triggers replication/physics for every
  subsequent property write).
- Destroy with `:Destroy()` (disconnects its events, locks Parent). For
  timed cleanup use `task.delay(t, function() inst:Destroy() end)` or
  `Debris:AddItem`.
- Find: `FindFirstChild(name)`, `FindFirstChildOfClass`,
  `FindFirstChildWhichIsA`, `FindFirstAncestorOfClass`, `WaitForChild`,
  `GetChildren`, `GetDescendants`, `IsA`, `IsDescendantOf`.
- **Attributes**: `inst:SetAttribute("Level", 3)`, `GetAttribute`,
  `GetAttributeChangedSignal("Level")`. Replicate from server to client;
  ideal for small per-instance state (owner UserId, level, target mode).
  Supported types: string, boolean, number, UDim/UDim2, BrickColor, Color3,
  Vector2/Vector3, CFrame, NumberSequence, ColorSequence, NumberRange,
  Rect, Font, EnumItem.
- **Tags** (CollectionService): `inst:AddTag("Placeable")`, `HasTag`,
  `RemoveTag`, `CollectionService:GetTagged(tag)`,
  `GetInstanceAddedSignal(tag)` / `GetInstanceRemovedSignal(tag)`. Tag
  map parts in Studio, handle them from one module.
- Clone templates: `ReplicatedStorage.Assets.Towers.Archer:Clone()`.

## 6. Parts, physics, collisions, spatial queries

- Key BasePart properties: `Anchored` (no physics), `CanCollide`,
  `CanTouch` (Touched events), `CanQuery` (raycasts/overlap queries),
  `Massless`, `CastShadow`, `Transparency`, `Material`, `Color`,
  `CollisionGroup` (string).
- Collision groups: `PhysicsService:RegisterCollisionGroup("Enemies")`,
  `PhysicsService:CollisionGroupSetCollidable("Enemies", "Players", false)`.
- Network ownership: unanchored parts near a player may be simulated by
  that player's client. For server-controlled physics objects call
  `part:SetNetworkOwner(nil)`. TD enemies should be anchored/client-only
  anyway.
- Prefer spatial queries over `Touched` for gameplay logic:
  - `workspace:Raycast(origin, direction, params)` → `RaycastResult?`
    (`.Instance`, `.Position`, `.Normal`, `.Material`); `RaycastParams`
    with `FilterType = Enum.RaycastFilterType.Include/Exclude` and
    `FilterDescendantsInstances`.
  - `Spherecast`, `Blockcast`, `Shapecast` for thick casts.
  - `GetPartBoundsInRadius(position, radius, OverlapParams)`,
    `GetPartBoundsInBox`, `GetPartsInPart`.
- Constraints for movers: `AlignPosition`, `AlignOrientation`,
  `LinearVelocity`, `AngularVelocity`, welds via `WeldConstraint`.

## 7. CFrame and moving things

- `CFrame.new(pos)`, `CFrame.lookAt(from, to)`, `CFrame.Angles(rx, ry, rz)`
  (radians), `cf * CFrame.new(offset)` (local offset), `cf:Lerp(goal, t)`,
  `cf.Position`, `cf.LookVector`, `cf:ToObjectSpace(other)`,
  `cf:PointToWorldSpace(v)`.
- Models: `model:PivotTo(cf)`, `model:GetPivot()`,
  `model:GetBoundingBox()`. (`SetPrimaryPartCFrame` is deprecated.)
- Moving many parts per frame: `workspace:BulkMoveTo(parts, cframes,
  Enum.BulkMoveMode.FireCFrameChanged)` — much cheaper than setting
  `CFrame` in a loop.
- Smooth one-off animations: `TweenService:Create(inst, TweenInfo.new(t,
  Enum.EasingStyle.Quad, Enum.EasingDirection.Out), { Position = ... })
  :Play()`. Tweens on the server replicate every step — tween cosmetic
  things on the client.
- Character/rig animation: load through the `Animator`
  (`humanoid:FindFirstChildOfClass("Animator"):LoadAnimation(anim)`), not
  `Humanoid:LoadAnimation` (deprecated). For non-humanoid rigs use an
  `AnimationController` with an `Animator` child.

## 8. Streaming

`Workspace.StreamingEnabled` (on by default in new places) sends only
nearby parts of the world to each client. Consequences:
- Client code must not assume distant Instances exist; use `WaitForChild`
  with timeouts, `CollectionService` added/removed signals, or
  `player:RequestStreamAroundAsync(position)` before teleporting a player
  somewhere.
- `Model.ModelStreamingMode`: `Default`/`Nonatomic`, `Atomic` (whole model
  streams together), `Persistent` (always sent), `PersistentPerPlayer`.
  For a TD map the path and placement surfaces should be `Atomic` or
  `Persistent`.
- Small single-map games (most TD match servers) can simply disable
  streaming. Server Authority requires it to be on.

## 9. Characters and players

- `Players.PlayerAdded` / `PlayerRemoving`; handle players already in the
  game when your script starts (`for _, p in Players:GetPlayers()`).
- `player.CharacterAdded` / `CharacterRemoving`; `Players.CharacterAutoLoads`
  (false if you spawn characters yourself with `player:LoadCharacterAsync()`).
- `Humanoid`: `Health`, `WalkSpeed`, `Died`; R15 is the default rig.
- `player.UserId` (stable, use for keys), `player.Name` (can change),
  `player.DisplayName` (cosmetic only).
- Camera is client-only: `workspace.CurrentCamera`; a TD camera is often a
  scriptable top-down/isometric camera (`CameraType = Scriptable`) with
  pan/zoom limits, or the default camera with zoom limits
  (`player.CameraMaxZoomDistance`).

## 10. Time, randomness, IDs

- `os.clock()` — high-resolution CPU time for measuring durations.
- `os.time()` / `DateTime.now()` — UTC wall clock (daily rewards, events).
- `workspace:GetServerTimeNow()` — clock synchronised between server and
  clients; use for timers and keyframes shown on clients.
- `Random.new(seed)` objects (`:NextInteger(a, b)`, `:NextNumber()`) for
  reproducible sequences (wave generation); `math.random` is fine for
  cosmetic randomness.
- `HttpService:GenerateGUID(false)` for unique ids;
  `HttpService:JSONEncode/JSONDecode` for serialization.

## 11. Current vs deprecated APIs (2026)

Roblox renamed many yielding methods to `...Async`. Write the current form:

| Deprecated | Use instead |
|---|---|
| `wait()`, `spawn()`, `delay()` | `task.wait`, `task.spawn`/`task.defer`, `task.delay` |
| `MarketplaceService:GetProductInfo` | `MarketplaceService:GetProductInfoAsync` |
| `MarketplaceService:PlayerOwnsAsset` | `PlayerOwnsAssetAsync` |
| `BadgeService:AwardBadge`, `UserHasBadge` | `AwardBadgeAsync`, `UserHasBadgeAsync` |
| `Player:LoadCharacter` | `Player:LoadCharacterAsync` |
| `Player:IsInGroup`, `GetRankInGroup(Async)`, `GetRoleInGroup(Async)` | `Player:IsInGroupAsync`; `GroupService:GetRolesInGroupAsync` |
| `Player:IsFriendsWith` | `Player:IsFriendsWithAsync` |
| `TeleportService:ReserveServer` | `ReserveServerAsync` |
| `TeleportService:TeleportToPrivateServer`, `TeleportPartyAsync`, `TeleportToPlaceInstance`, client `Teleport` | server `TeleportService:TeleportAsync(placeId, players, TeleportOptions)` |
| `Humanoid:LoadAnimation` | `Animator:LoadAnimation` |
| `Model:SetPrimaryPartCFrame`, `GetPrimaryPartCFrame` | `Model:PivotTo`, `GetPivot` |
| `AnalyticsService:FireCustomEvent`, `FireInGameEconomyEvent`, `FirePlayerProgressionEvent` | `LogCustomEvent`, `LogEconomyEvent`, `LogProgressionStartEvent`/`CompleteEvent`/`FailEvent` (+ `LogFunnelStepEvent`, `LogOnboardingFunnelStepEvent`) |
| `AdService:ShowVideoAd` (decommissioned) | `AdService:ShowRewardedVideoAdAsync` |
| `CollectionService:GetCollection` | `CollectionService:GetTagged` |
| `ContentProvider:Preload` | `ContentProvider:PreloadAsync` |
| `BasePart.Velocity` | `AssemblyLinearVelocity` |

Not deprecated but superseded for new code: `RunService.RenderStepped` →
`PreRender`, `RunService.Stepped` → `PreSimulation` (`Heartbeat` remains
standard).

When unsure whether an API is current, check the engine API reference
(Creator Hub) or the Studio MCP `http_get` docs tool; luau-lsp flags
deprecated members.

## 12. Studio vs live server differences

| Feature | In Studio playtest |
|---|---|
| DataStores | Only with *Game Settings → Security → Enable Studio Access to API Services* on a published place; uses **live** data |
| TeleportService | Does not work — publish and test in the Roblox app |
| MarketplaceService purchases | Test prompts; no Robux charged; `ProcessReceipt` still runs |
| HttpService | Requires *Allow HTTP Requests* |
| MemoryStores / MessagingService | Work in Studio with API access (separate from live) |
| Multiplayer | Test → Clients and Servers (start N players) |
| Device testing | Device Emulator (phones/tablets/console), Controller Emulator, Network Simulator for latency |
| Server performance | Not representative — profile live servers in the Developer Console (F9) and MicroProfiler |
