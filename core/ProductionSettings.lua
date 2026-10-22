ProductionSettings = {}
ProductionSettings.SETTINGS = {}
ProductionSettings.CONTROLS = {}

-- Ordered setting definitions. Each entry drives the menu option, load/save and
-- (when synced) the multiplayer event, so adding a setting is one line here plus
-- its texts.
--   id       - field on ProductionSettings holding the current value
--   values   - option values (booleans or numbers)
--   default  - index into values
--   strings  - option labels (l10n keys resolved at load, or a function(value))
--   synced   - true: host-wide gameplay setting, sent to every player
--              false: personal display preference, never sent
--   section  - settings page section header key
ProductionSettings.ORDER = {}

local SECTION_MANAGER  = "production_menu_section_title"
local SECTION_INSIGHTS = "pi_menu_section_insights"
local SECTION_LOGISTICS = "pi_menu_section_logistics"
local SECTION_GAMEPLAY = "pi_menu_section_gameplay"

local function text(key) return g_i18n:getText(key) end

local function onOffStrings(onKey, offKey)
    return { text(onKey or "production_setting_notify_on"), text(offKey or "production_setting_notify_off") }
end

local function labels(values, formatter)
    local result = {}
    for i, value in ipairs(values) do result[i] = formatter(value) end
    return result
end

local function percent(value) return string.format("%d%%", value) end
local function liters(value) return string.format("%s L", tostring(value)) end
local function meters(value)
    if value == 0 then return text("pi_setting_farmWide") end
    return string.format("%d m", value)
end
local function money(value) return g_i18n:formatMoney(value, 0, true, true) end
local function multiplier(value)
    if value == 1 then return text("pi_setting_off") end
    return string.format("%gx", value)
end

local function define(id, section, values, default, strings, synced)
    ProductionSettings.SETTINGS[id] = { values = values, default = default, strings = strings, synced = synced, section = section }
    table.insert(ProductionSettings.ORDER, id)
    ProductionSettings[id] = values[default]
end

-- Productions Manager (existing)
define("autoManageEnabled",       SECTION_MANAGER, {true, false}, 2, onOffStrings("production_setting_automanage_on", "production_setting_automanage_off"), true)
define("hideInactiveProductions", SECTION_MANAGER, {true, false}, 2, onOffStrings("production_setting_hide_inactive_on", "production_setting_hide_inactive_off"), true)
define("notifySmartControl",      SECTION_MANAGER, {true, false}, 2, onOffStrings(), true)
define("notifyLowInputs",         SECTION_MANAGER, {true, false}, 2, onOffStrings(), true)
define("notifyHighOutputs",       SECTION_MANAGER, {true, false}, 2, onOffStrings(), true)
define("lowInputThreshold",       SECTION_MANAGER, {10, 15, 20, 25, 30}, 3, labels({10, 15, 20, 25, 30}, percent), true)
define("highOutputThreshold",     SECTION_MANAGER, {70, 75, 80, 85, 90}, 3, labels({70, 75, 80, 85, 90}, percent), true)
define("notificationDuration",    SECTION_MANAGER, {3000, 4000, 5000, 6000, 8000, 10000}, 3, {
    text("production_setting_duration_3s"), text("production_setting_duration_4s"), text("production_setting_duration_5s"),
    text("production_setting_duration_6s"), text("production_setting_duration_8s"), text("production_setting_duration_10s"),
}, true)

-- Productions Insights (personal)
define("insightsAnimalThreshold", SECTION_INSIGHTS, {0, 10, 20, 30, 40, 50}, 3, labels({0, 10, 20, 30, 40, 50}, percent), false)
define("insightsVehicleFullSize", SECTION_INSIGHTS, {1000, 2500, 5000, 10000, 20000}, 3, labels({1000, 2500, 5000, 10000, 20000}, liters), false)
define("insightsFreeWater",       SECTION_INSIGHTS, {true, false}, 2, onOffStrings(), false)
define("insightsPriceBasis",      SECTION_INSIGHTS, {1, 2}, 1, { text("pi_setting_priceCurrent"), text("pi_setting_pricePeak") }, false)
define("insightsAdviceThreshold", SECTION_INSIGHTS, {0, 50, 100, 250, 500}, 3, labels({0, 50, 100, 250, 500}, money), false)

