--!strict
--[[
	Biomes — чем засажена локация: материал пола и состав растительности.

	Разделение с Config/Palette намеренное и держится на одном правиле: цвета
	живут в палитре, потому что палитра — единственное место, где цвета игры
	вообще лежат. Здесь только состав и пропорции: какие деревья растут, что
	стоит опушкой, что рассыпано под ногами.

	КЛЮЧ ТОТ ЖЕ, что у Palette.Arenas, и сверяется в ОБЕ стороны: биом без
	палитры красить нечем, палитра без биома означает, что новую локацию
	забыли населить, и её арена окажется голой плитой. Оба случая обязаны
	падать при загрузке, а не выясняться на живом забеге.

	Публичный API:
		Biomes.ByKey                -> { [string]: BiomeDef }
		Biomes.Get(paletteKey)      -> BiomeDef
		Biomes.Pick(list, rng)      -> Species
]]

local ArenaProps = require(script.Parent.ArenaProps)
local Palette = require(script.Parent.Palette)
local RNG = require(script.Parent.Parent.Util.RNG)

local Biomes = {}

--[[
	Вид растения в биоме: модель, её вес в жеребьёвке и разброс размера.

	Разброс обязателен. Ряд одинаковых елей читается забором ровно так же,
	как читался бы ряд одинаковых деревьев в лобби, и никакой поворот этого
	не лечит: силуэт-то один и тот же.
]]
export type Species = {
	key: string,
	weight: number,
	minScale: number,
	maxScale: number,
}

export type BiomeDef = {
	key: string,
	--[[
		Материал пола. Встроенные материалы движка — не ассеты (правило 4
		их не касается), и «трава под ногами» стоит ровно одно поле.
	]]
	floorMaterial: Enum.Material,
	trees: { Species }, -- кроны деревьев-препятствий: их стволы строит сервер
	treeLine: { Species }, -- стена леса за периметром арены
	scatter: { Species }, -- мелочь без коллизии
	grass: { Species }, -- трава: свой бюджет и свой рычаг качества
}

local definitions: { BiomeDef } = {
	--[[
		Лесная поляна: светлый лиственный лес. Ели редкие — на поляне они
		гостьи, и именно поэтому их видно.

		Сухостоя здесь нет вовсе: это первая локация, и мёртвое дерево на
		солнечной поляне читалось бы обещанием опасности, которого локация
		не выполняет.
	]]
	{
		key = "ForestGlade",
		floorMaterial = Enum.Material.LeafyGrass,
		trees = {
			{ key = "CrownBroad", weight = 4, minScale = 1, maxScale = 1 },
			{ key = "CrownPine", weight = 1, minScale = 1, maxScale = 1 },
		},
		treeLine = {
			{ key = "WallBroad", weight = 3, minScale = 1, maxScale = 1.5 },
			{ key = "WallPine", weight = 2, minScale = 1.1, maxScale = 1.6 },
		},
		scatter = {
			{ key = "Bush", weight = 4, minScale = 0.8, maxScale = 1.4 },
			{ key = "Fern", weight = 3, minScale = 0.8, maxScale = 1.3 },
			{ key = "Rock", weight = 2, minScale = 0.7, maxScale = 1.5 },
			{ key = "Stump", weight = 1, minScale = 0.9, maxScale = 1.2 },
			{ key = "Log", weight = 1, minScale = 0.9, maxScale = 1.3 },
			{ key = "Flower", weight = 4, minScale = 0.9, maxScale = 1.6 },
		},
		grass = {
			{ key = "GrassTuft", weight = 1, minScale = 0.8, maxScale = 1.6 },
		},
	},

	--[[
		Дремучий лес: хвоя, сухостой, грибы. Цветов нет — солнце сюда
		не достаёт, и жёлтое пятно на тёмном полу выглядело бы подобранным
		предметом, а не цветком.
	]]
	{
		key = "DeepForest",
		floorMaterial = Enum.Material.Ground,
		trees = {
			{ key = "CrownPine", weight = 5, minScale = 1, maxScale = 1 },
			{ key = "CrownDead", weight = 2, minScale = 1, maxScale = 1 },
			{ key = "CrownBroad", weight = 1, minScale = 1, maxScale = 1 },
		},
		treeLine = {
			{ key = "WallPine", weight = 5, minScale = 1.1, maxScale = 1.7 },
			{ key = "WallBroad", weight = 1, minScale = 1, maxScale = 1.3 },
		},
		scatter = {
			{ key = "Fern", weight = 4, minScale = 0.9, maxScale = 1.5 },
			{ key = "Stump", weight = 3, minScale = 0.9, maxScale = 1.4 },
			{ key = "Log", weight = 3, minScale = 1, maxScale = 1.5 },
			{ key = "Rock", weight = 3, minScale = 0.8, maxScale = 1.6 },
			{ key = "Mushroom", weight = 3, minScale = 0.9, maxScale = 1.8 },
			{ key = "Bush", weight = 2, minScale = 0.8, maxScale = 1.2 },
		},
		grass = {
			{ key = "GrassTuft", weight = 1, minScale = 0.7, maxScale = 1.3 },
		},
	},
}

