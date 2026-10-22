-- ProductionCommon.lua
-- Shared helpers for the Productions Insights and Logistics modules: formatting, safe
-- engine calls, farm/period lookups and the price model.
--
-- The price model answers three questions for any fill type:
--   * what a litre sells for right now (best station, not our own),
--   * what it should sell for at its seasonal best (current best price scaled by
--     the fill type's economy factors, so station multipliers are respected),
--   * what a litre is worth as a recipe/animal input (its sale value if it can be
--     sold, otherwise its purchase cost - i.e. the opportunity cost of using it).

ProductionUtil = {}

ProductionUtil.COLOR = {
    WHITE   = {1, 1, 1, 1},
    GREY    = {0.5, 0.5, 0.5, 1},
    CAPTION = {0.65, 0.65, 0.65, 1},
    GREEN   = {0.3, 0.85, 0.3, 1},
    RED     = {0.9, 0.25, 0.2, 1},
    ORANGE  = {1, 0.6, 0, 1},
    BLUE    = {0.3, 0.7, 1, 1},
    GOLD    = {1, 0.85, 0.1, 1},
}

-- Calls obj:methodName(...) if it exists, swallowing errors. Returns up to three
-- results, or nil. Keeps version differences in the engine API from breaking a page.
function ProductionUtil.call(obj, methodName, ...)
    if obj == nil then return nil end
    local fn = obj[methodName]
    if type(fn) ~= "function" then return nil end
    local ok, a, b, c = pcall(fn, obj, ...)
    if ok then return a, b, c end
    return nil
end

function ProductionUtil.text(key, ...)
    local text = g_i18n:getText(key)
    if select("#", ...) > 0 then
        local ok, formatted = pcall(string.format, text, ...)
        if ok then return formatted end
    end
    return text
end

function ProductionUtil.getFarmId()
    if g_currentMission == nil then return nil end
    return g_currentMission:getFarmId()
end

function ProductionUtil.isRealFarm(farmId)
    if farmId == nil or farmId == 0 then return false end
    if FarmManager ~= nil and farmId == FarmManager.SPECTATOR_FARM_ID then return false end
    return true
end

function ProductionUtil.isServer()
    return g_currentMission ~= nil and g_currentMission:getIsServer()
end

function ProductionUtil.getPeriod()
    local env = g_currentMission ~= nil and g_currentMission.environment or nil
    if env == nil then return 1 end
    return env.currentPeriod or 1
end

-- A production "month" is 24 production hours, whatever the save's days per
-- month. Returns the first rate given: per month as-is, per hour x24, per minute
-- x1440 (or nil). Never scale these by days per month.
ProductionUtil.PRODUCTION_HOURS_PER_MONTH = 24

function ProductionUtil.monthlyRate(perMonth, perHour, perMinute)
    if perMonth ~= nil then return perMonth end
    if perHour ~= nil then return perHour * ProductionUtil.PRODUCTION_HOURS_PER_MONTH end
    if perMinute ~= nil then return perMinute * 60 * ProductionUtil.PRODUCTION_HOURS_PER_MONTH end
    return nil
end

function ProductionUtil.getDaysPerPeriod()
    local info = g_currentMission ~= nil and g_currentMission.missionInfo or nil
    return (info ~= nil and info.plannedDaysPerPeriod) or 1
end

-- ------------------------------------------------------------------
-- Formatting
-- ------------------------------------------------------------------

function ProductionUtil.formatNumber(num)
    local formatted = tostring(math.floor((num or 0) + 0.5))
    local k
    repeat
        formatted, k = string.gsub(formatted, "^(-?%d+)(%d%d%d)", "%1,%2")
    until k == 0
    return formatted
end

function ProductionUtil.formatLiters(liters)
    return ProductionUtil.formatNumber(liters) .. " L"
end

function ProductionUtil.formatMoney(value)
    return g_i18n:formatMoney(value or 0, 0, true, true)
end

-- Price per litre shown per 1000 L, matching the in-game prices menu
function ProductionUtil.formatPer1000(pricePerLiter)
    if pricePerLiter == nil then return "-" end
    return ProductionUtil.formatMoney(pricePerLiter * 1000)
end

function ProductionUtil.formatPercent(fraction)
    return string.format("%d%%", math.floor((fraction or 0) * 100 + 0.5))
end

function ProductionUtil.periodName(period)
    return g_i18n:getText("PS_MONTH_" .. tostring(period))
end

function ProductionUtil.periodShort(period)
    local name = ProductionUtil.periodName(period)
    if utf8Substr ~= nil then
        return utf8Substr(name, 0, 3)
    end
    return string.sub(name, 1, 3)
end

-- Turns a set { [period] = true } into "Mar-May, Sep" (consecutive periods merged)
function ProductionUtil.formatPeriods(periodSet)
    if periodSet == nil then return "-" end
    local count = 0
    for period = 1, 12 do
        if periodSet[period] == true then count = count + 1 end
    end
    if count == 12 then return ProductionUtil.text("pi_allYear") end

    local parts = {}
    local runStart = nil
    for period = 1, 13 do
        local on = period <= 12 and periodSet[period] == true
        if on and runStart == nil then
            runStart = period
        elseif not on and runStart ~= nil then
            local runEnd = period - 1
            if runEnd == runStart then
                table.insert(parts, ProductionUtil.periodShort(runStart))
            else
                table.insert(parts, ProductionUtil.periodShort(runStart) .. "-" .. ProductionUtil.periodShort(runEnd))
            end
            runStart = nil
        end
    end
    if #parts == 0 then return "-" end
    return table.concat(parts, ", ")
end

-- ------------------------------------------------------------------
-- Fill types
-- ------------------------------------------------------------------

function ProductionUtil.getFillType(fillTypeIndex)
    if fillTypeIndex == nil or g_fillTypeManager == nil then return nil end
    return g_fillTypeManager:getFillTypeByIndex(fillTypeIndex)
end

function ProductionUtil.fillTypeTitle(fillTypeIndex)
    local fillType = ProductionUtil.getFillType(fillTypeIndex)
    return fillType ~= nil and fillType.title or "?"
end

function ProductionUtil.fillTypeIcon(fillTypeIndex)
    local fillType = ProductionUtil.getFillType(fillTypeIndex)
    if fillType ~= nil and fillType.hudOverlayFilename ~= nil and fillType.hudOverlayFilename ~= "" then
        return fillType.hudOverlayFilename
    end
    return nil
end

function ProductionUtil.fillTypeIndexByName(name)
    if name == nil or g_fillTypeManager == nil then return nil end
    return g_fillTypeManager:getFillTypeIndexByName(name)
end

function ProductionUtil.isWater(fillTypeIndex)
    return FillType ~= nil and fillTypeIndex == FillType.WATER
end

-- Manure-type outputs are by-products: useful, but never the reason to run something
function ProductionUtil.isByproduct(fillTypeIndex)
    if FillType == nil then return false end
    return fillTypeIndex == FillType.MANURE or fillTypeIndex == FillType.LIQUIDMANURE
        or fillTypeIndex == FillType.DIGESTATE
end

-- ------------------------------------------------------------------
-- World helpers
-- ------------------------------------------------------------------

function ProductionUtil.getPlaceablePosition(placeable)
    if placeable == nil or placeable.rootNode == nil or getWorldTranslation == nil then return nil end
    local ok, x, _, z = pcall(getWorldTranslation, placeable.rootNode)
    if ok then return x, z end
    return nil
end

function ProductionUtil.distance(x1, z1, x2, z2)
    if x1 == nil or x2 == nil then return nil end
    local dx, dz = x2 - x1, z2 - z1
    return math.sqrt(dx * dx + dz * dz)
end

-- ==================================================================
-- Prices
-- ==================================================================

ProductionPrices = {}
ProductionPrices.CACHE_MS = 2000
ProductionPrices.BASIS_CURRENT = 1
ProductionPrices.BASIS_PEAK    = 2

function ProductionPrices.getPriceMultiplier()
    if EconomyManager ~= nil and EconomyManager.getPriceMultiplier ~= nil then
        local ok, value = pcall(EconomyManager.getPriceMultiplier)
        if ok and type(value) == "number" and value > 0 then
            return value
        end
    end
    return 1
end

-- Best current sell price per fill type, cached briefly so every page and the
-- HUD can ask freely without rescanning every station.
function ProductionPrices:getSellMap()
    local now = g_time or 0
    if self.sellMap ~= nil and self.sellMapTime ~= nil and now - self.sellMapTime < self.CACHE_MS then
        return self.sellMap
    end

    local map = {}
    if ProductionMarketData ~= nil then
        local ok, result = pcall(ProductionMarketData.getSellPriceMap, ProductionMarketData, ProductionUtil.getFarmId())
        if ok and type(result) == "table" then
            map = result
        end
    end
    self.sellMap = map
    self.sellMapTime = now
    return map
end

function ProductionPrices:invalidate()
    self.sellMap = nil
end

-- Returns pricePerLiter, stationName for the best station buying it now (or nil)
function ProductionPrices:getBestSell(fillTypeIndex)
    local info = self:getSellMap()[fillTypeIndex]
    if info == nil then return nil, nil end
    return info.price, info.stationName
end

function ProductionPrices:getStations(fillTypeIndex)
    if ProductionMarketData == nil or ProductionMarketData.getStationPrices == nil then return {} end
    local ok, list = pcall(ProductionMarketData.getStationPrices, ProductionMarketData, fillTypeIndex, ProductionUtil.getFarmId())
    if ok and type(list) == "table" then return list end
    return {}
end

-- Seasonal factor of a fill type in a period (1 when the fill type has no curve)
function ProductionPrices:getSeasonFactor(fillTypeIndex, period)
    local fillType = ProductionUtil.getFillType(fillTypeIndex)
    if fillType == nil or fillType.economy == nil or fillType.economy.factors == nil then
        return 1
    end
    local factor = fillType.economy.factors[period]
    if type(factor) ~= "number" or factor <= 0 then return 1 end
    return factor
end

function ProductionPrices:getBasePrice(fillTypeIndex)
    local fillType = ProductionUtil.getFillType(fillTypeIndex)
    if fillType == nil or fillType.pricePerLiter == nil or fillType.pricePerLiter <= 0 then
        return nil
    end
    return fillType.pricePerLiter * self.getPriceMultiplier()
end

-- Estimated best-station price in a given period. The current best price already
-- contains the station's own multiplier, so it is rescaled by the ratio of the
-- seasonal factors rather than recomputed from the base price.
function ProductionPrices:getPriceInPeriod(fillTypeIndex, period)
    local current = self:getBestSell(fillTypeIndex)
    if current == nil then return nil end
    local nowFactor = self:getSeasonFactor(fillTypeIndex, ProductionUtil.getPeriod())
    return current * self:getSeasonFactor(fillTypeIndex, period) / nowFactor
end

-- { price = <perLiter at peak>, periods = {[p]=true}, isNow = bool } or nil
function ProductionPrices:getPeak(fillTypeIndex)
    local current = self:getBestSell(fillTypeIndex)
    if current == nil then return nil end

    local best, periods = nil, {}
    for period = 1, 12 do
        local price = self:getPriceInPeriod(fillTypeIndex, period)
        if price ~= nil then
            if best == nil or price > best + 1e-6 then
                best = price
                periods = { [period] = true }
            elseif math.abs(price - best) <= 1e-6 then
                periods[period] = true
            end
        end
    end
    if best == nil then return nil end

    return { price = best, periods = periods, isNow = periods[ProductionUtil.getPeriod()] == true }
end

-- What a litre of output is worth, following the player's price-basis setting.
-- Returns price, isEstimate (true when no station buys it and the base price is used).
function ProductionPrices:getSaleValue(fillTypeIndex)
    local basis = ProductionSettings ~= nil and ProductionSettings.insightsPriceBasis or self.BASIS_CURRENT
    if basis == self.BASIS_PEAK then
        local peak = self:getPeak(fillTypeIndex)
        if peak ~= nil then return peak.price, false end
    else
        local price = self:getBestSell(fillTypeIndex)
        if price ~= nil then return price, false end
    end
    local base = self:getBasePrice(fillTypeIndex)
    return base, true
end

-- Purchase cost per litre (seeds, fertiliser, water ...) or nil if not buyable
function ProductionPrices:getBuyPrice(fillTypeIndex)
    if ProductionUtil.isWater(fillTypeIndex) and ProductionSettings ~= nil and ProductionSettings.insightsFreeWater then
        return 0
    end
    local economy = g_currentMission ~= nil and g_currentMission.economyManager or nil
    local cost = ProductionUtil.call(economy, "getCostPerLiter", fillTypeIndex, true)
    if type(cost) == "number" and cost > 0 then
        return cost
    end
    return nil
end

-- Value of a litre used as an input. If the farm holds some and a station buys
-- it, that sale price is what processing it gives up. If the farm has none it
-- would have to be bought, so the purchase price applies when there is one.
-- inStock: true / false, or nil when unknown (then the sale price is preferred).
-- Returns price, isEstimate (true when only the base price was available).
function ProductionPrices:getInputValue(fillTypeIndex, inStock)
    if ProductionUtil.isWater(fillTypeIndex) and ProductionSettings ~= nil and ProductionSettings.insightsFreeWater then
        return 0, false
    end
    local sell = self:getBestSell(fillTypeIndex)
    if sell ~= nil and inStock ~= false then return sell, false end
    local buy = self:getBuyPrice(fillTypeIndex)
    if buy ~= nil then return buy, false end
    if sell ~= nil then return sell, false end
    return self:getBasePrice(fillTypeIndex) or 0, true
end
