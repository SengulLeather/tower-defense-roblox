# Tower Defense Game Design (Roblox)

Design knowledge for the genre: what the successful Roblox TD games do, the
numbers to start from, and how to balance. Pair with
`td-architecture.md` for how to implement it.

## Contents
1. Genre shapes on Roblox
2. Loops: core, session, meta
3. Maps and paths
4. Enemies
5. Towers
6. Upgrades and selling
7. Targeting
8. Economy and balance math
9. Waves and difficulty
10. Co-op and social
11. Meta progression and retention
12. Monetization that fits TD
13. Onboarding (first 5 minutes)
14. Analytics to wire up from day one
15. Balance checklist

---

## 1. Genre shapes on Roblox

There are three proven shapes. Pick one before writing code, because it
decides the server architecture.

| Shape | Examples (for reference) | Structure | Notes |
|---|---|---|---|
| **Classic co-op TD** | Tower Defense Simulator, Tower Defense X, Toilet Tower Defense | Lobby place → queue/elevator → reserved match server (1–4+ players, shared map) → rewards → back to lobby | Towers bought permanently with currency, equipped in a small loadout (TDS uses 5 slots). Skins are the main cosmetic revenue. |
| **Anime / gacha unit TD** | All Star Tower Defense, Anime Vanguards, Ultimate Tower Defense | Same lobby/match split, but units come from summon banners with rarities, traits, evolutions, often trading | Highest revenue potential, but **paid random items rules apply** (odds disclosure, PolicyService restrictions, trading restrictions) — see `monetization-and-compliance.md`. |
| **Solo arena / casual TD** | Many smaller games; this repo's current design | One place, each player gets a private arena (offset in the same world) or the whole server shares one map | No teleports, easiest to build and test in Studio. Limits co-op and caps enemies per server because all arenas share one server's CPU/bandwidth. |

Common to all three: a **lobby/hub** where players see each other, show off
skins, open shops, and queue; a **match** with waves on a fixed path; a
**results screen** with rewards; and a **meta loop** (unlock/upgrade towers)
that brings players back.

## 2. Loops

- **Core loop (seconds):** enemies walk → towers shoot → cash comes in →
  place/upgrade towers → stronger defense. Every action should give feedback
  within 100 ms (sound, number popup, tower animation).
- **Session loop (5–25 min):** pick map + difficulty → survive N waves (or
  endless) → win/lose → rewards (coins, XP, items) → lobby. Typical Roblox
  match length is 10–20 minutes; offer a 2x speed option to shorten it.
- **Meta loop (days/weeks):** level up, unlock and buy towers, collect
  skins/units, complete daily/weekly quests, climb harder difficulties and
  leaderboards, seasonal events.

Design rule: a player must be able to **win their first match** and feel
progress (new tower/currency) within the first session.

## 3. Maps and paths

- Path is a polyline of waypoints from spawn to base. Total length of
  ~150–400 studs suits 5–10 minute waves at walking speeds of 6–16 studs/s.
- **Turns and U-bends** create spots where one tower covers the path twice —
  these are the "good spots" players learn. Include 2–4 per map.
- **Placement zones:** decide between a **grid** (simple validation,
  readable, mobile-friendly — this repo uses an 8-stud grid) or **free
  placement** on parts tagged `Placeable` with a footprint radius (TDS style;
  more expressive, needs overlap checks). Some towers can be placement-
  restricted (e.g., cliff-only snipers, water-only boats, path-only
  traps/mines).
- **Multiple paths/spawns** later in the game force splitting defense.
- Flying enemies may use a straight "air path" that ignores the ground path.
- Map count: launch with 2–3 maps across difficulties; each new map is cheap
  content for updates.
- Keep maps small and readable from an isometric camera on a phone screen.

## 4. Enemies

Each enemy definition: `hp`, `speed` (studs/s), `bounty` (cash on kill),
`leakDamage` (base HP lost when it reaches the end), optional `armor`/
resist, `flying`, `hidden`, abilities, model id, scale.

