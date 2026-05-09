local mq         = require('mq')
local PackageMan = require('mq.PackageMan')
PackageMan.Require('lsqlite3')

local ICONS    = require('mq.Icons')
local BazaarDB = require('bazaar_db')
local ImGui    = require('ImGui')
local ImPlot   = require('ImPlot')

require('baz_utils')

math.randomseed(os.time())

local animItems = mq.FindTextureAnimation("A_DragItem")

function GetTableEntry(t, v)
    --printf("Serach %s for %s", t, v)
    if not t then return false, 0 end
    for idx, tv in pairs(t) do
        --printf("%s == %s", v, tv.item)
        if tv.item == v then return true, idx end
    end
    return false, 0
end

function Tooltip(desc)
    ImGui.SameLine()
    if ImGui.IsItemHovered() then
        ImGui.BeginTooltip()
        ImGui.PushTextWrapPos(ImGui.GetFontSize() * 25.0)
        ImGui.Text(desc)
        ImGui.PopTextWrapPos()
        ImGui.EndTooltip()
    end
end

function Tokenize(inputStr, sep)
    if sep == nil then
        sep = "|"
    end

    local t = {}
    if string.find(tostring(inputStr), "^#") == nil then
        for str in string.gmatch(tostring(inputStr), "([^" .. sep .. "]+)") do
            if string.find(str, "^#") == nil then
                table.insert(t, str)
            end
        end
    end

    return t
end

-- Search for Items
local function searchFound(num, itemName)
    printf("Found %d of %s!", num, itemName)
end

mq.event("searchFound", "There are #1# Buy Lines that match the search string '#2#'.", searchFound)

CharConfig = mq.TLO.Me.CleanName()
ServerName = mq.TLO.EverQuest.Server():gsub(" ", "")

local openGUI = true
local shouldDrawGUI = true

local openHistoryGUI = false
local shouldDrawHistoryGUI = false

local bgOpacity = 1.0
local doItemScan = false
local currentItemIdx = 0
local currentScanItem = nil

local scanItem = nil
local pauseScan = false

local itemDB

local itemList = {}
local allKnownItems = {}
local totalItems = 0

local settings = {}

local config_pickle_path = mq.configDir .. '/bazaar/' .. ServerName .. '_' .. CharConfig .. '.lua'

local newAuctionPopup = "new_auction_popup"
local lastAuction = 0
local AuctionText = {}
local pauseAuctioning = true

local popupAuctionCost = ""
local popupAuctionItem = ""

local cachedPriceHistory = {}

local openPopup = false

-- first scan should be about 2 seconds after startup.
local lastFullScan = 0

local BAZAAR_ACTION_PAUSE_MS = 1000
local BAZAAR_MIN_ITEM_PAUSE_MS = 1500
local BAZAAR_MAX_ITEM_PAUSE_MS = 6000
local BAZAAR_BREATHER_EVERY = 5
local BAZAAR_BREATHER_MS = 8000
local lastBazaarQueryDuration = 0

local function bazaarActionPause()
    -- Keep Bazaar UI interactions from firing back-to-back too tightly.
    mq.delay(BAZAAR_ACTION_PAUSE_MS)
end

local function bazaarItemPause(itemsScanned)
    -- Pace the scan from Bazaar's actual response time instead of a rigid loop.
    local responsePause = math.floor(lastBazaarQueryDuration * 500)
    local pauseMs = BAZAAR_MIN_ITEM_PAUSE_MS + responsePause
    pauseMs = math.min(BAZAAR_MAX_ITEM_PAUSE_MS, pauseMs)

    if itemsScanned and itemsScanned > 0 and itemsScanned % BAZAAR_BREATHER_EVERY == 0 then
        print("\ayTaking a short breather before the next batch...")
        pauseMs = pauseMs + BAZAAR_BREATHER_MS
    end

    mq.delay(pauseMs)
end

local function clearCachedHistory()
    cachedPriceHistory.max_x = 0
    cachedPriceHistory.min_x = os.time()
    cachedPriceHistory.max_y = 0
    cachedPriceHistory.labels = {}
    cachedPriceHistory.xs = {}
    cachedPriceHistory.ys = {}
    cachedPriceHistory.avg_xs = {}
    cachedPriceHistory.avg_ys = {}
end

