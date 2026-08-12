--!strict
--[[
	Enemies — таблица врагов (раздел 3.5 ТЗ).

	Враг = архетип поведения × стихия × модификаторы. Уникальных мобов не рисуем:
	новый враг — это новая строка здесь, а не новый код.

	typeId проставляется автоматически по порядку записей: именно это число
	летит по сети одним байтом. Порядок записей менять нельзя — только дописывать
	в конец, иначе старые клиенты увидят не тех врагов.

	В M1 работают архетипы Chaser и Swarm; остальные появятся в M6 вместе с боссами.
]]

local Palette = require(script.Parent.Palette)
local Types = require(script.Parent.Parent.Types)

type EnemyDef = Types.EnemyDef

local Enemies = {}

--[[
	Сколько мелких деталей разрешено врагу сверх тела (Types.EnemyPart).

	Две. Это не круглое число, а замеренное: три сотни слизней с парой глаз
	каждый прошли живой забег без просадки, а четвёртой детали на врага
	никто не проверял.
]]
local MAX_PARTS = 2

local definitions: { EnemyDef } = {
	{
		key = "Slime",
		typeId = 0, -- проставляется ниже
		displayName = "Slime",
		archetype = "Chaser",
		element = "Nature",
		modifiers = {},
		stats = { health = 24, speed = 9, damage = 8, radius = 1.6, xp = 1 },
		--[[
			Слизни рисуются в стиле Slime King: приплюснутый полупрозрачный
			шар с чёрными глазами. Глаза — две отдельные детали сверх тела,
			то есть слизень занимает в BulkMoveTo три места вместо одного.
			Замерено на живом забеге: просадки нет (см. Types.EnemyPart).
		]]
		model = {
			size = Vector3.new(3.2, 2.4, 3.2),
			shape = "Ball",
			neon = false,
			palette = "SlimeSmall",
			transparency = 0.25,
			parts = {
				{
					shape = "Ball",
					size = Vector3.new(0.19, 0.25, 0.19),
					forward = 0.41,
					side = -0.21,
					height = 0.15,
					color = "eye",
				},
				{
					shape = "Ball",
					size = Vector3.new(0.19, 0.25, 0.19),
					forward = 0.41,
					side = 0.21,
					height = 0.15,
					color = "eye",
				},
			},
		},
	},
	{
		key = "Bat",
		typeId = 0,
		displayName = "Bat",
		archetype = "Swarm",
		element = "Dark",
		modifiers = { "Fast" },
		stats = { health = 14, speed = 15, damage = 6, radius = 1.2, xp = 1 },
		model = { size = Vector3.new(2.2, 1.6, 2.2), shape = "Ball", neon = false },
	},
	{
		key = "Ember",
		typeId = 0,
		displayName = "Ember",
		archetype = "Chaser",
		element = "Fire",
		modifiers = { "Tanky" },
		stats = { health = 60, speed = 7, damage = 14, radius = 2.1, xp = 3 },
		model = { size = Vector3.new(4, 3.4, 4), shape = "Block", neon = true },
	},

	--[[
		Лесная поляна: три вида слизней (M2+).

		Bat и Ember в новой раскладке локаций не участвуют — они остаются
		описанными на будущее. Удалять их нельзя в любом случае: typeId летит
		по сети байтом и определяется порядком записей, поэтому строки только
		дописываются в конец.
	]]
	{
		key = "BigSlime",
		typeId = 0,
		displayName = "Big Slime",
		archetype = "Chaser",
		element = "Nature",
		modifiers = { "Tanky" },
		stats = { health = 68, speed = 8, damage = 13, radius = 2.4, xp = 3 },
		model = {
			size = Vector3.new(4.6, 3.4, 4.6),
			shape = "Ball",
			neon = false,
			palette = "SlimeStrong",
			transparency = 0.25,
			parts = {
				{
					shape = "Ball",
					size = Vector3.new(0.19, 0.25, 0.19),
					forward = 0.41,
					side = -0.21,
					height = 0.15,
					color = "eye",
				},
				{
					shape = "Ball",
					size = Vector3.new(0.19, 0.25, 0.19),
					forward = 0.41,
					side = 0.21,
					height = 0.15,
					color = "eye",
				},
			},
		},
	},
	{
		key = "MegaSlime",
		typeId = 0,
		displayName = "Mega Slime",
		archetype = "Splitter",
		element = "Nature",
		modifiers = { "Tanky" },
		stats = { health = 180, speed = 6.5, damage = 18, radius = 3.4, xp = 8 },
		model = {
			size = Vector3.new(6.4, 4.8, 6.4),
			shape = "Ball",
			neon = false,
			palette = "SlimeGiant",
			transparency = 0.2,
			parts = {
				{
					shape = "Ball",
					size = Vector3.new(0.19, 0.25, 0.19),
					forward = 0.41,
					side = -0.21,
					height = 0.15,
					color = "eye",
				},
				{
					shape = "Ball",
					size = Vector3.new(0.19, 0.25, 0.19),
					forward = 0.41,
					side = 0.21,
					height = 0.15,
					color = "eye",
				},
			},
		},
		--[[
			Делится только от смерти УРОНОМ. Зачистка по потолку живых
			и принудительная уборка в конце фазы деления не вызывают: иначе
			освобождение места плодило бы врагов вместо того, чтобы освобождать.

			Распадается на КРЕПКИХ (зелёных), а не на мелких: смерть гиганта
			обязана оставлять после себя проблему, 48 здоровья осколками
			вместо 136 обесценили бы его целиком.
		]]
		splitInto = { key = "BigSlime", count = 2 },
	},

	--[[
		Дремучий лес: гоблины.

		Тёмная стихия — чтобы отличались цветом от зелёных слизней с первого
		взгляда: в толпе из трёхсот тел это единственное, что читается сразу.
	]]
	{
		key = "GoblinSwordsman",
		typeId = 0,
		displayName = "Goblin Swordsman",
		archetype = "Chaser",
		element = "Dark",
		modifiers = { "Fast" },
		-- Решение владельца: в полтора раза живучее и в полтора раза быстрее
		-- обычного слизня (24 здоровья и 9 скорости).
		stats = { health = 36, speed = 13.5, damage = 12, radius = 1.7, xp = 3 },
		--[[
			Три детали, как у слизня: туловище, голова и клинок.

			Туловище узкое и коричневое — это обноски. Цвет стихии тело
			больше не носит (см. Palette.Enemy.bodies): фиолетовый гоблин
			выглядел не гоблином. Зелёная голова связывает орду с шаманом,
			который её зовёт.

			Клинок торчит вбок и вперёд намеренно: у бегущей на тебя толпы
			силуэт читается по контуру, а меч, прижатый к телу, в контур
			не попадает вовсе.
		]]
		model = {
			size = Vector3.new(1.9, 3.6, 1.5),
			shape = "Block",
			neon = false,
			palette = "GoblinRags",
			parts = {
				{
					shape = "Ball",
					size = Vector3.new(1.05, 0.5, 1.05),
					forward = 0.08,
					side = 0,
					height = 0.55,
					color = "skin",
				},
				{
					shape = "Block",
					size = Vector3.new(0.19, 0.85, 0.19),
					forward = 0.3,
					side = 0.85,
					height = 0.1,
					angles = Vector3.new(-35, 0, -12),
					color = "steel",
				},
			},
		},
	},
	{
		key = "GoblinArcher",
		typeId = 0,
		displayName = "Goblin Archer",
		archetype = "Ranged",
		element = "Dark",
		modifiers = {},
		--[[
			Слабее и медленнее мечника: стрелок опасен дистанцией, а не телом.
			Опыта даёт больше — он и убивается труднее, потому что не подходит.
		]]
		-- Здоровье снижено решением владельца: стрелок и так неудобен тем,
		-- что не подходит, и умирать он должен быстро, когда до него дошли.
		stats = { health = 11, speed = 7, damage = 6, radius = 1.5, xp = 5 },
		--[[
			Те же три детали, но лук вместо клинка.

			ЛУК — КЛИН, А НЕ ПАЛКА. Тонкий брусок с любого расстояния читался
			палкой; клин, развёрнутый треугольной гранью к игроку, читается
			луком. Разворот на 90 по Y именно за этим: треугольные грани
			у клина смотрят вдоль его оси X, и без поворота игрок видел бы
			прямоугольный бок.

			Держит перед собой, а не над плечом: стрелок обязан отличаться
			от мечника силуэтом, а не только тем, что стоит дальше.
		]]
		model = {
			size = Vector3.new(1.7, 3.4, 1.4),
			shape = "Cylinder",
			neon = false,
			palette = "GoblinRags",
			parts = {
				{
					shape = "Ball",
					size = Vector3.new(1.1, 0.55, 1.1),
					forward = 0.08,
					side = 0,
					height = 0.56,
					color = "skin",
				},
				{
					shape = "Wedge",
					size = Vector3.new(0.25, 1, 0.85),
					forward = 0.7,
					side = 0.1,
					height = 0.05,
					angles = Vector3.new(0, 90, 0),
					color = "wood",
				},
			},
		},
		ranged = {
			range = 34,
			motionMargin = 8,
			cooldown = 2.6,
			-- Полсекунды на уход: трассер видно, и это честное окно.
			telegraph = 0.5,
			damage = 14,
			speed = 46,
			lifetime = 2.2,
			hitRadius = 1.4,
		},
	},
}

