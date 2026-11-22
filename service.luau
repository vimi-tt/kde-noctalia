--!nonstrict

local BUS_NAME = "org.kde.kdeconnect"
local DAEMON_PATH = "/modules/kdeconnect"
local DAEMON_IFACE = "org.kde.kdeconnect.daemon"
local DEVICE_IFACE = "org.kde.kdeconnect.device"
local BATTERY_IFACE = "org.kde.kdeconnect.device.battery"
local MPRIS_IFACE = "org.kde.kdeconnect.device.mprisremote"
local NOTIFS_IFACE = "org.kde.kdeconnect.device.notifications"
local NOTIF_ITEM_IFACE = "org.kde.kdeconnect.device.notifications.notification"
local PING_IFACE = "org.kde.kdeconnect.device.ping"
local FIND_IFACE = "org.kde.kdeconnect.device.findmyphone"
local SHARE_IFACE = "org.kde.kdeconnect.device.share"
local CLIPBOARD_IFACE = "org.kde.kdeconnect.device.clipboard"
local PROPS_IFACE = "org.freedesktop.DBus.Properties"

local state = {
	daemonOnline = false,
	error = "",
	activeDeviceId = "",
	devices = {},
	updatedAt = 0,
}

local refreshInFlight = false
local refreshQueued = false
local monitorStarted = false
local lastSignalRefreshMs = 0

local function hasPlugin(supportedPlugins: { string }?, pluginName: string): boolean
	if not supportedPlugins then
		return false
	end
	for _, name in ipairs(supportedPlugins) do
		if name == pluginName then
			return true
		end
	end
	return false
end

local function unwrapProp(props: { [string]: any }?, key: string, defaultValue: any): any
	if not props or props[key] == nil then
		return defaultValue
	end
	local entry = props[key]
	if type(entry) == "table" and entry.data ~= nil then
		return entry.data
	end
	return entry
end

local function decodeJson(raw: string?): any
	if not raw or raw == "" then
		return nil
	end
	local ok, parsed = pcall(noctalia.json.decode, raw)
	if not ok then
		return nil
	end
	return parsed
end

local function pickActiveDeviceId(devices: { any }, preferredId: string): string
	if #devices == 0 then
		return ""
	end
	if preferredId ~= "" then
		for _, dev in ipairs(devices) do
			if dev.id == preferredId then
				return preferredId
			end
		end
	end
	local configured = noctalia.getConfig("default_device")
	if type(configured) == "string" and configured ~= "" then
		for _, dev in ipairs(devices) do
			if dev.id == configured or dev.name == configured then
				return dev.id
			end
		end
	end
	for _, dev in ipairs(devices) do
		if dev.isReachable and dev.isPaired then
			return dev.id
		end
	end
	for _, dev in ipairs(devices) do
		if dev.isPaired then
			return dev.id
		end
	end
	return devices[1].id
end

local function publishState()
	state.updatedAt = os.time()
	noctalia.state.set("kdeconnect", state)
end

local function findDevice(devId: string?): any
	if not devId or devId == "" then
		return nil
	end
	for _, dev in ipairs(state.devices) do
		if dev.id == devId then
			return dev
		end
	end
	return nil
end

local function fetchNotifications(devPath: string, cb: ({ any }) -> ())
	noctalia.runAsync({
		"busctl", "--user", "--json=short", "call",
		BUS_NAME, devPath .. "/notifications", NOTIFS_IFACE, "activeNotifications",
	}, function(res)
		if res.exitCode ~= 0 then
			cb({})
			return
		end
		local parsed = decodeJson(res.stdout)
		local notifIds = (parsed and type(parsed.data) == "table" and parsed.data[1]) or {}
		if #notifIds == 0 then
			cb({})
			return
		end

		local items = {}
		local pending = #notifIds
		for _, nid in ipairs(notifIds) do
			noctalia.runAsync({
				"busctl", "--user", "--json=short", "call",
				BUS_NAME, devPath .. "/notifications/" .. nid, PROPS_IFACE, "GetAll", "s", NOTIF_ITEM_IFACE,
			}, function(nRes)
				if nRes.exitCode == 0 then
					local nJson = decodeJson(nRes.stdout)
					local props = (nJson and type(nJson.data) == "table" and nJson.data[1]) or {}
					table.insert(items, {
						id = nid,
						appName = unwrapProp(props, "appName", "App"),
						title = unwrapProp(props, "title", ""),
						text = unwrapProp(props, "text", ""),
						isClearable = unwrapProp(props, "isClearable", true),
						replyId = unwrapProp(props, "replyId", ""),
					})
				end
				pending -= 1
				if pending == 0 then
					cb(items)
				end
			end)
		end
	end)
