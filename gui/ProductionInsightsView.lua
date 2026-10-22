-- ProductionInsightsView.lua
-- The Stock, Profitability, Animals, Network (Productions Logistics) and This Month
-- sub-tabs of the Productions Manager screen.
--
-- The Productions Manager frame owns the tab bar, title, balance and footer; when
-- one of these sub-tabs is picked it hands over to this view, which fills the shared
-- "insightsPage" list and publishes its own footer buttons through the host.
--
-- All five views share one list and one header row. Each view is a row builder that
-- turns module data into generic rows:
--   { name, nameIcon, nameColor, cols = { {text, color, icon} x5 }, status,
--     statusColor, wide, wideColor, heading, data }
-- and populateCellForItemInSection renders any row the same way. Selecting a row
-- and pressing Details swaps the list for a drill-down of that row (self.detail),
-- the same way the Logistics tab swaps in its schedule editor.

ProductionInsightsView = {}
local ProductionInsightsView_mt = { __index = ProductionInsightsView }

ProductionInsightsView.VIEW = { STOCK = 1, PROFIT = 2, ANIMALS = 3, NETWORK = 4, TASKS = 5 }
ProductionInsightsView.VIEW_TITLES = { "pi_tab_stock", "pi_tab_profit", "pi_tab_animals", "pi_tab_network", "pi_tab_tasks" }

ProductionInsightsView.HEADERS = {
    { "pi_hdr_product", "pi_hdr_stock", "pi_hdr_priceNow", "pi_hdr_valueNow", "pi_hdr_bestMonth", "pi_hdr_bestValue", "pi_hdr_alert" },
    { "pi_hdr_facility", "pi_hdr_recipe", "pi_hdr_cost1000", "pi_hdr_value1000", "pi_hdr_profit1000", "pi_hdr_profitMonth", "pi_hdr_source" },
    { "pi_hdr_pen", "pi_hdr_animals", "pi_hdr_age", "pi_hdr_condition", "pi_hdr_value", "pi_hdr_advice", "pi_hdr_repro" },
    { "pi_hdr_building", "pi_hdr_role", "pi_hdr_level", "pi_hdr_rule", "pi_hdr_thisMonth", "pi_hdr_income", "" },
    { "pi_hdr_category", "pi_hdr_task", "", "", "", "", "" },
}
ProductionInsightsView.DETAIL_HEADERS = { "pi_hdr_detail", "", "", "", "", "", "" }

-- This Month rows: info / warning / urgent
ProductionInsightsView.SEVERITY_COLORS = {
    [1] = {0.85, 0.85, 0.85, 1},
    [2] = {1, 0.75, 0.2, 1},
    [3] = {1, 0.35, 0.3, 1},
}

ProductionInsightsView.PROFIT_FILTERS = { "pi_filter_all", "pi_recipeSource_owned", "pi_recipeSource_forSale", "pi_recipeSource_shop" }
ProductionInsightsView.NETWORK_FILTERS = { false, "production", "animals", "silo" }

local C = ProductionUtil.COLOR
local U = ProductionUtil

local function col(text, color, icon)
    return { text = text, color = color, icon = icon }
end

local function headingRow(title, captions)
    local row = { name = title, nameColor = C.GOLD, heading = true, cols = {} }
    for i, caption in ipairs(captions or {}) do
        row.cols[i] = col(caption ~= "" and g_i18n:getText(caption) or nil, C.CAPTION)
    end
    return row
end

local function noteRow(text, color)
    return { wide = text, wideColor = color or C.CAPTION }
end

local function signColor(value)
    if value == nil then return C.GREY end
    return value >= 0 and C.GREEN or C.RED
end

local function money(value)
    if value == nil then return "-" end
    return U.formatMoney(value)
end

-- ------------------------------------------------------------------
-- Construction
-- ------------------------------------------------------------------

-- host: the InGameMenuProductionsManager frame
function ProductionInsightsView.new(host)
    local self = setmetatable({}, ProductionInsightsView_mt)
    self.host = host

    self.view = self.VIEW.STOCK
    self.detail = nil
    self.rows = {}
    self.selectedIndex = 1

    self.stockShowAll = false
    self.profitFilter = 1
    self.profitSortMonthly = true
    self.networkFilter = 1

    local function button(textKey, action, callback)
        return { text = string.upper(g_i18n:getText(textKey)), inputAction = action, callback = callback }
    end

    self.backButtonInfo    = host.backButtonInfo or { inputAction = InputAction.MENU_BACK }
    self.detailsButtonInfo = button("pi_btn_details", InputAction.MENU_ACCEPT, function() self:onDetails() end)
    self.closeDetailButtonInfo = button("pi_btn_closeDetails", InputAction.MENU_ACCEPT, function() self:closeDetail() end)
    self.refreshButtonInfo = button("ui_refresh", InputAction.MENU_EXTRA_2, function() self:refresh() end)
    self.filterButtonInfo  = button("pi_btn_filter", InputAction.MENU_EXTRA_1, function() self:onFilter() end)
    self.sortButtonInfo    = button("pi_btn_sort", InputAction.MENU_EXTRA_2, function() self:onSort() end)
    self.alertButtonInfo   = button("pi_btn_alert", InputAction.MENU_ACTIVATE, function() self:onAlert() end)
    self.modeButtonInfo    = button("pi_btn_mode", InputAction.MENU_ACTIVATE, function() self:onRuleChange("mode") end)
    self.reserveButtonInfo = button("pi_btn_reserve", InputAction.MENU_EXTRA_2, function() self:onRuleChange("reserve") end)
    self.blockButtonInfo   = button("pi_btn_block", InputAction.MENU_ACTIVATE, function() self:onRuleChange("blocked") end)
    self.priorityButtonInfo = button("pi_btn_priority", InputAction.MENU_CANCEL, function() self:onRuleChange("priority") end)
    self.targetButtonInfo  = button("pi_btn_target", InputAction.MENU_EXTRA_2, function() self:onRuleChange("target") end)
    self.acceptButtonInfo  = button("pi_btn_accept", InputAction.MENU_ACTIVATE, function() self:onRuleChange("accept") end)

    return self
