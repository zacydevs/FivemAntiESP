local AddEventHandler <const> = AddEventHandler
local CreateThread <const> = CreateThread
local DoesEntityExist <const> = DoesEntityExist
local GetCurrentResourceName <const> = GetCurrentResourceName
local GetEntityCoords <const> = GetEntityCoords
local GetGameTimer <const> = GetGameTimer
local GetPlayerName <const> = GetPlayerName
local GetPlayerPed <const> = GetPlayerPed
local GetPlayerRoutingBucket <const> = GetPlayerRoutingBucket
local RegisterNetEvent <const> = RegisterNetEvent
local TriggerClientEvent <const> = TriggerClientEvent
local Wait <const> = Wait
local ipairs <const> = ipairs
local pairs <const> = pairs
local type <const> = type
local tonumber <const> = tonumber
local next <const> = next
local rawget <const> = rawget

local config <const> = rawget(Config, 'AntiWallhack')
local configEnabled <const> = rawget(config, 'enabled')
local configMaxDistance <const> = rawget(config, 'maxDistance')
local configMaxTargets <const> = rawget(config, 'maxTargets')
local configMaxPositionRequestsPerSecond <const> = rawget(config, 'maxPositionRequestsPerSecond')
local configReciprocalVisibility <const> = rawget(config, 'reciprocalVisibility')
local configMaxReportsPerSecond <const> = rawget(config, 'maxReportsPerSecond')
local configLeaseMs <const> = rawget(config, 'leaseMs')

if not configEnabled then
    return
end

local positionLimits = {}
local viewers = {}
local reportLimits = {}
local reverse = {}
local dirty = {}

local function playerInfo(id)
    if not GetPlayerName(id) then
        return nil
    end

    local ped = GetPlayerPed(id)

    if ped == 0 or not DoesEntityExist(ped) then
        return nil
    end

    return {
        pos = GetEntityCoords(ped),
        bucket = GetPlayerRoutingBucket(id),
    }
end

local function nearby(a, b)
    if not a or not b or a.bucket ~= b.bucket then
        return false
    end

    local x = a.pos.x - b.pos.x
    local y = a.pos.y - b.pos.y
    local z = a.pos.z - b.pos.z

    return x * x + y * y + z * z <= configMaxDistance * configMaxDistance
end

local function allowRequest(limits, sender, now, maximum)
    local limit = limits[sender]

    if not limit or now < limit.start or now - limit.start >= 1000 then
        limit = {
            start = now,
            count = 0,
        }
        limits[sender] = limit
    end

    limit.count = limit.count + 1

    return limit.count <= maximum
end

local function validIds(ids)
    if type(ids) ~= 'table' then
        return false
    end

    local count = 0

    for key, id in pairs(ids) do
        count = count + 1

        if
            count > configMaxTargets
            or type(key) ~= 'number'
            or key % 1 ~= 0
            or key < 1
            or key > configMaxTargets
            or type(id) ~= 'number'
            or id % 1 ~= 0
            or id < 1
            or id > 65535
        then
            return false
        end
    end

    for index = 1, count do
        if ids[index] == nil then
            return false
        end
    end

    return true
end

local function setRelationship(viewer, target, visible)
    local observers = reverse[target] or {}

    observers[viewer] = visible and true or nil
    reverse[target] = next(observers) and observers or nil
    dirty[target] = true
end

local function clearViewer(id)
    for target in pairs(viewers[id] or {}) do
        setRelationship(id, target, false)
    end

    viewers[id] = nil
end

RegisterNetEvent('zacy:requestPositions', function(ids)
    local sender = tonumber(source)

    if not sender or sender <= 0 then
        return
    end

    local now = GetGameTimer()

    if
        not allowRequest(positionLimits, sender, now, configMaxPositionRequestsPerSecond) or not validIds(ids)
    then
        return
    end

    local observer = playerInfo(sender)

    if not observer then
        return
    end

    local positions = {}
    local visited = {}

    for _, id in ipairs(ids) do
        if id ~= sender and not visited[id] then
            visited[id] = true
            local target = playerInfo(id)

            if nearby(observer, target) then
                positions[#positions + 1] = { id, target.pos.x, target.pos.y, target.pos.z }
            end
        end
    end

    TriggerClientEvent('zacy:positions', sender, positions)
end)

AddEventHandler('playerDropped', function()
    local id = tonumber(source)
    positionLimits[id] = nil

    if not configReciprocalVisibility then
        return
    end

    clearViewer(id)
    reportLimits[id] = nil
    reverse[id] = nil
    dirty[id] = nil

    for _, targets in pairs(viewers) do
        targets[id] = nil
    end
end)

if not configReciprocalVisibility then
    return
end

RegisterNetEvent('zacy:report', function(ids)
    local sender = tonumber(source)

    if not sender or sender <= 0 then
        return
    end

    local now = GetGameTimer()

    if not allowRequest(reportLimits, sender, now, configMaxReportsPerSecond) or not validIds(ids) then
        return
    end

    local observer = playerInfo(sender)
    local previous = viewers[sender] or {}
    local nextSet = {}

    for _, target in ipairs(ids) do
        if target ~= sender and not nextSet[target] and nearby(observer, playerInfo(target)) then
            nextSet[target] = now
            setRelationship(sender, target, true)
        end
    end

    for target in pairs(previous) do
        if not nextSet[target] then
            setRelationship(sender, target, false)
        end
    end

    viewers[sender] = next(nextSet) and nextSet or nil
end)

local function expireRelationships(now)
    local cache = {}

    local function info(id)
        if cache[id] == nil then
            cache[id] = playerInfo(id) or false
        end

        return cache[id]
    end

    for viewer, targets in pairs(viewers) do
        for target, refreshed in pairs(targets) do
            if
                now < refreshed
                or now - refreshed > configLeaseMs
                or not nearby(info(viewer), info(target))
            then
                targets[target] = nil
                setRelationship(viewer, target, false)
            end
        end

        if not next(targets) then
            viewers[viewer] = nil
        end
    end

    for id, limit in pairs(reportLimits) do
        if now < limit.start or now - limit.start > configLeaseMs then
            reportLimits[id] = nil
        end
    end
end

local function flushRelationships()
    for target in pairs(dirty) do
        if GetPlayerName(target) then
            local ids = {}

            for viewer in pairs(reverse[target] or {}) do
                ids[#ids + 1] = viewer
            end

            TriggerClientEvent('zacy:seenByBatch', target, ids)
        end

        dirty[target] = nil
    end
end

CreateThread(function()
    local lastCleanup = GetGameTimer()

    while true do
        Wait(250)

        local now = GetGameTimer()

        if now < lastCleanup or now - lastCleanup >= 1000 then
            expireRelationships(now)
            lastCleanup = now
        end

        flushRelationships()
    end
end)

AddEventHandler('onResourceStop', function(name)
    if name ~= GetCurrentResourceName() then
        return
    end

    for target in pairs(reverse) do
        TriggerClientEvent('zacy:seenByBatch', target, {})
    end
end)