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

local Types = require(script.Parent.Parent.Types)

type EnemyDef = Types.EnemyDef

local Enemies = {}

local definitions: { EnemyDef } = {
	{
		key = "Slime",
		typeId = 0, -- проставляется ниже
		displayName = "Slime",
		archetype = "Chaser",
		element = "Nature",
		modifiers = {},
		stats = { health = 24, speed = 9, damage = 8, radius = 1.6, xp = 1 },
		model = { size = Vector3.new(3.2, 2.4, 3.2), shape = "Block", neon = false },
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
		model = { size = Vector3.new(4.6, 3.4, 4.6), shape = "Block", neon = false },
	},
	{
		key = "MegaSlime",
		typeId = 0,
		displayName = "Mega Slime",
		archetype = "Splitter",
		element = "Nature",
		modifiers = { "Tanky" },
		stats = { health = 180, speed = 6.5, damage = 18, radius = 3.4, xp = 8 },
		model = { size = Vector3.new(6.4, 4.8, 6.4), shape = "Block", neon = false },
		--[[
			Делится только от смерти УРОНОМ. Зачистка по потолку живых
			и принудительная уборка в конце фазы деления не вызывают: иначе
			освобождение места плодило бы врагов вместо того, чтобы освобождать.
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
		model = { size = Vector3.new(2.6, 3.6, 2.6), shape = "Block", neon = false },
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
		model = { size = Vector3.new(2.2, 3.4, 2.2), shape = "Cylinder", neon = false },
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
	table.freeze(def.model)
	table.freeze(def)
end

table.freeze(definitions)
table.freeze(Enemies.ByKey)

-- Санитарная проверка: typeId должен помещаться в один байт (формат пакета).
assert(#definitions <= 255, "[Enemies] Больше 255 типов врагов не влезет в байт typeId")

return Enemies
