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

	Постройка идёт порциями с уступкой кадра: тысяча Instance.new в одном
	кадре — это заметный рывок ровно в тот момент, когда игрок входит в бой.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local ArenaLayout = require(Shared.Util.ArenaLayout)
local ArenaProps = require(Shared.Config.ArenaProps)
local Balance = require(Shared.Config.Balance)
local Biomes = require(Shared.Config.Biomes)
local Net = require(Shared.Net)
local Palette = require(Shared.Config.Palette)
local RNG = require(Shared.Util.RNG)
local SettingsController = require(script.Parent.SettingsController)

local ArenaDecorController = {}

-- Сколько деталей создаётся между уступками кадра.
local PARTS_PER_CHUNK = 120

local SHAPES: { [string]: Enum.PartType } = {
	Block = Enum.PartType.Block,
	Ball = Enum.PartType.Ball,
	Cylinder = Enum.PartType.Cylinder,
}

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
	Цвет по имени из палитры локации.

	Имена сверены при загрузке (Config/Biomes требует их у каждой палитры),
	поэтому здесь остаётся только откат на белый — на случай, если деталь
	добавят раньше, чем цвет.
]]
local function colorOf(palette: any, name: string): Color3
	return palette[name] or Color3.new(1, 1, 1)
end

local function makePart(
	parent: Instance,
	name: string,
	size: Vector3,
	cframe: CFrame,
	color: Color3,
	material: Enum.Material
): BasePart
	local part = Instance.new("Part")
	part.Name = name
	part.Size = size
	part.CFrame = cframe
	part.Color = color
	part.Material = material
	part.Anchored = true
	--[[
		Ни коллизии, ни лучей, ни касаний. Коллизия здесь была бы прямым
		враньём: препятствия перечислены в ArenaLayout, и то, чего в этом
		списке нет, враги обходить не умеют.
	]]
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.CastShadow = false
	part.TopSurface = Enum.SurfaceType.Smooth
	part.BottomSurface = Enum.SurfaceType.Smooth
	part.Parent = parent
	return part
end

--[[
	Одна деталь модели декора.

	scale множит и размер, и смещение: дерево вдвое выше обязано быть вдвое
	толще и нести крону вдвое дальше от земли. Поворот применяется ПОСЛЕ
	смещения, как и во всех сборщиках проекта, иначе наклонённая деталь
	уезжала бы вместе с наклоном.
]]
local function spawnPart(parent: Instance, def: ArenaProps.PartDef, pivot: CFrame, scale: number, palette: any): ()
	local angles = def.angles
	local rotation = if angles
		then CFrame.Angles(math.rad(angles.X), math.rad(angles.Y), math.rad(angles.Z))
		else CFrame.identity

	local cframe = pivot * CFrame.new(def.offset * scale) * rotation

	if def.shape == "Wedge" then
		-- Клин — отдельный класс, а не форма Part: тонкие былинки травы
		-- и листья папоротника собираются только из него.
		local wedge = Instance.new("WedgePart")
		wedge.Name = "Blade"
		wedge.Size = def.size * scale
		wedge.CFrame = cframe
		wedge.Color = colorOf(palette, def.color)
		wedge.Material = def.material or Enum.Material.SmoothPlastic
		wedge.Anchored = true
		wedge.CanCollide = false
		wedge.CanQuery = false
		wedge.CanTouch = false
		wedge.CastShadow = false
		wedge.Parent = parent
		return
	end

	local part = makePart(
		parent,
		"Piece",
		def.size * scale,
		cframe,
		colorOf(palette, def.color),
		def.material or Enum.Material.SmoothPlastic
	)
	part.Shape = SHAPES[def.shape] or Enum.PartType.Block
end

