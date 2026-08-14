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

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local Icons = require(Shared.Config.Icons)
local Palette = require(Shared.Config.Palette)

local UiKit = {}

UiKit.ButtonHeight = 48 -- не меньше 44 пикселей
UiKit.RowHeight = 64
UiKit.Corner = 10
UiKit.TabHeight = 40
UiKit.ChipHeight = 32
--[[
	Ячейка инвентаря. Ширина — тач-таргет, высота с запасом на подпись под
	иконкой (звёзды у питомца, слот у снаряжения): одна высота на все вкладки,
	иначе сетка прыгала бы при переключении.
]]
UiKit.SlotSize = 76
UiKit.SlotHeight = 94
UiKit.SlotGap = 8

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

--[[
	Картинка по Asset ID — или nil, если ассета нет.

	Возвращаемый nil и есть тот самый «ноль означает ассета нет» из Config/Icons:
	вызывающий по нему рисует прежнюю заглушку. Проверка живёт здесь, чтобы
	девять панелей не написали её девять раз и не разошлись в мелочах.

	Растягивается на весь родитель. Кому нужен отступ — задаёт размер сам:
	у ячейки инвентаря и у метки строки они разные.
]]
function UiKit.Image(parent: Instance, name: string, assetId: number?): ImageLabel?
	local asset = Icons.Image(assetId)
	if not asset then
		return nil
	end

	local image = Instance.new("ImageLabel")
	image.Name = name
	image.BackgroundTransparency = 1
	image.BorderSizePixel = 0
	image.Image = asset
	--[[
		Fit, а не Stretch: часть картинок квадратная, часть (баннер локации) нет,
		и растянутая по ячейке иконка — единственный способ испортить любой,
		даже хорошо нарисованный ассет.
	]]
	image.ScaleType = Enum.ScaleType.Fit
	image.Size = UDim2.fromScale(1, 1)
	image.Parent = parent
	return image
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
		Скин кнопки. Цвет при этом теряется — и это осознанно: в новом стиле
		кнопка одна на всё, а смысл несут значок и подпись. Чем отличается
		нажатая и недоступная, говорят отдельные картинки, а не оттенок.

		AutoButtonColor выключается: он подсвечивает ФОН, а фон стал прозрачным,
		и подсветка просто перестала бы работать, тихо и незаметно.
	]]
	if UiKit.Skin(button, "ButtonNormal") then
		button.AutoButtonColor = false

		--[[
			Подпись переезжает в отдельный ярлык, а собственная гасится.

			Иначе её не видно вовсе: подложка скина — ПОТОМОК кнопки, а потомок
			в Roblox рисуется поверх текста своего родителя. Так и пропали
			все надписи разом, включая крестик окна.

			Снаружи при этом ничего не меняется: код по-прежнему пишет
			button.Text, а ярлык повторяет за ним. Менять публичный вызов было
			нельзя — текст кнопкам задают в семи местах уже после создания.
		]]
		local label = UiKit.Label(button, "Label", text, button.TextSize, button.TextColor3)
		label.Font = button.Font
		label.Size = UDim2.fromScale(1, 1)
		label.TextXAlignment = Enum.TextXAlignment.Center
		button.TextTransparency = 1

		button:GetPropertyChangedSignal("Text"):Connect(function()
			label.Text = button.Text
		end)

		--[[
			ПРОЗРАЧНОСТЬ ЗЕРКАЛИТСЯ ТАК ЖЕ, КАК ТЕКСТ, И ТУТ ЖЕ ГАСИТСЯ ОБРАТНО.

			Собственная подпись кнопки со скином обязана оставаться невидимой
			ВСЕГДА: её рисует ярлык. Но снаружи прозрачность пишут в трёх
			местах (SetEnabled, Chip, вкладки) — и каждое из них проявляло
			родной текст поверх ярлыка. На кнопке без значка две копии ложились
			ровно друг на друга и выглядели просто жирнее; на кнопке со значком
			ярлык сдвинут вправо, и надпись двоилась — «1.5M» поверх «1.5M»
			читалось нечитаемой кашей из цифр.

			СОБСТВЕННАЯ ЗАПИСЬ ОТСЕКАЕТСЯ ЗНАЧЕНИЕМ, А НЕ ЗАМКОМ. Сигналы
			свойств в Roblox отложенные: обработчик выполняется не в момент
			присвоения, а на ближайшей точке возобновления, — и флаг «сейчас
			пишу сам» к тому времени уже снят. Единица, которой мы гасим родной
			текст, возвращалась в обработчик как чужая и уезжала в ярлык:
			подпись пропадала с кнопки целиком. Проверка «меньше единицы»
			от порядка выполнения не зависит вовсе.

			Полная непрозрачность снаружи при этом игнорируется — и это
			правильно: погасить подпись через кнопку никто не пытается,
			а те, кто гасит интерфейс совсем (экран загрузки), идут по всем
			потомкам и достают ярлык напрямую.
		]]
		button:GetPropertyChangedSignal("TextTransparency"):Connect(function()
			if button.TextTransparency < 1 then
				label.TextTransparency = button.TextTransparency
				button.TextTransparency = 1
			end
		end)
		button:GetPropertyChangedSignal("TextSize"):Connect(function()
			label.TextSize = button.TextSize
		end)
		button:GetPropertyChangedSignal("TextColor3"):Connect(function()
			label.TextColor3 = button.TextColor3
		end)

		--[[
			Замок SkinLocked ставят те, у кого своя картинка состояния: вкладка
			и чип. Без него нажатие подменило бы их скин на кнопочный, и активная
			вкладка после первого же клика стала бы обычной кнопкой.
		]]
		button.MouseButton1Down:Connect(function()
			if button.Active and not button:GetAttribute("SkinLocked") then
				UiKit.SetSkin(button, "ButtonPressed")
			end
		end)

		local function release()
			if button:GetAttribute("SkinLocked") then
				return
			end
			UiKit.SetSkin(button, if button.Active then "ButtonNormal" else "ButtonDisabled")
		end

		button.MouseButton1Up:Connect(release)
		button.MouseLeave:Connect(release)
	end

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
	Геометрия нарезки скина.

	inset — сколько пикселей ИСХОДНИКА занимает угол; всё, что внутри, тянется.
	Числа измерены по самим файлам, а не подобраны: у каждого куска свой радиус
	скругления, и общей константы тут быть не может.

	scale — во сколько раз ужать куски при отрисовке. Углы 9-slice рисуются в
	натуральную величину, а исходники разного масштаба: у полосы здоровья угол
	120 пикселей при высоте полосы в 16, и без ужатия она превратилась бы
	в два налезающих друг на друга торца.
]]
type SkinPart = { width: number, height: number, inset: number, scale: number }