end

-- Takes over the host's shared list and header texts (after the GUI is loaded)
function ProductionInsightsView:bind()
    local host = self.host
    self.piList = host.piList
    for i = 0, 6 do
        self["piHeader" .. i] = host["piHeader" .. i]
    end
    self.piTitleText = host.categoryHeaderText
    if self.piList ~= nil then
        self.piList:setDataSource(self)
        self.piList:setDelegate(self)
    end
end

-- Called by the host when one of the Insights sub-tabs is picked
function ProductionInsightsView:open(view)
    self:setView(view)
    if self.piList ~= nil then FocusManager:setFocus(self.piList) end
end

function ProductionInsightsView:close()
    self.rows = {}
    self.detail = nil
    self.allRecipes = nil
end

-- ------------------------------------------------------------------
-- View switching and data
-- ------------------------------------------------------------------

function ProductionInsightsView:setView(view)
    self.view = view
    self.detail = nil
    self.selectedIndex = 1
    self:refresh()
end

function ProductionInsightsView:loadData()
    local farmId = U.getFarmId()
    local V = self.VIEW
    ProductionPrices:invalidate()

    if self.view == V.STOCK then
        self.stock = ProductionStock:getProducts(farmId, self.stockShowAll)
    elseif self.view == V.PROFIT then
        self.recipes = ProductionRecipes:getRecipes(farmId, true)
    elseif self.view == V.ANIMALS then
        self.pens = ProductionAnimals:getPens(farmId)
    elseif self.view == V.NETWORK then
        self.nodes = ProductionLogistics:getNodes(farmId)
    elseif self.view == V.TASKS then
        ProductionTasks:rebuild()
    end
end

-- Reload data and rebuild the current view (or detail) keeping the selection
function ProductionInsightsView:refresh()
    local ok, err = pcall(self.loadData, self)
    if not ok then
        Logging.warning("[ProductionsManager] Insights data load failed (%s)", tostring(err))
    end
    self:rebuild()
    self:updateBalance()
end

