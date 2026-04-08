ProductionAutoManager = {}

ProductionAutoManager.CHECK_INTERVAL = 30000
ProductionAutoManager.lastCheckTime = 0
ProductionAutoManager.productionStates = {}  -- Tracks previous running state and notification state

function ProductionAutoManager:loadMap(name)
end

function ProductionAutoManager:update(dt)
    if g_server == nil then
        return
    end

    if not ProductionSettings or not ProductionSettings.autoManageEnabled then
        return
    end
    
    ProductionAutoManager.lastCheckTime = ProductionAutoManager.lastCheckTime + dt
    
    if ProductionAutoManager.lastCheckTime < ProductionAutoManager.CHECK_INTERVAL then
        return
    end
    
    ProductionAutoManager.lastCheckTime = 0
    ProductionAutoManager:checkAllProductions()
end

function ProductionAutoManager:checkAllProductions()
    if g_currentMission == nil or g_currentMission.productionChainManager == nil then
        return
    end
    
    local farmId = g_currentMission:getFarmId()
    
    for _, productionPoint in pairs(g_currentMission.productionChainManager.productionPoints) do
        if productionPoint.ownerFarmId == farmId then
            self:manageProduction(productionPoint)
        end
    end
end

function ProductionAutoManager:getProductionStateKey(productionPoint, production)
    return string.format("%s_%s", tostring(productionPoint), production.id)
end

function ProductionAutoManager:manageProduction(productionPoint)
    if productionPoint.storage == nil or productionPoint.productions == nil then
        return
    end
    
    local locationName = productionPoint.owningPlaceable and productionPoint.owningPlaceable:getName() or "Unknown"
    
    for _, production in pairs(productionPoint.productions) do
        if production.status ~= ProductionPoint.PROD_STATUS.INACTIVE then
            local shouldActivate, reason, emptyInputs, lowInputs, fullOutputs = self:shouldActivateProduction(productionPoint, production)
            local isCurrentlyRunning = production.status == ProductionPoint.PROD_STATUS.RUNNING
            
            local stateKey = self:getProductionStateKey(productionPoint, production)
            
            -- Get previous state (default to current state if first check)
            local previousState = ProductionAutoManager.productionStates[stateKey]
            local isFirstCheck = (previousState == nil)
            
            if previousState == nil then
                previousState = {
                    wasRunning = isCurrentlyRunning,
                    notifiedLowInputs = false,
                    notifiedHighOutputs = false
                }
                ProductionAutoManager.productionStates[stateKey] = previousState
            end
            
            local wasRunning = previousState.wasRunning
            
            -- On first check, if production is already stopped with issues, notify immediately
            if isFirstCheck and not isCurrentlyRunning and not shouldActivate then
                if emptyInputs and #emptyInputs > 0 and ProductionNotifications then
                    ProductionNotifications.notifyOutOfInputs(productionPoint, production, emptyInputs)
                    previousState.notifiedLowInputs = true
                elseif lowInputs and #lowInputs > 0 and ProductionNotifications then
                    ProductionNotifications.notifyLowInputs(productionPoint, production, lowInputs)
                    previousState.notifiedLowInputs = true
                end
                
                if fullOutputs and #fullOutputs > 0 and ProductionNotifications then
                    ProductionNotifications.notifyHighOutputs(productionPoint, production, fullOutputs)
                    previousState.notifiedHighOutputs = true
                end
            end
            
            -- DETECT STATE TRANSITIONS
            
            -- Transition: RUNNING → STOPPED (game auto-paused due to lack of inputs or schedule)
            if wasRunning and not isCurrentlyRunning then
                if ProductionNotifications then
                    ProductionNotifications.notifyProductionStopped(productionPoint, production, reason)
                end
                
                if emptyInputs and #emptyInputs > 0 and ProductionNotifications then
                    ProductionNotifications.notifyOutOfInputs(productionPoint, production, emptyInputs)
                    previousState.notifiedLowInputs = true
                elseif lowInputs and #lowInputs > 0 and ProductionNotifications then
                    ProductionNotifications.notifyLowInputs(productionPoint, production, lowInputs)
                    previousState.notifiedLowInputs = true
                end
                
                if fullOutputs and #fullOutputs > 0 and ProductionNotifications then
                    ProductionNotifications.notifyHighOutputs(productionPoint, production, fullOutputs)
                    previousState.notifiedHighOutputs = true
                end
                
                previousState.wasRunning = false
                
            -- Transition: STOPPED → RUNNING (auto-manager is restarting it)
            elseif not wasRunning and shouldActivate then
                productionPoint:setProductionState(production.id, ProductionPoint.PROD_STATUS.RUNNING)
                
                if ProductionNotifications then
                    if previousState.notifiedLowInputs then
                        ProductionNotifications.notifyProductionResumed(productionPoint, production)
                    else
                        ProductionNotifications.notifyProductionStarted(productionPoint, production)
                    end
                end
                
                previousState.wasRunning = true
                previousState.notifiedLowInputs = false
                previousState.notifiedHighOutputs = false
                
            -- State: inputs refilled but production still stopped
            elseif not wasRunning and not isCurrentlyRunning and shouldActivate and previousState.notifiedLowInputs then
                if ProductionNotifications then
                    ProductionNotifications.notifyInputsRestored(productionPoint, production)
                end
                
                previousState.notifiedLowInputs = false
                previousState.notifiedHighOutputs = false
                
            -- State: still stopped, waiting for inputs or schedule window
            elseif not wasRunning and not shouldActivate and not isCurrentlyRunning then
                if emptyInputs and #emptyInputs > 0 and ProductionNotifications then
                    if not previousState.notifiedLowInputs then
                        ProductionNotifications.notifyOutOfInputs(productionPoint, production, emptyInputs)
                        previousState.notifiedLowInputs = true
                    end
                elseif lowInputs and #lowInputs > 0 and ProductionNotifications then
                    if not previousState.notifiedLowInputs then
                        ProductionNotifications.notifyLowInputs(productionPoint, production, lowInputs)
                        previousState.notifiedLowInputs = true
                    end
                end
                
                if fullOutputs and #fullOutputs > 0 and ProductionNotifications then
                    if not previousState.notifiedHighOutputs then
                        ProductionNotifications.notifyHighOutputs(productionPoint, production, fullOutputs)
                        previousState.notifiedHighOutputs = true
                    end
                end
                
            -- State: running normally
            elseif isCurrentlyRunning and shouldActivate then
                previousState.wasRunning = true
                previousState.notifiedLowInputs = false
                previousState.notifiedHighOutputs = false
            end
        end
    end
