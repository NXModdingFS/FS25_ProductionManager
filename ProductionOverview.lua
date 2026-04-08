ProductionOverview = {}

ProductionOverview.dir = g_currentModDirectory
ProductionOverview.modName = g_currentModName
ProductionOverview.dlg = nil

-- Core UI
source(ProductionOverview.dir .. "gui/ProductionDlgFrame.lua")

function ProductionOverview:loadMap(name)
	print("Production Manager - ModHub V1.0.0.0 - Development V1.0.0.4")
end

function ProductionOverview:ShowProductionDlg(actionName, keyStatus, arg3, arg4, arg5)
	ProductionOverview.dlg = nil
	g_gui:loadProfiles(ProductionOverview.dir .. "gui/guiProfiles.xml")
	local productionDlgFrame = ProductionDlgFrame.new(g_i18n)
	g_gui:loadGui(ProductionOverview.dir .. "gui/ProductionDlgFrame.xml", "ProductionDlgFrame", productionDlgFrame)
	ProductionOverview.dlg = g_gui:showDialog("ProductionDlgFrame")
end

function ProductionOverview:onLoad(savegame) end
function ProductionOverview:onUpdate(dt) end
function ProductionOverview:deleteMap() end
function ProductionOverview:keyEvent(unicode, sym, modifier, isDown) end
function ProductionOverview:mouseEvent(posX, posY, isDown, isUp, button) end

addModEventListener(ProductionOverview)