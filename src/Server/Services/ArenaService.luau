--!strict
--[[
	ArenaService — слоты арен и их геометрия (раздел 2 и 5 ТЗ).

	Арена слота i строится в точке (i * spacing, 0, 0), максимум maxSlots штук.
	При выходе игрока арена уничтожается, слот освобождается.

	Что строится на сервере: пол, невидимые стены по периметру и площадка выхода.
	Всё это нужно физике игрока, поэтому без вариантов должно быть Instance-ами.

	Что НЕ строится на сервере: декор. Его собирает клиент сам из seed
	(см. ArenaController) — это экономит сотни реплицируемых партов и заодно
	означает, что чужие арены для игрока выглядят пустыми площадками за туманом.

	Публичный API:
		ArenaService.Acquire(player)      -> number?          -- слот или nil, если мест нет
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
local Palette = require(Shared.Config.Palette)

type Slot = {
	index: number,
	player: Player?,
	folder: Folder?,
	seed: number,
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

local function buildArena(slot: Slot): ()
	local origin = ArenaService.GetOrigin(slot.index)
	local size = Balance.Arena.size
	local thickness = Balance.Arena.floorThickness
	local wallHeight = Balance.Arena.wallHeight
	local half = size / 2

	local folder = Instance.new("Folder")
	folder.Name = `Arena{slot.index}`
	folder.Parent = getArenasFolder()

	makePart(
		"Floor",
		Vector3.new(size, thickness, size),
		origin + Vector3.new(0, -thickness / 2, 0),
		Palette.Arena.floor,
		folder
	)

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
			Palette.Arena.floor,
			folder
		)
		wall.Transparency = 1
		wall.CanCollide = true
		wall.CanQuery = false
		wall.CanTouch = false
	end

	--[[
		Колонны. Строятся на сервере, потому что это настоящие препятствия
		с коллизией, а физика игрока проверяется сервером. Расстановка берётся
		из ArenaLayout по seed — тот же самый набор получают EnemyService
		и клиентская симуляция, поэтому враги обходят ровно то, что видно.
	]]
	for index, obstacle in ArenaLayout.Generate(slot.seed) do
		local pillar = makePart(
			`Pillar{index}`,
			obstacle.size,
			origin + obstacle.position + Vector3.new(0, obstacle.size.Y * 0.5, 0),
			Palette.Arena.decor,
			folder
		)
		pillar.CFrame = CFrame.new(pillar.Position) * CFrame.Angles(0, obstacle.angle, 0)
		pillar.CanCollide = true
		pillar.CastShadow = false

		-- Неоновая полоса у основания: силуэт читается даже в тумане.
		local base = makePart(
			`PillarBase{index}`,
			Vector3.new(obstacle.size.X + 1.6, 0.5, obstacle.size.Z + 1.6),
			origin + obstacle.position + Vector3.new(0, 0.25, 0),
			Palette.Arena.decorAccent,
			folder
		)
		base.CFrame = CFrame.new(base.Position) * CFrame.Angles(0, obstacle.angle, 0)
		base.Material = Enum.Material.Neon
		base.CanCollide = false
		base.CanQuery = false
		base.CanTouch = false
		base.CastShadow = false
	end

	-- Площадка выхода: единственный способ покинуть арену живым.
	local exitPad = makePart(
		"ExitPad",
		Vector3.new(14, 0.6, 14),
		origin + Vector3.new(0, 0.3, Balance.Arena.exitOffset),
		Palette.Arena.exit,
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
		slots[index] = { index = index, player = nil, folder = nil, seed = 0, exitPrompt = nil }
	end
end

function ArenaService.GetOrigin(slot: number): Vector3
	return Vector3.new(slot * Balance.Arena.spacing, 0, 0)
end

function ArenaService.GetSpawnCFrame(slot: number): CFrame
	return CFrame.new(ArenaService.GetOrigin(slot) + Vector3.new(0, 4, 0))
end

function ArenaService.Acquire(player: Player): number?
	if slotByPlayer[player] then
		return nil -- игрок уже в бою
	end

	for _, slot in slots do
		if slot.player == nil then
			slot.player = player
			slot.seed = math.random(1, 2 ^ 31 - 1)
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
