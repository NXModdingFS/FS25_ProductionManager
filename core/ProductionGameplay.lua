-- ProductionGameplay.lua
-- Optional gameplay adjustments. Every one is OFF by default and lives in the
-- synced settings, so host and clients agree:
--
--   gpWaterNoValue  - selling stations pay nothing for water
--   gpGrapeYield /
--   gpOliveYield    - multiply the litres per m2 of grapes / olives
--   gpHorseValue /
--   gpPigValue /
--   gpBeefValue     - multiply animal sale values (beef = cattle that give no milk)

ProductionGameplay = {}

ProductionGameplay.originalYield = {}     -- [fruitTypeIndex] = literPerSqm
ProductionGameplay.hooksInstalled = false

local function setting(name, fallback)
    if ProductionSettings == nil or ProductionSettings[name] == nil then return fallback end
    return ProductionSettings[name]
end

-- ------------------------------------------------------------------
-- Animal values
-- ------------------------------------------------------------------

function ProductionGameplay:getAnimalValueFactor(subType)
    if subType == nil then return 1 end
    local typeName = ProductionAnimals ~= nil and ProductionAnimals.getTypeName(subType) or nil
    if typeName == "HORSE" then
        return setting("gpHorseValue", 1)
    elseif typeName == "PIG" then
        return setting("gpPigValue", 1)
    elseif typeName == "COW" and not ProductionAnimals.producesMilk(subType) then
        return setting("gpBeefValue", 1)
    end
    return 1
end

-- Wraps getSellPrice on each animal class. Horse clusters extend the base class and
-- call into it, so a depth counter makes sure the factor is applied exactly once.
local sellPriceDepth = 0
local function wrapSellPrice(class)
    if class == nil or type(class.getSellPrice) ~= "function" or rawget(class, "nxProductionsWrapped") then return end
    local original = class.getSellPrice
    class.getSellPrice = function(self, ...)
        sellPriceDepth = sellPriceDepth + 1
        local ok, price = pcall(original, self, ...)
        sellPriceDepth = sellPriceDepth - 1
        if not ok then error(price, 0) end
        if sellPriceDepth == 0 and type(price) == "number" then
            local subTypeIndex = self.subTypeIndex or ProductionUtil.call(self, "getSubTypeIndex")
            price = price * ProductionGameplay:getAnimalValueFactor(ProductionAnimals.getSubType(subTypeIndex))
        end
        return price
    end
    rawset(class, "nxProductionsWrapped", true)
end

-- ------------------------------------------------------------------
-- Water value
-- ------------------------------------------------------------------

local function wrapStationPrice()
    if SellingStation == nil or SellingStation.getEffectiveFillTypePrice == nil then return end
    SellingStation.getEffectiveFillTypePrice = Utils.overwrittenFunction(SellingStation.getEffectiveFillTypePrice,
        function(self, superFunc, fillTypeIndex, ...)
            if setting("gpWaterNoValue", false) and ProductionUtil.isWater(fillTypeIndex) then
                return 0
            end
            return superFunc(self, fillTypeIndex, ...)
        end)
end

function ProductionGameplay:installHooks()
    if self.hooksInstalled then return end
    self.hooksInstalled = true
    wrapStationPrice()
    wrapSellPrice(AnimalCluster)
    wrapSellPrice(AnimalClusterHorse)
    wrapSellPrice(Animal)
end

-- ------------------------------------------------------------------
-- Grape / olive yield
-- ------------------------------------------------------------------

local function applyYield(fruitName, factor)
    if g_fruitTypeManager == nil then return end
    local fruitType = g_fruitTypeManager:getFruitTypeByName(fruitName)
    if fruitType == nil or fruitType.literPerSqm == nil then return end
    local original = ProductionGameplay.originalYield[fruitType.index]
    if original == nil then
        original = fruitType.literPerSqm
        ProductionGameplay.originalYield[fruitType.index] = original
    end
    fruitType.literPerSqm = original * (factor or 1)
end

function ProductionGameplay:applySettings()
    applyYield("GRAPE", setting("gpGrapeYield", 1))
    applyYield("OLIVE", setting("gpOliveYield", 1))
    if ProductionPrices ~= nil then ProductionPrices:invalidate() end
end

function ProductionGameplay:reset()
    if g_fruitTypeManager ~= nil then
        for index, original in pairs(self.originalYield) do
            local fruitType = g_fruitTypeManager:getFruitTypeByIndex(index)
            if fruitType ~= nil then fruitType.literPerSqm = original end
        end
    end
    self.originalYield = {}
end
