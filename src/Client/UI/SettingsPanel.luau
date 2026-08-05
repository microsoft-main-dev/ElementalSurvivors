--!strict
--[[
	SettingsPanel — настройки игрока (раздел 2.1 ТЗ, M7).

	Пять строк, у каждой одна кнопка-переключатель: клик проходит по кругу
	значений и сразу шлёт SetSetting. Отдельного "Сохранить" нет — так же,
	как остальные панели лобби не имеют явного сейва: правка уходит на сервер
	сразу, а профиль — источник правды.

	Строка эффектов других игроков показывает значение и принимает клики, но
	сейчас ни на что не влияет: в проекте нет ни одной донатной косметики
	с Trail/ParticleEmitter (M6 сделал только числовые статы предметов).
	Настройка ждёт визуал, а не наоборот — см. комментарий у Types.OthersEffectsMode.

	Публичный API:
		SettingsPanel.Build(parent, send) -> Panel
		panel.Open()
		panel.Close()
		panel.Refresh(settings)
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Palette = require(Shared.Config.Palette)
local Types = require(Shared.Types)
local UiKit = require(script.Parent.UiKit)

export type Panel = {
	Open: () -> (),
	Close: () -> (),
	Refresh: (settings: Types.ProfileSettings) -> (),
}

local SettingsPanel = {}

local QUALITY_CYCLE: { Types.QualityMode } = { "Auto", "High", "Low" }
local EFFECTS_CYCLE: { Types.OthersEffectsMode } = { "All", "Nearby", "Off" }
local VOLUME_STEP = 0.25

local function nextOf<T>(cycle: { T }, current: T): T
	for index, value in cycle do
		if value == current then
			return cycle[index % #cycle + 1]
		end
	end
	return cycle[1]
end

local function nextVolume(current: number): number
	local stepped = math.floor(current / VOLUME_STEP + 0.5) + 1
	if stepped * VOLUME_STEP > 1 + 1e-6 then
		return 0
	end
	return stepped * VOLUME_STEP
end

local function percent(value: number): string
	return `{math.floor(value * 100 + 0.5)}%`
end

function SettingsPanel.Build(parent: Instance, send: (action: string, target: string?, extra: unknown) -> ()): Panel
	local window = UiKit.Window(parent, "SettingsPanel", "Settings")
	window.subtitle.Text = "Applies immediately"

	local list = UiKit.Scroll(window.content, "List")
	list.Size = UDim2.fromScale(1, 1)

	-- Дефолты повторяют ProfileSchema.Template.settings до первого Refresh.
	local current: Types.ProfileSettings = {
		quality = "Auto",
		othersEffects = "All",
		sfxVolume = 1,
		musicVolume = 1,
		showDamageMeter = true,
	}

	local function render(): ()
		UiKit.ClearList(list)

		local qualityRow = UiKit.Row(list, 1, Palette.UI.accent)
		qualityRow.title.Text = "Quality"
		qualityRow.subtitle.Text = "Auto picks by your device"
		local qualityButton = UiKit.Button(qualityRow.actions, "Value", current.quality)
		qualityButton.Size = UDim2.fromOffset(112, UiKit.ButtonHeight)
		qualityButton.Activated:Connect(function()
			send("SetSetting", "quality", nextOf(QUALITY_CYCLE, current.quality))
		end)

		local effectsRow = UiKit.Row(list, 2, Palette.UI.accent)
		effectsRow.title.Text = "Other players' effects"
		effectsRow.subtitle.Text = "Cosmetic FX, lobby only"
		local effectsButton = UiKit.Button(effectsRow.actions, "Value", current.othersEffects)
		effectsButton.Size = UDim2.fromOffset(112, UiKit.ButtonHeight)
		effectsButton.Activated:Connect(function()
			send("SetSetting", "othersEffects", nextOf(EFFECTS_CYCLE, current.othersEffects))
		end)

		local sfxRow = UiKit.Row(list, 3, Palette.UI.accent)
		sfxRow.title.Text = "Sound volume"
		sfxRow.subtitle.Text = percent(current.sfxVolume)
		local sfxButton = UiKit.Button(sfxRow.actions, "Value", percent(current.sfxVolume))
		sfxButton.Size = UDim2.fromOffset(112, UiKit.ButtonHeight)
		sfxButton.Activated:Connect(function()
			send("SetSetting", "sfxVolume", nextVolume(current.sfxVolume))
		end)

		local musicRow = UiKit.Row(list, 4, Palette.UI.accent)
		musicRow.title.Text = "Music volume"
		musicRow.subtitle.Text = percent(current.musicVolume)
		local musicButton = UiKit.Button(musicRow.actions, "Value", percent(current.musicVolume))
		musicButton.Size = UDim2.fromOffset(112, UiKit.ButtonHeight)
		musicButton.Activated:Connect(function()
			send("SetSetting", "musicVolume", nextVolume(current.musicVolume))
		end)

		local meterRow = UiKit.Row(list, 5, Palette.UI.accent)
		meterRow.title.Text = "Damage meter"
		meterRow.subtitle.Text = "Per-ability totals during combat"
		local meterButton =
			UiKit.Button(meterRow.actions, "Value", if current.showDamageMeter then "Shown" else "Hidden")
		meterButton.Size = UDim2.fromOffset(112, UiKit.ButtonHeight)
		meterButton.Activated:Connect(function()
			send("SetSetting", "showDamageMeter", not current.showDamageMeter)
		end)
	end

	local panel: Panel = {
		Open = function()
			window.screen.Enabled = true
			render()
		end,

		Close = function()
			window.screen.Enabled = false
		end,

		Refresh = function(settings: Types.ProfileSettings)
			current = settings
			if window.screen.Enabled then
				render()
			end
		end,
	}

	return panel
end

return SettingsPanel
