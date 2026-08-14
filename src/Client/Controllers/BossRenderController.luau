--!strict
--[[
	BossRenderController — отрисовка босса и его атак (раздел 5.1 ТЗ), M6.

	Босс один на арену, поэтому его модель и круги телеграфов создаются ОДИН РАЗ
	при старте клиента и дальше только включаются и выключаются. Инвариант
	«ноль Instance.new в бою» касается и одной детали: правило существует, чтобы
	не думать каждый раз, много это или мало.

	Отсюда же собираются модели ВСЕХ боссов сразу, а не одна нужная: какой босс
	будет на уровне, известно только в момент спавна, а спавн — это уже бой.
	Их всего две по десятку деталей, и стоят они меньше, чем одна волна врагов.

	Босс без modelKey остаётся одной деталью по def.model — этот путь живой,
	по нему рисуются архетипы, которым модель ещё не нарисовали.

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
local Models = require(Shared.Config.Models)
local Net = require(Shared.Net)
local Palette = require(Shared.Config.Palette)
local PartModel = require(Shared.Util.PartModel)

-- Сколько телеграфов может висеть одновременно. Атака у босса одна за раз,
-- запас — на случай наложения конца одной и начала другой.
local TELEGRAPH_POOL = 10

--[[
	Сколько стрелков на холмах может быть нарисовано разом.

	Они появляются раз в минуту и не умирают до конца боссфайта, так что
	это ещё и потолок длины боя, за которым новые перестанут показываться:
	двенадцать штук — это двенадцать минут, а таких боёв не бывает.
]]
local ARCHER_POOL = 12

--[[
	Сколько заполненная область держится после удара. Без этой задержки момент
	«залилось до конца» и момент удара совпадают с исчезновением картинки,
	и игрок не успевает связать одно с другим.
]]
local TELEGRAPH_HOLD = 0.15

--[[
	Контур области вместо полупрозрачного блина.

	Залитый круг поверх пола прятал под собой врагов и кристаллы, а границу
	показывал хуже, чем ломаная из коротких стенок по самому краю: та же
	мысль, что у кольца ауры и у волны Nova, и та же геометрия — воксельные
	отрезки по касательной.

	Восемнадцати хватает: у самой широкой области босса радиус около двенадцати
	стадов, отрезки выходят чуть больше четырёх, и кольцо читается кругом.
	Полосе из восемнадцати нужны только четыре — два борта и два торца.
]]
local CONTOUR_SEGMENTS = 18
local CONTOUR_HEIGHT = 1.1
local CONTOUR_THICK = 0.36

local CONTOUR_TRANSPARENCY = 0.1
local FILL_TRANSPARENCY = 0.62

type Telegraph = {
	contour: { BasePart },
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

-- Собранные модели по ключу из Config/Models и та из них, что сейчас на арене.
local models: { [string]: PartModel.Built } = {}
local activeModel: PartModel.Built? = nil

--[[
	Стрелки на холмах. Единственное в бою, что стоит НАД полом: у врагов
	Y всегда ноль, а этот сидит на верхушке. Позиция приходит один раз при
	появлении и больше не меняется — он не двигается вовсе.
]]
local archerModels: { PartModel.Built } = {}
local archerCount = 0

local origin = Vector3.zero
local active = false

-- Куда босса ведут: последняя точка с сервера и текущая нарисованная.
local targetPosition = Vector3.zero
local drawnPosition = Vector3.zero
local bobPhase = 0

--[[
	Куда модель смотрит. У одной детали переда нет, а у модели он есть: лицо
	шамана и глаза слизня обязаны быть повёрнуты по ходу движения, иначе босс
	читается как декорация, которую тащит вбок.

	Направление берётся из СВОЕГО движения на экране, а не с сервера: серверу
	разворот босса не нужен вовсе, он бьёт по кругу и по прицелу, и слать
	ради картинки ещё одно поле десять раз в секунду незачем.
]]
local facing = Vector3.new(0, 0, -1)

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
		Цвет здесь любой: тинты выставляются на спавне по стихии босса
		(SetTints). Одна и та же модель может достаться боссам разных стихий,
		и красить её при сборке было бы решением, принятым слишком рано.
	]]
	local tints = PartModel.TintsFor(Palette.Element.Nature, Palette.Model.accent)

	--[[
		Собираются ТОЛЬКО модели боссов, а не весь Config/Models.

		Раньше строился весь список целиком: двенадцать воксельных питомцев,
		весь реквизит лобби и тела способностей — больше полутора тысяч
		деталей, из которых на арене нужны две. Невидимые они почти ничего
		не стоят, но и заводить их незачем, а список с тех пор только рос.
	]]
	for _, boss in Bosses.List do
		local key = boss.modelKey
		if key and not models[key] then
			local def = Models.ByKey[key]
			if def then
				models[key] = PartModel.Build(def, tints, folder)
			end
		end
	end

	--[[
		Лучники: та же воксельная модель, что у всего остального в бою, вместо
		тёмного шара. Палитра тёмная и своя — стрелок принадлежит шаману,
		а не стихии арены.
	]]
	--[[
		Стрелок на холме — тот же гоблин-лучник, что бегает в волнах, той же
		моделью и того же цвета. Стихия у гоблинов Dark, но красить их ею
		нельзя: фиолетовый гоблин — не гоблин, а робот (Palette.Model.bases).
	]]
	local archerDef = Models.ByKey.GoblinArcher
	local archerTints = PartModel.TintsFor(Palette.Model.bases.GoblinArcher, Palette.Model.accent)
	for index = 1, ARCHER_POOL do
		archerModels[index] = PartModel.Build(archerDef, archerTints, folder)
	end

	--[[
		Телеграф — контур из отрезков плюс заливка, растущая внутри него
		до конца показа. Всё создаётся один раз при старте: «ноль Instance.new
		в бою» касается и этих деталей, а их тут по восемнадцать на область.
	]]
	for index = 1, TELEGRAPH_POOL do
		local contour: { BasePart } = {}
		for segment = 1, CONTOUR_SEGMENTS do
			contour[segment] = makePart(`TelegraphEdge{index}_{segment}`, folder)
		end

		telegraphs[index] = {
			contour = contour,
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
	entry.fill.Transparency = 1
	for _, part in entry.contour do
		part.Transparency = 1
	end
end

local function hideAll(): ()
	local part = bossPart
	if part then
		part.Transparency = 1
	end

	local model = activeModel
	if model then
		model.SetVisible(false)
		activeModel = nil
	end

	-- Стрелки уходят вместе с боссом: неуязвимость держалась ровно до его
	-- смерти, и оставшийся на холме силуэт обещал бы бой, которого нет.
	for index = 1, archerCount do
		archerModels[index].SetVisible(false)
	end
	archerCount = 0

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
	local lift = Vector3.new(0, CONTOUR_HEIGHT * 0.5, 0)

	if entry.shape == "Line" then
		local direction = Vector3.new(entry.dirX, 0, entry.dirZ)
		local full = entry.length
		local grown = math.max(full * progress, 0.05)
		local half = entry.width * 0.5

		--[[
			Полоса очерчивается четырьмя отрезками: два борта во всю длину
			и два торца. Остальные отрезки контура прячутся — своего пула
			на каждую форму заводить незачем, области не бывают одновременно.
		]]
		local across = Vector3.new(-direction.Z, 0, direction.X)
		local centre = base + direction * (full * 0.5) + lift

		for side = -1, 1, 2 do
			local rail = entry.contour[if side < 0 then 1 else 2]
			rail.Size = Vector3.new(CONTOUR_THICK, CONTOUR_HEIGHT, full)
			local at = centre + across * (half * side)
			rail.CFrame = CFrame.lookAt(at, at + direction)
		end

		for cap = 0, 1 do
			local part = entry.contour[3 + cap]
			part.Size = Vector3.new(entry.width, CONTOUR_HEIGHT, CONTOUR_THICK)
			local at = base + direction * (full * cap) + lift
			part.CFrame = CFrame.lookAt(at, at + direction)
		end

		for index = 5, CONTOUR_SEGMENTS do
			entry.contour[index].Transparency = 1
		end

		entry.fill.Size = Vector3.new(entry.width, 0.2, grown)
		local fillCenter = base + direction * (grown / 2) + Vector3.new(0, 0.2, 0)
		entry.fill.CFrame = CFrame.lookAt(fillCenter, fillCenter + direction)
		return
	end

	--[[
		Круг: отрезки по касательной, ровно по границе радиуса. Хорда берётся
		с нахлёстом, иначе кольцо читается пунктиром.

		Радиус здесь тот же, что у удара, и это не косметическая мелочь: круг,
		нарисованный не там, где бьёт, — уже было багом.
	]]
	local step = math.pi * 2 / CONTOUR_SEGMENTS
	local chord = 2 * entry.radius * math.sin(step * 0.5) * 1.06

	for index = 1, CONTOUR_SEGMENTS do
		local angle = step * (index - 1)
		local x, z = math.cos(angle), math.sin(angle)

		local part = entry.contour[index]
		part.Size = Vector3.new(chord, CONTOUR_HEIGHT, CONTOUR_THICK)
		part.CFrame = CFrame.new(base.X + x * entry.radius, base.Y + CONTOUR_HEIGHT * 0.5, base.Z + z * entry.radius)
			* CFrame.Angles(0, math.atan2(-x, -z), 0)
	end

	local grown = math.max(entry.radius * 2 * progress, 0.05)
	entry.fill.Size = Vector3.new(0.2, grown, grown)
	entry.fill.CFrame = CFrame.new(base + Vector3.new(0, 0.2, 0)) * CFrame.Angles(0, 0, math.rad(90))
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
	entry.fill.Color = color
	for _, part in entry.contour do
		part.Color = color
		part.Shape = Enum.PartType.Block
	end

	-- Заливка круга — цилиндр, полосы — коробка; контур везде из коробок.
	entry.fill.Shape = if shape == "Line" then Enum.PartType.Block else Enum.PartType.Cylinder

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

	for _, part in entry.contour do
		part.Transparency = CONTOUR_TRANSPARENCY
	end
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

		--[[
			Предыдущая модель гасится ДО показа новой. Босс за забег один, но
			отладочные кнопки в лобби выводят их подряд, и оставленная на арене
			модель прошлого босса — ровно тот же класс ошибки, что брошенные
			части врагов от перепутанного порядка событий.
		]]
		local previous = activeModel
		if previous then
			previous.SetVisible(false)
			activeModel = nil
		end

		local model = if def.modelKey then models[def.modelKey] else nil
		if model then
			--[[
				Стихия красит модель, если у неё нет своего цвета. Свой нужен
				там, где стихия про урон, а не про облик: гоблин-шаман бьёт
				тьмой, но фиолетовым он выглядит роботом.
			]]
			local base = Palette.Model.bases[def.modelKey :: string] or Palette.Element[def.element]
			model.SetTints(PartModel.TintsFor(base, Palette.Model.accent))
			model.SetVisible(true)
			activeModel = model
			part.Transparency = 1
		else
			part.Size = def.model.size
			part.Color = Palette.Element[def.element]
			part.Material = if def.model.neon then Enum.Material.Neon else Enum.Material.SmoothPlastic
			part.Shape = if def.model.shape == "Ball" then Enum.PartType.Ball else Enum.PartType.Block
			part.Transparency = 0
		end

		targetPosition = Vector3.new(payload.x, 0, payload.z)
		drawnPosition = targetPosition
		facing = Vector3.new(0, 0, -1)
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

	--[[
		Стрелок сел на холм. Позиция приходит один раз: он не двигается
		и не умирает до конца боссфайта, поэтому обновлять её нечем и незачем.
	]]
	if kind == "Archer" then
		if archerCount >= ARCHER_POOL then
			return
		end

		archerCount += 1
		local archer = archerModels[archerCount]

		--[[
			Показать, потом поставить: Draw у скрытой модели выходит сразу,
			ничего не рисуя. Дальше её не трогают вовсе — стрелок не двигается,
			а модель без анимации второй раз геометрию не считает.
		]]
		archer.SetVisible(true)
		archer.Draw(CFrame.new(origin + Vector3.new(payload.x, payload.y, payload.z)), 0, 0)
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

		Усиление и яд отличаются цветом, и это не украшение: игрок обязан с
		первого взгляда понимать, из какого круга надо выйти самому, а в какой
		нельзя пускать толпу. Круг усиления «безвреден» только для него: урона
		он не наносит, но выходящие из него враги неуязвимы.
	]]
	if kind == "Field" then
		local harmless = payload.field == "Buff"
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
	local previousDrawn = drawnPosition
	local alpha = math.min(deltaTime * 12, 1)
	drawnPosition = drawnPosition:Lerp(targetPosition, alpha)

	local model = activeModel
	if model then
		--[[
			Разворот берётся из пройденного за кадр пути. Порог обязателен:
			на стоящем боссе интерполяция даёт дрожание в тысячные доли студа,
			и модель крутилась бы на месте вокруг своей оси.
		]]
		local moved = drawnPosition - previousDrawn
		if moved.Magnitude > 0.01 then
			local turned = facing:Lerp(moved.Unit, math.min(deltaTime * 6, 1))
			-- На развороте ровно назад промежуточный вектор проходит через ноль,
			-- и Unit от него — NaN. Такой кадр разворот просто пропускает.
			facing = if turned.Magnitude > 1e-3 then turned.Unit else moved.Unit
		end

		--[[
			Скорость берётся из НАРИСОВАННОГО пути, а не из серверной: ноги
			обязаны совпадать с той картинкой, которая на экране. Возьми мы
			скорость из конфига фазы — сглаженный босс скользил бы в те кадры,
			когда интерполяция его придерживает.
		]]
		local speed = if deltaTime > 0 then moved.Magnitude / deltaTime else 0

		-- Пивот модели стоит на полу: offset деталей отсчитан от него же.
		local ground = origin + Vector3.new(drawnPosition.X, 0, drawnPosition.Z)
		model.Draw(CFrame.lookAt(ground, ground + facing), deltaTime, speed)
		return
	end

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
