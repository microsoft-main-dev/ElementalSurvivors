--!strict
--[[
	EnemyShotController — снаряды дальнобойных врагов (M2+).

	Гоблин-лучник стреляет по прямой в точку, где игрок был в момент выстрела.
	Урон считает сервер, здесь только картинка — но картинка эта обязана быть
	честной: игрок уворачивается именно по ней.

	Порядок ровно как у босса: сначала ТРАССЕР, потом снаряд. Трассер — тонкая
	линия по всей траектории, она висит telegraph секунд и говорит «отсюда
	сюда сейчас полетит». Без неё стрела, вылетевшая из толпы в триста тел,
	читается как случайная потеря здоровья.

	Позиции по сети не гоняются: сервер шлёт один пакет на выстрел, а дальше
	обе стороны считают прямую по одной и той же скорости. Тот же приём, что
	у снарядов способностей.

	Ноль Instance.new в бою: и трассеры, и снаряды берутся из пулов.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Balance = require(Shared.Config.Balance)
local Net = require(Shared.Net)
local Palette = require(Shared.Config.Palette)
local Pool = require(Shared.Util.Pool)

local SHOT_SIZE = Vector3.new(2.2, 0.4, 0.4)
local TRACER_WIDTH = 0.18
local SHOT_HEIGHT = 2.6

local EnemyShotController = {}

type Shot = {
	part: Part,
	position: Vector3,
	direction: Vector3,
	speed: number,
	life: number,
	-- Пока больше нуля, снаряда ещё нет: на экране трассер.
	delay: number,
	tracer: Part?,
}

local shots: { Shot } = {}
local container: Folder? = nil
local shotPool: Pool.Pool<Part>? = nil
local tracerPool: Pool.Pool<Part>? = nil

local origin = Vector3.zero
local active = false
local paused = false

local function makePart(): Part
	local part = Instance.new("Part")
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.Massless = true
	part.CastShadow = false
	part.Material = Enum.Material.Neon
	return part
end

local function getShotPool(): Pool.Pool<Part>
	local pool = shotPool
	if pool then
		return pool
	end
	local created = Pool.new(makePart, function(part: Part)
		part.Parent = nil
	end, 16)
	shotPool = created
	return created
end

local function getTracerPool(): Pool.Pool<Part>
	local pool = tracerPool
	if pool then
		return pool
	end
	local created = Pool.new(makePart, function(part: Part)
		part.Parent = nil
	end, 16)
	tracerPool = created
	return created
end

local function releaseTracer(shot: Shot): ()
	local tracer = shot.tracer
	if tracer then
		getTracerPool().Release(tracer)
		shot.tracer = nil
	end
end

local function clearAll(): ()
	for _, shot in shots do
		releaseTracer(shot)
		getShotPool().Release(shot.part)
	end
	table.clear(shots)
end

--[[
	Один выстрел. Трассер строится сразу на всю дальность полёта: игрок должен
	видеть не направление, а именно линию, с которой надо сойти.
]]
local function spawnShot(entry: { [string]: any }): ()
	local folder = container
	if not folder then
		return
	end

	local direction = Vector3.new(entry.dx, 0, entry.dz)
	local position = Vector3.new(entry.x, 0, entry.z)
	local length = entry.speed * entry.life

	local tracer = getTracerPool().Get()
	tracer.Size = Vector3.new(length, TRACER_WIDTH, TRACER_WIDTH)
	tracer.Color = Palette.UI.danger
	tracer.Transparency = 0.45
	tracer.CFrame = CFrame.new(origin + position + Vector3.new(0, SHOT_HEIGHT, 0))
		* CFrame.Angles(0, math.atan2(-direction.Z, direction.X), 0)
		* CFrame.new(length / 2, 0, 0)
	tracer.Parent = folder

	local part = getShotPool().Get()
	part.Size = SHOT_SIZE
	part.Color = Palette.Element.Dark
	-- Снаряда ещё нет: он появится, когда догорит трассер.
	part.Transparency = 1
	part.Parent = folder

	table.insert(shots, {
		part = part,
		position = position,
		direction = direction,
		speed = entry.speed,
		life = entry.life,
		delay = entry.delay,
		tracer = tracer,
	})
end

local function onHeartbeat(deltaTime: number): ()
	if not active or paused then
		-- На паузе снаряды замирают вместе с боем: сервер их тоже не считает.
		return
	end

	local index = 1
	while index <= #shots do
		local shot = shots[index]

		if shot.delay > 0 then
			shot.delay -= deltaTime
			if shot.delay <= 0 then
				-- Трассер догорел: линия гаснет, летит снаряд.
				releaseTracer(shot)
				shot.part.Transparency = 0
			end
			index += 1
			continue
		end

		shot.life -= deltaTime
		if shot.life <= 0 then
			releaseTracer(shot)
			getShotPool().Release(shot.part)
			shots[index] = shots[#shots]
			shots[#shots] = nil :: any
			continue
		end

		shot.position += shot.direction * (shot.speed * deltaTime)
		shot.part.CFrame = CFrame.new(origin + shot.position + Vector3.new(0, SHOT_HEIGHT, 0))
			* CFrame.Angles(0, math.atan2(-shot.direction.Z, shot.direction.X), 0)

		index += 1
	end
end

function EnemyShotController.Start(): ()
	Net.GetEvent(Net.Id.RunStarted).OnClientEvent:Connect(function(slot: number)
		clearAll()
		origin = Vector3.new(slot * Balance.Arena.spacing, 0, 0)

		local folder = Instance.new("Folder")
		folder.Name = "EnemyShots"
		folder.Parent = Workspace
		container = folder

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

		local shotsPool = shotPool
		if shotsPool then
			shotsPool.Destroy()
			shotPool = nil
		end

		local tracers = tracerPool
		if tracers then
			tracers.Destroy()
			tracerPool = nil
		end
	end)

	Net.GetEvent(Net.Id.CombatPaused).OnClientEvent:Connect(function(value: boolean)
		paused = value
	end)

	Net.GetUnreliable(Net.Id.EnemyShots).OnClientEvent:Connect(function(payload: { { [string]: any } })
		if not active then
			return
		end
		for _, entry in payload do
			spawnShot(entry)
		end
	end)

	RunService.Heartbeat:Connect(onHeartbeat)
end

return EnemyShotController