--[[
	width/height — размеры самого файла. Без них нельзя посчитать SliceCenter:
	он задаётся координатами прямоугольника от левого верхнего угла, а не
	отступами с четырёх сторон, и правая граница считается как width - inset.

	Отступ обязан быть не больше половины меньшей стороны, иначе прямоугольник
	вывернется наизнанку.
]]
local SKIN: { [string]: SkinPart } = {
	FrameWindow = { width = 179, height = 185, inset = 22, scale = 1 },
	FrameRow = { width = 117, height = 122, inset = 14, scale = 1 },
	FrameSlot = { width = 120, height = 126, inset = 34, scale = 0.5 },
	-- Три состояния кнопки нарезаются одинаково, хотя рисунки чуть разные:
	-- иначе кнопка дёргалась бы геометрией в момент нажатия.
	ButtonNormal = { width = 110, height = 67, inset = 22, scale = 0.6 },
	ButtonPressed = { width = 113, height = 69, inset = 22, scale = 0.6 },
	ButtonDisabled = { width = 110, height = 67, inset = 22, scale = 0.6 },
	TabActive = { width = 1869, height = 472, inset = 70, scale = 0.2 },
	TabIdle = { width = 1747, height = 447, inset = 45, scale = 0.31 },
	BarBackground = { width = 1776, height = 308, inset = 110, scale = 0.055 },
	BarFill = { width = 1980, height = 292, inset = 140, scale = 0.045 },
}

local function sliceRect(part: SkinPart): Rect
	return Rect.new(part.inset, part.inset, part.width - part.inset, part.height - part.inset)
end

