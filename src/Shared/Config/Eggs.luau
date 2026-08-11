--!strict
--[[
	Eggs — яйца-лутбоксы лобби (раздел 4 ТЗ).

	Веса заданы по редкостям, а не по конкретным питомцам: внутри выпавшей
	редкости питомец выбирается равновероятно. Так добавление тринадцатого
	питомца не требует пересчёта ни одной весовой таблицы — меняется только
	то, сколько питомцев делят между собой уже утверждённый шанс редкости.

	Дорогое яйцо режет нижние редкости, а не добавляет своих питомцев.
	Донатные яйца отличаются шансами, а не эксклюзивами (раздел 6 ТЗ):
	принцип «всё добывается гриндом» ломать нечем.

	Веса — это относительные доли, а не проценты: сумма нормализуется при
	загрузке, и веса можно править по одному, не пересчитывая остальные.
	Для базового яйца они специально записаны так, что сумма равна 100 —
	это ровно таблица из раздела 6 ТЗ, и её проще всего сверять глазами.
]]

local Pets = require(script.Parent.Pets)
local Types = require(script.Parent.Parent.Types)

type CurrencyKind = Types.CurrencyKind
type PetRarity = Types.PetRarity

export type EggDef = {
	key: string,
	displayName: string,
	description: string,
	currency: CurrencyKind,
	price: number,
	weights: { [PetRarity]: number },
	-- Заполняется при загрузке: суммарный вес и границы для выбора.
	totalWeight: number,
	--[[
		hex, чтобы Palette не тянуть в данные. Цвет остаётся нужен и после
		появления картинки: им красится строка яйца и заглушка, пока ассет
		не загружен. Сам Asset ID лежит в Config/Icons вместе со всеми
		остальными — искать сорок чисел по семи файлам не должно быть нужно.
	]]
	color: string,
}

local Eggs = {}

local definitions: { EggDef } = {
	{
		key = "Basic",
		displayName = "Basic Egg",
		description = "The standard odds. Anything can hatch, even the best.",
		currency = "essence",
		--[[
			Якорь всей экономики Essence: примерно десять минут боя.
			Остальные цены за Essence — в этом файле, в Balance.Pets
			и в Config/Shop — выражены относительно него.

			Замерено на живом забеге: 18 451 убитых за 12:55, то есть около
			1430 убийств в минуту и ~14 500 Essence за десять минут. Цена
			чуть ниже замера намеренно: десяти минут должно хватать с запасом,
			а не ровно впритык.
		]]
		price = 14000,
		--[[
			Решение владельца: сильного питомца не должно быть легко достать.
			Базовое яйцо — это почти всегда B, изредка A и почти никогда S.
			Ни SS, ни SSS из него не выпадает вовсе: за ними идут в дорогие.
		]]
		weights = { B = 87.5, A = 12, S = 0.5 },
		totalWeight = 0,
		color = "#8FD3AC",
	},
	{
		key = "Greater",
		displayName = "Greater Egg",
		description = "Far fewer commons and a real chance at S.",
		currency = "essence",
		price = 45000,
		-- Второй тир: B перестаёт быть подавляющим, S становится реальным.
		-- SS и выше по-прежнему нет — это всё ещё не топовое яйцо.
		weights = { B = 55, A = 40, S = 5 },
		totalWeight = 0,
		color = "#5FC8E8",
	},
	{
		key = "Prime",
		displayName = "Prime Egg",
		description = "The best egg you can buy with Essence. SS and SSS possible.",
		currency = "essence",
		price = 130000,
		--[[
			Максимум, доступный за Essence. A уже заметно вероятнее B, и только
			здесь вообще появляются SS и SSS — по решению владельца, 3% и 1%.
		]]
		weights = { B = 20, A = 50, S = 26, SS = 3, SSS = 1 },
		totalWeight = 0,
		color = "#E8CE4B",
	},
	--[[
		Донатные яйца. Купить их до M7 нельзя — Prisms в игре пока не
		зарабатываются, — но объекты стоят в лобби и честно показывают цену:
		лутбокс, о котором игрок не знает, ничего не мотивирует.
	]]
	{
		key = "Prism",
		displayName = "Prism Egg",
		description = "Prism odds: strong pets far more often.",
		currency = "prisms",
		price = 80,
		weights = { A = 30, S = 45, SS = 20, SSS = 5 },
		totalWeight = 0,
		color = "#7A5BC4",
	},
	{
		key = "Radiant",
		displayName = "Radiant Egg",
		description = "S and above only. The best odds in the game.",
		currency = "prisms",
		price = 200,
		weights = { S = 55, SS = 35, SSS = 10 },
		totalWeight = 0,
		color = "#F2EFDF",
	},
}

Eggs.List = definitions
Eggs.ByKey = {} :: { [string]: EggDef }

--[[
	Один ролл. Random передаётся снаружи: боевой путь берёт свой генератор,
	а стенд проверки шансов — свой с фиксированным seed, и одна и та же
	функция обслуживает оба, без глобального состояния.
]]
function Eggs.Roll(egg: EggDef, random: Random): string
	local roll = random:NextNumber(0, egg.totalWeight)

	--[[
		Накопительная сумма, а не вычитание: погрешность float не может тогда
		оставить ролл без ответа — остаток забирает последняя присутствующая
		в таблице редкость, ради чего rarity и присваивается на каждом шаге.
	]]
	local rarity: PetRarity? = nil
	local accumulated = 0

	for _, candidate in Pets.Rarities do
		local weight = egg.weights[candidate]
		if weight then
			accumulated += weight
			rarity = candidate
			if roll <= accumulated then
				break
			end
		end
	end

	-- Внутри редкости все питомцы равновероятны.
	local bucket = Pets.ByRarity[rarity :: PetRarity]
	return bucket[random:NextInteger(1, #bucket)].key
end

-- Ожидаемая доля редкости, 0..1. Нужна стенду проверки шансов и интерфейсу.
function Eggs.Chance(egg: EggDef, rarity: PetRarity): number
	local weight = egg.weights[rarity]
	if not weight or egg.totalWeight <= 0 then
		return 0
	end
	return weight / egg.totalWeight
end

for _, def in definitions do
	assert(Eggs.ByKey[def.key] == nil, `[Eggs] Дубликат ключа "{def.key}"`)
	Eggs.ByKey[def.key] = def

	assert(def.price > 0, `[Eggs] У "{def.key}" цена должна быть больше нуля`)

	local total = 0
	for rarity, weight in def.weights do
		assert(
			table.find(Pets.Rarities, rarity) ~= nil,
			`[Eggs] У "{def.key}" неизвестная редкость "{rarity}"`
		)
		assert(weight > 0, `[Eggs] У "{def.key}" вес редкости "{rarity}" не больше нуля`)
		total += weight
	end

	assert(
		total > 0,
		`[Eggs] У "{def.key}" пустая весовая таблица: яйцо ничего не выдаст`
	)
	def.totalWeight = total

	table.freeze(def.weights)
	table.freeze(def)
end

table.freeze(definitions)
table.freeze(Eggs.ByKey)

return Eggs
