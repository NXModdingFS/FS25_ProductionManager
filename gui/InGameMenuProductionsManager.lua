-- InGameMenuProductionsManager.lua
-- In-game ESC-menu tab version of the Production Manager.
--
-- Design note: this frame deliberately REUSES the data + rendering logic that
-- already lives on ProductionDlgFrame (loadProductionData / buildDisplayRows /
-- populateCellForItemInSection / updateHeaderVisibility / getDistributionDestination
-- / formatNumber / onClickExportCSV). Those functions only touch `self` fields and
-- a SmoothList called self.overviewTable, so as long as this frame provides the
-- same fields and a list with the same cell-attribute names, they work unchanged.
-- They are aliased at the bottom of this file. The dialog is left fully intact as
-- a fallback; nothing here modifies it.
--
-- Sub-tabs map 1:1 to the dialog's pages by setting the same show* flags. Schedule
-- is not a top-level sub-tab because it needs a selected production - it is reached
-- from the Logistics tab, same as the dialog.
--
-- The last five sub-tabs (Stock, Profitability, Animals, Network, This Month) share
-- one page and are driven by ProductionInsightsView (gui/ProductionInsightsView.lua).

InGameMenuProductionsManager = {}
InGameMenuProductionsManager._mt = Class(InGameMenuProductionsManager, TabbedMenuFrameElement)

InGameMenuProductionsManager.CATEGORIES = {
    INPUTS    = 1,
    OUTPUTS   = 2,
    RECIPES   = 3,
    FINANCES  = 4,
    LOGISTICS = 5,
    STOCK     = 6,
    PROFIT    = 7,
    ANIMALS   = 8,
    NETWORK   = 9,
    TASKS     = 10,
}

-- Sub-tab -> ProductionInsightsView view
InGameMenuProductionsManager.INSIGHTS_VIEWS = {
    [6] = 1, [7] = 2, [8] = 3, [9] = 4, [10] = 5,
}

InGameMenuProductionsManager.CATEGORY_TEXTS = {
    "ui_tab_inputs",
    "ui_tab_outputs",
    "ui_tab_recipes",
    "ui_tab_finances",
    "ui_tab_logistics",
    "pi_tab_stock",
    "pi_tab_profit",
    "pi_tab_animals",
    "pi_tab_network",
    "pi_tab_tasks",
}

InGameMenuProductionsManager.NUM_CATEGORIES = #InGameMenuProductionsManager.CATEGORY_TEXTS

function InGameMenuProductionsManager.new(i18n, messageCenter)
    local self = InGameMenuProductionsManager:superClass().new(nil, InGameMenuProductionsManager._mt)

    self.name         = "InGameMenuProductionsManager"
    self.i18n         = i18n or g_i18n
    self.messageCenter = messageCenter

    -- Same state fields the reused dialog methods expect
    self.productions   = {}
    self.displayRows   = {}
    self.showInputs    = true
    self.showRecipes   = false
    self.showFinances  = false
    self.showLogistics = false
    self.showSchedule  = false
    self.selectedLogisticsRow = nil
    self.selectedRecipeRow    = nil
    self.schedulePeak  = nil

    self.subCategoryTabs  = {}
    self.lastUpdateTime   = 0
    self.autoRefreshInterval = 5000

    -- Footer buttons
    self.backButtonInfo = { inputAction = InputAction.MENU_BACK }

    self.refreshButtonInfo = {
        text = string.upper(self.i18n:getText("ui_refresh") or "REFRESH"),
        inputAction = InputAction.MENU_EXTRA_1,
        callback = function() self:updateContent() end,
    }

    self.exportButtonInfo = {
        text = string.upper(self.i18n:getText("ui_productionDlg_btnExportCSV") or "EXPORT CSV"),
        inputAction = InputAction.MENU_ACTIVATE,
        callback = function() self:onClickExportCSV() end,
    }

    -- Logistics-tab action buttons (enabled only when a recipe row is selected)
    self.changeOutputButtonInfo = {
        text = string.upper(self.i18n:getText("ui_productionDlg_btnChangeOutput") or "CHANGE OUTPUT"),
        inputAction = InputAction.MENU_ACCEPT,
        disabled = true,
        callback = function() self:onChangeOutput() end,
    }
    self.activateButtonInfo = {
        text = string.upper(self.i18n:getText("ui_productionDlg_btnActivate") or "ACTIVATE"),
        inputAction = InputAction.MENU_CANCEL,
        disabled = true,
        callback = function() self:onToggleRecipe() end,
    }
    self.scheduleButtonInfo = {
        text = string.upper(self.i18n:getText("ui_productionDlg_btnSchedule") or "SCHEDULE"),
        inputAction = InputAction.MENU_EXTRA_2,
        disabled = true,
        callback = function() self:menuOpenSchedule() end,
    }

    -- Schedule-mode buttons
    self.commitButtonInfo = {
        text = string.upper(self.i18n:getText("button_ok") or "OK"),
        inputAction = InputAction.MENU_ACCEPT,
        callback = function() self:menuCommitSchedule() end,
    }
    self.cancelScheduleButtonInfo = {
        text = string.upper(self.i18n:getText("button_cancel") or "CANCEL"),
        inputAction = InputAction.MENU_CANCEL,
        callback = function() self:menuExitSchedule() end,
    }
    self.allMonthsButtonInfo = {
        text = string.upper(self.i18n:getText("PS_BTN_ALL_TOGGLE") or "ALL MONTHS"),
        inputAction = InputAction.MENU_EXTRA_1,
        callback = function() self:menuAllMonths() end,
    }
    self.schedEnableButtonInfo = {
        text = string.upper(self.i18n:getText("PS_BTN_SCHED_TOGGLE") or "ENABLE SCHEDULE"),
        inputAction = InputAction.MENU_EXTRA_2,
        callback = function() self:menuSchedEnable() end,
    }
    self.toggleMonthButtonInfo = {
        text = string.upper(self.i18n:getText("PS_COL_MONTH") or "TOGGLE MONTH"),
        inputAction = InputAction.MENU_ACTIVATE,
        callback = function() self:menuToggleFocusedMonth() end,
    }

    self:setMenuButtonInfo({
        self.backButtonInfo,
        self.refreshButtonInfo,
        self.exportButtonInfo,
    })

    self.insightsActive = false
    if ProductionInsightsView ~= nil then
        self.insights = ProductionInsightsView.new(self)
    end

    return self
