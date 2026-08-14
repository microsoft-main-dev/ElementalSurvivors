--!strict
--[[
	ArenaService — слоты арен и их геометрия (раздел 2 и 5 ТЗ).

	Арена слота i строится в точке (i * spacing, 0, 0), максимум maxSlots штук.
	При выходе игрока арена уничтожается, слот освобождается.

	Что строится на сервере: пол, невидимые стены по периметру, площадка выхода
	и ТЕЛА ПРЕПЯТСТВИЙ — тело холма и ствол дерева. Всё это нужно физике игрока,
	поэтому без вариантов должно быть Instance-ами.

	Что НЕ строится на сервере: декор. Его собирает клиент сам из seed
	(см. ArenaDecorController) — это экономит сотни реплицируемых партов
	и заодно означает, что чужие арены для игрока выглядят пустыми площадками
	за туманом.

	Граница между ними проходит ровно по коллизии: клиент ОДЕВАЕТ то, что
	построил сервер (шапка и валуны на холм, крона на ствол), а не строит
	своё поверх. Второй слой той же геометрии удвоил бы её и разъехался бы
	с коллизией при первой же правке размеров.

	Публичный API:
		ArenaService.Acquire(player, paletteKey) -> number?   -- слот или nil, если мест нет
		ArenaService.Release(player)
		ArenaService.GetSlot(player)      -> number?
		ArenaService.GetOrigin(slot)      -> Vector3
		ArenaService.GetSeed(slot)        -> number
		ArenaService.GetSpawnCFrame(slot) -> CFrame
		ArenaService.GetExitPrompt(slot)  -> ProximityPrompt?
		ArenaService.IsPlayerInSlot(player, slot) -> boolean  -- для проверок на сервере
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local ArenaLayout = require(Shared.Util.ArenaLayout)
local Balance = require(Shared.Config.Balance)
local Biomes = require(Shared.Config.Biomes)
local Palette = require(Shared.Config.Palette)

type Slot = {
	index: number,
	player: Player?,
	folder: Folder?,
	seed: number,
	-- Ключ локации: он же ключ палитры и биома. Приходит из CombatService,
	-- считается один раз в Stages.PaletteFor и больше нигде.
	paletteKey: string,
	exitPrompt: ProximityPrompt?,
}

local ArenaService = {}

local slots: { Slot } = {}
local slotByPlayer: { [Player]: number } = {}
local arenasFolder: Folder? = nil

local function getArenasFolder(): Folder
	local folder = arenasFolder
	if folder then
		return folder
	end
	local created = Instance.new("Folder")
	created.Name = "Arenas"
	created.Parent = Workspace
	arenasFolder = created
	return created
end

local function makePart(name: string, size: Vector3, position: Vector3, color: Color3, parent: Instance): Part
	local part = Instance.new("Part")
	part.Name = name
	part.Size = size
	part.Position = position
	part.Color = color
	part.Material = Enum.Material.SmoothPlastic
	part.Anchored = true
	part.TopSurface = Enum.SurfaceType.Smooth
	part.BottomSurface = Enum.SurfaceType.Smooth
	part.Parent = parent
	return part
end

--[[
	Вертикальный цилиндр.

	У Part с Shape = Cylinder ось идёт вдоль X, поэтому вертикальным он
	становится поворотом на 90 вокруг Z, а размер задаётся как
	(высота, диаметр, диаметр). Это же правило действует во всех моделях
	проекта — см. angles = (0, 0, 90) у стволов в Config/Props.
]]
local function makeColumn(
	name: string,
	radius: number,
	height: number,
	position: Vector3,
	angle: number,
	color: Color3,
	material: Enum.Material,
	parent: Instance
): Part
	local part = makePart(name, Vector3.new(height, radius * 2, radius * 2), position, color, parent)
	part.Shape = Enum.PartType.Cylinder
	part.Material = material
	part.CFrame = CFrame.new(position) * CFrame.Angles(0, angle, 0) * CFrame.Angles(0, 0, math.pi * 0.5)
	part.CanCollide = true
	part.CastShadow = false
	return part
end

--[[
	Палитра локации. Локация без своей записи откатывается на общую —
	забытый цвет не должен ронять бой, ровно как на клиенте.
]]
local function paletteOf(key: string): typeof(Palette.Arena)
	local named: any = Palette.Arenas
	return named[key] or Palette.Arena
end

local function buildArena(slot: Slot): ()
	local origin = ArenaService.GetOrigin(slot.index)
	local numbers = Balance.Arena
	local size = numbers.size
	local thickness = numbers.floorThickness
	local wallHeight = numbers.wallHeight
	local half = size / 2

	local palette = paletteOf(slot.paletteKey)
	local biome = Biomes.Get(slot.paletteKey)

	local folder = Instance.new("Folder")
	folder.Name = `Arena{slot.index}`
	folder.Parent = getArenasFolder()

	local floor = makePart(
		"Floor",
		Vector3.new(size, thickness, size),
		origin + Vector3.new(0, -thickness / 2, 0),
		palette.floor,
		folder
	)
	-- Материал берётся у биома: трава под ногами на поляне и голая земля
	-- в чаще — это встроенные материалы движка, а не ассеты.
	floor.Material = biome.floorMaterial

	--[[
		Бок платформы: земляная подошва под полом.

		Основную работу — «за краем арены продолжается лес, а не небо» — делает
		подстилка под опушкой, но она клиентская и появляется не мгновенно:
		декор собирается порциями. Юбка стоит с первого кадра и закрывает срез
		пола, поэтому арена не успевает мелькнуть плитой, висящей в воздухе.

		Два яруса с поджатием: ровный параллелепипед читается коробкой,
		а сужающийся книзу — куском земли.
	]]
	local skirtDepth = numbers.skirtDepth

	local skirtTop = makePart(
		"Skirt1",
		Vector3.new(size - 6, skirtDepth * 0.55, size - 6),
		origin + Vector3.new(0, -thickness - skirtDepth * 0.275, 0),
		palette.earth,
		folder
	)
	skirtTop.Material = Enum.Material.Ground
	skirtTop.CanCollide = false
	skirtTop.CanQuery = false
	skirtTop.CanTouch = false

	local skirtBottom = makePart(
		"Skirt2",
		Vector3.new(size - 40, skirtDepth * 0.6, size - 40),
		origin + Vector3.new(0, -thickness - skirtDepth * 0.75, 0),
		palette.earthDark,
		folder
	)
	skirtBottom.Material = Enum.Material.Rock
	skirtBottom.CanCollide = false
	skirtBottom.CanQuery = false
	skirtBottom.CanTouch = false

	-- Невидимые стены: игрок не должен уходить за пределы арены.
	local sides = {
		Vector3.new(0, 0, -half),
		Vector3.new(0, 0, half),
		Vector3.new(-half, 0, 0),
		Vector3.new(half, 0, 0),
	}

	for index, offset in sides do
		local wallSize = if offset.X == 0
			then Vector3.new(size + 8, wallHeight, 4)
			else Vector3.new(4, wallHeight, size + 8)

		local wall = makePart(
			`Wall{index}`,
			wallSize,
			origin + offset + Vector3.new(0, wallHeight / 2, 0),
			palette.floor,
			folder
		)
		wall.Transparency = 1
		wall.CanCollide = true
		wall.CanQuery = false
		wall.CanTouch = false
	end

	--[[
		Тела препятствий. Строятся на сервере, потому что это настоящая
		коллизия, а физика игрока проверяется сервером. Расстановка берётся
		из ArenaLayout по seed — тот же самый набор получают EnemyService
		и клиентская симуляция, поэтому враги обходят ровно то, что видно.

		Оба вида — цилиндры, и это не упрощение: расталкивание сравнивает
		расстояние с радиусом, то есть препятствие И ЕСТЬ круг. Коробка
		на его месте оставляла бы углы, в которые враг не заходит,
		а игрок в них помещается.

		Одевает их клиент (ArenaDecorController): земляная шапка и валуны
		на холм, крона на ствол. Если он почему-то не соберётся, арена
		останется играбельной — препятствия видно и так.
	]]
	for index, obstacle in ArenaLayout.Generate(slot.seed) do
		if obstacle.kind == "Hill" then
			makeColumn(
				`Hill{index}`,
				obstacle.radius,
				obstacle.size.Y,
				origin + obstacle.position + Vector3.new(0, obstacle.size.Y * 0.5, 0),
				obstacle.angle,
				palette.earth,
				Enum.Material.Ground,
				folder
			)
		else
			makeColumn(
				`Trunk{index}`,
				obstacle.radius,
				obstacle.size.Y,
				origin + obstacle.position + Vector3.new(0, obstacle.size.Y * 0.5, 0),
				obstacle.angle,
				palette.trunk,
				Enum.Material.Wood,
				folder
			)
		end
	end

	-- Площадка выхода: единственный способ покинуть арену живым.
	local exitPad = makePart(
		"ExitPad",
		Vector3.new(14, 0.6, 14),
		origin + Vector3.new(0, 0.3, numbers.exitOffset),
		palette.exit,
		folder
	)
	exitPad.Material = Enum.Material.Neon
	exitPad.CanCollide = false

	local prompt = Instance.new("ProximityPrompt")
	prompt.Name = "ExitPrompt"
	prompt.ObjectText = "Arena"
	prompt.ActionText = "Return to lobby"
	prompt.HoldDuration = 0.6
	prompt.MaxActivationDistance = 12
	prompt.RequiresLineOfSight = false
	prompt.Parent = exitPad

	slot.folder = folder
	slot.exitPrompt = prompt
end

function ArenaService.Init(): ()
	for index = 1, Balance.Arena.maxSlots do
		slots[index] = {
			index = index,
			player = nil,
			folder = nil,
			seed = 0,
			paletteKey = "",
			exitPrompt = nil,
		}
	end
end

function ArenaService.GetOrigin(slot: number): Vector3
	return Vector3.new(slot * Balance.Arena.spacing, 0, 0)
end

function ArenaService.GetSpawnCFrame(slot: number): CFrame
	return CFrame.new(ArenaService.GetOrigin(slot) + Vector3.new(0, 4, 0))
end

--[[
	Занять слот и построить арену.

	paletteKey — ключ локации (Stages.PaletteFor). Он нужен ДО постройки:
	от него зависят и материал пола, и цвет земли, и породы, которыми клиент
	эту арену засадит. Ключ без записи откатывается на общую палитру.
]]
function ArenaService.Acquire(player: Player, paletteKey: string): number?
	if slotByPlayer[player] then
		return nil -- игрок уже в бою
	end

	for _, slot in slots do
		if slot.player == nil then
			slot.player = player
			slot.seed = math.random(1, 2 ^ 31 - 1)
			slot.paletteKey = paletteKey
			slotByPlayer[player] = slot.index
			buildArena(slot)
			return slot.index
		end
	end

	return nil
end

function ArenaService.Release(player: Player): ()
	local index = slotByPlayer[player]
	if not index then
		return
	end

	local slot = slots[index]
	slotByPlayer[player] = nil
	slot.player = nil
	slot.paletteKey = ""
	slot.exitPrompt = nil

	local folder = slot.folder
	if folder then
		folder:Destroy()
		slot.folder = nil
	end
end

function ArenaService.GetSlot(player: Player): number?
	return slotByPlayer[player]
end

function ArenaService.GetSeed(slot: number): number
	return slots[slot].seed
end

function ArenaService.GetExitPrompt(slot: number): ProximityPrompt?
	return slots[slot].exitPrompt
end

function ArenaService.IsPlayerInSlot(player: Player, slot: number): boolean
	return slotByPlayer[player] == slot
end

return ArenaService
