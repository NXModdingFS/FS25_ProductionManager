ProductionNotifications = {}

ProductionNotifications.cooldowns = {}
ProductionNotifications.COOLDOWN_TIME_SHORT = 30000
ProductionNotifications.COOLDOWN_TIME_LONG = 600000

ProductionNotifications.lastNotifications = {}

ProductionNotificationEvent = {}
ProductionNotificationEvent_mt = Class(ProductionNotificationEvent, Event)
InitEventClass(ProductionNotificationEvent, "ProductionNotificationEvent")

function ProductionNotificationEvent.emptyNew()
    local self = Event.new(ProductionNotificationEvent_mt)
    return self
end

function ProductionNotificationEvent.new(message, notificationType)
    local self = ProductionNotificationEvent.emptyNew()
    self.message = message
    self.notificationType = notificationType or FSBaseMission.INGAME_NOTIFICATION_INFO
    return self
end

function ProductionNotificationEvent:readStream(streamId, connection)
    self.message = streamReadString(streamId)
    self.notificationType = streamReadUInt8(streamId)
    self:run(connection)
end

function ProductionNotificationEvent:writeStream(streamId, connection)
    streamWriteString(streamId, self.message)
    streamWriteUInt8(streamId, self.notificationType)
end

function ProductionNotificationEvent:run(connection)
    if not connection:getIsServer() then
        ProductionNotifications.showNotification(self.message, self.notificationType)
    end
end

function ProductionNotifications.showNotification(message, notificationType, playSound)
    if not g_currentMission or not g_currentMission.hud then
        return
    end
    
    notificationType = notificationType or FSBaseMission.INGAME_NOTIFICATION_INFO
    
    local sound = nil
    if playSound ~= false then
        if notificationType == FSBaseMission.INGAME_NOTIFICATION_CRITICAL then
            sound = GuiSoundPlayer.SOUND_SAMPLES.NOTIFICATION
        elseif notificationType == FSBaseMission.INGAME_NOTIFICATION_OK then
            sound = GuiSoundPlayer.SOUND_SAMPLES.NOTIFICATION
        else
            sound = GuiSoundPlayer.SOUND_SAMPLES.NOTIFICATION
        end
    end
    
    local duration = ProductionSettings and ProductionSettings.notificationDuration or 5000
    
    g_currentMission.hud:addSideNotification(
        notificationType,
        message,
        duration,
        sound
    )
end

function ProductionNotifications.broadcastNotification(message, notificationType)
    if not g_server then
        return
    end
    
    ProductionNotifications.showNotification(message, notificationType)
    
    if g_currentMission.missionDynamicInfo.isMultiplayer then
        g_server:broadcastEvent(ProductionNotificationEvent.new(message, notificationType))
    end
end

function ProductionNotifications.isOnCooldown(key, currentTime, cooldownTime)
    if ProductionNotifications.cooldowns[key] then
        local elapsed = currentTime - ProductionNotifications.cooldowns[key]
        return elapsed < cooldownTime
    end
    return false
end

function ProductionNotifications.setCooldown(key, currentTime)
    ProductionNotifications.cooldowns[key] = currentTime
end

function ProductionNotifications.notifyProductionStarted(productionPoint, production)
    if not ProductionSettings or not ProductionSettings.notifySmartControl then
        return
    end
    
    if not productionPoint or productionPoint.ownerFarmId ~= g_currentMission:getFarmId() then
        return
    end
    
    local currentTime = g_currentMission.time
    local key = string.format("start_%s_%s", tostring(productionPoint), production.id)
    
    if ProductionNotifications.isOnCooldown(key, currentTime, ProductionNotifications.COOLDOWN_TIME_SHORT) then
        return
    end
    
    local locationName = ProductionNotifications.getLocationName(productionPoint)
    local productionName = production.name or "Production"
    
    local message = string.format(
        g_i18n:getText("production_notify_started"),
        productionName,
        locationName
    )
    
    ProductionNotifications.broadcastNotification(message, FSBaseMission.INGAME_NOTIFICATION_OK)
    ProductionNotifications.setCooldown(key, currentTime)