end

local function fetchDeviceDetails(dev: any, devPath: string, done: () -> ())
	if not (dev.isReachable and dev.isPaired) then
		done()
		return
	end

	local tasks = 0
	local function taskDone()
		tasks -= 1
		if tasks == 0 then
			done()
		end
	end

	local needBattery = hasPlugin(dev.supportedPlugins, "kdeconnect_battery")
	local needMpris = hasPlugin(dev.supportedPlugins, "kdeconnect_mprisremote")
	local needNotifs = hasPlugin(dev.supportedPlugins, "kdeconnect_notifications")

	if needBattery then tasks += 1 end
	if needMpris then tasks += 1 end
	if needNotifs then tasks += 1 end

	if tasks == 0 then
		done()
		return
	end

	if needBattery then
		noctalia.runAsync({
			"busctl", "--user", "--json=short", "call",
			BUS_NAME, devPath .. "/battery", PROPS_IFACE, "GetAll", "s", BATTERY_IFACE,
		}, function(batRes)
			if batRes.exitCode == 0 then
				local batJson = decodeJson(batRes.stdout)
				local batProps = (batJson and type(batJson.data) == "table" and batJson.data[1]) or {}
				dev.batteryCharge = unwrapProp(batProps, "charge", -1)
				dev.batteryCharging = unwrapProp(batProps, "isCharging", false)
			end
			taskDone()
		end)
	end

	if needMpris then
		noctalia.runAsync({
			"busctl", "--user", "--json=short", "call",
			BUS_NAME, devPath .. "/mprisremote", PROPS_IFACE, "GetAll", "s", MPRIS_IFACE,
		}, function(mRes)
			if mRes.exitCode == 0 then
				local mJson = decodeJson(mRes.stdout)
				local mProps = (mJson and type(mJson.data) == "table" and mJson.data[1]) or {}
				local player = unwrapProp(mProps, "player", "")
				local title = unwrapProp(mProps, "title", "")
				local artist = unwrapProp(mProps, "artist", "")
				local playerList = unwrapProp(mProps, "playerList", {})
				dev.mpris = {
					hasPlayer = (player ~= "" or title ~= "" or #playerList > 0),
					player = player,
					title = title,
					artist = artist,
					album = unwrapProp(mProps, "album", ""),
					isPlaying = unwrapProp(mProps, "isPlaying", false),
				}
			end
			taskDone()
		end)
	end

	if needNotifs then
		fetchNotifications(devPath, function(items)
			dev.notifications = items
			taskDone()
		end)
	end
end

local function refreshDevices()
	if refreshInFlight then
		refreshQueued = true
		return
	end
	refreshInFlight = true
	refreshQueued = false

	noctalia.runAsync({
		"busctl", "--user", "--json=short", "call",
		BUS_NAME, DAEMON_PATH, DAEMON_IFACE, "devices",
	}, function(res)
		if res.exitCode ~= 0 then
			state.daemonOnline = false
			state.devices = {}
			state.activeDeviceId = ""
			state.error = "Daemon kdeconnectd indisponível"
			publishState()
			refreshInFlight = false
			if refreshQueued then
				refreshDevices()
			end
			return
		end

		local parsed = decodeJson(res.stdout)
		local ids = (parsed and type(parsed.data) == "table" and parsed.data[1]) or {}
		state.daemonOnline = true
		state.error = ""

		if #ids == 0 then
			state.devices = {}
			state.activeDeviceId = ""
			publishState()
			refreshInFlight = false
			if refreshQueued then
				refreshDevices()
			end
			return
		end

		local collected = {}
		local pending = #ids

		local function onOneFinished()
			pending -= 1
			if pending > 0 then
				return
			end

			table.sort(collected, function(a, b)
				if a.isReachable ~= b.isReachable then
					return a.isReachable
				end
				if a.isPaired ~= b.isPaired then
					return a.isPaired
				end
				return a.name < b.name
			end)

			state.devices = collected
			state.activeDeviceId = pickActiveDeviceId(collected, state.activeDeviceId)
			publishState()

			refreshInFlight = false
			if refreshQueued then
				refreshDevices()
			end
		end

		for _, devId in ipairs(ids) do
			local devPath = DAEMON_PATH .. "/devices/" .. devId
			noctalia.runAsync({
				"busctl", "--user", "--json=short", "call",
				BUS_NAME, devPath, PROPS_IFACE, "GetAll", "s", DEVICE_IFACE,
			}, function(devRes)
				if devRes.exitCode ~= 0 then
					onOneFinished()
					return
				end

				local devJson = decodeJson(devRes.stdout)
				local props = (devJson and type(devJson.data) == "table" and devJson.data[1]) or {}
				local supported = unwrapProp(props, "supportedPlugins", {})
				local hasList = type(supported) == "table" and #supported > 0

				local dev = {
					id = devId,
					name = unwrapProp(props, "name", devId),
					type = unwrapProp(props, "type", "phone"),
					isPaired = unwrapProp(props, "isPaired", false),
					isReachable = unwrapProp(props, "isReachable", false),
					isPairRequested = unwrapProp(props, "isPairRequested", false),
					isPairRequestedByPeer = unwrapProp(props, "isPairRequestedByPeer", false),
					supportedPlugins = supported,
					canPing = (not hasList) or hasPlugin(supported, "kdeconnect_ping"),
					canRing = (not hasList) or hasPlugin(supported, "kdeconnect_findmyphone"),
					canShare = (not hasList) or hasPlugin(supported, "kdeconnect_share"),
					canClipboard = (not hasList) or hasPlugin(supported, "kdeconnect_clipboard"),
					canMpris = (not hasList) or hasPlugin(supported, "kdeconnect_mprisremote"),
					canNotifications = (not hasList) or hasPlugin(supported, "kdeconnect_notifications"),
					batteryCharge = -1,
					batteryCharging = false,
					mpris = nil,
					notifications = {},
				}

				fetchDeviceDetails(dev, devPath, function()
					table.insert(collected, dev)
					onOneFinished()
				end)
			end)
		end
	end)
end

local function dbusCall(path: string, iface: string, method: string, sig: string?, ...: string)
	local argv = { "busctl", "--user", "call", BUS_NAME, path, iface, method }
	if sig and sig ~= "" then
		table.insert(argv, sig)
		for i = 1, select("#", ...) do
			table.insert(argv, select(i, ...))
		end
	end
	return argv
end

local function startMonitor()
	if monitorStarted then
		return
	end
	monitorStarted = true

	noctalia.runStream("gdbus monitor --session --dest " .. BUS_NAME, function(line)
		if not line or line == "" then
			return
		end
		if string.find(line, "org.kde.kdeconnect", 1, true)
			or string.find(line, "PropertiesChanged", 1, true)
			or string.find(line, "NameOwnerChanged", 1, true)
		then
			local now = noctalia.nowMs and noctalia.nowMs() or (os.time() * 1000)
			if (now - lastSignalRefreshMs) >= 350 then
				lastSignalRefreshMs = now
				refreshDevices()
			end
		end
	end)
end

function onIpc(event: string, payload: string?)
	if event == "refresh" then
		refreshDevices()
		return
	elseif event == "select_device" and payload and payload ~= "" then
		state.activeDeviceId = payload
		publishState()
		return
	end

	local data = decodeJson(payload)
	local devId = (type(data) == "table" and data.id) or payload or state.activeDeviceId
	local dev = findDevice(devId)
	if not devId or devId == "" then
		return
	end
	local devPath = DAEMON_PATH .. "/devices/" .. devId
	local devName = (dev and dev.name) or devId

	if event == "ping" then
		noctalia.runAsync(dbusCall(devPath .. "/ping", PING_IFACE, "sendPing"), function(res)
			if res.exitCode == 0 then
				noctalia.notify("KDE Connect", "Ping enviado para " .. devName)
			else
				noctalia.notifyError("KDE Connect", "Falha ao enviar ping para " .. devName)
			end
		end)
	elseif event == "ring" then
		noctalia.runAsync(dbusCall(devPath .. "/findmyphone", FIND_IFACE, "ring"), function(res)
			if res.exitCode == 0 then
				noctalia.notify("KDE Connect", "Tocando " .. devName)
			else
				noctalia.notifyError("KDE Connect", "Não foi possível tocar " .. devName)
			end
		end)
	elseif event == "send_clipboard" then
		noctalia.runAsync(dbusCall(devPath .. "/clipboard", CLIPBOARD_IFACE, "sendClipboard"), function(res)
			if res.exitCode == 0 then
				noctalia.notify("KDE Connect", "Área de transferência enviada para " .. devName)
			else
				noctalia.notifyError("KDE Connect", "Falha ao enviar área de transferência")
			end
		end)
	elseif event == "share_text" and type(data) == "table" and data.text and data.text ~= "" then
		local text = tostring(data.text)
		local isUrl = string.match(text, "^https?://") ~= nil
		local method = isUrl and "shareUrl" or "shareText"
		noctalia.runAsync(dbusCall(devPath .. "/share", SHARE_IFACE, method, "s", text), function(res)
			if res.exitCode == 0 then
				noctalia.notify("KDE Connect", (isUrl and "Link enviado para " or "Texto enviado para ") .. devName)
			else
				noctalia.notifyError("KDE Connect", "Falha ao enviar para " .. devName)
			end
		end)
	elseif event == "share_file" then
		noctalia.runAsync({
			"zenity", "--file-selection", "--title=Enviar arquivo para " .. devName,
		}, function(pickRes)
			if pickRes.exitCode ~= 0 then
				return
			end
			local filePath = string.gsub(pickRes.stdout or "", "[\r\n]+$", "")
			if filePath == "" then
				return
			end
			noctalia.runAsync(dbusCall(devPath .. "/share", SHARE_IFACE, "openFile", "s", "file://" .. filePath), function(res)
				if res.exitCode == 0 then
					noctalia.notify("KDE Connect", "Arquivo enviado para " .. devName)
				else
					noctalia.notifyError("KDE Connect", "Falha ao enviar arquivo")
				end
			end)
		end)
	elseif event == "pair" then
		local method = (dev and dev.isPairRequestedByPeer) and "acceptPairing" or "requestPairing"
		noctalia.runAsync(dbusCall(devPath, DEVICE_IFACE, method), function()
			refreshDevices()
		end)
	elseif event == "cancel_pair" then
		noctalia.runAsync(dbusCall(devPath, DEVICE_IFACE, "cancelPairing"), function()
			refreshDevices()
		end)
	elseif event == "unpair" then
		noctalia.runAsync(dbusCall(devPath, DEVICE_IFACE, "unpair"), function(res)
			if res.exitCode == 0 then
				noctalia.notify("KDE Connect", devName .. " despareado")
			end
			refreshDevices()
		end)
	elseif event == "mpris" and type(data) == "table" and data.action then
		noctalia.runAsync(dbusCall(devPath .. "/mprisremote", MPRIS_IFACE, "sendAction", "s", tostring(data.action)), function()
			refreshDevices()
		end)
	elseif event == "dismiss_notif" and type(data) == "table" and data.notifId then
		noctalia.runAsync(dbusCall(devPath .. "/notifications/" .. tostring(data.notifId), NOTIF_ITEM_IFACE, "dismiss"), function()
			refreshDevices()
		end)
	elseif event == "reply_notif" and type(data) == "table" and data.replyId and data.message and data.message ~= "" then
		noctalia.runAsync(dbusCall(devPath .. "/notifications", NOTIFS_IFACE, "sendReply", "ss", tostring(data.replyId), tostring(data.message)), function(res)
			if res.exitCode == 0 then
				noctalia.notify("KDE Connect", "Resposta enviada")
			else
				noctalia.notifyError("KDE Connect", "Falha ao responder notificação")
			end
			refreshDevices()
		end)
	end
end

function onConfigChanged()
	state.activeDeviceId = pickActiveDeviceId(state.devices, "")
	publishState()
end

function onExit()
	monitorStarted = false
end

noctalia.state.watch("kdeconnect_cmd", function(cmd: any)
	if type(cmd) ~= "table" or not cmd.event then
		return
	end
	local payload = cmd.payload
	if type(payload) == "table" then
		payload = noctalia.json.encode(payload)
	end
	onIpc(tostring(cmd.event), payload ~= nil and tostring(payload) or nil)
end)

startMonitor()
refreshDevices()
