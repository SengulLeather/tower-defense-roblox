# Data Persistence (DataStores, ProfileStore, MemoryStores)

Sources: Roblox Creator Docs `cloud-services/data-stores/*` (best practices,
error codes and limits, player data & purchasing sample), ProfileStore
source/docs (MadStudioRoblox/ProfileStore, wally `lm-loleris/profilestore@1.0.3`).
Checked October 2026.

## Contents
1. Rules that prevent data loss
2. Current limits (2026)
3. Recommended: ProfileStore (session locking)
4. Raw DataStore pattern (if you can't use ProfileStore)
5. Schema, defaults, migrations
6. Purchases and data
7. Leaderboards, global state, cross-server
8. Studio testing
9. Operations: observability, RTBF, Extended Services

---

## 1. Rules that prevent data loss

1. **One key per player** in one data store (e.g. `PlayerData` /
   `Player_<UserId>`), holding one table. Atomic, fewer requests, easy
   rollback. Never key by name/display name.
2. **Session lock** the key (ProfileStore does this). Without it, a player
   who hops servers quickly (teleport!) can be loaded on server B before
   server A's final save lands — data loss and item-duplication exploits.
3. **Keep data in memory** during the session; write on an autosave
   interval (with random per-player offset), on leave, on shutdown
   (`game:BindToClose`, ~30 s budget), and immediately after purchases.
4. **Use `UpdateAsync`** for writes that depend on the current value or
   that several servers might touch. `SetAsync` blindly overwrites.
5. **Never save fallback data over real data.** If loading failed, mark
   the session as errored, let the player play with defaults (and tell
   them), but block saving and purchases for that session.
6. **Retry with exponential backoff + jitter**, in order per key (an old
   retry must not overwrite a newer write). Writes can succeed even when
   the call errors — design for unknown outcomes.
7. **Don't pre-compress** data; Roblox compresses stored data itself and
   counts the compressed size.
8. **Version your schema** (`schemaVersion` field) and migrate on load.

## 2. Current limits (2026)

| Limit | Value |
|---|---|
| Key name / store name / scope | 50 characters each |
| Value size | 4,194,304 characters (~4 MB) per key, JSON-encoded |
| Metadata | 300 characters total |
| Per-key throughput | Read 25 MB/min, write 4 MB/min (rounded up per KB per request) |
| Experience request budget (standard stores, shared by all servers + Open Cloud) | Read `300 + 40 × CCU`/min · Write `300 + 20 × CCU`/min · List `300 + 2 × CCU`/min · Remove `300 + 40 × CCU`/min |
| `UpdateAsync` | Consumes **both** a read and a write |
| Throttle queues | 30 requests per queue (Set, Ordered set, Get, Ordered get); beyond that requests fail (errors 301–306) |
| Storage | `500 MB + 1 MB × lifetime users`, measured on the compressed latest version of each key |
| Per-server control | `DataStoreService:SetRateLimitForRequestType` / `GetRequestBudgetForRequestType` |

Studio "Run" mode uses separate, lower static limits. Use Team Create
test sessions if you need to test throttling realistically.

## 3. Recommended: ProfileStore (session locking)

ProfileStore (by loleris; successor to the unmaintained ProfileService)
handles session locking, autosave (default every 300 s, using
MessagingService to hand sessions over quickly), shutdown saves, and a
mock store for Studio. It is a server-only module. Install with Wally:

```toml
# wally.toml
[server-dependencies]
ProfileStore = "lm-loleris/profilestore@1.0.3"
```

Or copy `ProfileStore.luau` into `src/server/`. Basic usage (adapted from
its tutorial):

```lua
--!strict
local Players = game:GetService("Players")
local ProfileStore = require(script.Parent.ProfileStore)

local TEMPLATE = require(script.Parent.DataTemplate) -- see §5

local PlayerStore = ProfileStore.New("PlayerData", TEMPLATE)
local Profiles: { [Player]: typeof(PlayerStore:StartSessionAsync("")) } = {}

local function onPlayerAdded(player: Player)
	local profile = PlayerStore:StartSessionAsync(`Player_{player.UserId}`, {
		Cancel = function()
			return player.Parent ~= Players -- stop waiting if they left
		end,
	})
	if profile == nil then
		player:Kick("Your data couldn't be loaded. Please rejoin.")
		return
	end
	profile:AddUserId(player.UserId) -- GDPR / right-to-be-forgotten
	profile:Reconcile() -- fill in fields added to TEMPLATE since last save
	profile.OnSessionEnd:Connect(function()
		Profiles[player] = nil
		player:Kick("Your data was loaded on another server. Please rejoin.")
	end)
	if player.Parent == Players then
		Profiles[player] = profile
		-- replicate initial data to the client, start systems...
	else
		profile:EndSession() -- left while loading
	end
end

for _, player in Players:GetPlayers() do
	task.spawn(onPlayerAdded, player)
end
Players.PlayerAdded:Connect(onPlayerAdded)
Players.PlayerRemoving:Connect(function(player)
	local profile = Profiles[player]
	if profile then
		profile:EndSession() -- final save + release lock
	end
end)
```

Key API: `ProfileStore.New(name, template)`, `store:StartSessionAsync(key,
{Cancel=, Steal=})`, `store:GetAsync(key)` (read-only view),
`store:MessageAsync(key, msg)`, `profile.Data`, `profile.LastSavedData`,
`profile:IsActive()`, `profile:Reconcile()`, `profile:Save()`,
`profile:EndSession()`, `profile:AddUserId()`, signals `OnSave`,
`OnLastSave`, `OnAfterSave`, `OnSessionEnd`; `ProfileStore.Mock` for tests;
`ProfileStore.DataStoreState` ("NotReady", "NoInternet", "NoAccess",
"Access"). Read the module's header comment for the exact current API.

Mutate `profile.Data` directly and synchronously. If code yields between
`IsActive()` and a write, check again — the session may have ended.

## 4. Raw DataStore pattern (if you can't use ProfileStore)

Follow Roblox's own reference design (Player Data and Purchasing sample):
- A per-key **queue** that serializes requests and retries with backoff
  (`DataStoreWrapper`).
- **Session lock in key metadata** written atomically inside the same
  `UpdateAsync` that reads the data (`LockId` GUID + timestamp; respect
  other servers' unexpired locks; refresh the lock on every autosave;
  remove it on the final save).
- Autosave every ~180 s with a random initial offset per player.
- On `BindToClose`, skip queued stale requests and save everyone in
  parallel; return only when all saves finish.

```lua
-- Minimal retry helper. Use it inside a per-key queue so retries stay ordered.
local function withRetries<T>(fn: () -> T, attempts: number?): (boolean, T | string)
	local maxAttempts = attempts or 5
	for attempt = 1, maxAttempts do
		local ok, result = pcall(fn)
		if ok then
			return true, result
		end
		if attempt < maxAttempts then
			local backoff = math.min(32, 2 ^ attempt)
			task.wait(backoff * (0.5 + math.random() * 0.5))
		else
			return false, tostring(result)
		end
	end
	return false, "unreachable"
end
```

## 5. Schema, defaults, migrations

```lua
-- DataTemplate.luau (server)
return {
	schemaVersion = 2,
	coins = 0,
	ownedTowers = { Archer = true },
	loadout = { "Archer", "", "", "", "" },
	processedPurchaseIds = {}, -- required by templates/ReceiptHandler.luau
	-- ...
}
```

- `Reconcile()` (ProfileStore) only adds missing keys. Renames, type
  changes and removals need a migration on load:

```lua
local MIGRATIONS: { [number]: (data: any) -> () } = {
	[1] = function(data) -- v1 -> v2: "gold" renamed to "coins"
		data.coins = (data.coins or 0) + (data.gold or 0)
		data.gold = nil
	end,
}
local function migrate(data: any)
	local version = data.schemaVersion or 1
	while MIGRATIONS[version] do
		MIGRATIONS[version](data)
		version += 1
	end
	data.schemaVersion = version
end
```

- Validate types defensively when reading old data (this repo's
  `PlayerProgress.coerce` is a good example of that habit).
- Store only what you need; derive the rest. Use sets (`{ Archer = true }`)
  for ownership and arrays for ordered data. Avoid mixed tables.
- Never store Instances, functions, or Vector3/CFrame directly — convert to
  numbers/strings/tables.

## 6. Purchases and data

Developer product grants must be written into the player's saved data
together with the `PurchaseId` so retries never double-grant. Use
`templates/ReceiptHandler.luau`. With ProfileStore, its `saveNow` adapter
follows ProfileStore's documented "PurchaseId cache" pattern:

```lua
local function saveNow(userId: number, purchaseId: string): boolean
	local player = Players:GetPlayerByUserId(userId)
	local profile = player and Profiles[player]
	if profile == nil then
		return false
	end
	local function saved(): boolean
		local ids = profile.LastSavedData.processedPurchaseIds
		return ids ~= nil and table.find(ids, purchaseId) ~= nil
	end
	while profile:IsActive() do
		if saved() then
			return true
		end
		local before = profile.LastSavedData
		profile:Save()
		if profile.LastSavedData == before then
			profile.OnAfterSave:Wait()
		end
		if saved() then
			return true
		end
		task.wait(10)
	end
	return false
end

local function waitForData(userId: number): any
	local player = Players:GetPlayerByUserId(userId)
	while player and player.Parent == Players do
		local profile = Profiles[player]
		if profile and profile:IsActive() then
			return profile.Data
		end
		task.wait()
	end
	return nil
end
```

Game passes don't need saving (ownership comes from
`MarketplaceService:UserOwnsGamePassAsync`), but you may cache grants in
memory for the session.

