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
local Stages = require(Shared.Config.Stages)

local ArenaController = {}

type LightingSnapshot = {
	fogColor: Color3,
	fogStart: number,
	fogEnd: number,
	ambient: Color3,
	outdoorAmbient: Color3,
	clockTime: number,
}

local lobbySnapshot: LightingSnapshot? = nil

local function snapshotLighting(): LightingSnapshot
	return {
		fogColor = Lighting.FogColor,
		fogStart = Lighting.FogStart,
		fogEnd = Lighting.FogEnd,
		ambient = Lighting.Ambient,
		outdoorAmbient = Lighting.OutdoorAmbient,
		clockTime = Lighting.ClockTime,
	}
end

local function restoreLighting(snapshot: LightingSnapshot): ()
	Lighting.FogColor = snapshot.fogColor
	Lighting.FogStart = snapshot.fogStart
	Lighting.FogEnd = snapshot.fogEnd
	Lighting.Ambient = snapshot.ambient
	Lighting.OutdoorAmbient = snapshot.outdoorAmbient
	Lighting.ClockTime = snapshot.clockTime
end

--[[
	Палитра локации, в которой идёт забег.

	Номер уровня приходит вместе со стартом, а сам уровень собирается той же
	функцией, что и на сервере — Stages.Get. Локация без своей записи
	откатывается на общую палитру: забытый цвет не должен ронять бой.
]]
local function paletteFor(stageIndex: number): typeof(Palette.Arena)
	local stage = if stageIndex > 0 then Stages.Get(stageIndex) else nil
	local named = if stage then Palette.Arenas[stage.location.palette] else nil
	return named or Palette.Arena
end

local function applyArenaLighting(palette: typeof(Palette.Arena)): ()
	Lighting.FogColor = palette.fog
	Lighting.FogStart = Balance.Arena.fogStart
	Lighting.FogEnd = Balance.Arena.fogEnd
	Lighting.Ambient = palette.floor
	Lighting.OutdoorAmbient = palette.floor

	--[[
		Время суток берётся из конфига и ставится ЛОКАЛЬНО: Lighting один на
		сервер, и серверная правка задела бы всех, кто сейчас в лобби.

		Стояла ночь (M7) — ради звёздного неба без ассетов. Вернули день:
		с тёмным ambient локации и туманом в 130 стадов ночью переставало
		быть видно происходящее, а небо этого не стоит.
	]]
	Lighting.ClockTime = Balance.Arena.clockTime
end

function ArenaController.Start(): ()
	Net.GetEvent(Net.Id.RunStarted).OnClientEvent
		:Connect(function(_slot: number, _seed: number, _magnet: number, _mode: string, stageIndex: number)
			if not lobbySnapshot then
				lobbySnapshot = snapshotLighting()
			end
			applyArenaLighting(paletteFor(stageIndex))
		end)

	Net.GetEvent(Net.Id.RunEnded).OnClientEvent:Connect(function()
		local snapshot = lobbySnapshot
		if snapshot then
			restoreLighting(snapshot)
		end
	end)
end

return ArenaController
