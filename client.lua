-- some protections so cheaters dont just override the natives on their client to bypass this entire system
local AddEventHandler <const> = AddEventHandler
local CreateThread <const> = CreateThread
local DoesEntityExist <const> = DoesEntityExist
local GetActivePlayers <const> = GetActivePlayers
local GetCurrentResourceName <const> = GetCurrentResourceName
local GetEntityCoords <const> = GetEntityCoords
local GetFinalRenderedCamCoord <const> = GetFinalRenderedCamCoord
local GetGameTimer <const> = GetGameTimer
local GetInteriorFromEntity <const> = GetInteriorFromEntity
local GetPedBoneCoords <const> = GetPedBoneCoords
local GetPlayerPed <const> = GetPlayerPed
local GetPlayerServerId <const> = GetPlayerServerId
local GetShapeTestResult <const> = GetShapeTestResult
local GetVehiclePedIsIn <const> = GetVehiclePedIsIn
local IsEntityDead <const> = IsEntityDead
local IsPedInAnyVehicle <const> = IsPedInAnyVehicle
local NetworkConcealEntity <const> = NetworkConcealEntity
local NetworkIsInSpectatorMode <const> = NetworkIsInSpectatorMode
local PlayerId <const> = PlayerId
local PlayerPedId <const> = PlayerPedId
local RegisterCommand <const> = RegisterCommand
local RegisterNetEvent <const> = RegisterNetEvent
local StartExpensiveSynchronousShapeTestLosProbe <const> = StartExpensiveSynchronousShapeTestLosProbe
local StartShapeTestLosProbe <const> = StartShapeTestLosProbe
local TriggerServerEvent <const> = TriggerServerEvent
local Wait <const> = Wait
local ipairs <const> = ipairs
local pairs <const> = pairs
local type <const> = type
local tonumber <const> = tonumber
local tostring <const> = tostring
local print <const> = print
local vector3 <const> = vector3
local rawget <const> = rawget
local mathAbs <const> = math.abs
local mathHuge <const> = math.huge
local mathMax <const> = math.max
local mathMin <const> = math.min
local mathSqrt <const> = math.sqrt

local config <const> = rawget(Config, 'AntiWallhack')
local configEnabled <const> = rawget(config, 'enabled')
local configPositionTimeoutMs <const> = rawget(config, 'positionTimeoutMs')
local configReciprocalVisibility <const> = rawget(config, 'reciprocalVisibility')
local configFarCheckMs <const> = rawget(config, 'farCheckMs')
local configCheckMs <const> = rawget(config, 'checkMs')
local configHideDelayMs <const> = rawget(config, 'hideDelayMs')
local configRayFailureGraceMs <const> = rawget(config, 'rayFailureGraceMs')
local configMaxTargets <const> = rawget(config, 'maxTargets')
local configMaxDistance <const> = rawget(config, 'maxDistance')
local configDiscoveryMs <const> = rawget(config, 'discoveryMs')
local configRevealDeadPlayers <const> = rawget(config, 'revealDeadPlayers')
local configRevealWhileSpectating <const> = rawget(config, 'revealWhileSpectating')
local configRevealInteriors <const> = rawget(config, 'revealInteriors')
local configLeaseMs <const> = rawget(config, 'leaseMs')
local configCloseDistance <const> = rawget(config, 'closeDistance')
local configRevealVehicles <const> = rawget(config, 'revealVehicles')
local configRayTimeoutMs <const> = rawget(config, 'rayTimeoutMs')
local configMaxRayStartsPerTick <const> = rawget(config, 'maxRayStartsPerTick')
local configMaxPendingRays <const> = rawget(config, 'maxPendingRays')
local configSynchronousFallback <const> = rawget(config, 'synchronousFallback')
local configFallbackAfterFailures <const> = rawget(config, 'fallbackAfterFailures')
local configTraceFlags <const> = rawget(config, 'traceFlags')
local configTraceOptions <const> = rawget(config, 'traceOptions')
local configFallbackIntervalMs <const> = rawget(config, 'fallbackIntervalMs')
local configPositionRequestMs <const> = rawget(config, 'positionRequestMs')
local configReportMs <const> = rawget(config, 'reportMs')
local configTickMs <const> = rawget(config, 'tickMs')

if not configEnabled then
    return
end

local tracked = {}
local order = {}
local seenBy = {}
local bones = {
    31086,
    24818,
    11816,
}
local pending = 0
local cursor = 1
local nextFallback = 0
local sampleCount = 6