--[[
	Растягиваемая подложка из Config/Icons.Skin.

	Кладётся первым потомком, чтобы всё остальное рисовалось поверх, и не
	перехватывает ввод: клики должны доставаться самой кнопке.

	Pixelated обязателен. Скин нарисован пиксель-артом, и середина у него
	растягивается в разы; билинейная фильтрация превратила бы её в мыло.
]]
function UiKit.Skin(parent: GuiObject, key: string): ImageLabel?
	local part = SKIN[key]
	local image = UiKit.Image(parent, "Skin", Icons.Skin[key])
	if not image or not part then
		if image then
			image:Destroy()
		end
		return nil
	end

	image.ScaleType = Enum.ScaleType.Slice
	image.SliceCenter = sliceRect(part)
	image.SliceScale = part.scale
	image.ResampleMode = Enum.ResamplerMode.Pixelated
	image.Size = UDim2.fromScale(1, 1)
	image.ZIndex = 0
	image.Active = false
	parent.BackgroundTransparency = 1
	return image
end

--[[
	Смена картинки у уже созданной подложки: нажатие кнопки, переключение вкладки.
	Молчит, если скина нет, — тогда вызывающий красит фон цветом, как раньше.
]]
function UiKit.SetSkin(holder: GuiObject, key: string): ()
	local image = holder:FindFirstChild("Skin")
	local part = SKIN[key]
	local asset = Icons.Image(Icons.Skin[key])
	if image and image:IsA("ImageLabel") and part and asset then
		image.Image = asset
		image.SliceCenter = sliceRect(part)
		image.SliceScale = part.scale
	end
end

-- Есть ли вообще скин: по этому вызывающий решает, красить ли фон цветом.
function UiKit.HasSkin(key: string): boolean
	return SKIN[key] ~= nil and Icons.Skin[key] > 0
end

--[[
	Сколько пикселей занимает НАРИСОВАННАЯ рамка скина с каждой стороны.

	Это и есть та полоса, в которую содержимому заезжать нельзя. Считается,
	а не записывается второй раз руками: угол 9-slice рисуется в натуральную
	величину, ужатую SliceScale, — то есть ровно inset * scale. Разъехаться
	с самой нарезкой это число не может по построению.

	Без скина ноль: тогда рамки нет вовсе, и отступ содержимому даёт вызывающий
	по своим прежним числам.
]]
function UiKit.SkinInset(key: string): number
	local part = SKIN[key]
	if not part or not UiKit.HasSkin(key) then
		return 0
	end
	return math.round(part.inset * part.scale)
end

--[[
	Значок внутри кнопки.

	С подписью значок встаёт слева, а текст отодвигается вправо ровно на его
	ширину: считать это снаружи нельзя — размер значка знает только эта функция.
	Без подписи (крестик окна, стрелка возврата) значок занимает центр.

	Возвращает false, если ассета нет: кнопка тогда остаётся такой, какой была.
]]
function UiKit.ButtonIcon(button: TextButton, assetId: number?, size: number?): boolean
	local image = UiKit.Image(button, "Icon", assetId)
	if not image then
		return false
	end

	local side = size or 26
	image.Size = UDim2.fromOffset(side, side)

	local text = button.Text
	if text == "" then
		image.AnchorPoint = Vector2.new(0.5, 0.5)
		image.Position = UDim2.fromScale(0.5, 0.5)
		return true
	end

	image.AnchorPoint = Vector2.new(0, 0.5)
	image.Position = UDim2.new(0, 8, 0.5, 0)

	--[[
		Подпись живёт отдельным ярлыком и отодвигается вправо от значка.

		UIPadding здесь НЕ ГОДИТСЯ, и это уже было багом: в Roblox он сдвигает
		не только текст, но и всех потомков сразу — то есть значок уезжал ровно
		на ту величину, на которую мы отодвигали от него подпись, и ложился
		поверх неё.

		У кнопки со скином ярлык уже создан — его и двигаем. Заводить второй
		с тем же именем нельзя: искать их потом будут по имени.
	]]
	local existing = button:FindFirstChild("Label")
	local label: TextLabel
	if existing and existing:IsA("TextLabel") then
		label = existing
	else
		button.Text = ""
		label = UiKit.Label(button, "Label", text, button.TextSize, button.TextColor3)
		label.Font = button.Font
	end

	label.TextXAlignment = Enum.TextXAlignment.Left
	label.Position = UDim2.fromOffset(8 + side + 6, 0)
	label.Size = UDim2.new(1, -(8 + side + 12), 1, 0)
	return true
