--!strict
--[[
	Talents — древо талантов (раздел 6 ТЗ), M5.

	Узел — это данные: где нарисован, с кем соединён, сколько очков вмещает
	и что даёт. Логика рисования (панель) и применения (TalentService)
	написана один раз и о конкретных узлах не знает ничего.

	СТРУКТУРА. Диск из шести секторов — по одному на стихию, — и четыре яруса
	от центра наружу:

		ядро                центр, единственная точка входа;
		входной кластер     r≈1.2, три узла своей стихии;
		магистраль          r=2.5…4.3, три общих узла лучом наружу;
		кольцо и мосты      r≈3.4 и 4.5, между секторами, общие бонусы;
		внешние созвездия   r≈5.2, двенадцать плотных гроздей — шесть стихийных
		                    по лучам и шесть общих между ними.

	Всё это генерируется из шаблонов. Писать сто пятьдесят почти одинаковых
	записей руками при шести симметричных стихиях — это тот же хардкод, только
	длиннее, и первая же правка шаблона разошлась бы по пяти секторам из шести.

	ФОРМА СОЗВЕЗДИЯ ОДНА НА ВСЕ ДВЕНАДЦАТЬ и поворачивается по сектору.
	Внутри неё есть кольца (два пути от входа к вершине), поэтому обходить
	созвездие можно с любой стороны, а не только по одной ветке.

	ЁМКОСТЬ ДЕРЕВА ВДВОЕ БОЛЬШЕ, ЧЕМ ОЧКОВ У СОТОГО УРОВНЯ. Это намеренно:
	дерево, которое можно набрать целиком, не требует ни одного решения.

	ПРАВИЛО ОТКРЫТИЯ (раздел 6 ТЗ): в узел можно вкладывать, только если
	он корневой или хотя бы у одного соседа уже вложено больше нуля.
	Проверяет это сервер; панель по тем же данным просто подсвечивает
	доступное.

	ЧИСЛА ЗДЕСЬ ЧЕРНОВЫЕ. Эффекты вписаны по аналогии с прежним деревом
	и по калибру узла (точка / крупный / ключевой) — их предстоит покрутить
	отдельным балансным проходом.

	Публичный API:
		Talents.List                 -> { TalentNode }
		Talents.ById                 -> { [string]: TalentNode }
		Talents.Neighbours(id)       -> { string }
		Talents.IsRoot(id)           -> boolean
		Talents.RootId               -> string
]]

local Elements = require(script.Parent.Elements)
local Types = require(script.Parent.Parent.Types)

type Element = Types.Element
type TalentEffect = Types.TalentEffect
type TalentNode = Types.TalentNode
type TalentNodeKind = Types.TalentNodeKind

local Talents = {}

Talents.RootId = "Core"

-- Порядок стихий задаёт расположение секторов по кругу. Список один на проект.
local ELEMENTS: { Element } = Elements.List
local SECTORS = #ELEMENTS

--[[
	Сколько очков вмещает узел своего калибра.

	Точка — одно очко: именно из-за этого дерево становится про маршрут,
	а не про то, в какой узел вылить всё разом. Крупные и ключевые вмещают
	больше, чтобы у пути была цель.
]]
local CAPACITY: { [TalentNodeKind]: number } = {
	Minor = 1,
	Notable = 2,
	Keystone = 3,
}

local nodes: { TalentNode } = {}

Talents.ById = {} :: { [string]: TalentNode }

--[[
	Эффект всегда копируется, а не подставляется ссылкой из шаблона: шаблон один
	на двенадцать созвездий, а валидатор ниже замораживает эффект КАЖДОГО узла.
	Повторный table.freeze на уже замороженной таблице — ошибка, которая роняет
	модуль при загрузке, а вместе с ним сервер и клиент разом. На этом уже
	наступались.
]]
local function add(
	id: string,
	displayName: string,
	element: Element?,
	kind: TalentNodeKind,
	position: Vector2,
	connections: { string },
	effect: TalentEffect
): ()
	assert(Talents.ById[id] == nil, `[Talents] Дубликат узла "{id}"`)

	local node: TalentNode = {
		id = id,
		displayName = displayName,
		element = element,
		kind = kind,
		position = position,
		connections = connections,
		maxPoints = CAPACITY[kind],
		effect = { kind = effect.kind, perPoint = effect.perPoint },
	}

	table.insert(nodes, node)
	Talents.ById[id] = node
