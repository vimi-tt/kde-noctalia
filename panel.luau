--!nonstrict

local isOpen = false
local confirmUnpairId = ""
local shareDraft = ""
local activeReplyNotifId = ""
local replyDraft = ""

local cmdSeq = 0

local function sendService(event: string, payload: any?)
	cmdSeq += 1
	noctalia.state.set("kdeconnect_cmd", {
		event = event,
		payload = payload,
		seq = cmdSeq,
	})
end

local function hasCapability(dev: any, flagKey: string, pluginName: string): boolean
	if not dev then
		return false
	end
	if dev[flagKey] ~= nil then
		return dev[flagKey] == true
	end
	if type(dev.supportedPlugins) == "table" and #dev.supportedPlugins > 0 then
		for _, name in ipairs(dev.supportedPlugins) do
			if name == pluginName then
				return true
			end
		end
		return false
	end
	return true
end

local function getActiveDevice(state: any)
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

local function deviceGlyph(devType: string?): string
	if devType == "tablet" then
		return "device-tablet"
	elseif devType == "laptop" or devType == "desktop" then
		return "device-laptop"
	end
	return "device-mobile"
end

local function batteryGlyph(charge: number, charging: boolean): string
	if charging then
		return "battery-charging"
	elseif charge >= 80 then
		return "battery-4"
	elseif charge >= 55 then
		return "battery-3"
	elseif charge >= 30 then
		return "battery-2"
	elseif charge >= 10 then
		return "battery-1"
	end
	return "battery"
end

local function statusText(dev: any): string
	if not dev.isReachable then
		return "Desconectado"
	elseif dev.isPairRequestedByPeer then
		return "Pedido de pareamento recebido"
	elseif dev.isPairRequested then
		return "Aguardando confirmação"
	elseif not dev.isPaired then
		return "Não pareado"
	elseif dev.batteryCharge and dev.batteryCharge >= 0 then
		local extra = dev.batteryCharging and " • Carregando" or ""
		return string.format("Conectado • %d%%%s", dev.batteryCharge, extra)
	end
	return "Conectado"
end

local function iconAction(glyphName: string, tooltipText: string, onPress: () -> ())
	return ui.row({
		padding = 6,
		radius = 999,
		fill = "surface_container_high",
		align = "center",
		justify = "center",
		tooltip = tooltipText,
		onClick = onPress,
	}, {
		ui.glyph({ name = glyphName, size = 16, color = "on_surface_variant" }),
	})
end

local function buildHeader(state: any)
	local online = state and state.daemonOnline
	local badgeFill = online and "primary_container" or "error_container"
	local badgeColor = online and "on_primary_container" or "on_error_container"
	local badgeText = online and "Ativo" or "Offline"

	return ui.row({
		gap = 8,
		align = "center",
		justify = "space_between",
		paddingH = 4,
		paddingV = 2,
	}, {
		ui.row({ gap = 8, align = "center", flexGrow = 1 }, {
			ui.glyph({ name = "device-mobile", size = 20, color = "primary" }),
			ui.label({ text = "KDE Connect", fontSize = 16, fontWeight = "bold" }),
			ui.row({ fill = badgeFill, radius = 999, paddingH = 8, paddingV = 2 }, {
				ui.label({ text = badgeText, fontSize = 11, fontWeight = "bold", color = badgeColor }),
			}),
		}),
		ui.row({ gap = 6, align = "center" }, {
			iconAction("refresh", "Atualizar dispositivos", function()
				sendService("refresh")
			end),
			iconAction("settings", "Configurações do plugin", function()
				if noctalia.openSettings then
					noctalia.openSettings()
				end
			end),
			iconAction("x", "Fechar painel", function()
				panel.close()
			end),
		}),
	})
end

