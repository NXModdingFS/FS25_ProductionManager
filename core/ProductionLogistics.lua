-- ProductionLogistics.lua
-- Productions Logistics: an optional demand-driven supply network between the farm's
-- productions, animal pens and silos. Runs on the server once per in-game hour.
--
-- Every building is a node that can hold, receive and hand out products. What
-- happens to each product is decided by a rule the player sets on the Network tab:
--
--   Output side (what a building does with a product it holds):
--     DEFAULT     leave it to the game (base output mode applies)
--     HOLD        keep it; never supplied, stored or sold by the network
--     SUPPLY      hand it to farm buildings that need it
--     STORE       move it into the nearest farm silo/shed with space
--     SELL        sell it at the best station every run
--     SELL_PEAK   keep it until its seasonal peak month, then sell
--     SUPPLY_SELL supply first; the surplus is sold in its peak month
--     plus a RESERVE (% of capacity) that always stays in the building.
--
--   Input side (what a building accepts):
--     blocked     receive nothing of this product
--     priority    low / normal / high - who is served first when stock is short
--     target      fill the building up to this % of its capacity
--
-- Each run: demands are served highest priority / emptiest first, from the nearest
-- source (optionally only within a radius), then STORE and SELL rules are applied
-- and water is topped up if enabled. Transport is charged per 1000 L per km.
-- Activity is counted per building and product for this month and last month.

ProductionLogistics = {}

ProductionLogistics.MODE_DEFAULT     = 0
ProductionLogistics.MODE_HOLD        = 1
ProductionLogistics.MODE_SUPPLY      = 2
ProductionLogistics.MODE_STORE       = 3
ProductionLogistics.MODE_SELL        = 4
ProductionLogistics.MODE_SELL_PEAK   = 5
ProductionLogistics.MODE_SUPPLY_SELL = 6
ProductionLogistics.MODE_COUNT       = 7

ProductionLogistics.KIND_PRODUCTION = "production"
ProductionLogistics.KIND_ANIMALS    = "animals"
ProductionLogistics.KIND_SILO       = "silo"

ProductionLogistics.PRIORITY_LOW, ProductionLogistics.PRIORITY_NORMAL, ProductionLogistics.PRIORITY_HIGH = 1, 2, 3
ProductionLogistics.RESERVES = { 0, 10, 25, 50 }
ProductionLogistics.TARGETS = { 25, 50, 75, 100 }
ProductionLogistics.FOOD_KEY = "*FOOD"       -- pseudo fill type: an animal pen's feed trough
ProductionLogistics.BUILDING_KEY = "*"       -- pseudo fill type: building-wide rule (silo accepts deliveries)
ProductionLogistics.MIN_TRANSFER = 1         -- litres; smaller moves are skipped

ProductionLogistics.rules = {}               -- [buildingKey][productKey] = rule
ProductionLogistics.stats = {}               -- [buildingKey][productKey] = { month = {...}, last = {...} }
ProductionLogistics.lastRunTime = nil

local function setting(name, fallback)
    if ProductionSettings == nil or ProductionSettings[name] == nil then return fallback end
    return ProductionSettings[name]
end

function ProductionLogistics.isEnabled()
    return setting("logisticsEnabled", false) == true
end

-- ------------------------------------------------------------------
-- Keys and rules
-- ------------------------------------------------------------------

function ProductionLogistics.getBuildingKey(placeable)
    if placeable == nil then return nil end
    if placeable.uniqueId ~= nil then return tostring(placeable.uniqueId) end
    if placeable.id ~= nil then return tostring(placeable.id) end
    return nil
end

function ProductionLogistics.productKey(fillTypeIndex)
    local fillType = ProductionUtil.getFillType(fillTypeIndex)
    return fillType ~= nil and fillType.name or nil
end

function ProductionLogistics:getDefaultRule(kind, productKey)
    local rule = {
        mode = ProductionLogistics.MODE_DEFAULT,
        reserve = 0,
        blocked = false,
        priority = ProductionLogistics.PRIORITY_NORMAL,
        target = setting("logisticsDefaultTarget", 75),
    }
    if kind == ProductionLogistics.KIND_SILO then
        rule.mode = ProductionLogistics.MODE_SUPPLY
    end
    if productKey == ProductionLogistics.BUILDING_KEY then
        rule.blocked = false
    end
    return rule
