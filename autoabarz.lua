--[[
    /abarz  /abscan  /abprice  /abchat  /abupdate
    Репозиторий: github.com/andergr0ynd/autoabarz  (ветка main)
]]

script_name('AutoABarz')
script_author('pechkin')
script_version('1.8.0')
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

local ok_arz, arz
local ok_cef, cefDlg = pcall(require, 'arizona-cef-dialogs')
if not ok_cef then cefDlg = nil end
local ok_ev, ev = pcall(require, 'samp.events')
if not ok_ev then ok_ev, ev = pcall(require, 'lib.samp.events') end
local ok_ntfy, ntfy = pcall(require, 'notifications')
if not ok_ntfy then ntfy = nil end

local new = imgui.new
local noticeLogo = getWorkingDirectory() .. '\\images\\abarz-logo.png'

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

-- UTF-8 не трогаем; CP1251 -> UTF-8
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

local function chat(msg, kind)
    local text = repair_mojibake(ensure_utf8(tostring(msg))):gsub('{%x%x%x%x%x%x}', '')
    kind = kind or 'info'
    if ntfy and type(ntfy.show) == 'function' then
        local ok, note = pcall(ntfy.show, text, kind, kind == 'error' and 12000 or 8000)
        if ok then
            if type(note) == 'table' then
                note.title = 'AutoABarz'
                note.icon_path = noticeLogo
                note.icon_uv = {0.065, 0.25, 0.955, 0.69}
            end
            return
        end
    end
    -- Library failure must not crash a scan or put service messages back in game chat.
    print('AutoABarz [' .. kind .. ']: ' .. text)
end

local function ensureDir(path)
    if not doesDirectoryExist(path) then createDirectory(path) end
end

-- Корневой массив ([] / [{...}]) в decodeJson не отдаём: MoonLoader 0.26.5 cjson AV, pcall не ловит
local function safeDecodeJson(raw)
    if type(raw) ~= 'string' then return false, nil end
    local s = raw:gsub('^%s+', ''):gsub('%s+$', '')
    local first = s:sub(1,1)
    if first ~= '{' and first ~= '[' then return false, nil end
    local okModule, json = pcall(require, 'json')
    local decoder = okModule and type(json) == 'table' and json.decode or decodeJson
    if type(decoder) ~= 'function' then return false, nil end
    -- Native MoonLoader decoders may reject root arrays. Wrap, never pass
    -- an array to that decoder, and leave the global decoder untouched.
    local wrapped = first == '['
    if wrapped then s = '{"data":' .. s .. '}' end
    local ok, data = pcall(decoder, s)
    if not ok or type(data) ~= 'table' then return false, nil end
    return true, wrapped and data.data or data
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
local pendingSell = { lots = {}, max = 2, draftModel = '', muteNtfy = 0, confirmations = {}, sequence = 0, details = {} }
local needSellSnapshot = false
ensureDir(DATA_DIR)

-- Превью машин в «База»: методы на таблице (не local function — лимит 200 locals).
-- Свои картинки: config/abarz/cars/<имя>.jpg|png (пробелы → _).
local carImg = {
    dir = DATA_DIR .. '\\cars',
    mapFile = DATA_DIR .. '\\vehicles.json',
    -- Arizona CDN: .../inventory/vehicles/512/{server_id}.png
    cdn = {
        'https://cdn.azresources.cloud/projects/arizona-rp/assets/images/inventory/vehicles/512/',
        'https://reserve-cdn.azresources.cloud/projects/arizona-rp/assets/images/inventory/vehicles/512/',
    },
    byName = {},
    mapReady = false,
    mapLoading = false,
    slots = {},
    dl = nil,
    activeName = nil,
    pending = nil,
}
ensureDir(carImg.dir)

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
    wantScan = false,
}

scanState.menuBindOn = new.bool(true)
scanState.chatBindOn = new.bool(true)
scanState.mouseBindOn = new.bool(true)
scanState.autoUpdateOn = new.bool(false)
scanState.bindHeld = {}
scanState.updateBusy = false
scanState.forceCloseUi = false

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
    if not v or v ~= v or v <= 0 or v > 9007199254740991 then return nil end
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

local savePrices

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

savePrices = function()
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

function scanState.writeJsonFile(path, value)
    local ok, encoded=pcall(encodeJson,value)
    if not ok then return false,tostring(encoded) end
    local temp,backup=path..'.tmp',path..'.bak'
    local f,err=io.open(temp,'wb')
    if not f then return false,err end
    local wrote,writeError=f:write(encoded)
    local closed,closeError=f:close()
    if not wrote or not closed then return false,writeError or closeError end
    local old=io.open(path,'rb')
    if old then
        old:close()
        os.remove(backup)
        local moved,why=os.rename(path,backup)
        if not moved then return false,why end
    end
    local moved,why=os.rename(temp,path)
    if not moved then
        if old then os.rename(backup,path) end
        return false,why
    end
    return true
end