end

function InGameMenuProductionsManager:copyAttributes(src)
    InGameMenuProductionsManager:superClass().copyAttributes(self, src)
    self.i18n = src.i18n
end

InGameMenuProductionsManager.LIST_IDS = {
    "inputsTable", "outputsTable", "recipesTable", "financesTable", "logisticsTable",
}

function InGameMenuProductionsManager:onGuiSetupFinished()
    InGameMenuProductionsManager:superClass().onGuiSetupFinished(self)
    for _, id in ipairs(self.LIST_IDS) do
        local list = self[id]
        if list ~= nil then
            list:setDataSource(self)
            list:setDelegate(self)
        end
    end
end

function InGameMenuProductionsManager:getNumberOfSections()
    return 1
end

-- Called once after injection to wire the sub-tab buttons, page containers and lists.
function InGameMenuProductionsManager:initialize()
    local CAT = self.CATEGORIES
    self.subCategoryTabs[CAT.INPUTS]    = self.inputsTab
    self.subCategoryTabs[CAT.OUTPUTS]   = self.outputsTab
    self.subCategoryTabs[CAT.RECIPES]   = self.recipesTab
    self.subCategoryTabs[CAT.FINANCES]  = self.financesTab
    self.subCategoryTabs[CAT.LOGISTICS] = self.logisticsTab
    self.subCategoryTabs[CAT.STOCK]     = self.stockTab
    self.subCategoryTabs[CAT.PROFIT]    = self.profitTab
    self.subCategoryTabs[CAT.ANIMALS]   = self.animalsTab
    self.subCategoryTabs[CAT.NETWORK]   = self.networkTab
    self.subCategoryTabs[CAT.TASKS]     = self.tasksTab

    self.subCategoryPages = {
        [CAT.INPUTS]    = self.inputsPage,
        [CAT.OUTPUTS]   = self.outputsPage,
        [CAT.RECIPES]   = self.recipesPage,
        [CAT.FINANCES]  = self.financesPage,
        [CAT.LOGISTICS] = self.logisticsPage,
        [CAT.STOCK]     = self.insightsPage,
        [CAT.PROFIT]    = self.insightsPage,
        [CAT.ANIMALS]   = self.insightsPage,
        [CAT.NETWORK]   = self.insightsPage,
        [CAT.TASKS]     = self.insightsPage,
    }
    self.pageLists = {
        [CAT.INPUTS]    = self.inputsTable,
        [CAT.OUTPUTS]   = self.outputsTable,
        [CAT.RECIPES]   = self.recipesTable,
        [CAT.FINANCES]  = self.financesTable,
        [CAT.LOGISTICS] = self.logisticsTable,
    }

    for key = 1, self.NUM_CATEGORIES do
        if self.subCategoryPaging ~= nil then
            self.subCategoryPaging:addText(tostring(key))
        end
        local tab = self.subCategoryTabs[key]
        if tab ~= nil then
            local bg = tab:getDescendantByName("background")
            if bg ~= nil then
                bg:setSize(tab.size[1], tab.size[2])
            end
            tab.onClickCallback = function() self:updateSubCategoryPages(key) end
        end
    end

    if self.subCategoryPaging ~= nil and self.subCategoryBox ~= nil then
        self.subCategoryPaging:setSize(self.subCategoryBox.maxFlowSize + 140 * g_pixelSizeScaledX)
    end

    if self.insights ~= nil then
        self.insights:bind()
    end
