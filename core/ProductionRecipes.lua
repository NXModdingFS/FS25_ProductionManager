-- ProductionRecipes.lua
-- Recipe catalogue + economics for the Profitability page.
--
-- Three kinds of recipe are compared side by side:
--   OWNED    - live recipes of the farm's production points
--   FOR_SALE - production points on the map nobody owns yet
--   SHOP     - production placeables from the shop (parsed once from their XML
--              and cached for the session, since reading them is not free)
--
-- Every recipe is reduced to per-cycle litres in and out, then valued:
--   inputs  at their opportunity value (ProductionPrices:getInputValue)
--   outputs at their sale value (current or seasonal peak, per setting)
--   running costs spread over the cycles of a month
-- and expressed both per 1000 L of the main output and per month.
--
-- Units: a production "month" is 24 production hours, whatever the save's days
-- per month. The live cyclesPerMonth / costsPerActiveMonth are already per month;
-- older hourly or per-minute figures convert with x24 / x1440 - never x days.

ProductionRecipes = {}

ProductionRecipes.SOURCE_OWNED    = 1
ProductionRecipes.SOURCE_FOR_SALE = 2
ProductionRecipes.SOURCE_SHOP     = 3

ProductionRecipes.SOURCE_KEYS = { "pi_recipeSource_owned", "pi_recipeSource_forSale", "pi_recipeSource_shop" }

ProductionRecipes.shopCatalog = nil   -- built lazily

-- ------------------------------------------------------------------
-- Collect
-- ------------------------------------------------------------------

local function copyAmounts(list)
    local result = {}
    for _, entry in pairs(list or {}) do
        if entry.type ~= nil and (entry.amount or 0) > 0 then
            table.insert(result, { fillTypeIndex = entry.type, amount = entry.amount })
        end
    end
    return result
end

local toMonthly = ProductionUtil.monthlyRate

local function isForSale(point, farmId)
    local owner = point.ownerFarmId
    if owner == farmId then return false end
    -- A point owned by another real farm is somebody else's business, not for sale
    if ProductionUtil.isRealFarm(owner) and g_farmManager ~= nil
       and ProductionUtil.call(g_farmManager, "getFarmById", owner) ~= nil then
        return false
    end
    return true
end

local function collectLive(farmId, list)
    local chain = g_currentMission ~= nil and g_currentMission.productionChainManager or nil
    if chain == nil then return end

    for _, point in pairs(chain.productionPoints or {}) do
        local source = nil
        if point.ownerFarmId == farmId then
            source = ProductionRecipes.SOURCE_OWNED
        elseif isForSale(point, farmId) then
            source = ProductionRecipes.SOURCE_FOR_SALE
        end

        if source ~= nil then
            -- Shared capacity: enabled recipes split the building's throughput
            local throughputFactor = 1
            if point.sharedThroughputCapacity then
                local enabled = 0
                for _, production in pairs(point.productions or {}) do
                    if ProductionPoint ~= nil and production.status ~= ProductionPoint.PROD_STATUS.INACTIVE then
                        enabled = enabled + 1
                    end
                end
                throughputFactor = 1 / math.max(1, enabled)
            end

            for _, production in pairs(point.productions or {}) do
                table.insert(list, {
                    source = source,
                    facilityName = ProductionUtil.call(point, "getName") or "?",
                    recipeName = production.name or "?",
                    inputs = copyAmounts(production.inputs),
                    outputs = copyAmounts(production.outputs),
                    cyclesPerMonth = toMonthly(production.cyclesPerMonth, production.cyclesPerHour,
                        production.cyclesPerMinute) or 0,
                    costsPerMonth = toMonthly(production.costsPerActiveMonth, production.costsPerActiveHour) or 0,
                    throughputFactor = throughputFactor,
                    status = production.status,
                    production = production,
                    productionPoint = point,
                    price = ProductionUtil.call(point.owningPlaceable, "getPrice"),
                })
            end
        end
    end
end

-- Reads "<fillType names>" + amount entries under a production XML key
local function readAmounts(xmlFile, key, customEnv)
    local result = {}
    local i = 0
    while true do
        local entryKey = string.format("%s(%d)", key, i)
        if not hasXMLProperty(xmlFile, entryKey) then break end
        local names = getXMLString(xmlFile, entryKey .. "#fillType") or ""
        local amount = getXMLFloat(xmlFile, entryKey .. "#amount") or 0
        for name in string.gmatch(names, "%S+") do
            local index = ProductionUtil.fillTypeIndexByName(name)
            if index ~= nil and amount > 0 then
                table.insert(result, { fillTypeIndex = index, amount = amount })
                break   -- alternatives share the slot; value the first known one
            end
        end
        i = i + 1
    end
    return result