end

function ProductionLogistics:getRule(buildingKey, productKey, kind)
    local byBuilding = self.rules[buildingKey]
    local rule = byBuilding ~= nil and byBuilding[productKey] or nil
    if rule ~= nil then return rule, true end
    return self:getDefaultRule(kind, productKey), false
end

-- Applies locally; callers go through ProductionLogisticsRuleEvent for multiplayer
function ProductionLogistics:setRuleLocal(buildingKey, productKey, rule)
    if buildingKey == nil or productKey == nil then return end
    self.rules[buildingKey] = self.rules[buildingKey] or {}
    self.rules[buildingKey][productKey] = rule
    if ProductionUtil.isServer() then
        self:onRuleApplied(buildingKey, productKey, rule)
    end
end

-- A production output handed to the network must not also be auto-delivered or
-- direct-sold by the game, so its base output mode is switched to "store".
function ProductionLogistics:onRuleApplied(buildingKey, productKey, rule)
    if rule.mode == ProductionLogistics.MODE_DEFAULT then return end
    local chain = g_currentMission.productionChainManager
    local fillTypeIndex = ProductionUtil.fillTypeIndexByName(productKey)
    if chain == nil or fillTypeIndex == nil then return end

    for _, point in pairs(chain.productionPoints or {}) do
        if ProductionLogistics.getBuildingKey(point.owningPlaceable) == buildingKey and point.getOutputDistributionMode ~= nil then
            local current = ProductionUtil.call(point, "getOutputDistributionMode", fillTypeIndex)
            if current ~= nil and current ~= 0 then
                local ok = pcall(point.setOutputDistributionMode, point, fillTypeIndex, 0, true)
                if ok and g_server ~= nil and ProductionPointOutputModeEvent ~= nil then
                    g_server:broadcastEvent(ProductionPointOutputModeEvent.new(point, fillTypeIndex, 0))
                end
            end
        end
    end
end

function ProductionLogistics.modeText(mode)
    return g_i18n:getText("pl_mode_" .. tostring(mode or 0))
end

function ProductionLogistics.priorityText(priority)
    return g_i18n:getText("pl_priority_" .. tostring(priority or ProductionLogistics.PRIORITY_NORMAL))
end

-- ------------------------------------------------------------------
-- Nodes
-- ------------------------------------------------------------------

local Node = {}
Node.__index = Node

local function newNode(kind, placeable, farmId, name)
    local node = setmetatable({
        kind = kind, placeable = placeable, farmId = farmId, name = name or "?",
        key = ProductionLogistics.getBuildingKey(placeable),
        inputs = {},      -- [productKey] = { fillTypes = {idx,...}, isFood = bool }
        outputs = {},     -- [fillTypeIndex] = true
        storages = {},
    }, Node)
    node.x, node.z = ProductionUtil.getPlaceablePosition(placeable)
    return node
end

local function storageLevel(storage, fillTypeIndex)
    return ProductionUtil.call(storage, "getFillLevel", fillTypeIndex) or 0
end

local function storageCapacity(storage, fillTypeIndex)
    return ProductionUtil.call(storage, "getCapacity", fillTypeIndex) or 0
end

local function storageFree(storage, fillTypeIndex)
    local free = ProductionUtil.call(storage, "getFreeCapacity", fillTypeIndex)
    if free ~= nil then return math.max(0, free) end
    return math.max(0, storageCapacity(storage, fillTypeIndex) - storageLevel(storage, fillTypeIndex))
end

local function storageSetLevel(storage, fillTypeIndex, level)
    return pcall(storage.setFillLevel, storage, level, fillTypeIndex)
end

function Node:getLevel(fillTypeIndex)
    if fillTypeIndex == ProductionLogistics.FOOD_KEY then
        local food = ProductionAnimals.getFoodSupply(self.placeable)
        return food ~= nil and food.level or 0
    end
    local total = 0
    for _, storage in ipairs(self.storages) do total = total + storageLevel(storage, fillTypeIndex) end
    return total
end