end

function InGameMenuProductionsManager:onFrameOpen()
    InGameMenuProductionsManager:superClass().onFrameOpen(self)
    self.lastUpdateTime = 0
    self.showSchedule = false
    self.overviewTable = self.inputsTable   -- active list, repointed on tab switch
    self:loadProductionData()
    self:updateSubCategoryPages(self.CATEGORIES.INPUTS)
    self:updateBalance()
    if self.inputsTable ~= nil then
        FocusManager:setFocus(self.inputsTable)
    end
end

function InGameMenuProductionsManager:updateBalance()
    if self.currentBalanceText ~= nil and g_currentMission ~= nil then
        local farmId  = g_currentMission:getFarmId()
        local balance = g_currentMission:getMoney(farmId)
        self.currentBalanceText:setText(g_i18n:formatMoney(balance, 0, true, true))
    end
end

function InGameMenuProductionsManager:onFrameClose()
    InGameMenuProductionsManager:superClass().onFrameClose(self)
    self.productions = {}
    self.displayRows = {}
    self.insightsActive = false
    if self.insights ~= nil then self.insights:close() end
end

function InGameMenuProductionsManager:update(dt)
    InGameMenuProductionsManager:superClass().update(self, dt)
    self.lastUpdateTime = self.lastUpdateTime + dt
    if self.lastUpdateTime >= self.autoRefreshInterval then
        self.lastUpdateTime = 0
        -- Don't yank data out from under the schedule editing flow; the Insights
        -- sub-tabs refresh on demand instead
        if not self.showSchedule and not self.insightsActive then
            self:updateContent()
        end
    end
end

-- Reload data and re-render the current sub-tab.
function InGameMenuProductionsManager:updateContent()
    local idx = nil
    if self.overviewTable ~= nil and self.overviewTable.getSelectedIndexInSection ~= nil then
        idx = self.overviewTable:getSelectedIndexInSection()
    end
    self:loadProductionData()   -- rebuilds self.productions + displayRows + reloadData
    if idx ~= nil and self.overviewTable ~= nil and self.overviewTable.setSelectedIndex ~= nil then
        if idx > 0 and idx <= #self.displayRows then
            self.overviewTable:setSelectedIndex(idx)
        end
    end
    self:updateBalance()
end

-- Switch sub-tab: set the page flags, swap the header, rebuild the list, and
-- publish this tab's footer buttons.
function InGameMenuProductionsManager:updateSubCategoryPages(state)
    local CAT = self.CATEGORIES

    -- Show the active page container, hide the rest (TenantFarmer-style). The
    -- Insights sub-tabs share one container, so hide everything first.
    for i = 1, self.NUM_CATEGORIES do
        if self.subCategoryPages ~= nil and self.subCategoryPages[i] ~= nil then
            self.subCategoryPages[i]:setVisible(false)
        end
        if self.subCategoryTabs[i] ~= nil then
            self.subCategoryTabs[i]:setSelected(i == state)
        end
    end
    if self.subCategoryPages ~= nil and self.subCategoryPages[state] ~= nil then
        self.subCategoryPages[state]:setVisible(true)
    end
    if self.subCategoryPaging ~= nil then
        self.subCategoryPaging.state = state
    end

    -- Insights sub-tabs: hand the page, title and footer to the view
    local insightsView = self.INSIGHTS_VIEWS[state]
    if insightsView ~= nil and self.insights ~= nil then
        self.insightsActive = true
        self.showSchedule = false
        self.insights:open(insightsView)
        return
    end
    self.insightsActive = false
    if self.categoryHeaderText ~= nil then
        self.categoryHeaderText:setText(self.i18n:getText("ui_productionDlg_title"))
    end

    -- Repoint the active list so the reused render methods target it
    if self.pageLists ~= nil then
        self.overviewTable = self.pageLists[state]
    end

    -- Leaving any schedule editing when a tab is picked
    self.showSchedule  = false
    self.showFinances  = false
    self.showRecipes   = false
    self.showLogistics = false
    self.showInputs    = (state == CAT.INPUTS)

    if state == CAT.OUTPUTS then
        self.showInputs = false
    elseif state == CAT.RECIPES then
        self.showRecipes = true
    elseif state == CAT.FINANCES then
        self.showLogistics = false
        self.showFinances = true
    elseif state == CAT.LOGISTICS then
        self.showLogistics = true
    end

    -- Logistics page owns two headers; default to the logistics one
    if self.logisticsHeaderBox ~= nil then self.logisticsHeaderBox:setVisible(true) end
    if self.scheduleHeaderBox  ~= nil then self.scheduleHeaderBox:setVisible(false) end

    self.selectedLogisticsRow = nil
    self.selectedRecipeRow    = nil

    self:buildDisplayRows()         -- aliased; builds rows for the active page's flags
    if self.overviewTable ~= nil then
        self.overviewTable:reloadData()
    end

    -- Footer per tab. Logistics gets the row actions; others just Back/Refresh/Export.
    if state == CAT.LOGISTICS then
        self.changeOutputButtonInfo.disabled = true
        self.activateButtonInfo.disabled     = true
        self.scheduleButtonInfo.disabled     = true
        self:setMenuButtonInfo({
            self.backButtonInfo,
            self.refreshButtonInfo,
            self.changeOutputButtonInfo,
            self.activateButtonInfo,
            self.scheduleButtonInfo,
        })
    else
        self:setMenuButtonInfo({
            self.backButtonInfo,
            self.refreshButtonInfo,
            self.exportButtonInfo,
        })
    end
    self:setMenuButtonInfoDirty()