local function buildEmptyCard(icon: string, title: string, subtitle: string, actionLabel: string?, actionFn: (() -> ())?)
	local children = {
		ui.glyph({ name = icon, size = 32, color = "on_surface_variant" }),
		ui.label({ text = title, fontSize = 14, fontWeight = "bold" }),
		ui.label({ text = subtitle, fontSize = 12, color = "on_surface_variant" }),
	}
	if actionLabel and actionFn then
		table.insert(children, ui.button({
			text = actionLabel,
			variant = "primary",
			controlSize = "sm",
			onClick = actionFn,
		}))
	end

	return ui.column({
		gap = 8,
		align = "center",
		fill = "surface_container",
		radius = 16,
		padding = 20,
	}, children)
end

local function buildDeviceItem(dev: any, isSelected: boolean)
	local fillColor = isSelected and "primary_container" or "surface_container"
	local titleColor = isSelected and "on_primary_container" or "on_surface"
	local subColor = isSelected and "on_primary_container" or "on_surface_variant"
	local iconColor = dev.isReachable and (isSelected and "on_primary_container" or "primary") or "on_surface_variant"

	local rightChildren = {}
	if dev.isReachable and dev.isPaired and dev.batteryCharge and dev.batteryCharge >= 0 then
		table.insert(rightChildren, ui.row({ gap = 4, align = "center" }, {
			ui.glyph({ name = batteryGlyph(dev.batteryCharge, dev.batteryCharging), size = 16, color = titleColor }),
			ui.label({ text = string.format("%d%%", dev.batteryCharge), fontSize = 12, fontWeight = "bold", color = titleColor }),
		}))
	end

	return ui.row({
		gap = 12,
		align = "center",
		justify = "space_between",
		fill = fillColor,
		radius = 14,
		paddingH = 14,
		paddingV = 12,
		onClick = function()
			confirmUnpairId = ""
			activeReplyNotifId = ""
			sendService("select_device", dev.id)
		end,
	}, {
		ui.row({ gap = 10, align = "center", flexGrow = 1 }, {
			ui.glyph({ name = deviceGlyph(dev.type), size = 20, color = iconColor }),
			ui.column({ gap = 2, flexGrow = 1 }, {
				ui.label({ text = dev.name, fontSize = 13, fontWeight = "bold", color = titleColor }),
				ui.label({ text = statusText(dev), fontSize = 11, color = subColor }),
			}),
		}),
		ui.row({ gap = 6, align = "center" }, rightChildren),
	})
end

local function buildPairingSection(dev: any)
	if dev.isPairRequestedByPeer then
		return ui.column({ gap = 10, fill = "surface_container", radius = 16, padding = 14 }, {
			ui.label({ text = dev.name .. " pediu para parear", fontSize = 13, fontWeight = "bold" }),
			ui.row({ gap = 8 }, {
				ui.button({
					text = "Aceitar",
					variant = "primary",
					controlSize = "sm",
					flexGrow = 1,
					onClick = function() sendService("pair", dev.id) end,
				}),
				ui.button({
					text = "Recusar",
					variant = "destructive",
					controlSize = "sm",
					flexGrow = 1,
					onClick = function() sendService("cancel_pair", dev.id) end,
				}),
			}),
		})
	elseif dev.isPairRequested then
		return ui.column({ gap = 10, fill = "surface_container", radius = 16, padding = 14 }, {
			ui.label({ text = "Aguardando aceitação em " .. dev.name .. "...", fontSize = 12, color = "on_surface_variant" }),
			ui.button({
				text = "Cancelar solicitação",
				variant = "outline",
				controlSize = "sm",
				onClick = function() sendService("cancel_pair", dev.id) end,
			}),
		})
	end

	return buildEmptyCard(
		"link",
		"Dispositivo não pareado",
		"Pareie para acessar ações rápidas, mídia e notificações.",
		"Parear dispositivo",
		function() sendService("pair", dev.id) end
	)
end

local function actionTile(glyphName: string, labelText: string, onPress: () -> ())
	return ui.row({
		gap = 8,
		align = "center",
		justify = "center",
		fill = "surface_container_high",
		radius = 12,
		paddingH = 12,
		paddingV = 10,
		flexGrow = 1,
		onClick = onPress,
	}, {
		ui.glyph({ name = glyphName, size = 16, color = "primary" }),
		ui.label({ text = labelText, fontSize = 12, fontWeight = "bold" }),
	})
