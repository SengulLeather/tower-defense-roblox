---
name: roblox-tower-defense
description: Build, extend, debug, balance and ship Roblox games in Luau, with deep support for tower defense (TD) games — project setup (Rojo, Rokit, Wally, Studio Script Sync, the built-in Studio MCP server), server-authoritative architecture, secure RemoteEvents, DataStores/ProfileStore session locking, ProcessReceipt and game passes, gacha/crate odds rules, 2026 publishing requirements, performance, cross-platform UI, plus TD systems (paths, waves, enemies, towers, targeting, upgrades, economy, lobby-to-match teleports). Use this skill whenever the user mentions Roblox, Roblox Studio, Luau, .luau files, Rojo, Robux, game passes, developer products, DataStores, or wants to design, build, fix, balance, monetize or publish a tower defense game — even for a single piece like a wave system, a tower upgrade, a lag problem, or a purchase bug.
---

# Roblox Tower Defense Development

Researched October 2026 from Roblox's official Creator Docs (Studio 0.742),
the engine API reference, and the current tool releases. The templates in
`templates/` are type-checked with luau-lsp (`--!strict`, Roblox
definitions), linted, formatted, and unit-tested under Lune.

## How to use this skill

1. **Orient before writing code.** Find out how the project is set up
   (`default.project.json` + `rokit.toml` = Rojo; service-named folders =
   Studio Script Sync; only a `.rbxl` = Studio-only). Read README/CLAUDE.md
   and two or three existing modules, and copy their layout, naming, and
   style. Check whether Studio MCP tools (`list_roblox_studios`,
   `execute_luau`, ...) are available in this session — they decide how you
   can test.
2. **Load only the reference you need** (each has a table of contents):

| Task | Read |
|---|---|
| Designing the game: towers, enemies, waves, economy, difficulty, meta, monetization fit, onboarding | `references/td-game-design.md` |
| Implementing TD systems: sim loop, enemy replication, targeting, placement, lobby↔match, data schema | `references/td-architecture.md` |
| Engine basics: services, script types/RunContext, replication, events, CFrames, streaming, current vs deprecated APIs, Studio vs live | `references/roblox-platform.md` |
| Luau language, types, idioms, gotchas | `references/luau.md` |
| Remotes, validation, rate limits, anti-exploit, Server Authority | `references/networking-and-security.md` |
| Saving data, ProfileStore, limits, migrations, leaderboards, MemoryStores | `references/data-persistence.md` |
| Passes, dev products, ProcessReceipt, ads, prices, paid random items, PolicyService, publishing/age rules, DevEx | `references/monetization-and-compliance.md` |
| Profiling, server/client/network optimization, Actors, native codegen | `references/performance.md` |
| UI layout, Input Action System, touch/gamepad placement, HUD checklist | `references/ui-and-input.md` |
| Rojo/Rokit/Wally, Script Sync, linting, Lune tests, Studio MCP, Studio CLI, Open Cloud, cloud containers | `references/tooling-and-workflow.md` |

3. **Start from the templates** when building the matching system
   (table below) instead of rewriting them.
4. **Verify** (see "Before you say it's done") and tell the user exactly
   what was and wasn't tested.

## Non-negotiables (and why)

- **The server decides; the client asks and renders.** Exploiters control
  their client completely: they can fire any remote with any arguments,
  read every replicated script, and change anything locally. Cash, HP,
  damage, placement, rewards and purchases are computed on the server.
- **Validate every remote**: rate-limit, type-check, reject NaN/inf
  (`NaN` passes `typeof == "number"` and slips past every `<`/`>` check),
  bounds/integer checks, ownership/phase/cash checks against server
  state, then act. Fail silently. Use `templates/RemoteGuard.luau`.
- **Never lose or duplicate player data**: one key per player, session
  locking (ProfileStore), `UpdateAsync` over `SetAsync`, autosave with
  jitter + save on leave + `BindToClose`, never save fallback/default data
  over real data after a failed load.
- **Developer products go through one idempotent `ProcessReceipt`**: record
  the `PurchaseId` in the player's save, save, and only then return
  `PurchaseGranted` (`templates/ReceiptHandler.luau`). Never grant from
  `PromptProductPurchaseFinished` or from a client message.
- **Don't simulate TD enemies as server Parts.** Moving hundreds of
  server-side models every frame floods replication. Simulate enemies as
  numbers (distance along the path) on the server and let clients render
  them from keyframes (`templates/PathMath.luau`, `templates/EnemyNet.luau`).