end

local function readProductionPoint(xmlFile, pointKey, storeItem, list)
    local j = 0
    while true do
        local key = string.format("%s.productions.production(%d)", pointKey, j)
        if not hasXMLProperty(xmlFile, key) then break end

        local cyclesPerMonth = toMonthly(getXMLFloat(xmlFile, key .. "#cyclesPerMonth"),
            getXMLFloat(xmlFile, key .. "#cyclesPerHour"), getXMLFloat(xmlFile, key .. "#cyclesPerMinute"))
        local costsPerMonth = toMonthly(getXMLFloat(xmlFile, key .. "#costsPerActiveMonth"),
            getXMLFloat(xmlFile, key .. "#costsPerActiveHour"))

        local outputs = readAmounts(xmlFile, key .. ".outputs.output", storeItem.customEnvironment)
        local rawName = getXMLString(xmlFile, key .. "#name")
        local recipeName = nil
        if rawName ~= nil then
            local ok, converted = pcall(g_i18n.convertText, g_i18n, rawName, storeItem.customEnvironment)
            recipeName = ok and converted or rawName
        end
        -- Some names are templates the game fills in at runtime ("%s %s"); we
        -- can't, so name the recipe after what it produces instead
        if (recipeName == nil or string.find(recipeName, "%%") ~= nil) and #outputs > 0 then
            local titles = {}
            for _, output in ipairs(outputs) do
                table.insert(titles, ProductionUtil.fillTypeTitle(output.fillTypeIndex))
            end
            recipeName = table.concat(titles, ", ")
        end

        table.insert(list, {
            source = ProductionRecipes.SOURCE_SHOP,
            facilityName = storeItem.name or "?",
            recipeName = recipeName or "?",
            inputs = readAmounts(xmlFile, key .. ".inputs.input", storeItem.customEnvironment),
            outputs = outputs,
            cyclesPerMonth = cyclesPerMonth or 0,
            costsPerMonth = costsPerMonth or 0,
            storeItem = storeItem,
            price = storeItem.price,
        })
        j = j + 1
    end
end

local function isPlaceableStoreItem(storeItem)
    if storeItem == nil or storeItem.xmlFilename == nil then return false end
    if storeItem.showInStore == false then return false end
    local species = storeItem.species
    return species == "placeable" or (StoreSpecies ~= nil and species == StoreSpecies.PLACEABLE)
end

function ProductionRecipes:buildShopCatalog()
    local catalog = {}
    if g_storeManager == nil then
        self.shopCatalog = catalog
        return catalog
    end

    for _, storeItem in pairs(g_storeManager:getItems() or {}) do
        if isPlaceableStoreItem(storeItem) then
            local ok, err = pcall(function()
                local xmlFile = loadXMLFile("nxProductionsShopItem", storeItem.xmlFilename)
                if xmlFile == nil or xmlFile == 0 then return end
                if hasXMLProperty(xmlFile, "placeable.productionPoint") then
                    readProductionPoint(xmlFile, "placeable.productionPoint", storeItem, catalog)
                end
                local i = 0
                while true do
                    local key = string.format("placeable.productionPoints.productionPoint(%d)", i)
                    if not hasXMLProperty(xmlFile, key) then break end
                    readProductionPoint(xmlFile, key, storeItem, catalog)
                    i = i + 1
                end
                delete(xmlFile)
            end)
            if not ok then
                Logging.warning("[ProductionsManager] Skipped shop item '%s' (%s)", tostring(storeItem.xmlFilename), tostring(err))
            end
        end
    end

    self.shopCatalog = catalog
    return catalog
end

-- ------------------------------------------------------------------
-- Economics
-- ------------------------------------------------------------------

