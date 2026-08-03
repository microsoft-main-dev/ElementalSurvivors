--!strict
--[[
	HudController — интерфейс боя (раздел 8 ТЗ).

	Таймер, здоровье, полоса опыта, иконки способностей с уровнями и кулдаунами,
	счётчик убийств. Интерактивных элементов нет: в бою игрок только двигается.

	Снимок приходит 10 раз в секунду, а кулдауны между снимками отсчитываются
	локально — иначе иконки дёргались бы рывками.

	Вёрстка под телефон: позиции в долях экрана, инсет статус-бара учитывается
	автоматически (IgnoreGuiInset не выставлен), иконки не меньше 44 пикселей.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Abilities = require(Shared.Config.Abilities)
local Net = require(Shared.Net)
local Palette = require(Shared.Config.Palette)
local Types = require(Shared.Types)

local ICON_SIZE = 48
local ICON_GAP = 6

local HudController = {}

local player = Players.LocalPlayer

local screen: ScreenGui? = nil
local xpFill: Frame? = nil
local levelLabel: TextLabel? = nil
local timerLabel: TextLabel? = nil
local killsLabel: TextLabel? = nil
local healthFill: Frame? = nil
local healthLabel: TextLabel? = nil
local iconRow: Frame? = nil

type Icon = {
	holder: Frame,
	cooldownFill: Frame,
	levelLabel: TextLabel,
	nameLabel: TextLabel,
}
local icons: { [string]: Icon } = {}

local snapshot: Types.RunSnapshot? = nil
local healthConnection: RBXScriptConnection? = nil

local function makeBar(parent: Instance, name: string, color: Color3): (Frame, Frame)
	local track = Instance.new("Frame")
	track.Name = name
	track.BackgroundColor3 = Palette.UI.panel
	track.BackgroundTransparency = 0.25
	track.BorderSizePixel = 0
	track.Parent = parent

	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 4)
	corner.Parent = track

	local fill = Instance.new("Frame")
	fill.Name = "Fill"
	fill.Size = UDim2.fromScale(0, 1)
	fill.BackgroundColor3 = color
	fill.BorderSizePixel = 0
	fill.Parent = track

	local fillCorner = Instance.new("UICorner")
	fillCorner.CornerRadius = UDim.new(0, 4)
	fillCorner.Parent = fill

	return track, fill
end

local function makeLabel(parent: Instance, name: string, size: number): TextLabel
	local label = Instance.new("TextLabel")
	label.Name = name
	label.BackgroundTransparency = 1
	label.Font = Enum.Font.GothamBold
	label.Text = ""
	label.TextColor3 = Palette.UI.text
	label.TextSize = size
	label.TextStrokeColor3 = Palette.UI.background
	label.TextStrokeTransparency = 0.4
	label.Parent = parent
	return label
end

local function build(): ()
	local playerGui = player:WaitForChild("PlayerGui")

	local gui = Instance.new("ScreenGui")
	gui.Name = "CombatHud"
	gui.ResetOnSpawn = false
	gui.DisplayOrder = 200
	gui.Enabled = false
	gui.Parent = playerGui
	screen = gui

	-- Полоса опыта во всю ширину сверху.
	local xpTrack, fill = makeBar(gui, "XpBar", Palette.UI.accent)
	xpTrack.Position = UDim2.fromScale(0, 0)
	xpTrack.Size = UDim2.new(1, 0, 0, 10)
	xpFill = fill

	local level = makeLabel(gui, "Level", 16)
	level.Position = UDim2.fromOffset(10, 12)
	level.Size = UDim2.fromOffset(120, 20)
	level.TextXAlignment = Enum.TextXAlignment.Left
	levelLabel = level

	local timer = makeLabel(gui, "Timer", 26)
	timer.AnchorPoint = Vector2.new(0.5, 0)
	timer.Position = UDim2.new(0.5, 0, 0, 12)
	timer.Size = UDim2.fromOffset(140, 30)
	timerLabel = timer

	local kills = makeLabel(gui, "Kills", 16)
	kills.AnchorPoint = Vector2.new(1, 0)
	kills.Position = UDim2.new(1, -10, 0, 12)
	kills.Size = UDim2.fromOffset(140, 20)
	kills.TextXAlignment = Enum.TextXAlignment.Right
	killsLabel = kills

	-- Здоровье снизу по центру: под большим пальцем ничего важного нет.
	local healthTrack, healthBar = makeBar(gui, "HealthBar", Palette.UI.danger)
	healthTrack.AnchorPoint = Vector2.new(0.5, 1)
	healthTrack.Position = UDim2.new(0.5, 0, 1, -14)
	healthTrack.Size = UDim2.new(0.34, 0, 0, 14)
	healthFill = healthBar

	local health = makeLabel(gui, "HealthText", 13)
	health.AnchorPoint = Vector2.new(0.5, 1)
	health.Position = UDim2.new(0.5, 0, 1, -30)
	health.Size = UDim2.fromOffset(140, 18)
	healthLabel = health

	-- Ряд иконок способностей над полосой здоровья.
	local row = Instance.new("Frame")
	row.Name = "Abilities"
	row.AnchorPoint = Vector2.new(0.5, 1)
	row.Position = UDim2.new(0.5, 0, 1, -52)
	row.Size = UDim2.fromOffset(0, ICON_SIZE)
	row.AutomaticSize = Enum.AutomaticSize.X
	row.BackgroundTransparency = 1
	row.Parent = gui
	iconRow = row

	local layout = Instance.new("UIListLayout")
	layout.FillDirection = Enum.FillDirection.Horizontal
	layout.HorizontalAlignment = Enum.HorizontalAlignment.Center
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Padding = UDim.new(0, ICON_GAP)
	layout.Parent = row
end

local function getIcon(key: string, order: number): Icon
	local existing = icons[key]
	if existing then
		existing.holder.LayoutOrder = order
		return existing
	end

	local def = Abilities.ByKey[key]
	local color = if def then Palette.Element[def.element] else Palette.UI.accent

	local holder = Instance.new("Frame")
	holder.Name = key
	holder.Size = UDim2.fromOffset(ICON_SIZE, ICON_SIZE)
	holder.BackgroundColor3 = color
	holder.BorderSizePixel = 0
	holder.LayoutOrder = order
	holder.Parent = iconRow

	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 8)
	corner.Parent = holder

	-- Кулдаун закрашивает иконку снизу вверх.
	local cooldown = Instance.new("Frame")
	cooldown.Name = "Cooldown"
	cooldown.AnchorPoint = Vector2.new(0, 1)
	cooldown.Position = UDim2.fromScale(0, 1)
	cooldown.Size = UDim2.fromScale(1, 0)
	cooldown.BackgroundColor3 = Palette.UI.background
	cooldown.BackgroundTransparency = 0.45
	cooldown.BorderSizePixel = 0
	cooldown.Parent = holder

	local name = Instance.new("TextLabel")
	name.Name = "Short"
	name.Size = UDim2.fromScale(1, 0.6)
	name.BackgroundTransparency = 1
	name.Font = Enum.Font.GothamBold
	name.Text = if def then string.sub(def.displayName, 1, 2) else "?"
	name.TextColor3 = Palette.UI.background
	name.TextScaled = true
	name.Parent = holder

	local levelText = Instance.new("TextLabel")
	levelText.Name = "Level"
	levelText.AnchorPoint = Vector2.new(1, 1)
	levelText.Position = UDim2.fromScale(1, 1)
	levelText.Size = UDim2.fromOffset(18, 16)
	levelText.BackgroundTransparency = 1
	levelText.Font = Enum.Font.GothamBold
	levelText.Text = "1"
	levelText.TextColor3 = Palette.UI.text
	levelText.TextSize = 14
	levelText.TextStrokeColor3 = Palette.UI.background
	levelText.TextStrokeTransparency = 0.2
	levelText.Parent = holder

	local icon: Icon = { holder = holder, cooldownFill = cooldown, levelLabel = levelText, nameLabel = name }
	icons[key] = icon
	return icon
