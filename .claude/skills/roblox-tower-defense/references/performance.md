# Performance

Sources: Creator Docs `performance-optimization/*`,
`scripting/multithreading.md`, `luau/native-code-gen.md` (October 2026).

## Contents
1. Budgets and targets
2. Measure first
3. Server script time
4. Networking and replication
5. Client rendering and memory
6. Parallel Luau (Actors)
7. Native code generation
8. TD-specific checklist

---

## 1. Budgets and targets

- 60 FPS = 16.67 ms per frame for *everything* (scripts, physics,
  rendering). Most players are on phones; pick a low-end baseline device
  and test on it throughout development.
- Studio is not representative: it runs server + client in one process,
  so memory and timing are inflated. Profile live servers.
- Rough targets for a TD match server: script time well under ~5 ms per
  Heartbeat at peak enemy count; for clients: stay under ~1,000 draw
  calls on low-end phones (example threshold from Roblox's own guidance),
  and keep memory well below device limits to avoid out-of-memory crashes.

## 2. Measure first

- **Developer Console** (F9 in game, also on live servers): Memory,
  Network, Scripts, Server Stats, Log. Server tabs show the real server.
- **MicroProfiler** (Ctrl+Alt+F6 / ⌘⌥F6; can also capture server frames
  from the Developer Console): look for wide script blocks, physics,
  replication. Add labels with `debug.profilebegin("EnemySim")` /
  `debug.profileend()` around your systems.
- **Script Profiler** (Studio/Developer Console): per-function CPU time.
- Debug stats overlays: Shift+F5 in the client (and the other Shift+F1–F4
  overlays) show FPS, draw calls, memory and network.
- Change one thing at a time and re-measure.

## 3. Server script time

- Event-driven over per-frame work; when per-frame is needed, run one
  loop that updates everything rather than one loop/thread per object
  (`task.wait` per enemy is expensive).
- Fixed-step simulation at 10–30 Hz for game logic; render-rate
  interpolation happens on clients.
- Avoid allocating tables/closures in hot loops; reuse arrays
  (`table.clear`); keep data in plain tables, not Instances/attributes.
- Spatial work: squared distances; precompute static relationships (TD:
  tower ↔ path intervals); bucket entities if counts are large.
- Split heavy one-off work across frames (`task.wait()` every N items) or
  move it to parallel Luau.
- Disconnect connections you no longer need; destroy what you create.
- Don't put everything in ReplicatedStorage — clients load all of it.

## 4. Networking and replication

Common causes of lag (Roblox docs):
- Replicating data every frame that doesn't need it; sending on every
  input without throttling; sending whole inventories instead of deltas.
- Creating/destroying large Instance trees at runtime (maps) on the server
  — load in chunks.
- Server-side `TweenService` — replicates the property every frame; tween
  on clients instead.
- Visual effects created on the server — create them on clients from a
  small remote event.
- Leftover animation-editor data inside rigs that get cloned often.

Fixes: send changes, not state; batch per frame; use buffers for dense
data; `UnreliableRemoteEvent` for loss-tolerant high-rate data; compute on
clients whatever can be derived (positions along a path, countdowns).

## 5. Client rendering and memory

- Reuse meshes/textures (same asset IDs) — duplicates cost memory and draw
  calls; turn reused models into Packages.
- Prefer built-in materials over custom textures where possible.
- Avoid partial transparency (0 < T < 1) on large surfaces (overdraw);
  limit `ParticleEmitter` rates and `Beam`/`Trail` counts; disable
  `CastShadow` on small/many parts.
- Pool frequently created objects (enemy models, projectiles, damage
  numbers) instead of `Clone`/`Destroy` each time.
- Move many parts with `workspace:BulkMoveTo`; anchored, non-colliding,
  non-queryable, non-touchable parts are cheapest.
- LOD: hide health bars/animations for distant or off-screen enemies;
  `Model.LevelOfDetail` and streaming for big worlds.
- UI: avoid rebuilding UI every frame; update text only when values change;
  limit `UIGradient`/`UIStroke` heavy effects on low-end devices.

## 6. Parallel Luau (Actors)

- Scripts under different `Actor` instances can run in parallel. Inside a
  connection or after `task.desynchronize()`, code runs in parallel and
  may only *read* most of the DataModel; call `task.synchronize()` before
  writing to Instances.
- `RunService.Heartbeat:ConnectParallel(fn)` runs a handler in parallel.
- Communicate between actors with `Actor:SendMessage`/`BindToMessage`
  (or `BindToMessageParallel`) and `SharedTable` for shared data.
- Good fits: server-side raycast validation, procedural generation, large
  independent simulations (e.g., one Actor per match arena when a single
  server hosts several arenas). Measure — the overhead isn't free.

## 7. Native code generation

- `--!native` at the top of a server script or `@native` on a function
  compiles it to machine code; best for math-heavy loops (path sampling,
  targeting, buffer encoding). Type-annotate parameters (especially
  `Vector3`) so the compiler specializes.
- Costs: compile time at server start, extra memory, a per-game limit on
  native code size. Use selectively after profiling.

## 8. TD-specific checklist

- [ ] Enemies are server data, not server Parts; clients render them.
- [ ] One enemy-event batch and one cosmetic batch per frame per match.
- [ ] Tower targeting at sim rate (10–30 Hz), range checks via path
      intervals or squared distances.
- [ ] Projectiles are client visuals; the server schedules hits.
- [ ] Enemy/projectile/effect models are pooled on the client.
- [ ] Health bars update on events, hidden at full HP or when far.
- [ ] Living-enemy cap per match; late waves use fewer, tougher enemies.
- [ ] Profiled with max enemies on a low-end phone and on a live server.
