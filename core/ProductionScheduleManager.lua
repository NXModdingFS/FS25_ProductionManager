-- ProductionScheduleManager.lua
-- Core scheduling engine for Production Manager.
-- Manages per-production month schedules, persists to savegame XML,
-- and enforces schedules server-side on period change.

ProductionScheduleManager = {}

ProductionScheduleManager.STATUS_ACTIVE   = "active"
ProductionScheduleManager.STATUS_INACTIVE = "inactive"

ProductionScheduleManager.modDir  = g_currentModDirectory
ProductionScheduleManager.modName = g_currentModName

-- UI context: written by ProductionDlgFrame before entering the schedule view,
-- read back by commitFromUI() when the user presses OK.
ProductionScheduleManager.ctxPointKey        = nil
ProductionScheduleManager.ctxProdId          = nil
ProductionScheduleManager.ctxProdName        = nil
ProductionScheduleManager.ctxMonths          = nil   -- table: [1..12] = true/nil
ProductionScheduleManager.ctxScheduleEnabled = nil   -- bool

-- Persistent data: data[pointKey][prodId] = { months = {}, scheduleEnabled = bool }
ProductionScheduleManager.data = {}

-- Runtime lookup: runtime[pointKey] = productionPoint
ProductionScheduleManager.runtime = {}

ProductionScheduleManager.lastPeriod = nil

local function resolvePeriod()
    if g_currentMission == nil or g_currentMission.environment == nil then return nil end
    local env = g_currentMission.environment
    return env.currentPeriod or env.currentMonth
end

local function getPointKey(pp)
    if pp == nil then return nil end
    local op = pp.owningPlaceable
    if op ~= nil then
        if op.uniqueId ~= nil then return tostring(op.uniqueId) end
        if op.id ~= nil then
            if type(op.id) == "number" then return tostring(op.id) end
            local num = tonumber(op.id)
            if num ~= nil then return tostring(num) end
        end
    end
    if pp.uniqueId ~= nil then return tostring(pp.uniqueId) end
    if pp.id ~= nil then
        local num = tonumber(pp.id)
        if num ~= nil then return tostring(num) end
    end
    return tostring(pp)
end

local function isAllowedInPeriod(monthTable, period)
    if monthTable == nil then return true end
    local any = false
    for _ in pairs(monthTable) do any = true; break end
    if not any then return true end
    return monthTable[period] == true
end

local function normalizeEntry(rawEntry)
    local entry = { months = {}, scheduleEnabled = false }
    if rawEntry == nil then return entry end
    if type(rawEntry) == "table" then
        if type(rawEntry.months) == "table" then
            for k, v in pairs(rawEntry.months) do
                local m = tonumber(k)
                if m ~= nil and m >= 1 and m <= 12 and v == true then
                    entry.months[m] = true
                end
            end
        end
        if rawEntry.scheduleEnabled ~= nil then
            entry.scheduleEnabled = (rawEntry.scheduleEnabled == true)
        end
    end
    return entry
end

local function getModSettingsPath()
    return Utils.getFilename("modSettings/ProductionSettings.xml", getUserProfileAppPath())
end

function ProductionScheduleManager:save()
    local path = getModSettingsPath()

    createFolder(getUserProfileAppPath() .. "modSettings/")

    local xmlFile
    if fileExists(path) then
        xmlFile = loadXMLFile("ProductionScheduleXML", path)
    else
        xmlFile = createXMLFile("ProductionScheduleXML", path, "production")
    end

    if xmlFile == nil or xmlFile == 0 then
        print("[ProductionManager] Schedule save failed - could not open modSettings XML")
        return false
    end

    local i = 0
    for pointKey, prodTable in pairs(self.data) do
        local hasAny = false
        for _ in pairs(prodTable) do hasAny = true; break end
        if hasAny then
            local pBase = string.format("production.schedules.point(%d)", i)
            setXMLString(xmlFile, pBase .. "#key", pointKey)
            local j = 0
            for prodId, rawEntry in pairs(prodTable) do
                local entry = normalizeEntry(rawEntry)
                local eBase = string.format("%s.production(%d)", pBase, j)
                setXMLString(xmlFile, eBase .. "#id",              tostring(prodId))
                setXMLBool(xmlFile,   eBase .. "#scheduleEnabled", entry.scheduleEnabled)
                local k = 0
                for m, enabled in pairs(entry.months) do
                    if enabled == true then
                        setXMLInt(xmlFile, string.format("%s.month(%d)#n", eBase, k), m)
                        k = k + 1
                    end
                end
                j = j + 1
            end
            i = i + 1
        end
    end

    saveXMLFile(xmlFile)
    delete(xmlFile)
    return true
end

