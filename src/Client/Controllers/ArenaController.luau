--!strict
--[[
	ArenaController — палитра и туман арены.

	Lighting в Roblox один на весь сервер, поэтому «своя палитра у каждой
	локации» (раздел 5.1 ТЗ) через сервер невозможна: на одном сервере до восьми
	игроков на разных аренах. Зато изменения Lighting, сделанные локальным
	скриптом, не реплицируются — значит палитру каждый клиент ставит себе сам.
	Это и делается здесь, и это же станет точкой входа для 20 локаций в M6.

	Декор арены строит ArenaService на сервере: колонна с настоящей коллизией
	обязана быть серверной, потому что физику игрока проверяет сервер.
	Визуал способностей живёт в AbilityFxController.
]]

local Lighting = game:GetService("Lighting")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Balance = require(Shared.Config.Balance)
local Net = require(Shared.Net)
local Palette = require(Shared.Config.Palette)

local ArenaController = {}

type LightingSnapshot = {
	fogColor: Color3,
	fogStart: number,
	fogEnd: number,
	ambient: Color3,
	outdoorAmbient: Color3,
}

local lobbySnapshot: LightingSnapshot? = nil

local function snapshotLighting(): LightingSnapshot
	return {
		fogColor = Lighting.FogColor,
		fogStart = Lighting.FogStart,
		fogEnd = Lighting.FogEnd,
		ambient = Lighting.Ambient,
		outdoorAmbient = Lighting.OutdoorAmbient,
	}
end

local function restoreLighting(snapshot: LightingSnapshot): ()
	Lighting.FogColor = snapshot.fogColor
	Lighting.FogStart = snapshot.fogStart
	Lighting.FogEnd = snapshot.fogEnd
	Lighting.Ambient = snapshot.ambient
	Lighting.OutdoorAmbient = snapshot.outdoorAmbient
end

local function applyArenaLighting(): ()
	Lighting.FogColor = Palette.Arena.fog
	Lighting.FogStart = Balance.Arena.fogStart
	Lighting.FogEnd = Balance.Arena.fogEnd
	Lighting.Ambient = Palette.Arena.floor
	Lighting.OutdoorAmbient = Palette.Arena.floor
end

function ArenaController.Start(): ()
	Net.GetEvent(Net.Id.RunStarted).OnClientEvent:Connect(function()
		if not lobbySnapshot then
			lobbySnapshot = snapshotLighting()
		end
		applyArenaLighting()
	end)

	Net.GetEvent(Net.Id.RunEnded).OnClientEvent:Connect(function()
		local snapshot = lobbySnapshot
		if snapshot then
			restoreLighting(snapshot)
		end
	end)
end

return ArenaController
