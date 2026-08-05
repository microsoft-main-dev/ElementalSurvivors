--!strict
--[[
	TalentsPanel — древо талантов (раздел 6 ТЗ), M5.

	Узлы и связи рисуются из Config/Talents, а не расставляются руками: панель
	не знает ни одного id и ни одной координаты. Добавить узел — значит дописать
	строку в конфиг, этот файл при этом не трогается.

	ЕДИНСТВЕННАЯ ПАНЕЛЬ, КОТОРАЯ НЕ ОКНО. Дерево занимает весь экран: так решил
	владелец ради полного фокуса на нём, и это же снимает вопрос обрезки. Связи
	дерева — повёрнутые прямоугольники, а Roblox не обрезает повёрнутые объекты
	НИКАК: ни через ClipsDescendants, ни внутри CanvasGroup. Их и не надо
	обрезать, если границей служит сам экран.

	Собирается своим ScreenGui, а не через UiKit.Window, по той же причине.
	Шапка, полоса подробностей и нижние кнопки лежат поверх дерева отдельными
	полосами.

	ПОДПИСЕЙ ПОД УЗЛАМИ НЕТ. В дереве полторы сотни узлов, и две строки текста
	под каждым — это не подсказка, а каша. Вместо них полоса внизу: касание
	узла показывает, что он даёт, сколько в него вложено и почему нельзя
	вложить ещё. Это же касание и вкладывает очко, если вложить можно.

	Что считает клиент, а что нет. Доступность узла подсвечивается здесь —
	это подсказка, чтобы игрок не тыкал вслепую. Настоящая проверка живёт
	в TalentService, и она единственная, которой можно верить: панель может
	ошибаться сколько угодно, сервер всё равно откажет.

	Управление: дерево возится пальцем и мышью, масштаб — колесом под курсором
	и двумя крупными кнопками. Пинч был бы приятнее пальцем, но он одинаково
	капризен и в Studio, и на половине устройств, а кнопки работают везде.

	Публичный API:
		TalentsPanel.Build(parent, send) -> Panel
		panel.Open()
		panel.Close()
		panel.Refresh(view, essence)
]]

