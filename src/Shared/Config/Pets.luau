--!strict
--[[
	Pets — таблица питомцев (разделы 6 и 6.1 ТЗ).

	Питомцы — это классы. Каждый даёт три вещи:
		1. стартовую способность боя (её стихия задаёт направление билда),
		2. пассивные бонусы к характеристикам,
		3. множитель урона своей стихии.

	Первая версия — 12 питомцев в раскладке из таблицы раздела 6:
	B×3, A×3, S×2, SS×2, SSS×2. Чем выше редкость, тем уже специализация:
	у B умеренные бонусы к своей стихии, у SSS — большие.

	typeId проставляется по порядку записей. Порядок менять нельзя —
	только дописывать в конец.

	Кривые (опыт, цена улучшения, сила, вклад в оффлайн) сюда не входят:
	это балансные числа, они живут в Balance.Pets, а здесь только функции,
	которые их читают.
]]

local Abilities = require(script.Parent.Abilities)
local Balance = require(script.Parent.Balance)
local Types = require(script.Parent.Parent.Types)

type PetDef = Types.PetDef
type PetRarity = Types.PetRarity

local Pets = {}

--[[
	Порядок редкостей от худшей к лучшей. По нему же идут весовые таблицы яиц
	и вся сортировка в интерфейсе, поэтому список один на весь проект.
]]
Pets.Rarities = table.freeze({ "B", "A", "S", "SS", "SSS" } :: { PetRarity })

