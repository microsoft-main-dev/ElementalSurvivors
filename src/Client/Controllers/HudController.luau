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
local BossRenderController = require(script.Parent.BossRenderController)
local Net = require(Shared.Net)
local Palette = require(Shared.Config.Palette)
local SettingsController = require(script.Parent.SettingsController)
local Types = require(Shared.Types)
local UiKit = require(script.Parent.Parent.UI.UiKit)

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
local damagePanel: Frame? = nil

type DamageRow = {
	holder: Frame,
	nameLabel: TextLabel,
	valueLabel: TextLabel,
}
local damageRows: { [string]: DamageRow } = {}

type Icon = {
	holder: Frame,
	cooldownFill: Frame,
	levelLabel: TextLabel,
	nameLabel: TextLabel,
}
local icons: { [string]: Icon } = {}

local snapshot: Types.RunSnapshot? = nil
local healthConnection: RBXScriptConnection? = nil

-- Боссфайт (M6): полоса здоровья и подпись фазы.
local bossBar: Frame? = nil
local bossFill: Frame? = nil
local bossHealthLabel: TextLabel? = nil
local phaseLabel: TextLabel? = nil

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

	-- Полоса опыта: по центру сверху, не во всю ширину.
	local xpTrack, fill = makeBar(gui, "XpBar", Palette.UI.accent)
	xpTrack.AnchorPoint = Vector2.new(0.5, 0)
	xpTrack.Position = UDim2.new(0.5, 0, 0, 10)
	xpTrack.Size = UDim2.new(0.42, 0, 0, 14)
	xpFill = fill

	local level = makeLabel(xpTrack, "Level", 12)
	level.Size = UDim2.fromScale(1, 1)
	level.ZIndex = 2
	levelLabel = level

	local timer = makeLabel(gui, "Timer", 26)
	timer.AnchorPoint = Vector2.new(0.5, 0)
	timer.Position = UDim2.new(0.5, 0, 0, 30)
	timer.Size = UDim2.fromOffset(140, 30)
	timerLabel = timer

	--[[
		Полоса здоровья босса и подпись фазы (M6). Висят под таймером
		и появляются только тогда, когда есть о чём говорить: пустая полоса
		весь забег занимала бы место и приучала на неё не смотреть.
	]]
	local bossTrack, bossFillFrame = makeBar(gui, "BossHealth", Palette.UI.danger)
	bossTrack.AnchorPoint = Vector2.new(0.5, 0)
	bossTrack.Position = UDim2.new(0.5, 0, 0, 62)
	bossTrack.Size = UDim2.new(0.5, 0, 0, 12)
	bossTrack.Visible = false
	bossBar = bossTrack
	bossFill = bossFillFrame

	-- Числа поверх полосы: доля показывает, что дело идёт, а число — сколько
	-- ещё бить. На боссе с двадцатью семью тысячами здоровья это разные вопросы.
	local bossText = makeLabel(bossTrack, "BossHealthText", 11)
	bossText.Size = UDim2.fromScale(1, 1)
	bossText.ZIndex = 2
	bossHealthLabel = bossText

	local phase = makeLabel(gui, "Phase", 15)
	phase.AnchorPoint = Vector2.new(0.5, 0)
	phase.Position = UDim2.new(0.5, 0, 0, 78)
	phase.Size = UDim2.fromOffset(320, 20)
	phase.TextColor3 = Palette.UI.subtext
	phase.Visible = false
	phaseLabel = phase

	local kills = makeLabel(gui, "Kills", 16)
	kills.AnchorPoint = Vector2.new(1, 0)
	kills.Position = UDim2.new(1, -10, 0, 10)
	kills.Size = UDim2.fromOffset(140, 20)
	kills.TextXAlignment = Enum.TextXAlignment.Right
	killsLabel = kills

	--[[
		Панель урона по способностям. Нужна была для проверки M2, но остаётся
		насовсем: тот же список с сортировкой требует экран результатов
		в разделе 8 ТЗ, и считается он из тех же чисел.
	]]
	local damage = Instance.new("Frame")
	damage.Name = "DamageMeter"
	damage.AnchorPoint = Vector2.new(1, 0)
	damage.Position = UDim2.new(1, -10, 0, 34)
	-- Шире прежнего: в строке теперь два числа, урон и DPS.
	damage.Size = UDim2.fromOffset(230, 0)
	damage.AutomaticSize = Enum.AutomaticSize.Y
	damage.BackgroundColor3 = Palette.UI.panel
	damage.BackgroundTransparency = 0.35
	damage.BorderSizePixel = 0
	damage.Parent = gui
	damagePanel = damage

	local damageCorner = Instance.new("UICorner")
	damageCorner.CornerRadius = UDim.new(0, 6)
	damageCorner.Parent = damage

	local damagePadding = Instance.new("UIPadding")
	damagePadding.PaddingTop = UDim.new(0, 5)
	damagePadding.PaddingBottom = UDim.new(0, 5)
	damagePadding.PaddingLeft = UDim.new(0, 8)
	damagePadding.PaddingRight = UDim.new(0, 8)
	damagePadding.Parent = damage

	local damageLayout = Instance.new("UIListLayout")
	damageLayout.FillDirection = Enum.FillDirection.Vertical
	damageLayout.SortOrder = Enum.SortOrder.LayoutOrder
	damageLayout.Padding = UDim.new(0, 2)
	damageLayout.Parent = damage

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

