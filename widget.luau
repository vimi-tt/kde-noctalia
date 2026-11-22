--!nonstrict

local function findActiveDevice(state: any)
	if not state or not state.devices or #state.devices == 0 then
		return nil
	end
	for _, dev in ipairs(state.devices) do
		if dev.id == state.activeDeviceId then
			return dev
		end
	end
	return state.devices[1]
end

local function hasConnectedDevice(state: any): boolean
	if not state or not state.daemonOnline or not state.devices then
		return false
	end
	for _, dev in ipairs(state.devices) do
		if dev.isReachable and dev.isPaired then
			return true
		end
	end
	return false
end

local function renderState(state: any)
	local hideWhenDisconnected = noctalia.getConfig("hide_when_disconnected") == true
	local showBatteryText = noctalia.getConfig("show_battery_text") ~= false

	if hideWhenDisconnected and not hasConnectedDevice(state) then
		if barWidget.setVisible then
			barWidget.setVisible(false)
		end
		return
	end

	if barWidget.setVisible then
		barWidget.setVisible(true)
	end

	if not state or not state.daemonOnline then
		barWidget.setGlyph("plug-connected-x")
		barWidget.setText("")
		barWidget.setTooltip("KDE Connect: daemon offline")
		return
	end

	local dev = findActiveDevice(state)
	if not dev then
		barWidget.setGlyph("device-mobile")
		barWidget.setText("")
		barWidget.setTooltip("KDE Connect: nenhum dispositivo encontrado")
		return
	end

	if not dev.isReachable then
		barWidget.setGlyph("device-mobile")
		barWidget.setText("")
		barWidget.setTooltip(string.format("%s — Desconectado\nClique para abrir o painel", dev.name))
		return
	end

	if not dev.isPaired then
		barWidget.setGlyph("link")
		barWidget.setText("?")
		barWidget.setTooltip(string.format("%s — Não pareado\nClique para parear", dev.name))
		return
	end

	barWidget.setGlyph(dev.batteryCharging and "battery-charging" or "device-mobile")
	if dev.batteryCharge and dev.batteryCharge >= 0 then
		if showBatteryText then
			barWidget.setText(string.format("%d%%", dev.batteryCharge))
		else
			barWidget.setText("")
		end
		local status = dev.batteryCharging and "Carregando" or "Conectado"
		barWidget.setTooltip(string.format("%s — %s (%d%%)\nClique para abrir o painel", dev.name, status, dev.batteryCharge))
	else
		barWidget.setText("")
		barWidget.setTooltip(string.format("%s — Conectado\nClique para abrir o painel", dev.name))
	end
end

function onClick()
	if noctalia.togglePanel then
		noctalia.togglePanel("vimi/kdeconnect:panel")
	end
end

local cmdSeq = 0

function onRightClick()
	cmdSeq += 1
	noctalia.state.set("kdeconnect_cmd", { event = "refresh", seq = cmdSeq })
end

noctalia.state.watch("kdeconnect", renderState)
renderState(noctalia.state.get("kdeconnect"))
