--!strict
--[[
	Monetization — товары за Robux (раздел 9 ТЗ), M7.

	Решение владельца: вечных геймпассов в игре нет вообще. Всё продаваемое —
	повторяемая покупка через дев-продукт, поэтому здесь только дев-продукты,
	а MarketplaceService:UserOwnsGamePassAsync в проекте не вызывается нигде.

	Ноль в productId означает «продукт ещё не заведён в Creator Dashboard»:
	лот показывается неактивным, а не роняет панель — так же устроен ноль
	в Config/Branding. Это позволяет писать и проверять весь код выдачи до того,
	как у владельца появятся настоящие id.

	Цен в Robux здесь нет и быть не может: цену задаёт Creator Dashboard,
	и меняется она без правки кода.

	Почему числа выдачи лежат здесь, а не в Balance: срок и множитель — это
	личность товара, а не балансный коэффициент. «x2 на сутки» перестаёт быть
	тем же товаром, если поменять 2 или сутки, а игрок покупал его по описанию
	из Creator Dashboard. Тихая правка такого числа превратила бы магазин
	в обман; правка Balance такого свойства не имеет.

	Публичный API:
		Monetization.Products     -> { ProductDef }
		Monetization.ByKey        -> { [string]: ProductDef }
		Monetization.ByProductId  -> { [number]: ProductDef }
		Monetization.Boosts       -> { [string]: BoostDef }
		Monetization.Charges      -> { [string]: ChargeDef }
		Monetization.VipBoostKey  -> string
		Monetization.IsConfigured(product) -> boolean
]]

local Types = require(script.Parent.Parent.Types)

type ProductDef = Types.ProductDef
type BoostDef = Types.BoostDef
type ChargeDef = Types.ChargeDef

local HOUR = 3600
local DAY = 24 * HOUR

local Monetization = {}

--[[
	VIP — это обычный бустер, просто с собственным сроком хранения:
	purchases.vipUntil существует в схеме профиля с M3 (раздел 6 ТЗ),
	и заводить ему второе место в purchases.boosters означало бы держать
	один факт в двух полях.
]]
Monetization.VipBoostKey = "Vip"

local boosts: { [string]: BoostDef } = {
	EssenceX2 = {
		key = "EssenceX2",
		displayName = "Double Essence",
		essenceMult = 2,
		offlineCapMult = 1,
		wheelRate = 1,
	},

	--[[
		VIP собирает всё сразу: доход за забег, потолок экспедиций и колесо.
		Смысл пакета в том, что он выгоднее любого отдельного бустера, —
		иначе покупать его незачем.
	]]
	Vip = {
		key = "Vip",
		displayName = "VIP",
		essenceMult = 2,
		offlineCapMult = 2,
		-- Колесо готово вдвое быстрее. Это и есть «лишняя прокрутка в сутки»,
		-- только без второго счётчика в профиле: период и так считается
		-- от отметки последней прокрутки.
		wheelRate = 2,
	},
}

local charges: { [string]: ChargeDef } = {
	--[[
		Заряд сгорает на любом засчитанном забеге, включая проигранный
		(решение владельца): покупка страхует попытку, а не результат.
		На поражении множитель ляжет на утешительные 10% — выплата выйдет
		маленькой, и это задуманное поведение, а не потеря товара.
	]]
	LuckyRun = {
		key = "LuckyRun",
		displayName = "Lucky Run",
		essenceMult = 10,
	},
}

