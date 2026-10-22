-- ProductionPalletData.lua
-- Scans the map for the farm's pallets and totals their contents by fill type.
--
-- Production output that has already been spawned as a pallet no longer lives in
-- the production point's internal storage, so the storage-based output view can't
-- see it. This helper walks the vehicle system, keeps the pallet-style vehicles
-- owned by the farm, and sums their fill-unit levels per fill type. It also records
-- a representative pallet capacity per fill type (the largest fill-unit capacity
-- seen) so callers can estimate "pallets per month" from a litres/month figure.
--
-- Pallet detection mirrors the well-tested approach used elsewhere in the FS
-- modding community (spec_pallet / isPallet, or "pallet"/"bigbag" in the type or
-- config name), reworked here to also capture capacities for the estimate.

ProductionPalletData = {}

local function getIsPalletVehicle(vehicle)
    if vehicle == nil then return false end

    if vehicle.spec_pallet ~= nil or vehicle.isPallet == true then
        return true
    end

    local typeName = string.lower(tostring(vehicle.typeName or vehicle.typeDesc or ""))
    if string.find(typeName, "pallet") ~= nil or string.find(typeName, "bigbag") ~= nil then
        return true
    end

    local configName = string.lower(tostring(vehicle.configFileName or vehicle.xmlFilename or ""))
    return string.find(configName, "pallet") ~= nil or string.find(configName, "bigbag") ~= nil
end

-- Shared with the Productions Insights stock scan so both agree on what counts as a pallet
ProductionPalletData.isPallet = getIsPalletVehicle

-- Accumulates one fill unit's level (and capacity) into the totals table.
local function addFillUnit(totals, vehicle, fillUnitIndex)
    if vehicle.getFillUnitFillType == nil or vehicle.getFillUnitFillLevel == nil then return end

    local okType,  fillTypeIndex = pcall(vehicle.getFillUnitFillType, vehicle, fillUnitIndex)
    local okLevel, fillLevel     = pcall(vehicle.getFillUnitFillLevel, vehicle, fillUnitIndex)

    local unknown = (FillType ~= nil and FillType.UNKNOWN) or nil
    if not (okType and okLevel) then return end
    if fillTypeIndex == nil or fillTypeIndex == unknown then return end
    if fillLevel == nil or fillLevel <= 0 then return end

    local entry = totals[fillTypeIndex]
    if entry == nil then
        entry = { liters = 0, count = 0, palletCapacity = nil }
        totals[fillTypeIndex] = entry
    end
    entry.liters = entry.liters + fillLevel
    entry.count  = entry.count + 1

    if vehicle.getFillUnitCapacity ~= nil then
        local okCap, cap = pcall(vehicle.getFillUnitCapacity, vehicle, fillUnitIndex)
        if okCap and type(cap) == "number" and cap > 0 then
            if entry.palletCapacity == nil or cap > entry.palletCapacity then
                entry.palletCapacity = cap
            end
        end
    end
end

-- Returns { [fillTypeIndex] = { liters = <total>, count = <#pallets>, palletCapacity = <litres or nil> } }
-- for every product currently sitting in the farm's pallets.
function ProductionPalletData:getPalletTotals(ownFarmId)
    local totals = {}

    local mission = g_currentMission
    if mission == nil or mission.vehicleSystem == nil or mission.vehicleSystem.vehicles == nil then
        return totals
    end

    for _, vehicle in pairs(mission.vehicleSystem.vehicles) do
        if vehicle ~= nil and vehicle.ownerFarmId == ownFarmId and getIsPalletVehicle(vehicle) then
            local handled = false
            if vehicle.getFillUnits ~= nil then
                local ok, units = pcall(vehicle.getFillUnits, vehicle)
                if ok and units ~= nil then
                    for fillUnitIndex, _ in pairs(units) do
                        addFillUnit(totals, vehicle, fillUnitIndex)
                    end
                    handled = true
                end
            end
            if not handled and vehicle.spec_fillUnit ~= nil and vehicle.spec_fillUnit.fillUnits ~= nil then
                for fillUnitIndex, _ in pairs(vehicle.spec_fillUnit.fillUnits) do
                    addFillUnit(totals, vehicle, fillUnitIndex)
                end
            end
        end
    end

    return totals
end

-- Pure helper module: loaded via source(), no loadMap/update lifecycle, so it is
-- intentionally NOT registered with addModEventListener.
