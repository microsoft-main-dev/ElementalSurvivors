--!strict
--[[
	Cards — редкость карточек улучшения (раздел 3.6 ТЗ).

	Редкость множит ТОЛЬКО обычный уровень: урон и скорость атаки. Рубеж
	каждого третьего уровня (+снаряд, +радиус) всегда одинаков — иначе главное,
	ради чего качают способность, превратилось бы в лотерею.

	Веса относительные, сумма нормализуется при загрузке: править вес одной
	редкости можно, не пересчитывая остальные.

	Публичный API:
		Cards.Rarities            -> { CardRarity }   от частой к редкой
		Cards.ByKey               -> { [string]: CardRarity }
		Cards.Roll(random)        -> CardRarity
		Cards.MultiplierFor(key)  -> number
]]

export type CardRarity = {
	key: string,
	displayName: string,
	weight: number,
	--[[
		Во сколько раз прибавка обычного уровня больше обычной. Единица —
		базовый случай; тройка означает, что вместо +12% урона карточка даст +36%.
	]]
	multiplier: number,
	color: string, -- hex, чтобы Palette не тянуть в данные
}

local Cards = {}

local definitions: { CardRarity } = {
	{ key = "Common", displayName = "Common", weight = 70, multiplier = 1, color = "#8A9A92" },
	{ key = "Rare", displayName = "Rare", weight = 20, multiplier = 1.5, color = "#5FC8E8" },
	{ key = "Epic", displayName = "Epic", weight = 8, multiplier = 2, color = "#7A5BC4" },
	{ key = "Legendary", displayName = "Legendary", weight = 2, multiplier = 3, color = "#E8CE4B" },
}

Cards.Rarities = definitions
Cards.ByKey = {} :: { [string]: CardRarity }
Cards.Common = definitions[1]

local totalWeight = 0

for _, rarity in definitions do
	assert(Cards.ByKey[rarity.key] == nil, `[Cards] Дубликат ключа "{rarity.key}"`)
	assert(rarity.weight > 0, `[Cards] У "{rarity.key}" вес не больше нуля`)
	assert(rarity.multiplier >= 1, `[Cards] У "{rarity.key}" множитель меньше единицы`)

	Cards.ByKey[rarity.key] = rarity
	totalWeight += rarity.weight
	table.freeze(rarity)
end

--[[
	Один ролл редкости. Накопительная сумма, а не вычитание: погрешность float
	не может тогда оставить ролл без ответа — остаток забирает последняя запись.
]]
function Cards.Roll(random: Random): CardRarity
	local roll = random:NextNumber(0, totalWeight)
	local accumulated = 0

	for _, rarity in definitions do
		accumulated += rarity.weight
		if roll <= accumulated then
			return rarity
		end
	end

	return definitions[#definitions]
end

-- Множитель по ключу. Неизвестный ключ — это обычная карточка, а не ошибка:
-- строка приходит в том числе на клиент, и падать из-за неё нечему.
function Cards.MultiplierFor(key: string): number
	local rarity = Cards.ByKey[key]
	return if rarity then rarity.multiplier else 1
end

function Cards.ColorFor(key: string): Color3
	local rarity = Cards.ByKey[key]
	return Color3.fromHex(if rarity then rarity.color else Cards.Common.color)
end

table.freeze(definitions)
table.freeze(Cards.ByKey)

return table.freeze(Cards)
