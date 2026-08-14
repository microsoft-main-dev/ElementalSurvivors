--!strict
--[[
	LobbyForestController — лес вокруг поляны лобби: опушка за невидимой
	стеной, тёмный задник за ней, подстилка под всем этим и подлесок
	на самой поляне.

	ЗАЧЕМ. Поляна 260×260 обрывалась трёхстадным бортиком, за которым сразу
	небо: горизонт читался прямой линией, а место — плитой в пустоте. На арене
	это уже решено и принято, поэтому решается тем же кодом (Shared/Util/Decor)
	и теми же деревьями (Config/ArenaProps): лобби и Лесная поляна — один
	и тот же лес, и свой набор деревьев для края завёл бы второй лес рядом
	с первым.

	ПОЧЕМУ ОТДЕЛЬНЫМ КОНТРОЛЛЕРОМ, А НЕ ЧАСТЬЮ LobbyDecorController. Там
	анимированные предметы из Config/Props, и любая ошибка в его Start()
	забирает у игрока весь лобби целиком вместе с промптами и панелями.
	Здесь статичная геометрия, которая строится один раз и в кадре не стоит
	ничего; отдельным контроллером она не может утащить за собой ничего.

	ЛЕС НЕ РАЗБИРАЕТСЯ на время забега, в отличие от арендного. Разбирать
	нечего: он статичен, в кадре не участвует, а лобби всё равно ждёт игрока
	в пяти тысячах стадов от арены. Собрать его заново по возвращении стоило
	бы тысячи созданий деталей на каждом выходе из боя (108 стволов, восемь
	плит и около шестисот деталей подлеска на High; на Low вчетверо меньше —
	травы там нет вовсе).
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Balance = require(Shared.Config.Balance)
local Biomes = require(Shared.Config.Biomes)
local Decor = require(Shared.Util.Decor)
local Palette = require(Shared.Config.Palette)
local Props = require(Shared.Config.Props)
local SettingsController = require(script.Parent.SettingsController)

local LobbyForestController = {}

--[[
	Лес вокруг лобби — это Лесная поляна, первая локация сюжета. Отсюда
	и деревья, и цвета: у поляны лобби уже её материал травы (LobbyService),
	и хвоя другого оттенка за краем читалась бы стыком двух миров.
]]
local BIOME_KEY = "ForestGlade"

--[[
	Seed постоянный: у всех игроков лес обязан быть один и тот же. Разные
	деревья у двоих, стоящих рядом, читаются поломкой, а не разнообразием.
]]
local SEED = 20260814

--[[
	Палитра опушки — локационная, но земля за краем берётся у самой поляны.

	Пол Лесной поляны заметно темнее и холоднее травы лобби, и на стыке у
	бортика это была бы полоса другого газона. Всё остальное (стволы, хвоя,
	листва, цвет задника) остаётся локационным: там расхождения нет, лес
	за краем и должен быть темнее освещённой поляны.
]]
local function paletteFor(): any
	local source: any = Palette.Arenas[BIOME_KEY]
	-- Копия, а не сама палитра: она заморожена и общая с ареной.
	local result: any = table.clone(source)

	result.floor = Palette.Lobby.grass
	return result
end

--[[
	Отступ мелочи от края поляны. Опушка начинается в шести стадах за краем,
	и куст, поставленный вплотную к нему, оказался бы наполовину внутри ствола.
]]
local GRASS_MARGIN = 8

--[[
	Просвет вокруг того, что уже стоит. Куст, растущий из фонаря или из тумбы
	с яйцом, читается поломкой, а не густотой.
]]
local PROP_CLEARANCE = 4

--[[
	Куда мелочи нельзя.

	Площадь целиком: мостовая — не место для папоротника, и мелочь у объектов
	взаимодействия закрывала бы их подходы. Кладка портала — по правилу самого
	Config/Props, чтобы описание крыльца оставалось в одном месте. И просвет
	вокруг каждого уже стоящего предмета.

	Предметы перебираются подряд, без пространственного индекса: их около
	сотни, а точек проверяется пара сотен — это тысячи сравнений один раз
	при входе в игру, а не в кадре.
]]
local function blockedForScatter(position: Vector3): boolean
	if position.Magnitude < Balance.Lobby.plazaRadius + 2 then
		return true
	end

	if Props.OnPortalWalk(position) then
		return true
	end

	for _, placement in Props.Placements do
		if (position - placement.position).Magnitude < PROP_CLEARANCE then
			return true
		end
	end

	return false
end

local function build(): ()
	local numbers = Balance.Lobby
	local half = numbers.floorSize * 0.5

	local biome = Biomes.Get(BIOME_KEY)
	local palette = paletteFor()
	local quality = Balance.Quality[SettingsController.ResolveQuality()]

	local parent = Instance.new("Folder")
	parent.Name = "LobbyForest"
	parent.Parent = Workspace

	Decor.Backdrop(
		parent,
		Vector3.zero,
		palette,
		biome,
		half,
		numbers.treeLineOffset,
		numbers.treeLineDepth,
		numbers.backdropHeight
	)

	--[[
		Шаг стволов берётся из арендного рычага качества намеренно: это
		буквально та же опушка тем же кодом, и вторая ручка для неё
		разъехалась бы с первой при первой же подкрутке.
	]]
	local trees =
		Decor.TreeRing(SEED, biome, quality.arenaTreeLineStep, half, numbers.treeLineOffset, numbers.treeLineDepth)

	--[[
		Бросать постройку не по чему: лобби одно на всё время жизни клиента
		и не пересобирается никогда.
	]]
	local function alive(): boolean
		return true
	end

	local ok, chunk = Decor.PlaceAll(parent, trees, Vector3.zero, palette, 0, alive)
	if not ok then
		return
	end

	--[[
		Порядок тот же, что на арене: сначала край, без которого место выглядит
		сломанным, и только потом мелочь под ногами.

		Бюджеты берутся арендные (Quality.arenaScatter и arenaGrass). На поляне
		это выйдет заметно плотнее: площадь под мелочь тут около 54 000 стадов
		против 160 000 у арены. Так и надо — по арене бегут, а в лобби стоят
		и разглядывают.
	]]
	local scatter =
		Decor.Scatter(SEED + 1, biome, quality.arenaScatter, quality.arenaGrass, half - GRASS_MARGIN, blockedForScatter)

	Decor.PlaceAll(parent, scatter, Vector3.zero, palette, chunk, alive)
end

function LobbyForestController.Start(): ()
	--[[
		Качество спрашивается ДО того, как приедет профиль с настройками:
		ResolveQuality в этот момент отвечает по устройству (телефон — Low),
		и это ровно тот случай, ради которого рычаг и заведён. Игрок, вручную
		выбравший Low на компьютере, получит лес плотности High до следующего
		входа — деревья статичны и кадр не занимают, а ждать профиль значило
		бы рисковать лобби без края вовсе, если событие разминётся с подпиской.
	]]
	build()
end

return LobbyForestController
