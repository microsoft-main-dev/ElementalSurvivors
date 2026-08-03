--!strict
--[[
	PickupService — кристаллы опыта и магнит (раздел 3.6 ТЗ).

	Схема та же, что у врагов: плоские массивы на сервере, пул на клиенте,
	события пачками. Круговая ресинхронизация здесь не нужна — кристалл либо
	лежит неподвижно, либо летит к игроку по детерминированному правилу,
	которое клиент повторяет точно.

	Публичный API:
		PickupService.StartRun(slot, player)
		PickupService.StopRun(slot)
		PickupService.Drop(slot, position, value)      -- вызывается на смерти врага
		PickupService.Tick(slot, dt, playerLocal)
		PickupService.SetCollectHandler(fn)            -- начисление опыта
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Balance = require(Shared.Config.Balance)
local Net = require(Shared.Net)
local Packet = require(Shared.Util.Packet)

type Sim = {
	slot: number,
	player: Player,

	positions: { Vector3 },
	values: { number },
	alive: { boolean },

	freeList: { number },
	freeCount: number,
	highWater: number,
	aliveCount: number,

	eventTimer: number,
	eventKinds: { number },
	eventIds: { number },
	eventAux: { number },
	eventX: { number },
	eventZ: { number },
	eventCount: number,
}

local PickupService = {}

local CAPACITY = Balance.Pickup.maxAlive

local sims: { [number]: Sim } = {}
local collectHandler: ((slot: number, player: Player, xp: number) -> ())? = nil
local eventsRemote: RemoteEvent? = nil

local function pushEvent(sim: Sim, kind: number, id: number, x: number, z: number): ()
	local index = sim.eventCount + 1
	sim.eventCount = index
	sim.eventKinds[index] = kind
	sim.eventIds[index] = id
	sim.eventAux[index] = 0
	sim.eventX[index] = x
	sim.eventZ[index] = z
end

function PickupService.Drop(slot: number, position: Vector3, value: number): ()
	local sim = sims[slot]
	if not sim or sim.freeCount == 0 then
		return
	end

	local id = sim.freeList[sim.freeCount]
	sim.freeCount -= 1
	if id > sim.highWater then
		sim.highWater = id
	end

	sim.positions[id] = position
	sim.values[id] = value
	sim.alive[id] = true
	sim.aliveCount += 1

	pushEvent(sim, Packet.Kind.Spawn, id, position.X, position.Z)
end

local function collect(sim: Sim, id: number): ()
	sim.alive[id] = false
	sim.aliveCount -= 1
	sim.freeCount += 1
	sim.freeList[sim.freeCount] = id

	pushEvent(sim, Packet.Kind.Despawn, id, 0, 0)
end

function PickupService.Tick(slot: number, dt: number, playerLocal: Vector3): ()
	local sim = sims[slot]
	if not sim then
		return
	end

	local magnetRadius = Balance.Pickup.magnetRadius
	local magnetRadiusSquared = magnetRadius * magnetRadius
	local collectRadius = Balance.Pickup.collectRadius
	local collectRadiusSquared = collectRadius * collectRadius
	local step = Balance.Pickup.magnetSpeed * dt

	local gained = 0

	for id = 1, sim.highWater do
		if sim.alive[id] then
			local position = sim.positions[id]
			local dx = playerLocal.X - position.X
			local dz = playerLocal.Z - position.Z
			local distanceSquared = dx * dx + dz * dz

			if distanceSquared <= collectRadiusSquared then
				gained += sim.values[id]
				collect(sim, id)
			elseif distanceSquared <= magnetRadiusSquared then
				local distance = math.sqrt(distanceSquared)
				local move = math.min(step, distance)
				sim.positions[id] = Vector3.new(position.X + dx / distance * move, 0, position.Z + dz / distance * move)
			end
		end
	end

	-- Репликация: пачкой, как у врагов.
	sim.eventTimer += dt
	if sim.eventTimer >= Balance.Pickup.eventInterval then
		sim.eventTimer = 0
		if sim.eventCount > 0 then
			local remote = eventsRemote
			if remote then
				remote:FireClient(
					sim.player,
					Packet.WriteEvents(
						sim.eventKinds,
						sim.eventIds,
						sim.eventAux,
						sim.eventX,
						sim.eventZ,
						sim.eventCount
					)
				)
			end
			sim.eventCount = 0
		end
	end

	if gained > 0 then
		local handler = collectHandler
		if handler then
			handler(sim.slot, sim.player, gained)
		end
	end
end

function PickupService.SetCollectHandler(handler: (slot: number, player: Player, xp: number) -> ()): ()
	collectHandler = handler
end

function PickupService.GetAliveCount(slot: number): number
	local sim = sims[slot]
	return if sim then sim.aliveCount else 0
end

function PickupService.StartRun(slot: number, player: Player): ()
	local sim: Sim = {
		slot = slot,
		player = player,

		positions = table.create(CAPACITY, Vector3.zero),
		values = table.create(CAPACITY, 0),
		alive = table.create(CAPACITY, false),

		freeList = table.create(CAPACITY, 0),
		freeCount = CAPACITY,
		highWater = 0,
		aliveCount = 0,

		eventTimer = 0,
		eventKinds = {},
		eventIds = {},
		eventAux = {},
		eventX = {},
		eventZ = {},
		eventCount = 0,
	}

	for index = 1, CAPACITY do
		sim.freeList[index] = CAPACITY - index + 1
	end

	sims[slot] = sim
end

function PickupService.StopRun(slot: number): ()
	sims[slot] = nil
end

function PickupService.Init(): ()
	eventsRemote = Net.GetEvent(Net.Id.CrystalEvents)
end

return PickupService
