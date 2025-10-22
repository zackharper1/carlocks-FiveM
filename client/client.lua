-- client.lua
local savedPlate = nil
local savedNet = nil

local lastE = 0
local doubleTapWindow = 300 -- ms

-- Lockpick/hotwire settings
local LOCKPICK_DURATION = 6000 -- ms
local HOTWIRE_DURATION = 12000 -- ms

-- Simple notification (replace with your notify)
local function Notify(text)
    SetNotificationTextEntry('STRING')
    AddTextComponentString(text)
    DrawNotification(false, false)
end

RegisterNetEvent("carlock:notify")
AddEventHandler("carlock:notify", function(text) Notify(text) end)

-- Set lock state for a net vehicle (called by server broadcast)
RegisterNetEvent("carlock:setLockStateNet")
AddEventHandler("carlock:setLockStateNet", function(netVeh, locked)
    local veh = NetToVeh(netVeh)
    if not DoesEntityExist(veh) then return end
    if locked then
        SetVehicleDoorsLocked(veh, 2)
        SetVehicleDoorsLockedForAllPlayers(veh, true)
    else
        SetVehicleDoorsLocked(veh, 1)
        SetVehicleDoorsLockedForAllPlayers(veh, false)
    end
    -- small visual feedback
    SetVehicleIndicatorLights(veh, 0, true)
    SetVehicleIndicatorLights(veh, 1, true)
    Citizen.SetTimeout(200, function()
        SetVehicleIndicatorLights(veh, 0, false)
        SetVehicleIndicatorLights(veh, 1, false)
    end)
end)

-- Set lock state for vehicles by plate (useful if some players have the vehicle without same netid)
RegisterNetEvent("carlock:setLockStateByPlate")
AddEventHandler("carlock:setLockStateByPlate", function(plate, locked)
    if not plate then return end
    -- search nearby vehicles for matching plate and set lock
    local playerPed = PlayerPedId()
    local pPos = GetEntityCoords(playerPed)
    local found = false
    local handle, veh = FindFirstVehicle()
    if handle ~= -1 then
        local ok = true
        repeat
            if DoesEntityExist(veh) then
                local vplate = GetVehicleNumberPlateText(veh)
                if vplate and vplate == plate and #(pPos - GetEntityCoords(veh)) < 250.0 then
                    if locked then
                        SetVehicleDoorsLocked(veh, 2)
                        SetVehicleDoorsLockedForAllPlayers(veh, true)
                    else
                        SetVehicleDoorsLocked(veh, 1)
                        SetVehicleDoorsLockedForAllPlayers(veh, false)
                    end
                    found = true
                end
            end
            ok, veh = FindNextVehicle(handle)
        until not ok
        EndFindVehicle(handle)
    end
end)

-- Save vehicle locally + notify server
local function saveCurrentVehicle()
    local ped = PlayerPedId()
    if not IsPedInAnyVehicle(ped, false) then
        Notify("You must be in a vehicle to save it (press U).")
        return
    end
    local veh = GetVehiclePedIsIn(ped, false)
    local plate = GetVehicleNumberPlateText(veh) or ""
    if plate == "" then Notify("Plate not found.") return end
    savedPlate = plate
    savedNet = VehToNet(veh)
    -- notify server to persist and lock
    TriggerServerEvent("carlock:saveVehicle", plate)
end

-- Attempt toggle (double tap E)
local function tryToggleLock()
    local ped = PlayerPedId()
    local veh = nil
    local plate = nil
    local net = nil

    if IsPedInAnyVehicle(ped, false) then
        veh = GetVehiclePedIsIn(ped, false)
        plate = GetVehicleNumberPlateText(veh) or ""
        net = VehToNet(veh)
    else
        if savedNet and NetworkDoesNetworkIdExist(savedNet) then
            local v = NetToVeh(savedNet)
            if DoesEntityExist(v) then
                veh = v
                plate = GetVehicleNumberPlateText(veh) or ""
                net = savedNet
            end
        end
        -- fallback: try to find nearby vehicle with savedPlate
        if not veh and savedPlate then
            local pPos = GetEntityCoords(ped)
            local handle, candidate = FindFirstVehicle()
            if handle ~= -1 then
                local ok = true
                repeat
                    if DoesEntityExist(candidate) then
                        local cplate = GetVehicleNumberPlateText(candidate)
                        if cplate and cplate == savedPlate and #(pPos - GetEntityCoords(candidate)) < 10.0 then
                            veh = candidate
                            plate = cplate
                            net = VehToNet(candidate)
                            break
                        end
                    end
                    ok, candidate = FindNextVehicle(handle)
                until not ok
                EndFindVehicle(handle)
            end
        end
    end

    if not veh or not DoesEntityExist(veh) then
        Notify("No vehicle found to toggle.")
        return
    end
    if not plate or plate == "" then Notify("Vehicle plate unknown.") return end

    -- ask server to toggle (server authorizes)
    TriggerServerEvent("carlock:requestToggleLock", net, plate)
