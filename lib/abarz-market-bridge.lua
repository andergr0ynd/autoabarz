-- Local integration with ArzMarket 3.57. No credentials or direct HTTP requests.
local bridge={}
function bridge.snapshot(data,now)
    if type(data)~='table' or type(data.list)~='table' then return end
    local rows,seen,vc={},{},false
    for _,shop in ipairs(data.list) do
        if type(shop)=='table' and tonumber(shop.serverId)==0 then
            vc=true
            if type(shop.items_sell)=='table' and type(shop.price_sell)=='table' then
                for index,item in ipairs(shop.items_sell) do
                    local price=tonumber(shop.price_sell[index])
                    local count=type(shop.count_sell)=='table' and tonumber(shop.count_sell[index])
                    local name=tostring(item)
                    local shopId=tostring(shop.LavkaUid or '')
                    local key=shopId..'/'..name
                    if shopId~='' and not seen[key] and price and price==price and price>0 and price<1e12
                        and count and count>0 and #name<200 and #rows<10000 then
                        seen[key]=true
                        rows[#rows+1]={item=name,price=price,at=tonumber(shop.ostime) or now}
                    end
                end
            end
        end
    end
    if vc then return {version=1,source='ArzMarket-3.57',captured=now,rows=rows} end
end
function bridge.install()
    local original=decodeJson
    local dir=getWorkingDirectory()..'\\config\\abarz'
    local path=dir..'\\arzmarket-vc.json'
    local nextPoll=math.huge
    decodeJson=function(...)
        local data=original(...)
        -- A failed export must never interfere with the original decoder/callback.
        pcall(function()
            local snapshot=bridge.snapshot(data,os.time())
            if not snapshot then return end
            if not doesDirectoryExist(dir) then createDirectory(dir) end
            local encoded=encodeJson(snapshot)
            local f=io.open(path..'.tmp','wb')
            if not f then return end
            local ok=f:write(encoded); local closed=f:close()
            if not ok or not closed then return end
            os.remove(path..'.bak')
            local old=io.open(path,'rb')
            if old then old:close(); if not os.rename(path,path..'.bak') then return end end
            if not os.rename(path..'.tmp',path) then if old then os.rename(path..'.bak',path) end; return end
            nextPoll=os.time()+300
        end)
        return data
    end
    lua_thread.create(function()
        while true do
            wait(1000)
            if os.time()>=nextPoll and sampGetGamestate()==3 and type(marketplace_Manager)=='function' then
                nextPoll=os.time()+300
                -- Only repeat after a successful VC response, using ArzMarket's own selected server and auth.
                local hasVC=false
                if type(download_marketplace)=='table' then
                    for _,shop in ipairs(download_marketplace) do
                        if type(shop)=='table' and tonumber(shop.serverId)==0 then hasVC=true; break end
                    end
                end
                if hasVC then pcall(marketplace_Manager) end
            end
        end
    end)
end
return bridge
