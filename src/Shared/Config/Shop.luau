--!strict
--[[
	Shop — прилавок лобби (раздел 4 ТЗ).

	В M4 магазин торгует только тем, что в игре существует: яйцами (поштучно
	и пачкой со скидкой) и опытом питомцу. Расходники, батлпасс, VIP и донатная
	валюта из раздела 4 — это M7, и появятся они дописыванием строк сюда,
	а не правкой кода: ShopService разбирает лот по полю kind.

	Пачка яиц — не просто удобство: десять роллов подряд это ещё и то, чем
	проще всего глазами сверить шансы, не залезая в Output.
]]

local Eggs = require(script.Parent.Eggs)
local Types = require(script.Parent.Parent.Types)

type CurrencyKind = Types.CurrencyKind

--[[
	kind определяет, что сервер сделает после списания:
		egg    — count роллов яйца с ключом target
		petXp  — count опыта питомцу, которого игрок выберет при покупке
]]
export type ShopLotKind = "egg" | "petXp"

export type ShopLot = {
	key: string,
	kind: ShopLotKind,
	target: string, -- ключ яйца для "egg"; для "petXp" не используется
	displayName: string,
	description: string,
	currency: CurrencyKind,
	price: number,
	count: number,
}

local Shop = {}

local lots: { ShopLot } = {
	{
		key = "BasicEgg10",
		kind = "egg",
		target = "Basic",
		displayName = "Basic Egg x10",
		description = "Ten rolls at once, one egg cheaper than buying them apart.",
		currency = "essence",
		price = 126000, -- десять яиц по 14000 минус одно: скидка ровно в яйцо
		count = 10,
	},
	{
		key = "GreaterEgg10",
		kind = "egg",
		target = "Greater",
		displayName = "Greater Egg x10",
		description = "Ten better rolls, one egg cheaper.",
		currency = "essence",
		price = 405000,
		count = 10,
	},
	{
		key = "PetXpSmall",
		kind = "petXp",
		target = "",
		displayName = "Training Treat",
		description = "100 experience for the pet you pick.",
		currency = "essence",
		price = 8000,
		count = 100,
	},
	{
		key = "PetXpLarge",
		kind = "petXp",
		target = "",
		displayName = "Training Feast",
		description = "600 experience for the pet you pick, at a discount.",
		currency = "essence",
		price = 44000,
		count = 600,
	},
}

Shop.Lots = lots
Shop.ByKey = {} :: { [string]: ShopLot }

for _, lot in lots do
	assert(Shop.ByKey[lot.key] == nil, `[Shop] Дубликат ключа "{lot.key}"`)
	Shop.ByKey[lot.key] = lot

	assert(lot.price > 0, `[Shop] У "{lot.key}" цена должна быть больше нуля`)
	assert(lot.count > 0, `[Shop] У "{lot.key}" count должен быть больше нуля`)

	if lot.kind == "egg" then
		local egg = Eggs.ByKey[lot.target]
		assert(
			egg,
			`[Shop] Лот "{lot.key}" ссылается на несуществующее яйцо "{lot.target}"`
		)
		-- Пачка обязана быть выгоднее поштучной покупки, иначе лот бессмыслен.
		assert(
			lot.price < egg.price * lot.count,
			`[Shop] Лот "{lot.key}" стоит дороже, чем {lot.count} яиц по отдельности`
		)
		assert(
			lot.currency == egg.currency,
			`[Shop] Лот "{lot.key}" продаётся за {lot.currency}, а само яйцо — за {egg.currency}`
		)
	end

	table.freeze(lot)
end

table.freeze(lots)
table.freeze(Shop.ByKey)

return Shop
