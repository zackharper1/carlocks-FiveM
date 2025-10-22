-- server.lua
local USE_DB = false
local dbType = nil -- "oxmysql" or "ghmattimysql" or nil
local savedCache = {} -- in-memory cache for quick lookups (plate -> {owner, locked})

-- FILE fallback
local DATA_FILE = "saved_vehicles.json"

-- Try to detect DB export presence
if exports and exports.oxmysql and type(exports.oxmysql.execute) == "function" then
    USE_DB = true
    dbType = "oxmysql"
    print("[carlock] using oxmysql for persistence")
elseif exports and exports.ghmattimysql and type(exports.ghmattimysql.execute) == "function" then
    USE_DB = true
    dbType = "ghmattimysql"
    print("[carlock] using ghmattimysql for persistence")
else
    print("[carlock] no oxmysql/ghmattimysql found, falling back to JSON file persistence")
end

-- Utilities: get player's discord or fallback identifier
local function getPlayerIdentifier(src)
    local ids = GetPlayerIdentifiers(src)
    local discordId = nil
    for _, id in ipairs(ids) do
        if string.sub(id,1,8) == "discord:" then
            discordId = id
            break
        end
    end
    if not discordId then
        for _, id in ipairs(ids) do
            if string.sub(id,1,8) == "license:" or string.sub(id,1,6) == "steam:" then
                discordId = id
                break
            end
        end
    end
    return discordId -- may be nil if none found
end

-- DB helpers (async)
local function dbFetchVehicle(plate, cb)
    if not plate then cb(nil) return end
    if USE_DB and dbType == "oxmysql" then
        exports.oxmysql:execute('SELECT plate, owner_identifier, locked FROM carlock_vehicles WHERE plate = ?', {plate}, function(result)
            if result and result[1] then cb(result[1]) else cb(nil) end
        end)
    elseif USE_DB and dbType == "ghmattimysql" then
        exports.ghmattimysql:execute('SELECT plate, owner_identifier, locked FROM carlock_vehicles WHERE plate = ?', {plate}, function(result)
            if result and result[1] then cb(result[1]) else cb(nil) end
        end)
    else
        -- fallback JSON file
        local f = LoadResourceFile(GetCurrentResourceName(), DATA_FILE)
        if f and f ~= "" then
            local ok, dec = pcall(json.decode, f)
            if ok and type(dec) == "table" and dec[plate] then
                cb({ plate = plate, owner_identifier = dec[plate].owner_identifier, locked = dec[plate].locked and 1 or 0 })
                return
            end
        end
        cb(nil)
    end
end

local function dbSaveVehicle(plate, ownerIdentifier, locked, cb)
    if not plate or not ownerIdentifier then
        if cb then cb(false) end
        return
    end
    locked = locked and 1 or 0
    if USE_DB and dbType == "oxmysql" then
        exports.oxmysql:execute([[
            INSERT INTO carlock_vehicles (plate, owner_identifier, locked) VALUES (?, ?, ?)
            ON DUPLICATE KEY UPDATE owner_identifier = VALUES(owner_identifier), locked = VALUES(locked)
        ]], { plate, ownerIdentifier, locked }, function()
            if cb then cb(true) end
        end)
    elseif USE_DB and dbType == "ghmattimysql" then
        exports.ghmattimysql.execute([[
            INSERT INTO carlock_vehicles (plate, owner_identifier, locked) VALUES (?, ?, ?)
            ON DUPLICATE KEY UPDATE owner_identifier = VALUES(owner_identifier), locked = VALUES(locked)
        ]], { plate, ownerIdentifier, locked }, function()
            if cb then cb(true) end
        end)
    else
        -- file fallback
        local f = LoadResourceFile(GetCurrentResourceName(), DATA_FILE)
        local data = {}
        if f and f ~= "" then
            local ok, dec = pcall(json.decode, f)
            if ok and type(dec) == "table" then data = dec end
        end
        data[plate] = { owner_identifier = ownerIdentifier, locked = (locked == 1) }
        local encoded = json.encode(data)
        SaveResourceFile(GetCurrentResourceName(), DATA_FILE, encoded, -1)
        if cb then cb(true) end
    end
