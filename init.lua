local mq       = require('mq')
local ICONS    = require('mq.Icons')
local BazaarDB = require('bazaar_db')
local ImGui    = require('ImGui')
local ImPlot   = require('ImPlot')
require('baz_utils')

local animItems      = mq.FindTextureAnimation("A_DragItem")
local animBox        = mq.FindTextureAnimation("A_RecessedBox")

-- Constants
local ICON_WIDTH     = 40
local ICON_HEIGHT    = 40
local COUNT_X_OFFSET = 39
local COUNT_Y_OFFSET = 23
local EQ_ICON_OFFSET = 500

local function display_item_on_cursor()
    if mq.TLO.Cursor() then
        local cursor_item = mq.TLO.Cursor -- this will be an MQ item, so don't forget to use () on the members!
        local mouse_x, mouse_y = ImGui.GetMousePos()
        local window_x, window_y = ImGui.GetWindowPos()
        local icon_x = mouse_x - window_x + 10
        local icon_y = mouse_y - window_y + 10
        local stack_x = icon_x + COUNT_X_OFFSET
        local stack_y = icon_y + COUNT_Y_OFFSET
        local text_size = ImGui.CalcTextSize(tostring(cursor_item.Stack()))
        ImGui.SetCursorPos(icon_x, icon_y)
        animItems:SetTextureCell(cursor_item.Icon() - EQ_ICON_OFFSET)
        ImGui.DrawTextureAnimation(animItems, ICON_WIDTH, ICON_HEIGHT)
        if cursor_item.Stackable() then
            ImGui.SetCursorPos(stack_x, stack_y)
            ImGui.DrawTextureAnimation(animBox, text_size, ImGui.GetTextLineHeight())
            ImGui.SetCursorPos(stack_x - text_size, stack_y)
            ImGui.TextUnformatted(tostring(cursor_item.Stack()))
        end
    end
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

local scanItem = nil
local pauseScan = false

local itemDB

local itemList = {}
local totalItems = 0

local settings = {}

local config_pickle_path = mq.configDir .. '/bazaar/' .. ServerName .. '_ ' .. CharConfig .. '.lua '

local newAuctionPopup = "new_auction_popup"
local lastAuction = 0
local AuctionText = {}
local pauseAuctioning = true

local popupAuctionCost = ""
local popupAuctionItem = ""

local cachedPriceHistory = {}

local openPopup = false

-- first scan should be about 2 seconds after startup.
local lastFullScan = os.time() - ((60 * 30) - 2)



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
        for _, v in ipairs(settings.AuctionItems) do
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
    ['Channels']             = { Default = "auc", Tooltip = "| Seperated list of channels to auction to. ex: auc|6|7", },
    ['UnderCutPercent']      = { Default = 1, Tooltip = "Default undercut amount", },
    ['DefaultPrice']         = { Default = 2000000, Tooltip = "Default price", },
    ['DontUndercut']         = { Default = CharConfig .. "|", Tooltip = "| Seperated list of traders not to undercut. ex: Bob|Derple", },
    ['AuctionItems']         = { Default = {}, },
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

    if needSave then SaveSettings(true) end

    -- open the items db
    local items_db_file = 'items.db'
    itemDB = BazaarDB.new(mq.configDir .. '/bazaar/' .. items_db_file)
    itemDB:setupDB()

    return true
end

----------------------------------------------------------------|
-- Manage /trader window
--------------------------------------------------------------**|
local function traderWindowControl(status)
    print("\aySetting Trader window to \ag", status)
    if status == "Open" or status == "On" or status == "Off" then
        if not mq.TLO.Window("BazaarWnd").Open() then
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
        if mq.TLO.Window("BazaarWnd").Child(string.format("BZR_BazaarSlot%d", slot)).Tooltip():len() == 0 then break end
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
        if mq.TLO.Window("BazaarWnd").Child(string.format("BZR_BazaarSlot%d", slot)).Tooltip():len() == 0 then break end
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
    if curr == 0 or curr >= (best or 0) then
        if shouldUndercut(trader) then
            return math.ceil((best or 0) - (settings.UnderCutPercent / 100 * (best or 0)))
        else
            return best
        end
    end

    return curr
end

local function recalcTargetPrices()
    for _, itemData in pairs(itemList) do
        itemData["TargetPrice"] = calcTargetPrice((tonumber(itemData["LowestPrice"]) or 0),
            (tonumber(itemData["CurrentPrice"]) or -1), (itemData["Trader"] or "Unknown"))
    end
