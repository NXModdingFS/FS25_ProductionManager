-- ProductionMarketData.lua
-- Market price helpers for the Production Manager finance/schedule pages.
--
-- Two independent questions are answered here:
--   1. Right now, which selling station pays the most for a fill type, and how much?
--      (getSellPriceMap - one pass over all selling stations, cached per query)
--   2. Across the year, which period(s) hit the seasonal price peak for a fill type?
--      (getSeasonalPeak - derived from the fill type's economy factors)
--
-- Note: this reaches the same base-game data a price-alert tool would, but the
-- shape here is deliberately built around per-production lookups for the finance
-- table rather than around HUD notifications.

ProductionMarketData = {}

-- Returns the game's global price multiplier, or 1 if unavailable.
local function getPriceMultiplier()
    if EconomyManager ~= nil and EconomyManager.getPriceMultiplier ~= nil then
        local ok, value = pcall(EconomyManager.getPriceMultiplier)
        if ok and type(value) == "number" and value > 0 then
            return value
        end
    end
    return 1
end

-- Calls fn(station, stationName) for every selling station that appears in the
-- prices menu and is not owned by ownFarmId (selling to yourself is not income).
local function forEachSellingStation(ownFarmId, fn)
    local mission = g_currentMission
    if mission == nil or mission.storageSystem == nil
       or mission.storageSystem.getUnloadingStations == nil then
        return
    end

    local stations = mission.storageSystem:getUnloadingStations() or {}
    for _, station in pairs(stations) do
        local usable = station ~= nil
            and station.isa ~= nil
            and SellingStation ~= nil
            and station:isa(SellingStation)
            and not station.hideFromPricesMenu
            and station.acceptedFillTypes ~= nil
            and station.getEffectiveFillTypePrice ~= nil

        if usable and station.ownerFarmId ~= ownFarmId then
            local stationName = station.getName ~= nil and station:getName() or nil
            fn(station, stationName or "?")
        end
    end
end

-- Builds { [fillTypeIndex] = { price = <perLiter>, stationName = <string> } } holding
-- the best price any station (other than the player's own) currently pays.
-- Scans every selling station once, so callers should build this map a single
-- time per refresh rather than per production.
function ProductionMarketData:getSellPriceMap(ownFarmId)
    local map = {}

    forEachSellingStation(ownFarmId, function(station, stationName)
        for fillTypeIndex, accepted in pairs(station.acceptedFillTypes) do
            if accepted == true then
                local price = station:getEffectiveFillTypePrice(fillTypeIndex)
                if price ~= nil and price > 0 then
                    local current = map[fillTypeIndex]
                    if current == nil or price > current.price then
                        map[fillTypeIndex] = {
                            price = price,
                            stationName = stationName
                        }
                    end
                end
            end
        end
    end)

    return map
end

-- Returns every station currently buying fillTypeIndex, best price first:
--   { { stationName = <string>, price = <perLiter>, station = <SellingStation> }, ... }
function ProductionMarketData:getStationPrices(fillTypeIndex, ownFarmId)
    local list = {}
    if fillTypeIndex == nil then return list end

    forEachSellingStation(ownFarmId, function(station, stationName)
        if station.acceptedFillTypes[fillTypeIndex] == true then
            local price = station:getEffectiveFillTypePrice(fillTypeIndex)
            if price ~= nil and price > 0 then
                table.insert(list, { stationName = stationName, price = price, station = station })
            end
        end
    end)

    table.sort(list, function(a, b) return a.price > b.price end)
    return list
end

-- Returns peak seasonal price info for a fill type, or nil if unknown:
--   { price = <perLiter at peak>, periods = { [period] = true, ... } }
-- The seasonal SHAPE (which months are best) comes purely from economy factors,
-- so it is independent of any particular station's price scale.
function ProductionMarketData:getSeasonalPeak(fillTypeIndex)
    if g_fillTypeManager == nil or fillTypeIndex == nil then return nil end

    local fillType = g_fillTypeManager:getFillTypeByIndex(fillTypeIndex)
    if fillType == nil or fillType.pricePerLiter == nil then return nil end
    if fillType.economy == nil or fillType.economy.factors == nil then return nil end

    local factors = fillType.economy.factors
    local firstPeriod = 1
    local lastPeriod = 12
    if SeasonPeriod ~= nil then
        firstPeriod = SeasonPeriod.EARLY_SPRING or firstPeriod
        lastPeriod = SeasonPeriod.LATE_WINTER or lastPeriod
    end

    local maxFactor = nil
    local peakPeriods = {}
    for period = firstPeriod, lastPeriod do
        local factor = factors[period] or 1
        if maxFactor == nil or factor > maxFactor + 0.0001 then
            maxFactor = factor
            peakPeriods = { [period] = true }
        elseif math.abs(factor - maxFactor) <= 0.0001 then
            peakPeriods[period] = true
        end
    end

    if maxFactor == nil then return nil end

    return {
        price   = fillType.pricePerLiter * maxFactor * getPriceMultiplier(),
        periods = peakPeriods
    }
end

-- Pure helper module: loaded via source(), no loadMap/update lifecycle, so it is
-- intentionally NOT registered with addModEventListener.