end

local function updateHealth(): ()
	local fill = healthFill
	local label = healthLabel
	if not fill or not label then
		return
	end

	local character = player.Character
	local humanoid = if character then character:FindFirstChildOfClass("Humanoid") else nil
	if not humanoid or humanoid.MaxHealth <= 0 then
		return
	end

	local ratio = math.clamp(humanoid.Health / humanoid.MaxHealth, 0, 1)
	fill.Size = UDim2.fromScale(ratio, 1)
	label.Text = `{math.ceil(humanoid.Health)} / {math.floor(humanoid.MaxHealth)}`
end

local function onHeartbeat(deltaTime: number): ()
	local gui = screen
	local current = snapshot
	if not gui or not gui.Enabled or not current then
		return
	end

	local timer = timerLabel
	if timer then
		local total = math.max(current.time, 0)
		timer.Text = string.format("%02d:%02d", math.floor(total / 60), math.floor(total % 60))
	end

	local kills = killsLabel
	if kills then
		kills.Text = `kills {current.kills}`
	end

	local level = levelLabel
	if level then
		level.Text = `Lv {current.level}`
	end

	local fill = xpFill
	if fill then
		local ratio = if current.xpToNext > 0 then math.clamp(current.xp / current.xpToNext, 0, 1) else 0
		fill.Size = UDim2.fromScale(ratio, 1)
	end

	local seen: { [string]: boolean } = {}
	for index, view in current.abilities do
		seen[view.key] = true
		local icon = getIcon(view.key, index)

		-- Между снимками кулдаун отсчитываем сами.
		view.cooldown = math.max(view.cooldown - deltaTime, 0)
		local ratio = if view.maxCooldown > 0 then math.clamp(view.cooldown / view.maxCooldown, 0, 1) else 0

		icon.cooldownFill.Size = UDim2.fromScale(1, ratio)
		icon.levelLabel.Text = tostring(view.level)
	end

	for key, icon in icons do
		if not seen[key] then
			icon.holder:Destroy()
			icons[key] = nil
		end
	end

	updateHealth()
end

local function setVisible(visible: boolean): ()
	local gui = screen
	if gui then
		gui.Enabled = visible
	end

	if not visible then
		snapshot = nil
		for key, icon in icons do
			icon.holder:Destroy()
			icons[key] = nil
		end
	end
end

function HudController.Start(): ()
	build()

	Net.GetEvent(Net.Id.RunStarted).OnClientEvent:Connect(function()
		setVisible(true)
	end)

	Net.GetEvent(Net.Id.RunEnded).OnClientEvent:Connect(function()
		setVisible(false)
	end)

	Net.GetUnreliable(Net.Id.RunSnapshot).OnClientEvent:Connect(function(value: Types.RunSnapshot)
		snapshot = value
	end)

	-- Полоса здоровья обновляется и по событию, и в цикле: событие даёт
	-- мгновенную реакцию на удар, цикл — корректность после респавна.
	local function bindHealth(character: Model)
		local existing = healthConnection
		if existing then
			existing:Disconnect()
		end

		local humanoid = character:WaitForChild("Humanoid", 10) :: Humanoid?
		if humanoid then
			healthConnection = humanoid.HealthChanged:Connect(updateHealth)
			updateHealth()
		end
	end

	player.CharacterAdded:Connect(bindHealth)
	if player.Character then
		task.spawn(bindHealth, player.Character)
	end

	RunService.Heartbeat:Connect(onHeartbeat)
end

return HudController