end

-- simple in-memory cache refresh (not required but speeds up checks)
local function refreshCacheForPlate(plate)
    dbFetchVehicle(plate, function(row)
        if row then
            savedCache[plate] = { owner = row.owner_identifier, locked = tonumber(row.locked) == 1 }
        else
            savedCache[plate] = nil
        end
    end)
end

-- When resource starts, optionally pre-load from DB/file to cache (not required, but helps)
AddEventHandler('onResourceStart', function(resourceName)
    if resourceName ~= GetCurrentResourceName() then return end
    print("[carlock] resource started, cache warmup")
    -- if using DB, you might choose to not load all rows (could be many). We'll keep lazy: only load on-demand.
end)

-- Server events

-- Save vehicle (called when player presses Save)
RegisterNetEvent("carlock:saveVehicle", function(plate)
    local src = source
    if not plate or plate == "" then
        TriggerClientEvent("carlock:notify", src, "Invalid plate.")
        return
    end
    local id = getPlayerIdentifier(src)
    if not id then
        TriggerClientEvent("carlock:notify", src, "No identifier available to save vehicle.")
        return
    end
    dbSaveVehicle(plate, id, 1, function(ok)
        if ok then
            savedCache[plate] = { owner = id, locked = true }
            TriggerClientEvent("carlock:notify", src, "Saved vehicle and locked it. Plate: " .. plate)
            -- broadcast to clients to ensure vehicle is locked if present
            TriggerClientEvent("carlock:setLockStateByPlate", -1, plate, true)
            print(("[carlock] %s saved plate %s"):format(id, plate))
        else
            TriggerClientEvent("carlock:notify", src, "Failed to save vehicle.")
        end
    end)
end)

-- Request toggle lock (server verifies ownership)
RegisterNetEvent("carlock:requestToggleLock", function(netVeh, plate)
    local src = source
    if not plate or plate == "" then
        TriggerClientEvent("carlock:notify", src, "No plate provided.")
        return
    end
    local id = getPlayerIdentifier(src)
    if not id then
        TriggerClientEvent("carlock:notify", src, "No identifier found.")
        return
    end

    -- first check cache
    local cached = savedCache[plate]
    if cached then
        if cached.owner ~= id then
            TriggerClientEvent("carlock:notify", src, "You don't own this vehicle.")
            return
        end
        -- toggle locked state
        local newLocked = not cached.locked
        savedCache[plate].locked = newLocked
        dbSaveVehicle(plate, id, newLocked, function(ok) end)
        -- broadcast to all clients to set lock for the network id (if vehicle exists) and plate (for those who have that vehicle)
        TriggerClientEvent("carlock:setLockStateNet", -1, netVeh, newLocked)
        TriggerClientEvent("carlock:notify", src, (newLocked and "Vehicle locked." or "Vehicle unlocked."))
        return
    end

    -- if not cached, fetch from DB
    dbFetchVehicle(plate, function(row)
        if row then
            if row.owner_identifier ~= id then
                TriggerClientEvent("carlock:notify", src, "You don't own this vehicle.")
                return
            end
            local newLocked = (tonumber(row.locked) == 0)
            dbSaveVehicle(plate, id, newLocked, function(ok) end)
            savedCache[plate] = { owner = id, locked = newLocked }
            TriggerClientEvent("carlock:setLockStateNet", -1, netVeh, newLocked)
            TriggerClientEvent("carlock:notify", src, (newLocked and "Vehicle locked." or "Vehicle unlocked."))
        else
            TriggerClientEvent("carlock:notify", src, "This vehicle is not saved (use the save key).")
        end
    end)
end)