end

local function buildQuickActions(dev: any, rerender: () -> ())
	local showPing = noctalia.getConfig("show_ping") ~= false
	local showRing = noctalia.getConfig("show_ring") ~= false
	local showShare = noctalia.getConfig("show_share") ~= false
	local showClipboard = noctalia.getConfig("show_clipboard") ~= false

	local tiles = {}
	if showPing and hasCapability(dev, "canPing", "kdeconnect_ping") then
		table.insert(tiles, actionTile("bell", "Ping", function()
			sendService("ping", dev.id)
		end))
	end
	if showRing and hasCapability(dev, "canRing", "kdeconnect_findmyphone") then
		table.insert(tiles, actionTile("bell-ringing", "Tocar celular", function()
			sendService("ring", dev.id)
		end))
	end
	if showShare and hasCapability(dev, "canShare", "kdeconnect_share") then
		table.insert(tiles, actionTile("upload", "Enviar arquivo", function()
			sendService("share_file", dev.id)
		end))
	end
	if showClipboard and hasCapability(dev, "canClipboard", "kdeconnect_clipboard") then
		table.insert(tiles, actionTile("clipboard", "Clipboard", function()
			sendService("send_clipboard", dev.id)
		end))
	end

	local children = {
		ui.row({ justify = "space_between", align = "center" }, {
			ui.label({ text = "Ações rápidas", fontSize = 12, fontWeight = "bold", color = "on_surface_variant" }),
			ui.button({
				text = "Desparear",
				variant = "ghost",
				controlSize = "sm",
				onClick = function()
					confirmUnpairId = dev.id
					rerender()
				end,
			}),
		}),
	}

	if confirmUnpairId == dev.id then
		table.insert(children, ui.column({
			gap = 8,
			fill = "error_container",
			radius = 12,
			padding = 12,
		}, {
			ui.label({ text = "Confirmar despareamento de " .. dev.name .. "?", fontSize = 12, fontWeight = "bold", color = "on_error_container" }),
			ui.row({ gap = 8 }, {
				ui.button({
					text = "Confirmar",
					variant = "destructive",
					controlSize = "sm",
					flexGrow = 1,
					onClick = function()
						confirmUnpairId = ""
						sendService("unpair", dev.id)
					end,
				}),
				ui.button({
					text = "Cancelar",
					variant = "ghost",
					controlSize = "sm",
					flexGrow = 1,
					onClick = function()
						confirmUnpairId = ""
						rerender()
					end,
				}),
			}),
		}))
	end

	-- Grade 2 colunas para nunca estourar a largura do painel
	for i = 1, #tiles, 2 do
		if tiles[i + 1] then
			table.insert(children, ui.row({ gap = 8 }, { tiles[i], tiles[i + 1] }))
		else
			table.insert(children, ui.row({ gap = 8 }, { tiles[i] }))
		end
	end

	if showShare and hasCapability(dev, "canShare", "kdeconnect_share") then
		table.insert(children, ui.row({ gap = 8, align = "center" }, {
			ui.input({
				value = shareDraft,
				placeholder = "Enviar texto ou link...",
				flexGrow = 1,
				submitOnEnter = true,
				onChange = function(text)
					shareDraft = text
				end,
				onSubmit = function(text)
					local value = (text and text ~= "") and text or shareDraft
					if value ~= "" then
						shareDraft = ""
						sendService("share_text", { id = dev.id, text = value })
						rerender()
					end
				end,
			}),
			ui.button({
				text = "Enviar",
				variant = "primary",
				controlSize = "sm",
				onClick = function()
					if shareDraft ~= "" then
						local value = shareDraft
						shareDraft = ""
						sendService("share_text", { id = dev.id, text = value })
						rerender()
					end
				end,
			}),
		}))
	end

	return ui.column({ gap = 10, fill = "surface_container", radius = 16, padding = 14 }, children)
