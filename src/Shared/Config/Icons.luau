--!strict
--[[
	Icons — Asset ID всех картинок интерфейса.

	Одно место на весь проект. Класть id рядом с данными («картинка яйца в
	Config/Eggs, картинка товара в Config/Monetization») было бы удобно ровно
	до первой загрузки новой пачки: искать, куда вписать сорок чисел, пришлось бы
	по семи файлам. Здесь же весь список виден сразу, и сразу видно, чего ещё нет.

	Ноль означает «ассета нет» — панель рисует то же, что рисовала до картинок.
	Так устроены Config/Branding и Config/Sounds, и так это останется: ассет может
	снять модерация, и игра обязана пережить это без единой правки кода.

	Ключи проверяются при загрузке по тем же конфигам, которые их и заводят:
	опечатка в ключе питомца или забытый новый товар роняют модуль сразу,
	а не оборачиваются молча не нарисованной иконкой через месяц.

	ЗДЕСЬ ЛЕЖАТ id КАРТИНОК, А НЕ ДЕКАЛОВ. Загрузка через Asset Manager отдаёт
	номер Decal — обёртки, внутри которой лежит собственно картинка со СВОИМ,
	совершенно другим номером. ImageLabel принимает только второй: с номером
	декала интерфейс молча рисует пустые квадраты, потому что ошибки в этом
	случае нет — просто нечего показать. На это уже наступили однажды, все 64
	номера пришлось менять разом. Как достать правильные — в assets/icons/README.

	Исходники PNG лежат в assets/icons, там же README с назначением каждой.

	Публичный API:
		Icons.Image(assetId) -> string?
]]

local Abilities = require(script.Parent.Abilities)
local Eggs = require(script.Parent.Eggs)
local Items = require(script.Parent.Items)
local Monetization = require(script.Parent.Monetization)
local Palette = require(script.Parent.Palette)
local Pets = require(script.Parent.Pets)
local Shop = require(script.Parent.Shop)
local Stages = require(script.Parent.Stages)

type Table = { [string]: number }

local Icons = {}

-- Питомцы: круг стихии с обводкой редкости рисует PetIcon, в файле только зверь.
Icons.Pets = {
	EmberCub = 104671477789112,
	FrostPup = 97665736170882,
	MossSprout = 124012012516266,
	SparkKit = 110986479022593,
	DuskMoth = 102851385782578,
	GlowFinch = 83941315314727,
	MagmaHound = 70844091010369,
	GlacierOwl = 103240076914847,
	StormDrake = 78381445087158,
	VoidLynx = 73497173901245,
	SolarPhoenix = 113697653328537,
	VerdantWarden = 135694178290724,
} :: Table

--[[
	Способности. Картинка обязана показывать ФОРМУ (кольцо, конус, цепь):
	по иконке в HUD игрок узнаёт, что у него сейчас работает, и нова вместо
	цепи врала бы ему каждый бой.
]]
Icons.Abilities = {
	FireOrbit = 109190539197051,
	EmberTrail = 106699146089418,
	IceShard = 83847195479320,
	FrostBurst = 83467459417126,
	ThornAura = 106795982721520,
	SeedVolley = 110308274324764,
	ChainSpark = 129587692978786,
	StormArc = 81539074742274,
	StormNova = 81492025789990,
	ShadowNeedle = 124095431511244,
	WingGust = 134597234125014,
	VoidFangs = 95331356588485,
	LightBurst = 110891658732540,
	MoteHalo = 84504055918079,
	SolarFlare = 119369967693215,
} :: Table

-- Стихии. Нужны там, где показан не питомец, а требование: слот корма эволюции.
Icons.Elements = {
	Fire = 77489791672450,
	Ice = 136227380234422,
	Lightning = 78951184901008,
	Nature = 138624777528583,
	Dark = 80415894319183,
	Light = 89637951184618,
} :: Table