end

--[[
	Кнопка, которую нельзя нажать (не хватает валюты, максимальный уровень).

	Гасится цветом и прозрачностью, а не исчезает: пропавшая кнопка читается как
	ошибка интерфейса, а погашенная — как «пока нельзя», и объясняет сама себя.
]]
function UiKit.SetEnabled(button: TextButton, enabled: boolean): ()
	--[[
		У кнопки со скином эта запись уезжает в ярлык и тут же гасится обратно
		(зеркало в UiKit.Button): собственная подпись такой кнопки обязана
		оставаться невидимой, иначе она рисуется поверх ярлыка вторым слоем.
	]]
	button.TextTransparency = if enabled then 0 else 0.5
	button.Active = enabled

	if UiKit.HasSkin("ButtonNormal") then
		-- Со скином прозрачность фона трогать нельзя: фон и так прозрачный,
		-- а недоступность показывает своя картинка.
		UiKit.SetSkin(button, if enabled then "ButtonNormal" else "ButtonDisabled")
	else
		button.AutoButtonColor = enabled
		button.BackgroundTransparency = if enabled then 0 else 0.6
	end

	--[[
		У кнопки со значком подпись живёт в отдельном ярлыке, и собственный
		TextTransparency её не гасит. Без этого погашенная кнопка выглядела бы
		наполовину активной.
	]]
	local label = button:FindFirstChild("Label")
	if label and label:IsA("TextLabel") then
		label.TextTransparency = if enabled then 0 else 0.5
	end

	local icon = button:FindFirstChild("Icon")
	if icon and icon:IsA("ImageLabel") then
		icon.ImageTransparency = if enabled then 0 else 0.5
	end
end

