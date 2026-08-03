--!strict
--[[
	BossRenderController — отрисовка босса и его атак (раздел 5.1 ТЗ), M6.

	Босс один на арену, поэтому его модель и круги телеграфов создаются ОДИН РАЗ
	при старте клиента и дальше только включаются и выключаются. Инвариант
	«ноль Instance.new в бою» касается и одной детали: правило существует, чтобы
	не думать каждый раз, много это или мало.

	Позиция приходит с сервера десять раз в секунду и сглаживается интерполяцией.
	Своей симуляции у босса на клиенте нет — в отличие от толпы, где она нужна
	ради трафика, здесь сущность одна и точные десять пакетов в секунду дешевле,
	чем расхождение картинки с уроном.

	Телеграф — главное, что здесь рисуется. Он показывает, куда ударят, за
	секунду до удара, и без него боссфайт на автобое превращается в лотерею.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Balance = require(Shared.Config.Balance)
local Bosses = require(Shared.Config.Bosses)
local Net = require(Shared.Net)
local Palette = require(Shared.Config.Palette)

-- Сколько кругов телеграфа может висеть одновременно. Атака у босса одна
-- за раз, запас — на случай наложения конца одной и начала другой.
local TELEGRAPH_POOL = 4

local BossRenderController = {}

local player = Players.LocalPlayer

local bossPart: BasePart? = nil
local telegraphs: { BasePart } = {}
local telegraphFree: { number } = {}

local origin = Vector3.zero
local active = false

-- Куда босса ведут: последняя точка с сервера и текущая нарисованная.
local targetPosition = Vector3.zero
local drawnPosition = Vector3.zero
local bobPhase = 0

local health = 0
local maxHealth = 1

local function makePart(name: string, parent: Instance): BasePart
	local part = Instance.new("Part")
	part.Name = name
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.Massless = true
	part.Material = Enum.Material.Neon
	part.Transparency = 1
	part.Parent = parent
	return part
end

local function build(): ()
	local folder = Instance.new("Folder")
	folder.Name = "BossRender"
	folder.Parent = Workspace

	bossPart = makePart("Boss", folder)

	for index = 1, TELEGRAPH_POOL do
		local circle = makePart(`Telegraph{index}`, folder)
		circle.Shape = Enum.PartType.Cylinder
		circle.Color = Palette.UI.danger
		telegraphs[index] = circle
		telegraphFree[index] = index
	end
end

local function hideAll(): ()
	local part = bossPart
	if part then
		part.Transparency = 1
	end
	for _, circle in telegraphs do
		circle.Transparency = 1
	end
end

--[[
	Показать круг телеграфа на время duration.

	Круг гаснет сам через task.delay, а не по таймеру в Heartbeat: их максимум
	четыре, и отдельный список активных ради этого не нужен.
]]
local function showTelegraph(x: number, z: number, radius: number, duration: number): ()
	local index = table.remove(telegraphFree)
	if not index then
		return
	end

	local circle = telegraphs[index]
	circle.Size = Vector3.new(0.2, radius * 2, radius * 2)
	circle.CFrame = CFrame.new(origin + Vector3.new(x, 0.15, z)) * CFrame.Angles(0, 0, math.rad(90))
	circle.Transparency = 0.55

	task.delay(duration, function()
		circle.Transparency = 1
		table.insert(telegraphFree, index)
	end)
end

local function onEvent(payload: { [string]: any }): ()
	local kind = payload.kind

	if kind == "Spawn" then
		local def = Bosses.ByKey[payload.boss]
		local part = bossPart
		if not def or not part then
			return
		end

		part.Size = def.model.size
		part.Color = Palette.Element[def.element]
		part.Material = if def.model.neon then Enum.Material.Neon else Enum.Material.SmoothPlastic
		part.Shape = if def.model.shape == "Ball" then Enum.PartType.Ball else Enum.PartType.Block
		part.Transparency = 0

		targetPosition = Vector3.new(payload.x, 0, payload.z)
		drawnPosition = targetPosition
		health = payload.maxHealth
		maxHealth = payload.maxHealth
		active = true
		return
	end

	if kind == "Despawn" then
		active = false
		hideAll()
		return
	end

	if kind == "Telegraph" then
		showTelegraph(payload.aimX, payload.aimZ, payload.radius, payload.duration)
		return
	end

	if kind == "Attack" and payload.attack == "Shockwave" then
		-- Сама волна: короткая вспышка на месте удара, чтобы попадание
		-- читалось как событие, а не как внезапная потеря здоровья.
		showTelegraph(payload.x, payload.z, payload.radius, 0.25)
	end
end

local function onState(payload: { [string]: any }): ()
	if not active then
		return
	end
	targetPosition = Vector3.new(payload.x, 0, payload.z)
	health = payload.health
	maxHealth = payload.maxHealth
end

local function onHeartbeat(deltaTime: number): ()
	local part = bossPart
	if not active or not part then
		return
	end

	--[[
		Сглаживание к последней известной точке. Коэффициент подобран так,
		чтобы движение читалось плавным, но босс не «плыл» заметно позади
		своей настоящей позиции: урон считает сервер по ней, а не по картинке.
	]]
	local alpha = math.min(deltaTime * 12, 1)
	drawnPosition = drawnPosition:Lerp(targetPosition, alpha)

	bobPhase = (bobPhase + deltaTime * Balance.Combat.bobSpeed * 0.4) % (math.pi * 2)
	local bob = math.sin(bobPhase) * 0.6

	part.CFrame = CFrame.new(origin + Vector3.new(drawnPosition.X, part.Size.Y / 2 + bob, drawnPosition.Z))
end

-- Доля здоровья для полосы в HUD. Читает HudController.
function BossRenderController.GetHealthFraction(): number
	if not active or maxHealth <= 0 then
		return 0
	end
	return math.clamp(health / maxHealth, 0, 1)
end

function BossRenderController.IsActive(): boolean
	return active
end

function BossRenderController.Start(): ()
	player:WaitForChild("PlayerGui")
	build()
	hideAll()

	Net.GetEvent(Net.Id.RunStarted).OnClientEvent:Connect(function(slot: number)
		origin = Vector3.new(slot * Balance.Arena.spacing, 0, 0)
		active = false
		hideAll()
	end)

	Net.GetEvent(Net.Id.RunEnded).OnClientEvent:Connect(function()
		active = false
		hideAll()
	end)

	Net.GetEvent(Net.Id.BossEvent).OnClientEvent:Connect(onEvent)
	Net.GetUnreliable(Net.Id.BossState).OnClientEvent:Connect(onState)

	RunService.Heartbeat:Connect(onHeartbeat)
end

return BossRenderController
