-- ProductionStock.lua
-- Farm-wide inventory: every litre the farm owns, wherever it sits.
--
-- Sources are scanned in a fixed order and each storage object is only counted
-- once (productions and husbandries also register their storage with the storage
-- system, so an identity set prevents double counting):
--   productions -> animal pens -> silos/sheds -> other storages
--   -> vehicles/trailers -> pallets -> bales -> object storage (best effort)

ProductionStock = {}

ProductionStock.SOURCE_PRODUCTION = "production"
ProductionStock.SOURCE_ANIMALS    = "animals"
ProductionStock.SOURCE_SILO       = "silo"
ProductionStock.SOURCE_VEHICLE    = "vehicle"
ProductionStock.SOURCE_PALLET     = "pallet"
ProductionStock.SOURCE_BALE       = "bale"
ProductionStock.SOURCE_OBJECTS    = "objectStorage"

ProductionStock.SOURCE_ORDER = {
    ProductionStock.SOURCE_SILO, ProductionStock.SOURCE_PRODUCTION, ProductionStock.SOURCE_ANIMALS,
    ProductionStock.SOURCE_PALLET, ProductionStock.SOURCE_BALE, ProductionStock.SOURCE_OBJECTS,
    ProductionStock.SOURCE_VEHICLE,
}

-- Fuel a motorised vehicle carries for itself is not stock
local function isOwnConsumable(vehicle, fillTypeIndex)
    if vehicle.spec_motorized == nil or FillType == nil then return false end
    return fillTypeIndex == FillType.DIESEL or fillTypeIndex == FillType.DEF
        or fillTypeIndex == FillType.AIR or fillTypeIndex == FillType.ELECTRICCHARGE
        or fillTypeIndex == FillType.METHANE
end

local function newCollector()
    local collector = { products = {} }

    function collector:add(fillTypeIndex, liters, sourceKey, placeName, count)
        if fillTypeIndex == nil or liters == nil or liters <= 0.5 then return end
        if FillType ~= nil and fillTypeIndex == FillType.UNKNOWN then return end

        local product = self.products[fillTypeIndex]
        if product == nil then
            product = { fillTypeIndex = fillTypeIndex, liters = 0, sources = {} }
            self.products[fillTypeIndex] = product
        end
        product.liters = product.liters + liters

        local source = product.sources[sourceKey]
        if source == nil then
            source = { liters = 0, count = 0, places = {} }
            product.sources[sourceKey] = source
        end
        source.liters = source.liters + liters
        source.count = source.count + (count or 1)
        if placeName ~= nil then
            source.places[placeName] = (source.places[placeName] or 0) + liters
        end
    end

    return collector
end

-- Adds every fill level of a Storage object
local function addStorage(collector, storage, sourceKey, placeName)
    if storage == nil then return end
    local levels = storage.fillLevels
    if levels == nil and storage.getFillLevels ~= nil then
        levels = ProductionUtil.call(storage, "getFillLevels")
    end
    if type(levels) ~= "table" then return end
    for fillTypeIndex, level in pairs(levels) do
        collector:add(fillTypeIndex, level, sourceKey, placeName, 0)
    end
end

local function placeableName(placeable)
    return ProductionUtil.call(placeable, "getName") or "?"
end

local function getPlaceables()
    local system = g_currentMission ~= nil and g_currentMission.placeableSystem or nil
    return (system ~= nil and system.placeables) or {}
end

local function addVehicleFillUnits(collector, vehicle, sourceKey, placeName)
    local spec = vehicle.spec_fillUnit
    if spec == nil or spec.fillUnits == nil then return end
    for index, fillUnit in pairs(spec.fillUnits) do
        local fillTypeIndex = fillUnit.fillType
        local level = fillUnit.fillLevel
        if vehicle.getFillUnitFillType ~= nil then
            fillTypeIndex = ProductionUtil.call(vehicle, "getFillUnitFillType", index) or fillTypeIndex
            level = ProductionUtil.call(vehicle, "getFillUnitFillLevel", index) or level
        end
        if fillTypeIndex ~= nil and not isOwnConsumable(vehicle, fillTypeIndex) then
            collector:add(fillTypeIndex, level, sourceKey, placeName)
        end
    end
end

-- Calls fn(bale) for every bale item owned by the farm
function ProductionStock.forEachBale(farmId, fn)
    local itemSystem = g_currentMission ~= nil and g_currentMission.itemSystem or nil
    if itemSystem == nil or Bale == nil then return end
    local items = itemSystem.itemsToSave or itemSystem.items or {}
    for key, entry in pairs(items) do
        local object = type(entry) == "table" and (entry.item or entry) or key
        if type(object) == "table" and object.isa ~= nil and object:isa(Bale) and object.ownerFarmId == farmId then
            fn(object)
        end
    end
end

-- Object storage keeps abstract objects rather than real ones; read what we can
local function addObjectStorage(collector, placeable)
    local spec = placeable.spec_objectStorage
    if spec == nil or spec.objectInfos == nil then return end
    local name = placeableName(placeable)
    for _, info in pairs(spec.objectInfos) do
        for _, object in pairs(info.objects or {}) do
            local attributes = object.baleAttributes or object.palletAttributes or object.attributes
            if type(attributes) == "table" then
                local fillTypeIndex = attributes.fillType or attributes.fillTypeIndex
                local level = attributes.fillLevel
                if fillTypeIndex ~= nil and level ~= nil then
                    collector:add(fillTypeIndex, level, ProductionStock.SOURCE_OBJECTS, name)
                end
            end
        end
    end
