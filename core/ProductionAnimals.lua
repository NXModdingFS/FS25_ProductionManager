-- ProductionAnimals.lua
-- Animal pens for the Animals page and the HUD: groups, supplies, output and
-- sale advice.
--
-- Advice model (all figures per animal, from the runtime animal curves so maps
-- and mods that change animals are respected):
--   * feed price per litre = cheapest way to satisfy the pen's food groups
--     (serial groups: cheapest group; parallel groups: eat-weighted mix)
--   * best sale age = the age that maximises  sale value(age) - feed cost from
--     now until that age
--   * animals kept for a primary output (milk, eggs, wool ...) are advised on
--     output value vs feed cost instead, until their output falls past its peak.

ProductionAnimals = {}

ProductionAnimals.ADVICE_KEEP        = "keep"
ProductionAnimals.ADVICE_SELL        = "sell"
ProductionAnimals.ADVICE_GROW        = "grow"
ProductionAnimals.ADVICE_HEALTH      = "health"
ProductionAnimals.ADVICE_PAST_PEAK   = "pastPeak"
ProductionAnimals.ADVICE_EVALUATE    = "evaluate"
ProductionAnimals.ADVICE_RIDE        = "ride"

ProductionAnimals.HEALTHY = 90   -- % health treated as "healthy enough to sell"

local function animalSystem()
    return g_currentMission ~= nil and g_currentMission.animalSystem or nil
end

function ProductionAnimals.getSubType(subTypeIndex)
    return ProductionUtil.call(animalSystem(), "getSubTypeByIndex", subTypeIndex)
end

function ProductionAnimals.getTypeName(subType)
    if subType == nil then return nil end
    local animalType = ProductionUtil.call(animalSystem(), "getTypeByIndex", subType.typeIndex)
    return animalType ~= nil and animalType.name or nil
end

function ProductionAnimals.getSubTypeTitle(subType)
    if subType == nil then return "?" end
    if subType.fillTypeIndex ~= nil then
        return ProductionUtil.fillTypeTitle(subType.fillTypeIndex)
    end
    return subType.name or "?"
end

-- Evaluates an AnimCurve (or nil) at the given age in months
local function curveAt(curve, age)
    if curve == nil or curve.get == nil then return nil end
    local ok, value = pcall(curve.get, curve, age)
    if ok and type(value) == "number" then return value end
    return nil
end