function Node:getCapacity(fillTypeIndex)
    if fillTypeIndex == ProductionLogistics.FOOD_KEY then
        local food = ProductionAnimals.getFoodSupply(self.placeable)
        return food ~= nil and food.capacity or 0
    end
    local total = 0
    for _, storage in ipairs(self.storages) do total = total + storageCapacity(storage, fillTypeIndex) end
    return total
end

function Node:getFree(fillTypeIndex)
    local total = 0
    for _, storage in ipairs(self.storages) do total = total + storageFree(storage, fillTypeIndex) end
    return total
end

-- Removes up to amount litres; returns what was actually taken
function Node:remove(fillTypeIndex, amount)
    local taken = 0
    for _, storage in ipairs(self.storages) do
        if taken >= amount then break end
        local level = storageLevel(storage, fillTypeIndex)
        local take = math.min(level, amount - taken)
        if take > 0 and storageSetLevel(storage, fillTypeIndex, level - take) then
            taken = taken + take
        end
    end
    return taken
end

-- Adds up to amount litres; returns what was actually stored
function Node:add(fillTypeIndex, amount, isFood)
    if isFood then
        local food = ProductionAnimals.getFoodSupply(self.placeable)
        if food == nil then return 0 end
        local room = math.max(0, food.capacity - food.level)
        local give = math.min(room, amount)
        if give <= 0 then return 0 end
        local added = ProductionUtil.call(self.placeable, "addFood", self.farmId, give, fillTypeIndex, nil, nil, nil)
        return type(added) == "number" and added or 0
    end

    if self.kind == ProductionLogistics.KIND_ANIMALS and self.placeable.addHusbandryFillLevel ~= nil then
        local storage = self.storages[1]
        local give = math.min(storage ~= nil and storageFree(storage, fillTypeIndex) or 0, amount)
        if give <= 0 then return 0 end
        local before = storageLevel(storage, fillTypeIndex)
        ProductionUtil.call(self.placeable, "addHusbandryFillLevel", self.farmId, give, fillTypeIndex, nil, nil, nil)
        return math.max(0, storageLevel(storage, fillTypeIndex) - before)
    end

    local added = 0
    for _, storage in ipairs(self.storages) do
        if added >= amount then break end
        local give = math.min(storageFree(storage, fillTypeIndex), amount - added)
        if give > 0 and storageSetLevel(storage, fillTypeIndex, storageLevel(storage, fillTypeIndex) + give) then
            added = added + give
        end
    end
    return added
end

function Node:acceptsStore(fillTypeIndex)
    if self.kind ~= ProductionLogistics.KIND_SILO then return false end
    local rule = ProductionLogistics:getRule(self.key, ProductionLogistics.BUILDING_KEY, self.kind)
    if rule.blocked then return false end
    return self:getFree(fillTypeIndex) > 0
end

local function enabledRecipes(point)
    local list = {}
    for _, production in pairs(point.productions or {}) do
        if ProductionPoint ~= nil and production.status ~= ProductionPoint.PROD_STATUS.INACTIVE then
            table.insert(list, production)
        end
    end
    return list
end

local function buildProductionNodes(nodes)
    local chain = g_currentMission.productionChainManager
    if chain == nil then return end
    for _, point in pairs(chain.productionPoints or {}) do
        if ProductionUtil.isRealFarm(point.ownerFarmId) and point.storage ~= nil and point.owningPlaceable ~= nil then
            local node = newNode(ProductionLogistics.KIND_PRODUCTION, point.owningPlaceable, point.ownerFarmId,
                ProductionUtil.call(point, "getName"))
            node.point = point
            table.insert(node.storages, point.storage)
            for _, production in ipairs(enabledRecipes(point)) do
                for _, input in pairs(production.inputs or {}) do
                    local key = ProductionLogistics.productKey(input.type)
                    if key ~= nil then node.inputs[key] = { fillTypes = { input.type } } end
                end
            end
            for _, production in pairs(point.productions or {}) do
                for _, output in pairs(production.outputs or {}) do
                    node.outputs[output.type] = true
                end
            end
            if node.key ~= nil then table.insert(nodes, node) end
        end
    end
end

