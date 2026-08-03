--!strict
--[[
	Talents — древо талантов (раздел 6 ТЗ), M5.

	Узел — это данные: где нарисован, с кем соединён, сколько очков вмещает
	и что даёт. Логика рисования (панель) и применения (TalentService)
	написана один раз и о конкретных узлах не знает ничего.

	СТРУКТУРА. Корень в центре, от него шесть одинаковых по форме ветвей —
	по одной на стихию, — и кольцо общих узлов между ветвями. Ветви
	раскладываются по кругу кодом из одного шаблона: писать руками тридцать
	почти одинаковых записей при шести симметричных стихиях — это тот же
	хардкод, только длиннее, и первая же правка шаблона разошлась бы
	по пяти веткам из шести.

	Кольцо соединено со вторыми узлами соседних ветвей. Поэтому общие бонусы
	доступны не сразу, а после вложения в стихию, и заодно связывают ветви
	между собой — по дереву можно обойти круг, а не только ходить лучами.

	ПРАВИЛО ОТКРЫТИЯ (раздел 6 ТЗ): в узел можно вкладывать, только если
	он корневой или хотя бы у одного соседа уже вложено больше нуля.
	Проверяет это сервер; панель по тем же данным просто подсвечивает
	доступное.

	Публичный API:
		Talents.List                 -> { TalentNode }
		Talents.ById                 -> { [string]: TalentNode }
		Talents.Neighbours(id)       -> { string }
		Talents.IsRoot(id)           -> boolean
		Talents.RootId               -> string
]]

local Types = require(script.Parent.Parent.Types)

type Element = Types.Element
type TalentEffect = Types.TalentEffect
type TalentNode = Types.TalentNode

local Talents = {}

Talents.RootId = "Core"

--[[
	Порядок стихий задаёт и расположение ветвей по кругу, и цвета в панели.
	Он же используется в Config/Abilities и Config/Pets — список один на проект.
]]
local ELEMENTS: { Element } = { "Fire", "Ice", "Lightning", "Nature", "Dark", "Light" }

--[[
	Форма одной ветви: пять узлов подряд, от центра наружу.

	Чередование «урон — кулдаун — урон — кулдаун» намеренное: ветвь из одного
	вида эффекта — это не ветвь, а полоска, и выбор внутри неё отсутствует.
	Чем дальше от центра, тем крупнее шаг и тем меньше очков влезает —
	последние узлы должны быть целью, а не следующей клеткой.
]]
local BRANCH: { { suffix: string, name: string, maxPoints: number, effect: TalentEffect } } = {
	{ suffix = "1", name = "Spark", maxPoints = 5, effect = { kind = "ElementDamage", perPoint = 0.03 } },
	{ suffix = "2", name = "Flow", maxPoints = 3, effect = { kind = "ElementCooldown", perPoint = 0.02 } },
	{ suffix = "3", name = "Focus", maxPoints = 5, effect = { kind = "ElementDamage", perPoint = 0.05 } },
	{ suffix = "4", name = "Surge", maxPoints = 3, effect = { kind = "ElementCooldown", perPoint = 0.04 } },
	{ suffix = "5", name = "Mastery", maxPoints = 3, effect = { kind = "ElementDamage", perPoint = 0.08 } },
}

--[[
	Кольцо общих узлов. Их шесть по числу промежутков между ветвями,
	эффекты идут по кругу тройками, чтобы любой сектор дерева давал доступ
	ко всем трём общим характеристикам, а не только к одной.
]]
local RING: { { name: string, maxPoints: number, effect: TalentEffect } } = {
	{ name = "Vitality", maxPoints = 5, effect = { kind = "MaxHealth", perPoint = 8 } },
	{ name = "Swiftness", maxPoints = 4, effect = { kind = "WalkSpeed", perPoint = 0.5 } },
	{ name = "Greed", maxPoints = 4, effect = { kind = "MagnetRadius", perPoint = 1.5 } },
	{ name = "Vigor", maxPoints = 5, effect = { kind = "MaxHealth", perPoint = 8 } },
	{ name = "Haste", maxPoints = 4, effect = { kind = "WalkSpeed", perPoint = 0.5 } },
	{ name = "Reach", maxPoints = 4, effect = { kind = "MagnetRadius", perPoint = 1.5 } },
}

-- Радиус кольца между второй и третьей ступенями ветви: так оно рисуется
-- в промежутке, а не поверх узлов.
local RING_RADIUS = 2.5

local nodes: { TalentNode } = {}

Talents.ById = {} :: { [string]: TalentNode }

local function add(node: TalentNode): ()
	assert(Talents.ById[node.id] == nil, `[Talents] Дубликат узла "{node.id}"`)
	table.insert(nodes, node)
	Talents.ById[node.id] = node
end

--[[
	Корень. Один вложенный очко, маленький общий бонус — он нужен не ради
	цифры, а как единственная точка входа: без него правило «сосед должен быть
	открыт» не с чего было бы начать.
]]
add({
	id = Talents.RootId,
	displayName = "Core",
	element = nil,
	position = Vector2.zero,
	connections = {},
	maxPoints = 1,
	effect = { kind = "MaxHealth", perPoint = 10 },
})

local function branchId(element: Element, suffix: string): string
	return `{element}_{suffix}`
end

for index, element in ELEMENTS do
	local angle = (index - 1) * (math.pi * 2 / #ELEMENTS)
	local direction = Vector2.new(math.cos(angle), math.sin(angle))

	for step, entry in BRANCH do
		--[[
			Первый узел ветви цепляется к корню, остальные — к предыдущему.
			Связи задаются только «назад»: обратные достраиваются ниже, и так
			ни одну связь нельзя описать в одну сторону и забыть про другую.
		]]
		local previous = if step == 1 then Talents.RootId else branchId(element, BRANCH[step - 1].suffix)

		add({
			id = branchId(element, entry.suffix),
			displayName = `{element} {entry.name}`,
			element = element,
			position = direction * step,
			connections = { previous },
			maxPoints = entry.maxPoints,
			--[[
				Копия, а не ссылка на шаблон: шаблон один на шесть стихий,
				и подстановка по ссылке дала бы шести узлам общий объект.
				Валидатор ниже замораживает эффект каждого узла — на общей
				таблице второй же вызов table.freeze падает с ошибкой,
				а модуль, упавший при загрузке, роняет и сервер, и клиент.
			]]
			effect = { kind = entry.effect.kind, perPoint = entry.effect.perPoint },
		})
	end
end

for index, entry in RING do
	--[[
		Узел кольца стоит ровно между двумя ветвями и соединён со вторыми
		узлами обеих. Соседняя ветвь берётся по модулю, поэтому последний
		узел кольца замыкается на первую.
	]]
	local angle = ((index - 1) + 0.5) * (math.pi * 2 / #ELEMENTS)
	local left = ELEMENTS[index]
	local right = ELEMENTS[index % #ELEMENTS + 1]

	add({
		id = `Ring_{index}`,
		displayName = entry.name,
		element = nil,
		position = Vector2.new(math.cos(angle), math.sin(angle)) * RING_RADIUS,
		connections = { branchId(left, "2"), branchId(right, "2") },
		maxPoints = entry.maxPoints,
		-- Копия по той же причине, что и в ветвях: узел владеет своим эффектом.
		effect = { kind = entry.effect.kind, perPoint = entry.effect.perPoint },
	})
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
