ProductionOverview = {}

ProductionOverview.dir = g_currentModDirectory
ProductionOverview.modName = g_currentModName
ProductionOverview.dlg = nil

-- Core UI
source(ProductionOverview.dir .. "gui/ProductionDlgFrame.lua")
-- Menu frame MUST be sourced after the dialog: it aliases the dialog's render
-- methods, so ProductionDlgFrame has to exist when this file runs. Wrapped in
-- pcall so a problem in the (newer, experimental) menu file can never stop the
-- proven dialog from loading.
pcall(function()
	source(ProductionOverview.dir .. "gui/InGameMenuProductionsManager.lua")
end)

-- Insights sub-tabs. They use the core/ modules, so this file is listed last in
-- modDesc; guarded so they can never break the page above.
pcall(function()
	source(ProductionOverview.dir .. "gui/ProductionInsightsView.lua")
end)

ProductionOverview.MENU_PAGE_NAME = "ingameMenuProductionsManager"

-- Standard community pattern for slotting a custom frame into the base in-game
-- menu. Position is clamped so it can never overflow the element list.
function ProductionOverview.fixInGameMenu(frame, pageName, uvs, position, predicateFunc)
	local inGameMenu = g_gui.screenControllers[InGameMenu]
	if inGameMenu == nil then return false end

	inGameMenu.controlIDs[pageName] = nil
	inGameMenu[pageName] = frame
	inGameMenu.pagingElement:addElement(inGameMenu[pageName])
	inGameMenu:exposeControlsAsFields(pageName)

	local pos = math.min(position, #inGameMenu.pagingElement.elements)

	for i = 1, #inGameMenu.pagingElement.elements do
		if inGameMenu.pagingElement.elements[i] == inGameMenu[pageName] then
			table.remove(inGameMenu.pagingElement.elements, i)
			table.insert(inGameMenu.pagingElement.elements, pos, inGameMenu[pageName])
			break
		end
	end
	for i = 1, #inGameMenu.pagingElement.pages do
		if inGameMenu.pagingElement.pages[i].element == inGameMenu[pageName] then
			local page = inGameMenu.pagingElement.pages[i]
			table.remove(inGameMenu.pagingElement.pages, i)
			table.insert(inGameMenu.pagingElement.pages, pos, page)
			break
		end
	end

	inGameMenu.pagingElement:updateAbsolutePosition()
	inGameMenu.pagingElement:updatePageMapping()

	inGameMenu:registerPage(inGameMenu[pageName], position, predicateFunc)
	local iconFileName = Utils.getFilename("images/menuIcon.dds", ProductionOverview.dir)
	inGameMenu:addPageTab(inGameMenu[pageName], iconFileName, GuiUtils.getUVs(uvs))

	for i = 1, #inGameMenu.pageFrames do
		if inGameMenu.pageFrames[i] == inGameMenu[pageName] then
			table.remove(inGameMenu.pageFrames, i)
			table.insert(inGameMenu.pageFrames, pos, inGameMenu[pageName])
			break
		end
	end

	inGameMenu:rebuildTabList()
	return true
end

-- Build + inject the ESC-menu tab. Wrapped by the caller in pcall so any failure
-- here can never stop the rest of the mod (dialog, managers, hotkey) from loading.
function ProductionOverview:setupInGameMenu()
	g_gui:loadProfiles(ProductionOverview.dir .. "gui/guiProfiles.xml")
	g_gui:loadProfiles(ProductionOverview.dir .. "gui/guiProfiles_InGameMenu.xml")

	local frame = InGameMenuProductionsManager.new(g_i18n, g_messageCenter)
	g_gui:loadGui(ProductionOverview.dir .. "gui/InGameMenuProductionsManager.xml",
		ProductionOverview.MENU_PAGE_NAME, frame, true)

	local ok = ProductionOverview.fixInGameMenu(frame, ProductionOverview.MENU_PAGE_NAME,
		{0, 0, 1024, 1024}, 9, function() return true end)

	if ok and frame.initialize ~= nil then
		frame:initialize()
		ProductionOverview.menuFrame = frame
		print("[ProductionManager] In-game menu tab registered")
	end
end

function ProductionOverview:loadMap(name)
	print("Production Manager - ModHub V1.0.0.0 - Development V1.0.0.4")

	-- Defensive: a menu-injection problem must never break the working dialog.
	local ok, err = pcall(function() ProductionOverview:setupInGameMenu() end)
	if not ok then
		Logging.warning("[ProductionManager] In-game menu setup failed, dialog still available (%s)", tostring(err))
	end

end

-- NOTE: The old Right-Shift-P popup dialog has been retired in favour of the
-- in-game ESC-menu tab. ProductionDlgFrame.lua is still sourced above because the
-- menu frame reuses its data/rendering methods - it is now a code library only and
-- is never shown as a dialog.

function ProductionOverview:onLoad(savegame) end
function ProductionOverview:onUpdate(dt) end
function ProductionOverview:deleteMap() end
function ProductionOverview:keyEvent(unicode, sym, modifier, isDown) end
function ProductionOverview:mouseEvent(posX, posY, isDown, isUp, button) end

addModEventListener(ProductionOverview)