end

-- Lockpick attempt: plays simple progress and requests server to evaluate
local function attemptLockpick(veh)
    if not DoesEntityExist(veh) then return end
    local plate = GetVehicleNumberPlateText(veh) or ""
    if plate == "" then Notify("Cannot determine plate.") return end

    Notify("Attempting to lockpick... stay near the vehicle.")
    -- simple progress indicator (no external kbbar). Freeze player
    local ped = PlayerPedId()
    local start = GetGameTimer()
    local finished = false
    Citizen.CreateThread(function()
        FreezeEntityPosition(ped, true)
        -- you can play a lockpicking animation here
        while (GetGameTimer() - start) < LOCKPICK_DURATION do
            Citizen.Wait(200)
            -- optional: allow cancellation by moving too far
            if #(GetEntityCoords(ped) - GetEntityCoords(veh)) > 3.5 then
                Notify("You moved too far. Lockpick cancelled.")
                FreezeEntityPosition(ped, false)
                return
            end
        end
        FreezeEntityPosition(ped, false)
        -- ask server to compute success and broadcast change
        TriggerServerEvent("carlock:attemptLockpick", plate, VehToNet(veh))
    end)
end

-- Hotwire attempt: must be inside vehicle (driver seat) and engine off
local function attemptHotwire(veh)
    if not DoesEntityExist(veh) then return end
    local plate = GetVehicleNumberPlateText(veh) or ""
    if plate == "" then Notify("Cannot determine plate.") return end

    local ped = PlayerPedId()
    if GetPedInVehicleSeat(veh, -1) ~= ped then
        Notify("You must be in the driver seat to hotwire.")
        return
    end

    Notify("Attempting to hotwire... this may take a while.")
    local start = GetGameTimer()
    FreezeEntityPosition(ped, true)
    Citizen.CreateThread(function()
        while (GetGameTimer() - start) < HOTWIRE_DURATION do
            Citizen.Wait(250)
            if GetVehicleEngineHealth(veh) <= 0 then
                -- vehicle destroyed, cancel
                FreezeEntityPosition(ped, false)
                Notify("Vehicle is too damaged to hotwire.")
                return
            end
        end
        FreezeEntityPosition(ped, false)
        TriggerServerEvent("carlock:attemptHotwire", GetVehicleNumberPlateText(veh), VehToNet(veh))
    end)
end

-- Input detection + keys
Citizen.CreateThread(function()
    while true do
        Citizen.Wait(0)
        -- Save with U (303)
        if IsControlJustReleased(0, 303) then
            saveCurrentVehicle()
        end

        -- Double-tap E (38) to toggle lock (as requested)
        if IsControlJustReleased(0, 38) then
            local now = GetGameTimer()
            if now - lastE <= doubleTapWindow then
                tryToggleLock()
                lastE = 0
            else
                lastE = now
            end
        end

        -- Lockpick attempt: use INPUT_CONTEXT (E) while looking at locked vehicle but not owner
        -- We'll allow lockpick when player is near a locked vehicle and presses SHIFT+E (or another key). For simplicity: use Left Shift (21) + E (38)
        if IsControlJustPressed(0, 21) and IsControlJustReleased(0, 38) then
            -- find nearest vehicle in front
            local ped = PlayerPedId()
            local pPos = GetEntityCoords(ped)
            local forward = GetEntityForwardVector(ped)
            local rayFrom = pPos
            local rayTo = pPos + forward * 5.0
            local _, hit, endCoords, surfaceNormal, entityHit = GetShapeTestResult(StartShapeTestRay(rayFrom.x, rayFrom.y, rayFrom.z, rayTo.x, rayTo.y, rayTo.z, -1, ped, 0))
            local targetVeh = nil
            if entityHit and DoesEntityExist(entityHit) and IsEntityAVehicle(entityHit) then
                targetVeh = entityHit
            else
                -- fallback: find vehicle in a small radius
                local handle, veh = FindFirstVehicle()
                if handle ~= -1 then
                    local ok = true
                    repeat
                        if DoesEntityExist(veh) and #(pPos - GetEntityCoords(veh)) < 3.5 then
                            targetVeh = veh
                            break
                        end
                        ok, veh = FindNextVehicle(handle)
                    until not ok
                    EndFindVehicle(handle)
                end
            end
            if targetVeh then
                attemptLockpick(targetVeh)
            else
                Notify("No vehicle nearby to lockpick.")
            end
        end

        -- Hotwire attempt: press H (74) while in driver seat to hotwire
        if IsControlJustReleased(0, 74) then -- H
            local ped = PlayerPedId()
            if IsPedInAnyVehicle(ped, false) then
                local veh = GetVehiclePedIsIn(ped, false)
                attemptHotwire(veh)
            else
                Notify("You must be inside a vehicle to hotwire.")
            end
        end
    end
end)