local function buildAnimalNodes(nodes)
    local system = g_currentMission.placeableSystem
    for _, placeable in pairs(system ~= nil and system.placeables or {}) do
        local husbandry = placeable.spec_husbandry
        if placeable.spec_husbandryAnimals ~= nil and husbandry ~= nil and husbandry.storage ~= nil
           and ProductionUtil.isRealFarm(placeable.ownerFarmId) then
            local node = newNode(ProductionLogistics.KIND_ANIMALS, placeable, placeable.ownerFarmId,
                ProductionUtil.call(placeable, "getName"))
            table.insert(node.storages, husbandry.storage)

            if placeable.spec_husbandryFood ~= nil then
                local fillTypes = {}
                local animalTypeIndex = ProductionUtil.call(placeable, "getAnimalTypeIndex")
                local foodSystem = g_currentMission.animalFoodSystem
                local food = ProductionUtil.call(foodSystem, "getAnimalFood", animalTypeIndex)
                for _, group in ipairs(food ~= nil and food.groups or {}) do
                    for _, fillTypeIndex in ipairs(group.fillTypes or {}) do table.insert(fillTypes, fillTypeIndex) end
                end
                if #fillTypes > 0 then
                    node.inputs[ProductionLogistics.FOOD_KEY] = { fillTypes = fillTypes, isFood = true }
                end
            end

            local water = placeable.spec_husbandryWater
            if FillType ~= nil and water ~= nil and water.automaticWaterSupply ~= true then
                node.inputs[ProductionLogistics.productKey(FillType.WATER)] = { fillTypes = { FillType.WATER } }
            end
            if FillType ~= nil and placeable.spec_husbandryStraw ~= nil then
                node.inputs[ProductionLogistics.productKey(FillType.STRAW)] = { fillTypes = { FillType.STRAW } }
            end

            for fillTypeIndex, _ in pairs(husbandry.storage.fillTypes or {}) do
                local key = ProductionLogistics.productKey(fillTypeIndex)
                if key ~= nil and node.inputs[key] == nil then
                    node.outputs[fillTypeIndex] = true
                end
            end
            if node.key ~= nil then table.insert(nodes, node) end
        end
    end
end

local function buildSiloNodes(nodes)
    local system = g_currentMission.placeableSystem
    for _, placeable in pairs(system ~= nil and system.placeables or {}) do
        local silo = placeable.spec_silo
        if silo ~= nil and silo.storages ~= nil and ProductionUtil.isRealFarm(placeable.ownerFarmId)
           and placeable.spec_husbandry == nil then
            local node = newNode(ProductionLogistics.KIND_SILO, placeable, placeable.ownerFarmId,
                ProductionUtil.call(placeable, "getName"))
            for _, storage in pairs(silo.storages) do
                table.insert(node.storages, storage)
                for fillTypeIndex, level in pairs(storage.fillLevels or {}) do
                    if level > 0 then node.outputs[fillTypeIndex] = true end
                end
            end
            if node.key ~= nil and #node.storages > 0 then table.insert(nodes, node) end
        end
    end
end

-- All nodes, optionally only those of one farm
function ProductionLogistics:getNodes(farmId)
    local nodes = {}
    if g_currentMission == nil then return nodes end
    buildProductionNodes(nodes)
    if setting("logisticsIncludeAnimals", true) then buildAnimalNodes(nodes) end
    if setting("logisticsIncludeSilos", true) then buildSiloNodes(nodes) end

    if farmId ~= nil then
        local filtered = {}
        for _, node in ipairs(nodes) do
            if node.farmId == farmId then table.insert(filtered, node) end
        end
        nodes = filtered
    end
    return nodes
end

-- ------------------------------------------------------------------
-- Statistics
-- ------------------------------------------------------------------

local function statEntry(buildingKey, productKey)
    ProductionLogistics.stats[buildingKey] = ProductionLogistics.stats[buildingKey] or {}
    local entry = ProductionLogistics.stats[buildingKey][productKey]
    if entry == nil then
        entry = { month = { received = 0, supplied = 0, sold = 0, income = 0, cost = 0 },
                  last  = { received = 0, supplied = 0, sold = 0, income = 0, cost = 0 } }
        ProductionLogistics.stats[buildingKey][productKey] = entry
    end
    return entry
end

function ProductionLogistics:getStats(buildingKey, productKey)
    local byBuilding = self.stats[buildingKey]
    return byBuilding ~= nil and byBuilding[productKey] or nil
