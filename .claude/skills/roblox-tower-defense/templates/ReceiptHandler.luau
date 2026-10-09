--!strict
-- ReceiptHandler — an idempotent MarketplaceService.ProcessReceipt for
-- Developer Products (currency packs, revives, rewarded-ad rewards...).
--
-- Follows the flow Roblox documents for safe purchase handling:
--   1. wait until the buyer's session-locked data is loaded on THIS server
--      (never grant into fallback/default data that will not be saved),
--   2. if this PurchaseId was already recorded, don't grant it again,
--   3. otherwise grant in memory and record the PurchaseId in the save,
--   4. save now; acknowledge (PurchaseGranted) only if the save succeeded.
-- Roblox re-delivers unacknowledged receipts when the player next joins or
-- buys again, and the same receipt can run on two servers at once, which is
-- why steps 1-2 need session-locked data (ProfileStore or equivalent).
--
-- Pure Luau with injected dependencies, so it is unit-testable under Lune.
--
-- Roblox wiring (ONE server Script; ProcessReceipt can only be set once):
--   local processReceipt = ReceiptHandler.new({
--       waitForData = PlayerData.waitForDataAsync, -- returns the live save table or nil
--       saveNow = PlayerData.saveNowAsync,         -- true once a save containing the id landed
--       products = {
--           [123456] = function(data) data.gems += 500 end,
--           [234567] = function(data) data.revives += 1 end,
--       },
--   })
--   MarketplaceService.ProcessReceipt = function(receiptInfo)
--       return Enum.ProductPurchaseDecision[processReceipt(receiptInfo)]
--   end

export type ReceiptInfo = {
	PurchaseId: string,
	PlayerId: number,
	ProductId: number,
	CurrencySpent: number?,
	PlaceIdWherePurchased: number?,
	ProductPurchaseChannel: any?, -- Enum.ProductPurchaseChannel (AdReward for rewarded video)
}

export type Decision = "PurchaseGranted" | "NotProcessedYet"

-- The part of the player's save this module needs. Your save table must
-- contain `processedPurchaseIds = {}` and persist it like any other field.
export type SaveData = { processedPurchaseIds: { string } }

export type Options = {
	-- Yields until the player's data is loaded and session-locked on this
	-- server. Return the SAME table your save routine writes, or nil if the
	-- player left or their data failed to load.
	waitForData: (userId: number) -> any,
	-- Saves the player's data now and returns true only once a save that
	-- includes `purchaseId` is confirmed (with ProfileStore: call
	-- profile:Save() and check profile.LastSavedData — see
	-- references/data-persistence.md). May yield.
	saveNow: (userId: number, purchaseId: string) -> boolean,
	-- ProductId -> grant function. Mutate `data` in memory only: no yielding,
	-- no DataStore calls. Keep it simple enough that it cannot error halfway.
	products: { [number]: (data: any, receipt: ReceiptInfo) -> () },
	-- How many recent PurchaseIds to remember per player (default 100).
	historyLimit: number?,
}

local ReceiptHandler = {}

function ReceiptHandler.new(options: Options): (ReceiptInfo) -> Decision
	local historyLimit = options.historyLimit or 100

	return function(receipt: ReceiptInfo): Decision
		local grant = options.products[receipt.ProductId]
		if grant == nil then
			-- Unknown product: leave it unacknowledged so a newer server
			-- version that knows the product can still grant it.
			warn(`[ReceiptHandler] no handler for product {receipt.ProductId}`)
			return "NotProcessedYet"
		end

		local data = options.waitForData(receipt.PlayerId)
		if data == nil then
			return "NotProcessedYet"
		end
		local history: { string } = data.processedPurchaseIds
		assert(type(history) == "table", "save data is missing processedPurchaseIds")

		if table.find(history, receipt.PurchaseId) == nil then
			local failure = "unknown error"
			local granted = xpcall(grant, function(message)
				failure = tostring(message)
			end, data, receipt)
			if not granted then
				warn(`[ReceiptHandler] grant failed for product {receipt.ProductId}: {failure}`)
				return "NotProcessedYet"
			end
			table.insert(history, receipt.PurchaseId)
			while #history > historyLimit do
				table.remove(history, 1)
			end
		end

		-- Recorded now or by an earlier attempt whose save failed: either way
		-- it must be durably saved before Roblox is told it was granted.
		if options.saveNow(receipt.PlayerId, receipt.PurchaseId) then
			return "PurchaseGranted"
		end
		return "NotProcessedYet"
	end
end

return ReceiptHandler
