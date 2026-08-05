--!strict
--[[
	UiKit — общий билдер интерфейса лобби (раздел 8 ТЗ: весь UI — код, ничего
	не собирается руками в Studio, чтобы всё лежало в git).

	Лежит в Client/UI, а не в Controllers: загрузчик сканирует только Controllers,
	и модуль без Init/Start там был бы контроллером-пустышкой.

	Вёрстка под телефон (раздел 2 ТЗ): панели в долях экрана, кнопки не меньше
	44 пикселей, списки прокручиваются, ничего важного не липнет к самому краю.

	Вызовы через точку, как у остальных утилит проекта.
]]

local Workspace = game:GetService("Workspace")

local Palette = require(game:GetService("ReplicatedStorage"):WaitForChild("Shared").Config.Palette)

local UiKit = {}

UiKit.ButtonHeight = 48 -- не меньше 44 пикселей
UiKit.RowHeight = 64
UiKit.Corner = 10

--[[
	Автомасштаб окна по вьюпорту (раздел 2 ТЗ, M7). Все панели верстались на
	широком экране, и на телефоне (300-450 pt в портретной ориентации) строки
	с фиксированными смещениями (UiKit.Row, ButtonHeight) начинают перекрывать
	друг друга раньше, чем помогает одна лишь UDim2.fromScale у панели.

	Никогда не увеличивает UI выше единицы — на широком десктопе фиксированные
	48px кнопки и так читаются нормально, расти там некуда и незачем.
	Не опускается ниже MIN_SCALE, иначе текст на самом маленьком телефоне
	стал бы нечитаемым быстрее, чем помогло бы место, которое он освободил.
]]
local REFERENCE_WIDTH = 1280
local REFERENCE_HEIGHT = 800

--[[
	Пол масштаба. ButtonHeight = 48 — минимальный тач-таргет проекта (44px
	с запасом), и 0.92 — это ровно тот пол, ниже которого масштаб опустил бы
	кнопку под эти 44px. Читаемость текста на самом узком телефоне здесь
	приносится в жертву тач-таргету, а не наоборот: промахнуться пальцем хуже,
	чем прищуриться.
]]
local MIN_SCALE = 0.92
local MAX_SCALE = 1

local function computeScale(): number
	local camera = Workspace.CurrentCamera
	local viewport = if camera then camera.ViewportSize else Vector2.new(REFERENCE_WIDTH, REFERENCE_HEIGHT)
	local factor = math.min(viewport.X / REFERENCE_WIDTH, viewport.Y / REFERENCE_HEIGHT)
	return math.clamp(factor, MIN_SCALE, MAX_SCALE)
end

-- Следит и за сменой размера окна, и за подменой самой камеры (на случай,
-- если что-то в проекте когда-нибудь её пересоздаст).
local function watchViewport(uiScale: UIScale): ()
	local viewportConnection: RBXScriptConnection? = nil

	local function apply()
		uiScale.Scale = computeScale()
	end

	local function hook()
		local existing = viewportConnection
		if existing then
			existing:Disconnect()
		end
		local camera = Workspace.CurrentCamera
		viewportConnection = if camera then camera:GetPropertyChangedSignal("ViewportSize"):Connect(apply) else nil
		apply()
	end

	hook()
	Workspace:GetPropertyChangedSignal("CurrentCamera"):Connect(hook)
end

--[[
	Скругление. Существующий UICorner переиспользуется, а не добавляется второй:
	Roblox применяет только первый найденный, поэтому «скруглить сильнее» уже
	скруглённую кнопку иначе не получилось бы — второй объект молча
	не действовал бы, и круглые узлы дерева остались бы прямоугольниками.
]]
function UiKit.Corners(instance: GuiObject, radius: number?): ()
	local corner = instance:FindFirstChildOfClass("UICorner")
	if not corner then
		corner = Instance.new("UICorner")
		corner.Parent = instance
	end
	corner.CornerRadius = UDim.new(0, radius or UiKit.Corner)
end

function UiKit.Padding(instance: GuiObject, amount: number): ()
	local padding = Instance.new("UIPadding")
	padding.PaddingTop = UDim.new(0, amount)
	padding.PaddingBottom = UDim.new(0, amount)
	padding.PaddingLeft = UDim.new(0, amount)
	padding.PaddingRight = UDim.new(0, amount)
	padding.Parent = instance
end

function UiKit.Frame(parent: Instance, name: string, color: Color3?): Frame
	local frame = Instance.new("Frame")
	frame.Name = name
	frame.BackgroundColor3 = color or Palette.UI.panel
	frame.BackgroundTransparency = if color then 0 else 1
	frame.BorderSizePixel = 0
	frame.Parent = parent
	return frame