end

--[[
	Точка сектора в полярных координатах.

	radial — насколько далеко от центра, tangential — насколько вбок поперёк
	луча. Вся геометрия дерева описана в этих двух числах, потому что все ярусы
	и созвездия — это одно и то же, повёрнутое на свой сектор.
]]
local function place(angle: number, radial: number, tangential: number): Vector2
	local out = Vector2.new(math.cos(angle), math.sin(angle))
	local side = Vector2.new(-math.sin(angle), math.cos(angle))
	return out * radial + side * tangential
end

--[[
	=== ЯДРО ===

	Одно очко и маленький общий бонус. Он нужен не ради цифры, а как
	единственная точка входа: без него правилу «сосед должен быть открыт»
	не с чего было бы начаться.
]]
add(Talents.RootId, "Core", nil, "Keystone", Vector2.zero, {}, { kind = "MaxHealth", perPoint = 10 })

--[[
	=== ВХОДНОЙ КЛАСТЕР СТИХИИ ===

	Три узла сразу за ядром: два дешёвых расходятся от корня и сходятся
	в крупном. Развилка с самого начала — это первое решение игрока
	(урон или темп), и она же делает центр дерева похожим на центр, а не
	на шесть одинаковых палок.
]]
local GATE: { { suffix: string, name: string, kind: TalentNodeKind, radial: number, tangential: number, effect: TalentEffect } } =
	{
		--[[
			Развилка стоит узко и подальше от ядра не случайно: у соседних
			секторов эти узлы ближе всего друг к другу во всём дереве, и при
			развороте пошире они начинали соприкасаться на стыке секторов.
		]]
		{
			suffix = "Gate1",
			name = "Spark",
			kind = "Minor",
			radial = 1.15,
			tangential = -0.3,
			effect = { kind = "ElementDamage", perPoint = 0.02 },
		},
		{
			suffix = "Gate2",
			name = "Flow",
			kind = "Minor",
			radial = 1.15,
			tangential = 0.3,
			effect = { kind = "ElementCooldown", perPoint = 0.015 },
		},
		{
			suffix = "Gate3",
			name = "Focus",
			kind = "Notable",
			radial = 1.75,
			tangential = 0,
			effect = { kind = "ElementDamage", perPoint = 0.05 },
		},
	}

--[[
	=== МАГИСТРАЛЬ ===

	Общие бонусы лучом наружу. Стихийных узлов здесь нет намеренно: магистраль —
	это дорога к внешнему созвездию, и платить за неё игрок должен тем, что
	полезно любому билду.
]]
local PATH: { { suffix: string, name: string, kind: TalentNodeKind, radial: number, effect: TalentEffect } } = {
	{ suffix = "Path1", name = "Grit", kind = "Minor", radial = 2.5, effect = { kind = "MaxHealth", perPoint = 6 } },
	{
		suffix = "Path2",
		name = "Stride",
		kind = "Minor",
		radial = 3.4,
		effect = { kind = "WalkSpeed", perPoint = 0.4 },
	},
	{
		suffix = "Path3",
		name = "Bulwark",
		kind = "Notable",
		radial = 4.3,
		effect = { kind = "MaxHealth", perPoint = 12 },
	},
}

--[[
	=== КОЛЬЦО МЕЖДУ СЕКТОРАМИ ===

	Крупный общий узел в каждом промежутке, соединённый со вторыми узлами обеих
	соседних магистралей. Отсюда же уходит мост к общему созвездию. Эффекты идут
	по кругу тройками, чтобы любая часть дерева давала доступ ко всем трём общим
	характеристикам, а не только к одной.
]]
local RING: { { name: string, effect: TalentEffect } } = {
	{ name = "Vitality", effect = { kind = "MaxHealth", perPoint = 10 } },
	{ name = "Swiftness", effect = { kind = "WalkSpeed", perPoint = 0.7 } },
	{ name = "Greed", effect = { kind = "MagnetRadius", perPoint = 2.2 } },
	{ name = "Vigor", effect = { kind = "MaxHealth", perPoint = 10 } },
	{ name = "Haste", effect = { kind = "WalkSpeed", perPoint = 0.7 } },
	{ name = "Reach", effect = { kind = "MagnetRadius", perPoint = 2.2 } },
}

local RING_RADIAL = 3.4
local BRIDGE_RADIAL = 4.5

