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

-- Сколько телеграфов может висеть одновременно. Атака у босса одна за раз,
-- запас — на случай наложения конца одной и начала другой.
local TELEGRAPH_POOL = 10

--[[
	Сколько заполненная область держится после удара. Без этой задержки момент
	«залилось до конца» и момент удара совпадают с исчезновением картинки,
	и игрок не успевает связать одно с другим.
]]
local TELEGRAPH_HOLD = 0.15

local OUTLINE_TRANSPARENCY = 0.75
local FILL_TRANSPARENCY = 0.35

type Telegraph = {
	outline: BasePart,
	fill: BasePart,
	shape: string,
	x: number,
	z: number,
	dirX: number,
	dirZ: number,
	radius: number,
	length: number,
	width: number,
	duration: number,
	elapsed: number,
	active: boolean,
	--[[
		Залито с первого кадра. Так рисуются стойкие поля: у них заливка
		означает «здесь уже действует», а не «сейчас ударит», и расти ей
		двенадцать секунд было бы прямой ложью.
	]]
	instant: boolean,
}

local BossRenderController = {}

local player = Players.LocalPlayer

local bossPart: BasePart? = nil
local telegraphs: { Telegraph } = {}

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

	--[[
		У каждого телеграфа две детали: контур показывает всю область сразу,
		заливка растёт внутри него до конца показа. Обе создаются один раз
		при старте — «ноль Instance.new в бою» касается и четырёх деталей.
	]]
	for index = 1, TELEGRAPH_POOL do
		telegraphs[index] = {
			outline = makePart(`TelegraphOutline{index}`, folder),
			fill = makePart(`TelegraphFill{index}`, folder),
			shape = "Circle",
			x = 0,
			z = 0,
			dirX = 1,
			dirZ = 0,
			radius = 0,
			length = 0,
			width = 0,
			duration = 1,
			elapsed = 0,
			active = false,
			instant = false,
		}
	end
end

local function hideTelegraph(entry: Telegraph): ()
	entry.active = false
	entry.outline.Transparency = 1
	entry.fill.Transparency = 1
end

local function hideAll(): ()
	local part = bossPart
	if part then
		part.Transparency = 1
	end
	for _, entry in telegraphs do
		hideTelegraph(entry)
	end
end

--[[
	Пересчитать размер заливки. progress = 0 — пусто, 1 — вся область.

	Круг растёт из центра, полоса — от босса вдоль рывка: и то, и другое
	показывает не только «сколько осталось», но и откуда придёт удар.
]]
local function drawTelegraph(entry: Telegraph, progress: number): ()
	local base = origin + Vector3.new(entry.x, 0, entry.z)

	if entry.shape == "Line" then
		local direction = Vector3.new(entry.dirX, 0, entry.dirZ)
		local full = entry.length
		local grown = math.max(full * progress, 0.05)

		entry.outline.Size = Vector3.new(entry.width, 0.2, full)
		local outlineCenter = base + direction * (full / 2) + Vector3.new(0, 0.15, 0)
		entry.outline.CFrame = CFrame.lookAt(outlineCenter, outlineCenter + direction)

		entry.fill.Size = Vector3.new(entry.width, 0.2, grown)
		local fillCenter = base + direction * (grown / 2) + Vector3.new(0, 0.2, 0)
		entry.fill.CFrame = CFrame.lookAt(fillCenter, fillCenter + direction)
		return
	end

	local diameter = entry.radius * 2
	local flat = CFrame.Angles(0, 0, math.rad(90))

	entry.outline.Size = Vector3.new(0.2, diameter, diameter)
	entry.outline.CFrame = CFrame.new(base + Vector3.new(0, 0.15, 0)) * flat

	local grown = math.max(diameter * progress, 0.05)
	entry.fill.Size = Vector3.new(0.2, grown, grown)
	entry.fill.CFrame = CFrame.new(base + Vector3.new(0, 0.2, 0)) * flat
end

--[[
	Показать телеграф. Область видна целиком с первого кадра, заливка растёт
	до конца показа — момент, когда она заполнила область, и есть момент удара
	(сервер бьёт ровно тогда же, по позиции игрока в этот момент).
]]
local function showTelegraph(
	shape: string,
	x: number,
	z: number,
	dirX: number,
	dirZ: number,
	radius: number,
	length: number,
	width: number,
	duration: number,
	harmless: boolean,
	instant: boolean
): ()
	local entry: Telegraph? = nil
	for _, candidate in telegraphs do
		if not candidate.active then
			entry = candidate
			break
		end
	end

	if not entry then
		return
	end

	local color = if harmless then Palette.UI.warning else Palette.UI.danger
	entry.outline.Color = color
	entry.fill.Color = color

	local isLine = shape == "Line"
	entry.outline.Shape = if isLine then Enum.PartType.Block else Enum.PartType.Cylinder
	entry.fill.Shape = entry.outline.Shape

	entry.shape = shape
	entry.x = x
	entry.z = z
	entry.dirX = dirX
	entry.dirZ = dirZ
	entry.radius = radius
	entry.length = length
	entry.width = width
	entry.duration = math.max(duration, 0.05)
	entry.elapsed = 0
	entry.active = true
	entry.instant = instant

	entry.outline.Transparency = OUTLINE_TRANSPARENCY
	entry.fill.Transparency = FILL_TRANSPARENCY
	drawTelegraph(entry, if instant then 1 else 0)
end

local function stepTelegraphs(deltaTime: number): ()
	for _, entry in telegraphs do
		if not entry.active then
			continue
		end

		entry.elapsed += deltaTime
		if entry.elapsed >= entry.duration + TELEGRAPH_HOLD then
			hideTelegraph(entry)
			continue
		end

		drawTelegraph(entry, if entry.instant then 1 else math.clamp(entry.elapsed / entry.duration, 0, 1))
	end
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
		showTelegraph(
			payload.shape,
			payload.x,
			payload.z,
			payload.dirX,
			payload.dirZ,
			payload.radius,
			payload.length,
			payload.width,
			payload.duration,
			payload.harmless == true,
			false
		)
		return
	end

	--[[
		Стойкое поле шамана. Круг живёт столько же, сколько на сервере: остаток
		клиент отсчитывает сам, поэтому по сети он приходит ровно один раз.

		Лечение и яд отличаются цветом, и это не украшение: игрок обязан с
		первого взгляда понимать, из какого круга надо выйти, а в какой
		нельзя пускать толпу.
	]]
	if kind == "Field" then
		local harmless = payload.field == "Heal"
		showTelegraph("Circle", payload.x, payload.z, 1, 0, payload.radius, 0, 0, payload.duration, harmless, true)
		return
	end

	if kind == "Attack" and payload.attack == "Shockwave" then
		-- Сама волна: короткая вспышка на месте удара, чтобы попадание
		-- читалось как событие, а не как внезапная потеря здоровья.
		-- Область та же, что была показана, — то есть круг вокруг босса.
		showTelegraph("Circle", payload.x, payload.z, 1, 0, payload.radius, 0, 0, 0.12, false, false)
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
	-- Телеграфы тикают всегда: вспышка удара обязана догореть даже в тот кадр,
	-- в котором босс умер и перестал быть активным.
	stepTelegraphs(deltaTime)

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

-- Абсолютные числа для подписи под полосой: доли мало, когда хочется понять,
-- сколько ещё бить.
function BossRenderController.GetHealth(): (number, number)
	return health, maxHealth
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
