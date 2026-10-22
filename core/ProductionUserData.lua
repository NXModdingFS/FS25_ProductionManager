-- ProductionUserData.lua
-- The player's own Productions Insights choices, kept per savegame and per player
-- (never synced, so every player in multiplayer has their own):
--   * price alerts - per product: notify when it reaches its best month
--
-- Stored in modSettings/FS25_NXProductions/insights_<save>.xml and written on every
-- change (the file is tiny, and clients have no savegame folder to hook into).

ProductionUserData = {}

ProductionUserData.alerts = {}          -- [fillTypeName] = {}
ProductionUserData.triggered = {}       -- [fillTypeName] = { fillTypeIndex, price, station } (runtime)
ProductionUserData.notifiedDay = {}     -- [fillTypeName] = day notified (runtime)

local function getFilePath()
    local info = g_currentMission ~= nil and g_currentMission.missionInfo or nil
    local key = "default"
    if info ~= nil and info.savegameDirectory ~= nil then
        key = info.savegameDirectory:match("([^/\\]+)$") or key
    elseif info ~= nil and info.mapId ~= nil then
        key = "mp_" .. tostring(info.mapId)
    end
    key = key:gsub("[^%w_%-]", "_")
    local folder = getUserProfileAppPath() .. "modSettings/FS25_NXProductions/"
    return folder, folder .. "insights_" .. key .. ".xml"
end

function ProductionUserData:load()
    self.alerts = {}
    local _, path = getFilePath()
    if not fileExists(path) then return end

    local xmlFile = loadXMLFile("ProductionUserData", path)
    if xmlFile == nil or xmlFile == 0 then return end

    local i = 0
    while true do
        local key = string.format("insights.alerts.alert(%d)", i)
        if not hasXMLProperty(xmlFile, key) then break end
        local name = getXMLString(xmlFile, key .. "#fillType")
        if name ~= nil then
            self.alerts[name] = {}
        end
        i = i + 1
    end

    delete(xmlFile)
end

function ProductionUserData:save()
    local folder, path = getFilePath()
    createFolder(getUserProfileAppPath() .. "modSettings/")
    createFolder(folder)

    local xmlFile = createXMLFile("ProductionUserData", path, "insights")
    if xmlFile == nil or xmlFile == 0 then
        Logging.warning("[ProductionsManager] Could not write %s", path)
        return
    end

    local i = 0
    for name, _ in pairs(self.alerts) do
        setXMLString(xmlFile, string.format("insights.alerts.alert(%d)#fillType", i), name)
        i = i + 1
    end

    saveXMLFile(xmlFile)
    delete(xmlFile)
end

-- ------------------------------------------------------------------
-- Alerts
-- ------------------------------------------------------------------

function ProductionUserData:getAlert(fillTypeName)
    if fillTypeName == nil then return nil end
    return self.alerts[fillTypeName]
end

function ProductionUserData:setAlert(fillTypeName)
    if fillTypeName == nil then return end
    self.alerts[fillTypeName] = {}
    self.notifiedDay[fillTypeName] = nil
    self:save()
    self:checkAlerts(false)
end

function ProductionUserData:clearAlert(fillTypeName)
    if fillTypeName == nil then return end
    self.alerts[fillTypeName] = nil
    self.triggered[fillTypeName] = nil
    self:save()
end

function ProductionUserData.alertText(alert)
    if alert == nil then return nil end
    return ProductionUtil.text("pi_alert_peak")
end

-- Re-evaluates every alert: it fires while the product is in its best month.
-- With notify, sends one side notification per product per in-game day.
function ProductionUserData:checkAlerts(notify)
    local triggered = {}
    local env = g_currentMission ~= nil and g_currentMission.environment or nil
    local day = env ~= nil and (env.currentMonotonicDay or env.currentDay) or 0

    for name, _ in pairs(self.alerts) do
        local fillTypeIndex = ProductionUtil.fillTypeIndexByName(name)
        local price, station = ProductionPrices:getBestSell(fillTypeIndex)
        local peak = price ~= nil and ProductionPrices:getPeak(fillTypeIndex) or nil
        if peak ~= nil and peak.isNow then
            triggered[name] = { fillTypeIndex = fillTypeIndex, price = price, station = station }
            if notify and self.notifiedDay[name] ~= day and ProductionNotifications ~= nil then
                self.notifiedDay[name] = day
                ProductionNotifications.showNotification(
                    ProductionUtil.text("pi_notify_alert", ProductionUtil.fillTypeTitle(fillTypeIndex),
                        ProductionUtil.formatPer1000(price), station or "?"),
                    FSBaseMission.INGAME_NOTIFICATION_OK)
            end
        end
    end
    self.triggered = triggered
end

function ProductionUserData:getTriggeredAlerts()
    return self.triggered
end

function ProductionUserData:reset()
    self.alerts, self.triggered, self.notifiedDay = {}, {}, {}
end