local function curveMaxAge(curve)
    if curve == nil then return 0 end
    if curve.maxTime ~= nil then return curve.maxTime end
    local keyframes = curve.keyframes
    if type(keyframes) == "table" and #keyframes > 0 then
        return keyframes[#keyframes].time or 0
    end
    return 0
end

-- Output entries of a subtype: { { fillTypeIndex, curve, isPrimary } }
function ProductionAnimals.getOutputs(subType)
    local list = {}
    if subType == nil or type(subType.output) ~= "table" then return list end
    for _, entry in pairs(subType.output) do
        if type(entry) == "table" and entry.fillType ~= nil and entry.curve ~= nil then
            table.insert(list, {
                fillTypeIndex = entry.fillType,
                curve = entry.curve,
                isPrimary = not ProductionUtil.isByproduct(entry.fillType),
            })
        end
    end
    return list
end

function ProductionAnimals.producesMilk(subType)
    for _, output in ipairs(ProductionAnimals.getOutputs(subType)) do
        local fillType = ProductionUtil.getFillType(output.fillTypeIndex)
        if fillType ~= nil and fillType.name ~= nil and string.find(fillType.name, "MILK") ~= nil then
            return true
        end
    end
    return false
end

-- ------------------------------------------------------------------
-- Feed
-- ------------------------------------------------------------------

-- { groups = { {title, fillTypeIndex (cheapest), price, eatWeight, productionWeight} },
--   pricePerLiter, parallel }
function ProductionAnimals.getFeedEconomics(animalTypeIndex)
    local result = { groups = {}, pricePerLiter = nil, parallel = false }
    local foodSystem = g_currentMission ~= nil and g_currentMission.animalFoodSystem or nil
    local food = ProductionUtil.call(foodSystem, "getAnimalFood", animalTypeIndex)
    if food == nil or food.groups == nil then return result end

    result.parallel = AnimalFoodSystem ~= nil and food.consumptionType == AnimalFoodSystem.FOOD_CONSUME_TYPE_PARALLEL

    for _, group in ipairs(food.groups) do
        local bestIndex, bestPrice = nil, nil
        for _, fillTypeIndex in ipairs(group.fillTypes or {}) do
            local price = ProductionPrices:getInputValue(fillTypeIndex)
            if price ~= nil and (bestPrice == nil or price < bestPrice) then
                bestIndex, bestPrice = fillTypeIndex, price
            end
        end
        table.insert(result.groups, {
            title = group.title or "?",
            fillTypeIndex = bestIndex,
            price = bestPrice,
            eatWeight = group.eatWeight or 1,
            productionWeight = group.productionWeight or 1,
        })
    end

    if result.parallel then
        local sum, weights = 0, 0
        for _, group in ipairs(result.groups) do
            if group.price ~= nil then
                sum = sum + group.price * group.eatWeight
                weights = weights + group.eatWeight
            end
        end
        if weights > 0 then result.pricePerLiter = sum / weights end
    else
        for _, group in ipairs(result.groups) do
            if group.price ~= nil and group.productionWeight > 0
               and (result.pricePerLiter == nil or group.price < result.pricePerLiter) then
                result.pricePerLiter = group.price
            end
        end
    end
    return result
end

-- ------------------------------------------------------------------
-- Per group analysis
-- ------------------------------------------------------------------

local function readCluster(cluster)
    local num = cluster.numAnimals or ProductionUtil.call(cluster, "getNumAnimals") or 0
    local age = cluster.age or ProductionUtil.call(cluster, "getAge") or 0
    local health = cluster.health
    if health == nil then
        local factor = ProductionUtil.call(cluster, "getHealthFactor")
        health = factor ~= nil and factor * 100 or 100
    end
    local reproduction = cluster.reproduction
    if reproduction == nil then
        local factor = ProductionUtil.call(cluster, "getReproductionFactor")
        reproduction = factor ~= nil and factor * 100 or nil
    end
    local subTypeIndex = cluster.subTypeIndex or ProductionUtil.call(cluster, "getSubTypeIndex")
    return num, age, health, reproduction, subTypeIndex
end

-- Theoretical healthy sale value per animal at an age, including value multipliers
local function valueAtAge(subType, age)
    local value = curveAt(subType.sellPrice, age)
    if value == nil then return nil end
    if ProductionGameplay ~= nil then
        value = value * ProductionGameplay:getAnimalValueFactor(subType)
    end
    return value
end

function ProductionAnimals:analyseGroup(cluster, feed)
    local num, age, health, reproduction, subTypeIndex = readCluster(cluster)
    local subType = ProductionAnimals.getSubType(subTypeIndex)
    local group = {
        cluster = cluster, subType = subType, num = num, age = age, health = health,
        reproduction = reproduction, title = ProductionAnimals.getSubTypeTitle(subType),
        typeName = ProductionAnimals.getTypeName(subType),
        isHorse = cluster.riding ~= nil,
        riding = cluster.riding,
    }
    if subType == nil then return group end

    group.value = ProductionUtil.call(cluster, "getSellPrice") or valueAtAge(subType, age)
    group.totalValue = group.value ~= nil and group.value * num or nil
    group.healthyValue = valueAtAge(subType, age)

    -- Food per animal per month at the current age
    local foodCurve = type(subType.input) == "table" and subType.input.food or nil
    group.foodPerMonth = curveAt(foodCurve, age) or 0
    local feedPrice = feed ~= nil and feed.pricePerLiter or nil
    group.feedCostPerMonth = feedPrice ~= nil and group.foodPerMonth * feedPrice or nil

    -- Output per animal per month
    group.outputs = {}
    group.primaryValuePerMonth = 0
    local peakOutput, peakAge, hasPrimary = 0, nil, false
    for _, output in ipairs(ProductionAnimals.getOutputs(subType)) do
        local amount = curveAt(output.curve, age) or 0
        local price = ProductionPrices:getSaleValue(output.fillTypeIndex) or 0
        table.insert(group.outputs, {
            fillTypeIndex = output.fillTypeIndex, amount = amount, value = amount * price,
            isPrimary = output.isPrimary,
        })
        if output.isPrimary then
            hasPrimary = true
            group.primaryValuePerMonth = group.primaryValuePerMonth + amount * price
            for a = 0, math.max(curveMaxAge(output.curve), 1) do
                local v = curveAt(output.curve, a) or 0
                if v > peakOutput then peakOutput, peakAge = v, a end
            end
        end
    end
    group.hasPrimary = hasPrimary
    group.peakOutputAge = peakAge

    -- Best sale age: value(a) - feed from now until a
    local maxAge = math.max(curveMaxAge(subType.sellPrice), age)
    local bestAge, bestNet, feedSoFar = age, nil, 0
    for a = age, maxAge do
        local value = valueAtAge(subType, a)
        if value ~= nil then
            local net = value - feedSoFar
            if bestNet == nil or net > bestNet + 0.01 then
                bestAge, bestNet = a, net
            end
        end
        if feedPrice ~= nil then
            feedSoFar = feedSoFar + (curveAt(foodCurve, a) or 0) * feedPrice
        end
    end
    group.bestAge = bestAge
    group.bestNet = bestNet

    -- Purchase-to-sale view: bought at 0 months, fed until the best age
    local buyAtZero = curveAt(subType.buyPrice, 0)
    if buyAtZero ~= nil and bestNet ~= nil then
        local feedFromBirth = 0
        if feedPrice ~= nil then
            for a = 0, bestAge - 1 do feedFromBirth = feedFromBirth + (curveAt(foodCurve, a) or 0) * feedPrice end
        end
        group.lifetimeProfit = (valueAtAge(subType, bestAge) or 0) - buyAtZero - feedFromBirth
    end

    -- Advice
    local healthy = health >= self.HEALTHY
    if group.isHorse and (group.riding or 100) < 100 then
        group.advice = self.ADVICE_RIDE
    elseif hasPrimary then
        if peakAge ~= nil and age > peakAge and group.feedCostPerMonth ~= nil
           and group.primaryValuePerMonth < group.feedCostPerMonth then
            group.advice = self.ADVICE_PAST_PEAK
        elseif group.feedCostPerMonth ~= nil and group.primaryValuePerMonth < group.feedCostPerMonth * 0.5 and age >= (peakAge or 0) then
            group.advice = self.ADVICE_EVALUATE
        else
            group.advice = self.ADVICE_KEEP
        end
    elseif bestAge > age then
        group.advice = healthy and self.ADVICE_GROW or self.ADVICE_HEALTH
    else
        group.advice = healthy and self.ADVICE_SELL or self.ADVICE_HEALTH
    end

    return group
end

function ProductionAnimals.adviceText(group)
    local key = "pi_advice_" .. (group.advice or ProductionAnimals.ADVICE_EVALUATE)
    if group.advice == ProductionAnimals.ADVICE_GROW then
        return ProductionUtil.text(key, group.bestAge or 0)
    end
    return g_i18n:getText(key)
end

-- ------------------------------------------------------------------
-- Pens
-- ------------------------------------------------------------------

local function getHusbandries(farmId)
    local system = g_currentMission ~= nil and g_currentMission.husbandrySystem or nil
    local list = ProductionUtil.call(system, "getPlaceablesByFarm", farmId)
    if list ~= nil then return list end

    list = {}
    local placeableSystem = g_currentMission ~= nil and g_currentMission.placeableSystem or nil
    for _, placeable in pairs(placeableSystem ~= nil and placeableSystem.placeables or {}) do
        if placeable.spec_husbandryAnimals ~= nil and placeable.ownerFarmId == farmId then
            table.insert(list, placeable)
        end
    end
    return list
end

-- { level, capacity, fraction } or nil
local function husbandrySupply(placeable, fillTypeIndex)
    if fillTypeIndex == nil then return nil end
    local capacity = ProductionUtil.call(placeable, "getHusbandryCapacity", fillTypeIndex)
    if capacity == nil or capacity <= 0 then return nil end
    local level = ProductionUtil.call(placeable, "getHusbandryFillLevel", fillTypeIndex) or 0
    return { level = level, capacity = capacity, fraction = level / capacity }
end

function ProductionAnimals.getFoodSupply(placeable)
    local spec = placeable.spec_husbandryFood
    if spec == nil then return nil end
    local level = ProductionUtil.call(placeable, "getTotalFood")
    local capacity = ProductionUtil.call(placeable, "getFoodCapacity") or spec.capacity
    if level == nil then
        level = 0
        for _, value in pairs(spec.fillLevels or {}) do level = level + value end
    end
    if capacity == nil or capacity <= 0 then return nil end
    return { level = level, capacity = capacity, fraction = level / capacity }
end

function ProductionAnimals:getPen(placeable)
    local pen = {
        placeable = placeable,
        name = ProductionUtil.call(placeable, "getName") or "?",
        numAnimals = ProductionUtil.call(placeable, "getNumOfAnimals") or 0,
        maxAnimals = ProductionUtil.call(placeable, "getMaxNumOfAnimals") or 0,
        animalTypeIndex = ProductionUtil.call(placeable, "getAnimalTypeIndex"),
        groups = {},
    }

    pen.food = ProductionAnimals.getFoodSupply(placeable)
    if FillType ~= nil then
        pen.water = husbandrySupply(placeable, FillType.WATER)
        pen.straw = placeable.spec_husbandryStraw ~= nil and husbandrySupply(placeable, FillType.STRAW) or nil
    end
    local waterSpec = placeable.spec_husbandryWater
    pen.autoWater = waterSpec ~= nil and waterSpec.automaticWaterSupply == true

    pen.feed = ProductionAnimals.getFeedEconomics(pen.animalTypeIndex)

    local totalValue, lowestHealth, count = 0, nil, 0
    for _, cluster in pairs(ProductionUtil.call(placeable, "getClusters") or {}) do
        local ok, group = pcall(self.analyseGroup, self, cluster, pen.feed)
        if ok and group ~= nil and group.num > 0 then
            table.insert(pen.groups, group)
            totalValue = totalValue + (group.totalValue or 0)
            count = count + group.num
            if lowestHealth == nil or group.health < lowestHealth then lowestHealth = group.health end
        end
    end
    table.sort(pen.groups, function(a, b)
        if a.title ~= b.title then return a.title < b.title end
        return a.age < b.age
    end)

    pen.totalValue = totalValue
    pen.lowestHealth = lowestHealth
    if pen.numAnimals == 0 then pen.numAnimals = count end
    return pen
end

function ProductionAnimals:getPens(farmId)
    local pens = {}
    for _, placeable in pairs(getHusbandries(farmId)) do
        if placeable.spec_husbandryAnimals ~= nil then
            local ok, pen = pcall(self.getPen, self, placeable)
            if ok and pen ~= nil then table.insert(pens, pen) end
        end
    end
    table.sort(pens, function(a, b) return a.name < b.name end)
    return pens
end
