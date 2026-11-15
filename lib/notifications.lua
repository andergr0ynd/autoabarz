--[[
    notifications.lua 2.3
    Toast + sale stack for MoonLoader / mimgui
]]

local imgui = require 'mimgui'
local encoding = require 'encoding'
encoding.default = 'CP1251'
local u8 = encoding.UTF8

local ok_fa, faicons = pcall(require, 'fAwesome6')
if not ok_fa then
    faicons = setmetatable({}, {
        __call = function() return '*' end,
        __index = {
            min_range = 0xf000, max_range = 0xf299,
            get_font_data_base85 = function() return nil end,
        }
    })
end

local ok_ini, inicfg = pcall(require, 'inicfg')

local notifications_list = {}
local sale_stack = {}
local inbox_open = false
local inbox_alpha = 0

local saved_positions = { positions = {} }
if ok_ini and inicfg then
    local ok_load, data = pcall(inicfg.load, { positions = {} }, 'notification_positions.ini')
    if ok_load and type(data) == 'table' then
        saved_positions = data
        saved_positions.positions = {}
        pcall(inicfg.save, saved_positions, 'notification_positions.ini')
    end
end

local settings = {
    max_notifications = 5,
    default_duration = 8000,
    fade_in_time = 300,
    fade_out_time = 300,
    position = 'bottom_left',
    movable = false,
    sale_window = 120,
    sale_threshold = 3,
    toast_width = 360,
    inbox_width = 380,
    gap = 12,
    margin = 18,
    close_vk = 0x12, -- Alt
}

local pending_inbox_clear = false

local TYPE_COLOR = {
    success = { 0.45, 0.85, 0.42, 1 },
    error   = { 0.89, 0.36, 0.42, 1 },
    warning = { 0.88, 0.64, 0.29, 1 },
    info    = { 0.36, 0.58, 1.00, 1 },
    debug   = { 0.60, 0.63, 0.70, 1 },
}

local TYPE_ICON = {
    success = 'check',
    error = 'xmark',
    warning = 'exclamation',
    info = 'info',
    debug = 'gear',
}

local TYPE_TITLE = {
    success = 'Успех',
    error = 'Ошибка',
    warning = 'Предупреждение',
    info = 'Инфо',
    debug = 'Debug',
}

local L = {
    inbox_title = 'Новые продажи',
    read_all = 'Прочитать все',
    dismiss = 'Свернуть',
    avg = 'средняя',
    cheaper = 'дешевле',
    left = 'ещё',
    sale_prefix = 'Новая продажа:',
    for_word = 'за',
    no_avg = 'средняя неизвестна',
    tt = 'ТТ',
    no_tt = 'Без ТТ',
    alt_hint = 'Alt — прочитать все',
}

local drag_offset = { x = 0, y = 0 }
local last_save_time = 0
local save_delay = 0.5
local font_ready = false
local icon_textures = {}
local close_held = false

local function close_key_down()
    local vk = tonumber(settings.close_vk) or 0x12
    local down = false
    pcall(function()
        if isKeyDown(vk) then down = true end
        if vk == 0x12 and (isKeyDown(0xA4) or isKeyDown(0xA5)) then down = true end
    end)
    return down
end

local function just_close_key()
    local down = close_key_down()
    local pressed = down and not close_held
    close_held = down
    return pressed
end

local function fmt_money(n)
    n = math.floor(tonumber(n) or 0)
    local s = tostring(math.abs(n))
    local out = s:reverse():gsub('(%d%d%d)', '%1.'):reverse():gsub('^%.', '')
    if n < 0 then return '-$' .. out end
    return '$' .. out
end

local function save_positions()
    if not (ok_ini and inicfg) then return end
    local positions_to_save = {}
    for i, notification in ipairs(notifications_list) do
        if notification.custom_x and notification.custom_y then
            positions_to_save[tostring(i)] = {
                x = notification.custom_x,
                y = notification.custom_y
            }
        end
    end
    saved_positions.positions = positions_to_save
    pcall(inicfg.save, saved_positions, 'notification_positions.ini')
end

local function measure_toast_height(notification)
    local width = tonumber(settings.toast_width) or 360
    local text_width = width - 28
    local ok, text_size = pcall(imgui.CalcTextSize, notification.text, nil, true, text_width)
    local text_h = (ok and text_size and text_size.y) or 16
    -- title/chip ~34px, text, gap + progress bar
    return math.max(58, text_h + (notification.icon_path and 58 or 48))