end

function ProductionLogistics:onPeriodChanged()
    for _, byBuilding in pairs(self.stats) do
        for _, entry in pairs(byBuilding) do
            entry.last = entry.month
            entry.month = { received = 0, supplied = 0, sold = 0, income = 0, cost = 0 }
        end
    end
end

-- ------------------------------------------------------------------
-- Engine
-- ------------------------------------------------------------------

local function transportCost(liters, meters)
    local rate = setting("logisticsTransportRate", 0)
    if rate <= 0 or meters == nil then return 0 end
    return liters / 1000 * math.max(meters, 100) / 1000 * rate
end

local function inRange(a, b)
    local radius = setting("logisticsScope", 0)
    if radius <= 0 then return true end
    local distance = ProductionUtil.distance(a.x, a.z, b.x, b.z)
    return distance == nil or distance <= radius
end

-- Litres a source may hand out right now under its rule
local function available(node, fillTypeIndex)
    local rule = ProductionLogistics:getRule(node.key, ProductionLogistics.productKey(fillTypeIndex), node.kind)
    if rule.mode ~= ProductionLogistics.MODE_SUPPLY and rule.mode ~= ProductionLogistics.MODE_SUPPLY_SELL then return 0 end
    local keep = node:getCapacity(fillTypeIndex) * (rule.reserve or 0) / 100
    return math.max(0, node:getLevel(fillTypeIndex) - keep)
end

-- Collects every unmet demand of a farm, most urgent first
local function collectDemands(nodes)
    local demands = {}
    for _, node in ipairs(nodes) do
        for productKey, input in pairs(node.inputs) do
            local rule = ProductionLogistics:getRule(node.key, productKey, node.kind)
            if not rule.blocked then
                local levelKey = input.isFood and ProductionLogistics.FOOD_KEY or input.fillTypes[1]
                local capacity = node:getCapacity(levelKey)
                if capacity > 0 then
                    local level = node:getLevel(levelKey)
                    local want = capacity * (rule.target or 75) / 100 - level
                    if want >= ProductionLogistics.MIN_TRANSFER then
                        table.insert(demands, {
                            node = node, productKey = productKey, input = input, amount = want,
                            priority = rule.priority or ProductionLogistics.PRIORITY_NORMAL, fraction = level / capacity,
                        })
                    end
                end
            end
        end
    end
    table.sort(demands, function(a, b)
        if a.priority ~= b.priority then return a.priority > b.priority end
        return a.fraction < b.fraction
    end)
    return demands
end

function ProductionLogistics:serveDemands(nodes, ledger)
    for _, demand in ipairs(collectDemands(nodes)) do
        local need = demand.amount
        local candidates = {}
        for _, source in ipairs(nodes) do
            if source ~= demand.node and inRange(source, demand.node) then
                for _, fillTypeIndex in ipairs(demand.input.fillTypes) do
                    if source.outputs[fillTypeIndex] and available(source, fillTypeIndex) >= self.MIN_TRANSFER then
                        table.insert(candidates, {
                            node = source, fillTypeIndex = fillTypeIndex,
                            distance = ProductionUtil.distance(source.x, source.z, demand.node.x, demand.node.z) or math.huge,
                        })
                    end
                end
            end
        end
        table.sort(candidates, function(a, b) return a.distance < b.distance end)

        for _, candidate in ipairs(candidates) do
            if need < self.MIN_TRANSFER then break end
            local amount = math.min(need, available(candidate.node, candidate.fillTypeIndex))
            if amount >= self.MIN_TRANSFER then
                local taken = candidate.node:remove(candidate.fillTypeIndex, amount)
                local added = demand.node:add(candidate.fillTypeIndex, taken, demand.input.isFood)
                if added < taken then
                    -- Could not place it all: put the rest back where it came from
                    candidate.node:add(candidate.fillTypeIndex, taken - added, false)
                end
                if added > 0 then
                    need = need - added
                    local productKey = ProductionLogistics.productKey(candidate.fillTypeIndex)
                    local cost = transportCost(added, candidate.distance)
                    ledger.cost = ledger.cost + cost
                    statEntry(candidate.node.key, productKey).month.supplied = statEntry(candidate.node.key, productKey).month.supplied + added
                    local received = statEntry(demand.node.key, demand.productKey).month
                    received.received = received.received + added
                    received.cost = received.cost + cost
                end
            end
        end
    end