| Archetype | Purpose | Typical tuning |
|---|---|---|
| Normal | Baseline | speed 8, hp 1× |
| Fast / runner | Tests coverage near the end, punishes slow fire rate | speed 14–18, hp 0.4× |
| Tank / armored | Tests single-target DPS; armor punishes low-damage high-rate towers | speed 4–5, hp 4–8×, flat armor (damage − armor, min 1) or % resist |
| Swarm | Tests splash | many small, hp 0.2× each |
| Flying | Only anti-air towers can hit | ignores ground path, speed 10 |
| Hidden / stealth | Requires detection towers | hp 0.8×, invisible to non-detecting towers |
| Regen / healer | Punishes burst gaps | heals self/others over time |
| Shielded | Absorbs first X damage or one hit type | adds a second health bar |
| Splitter | Spawns children on death | children inherit path distance |
| Boss | Climax every 5–10 waves | hp 30–100×, slow, abilities (stun towers in radius, summon minions, speed aura), big leak damage or instant loss |

Introduce **one new mechanic at a time**, and show a "new enemy" card the
first time it appears (name, icon, what counters it).

## 5. Towers

Each tower definition: `cost`, `range`, `damage`, `fireRate` (shots/s) or
`cooldown`, `targets` (ground/flying/hidden detection), `placementLimit`,
`footprint`, optional `splashRadius`, `slow`, `dot`, `chain`, `buff`,
`income`, and an `upgrades` list.

| Role | Examples | Why it exists |
|---|---|---|
| Starter single-target | Archer, Scout, Soldier | Cheap, reliable early DPS |
| Splash / AOE | Cannon, Mortar, Demoman | Answers swarms |
| Sniper | Long range, slow, high damage | Answers tanks; covers the whole map |
| Rapid-fire | Minigunner | High DPS, weak vs armor |
| Control | Freezer, Frost spire | Slows/stuns; multiplies other towers' damage |
| DoT | Poison, Fire | Damage over time, good vs regen/swarm |
| Chain | Lightning/Storm | Hits several enemies in a row |
| Detection | Radar, Scout with detection | Unlocks hidden enemies for itself or nearby towers |
| Anti-air | Turret, Archer variants | Required for flying |
| Support / buff | Commander, DJ | +range/+fire rate/+damage aura; makes clusters strong |
| Economy / farm | Farm, Bank | Pays cash each wave instead of fighting; a real risk/reward decision |
| Spawner / summoner | Barracks | Sends units down the path backwards to fight |
| Hero / ability | Ability with cooldown | Active play for engaged players |

Rules of thumb:
- **Placement limits** (e.g., max 8 farms, max 2 heroes) stop degenerate
  spam and are much easier than perfect balance.
- **Cost efficiency** = DPS per cash. Cheap towers should be slightly *less*
  efficient than expensive ones at the same tier, otherwise players spam the
  cheapest tower forever.
- Every tower should have a **clear counter-situation** where it is the
  best choice. If two towers have no situation where each wins, merge them.
- Separate *ownership* (meta: you own the tower) from *placement* (match:
  you pay in-match cash to place it).

## 6. Upgrades and selling

- **Linear levels** (TDS style: L0→L5, each upgrade bought in-match) are
  easiest to balance and to show in UI. **Branching paths** (two or three
  specializations at higher tiers) add depth — consider them later.
- Each level should change something visible: model, stats, and ideally a
  new property at milestone levels (detection, splash, flying).
- Start with each upgrade costing about 1.5–2× the previous; final upgrades
  are expensive "goals".
- Show **exact before → after deltas** in the upgrade panel.
- **Sell refund** 50–70% of total spent (cost + upgrades). Some games refund
  100% during the wave a tower was placed in, to forgive misclicks.

## 7. Targeting