local definitions: { PetDef } = {
	--[[ B — стартовая редкость: полноценные, но без выраженной специализации. ]]
	{
		key = "EmberCub",
		typeId = 0,
		displayName = "Ember Cub",
		description = "Starts you with Fire Halo. Steady all-rounder.",
		rarity = "B",
		element = "Fire",
		starterAbility = "FireOrbit",
		passives = { maxHealth = 10, walkSpeed = 0, magnetRadius = 1 },
		elementDamage = 1.08,
		model = { size = Vector3.new(2, 2, 2), shape = "Ball", neon = false },
	},
	{
		key = "FrostPup",
		typeId = 0,
		displayName = "Frost Pup",
		description = "Starts you with Ice Shard. Slightly quicker on foot.",
		rarity = "B",
		element = "Ice",
		starterAbility = "IceShard",
		passives = { maxHealth = 5, walkSpeed = 1, magnetRadius = 1 },
		elementDamage = 1.08,
		model = { size = Vector3.new(2, 2, 2), shape = "Block", neon = false },
	},
	{
		key = "MossSprout",
		typeId = 0,
		displayName = "Moss Sprout",
		description = "Starts you with Thorn Aura. Pulls crystals from further away.",
		rarity = "B",
		element = "Nature",
		starterAbility = "ThornAura",
		passives = { maxHealth = 8, walkSpeed = 0, magnetRadius = 3 },
		elementDamage = 1.08,
		model = { size = Vector3.new(1.8, 2.4, 1.8), shape = "Cylinder", neon = false },
	},

	--[[ A — заметный уклон в одну характеристику. ]]
	{
		key = "SparkKit",
		typeId = 0,
		displayName = "Spark Kit",
		description = "Starts you with Storm Nova. Built for speed.",
		rarity = "A",
		element = "Lightning",
		starterAbility = "StormNova",
		passives = { maxHealth = 5, walkSpeed = 2.5, magnetRadius = 2 },
		elementDamage = 1.16,
		model = { size = Vector3.new(2, 2, 2), shape = "Block", neon = true },
	},
	{
		key = "DuskMoth",
		typeId = 0,
		displayName = "Dusk Moth",
		description = "Starts you with Shadow Needles. Wide crystal pickup.",
		rarity = "A",
		element = "Dark",
		starterAbility = "ShadowNeedle",
		passives = { maxHealth = 5, walkSpeed = 1, magnetRadius = 5 },
		elementDamage = 1.16,
		model = { size = Vector3.new(2.4, 1.6, 2.4), shape = "Block", neon = true },
	},
	{
		key = "GlowFinch",
		typeId = 0,
		displayName = "Glow Finch",
		description = "Starts you with Light Burst. Tougher than it looks.",
		rarity = "A",
		element = "Light",
		starterAbility = "LightBurst",
		passives = { maxHealth = 20, walkSpeed = 1, magnetRadius = 1 },
		elementDamage = 1.16,
		model = { size = Vector3.new(1.8, 1.8, 1.8), shape = "Ball", neon = true },
	},

	--[[ S — сильные бонусы к своей стихии, билд начинает ощущаться. ]]
	{
		key = "MagmaHound",
		typeId = 0,
		displayName = "Magma Hound",
		description = "Fire Halo starter. Fire abilities hit noticeably harder.",
		rarity = "S",
		element = "Fire",
		starterAbility = "FireOrbit",
		passives = { maxHealth = 25, walkSpeed = 1, magnetRadius = 2 },
		elementDamage = 1.3,
		model = { size = Vector3.new(2.6, 2.2, 2.6), shape = "Block", neon = true },
	},
	{
		key = "GlacierOwl",
		typeId = 0,
		displayName = "Glacier Owl",
		description = "Ice Shard starter. Ice abilities hit noticeably harder.",
		rarity = "S",
		element = "Ice",
		starterAbility = "IceShard",
		passives = { maxHealth = 15, walkSpeed = 2, magnetRadius = 4 },
		elementDamage = 1.3,
		model = { size = Vector3.new(2.2, 2.6, 2.2), shape = "Ball", neon = true },
	},

	--[[ SS — узкая специализация, ради которой билд и собирают. ]]
	{
		key = "StormDrake",
		typeId = 0,
		displayName = "Storm Drake",
		description = "Storm Nova starter. Lightning damage soars.",
		rarity = "SS",
		element = "Lightning",
		starterAbility = "StormNova",
		passives = { maxHealth = 30, walkSpeed = 2, magnetRadius = 3 },
		elementDamage = 1.45,
		model = { size = Vector3.new(3, 2.4, 3), shape = "Block", neon = true },
	},
	{
		key = "VoidLynx",
		typeId = 0,
		displayName = "Void Lynx",
		description = "Shadow Needles starter. Dark damage soars.",
		rarity = "SS",
		element = "Dark",
		starterAbility = "ShadowNeedle",
		passives = { maxHealth = 20, walkSpeed = 3, magnetRadius = 5 },
		elementDamage = 1.45,
		model = { size = Vector3.new(2.8, 2.2, 2.8), shape = "Ball", neon = true },
	},

	--[[ SSS — вершина коллекции: и бонусы, и вклад в экспедиции. ]]
	{
		key = "SolarPhoenix",
		typeId = 0,
		displayName = "Solar Phoenix",
		description = "Light Burst starter. Light damage is overwhelming.",
		rarity = "SSS",
		element = "Light",
		starterAbility = "LightBurst",
		passives = { maxHealth = 40, walkSpeed = 3, magnetRadius = 6 },
		elementDamage = 1.65,
		model = { size = Vector3.new(3.2, 3.2, 3.2), shape = "Ball", neon = true },
	},
	{
		key = "VerdantWarden",
		typeId = 0,
		displayName = "Verdant Warden",
		description = "Thorn Aura starter. Nature damage is overwhelming.",
		rarity = "SSS",
		element = "Nature",
		starterAbility = "ThornAura",
		passives = { maxHealth = 55, walkSpeed = 1, magnetRadius = 5 },
		elementDamage = 1.65,
		model = { size = Vector3.new(2.8, 3.4, 2.8), shape = "Cylinder", neon = true },
	},
}

Pets.List = definitions
Pets.ByKey = {} :: { [string]: PetDef }
Pets.ByRarity = {} :: { [PetRarity]: { PetDef } }

--[[
	Сколько опыта нужно, чтобы уйти с уровня level на следующий.
	Формула, а не таблица (правило 6 ТЗ).
]]
function Pets.XpForLevel(level: number): number
	return math.floor(Balance.Pets.xpBase * Balance.Pets.xpGrowth ^ (level - 1) + 0.5)
end

