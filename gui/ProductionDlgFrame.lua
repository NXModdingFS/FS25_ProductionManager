ProductionDlgFrame = {}
local DlgFrame_mt = Class(ProductionDlgFrame, MessageDialog)

function ProductionDlgFrame.new(target, custom_mt)
	local self = MessageDialog.new(target, custom_mt or DlgFrame_mt)
	self.productions = {}
	self.displayRows = {}
	self.showInputs = true
	self.showRecipes = false
	self.showFinances = false
	self.showLogistics = false
	self.selectedLogisticsRow = nil
	self.selectedRecipeRow = nil
	self.showSchedule = false
	return self
end

function ProductionDlgFrame:onGuiSetupFinished()
	ProductionDlgFrame:superClass().onGuiSetupFinished(self)
	self.overviewTable:setDataSource(self)
	self.overviewTable:setDelegate(self)
end

function ProductionDlgFrame:onCreate()
	ProductionDlgFrame:superClass().onCreate(self)
end

function ProductionDlgFrame:onOpen()
	ProductionDlgFrame:superClass().onOpen(self)

	self:updateToggleButtonText()
	self:updateRecipeButtonText()
	self:loadProductionData()
	self:updateHeaderVisibility()

	if self.toggleButton ~= nil then
		self.toggleButton:setInputAction(InputAction.MENU_EXTRA_1)
	end
	
	if self.recipeButton ~= nil then
		self.recipeButton:setInputAction(InputAction.MENU_EXTRA_2)
	end
	
	if self.financesButton ~= nil then
		self.financesButton:setInputAction(InputAction.MENU_PAGE_PREV)
	end
	
	if self.logisticsButton ~= nil then
		self.logisticsButton:setInputAction(InputAction.MENU_PAGE_NEXT)
	end
	
	if self.changeOutputButton ~= nil then
		self.changeOutputButton:setInputAction(InputAction.MENU_ACCEPT)
		self.changeOutputButton:setVisible(false)
	end
	
	if self.toggleRecipeButton ~= nil then
		self.toggleRecipeButton:setInputAction(InputAction.MENU_CANCEL)
		self.toggleRecipeButton:setVisible(false)
	end
	
	-- Schedule button: shown on logistics page when a recipe row is selected
	if self.scheduleButton ~= nil then
		self.scheduleButton:setInputAction(InputAction.MENU_EXTRA_1)
		self.scheduleButton:setVisible(false)
	end
	
	if self.exportButton ~= nil then
		self.exportButton:setInputAction(InputAction.MENU_ACTIVATE)
	end

	-- Schedule page buttons (hidden until schedule view is active)
	if self.allMonthsButton ~= nil then
		self.allMonthsButton:setVisible(false)
	end
	if self.schedEnableButton ~= nil then
		self.schedEnableButton:setVisible(false)
	end
	if self.commitScheduleButton ~= nil then
		self.commitScheduleButton:setVisible(false)
	end
	if self.cancelScheduleButton ~= nil then
		self.cancelScheduleButton:setVisible(false)
	end
	if self.scheduleHeaderBox ~= nil then
		self.scheduleHeaderBox:setVisible(false)
	end
	if self.recipeHeaderBox ~= nil then
		self.recipeHeaderBox:setVisible(false)
	end

	self:refreshButtonLayout()

	self:setSoundSuppressed(true)
	FocusManager:setFocus(self.overviewTable)
	self:setSoundSuppressed(false)
end

function ProductionDlgFrame:onClickOk()
	return false
end

function ProductionDlgFrame:inputEvent(action, value, eventUsed)
	if eventUsed then
		return eventUsed
	end
	
	if value == 0 then
		return eventUsed
	end
	
	if action == InputAction.MENU_EXTRA_1 then
		-- Schedule page: All-months toggle.  Other pages: Inputs/Outputs toggle or Schedule open
		if self.showSchedule then
			self:onClickAllMonths()
		elseif self.showLogistics then
			self:onClickSchedule()
		else
			self:onClickToggle()
		end
		return true
	elseif action == InputAction.MENU_EXTRA_2 then
		if self.showSchedule then
			self:onClickSchedEnable()
		else
			self:onClickRecipes()
		end
		return true
	elseif action == InputAction.MENU_PAGE_PREV then
		if not self.showSchedule then
			self:onClickFinances()
		end
		return true
	elseif action == InputAction.MENU_PAGE_NEXT then
		if not self.showSchedule then
			self:onClickLogistics()
		end
		return true
	elseif action == InputAction.MENU_ACCEPT then
		if self.showSchedule then
			-- Toggle currently focused month
			local idx = self.overviewTable:getSelectedIndexInSection()
			if idx ~= nil then
				local row = self.displayRows[idx]
				if row and row.rowType == "schedule" then
					self:toggleScheduleMonth(row.monthIdx)
				end
			end
			return true
		elseif self.showLogistics then
			self:onClickChangeOutput()
			return true
		end
	elseif action == InputAction.MENU_CANCEL then
		if self.showSchedule then
			self:onClickCancelSchedule()
			return true
		elseif self.showRecipes then
			self:onClickToggleRecipe()
			return true
		end
	elseif action == InputAction.MENU_ACTIVATE then
		if self.showSchedule then
			self:onClickCommitSchedule()
		else
			self:onClickExportCSV()
		end
		return true
	end

	return ProductionDlgFrame:superClass().inputEvent(self, action, value, eventUsed)
end

-- ============================================================
-- Schedule Button
-- ============================================================

-- Returns (production, productionPoint) for the currently selected logistics row.
-- Used by the Schedule button to know which production to open the dialog for.
function ProductionDlgFrame:getSelectedProduction()
	if self.selectedLogisticsRow == nil then return nil, nil end
	local row            = self.selectedLogisticsRow
	local productionPoint = row.production.productionPoint
	local recipeName     = row.logistic.recipe
	if productionPoint == nil or productionPoint.productions == nil then
		return nil, productionPoint
	end
	for _, prod in pairs(productionPoint.productions) do
		if prod.name == recipeName then
			return prod, productionPoint
		end
	end
	return nil, productionPoint
end

function ProductionDlgFrame:onClickSchedule()
	if ProductionScheduleManager == nil then return end
	local production, productionPoint = self:getSelectedProduction()
	if production == nil or productionPoint == nil then return end

	local pointKey = ProductionScheduleManager:getPointKey(productionPoint)
	if pointKey == nil then return end

	local prodId   = tostring(production.id)
	local prodName = production.name or prodId

	local entry = ProductionScheduleManager:getEntry(pointKey, prodId)
	if entry == nil then entry = {months = {}, scheduleEnabled = false} end

	-- Copy months table so edits don't touch live data until commit
	local months = {}
	for k, v in pairs(entry.months) do months[k] = v end

	-- Write context fields that commitFromUI() will read
	ProductionScheduleManager.ctxPointKey        = pointKey
	ProductionScheduleManager.ctxProdId          = prodId
	ProductionScheduleManager.ctxProdName        = prodName
	ProductionScheduleManager.ctxMonths          = months
	ProductionScheduleManager.ctxScheduleEnabled = (entry.scheduleEnabled == true)

	-- Seasonal price peak for the primary output, so the schedule can highlight
	-- the best months to sell. Display-only, so it lives on the frame (not the
	-- persisted schedule context). nil if the market helper or price data is absent.
	self.schedulePeak = nil
	if ProductionMarketData ~= nil and production.outputs ~= nil and #production.outputs > 0 then
		local outputType = production.outputs[1].type
		local peak = ProductionMarketData:getSeasonalPeak(outputType)
		if peak ~= nil then
			self.schedulePeak = peak
		end
	end

	self.showSchedule = true
	self:enterScheduleView()
end

function ProductionDlgFrame:enterScheduleView()
	-- Hide all standard-page and logistics-page buttons
	if self.toggleButton       ~= nil then self.toggleButton:setVisible(false) end
	if self.recipeButton       ~= nil then self.recipeButton:setVisible(false) end
	if self.financesButton     ~= nil then self.financesButton:setVisible(false) end
	if self.logisticsButton    ~= nil then self.logisticsButton:setVisible(false) end
	if self.changeOutputButton ~= nil then self.changeOutputButton:setVisible(false) end
	if self.toggleRecipeButton ~= nil then self.toggleRecipeButton:setVisible(false) end
	if self.scheduleButton     ~= nil then self.scheduleButton:setVisible(false) end
	if self.exportButton       ~= nil then self.exportButton:setVisible(false) end

	-- Show schedule-page buttons
	if self.allMonthsButton       ~= nil then self.allMonthsButton:setVisible(true) end
	if self.schedEnableButton     ~= nil then self.schedEnableButton:setVisible(true) end
	if self.commitScheduleButton  ~= nil then self.commitScheduleButton:setVisible(true) end
	if self.cancelScheduleButton  ~= nil then self.cancelScheduleButton:setVisible(true) end

	-- Swap header boxes
	if self.tableHeaderBox     ~= nil then self.tableHeaderBox:setVisible(false) end
	if self.financeHeaderBox   ~= nil then self.financeHeaderBox:setVisible(false) end
	if self.logisticsHeaderBox ~= nil then self.logisticsHeaderBox:setVisible(false) end
	if self.recipeHeaderBox    ~= nil then self.recipeHeaderBox:setVisible(false) end
	if self.scheduleHeaderBox  ~= nil then self.scheduleHeaderBox:setVisible(true) end

	-- Update dialog title to show the production name
	if self.dialogTitleElement ~= nil and ProductionScheduleManager ~= nil then
		local name = ProductionScheduleManager.ctxProdName
		             or ProductionScheduleManager.ctxProdId
		             or "?"
		self.dialogTitleElement:setText(g_i18n:getText("PS_DIALOG_TITLE"):format(tostring(name)))
	end

	self:refreshButtonLayout()

	self:updateAllMonthsButtonText()
	self:updateSchedEnableButtonText()
	self:buildDisplayRows()
	self.overviewTable:reloadData()
	if self.overviewTable.setSelectedIndex ~= nil then
		self.overviewTable:setSelectedIndex(1, true)
	end