-- Productions Logistics (synced)
define("logisticsEnabled",        SECTION_LOGISTICS, {true, false}, 2, onOffStrings(), true)
define("logisticsScope",          SECTION_LOGISTICS, {0, 500, 1000, 2000, 5000}, 1, labels({0, 500, 1000, 2000, 5000}, meters), true)
define("logisticsIncludeAnimals", SECTION_LOGISTICS, {true, false}, 1, onOffStrings(), true)
define("logisticsIncludeSilos",   SECTION_LOGISTICS, {true, false}, 1, onOffStrings(), true)
define("logisticsDefaultTarget",  SECTION_LOGISTICS, {25, 50, 75, 100}, 3, labels({25, 50, 75, 100}, percent), true)
define("logisticsTransportRate",  SECTION_LOGISTICS, {0, 1, 2, 5, 10, 20}, 3, labels({0, 1, 2, 5, 10, 20}, money), true)
define("logisticsAutoWater",      SECTION_LOGISTICS, {true, false}, 2, onOffStrings(), true)
define("logisticsWaterPrice",     SECTION_LOGISTICS, {0, 1, 2, 5, 10}, 3, labels({0, 1, 2, 5, 10}, money), true)

-- Gameplay adjustments (synced)
define("gpWaterNoValue",  SECTION_GAMEPLAY, {true, false}, 2, onOffStrings(), true)
define("gpGrapeYield",    SECTION_GAMEPLAY, {1, 1.5, 2, 2.5, 3}, 1, labels({1, 1.5, 2, 2.5, 3}, multiplier), true)
define("gpOliveYield",    SECTION_GAMEPLAY, {1, 1.5, 2, 2.5, 3}, 1, labels({1, 1.5, 2, 2.5, 3}, multiplier), true)
define("gpHorseValue",    SECTION_GAMEPLAY, {1, 1.5, 2, 3, 4, 5, 6}, 1, labels({1, 1.5, 2, 3, 4, 5, 6}, multiplier), true)
define("gpPigValue",      SECTION_GAMEPLAY, {1, 1.5, 2, 2.5, 3}, 1, labels({1, 1.5, 2, 2.5, 3}, multiplier), true)
define("gpBeefValue",     SECTION_GAMEPLAY, {1, 1.5, 2, 3, 4, 5, 6}, 1, labels({1, 1.5, 2, 3, 4, 5, 6}, multiplier), true)

-- Network Event for Settings Synchronization (synced settings only)
ProductionSettingsEvent = {}
ProductionSettingsEvent_mt = Class(ProductionSettingsEvent, Event)
InitEventClass(ProductionSettingsEvent, "ProductionSettingsEvent")

function ProductionSettingsEvent.emptyNew()
    local self = Event.new(ProductionSettingsEvent_mt)
    return self
end

-- Snapshot of the current synced values
function ProductionSettingsEvent.new()
    local self = ProductionSettingsEvent.emptyNew()
    self.values = {}
    for _, id in ipairs(ProductionSettings.ORDER) do
        if ProductionSettings.SETTINGS[id].synced then
            self.values[id] = ProductionSettings[id]
        end
    end
    return self
end

function ProductionSettingsEvent:readStream(streamId, connection)
    self.values = {}
    for _, id in ipairs(ProductionSettings.ORDER) do
        local def = ProductionSettings.SETTINGS[id]
        if def.synced then
            if type(def.values[1]) == "boolean" then
                self.values[id] = streamReadBool(streamId)
            else
                self.values[id] = streamReadFloat32(streamId)
            end
        end
    end
    self:run(connection)
end

function ProductionSettingsEvent:writeStream(streamId, connection)
    for _, id in ipairs(ProductionSettings.ORDER) do
        local def = ProductionSettings.SETTINGS[id]
        if def.synced then
            local value = self.values[id]
            if type(def.values[1]) == "boolean" then
                streamWriteBool(streamId, value == true)
            else
                streamWriteFloat32(streamId, value or def.values[def.default])
            end
        end
    end
end

function ProductionSettingsEvent:run(connection)
    for id, value in pairs(self.values) do
        ProductionSettings.setValue(id, ProductionSettings.normalize(id, value))
    end

    if not connection:getIsServer() then
        -- We are the server and a client changed something: keep the host's file
        -- up to date and pass the change on to every other client
        ProductionSettings.saveSettings()
        g_server:broadcastEvent(ProductionSettingsEvent.new(), false, connection)
    end

    ProductionSettings.updateUIControls()
    ProductionSettings.onSettingsChanged()
end