Icons.Gear = {
	Helmet = 133266796517903,
	Chest = 109765778863404,
	Boots = 113331410611168,
	-- Файл называется equip_amulet: слот у нас Trinket, картинка та самая.
	Trinket = 133018028208547,
} :: Table

--[[
	Расходники в инвентаре. Ключи — бустеры и заряды из Config/Monetization,
	картинки те же, что у соответствующих товаров в магазине: это один и тот же
	предмет, просто в одном месте его покупают, а в другом он лежит.
]]
Icons.Consumables = {
	-- Те же картинки, что у товаров ниже. Файлы consumable_* не подошли:
	-- нарисованы зелье, эликсир и магнит, а таких предметов в игре нет.
	EssenceX2 = 86412355562356,
	Vip = 121877119909714,
	LuckyRun = 79229807920402,
} :: Table

Icons.Currency = {
	essence = 71723001208019,
	prisms = 94523125097868,
} :: Table

Icons.Eggs = {
	Basic = 78501017671049,
	Greater = 114943924942641,
	Prime = 72590002697684,
	Prism = 130498354740211,
	Radiant = 94991294542850,
} :: Table

Icons.Shop = {
	BasicEgg10 = 73590932643338,
	GreaterEgg10 = 71803992937944,
	PetXpSmall = 117207267087299,
	PetXpLarge = 99837700236484,
} :: Table

Icons.Products = {
	PrismsSmall = 81173311309223,
	PrismsMedium = 107215139540976,
	PrismsLarge = 87510875990068,
	PrismsHuge = 81654818353473,
	BoostHour = 78975511512834,
	BoostDay = 86412355562356,
	BoostWeek = 104471650022054,
	LuckyRun = 79229807920402,
	Vip30 = 121877119909714,
} :: Table

Icons.Locations = {
	ForestGlade = 71286409767141,
	DeepForest = 86104209888874,
} :: Table

--[[
	Всё, что не образует группы. Стрелка обучения и приз в ступице колеса —
	по одной картинке на всю игру, и заводить каждой свою таблицу незачем.
]]
Icons.Misc = {
	TutorialArrow = 113943803061862,
	WheelPrize = 75663468631545,
} :: Table

--[[
	Значки интерфейса: семь кнопок панели лобби плюс служебные.

	У этой группы нет конфига-владельца, по которому сверять ключи, — их заводит
	сам интерфейс. Поэтому опечатка здесь не уронит модуль, а просто оставит
	кнопку без картинки. Держать список коротким и рядом с потребителем важнее
	обычного.
]]
Icons.Ui = {
	Inventory = 80122462891261,
	Eggs = 135324519520781,
	Shop = 78719945281799,
	Talents = 98833799945119,
	Daily = 100845485681710,
	Store = 124563622599130,
	Settings = 127157498093204,

	Close = 122366225252974,
	Back = 128397829225143,
	Pointer = 103147319147652,
	Scrollbar = 86690247580168,
} :: Table

--[[
	Значки узлов дерева талантов по виду эффекта. Ключи — те же, что у
	TalentEffect.kind в Config/Talents: 157 узлов, но видов эффекта пять,
	а стихию узел несёт цветом, поэтому иконок нужно ровно пять.
]]
Icons.Talents = {
	ElementDamage = 91481888777056,
	ElementCooldown = 86500254997448,
	MaxHealth = 127447074927580,
	WalkSpeed = 82594074799860,
	MagnetRadius = 108799268485718,
} :: Table

--[[
	Скин каркаса: куски, которые тянутся под размер.

	Все они рисуются девятью кусками (ScaleType = Slice) — у растянутой обычной
	картинки поплыли бы углы. Сама разбивка на куски лежит не здесь, а в UiKit
	рядом с местом отрисовки: id — это данные, а геометрия — уже вёрстка.
]]
Icons.Skin = {
	FrameWindow = 89910829872842,
	FrameRow = 99340825630167,
	FrameSlot = 106330987604074,

	ButtonNormal = 100121458916443,
	ButtonPressed = 90263901726440,
	ButtonDisabled = 124371605169318,

	TabActive = 98694943218520,
	TabIdle = 113319369469834,

	BarBackground = 94695328980306,
	BarFill = 108203115241730,
} :: Table

