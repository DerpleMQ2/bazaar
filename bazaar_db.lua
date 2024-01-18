local BazaarDB = { _version = '1.0', author = 'Derple', }
BazaarDB.__index = BazaarDB

local mq = require('mq')
local sqlite = require('lsqlite3')

local function dump(o)
    if type(o) == 'table' then
        local s = '{ '
        for k, v in pairs(o) do
            if type(k) ~= 'number' then k = '"' .. k .. '"' end
            s = s .. '[\ay' .. k .. '\ax] = \am' .. dump(v) .. '\ax,'
        end
        return s .. '} '
    else
        return tostring(o)
    end
end

---@param t any
---@return table
function BazaarDB.new(t)
    local newBazaarDB = setmetatable(
        { itemPriceCache = {}, itemListedTimeCache = {}, historicalSales = {}, historicalItem = nil, DB = sqlite.open(t), },
        BazaarDB)
    return newBazaarDB
end

function BazaarDB:dbStartTransaction()
    if not self["DB"] then return end

    local res = 0
    repeat
        res = self["DB"]:exec("BEGIN IMMEDIATE TRANSACTION;")
        if res == sqlite.BUSY then
            mq.delay(1000)
            print("\ayWaiting for DB Lock...")
        end
    until res ~= sqlite.BUSY

    print("\agStarting DB Transaction")
end

function BazaarDB:dbCompleteTransaction()
    if not self["DB"] then return end

    self["DB"]:exec("COMMIT;")
    print("\agCommitted DB Transaction")
end

function BazaarDB:setupDB()
    if not self["DB"] then return end

    self["DB"]:exec("PRAGMA journal_mode=WAL;")

    assert(self["DB"]:exec "CREATE TABLE IF NOT EXISTS items (item_id INTEGER PRIMARY KEY AUTOINCREMENT, server_name TEXT NOT NULL, item_name TEXT NOT NULL);")
    assert(self["DB"]:exec "CREATE TABLE IF NOT EXISTS item_prices (price_id INTEGER PRIMARY KEY AUTOINCREMENT, item_id INTEGER NOT NULL, seller_name TEXT NOT NULL, price INTEGER NOT NULL, seen_date INTEGER NOT NULL);")
    assert(self["DB"]:exec "CREATE TABLE IF NOT EXISTS item_listed (listed_id INTEGER PRIMARY KEY AUTOINCREMENT, item_id INTEGER NOT NULL, price INTEGER NOT NULL, listed_date INTEGER NOT NULL);")
end

function BazaarDB:queryItemDBId(itemName)
    local query_item_stmt = assert(self["DB"]:prepare "SELECT * FROM items WHERE server_name=? AND item_name=?;")
    query_item_stmt:bind(1, mq.TLO.MacroQuest.Server())
    query_item_stmt:bind(2, itemName)

    for row in query_item_stmt:nrows() do
        return tonumber(row.item_id)
    end

    print(string.format("\arItem not found: %s on %s", itemName, mq.TLO.MacroQuest.Server()))
    return nil
end

function BazaarDB:insertItem(itemName)
    local insert_item_stmt = assert(self["DB"]:prepare "INSERT INTO items VALUES (NULL, :server, :item);")
    insert_item_stmt:bind_names { server = mq.TLO.MacroQuest.Server(), item = itemName, }
    insert_item_stmt:step()
    insert_item_stmt:reset()
    insert_item_stmt:finalize()
    return self:queryItemDBId(itemName)
end

function BazaarDB:getItemDBId(itemName)
    local dbid = self:queryItemDBId(itemName)

    if dbid then return dbid end

    -- Not in DB Add it.
    self:dbStartTransaction()
    dbid = self:insertItem(itemName)
    self:dbCompleteTransaction()

    printf("\ayCreated item in DB \at%s \ay(\am%d\ay)", itemName, dbid)

    return dbid
end

function BazaarDB:insertPrice(values)
    local insert_item_stmt = assert(self["DB"]:prepare "INSERT INTO item_prices VALUES (NULL, :item_id, :seller, :price, :date);")
    insert_item_stmt:bind_names(values)
    insert_item_stmt:step()
    insert_item_stmt:reset()
    local result = insert_item_stmt:finalize()

    print(string.format("Insert Price %s Result: \ay%d", dump(values), result))
end

function BazaarDB:cacheItemPrice(dbid, seller, price)
    table.insert(self["itemPriceCache"], { item_id = dbid, seller = seller, price = price, date = os.time(), })
end

function BazaarDB:writeItemPriceCache()
    if #self["itemPriceCache"] == 0 then return end

    self:dbStartTransaction()

    for k, v in ipairs(self["itemPriceCache"]) do
        self:insertPrice(v)
    end

    self:dbCompleteTransaction()

    self["itemPriceCache"] = {}
end

function BazaarDB:getItemListedTime(dbid)
    local query_item_stmt = assert(self["DB"]:prepare "SELECT listed_date FROM item_listed WHERE item_id=? ORDER BY listed_date ASC;")
    query_item_stmt:bind(1, dbid)

    local last_date = nil
    for date in query_item_stmt:urows() do
        --print(string.format("Found listed time: \ay%s\ax for \at%s", date, itemName))
        last_date = date
    end

    --print(string.format("\arItem list not found: %s", itemName))
    return last_date
end

function BazaarDB:insertItemListedTime(values)
    local insert_item_stmt = assert(self["DB"]:prepare "INSERT INTO item_listed VALUES (NULL, :item_id, :price, :listed_date);")
    insert_item_stmt:bind_names(values)
    insert_item_stmt:step()
    insert_item_stmt:reset()
    local result = insert_item_stmt:finalize()

    print(string.format("Insert Listed Time %s Result: \ay%d", dump(values), result))

    return
end

function BazaarDB:writeItemListedCache()
    if #self["itemListedTimeCache"] == 0 then return end

    self:dbStartTransaction()

    for k, v in ipairs(self["itemListedTimeCache"]) do
        self:insertItemListedTime(v)
    end

    self:dbCompleteTransaction()

    self["itemListedTimeCache"] = {}
end

function BazaarDB:cacheItemListedTime(dbid, price, date)
    table.insert(self["itemListedTimeCache"], { item_id = dbid, price = price, listed_date = date, })
end

function BazaarDB:clearHistoricalData()
    self["historicalSales"] = {}
    self["historicalItem"] = nil
end

function BazaarDB:loadHistoricalData(itemName, dbid)
    local query_item_stmt = assert(self["DB"]:prepare "SELECT seller_name, price, seen_date FROM item_prices WHERE item_id=?;")
    query_item_stmt:bind(1, dbid)

    printf("\ayLoading \at%s \ay(\am%d\ay)", itemName, dbid)
    self["historicalItem"] = itemName
    self["historicalSales"] = {}

    for trader, price, date in query_item_stmt:urows() do
        table.insert(self["historicalSales"], { Trader = trader, Price = price, Date = date, })
    end

    return
end

function BazaarDB:getHistoricalData()
    return self["historicalItem"], self["historicalSales"]
end

function BazaarDB:GiveTime()
    self:writeItemListedCache()
    self:writeItemPriceCache()
end

function BazaarDB:Shutdown()
    self["DB"]:close()
    self["DB"] = nil
end

return BazaarDB
