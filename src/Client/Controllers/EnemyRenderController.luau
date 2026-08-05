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
		EnemyRenderController.GetActiveCount() -> number   (для отладочного оверлея;
			на Low качестве (M7) — только видимые в renderDistance, не все живые)
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
local SettingsController = require(script.Parent.SettingsController)
local SpatialHash = require(Shared.Util.SpatialHash)

local DEATH_FLASH_TIME = 0.09
local PREWARM = 340

local EnemyRenderController = {}

local player = Players.LocalPlayer

local active = false
local paused = false -- бой стоит из-за выбора карточки левел-апа
local origin = Vector3.zero
local accumulator = 0

-- Состояние врагов, индексируется серверным id.
local positions: { [number]: Vector3 } = {}
local offsets: { [number]: Vector3 } = {} -- невязка после ресинхронизации, затухает к нулю
local typeIds: { [number]: number } = {}
local phases: { [number]: number } = {}
local parts: { [number]: Part } = {}
local isAlive: { [number]: boolean } = {}
-- Виден ли враг сейчас (в пределах renderDistance качества). false = скрыт
-- прозрачностью и не участвует в BulkMoveTo, но продолжает симулироваться.
local visible: { [number]: boolean } = {}
local highWater = 0
local activeCount = 0

-- Качество отрисовки (M7), выставляется заново на каждый onRunStarted:
-- смена настройки посреди боя недоступна (LobbyRequest заблокирован в бою).
local renderDistance = Balance.Quality.High.renderDistance
local deathFlash = Balance.Quality.High.deathFlash

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
local resyncHealth: { number } = {}

--[[
	Полоски здоровья над врагами (M7).

	Доля здоровья приходит в пакете ресинхронизации, то есть у врага, которого
	давно не ресинкали, она слегка устаревшая — для полоски над головой этого
	достаточно, а второй поток ради неё был бы дороже самой фичи.

	Полоски рисуются НЕ у всех: только у раненых, только вблизи и не больше
	фиксированного числа сразу. При трёхстах врагах на арене полоска над каждым
	превратилась бы в сплошную рябь и в честную просадку кадра на телефоне.
]]
local health: { [number]: number } = {}

type HealthBar = {
	gui: BillboardGui,
	fill: Frame,
}

local healthBars: { HealthBar } = {}
local healthBarLimit = Balance.Quality.High.healthBars

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

--[[
	Пул полосок здоровья. Создаётся один раз при старте контроллера по потолку
	High: сменить настройку качества посреди боя нельзя, но между забегами
	можно, и пересоздавать интерфейс на входе в бой ради этого не хочется.
]]
local function buildHealthBars(parent: Instance): ()
	local screen = Instance.new("ScreenGui")
	screen.Name = "EnemyHealthBars"
	screen.ResetOnSpawn = false
	-- Ниже HUD (200): полоски врагов не должны налезать на счётчики игрока.
	screen.DisplayOrder = 120
	screen.Parent = parent

	for index = 1, Balance.Quality.High.healthBars do
		local gui = Instance.new("BillboardGui")
		gui.Name = `EnemyHealth{index}`
		gui.Size = UDim2.fromOffset(38, 5)
		gui.AlwaysOnTop = false
		gui.LightInfluence = 0
		gui.MaxDistance = Balance.Combat.healthBarDistance
		gui.Enabled = false
		gui.Parent = screen

		local track = Instance.new("Frame")
		track.Name = "Track"
		track.Size = UDim2.fromScale(1, 1)
		track.BackgroundColor3 = Palette.UI.background
		track.BackgroundTransparency = 0.25
		track.BorderSizePixel = 0
		track.Parent = gui

		local fill = Instance.new("Frame")
		fill.Name = "Fill"
		fill.Size = UDim2.fromScale(1, 1)
		fill.BackgroundColor3 = Palette.UI.danger
		fill.BorderSizePixel = 0
		fill.Parent = track

		healthBars[index] = { gui = gui, fill = fill }
	end
end

local function hideHealthBars(from: number): ()
	for index = from, #healthBars do
		local bar = healthBars[index]
		bar.gui.Enabled = false
		bar.gui.Adornee = nil
	end
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
	table.clear(visible)
	table.clear(health)
	hideHealthBars(1)
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
	visible[id] = true
	-- Целым враг считается до первого ресинка: полоска над невредимым
	-- не рисуется вовсе, поэтому «пока не знаем» и «цел» здесь одно и то же.
	health[id] = 1

	if id > highWater then
		highWater = id
	end
end

local function applyDespawn(id: number, reason: number): ()
	isAlive[id] = nil
	visible[id] = nil
	health[id] = nil

	local part = parts[id]
	parts[id] = nil
	if not part then
		return
	end

	if reason == Packet.Reason.Killed and deathFlash then
		-- Вспышка вместо анимации смерти (раздел 2.1 ТЗ). На Low качестве
		-- пропускается: часть уходит в пул тем же кадром, без лишнего кадра
		-- жизни на экране.
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

