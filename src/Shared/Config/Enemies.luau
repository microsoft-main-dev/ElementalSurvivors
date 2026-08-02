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
