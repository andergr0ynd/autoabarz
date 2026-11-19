--[[
    /abarz  /abscan  /abprice  /abchat  /abupdate
    Репозиторий: github.com/andergr0ynd/autoabarz  (ветка main)
]]

script_name('AutoABarz')
script_author('pechkin')
script_version('1.9.2')
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
local LEGACY_PRICES_FILE = DATA_DIR .. '\\prices.json'
local DATA_FILE
local LOGS_FILE = DATA_DIR .. '\\deals.json'
local dealLogs = {}
local knownPlates = {}
local incomingChat = {}
local incomingDlg = {}
local incomingCef = {}
local pendingBuy = { active = false, model = '', price = 0, t = 0, source = '' }
local pendingSell = { lots = {}, max = 32, draftModel = '', muteNtfy = 0, confirmations = {}, sequence = 0, details = {} }
local needSellSnapshot = false
ensureDir(DATA_DIR)

-- Превью машин в «База»: методы на таблице (не local function — лимит 200 locals).
-- Official images are cached separately from legacy wiki pictures.
-- Optional custom pictures: config/abarz/cars/custom/<имя>.jpg|png.
local carImg = {
    dir = DATA_DIR .. '\\cars',
    mapFile = DATA_DIR .. '\\vehicles.json',
    officialDir = DATA_DIR .. '\\cars\\arizona',
    customDir = DATA_DIR .. '\\cars\\custom',
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
ensureDir(carImg.officialDir)
ensureDir(carImg.customDir)

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

function scanState.readUiMouse()
    if not scanState.uiMouseBackend then
        pcall(ffi.cdef,[[
            typedef struct { long x; long y; } ABarzMousePoint;
            int __stdcall GetCursorPos(ABarzMousePoint*);
            int __stdcall ScreenToClient(void*, ABarzMousePoint*);
            void* __stdcall GetForegroundWindow(void);
            short __stdcall GetAsyncKeyState(int);
        ]])
        scanState.uiMouseBackend=ffi.load('user32')
    end
    local backend=scanState.uiMouseBackend
    local hwnd=ffi.cast('void*',readMemory(0x00C8CF88,4,false))
    if hwnd==nil or backend.GetForegroundWindow()~=hwnd then return end
    local point=ffi.new('ABarzMousePoint[1]')
    if backend.GetCursorPos(point)==0 or backend.ScreenToClient(hwnd,point)==0 then return end
    return tonumber(point[0].x),tonumber(point[0].y),
        bit.band(backend.GetAsyncKeyState(1),0x8000)~=0,
        bit.band(backend.GetAsyncKeyState(2),0x8000)~=0,
        bit.band(backend.GetAsyncKeyState(4),0x8000)~=0
end

function scanState.syncUiMouse(io)
    local ok,x,y,left,right,middle=pcall(scanState.readUiMouse)
    if not ok then return false end
    if x and y then io.MousePos.x,io.MousePos.y=x,y end
    io.MouseDown[0],io.MouseDown[1],io.MouseDown[2]=not not left,not not right,not not middle
    return x~=nil
end

-- The launcher can return either a DNS name or the IP of the same server.
-- Keep one identity for chat and marketplace; never use the displayed server name.
-- Official PC launcher server list; DNS addresses verified on 18.11.2026.
scanState.servers = {
    {'Phoenix','phoenix','185.169.134.3'}, {'Tucson','tucson','185.169.134.4'},
    {'Scottdale','scottdale','185.169.134.43'}, {'Chandler','chandler','185.169.134.44'},
    {'Brainburg','brainburg','185.169.134.45'}, {'Saint Rose','saintrose','185.169.134.5'},
    {'Mesa','mesa','185.169.134.59'}, {'Red-Rock','redrock','185.169.134.61'},
    {'Yuma','yuma','185.169.134.107'}, {'Surprise','surprise','185.169.134.109'},
    {'Prescott','prescott','185.169.134.166'}, {'Glendale','glendale','185.169.134.171'},
    {'Kingman','kingman','185.169.134.172'}, {'Winslow','winslow','185.169.134.173'},
    {'Payson','payson','185.169.134.174'}, {'Gilbert','gilbert','80.66.82.191'},
    {'Show-Low','showlow','80.66.82.190'}, {'Casa Grande','casagrande','80.66.82.188'},
    {'Page','page','80.66.82.168'}, {'Sun City','suncity','80.66.82.159'},
    {'Queen Creek','queencreek','80.66.82.200'}, {'Sedona','sedona','80.66.82.144'},
    {'Holiday','holiday','80.66.82.132'}, {'Wednesday','wednesday','80.66.82.128'},
    {'Yava','yava','80.66.82.113'}, {'Faraway','faraway','80.66.82.82'},
    {'Bumble Bee','bumblebee','80.66.82.87'}, {'Christmas','christmas','80.66.82.54'},
    {'Mirage','mirage','80.66.82.39'}, {'Love','love','80.66.82.33'},
    {'Drake','drake','80.66.82.22'}, {'Space','space','80.66.82.199'},
    {'Vice City',nil,'80.66.82.147'},
    {'Home','home','80.66.82.235',33},
}
scanState.serverAliases = {}
for _,server in ipairs(scanState.servers) do
    if server[2] then scanState.serverAliases[server[2]..'.arizona-rp.com']=server[3] end
end
function scanState.canonicalServerHost(host)
    host=tostring(host or ''):lower():gsub('^%s+',''):gsub('%s+$','')
    host=(host:match('^([^:]+):%d+$') or host):gsub('%.$','')
    return scanState.serverAliases[host] or host
end

function scanState.pricesIdentity(host,port)
    if host==nil then
        if type(sampGetCurrentServerAddress)~='function' then return end
        if type(sampGetGamestate)=='function' and sampGetGamestate()~=3 then return end
        local ok
        ok,host,port=pcall(sampGetCurrentServerAddress)
        if not ok then return end
    end
    host,port=scanState.canonicalServerHost(host),tonumber(port)
    if host=='' or host=='0.0.0.0' or not port or port<=0 then return end
    local slug=host:gsub('[^%w%-]','-')
    for _,server in ipairs(scanState.servers) do
        if server[3]==host then slug=server[2] or 'vice-city'; break end
    end
    if port~=7777 then slug=slug..'-'..port end
    return {room=host..':'..port,vice=host=='80.66.82.147',
        path=DATA_DIR..'\\prices\\'..slug..'.json'}
end

function scanState.acquireInstance()
    if scanState.instanceHandle then return true end
    local ok,acquired=pcall(function()
        pcall(ffi.cdef,'void* __stdcall CreateMutexA(void*, int, const char*);')
        pcall(ffi.cdef,'unsigned long __stdcall GetLastError(void);')
        pcall(ffi.cdef,'unsigned long __stdcall GetCurrentProcessId(void);')
        pcall(ffi.cdef,'int __stdcall CloseHandle(void*);')
        local kernel=scanState.instanceKernel or ffi.load('kernel32')
        local name='Local\\AutoABarz-instance-'..tonumber(kernel.GetCurrentProcessId())
        local handle=kernel.CreateMutexA(nil,0,name)
        local exists=tonumber(kernel.GetLastError())==183
        if handle==nil or handle==ffi.NULL then return true end
        if exists then kernel.CloseHandle(handle); return false end
        scanState.instanceKernel,scanState.instanceHandle=kernel,handle
        return true
    end)
    if ok and not acquired then scanState.duplicateInstance=true; return false end
    scanState.duplicateInstance=nil
    return true
end

function scanState.releaseInstance()
    if scanState.instanceHandle then
        scanState.instanceKernel.CloseHandle(scanState.instanceHandle)
        scanState.instanceHandle=nil
    end
end

function scanState.isViceCity()
    local ip, name
    if type(sampGetCurrentServerAddress) == 'function' then
        local ok, value = pcall(sampGetCurrentServerAddress)
        if ok then ip = scanState.canonicalServerHost(value) end
    end
    if ip and ip ~= '' and ip ~= '0.0.0.0' then return ip == '80.66.82.147' end
    if type(sampGetCurrentServerName) == 'function' then
        local ok, value = pcall(sampGetCurrentServerName)
        if ok then name = ensure_utf8(tostring(value or '')) end
    end
    return name and name:lower():gsub('[%s%-%|_%.]+', ''):find('vicecity', 1, true) ~= nil or false
end

function scanState.dealsPath()
    local vice = scanState.marketProfile == 'vice'
        or (not scanState.marketProfile and scanState.isViceCity())
    return vice and (DATA_DIR .. '\\deals-vice-city.json') or LOGS_FILE
end

function scanState.listingSession()
    if type(sampGetGamestate)~='function' or sampGetGamestate()~=3
        or type(sampGetPlayerIdByCharHandle)~='function' or type(sampGetCurrentServerAddress)~='function'
        or type(pendingSell.localNick)~='function' then return end
    if not scanState.processId then
        pcall(ffi.cdef,'unsigned long __stdcall GetCurrentProcessId(void);')
        local ok,value=pcall(function() return tonumber(ffi.load('kernel32').GetCurrentProcessId()) end)
        if not ok then return end
        scanState.processId=value
    end
    local ok,found,id=pcall(sampGetPlayerIdByCharHandle,PLAYER_PED)
    local good,ip,port=pcall(sampGetCurrentServerAddress)
    local nick=pendingSell.localNick()
    if not ok or not found or not good or not nick or not ip or ip=='' or not port then return end
    return {process=scanState.processId,player=id,room=tostring(ip)..':'..tostring(port),nick=nick,at=os.time()}
end

function scanState.sameListingSession(saved)
    local current=scanState.listingSession()
    local at=type(saved)=='table' and tonumber(saved.at)
    return current and at and os.time()-at>=-5 and os.time()-at<=10
        and saved.process==current.process and saved.player==current.player
        and saved.room==current.room and saved.nick==current.nick or false
end

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
    local p = s:match(':CASHV?:(%d[%d%.,%s]*)') or s:match(':DONATE:(%d[%d%.,%s]*)')
        or s:match('VC%$(%d[%d%.,%s]*)')
    if p then return cleanPriceNum(p) end
    return cleanPriceNum(s)
end

local function dateOffset(daysAgo)
    daysAgo = tonumber(daysAgo) or 0
    local t = os.time() - daysAgo * 86400
    return os.date('%Y-%m-%d', t)
end

local function ensureCar(name)
    if scanState.priceSwitchPending then return end
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

local function setDayPrice(name, dateStr, price, count)
    name = normalizeName(name)
    dateStr = tostring(dateStr or ''):gsub('^%s+', ''):gsub('%s+$', '')
    price = cleanPriceNum(price)
    count = tonumber(count)
    if count and (count ~= count or count < 0 or count >= math.huge) then count=nil end
    if count then count=math.floor(count) end
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
            if count and row.count ~= count then row.count=count; changed=true end
            found = true
            break
        end
    end
    if not found then
        info.days[#info.days + 1] = { date = dateStr, price = price, count = count }
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
                        count = tonumber(row.count or row.sales or row.salesCount),
                    }
                end
            end
        end
        local price = tonumber(v.price or v.avg or v.average) or avgFromDays(days)
        prices[name] = { price = price or 0, days = days, updated = tonumber(v.updated) or os.time() }
    end
end

function scanState.legacyPricesFor(server)
    if server.vice or not doesFileExist(LEGACY_PRICES_FILE) then return end
    local claimPath=DATA_DIR..'\\prices-legacy-owner.json'
    local f=io.open(claimPath,'r')
    local owner
    if f then
        local ok,data=safeDecodeJson(f:read('*a')); f:close()
        if not ok then return end
        owner=data.room
    else
        if not scanState.writeJsonFile(claimPath,{room=server.room,migrated_at=os.time()}) then return end
        owner=server.room
    end
    if owner==server.room then return LEGACY_PRICES_FILE end
end

local function loadPrices(server)
    server=server or scanState.pricesIdentity()
    prices = {}
    selectedName=nil
    scanState.pricesDirty=false
    scanState.priceStore=server
    DATA_FILE=server and server.path or nil
    if not DATA_FILE then rebuildList(); return end
    ensureDir(DATA_DIR..'\\prices')
    local paths={DATA_FILE,DATA_FILE..'.bak'}
    local legacy
    if not doesFileExist(paths[1]) and not doesFileExist(paths[2]) then
        legacy=scanState.legacyPricesFor(server)
        if legacy then paths[#paths+1]=legacy end
    end
    for _,path in ipairs(paths) do
        local f = doesFileExist(path) and io.open(path, 'r')
        if f then
            local raw = f:read('*a')
            f:close()
            local ok, data = safeDecodeJson( raw)
            if ok and type(data) == 'table' and (not data.server or data.server==server.room) then
                local src = data.prices or data
                if type(src)=='table' then
                    for k, v in pairs(src) do
                        if type(k) == 'string' then migrateEntry(k, v) end
                    end
                    if path==legacy then
                        local saved=scanState.writeJsonFile(DATA_FILE,{version=3,server=server.room,prices=prices,saved_at=os.time()})
                        scanState.pricesDirty=not saved
                        scanState.saveAt=os.clock()+1
                    end
                    break
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
    if not DATA_FILE or not scanState.priceStore then return false end
    ensureDir(DATA_DIR)
    ensureDir(DATA_DIR..'\\prices')
    local ok,err=scanState.writeJsonFile(DATA_FILE,{version=3,server=scanState.priceStore.room,prices=prices,saved_at=os.time()})
    if ok then scanState.pricesDirty=false
    else
        scanState.saveAt=os.clock()+10
        print('AutoABarz prices: '..tostring(err or 'ошибка сохранения'))
    end
    return ok
end

function scanState.syncPrices()
    local server=scanState.pricesIdentity()
    if not server then
        scanState.priceSwitchPending=true
        scanState.active,scanState.wantScan=false,false
        return false
    end
    if scanState.priceStore and scanState.priceStore.room==server.room then
        scanState.priceSwitchPending=nil
        return true
    end
    scanState.priceSwitchPending=true
    scanState.active,scanState.wantScan=false,false
    scanState.scanEpoch=(scanState.scanEpoch or 0)+1
    if scanState.pricesDirty and not savePrices() then return false end
    scanState.dlg,scanState.currentName=nil,nil
    incomingDlg,incomingCef={},{}
    loadPrices(server)
    scanState.priceSwitchPending=nil
    return true
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
                    if row.count ~= nil then byDate[date].count=tonumber(row.count) end
                else
                    dst.days[#dst.days + 1] = { date = date, price = price, count=tonumber(row.count) }
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
                    days[#days + 1] = { date, price, tonumber(row.count) }
                end
            end
        end
        pack[name] = { p = tonumber(info.price) or 0, d = days }
        n = n + 1
    end
    local server=scanState.pricesIdentity()
    return encodeJson({ abarz = 1, t = os.time(), n = n, p = pack, room=server and server.room }), n
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
    local server=scanState.pricesIdentity()
    if data.room and (not server or data.room~=server.room) then return 0,'база относится к другому серверу' end

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
                                count = tonumber(pair[3] or pair.count),
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
                marketKey=lot.marketKey,marketObjectId=lot.marketObjectId,marketObjectHandle=lot.marketObjectHandle,
                marketX=lot.marketX,marketY=lot.marketY,marketZ=lot.marketZ,
                marketTurbo=lot.marketTurbo,marketMileage=lot.marketMileage,
                marketTurboKnown=lot.marketTurboKnown,
                marketTuning=lot.marketTuning,
                marketChatConfirmed=lot.marketChatConfirmed,marketRestoreUntil=lot.marketRestoreUntil,
                marketVehicleId=lot.marketVehicleId,marketSuppressed=lot.marketSuppressed,
            }
        end
    end
    local unresolved = {}
    for _, entry in ipairs(pendingSell.confirmations) do
        if entry.state == 'waiting' or entry.state == 'unresolved' then unresolved[#unresolved+1] = entry end
    end
    local ok,err=scanState.writeJsonFile(scanState.dealsPath(),{version=4,deals=dealLogs,listed=listed,unresolved=unresolved,
        listed_session=scanState.listingSession(),saved_at=os.time()})
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

local function ingestListedRow(row,verifiedSession)
    if type(row) ~= 'table' then return end
    local price = tonumber(row.price) or 0
    local at = tonumber(row.at) or 0
    if price <= 0 or at <= 0 or (not verifiedSession and (os.time() - at) >= 43200) then return end
    pendingSell.lots = pendingSell.lots or {}
    pendingSell.lots[#pendingSell.lots + 1] = {
        id = row.id or pendingSell.newId('lot'),
        model = tostring(row.model or ''),
        price = price,
        source = tostring(row.source or 'saved'),
        at = at,
        t = os.clock(),
        marketKey=row.marketKey,marketObjectId=tonumber(row.marketObjectId),marketObjectHandle=tonumber(row.marketObjectHandle),
        marketX=tonumber(row.marketX),marketY=tonumber(row.marketY),marketZ=tonumber(row.marketZ),
        marketTurbo=row.marketTurbo==true or nil,marketMileage=tonumber(row.marketMileage),
        marketTurboKnown=row.marketTurboKnown==true or row.marketTurbo==true or nil,
        marketTuning=scanState.marketplace.tuning.clean(row.marketTuning),
        marketChatConfirmed=row.marketChatConfirmed==true or nil,marketRestoreUntil=tonumber(row.marketRestoreUntil),
        marketVehicleId=tonumber(row.marketVehicleId),marketSuppressed=row.marketSuppressed==true or nil,
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
    local logsPath = scanState.dealsPath()
    for _,path in ipairs({logsPath,logsPath..'.tmp',logsPath..'.bak'}) do
        local f=io.open(path,'rb')
        if f then
            local raw=f:read('*a'); f:close()
            local ok,decoded=safeDecodeJson(raw)
            if ok and type(decoded)=='table' then data=decoded; break end
        end
    end
    if not data then return end
    local sessionRestore=keepListed=='session'
    if sessionRestore then keepListed=scanState.sameListingSession(data.listed_session) end
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
                for i = 1, #listed do ingestListedRow(listed[i],sessionRestore) end
            else
                ingestListedRow(listed,sessionRestore)
            end
        end
        if sessionRestore then
            for _,lot in ipairs(pendingSell.lots) do
                lot.marketRestoreUntil=math.min(lot.marketRestoreUntil or math.huge,(tonumber(data.saved_at) or os.time())+300)
                -- Older builds accumulated chat receipts without a physical car identity.
                -- Keep them for deal matching, but require fresh evidence to advertise again.
                if not lot.marketKey and not lot.marketVehicleId then lot.marketSuppressed=true end
                local id=lot.marketObjectId
                local handle=id and scanState.mark.objectHandle(id)
                if handle and type(getObjectModel)=='function' and getObjectModel(handle)==scanState.mark.abModel then
                    scanState.mark.objectSequence=(scanState.mark.objectSequence or 0)+1
                    lot.marketObjectGeneration=scanState.mark.objectSequence
                    scanState.mark.objects[id]={model=scanState.mark.abModel,generation=lot.marketObjectGeneration,
                        x=lot.marketX,y=lot.marketY,z=lot.marketZ}
                    if lot.marketObjectHandle==handle then lot.marketRestoreUntil=nil end
                end
            end
        end
    end
end

local function fmtMoney(n,currency)
    currency = currency or (scanState.isViceCity() and 'VC$' or '$')
    n = math.floor(tonumber(n) or 0)
    local s = tostring(n)
    local left, num, right = s:match('^([^%d]*%d)(%d*)(.-)$')
    if not left then return currency .. s end
    return currency .. left .. (num:reverse():gsub('(%d%d%d)', '%1.'):reverse()) .. right
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

function scanState.priceHistory(days)
    local byDate, points = {}, {}
    for _, row in ipairs(type(days) == 'table' and days or {}) do
        if type(row) == 'table' then
            local date = normalizeDate(row.date)
            local year, month, day = date:match('^(%d%d%d%d)%-(%d%d)%-(%d%d)$')
            year, month, day = tonumber(year), tonumber(month), tonumber(day)
            local price = cleanPriceNum(row.price)
            local limit = month and ({31,28,31,30,31,30,31,31,30,31,30,31})[month]
            if month == 2 and year and (year%400 == 0 or (year%4 == 0 and year%100 ~= 0)) then limit=29 end
            if year and year >= 1970 and limit and day >= 1 and day <= limit and price and not byDate[date] then
                local count=tonumber(row.count)
                if count and (count ~= count or count<0 or count>=math.huge) then count=nil end
                local y=year-(month<=2 and 1 or 0)
                local era=math.floor(y/400)
                local yoe=y-era*400
                local doy=math.floor((153*(month+(month>2 and -3 or 9))+2)/5)+day-1
                local ordinal=era*146097+yoe*365+math.floor(yoe/4)-math.floor(yoe/100)+doy
                local point = {date=date,price=price,count=count and math.floor(count),ordinal=ordinal}
                byDate[date]=point
                points[#points+1]=point
            end
        end
    end
    table.sort(points,function(a,b) return a.date < b.date end)
    while #points > MAX_DAYS do table.remove(points,1) end
    local result={points=points,sales=0,countDays=0}
    for _, point in ipairs(points) do
        if point.count ~= nil then result.sales=result.sales+point.count; result.countDays=result.countDays+1 end
        result.min=math.min(result.min or point.price,point.price)
        result.max=math.max(result.max or point.price,point.price)
    end
    if #points > 0 then
        result.delta=points[#points].price-points[1].price
        result.percent=result.delta/points[1].price*100
    end
    return result
end

function scanState.parseDayRow(line)
    local plain=stripColors(repair_mojibake(ensure_utf8(tostring(line or ''))))
    plain=plain:gsub('^%s+',''):gsub('%s+$','')
    local date,rest=plain:match('^(%d%d%d%d%-%d%d%-%d%d)(.*)$')
    if not date then date,rest=plain:match('^(%d%d[%.%/]%d%d[%.%/]%d%d%d%d)(.*)$') end
    if not date then return end
    local count,price=rest:match('^%s*(%d+)%s+(.+)$')
    if count then
        price=parseCashToken(price)
        if price then return normalizeDate(date),tonumber(count),price end
    end
    -- Legacy records may contain only the price; an unknown count is not zero.
    price=parseCashToken(rest:gsub('^%s*[—–|%-]+%s*',''))
    if price then return normalizeDate(date),nil,price end
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
        setDayPrice(name, normalizeDate(date), price, node.count or node.sales or node.salesCount)
    elseif name and price and not date then
        setPrice(name, price)
    elseif date and price and looksLikeDate(date) and (carHint or scanState.currentName) then
        setDayPrice(carHint or scanState.currentName, normalizeDate(date), price, node.count or node.sales or node.salesCount)
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
    if carHint then
        for line in text:gmatch('[^\r\n]+') do
            local date,count,price=scanState.parseDayRow(line)
            if date and price then setDayPrice(carHint,date,price,count) end
        end
    end

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
    local rowDate,rowCount,rowPrice=scanState.parseDayRow(line)
    if rowDate and scanState.currentName then
        return setDayPrice(scanState.currentName,rowDate,rowPrice,rowCount)
    end

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
        local date, cnt, price = scanState.parseDayRow(line)
        if date and price then
            days[#days + 1] = { date = date, count = cnt, price = price }
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
                setDayPrice(car, row.date, row.price, row.count)
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
        if normalizeDate(info.days[i].date or '') == today and info.days[i].count ~= nil then
            return true
        end
    end
    return false
end

local function requestScan()
    scanState.wantScan = true
end

local function startScan()
    if scanState.isViceCity() then
        chat('На Vice City нет системных средних цен. Найденные лоты доступны во вкладке «Цены».', 'info')
        return
    end
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

    scanState.scanEpoch=(scanState.scanEpoch or 0)+1
    local epoch=scanState.scanEpoch
    lua_thread.create(function()
        local function current() return scanState.scanEpoch==epoch end
        local page = 0
        local seenFirst = {}

        while current() and scanState.active and page < MAX_PAGES_SAFETY do
            local list = scanState.dlg
            if not list or list.kind ~= 'list' then
                list = waitForDialog('list', 4000, scanState.dlgSeq or 0)
            end
            if not current() then return end
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
                if not current() then return end
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
                    if not current() then return end
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

        if not current() then return end
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
    s = s:gsub(':CASHV?:', ''):gsub('VC%$', '')
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
    if scanState.isViceCity() then return nil end
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
    if scanState.isViceCity() then return nil, normalizeName(model) end
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

function scanState.mark.ownerOf(text)
    local owner = scanState.mark.clean(text):match('Владелец:%s*([^\r\n]+)')
    if owner then return normalizeName(owner:gsub('^%[%d+%]%s*', '')) end
end

function scanState.mark.parseVice(text)
    text = scanState.mark.clean(text)
    local number, model, amount = text:match('^%s*Автомобиль №(%d+)%s*\n([^\n]+)\n%s*VC%$(%d[%d%.%, ]*)%s*\n')
    if not number or not scanState.mark.validModel(model) then return nil end
    local price = cleanPriceNum(amount)
    local owner = scanState.mark.ownerOf(text)
    if not price or not owner or owner == '' then return nil end
    local mileage = text:match('\n%s*(%d[%d%.%, ]*)%s+км%s*\n')
    return 'sale', normalizeName(model), price, scanState.mark.turboOf(text), {
        number=tonumber(number), owner=owner, currency='VC$',
        mileage=mileage and tonumber((mileage:gsub(' ', ''):gsub(',', '.'))),
        expires=text:match('\n%s*(до [^\n]+)'),
    }
end

function scanState.mark.parseShort(text)
    text = scanState.mark.clean(text)
    if text:match('^%s*Автомобиль №') then return scanState.mark.parseVice(text) end
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
    if text:match('^%s*Автомобиль №') then return scanState.mark.parseVice(text) end

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
    if scanState.isViceCity() and kind == 'sale' then
        chat(('На продаже: %s за %s'):format(model, fmtMoney(price)))
        return
    end
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
    local interior = scanState.isViceCity() and 20 or scanState.mark.interior
    return type(getActiveInterior) == 'function' and getActiveInterior() == interior
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
        key = key,
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

function scanState.viceOffers(filter)
    local rows, now = {}, os.clock()
    filter = foldName(filter or '')
    for _, row in pairs(knownPlates) do
        local live = row.objectId and scanState.mark.objects[row.objectId]
        if row.vice and (live or now - (row.t or 0) < 90)
            and (filter == '' or foldName(row.model .. ' ' .. (row.owner or '')):find(filter,1,true)) then
            rows[#rows+1] = row
        end
    end
    table.sort(rows,function(a,b)
        if a.model ~= b.model then return a.model < b.model end
        if a.price ~= b.price then return a.price < b.price end
        return (a.vice.number or 0) < (b.vice.number or 0)
    end)
    return rows
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
        for _,i in ipairs(matches) do
            if not pendingSell.lots[i].marketSuppressed then return i,pendingSell.lots[i] end
        end
        return matches[1],pendingSell.lots[matches[1]]
    end
end

function pendingSell.addLot(model, price, source)
    price = cleanPriceNum(price)
    if not price then return false end
    model = normalizeName(model or pendingSell.draftModel or '')
    if isGenericCarName(model) then model = '' end
    if source=='chat' then
        local vehicle=scanState.marketplace and scanState.marketplace.currentVehicle()
        if vehicle then
            for _,lot in ipairs(pendingSell.lots) do
                if scanState.marketplace.vehicleIdentity(lot)==tostring(vehicle) and not scanState.marketplace.salePending(lot.id) then
                    lot.model,lot.price,lot.t,lot.at=pendingSell.preferName(lot.model,model),price,os.clock(),os.time()
                    lot.marketSuppressed,lot.marketRestoreUntil=nil,nil
                    lot.marketChatConfirmed=true
                    lot.marketVehicleId=vehicle
                    saveDealLogs(); return true
                end
            end
        end
        local candidate
        for _,lot in ipairs(pendingSell.lots) do
            if ((lot.source=='market-plate' and not lot.marketChatConfirmed) or lot.marketNeedsChat) and lot.price==price
                and os.clock()-(lot.marketChangedAt or lot.t or 0)<10 and pendingSell.sameModel(lot.model,model) then
                if candidate then candidate=nil; break end
                candidate=lot
            end
        end
        if candidate then
            candidate.marketChatConfirmed=true; candidate.marketNeedsChat=nil
            candidate.marketVehicleId=vehicle or candidate.marketVehicleId
            candidate.marketSuppressed=nil
            saveDealLogs(); return true
        end
    end
    -- Every server listing confirmation is a new lot, even for equal cars.
    pendingSell.lots[#pendingSell.lots+1] = {id=pendingSell.newId('lot'), model=model,price=price,
        t=os.clock(),at=os.time(),source=tostring(source or 'chat'),
        marketVehicleId=source=='chat' and scanState.marketplace and scanState.marketplace.currentVehicle() or nil}
    saveDealLogs()
    return true
end

function pendingSell.removeLot(idx)
    idx = tonumber(idx)
    if not idx or not pendingSell.lots or not pendingSell.lots[idx] then return nil end
    local lot = table.remove(pendingSell.lots, idx)
    if scanState.marketplace then scanState.marketplace.retire(lot) end
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
    if index then
        local removed=table.remove(pendingSell.lots,index)
        if scanState.marketplace then scanState.marketplace.retire(removed) end
    end
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
        local hasActive=false
        for _,lot in ipairs(pendingSell.lots) do if not lot.marketSuppressed then hasActive=true; break end end
        for _,lot in ipairs(pendingSell.lots) do
            if not hasActive or not lot.marketSuppressed then
                entry.candidates[#entry.candidates+1]={id=lot.id,model=lot.model,price=lot.price}
            end
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
        local a, b = costLine:match(':CASHV?:([%d%.,%s]+).-:CASHV?:([%d%.,%s]+)')
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
    if scanState.marketplace then
        local cancellation=clean:gsub('[%.!]+$','')
        local removed=clean:match('Вы сняли транспорт (.-) с продажи')
            or clean:match('Вы сняли автомобиль (.-) с продажи')
        if removed then scanState.marketplace.cancelOwn(removed); return end
        if cancellation=='Вы сняли транспорт с продажи' or cancellation=='Вы сняли свой транспорт с продажи'
            or cancellation=='Ваш транспорт был снят с продажи' then
            scanState.marketplace.cancelOwn(); return
        end
    end

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
    local owner=scanState.mark.ownerOf(text)
    rememberPlate(key, model, price, x, y, z, owner)
    if knownPlates[key] then knownPlates[key].objectId=sampId end
    local _, _, _, _, vice = scanState.mark.parseVice(text)
    if vice and knownPlates[key] then knownPlates[key].vice = vice end
    if kind=='sale' and fromSign and scanState.marketplace then
        scanState.marketplace.observeOwn(text,model,price,turbo,owner,sampId,x,y,z)
    end

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
                if p and p > 0 then return p end
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
    local owner = scanState.mark.ownerOf(utf)
    local avg, avgName = nil, nil
    if model then avg, avgName = resolveAvgForModel(model) end
    -- приоритет: табличка рядом → текст ПТС (цена продажи)
    local lot = model and select(1, scanState.findLot(model, owner)) or nil
    if (not lot or lot <= 0) then
        lot = passportLotFromText(utf)
    end
    local avgLabel = avg and fmtMoney(avg) or (scanState.isViceCity() and 'нет системных средних цен на Vice City' or 'нет в базе')
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
    if scanState.isViceCity() then avgLine = 'Vice City: системные средние цены отсутствуют' end
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
    if type(owner)~='string' then owner=nil else owner=normalizeName(owner:gsub('^%[%d+%]%s*','')) end
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
    scanState.marketplace.tuning.cef(packet)
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
    if snap.event=='event.inventory.playerInventory' or snap.event=='event.inventory.updateCharacterTab'
        or snap.event=='event.inventory.setPlayerInventoryVisible' or snap.event=='event.setActiveView' then
        incomingCef[#incomingCef+1]=snap
        if #incomingCef>256 then table.remove(incomingCef,1) end
        return
    end
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
    scanState.marketplace.tuning.saleDialog(id,text or '',finger)
    scanState.marketplace.tuning.dialog(title or '',text or '')
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
        if prevResponse then
            local result=prevResponse(id,button,listitem,input)
            if result~=nil then return result end
        end
        return scanState.marketplace.tuning.saleResponse(id,button,listitem,input)
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
            if scanState.marketplace then scanState.marketplace.retired[id]=nil end
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
        if scanState.marketplace then pcall(scanState.marketplace.noteSignGone,id) end
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
            if scanState.marketplace and type(data)=='table' and data.materialId==1 and type(v)=='string' then
                local object=scanState.mark.objects[id]
                scanState.marketplace.pendingClears[id]=v:match('^%s*$') and object and {generation=object.generation} or nil
                if not v:match('^%s*$') then scanState.marketplace.retired[id]=nil end
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
        if scanState.marketplace then pcall(scanState.marketplace.close) end
        pendingBuy.reset()
        scanState.mark.objects = {}
        knownPlates, PLATES, incomingPlates = {}, {}, {}
        -- сразу в deals.json, до возможной выгрузки скрипта при реконнекте
        pcall(forgetListed)
        if prevLost then pcall(prevLost) end
    end
    local prevClosed = ev.onConnectionClosed
    function ev.onConnectionClosed()
        if scanState.marketplace then pcall(scanState.marketplace.close) end
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

local function ensureChatCid()
    if chatState.cid ~= '' then return chatState.cid end
    chatState.cid = ('%s-%s-%d-%d'):format(
        pendingSell.localNick() or 'unknown',
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
        shareUrl = scanState.cloud.shareUrl(text)
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
    if scanState.cloud then
        local topic,suffix=tostring(url):match('^https://abarz%.internal/([^/]+)(.*)$')
        if topic and (topic:match('^abarz%-market%-v1%-') or topic:match('^abarzv161%-')) then
            if not scanState.cloud.url then queueHttpCb(callback,nil,'ABarz API не настроен',0); return end
            scanState.cloud.request(method,topic,suffix,body,callback,timeout)
            return
        end
        if tostring(url):find('^https?://ntfy%.sh/') then queueHttpCb(callback,nil,'Старые ссылки ntfy больше не поддерживаются',0); return end
    end
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
                    redirect = false,
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
                        -- 307/308 (and PUT redirects) must retain the publication body.
                        if c==303 and m~='HEAD' then
                            m,b='GET',''
                            hdrs['Content-Length']=nil
                        end
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
        url = tostring(url),
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
            if not (okFlag==true or okFlag==1) then
                scanState.lastHttpError=tostring(payload or 'error'):sub(1,160)..' ['..tostring(code)..']'
            end
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
scanState.cloud={defaultUrl='https://abarz-api.andergr0ynd-59c.workers.dev',queue={},active=0,generation=0,nextRegister=0}

function scanState.cloud.validUrl(url)
    return type(url)=='string' and url:match('^https://[%w%.%-]+$') and not url:find('%.%.')
end

function scanState.cloud.shareUrl(text)
    local url=tostring(text or ''):match('(https://[%w%.%-]+/v1/prices/[a-f0-9%-]+)')
    local base=scanState.cloud.url or scanState.cloud.defaultUrl
    if url and base and url:sub(1,#base+11)==base..'/v1/prices/' and #url==#base+11+36 then return url end
    return nil
end

function scanState.cloud.error(err,code)
    local ok,data=safeDecodeJson(tostring(err or ''))
    local detail=ok and data.error or tostring(err or 'Нет ответа')
    return 'ABarz API: '..tostring(detail)..' ['..tostring(code or 0)..']'
end

function scanState.cloud.load()
    local c=scanState.cloud
    local url=c.defaultUrl
    local f=io.open(DATA_DIR..'\\cloudflare.json','r')
    if f then
        local ok,data=safeDecodeJson(f:read('*a')); f:close()
        if ok and type(data.apiUrl)=='string' then url=data.apiUrl:gsub('/+$','') end
    end
    c.url=c.validUrl(url) and url or nil
    c.device=nil
    c.generation=c.generation+1
    c.queue,c.active,c.nextRegister,c.registering,c.nextPollAt={},0,0,false,0
    if not c.url then return end
    f=io.open(DATA_DIR..'\\cloudflare-device.json','r')
    if f then
        local ok,data=safeDecodeJson(f:read('*a')); f:close()
        if ok and data.apiUrl==c.url and type(data.token)=='string' and #data.token==64
            and data.token:match('^[a-f0-9]+$') and type(data.deviceId)=='string' then c.device=data end
    end
end

function scanState.cloud.request(method,topic,suffix,body,callback,timeout)
    local c=scanState.cloud
    if method~='GET' and method~='PUT' then queueHttpCb(callback,nil,'ABarz API: неподдерживаемый запрос',0); return end
    if #c.queue>=128 then queueHttpCb(callback,nil,'ABarz API: очередь переполнена',0); return end
    c.queue[#c.queue+1]={method=method,topic=topic,body=body or '',callback=callback,
        since=tostring(suffix):match('[?&]since=([%w_%-]+)'),untilAt=os.clock()+(tonumber(timeout) or 12)+20}
    c.pollReadyAt=c.pollReadyAt or (os.clock()+0.1)
end

function scanState.cloud.uploadPrices(topic,payload,nick,callback)
    local c=scanState.cloud
    if not c.url then queueHttpCb(callback,nil,'ABarz API не настроен',0); return end
    if #c.queue>=128 then queueHttpCb(callback,nil,'ABarz API: очередь переполнена',0); return end
    c.queue[#c.queue+1]={method='SHARE',topic=topic,body=payload,nick=nick,callback=callback,untilAt=os.clock()+80}
end

function scanState.cloud.register()
    local c=scanState.cloud
    if c.registering or os.time()<c.nextRegister then return end
    c.registering=true
    local generation=c.generation
    httpRequestAsync('POST',c.url..'/v1/register','{}',{['Content-Type']='application/json'},function(body,err,code)
        if generation~=c.generation then return end
        c.registering=false
        local ok,data=safeDecodeJson(body or '')
        if err or not ok or type(data.deviceId)~='string' or type(data.token)~='string'
            or #data.token~=64 or not data.token:match('^[a-f0-9]+$') then
            c.errorText=c.error(err or body,code)
            c.nextRegister=os.time()+60
            return
        end
        local device={apiUrl=c.url,deviceId=data.deviceId,token=data.token}
        if not scanState.writeJsonFile(DATA_DIR..'\\cloudflare-device.json',device) then
            c.errorText='Не удалось сохранить ключ ABarz API'
            c.nextRegister=os.time()+60; return
        end
        c.device,c.errorText=device,nil
    end,12)
end

function scanState.cloud.send(path,data,callback)
    local c=scanState.cloud
    local generation=c.generation
    c.active=c.active+1
    httpRequestAsync('POST',c.url..path,encodeJson(data),{
        ['Content-Type']='application/json',['Authorization']='Bearer '..c.device.token,
        ['User-Agent']='ABarz/1.9'},function(body,err,code)
        if generation~=c.generation then return end
        c.active=math.max(0,c.active-1)
        if err then c.errorText=c.error(err,code) else c.errorText=nil end
        if tonumber(code)==401 then
            c.device=nil; c.nextRegister=os.time()+10
            scanState.writeJsonFile(DATA_DIR..'\\cloudflare-device.json',{})
        end
        callback(body,err and c.errorText or nil,code)
    end,12)
end

function scanState.cloud.pump()
    local c=scanState.cloud
    if not c.url then return end
    local waiting={}
    for _,job in ipairs(c.queue) do
        if os.clock()>job.untilAt then queueHttpCb(job.callback,nil,c.errorText or 'ABarz API: timeout',0)
        else waiting[#waiting+1]=job end
    end
    c.queue=waiting
    if #c.queue==0 then c.pollReadyAt=nil; return end
    if not c.device then c.register(); return end
    while c.active<3 do
        local index
        for i,job in ipairs(c.queue) do if job.method=='PUT' or job.method=='SHARE' then index=i; break end end
        if not index then break end
        local job=table.remove(c.queue,index)
        local share=job.method=='SHARE'
        c.send(share and '/v1/prices' or '/v1/publish',share and {topic=job.topic,payload=job.body,nick=job.nick} or {topic=job.topic,message=job.body},function(body,err,code)
            queueHttpCb(job.callback,body,err,code)
        end)
    end
    if c.active>=3 or os.clock()<(c.pollReadyAt or 0) or os.time()<(c.nextPollAt or 0) then return end
    local topics,jobs,remaining={},{},{}
    for _,job in ipairs(c.queue) do
        if job.method=='GET' and #topics<2 then
            topics[#topics+1]={topic=job.topic,since=job.since or '1h'}; jobs[#jobs+1]=job
        else remaining[#remaining+1]=job end
    end
    c.queue=remaining
    c.pollReadyAt=os.clock()+0.1
    if #topics==0 then return end
    c.nextPollAt=os.time()+30
    c.send('/v1/poll',{topics=topics},function(body,err,code)
        local ok,data=safeDecodeJson(body or '')
        for index,job in ipairs(jobs) do
            local stream=ok and type(data.streams)=='table' and data.streams[index]
            if err or not stream or stream.topic~=job.topic or type(stream.body)~='string' then
                queueHttpCb(job.callback,nil,err or 'ABarz API: некорректный ответ каталога',code)
            else queueHttpCb(job.callback,stream.body,nil,200) end
        end
    end)
end

function carImg.safeKey(name)
    name = normalizeName(name):lower()
    name = name:gsub('[^%w%+%-%._]+', '_')
    name = name:gsub('_+', '_'):gsub('^_', ''):gsub('_$', '')
    if name == '' then name = 'car' end
    if #name > 80 then name = name:sub(1, 80) end
    return name
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
    local ok,rows=safeDecodeJson(raw)
    if not ok or type(rows)~='table' then return 0 end
    local mapped,n={},0
    for _,source in ipairs(rows) do
        if type(source)=='table' then
            local name=normalizeName(source.name or '')
            local sid,mid=tonumber(source.server_id),tonumber(source.model_id)
            if name~='' and sid and sid>0 and sid==math.floor(sid) then
                local key=name:lower()
                local previous=mapped[key]
                mapped[key]={name=name,model_id=mid,server_id=sid,img_id=sid,key=carImg.normKey(name),
                    ambiguous=previous and (previous.ambiguous or previous.server_id~=sid) or false}
                n=n+1
            end
        end
    end
    if n>0 then carImg.byName=mapped end
    return n
end

function carImg.loadVehiclesMap(force)
    if carImg.mapLoading then return end
    if carImg.mapAttempted and not force then return end
    carImg.mapAttempted=true
    carImg.mapLoading = true
    if doesFileExist(carImg.mapFile) and not force then
        local f = io.open(carImg.mapFile, 'r')
        if f then
            local raw = f:read('*a')
            f:close()
            if carImg.ingestVehiclesJson(raw) > 0 then
                carImg.mapReady = true
            end
        end
    end
    httpRequestAsync('GET',
        'https://api.arztools.tech/tools/arizona/vehicles.json',
        '',
        { ['User-Agent'] = 'Mozilla/5.0 (compatible; AutoABarz)', ['Accept'] = 'application/json' },
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
    model=normalizeName(model)
    if model=='' then return end
    local hit=carImg.byName[model:lower()]
    if hit then
        if not hit.ambiguous then return hit.img_id,hit.name,hit.model_id end
        return
    end
    -- Only harmless brand spelling aliases; never discard trim/chassis words.
    local key,best=carImg.normKey(model),nil
    for _,row in pairs(carImg.byName) do
        if row.key==key then
            if row.ambiguous or (best and best.img_id~=row.img_id) then return end
            best=row
        end
    end
    if best then return best.img_id,best.name,best.model_id end
end

function carImg.cdnUrl(imgId, mirror)
    imgId = tonumber(imgId)
    if not imgId then return nil end
    mirror = tonumber(mirror) or 1
    local base = carImg.cdn[mirror] or carImg.cdn[1]
    return base .. tostring(imgId) .. '.png'
end

function carImg.cachePathById(imgId)
    return carImg.officialDir .. '\\' .. tostring(imgId) .. '.png'
end

function carImg.tryCdn(name,imgId,mirror)
    imgId,mirror=tonumber(imgId),tonumber(mirror) or 1
    local slot=carImg.ensureSlot(name)
    if not imgId then slot.status='fail'; slot.msg='Точная модель не найдена'; return end
    local dest=carImg.cachePathById(imgId)
    if doesFileExist(dest) then
        carImg.releaseSlot(slot)
        slot.path,slot.status,slot.msg,slot.img_id=dest,'ready','',imgId
        return
    end
    slot.status,slot.msg,slot.img_id='loading','Загрузка фото Arizona…',imgId
    carImg.dlFail=function()
        if mirror<#carImg.cdn then carImg.tryCdn(name,imgId,mirror+1); return end
        slot.status,slot.msg='fail','Фото этой модели пока недоступно'
    end
    carImg.startFileDownload(name,carImg.cdnUrl(imgId,mirror),dest)
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

function carImg.request(name)
    name = normalizeName(name)
    if name == '' then return end
    carImg.activeName = name
    local slot = carImg.ensureSlot(name)
    if carImg.dl and carImg.dl.name~=name then
        carImg.pending=name
        return
    end
    carImg.loadVehiclesMap(false)

    if slot.tex and slot.status == 'ok' then return end
    if slot.status == 'loading' or slot.status == 'ready' then return end

    local imgId, matched, mid = carImg.resolveModelId(name)
    slot.img_id = imgId
    slot.model_id = mid
    slot.matched = matched

    -- ручной файл по имени
    local key = carImg.safeKey(name)
    for _, ext in ipairs({ '.jpg', '.jpeg', '.png', '.bmp' }) do
        local p = carImg.customDir .. '\\' .. key .. ext
        if doesFileExist(p) then
            carImg.releaseSlot(slot)
            slot.path = p
            slot.status = 'ready'
            slot.msg = ''
            return
        end
    end

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

    if not imgId then
        if carImg.mapLoading then
            slot.status = 'loading'
            slot.msg = 'карта машин…'
            carImg.pending = name
            return
        end
        slot.status = 'fail'
        slot.msg = 'Точная модель не найдена'
        return
    end

    slot.status = 'loading'
    slot.msg = 'CDN Arizona…'
    carImg.tryCdn(name, imgId, 1)
end

function carImg.pump()
    if carImg.pending and not carImg.dl and (carImg.mapReady or not carImg.mapLoading) then
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

function carImg.drawPreview(name, maxW, scale, compact, thumbnail)
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
        imgui.SetWindowFontScale(scale)
        local msg = slot.msg
        if slot.status == 'loading' then
            msg = msg ~= '' and msg or 'загрузка…'
        elseif slot.status == 'fail' then
            msg = msg ~= '' and msg or 'нет картинки'
        else
            msg = 'превью…'
        end
        if compact then msg = slot.status == 'fail' and 'Фото недоступно' or 'Загрузка фото…' end
        if thumbnail then msg = slot.status == 'fail' and 'Нет фото' or 'Загрузка…' end
        imgui.SetCursorPos(imgui.ImVec2(12 * scale, h / 2 - 8 * scale))
        imgui.TextDisabled(msg)
        imgui.EndChild()
    end
    if compact then return end
    if slot.img_id then
        imgui.TextDisabled(('CDN id  %d'):format(slot.img_id))
    elseif slot.model_id then
        imgui.TextDisabled(('model  %d'):format(slot.model_id))
    end
end

function carImg.drawThumbnail(name,width,scale)
    carImg.drawPreview(name,width*scale,scale,true,true)
    local slot=carImg.slots[normalizeName(name)]
    if slot and slot.tex and slot.status=='ok' and imgui.IsItemHovered() then
        imgui.BeginTooltip()
        imgui.SetWindowFontScale(scale)
        imgui.Text(normalizeName(name))
        imgui.Image(slot.tex,imgui.ImVec2(240*scale,math.floor(240*0.62)*scale))
        imgui.EndTooltip()
    end
end

-- Автообновление через effil. downloadUrlToFile + wait() в колбэке крашит lua51.dll.
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
    return scanState.cloud.shareUrl(raw)
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
    ip = scanState.canonicalServerHost(ip)
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
    local known=false
    for _,server in ipairs(scanState.servers) do if server[3]==ip then known=true; break end end
    if not special and not known and normChatName(name):find('vicecity', 1, true) then
        special = { label = 'Vice City', topic = 'abarzv161-qk7-hvc1' }
    end
    if special then
        return nil, special.label, special.topic
    end

    local num = parseServerNumFromName(name)
    local label = name ~= '' and name or (ip .. ':' .. tostring(port))
    local host = (ip .. '_' .. tostring(port)):gsub('[^%w]', '')
    if host == '' then host = 'unknown' end
    return num, label, 'abarzv161-qk7-h' .. host
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
    chatState.serverKey = scanState.canonicalServerHost(ip) .. ':' .. tostring(tonumber(port) or 0)
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
        shareUrl = scanState.cloud.shareUrl(att.url) or ''
    end
    if okPayload and type(payload)=='table' then shareUrl=scanState.cloud.shareUrl(payload.shareUrl) or shareUrl end
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
    chatState.pollMs = (scanState.cloud and scanState.cloud.url) and 30000 or 12000
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
    local since=chatState.sinceId
    if type(since)~='string' or not since:match('^[%w_%-]+$') then since='1h' end
    local url = 'https://abarz.internal/' .. topic .. '/json?poll=1&since='..since
    chatState.requestSeq = chatState.requestSeq + 1
    local request = {generation=chatState.generation,topic=topic,serverKey=chatState.serverKey,token=chatState.requestSeq}
    chatState.inFlight = true
    chatState.inFlightToken = request.token
    httpRequestAsync('GET', url, '', {
        ['User-Agent'] = 'ABarz/1.6',
        ['Accept'] = 'application/x-ndjson',
    }, function(body,err,code) onPollResult(body,err,code,request) end)
end

function scanState.verifyNtfyAck(body,topic,payload)
    local ok,ack=safeDecodeJson(body)
    if not ok or ack.event~='message' or ack.topic~=topic or type(ack.id)~='string'
        or ack.id=='' or ack.message~=payload then return false end
    return true
end

function scanState.publicationError(err,code)
    if tonumber(code)==429 then
        local detail=tostring(err or '')
        if detail:find('42908',1,true) or detail:find('daily message quota',1,true) then
            return 'Дневной лимит сервиса исчерпан (429). Новые лоты и сообщения пока не отправляются.'
        end
        return 'Сервис временно ограничил отправку (429). Повторю позже.'
    end
    return tostring(err or code or '?')
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
    httpRequestAsync('PUT','https://abarz.internal/'..topic,payload,{
        ['User-Agent']='ABarz/1.7.2', ['Content-Type']='text/plain; charset=utf-8',
        ['Title']=chatState.truncate(nick,64),
    },function(body,err,code)
        if tonumber(code)==429 then err=scanState.publicationError(err or body,code) end
        if not err and not scanState.verifyNtfyAck(body,topic,payload) then
            err='Сервис не подтвердил отправку сообщения'
        end
        if onDone then onDone(err,code) end
    end)
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
    chatState.pollMs = (scanState.cloud and scanState.cloud.url) and 30000 or 12000
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
        -- не сбрасываем seen/sinceId: иначе при открытии API снова отдаёт
        -- те же сообщения, и они накладываются на уже показанные
        chatState.status = 'подключение...'
        chatState.pollMs = (scanState.cloud and scanState.cloud.url) and 30000 or 12000
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
    if scanState.saveSettings then scanState.saveSettings() end
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
    if scanState.isViceCity() then
        chat('На Vice City нет базы системных средних цен для обмена.', 'info')
        return
    end
    if shareState.busy then return end
    if not scanState.syncPrices() then chat('Не удалось открыть базу текущего сервера.','warning'); return end
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
    local shareRoom=chatState.serverKey
    local nick = tostring(myNickname() or 'ABarz'):gsub('[\r\n]', ''):sub(1, 64)
    scanState.cloud.uploadPrices(topic,payload,nick,function(res, err, code)
        shareState.busy = false
        local url = ''
        local ok, obj = safeDecodeJson( tostring(res or ''))
        if ok and type(obj) == 'table' and type(obj.attachment) == 'table' then
            url = tostring(obj.attachment.url or '')
        end
        if url == '' then
            url = extractShareUrl(res) or ''
        end
        if not err and scanState.cloud.shareUrl(url) then
            if ok and obj.id then rememberChatId(tostring(obj.id)) end
            if shareRoom~=chatState.serverKey then shareState.msg='база отправлена на прежний сервер'; return end
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
    end)
end

local function startDownloadPrices(raw)
    if scanState.isViceCity() then
        chat('База средних цен Arizona не применяется к Vice City.', 'warning')
        return
    end
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
    local downloadRoom=scanState.pricesIdentity()
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
        local currentRoom=scanState.pricesIdentity()
        if not downloadRoom or not currentRoom or downloadRoom.room~=currentRoom.room then
            shareState.msg='сервер изменился'; chat('Скачивание базы отменено: сервер изменился.','warning'); return
        end
        if not scanState.syncPrices() then shareState.msg='база сервера недоступна'; return end
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
scanState.marketplace = {
    enabled=true, sharing=true, ttl=300, heartbeat=180, peers={}, generation=0, sequence=0,
    nextSend=0, nextPoll=0, status='Ожидание подключения', visibleAt=0,pendingClears={},retired={},
    selectedServer=0,viewGeneration=0,
}

function scanState.marketplace.serverLabel(index)
    local server=scanState.servers[index]
    if not server then return 'Текущий сервер' end
    return index==33 and server[1] or ('#%02d · %s'):format(server[4] or index,server[1])
end

function scanState.marketplace.serverOrder()
    local order={33,0}
    for index=1,#scanState.servers do if index~=33 then order[#order+1]=index end end
    return order
end

function scanState.marketplace.roomLabel(room)
    for index,server in ipairs(scanState.servers) do
        if room==server[3]..':7777' then return scanState.marketplace.serverLabel(index) end
    end
    return room or 'Нет подключения'
end

function scanState.marketplace.bindView()
    local m=scanState.marketplace
    local server=scanState.servers[m.selectedServer]
    local target=m.ctx
    if server and (not m.ctx or m.ctx.room~=server[3]..':7777') then
        target={room=server[3]..':7777',key='browse:'..server[3]..':7777',
            topic='abarz-market-v1-'..(server[3]..'-7777'):gsub('[^%w%-]','_'),
            currency=m.selectedServer==33 and 'VC$' or '$'}
    end
    if (m.viewCtx and m.viewCtx.key)~=(target and target.key) then
        m.viewGeneration=m.viewGeneration+1
        m.peers,m.cursor={},nil
        m.pollBusy,m.nextPoll,m.pollBlockedUntil=false,0,0
        m.status=target and 'Подключение к каталогу' or 'Ожидание подключения'
        m.viewCtx=target
    end
    return m.viewCtx
end

function scanState.marketplace.selectServer(index)
    local m=scanState.marketplace
    index=tonumber(index)
    if not index or index~=math.floor(index) or index<0 or index>#scanState.servers then return false end
    m.selectedServer=index
    m.bindView()
    return true
end

function scanState.marketplace.currentVehicle()
    if type(isCharInAnyCar)~='function' or type(storeCarCharIsInNoSave)~='function'
        or type(sampGetVehicleIdByCarHandle)~='function' then return end
    local ok,id=pcall(function()
        if not isCharInAnyCar(PLAYER_PED) then return end
        local found,value=sampGetVehicleIdByCarHandle(storeCarCharIsInNoSave(PLAYER_PED))
        if found and type(value)=='number' and value>0 and value<2000 then return value end
    end)
    if ok then return id end
end

scanState.marketplace.tuning={cache={},attempted={},types={[12]='v',[23]='t',[18]='n',[19]='p',[36]='n'}}

scanState.marketplace.tuning.itemNames={
    ["1031"]="Шашка такси (черный-1) [деталь тюнинга]",
    ["1129"]="Улучшение для автомобиля",
    ["2320"]="Сертификат Toyota Supra A90",
    ["2321"]="Сертификат UAZ",
    ["2322"]="Сертификат Volvo XC90 2012",
    ["2323"]="Талон снятия предупреждений",
    ["2324"]="Коленвал (improv)",
    ["2325"]="Коленвал (sport)",
    ["2326"]="Коленвал (sport+)",
    ["2327"]="Распредвал (improv)",
    ["2328"]="Распредвал (sport)",
    ["2329"]="Распредвал (sport+)",
    ["2330"]="Турбокомпрессор (improv)",
    ["2331"]="Турбокомпрессор (sport)",
    ["2332"]="Турбокомпрессор (sport+)",
    ["2333"]="Нагнетатель (improv)",
    ["2334"]="Нагнетатель (sport)",
    ["2335"]="Нагнетатель (sport+)",
    ["2336"]="Чип-тюнинг (STAGE 1)",
    ["2337"]="Чип-тюнинг (STAGE 2)",
    ["2338"]="Чип-тюнинг (STAGE 3)",
    ["2339"]="Сцепление (improv)",
    ["2340"]="Сцепление (sport)",
    ["2341"]="Сцепление (sport+)",
    ["2342"]="КПП (improv)",
    ["2343"]="КПП (sport)",
    ["2344"]="КПП (sport+)",
    ["2345"]="Дифференциал (improv)",
    ["2346"]="Дифференциал (sport)",
    ["2347"]="Дифференциал (sport+)",
    ["2348"]="Подвеска (improv)",
    ["2349"]="Подвеска (sport)",
    ["2350"]="Подвеска (sport+)",
    ["2351"]="Тормоза (improv)",
    ["2352"]="Тормоза (sport)",
    ["2353"]="Тормоза (sport+)",
    ["2354"]="Винил-1",
    ["2355"]="Винил-2",
    ["2356"]="Винил-3",
    ["2357"]="Винил-4",
    ["2358"]="Винил-5",
    ["2359"]="Винил-6",
    ["4817"]="Увеличенный бак (160 литров)",
    ["6516"]="Красное Нитро",
    ["9701"]="Диски (Пряня 2k26)",
    ["10123"]="Багажник Double-Gang",
    ["10276"]="Ковш: Mad Donut",
    ["10321"]="Номерная рамка: Rubio",
    ["10368"]="Номер на Т/С",
    ["10838"]="Протекающие радиоактивные бочки",
    ["10839"]="Гроб на крышу",
    ["10842"]="Адский нагнетатель",
    ["10856"]="Ухмыляющийся полумесяц",
}

function scanState.marketplace.tuning.itemName(id)
    local t=scanState.marketplace.tuning
    if not t.namesLoaded then
        t.namesLoaded=true
        for _,version in ipairs({35,34,33,0}) do
            local f=io.open(getWorkingDirectory()..'\\ArzMarket\\items_data'..version..'.json','r')
            if f then
                local raw=f:read(2000001); f:close()
                local ok,names=safeDecodeJson(raw)
                if ok and type(names)=='table' then t.names=names; break end
            end
        end
    end
    return t.names and t.names[tostring(id)] or t.itemNames[tostring(id)] or ('Деталь #'..tostring(id))
end

function scanState.marketplace.tuning.clean(data)
    if type(data)~='table' then return end
    local result,count={},0
    for _,key in ipairs({'v','t','p','m','n'}) do
        if data[key]~=nil then
            if type(data[key])~='table' or #data[key]>64 then return end
            result[key]={}
            for _,name in ipairs(data[key]) do
                if type(name)~='string' or #name>180 or name:find('[%c]') then return end
                count=count+1; if count>64 then return end
                result[key][#result[key]+1]=name
            end
        end
    end
    if next(result)==nil then return end
    return result
end

function scanState.marketplace.tuning.store(id,model,data)
    local m=scanState.marketplace
    local ctx=m.context()
    data=m.tuning.clean(data)
    if not ctx or not data or not id or not scanState.mark.validModel(model) then return false end
    local snapshot={id=id,model=model,data=data,at=m.now(),room=ctx.room,handle=m.tuning.handle(id)}
    m.tuning.cache[ctx.room..'/'..id]=snapshot
    if m.tuning.sale and (m.tuning.sale.phase=='opening' or m.tuning.sale.phase=='reading')
        and m.tuning.sale.vehicle==id and m.tuning.sale.room==ctx.room then
        m.tuning.sale.received=true
    end
    for _,lot in ipairs(pendingSell.lots) do
        if m.vehicleIdentity(lot)==tostring(id) and pendingSell.sameModel(lot.model,model) then lot.marketTuning=data end
    end
    m.tuning.pending=nil
    saveDealLogs()
    return true
end

function scanState.marketplace.tuning.handle(id)
    if type(sampGetCarHandleBySampVehicleId)~='function' then return end
    local ok,found,handle=pcall(sampGetCarHandleBySampVehicleId,id)
    if ok and found then return handle end
end

function scanState.marketplace.tuning.available()
    return ok_arz and arz and type(arz.eval)=='function'
end

function scanState.marketplace.tuning.eval(js)
    if not scanState.marketplace.tuning.available() then return false end
    return pcall(arz.eval,js,0)
end

function scanState.marketplace.tuning.saleDialog(id,text,finger)
    local t=scanState.marketplace.tuning
    local m=scanState.marketplace
    local clean=scanState.mark.clean(text)
    if tonumber(id)==8905 and clean:find('Вы хотите выставить свой транспорт на продажу за',1,true) then
        local ctx=m.context()
        local vehicle=m.currentVehicle()
        if ctx and vehicle then
            t.confirm={id=tonumber(id),finger=finger,context=ctx.key,room=ctx.room,vehicle=vehicle,handle=t.handle(vehicle)}
            return
        end
    end
    t.confirm=nil
    if t.sale then t.sale.interrupted=true end
end

function scanState.marketplace.tuning.saleResponse(id,button,listitem,input)
    local t=scanState.marketplace.tuning
    if t.replaying then return end
    if tonumber(button)~=1 then
        if t.sale and tonumber(id)==t.sale.id then t.sale.interrupted=true end
        return
    end
    if t.sale and tonumber(id)==t.sale.id then return false end
    local confirm=t.confirm
    if not confirm or tonumber(id)~=confirm.id or not t.available() then return end
    local ctx=scanState.marketplace.context()
    if not ctx or ctx.key~=confirm.context or scanState.marketplace.currentVehicle()~=confirm.vehicle then return end
    t.sale={id=confirm.id,button=button,listitem=listitem,input=input or '',finger=confirm.finger,
        context=confirm.context,room=confirm.room,vehicle=confirm.vehicle,handle=confirm.handle,phase='queued'}
    return false
end

function scanState.marketplace.tuning.finishSale(resume,reason)
    local t=scanState.marketplace.tuning
    local sale=t.sale
    if not sale then return end
    t.sale,t.pending,t.confirm,t.stage=nil,nil,nil,nil
    local ctx=scanState.marketplace.context()
    if sale.opened and ctx and ctx.key==sale.context then
        t.eval("window.executeEvent('event.inventory.setPlayerInventoryVisible','[false]');window.executeEvent('event.setActiveView','[null]');if(window.cef&&window.cef.SendMessage){window.cef.SendMessage('onActiveViewChanged|null',0);}")
        t.inventoryVisible=false
    end
    if not resume then
        if reason then chat(reason,'warning') end
        return
    end
    t.replaying=true
    local sent,err=pcall(sampSendDialogResponse,sale.id,sale.button,sale.listitem,sale.input)
    t.replaying=false
    if not sent then chat('Не удалось продолжить выставление: '..tostring(err),'error')
    elseif not sale.received then chat('Тюнинг не получен. Продолжаю выставление машины.','warning') end
end

function scanState.marketplace.tuning.pumpSale()
    local m=scanState.marketplace
    local t=m.tuning
    local sale=t.sale
    if not sale then return false end
    local ctx=m.context()
    local dialog=scanState.currentDialog
    if sale.interrupted or not ctx or ctx.key~=sale.context or m.currentVehicle()~=sale.vehicle
        or (sale.handle and sale.handle~=t.handle(sale.vehicle))
        or not dialog or dialog.id~=sale.id or dialog.finger~=sale.finger then
        t.finishSale(false,'Считывание тюнинга отменено: машина или окно изменились. Выставьте транспорт заново.')
        return true
    end
    if sale.phase=='queued' then
        sale.phase,sale.started,sale.deadline='opening',m.now(),m.now()+8
        t.attempted[sale.room..'/'..sale.vehicle]=true
        sale.opened=not t.inventoryVisible
        t.stage=nil
        t.pending={id=sale.vehicle,at=m.now()}
        chat('Считываю тюнинг машины перед выставлением…')
        if sale.opened then
            local sent=type(sampSendChat)=='function' and pcall(sampSendChat,'/invent')
            if not sent then t.finishSale(true); return true end
        end
    end
    if sale.received or m.now()>=sale.deadline then
        t.finishSale(true)
    elseif sale.phase=='opening' and t.inventoryVisible and (not sale.opened or m.now()-sale.started>=1) then
        sale.phase='reading'
        t.stage=nil
        local sent=t.eval("if(window.cef&&window.cef.SendMessage){window.cef.SendMessage('requestShowingInventory|30',0);}")
        if not sent then t.finishSale(true) end
    end
    return true
end

function scanState.marketplace.tuning.dialog(title,text)
    title=scanState.mark.clean(title)
    text=scanState.mark.clean(text)
    if not text:find('Технический тюнинг',1,true) or not text:find('Визуальный тюнинг',1,true) then return false end
    local model,id=title:match('^(.-)%s*%[ID:%s*(%d+)%]$')
    if not model then return false end
    local groups={['Визуальный тюнинг']='v',['Технический тюнинг']='t',['Винил']='p',['Модификация']='m',['Номерной знак']='n'}
    local data,key={},nil
    for line in text:gmatch('[^\r\n]+') do
        line=line:gsub('^%s+',''):gsub('%s+$','')
        if groups[line] then key=groups[line]; data[key]={}
        elseif key then
            local name=line:match('^%[%d+%]%s*(.-)\t') or line:match('^%[%d+%]%s*(.+)$')
            if name and name~='' then data[key][#data[key]+1]=name end
        end
    end
    return scanState.marketplace.tuning.store(tonumber(id),normalizeName(model),data)
end

function scanState.marketplace.tuning.cef(packet)
    local m=scanState.marketplace
    local t=m.tuning
    if packet.event=='event.inventory.setPlayerInventoryVisible' or packet.event=='event.setActiveView' then
        local doc=packet.json
        if type(doc)~='table' then local ok; ok,doc=safeDecodeJson(packet.jsonText or ''); if not ok then return end end
        if packet.event=='event.setActiveView' then
            if doc[1]=='Inventory' then t.inventoryVisible=true
            elseif doc[1]==nil or tostring(doc[1])=='null' then t.inventoryVisible=false end
        elseif type(doc[1])=='boolean' then t.inventoryVisible=doc[1] end
        return
    end
    local id=m.currentVehicle()
    local ctx=m.context()
    if not id or not ctx then t.stage=nil; return end
    local doc=packet.json
    if type(doc)~='table' then local ok; ok,doc=safeDecodeJson(packet.jsonText or ''); if not ok then return end end
    local event=packet.event or ''
    if event=='event.inventory.updateCharacterTab' then
        local stage=t.stage
        if doc[1]=='vehicle' and stage and stage.id==id and stage.room==ctx.room and m.now()-stage.at<=10
            and stage.model and stage.data.t and stage.data.v then
            t.store(id,stage.model,stage.data); t.stage=nil
        elseif doc[1]~='vehicle' then
            t.stage=nil
        end
        return
    end
    if event~='event.inventory.playerInventory' then return end
    for _,entry in ipairs(doc) do
        local data=type(entry)=='table' and entry.data
        if type(data)=='table' then
            local group=t.types[tonumber(data.type)]
            if group and entry.action==0 and type(data.items)=='table' then
                if not t.stage or t.stage.id~=id or t.stage.room~=ctx.room or m.now()-t.stage.at>10 then
                    t.stage={id=id,room=ctx.room,at=m.now(),data={},parts={}}
                end
                local list={}
                for _,item in ipairs(data.items) do
                    if type(item)=='table' and tonumber(item.item) and tonumber(item.item)>0 then
                        list[#list+1]=t.itemName(tonumber(item.item))
                    end
                end
                t.stage.parts[tonumber(data.type)]=list
                local merged={}
                for _,kind in ipairs({12,23,18,19,36}) do
                    if t.types[kind]==group then
                        for _,name in ipairs(t.stage.parts[kind] or {}) do merged[#merged+1]=name end
                    end
                end
                t.stage.data[group]=merged
            elseif entry.action==1 and type(data.name)=='string' and t.stage and t.stage.id==id and t.stage.room==ctx.room then
                t.stage.model=normalizeName(data.name)
            end
        end
    end
end

function scanState.marketplace.tuning.pump(forceId)
    local m=scanState.marketplace
    local t=m.tuning
    forceId=forceId or t.force
    t.force=nil
    local ctx=m.ctx
    if t.pumpSale() then return end
    if not ctx then t.stage,t.pending=nil,nil; return end
    local canRequest=not scanState.active and not scanState.wantScan
        and not (type(sampIsDialogActive)=='function' and sampIsDialogActive())
    for _,lot in ipairs(pendingSell.lots) do
        local id=m.vehicleIdentity(lot)
        local cached=id and t.cache[ctx.room..'/'..id]
        if cached and m.now()-cached.at<900 and pendingSell.sameModel(cached.model,lot.model)
            and (not cached.handle or cached.handle==t.handle(tonumber(id))) then lot.marketTuning=cached.data end
        if canRequest and id and not lot.marketSuppressed and not lot.marketTuning and m.currentVehicle()==tonumber(id)
            and (not t.attempted[ctx.room..'/'..id] or forceId==id) and ok_arz and arz and arz.eval then
            t.attempted[ctx.room..'/'..id]=true
            t.pending={id=tonumber(id),at=m.now()}
            pcall(arz.eval,"if(window.cef&&window.cef.SendMessage){window.cef.SendMessage('requestShowingInventory|30',0);}",0)
            break
        end
    end
    if t.pending and m.now()-t.pending.at>12 then t.pending=nil end
end

function scanState.marketplace.vehicleIdentity(lot)
    local id=tonumber(lot.marketVehicleId) or tonumber(tostring(lot.marketKey or ''):match('^vehicle:(%d+)$'))
    if id and id>0 and id==math.floor(id) then return tostring(id) end
end

function scanState.marketplace.reconcileIdentities()
    local m,seen,changed=scanState.marketplace,{},false
    local i=1
    while i<=#pendingSell.lots do
        local lot=pendingSell.lots[i]
        local identity=m.vehicleIdentity(lot)
        local keep=identity and seen[identity]
        if keep and not m.salePending(keep.id) and not m.salePending(lot.id) then
            if (lot.at or 0)>=(keep.at or 0) then
                keep.model,keep.price,keep.at,keep.t=lot.model,lot.price,lot.at,lot.t
                keep.marketSuppressed=lot.marketSuppressed
            end
            for _,field in ipairs({'marketKey','marketObjectId','marketObjectGeneration','marketObjectHandle',
                'marketX','marketY','marketZ','marketObservedAt','marketVehicleId','marketChatConfirmed',
                'marketTurbo','marketTurboKnown','marketMileage','marketTuning'}) do
                if keep[field]==nil then keep[field]=lot[field] end
            end
            keep.marketVehicleId=tonumber(identity)
            for _,entry in ipairs(pendingSell.confirmations) do
                local choices,ids={},{}
                for _,choice in ipairs(entry.candidates or {}) do
                    if choice.id==lot.id then choice.id=keep.id end
                    if not ids[choice.id] then choices[#choices+1]=choice; ids[choice.id]=true end
                end
                entry.candidates=choices
            end
            table.remove(pendingSell.lots,i)
            changed=true
        else
            if identity then seen[identity]=lot end
            i=i+1
        end
    end
    if changed then saveDealLogs() end
end

function scanState.marketplace.retire(lot)
    if not lot then return end
    local m=scanState.marketplace
    if lot.marketObjectId and lot.marketObjectGeneration then
        m.retired[lot.marketObjectId]=lot.marketObjectGeneration
    end
end

function scanState.marketplace.now() return os.time() end
function scanState.marketplace.request(...)
    return httpRequestAsync(...)
end

function scanState.marketplace.context()
    if not pendingSell.inWorld() or type(sampGetCurrentServerAddress)~='function' then return end
    local ok,ip,port=pcall(sampGetCurrentServerAddress)
    local nick=pendingSell.localNick()
    ip,port=scanState.canonicalServerHost(ip),tonumber(port)
    if not ok or ip=='' or ip=='0.0.0.0' or not port or port<=0 or not nick or nick=='' then return end
    local room=ip..':'..port
    return {room=room,nick=nick,key=room..'/'..nick,
        topic='abarz-market-v1-'..(ip..'-'..port):gsub('[^%w%-]','_'),
        currency=scanState.isViceCity() and 'VC$' or '$'}
end

function scanState.marketplace.collect()
    local m=scanState.marketplace
    local blocked,rows={},{}
    for _,entry in ipairs(pendingSell.confirmations) do
        if entry.action=='sell' and (entry.state=='waiting' or entry.state=='unresolved') then
            for _,candidate in ipairs(entry.candidates or {}) do blocked[candidate.id]=true end
        end
    end
    for _,lot in ipairs(pendingSell.lots) do
        local price=cleanPriceNum(lot.price)
        if not blocked[lot.id] and not lot.marketSuppressed and (not lot.marketRestoreUntil or lot.marketRestoreUntil>m.now())
            and price and not isGenericCarName(lot.model)
            and scanState.mark.validModel(lot.model)
            and (lot.source=='chat' or lot.source=='plate' or lot.source=='market-plate') then
            local mileage=tonumber(lot.marketMileage)
            if mileage and (mileage~=mileage or mileage<0 or mileage>1000000000) then mileage=nil end
            rows[#rows+1]={i=tostring(lot.id),m=chatState.truncate(lot.model,96),p=price,
                t=lot.marketTurbo==true or nil,tk=lot.marketTurboKnown==true or nil,km=mileage,
                u=scanState.marketplace.tuning.clean(lot.marketTuning)}
        end
    end
    table.sort(rows,function(a,b) return a.i<b.i end)
    return rows
end

function scanState.marketplace.noteSignGone(objectId)
    local object=scanState.mark.objects[objectId]
    if not object or object.model~=scanState.mark.abModel or not scanState.mark.inAb() then return end
    local px,py,pz=playerPos()
    if not px or not object.x or not object.y or not object.z then return end
    if dist3(px,py,pz,object.x,object.y,object.z)>25 then return end
    for _,lot in ipairs(pendingSell.lots) do
        if lot.marketObjectId==objectId and lot.marketObjectGeneration==object.generation then
            lot.marketGoneAt=os.clock()
        end
    end
end

function scanState.marketplace.salePending(lotId)
    for _,entry in ipairs(pendingSell.confirmations) do
        if entry.action=='sell' and (entry.state=='waiting' or entry.state=='unresolved') then
            for _,choice in ipairs(entry.candidates or {}) do if choice.id==lotId then return true end end
        end
    end
    return false
end

function scanState.marketplace.mergeReceipt(found,model,price)
    local candidate
    for i,lot in ipairs(pendingSell.lots) do
        if lot~=found and not lot.marketKey and lot.source=='chat' and lot.price==price
            and pendingSell.sameModel(lot.model,model) and os.clock()-(lot.t or 0)<=15 then
            if candidate then return false end
            candidate=i
        end
    end
    if not candidate then return false end
    local merged=table.remove(pendingSell.lots,candidate)
    for _,entry in ipairs(pendingSell.confirmations) do
        local seen,choices={},{}
        for _,choice in ipairs(entry.candidates or {}) do
            if type(choice)=='table' and choice.id then
                if choice.id==merged.id then choice.id=found.id end
                if not seen[choice.id] then choices[#choices+1]=choice; seen[choice.id]=true end
            end
        end
        entry.candidates=choices
    end
    found.marketChatConfirmed,found.marketNeedsChat=true,nil
    return true
end

-- A streamed sign belonging to this nickname is also a server listing confirmation.
function scanState.marketplace.observeOwn(text,model,price,turbo,owner,objectId,x,y,z)
    local m=scanState.marketplace
    if not m.enabled then return end
    local nick=pendingSell.localNick()
    if not nick or not owner or owner=='' then return end
    local clean=scanState.mark.clean(text)
    local rawOwner=clean:match('Владелец:%s*([^\r\n]+)') or ''
    local ownerRealm,nickRealm=rawOwner:match('^%[(%d+)%]'),nick:match('^%[(%d+)%]')
    local own=owner==normalizeName(nick:gsub('^%[%d+%]%s*',''))
        and not (ownerRealm and nickRealm and tonumber(ownerRealm)~=tonumber(nickRealm))
    local number=clean:match('^%s*Автомобиль №(%d+)') or clean:match('\nid:%s*(%d+)')
    local key=number and ('vehicle:'..number)
    if not key and x and y and z then key=('spot:%.1f:%.1f:%.1f'):format(x,y,z) end
    if not key then return end
    local object=objectId and scanState.mark.objects[objectId]
    if own and object and m.retired[objectId]==object.generation then return end
    if not own then
        for i=#pendingSell.lots,1,-1 do
            if pendingSell.lots[i].marketKey==key then pendingSell.removeLot(i) end
        end
        return
    end
    local found
    for _,lot in ipairs(pendingSell.lots) do if lot.marketKey==key then found=lot; break end end
    -- Material changes can give the same physical sign a new parking/vehicle label.
    if not found and object then
        for _,lot in ipairs(pendingSell.lots) do
            if lot.marketObjectId==objectId and lot.marketObjectGeneration==object.generation
                and not m.salePending(lot.id) then found=lot; break end
        end
    end
    local relocated=false
    if not found then
        local candidate
        for _,lot in ipairs(pendingSell.lots) do
            local object=lot.marketObjectId and scanState.mark.objects[lot.marketObjectId]
            local stillVisible=object and object.generation==lot.marketObjectGeneration
            if lot.marketKey and not stillVisible and lot.marketGoneAt and os.clock()-lot.marketGoneAt<=30
                and not m.salePending(lot.id) and pendingSell.sameModel(lot.model,model) then
                if candidate then candidate=nil; break end
                candidate=lot
            end
        end
        if candidate then found,relocated=candidate,true end
    end
    if not found then
        for _,lot in ipairs(pendingSell.lots) do
            if not lot.marketKey and lot.price==price
                and (isGenericCarName(lot.model) or pendingSell.sameModel(lot.model,model)) then found=lot; break end
        end
    end
    if not found then
        if not pendingSell.addLot(model,price,'market-plate') then return end
        found=pendingSell.lots[#pendingSell.lots]
    end
    local moved=found.marketX and x and y and z and dist3(found.marketX,found.marketY,found.marketZ,x,y,z)>0.5
    if not pendingSell.sameModel(found.model,model) then found.marketTuning=nil end
    local replacing=found.marketKey and (relocated or moved or found.model~=model or found.price~=price)
    local changed=found.model~=model or found.price~=price or found.marketKey~=key or moved
    if replacing then
        found.marketNeedsChat,found.marketChangedAt=true,os.clock()
    end
    found.model,found.price,found.marketKey,found.marketObjectId=model,price,key,objectId
    found.marketX,found.marketY,found.marketZ=x,y,z
    found.marketObservedAt=os.clock()
    found.marketGoneAt=nil
    found.marketObjectGeneration=objectId and scanState.mark.objects[objectId] and scanState.mark.objects[objectId].generation
    found.marketObjectHandle=objectId and scanState.mark.objectHandle(objectId)
    found.marketRestoreUntil=nil
    found.marketSuppressed=nil
    if objectId then m.pendingClears[objectId]=nil end
    found.marketTurbo=turbo=='Twin Turbo' or nil
    found.marketTurboKnown=true
    local _,_,_,_,vice=scanState.mark.parseVice(text)
    found.marketMileage=vice and vice.mileage or nil
    if replacing and m.mergeReceipt(found,model,price) then changed=true end
    if changed then saveDealLogs() end
end

function scanState.marketplace.reconcileRelocations()
    local m,now=scanState.marketplace,os.clock()
    for i=#pendingSell.lots,1,-1 do
        local old=pendingSell.lots[i]
        if old.marketGoneAt and now-old.marketGoneAt>=1 and now-old.marketGoneAt<=15 and not m.salePending(old.id) then
            local object=old.marketObjectId and scanState.mark.objects[old.marketObjectId]
            local stillVisible=object and object.generation==old.marketObjectGeneration
            local replacement
            if not stillVisible then
                for _,lot in ipairs(pendingSell.lots) do
                    local live=lot.marketObjectId and scanState.mark.objects[lot.marketObjectId]
                    if lot~=old and lot.marketKey~=old.marketKey and live and live.generation==lot.marketObjectGeneration
                        and (lot.source=='chat' or lot.marketChatConfirmed) and not m.salePending(lot.id)
                        and (lot.marketObservedAt or -math.huge)>=old.marketGoneAt-2
                        and now-(lot.marketObservedAt or -math.huge)<=15 and pendingSell.sameModel(lot.model,old.model) then
                        if replacement then replacement=nil; break end
                        replacement=lot
                    end
                end
            end
            if replacement then
                table.remove(pendingSell.lots,i)
                saveDealLogs()
            end
        end
    end
end

function scanState.marketplace.cancelOwn(model)
    local matches={}
    local vehicle=scanState.marketplace.currentVehicle()
    if vehicle then
        for i=#pendingSell.lots,1,-1 do
            local lot=pendingSell.lots[i]
            if scanState.marketplace.vehicleIdentity(lot)==tostring(vehicle) and (not model or pendingSell.sameModel(lot.model,model)) then
                pendingSell.removeLot(i)
                return
            end
        end
    end
    for i,lot in ipairs(pendingSell.lots) do
        if not model or pendingSell.sameModel(lot.model,model) then matches[#matches+1]=i end
    end
    if #matches==1 then pendingSell.removeLot(matches[1])
    else
        -- Do not keep advertising candidates when a generic cancellation is ambiguous.
        for _,i in ipairs(matches) do
            local lot=pendingSell.lots[i]
            lot.marketSuppressed=true
            scanState.marketplace.retire(lot)
        end
        saveDealLogs()
    end
end

function scanState.marketplace.fingerprint(rows)
    local parts={}
    for _,row in ipairs(rows) do parts[#parts+1]=table.concat({row.i,row.m,row.p,row.t and 'tt' or '',row.km or '',row.tk and 'known' or '',row.u and encodeJson(row.u) or ''},'\1') end
    return table.concat(parts,'\2')
end

function scanState.marketplace.ingest(line,ctx)
    local m=scanState.marketplace
    local active=m.viewCtx or m.ctx
    if not ctx or not active or ctx.key~=active.key then return false end
    if type(line)~='string' or #line>(scanState.cloud.url and 64000 or 16000) then return false end
    local ok,event=safeDecodeJson(line)
    if not ok or event.event~='message' or event.topic~=ctx.topic or type(event.message)~='string'
        or #event.message>(scanState.cloud.url and 16000 or 4000) then return false end
    local at=tonumber(event.time)
    local now=m.now()
    if not at or at~=at or at>now+60 or at+m.ttl<=now then return false end
    local good,p=safeDecodeJson(event.message)
    if not good or p.v~=1 or p.r~=ctx.room or p.c~=ctx.currency or type(p.s)~='string'
        or #p.s<8 or #p.s>160 or type(p.n)~='string' or #p.n<1 or #p.n>64
        or p.s:find('[%c]') or p.n:find('[%c]')
        or type(p.b)~='number' or p.b<=0 or p.b>at+60 or p.b~=math.floor(p.b)
        or type(p.q)~='number' or p.q<1 or p.q>1000000000 or p.q~=math.floor(p.q)
        or type(p.l)~='table' or #p.l>32 then return false end
    local previous=m.peers[p.s]
    if previous and p.q<=previous.sequence then return false end
    local rows,seen={},{}
    for key in pairs(p.l) do if type(key)~='number' or key<1 or key~=math.floor(key) then return false end end
    for _,row in ipairs(p.l) do
        if type(row)~='table' or type(row.i)~='string' or #row.i<1 or #row.i>160
            or type(row.m)~='string' or #row.m<1 or #row.m>96 or not scanState.mark.validModel(row.m)
            or row.i:find('[%c]') or row.m:find('[%c]')
            or not cleanPriceNum(row.p) or seen[row.i] then return false end
        seen[row.i]=true
        local mileage=tonumber(row.km)
        if mileage and (mileage~=mileage or mileage<0 or mileage>1000000000) then mileage=nil end
        rows[#rows+1]={key=p.s..'/'..row.i,id=row.i,model=normalizeName(chatState.truncate(row.m,96)),price=cleanPriceNum(row.p),
            seller=chatState.truncate(p.n,64):gsub('[%c]',''),currency=p.c,turbo=row.t==true,
            turboKnown=row.tk==true or row.t==true,mileage=mileage,updated=at,expires=at+m.ttl,
            tuning=m.tuning.clean(row.u),tuningOmitted=row.ut==true}
    end
    if not previous then
        local count=0
        for _ in pairs(m.peers) do count=count+1 end
        if count>=2048 then return false end
    end
    local publisher=scanState.cloud.url and type(p.d)=='string' and #p.d==36 and p.d or nil
    local generation=publisher and type(p.g)=='number' and p.g>0 and p.g==math.floor(p.g) and p.g or 0
    m.peers[p.s]={sequence=p.q,expires=at+m.ttl,rows=rows,seller=p.n,started=p.b,updated=at,publisher=publisher,generation=generation}
    return true
end

function scanState.marketplace.prune()
    local m=scanState.marketplace
    for session,peer in pairs(m.peers) do if peer.expires<=m.now() then m.peers[session]=nil end end
end

function scanState.marketplace.publish(rows,closing)
    local m=scanState.marketplace
    local ctx=m.ctx
    if not ctx or (m.sendBusy and not closing) then return end
    m.sequence=m.sequence+1
    local packet={v=1,r=ctx.room,c=ctx.currency,n=ctx.nick,s=m.session,b=m.started,q=m.sequence,l=rows}
    local body=encodeJson(packet)
    local fingerprint=m.fingerprint(rows)
    local maxBody=scanState.cloud.url and 16000 or 3900
    -- Optional details must never prevent the car itself from being published.
    while #body>maxBody do
        local largest,size=nil,0
        for i,row in ipairs(rows) do
            local bytes=row.u and #encodeJson(row.u) or 0
            if bytes>size then largest,size=i,bytes end
        end
        if not largest then break end
        rows[largest].u,rows[largest].ut=nil,true
        body=encodeJson(packet)
    end
    if #rows>32 or #body>maxBody then m.status='Слишком много лотов для публикации'; m.nextSend=m.now()+60; return end
    local generation=m.generation
    m.sendBusy=true
    m.publishStatus='Отправляю объявления…'
    m.nextSend=m.now()+3
    m.request('PUT','https://abarz.internal/'..ctx.topic,body,{
        ['Content-Type']='text/plain; charset=utf-8',['User-Agent']='ABarz-market/1'},
        function(reply,err,code)
            if generation~=m.generation or m.ctx~=ctx then return end
            m.sendBusy=false
            if not err and not scanState.verifyNtfyAck(reply,ctx.topic,body) then err='Сервис не подтвердил публикацию лотов' end
            if err or not reply or tonumber(code or 200)>=300 then
                m.sendFailures=math.min(5,(m.sendFailures or 0)+1)
                m.nextSend=m.now()+(tonumber(code)==429 and 600 or math.min(180,5*2^m.sendFailures))
                m.status=tonumber(code)==429 and scanState.publicationError(err or reply,code)
                    or ('Не удалось обновить объявления: '..tostring(err or code or '?'))
                m.publishStatus=m.status
                m.publishError=m.status
                return
            end
            m.sendFailures=0
            m.publishError=nil
            m.lastFingerprint=fingerprint
            m.needsInitialSnapshot=false
            m.lastSent=m.now()
            m.hadPublished=#rows>0
            m.status='Каталог обновляется автоматически'
            m.publishStatus='Мои объявления обновлены'
        end,12)
end

function scanState.marketplace.close()
    local m=scanState.marketplace
    if m.ctx and (m.hadPublished or m.sendBusy) then m.publish({},true) end
    m.generation=m.generation+1
    m.ctx,m.session,m.sendBusy,m.pollBusy=nil,nil,false,false
    m.peers,m.cursor={},nil
    m.tuning.cache,m.tuning.attempted,m.tuning.stage,m.tuning.pending,m.tuning.sale,m.tuning.confirm={},{},nil,nil,nil,nil
    m.viewCtx=nil
    m.viewGeneration=m.viewGeneration+1
    m.pendingClears={}
    m.lastFingerprint,m.hadPublished=nil,false
    m.publishError=nil
    m.nextSend,m.nextPoll,m.lastSent=0,0,0
end

function scanState.marketplace.bind()
    local m=scanState.marketplace
    local ctx=m.enabled and m.context() or nil
    if m.ctx and (not ctx or ctx.key~=m.ctx.key) then m.close() end
    if ctx and not m.ctx then
        m.generation=m.generation+1
        m.ctx=ctx
        m.started=m.now()
        m.session=ensureChatCid()..'-'..chatState.truncate(ctx.nick,32)..'-market-'..m.generation..'-'..m.now()
        m.sequence=0
        m.needsInitialSnapshot=true
        m.status='Подключение к каталогу'
    end
    return m.ctx
end

function scanState.marketplace.poll()
    local m=scanState.marketplace
    local ctx=m.viewCtx or m.ctx
    if not ctx or m.pollBusy or m.now()<(m.pollBlockedUntil or 0) then return end
    local generation=m.viewGeneration
    m.pollBusy=true
    local cursor=m.cursor or '5m'
    m.request('GET','https://abarz.internal/'..ctx.topic..'/json?poll=1&since='..cursor,'',{
        ['User-Agent']='ABarz-market/1',['Accept']='application/x-ndjson'},
        function(body,err,code)
            if generation~=m.viewGeneration or (m.viewCtx or m.ctx)~=ctx then return end
            m.pollBusy=false
            m.nextPoll=m.now()+(scanState.cloud.url and 30 or 15)
            if err or not body or tonumber(code or 200)>=300 then
                m.pollFailures=math.min(5,(m.pollFailures or 0)+1)
                m.pollBlockedUntil=m.now()+(tonumber(code)==429 and 120 or math.min(120,5*2^m.pollFailures))
                m.status='Каталог временно недоступен. Показаны ещё активные объявления.'
                return
            end
            m.pollFailures,m.pollBlockedUntil=0,0
            if #body>8000000 then m.status='Ответ каталога слишком большой'; return end
            local count=0
            for line in body:gmatch('[^\r\n]+') do
                count=count+1
                if count>5000 then break end
                local ok,event=false,nil
                if #line<=(scanState.cloud.url and 64000 or 16000) then ok,event=safeDecodeJson(line) end
                if ok and event.event=='message' and event.topic==ctx.topic and type(event.id)=='string'
                    and event.id:match('^[%w_%-]+$') and #event.id<=100 then m.cursor=event.id end
                m.ingest(line,ctx)
            end
            m.lastPoll=m.now()
            m.status='Каталог обновлён'
            m.prune()
        end,12)
end

function scanState.marketplace.rows(filter,minimum,maximum,onlyTT,ownOnly)
    local m=scanState.marketplace
    local view=m.viewCtx or m.ctx
    local localRoom=m.ctx and view and view.room==m.ctx.room
    m.prune()
    local result={}
    filter=foldName(filter or '')
    local function add(row)
        if (not minimum or row.price>=minimum) and (not maximum or row.price<=maximum)
            and (not onlyTT or row.turbo) and (not ownOnly or row.own)
            and (filter=='' or foldName(row.model..' '..row.seller):find(filter,1,true)) then result[#result+1]=row end
    end
    local latest={}
    for session,peer in pairs(m.peers) do
        local owner=peer.publisher or peer.seller
        local previous=latest[owner]
        if not previous or (peer.generation or 0)>(previous.peer.generation or 0)
            or ((peer.generation or 0)==(previous.peer.generation or 0) and (peer.started>previous.peer.started
            or (peer.started==previous.peer.started and session>previous.session))) then
            latest[owner]={session=session,peer=peer}
        end
    end
    for _,entry in pairs(latest) do
        local own=localRoom and (entry.peer.publisher and scanState.cloud.device and entry.peer.publisher==scanState.cloud.device.deviceId
            or (not entry.peer.publisher and entry.peer.seller==m.ctx.nick))
        if not own then for _,row in ipairs(entry.peer.rows) do add(row) end end
    end
    if localRoom then
        for _,lot in ipairs(m.collect()) do
            add({key=m.session..'/'..lot.i,id=lot.i,model=lot.m,price=lot.p,seller=m.ctx.nick,
                currency=m.ctx.currency,turbo=lot.t==true,turboKnown=lot.tk==true or lot.t==true,mileage=lot.km,own=true,updated=m.now(),
                tuning=lot.u})
        end
    end
    table.sort(result,function(a,b)
        if a.price~=b.price then return a.price<b.price end
        if a.model~=b.model then return a.model<b.model end
        return a.key<b.key
    end)
    return result
end

function scanState.marketplace.modelOffers(selected)
    local stats={count=0,others=0}
    for _,row in ipairs(scanState.marketplace.rows('')) do
        if row.currency==selected.currency and pendingSell.sameModel(row.model,selected.model) then
            stats.count=stats.count+1
            if row.key~=selected.key then stats.others=stats.others+1 end
            stats.minimum=math.min(stats.minimum or row.price,row.price)
            stats.maximum=math.max(stats.maximum or row.price,row.price)
        end
    end
    return stats
end

function scanState.marketplace.modelAverage(model,view)
    if not view or view.currency~='$' then return end
    local m=scanState.marketplace
    local average,name,info
    if scanState.priceStore and scanState.priceStore.room==view.room and not scanState.priceSwitchPending then
        average,name=resolveAvgForModel(model)
        info=name and prices[name]
    else
        local host,port=view.room:match('^([^:]+):(%d+)$')
        local server=host and scanState.pricesIdentity(host,port)
        if not server or server.vice then return end
        m.priceCaches=m.priceCaches or {}
        local cache=m.priceCaches[view.room]
        if not cache or m.now()-cache.at>=30 then
            cache={at=m.now(),prices={},matches={}}
            for _,path in ipairs({server.path,server.path..'.bak'}) do
                local f=io.open(path,'r')
                if f then
                    local raw=f:read(4000001); f:close()
                    local ok,data=false,nil
                    if type(raw)=='string' and #raw<=4000000 then ok,data=safeDecodeJson(raw) end
                    if ok and (not data.server or data.server==server.room) and type(data.prices)=='table' then
                        cache.prices=data.prices; break
                    end
                end
            end
            m.priceCaches[view.room]=cache
        end
        local key=foldName(model)
        local match=cache.matches[key]
        if match==nil then
            local exact,similar,ambiguous
            for candidate,value in pairs(cache.prices) do
                if type(candidate)=='string' and type(value)=='table' and cleanPriceNum(value.price) then
                    if foldName(candidate)==key then exact=candidate; break end
                    if pendingSell.sameModel(candidate,model) then
                        if similar then ambiguous=true end
                        similar=candidate
                    end
                end
            end
            match=exact or (not ambiguous and similar) or false
            cache.matches[key]=match
        end
        info=match and cache.prices[match]
        average=info and cleanPriceNum(info.price)
    end
    if not average or not info then return end
    local result={price=average,days=0,sales=0,countDays=0}
    for _,day in ipairs(type(info.days)=='table' and info.days or {}) do
        if type(day)=='table' and cleanPriceNum(day.price) then
            result.days=result.days+1
            local count=tonumber(day.count)
            if count and count==count and count>=0 and count<1000000000 and count==math.floor(count) then
                result.sales=result.sales+count; result.countDays=result.countDays+1
            end
            local date=normalizeDate(day.date or '')
            if date:match('^%d%d%d%d%-%d%d%-%d%d$') and (not result.date or date>result.date) then result.date=date end
        end
    end
    return result
end

function scanState.marketplace.pump()
    local m=scanState.marketplace
    m.sharing=true
    m.bind()
    local view=m.bindView()
    if not m.ctx then
        m.prune()
        if view and m.now()-(m.visibleAt or 0)<=2 and m.now()>=m.nextPoll then m.poll() end
        return
    end
    m.reconcileIdentities()
    m.tuning.pump()
    m.reconcileRelocations()
    -- Close-range removal is confirmed after a grace period for a moved/recreated sign.
    -- Keep the receipt for sale accounting; only withdraw its public advertisement.
    for _,lot in ipairs(pendingSell.lots) do
        if lot.marketGoneAt and os.clock()-lot.marketGoneAt>=3 and not lot.marketSuppressed then
            local object=lot.marketObjectId and scanState.mark.objects[lot.marketObjectId]
            if not object or object.generation~=lot.marketObjectGeneration then
                lot.marketSuppressed=true
                saveDealLogs()
            end
        end
    end
    for objectId,notice in pairs(m.pendingClears) do
        for i=#pendingSell.lots,1,-1 do
            local lot=pendingSell.lots[i]
            if lot.marketObjectId==objectId and lot.marketObjectGeneration==notice.generation then pendingSell.removeLot(i) end
        end
        m.pendingClears[objectId]=nil
    end
    m.prune()
    local rows=m.collect()
    local fingerprint=m.fingerprint(rows)
    local changed=m.needsInitialSnapshot or (fingerprint~=m.lastFingerprint and (#rows>0 or m.hadPublished))
    if not m.sendBusy and m.now()>=m.nextSend and (changed or (#rows>0 and m.now()-(m.lastSent or 0)>=m.heartbeat)) then
        m.publish(rows)
    end
    if m.now()-(m.visibleAt or 0)<=2 and m.now()>=m.nextPoll then m.poll() end
end



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
            marketBrowseServer = scanState.marketplace.selectedServer,
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
        if data.autoOn ~= nil then scanState.autoUpdateOn[0] = not not data.autoOn end
        scanState.marketplace.selectServer(data.marketBrowseServer or 0)
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
    for _, name in ipairs({'GetWindowPos','GetWindowSize','GetContentRegionAvail','GetItemRectMin','GetItemRectMax','GetMousePos','GetCursorScreenPos'}) do
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
    ui.Selectable=function(label,selected,flags,size)
        if size then return raw.Selectable(label,selected,flags or 0,vec(size)) end
        return raw.Selectable(label,selected,flags or 0)
    end
    ui.Image=function(texture, size, ...) return raw.Image(texture,vec(size),...) end
    ui.InvisibleButton=function(label,size) return raw.InvisibleButton(label,vec(size)) end
    ui.CalcTextSize=function(...) return logical(raw.CalcTextSize(...)) end
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
            AddLine=function(_,a,b,color,thickness)
                return dl:AddLine(vec(a),vec(b),color,(thickness or 1)*getScale())
            end,
            AddRect=function(_,a,b,color,rounding,corners,thickness)
                return dl:AddRect(vec(a),vec(b),color,(rounding or 0)*getScale(),corners,(thickness or 1)*getScale())
            end,
            AddText=function(_,pos,color,text) return dl:AddText(vec(pos),color,text) end,
            AddQuadFilled=function(_,a,b,c,d,color)
                return dl:AddQuadFilled(vec(a),vec(b),vec(c),vec(d),color)
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
local marketOwn=new.bool(false)
local marketSort=new.int(0)
local marketSelected
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
    { id = 'marketplace', title = 'Маркетплейс' },
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
local baseDetailsOpen = false

local function chartDate(date)
    local year,month,day=date:match('^(%d%d%d%d)%-(%d%d)%-(%d%d)$')
    return day and (day..'.'..month..'.'..year) or date
end

local function drawPriceHistory(days, chartHeight)
    local history=scanState.priceHistory(days)
    local points=history.points
    if #points==0 then
        imgui.TextWrapped('Нет данных по дням. Обновите базу сканированием средних цен.')
        return
    end
    local width=math.max(160,imgui.GetContentRegionAvail().x)
    local height=chartHeight or 224
    local origin=imgui.GetCursorScreenPos()
    imgui.InvisibleButton('##carPriceHistory',imgui.ImVec2(width,height))
    local hovered=imgui.IsItemHovered()
    local dl=imgui.GetWindowDrawList()
    local function v(x,y) return imgui.ImVec2(origin.x+x,origin.y+y) end
    dl:AddRectFilled(origin,v(width,height),u32(0.06,0.09,0.14,0.8),10)
    dl:AddRect(origin,v(width,height),u32(accentCol[1],accentCol[2],accentCol[3],0.25),10,nil,1)
    local left,right,top,bottom=82,width-24,22,height-34
    local range=history.max-history.min
    local padding=math.max(range*0.08,history.max*0.02,1)
    local low,high=math.max(0,history.min-padding),history.max+padding
    local plot={}
    for i,point in ipairs(points) do
        local t=#points==1 and 0.5 or (point.ordinal-points[1].ordinal)/(points[#points].ordinal-points[1].ordinal)
        plot[i]={x=left+t*(right-left),y=bottom-(point.price-low)/(high-low)*(bottom-top)}
    end
    local function shortMoney(n)
        local divisor,suffix=1,''
        if n>=1000000000 then divisor,suffix=1000000000,'B'
        elseif n>=1000000 then divisor,suffix=1000000,'M'
        elseif n>=1000 then divisor,suffix=1000,'K' end
        local label=divisor==1 and tostring(math.floor(n+0.5)) or ('%.1f'):format(n/divisor):gsub('%.0$','')
        return '$'..label..suffix
    end
    for tick=0,4 do
        local y=bottom-(bottom-top)*tick/4
        local label=shortMoney(low+(high-low)*tick/4)
        local size=imgui.CalcTextSize(label)
        dl:AddLine(v(left,y),v(right,y),u32(1,1,1,0.07),1)
        dl:AddText(v(left-size.x-12,y-size.y/2),u32(0.54,0.62,0.74,1),label)
    end
    local previousLabelEnd=-math.huge
    local ticks=math.min(6,#points)
    local lastLabelWidth=imgui.CalcTextSize(chartDate(points[#points].date):sub(1,5)).x
    for tick=1,ticks do
        local index=ticks==1 and 1 or math.floor((tick-1)*(#points-1)/(ticks-1)+0.5)+1
        local point,xy=points[index],plot[index]
        local label=chartDate(point.date):sub(1,5)
        local size=imgui.CalcTextSize(label)
        local x=math.max(left,math.min(right-size.x,xy.x-size.x/2))
        if tick==ticks or tick==1 or (x>=previousLabelEnd+12 and x+size.x+12<=right-lastLabelWidth) then
            dl:AddLine(v(xy.x,top),v(xy.x,bottom),u32(1,1,1,0.035),1)
            dl:AddText(v(x,bottom+10),u32(0.54,0.62,0.74,1),label)
            previousLabelEnd=x+size.x
        end
    end
    for i=2,#plot do
        local a,b=plot[i-1],plot[i]
        -- A few translucent strips make the area fade towards the baseline.
        for band=0,7 do
            local t0,t1=band/8,(band+1)/8
            dl:AddQuadFilled(v(a.x,a.y+(bottom-a.y)*t0),v(b.x,b.y+(bottom-b.y)*t0),
                v(b.x,b.y+(bottom-b.y)*t1),v(a.x,a.y+(bottom-a.y)*t1),
                u32(accentCol[1],accentCol[2],accentCol[3],0.2*(1-(t0+t1)/2)))
        end
    end
    for i=2,#plot do dl:AddLine(v(plot[i-1].x,plot[i-1].y),v(plot[i].x,plot[i].y),u32(accentCol[1],accentCol[2],accentCol[3],1),2.3) end
    if #plot==1 then dl:AddCircleFilled(v(plot[1].x,plot[1].y),3.5,u32(accentCol[1],accentCol[2],accentCol[3],1),16) end
    if hovered then
        local mouse=imgui.GetMousePos()
        local closest,distance=1,math.huge
        for i,xy in ipairs(plot) do
            local d=math.abs(mouse.x-origin.x-xy.x)
            if d<distance then closest,distance=i,d end
        end
        local xy,point=plot[closest],points[closest]
        dl:AddLine(v(xy.x,top),v(xy.x,bottom),u32(0.8,0.88,1,0.35),1)
        dl:AddCircleFilled(v(xy.x,xy.y),4,u32(0.8,0.9,1,1),16)
        local tip=chartDate(point.date)..'\n'..fmtMoney(point.price)
        if point.count then tip=tip..'\nПродаж: '..point.count end
        imgui.SetTooltip(tip)
    end
end

local function drawCarDetails(name,info)
    local width=imgui.GetContentRegionAvail().x
    if actionButton('‹ Назад',imgui.ImVec2(100,30)) then baseDetailsOpen=false end
    imgui.SameLine(120)
    imgui.Text(name)
    spaced(0,10)
    local history=scanState.priceHistory(info.days)
    local photoWidth=math.min(230,width*0.3)
    imgui.BeginChild('##carPhoto',imgui.ImVec2(photoWidth,220),false)
        carImg.drawPreview(name,photoWidth*uiScale,uiScale,true)
        imgui.TextDisabled('Средняя за период')
        imgui.TextColored(accent(),fmtMoney(info.price or 0))
        local sales=history.countDays>0 and tostring(history.sales) or '—'
        imgui.TextDisabled('Продаж за период: '..sales..(history.countDays<#history.points and ' (не все дни)' or ''))
    imgui.EndChild()
    imgui.SameLine()
    local tableWidth=width-photoWidth-10
    imgui.BeginChild('##carDayTable',imgui.ImVec2(-1,220),true)
        imgui.SetCursorPos(imgui.ImVec2(12,10))
        imgui.TextDisabled('Дата')
        imgui.SameLine(tableWidth*0.35)
        imgui.TextDisabled('Кол-во продаж')
        imgui.SameLine(tableWidth*0.62)
        imgui.TextDisabled('Средняя цена за день')
        spaced(0,4)
        imgui.Separator()
        for i=#history.points,1,-1 do
            local point=history.points[i]
            imgui.SetCursorPosX(12)
            imgui.Text(chartDate(point.date))
            imgui.SameLine(tableWidth*0.4)
            imgui.Text(point.count and tostring(point.count) or '—')
            imgui.SameLine(tableWidth*0.62)
            imgui.TextColored(accent(),fmtMoney(point.price))
            imgui.Separator()
        end
        if #history.points==0 then imgui.TextDisabled('Нет истории продаж.') end
    imgui.EndChild()
    spaced(0,10)
    drawPriceHistory(info.days,224)
    if #history.points>0 then
        imgui.TextDisabled(('Изменение за период: %+.1f%%'):format(history.percent))
        for _,point in ipairs(history.points) do
            if point.count==nil then
                imgui.TextWrapped('«—» — количество продаж не сохранено. Обновите базу сканированием.')
                break
            end
        end
    end
end

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

local function marketValue(label,value,color,scale)
    imgui.TextDisabled(label)
    imgui.SameLine(150)
    imgui.SetWindowFontScale(scale or 1.0)
    if color then imgui.PushStyleColor(imgui.Col.Text,color) end
    imgui.TextWrapped(tostring(value))
    if color then imgui.PopStyleColor() end
    imgui.SetWindowFontScale(1.0)
end

local function drawMarketTuning(selected)
    local count=0
    if selected.tuning then
        for _,items in pairs(selected.tuning) do count=count+#items end
    end
    local title=count>0 and ('Установленный тюнинг · %d'):format(count) or 'Установленный тюнинг'
    if not imgui.CollapsingHeader(title..'###tuning-'..tostring(selected.key or selected.id)) then return end
    if selected.tuning then
        for _,group in ipairs({{'t','Технический'},{'v','Визуальный'},{'p','Винил'},{'m','Модификация'},{'n','Номер'}}) do
            local items=selected.tuning[group[1]]
            if items and #items>0 then
                imgui.Text(group[2])
                for _,name in ipairs(items) do imgui.TextWrapped('• '..name) end
                spaced(0,4)
            end
        end
        if count==0 then imgui.TextDisabled('В считанных разделах деталей нет') end
    else
        imgui.TextWrapped(selected.tuningOmitted and 'Полный список деталей не передан: превышен размер объявления.'
            or 'Тюнинг ещё не считан продавцом.')
    end
end

local function drawMarketplaceContent()
    local m=scanState.marketplace
    m.visibleAt=m.now()
    sectionTitle('Маркетплейс игроков ABarz')
    local view=m.bindView()
    imgui.SetNextItemWidth(340)
    local selectedServer=m.selectedServer==0 and (m.roomLabel(m.ctx and m.ctx.room)..' · сейчас')
        or m.serverLabel(m.selectedServer)
    if imgui.BeginCombo('##marketServer',selectedServer) then
        for _,index in ipairs(m.serverOrder()) do
            local title=index==0 and ('Текущий сервер · '..m.roomLabel(m.ctx and m.ctx.room)) or m.serverLabel(index)
            if imgui.Selectable(title,m.selectedServer==index) then
                m.selectServer(index)
                marketSelected=nil
                scanState.saveSettings()
            end
        end
        imgui.EndCombo()
    end
    imgui.SameLine()
    view=m.viewCtx
    if imgui.SmallButton('Обновить каталог') then m.nextPoll=m.now() end
    if m.publishError then imgui.TextWrapped(m.publishError) end
    if (m.pollFailures or 0)>0 then imgui.TextWrapped(m.status) end
    if not view then
        imgui.TextWrapped('Выберите сервер в списке или подключитесь к игре. Здесь будут объявления продавцов с ABarz.')
        return
    end
    spaced(0,6)
    local toolbarWidth=imgui.GetContentRegionAvail().x
    if navButton('Все лоты##marketScope',not marketOwn[0],104) then marketOwn[0]=false end
    imgui.SameLine()
    if navButton('Мои##marketScope',marketOwn[0],76) then marketOwn[0]=true end
    local rows=m.rows('',nil,nil,false,marketOwn[0])
    imgui.SameLine(math.max(260,toolbarWidth-185))
    imgui.SetNextItemWidth(185)
    local sorts={'Сначала дешевле','Сначала дороже','Свежие объявления'}
    if imgui.BeginCombo('##marketSort',sorts[marketSort[0]+1]) then
        for i,title in ipairs(sorts) do
            if imgui.Selectable(title,marketSort[0]==i-1) then marketSort[0]=i-1 end
        end
        imgui.EndCombo()
    end
    if marketSort[0]==1 then table.sort(rows,function(a,b) return a.price>b.price end)
    elseif marketSort[0]==2 then table.sort(rows,function(a,b) return a.updated>b.updated end) end
    local selected
    for _,row in ipairs(rows) do if row.key==marketSelected then selected=row; break end end
    selected=selected or rows[1]
    marketSelected=selected and selected.key or nil
    spaced(0,8)
    local height=math.max(180,imgui.GetContentRegionAvail().y-30)
    local listWidth=math.max(310,math.min(360,imgui.GetContentRegionAvail().x*0.45))
    imgui.BeginChild('##marketList',imgui.ImVec2(listWidth,height),true)
        imgui.SetCursorPos(imgui.ImVec2(14,10))
        imgui.TextDisabled(('Объявления · %d'):format(#rows))
        spaced(0,4)
        for _,row in ipairs(rows) do
            imgui.PushIDStr(row.key)
            local active=marketSelected==row.key
            local titleLines=math.min(3,math.max(1,math.ceil(imgui.CalcTextSize(row.model).x/(listWidth-32))))
            local rowHeight=62+17*titleLines
            imgui.SetCursorPosX(6)
            imgui.PushStyleColor(imgui.Col.ChildBg,active and accentDim(0.16) or imgui.ImVec4(0,0,0,0))
            imgui.BeginChild('##marketRow',imgui.ImVec2(-6,rowHeight),false)
            local hitWidth=math.max(1,imgui.GetContentRegionAvail().x)
            if imgui.Selectable('##selectLot',false,0,imgui.ImVec2(hitWidth,rowHeight-4)) then marketSelected,selected=row.key,row end
            imgui.SetCursorPos(imgui.ImVec2(10,8))
            imgui.PushStyleColor(imgui.Col.Text,active and accent() or imgui.ImVec4(0.9,0.92,0.95,1))
            imgui.TextWrapped(row.model)
            imgui.PopStyleColor()
            imgui.TextColored(imgui.ImVec4(0.84,0.87,0.92,1),fmtMoney(row.price,row.currency))
            imgui.SetWindowFontScale(0.86)
            imgui.TextDisabled(row.seller..(row.own and ' · ваш лот' or ''))
            imgui.SetWindowFontScale(1.0)
            imgui.EndChild()
            imgui.PopStyleColor()
            spaced(0,3)
            imgui.PopID()
        end
        if #rows==0 then imgui.TextWrapped('Объявлений пока нет. Лоты появятся, когда игроки с ABarz выставят машины на продажу.') end
    imgui.EndChild()
    imgui.SameLine()
    imgui.BeginChild('##marketDetails',imgui.ImVec2(-1,height),false)
        imgui.SetCursorPos(imgui.ImVec2(14,10))
        imgui.BeginChild('##marketDetailsContent',imgui.ImVec2(-14,-10),false)
        if selected then
            local average=m.modelAverage(selected.model,view)
            local titleWidth=math.max(100,imgui.GetContentRegionAvail().x-110)
            local titleHeight=math.max(64,math.ceil(imgui.CalcTextSize(selected.model).x*1.16/titleWidth)*22+26)
            carImg.drawThumbnail(selected.model,96,uiScale)
            imgui.SameLine()
            imgui.BeginChild('##marketTitle',imgui.ImVec2(-1,titleHeight),false)
                imgui.SetWindowFontScale(1.16)
                imgui.TextWrapped(selected.model)
                imgui.SetWindowFontScale(1.0)
                imgui.TextDisabled(m.roomLabel(view.room))
            imgui.EndChild()
            spaced(0,10)
            marketValue('Цена лота',fmtMoney(selected.price,selected.currency),accent(),1.20)
            if average then
                marketValue('Средняя сервера',fmtMoney(average.price,selected.currency))
                local delta=selected.price-average.price
                local percent=math.abs(delta)/average.price*100
                local color=delta<0 and imgui.ImVec4(0.45,0.85,0.55,1)
                    or (delta>0 and imgui.ImVec4(0.95,0.45,0.45,1) or imgui.ImVec4(0.68,0.72,0.78,1))
                local comparison=delta==0 and 'На уровне средней цены' or
                    (('%s на %s (%.1f%%)'):format(delta<0 and 'Дешевле' or 'Дороже',fmtMoney(math.abs(delta),selected.currency),percent))
                marketValue('К средней цене',comparison,color,0.96)
                if average.countDays>0 then
                    marketValue('Продажи',('%d за %d дней%s'):format(average.sales,average.days,
                        average.countDays<average.days and ' · неполные данные' or ''))
                end
                if average.date then marketValue('Данные на',chartDate(average.date)) end
            else
                imgui.TextWrapped(selected.currency=='VC$' and 'На Vice City нет системной средней цены.'
                    or 'Средняя цена этого сервера ещё не сохранена.')
            end
            spaced(0,8)
            imgui.Separator()
            spaced(0,8)
            marketValue('Продавец',selected.seller)
            if imgui.IsItemHovered() then imgui.SetTooltip('Ник передан скриптом продавца. Сервер Arizona его не подтверждает.') end
            marketValue('Тюнинг',selected.turbo and 'Twin Turbo' or (selected.turboKnown and 'Без Twin Turbo' or 'Не указан'),
                selected.turbo and accent() or nil)
            imgui.SetCursorPosX(150)
            if imgui.SmallButton('Скопировать ник') and type(setClipboardText)=='function' then setClipboardText(selected.seller) end
            imgui.SameLine()
            if selected.own then
                if m.lastFingerprint~=m.fingerprint(m.collect()) then imgui.TextDisabled(m.publishStatus or 'Ожидает публикации')
                else imgui.TextDisabled('Ваше объявление') end
            else
                imgui.TextDisabled(('Обновлено %d сек. назад'):format(math.max(0,m.now()-selected.updated)))
            end
            spaced(0,8)
            imgui.Separator()
            spaced(0,8)
            drawMarketTuning(selected)
            local vehicle=selected.own and m.vehicleIdentity({marketKey=selected.id})
            if selected.own then
                for _,lot in ipairs(pendingSell.lots) do if lot.id==selected.id then vehicle=m.vehicleIdentity(lot); break end end
                if vehicle and m.currentVehicle()==tonumber(vehicle) then
                    if imgui.SmallButton('Считать тюнинг') then
                        for _,lot in ipairs(pendingSell.lots) do if lot.id==selected.id then lot.marketTuning=nil; break end end
                        m.tuning.cache[m.ctx.room..'/'..vehicle]=nil
                        m.tuning.force=vehicle
                    end
                    if m.tuning.pending then imgui.TextDisabled('Запрашиваю детали автомобиля…') end
                end
            end
        elseif #pendingSell.lots>0 then
            imgui.TextWrapped('Не удалось определить модель вашего лота или есть неуточнённая продажа. Откройте табличку машины либо вкладку «Сделки».')
        else
            imgui.TextDisabled('Объявления выбранного сервера')
            imgui.TextWrapped('Выберите машину в списке слева, чтобы посмотреть цену и данные продавца.')
        end
        imgui.EndChild()
    imgui.EndChild()
    imgui.TextDisabled('Лоты игроков ABarz · при потере связи объявление хранится до 5 минут.')
end

local function drawMarketplace()
    imgui.PushStyleVarVec2(imgui.StyleVar.ItemSpacing,imgui.ImVec2(10,4))
    imgui.PushStyleColor(imgui.Col.ChildBg,imgui.ImVec4(0.055,0.064,0.085,1))
    imgui.PushStyleColor(imgui.Col.FrameBg,imgui.ImVec4(0.11,0.13,0.16,1))
    imgui.PushStyleColor(imgui.Col.Button,imgui.ImVec4(0.12,0.14,0.18,1))
    imgui.PushStyleColor(imgui.Col.TextDisabled,imgui.ImVec4(0.61,0.65,0.72,1))
    imgui.BeginChild('##marketWorkspace',imgui.ImVec2(-1,-1),false)
    imgui.SetCursorPos(imgui.ImVec2(16,14))
    imgui.PushStyleColor(imgui.Col.ChildBg,imgui.ImVec4(0,0,0,0))
    imgui.BeginChild('##marketWorkspaceBody',imgui.ImVec2(-16,-14),false)
        drawMarketplaceContent()
    imgui.EndChild()
    imgui.PopStyleColor()
    imgui.EndChild()
    imgui.PopStyleColor(4)
    imgui.PopStyleVar()
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
    if scanState.isViceCity() then
        sectionTitle('Лоты Vice City')
        imgui.TextWrapped('Системных средних цен здесь нет. Ниже — найденные таблички продажи, а не история совершённых сделок.')
        imgui.SetNextItemWidth(-1)
        if imgui.InputTextWithHint('##vcSearch','Модель или владелец...',searchBuf,64) then
            filter=ffi.string(searchBuf)
        end
        local offers=scanState.viceOffers(filter)
        imgui.TextDisabled(('Найдено лотов: %d. Пройдите по автосалону, чтобы получить таблички.'):format(#offers))
        spaced(0,8)
        imgui.BeginChild('##vcOffers',imgui.ImVec2(-1,WIN_H-235),false)
        for _,row in ipairs(offers) do
            imgui.PushIDStr(tostring(row.key or row.vice.number))
            imgui.Text(row.model)
            imgui.SameLine(350)
            imgui.TextColored(accent(),fmtMoney(row.price))
            local details=('Лот №%s · %s'):format(row.vice.number,row.owner or 'владелец неизвестен')
            if row.vice.mileage then details=details..(' · %s км'):format(row.vice.mileage) end
            imgui.TextDisabled(details)
            if row.vice.expires then imgui.TextDisabled(row.vice.expires) end
            imgui.Separator()
            imgui.PopID()
        end
        if #offers==0 then imgui.TextDisabled('Подходящих табличек пока нет.') end
        imgui.EndChild()
        return
    end
    if baseDetailsOpen and baseTab==1 and selectedName and prices[selectedName] then
        drawCarDetails(selectedName,prices[selectedName])
        return
    end
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
    if imgui.InputTextWithHint('##search', 'Поиск по названию машины...', searchBuf, 64) then
        filter = ffi.string(searchBuf)
    end
    spaced(0, 4)
    local rows = findPrices(filter)
    local listH = WIN_H - 224
    local leftW = imgui.GetContentRegionAvail().x
    if (not selectedName or not prices[selectedName]) and rows[1] then selectedName=rows[1].name end
    imgui.BeginChild('##left', imgui.ImVec2(leftW, listH), true)
        imgui.TextDisabled(('Машины  ·  %d'):format(#rows))
        spaced(0, 2)
        imgui.TextDisabled('Модель транспорта')
        imgui.SameLine(leftW*0.60)
        imgui.TextDisabled('Дней в базе')
        imgui.SameLine(leftW*0.77)
        imgui.TextDisabled('Средняя цена')
        imgui.Separator()
        if #rows == 0 then
            imgui.TextDisabled('Пока пусто — сначала скан')
        else
            for i, row in ipairs(rows) do
                imgui.PushIDStr('c' .. i)
                if imgui.Selectable(row.name, selectedName == row.name) then
                    selectedName = row.name
                    baseDetailsOpen=true
                end
                imgui.SameLine(leftW*0.60)
                imgui.TextDisabled(('%d/30'):format(math.min(row.days,30)))
                imgui.SameLine(leftW*0.77)
                imgui.TextColored(accent(),fmtMoney(row.price))
                imgui.PopID()
            end
        end
    imgui.EndChild()

end

local function drawScan()
    if scanState.isViceCity() then
        sectionTitle('Vice City')
        imgui.TextWrapped('На этом сервере нет системного раздела средних цен. Скрипт автоматически читает таблички в автосалоне и показывает их во вкладке «Цены».')
        return
    end
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
        imgui.Checkbox(scanState.isViceCity() and 'Цена лота в техпаспорте' or 'Средняя цена в техпаспорте', showPassportAvg)
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
        if scanState.isViceCity() then
            imgui.InputTextWithHint('##dealmodelvc', 'Модель транспорта', dealModelBuf, 64)
        else
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
        imgui.TextDisabled(scanState.isViceCity() and 'Введите модель и цену сделки в VC$.'
            or 'Модель — из базы средних цен. Если сделки нет в логе — внеси сюда.')

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
    marketplace = drawMarketplace,
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
    local interactive=win[0]
    if not interactive and chatOn[0] and scanState.mouseBindOn[0] then
        local vk=tonumber(scanState.mouseVk) or 0x12
        interactive=isKeyDown(vk) or (vk==0x12 and (isKeyDown(0xA4) or isKeyDown(0xA5)))
    end
    player.HideCursor=not interactive
    player.LockPlayer=false
    if interactive then
        rawImgui.DisableInput=false
        scanState.syncUiMouse(rawImgui.GetIO())
    end
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


-- Install the optional UI library once; this does not update the script itself.
function scanState.ensureNotifications()
    if ntfy and type(ntfy.show) == 'function' and type(ntfy.sale) == 'function' then return false end
    local function status(text)
        sampAddChatMessage('{5B8CFF}[ABarz] {FFFFFF}' .. d(text), -1)
    end
    local path = getWorkingDirectory() .. '\\lib\\notifications.lua'
    if doesFileExist(path) then
        status('Не удалось загрузить notifications.lua. Проверьте её зависимости в moonloader.log.')
        return false
    end
    status('Качаю библиотеку уведомлений, пожалуйста, подождите…')
    ensureDir(getWorkingDirectory() .. '\\lib')
    local okMoon, moon = pcall(require, 'moonloader')
    if not okMoon then okMoon, moon = pcall(require, 'lib.moonloader') end
    local ds = okMoon and moon.download_status
    if type(downloadUrlToFile) ~= 'function' or not ds then
        status('Не удалось скачать библиотеку уведомлений. Установите lib/notifications.lua вручную.')
        return false
    end
    local urls = {
        'https://raw.githubusercontent.com/andergr0ynd/autoabarz/main/lib/notifications.lua',
        'https://cdn.jsdelivr.net/gh/andergr0ynd/autoabarz@main/lib/notifications.lua',
    }
    local installed = false
    for i, url in ipairs(urls) do
        local part = path .. '.' .. tostring(os.time()) .. '.' .. tostring(math.random(100000,999999)) .. '.part'
        local job = {done=false, success=false}
        local started, err = pcall(downloadUrlToFile, url, part, function(_, state)
            if state == ds.STATUS_ENDDOWNLOADDATA or state == ds.STATUSEX_ENDDOWNLOAD then
                job.success, job.done = true, true
            elseif state == ds.STATUS_ERROR or state == ds.STATUSEX_ERROR then
                job.done = true
            end
        end)
        if not started then print('ABarz notifications download: ' .. tostring(err)) end
        local elapsed = 0
        while started and not job.done and elapsed < 25000 do
            wait(50)
            elapsed = elapsed + 50
        end
        if job.success then
            local f = io.open(part, 'rb')
            local body = f and f:read('*a') or ''
            if f then f:close() end
            local compiled = loadfile(part)
            if compiled and #body > 1000 and body:find('return notifications',1,true) then
                -- Another instance may have installed it while this request was running.
                installed = doesFileExist(path) or os.rename(part, path) ~= nil
            end
        end
        pcall(os.remove, part)
        if installed then break end
    end
    if not installed then
        status('Не удалось скачать библиотеку уведомлений. Установите lib/notifications.lua вручную.')
        return false
    end
    status('Библиотека уведомлений установлена. Перезапускаю скрипт…')
    -- Register notification fonts before mimgui initializes on the next load.
    wait(300)
    thisScript():reload()
    return true
end

function scanState.syncMarket()
    if type(sampGetCurrentServerAddress) ~= 'function' then return end
    local ok, ip = pcall(sampGetCurrentServerAddress)
    if not ok or not ip or ip == '' or ip == '0.0.0.0' then return end
    if os.clock() < (scanState.marketCheckAt or 0) then return end
    scanState.marketCheckAt = os.clock() + 1
    local profile = scanState.isViceCity() and 'vice' or 'arizona'
    if not scanState.marketProfile then scanState.marketProfile=profile; return end
    if scanState.marketProfile == profile then return end
    saveDealLogs()
    scanState.marketProfile = profile
    pendingBuy.reset()
    pendingSell.details = {}
    scanState.manualConfirmation = nil
    scanState.active, scanState.wantScan = false, false
    passportJob.patch, passportJob.model = nil, nil
    knownPlates, PLATES = {}, {}
    loadDealLogs(false)
    forgetListed()
end

local CMDS = { 'abarz', 'abscan', 'abchat', 'abprice', 'carprice', 'abupdate' }

local function unregisterCmds()
    for _, name in ipairs(CMDS) do
        pcall(sampUnregisterChatCommand, name)
    end
end

function main()
    if not scanState.acquireInstance() then
        print('AutoABarz: duplicate script copy disabled; keep only one ABarz file in moonloader.')
        thisScript():unload()
        return
    end
    while not isSampAvailable() do wait(0) end
    if scanState.ensureNotifications() then return end
    if scanState.ensureEventsLib() then return end
    scanState.loadArizonaEvents()
    loadPrices()
    -- Restore own listings only after a quick reload in the same connected game process.
    -- Disconnect handlers clear them; a fresh game/server/player identity never reuses them.
    scanState.marketProfile = scanState.isViceCity() and 'vice' or 'arizona'
    loadDealLogs('session')
    pcall(scanState.loadSettings)
    pcall(scanState.cloud.load)
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
        if scanState.isViceCity() then
            chat('На Vice City нет системных средних цен. Лоты и их цены доступны в /abarz → Цены.', 'info')
            return
        end
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
        pcall(scanState.syncPrices)
        pcall(scanState.syncMarket)
        if scanState.wantScan then
            scanState.wantScan = false
            startScan()
        end
        pcall(scanState.pumpHttpJobs)
        pcall(scanState.cloud.pump)
        pcall(scanState.pumpLogo)
        pcall(drainHttpCbQueue)
        pcall(pumpSales)
        pcall(scanState.marketplace.pump)
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
        if scanState.duplicateInstance then return end
        pcall(scanState.marketplace.close)
        chatOn[0] = false
        unregisterCmds()
        stopSaleWatch()
        pcall(scanState.mark.release)
        rebuildList()
        if scanState.pricesDirty then savePrices() end
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
        pcall(scanState.releaseInstance)
    end
end