end

-- Full logistics-row selection: mirror the dialog's data setup (selectedLogisticsRow
-- + selectedRecipeRow) and enable/label the footer action buttons accordingly.
function InGameMenuProductionsManager:onListSelectionChanged(list, section, index)
    if list ~= self.overviewTable then return end
    if self.showSchedule then return end
    if not self.showLogistics then
        self.selectedLogisticsRow = nil
        self.selectedRecipeRow    = nil
        return
    end

    local row = self.displayRows[index]
    if row ~= nil and row.rowType == "logistics" then
        self.selectedLogisticsRow = row

        local productionPoint = row.production.productionPoint
        local recipeName      = row.logistic.recipe
        local recipeProduction = nil
        if productionPoint ~= nil and productionPoint.productions ~= nil then
            for _, prod in pairs(productionPoint.productions) do
                if prod.name == recipeName then
                    recipeProduction = prod
                    break
                end
            end
        end

        if recipeProduction ~= nil then
            local running = recipeProduction.status == ProductionPoint.PROD_STATUS.RUNNING
                         or recipeProduction.status == ProductionPoint.PROD_STATUS.MISSING_INPUTS
            self.selectedRecipeRow = {
                production = row.production,
                recipe = { production = recipeProduction, isActive = running },
            }
            self.activateButtonInfo.text = string.upper(
                running and self.i18n:getText("ui_productionDlg_btnDeactivate")
                        or  self.i18n:getText("ui_productionDlg_btnActivate"))
            self.activateButtonInfo.disabled = false
        else
            self.selectedRecipeRow = nil
            self.activateButtonInfo.disabled = true
        end

        self.changeOutputButtonInfo.disabled = false
        self.scheduleButtonInfo.disabled     = false
    else
        self.selectedLogisticsRow = nil
        self.selectedRecipeRow    = nil
        self.changeOutputButtonInfo.disabled = true
        self.activateButtonInfo.disabled     = true
        self.scheduleButtonInfo.disabled     = true
    end

    self:setMenuButtonInfoDirty()
end

-- ============================================================
-- Logistics row actions (reuse dialog handlers, then refresh footer state)
-- ============================================================

function InGameMenuProductionsManager:onChangeOutput()
    if self.selectedLogisticsRow == nil then return end
    self:onClickChangeOutput()   -- aliased; nil-guards its dialog-only button refs
end

function InGameMenuProductionsManager:onToggleRecipe()
    if self.selectedRecipeRow == nil then return end
    self:onClickToggleRecipe()   -- aliased
end

-- ============================================================
-- Schedule flow (open from a selected Logistics row)
-- ============================================================

function InGameMenuProductionsManager:menuOpenSchedule()
    if self.selectedLogisticsRow == nil or ProductionScheduleManager == nil then return end

    -- Reuse the dialog's context setup: it sets ProductionScheduleManager ctx*
    -- fields and self.schedulePeak, then calls enterScheduleView(). We provide our
    -- own enterScheduleView() below (menu version) so the dialog method drives it.
    self:onClickSchedule()