function UiKit.Scroll(parent: Instance, name: string): ScrollingFrame
	local scroll = Instance.new("ScrollingFrame")
	scroll.Name = name
	scroll.BackgroundTransparency = 1
	scroll.BorderSizePixel = 0
	scroll.ScrollBarThickness = 4
	scroll.ScrollBarImageColor3 = Palette.UI.accent

	--[[
		Ползунок собирается из ТРЁХ картинок, свойства «одна картинка ползунка»
		у ScrollingFrame нет вовсе. И трогать их можно только когда ассет есть:
		по умолчанию там лежат встроенные rbxasset-пути, и запись пустой строки
		не вернула бы стандартный вид, а стёрла бы ползунок.
	]]
	local scrollbar = Icons.Image(Icons.Ui.Scrollbar)
	if scrollbar then
		scroll.TopImage = scrollbar
		scroll.MidImage = scrollbar
		scroll.BottomImage = scrollbar
	end

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

	ОКНО МОДАЛЬНОЕ. Пока оно открыто, кнопки лобби под ним не нажимаются,
	и это не косметика: раньше поверх выбора в одном окне открывалось второе,
	а первое оставалось висеть с уже неверными данными.
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

	--[[
		Подложка — кнопка, а не фрейм, по двум причинам сразу: кнопка
		перехватывает клики по всему экрану (сквозь неинтерактивный фрейм
		Roblox пропускает их к кнопкам под ним, из-за чего панель лобби
		и оставалась нажимаемой), и она же даёт закрытие по клику мимо окна.
	]]
	local backdrop = Instance.new("TextButton")
	backdrop.Name = "Backdrop"
	backdrop.BackgroundColor3 = Palette.UI.background
	backdrop.BackgroundTransparency = 0.35
	backdrop.BorderSizePixel = 0
	backdrop.AutoButtonColor = false
	backdrop.Text = ""
	backdrop.Size = UDim2.fromScale(1, 1)
	backdrop.Parent = screen

	local panel = UiKit.Frame(backdrop, "Panel", Palette.UI.panel)
	panel.AnchorPoint = Vector2.new(0.5, 0.5)
	panel.Position = UDim2.fromScale(0.5, 0.5)
	panel.Size = UDim2.fromScale(0.88, 0.82)
	--[[
		Без этого клик по пустому месту ВНУТРИ окна проваливался бы в подложку
		и закрывал его: фрейм сам по себе ввод не перехватывает.
	]]
	panel.Active = true
	UiKit.Corners(panel, 14)
	UiKit.Skin(panel, "FrameWindow")

	--[[
		Закрытие по клику мимо окна — именно КЛИКОМ, а не отпусканием кнопки.

		Нажатие и отпускание должны прийти на подложку, и палец между ними
		не должен уехать. Иначе перетаскивание, начатое внутри окна и
		законченное за его краем, закрывало бы окно: ровно так и оказалось
		невозможно возить дерево талантов мышью.
	]]
	local CLICK_SLOP = 8 -- пикселей: дрожание руки это ещё клик, а не перетаскивание
	local pressedAt: Vector2? = nil

	local function isPointer(input: InputObject): boolean
		return input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch
	end

	backdrop.InputBegan:Connect(function(input: InputObject)
		if isPointer(input) then
			pressedAt = Vector2.new(input.Position.X, input.Position.Y)
		end
	end)

	backdrop.InputEnded:Connect(function(input: InputObject)
		if not isPointer(input) then
			return
		end

		local start = pressedAt
		pressedAt = nil

		if start and (Vector2.new(input.Position.X, input.Position.Y) - start).Magnitude <= CLICK_SLOP then
			screen.Enabled = false
		end
	end)

	local uiScale = Instance.new("UIScale")
	uiScale.Parent = panel
	watchViewport(uiScale)

	--[[
		Отступ содержимого от края окна.

		Считается от нарисованной рамки, а не берётся числом: у скина окна
		фаска в 22 пикселя, и прежние двенадцать заводили заголовок, вкладки
		и кнопки ПОД неё — надписи наезжали на борт по всему интерфейсу.

		Максимум с двенадцатью нужен для случая «скина нет»: тогда рамки нет
		вовсе, но прижимать содержимое вплотную к краю всё равно нельзя.
	]]
	local inset = math.max(UiKit.SkinInset("FrameWindow"), 12)
	local headerHeight = 56
	local headerGap = 8

	local header = UiKit.Frame(panel, "Header")
	header.Size = UDim2.new(1, -inset * 2, 0, headerHeight)
	header.Position = UDim2.fromOffset(inset, inset)

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
	-- Текст гасится ДО значка: по пустой подписи ButtonIcon понимает,
	-- что кнопка одноиконочная, и ставит картинку по центру.
	if Icons.Ui.Close > 0 then
		close.Text = ""
		UiKit.ButtonIcon(close, Icons.Ui.Close, 22)
	end
	close.Activated:Connect(function()
		screen.Enabled = false
	end)

	local content = UiKit.Frame(panel, "Content")
	content.Position = UDim2.fromOffset(inset, inset + headerHeight + headerGap)
	content.Size = UDim2.new(1, -inset * 2, 1, -(inset * 2 + headerHeight + headerGap))

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
	UiKit.Skin(frame, "FrameRow")

	--[[
		Тот же отступ от рамки, что у окна, только у строки фаска тоньше.
		Метка, поставленная в восьми пикселях, наезжала на неё углом.
	]]
	local inset = math.max(UiKit.SkinInset("FrameRow"), 8)

	local badge = Instance.new("TextLabel")
	badge.Name = "Badge"
	badge.AnchorPoint = Vector2.new(0, 0.5)
	badge.Position = UDim2.new(0, inset, 0.5, 0)
	badge.Size = UDim2.fromOffset(44, 44)
	badge.BackgroundColor3 = accent
	badge.BorderSizePixel = 0
	badge.Font = Enum.Font.GothamBold
	badge.Text = ""
	badge.TextColor3 = Palette.UI.background
	badge.TextSize = 16
	badge.Parent = frame
	UiKit.Corners(badge, 8)

	--[[
		Текст начинается за меткой, а место под кнопки вычитается из ширины
		целиком: 176 самих кнопок, отступ до них и обе фаски. Считать это
		числом «250» было верно ровно до появления рамки.
	]]
	local textLeft = inset + 54
	local textWidth = -(textLeft + 176 + 12 + inset)

	local title = UiKit.Label(frame, "Title", "", 17)
	title.Font = Enum.Font.GothamBold
	title.Position = UDim2.fromOffset(textLeft, 10)
	title.Size = UDim2.new(1, textWidth, 0, 22)

	local subtitle = UiKit.Label(frame, "Subtitle", "", 13, Palette.UI.subtext)
	subtitle.Position = UDim2.fromOffset(textLeft, 32)
	subtitle.Size = UDim2.new(1, textWidth, 0, 20)

	local actions = UiKit.Frame(frame, "Actions")
	actions.AnchorPoint = Vector2.new(1, 0.5)
	actions.Position = UDim2.new(1, -inset, 0.5, 0)
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