end

function ProductionLogistics:applyOutputRules(nodes, ledger, sellPrices)
    for _, node in ipairs(nodes) do
        for fillTypeIndex, _ in pairs(node.outputs) do
            local productKey = ProductionLogistics.productKey(fillTypeIndex)
            local rule = self:getRule(node.key, productKey, node.kind)
            local keep = node:getCapacity(fillTypeIndex) * (rule.reserve or 0) / 100
            local surplus = node:getLevel(fillTypeIndex) - keep

            if surplus >= self.MIN_TRANSFER then
                if rule.mode == ProductionLogistics.MODE_STORE then
                    local targets = {}
                    for _, other in ipairs(nodes) do
                        if other ~= node and other:acceptsStore(fillTypeIndex) and inRange(node, other) then
                            table.insert(targets, { node = other,
                                distance = ProductionUtil.distance(node.x, node.z, other.x, other.z) or math.huge })
                        end
                    end
                    table.sort(targets, function(a, b) return a.distance < b.distance end)
                    for _, target in ipairs(targets) do
                        if surplus < self.MIN_TRANSFER then break end
                        local taken = node:remove(fillTypeIndex, math.min(surplus, target.node:getFree(fillTypeIndex)))
                        local added = target.node:add(fillTypeIndex, taken, false)
                        if added < taken then node:add(fillTypeIndex, taken - added, false) end
                        if added > 0 then
                            surplus = surplus - added
                            local cost = transportCost(added, target.distance)
                            ledger.cost = ledger.cost + cost
                            local stat = statEntry(node.key, productKey).month
                            stat.supplied = stat.supplied + added
                            stat.cost = stat.cost + cost
                            local received = statEntry(target.node.key, productKey).month
                            received.received = received.received + added
                        end
                    end
                else
                    local sellNow = rule.mode == ProductionLogistics.MODE_SELL
                    if rule.mode == ProductionLogistics.MODE_SELL_PEAK or rule.mode == ProductionLogistics.MODE_SUPPLY_SELL then
                        local peak = ProductionPrices:getPeak(fillTypeIndex)
                        sellNow = peak ~= nil and peak.isNow
                    end
                    local price = sellPrices[fillTypeIndex] ~= nil and sellPrices[fillTypeIndex].price or nil
                    if sellNow and price ~= nil and price > 0 then
                        local sold = node:remove(fillTypeIndex, surplus)
                        if sold > 0 then
                            local income = sold * price
                            ledger.income = ledger.income + income
                            local stat = statEntry(node.key, productKey).month
                            stat.sold = stat.sold + sold
                            stat.income = stat.income + income
                        end
                    end
                end
            end
        end
    end
end

-- Water from the network's own supply (charged per 1000 L)
function ProductionLogistics:topUpWater(nodes, ledger)
    if not setting("logisticsAutoWater", false) or FillType == nil then return end
    local waterKey = ProductionLogistics.productKey(FillType.WATER)
    local price = setting("logisticsWaterPrice", 0) / 1000
    for _, node in ipairs(nodes) do
        local input = node.inputs[waterKey]
        if input ~= nil then
            local rule = self:getRule(node.key, waterKey, node.kind)
            local capacity = node:getCapacity(FillType.WATER)
            if not rule.blocked and capacity > 0 then
                local want = capacity * (rule.target or 75) / 100 - node:getLevel(FillType.WATER)
                if want >= self.MIN_TRANSFER then
                    local added = node:add(FillType.WATER, want, false)
                    if added > 0 then
                        local cost = added * price
                        ledger.cost = ledger.cost + cost
                        local stat = statEntry(node.key, waterKey).month
                        stat.received = stat.received + added
                        stat.cost = stat.cost + cost
                    end
                end
            end
        end
    end
end