## 7. Leaderboards, global state, cross-server

- **OrderedDataStore** for leaderboards (`GetSortedAsync(false, 50)`),
  integer values only. Update at match end, not continuously; refresh the
  board display every few minutes with jitter.
- **MemoryStoreService** for fast, expiring, cross-server data:
  matchmaking queues (`MemoryStoreQueue`), party/session info, live event
  state (`MemoryStoreHashMap`, `MemoryStoreSortedMap`). Data expires
  (TTL), doesn't count toward data store storage.
- **MessagingService** for cross-server broadcasts (announcements, global
  events, "player X's data was requested elsewhere" — ProfileStore uses it).
- **ConfigService** (`GetConfigAsync()`, `GetConfigForPlayerAsync(player)`)
  for tunable values/feature flags editable in Creator Hub without
  republishing; supports targeting and experiments.
- Shared rarely-changing data read by every server: shard reads across
  several keys if one key gets read-throttled.

## 8. Studio testing

- DataStores in Studio need **Game Settings → Security → Enable Studio
  Access to API Services** on a *published* place. They hit the real
  (production) data stores — use a separate store name in Studio (e.g.
  suffix `_Studio`) or `ProfileStore.Mock`, so tests don't touch live data.
- Wrap all calls in `pcall`; when access is unavailable, fall back to an
  in-memory store and say so in the output (this repo's `PlayerProgress`
  does this).
- Test: join, earn, leave, rejoin; two quick server hops; shutdown during
  autosave; purchase while saving fails (simulate by forcing `saveNow` to
  return false).

## 9. Operations: observability, RTBF, Extended Services

- **Data Stores Manager** (Creator Hub): inspect/edit keys, storage usage,
  estimated cost; **Observability dashboard** for request/error rates.
  Configure alerts.
- **Right to be forgotten**: use static key patterns (`Player_<UserId>`) so
  Roblox's automated RTBF deletion templates can find the data, or handle
  the erasure webhook. `profile:AddUserId()` records the association.
- If legitimate usage exceeds default quotas, Roblox **Extended Services**
  lets you buy more DataStore access/storage. Reduce waste first.
- Open Cloud data store APIs (and the Data Stores Batch Processor CLI)
  share the experience budget with game servers — rate-limit scripts.
