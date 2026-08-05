--!strict
--[[
	Abilities — таблица способностей (раздел 3.4 ТЗ).

	Логика формы (shape) написана один раз в AbilityService. Новая способность —
	это новая запись здесь и ни одной строки кода.

	typeId проставляется по порядку записей и летит по сети одним байтом.
	Порядок менять нельзя — только дописывать в конец.

	ДЕВЯТЬ УРОВНЕЙ ФОРМУЛОЙ, А НЕ ТАБЛИЦЕЙ

	Раньше у каждой способности лежали пять строк характеристик. Девять уровней
	на полтора десятка способностей — это полторы сотни строк, которые надо
	держать согласованными руками. Поэтому способность описывается тремя вещами:

		base      — характеристики первого уровня;
		growth    — множители за ОБЫЧНЫЙ уровень (урон вверх, кулдаун вниз);
		milestone — что даёт КАЖДЫЙ ТРЕТИЙ уровень (3, 6, 9).

	Обычный уровень крутится редкостью карточки (Config/Cards), рубеж — никогда:
	«+1 снаряд» обязан быть одинаковым у всех, иначе главное, ради чего качают
	способность, становится лотереей.

	Какие поля нужны какой форме:
		Orbit      count, radius, hitRadius, angularSpeed, damage, cooldown
		Projectile count, speed, lifetime, pierce, hitRadius, damage, cooldown
		Aura       radius, damage, cooldown
		Nova       radius, damage, cooldown
		Cone       radius (длина), angle (ширина клина), damage, cooldown
		Chain      radius (дальность прыжка), count (звенья), falloff, damage, cooldown

	Соответствие проверяет валидатор внизу файла: если у формы не хватает поля,
	сервер упадёт при старте с понятным сообщением, а не молча промахнётся.

	Публичный API:
		Abilities.List / Abilities.ByKey / Abilities.BaseList
		Abilities.IsMilestone(level)             -> boolean
		Abilities.NextMilestone(level)           -> number
		Abilities.Stats(def, bonuses)            -> AbilityLevel
		Abilities.ApplyUpgrade(def, level, mult, bonuses)
		Abilities.NewBonuses()                   -> AbilityBonuses
		Abilities.UpgradeText(def, level, mult)  -> string
]]

local Balance = require(script.Parent.Balance)
local Types = require(script.Parent.Parent.Types)