local function cacheItems()
    local itemCount = 0
    local line = ""
    local lineCount = 1

    if (settings and #AuctionText == 0) then
        for _, v in pairs(settings.AuctionItems or {}) do
            if line:len() > 0 then line = line .. " | " end
            ---@diagnostic disable-next-line: undefined-field
            line = line .. mq.TLO.LinkDB("=" .. v.item)() .. " " .. v.cost
            itemCount = itemCount + 1
            if itemCount == 4 then
                print(string.format("Cached[%d]: %s", lineCount, line))
                AuctionText[lineCount] = line
                lineCount = lineCount + 1
                line = ""
                itemCount = 0
            end
        end
    end

    if line:len() > 0 then
        print(string.format("Cached[%d]: %s", lineCount, line))
        AuctionText[lineCount] = line
    end
end

local function SaveSettings(clearItems)
    mq.pickle(config_pickle_path, settings)

    if clearItems then
        AuctionText = {}
        cacheItems()
    end
end

local DefaultConfig = {
    ['Timer']                = { Default = 5, Tooltip = "Time in minutes between manual auctions", },
    ['Channels']             = { Default = "auc", Tooltip = "| Separated list of channels to auction to. ex: auc|6|7", },
    ['UnderCutPercent']      = { Default = 1, Tooltip = "Minimum undercut percent", },
    ['UnderCutPercentMax']   = { Default = 1, Tooltip = "Maximum undercut percent", },
    ['UnderCutOOM']          = { Default = 0, Tooltip = "Round Undercut to Order of Magnitude X", },
    ['RaiseUnderpriced']     = { Default = false, Tooltip = "Raise prices that are far below the calculated target price.", },
    ['RaiseUnderpricedPercent'] = { Default = 10, Tooltip = "Only raise prices when current price is this percent or more below target.", },
    ['DefaultPrice']         = { Default = 2000000, Tooltip = "Default price", },
    ['DontUndercut']         = { Default = CharConfig .. "|", Tooltip = "| Separated list of traders not to undercut. ex: Bob|Derple", },
    ['AutoUpdatePrices']     = { Default = true, Tooltip = "Automatically update trader prices to the calculated target price after scanning.", },
    ['AuctionItems']         = { Default = {}, },
    ['scanTimer']            = { Default = 30, },
    ['DisabledAuctionItems'] = { Default = {}, },
}

local function LoadSettings()
    CharConfig = mq.TLO.Me.CleanName()
    local needSave = false

    local config, err = loadfile(config_pickle_path)
    if not config or err then
        printf("Failed to Load Config: %s", config_pickle_path)
        needSave = true
        settings = {}
    else
        settings = config()
    end

    for k, v in pairs(DefaultConfig) do
        if settings[k] == nil then settings[k] = v.Default end
    end

    lastFullScan = os.time() - ((60 * settings.scanTimer) - 2)

    if needSave then SaveSettings(true) end

    -- open the items db
    local items_db_file = 'items.db'
    itemDB = BazaarDB.new(mq.configDir .. '/bazaar/' .. items_db_file)
    itemDB:setupDB()

    allKnownItems = itemDB:getAllItems()

    return true
end

----------------------------------------------------------------|
-- Manage /trader window
--------------------------------------------------------------**|
local function traderWindowControl(status)
    if status == "Open" or status == "On" or status == "Off" then
        if not mq.TLO.Window("BazaarWnd").Open() then
            print("\ayOpening Trader window...")
            mq.cmd("/trader")
        end

        if status == "On" then
            if mq.TLO.Window("BazaarWnd").Child("BZW_Start_Button") then
                mq.TLO.Window("BazaarWnd").Child("BZW_Start_Button").LeftMouseUp()
                print("\aySetting Trader Window to Start Trading...")
            end
        end

        if status == "Off" then
            if mq.TLO.Window("BazaarWnd").Child("BZW_End_Button") then
                mq.TLO.Window("BazaarWnd").Child("BZW_End_Button").LeftMouseUp()
                print("\aySetting Trader Window to Stop Trading...")
            end
        end
    end

    if status == "Close" then
        mq.cmd("/windowstate BazaarWnd Close")
        print("\amClosed Trader Window...")
    end
end

local function shouldUndercut(trader)
    local tokens = Tokenize(settings.DontUndercut, "|")

    for _, t in ipairs(tokens) do
        if t == trader then return false end
    end

    return true
end

local setItem = nil
local setPrice = 2000000
local setAsyncItemFound = false

local function setTraderPrice(itemName, price)
    print("Setting item \at" .. itemName .. "\ax to \ay" .. price)
    setItem = itemName
    setPrice = price
    setAsyncItemFound = false
end

local asyncSetTraderPriceState = 0
local asyncSetTraderPriceTiming = 0

local function refreshItemInSlot(slot)
    local currentItem     = mq.TLO.Window("BazaarWnd").Child(string.format("BZR_BazaarSlot%d", slot)).Tooltip()
    local currentPrice    = mq.TLO.Window("BazaarWnd").Child("BZW_Money0").Text()
    local itemRef         = mq.TLO.FindItem(string.format("=%s", currentItem))
    local currentItemIcon = itemRef.Icon()

    if currentItem ~= nil and currentItem ~= "" then
        local itemDBId = itemDB:getItemDBId(currentItem)

        local listedDate = itemDB:getItemListedTime(itemDBId)
        if not listedDate then
            itemDB:cacheItemListedTime(itemDBId, currentPrice or 0, os.time())
            listedDate = os.time()
        end

        itemList[currentItem] = itemList[currentItem] or {}
        itemList[currentItem]["CurrentPrice"] = tonumber(currentPrice) or 0
        itemList[currentItem]["slot"] = slot
        itemList[currentItem]["IconID"] = currentItemIcon
        itemList[currentItem]["ItemRef"] = itemRef
        itemList[currentItem]["DBID"] = itemDBId
        itemList[currentItem]["ListedDate"] = listedDate

        print(string.format("Set price of \at%s\ax to \ay%d", currentItem, currentPrice))
    end
end

local function refreshItemSlot(slot)
    local currentItem  = mq.TLO.Window("BazaarWnd").Child(string.format("BZR_BazaarSlot%d", slot)).Tooltip()
    local currentPrice = mq.TLO.Window("BazaarWnd").Child("BZW_Money0").Text()

    if currentItem ~= nil and currentItem ~= "" then
        itemList[currentItem] = itemList[currentItem] or {}
        if not itemList[currentItem]["CurrentPrice"] then
            itemList[currentItem] = {}
            itemList[currentItem]["CurrentPrice"] = tonumber(currentPrice) or 0
        end

        itemList[currentItem]["slot"] = slot

        if currentItem == setItem then
            setAsyncItemFound = true
        end
    end
end

local function refreshLocalSlots()
    traderWindowControl("Open")

    for slot = 0, 144 do
        ---@diagnostic disable-next-line: undefined-field
        if (mq.TLO.Window("BazaarWnd").Child(string.format("BZR_BazaarSlot%d", slot)).Tooltip() or ""):len() == 0 then break end
        mq.TLO.Window("BazaarWnd").Child(string.format("BZR_BazaarSlot%d", slot)).LeftMouseUp()
        ---@diagnostic disable-next-line: undefined-field
        while not mq.TLO.Window("BazaarWnd").Child(string.format("BZR_BazaarSlot%d", slot)).InvSlot.Selected() do
            mq.delay(1)
        end
        refreshItemSlot(slot)
    end
end

local function refreshLocalItems()
    traderWindowControl("Open")

    for slot = 0, 144 do
        ---@diagnostic disable-next-line: undefined-field
        if (mq.TLO.Window("BazaarWnd").Child(string.format("BZR_BazaarSlot%d", slot)).Tooltip() or ""):len() == 0 then break end
        mq.TLO.Window("BazaarWnd").Child(string.format("BZR_BazaarSlot%d", slot)).LeftMouseUp()
        ---@diagnostic disable-next-line: undefined-field
        while not mq.TLO.Window("BazaarWnd").Child(string.format("BZR_BazaarSlot%d", slot)).InvSlot.Selected() do
            mq.delay(1)
        end
        refreshItemInSlot(slot)
    end

    totalItems = GetTableSize(itemList)
end

local function asyncSetTraderPrice()
    if setItem == nil then return end

    if asyncSetTraderPriceState == 0 then
        refreshLocalSlots()
        if not setAsyncItemFound then
            print(string.format("Item \ar%s\ax no longer found -- Removing.", setItem))
            if itemList[setItem] then
                itemList[setItem] = nil
            end
            setItem = nil
            asyncSetTraderPriceState = 0

            totalItems = GetTableSize(itemList)
            return
        end
        mq.TLO.Window("BazaarWnd").Child(string.format("BZR_BazaarSlot%d", itemList[setItem]["slot"])).LeftMouseUp()
        asyncSetTraderPriceTiming = os.clock() + 1
        asyncSetTraderPriceState = 1
        return
    end

    if asyncSetTraderPriceState == 1 and os.clock() >= asyncSetTraderPriceTiming then
        -- wait until we are acutally selected.
        ---@diagnostic disable-next-line: undefined-field
        if not mq.TLO.Window("BazaarWnd").Child(string.format("BZR_BazaarSlot%d", itemList[setItem]["slot"])).InvSlot.Selected() then return end

        mq.TLO.Window("BazaarWnd").Child("BZW_Money0").LeftMouseUp()
        asyncSetTraderPriceTiming = os.clock() + 0.1
        asyncSetTraderPriceState = 2
        return
    end

    if asyncSetTraderPriceState == 2 and os.clock() >= asyncSetTraderPriceTiming then
        mq.cmd(string.format("/notify QuantityWnd QTYW_Slider newvalue %d", setPrice))
        mq.cmd("/notify QuantityWnd QTYW_Accept_Button leftmouseup")
        mq.cmd("/notify BazaarWnd BZW_SetPrice_Button leftmouseup")
        asyncSetTraderPriceTiming = os.clock() + 0.1
        asyncSetTraderPriceState = 3
    end

    if asyncSetTraderPriceState == 3 and os.clock() >= asyncSetTraderPriceTiming then
        mq.TLO.Window("BazaarWnd").Child("BZW_Add_Button").LeftMouseUp()
        asyncSetTraderPriceState = 0
        asyncSetTraderPriceTiming = 0
        scanItem = setItem
        itemList[scanItem]["LowestPrice"] = nil
        setItem = nil
        setPrice = 2000000
    end
end

local function waitForTraderPriceUpdate(itemName)
    local startTime = os.clock()
    local timeoutSeconds = 20

    while setItem ~= nil do
        asyncSetTraderPrice()
        mq.doevents()
        mq.delay(50)

        if os.clock() - startTime > timeoutSeconds then
            print(string.format("\arTimed out while updating trader price for \am%s", itemName))
            setItem = nil
            setPrice = 2000000
            asyncSetTraderPriceState = 0
            asyncSetTraderPriceTiming = 0
            return false
        end
    end

    return true
end

-------------------------------------------------------------|
-- Checks your /trader prices and updates if needed.
-----------------------------------------------------------**|

local function bazaarSearchWindowControl(status)
    if status == "Open" then
        if not mq.TLO.Window("BazaarSearchWnd").Open() then
            mq.cmd("/bazaar")
        end
    end

    if status == "Close" then
        if mq.TLO.Window("BazaarSearchWnd").Open() then
            mq.cmd("/windowstate BazaarSearchWnd Close")
        end
    end
end

local function calcTargetPrice(best, curr, trader)
    if curr == 0 and (best or 0) == 0 then
        return settings.DefaultPrice
    end

    if not shouldUndercut(trader) then
        return best
    end

    local ordMagDiff = 10 ^ settings.UnderCutOOM
    -- math.floor(math.abs(math.log((best > 0 and best or 1) / (settings.UnderCutOOM > 0 and 10 ^ settings.UnderCutOOM or 10), 10)))

    local minPercent = tonumber(settings.UnderCutPercent) or 0
    local maxPercent = tonumber(settings.UnderCutPercentMax) or minPercent
    if maxPercent < minPercent then
        minPercent, maxPercent = maxPercent, minPercent
    end
    local undercutPercent = minPercent
    if maxPercent > minPercent then
        undercutPercent = math.random(minPercent, maxPercent)
    end

    local newPrice = math.ceil((best or 0) - (undercutPercent / 100 * (best or 0)))

    if ordMagDiff <= best then
        newPrice = math.floor(newPrice / ordMagDiff) * ordMagDiff
    end

    if curr == 0 or curr >= (best or 0) then
        return newPrice
    end

    if settings.RaiseUnderpriced then
        local raiseThresholdPercent = tonumber(settings.RaiseUnderpricedPercent) or 0
        local raiseBelow = newPrice - ((raiseThresholdPercent / 100) * newPrice)
        if curr <= raiseBelow then
            return newPrice
        end
    end

    return curr
end

local function recalcTargetPrices()
    for _, itemData in pairs(itemList) do
        itemData["TargetPrice"] = calcTargetPrice((tonumber(itemData["CompetitivePrice"]) or 0),
            (tonumber(itemData["CurrentPrice"]) or -1), (itemData["CompetitiveTrader"] or "Unknown"))
    end
end

local function bazaarQuery(itemName)
    if not mq.TLO.Window("BazaarSearchWnd").Open() then
        bazaarSearchWindowControl("Open")
        mq.delay(1000, function() return mq.TLO.Window("BazaarSearchWnd").Open() end)
    end

    mq.TLO.Window("BazaarSearchWnd").Child("BZR_ItemNameInput").SetText(itemName)
    mq.delay(500, function() return mq.TLO.Window("BazaarSearchWnd").Child("BZR_ItemNameInput").Text() == itemName end)
    bazaarActionPause()

    if not mq.TLO.Window("BazaarSearchWnd").Child("BZR_QueryButton").Enabled() then
        print("\ayBazaar is still busy, skipping this search for now.")
        return false
    end

    mq.TLO.Window("BazaarSearchWnd").Child("BZR_QueryButton").LeftMouseUp()
    mq.delay(500, function() return not mq.TLO.Window("BazaarSearchWnd").Child("BZR_QueryButton").Enabled() end)

    local waitStart = os.clock()
    local lastStatus = waitStart
    local timeoutSeconds = 45
    repeat
        mq.delay(250)
        if os.clock() - waitStart > timeoutSeconds then
            print(string.format("\arBazaar query timed out after %d seconds: \am%s", timeoutSeconds, itemName))
            lastBazaarQueryDuration = timeoutSeconds
            return false
        end
        if os.clock() - lastStatus > 15 then
            print("\ayStill waiting on Bazaar results...")
            lastStatus = os.clock()
        end
        ---@diagnostic disable-next-line: undefined-field
    until mq.TLO.Window("BazaarSearchWnd").Child("BZR_QueryButton").Enabled()

    lastBazaarQueryDuration = os.clock() - waitStart
    return true
end

local function autoUpdateTraderPrice(itemName)
    if not settings.AutoUpdatePrices then return end

    local itemData = itemList[itemName]
    if not itemData then return end

    local currentPrice = tonumber(itemData["CurrentPrice"]) or 0
    local targetPrice = tonumber(itemData["TargetPrice"]) or 0

    if targetPrice <= 0 then return end
    if currentPrice == targetPrice then return end

    print(string.format("\ayAuto-updating \am%s\ay from \aw%d\ay to \ag%d", itemName, currentPrice, targetPrice))
    setTraderPrice(itemName, targetPrice)
    if waitForTraderPriceUpdate(itemName) then
        itemData["CurrentPrice"] = targetPrice
    end
end

local function searchBazaar(itemName)
    itemList[itemName] = itemList[itemName] or {}
    itemList[itemName]["LowestPrice"] = nil
    itemList[itemName]["Trader"] = nil
    itemList[itemName]["NextLowestPrice"] = nil
    itemList[itemName]["NextTrader"] = nil
    itemList[itemName]["CompetitivePrice"] = nil
    itemList[itemName]["CompetitiveTrader"] = nil
    itemList[itemName]["TargetPrice"] = nil

    bazaarSearchWindowControl("Open")

    mq.TLO.Window("BazaarSearchWnd").Child("BZR_Default").LeftMouseUp()
    mq.delay(500, function() return not mq.TLO.Window("BazaarSearchWnd").Child("BZR_Default").Checked() end)
    bazaarActionPause()

    if not bazaarQuery(itemName) then return end

    if not mq.TLO.Window("BazaarSearchWnd").Child("BZR_ItemList").List(1, 3) then
        print("\arSearch failed, trying 1 more time...")
        bazaarActionPause()
        if not bazaarQuery(itemName) then return end
    end

    local startSearchTime = os.clock()
    local found = 0
    while os.clock() - startSearchTime <= 30 and found == 0 do
        mq.delay(5)
        found = mq.TLO.Window("BazaarSearchWnd").Child("BZR_ItemList").List(1, 3)()
    end

    local allSellers = {}
    local eligibleSellers = {}

    for searchResult = 1, 255 do
        local count = mq.TLO.Window("BazaarSearchWnd").Child("BZR_ItemList").List(searchResult, 3)()
        if count and count ~= "NULL" then
            local result = mq.TLO.Window("BazaarSearchWnd").Child("BZR_ItemList").List(searchResult, 2)()
            if result == itemName then
                local workingValue = NoComma(mq.TLO.Window("BazaarSearchWnd").Child("BZR_ItemList").List(searchResult, 4)())
                local trader = mq.TLO.Window("BazaarSearchWnd").Child("BZR_ItemList").List(searchResult, 8)()
                workingValue = tonumber(workingValue)

                if workingValue and trader then
                    print(string.format("Found seller: \am%s \axwith price: \ag%d", trader, workingValue))

                    itemDB:cacheItemPrice(itemList[itemName]["DBID"], trader, workingValue)
                    table.insert(allSellers, { price = workingValue, trader = trader })

                    if shouldUndercut(trader) then
                        table.insert(eligibleSellers, { price = workingValue, trader = trader })
                    end
                end
            end
        end
    end

    table.sort(allSellers, function(a, b)
        if a.price == b.price then
            return tostring(a.trader) < tostring(b.trader)
        end
        return a.price < b.price
    end)

    table.sort(eligibleSellers, function(a, b)
        if a.price == b.price then
            return tostring(a.trader) < tostring(b.trader)
        end
        return a.price < b.price
    end)

    local lowestSeller = allSellers[1]
    local nextLowestSeller = nil
    if lowestSeller then
        for _, seller in ipairs(allSellers) do
            if seller.trader ~= lowestSeller.trader then
                nextLowestSeller = seller
                break
            end
        end
    end

    if lowestSeller then
        itemList[itemName]["LowestPrice"] = lowestSeller.price
        itemList[itemName]["Trader"] = lowestSeller.trader
    end

    if nextLowestSeller then
        itemList[itemName]["NextLowestPrice"] = nextLowestSeller.price
        itemList[itemName]["NextTrader"] = nextLowestSeller.trader
    end

    local bestSeller = eligibleSellers[1]
    if bestSeller then
        itemList[itemName]["CompetitivePrice"] = bestSeller.price
        itemList[itemName]["CompetitiveTrader"] = bestSeller.trader
        itemList[itemName]["TargetPrice"] = calcTargetPrice((tonumber(bestSeller.price) or 0),
            (tonumber(itemList[itemName]["CurrentPrice"]) or -1), bestSeller.trader)
    end
    --items_db:exec("PRAGMA schema.wal_checkpoint;")
end

local cancelCheckPrices          = false

local traderCheckPrices          = function()
    print("\ayChecking current prices...")

    for currentItem, _ in pairs(itemList) do
        currentItemIdx = currentItemIdx + 1
        currentScanItem = currentItem
        print(string.format(" - \ag%d\ax/\ag%d\ax item = \am%s", currentItemIdx, totalItems, currentItem))
        searchBazaar(currentItem)
        autoUpdateTraderPrice(currentItem)
        bazaarItemPause(currentItemIdx)

        if cancelCheckPrices then
            cancelCheckPrices = false
            currentScanItem = nil
            print("\arPrice Scan Canceled!")
            return
        end
    end

    currentScanItem = nil
    print "\agPrice Scan Complete!"
end

local traderCheckItems           = function()
    if scanItem ~= nil then
        searchBazaar(scanItem)
        refreshItemSlot(itemList[scanItem]["slot"])
        scanItem = nil
        return
    end

    if doItemScan == false then return end

    bazaarSearchWindowControl("Open")

    print("\ayChecking for items...")

    refreshLocalItems()

    traderCheckPrices()

    print "\agItem Scan Complete!"

    doItemScan = false
    currentScanItem = nil
end
local ColumnID_AuctionItemName   = 0
local ColumnID_AuctionItemCost   = 1
local ColumnID_AuctionItemActive = 2
local ColumnID_AuctionItemUnused = 3

local ColumnID_ItemIcon          = 0
local ColumnID_Item              = 1
local ColumnID_MyPrice           = 2
local ColumnID_LowestPrice       = 3
local ColumnID_BestTrader        = 4
local ColumnID_NextLowestPrice   = 5
local ColumnID_NextTrader        = 6
local ColumnID_ListedDate        = 7
local ColumnID_TargetPrice       = 8
local ColumnID_LAST              = ColumnID_TargetPrice + 1

local genericSort                = function(k1, k2, dir)
    if dir == 1 then
        return k1 < k2
    end
    return k1 > k2
end

local auctionItemSorter          = function(k1, k2, spec, tbl)
    local i1 = tbl[k1]
    local i2 = tbl[k2]
    if spec then
        ---@type string, string
        local a, b = i1.item or "", i2.item or ""
        if spec.ColumnUserID == ColumnID_AuctionItemCost then
            a = i1.cost or "0"
            b = i2.cost or "0"
        end

        if a ~= b then return genericSort(a, b, spec.SortDirection) end

        return genericSort(k1, k2, spec.SortDirection)
    end

    return genericSort(k1, k2, 1)
end

local itemSorter                 = function(k1, k2, spec)
    local i1 = itemList[k1]
    local i2 = itemList[k2]
    if spec then
        local a
        local b
        if spec.ColumnUserID == ColumnID_MyPrice then
            a = tonumber(i1["CurrentPrice"] or 0)
            b = tonumber(i2["CurrentPrice"] or 0)
        end
        if spec.ColumnUserID == ColumnID_LowestPrice then
            a = tonumber(i1["LowestPrice"] or 2000000)
            b = tonumber(i2["LowestPrice"] or 2000000)
        end
        if spec.ColumnUserID == ColumnID_NextLowestPrice then
            a = tonumber(i1["NextLowestPrice"] or 2000000)
            b = tonumber(i2["NextLowestPrice"] or 2000000)
        end
        if spec.ColumnUserID == ColumnID_TargetPrice then
            a = tonumber(i1["TargetPrice"] or 0)
            b = tonumber(i2["TargetPrice"] or 0)
        end
        if spec.ColumnUserID == ColumnID_ListedDate then
            a = tonumber(i1["ListedDate"] or 0)
            b = tonumber(i2["ListedDate"] or 0)
        end
        if spec.ColumnUserID == ColumnID_BestTrader then
            a = (i1["Trader"] or "zUnknown")
            b = (i2["Trader"] or "zUnknown")
        end
        if spec.ColumnUserID == ColumnID_NextTrader then
            a = (i1["NextTrader"] or "zUnknown")
            b = (i2["NextTrader"] or "zUnknown")
        end

        if a ~= b then return genericSort(a, b, spec.SortDirection) end

        return genericSort(k1, k2, spec.SortDirection)
    end

    return genericSort(k1, k2, 1)
end

local ColumnID_HistoryPrice      = 0
local ColumnID_HistoryTrader     = 1
local ColumnID_HistoryDate       = 2
local ColumnID_HistoryLAST       = ColumnID_HistoryDate + 1

---@param k1 table<any>: object 1 to sort
---@param k2 table<any>: object 2 to sort
---@param spec table<any>: sorting spec
---@return boolean
local historySorter              = function(k1, k2, spec)
    if spec then
        local a
        local b
        if spec.ColumnUserID == ColumnID_HistoryPrice then
            a = tonumber(k1["Price"] or 0)
            b = tonumber(k2["Price"] or 0)
        elseif spec.ColumnUserID == ColumnID_HistoryTrader then
            a = (k1["Trader"])
            b = (k2["Trader"])
        else
            a = tonumber(k1["Date"])
            b = tonumber(k2["Date"])
        end

        if a ~= b then return genericSort(a, b, spec.SortDirection) end

        if spec.ColumnUserID == ColumnID_HistoryPrice then
            a = (k1["Trader"])
            b = (k2["Trader"])
        elseif spec.ColumnUserID == ColumnID_HistoryTrader then
            a = tonumber(k1["Date"])
            b = tonumber(k2["Date"])
        else
            a = tonumber(k1["Price"] or 0)
            b = tonumber(k2["Price"] or 0)
        end

        if a ~= b then return genericSort(a, b, spec.SortDirection) end

        if spec.ColumnUserID == ColumnID_HistoryPrice then
            a = tonumber(k1["Date"])
            b = tonumber(k2["Date"])
        elseif spec.ColumnUserID == ColumnID_HistoryTrader then
            a = tonumber(k1["Price"] or 0)
            b = tonumber(k2["Price"] or 0)
        else
            a = (k1["Trader"])
            b = (k2["Trader"])
        end

        return genericSort(a, b, spec.SortDirection)
    end


    return genericSort(k1["Date"], k2["Date"], 1)
end

local function DisabledButton(text)
    ImGui.PushStyleColor(ImGuiCol.Button, 0.2, 0.2, 0.2, 0.5)
    ImGui.PushStyleColor(ImGuiCol.ButtonHovered, 0.2, 0.2, 0.2, 0.5)
    ImGui.PushStyleColor(ImGuiCol.ButtonActive, 0.2, 0.2, 0.2, 0.5)
    ImGui.SmallButton(text) -- noop
    ImGui.PopStyleColor(3)
end

local ICON_SIZE = 20

local function drawInspectableIcon(iconID, item)
    if not item then return end
    if not iconID then iconID = 0 end
    local cursor_x, cursor_y = ImGui.GetCursorPos()

    animItems:SetTextureCell(iconID or 0)

    ImGui.DrawTextureAnimation(animItems, ICON_SIZE, ICON_SIZE)

    ImGui.SetCursorPos(cursor_x, cursor_y)

    ImGui.PushID((tostring(iconID or 0) or "0") .. (item.Name() or "") .. "_invis_btn")
    ImGui.InvisibleButton(item.Name() or "NotFound", ImVec2(ICON_SIZE, ICON_SIZE),
        bit32.bor(ImGuiButtonFlags.MouseButtonLeft))
    if ImGui.IsItemHovered() and ImGui.IsMouseReleased(ImGuiMouseButton.Left) then
        item.Inspect()
    end
    ImGui.PopID()
end

local sortedItemKeys = {}
local sortedAuctionItemKeys = {}
local sortedDisabledAuctionItemKeys = {}
local editingTargetItem = nil
local showAdvancedPricing = false

local function renderTraderUI()
    local pressed

    ImGui.PushStyleColor(ImGuiCol.Text, 0.0, 1.0, 0.0, 1)
    ImGui.Text("Bazaar running for %s", CharConfig)
    ImGui.PopStyleColor(1)

    local used

    ImGui.Text("Trader Controls")
    if ImGui.Button("Open Trader", 150, 25) then
        traderWindowControl("Open")
    end
    ImGui.SameLine()
    if mq.TLO.Me.Trader() then
        ImGui.PushStyleColor(ImGuiCol.Button, 0.6, 0.3, 0.3, 1.0)
        if ImGui.Button("Turn Off Trader", 150, 25) then
            traderWindowControl("Off")
        end
    else
        ImGui.PushStyleColor(ImGuiCol.Button, 0.3, 0.6, 0.3, 1.0)
        if ImGui.Button("Turn On Trader", 150, 25) then
            traderWindowControl("On")
        end
    end
    ImGui.PopStyleColor(1)

    ImGui.Separator()
    ImGui.Text("Scan Controls")

    ImGui.Text("Scan every")
    ImGui.SameLine()
    ImGui.PushItemWidth(80)
    settings.scanTimer, pressed = ImGui.InputInt("##scan_minutes", settings.scanTimer)
    if pressed then
        if settings.scanTimer < 30 then settings.scanTimer = 30 end
        SaveSettings(false)
    end
    ImGui.PopItemWidth()
    ImGui.SameLine()
    ImGui.Text("minutes")

    if ImGui.Button("Check Bazaar Prices", 170, 25) then
        doItemScan = true
        currentItemIdx = 0
        currentScanItem = nil
        lastFullScan = os.time()
    end
    ImGui.SameLine()
    ImGui.PushStyleColor(ImGuiCol.Text, 0.3, 0.6, 0.6, 1.0)
    ImGui.Text(string.format("Next scan: %s", FormatTime((60 * settings.scanTimer) - (os.time() - lastFullScan))))
    ImGui.PopStyleColor(1)
    ImGui.SameLine()
    pauseScan, _ = ImGui.Checkbox("Pause timer", pauseScan)
    ImGui.SameLine()
    settings.AutoUpdatePrices, pressed = ImGui.Checkbox("Update prices after scan", settings.AutoUpdatePrices)
    if pressed then
        SaveSettings()
    end
    Tooltip("When enabled, Scan Items will update your trader prices to the calculated Target Price.")
    ImGui.Text("")

    ImGui.Text("Pricing Rules")

    ImGui.Text("Undercut range")
    ImGui.SameLine()
    ImGui.PushItemWidth(70)
    settings.UnderCutPercent, used = ImGui.InputInt("##min_undercut_percent", settings.UnderCutPercent)
    if used then
        if settings.UnderCutPercent < 0 then settings.UnderCutPercent = 0 end
        if settings.UnderCutPercent > 90 then settings.UnderCutPercent = 90 end
        if settings.UnderCutPercentMax < settings.UnderCutPercent then
            settings.UnderCutPercentMax = settings.UnderCutPercent
        end
        recalcTargetPrices()
        SaveSettings()
    end
    ImGui.SameLine()
    ImGui.Text("% to")
    ImGui.SameLine()
    settings.UnderCutPercentMax, used = ImGui.InputInt("##max_undercut_percent", settings.UnderCutPercentMax)
    if used then
        if settings.UnderCutPercentMax < 0 then settings.UnderCutPercentMax = 0 end
        if settings.UnderCutPercentMax > 90 then settings.UnderCutPercentMax = 90 end
        if settings.UnderCutPercent > settings.UnderCutPercentMax then
            settings.UnderCutPercent = settings.UnderCutPercentMax
        end
        recalcTargetPrices()
        SaveSettings()
    end
    ImGui.PopItemWidth()
    ImGui.SameLine()
    ImGui.Text("% below lowest eligible seller")

    ImGui.PushStyleColor(ImGuiCol.Text, 0.9, 0.85, 0.45, 1.0)
    if settings.AutoUpdatePrices then
        ImGui.Text("Auto-update is ON: prices may change during scans.")
    else
        ImGui.Text("Auto-update is OFF: scans only calculate target prices.")
    end
    ImGui.PopStyleColor(1)

    settings.RaiseUnderpriced, used = ImGui.Checkbox("Raise prices that are way under target", settings.RaiseUnderpriced)
    if used then
        SaveSettings()
    end
    if settings.RaiseUnderpriced then
        ImGui.SameLine()
        ImGui.Text("if under by")
        ImGui.SameLine()
        ImGui.PushItemWidth(95)
        settings.RaiseUnderpricedPercent, used = ImGui.InputInt("##raise_underpriced_percent", settings.RaiseUnderpricedPercent)
        if used then
            if settings.RaiseUnderpricedPercent < 0 then settings.RaiseUnderpricedPercent = 0 end
            if settings.RaiseUnderpricedPercent > 90 then settings.RaiseUnderpricedPercent = 90 end
            recalcTargetPrices()
            SaveSettings()
        end
        ImGui.PopItemWidth()
        ImGui.SameLine()
        ImGui.Text("% or more")
    end

    ImGui.Text("Default price")
    ImGui.SameLine()
    ImGui.PushItemWidth(180)
    local newText, _ = ImGui.InputText("##default_price", tostring(settings.DefaultPrice),
        ImGuiInputTextFlags.CharsDecimal)
    ---@diagnostic disable-next-line: undefined-field
    if newText:len() > 0 and newText ~= tostring(settings.DefaultPrice) then
        settings.DefaultPrice = math.ceil(tonumber(newText) or 0)
        SaveSettings()
    end
    ImGui.PopItemWidth()

    ImGui.Text("Don't undercut")
    ImGui.SameLine()
    ImGui.PushItemWidth(300)
    newText, _ = ImGui.InputText("##dont_undercut", settings.DontUndercut, ImGuiInputTextFlags.None)
    ---@diagnostic disable-next-line: undefined-field
    if newText:len() > 0 and newText ~= settings.DontUndercut then
        settings.DontUndercut = newText
        SaveSettings()
    end
    ImGui.PopItemWidth()

    showAdvancedPricing, _ = ImGui.Checkbox("Advanced", showAdvancedPricing)
    if showAdvancedPricing then
        ImGui.Indent()
        ImGui.Text("Round target prices to nearest")
        ImGui.SameLine()
        ImGui.PushItemWidth(180)
        settings.UnderCutOOM, used = ImGui.InputInt("##undercut_rounding", settings.UnderCutOOM)
        if used then
            if settings.UnderCutOOM < 0 then settings.UnderCutOOM = 0 end
            if settings.UnderCutOOM > 90 then settings.UnderCutOOM = 90 end
            recalcTargetPrices()
            SaveSettings()
        end
        ImGui.PopItemWidth()
        Tooltip("Optional rounding for target prices. Leave at 0 if you are unsure.")
        ImGui.Unindent()
    end
    ImGui.Text("")

    ImGui.BeginChild("BazaarItemsPanel")

    ImGui.Separator()
    ImGui.Text("Trader Items")
    if doItemScan then
        if not cancelCheckPrices then
            ImGui.Text(string.format("Scanning %d / %d", math.max(0, currentItemIdx), math.max(totalItems or 0, 0)))
        else
            ImGui.Text("Canceling Scan...")
        end
        ImGui.SameLine()
        ImGui.PushStyleColor(ImGuiCol.Button, 242, 0, 0, 0.5)
        ImGui.PushStyleColor(ImGuiCol.ButtonHovered, 242, 0, 0, 1)
        ImGui.PushStyleColor(ImGuiCol.ButtonActive, 255, 0, 0, 1)
        if ImGui.Button(ICONS.MD_CANCEL, 25, 22) then
            cancelCheckPrices = true
        end
        ImGui.PopStyleColor(3)
        ImGui.SameLine()
        local progressFraction = math.max(0, currentItemIdx) / math.max(totalItems or 1, 1)
        local progressOverlay = string.format("%3d%%", math.floor((progressFraction * 100) + 0.5))
        local progressBarWidth = ImGui.GetContentRegionAvail()
        local progressBarHeight = 24
        local progressTextWidth, progressTextHeight = ImGui.CalcTextSize(progressOverlay)
        local progressBarX, progressBarY = ImGui.GetCursorScreenPos()
        ImGui.ProgressBar(progressFraction, progressBarWidth, progressBarHeight, "")
        ImGui.GetWindowDrawList():AddText(
            ImVec2(
                progressBarX + ((progressBarWidth - progressTextWidth) * 0.5),
                progressBarY + ((progressBarHeight - progressTextHeight) * 0.5)
            ),
            ImGui.GetColorU32(1, 1, 1, 1),
            progressOverlay
        )
    end

    if ImGui.BeginTable("ItemList", ColumnID_LAST, bit32.bor(ImGuiTableFlags.Resizable, ImGuiTableFlags.Borders, ImGuiTableFlags.Sortable)) then
        ImGui.PushStyleColor(ImGuiCol.Text, 255, 0, 255, 1)
        ImGui.TableSetupColumn('Icon', bit32.bor(ImGuiTableColumnFlags.NoSort, ImGuiTableColumnFlags.WidthFixed), 20.0,
            ColumnID_ItemIcon)
        ImGui.TableSetupColumn('Item',
            bit32.bor(ImGuiTableColumnFlags.DefaultSort, ImGuiTableColumnFlags.PreferSortDescending,
                ImGuiTableColumnFlags.WidthFixed),
            300.0, ColumnID_Item)
        ImGui.TableSetupColumn('My Price', ImGuiTableColumnFlags.None, 50.0, ColumnID_MyPrice)
        ImGui.TableSetupColumn('Lowest Price', ImGuiTableColumnFlags.None, 50.0, ColumnID_LowestPrice)
        ImGui.TableSetupColumn('Lowest Trader', ImGuiTableColumnFlags.None, 50.0, ColumnID_BestTrader)
        ImGui.TableSetupColumn('Next Lowest Price', ImGuiTableColumnFlags.None, 50.0, ColumnID_NextLowestPrice)
        ImGui.TableSetupColumn('Next Lowest Trader', ImGuiTableColumnFlags.None, 50.0, ColumnID_NextTrader)
        ImGui.TableSetupColumn('Listed Date', ImGuiTableColumnFlags.None, 50.0, ColumnID_ListedDate)
        ImGui.TableSetupColumn('Target Price', ImGuiTableColumnFlags.None, 50.0, ColumnID_TargetPrice)
        ImGui.PopStyleColor()
        ImGui.TableHeadersRow()
        local sortSpec = ImGui.TableGetSortSpecs()
        if sortSpec and (sortSpec.SpecsDirty or (#sortedItemKeys ~= totalItems)) then
            print("Redoing Item List...")
            sortSpec.SpecsDirty = false

            sortedItemKeys = {}

            for k, v in pairs(itemList) do
                table.insert(sortedItemKeys, k)
            end

            if sortSpec.SpecsCount >= 1 then
                local spec = sortSpec:Specs(1)
                table.sort(sortedItemKeys, function(k1, k2) return itemSorter(k1, k2, spec) end)
            end
        end
        for _, currentItem in ipairs(sortedItemKeys) do
            local itemData = itemList[currentItem]
            ImGui.TableNextRow()

            ImGui.TableNextColumn()

            if itemData then
                drawInspectableIcon((tonumber(itemData["IconID"]) or 500) - 500, itemData["ItemRef"])
            end

            ImGui.TableNextColumn()
            if ImGui.Selectable(currentItem, false, 0) then
                print("Loading history...")
                itemDB:loadHistoricalData(currentItem, itemData["DBID"])
                clearCachedHistory()
                openHistoryGUI = true
            end
            ImGui.TableNextColumn()
            if not itemData["LowestPrice"] then
                ImGui.PushStyleColor(ImGuiCol.Text, 80, 80, 80, 0.25)
                ImGui.PushStyleColor(ImGuiCol.Text, 80, 80, 80, 0.25)
            else
                if itemData["CurrentPrice"] <= (itemData["LowestPrice"] or 2000000) then
                    if (itemData["CurrentPrice"] * 1.3) <= (itemData["LowestPrice"] or 2000000) then
                        ImGui.PushStyleColor(ImGuiCol.Text, 255, 0, 0, 1)
                        ImGui.PushStyleColor(ImGuiCol.Text, 255, 255, 0, 1)
                    else
                        ImGui.PushStyleColor(ImGuiCol.Text, 255, 0, 0, 1)
                        ImGui.PushStyleColor(ImGuiCol.Text, 0, 255, 0, 1)
                    end
                else
                    ImGui.PushStyleColor(ImGuiCol.Text, 0, 255, 0, 1)
                    ImGui.PushStyleColor(ImGuiCol.Text, 255, 0, 0, 1)
                end
            end
            ImGui.Text(FormatInt(itemData["CurrentPrice"] or 0))
            ImGui.PopStyleColor()
            ImGui.TableNextColumn()
            ImGui.Text(itemData["LowestPrice"] and FormatInt(itemData["LowestPrice"]) or "Unknown")
            ImGui.PopStyleColor()
            ImGui.TableNextColumn()
            if not itemData["Trader"] then
                ImGui.PushStyleColor(ImGuiCol.Text, 80, 80, 80, 0.25)
            else
                if shouldUndercut(itemData["Trader"] or "Unknown") then
                    ImGui.PushStyleColor(ImGuiCol.Text, 0, 255, 255, 1)
                else
                    ImGui.PushStyleColor(ImGuiCol.Text, 255, 255, 0, 1)
                end
            end
            ImGui.Text(itemData["Trader"] or "Unknown")
            ImGui.PopStyleColor()
            ImGui.TableNextColumn()
            if not itemData["NextLowestPrice"] then
                ImGui.PushStyleColor(ImGuiCol.Text, 80, 80, 80, 0.25)
            else
                ImGui.PushStyleColor(ImGuiCol.Text, 180, 220, 255, 1)
            end
            ImGui.Text(itemData["NextLowestPrice"] and FormatInt(itemData["NextLowestPrice"]) or "Unknown")
            ImGui.PopStyleColor()
            ImGui.TableNextColumn()
            if not itemData["NextTrader"] then
                ImGui.PushStyleColor(ImGuiCol.Text, 80, 80, 80, 0.25)
            else
                ImGui.PushStyleColor(ImGuiCol.Text, 180, 220, 255, 1)
            end
            ImGui.Text(itemData["NextTrader"] or "Unknown")
            ImGui.PopStyleColor()
            ImGui.TableNextColumn()
            ImGui.Text(GetDateString(itemData["ListedDate"] or 0))
            ImGui.SameLine()
            ImGui.PushID(currentItem .. "_set_list_btn")
            if ImGui.SmallButton(string.format('%s', ICONS.MD_UPDATE)) then
                itemDB:cacheItemListedTime(itemData["DBID"], itemData["CurrentPrice"] or 0, os.time())
                itemList[currentItem]["ListedDate"] = os.time()
            end
            ImGui.PopID()
            Tooltip("Set List Date")
            ImGui.TableNextColumn()
            ImGui.PushStyleColor(ImGuiCol.Text, 100, 100, 255, 1)
            local targetText = tostring(itemData["TargetPrice"] or settings.DefaultPrice)
            if editingTargetItem == currentItem then
                ImGui.PushItemWidth(90)
                ImGui.PushID(currentItem .. "_text")
                local newText, _ = ImGui.InputText("##targetinputtext##edit", targetText, ImGuiInputTextFlags.CharsDecimal)
                ---@diagnostic disable-next-line: undefined-field
                if newText:len() > 0 and newText ~= tostring(itemData["TargetPrice"]) then
                    itemData["TargetPrice"] = math.ceil(tonumber(newText) or 0)
                end
                ImGui.PopID()
                ImGui.PopItemWidth()
                ImGui.SameLine()
                ImGui.PushID(currentItem .. "_done_edit_btn")
                if ImGui.SmallButton("Done") then
                    editingTargetItem = nil
                end
                ImGui.PopID()
            else
                ImGui.Text(FormatInt(itemData["TargetPrice"] or settings.DefaultPrice))
                ImGui.SameLine()
                ImGui.PushID(currentItem .. "_edit_target_btn")
                if ImGui.SmallButton("Edit") then
                    editingTargetItem = currentItem
                end
                ImGui.PopID()
            end
            ImGui.SameLine()
            ImGui.PushID(currentItem .. "_set_btn")
            if not setItem then
                if ImGui.SmallButton(string.format('%s', ICONS.FA_CHECK_CIRCLE)) then
                    local oldPrice = itemData["CurrentPrice"]
                    setTraderPrice(currentItem, itemData["TargetPrice"])
                    itemData["CurrentPrice"] = itemData["TargetPrice"]
                    itemData["TargetPrice"] = calcTargetPrice((itemData["CompetitivePrice"] or 2000000),
                        (oldPrice or -1), (itemData["CompetitiveTrader"] or "Unknown"))
                end
            else
                DisabledButton(string.format('%s', ICONS.FA_CHECK_CIRCLE)) -- noop
            end
            ImGui.PopID()
            Tooltip("Set Price")
            ImGui.SameLine()
            ImGui.PushID(currentItem .. "_scan_btn")
            if scanItem == nil and doItemScan == false then
                if ImGui.SmallButton(string.format('%s', ICONS.MD_REFRESH)) then
                    scanItem = currentItem
                    itemList[currentItem]["LowestPrice"] = nil
                end
            else
                DisabledButton(string.format('%s', ICONS.MD_REFRESH)) -- noop
            end
            ImGui.PopID()
            ImGui.PopStyleColor()
            Tooltip("Refresh Item")
        end
        ImGui.EndTable()
    end

    if ImGui.CollapsingHeader("Previously Sold Items") then
        ImGui.Indent()
        if ImGui.BeginTable("OldItemList", 3, ImGuiTableFlags.Borders) then
            ImGui.PushStyleColor(ImGuiCol.Text, 255, 0, 255, 1)
            ImGui.TableSetupColumn('Id', (ImGuiTableColumnFlags.WidthFixed), 50.0)
            ImGui.TableSetupColumn('DBId', (ImGuiTableColumnFlags.WidthFixed), 50.0)
            ImGui.TableSetupColumn('Item', (ImGuiTableColumnFlags.WidthStretch), 300.0)
            ImGui.PopStyleColor()
            ImGui.TableHeadersRow()

            for idx, itemData in ipairs(allKnownItems) do
                ImGui.TableNextColumn()

                ImGui.Text(tostring(idx))

                ImGui.TableNextColumn()

                ImGui.Text(tostring(itemData.ID))

                ImGui.TableNextColumn()
                if ImGui.Selectable(itemData.Name, false, 0) then
                    print("Loading history...")
                    itemDB:loadHistoricalData(itemData.Name, itemData.ID)
                    clearCachedHistory()
                    openHistoryGUI = true
                end
            end
            ImGui.EndTable()
        end
        ImGui.Unindent()
    end
    ImGui.EndChild()
end

function math.average(t)
    local sum = 0
    for _, v in pairs(t) do
        sum = sum + v
    end
    return sum / #t
end

local function createCachedGraphData()
    local itemName, historicalSales = itemDB:getHistoricalData()

    clearCachedHistory()
    for _, itemData in ipairs(historicalSales) do
        local dayString = GetDayString(itemData.Date)
        printf("\am%s\ay on \at%s\ay => \ag%s", itemName, dayString, itemData.Price)
        if itemData.Price > cachedPriceHistory.max_y then cachedPriceHistory.max_y = itemData.Price end
        if itemData.Date > cachedPriceHistory.max_x then cachedPriceHistory.max_x = itemData.Date end
        if itemData.Date < cachedPriceHistory.min_x then cachedPriceHistory.min_x = itemData.Date end
        table.insert(cachedPriceHistory.ys, itemData.Price or 0)
        table.insert(cachedPriceHistory.xs, itemData.Date or 0)
        cachedPriceHistory.labels[os.time(GetDayTable(itemData.Date))] = cachedPriceHistory.labels
            [os.time(GetDayTable(itemData.Date))] or {}
        table.insert(cachedPriceHistory.labels[os.time(GetDayTable(itemData.Date))], itemData.Price)
    end

    local dates = {}
    for date, _ in pairs(cachedPriceHistory.labels) do table.insert(dates, date) end
    table.sort(dates)

    for _, date in ipairs(dates) do
        local val = cachedPriceHistory.labels[date]
        local avg = math.average(val)
        table.insert(cachedPriceHistory.avg_ys, avg)
        table.insert(cachedPriceHistory.avg_xs, date)
        printf("\agHistorical price on \am%s \agwas \at%0.2f", GetDayString(date), avg)
    end
end

local function renderHistoryUI()
    local historicalItem, historicalSales = itemDB:getHistoricalData()
    ImGui.PushStyleColor(ImGuiCol.Text, 0.0, 1.0, 0.0, 1)
    ImGui.Text("Sales History for Item %s", historicalItem)
    ImGui.PopStyleColor(1)

    if #cachedPriceHistory.xs == 0 and #historicalSales > 0 then
        createCachedGraphData()
    end

    if ImPlot.BeginPlot("Price of " .. historicalItem) then
        ImPlot.SetupAxes("Date", "Price")
        ImPlot.SetupAxesLimits(cachedPriceHistory.min_x - 36000, cachedPriceHistory.max_x + 36000, 0,
            cachedPriceHistory.max_y * 2, ImPlotCond.Always)
        ImPlot.SetupAxisScale(ImAxis.X1, ImPlotScale.Time)
        ImPlot.PlotScatter('Prices', cachedPriceHistory.xs, cachedPriceHistory.ys, #cachedPriceHistory.xs)
        ImPlot.PlotLine('Average', cachedPriceHistory.avg_xs, cachedPriceHistory.avg_ys, #cachedPriceHistory.avg_xs)
        ImPlot.EndPlot()
    end
    --ImGui.PlotLines('', cachedPriceHistory, #cachedPriceHistory, 0, "", 0, 2000, ImVec2(width, height))

    if ImGui.BeginTable("HistoryList", ColumnID_HistoryLAST, bit32.bor(ImGuiTableFlags.Resizable, ImGuiTableFlags.Borders, ImGuiTableFlags.Sortable)) then
        ImGui.PushStyleColor(ImGuiCol.Text, 255, 0, 255, 1)
        ImGui.TableSetupColumn('Price', ImGuiTableColumnFlags.None, 50.0, ColumnID_HistoryPrice)
        ImGui.TableSetupColumn('Trader', ImGuiTableColumnFlags.None, 50.0, ColumnID_HistoryTrader)
        ImGui.TableSetupColumn('Date',
            bit32.bor(ImGuiTableColumnFlags.DefaultSort, ImGuiTableColumnFlags.PreferSortDescending),
            50.0, ColumnID_HistoryDate)
        ImGui.PopStyleColor()
        ImGui.TableHeadersRow()
        local sortSpec = ImGui.TableGetSortSpecs()
        if sortSpec and sortSpec.SpecsDirty then
            sortSpec.SpecsDirty = false
        end
        ImGui.TableNextRow()

        if sortSpec and sortSpec.SpecsCount >= 1 then
            local spec = sortSpec:Specs(1)
            table.sort(historicalSales, function(k1, k2) return historySorter(k1, k2, spec) end)
        end

        for _, itemData in ipairs(historicalSales) do
            ImGui.TableNextColumn()
            ImGui.Text(itemData["Price"] and FormatInt(itemData["Price"]) or "Unknown")
            ImGui.TableNextColumn()
            if shouldUndercut(itemData["Trader"] or "Unknown") then
                ImGui.PushStyleColor(ImGuiCol.Text, 0, 255, 255, 1)
            else
                ImGui.PushStyleColor(ImGuiCol.Text, 255, 255, 0, 1)
            end
            ImGui.Text(itemData["Trader"] or "Unknown")
            ImGui.PopStyleColor()
            ImGui.TableNextColumn()
            ImGui.Text(GetDateString(itemData["Date"]) or "Unknown")
        end

        ImGui.EndTable()
    end
end

local RenderNewAuctionPopup = function()
    if ImGui.BeginPopup(newAuctionPopup) then
        ImGui.Text("Item Name:")
        local tmp_item, selected_item = ImGui.InputText("##edit_item", popupAuctionItem, 0)
        if selected_item then popupAuctionItem = tmp_item end

        ImGui.Text("Item Cost:")
        local tmp_cost, selected_cost = ImGui.InputText("##edit_cost", popupAuctionCost, 0)
        if selected_cost then popupAuctionCost = tmp_cost end

        if ImGui.Button("Save") then
            ---@diagnostic disable-next-line: undefined-field
            if popupAuctionItem ~= nil and popupAuctionItem:len() > 0 then
                settings = settings or {}
                local exists, idx = GetTableEntry(settings.AuctionItems or {}, popupAuctionItem)
                local exists_dis, idx_dis = GetTableEntry(settings.DisabledAuctionItems or {}, popupAuctionItem)
                if exists then
                    settings.AuctionItems[idx].cost = popupAuctionCost
                elseif exists_dis then
                    settings.DisabledAuctionItems[idx_dis].cost = popupAuctionCost
                else
                    table.insert(settings.AuctionItems, { item = popupAuctionItem, cost = popupAuctionCost, })
                end
                SaveSettings(true)
            else
                print("\arError Saving Auction Item: Item Name cannot be empty.\ax")
            end

            popupAuctionCost = ""
            popupAuctionItem = ""

            ImGui.CloseCurrentPopup()
        end

        ImGui.SameLine()

        if ImGui.Button("Cancel") then
            ImGui.CloseCurrentPopup()
        end
        ImGui.EndPopup()
    end
end

local forceAuction          = false
local doAuction             = function(ignorePause)
    cacheItems()

    if not forceAuction then
        if pauseAuctioning and not ignorePause then
            return
        end
    end

    local tokens = Tokenize(settings.Channels, "|")

    for _, v in ipairs(AuctionText) do
        for _, c in ipairs(tokens) do
            mq.cmdf("/%s WTS %s", c, v)
            print(string.format("/%s WTS %s", c, v))
            mq.delay(500)
        end
    end

    forceAuction = false
    lastAuction = os.clock()
end

local addCursorItem         = function()
    if mq.TLO.Cursor() ~= nil then
        popupAuctionItem = mq.TLO.Cursor() or ""
        openPopup = true
    end
end

local ICON_WIDTH            = 50
local ICON_HEIGHT           = 50

local function handleSorting(sortSpec, inputTable)
    local sortedKeys = {}

    for k, _ in pairs(inputTable or {}) do
        table.insert(sortedKeys, k)
    end

    if sortSpec.SpecsCount >= 1 then
        local spec = sortSpec:Specs(1)
        table.sort(sortedKeys, function(k1, k2) return auctionItemSorter(k1, k2, spec, inputTable) end)
    end

    return sortedKeys
end

local function renderAuctionUI()
    if not settings then return end
    local used

    ImGui.Text("Auction Settings")
    settings.Timer, used = ImGui.SliderInt("Auction Timer", settings.Timer, 1, 30,
        "%d")
    if used then
        SaveSettings(false)
    end
    local newText, _ = ImGui.InputText("Auction Channel", settings.Channels,
        ImGuiInputTextFlags.None)
    ---@diagnostic disable-next-line: undefined-field
    if newText:len() > 0 and newText ~= settings.Channels then
        settings.Channels = newText
        SaveSettings(false)
    end
    ImGui.Separator()
    pauseAuctioning, _ = ImGui.Checkbox("Pause Auction", pauseAuctioning)
    ImGui.SetWindowFontScale(1.2)
    ImGui.PushStyleColor(ImGuiCol.Text, 255, 255, 0, 1)
    ImGui.Text("Count Down: %ds", (settings.Timer * 60) - (os.clock() - lastAuction))
    ImGui.SetWindowFontScale(1)
    ImGui.PopStyleColor()
    if ImGui.Button("Auction Now!") then
        forceAuction = true
    end

    ImGui.Separator()

    ImGui.Text("Drag new Items")
    if ImGui.Button("HERE", ICON_WIDTH, ICON_HEIGHT) then
        addCursorItem()
        --mq.cmd("/autoinv")
    end
    ImGui.Separator()


    if ImGui.Button("Manually Add Auction Line") then
        openPopup = true
    end

    ImGui.Separator()

    ImGui.BeginChild("AuctionItemList")

    ImGui.PushStyleColor(ImGuiCol.Text, 0, 100, 255, 1)
    ImGui.Text("Auction Items")

    ImGui.BeginTable("Items", 4, bit32.bor(ImGuiTableFlags.Resizable, ImGuiTableFlags.Borders, ImGuiTableFlags.Sortable))
    ImGui.TableSetupColumn('Item', ImGuiTableColumnFlags.None, 250, ColumnID_AuctionItemName)
    ImGui.TableSetupColumn('Cost', ImGuiTableColumnFlags.None, 50.0, ColumnID_AuctionItemCost)
    ImGui.TableSetupColumn('Active', ImGuiTableColumnFlags.NoSort, 50.0, ColumnID_AuctionItemActive)
    ImGui.TableSetupColumn('', ImGuiTableColumnFlags.NoSort, 50.0, ColumnID_AuctionItemUnused)
    ImGui.TableHeadersRow()
    ImGui.PopStyleColor()

    local sortSpec = ImGui.TableGetSortSpecs()
    local auctionItemCount = GetTableSize(settings.AuctionItems)
    if sortSpec and (sortSpec.SpecsDirty or (#sortedAuctionItemKeys ~= auctionItemCount)) then
        printf("Redoing Auction Item List... %d %d", #sortedAuctionItemKeys, auctionItemCount)
        sortedAuctionItemKeys = handleSorting(sortSpec, settings.AuctionItems)
    end
    local disabledAuctionItemCount = GetTableSize(settings.DisabledAuctionItems)
    if sortSpec and (sortSpec.SpecsDirty or (#sortedDisabledAuctionItemKeys ~= disabledAuctionItemCount)) then
        printf("Redoing Disabled Auction Item List... %d %d", #sortedDisabledAuctionItemKeys, disabledAuctionItemCount)
        sortedDisabledAuctionItemKeys = handleSorting(sortSpec, settings.DisabledAuctionItems)
    end

    if sortSpec then
        sortSpec.SpecsDirty = false
    end

    if (settings) then
        for _, key in ipairs(sortedAuctionItemKeys or {}) do
            local v = settings.AuctionItems[key]
            ImGui.TableNextColumn()
            local _, clicked = ImGui.Selectable(v.item, false)
            if clicked then
                popupAuctionItem = v.item
                popupAuctionCost = v.cost
                openPopup = true
            end
            ImGui.TableNextColumn()
            ImGui.Text(v.cost)
            ImGui.TableNextColumn()
            ImGui.PushID(key .. "_disab_togg_btn")
            if ImGui.SmallButton(ICONS.FA_TOGGLE_ON) then
                table.insert(settings.DisabledAuctionItems, settings.AuctionItems[key])
                settings.AuctionItems[key] = nil
                SaveSettings(true)
                cacheItems()
            end
            ImGui.PopID()
            ImGui.TableNextColumn()
            ImGui.PushID(key .. "_trash_btn")
            if ImGui.SmallButton(ICONS.FA_TRASH) then
                settings.AuctionItems[key] = nil
                SaveSettings(true)
            end
            ImGui.PopID()
        end
        for _, key in ipairs(sortedDisabledAuctionItemKeys or {}) do
            local v = settings.DisabledAuctionItems[key]
            ImGui.TableNextColumn()
            local _, clicked = ImGui.Selectable(v.item, false)
            if clicked then
                popupAuctionItem = v.item
                popupAuctionCost = v.cost
                openPopup = true
            end
            ImGui.TableNextColumn()
            ImGui.Text(v.cost)
            ImGui.TableNextColumn()
            ImGui.PushID(key .. "_enab_togg_btn")
            if ImGui.SmallButton(ICONS.FA_TOGGLE_OFF) then
                table.insert(settings.AuctionItems, settings.DisabledAuctionItems[key])
                settings.DisabledAuctionItems[key] = nil
                SaveSettings(true)
            end
            ImGui.PopID()
            ImGui.TableNextColumn()
            ImGui.PushID(key .. "_trash_btn")
            if ImGui.SmallButton(ICONS.FA_TRASH) then
                settings.DisabledAuctionItems[key] = nil
                SaveSettings(true)
            end
            ImGui.PopID()
        end
    end
    ImGui.EndTable()
    ImGui.EndChild()

    if openPopup and ImGui.IsPopupOpen(newAuctionPopup) == false then
        ImGui.OpenPopup(newAuctionPopup)
        openPopup = false
    end

    RenderNewAuctionPopup()
end

local function asyncAuctionUpdate()
    if (not settings) then
        ---@diagnostic disable-next-line: lowercase-global
        curState = "No configuration for " .. CharConfig .. "..."
        return
    end

    if lastAuction == 0 then
        lastAuction = os.clock()
    end

    if not pauseAuctioning and GetTableSize(settings.AuctionItems or {}) == 0 then
        pauseAuctioning = true
    end

    if pauseAuctioning then
        lastAuction = os.clock()
    end

    if forceAuction or os.clock() - lastAuction >= settings.Timer * 60 then
        print("Auctioning items")
        doAuction(false)
    end
end

local function Alive()
    return mq.TLO.NearestSpawn('pc')() ~= nil
end

local BazaarGUI = function()
    if not Alive() then return end
    if mq.TLO.MacroQuest.GameState() ~= "INGAME" then return end
    if mq.TLO.Me.Dead() then return end

    if openGUI then
        ImGui.SetNextWindowBgAlpha(bgOpacity)
        ---@diagnostic disable-next-line: undefined-field
        openGUI, shouldDrawGUI = ImGui.Begin('BFO Bazaar', openGUI)
        if shouldDrawGUI then
            if ImGui.BeginTabBar("Tabs") then
                if ImGui.BeginTabItem("Bazaar") then
                    renderTraderUI()
                    ImGui.EndTabItem()
                end

                if ImGui.BeginTabItem("Auction") then
                    renderAuctionUI()
                    ImGui.EndTabItem()
                end

                ImGui.EndTabBar()
            end
        end

        ---@diagnostic disable-next-line: undefined-field
        ImGui.End()

        if not openHistoryGUI then return end

        ---@diagnostic disable-next-line: undefined-field
        openHistoryGUI, shouldDrawHistoryGUI = ImGui.Begin('BFO Bazaar History', openHistoryGUI)
        if shouldDrawHistoryGUI then
            renderHistoryUI()
        end

        ---@diagnostic disable-next-line: undefined-field
        ImGui.End()
    end
end

--if not mq.TLO.Plugin("MQ2Bzsrch").IsLoaded() then
--    printf("\arBazaar requires MQ2Bzsrch to be loaded!\n\aw\ayPlease load it using: \aw/plugin mq2bzsrch")
--    mq.exit()
--end
LoadSettings()

mq.imgui.init('bazaarGUI', BazaarGUI)

bazaarSearchWindowControl("Open")
traderWindowControl("Open")

while openGUI do
    if pauseScan then
        lastFullScan = os.time()
    end

    if os.time() - lastFullScan >= (60 * settings.scanTimer) then
        doItemScan = true
        currentItemIdx = 0
        lastFullScan = os.time()
        allKnownItems = itemDB:getAllItems()
    end

    traderCheckItems()
    asyncSetTraderPrice()
    asyncAuctionUpdate()
    itemDB:GiveTime()

    mq.doevents()
    mq.delay(10)
end

itemDB:Shutdown()
