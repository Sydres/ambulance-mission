local ESX = nil

local TERMINATE_GAME_EVENT = 'blargleambulance:terminateGame'
local START_GAME_EVENT = 'blargleambulance:startGame'
local SERVER_EVENT = 'blargleambulance:finishLevel'

local playerData = {
    ped = nil,
    position = nil,
    vehicle = nil,
    isInAmbulance = false,
    isAmbulanceDriveable = false,
    isPlayerDead = false
}

local gameData = {
    isPlaying = false,
    level = 1,
    peds = {}, -- {{model: model, coords: coords}}
    pedsInAmbulance = {}, -- {{model: model, coords: coords}}
    secondsLeft = 0,
    hospitalLocation = {x = 0, y = 0, z = 0, spawnLocations = {}}
}

Citizen.CreateThread(function()
    waitForEsxInitialization()
    waitForControlLoop()
    mainLoop()
end)

function waitForEsxInitialization()
    while ESX == nil do
        TriggerEvent('esx:getSharedObject', function(obj) ESX = obj end)
        Citizen.Wait(0)
    end
end

function mainLoop()
    while true do
        local newPlayerData = gatherData()

        if gameData.isPlaying then
            if not newPlayerData.isInAmbulance then
                TriggerEvent(TERMINATE_GAME_EVENT, _('terminate_left_ambulance'))
            elseif not newPlayerData.isAmbulanceDriveable then
                TriggerEvent(TERMINATE_GAME_EVENT, _('terminate_destroyed_ambulance'))
            elseif newPlayerData.isPlayerDead then
                TriggerEvent(TERMINATE_GAME_EVENT, _('terminate_you_died'))
            end
        elseif not playerData.isInAmbulance and newPlayerData.isInAmbulance then
            ESX.ShowHelpNotification(_('start_game'))
        end

        playerData = newPlayerData

        Citizen.Wait(1000)
    end
end

