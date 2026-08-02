--!strict
--[[
	EnemyService — симуляция врагов (раздел 3 ТЗ). Сердце игры.

	Враги на сервере — НЕ Instance, а записи в плоских массивах (Structure of Arrays).
	id врага — это индекс в массивах, освобождённые id переиспользуются через free-list.
	Никаких table.remove в горячем цикле, никаких Humanoid, никаких Script на врага.

	Один Heartbeat на весь сервер (а не на арену, как предлагало ТЗ): при восьми
	аренах восемь подписок дают лишние накладные расходы на ровном месте,
	а поведение получается идентичное.

	Шаг симуляции фиксированный (1/30 с) и накапливается аккумулятором, поэтому
	результат не зависит от FPS сервера. Больше maxStepsPerFrame шагов за кадр
	не делаем — иначе просадка порождает спираль смерти.

	Позиции хранятся В ЛОКАЛЬНЫХ координатах арены (Y всегда 0). Мировая позиция
	получается прибавлением origin арены. Так числа остаются маленькими,
	а математика — чистой и готовой к переносу в parallel Luau.

	Публичный API:
		EnemyService.StartRun(slot, player)
		EnemyService.StopRun(slot)
		EnemyService.Damage(slot, id, amount)              -> boolean  (true = убит)
		EnemyService.Collect(slot, localPosition, radius, out) -> count
		EnemyService.GetAliveCount(slot)                   -> number
		EnemyService.GetRunTime(slot)                      -> number
		EnemyService.SetContactHandler(fn)                 -- урон игроку от касания
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Balance = require(Shared.Config.Balance)
local Enemies = require(Shared.Config.Enemies)
local EnemyMotion = require(Shared.Util.EnemyMotion)
local Net = require(Shared.Net)
local Packet = require(Shared.Util.Packet)
local RNG = require(Shared.Util.RNG)
local SpatialHash = require(Shared.Util.SpatialHash)
local Types = require(Shared.Types)
local Waves = require(Shared.Config.Waves)

type EnemyDef = Types.EnemyDef

type Sim = {
	slot: number,
	player: Player,
	origin: Vector3,
	rng: RNG.RNG,
	hash: SpatialHash.SpatialHash,

	time: number,
	accumulator: number,

	-- Structure of Arrays
	positions: { Vector3 },
	nextPositions: { Vector3 },
	hp: { number },
	typeId: { number },
	phase: { number },
	alive: { boolean },

	freeList: { number },
	freeCount: number,
	highWater: number,
	aliveCount: number,

	-- Волны
	waveIndex: number,
	spawnCredit: number,
	cullTimer: number,

	-- Репликация. События лежат ОДНИМ потоком в порядке возникновения:
	-- id умерших переиспользуются сразу, и перестановка спавнов со смертями
	-- ломала бы соответствие id врагу на клиенте.
	eventTimer: number,
	eventKinds: { number },
	eventIds: { number },
	eventAux: { number },
	eventX: { number },
	eventZ: { number },
	eventCount: number,
	resyncCursor: number,
	resyncCredit: number,
	resyncIds: { number },

	-- Переиспользуемый буфер под запросы к хешу
	neighbours: { number },
}

local EnemyService = {}

-- Ёмкость массивов: потолок живых из таблицы волн плюс запас на кадр смерти.
local CAPACITY = (function(): number
	local maxAlive = 0
	for _, wave in Waves do
		maxAlive = math.max(maxAlive, wave.maxAlive)
	end
	return maxAlive + 100
end)()

-- Самый крупный враг: по нему считается радиус поиска касаний.
local maxEnemyRadius = (function(): number
	local largest = 0
	for _, def in Enemies.List do
		largest = math.max(largest, def.stats.radius)
	end
	return largest
end)()

local sims: { [number]: Sim } = {}
local contactHandler: ((player: Player, damage: number) -> ())? = nil

local eventsRemote: RemoteEvent? = nil
local resyncRemote: UnreliableRemoteEvent? = nil

local function getPlayerLocalPosition(sim: Sim): Vector3?
	local character = sim.player.Character
	if not character then
		return nil
	end
	local root = character:FindFirstChild("HumanoidRootPart") :: BasePart?
	if not root then
		return nil
	end
	local world = root.Position - sim.origin
	return Vector3.new(world.X, 0, world.Z)
end

local function currentWave(sim: Sim): Types.WaveEntry
	local index = sim.waveIndex
	while index < #Waves and Waves[index + 1].time <= sim.time do
		index += 1
	end
	sim.waveIndex = index
	return Waves[index]
end

local function allocate(sim: Sim): number?
	if sim.freeCount == 0 then
		return nil
	end
	local id = sim.freeList[sim.freeCount]
	sim.freeCount -= 1
	if id > sim.highWater then
		sim.highWater = id
	end
	return id
end

local function pushEvent(sim: Sim, kind: number, id: number, aux: number, x: number, z: number): ()
	local index = sim.eventCount + 1
	sim.eventCount = index
	sim.eventKinds[index] = kind
	sim.eventIds[index] = id
	sim.eventAux[index] = aux
	sim.eventX[index] = x
	sim.eventZ[index] = z
end

local function release(sim: Sim, id: number, reason: number): ()
	sim.alive[id] = false
	sim.aliveCount -= 1
	sim.freeCount += 1
	sim.freeList[sim.freeCount] = id

	pushEvent(sim, Packet.Kind.Despawn, id, reason, 0, 0)
end

local function spawnOne(sim: Sim, def: EnemyDef, playerLocal: Vector3): ()
	local id = allocate(sim)
	if not id then
		return
	end

	-- Спавн по окружности радиусом чуть больше видимой области — никогда в кадре.
	local direction = sim.rng.NextUnitVector()
	local position = EnemyMotion.ClampToArena(playerLocal + direction * Balance.Combat.spawnRadius, Balance.Arena.size)

	sim.positions[id] = position
	sim.nextPositions[id] = position
	sim.hp[id] = def.stats.health
	sim.typeId[id] = def.typeId
	sim.phase[id] = sim.rng.NextNumber(0, 6.28)
	sim.alive[id] = true
	sim.aliveCount += 1

	pushEvent(sim, Packet.Kind.Spawn, id, def.typeId, position.X, position.Z)
end

local function spawnStep(sim: Sim, dt: number, playerLocal: Vector3): ()
	local wave = currentWave(sim)
	if sim.aliveCount >= wave.maxAlive then
		sim.spawnCredit = 0
		return
	end

	sim.spawnCredit += wave.spawnRate * dt

	while sim.spawnCredit >= 1 and sim.aliveCount < wave.maxAlive do
		sim.spawnCredit -= 1
		local key = sim.rng.NextChoice(wave.types)
		local def = Enemies.ByKey[key]
		if def then
			spawnOne(sim, def, playerLocal)
		end
	end
end

local function moveStep(sim: Sim, dt: number, playerLocal: Vector3): ()
	local positions = sim.positions
	local nextPositions = sim.nextPositions
	local alive = sim.alive
	local typeIds = sim.typeId
	local neighbours = sim.neighbours
	local hash = sim.hash

	hash.Rebuild(positions, alive, sim.highWater)

	local separationRadius = Balance.Combat.separationRadius
	local separationStrength = Balance.Combat.separationStrength
	local arenaSize = Balance.Arena.size

	for id = 1, sim.highWater do
		if alive[id] then
			local def = Enemies.List[typeIds[id]]
			local position = positions[id]

			position = EnemyMotion.Chase(position, playerLocal, def.stats.speed, dt)

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

			nextPositions[id] = EnemyMotion.ClampToArena(position, arenaSize)
		end
	end

	-- Двойная буферизация: все читают старые позиции, пишут в новые.
	-- Так шаг детерминирован и его можно будет посчитать параллельно.
	sim.positions = nextPositions
	sim.nextPositions = positions
end

local function contactStep(sim: Sim, playerLocal: Vector3): ()
	local handler = contactHandler
	if not handler then
		return
	end

	local positions = sim.positions
	local alive = sim.alive
	local typeIds = sim.typeId
	local playerRadius = Balance.Combat.playerRadius
	local padding = Balance.Combat.contactPadding

	-- Через хеш, а не полным перебором: касание проверяется каждый тик,
	-- и лишние 300 итераций тут стоят дороже, чем сам поиск соседей.
	-- Хеш построен по позициям прошлого тика — расхождение меньше половины стада.
	local reach = playerRadius + maxEnemyRadius + padding
	local count = sim.hash.Collect(playerLocal, reach, sim.neighbours)

	-- Достаточно самого сильного касания за тик: i-frames всё равно съедят остальные.
	local worst = 0
	for index = 1, count do
		local id = sim.neighbours[index]
		if alive[id] then
			local def = Enemies.List[typeIds[id]]
			local exactReach = playerRadius + def.stats.radius + padding
			local position = positions[id]
			local dx = position.X - playerLocal.X
			local dz = position.Z - playerLocal.Z
			if dx * dx + dz * dz <= exactReach * exactReach and def.stats.damage > worst then
				worst = def.stats.damage
			end
		end
	end

	if worst > 0 then
		handler(sim.player, worst)
	end
end

local CULL_INTERVAL = 0.5

local function cullStep(sim: Sim, dt: number, playerLocal: Vector3): ()
	sim.cullTimer += dt
	if sim.cullTimer < CULL_INTERVAL then
		return
	end
	sim.cullTimer = 0

	local wave = Waves[sim.waveIndex]
	if sim.aliveCount < wave.maxAlive then
		return
	end

	-- Потолок достигнут: молча убираем самых дальних, чтобы освободить место.
	local positions = sim.positions
	local alive = sim.alive
	local cullRadius = Balance.Combat.cullRadius
	local cullRadiusSquared = cullRadius * cullRadius

	for id = 1, sim.highWater do
		if alive[id] then
			local position = positions[id]
			local dx = position.X - playerLocal.X
			local dz = position.Z - playerLocal.Z
			if dx * dx + dz * dz > cullRadiusSquared then
				release(sim, id, Packet.Reason.Culled)
			end
		end
	end
end

local function collectResync(sim: Sim, wanted: number): number
	local limit = sim.highWater
	if limit == 0 or sim.aliveCount == 0 then
		return 0
	end

	local found = 0
	local scanned = 0
	local cursor = sim.resyncCursor
	local target = math.min(wanted, sim.aliveCount)

	while found < target and scanned < limit do
		cursor += 1
		if cursor > limit then
			cursor = 1
		end
		scanned += 1
		if sim.alive[cursor] then
			found += 1
			sim.resyncIds[found] = cursor
		end
	end

	sim.resyncCursor = cursor
	return found
end

local function replicationStep(sim: Sim, dt: number): ()
	-- События спавна и смерти — надёжным каналом, пачкой раз в eventInterval.
	sim.eventTimer += dt
	if sim.eventTimer >= Balance.Combat.eventInterval then
		sim.eventTimer = 0
		if sim.eventCount > 0 then
			local remote = eventsRemote
			if remote then
				local data = Packet.WriteEvents(
					sim.eventKinds,
					sim.eventIds,
					sim.eventAux,
					sim.eventX,
					sim.eventZ,
					sim.eventCount
				)
				remote:FireClient(sim.player, data)
			end
			sim.eventCount = 0
		end
	end

	-- Круговая ресинхронизация точных позиций — ненадёжным каналом.
	sim.resyncCredit += Balance.Combat.resyncPerSecond * dt
	local wanted = math.floor(sim.resyncCredit)
	if wanted > 0 then
		sim.resyncCredit -= wanted
		local found = collectResync(sim, wanted)
		if found > 0 then
			local remote = resyncRemote
			if remote then
				remote:FireClient(sim.player, Packet.WriteResync(sim.resyncIds, sim.positions, found))
			end
		end
	end
end

local function step(sim: Sim, dt: number): ()
	sim.time += dt

	local playerLocal = getPlayerLocalPosition(sim)
	if not playerLocal then
		return
	end

	spawnStep(sim, dt, playerLocal)
	moveStep(sim, dt, playerLocal)
	contactStep(sim, playerLocal)
	cullStep(sim, dt, playerLocal)
end

local function onHeartbeat(deltaTime: number): ()
	local tickRate = Balance.Combat.tickRate
	local maxSteps = Balance.Combat.maxStepsPerFrame

	for _, sim in sims do
		sim.accumulator += deltaTime

		local steps = 0
		while sim.accumulator >= tickRate and steps < maxSteps do
			sim.accumulator -= tickRate
			steps += 1
			step(sim, tickRate)
		end

		-- Сервер не успевает: остаток отбрасываем, иначе догоняние снежным комом.
		if sim.accumulator >= tickRate then
			sim.accumulator = 0
		end

		if steps > 0 then
			replicationStep(sim, steps * tickRate)
		end
	end
end

function EnemyService.Init(): ()
	eventsRemote = Net.GetEvent(Net.Id.EnemyEvents)
	resyncRemote = Net.GetUnreliable(Net.Id.EnemyResync)
end

function EnemyService.Start(): ()
	RunService.Heartbeat:Connect(onHeartbeat)
end

function EnemyService.SetContactHandler(handler: (player: Player, damage: number) -> ()): ()
	contactHandler = handler
end

function EnemyService.StartRun(slot: number, player: Player, origin: Vector3, seed: number): ()
	local sim: Sim = {
		slot = slot,
		player = player,
		origin = origin,
		rng = RNG.new(seed),
		hash = SpatialHash.new(Balance.Combat.cellSize),

		time = 0,
		accumulator = 0,

		positions = table.create(CAPACITY, Vector3.zero),
		nextPositions = table.create(CAPACITY, Vector3.zero),
		hp = table.create(CAPACITY, 0),
		typeId = table.create(CAPACITY, 1),
		phase = table.create(CAPACITY, 0),
		alive = table.create(CAPACITY, false),

		freeList = table.create(CAPACITY, 0),
		freeCount = CAPACITY,
		highWater = 0,
		aliveCount = 0,

		waveIndex = 1,
		spawnCredit = 0,
		cullTimer = 0,

		eventTimer = 0,
		eventKinds = {},
		eventIds = {},
		eventAux = {},
		eventX = {},
		eventZ = {},
		eventCount = 0,
		resyncCursor = 0,
		resyncCredit = 0,
		resyncIds = {},

		neighbours = {},
	}

	-- Free-list заполняем в обратном порядке, чтобы id выдавались с единицы:
	-- плотные id дают компактный обход массивов.
	for index = 1, CAPACITY do
		sim.freeList[index] = CAPACITY - index + 1
	end

	sims[slot] = sim
end

function EnemyService.StopRun(slot: number): ()
	sims[slot] = nil
end

function EnemyService.Damage(slot: number, id: number, amount: number): boolean
	local sim = sims[slot]
	if not sim or not sim.alive[id] then
		return false
	end

	local remaining = sim.hp[id] - amount
	if remaining > 0 then
		sim.hp[id] = remaining
		return false
	end

	release(sim, id, Packet.Reason.Killed)
	return true
end

function EnemyService.Collect(slot: number, localPosition: Vector3, radius: number, out: { number }): number
	local sim = sims[slot]
	if not sim then
		return 0
	end
	return sim.hash.Collect(localPosition, radius, out)
end

function EnemyService.GetAliveCount(slot: number): number
	local sim = sims[slot]
	return if sim then sim.aliveCount else 0
end

function EnemyService.GetRunTime(slot: number): number
	local sim = sims[slot]
	return if sim then sim.time else 0
end

return EnemyService
