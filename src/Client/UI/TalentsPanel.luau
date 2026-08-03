--!strict
--[[
	TalentsPanel — древо талантов (раздел 6 ТЗ), M5.

	Узлы и связи рисуются из Config/Talents, а не расставляются руками: панель
	не знает ни одного id и ни одной координаты. Добавить узел — значит дописать
	строку в конфиг, этот файл при этом не трогается.

	Что считает клиент, а что нет. Доступность узла подсвечивается здесь —
	это подсказка, чтобы игрок не тыкал вслепую. Настоящая проверка живёт
	в TalentService, и она единственная, которой можно верить: панель может
	ошибаться сколько угодно, сервер всё равно откажет.

	Управление под телефон: дерево перетаскивается пальцем, масштаб — двумя
	крупными кнопками. Пинч был бы приятнее, но он одинаково капризен
	и в Studio, и на половине устройств, а кнопки работают везде.

	Публичный API:
		TalentsPanel.Build(parent, send) -> Panel
		panel.Open()
		panel.Close()
		panel.Refresh(view, essence)
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Palette = require(Shared.Config.Palette)
local Talents = require(Shared.Config.Talents)
local Types = require(Shared.Types)
local UiKit = require(script.Parent.UiKit)

--[[
	Сколько пикселей в одной условной единице дерева при масштабе 1.
	Заметно больше диаметра узла: под каждым узлом стоят две строки подписи,
	и при тесной расстановке они наезжали бы на соседей.
]]
local UNIT = 96
local NODE_SIZE = 54
local LINK_THICKNESS = 4

local ZOOM_MIN = 0.5
local ZOOM_MAX = 1.6
local ZOOM_STEP = 0.15

export type Panel = {
	Open: () -> (),
	Close: () -> (),
	Refresh: (view: Types.TalentsView?, essence: number) -> (),
}

local TalentsPanel = {}

-- Цвет узла: стихия своим цветом, общий — акцентом интерфейса.
local function nodeColor(node: Types.TalentNode): Color3
	local element = node.element
	return if element then Palette.Element[element] else Palette.UI.accent
end

-- Короткая подпись эффекта под названием узла.
local function effectText(node: Types.TalentNode): string
	local effect = node.effect
	local kind = effect.kind

	if kind == "ElementDamage" then
		return `+{math.floor(effect.perPoint * 100 + 0.5)}% damage`
	elseif kind == "ElementCooldown" then
		return `-{math.floor(effect.perPoint * 100 + 0.5)}% cooldown`
	elseif kind == "MaxHealth" then
		return `+{effect.perPoint} health`
	elseif kind == "WalkSpeed" then
		return `+{effect.perPoint} speed`
	end

	return `+{effect.perPoint} pickup range`
end

function TalentsPanel.Build(parent: Instance, send: (action: string, target: string?, extra: unknown) -> ()): Panel
	local window = UiKit.Window(parent, "TalentsPanel", "Talents")

	--[[
		Область просмотра с обрезкой: дерево заведомо больше окна, и без
		ClipsDescendants узлы вылезали бы поверх заголовка и кнопок.
	]]
	local viewport = UiKit.Frame(window.content, "Viewport", Palette.UI.background)
	viewport.Size = UDim2.new(1, 0, 1, -UiKit.ButtonHeight - 10)
	viewport.BackgroundTransparency = 0.45
	viewport.ClipsDescendants = true
	viewport.Active = true -- чтобы кадр сам ловил перетаскивание
	UiKit.Corners(viewport, 10)

	--[[
		Холст стоит в центре области просмотра и двигается перетаскиванием.
		Масштаб делает UIScale, а не пересчёт координат: так меняется одно
		число, а не позиция каждого узла и каждой связи.
	]]
	local canvas = UiKit.Frame(viewport, "Canvas")
	canvas.AnchorPoint = Vector2.new(0.5, 0.5)
	canvas.Position = UDim2.fromScale(0.5, 0.5)
	canvas.Size = UDim2.fromOffset(0, 0)

	local scale = Instance.new("UIScale")
	scale.Scale = 1
	scale.Parent = canvas

	local links = UiKit.Frame(canvas, "Links")
	links.Size = UDim2.fromOffset(0, 0)

	local buttons: { [string]: TextButton } = {}
	local counters: { [string]: TextLabel } = {}

	local latest: Types.TalentsView? = nil
	local essenceBalance = 0

	local footer = UiKit.Frame(window.content, "Footer")
	footer.AnchorPoint = Vector2.new(0, 1)
	footer.Position = UDim2.fromScale(0, 1)
	footer.Size = UDim2.new(1, 0, 0, UiKit.ButtonHeight)

	local zoomOut = UiKit.Button(footer, "ZoomOut", "-", Palette.UI.panel)
	zoomOut.Size = UDim2.fromOffset(UiKit.ButtonHeight, UiKit.ButtonHeight)

	local zoomIn = UiKit.Button(footer, "ZoomIn", "+", Palette.UI.panel)
	zoomIn.Position = UDim2.fromOffset(UiKit.ButtonHeight + 6, 0)
	zoomIn.Size = UDim2.fromOffset(UiKit.ButtonHeight, UiKit.ButtonHeight)

	local recenter = UiKit.Button(footer, "Recenter", "Center", Palette.UI.panel)
	recenter.Position = UDim2.fromOffset((UiKit.ButtonHeight + 6) * 2, 0)
	recenter.Size = UDim2.fromOffset(96, UiKit.ButtonHeight)

	local reset = UiKit.Button(footer, "Reset", "Reset tree", Palette.UI.danger)
	reset.AnchorPoint = Vector2.new(1, 0)
	reset.Position = UDim2.fromScale(1, 0)
	reset.Size = UDim2.fromOffset(190, UiKit.ButtonHeight)

	--[[
		Связи рисуются один раз: они не зависят ни от вложенных очков, ни от
		уровня — только от данных, которые за сессию не меняются.

		Каждая связь — узкий прямоугольник, повёрнутый вдоль отрезка между
		узлами. Пара рисуется только в одну сторону: у соседей связь взаимная,
		и без этой проверки каждая линия рисовалась бы дважды.
	]]
	local function buildLinks(): ()
		for _, node in Talents.List do
			for _, otherId in Talents.Neighbours(node.id) do
				if node.id >= otherId then
					continue
				end

				local other = Talents.ById[otherId]
				if not other then
					continue
				end

				local from = node.position * UNIT
				local to = other.position * UNIT
				local delta = to - from
				local middle = (from + to) / 2

				local line = UiKit.Frame(links, `Link_{node.id}_{otherId}`, Palette.UI.panel)
				line.AnchorPoint = Vector2.new(0.5, 0.5)
				line.Position = UDim2.fromOffset(middle.X, middle.Y)
				line.Size = UDim2.fromOffset(delta.Magnitude, LINK_THICKNESS)
				line.Rotation = math.deg(math.atan2(delta.Y, delta.X))
				line.BackgroundTransparency = 0.3
			end
		end
	end

	local function buildNodes(): ()
		for _, node in Talents.List do
			local position = node.position * UNIT

			local button = UiKit.Button(canvas, `Node_{node.id}`, "", nodeColor(node))
			button.AnchorPoint = Vector2.new(0.5, 0.5)
			button.Position = UDim2.fromOffset(position.X, position.Y)
			button.Size = UDim2.fromOffset(NODE_SIZE, NODE_SIZE)
			button.Text = ""
			UiKit.Corners(button, NODE_SIZE // 2)

			local counter = UiKit.Label(button, "Counter", "0/0", 15, Palette.UI.background)
			counter.Font = Enum.Font.GothamBold
			counter.Size = UDim2.fromScale(1, 1)
			counter.TextXAlignment = Enum.TextXAlignment.Center

			-- Подпись под узлом: без неё дерево читается как набор кружков.
			local caption = UiKit.Label(button, "Caption", node.displayName, 12, Palette.UI.text)
			caption.AnchorPoint = Vector2.new(0.5, 0)
			caption.Position = UDim2.new(0.5, 0, 1, 2)
			caption.Size = UDim2.fromOffset(120, 16)
			caption.TextXAlignment = Enum.TextXAlignment.Center
			caption.TextTruncate = Enum.TextTruncate.AtEnd

			local hint = UiKit.Label(button, "Hint", effectText(node), 11, Palette.UI.subtext)
			hint.AnchorPoint = Vector2.new(0.5, 0)
			hint.Position = UDim2.new(0.5, 0, 1, 18)
			hint.Size = UDim2.fromOffset(120, 14)
			hint.TextXAlignment = Enum.TextXAlignment.Center

			button.Activated:Connect(function()
				send("SpendTalent", node.id, nil)
			end)

			buttons[node.id] = button
			counters[node.id] = counter
		end
	end

	--[[
		Перекраска по состоянию. Три состояния и все три различимы без текста:
		вложенный узел горит полным цветом, доступный — приглушён, закрытый —
		почти прозрачен.
	]]
	local function render(): ()
		local view = latest

		local spent: { [string]: number } = if view then view.spent else {}
		local points = if view then view.points else 0

		if view then
			local progress = if view.xpToNext > 0 then `{view.xp}/{view.xpToNext} xp` else "max level"
			window.subtitle.Text = `Level {view.level}  ·  {progress}  ·  {points} points to spend`

			local cost = view.resetCost
			reset.Text = if cost > 0 then `Reset · {UiKit.FormatAmount(cost)}` else "Reset tree"
			UiKit.SetEnabled(reset, cost > 0 and essenceBalance >= cost)
		end

		for _, node in Talents.List do
			local button = buttons[node.id]
			local counter = counters[node.id]
			if not button or not counter then
				continue
			end

			local invested = spent[node.id] or 0
			counter.Text = `{invested}/{node.maxPoints}`

			local unlocked = Talents.IsRoot(node.id) or invested > 0
			if not unlocked then
				for _, neighbourId in Talents.Neighbours(node.id) do
					if (spent[neighbourId] or 0) > 0 then
						unlocked = true
						break
					end
				end
			end

			local canSpend = unlocked and points > 0 and invested < node.maxPoints

			if invested > 0 then
				button.BackgroundTransparency = 0
			elseif unlocked then
				button.BackgroundTransparency = 0.45
			else
				button.BackgroundTransparency = 0.8
			end

			button.AutoButtonColor = canSpend
			counter.TextTransparency = if unlocked then 0 else 0.5
		end
	end

	local function setZoom(value: number): ()
		scale.Scale = math.clamp(value, ZOOM_MIN, ZOOM_MAX)
	end

	local function recenterCanvas(): ()
		canvas.Position = UDim2.fromScale(0.5, 0.5)
		setZoom(1)
	end

	--[[
		Перетаскивание.

		Главная ловушка здесь в том, что мышь и палец приходят по-разному:
		у пальца движение приходит тем же InputObject, что и нажатие, а у мыши
		нажатие и движение — два РАЗНЫХ объекта (MouseButton1 и MouseMovement).
		Поэтому запоминается флаг и точка отсчёта, а не сам объект: сравнение
		с запомненным объектом означало бы, что мышью дерево не двигается вовсе.

		Холст сдвигается в пикселях, поэтому масштаб на скорость перетаскивания
		не влияет.
	]]
	local dragging = false
	local dragStart = Vector2.zero
	local dragOrigin = UDim2.new()

	local function moveDrag(position: Vector3): ()
		if not dragging then
			return
		end

		local delta = Vector2.new(position.X, position.Y) - dragStart
		canvas.Position = UDim2.new(
			dragOrigin.X.Scale,
			dragOrigin.X.Offset + delta.X,
			dragOrigin.Y.Scale,
			dragOrigin.Y.Offset + delta.Y
		)
	end

	viewport.InputBegan:Connect(function(input: InputObject)
		if
			input.UserInputType == Enum.UserInputType.MouseButton1
			or input.UserInputType == Enum.UserInputType.Touch
		then
			dragging = true
			dragStart = Vector2.new(input.Position.X, input.Position.Y)
			dragOrigin = canvas.Position
		end
	end)

	viewport.InputChanged:Connect(function(input: InputObject)
		if
			input.UserInputType == Enum.UserInputType.MouseMovement
			or input.UserInputType == Enum.UserInputType.Touch
		then
			moveDrag(input.Position)
		end
	end)

	--[[
		Отпускание слушаем у UserInputService, а не у кадра: палец или курсор
		вполне может уйти за границы области просмотра, и событие кадра тогда
		не придёт вовсе — холст остался бы приклеенным к курсору навсегда.
	]]
	UserInputService.InputEnded:Connect(function(input: InputObject)
		if
			input.UserInputType == Enum.UserInputType.MouseButton1
			or input.UserInputType == Enum.UserInputType.Touch
		then
			dragging = false
		end
	end)

	zoomIn.Activated:Connect(function()
		setZoom(scale.Scale + ZOOM_STEP)
	end)

	zoomOut.Activated:Connect(function()
		setZoom(scale.Scale - ZOOM_STEP)
	end)

	recenter.Activated:Connect(recenterCanvas)

	reset.Activated:Connect(function()
		send("ResetTalents", nil, nil)
	end)

	buildLinks()
	buildNodes()

	local panel: Panel = {
		Open = function()
			window.screen.Enabled = true
			-- Дерево всегда открывается от корня: игрок, ушедший в прошлый раз
			-- в дальний угол, иначе увидел бы пустоту и решил, что оно сломалось.
			recenterCanvas()
			render()
		end,

		Close = function()
			window.screen.Enabled = false
		end,

		Refresh = function(view: Types.TalentsView?, essence: number)
			latest = view
			essenceBalance = essence
			if window.screen.Enabled then
				render()
			end
		end,
	}

	return panel
end

return TalentsPanel