end

local function buildMprisSection(dev: any)
	local m = dev.mpris
	if not m or not m.hasPlayer then
		return nil
	end

	local title = (m.title and m.title ~= "") and m.title or "Sem faixa ativa"
	local sub = (m.artist and m.artist ~= "") and m.artist or (m.player ~= "" and m.player or "Mídia")
	local playText = m.isPlaying and "Pausar" or "Tocar"

	return ui.column({ gap = 10, fill = "surface_container", radius = 16, padding = 14 }, {
		ui.row({ justify = "space_between", align = "center" }, {
			ui.label({ text = "Mídia no celular", fontSize = 12, fontWeight = "bold", color = "on_surface_variant" }),
			ui.label({ text = m.player or "", fontSize = 11, color = "on_surface_variant" }),
		}),
		ui.column({ gap = 2 }, {
			ui.label({ text = title, fontSize = 13, fontWeight = "bold" }),
			ui.label({ text = sub, fontSize = 11, color = "on_surface_variant" }),
		}),
		ui.row({ gap = 8 }, {
			ui.button({
				text = "Anterior",
				variant = "secondary",
				controlSize = "sm",
				flexGrow = 1,
				onClick = function() sendService("mpris", { id = dev.id, action = "Previous" }) end,
			}),
			ui.button({
				text = playText,
				variant = "primary",
				controlSize = "sm",
				flexGrow = 1,
				onClick = function() sendService("mpris", { id = dev.id, action = "PlayPause" }) end,
			}),
			ui.button({
				text = "Próxima",
				variant = "secondary",
				controlSize = "sm",
				flexGrow = 1,
				onClick = function() sendService("mpris", { id = dev.id, action = "Next" }) end,
			}),
		}),
	})
end