type AbilityBonuses = Types.AbilityBonuses
type AbilityDef = Types.AbilityDef
type AbilityLevel = Types.AbilityLevel
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
		source = "Base",
		--[[
			Два орба с первого уровня, а не один: одиночный орб на широком
			радиусе — это не кольцо, а точка, вращающаяся по кругу, и она
			попадала в одного врага из десяти.
		]]
		base = { damage = 8, cooldown = 0.5, count = 2, radius = 8, hitRadius = 4.2, angularSpeed = 3 },
		growth = { damage = 1.18, cooldown = 0.96 },
		milestone = { kind = "Count", amount = 1 },
	},
	{
		key = "IceShard",
		typeId = 0,
		displayName = "Ice Shard",
		description = "Fires a piercing shard at the nearest enemy.",
		element = "Ice",
		shape = "Projectile",
		source = "Base",
		base = { damage = 18, cooldown = 1.1, count = 1, speed = 75, lifetime = 1.3, pierce = 1, hitRadius = 2 },
		growth = { damage = 1.18, cooldown = 0.95 },
		milestone = { kind = "Count", amount = 2 },
	},
	{
		key = "ThornAura",
		typeId = 0,
		displayName = "Thorn Aura",
		description = "Everything close to you keeps taking damage.",
		element = "Nature",
		shape = "Aura",
		source = "Base",
		base = { damage = 6, cooldown = 0.6, radius = 12 },
		growth = { damage = 1.2, cooldown = 0.96 },
		milestone = { kind = "Radius", amount = 3 },
	},
	{
		key = "StormNova",
		typeId = 0,
		displayName = "Storm Nova",
		description = "A shockwave bursts out from you.",
		element = "Lightning",
		shape = "Nova",
		source = "Base",
		base = { damage = 22, cooldown = 3, radius = 17 },
		growth = { damage = 1.2, cooldown = 0.95 },
		milestone = { kind = "Radius", amount = 4 },
	},
	{
		key = "ShadowNeedle",
		typeId = 0,
		displayName = "Shadow Needles",
		description = "A volley of fast needles at nearby enemies.",
		element = "Dark",
		shape = "Projectile",
		source = "Base",
		base = { damage = 9, cooldown = 0.95, count = 2, speed = 100, lifetime = 0.9, pierce = 1, hitRadius = 1.6 },
		growth = { damage = 1.17, cooldown = 0.95 },
		milestone = { kind = "Count", amount = 2 },
	},
	{
		key = "LightBurst",
		typeId = 0,
		displayName = "Light Burst",
		description = "A rare but devastating flash of light.",
		element = "Light",
		shape = "Nova",
		source = "Base",
		base = { damage = 34, cooldown = 4.5, radius = 11 },
		growth = { damage = 1.21, cooldown = 0.95 },
		milestone = { kind = "Radius", amount = 3 },
	},

	--[[
		УНИКАЛЬНЫЕ СПОСОБНОСТИ ПИТОМЦЕВ (source = "Signature").

		По одной на каждого питомца выше ранга B. Карточками они не выдаются
		никогда — их приносит с собой питомец, — но качаются наравне
		с базовыми: иначе редкий питомец обесценивался бы к середине забега.

		У каждой своя пара «стихия + форма», не совпадающая ни с базовыми
		шестью, ни между собой: уникальность должна быть в ощущении, а не
		в цвете. Сила растёт с рангом питомца — это и есть разница между
		A и SSS, и крутить её надо здесь, а не в рубежах.
	]]
	{
		key = "ChainSpark",
		typeId = 0,
		displayName = "Chain Spark",
		description = "Lightning jumps from enemy to enemy.",
		element = "Lightning",
		shape = "Chain",
		source = "Signature",
		base = { damage = 16, cooldown = 1.6, count = 3, radius = 16, falloff = 0.8 },
		growth = { damage = 1.18, cooldown = 0.95 },
		milestone = { kind = "Count", amount = 1 },
	},
	{
		key = "WingGust",
		typeId = 0,
		displayName = "Wing Gust",
		description = "A wide sweep of dust in front of you.",
		element = "Dark",
		shape = "Cone",
		source = "Signature",
		base = { damage = 14, cooldown = 1.2, radius = 18, angle = 110 },
		growth = { damage = 1.18, cooldown = 0.95 },
		milestone = { kind = "Radius", amount = 4 },
	},
	{
		key = "MoteHalo",
		typeId = 0,
		displayName = "Mote Halo",
		description = "Small motes of light spin around you.",
		element = "Light",
		shape = "Orbit",
		source = "Signature",
		base = { damage = 5, cooldown = 0.35, count = 4, radius = 7, hitRadius = 3, angularSpeed = 4.5 },
		growth = { damage = 1.17, cooldown = 0.96 },
		milestone = { kind = "Count", amount = 1 },
	},
	{
		key = "EmberTrail",
		typeId = 0,
		displayName = "Ember Trail",
		description = "The ground around you burns.",
		element = "Fire",
		shape = "Aura",
		source = "Signature",
		base = { damage = 10, cooldown = 0.5, radius = 10 },
		growth = { damage = 1.2, cooldown = 0.95 },
		milestone = { kind = "Radius", amount = 3 },
	},
	{
		key = "FrostBurst",
		typeId = 0,
		displayName = "Frost Burst",
		description = "A rare, enormous wave of cold.",
		element = "Ice",
		shape = "Nova",
		source = "Signature",
		base = { damage = 46, cooldown = 4, radius = 22 },
		growth = { damage = 1.21, cooldown = 0.95 },
		milestone = { kind = "Radius", amount = 5 },
	},
	{
		key = "StormArc",
		typeId = 0,
		displayName = "Storm Arc",
		description = "A long arc that leaps across the crowd.",
		element = "Lightning",
		shape = "Chain",
		source = "Signature",
		base = { damage = 26, cooldown = 1.5, count = 5, radius = 24, falloff = 0.88 },
		growth = { damage = 1.19, cooldown = 0.95 },
		milestone = { kind = "Count", amount = 2 },
	},
	{
		key = "VoidFangs",
		typeId = 0,
		displayName = "Void Fangs",
		description = "Two heavy fangs circle you slowly.",
		element = "Dark",
		shape = "Orbit",
		source = "Signature",
		base = { damage = 22, cooldown = 0.7, count = 2, radius = 10, hitRadius = 5.5, angularSpeed = 2.2 },
		growth = { damage = 1.19, cooldown = 0.96 },
		milestone = { kind = "Count", amount = 1 },
	},
	{
		key = "SolarFlare",
		typeId = 0,
		displayName = "Solar Flare",
		description = "A narrow beam of sunlight burns everything in its path.",
		element = "Light",
		shape = "Cone",
		source = "Signature",
		base = { damage = 40, cooldown = 1.8, radius = 34, angle = 45 },
		growth = { damage = 1.2, cooldown = 0.95 },
		milestone = { kind = "Radius", amount = 6 },
	},
	{
		key = "SeedVolley",
		typeId = 0,
		displayName = "Seed Volley",
		description = "Heavy seeds tear through everything they touch.",
		element = "Nature",
		shape = "Projectile",
		source = "Signature",
		base = { damage = 30, cooldown = 1, count = 2, speed = 85, lifetime = 1.5, pierce = 4, hitRadius = 2.4 },
		growth = { damage = 1.19, cooldown = 0.95 },
		milestone = { kind = "Count", amount = 2 },
	},
}