-- Lockpick attempt (server-side: check rules and broadcast result)
-- clients call: TriggerServerEvent("carlock:attemptLockpick", plate, netVeh)
RegisterNetEvent("carlock:attemptLockpick", function(plate, netVeh)
    local src = source
    local id = getPlayerIdentifier(src)
    if not plate or plate == "" then
        TriggerClientEvent("carlock:notify", src, "Invalid vehicle.")
        return
    end
    -- load vehicle owner
    dbFetchVehicle(plate, function(row)
        -- if there's no owner or owner differs, allow lockpick attempt (owner can still be victim)
        -- You might want to block lockpicking for very recent saves or certain perms; adjust here.
        local isOwned = row ~= nil
        -- If owned and owner is the same as player, lockpick should be denied
        if isOwned and row.owner_identifier == id then
            TriggerClientEvent("carlock:notify", src, "You already own this vehicle.")
            return
        end

        -- success chance (tweakable)
        local baseChance = 40 -- percent
        if not isOwned then baseChance = 70 end -- easier if not owned
        -- you can add modifiers here (tools, skill levels, server settings)

        local success = (math.random(1,100) <= baseChance)
        if success then
            -- broadcast unlock to all clients for that netVeh (if present)
            TriggerClientEvent("carlock:setLockStateNet", -1, netVeh, false)
            TriggerClientEvent("carlock:notify", src, "Lockpick successful.")
            print(("[carlock] %s successfully lockpicked plate %s"):format(tostring(id), plate))
        else
            -- failure effects: break tool, alert owner, etc. For now just notify and maybe add a cooldown
            TriggerClientEvent("carlock:notify", src, "Lockpick failed.")
            print(("[carlock] %s failed lockpick on plate %s"):format(tostring(id), plate))
        end
    end)
end)

-- Hotwire attempt (server-side)
-- clients call: TriggerServerEvent("carlock:attemptHotwire", plate, netVeh)
RegisterNetEvent("carlock:attemptHotwire", function(plate, netVeh)
    local src = source
    local id = getPlayerIdentifier(src)
    if not plate or plate == "" then
        TriggerClientEvent("carlock:notify", src, "Invalid vehicle.")
        return
    end
    dbFetchVehicle(plate, function(row)
        -- if owner matches player then no need to hotwire
        if row and row.owner_identifier == id then
            TriggerClientEvent("carlock:notify", src, "You already own this vehicle.")
            return
        end

        -- hotwire success chance lower than lockpick; takes longer
        local baseChance = 30
        if not row then baseChance = 50 end

        local success = (math.random(1,100) <= baseChance)
        if success then
            -- allow engine start: clients will set doors unlocked for everyone and allow engine
            TriggerClientEvent("carlock:setLockStateNet", -1, netVeh, false)
            TriggerClientEvent("carlock:notify", src, "Hotwire successful. Vehicle unlocked.")
            print(("[carlock] %s hotwired plate %s"):format(tostring(id), plate))
        else
            TriggerClientEvent("carlock:notify", src, "Hotwire failed.")
            print(("[carlock] %s failed hotwire on plate %s"):format(tostring(id), plate))
        end
    end)
end)

-- Optional admin console command to view saved entries
RegisterCommand("carlock_list", function(source, args)
    if source ~= 0 then
        TriggerClientEvent("carlock:notify", source, "Console only.")
        return
    end
    print("---- carlock saved vehicles ----")
    if USE_DB then
        local q = "SELECT plate, owner_identifier, locked FROM carlock_vehicles"
        if dbType == "oxmysql" then
            exports.oxmysql:execute(q, {}, function(rows)
                for _, r in ipairs(rows) do
                    print(("%s => %s (locked=%s)"):format(r.plate, r.owner_identifier, tostring(r.locked)))
                end
            end)
        else
            exports.ghmattimysql.execute(q, {}, function(rows)
                for _, r in ipairs(rows) do
                    print(("%s => %s (locked=%s)"):format(r.plate, r.owner_identifier, tostring(r.locked)))
                end
            end)
        end
    else
        local f = LoadResourceFile(GetCurrentResourceName(), DATA_FILE)
        if f and f ~= "" then
            local ok, dec = pcall(json.decode, f)
            if ok and type(dec) == "table" then
                for plate,v in pairs(dec) do
                    print(("%s => %s (locked=%s)"):format(plate, v.owner_identifier, tostring(v.locked)))
                end
            else
                print("No saved vehicles.")
            end
        else
            print("No saved vehicles.")
        end
    end
end, true)
