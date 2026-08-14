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
local Icons = require(Shared.Config.Icons)
local Net = require(Shared.Net)
local Palette = require(Shared.Config.Palette)
local Types = require(Shared.Types)
local UiKit = require(script.Parent.Parent.UI.UiKit)

local PILL_HEIGHT = 32
local PILL_WIDTH = 116
local PILL_GAP = 6

local CurrencyController = {}

local player = Players.LocalPlayer

local screen: ScreenGui? = nil
local essenceLabel: TextLabel? = nil
local prismsLabel: TextLabel? = nil

local function makePill(parent: Instance, order: number, color: Color3, kind: Types.CurrencyKind): TextLabel
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

	-- Та же рамка, что у строк списков: плашка валюты — такой же элемент
	-- интерфейса, и без рамки она выпадала из общего вида.
	UiKit.Skin(pill, "FrameRow")

	--[[
		Иконка валюты. Пока её нет — кружок цветом валюты: цена в этой строке
		есть всегда, и без опознавательного знака рядом с числом непонятно,
		о какой из двух валют речь.

		Иконка крупнее кружка (20 против 14): у кружка вся работа — быть цветом,
		а у картинки внутри есть форма, и на четырнадцати точках она пропадает.
	]]
	local image = UiKit.Image(pill, "Icon", Icons.Currency[kind])
	if image then
		image.AnchorPoint = Vector2.new(0, 0.5)
		image.Position = UDim2.new(0, 6, 0.5, 0)
		image.Size = UDim2.fromOffset(20, 20)
	else
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
	end

	--[[
		Число стоит ПО ЦЕНТРУ свободного места справа от значка, а не жмётся
		к правому краю. Прижатое к краю, оно упиралось в фаску рамки, и на
		коротком числе плашка выглядела наполовину пустой: значок слева,
		число у самого борта, дыра посередине.

		Ширина считается от значка и отступов, а не подбирается: значок стоит
		в шести пикселях и занимает двадцать, справа оставляем столько же.
	]]
	local textLeft = 6 + 20 + 4

	local label = Instance.new("TextLabel")
	label.Name = "Amount"
	label.AnchorPoint = Vector2.new(0, 0.5)
	label.Position = UDim2.new(0, textLeft, 0.5, 0)
	label.Size = UDim2.new(1, -(textLeft + 10), 1, 0)
	label.BackgroundTransparency = 1
	label.Font = Enum.Font.GothamBold
	label.Text = "0"
	label.TextColor3 = Palette.UI.text
	label.TextSize = 16
	label.TextXAlignment = Enum.TextXAlignment.Center
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

	essenceLabel = makePill(holder, 1, Palette.UI.accent, "essence")
	prismsLabel = makePill(holder, 2, Palette.Element.Dark, "prisms")
end

local function setVisible(visible: boolean): ()
	local gui = screen
	if gui then
		gui.Enabled = visible
	end
end

--[[
	Числа компактные с миллиона: плашка узкая, а Essence поздней игры считается
	миллионами и миллиардами. До миллиона формат прежний, с разделителем —
	«67 507» читается с одного взгляда, а «67.5K» пришлось бы расшифровывать.
]]
local function apply(view: Types.ProfileView): ()
	local essence = essenceLabel
	if essence then
		essence.Text = UiKit.FormatShort(view.essence)
	end

	local prisms = prismsLabel
	if prisms then
		prisms.Text = UiKit.FormatShort(view.prisms)
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