function waitForControlLoop()
    Citizen.CreateThread(function()
        while true do
            if IsControlJustPressed(1, Config.ActivationKey) then
                if gameData.isPlaying then
                    TriggerEvent(TERMINATE_GAME_EVENT, _('terminate_requested')
                    Citizen.Wait(5000)
                elseif playerData.isInAmbulance then
                    TriggerEvent(START_GAME_EVENT)
                    Citizen.Wait(5000)
                end
            end

            Citizen.Wait(25)
        end
    end)
end

function gatherData()
    local newPlayerData = {}
    newPlayerData.ped = PlayerPedId()
    newPlayerData.position = GetEntityCoords(playerData.ped)
    newPlayerData.vehicle = GetVehiclePedIsIn(playerData.ped, false)
    newPlayerData.isPlayerDead = IsPedDeadOrDying(newPlayerData.ped, true)

    newPlayerData.isInAmbulance = false
    newPlayerData.isAmbulanceDriveable = false

    if newPlayerData.vehicle ~= nil then
        newPlayerData.isInAmbulance = IsVehicleModel(newPlayerData.vehicle, GetHashKey('Ambulance'))

        if newPlayerData.isInAmbulance then
            newPlayerData.isAmbulanceDriveable = IsVehicleDriveable(newPlayerData.vehicle, true)
        end
    end

    return newPlayerData
end

AddEventHandler(TERMINATE_GAME_EVENT, function(reasonForTerminating)
    ESX.ShowNotification(reasonForTerminating)

    gameData.isPlaying = false
    Markers.StopMarkers()

    Peds.DeletePeds(mapPedsToModel(gameData.peds))
    Peds.DeletePeds(mapPedsToModel(gameData.pedsInAmbulance))
end)


AddEventHandler(START_GAME_EVENT, function()
    gameData.hospitalLocation = findNearestHospital(playerData.position)
    gameData.secondsLeft = Config.InitialSeconds
    gameData.isPlaying = true
    gameData.level = 1
    gameData.pedsInAmbulance = 0
    
    ESX.ShowNotification(_('game_started'))
    Markers.StartMarkers(gameData.hospitalLocation)
    setupLevel()
    startGameLoop()
    startTimerThread()
end)

function findNearestHospital(playerPosition)
    local coordsOfNearest = Config.Hospitals[1]
    local distanceToNearest = getDistance(playerPosition, Config.Hospitals[1])

    for i = 2, #Config.Hospitals do
        local coords = Config.Hospitals[i]
        local distance = getDistance(playerPosition, coords)

        if distance < distanceToNearest then
            coordsOfNearest = coords
            distanceToNearest = distance
        end
    end

    return coordsOfNearest
end

function startTimerThread()
    Citizen.CreateThread(function()
        while gameData.isPlaying then
            Citizen.Wait(1000)
            gameData.secondsLeft = gameData.secondsLeft - 1

            if gameData.secondsLeft <= 0 then
                TriggerEvent(TERMINATE_GAME_EVENT, _('terminate_out_of_time'))
            end

            Overlay.Update(gameData)
        end
    end)
end

function startGameLoop()
    Citizen.CreateThread(function()
        while gameData.isPlaying do
            if #gameData.pedsInAmbulance >= Config.MaxPatientsPerTrip or #gameData.peds == 0 then
                ESX.ShowNotification(_('return_to_hospital'))
            elseif getDistance(playerData.position, gameData.hospitalLocation) <= 5.0 then
                handlePatientDropOff()
            else
                handlePatientPickUps()
            end

            Citizen.Wait(1000)
        end
    end)
end

function handlePatientDropOff()
    displayMessageAndWaitUntilStopped('stop_ambulance_dropoff')

    local numberDroppedOff = #gameData.pedsInAmbulance
    Peds.DeletePeds(mapPedsToModel(gameData.pedsInAmbulance))
    gameData.pedsInAmbulance = {}
    gameData.secondsLeft = gameData.secondsLeft + Config.AdditionalTimeForDropOff(numberDroppedOff)

    if #gameData.peds == 0 then
        TriggerServerEvent(SERVER_EVENT, gameData.level)
        ESX.ShowNotification(_('end_level', gameData.level))

        if gameData.level == Config.MaxLevels then
            TriggerEvent(TERMINATE_GAME_EVENT, 'terminate_finished')
        else
            gameData.level = gameData.level + 1
            setupLevel()
        end
    end
end

function mapPedsToModel(peds)
    return Map.map(peds, function(ped)
        return ped.model
    end)
end

function handlePatientPickUps()
    for index, ped in pairs(gameData.peds) do
        if getDistance(playerData.position, ped.coords) <= 5.0 then
            displayMessageAndWaitUntilStopped('stop_ambulance_pickup')
            handleLoading(ped, index)
            addTime(Config.AdditionalTimeForPickup(getDistance(playerData.position, ped.coords)))
            updateMarkersAndBlips()
            Overlay.Update(gameData)
            return
        end
    end
end

function addTime(timeToAdd)
    gameData.secondsLeft = gameData.secondsLeft + timeToAdd
    ESX.ShowNotification(_('time_added', timeToAdd))
end

function handleLoading(ped, index)
    local freeSeat = findFirstFreeSeat()
    Peds.EnterVehicle(ped.model, gameData.vehicle, freeSeat)
    table.insert(gameData.pedsInAmbulance, ped)
    waitUntilPatientOnBus(ped)
    table.remove(gameData.peds, index)
end

function waitUntilPatientOnBus(ped)
    while gameData.isPlaying do
        if Peds.IsPedInVehicleDeadOrTooFarAway(ped.model, ped.coords) then
            return
        end
        Citizen.Wait(50)
    end
end

function setupLevel()
    local locations = Map.shuffle(gameData.hospitalLocation.spawnLocations)
    locations = Map.filter(locations, function(location, index)return index < level end)
    Map.forEach(locations, function(location))
        table.insert(gameData.peds, Peds.CreateRandomPedInArea(coords))
    end)
    updateMarkersAndBlips()

    ESX.ShowNotification(_('start_level', level, level))
end

function getDistance(coords1, coords2)
    return GetDistanceBetweenCoords(coords1, coords2.x, coords2.y, coords2.z, true)
end

function displayMessageAndWaitUntilStopped(notificationMessage)
    while gameData.isPlaying and not IsVehicleStopped(playerData.vehicle) do
        ESX.ShowNotification(_(notificationMessage))
        Citizen.Wait(50)
    end
end

function findFirstFreeSeat()
    for i = 1, Config.MaxPatientsPerTrip do
        if IsVehicleSeatFree(gameData.vehicle, i) then
            return i
        end
    end

    return 0
end

function updateMarkersAndBlips()
    local coordsList = Map.map(gameData.peds, function(ped)
        return ped.coords
    end)

    Blips.UpdateBlips(coordsList)
    Markers.UpdateMarkers(coordsList)
end