local function worldPosition(entry, now)
    if entry.hidden or (entry.restoreUntil and now < entry.restoreUntil) then
        if entry.serverPosition and now - entry.serverPositionAt < configPositionTimeoutMs then
            return entry.serverPosition
        end

        if entry.lastWorldPosition and now - entry.lastWorldAt < configPositionTimeoutMs then
            return entry.lastWorldPosition
        end

        return nil
    end

    local pos = GetEntityCoords(entry.ped)
    entry.lastWorldPosition, entry.lastWorldAt = pos, now

    return pos
end

local function conceal(entry, hidden)
    if entry.hidden == hidden or not DoesEntityExist(entry.ped) then
        return
    end

    NetworkConcealEntity(entry.ped, hidden)
    entry.hidden = hidden

    if not hidden then
        entry.restoreUntil = GetGameTimer() + 500
    end
end

local function release(entry)
    conceal(entry, false)

    if entry.ray then
        pending = pending - 1
        entry.ray = nil
    end
end

RegisterNetEvent('zacy:positions', function(positions)
    if source ~= 65535 then -- server only cus client doesnt call it
        return
    end

    local now = GetGameTimer()
    for _, value in ipairs(positions) do
        if type(value) == 'table' then
            local entry = tracked[value[1]]
            local valid = true
            for i = 2, 4 do
                local n = value[i]
                if type(n) ~= 'number' or n ~= n or mathAbs(n) == mathHuge then
                    valid = false
                end
            end
            if entry and valid then
                entry.serverPosition = vector3(value[2], value[3], value[4])
                entry.serverPositionAt = now
            end
        end
    end
end)

RegisterNetEvent('zacy:seenByBatch', function(ids)
    if not configReciprocalVisibility or source ~= 65535 then
        return
    end

    local nextSeen, now = {}, GetGameTimer()
    for _, id in ipairs(ids) do
        if type(id) == 'number' then
            nextSeen[id] = now
            if tracked[id] then
                conceal(tracked[id], false)
            end
        end
    end

    seenBy = nextSeen
end)

local function finish(entry, clear, now, reason)
    entry.clear = clear
    entry.reason = reason or (clear and 'clear-ray' or 'blocked-rays')
    entry.sample = 1
    entry.nextCheck = now + (entry.distance > 100 and configFarCheckMs or configCheckMs)

    if clear then
        entry.blockedSince = nil
        conceal(entry, false)
    else
        entry.blockedSince = entry.blockedSince or now
        conceal(entry, not seenBy[entry.id] and now - entry.blockedSince >= configHideDelayMs)
    end
end

local function consumeResult(entry, status, hit, endpoint, entityHit, now)
    entry.lastStatus = status

    if status ~= 2 then
        entry.failures = (entry.failures or 0) + 1
        entry.failureSince = entry.failureSince or now
        entry.reason = status == 1 and 'ray-timeout' or 'ray-invalid'
        entry.sample = 1
        entry.nextCheck = now + configCheckMs
        entry.clear = false
        if now - entry.failureSince >= configRayFailureGraceMs then
            entry.blockedSince = nil
            conceal(entry, false)
            entry.reason = entry.reason .. '-fail-open'
        end

        return
    end

    entry.failures, entry.failureSince = 0, nil
    entry.completed = (entry.completed or 0) + 1
    entry.lastHit, entry.lastEndpoint = entityHit, endpoint
    entry.lastTarget = entry.rayTarget

    local currentPosition = worldPosition(entry, now)

    if not currentPosition then
        finish(entry, true, now, 'position-unavailable')

        return
    end

    if
        #(currentPosition - entry.rayPosition) > 1.0
        or #(GetFinalRenderedCamCoord() - entry.rayOrigin) > 1.0
    then
        finish(entry, true, now, 'moved-during-ray')

        return
    end

    local clear = not (hit == true or hit == 1)
        or entityHit == entry.ped
        or (entityHit ~= 0 and entityHit == GetVehiclePedIsIn(entry.ped, false))
        or #(endpoint - entry.rayTarget) <= 0.2

    if clear then
        finish(entry, true, now)
    elseif entry.sample >= sampleCount then
        finish(entry, false, now)
    else
        entry.reason = 'blocked-sample-awaiting-rest'
        entry.sample = entry.sample + 1
    end
end