end

function ProductionNotifications.notifyProductionResumed(productionPoint, production)
    if not ProductionSettings or not ProductionSettings.notifySmartControl then
        return
    end
    
    if not productionPoint or productionPoint.ownerFarmId ~= g_currentMission:getFarmId() then
        return
    end
    
    local currentTime = g_currentMission.time
    local key = string.format("resumed_%s_%s", tostring(productionPoint), production.id)
    
    if ProductionNotifications.isOnCooldown(key, currentTime, ProductionNotifications.COOLDOWN_TIME_SHORT) then
        return
    end
    
    local locationName = ProductionNotifications.getLocationName(productionPoint)
    local productionName = production.name or "Production"
    
    local message = string.format(
        g_i18n:getText("production_notify_resumed"),
        productionName,
        locationName
    )
    
    ProductionNotifications.broadcastNotification(message, FSBaseMission.INGAME_NOTIFICATION_OK)
    ProductionNotifications.setCooldown(key, currentTime)
end

function ProductionNotifications.notifyProductionStopped(productionPoint, production, reason)
    if not ProductionSettings or not ProductionSettings.notifySmartControl then
        return
    end
    
    if not productionPoint or productionPoint.ownerFarmId ~= g_currentMission:getFarmId() then
        return
    end
    
    local currentTime = g_currentMission.time
    local key = string.format("stop_%s_%s", tostring(productionPoint), production.id)
    
    if ProductionNotifications.isOnCooldown(key, currentTime, ProductionNotifications.COOLDOWN_TIME_SHORT) then
        return
    end
    
    local locationName = ProductionNotifications.getLocationName(productionPoint)
    local productionName = production.name or "Production"
    
    local message = string.format(
        g_i18n:getText("production_notify_stopped"),
        productionName,
        locationName,
        reason or g_i18n:getText("production_notify_reason_unknown")
    )
    
    ProductionNotifications.broadcastNotification(message, FSBaseMission.INGAME_NOTIFICATION_INFO)
    ProductionNotifications.setCooldown(key, currentTime)
end

function ProductionNotifications.notifyOutOfInputs(productionPoint, production, emptyInputs)
    if not ProductionSettings or not ProductionSettings.notifyLowInputs then
        return
    end
    
    if not productionPoint or productionPoint.ownerFarmId ~= g_currentMission:getFarmId() then
        return
    end
    
    local currentTime = g_currentMission.time
    local key = string.format("out_of_input_%s_%s", tostring(productionPoint), production.id)
    
    if ProductionNotifications.isOnCooldown(key, currentTime, ProductionNotifications.COOLDOWN_TIME_LONG) then
        return
    end
    
    local locationName = ProductionNotifications.getLocationName(productionPoint)
    local productionName = production.name or "Production"
    
    local inputNames = {}
    for _, input in ipairs(emptyInputs or {}) do
        local fillType = g_fillTypeManager:getFillTypeByIndex(input.type)
        if fillType then
            table.insert(inputNames, fillType.title)
        end
    end
    
    local inputList = table.concat(inputNames, ", ")
    
    local message = string.format(
        g_i18n:getText("production_notify_out_of_inputs"),
        productionName,
        locationName,
        inputList
    )
    
    ProductionNotifications.broadcastNotification(message, FSBaseMission.INGAME_NOTIFICATION_CRITICAL)
    ProductionNotifications.setCooldown(key, currentTime)
end