local products: { ProductDef } = {
	{
		key = "PrismsSmall",
		kind = "prisms",
		productId = 3613036391,
		displayName = "Handful of Prisms",
		description = "80 Prisms. Exactly one Prism Egg.",
		grant = { prisms = 80, boost = "", seconds = 0, charge = "", count = 0 },
	},
	{
		key = "PrismsMedium",
		kind = "prisms",
		productId = 3613036418,
		displayName = "Pouch of Prisms",
		description = "200 Prisms. One Radiant Egg, or two Prism Eggs and change.",
		grant = { prisms = 200, boost = "", seconds = 0, charge = "", count = 0 },
	},
	{
		key = "PrismsLarge",
		kind = "prisms",
		productId = 3613036439,
		displayName = "Chest of Prisms",
		description = "450 Prisms.",
		grant = { prisms = 450, boost = "", seconds = 0, charge = "", count = 0 },
	},
	{
		key = "PrismsHuge",
		kind = "prisms",
		productId = 3613036454,
		displayName = "Vault of Prisms",
		description = "1200 Prisms.",
		grant = { prisms = 1200, boost = "", seconds = 0, charge = "", count = 0 },
	},

	{
		key = "BoostHour",
		kind = "boost",
		productId = 3613036477,
		displayName = "Double Essence — 1 hour",
		description = "Every run pays twice as much Essence for one hour.",
		grant = { prisms = 0, boost = "EssenceX2", seconds = HOUR, charge = "", count = 0 },
	},
	{
		key = "BoostDay",
		kind = "boost",
		productId = 3613036506,
		displayName = "Double Essence — 1 day",
		description = "Every run pays twice as much Essence for a full day.",
		grant = { prisms = 0, boost = "EssenceX2", seconds = DAY, charge = "", count = 0 },
	},
	{
		key = "BoostWeek",
		kind = "boost",
		productId = 3613036540,
		displayName = "Double Essence — 7 days",
		description = "Every run pays twice as much Essence for a week.",
		grant = { prisms = 0, boost = "EssenceX2", seconds = 7 * DAY, charge = "", count = 0 },
	},

	{
		key = "LuckyRun",
		kind = "charge",
		productId = 3613036579,
		displayName = "Lucky Run",
		description = "Ten times the Essence from your next finished run. Win or lose, it is spent.",
		grant = { prisms = 0, boost = "", seconds = 0, charge = "LuckyRun", count = 1 },
	},

	{
		key = "Vip30",
		kind = "vip",
		productId = 3613036609,
		displayName = "VIP — 30 days",
		description = "Double Essence, double expedition storage and a faster wheel for 30 days.",
		grant = { prisms = 0, boost = "Vip", seconds = 30 * DAY, charge = "", count = 0 },
	},
}

Monetization.Products = products
Monetization.Boosts = boosts
Monetization.Charges = charges
Monetization.ByKey = {} :: { [string]: ProductDef }
Monetization.ByProductId = {} :: { [number]: ProductDef }

-- Продукт заведён у владельца и его можно предлагать к покупке.
function Monetization.IsConfigured(product: ProductDef): boolean
	return product.productId > 0
end

for _, boost in boosts do
	assert(
		boost.essenceMult >= 1,
		`[Monetization] У бустера "{boost.key}" множитель Essence меньше единицы`
	)
	assert(
		boost.offlineCapMult >= 1,
		`[Monetization] У бустера "{boost.key}" множитель оффлайна меньше единицы`
	)
	assert(
		boost.wheelRate >= 1,
		`[Monetization] У бустера "{boost.key}" колесо медленнее обычного`
	)
	table.freeze(boost)
end

for _, charge in charges do
	assert(charge.essenceMult > 1, `[Monetization] Заряд "{charge.key}" ничего не даёт`)
	table.freeze(charge)
end

assert(
	boosts[Monetization.VipBoostKey],
	`[Monetization] Нет бустера VIP с ключом "{Monetization.VipBoostKey}"`
)

for _, product in products do
	assert(Monetization.ByKey[product.key] == nil, `[Monetization] Дубликат ключа "{product.key}"`)
	Monetization.ByKey[product.key] = product

	--[[
		Незаведённые продукты в ByProductId не попадают: ноль там был бы одним
		ключом сразу для всех, и первый же настоящий чек с нулевым id (а такого
		не бывает) выдал бы случайный товар. Дешевле не заводить эту дырку вовсе.
	]]
	if Monetization.IsConfigured(product) then
		assert(
			Monetization.ByProductId[product.productId] == nil,
			`[Monetization] Два товара с одним productId {product.productId}`
		)
		Monetization.ByProductId[product.productId] = product
	end

	local grant = product.grant

	if product.kind == "prisms" then
		assert(grant.prisms > 0, `[Monetization] Товар "{product.key}" не выдаёт Prisms`)
	elseif product.kind == "boost" or product.kind == "vip" then
		assert(
			boosts[grant.boost],
			`[Monetization] Товар "{product.key}" ссылается на бустер "{grant.boost}"`
		)
		assert(grant.seconds > 0, `[Monetization] У товара "{product.key}" нулевой срок`)
	elseif product.kind == "charge" then
		assert(
			charges[grant.charge],
			`[Monetization] Товар "{product.key}" ссылается на заряд "{grant.charge}"`
		)
		assert(grant.count > 0, `[Monetization] Товар "{product.key}" выдаёт ноль зарядов`)
	end

	table.freeze(grant)
	table.freeze(product)
end

table.freeze(products)
table.freeze(boosts)
table.freeze(charges)
table.freeze(Monetization.ByKey)
table.freeze(Monetization.ByProductId)

return Monetization
