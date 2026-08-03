--!strict
--[[
	EnemyRenderController — отрисовка врагов (раздел 3.3 ТЗ).

	Сервер шлёт события (спавн/смерть) пачками раз в 100 мс и по кругу досылает
	точные позиции части врагов. Между этими сообщениями клиент симулирует
	движение сам тем же кодом из Shared/Util/EnemyMotion.

	События применяются СТРОГО в порядке получения. Сервер переиспользует id
	умерших врагов почти сразу, поэтому в одной пачке id может быть сначала
	освобождён, а потом выдан новому врагу. Любая перестановка приводит
	к брошенным частям на арене и невидимым живым врагам.

	Клиент повторяет и преследование, и расталкивание — тем же шагом 1/30 с,
	что и сервер. Без расталкивания толпа на клиенте схлопывалась в плотный ком
	вокруг игрока, и то, что видно на экране, переставало совпадать с тем,
	по чему считается урон. Расхождение снимает круговая ресинхронизация.

	Ноль Instance.new в бою: все части берутся из пула.

	Публичный API:
		EnemyRenderController.GetActiveCount() -> number   (для отладочного оверлея)
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local ArenaLayout = require(Shared.Util.ArenaLayout)
local Balance = require(Shared.Config.Balance)
local Enemies = require(Shared.Config.Enemies)
local EnemyMotion = require(Shared.Util.EnemyMotion)
local Net = require(Shared.Net)
local Packet = require(Shared.Util.Packet)
local Palette = require(Shared.Config.Palette)
local Pool = require(Shared.Util.Pool)
local SpatialHash = require(Shared.Util.SpatialHash)

local DEATH_FLASH_TIME = 0.09
local PREWARM = 340

local EnemyRenderController = {}

local player = Players.LocalPlayer

local active = false
local origin = Vector3.zero
local accumulator = 0

-- Состояние врагов, индексируется серверным id.
local positions: { [number]: Vector3 } = {}
local offsets: { [number]: Vector3 } = {} -- невязка после ресинхронизации, затухает к нулю
local typeIds: { [number]: number } = {}
local phases: { [number]: number } = {}
local parts: { [number]: Part } = {}
local isAlive: { [number]: boolean } = {}
local highWater = 0
local activeCount = 0

-- Гаснущие части убитых врагов.
local fadingParts: { Part } = {}
local fadingUntil: { number } = {}
local fadingCount = 0

local container: Folder? = nil
local partPool: Pool.Pool<Part>? = nil
local hash = SpatialHash.new(Balance.Combat.cellSize)
local neighbours: { number } = {}

-- Колонны арены: тот же набор, что у сервера, из того же seed.
local obstacleHash = SpatialHash.new(Balance.Combat.cellSize * 2)
local obstaclePositions: { Vector3 } = {}
local obstacleRadii: { number } = {}
local obstacleQueryRadius = 0
local obstacleHits: { number } = {}

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
	table.clear(moveParts)
	table.clear(moveCFrames)
	hash.Clear()

	highWater = 0
	activeCount = 0
	fadingCount = 0
	lastMoveCount = 0
	accumulator = 0
end

local function applySpawn(id: number, typeId: number, position: Vector3): ()
	local def = Enemies.List[typeId]
	if not def then
		return
	end

	-- Страховка от потерянной смерти: если id всё ещё занят, часть надо вернуть
	-- в пул, иначе она останется висеть на арене навсегда.
	local previous = parts[id]
	if previous then
		getPool().Release(previous)
		parts[id] = nil
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

	if id > highWater then
		highWater = id
	end
end

local function applyDespawn(id: number, reason: number): ()
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

-- Один шаг симуляции, тот же 1/30 с, что и на сервере.
local function simulate(dt: number, playerLocal: Vector3): ()
	hash.Rebuild(positions, isAlive, highWater)

	local separationRadius = Balance.Combat.separationRadius
	local separationStrength = Balance.Combat.separationStrength
	local arenaSize = Balance.Arena.size
	local decay = math.clamp(dt / Balance.Combat.resyncBlendTime, 0, 1)

	for id = 1, highWater do
		if isAlive[id] then
			local def = Enemies.List[typeIds[id]]
			local position = EnemyMotion.Chase(positions[id], playerLocal, def.stats.speed, dt)

			local count = hash.Collect(position, separationRadius, neighbours)
			position = EnemyMotion.Separation(
				id,
				position,
				neighbours,
				positions,
				count,
				separationRadius,
				separationStrength,
				dt
			)

			if obstacleQueryRadius > 0 then
				local hits = obstacleHash.Collect(position, obstacleQueryRadius + def.stats.radius, obstacleHits)
				if hits > 0 then
					position = EnemyMotion.PushOutOfObstacles(
						position,
						obstacleHits,
						obstaclePositions,
						obstacleRadii,
						hits,
						def.stats.radius
					)
				end
			end

			positions[id] = EnemyMotion.ClampToArena(position, arenaSize)

			local offset = offsets[id]
			if offset ~= Vector3.zero then
				offsets[id] = offset:Lerp(Vector3.zero, decay)
			end
		end
	end
end

local function render(now: number): ()
	local bobSpeed = Balance.Combat.bobSpeed
	local bobAmplitude = Balance.Combat.bobAmplitude
	local count = 0

	for id = 1, highWater do
		if isAlive[id] then
			local part = parts[id]
			if part then
				local def = Enemies.List[typeIds[id]]
				local position = positions[id]
				local offset = offsets[id]
				local bob = EnemyMotion.BobOffset(phases[id], now, bobSpeed, bobAmplitude)

				count += 1
				moveParts[count] = part
				moveCFrames[count] = CFrame.new(
					origin + Vector3.new(position.X + offset.X, def.model.size.Y * 0.5 + bob, position.Z + offset.Z)
				)
			end
		end
	end

	-- Хвост от прошлого кадра надо обнулить, иначе BulkMoveTo подвинет лишнее.
	for index = count + 1, lastMoveCount do
		moveParts[index] = nil :: any
		moveCFrames[index] = nil :: any
	end
	lastMoveCount = count
	activeCount = count

	if count > 0 then
		Workspace:BulkMoveTo(moveParts, moveCFrames, Enum.BulkMoveMode.FireCFrameChanged)
	end
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

	local tickRate = Balance.Combat.tickRate
	accumulator += deltaTime

	local steps = 0
	while accumulator >= tickRate and steps < Balance.Combat.maxStepsPerFrame do
		accumulator -= tickRate
		steps += 1
		simulate(tickRate, playerLocal)
	end

	if accumulator >= tickRate then
		accumulator = 0
	end

	if steps > 0 then
		render(now)
	end
end

local function buildObstacles(seed: number): ()
	table.clear(obstaclePositions)
	table.clear(obstacleRadii)
	obstacleQueryRadius = 0

	local occupied: { boolean } = {}
	local layout = ArenaLayout.Generate(seed)

	for index, obstacle in layout do
		obstaclePositions[index] = obstacle.position
		obstacleRadii[index] = obstacle.radius
		occupied[index] = true
		obstacleQueryRadius = math.max(obstacleQueryRadius, obstacle.radius)
	end

	obstacleHash.Rebuild(obstaclePositions, occupied, #layout)
end

local function onRunStarted(slot: number, seed: number): ()
	clearAll()
	origin = Vector3.new(slot * Balance.Arena.spacing, 0, 0)
	buildObstacles(seed)

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

	-- Порядок событий значим: применяем ровно в том, в котором они пришли.
	for _, event in Packet.ReadEvents(data) do
		if event.kind == Packet.Kind.Spawn then
			applySpawn(event.id, event.aux, Vector3.new(event.x, 0, event.z))
		else
			applyDespawn(event.id, event.aux)
		end
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
