# Monetization, Publishing and Compliance

Sources: Roblox Creator Docs `production/monetization/*`,
`production/publishing/*`, `production/promotion/rewarded-video-ads.md`,
MarketplaceService/AdService/PolicyService API reference (October 2026).
Policies change often — when a decision depends on a number or rule here,
re-check the current Creator Hub page.

## Contents
1. Revenue options at a glance
2. Game passes
3. Developer products and ProcessReceipt
4. Rewarded video ads
5. Prices: don't hardcode them
6. Paid random items (crates, summons, gacha) — policy
7. PolicyService: per-user restrictions
8. Publishing requirements (2026)
9. Content, text and safety rules
10. Getting paid (DevEx)
11. Store-page basics

---

## 1. Revenue options at a glance

| Option | What | TD examples |
|---|---|---|
| Game pass | One-time purchase, permanent | 2x speed, VIP, extra loadout slot, premium tower |
| Developer product | Repeatable purchase | Coin/gem packs, revive, extra base HP, crate/summon currency |
| Subscription | Recurring monthly benefit | Monthly VIP with daily gems |
| Rewarded video ad | Player opts in to watch an ad, receives a developer product | 2x match rewards, free revive |
| Private servers | Paid private servers (price set in Creator Hub) | Grinding with friends |
| Engagement-based payouts | Robux from Roblox Premium members' playtime | Automatic |
| Immersive ads / ad integrations | Ads placed in the 3D world | Lobby billboards |
| Commerce products / avatar items | Physical or avatar items | Merch, UGC tower-themed accessories |

Shop (Creator Hub → Monetization → Shop) lists your passes and eligible
developer products in Roblox's built-in in-game Shop and can surface
**Listed** items outside your game (home page, search, after Robux
purchases). Cross-game pass/product sales are disabled since May 30, 2026
(use Robux transfers if you relied on them).

## 2. Game passes

- Create after the experience is published: Creator Hub → your game →
  Monetization → Passes. Copy the pass ID into a shared config module.
- Prompt from the client (or server):
  `MarketplaceService:PromptGamePassPurchase(player, passId)`.
- **Grant on the server**: on join check
  `MarketplaceService:UserOwnsGamePassAsync(player.UserId, passId)`
  (wrap in `pcall`; cache the result for the session) and also listen to
  `MarketplaceService.PromptGamePassPurchaseFinished` (server) to grant
  immediately after an in-game purchase — the ownership check result is
  cached and may not reflect a purchase made seconds ago.
- Never treat a client message ("I bought it") as proof.

```lua
local ownedPasses: { [Player]: { [number]: boolean } } = {}

local function ownsPass(player: Player, passId: number): boolean
	local cache = ownedPasses[player]
	if cache and cache[passId] ~= nil then
		return cache[passId]
	end
	local ok, owns = pcall(function()
		return MarketplaceService:UserOwnsGamePassAsync(player.UserId, passId)
	end)
	if ok then
		ownedPasses[player] = ownedPasses[player] or {}
		ownedPasses[player][passId] = owns
		return owns
	end
	return false -- on error, deny for now; retry later rather than caching false
end

MarketplaceService.PromptGamePassPurchaseFinished:Connect(function(player, passId, purchased)
	if purchased then
		ownedPasses[player] = ownedPasses[player] or {}
		ownedPasses[player][passId] = true
		Perks.apply(player, passId)
	end
end)
Players.PlayerRemoving:Connect(function(player)
	ownedPasses[player] = nil
end)
```

## 3. Developer products and ProcessReceipt

Facts from the `MarketplaceService.ProcessReceipt` reference:
- Set the callback **once**, in **one** server Script; it handles every
  developer product (including rewarded-ad rewards).
- Called for unresolved purchases when a purchase completes, when a
  purchase prompt succeeds, and **when the user joins a server**. No
  time-based retries; no timeout (it may yield as long as the server runs).
- Return `Enum.ProductPurchaseDecision.PurchaseGranted` only after the
  grant is durably saved; otherwise `NotProcessedYet` (Roblox asks again
  next time the player joins or buys).
