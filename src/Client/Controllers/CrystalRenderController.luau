--!strict
--[[
	CrystalRenderController — кристаллы опыта (раздел 3.6 ТЗ).

	Сервер шлёт только появление и подбор. Полёт к игроку клиент считает сам
	тем же правилом, что и сервер: кристалл в радиусе магнита движется к игроку
	с фиксированной скоростью. Правило детерминированное, поэтому досылать
	позиции не нужно вообще.

	Как и у врагов, порядок событий значим: id кристаллов переиспользуются.

	Публичный API:
		CrystalRenderController.GetActiveCount() -> number
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Balance = require(Shared.Config.Balance)
local Net = require(Shared.Net)
local Packet = require(Shared.Util.Packet)
local Palette = require(Shared.Config.Palette)
local Pool = require(Shared.Util.Pool)

local PREWARM = 120

local CrystalRenderController = {}

local player = Players.LocalPlayer

local active = false
local paused = false
local origin = Vector3.zero

local positions: { [number]: Vector3 } = {}
local parts: { [number]: Part } = {}
local isAlive: { [number]: boolean } = {}
local highWater = 0
local activeCount = 0

local container: Folder? = nil
local partPool: Pool.Pool<Part>? = nil

local moveParts: { BasePart } = {}
local moveCFrames: { CFrame } = {}
local lastMoveCount = 0

local function resetPart(part: Part): ()
	part.Parent = nil
end

local function createPart(): Part
	local size = Balance.Pickup.size
	local part = Instance.new("Part")
	part.Shape = Enum.PartType.Ball
	part.Size = Vector3.new(size, size, size)
	part.Color = Palette.UI.subtext
	part.Material = Enum.Material.Neon
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.Massless = true
	part.CastShadow = false
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
	table.clear(parts)
	table.clear(isAlive)
	table.clear(moveParts)
	table.clear(moveCFrames)

	highWater = 0
	activeCount = 0
	lastMoveCount = 0
end

local function applySpawn(id: number, position: Vector3): ()
	local previous = parts[id]
	if previous then
		getPool().Release(previous)
		parts[id] = nil
	end

	local part = getPool().Get()
	part.CFrame = CFrame.new(origin + Vector3.new(position.X, Balance.Pickup.height, position.Z))
	part.Parent = container

	positions[id] = position
	parts[id] = part
	isAlive[id] = true

	if id > highWater then
		highWater = id
	end
end

local function applyDespawn(id: number): ()
	isAlive[id] = nil
	local part = parts[id]
	parts[id] = nil
	if part then
		getPool().Release(part)
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
	if not active or paused then
		return
	end

	local playerLocal = getPlayerLocalPosition()
	if not playerLocal then
		return
	end

	local magnetRadiusSquared = Balance.Pickup.magnetRadius ^ 2
	local step = Balance.Pickup.magnetSpeed * deltaTime
	local height = Balance.Pickup.height
	local count = 0

	for id = 1, highWater do
		if isAlive[id] then
			local part = parts[id]
			if part then
				local position = positions[id]
				local dx = playerLocal.X - position.X
				local dz = playerLocal.Z - position.Z
				local distanceSquared = dx * dx + dz * dz

				if distanceSquared <= magnetRadiusSquared and distanceSquared > 1e-6 then
					local distance = math.sqrt(distanceSquared)
					local move = math.min(step, distance)
					position = Vector3.new(position.X + dx / distance * move, 0, position.Z + dz / distance * move)
					positions[id] = position
				end

				count += 1
				moveParts[count] = part
				moveCFrames[count] = CFrame.new(origin + Vector3.new(position.X, height, position.Z))
			end
		end
	end

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

function CrystalRenderController.GetActiveCount(): number
	return activeCount
end

function CrystalRenderController.Start(): ()
	Net.GetEvent(Net.Id.RunStarted).OnClientEvent:Connect(function(slot: number)
		clearAll()
		origin = Vector3.new(slot * Balance.Arena.spacing, 0, 0)

		local folder = Instance.new("Folder")
		folder.Name = "Crystals"
		folder.Parent = Workspace
		container = folder

		getPool()
		paused = false
		active = true
	end)

	Net.GetEvent(Net.Id.RunEnded).OnClientEvent:Connect(function()
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
	end)

	Net.GetEvent(Net.Id.CombatPaused).OnClientEvent:Connect(function(value: boolean)
		paused = value
	end)

	Net.GetEvent(Net.Id.CrystalEvents).OnClientEvent:Connect(function(data: buffer)
		if not active then
			return
		end
		for _, event in Packet.ReadEvents(data) do
			if event.kind == Packet.Kind.Spawn then
				applySpawn(event.id, Vector3.new(event.x, 0, event.z))
			else
				applyDespawn(event.id)
			end
		end
	end)

	RunService.Heartbeat:Connect(onHeartbeat)
end

return CrystalRenderController
