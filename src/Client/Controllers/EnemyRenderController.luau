--!strict
--[[
	EnemyRenderController — отрисовка врагов (раздел 3.3 ТЗ).

	Сервер шлёт только события (спавн/смерть) пачками раз в 100 мс и по кругу
	досылает точные позиции части врагов. Между этими сообщениями клиент
	симулирует движение сам тем же кодом из Shared/Util/EnemyMotion.

	Клиент повторяет ТОЛЬКО преследование, без расталкивания: у него другой набор
	соседей, и Separation здесь накапливал бы расхождение вместо того, чтобы
	его гасить. Разница между клиентом и сервером ограничена радиусом
	расталкивания (пара стадов) и постоянно подрезается ресинхронизацией.

	Ноль Instance.new в бою: все части берутся из пула. Части без коллизий,
	без запросов и без физики — они чистая графика.

	Публичный API:
		EnemyRenderController.GetActiveCount() -> number   (для отладочного оверлея)
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Balance = require(Shared.Config.Balance)
local Enemies = require(Shared.Config.Enemies)
local EnemyMotion = require(Shared.Util.EnemyMotion)
local Net = require(Shared.Net)
local Packet = require(Shared.Util.Packet)
local Palette = require(Shared.Config.Palette)
local Pool = require(Shared.Util.Pool)

local DEATH_FLASH_TIME = 0.09
local PREWARM = 340

local EnemyRenderController = {}

local player = Players.LocalPlayer

local active = false
local origin = Vector3.zero

-- Состояние врагов, индексируется серверным id.
local positions: { Vector3 } = {}
local offsets: { Vector3 } = {} -- невязка после ресинхронизации, затухает к нулю
local typeIds: { number } = {}
local phases: { number } = {}
local parts: { Part? } = {}
-- Разреженный словарь, а не массив: мёртвые id удаляются, чтобы обход
-- каждого кадра шёл только по живым врагам.
local isAlive: { [number]: boolean } = {}
local activeCount = 0

-- Гаснущие части убитых врагов: {часть, момент возврата в пул}.
local fadingParts: { Part } = {}
local fadingUntil: { number } = {}
local fadingCount = 0

local container: Folder? = nil
local partPool: Pool.Pool<Part>? = nil

-- Переиспользуемые массивы для BulkMoveTo и разбора пакетов.
local moveParts: { BasePart } = {}
local moveCFrames: { CFrame } = {}
local lastMoveCount = 0
local resyncIds: { number } = {}
local resyncPositions: { Vector3 } = {}

local function resetPart(part: Part): ()
	part.Parent = nil
end

local function createPart(): Part
	local part = Instance.new("Part")
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.Massless = true
	part.CastShadow = false
	part.TopSurface = Enum.SurfaceType.Smooth
	part.BottomSurface = Enum.SurfaceType.Smooth
	return part
end

local function getPool(): Pool.Pool<Part>
	local pool = partPool
	if pool then
		return pool
	end
	local created = Pool.new(createPart, resetPart, PREWARM)
	partPool = created
	return created
end

local function clearAll(): ()
	local pool = partPool
	if pool then
		pool.ReleaseAll()
	end

	table.clear(positions)
	table.clear(offsets)
	table.clear(typeIds)
	table.clear(phases)
	table.clear(parts)
	table.clear(isAlive)
	table.clear(fadingParts)
	table.clear(fadingUntil)
	activeCount = 0
	fadingCount = 0
	lastMoveCount = 0
	table.clear(moveParts)
	table.clear(moveCFrames)
end

local function applySpawn(id: number, typeId: number, position: Vector3): ()
	local def = Enemies.List[typeId]
	if not def then
		return
	end

	local part = getPool().Get()
	part.Shape = if def.model.shape == "Ball"
		then Enum.PartType.Ball
		elseif def.model.shape == "Cylinder" then Enum.PartType.Cylinder
		else Enum.PartType.Block
	part.Size = def.model.size
	part.Color = Palette.Element[def.element]
	part.Material = if def.model.neon then Enum.Material.Neon else Enum.Material.SmoothPlastic
	part.Transparency = 0
	part.CFrame = CFrame.new(origin + Vector3.new(position.X, def.model.size.Y * 0.5, position.Z))
	part.Parent = container

	positions[id] = position
	offsets[id] = Vector3.zero
	typeIds[id] = typeId
	phases[id] = (id % 32) * 0.4
	parts[id] = part
	isAlive[id] = true
end

local function applyDespawn(id: number, reason: number): ()
	if not isAlive[id] then
		return
	end
	isAlive[id] = nil

	local part = parts[id]
	parts[id] = nil
	if not part then
		return
	end

	if reason == Packet.Reason.Killed then
		-- Вспышка вместо анимации смерти (раздел 2.1 ТЗ).
		part.Material = Enum.Material.Neon
		part.Color = Palette.Brand.white
		fadingCount += 1
		fadingParts[fadingCount] = part
		fadingUntil[fadingCount] = os.clock() + DEATH_FLASH_TIME
	else
		getPool().Release(part)
	end
end

local function updateFading(now: number): ()
	local index = 1
	while index <= fadingCount do
		if now >= fadingUntil[index] then
			getPool().Release(fadingParts[index])
			fadingParts[index] = fadingParts[fadingCount]
			fadingUntil[index] = fadingUntil[fadingCount]
			fadingParts[fadingCount] = nil :: any
			fadingCount -= 1
		else
			index += 1
		end
	end
end

local function getPlayerLocalPosition(): Vector3?
	local character = player.Character
	if not character then
		return nil
	end
	local root = character:FindFirstChild("HumanoidRootPart") :: BasePart?
	if not root then
		return nil
	end
	local world = root.Position - origin
	return Vector3.new(world.X, 0, world.Z)
end

local function onHeartbeat(deltaTime: number): ()
	local now = os.clock()
	updateFading(now)

	if not active then
		return
	end

	local playerLocal = getPlayerLocalPosition()
	if not playerLocal then
		return
	end

	-- Затухание невязки: врага не дёргает при ресинхронизации, он подъезжает.
	local decay = math.clamp(deltaTime / Balance.Combat.resyncBlendTime, 0, 1)
	local bobSpeed = Balance.Combat.bobSpeed
	local bobAmplitude = Balance.Combat.bobAmplitude

	local count = 0
	activeCount = 0

	for id, aliveFlag in isAlive do
		if aliveFlag then
			local part = parts[id]
			if part then
				local def = Enemies.List[typeIds[id]]
				local position = EnemyMotion.Chase(positions[id], playerLocal, def.stats.speed, deltaTime)
				positions[id] = position

				local offset = offsets[id]
				if offset ~= Vector3.zero then
					offset = offset:Lerp(Vector3.zero, decay)
					offsets[id] = offset
				end

				local bob = EnemyMotion.BobOffset(phases[id], now, bobSpeed, bobAmplitude)
				local height = def.model.size.Y * 0.5 + bob

				count += 1
				moveParts[count] = part
				moveCFrames[count] =
					CFrame.new(origin + Vector3.new(position.X + offset.X, height, position.Z + offset.Z))
				activeCount += 1
			end
		end
	end

	-- Хвост от прошлого кадра надо обнулить, иначе BulkMoveTo подвинет лишнее.
	for index = count + 1, lastMoveCount do
		moveParts[index] = nil :: any
		moveCFrames[index] = nil :: any
	end
	lastMoveCount = count

	if count > 0 then
		Workspace:BulkMoveTo(moveParts, moveCFrames, Enum.BulkMoveMode.FireCFrameChanged)
	end
end

local function onRunStarted(slot: number, _seed: number): ()
	clearAll()

	origin = Vector3.new(slot * Balance.Arena.spacing, 0, 0)

	local folder = Instance.new("Folder")
	folder.Name = "Enemies"
	folder.Parent = Workspace
	container = folder

	getPool()
	active = true
end

local function onRunEnded(_reason: string): ()
	active = false
	clearAll()

	local folder = container
	if folder then
		folder:Destroy()
		container = nil
	end

	local pool = partPool
	if pool then
		pool.Destroy()
		partPool = nil
	end
end

local function onEvents(data: buffer): ()
	if not active then
		return
	end

	local spawns, despawns = Packet.ReadEvents(data)
	for _, record in spawns do
		applySpawn(record.id, record.typeId, record.position)
	end
	for _, record in despawns do
		applyDespawn(record.id, record.reason)
	end
end

local function onResync(data: buffer): ()
	if not active then
		return
	end

	local count = Packet.ReadResync(data, resyncIds, resyncPositions)
	for index = 1, count do
		local id = resyncIds[index]
		if isAlive[id] then
			local exact = resyncPositions[index]
			-- Позицию принимаем сразу, а видимую разницу гасим постепенно.
			offsets[id] = positions[id] - exact
			positions[id] = exact
		end
	end
end

function EnemyRenderController.GetActiveCount(): number
	return activeCount
end

function EnemyRenderController.Start(): ()
	Net.GetEvent(Net.Id.RunStarted).OnClientEvent:Connect(onRunStarted)
	Net.GetEvent(Net.Id.RunEnded).OnClientEvent:Connect(onRunEnded)
	Net.GetEvent(Net.Id.EnemyEvents).OnClientEvent:Connect(onEvents)
	Net.GetUnreliable(Net.Id.EnemyResync).OnClientEvent:Connect(onResync)

	RunService.Heartbeat:Connect(onHeartbeat)
end

return EnemyRenderController
