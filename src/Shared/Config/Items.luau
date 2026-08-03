--!strict
--[[
	Items — экипировка (раздел 6.1 ТЗ), M6.

	Броня выпадает за прохождение сюжетных уровней. Слоты, редкости и роллы
	характеристик — здесь; сами предметы не описываются поштучно, а собираются
	роллом: слот × редкость × набор характеристик. Так десять уровней дают сотни
	разных предметов без единой лишней записи.

	Характеристики намеренно те же, что уже умеет лоадаут забега: здоровье,
	скорость, радиус притяжения и урон. Пятый вид потребовал бы кода в бою,
	а экипировка должна добавляться данными.

	Публичный API:
		Items.Slots / Items.Rarities / Items.RarityByKey
		Items.Roll(stageIndex, guaranteedRarity, random) -> ItemInstance
		Items.Power(item) -> number
]]

local Balance = require(script.Parent.Balance)
local Types = require(script.Parent.Parent.Types)

type ItemInstance = Types.ItemInstance
type ItemRarity = Types.ItemRarity
type ItemSlot = Types.ItemSlot
type ItemStatKind = Types.ItemStatKind

local Items = {}

Items.Slots = table.freeze({ "Helmet", "Chest", "Boots", "Trinket" } :: { ItemSlot })

--[[
	Редкости. Вес — шанс выпадения, множитель — насколько крупнее числа.
	Уровни эффектов совпадают с таблицей раздела 2.1 ТЗ: обычный плоский,
	легендарный светится. Визуал появится вместе с косметикой в M7,
	а данные для него лежат уже здесь.
]]
export type RarityDef = {
	key: ItemRarity,
	displayName: string,
	weight: number,
	statMult: number,
	statCount: number, -- сколько характеристик у предмета
	color: string,
}

local rarities: { RarityDef } = {
	{ key = "Common", displayName = "Common", weight = 60, statMult = 1, statCount = 1, color = "#8A9A92" },
	{ key = "Rare", displayName = "Rare", weight = 27, statMult = 1.6, statCount = 2, color = "#5FC8E8" },
	{ key = "Epic", displayName = "Epic", weight = 10, statMult = 2.4, statCount = 3, color = "#7A5BC4" },
	{ key = "Legendary", displayName = "Legendary", weight = 3, statMult = 3.6, statCount = 4, color = "#E8CE4B" },
}

Items.Rarities = rarities
Items.RarityByKey = {} :: { [ItemRarity]: RarityDef }

--[[
	Характеристики и их базовые значения на первом уровне.

	AllDamage — множитель, остальные — добавки. Разделение важное: множитель
	перемножается с питомцем и талантами, добавки складываются с базой.
]]
local STATS: { { kind: ItemStatKind, base: number, perStage: number } } = {
	{ kind = "MaxHealth", base = 12, perStage = 1.8 },
	{ kind = "WalkSpeed", base = 0.6, perStage = 0.05 },
	{ kind = "MagnetRadius", base = 1.4, perStage = 0.12 },
	{ kind = "AllDamage", base = 0.03, perStage = 0.004 },
}

local totalWeight = 0
for _, rarity in rarities do
	totalWeight += rarity.weight
	Items.RarityByKey[rarity.key] = rarity
	table.freeze(rarity)
end

local function rollRarity(random: Random): RarityDef
	local roll = random:NextNumber(0, totalWeight)
	local accumulated = 0

	for _, rarity in rarities do
		accumulated += rarity.weight
		if roll <= accumulated then
			return rarity
		end
	end

	return rarities[#rarities]
end

--[[
	Собрать предмет.

	guaranteedRarity задаётся только там, где награда обещана заранее, —
	финальный уровень локации даёт гарантированный предмет (раздел 5.1 ТЗ).
	В остальных случаях редкость роллится.

	uid здесь не проставляется: он выдаётся профилем, как и у питомцев,
	и уникален на всём протяжении жизни аккаунта.
]]
function Items.Roll(stageIndex: number, guaranteedRarity: ItemRarity?, random: Random): ItemInstance
	local rarity = if guaranteedRarity then Items.RarityByKey[guaranteedRarity] else rollRarity(random)
	local slot = Items.Slots[random:NextInteger(1, #Items.Slots)]

	--[[
		Характеристики выбираются без повторов: предмет с двумя строками
		«+12 здоровья» читается как ошибка, даже если сумма та же.
	]]
	local pool = table.clone(STATS)
	local stats: { [string]: number } = {}
	local count = math.min(rarity.statCount, #pool)

	for _ = 1, count do
		local index = random:NextInteger(1, #pool)
		local entry = pool[index]
		table.remove(pool, index)

		local value = (entry.base + entry.perStage * (stageIndex - 1)) * rarity.statMult
		-- Проценты урона округляем до тысячных, добавки — до десятых:
		-- «+12.4 здоровья» читается, «+12.437291» нет.
		local rounded = if entry.kind == "AllDamage"
			then math.floor(value * 1000 + 0.5) / 1000
			else math.floor(value * 10 + 0.5) / 10
		stats[entry.kind] = rounded
	end

	return {
		uid = "",
		slot = slot,
		rarity = rarity.key,
		stageIndex = stageIndex,
		stats = stats,
	}
end

--[[
	Сила предмета одним числом. Нужна интерфейсу, чтобы сортировать инвентарь
	и подсказывать, что новое лучше надетого.
]]
function Items.Power(item: ItemInstance): number
	local power = 0
	for kind, value in item.stats do
		-- Урон приведён к тому же порядку, что и добавки: иначе три сотых
		-- множителя весили бы меньше единицы здоровья.
		power += if kind == "AllDamage" then value * 400 else value
	end
	return power
end

-- Сколько предметов даёт уровень: гарантированный на финале локации,
-- иначе по шансу из Balance.
function Items.DropCount(isLocationFinal: boolean, random: Random): number
	if isLocationFinal then
		return 1
	end
	return if random:NextNumber(0, 1) < Balance.Items.dropChance then 1 else 0
end

table.freeze(rarities)
table.freeze(Items.RarityByKey)
table.freeze(STATS)

return Items
