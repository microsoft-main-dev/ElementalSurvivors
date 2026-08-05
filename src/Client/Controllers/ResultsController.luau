--!strict
--[[
	ResultsController — экран результатов забега (раздел 8 ТЗ).

	Все цифры приходят готовыми с сервера: клиент ничего не считает и никуда
	ничего не отправляет — кнопка просто закрывает панель. Награда к этому
	моменту уже начислена и сохранена, экран лишь показывает, что произошло.

	Появляется он поверх лобби, куда игрока уже вернули: держать арену живой
	ради панели значило бы занимать слот, которого может не хватить другому.

	Вёрстка под телефон: панель в долях экрана, список урона прокручивается,
	кнопка крупная и стоит внизу, где до неё дотягивается большой палец.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Abilities = require(Shared.Config.Abilities)
local Net = require(Shared.Net)
local Palette = require(Shared.Config.Palette)
local Types = require(Shared.Types)

local ROW_HEIGHT = 34
local BUTTON_HEIGHT = 52 -- не меньше 44 пикселей (раздел 2 ТЗ)

local ResultsController = {}

local player = Players.LocalPlayer

local screen: ScreenGui? = nil
local titleLabel: TextLabel? = nil
local summaryLabel: TextLabel? = nil
local rewardLabel: TextLabel? = nil
local metaLabel: TextLabel? = nil
local bestBadge: TextLabel? = nil
local damageList: ScrollingFrame? = nil

local function formatTime(seconds: number): string
	local total = math.max(math.floor(seconds), 0)
	return string.format("%d:%02d", total // 60, total % 60)
end

local function hide(): ()
	local gui = screen
	if gui then
		gui.Enabled = false
	end
end

local function makeLabel(parent: Instance, font: Enum.Font, color: Color3): TextLabel
	local label = Instance.new("TextLabel")
	label.BackgroundTransparency = 1
	label.Font = font
	label.Text = ""
	label.TextColor3 = color
	label.TextScaled = true
	label.Parent = parent
	return label
end

local function build(): ()
	local playerGui = player:WaitForChild("PlayerGui")

	local gui = Instance.new("ScreenGui")
	gui.Name = "Results"
	gui.ResetOnSpawn = false
	gui.DisplayOrder = 500 -- выше левел-апа: забег уже кончился
	gui.IgnoreGuiInset = true
	gui.Enabled = false
	gui.Parent = playerGui
	screen = gui

	local backdrop = Instance.new("Frame")
	backdrop.Name = "Backdrop"
	backdrop.Size = UDim2.fromScale(1, 1)
	backdrop.BackgroundColor3 = Palette.UI.background
	backdrop.BackgroundTransparency = 0.25
	backdrop.BorderSizePixel = 0
	--[[
		Ввод дальше не идёт. Экран результатов появляется, когда панель лобби
		уже вернулась на место, и без этого её кнопки нажимались бы прямо
		сквозь него: неинтерактивный фрейм Roblox клики не задерживает.
		Закрытия по клику мимо здесь нет намеренно — экран закрывают кнопкой.
	]]
	backdrop.Active = true
	backdrop.Parent = gui

	local panel = Instance.new("Frame")
	panel.Name = "Panel"
	panel.AnchorPoint = Vector2.new(0.5, 0.5)
	panel.Position = UDim2.fromScale(0.5, 0.5)
	panel.Size = UDim2.fromScale(0.86, 0.84)
	panel.BackgroundColor3 = Palette.UI.panel
	panel.BorderSizePixel = 0
	panel.Parent = backdrop

	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 14)
	corner.Parent = panel

	local stroke = Instance.new("UIStroke")
	stroke.Color = Palette.UI.accent
	stroke.Thickness = 2
	stroke.Parent = panel

	local title = makeLabel(panel, Enum.Font.GothamBold, Palette.UI.text)
	title.Name = "Title"
	title.AnchorPoint = Vector2.new(0.5, 0)
	title.Position = UDim2.fromScale(0.5, 0.04)
	title.Size = UDim2.fromScale(0.9, 0.09)
	titleLabel = title

	-- Время, убийства и уровень одной строкой: три коротких числа читаются
	-- быстрее, чем три подписанные строки друг под другом.
	local summary = makeLabel(panel, Enum.Font.Gotham, Palette.UI.subtext)
	summary.Name = "Summary"
	summary.AnchorPoint = Vector2.new(0.5, 0)
	summary.Position = UDim2.fromScale(0.5, 0.145)
	summary.Size = UDim2.fromScale(0.9, 0.06)
	summaryLabel = summary

	local damageTitle = makeLabel(panel, Enum.Font.GothamBold, Palette.UI.subtext)
	damageTitle.Name = "DamageTitle"
	damageTitle.AnchorPoint = Vector2.new(0.5, 0)
	damageTitle.Position = UDim2.fromScale(0.5, 0.225)
	damageTitle.Size = UDim2.fromScale(0.9, 0.045)
	damageTitle.Text = "DAMAGE BY ABILITY"
	damageTitle.TextXAlignment = Enum.TextXAlignment.Left

	local list = Instance.new("ScrollingFrame")
	list.Name = "Damage"
	list.AnchorPoint = Vector2.new(0.5, 0)
	list.Position = UDim2.fromScale(0.5, 0.28)
	list.Size = UDim2.fromScale(0.9, 0.38)
	list.BackgroundTransparency = 1
	list.BorderSizePixel = 0
	list.ScrollBarThickness = 4
	list.ScrollBarImageColor3 = Palette.UI.accent
	list.CanvasSize = UDim2.new()
	list.AutomaticCanvasSize = Enum.AutomaticSize.Y
	list.Parent = panel
	damageList = list

	local layout = Instance.new("UIListLayout")
	layout.FillDirection = Enum.FillDirection.Vertical
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Padding = UDim.new(0, 4)
	layout.Parent = list

	local reward = makeLabel(panel, Enum.Font.GothamBold, Palette.UI.accent)
	reward.Name = "Reward"
	reward.AnchorPoint = Vector2.new(0.5, 0)
	reward.Position = UDim2.fromScale(0.5, 0.69)
	reward.Size = UDim2.fromScale(0.9, 0.08)
	rewardLabel = reward

	--[[
		Мета-прогрессия (M5). Стоит отдельной строкой под наградой намеренно:
		валюта и опыт персонажа — разные вещи, и внутрибоевой уровень выше
		по экрану к опыту персонажа отношения не имеет вовсе.
	]]
	local meta = makeLabel(panel, Enum.Font.Gotham, Palette.UI.subtext)
	meta.Name = "Meta"
	meta.AnchorPoint = Vector2.new(0.5, 0)
	meta.Position = UDim2.fromScale(0.5, 0.775)
	meta.Size = UDim2.fromScale(0.9, 0.05)
	metaLabel = meta

	local badge = makeLabel(panel, Enum.Font.GothamBold, Palette.Element.Lightning)
	badge.Name = "BestBadge"
	badge.AnchorPoint = Vector2.new(0.5, 0)
	badge.Position = UDim2.fromScale(0.5, 0.83)
	badge.Size = UDim2.fromScale(0.9, 0.05)
	badge.Text = "NEW BEST TIME"
	badge.Visible = false
	bestBadge = badge

	local button = Instance.new("TextButton")
	button.Name = "Continue"
	button.AnchorPoint = Vector2.new(0.5, 1)
	button.Position = UDim2.fromScale(0.5, 0.95)
	button.Size = UDim2.new(0.6, 0, 0, BUTTON_HEIGHT)
	button.BackgroundColor3 = Palette.UI.accent
	button.BorderSizePixel = 0
	button.AutoButtonColor = true
	button.Font = Enum.Font.GothamBold
	button.Text = "CONTINUE"
	button.TextColor3 = Palette.UI.background
	button.TextSize = 20
	button.Parent = panel

	local buttonCorner = Instance.new("UICorner")
	buttonCorner.CornerRadius = UDim.new(0, 10)
	buttonCorner.Parent = button

	button.Activated:Connect(hide)
end

local function buildDamageRow(view: Types.AbilityView, order: number, maxDamage: number): ()
	local list = damageList
	if not list then
		return
	end

	local def = Abilities.ByKey[view.key]
	local color = if def then Palette.Element[def.element] else Palette.UI.accent

	local row = Instance.new("Frame")
	row.Name = view.key
	row.LayoutOrder = order
	row.Size = UDim2.new(1, 0, 0, ROW_HEIGHT)
	row.BackgroundTransparency = 1
	row.Parent = list

	--[[
		Полоса под строкой — доля от лучшей способности. Сравнивать числа
		глазами тяжело, а длину полос — нет; ради этого экран и нужен.
	]]
	local bar = Instance.new("Frame")
	bar.Name = "Bar"
	bar.AnchorPoint = Vector2.new(0, 1)
	bar.Position = UDim2.fromScale(0, 1)
	bar.Size = UDim2.new(if maxDamage > 0 then view.damage / maxDamage else 0, 0, 0, 3)
	bar.BackgroundColor3 = color
	bar.BorderSizePixel = 0
	bar.Parent = row

	local name = makeLabel(row, Enum.Font.Gotham, Palette.UI.text)
	name.Size = UDim2.fromScale(0.7, 0.75)
	name.TextXAlignment = Enum.TextXAlignment.Left
	name.TextScaled = false
	name.TextSize = 16
	name.Text = `{if def then def.displayName else view.key}  ·  Lv {view.level}`

	local value = makeLabel(row, Enum.Font.GothamBold, color)
	value.AnchorPoint = Vector2.new(1, 0)
	value.Position = UDim2.fromScale(1, 0)
	value.Size = UDim2.fromScale(0.3, 0.75)
	value.TextXAlignment = Enum.TextXAlignment.Right
	value.TextScaled = false
	value.TextSize = 16
	value.Text = tostring(math.floor(view.damage))
end

local function show(result: Types.RunResult): ()
	local gui = screen
	local list = damageList
	if not gui or not list then
		return
	end

	for _, child in list:GetChildren() do
		if child:IsA("Frame") then
			child:Destroy()
		end
	end

	local title = titleLabel
	if title then
		if result.victory then
			title.Text = "STAGE CLEARED"
			title.TextColor3 = Palette.Element.Nature
		elseif result.reason == "Death" then
			title.Text = "YOU DIED"
			title.TextColor3 = Palette.UI.danger
		else
			title.Text = "RUN ENDED"
			title.TextColor3 = Palette.UI.text
		end
	end

	local summary = summaryLabel
	if summary then
		-- В сюжетном режиме номер уровня важнее внутрибоевого уровня:
		-- он говорит, где игрок находится в прогрессе, а не в этом забеге.
		local prefix = if result.mode == "Story" then `Stage {result.stageIndex}   ·   ` else ""
		summary.Text = `{prefix}Time {formatTime(result.time)}   ·   Kills {result.kills}   ·   Level {result.level}`
	end

	-- Сортировка по урону: первым идёт то, что реально несло забег.
	local sorted = table.clone(result.abilities)
	table.sort(sorted, function(a: Types.AbilityView, b: Types.AbilityView): boolean
		return a.damage > b.damage
	end)

	local maxDamage = if #sorted > 0 then sorted[1].damage else 0
	for order, view in sorted do
		buildDamageRow(view, order, maxDamage)
	end

	local reward = rewardLabel
	if reward then
		--[[
			Множитель называется вслух (M7). Без него человек, купивший x10,
			видит просто большое число и не знает, сработала покупка или ему
			повезло с картами: сама сумма за забег и так скачет вдвое.
		]]
		local boost = if result.essenceMult > 1 then `   ·   x{result.essenceMult} boost` else ""
		reward.Text = `+{result.essence} Essence   (total {result.currency.essence}){boost}`
	end

	local meta = metaLabel
	if meta then
		local text = `+{result.xp} XP   ·   Character level {result.metaLevel}`
		if result.levelsGained > 0 then
			-- Очко таланта — единственное, ради чего опыт вообще нужен,
			-- поэтому о нём сказано прямо, а не оставлено на догадку.
			local points = if result.levelsGained == 1 then "point" else "points"
			text ..= `   ·   +{result.levelsGained} talent {points}`
		end

		-- Выпавшая экипировка (M6). Перечисляется поимённо: «+1 предмет»
		-- заставляет лезть в инвентарь, чтобы узнать, что именно дали.
		if #result.items > 0 then
			local names: { string } = {}
			for _, item in result.items do
				table.insert(names, `{item.rarity} {item.slot}`)
			end
			text ..= `   ·   {table.concat(names, ", ")}`
		end

		meta.Text = text
	end

	local badge = bestBadge
	if badge then
		badge.Visible = result.newBest
	end

	gui.Enabled = true
end

function ResultsController.Start(): ()
	build()

	Net.GetEvent(Net.Id.RunResult).OnClientEvent:Connect(function(result: Types.RunResult)
		show(result)
	end)

	-- Новый забег начался — старые итоги на экране висеть не должны.
	Net.GetEvent(Net.Id.RunStarted).OnClientEvent:Connect(hide)
end

return ResultsController