end

-- Raw scan: { [fillTypeIndex] = { fillTypeIndex, liters, sources = { [key] = {liters, count, places} } } }
function ProductionStock:scan(farmId)
    local collector = newCollector()
    if g_currentMission == nil or not ProductionUtil.isRealFarm(farmId) then return collector.products end

    local counted = {}

    -- Productions
    local chain = g_currentMission.productionChainManager
    if chain ~= nil then
        for _, point in pairs(chain.productionPoints or {}) do
            if point.ownerFarmId == farmId and point.storage ~= nil and not counted[point.storage] then
                counted[point.storage] = true
                addStorage(collector, point.storage, self.SOURCE_PRODUCTION, ProductionUtil.call(point, "getName"))
            end
        end
    end

    for _, placeable in pairs(getPlaceables()) do
        if placeable.ownerFarmId == farmId then
            -- Animal pens: husbandry storage (milk, manure, water, straw ...) + food trough
            local husbandry = placeable.spec_husbandry
            if husbandry ~= nil and husbandry.storage ~= nil and not counted[husbandry.storage] then
                counted[husbandry.storage] = true
                addStorage(collector, husbandry.storage, self.SOURCE_ANIMALS, placeableName(placeable))
            end
            local food = placeable.spec_husbandryFood
            if food ~= nil and type(food.fillLevels) == "table" then
                for fillTypeIndex, level in pairs(food.fillLevels) do
                    collector:add(fillTypeIndex, level, self.SOURCE_ANIMALS, placeableName(placeable), 0)
                end
            end

            -- Silos and sheds
            local silo = placeable.spec_silo
            if silo ~= nil and silo.storages ~= nil then
                for _, storage in pairs(silo.storages) do
                    if not counted[storage] then
                        counted[storage] = true
                        addStorage(collector, storage, self.SOURCE_SILO, placeableName(placeable))
                    end
                end
            end

            addObjectStorage(collector, placeable)
        end
    end

    -- Any other farm storage the storage system knows about (extensions, mods)
    local storageSystem = g_currentMission.storageSystem
    if storageSystem ~= nil then
        local storages = ProductionUtil.call(storageSystem, "getStorages") or storageSystem.storages or {}
        for _, storage in pairs(storages) do
            if type(storage) == "table" and storage.ownerFarmId == farmId and not counted[storage] then
                counted[storage] = true
                local owner = storage.owningPlaceable
                addStorage(collector, storage, self.SOURCE_SILO, owner ~= nil and placeableName(owner) or nil)
            end
        end
    end

    -- Vehicles, trailers and pallets
    local vehicleSystem = g_currentMission.vehicleSystem
    if vehicleSystem ~= nil then
        for _, vehicle in pairs(vehicleSystem.vehicles or {}) do
            if vehicle.ownerFarmId == farmId then
                local isPallet = ProductionPalletData ~= nil and ProductionPalletData.isPallet ~= nil
                    and ProductionPalletData.isPallet(vehicle)
                if isPallet then
                    addVehicleFillUnits(collector, vehicle, self.SOURCE_PALLET, nil)
                else
                    addVehicleFillUnits(collector, vehicle, self.SOURCE_VEHICLE, ProductionUtil.call(vehicle, "getName"))
                end
            end
        end
    end

    -- Bales
    self.forEachBale(farmId, function(bale)
        local fillTypeIndex = bale.fillType or ProductionUtil.call(bale, "getFillType")
        local level = bale.fillLevel or ProductionUtil.call(bale, "getFillLevel")
        collector:add(fillTypeIndex, level, self.SOURCE_BALE, nil)
    end)

    return collector.products
end

-- Priced product list for the Stock page and HUD, sorted by title.
-- showAllSellable adds products the farm has none of but that a station buys.
function ProductionStock:getProducts(farmId, showAllSellable)
    local raw = self:scan(farmId)

    if showAllSellable then
        for fillTypeIndex, _ in pairs(ProductionPrices:getSellMap()) do
            if raw[fillTypeIndex] == nil then
                raw[fillTypeIndex] = { fillTypeIndex = fillTypeIndex, liters = 0, sources = {} }
            end
        end
    end

    local alerts = ProductionUserData ~= nil and ProductionUserData or nil
    local list = {}
    for fillTypeIndex, product in pairs(raw) do
        local fillType = ProductionUtil.getFillType(fillTypeIndex)
        -- Skip hidden technical fill types unless the farm actually holds them
        local hidden = fillType == nil or (fillType.showOnPriceTable == false and product.liters <= 0)
        if not hidden then
            product.title = fillType.title or fillType.name
            product.name = fillType.name
            product.icon = ProductionUtil.fillTypeIcon(fillTypeIndex)

            local price, station = ProductionPrices:getBestSell(fillTypeIndex)
            product.priceNow = price
            product.stationNow = station
            product.valueNow = price ~= nil and price * product.liters or nil

            product.peak = ProductionPrices:getPeak(fillTypeIndex)
            product.peakValue = product.peak ~= nil and product.peak.price * product.liters or nil

            product.alert = alerts ~= nil and alerts:getAlert(fillType.name) or nil
            table.insert(list, product)
        end
    end

    table.sort(list, function(a, b) return (a.title or "") < (b.title or "") end)
    return list
end

function ProductionStock.sourceTitle(sourceKey)
    return g_i18n:getText("pi_source_" .. sourceKey)
end
