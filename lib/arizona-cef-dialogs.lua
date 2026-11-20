--[[
    arizona-cef-dialogs v1.0
    Author: XRLM
    Link: https://www.blast.hk/threads/255083/
]]

local M = {
    PREFIX = 'arizona-cef-dialogs',
    pending = {},
    requestsSeq = 0,
    lastDialogInfo = {
        id = -1,
        style = -1,
        title = '',
        button1 = '',
        button2 = '',
        text = ''
    },
    lastDialogRespond = {
        id = -1,
        button = -1,
        list = -1,
        input = '',
    }
}

local function escapePattern(text)
    return (tostring(text):gsub('%%', '%%%%'):gsub('([%^%$%(%)%.%[%]%*%+%-%?])', '%%%1'))
end

local function evalcef(code, encoded)
    encoded = encoded or 0
    local bs = raknetNewBitStream()
    raknetBitStreamWriteInt8(bs, 17)
    raknetBitStreamWriteInt32(bs, 0)
    raknetBitStreamWriteInt16(bs, #code)
    raknetBitStreamWriteInt8(bs, encoded)
    raknetBitStreamWriteString(bs, code)
    raknetEmulPacketReceiveBitStream(220, bs)
    raknetDeleteBitStream(bs)
end

local function evalanon(code)
    evalcef(("(() => {%s})()"):format(code))
end

addEventHandler('onSendPacket', function(id, bs)
    if id == 220 then
        raknetBitStreamIgnoreBits(bs, 8)
        local pType = raknetBitStreamReadInt8(bs)
        if pType == 18 then
            local len = raknetBitStreamReadInt16(bs)
            local text = raknetBitStreamReadString(bs, len)
            local prefix = escapePattern(M.PREFIX)
            if text:find('^' .. prefix .. '|(.+)$') then
                local json = text:match('^' .. prefix .. '|(.+)$')
                if json then
                    local ok, data = pcall(decodeJson, json)
                    if ok and data then
                        M.pending[tonumber(data.requestId)] = {
                            received = true,
                            value = data.value,
                        }
                    end
                end
                return false
            end
        end
    end
end)

addEventHandler('onReceiveRpc', function(id, bs)
    if id == 61 then
        local dialogId = raknetBitStreamReadInt16(bs)
        local style = raknetBitStreamReadInt8(bs)
        local title = raknetBitStreamReadString(bs, raknetBitStreamReadInt8(bs))
        local button1 = raknetBitStreamReadString(bs, raknetBitStreamReadInt8(bs))
        local button2 = raknetBitStreamReadString(bs, raknetBitStreamReadInt8(bs))
        local text = raknetBitStreamDecodeString(bs, 4096)
        M.lastDialogInfo = {
            id = dialogId,
            style = style,
            title = title,
            button1 = button1,
            button2 = button2,
            text = text
        }
    end
end)

addEventHandler('onSendRpc', function(id, bs)
    if id == 62 then
        local dialogId = raknetBitStreamReadInt16(bs)
        local button = raknetBitStreamReadInt8(bs)
        local list = raknetBitStreamReadInt16(bs)
        local input = raknetBitStreamReadString(bs, raknetBitStreamReadInt8(bs))
        M.lastDialogRespond = {
            id = dialogId,
            button = button,
            list = list,
            input = input
        }
    end
end)

function M.cefQuery(code, timeout)
    if type(code) ~= 'string' then return print('arizona-cef-dialogs: code is not a string') end
    timeout = timeout or 500

    M.requestsSeq = M.requestsSeq + 1
    local requestId = M.requestsSeq

    evalanon(([[
var value;
try { value = (function () { %s })(); } catch (e) { value = null; }
if (!window.cef) return;
var data = { requestId: %d, value: value };
window.cef.SendMessage('%s|' + JSON.stringify(data), 0);
]]):format(code, requestId, M.PREFIX))

    local deadline = os.clock() + timeout / 1000
    while not (M.pending[requestId] and M.pending[requestId].received) and os.clock() < deadline do wait(0) end

    local value = M.pending[requestId] and M.pending[requestId].value or nil
    M.pending[requestId] = nil
    return value
end

function M.cefQueryAsync(code, callback, timeout)
    if type(callback) ~= 'function' then return print('arizona-cef-dialogs: callback is not a function') end
    if type(code) ~= 'string' then return print('arizona-cef-dialogs: code is not a string') end
    timeout = timeout or 500

    M.requestsSeq = M.requestsSeq + 1
    local requestId = M.requestsSeq

    evalanon(([[
var value;
try { value = (function () { %s })(); } catch (e) { value = null; }
if (!window.cef) return;
var data = { requestId: %d, value: value };
window.cef.SendMessage('%s|' + JSON.stringify(data), 0);
]]):format(code, requestId, M.PREFIX))

    local started = os.clock()
    lua_thread.create(function()
        while not (M.pending[requestId] and M.pending[requestId].received) and os.clock() - started < timeout / 1000 do wait(0) end
        local value = M.pending[requestId] and M.pending[requestId].value or nil
        M.pending[requestId] = nil
        callback(value)
    end)
end

function M.SetInputText(text)
    evalanon(([[
var d = document.querySelector('.dialog');
if (!d) return;
var i = d.querySelector('input.dialog-input__field');
if (!i) return;
i.value = %q;
]]):format(tostring(text)))
end

function M.GetInputText(isAsync, callback, timeout)
    isAsync = isAsync or false
    timeout = timeout or 500

    local code = [[
var d = document.querySelector('.dialog');
if (!d) return null;
var i = d.querySelector('input.dialog-input__field');
return i ? i.value : null;
]]

    if isAsync then
        if type(callback) ~= 'function' then return print('arizona-cef-dialogs: callback is not a function') end
        M.cefQueryAsync(code, callback, timeout)
    else
        return M.cefQuery(code, timeout)
    end
end

function M.CloseWithButton(button) -- 1 - Enter, 0 - Escape
    button = button or 0
    evalanon(([[
var d = document.querySelector('.dialog');
if (!d) return;
if (%d) {
    var btn = d.querySelector('.dialog__button--primary:not(.dialog__button--disabled)');
    if (btn) { btn.click(); return; }
} else {
    var btn = d.querySelector('.dialog__button--secondary:not(.dialog__button--disabled)');
    if (btn) { btn.click(); return; }
    var close = d.querySelector('.dialog__header-close');
    if (close) { close.click(); return; }
    window.cef.doDialogResponse();
}
]]):format(button))
end

function M.SetListItem(index)
    index = index or 0

    evalanon(([[
var d = document.querySelector('.dialog');
if (!d) return;
var items = d.querySelectorAll('.dialog-list-loop__list-item');
var item = items[%d];
if (item) item.click();
]]):format(index))
end

function M.GetListItem(isAsync, callback, timeout)
    isAsync = isAsync or false
    timeout = timeout or 500

    local code = [[
var d = document.querySelector('.dialog');
if (!d) return 0;
var list = d.querySelector('.dialog-list-loop__list');
if (!list) return 0;
var items = list.querySelectorAll('.dialog-list-loop__list-item');
for (var i = 0; i < items.length; i++) {
    if (items[i].classList.contains('dialog-list-loop__list-item--active')) return i;
}
return 0;
]]

    if isAsync then
        if type(callback) ~= 'function' then return print('arizona-cef-dialogs: callback is not a function') end
        M.cefQueryAsync(code, callback, timeout)
    else
        return M.cefQuery(code, timeout)
    end
end

function M.IsDialogActive()
    return sampIsDialogActive()
end

function M.GetId()
    return M.lastDialogInfo.id
end

function M.GetDialogText()
    return M.lastDialogInfo.text
end

function M.GetStyle()
    return M.lastDialogInfo.style
end

function M.GetTitle()
    return M.lastDialogInfo.title
end

function M.GetButton1()
    return M.lastDialogInfo.button1
end

function M.GetButton2()
    return M.lastDialogInfo.button2
end

function M.GetRespond()
    return M.lastDialogRespond.id, M.lastDialogRespond.button, M.lastDialogRespond.list, M.lastDialogRespond.input
end

function M.Show(id, title, text, button1, button2, style)
    id = id or 0
    title = title or ''
    text = text or ''
    button1 = button1 or ''
    button2 = button2 or ''
    style = style or 0

    M.lastDialogInfo = {
        id = id,
        style = style,
        title = title,
        button1 = button1,
        button2 = button2,
        text = text
    }
    return sampShowDialog(id, title, text, button1, button2, style)
end

return M