--!strict
--[[
	ArenaDecorController — всё, что растёт на арене: холмы, деревья, опушка,
	кусты, трава, камни.

	ПОЧЕМУ НА КЛИЕНТЕ. По тому же правилу, что и декор лобби: на сервере
	остаётся только то, во что игрок упирается. Здесь это ещё выгоднее —
	декора больше тысячи деталей, и реплицировать их на двадцать арен значило
	бы держать на сервере два десятка тысяч Part ради картинки, которую видит
	по одному игроку каждая.

	ЧТО ИМЕННО СТРОИТ КЛИЕНТ. Не «то же самое, только красивее»: тело холма
	и ствол дерева уже стоят — их построил ArenaService, они и есть коллизия.
	Клиент их ОДЕВАЕТ: земляная шапка и валуны на холм, крона на ствол.
	Второй слой той же геометрии удвоил бы её и разъехался бы с коллизией
	при первой правке размеров.

	АНИМАЦИИ ЗДЕСЬ НЕТ ВОВСЕ. Декор статичен: разложен один раз при старте
	забега и в кадре не стоит ничего. Качающаяся трава — это тысяча деталей
	в BulkMoveTo каждый кадр рядом с тремя сотнями врагов, то есть отнятый
	кадр там, где он дороже всего.

	Постройка идёт порциями с уступкой кадра (Shared/Util/Decor): тысяча
	Instance.new в одном кадре — это заметный рывок ровно в тот момент,
	когда игрок входит в бой.

	Сама постройка деталей, опушка и задник живут в Shared/Util/Decor: такой же
	лес растёт вокруг поляны лобби, и второй экземпляр той же геометрии
	разъехался бы с этим при первой правке. Здесь остался сценарий забега.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local ArenaLayout = require(Shared.Util.ArenaLayout)
local Balance = require(Shared.Config.Balance)
local Biomes = require(Shared.Config.Biomes)
local Decor = require(Shared.Util.Decor)
local Net = require(Shared.Net)
local Palette = require(Shared.Config.Palette)
local RNG = require(Shared.Util.RNG)
local SettingsController = require(script.Parent.SettingsController)

local ArenaDecorController = {}

local folder: Folder? = nil
--[[
	Номер забега. Постройка уступает кадр и потому может пережить свой забег:
	игрок вправе выйти в лобби через две секунды после входа. Каждая порция
	сверяет номер и бросает работу, если он сменился.
]]
local generation = 0

local function cleanup(): ()
	local existing = folder
	if existing then
		existing:Destroy()
		folder = nil
	end
end

--[[
	Пятна на полу. Ровный пол одного цвета читается пластиковым столом при
	любом материале, а пара десятков блинов другого оттенка превращает его
	в землю. Лежат чуть выше пола, чтобы не мерцать с ним гранями.
]]
local function buildPatches(parent: Instance, origin: Vector3, seed: number, palette: any, biome: Biomes.BiomeDef): ()
	local rng = RNG.new(seed + 4)
	local half = Balance.Arena.size * 0.5 - 20

	for index = 1, Balance.Arena.floorPatches do
		local size = rng.NextNumber(24, 70)
		local position = Vector3.new(rng.NextNumber(-half, half), 0.06, rng.NextNumber(-half, half))

		local patch = Decor.Part(
			parent,
			`Patch{index}`,
			Vector3.new(size, 0.12, size * rng.NextNumber(0.6, 1.4)),
			CFrame.new(origin + position) * CFrame.Angles(0, rng.NextAngle(), 0),
			Decor.Color(palette, if index % 3 == 0 then "patch" else "floorAccent"),
			biome.floorMaterial
		)
		patch.TopSurface = Enum.SurfaceType.Smooth
	end
end

local function build(slot: number, seed: number, paletteKey: string): ()
	local mine = generation
	local origin = Vector3.new(slot * Balance.Arena.spacing, 0, 0)

	local named: any = Palette.Arenas
	local palette: any = named[paletteKey] or Palette.Arena
	local biome = Biomes.Get(paletteKey)
	local quality = Balance.Quality[SettingsController.ResolveQuality()]

	local parent = Instance.new("Folder")
	parent.Name = "ArenaDecor"
	parent.Parent = Workspace
	folder = parent

	--[[
		Стена леса стоит дальше конца тумана от центра, поэтому из середины
		арены её не видно вовсе; она работает только тогда, когда игрок прижат
		к краю — то есть ровно тогда, когда видно и небо.
	]]
	local numbers = Balance.Arena
	Decor.Backdrop(
		parent,
		origin,
		palette,
		biome,
		numbers.size * 0.5,
		numbers.treeLineOffset,
		numbers.treeLineDepth,
		numbers.wallBandHeight
	)
	buildPatches(parent, origin, seed, palette, biome)

	-- Постройка бросается, если забег сменился: она уступает кадр и потому
	-- может пережить свой забег — игрок вправе выйти в лобби через секунду.
	local function alive(): boolean
		return generation == mine
	end

	--[[
		Порядок не случаен: сначала то, без чего арена выглядит сломанной
		(одежда препятствий), потом опушка, и только потом мелочь. Если
		игрок выйдет в лобби посреди постройки, брошенной окажется трава,
		а не половина холмов.
	]]
	local ok, chunk = Decor.PlaceAll(parent, ArenaLayout.ObstacleDecor(seed, biome), origin, palette, 0, alive)
	if not ok then
		return
	end

	local treeLine = ArenaLayout.TreeLine(seed, biome, quality.arenaTreeLineStep)
	ok, chunk = Decor.PlaceAll(parent, treeLine, origin, palette, chunk, alive)
	if not ok then
		return
	end

	local scatter = ArenaLayout.Decor(seed, biome, quality.arenaScatter, quality.arenaGrass)
	Decor.PlaceAll(parent, scatter, origin, palette, chunk, alive)
end

function ArenaDecorController.Start(): ()
	Net.GetEvent(Net.Id.RunStarted).OnClientEvent:Connect(
		function(slot: number, seed: number, _magnet: number, _mode: string, _stageIndex: number, paletteKey: string)
			generation += 1
			cleanup()
			--[[
				Постройка уступает кадр, поэтому идёт отдельным потоком:
				обработчик события не имеет права висеть — за ним в очереди
				стоят все остальные подписчики старта забега.
			]]
			task.spawn(build, slot, seed, paletteKey)
		end
	)

	Net.GetEvent(Net.Id.RunEnded).OnClientEvent:Connect(function()
		--[[
			Декор уничтожается вместе с забегом, в отличие от пулов эффектов.
			Держать его между забегами незачем: следующая арена почти наверняка
			другой локации, и с другим seed от прежнего леса не годится
			ни одно дерево.
		]]
		generation += 1
		cleanup()
	end)
end

return ArenaDecorController