--[[
	Уровень по суммарному опыту питомца.

	Единственный источник правды о том, какой у питомца уровень: и выдача
	дубликатов, и покупка опыта в магазине приводят к пересчёту здесь,
	а не каждая к своему. Возвращает уровень, опыт внутри уровня и остаток
	до следующего (0 на максимуме — там прогресс-бар не нужен).
]]
function Pets.LevelForXp(xp: number): (number, number, number)
	local level = 1
	local left = math.max(math.floor(xp), 0)
	local maxLevel = Balance.Pets.maxLevel

	while level < maxLevel do
		local need = Pets.XpForLevel(level)
		if left < need then
			return level, left, need - left
		end
		left -= need
		level += 1
	end

	return maxLevel, 0, 0
end

--[[
	Сила питомца. Она же определяет и вклад в оффлайн-доход, и порядок
	сортировки коллекции: считать «силу» двумя разными способами нельзя,
	иначе список в интерфейсе перестанет соответствовать выплате.
]]
function Pets.Power(petId: string, level: number): number
	local def = Pets.ByKey[petId]
	if not def then
		return 0
	end
	local base = Balance.Pets.rarityPower[def.rarity]
	return base * (1 + (level - 1) * Balance.Pets.powerPerLevel)
end

-- Сколько Essence стоит поднять питомца с уровня level на level + 1.
-- Ноль означает, что поднимать некуда.
function Pets.UpgradeCost(petId: string, level: number): number
	local def = Pets.ByKey[petId]
	if not def or level >= Balance.Pets.maxLevel then
		return 0
	end
	local base = Balance.Pets.rarityUpgradeCost[def.rarity]
	return math.floor(base * Balance.Pets.upgradeCostGrowth ^ (level - 1) + 0.5)
end

-- Сколько опыта даёт дубликат. Зависит от редкости выпавшего питомца.
function Pets.DuplicateXp(petId: string): number
	local def = Pets.ByKey[petId]
	if not def then
		return 0
	end
	return Balance.Pets.rarityDuplicateXp[def.rarity]
end

--[[
	Множитель бонусов на уровне level. Бонусы первого уровня записаны в таблице,
	а рост общий для всех: иначе балансить пришлось бы 12 кривых вместо одной.
]]
function Pets.LevelScale(level: number): number
	return 1 + (level - 1) * Balance.Pets.passivePerLevel
end

for _, rarity in Pets.Rarities do
	Pets.ByRarity[rarity] = {}
end

for index, def in definitions do
	def.typeId = index
	assert(Pets.ByKey[def.key] == nil, `[Pets] Дубликат ключа "{def.key}"`)
	Pets.ByKey[def.key] = def

	local bucket = Pets.ByRarity[def.rarity]
	assert(bucket, `[Pets] У "{def.key}" неизвестная редкость "{def.rarity}"`)
	table.insert(bucket, def)

	assert(
		Balance.Pets.rarityPower[def.rarity] ~= nil,
		`[Pets] Для редкости "{def.rarity}" нет коэффициентов в Balance.Pets`
	)
	assert(
		def.elementDamage >= 1,
		`[Pets] "{def.key}": elementDamage меньше единицы — питомец ослаблял бы свою же стихию`
	)

	local ability = Abilities.ByKey[def.starterAbility]
	assert(
		ability,
		`[Pets] "{def.key}" ссылается на несуществующую способность "{def.starterAbility}"`
	)
	--[[
		Стихия питомца и стихия его стартовой способности обязаны совпадать:
		иначе бонус к стихии не попадёт в ту самую способность, ради которой
		питомца и берут, и «класс» развалится на два несвязанных куска.
	]]
	assert(
		ability.element == def.element,
		`[Pets] У "{def.key}" стихия {def.element}, а у стартовой способности {ability.element}`
	)

	table.freeze(def.passives)
	table.freeze(def.model)
	table.freeze(def)
end

for _, rarity in Pets.Rarities do
	assert(
		#Pets.ByRarity[rarity] > 0,
		`[Pets] В редкости "{rarity}" нет ни одного питомца: яйцо не сможет её выдать`
	)
	table.freeze(Pets.ByRarity[rarity])
end

table.freeze(definitions)
table.freeze(Pets.ByKey)
table.freeze(Pets.ByRarity)

assert(#definitions <= 255, "[Pets] Больше 255 питомцев не влезет в байт typeId")

return Pets