-- Fills entry.economics.
--   stock: { [fillTypeIndex] = litres } held by the farm (inputs it has none of are
--          priced at their purchase cost), or nil when unknown.
-- A recipe whose main product has no known price is marked incomplete and left out
-- of rankings rather than valued at a guess; by-products without a price count as 0.
-- Inputs that only have a base price are marked estimated.
function ProductionRecipes:evaluate(entry, stock)
    local eco = { inputCost = 0, outputValue = 0, estimated = false, incomplete = false }

    for _, input in ipairs(entry.inputs) do
        local inStock = nil
        if stock ~= nil then inStock = (stock[input.fillTypeIndex] or 0) > 0 end
        local price, estimated = ProductionPrices:getInputValue(input.fillTypeIndex, inStock)
        input.pricePerLiter = price or 0
        input.cost = input.amount * input.pricePerLiter
        eco.inputCost = eco.inputCost + input.cost
        eco.estimated = eco.estimated or estimated
    end

    local primary = nil
    for _, output in ipairs(entry.outputs) do
        local price, estimated = ProductionPrices:getSaleValue(output.fillTypeIndex)
        local byproduct = ProductionUtil.isByproduct(output.fillTypeIndex)
        if estimated then
            if byproduct then price = 0 end
            output.unpriced = true
        end
        output.pricePerLiter = price or 0
        output.value = output.amount * output.pricePerLiter
        eco.outputValue = eco.outputValue + output.value
        if not byproduct and (primary == nil or output.value > primary.value) then
            primary = output
        end
    end
    primary = primary or entry.outputs[1]
    eco.primary = primary
    eco.incomplete = primary == nil or primary.unpriced == true

    -- Shared-capacity buildings split their throughput between enabled recipes
    local factor = entry.throughputFactor or 1
    local cycles = (entry.cyclesPerMonth or 0) * factor
    local runningPerMonth = entry.costsPerMonth or 0
    eco.throughputFactor = factor
    eco.cyclesPerMonth = cycles
    eco.runningPerMonth = runningPerMonth
    eco.runningPerCycle = cycles > 0 and runningPerMonth / cycles or 0

    eco.profitPerCycle = eco.outputValue - eco.inputCost - eco.runningPerCycle
    eco.profitPerMonth = cycles > 0 and eco.profitPerCycle * cycles or -runningPerMonth

    if primary ~= nil and primary.amount > 0 then
        local scale = 1000 / primary.amount
        eco.cost1000 = (eco.inputCost + eco.runningPerCycle) * scale
        eco.value1000 = eco.outputValue * scale
        eco.profit1000 = eco.profitPerCycle * scale
        eco.primaryPerMonth = primary.amount * cycles
    end

    entry.economics = eco
    return eco
end

-- All recipes, evaluated. includeShop builds the shop catalogue on first use.
function ProductionRecipes:getRecipes(farmId, includeShop)
    local list = {}
    collectLive(farmId, list)

    if includeShop then
        local catalog = self.shopCatalog or self:buildShopCatalog()
        for _, template in ipairs(catalog) do
            -- Shallow copy so per-call economics never leak into the cache
            local entry = {}
            for k, v in pairs(template) do entry[k] = v end
            entry.inputs, entry.outputs = {}, {}
            for _, input in ipairs(template.inputs) do
                table.insert(entry.inputs, { fillTypeIndex = input.fillTypeIndex, amount = input.amount })
            end
            for _, output in ipairs(template.outputs) do
                table.insert(entry.outputs, { fillTypeIndex = output.fillTypeIndex, amount = output.amount })
            end
            table.insert(list, entry)
        end
    end

    -- One stock scan for the whole list decides sale vs purchase price per input
    local stock = nil
    local okStock, raw = pcall(ProductionStock.scan, ProductionStock, farmId)
    if okStock and type(raw) == "table" then
        stock = {}
        for fillTypeIndex, product in pairs(raw) do stock[fillTypeIndex] = product.liters end
    end

    for _, entry in ipairs(list) do
        self:evaluate(entry, stock)
    end
    return list
end

-- Best ways to turn fillTypeIndex into something worth more than selling it raw.
-- For every recipe that consumes it: value created per litre of this input, after
-- every other input and running cost, compared with its direct sale price.
-- Returns up to maxResults { entry, perLiter, uplift }, best first, filtered by
-- the advice threshold (per 1000 L).
function ProductionRecipes:getBestUses(recipes, fillTypeIndex, maxResults)
    local direct = ProductionPrices:getBestSell(fillTypeIndex) or 0
    local threshold = (ProductionSettings ~= nil and ProductionSettings.insightsAdviceThreshold or 0) / 1000
    local results = {}

    for _, entry in ipairs(recipes) do
        local eco = entry.economics
        local own = nil
        for _, input in ipairs(entry.inputs) do
            if input.fillTypeIndex == fillTypeIndex then own = input break end
        end
        if own ~= nil and eco ~= nil and not eco.incomplete and own.amount > 0 then
            local otherCosts = eco.inputCost - own.cost + eco.runningPerCycle
            local perLiter = (eco.outputValue - otherCosts) / own.amount
            local uplift = perLiter - direct
            if uplift >= threshold then
                table.insert(results, { entry = entry, perLiter = perLiter, uplift = uplift })
            end
        end
    end

    table.sort(results, function(a, b) return a.uplift > b.uplift end)
    while #results > (maxResults or 3) do table.remove(results) end
    return results
end

function ProductionRecipes.sourceTitle(source)
    return g_i18n:getText(ProductionRecipes.SOURCE_KEYS[source] or "pi_recipeSource_owned")
end