end

function ProductionDlgFrame:exitScheduleView()
	self.showSchedule = false
	self.schedulePeak = nil

	-- Restore export button
	if self.exportButton ~= nil then self.exportButton:setVisible(true) end

	-- Hide schedule-page buttons
	if self.allMonthsButton      ~= nil then self.allMonthsButton:setVisible(false) end
	if self.schedEnableButton    ~= nil then self.schedEnableButton:setVisible(false) end
	if self.commitScheduleButton ~= nil then self.commitScheduleButton:setVisible(false) end
	if self.cancelScheduleButton ~= nil then self.cancelScheduleButton:setVisible(false) end
	if self.scheduleHeaderBox    ~= nil then self.scheduleHeaderBox:setVisible(false) end

	-- Restore dialog title
	if self.dialogTitleElement ~= nil then
		self.dialogTitleElement:setText(g_i18n:getText("ui_productionDlg_title"))
	end

	-- Re-enter logistics page (that's where the user came from)
	self.showLogistics = true
	if self.logisticsButton ~= nil then
		self.logisticsButton:setText(g_i18n:getText("ui_productionDlg_btnHideLogistics"))
		self.logisticsButton:setVisible(true)
	end
	self:updateHeaderVisibility()
	self:refreshButtonLayout()

	self:loadProductionData()
	self:buildDisplayRows()
	self.overviewTable:reloadData()
end

-- ============================================================
-- Schedule View – Month Toggle Helpers
-- ============================================================

function ProductionDlgFrame:buildScheduleRows()
	self.displayRows = {}
	local months = (ProductionScheduleManager ~= nil and ProductionScheduleManager.ctxMonths) or {}
	local peak = self.schedulePeak
	for i = 1, 12 do
		table.insert(self.displayRows, {
			rowType   = "schedule",
			monthIdx  = i,
			monthName = g_i18n:getText("PS_MONTH_" .. i),
			enabled   = (months[i] == true),
			isPeak    = (peak ~= nil and peak.periods[i] == true),
			peakPrice = (peak ~= nil and peak.price) or nil
		})
	end
end

function ProductionDlgFrame:toggleScheduleMonth(idx)
	if ProductionScheduleManager == nil or idx == nil then return end
	local months = ProductionScheduleManager.ctxMonths or {}
	months[idx] = not (months[idx] == true)
	ProductionScheduleManager.ctxMonths = months
	self:buildDisplayRows()
	self.overviewTable:reloadData()
	if self.overviewTable.setSelectedIndex ~= nil then
		self.overviewTable:setSelectedIndex(idx, true)
	end
	self:updateAllMonthsButtonText()
end

function ProductionDlgFrame:onClickTableRow(element)
	if not self.showSchedule then return end
	if element == nil then return end
	local idx = element.psMonthIdx
	if idx == nil then return end
	self:toggleScheduleMonth(idx)
end

function ProductionDlgFrame:onClickAllMonths()
	if ProductionScheduleManager == nil then return end
	local months = ProductionScheduleManager.ctxMonths or {}
	local allOn  = true
	for i = 1, 12 do
		if months[i] ~= true then allOn = false; break end
	end
	local newValue = not allOn
	for i = 1, 12 do months[i] = newValue end
	ProductionScheduleManager.ctxMonths = months
	self:buildDisplayRows()
	self.overviewTable:reloadData()
	self:updateAllMonthsButtonText()
end

function ProductionDlgFrame:onClickSchedEnable()
	if ProductionScheduleManager == nil then return end
	ProductionScheduleManager.ctxScheduleEnabled = not (ProductionScheduleManager.ctxScheduleEnabled == true)
	self:updateSchedEnableButtonText()
end

function ProductionDlgFrame:onClickCommitSchedule()
	if ProductionScheduleManager ~= nil then
		ProductionScheduleManager:commitFromUI()
	end
	self:exitScheduleView()
end

function ProductionDlgFrame:onClickCancelSchedule()
	-- Discard in-progress changes; context is abandoned on exit
	self:exitScheduleView()
end

function ProductionDlgFrame:updateAllMonthsButtonText()
	if self.allMonthsButton == nil or ProductionScheduleManager == nil then return end
	local months = ProductionScheduleManager.ctxMonths or {}
	local allOn  = true
	for i = 1, 12 do
		if months[i] ~= true then allOn = false; break end
	end
	self.allMonthsButton:setText(
		allOn and g_i18n:getText("PS_BTN_ALL_TOGGLE_OFF")
		       or g_i18n:getText("PS_BTN_ALL_TOGGLE_ON")
	)
end

function ProductionDlgFrame:updateSchedEnableButtonText()
	if self.schedEnableButton == nil or ProductionScheduleManager == nil then return end
	local enabled = (ProductionScheduleManager.ctxScheduleEnabled == true)
	local stateKey = enabled and "PS_STATE_ACTIVE" or "PS_STATE_INACTIVE"
	self.schedEnableButton:setText(
		g_i18n:getText("PS_BTN_SCHED_TOGGLE") .. ": " .. g_i18n:getText(stateKey)
	)
end

-- ============================================================
-- Distribution / Output helpers
-- ============================================================

function ProductionDlgFrame:getDistributionDestination(sourceProduction, fillType)
	if sourceProduction == nil or fillType == nil then
		return nil
	end

	if sourceProduction.outputFillTypeIdsAutoDeliver == nil or 
	   sourceProduction.outputFillTypeIdsAutoDeliver[fillType] == nil then
		return nil
	end

	local farmId = sourceProduction.ownerFarmId
	if g_currentMission == nil or g_currentMission.productionChainManager == nil then
		return nil
	end

	local farmTable = g_currentMission.productionChainManager.farmIds[farmId]
	if farmTable == nil or farmTable.inputTypeToProductionPoints == nil then
		return nil
	end

	local prodPointsInDemand = farmTable.inputTypeToProductionPoints[fillType] or {}
	
	for i = 1, #prodPointsInDemand do
		local prodPointInDemand = prodPointsInDemand[i]
		
		if prodPointInDemand ~= sourceProduction then
			local filltypeRequired = false
			if prodPointInDemand.activeProductions ~= nil then
				for j = 1, #prodPointInDemand.activeProductions do
					local activeProduction = prodPointInDemand.activeProductions[j]
					if activeProduction.inputs ~= nil then
						for k = 1, #activeProduction.inputs do
							if activeProduction.inputs[k].type == fillType then
								filltypeRequired = true
								break
							end
						end
					end
					if filltypeRequired then break end
				end
			end
			
			if filltypeRequired and prodPointInDemand.getName ~= nil then
				return prodPointInDemand:getName()
			end
		end
	end

	return nil
end

-- ============================================================
-- Data Loading
-- ============================================================

function ProductionDlgFrame:loadProductionData()
	self.productions = {}

	if g_currentMission ~= nil and g_currentMission.productionChainManager ~= nil then
		-- Best current sell price per fill type, scanned once for the whole refresh
		-- rather than per production. Empty table if the market helper is absent.
		local farmId = g_currentMission:getFarmId()
		local sellPrices = {}
		if ProductionMarketData ~= nil then
			-- Never let a market-scan problem abort the whole data load
			local ok, result = pcall(function() return ProductionMarketData:getSellPriceMap(farmId) end)
			if ok and type(result) == "table" then
				sellPrices = result
			else
				Logging.warning("ProductionDlgFrame: sell-price scan failed, continuing without it (%s)", tostring(result))
			end
		end

		-- Farm-wide pallet contents per fill type (output already spawned as pallets
		-- no longer shows in a production's internal storage). Scanned once, guarded.
		local palletTotals = {}
		if ProductionPalletData ~= nil then
			local ok, result = pcall(function() return ProductionPalletData:getPalletTotals(farmId) end)
			if ok and type(result) == "table" then
				palletTotals = result
			else
				Logging.warning("ProductionDlgFrame: pallet scan failed, continuing without it (%s)", tostring(result))
			end
		end

		for _, productionPoint in pairs(g_currentMission.productionChainManager.productionPoints) do
			if productionPoint.ownerFarmId == farmId then

				local hasActiveProduction = true
				if ProductionSettings and ProductionSettings.hideInactiveProductions then
					hasActiveProduction = false
					if productionPoint.productions ~= nil then
						for _, production in pairs(productionPoint.productions) do
							if production.status ~= ProductionPoint.PROD_STATUS.INACTIVE then
								hasActiveProduction = true
								break
							end
						end
					end
				end

				if hasActiveProduction then
			
					local modeIndicator = ""
					if productionPoint.sharedThroughputCapacity ~= nil then
						modeIndicator = productionPoint.sharedThroughputCapacity and " (S)" or " (P)"
					end
					
					local prodData = {
						name = productionPoint:getName() .. modeIndicator,
						inputFillTypes = {},
						outputFillTypes = {},
						recipes = {},
						logistics = {},
						monthlyIncome = 0,
						monthlyCosts = 0,
						monthlyRevenue = 0,
						monthlyDistributedValue = 0,
						bestSale = nil,
						monthlyOutputLiters = {},   -- [fillTypeIndex] = litres produced per month
						dailyUpkeep = 0,
						productionPoint = productionPoint
					}

					if productionPoint.storage ~= nil and productionPoint.storage.fillTypes ~= nil then
						local inputFillTypeIndices = {}
						local outputFillTypeIndices = {}

						if productionPoint.productions ~= nil then
							for _, production in pairs(productionPoint.productions) do
								if production.inputs ~= nil then
									for _, input in pairs(production.inputs) do
										inputFillTypeIndices[input.type] = true
									end
								end
								if production.outputs ~= nil then
									for _, output in pairs(production.outputs) do
										outputFillTypeIndices[output.type] = true
									end
								end
							end
						end

						for fillTypeIndex, _ in pairs(productionPoint.storage.fillTypes) do
							local fillLevel = productionPoint.storage:getFillLevel(fillTypeIndex)
							local capacity = productionPoint.storage:getCapacity(fillTypeIndex)

							if capacity > 0 then
								local fillType = g_fillTypeManager:getFillTypeByIndex(fillTypeIndex)
								if fillType ~= nil then
									local data = {
										fillTypeIndex = fillTypeIndex,
										name = fillType.name,
										title = fillType.title,
										liters = fillLevel,
										capacity = capacity,
										fillPercent = (fillLevel / capacity) * 100,
										hudOverlayFilename = fillType.hudOverlayFilename
									}

									local isInput = inputFillTypeIndices[fillTypeIndex]
									local isOutput = outputFillTypeIndices[fillTypeIndex]
									
								
									if isOutput then
										table.insert(prodData.outputFillTypes, data)
									end
									
									
									if isInput and not isOutput then
										table.insert(prodData.inputFillTypes, data)
									end
									
								
									if isInput and isOutput then
										table.insert(prodData.inputFillTypes, data)
									end
									
								
									if not isInput and not isOutput then
										table.insert(prodData.outputFillTypes, data)
									end
								end
							end
						end
					end

					table.sort(prodData.inputFillTypes, function(a, b) return a.title < b.title end)
					table.sort(prodData.outputFillTypes, function(a, b) return a.title < b.title end)

					if productionPoint.productions ~= nil then
						local daysPerMonth = g_currentMission.missionInfo.plannedDaysPerPeriod or 1
						local hoursPerDay = 24
						
						local totalConsumptionRates = {}
						
						for _, production in pairs(productionPoint.productions) do
							if production.status == ProductionPoint.PROD_STATUS.RUNNING then
								local cyclesPerHour = production.cyclesPerHour or 0
								
								if production.inputs ~= nil then
									for _, input in pairs(production.inputs) do
										local fillTypeIndex = input.type
										local consumptionPerCycle = input.amount or 0
										local consumptionPerHour = consumptionPerCycle * cyclesPerHour
										
										if totalConsumptionRates[fillTypeIndex] == nil then
											totalConsumptionRates[fillTypeIndex] = 0
										end
										totalConsumptionRates[fillTypeIndex] = totalConsumptionRates[fillTypeIndex] + consumptionPerHour
									end
								end
							end
						end
						
						for _, production in pairs(productionPoint.productions) do
							
							local fullName = production.name or "Unknown Recipe"
							
							local outputFillTypeInfo = nil
							if production.outputs and #production.outputs > 0 then
								local outputType = production.outputs[1].type
								if outputType then
									local outputFillType = g_fillTypeManager:getFillTypeByIndex(outputType)
									if outputFillType then
										outputFillTypeInfo = {
											type = outputType,
											title = outputFillType.title,
											hudOverlayFilename = outputFillType.hudOverlayFilename
										}
									end
								end
							end
							
							table.insert(prodData.recipes, {
								name = fullName,
								isActive = production.status == ProductionPoint.PROD_STATUS.RUNNING,
								status = production.status,
								inputs = production.inputs or {},
								outputs = production.outputs or {},
								outputFillTypeInfo = outputFillTypeInfo,
								production = production
							})
							
						
							local cyclesPerMonth = production.cyclesPerMonth or 0
							
							local supplyDuration = "N/A"
							local outputMode = "Storing"
							local destination = "N/A"
							local destinationColor = {1, 0, 0, 1}
							
						
							if production.status == ProductionPoint.PROD_STATUS.RUNNING then
								if production.inputs ~= nil and #production.inputs > 0 then
									local minDuration = math.huge
									
									for _, input in pairs(production.inputs) do
										local fillTypeIndex = input.type
										local fillLevel = productionPoint.storage:getFillLevel(fillTypeIndex)
										local totalConsumptionPerHour = totalConsumptionRates[fillTypeIndex] or 0
										
										if totalConsumptionPerHour > 0 then
											local hoursUntilEmpty = fillLevel / totalConsumptionPerHour
											if hoursUntilEmpty < minDuration then
												minDuration = hoursUntilEmpty
											end
										end
									end
									
									if minDuration ~= math.huge then
										local gameDaysUntilEmpty = minDuration / hoursPerDay
										
										if gameDaysUntilEmpty < 1 then
											supplyDuration = string.format("%.1fh", minDuration)
										elseif gameDaysUntilEmpty < 30 then
											supplyDuration = string.format("%.1fd", gameDaysUntilEmpty)
										else
											local monthsUntilEmpty = gameDaysUntilEmpty / daysPerMonth
											supplyDuration = string.format("%.1fm", monthsUntilEmpty)
										end
									end
								end
								
							
								if production.outputs ~= nil and #production.outputs > 0 then
									local output = production.outputs[1]
									local fillType = output.type
									
									if productionPoint.getOutputDistributionMode then
										local mode = productionPoint:getOutputDistributionMode(fillType)
										if mode == ProductionPoint.OUTPUT_MODE.DIRECT_SELL then
											outputMode = "Selling"
										elseif mode == ProductionPoint.OUTPUT_MODE.AUTO_DELIVER then
											outputMode = "Distributing"
											
											local destName = self:getDistributionDestination(productionPoint, fillType)
											if destName then
												destination = destName
												destinationColor = {1, 1, 1, 1}
											else
												destination = "Not Set"
												destinationColor = {1, 0.5, 0, 1}
											end
										end
									end
									
									if outputMode ~= "Distributing" then
										local fillLevel = productionPoint.storage:getFillLevel(fillType)
										local capacity = productionPoint.storage:getCapacity(fillType)
										if fillLevel > capacity * 0.9 then
											destination = "Full"
											destinationColor = {1, 0, 0, 1}
										end
									end
								end
							else
								
								supplyDuration = "-"
								outputMode = "-"
								destination = "-"
								destinationColor = {0.5, 0.5, 0.5, 1}
							end

							-- Build schedule indicator for the logistics row
							local scheduleIndicator = ""
							if ProductionScheduleManager ~= nil then
								local pointKey = ProductionScheduleManager:getPointKey(productionPoint)
								local entry    = ProductionScheduleManager:getEntry(pointKey, production.id)
								if entry ~= nil and entry.scheduleEnabled then
									scheduleIndicator = " [S]"
								end
							end
							
							table.insert(prodData.logistics, {
								recipe = fullName,
								cyclesPerMonth = cyclesPerMonth,
								supplyDuration = supplyDuration,
								outputMode = outputMode,
								destination = destination,
								destinationColor = destinationColor,
								outputFillTypeInfo = outputFillTypeInfo,
								isActive = production.status == ProductionPoint.PROD_STATUS.RUNNING,
								scheduleIndicator = scheduleIndicator,
								production = production
							})
						end
					end

					-- Days in an in-game month. NOTE: missionInfo.timeScale is the game-speed
					-- multiplier, NOT a day count - using it here scaled every cost by the
					-- player's speed setting.
					local daysPerMonth = g_currentMission.missionInfo.plannedDaysPerPeriod or 1

					-- Revenue is the value of output PRODUCED per month by running recipes,
					-- not the value of whatever happens to be sitting in storage. Outputs set
					-- to auto-deliver feed another facility, so they are intermediate goods
					-- rather than income and are tracked separately.
					local hasRunningProduction = false

					if productionPoint.productions ~= nil then
						for _, production in pairs(productionPoint.productions) do
							if production.status == ProductionPoint.PROD_STATUS.RUNNING then
								hasRunningProduction = true

								local cyclesPerMonth = ProductionUtil.monthlyRate(production.cyclesPerMonth,
									production.cyclesPerHour, production.cyclesPerMinute) or 0

								if production.outputs ~= nil then
									for _, output in pairs(production.outputs) do
										-- Litres of this output produced per month (running recipes only),
										-- used for the estimated pallets/month figure on the output page.
										local producedPerMonth = (output.amount or 0) * cyclesPerMonth
										prodData.monthlyOutputLiters[output.type] =
											(prodData.monthlyOutputLiters[output.type] or 0) + producedPerMonth

										-- Prefer the best real sell price from a station; fall back to
										-- the economy manager's reference price if no station buys it.
										local saleInfo = sellPrices[output.type]
										local price = saleInfo ~= nil and saleInfo.price or nil
										if price == nil then
											price = g_currentMission.economyManager:getPricePerLiter(output.type)
										end

										if price ~= nil then
											local value = (output.amount or 0) * cyclesPerMonth * price

											local mode = nil
											if productionPoint.getOutputDistributionMode ~= nil then
												mode = productionPoint:getOutputDistributionMode(output.type)
											end

											if mode == ProductionPoint.OUTPUT_MODE.AUTO_DELIVER then
												prodData.monthlyDistributedValue = prodData.monthlyDistributedValue + value
											else
												prodData.monthlyRevenue = prodData.monthlyRevenue + value

												-- Remember the highest-value sold output so the finance page
												-- can show where it sells best.
												if saleInfo ~= nil and (prodData.bestSale == nil or value > prodData.bestSale.value) then
													local ft = g_fillTypeManager:getFillTypeByIndex(output.type)
													prodData.bestSale = {
														value        = value,
														pricePerLiter = saleInfo.price,
														stationName  = saleInfo.stationName,
														fillTypeTitle = ft ~= nil and ft.title or "?"
													}
												end
											end
										end
									end
								end

								-- Running costs are a per-production-month figure (24 production
								-- hours); they are not scaled by the save's days per month.
								local runningPerMonth = ProductionUtil.monthlyRate(production.costsPerActiveMonth,
									production.costsPerActiveHour)
								if runningPerMonth ~= nil then
									prodData.monthlyCosts = prodData.monthlyCosts + runningPerMonth
								end
							end
						end
					end

					if productionPoint.owningPlaceable then
						local upkeep = productionPoint.owningPlaceable:getDailyUpkeep()
						if upkeep and upkeep > 0 then
							prodData.dailyUpkeep = upkeep
							prodData.monthlyCosts = prodData.monthlyCosts + (upkeep * daysPerMonth)
						end
					end

					-- Building-level running costs only accrue while something is running
					local pointRunningPerMonth = ProductionUtil.monthlyRate(productionPoint.costsPerActiveMonth,
						productionPoint.costsPerActiveHour)
					if hasRunningProduction and pointRunningPerMonth ~= nil then
						prodData.monthlyCosts = prodData.monthlyCosts + pointRunningPerMonth
					end

					prodData.monthlyIncome = prodData.monthlyRevenue - prodData.monthlyCosts

					-- Enrich each output with farm pallet inventory and a monthly estimate.
					-- monthlyPallets is only set when a pallet capacity is known (a pallet of
					-- that type exists on the map); otherwise the view falls back to litres.
					for _, ft in ipairs(prodData.outputFillTypes) do
						local idx = ft.fillTypeIndex
						local pal = idx ~= nil and palletTotals[idx] or nil
						if pal ~= nil then
							ft.palletLiters   = pal.liters
							ft.palletCount    = pal.count
							ft.palletCapacity = pal.palletCapacity
						end
						local monthly = (idx ~= nil and prodData.monthlyOutputLiters[idx]) or 0
						ft.monthlyLiters = monthly
						if monthly > 0 and ft.palletCapacity ~= nil and ft.palletCapacity > 0 then
							ft.monthlyPallets = monthly / ft.palletCapacity
						end
					end

					table.insert(self.productions, prodData)
				end
			end
		end
	end

	table.sort(self.productions, function(a, b) return a.name < b.name end)
	self:buildDisplayRows()
	self.overviewTable:reloadData()
end

function ProductionDlgFrame:buildDisplayRows()
	self.displayRows = {}

	-- Schedule view: show 12 month rows instead of production data
	if self.showSchedule then
		self:buildScheduleRows()
		return
	end

	for _, prod in ipairs(self.productions) do
		if self.showLogistics then
			if #prod.logistics > 0 then
				for i, logistic in ipairs(prod.logistics) do
					table.insert(self.displayRows, {
						production = prod,
						rowType = "logistics",
						logistic = logistic,
						isFirst = (i == 1)
					})
				end
			else
				table.insert(self.displayRows, {
					production = prod,
					rowType = "logistics_empty",
					isFirst = true
				})
			end
			
			table.insert(self.displayRows, {
				production = prod,
				rowType = "logistics_gap"
			})
		elseif self.showFinances then
			table.insert(self.displayRows, {
				production = prod,
				rowType = "finance",
				fillTypes = {},
				startIndex = 1,
				endIndex = 0
			})
		else
			local fillTypes = self.showInputs and prod.inputFillTypes or prod.outputFillTypes

			if self.showRecipes then
				-- One row per recipe; ingredients display across columns
				if #prod.recipes > 0 then
					for i, recipe in ipairs(prod.recipes) do
						table.insert(self.displayRows, {
							production = prod,
							rowType    = "recipe_row",
							recipe     = recipe,
							isFirst    = (i == 1)
						})
					end
				else
					table.insert(self.displayRows, {
						production = prod,
						rowType    = "recipe_empty",
						isFirst    = true
					})
				end
				table.insert(self.displayRows, {
					production = prod,
					rowType    = "recipe_gap"
				})
			elseif not self.showInputs then
				-- Output page: one row per output product, with room for current
				-- pallet contents and an estimated pallets/month figure.
				if #prod.outputFillTypes > 0 then
					for i, ft in ipairs(prod.outputFillTypes) do
						table.insert(self.displayRows, {
							production = prod,
							rowType    = "output_row",
							fillType   = ft,
							isFirst    = (i == 1)
						})
					end
				else
					table.insert(self.displayRows, {
						production = prod,
						rowType    = "output_empty",
						isFirst    = true
					})
				end
				table.insert(self.displayRows, {
					production = prod,
					rowType    = "output_gap"
				})
			else
				-- Input page: one row per input product (single line, centred),
				-- matching the Outputs page instead of the old 2-row grid.
				if #prod.inputFillTypes > 0 then
					for i, ft in ipairs(prod.inputFillTypes) do
						table.insert(self.displayRows, {
							production = prod,
							rowType    = "input_row",
							fillType   = ft,
							isFirst    = (i == 1)
						})
					end
				else
					table.insert(self.displayRows, {
						production = prod,
						rowType    = "input_empty",
						isFirst    = true
					})
				end
				table.insert(self.displayRows, {
					production = prod,
					rowType    = "input_gap"
				})
			end
		end
	end
end

-- ============================================================
-- Button Text Helpers
-- ============================================================

function ProductionDlgFrame:updateToggleButtonText()
	if self.toggleButton ~= nil then
		if self.showInputs then
			self.toggleButton:setText(g_i18n:getText("ui_productionDlg_btnShowOutputs"))
		else
			self.toggleButton:setText(g_i18n:getText("ui_productionDlg_btnShowInputs"))
		end
	end
	
	if self.fillTypeHeader ~= nil then
		if self.showInputs then
			self.fillTypeHeader:setText(g_i18n:getText("ui_productionDlg_hbInputs"))
		else
			self.fillTypeHeader:setText(g_i18n:getText("ui_productionDlg_hbOutputs"))
		end
	end
end

function ProductionDlgFrame:updateRecipeButtonText()
	if self.recipeButton ~= nil then
		if self.showRecipes then
			self.recipeButton:setText(g_i18n:getText("ui_productionDlg_btnShowFillTypes"))
		else
			self.recipeButton:setText(g_i18n:getText("ui_productionDlg_btnShowRecipes"))
		end
	end
end

-- Centralized header reconciliation. Exactly one header box is shown, chosen by
-- the SAME priority buildDisplayRows() uses to pick the body. Handlers used to
-- toggle header boxes piecemeal, so a quick sequence of page switches could leave
-- the wrong combination visible (header not matching the body). Deriving both from
-- one priority order guarantees they always agree.
function ProductionDlgFrame:updateHeaderVisibility()
	local schedule  = self.showSchedule == true
	local logistics = (not schedule) and (self.showLogistics == true)
	local finances  = (not schedule) and (not logistics) and (self.showFinances == true)
	local recipes   = (not schedule) and (not logistics) and (not finances) and (self.showRecipes == true)
	local standard  = (not schedule) and (not logistics) and (not finances) and (not recipes)
	-- The standard view splits into the input grid vs the per-product output rows
	local stdInputs  = standard and (self.showInputs == true)
	local stdOutputs = standard and (self.showInputs ~= true)

	if self.scheduleHeaderBox  ~= nil then self.scheduleHeaderBox:setVisible(schedule)   end
	if self.logisticsHeaderBox ~= nil then self.logisticsHeaderBox:setVisible(logistics) end
	if self.financeHeaderBox   ~= nil then self.financeHeaderBox:setVisible(finances)    end
	if self.recipeHeaderBox    ~= nil then self.recipeHeaderBox:setVisible(recipes)      end
	if self.tableHeaderBox     ~= nil then self.tableHeaderBox:setVisible(stdInputs)     end
	if self.outputHeaderBox    ~= nil then self.outputHeaderBox:setVisible(stdOutputs)   end
end

-- Force the footer button bar to re-flow after any button is shown/hidden.
-- BoxLayout only lays out visible children, and without an explicit invalidate
-- it can leave stale positions (buttons overlapping) after a quick page switch.
function ProductionDlgFrame:refreshButtonLayout()
	if self.buttonLayout ~= nil and self.buttonLayout.invalidateLayout ~= nil then
		self.buttonLayout:invalidateLayout()
	end
end

-- ============================================================
-- Button Click Handlers
-- ============================================================

function ProductionDlgFrame:onClickToggleRecipe()
    if self.selectedRecipeRow == nil then
        return
    end

    local recipeInfo = self.selectedRecipeRow.recipe
    if recipeInfo == nil or recipeInfo.production == nil then
        return
    end

    local production = recipeInfo.production
    local prodPoint = self.selectedRecipeRow.production.productionPoint
    
    if prodPoint == nil then
        return
    end

    -- productionsIdToObj is keyed by the production's XML string id, NOT by its
    -- index in prodPoint.productions. Passing the array index makes the base
    -- game reject the call with "unknown productionId".
    local productionId = production.id

    if productionId == nil or prodPoint.productionsIdToObj == nil
       or prodPoint.productionsIdToObj[productionId] == nil then
        Logging.warning("ProductionDlgFrame: cannot resolve production id for '%s'", tostring(production.name))
        return
    end

    local isActive = production.status == ProductionPoint.PROD_STATUS.RUNNING or production.status == ProductionPoint.PROD_STATUS.MISSING_INPUTS

    -- setProductionState updates isEnabled, rebuilds activeProductions and
    -- broadcasts the status event itself - don't duplicate any of that here.
    prodPoint:setProductionState(productionId, not isActive)

    local idx = self.overviewTable:getSelectedIndexInSection()
    
    self:setSoundSuppressed(true)
    self:loadProductionData()
    self:buildDisplayRows()
    self.overviewTable:reloadData()
    
    if idx then
        self.overviewTable:setSelectedIndex(idx)
        self.selectedRecipeRow = nil
        self:onListSelectionChanged(self.overviewTable, 1, idx)
    end
    
    self:setSoundSuppressed(false)
end

function ProductionDlgFrame:onClickChangeOutput()
	if not self.selectedLogisticsRow then
		return
	end
	
	local row = self.selectedLogisticsRow
	local productionPoint = row.production.productionPoint
	local logistic = row.logistic
	
	local fillType = nil
	local production = nil
	
	for _, prod in pairs(productionPoint.productions) do
		if prod.name == logistic.recipe then
			if prod.outputs and #prod.outputs > 0 then
				fillType = prod.outputs[1].type
				production = prod
				break
			end
		end
	end
	
	if fillType == nil or production == nil then
		InfoDialog.show("Cannot find output fill type for this recipe")
		return
	end
	
	local currentMode = productionPoint:getOutputDistributionMode(fillType)
	
	local newMode
	if currentMode == 0 then
		newMode = ProductionPoint.OUTPUT_MODE.AUTO_DELIVER
	elseif currentMode == ProductionPoint.OUTPUT_MODE.AUTO_DELIVER then
		newMode = ProductionPoint.OUTPUT_MODE.DIRECT_SELL
	else
		newMode = 0
	end
	
	productionPoint:setOutputDistributionMode(fillType, newMode, true)
	
	if g_server ~= nil then
		g_server:broadcastEvent(ProductionPointOutputModeEvent.new(productionPoint, fillType, newMode))
	else
		g_client:getServerConnection():sendEvent(ProductionPointOutputModeEvent.new(productionPoint, fillType, newMode))
	end
	
	local currentIndex = self.overviewTable:getSelectedIndexInSection()
	self:loadProductionData()
	
	if currentIndex and currentIndex > 0 and currentIndex <= #self.displayRows then
		self:setSoundSuppressed(true)
		self.overviewTable:setSelectedIndex(currentIndex)
		self:setSoundSuppressed(false)
		
		local row = self.displayRows[currentIndex]
		if row and row.rowType == "logistics" then
			self.selectedLogisticsRow = row
			if self.changeOutputButton ~= nil then
				self.changeOutputButton:setVisible(true)
			end
		end
	end
end

function ProductionDlgFrame:onClickLogistics()
	self.showLogistics = not self.showLogistics
	self.selectedLogisticsRow = nil
	self.showRecipes = false
	
	if self.logisticsButton ~= nil then
		if self.showLogistics then
			self.logisticsButton:setText(g_i18n:getText("ui_productionDlg_btnHideLogistics"))
		else
			self.logisticsButton:setText(g_i18n:getText("ui_productionDlg_btnShowLogistics"))
		end
	end
	
	-- Toggle button repurposed as Schedule button on logistics page
	if self.toggleButton ~= nil then
		self.toggleButton:setVisible(not self.showLogistics)
	end
	if self.recipeButton ~= nil then
		self.recipeButton:setVisible(not self.showLogistics)
	end
	if self.financesButton ~= nil then
		self.financesButton:setVisible(not self.showLogistics)
	end
	if self.changeOutputButton ~= nil then
		self.changeOutputButton:setVisible(false)
	end
	if self.toggleRecipeButton ~= nil then
		self.toggleRecipeButton:setVisible(false)
	end
	-- Schedule button: only visible when logistics is active AND a row is selected
	if self.scheduleButton ~= nil then
		self.scheduleButton:setVisible(false)
	end
	
	self:updateHeaderVisibility()
	self:refreshButtonLayout()

	self:loadProductionData()
	self:buildDisplayRows()
	self.overviewTable:reloadData()
end

function ProductionDlgFrame:onClickFinances()
	self.showFinances = not self.showFinances
	
	if self.financesButton ~= nil then
		if self.showFinances then
			self.financesButton:setText(g_i18n:getText("ui_productionDlg_btnHideFinances"))
		else
			self.financesButton:setText(g_i18n:getText("ui_productionDlg_btnShowFinances"))
		end
	end
	
	if self.toggleButton ~= nil then
		self.toggleButton:setVisible(not self.showFinances)
	end
	if self.recipeButton ~= nil then
		self.recipeButton:setVisible(not self.showFinances)
	end
	if self.toggleRecipeButton ~= nil then
		self.toggleRecipeButton:setVisible(false)
	end

	self:updateHeaderVisibility()
	self:refreshButtonLayout()

	self:loadProductionData()
	self:buildDisplayRows()
	self.overviewTable:reloadData()
end

function ProductionDlgFrame:onClickRecipes()
	self.showRecipes = not self.showRecipes
	self:updateRecipeButtonText()
	
	if self.toggleButton ~= nil then
		self.toggleButton:setVisible(not self.showRecipes)
	end
	
	if self.toggleRecipeButton ~= nil then
		self.toggleRecipeButton:setVisible(false)
	end

	self:updateHeaderVisibility()
	self:refreshButtonLayout()

	self:loadProductionData()
	self:buildDisplayRows()
	self.overviewTable:reloadData()
end

function ProductionDlgFrame:onClickToggle()
	self.showInputs = not self.showInputs
	self:updateToggleButtonText()
	self:updateHeaderVisibility()
	self:buildDisplayRows()
	self.overviewTable:reloadData()
end

function ProductionDlgFrame:onClickExportCSV()
	if #self.productions == 0 then
		InfoDialog.show("No production data to export")
		return
	end
	
	local env = g_currentMission.environment
	local savegameName = g_currentMission.missionInfo.savegameDirectory or "Unknown"
	savegameName = savegameName:match("([^/\\]+)$") or savegameName
	savegameName = savegameName:gsub("savegame(%d)$", "savegame0%1")
	
	local year = env.currentYear or 1
	local period = env.currentPeriod or 1
	local monthMap = {3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 1, 2}
	local monthNumber = monthMap[period] or 1
	local dayNumber = env.currentDayInPeriod or 1
	
	local filename = string.format("ProductionExport_%s_Y%02d_M%02d_D%02d.csv",
		savegameName, year, monthNumber, dayNumber)

	local modsDir = getUserProfileAppPath() .. "modSettings"
	local exportDir = modsDir .. "/ProductionManagerDump"
	createFolder(exportDir)
	
	local filepath = exportDir .. "/" .. filename
	
	local file = io.open(filepath, "w")
	if file == nil then
		InfoDialog.show("Export Failed")
		return
	end

	local currencySymbol = g_i18n:getCurrencySymbol(true)
	file:write("\239\187\191")
	file:write(string.format('"Production Name","Status","Type","Fill Type","Amount (L)","Capacity (L)","Fill %%","Daily Upkeep (%s)","Monthly Revenue (%s)","Monthly Costs (%s)","Net Profit (%s)","Monthly Distributed (%s)"\n',
		currencySymbol, currencySymbol, currencySymbol, currencySymbol, currencySymbol))

	for _, prod in ipairs(self.productions) do
		local activeCount = 0
		local totalCount = #prod.recipes
		for _, recipe in ipairs(prod.recipes) do
			if recipe.status == ProductionPoint.PROD_STATUS.RUNNING then
				activeCount = activeCount + 1
			end
		end
		local statusText = string.format("Active %d/%d", activeCount, totalCount)

		for _, fillType in ipairs(prod.inputFillTypes) do
			file:write(string.format('"%s","%s","Input","%s","%d","%d","%.2f","","","","",""\n',
				prod.name or "", statusText, fillType.title or "",
				math.floor(fillType.liters), math.floor(fillType.capacity), fillType.fillPercent))
		end

		for _, fillType in ipairs(prod.outputFillTypes) do
			file:write(string.format('"%s","%s","Output","%s","%d","%d","%.2f","","","","",""\n',
				prod.name or "", statusText, fillType.title or "",
				math.floor(fillType.liters), math.floor(fillType.capacity), fillType.fillPercent))
		end

		file:write(string.format('"%s","%s","Finance Summary","","","","","%.2f","%d","%d","%d","%d"\n',
			prod.name or "", statusText, prod.dailyUpkeep,
			math.floor(prod.monthlyRevenue), math.floor(prod.monthlyCosts), math.floor(prod.monthlyIncome),
			math.floor(prod.monthlyDistributedValue)))

		file:write("\n")
	end

	file:close()
	InfoDialog.show(string.format("Export Successful!\n\nExported to:\n%s", filename))
end

-- ============================================================
-- SmoothList Callbacks
-- ============================================================

function ProductionDlgFrame:getNumberOfItemsInSection(list, section)
	if list == self.overviewTable then
		return #self.displayRows
	else
		return 0
	end
end

function ProductionDlgFrame:onListSelectionChanged(list, section, index)
	if list == self.overviewTable then
		if self.showLogistics then
			local row = self.displayRows[index]
			if row and row.rowType == "logistics" then
				self.selectedLogisticsRow = row
				
				if self.changeOutputButton ~= nil then
					self.changeOutputButton:setVisible(true)
				end
				
				-- Show schedule button when a recipe row is selected on the logistics page
				if self.scheduleButton ~= nil then
					self.scheduleButton:setVisible(true)
				end
				
				if self.toggleRecipeButton ~= nil then
					local productionPoint = row.production.productionPoint
					local recipeName = row.logistic.recipe
					local recipeProduction = nil
					
					
					for _, prod in pairs(productionPoint.productions) do
						if prod.name == recipeName then
							recipeProduction = prod
							Logging.info("ProductionDlgFrame: Selection changed - Recipe '%s' has status: %s", recipeName, tostring(recipeProduction.status))
							break
						end
					end
					
					if recipeProduction then
						self.selectedRecipeRow = {
							production = row.production,
							recipe = {
								production = recipeProduction,
								isActive = recipeProduction.status == ProductionPoint.PROD_STATUS.RUNNING or recipeProduction.status == ProductionPoint.PROD_STATUS.MISSING_INPUTS
							}
						}
						
						if recipeProduction.status == ProductionPoint.PROD_STATUS.RUNNING or recipeProduction.status == ProductionPoint.PROD_STATUS.MISSING_INPUTS then
							self.toggleRecipeButton:setText(g_i18n:getText("ui_productionDlg_btnDeactivate"))
						else
							self.toggleRecipeButton:setText(g_i18n:getText("ui_productionDlg_btnActivate"))
						end
						self.toggleRecipeButton:setVisible(true)
					else
						self.selectedRecipeRow = nil
						self.toggleRecipeButton:setVisible(false)
					end
				end
			else
				self.selectedLogisticsRow = nil
				self.selectedRecipeRow = nil
				if self.changeOutputButton ~= nil then
					self.changeOutputButton:setVisible(false)
				end
				if self.toggleRecipeButton ~= nil then
					self.toggleRecipeButton:setVisible(false)
				end
				-- Hide schedule button when no recipe row is selected
				if self.scheduleButton ~= nil then
					self.scheduleButton:setVisible(false)
				end
			end
		else
			self.selectedLogisticsRow = nil
			self.selectedRecipeRow = nil

			if self.toggleRecipeButton ~= nil then
				self.toggleRecipeButton:setVisible(false)
			end
			if self.changeOutputButton ~= nil then
				self.changeOutputButton:setVisible(false)
			end
			if self.scheduleButton ~= nil then
				self.scheduleButton:setVisible(false)
			end
		end

		self:refreshButtonLayout()
	end
end

function ProductionDlgFrame:populateCellForItemInSection(list, section, index, cell)
	if list == self.overviewTable then
		local row = self.displayRows[index]
		if row == nil then
			return
		end

		local prod = row.production
		local currencySymbol = g_i18n:getCurrencySymbol(true)

		-- Schedule view: render a single month row
		if row.rowType == "schedule" then
			cell.psMonthIdx = row.monthIdx

			cell:getAttribute("productionName"):setText(row.monthName or "?")
			cell:getAttribute("productionName"):setVisible(true)
			cell:getAttribute("statusText"):setVisible(false)

			-- Show status in first text column
			local active     = (row.enabled == true)
			local statusText = active and g_i18n:getText("PS_STATE_ACTIVE") or g_i18n:getText("PS_STATE_INACTIVE")
			cell:getAttribute("fillIcon1"):setVisible(false)
			cell:getAttribute("fillCapacity1"):setText(statusText)
			if active then
				cell:getAttribute("fillCapacity1"):setTextColor(0.1, 0.7, 0.1, 1)
			else
				cell:getAttribute("fillCapacity1"):setTextColor(0.7, 0.2, 0.2, 1)
			end
			cell:getAttribute("fillCapacity1"):setVisible(true)

			-- Seasonal price column: flag the peak-price month(s) for this output so
			-- the player can schedule production/selling around them.
			cell:getAttribute("fillIcon2"):setVisible(false)
			if row.isPeak then
				local peakText = g_i18n:getText("PS_PEAK_MARK")
				if row.peakPrice ~= nil then
					peakText = string.format("%s  %s%s/1000L", peakText,
						currencySymbol, self:formatNumber(math.floor(row.peakPrice * 1000)))
				end
				cell:getAttribute("fillCapacity2"):setText(peakText)
				cell:getAttribute("fillCapacity2"):setTextColor(0.3, 0.85, 0.3, 1)
				cell:getAttribute("fillCapacity2"):setVisible(true)
			else
				cell:getAttribute("fillCapacity2"):setVisible(false)
			end

			for i = 3, 10 do
				cell:getAttribute("fillIcon" .. i):setVisible(false)
				cell:getAttribute("fillCapacity" .. i):setVisible(false)
			end
			return
		end

		if row.rowType == "logistics_gap" then
			cell:getAttribute("productionName"):setText("")
			cell:getAttribute("productionName"):setVisible(false)
			cell:getAttribute("statusText"):setVisible(false)
			
			for i = 1, 10 do
				cell:getAttribute("fillIcon" .. i):setVisible(false)
				cell:getAttribute("fillCapacity" .. i):setVisible(false)
			end
			return
		end

		-- --------------------------------------------------------
		-- Input rows: one row per input product (icon + name + stored)
		-- --------------------------------------------------------

		if row.rowType == "input_gap" then
			cell:getAttribute("productionName"):setText("")
			cell:getAttribute("productionName"):setVisible(false)
			cell:getAttribute("statusText"):setVisible(false)
			for i = 1, 10 do
				cell:getAttribute("fillIcon" .. i):setVisible(false)
				cell:getAttribute("fillCapacity" .. i):setVisible(false)
			end
			return
		end

		if row.rowType == "input_empty" then
			cell:getAttribute("productionName"):setText(prod.name)
			cell:getAttribute("productionName"):setVisible(true)
			cell:getAttribute("statusText"):setVisible(false)
			cell:getAttribute("fillIcon1"):setVisible(false)
			cell:getAttribute("fillCapacity1"):setText("-")
			cell:getAttribute("fillCapacity1"):setTextColor(0.5, 0.5, 0.5, 1)
			cell:getAttribute("fillCapacity1"):setVisible(true)
			for i = 2, 10 do
				cell:getAttribute("fillIcon" .. i):setVisible(false)
				cell:getAttribute("fillCapacity" .. i):setVisible(false)
			end
			return
		end

		if row.rowType == "input_row" then
			local ft = row.fillType

			if row.isFirst then
				cell:getAttribute("productionName"):setText(prod.name)
				cell:getAttribute("productionName"):setVisible(true)
			else
				cell:getAttribute("productionName"):setText("")
				cell:getAttribute("productionName"):setVisible(false)
			end
			cell:getAttribute("statusText"):setVisible(false)

			-- Col 1: product icon + name
			if ft.hudOverlayFilename ~= nil and ft.hudOverlayFilename ~= "" then
				cell:getAttribute("fillIcon1"):setImageFilename(ft.hudOverlayFilename)
				cell:getAttribute("fillIcon1"):setVisible(true)
			else
				cell:getAttribute("fillIcon1"):setVisible(false)
			end
			cell:getAttribute("fillCapacity1"):setText(ft.title or "?")
			cell:getAttribute("fillCapacity1"):setTextColor(1, 1, 1, 1)
			cell:getAttribute("fillCapacity1"):setVisible(true)

			-- Col 2: stored / capacity
			cell:getAttribute("fillIcon2"):setVisible(false)
			cell:getAttribute("fillCapacity2"):setText(string.format("%s / %s L",
				self:formatNumber(math.floor(ft.liters or 0)),
				self:formatNumber(math.floor(ft.capacity or 0))))
			cell:getAttribute("fillCapacity2"):setTextColor(1, 1, 1, 1)
			cell:getAttribute("fillCapacity2"):setVisible(true)

			for i = 3, 10 do
				cell:getAttribute("fillIcon" .. i):setVisible(false)
				cell:getAttribute("fillCapacity" .. i):setVisible(false)
			end
			return
		end

		-- --------------------------------------------------------
		-- Output rows: one row per output product, with current pallet
		-- contents and an estimated output/month figure
		-- --------------------------------------------------------

		if row.rowType == "output_gap" then
			cell:getAttribute("productionName"):setText("")
			cell:getAttribute("productionName"):setVisible(false)
			cell:getAttribute("statusText"):setVisible(false)
			for i = 1, 10 do
				cell:getAttribute("fillIcon" .. i):setVisible(false)
				cell:getAttribute("fillCapacity" .. i):setVisible(false)
			end
			return
		end

		if row.rowType == "output_empty" then
			cell:getAttribute("productionName"):setText(prod.name)
			cell:getAttribute("productionName"):setVisible(true)
			cell:getAttribute("statusText"):setVisible(false)
			cell:getAttribute("fillIcon1"):setVisible(false)
			cell:getAttribute("fillCapacity1"):setText(g_i18n:getText("ui_productionDlg_outNone"))
			cell:getAttribute("fillCapacity1"):setTextColor(1, 0.5, 0, 1)
			cell:getAttribute("fillCapacity1"):setVisible(true)
			for i = 2, 10 do
				cell:getAttribute("fillIcon" .. i):setVisible(false)
				cell:getAttribute("fillCapacity" .. i):setVisible(false)
			end
			return
		end

		if row.rowType == "output_row" then
			local ft = row.fillType

			if row.isFirst then
				cell:getAttribute("productionName"):setText(prod.name)
				cell:getAttribute("productionName"):setVisible(true)
			else
				cell:getAttribute("productionName"):setText("")
				cell:getAttribute("productionName"):setVisible(false)
			end
			cell:getAttribute("statusText"):setVisible(false)

			-- Col 1: product icon + name
			if ft.hudOverlayFilename ~= nil and ft.hudOverlayFilename ~= "" then
				cell:getAttribute("fillIcon1"):setImageFilename(ft.hudOverlayFilename)
				cell:getAttribute("fillIcon1"):setVisible(true)
			else
				cell:getAttribute("fillIcon1"):setVisible(false)
			end
			cell:getAttribute("fillCapacity1"):setText(ft.title or "?")
			cell:getAttribute("fillCapacity1"):setTextColor(1, 1, 1, 1)
			cell:getAttribute("fillCapacity1"):setVisible(true)

			-- Col 2: stored in the production's internal storage
			cell:getAttribute("fillIcon2"):setVisible(false)
			cell:getAttribute("fillCapacity2"):setText(string.format("%s / %s L",
				self:formatNumber(math.floor(ft.liters or 0)),
				self:formatNumber(math.floor(ft.capacity or 0))))
			cell:getAttribute("fillCapacity2"):setTextColor(1, 1, 1, 1)
			cell:getAttribute("fillCapacity2"):setVisible(true)

			-- Col 3: contents currently sitting in the farm's pallets
			cell:getAttribute("fillIcon3"):setVisible(false)
			if ft.palletLiters ~= nil and ft.palletLiters > 0 then
				cell:getAttribute("fillCapacity3"):setText(string.format("%s L (%d)",
					self:formatNumber(math.floor(ft.palletLiters)), ft.palletCount or 0))
				cell:getAttribute("fillCapacity3"):setTextColor(0.3, 0.7, 1, 1)
			else
				cell:getAttribute("fillCapacity3"):setText("-")
				cell:getAttribute("fillCapacity3"):setTextColor(0.5, 0.5, 0.5, 1)
			end
			cell:getAttribute("fillCapacity3"):setVisible(true)

			-- Col 4: estimated output per month (pallets if a pallet size is known,
			-- otherwise litres). Narrow column, so keep the text short.
			cell:getAttribute("fillIcon4"):setVisible(false)
			if ft.monthlyPallets ~= nil and ft.monthlyPallets > 0 then
				cell:getAttribute("fillCapacity4"):setText(string.format("~%.1f/mo", ft.monthlyPallets))
				cell:getAttribute("fillCapacity4"):setTextColor(0.6, 0.9, 0.6, 1)
			elseif ft.monthlyLiters ~= nil and ft.monthlyLiters > 0 then
				cell:getAttribute("fillCapacity4"):setText(string.format("~%sL/mo",
					self:formatNumber(math.floor(ft.monthlyLiters))))
				cell:getAttribute("fillCapacity4"):setTextColor(0.6, 0.9, 0.6, 1)
			else
				cell:getAttribute("fillCapacity4"):setText("-")
				cell:getAttribute("fillCapacity4"):setTextColor(0.5, 0.5, 0.5, 1)
			end
			cell:getAttribute("fillCapacity4"):setVisible(true)

			for i = 5, 10 do
				cell:getAttribute("fillIcon" .. i):setVisible(false)
				cell:getAttribute("fillCapacity" .. i):setVisible(false)
			end
			return
		end

		-- --------------------------------------------------------
		-- Recipe rows: one row per recipe, ingredients across columns
		-- --------------------------------------------------------

		if row.rowType == "recipe_gap" then
			cell:getAttribute("productionName"):setText("")
			cell:getAttribute("productionName"):setVisible(false)
			cell:getAttribute("statusText"):setVisible(false)
			for i = 1, 10 do
				cell:getAttribute("fillIcon" .. i):setVisible(false)
				cell:getAttribute("fillCapacity" .. i):setVisible(false)
			end
			return
		end

		if row.rowType == "recipe_empty" then
			cell:getAttribute("productionName"):setText(prod.name)
			cell:getAttribute("productionName"):setVisible(true)
			cell:getAttribute("statusText"):setVisible(false)
			cell:getAttribute("fillIcon1"):setVisible(false)
			cell:getAttribute("fillCapacity1"):setText("No Recipes")
			cell:getAttribute("fillCapacity1"):setTextColor(1, 0.5, 0, 1)
			cell:getAttribute("fillCapacity1"):setVisible(true)
			for i = 2, 10 do
				cell:getAttribute("fillIcon" .. i):setVisible(false)
				cell:getAttribute("fillCapacity" .. i):setVisible(false)
			end
			return
		end

		if row.rowType == "recipe_row" then
			local recipe = row.recipe

			-- NAME column: facility name on first row only
			if row.isFirst then
				cell:getAttribute("productionName"):setText(prod.name)
				cell:getAttribute("productionName"):setVisible(true)
			else
				cell:getAttribute("productionName"):setText("")
				cell:getAttribute("productionName"):setVisible(false)
			end

			-- Status text (Active / Inactive / Active(!))
			local recipeStatus = g_i18n:getText("ui_prodmgr_status_inactive")
			local statusColor  = {1, 0, 0, 1}
			if recipe.status == ProductionPoint.PROD_STATUS.RUNNING then
				recipeStatus = g_i18n:getText("ui_prodmgr_status_active")
				statusColor  = {0, 1, 0, 1}
			elseif recipe.status == ProductionPoint.PROD_STATUS.MISSING_INPUTS then
				recipeStatus = g_i18n:getText("ui_prodmgr_status_active") .. "(!)"
				statusColor  = {1, 0.6, 0, 1}
			end
			cell:getAttribute("statusText"):setText(recipeStatus)
			cell:getAttribute("statusText"):setTextColor(statusColor[1], statusColor[2], statusColor[3], statusColor[4])
			cell:getAttribute("statusText"):setVisible(true)

			-- Col 1: output icon + recipe name (under Recipe header)
			if recipe.outputFillTypeInfo and recipe.outputFillTypeInfo.hudOverlayFilename and recipe.outputFillTypeInfo.hudOverlayFilename ~= "" then
				cell:getAttribute("fillIcon1"):setImageFilename(recipe.outputFillTypeInfo.hudOverlayFilename)
				cell:getAttribute("fillIcon1"):setVisible(true)
			else
				cell:getAttribute("fillIcon1"):setVisible(false)
			end
			cell:getAttribute("fillCapacity1"):setText(recipe.name or "")
			cell:getAttribute("fillCapacity1"):setTextColor(1, 1, 1, 1)
			cell:getAttribute("fillCapacity1"):setVisible(true)

			-- Cols 2-5: one ingredient per column (under Ingredients header)
			local inputs = recipe.inputs or {}
			for i = 1, 4 do
				local colIcon = cell:getAttribute("fillIcon" .. (i + 1))
				local colText = cell:getAttribute("fillCapacity" .. (i + 1))
				if i <= #inputs then
					local input    = inputs[i]
					local fillType = g_fillTypeManager:getFillTypeByIndex(input.type)
					if fillType and fillType.hudOverlayFilename and fillType.hudOverlayFilename ~= "" then
						colIcon:setImageFilename(fillType.hudOverlayFilename)
						colIcon:setVisible(true)
					else
						colIcon:setVisible(false)
					end
					local amtText = fillType and (fillType.title .. ": " .. self:formatNumber(math.floor(input.amount)) .. "L") or "?"
					colText:setText(amtText)
					colText:setTextColor(0.9, 0.9, 0.9, 1)
					colText:setVisible(true)
				else
					colIcon:setVisible(false)
					colText:setVisible(false)
				end
			end

			-- Hide second-row slots (6-10)
			for i = 6, 10 do
				cell:getAttribute("fillIcon" .. i):setVisible(false)
				cell:getAttribute("fillCapacity" .. i):setVisible(false)
			end
			return
		end

		if row.rowType == "logistics" or row.rowType == "logistics_empty" then
			if row.isFirst then
				cell:getAttribute("productionName"):setText(prod.name)
				cell:getAttribute("productionName"):setVisible(true)
			else
				cell:getAttribute("productionName"):setText("")
				cell:getAttribute("productionName"):setVisible(false)
			end
			
			if row.rowType == "logistics_empty" then
				cell:getAttribute("statusText"):setVisible(false)
				
				cell:getAttribute("fillIcon1"):setVisible(false)
				cell:getAttribute("fillCapacity1"):setText("No Active Recipes")
				cell:getAttribute("fillCapacity1"):setTextColor(1, 0.5, 0, 1)
				cell:getAttribute("fillCapacity1"):setVisible(true)
				
				for i = 2, 10 do
					cell:getAttribute("fillIcon" .. i):setVisible(false)
					cell:getAttribute("fillCapacity" .. i):setVisible(false)
				end
			else
				local logistic = row.logistic
				
				local recipeStatus = g_i18n:getText("ui_prodmgr_status_inactive")
				local statusColor = {1, 0, 0, 1} 

				local productionPoint = prod.productionPoint
				if productionPoint and productionPoint.productions then
					for _, production in pairs(productionPoint.productions) do
						if production.name == logistic.recipe then
							if production.status == ProductionPoint.PROD_STATUS.RUNNING then
								recipeStatus = g_i18n:getText("ui_prodmgr_status_active")
								statusColor = {0, 1, 0, 1} 
							elseif production.status == ProductionPoint.PROD_STATUS.MISSING_INPUTS then
								recipeStatus = g_i18n:getText("ui_prodmgr_status_active") .. "(!)"
								statusColor = {1, 0.6, 0, 1} 
							end
							break
						end
					end
				end
				
				-- Append schedule indicator [S] to status if scheduled
				if logistic.scheduleIndicator and logistic.scheduleIndicator ~= "" then
					recipeStatus = recipeStatus .. logistic.scheduleIndicator
				end
							
				cell:getAttribute("statusText"):setText(recipeStatus)
				cell:getAttribute("statusText"):setTextColor(statusColor[1], statusColor[2], statusColor[3], statusColor[4])
				cell:getAttribute("statusText"):setVisible(true)
				
				
				if logistic.outputFillTypeInfo and logistic.outputFillTypeInfo.hudOverlayFilename and logistic.outputFillTypeInfo.hudOverlayFilename ~= "" then
					cell:getAttribute("fillIcon1"):setImageFilename(logistic.outputFillTypeInfo.hudOverlayFilename)
					cell:getAttribute("fillIcon1"):setVisible(true)
				else
					cell:getAttribute("fillIcon1"):setVisible(false)
				end
				cell:getAttribute("fillCapacity1"):setText(logistic.recipe)
				cell:getAttribute("fillCapacity1"):setTextColor(1, 1, 1, 1)
				cell:getAttribute("fillCapacity1"):setVisible(true)
				
				
				cell:getAttribute("fillIcon2"):setVisible(false)
				cell:getAttribute("fillCapacity2"):setText(string.format("%.0f", logistic.cyclesPerMonth))
				cell:getAttribute("fillCapacity2"):setTextColor(1, 1, 1, 1)
				cell:getAttribute("fillCapacity2"):setVisible(true)
				
				
				cell:getAttribute("fillIcon3"):setVisible(false)
				cell:getAttribute("fillCapacity3"):setText(logistic.supplyDuration)
				local durColor = {1, 1, 1, 1}
				if logistic.supplyDuration:match("h$") then
					local hours = tonumber(logistic.supplyDuration:match("([%d%.]+)"))
					if hours and hours < 12 then
						durColor = {1, 0, 0, 1}
					elseif hours and hours < 24 then
						durColor = {1, 0.5, 0, 1}
					end
				end
				cell:getAttribute("fillCapacity3"):setTextColor(durColor[1], durColor[2], durColor[3], durColor[4])
				cell:getAttribute("fillCapacity3"):setVisible(true)
				
				
				cell:getAttribute("fillIcon4"):setVisible(false)
				cell:getAttribute("fillCapacity4"):setText(logistic.outputMode)
				local modeColor = {1, 1, 1, 1}
				if logistic.outputMode == "Selling" then
					modeColor = {0, 1, 0, 1}
				elseif logistic.outputMode == "Distributing" then
					modeColor = {0.3, 0.7, 1, 1}
				end
				cell:getAttribute("fillCapacity4"):setTextColor(modeColor[1], modeColor[2], modeColor[3], modeColor[4])
				cell:getAttribute("fillCapacity4"):setVisible(true)
				
				-- Destination
				cell:getAttribute("fillIcon5"):setVisible(false)
				
				local destText = logistic.destination
				
				cell:getAttribute("fillCapacity5"):setText(destText)
				local destColor = logistic.destinationColor or {1, 1, 1, 1}
				cell:getAttribute("fillCapacity5"):setTextColor(destColor[1], destColor[2], destColor[3], destColor[4])
				cell:getAttribute("fillCapacity5"):setVisible(true)
				
				for i = 6, 10 do
					cell:getAttribute("fillIcon" .. i):setVisible(false)
					cell:getAttribute("fillCapacity" .. i):setVisible(false)
				end
			end
			return
		end

		
		cell:getAttribute("statusText"):setVisible(false)

		if row.rowType == "finance" then
			cell:getAttribute("productionName"):setText(prod.name)
			cell:getAttribute("productionName"):setVisible(true)
			
			local revenueText = string.format("%s%s/mo", currencySymbol, self:formatNumber(math.floor(prod.monthlyRevenue)))
			local costsText = string.format("%s%s/mo", currencySymbol, self:formatNumber(math.floor(prod.monthlyCosts)))
			local profitText = string.format("%s%s/mo", currencySymbol, self:formatNumber(math.floor(prod.monthlyIncome)))
			
			cell:getAttribute("fillIcon1"):setVisible(false)
			cell:getAttribute("fillCapacity1"):setText(revenueText)
			cell:getAttribute("fillCapacity1"):setTextColor(1, 1, 1, 1)
			cell:getAttribute("fillCapacity1"):setVisible(true)
			
			cell:getAttribute("fillIcon2"):setVisible(false)
			cell:getAttribute("fillCapacity2"):setText(costsText)
			cell:getAttribute("fillCapacity2"):setTextColor(1, 0, 0, 1)
			cell:getAttribute("fillCapacity2"):setVisible(true)
			
			cell:getAttribute("fillIcon3"):setVisible(false)
			cell:getAttribute("fillCapacity3"):setText(profitText)
			if prod.monthlyIncome >= 0 then
				cell:getAttribute("fillCapacity3"):setTextColor(0, 1, 0, 1)
			else
				cell:getAttribute("fillCapacity3"):setTextColor(1, 0, 0, 1)
			end
			cell:getAttribute("fillCapacity3"):setVisible(true)

			-- Value of output auto-delivered to other facilities. Not income, so it is
			-- excluded from revenue/profit and shown separately.
			cell:getAttribute("fillIcon4"):setVisible(false)
			if prod.monthlyDistributedValue > 0 then
				cell:getAttribute("fillCapacity4"):setText(string.format("%s%s/mo",
					currencySymbol, self:formatNumber(math.floor(prod.monthlyDistributedValue))))
				cell:getAttribute("fillCapacity4"):setTextColor(0.3, 0.7, 1, 1)
			else
				cell:getAttribute("fillCapacity4"):setText("-")
				cell:getAttribute("fillCapacity4"):setTextColor(0.5, 0.5, 0.5, 1)
			end
			cell:getAttribute("fillCapacity4"):setVisible(true)

			-- Best current sell price for this facility's top output, and where.
			-- Prices shown per 1000L to match the in-game prices menu convention.
			cell:getAttribute("fillIcon5"):setVisible(false)
			if prod.bestSale ~= nil then
				-- Full station name; the cell uses scrolling text layout so long
				-- names marquee rather than truncate.
				local station = prod.bestSale.stationName or "?"
				cell:getAttribute("fillCapacity5"):setText(string.format("%s%s @ %s",
					currencySymbol,
					self:formatNumber(math.floor(prod.bestSale.pricePerLiter * 1000)),
					station))
				cell:getAttribute("fillCapacity5"):setTextColor(0.6, 0.9, 0.6, 1)
			else
				cell:getAttribute("fillCapacity5"):setText("-")
				cell:getAttribute("fillCapacity5"):setTextColor(0.5, 0.5, 0.5, 1)
			end
			cell:getAttribute("fillCapacity5"):setVisible(true)

			for i = 6, 10 do
				cell:getAttribute("fillIcon" .. i):setVisible(false)
				cell:getAttribute("fillCapacity" .. i):setVisible(false)
			end
			return
		end

		local fillTypes = row.fillTypes

		if row.rowType == "row1" then
			cell:getAttribute("productionName"):setText(prod.name)
			cell:getAttribute("productionName"):setVisible(true)
		else
			cell:getAttribute("productionName"):setText("")
			cell:getAttribute("productionName"):setVisible(false)
		end

		for i = 1, 5 do
			local fillIcon = cell:getAttribute("fillIcon" .. i)
			local fillCapacity = cell:getAttribute("fillCapacity" .. i)
			local dataIndex = row.startIndex + (i - 1)

			if dataIndex <= #fillTypes then
				local fillType = fillTypes[dataIndex]
				fillCapacity:setTextColor(1, 1, 1, 1)
				
				if self.showRecipes then
					local iconFilename = fillType.outputFillTypeInfo and fillType.outputFillTypeInfo.hudOverlayFilename or nil
					
					if iconFilename and iconFilename ~= "" then
						fillIcon:setImageFilename(iconFilename)
						fillIcon:setVisible(true)
					else
						fillIcon:setVisible(false)
					end
					
				
					local statusColor = {1, 0, 0, 1} 
					if fillType.status == ProductionPoint.PROD_STATUS.RUNNING then
						statusColor = {0, 1, 0, 1} 
					elseif fillType.status == ProductionPoint.PROD_STATUS.MISSING_INPUTS then
						statusColor = {1, 0.6, 0, 1} 
					end
					
					fillCapacity:setText(fillType.name)
					fillCapacity:setTextColor(statusColor[1], statusColor[2], statusColor[3], statusColor[4])
					fillCapacity:setVisible(true)
				else
					if fillType.hudOverlayFilename ~= nil and fillType.hudOverlayFilename ~= "" then
						fillIcon:setImageFilename(fillType.hudOverlayFilename)
						fillIcon:setVisible(true)
					else
						fillIcon:setVisible(false)
					end

					local capacityText = string.format("%s / %s L", 
						self:formatNumber(math.floor(fillType.liters)),
						self:formatNumber(math.floor(fillType.capacity)))
					fillCapacity:setText(capacityText)
					fillCapacity:setVisible(true)
				end
			else
				fillIcon:setVisible(false)
				fillCapacity:setVisible(false)
			end
		end
		
		if not self.showFinances and not self.showLogistics then
			for i = 6, 10 do
				local fillIcon = cell:getAttribute("fillIcon" .. i)
				local fillCapacity = cell:getAttribute("fillCapacity" .. i)
				local dataIndex = row.startIndex + (i - 1)

				if dataIndex <= #fillTypes and row.rowType == "rowN" then
					local fillType = fillTypes[dataIndex]
					fillCapacity:setTextColor(1, 1, 1, 1)
					
					if self.showRecipes then
						local iconFilename = fillType.outputFillTypeInfo and fillType.outputFillTypeInfo.hudOverlayFilename or nil
						
						if iconFilename and iconFilename ~= "" then
							fillIcon:setImageFilename(iconFilename)
							fillIcon:setVisible(true)
						else
							fillIcon:setVisible(false)
						end
						
						
						local statusColor = {1, 0, 0, 1} 
						if fillType.status == ProductionPoint.PROD_STATUS.RUNNING then
							statusColor = {0, 1, 0, 1} 
						elseif fillType.status == ProductionPoint.PROD_STATUS.MISSING_INPUTS then
							statusColor = {1, 0.6, 0, 1} 
						end
						
						fillCapacity:setText(fillType.name)
						fillCapacity:setTextColor(statusColor[1], statusColor[2], statusColor[3], statusColor[4])
						fillCapacity:setVisible(true)
					else
						if fillType.hudOverlayFilename ~= nil and fillType.hudOverlayFilename ~= "" then
							fillIcon:setImageFilename(fillType.hudOverlayFilename)
							fillIcon:setVisible(true)
						else
							fillIcon:setVisible(false)
						end

						local capacityText = string.format("%s / %s L", 
							self:formatNumber(math.floor(fillType.liters)),
							self:formatNumber(math.floor(fillType.capacity)))
						fillCapacity:setText(capacityText)
						fillCapacity:setVisible(true)
					end
				else
					fillIcon:setVisible(false)
					fillCapacity:setVisible(false)
				end
			end
		end
	end
end

function ProductionDlgFrame:formatNumber(num)
	local formatted = tostring(num)
	local k
	while true do  
		formatted, k = string.gsub(formatted, "^(-?%d+)(%d%d%d)", '%1,%2')
		if k == 0 then
			break
		end
	end
	return formatted
end

function ProductionDlgFrame:update(dt)
    ProductionDlgFrame:superClass().update(self, dt)
end

function ProductionDlgFrame:onClose()
	self.productions = {}
	self.displayRows = {}
	ProductionDlgFrame:superClass().onClose(self)
end

function ProductionDlgFrame:onClickBack(sender)
	self:close()
end