end

local function searchBazaar(itemName)
    bazaarSearchWindowControl("Open")
    mq.cmd("/breset")
    mq.cmd(string.format("/bzsrch \"%s\"", itemName))
    repeat
        mq.delay(1000)
        print("\awWaiting for bazaar cmd to finish...")
        ---@diagnostic disable-next-line: undefined-field
    until (mq.TLO.Bazaar() == "TRUE")

    if not mq.TLO.Window("BazaarSearchWnd").Child("BZR_ItemList").List(1, 3) then
        print("\arSearch failed, trying 1 more time...")
        mq.cmd("/bzquery")
    end

    local startSearchTime = os.clock()
    local found = 0
    while os.clock() - startSearchTime <= 30 and found == 0 do
        mq.delay(5)
        found = mq.TLO.Window("BazaarSearchWnd").Child("BZR_ItemList").List(1, 3)()
    end

    itemList[itemName] = itemList[itemName] or {}
    itemList[itemName]["LowestPrice"] = nil

    for searchResult = 1, 255 do
        local count = mq.TLO.Window("BazaarSearchWnd").Child("BZR_ItemList").List(searchResult, 3)()
        if count and count ~= "NULL" then
            local result = mq.TLO.Window("BazaarSearchWnd").Child("BZR_ItemList").List(searchResult, 2)()
            if result == itemName then
                local workingValue = NoComma(mq.TLO.Window("BazaarSearchWnd").Child("BZR_ItemList").List(searchResult, 4)())
                local trader = mq.TLO.Window("BazaarSearchWnd").Child("BZR_ItemList").List(searchResult, 8)()
                workingValue = tonumber(workingValue)
                print(string.format("Found seller: \am%s \axwith price: \ag%d", trader, workingValue))

                itemDB:cacheItemPrice(itemList[itemName]["DBID"], trader, workingValue)

                local LowestPrice = tonumber(itemList[itemName]["LowestPrice"]) or 2000000

                if workingValue <= LowestPrice then
                    itemList[itemName]["LowestPrice"] = workingValue
                    itemList[itemName]["Trader"] = trader
                    itemList[itemName]["TargetPrice"] = calcTargetPrice((tonumber(workingValue) or 0),
                        (tonumber(itemList[itemName]["CurrentPrice"]) or -1), trader)
                end
            end
        end
    end
    --items_db:exec("PRAGMA schema.wal_checkpoint;")
end

local cancelCheckPrices = false

local traderCheckPrices = function()
    print("\ayChecking current prices...")

    for currentItem, _ in pairs(itemList) do
        currentItemIdx = currentItemIdx + 1
        print(string.format(" - \ag%d\ax/\ag%d\ax item = \am%s", currentItemIdx, totalItems, currentItem))
        searchBazaar(currentItem)

        if cancelCheckPrices then
            cancelCheckPrices = false
            print("\arPrice Scan Canceled!")
            return
        end
    end

    print "\agPrice Scan Complete!"
end

local traderCheckItems = function()
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
end

local ColumnID_ItemIcon = 0
local ColumnID_Item = 1
local ColumnID_MyPrice = 2
local ColumnID_LowestPrice = 3
local ColumnID_BestTrader = 4
local ColumnID_ListedDate = 5
local ColumnID_TargetPrice = 6
local ColumnID_LAST = ColumnID_TargetPrice + 1

local genericSort = function(k1, k2, dir)
    if dir == 1 then
        return k1 < k2
    end
    return k1 > k2
end

local itemSorter = function(k1, k2, spec)
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
        if spec.ColumnUserID == ColumnID_TargetPrice then
            a = tonumber(i1["TargetPrice"] or 0)
            b = tonumber(i2["TargetPrice"] or 0)
        end
        if spec.ColumnUserID == ColumnID_TargetPrice then
            a = tonumber(i1["ListedDate"] or 0)
            b = tonumber(i2["ListedDate"] or 0)
        end
        if spec.ColumnUserID == ColumnID_BestTrader then
            a = (i1["Trader"] or "zUnknown")
            b = (i2["Trader"] or "zUnknown")
        end

        if a ~= b then return genericSort(a, b, spec.SortDirection) end

        return genericSort(k1, k2, spec.SortDirection)
    end

    return genericSort(k1, k2, 1)
end