end

-- The reused onClickSchedule() ends by calling self:enterScheduleView(); this menu
-- override swaps the logistics page into month-editing mode (schedule header + month
-- rows in the same list), instead of the dialog's button juggling.
function InGameMenuProductionsManager:enterScheduleView()
    self.showSchedule = true
    self.overviewTable = self.logisticsTable
    if self.logisticsHeaderBox ~= nil then self.logisticsHeaderBox:setVisible(false) end
    if self.scheduleHeaderBox  ~= nil then self.scheduleHeaderBox:setVisible(true) end
    self:buildDisplayRows()
    if self.overviewTable ~= nil then
        self.overviewTable:reloadData()
        if self.overviewTable.setSelectedIndex ~= nil then
            self.overviewTable:setSelectedIndex(1, true)
        end
    end
    self:refreshScheduleFooter()
end

function InGameMenuProductionsManager:refreshScheduleFooter()
    -- All-months label reflects current state
    local months = (ProductionScheduleManager ~= nil and ProductionScheduleManager.ctxMonths) or {}
    local allOn = true
    for i = 1, 12 do if months[i] ~= true then allOn = false; break end end
    self.allMonthsButtonInfo.text = string.upper(
        allOn and self.i18n:getText("PS_BTN_ALL_TOGGLE_OFF")
              or  self.i18n:getText("PS_BTN_ALL_TOGGLE_ON"))

    local enabled = (ProductionScheduleManager ~= nil and ProductionScheduleManager.ctxScheduleEnabled == true)
    local stateKey = enabled and "PS_STATE_ACTIVE" or "PS_STATE_INACTIVE"
    self.schedEnableButtonInfo.text = string.upper(
        self.i18n:getText("PS_BTN_SCHED_TOGGLE") .. ": " .. self.i18n:getText(stateKey))

    self:setMenuButtonInfo({
        self.cancelScheduleButtonInfo,
        self.toggleMonthButtonInfo,
        self.allMonthsButtonInfo,
        self.schedEnableButtonInfo,
        self.commitButtonInfo,
    })
    self:setMenuButtonInfoDirty()
end

function InGameMenuProductionsManager:menuExitSchedule()
    self.showSchedule = false
    self.schedulePeak = nil
    self:updateSubCategoryPages(self.CATEGORIES.LOGISTICS)
end

function InGameMenuProductionsManager:menuCommitSchedule()
    if ProductionScheduleManager ~= nil then
        ProductionScheduleManager:commitFromUI()
    end
    self:menuExitSchedule()
end

function InGameMenuProductionsManager:menuAllMonths()
    self:onClickAllMonths()   -- aliased: toggles all + rebuilds list
    self:refreshScheduleFooter()
end

function InGameMenuProductionsManager:menuSchedEnable()
    self:onClickSchedEnable() -- aliased: flips ctxScheduleEnabled
    self:refreshScheduleFooter()
end

function InGameMenuProductionsManager:menuToggleFocusedMonth()
    if not self.showSchedule or self.overviewTable == nil then return end
    local idx = self.overviewTable:getSelectedIndexInSection()
    if idx == nil then return end
    local row = self.displayRows[idx]
    if row ~= nil and row.rowType == "schedule" then
        self:toggleScheduleMonth(row.monthIdx)   -- aliased
        self:refreshScheduleFooter()
    end
end

-- Schedule-view month toggle click (rows carry psMonthIdx), harmless elsewhere.
function InGameMenuProductionsManager:onClickTableRow(element)
    if not self.showSchedule then return end
    if element == nil then return end
    local idx = element.psMonthIdx
    if idx == nil then return end
    self:toggleScheduleMonth(idx)
end

-- ============================================================
-- Reuse the dialog's data + rendering (see header comment).
-- Aliased only AFTER ProductionDlgFrame has been sourced.
-- ============================================================
if ProductionDlgFrame ~= nil then
    local reuse = {
        "loadProductionData",
        "buildDisplayRows",
        "buildScheduleRows",
        "getDistributionDestination",
        "getSelectedProduction",
        "formatNumber",
        "getNumberOfItemsInSection",
        "populateCellForItemInSection",
        "onClickExportCSV",
        "toggleScheduleMonth",
        "onClickChangeOutput",
        "onClickToggleRecipe",
        "onClickSchedule",
        "onClickAllMonths",
        "onClickSchedEnable",
    }
    for _, name in ipairs(reuse) do
        if ProductionDlgFrame[name] ~= nil then
            InGameMenuProductionsManager[name] = ProductionDlgFrame[name]
        end
    end
end