local function getDamageRow(key: string): DamageRow
	local existing = damageRows[key]
	if existing then
		return existing
	end

	local def = Abilities.ByKey[key]
	local color = if def then Palette.Element[def.element] else Palette.UI.accent

	local holder = Instance.new("Frame")
	holder.Name = key
	holder.Size = UDim2.new(1, 0, 0, 16)
	holder.BackgroundTransparency = 1
	holder.Parent = damagePanel

	local nameLabel = Instance.new("TextLabel")
	nameLabel.Size = UDim2.fromScale(0.5, 1)
	nameLabel.BackgroundTransparency = 1
	nameLabel.Font = Enum.Font.Gotham
	nameLabel.Text = if def then def.displayName else key
	nameLabel.TextColor3 = color
	nameLabel.TextSize = 13
	nameLabel.TextXAlignment = Enum.TextXAlignment.Left
	nameLabel.TextTruncate = Enum.TextTruncate.AtEnd
	nameLabel.Parent = holder

	local valueLabel = Instance.new("TextLabel")
	valueLabel.AnchorPoint = Vector2.new(1, 0)
	valueLabel.Position = UDim2.fromScale(1, 0)
	valueLabel.Size = UDim2.fromScale(0.5, 1)
	valueLabel.BackgroundTransparency = 1
	valueLabel.Font = Enum.Font.Code
	valueLabel.Text = "0"
	valueLabel.TextColor3 = Palette.UI.text
	valueLabel.TextSize = 13
	valueLabel.TextXAlignment = Enum.TextXAlignment.Right
	valueLabel.Parent = holder

	local row: DamageRow = { holder = holder, nameLabel = nameLabel, valueLabel = valueLabel }
	damageRows[key] = row
	return row
end

--[[
	Список урона по способностям, отсортированный по убыванию.

	Рядом с суммарным уроном — DPS. Сумма отвечает на вопрос «что несло забег»,
	DPS — «что несёт его сейчас»: способность, взятая на восьмой минуте, по сумме
	всегда проигрывает стартовой, даже если бьёт вдвое сильнее. Считается от
	времени забега, а не от времени владения способностью: серверу такое время
	никто не считает, а гадать о нём на клиенте — значит показывать неправду.
]]
local function updateDamageMeter(abilities: { Types.AbilityView }, elapsed: number): ()
	local sorted = table.clone(abilities)
	table.sort(sorted, function(a: Types.AbilityView, b: Types.AbilityView): boolean
		return a.damage > b.damage
	end)

	local seconds = math.max(elapsed, 1)

	local seen: { [string]: boolean } = {}
	for order, view in sorted do
		seen[view.key] = true
		local row = getDamageRow(view.key)
		row.holder.LayoutOrder = order
		row.valueLabel.Text = string.format("%d  %d/s", view.damage, view.damage / seconds)
	end

	for key, row in damageRows do
		if not seen[key] then
			row.holder:Destroy()
			damageRows[key] = nil
		end
	end
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

--[[
	Полоса босса. Доля здоровья берётся у BossRenderController — он и так
	получает состояние босса десять раз в секунду, и второй канал ради
	одной цифры был бы лишним.
]]
local function updateBoss(): ()
	local bar = bossBar
	local fill = bossFill
	if not bar or not fill then
		return
	end

	local active = BossRenderController.IsActive()
	bar.Visible = active
	if not active then
		return
	end

	fill.Size = UDim2.fromScale(BossRenderController.GetHealthFraction(), 1)

	local label = bossHealthLabel
	if label then
		local current, maximum = BossRenderController.GetHealth()
		label.Text = `{UiKit.FormatAmount(math.max(current, 0))} / {UiKit.FormatAmount(maximum)}`
	end
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

	updateDamageMeter(current.abilities, current.time)
	updateHealth()
	updateBoss()
end

local function setVisible(visible: boolean): ()
	local gui = screen
	if gui then
		gui.Enabled = visible
	end

	if not visible then
		snapshot = nil

		local bar = bossBar
		if bar then
			bar.Visible = false
		end
		local label = phaseLabel
		if label then
			label.Visible = false
		end

		for key, icon in icons do
			icon.holder:Destroy()
			icons[key] = nil
		end
		for key, row in damageRows do
			row.holder:Destroy()
			damageRows[key] = nil
		end
	end
end

function HudController.Start(): ()
	build()

	Net.GetEvent(Net.Id.RunStarted).OnClientEvent:Connect(function()
		setVisible(true)
		-- Настройка не меняется в бою (LobbyRequest заблокирован во время
		-- забега), поэтому решить достаточно один раз на старте.
		local panel = damagePanel
		if panel then
			panel.Visible = SettingsController.Get().showDamageMeter
		end
	end)

	Net.GetEvent(Net.Id.RunEnded).OnClientEvent:Connect(function()
		setVisible(false)
	end)

	Net.GetUnreliable(Net.Id.RunSnapshot).OnClientEvent:Connect(function(value: Types.RunSnapshot)
		snapshot = value
	end)

	--[[
		Подпись фазы сюжетного уровня (M6). Без неё момент, когда спавн
		прекратился и надо добить оставшихся, выглядит как «враги кончились
		и игра сломалась».
	]]
	Net.GetEvent(Net.Id.StagePhase).OnClientEvent:Connect(function(payload: { [string]: any })
		local label = phaseLabel
		if not label then
			return
		end

		local phase = payload.phase
		if phase == "Sweep" then
			label.Text = "Clear the field — the boss is waiting"
			label.Visible = true
		elseif phase == "Boss" then
			label.Text = "BOSS"
			label.Visible = true
		else
			label.Visible = false
		end
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
