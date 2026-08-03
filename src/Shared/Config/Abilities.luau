--!strict
--[[
	Abilities — таблица способностей (раздел 3.4 ТЗ).

	Логика формы (shape) написана один раз в AbilityService. Новая способность —
	это новая запись здесь и ни одной строки кода. Именно это проверяется
	на приёмке M2.

	typeId проставляется по порядку записей и летит по сети одним байтом.
	Порядок менять нельзя — только дописывать в конец.

	Какие поля нужны какой форме:
		Orbit      count, radius, hitRadius, angularSpeed, damage, cooldown
		Projectile count, speed, lifetime, pierce, hitRadius, damage, cooldown
		Aura       radius, damage, cooldown
		Nova       radius, damage, cooldown

	Соответствие проверяет валидатор внизу файла: если у формы не хватает поля,
	сервер упадёт при старте с понятным сообщением, а не молча промахнётся.
]]

local Types = require(script.Parent.Parent.Types)

type AbilityDef = Types.AbilityDef
type AbilityShape = Types.AbilityShape

local Abilities = {}

local definitions: { AbilityDef } = {
	{
		key = "FireOrbit",
		typeId = 0,
		displayName = "Fire Halo",
		description = "Burning orbs circle around you.",
		element = "Fire",
		shape = "Orbit",
		levels = {
			{ damage = 11, cooldown = 0.5, count = 1, radius = 9, hitRadius = 3.2, angularSpeed = 2.2 },
			{ damage = 15, cooldown = 0.5, count = 2, radius = 9, hitRadius = 3.2, angularSpeed = 2.4 },
			{ damage = 20, cooldown = 0.45, count = 2, radius = 11, hitRadius = 3.6, angularSpeed = 2.6 },
			{ damage = 26, cooldown = 0.45, count = 3, radius = 11, hitRadius = 3.6, angularSpeed = 2.8 },
			{ damage = 34, cooldown = 0.4, count = 4, radius = 12, hitRadius = 4, angularSpeed = 3 },
		},
	},
	{
		key = "IceShard",
		typeId = 0,
		displayName = "Ice Shard",
		description = "Fires a piercing shard at the nearest enemy.",
		element = "Ice",
		shape = "Projectile",
		levels = {
			{ damage = 18, cooldown = 1.1, count = 1, speed = 75, lifetime = 1.3, pierce = 1, hitRadius = 2 },
			{ damage = 24, cooldown = 1, count = 1, speed = 80, lifetime = 1.3, pierce = 2, hitRadius = 2 },
			{ damage = 30, cooldown = 0.9, count = 2, speed = 85, lifetime = 1.4, pierce = 2, hitRadius = 2.2 },
			{ damage = 38, cooldown = 0.85, count = 2, speed = 90, lifetime = 1.4, pierce = 3, hitRadius = 2.4 },
			{ damage = 48, cooldown = 0.75, count = 3, speed = 95, lifetime = 1.5, pierce = 4, hitRadius = 2.6 },
		},
	},
	{
		key = "ThornAura",
		typeId = 0,
		displayName = "Thorn Aura",
		description = "Everything close to you keeps taking damage.",
		element = "Nature",
		shape = "Aura",
		levels = {
			{ damage = 6, cooldown = 0.6, radius = 12 },
			{ damage = 8, cooldown = 0.6, radius = 14 },
			{ damage = 11, cooldown = 0.55, radius = 16 },
			{ damage = 14, cooldown = 0.5, radius = 18 },
			{ damage = 18, cooldown = 0.45, radius = 21 },
		},
	},
	{
		key = "StormNova",
		typeId = 0,
		displayName = "Storm Nova",
		description = "A shockwave bursts out from you.",
		element = "Lightning",
		shape = "Nova",
		levels = {
			{ damage = 22, cooldown = 3, radius = 17 },
			{ damage = 30, cooldown = 2.8, radius = 20 },
			{ damage = 39, cooldown = 2.6, radius = 23 },
			{ damage = 50, cooldown = 2.3, radius = 27 },
			{ damage = 64, cooldown = 2, radius = 31 },
		},
	},
	{
		key = "ShadowNeedle",
		typeId = 0,
		displayName = "Shadow Needles",
		description = "A volley of fast needles at nearby enemies.",
		element = "Dark",
		shape = "Projectile",
		levels = {
			{ damage = 9, cooldown = 0.95, count = 2, speed = 100, lifetime = 0.9, pierce = 1, hitRadius = 1.6 },
			{ damage = 11, cooldown = 0.9, count = 3, speed = 100, lifetime = 0.9, pierce = 1, hitRadius = 1.6 },
			{ damage = 14, cooldown = 0.85, count = 4, speed = 105, lifetime = 1, pierce = 1, hitRadius = 1.8 },
			{ damage = 18, cooldown = 0.8, count = 5, speed = 110, lifetime = 1, pierce = 2, hitRadius = 1.8 },
			{ damage = 23, cooldown = 0.7, count = 6, speed = 115, lifetime = 1.1, pierce = 2, hitRadius = 2 },
		},
	},
	{
		key = "LightBurst",
		typeId = 0,
		displayName = "Light Burst",
		description = "A rare but devastating flash of light.",
		element = "Light",
		shape = "Nova",
		levels = {
			{ damage = 34, cooldown = 4.5, radius = 11 },
			{ damage = 46, cooldown = 4.2, radius = 13 },
			{ damage = 60, cooldown = 3.9, radius = 15 },
			{ damage = 78, cooldown = 3.6, radius = 17 },
			{ damage = 100, cooldown = 3.2, radius = 19 },
		},
	},
}

Abilities.List = definitions
Abilities.ByKey = {} :: { [string]: AbilityDef }

-- Какие поля обязаны быть у каждой формы.
local REQUIRED_FIELDS: { [AbilityShape]: { string } } = {
	Orbit = { "count", "radius", "hitRadius", "angularSpeed" },
	Projectile = { "count", "speed", "lifetime", "pierce", "hitRadius" },
	Aura = { "radius" },
	Nova = { "radius" },
	Cone = { "radius" },
	Chain = { "radius" },
}

for index, def in definitions do
	def.typeId = index
	assert(Abilities.ByKey[def.key] == nil, `[Abilities] Дубликат ключа "{def.key}"`)
	Abilities.ByKey[def.key] = def

	assert(
		#def.levels == 5,
		`[Abilities] У "{def.key}" должно быть ровно 5 уровней, а не {#def.levels}`
	)

	local required = REQUIRED_FIELDS[def.shape]
	assert(required, `[Abilities] У "{def.key}" неизвестная форма "{def.shape}"`)

	for level, data in def.levels do
		assert(
			data.damage > 0,
			`[Abilities] "{def.key}" уровень {level}: damage должен быть больше нуля`
		)
		assert(
			data.cooldown > 0,
			`[Abilities] "{def.key}" уровень {level}: cooldown должен быть больше нуля`
		)
		for _, field in required do
			assert(
				(data :: any)[field] ~= nil,
				`[Abilities] "{def.key}" уровень {level}: форме {def.shape} нужно поле "{field}"`
			)
		end
		table.freeze(data)
	end

	table.freeze(def.levels)
	table.freeze(def)
end

table.freeze(definitions)
table.freeze(Abilities.ByKey)

assert(
	#definitions <= 255,
	"[Abilities] Больше 255 способностей не влезет в байт typeId"
)

return Abilities
