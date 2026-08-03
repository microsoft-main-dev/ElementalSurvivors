--!strict
--[[
	CurrencyController — валюты в верхней части экрана лобби (раздел 8 ТЗ).

	Значения приходят только с сервера пакетом ProfileView и нигде на клиенте
	не пересчитываются: показанное число всегда равно тому, что лежит в профиле.

	На время боя панель прячется — в бою интерфейс занят HUD-ом забега,
	а тратить валюту всё равно негде.

	Prisms в M3 заработать нельзя (донат — M7), поэтому там честный ноль:
	показывать валюту всё равно надо, иначе игрок не знает, что она есть.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Net = require(Shared.Net)
local Palette = require(Shared.Config.Palette)
local Types = require(Shared.Types)

local PILL_HEIGHT = 32
local PILL_WIDTH = 116
local PILL_GAP = 6

local CurrencyController = {}

local player = Players.LocalPlayer

local screen: ScreenGui? = nil
local essenceLabel: TextLabel? = nil
local prismsLabel: TextLabel? = nil

-- 12345 -> "12 345": длинные числа без разделителя читаются как каша.
local function formatAmount(value: number): string
	local text = tostring(math.floor(value))
	local result = text
	local count: number

	repeat
		result, count = string.gsub(result, "^(-?%d+)(%d%d%d)", "%1 %2")
	until count == 0

	return result
end

local function makePill(parent: Instance, order: number, color: Color3): TextLabel
	local pill = Instance.new("Frame")
	pill.Name = `Pill{order}`
	pill.LayoutOrder = order
	pill.Size = UDim2.fromOffset(PILL_WIDTH, PILL_HEIGHT)
	pill.BackgroundColor3 = Palette.UI.panel
	pill.BackgroundTransparency = 0.15
	pill.BorderSizePixel = 0
	pill.Parent = parent

	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, PILL_HEIGHT // 2)
	corner.Parent = pill

	-- Валюту различает цвет кружка: иконок у нас нет и не будет до ассетов.
	local dot = Instance.new("Frame")
	dot.Name = "Dot"
	dot.AnchorPoint = Vector2.new(0, 0.5)
	dot.Position = UDim2.new(0, 8, 0.5, 0)
	dot.Size = UDim2.fromOffset(14, 14)
	dot.BackgroundColor3 = color
	dot.BorderSizePixel = 0
	dot.Parent = pill

	local dotCorner = Instance.new("UICorner")
	dotCorner.CornerRadius = UDim.new(0.5, 0)
	dotCorner.Parent = dot

	local label = Instance.new("TextLabel")
	label.Name = "Amount"
	label.AnchorPoint = Vector2.new(1, 0.5)
	label.Position = UDim2.new(1, -10, 0.5, 0)
	label.Size = UDim2.new(1, -32, 1, 0)
	label.BackgroundTransparency = 1
	label.Font = Enum.Font.GothamBold
	label.Text = "0"
	label.TextColor3 = Palette.UI.text
	label.TextSize = 16
	label.TextXAlignment = Enum.TextXAlignment.Right
	label.Parent = pill

	return label
end

local function build(): ()
	local playerGui = player:WaitForChild("PlayerGui")

	local gui = Instance.new("ScreenGui")
	gui.Name = "LobbyCurrency"
	gui.ResetOnSpawn = false
	gui.DisplayOrder = 200
	gui.Parent = playerGui
	screen = gui

	local holder = Instance.new("Frame")
	holder.Name = "Holder"
	holder.AnchorPoint = Vector2.new(1, 0)
	holder.Position = UDim2.new(1, -12, 0, 12)
	holder.Size = UDim2.fromOffset(PILL_WIDTH, PILL_HEIGHT * 2 + PILL_GAP)
	holder.BackgroundTransparency = 1
	holder.Parent = gui

	local layout = Instance.new("UIListLayout")
	layout.FillDirection = Enum.FillDirection.Vertical
	layout.HorizontalAlignment = Enum.HorizontalAlignment.Right
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Padding = UDim.new(0, PILL_GAP)
	layout.Parent = holder

	essenceLabel = makePill(holder, 1, Palette.UI.accent)
	prismsLabel = makePill(holder, 2, Palette.Element.Dark)
end

local function setVisible(visible: boolean): ()
	local gui = screen
	if gui then
		gui.Enabled = visible
	end
end

local function apply(view: Types.ProfileView): ()
	local essence = essenceLabel
	if essence then
		essence.Text = formatAmount(view.essence)
	end

	local prisms = prismsLabel
	if prisms then
		prisms.Text = formatAmount(view.prisms)
	end
end

function CurrencyController.Start(): ()
	build()

	Net.GetEvent(Net.Id.ProfileView).OnClientEvent:Connect(function(view: Types.ProfileView)
		apply(view)
	end)

	Net.GetEvent(Net.Id.RunStarted).OnClientEvent:Connect(function()
		setVisible(false)
	end)

	Net.GetEvent(Net.Id.RunEnded).OnClientEvent:Connect(function()
		setVisible(true)
	end)
end

return CurrencyController