local GuiService = game:GetService("GuiService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Palette = require(Shared.Config.Palette)
local Talents = require(Shared.Config.Talents)
local Types = require(Shared.Types)
local UiKit = require(script.Parent.UiKit)

--[[
	Сколько пикселей в одной условной единице дерева при масштабе 1.

	Меньше, чем было у дерева из тридцати семи узлов: подписи под узлами ушли,
	а сам диск вырос до восьми единиц радиусом, и при прежних 96 пикселях он
	не помещался на экран ни при каком масштабе.
]]
local UNIT = 64

-- Размер узла по калибру. Точка мельче тач-таргета осознанно: их полторы
-- сотни, они кучные, и промах по точке стоит одного повторного касания.
local NODE_SIZE: { [Types.TalentNodeKind]: number } = {
	Minor = 22,
	Notable = 34,
	Keystone = 48,
}

local LINK_THICKNESS = 3
local LINK_ACTIVE_THICKNESS = 5

--[[
	Фон-диск: три кольца разной темноты и разделители секторов. Чистая
	декорация, но без неё полторы сотни кружков висят в пустоте и не читаются
	как ярусы. Радиусы совпадают с ярусами дерева из конфига.
]]
local DISC_RADII = { 8.6, 5.0, 2.1 }
local SECTOR_LINES = 12
local SECTOR_INNER = 2.1
local SECTOR_OUTER = 8.6

local ZOOM_MIN = 0.35
local ZOOM_MAX = 1.6
local ZOOM_STEP = 0.15

local INFO_HEIGHT = 46

export type Panel = {
	Open: () -> (),
	Close: () -> (),
	Refresh: (view: Types.TalentsView?, essence: number) -> (),
}

local TalentsPanel = {}

local player = Players.LocalPlayer

-- Цвет узла: стихия своим цветом, общий — медью магистралей.
local function nodeColor(node: Types.TalentNode): Color3
	local element = node.element
	return if element then Palette.Element[element] else Palette.Talents.path
end

-- Короткая подпись эффекта: сколько даёт одно очко.
local function effectText(node: Types.TalentNode): string
	local effect = node.effect
	local kind = effect.kind

	if kind == "ElementDamage" then
		return `+{math.floor(effect.perPoint * 100 + 0.5)}% {node.element} damage per point`
	elseif kind == "ElementCooldown" then
		return `-{math.floor(effect.perPoint * 100 + 0.5)}% {node.element} cooldown per point`
	elseif kind == "MaxHealth" then
		return `+{effect.perPoint} health per point`
	elseif kind == "WalkSpeed" then
		return `+{effect.perPoint} speed per point`
	end

	return `+{effect.perPoint} pickup range per point`
end

function TalentsPanel.Build(parent: Instance, send: (action: string, target: string?, extra: unknown) -> ()): Panel
	--[[
		Дерево занимает ВЕСЬ экран, а не окно, как остальные панели.

		Так решил владелец, и заодно это единственный способ не бороться
		с обрезкой: связи дерева — повёрнутые прямоугольники, а Roblox
		не обрезает повёрнутые объекты ни через ClipsDescendants, ни внутри
		CanvasGroup. Всё, что выходит за край ЭКРАНА, не рисуется само собой,
		поэтому у полноэкранного дерева этой проблемы просто нет.
	]]
	local screen = Instance.new("ScreenGui")
	screen.Name = "TalentsScreen"
	screen.ResetOnSpawn = false
	screen.DisplayOrder = 300
	screen.IgnoreGuiInset = true
	screen.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	screen.Enabled = false
	screen.Parent = parent

	--[[
		Фон: почти непрозрачная заливка на весь экран. Кнопка, а не фрейм,
		по тем же двум причинам, что и подложка окон, — она перехватывает ввод
		(панель лобби под ней не нажимается) и ловит перетаскивание дерева.

		Клик мимо здесь НИЧЕГО не закрывает: мимо дерева тут только само дерево,
		и закрытие по клику означало бы, что каждая неудачная попытка потащить
		его выбрасывает игрока в лобби. Закрывает крестик.
	]]
	local backdrop = Instance.new("TextButton")
	backdrop.Name = "Backdrop"
	backdrop.BackgroundColor3 = Palette.UI.background
	backdrop.BackgroundTransparency = 0.06
	backdrop.BorderSizePixel = 0
	backdrop.AutoButtonColor = false
	backdrop.Text = ""
	backdrop.Size = UDim2.fromScale(1, 1)
	backdrop.ZIndex = 1
	backdrop.Parent = screen

	--[[
		Холст стоит в центре экрана и двигается перетаскиванием. Масштаб делает
		UIScale, а не пересчёт координат: так меняется одно число, а не позиция
		каждого узла и каждой связи.
	]]
	local canvas = UiKit.Frame(backdrop, "Canvas")
	canvas.AnchorPoint = Vector2.new(0.5, 0.5)
	canvas.Position = UDim2.fromScale(0.5, 0.5)
	canvas.Size = UDim2.fromOffset(0, 0)
	canvas.ZIndex = 1

	local scale = Instance.new("UIScale")
	scale.Scale = 1
	scale.Parent = canvas

	--[[
		Три слоя рисуются в порядке создания: фон, связи, узлы. У соседей
		с одинаковым ZIndex порядок отрисовки задаёт порядок в детях, поэтому
		отдельные ZIndex здесь не нужны — нужен порядок вызовов ниже.
	]]
	local decor = UiKit.Frame(canvas, "Decor")
	decor.Size = UDim2.fromOffset(0, 0)

	local links = UiKit.Frame(canvas, "Links")
	links.Size = UDim2.fromOffset(0, 0)

	type LinkView = {
		frame: Frame,
		a: string,
		b: string,
		color: Color3,
		-- Длина запоминается при постройке: читать её обратно из AbsoluteSize
		-- значило бы считать длину через масштаб, который сам на неё влияет.
		length: number,
	}

	local linkViews: { LinkView } = {}
	local buttons: { [string]: TextButton } = {}
	local counters: { [string]: TextLabel } = {}
	local strokes: { [string]: UIStroke } = {}

	local latest: Types.TalentsView? = nil
	local essenceBalance = 0
	local selectedId: string? = nil

	--[[
		Всё, что не дерево, лежит поверх него отдельными полосами и ловит ввод
		само (Active): без этого узел, уехавший под шапку, оставался бы
		нажимаемым сквозь неё.

		ZIndex сравнивается только между соседями (ZIndexBehavior.Sibling),
		поэтому достаточно поднять сами полосы — их содержимое едет вместе
		с ними.
	]]
	local CHROME_MARGIN = 12

	local header = UiKit.Frame(backdrop, "Header", Palette.UI.background)
	header.Position = UDim2.fromOffset(CHROME_MARGIN, CHROME_MARGIN)
	header.Size = UDim2.new(1, -CHROME_MARGIN * 2, 0, 60)
	header.BackgroundTransparency = 0.35
	header.Active = true
	header.ZIndex = 5
	UiKit.Corners(header, 8)

	local title = UiKit.Label(header, "Title", "Talents", 24)
	title.Font = Enum.Font.GothamBold
	title.Position = UDim2.fromOffset(12, 6)
	title.Size = UDim2.new(1, -80, 0, 28)

	local subtitle = UiKit.Label(header, "Subtitle", "", 14, Palette.UI.subtext)
	subtitle.Position = UDim2.fromOffset(12, 34)
	subtitle.Size = UDim2.new(1, -80, 0, 20)

	local close = UiKit.Button(header, "Close", "X", Palette.UI.danger)
	close.AnchorPoint = Vector2.new(1, 0.5)
	close.Position = UDim2.new(1, -6, 0.5, 0)
	close.Size = UDim2.fromOffset(UiKit.ButtonHeight, UiKit.ButtonHeight)

	--[[
		Полоса подробностей вместо подписей под узлами. Пока ничего не выбрано,
		она объясняет, что делать: пустая полоса внизу экрана выглядела бы
		поломкой.
	]]
	local info = UiKit.Frame(backdrop, "Info", Palette.UI.background)
	info.AnchorPoint = Vector2.new(0, 1)
	info.Position = UDim2.new(0, CHROME_MARGIN, 1, -UiKit.ButtonHeight - CHROME_MARGIN * 2)
	info.Size = UDim2.new(1, -CHROME_MARGIN * 2, 0, INFO_HEIGHT)
	info.BackgroundTransparency = 0.35
	info.Active = true
	info.ZIndex = 5
	UiKit.Corners(info, 8)

	local infoTitle = UiKit.Label(info, "Title", "Tap a talent", 17)
	infoTitle.Font = Enum.Font.GothamBold
	infoTitle.Position = UDim2.fromOffset(10, 5)
	infoTitle.Size = UDim2.new(1, -20, 0, 20)

	local infoText = UiKit.Label(info, "Text", "Tapping an unlocked talent spends a point.", 13, Palette.UI.subtext)
	infoText.Position = UDim2.fromOffset(10, 25)
	infoText.Size = UDim2.new(1, -20, 0, 18)

	local footer = UiKit.Frame(backdrop, "Footer")
	footer.AnchorPoint = Vector2.new(0, 1)
	footer.Position = UDim2.new(0, CHROME_MARGIN, 1, -CHROME_MARGIN)
	footer.Size = UDim2.new(1, -CHROME_MARGIN * 2, 0, UiKit.ButtonHeight)
	footer.Active = true
	footer.ZIndex = 5

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
		Фон дерева: вложенные круги и радиальные разделители секторов.

		Круг — это квадрат со скруглением в половину стороны; сектор — тонкая
		полоска от внутреннего кольца к внешнему. Ни одного ассета: их у проекта
		нет, а диск с секторами узнаётся и так.
	]]
	local function buildDecor(): ()
		for index, radius in DISC_RADII do
			local size = radius * 2 * UNIT
			local circle = UiKit.Frame(decor, `Disc{index}`, Palette.Talents.disc)
			circle.AnchorPoint = Vector2.new(0.5, 0.5)
			circle.Position = UDim2.fromOffset(0, 0)
			circle.Size = UDim2.fromOffset(size, size)
			-- Каждое следующее кольцо светлее предыдущего: так видно, что ярусов
			-- три, даже когда узлы ещё не открыты.
			circle.BackgroundTransparency = 0.25 - index * 0.05
			UiKit.Corners(circle, size // 2)
		end

		local length = (SECTOR_OUTER - SECTOR_INNER) * UNIT
		local middle = (SECTOR_OUTER + SECTOR_INNER) * 0.5 * UNIT

		for index = 1, SECTOR_LINES do
			local angle = (index - 1) * (math.pi * 2 / SECTOR_LINES)
			local centre = Vector2.new(math.cos(angle), math.sin(angle)) * middle

			local line = UiKit.Frame(decor, `Sector{index}`, Palette.Talents.sector)
			line.AnchorPoint = Vector2.new(0.5, 0.5)
			line.Position = UDim2.fromOffset(centre.X, centre.Y)
			line.Size = UDim2.fromOffset(length, 2)
			line.Rotation = math.deg(angle)
			line.BackgroundTransparency = 0.5
		end
	end

	--[[
		Связи. Каждая — узкий прямоугольник, повёрнутый вдоль отрезка между
		узлами. Пара рисуется только в одну сторону: у соседей связь взаимная,
		и без этой проверки каждая линия рисовалась бы дважды.

		Цвет запоминается сразу, а зажигается при перерисовке: связь горит,
		когда вложены оба её конца, — это и есть пройденный путь.
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

				table.insert(linkViews, {
					frame = line,
					a = node.id,
					b = otherId,
					-- Стихийная связь горит цветом своей стихии, общая — медью.
					color = if node.element then nodeColor(node) else nodeColor(other),
					length = delta.Magnitude,
				})
			end
		end
	end

	local render: () -> ()

	-- Состояние узла: вложено ли, открыт ли, можно ли вложить ещё.
	local function stateOf(
		node: Types.TalentNode,
		spent: { [string]: number },
		points: number
	): (number, boolean, boolean)
		local invested = spent[node.id] or 0

		local unlocked = Talents.IsRoot(node.id) or invested > 0
		if not unlocked then
			for _, neighbourId in Talents.Neighbours(node.id) do
				if (spent[neighbourId] or 0) > 0 then
					unlocked = true
					break
				end
			end
		end

		return invested, unlocked, unlocked and points > 0 and invested < node.maxPoints
	end

	-- Срез, по которому считается состояние узлов. Пока он не пришёл, дерево
	-- рисуется пустым, а не гадает.
	local function currentState(): ({ [string]: number }, number)
		local view = latest
		return (if view then view.spent else {}), (if view then view.points else 0)
	end

	local renderInfo: () -> ()

	--[[
		Выделение. Переключает обводку у двух узлов и перерисовывает полосу
		внизу — и ничего больше.

		Полная перерисовка здесь была бы ошибкой: выделение меняется на каждом
		наведении мыши, а полный проход трогает полторы сотни узлов и две сотни
		связей. Сметённая через дерево мышь превратилась бы в подтормаживание
		на ровном месте.
	]]
	local function highlight(nodeId: string?): ()
		if selectedId == nodeId then
			return
		end

		local previous = if selectedId then strokes[selectedId] else nil
		if previous then
			previous.Enabled = false
		end

		selectedId = nodeId

		local current = if nodeId then strokes[nodeId] else nil
		if current then
			current.Enabled = true
		end

		renderInfo()
	end

	local function pick(node: Types.TalentNode): ()
		highlight(node.id)

		--[[
			Одно касание и выбирает, и вкладывает — но запрос уходит, только если
			клиент сам считает вложение возможным. Дело не в доверии к серверу
			(он проверит заново), а в лимите запросов: игрок, читающий дерево
			касаниями, выбрал бы его за пару секунд, и следующее НАСТОЯЩЕЕ
			вложение сервер отбросил бы как флуд.

			Перерисовывать дерево здесь незачем: вложение меняет состояние
			на сервере, и обратно оно приедет срезом, который и вызовет
			перерисовку.
		]]
		local spent, points = currentState()
		local _, _, canSpend = stateOf(node, spent, points)
		if canSpend then
			send("SpendTalent", node.id, nil)
		end
	end

	local function buildNodes(): ()
		for _, node in Talents.List do
			local position = node.position * UNIT
			local size = NODE_SIZE[node.kind]

			local button = UiKit.Button(canvas, `Node_{node.id}`, "", nodeColor(node))
			button.AnchorPoint = Vector2.new(0.5, 0.5)
			button.Position = UDim2.fromOffset(position.X, position.Y)
			button.Size = UDim2.fromOffset(size, size)
			button.Text = ""
			UiKit.Corners(button, size // 2)

			-- Обводка выбранного узла. Создаётся сразу выключенной: заводить
			-- объекты на ходу в чужом слое — это мигание при первом касании.
			local stroke = Instance.new("UIStroke")
			stroke.Color = Palette.UI.text
			stroke.Thickness = 2
			stroke.Enabled = false
			stroke.Parent = button

			--[[
				Счётчик только там, где очков больше одного. У точки он не нужен:
				залитая точка и есть «вложено», а цифра в кружке двадцати двух
				пикселей всё равно нечитаема.
			]]
			if node.maxPoints > 1 then
				local counter = UiKit.Label(button, "Counter", "0", 13, Palette.UI.background)
				counter.Font = Enum.Font.GothamBold
				counter.Size = UDim2.fromScale(1, 1)
				counter.TextXAlignment = Enum.TextXAlignment.Center
				counters[node.id] = counter
			end

			button.Activated:Connect(function()
				pick(node)
			end)

			--[[
				На мыши узел рассказывает о себе наведением — так дерево читается
				без единого клика. На телефоне события наведения не приходят,
				и там ту же работу делает касание.
			]]
			button.MouseEnter:Connect(function()
				highlight(node.id)
			end)

			buttons[node.id] = button
			strokes[node.id] = stroke
		end
	end

	--[[
		Полоса подробностей выбранного узла. Причина отказа пишется прямо здесь:
		узел, в который «почему-то нельзя», — это первый вопрос, который задаёт
		игрок, и ответ на него должен быть на экране, а не в сообщении, которое
		появится только после нажатия.
	]]
	renderInfo = function(): ()
		local spent, points = currentState()
		local id = selectedId
		local node = if id then Talents.ById[id] else nil

		if not node then
			infoTitle.Text = "Tap a talent"
			infoTitle.TextColor3 = Palette.UI.text
			infoText.Text = "Tapping an unlocked talent spends a point."
			return
		end

		local invested, unlocked, canSpend = stateOf(node, spent, points)

		local badge = if node.kind == "Keystone"
			then "  ·  Keystone"
			elseif node.kind == "Notable" then "  ·  Notable"
			else ""
		infoTitle.Text = `{node.displayName}  ·  {invested}/{node.maxPoints}{badge}`
		infoTitle.TextColor3 = nodeColor(node)

		local reason = if canSpend
			then ""
			elseif invested >= node.maxPoints then "  ·  maxed"
			elseif not unlocked then "  ·  locked: invest in a connected talent first"
			else "  ·  no points left"
		infoText.Text = `{effectText(node)}{reason}`
	end

	--[[
		Перекраска по состоянию. Три состояния и все три различимы без текста:
		вложенный узел горит полным цветом, доступный — приглушён, закрытый —
		почти прозрачен. Связь между двумя вложенными узлами зажигается тем же
		цветом — так виден пройденный маршрут, а не только его концы.
	]]
	render = function(): ()
		local view = latest
		local spent, points = currentState()

		if view then
			local progress = if view.xpToNext > 0 then `{view.xp}/{view.xpToNext} xp` else "max level"
			subtitle.Text = `Level {view.level}  ·  {progress}  ·  {points} points to spend`

			local cost = view.resetCost
			reset.Text = if cost > 0 then `Reset · {UiKit.FormatAmount(cost)}` else "Reset tree"
			UiKit.SetEnabled(reset, cost > 0 and essenceBalance >= cost)
		end

		for _, node in Talents.List do
			local button = buttons[node.id]
			if not button then
				continue
			end

			local invested, unlocked, canSpend = stateOf(node, spent, points)

			local counter = counters[node.id]
			if counter then
				counter.Text = tostring(invested)
				counter.TextTransparency = if invested > 0 then 0 else 0.55
			end

			if invested > 0 then
				button.BackgroundTransparency = 0
			elseif unlocked then
				button.BackgroundTransparency = 0.45
			else
				button.BackgroundTransparency = 0.82
			end

			button.AutoButtonColor = canSpend

			local stroke = strokes[node.id]
			if stroke then
				stroke.Enabled = node.id == selectedId
			end
		end

		for _, link in linkViews do
			local active = (spent[link.a] or 0) > 0 and (spent[link.b] or 0) > 0

			link.frame.BackgroundColor3 = if active then link.color else Palette.UI.panel
			link.frame.BackgroundTransparency = if active then 0.1 else 0.55
			link.frame.Size = UDim2.fromOffset(link.length, if active then LINK_ACTIVE_THICKNESS else LINK_THICKNESS)
		end

		renderInfo()
	end

	--[[
		Масштаб вокруг точки экрана: то, что было под курсором, под ним
		и остаётся.

		Без этого колесо утаскивало бы дерево от игрока: приблизить дальний
		сектор значило бы приблизить центр, а сектор при этом уехал бы за край.
		Холст стоит якорем в своей середине и размера не имеет, поэтому его
		AbsolutePosition — это и есть начало координат дерева на экране.
	]]
	local function zoomAt(target: number, focus: Vector2): ()
		local previous = scale.Scale
		local wanted = math.clamp(target, ZOOM_MIN, ZOOM_MAX)
		if math.abs(wanted - previous) < 1e-4 then
			return
		end

		local origin = canvas.AbsolutePosition
		local shift = (focus - origin) * (1 - wanted / previous)

		scale.Scale = wanted

		local position = canvas.Position
		canvas.Position =
			UDim2.new(position.X.Scale, position.X.Offset + shift.X, position.Y.Scale, position.Y.Offset + shift.Y)
	end

	--[[
		Размер экрана берётся у камеры, а не у фона: AbsoluteSize у ещё ни разу
		не показанного ScreenGui равен нулю, и первое открытие считало бы
		масштаб от пустоты.
	]]
	local function screenSize(): Vector2
		local camera = Workspace.CurrentCamera
		return if camera then camera.ViewportSize else Vector2.new(1280, 720)
	end

	local function screenCentre(): Vector2
		return screenSize() * 0.5
	end

	--[[
		Где сейчас курсор, в тех же координатах, что и AbsolutePosition.

		У СОБЫТИЯ КОЛЕСА ПОЗИЦИИ НЕТ: у MouseWheel в InputObject.Position лежит
		(0, 0, направление), и первая попытка масштабировать «в точку под
		курсором» брала её оттуда — то есть всегда левый верхний угол экрана,
		а проверка «курсор над деревом» никогда не проходила. Спрашивать надо
		у сервиса.

		Инсет прибавляется, потому что GetMouseLocation считает от области под
		верхней панелью Roblox, а наш ScreenGui её игнорирует и считает от самого
		верха экрана.
	]]
	local function cursorPosition(): Vector2
		return UserInputService:GetMouseLocation() + GuiService:GetGuiInset()
	end

	--[[
		Колесо мыши слушается у UserInputService, и это не первый подход.

		Через сам кадр не выйдет: колесо получает объект под курсором, а курсор
		над деревом почти всегда стоит над узлом. Через ContextActionService
		тоже не вышло: КОЛЕСО ЕМУ ПРИВЯЗАТЬ НЕЛЬЗЯ — BindAction принимает клавиши,
		кнопки мыши и геймпад, а MouseWheel в этот список не входит, и обработчик
		молча не вызывался ни разу.

		UserInputService событие отдаёт всегда, но перехватить его не может,
		поэтому камеру от колеса приходится защищать отдельно (см. lockCamera).
	]]
	UserInputService.InputChanged:Connect(function(input: InputObject)
		if not screen.Enabled or input.UserInputType ~= Enum.UserInputType.MouseWheel then
			return
		end

		zoomAt(scale.Scale + input.Position.Z * ZOOM_STEP, cursorPosition())
	end)

	--[[
		Пока дерево открыто, колесо не должно двигать камеру за спиной. Отнять
		у неё колесо нечем, поэтому у камеры отнимается сам диапазон: минимум
		и максимум приравниваются к текущему расстоянию, а при закрытии
		возвращаются как были.

		Порядок присваиваний важен в обе стороны: Roblox не даст поставить
		минимум больше максимума.
	]]
	local savedZoom: { min: number, max: number }? = nil

	local function lockCamera(): ()
		local camera = Workspace.CurrentCamera
		if savedZoom or not camera then
			return
		end

		local distance = math.clamp((camera.CFrame.Position - camera.Focus.Position).Magnitude, 0.5, 400)
		savedZoom = { min = player.CameraMinZoomDistance, max = player.CameraMaxZoomDistance }

		player.CameraMinZoomDistance = math.min(distance, player.CameraMaxZoomDistance)
		player.CameraMaxZoomDistance = distance
		player.CameraMinZoomDistance = distance
	end

	local function unlockCamera(): ()
		local saved = savedZoom
		if not saved then
			return
		end

		savedZoom = nil
		player.CameraMaxZoomDistance = saved.max
		player.CameraMinZoomDistance = saved.min
	end

	--[[
		Масштаб «дерево целиком». Считается от размера экрана, а не числом:
		экран у всех разный, а увидеть при открытии игрок должен одно и то же —
		весь диск и своё место на нём.

		Полосы сверху и снизу вычитаются из высоты: дерево под ними не спрячешь,
		и без этого верхний сектор всегда оказывался бы под шапкой.
	]]
	local function fitZoom(): number
		local size = screenSize()
		local usableHeight = size.Y - (60 + INFO_HEIGHT + UiKit.ButtonHeight + CHROME_MARGIN * 4)
		local usableWidth = size.X - CHROME_MARGIN * 2
		local span = DISC_RADII[1] * 2 * UNIT

		if span <= 0 or usableHeight <= 0 or usableWidth <= 0 then
			return ZOOM_MIN
		end

		return math.clamp(math.min(usableWidth, usableHeight) / span, ZOOM_MIN, ZOOM_MAX)
	end

	local function recenterCanvas(): ()
		canvas.Position = UDim2.fromScale(0.5, 0.5)
		scale.Scale = fitZoom()
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

	backdrop.InputBegan:Connect(function(input: InputObject)
		if
			input.UserInputType == Enum.UserInputType.MouseButton1
			or input.UserInputType == Enum.UserInputType.Touch
		then
			dragging = true
			dragStart = Vector2.new(input.Position.X, input.Position.Y)
			dragOrigin = canvas.Position
		end
	end)

	--[[
		Движение и отпускание слушаем у UserInputService, а не у кадра: курсор
		при перетаскивании легко уходит за границу области просмотра, и события
		кадра тогда не приходят вовсе — дерево замирало бы на полпути, а холст
		остался бы приклеенным к курсору навсегда.
	]]
	UserInputService.InputChanged:Connect(function(input: InputObject)
		if not dragging then
			return
		end

		if
			input.UserInputType == Enum.UserInputType.MouseMovement
			or input.UserInputType == Enum.UserInputType.Touch
		then
			moveDrag(input.Position)
		end
	end)

	UserInputService.InputEnded:Connect(function(input: InputObject)
		if
			input.UserInputType == Enum.UserInputType.MouseButton1
			or input.UserInputType == Enum.UserInputType.Touch
		then
			dragging = false
		end
	end)

	zoomIn.Activated:Connect(function()
		zoomAt(scale.Scale + ZOOM_STEP, screenCentre())
	end)

	zoomOut.Activated:Connect(function()
		zoomAt(scale.Scale - ZOOM_STEP, screenCentre())
	end)

	recenter.Activated:Connect(recenterCanvas)

	reset.Activated:Connect(function()
		send("ResetTalents", nil, nil)
	end)

	close.Activated:Connect(function()
		screen.Enabled = false
	end)

	--[[
		Замок камеры следит за самим экраном, а не за Open и Close: закрыть
		дерево можно ещё и крестиком, а этот путь идёт мимо панели. Замок,
		переживший закрытие, оставил бы игрока с намертво зафиксированной
		камерой до конца сессии.
	]]
	screen:GetPropertyChangedSignal("Enabled"):Connect(function()
		if screen.Enabled then
			lockCamera()
		else
			unlockCamera()
		end
	end)

	buildDecor()
	buildLinks()
	buildNodes()

	local panel: Panel = {
		Open = function()
			screen.Enabled = true
			-- Дерево всегда открывается от корня: игрок, ушедший в прошлый раз
			-- в дальний угол, иначе увидел бы пустоту и решил, что оно сломалось.
			recenterCanvas()
			render()
		end,

		Close = function()
			screen.Enabled = false
		end,

		Refresh = function(view: Types.TalentsView?, essence: number)
			latest = view
			essenceBalance = essence
			if screen.Enabled then
				render()
			end
		end,
	}

	return panel
end

return TalentsPanel