Biomes.ByKey = {} :: { [string]: BiomeDef }

local function validateList(biomeKey: string, listName: string, list: { Species }): ()
	assert(#list > 0, `[Biomes] У биома "{biomeKey}" пустой список "{listName}"`)

	for _, species in list do
		--[[
			У дерева-препятствия размер задаёт расстановка (Balance.Arena.tree*),
			а не биом: ствол строит сервер, который биома не знает, и крона
			обязана совпасть с ним. Разброс здесь молча ничего бы не делал,
			а поле, которое ни на что не влияет, однажды покрутят.
		]]
		if listName == "trees" then
			assert(
				species.minScale == 1 and species.maxScale == 1,
				`[Biomes] Биом "{biomeKey}", "{species.key}": размер дерева-препятствия задаёт `
					.. "Balance.Arena.treeScale*, а не биом"
			)
		end

		assert(
			ArenaProps.ByKey[species.key] ~= nil,
			`[Biomes] Биом "{biomeKey}", список "{listName}": нет модели "{species.key}" в ArenaProps`
		)
		assert(
			species.weight > 0,
			`[Biomes] Биом "{biomeKey}", "{species.key}": вес обязан быть положительным`
		)
		assert(
			species.minScale > 0 and species.maxScale >= species.minScale,
			`[Biomes] Биом "{biomeKey}", "{species.key}": разброс размера задом наперёд`
		)
		table.freeze(species)
	end

	table.freeze(list)
end

for _, def in definitions do
	assert(Biomes.ByKey[def.key] == nil, `[Biomes] Дубликат ключа "{def.key}"`)
	Biomes.ByKey[def.key] = def

	validateList(def.key, "trees", def.trees)
	validateList(def.key, "treeLine", def.treeLine)
	validateList(def.key, "scatter", def.scatter)
	validateList(def.key, "grass", def.grass)

	table.freeze(def)
end

--[[
	Сверка с палитрами — та же в обе стороны, что у Config/Icons с его
	владельцами ключей. Лишний биом означает опечатку в ключе, недостающий —
	забытую локацию.
]]
local arenaPalettes: any = Palette.Arenas

for key in arenaPalettes do
	assert(
		Biomes.ByKey[key] ~= nil,
		`[Biomes] У локации "{key}" есть палитра, но нет биома`
	)
end

for key in Biomes.ByKey do
	assert(arenaPalettes[key] ~= nil, `[Biomes] У биома "{key}" нет палитры в Palette.Arenas`)
end

--[[
	Каждое имя цвета, которое спрашивает декор, обязано быть у КАЖДОЙ локации
	и у общей палитры-отката. Забытый цвет оставил бы деталь белой, а белое
	дерево посреди тёмного леса в тумане замечают не сразу.
]]
local function checkColors(name: string, record: any): ()
	for _, colorName in ArenaProps.ColorNames do
		assert(
			record[colorName] ~= nil,
			`[Biomes] В палитре "{name}" нет цвета "{colorName}", который спрашивает декор арены`
		)
	end
end

checkColors("Arena", Palette.Arena)

for key, record in arenaPalettes do
	checkColors(key, record)
end

--[[
	Биом локации. Ключ без записи откатывается на первый биом, а не роняет
	бой: сюда приходит и бесконечный режим, у которого локации может не быть
	вовсе (до первой победы в сюжете).
]]
function Biomes.Get(paletteKey: string): BiomeDef
	return Biomes.ByKey[paletteKey] or definitions[1]
end

--[[
	Жеребьёвка вида по весам. Веса целыми не обязаны быть и в сумму не
	нормируются: список правится чаще, чем читается, и требование «сумма
	равна ста» разъедется на первой же правке.
]]
function Biomes.Pick(list: { Species }, rng: RNG.RNG): Species
	local total = 0
	for _, species in list do
		total += species.weight
	end

	local roll = rng.NextNumber(0, total)
	for _, species in list do
		roll -= species.weight
		if roll <= 0 then
			return species
		end
	end

	return list[#list]
end

table.freeze(definitions)
table.freeze(Biomes.ByKey)

return Biomes
