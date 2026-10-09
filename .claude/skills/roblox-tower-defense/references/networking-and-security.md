# Networking and Security

Roblox is client-server with the server as the only trustworthy machine.
Source: Roblox Creator Docs (scripting/security/*, scripting/events/remote.md,
RemoteEvent / UnreliableRemoteEvent API reference), October 2026.

## Contents
1. What an exploiter can do
2. Remote types and limits
3. Validation checklist for every remote
4. Rate limiting
5. Design patterns that resist cheating
6. Payload design and bandwidth
7. Server Authority (physics) — when it matters
8. Secrets, admin tools, and things that must never be on the client
9. Common vulnerabilities found in TD games

---

## 1. What an exploiter can do

Assume a determined player fully controls their client. They can:
- decompile any LocalScript or any ModuleScript that replicates to them
  (anything in ReplicatedStorage, ReplicatedFirst, Workspace, StarterGui,
  StarterPlayer...), even if it never runs on the client;
- fire any RemoteEvent / invoke any RemoteFunction at any rate with
  arbitrary arguments (only the first `player` argument is trustworthy);
- send NaN, ±inf, huge strings, deeply nested tables, or tables that mimic
  Instances;
- trigger `Touched`, `ProximityPrompt`, `ClickDetector` at any range/rate;
- move their character anywhere, take network ownership of unanchored
  parts they own, change anything locally without firing events.

Therefore: all rules, prices, cooldowns, inventories and currency live on
the server; the client only renders and asks.

## 2. Remote types and limits

| Type | Use | Notes |
|---|---|---|
| `RemoteEvent` | One-way, reliable, ordered per remote | Default choice. Client→server is throttled at ~500 requests/s per client, **shared across all RemoteEvents**. |
| `UnreliableRemoteEvent` | Cosmetic or high-frequency, loss-tolerant data (muzzle flashes, snapshots) | Payload > **1000 bytes is dropped**; no ordering or delivery guarantee; also dropped if no handler is connected yet. Add a sequence number if order matters. |
| `RemoteFunction` | Request/response from client to server (`InvokeServer`) | Yields the caller. **Never `InvokeClient` from the server** — a malicious or disconnected client can hang that server thread forever. |
| `BindableEvent` / `BindableFunction` | Same-side communication | Not networked. Prefer plain module signals. |
| Attributes / ValueObjects | Low-frequency replicated state (owner id, level, state name) | Each change replicates; don't write them per frame. |

Other notes:
- Events are deferred by default (`Workspace.SignalBehavior = Deferred`):
  handlers run at the next resumption point, not inside the `Fire` call.
- Handler start order is preserved per remote, but a handler that yields
  can let later messages start first.
- Tables lose mixed numeric/string keys and non-string keys get converted
  to strings; functions become nil; metatables are dropped. Send arrays or
  pure dictionaries, or a `buffer`.
- Create remotes on the server (or in the place file) and fetch them on the
  client with `WaitForChild`. A single `Remotes` module that both sides
  require (like `src/shared/Remotes.luau` in this repo) avoids typos.
- Networking libraries (Blink, Zap — IDL compilers that generate typed,
  buffer-packed remotes; Packet, ByteNet) can save bandwidth and add
  validation; worth it for large games, optional for a first TD.

## 3. Validation checklist for every remote

For each `OnServerEvent` / `OnServerInvoke` handler, in this order:

1. **Rate limit** the player (token bucket; `templates/RemoteGuard.luau`).
2. **Type check** every argument: `typeof(x) == "Instance"`, `"Vector3"`,
   `type(x) == "string"`, etc. Reject anything unexpected.
3. **Value check**: finite numbers (`math.isfinite` or
   `RemoteGuard.isFiniteNumber` — NaN passes `typeof == "number"` and every
   `>`/`<` check fails silently), integer where an index is expected,
   in-range, strings with length caps (and UTF-8 if displayed), ids that
   exist in a server-side table (`RemoteGuard.isKeyOf`), Instances that are
   descendants of the expected container (`RemoteGuard.isInstanceUnder`).
4. **Context/permission**: is the player in this match? alive? owns this
   tower? has enough cash (read from server state, never from the client)?
   is the action allowed in the current phase? within distance of the shop
   NPC? cooldown elapsed?
5. **Act** using server data (server-side prices and stats), then
   replicate results.
6. **Fail silently** for invalid requests (don't give exploiters an oracle);
   optionally count violations for moderation.

```lua
Remotes.UpgradeTower.OnServerEvent:Connect(function(player, towerId)
	if not upgradeLimiter:allow(player) then return end
	if not RemoteGuard.isInteger(towerId, 1, 2^31) then return end
	local match = Matches.forPlayer(player)
	local tower = match and match.towers[towerId]
	if not tower or tower.owner ~= player then return end
	local nextLevel = TowerDefs[tower.kind].upgrades[tower.level + 1]
	if not nextLevel then return end
	local state = match.players[player]
	if state.cash < nextLevel.cost then return end
	state.cash -= nextLevel.cost
	match:upgrade(tower)
end)
```

## 4. Rate limiting

- Per player, per action type. A token bucket allows bursts (fast clicking)
  while capping sustained rate: `RemoteGuard.newRateLimiter(capacity,
  refillPerSecond)`; call `limiter:forget(player)` on `PlayerRemoving`.
- Also limit anything that calls rate-limited Roblox services
  (DataStores, MarketplaceService, BadgeService, TextService, HttpService)
  and anything expensive (cloning big models, pathfinding, filtering).
- Debounce `Touched`/`ProximityPrompt` triggers on the server per player.

## 5. Design patterns that resist cheating

Prefer designs where cheating is impossible or worthless over detection:
- Server computes all damage from server-side tower stats; the client never
  reports damage or kills.
- Rewards come from server-observed outcomes (wave reached on the server's
  sim), never from a client "I won" message.
- Purchases and currency only change inside server code paths with
  validated, idempotent logic.
- Shops check distance from the server-side character position (with
  latency tolerance) if proximity matters.
- Sequential checkpoints (obbies) / sequential tutorial steps are validated
  in order on the server before granting rewards.
- For any "admin" or debug feature, gate by a `player.UserId` allow-list or
  group role on the server (`GroupService:GetRolesInGroupAsync`; the
  `Player:GetRankInGroup*` methods are deprecated) — never by a password
  typed on the client.

## 6. Payload design and bandwidth

- Send **intent**, not state, from client to server (`"place", towerId,
  cell`), and **diffs/keyframes**, not full state, from server to client.
- Batch per frame: one call with an array (or a buffer) beats 100 calls.
- `buffer` values are compact and fast; see `templates/EnemyNet.luau` for a
  packed format with a header and typed records.
- Use `workspace:GetServerTimeNow()` for timestamps both sides agree on.
- Don't replicate what clients can compute (positions along a known path,
  timers from an end-time, cosmetic randomness from a shared seed).
- Avoid parenting thousands of Instances under replicated containers at
  once; spread creation or build cosmetic objects on the client.

## 7. Server Authority (physics) — when it matters

Roblox's Server Authority model (announced as available to all creators
in mid-2026) makes the server authoritative for physics, with client-side
prediction and rollback so input still feels instant. Enable with
`Workspace.AuthorityMode = Server`, which also turns on
NextGenerationReplication, PlayerScriptsUseInputActionSystem, Deferred
signals, UseFixedSimulation and StreamingEnabled. It blocks physics
exploits like speed hacks and flyhacks without custom anti-cheat code.

For a TD game, enemies and towers are already server-simulated data, so
Server Authority mainly matters if players walk around (lobby, or a
player-controlled hero/gun like this repo's player guns). Treat it as an
option to evaluate, not a requirement; test performance and feel before
switching an existing game.

## 8. Secrets, admin tools, and things that must never be on the client

- Never put API keys, webhook URLs, admin codes, code-redemption lists,
  drop tables you don't want leaked, or anti-cheat logic in
  ReplicatedStorage/StarterPlayer/StarterGui/Workspace. Server-only code
  belongs in `ServerScriptService` / `ServerStorage`.
- HTTP secrets: store them in the experience's **Secrets** store
  (Creator Hub) and read with `HttpService:GetSecret(name)` on the server.
- Never trust `TeleportData` for anything valuable; it passes through the
  client.
- User-generated text shown to others (custom names, signs, messages) must
  be filtered with `TextService:FilterStringAsync` on the server; chat
  goes through `TextChatService`, which filters automatically.

## 9. Common vulnerabilities found in TD games

| Bug | Fix |
|---|---|
| `PlaceTower(gx, gy)` accepts NaN/huge/fractional coordinates | integer + bounds check |
| Client sends tower cost or uses client-side cash | server-side `TowerDefs` cost and cash |
| Sell handler doesn't check ownership → sell teammates' towers | owner check |
| Upgrade spam beats the cash check due to yields between check and spend | check-and-spend with no yield in between |
| Admin/cheat code checked on the server but brute-forceable (4 digits, no rate limit) | remove; use a UserId allow-list |
| `ProcessReceipt` grants currency without saving or recording `PurchaseId` → lost or duplicated purchases | `templates/ReceiptHandler.luau` |
| Reward remote `ClaimReward(amount)` | server computes rewards from its own records |
| Code redemption without per-user record | store redeemed codes in the player's save |
| Unfiltered custom text | `TextService` filtering |