-- Float32 transport can turn 1.5 into 1.4999999; snap back to the defined value
function ProductionSettings.normalize(id, value)
    local def = ProductionSettings.SETTINGS[id]
    if def == nil or type(value) ~= "number" then return value end
    for _, candidate in ipairs(def.values) do
        if type(candidate) == "number" and math.abs(candidate - value) < 0.001 then
            return candidate
        end
    end
    return value
end

-- Send settings to all clients
function ProductionSettings.sendSettingsToClients()
    if g_server ~= nil then
        g_server:broadcastEvent(ProductionSettingsEvent.new())
    end
end

-- Send settings to server (from client)
function ProductionSettings.sendSettingsToServer()
    if g_client ~= nil and not g_currentMission:getIsServer() then
        g_client:getServerConnection():sendEvent(ProductionSettingsEvent.new())
    end
end

-- Set a value
function ProductionSettings.setValue(id, value)
    ProductionSettings[id] = value
end

-- Get a value
function ProductionSettings.getValue(id)
    return ProductionSettings[id]
end

-- Find the index for a specific value
function ProductionSettings.getStateIndex(id, value)
    local def = ProductionSettings.SETTINGS[id]
    if value == nil then value = ProductionSettings.getValue(id) end

    for i, candidate in ipairs(def.values) do
        if candidate == value then
            return i
        end
    end

    return def.default
end

-- Hook for modules that react to setting changes (yield multipliers, caches)
function ProductionSettings.onSettingsChanged()
    if ProductionGameplay ~= nil then
        ProductionGameplay:applySettings()
    end
    if ProductionPrices ~= nil then
        ProductionPrices:invalidate()
    end
    if ProductionTasks ~= nil then
        ProductionTasks.timer = ProductionTasks.INTERVAL
    end
end

-- Update UI controls when settings change
function ProductionSettings.updateUIControls()
    local menu = g_gui.screenControllers[InGameMenu]
    if menu ~= nil and menu.isOpen then
        for _, control in pairs(ProductionSettings.CONTROLS or {}) do
            if control.id and ProductionSettings.SETTINGS[control.id] then
                local stateIndex = ProductionSettings.getStateIndex(control.id)
                control:setState(stateIndex)
            end
        end
    end
end

-- Controls for settings
ProductionControls = {}

function ProductionControls:onMenuOptionChanged(state, menuOption)
    local id = menuOption.id
    local def = ProductionSettings.SETTINGS[id]
    local value = def ~= nil and def.values[state] or nil

    if value ~= nil then
        ProductionSettings.setValue(id, value)
        ProductionSettings.saveSettings()

        if def.synced then
            if g_currentMission:getIsServer() then
                ProductionSettings.sendSettingsToClients()
            else
                ProductionSettings.sendSettingsToServer()
            end
        end

        ProductionSettings.onSettingsChanged()
    end
end

local function getSettingsPath()
    return Utils.getFilename("modSettings/ProductionSettings.xml", getUserProfileAppPath())
end

-- Load settings from XML file
function ProductionSettings.loadSettings()
    local xmlFilePath = getSettingsPath()

    if not fileExists(xmlFilePath) then
        return
    end

    local xmlFile = loadXMLFile("ProductionXML", xmlFilePath)
    if xmlFile == 0 then
        return
    end

    for _, id in ipairs(ProductionSettings.ORDER) do
        local def = ProductionSettings.SETTINGS[id]
        local key = "production.settings#" .. id
        local value
        if type(def.values[1]) == "boolean" then
            value = getXMLBool(xmlFile, key)
        else
            value = getXMLFloat(xmlFile, key)
        end
        if value ~= nil then
            ProductionSettings.setValue(id, ProductionSettings.normalize(id, value))
        end
    end

    delete(xmlFile)
end

-- Save settings to XML file
function ProductionSettings.saveSettings()
    local xmlFilePath = getSettingsPath()
    local xmlFile = nil

    createFolder(getUserProfileAppPath() .. "modSettings/")

    if fileExists(xmlFilePath) then
        xmlFile = loadXMLFile("ProductionXML", xmlFilePath)
    else
        xmlFile = createXMLFile("ProductionXML", xmlFilePath, "production")
    end

    if xmlFile == 0 then
        print("ProductionSettings: Error opening XML file.")
        return
    end

    for _, id in ipairs(ProductionSettings.ORDER) do
        local value = ProductionSettings[id]
        local key = "production.settings#" .. id
        if type(value) == "boolean" then
            setXMLBool(xmlFile, key, value)
        elseif type(value) == "number" then
            setXMLFloat(xmlFile, key, value)
        end
    end

    saveXMLFile(xmlFile)
    delete(xmlFile)
