--[[
    AutoABarz — тот же ABarz + автообновление с GitHub.
    /abarz  /abscan  /carprice  /abchat  /abupdate
    Репозиторий: github.com/andergr0ynd/autoabarz  (ветка main)
    Файлы: autoabarz.lua  version.json
]]

script_name('AutoABarz')
script_author('pechkin')
script_version('v1.6.63')
script_description('Автобазар Arizona: цены, продажи, сделки, автообновление GitHub')
require 'lib.moonloader'
local bit = require 'bit'
local ffi = require 'ffi'
local encoding = require 'encoding'
encoding.default = 'CP1251'
local u8 = encoding.UTF8

local ok_imgui, imgui = pcall(require, 'mimgui')
if not ok_imgui then
    function main()
        while not isSampAvailable() do wait(0) end
        sampAddChatMessage('{FF5C7A}[ABarz] {FFFFFF}Нужен mimgui', -1)
    end
    return
end

local ok_arz, arz = pcall(require, 'arizona-events')
local ok_cef, cefDlg = pcall(require, 'arizona-cef-dialogs')
if not ok_cef then cefDlg = nil end
local ok_ev, ev = pcall(require, 'samp.events')
if not ok_ev then ok_ev, ev = pcall(require, 'lib.samp.events') end

local new = imgui.new
local TAG = '{5B8CFF}[ABarz] {FFFFFF}'

local function is_valid_utf8(s)
    if type(s) ~= 'string' then return false end
    local i, n = 1, #s
    while i <= n do
        local b = s:byte(i)
        if not b then return false end
        if b < 0x80 then
            i = i + 1
        elseif b >= 0xC2 and b <= 0xDF then
            local b2 = s:byte(i + 1)
            if not b2 or b2 < 0x80 or b2 > 0xBF then return false end
            i = i + 2
        elseif b >= 0xE0 and b <= 0xEF then
            local b2, b3 = s:byte(i + 1, i + 2)
            if not b2 or not b3 or b2 < 0x80 or b2 > 0xBF or b3 < 0x80 or b3 > 0xBF then return false end
            i = i + 3
        elseif b >= 0xF0 and b <= 0xF4 then
            local b2, b3, b4 = s:byte(i + 1, i + 3)
            if not b2 or not b3 or not b4 or b2 < 0x80 or b2 > 0xBF or b3 < 0x80 or b3 > 0xBF or b4 < 0x80 or b4 > 0xBF then return false end
            i = i + 4
        else
            return false
        end
    end
    return true
end

-- UTF-8 не трогаем; CP1251 → UTF-8
local function ensure_utf8(text)
    if text == nil then return '' end
    text = tostring(text)
    if text == '' then return '' end
    if is_valid_utf8(text) then return text end
    local ok, encoded = pcall(u8, text)
    return (ok and encoded) or text
end

-- Чинит только явный двойной UTF-8 («РЎРє…»), обычный русский не трогает
local function repair_mojibake(s)
    if type(s) ~= 'string' or s == '' then return s end
    if not is_valid_utf8(s) then return ensure_utf8(s) end
    local n, i, len = 0, 1, #s
    while i <= len - 3 do
        local a, b, c = s:byte(i, i + 2)
        -- UTF-8 «Р»/«С» сразу перед следующим кириллическим стартом — типичный mojibake
        if a == 208 and (b == 160 or b == 161) and (c == 208 or c == 209) then
            n = n + 1
            i = i + 2
        else
            i = i + 1
        end
    end
    if n < 3 then return s end
    local ok, as_bytes = pcall(u8.decode, u8, s)
    if ok and type(as_bytes) == 'string' and as_bytes ~= s and is_valid_utf8(as_bytes) then
        if as_bytes:find('[\208\209]') then
            return as_bytes
        end
    end
    return s
end

local function d(text)
    if type(text) ~= 'string' or text == '' then return text or '' end
    text = repair_mojibake(ensure_utf8(text))
    local ok, out = pcall(u8.decode, u8, text)
    return (ok and out) or text
end

local function chat(msg)
    if isSampAvailable() then
        sampAddChatMessage(TAG .. d(tostring(msg)), -1)
    end
end

local function ensureDir(path)
    if not doesDirectoryExist(path) then createDirectory(path) end
end

-- MoonLoader CJSON падает на [] («T_ARR_END at character 3») и может убить корутину
local function safeDecodeJson(raw)
    if type(raw) ~= 'string' then return false, nil end
    local s = raw:gsub('^%s+', ''):gsub('%s+$', '')
    if s == '' or s == 'null' then return false, nil end
    local first = s:sub(1, 1)
    if first ~= '{' and first ~= '[' then return false, nil end
    if first == '[' and s:match('^%[%s*%]') then
        return true, {}
    end
    local ok, data = pcall(decodeJson, s)
    if not ok or data == nil then return false, nil end
    return true, data
end

local DATA_DIR = getWorkingDirectory() .. '\\config\\abarz'
local DATA_FILE = DATA_DIR .. '\\prices.json'
local LOGS_FILE = DATA_DIR .. '\\deals.json'
local dealLogs = {}
local knownPlates = {}
local incomingChat = {}
local incomingDlg = {}
local incomingCef = {}
local pendingBuy = { active = false, model = '', price = 0, t = 0, source = '' }
local pendingSell = { active = false, model = '', price = 0, t = 0, at = 0, source = '', muteNtfy = 0 }
local needBuySnapshot = false
local needSellSnapshot = false
ensureDir(DATA_DIR)

local waitPageMs = new.int(0)
local notifyNewSales = new.bool(true)
local showPassportAvg = new.bool(true)
local MAX_DAYS = 30
local MAX_PAGES_SAFETY = 40
local DIALOG_LIST_ID = 15376
local DIALOG_DAYS_ID = 15377
local DIALOG_PASSPORT_ID = 25218
---------------------------------------------------------------------------
-- База:
-- prices[name] = {
--   price = 123456,          -- средняя / последняя
--   days = { {date="2026-09-01", price=100}, ... },
--   updated = os.time()
-- }
---------------------------------------------------------------------------
local prices = {}
local priceList = {}
local selectedName = nil
local scanState = {
    active = false,
    index = 0,
    currentName = nil,
    dlg = nil,
    dlgSeq = 0,
    lastFinger = '',
    forceDlg = false,
    listUntil = 0,
    menuVk = 0x72,
    chatVk = 0x74,
    mouseVk = 0x12,
    bindWait = nil,
    httpJobs = {},
}

scanState.menuBindOn = new.bool(true)
scanState.chatBindOn = new.bool(true)
scanState.mouseBindOn = new.bool(true)
scanState.autoUpdateOn = new.bool(true)
scanState.bindHeld = {}
scanState.gitlabRaw = 'https://raw.githubusercontent.com/andergr0ynd/autoabarz/refs/heads/main/'
scanState.gitlabToken = ''
scanState.updateBusy = false

local scanFab = { pollAt = 0, pollBusy = false, cmd = '' }

local function normalizeName(name)
    name = repair_mojibake(ensure_utf8(tostring(name or '')))
    name = name:gsub('^%s+', ''):gsub('%s+$', '')
    name = name:gsub('{......}', '')
    -- валютные хвосты из списка АБ
    name = name:gsub('[\t ]*:CASH%s*$', '')
    name = name:gsub('[\t ]*:DONATE%s*$', '')
    name = name:gsub('[\t ]*:KK:%s*$', '')
    name = name:gsub('[\t ]*:K:%s*$', '')
    name = name:gsub('[\t\r\n]+', ' ')
    name = name:gsub('%s+', ' ')
    name = name:gsub('^%s+', ''):gsub('%s+$', '')
    return name
end

local function cleanPriceNum(v)
    if type(v) == 'string' then
        v = v:gsub('%s+', ''):gsub('%$', ''):gsub('%.', ''):gsub(',', '')
    end
    v = tonumber(v)
    if not v or v <= 0 or v > 2147483647 then return nil end
    return math.floor(v)
end

local function stripColors(s)
    return tostring(s or ''):gsub('{......}', '')
end

local function parseCashToken(s)
    s = tostring(s or '')
    local p = s:match(':CASH:(%d[%d%.,%s]*)') or s:match(':DONATE:(%d[%d%.,%s]*)')
    if p then return cleanPriceNum(p) end
    return cleanPriceNum(s)
end

local function dateOffset(daysAgo)
    daysAgo = tonumber(daysAgo) or 0
    local t = os.time() - daysAgo * 86400
    return os.date('%Y-%m-%d', t)
end

local function ensureCar(name)
    name = normalizeName(name)
    if name == '' then return nil end
    if not prices[name] then
        prices[name] = { price = 0, days = {}, updated = os.time() }
    end
    if type(prices[name].days) ~= 'table' then
        prices[name].days = {}
    end
    return name, prices[name]
end

local function avgFromDays(days)
    if type(days) ~= 'table' or #days == 0 then return 0 end
    local sum, n = 0, 0
    for _, row in ipairs(days) do
        local p = tonumber(row.price)
        if p and p > 0 then
            sum = sum + p
            n = n + 1
        end
    end
    if n == 0 then return 0 end
    return math.floor(sum / n + 0.5)
end