local function saveDealLogs()
    ensureDir(DATA_DIR)
    local listed = {}
    for i = 1, #(pendingSell.lots or {}) do
        local lot = pendingSell.lots[i]
        if type(lot) == 'table' and tonumber(lot.price) and lot.price > 0 then
            listed[#listed + 1] = {
                id = lot.id,
                model = tostring(lot.model or ''),
                price = lot.price,
                at = tonumber(lot.at) or os.time(),
                source = tostring(lot.source or ''),
            }
        end
    end
    local unresolved = {}
    for _, entry in ipairs(pendingSell.confirmations) do
        if entry.state == 'waiting' or entry.state == 'unresolved' then unresolved[#unresolved+1] = entry end
    end
    local ok,err=scanState.writeJsonFile(LOGS_FILE,{version=4,deals=dealLogs,listed=listed,unresolved=unresolved,saved_at=os.time()})
    if not ok and not pendingSell.saveErrorNotified then
        chat('Не удалось сохранить сделки: '..tostring(err or 'ошибка записи'), 'error')
    end
    pendingSell.saveErrorNotified=not ok
    return ok
end

-- Arizona снимает лоты с АБ при кике/дисконнекте/переподключении.
-- Чистим сразу в файл — иначе onScriptTerminate успевает сохранить «призраков».
local function forgetListed()
    pendingSell.lots = {}
    pendingSell.dropListed = false
    pendingSell.draftModel = ''
    saveDealLogs()
end

local function dropListedNow(reason)
    local had = pendingSell.isActive()
    pendingSell.dropListed = false
    if not had then return false end
    forgetListed()
    if reason and isSampAvailable() then
        chat(reason)
    end
    return true
end

local function ingestListedRow(row)
    if type(row) ~= 'table' then return end
    local price = tonumber(row.price) or 0
    local at = tonumber(row.at) or 0
    if price <= 0 or at <= 0 or (os.time() - at) >= 43200 then return end
    pendingSell.lots = pendingSell.lots or {}
    pendingSell.lots[#pendingSell.lots + 1] = {
        id = row.id or pendingSell.newId('lot'),
        model = tostring(row.model or ''),
        price = price,
        source = tostring(row.source or 'saved'),
        at = at,
        t = os.clock(),
    }
    while #pendingSell.lots > (pendingSell.max or 2) do
        table.remove(pendingSell.lots, 1)
    end
end

local function loadDealLogs(keepListed)
    dealLogs = {}
    pendingSell.lots = {}
    pendingSell.confirmations = {}
    local data
    for _,path in ipairs({LOGS_FILE,LOGS_FILE..'.tmp',LOGS_FILE..'.bak'}) do
        local f=io.open(path,'rb')
        if f then
            local raw=f:read('*a'); f:close()
            local ok,decoded=safeDecodeJson(raw)
            if ok and type(decoded)=='table' then data=decoded; break end
        end
    end
    if not data then return end
    local src = data.deals or data
    if type(src) == 'table' then
        for _, row in ipairs(src) do
            if type(row) == 'table' then
                dealLogs[#dealLogs + 1] = {
                    id = row.id,
                    action = tostring(row.action or 'buy'),
                    model = tostring(row.model or 'Транспорт'),
                    price = tonumber(row.price) or 0,
                    time = tonumber(row.time or 0) or os.time(),
                    source = tostring(row.source or ''),
                }
            end
        end
    end
    pendingSell.confirmations = {}
    for _, entry in ipairs(type(data.unresolved) == 'table' and data.unresolved or {}) do
        if type(entry) == 'table' and (entry.action == 'buy' or entry.action == 'sell') then
            entry.state = 'unresolved'
            pendingSell.confirmations[#pendingSell.confirmations+1] = entry
        end
    end
    if keepListed then
        local listed = data.listed
        if type(listed) == 'table' then
            if listed[1] then
                for i = 1, #listed do ingestListedRow(listed[i]) end
            else
                ingestListedRow(listed)
            end
        end
    end
end

local function fmtMoney(n)
    n = math.floor(tonumber(n) or 0)
    local s = tostring(n)
    local left, num, right = s:match('^([^%d]*%d)(%d*)(.-)$')
    if not left then return '$' .. s end
    return '$' .. left .. (num:reverse():gsub('(%d%d%d)', '%1.'):reverse()) .. right
end

-- Латинские буквы и похожие кириллические (С/C, О/O, …) в поиске одно и то же.
-- В базе имя «C5 СEO»: третья буква кириллическая, с клавиатуры приходит латинская.
local function foldName(s)
    s = tostring(s or ''):lower()
    local map = {
        ['\208\144'] = 'a', ['\208\176'] = 'a',
        ['\208\146'] = 'b', ['\208\178'] = 'b',
        ['\208\149'] = 'e', ['\208\181'] = 'e',
        ['\208\154'] = 'k', ['\208\186'] = 'k',
        ['\208\156'] = 'm', ['\208\188'] = 'm',
        ['\208\157'] = 'h', ['\208\189'] = 'h',
        ['\208\158'] = 'o', ['\208\190'] = 'o',
        ['\208\160'] = 'p', ['\209\128'] = 'p',
        ['\208\161'] = 'c', ['\209\129'] = 'c',
        ['\208\162'] = 't', ['\209\130'] = 't',
        ['\208\163'] = 'y', ['\209\131'] = 'y',
        ['\208\165'] = 'x', ['\209\133'] = 'x',
        ['\208\134'] = 'i', ['\209\150'] = 'i',
    }
    local out, i, n = {}, 1, #s
    while i <= n do
        local two = s:sub(i, i + 1)
        local rep = map[two]
        if rep then
            out[#out + 1] = rep
            i = i + 2
        else
            out[#out + 1] = s:sub(i, i)
            i = i + 1
        end
    end
    return table.concat(out)
end

local function findPrices(query)
    query = foldName(query)
    local out = {}
    for _, row in ipairs(priceList) do
        if query == '' or foldName(row.name):find(query, 1, true) then
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
    title = stripColors(ensure_utf8(tostring(title or ''))):gsub('^%s+', '')
    text = ensure_utf8(tostring(text or ''))
    if title:find('Средняя цена автомобилей', 1, true) == 1 then return 'list' end
    if title:find('Продажа транспорта', 1, true) == 1
        and (text:find('Средняя цена за день', 1, true)
            or text:find('Количество продаж', 1, true)
            or text:find('За последние 30 дней не найдено ни одной продажи этого транспорта', 1, true)) then
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
    local finger = table.concat({tostring(id),tostring(style),tostring(title),tostring(text)}, '\1')
    if finger == (scanState.lastFinger or '') then
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
            pcall(scanState.consumeDialog or ingestDialog, d.id, d.style, d.title, d.btn1, d.btn2, d.text)
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
            (scanState.consumeDialog or ingestDialog)(id, cefDlg.GetStyle(), title, cefDlg.GetButton1(), cefDlg.GetButton2(), text)
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
    if d and d.kind == kind and (tonumber(d.seq) or 0) > minSeq then return d end
    return nil
end

-- Быстрый «Назад»: native close + короткий poll, один fallback RESP.
local function backToList(timeoutMs)
    if not scanState.active then return false end
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
        if not scanState.active then return false end
        startSeq = scanState.dlgSeq or 0
    end
    scanState.forceDlg = true
    if sampCloseCurrentDialogWithButton then
        pcall(sampCloseCurrentDialogWithButton, 1)
        if waitForDialog('list', timeoutMs, startSeq) then return true end
        if haveList() then return true end
        if not scanState.active then return false end
    end

    startSeq = scanState.dlgSeq or 0
    dialogResponse(daysId, 1, 0, '')
    if waitForDialog('list', timeoutMs, startSeq) then return true end
    if haveList() then return true end
    if not scanState.active then return false end

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
    if not idx or idx < 0 then
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

local function requestScan()
    scanState.wantScan = true
end

local function startScan()
    if scanState.active then
        return
    end

    if not (scanState.dlg and scanState.dlg.kind == 'list') then
        chat('Сначала открой диалог «Средняя цена автомобилей…»', 'warning')
        return
    end

    scanState.active = true
    scanState.stopped = false
    scanState.index = 0
    scanState.currentName = nil

    lua_thread.create(function()
        local page = 0
        local seenFirst = {}

        while scanState.active and page < MAX_PAGES_SAFETY do
            local list = scanState.dlg
            if not list or list.kind ~= 'list' then
                list = waitForDialog('list', 4000, scanState.dlgSeq or 0)
            end
            if not list or list.kind ~= 'list' then
                chat('Нет списка — стоп', 'error')
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
                            chat('Не могу нажать Назад — стоп.', 'error')
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
                            chat('Назад из дней не сработал. Стоп.', 'error')
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
    end)
end

local function stopScan()
    if not scanState.active then return end
    scanState.active = false
    scanState.stopped = true
    rebuildList()
    savePrices()
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
    if type(sampIsDialogActive) == 'function' and not sampIsDialogActive() then return false end
    if scanState.currentDialog then return scanState.currentDialog.kind == 'list' end
    if ok_cef and cefDlg then
        local ok, kind = pcall(function()
            return classifyDialog(cefDlg.GetId(), cefDlg.GetTitle(), cefDlg.GetDialogText())
        end)
        return ok and kind == 'list'
    end
    return false
end

local function injectScanButton()
    evalCefDialog([[
var id='abarz-scan-btn';
var title='Средняя цена автомобилей';
function priceDialog(){
  var nodes=document.querySelectorAll('.dialog');
  for(var i=0;i<nodes.length;i++){
    var box=nodes[i];
    if(!box.getClientRects().length) continue;
    var header=box.querySelector('.dialog__header');
    var t=String((header||box).innerText||(header||box).textContent||'').trim();
    if(t.indexOf(title)===0) return box;
  }
  return null;
}
function refresh(){
  var box=priceDialog(), old=document.getElementById(id);
  if(!box){ if(old) old.remove(); window.__abarzScan=null; return; }
  if(old){ if(box.contains(old)) return; old.remove(); }
  var btn=document.createElement('div');
  btn.id=id; btn.textContent='Сканировать';
  btn.onclick=function(ev){
    ev.preventDefault(); ev.stopPropagation();
    if(priceDialog()!==box) return;
    window.__abarzScan='start';
    try{ if(window.cef&&window.cef.SendMessage) window.cef.SendMessage('abarz-scan|start',0); }catch(e){}
  };
  btn.style.cssText='width:100%;margin:8px 0 4px;padding:10px 14px;text-align:center;font-size:15px;font-weight:700;color:#fff;background:#27ae60;border-radius:8px;cursor:pointer;box-sizing:border-box;';
  box.appendChild(btn);
}
if(window.__abarzScanObserver) window.__abarzScanObserver.disconnect();
window.__abarzScanObserver=new MutationObserver(refresh);
window.__abarzScanObserver.observe(document.body,{childList:true,subtree:true,characterData:true});
refresh();
]])
end

local function pumpScanFab()
    if scanFab.cmd == 'start' then
        scanFab.cmd = ''
        if priceMenuOpen() and not scanState.active then requestScan() end
    end
    if not priceMenuOpen() then
        if scanFab.wasOpen then
            evalCefDialog([[var e=document.getElementById('abarz-scan-btn'); if(e) e.remove(); window.__abarzScan=null; if(window.__abarzScanObserver) window.__abarzScanObserver.disconnect();]])
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
        local off = raknetBitStreamGetReadOffset and raknetBitStreamGetReadOffset(bs)
        pcall(function()
            if raknetBitStreamSetReadOffset then raknetBitStreamSetReadOffset(bs, 0) end
            raknetBitStreamIgnoreBits(bs, 8)
            local pType = raknetBitStreamReadInt8(bs)
            if pType == 18 then
                local len = raknetBitStreamReadInt16(bs)
                local text = raknetBitStreamReadString(bs, len)
                if type(text) == 'string' then act = text:match('abarz%-scan%|(%w+)') end
            end
        end)
        if off and raknetBitStreamSetReadOffset then raknetBitStreamSetReadOffset(bs, off) end
        if act == 'start' then
            scanFab.cmd = act
            return false
        end
    end)
end)

---------------------------------------------------------------------------
-- Новые продажи на АБ -> чат. Из RPC только строки/числа, обработка в main.
---------------------------------------------------------------------------
local PLATES = {}
local incomingPlates = {}
local saleAlive = true
local onNewSalePlate

local function parseAbbrevPrice(str)
    if not str then return nil end
    local s = tostring(str):gsub('{%x+}', ''):gsub('{......}', ''):gsub('<[^>]+>', '')
    s = s:gsub('[%s%$]', ''):gsub('\160', ''):gsub('\194\160', '')
    -- иконка валюты Arizona (? и т.п.) + «75.000.000»
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

-- Суффиксы кузова/поколения, которые сервер часто не выносит в отдельную
-- среднюю (S600 W124 / W221 → одна «Mercedes S600» в списке АБ).
local function stripChassisSuffix(name)
    name = normalizeName(name)
    if name == '' then return name end
    -- (W124) / [W221] / (E39)
    name = name:gsub('%s*[%(%[]%s*[WwEe]%d%d%d?%s*[%)%]]%s*$', '')
    -- хвостовые токены: W124, W221, E39, E60, C207…
    while true do
        local trimmed = name:gsub('%s+[WwEe][A-Za-z]?%d%d%d?%s*$', '')
        if trimmed == name then break end
        name = trimmed
    end
    return normalizeName(name)
end

-- Кандидаты: полное имя → без шасси → укорачивание с хвоста по словам.
local function avgNameCandidates(model)
    model = normalizeName(model)
    local out, seen = {}, {}
    local function push(n)
        n = normalizeName(n)
        if n == '' or seen[n] then return end
        seen[n] = true
        out[#out + 1] = n
    end
    push(model)
    push(stripChassisSuffix(model))
    local words = {}
    for w in model:gmatch('%S+') do words[#words + 1] = w end
    for len = #words - 1, 1, -1 do
        push(table.concat(words, ' ', 1, len))
    end
    return out
end

-- Сервер схлопывает варианты в одну среднюю → ищем лучшее совпадение в базе.
-- Возвращает price, matchedName (имя из prices).
local function resolveAvgForModel(model)
    model = normalizeName(model)
    if model == '' then return nil, model end

    for _, cand in ipairs(avgNameCandidates(model)) do
        local p = lookupAvgPrice(cand)
        if p then return p, cand end
    end

    -- Паспорт часто пишет латинское C, а в базе та же буква кириллическая.
    -- Совпадение: целиком, с лишним хвостом, либо имя из базы встречается внутри.
    local modelLow = foldName(model)
    if modelLow == '' then return nil, model end
    local bestName, bestScore
    for _, row in ipairs(priceList) do
        local nLow = foldName(row.name)
        if nLow ~= '' then
            local score
            if modelLow == nLow then
                score = 1000 + #nLow
            elseif modelLow:sub(1, #nLow + 1) == nLow .. ' '
                or nLow:sub(1, #modelLow + 1) == modelLow .. ' ' then
                score = 800 + math.min(#modelLow, #nLow)
            elseif #nLow >= 4 and modelLow:find(nLow, 1, true) then
                score = 500 + #nLow
            elseif #modelLow >= 4 and nLow:find(modelLow, 1, true) then
                score = 400 + #modelLow
            end
            if score and (not bestScore or score > bestScore) then
                bestName, bestScore = row.name, score
            end
        end
    end
    if bestName then
        local p = lookupAvgPrice(bestName)
        if p then return p, bestName end
    end
    return nil, model
end

-- Стрелка и звук как в AB Informer: только интерьер автобазара и модель таблички.
-- Модель стрелки держим загруженной, пока скрипт жив. Короткий разбор
-- «имя / цена / Twin Turbo» включается лишь для этой таблички.
scanState.mark = {
    interior = 15,
    abModel = 15256,
    sound = 1052,
    arrowModel = 19605,
    duration = 8000,
    height = 1.2,
    scale = 1.0,
    rotSpeed = 18,
    object = nil,
    expires = 0,
    modelReady = false,
    pendingShort = {},
    objects = {},
}

function scanState.mark.turboOf(text)
    local low = tostring(text or ''):lower()
    if low:find('twin turbo', 1, true) or low:find('twinturbo', 1, true) then
        return 'Twin Turbo'
    end
    return 'No TT'
end

function scanState.mark.clean(text)
    text = tostring(text or ''):gsub('{%x+}', ''):gsub('{......}', '')
    text = repair_mojibake(ensure_utf8(text))
    text = text:gsub('\r\n', '\n'):gsub('\r', '')
    text = text:gsub('~[nN]~', '\n')
    text = text:gsub('~[%a]~', '')
    return text
end

function scanState.mark.objectHandle(sampId)
    sampId = tonumber(sampId)
    if not sampId or type(sampGetObjectHandleBySampId) ~= 'function' then return end
    local ok, a, b = pcall(sampGetObjectHandleBySampId, sampId)
    local handle = type(a) == 'number' and a or (a == true and b or nil)
    if not ok or type(handle) ~= 'number' or handle <= 0 then return end
    if type(doesObjectExist) == 'function' then
        local okE, exists = pcall(doesObjectExist, handle)
        if okE and not exists then return end
    end
    return handle
end

function scanState.mark.isSign(sampId)
    local object=scanState.mark.objects[tonumber(sampId)]
    if object then return object.model == scanState.mark.abModel end
    local handle = scanState.mark.objectHandle(sampId)
    if not handle or type(getObjectModel) ~= 'function' then return false end
    local ok, model = pcall(getObjectModel, handle)
    return ok and tonumber(model) == scanState.mark.abModel
end

function scanState.mark.validModel(name)
    name = normalizeName(name)
    if name == '' or name:find('***',1,true) or name:find(':',1,true) then return false end
    if name:match('^%[?%d+%]?$') or name:match('^[%w]+_[%w_]+') then return false end
    if name:lower():match('^id%s') or name:lower():match('^id#') then return false end
    if name:find('Владел',1,true) or name:find('Продавец',1,true)
        or name:find('Текущая ставка',1,true) or name:find('Состояние',1,true)
        or name:find('Продажа',1,true) or name:find('Аукцион',1,true) then return false end
    if name:lower() == 'twin turbo' or name:lower() == 'twinturbo' then return false end
    return name:find('[%a\128-\255]') ~= nil
end

function scanState.mark.parseShort(text)
    text = scanState.mark.clean(text)
    local lines = {}
    for line in text:gmatch('[^\n]+') do
        line = line:gsub('^%s+',''):gsub('%s+$','')
        if line ~= '' then lines[#lines+1] = line end
    end
    if #lines < 2 then return nil end
    if lines[1]:find('Аукцион №',1,true) == 1 and scanState.mark.validModel(lines[2]) then
        return 'auction',normalizeName(lines[2]),nil,nil
    end
    local index = lines[1] == 'Продажа транспорта' and 2 or 1
    local model = lines[index]
    if not scanState.mark.validModel(model) then return nil end
    for i=index+1,math.min(#lines,index+3) do
        local line = lines[i]
        if line:find('Владел',1,true) or line:lower():find('id:',1,true) then return nil end
        if line:lower() ~= 'twin turbo' and line:lower() ~= 'twinturbo' then
            local price = parsePlatePrice(line)
            if price and price >= 5001 then
                return 'sale',normalizeName(model),price,scanState.mark.turboOf(text)
            end
            return nil
        end
    end
    return nil
end

function scanState.mark.looksLikePlate(text)
    return scanState.mark.parseShort(text) ~= nil
end

function scanState.mark.holdShort(sampId, key, text, x, y, z)
    local n = 0
    for _ in pairs(scanState.mark.pendingShort) do n = n + 1 end
    if n >= 30 and not scanState.mark.pendingShort[sampId] then return end
    scanState.mark.pendingShort[sampId] = {
        key = key,
        text = text,
        t = os.clock(),
        x = x, y = y, z = z,
    }
end

local function parseSalePlate(text)
    text = scanState.mark.clean(text)
    if text == '' then return nil end

    local auc = text:match('Аукцион №%d+\n([^\n]+)')
    if auc then
        auc = normalizeName(auc)
        if scanState.mark.validModel(auc) then
            return 'auction', auc, nil, nil
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
    if not model or not scanState.mark.validModel(model) then return nil end
    model = normalizeName(model)
    if model == '' or not priceStr then return nil end
    local price = parsePlatePrice(priceStr)
    if not price or price <= 0 then return nil end
    return 'sale', model, price, scanState.mark.turboOf(text)
end

local function stopSaleWatch()
    saleAlive = false
    incomingPlates = {}
    scanState.mark.pendingShort = {}
    scanState.mark.arm = nil
    if scanState.mark.remove then scanState.mark.remove() end
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

local function notifyNewSale(kind, model, price, turbo)
    if kind == 'auction' then
        local msg = ('Новый транспорт на аукционе: %s'):format(model)
        chat(msg)
        return
    end

    local avg, avgName = resolveAvgForModel(model)
    local ttPlain = (turbo == 'Twin Turbo') and 'ТТ' or 'Без ТТ'
    local tt = (turbo == 'Twin Turbo') and '{FF69B4}ТТ' or '{A0A0A0}Без ТТ'
    local plain
    if not avg then
        plain = ('На продаже: %s за %s | средняя неизвестна | %s'):format(
            model, fmtMoney(price), ttPlain)
    else
        local avgLabel = (avgName and avgName ~= model)
            and (('средняя %s (%s)'):format(fmtMoney(avg), avgName))
            or (('средняя %s'):format(fmtMoney(avg)))
        local gain = avg - (tonumber(price) or 0)
        if gain > 15000000 then
            local vs = vsAvgInfo(price, avg)
            local how = (vs.title == 'Дороже средней') and 'Дороже' or 'Дешевле'
            local detail = (vs.detail or ''):gsub('%%', '')
            plain = ('На продаже: %s за %s | %s | %s %s | %s'):format(
                model, fmtMoney(price), avgLabel, how, detail, ttPlain)
        else
            plain = ('На продаже: %s за %s | %s | %s'):format(
                model, fmtMoney(price), avgLabel, ttPlain)
        end
    end

    if ntfy and ntfy.sale then
        local ok = pcall(ntfy.sale, {
            model = model,
            price = price,
            avg = avg,
            turbo = turbo,
            text = plain,
            title = 'AutoABarz',
            icon_path = noticeLogo,
            icon_uv = {0.065, 0.25, 0.955, 0.69},
        })
        if ok then return end
    end

    if not avg then
        chat(('На продаже: %s за %s | средняя неизвестна | %s'):format(
            model, fmtMoney(price), tt))
        return
    end
    local avgLabel = (avgName and avgName ~= model)
        and (('средняя %s (%s)'):format(fmtMoney(avg), avgName))
        or (('средняя %s'):format(fmtMoney(avg)))
    local gain = avg - (tonumber(price) or 0)
    if gain > 15000000 then
        local vs = vsAvgInfo(price, avg)
        local how = (vs.title == 'Дороже средней') and 'Дороже' or 'Дешевле'
        local detail = (vs.detail or ''):gsub('%%', '')
        chat(('На продаже: %s за %s | %s | {%s}%s %s | %s'):format(
            model, fmtMoney(price), avgLabel, vs.samp, how, detail, tt))
        return
    end
    chat(('На продаже: %s за %s | %s | %s'):format(
        model, fmtMoney(price), avgLabel, tt))
end

local function tryObjectPos(sampId)
    local object=scanState.mark.objects[tonumber(sampId)]
    local handle=scanState.mark.objectHandle(sampId)
    if handle and type(getObjectCoordinates) == 'function' then
        local ok,a,b,c,d=pcall(getObjectCoordinates,handle)
        if ok then
            if type(b)=='number' and type(c)=='number' and type(d)=='number' then return b,c,d end
            if type(a)=='number' and type(b)=='number' and type(c)=='number' then return a,b,c end
        end
    end
    if object then return object.x,object.y,object.z end
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

function scanState.mark.inAb()
    return type(getActiveInterior) == 'function' and getActiveInterior() == scanState.mark.interior
end

function scanState.mark.play()
    if type(addOneOffSound) ~= 'function' then return end
    local x, y, z = playerPos()
    if not x then return end
    pcall(addOneOffSound, x, y, z, scanState.mark.sound)
end

function scanState.mark.remove()
    if scanState.mark.object and type(doesObjectExist) == 'function' and doesObjectExist(scanState.mark.object) then
        deleteObject(scanState.mark.object)
    end
    scanState.mark.object = nil
    scanState.mark.expires = 0
end

function scanState.mark.show(x, y, z)
    x, y, z = tonumber(x), tonumber(y), tonumber(z)
    if not scanState.mark.modelReady or not x or not y or not z then return end
    if not scanState.mark.inAb() then return end
    if type(createObject) ~= 'function' then return end
    scanState.mark.remove()
    local obj = createObject(scanState.mark.arrowModel, x, y, z + scanState.mark.height)
    if not obj or obj == 0 then
        scanState.mark.object = nil
        return
    end
    if type(doesObjectExist) == 'function' and not doesObjectExist(obj) then
        scanState.mark.object = nil
        return
    end
    pcall(setObjectCollision, obj, false)
    pcall(setObjectScale, obj, scanState.mark.scale)
    scanState.mark.object = obj
    local now = (type(getGameTimer) == 'function') and getGameTimer() or 0
    scanState.mark.expires = now + scanState.mark.duration
end

function scanState.mark.ensureModel()
    if scanState.mark.modelReady or scanState.mark.modelFailed then return end
    scanState.mark.modelTries = (scanState.mark.modelTries or 0) + 1
    if type(requestModel) == 'function' then requestModel(scanState.mark.arrowModel) end
    if type(hasModelLoaded) == 'function' and hasModelLoaded(scanState.mark.arrowModel) then
        scanState.mark.modelReady = true
        return
    end
    if scanState.mark.modelTries > 200 then
        scanState.mark.modelFailed = true
    end
end

function scanState.mark.flushArm()
    local arm = scanState.mark.arm
    if not arm then return end
    if os.clock() > (arm.untilClock or 0) then
        scanState.mark.arm = nil
        return
    end
    if not scanState.mark.inAb() or not scanState.mark.isSign(arm.sampId) then return end
    local x, y, z = tryObjectPos(arm.sampId)
    scanState.mark.arm = nil
    if not x then return end
    if arm.sound then pcall(scanState.mark.play) end
    scanState.mark.show(x, y, z)
end

function scanState.mark.flushShort()
    local now = os.clock()
    for id, item in pairs(scanState.mark.pendingShort) do
        if now - (item.t or 0) > 8 then
            scanState.mark.pendingShort[id] = nil
        elseif scanState.mark.isSign(id) then
            scanState.mark.pendingShort[id] = nil
            pcall(onNewSalePlate, item.key, item.text, nil, item.x, item.y, item.z, id)
        end
    end
end

function scanState.mark.pump()
    scanState.mark.ensureModel()
    if not scanState.mark.inAb() then
        if scanState.mark.object then scanState.mark.remove() end
    elseif scanState.mark.object and type(doesObjectExist) == 'function' and doesObjectExist(scanState.mark.object) then
        if type(getGameTimer) == 'function' and type(setObjectHeading) == 'function' then
            local angle = (getGameTimer() / 1000 * scanState.mark.rotSpeed) % 360
            setObjectHeading(scanState.mark.object, angle)
        end
        if scanState.mark.expires > 0 and getGameTimer() >= scanState.mark.expires then
            scanState.mark.remove()
        end
    elseif scanState.mark.object then
        scanState.mark.remove()
    end
    scanState.mark.flushArm()
    scanState.mark.flushShort()
end

function scanState.mark.release()
    scanState.mark.remove()
    scanState.mark.arm = nil
    scanState.mark.pendingShort = {}
    if scanState.mark.modelReady and type(markModelAsNoLongerNeeded) == 'function' then
        markModelAsNoLongerNeeded(scanState.mark.arrowModel)
    end
    scanState.mark.modelReady = false
end

local function rememberPlate(key, model, price, x, y, z, owner)
    if not key or not model or not price then return end
    knownPlates[key] = {
        owner = owner,
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

-- Табличка ↔ ПТС: Mercedes/Mercedes-Benz ок; W140 ≠ W221; «просто ближайшая» — нет.
local function lotNameKey(s)
    s = foldName(normalizeName(s))
    s = s:gsub('mercedes%-benz', 'mercedes'):gsub('mercedes benz', 'mercedes')
    s = s:gsub('%s+', ' ')
    return s
end

local function isChassisToken(tok)
    tok = tostring(tok or ''):gsub('[%(%[%]%)]', '')
    return tok:match('^[WwEe]%d%d%d?$') ~= nil
end

-- score: 100 точное, 90 base+кузов, 0 нет. W140 и W221 друг с другом не матчятся.
local function modelsMatchForLot(plateModel, ptsModel)
    plateModel, ptsModel = normalizeName(plateModel), normalizeName(ptsModel)
    if plateModel == '' or ptsModel == '' then return false, 0 end
    local ka, kb = lotNameKey(plateModel), lotNameKey(ptsModel)
    if ka == kb then return true, 100 end

    local function onlyChassisExtra(short, long)
        if #long <= #short then return false end
        if long:sub(1, #short + 1) ~= short .. ' ' then return false end
        local extra = long:sub(#short + 2)
        if extra == '' then return false end
        for tok in extra:gmatch('%S+') do
            if not isChassisToken(tok) then return false end
        end
        return true
    end

    -- ПТС «Mercedes S600», табличка «Mercedes S600 W221» (или наоборот)
    if onlyChassisExtra(ka, kb) or onlyChassisExtra(kb, ka) then
        return true, 90
    end
    return false, 0
end

scanState.findLot = function(model, owner)
    model = normalizeName(model)
    if model == '' then return nil end
    local now = os.clock()
    local px, py, pz = playerPos()
    local maxDist = 12

    local best -- { price, score, dist, t, plateModel }
    for _, row in pairs(knownPlates) do
        local p = tonumber(row.price) or 0
        if p > 0 and (not owner or not row.owner or row.owner == owner)
            and ((row.objectId and scanState.mark.objects[row.objectId]) or (now - (row.t or 0)) < 90) then
            local ok, score = modelsMatchForLot(row.model, model)
            if ok then
                local d = nil
                if px and row.x and row.y and row.z then
                    d = dist3(px, py, pz, row.x, row.y, row.z)
                end
                -- без координат не берём: новая заехавшая машина иначе перебивает лот
                if d and d <= maxDist then
                    local better = false
                    if not best then
                        better = true
                    elseif score > best.score then
                        better = true
                    elseif score == best.score and d < best.dist then
                        better = true
                    elseif score == best.score and d == best.dist and row.t > best.t then
                        better = true
                    end
                    if better then
                        best = {
                            price = p,
                            score = score,
                            dist = d,
                            t = row.t,
                            plateModel = row.model,
                        }
                    end
                end
            end
        end
    end
    if best then return best.price, best.plateModel end
    return nil
end

local function isGenericCarName(name)
    name = normalizeName(name or '')
    if name == '' then return true end
    local n = name:lower()
    return n == 'транспорт' or name == 'Транспорт'
        or name == 'ваш транспорт' or n == 'ваш транспорт'
        or name == 'свой транспорт' or name == 'транспортное средство'
end

function pendingSell.isActive()
    return type(pendingSell.lots) == 'table' and #pendingSell.lots > 0
end

-- С/C, О/O и остальные похожие буквы — одна машина. Кузов W140 и W221 по-прежнему разные.
function pendingSell.sameModel(a, b)
    if isGenericCarName(a) or isGenericCarName(b) then return false end
    local ok = modelsMatchForLot(a, b)
    return ok and true or false
end

function pendingSell.preferName(a, b)
    a = normalizeName(a or '')
    b = normalizeName(b or '')
    if isGenericCarName(a) then return (not isGenericCarName(b)) and b or a end
    if isGenericCarName(b) then return a end
    if not pendingSell.sameModel(a, b) then return b ~= '' and b or a end
    local fa, fb = foldName(a), foldName(b)
    if #fb > #fa then return b end
    return a
end

-- В мире только GAMESTATE_CONNECTED (3). Кик — 5, рестарт — 4, заход заново — 1..2.
function pendingSell.inWorld()
    if type(sampGetGamestate) ~= 'function' then return true end
    local gs = sampGetGamestate()
    return type(gs) == 'number' and gs == 3
end

function pendingSell.newId(prefix)
    pendingSell.sequence = pendingSell.sequence + 1
    return prefix..':'..tostring(os.time())..':'..tostring(math.floor(os.clock()*1000000))..':'..pendingSell.sequence
end

function pendingSell.findLot(model, price)
    model,price = normalizeName(model or ''),tonumber(price) or 0
    local matches = {}
    for i,lot in ipairs(pendingSell.lots or {}) do
        local modelOK = isGenericCarName(model) or isGenericCarName(lot.model) or pendingSell.sameModel(lot.model,model)
        local priceOK = price <= 0 or tonumber(lot.price) == price
        if modelOK and priceOK then matches[#matches+1] = i end
    end
    if #matches == 1 then return matches[1],pendingSell.lots[matches[1]] end
    -- Identical cars remain distinct lots. A detailed sale of that exact model
    -- and price may consume one; a generic same-price sale remains ambiguous.
    if #matches > 1 and price > 0 and not isGenericCarName(model) then
        for _,i in ipairs(matches) do
            if not pendingSell.sameModel(pendingSell.lots[i].model,model) then return nil end
        end
        return matches[1],pendingSell.lots[matches[1]]
    end
end

function pendingSell.addLot(model, price, source)
    price = cleanPriceNum(price)
    if not price then return false end
    model = normalizeName(model or pendingSell.draftModel or '')
    if isGenericCarName(model) then model = '' end
    -- Every server listing confirmation is a new lot, even for equal cars.
    pendingSell.lots[#pendingSell.lots+1] = {id=pendingSell.newId('lot'), model=model,price=price,
        t=os.clock(),at=os.time(),source=tostring(source or 'chat')}
    saveDealLogs()
    return true
end

function pendingSell.removeLot(idx)
    idx = tonumber(idx)
    if not idx or not pendingSell.lots or not pendingSell.lots[idx] then return nil end
    local lot = table.remove(pendingSell.lots, idx)
    saveDealLogs()
    return lot
end

function pendingSell.localNick()
    if type(sampGetPlayerIdByCharHandle) ~= 'function' or type(sampGetPlayerNickname) ~= 'function' then return nil end
    local ok,found,id=pcall(sampGetPlayerIdByCharHandle,PLAYER_PED)
    if ok and found then
        local good,nick=pcall(sampGetPlayerNickname,id)
        if good then return ensure_utf8(tostring(nick)) end
    end
end

function pendingSell.isOwn(model, price, owner)
    local nick=pendingSell.localNick()
    if not nick or owner ~= nick then return false end
    for i,lot in ipairs(pendingSell.lots) do
        if tonumber(lot.price) == tonumber(price) and (isGenericCarName(lot.model) or pendingSell.sameModel(lot.model,model)) then
            return true,i,lot
        end
    end
    return false
end

function pendingBuy.reset()
    pendingBuy.active=false
    pendingBuy.model,pendingBuy.price,pendingBuy.source='',0,''
    pendingBuy.basePrice,pendingBuy.fee,pendingBuy.token,pendingBuy.dialogId=nil,nil,nil,nil
    pendingBuy.t=0
end

local function snapshotSellFromPlate()
    if not pendingSell.isActive() then return end
    local now = os.clock()
    local px, py, pz = playerPos()
    local changed = false
    local owner = pendingSell.localNick()
    if not owner then return end
    for i = 1, #pendingSell.lots do
        local lot = pendingSell.lots[i]
        if isGenericCarName(lot.model) then
            local want = tonumber(lot.price) or 0
            if want > 0 then
                local p,ambiguous
                for _, row in pairs(knownPlates) do
                    if row.owner == owner and row.price == want and (now - (row.t or 0)) <= 45 then
                        local okd = true
                        if px and row.x and row.y and row.z then
                            local d = dist3(px, py, pz, row.x, row.y, row.z)
                            okd = d and d <= 12
                        end
                        if okd then
                            if p and not pendingSell.sameModel(p.model,row.model) then ambiguous=true end
                            if not p or row.t > p.t then p=row end
                        end
                    end
                end
                if p and not ambiguous and not isGenericCarName(p.model) then
                    lot.model = p.model
                    lot.source = 'plate'
                    changed = true
                end
            end
        end
    end
    if changed then saveDealLogs() end
end

local function addDeal(action, model, price, source, transactionId)
    model = normalizeName(model or 'Транспорт')
    if model == '' then model = 'Транспорт' end
    price = tonumber(price) or 0
    local nowt = os.time()
    transactionId = transactionId or pendingSell.newId('deal')
    for _,row in ipairs(dealLogs) do if row.id == transactionId then return false end end
    dealLogs[#dealLogs + 1] = {
        id = transactionId,
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

function pendingSell.commit(entry, model, price, source, lotId)
    if entry.state == 'recorded' then return false end
    model,price=normalizeName(model or ''),cleanPriceNum(price)
    if isGenericCarName(model) or not price then return false end
    local index,lot
    if entry.action == 'sell' then
        if lotId then
            for i,value in ipairs(pendingSell.lots) do if value.id == lotId then index,lot=i,value; break end end
        else index,lot=pendingSell.findLot(model,price) end
    end
    entry.state,entry.model,entry.price='recorded',model,price
    if scanState.manualConfirmation == entry.id then scanState.manualConfirmation=nil end
    entry.recordedAt=os.clock()
    if index then table.remove(pendingSell.lots,index) end
    addDeal(entry.action,model,price,source,entry.id)
    saveDealLogs()
    return true
end

function pendingSell.resolve(id, candidateId, model, price)
    for _,entry in ipairs(pendingSell.confirmations) do
        if entry.id == id and entry.state ~= 'recorded' and entry.state ~= 'dismissed' then
            if candidateId then
                for _,candidate in ipairs(entry.candidates or {}) do
                    if candidate.id == candidateId then
                        return pendingSell.commit(entry,candidate.model,candidate.price,'confirmed',candidate.id)
                    end
                end
                return false
            end
            return pendingSell.commit(entry,model,price,'manual')
        end
    end
    return false
end

function pendingSell.confirmGeneric(action)
    -- Some server actions emit detailed and generic confirmations together.
    for _,detail in ipairs(pendingSell.details) do
        if detail.action == action and not detail.paired and os.clock()-detail.at < 1
            and (action ~= 'buy' or not pendingBuy.active or pendingBuy.token == detail.context) then
            detail.paired=true
            return
        end
    end
    local entry={id=pendingSell.newId('tx'),action=action,state='waiting',at=os.time(),
        deadline=os.clock()+2.5,candidates={}}
    if action == 'buy' then
        if pendingBuy.active and os.clock()-(pendingBuy.t or 0)<90 then
            entry.model,entry.price,entry.basePrice,entry.context = pendingBuy.model,pendingBuy.price,pendingBuy.basePrice,pendingBuy.token
        end
        pendingBuy.reset()
    else
        snapshotSellFromPlate()
        for _,lot in ipairs(pendingSell.lots) do
            entry.candidates[#entry.candidates+1]={id=lot.id,model=lot.model,price=lot.price}
        end
    end
    pendingSell.confirmations[#pendingSell.confirmations+1]=entry
    saveDealLogs()
end

function pendingSell.recordDetail(action, model, price)
    model,price=normalizeName(model),cleanPriceNum(price)
    if not price or isGenericCarName(model) then return end
    local context=pendingBuy.token
    if action == 'buy' and pendingBuy.active and pendingSell.sameModel(model,pendingBuy.model)
        and price == pendingBuy.basePrice then price=pendingBuy.price end
    local chosen
    for _,entry in ipairs(pendingSell.confirmations) do
        if entry.action == action and not entry.hasDetail and entry.state ~= 'dismissed'
            and (entry.state ~= 'recorded' or os.clock()-(entry.recordedAt or 0)<10) then
            local matching=action == 'buy' and (not context or context == entry.context)
                and (isGenericCarName(entry.model) or pendingSell.sameModel(entry.model,model))
                and (not entry.price or entry.price == 0 or entry.price == price or entry.basePrice == price)
            if action == 'sell' then
                matching=#(entry.candidates or {})==0
                for _,candidate in ipairs(entry.candidates or {}) do
                    if pendingSell.sameModel(candidate.model,model) and candidate.price == price then matching=true; break end
                end
            end
            if matching then chosen=entry; break end
        end
    end
    if not chosen then chosen={id=pendingSell.newId('tx'),action=action,state='waiting',at=os.time(),candidates={}} end
    if action == 'buy' and chosen.basePrice == price and chosen.price then price=chosen.price end
    local paired=chosen.deadline ~= nil
    chosen.hasDetail=true
    pendingSell.commit(chosen,model,price,'chat')
    pendingSell.details[#pendingSell.details+1]={action=action,at=os.clock(),paired=paired,context=context}
    while #pendingSell.details>20 do table.remove(pendingSell.details,1) end
    if action == 'buy' then pendingBuy.reset() end
end

function pendingSell.pumpConfirmations()
    for _,entry in ipairs(pendingSell.confirmations) do
        if entry.state == 'waiting' and os.clock()>=(entry.deadline or math.huge) then
            local done=false
            if entry.action == 'buy' and entry.model and entry.price then
                done=pendingSell.commit(entry,entry.model,entry.price,'dialog')
            elseif entry.action == 'sell' and #entry.candidates==1 then
                local candidate=entry.candidates[1]
                for _,lot in ipairs(pendingSell.lots) do
                    if lot.id == candidate.id and lot.model == candidate.model and lot.price == candidate.price then
                        done=pendingSell.commit(entry,candidate.model,candidate.price,'listed',candidate.id)
                        break
                    end
                end
            end
            if not done then
                entry.state='unresolved'
                chat('Подтверждена '..(entry.action=='buy' and 'покупка' or 'продажа')..'. Уточните сделку во вкладке «Сделки».')
                saveDealLogs()
            end
        end
    end
    for i=#pendingSell.confirmations,1,-1 do
        local entry=pendingSell.confirmations[i]
        if entry.state == 'dismissed' or (entry.state == 'recorded' and os.clock()-(entry.recordedAt or 0)>10) then
            table.remove(pendingSell.confirmations,i)
        end
    end
end

local function noteDealDialog(title, text, dialogId)
    title = repair_mojibake(stripColors(ensure_utf8(tostring(title or ''))))
    text = repair_mojibake(stripColors(ensure_utf8(tostring(text or ''))))

    if title:find('Подтверждение покупки', 1, true) then
        pendingBuy.reset()
        pendingBuy.token = pendingSell.newId('quote')
        pendingBuy.dialogId = dialogId
        local model = text:match('Транспорт:%s*([^\r\n]+)') or text:match('Модель:%s*([^\r\n]+)')
        if model then
            model = normalizeName(model:gsub('%s*%[%d+%]', ''))
            model = model:gsub('%s+TT$', ''):gsub('%s+ТТ$', '')
        end
        local price
        local costLine = text:match('Стоимость автомобиля:%s*([^\r\n]+)')
            or text:match('Стоимость транспорта:%s*([^\r\n]+)')
            or text:match('Цена:%s*([^\r\n]+)') or ''
        local a, b = costLine:match(':CASH:([%d%.,%s]+).-:CASH:([%d%.,%s]+)')
        if a and b then
            pendingBuy.basePrice,pendingBuy.fee=parsePlatePrice(a),parsePlatePrice(b)
            if pendingBuy.basePrice and pendingBuy.fee then price=pendingBuy.basePrice+pendingBuy.fee end
        else
            local chars = 'kKкКmMмМlLлЛnNнНtTтТyYыЫsSсСbBбБrRрРdDдД'
            local p1, p2 = costLine:match('[%$]?%s*([%d%.%,%s' .. chars .. ']+)%s*%+.-[%$]?%s*([%d%.%,%s' .. chars .. ']+)')
            if p1 and p2 then
                price = (parseAbbrevPrice(p1) or 0) + (parseAbbrevPrice(p2) or 0)
            else
                price = parsePlatePrice(costLine)
            end
        end
        pendingBuy.active = true
        pendingBuy.model = model or ''
        pendingBuy.price = (price and price > 0) and price or 0
        pendingBuy.t = os.clock()
        pendingBuy.source = (price and price > 0) and 'dialog' or pendingBuy.source
    end

    if title:find('Продажа', 1, true) or title:find('Аукцион', 1, true) or title:find('продажу', 1, true) then
        local model = text:match('Транспорт:%s*([^\r\n]+)') or text:match('Модель:%s*([^\r\n]+)')
        if model then
            pendingSell.draftModel = normalizeName((model:gsub('%s*%[%d+%]$', '')))
            pendingSell.draftAt,pendingSell.draftDialogId=os.clock(),dialogId
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
            pendingSell.recordDetail('buy',bought_model,price)
            return
        end
    end

    if clean:find('Поздравляем с приобретением транспортного средства',1,true) then
        pendingSell.confirmGeneric('buy')
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
        local price = parseAbbrevPrice(listed_price)
        local model = listed_model
        if not model or isGenericCarName(model) then
            model = os.clock()-(pendingSell.draftAt or -100)<30 and pendingSell.draftModel or ''
            needSellSnapshot = true
        end
        if price and price > 0 then
            pendingSell.addLot(model, price, 'chat')
            pendingSell.draftModel = ''
        end
    end

    if clean:find('Поздравляем с продажей транспортного средства',1,true) then
        pendingSell.confirmGeneric('sell')
        return
    end

    local state_price = clean:match('Вы продали свой транспорт государству за %D*(.+)')
    if state_price then
        local price = parseAbbrevPrice(state_price)
        if price then addDeal('sell', 'Слив в гос', price, 'chat') end
        return
    end

    local auc_model, auc_price = clean:match('Вы успешно выкупили транспорт (.-) с аукциона за %D*(.+)')
    if auc_model and auc_price then
        local price = parseAbbrevPrice(auc_price)
        if price then pendingSell.recordDetail('buy',auc_model,price) end
        return
    end

    local sold_model, sold_price = clean:match('Вы продали транспорт (.-) игроку .- за %D*(.+)')
    if not sold_model then
        local _, m, p = clean:match('Игрок (.-) купил у вас транспорт (.-) за %D*(.+)')
        sold_model, sold_price = m, p
    end
    if sold_model and sold_price then
        local price = parseAbbrevPrice(sold_price)
            if price then pendingSell.recordDetail('sell',sold_model,price) end
    end
end

local function queuePlate(item)
    if not saleAlive or type(item) ~= 'table' then return end
    if type(item.text) ~= 'string' or item.text == '' then return end
    local object=item.sampId and scanState.mark.objects[item.sampId]
    if object then item.generation=object.generation end
    incomingPlates[#incomingPlates + 1] = item
    if #incomingPlates > 512 then table.remove(incomingPlates, 1) end
end

-- RPC только копирует строку/числа. Чат — в pump, не из пакета.
onNewSalePlate = function(key, text, minPrice, x, y, z, sampId)
    if not saleAlive then return end
    local fromSign = sampId and scanState.mark.isSign(sampId) or false
    local kind, model, price, turbo = parseSalePlate(text)
    if not kind then
        local tt = scanState.mark.turboOf(text) == 'Twin Turbo'
        if fromSign or (scanState.mark.inAb() and scanState.mark.looksLikePlate(text)) then
            kind, model, price, turbo = scanState.mark.parseShort(text)
        elseif sampId and not scanState.mark.objectHandle(sampId) and scanState.mark.looksLikePlate(text) then
            scanState.mark.holdShort(sampId, key, text, x, y, z)
        end
    end
    if not kind then return end
    if kind == 'sale' and minPrice and price < minPrice then return end

    x, y, z = tonumber(x), tonumber(y), tonumber(z)
    if not (x and y and z) and sampId then
        x, y, z = tryObjectPos(sampId)
    end
    local owner=scanState.mark.clean(text):match('Владелец:%s*([^\n]+)')
    if owner then owner=normalizeName(owner) end
    rememberPlate(key, model, price, x, y, z, owner)
    if knownPlates[key] then knownPlates[key].objectId=sampId end

    local own, ownIdx, ownLot = pendingSell.isOwn(model, price, owner)
    if own and ownLot and isGenericCarName(ownLot.model) then
        local dist
        if x and y and z then
            local px, py, pz = playerPos()
            if px then dist = dist3(px, py, pz, x, y, z) end
        end
        if not dist or dist <= 8 then
            ownLot.model = model
            ownLot.source = 'plate'
            saveDealLogs()
        end
    end

    local token = (kind == 'auction') and ('AUC/' .. model)
        or ('%s/%s/%s'):format(model, tostring(price), turbo or '')
    if PLATES[key] == token then return end
    -- Пока пауза после своего лота: не запоминаем табличку, иначе она уже
    -- никогда не попадёт в чат.
    if os.clock() <= (pendingSell.muteNtfy or 0) then return end
    PLATES[key] = token
    if notifyNewSales[0] and not own then
        local okN, errN = pcall(notifyNewSale, kind, model, price, turbo)
        if not okN then
            print('AutoABarz notify: ' .. tostring(errN))
        end
        if scanState.mark.inAb() and (fromSign or turbo == 'Twin Turbo') then
            pcall(scanState.mark.play)
            if x and y and z then
                pcall(scanState.mark.show, x, y, z)
            elseif sampId then
                scanState.mark.arm = { sampId = sampId, sound = false, untilClock = os.clock() + 8 }
            end
        elseif sampId and scanState.mark.inAb() and not scanState.mark.objectHandle(sampId) then
            scanState.mark.arm = { sampId = sampId, sound = true, untilClock = os.clock() + 8 }
        end
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
        dropListedNow('Лоты на АБ сброшены: кик/дисконнект — выставьте машины заново')
    end
    pcall(function()
        if pendingSell.isActive() and not pendingSell.inWorld() then
            dropListedNow('Лоты на АБ сброшены: кик/дисконнект — выставьте машины заново')
        end
    end)

    local nc = #incomingChat
    if nc > 0 then
        local chats = incomingChat
        incomingChat = {}
        for i = 1, nc do
            pcall(processDealChat, chats[i])
        end
    end

    pendingSell.pumpConfirmations()

    local n = #incomingPlates
    if n > 0 then
        local batch = incomingPlates
        incomingPlates = {}
        for i = 1, n do
            local it = batch[i]
            local object=it.sampId and scanState.mark.objects[it.sampId]
            if not it.generation or (object and object.generation == it.generation) then
                pcall(onNewSalePlate, it.key, it.text, it.minPrice, it.x, it.y, it.z, it.sampId)
            end
        end
    end

    pcall(pollSale3dTexts)

    if needSellSnapshot then
        pcall(snapshotSellFromPlate)
        local still = false
        for i = 1, #(pendingSell.lots or {}) do
            local lot = pendingSell.lots[i]
            if isGenericCarName(lot.model) and (os.clock() - (lot.t or 0)) <= 8 then
                still = true
                break
            end
        end
        if not still then needSellSnapshot = false end
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
    if type(s) ~= 'string' then return nil end
    s = normalizeName(s)
    if s == '' or #s < 2 or #s > 48 then return nil end
    if not scanState.mark.validModel(s) then return nil end
    if s:find('паспорт', 1, true) or s:find('Паспорт', 1, true) then return nil end
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
    if event:find('document', 1, true) then
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

local function parsePassportModel(text)
    text = stripColors(ensure_utf8(tostring(text or '')))
    local m = text:match('Транспорт:%s*([^\r\n]+)')
        or text:match('Лимитированный авто:%s*([^\r\n]+)')
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

local function passportLotFromText(utf)
    utf = ensure_utf8(tostring(utf or ''))
    -- только явная цена продажи, не путать с пробегом/др.
    for line in utf:gmatch('[^\r\n]+') do
        local plain = stripColors(line)
        local low = plain:lower()
        if low:find('пробег', 1, true) or low:find('mileage', 1, true) then
            -- skip
        else
            local ps = plain:match('Цена продажи:%s*(.+)$')
                or plain:match('Цена:%s*(.+)$')
                or plain:match('Стоимость:%s*(.+)$')
            if ps then
                local p = parsePlatePrice(ps)
                if p and p >= 1000000 then return p end
            end
        end
    end
    return nil
end

local function queuePassportDialogPatch(id, style, title, btn1, btn2, text)
    if not showPassportAvg[0] then return end
    text = tostring(text or '')
    local utf = ensure_utf8(text)
    if utf:find('Средняя цена:', 1, true) or utf:find('Дешевле средней', 1, true) then return end
    local model = parsePassportModel(text)
    local owner = stripColors(utf):match('Владелец:%s*([^\r\n]+)')
    if owner then owner=normalizeName(owner) end
    local avg, avgName = nil, nil
    if model then avg, avgName = resolveAvgForModel(model) end
    -- приоритет: табличка рядом → текст ПТС (цена продажи)
    local lot = model and select(1, scanState.findLot(model, owner)) or nil
    if (not lot or lot <= 0) then
        lot = passportLotFromText(utf)
    end
    local avgLabel = avg and fmtMoney(avg) or 'нет в базе'
    if avg and avgName and model and foldName(avgName) ~= foldName(model) then
        avgLabel = ('%s (%s)'):format(avgLabel, avgName)
    end
    local parts = { ('Средняя цена: %s'):format(avgLabel) }
    if lot and lot > 0 then
        parts[#parts + 1] = ('Лот: %s'):format(fmtMoney(lot))
        local vs = vsAvgInfo(lot, avg)
        if vs.title == 'Дешевле средней' then
            parts[#parts + 1] = ('{%s}%s %s'):format(vs.samp, vs.title, vs.detail)
        elseif vs.title == 'Дороже средней' then
            parts[#parts + 1] = ('{%s}%s %s'):format(vs.samp, vs.title, vs.detail)
        elseif vs.title then parts[#parts+1] = vs.title end
    else
        parts[#parts+1] = 'Цена лота: не определена'
    end
    local line = d('\n\n' .. table.concat(parts, '\n'))
    passportJob.patch = {
        finger = scanState.currentDialog and scanState.currentDialog.finger,
        id = tonumber(id) or DIALOG_PASSPORT_ID,
        style = tonumber(style) or 0,
        title = title or '',
        btn1 = (btn1 and tostring(btn1) ~= '') and btn1 or 'Закрыть',
        btn2 = btn2 or '',
        text = text .. line,
        at = os.clock() + 0.03,
    }
end

local function queuePassportOverlay(model, sid, lot, owner)
    model = pickCarName(model) or normalizeName(model)
    if not showPassportAvg[0] or model == '' then return end
    passportJob.model = model
    passportJob.sid = tonumber(sid) or 0
    passportJob.lotOwner = owner
    lot = tonumber(lot) or 0
    if lot <= 0 then
        lot = select(1, scanState.findLot(model, owner)) or 0
    end
    passportJob.lotPrice = (lot > 0) and lot or 0
    passportJob.lotModel = model
    passportJob.at = os.clock() + 0.28
    passportJob.tries = 0
end

local function injectPassportPrice(model)
    if not (ok_arz and arz and arz.eval) then return end
    local avg, avgName = resolveAvgForModel(model)
    -- только табличка этой модели рядом; stale lotPrice — лишь если модель та же
    local lot = select(1, scanState.findLot(model, passportJob.lotOwner)) or 0
    if lot <= 0
        and passportJob.lotModel
        and foldName(passportJob.lotModel) == foldName(model)
    then
        lot = tonumber(passportJob.lotPrice) or 0
    end
    if lot <= 0 then lot = 0 end
    local avgLine = avg and ('Средняя: %s'):format(fmtMoney(avg)) or 'Средняя: нет в базе'
    if avg and avgName and model and foldName(avgName) ~= foldName(model) then
        avgLine = ('Средняя: %s (%s)'):format(fmtMoney(avg), avgName)
    end
    local lines = { avgLine }
    local color = '#f3f3f3'
    if lot > 0 then
        lines[#lines + 1] = ('Лот: %s'):format(fmtMoney(lot))
        local vs = vsAvgInfo(lot, avg)
        if vs.title then
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
var nodes=document.querySelectorAll('.dialog, [class*="document"], [class*="passport"]');
var box=null;
for(var i=0;i<nodes.length;i++){
  var candidate=nodes[i];
  if(!candidate.getClientRects().length) continue;
  var text=String(candidate.innerText||candidate.textContent||'');
  var passport=text.indexOf('Технический паспорт')!==-1 || text.indexOf('Информация о транспорте')!==-1;
  if(!passport) continue;
  if(text.indexOf('Средняя цена:')!==-1) return;
  box=candidate; break;
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
        if patch.finger and (not scanState.currentDialog or scanState.currentDialog.finger ~= patch.finger) then return end
        if type(sampIsDialogActive) == 'function' and not sampIsDialogActive() then return end
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
    local owner = type(doc)=='table' and (doc.ownerName or doc.owner) or nil
    if type(owner)~='string' then owner=nil else owner=normalizeName(owner) end
    if not model then
        model = parsePassportModel(text)
    end
    -- 1) табличка рядом  2) CEF sellPrice  3) текст
    local lot = model and select(1, scanState.findLot(model, owner)) or nil
    if (not lot or lot <= 0) and type(doc) == 'table' then
        local raw = doc.sellPrice or doc.sell_price or doc.listingPrice or doc.lotPrice
            or doc.price or doc.cost
        if type(raw) == 'table' then raw = raw.value or raw.price or raw[1] end
        local p
        if type(raw) == 'string' then p = parsePlatePrice(raw)
        elseif type(raw) == 'number' then
            p = math.floor(raw)
        end
        if p and p > 0 then lot = p end
    end
    if (not lot or lot <= 0) then
        lot = passportLotFromText(text)
    end
    if model then queuePassportOverlay(model, sid, (lot and lot > 0) and lot or 0, owner) end
end

local function ingestAbCefPacket(packet)
    if not packet then return end
    local jsonText0 = tostring(packet.jsonText or '')
    local evName = tostring(packet.event or '')
    local rawText = tostring(packet.text or '')
    if evName:find('inventory', 1, true) or evName:find('storage', 1, true) then return end
    if rawText:find('playerInventory', 1, true) or rawText:find('event.storage', 1, true) then return end
    local jsonLead = jsonText0:gsub('^%s+', ''):sub(1, 1)
    if (jsonLead == '{' or jsonLead == '[') and type(packet.json) ~= 'table' then
        local ok, copy = safeDecodeJson(jsonText0)
        if ok then packet.json = copy end
    end
    pcall(noteVehiclePassport, packet)
    if not scanState.active then return end
    local jsonText = jsonText0
    if jsonText == '' and type(packet.json) == 'string' then
        local lead = packet.json:gsub('^%s+', ''):sub(1, 1)
        if lead == '{' then jsonText = packet.json end
    end
    if isAbCefText(rawText, evName) or isAbCefText(jsonText, evName) then
        if rawText ~= '' then ingestTextBlob(rawText) end
        if jsonText ~= '' and jsonText ~= rawText then ingestTextBlob(jsonText) end
    end
end

local function queueCefSnap(packet)
    if type(packet) ~= 'table' then return end
    local text = type(packet.text) == 'string' and packet.text or ''
    if #text > 131072 then return end
    local snap = {text=text, event=tostring(packet.event or ''), server_id=tonumber(packet.server_id) or 0, jsonText=''}
    local payloads = extractJsonPayloads(text)
    if payloads[1] then
        snap.event = snap.event ~= '' and snap.event or payloads[1].event
        snap.jsonText = payloads[1].json
    elseif type(packet.json) == 'string' then
        snap.jsonText = packet.json
    elseif type(packet.json) == 'table' then
        snap.json = packet.json
    end
    local utf = ensure_utf8(text)
    if snap.event:find('inventory',1,true) or snap.event:find('storage',1,true) then return end
    if utf:find('playerInventory',1,true) or utf:find('event.storage',1,true) then return end
    if not (isAbCefText(utf,snap.event) or snap.event:find('dialog',1,true)
        or snap.event:find('document',1,true) or snap.event:find('passport',1,true)
        or utf:find('Технический паспорт',1,true)) then return end
    incomingCef[#incomingCef+1] = snap
    if #incomingCef > 256 then table.remove(incomingCef,1) end
end

-- Read directly: library callbacks may be absent or reject compressed data.
function scanState.readCefPacket(bs)
    local offset = raknetBitStreamGetReadOffset(bs)
    local ok, text, server = pcall(function()
        raknetBitStreamSetReadOffset(bs,0)
        raknetBitStreamIgnoreBits(bs,8)
        if raknetBitStreamReadInt8(bs) ~= 17 then return end
        local sid = raknetBitStreamReadInt32(bs)
        local length = raknetBitStreamReadInt16(bs)
        if length < 0 then length = length + 65536 end
        local encoded = raknetBitStreamReadInt8(bs)
        if length == 0 then return '',sid end
        if encoded ~= 0 then return raknetBitStreamDecodeString(bs,length+1),sid end
        if length*8 > raknetBitStreamGetNumberOfUnreadBits(bs) then error('truncated CEF text') end
        return raknetBitStreamReadString(bs,length),sid
    end)
    raknetBitStreamSetReadOffset(bs,offset)
    if ok then return text,server end
end
addEventHandler('onReceivePacket',function(id,bs)
    if id ~= 220 then return end
    local text,server = scanState.readCefPacket(bs)
    if type(text) == 'string' and text ~= '' then queueCefSnap({text=text,server_id=server}) end
end)

-- Только окна АБ. Угон и похожие списки dlg не перезаписывают.
local lastDlgFinger = ''
local function onAnyDialog(id, style, title, btn1, btn2, text)
    local kind = classifyDialog(id, title, text)
    if kind == 'list' then
        scanState.listUntil = os.clock() + 4
    end
    local finger = table.concat({tostring(id),tostring(style),tostring(title),tostring(text)}, '\1')
    if finger == lastDlgFinger then return end
    lastDlgFinger = finger
    scanState.currentDialog = {id=tonumber(id), kind=kind, finger=finger}
    if kind == 'other' then
        scanState.dlg = nil
        if scanState.active then
            scanState.active, scanState.stopped = false, true
        end
    end
    local titleU = stripColors(ensure_utf8(tostring(title or '')))
    if isPassportDialog(id, titleU) then
        queuePassportDialogPatch(id, style, title, btn1, btn2, text)
    end
    if title or text then
        pcall(noteDealDialog, title, text, id)
    end
    if not text then return end
    if kind ~= 'list' and kind ~= 'days' then return end
    ingestDialog(id, style, title, btn1, btn2, text)
end
scanState.consumeDialog = onAnyDialog

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
    local prevResponse = ev.onSendDialogResponse
    function ev.onSendDialogResponse(id, button, listitem, input)
        if tonumber(button) == 0 then
            if pendingBuy.dialogId == id then pendingBuy.reset() end
            if pendingSell.draftDialogId == id then pendingSell.draftModel=''; pendingSell.draftAt=nil end
        end
        if prevResponse then return prevResponse(id,button,listitem,input) end
    end
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

    local prevCreate = ev.onCreateObject
    function ev.onCreateObject(id, data)
        if type(data)=='table' then
            local pos=data.position or {}
            scanState.mark.objectSequence=(scanState.mark.objectSequence or 0)+1
            scanState.mark.objects[id]={generation=scanState.mark.objectSequence,model=tonumber(data.modelId),x=tonumber(pos.x),y=tonumber(pos.y),z=tonumber(pos.z)}
            PLATES['obj_'..tostring(id)]=nil
            knownPlates['obj_'..tostring(id)]=nil
            for _, material in ipairs(data.materialText or data.materials_text or {}) do
                if type(material.text)=='string' and (tonumber(data.modelId)==scanState.mark.abModel or scanState.mark.looksLikePlate(material.text)) then
                    queuePlate({key='obj_'..tostring(id),text=material.text,sampId=id,x=tonumber(pos.x),y=tonumber(pos.y),z=tonumber(pos.z)})
                end
            end
        end
        if prevCreate then return prevCreate(id,data) end
    end
    local prevDestroy = ev.onDestroyObject
    function ev.onDestroyObject(id)
        scanState.mark.objects[id]=nil
        scanState.mark.pendingShort[id]=nil
        PLATES['obj_'..tostring(id)]=nil
        knownPlates['obj_'..tostring(id)]=nil
        if prevDestroy then return prevDestroy(id) end
    end
    local prevMove = ev.onSetObjectPosition
    function ev.onSetObjectPosition(id,pos)
        local object=scanState.mark.objects[id]
        if object and pos then
            object.x,object.y,object.z=tonumber(pos.x),tonumber(pos.y),tonumber(pos.z)
            local plate=knownPlates['obj_'..tostring(id)]
            if plate then plate.x,plate.y,plate.z=object.x,object.y,object.z end
        end
        if prevMove then return prevMove(id,pos) end
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
        pendingBuy.reset()
        scanState.mark.objects = {}
        knownPlates, PLATES, incomingPlates = {}, {}, {}
        -- сразу в deals.json, до возможной выгрузки скрипта при реконнекте
        pcall(forgetListed)
        if prevLost then pcall(prevLost) end
    end
    local prevClosed = ev.onConnectionClosed
    function ev.onConnectionClosed()
        pendingBuy.reset()
        scanState.mark.objects = {}
        knownPlates, PLATES, incomingPlates = {}, {}, {}
        pcall(forgetListed)
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
    generation = 0, requestSeq = 0, pollerToken = 0, sendSeq = 0, outgoing = {},
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

function chatState.truncate(text, limit)
    text = ensure_utf8(tostring(text or ''))
    text = text:gsub('[%z\1-\8\11\12\14-\31]', ' ')
    if #text <= limit then return text end
    text = text:sub(1,limit)
    while #text > 0 and not is_valid_utf8(text) do text = text:sub(1,-2) end
    return text
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
    while #chatLines > 120 do
        local old = table.remove(chatLines, 1)
        if old.messageId then chatState.outgoing[old.messageId]=nil end
    end
    chatScrollDown = true
    return chatLines[#chatLines]
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
        local checked, checkError = pcall(function()
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
        if not checked then
            done,okFlag,payload,code=true,false,tostring(checkError),0
        elseif not done and now > (job.untilAt or 0) then
            pcall(function() job.th:cancel() end)
            done,okFlag,payload,code=true,false,'timeout',0
        end
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

---------------------------------------------------------------------------
-- Картинки машин (База) — всё через carImg.*, без новых local
---------------------------------------------------------------------------
function carImg.safeKey(name)
    name = normalizeName(name):lower()
    name = name:gsub('[^%w%+%-%._]+', '_')
    name = name:gsub('_+', '_'):gsub('^_', ''):gsub('_$', '')
    if name == '' then name = 'car' end
    if #name > 80 then name = name:sub(1, 80) end
    return name
end

function carImg.localPath(name)
    local key = carImg.safeKey(name)
    local exts = { '.jpg', '.jpeg', '.png', '.bmp' }
    for i = 1, #exts do
        local p = carImg.dir .. '\\' .. key .. exts[i]
        if doesFileExist(p) then return p end
    end
    return carImg.dir .. '\\' .. key .. '.jpg'
end

function carImg.releaseSlot(slot)
    if type(slot) == 'table' then slot.tex = nil end
end

function carImg.ensureSlot(name)
    name = normalizeName(name)
    local slot = carImg.slots[name]
    if not slot then
        slot = { status = 'idle', path = '', tex = nil, msg = '', model_id = nil }
        carImg.slots[name] = slot
    end
    return slot
end

function carImg.normKey(s)
    s = normalizeName(s):lower()
    s = s:gsub('mercedes%-benz', 'mercedes'):gsub('mercedes benz', 'mercedes')
    s = s:gsub('lamborghini%s+', ''):gsub('porsche%s+', 'porche ')
    s = s:gsub('%s+', ' '):gsub('^%s+', ''):gsub('%s+$', '')
    return s
end

function carImg.ingestVehiclesJson(raw)
    raw = tostring(raw or '')
    if raw == '' then return 0 end
    local n = 0
    for block in raw:gmatch('%b{}') do
        local name = block:match('"name"%s*:%s*"([^"]+)"')
        local mid = tonumber(block:match('"model_id"%s*:%s*(%d+)'))
        local sid = tonumber(block:match('"server_id"%s*:%s*(%d+)'))
        -- картинки на CDN чаще по server_id; model_id — запасной
        local imgId = sid or mid
        if name and imgId and imgId > 0 then
            name = normalizeName(name)
            carImg.byName[name:lower()] = {
                name = name,
                model_id = mid or imgId,
                server_id = sid or imgId,
                img_id = imgId,
                key = carImg.normKey(name),
            }
            n = n + 1
        end
    end
    return n
end

function carImg.loadVehiclesMap(force)
    if carImg.mapLoading then return end
    if carImg.mapReady and not force then return end
    carImg.mapLoading = true
    if doesFileExist(carImg.mapFile) and not force then
        local f = io.open(carImg.mapFile, 'r')
        if f then
            local raw = f:read('*a')
            f:close()
            if carImg.ingestVehiclesJson(raw) > 0 then
                carImg.mapReady = true
                carImg.mapLoading = false
                return
            end
        end
    end
    httpRequestAsync('GET',
        'https://api.arztools.tech/tools/arizona/vehicles.json',
        '',
        { ['User-Agent'] = 'AutoABarz', ['Accept'] = 'application/json' },
        function(body, err)
            carImg.mapLoading = false
            body = tostring(body or '')
            if err or #body < 200 then return end
            if carImg.ingestVehiclesJson(body) <= 0 then return end
            carImg.mapReady = true
            pcall(function()
                local f = io.open(carImg.mapFile, 'w')
                if f then f:write(body) f:close() end
            end)
        end,
        25)
end

-- Возвращает img_id (для CDN), отобрамое имя, model_id
function carImg.resolveModelId(model)
    model = normalizeName(model)
    if model == '' then return nil, nil, nil end
    local hit = carImg.byName[model:lower()]
    if hit then return hit.img_id, hit.name, hit.model_id end

    local q = carImg.normKey(model)
    for _, cand in ipairs(avgNameCandidates(model)) do
        hit = carImg.byName[cand:lower()]
        if hit then return hit.img_id, hit.name, hit.model_id end
        local cq = carImg.normKey(cand)
        for _, row in pairs(carImg.byName) do
            if row.key == cq then
                return row.img_id, row.name, row.model_id
            end
        end
    end

    -- префикс / вхождение после нормализации (Mercedes S600 → … S600 W140)
    local best, bestScore
    for _, row in pairs(carImg.byName) do
        local k = row.key or ''
        if k == q then
            return row.img_id, row.name, row.model_id
        end
        local score
        if k:sub(1, #q + 1) == q .. ' ' then
            score = 500 - (#k - #q) -- короче хвост — лучше для «S600» без кузова
        elseif q:sub(1, #k + 1) == k .. ' ' then
            score = 400
        elseif k:find(q, 1, true) then
            score = 300 - (#k - #q)
        elseif q:find(k, 1, true) and #k >= 5 then
            score = 200
        end
        if score and (not bestScore or score > bestScore) then
            best, bestScore = row, score
        end
    end
    if best then return best.img_id, best.name, best.model_id end
    return nil, nil, nil
end

function carImg.cdnUrl(imgId, mirror)
    imgId = tonumber(imgId)
    if not imgId then return nil end
    mirror = tonumber(mirror) or 1
    local base = carImg.cdn[mirror] or carImg.cdn[1]
    return base .. tostring(imgId) .. '.png'
end

function carImg.cachePathById(imgId)
    return carImg.dir .. '\\' .. tostring(imgId) .. '.png'
end

function carImg.tryCdn(name, imgId, mirror, triedMid)
    imgId = tonumber(imgId)
    mirror = tonumber(mirror) or 1
    local slot = carImg.ensureSlot(name)
    if not imgId then
        carImg.tryWiki(name, carImg.wikiTitles(name), 1)
        return
    end
    local dest = carImg.cachePathById(imgId)
    if doesFileExist(dest) then
        carImg.releaseSlot(slot)
        slot.path = dest
        slot.status = 'ready'
        slot.msg = ''
        slot.img_id = imgId
        return
    end
    local url = carImg.cdnUrl(imgId, mirror)
    if not url then
        carImg.tryWiki(name, carImg.wikiTitles(name), 1)
        return
    end
    slot.status = 'loading'
    slot.msg = 'CDN Arizona…'
    slot.img_id = imgId
    carImg.dlFail = function()
        if mirror < #carImg.cdn then
            carImg.tryCdn(name, imgId, mirror + 1, triedMid)
            return
        end
        local mid = tonumber(slot.model_id)
        if mid and mid ~= imgId and not triedMid then
            carImg.tryCdn(name, mid, 1, true)
            return
        end
        carImg.tryWiki(name, carImg.wikiTitles(name), 1)
    end
    carImg.startFileDownload(name, url, dest)
end

function carImg.wikiTitles(model)
    local out, seen = {}, {}
    local function push(s)
        s = normalizeName(s)
        if s == '' then return end
        s = s:gsub('%s+', '_')
        if seen[s] then return end
        seen[s] = true
        out[#out + 1] = s
    end
    for _, cand in ipairs(avgNameCandidates(model)) do
        push(cand)
        push(cand:gsub('^Mercedes%s+', 'Mercedes-Benz '))
        local base, ch = cand:match('^(.+)%s+([WwEe]%d%d%d?)$')
        if base and ch then
            ch = ch:upper()
            push(base .. ' (' .. ch .. ')')
            push((base:gsub('^Mercedes%s+', 'Mercedes-Benz ')) .. ' (' .. ch .. ')')
            if base:lower():find('s%d%d%d', 1) or base:lower():find('s%-?class', 1) then
                push('Mercedes-Benz S-Class (' .. ch .. ')')
            end
            if base:lower():find('x5', 1, true) then
                push('BMW X5 (' .. ch .. ')')
            end
            if base:lower():find('m5', 1, true) then
                push('BMW M5 (' .. ch .. ')')
            end
        end
    end
    return out
end

function carImg.parseWikiThumb(json)
    json = tostring(json or '')
    local url = json:match('"thumbnail"%s*:%s*%b{}')
    if url then url = url:match('"source"%s*:%s*"(.-)"') end
    if not url then
        url = json:match('"originalimage"%s*:%s*%b{}')
        if url then url = url:match('"source"%s*:%s*"(.-)"') end
    end
    if not url or url == '' then return nil end
    url = url:gsub('\\/', '/'):gsub('\\u0026', '&'):gsub('%?.*$', '')
    if not url:find('^https?://') then return nil end
    if not (url:lower():find('%.jpe?g') or url:lower():find('%.png') or url:lower():find('%.bmp')) then
        if not url:find('upload%.wikimedia%.org', 1) then return nil end
    end
    return url
end

function carImg.onDownloadFail(name)
    local fail = carImg.dlFail
    carImg.dlFail = nil
    carImg.dl = nil
    if type(fail) == 'function' then
        pcall(fail)
        return
    end
    local slot = carImg.ensureSlot(name)
    slot.status = 'fail'
    slot.msg = 'не скачалась'
end

function carImg.startFileDownload(name, url, dest)
    if type(downloadUrlToFile) ~= 'function' then
        httpRequestAsync('GET', url, '', {
            ['User-Agent'] = 'AutoABarz/car-preview',
            ['Accept'] = 'image/png,image/*,*/*',
        }, function(body, err)
            local slot = carImg.ensureSlot(name)
            if carImg.activeName ~= name and carImg.dlFail then
                -- устаревшая закачка
                carImg.dl = nil
                return
            end
            if err or type(body) ~= 'string' or #body < 800 then
                carImg.onDownloadFail(name)
                return
            end
            local b1, b2, b3, b4 = body:byte(1, 4)
            local isPng = b1 == 137 and b2 == 80 and b3 == 78 and b4 == 71 -- PNG
            local isJpg = b1 == 0xFF and b2 == 0xD8
            if not isPng and not isJpg then
                pcall(os.remove, dest)
                carImg.onDownloadFail(name)
                return
            end
            pcall(function()
                local f = io.open(dest, 'wb')
                if f then f:write(body) f:close() end
            end)
            carImg.dlFail = nil
            if doesFileExist(dest) then
                slot.path = dest
                slot.status = 'ready'
                slot.msg = ''
            else
                carImg.onDownloadFail(name)
                return
            end
            carImg.dl = nil
        end, 30)
        carImg.dl = { name = name, path = dest, via = 'http' }
        return
    end
    local ml = require('moonloader')
    local ds = ml and ml.download_status
    carImg.dl = {
        name = name,
        path = dest,
        via = 'ml',
        done = false,
        ok = false,
        t0 = os.clock(),
    }
    local job = carImg.dl
    pcall(downloadUrlToFile, url, dest, function(_, status)
        if not ds then return end
        if status == ds.STATUS_ENDDOWNLOADDATA or status == ds.STATUSEX_ENDDOWNLOAD then
            job.done = true
            job.ok = true
        end
    end)
end

function carImg.tryWiki(name, titles, idx)
    idx = tonumber(idx) or 1
    carImg.dlFail = nil
    local slot = carImg.ensureSlot(name)
    if idx > #titles then
        slot.status = 'fail'
        slot.msg = 'нет на CDN'
        return
    end
    slot.status = 'loading'
    slot.msg = 'поиск…'
    local title = titles[idx]
    local url = 'https://en.wikipedia.org/api/rest_v1/page/summary/' .. title
    httpRequestAsync('GET', url, '', {
        ['User-Agent'] = 'AutoABarz/car-preview (moonloader)',
        ['Accept'] = 'application/json',
    }, function(body, err)
        if carImg.activeName ~= name then return end
        local thumb = (not err) and carImg.parseWikiThumb(body) or nil
        if not thumb then
            carImg.tryWiki(name, titles, idx + 1)
            return
        end
        slot.msg = 'скачиваю…'
        local dest = carImg.localPath(name)
        if not dest:lower():match('%.jpe?g$') then
            dest = carImg.dir .. '\\' .. carImg.safeKey(name) .. '.jpg'
        end
        carImg.startFileDownload(name, thumb, dest)
    end, 15)
end

function carImg.request(name)
    name = normalizeName(name)
    if name == '' then return end
    carImg.activeName = name
    carImg.loadVehiclesMap(false)
    local slot = carImg.ensureSlot(name)

    if slot.tex and slot.status == 'ok' then return end
    if slot.status == 'loading' or slot.status == 'ready' then return end

    local imgId, matched, mid = carImg.resolveModelId(name)
    slot.img_id = imgId
    slot.model_id = mid
    slot.matched = matched

    -- кэш по id с CDN
    if imgId then
        local byId = carImg.cachePathById(imgId)
        if doesFileExist(byId) then
            carImg.releaseSlot(slot)
            slot.path = byId
            slot.status = 'ready'
            slot.msg = ''
            return
        end
    end

    -- ручной файл по имени
    local key = carImg.safeKey(name)
    for _, ext in ipairs({ '.jpg', '.jpeg', '.png', '.bmp' }) do
        local p = carImg.dir .. '\\' .. key .. ext
        if doesFileExist(p) then
            carImg.releaseSlot(slot)
            slot.path = p
            slot.status = 'ready'
            slot.msg = ''
            return
        end
    end

    if not imgId then
        if carImg.mapLoading or not carImg.mapReady then
            slot.status = 'loading'
            slot.msg = 'карта машин…'
            carImg.pending = name
            return
        end
        slot.status = 'loading'
        slot.msg = 'загрузка…'
        carImg.tryWiki(name, carImg.wikiTitles(name), 1)
        return
    end

    slot.status = 'loading'
    slot.msg = 'CDN Arizona…'
    carImg.tryCdn(name, imgId, 1, false)
end

function carImg.pump()
    if carImg.pending and carImg.mapReady then
        local n = carImg.pending
        carImg.pending = nil
        local slot = carImg.slots[n]
        if slot and not slot.tex then
            slot.status = 'idle'
            if carImg.activeName == n then
                carImg.request(n)
            end
        end
    end

    local dl = carImg.dl
    if dl and dl.via == 'ml' then
        if dl.done or (os.clock() - (dl.t0 or 0)) > 45 then
            local slot = carImg.ensureSlot(dl.name)
            if dl.ok and doesFileExist(dl.path) then
                local f = io.open(dl.path, 'rb')
                local head = f and f:read(8) or ''
                if f then f:close() end
                local isPng = head:sub(1, 4) == '\137PNG'
                local isJpg = head:byte(1) == 0xFF and head:byte(2) == 0xD8
                if not isPng and not isJpg then
                    pcall(os.remove, dl.path)
                    carImg.onDownloadFail(dl.name)
                else
                    carImg.dlFail = nil
                    slot.path = dl.path
                    slot.status = 'ready'
                    slot.msg = ''
                    carImg.dl = nil
                end
            else
                pcall(os.remove, dl.path)
                carImg.onDownloadFail(dl.name)
            end
        end
    end

    if carImg.activeName then
        local slot = carImg.slots[carImg.activeName]
        if slot and slot.status == 'ready' and slot.path ~= '' and not slot.tex then
            if doesFileExist(slot.path) then
                local ok, tex = pcall(imgui.CreateTextureFromFile, slot.path)
                if ok and tex then
                    slot.tex = tex
                    slot.status = 'ok'
                    slot.msg = ''
                else
                    slot.status = 'fail'
                    slot.msg = 'не открылась'
                end
            else
                slot.status = 'fail'
                slot.msg = 'файл пропал'
            end
        end
    end
end

function carImg.drawPreview(name, maxW, scale)
    scale = scale or 1
    name = normalizeName(name)
    if name == '' then return end
    if carImg.activeName ~= name then
        carImg.request(name)
    elseif carImg.slots[name] and carImg.slots[name].status == 'idle' then
        carImg.request(name)
    end
    local slot = carImg.ensureSlot(name)
    if slot.img_id == nil and carImg.mapReady then
        local imgId, matched, mid = carImg.resolveModelId(name)
        slot.img_id, slot.matched, slot.model_id = imgId, matched, mid
    end
    maxW = tonumber(maxW) or 280
    local h = math.floor(maxW * 0.62)
    if slot.tex and slot.status == 'ok' then
        imgui.Image(slot.tex, imgui.ImVec2(maxW, h))
    else
        imgui.BeginChild('##carprev', imgui.ImVec2(maxW, h), true)
        local msg = slot.msg
        if slot.status == 'loading' then
            msg = msg ~= '' and msg or 'загрузка…'
        elseif slot.status == 'fail' then
            msg = msg ~= '' and msg or 'нет картинки'
        else
            msg = 'превью…'
        end
        imgui.SetCursorPos(imgui.ImVec2(12 * scale, h / 2 - 8 * scale))
        imgui.TextDisabled(msg)
        imgui.EndChild()
    end
    if slot.img_id then
        imgui.TextDisabled(('CDN id  %d'):format(slot.img_id))
    elseif slot.model_id then
        imgui.TextDisabled(('model  %d'):format(slot.model_id))
    end
end

-- Автообновление через effil (как ntfy/share). downloadUrlToFile + wait() в колбэке крашит lua51.dll.
local UPDATE_JSON = 'https://raw.githubusercontent.com/andergr0ynd/autoabarz/refs/heads/main/version.json'
local UPDATE_LUA = 'https://raw.githubusercontent.com/andergr0ynd/autoabarz/refs/heads/main/autoabarz.lua'

scanState.isHtmlHead = function(s)
    s = tostring(s or ''):gsub('^%s+', ''):sub(1, 96):lower()
    return s:sub(1, 9) == '<!doctype' or s:sub(1, 5) == '<html'
end

scanState.fetchUrls = function(urls, timeout, minLen, cb)
    local i = 0
    local function tryNext()
        i = i + 1
        if i > #urls then
            cb(nil)
            return
        end
        httpRequestAsync('GET', urls[i], '', {
            ['User-Agent'] = 'AutoABarz',
            ['Accept'] = '*/*',
        }, function(body, err)
            body = tostring(body or '')
            if not err and #body >= (minLen or 8) and not scanState.isHtmlHead(body) then
                cb(body)
            else
                tryNext()
            end
        end, timeout)
    end
    tryNext()
end

scanState.writeUpdateFile = function(latest, body)
    if type(body) ~= 'string' or #body < 4000
        or not body:find('script_name', 1, true) or not body:find('function main', 1, true) then
        scanState.updateBusy = false
        chat('Обновление прошло неудачно. Запускаю текущую версию.', 'error')
        return
    end
    local path = thisScript().path
    if type(path) ~= 'string' or path == '' then
        scanState.updateBusy = false
        chat('Нет пути скрипта', 'error')
        return
    end
    pcall(function()
        local old = io.open(path, 'rb')
        if old then
            local prev = old:read('*a')
            old:close()
            local b = io.open(path .. '.bak', 'wb')
            if b then b:write(prev) b:close() end
        end
    end)
    local f = io.open(path, 'wb')
    if not f then
        scanState.updateBusy = false
        chat('Не записалось обновление', 'error')
        return
    end
    f:write(body)
    f:close()
    scanState.forceCloseUi = true
    scanState.updateBusy = false
    chat(('Файл обновлён до %s. Меню закрыто.'):format(latest))
    chat('Перезагрузи скрипт: /reload  или перезайди в игру.')
    chat('Не жми обновление повторно, пока не сделаешь /reload.', 'warning')
end

function scanState.newerVersion(latest,current)
    local a,b={},{}
    for n in tostring(latest):gmatch('%d+') do a[#a+1]=tonumber(n) end
    for n in tostring(current):gmatch('%d+') do b[#b+1]=tonumber(n) end
    if #a==0 or #b==0 then return false end
    for i=1,math.max(#a,#b) do
        if (a[i] or 0) ~= (b[i] or 0) then return (a[i] or 0) > (b[i] or 0) end
    end
    return false
end

scanState.checkUpdate = function(manual)
    if scanState.updateBusy then
        if manual then chat('Обновление уже идёт') end
        return
    end
    if not ok_effil then
        if manual then chat('Нет сети (effil)', 'error') end
        return
    end
    scanState.updateBusy = true
    if manual then chat('Проверяю GitHub…') end
    scanState.fetchUrls({
        UPDATE_JSON,
        'https://cdn.jsdelivr.net/gh/andergr0ynd/autoabarz@main/version.json',
    }, 12, 8, function(raw)
        if type(raw) ~= 'string' then
            scanState.updateBusy = false
            if manual then chat('GitHub недоступен', 'error') end
            return
        end
        local okj, meta = safeDecodeJson(raw)
        local latest = okj and type(meta) == 'table' and tostring(meta.latest or '')
        local updateurl = okj and type(meta) == 'table' and tostring(meta.updateurl or '')
        if not latest or latest == '' then
            scanState.updateBusy = false
            if manual then chat('Не прочитался version.json', 'error') end
            return
        end
        local cur = tostring(thisScript().version or '0')
        if not scanState.newerVersion(latest,cur) then
            scanState.updateBusy = false
            if manual then chat(('Уже актуальная версия %s'):format(cur)) end
            return
        end
        if updateurl == '' or not updateurl:find('^https?://') then
            updateurl = UPDATE_LUA
        end
        chat(('Есть обновление: %s -> %s'):format(cur, latest))
        scanState.fetchUrls({
            updateurl,
            UPDATE_LUA,
            'https://cdn.jsdelivr.net/gh/andergr0ynd/autoabarz@main/autoabarz.lua',
        }, 45, 4000, function(body)
            scanState.writeUpdateFile(latest, body)
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
    local oldKey = chatState.serverKey
    local ip, port = '', 0
    pcall(function()
        ip, port = sampGetCurrentServerAddress()
    end)
    if tostring(ip or '') == '' or ip == '0.0.0.0' or (tonumber(port) or 0) == 0 then return nil end
    chatState.serverKey = tostring(ip or '') .. ':' .. tostring(tonumber(port) or 0)
    chatState.serverNum = num
    chatState.serverName = label
    chatState.topic = topic
    if old ~= '' and topic ~= '' and (topic ~= old or oldKey ~= chatState.serverKey) then
        chatState.generation = chatState.generation + 1
        chatState.inFlight = false
        chatState.inFlightToken = nil
        chatLines = {}
        chatState.outgoing = {}
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
    if cid ~= '' and cid == chatState.cid then
        local okOwn, own = safeDecodeJson(msg)
        local row = okOwn and chatState.outgoing[tostring(own.messageId or '')]
        if row then row.delivery = 'sent'; row.error = nil end
        return
    end
    local okPayload, payload = safeDecodeJson(msg)
    if okPayload and payload.messageId and cid ~= '' then
        if rememberChatId('sender:'..cid..':'..tostring(payload.messageId)) then return end
    end
    nick = chatState.truncate(nick,64)
    if nick == 'Система' then nick = 'Система (участник)' end
    text = chatState.truncate(text,1000)
    local shareUrl = ''
    local att = obj.attachment
    if type(att) == 'table' and att.url then
        shareUrl = tostring(att.url)
    end
    if mid == '' then
        if not obj.time then return end
        local fp = tostring(obj.time)..'|'..cid..'|'..msg..'|'..shareUrl
        if rememberChatId('fallback:'..fp) then return end
    end
    if shareUrl ~= '' then
        if text == '' or text:lower():find('file', 1, true) then
            text = 'База цен'
        end
        pushScriptChat(nick ~= '' and nick or 'ABarz', text, false, shareUrl)
        return
    end
    if text == '' then return end
    pushScriptChat(nick, text, false)
end

local function onPollResult(body, err, code, request)
    if not refreshChatRoom() then
        if request and request.token == chatState.inFlightToken then
            chatState.inFlight=false
            chatState.inFlightToken=nil
            chatState.status='нет подключения'
        end
        return
    end
    if not request or request.generation ~= chatState.generation
        or request.topic ~= chatState.topic or request.serverKey ~= chatState.serverKey
        or request.token ~= chatState.inFlightToken then return end
    chatState.inFlight = false
    chatState.inFlightToken = nil
    if not chatOn[0] then return end
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
    if not chatOn[0] then return end
    local topic = refreshChatRoom()
    if chatState.inFlight then return end
    if not topic or topic == '' then return end
    local url = 'https://ntfy.sh/' .. topic .. '/json?poll=1'
    if chatState.sinceId and chatState.sinceId ~= '' then
        url = url .. '&since=' .. tostring(chatState.sinceId)
    else
        -- без since ntfy отдаёт ВЕСЬ кэш топика — при открытии это дублирует историю
        url = url .. '&since=30m'
    end
    chatState.requestSeq = chatState.requestSeq + 1
    local request = {generation=chatState.generation,topic=topic,serverKey=chatState.serverKey,token=chatState.requestSeq}
    chatState.inFlight = true
    chatState.inFlightToken = request.token
    httpRequestAsync('GET', url, '', {
        ['User-Agent'] = 'ABarz/1.6',
        ['Accept'] = 'application/x-ndjson',
    }, function(body,err,code) onPollResult(body,err,code,request) end)
end

local function chatSendHttp(nick, text, onDone, messageId)
    local topic = refreshChatRoom()
    if not topic or topic == '' then if onDone then onDone('Нет подключения к серверу',0) end; return end
    local cid = ensureChatCid()
    if not messageId then
        chatState.sendSeq = chatState.sendSeq + 1
        messageId = cid..':'..tostring(chatState.sendSeq)
    end
    local payload = encodeJson({v=2,cid=cid,nick=nick,text=text,messageId=messageId})
    httpRequestAsync('PUT','https://ntfy.sh/'..topic,payload,{
        ['User-Agent']='ABarz/1.7.2', ['Content-Type']='text/plain; charset=utf-8',
        ['Title']=chatState.truncate(nick,64),
    },function(body,err,code) if onDone then onDone(err,code) end end)
end

function chatState.sendRow(row)
    if not chatOn[0] or row.serverKey ~= chatState.serverKey then return end
    row.delivery, row.error = 'sending', nil
    chatSendHttp(row.nick,row.text,function(err,code)
        if err then
            if row.delivery ~= 'sent' then row.delivery, row.error = 'failed',tostring(err) end
            if code == 429 and row.serverKey == chatState.serverKey then chatState.pollMs = 45000 end
        else
            row.delivery, row.error = 'sent',nil
        end
    end,row.messageId)
end

local function startChatPoller()
    if chatState.polling then return end
    if not ok_effil then
        pushScriptChat('Система', 'Чат недоступен.', false)
        chat('Чат недоступен', 'error')
        chatOn[0] = false
        return
    end
    chatState.pollerToken = chatState.pollerToken + 1
    local token = chatState.pollerToken
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
        while chatOn[0] and token == chatState.pollerToken do
            pcall(chatPollOnce)
            local pause = tonumber(chatState.pollMs) or 12000
            if pause < 8000 then pause = 8000 end
            wait(pause)
        end
        if token == chatState.pollerToken then
            chatState.polling = false
            chatState.inFlight = false
            chatState.status = 'выкл'
        end
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
        end
    else
        chatState.generation = chatState.generation + 1
        chatState.pollerToken = chatState.pollerToken + 1
        chatState.polling, chatState.inFlight = false,false
        chatState.inFlightToken = nil
        chatState.status = 'выкл'
    end
end

local function sendScriptChat(raw)
    if not chatOn[0] then
        chat('Сначала включи чат', 'warning')
        return
    end
    if not ok_effil then
        chat('Чат недоступен', 'error')
        return
    end
    raw = tostring(raw or ''):gsub('[\r\n]+', ' '):gsub('^%s+', ''):gsub('%s+$', '')
    if raw == '' then return end
    raw = chatState.truncate(raw,180)
    refreshChatRoom()
    local nick = myNickname()
    chatState.sendSeq = chatState.sendSeq + 1
    local messageId = ensureChatCid()..':'..tostring(chatState.sendSeq)
    local row = pushScriptChat(nick,raw,true)
    row.messageId, row.serverKey = messageId,chatState.serverKey
    chatState.outgoing[messageId] = row
    chatState.sendRow(row)
end

local function startSharePrices()
    if shareState.busy then return end
    if not next(prices) then
        shareState.msg = 'база пустая'
        chat('Нечем делиться — сначала скан или скачай чужую базу', 'warning')
        return
    end
    if not chatOn[0] then
        setChatEnabled(true)
    end
    local topic = refreshChatRoom()
    if not topic or topic == '' then
        chat('Не удалось определить сервер', 'error')
        return
    end
    local payload, n = buildShareJson()
    if not payload or payload == '' then
        chat('Не удалось собрать базу', 'error')
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
            chat('Не удалось поделиться базой', 'error')
        end
    end, 60)
end

local function startDownloadPrices(raw)
    if shareState.busy then return end
    raw = tostring(raw or ''):gsub('^%s+', ''):gsub('%s+$', '')
    if raw == '' then
        shareState.msg = 'нет ссылки'
        chat('В чате нет ссылки на базу', 'warning')
        return
    end
    local url = resolveShareFetchUrl(raw)
    if not url then
        shareState.msg = 'непонятная ссылка'
        chat('Непонятная ссылка на базу', 'warning')
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
                chat('Не удалось скачать базу', 'error')
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
            uiScale = scanState.uiScale or 1,
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
        local scale = tonumber(data.uiScale)
        if scale and scale == scale then scanState.uiScale = math.max(0.6, math.min(1.2, scale)) end
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

-- Logical coordinates keep every layout proportional without changing the shared module.
function scanState.scaledUi(raw, getScale)
    local ui = setmetatable({}, {__index=raw})
    local function vec(v) local s=getScale(); return raw.ImVec2(v.x*s, v.y*s) end
    local function logical(v) local s=getScale(); return raw.ImVec2(v.x/s, v.y/s) end
    for _, name in ipairs({'SetCursorPos','SetNextWindowSize','Dummy'}) do
        local method=name
        ui[method]=function(v, ...) return raw[method](vec(v), ...) end
    end
    for _, name in ipairs({'SetCursorPosX','SetCursorPosY','SetNextItemWidth'}) do
        local method=name
        ui[method]=function(n) return raw[method](n*getScale()) end
    end
    for _, name in ipairs({'GetWindowPos','GetWindowSize','GetContentRegionAvail'}) do
        local method=name
        ui[method]=function() return logical(raw[method]()) end
    end
    ui.GetWindowWidth=function() return raw.GetWindowWidth()/getScale() end
    ui.SetNextWindowPos=function(pos, cond, pivot) return raw.SetNextWindowPos(vec(pos),cond,pivot) end
    ui.SameLine=function(offset, spacing)
        return raw.SameLine(offset and offset*getScale() or 0,
            spacing and spacing >= 0 and spacing*getScale() or -1)
    end
    ui.Button=function(label, size) return raw.Button(label, size and vec(size) or raw.ImVec2(0,0)) end
    ui.Image=function(texture, size, ...) return raw.Image(texture,vec(size),...) end
    ui.Begin=function(...)
        local visible=raw.Begin(...); raw.SetWindowFontScale(getScale()); return visible
    end
    ui.BeginChild=function(id,size,...)
        local visible=raw.BeginChild(id,vec(size),...); raw.SetWindowFontScale(getScale()); return visible
    end
    ui.SetWindowFontScale=function(n) raw.SetWindowFontScale(n*getScale()) end
    ui.PushStyleVarFloat=function(key,n)
        return raw.PushStyleVarFloat(key,key == raw.StyleVar.Alpha and n or n*getScale())
    end
    ui.PushStyleVarVec2=function(key,v) return raw.PushStyleVarVec2(key,vec(v)) end
    ui.GetWindowDrawList=function()
        local dl=raw.GetWindowDrawList()
        return {
            AddRectFilled=function(_,a,b,color,rounding,...)
                return dl:AddRectFilled(vec(a),vec(b),color,(rounding or 0)*getScale(),...)
            end,
            AddCircleFilled=function(_,pos,radius,...)
                return dl:AddCircleFilled(vec(pos),radius*getScale(),...)
            end,
        }
    end
    return ui
end

local function setupUi()
local rawImgui = imgui
local uiScale = 1
local savedStyle
local imgui = scanState.scaledUi(rawImgui, function() return uiScale end)
local scalePercent = new.int(100)
local searchBuf = new.char[64]()
local dealModelBuf = new.char[64]()
local dealSearchBuf = new.char[64]()
local dealPriceBuf = new.char[32]()
local function setCString(buf, cap, s)
    s = tostring(s or '')
    if #s >= cap then s = s:sub(1, cap - 1) end
    ffi.fill(buf, cap, 0)
    if s ~= '' then ffi.copy(buf, s) end
end
local filter = ''
local page = 1
local WIN_W, WIN_H, SIDEBAR = 1020, 680, 176
local CHAT_W, CHAT_H = 380, 470
local accentCol = { 0.36, 0.58, 1.0 }
local PAGES = {
    { id = 'base', title = 'Цены' },
    { id = 'scan', title = 'Сканирование' },
    { id = 'deals', title = 'Сделки' },
    { id = 'chat', title = 'Чат' },
    { id = 'settings', title = 'Настройки' },
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
    s:ScaleAllSizes(uiScale)
    local c = s.Colors
    c[imgui.Col.Text] = imgui.ImVec4(0.94, 0.95, 0.97, 1)
    c[imgui.Col.TextDisabled] = imgui.ImVec4(0.54, 0.57, 0.63, 1)
    c[imgui.Col.WindowBg] = imgui.ImVec4(0.047, 0.055, 0.078, 0.97)
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

local baseTab, dealsTab, settingsTab = 1, 1, 1

local function tabs(id, titles, current)
    for i, title in ipairs(titles) do
        if i > 1 then imgui.SameLine() end
        if navButton(title .. '##' .. id .. i, current == i, 150) then current = i end
    end
    spaced(0, 6)
    imgui.Separator()
    spaced(0, 8)
    return current
end

local function drawChatPage()
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

    spaced(0, 14)
    imgui.TextWrapped('Сообщения сервера открываются в отдельном окне. Здесь можно включить или закрыть его.')
    imgui.TextDisabled('Клавиши чата и мыши: Настройки → Клавиши.')
end

local function drawBase()
    baseTab = tabs('base', {'Цены', 'Обмен базой', 'Хранение'}, baseTab)
    if baseTab == 2 then
        sectionTitle('Обмен базой цен')
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
        spaced(0, 12)
        imgui.TextWrapped('Поделитесь своей базой в чате сервера. Скачать чужую базу можно кнопкой у сообщения в чате.')
        return
    elseif baseTab == 3 then
        sectionTitle('Хранение базы')
        imgui.Text(('Сохранено моделей: %d'):format(#priceList))
        imgui.TextDisabled('После сканирования база сохраняется автоматически.')
        spaced(0, 12)
        if actionButton('Сохранить базу', imgui.ImVec2(170,34)) then
            rebuildList(); savePrices(); chat('База сохранена', 'success')
        end
        spaced(0, 20)
        sectionTitle('Очистка базы')
        imgui.TextWrapped('Удаляет сохранённые цены. История сделок остаётся.')
        if dangerButton('Очистить базу', imgui.ImVec2(170,34)) then
            prices={}; selectedName=nil; rebuildList(); savePrices(); chat('База очищена', 'success')
        end
        return
    end
    sectionTitle('Цены автобазара')
    imgui.SetNextItemWidth(-1)
    if imgui.InputTextWithHint('##search', 'Поиск машины...', searchBuf, 64) then
        filter = ffi.string(searchBuf)
    end
    spaced(0, 4)
    local rows = findPrices(filter)
    local listH = WIN_H - 224
    local leftW = 440
    imgui.BeginChild('##left', imgui.ImVec2(leftW, listH), true)
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
                imgui.SameLine(250)
                imgui.TextDisabled(('%d/30'):format(math.min(row.days, 30)))
                imgui.SameLine(300)
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
            imgui.TextWrapped(selectedName)
            imgui.PopStyleColor()
            imgui.Text(('Средняя: %s'):format(fmtMoney(info.price or 0)))
            spaced(0, 6)
            local prevW = math.floor(imgui.GetContentRegionAvail().x)
            if prevW < 280 then prevW = 280 end
            if prevW > 420 then prevW = 420 end
            carImg.drawPreview(selectedName, prevW * uiScale, uiScale)
            spaced(0, 4)
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
                    imgui.SameLine(150)
                    imgui.TextColored(imgui.ImVec4(0.45, 0.85, 0.55, 1), fmtMoney(row.price))
                end
            end
        end
    imgui.EndChild()
end

local function drawScan()
    sectionTitle('Сканирование цен')
    imgui.TextWrapped('Откройте на автобазаре список «Средняя цена автомобилей», затем запустите сканирование.')
    spaced(0, 14)
    if scanState.active then
        imgui.TextColored(accent(), 'Идёт сканирование — пожалуйста, подождите')
        imgui.TextDisabled(tostring(scanState.currentName or 'Получение списка транспорта'))
        imgui.TextDisabled('Примерное время: 5 минут. Результат сохраняется автоматически.')
        spaced(0, 12)
        if actionButton('Остановить', imgui.ImVec2(160,34)) then stopScan() end
    else
        imgui.TextDisabled(('Моделей в базе: %d'):format(#priceList))
        spaced(0, 12)
        if actionButton('Начать сканирование', imgui.ImVec2(220,34)) then requestScan() end
    end
    spaced(0, 24)
    sectionTitle('Скорость сканирования')
    imgui.Text(('Пауза между кликами: %d мс'):format(tonumber(waitPageMs[0]) or 0))
    imgui.SetNextItemWidth(280)
    imgui.SliderInt('##wp', waitPageMs, 0, 40)
end

local function drawSettings()
    settingsTab = tabs('settings', {'Интерфейс', 'Клавиши', 'Обновления'}, settingsTab)
    if settingsTab == 1 then
        sectionTitle('Масштаб и отображение')
        scalePercent[0] = math.floor((scanState.uiScale or 1) * 100 + 0.5)
        imgui.SetNextItemWidth(220)
        if imgui.SliderInt('Масштаб интерфейса', scalePercent, 60, 120, '%d%%') then
            scanState.uiScale = scalePercent[0] / 100
            scanState.saveSettings()
        end
        imgui.SameLine()
        if imgui.SmallButton('100%##resetScale') then
            scanState.uiScale = 1
            scanState.saveSettings()
        end
        imgui.Checkbox('Уведомлять о новых продажах', notifyNewSales)
        imgui.Checkbox('Средняя цена в техпаспорте', showPassportAvg)
    elseif settingsTab == 2 then
        sectionTitle('Горячие клавиши')
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

    else
        sectionTitle('Автообновление GitHub')
        if imgui.Checkbox('Проверять через 45 сек после спавна', scanState.autoUpdateOn) then scanState.saveSettings() end
        if actionButton(scanState.updateBusy and 'Проверяю...' or 'Проверить сейчас', imgui.ImVec2(200, 32)) then
            scanState.checkUpdate(true)
        end
    end
end

local function drawDeals()
    dealsTab = tabs('deals', {'История', 'Мои лоты', 'Добавить сделку'}, dealsTab)
    local unresolved = 0
    for _, entry in ipairs(pendingSell.confirmations) do
        if entry.state == 'unresolved' then unresolved = unresolved + 1 end
    end
    if unresolved > 0 and dealsTab ~= 2 then
        imgui.TextColored(imgui.ImVec4(1,0.76,0.3,1), ('Сделок для уточнения: %d'):format(unresolved))
        imgui.SameLine()
        if imgui.SmallButton('Уточнить сделки') then dealsTab = 2 end
        spaced(0, 6)
    end
    if dealsTab == 2 then
        sectionTitle('Лоты и подтверждения')
        local nLots = #(pendingSell.lots or {})
        for _, entry in ipairs(pendingSell.confirmations) do
            if entry.state == 'unresolved' then
                imgui.PushIDStr(entry.id)
                imgui.TextColored(imgui.ImVec4(1,0.76,0.3,1),
                    (entry.action=='buy' and 'Покупка' or 'Продажа')..' подтверждена — уточните данные')
                for _, candidate in ipairs(entry.candidates or {}) do
                    if isGenericCarName(candidate.model) then
                        imgui.TextDisabled('Модель не определена · '..fmtMoney(candidate.price))
                    elseif imgui.SmallButton(candidate.model..' · '..fmtMoney(candidate.price)..'##'..candidate.id) then
                        pendingSell.resolve(entry.id,candidate.id)
                    end
                end
                if imgui.SmallButton('Внести данные вручную') then
                    scanState.manualConfirmation=entry.id
                    dealsTab=3
                    setCString(dealModelBuf,64,entry.model or '')
                    setCString(dealPriceBuf,32,tostring(entry.price or ''))
                end
                imgui.SameLine()
                if imgui.SmallButton('Пропустить') then
                    entry.state='dismissed'
                    if scanState.manualConfirmation == entry.id then scanState.manualConfirmation=nil end
                    saveDealLogs()
                end
                imgui.PopID()
            end
        end
        if nLots > 0 then
            imgui.TextColored(imgui.ImVec4(0.45, 0.85, 0.55, 1),
                ('На АБ  %d'):format(nLots))
            for i = 1, nLots do
                local lot = pendingSell.lots[i]
                imgui.Text(('  %s  ·  %s'):format(
                    (lot.model ~= '' and lot.model) or 'транспорт',
                    fmtMoney(lot.price)))
                imgui.SameLine(320)
                if imgui.SmallButton('Убрать из учёта##' .. i) then
                    pendingSell.removeLot(i)
                    chat('Лот убран из памяти (машина на АБ не снимается)')
                    break
                end
            end
        else
            imgui.TextDisabled('В этой сессии нет учтённых лотов на автобазаре')
        end

        return
    elseif dealsTab == 3 then
        sectionTitle('Добавить сделку')
        if scanState.manualConfirmation then
            imgui.TextDisabled('Уточнение подтверждённой сделки')
            imgui.SameLine()
            if imgui.SmallButton('Отменить уточнение') then scanState.manualConfirmation=nil end
        end
        local pickedModel = ffi.string(dealModelBuf)
        imgui.SetNextItemWidth(280)
        if imgui.BeginCombo('##dealmodel', pickedModel ~= '' and pickedModel or 'модель из базы') then
            if imgui.IsWindowAppearing() then imgui.SetKeyboardFocusHere() end
            imgui.SetNextItemWidth(-1)
            imgui.InputTextWithHint('##dealmsearch', 'поиск по базе...', dealSearchBuf, 64)
            local rows = findPrices(ffi.string(dealSearchBuf))
            if #priceList == 0 then
                imgui.TextDisabled('Сначала скан — список из средних цен')
            elseif #rows == 0 then
                imgui.TextDisabled('Нет совпадений')
            else
                for i = 1, math.min(#rows, 80) do
                    local row = rows[i]
                    local name = row.name
                    local sel = name == pickedModel
                    if imgui.Selectable(('%s  %s'):format(name, fmtMoney(row.price)), sel) then
                        setCString(dealModelBuf, 64, name)
                        dealSearchBuf[0] = 0
                    end
                    if sel then imgui.SetItemDefaultFocus() end
                end
            end
            imgui.EndCombo()
        end
        imgui.SameLine()
        imgui.SetNextItemWidth(140)
        imgui.InputTextWithHint('##dealprice', 'цена, 12кк', dealPriceBuf, 32)
        local function submitManual(action)
            local model = normalizeName(ffi.string(dealModelBuf))
            if model == '' then
                local q = normalizeName(ffi.string(dealSearchBuf))
                if q ~= '' then
                    local rows = findPrices(q)
                    if #rows == 1 then model = rows[1].name else model = q end
                end
            end
            local priceRaw = ffi.string(dealPriceBuf)
            local price = parseAbbrevPrice(priceRaw) or cleanPriceNum(priceRaw)
            if model == '' then
                chat('Выбери модель из базы', 'warning')
                return
            end
            if not price or price <= 0 then
                chat('Укажи цену (можно 12кк)', 'warning')
                return
            end
            if scanState.manualConfirmation then
                local found=false
                for _,entry in ipairs(pendingSell.confirmations) do
                    if entry.id == scanState.manualConfirmation and entry.action == action then found=true; break end
                end
                if not found then chat('Выберите действие, соответствующее подтверждённой сделке.'); return end
                if not pendingSell.resolve(scanState.manualConfirmation,nil,model,price) then return end
                scanState.manualConfirmation=nil
            else
                addDeal(action, model, price, 'manual')
            end
            dealModelBuf[0] = 0
            dealSearchBuf[0] = 0
            dealPriceBuf[0] = 0
        end
        if actionButton('Купил', imgui.ImVec2(110, 28)) then submitManual('buy') end
        imgui.SameLine()
        if actionButton('Продал', imgui.ImVec2(110, 28)) then submitManual('sell') end
        imgui.TextDisabled('Модель — из базы средних цен. Если сделки нет в логе — внеси сюда.')

        return
    end
    sectionTitle('История сделок')
    local spent, earned = dealTotals()
    metric('Сделок', tostring(#dealLogs), 130)
    imgui.SameLine()
    metric('Потрачено', fmtMoney(spent), 170)
    imgui.SameLine()
    metric('Получено', fmtMoney(earned), 170)
    spaced(0, 6)
    imgui.BeginChild('##deals', imgui.ImVec2(-1, WIN_H - 310), true)
        if #dealLogs == 0 then
            imgui.TextDisabled('Пока пусто')
        else
            local removeIdx
            for i = #dealLogs, math.max(1, #dealLogs - 80), -1 do
                local log = dealLogs[i]
                local tag = log.action == 'buy' and 'Купил' or 'Продал'
                local col = log.action == 'buy' and imgui.ImVec4(0.95, 0.45, 0.45, 1) or imgui.ImVec4(0.45, 0.85, 0.55, 1)
                imgui.PushIDInt(i)
                imgui.TextDisabled(os.date('%d.%m %H:%M', log.time or 0))
                imgui.SameLine(90)
                imgui.TextColored(col, tag)
                imgui.SameLine(150)
                imgui.Text(tostring(log.model or ''))
                imgui.SameLine(320)
                imgui.TextColored(col, fmtMoney(log.price))
                imgui.SameLine(430)
                if imgui.SmallButton('x') then
                    removeIdx = i
                end
                imgui.PopID()
            end
            if removeIdx then
                table.remove(dealLogs, removeIdx)
                saveDealLogs()
            end
        end
    imgui.EndChild()
    spaced(0, 6)
    if dangerButton('Очистить сделки', imgui.ImVec2(180, 32)) then
        dealLogs = {}
        saveDealLogs()
        chat('Логи сделок очищены', 'success')
    end
end

local PAGE_DRAW = {
    base = drawBase,
    scan = drawScan,
    deals = drawDeals,
    chat = drawChatPage,
    settings = drawSettings,
}

scanState.forumUrl = 'https://www.blast.hk/threads/257682/#post-1695478'
scanState.logoUrl = 'https://raw.githubusercontent.com/andergr0ynd/autoabarz/refs/heads/main/images/abarz-logo.png'
scanState.eventsLibBase = {
    'https://cdn.jsdelivr.net/gh/andergr0ynd/autoabarz@main/arizona-events/',
    'https://raw.githubusercontent.com/andergr0ynd/autoabarz/refs/heads/main/arizona-events/',
}
scanState.eventsLibFiles = {
    { 'init.lua', '' },
    { 'subprocess.lua', '' },
    { 'core.lua', 'bad packet size' },
    { 'bitstream.lua', 'oversized string' },
}

function scanState.eventsLibPath(name)
    return getWorkingDirectory() .. '\\lib\\arizona-events\\' .. name
end

function scanState.eventsLibOk(name, marker)
    local f = io.open(scanState.eventsLibPath(name), 'rb')
    if not f then return false end
    local s = f:read('*a') or ''
    f:close()
    if #s < 32 then return false end
    local head = s:sub(1, 64):lower()
    if head:find('<!doctype', 1, true) or head:find('<html', 1, true) then return false end
    if marker and marker ~= '' and not s:find(marker, 1, true) then return false end
    return true
end

function scanState.downloadLibFile(name)
    ensureDir(getWorkingDirectory() .. '\\lib')
    ensureDir(getWorkingDirectory() .. '\\lib\\arizona-events')
    local path = scanState.eventsLibPath(name)
    if type(downloadUrlToFile) ~= 'function' then return false end
    local ml = require('moonloader')
    local ds = ml and ml.download_status
    if not ds then return false end
    local bases = scanState.eventsLibBase
    for i = 1, #bases do
        pcall(os.remove, path)
        local done, success = false, false
        local url = bases[i] .. name .. '?t=' .. tostring(os.time())
        pcall(downloadUrlToFile, url, path, function(_, status)
            if status == ds.STATUS_ENDDOWNLOADDATA or status == ds.STATUSEX_ENDDOWNLOAD then
                done = true
                success = true
            end
        end)
        local t0 = os.clock()
        while not done and os.clock() - t0 < 25 do wait(50) end
        if success and scanState.eventsLibOk(name, '') then return true end
        pcall(os.remove, path)
    end
    return false
end

function scanState.ensureEventsLib()
    local files = scanState.eventsLibFiles
    local need = false
    for i = 1, #files do
        if not scanState.eventsLibOk(files[i][1], files[i][2]) then
            need = true
            break
        end
    end
    if not need then return false end
    chat('Качаю arizona-events с GitHub AutoABarz…')
    local okAll = true
    for i = 1, #files do
        local name, marker = files[i][1], files[i][2]
        if not scanState.eventsLibOk(name, marker) then
            if not scanState.downloadLibFile(name) or not scanState.eventsLibOk(name, marker) then
                okAll = false
            end
        end
    end
    if not okAll then
        chat('Не удалось скачать arizona-events. CEF будет ограничен.', 'error')
        return false
    end
    chat('Библиотеки обновлены. Перезапуск скрипта…', 'success')
    wait(300)
    thisScript():reload()
    return true
end

function scanState.loadArizonaEvents()
    ok_arz, arz = pcall(require, 'arizona-events')
    if not ok_arz then arz = nil end
end
scanState.logoPath = getWorkingDirectory() .. '\\images\\abarz-logo.png'

function scanState.logoIsPng(path)
    local f = io.open(path, 'rb')
    if not f then return false end
    local head = f:read(8)
    local size = f:seek('end') or 0
    f:close()
    if not head or #head < 4 then return false end
    return head:byte(1) == 137 and head:byte(2) == 80 and head:byte(3) == 78 and head:byte(4) == 71 and size > 1500
end

function scanState.loadLogoTex()
    if scanState.logoTex then return end
    if not scanState.logoIsPng(scanState.logoPath) then return end
    local ok, tex = pcall(imgui.CreateTextureFromFile, scanState.logoPath)
    if ok and tex then scanState.logoTex = tex end
end

function scanState.applyLogoPart()
    local part = scanState.logoPath .. '.part'
    if not scanState.logoIsPng(part) then
        pcall(os.remove, part)
        scanState.logoBusy = false
        return
    end
    pcall(os.remove, scanState.logoPath)
    if not os.rename(part, scanState.logoPath) then
        pcall(function()
            local src = io.open(part, 'rb')
            local dst = io.open(scanState.logoPath, 'wb')
            if src and dst then dst:write(src:read('*a')) end
            if src then src:close() end
            if dst then dst:close() end
            os.remove(part)
        end)
    end
    scanState.logoBusy = false
    scanState.loadLogoTex()
end

function scanState.fetchLogo()
    if scanState.logoBusy or scanState.logoFetched then return end
    scanState.logoFetched = true
    scanState.logoBusy = true
    ensureDir(getWorkingDirectory() .. '\\images')
    local part = scanState.logoPath .. '.part'
    pcall(os.remove, part)
    if type(downloadUrlToFile) ~= 'function' then
        httpRequestAsync('GET', scanState.logoUrl, '', {
            ['User-Agent'] = 'AutoABarz/logo',
            ['Accept'] = 'image/png,image/*,*/*',
        }, function(body, err)
            scanState.logoBusy = false
            if err or type(body) ~= 'string' or #body < 1500 then return end
            if body:byte(1) ~= 137 or body:byte(2) ~= 80 or body:byte(3) ~= 78 or body:byte(4) ~= 71 then return end
            pcall(function()
                local f = io.open(part, 'wb')
                if f then f:write(body) f:close() end
            end)
            scanState.applyLogoPart()
        end, 20)
        return
    end
    local ml = require('moonloader')
    local ds = ml and ml.download_status
    scanState.logoJob = { done = false, ok = false, t0 = os.clock() }
    local job = scanState.logoJob
    pcall(downloadUrlToFile, scanState.logoUrl, part, function(_, status)
        if not ds or not job then return end
        if status == ds.STATUS_ENDDOWNLOADDATA or status == ds.STATUSEX_ENDDOWNLOAD then
            job.done = true
            job.ok = true
        end
    end)
end

function scanState.pumpLogo()
    local job = scanState.logoJob
    if not job then return end
    if job.done then
        scanState.logoJob = nil
        if job.ok then
            scanState.applyLogoPart()
        else
            pcall(os.remove, scanState.logoPath .. '.part')
            scanState.logoBusy = false
        end
        return
    end
    if os.clock() - (job.t0 or 0) > 25 then
        scanState.logoJob = nil
        pcall(os.remove, scanState.logoPath .. '.part')
        scanState.logoBusy = false
    end
end

function scanState.openForum()
    local url = scanState.forumUrl
    pcall(ffi.cdef, [[
        void* __stdcall ShellExecuteA(void* hwnd, const char* op, const char* file,
            const char* params, const char* dir, int show);
    ]])
    local opened = false
    pcall(function()
        ffi.load('Shell32').ShellExecuteA(nil, 'open', url, nil, nil, 1)
        opened = true
    end)
    if not opened then
        os.execute('cmd /c start "" "' .. url .. '"')
    end
end

local function drawSidebar()
    imgui.BeginChild('##sidebar', imgui.ImVec2(SIDEBAR, WIN_H), false)
        local dl = imgui.GetWindowDrawList()
        local min = imgui.GetWindowPos()
        local max = imgui.ImVec2(min.x + SIDEBAR, min.y + WIN_H)
        dl:AddRectFilled(min, max, u32(0.07, 0.08, 0.11, 1), 10)
        dl:AddRectFilled(min, imgui.ImVec2(min.x + 4, max.y), imgui.ColorConvertFloat4ToU32(accent()), 2)
        if not scanState.logoKick then
            scanState.logoKick = true
            scanState.loadLogoTex()
            scanState.fetchLogo()
        end
        local logoW = SIDEBAR - 20
        local logoH = math.floor(logoW * 9 / 16)
        imgui.SetCursorPos(imgui.ImVec2(10, 10))
        if scanState.logoTex then
            imgui.Image(scanState.logoTex, imgui.ImVec2(logoW, logoH))
        end
        imgui.SetCursorPos(imgui.ImVec2(14, 14 + logoH))
        imgui.TextDisabled('v' .. tostring(thisScript().version))
        imgui.SetCursorPosY(34 + logoH)
        for i, p in ipairs(PAGES) do
            imgui.SetCursorPosX(12)
            if navButton(p.title, page == i, SIDEBAR - 24) then page = i end
        end
        imgui.SetCursorPos(imgui.ImVec2(12, WIN_H - 80))
        imgui.SetWindowFontScale(0.86)
        if navButton('Тема на blast.hk', false, SIDEBAR - 24) then
            scanState.openForum()
        end
        imgui.SetWindowFontScale(1.0)
        if imgui.IsItemHovered() then
            imgui.SetTooltip(scanState.forumUrl)
        end
        imgui.SetCursorPos(imgui.ImVec2(18, WIN_H - 28))
        imgui.TextDisabled('/abarz | /abprice')
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
    imgui.SetNextWindowSize(imgui.ImVec2(CHAT_W, CHAT_H), imgui.Cond.Always)
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
                if m.self and m.delivery == 'sending' then
                    imgui.TextDisabled('Отправляется...')
                elseif m.self and m.delivery == 'failed' then
                    imgui.TextDisabled('Не отправлено')
                    imgui.SameLine()
                    if imgui.SmallButton('Повторить') then chatState.sendRow(m) end
                    if imgui.IsItemHovered() then imgui.SetTooltip(tostring(m.error or 'Ошибка отправки')) end
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
            chatState.outgoing = {}
        end
    end
    imgui.End()
    st.WindowPadding = imgui.ImVec2(0, 0)
end

local function drawScanNotice(sw, sh)
    local width = math.min(480, sw - 32)
    local height = 112
    imgui.SetNextWindowPos(imgui.ImVec2(sw / 2, sh - 28), imgui.Cond.Always, imgui.ImVec2(0.5, 1))
    imgui.SetNextWindowSize(imgui.ImVec2(width, height), imgui.Cond.Always)
    imgui.PushStyleVarFloat(imgui.StyleVar.WindowRounding, 12)
    imgui.PushStyleVarFloat(imgui.StyleVar.WindowBorderSize, 1)
    imgui.PushStyleVarVec2(imgui.StyleVar.WindowPadding, imgui.ImVec2(18, 14))
    imgui.PushStyleColor(imgui.Col.WindowBg, imgui.ImVec4(0.055, 0.07, 0.105, 0.97))
    imgui.PushStyleColor(imgui.Col.Border, imgui.ImVec4(0.36, 0.58, 1, 0.35))
    local flags = bit.bor(imgui.WindowFlags.NoDecoration, imgui.WindowFlags.NoInputs,
        imgui.WindowFlags.NoMove, imgui.WindowFlags.NoSavedSettings,
        imgui.WindowFlags.NoFocusOnAppearing, imgui.WindowFlags.NoBringToFrontOnFocus)
    if imgui.Begin('##abarzScanNotice', nil, flags) then
        local pos = imgui.GetWindowPos()
        local dl = imgui.GetWindowDrawList()
        local pulse = 0.65 + 0.35 * math.sin(os.clock() * 3)
        dl:AddCircleFilled(imgui.ImVec2(pos.x + 21, pos.y + 23), 3.5,
            imgui.ColorConvertFloat4ToU32(imgui.ImVec4(0.42, 0.68, 1, pulse)), 16)
        imgui.SetCursorPos(imgui.ImVec2(34, 14))
        imgui.TextColored(imgui.ImVec4(0.7, 0.83, 1, 1), 'Идёт сканирование')
        imgui.SetCursorPos(imgui.ImVec2(18, 40))
        imgui.Text('Пожалуйста, подождите.')
        imgui.SetCursorPos(imgui.ImVec2(18, 63))
        imgui.TextDisabled('Примерное время сканирования — 5 минут.')
        local track = width - 36
        local y = pos.y + height - 13
        dl:AddRectFilled(imgui.ImVec2(pos.x + 18, y), imgui.ImVec2(pos.x + width - 18, y + 3),
            imgui.ColorConvertFloat4ToU32(imgui.ImVec4(1, 1, 1, 0.08)), 2)
        local bar = track * 0.28
        local x = (os.clock() * 0.3 % 1) * (track + bar) - bar
        dl:AddRectFilled(imgui.ImVec2(pos.x + 18 + math.max(0, x), y),
            imgui.ImVec2(pos.x + 18 + math.min(track, x + bar), y + 3),
            imgui.ColorConvertFloat4ToU32(imgui.ImVec4(0.36, 0.64, 1, 0.95)), 2)
    end
    imgui.End()
    imgui.PopStyleColor(2)
    imgui.PopStyleVar(3)
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
    if scanState.forceCloseUi then
        win[0] = false
        chatOn[0] = false
        return false
    end
    return win[0] or chatOn[0] or scanState.active
end, function(player)
    local sw, sh = getScreenResolution()
    uiScale = math.min(math.max(0.6, math.min(1.2, scanState.uiScale or 1)),
        math.max(0.3, math.min((sw - 32) / WIN_W, (sh - 32) / WIN_H)))
    sw, sh = sw / uiScale, sh / uiScale
    -- Restore shared styles after drawing so library notifications keep their size.
    local sharedStyle = rawImgui.GetStyle()
    savedStyle = savedStyle or ffi.new('ImGuiStyle[1]')
    ffi.copy(savedStyle, sharedStyle, ffi.sizeof('ImGuiStyle'))
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
    if scanState.active then drawScanNotice(sw, sh) end
    ffi.copy(sharedStyle, savedStyle, ffi.sizeof('ImGuiStyle'))
end)

end
setupUi()

local CMDS = { 'abarz', 'abscan', 'abchat', 'abprice', 'carprice', 'abupdate' }

local function unregisterCmds()
    for _, name in ipairs(CMDS) do
        pcall(sampUnregisterChatCommand, name)
    end
end

function main()
    while not isSampAvailable() do wait(0) end
    if scanState.ensureEventsLib() then return end
    scanState.loadArizonaEvents()
    loadPrices()
    -- Сделки из файла — да. «На АБ» из файла — нет: при реконнекте скрипт часто
    -- перезагружается ещё до onConnectionLost, а сервер лоты уже снял.
    -- Лоты живут только в памяти текущей сессии скрипта (+ deals.json на дисконнекте чистим).
    loadDealLogs(false)
    forgetListed()
    pcall(scanState.loadSettings)
    cleanupCurrencyNames()
    pcall(carImg.loadVehiclesMap, false)

    unregisterCmds()
    saleAlive = true
    chat(('AutoABarz загружен. /abarz — в базе: %d'):format(#priceList))
    if scanState.menuBindOn[0] then
        chat(('Бинд меню: %s  ·  чат: %s  (Настройки → Клавиши)'):format(
            scanState.keyName(scanState.menuVk),
            scanState.chatBindOn[0] and scanState.keyName(scanState.chatVk) or 'выкл'))
    end
    if ntfy and ntfy.configure then
        pcall(ntfy.configure, {
            sale_window = 120,
            sale_threshold = 3,
            position = 'bottom_left',
            default_duration = 8000,
        })
    else
        chat('Библиотека notifications недоступна. Уведомления записываются в moonloader.log.', 'error')
    end
    if not ok_arz then
        chat('Нет arizona-events (lib) — CEF будет ограничен', 'warning')
    end
    if not ok_cef then
        chat('Нет arizona-cef-dialogs (lib) — CEF-диалоги могут не читаться', 'warning')
    end

    sampRegisterChatCommand('abarz', function() win[0] = not win[0] end)
    sampRegisterChatCommand('abscan', function() requestScan() end)
    sampRegisterChatCommand('abchat', function()
        setChatEnabled(not chatOn[0])
    end)
    local function cmdAbPrice(arg)
        arg = tostring(arg or ''):gsub('^%s+', ''):gsub('%s+$', '')
        if arg == '' then
            chat('Использование: /abprice [название]')
            return
        end
        rebuildList()
        local rows = findPrices(arg)
        if #rows == 0 then
            local avg, matched = resolveAvgForModel(arg)
            if avg and matched then
                local info = prices[matched]
                chat(('%s → %s — средняя %s, дней: %d'):format(
                    normalizeName(arg), matched, fmtMoney(avg), info and #(info.days or {}) or 0))
                if info and info.days then
                    for j = 1, math.min(3, #info.days) do
                        chat(('   %s: %s'):format(info.days[j].date, fmtMoney(info.days[j].price)))
                    end
                end
                return
            end
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
    end
    sampRegisterChatCommand('abprice', cmdAbPrice)
    sampRegisterChatCommand('carprice', cmdAbPrice)

    sampRegisterChatCommand('abupdate', function()
        scanState.checkUpdate(true)
    end)
    if scanState.autoUpdateOn[0] then
        lua_thread.create(function()
            local t0 = os.clock()
            while os.clock() - t0 < 45 do wait(500) end
            for _ = 1, 60 do
                local spawned = false
                pcall(function()
                    spawned = sampIsLocalPlayerSpawned and sampIsLocalPlayerSpawned()
                end)
                if spawned then break end
                wait(1000)
            end
            wait(2000)
            if not scanState.updateBusy then
                scanState.checkUpdate(false)
            end
        end)
    end

    while true do
        if scanState.wantScan then
            scanState.wantScan = false
            startScan()
        end
        pcall(scanState.pumpHttpJobs)
        pcall(scanState.pumpLogo)
        pcall(drainHttpCbQueue)
        pcall(pumpSales)
        pcall(scanState.mark.pump)
        pcall(pumpCefDialog)
        pcall(pumpScanFab)
        pcall(pumpPassportOverlay)
        pcall(carImg.pump)
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
        pcall(scanState.mark.release)
        rebuildList()
        savePrices()
        -- не сохранять лоты, если уже дисконнект / помечен сброс
        if pendingSell.dropListed then
            pendingSell.lots = {}
            pendingSell.dropListed = false
        else
            pcall(function()
                if not pendingSell.inWorld() then
                    pendingSell.lots = {}
                end
            end)
        end
        saveDealLogs()
        pcall(scanState.saveSettings)
        pcall(function()
            for _, slot in pairs(carImg.slots) do
                carImg.releaseSlot(slot)
            end
        end)
    end
end
