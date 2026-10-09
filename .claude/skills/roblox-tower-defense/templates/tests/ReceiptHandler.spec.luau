--!strict
local T = require("./TestKit")
local ReceiptHandler = T.load(T.TEMPLATES .. "/ReceiptHandler.luau")

T.section("ReceiptHandler")

local GEMS = 1001
local BROKEN = 1002

local function setup(saveResults: { boolean }?)
	local data = { gems = 0, processedPurchaseIds = {} :: { string } }
	local saves = 0
	local loaded = true
	local process = ReceiptHandler.new({
		waitForData = function(_userId)
			return if loaded then data else nil
		end,
		saveNow = function(_userId, purchaseId)
			assert(type(purchaseId) == "string", "saveNow receives the PurchaseId")
			saves += 1
			if saveResults and saveResults[saves] ~= nil then
				return saveResults[saves]
			end
			return true
		end,
		products = {
			[GEMS] = function(d)
				d.gems += 100
			end,
			[BROKEN] = function(_d)
				error("boom")
			end,
		},
		historyLimit = 3,
	})
	return process,
		data,
		function()
			return saves
		end,
		function(value: boolean)
			loaded = value
		end
end

local function receipt(purchaseId: string, productId: number?): any
	return { PurchaseId = purchaseId, PlayerId = 1, ProductId = productId or GEMS }
end

T.test("grants, records the PurchaseId and saves", function()
	local process, data, saves = setup()
	T.eq(process(receipt("a")), "PurchaseGranted")
	T.eq(data.gems, 100)
	T.eq(data.processedPurchaseIds[1], "a")
	T.eq(saves(), 1)
end)

T.test("a re-delivered receipt is not granted twice", function()
	local process, data = setup()
	process(receipt("a"))
	T.eq(process(receipt("a")), "PurchaseGranted")
	T.eq(data.gems, 100)
end)

T.test("save failure -> NotProcessedYet, retry later acknowledges without double grant", function()
	local process, data = setup({ false, true })
	T.eq(process(receipt("a")), "NotProcessedYet")
	T.eq(data.gems, 100, "granted in memory for this session")
	T.eq(process(receipt("a")), "PurchaseGranted")
	T.eq(data.gems, 100, "not granted again")
end)

T.test("data not loaded -> NotProcessedYet and nothing granted", function()
	local process, data, _, setLoaded = setup()
	setLoaded(false)
	T.eq(process(receipt("a")), "NotProcessedYet")
	T.eq(data.gems, 0)
end)

T.test("unknown product -> NotProcessedYet", function()
	local process = setup()
	T.eq(process(receipt("a", 9999)), "NotProcessedYet")
end)

T.test("a grant that errors is not recorded", function()
	local process, data = setup()
	T.eq(process(receipt("x", BROKEN)), "NotProcessedYet")
	T.eq(#data.processedPurchaseIds, 0)
end)

T.test("history is trimmed to historyLimit (oldest first)", function()
	local process, data = setup()
	for _, id in { "a", "b", "c", "d" } do
		process(receipt(id))
	end
	T.eq(#data.processedPurchaseIds, 3)
	T.eq(data.processedPurchaseIds[1], "b")
end)

return nil