function ProductionNotifications.notifyInputsRestored(productionPoint, production)
    if not ProductionSettings or not ProductionSettings.notifySmartControl then
        return
    end
    
    if not productionPoint or productionPoint.ownerFarmId ~= g_currentMission:getFarmId() then
        return
    end
    
    local currentTime = g_currentMission.time
    local key = string.format("inputs_restored_%s_%s", tostring(productionPoint), production.id)
    
    if ProductionNotifications.isOnCooldown(key, currentTime, ProductionNotifications.COOLDOWN_TIME_SHORT) then
        return
    end
    
    local locationName = ProductionNotifications.getLocationName(productionPoint)
    local productionName = production.name or "Production"
    
    local message = string.format(
        g_i18n:getText("production_notify_inputs_restored"),
        productionName,
        locationName
    )
    
    ProductionNotifications.broadcastNotification(message, FSBaseMission.INGAME_NOTIFICATION_OK)
    ProductionNotifications.setCooldown(key, currentTime)
end

function ProductionNotifications.notifyLowInputs(productionPoint, production, missingInputs)
    if not ProductionSettings or not ProductionSettings.notifyLowInputs then
        return
    end
    
    if not productionPoint or productionPoint.ownerFarmId ~= g_currentMission:getFarmId() then
        return
    end
    
    local currentTime = g_currentMission.time
    local key = string.format("low_input_%s_%s", tostring(productionPoint), production.id)
    
    if ProductionNotifications.isOnCooldown(key, currentTime, ProductionNotifications.COOLDOWN_TIME_LONG) then
        return
    end
    
    local locationName = ProductionNotifications.getLocationName(productionPoint)
    local productionName = production.name or "Production"
    
    local inputNames = {}
    for _, input in ipairs(missingInputs or {}) do
        local fillType = g_fillTypeManager:getFillTypeByIndex(input.type)
        if fillType then
            table.insert(inputNames, fillType.title)
        end
    end
    
    local inputList = table.concat(inputNames, ", ")
    
    local message = string.format(
        g_i18n:getText("production_notify_low_inputs"),
        productionName,
        locationName,
        inputList
    )
    
    ProductionNotifications.broadcastNotification(message, FSBaseMission.INGAME_NOTIFICATION_CRITICAL)
    ProductionNotifications.setCooldown(key, currentTime)
end

function ProductionNotifications.notifyHighOutputs(productionPoint, production, fullOutputs)
    if not ProductionSettings or not ProductionSettings.notifyHighOutputs then
        return
    end
    
    if not productionPoint or productionPoint.ownerFarmId ~= g_currentMission:getFarmId() then
        return
    end
    
    local currentTime = g_currentMission.time
    local key = string.format("high_output_%s_%s", tostring(productionPoint), production.id)
    
    if ProductionNotifications.isOnCooldown(key, currentTime, ProductionNotifications.COOLDOWN_TIME_LONG) then
        return
    end
    
    local locationName = ProductionNotifications.getLocationName(productionPoint)
    local productionName = production.name or "Production"
    
    local outputNames = {}
    for _, output in ipairs(fullOutputs or {}) do
        local fillType = g_fillTypeManager:getFillTypeByIndex(output.type)
        if fillType then
            table.insert(outputNames, fillType.title)
        end
    end
    
    local outputList = table.concat(outputNames, ", ")
    
    local message = string.format(
        g_i18n:getText("production_notify_high_outputs"),
        productionName,
        locationName,
        outputList
    )
    
    ProductionNotifications.broadcastNotification(message, FSBaseMission.INGAME_NOTIFICATION_CRITICAL)
    ProductionNotifications.setCooldown(key, currentTime)
end

function ProductionNotifications.getLocationName(productionPoint)
    if not productionPoint then
        return g_i18n:getText("production_notify_unknown_location")
    end
    
    if productionPoint.owningPlaceable then
        local placeable = productionPoint.owningPlaceable
        if placeable.getName then
            return placeable:getName()
        elseif placeable.typeName then
            return placeable.typeName
        end
    end
    
    return productionPoint.name or g_i18n:getText("production_notify_production_facility")
end

function ProductionNotifications.clearCooldowns()
    ProductionNotifications.cooldowns = {}
end