function ProductionInsightsView:rebuild()
    local rows
    local ok, result = pcall(function()
        if self.detail ~= nil then
            return self:buildDetailRows()
        end
        return self:buildViewRows()
    end)
    if ok then
        rows = result or {}
    else
        Logging.warning("[ProductionsManager] Insights view failed (%s)", tostring(result))
        rows = { noteRow(g_i18n:getText("pi_note_error"), C.RED) }
    end
    if #rows == 0 then
        rows = { noteRow(g_i18n:getText("pi_note_empty")) }
    end
    self.rows = rows

    self:updateHeader()
    self:updateTitle()
    if self.piList ~= nil then
        self.piList:reloadData()
        local index = math.max(1, math.min(self.selectedIndex or 1, #self.rows))
        self.piList:setSelectedIndex(index)
        self.selectedIndex = index
    end
    self:updateFooter()
end

function ProductionInsightsView:buildViewRows()
    local V = self.VIEW
    if self.view == V.STOCK then return self:buildStockRows() end
    if self.view == V.PROFIT then return self:buildProfitRows() end
    if self.view == V.ANIMALS then return self:buildAnimalRows() end
    if self.view == V.NETWORK then return self:buildNetworkRows() end
    return self:buildTaskRows()
end

function ProductionInsightsView:buildDetailRows()
    local kind = self.detail.kind
    if kind == "product" then return self:buildProductDetail(self.detail.data) end
    if kind == "recipe" then return self:buildRecipeDetail(self.detail.data) end
    if kind == "pen" then return self:buildPenDetail(self.detail.data) end
    return {}
end

function ProductionInsightsView:getSelectedRow()
    return self.rows[self.selectedIndex or 0]
end

function ProductionInsightsView:updateHeader()
    local keys = self.detail ~= nil and self.DETAIL_HEADERS or self.HEADERS[self.view]
    for i = 0, 6 do
        local element = self["piHeader" .. i]
        if element ~= nil then
            local key = keys[i + 1]
            element:setText(key ~= nil and key ~= "" and g_i18n:getText(key) or "")
        end
    end
end

function ProductionInsightsView:updateTitle()
    -- The header keeps the page name only; filter and sort state live on the
    -- footer buttons (see filterLabel / updateFooter) so the title never overflows.
    if self.piTitleText == nil then return end
    self.piTitleText:setText(g_i18n:getText("ui_productionDlg_title"))
end

-- Current filter of the active view, shown on the Filter button
function ProductionInsightsView:filterLabel()
    local V = self.VIEW
    if self.view == V.STOCK then
        return g_i18n:getText(self.stockShowAll and "pi_filter_allSellable" or "pi_filter_inStock")
    elseif self.view == V.PROFIT then
        return g_i18n:getText(self.PROFIT_FILTERS[self.profitFilter])
    elseif self.view == V.NETWORK then
        local kind = self.NETWORK_FILTERS[self.networkFilter]
        return kind and g_i18n:getText("pi_nodeKind_" .. kind) or g_i18n:getText("pi_filter_all")
    end
    return nil
end

function ProductionInsightsView:updateBalance()
    if self.host.updateBalance ~= nil then
        self.host:updateBalance()
    end
end

-- ------------------------------------------------------------------
-- Footer
-- ------------------------------------------------------------------

function ProductionInsightsView:updateFooter()
    local V = self.VIEW
    local row = self:getSelectedRow()
    local data = row ~= nil and row.data or nil
    local buttons = { self.backButtonInfo }

    local function add(info, enabled)
        info.disabled = not enabled
        table.insert(buttons, info)
    end

    local filter = self:filterLabel()
    self.filterButtonInfo.text = string.upper(g_i18n:getText("pi_btn_filter")
        .. (filter ~= nil and (": " .. filter) or ""))
    self.sortButtonInfo.text = string.upper(g_i18n:getText("pi_btn_sort") .. ": "
        .. g_i18n:getText(self.profitSortMonthly and "pi_sort_monthly" or "pi_sort_per1000"))

    if self.detail ~= nil then
        table.insert(buttons, self.closeDetailButtonInfo)
        if self.detail.kind == "product" then
            self.alertButtonInfo.text = self:alertButtonText(self.detail.data)
            add(self.alertButtonInfo, true)
        end
    elseif self.view == V.STOCK then
        add(self.detailsButtonInfo, data ~= nil)
        self.alertButtonInfo.text = self:alertButtonText(data)
        add(self.alertButtonInfo, data ~= nil)
        add(self.filterButtonInfo, true)
        add(self.refreshButtonInfo, true)
    elseif self.view == V.PROFIT then
        add(self.detailsButtonInfo, data ~= nil)
        add(self.filterButtonInfo, true)
        add(self.sortButtonInfo, true)
    elseif self.view == V.ANIMALS then
        add(self.detailsButtonInfo, data ~= nil)
        add(self.refreshButtonInfo, true)
    elseif self.view == V.NETWORK then
        local kind = data ~= nil and data.kind or nil
        if kind == "output" then
            add(self.modeButtonInfo, true)
            add(self.reserveButtonInfo, true)
        elseif kind == "input" then
            local rule = ProductionLogistics:getRule(data.node.key, data.productKey, data.node.kind)
            self.blockButtonInfo.text = string.upper(g_i18n:getText(rule.blocked and "pi_btn_unblock" or "pi_btn_block"))
            add(self.blockButtonInfo, true)
            add(self.priorityButtonInfo, true)
            add(self.targetButtonInfo, true)
        elseif kind == "node" and data.node.kind == ProductionLogistics.KIND_SILO then
            add(self.acceptButtonInfo, true)
        end
        add(self.filterButtonInfo, true)
    elseif self.view == V.TASKS then
        add(self.refreshButtonInfo, true)
    end

    self.host:setMenuButtonInfo(buttons)
    self.host:setMenuButtonInfoDirty()
end

-- ------------------------------------------------------------------
-- List data source
-- ------------------------------------------------------------------

function ProductionInsightsView:getNumberOfSections()
    return 1
end

function ProductionInsightsView:getNumberOfItemsInSection(list, section)
    return #self.rows
end

function ProductionInsightsView:onListSelectionChanged(list, section, index)
    self.selectedIndex = index
    self:updateFooter()
end

function ProductionInsightsView:populateCellForItemInSection(list, section, index, cell)
    local row = self.rows[index]
    if row == nil then return end

    local function setText(name, text, color)
        local element = cell:getAttribute(name)
        if element == nil then return end
        if text == nil or text == "" then
            element:setVisible(false)
            return
        end
        local c = color or C.WHITE
        element:setText(text)
        element:setTextColor(c[1], c[2], c[3], c[4])
        element:setVisible(true)
    end

    local function setIcon(name, filename)
        local element = cell:getAttribute(name)
        if element == nil then return end
        if filename ~= nil and filename ~= "" then
            element:setImageFilename(filename)
            element:setVisible(true)
        else
            element:setVisible(false)
        end
    end

    setIcon("nameIcon", row.nameIcon)
    setText("nameText", row.name, row.nameColor)
    for i = 1, 5 do
        local c = row.cols ~= nil and row.cols[i] or nil
        setIcon("icon" .. i, c ~= nil and c.icon or nil)
        setText("text" .. i, c ~= nil and c.text or nil, c ~= nil and c.color or nil)
    end
    setText("statusText", row.status, row.statusColor)
    setText("wideText", row.wide, row.wideColor)
end

-- ==================================================================
-- STOCK
-- ==================================================================

function ProductionInsightsView:buildStockRows()
    local rows = {}
    local totalNow, totalBest = 0, 0
    for _, product in ipairs(self.stock or {}) do
        local peak = product.peak
        local nowText = "-"
        if product.priceNow ~= nil then
            nowText = U.formatPer1000(product.priceNow) .. " @ " .. (product.stationNow or "?")
        end
        local status, statusColor = nil, nil
        if product.alert ~= nil then
            status, statusColor = g_i18n:getText("pi_alert_on"), C.GOLD
        end
        if peak ~= nil and peak.isNow and product.liters > 0 then
            status, statusColor = g_i18n:getText("pi_peakNow"), C.GREEN
        end
        table.insert(rows, {
            name = product.title, nameIcon = product.icon, data = product,
            cols = {
                col(U.formatLiters(product.liters), product.liters > 0 and C.WHITE or C.GREY),
                col(nowText, product.priceNow ~= nil and C.WHITE or C.GREY),
                col(money(product.valueNow)),
                col(peak ~= nil and U.formatPeriods(peak.periods) or "-", peak ~= nil and peak.isNow and C.GREEN or C.WHITE),
                col(money(product.peakValue), C.GREEN),
            },
            status = status, statusColor = statusColor,
        })
        totalNow = totalNow + (product.valueNow or 0)
        totalBest = totalBest + (product.peakValue or 0)
    end
    if #rows > 0 then
        table.insert(rows, {})
        table.insert(rows, { name = g_i18n:getText("pi_total"), nameColor = C.GOLD,
            cols = { nil, nil, col(money(totalNow), C.GOLD), nil, col(money(totalBest), C.GOLD) } })
    end
    return rows
end

function ProductionInsightsView:buildProductDetail(product)
    local rows = {}
    local fillTypeIndex = product.fillTypeIndex

    table.insert(rows, headingRow(g_i18n:getText("pi_detail_where"), { "pi_hdr_amount", "pi_hdr_count" }))
    local any = false
    for _, sourceKey in ipairs(ProductionStock.SOURCE_ORDER) do
        local source = product.sources[sourceKey]
        if source ~= nil and source.liters > 0 then
            any = true
            table.insert(rows, { name = ProductionStock.sourceTitle(sourceKey),
                cols = { col(U.formatLiters(source.liters)), col(source.count > 0 and tostring(source.count) or nil) } })
            for place, liters in pairs(source.places) do
                table.insert(rows, { name = "   " .. place, nameColor = C.CAPTION,
                    cols = { col(U.formatLiters(liters), C.CAPTION) } })
            end
        end
    end
    if not any then table.insert(rows, noteRow(g_i18n:getText("pi_note_noStock"))) end

    table.insert(rows, {})
    table.insert(rows, headingRow(g_i18n:getText("pi_detail_sellPoints"), { "pi_hdr_price1000", "pi_hdr_stockValue", "pi_hdr_bestMonthPrice" }))
    local stations = ProductionPrices:getStations(fillTypeIndex)
    local peak = product.peak
    local nowFactor = ProductionPrices:getSeasonFactor(fillTypeIndex, U.getPeriod())
    local peakFactor = 1
    if peak ~= nil then
        for period in pairs(peak.periods) do
            peakFactor = ProductionPrices:getSeasonFactor(fillTypeIndex, period) / nowFactor
            break
        end
    end
    for i, station in ipairs(stations) do
        if i > 10 then break end
        table.insert(rows, { name = station.stationName, nameColor = i == 1 and C.GREEN or nil,
            cols = { col(U.formatPer1000(station.price)), col(money(station.price * product.liters)),
                     col(U.formatPer1000(station.price * peakFactor), C.GREEN) } })
    end
    if #stations == 0 then table.insert(rows, noteRow(g_i18n:getText("pi_note_noSellPoint"))) end

    if #stations > 0 then
        table.insert(rows, {})
        table.insert(rows, headingRow(g_i18n:getText("pi_detail_byMonth"), { "pi_hdr_price1000", "pi_hdr_stockValue" }))
        local current = U.getPeriod()
        for period = 1, 12 do
            local price = ProductionPrices:getPriceInPeriod(fillTypeIndex, period)
            local isPeak = peak ~= nil and peak.periods[period]
            table.insert(rows, {
                name = U.periodName(period), nameColor = period == current and C.BLUE or nil,
                cols = { col(U.formatPer1000(price), isPeak and C.GREEN or nil), col(money(price ~= nil and price * product.liters or nil)) },
                status = isPeak and g_i18n:getText("PS_PEAK_MARK") or (period == current and g_i18n:getText("pi_now") or nil),
                statusColor = isPeak and C.GREEN or C.BLUE,
            })
        end
    end

    table.insert(rows, {})
    table.insert(rows, headingRow(g_i18n:getText("pi_detail_bestUse"), { "pi_hdr_recipe", "pi_hdr_viaRecipe", "pi_hdr_uplift", "pi_hdr_source" }))
    self.allRecipes = self.allRecipes or ProductionRecipes:getRecipes(U.getFarmId(), true)
    local uses = ProductionRecipes:getBestUses(self.allRecipes, fillTypeIndex, 5)
    for _, use in ipairs(uses) do
        local entry = use.entry
        local primary = entry.economics.primary
        table.insert(rows, { name = entry.facilityName,
            cols = { col(entry.recipeName, nil, primary ~= nil and U.fillTypeIcon(primary.fillTypeIndex) or nil),
                     col(U.formatPer1000(use.perLiter)), col("+" .. U.formatPer1000(use.uplift), C.GREEN),
                     col(ProductionRecipes.sourceTitle(entry.source), C.CAPTION) } })
    end
    if #uses == 0 then table.insert(rows, noteRow(g_i18n:getText("pi_note_sellDirect"))) end

    table.insert(rows, {})
    local alert = ProductionUserData:getAlert(product.name)
    table.insert(rows, noteRow(alert ~= nil and ProductionUserData.alertText(alert) or g_i18n:getText("pi_note_noAlert"),
        alert ~= nil and C.GOLD or C.CAPTION))
    return rows
end

function ProductionInsightsView:alertButtonText(product)
    local key = "pi_btn_alert"
    if product ~= nil and product.name ~= nil and ProductionUserData:getAlert(product.name) ~= nil then
        key = "pi_btn_clearAlert"
    end
    return string.upper(g_i18n:getText(key))
end

-- Toggles the best-month alert for the selected product
function ProductionInsightsView:onAlert()
    local product = self.detail ~= nil and self.detail.data or (self:getSelectedRow() or {}).data
    if product == nil or product.name == nil then return end

    if ProductionUserData:getAlert(product.name) ~= nil then
        ProductionUserData:clearAlert(product.name)
    else
        ProductionUserData:setAlert(product.name)
    end
    self:refreshKeepingDetail()
end

-- ==================================================================
-- PROFITABILITY
-- ==================================================================

function ProductionInsightsView:buildProfitRows()
    local rows = {}
    local list = {}
    local wanted = self.profitFilter - 1   -- 0 = all, else a SOURCE_* value
    local unpriced = 0
    for _, entry in ipairs(self.recipes or {}) do
        if (wanted == 0 or entry.source == wanted) and entry.economics ~= nil and entry.economics.primary ~= nil then
            if entry.economics.incomplete then
                unpriced = unpriced + 1
            else
                table.insert(list, entry)
            end
        end
    end

    local monthly = self.profitSortMonthly
    table.sort(list, function(a, b)
        local ea, eb = a.economics, b.economics
        if monthly then return (ea.profitPerMonth or 0) > (eb.profitPerMonth or 0) end
        return (ea.profit1000 or 0) > (eb.profit1000 or 0)
    end)

    local sourceColors = { C.GREEN, C.BLUE, C.GOLD }
    for _, entry in ipairs(list) do
        local eco = entry.economics
        table.insert(rows, {
            name = entry.facilityName, data = entry,
            cols = {
                col(entry.recipeName, nil, U.fillTypeIcon(eco.primary.fillTypeIndex)),
                col(U.formatMoney(eco.cost1000 or 0), C.RED),
                col(U.formatMoney(eco.value1000 or 0)),
                col(U.formatMoney(eco.profit1000 or 0), signColor(eco.profit1000)),
                col(U.formatMoney(eco.profitPerMonth or 0), signColor(eco.profitPerMonth)),
            },
            status = ProductionRecipes.sourceTitle(entry.source) .. (eco.estimated and "*" or ""),
            statusColor = sourceColors[entry.source],
        })
    end
    if #rows > 0 then
        table.insert(rows, {})
        table.insert(rows, noteRow(g_i18n:getText("pi_note_profit")))
    end
    if unpriced > 0 then
        table.insert(rows, noteRow(U.text("pi_note_unpriced", unpriced)))
    end
    return rows
end

function ProductionInsightsView:buildRecipeDetail(entry)
    local rows = {}
    local eco = entry.economics

    table.insert(rows, noteRow(entry.facilityName .. " - " .. entry.recipeName .. "  ("
        .. ProductionRecipes.sourceTitle(entry.source) .. ")", C.GOLD))

    local function amounts(titleKey, list, isInput)
        table.insert(rows, headingRow(g_i18n:getText(titleKey), { "pi_hdr_perCycle", "pi_hdr_price1000", "pi_hdr_value", "pi_hdr_perMonth" }))
        for _, item in ipairs(list) do
            local value = isInput and item.cost or item.value
            local status, statusColor = nil, nil
            if isInput and entry.productionPoint ~= nil and entry.productionPoint.storage ~= nil then
                local have = entry.productionPoint.storage:getFillLevel(item.fillTypeIndex) or 0
                if have < item.amount then
                    status, statusColor = g_i18n:getText("pi_missing"), C.RED
                end
            end
            table.insert(rows, {
                name = U.fillTypeTitle(item.fillTypeIndex), nameIcon = U.fillTypeIcon(item.fillTypeIndex),
                cols = { col(U.formatLiters(item.amount)), col(U.formatPer1000(item.pricePerLiter)),
                         col(money(value), isInput and C.RED or C.GREEN),
                         col(U.formatLiters(item.amount * (eco.cyclesPerMonth or 0))) },
                status = status, statusColor = statusColor,
            })
        end
        if #list == 0 then table.insert(rows, noteRow("-")) end
    end
    amounts("pi_detail_inputs", entry.inputs, true)
    table.insert(rows, {})
    amounts("pi_detail_outputs", entry.outputs, false)

    table.insert(rows, {})
    table.insert(rows, headingRow(g_i18n:getText("pi_detail_economics"), { "pi_hdr_value" }))
    local function line(key, textValue, color)
        table.insert(rows, { name = g_i18n:getText(key), cols = { col(textValue, color) } })
    end
    line("pi_eco_cycles", string.format("%.1f", eco.cyclesPerMonth or 0))
    line("pi_eco_running", money(eco.runningPerMonth), C.RED)
    line("pi_eco_profitCycle", money(eco.profitPerCycle), signColor(eco.profitPerCycle))
    line("pi_eco_profitMonth", money(eco.profitPerMonth), signColor(eco.profitPerMonth))
    if eco.primaryPerMonth ~= nil then
        line("pi_eco_outputMonth", U.formatLiters(eco.primaryPerMonth))
    end
    if entry.price ~= nil and entry.price > 0 then
        line("pi_eco_price", money(entry.price))
        if (eco.profitPerMonth or 0) > 0 and entry.source ~= ProductionRecipes.SOURCE_OWNED then
            line("pi_eco_payback", U.text("pi_months", math.ceil(entry.price / eco.profitPerMonth)))
        end
    end
    if (eco.throughputFactor or 1) < 1 then
        table.insert(rows, noteRow(U.text("pi_note_shared", math.floor(1 / eco.throughputFactor + 0.5)), C.ORANGE))
    end
    if eco.incomplete then
        table.insert(rows, noteRow(g_i18n:getText("pi_note_unpricedDetail"), C.ORANGE))
    end
    if eco.estimated then
        table.insert(rows, noteRow(g_i18n:getText("pi_note_estimated"), C.ORANGE))
    end
    return rows
end

-- ==================================================================
-- ANIMALS
-- ==================================================================

local function supplyText(supply)
    if supply == nil then return nil end
    return U.formatPercent(supply.fraction)
end

function ProductionInsightsView:buildAnimalRows()
    local rows = {}
    local threshold = (ProductionSettings.insightsAnimalThreshold or 20) / 100
    for _, pen in ipairs(self.pens or {}) do
        local parts = {}
        local low = false
        for _, entry in ipairs({ { "pi_short_food", pen.food }, { "pi_short_water", (not pen.autoWater) and pen.water or nil },
                                 { "pi_short_straw", pen.straw } }) do
            if entry[2] ~= nil then
                table.insert(parts, g_i18n:getText(entry[1]) .. " " .. supplyText(entry[2]))
                low = low or entry[2].fraction <= threshold
            end
        end
        table.insert(rows, {
            name = pen.name, nameColor = C.GOLD, data = pen,
            cols = { col(string.format("%d / %d", pen.numAnimals, pen.maxAnimals)), nil,
                     col(table.concat(parts, "  "), low and C.ORANGE or C.WHITE),
                     col(money(pen.totalValue)) },
        })
        for _, group in ipairs(pen.groups) do
            local adviceColor = (group.advice == ProductionAnimals.ADVICE_SELL or group.advice == ProductionAnimals.ADVICE_PAST_PEAK) and C.GREEN
                or (group.advice == ProductionAnimals.ADVICE_HEALTH and C.ORANGE or nil)
            table.insert(rows, {
                name = "   " .. group.title, data = pen,
                cols = { col(string.format("x%d", group.num)), col(U.text("pi_months", group.age)),
                         col(U.text("pi_health", math.floor(group.health + 0.5)), group.health < ProductionAnimals.HEALTHY and C.ORANGE or nil),
                         col(money(group.totalValue)), col(ProductionAnimals.adviceText(group), adviceColor) },
                status = group.reproduction ~= nil and U.formatPercent(group.reproduction / 100) or nil,
            })
        end
        table.insert(rows, {})
    end
    return rows
end

function ProductionInsightsView:buildPenDetail(pen)
    local rows = {}
    local free = math.max(0, (pen.maxAnimals or 0) - (pen.numAnimals or 0))
    table.insert(rows, noteRow(U.text("pi_pen_summary", pen.name, pen.numAnimals, pen.maxAnimals, free, money(pen.totalValue)), C.GOLD))

    table.insert(rows, headingRow(g_i18n:getText("pi_detail_supplies"), { "pi_hdr_level", "pi_hdr_capacity", "pi_hdr_fill" }))
    local supplies = { { "pi_supply_food", pen.food }, { "pi_supply_water", pen.water }, { "pi_supply_straw", pen.straw } }
    for _, entry in ipairs(supplies) do
        local supply = entry[2]
        if supply ~= nil then
            local auto = entry[1] == "pi_supply_water" and pen.autoWater
            table.insert(rows, { name = g_i18n:getText(entry[1]),
                cols = { col(U.formatLiters(supply.level)), col(U.formatLiters(supply.capacity)),
                         col(auto and g_i18n:getText("pi_auto") or U.formatPercent(supply.fraction)) } })
        end
    end

    table.insert(rows, {})
    table.insert(rows, headingRow(g_i18n:getText("pi_detail_groups"), { "pi_hdr_count", "pi_hdr_age", "pi_hdr_value", "pi_hdr_bestAge", "pi_hdr_lifetime" }))
    local feedMonth, outputs = 0, {}
    for _, group in ipairs(pen.groups) do
        table.insert(rows, { name = group.title,
            cols = { col(string.format("x%d", group.num)), col(U.text("pi_months", group.age)),
                     col(money(group.value)), col(U.text("pi_months", group.bestAge or group.age)),
                     col(money(group.lifetimeProfit), signColor(group.lifetimeProfit)) },
            status = ProductionAnimals.adviceText(group) })
        feedMonth = feedMonth + (group.feedCostPerMonth or 0) * group.num
        for _, output in ipairs(group.outputs or {}) do
            local total = outputs[output.fillTypeIndex] or { amount = 0, value = 0 }
            total.amount = total.amount + output.amount * group.num
            total.value = total.value + output.value * group.num
            outputs[output.fillTypeIndex] = total
        end
    end

    table.insert(rows, {})
    local parallel = pen.feed ~= nil and pen.feed.parallel
    table.insert(rows, headingRow(g_i18n:getText("pi_detail_feed"), { "pi_hdr_cheapest", "pi_hdr_price1000", "pi_hdr_weight" }))
    for _, group in ipairs(pen.feed ~= nil and pen.feed.groups or {}) do
        table.insert(rows, { name = group.title,
            cols = { col(group.fillTypeIndex ~= nil and U.fillTypeTitle(group.fillTypeIndex) or "-", nil,
                         group.fillTypeIndex ~= nil and U.fillTypeIcon(group.fillTypeIndex) or nil),
                     col(U.formatPer1000(group.price)),
                     col(U.formatPercent(parallel and group.eatWeight or group.productionWeight)) } })
    end
    table.insert(rows, noteRow(g_i18n:getText(parallel and "pi_note_feedParallel" or "pi_note_feedSerial")))

    table.insert(rows, {})
    table.insert(rows, headingRow(g_i18n:getText("pi_detail_outputs"), { "pi_hdr_perMonth", "pi_hdr_value" }))
    local outputValue = 0
    for fillTypeIndex, total in pairs(outputs) do
        outputValue = outputValue + total.value
        table.insert(rows, { name = U.fillTypeTitle(fillTypeIndex), nameIcon = U.fillTypeIcon(fillTypeIndex),
            cols = { col(U.formatLiters(total.amount)), col(money(total.value), C.GREEN) } })
    end

    table.insert(rows, {})
    table.insert(rows, { name = g_i18n:getText("pi_eco_feedMonth"), cols = { col(money(feedMonth), C.RED) } })
    table.insert(rows, { name = g_i18n:getText("pi_eco_outputValue"), cols = { col(money(outputValue), C.GREEN) } })
    table.insert(rows, { name = g_i18n:getText("pi_eco_net"), nameColor = C.GOLD,
        cols = { col(money(outputValue - feedMonth), signColor(outputValue - feedMonth)) } })
    table.insert(rows, noteRow(g_i18n:getText("pi_note_animals")))
    return rows
end

-- ==================================================================
-- NETWORK (Productions Logistics)
-- ==================================================================

local function ruleText(node, productKey, isInput)
    local rule, custom = ProductionLogistics:getRule(node.key, productKey, node.kind)
    if isInput then
        if rule.blocked then return g_i18n:getText("pi_rule_blocked"), C.RED end
        return U.text("pi_rule_input", ProductionLogistics.priorityText(rule.priority), rule.target or 75),
            custom and C.WHITE or C.CAPTION
    end
    local textValue = ProductionLogistics.modeText(rule.mode)
    if (rule.reserve or 0) > 0 then textValue = textValue .. " " .. U.text("pi_rule_reserve", rule.reserve) end
    return textValue, rule.mode == ProductionLogistics.MODE_DEFAULT and C.CAPTION or C.WHITE
end

local function statsText(node, productKey)
    local stats = ProductionLogistics:getStats(node.key, productKey)
    if stats == nil then return nil, nil end
    local month = stats.month
    local parts = {}
    if month.received > 0 then table.insert(parts, "+" .. U.formatLiters(month.received)) end
    if month.supplied > 0 then table.insert(parts, "-" .. U.formatLiters(month.supplied)) end
    if month.sold > 0 then table.insert(parts, U.text("pi_sold", U.formatLiters(month.sold))) end
    local income = month.income - month.cost
    return (#parts > 0 and table.concat(parts, " ") or nil), (month.income > 0 or month.cost > 0) and income or nil
end

function ProductionInsightsView:buildNetworkRows()
    local rows = {}
    if not ProductionLogistics.isEnabled() then
        table.insert(rows, noteRow(g_i18n:getText("pi_note_networkOff"), C.ORANGE))
    end
    if not U.isServer() then
        table.insert(rows, noteRow(g_i18n:getText("pi_note_networkClient")))
    end

    local wanted = self.NETWORK_FILTERS[self.networkFilter]
    local nodes = {}
    for _, node in ipairs(self.nodes or {}) do
        if not wanted or node.kind == wanted then table.insert(nodes, node) end
    end
    table.sort(nodes, function(a, b)
        if a.kind ~= b.kind then return a.kind < b.kind end
        return a.name < b.name
    end)

    for _, node in ipairs(nodes) do
        local status = nil
        if node.kind == ProductionLogistics.KIND_SILO then
            local rule = ProductionLogistics:getRule(node.key, ProductionLogistics.BUILDING_KEY, node.kind)
            status = g_i18n:getText(rule.blocked and "pi_silo_closed" or "pi_silo_open")
        end
        table.insert(rows, { name = node.name, nameColor = C.GOLD, data = { kind = "node", node = node },
            cols = { col(g_i18n:getText("pi_nodeKind_" .. node.kind), C.CAPTION) },
            status = status, statusColor = C.CAPTION })

        local inputKeys = {}
        for productKey in pairs(node.inputs) do table.insert(inputKeys, productKey) end
        table.sort(inputKeys)
        for _, productKey in ipairs(inputKeys) do
            local input = node.inputs[productKey]
            local levelKey = input.isFood and ProductionLogistics.FOOD_KEY or input.fillTypes[1]
            local title = input.isFood and g_i18n:getText("pi_supply_food") or U.fillTypeTitle(input.fillTypes[1])
            local capacity = node:getCapacity(levelKey)
            local level = node:getLevel(levelKey)
            local ruleValue, ruleColor = ruleText(node, productKey, true)
            local moved, net = statsText(node, productKey)
            table.insert(rows, {
                name = "   " .. title, nameIcon = (not input.isFood) and U.fillTypeIcon(input.fillTypes[1]) or nil,
                data = { kind = "input", node = node, productKey = productKey },
                cols = { col(g_i18n:getText("pi_role_in"), C.BLUE),
                         col(capacity > 0 and U.formatPercent(level / capacity) .. " (" .. U.formatLiters(level) .. ")" or U.formatLiters(level)),
                         col(ruleValue, ruleColor), col(moved), col(net ~= nil and money(net) or nil, signColor(net)) },
            })
        end

        local outputs = {}
        for fillTypeIndex in pairs(node.outputs) do table.insert(outputs, fillTypeIndex) end
        table.sort(outputs, function(a, b) return U.fillTypeTitle(a) < U.fillTypeTitle(b) end)
        for _, fillTypeIndex in ipairs(outputs) do
            local productKey = ProductionLogistics.productKey(fillTypeIndex)
            local level = node:getLevel(fillTypeIndex)
            local ruleValue, ruleColor = ruleText(node, productKey, false)
            local moved, net = statsText(node, productKey)
            if level > 0 or node.kind ~= ProductionLogistics.KIND_SILO then
                table.insert(rows, {
                    name = "   " .. U.fillTypeTitle(fillTypeIndex), nameIcon = U.fillTypeIcon(fillTypeIndex),
                    data = { kind = "output", node = node, productKey = productKey, fillTypeIndex = fillTypeIndex },
                    cols = { col(g_i18n:getText("pi_role_out"), C.GREEN), col(U.formatLiters(level)),
                             col(ruleValue, ruleColor), col(moved), col(net ~= nil and money(net) or nil, signColor(net)) },
                })
            end
        end
        table.insert(rows, {})
    end
    return rows
end

local function nextIn(list, current)
    for i, value in ipairs(list) do
        if value == current then return list[i % #list + 1] end
    end
    return list[1]
end

function ProductionInsightsView:onRuleChange(what)
    local row = self:getSelectedRow()
    local data = row ~= nil and row.data or nil
    if data == nil or data.node == nil then return end
    local node = data.node
    local productKey = data.productKey
    if what == "accept" then productKey = ProductionLogistics.BUILDING_KEY end
    if productKey == nil then return end

    local current = ProductionLogistics:getRule(node.key, productKey, node.kind)
    local rule = {}
    for k, v in pairs(current) do rule[k] = v end

    if what == "mode" then
        rule.mode = ((rule.mode or 0) + 1) % ProductionLogistics.MODE_COUNT
    elseif what == "reserve" then
        rule.reserve = nextIn(ProductionLogistics.RESERVES, rule.reserve or 0)
    elseif what == "blocked" or what == "accept" then
        rule.blocked = not rule.blocked
    elseif what == "priority" then
        rule.priority = (rule.priority or ProductionLogistics.PRIORITY_NORMAL) % 3 + 1
    elseif what == "target" then
        rule.target = nextIn(ProductionLogistics.TARGETS, rule.target or 75)
    end

    ProductionLogisticsRuleEvent.send(node.key, productKey, rule)
    self:rebuild()
end

-- ==================================================================
-- THIS MONTH
-- ==================================================================

function ProductionInsightsView:buildTaskRows()
    local rows = {}
    for _, task in ipairs(ProductionTasks:getTasks()) do
        local color = self.SEVERITY_COLORS[task.severity] or C.WHITE
        table.insert(rows, { name = ProductionTasks.categoryTitle(task.category), nameColor = color,
            wide = task.text, wideColor = color })
    end
    if #rows == 0 then
        table.insert(rows, noteRow(g_i18n:getText("pi_hud_nothing"), C.GREEN))
    end
    return rows
end

-- ==================================================================
-- Shared actions
-- ==================================================================

function ProductionInsightsView:onDetails()
    local row = self:getSelectedRow()
    if row == nil or row.data == nil then return end
    local V = self.VIEW
    local kinds = { [V.STOCK] = "product", [V.PROFIT] = "recipe", [V.ANIMALS] = "pen" }
    local kind = kinds[self.view]
    if kind == nil then return end

    local title = row.data.title or row.data.name or row.data.recipeName or row.name
    self.detail = { kind = kind, data = row.data, title = title, returnIndex = self.selectedIndex }
    self.selectedIndex = 1
    self:rebuild()
end

function ProductionInsightsView:closeDetail()
    local returnIndex = self.detail ~= nil and self.detail.returnIndex or 1
    self.detail = nil
    self.allRecipes = nil
    self.selectedIndex = returnIndex
    self:refresh()
end

-- Refreshes data but stays in the open drill-down (e.g. after setting an alert)
function ProductionInsightsView:refreshKeepingDetail()
    if self.detail ~= nil then
        self:rebuild()
    else
        self:refresh()
    end
end

function ProductionInsightsView:onFilter()
    local V = self.VIEW
    if self.view == V.STOCK then
        self.stockShowAll = not self.stockShowAll
    elseif self.view == V.PROFIT then
        self.profitFilter = self.profitFilter % #self.PROFIT_FILTERS + 1
    elseif self.view == V.NETWORK then
        self.networkFilter = self.networkFilter % #self.NETWORK_FILTERS + 1
    end
    self.selectedIndex = 1
    self:refresh()
end

function ProductionInsightsView:onSort()
    self.profitSortMonthly = not self.profitSortMonthly
    self.selectedIndex = 1
    self:rebuild()
end