--[[
	Земля за ареной и стена леса за ней.

	Оба нужны по одной причине: за краем платформы — пустое небо, и без них
	арена читается плитой, висящей в воздухе, что бы на ней ни росло.

	Стена стоит дальше конца тумана от центра, поэтому из середины арены её
	не видно вовсе; она работает только тогда, когда игрок прижат к краю —
	то есть ровно тогда, когда видно и небо.
]]
local function buildBackdrop(parent: Instance, origin: Vector3, palette: any, biome: Biomes.BiomeDef): ()
	local numbers = Balance.Arena
	local half = numbers.size * 0.5
	local band = half + numbers.treeLineOffset + numbers.treeLineDepth + 27
	local reach = band + 8
	local width = reach - half
	local middle = half + width * 0.5

	--[[
		Подстилка под опушкой — КОЛЬЦО из четырёх блоков, а не один блин.

		Блин был проще, но его верх приходилось топить ниже пола арены: два
		совпадающих по высоте лица (его и пола) мерцают друг сквозь друга
		по всей арене. Утопленный блин, в свою очередь, оставлял ступеньку —
		деревья опушки висели над землёй, а под стеной леса светилась щель.

		Кольцо не пересекается с полом вовсе, поэтому его верх ставится ровно
		на ноль: земля за краем арены продолжается без стыка, и всё, что на
		ней стоит, стоит на ней по-настоящему. Швов между четырьмя кусками
		не видно — они одного цвета и материала и сходятся вплотную.
	]]
	local plates = {
		{ offset = Vector3.new(0, 0, -middle), size = Vector3.new(reach * 2, 2, width) },
		{ offset = Vector3.new(0, 0, middle), size = Vector3.new(reach * 2, 2, width) },
		{ offset = Vector3.new(-middle, 0, 0), size = Vector3.new(width, 2, half * 2) },
		{ offset = Vector3.new(middle, 0, 0), size = Vector3.new(width, 2, half * 2) },
	}

	for index, plate in plates do
		local ground = makePart(
			parent,
			`OuterGround{index}`,
			plate.size,
			CFrame.new(origin + plate.offset + Vector3.new(0, -1, 0)),
			colorOf(palette, "floor"),
			biome.floorMaterial
		)
		ground.TopSurface = Enum.SurfaceType.Smooth
	end

	local sides = {
		Vector3.new(0, 0, -band),
		Vector3.new(0, 0, band),
		Vector3.new(-band, 0, 0),
		Vector3.new(band, 0, 0),
	}

	--[[
		Стена уходит НИЖЕ земли на пару стадов.

		Поставленная точно на ноль, она давала светящуюся щель по всему
		периметру: любая неточность в стыке двух граней — это просвет,
		а за просветом небо, которое туман не красит вовсе.
	]]
	local sink = 3
	local height = numbers.wallBandHeight + sink

	for index, offset in sides do
		local length = band * 2 + 12
		local size = if offset.X == 0 then Vector3.new(length, height, 6) else Vector3.new(6, height, length)

		makePart(
			parent,
			`Backdrop{index}`,
			size,
			CFrame.new(origin + offset + Vector3.new(0, height * 0.5 - sink, 0)),
			colorOf(palette, "wall"),
			Enum.Material.Slate
		)
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

		local patch = makePart(
			parent,
			`Patch{index}`,
			Vector3.new(size, 0.12, size * rng.NextNumber(0.6, 1.4)),
			CFrame.new(origin + position) * CFrame.Angles(0, rng.NextAngle(), 0),
			colorOf(palette, if index % 3 == 0 then "patch" else "floorAccent"),
			biome.floorMaterial
		)
		patch.TopSurface = Enum.SurfaceType.Smooth
	end
end

--[[
	Разложить пачку декора, уступая кадр каждые PARTS_PER_CHUNK деталей.

	Возвращает false, если забег сменился и работу пора бросить, и счётчик
	деталей текущей порции. Счётчик передаётся между вызовами, а не живёт
	в модуле: постройка прошлого забега может ещё доживать свой кадр рядом
	с новой, и общий счётчик перемешал бы их границы.
]]
local function placeAll(
	parent: Instance,
	items: { ArenaLayout.Decor },
	origin: Vector3,
	palette: any,
	mine: number,
	chunk: number
): (boolean, number)
	for _, item in items do
		local parts = item.parts or ArenaProps.ByKey[item.key].parts
		local pivot = CFrame.new(origin + item.position) * CFrame.Angles(0, math.rad(item.yaw), 0)

		for _, def in parts do
			spawnPart(parent, def, pivot, item.scale, palette)
		end

		chunk += #parts
		if chunk >= PARTS_PER_CHUNK then
			chunk = 0
			task.wait()
			if generation ~= mine then
				return false, chunk
			end
		end
	end

	return true, chunk
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

	buildBackdrop(parent, origin, palette, biome)
	buildPatches(parent, origin, seed, palette, biome)

	--[[
		Порядок не случаен: сначала то, без чего арена выглядит сломанной
		(одежда препятствий), потом опушка, и только потом мелочь. Если
		игрок выйдет в лобби посреди постройки, брошенной окажется трава,
		а не половина холмов.
	]]
	local ok, chunk = placeAll(parent, ArenaLayout.ObstacleDecor(seed, biome), origin, palette, mine, 0)
	if not ok then
		return
	end

	local treeLine = ArenaLayout.TreeLine(seed, biome, quality.arenaTreeLineStep)
	ok, chunk = placeAll(parent, treeLine, origin, palette, mine, chunk)
	if not ok then
		return
	end

	local scatter = ArenaLayout.Decor(seed, biome, quality.arenaScatter, quality.arenaGrass)
	placeAll(parent, scatter, origin, palette, mine, chunk)
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