- **Write current APIs**: `task.*` (never `wait/spawn/delay`), `...Async`
  methods (`GetProductInfoAsync`, `AwardBadgeAsync`, `LoadCharacterAsync`,
  `ReserveServerAsync` + `TeleportAsync`), `Animator:LoadAnimation`,
  `PivotTo`, `AnalyticsService:Log*`, `AdService:ShowRewardedVideoAdAsync`.
  Full table: `references/roblox-platform.md` §11.
- **`--!strict` in new files**, and match the repo's StyLua/selene config.
  Don't use Luau's new `const` keyword unless the toolchain supports it
  (StyLua 2.4 / selene 0.30 / Lune 0.10 fail to parse it).
- **Design for phones first** (touch placement with confirm buttons, large
  targets, safe areas), then mouse/keyboard and gamepad.
- **Paid randomness is regulated**: crates/summons bought directly or
  indirectly with Robux need on-screen odds (summing to 100%), and players
  flagged by `PolicyService` (`ArePaidRandomItemsRestricted`,
  `IsPaidItemTradingAllowed`) must get the compliant alternative.
- **No secrets or admin backdoors in replicated code**, and no admin
  "passwords" checked through remotes — gate debug tools by UserId on the
  server.

## TD architecture at a glance

```
CLIENT (render + intent)                         SERVER (authority)
──────────────────────────                       ─────────────────────────────────
Placement ghost / UI  ── PlaceTower(id, pos) ──▶  RemoteGuard → validate → spend cash
                                                  Match:step(SIM_DT)  (fixed 20 Hz)
                                                    WaveRunner  → spawn queue
                                                    EnemySim    → distance += speed·dt
                                                    TowerSim    → Targeting.pick / cooldown
                                                    hits, splash, DoT, leaks, rewards
EnemyRenderer ◀── EnemyEvents (buffer, reliable,  ◀ EnemyNet.encode(spawn/motion/health/remove)
  d = d0 + speed·(now − t0)   1 batch per frame)
  PathMath.sample → BulkMoveTo
TowerFx      ◀── TowerFired (unreliable, batched) ◀ cosmetic shot events
HUD          ◀── MatchState (on change)          ◀ phase, wave, timer end, base HP, cash
                                                  PlayerData (ProfileStore) · ReceiptHandler
```

Lobby/match: either a **single place** (per-player arenas or one shared
match — simplest, fully testable in Studio) or a **lobby place + match
place** in one universe with `TeleportAsync` into reserved servers (best
for co-op; teleports don't work in Studio, so the match place must also
start a default match when run standalone). Details in
`references/td-architecture.md` §9.

## Templates

Copy into the game and adjust `require` paths. All are pure logic except
where noted, so they stay unit-testable.

| File | Put it in | What it does |
|---|---|---|
| `templates/PathMath.luau` | shared | Path from waypoints; position/facing at a distance; distance-to-path (placement validation); exact path intervals inside a tower's range (cheap range checks); time-in-range for balancing |
| `templates/Targeting.luau` | shared (server uses) | First/Last/Strongest/Weakest/Closest with flying/hidden filters and sensible tie-breaks; splash radius; chain hops |
| `templates/EnemyNet.luau` | shared | Buffer codec for per-frame enemy keyframes (Spawn/Motion/Health/Remove) |
| `templates/RemoteGuard.luau` | server | Finite/range/integer/string/key/Vector3/Instance validators, token-bucket rate limiter, guarded `connect` |
| `templates/ReceiptHandler.luau` | server | Idempotent ProcessReceipt (PurchaseId history, save-before-ack), data-layer agnostic |
| `templates/tests/*` | `tests/` | Lune test kit (injects Roblox datatypes) + 44 specs; copy the pattern for game rules |

Run the template tests: `lune run <skill>/templates/tests/run.luau <skill>/templates`.

## Build plan for a new TD game

Work in vertical slices; each phase ends playable and verified.

1. **Skeleton** — Rojo project (`src/shared|server|client`), Rokit tools,
   StyLua/selene configs, `Remotes` module, server/client entry scripts
   with ordered `start()` calls, `tests/` with Lune. Done when `rojo
   build` and the checks pass.
2. **Core loop, one player** — one map with a waypoint path, PathMath,
   EnemySim + EnemyNet + client EnemyRenderer, one tower type with
   Targeting, cash/base HP, 5 hand-made waves, win/lose. Done when a full
   match is playable in Studio and the sim modules have tests.
3. **Depth** — 5–8 towers covering the roles (single, splash, slow,
   sniper, anti-air/detection, support, farm), upgrades with deltas,
   targeting modes, enemy archetypes (fast, tank, swarm, flying, hidden,
   boss), wave generator + difficulty modes, 2x speed, skip vote. Balance
   with a Lune script (DPS, cost efficiency, time in range).
4. **Persistence and meta** — ProfileStore, data template + migrations,
   coins/XP/levels, tower unlocks and loadout, rewards at match end,
   daily rewards/quests, codes, badges, leaderboards.