local function discoverPlayers()
    local present = {}
    local nextOrder = {}
    local ownPlayer = PlayerId()

    for _, player in ipairs(GetActivePlayers()) do
        if player ~= ownPlayer then
            local id, ped = GetPlayerServerId(player), GetPlayerPed(player)

            if id > 0 and ped ~= 0 and DoesEntityExist(ped) then
                local entry = tracked[id]

                if entry and (entry.ped ~= ped or entry.player ~= player) then
                    release(entry)
                    entry = nil
                end

                entry = entry
                    or {
                        id = id,
                        player = player,
                        ped = ped,
                        hidden = false,
                        clear = false,
                        sample = 1,
                        nextCheck = 0,
                        distance = 0,
                        reason = 'awaiting-ray',
                    }
                tracked[id], present[id] = entry, true
                nextOrder[#nextOrder + 1] = id
            end
        end
    end

    for id, entry in pairs(tracked) do
        if not present[id] then
            release(entry)

            tracked[id] = nil
            seenBy[id] = nil
        end
    end

    order = nextOrder
end

local function requestPositions()
    local ids = {}

    for id, entry in pairs(tracked) do
        if entry.hidden and #ids < configMaxTargets then
            ids[#ids + 1] = id
        end
    end

    if #ids > 0 then
        TriggerServerEvent('zacy:requestPositions', ids)
    end
end

local function reportVisibility()
    local visible = {}

    for id, entry in pairs(tracked) do
        if entry.clear and entry.distance <= configMaxDistance and #visible < configMaxTargets then
            visible[#visible + 1] = id
        end
    end

    TriggerServerEvent('zacy:report', visible)
end

-- messy ass thread but it works, you can refactor so it isnt some slop
CreateThread(function()
    local nextDiscovery = 0
    local nextPositions = 0
    local nextReport = 0
    local lastTick = GetGameTimer()

    while true do
        local now = GetGameTimer()

        if now < lastTick then
            nextDiscovery = now
            nextPositions = now
            nextReport = now
        end

        lastTick = now

        if now >= nextDiscovery then
            discoverPlayers()
            nextDiscovery = now + configDiscoveryMs
        end

        local ownPed = PlayerPedId()
        local ownPos, camera = GetEntityCoords(ownPed), GetFinalRenderedCamCoord()
        local bypass = not DoesEntityExist(ownPed)
            or (configRevealDeadPlayers and IsEntityDead(ownPed))
            or (configRevealWhileSpectating and NetworkIsInSpectatorMode())
        local ownVehicle = GetVehiclePedIsIn(ownPed, false)
        local ownInterior = configRevealInteriors and GetInteriorFromEntity(ownPed) or 0

        for id, refreshed in pairs(seenBy) do
            if now < refreshed or now - refreshed > configLeaseMs then
                seenBy[id] = nil
            end
        end

        local starts, count = 0, #order
        for offset = 0, count - 1 do
            local entry = tracked[order[((cursor + offset - 1) % count) + 1]]

            if DoesEntityExist(entry.ped) and GetPlayerPed(entry.player) == entry.ped then
                local pos = worldPosition(entry, now)

                if pos then
                    entry.distance = #(ownPos - pos)
                end

                local exempt = not pos and 'position-unavailable'
                    or bypass and 'local-bypass'
                    or (entry.distance < configCloseDistance and 'close-distance')
                    or (entry.distance > configMaxDistance and 'outside-check-range')
                    or (configRevealDeadPlayers and IsEntityDead(entry.ped) and 'dead-player')
                    or (configRevealInteriors and (ownInterior ~= 0 or GetInteriorFromEntity(entry.ped) ~= 0) and 'interior-bypass')
                    or (configRevealVehicles and IsPedInAnyVehicle(entry.ped, false) and 'vehicle-bypass')

                if exempt then
                    release(entry)
                    finish(entry, true, now, exempt)
                elseif entry.ray then
                    local status, hit, endpoint, _, entityHit = GetShapeTestResult(entry.ray)

                    if status ~= 1 or now - entry.rayStarted >= configRayTimeoutMs then
                        entry.ray = nil
                        pending = pending - 1
                        consumeResult(entry, status, hit, endpoint, entityHit, now)
                    end
                elseif
                    now >= entry.nextCheck
                    and starts < configMaxRayStartsPerTick
                    and pending < configMaxPendingRays
                then
                    local fallback = configSynchronousFallback
                        and (entry.useFallback or (entry.failures or 0) >= configFallbackAfterFailures)
                    if not fallback or now >= nextFallback then
                        local target
                        if
                            entry.sample <= #bones
                            and not entry.hidden
                            and not (entry.restoreUntil and now < entry.restoreUntil)
                        then
                            target = GetPedBoneCoords(entry.ped, bones[entry.sample], 0.0, 0.0, 0.0)
                            if #(target - pos) > 2.5 then
                                target = vector3(pos.x, pos.y, pos.z + 0.6)
                            end
                        else
                            local dx, dy = pos.x - camera.x, pos.y - camera.y
                            local length = mathMax(mathSqrt(dx * dx + dy * dy), 0.001)
                            local side = entry.sample == 5 and 0.35 or (entry.sample == 6 and -0.35 or 0.0)
                            local height = entry.sample == 2 and 0.25 or (entry.sample == 3 and 0.0 or 0.6)

                            target = vector3(
                                pos.x - dy / length * side,
                                pos.y + dx / length * side,
                                pos.z + height
                            )
                        end

                        local probe = fallback and StartExpensiveSynchronousShapeTestLosProbe
                            or StartShapeTestLosProbe
                        local handle = probe(
                            camera.x,
                            camera.y,
                            camera.z,
                            target.x,
                            target.y,
                            target.z,
                            configTraceFlags,
                            ownVehicle ~= 0 and ownVehicle or ownPed,
                            configTraceOptions
                        )

                        entry.rayStarted, entry.rayTarget = now, target
                        entry.rayOrigin, entry.rayPosition = camera, pos

                        starts = starts + 1

                        if fallback then
                            nextFallback = now + configFallbackIntervalMs
                            entry.useFallback = true
                            entry.fallbacks = (entry.fallbacks or 0) + 1

                            local status, hit, endpoint, _, entityHit = GetShapeTestResult(handle)
                            consumeResult(entry, status, hit, endpoint, entityHit, now)

                            if entry.sample == 1 then
                                entry.useFallback = nil
                            end
                        elseif handle == 0 then
                            consumeResult(entry, 0, nil, nil, nil, now)
                        else
                            entry.ray = handle
                            pending = pending + 1
                        end
                    end
                end

                if seenBy[entry.id] then
                    conceal(entry, false)
                end
            else
                release(entry)
                entry.clear = false
            end
        end

        if count > 0 then
            cursor = (cursor + configMaxRayStartsPerTick - 1) % count + 1
        end

        if now >= nextPositions then
            requestPositions()

            nextPositions = now + configPositionRequestMs
        end

        if configReciprocalVisibility and now >= nextReport then
            reportVisibility()

            nextReport = now + configReportMs
        end

        local waitMs = count > 0 and configTickMs or configDiscoveryMs

        waitMs = mathMin(waitMs, nextDiscovery - now, nextPositions - now)

        if configReciprocalVisibility then
            waitMs = mathMin(waitMs, nextReport - now)
        end

        Wait(pending > 0 and 0 or mathMax(0, waitMs))
    end
end)

-- parse the player id for this (prints conceal status for the player)
RegisterCommand('check', function(_, args) -- example useage `/check 1`
    local id = tonumber(args[1])
    local entry = id and tracked[id]

    if not entry then
        return print('failed to get player make sure the player is in onesync render')
    end

    print(
        ('id=%d concealed=%s reason=%s distance=%.1f reciprocal=%s pending=%d status=%s failures=%d completed=%d fallbacks=%d'):format(
            id,
            tostring(entry.hidden),
            entry.reason,
            entry.distance,
            tostring(seenBy[id] ~= nil),
            pending,
            tostring(entry.lastStatus),
            entry.failures or 0,
            entry.completed or 0,
            entry.fallbacks or 0
        )
    )

    if entry.lastTarget and entry.lastEndpoint then
        local target, hit = entry.lastTarget, entry.lastEndpoint
        print(
            ('target=(%.2f,%.2f,%.2f) hit=(%.2f,%.2f,%.2f) hitEntity=%s'):format(
                target.x,
                target.y,
                target.z,
                hit.x,
                hit.y,
                hit.z,
                tostring(entry.lastHit)
            )
        )
    end
end, false)

AddEventHandler('onResourceStop', function(name)
    if name ~= GetCurrentResourceName() then
        return
    end

    for _, entry in pairs(tracked) do
        release(entry)
    end
end)