end

-- Helper function for FocusManager
local function updateFocusIds(element)
    if not element then
        return
    end
    element.focusId = FocusManager:serveAutoFocusId()
    for _, child in pairs(element.elements or {}) do
        updateFocusIds(child)
    end
end

-- Inject settings into InGame menu
function ProductionSettings.injectMenu()
    local inGameMenu = g_gui.screenControllers[InGameMenu]
    if not inGameMenu then
        print("ProductionSettings: InGameMenu not found!")
        return
    end

    local settingsPage = inGameMenu.pageSettings
    if not settingsPage then
        print("ProductionSettings: Settings-Page not found!")
        return
    end

    local layoutToUse = settingsPage.gameSettingsLayout
    if not layoutToUse then
        print("ProductionSettings: gameSettingsLayout not found!")
        return
    end

    local headerTemplate = nil
    for _, elem in ipairs(layoutToUse.elements) do
        if elem.name == "sectionHeader" then
            headerTemplate = elem
            break
        end
    end

    local function addSectionHeader(titleKey)
        local sectionTitle
        if headerTemplate ~= nil then
            sectionTitle = headerTemplate:clone(layoutToUse)
        else
            sectionTitle = TextElement.new()
            sectionTitle:applyProfile("fs25_settingsSectionHeader", true)
            sectionTitle.name = "sectionHeader"
            layoutToUse:addElement(sectionTitle)
        end
        sectionTitle:setText(g_i18n:getText(titleKey))
        sectionTitle.focusId = FocusManager:serveAutoFocusId()
        table.insert(settingsPage.controlsList, sectionTitle)
        ProductionSettings.CONTROLS["sectionHeader_" .. titleKey] = sectionTitle
    end

    local originalBox = settingsPage.multiVolumeVoiceBox
    if not originalBox then
        print("ProductionSettings: multiVolumeVoiceBox not found!")
        return
    end

    -- Helper function to create a setting option
    local function createSettingOption(id)
        local box = originalBox:clone(layoutToUse)
        box.id = id .. "Box"

        local option = box.elements[1]
        option.id = id
        option.target = ProductionControls

        option:setCallback("onClickCallback", "onMenuOptionChanged")
        option:setDisabled(false)

        local toolTip = option.elements[1]
        toolTip:setText(g_i18n:getText(ProductionSettings.getTooltipKey(id)))
        box.elements[2]:setText(g_i18n:getText(ProductionSettings.getTitleKey(id)))

        option:setTexts(ProductionSettings.SETTINGS[id].strings)

        local stateIndex = ProductionSettings.getStateIndex(id)
        option:setState(stateIndex)

        ProductionSettings.CONTROLS[id] = option

        updateFocusIds(box)
        table.insert(settingsPage.controlsList, box)
    end

    local currentSection = nil
    for _, id in ipairs(ProductionSettings.ORDER) do
        local section = ProductionSettings.SETTINGS[id].section
        if section ~= currentSection then
            addSectionHeader(section)
            currentSection = section
        end
        createSettingOption(id)
    end

    layoutToUse:invalidateLayout()
end

-- The original settings kept their historic text keys; new ones follow the id
local LEGACY_TEXT_KEYS = {
    autoManageEnabled       = "production_menu_automanage",
    hideInactiveProductions = "production_menu_hide_inactive",
    notifySmartControl      = "production_menu_notify_smart_control",
    notifyLowInputs         = "production_menu_notify_low_inputs",
    notifyHighOutputs       = "production_menu_notify_high_outputs",
    lowInputThreshold       = "production_menu_low_input_threshold",
    highOutputThreshold     = "production_menu_high_output_threshold",
    notificationDuration    = "production_menu_notification_duration",
}

function ProductionSettings.getTitleKey(id)
    return LEGACY_TEXT_KEYS[id] or ("pi_setting_" .. id)
end

function ProductionSettings.getTooltipKey(id)
    return ProductionSettings.getTitleKey(id) .. "_tooltip"
end

-- Initialize when game is loaded
Mission00.loadMission00Finished = Utils.appendedFunction(Mission00.loadMission00Finished, function()
    ProductionSettings.loadSettings()
    ProductionSettings.injectMenu()
    ProductionSettings.onSettingsChanged()
end)