--[[
	=== СОЗВЕЗДИЕ ===

	Форма внешней грозди: девять узлов, вход снизу, ключевой на вершине.
	Два пути от входа к вершине — левый и правый, — поэтому гроздь можно
	обойти с любой стороны, и «дойти до ключевого» не означает «вложить всё».

	Координаты локальные: x — наружу от центра дерева, y — вбок. Одна форма
	на все двенадцать гроздей; различаются они только поворотом и эффектами.
]]
local CONSTELLATION: { { key: string, kind: TalentNodeKind, radial: number, tangential: number } } = {
	{ key = "a", kind = "Minor", radial = 0, tangential = 0 },
	{ key = "b", kind = "Minor", radial = 0.55, tangential = -0.55 },
	{ key = "c", kind = "Minor", radial = 0.55, tangential = 0.55 },
	{ key = "d", kind = "Minor", radial = 1.15, tangential = -0.95 },
	{ key = "e", kind = "Notable", radial = 1.15, tangential = 0 },
	{ key = "f", kind = "Minor", radial = 1.15, tangential = 0.95 },
	{ key = "g", kind = "Minor", radial = 1.8, tangential = -0.55 },
	{ key = "h", kind = "Minor", radial = 1.8, tangential = 0.55 },
	{ key = "i", kind = "Keystone", radial = 2.4, tangential = 0 },
}

local CONSTELLATION_LINKS: { { string } } = {
	{ "a", "b" },
	{ "a", "c" },
	{ "b", "d" },
	{ "b", "e" },
	{ "c", "e" },
	{ "c", "f" },
	{ "d", "g" },
	{ "e", "g" },
	{ "e", "h" },
	{ "f", "h" },
	{ "g", "i" },
	{ "h", "i" },
}

local CLUSTER_RADIAL = 5.2

--[[
	Что даёт каждый узел стихийного созвездия. Порядок тот же, что в форме:
	дешёвые точки по краям, крупный в середине, ключевой на вершине.

	Урон и кулдаун чередуются: гроздь из одного вида эффекта — это не гроздь,
	а полоска, и выбор внутри неё отсутствует.
]]
local ELEMENT_SLOTS: { [string]: { name: string, effect: TalentEffect } } = {
	a = { name = "Ember", effect = { kind = "ElementDamage", perPoint = 0.03 } },
	b = { name = "Drift", effect = { kind = "ElementCooldown", perPoint = 0.02 } },
	c = { name = "Edge", effect = { kind = "ElementDamage", perPoint = 0.03 } },
	d = { name = "Pulse", effect = { kind = "ElementCooldown", perPoint = 0.025 } },
	e = { name = "Heart", effect = { kind = "ElementDamage", perPoint = 0.07 } },
	f = { name = "Rush", effect = { kind = "ElementCooldown", perPoint = 0.025 } },
	g = { name = "Fang", effect = { kind = "ElementDamage", perPoint = 0.04 } },
	h = { name = "Tide", effect = { kind = "ElementDamage", perPoint = 0.04 } },
	i = { name = "Mastery", effect = { kind = "ElementDamage", perPoint = 0.1 } },
}

