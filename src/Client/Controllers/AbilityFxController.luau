--!strict
--[[
	AbilityFxController — как способности выглядят.

	Разделение простое: то, что выводится из состояния, клиент считает сам,
	а по сети идёт только то, что вывести нельзя.

		Orbit  — положение орбов полностью задаётся уровнем и фазой, а фаза
		         и так приходит в снимке для HUD. Ноль отдельного трафика.
		         Между снимками фаза крутится локально с той же скоростью,
		         поэтому орбы на экране совпадают с теми, что бьют на сервере.
		Aura   — кольцо радиусом из конфига, тоже чистое состояние.
		Nova   — момент вспышки предсказать нельзя, приходит событием.
		Projectile — рождение снаряда приходит событием, дальше он летит
		         по прямой, и клиент повторяет это точно.

	Урона здесь нет и быть не может: всё это чистая косметика.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Abilities = require(Shared.Config.Abilities)
local Balance = require(Shared.Config.Balance)
local Net = require(Shared.Net)
local Palette = require(Shared.Config.Palette)
local Pool = require(Shared.Util.Pool)
local Types = require(Shared.Types)

type AbilityView = Types.AbilityView

local NOVA_TIME = 0.32
local ORB_SIZE = 1.8

local AbilityFxController = {}

local player = Players.LocalPlayer

local active = false
local paused = false
local origin = Vector3.zero
local views: { AbilityView } = {}

local container: Folder? = nil
local orbPool: Pool.Pool<Part>? = nil
local shardPool: Pool.Pool<Part>? = nil

-- Летящие снаряды: только для вида, поэтому состояние минимальное.
type Shard = {
	part: Part,
	position: Vector3,
	direction: Vector3,
	speed: number,
	life: number,
}
local shards: { Shard } = {}

-- Активные орбы и ауры пересобираются каждый кадр из состояния.
local orbParts: { Part } = {}
local auraParts: { [string]: Part } = {}

type Nova = {
	part: Part,
	position: Vector3,
	radius: number,
	startedAt: number,
}
local novas: { Nova } = {}

local function makeEffectPart(shape: Enum.PartType): Part
	local part = Instance.new("Part")
	part.Shape = shape
	part.Material = Enum.Material.Neon
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.Massless = true
	part.CastShadow = false
	return part
end

local function getOrbPool(): Pool.Pool<Part>
	local pool = orbPool
	if pool then
		return pool
	end
	local created = Pool.new(function()
		return makeEffectPart(Enum.PartType.Ball)
	end, function(part: Part)
		part.Parent = nil
	end, 8)
	orbPool = created
	return created
end

local function getShardPool(): Pool.Pool<Part>
	local pool = shardPool
	if pool then
		return pool
	end
	local created = Pool.new(function()
		return makeEffectPart(Enum.PartType.Block)
	end, function(part: Part)
		part.Parent = nil
	end, 40)
	shardPool = created
	return created
end

local function getPlayerWorld(): Vector3?
	local character = player.Character
	if not character then
		return nil
	end
	local root = character:FindFirstChild("HumanoidRootPart") :: BasePart?
	return if root then root.Position else nil
end

local function clearAll(): ()
	for _, part in orbParts do
		getOrbPool().Release(part)
	end
	table.clear(orbParts)

	for _, part in auraParts do
		part:Destroy()
	end
	table.clear(auraParts)

	for _, shard in shards do
		getShardPool().Release(shard.part)
	end
	table.clear(shards)

	for _, nova in novas do
		nova.part:Destroy()
	end
	table.clear(novas)

	table.clear(views)
end

local function getAura(key: string, element: Types.Element): Part
	local existing = auraParts[key]
	if existing then
		return existing
	end

	local part = makeEffectPart(Enum.PartType.Cylinder)
	part.Color = Palette.Element[element]
	part.Transparency = 0.86
	part.Parent = container
	auraParts[key] = part
	return part
end

--[[
	Орбы и ауры: количество орбов меняется с уровнем, поэтому пул отдаёт
	ровно столько частей, сколько нужно в этом кадре, а лишние возвращаются.
]]
local function updateStateDriven(dt: number, playerWorld: Vector3): ()
	local usedOrbs = 0
	local seenAuras: { [string]: boolean } = {}

	for _, view in views do
		local def = Abilities.ByKey[view.key]
		if not def then
			continue
		end
		local data = def.levels[view.level]

		if def.shape == "Orbit" then
			-- Фаза из снимка докручивается локально: между снимками 0.1 с,
			-- за которые орб уходит заметно далеко.
			view.phase = (view.phase + (data.angularSpeed :: number) * dt) % (math.pi * 2)

			local count = data.count :: number
			local radius = data.radius :: number
			local step = math.pi * 2 / count

			for index = 0, count - 1 do
				local angle = view.phase + step * index
				usedOrbs += 1

				local part = orbParts[usedOrbs]
				if not part then
					part = getOrbPool().Get()
					part.Size = Vector3.new(ORB_SIZE, ORB_SIZE, ORB_SIZE)
					part.Parent = container
					orbParts[usedOrbs] = part
				end

				part.Color = Palette.Element[def.element]
				part.CFrame = CFrame.new(
					playerWorld.X + math.cos(angle) * radius,
					playerWorld.Y,
					playerWorld.Z + math.sin(angle) * radius
				)
			end
		elseif def.shape == "Aura" then
			seenAuras[view.key] = true
			local diameter = (data.radius :: number) * 2
			local part = getAura(view.key, def.element)
			part.Size = Vector3.new(0.3, diameter, diameter)
			part.CFrame = CFrame.new(playerWorld.X, 0.5, playerWorld.Z) * CFrame.Angles(0, 0, math.rad(90))
		end
	end

	-- Лишние орбы с прошлого кадра (уровень упал или способность пропала).
	for index = #orbParts, usedOrbs + 1, -1 do
		getOrbPool().Release(orbParts[index])
		orbParts[index] = nil :: any
	end

	for key, part in auraParts do
		if not seenAuras[key] then
			part:Destroy()
			auraParts[key] = nil
		end
	end
end

local function updateShards(dt: number): ()
	local index = 1
	while index <= #shards do
		local shard = shards[index]
		shard.life -= dt

		if shard.life <= 0 then
			getShardPool().Release(shard.part)
			shards[index] = shards[#shards]
			shards[#shards] = nil :: any
		else
			shard.position += shard.direction * (shard.speed * dt)
			shard.part.CFrame = CFrame.new(origin + shard.position + Vector3.new(0, 2.5, 0))
				* CFrame.Angles(0, math.atan2(-shard.direction.Z, shard.direction.X), 0)
			index += 1
		end
	end
end

local function updateNovas(now: number): ()
	local index = 1
	while index <= #novas do
		local nova = novas[index]
		local progress = (now - nova.startedAt) / NOVA_TIME

		if progress >= 1 then
			nova.part:Destroy()
			novas[index] = novas[#novas]
			novas[#novas] = nil :: any
		else
			local diameter = nova.radius * 2 * progress
			nova.part.Size = Vector3.new(0.4, diameter, diameter)
			nova.part.Transparency = 0.25 + 0.75 * progress
			index += 1
		end
	end
end

local function onHeartbeat(deltaTime: number): ()
	if not active or paused then
		-- На паузе эффекты замирают вместе с боем: сервер их тоже не считает.
		return
	end

	local now = os.clock()
	updateShards(deltaTime)
	updateNovas(now)

	local playerWorld = getPlayerWorld()
	if playerWorld then
		updateStateDriven(deltaTime, playerWorld)
	end
end

local function spawnShards(key: string, payload: { { x: number, z: number, dx: number, dz: number } }): ()
	local def = Abilities.ByKey[key]
	if not def then
		return
	end

	for _, entry in payload do
		local view: AbilityView? = nil
		for _, candidate in views do
			if candidate.key == key then
				view = candidate
				break
			end
		end

		local data = def.levels[if view then view.level else 1]
		local part = getShardPool().Get()
		part.Size = Vector3.new(2.6, 0.5, 0.5)
		part.Color = Palette.Element[def.element]
		part.Transparency = 0
		part.Parent = container

		table.insert(shards, {
			part = part,
			position = Vector3.new(entry.x, 0, entry.z),
			direction = Vector3.new(entry.dx, 0, entry.dz),
			speed = data.speed :: number,
			life = data.lifetime :: number,
		})
	end
end

local function spawnNova(key: string, payload: { { x: number, z: number, dx: number, dz: number } }): ()
	local def = Abilities.ByKey[key]
	local entry = payload[1]
	if not def or not entry then
		return
	end

	local view: AbilityView? = nil
	for _, candidate in views do
		if candidate.key == key then
			view = candidate
			break
		end
	end

	local data = def.levels[if view then view.level else 1]
	local part = makeEffectPart(Enum.PartType.Cylinder)
	part.Color = Palette.Element[def.element]
	part.CFrame = CFrame.new(origin.X + entry.x, 0.6, origin.Z + entry.z) * CFrame.Angles(0, 0, math.rad(90))
	part.Parent = container

	table.insert(novas, {
		part = part,
		position = Vector3.new(entry.x, 0, entry.z),
		radius = data.radius :: number,
		startedAt = os.clock(),
	})
end

function AbilityFxController.Start(): ()
	Net.GetEvent(Net.Id.RunStarted).OnClientEvent:Connect(function(slot: number)
		clearAll()
		origin = Vector3.new(slot * Balance.Arena.spacing, 0, 0)

		local folder = Instance.new("Folder")
		folder.Name = "AbilityFx"
		folder.Parent = Workspace
		container = folder
		paused = false
		active = true
	end)

	Net.GetEvent(Net.Id.CombatPaused).OnClientEvent:Connect(function(value: boolean)
		paused = value
		-- Вспышки нельзя оставлять «на паузе»: они привязаны к абсолютному
		-- времени и после снятия паузы схлопнулись бы мгновенно.
		for _, nova in novas do
			nova.part:Destroy()
		end
		table.clear(novas)
	end)

	Net.GetEvent(Net.Id.RunEnded).OnClientEvent:Connect(function()
		active = false
		clearAll()

		local folder = container
		if folder then
			folder:Destroy()
			container = nil
		end

		local orbs = orbPool
		if orbs then
			orbs.Destroy()
			orbPool = nil
		end

		local shardsPool = shardPool
		if shardsPool then
			shardsPool.Destroy()
			shardPool = nil
		end
	end)

	Net.GetUnreliable(Net.Id.RunSnapshot).OnClientEvent:Connect(function(snapshot: Types.RunSnapshot)
		views = snapshot.abilities
	end)

	Net.GetUnreliable(Net.Id.AbilityFx).OnClientEvent
		:Connect(function(kind: string, key: string, payload: { { x: number, z: number, dx: number, dz: number } })
			if not active then
				return
			end
			if kind == "Projectile" then
				spawnShards(key, payload)
			elseif kind == "Nova" then
				spawnNova(key, payload)
			end
		end)

	RunService.Heartbeat:Connect(onHeartbeat)
end

return AbilityFxController
