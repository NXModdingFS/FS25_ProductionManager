-- ProductionTasks.lua
-- "This month" to-do list for the menu's This Month tab.
-- Rebuilt every few seconds from the other Productions Insights modules; each task is
--   { category = <key>, text = <string>, severity = 1 info | 2 warning | 3 urgent }
-- and the list is ordered most urgent first.

ProductionTasks = {}

ProductionTasks.INTERVAL = 5000   -- ms between rebuilds
ProductionTasks.MIN_SELL_LITERS = 1000

ProductionTasks.INFO, ProductionTasks.WARNING, ProductionTasks.URGENT = 1, 2, 3

ProductionTasks.tasks = {}
ProductionTasks.timer = ProductionTasks.INTERVAL

local function setting(name, fallback)
    if ProductionSettings == nil or ProductionSettings[name] == nil then return fallback end
    return ProductionSettings[name]
end

local function isOnField(x, z)
    if x == nil or g_fieldManager == nil then return true end
    local field = ProductionUtil.call(g_fieldManager, "getFieldAtWorldPosition", x, z)
    if field ~= nil then return true end
    -- Without a lookup we cannot tell; count the bale rather than hide it
    return g_fieldManager.getFieldAtWorldPosition == nil
end

function ProductionTasks:rebuild()
    local tasks = {}
    local farmId = ProductionUtil.getFarmId()
    if not ProductionUtil.isRealFarm(farmId) then
        self.tasks = tasks
        return tasks
    end

    local function add(category, severity, text)
        table.insert(tasks, { category = category, severity = severity, text = text })
    end

    -- Price alerts and products at their seasonal peak
    local alerted = {}
    if ProductionUserData ~= nil then
        ProductionUserData:checkAlerts(true)
        for name, hit in pairs(ProductionUserData:getTriggeredAlerts()) do
            alerted[hit.fillTypeIndex] = true
            add("sell", self.URGENT, ProductionUtil.text("pi_task_alert", ProductionUtil.fillTypeTitle(hit.fillTypeIndex),
                ProductionUtil.formatPer1000(hit.price), hit.station or "?"))
        end
    end

    local okStock, raw = pcall(ProductionStock.scan, ProductionStock, farmId)
    if okStock then
        for fillTypeIndex, product in pairs(raw) do
            if not alerted[fillTypeIndex] and product.liters >= self.MIN_SELL_LITERS then
                local peak = ProductionPrices:getPeak(fillTypeIndex)
                if peak ~= nil and peak.isNow then
                    add("sell", self.INFO, ProductionUtil.text("pi_task_peak", ProductionUtil.fillTypeTitle(fillTypeIndex),
                        ProductionUtil.formatLiters(product.liters)))
                end
            end
        end
    end

    -- Bales left lying on fields
    local bales = {}
    ProductionStock.forEachBale(farmId, function(bale)
        local x, z = nil, nil
        if bale.nodeId ~= nil and getWorldTranslation ~= nil then
            local ok, bx, _, bz = pcall(getWorldTranslation, bale.nodeId)
            if ok then x, z = bx, bz end
        end
        if isOnField(x, z) then
            local fillTypeIndex = bale.fillType or ProductionUtil.call(bale, "getFillType")
            if fillTypeIndex ~= nil then bales[fillTypeIndex] = (bales[fillTypeIndex] or 0) + 1 end
        end
    end)
    for fillTypeIndex, count in pairs(bales) do
        add("collect", self.INFO, ProductionUtil.text("pi_task_bales", count, ProductionUtil.fillTypeTitle(fillTypeIndex)))
    end

    -- Full vehicles and trailers
    local minSize = setting("insightsVehicleFullSize", 5000)
    local vehicleSystem = g_currentMission.vehicleSystem
    for _, vehicle in pairs(vehicleSystem ~= nil and vehicleSystem.vehicles or {}) do
        local spec = vehicle.spec_fillUnit
        local isPallet = ProductionPalletData ~= nil and ProductionPalletData.isPallet ~= nil and ProductionPalletData.isPallet(vehicle)
        if vehicle.ownerFarmId == farmId and spec ~= nil and not isPallet and vehicle.spec_motorized == nil then
            for index, fillUnit in pairs(spec.fillUnits or {}) do
                local capacity = fillUnit.capacity or 0
                local level = fillUnit.fillLevel or 0
                if capacity >= minSize and level >= capacity * 0.98 then
                    add("vehicle", self.WARNING, ProductionUtil.text("pi_task_vehicle",
                        ProductionUtil.call(vehicle, "getName") or "?", ProductionUtil.fillTypeTitle(fillUnit.fillType),
                        ProductionUtil.formatLiters(level)))
                    break
                end
            end
        end
    end

    -- Animal pens: food / water / straw below the threshold, poor health
    local animalThreshold = setting("insightsAnimalThreshold", 20) / 100
    local okPens, pens = pcall(ProductionAnimals.getPens, ProductionAnimals, farmId)
    if okPens then
        for _, pen in ipairs(pens) do
            if pen.numAnimals > 0 then
                local supplies = {
                    { key = "pi_supply_food", data = pen.food },
                    { key = "pi_supply_water", data = (not pen.autoWater) and pen.water or nil },
                    { key = "pi_supply_straw", data = pen.straw },
                }
                for _, supply in ipairs(supplies) do
                    local data = supply.data
                    if data ~= nil and (data.fraction <= animalThreshold or data.level <= 0) then
                        local severity = data.level <= 0 and self.URGENT or self.WARNING
                        add("animals", severity, ProductionUtil.text("pi_task_supply", pen.name,
                            g_i18n:getText(supply.key), ProductionUtil.formatPercent(data.fraction)))
                    end
                end
                if pen.lowestHealth ~= nil and pen.lowestHealth < 50 then
                    add("animals", self.URGENT, ProductionUtil.text("pi_task_health", pen.name))
                end
            end
        end
    end

    -- Productions: low inputs on enabled recipes, outputs filling up
    local lowInput = setting("lowInputThreshold", 20) / 100
    local highOutput = setting("highOutputThreshold", 80) / 100
    local chain = g_currentMission.productionChainManager
    for _, point in pairs(chain ~= nil and chain.productionPoints or {}) do
        if point.ownerFarmId == farmId and point.storage ~= nil then
            local name = ProductionUtil.call(point, "getName") or "?"
            local lowSeen, fullSeen = {}, {}
            for _, production in pairs(point.productions or {}) do
                local enabled = production.status ~= nil and ProductionPoint ~= nil
                    and production.status ~= ProductionPoint.PROD_STATUS.INACTIVE
                if enabled then
                    for _, input in pairs(production.inputs or {}) do
                        local capacity = point.storage:getCapacity(input.type)
                        if capacity > 0 and not lowSeen[input.type]
                           and point.storage:getFillLevel(input.type) / capacity <= lowInput then
                            lowSeen[input.type] = true
                            add("production", self.WARNING, ProductionUtil.text("pi_task_lowInput", name,
                                ProductionUtil.fillTypeTitle(input.type),
                                ProductionUtil.formatPercent(point.storage:getFillLevel(input.type) / capacity)))
                        end
                    end
                    for _, output in pairs(production.outputs or {}) do
                        local capacity = point.storage:getCapacity(output.type)
                        if capacity > 0 and not fullSeen[output.type]
                           and point.storage:getFillLevel(output.type) / capacity >= highOutput then
                            fullSeen[output.type] = true
                            add("production", self.URGENT, ProductionUtil.text("pi_task_fullOutput", name,
                                ProductionUtil.fillTypeTitle(output.type),
                                ProductionUtil.formatPercent(point.storage:getFillLevel(output.type) / capacity)))
                        end
                    end
                end
            end
        end
    end

    table.sort(tasks, function(a, b)
        if a.severity ~= b.severity then return a.severity > b.severity end
        if a.category ~= b.category then return a.category < b.category end
        return a.text < b.text
    end)

    self.tasks = tasks
    return tasks
end

function ProductionTasks:update(dt)
    self.timer = self.timer + dt
    if self.timer < self.INTERVAL then return end
    self.timer = 0
    local ok, err = pcall(self.rebuild, self)
    if not ok then
        Logging.warning("[ProductionsManager] Task rebuild failed (%s)", tostring(err))
    end
end

function ProductionTasks:getTasks()
    return self.tasks
end

function ProductionTasks.categoryTitle(category)
    return g_i18n:getText("pi_taskCat_" .. category)
end

function ProductionTasks:reset()
    self.tasks = {}
    self.timer = self.INTERVAL
end