Offer per-tower targeting modes: **First** (furthest along path — default),
**Last**, **Strongest** (highest HP), **Weakest**, **Closest**, and
sometimes **Random**. "First" must use *distance along the path*, never
straight-line distance to the base. The `templates/Targeting.luau` module
implements these with sensible tie-breaks plus splash and chain helpers.

## 8. Economy and balance math

**Cash sources (in-match):** kill bounty, per-damage cash (some games pay
cash per damage dealt so support/slow towers aren't starved), wave-clear
bonus, farms/economy towers, early-start bonus (skipping the intermission).
**Sinks:** placing, upgrading, abilities. Selling returns part.

**Core balance equations** (put these in a spreadsheet or a Lune script):

```
towerDPS            = damage × fireRate × (1 + splashFactor) × hitChance
cashEfficiency      = towerDPS / totalCost
timeInRange(enemy)  = pathLengthInsideRange / enemySpeed          -- PathMath.timeInRange
damagePerEnemy      = towerDPS × timeInRange                       -- single-target
waveHP              = Σ enemyHP over the wave
requiredDPS(wave)   ≈ waveHP / (time the wave spends inside your kill zone)
waveIncome          = Σ bounties + clearBonus + farmIncome
```

Targets that make a good curve:
- The player can **almost** afford the build that handles the next wave:
  income per wave ≈ 80–100% of the extra DPS investment needed.
- Enemy HP grows faster than income (roughly 1.1–1.2× per wave in the
  midgame; linear early, steeper late), so later waves require smart
  upgrades and placement, not just more towers.
- Test every wave against a **reference build** (what an average player
  would have bought). If the reference build leaks badly, the wave is too
  hard; if it never takes damage across 5 waves, tighten.

Persisted meta currency (coins/gems) is a separate economy: track every
source and sink with `AnalyticsService:LogEconomyEvent` and watch the
balance curve, otherwise inflation makes everything trivial within weeks.

## 9. Waves and difficulty

- **Hand-author early waves** (1–10) to teach mechanics; generate later
  waves from a **threat budget**: `budget(w) = base × growth^w`, spend it on
  enemy types unlocked at that wave, then shuffle groups with a seeded RNG.
- **Rhythm:** spike → breather → spike. Boss or mini-boss every 5 or 10
  waves; a breather wave after each boss for players to rebuild.
- **Intermission** 5–15 s between waves with a visible timer; let players
  **skip/vote-skip** (with a small cash bonus) — veteran players hate
  waiting.
- **Wave preview:** show what's coming next (icons + counts), especially
  flying/hidden/boss.
- **Difficulty modes:** Easy / Normal / Hard / Insane / Nightmare with
  enemy HP and speed multipliers and *higher rewards* for higher modes.
  Gate harder modes behind level or clearing the previous mode.
- **Co-op scaling:** multiply enemy HP by roughly `1 + 0.5 × (players − 1)`
  (tune it) and split or share cash.
- **Endless mode:** after the final wave, keep scaling HP (and armor) with a
  leaderboard for highest wave — cheap long-term content.
- **Game speed:** 1x/2x (sometimes 3x via pass). Implement as a multiplier
  on simulation time, never by changing per-enemy speeds ad hoc.

## 10. Co-op and social

- **Cash model:** each player has their own cash (TDS) or a shared pool.
  Per-player cash prevents one player from spending everything, but
  income must be split fairly (bounty to everyone in range, or equally).
- **Tower ownership:** only the owner can upgrade/sell/retarget. Show the
  owner's name on hover.
- **Votes:** difficulty, map, skip wave, restart — majority with a timer.
- **Griefing:** cap towers per player; don't let one player block all good
  spots in shared maps (per-player placement limits help).
- **Parties/friends:** queue together; invite friends with
  `SocialService:PromptGameInvite`; show friends in lobby.
- Late joiners (if allowed) get starting cash scaled to the current wave.

## 11. Meta progression and retention

- Player level/XP from matches; unlock towers at levels; buy towers with
  coins. Loadout of N equipped towers (start with 3–5 slots; extra slot is
  a classic game pass).
- Tower **skins** (cosmetic; strong monetization without pay-to-win).
- **Daily rewards** and **daily/weekly quests** (win on map X, place 50
  freezers, reach wave 30 on Hard).
- **Badges** (`BadgeService:AwardBadgeAsync`) for milestones.
- **Leaderboards** (OrderedDataStore): highest endless wave, total wins.
- **Codes:** players expect social-media codes in Roblox TD games. Keep the
  code list on the server only, track redemptions per user in their save,
  rate-limit the redeem remote.
- **Live ops:** limited-time event maps, event currency and event-only
  towers/skins, seasonal battle pass. Plan a content cadence (new tower or
  map every 1–3 weeks is typical for top TD games). Use
  `ConfigService` to tune and toggle events without republishing.

## 12. Monetization that fits TD

| Product | Type | Notes |
|---|---|---|
| 2x/3x game speed, VIP (extra rewards, chat tag), extra loadout slot | Game passes | One-time; check ownership on join and on purchase |
| Premium tower | Game pass or currency | Keep it a *sidegrade* or modestly better; obvious pay-to-win ruins co-op lobbies |
| Coin/gem packs | Developer products | Repeatable; must go through an idempotent `ProcessReceipt` |
| Revive / extra base HP / instant wave skip in a match | Developer products | Contextual purchases at the moment of need convert well; don't make normal difficulty require them |
| Tower skins, crates | Currency / dev products | Crates with random results bought with Robux-bought currency are **paid random items** → disclose odds, handle `ArePaidRandomItemsRestricted` |
| Summon banners (anime TD) | Paid random items | Same rules; add pity carefully and show its effect numerically |
| Rewarded video ad (2x match rewards, free revive) | `AdService` | Opt-in only; the reward is granted through `ProcessReceipt` |
| Private servers | Built-in | Cheap, players like them for grinding |
| Season/battle pass | Dev product or subscription | Strong for retention when content cadence is reliable |

## 13. Onboarding (first 5 minutes)

- Drop new players straight into a short **tutorial match** (or the first
  real match on Easy) — don't make them read a lobby.
- Force exactly one action per step: place this tower *here* → start wave
  → upgrade it → change targeting. Arrows and highlights, minimal text,
  works on touch.
- Guarantee a win on the first match; give an immediate reward (a new
  tower) and show where to spend it.
- Track every step with `AnalyticsService:LogOnboardingFunnelStepEvent` and
  fix the biggest drop-off first.

## 14. Analytics to wire up from day one

- Onboarding funnel (steps above).
- Economy events for every coin/gem source and sink (`LogEconomyEvent`).
- Custom events: match start/finish (map, difficulty, wave reached, win/
  loss), tower placed/upgraded (tower id as custom field), leaks per wave.
- Progression events for level/wave milestones.
- Respect the rate limit (120 + 20 × CCU requests per minute per
  experience); batch counts into values (e.g., "EnemiesKilled", 37) instead
  of one event per kill.

## 15. Balance checklist

- [ ] Wave 1 can be beaten with the starting cash and one starter tower.
- [ ] Every tower has a situation where it is the best purchase.
- [ ] Cheapest tower is not the most cash-efficient.
- [ ] Each new enemy mechanic appears first in a forgiving wave.
- [ ] Boss waves are survivable by the reference build on the intended
      difficulty, with ~10–30% base HP lost.
- [ ] Income ≈ cost of the next "needed" upgrade per wave.
- [ ] 2x speed doesn't break anything (cooldowns, spawn intervals, abilities).
- [ ] Co-op scaling tested with 1, 2 and max players.
- [ ] Match length on Normal is within your target (e.g., 12–18 min).
- [ ] Endless mode HP curve eventually beats any build (no infinite runs).