local function setDayPrice(name, dateStr, price)
    name = normalizeName(name)
    dateStr = tostring(dateStr or ''):gsub('^%s+', ''):gsub('%s+$', '')
    price = cleanPriceNum(price)
    if name == '' or dateStr == '' or not price then return false end

    local _, info = ensureCar(name)
    if not info then return false end

    if scanState.active then
        scanState.currentName = name
    end

    local found = false
    local changed = false
    for _, row in ipairs(info.days) do
        if tostring(row.date) == dateStr then
            if tonumber(row.price) ~= price then
                row.price = price
                changed = true
            end
            found = true
            break
        end
    end
    if not found then
        info.days[#info.days + 1] = { date = dateStr, price = price }
        changed = true
    end

    table.sort(info.days, function(a, b) return tostring(a.date) > tostring(b.date) end)
    while #info.days > MAX_DAYS do
        table.remove(info.days)
    end
    info.price = avgFromDays(info.days)
    if info.price == 0 then info.price = price end
    info.updated = os.time()
    if changed then
        scanState.pricesDirty = true
        scanState.saveAt = os.clock() + 1.2
    end
    return true
end

local function setPrice(name, price)
    name = normalizeName(name)
    price = cleanPriceNum(price)
    if name == '' or not price then return false end

    local _, info = ensureCar(name)
    if not info then return false end

    if scanState.active then
        scanState.currentName = name
    end

    if tonumber(info.price) == price and #(info.days or {}) > 0 then
        info.updated = os.time()
        return false
    end
    if #(info.days or {}) == 0 then
        info.price = price
    else
        info.price = avgFromDays(info.days)
        if info.price == 0 then info.price = price end
    end
    info.updated = os.time()
    scanState.pricesDirty = true
    scanState.saveAt = os.clock() + 1.2
    return true
end

local function rebuildList()
    local fixed = {}
    for name, info in pairs(prices) do
        local good = normalizeName(name)
        if good ~= '' then
            if fixed[good] then
                local dst = fixed[good]
                dst.price = tonumber(info.price) or dst.price
                if type(info.days) == 'table' then
                    dst.days = dst.days or {}
                    for _, row in ipairs(info.days) do
                        dst.days[#dst.days + 1] = row
                    end
                end
                dst.updated = math.max(tonumber(dst.updated) or 0, tonumber(info.updated) or 0)
            else
                if type(info) == 'table' then
                    info.days = info.days or {}
                    fixed[good] = info
                end
            end
        end
    end
    prices = fixed

    priceList = {}
    for name, info in pairs(prices) do
        priceList[#priceList + 1] = {
            name = name,
            price = tonumber(info.price) or avgFromDays(info.days) or 0,
            days = (info.days and #info.days) or 0,
            updated = tonumber(info.updated) or 0,
        }
    end
    table.sort(priceList, function(a, b) return a.name:lower() < b.name:lower() end)
end

local function migrateEntry(name, v)
    name = normalizeName(name)
    if name == '' then return end
    if type(v) == 'number' then
        prices[name] = { price = v, days = {}, updated = os.time() }
    elseif type(v) == 'table' then
        local days = {}
        if type(v.days) == 'table' then
            for _, row in ipairs(v.days) do
                if type(row) == 'table' then
                    days[#days + 1] = {
                        date = tostring(row.date or row.day or row.d or ''),
                        price = tonumber(row.price or row.avg or row.p or 0) or 0,
                    }
                end
            end
        end
        local price = tonumber(v.price or v.avg or v.average) or avgFromDays(days)
        prices[name] = { price = price or 0, days = days, updated = tonumber(v.updated) or os.time() }
    end
end

local function loadPrices()
    prices = {}
    if doesFileExist(DATA_FILE) then
        local f = io.open(DATA_FILE, 'r')
        if f then
            local raw = f:read('*a')
            f:close()
            local ok, data = safeDecodeJson( raw)
            if ok and type(data) == 'table' then
                local src = data.prices or data
                for k, v in pairs(src) do
                    if type(k) == 'string' then migrateEntry(k, v) end
                end
            end
        end
    end
    rebuildList()
end

-- один раз чистим старые "Firebird\t:CASH"
local function cleanupCurrencyNames()
    local changed = false
    local fixed = {}
    for name, info in pairs(prices) do
        local good = normalizeName(name)
        if good ~= '' then
            if fixed[good] then
                local dst = fixed[good]
                dst.price = tonumber(info.price) or dst.price
                if type(info.days) == 'table' then
                    dst.days = dst.days or {}
                    for _, row in ipairs(info.days) do
                        dst.days[#dst.days + 1] = row
                    end
                end
            else
                info.days = info.days or {}
                fixed[good] = info
            end
            if good ~= name then changed = true end
        end
    end
    if changed then
        prices = fixed
        rebuildList()
        savePrices()
    end
end

local function savePrices()
    ensureDir(DATA_DIR)
    local f = io.open(DATA_FILE, 'w')
    if not f then return end
    f:write(encodeJson({ version = 2, prices = prices, saved_at = os.time() }))
    f:close()
    scanState.pricesDirty = false
end

local function mergeImportedCar(name, info)
    name = normalizeName(name)
    if name == '' or type(info) ~= 'table' then return false end
    local incomingDays = info.days
    if type(incomingDays) ~= 'table' then incomingDays = {} end
    if not prices[name] then
        prices[name] = {
            price = tonumber(info.price) or 0,
            days = incomingDays,
            updated = tonumber(info.updated) or os.time(),
        }
        return true
    end
    local dst = prices[name]
    dst.days = dst.days or {}
    local byDate = {}
    for _, row in ipairs(dst.days) do
        byDate[tostring(row.date)] = row
    end
    for _, row in ipairs(incomingDays) do
        if type(row) == 'table' then
            local date = tostring(row.date or '')
            local price = tonumber(row.price) or 0
            if date ~= '' and price > 0 then
                if byDate[date] then
                    byDate[date].price = price
                else
                    dst.days[#dst.days + 1] = { date = date, price = price }
                    byDate[date] = dst.days[#dst.days]
                end
            end
        end
    end
    local p = tonumber(info.price) or 0
    if p > 0 then dst.price = p end
    table.sort(dst.days, function(a, b)
        return tostring(a.date or '') > tostring(b.date or '')
    end)
    dst.updated = os.time()
    return true
end

local function buildShareJson()
    local pack = {}
    local n = 0
    for name, info in pairs(prices) do
        local days = {}
        if type(info.days) == 'table' then
            for i = 1, math.min(#info.days, MAX_DAYS) do
                local row = info.days[i]
                local date = tostring(row.date or '')
                local price = tonumber(row.price) or 0
                if date ~= '' and price > 0 then
                    days[#days + 1] = { date, price }
                end
            end
        end
        pack[name] = { p = tonumber(info.price) or 0, d = days }
        n = n + 1
    end
    return encodeJson({ abarz = 1, t = os.time(), n = n, p = pack }), n
end

local function importPricesFromText(raw)
    raw = tostring(raw or ''):gsub('^\239\187\191', ''):gsub('^%s+', ''):gsub('%s+$', '')
    if raw == '' then return 0, 'пусто' end
    if raw:find('<html', 1, true) or raw:find('<HTML', 1, true) then
        return 0, 'ссылка открылась как страница, не как база'
    end
    if raw:sub(1, 1) ~= '{' then
        local a = raw:find('{', 1, true)
        local b = raw:match('.*()}' )
        if a and b and b > a then
            raw = raw:sub(a, b)
        end
    end
    local ok, data = safeDecodeJson( raw)
    if not ok or type(data) ~= 'table' then
        return 0, 'не получилось прочитать базу'
    end

    local src = nil
    if tonumber(data.abarz) == 1 and type(data.p) == 'table' then
        src = {}
        for name, row in pairs(data.p) do
            if type(name) == 'string' and type(row) == 'table' then
                local days = {}
                local d = row.d or row.days
                if type(d) == 'table' then
                    for _, pair in ipairs(d) do
                        if type(pair) == 'table' then
                            days[#days + 1] = {
                                date = tostring(pair[1] or pair.date or ''),
                                price = tonumber(pair[2] or pair.price) or 0,
                            }
                        end
                    end
                end
                src[name] = {
                    price = tonumber(row.p or row.price) or 0,
                    days = days,
                    updated = tonumber(data.t) or os.time(),
                }
            end
        end
    elseif type(data.prices) == 'table' then
        src = data.prices
    else
        src = data
    end
    if type(src) ~= 'table' then return 0, 'в ссылке нет машин' end

    local added = 0
    for name, v in pairs(src) do
        if type(name) == 'string'
            and name ~= 'version' and name ~= 'saved_at' and name ~= 'abarz'
            and name ~= 't' and name ~= 'n' and name ~= 'p' and name ~= 'prices'
        then
            if type(v) == 'number' then
                v = { price = v, days = {}, updated = os.time() }
            end
            if type(v) == 'table' and mergeImportedCar(name, v) then
                added = added + 1
            end
        end
    end
    if added == 0 then return 0, 'в ссылке нет машин' end
    rebuildList()
    savePrices()
    return added, nil
end

local function saveDealLogs()
    ensureDir(DATA_DIR)
    local f = io.open(LOGS_FILE, 'w')
    if not f then return end
    local listed
    if pendingSell.active and tonumber(pendingSell.price) and pendingSell.price > 0 then
        listed = {
            model = tostring(pendingSell.model or ''),
            price = pendingSell.price,
            at = tonumber(pendingSell.at) or os.time(),
            source = tostring(pendingSell.source or ''),
        }
    end
    f:write(encodeJson({ version = 2, deals = dealLogs, listed = listed, saved_at = os.time() }))
    f:close()
end

local function forgetListed()
    pendingSell.active = false
    pendingSell.model = ''
    pendingSell.price = 0
    pendingSell.at = 0
    pendingSell.source = ''
    pendingSell.dropListed = false
    saveDealLogs()
end

local function loadDealLogs(keepListed)
    dealLogs = {}
    if not doesFileExist(LOGS_FILE) then
        pendingSell.muteNtfy = os.clock() + 12
        return
    end
    local f = io.open(LOGS_FILE, 'r')
    if not f then return end
    local raw = f:read('*a')
    f:close()
    local ok, data = safeDecodeJson( raw)
    if not ok or type(data) ~= 'table' then return end
    local src = data.deals or data
    if type(src) == 'table' then
        for _, row in ipairs(src) do
            if type(row) == 'table' then
                dealLogs[#dealLogs + 1] = {
                    action = tostring(row.action or 'buy'),
                    model = tostring(row.model or 'Транспорт'),
                    price = tonumber(row.price) or 0,
                    time = tonumber(row.time or 0) or os.time(),
                    source = tostring(row.source or ''),
                }
            end
        end
    end
    if keepListed then
        local listed = data.listed
        if type(listed) == 'table' then
            local price = tonumber(listed.price) or 0
            local at = tonumber(listed.at) or 0
            if price > 0 and at > 0 and (os.time() - at) < 43200 then
                pendingSell.active = true
                pendingSell.model = tostring(listed.model or '')
                pendingSell.price = price
                pendingSell.source = tostring(listed.source or 'saved')
                pendingSell.at = at
                pendingSell.t = os.clock()
            end
        end
    end
    pendingSell.muteNtfy = os.clock() + 12
end

local function fmtMoney(n)
    n = math.floor(tonumber(n) or 0)
    local s = tostring(n)
    local left, num, right = s:match('^([^%d]*%d)(%d*)(.-)$')
    if not left then return '$' .. s end
    return '$' .. left .. (num:reverse():gsub('(%d%d%d)', '%1.'):reverse()) .. right
end

local function findPrices(query)
    query = tostring(query or ''):lower()
    local out = {}
    for _, row in ipairs(priceList) do
        if query == '' or row.name:lower():find(query, 1, true) then
            out[#out + 1] = row
        end
    end
    return out
end

---------------------------------------------------------------------------
-- Парсинг
---------------------------------------------------------------------------
local function looksLikeDate(s)
    s = tostring(s or '')
    return s:match('^%d%d%d%d%-%d%d%-%d%d')
        or s:match('^%d%d%.%d%d%.%d%d%d%d')
        or s:match('^%d%d%/%d%d%/%d%d%d%d')
        or s:match('^%d%d%.%d%d$')
        or s:match('^%d%d%-%d%d$')
end

local function normalizeDate(s)
    s = tostring(s or ''):gsub('^%s+', ''):gsub('%s+$', '')
    local d, m, y = s:match('^(%d%d)%.(%d%d)%.(%d%d%d%d)$')
    if d then return ('%s-%s-%s'):format(y, m, d) end
    d, m, y = s:match('^(%d%d)/(%d%d)/(%d%d%d%d)$')
    if d then return ('%s-%s-%s'):format(y, m, d) end
    d, m = s:match('^(%d%d)%.(%d%d)$')
    if d then
        local yyyy = os.date('%Y')
        return ('%s-%s-%s'):format(yyyy, m, d)
    end
    return s
end

local function harvestDaysFromJson(node, carHint, depth)
    depth = depth or 0
    if depth > 12 or type(node) ~= 'table' then return end

    local name = node.name or node.title or node.model or node.car or node.vehicle
        or node.modelName or node.carName or node.label or node.n or carHint
    if name then name = normalizeName(tostring(name)) end

    local date = node.date or node.day or node.time or node.dt or node.d or node.label
    local price = node.price or node.avg or node.average or node.avgPrice
        or node.averagePrice or node.cost or node.value or node.p or node.middle
        or node.y or node.sum or node.amount

    if name and date and price and looksLikeDate(date) then
        setDayPrice(name, normalizeDate(date), price)
    elseif name and price and not date then
        setPrice(name, price)
    elseif date and price and looksLikeDate(date) and (carHint or scanState.currentName) then
        setDayPrice(carHint or scanState.currentName, normalizeDate(date), price)
    end

    -- массив чисел = точки графика за ~30 дней
    local hist = node.history or node.days or node.chart or node.graph
        or node.points or node.values or node.sales or node.data or node.prices
    if name and type(hist) == 'table' then
        local numeric = true
        local nums = {}
        for i, item in ipairs(hist) do
            if type(item) == 'number' then
                nums[#nums + 1] = item
            elseif type(item) == 'string' and tonumber((item:gsub('[^%d]', ''))) then
                nums[#nums + 1] = tonumber((item:gsub('[^%d]', '')))
            else
                numeric = false
                break
            end
            if i > MAX_DAYS then break end
        end
        if numeric and #nums >= 3 then
            for i, p in ipairs(nums) do
                local ago = #nums - i
                setDayPrice(name, dateOffset(ago), p)
            end
        else
            for i, item in ipairs(hist) do
                if type(item) == 'table' then
                    harvestDaysFromJson(item, name or carHint, depth + 1)
                elseif type(item) == 'number' then
                    setDayPrice(name, dateOffset(#hist - i), item)
                end
            end
        end
    end

    if type(node[1]) == 'table' then
        for _, item in ipairs(node) do
            harvestDaysFromJson(item, name or carHint, depth + 1)
        end
    end
    for k, v in pairs(node) do
        if type(k) ~= 'number' and type(v) == 'table' then
            harvestDaysFromJson(v, name or carHint, depth + 1)
        end
    end
end

local function regexHarvest(text, carHint)
    if type(text) ~= 'string' then return end
    carHint = carHint or scanState.currentName
    text = repair_mojibake(ensure_utf8(text))

    -- "date":"2026-09-01","price":123
    for date, price in text:gmatch('"date"%s*:%s*"([^"]+)"%s*,%s*"price"%s*:%s*(%d+)') do
        if carHint then setDayPrice(carHint, normalizeDate(date), price) end
    end
    for price, date in text:gmatch('"price"%s*:%s*(%d+)%s*,%s*"date"%s*:%s*"([^"]+)"') do
        if carHint then setDayPrice(carHint, normalizeDate(date), price) end
    end
    for date, price in text:gmatch('"day"%s*:%s*"([^"]+)"%s*,%s*"price"%s*:%s*(%d+)') do
        if carHint then setDayPrice(carHint, normalizeDate(date), price) end
    end

    -- name + price (+ валюта)
    for name, price in text:gmatch('"name"%s*:%s*"([^"]+)"%s*,%s*"price"%s*:%s*(%d+)') do
        setPrice(name, price)
    end
    for name, price in text:gmatch('"model"%s*:%s*"([^"]+)"%s*,%s*"price"%s*:%s*(%d+)') do
        setPrice(name, price)
    end
    for name, price in text:gmatch('"modelName"%s*:%s*"([^"]+)"%s*,%s*"avgPrice"%s*:%s*(%d+)') do
        setPrice(name, price)
    end
    for name, price in text:gmatch('"title"%s*:%s*"([^"]+)"%s*,%s*"price"%s*:%s*(%d+)') do
        setPrice(name, price)
    end

    -- текст списка: "LP Urus :CASH — $200.000.000"
    for name, price in text:gmatch('([%w%[%] %-%._А-Яа-яЁё]+)%s*:CASH%s*[—–%-:|]+%s*%$?%s*([%d%s%.,]+)') do
        setPrice(name, price)
    end
    for name, price in text:gmatch('([%w%[%] %-%._А-Яа-яЁё]+)%s*[\t ]+:CASH%s*[—–%-:|]+%s*%$?%s*([%d%s%.,]+)') do
        setPrice(name, price)
    end

    -- строки дней: "01.09.2026 - $1.234.567" / "01.09 — $..."
    for date, price in text:gmatch('(%d%d[%.%/%-]%d%d[%.%/%-]%d%d%d%d)%s*[—–%-:|]+%s*%$?%s*([%d%s%.,]+)') do
        local hint = carHint or scanState.currentName
        if hint then
            local p = tostring(price):gsub('%s+', ''):gsub('%.', ''):gsub(',', '')
            setDayPrice(hint, normalizeDate(date), p)
        end
    end
    for date, price in text:gmatch('(%d%d[%.%/%-]%d%d)%s*[—–%-:|]+%s*%$?%s*([%d%s%.,]+)') do
        local hint = carHint or scanState.currentName
        if hint then
            local p = tostring(price):gsub('%s+', ''):gsub('%.', ''):gsub(',', '')
            setDayPrice(hint, normalizeDate(date), p)
        end
    end

    -- history:[1,2,3]
    if carHint then
        local arr = text:match('"history"%s*:%s*(%b[])')
            or text:match('"points"%s*:%s*(%b[])')
            or text:match('"values"%s*:%s*(%b[])')
            or text:match('"chart"%s*:%s*(%b[])')
        if arr then
            local nums = {}
            for n in arr:gmatch('(%d+)') do
                nums[#nums + 1] = tonumber(n)
                if #nums >= MAX_DAYS then break end
            end
            if #nums >= 3 then
                for i, p in ipairs(nums) do
                    setDayPrice(carHint, dateOffset(#nums - i), p)
                end
            end
        end
    end
end

local function parsePriceLine(line)
    if type(line) ~= 'string' or line == '' then return false end
    line = repair_mojibake(ensure_utf8(line))
    line = line:gsub('{......}', '')

    local date, price = line:match('^%s*(%d%d[%.%/%-]%d%d[%.%/%-]%d%d%d%d)%s*[—–%-:|]+%s*%$?%s*([%d%s%.,]+)')
    if date and price and scanState.currentName then
        return setDayPrice(scanState.currentName, normalizeDate(date), price)
    end
    date, price = line:match('^%s*(%d%d[%.%/%-]%d%d)%s*[—–%-:|]+%s*%$?%s*([%d%s%.,]+)')
    if date and price and scanState.currentName then
        return setDayPrice(scanState.currentName, normalizeDate(date), price)
    end

    -- "Name :CASH — $1.234"
    local name, p2 = line:match('^%s*(.-)%s*:CASH%s*[—–%-:|]+%s*%$?%s*([%d%s%.,]+)%s*$')
    if name and p2 then
        return setPrice(name, p2)
    end

    name, p2 = line:match('^%s*(.-)%s*[—–%-|]+%s*%$?%s*([%d%s%.,]+)%s*$')
    if name and p2 and not looksLikeDate(name) then
        name = name:gsub('%s*:CASH%s*$', '')
        return setPrice(name, p2)
    end
    return false
end

local function extractJsonPayloads(text)
    local payloads = {}
    if type(text) ~= 'string' or text == '' then return payloads end
    for ev, js in text:gmatch("window%.executeEvent%(%s*'([^']+)'%s*,%s*`([^`]*)`%s*%)") do
        payloads[#payloads + 1] = { event = ev, json = js }
    end
    for ev, js in text:gmatch("window%.executeEvent%(%s*'([^']+)'%s*,%s*'([^']*)'%s*%)") do
        payloads[#payloads + 1] = { event = ev, json = js }
    end
    for js in text:gmatch('JSON%.stringify%((%b[])%)') do
        payloads[#payloads + 1] = { event = 'stringify', json = js }
    end
    for js in text:gmatch('JSON%.stringify%((%b{})%)') do
        payloads[#payloads + 1] = { event = 'stringify', json = js }
    end
    if text:sub(1, 1) == '{' or text:sub(1, 1) == '[' then
        payloads[#payloads + 1] = { event = 'raw', json = text }
    end
    return payloads
end

local function ingestTextBlob(text)
    if type(text) ~= 'string' or text == '' then return end
    local utf = repair_mojibake(ensure_utf8(text))
    for line in utf:gmatch('[^\r\n]+') do
        parsePriceLine(line)
    end
    regexHarvest(utf, scanState.currentName)
    for _, payload in ipairs(extractJsonPayloads(utf)) do
        regexHarvest(payload.json or '', scanState.currentName)
        local ok, tbl = safeDecodeJson( payload.json or '')
        if ok and type(tbl) == 'table' then
            harvestDaysFromJson(tbl, scanState.currentName)
        end
    end
end

---------------------------------------------------------------------------
-- Диалоги АБ
-- Не матчить «похожие» окна (угон и т.п.) по :CASH: / пагинации.
-- CEF: arizona-cef-dialogs (RPC 61) + arizona-events.
---------------------------------------------------------------------------
local function classifyDialog(id, title, text)
    title = stripColors(ensure_utf8(tostring(title or '')))
    text = ensure_utf8(tostring(text or ''))
    id = tonumber(id) or 0
    if id == DIALOG_LIST_ID or title:find('Средняя цена автомобилей', 1, true) then
        return 'list'
    end
    if id == DIALOG_DAYS_ID then
        return 'days'
    end
    if title:find('Продажа транспорта', 1, true)
        and (text:find('Средняя цена за день', 1, true)
            or text:find('Количество продаж', 1, true))
    then
        return 'days'
    end
    return 'other'
end

local function isAbCefText(text, event)
    text = tostring(text or '')
    event = tostring(event or '')
    if text:find('Средняя цена автомобилей', 1, true) then return true end
    if text:find('Средняя цена за день', 1, true) then return true end
    if event:find('dialog', 1, true) and text:find('Средняя цена', 1, true) then
        return true
    end
    return false
end

local function navKind(plain)
    plain = tostring(plain or '')
    -- Lua string.lower не трогает кириллицу — ищем как есть
    if plain:find('оиск по названию', 1, true) then return 'search' end
    if plain:find('редыдущая страница', 1, true) then return 'prev' end
    if plain:find('ледующая страница', 1, true) then return 'next' end
    if plain:find('ранспорт', 1, true) and plain:find('30', 1, true) then return 'header' end
    if plain:find('ата', 1, true) and plain:find('родаж', 1, true) then return 'header' end
    return nil
end

-- style=5 (TABLIST_HEADERS): строка 0 — заголовок, в listitem НЕ входит.
-- Текст: [0]header [1]поиск [2]prev [3]next [4+]машины
-- listitem:          [0]поиск [1]prev [2]next [3+]машины
local function parseListDialog(text, style)
    style = tonumber(style) or 0
    local headerOffset = (style == 5) and 1 or 0
    local items, cars = {}, {}
    local lineIdx = 0
    for line in tostring(text or ''):gmatch('[^\r\n]+') do
        local plain = stripColors(ensure_utf8(line))
        plain = plain:gsub('%s+$', '')
        local kind = navKind(plain)
        local name, price
        if headerOffset == 1 and lineIdx == 0 then
            kind = kind or 'header'
        end
        if not kind then
            -- Name<TAB>:CASH:123.456
            name, price = plain:match('^(.-)\t+:CASH:(.+)$')
            if not name then
                name, price = plain:match('^(.+)%s+:CASH:(.+)$')
            end
            if name and price then
                name = normalizeName(name)
                price = parseCashToken(':CASH:' .. price)
                if name ~= '' and price then
                    kind = 'car'
                else
                    name, price = nil, nil
                end
            end
        end
        local listitem = lineIdx - headerOffset
        if headerOffset == 1 and lineIdx == 0 then
            listitem = -1
        end
        local row = {
            idx = listitem,
            line = lineIdx,
            kind = kind or 'other',
            raw = plain,
            name = name,
            price = price,
        }
        items[#items + 1] = row
        if kind == 'car' and listitem >= 0 then cars[#cars + 1] = row end
        lineIdx = lineIdx + 1
    end
    local nextIdx, prevIdx
    for _, row in ipairs(items) do
        if row.kind == 'next' and row.idx >= 0 then nextIdx = row.idx end
        if row.kind == 'prev' and row.idx >= 0 then prevIdx = row.idx end
    end
    return cars, nextIdx, prevIdx
end

local function parseDaysDialog(title, text)
    title = stripColors(ensure_utf8(tostring(title or '')))
    local car = title:match("Продажа транспорта%s+'([^']+)'")
        or title:match('Продажа транспорта%s+"([^"]+)"')
        or title:match('Продажа транспорта%s+«([^»]+)»')
        or title:match("Продажа транспорта%s+['\"«](.+)['\"»]%s+за")
        or title:match("transport%s+'([^']+)'")
    car = normalizeName(car or '')
    local days = {}
    for line in tostring(text or ''):gmatch('[^\r\n]+') do
        local plain = stripColors(ensure_utf8(line))
        local date, cnt, price = plain:match('^(%d%d%d%d%-%d%d%-%d%d)\t(%d+)\t:CASH:(.+)$')
        if not date then
            date, cnt, price = plain:match('^(%d%d%d%d%-%d%d%-%d%d)%s+(%d+)%s+:CASH:(.+)$')
        end
        if not date then
            date, price = plain:match('^(%d%d%d%d%-%d%d%-%d%d).-:CASH:(.+)$')
            cnt = 0
        end
        if date and price then
            local p = parseCashToken(':CASH:' .. tostring(price))
            if p then
                days[#days + 1] = { date = date, count = tonumber(cnt) or 0, price = p }
            end
        end
    end
    return car, days
end

local function ingestDialog(id, style, title, btn1, btn2, text)
    local kind = classifyDialog(id, title, text)
    local finger = tostring(tonumber(id) or 0) .. '\1' .. tostring(kind) .. '\1' .. tostring(#(text or ''))
    if finger == (scanState.lastFinger or '') and not scanState.forceDlg then
        if kind == 'list' then scanState.listUntil = os.clock() + 4 end
        return scanState.dlg
    end
    scanState.forceDlg = false
    scanState.lastFinger = finger

    local cars, nextIdx, prevIdx
    if kind == 'list' then
        scanState.listUntil = os.clock() + 4
        cars, nextIdx, prevIdx = parseListDialog(text, style)
        for _, row in ipairs(cars) do
            setPrice(row.name, row.price)
        end
    elseif kind == 'days' then
        local car, days = parseDaysDialog(title, text)
        if car == '' then car = normalizeName(scanState.currentName or '') end
        if car ~= '' then
            scanState.currentName = car
            for _, row in ipairs(days) do
                setDayPrice(car, row.date, row.price)
            end
        end
    end

    scanState.dlgSeq = (scanState.dlgSeq or 0) + 1
    scanState.dlg = {
        id = tonumber(id) or 0,
        kind = kind,
        seq = scanState.dlgSeq,
        cars = cars,
        nextIdx = nextIdx or 2,
        prevIdx = prevIdx or 1,
    }
    if not scanState.active then
        rebuildList()
    end
    return scanState.dlg
end

local function dialogResponse(dialogId, button, listitem, input)
    dialogId = tonumber(dialogId) or 0
    button = tonumber(button) or 1
    listitem = tonumber(listitem) or -1
    input = tostring(input or '')
    scanState.forceDlg = true
    pcall(function()
        if sampSendDialogResponse then
            sampSendDialogResponse(dialogId, button, listitem, input)
        end
    end)
end

-- Пауза из слайдера. 0 = один тик (wait 0), иначе 1..40 мс.
local function clickDelay()
    local ms = tonumber(waitPageMs[0]) or 0
    if ms < 0 then ms = 0 elseif ms > 40 then ms = 40 end
    if ms <= 0 then
        wait(0)
    else
        wait(ms)
    end
end

-- Сразу забрать диалог, не ждать цикл main (там пауза 80мс)
local function drainScanDialogs()
    if #incomingDlg > 0 then
        local batch = incomingDlg
        incomingDlg = {}
        for i = 1, #batch do
            local d = batch[i]
            pcall(ingestDialog, d.id, d.style, d.title, d.btn1, d.btn2, d.text)
        end
    end
    if not (ok_cef and cefDlg) then return end
    pcall(function()
        local id = tonumber(cefDlg.GetId()) or -1
        if id < 0 then return end
        local title = cefDlg.GetTitle() or ''
        local text = cefDlg.GetDialogText() or ''
        if title == '' and text == '' then return end
        local kind = classifyDialog(id, title, text)
        if kind == 'list' or kind == 'days' then
            ingestDialog(id, cefDlg.GetStyle(), title, cefDlg.GetButton1(), cefDlg.GetButton2(), text)
        end
    end)
end

local function waitForDialog(kind, timeoutMs, minSeq)
    timeoutMs = timeoutMs or 700
    minSeq = tonumber(minSeq) or 0
    local deadline = os.clock() + timeoutMs / 1000
    while os.clock() < deadline and scanState.active do
        pcall(drainScanDialogs)
        local d = scanState.dlg
        if d and d.kind == kind and (tonumber(d.seq) or 0) > minSeq then
            return d
        end
        if d and d.kind == kind and minSeq <= 0 then
            return d
        end
        wait(0)
    end
    pcall(drainScanDialogs)
    local d = scanState.dlg
    if d and d.kind == kind then return d end
    return nil
end

-- Быстрый «Назад»: native close + короткий poll, один fallback RESP.
local function backToList(timeoutMs)
    timeoutMs = timeoutMs or 400

    local function haveList()
        pcall(drainScanDialogs)
        return scanState.dlg and scanState.dlg.kind == 'list'
    end

    if haveList() then return true end

    local daysId = (scanState.dlg and scanState.dlg.id > 0) and scanState.dlg.id or DIALOG_DAYS_ID
    local startSeq = scanState.dlgSeq or 0

    scanState.forceDlg = true
    if ok_cef and cefDlg then
        pcall(cefDlg.CloseWithButton, 1)
        if waitForDialog('list', timeoutMs, startSeq) then return true end
        if haveList() then return true end
        startSeq = scanState.dlgSeq or 0
    end
    scanState.forceDlg = true
    if sampCloseCurrentDialogWithButton then
        pcall(sampCloseCurrentDialogWithButton, 1)
        if waitForDialog('list', timeoutMs, startSeq) then return true end
        if haveList() then return true end
    end

    startSeq = scanState.dlgSeq or 0
    dialogResponse(daysId, 1, 0, '')
    if waitForDialog('list', timeoutMs, startSeq) then return true end
    if haveList() then return true end

    startSeq = scanState.dlgSeq or 0
    dialogResponse(daysId, 1, -1, '')
    if waitForDialog('list', timeoutMs + 200, startSeq) then return true end

    return haveList()
end

local function namesEqual(a, b)
    return normalizeName(a or '') == normalizeName(b or '') and normalizeName(a or '') ~= ''
end

-- Открыть дни: один клик по корректному listitem.
local function openCarDays(listId, car, nextIdx, prevIdx)
    nextIdx = nextIdx or 2
    prevIdx = prevIdx or 1
    local idx = tonumber(car.idx)
    if not idx or idx < 3 or idx == nextIdx or idx == prevIdx then
        return nil, nil
    end
    if not (scanState.dlg and scanState.dlg.kind == 'list') then
        if not backToList(500) then return nil end
    end
    listId = (scanState.dlg and scanState.dlg.id > 0) and scanState.dlg.id or listId
    local seqBefore = scanState.dlgSeq or 0
    dialogResponse(listId, 1, idx, '')
    clickDelay()
    local daysDlg = waitForDialog('days', 700, seqBefore)
    if not daysDlg and scanState.dlg and scanState.dlg.kind == 'days' then
        daysDlg = scanState.dlg
    end
    if daysDlg then
        return daysDlg, idx
    end
    return nil, nil
end

local function goNextPage(listId, nextIdx, oldFirst)
    nextIdx = nextIdx or 2
    for attempt = 1, 3 do
        if scanState.dlg and scanState.dlg.kind == 'days' then
            if not backToList(500) then return nil end
        end
        if not (scanState.dlg and scanState.dlg.kind == 'list') then
            if not backToList(500) then return nil end
        end
        listId = (scanState.dlg and scanState.dlg.id > 0) and scanState.dlg.id or listId
        nextIdx = (scanState.dlg and scanState.dlg.nextIdx) or nextIdx
        local seqBefore = scanState.dlgSeq or 0
        dialogResponse(listId, 1, nextIdx, '')
        clickDelay()

        local deadline = os.clock() + 0.7
        while os.clock() < deadline and scanState.active do
            pcall(drainScanDialogs)
            local d = scanState.dlg
            if d and d.kind == 'days' then
                if not backToList(500) then return nil end
                break
            end
            if d and d.kind == 'list' and d.cars and d.cars[1] then
                if (tonumber(d.seq) or 0) > seqBefore and not namesEqual(d.cars[1].name, oldFirst) then
                    return d
                end
                if not namesEqual(d.cars[1].name, oldFirst) then
                    return d
                end
            end
            wait(0)
        end
    end
    return nil
end

local function carHasToday(name)
    name = normalizeName(name)
    local info = prices[name]
    if not (info and type(info.days) == 'table') then return false end
    local today = os.date('%Y-%m-%d')
    for i = 1, #info.days do
        if normalizeDate(info.days[i].date or '') == today then
            return true
        end
    end
    return false
end

local function startScan()
    if scanState.active then
        chat('Скан уже идёт...')
        return
    end

    if not (scanState.dlg and scanState.dlg.kind == 'list') then
        chat('Сначала открой диалог «Средняя цена автомобилей…»')
        return
    end

    scanState.active = true
    scanState.stopped = false
    scanState.index = 0
    scanState.currentName = nil
    chat('Скан запущен')

    lua_thread.create(function()
        local page = 0
        local seenFirst = {}

        while scanState.active and page < MAX_PAGES_SAFETY do
            local list = scanState.dlg
            if not list or list.kind ~= 'list' then
                list = waitForDialog('list', 4000, scanState.dlgSeq or 0)
            end
            if not list or list.kind ~= 'list' then
                chat('Нет списка — стоп')
                break
            end

            -- снимок страницы сразу (пока диалог не сменился)
            local pageCars = {}
            for i, c in ipairs(list.cars or {}) do
                pageCars[i] = { idx = c.idx, name = c.name, price = c.price }
            end
            local listId = (list.id and list.id > 0) and list.id or DIALOG_LIST_ID
            local nextIdx = list.nextIdx or 2
            local prevIdx = list.prevIdx or 1
            local firstName = pageCars[1] and pageCars[1].name or ''
            page = page + 1
            scanState.index = page
            chat(('Стр.%d: %d машин'):format(page, #pageCars))

            if firstName ~= '' and seenFirst[firstName] then
                break
            end
            if firstName ~= '' then seenFirst[firstName] = true end

            if #pageCars == 0 then
                break
            end

            for _, car in ipairs(pageCars) do
                if not scanState.active then break end
                scanState.currentName = car.name
                if not carHasToday(car.name) then
                    if scanState.dlg and scanState.dlg.kind == 'days' then
                        if not backToList(500) then
                            chat('Не могу нажать Назад — стоп.')
                            scanState.active = false
                            break
                        end
                    end
                    if not (scanState.dlg and scanState.dlg.kind == 'list') then
                        waitForDialog('list', 500, 0)
                    end
                    if not (scanState.dlg and scanState.dlg.kind == 'list') then
                        break
                    end
                    listId = scanState.dlg.id > 0 and scanState.dlg.id or listId
                    nextIdx = scanState.dlg.nextIdx or nextIdx
                    prevIdx = scanState.dlg.prevIdx or 1

                    local daysDlg = openCarDays(listId, car, nextIdx, prevIdx)
                    if daysDlg then
                        if not backToList(500) then
                            chat('Назад из дней не сработал. Стоп.')
                            scanState.active = false
                            break
                        end
                    end
                end
            end

            if not scanState.active then break end

            if scanState.dlg and scanState.dlg.kind == 'days' then
                backToList(500)
            end
            if not (scanState.dlg and scanState.dlg.kind == 'list') then
                waitForDialog('list', 500, 0)
            end
            if not (scanState.dlg and scanState.dlg.kind == 'list') then
                break
            end

            listId = scanState.dlg.id > 0 and scanState.dlg.id or listId
            nextIdx = scanState.dlg.nextIdx or 2
            local nxt = goNextPage(listId, nextIdx, firstName)
            if not nxt then
                break
            end
        end

        scanState.active = false
        rebuildList()
        savePrices()
        if not scanState.stopped then
            chat(('Скан готов. Машин в базе: %d'):format(#priceList))
        end
    end)
end

local function stopScan()
    if not scanState.active then return end
    scanState.active = false
    scanState.stopped = true
    rebuildList()
    savePrices()
    chat('Скан остановлен')
end

-- Тот же канал, что у кнопки «Закрыть» в CEF-диалоге (не HUD, как ПТС)
local function evalCefDialog(code)
    if type(code) ~= 'string' or code == '' then return end
    pcall(function()
        local wrapped = '(() => {' .. code .. '})()'
        local bs = raknetNewBitStream()
        raknetBitStreamWriteInt8(bs, 17)
        raknetBitStreamWriteInt32(bs, 0)
        raknetBitStreamWriteInt16(bs, #wrapped)
        raknetBitStreamWriteInt8(bs, 0)
        raknetBitStreamWriteString(bs, wrapped)
        raknetEmulPacketReceiveBitStream(220, bs)
        raknetDeleteBitStream(bs)
    end)
end

local function priceMenuOpen()
    if ok_cef and cefDlg then
        local id, title, text = -1, '', ''
        pcall(function()
            id = tonumber(cefDlg.GetId()) or -1
            title = cefDlg.GetTitle() or ''
            text = cefDlg.GetDialogText() or ''
        end)
        if classifyDialog(id, title, text) == 'list' then return true end
    end
    return scanState.dlg and scanState.dlg.kind == 'list'
end

local function injectScanButton()
    -- Ищем список по тексту внутри окна, не по первому попавшемуся .dialog
    evalCefDialog([[
var id='abarz-scan-btn';
var needles=['\u0421\u0440\u0435\u0434\u043d\u044f\u044f \u0446\u0435\u043d\u0430 \u0430\u0432\u0442\u043e\u043c\u043e\u0431\u0438\u043b\u0435\u0439','\u041f\u043e\u0438\u0441\u043a \u043f\u043e \u043d\u0430\u0437\u0432\u0430\u043d\u0438\u044e','\u043e\u0438\u0441\u043a \u043f\u043e \u043d\u0430\u0437\u0432\u0430\u043d\u0438\u044e','\u043b\u0435\u0434\u0443\u044e\u0449\u0430\u044f \u0441\u0442\u0440\u0430\u043d\u0438\u0446\u0430'];
var skip='\u0446\u0435\u043d\u0430 \u0437\u0430 \u0434\u0435\u043d\u044c';
function hit(s){
  if(!s) return false;
  if(s.indexOf(skip)!==-1) return false;
  for(var i=0;i<needles.length;i++) if(s.indexOf(needles[i])!==-1) return true;
  return false;
}
var box=null;
var nodes=document.querySelectorAll('.dialog');
for(var i=0;i<nodes.length;i++){
  if(hit(nodes[i].innerText||nodes[i].textContent||'')){ box=nodes[i]; break; }
}
if(!box){
  var w=document.createTreeWalker(document.body,NodeFilter.SHOW_TEXT,null,false);
  var n, host=null;
  while(n=w.nextNode()){
    if(hit(n.nodeValue||'')){ host=n.parentElement; break; }
  }
  if(host){
    var p=host;
    for(var i=0;i<16&&p;i++){
      var cn=(p.className&&(p.className.baseVal||p.className))||'';
      if(String(cn).indexOf('dialog')!==-1){ box=p; break; }
      p=p.parentElement;
    }
    if(!box) box=host;
  }
}
var old=document.getElementById(id);
if(!box){ if(old) old.remove(); return; }
if(old){
  if(!box.contains(old)) old.remove();
  else return;
}
var btn=document.createElement('div');
btn.id=id;
btn.textContent='\u0421\u043a\u0430\u043d\u0438\u0440\u043e\u0432\u0430\u0442\u044c';
btn.onclick=function(ev){
  if(ev){ ev.preventDefault(); ev.stopPropagation(); }
  window.__abarzScan='start';
  try{ if(window.cef&&window.cef.SendMessage) window.cef.SendMessage('abarz-scan|start',0); }catch(e){}
};
btn.style.cssText='width:100%;margin:8px 0 4px;padding:10px 14px;text-align:center;font-size:15px;font-weight:700;color:#fff;letter-spacing:.03em;box-sizing:border-box;background:#27ae60;border-radius:8px;cursor:pointer;';
var header=box.querySelector('.dialog__header');
if(header&&header.parentNode) header.parentNode.insertBefore(btn, header.nextSibling);
else box.insertBefore(btn, box.firstChild);
]])
end

local function pumpScanFab()
    if scanFab.cmd == 'start' then
        scanFab.cmd = ''
        if not scanState.active then startScan() end
    end
    if not priceMenuOpen() then
        if scanFab.wasOpen then
            evalCefDialog([[var e=document.getElementById('abarz-scan-btn'); if(e) e.remove();]])
        end
        scanFab.wasOpen = false
        return
    end
    scanFab.wasOpen = true
    if os.clock() < (scanFab.pollAt or 0) then return end
    scanFab.pollAt = os.clock() + 0.6
    injectScanButton()
    if scanFab.pollBusy then return end
    if not (ok_cef and cefDlg and cefDlg.cefQueryAsync) then return end
    scanFab.pollBusy = true
    cefDlg.cefQueryAsync([[
var v=window.__abarzScan||null; window.__abarzScan=null; return v;
]], function(v)
        scanFab.pollBusy = false
        v = tostring(v or '')
        if v == 'start' then scanFab.cmd = 'start' end
    end, 350)
end

pcall(function()
    addEventHandler('onSendPacket', function(id, bs)
        if id ~= 220 then return end
        local act
        pcall(function()
            local off
            if raknetBitStreamGetReadOffset then off = raknetBitStreamGetReadOffset(bs) end
            if raknetBitStreamSetReadOffset then raknetBitStreamSetReadOffset(bs, 0) end
            raknetBitStreamIgnoreBits(bs, 8)
            local pType = raknetBitStreamReadInt8(bs)
            if pType == 18 then
                local len = raknetBitStreamReadInt16(bs)
                local text = raknetBitStreamReadString(bs, len)
                if type(text) == 'string' then act = text:match('abarz%-scan%|(%w+)') end
            end
            if off and raknetBitStreamSetReadOffset then raknetBitStreamSetReadOffset(bs, off) end
        end)
        if act == 'start' then
            scanFab.cmd = act
            return false
        end
    end)
end)

---------------------------------------------------------------------------
-- Новые продажи на АБ → чат. Из RPC только строки/числа, обработка в main.
---------------------------------------------------------------------------
local PLATES = {}
local incomingPlates = {}
local saleAlive = true
local onNewSalePlate

local function parseAbbrevPrice(str)
    if not str then return nil end
    local s = tostring(str):gsub('{%x+}', ''):gsub('{......}', ''):gsub('<[^>]+>', '')
    s = s:gsub('[%s%$]', ''):gsub('\160', ''):gsub('\194\160', '')
    -- иконка валюты Arizona (🰢 и т.п.) + «75.000.000»
    local i1, i2, numStr = s:find('(%d[%d%.,]*)')
    if not numStr then return cleanPriceNum(s) end
    local n = cleanPriceNum(numStr)
    if not n then return nil end
    local tail = (s:sub(1, i1 - 1) .. s:sub(i2 + 1)):lower()
    tail = tail:gsub('[^%a\128-\255]', '')
    if tail == 'kkk' or tail == 'ккк' or tail == 'млрд' or tail == 'mlrd'
        or tail == 'b' or tail == 'б' or tail == 'm' or tail == 'м' then
        return math.floor(n * 1000000000)
    elseif tail == 'kk' or tail == 'кк' or tail == 'млн' or tail == 'mln' then
        return math.floor(n * 1000000)
    elseif tail == 'k' or tail == 'к' or tail == 'тыс' or tail == 'tys'
        or tail == 't' or tail == 'т' then
        return math.floor(n * 1000)
    end
    return n
end

local function parsePlatePrice(s)
    return parseCashToken(s) or parseAbbrevPrice(s)
end

local function lookupAvgPrice(model)
    local info = prices[normalizeName(model)]
    if not info then return nil end
    local p = tonumber(info.price) or avgFromDays(info.days)
    if p and p > 0 then return p end
end

local function parseSalePlate(text)
    text = tostring(text or ''):gsub('{%x+}', ''):gsub('{......}', '')
    text = repair_mojibake(ensure_utf8(text))
    text = text:gsub('\r\n', '\n')
    if text == '' then return nil end

    local auc = text:match('Аукцион №%d+\n([^\n]+)')
    if auc then
        auc = normalizeName(auc)
        if auc ~= '' and not auc:find('***', 1, true) then
            return 'auction', auc, nil
        end
    end

    local model, priceStr
    local i = text:find('Продажа транспорта', 1, true)
    if i then
        local block = text:sub(i)
        model, priceStr = block:match('Продажа транспорта\n([^\n]+)\nЦена:%s*([^\n]+)')
        if not model then
            model, priceStr = block:match('Продажа транспорта\n([^\n]+)\n([^\n]+)')
        end
    elseif text:find('Владеле', 1, true) or text:find('Состояние:', 1, true) then
        model, priceStr = text:match('^([^\n]+)\n([^\n]+)')
    end
    if not model then
        model, priceStr = text:match('([^\n]+)\t+:CASH:([^\n]+)')
    end
    if not model or model:find('***', 1, true) then return nil end
    model = normalizeName(model)
    if model == '' or not priceStr then return nil end
    local price = parsePlatePrice(priceStr)
    if not price or price <= 0 then return nil end
    return 'sale', model, price
end

local function stopSaleWatch()
    saleAlive = false
    incomingPlates = {}
end

local function vsAvgInfo(lot, avg)
    lot, avg = tonumber(lot), tonumber(avg)
    local info = { color = '#f3f3f3', samp = 'FFFFFF', title = nil, detail = '' }
    if not avg or avg <= 0 or not lot or lot <= 0 then return info end
    local delta = lot - avg
    local pct = math.floor(math.abs(delta) / avg * 100 + 0.5)
    if pct > 999 then pct = 999 end
    if delta < 0 then
        info.color = '#2ecc71'
        info.samp = '45D96F'
        info.title = 'Дешевле средней'
        info.detail = ('на %s (-%d%%)'):format(fmtMoney(-delta), pct)
    elseif delta > 0 then
        info.color = '#e74c3c'
        info.samp = 'FF6B6B'
        info.title = 'Дороже средней'
        info.detail = ('на %s (+%d%%)'):format(fmtMoney(delta), pct)
    else
        info.title = 'Как средняя'
    end
    return info
end

local function notifyNewSale(kind, model, price)
    if kind == 'auction' then
        chat(('Новый транспорт на аукционе: %s'):format(model))
        return
    end
    local avg = lookupAvgPrice(model)
    if not avg then
        chat(('На продажу выставлен: %s за %s | средняя неизвестна'):format(model, fmtMoney(price)))
        return
    end
    local gain = avg - (tonumber(price) or 0)
    if gain > 15000000 then
        local vs = vsAvgInfo(price, avg)
        chat(('На продажу выставлен: %s за %s | средняя %s | {%s}%s %s'):format(
            model, fmtMoney(price), fmtMoney(avg), vs.samp, vs.title, vs.detail))
        return
    end
    chat(('На продажу выставлен: %s за %s | средняя %s'):format(model, fmtMoney(price), fmtMoney(avg)))
end

local function tryObjectPos(sampId)
    sampId = tonumber(sampId)
    if not sampId or type(sampGetObjectHandleBySampId) ~= 'function' then return end
    local ok, handle = pcall(sampGetObjectHandleBySampId, sampId)
    if not ok or type(handle) ~= 'number' or handle <= 0 then return end
    local ok2, a, b, c, d = pcall(getObjectCoordinates, handle)
    if not ok2 then return end
    if type(b) == 'number' and type(c) == 'number' and type(d) == 'number' then
        return b, c, d
    end
    if type(a) == 'number' and type(b) == 'number' and type(c) == 'number' then
        return a, b, c
    end
end

local function playerPos()
    local ok, a, b, c, d = pcall(getCharCoordinates, PLAYER_PED)
    if not ok then return end
    if type(b) == 'number' and type(c) == 'number' and type(d) == 'number' then
        return b, c, d
    end
    if type(a) == 'number' and type(b) == 'number' and type(c) == 'number' then
        return a, b, c
    end
end

local function dist3(ax, ay, az, bx, by, bz)
    local dx, dy, dz = ax - bx, ay - by, az - bz
    return math.sqrt(dx * dx + dy * dy + dz * dz)
end

local function rememberPlate(key, model, price, x, y, z)
    if not key or not model or not price then return end
    knownPlates[key] = {
        model = model,
        price = price,
        x = tonumber(x), y = tonumber(y), z = tonumber(z),
        t = os.clock(),
    }
    local n = 0
    local oldestKey, oldestT
    for k, p in pairs(knownPlates) do
        n = n + 1
        if not oldestT or p.t < oldestT then
            oldestKey, oldestT = k, p.t
        end
    end
    if n > 250 and oldestKey then
        knownPlates[oldestKey] = nil
    end
end

local function nearestPlate(maxDist)
    maxDist = maxDist or 22
    local px, py, pz = playerPos()
    if not px then return nil end
    local best, bestD
    local now = os.clock()
    for _, p in pairs(knownPlates) do
        if p.x and p.y and p.z and (now - p.t) < 180 then
            local d = dist3(px, py, pz, p.x, p.y, p.z)
            if d <= maxDist and (not bestD or d < bestD) then
                best, bestD = p, d
            end
        end
    end
    return best, bestD
end

local function lastFreshPlate(maxAge)
    maxAge = maxAge or 20
    local now = os.clock()
    local best
    for _, p in pairs(knownPlates) do
        if (now - p.t) <= maxAge then
            if not best or p.t > best.t then best = p end
        end
    end
    return best
end

scanState.findLot = function(model)
    model = normalizeName(model)
    if model == '' then return nil end
    local now = os.clock()
    local near = nearestPlate(22)
    if near and normalizeName(near.model) == model then
        local p = tonumber(near.price) or 0
        if p >= 1000000 then return p end
    end
    local best, bestT
    for _, row in pairs(knownPlates) do
        local p = tonumber(row.price) or 0
        if normalizeName(row.model) == model and p >= 1000000
            and (now - (row.t or 0)) < 180 and (not bestT or row.t > bestT) then
            best, bestT = p, row.t
        end
    end
    return best
end

local function isGenericCarName(name)
    name = normalizeName(name or '')
    if name == '' then return true end
    local n = name:lower()
    return n == 'транспорт' or name == 'Транспорт'
        or name == 'ваш транспорт' or n == 'ваш транспорт'
        or name == 'свой транспорт' or name == 'транспортное средство'
end

local function snapshotBuyFromPlate()
    local p = nearestPlate(25) or lastFreshPlate(25)
    if not p then return end
    if not pendingBuy.active or (os.clock() - (pendingBuy.t or 0)) > 90 then
        pendingBuy.active = true
        pendingBuy.t = os.clock()
        pendingBuy.source = 'plate'
    end
    if isGenericCarName(pendingBuy.model) then
        pendingBuy.model = p.model
    end
    if not pendingBuy.price or pendingBuy.price <= 0 then
        pendingBuy.price = p.price
        pendingBuy.source = 'plate'
    end
end

local function snapshotSellFromPlate()
    if not pendingSell.active then return end
    local want = tonumber(pendingSell.price) or 0
    if want <= 0 then return end
    local now = os.clock()
    local px, py, pz = playerPos()
    local p
    for _, row in pairs(knownPlates) do
        if row.price == want and (now - (row.t or 0)) <= 45 then
            local okd = true
            if px and row.x and row.y and row.z then
                local d = dist3(px, py, pz, row.x, row.y, row.z)
                okd = d and d <= 12
            end
            if okd and (not p or row.t > p.t) then p = row end
        end
    end
    if not p then return end
    if isGenericCarName(pendingSell.model) then
        pendingSell.model = p.model
        pendingSell.source = 'plate'
        saveDealLogs()
    end
end

local function addDeal(action, model, price, source)
    model = normalizeName(model or 'Транспорт')
    if model == '' then model = 'Транспорт' end
    price = tonumber(price) or 0
    local nowt = os.time()
    local last = dealLogs[#dealLogs]
    if last and last.action == action and last.model == model
        and last.price == price and (nowt - (last.time or 0)) <= 3 then
        return false
    end
    dealLogs[#dealLogs + 1] = {
        action = action,
        model = model,
        price = price,
        time = nowt,
        source = tostring(source or ''),
    }
    while #dealLogs > 300 do table.remove(dealLogs, 1) end
    saveDealLogs()
    if action == 'buy' then
        if price > 0 then
            chat(('Купил %s за %s'):format(model, fmtMoney(price)))
        else
            chat(('Купил %s'):format(model))
        end
    else
        if price > 0 then
            chat(('Продал %s за %s'):format(model, fmtMoney(price)))
        else
            chat(('Продал %s'):format(model))
        end
    end
    return true
end

local function noteDealDialog(title, text)
    title = repair_mojibake(stripColors(ensure_utf8(tostring(title or ''))))
    text = repair_mojibake(stripColors(ensure_utf8(tostring(text or ''))))

    if title:find('Подтверждение покупки', 1, true) then
        local model = text:match('Транспорт:%s*([^\r\n]+)') or text:match('Модель:%s*([^\r\n]+)')
        if model then
            model = normalizeName((model:gsub('%s*%[%d+%]$', '')))
        end
        local price
        local a, b = text:match(':CASH:([%d%.,%s]+).-:CASH:([%d%.,%s]+)')
        if a and b then
            price = (parsePlatePrice(a) or 0) + (parsePlatePrice(b) or 0)
        else
            local chars = 'kKкКmMмМlLлЛnNнНtTтТyYыЫsSсСbBбБrRрРdDдД'
            local p1, p2 = text:match('[%$]?%s*([%d%.%,%s' .. chars .. ']+)%s*%+.-[%$]?%s*([%d%.%,%s' .. chars .. ']+)')
            if p1 and p2 then
                price = (parseAbbrevPrice(p1) or 0) + (parseAbbrevPrice(p2) or 0)
            else
                price = parsePlatePrice(text)
            end
        end
        pendingBuy.active = true
        pendingBuy.model = (model ~= '' and model) or pendingBuy.model or 'Транспорт'
        pendingBuy.price = (price and price > 0) and price or (pendingBuy.price or 0)
        pendingBuy.t = os.clock()
        pendingBuy.source = (price and price > 0) and 'dialog' or pendingBuy.source
        needBuySnapshot = true
    end

    if title:find('Продажа', 1, true) or title:find('Аукцион', 1, true) or title:find('продажу', 1, true) then
        local model = text:match('Транспорт:%s*([^\r\n]+)') or text:match('Модель:%s*([^\r\n]+)')
        if model then
            pendingSell.model = normalizeName((model:gsub('%s*%[%d+%]$', '')))
        end
    end
end

local function processDealChat(raw)
    local clean = repair_mojibake(stripColors(ensure_utf8(tostring(raw or ''))))
    if clean == '' then return end

    local bought_model, bought_price = clean:match('Вы успешно купили транспорт (.-) у игрока .- за %D*(.+)')
    if not bought_model then
        bought_model, bought_price = clean:match('Вы успешно приобрели транспорт (.-) за %D*(.+)')
    end
    if bought_model and bought_price then
        local price = parseAbbrevPrice(bought_price)
        if price then
            addDeal('buy', bought_model, price, 'chat')
            pendingBuy.active = false
            return
        end
    end

    if clean:find('Поздравляем с приобретением транспортного средства', 1, true) then
        if pendingBuy.active and (os.clock() - (pendingBuy.t or 0)) < 90 and pendingBuy.price and pendingBuy.price > 0 then
            addDeal('buy', pendingBuy.model, pendingBuy.price, pendingBuy.source)
        else
            snapshotBuyFromPlate()
            if pendingBuy.price and pendingBuy.price > 0 then
                addDeal('buy', pendingBuy.model, pendingBuy.price, 'plate')
            else
                addDeal('buy', pendingBuy.model ~= '' and pendingBuy.model or 'Транспорт', 0, 'unknown')
            end
        end
        pendingBuy.active = false
        return
    end

    local listed_price = clean:match('выставили .- на продажу за%s*(.+)')
    if not listed_price then
        listed_price = clean:match('на продажу за%s*(.+)$')
        if not (clean:find('выставили', 1, true) or clean:find('продажу', 1, true)) then
            listed_price = nil
        end
    end
    local otherPlayer = clean:find('Игрок ', 1, true) or clean:find('выставлен:', 1, true)
        or clean:find('На продажу выставлен', 1, true)
    if listed_price and clean:find('выставили', 1, true) and not otherPlayer then
        local listed_model = clean:match('выставили%s+(.-)%s+на продажу')
        pendingSell.active = true
        pendingSell.t = os.clock()
        pendingSell.at = os.time()
        pendingSell.source = 'chat'
        local price = parseAbbrevPrice(listed_price)
        if price and price > 0 then pendingSell.price = price end
        if listed_model and not isGenericCarName(listed_model) then
            pendingSell.model = normalizeName(listed_model)
        else
            needSellSnapshot = true
        end
        saveDealLogs()
    end

    if clean:find('Поздравляем с продажей транспортного средства', 1, true) then
        if pendingSell.active and pendingSell.price and pendingSell.price > 0
            and (os.time() - (pendingSell.at or 0)) < 43200 then
            snapshotSellFromPlate()
            addDeal('sell', pendingSell.model, pendingSell.price, pendingSell.source)
        end
        pendingSell.active = false
        pendingSell.model = ''
        pendingSell.price = 0
        pendingSell.at = 0
        needSellSnapshot = false
        saveDealLogs()
        return
    end

    local state_price = clean:match('Вы продали свой транспорт государству за %D*(.+)')
    if state_price then
        local price = parseAbbrevPrice(state_price)
        if price then addDeal('sell', 'Слив в гос', price, 'chat') end
        pendingSell.active = false
        pendingSell.model = ''
        pendingSell.price = 0
        pendingSell.at = 0
        saveDealLogs()
        return
    end

    local auc_model, auc_price = clean:match('Вы успешно выкупили транспорт (.-) с аукциона за %D*(.+)')
    if auc_model and auc_price then
        local price = parseAbbrevPrice(auc_price)
        if price then addDeal('buy', auc_model, price, 'chat') end
        return
    end

    local sold_model, sold_price = clean:match('Вы продали транспорт (.-) игроку .- за %D*(.+)')
    if not sold_model then
        local _, m, p = clean:match('Игрок (.-) купил у вас транспорт (.-) за %D*(.+)')
        sold_model, sold_price = m, p
    end
    if sold_model and sold_price then
        local price = parseAbbrevPrice(sold_price)
        if price then addDeal('sell', sold_model, price, 'chat') end
        pendingSell.active = false
        pendingSell.model = ''
        pendingSell.price = 0
        pendingSell.at = 0
        saveDealLogs()
    end
end

local function queuePlate(item)
    if not saleAlive or type(item) ~= 'table' then return end
    if type(item.text) ~= 'string' or item.text == '' then return end
    incomingPlates[#incomingPlates + 1] = item
    if #incomingPlates > 80 then table.remove(incomingPlates, 1) end
end

-- RPC только копирует строку/числа. Чат — в pump, не из пакета.
onNewSalePlate = function(key, text, minPrice, x, y, z, sampId)
    if not saleAlive then return end
    local kind, model, price = parseSalePlate(text)
    if not kind then return end
    if kind == 'sale' and minPrice and price < minPrice then return end

    x, y, z = tonumber(x), tonumber(y), tonumber(z)
    if not (x and y and z) and sampId then
        x, y, z = tryObjectPos(sampId)
    end
    rememberPlate(key, model, price, x, y, z)

    if pendingSell.active and price and pendingSell.price and price == pendingSell.price then
        local dist
        if x and y and z then
            local px, py, pz = playerPos()
            if px then dist = dist3(px, py, pz, x, y, z) end
        end
        if (not dist or dist <= 8) and isGenericCarName(pendingSell.model) then
            pendingSell.model = model
            pendingSell.source = 'plate'
            saveDealLogs()
        end
    end

    local token = (kind == 'auction') and ('AUC/' .. model) or ('%s/%s'):format(model, tostring(price))
    if PLATES[key] == token then return end
    PLATES[key] = token

    local own = pendingSell.active and pendingSell.price == price
        and (isGenericCarName(pendingSell.model) or pendingSell.model == model)
    if notifyNewSales[0] and not own and os.clock() > (pendingSell.muteNtfy or 0) then
        pcall(notifyNewSale, kind, model, price)
    end
end

local last3dPoll = 0
local function pollSale3dTexts()
    if not saleAlive then return end
    if type(sampIs3dTextDefined) ~= 'function' or type(sampGet3dTextInfoById) ~= 'function' then
        return
    end
    if not isSampAvailable() then return end
    local now = os.clock()
    if now - last3dPoll < 0.5 then return end
    last3dPoll = now

    for id = 0, 2047 do
        local okd, defined = pcall(sampIs3dTextDefined, id)
        if okd and defined then
            local ok, a, b, c, d, e, f, g, h, i7 = pcall(sampGet3dTextInfoById, id)
            if ok then
                local text, x, y, z
                if type(a) == 'string' then
                    text, x, y, z = a, c, d, e
                elseif type(b) == 'string' then
                    text, x, y, z = b, d, e, f
                end
                if type(text) == 'string' and text ~= '' and #text < 4096 then
                    onNewSalePlate('3d_' .. id, text .. '', 5001, tonumber(x), tonumber(y), tonumber(z))
                end
            end
        end
    end
end

local function pumpSales()
    if not saleAlive then return end

    if pendingSell.dropListed then
        local had = pendingSell.active
        pendingSell.dropListed = false
        forgetListed()
        if had then
            chat('Лот на АБ сброшен: кик/дисконнект — выставьте машину заново')
        end
    end
    pcall(function()
        if type(sampGetGamestate) == 'function' and pendingSell.active then
            local gs = sampGetGamestate()
            if type(gs) == 'number' and gs < 3 then
                pendingSell.dropListed = true
            end
        end
    end)

    if needBuySnapshot then
        pcall(snapshotBuyFromPlate)
        needBuySnapshot = false
    end

    local nc = #incomingChat
    if nc > 0 then
        local chats = incomingChat
        incomingChat = {}
        for i = 1, nc do
            pcall(processDealChat, chats[i])
        end
    end

    local n = #incomingPlates
    if n > 0 then
        local batch = incomingPlates
        incomingPlates = {}
        for i = 1, n do
            local it = batch[i]
            pcall(onNewSalePlate, it.key, it.text, it.minPrice, it.x, it.y, it.z, it.sampId)
        end
    end

    pcall(pollSale3dTexts)

    if needSellSnapshot then
        pcall(snapshotSellFromPlate)
        if not isGenericCarName(pendingSell.model) or (os.clock() - (pendingSell.t or 0)) > 8 then
            needSellSnapshot = false
        end
    end
end

---------------------------------------------------------------------------
-- Хуки
---------------------------------------------------------------------------
local function chainArz(name, fn)
    if not (ok_arz and arz) then return end
    local prev = arz[name]
    arz[name] = function(packet)
        local r
        pcall(function() r = fn(packet) end)
        if prev then
            local okp, pr = pcall(prev, packet)
            if okp then
                if pr == false then return false end
                if type(pr) == 'table' then return pr end
            end
        end
        return r
    end
end

-- Средняя цена в техпаспорте. JS/диалог — из main, не из RPC.
local passportJob = { at = 0, model = '', tries = 0, sid = 0 }

local function pickCarName(s)
    s = normalizeName(s)
    if s == '' or #s < 2 or #s > 48 then return nil end
    if s:find('https://', 1, true) or s:find('http://', 1, true) then return nil end
    if s:match('^%w+_%w+$') then return nil end
    if s:match('^%d%d[%.%/%-]') then return nil end
    return s
end

local function carNameFromNode(node, depth)
    depth = depth or 0
    if depth > 8 or type(node) ~= 'table' then return nil end
    local keys = {
        'model', 'modelName', 'car', 'carName', 'vehicle', 'vehicleName',
        'transport', 'title', 'label', 'n'
    }
    for i = 1, #keys do
        local n = pickCarName(node[keys[i]])
        if n then return n end
    end
    if type(node.name) == 'string' then
        local n = pickCarName(node.name)
        if n then return n end
    end
    local lists = { node.vehicles, node.cars, node.transports, node.info, node.items, node.data }
    for i = 1, #lists do
        local list = lists[i]
        if type(list) == 'table' then
            if list[1] then
                local n = carNameFromNode(list[1], depth + 1)
                if n then return n end
            else
                local n = carNameFromNode(list, depth + 1)
                if n then return n end
            end
        end
    end
    for _, v in pairs(node) do
        if type(v) == 'table' then
            local n = carNameFromNode(v, depth + 1)
            if n then return n end
        end
    end
end

local function looksLikeVehicleDoc(doc, event, text)
    text = tostring(text or '')
    event = tostring(event or '')
    if text:find('Технический паспорт', 1, true) or text:find('технический паспорт', 1, true) then
        return true
    end
    if event:find('documents', 1, true) then
        local t = type(doc) == 'table' and tonumber(doc.type)
        if t == 1 or t == 2 or t == 4 then return false end
        if t == 6 then return true end
        if type(doc) == 'table' then
            if doc.mileage or doc.Mileage or doc.probeg or doc.odometer then return true end
            if (doc.model or doc.car or doc.vehicle or doc.vehicles)
                and (doc.plate or doc.number or doc.gosnumber or doc.mileage) then
                return true
            end
        end
    end
    return false
end

local function resolveAvgForModel(model)
    model = normalizeName(model)
    if model == '' then return nil, model end
    local p = lookupAvgPrice(model)
    if p then return p, model end
    local rows = findPrices(model)
    if #rows == 1 then return rows[1].price, rows[1].name end
    for i = 1, #rows do
        local n = rows[i].name
        if n:find(model, 1, true) or model:find(n, 1, true) then
            return rows[i].price, n
        end
    end
    local short = model:match('^(%S+%s+%S+)') or model:match('^(%S+)')
    if short and short ~= model then
        p = lookupAvgPrice(short)
        if p then return p, short end
        rows = findPrices(short)
        if #rows == 1 then return rows[1].price, rows[1].name end
    end
    return nil, model
end

local function parsePassportModel(text)
    text = stripColors(ensure_utf8(tostring(text or '')))
    local m = text:match('Транспорт:%s*([^\r\n]+)')
        or text:match('Модель:%s*([^\r\n]+)')
        or text:match('Название:%s*([^\r\n]+)')
    if not m then return nil end
    m = m:gsub('%s*%[%d+%]%s*$', '')
    return pickCarName(m)
end

local function isPassportDialog(id, title)
    id = tonumber(id) or 0
    title = stripColors(ensure_utf8(tostring(title or '')))
    if id == DIALOG_PASSPORT_ID then return true end
    return title:find('Технический паспорт транспорта', 1, true) and true or false
end

local function queuePassportDialogPatch(id, style, title, btn1, btn2, text)
    if not showPassportAvg[0] then return end
    text = tostring(text or '')
    local utf = ensure_utf8(text)
    if utf:find('Средняя цена:', 1, true) or utf:find('Дешевле средней', 1, true) then return end
    local model = parsePassportModel(text)
    local avg = model and resolveAvgForModel(model) or nil
    local lot = model and scanState.findLot(model) or nil
    if (not lot or lot < 1000000) and model then
        local ps = utf:match('Цена:%s*([^\r\n]+)')
        if ps and not ensure_utf8(ps):find('робег', 1, true) then
            local p = parsePlatePrice(ps)
            if p and p >= 1000000 then lot = p end
        end
    end
    local parts = { ('Средняя цена: %s'):format(avg and fmtMoney(avg) or 'нет в базе') }
    if lot and lot >= 1000000 then
        parts[#parts + 1] = ('Лот: %s'):format(fmtMoney(lot))
        local vs = vsAvgInfo(lot, avg)
        if vs.title == 'Дешевле средней' then
            parts[#parts + 1] = ('{%s}%s %s'):format(vs.samp, vs.title, vs.detail)
        end
    end
    local line = d('\n\n' .. table.concat(parts, '\n'))
    passportJob.patch = {
        id = tonumber(id) or DIALOG_PASSPORT_ID,
        style = tonumber(style) or 0,
        title = title or '',
        btn1 = (btn1 and tostring(btn1) ~= '') and btn1 or 'Закрыть',
        btn2 = btn2 or '',
        text = text .. line,
        at = os.clock() + 0.03,
    }
end

local function queuePassportOverlay(model, sid, lot)
    model = pickCarName(model) or normalizeName(model)
    if not showPassportAvg[0] or model == '' then return end
    passportJob.model = model
    passportJob.sid = tonumber(sid) or 0
    passportJob.lotPrice = tonumber(lot) or 0
    passportJob.at = os.clock() + 0.28
    passportJob.tries = 0
end

local function injectPassportPrice(model)
    if not (ok_arz and arz and arz.eval) then return end
    local avg = resolveAvgForModel(model)
    local lot = scanState.findLot(model) or tonumber(passportJob.lotPrice) or 0
    if lot < 1000000 then lot = 0 end
    local lines = { avg and ('Средняя: %s'):format(fmtMoney(avg)) or 'Средняя: нет в базе' }
    local color = '#f3f3f3'
    if lot >= 1000000 then
        lines[#lines + 1] = ('Лот: %s'):format(fmtMoney(lot))
        local vs = vsAvgInfo(lot, avg)
        if vs.title == 'Дешевле средней' then
            color = vs.color
            lines[#lines + 1] = (vs.title .. ' ' .. vs.detail):gsub('%s+$', '')
        end
    end
    local label = table.concat(lines, '\n')
    local q = '"' .. tostring(label):gsub('\\', '\\\\'):gsub('"', '\\"'):gsub('\r', ''):gsub('\n', '\\n') .. '"'
    local js = [[
var id='abarz-avg-price';
var old=document.getElementById(id);
if(old) old.remove();
var el=document.createElement('div');
el.id=id;
el.textContent=]] .. q .. [[;
el.style.cssText='width:100%;margin-top:6px;padding:10px 14px 16px;text-align:center;font-size:15px;font-weight:600;color:]] .. color .. [[;letter-spacing:.02em;box-sizing:border-box;white-space:pre-line;';
var needles=['Технический паспорт','Информация о транспорте','информацию о транспорте','Пробег','Владелец','Госномер','Гос. номер'];
var host=null;
var w=document.createTreeWalker(document.body,NodeFilter.SHOW_TEXT,null,false);
var n;
while(n=w.nextNode()){
  var v=n.nodeValue||'';
  for(var i=0;i<needles.length;i++){
    if(v.indexOf(needles[i])!==-1){ host=n.parentElement; break; }
  }
  if(host) break;
}
var box=host;
for(var i=0;i<12&&box&&box.parentElement;i++){
  if(box.scrollHeight>220) break;
  box=box.parentElement;
}
if(!box){
  box=document.querySelector('.dialog')
    ||document.querySelector('[class*="modal"]')
    ||document.querySelector('[class*="document"]')
    ||document.querySelector('[class*="passport"]');
}
if(!box) return;
box.appendChild(el);
]]
    pcall(arz.eval, js, tonumber(passportJob.sid) or 0)
end

local function pumpPassportOverlay()
    local patch = passportJob.patch
    if patch and os.clock() >= (patch.at or 0) then
        passportJob.patch = nil
        pcall(function()
            if ok_cef and cefDlg and cefDlg.Show then
                cefDlg.Show(patch.id, patch.title, patch.text, patch.btn1, patch.btn2, patch.style)
            elseif sampShowDialog then
                sampShowDialog(patch.id, patch.title, patch.text, patch.btn1, patch.btn2, patch.style)
            end
        end)
        return
    end
    if passportJob.at <= 0 then return end
    if os.clock() < passportJob.at then return end
    local model = passportJob.model
    passportJob.tries = (passportJob.tries or 0) + 1
    if passportJob.tries < 4 then
        passportJob.at = os.clock() + 0.35
    else
        passportJob.at = 0
    end
    injectPassportPrice(model or '')
end

local function noteVehiclePassport(packet)
    if not packet or not showPassportAvg[0] then return end
    local text = tostring(packet.text or '')
    local event = tostring(packet.event or '')
    -- Подсказка N / меню покупки — не техпаспорт, цену не рисуем
    if event:find('showModal', 1, true) or event:find('closeModal', 1, true) then
        return
    end
    local sid = tonumber(packet.server_id) or 0
    local doc = packet.json
    if type(doc) == 'table' and doc[1] then doc = doc[1] end
    if not looksLikeVehicleDoc(doc, event, text) then return end
    local model = carNameFromNode(doc)
    if not model then
        model = parsePassportModel(text)
    end
    local lot = model and scanState.findLot(model) or nil
    if (not lot or lot < 1000000) and type(doc) == 'table' then
        local raw = doc.sellPrice or doc.sell_price or doc.listingPrice or doc.lotPrice
        if type(raw) == 'table' then raw = raw.value or raw.price or raw[1] end
        local p
        if type(raw) == 'string' then p = parsePlatePrice(raw)
        elseif type(raw) == 'number' then p = math.floor(raw) end
        if p and p >= 1000000 then lot = p end
    end
    if model then queuePassportOverlay(model, sid, (lot and lot >= 1000000) and lot or 0) end
end

local function ingestAbCefPacket(packet)
    if not packet then return end
    if type(packet.json) ~= 'table' and type(packet.jsonText) == 'string' and packet.jsonText ~= '' then
        local ok, copy = safeDecodeJson(packet.jsonText)
        if ok then packet.json = copy end
    end
    if type(packet.json) ~= 'table' and type(packet.text) == 'string' and arz and arz.decode then
        local t = tostring(packet.text):gsub('^%s+', ''):gsub('%s+$', '')
        if t ~= '' and t ~= '[]' and t ~= '{}' then
            pcall(function()
                local fake = { id = 17, text = packet.text }
                arz.decode(fake)
                if fake.json then packet.json = fake.json end
                if type(fake.event) == 'string' and fake.event ~= '' then
                    packet.event = fake.event
                end
            end)
        end
    end
    pcall(noteVehiclePassport, packet)
    if not scanState.active then return end
    local text = tostring(packet.text or '')
    local event = tostring(packet.event or '')
    local jsonText = tostring(packet.jsonText or '')
    if jsonText == '' and type(packet.json) == 'string' then
        jsonText = packet.json
    elseif jsonText == '' and type(packet.json) == 'table' then
        local okj, encoded = pcall(encodeJson, packet.json)
        if okj then jsonText = encoded end
    end
    if isAbCefText(text, event) or isAbCefText(jsonText, event) then
        if text ~= '' then ingestTextBlob(text) end
        if jsonText ~= '' and jsonText ~= text then ingestTextBlob(jsonText) end
    end
end

local function queueCefSnap(packet)
    if not packet then return end
    local snap = { text = '', event = '', server_id = 0, jsonText = '' }
    pcall(function()
        local t = packet.text
        if type(t) == 'string' and t ~= '' and #t < 8000 then snap.text = t .. '' end
        local e = packet.event
        if type(e) == 'string' then snap.event = e .. '' end
        snap.server_id = tonumber(packet.server_id) or 0
        local j = packet.json
        if type(j) == 'string' and #j < 8000 then snap.jsonText = j .. '' end
    end)
    if snap.event == '' and snap.text ~= '' then
        local ev = snap.text:match("executeEvent%('([^']+)'")
        if ev then snap.event = ev .. '' end
        if snap.jsonText == '' then
            local js = snap.text:match("executeEvent%('[^']+',%s*`([^`]*)`%)")
            if js and #js < 8000 then snap.jsonText = js end
        end
    end
    if snap.text == '' and snap.jsonText == '' then return end
    incomingCef[#incomingCef + 1] = snap
    if #incomingCef > 24 then table.remove(incomingCef, 1) end
end

chainArz('onArizonaDisplay', queueCefSnap)
chainArz('onArizonaIncomingCef18', queueCefSnap)

-- Только окна АБ. Угон и похожие списки dlg не перезаписывают.
local lastDlgFinger = ''
local function onAnyDialog(id, style, title, btn1, btn2, text)
    local kind = classifyDialog(id, title, text)
    if kind == 'list' then
        scanState.listUntil = os.clock() + 4
    end
    local finger = tostring(tonumber(id) or 0) .. '\1' .. tostring(title or '') .. '\1' .. tostring(#(text or ''))
    if finger == lastDlgFinger and not scanState.forceDlg then return end
    lastDlgFinger = finger
    local titleU = stripColors(ensure_utf8(tostring(title or '')))
    if isPassportDialog(id, titleU) then
        queuePassportDialogPatch(id, style, title, btn1, btn2, text)
    end
    if title or text then
        pcall(noteDealDialog, title, text)
    end
    if not text then return end
    if kind ~= 'list' and kind ~= 'days' then return end
    ingestDialog(id, style, title, btn1, btn2, text)
end

local function pumpCefDialog()
    if #incomingCef > 0 then
        local batch = incomingCef
        incomingCef = {}
        for i = 1, #batch do
            pcall(ingestAbCefPacket, batch[i])
        end
    end
    if #incomingDlg > 0 then
        local batch = incomingDlg
        incomingDlg = {}
        for i = 1, #batch do
            local d = batch[i]
            pcall(onAnyDialog, d.id, d.style, d.title, d.btn1, d.btn2, d.text)
        end
    end
    if not (ok_cef and cefDlg) then return end
    local id = tonumber(cefDlg.GetId()) or -1
    if id < 0 then return end
    local title = cefDlg.GetTitle() or ''
    local text = cefDlg.GetDialogText() or ''
    if title == '' and text == '' then return end
    onAnyDialog(id, cefDlg.GetStyle(), title, cefDlg.GetButton1(), cefDlg.GetButton2(), text)
end

if ok_ev and ev then
    local prevDlg = ev.onShowDialog
    function ev.onShowDialog(id, style, title, btn1, btn2, text)
        pcall(function()
            incomingDlg[#incomingDlg + 1] = {
                id = tonumber(id) or 0,
                style = tonumber(style) or 0,
                title = type(title) == 'string' and (title .. '') or '',
                btn1 = type(btn1) == 'string' and (btn1 .. '') or '',
                btn2 = type(btn2) == 'string' and (btn2 .. '') or '',
                text = type(text) == 'string' and (text .. '') or '',
            }
            if #incomingDlg > 12 then table.remove(incomingDlg, 1) end
        end)
        if prevDlg then
            local ok, a = pcall(prevDlg, id, style, title, btn1, btn2, text)
            if ok then return a end
        end
    end

    local prevMat = ev.onSetObjectMaterialText
    function ev.onSetObjectMaterialText(id, data)
        pcall(function()
            local v
            if type(data) == 'table' then
                v = data.text
            elseif type(data) == 'string' then
                v = data
            end
            if type(v) == 'string' and v ~= '' then
                queuePlate({
                    key = 'obj_' .. tostring(tonumber(id) or 0),
                    text = v .. '',
                    sampId = tonumber(id),
                })
            end
        end)
        if prevMat then
            local ok, a, b = pcall(prevMat, id, data)
            if ok then return a, b end
        end
    end

    local prevMsg = ev.onServerMessage
    function ev.onServerMessage(color, text)
        pcall(function()
            if type(text) == 'string' and text ~= '' then
                incomingChat[#incomingChat + 1] = text .. ''
                if #incomingChat > 40 then table.remove(incomingChat, 1) end
            end
        end)
        if prevMsg then
            local ok, a = pcall(prevMsg, color, text)
            if ok then return a end
        end
    end

    local prevLost = ev.onConnectionLost
    function ev.onConnectionLost()
        pendingSell.dropListed = true
        if prevLost then pcall(prevLost) end
    end
    local prevClosed = ev.onConnectionClosed
    function ev.onConnectionClosed()
        pendingSell.dropListed = true
        if prevClosed then pcall(prevClosed) end
    end
else
    function onShowDialog(dialogId, style, title, button1, button2, text)
        onAnyDialog(dialogId, style, title, button1, button2, text)
    end
end

---------------------------------------------------------------------------
-- Чат пользователей ABarz на ТЕКУЩЕМ сервере
---------------------------------------------------------------------------
local chatOn = new.bool(false)
local chatInput = new.char[192]()
local chatLines = {} -- { time, nick, text, self }
local chatScrollDown = false
local chatState = {
    cid = '',
    serverNum = nil,
    serverName = '',
    serverKey = '',
    topic = '',
    sinceId = nil,
    seen = {},
    seenOrder = {},
    polling = false,
    status = 'выкл',
    pollMs = 12000, 
    inFlight = false,     -- один запрос за раз
    lastErrAt = 0,
    wantMouse = false,
}

local ok_effil, effil = pcall(require, 'effil')

-- Очередь callback HTTP: не трогаем Lua/ImGui
local httpCbQueue = {}
local function queueHttpCb(cb, body, err, code)
    if type(cb) ~= 'function' then return end
    httpCbQueue[#httpCbQueue + 1] = { cb, body, err, code }
end
local function drainHttpCbQueue()
    if scanState.httpDraining then return end
    local n = #httpCbQueue
    if n == 0 then return end
    scanState.httpDraining = true
    local batch = httpCbQueue
    httpCbQueue = {}
    for i = 1, n do
        local item = batch[i]
        pcall(item[1], item[2], item[3], item[4])
    end
    scanState.httpDraining = false
end

local function jsonEsc(s)
    s = tostring(s or '')
        :gsub('\\', '\\\\')
        :gsub('"', '\\"')
        :gsub('\r', '')
        :gsub('\n', ' ')
        :gsub('\t', ' ')
    return s
end

local function ensureChatCid()
    if chatState.cid ~= '' then return chatState.cid end
    chatState.cid = ('%s-%d-%d'):format(
        tostring(os.time()),
        math.random(1000, 9999),
        math.floor((os.clock() % 1) * 1e6)
    )
    return chatState.cid
end

local function myNickname()
    local result, id = sampGetPlayerIdByCharHandle(PLAYER_PED)
    if result and type(id) == 'number' and sampGetPlayerNickname then
        local nick = sampGetPlayerNickname(id)
        if nick and nick ~= '' then return ensure_utf8(nick) end
    end
    return 'Я'
end

local function pushScriptChat(nick, text, isSelf, shareUrl)
    nick = tostring(nick or '?')
    text = tostring(text or '')
    if text == '' then return end
    if not shareUrl or shareUrl == '' then
        shareUrl = tostring(text):match('(https://ntfy%.sh/file/[%w%._%-]+)')
    end
    chatLines[#chatLines + 1] = {
        time = os.date('%H:%M:%S'),
        nick = nick,
        text = text,
        self = isSelf and true or false,
        shareUrl = shareUrl or '',
    }
    while #chatLines > 120 do table.remove(chatLines, 1) end
    chatScrollDown = true
end

-- Асинхронно через effil. Нельзя wait() внутри pcall/OnFrame — MoonLoader убивает скрипт
-- («cannot resume non-suspended coroutine»). Результат забираем из main.
-- Важно: из effil нельзя возвращать table с именованными ключами — только примитивы / array.
local function httpRequestAsync(method, url, body, headers, callback, timeout)
    callback = callback or function() end
    if not ok_effil then
        queueHttpCb(callback, nil, 'нет сети', 0)
        return
    end
    timeout = tonumber(timeout) or 5
    local hk1, hv1, hk2, hv2, hk3, hv3
    if type(headers) == 'table' then
        local n = 0
        for k, v in pairs(headers) do
            n = n + 1
            if n == 1 then hk1, hv1 = tostring(k), tostring(v)
            elseif n == 2 then hk2, hv2 = tostring(k), tostring(v)
            elseif n == 3 then hk3, hv3 = tostring(k), tostring(v); break
            end
        end
    end

    local runner = effil.thread(function(m, u, b, a1, b1, a2, b2, a3, b3, to)
        local ok, pack = pcall(function()
            local https_m = require('ssl.https')
            local ltn12_m = require('ltn12')
            local http_m = require('socket.http')
            to = tonumber(to) or 5
            http_m.TIMEOUT = to
            https_m.TIMEOUT = to
            local hdrs = {}
            if a1 and b1 then hdrs[a1] = b1 end
            if a2 and b2 then hdrs[a2] = b2 end
            if a3 and b3 then hdrs[a3] = b3 end
            b = b or ''
            if b ~= '' then hdrs['Content-Length'] = tostring(#b) end
            local chunks = {}
            local hops, text, c, one, rh = 0, '', 0, nil, nil
            while hops < 5 do
                hops = hops + 1
                chunks = {}
                one, c, rh = https_m.request({
                    url = u,
                    method = m,
                    headers = hdrs,
                    source = (#b > 0) and ltn12_m.source.string(b) or nil,
                    sink = ltn12_m.sink.table(chunks),
                })
                c = tonumber(c) or 0
                text = table.concat(chunks)
                if text == '' and type(one) == 'string' then text = one end
                if (c == 301 or c == 302 or c == 303 or c == 307 or c == 308) and type(rh) == 'table' then
                    local loc = rh.location or rh.Location
                    if loc and loc ~= '' then
                        loc = tostring(loc)
                        if not loc:find('^https?://') then
                            local origin = tostring(u):match('^(https?://[^/]+)') or 'https://raw.githubusercontent.com'
                            if loc:sub(1, 1) ~= '/' then loc = '/' .. loc end
                            loc = origin .. loc
                        end
                        u = loc
                        m = 'GET'
                        b = ''
                        hdrs['Content-Length'] = nil
                    else
                        break
                    end
                else
                    break
                end
            end
            if text == '' and type(rh) == 'table' then
                local loc = rh.location or rh.Location
                if loc and loc ~= '' then text = tostring(loc) end
            end
            if c == 0 and (one == 1 or one == true) then
                c = 200
            end
            if c >= 200 and c < 300 then
                return { true, text or '', c }
            end
            local why = tostring(text or ''):gsub('%s+', ' ')
            why = why:gsub('^%s+', ''):gsub('%s+$', '')
            if why == '' then why = ('HTTP %d'):format(c) end
            if #why > 140 then why = why:sub(1, 140) end
            return { false, why, c }
        end)
        if not ok then
            return { false, tostring(pack), 0 }
        end
        return pack
    end)

    local th = runner(
        string.upper(tostring(method or 'GET')),
        tostring(url),
        tostring(body or ''),
        hk1, hv1, hk2, hv2, hk3, hv3,
        timeout
    )
    local jobs = scanState.httpJobs
    if type(jobs) ~= 'table' then
        jobs = {}
        scanState.httpJobs = jobs
    end
    jobs[#jobs + 1] = {
        th = th,
        cb = callback,
        untilAt = os.clock() + timeout + 8,
    }
end

scanState.pumpHttpJobs = function()
    local jobs = scanState.httpJobs
    if type(jobs) ~= 'table' or #jobs == 0 then return end
    local rest, now = {}, os.clock()
    for i = 1, #jobs do
        local job = jobs[i]
        local done, okFlag, payload, code
        pcall(function()
            local th = job.th
            if not th then
                done, okFlag, payload, code = true, false, 'нет потока', 0
                return
            end
            if th:status() == 'failed' then
                done, okFlag, payload, code = true, false, 'effil failed', 0
                return
            end
            local r = th:get(0)
            if not r then
                if now > (job.untilAt or 0) then
                    done, okFlag, payload, code = true, false, 'timeout', 0
                end
                return
            end
            done = true
            local tr = type(r)
            if tr == 'table' or tr == 'userdata' then
                okFlag, payload, code = r[1], r[2], r[3]
            elseif tr == 'boolean' or tr == 'number' then
                okFlag, payload, code = r, th:get(0), th:get(0)
            end
        end)
        if done then
            code = tonumber(code) or 0
            if okFlag == true or okFlag == 1 then
                queueHttpCb(job.cb, tostring(payload or ''), nil, code > 0 and code or 200)
            else
                queueHttpCb(job.cb, nil, tostring(payload or 'error'), code)
            end
        else
            rest[#rest + 1] = job
        end
    end
    scanState.httpJobs = rest
end

scanState.verNewer = function(remote, localv)
    local function parts(v)
        local t, s = {}, tostring(v or ''):lower():gsub('^v', '')
        for n in s:gmatch('%d+') do t[#t + 1] = tonumber(n) or 0 end
        return t
    end
    local a, b = parts(localv), parts(remote)
    if #a == 0 or #b == 0 then return false end
    local n = math.max(#a, #b)
    for i = 1, n do
        local x, y = a[i] or 0, b[i] or 0
        if y > x then return true end
        if y < x then return false end
    end
    return false
end

scanState.gitlabGet = function(file, timeout, cb)
    file = tostring(file or 'autoabarz.lua')
    -- github.com/.../raw/... редиректит на HTML у LuaSocket.
    -- Сразу raw.githubusercontent.com — это те же файлы, что по ссылкам пользователя.
    local name = 'autoabarz.lua'
    if file:find('version.json', 1, true) then name = 'version.json' end
    local url = 'https://raw.githubusercontent.com/andergr0ynd/autoabarz/refs/heads/main/' .. name
    local hdrs = {
        ['User-Agent'] = 'Mozilla/5.0 AutoABarz/1.6',
        ['Accept'] = '*/*',
    }
    if type(scanState.gitlabToken) == 'string' and scanState.gitlabToken ~= '' then
        hdrs['Authorization'] = 'Bearer ' .. scanState.gitlabToken
    end
    httpRequestAsync('GET', url, '', hdrs, cb, timeout or 30)
end

scanState.applyUpdate = function(body, latest)
    if type(body) ~= 'string' or #body < 4000 then return false, 'файл короткий' end
    if body:find('<html', 1, true) or body:find('<HTML', 1, true) or body:find('<!DOCTYPE', 1, true) then
        return false, 'пришла страница, не lua'
    end
    if not body:find('script_name', 1, true) or not body:find('function main', 1, true) then
        return false, 'это не скрипт'
    end
    local path = thisScript().path
    if type(path) ~= 'string' or path == '' then return false, 'нет пути скрипта' end
    local bak = path .. '.bak'
    pcall(function()
        local old = io.open(path, 'rb')
        if old then
            local prev = old:read('*a')
            old:close()
            local b = io.open(bak, 'wb')
            if b then b:write(prev) b:close() end
        end
    end)
    local f = io.open(path, 'wb')
    if not f then return false, 'не записалось' end
    f:write(body)
    f:close()
    chat(('Обновлён до %s. Перезагрузка…'):format(tostring(latest or '')))
    lua_thread.create(function()
        wait(400)
        pcall(function() thisScript():reload() end)
    end)
    return true
end

scanState.checkUpdate = function(manual)
    if scanState.updateBusy then
        if manual then chat('Обновление уже идёт') end
        return
    end
    scanState.updateBusy = true
    local cur = tostring(thisScript().version or '0')
    if manual then chat('Проверяю GitHub…') end
    scanState.gitlabGet('version.json', 20, function(res, err, code)
        if type(res) ~= 'string' or res == '' then
            scanState.updateBusy = false
            if manual then chat('GitHub недоступен' .. (err and (': ' .. tostring(err)) or '')) end
            return
        end
        local ok, data = safeDecodeJson(res)
        local latest = ok and type(data) == 'table' and tostring(data.latest or data.version or '')
        if not latest or latest == '' then
            scanState.updateBusy = false
            if manual then chat('Не прочитался version.json') end
            return
        end
        if not scanState.verNewer(latest, cur) then
            scanState.updateBusy = false
            if manual then chat(('Уже актуальная версия %s'):format(cur)) end
            return
        end
        chat(('Есть обновление: %s → %s'):format(cur, latest))
        scanState.gitlabGet('autoabarz.lua', 60, function(body, err2)
            if type(body) ~= 'string' then
                scanState.updateBusy = false
                chat('Не скачался скрипт' .. (err2 and (': ' .. tostring(err2)) or ''))
                return
            end
            local done, why = scanState.applyUpdate(body, latest)
            scanState.updateBusy = false
            if not done then chat('Обновление не применилось: ' .. tostring(why or '')) end
        end)
    end)
end

local shareState = { busy = false, lastUrl = '', msg = '' }

local function copyShareUrl(url)
    url = tostring(url or '')
    if url == '' then return end
    pcall(setClipboardText, url)
end

local function resolveShareFetchUrl(raw)
    raw = tostring(raw or ''):gsub('^%s+', ''):gsub('%s+$', '')
    if raw:match('^https?://') then
        return raw
    end
    return nil
end

local function extractShareUrl(res)
    res = tostring(res or ''):gsub('^%s+', ''):gsub('%s+$', '')
    if res == '' then return nil end
    local url = res:match('(https?://[%w%._/%-%?=&%%#]+)')
    if url then
        url = url:gsub('[%)%]}>,;]+$', '')
        return url
    end
    return nil
end

local function parseServerNumFromName(name)
    name = ensure_utf8(tostring(name or ''))
    local n = name:match('#%s*(%d+)')
        or name:match('№%s*(%d+)')
        or name:match('%[(%d+)%]')
        or name:match('[Ss]erver%s*[#:.]?%s*(%d+)')
        or name:match('[Сс]ервер%s*[#:.]?%s*(%d+)')
    n = tonumber(n)
    if n and n >= 1 and n <= 40 then return n end
    return nil
end

-- IP важнее имени: лаунчер часто оставляет Casa-Grande, хотя уже Vice City
local CHAT_BY_IP = {
    ['80.66.82.147'] = { label = 'Vice City', topic = 'abarzv161-qk7-hvc1' },
}

local function normChatName(s)
    s = ensure_utf8(tostring(s or '')):lower()
    return (s:gsub('[%s%-%|_%.]+', ''))
end

local function resolveArizonaServer()
    local name = ''
    pcall(function() name = sampGetCurrentServerName() or '' end)
    name = ensure_utf8(name)
    local ip, port = '', 0
    pcall(function()
        ip, port = sampGetCurrentServerAddress()
    end)
    ip = tostring(ip or '')
    port = tonumber(port) or 0
    local key = ip .. ':' .. tostring(port)
    local offline = (ip == '' or ip == '0.0.0.0' or port == 0)

    if offline and chatState.topic ~= '' then
        return chatState.serverNum, chatState.serverName, chatState.topic
    end
    if chatState.topic ~= '' and chatState.serverKey == key and key ~= ':' then
        return chatState.serverNum, chatState.serverName, chatState.topic
    end

    local special = CHAT_BY_IP[ip]
    if not special and normChatName(name):find('vicecity', 1, true) then
        special = { label = 'Vice City', topic = 'abarzv161-qk7-hvc1' }
    end
    if special then
        return nil, special.label, special.topic
    end

    local num = parseServerNumFromName(name)
    local label = name ~= '' and name or (ip .. ':' .. tostring(port))
    if not num then
        local host = (ip .. '_' .. tostring(port)):gsub('[^%w]', '')
        if host == '' then host = 'unknown' end
        return nil, label, 'abarzv161-qk7-h' .. host
    end
    return num, label, ('abarzv161-qk7-s%d'):format(num)
end

local function refreshChatRoom()
    local num, label, topic = resolveArizonaServer()
    local old = chatState.topic
    local ip, port = '', 0
    pcall(function()
        ip, port = sampGetCurrentServerAddress()
    end)
    chatState.serverKey = tostring(ip or '') .. ':' .. tostring(tonumber(port) or 0)
    chatState.serverNum = num
    chatState.serverName = label
    chatState.topic = topic
    if old ~= '' and topic ~= '' and topic ~= old then
        chatState.sinceId = nil
        chatState.seen = {}
        chatState.seenOrder = {}
        pushScriptChat('Система', ('Чат: %s'):format(label), false)
    end
    return topic
end

local function rememberChatId(key)
    if not key or key == '' then return false end
    if chatState.seen[key] then return true end
    chatState.seen[key] = true
    local order = chatState.seenOrder
    if not order then
        order = {}
        chatState.seenOrder = order
    end
    order[#order + 1] = key
    while #order > 180 do
        local old = table.remove(order, 1)
        if old ~= key then chatState.seen[old] = nil end
    end
    return false
end

local function ingestNtfyLine(line)
    line = tostring(line or ''):gsub('^%s+', ''):gsub('%s+$', '')
    if line == '' then return end
    local ok, obj = safeDecodeJson( line)
    if not ok or type(obj) ~= 'table' then return end
    if obj.event and obj.event ~= 'message' then return end
    local mid = tostring(obj.id or '')
    if mid ~= '' then
        if rememberChatId(mid) then return end
        chatState.sinceId = mid
    end

    local msg = tostring(obj.message or '')
    local nick = tostring(obj.title or '?')
    local text, cid = msg, ''
    if msg:sub(1, 1) == '{' then
        local ok2, p = safeDecodeJson( msg)
        if ok2 and type(p) == 'table' and p.text then
            text = tostring(p.text)
            nick = tostring(p.nick or nick)
            cid = tostring(p.cid or '')
        end
    else
        local a, b, c = msg:match('^([^|]+)|([^|]+)|(.+)$')
        if c then cid, nick, text = a, b, c end
    end
    if cid ~= '' and cid == chatState.cid then return end
    local shareUrl = ''
    local att = obj.attachment
    if type(att) == 'table' and att.url then
        shareUrl = tostring(att.url)
    end
    local fp = shareUrl ~= '' and ('u:' .. shareUrl)
        or (tostring(obj.time or '') .. '|' .. nick .. '|' .. text)
    if fp ~= '|' and rememberChatId(fp) then return end
    if shareUrl ~= '' then
        for _, m in ipairs(chatLines) do
            if m.shareUrl == shareUrl then return end
        end
        if text == '' or text:lower():find('file', 1, true) then
            text = 'База цен'
        end
        pushScriptChat(nick ~= '' and nick or 'ABarz', text, false, shareUrl)
        return
    end
    if text == '' then return end
    for i = #chatLines, math.max(1, #chatLines - 40), -1 do
        local m = chatLines[i]
        if m and not m.self and m.nick == nick and m.text == text then
            return
        end
    end
    pushScriptChat(nick, text, false)
end

local function onPollResult(body, err, code)
    chatState.inFlight = false
    code = tonumber(code) or 0
    if not body then
        if code == 429 then
            chatState.pollMs = math.min(120000, math.max(30000, (chatState.pollMs or 12000) * 2))
            chatState.status = ('лимит 429 · пауза %ds'):format(math.floor(chatState.pollMs / 1000))
            if os.clock() - (chatState.lastErrAt or 0) > 20 then
                chatState.lastErrAt = os.clock()
                pushScriptChat('Система', 'Слишком частые запросы — увеличил паузу.', false)
            end
        else
            chatState.pollMs = math.min(60000, (chatState.pollMs or 12000) + 3000)
            chatState.status = 'ошибка: ' .. tostring(err or '?')
        end
        return
    end
    -- успех — мягко возвращаем интервал к 12с
    chatState.pollMs = 12000
    chatState.status = 'онлайн'
    for line in body:gmatch('[^\r\n]+') do
        ingestNtfyLine(line)
    end
end

local function chatPollOnce()
    if not chatOn[0] or chatState.inFlight then return end
    local topic = refreshChatRoom()
    if not topic or topic == '' then return end
    local url = 'https://ntfy.sh/' .. topic .. '/json?poll=1'
    if chatState.sinceId and chatState.sinceId ~= '' then
        url = url .. '&since=' .. tostring(chatState.sinceId)
    else
        -- без since ntfy отдаёт ВЕСЬ кэш топика — при открытии это дублирует историю
        url = url .. '&since=30m'
    end
    chatState.inFlight = true
    httpRequestAsync('GET', url, '', {
        ['User-Agent'] = 'ABarz/1.6',
        ['Accept'] = 'application/x-ndjson',
    }, onPollResult)
end

local function chatSendHttp(nick, text, onDone)
    local topic = refreshChatRoom()
    if not topic or topic == '' then return end
    local cid = ensureChatCid()
    local payload = ('{"v":1,"cid":"%s","nick":"%s","text":"%s"}'):format(
        jsonEsc(cid), jsonEsc(nick), jsonEsc(text))
    httpRequestAsync('PUT', 'https://ntfy.sh/' .. topic, payload, {
        ['User-Agent'] = 'ABarz/1.6',
        ['Content-Type'] = 'text/plain; charset=utf-8',
        ['Title'] = nick:sub(1, 64),
    }, function(body, err, code)
        if onDone then onDone(err, code) end
    end)
end

local function startChatPoller()
    if chatState.polling then return end
    if not ok_effil then
        pushScriptChat('Система', 'Чат недоступен.', false)
        chat('Чат недоступен')
        chatOn[0] = false
        return
    end
    chatState.polling = true
    chatState.pollMs = 12000
    chatState.inFlight = false
    lua_thread.create(function()
        ensureChatCid()
        refreshChatRoom()
        local room = tostring(chatState.serverName)
        if room == '' then
            room = chatState.serverNum
                and ('сервер #' .. tostring(chatState.serverNum))
                or 'чат'
        end
        local hello = ('Чат: %s'):format(room)
        local already = false
        for i = #chatLines, math.max(1, #chatLines - 8), -1 do
            local m = chatLines[i]
            if m and m.nick == 'Система' and m.text == hello then already = true break end
        end
        if not already then
            pushScriptChat('Система', hello, false)
        end
        -- первый poll чуть позже, чтобы не спамить при включении
        wait(800)
        while chatOn[0] do
            pcall(chatPollOnce)
            local pause = tonumber(chatState.pollMs) or 12000
            if pause < 8000 then pause = 8000 end
            wait(pause)
        end
        chatState.polling = false
        chatState.inFlight = false
        chatState.status = 'выкл'
    end)
end

local function setChatEnabled(on)
    chatOn[0] = on and true or false
    if chatOn[0] then
        -- не сбрасываем seen/sinceId: иначе при открытии ntfy снова отдаёт
        -- те же сообщения, и они накладываются на уже показанные
        chatState.status = 'подключение...'
        chatState.pollMs = 12000
        startChatPoller()
        if chatOn[0] then
            chat('Чат включён')
        end
    else
        chat('Чат выключен')
    end
end

local function sendScriptChat(raw)
    if not chatOn[0] then
        chat('Сначала включи чат')
        return
    end
    if not ok_effil then
        chat('Чат недоступен')
        return
    end
    raw = tostring(raw or ''):gsub('[\r\n]+', ' '):gsub('^%s+', ''):gsub('%s+$', '')
    if raw == '' then return end
    if #raw > 180 then raw = raw:sub(1, 180) end
    local nick = myNickname()
    pushScriptChat(nick, raw, true)
    chatSendHttp(nick, raw, function(err, code)
        if err then
            if code == 429 then
                chatState.pollMs = math.min(120000, 45000)
                pushScriptChat('Система', 'Лимит отправки (429). Подожди немного.', false)
            else
                pushScriptChat('Система', 'Не отправилось: ' .. tostring(err), false)
            end
        end
    end)
end

local function startSharePrices()
    if shareState.busy then return end
    if not next(prices) then
        shareState.msg = 'база пустая'
        chat('Нечем делиться — сначала скан или скачай чужую базу')
        return
    end
    if not chatOn[0] then
        setChatEnabled(true)
    end
    local topic = refreshChatRoom()
    if not topic or topic == '' then
        chat('Не удалось определить сервер')
        return
    end
    local payload, n = buildShareJson()
    if not payload or payload == '' then
        chat('Не удалось собрать базу')
        return
    end
    shareState.busy = true
    shareState.msg = 'загрузка...'
    local nick = tostring(myNickname() or 'ABarz'):gsub('[\r\n]', ''):sub(1, 64)
    httpRequestAsync('PUT', 'https://ntfy.sh/' .. topic, payload, {
        ['User-Agent'] = 'ABarz/1.6',
        ['Filename'] = 'abarz.json',
        ['Title'] = nick ~= '' and nick or 'ABarz',
    }, function(res, err, code)
        shareState.busy = false
        local url = ''
        local ok, obj = safeDecodeJson( tostring(res or ''))
        if ok and type(obj) == 'table' and type(obj.attachment) == 'table' then
            url = tostring(obj.attachment.url or '')
        end
        if url == '' then
            url = extractShareUrl(res) or ''
        end
        if url:find('ntfy.sh/file', 1, true) then
            shareState.lastUrl = url
            shareState.msg = 'в чате'
            copyShareUrl(url)
            local already = false
            for _, m in ipairs(chatLines) do
                if m.shareUrl == url then already = true break end
            end
            if not already then
                pushScriptChat(nick ~= '' and nick or myNickname(), 'База цен', true, url)
            end
            chat(('База в чате (%d машин). Скачать — кнопка у сообщения.'):format(n or 0))
            return
        end
        local why = tostring(err or res or '')
        shareState.msg = 'не удалось поделиться'
        if why ~= '' and #why < 90 and not why:find('<', 1, true) then
            chat('Не удалось поделиться базой (' .. why .. ')')
        else
            chat('Не удалось поделиться базой')
        end
    end, 60)
end

local function startDownloadPrices(raw)
    if shareState.busy then return end
    raw = tostring(raw or ''):gsub('^%s+', ''):gsub('%s+$', '')
    if raw == '' then
        shareState.msg = 'нет ссылки'
        chat('В чате нет ссылки на базу')
        return
    end
    local url = resolveShareFetchUrl(raw)
    if not url then
        shareState.msg = 'непонятная ссылка'
        chat('Непонятная ссылка на базу')
        return
    end
    shareState.busy = true
    shareState.msg = 'скачивание...'
    httpRequestAsync('GET', url, '', {
        ['User-Agent'] = 'ABarz/1.6',
        ['Accept'] = 'application/json, text/plain, */*',
    }, function(res, err, code)
        shareState.busy = false
        if err or not res or res == '' then
            shareState.msg = 'не удалось скачать'
            local why = tostring(err or '')
            if why ~= '' and #why < 80 and not why:find('<', 1, true) then
                chat('Не удалось скачать базу (' .. why .. ')')
            else
                chat('Не удалось скачать базу')
            end
            return
        end
        local added, ierr = importPricesFromText(res)
        if ierr then
            shareState.msg = ierr
            chat('Не удалось загрузить: ' .. ierr)
            return
        end
        shareState.msg = ('загружено: %d'):format(added)
        chat(('База скачана: %d машин'):format(added))
    end, 60)
end

---------------------------------------------------------------------------
-- UI  (во вложенной функции: в чанке Lua 5.1 максимум 200 local)
---------------------------------------------------------------------------
local win = new.bool(false)

scanState.keyName = function(vk)
    vk = tonumber(vk) or 0
    local n = ({
        [0x70]='F1',[0x71]='F2',[0x72]='F3',[0x73]='F4',[0x74]='F5',[0x75]='F6',
        [0x76]='F7',[0x77]='F8',[0x78]='F9',[0x79]='F10',[0x7A]='F11',[0x7B]='F12',
        [0x2D]='Insert',[0x2E]='Delete',[0x24]='Home',[0x23]='End',
        [0x21]='PageUp',[0x22]='PageDown',[0x60]='Num0',[0x61]='Num1',[0x62]='Num2',
        [0x63]='Num3',[0x64]='Num4',[0x65]='Num5',[0x66]='Num6',[0x67]='Num7',
        [0x68]='Num8',[0x69]='Num9',[0x6A]='Num*',[0x6B]='Num+',[0x6D]='Num-',[0x6F]='Num/',
        [0x10]='Shift',[0x11]='Ctrl',[0x12]='Alt',[0x14]='CapsLock',
        [0xA0]='LShift',[0xA1]='RShift',[0xA2]='LCtrl',[0xA3]='RCtrl',[0xA4]='LAlt',[0xA5]='RAlt',
    })[vk]
    if n then return n end
    if vk >= 0x30 and vk <= 0x39 then return string.char(vk) end
    if vk >= 0x41 and vk <= 0x5A then return string.char(vk) end
    if vk <= 0 then return 'нет' end
    return ('VK %d'):format(vk)
end

scanState.saveSettings = function()
    pcall(function()
        ensureDir(DATA_DIR)
        local f = io.open(DATA_DIR .. '\\settings.json', 'w')
        if not f then return end
        f:write(encodeJson({
            menuVk = tonumber(scanState.menuVk) or 0x72,
            chatVk = tonumber(scanState.chatVk) or 0x74,
            mouseVk = tonumber(scanState.mouseVk) or 0x12,
            menuOn = not not scanState.menuBindOn[0],
            chatOn = not not scanState.chatBindOn[0],
            mouseOn = not not scanState.mouseBindOn[0],
            autoOn = not not scanState.autoUpdateOn[0],
            gitlabRaw = tostring(scanState.gitlabRaw or ''),
            gitlabToken = tostring(scanState.gitlabToken or ''),
        }))
        f:close()
    end)
end

scanState.loadSettings = function()
    pcall(function()
        local f = io.open(DATA_DIR .. '\\settings.json', 'r')
        if not f then return end
        local raw = f:read('*a')
        f:close()
        local ok, data = safeDecodeJson(raw)
        if not ok or type(data) ~= 'table' then return end
        if tonumber(data.menuVk) then scanState.menuVk = tonumber(data.menuVk) end
        if tonumber(data.chatVk) then scanState.chatVk = tonumber(data.chatVk) end
        if tonumber(data.mouseVk) then scanState.mouseVk = tonumber(data.mouseVk) end
        if data.menuOn ~= nil then scanState.menuBindOn[0] = not not data.menuOn end
        if data.chatOn ~= nil then scanState.chatBindOn[0] = not not data.chatOn end
        if data.mouseOn ~= nil then scanState.mouseBindOn[0] = not not data.mouseOn end
        if data.autoOn ~= nil then scanState.autoUpdateOn[0] = not not data.autoOn end
        if type(data.gitlabRaw) == 'string' and data.gitlabRaw:find('https://', 1, true)
            and data.gitlabRaw:find('andergr0ynd', 1, true)
            and (data.gitlabRaw:find('github.com', 1, true)
                or data.gitlabRaw:find('githubusercontent', 1, true)) then
            scanState.gitlabRaw = data.gitlabRaw
        end
        if type(data.gitlabToken) == 'string' then
            scanState.gitlabToken = data.gitlabToken
        end
    end)
end

scanState.justKey = function(vk)
    vk = tonumber(vk) or 0
    if vk <= 0 then return false end
    local down = false
    pcall(function() down = isKeyDown(vk) and true or false end)
    local was = scanState.bindHeld[vk]
    scanState.bindHeld[vk] = down
    return down and not was
end

scanState.pumpBinds = function()
    local busy = false
    pcall(function()
        if sampIsChatInputActive and sampIsChatInputActive() then busy = true end
    end)
    pcall(function()
        if isPauseMenuActive and isPauseMenuActive() then busy = true end
    end)
    if scanState.bindWait then
        if scanState.justKey(0x1B) then
            scanState.bindWait = nil
            return
        end
        if busy then return end
        local keys = {
            0x70,0x71,0x72,0x73,0x74,0x76,0x78,0x79,0x7A,0x7B,
            0x2D,0x2E,0x24,0x23,0x21,0x22,
            0x60,0x61,0x62,0x63,0x64,0x65,0x66,0x67,0x68,0x69,
            0x6A,0x6B,0x6D,0x6F,
        }
        if scanState.bindWait == 'mouse' then
            keys = {
                0x12,0xA4,0xA5,0x11,0xA2,0xA3,0x10,0xA0,0xA1,0x14,
                0x70,0x71,0x72,0x73,0x74,0x76,0x78,0x79,0x7A,0x7B,
                0x2D,0x2E,0x24,0x23,0x21,0x22,
                0x60,0x61,0x62,0x63,0x64,0x65,0x66,0x67,0x68,0x69,
            }
        end
        for i = 1, #keys do
            local vk = keys[i]
            if scanState.justKey(vk) then
                if scanState.bindWait == 'menu' then
                    scanState.menuVk = vk
                    if scanState.chatVk == vk then scanState.chatBindOn[0] = false end
                    if scanState.mouseVk == vk then scanState.mouseBindOn[0] = false end
                    chat('Бинд меню: ' .. scanState.keyName(vk))
                elseif scanState.bindWait == 'chat' then
                    scanState.chatVk = vk
                    if scanState.menuVk == vk then scanState.menuBindOn[0] = false end
                    if scanState.mouseVk == vk then scanState.mouseBindOn[0] = false end
                    chat('Бинд чата: ' .. scanState.keyName(vk))
                else
                    scanState.mouseVk = vk
                    if scanState.menuVk == vk then scanState.menuBindOn[0] = false end
                    if scanState.chatVk == vk then scanState.chatBindOn[0] = false end
                    chat('Мышь в чате: ' .. scanState.keyName(vk) .. ' (удерживать)')
                end
                scanState.bindWait = nil
                scanState.saveSettings()
                return
            end
        end
        return
    end
    if busy then return end
    if scanState.menuBindOn[0] and scanState.justKey(scanState.menuVk) then
        win[0] = not win[0]
    end
    if scanState.chatBindOn[0] and scanState.justKey(scanState.chatVk) then
        setChatEnabled(not chatOn[0])
    end
end

local function setupUi()
local searchBuf = new.char[64]()
local filter = ''
local page = 1
local WIN_W, WIN_H, SIDEBAR = 760, 520, 168
local CHAT_W, CHAT_H = 380, 470
local accentCol = { 0.36, 0.58, 1.0 }
local PAGES = {
    { id = 'home', title = 'Обзор' },
    { id = 'base', title = 'База' },
    { id = 'scan', title = 'Скан' },
    { id = 'deals', title = 'Сделки' },
}

local function accent()
    return imgui.ImVec4(accentCol[1], accentCol[2], accentCol[3], 1)
end

local function accentDim(a)
    return imgui.ImVec4(accentCol[1], accentCol[2], accentCol[3], a or 0.18)
end

local function u32(r, g, b, a)
    return imgui.ColorConvertFloat4ToU32(imgui.ImVec4(r, g, b, a or 1))
end

local function applyStyle()
    local s = imgui.GetStyle()
    s.WindowRounding = 10
    s.ChildRounding = 8
    s.FrameRounding = 6
    s.PopupRounding = 6
    s.GrabRounding = 4
    s.ScrollbarRounding = 8
    s.WindowBorderSize = 0
    s.ChildBorderSize = 0
    s.FrameBorderSize = 0
    s.WindowPadding = imgui.ImVec2(0, 0)
    s.FramePadding = imgui.ImVec2(10, 6)
    s.ItemSpacing = imgui.ImVec2(10, 8)
    s.ScrollbarSize = 8
    s.GrabMinSize = 10
    local c = s.Colors
    c[imgui.Col.Text] = imgui.ImVec4(0.91, 0.92, 0.94, 1)
    c[imgui.Col.TextDisabled] = imgui.ImVec4(0.55, 0.57, 0.63, 1)
    c[imgui.Col.WindowBg] = imgui.ImVec4(0.055, 0.06, 0.08, 0.96)
    c[imgui.Col.ChildBg] = imgui.ImVec4(0.07, 0.08, 0.11, 0.55)
    c[imgui.Col.PopupBg] = imgui.ImVec4(0.09, 0.10, 0.13, 0.98)
    c[imgui.Col.Border] = imgui.ImVec4(1, 1, 1, 0.06)
    c[imgui.Col.FrameBg] = imgui.ImVec4(1, 1, 1, 0.05)
    c[imgui.Col.FrameBgHovered] = accentDim(0.22)
    c[imgui.Col.FrameBgActive] = accentDim(0.35)
    c[imgui.Col.TitleBg] = imgui.ImVec4(0.07, 0.08, 0.10, 1)
    c[imgui.Col.TitleBgActive] = imgui.ImVec4(0.07, 0.08, 0.10, 1)
    c[imgui.Col.Button] = accentDim(0.28)
    c[imgui.Col.ButtonHovered] = imgui.ImVec4(accentCol[1], accentCol[2], accentCol[3], 0.55)
    c[imgui.Col.ButtonActive] = accent()
    c[imgui.Col.Header] = accentDim(0.25)
    c[imgui.Col.HeaderHovered] = accentDim(0.40)
    c[imgui.Col.HeaderActive] = accent()
    c[imgui.Col.Separator] = imgui.ImVec4(1, 1, 1, 0.07)
    c[imgui.Col.CheckMark] = accent()
    c[imgui.Col.SliderGrab] = accent()
    c[imgui.Col.SliderGrabActive] = imgui.ImVec4(1, 1, 1, 0.9)
    c[imgui.Col.ScrollbarBg] = imgui.ImVec4(0, 0, 0, 0)
    c[imgui.Col.ScrollbarGrab] = imgui.ImVec4(1, 1, 1, 0.12)
    c[imgui.Col.ScrollbarGrabHovered] = accentDim(0.45)
    c[imgui.Col.ScrollbarGrabActive] = accent()
end

local function spaced(dx, dy) imgui.Dummy(imgui.ImVec2(dx or 0, dy or 0)) end

local function sectionTitle(text)
    imgui.PushStyleColor(imgui.Col.Text, accent())
    imgui.Text(text)
    imgui.PopStyleColor()
    imgui.Separator()
    spaced(0, 6)
end

local function metric(label, value, width)
    imgui.BeginChild('##m' .. label, imgui.ImVec2(width or 160, 64), false)
        imgui.TextDisabled(label)
        imgui.SetWindowFontScale(1.15)
        imgui.Text(tostring(value))
        imgui.SetWindowFontScale(1.0)
    imgui.EndChild()
end

local function navButton(label, selected, width)
    if selected then
        imgui.PushStyleColor(imgui.Col.Button, accent())
        imgui.PushStyleColor(imgui.Col.ButtonHovered, accent())
        imgui.PushStyleColor(imgui.Col.ButtonActive, accent())
        imgui.PushStyleColor(imgui.Col.Text, imgui.ImVec4(0.07, 0.08, 0.10, 1))
    else
        imgui.PushStyleColor(imgui.Col.Button, imgui.ImVec4(0, 0, 0, 0))
        imgui.PushStyleColor(imgui.Col.ButtonHovered, accentDim(0.22))
        imgui.PushStyleColor(imgui.Col.ButtonActive, accentDim(0.35))
        imgui.PushStyleColor(imgui.Col.Text, imgui.ImVec4(0.78, 0.80, 0.86, 1))
    end
    local clicked = imgui.Button(label, imgui.ImVec2(width, 32))
    imgui.PopStyleColor(4)
    return clicked
end

local function actionButton(label, size)
    return imgui.Button(label, size or imgui.ImVec2(150, 32))
end

local function dangerButton(label, size)
    imgui.PushStyleColor(imgui.Col.Button, imgui.ImVec4(0.8, 0.22, 0.32, 0.55))
    imgui.PushStyleColor(imgui.Col.ButtonHovered, imgui.ImVec4(0.9, 0.25, 0.35, 0.7))
    local clicked = imgui.Button(label, size or imgui.ImVec2(150, 32))
    imgui.PopStyleColor(2)
    return clicked
end

local function dealTotals()
    local spent, earned = 0, 0
    for _, log in ipairs(dealLogs) do
        if log.action == 'buy' then spent = spent + (tonumber(log.price) or 0)
        elseif log.action == 'sell' then earned = earned + (tonumber(log.price) or 0) end
    end
    return spent, earned
end

local function drawHome()
    sectionTitle('Сводка')
    local spent, earned = dealTotals()
    metric('В базе', tostring(#priceList), 120)
    imgui.SameLine()
    metric('Сделок', tostring(#dealLogs), 120)
    imgui.SameLine()
    metric('Чат', chatOn[0] and 'онлайн' or 'выкл', 120)
    imgui.SameLine()
    metric('Скан', scanState.active and 'идёт' or 'стоп', 120)
    spaced(0, 4)
    imgui.TextDisabled(('Потрачено %s  ·  получено %s'):format(fmtMoney(spent), fmtMoney(earned)))
    if scanState.active then
        imgui.TextColored(imgui.ImVec4(0.45, 0.85, 0.55, 1),
            ('Скан: стр. %d  %s'):format(scanState.index, tostring(scanState.currentName or '')))
    end

    spaced(0, 10)
    sectionTitle('Чат сервера')
    spaced(0, 4)
    if actionButton(chatOn[0] and 'Закрыть чат' or 'Открыть чат', imgui.ImVec2(180, 32)) then
        setChatEnabled(not chatOn[0])
    end
    imgui.SameLine()
    if chatOn[0] then
        if chatState.serverNum then
            imgui.TextColored(imgui.ImVec4(0.45, 0.85, 0.55, 1),
                ('Arizona #%d'):format(chatState.serverNum))
        else
            imgui.TextColored(imgui.ImVec4(0.45, 0.85, 0.55, 1), tostring(chatState.status))
        end
    else
        imgui.TextDisabled('/abchat')
    end

    spaced(0, 12)
    sectionTitle('Обмен json')
    spaced(0, 4)
    if actionButton('Поделиться', imgui.ImVec2(150, 32)) then startSharePrices() end
    if shareState.lastUrl ~= '' then
        imgui.SameLine()
        if actionButton('Копировать', imgui.ImVec2(130, 32)) then
            copyShareUrl(shareState.lastUrl)
            shareState.msg = 'ссылка скопирована'
            chat(shareState.lastUrl)
        end
    end
    if shareState.msg ~= '' then
        imgui.TextDisabled(shareState.busy and '...' or shareState.msg)
    end
end

local function drawBase()
    sectionTitle('Цены автобазара')
    imgui.SetNextItemWidth(-1)
    if imgui.InputTextWithHint('##search', 'Поиск машины...', searchBuf, 64) then
        filter = ffi.string(searchBuf)
    end
    spaced(0, 4)
    local rows = findPrices(filter)
    local listH = WIN_H - 168
    imgui.BeginChild('##left', imgui.ImVec2(300, listH), true)
        imgui.TextDisabled(('Машины  ·  %d'):format(#rows))
        spaced(0, 2)
        if #rows == 0 then
            imgui.TextDisabled('Пока пусто — сначала скан')
        else
            for i, row in ipairs(rows) do
                imgui.PushIDStr('c' .. i)
                if imgui.Selectable(row.name, selectedName == row.name) then
                    selectedName = row.name
                end
                imgui.SameLine(168)
                imgui.TextDisabled(('%d/30'):format(math.min(row.days, 30)))
                imgui.SameLine(214)
                imgui.TextColored(imgui.ImVec4(0.45, 0.85, 0.55, 1), fmtMoney(row.price))
                imgui.PopID()
            end
        end
    imgui.EndChild()
    imgui.SameLine()
    imgui.BeginChild('##right', imgui.ImVec2(-1, listH), true)
        if not selectedName or not prices[selectedName] then
            imgui.TextDisabled('Выбери машину слева')
        else
            local info = prices[selectedName]
            imgui.PushStyleColor(imgui.Col.Text, accent())
            imgui.Text(selectedName)
            imgui.PopStyleColor()
            imgui.Text(('Средняя: %s'):format(fmtMoney(info.price or 0)))
            imgui.Separator()
            imgui.TextDisabled('Продажи по дням')
            spaced(0, 4)
            local days = info.days or {}
            if #days == 0 then
                imgui.TextDisabled('Нет данных')
            else
                for j = 1, math.min(#days, MAX_DAYS) do
                    local row = days[j]
                    imgui.Text(tostring(row.date))
                    imgui.SameLine(130)
                    imgui.TextColored(imgui.ImVec4(0.45, 0.85, 0.55, 1), fmtMoney(row.price))
                end
            end
        end
    imgui.EndChild()
end

local function drawScan()
    sectionTitle('Сканирование')
    if scanState.active then
        imgui.TextColored(imgui.ImVec4(0.45, 0.85, 0.55, 1),
            ('Идёт скан: стр. %d  %s'):format(scanState.index, tostring(scanState.currentName or '')))
    end
    spaced(0, 6)
    if actionButton('Сканировать', imgui.ImVec2(150, 34)) then startScan() end
    imgui.SameLine()
    if actionButton('Стоп', imgui.ImVec2(90, 34)) then stopScan() end
    imgui.SameLine()
    if actionButton('Сохранить', imgui.ImVec2(120, 34)) then
        rebuildList(); savePrices(); chat('База сохранена')
    end
    imgui.SameLine()
    if dangerButton('Очистить', imgui.ImVec2(110, 34)) then
        prices = {}; selectedName = nil; rebuildList(); savePrices(); chat('База очищена')
    end

    spaced(0, 14)
    sectionTitle('Параметры')
    imgui.Checkbox('Уведомлять о новых продажах', notifyNewSales)
    imgui.Checkbox('Средняя цена в техпаспорте', showPassportAvg)
    imgui.Text(('Пауза между кликами: %d мс'):format(tonumber(waitPageMs[0]) or 0))
    imgui.SetNextItemWidth(280)
    imgui.SliderInt('##wp', waitPageMs, 0, 40)
    imgui.TextDisabled('0 — быстрее. Уже снятые сегодня дни пропускаются.')
    imgui.TextDisabled('В средних ценах — Сканировать. Стоп только здесь. База пишется сама.')

    spaced(0, 14)
    sectionTitle('Бинды')
    if scanState.bindWait then
        imgui.TextColored(imgui.ImVec4(0.45, 0.85, 0.55, 1), 'Нажми клавишу…  Esc — отмена')
    end
    if imgui.Checkbox('Меню ABarz', scanState.menuBindOn) then scanState.saveSettings() end
    imgui.SameLine(168)
    imgui.TextDisabled(scanState.keyName(scanState.menuVk))
    imgui.SameLine(250)
    if imgui.SmallButton(scanState.bindWait == 'menu' and '...' or 'Сменить##bm') then
        scanState.bindWait = 'menu'
    end
    if imgui.Checkbox('Чат ABarz', scanState.chatBindOn) then scanState.saveSettings() end
    imgui.SameLine(168)
    imgui.TextDisabled(scanState.keyName(scanState.chatVk))
    imgui.SameLine(250)
    if imgui.SmallButton(scanState.bindWait == 'chat' and '...' or 'Сменить##bc') then
        scanState.bindWait = 'chat'
    end
    if imgui.Checkbox('Мышь в чате', scanState.mouseBindOn) then scanState.saveSettings() end
    imgui.SameLine(168)
    imgui.TextDisabled(scanState.keyName(scanState.mouseVk))
    imgui.SameLine(250)
    if imgui.SmallButton(scanState.bindWait == 'mouse' and '...' or 'Сменить##bms') then
        scanState.bindWait = 'mouse'
    end
    imgui.TextDisabled('Мышь в чате — удерживать.')

    spaced(0, 14)
    sectionTitle('Автообновление GitHub')
    if imgui.Checkbox('Проверять при загрузке', scanState.autoUpdateOn) then scanState.saveSettings() end
    if actionButton(scanState.updateBusy and 'Проверяю...' or 'Проверить сейчас', imgui.ImVec2(200, 32)) then
        scanState.checkUpdate(true)
    end
    imgui.TextDisabled('github.com/andergr0ynd/autoabarz')
    imgui.TextDisabled('/abupdate — проверить вручную')
end

local function drawDeals()
    sectionTitle('Логи сделок')
    local spent, earned = dealTotals()
    metric('Сделок', tostring(#dealLogs), 130)
    imgui.SameLine()
    metric('Потрачено', fmtMoney(spent), 170)
    imgui.SameLine()
    metric('Получено', fmtMoney(earned), 170)
    spaced(0, 6)
    if pendingSell.active and (tonumber(pendingSell.price) or 0) > 0 then
        imgui.TextColored(imgui.ImVec4(0.55, 0.85, 0.65, 1),
            ('На АБ: %s  ·  %s'):format(
                (pendingSell.model ~= '' and pendingSell.model) or 'транспорт',
                fmtMoney(pendingSell.price)))
    else
        imgui.TextDisabled('Сейчас на АБ ничего не выставлено (из сохранения)')
    end
    spaced(0, 6)
    imgui.BeginChild('##deals', imgui.ImVec2(-1, WIN_H - 220), true)
        if #dealLogs == 0 then
            imgui.TextDisabled('Пока пусто')
        else
            for i = #dealLogs, math.max(1, #dealLogs - 80), -1 do
                local log = dealLogs[i]
                local tag = log.action == 'buy' and 'Купил' or 'Продал'
                local col = log.action == 'buy' and imgui.ImVec4(0.95, 0.45, 0.45, 1) or imgui.ImVec4(0.45, 0.85, 0.55, 1)
                imgui.TextDisabled(os.date('%d.%m %H:%M', log.time or 0))
                imgui.SameLine(90)
                imgui.TextColored(col, tag)
                imgui.SameLine(150)
                imgui.Text(tostring(log.model or ''))
                imgui.SameLine(320)
                imgui.TextColored(col, fmtMoney(log.price))
            end
        end
    imgui.EndChild()
    spaced(0, 6)
    if dangerButton('Очистить сделки', imgui.ImVec2(180, 32)) then
        dealLogs = {}
        saveDealLogs()
        chat('Логи сделок очищены')
    end
end

local PAGE_DRAW = {
    home = drawHome,
    base = drawBase,
    scan = drawScan,
    deals = drawDeals,
}

local function drawSidebar()
    imgui.BeginChild('##sidebar', imgui.ImVec2(SIDEBAR, WIN_H), false)
        local dl = imgui.GetWindowDrawList()
        local min = imgui.GetWindowPos()
        local max = imgui.ImVec2(min.x + SIDEBAR, min.y + WIN_H)
        dl:AddRectFilled(min, max, u32(0.07, 0.08, 0.11, 1), 10)
        dl:AddRectFilled(min, imgui.ImVec2(min.x + 4, max.y), imgui.ColorConvertFloat4ToU32(accent()), 2)
        spaced(0, 14)
        imgui.SetCursorPosX(18)
        imgui.PushStyleColor(imgui.Col.Text, accent())
        imgui.Text('ABarz')
        imgui.PopStyleColor()
        imgui.SetCursorPosX(18)
        imgui.TextDisabled('Arizona  •  v' .. tostring(thisScript().version))
        spaced(0, 10)
        for i, p in ipairs(PAGES) do
            imgui.SetCursorPosX(12)
            if navButton(p.title, page == i, SIDEBAR - 24) then page = i end
        end
        imgui.SetCursorPos(imgui.ImVec2(12, WIN_H - 86))
        if navButton(chatOn[0] and 'Чат  ·  вкл' or 'Чат', chatOn[0], SIDEBAR - 24) then
            setChatEnabled(not chatOn[0])
        end
        imgui.SetCursorPos(imgui.ImVec2(18, WIN_H - 40))
        imgui.TextDisabled('/abarz  закрыть')
    imgui.EndChild()
end

local function drawHeader()
    imgui.BeginChild('##header', imgui.ImVec2(WIN_W - SIDEBAR, 48), false)
        imgui.SetCursorPos(imgui.ImVec2(20, 14))
        imgui.Text(PAGES[page].title)
        imgui.SameLine(WIN_W - SIDEBAR - 48)
        imgui.SetCursorPosY(8)
        imgui.PushStyleColor(imgui.Col.Button, imgui.ImVec4(0.8, 0.22, 0.32, 0.35))
        imgui.PushStyleColor(imgui.Col.ButtonHovered, imgui.ImVec4(0.9, 0.25, 0.35, 0.7))
        if imgui.Button('X', imgui.ImVec2(32, 32)) then win[0] = false end
        imgui.PopStyleColor(2)
    imgui.EndChild()
end

local function drawChatWindow(sw, sh)
    local st = imgui.GetStyle()
    st.WindowPadding = imgui.ImVec2(14, 12)
    imgui.SetNextWindowPos(imgui.ImVec2(sw - 20, sh / 2), imgui.Cond.FirstUseEver, imgui.ImVec2(1.0, 0.5))
    imgui.SetNextWindowSize(imgui.ImVec2(CHAT_W, CHAT_H), imgui.Cond.FirstUseEver)
    local flags = bit.bor(imgui.WindowFlags.NoCollapse, imgui.WindowFlags.NoTitleBar)
    if not chatState.wantMouse then
        local extra = imgui.WindowFlags.NoMouseInputs or imgui.WindowFlags.NoInputs
        if extra then flags = bit.bor(flags, extra) end
        if imgui.WindowFlags.NoNav then
            flags = bit.bor(flags, imgui.WindowFlags.NoNav)
        end
    end
    if imgui.Begin('##abarzchat', chatOn, flags) then
        local dl = imgui.GetWindowDrawList()
        local min = imgui.GetWindowPos()
        local sz = imgui.GetWindowSize()
        dl:AddRectFilled(min, imgui.ImVec2(min.x + 4, min.y + sz.y), imgui.ColorConvertFloat4ToU32(accent()), 2)

        imgui.PushStyleColor(imgui.Col.Text, accent())
        imgui.Text('ABarz чат')
        imgui.PopStyleColor()
        imgui.SameLine()
        if chatState.serverName ~= '' then
            imgui.TextDisabled(('%s · %s'):format(tostring(chatState.serverName), tostring(chatState.status)))
        elseif chatState.serverNum then
            imgui.TextDisabled(('Arizona #%d · %s'):format(chatState.serverNum, tostring(chatState.status)))
        else
            imgui.TextDisabled(tostring(chatState.status))
        end
        if not win[0] then
            imgui.SameLine()
            local mk = scanState.keyName(scanState.mouseVk)
            imgui.TextDisabled(chatState.wantMouse and mk or (mk .. ' — мышь'))
        end
        imgui.SameLine()
        imgui.SetCursorPosX(imgui.GetWindowWidth() - 42)
        imgui.SetCursorPosY(8)
        imgui.PushStyleColor(imgui.Col.Button, imgui.ImVec4(0.8, 0.22, 0.32, 0.35))
        imgui.PushStyleColor(imgui.Col.ButtonHovered, imgui.ImVec4(0.9, 0.25, 0.35, 0.7))
        if imgui.Button('X##chatx', imgui.ImVec2(28, 28)) then setChatEnabled(false) end
        imgui.PopStyleColor(2)

        imgui.BeginChild('##abchat', imgui.ImVec2(-1, -72), true)
            for i, m in ipairs(chatLines) do
                imgui.PushIDInt(i)
                local hasFile = m.shareUrl and m.shareUrl ~= ''
                local shown = m.text
                if hasFile then
                    local low = tostring(shown):lower()
                    if shown:find('https://', 1, true) or low:find('file', 1, true) then
                        shown = 'База цен'
                    end
                end
                if m.nick == 'Система' then
                    imgui.TextColored(imgui.ImVec4(0.7, 0.7, 0.75, 1), shown)
                else
                    local col = m.self and imgui.ImVec4(0.45, 0.85, 0.55, 1) or imgui.ImVec4(0.55, 0.75, 1.0, 1)
                    imgui.TextColored(col, ('[%s] %s:'):format(m.time, m.nick))
                    imgui.SameLine()
                    if hasFile then
                        imgui.Text(shown)
                    else
                        imgui.TextWrapped(shown)
                    end
                end
                if hasFile then
                    imgui.SameLine()
                    if imgui.SmallButton('Скачать') then
                        startDownloadPrices(m.shareUrl)
                    end
                end
                imgui.PopID()
            end
            if chatScrollDown then
                imgui.SetScrollHereY(1.0)
                chatScrollDown = false
            end
        imgui.EndChild()

        local flagsIn = 0
        if imgui.InputTextFlags and imgui.InputTextFlags.EnterReturnsTrue then
            flagsIn = imgui.InputTextFlags.EnterReturnsTrue
        end
        imgui.SetNextItemWidth(-70)
        local enter = imgui.InputText('##abchat_in', chatInput, 192, flagsIn)
        imgui.SameLine()
        if imgui.Button('>>', imgui.ImVec2(56, 0)) or enter then
            sendScriptChat(ffi.string(chatInput))
            chatInput[0] = 0
        end
        if imgui.Button('Очистить чат', imgui.ImVec2(140, 26)) then
            chatLines = {}
        end
    end
    imgui.End()
    st.WindowPadding = imgui.ImVec2(0, 0)
end

imgui.OnInitialize(function()
    imgui.GetIO().IniFilename = nil
    local fontsDir = getFolderPath(0x14)
    local ranges = imgui.GetIO().Fonts:GetGlyphRangesCyrillic()
    pcall(function()
        local cfg = imgui.ImFontConfig()
        imgui.GetIO().Fonts:AddFontFromFileTTF(fontsDir .. '\\arial.ttf', 16.0, cfg, ranges)
    end)
    applyStyle()
end)

imgui.OnFrame(function()
    return win[0] or chatOn[0]
end, function(player)
    -- меню ABarz — курсор; один чат — камера свободна, бинд мыши включает курсор
    local wantMouse = win[0] and true or false
    if (not wantMouse) and chatOn[0] and scanState.mouseBindOn[0] then
        local vk = tonumber(scanState.mouseVk) or 0x12
        pcall(function()
            if isKeyDown(vk) then wantMouse = true end
            if vk == 0x12 and (isKeyDown(0xA4) or isKeyDown(0xA5)) then wantMouse = true end
        end)
    end
    chatState.wantMouse = wantMouse
    player.HideCursor = not wantMouse
    player.LockPlayer = false
    applyStyle()
    local sw, sh = getScreenResolution()

    if win[0] then
        imgui.SetNextWindowPos(imgui.ImVec2(sw / 2, sh / 2), imgui.Cond.FirstUseEver, imgui.ImVec2(0.5, 0.5))
        imgui.SetNextWindowSize(imgui.ImVec2(WIN_W, WIN_H), imgui.Cond.Always)
        local flags = bit.bor(
            imgui.WindowFlags.NoCollapse,
            imgui.WindowFlags.NoResize,
            imgui.WindowFlags.NoTitleBar,
            imgui.WindowFlags.NoScrollbar
        )
        if imgui.Begin('##abarz', win, flags) then
            drawSidebar()
            imgui.SameLine(0, 0)
            imgui.BeginChild('##main', imgui.ImVec2(WIN_W - SIDEBAR, WIN_H), false)
                drawHeader()
                imgui.SetCursorPos(imgui.ImVec2(20, 56))
                imgui.BeginChild('##content', imgui.ImVec2(WIN_W - SIDEBAR - 32, WIN_H - 72), false)
                    local draw = PAGE_DRAW[PAGES[page].id]
                    if draw then draw() end
                imgui.EndChild()
            imgui.EndChild()
        end
        imgui.End()
    end

    if chatOn[0] then
        drawChatWindow(sw, sh)
    end
end)

end
setupUi()

local CMDS = { 'abarz', 'abscan', 'abchat', 'carprice', 'abupdate' }

local function unregisterCmds()
    for _, name in ipairs(CMDS) do
        pcall(sampUnregisterChatCommand, name)
    end
end

function main()
    local keepListed = false
    pcall(function()
        if isSampAvailable() and type(sampGetGamestate) == 'function' then
            local gs = sampGetGamestate()
            keepListed = type(gs) == 'number' and gs >= 3
        end
    end)
    while not isSampAvailable() do wait(0) end
    loadPrices()
    loadDealLogs(keepListed)
    pcall(scanState.loadSettings)
    if not keepListed then
        forgetListed()
    end
    cleanupCurrencyNames()

    unregisterCmds()
    saleAlive = true
    chat(('AutoABarz загружен. /abarz — в базе: %d'):format(#priceList))
    if scanState.menuBindOn[0] then
        chat(('Бинд меню: %s  ·  чат: %s  (Скан → Бинды)'):format(
            scanState.keyName(scanState.menuVk),
            scanState.chatBindOn[0] and scanState.keyName(scanState.chatVk) or 'выкл'))
    end
    if pendingSell.active and (tonumber(pendingSell.price) or 0) > 0 then
        chat(('На АБ помню: %s за %s'):format(
            (pendingSell.model ~= '' and pendingSell.model) or 'транспорт',
            fmtMoney(pendingSell.price)))
    end
    if not ok_arz then
        chat('Нет arizona-events (lib) — CEF будет ограничен')
    end
    if not ok_cef then
        chat('Нет arizona-cef-dialogs (lib) — CEF-диалоги могут не читаться')
    end

    sampRegisterChatCommand('abarz', function() win[0] = not win[0] end)
    sampRegisterChatCommand('abscan', function() startScan() end)
    sampRegisterChatCommand('abchat', function()
        setChatEnabled(not chatOn[0])
    end)
    sampRegisterChatCommand('carprice', function(arg)
        arg = tostring(arg or ''):gsub('^%s+', ''):gsub('%s+$', '')
        if arg == '' then
            chat('Использование: /carprice [название]')
            return
        end
        rebuildList()
        local rows = findPrices(arg)
        if #rows == 0 then
            chat('Не найдено: ' .. arg)
            return
        end
        for i = 1, math.min(#rows, 5) do
            local r = rows[i]
            local info = prices[r.name]
            chat(('%s — средняя %s, дней: %d'):format(r.name, fmtMoney(r.price), info and #(info.days or {}) or 0))
            if info and info.days then
                for j = 1, math.min(3, #info.days) do
                    chat(('   %s: %s'):format(info.days[j].date, fmtMoney(info.days[j].price)))
                end
            end
        end
    end)

    sampRegisterChatCommand('abupdate', function()
        scanState.checkUpdate(true)
    end)
    if scanState.autoUpdateOn[0] then
        lua_thread.create(function()
            wait(10000)
            scanState.checkUpdate(false)
        end)
    end

    while true do
        pcall(scanState.pumpHttpJobs)
        pcall(drainHttpCbQueue)
        pcall(pumpSales)
        pcall(pumpCefDialog)
        pcall(pumpScanFab)
        pcall(pumpPassportOverlay)
        pcall(scanState.pumpBinds)
        pcall(function()
            if scanState.pricesDirty and os.clock() >= (scanState.saveAt or 0) then
                savePrices()
            end
        end)
        wait(scanState.active and 10 or (scanState.bindWait and 20 or 80))
    end
end

function onScriptTerminate(s)
    if s == thisScript() then
        chatOn[0] = false
        unregisterCmds()
        stopSaleWatch()
        rebuildList()
        savePrices()
        saveDealLogs()
        pcall(scanState.saveSettings)
    end
end