Abilities.List = definitions
Abilities.ByKey = {} :: { [string]: AbilityDef }
-- Только те, что предлагаются карточками. Уникальные способности питомцев
-- сюда не попадают: их нельзя получить в бою, только принести с собой.
Abilities.BaseList = {} :: { AbilityDef }

Abilities.MaxLevel = Balance.Progression.maxAbilityLevel

-- Каждый milestoneEvery-й уровень — рубеж.
function Abilities.IsMilestone(level: number): boolean
	return level > 1 and level % Balance.Progression.milestoneEvery == 0
end

-- Ближайший рубеж строго после level; ноль, если дальше рубежей нет.
function Abilities.NextMilestone(level: number): number
	local every = Balance.Progression.milestoneEvery
	local next = (math.floor(level / every) + 1) * every
	return if next <= Abilities.MaxLevel then next else 0
end

function Abilities.NewBonuses(): AbilityBonuses
	return { damageMult = 1, cooldownMult = 1, count = 0, radius = 0, pierce = 0 }
end

--[[
	Характеристики способности с учётом накопленного за забег.

	Собирается новая таблица, а не правится базовая: base заморожен и общий
	для всех забегов на сервере — править его означало бы менять способность
	всем сразу и навсегда.
]]
function Abilities.Stats(def: AbilityDef, bonuses: AbilityBonuses): AbilityLevel
	local base = def.base

	return {
		damage = base.damage * bonuses.damageMult,
		cooldown = base.cooldown * bonuses.cooldownMult,
		count = if base.count then base.count + bonuses.count else nil,
		radius = if base.radius then base.radius + bonuses.radius else nil,
		hitRadius = base.hitRadius,
		angularSpeed = base.angularSpeed,
		speed = base.speed,
		lifetime = base.lifetime,
		pierce = if base.pierce then base.pierce + bonuses.pierce else nil,
		--[[
			Поля новых форм переносятся как есть. Забыть здесь поле — значит
			получить nil в бою: Cone падал на math.rad(nil) до первого удара,
			а Chain — на затухании урона уже ПОСЛЕ удара по первому врагу,
			из-за чего цепь била одного и не рисовалась вовсе.
		]]
		angle = base.angle,
		falloff = base.falloff,
	}
end

--[[
	Характеристики для ОТРИСОВКИ, по одному лишь уровню.

	Клиент не знает накопленных множителей: редкость карточек живёт на сервере.
	Но рисовать ему нужно ровно то, что от них не зависит — число орбов, радиус
	орбиты и ауры, скорость и время жизни снаряда. Всё это либо неизменная база,
	либо рубеж, а рубеж детерминирован уровнем и у всех одинаков.

	Урон и кулдаун здесь базовые и для отрисовки не годятся — их и не рисуют.
]]
function Abilities.VisualStats(def: AbilityDef, level: number): AbilityLevel
	local bonuses = Abilities.NewBonuses()

	for step = 2, math.min(level, Abilities.MaxLevel) do
		if Abilities.IsMilestone(step) then
			Abilities.ApplyUpgrade(def, step, 1, bonuses)
		end
	end

	return Abilities.Stats(def, bonuses)
end

--[[
	Применить повышение до уровня level.

	multiplier — множитель редкости карточки, действует только на обычный
	уровень. На рубеже он игнорируется намеренно.
]]
function Abilities.ApplyUpgrade(def: AbilityDef, level: number, multiplier: number, bonuses: AbilityBonuses): ()
	if Abilities.IsMilestone(level) then
		local milestone = def.milestone
		if milestone.kind == "Count" then
			bonuses.count += milestone.amount
		elseif milestone.kind == "Radius" then
			bonuses.radius += milestone.amount
		else
			bonuses.pierce += milestone.amount
		end
		return
	end

	-- Прибавка, а не множитель в степени: редкая карточка добавляет больше
	-- ровно один раз, и её вклад остаётся в способности навсегда.
	bonuses.damageMult *= 1 + (def.growth.damage - 1) * multiplier
	bonuses.cooldownMult *= 1 - (1 - def.growth.cooldown) * multiplier
end