local function buildNotificationsSection(dev: any, rerender: () -> ())
	if not hasCapability(dev, "canNotifications", "kdeconnect_notifications") then
		return nil
	end

	local notifs = dev.notifications or {}
	local children = {
		ui.label({
			text = string.format("Notificações (%d)", #notifs),
			fontSize = 12,
			fontWeight = "bold",
			color = "on_surface_variant",
		}),
	}

	if #notifs == 0 then
		table.insert(children, ui.column({ fill = "surface_container", radius = 14, padding = 14, align = "center" }, {
			ui.label({ text = "Nenhuma notificação ativa", fontSize = 12, color = "on_surface_variant" }),
		}))
		return ui.column({ gap = 8 }, children)
	end

	for _, n in ipairs(notifs) do
		local actionRow = {}
		if n.replyId and n.replyId ~= "" then
			table.insert(actionRow, ui.button({
				text = "Responder",
				variant = "ghost",
				controlSize = "sm",
				onClick = function()
					if activeReplyNotifId == n.id then
						activeReplyNotifId = ""
					else
						activeReplyNotifId = n.id
						replyDraft = ""
					end
					rerender()
				end,
			}))
		end
		if n.isClearable then
			table.insert(actionRow, ui.button({
				text = "Dispensar",
				variant = "ghost",
				controlSize = "sm",
				onClick = function()
					sendService("dismiss_notif", { id = dev.id, notifId = n.id })
				end,
			}))
		end

		local cardChildren = {
			ui.row({ justify = "space_between", align = "center" }, {
				ui.label({ text = n.appName or "App", fontSize = 11, fontWeight = "bold", color = "primary", flexGrow = 1 }),
				ui.row({ gap = 4 }, actionRow),
			}),
		}

		if n.title and n.title ~= "" then
			table.insert(cardChildren, ui.label({ text = n.title, fontSize = 13, fontWeight = "bold" }))
		end
		if n.text and n.text ~= "" then
			table.insert(cardChildren, ui.label({ text = n.text, fontSize = 12, color = "on_surface_variant" }))
		end

		if activeReplyNotifId == n.id and n.replyId and n.replyId ~= "" then
			table.insert(cardChildren, ui.row({ gap = 6, align = "center" }, {
				ui.input({
					value = replyDraft,
					placeholder = "Escrever resposta...",
					flexGrow = 1,
					focus = true,
					submitOnEnter = true,
					onChange = function(text)
						replyDraft = text
					end,
					onSubmit = function(text)
						local msg = (text and text ~= "") and text or replyDraft
						if msg ~= "" then
							activeReplyNotifId = ""
							replyDraft = ""
							sendService("reply_notif", { id = dev.id, replyId = n.replyId, message = msg })
							rerender()
						end
					end,
				}),
				ui.button({
					text = "Enviar",
					variant = "primary",
					controlSize = "sm",
					onClick = function()
						if replyDraft ~= "" then
							local msg = replyDraft
							activeReplyNotifId = ""
							replyDraft = ""
							sendService("reply_notif", { id = dev.id, replyId = n.replyId, message = msg })
							rerender()
						end
					end,
				}),
			}))
		end

		table.insert(children, ui.column({ gap = 4, fill = "surface_container", radius = 14, padding = 12 }, cardChildren))
	end

	return ui.column({ gap = 8 }, children)
end

local function renderPanel(state: any)
	if not isOpen then
		return
	end

	local function rerender()
		renderPanel(noctalia.state.get("kdeconnect"))
	end

	local bodyChildren = {
		buildHeader(state),
	}

	if not state or not state.daemonOnline then
		table.insert(bodyChildren, buildEmptyCard(
			"plug-connected-x",
			"Daemon do KDE Connect offline",
			"Inicie o serviço kdeconnectd na sua sessão e tente novamente.",
			"Tentar novamente",
			function()
				sendService("refresh")
			end
		))
	elseif not state.devices or #state.devices == 0 then
		table.insert(bodyChildren, buildEmptyCard(
			"device-mobile",
			"Nenhum dispositivo encontrado",
			"Abra o KDE Connect no celular conectado à mesma rede Wi-Fi.",
			"Procurar novamente",
			function()
				sendService("refresh")
			end
		))
	else
		local active = getActiveDevice(state)
		local deviceCards = {}
		for _, dev in ipairs(state.devices) do
			table.insert(deviceCards, buildDeviceItem(dev, active ~= nil and dev.id == active.id))
		end

		table.insert(bodyChildren, ui.column({ gap = 6 }, {
			ui.label({ text = "Dispositivos", fontSize = 12, fontWeight = "bold", color = "on_surface_variant" }),
			ui.column({ gap = 8 }, deviceCards),
		}))

		if active then
			if not active.isReachable then
				table.insert(bodyChildren, buildEmptyCard(
					"plug-connected-x",
					active.name .. " está offline",
					"Verifique se o aparelho está ligado e na mesma rede Wi-Fi.",
					nil,
					nil
				))
			elseif not active.isPaired then
				table.insert(bodyChildren, buildPairingSection(active))
			else
				table.insert(bodyChildren, buildQuickActions(active, rerender))

				if noctalia.getConfig("show_media") ~= false then
					local mprisCard = buildMprisSection(active)
					if mprisCard then
						table.insert(bodyChildren, mprisCard)
					end
				end

				if noctalia.getConfig("show_notifications") ~= false then
					local notifsSection = buildNotificationsSection(active, rerender)
					if notifsSection then
						table.insert(bodyChildren, notifsSection)
					end
				end
			end
		end
	end

	panel.render(ui.scroll({
		padding = 16,
		gap = 12,
	}, bodyChildren))
end

function onOpen()
	isOpen = true
	confirmUnpairId = ""
	activeReplyNotifId = ""
	renderPanel(noctalia.state.get("kdeconnect"))
	sendService("refresh")
end

function onClose()
	isOpen = false
	confirmUnpairId = ""
	activeReplyNotifId = ""
end

noctalia.state.watch("kdeconnect", renderPanel)