end

function UiKit.Label(parent: Instance, name: string, text: string, size: number, color: Color3?): TextLabel
	local label = Instance.new("TextLabel")
	label.Name = name
	label.BackgroundTransparency = 1
	label.Font = Enum.Font.Gotham
	label.Text = text
	label.TextColor3 = color or Palette.UI.text
	label.TextSize = size
	label.TextXAlignment = Enum.TextXAlignment.Left
	label.TextTruncate = Enum.TextTruncate.AtEnd
	label.Parent = parent
	return label
end

function UiKit.Button(parent: Instance, name: string, text: string, color: Color3?): TextButton
	local button = Instance.new("TextButton")
	button.Name = name
	button.AutoButtonColor = true
	button.BackgroundColor3 = color or Palette.UI.accent
	button.BorderSizePixel = 0
	button.Font = Enum.Font.GothamBold
	button.Text = text
	button.TextColor3 = Palette.UI.text
	button.TextSize = 16
	button.Size = UDim2.fromOffset(120, UiKit.ButtonHeight)
	button.Parent = parent
	UiKit.Corners(button, 8)

	--[[
		Звук клика централизован здесь: у проекта девять с лишним панелей,
		и заводить его в каждой по отдельности значило бы девять раз забыть
		один клик. require ленивый (внутри обработчика, а не в шапке модуля):
		SoundController — Controller, а не Util, и на момент требования этого
		модуля из панели он может быть ещё не заскроен загрузчиком; к моменту
		первого клика Start уже отработал у всех.
	]]
	button.Activated:Connect(function()
		local SoundController = require(script.Parent.Parent.Controllers.SoundController)
		SoundController.PlaySfx("ButtonClick")
	end)

	return button
end

--[[
	Кнопка, которую нельзя нажать (не хватает валюты, максимальный уровень).

	Гасится цветом и прозрачностью, а не исчезает: пропавшая кнопка читается как
	ошибка интерфейса, а погашенная — как «пока нельзя», и объясняет сама себя.
]]
function UiKit.SetEnabled(button: TextButton, enabled: boolean): ()
	button.AutoButtonColor = enabled
	button.BackgroundTransparency = if enabled then 0 else 0.6
	button.TextTransparency = if enabled then 0 else 0.5
	button.Active = enabled
end

function UiKit.Scroll(parent: Instance, name: string): ScrollingFrame
	local scroll = Instance.new("ScrollingFrame")
	scroll.Name = name
	scroll.BackgroundTransparency = 1
	scroll.BorderSizePixel = 0
	scroll.ScrollBarThickness = 4
	scroll.ScrollBarImageColor3 = Palette.UI.accent
	scroll.AutomaticCanvasSize = Enum.AutomaticSize.Y
	scroll.CanvasSize = UDim2.new()
	scroll.Parent = parent

	local layout = Instance.new("UIListLayout")
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Padding = UDim.new(0, 8)
	layout.Parent = scroll

	return scroll
end

--[[
	Очистка списка перед перерисовкой.

	Удаляется всё, кроме раскладки: проверять «это Frame» недостаточно —
	строкой списка может оказаться и подпись «пусто», и она бы пережила
	перерисовку и осталась висеть поверх заполненного списка.
]]
function UiKit.ClearList(scroll: ScrollingFrame): ()
	for _, child in scroll:GetChildren() do
		if not child:IsA("UIListLayout") then
			child:Destroy()
		end
	end
end

--[[
	Каркас окна: затемнение, панель, заголовок, крестик и место под содержимое.

	Возвращает саму панель (её показывают и прячут) и контейнер содержимого,
	чтобы вызывающий не знал про внутреннее устройство шапки.
]]
export type Window = {
	screen: ScreenGui,
	panel: Frame,
	content: Frame,
	title: TextLabel,
	subtitle: TextLabel,
}