end

function ProductionAutoManager:shouldActivateProduction(productionPoint, production)
    -- ----------------------------------------------------------------
    -- Schedule guard: if this production has an active schedule and the
    -- current period is outside its allowed months, never auto-restart it.
    -- This prevents AutoManager from fighting ProductionScheduleManager.
    -- ----------------------------------------------------------------
    if ProductionScheduleManager ~= nil then
        local pointKey = ProductionScheduleManager:getPointKey(productionPoint)
        local entry    = ProductionScheduleManager:getEntry(pointKey, production.id)
        if entry ~= nil and entry.scheduleEnabled then
            local period = ProductionScheduleManager:getCurrentPeriod()
            if period ~= nil then
                local months = entry.months or {}
                local any = false
                for _ in pairs(months) do any = true; break end
                if any and months[period] ~= true then
                    -- Outside scheduled months - do not activate
                    return false,
                        g_i18n:getText("production_notify_reason_scheduled"),
                        {}, {}, {}
                end
            end
        end
    end

    local storage = productionPoint.storage
    local reason = nil
    local emptyInputs = {}  -- Inputs completely out (fillLevel < input.amount)
    local lowInputs = {}    -- Inputs running low but still available
    local fullOutputs = {}
    
    local highOutputThreshold = ProductionSettings and ProductionSettings.highOutputThreshold or 80
    local lowInputThreshold = ProductionSettings and ProductionSettings.lowInputThreshold or 20
    
    -- Check outputs first - if ANY output is full, stop production
    if production.outputs ~= nil then
        for _, output in pairs(production.outputs) do
            local fillLevel = storage:getFillLevel(output.type)
            local capacity = storage:getCapacity(output.type)
            
            if capacity > 0 then
                local fillPercent = (fillLevel / capacity) * 100
                
                if fillPercent >= highOutputThreshold then
                    reason = g_i18n:getText("production_notify_reason_output_full")
                    table.insert(fullOutputs, output)
                    return false, reason, emptyInputs, lowInputs, fullOutputs
                end
            end
        end
    end

    -- Check inputs - distinguish between completely empty and just low
    if production.inputs ~= nil then
        for _, input in pairs(production.inputs) do
            local fillLevel = storage:getFillLevel(input.type)
            local capacity = storage:getCapacity(input.type)
            
            -- Check if input is completely missing (below required amount)
            if fillLevel < input.amount then
                reason = g_i18n:getText("production_notify_reason_out_of_inputs")
                table.insert(emptyInputs, input)
            -- Only check for low inputs if not already empty
            elseif capacity > 0 then
                local fillPercent = (fillLevel / capacity) * 100
                
                if fillPercent < lowInputThreshold then
                    if reason == nil then
                        reason = g_i18n:getText("production_notify_reason_low_inputs")
                    end
                    table.insert(lowInputs, input)
                end
            end
        end
        
        -- If any inputs are completely empty, cannot activate
        if #emptyInputs > 0 then
            return false, reason, emptyInputs, lowInputs, fullOutputs
        end
    end

    return true, nil, emptyInputs, lowInputs, fullOutputs
end

function ProductionAutoManager:deleteMap()
    ProductionAutoManager.productionStates = {}
end

addModEventListener(ProductionAutoManager)