-- Список по typeId: List[typeId] -> определение. Индексация с 1.
Enemies.List = definitions

-- Быстрый доступ по строковому ключу (конфиг волн оперирует ключами).
Enemies.ByKey = {} :: { [string]: EnemyDef }

for index, def in definitions do
	def.typeId = index
	assert(Enemies.ByKey[def.key] == nil, `[Enemies] Дубликат ключа "{def.key}"`)
	Enemies.ByKey[def.key] = def
	table.freeze(def.stats)

	--[[
		Потолок деталей на врага. Не вкусовщина: три детали на тело — это
		ровно то, что замерено на живом забеге с тремя сотнями слизней.
		Четвёртая никем не проверена, и разрешать её тихо нельзя.
	]]
	local parts = def.model.parts
	if parts then
		assert(#parts <= MAX_PARTS, `[Enemies] У "{def.key}" деталей больше {MAX_PARTS}`)
		for slot, part in parts do
			assert(
				Palette.Detail[part.color] ~= nil,
				`[Enemies] "{def.key}", деталь {slot}: нет цвета "{part.color}" в Palette.Detail`
			)
			table.freeze(part)
		end
		table.freeze(parts)
	end

	table.freeze(def.model)
	table.freeze(def)
end

table.freeze(definitions)
table.freeze(Enemies.ByKey)

-- Санитарная проверка: typeId должен помещаться в один байт (формат пакета).
assert(#definitions <= 255, "[Enemies] Больше 255 типов врагов не влезет в байт typeId")

return Enemies