function UiKit.Window(parent: Instance, name: string, titleText: string): Window
	local screen = Instance.new("ScreenGui")
	screen.Name = name
	screen.ResetOnSpawn = false
	screen.DisplayOrder = 300
	screen.IgnoreGuiInset = true
	screen.Enabled = false
	screen.Parent = parent

	local backdrop = UiKit.Frame(screen, "Backdrop", Palette.UI.background)
	backdrop.Size = UDim2.fromScale(1, 1)
	backdrop.BackgroundTransparency = 0.35

	local panel = UiKit.Frame(backdrop, "Panel", Palette.UI.panel)
	panel.AnchorPoint = Vector2.new(0.5, 0.5)
	panel.Position = UDim2.fromScale(0.5, 0.5)
	panel.Size = UDim2.fromScale(0.88, 0.82)
	UiKit.Corners(panel, 14)

	local uiScale = Instance.new("UIScale")
	uiScale.Parent = panel
	watchViewport(uiScale)

	local header = UiKit.Frame(panel, "Header")
	header.Size = UDim2.new(1, -24, 0, 56)
	header.Position = UDim2.fromOffset(12, 8)

	local title = UiKit.Label(header, "Title", titleText, 24)
	title.Font = Enum.Font.GothamBold
	title.Size = UDim2.new(1, -60, 0, 30)

	local subtitle = UiKit.Label(header, "Subtitle", "", 14, Palette.UI.subtext)
	subtitle.Position = UDim2.fromOffset(0, 32)
	subtitle.Size = UDim2.new(1, -60, 0, 20)

	local close = UiKit.Button(header, "Close", "X", Palette.UI.danger)
	close.AnchorPoint = Vector2.new(1, 0)
	close.Position = UDim2.fromScale(1, 0)
	close.Size = UDim2.fromOffset(UiKit.ButtonHeight, UiKit.ButtonHeight)
	close.Activated:Connect(function()
		screen.Enabled = false
	end)

	local content = UiKit.Frame(panel, "Content")
	content.Position = UDim2.fromOffset(12, 72)
	content.Size = UDim2.new(1, -24, 1, -84)

	return { screen = screen, panel = panel, content = content, title = title, subtitle = subtitle }
end

--[[
	Строка списка: цветная метка слева (редкость или стихия), две строки текста
	и место под кнопки справа. Одна форма на питомцев, яйца и лоты магазина —
	иначе три почти одинаковых вёрстки разъедутся при первой же правке.
]]
export type Row = {
	frame: Frame,
	badge: TextLabel,
	title: TextLabel,
	subtitle: TextLabel,
	actions: Frame,
}

function UiKit.Row(parent: Instance, order: number, accent: Color3): Row
	local frame = UiKit.Frame(parent, `Row{order}`, Palette.UI.background)
	frame.LayoutOrder = order
	frame.Size = UDim2.new(1, -8, 0, UiKit.RowHeight)
	frame.BackgroundTransparency = 0.3
	UiKit.Corners(frame, 8)

	local badge = Instance.new("TextLabel")
	badge.Name = "Badge"
	badge.AnchorPoint = Vector2.new(0, 0.5)
	badge.Position = UDim2.new(0, 8, 0.5, 0)
	badge.Size = UDim2.fromOffset(44, 44)
	badge.BackgroundColor3 = accent
	badge.BorderSizePixel = 0
	badge.Font = Enum.Font.GothamBold
	badge.Text = ""
	badge.TextColor3 = Palette.UI.background
	badge.TextSize = 16
	badge.Parent = frame
	UiKit.Corners(badge, 8)

	local title = UiKit.Label(frame, "Title", "", 17)
	title.Font = Enum.Font.GothamBold
	title.Position = UDim2.fromOffset(62, 10)
	title.Size = UDim2.new(1, -250, 0, 22)

	local subtitle = UiKit.Label(frame, "Subtitle", "", 13, Palette.UI.subtext)
	subtitle.Position = UDim2.fromOffset(62, 32)
	subtitle.Size = UDim2.new(1, -250, 0, 20)

	local actions = UiKit.Frame(frame, "Actions")
	actions.AnchorPoint = Vector2.new(1, 0.5)
	actions.Position = UDim2.new(1, -8, 0.5, 0)
	actions.Size = UDim2.fromOffset(176, UiKit.ButtonHeight)

	local layout = Instance.new("UIListLayout")
	layout.FillDirection = Enum.FillDirection.Horizontal
	layout.HorizontalAlignment = Enum.HorizontalAlignment.Right
	layout.VerticalAlignment = Enum.VerticalAlignment.Center
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Padding = UDim.new(0, 6)
	layout.Parent = actions

	return { frame = frame, badge = badge, title = title, subtitle = subtitle, actions = actions }
end

-- 12345 -> "12 345". Длинные числа без разделителя читаются как каша.
function UiKit.FormatAmount(value: number): string
	local text = tostring(math.floor(value))
	local result = text
	local count: number

	repeat
		result, count = string.gsub(result, "^(-?%d+)(%d%d%d)", "%1 %2")
	until count == 0

	return result
end

-- Длительность словами: «4 h 20 m». Секунды в отчёте экспедиций не нужны.
function UiKit.FormatDuration(seconds: number): string
	local total = math.max(math.floor(seconds), 0)
	local hours = total // 3600
	local minutes = (total % 3600) // 60

	if hours > 0 then
		return `{hours} h {minutes} m`
	end
	if minutes > 0 then
		return `{minutes} m`
	end
	return `{total} s`
end

return UiKit