local MILESTONE_TEXT: { [Types.AbilityMilestoneKind]: (def: AbilityDef) -> string } = {
	Count = function(def: AbilityDef): string
		local word = if def.shape == "Orbit" then "orb" elseif def.shape == "Chain" then "jump" else "projectile"
		local amount = def.milestone.amount
		return if amount == 1 then `+1 {word}` else `+{amount} {word}s`
	end,
	Radius = function(def: AbilityDef): string
		return `+{def.milestone.amount} radius`
	end,
	Pierce = function(def: AbilityDef): string
		return `+{def.milestone.amount} pierce`
	end,
}

--[[
	Что игрок получит прямо сейчас, если возьмёт карточку.

	Именно это, а не описание способности: описание он прочитал, когда брал её
	впервые, а решение принимает по прибавке.
]]
function Abilities.UpgradeText(def: AbilityDef, level: number, multiplier: number): string
	if level <= 1 then
		return def.description
	end

	if Abilities.IsMilestone(level) then
		return MILESTONE_TEXT[def.milestone.kind](def)
	end

	local damage = (def.growth.damage - 1) * multiplier * 100
	local cooldown = (1 - def.growth.cooldown) * multiplier * 100

	return string.format("+%.0f%% damage · +%.0f%% attack speed", damage, cooldown)
end

-- Какие поля обязаны быть у каждой формы.
local REQUIRED_FIELDS: { [AbilityShape]: { string } } = {
	Orbit = { "count", "radius", "hitRadius", "angularSpeed" },
	Projectile = { "count", "speed", "lifetime", "pierce", "hitRadius" },
	Aura = { "radius" },
	Nova = { "radius" },
	-- Клин: длина и ширина. Без угла это была бы просто Nova.
	Cone = { "radius", "angle" },
	-- Цепь: дальность прыжка, число звеньев и затухание урона по звеньям.
	Chain = { "radius", "count", "falloff" },
}

for index, def in definitions do
	def.typeId = index
	assert(Abilities.ByKey[def.key] == nil, `[Abilities] Дубликат ключа "{def.key}"`)
	Abilities.ByKey[def.key] = def

	if def.source == "Base" then
		table.insert(Abilities.BaseList, def)
	end

	local required = REQUIRED_FIELDS[def.shape]
	assert(required, `[Abilities] У "{def.key}" неизвестная форма "{def.shape}"`)

	assert(def.base.damage > 0, `[Abilities] "{def.key}": damage должен быть больше нуля`)
	assert(def.base.cooldown > 0, `[Abilities] "{def.key}": cooldown должен быть больше нуля`)

	--[[
		Поле обязано быть и в данных, и в том, что из них собирает Stats.

		Вторая проверка выглядит избыточной ровно до первого раза, когда
		у формы появляется новое поле, а перенести его в Stats забывают:
		тогда в бою прилетает nil, и способность падает молча — Cone
		не наносил урона вовсе, Chain бил одного врага вместо цепи.
	]]
	local stats = Abilities.Stats(def, Abilities.NewBonuses())
	for _, field in required do
		assert(
			(def.base :: any)[field] ~= nil,
			`[Abilities] "{def.key}": форме {def.shape} нужно поле "{field}"`
		)
		assert(
			(stats :: any)[field] ~= nil,
			`[Abilities] "{def.key}": поле "{field}" есть в данных, но теряется в Abilities.Stats`
		)
	end

	assert(
		def.growth.damage > 1,
		`[Abilities] "{def.key}": рост урона должен быть больше единицы`
	)
	assert(
		def.growth.cooldown > 0 and def.growth.cooldown < 1,
		`[Abilities] "{def.key}": рост кулдауна должен быть между нулём и единицей`
	)

	--[[
		Рубеж «+радиус» способности без радиуса — это молчаливо ничего.
		Ловим здесь, а не в бою.
	]]
	if def.milestone.kind == "Radius" then
		assert(
			def.base.radius ~= nil,
			`[Abilities] "{def.key}": рубеж по радиусу, а радиуса нет`
		)
	elseif def.milestone.kind == "Count" then
		assert(
			def.base.count ~= nil,
			`[Abilities] "{def.key}": рубеж по числу снарядов, а count нет`
		)
	else
		assert(def.base.pierce ~= nil, `[Abilities] "{def.key}": рубеж по пробою, а pierce нет`)
	end

	assert(def.milestone.amount > 0, `[Abilities] "{def.key}": рубеж без прибавки`)

	table.freeze(def.base)
	table.freeze(def.growth)
	table.freeze(def.milestone)
	table.freeze(def)
end

table.freeze(definitions)
table.freeze(Abilities.ByKey)
table.freeze(Abilities.BaseList)

assert(
	#definitions <= 255,
	"[Abilities] Больше 255 способностей не влезет в байт typeId"
)

return Abilities