--[[
	Картинка в метке строки вместо её подписи.

	Метка остаётся цветной подложкой: у части иконок фон прозрачный, и без
	подложки они висели бы в пустоте. Отступ обязателен — иконка, упирающаяся
	в скруглённый угол, срезается им.

	Возвращает false, если ассета нет: вызывающий тогда оставляет свою подпись
	(«10x», «R$») и строка выглядит ровно как до картинок.
]]
function UiKit.RowIcon(row: Row, assetId: number?): boolean
	local image = UiKit.Image(row.badge, "Icon", assetId)
	if not image then
		return false
	end

	row.badge.Text = ""
	image.Size = UDim2.new(1, -8, 1, -8)
	image.Position = UDim2.fromOffset(4, 4)
	return true
end

--[[
	Сетка ячеек: прокручиваемая область, которая сама переносит ячейки
	по ширине. Считать, сколько их влезает в ряд, не нужно ни разу — на телефоне
	и на десктопе это разные числа, и любое посчитанное однажды будет неверным
	на второй половине устройств.
]]
function UiKit.Grid(parent: Instance, name: string, cellWidth: number, cellHeight: number): ScrollingFrame
	local scroll = Instance.new("ScrollingFrame")
	scroll.Name = name
	scroll.BackgroundTransparency = 1
	scroll.BorderSizePixel = 0
	scroll.ScrollBarThickness = 4
	scroll.ScrollBarImageColor3 = Palette.UI.accent
	scroll.AutomaticCanvasSize = Enum.AutomaticSize.Y
	scroll.CanvasSize = UDim2.new()
	scroll.Parent = parent

	local layout = Instance.new("UIGridLayout")
	layout.CellSize = UDim2.fromOffset(cellWidth, cellHeight)
	layout.CellPadding = UDim2.fromOffset(UiKit.SlotGap, UiKit.SlotGap)
	layout.HorizontalAlignment = Enum.HorizontalAlignment.Center
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Parent = scroll

	return scroll
end

--[[
	Пустая ячейка инвентаря: квадрат с рамкой, в который кладут иконку.

	Отдельно от иконки предмета, потому что ячейка существует и без него:
	классический инвентарь показывает и то, чего в нём нет, — иначе три предмета
	выглядят как список из трёх строк, а не как инвентарь.
]]
function UiKit.Slot(parent: Instance, name: string, order: number): TextButton
	local slot = Instance.new("TextButton")
	slot.Name = name
	slot.LayoutOrder = order
	slot.BackgroundColor3 = Palette.UI.slot
	slot.BackgroundTransparency = 0.25
	slot.BorderSizePixel = 0
	slot.AutoButtonColor = false
	slot.Text = ""
	slot.Size = UDim2.fromScale(1, 1)
	slot.Parent = parent
	UiKit.Corners(slot, 8)

	--[[
		Обводка остаётся и со скином: ею панель показывает выделенную ячейку,
		меняя цвет. Рамка из картинки этого не умеет — она одна на все ячейки.
	]]
	local stroke = Instance.new("UIStroke")
	stroke.Name = "Border"
	stroke.Color = Palette.UI.panel
	stroke.Thickness = 2
	stroke.Parent = slot

	UiKit.Skin(slot, "FrameSlot")
	return slot
end