function ProductionLogistics:run()
    if not ProductionUtil.isServer() or not self.isEnabled() then return end

    local byFarm = {}
    for _, node in ipairs(self:getNodes(nil)) do
        byFarm[node.farmId] = byFarm[node.farmId] or {}
        table.insert(byFarm[node.farmId], node)
    end

    for farmId, nodes in pairs(byFarm) do
        local ledger = { cost = 0, income = 0 }
        local sellPrices = ProductionMarketData ~= nil and ProductionMarketData:getSellPriceMap(farmId) or {}

        local ok, err = pcall(function()
            self:serveDemands(nodes, ledger)
            self:applyOutputRules(nodes, ledger, sellPrices)
            self:topUpWater(nodes, ledger)
        end)
        if not ok then
            Logging.warning("[ProductionLogistics] Run failed for farm %s (%s)", tostring(farmId), tostring(err))
        end

        if ledger.income > 0 then
            local moneyType = MoneyType ~= nil and (MoneyType.SOLD_PRODUCTS or MoneyType.HARVEST_INCOME or MoneyType.OTHER) or nil
            g_currentMission:addMoney(ledger.income, farmId, moneyType, true)
        end
        if ledger.cost > 0 then
            local moneyType = MoneyType ~= nil and (MoneyType.PRODUCTION_COSTS or MoneyType.OTHER) or nil
            g_currentMission:addMoney(-ledger.cost, farmId, moneyType, true)
        end
    end

    self.lastRunTime = g_currentMission.time
end

-- ------------------------------------------------------------------
-- Persistence (server; savegame folder)
-- ------------------------------------------------------------------

local function savegamePath()
    local info = g_currentMission ~= nil and g_currentMission.missionInfo or nil
    if info == nil or info.savegameDirectory == nil then return nil end
    return info.savegameDirectory .. "/productionLogistics.xml"
end

function ProductionLogistics:saveToSavegame()
    local path = savegamePath()
    if path == nil then return end
    local xmlFile = createXMLFile("ProductionLogistics", path, "productionLogistics")
    if xmlFile == nil or xmlFile == 0 then return end

    local i = 0
    for buildingKey, byProduct in pairs(self.rules) do
        for productKey, rule in pairs(byProduct) do
            local key = string.format("productionLogistics.rules.rule(%d)", i)
            setXMLString(xmlFile, key .. "#building", buildingKey)
            setXMLString(xmlFile, key .. "#product", productKey)
            setXMLInt(xmlFile, key .. "#mode", rule.mode or 0)
            setXMLInt(xmlFile, key .. "#reserve", rule.reserve or 0)
            setXMLBool(xmlFile, key .. "#blocked", rule.blocked == true)
            setXMLInt(xmlFile, key .. "#priority", rule.priority or ProductionLogistics.PRIORITY_NORMAL)
            setXMLInt(xmlFile, key .. "#target", rule.target or 75)
            i = i + 1
        end
    end

    saveXMLFile(xmlFile)
    delete(xmlFile)
end

function ProductionLogistics:loadFromSavegame()
    self.rules = {}
    local path = savegamePath()
    if path == nil or not fileExists(path) then return end
    local xmlFile = loadXMLFile("ProductionLogistics", path)
    if xmlFile == nil or xmlFile == 0 then return end

    local i = 0
    while true do
        local key = string.format("productionLogistics.rules.rule(%d)", i)
        if not hasXMLProperty(xmlFile, key) then break end
        local buildingKey = getXMLString(xmlFile, key .. "#building")
        local productKey = getXMLString(xmlFile, key .. "#product")
        if buildingKey ~= nil and productKey ~= nil then
            self.rules[buildingKey] = self.rules[buildingKey] or {}
            self.rules[buildingKey][productKey] = {
                mode = getXMLInt(xmlFile, key .. "#mode") or 0,
                reserve = getXMLInt(xmlFile, key .. "#reserve") or 0,
                blocked = getXMLBool(xmlFile, key .. "#blocked") == true,
                priority = getXMLInt(xmlFile, key .. "#priority") or ProductionLogistics.PRIORITY_NORMAL,
                target = getXMLInt(xmlFile, key .. "#target") or 75,
            }
        end
        i = i + 1
    end
    delete(xmlFile)
end

function ProductionLogistics:reset()
    self.rules = {}
    self.stats = {}
    self.lastRunTime = nil
end

-- ------------------------------------------------------------------
-- Network events
-- ------------------------------------------------------------------