--[[
	Ссылка на картинку или nil, если ассета нет.

	Единственное место в проекте, где собирается строка rbxassetid://. Вызывающий
	получает nil и рисует то, что рисовал раньше, — проверка «id больше нуля»
	не должна расползтись по девяти панелям.
]]
function Icons.Image(assetId: number?): string?
	if not assetId or assetId <= 0 then
		return nil
	end
	return `rbxassetid://{assetId}`
end

--[[
	Сверка ключей с конфигом-владельцем. Обе стороны обязательны: лишний ключ —
	это опечатка, а недостающий — новая запись в конфиге, которой забыли завести
	иконку. Второе тише и потому опаснее.
]]
local function checkKeys(name: string, icons: Table, known: { [string]: boolean }): ()
	for key, assetId in icons do
		assert(known[key], `[Icons] "{name}" ссылается на несуществующий ключ "{key}"`)
		assert(assetId >= 0, `[Icons] у "{name}.{key}" отрицательный Asset ID`)
	end
	for key in known do
		assert(icons[key] ~= nil, `[Icons] в "{name}" нет ключа "{key}"`)
	end
end

-- Множество ключей из таблицы вида { [key]: def }.
local function keysOf(source: { [string]: any }): { [string]: boolean }
	local set: { [string]: boolean } = {}
	for key in source do
		set[key] = true
	end
	return set
end

-- Множество ключей из списка записей с полем key.
local function keysOfList(source: { any }): { [string]: boolean }
	local set: { [string]: boolean } = {}
	for _, entry in source do
		set[entry.key] = true
	end
	return set
end

local consumables: { [string]: boolean } = keysOf(Monetization.Boosts)
for key in Monetization.Charges do
	consumables[key] = true
end

local slots: { [string]: boolean } = {}
for _, slot in Items.Slots do
	slots[slot] = true
end

checkKeys("Pets", Icons.Pets, keysOf(Pets.ByKey))
checkKeys("Abilities", Icons.Abilities, keysOf(Abilities.ByKey))
checkKeys("Elements", Icons.Elements, keysOf(Palette.Element))
checkKeys("Gear", Icons.Gear, slots)
checkKeys("Consumables", Icons.Consumables, consumables)
checkKeys("Currency", Icons.Currency, { essence = true, prisms = true })
checkKeys("Eggs", Icons.Eggs, keysOf(Eggs.ByKey))
checkKeys("Shop", Icons.Shop, keysOf(Shop.ByKey))
checkKeys("Products", Icons.Products, keysOf(Monetization.ByKey))
checkKeys("Locations", Icons.Locations, keysOfList(Stages.Locations))

table.freeze(Icons.Pets)
table.freeze(Icons.Abilities)
table.freeze(Icons.Elements)
table.freeze(Icons.Gear)
table.freeze(Icons.Consumables)
table.freeze(Icons.Currency)
table.freeze(Icons.Eggs)
table.freeze(Icons.Shop)
table.freeze(Icons.Products)
--[[
	У Ui, Talents и Skin конфига-владельца нет: их ключи заводит сам интерфейс.
	Проверяем только то, что вообще проверяемо, — что число не отрицательное.
]]
for _, group in { Icons.Ui, Icons.Talents, Icons.Skin } do
	for key, assetId in group do
		assert(assetId >= 0, `[Icons] у "{key}" отрицательный Asset ID`)
	end
end

table.freeze(Icons.Locations)
table.freeze(Icons.Misc)
table.freeze(Icons.Ui)
table.freeze(Icons.Talents)
table.freeze(Icons.Skin)

return table.freeze(Icons)