local ColumnID_HistoryPrice = 0
local ColumnID_HistoryTrader = 1
local ColumnID_HistoryDate = 2
local ColumnID_HistoryLAST = ColumnID_HistoryDate + 1

---@param k1 table<any>: object 1 to sort
---@param k2 table<any>: object 2 to sort
---@param spec table<any>: sorting spec
---@return boolean
local historySorter = function(k1, k2, spec)
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
    local cursor_x, cursor_y = ImGui.GetCursorPos()

    animItems:SetTextureCell(iconID or 0)

    ImGui.DrawTextureAnimation(animItems, ICON_SIZE, ICON_SIZE)

    ImGui.SetCursorPos(cursor_x, cursor_y)

    ImGui.PushID(tostring(iconID) .. item.Name() .. "_invis_btn")
    ImGui.InvisibleButton(item.Name(), ImVec2(ICON_SIZE, ICON_SIZE),
        bit32.bor(ImGuiButtonFlags.MouseButtonLeft))
    if ImGui.IsItemHovered() and ImGui.IsMouseReleased(ImGuiMouseButton.Left) then
        item.Inspect()
    end
    ImGui.PopID()
end

local sortedItemKeys = {}

local function renderTraderUI()
    ImGui.PushStyleColor(ImGuiCol.Text, 0.0, 1.0, 0.0, 1)
    ImGui.Text("Bazaar running for %s", CharConfig)
    ImGui.PopStyleColor(1)

    if ImGui.Button("Open Trader", 150, 25) then
        traderWindowControl("Open")
    end

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

    if ImGui.Button("Scan Items", 150, 25) then
        doItemScan = true
        currentItemIdx = 0
        lastFullScan = os.time()
    end

    ImGui.SameLine()

    ImGui.PushStyleColor(ImGuiCol.Text, 0.3, 0.6, 0.6, 1.0)
    ImGui.Text(string.format("Next Scan in %s", FormatTime((60 * 30) - (os.time() - lastFullScan))))
    ImGui.PopStyleColor(1)

    ImGui.SameLine()

    pauseScan, _ = ImGui.Checkbox("Pause Scan Timer", pauseScan)

    ImGui.Separator()
    ImGui.Text("Trader Settings")
    local used
    settings.UnderCutPercent, used = ImGui.SliderInt("Undercut by Percent",
        settings.UnderCutPercent, 0, 90)
    if used then
        recalcTargetPrices()
        SaveSettings()
    end

    local newText, _ = ImGui.InputText("Default Price", tostring(settings.DefaultPrice),
        ImGuiInputTextFlags.CharsDecimal)
    ---@diagnostic disable-next-line: undefined-field
    if newText:len() > 0 and newText ~= tostring(settings.DefaultPrice) then
        settings.DefaultPrice = math.ceil(tonumber(newText) or 0)
        SaveSettings()
    end

    newText, _ = ImGui.InputText("Don't Undercut", settings.DontUndercut, ImGuiInputTextFlags.None)
    ---@diagnostic disable-next-line: undefined-field
    if newText:len() > 0 and newText ~= settings.DontUndercut then
        settings.DontUndercut = newText
        SaveSettings()
    end

    ImGui.Separator()
    ImGui.Text("Trader Items")
    if doItemScan then
        if not cancelCheckPrices then
            ImGui.Text("Scanning Progress:")
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
        ImGui.ProgressBar((currentItemIdx - 1) / (totalItems or 1))
    end

    if ImGui.BeginTable("ItemList", ColumnID_LAST, ImGuiTableFlags.Resizable + ImGuiTableFlags.Borders + ImGuiTableFlags.Sortable) then
        ImGui.PushStyleColor(ImGuiCol.Text, 255, 0, 255, 1)
        ImGui.TableSetupColumn('Icon', (ImGuiTableColumnFlags.NoSort + ImGuiTableColumnFlags.WidthFixed), 20.0,
            ColumnID_ItemIcon)
        ImGui.TableSetupColumn('Item',
            (ImGuiTableColumnFlags.DefaultSort + ImGuiTableColumnFlags.PreferSortDescending + ImGuiTableColumnFlags.WidthFixed),
            300.0, ColumnID_Item)
        ImGui.TableSetupColumn('My Price', ImGuiTableColumnFlags.None, 50.0, ColumnID_MyPrice)
        ImGui.TableSetupColumn('Lowest Price', ImGuiTableColumnFlags.None, 50.0, ColumnID_LowestPrice)
        ImGui.TableSetupColumn('Trader', ImGuiTableColumnFlags.None, 50.0, ColumnID_BestTrader)
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
        ImGui.TableNextRow()

        for _, currentItem in ipairs(sortedItemKeys) do
            local itemData = itemList[currentItem]

            ImGui.TableNextColumn()

            drawInspectableIcon((tonumber(itemData["IconID"]) or 500) - 500, itemData["ItemRef"])

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
            ImGui.Text(FormatInt(itemData["LowestPrice"]) or "Unknown")
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
            ImGui.PushID(currentItem .. "_text")
            local targetText = tostring(itemData["TargetPrice"] or settings.DefaultPrice)
            local newText, _ = ImGui.InputText("##targetinputtext##edit", targetText, ImGuiInputTextFlags.CharsDecimal)
            ---@diagnostic disable-next-line: undefined-field
            if newText:len() > 0 and newText ~= tostring(itemData["TargetPrice"]) then
                itemData["TargetPrice"] = math.ceil(tonumber(newText) or 0)
            end
            ImGui.PopID()
            ImGui.SameLine()
            ImGui.PushID(currentItem .. "_set_btn")
            if not setItem then
                if ImGui.SmallButton(string.format('%s', ICONS.FA_CHECK_CIRCLE)) then
                    setTraderPrice(currentItem, itemData["TargetPrice"])
                    itemData["CurrentPrice"] = itemData["TargetPrice"]
                    itemData["TargetPrice"] = calcTargetPrice((itemData["LowestPrice"] or 2000000),
                        (itemData["CurrentPrice"] or -1), (itemData["Trader"] or "Unknown"))
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
            Tooltip("Refresh Item")
        end
        ImGui.EndTable()
    end
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
        cachedPriceHistory.labels[os.time(GetDayTable(itemData.Date))] = cachedPriceHistory.labels[os.time(GetDayTable(itemData.Date))] or {}
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
        ImPlot.SetupAxesLimits(cachedPriceHistory.min_x - 36000, cachedPriceHistory.max_x + 36000, 0, cachedPriceHistory.max_y * 2, ImPlotCond.Always)
        ImPlot.SetupAxisScale(ImAxis.X1, ImPlotScale.Time)
        ImPlot.PlotScatter('Prices', cachedPriceHistory.xs, cachedPriceHistory.ys, #cachedPriceHistory.xs)
        ImPlot.PlotLine('Average', cachedPriceHistory.avg_xs, cachedPriceHistory.avg_ys, #cachedPriceHistory.avg_xs)
        ImPlot.EndPlot()
    end
    --ImGui.PlotLines('', cachedPriceHistory, #cachedPriceHistory, 0, "", 0, 2000, ImVec2(width, height))

    if ImGui.BeginTable("HistoryList", ColumnID_HistoryLAST, ImGuiTableFlags.Resizable + ImGuiTableFlags.Borders + ImGuiTableFlags.Sortable) then
        ImGui.PushStyleColor(ImGuiCol.Text, 255, 0, 255, 1)
        ImGui.TableSetupColumn('Price', ImGuiTableColumnFlags.None, 50.0, ColumnID_HistoryPrice)
        ImGui.TableSetupColumn('Trader', ImGuiTableColumnFlags.None, 50.0, ColumnID_HistoryTrader)
        ImGui.TableSetupColumn('Date', ImGuiTableColumnFlags.DefaultSort + ImGuiTableColumnFlags.PreferSortDescending,
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
            ImGui.Text(FormatInt(itemData["Price"]) or "Unknown")
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
                table.insert(settings.AuctionItems, { item = popupAuctionItem, cost = popupAuctionCost, })
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

local forceAuction = false
local doAuction = function(ignorePause)
    cacheItems()

    if not forceAuction then
        if pauseAuctioning and not ignorePause then
            return
        end
    end

    local tokens = Tokenize(settings.Channel, "|")

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

local addCursorItem = function()
    if mq.TLO.Cursor() ~= nil then
        popupAuctionItem = mq.TLO.Cursor() or ""
        openPopup = true
    end
end

local ICON_WIDTH = 50
local ICON_HEIGHT = 50

local function renderAuctionUI()
    if not settings then return end
    local used

    ImGui.Text("Auction Settings")
    settings.Timer, used = ImGui.SliderInt("Auction Timer", settings.Timer, 1, 10,
        "%d")
    if used then
        SaveSettings(false)
    end
    local newText, _ = ImGui.InputText("Auction Channel", settings.Channel,
        ImGuiInputTextFlags.None)
    ---@diagnostic disable-next-line: undefined-field
    if newText:len() > 0 and newText ~= settings.Channel then
        settings.Channel = newText
        SaveSettings(false)
    end
    ImGui.Separator()
    pauseAuctioning, _ = ImGui.Checkbox("Pause Auction", pauseAuctioning)
    ImGui.SetWindowFontScale(1.2)
    ImGui.PushStyleColor(ImGuiCol.Text, 255, 255, 0, 1)
    ImGui.Text("Count Down: %ds", (settings.Timer * 60) - (os.clock() - lastAuction))
    ImGui.PopStyleColor()
    if ImGui.Button("Auction Now!") then
        forceAuction = true
    end

    ImGui.Separator()

    ImGui.PushStyleColor(ImGuiCol.Text, 0, 100, 255, 1)
    ImGui.Text("Auction Items")
    ImGui.SetWindowFontScale(1)

    ImGui.BeginTable("Items", 4, ImGuiTableFlags.Resizable + ImGuiTableFlags.Borders)

    ImGui.TableSetupColumn('Item', ImGuiTableColumnFlags.None, 250)
    ImGui.TableSetupColumn('Cost', ImGuiTableColumnFlags.None, 50.0)
    ImGui.TableSetupColumn('Active', ImGuiTableColumnFlags.None, 50.0)
    ImGui.TableSetupColumn('', ImGuiTableColumnFlags.None, 50.0)
    ImGui.TableHeadersRow()
    ImGui.PopStyleColor()
    if (settings) then
        for idx, v in ipairs(settings.AuctionItems or {}) do
            ImGui.TableNextColumn()
            local _, clicked = ImGui.Selectable(v.item, false)
            if clicked then
                popupAuctionItem = v.item
                popupAuctionCost = v.cost
                openPopup = true
            end
            ImGui.TableNextColumn()
            ImGui.Text(v.item)
            ImGui.TableNextColumn()
            ImGui.PushID(idx .. "_togg_btn")
            if ImGui.SmallButton(ICONS.FA_TOGGLE_ON) then
                table.insert(settings.DisabledAuctionItems, settings.AuctionItems[idx])
                settings.AuctionItems[idx] = nil
                SaveSettings(true)
                cacheItems()
            end
            ImGui.PopID()
            ImGui.TableNextColumn()
            ImGui.PushID(idx .. "_trash_btn")
            if ImGui.SmallButton(ICONS.FA_TRASH) then
                settings.AuctionItems[idx] = nil
                SaveSettings(true)
            end
            ImGui.PopID()
        end
        for idx, v in ipairs(settings.DisabledAuctionItems or {}) do
            ImGui.TableNextColumn()
            local _, clicked = ImGui.Selectable(v.item, false)
            if clicked then
                popupAuctionItem = v.item
                popupAuctionCost = v.cost
                openPopup = true
            end
            ImGui.TableNextColumn()
            ImGui.Text(v.item)
            ImGui.TableNextColumn()
            ImGui.PushID(idx .. "_togg_btn")
            if ImGui.SmallButton(ICONS.FA_TOGGLE_OFF) then
                table.insert(settings.AuctionItems, settings.DisabledAuctionItems[idx])
                settings.DisabledAuctionItems[idx] = nil
                SaveSettings(true)
            end
            ImGui.PopID()
            ImGui.TableNextColumn()
            ImGui.PushID(idx .. "_trash_btn")
            if ImGui.SmallButton(ICONS.FA_TRASH) then
                settings.DisabledAuctionItems[idx] = nil
                SaveSettings(true)
            end
            ImGui.PopID()
        end
    end
    ImGui.EndTable()
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

    if not pauseAuctioning and GetTableSize(settings or {}) == 0 then
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
        display_item_on_cursor()

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

LoadSettings()

mq.imgui.init('bazaarGUI', BazaarGUI)

bazaarSearchWindowControl("Open")
traderWindowControl("Open")

while openGUI do
    if pauseScan then
        lastFullScan = os.time()
    end

    if os.time() - lastFullScan >= (60 * 30) then
        doItemScan = true
        currentItemIdx = 0
        lastFullScan = os.time()
    end

    traderCheckItems()
    asyncSetTraderPrice()
    asyncAuctionUpdate()
    itemDB:GiveTime()

    mq.doevents()
    mq.delay(10)
end

itemDB:Shutdown()