local function render(now: number, playerLocal: Vector3): ()
	local bobSpeed = Balance.Combat.bobSpeed
	local bobAmplitude = Balance.Combat.bobAmplitude
	local renderDistanceSquared = renderDistance * renderDistance
	local barDistanceSquared = Balance.Combat.healthBarDistance * Balance.Combat.healthBarDistance
	local count = 0
	local bars = 0

	for id = 1, highWater do
		if isAlive[id] then
			local part = parts[id]
			if part then
				local position = positions[id]
				local dx = position.X - playerLocal.X
				local dz = position.Z - playerLocal.Z
				local inRange = dx * dx + dz * dz <= renderDistanceSquared

				--[[
					Дальше renderDistance часть гасится прозрачностью и выходит
					из BulkMoveTo — это и есть реальная экономия кадра на Low.
					Позиция при этом продолжает симулироваться каждый тик:
					расталкивание и попадания способностей не должны зависеть
					от того, что сейчас видно на экране.
				]]
				if not inRange then
					if visible[id] ~= false then
						part.Transparency = 1
						visible[id] = false
					end
					continue
				end

				if visible[id] == false then
					part.Transparency = 0
				end
				visible[id] = true

				local def = Enemies.List[typeIds[id]]
				local offset = offsets[id]
				local bob = EnemyMotion.BobOffset(phases[id], now, bobSpeed, bobAmplitude)

				--[[
					Полоска достаётся раненым вблизи, пока не кончился лимит.
					Порядок обхода — по id, то есть по старшинству врага, а не
					по расстоянию: сортировать три сотни врагов каждый кадр ради
					порядка полосок дороже, чем сама фича.
				]]
				local fraction = health[id]
				if
					bars < healthBarLimit
					and fraction ~= nil
					and fraction < 1
					and dx * dx + dz * dz <= barDistanceSquared
				then
					bars += 1
					local bar = healthBars[bars]
					bar.gui.Adornee = part
					bar.gui.StudsOffsetWorldSpace = Vector3.new(0, def.model.size.Y * 0.5 + 1.2, 0)
					bar.gui.Enabled = true
					bar.fill.Size = UDim2.fromScale(math.max(fraction, 0), 1)
				end

				count += 1
				moveParts[count] = part
				moveCFrames[count] = CFrame.new(
					origin + Vector3.new(position.X + offset.X, def.model.size.Y * 0.5 + bob, position.Z + offset.Z)
				)
			end
		end
	end

	-- Полоски, не доставшиеся никому в этом кадре, гасим: иначе они остались бы
	-- висеть на враге, который умер или вышел из радиуса.
	hideHealthBars(bars + 1)

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

	if paused then
		-- Пауза должна выглядеть как пауза: накопленную дельту сбрасываем,
		-- иначе после выбора карточки толпа рванёт вперёд рывком.
		accumulator = 0
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
		render(now, playerLocal)
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

	local quality = Balance.Quality[SettingsController.ResolveQuality()]
	renderDistance = quality.renderDistance
	deathFlash = quality.deathFlash
	healthBarLimit = quality.healthBars

	local folder = Instance.new("Folder")
	folder.Name = "Enemies"
	folder.Parent = Workspace
	container = folder

	getPool()
	paused = false
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

	local count = Packet.ReadResync(data, resyncIds, resyncPositions, resyncHealth)
	for index = 1, count do
		local id = resyncIds[index]
		if isAlive[id] then
			local exact = resyncPositions[index]
			-- Позицию принимаем сразу, а видимую разницу гасим постепенно.
			offsets[id] = positions[id] - exact
			positions[id] = exact
			-- Здоровье едет тем же пакетом: полоска обновляется тогда же,
			-- когда врага и так поправили по позиции.
			health[id] = resyncHealth[index]
		end
	end
end

function EnemyRenderController.GetActiveCount(): number
	return activeCount
end

function EnemyRenderController.Start(): ()
	buildHealthBars(player:WaitForChild("PlayerGui"))

	Net.GetEvent(Net.Id.RunStarted).OnClientEvent:Connect(onRunStarted)
	Net.GetEvent(Net.Id.RunEnded).OnClientEvent:Connect(onRunEnded)
	Net.GetEvent(Net.Id.EnemyEvents).OnClientEvent:Connect(onEvents)
	Net.GetUnreliable(Net.Id.EnemyResync).OnClientEvent:Connect(onResync)
	Net.GetEvent(Net.Id.CombatPaused).OnClientEvent:Connect(function(value: boolean)
		paused = value
	end)

	RunService.Heartbeat:Connect(onHeartbeat)
end

return EnemyRenderController
