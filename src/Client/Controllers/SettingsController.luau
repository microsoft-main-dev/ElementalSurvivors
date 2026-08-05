--!strict
--[[
	SettingsController — держатель текущих настроек игрока (M7, раздел 2.1 ТЗ).

	Настройки лежат в профиле и приходят как часть ProfileView — отдельного
	Remote под них нет: пуш уже существует, а второй канал для того же факта
	держать незачем.

	Другие контроллеры (SoundController, RenderController'ы) читают текущие
	настройки через Get(), а не подписываются на ProfileView каждый сам:
	если разбор формы значений когда-нибудь изменится, менять его придётся
	только здесь.

	quality = "Auto" не запоминается один раз при первом входе — ResolveQuality
	разворачивает его в High/Low заново при каждом обращении, по текущему
	вьюпорту и наличию тача. Так режим остаётся верным, даже если игрок зашёл
	с телефона, а потом с компьютера на том же аккаунте.

	Публичный API:
		SettingsController.Get() -> Types.ProfileSettings
		SettingsController.ResolveQuality() -> "High" | "Low"
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Net = require(Shared.Net)
local Types = require(Shared.Types)

-- Ниже этой ширины вьюпорта Auto считает устройство телефоном, даже без тача
-- (окно Studio, зауженное для проверки вёрстки).
local AUTO_LOW_WIDTH = 900

local SettingsController = {}

-- Дефолты повторяют ProfileSchema.Template.settings: до первого ProfileView
-- (доля секунды после входа) остальным контроллерам всё равно нужно что-то
-- вернуть, и это должно быть то же самое значение, что выдаст сервер.
local current: Types.ProfileSettings = {
	quality = "Auto",
	othersEffects = "All",
	sfxVolume = 1,
	musicVolume = 1,
	showDamageMeter = true,
}

function SettingsController.Get(): Types.ProfileSettings
	return current
end

function SettingsController.ResolveQuality(): "High" | "Low"
	local mode = current.quality
	if mode == "High" or mode == "Low" then
		return mode
	end

	if UserInputService.TouchEnabled then
		return "Low"
	end

	local camera = Workspace.CurrentCamera
	local viewport = if camera then camera.ViewportSize else Vector2.new(AUTO_LOW_WIDTH, AUTO_LOW_WIDTH)
	if viewport.X < AUTO_LOW_WIDTH then
		return "Low"
	end

	return "High"
end

function SettingsController.Start(): ()
	Net.GetEvent(Net.Id.ProfileView).OnClientEvent:Connect(function(view: Types.ProfileView)
		current = view.settings
	end)
end

return SettingsController