5. **Multiplayer** — co-op match (cash model, ownership, votes), lobby with
   queues/parties and teleports (or keep single place with arenas), late
   join, rejoin handling.
6. **Monetization and analytics** — passes (2x speed, VIP, extra slot),
   dev products via ReceiptHandler, skins, crates/summons only with
   compliant odds UI + PolicyService handling, rewarded ads, runtime
   prices; onboarding funnel, economy, and custom events.
7. **Polish and launch** — tutorial, UI on phone/tablet/console, sounds
   and effects, performance pass at max enemies on a low-end phone,
   localization, store page, maturity questionnaire, account verification
   and publishing requirements, private test → public.

## Before you say it's done

- Run `scripts/check.sh [project_dir]` (StyLua, selene, `rojo build`,
  luau-lsp analyze when `LUAU_LSP_DEFS` is set, Lune tests). It reports
  which tools are missing; install via `rokit install` or see
  `references/tooling-and-workflow.md` §10.
- Add or update Lune specs for any pure logic you changed.
- **With Studio MCP**: start play, read `get_console_output` for errors,
  drive the scenario (`execute_luau` on the Server datamodel to start
  waves/give cash, `user_mouse_input` for UI), `screen_capture` to look,
  stop play. Test multiplayer with Studio's Clients and Servers mode.
- **Without Studio** (e.g., a cloud container): say clearly that the
  change is verified only by static checks and unit tests, and give the
  user a short manual test script (steps, expected result, expected
  output lines).
- Things that only work on live servers (teleports, real purchases, some
  data store behavior) need a published test place — say so.

## Quick reference

| Limit / fact | Value |
|---|---|
| Client→server remote rate | ~500 requests/s per client, shared across all RemoteEvents |
| UnreliableRemoteEvent payload | > 1000 bytes is dropped |
| DataStore value | ~4 MB per key; key/name ≤ 50 chars |
| DataStore budget (experience) | read 300 + 40·CCU/min, write 300 + 20·CCU/min (`UpdateAsync` uses both) |
| DataStore storage | 500 MB + 1 MB × lifetime users |
| `BindToClose` | ~30 s to finish saves |
| AnalyticsService | 120 + 20·CCU requests/min |
| ConfigService | up to 1,000 live configs; values update without republishing |
| Luau Execution (Open Cloud) | ≤ 5 min per task, 10 concurrent per place |
| Script Sync | ≤ 10,000 scripts per root, 128 roots |
| Publish to all ages | age check + ID/face verification + 2FA + 2-month Plus/Premium or 1,000 R$ refundable fee + evaluation (250 highly engaged plays in 60 days) |
| DevEx | $0.0038 per Earned Robux (US 18+ eligible: $0.0054); min 30,000 |

Studio vs live: DataStores need "Enable Studio Access to API Services" and
hit **live** data (use a `_Studio` store or `ProfileStore.Mock`);
TeleportService doesn't work in Studio; purchases are simulated;
Studio performance numbers aren't representative.

## Working in sengulleather/tower-defense-roblox

This repo is a Rojo project (Rokit-pinned Rojo 7.6.1, StyLua 2.4.0,
selene 0.30.1, Wally 0.3.2), `src/shared` → `ReplicatedStorage.Shared`,
`src/server` → `ServerScriptService.Server`, `src/client` →
`StarterPlayerScripts.Client`, `--!strict`, tabs, double quotes. It is a
single-place design: a shared lobby plus a private arena per player
(`PlayerSlot`, `ArenaController`), grid placement (`Config.CELL_SIZE` = 8
studs), realms with themed paths (`RealmDefs`), `GameState` per player,
`PlayerProgress` DataStore wrapper, game passes and cash packs in
`GamePassConfig`. Follow those conventions when extending it. Known gaps
worth raising with the user before large changes (verified October 2026):
- `PlaceTower`/`PlaceFromInventory` accept any number for `gx`/`gy` (no
  integer or bounds check), so a crafted remote can place towers off-grid,
  on top of each other (fractional cells), or outside the arena.
- `UnlockAdmin` accepts a 4-digit code over a remote with no rate limit;
  it grants every gun, all realms and premium items — brute-forceable.
- `ProcessReceipt` adds gold in memory and returns `PurchaseGranted`
  without saving or recording the `PurchaseId`.
- `PlayerProgress` has no session locking (`UpdateAsync` ignores the old
  value), so fast server hops can lose progress.
- Enemies are server Models moved with `PivotTo` every Heartbeat
  (`EnemyManager`) — the main scaling bottleneck.
- Robux prices are hardcoded in `GamePassConfig`; price optimization and
  regional pricing need runtime `GetProductInfoAsync` prices.