--[[
	Компактная кнопка-переключатель: критерий сортировки, фильтр по слоту.

	Ниже минимальных 44 пикселей осознанно, и это единственное место, где так
	можно: чип не совершает действия, он меняет вид списка. Промах по нему
	стоит одного повторного нажатия, а не потраченной валюты, — поэтому здесь
	плотность важнее размера цели.
]]
function UiKit.Chip(parent: Instance, name: string, text: string, width: number, active: boolean): TextButton
	local chip = UiKit.Button(parent, name, text, if active then Palette.UI.accent else Palette.UI.background)
	chip.Size = UDim2.fromOffset(width, UiKit.ChipHeight)
	chip.TextSize = 12
	chip.TextTransparency = if active then 0 else 0.2

	--[[
		Со скином цвет чипа перестаёт что-либо значить, поэтому выбранность
		показывают разные картинки: обычная кнопка против погашенной. Замок
		нужен, чтобы нажатие не сбросило это обратно.
	]]
	if UiKit.HasSkin("ButtonNormal") then
		chip:SetAttribute("SkinLocked", true)
		UiKit.SetSkin(chip, if active then "ButtonNormal" else "ButtonDisabled")
	end

	return chip
end

--[[
	Полоса вкладок. Возвращает функцию выбора, чтобы окно могло открыться сразу
	на нужном разделе, не повторяя подсветку у себя.
]]
export type Tabs = {
	frame: Frame,
	Select: (name: string) -> (),
	Current: () -> string,
}

function UiKit.Tabs(parent: Instance, names: { string }, onSelect: (name: string) -> ()): Tabs
	local frame = UiKit.Frame(parent, "Tabs")
	frame.Size = UDim2.new(1, 0, 0, UiKit.TabHeight)

	local layout = Instance.new("UIListLayout")
	layout.FillDirection = Enum.FillDirection.Horizontal
	layout.HorizontalAlignment = Enum.HorizontalAlignment.Left
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Padding = UDim.new(0, 6)
	layout.Parent = frame

	local buttons: { [string]: TextButton } = {}
	local current = names[1] or ""

	local skinned = UiKit.HasSkin("TabActive")

	local tabs: Tabs
	local function paint(): ()
		for name, button in buttons do
			local active = name == current
			button.TextTransparency = if active then 0 else 0.25
			if skinned then
				UiKit.SetSkin(button, if active then "TabActive" else "TabIdle")
			else
				button.BackgroundColor3 = if active then Palette.UI.accent else Palette.UI.background
			end
		end
	end

	for order, name in names do
		local button = UiKit.Button(frame, name, name, Palette.UI.background)
		button.LayoutOrder = order
		button.Size = UDim2.fromOffset(104, UiKit.TabHeight)
		button.TextSize = 15
		if skinned then
			button:SetAttribute("SkinLocked", true)
		end
		button.Activated:Connect(function()
			tabs.Select(name)
		end)
		buttons[name] = button
	end

	tabs = {
		frame = frame,

		Select = function(name: string)
			if not buttons[name] then
				return
			end
			current = name
			paint()
			onSelect(name)
		end,

		Current = function(): string
			return current
		end,
	}

	paint()
	return tabs
end

--[[
	Компактная запись больших чисел: 1 200 000 -> "1.2M".

	Нужна там, где число живёт в узком месте — на кнопке, в плашке валюты, на
	шкале. Экономика поздней игры оперирует миллиардами (полный путь SSS-питомца
	стоит пятнадцать миллионов, а цена уровня растёт в 87 раз), и десятизначное
	число не помещается никуда: оно либо вылезает за рамку, либо наезжает
	на соседний ярлык.

	Точность до одного знака и НЕ округляется вверх: показанное «1.2M» должно
	означать, что денег хватит, если их 1.2M, — а не наоборот.

	Ниже миллиона формат не меняется вовсе: 67 507 читается с одного взгляда,
	а «67.5K» пришлось бы расшифровывать.
]]
local SUFFIXES = table.freeze({
	{ limit = 1e12, suffix = "T" },
	{ limit = 1e9, suffix = "B" },
	{ limit = 1e6, suffix = "M" },
})

function UiKit.FormatShort(value: number): string
	local amount = math.floor(value)
	local sign = if amount < 0 then "-" else ""
	amount = math.abs(amount)

	for _, step in SUFFIXES do
		if amount >= step.limit then
			-- Обрезание, а не округление: 1.99M обязано остаться 1.9M,
			-- иначе кнопка обещает цену, которой игрок ещё не набрал.
			local scaled = math.floor(amount / step.limit * 10) / 10
			local text = if scaled % 1 == 0 then string.format("%d", scaled) else string.format("%.1f", scaled)
			return `{sign}{text}{step.suffix}`
		end
	end

	return sign .. UiKit.FormatAmount(amount)
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
