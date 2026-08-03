--!strict
--[[
	LevelUpController — экран выбора при левел-апе (раздел 3.6 и 8 ТЗ).

	Это единственный момент, когда игрок в бою что-то решает, и единственное
	место во всём клиенте, которое что-то отправляет на сервер. Отправляется
	только номер карточки: сервер сам знает, какие три он предложил, и берёт
	эффект из своей копии, а не из присланных данных.

	Бой на это время стоит на паузе — её ставит сервер, клиент лишь показывает
	карточки. Даже если игрок ничего не нажмёт, сервер через таймаут выберет
	первую и снимет паузу: зависшая арена недопустима.

	Карточки крупные и разнесены: попадание пальцем важнее плотности.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Abilities = require(Shared.Config.Abilities)
local Net = require(Shared.Net)
local Palette = require(Shared.Config.Palette)
local Types = require(Shared.Types)

type LevelUpCard = Types.LevelUpCard

local LevelUpController = {}

local player = Players.LocalPlayer

local screen: ScreenGui? = nil
local cardRow: Frame? = nil
local titleLabel: TextLabel? = nil
local choiceRemote: RemoteEvent? = nil
local awaitingChoice = false

local function build(): ()
	local playerGui = player:WaitForChild("PlayerGui")

	local gui = Instance.new("ScreenGui")
	gui.Name = "LevelUp"
	gui.ResetOnSpawn = false
	gui.DisplayOrder = 400
	gui.IgnoreGuiInset = true
	gui.Enabled = false
	gui.Parent = playerGui
	screen = gui

	local backdrop = Instance.new("Frame")
	backdrop.Name = "Backdrop"
	backdrop.Size = UDim2.fromScale(1, 1)
	backdrop.BackgroundColor3 = Palette.UI.background
	backdrop.BackgroundTransparency = 0.35
	backdrop.BorderSizePixel = 0
	backdrop.Parent = gui

	local title = Instance.new("TextLabel")
	title.Name = "Title"
	title.AnchorPoint = Vector2.new(0.5, 0)
	title.Position = UDim2.fromScale(0.5, 0.08)
	title.Size = UDim2.fromScale(0.8, 0.09)
	title.BackgroundTransparency = 1
	title.Font = Enum.Font.GothamBold
	title.Text = "LEVEL UP"
	title.TextColor3 = Palette.UI.text
	title.TextScaled = true
	title.Parent = backdrop
	titleLabel = title

	local row = Instance.new("Frame")
	row.Name = "Cards"
	row.AnchorPoint = Vector2.new(0.5, 0.5)
	row.Position = UDim2.fromScale(0.5, 0.55)
	row.Size = UDim2.fromScale(0.92, 0.6)
	row.BackgroundTransparency = 1
	row.Parent = backdrop
	cardRow = row

	local layout = Instance.new("UIListLayout")
	layout.FillDirection = Enum.FillDirection.Horizontal
	layout.HorizontalAlignment = Enum.HorizontalAlignment.Center
	layout.VerticalAlignment = Enum.VerticalAlignment.Center
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Padding = UDim.new(0.02, 0)
	layout.Parent = row
end

local function hide(): ()
	awaitingChoice = false

	local gui = screen
	if gui then
		gui.Enabled = false
	end

	local row = cardRow
	if row then
		for _, child in row:GetChildren() do
			if child:IsA("TextButton") then
				child:Destroy()
			end
		end
	end
end

local function choose(index: number): ()
	if not awaitingChoice then
		return
	end
	awaitingChoice = false

	local remote = choiceRemote
	if remote then
		remote:FireServer(index)
	end

	hide()
end

local function buildCard(card: LevelUpCard, index: number, total: number): ()
	local row = cardRow
	if not row then
		return
	end

	local def = Abilities.ByKey[card.abilityKey]
	local color = if def then Palette.Element[def.element] else Palette.UI.accent

	local button = Instance.new("TextButton")
	button.Name = `Card{index}`
	button.LayoutOrder = index
	button.Size = UDim2.fromScale(0.94 / total, 1)
	button.BackgroundColor3 = Palette.UI.panel
	button.BorderSizePixel = 0
	button.AutoButtonColor = true
	button.Text = ""
	button.Parent = row

	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 12)
	corner.Parent = button

	local stroke = Instance.new("UIStroke")
	stroke.Color = color
	stroke.Thickness = 3
	stroke.Parent = button

	local header = Instance.new("Frame")
	header.Size = UDim2.fromScale(1, 0.22)
	header.BackgroundColor3 = color
	header.BorderSizePixel = 0
	header.Parent = button

	local headerCorner = Instance.new("UICorner")
	headerCorner.CornerRadius = UDim.new(0, 12)
	headerCorner.Parent = header

	local badge = Instance.new("TextLabel")
	badge.Size = UDim2.fromScale(1, 1)
	badge.BackgroundTransparency = 1
	badge.Font = Enum.Font.GothamBold
	badge.Text = if card.isNew then "NEW" else `LEVEL {card.level}`
	badge.TextColor3 = Palette.UI.background
	badge.TextScaled = true
	badge.Parent = header

	local badgePadding = Instance.new("UIPadding")
	badgePadding.PaddingTop = UDim.new(0, 6)
	badgePadding.PaddingBottom = UDim.new(0, 6)
	badgePadding.Parent = badge

	local name = Instance.new("TextLabel")
	name.AnchorPoint = Vector2.new(0.5, 0)
	name.Position = UDim2.fromScale(0.5, 0.3)
	name.Size = UDim2.fromScale(0.86, 0.2)
	name.BackgroundTransparency = 1
	name.Font = Enum.Font.GothamBold
	name.Text = if def then def.displayName else card.abilityKey
	name.TextColor3 = Palette.UI.text
	name.TextScaled = true
	name.Parent = button

	local description = Instance.new("TextLabel")
	description.AnchorPoint = Vector2.new(0.5, 0)
	description.Position = UDim2.fromScale(0.5, 0.54)
	description.Size = UDim2.fromScale(0.86, 0.34)
	description.BackgroundTransparency = 1
	description.Font = Enum.Font.Gotham
	description.Text = if def then def.description else ""
	description.TextColor3 = Palette.UI.subtext
	description.TextWrapped = true
	description.TextScaled = true
	description.Parent = button

	button.Activated:Connect(function()
		choose(index)
	end)
end

local function show(level: number, cards: { LevelUpCard }): ()
	local gui = screen
	local row = cardRow
	local title = titleLabel
	if not gui or not row then
		return
	end

	hide()

	if title then
		title.Text = `LEVEL {level}`
	end

	for index, card in cards do
		buildCard(card, index, #cards)
	end

	awaitingChoice = true
	gui.Enabled = true
end

function LevelUpController.Start(): ()
	build()
	choiceRemote = Net.GetEvent(Net.Id.LevelUpChoice)

	Net.GetEvent(Net.Id.LevelUpOffer).OnClientEvent:Connect(function(level: number, cards: { LevelUpCard })
		show(level, cards)
	end)

	-- Сервер снял паузу сам (таймаут или выбор применён) — экран убираем.
	Net.GetEvent(Net.Id.CombatPaused).OnClientEvent:Connect(function(paused: boolean)
		if not paused then
			hide()
		end
	end)

	Net.GetEvent(Net.Id.RunEnded).OnClientEvent:Connect(hide)
end

return LevelUpController