function ProductionScheduleManager:load()
    local path = getModSettingsPath()
    if not fileExists(path) then return end

    local xmlFile = loadXMLFile("ProductionScheduleXML", path)
    if xmlFile == nil or xmlFile == 0 then return end

    self.data = {}
    local i = 0
    while true do
        local pBase = string.format("production.schedules.point(%d)", i)
        if not hasXMLProperty(xmlFile, pBase) then break end
        local key = getXMLString(xmlFile, pBase .. "#key")
        if key ~= nil then
            self.data[key] = {}
            local j = 0
            while true do
                local eBase = string.format("%s.production(%d)", pBase, j)
                if not hasXMLProperty(xmlFile, eBase) then break end
                local prodId = getXMLString(xmlFile, eBase .. "#id")
                if prodId ~= nil then
                    local schedEnabled = getXMLBool(xmlFile, eBase .. "#scheduleEnabled")
                    if schedEnabled == nil then schedEnabled = true end
                    self.data[key][prodId] = { months = {}, scheduleEnabled = schedEnabled }
                    local k = 0
                    while true do
                        local mKey = string.format("%s.month(%d)", eBase, k)
                        if not hasXMLProperty(xmlFile, mKey) then break end
                        local month = getXMLInt(xmlFile, mKey .. "#n")
                        if month ~= nil then self.data[key][prodId].months[month] = true end
                        k = k + 1
                    end
                end
                j = j + 1
            end
        end
        i = i + 1
    end
    delete(xmlFile)
    print("[ProductionManager] Schedule data loaded from modSettings/ProductionSettings.xml")
end

function ProductionScheduleManager:rebuildRuntimeMap()
    self.runtime = {}
    if g_currentMission == nil or g_currentMission.productionChainManager == nil then return end
    for _, pp in pairs(g_currentMission.productionChainManager.productionPoints) do
        local key = getPointKey(pp)
        if key ~= nil then
            self.runtime[key] = pp
            -- Legacy aliases so old saves still resolve
            if pp.uniqueId ~= nil then
                local k2 = tostring(pp.uniqueId)
                if self.runtime[k2] == nil then self.runtime[k2] = pp end
            end
            if pp.id ~= nil then
                local k3 = tostring(pp.id)
                if self.runtime[k3] == nil then self.runtime[k3] = pp end
            end
        end
    end
end

function ProductionScheduleManager:applyAll(period)
    if period == nil then return end
    for pointKey, prodTable in pairs(self.data) do
        local pp = self.runtime[pointKey]
        if pp ~= nil and prodTable ~= nil then
            for storedProdId, rawEntry in pairs(prodTable) do
                local entry = normalizeEntry(rawEntry)
                if entry.scheduleEnabled then
                    local enable = isAllowedInPeriod(entry.months, period)
                    pp:setProductionState(storedProdId, enable, true)
                    -- Sync isEnabled field directly as a safety net
                    if type(pp.productionsIdToObj) == "table" and pp.productionsIdToObj[storedProdId] ~= nil then
                        pp.productionsIdToObj[storedProdId].isEnabled = enable
                    end
                    if pp.updateActiveProductions ~= nil then
                        pp:updateActiveProductions()
                    elseif pp.updateProductions ~= nil then
                        pp:updateProductions()
                    end
                end
            end
        end
    end
end

function ProductionScheduleManager:getPointKey(pp)
    return getPointKey(pp)
end

function ProductionScheduleManager:getCurrentPeriod()
    return resolvePeriod()
end

function ProductionScheduleManager:getEntry(pointKey, prodId)
    if self.data == nil or pointKey == nil or prodId == nil then return nil end
    local pk = tostring(pointKey)
    local id = tostring(prodId)
    if self.data[pk] == nil then return nil end
    return normalizeEntry(self.data[pk][id])
end


function ProductionScheduleManager:commitFromUI()
    local pointKey    = self.ctxPointKey
    local prodId      = self.ctxProdId
    local months      = self.ctxMonths or {}
    local schedEnabled = (self.ctxScheduleEnabled == true)

    if pointKey == nil or prodId == nil then
        print("[ProductionManager] commitFromUI: missing context, aborting")
        return
    end

    if self.data[pointKey] == nil then self.data[pointKey] = {} end

    self.data[pointKey][tostring(prodId)] = {
        months         = months,
        scheduleEnabled = schedEnabled
    }

    -- Prune empty point entries
    local empty = true
    for _ in pairs(self.data[pointKey]) do empty = false; break end
    if empty then self.data[pointKey] = nil end

    self:save()
    self:rebuildRuntimeMap()
    self:applyAll(resolvePeriod())
end

function ProductionScheduleManager:_installSaveHooks()
    if self._saveHooksInstalled then return end
    self._saveHooksInstalled = true

    if Mission00 ~= nil and Mission00.saveToXMLFile ~= nil then
        Mission00.saveToXMLFile = Utils.appendedFunction(Mission00.saveToXMLFile, function()
            ProductionScheduleManager:save()
        end)
    end
end

function ProductionScheduleManager:loadMap(name)
    self:load()
    self:_installSaveHooks()
    self:rebuildRuntimeMap()
    self.lastPeriod = nil
    print("[ProductionManager] ProductionScheduleManager loaded")
end

function ProductionScheduleManager:loadMapFinished()
    local period = resolvePeriod()
    self.lastPeriod = period
    self:rebuildRuntimeMap()
    self:applyAll(period)
end

function ProductionScheduleManager:update(dt)
    -- Only enforce on the server
    if g_currentMission == nil or not g_currentMission:getIsServer() then return end

    local period = resolvePeriod()
    if period ~= nil and period ~= self.lastPeriod then
        self.lastPeriod = period
        self:rebuildRuntimeMap()
        self:applyAll(period)
        print("[ProductionManager] Schedule enforced for period " .. tostring(period))
    end
end

function ProductionScheduleManager:deleteMap()
    self.data    = {}
    self.runtime = {}
end

addModEventListener(ProductionScheduleManager)