--[[
	То же для общих созвездий. Наборов три, и они чередуются по промежуткам:
	шесть одинаковых гроздей вокруг дерева означали бы, что общая половина
	дерева — это один и тот же узел, размноженный шесть раз.
]]
local GENERAL_SETS: { { [string]: { name: string, effect: TalentEffect } } } = {
	{
		a = { name = "Nerve", effect = { kind = "MaxHealth", perPoint = 7 } },
		b = { name = "Hide", effect = { kind = "MaxHealth", perPoint = 7 } },
		c = { name = "Pace", effect = { kind = "WalkSpeed", perPoint = 0.4 } },
		d = { name = "Draw", effect = { kind = "MagnetRadius", perPoint = 1.2 } },
		e = { name = "Bastion", effect = { kind = "MaxHealth", perPoint = 16 } },
		f = { name = "Step", effect = { kind = "WalkSpeed", perPoint = 0.4 } },
		g = { name = "Guard", effect = { kind = "MaxHealth", perPoint = 9 } },
		h = { name = "Sprint", effect = { kind = "WalkSpeed", perPoint = 0.5 } },
		i = { name = "Fortress", effect = { kind = "MaxHealth", perPoint = 24 } },
	},
	{
		a = { name = "Gait", effect = { kind = "WalkSpeed", perPoint = 0.4 } },
		b = { name = "Dash", effect = { kind = "WalkSpeed", perPoint = 0.4 } },
		c = { name = "Grasp", effect = { kind = "MagnetRadius", perPoint = 1.2 } },
		d = { name = "Brace", effect = { kind = "MaxHealth", perPoint = 7 } },
		e = { name = "Tempo", effect = { kind = "WalkSpeed", perPoint = 1 } },
		f = { name = "Pull", effect = { kind = "MagnetRadius", perPoint = 1.4 } },
		g = { name = "Bound", effect = { kind = "WalkSpeed", perPoint = 0.5 } },
		h = { name = "Reap", effect = { kind = "MagnetRadius", perPoint = 1.6 } },
		i = { name = "Windrunner", effect = { kind = "WalkSpeed", perPoint = 1.6 } },
	},
	{
		a = { name = "Scoop", effect = { kind = "MagnetRadius", perPoint = 1.2 } },
		b = { name = "Sweep", effect = { kind = "MagnetRadius", perPoint = 1.2 } },
		c = { name = "Heft", effect = { kind = "MaxHealth", perPoint = 7 } },
		d = { name = "Trot", effect = { kind = "WalkSpeed", perPoint = 0.4 } },
		e = { name = "Harvest", effect = { kind = "MagnetRadius", perPoint = 3 } },
		f = { name = "Gather", effect = { kind = "MagnetRadius", perPoint = 1.4 } },
		g = { name = "Sift", effect = { kind = "MagnetRadius", perPoint = 1.6 } },
		h = { name = "Toil", effect = { kind = "MaxHealth", perPoint = 9 } },
		i = { name = "Hoard", effect = { kind = "MagnetRadius", perPoint = 4.5 } },
	},
}

--[[
	Собрать созвездие: девять узлов формы, повёрнутых на угол, плюс их
	внутренние связи. entry — с чем соединён входной узел «a».
]]
local function addConstellation(
	prefix: string,
	element: Element?,
	angle: number,
	baseRadial: number,
	entry: string,
	slots: { [string]: { name: string, effect: TalentEffect } }
): ()
	local function slotId(key: string): string
		return `{prefix}_{key}`
	end

	for _, point in CONSTELLATION do
		local slot = slots[point.key]
		assert(slot, `[Talents] У созвездия "{prefix}" нет описания для узла "{point.key}"`)

		--[[
			Связи описываются только «назад», и у входного узла назад — это
			магистраль. Остальные связи созвездия добавляются отдельным проходом
			ниже: описывать их в двух местах значило бы однажды описать одну
			из них дважды, а другую забыть.
		]]
		local connections = if point.key == "a" then { entry } else {}
		local name = if element then `{element} {slot.name}` else slot.name

		add(
			slotId(point.key),
			name,
			element,
			point.kind,
			place(angle, baseRadial + point.radial, point.tangential),
			connections,
			slot.effect
		)
	end

	for _, pair in CONSTELLATION_LINKS do
		local node = Talents.ById[slotId(pair[2])]
		assert(
			node,
			`[Talents] Созвездие "{prefix}" ссылается на несуществующий узел "{pair[2]}"`
		)
		table.insert(node.connections, slotId(pair[1]))
	end
end

--[[
	=== СБОРКА ===
]]
local function nodeId(element: Element, suffix: string): string
	return `{element}_{suffix}`
end

for index, element in ELEMENTS do
	local angle = (index - 1) * (math.pi * 2 / SECTORS)

	-- Входной кластер: первые два цепляются к ядру, третий собирает оба.
	for step, entry in GATE do
		local connections = if step == 3
			then { nodeId(element, "Gate1"), nodeId(element, "Gate2") }
			else { Talents.RootId }

		add(
			nodeId(element, entry.suffix),
			`{element} {entry.name}`,
			element,
			entry.kind,
			place(angle, entry.radial, entry.tangential),
			connections,
			entry.effect
		)
	end

	-- Магистраль: первый узел цепляется к крупному узлу входного кластера.
	for step, entry in PATH do
		local previous = if step == 1 then nodeId(element, "Gate3") else nodeId(element, PATH[step - 1].suffix)

		add(
			nodeId(element, entry.suffix),
			entry.name,
			nil,
			entry.kind,
			place(angle, entry.radial, 0),
			{ previous },
			entry.effect
		)
	end

	-- Стихийное созвездие на конце магистрали.
	addConstellation(nodeId(element, "Star"), element, angle, CLUSTER_RADIAL, nodeId(element, "Path3"), ELEMENT_SLOTS)