end

local function measure_inbox_height()
    if #sale_stack == 0 then return 0 end
    if not inbox_open and inbox_alpha <= 0.01 then return 0 end
    return math.min(340, 88 + #sale_stack * 50)
end

local function stack_anchor_x(screen_w, width)
    local margin = tonumber(settings.margin) or 18
    local pos = settings.position or 'bottom_left'
    if pos == 'top_right' or pos == 'bottom_right' then
        return screen_w - width - margin
    elseif pos == 'center' then
        return screen_w / 2 - width / 2
    end
    return margin
end

-- Считает Y так, чтобы карточки не пересекались: снизу вверх или сверху вниз.
local function layout_positions(screen_w, screen_h)
    local gap = tonumber(settings.gap) or 10
    local margin = tonumber(settings.margin) or 18
    local pos = settings.position or 'bottom_left'
    local from_bottom = (pos == 'bottom_left' or pos == 'bottom_right')
    local toast_w = tonumber(settings.toast_width) or 360
    local inbox_w = tonumber(settings.inbox_width) or 380
    local inbox_h = measure_inbox_height()

    local items = {}
    if inbox_h > 0 and (inbox_open or inbox_alpha > 0.01) then
        items[#items + 1] = { kind = 'inbox', w = inbox_w, h = inbox_h }
    end
    for i = 1, #notifications_list do
        local n = notifications_list[i]
        local h = measure_toast_height(n)
        n._h = h
        items[#items + 1] = { kind = 'toast', index = i, note = n, w = toast_w, h = h }
    end

    local cursor
    if from_bottom then
        cursor = screen_h - margin
        for i = 1, #items do
            local it = items[i]
            cursor = cursor - it.h
            it.x = stack_anchor_x(screen_w, it.w)
            it.y = cursor
            cursor = cursor - gap
        end
    else
        cursor = margin
        for i = 1, #items do
            local it = items[i]
            it.x = stack_anchor_x(screen_w, it.w)
            it.y = cursor
            cursor = cursor + it.h + gap
        end
    end

    local toast_pos, inbox_pos = {}, nil
    for i = 1, #items do
        local it = items[i]
        if it.kind == 'inbox' then
            inbox_pos = it
        else
            toast_pos[it.index] = it
        end
    end
    return toast_pos, inbox_pos
end

local function draw_shadow(dl, x, y, w, h, a)
    local shade = imgui.ColorConvertFloat4ToU32(imgui.ImVec4(0, 0, 0, 0.22 * a))
    dl:AddRectFilled(imgui.ImVec2(x + 3, y + 4), imgui.ImVec2(x + w + 3, y + h + 4), shade, 12)
end

local function animate_alpha(notification, current_time)
    local elapsed = current_time - notification.start_time
    local fade_in_duration = settings.fade_in_time / 1000
    local fade_out_duration = settings.fade_out_time / 1000
    local total_duration = notification.duration / 1000
    if elapsed < fade_in_duration then
        notification.alpha = elapsed / fade_in_duration
    elseif elapsed > total_duration - fade_out_duration then
        notification.alpha = math.max(0, (total_duration - elapsed) / fade_out_duration)
    else
        notification.alpha = 1.0
    end
    return notification.alpha
end

local function create_notification(text, ntype, duration, custom_colors, kind)
    ntype = ntype or 'info'
    local notification = {
        id = os.clock() + math.random(),
        text = tostring(text or ''),
        type = ntype,
        kind = kind or 'plain',
        duration = duration or settings.default_duration,
        start_time = os.clock(),
        alpha = 0,
        colors = custom_colors or TYPE_COLOR[ntype] or TYPE_COLOR.info,
        icon = TYPE_ICON[ntype] or 'info',
        title = TYPE_TITLE[ntype] or TYPE_TITLE.info,
        custom_x = nil,
        custom_y = nil,
        is_dragging = false,
    }
    table.insert(notifications_list, notification)
    while #notifications_list > settings.max_notifications do
        table.remove(notifications_list, 1)
    end
    return notification
end

local function clear_sale_toasts()
    for i = #notifications_list, 1, -1 do
        if notifications_list[i].kind == 'sale' then
            table.remove(notifications_list, i)
        end
    end
end

local function prune_sales(now)
    local window = tonumber(settings.sale_window) or 120
    local cutoff = now - window
    local changed = false
    for i = #sale_stack, 1, -1 do
        if (sale_stack[i].at or 0) < cutoff then
            table.remove(sale_stack, i)
            changed = true
        end
    end
    if #sale_stack == 0 then
        inbox_open = false
    elseif changed and #sale_stack < (tonumber(settings.sale_threshold) or 3) then
        inbox_open = false
    end
end

local function open_inbox()
    inbox_open = true
    clear_sale_toasts()
end

local function close_inbox(clear_items)
    inbox_open = false
    if clear_items then
        pending_inbox_clear = true
    end
end

local function finish_inbox_clear()
    if pending_inbox_clear and not inbox_open and inbox_alpha <= 0.01 then
        sale_stack = {}
        pending_inbox_clear = false
    end
end

local function sale_line(item)
    if item.text and item.text ~= '' then
        return item.text
    end
    local model = tostring(item.model or '?')
    local price = fmt_money(item.price)
    local tt = (tostring(item.turbo or '') == 'Twin Turbo') and L.tt or L.no_tt
    local avg = tonumber(item.avg)
    if not avg then
        return ('%s %s %s %s | %s | %s'):format(L.sale_prefix, model, L.for_word, price, L.no_avg, tt)
    end
    return ('%s %s %s %s | %s %s | %s'):format(
        L.sale_prefix, model, L.for_word, price, L.avg, fmt_money(avg), tt)
end

local function push_sale(item)
    item = type(item) == 'table' and item or { text = tostring(item) }
    local now = os.clock()
    prune_sales(now)
    item.at = now
    item.model = tostring(item.model or item.name or '?')
    item.price = tonumber(item.price) or 0
    item.avg = tonumber(item.avg)
    item.turbo = item.turbo or ''
    item.text = sale_line(item)
    sale_stack[#sale_stack + 1] = item

    local threshold = tonumber(settings.sale_threshold) or 3
    if #sale_stack >= threshold then
        open_inbox()
    else
        local note = create_notification(item.text, 'info', settings.default_duration, nil, 'sale')
        note.title = item.title or note.title
        note.icon_path = item.icon_path
        note.icon_uv = item.icon_uv
    end
    return true
end

local function draw_toast(notification, index, pos)
    local width = tonumber(settings.toast_width) or 360
    local height = notification._h or measure_toast_height(notification)
    local x = (pos and pos.x) or 18
    local y = (pos and pos.y) or 18
    -- лёгкий выезд при появлении
    local a = notification.alpha or 1
    local slide = (1 - a) * 10
    if (settings.position or ''):find('bottom', 1, true) then
        y = y + slide
    else
        y = y - slide
    end

    local col = notification.colors
    local r, g, b = col[1] or 0.36, col[2] or 0.58, col[3] or 1

    imgui.SetNextWindowPos(imgui.ImVec2(x, y), imgui.Cond.Always, imgui.ImVec2(0, 0))
    imgui.SetNextWindowSize(imgui.ImVec2(width, height), imgui.Cond.Always)
    imgui.PushStyleVarFloat(imgui.StyleVar.Alpha, a)
    imgui.PushStyleVarFloat(imgui.StyleVar.WindowRounding, 10)
    imgui.PushStyleVarFloat(imgui.StyleVar.WindowBorderSize, 0)
    imgui.PushStyleColor(imgui.Col.WindowBg, imgui.ImVec4(0.07, 0.08, 0.11, 0.96))
    imgui.PushStyleColor(imgui.Col.Border, imgui.ImVec4(0, 0, 0, 0))

    local flags = imgui.WindowFlags.NoTitleBar
        + imgui.WindowFlags.NoResize
        + imgui.WindowFlags.NoScrollbar
        + imgui.WindowFlags.NoFocusOnAppearing
        + imgui.WindowFlags.NoBringToFrontOnFocus
        + imgui.WindowFlags.NoCollapse
        + imgui.WindowFlags.NoInputs
        + imgui.WindowFlags.NoMove

    imgui.Begin('##ntfy' .. tostring(notification.id), nil, flags)

    local dl = imgui.GetWindowDrawList()
    local min = imgui.GetWindowPos()
    draw_shadow(dl, min.x, min.y, width, height, a)
    dl:AddRectFilled(min, imgui.ImVec2(min.x + width, min.y + height), imgui.ColorConvertFloat4ToU32(imgui.ImVec4(0.07, 0.08, 0.11, 0.96 * a)), 10)
    dl:AddRect(min, imgui.ImVec2(min.x + width, min.y + height), imgui.ColorConvertFloat4ToU32(imgui.ImVec4(1, 1, 1, 0.06 * a)), 10, 0, 1)
    dl:AddRectFilled(min, imgui.ImVec2(min.x + 4, min.y + height), imgui.ColorConvertFloat4ToU32(imgui.ImVec4(r, g, b, a)), 2)

    -- icon chip
    local texture
    if notification.icon_path then
        if icon_textures[notification.icon_path] == nil then
            local ok, tex = pcall(imgui.CreateTextureFromFile, notification.icon_path)
            icon_textures[notification.icon_path] = (ok and tex) or false
        end
        texture = icon_textures[notification.icon_path]
    end
    if texture then
        imgui.SetCursorPos(imgui.ImVec2(12, 10))
        local uv = notification.icon_uv or {0, 0, 1, 1}
        imgui.Image(texture, imgui.ImVec2(80, 23),
            imgui.ImVec2(uv[1], uv[2]), imgui.ImVec2(uv[3], uv[4]))
    else
        dl:AddRectFilled(imgui.ImVec2(min.x + 12, min.y + 10), imgui.ImVec2(min.x + 34, min.y + 32), imgui.ColorConvertFloat4ToU32(imgui.ImVec4(r, g, b, 0.16 * a)), 6)
        imgui.SetCursorPos(imgui.ImVec2(17, 13))
        imgui.TextColored(imgui.ImVec4(r, g, b, a), faicons(notification.icon))
    end
    if not texture then
        imgui.SetCursorPos(imgui.ImVec2(42, 12))
        imgui.TextColored(imgui.ImVec4(r, g, b, a), notification.title)
    end

    imgui.SetCursorPos(imgui.ImVec2(14, notification.icon_path and 44 or 34))
    imgui.PushTextWrapPos(width - 14)
    imgui.TextColored(imgui.ImVec4(0.92, 0.94, 0.97, a), notification.text)
    imgui.PopTextWrapPos()

    local elapsed = os.clock() - notification.start_time
    local progress = 1 - (elapsed / (notification.duration / 1000))
    if progress < 0 then progress = 0 end
    local bar_y = min.y + height - 5
    dl:AddRectFilled(imgui.ImVec2(min.x + 12, bar_y), imgui.ImVec2(min.x + width - 12, bar_y + 2), imgui.ColorConvertFloat4ToU32(imgui.ImVec4(1, 1, 1, 0.05 * a)), 2)
    dl:AddRectFilled(imgui.ImVec2(min.x + 12, bar_y), imgui.ImVec2(min.x + 12 + (width - 24) * progress, bar_y + 2), imgui.ColorConvertFloat4ToU32(imgui.ImVec4(r, g, b, 0.9 * a)), 2)

    imgui.End()
    imgui.PopStyleColor(2)
    imgui.PopStyleVar(3)
end

local function draw_inbox(pos)
    if not inbox_open and inbox_alpha <= 0.01 then return end
    if inbox_open then
        inbox_alpha = math.min(1, inbox_alpha + 0.14)
    else
        inbox_alpha = math.max(0, inbox_alpha - 0.14)
    end
    if #sale_stack == 0 then
        inbox_open = false
        return
    end
    if not pos then return end

    local width = pos.w or (tonumber(settings.inbox_width) or 380)
    local height = pos.h or measure_inbox_height()
    local x, y = pos.x, pos.y
    local slide = (1 - inbox_alpha) * 10
    if (settings.position or ''):find('bottom', 1, true) then
        y = y + slide
    else
        y = y - slide
    end

    imgui.SetNextWindowPos(imgui.ImVec2(x, y), imgui.Cond.Always, imgui.ImVec2(0, 0))
    imgui.SetNextWindowSize(imgui.ImVec2(width, height), imgui.Cond.Always)
    imgui.PushStyleVarFloat(imgui.StyleVar.Alpha, inbox_alpha)
    imgui.PushStyleVarFloat(imgui.StyleVar.WindowRounding, 12)
    imgui.PushStyleVarFloat(imgui.StyleVar.WindowBorderSize, 0)
    imgui.PushStyleColor(imgui.Col.WindowBg, imgui.ImVec4(0.07, 0.08, 0.11, 0.97))
    imgui.PushStyleColor(imgui.Col.Border, imgui.ImVec4(0, 0, 0, 0))

    local flags = imgui.WindowFlags.NoTitleBar
        + imgui.WindowFlags.NoResize
        + imgui.WindowFlags.NoCollapse
        + imgui.WindowFlags.NoMove
        + imgui.WindowFlags.NoFocusOnAppearing
        + imgui.WindowFlags.NoInputs

    imgui.Begin('##ntfy_inbox', nil, flags)
    local dl = imgui.GetWindowDrawList()
    local min = imgui.GetWindowPos()
    local a = inbox_alpha
    draw_shadow(dl, min.x, min.y, width, height, a)
    dl:AddRectFilled(min, imgui.ImVec2(min.x + width, min.y + height), imgui.ColorConvertFloat4ToU32(imgui.ImVec4(0.07, 0.08, 0.11, 0.97 * a)), 12)
    dl:AddRect(min, imgui.ImVec2(min.x + width, min.y + height), imgui.ColorConvertFloat4ToU32(imgui.ImVec4(1, 1, 1, 0.06 * a)), 12, 0, 1)
    dl:AddRectFilled(min, imgui.ImVec2(min.x + 4, min.y + height), imgui.ColorConvertFloat4ToU32(imgui.ImVec4(0.36, 0.58, 1.0, a)), 2)

    -- header
    imgui.SetCursorPos(imgui.ImVec2(14, 11))
    imgui.TextColored(imgui.ImVec4(0.94, 0.95, 0.97, 1), L.inbox_title)
    local count = tostring(#sale_stack)
    local ok_tsz, title_sz = pcall(imgui.CalcTextSize, L.inbox_title)
    local title_w = (ok_tsz and title_sz and title_sz.x) or 110
    local ok_csz, count_sz = pcall(imgui.CalcTextSize, count)
    local count_w = (ok_csz and count_sz and count_sz.x) or 10
    local badge_pad = 7
    local badge_w = count_w + badge_pad * 2
    local badge_x = min.x + 14 + title_w + 10
    dl:AddRectFilled(imgui.ImVec2(badge_x, min.y + 11), imgui.ImVec2(badge_x + badge_w, min.y + 29), imgui.ColorConvertFloat4ToU32(imgui.ImVec4(0.36, 0.58, 1.0, 0.2 * a)), 8)
    imgui.SetCursorPos(imgui.ImVec2(badge_x - min.x + badge_pad, 12))
    imgui.TextColored(imgui.ImVec4(0.36, 0.58, 1.0, 1), count)

    local oldest = sale_stack[1] and sale_stack[1].at or os.clock()
    local left = math.max(0, (oldest + (tonumber(settings.sale_window) or 120)) - os.clock())
    local mm = math.floor(left / 60)
    local ss = math.floor(left % 60)
    imgui.SetCursorPos(imgui.ImVec2(width - 72, 12))
    imgui.TextColored(imgui.ImVec4(0.54, 0.57, 0.63, 1), ('%s %d:%02d'):format(L.left, mm, ss))

    dl:AddLine(imgui.ImVec2(min.x + 12, min.y + 36), imgui.ImVec2(min.x + width - 12, min.y + 36), imgui.ColorConvertFloat4ToU32(imgui.ImVec4(1, 1, 1, 0.06 * a)), 1)

    imgui.SetCursorPos(imgui.ImVec2(10, 42))
    imgui.BeginChild('##ntfy_inbox_list', imgui.ImVec2(width - 20, height - 74), false)
    for i, item in ipairs(sale_stack) do
        imgui.PushIDInt(i)
        local row_min = imgui.GetCursorScreenPos()
        imgui.TextColored(imgui.ImVec4(0.94, 0.95, 0.97, 1), tostring(item.model or '?'))
        imgui.SameLine(width - 118)
        imgui.TextColored(imgui.ImVec4(0.36, 0.58, 1.0, 1), fmt_money(item.price))
        local avg = tonumber(item.avg)
        if avg then
            local gain = avg - (tonumber(item.price) or 0)
            local line = L.avg .. ' ' .. fmt_money(avg)
            if gain > 0 then
                local pct = math.floor(gain / avg * 100 + 0.5)
                line = line .. (' · %s %s (-%d)'):format(L.cheaper, fmt_money(gain), pct)
                imgui.TextColored(imgui.ImVec4(0.45, 0.85, 0.42, 1), line)
            else
                imgui.TextColored(imgui.ImVec4(0.54, 0.57, 0.63, 1), line)
            end
        else
            imgui.TextColored(imgui.ImVec4(0.54, 0.57, 0.63, 1), L.no_avg)
        end
        if tostring(item.turbo or '') == 'Twin Turbo' then
            imgui.SameLine()
            imgui.TextColored(imgui.ImVec4(1.0, 0.41, 0.71, 1), L.tt)
        end
        if i < #sale_stack then
            local sep = imgui.GetCursorScreenPos()
            dl:AddLine(imgui.ImVec2(row_min.x, sep.y + 2), imgui.ImVec2(row_min.x + width - 40, sep.y + 2), imgui.ColorConvertFloat4ToU32(imgui.ImVec4(1, 1, 1, 0.05 * a)), 1)
            imgui.Dummy(imgui.ImVec2(1, 6))
        end
        imgui.PopID()
    end
    imgui.EndChild()

    imgui.SetCursorPos(imgui.ImVec2(14, height - 24))
    imgui.TextColored(imgui.ImVec4(0.54, 0.57, 0.63, 1), L.alt_hint)

    imgui.End()
    imgui.PopStyleColor(2)
    imgui.PopStyleVar(3)
end

local notifications = {
    show = function(text, ntype, duration, custom_colors)
        return create_notification(text, ntype, duration, custom_colors, 'plain')
    end,
    success = function(text, duration, custom_colors)
        return create_notification(text, 'success', duration, custom_colors, 'plain')
    end,
    error = function(text, duration, custom_colors)
        return create_notification(text, 'error', duration, custom_colors, 'plain')
    end,
    warning = function(text, duration, custom_colors)
        return create_notification(text, 'warning', duration, custom_colors, 'plain')
    end,
    info = function(text, duration, custom_colors)
        return create_notification(text, 'info', duration, custom_colors, 'plain')
    end,
    debug = function(text, duration, custom_colors)
        return create_notification(text, 'debug', duration, custom_colors, 'plain')
    end,
    sale = function(item)
        return push_sale(item)
    end,
    clear = function()
        notifications_list = {}
        sale_stack = {}
        inbox_open = false
        inbox_alpha = 0
        pending_inbox_clear = false
    end,
    clear_sales = function()
        clear_sale_toasts()
        sale_stack = {}
        inbox_open = false
        inbox_alpha = 0
        pending_inbox_clear = false
    end,
    count = function()
        return #notifications_list
    end,
    sales_count = function()
        return #sale_stack
    end,
    reset_positions = function()
        saved_positions.positions = {}
        if ok_ini and inicfg then
            pcall(inicfg.save, saved_positions, 'notification_positions.ini')
        end
        for _, notification in ipairs(notifications_list) do
            notification.custom_x = nil
            notification.custom_y = nil
        end
    end,
    save_positions = function()
        save_positions()
    end,
    configure = function(new_settings)
        if type(new_settings) ~= 'table' then return end
        for key, value in pairs(new_settings) do
            settings[key] = value
        end
    end,
    set_interactive = function(interactive)
        settings.movable = not not interactive
    end,
    is_interactive = function()
        return settings.movable
    end,
}

pcall(function()
    imgui.OnInitialize(function()
        if type(faicons.get_font_data_base85) ~= 'function' then return end
        local data = faicons.get_font_data_base85('solid')
        if not data then return end
        local imgui_io = imgui.GetIO()
        local config = imgui.ImFontConfig()
        config.MergeMode = true
        config.PixelSnapH = true
        local iconRanges = imgui.new.ImWchar[3](faicons.min_range, faicons.max_range, 0)
        imgui_io.Fonts:AddFontFromMemoryCompressedBase85TTF(data, 16, config, iconRanges)
        font_ready = true
    end)
end)

pcall(function()
    imgui.OnFrame(
        function()
            return #notifications_list > 0 or inbox_open or inbox_alpha > 0.01
        end,
        function()
            local screen_w, screen_h = getScreenResolution()
            local current_time = os.clock()
            prune_sales(current_time)

            if just_close_key() and inbox_open then
                close_inbox(true)
            end

            for i = #notifications_list, 1, -1 do
                local notification = notifications_list[i]
                animate_alpha(notification, current_time)
                local elapsed = current_time - notification.start_time
                if elapsed > notification.duration / 1000 then
                    table.remove(notifications_list, i)
                end
            end

            local toast_pos, inbox_pos = layout_positions(screen_w, screen_h)
            for i = 1, #notifications_list do
                draw_toast(notifications_list[i], i, toast_pos[i])
            end
            draw_inbox(inbox_pos)
            finish_inbox_clear()
        end
    ).HideCursor = true
end)

return notifications