local function writeRule(streamId, rule)
    streamWriteUInt8(streamId, rule.mode or 0)
    streamWriteUInt8(streamId, rule.reserve or 0)
    streamWriteBool(streamId, rule.blocked == true)
    streamWriteUInt8(streamId, rule.priority or ProductionLogistics.PRIORITY_NORMAL)
    streamWriteUInt8(streamId, rule.target or 75)
end

local function readRule(streamId)
    return {
        mode = streamReadUInt8(streamId),
        reserve = streamReadUInt8(streamId),
        blocked = streamReadBool(streamId),
        priority = streamReadUInt8(streamId),
        target = streamReadUInt8(streamId),
    }
end

-- One rule change, client -> server -> everyone
ProductionLogisticsRuleEvent = {}
ProductionLogisticsRuleEvent_mt = Class(ProductionLogisticsRuleEvent, Event)
InitEventClass(ProductionLogisticsRuleEvent, "ProductionLogisticsRuleEvent")

function ProductionLogisticsRuleEvent.emptyNew()
    return Event.new(ProductionLogisticsRuleEvent_mt)
end

function ProductionLogisticsRuleEvent.new(buildingKey, productKey, rule)
    local self = ProductionLogisticsRuleEvent.emptyNew()
    self.buildingKey, self.productKey, self.rule = buildingKey, productKey, rule
    return self
end

function ProductionLogisticsRuleEvent:writeStream(streamId, connection)
    streamWriteString(streamId, self.buildingKey)
    streamWriteString(streamId, self.productKey)
    writeRule(streamId, self.rule)
end

function ProductionLogisticsRuleEvent:readStream(streamId, connection)
    self.buildingKey = streamReadString(streamId)
    self.productKey = streamReadString(streamId)
    self.rule = readRule(streamId)
    self:run(connection)
end

function ProductionLogisticsRuleEvent:run(connection)
    ProductionLogistics:setRuleLocal(self.buildingKey, self.productKey, self.rule)
    if not connection:getIsServer() then
        -- We are the server and a client sent this: pass it on to everyone else
        g_server:broadcastEvent(self, false, connection)
    end
end

function ProductionLogisticsRuleEvent.send(buildingKey, productKey, rule)
    if g_server ~= nil then
        ProductionLogistics:setRuleLocal(buildingKey, productKey, rule)
        g_server:broadcastEvent(ProductionLogisticsRuleEvent.new(buildingKey, productKey, rule))
    else
        g_client:getServerConnection():sendEvent(ProductionLogisticsRuleEvent.new(buildingKey, productKey, rule))
    end
end

-- Full rule set, server -> joining client
ProductionLogisticsSyncEvent = {}
ProductionLogisticsSyncEvent_mt = Class(ProductionLogisticsSyncEvent, Event)
InitEventClass(ProductionLogisticsSyncEvent, "ProductionLogisticsSyncEvent")

function ProductionLogisticsSyncEvent.emptyNew()
    return Event.new(ProductionLogisticsSyncEvent_mt)
end

function ProductionLogisticsSyncEvent.new()
    return ProductionLogisticsSyncEvent.emptyNew()
end

function ProductionLogisticsSyncEvent:writeStream(streamId, connection)
    local entries = {}
    for buildingKey, byProduct in pairs(ProductionLogistics.rules) do
        for productKey, rule in pairs(byProduct) do
            table.insert(entries, { buildingKey, productKey, rule })
        end
    end
    streamWriteInt32(streamId, #entries)
    for _, entry in ipairs(entries) do
        streamWriteString(streamId, entry[1])
        streamWriteString(streamId, entry[2])
        writeRule(streamId, entry[3])
    end
end

function ProductionLogisticsSyncEvent:readStream(streamId, connection)
    ProductionLogistics.rules = {}
    local count = streamReadInt32(streamId)
    for _ = 1, count do
        local buildingKey = streamReadString(streamId)
        local productKey = streamReadString(streamId)
        local rule = readRule(streamId)
        ProductionLogistics.rules[buildingKey] = ProductionLogistics.rules[buildingKey] or {}
        ProductionLogistics.rules[buildingKey][productKey] = rule
    end
end

function ProductionLogisticsSyncEvent:run(connection)
end