- The same purchase can run on **two servers at once** (player rejoined
  before the first callback returned) → you need session-locked data and a
  `PurchaseId` record.
- Multiple pending purchases are delivered in non-deterministic order.
- If you never set `ProcessReceipt`, receipts are auto-acknowledged (lost).
- `receiptInfo`: `PurchaseId`, `PlayerId`, `ProductId`,
  `PlaceIdWherePurchased`, `CurrencySpent` (actual price paid, even
  during price tests), `CurrencyType`, `ProductPurchaseChannel` (e.g.
  `AdReward`).
- Do **not** use `PromptProductPurchaseFinished` to grant — it doesn't mean
  the purchase succeeded.
- Roblox monitors your ProcessReceipt correctness for **Listed** products;
  flagged products stop being shown outside the game until fixed (banner in
  Creator Hub → Monetization → Shop).

Implementation: `templates/ReceiptHandler.luau` (PurchaseId history +
save-before-ack), wired to your data layer as shown in
`data-persistence.md` §6.

UI flow: client calls `MarketplaceService:PromptProductPurchase(player,
productId)`; the server's ProcessReceipt grants; the server then pushes
the new balance to the client. Disable buy buttons if the player's data
failed to load (purchases can't be saved).

## 4. Rewarded video ads

- Eligibility (creator/game): 13+, ID-verified account, public game with
  ≥ 2,000 unique visitors per month; enable in Creator Hub.
- Rewards must be **developer products** (not Robux, not randomized items);
  Roblox suggests rewards worth roughly 3–10 Robux.
- Must be opt-in and clearly disclosed ("Watch an ad to get 2x rewards").
  Pause danger while the ad plays or only offer it in safe places (lobby,
  results screen) — for TD: results screen "double rewards", or a revive
  offer at defeat.
- Client: `AdService:GetAdAvailabilityNowAsync(Enum.AdFormat.RewardedVideo)`
  right before showing the button (call it when the menu opens).
- Server: `AdService:ShowRewardedVideoAdAsync(player,
  AdService:CreateAdRewardFromDevProductId(productId), placementId)`.
  **Grant in ProcessReceipt** (`ProductPurchaseChannel == AdReward`), not
  from the returned `ShowAdResult`.
- `AdService:ShowVideoAd` is decommissioned.

## 5. Prices: don't hardcode them

Price optimization and regional pricing (both part of **Managed pricing**)
can show different players different prices. Fetch prices at runtime on
the **client** with `MarketplaceService:GetProductInfoAsync(id,
Enum.InfoType.Product / GamePass)` (the old `GetProductInfo` is
deprecated) and display `PriceInRobux`. Several concurrent
`GetProductInfoAsync` calls are batched automatically (transparent
batching) — spawn them in parallel. Keep IDs (not prices) in code.

Personalize store ordering with `MarketplaceService:RankProductsAsync`
(strict rate limit; call once at join) and `RecommendTopProductsAsync`.

## 6. Paid random items (crates, summons, gacha) — policy

Applies to random outcomes bought **directly or indirectly** with Robux —
including in-game currency that can be bought with Robux, keys, tickets,
rerolls. Types: capsules (crates, eggs, summons, wheel spins), enhancement
(upgrade with a chance to fail), combination (fuse for a chance at better),
probability modifiers (luck boosts, **pity systems**, rate-up).

Requirements:
- Before purchase, show **all possible outcomes and their numerical odds as
  percentages** that sum to exactly 100% (long decimals may be rounded with
  a disclaimer that totals may not equal 100%).
- Too many outcomes? A clickable pop-up with a descriptive label ("Odds",
  "Details") — an unlabeled (i) icon is not enough. Many items with equal
  odds can share one line ("Odds for each item listed below: X%").
- If an outcome can only be obtained once, update the remaining odds for
  that user.
- Odds modifiers must state their effect numerically, and the displayed odds
  must update while the modifier is active.
- Free random rewards (not bought with Robux or Robux-bought currency)
  don't need disclosure.

## 7. PolicyService: per-user restrictions

`PolicyService:GetPolicyInfoForPlayerAsync(player)` (server, pcall, cache
per session) returns, among others:
- `ArePaidRandomItemsRestricted` — if true, this player must not be able to
  buy random items with Robux or Robux-bought currency. Allowed treatments:
  earnable free path, pre-determined disclosed order, direct purchase of
  the specific item (priced at expected value), hiding the item, blocking
  with a message ("unavailable in your region"), or keeping the player out
  of that area.
- `IsPaidItemTradingAllowed` — if false, this player must not trade items
  obtained with Robux/paid currency (including paid random items).
- Other flags (e.g., restrictions on external links/social references) —
  check them before showing social media codes or links.

## 8. Publishing requirements (2026)

New games start **Private** (only you/editors). "Playtest" permission no
longer grants access to Private games; set Audience → **Limited →
Playtesters** (requires meeting the Public/Limited requirements). Up to 5
never-public games can be made public per day.

| To reach | Creator requirements |
|---|---|
| **16+ and Trusted Friends** | Account in good standing and ≥ 2 days old; age check (facial age estimation or government ID); complete the **Maturity & Compliance Questionnaire** |
| **All ages** incl. **Roblox Kids** (5–8) and **Roblox Select** (9–15) | All of the above, plus: verified account (facial age estimation if under 18, government ID if 18+); **2-Step Verification**; an active Roblox Plus or Premium subscription for 2 consecutive months **or** a one-time refundable 1,000 Robux publishing fee per game; and the game must pass **evaluation** |

Evaluation: the game first runs for age-checked 16+ users; it becomes
eligible for Kids/Select after **250 unique plays by "highly engaged"
age-checked users within 60 days** plus a safety review. Track it on the
**Audience Reach** dashboard. A refundable **expedited review fee of 50,000
Robux** exists for timed launches. Kids accounts see Minimal/Mild content
only; Select sees up to Moderate.

Practical consequences for a TD game aimed at kids:
- Keep violence cartoony (no blood/gore), so the questionnaire yields
  Minimal/Mild.
- Plan for a launch period where only 16+ players can find the game.
- Do the account verification and 2FA early; they block publishing.

## 9. Content, text and safety rules

- Fill in the Maturity & Compliance Questionnaire honestly; update it when
  content changes.
- Filter all user-entered text shown to other users with
  `TextService:FilterStringAsync` (+ `GetNonChatStringForBroadcastAsync` /
  `GetNonChatStringForUserAsync`). Use `TextChatService` for chat.
- No off-platform links, real-money trading, or pressuring purchase
  language aimed at kids; follow Roblox's Advertising Standards for ads and
  "rewarded video" disclosures.
- Respect IP: no copyrighted characters (anime TDs use "inspired-by"
  designs or licensed IP via Roblox's IP licensing program).
- Localize UI text (`LocalizationService`, automatic translation in
  Creator Hub) — a large share of players don't read English.
- Right to be forgotten: use `Player_<UserId>` keys / `AddUserId` so data
  deletion works (see `data-persistence.md`).

## 10. Getting paid (DevEx)

- DevEx standard rate: **$0.0038 per Earned Robux** (since Sept 5, 2025;
  older balances cash out at $0.0035 first). Minimum 30,000 Earned Robux,
  13+, verified email, account in good standing.
- U.S. 18+ rate: **$0.0054** for eligible Earned Robux from purchases by
  age-verified U.S. players 18+ in eligible games (criteria include
  R15/human-form character requirements — read `18-plus-devex-rate`).
- Earned Robux from passes/products is after Roblox's marketplace fee; check
  the Creator Hub sales reports for actual net amounts.

## 11. Store-page basics

- Icon 512×512, thumbnails (16:9) that show real gameplay; a short video.
- Description: one-line pitch first ("Build towers, survive 50 waves with
  friends"), then features, update log, social links only where policy
  allows.
- Genre: **Tower Defense** is an official experience genre — set it.
- Max players, server fill, and allowed devices (phone/tablet/console/VR)
  in Places/Settings; test controller support before enabling console.
