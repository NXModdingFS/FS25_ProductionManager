-- ProductionRuntime.lua
-- Lifecycle glue for the Productions Insights and Logistics modules: one mod event
-- listener that loads per-save data, drives the background updates, reacts to the
-- in-game clock and syncs joining clients.

ProductionRuntime = {}

function ProductionRuntime:loadMap(name)
    if ProductionGameplay ~= nil then
        ProductionGameplay:installHooks()
    end
end

-- Runs once the mission is fully loaded (savegame data and placeables available)
function ProductionRuntime:onMissionLoaded()
    if ProductionUserData ~= nil then ProductionUserData:load() end
    if ProductionLogistics ~= nil and ProductionUtil.isServer() then ProductionLogistics:loadFromSavegame() end

    if g_messageCenter ~= nil and MessageType ~= nil then
        g_messageCenter:subscribe(MessageType.HOUR_CHANGED, self.onHourChanged, self)
        g_messageCenter:subscribe(MessageType.PERIOD_CHANGED, self.onPeriodChanged, self)
    end
end

function ProductionRuntime:onHourChanged()
    if ProductionLogistics ~= nil then
        local ok, err = pcall(ProductionLogistics.run, ProductionLogistics)
        if not ok then Logging.warning("[ProductionsManager] Logistics run failed (%s)", tostring(err)) end
    end
    if ProductionUserData ~= nil then ProductionUserData:checkAlerts(true) end
end

function ProductionRuntime:onPeriodChanged()
    if ProductionLogistics ~= nil then ProductionLogistics:onPeriodChanged() end
end

function ProductionRuntime:update(dt)
    if g_currentMission == nil then return end
    if ProductionTasks ~= nil then ProductionTasks:update(dt) end
end

function ProductionRuntime:deleteMap()
    if g_messageCenter ~= nil then g_messageCenter:unsubscribeAll(self) end
    if ProductionTasks ~= nil then ProductionTasks:reset() end
    if ProductionUserData ~= nil then ProductionUserData:reset() end
    if ProductionGameplay ~= nil then ProductionGameplay:reset() end
    if ProductionLogistics ~= nil then ProductionLogistics:reset() end
end

Mission00.loadMission00Finished = Utils.appendedFunction(Mission00.loadMission00Finished, function()
    ProductionRuntime:onMissionLoaded()
end)

-- Logistics rules live in the savegame folder next to the base game's own files
Mission00.saveToXMLFile = Utils.appendedFunction(Mission00.saveToXMLFile, function()
    if ProductionLogistics ~= nil and ProductionUtil.isServer() then
        ProductionLogistics:saveToSavegame()
    end
end)

-- A joining player gets the host's synced settings and logistics rules
if FSBaseMission ~= nil and FSBaseMission.sendInitialClientState ~= nil then
    FSBaseMission.sendInitialClientState = Utils.appendedFunction(FSBaseMission.sendInitialClientState,
        function(mission, connection, user, farm)
            if connection == nil then return end
            if ProductionSettingsEvent ~= nil then
                connection:sendEvent(ProductionSettingsEvent.new())
            end
            if ProductionLogisticsSyncEvent ~= nil then
                connection:sendEvent(ProductionLogisticsSyncEvent.new())
            end
        end)
end

addModEventListener(ProductionRuntime)