end

for index, entry in RING do
	--[[
		Узел кольца стоит ровно между двумя секторами и соединён со вторыми
		узлами обеих магистралей. Соседний сектор берётся по модулю, поэтому
		последний узел кольца замыкается на первый.
	]]
	local angle = ((index - 1) + 0.5) * (math.pi * 2 / SECTORS)
	local left = ELEMENTS[index]
	local right = ELEMENTS[index % SECTORS + 1]

	local ringId = `Ring{index}`
	local bridgeId = `Bridge{index}`

	add(
		ringId,
		entry.name,
		nil,
		"Notable",
		place(angle, RING_RADIAL, 0),
		{ nodeId(left, "Path2"), nodeId(right, "Path2") },
		entry.effect
	)

	--[[
		Мост от кольца к общему созвездию. Он же — та самая длинная спица
		между секторами: без него гроздь висела бы вплотную к кольцу,
		и промежуток между секторами перестал бы читаться.
	]]
	add(
		bridgeId,
		"Trail",
		nil,
		"Minor",
		place(angle, BRIDGE_RADIAL, 0),
		{ ringId },
		{ kind = "MagnetRadius", perPoint = 1.2 }
	)

	addConstellation(
		`Gap{index}`,
		nil,
		angle,
		CLUSTER_RADIAL + 0.6,
		bridgeId,
		GENERAL_SETS[(index - 1) % #GENERAL_SETS + 1]
	)
end

--[[
	Достраиваем обратные связи и складываем всё в одну таблицу соседей.

	Связи в дереве двусторонние по смыслу: если из A можно дойти до B, значит
	и из B до A. Описывать их дважды руками — это гарантированная рассинхронизация,
	поэтому в данных каждая связь записана один раз, а зеркальная строится здесь.
]]
local neighbours: { [string]: { string } } = {}

for _, node in nodes do
	neighbours[node.id] = neighbours[node.id] or {}
end

for _, node in nodes do
	for _, otherId in node.connections do
		local other = Talents.ById[otherId]
		assert(other, `[Talents] Узел "{node.id}" ссылается на несуществующий "{otherId}"`)

		if not table.find(neighbours[node.id], otherId) then
			table.insert(neighbours[node.id], otherId)
		end
		if not table.find(neighbours[otherId], node.id) then
			table.insert(neighbours[otherId], node.id)
		end
	end
end

--[[
	Дерево обязано быть связным: узел, до которого нельзя дойти от корня,
	недостижим навсегда — правило открытия не даст в него вложить ни очка.
	Такую ошибку в данных без проверки заметить невозможно, поэтому
	обход в ширину выполняется прямо при загрузке.
]]
do
	local seen: { [string]: boolean } = { [Talents.RootId] = true }
	local queue: { string } = { Talents.RootId }
	local head = 1
	local reached = 1

	while head <= #queue do
		local current = queue[head]
		head += 1

		for _, neighbourId in neighbours[current] do
			if not seen[neighbourId] then
				seen[neighbourId] = true
				reached += 1
				table.insert(queue, neighbourId)
			end
		end
	end

	assert(
		reached == #nodes,
		`[Talents] Дерево несвязно: от корня достижимо {reached} узлов из {#nodes}`
	)
end

for _, node in nodes do
	assert(node.maxPoints > 0, `[Talents] У "{node.id}" maxPoints должен быть больше нуля`)
	assert(node.effect.perPoint > 0, `[Talents] У "{node.id}" perPoint должен быть больше нуля`)

	local kind = node.effect.kind
	local needsElement = kind == "ElementDamage" or kind == "ElementCooldown"
	assert(
		not needsElement or node.element ~= nil,
		`[Talents] У "{node.id}" эффект {kind} без стихии: усиливать было бы нечего`
	)

	table.freeze(node.effect)
	table.freeze(node.connections)
	table.freeze(node)
	table.freeze(neighbours[node.id])
end

Talents.List = nodes

function Talents.Neighbours(id: string): { string }
	return neighbours[id] or {}
end

function Talents.IsRoot(id: string): boolean
	return id == Talents.RootId
end

table.freeze(nodes)
table.freeze(Talents.ById)
table.freeze(neighbours)

return Talents
