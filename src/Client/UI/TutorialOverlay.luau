--!strict
--[[
	TutorialOverlay — одна подсказка обучения на экране (M7, раздел 4 ТЗ).

	Всё обучение обходится одной плашкой: и в бою, и в лобби подсказка бывает
	только одна за раз (порядок задан Config/Tutorial), поэтому ни списка,
	ни очереди здесь нет.

	Кнопка «Next» показывается только у шагов, которые нечем закрыть действием
	(объяснение пассивок питомца, прощание в конце). У остальных её нет
	намеренно: там, где от игрока ждут нажатия настоящей кнопки, вторая кнопка
	рядом с текстом — это способ пройти обучение, ничего не сделав.

	Место — под шапкой боевого HUD (полоса опыта, таймер, полоса босса и подпись
	фазы занимают верхние ~98 пикселей). Ниже нельзя: на телефоне низ экрана
	занимает джойстик, а в лобби — панель кнопок.

	DisplayOrder 450 — выше карточек левел-апа (400) и окон лобби (300), но ниже
	экрана результатов (500) и уведомлений. Подсказка про карточку обязана быть
	видна поверх самих карточек (иначе она бесполезна ровно тогда, когда нужна),
	а вот экран результатов её честно закрывает: забег кончился, читать про
	кристаллы поздно.

	Публичный API:
		TutorialOverlay.Build(parent) -> Overlay
		Overlay.Show(text, showNext)
		Overlay.Hide()
		Overlay.SetNextHandler(fn)
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Palette = require(ReplicatedStorage:WaitForChild("Shared").Config.Palette)
local UiKit = require(script.Parent.UiKit)

local TOP_OFFSET = 110
local MAX_WIDTH = 620
local PADDING = 10

local TutorialOverlay = {}

export type Overlay = {
	Show: (text: string, showNext: boolean) -> (),
	Hide: () -> (),
	SetNextHandler: (fn: () -> ()) -> (),
}

function TutorialOverlay.Build(parent: Instance): Overlay
	local screen = Instance.new("ScreenGui")
	screen.Name = "Tutorial"
	screen.ResetOnSpawn = false
	screen.DisplayOrder = 450
	screen.IgnoreGuiInset = true
	screen.Enabled = false
	screen.Parent = parent

	local bubble = UiKit.Frame(screen, "Bubble", Palette.UI.panel)
	bubble.AnchorPoint = Vector2.new(0.5, 0)
	bubble.Position = UDim2.new(0.5, 0, 0, TOP_OFFSET)
	-- Ширина по экрану, высота по содержимому: одна и та же подсказка занимает
	-- одну строку на десктопе и три на телефоне.
	bubble.Size = UDim2.fromScale(0.7, 0)
	bubble.AutomaticSize = Enum.AutomaticSize.Y
	bubble.BackgroundTransparency = 0.1
	UiKit.Corners(bubble, 10)
	UiKit.Padding(bubble, PADDING)

	local limit = Instance.new("UISizeConstraint")
	limit.MaxSize = Vector2.new(MAX_WIDTH, math.huge)
	limit.Parent = bubble

	local stroke = Instance.new("UIStroke")
	stroke.Color = Palette.UI.accent
	stroke.Thickness = 2
	stroke.Parent = bubble

	-- Вертикальная раскладка: кнопка встаёт под текстом сама, какой бы
	-- высоты он ни оказался на узком экране.
	local layout = Instance.new("UIListLayout")
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.HorizontalAlignment = Enum.HorizontalAlignment.Center
	layout.Padding = UDim.new(0, 8)
	layout.Parent = bubble

	local label = UiKit.Label(bubble, "Text", "", 18)
	label.Font = Enum.Font.GothamBold
	label.LayoutOrder = 1
	label.Size = UDim2.fromScale(1, 0)
	label.AutomaticSize = Enum.AutomaticSize.Y
	label.TextWrapped = true
	label.TextTruncate = Enum.TextTruncate.None
	label.TextXAlignment = Enum.TextXAlignment.Center

	-- Имя не next: так называется стандартная функция Lua, и затенять её
	-- локальной переменной — способ однажды получить очень странную ошибку.
	local nextButton = UiKit.Button(bubble, "Next", "Got it", Palette.UI.accent)
	nextButton.LayoutOrder = 2
	nextButton.Size = UDim2.fromOffset(140, UiKit.ButtonHeight)
	nextButton.Visible = false

	local nextHandler: (() -> ())? = nil
	nextButton.Activated:Connect(function()
		local handler = nextHandler
		if handler then
			handler()
		end
	end)

	local function Show(text: string, showNext: boolean): ()
		label.Text = text
		nextButton.Visible = showNext
		screen.Enabled = true
	end

	local function Hide(): ()
		screen.Enabled = false
	end

	local function SetNextHandler(fn: () -> ()): ()
		nextHandler = fn
	end

	return { Show = Show, Hide = Hide, SetNextHandler = SetNextHandler }
end

return TutorialOverlay
