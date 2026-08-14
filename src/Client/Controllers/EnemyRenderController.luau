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
		EnemyRenderController.Flash(centre, inner, outer, colour, start?, span?)
			вспышка попадания по области; чистая косметика, урона не наносит
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
local Models = require(Shared.Config.Models)
local Net = require(Shared.Net)
local Packet = require(Shared.Util.Packet)
local Palette = require(Shared.Config.Palette)
local PartModel = require(Shared.Util.PartModel)
local Pool = require(Shared.Util.Pool)
local SettingsController = require(script.Parent.SettingsController)
local SpatialHash = require(Shared.Util.SpatialHash)
local Types = require(Shared.Types)

local DEATH_FLASH_TIME = 0.09

--[[
	Вспышка попадания: сколько живёт и насколько отбрасывает.

	Десятая секунды — это три тика симуляции: короче попадание не успевает
	попасть в кадр, длиннее — толпа под аурой светится белым непрерывно.

	Отскок мелкий намеренно. Это зрительный сдвиг, а не движение: враг
	остаётся там, где его посчитал сервер, и уводить его дальше полустада
	значит показывать игроку не ту позицию, по которой считается урон.
]]
local HIT_FLASH_TIME = 0.1
local HIT_PUSH = 0.5
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
--[[
	Мелкие детали врагов (Types.EnemyPart): глаза слизней, головы и оружие
	гоблинов. Живут своим пулом и своим массивом.

	Массив ПЛОСКИЙ, с ключом (id - 1) * MAX_PARTS + номер детали, а не
	таблица на врага: пара таблиц на каждого из трёхсот тел — это мусор
	для сборщика каждую волну.
]]
local MAX_PARTS = 2
local extraParts: { [number]: Part } = {}
local isAlive: { [number]: boolean } = {}
--[[
	Сколько секунд врагу осталось быть усиленным полем босса. Клиент ведёт
	этот отсчёт сам: по сети приходит только момент начала и длительность,
	а дальше обе стороны считают одинаково тем же шагом 1/30 с.
]]
local buffLeft: { [number]: number } = {}

-- Сколько осталось светиться от попадания. Пусто у всех, кого не задели.
local flashLeft: { [number]: number } = {}

--[[
	ВОКСЕЛЬНЫЕ МОДЕЛИ БЛИЖАЙШИМ ВРАГАМ.

	Модель гоблина — десять деталей против трёх, и каждая едет в BulkMoveTo
	каждый кадр. Пятьсот моделей удлинили бы самый длинный массив игры впятеро,
	поэтому модель достаётся только тем, кто рядом, и только пока хватает
	бюджета Balance.Quality.modelEnemies. Остальные ходят как раньше.

	Тело врага при этом никуда не девается: оно становится невидимым, но
	продолжает ездить в общем BulkMoveTo. На нём висит полоска здоровья, оно
	же догорает вспышкой смерти, и своя ветка для «модельных» врагов в обоих
	местах стоила бы дороже одной невидимой детали.

	Усиленный полем босса модель не получает вовсе. Неуязвимость показывается
	цветом ВСЕГО тела, а SetTints не трогает детали с ручным цветом — тряпьё
	и клинок остались бы обычными, то есть сигнал «не бей» стал бы половинчатым.
]]
local modelEnemiesBudget = Balance.Quality.High.modelEnemies
local modelPools: { [string]: Pool.Pool<PartModel.Built> } = {}
local modelOf: { [number]: PartModel.Built } = {}
local modelKeyOf: { [number]: string } = {}
local modelTints: { [string]: PartModel.Tints } = {}
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
local extraPool: Pool.Pool<Part>? = nil
local hash = SpatialHash.new(Balance.Combat.cellSize)
local neighbours: { number } = {}

-- Свой массив под выборку вспышки: neighbours занят расталкиванием,
-- и общий на двоих затёрся бы посреди шага симуляции.
local flashHits: { number } = {}

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
	Мелкая деталь. Форму ей задаёт SpecialMesh со встроенным типом, а не
	PartType: меш создаётся ОДИН РАЗ здесь, при наполнении пула, и на выдаче
	только переключается свойством. Лишней детали в BulkMoveTo от него не
	берётся — это и есть тот бесплатный ход, ради которого он тут.

	Через PartType то же самое не вышло бы: клин формой детали не задаётся
	вовсе, а заводить и уничтожать меш на выдаче значило бы делать
	Instance.new в бою.
]]
local meshOf: { [Part]: SpecialMesh } = {}

local function createExtraPart(): Part
	local part = createPart()
	part.Material = Enum.Material.SmoothPlastic

	local mesh = Instance.new("SpecialMesh")
	mesh.MeshType = Enum.MeshType.Brick
	mesh.Parent = part
	meshOf[part] = mesh

	return part
end

local function getExtraPool(): Pool.Pool<Part>
	local pool = extraPool
	if pool then
		return pool
	end
	-- По потолку деталей на врага: пул, кончившийся в бою, начнёт делать
	-- Instance.new ровно там, где его быть не должно.
	local created = Pool.new(createExtraPart, resetPart, PREWARM * MAX_PARTS)
	extraPool = created
	return created
end

local MESHES: { [string]: Enum.MeshType } = {
	Block = Enum.MeshType.Brick,
	Ball = Enum.MeshType.Sphere,
	Wedge = Enum.MeshType.Wedge,
}

--[[
	Раскладка деталей по typeId, посчитанная один раз при старте.

	В конфиге детали заданы долями размера тела, а рисовать надо студами
	и готовыми CFrame. Пересчитывать это каждому из трёхсот врагов каждый
	кадр незачем: раскладка зависит только от определения врага.

	bodyLocal и bodySizes заводятся только у врагов С деталями: остальные
	рисуются прежним самым дешёвым путём, без разворота вовсе.
]]
local extraLocal: { [number]: { CFrame } } = {}
local extraSizes: { [number]: { Vector3 } } = {}
local extraColors: { [number]: { Color3 } } = {}
local bodySizes: { [number]: Vector3 } = {}
local bodyLocal: { [number]: CFrame } = {}

local function buildLayouts(): ()
	for typeId, def in Enemies.List do
		local size = def.model.size
		bodySizes[typeId] = size

		local defParts = def.model.parts
		if not defParts then
			-- Разворот врагу без деталей не нужен и не виден, поэтому и тело
			-- ему не разворачивается: самый дешёвый путь остаётся дешёвым.
			continue
		end

		--[[
			Цилиндр приходится ставить стоймя: ось у него вдоль X, и без
			этого стрелок лежал бы бревном. Высота и диаметр меняются местами
			только у САМОЙ детали — все, кто считает по def.model.size
			(полоска над головой, центр тела), продолжают читать её как было.
		]]
		if def.model.shape == "Cylinder" then
			bodySizes[typeId] = Vector3.new(size.Y, size.X, size.Z)
			bodyLocal[typeId] = CFrame.Angles(0, 0, math.pi * 0.5)
		end

		local locals: { CFrame } = {}
		local sizes: { Vector3 } = {}
		local colors: { Color3 } = {}

		for index, entry in defParts do
			local angles = entry.angles
			local rotation = if angles
				then CFrame.Angles(math.rad(angles.X), math.rad(angles.Y), math.rad(angles.Z))
				else CFrame.identity

			-- Перёд врага — это -Z, как у CFrame.lookAt: тем же способом
			-- повёрнут и босс, и его модель.
			locals[index] = CFrame.new(entry.side * size.X, entry.height * size.Y, -entry.forward * size.X) * rotation
			sizes[index] = Vector3.new(entry.size.X * size.X, entry.size.Y * size.Y, entry.size.Z * size.X)
			colors[index] = Palette.Detail[entry.color]
		end

		extraLocal[typeId] = locals
		extraSizes[typeId] = sizes
		extraColors[typeId] = colors
	end
end

--[[
	Собственный цвет врага. Цвет кодирует стихию (раздел 2.1 ТЗ), кроме тех,
	кому задан свой: у слизней различать надо размер, а стихия у них общая.

	Отдельной функцией, потому что цвет ставится дважды — при спавне и когда
	с врага спадает усиление: два разных выражения для одного факта
	однажды разошлись бы.
]]
local function colorFor(def: Types.EnemyDef): Color3
	local palette = def.model.palette
	return (palette and Palette.Enemy.bodies[palette]) or Palette.Element[def.element]
end

--[[
	Вернуть детали врага в пул. Зовётся и на смерти, и на уборке арены,
	поэтому молча переживает врага, у которого деталей не было вовсе.
]]
local function releaseExtras(id: number): ()
	local base = (id - 1) * MAX_PARTS
	for slot = 1, MAX_PARTS do
		local part = extraParts[base + slot]
		if part then
			getExtraPool().Release(part)
			extraParts[base + slot] = nil
		end
	end
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

	local extras = extraPool
	if extras then
		extras.ReleaseAll()
	end
	table.clear(extraParts)
	table.clear(buffLeft)
	table.clear(flashLeft)

	--[[
		Модели уходят вместе с пулами, а не возвращаются в них: их детали
		лежат в контейнере забега, и он будет уничтожен. Пул, переживший
		контейнер, раздал бы следующему забегу уничтоженные модели.
	]]
	table.clear(modelOf)
	table.clear(modelKeyOf)
	table.clear(modelPools)

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
	releaseExtras(id)

	local part = getPool().Get()
	part.Shape = if def.model.shape == "Ball"
		then Enum.PartType.Ball
		elseif def.model.shape == "Cylinder" then Enum.PartType.Cylinder
		else Enum.PartType.Block
	part.Size = bodySizes[typeId]
	part.Color = colorFor(def)
	part.Material = if def.model.neon then Enum.Material.Neon else Enum.Material.SmoothPlastic
	part.Transparency = def.model.transparency or 0
	part.CFrame = CFrame.new(origin + Vector3.new(position.X, def.model.size.Y * 0.5, position.Z))
	part.Parent = container

	positions[id] = position
	offsets[id] = Vector3.zero
	typeIds[id] = typeId
	phases[id] = (id % 32) * 0.4
	parts[id] = part

	--[[
		Детали берутся на спавне, а не в кадре отрисовки: пул на выдаче делает
		Instance.new, если кончился, и делать это посреди кадра — худшее место
		из возможных. Здесь спавн и так уже стоит одной детали.
	]]
	local defParts = def.model.parts
	if defParts then
		local base = (id - 1) * MAX_PARTS
		local sizes = extraSizes[typeId]
		local colors = extraColors[typeId]

		for index, entry in defParts do
			local extra = getExtraPool().Get()
			local mesh = meshOf[extra]
			if mesh then
				mesh.MeshType = MESHES[entry.shape] or Enum.MeshType.Brick
			end
			extra.Size = sizes[index]
			extra.Color = colors[index]
			extra.Transparency = 0
			extra.Parent = container
			extraParts[base + index] = extra
		end
	end

	buffLeft[id] = nil
	isAlive[id] = true
	visible[id] = true
	-- Целым враг считается до первого ресинка: полоска над невредимым
	-- не рисуется вовсе, поэтому «пока не знаем» и «цел» здесь одно и то же.
	health[id] = 1

	if id > highWater then
		highWater = id
	end
end

--[[
	Усиление полем босса: неуязвим и быстр на столько-то секунд.

	Клиент отсчитывает срок сам тем же шагом 1/30 с, что и сервер, и той же
	скоростью — иначе усиленная толпа на экране разошлась бы с той, по которой
	считается урон. По сети приходит только момент начала и длительность.

	Цвет меняется сразу: игрок обязан видеть, по кому бить бесполезно,
	до того, как он потратит на это способность.
]]
--[[
	Вернуть врагу его собственные цвета.

	Одна функция на два случая — конец усиления и конец вспышки попадания:
	перекрашивают они одинаково, а разъехавшись, оставили бы врага белым
	навсегда в том из них, который забыли поправить.
]]
--[[
	Палитра модели врага: свой цвет из Palette.Model.bases, если он есть,
	иначе стихия. То же правило, что у боссов, и по той же причине —
	гоблин стихии Dark, но фиолетовый гоблин не гоблин.
]]
local function tintsForModel(key: string, def: Types.EnemyDef): PartModel.Tints
	local existing = modelTints[key]
	if existing then
		return existing
	end

	local base = Palette.Model.bases[key] or Palette.Element[def.element]
	local made = PartModel.TintsFor(base, Palette.Model.accent)
	modelTints[key] = made
	return made
end

local function getModelPool(key: string, def: Types.EnemyDef): Pool.Pool<PartModel.Built>
	local existing = modelPools[key]
	if existing then
		return existing
	end

	local modelDef = Models.ByKey[key]
	local tints = tintsForModel(key, def)
	--[[
		Пул набирается сразу на весь бюджет: собрать два десятка моделей
		посреди волны — это тот самый Instance.new в бою, которого во всём
		рендере врагов нет. Начало забега для этого и есть место.
	]]
	local created = Pool.new(function(): PartModel.Built
		return PartModel.Build(modelDef, tints, container :: Instance)
	end, function(model: PartModel.Built)
		model.SetVisible(false)
	end, modelEnemiesBudget)
	modelPools[key] = created
	return created
end

local function releaseModel(id: number): ()
	local model = modelOf[id]
	if not model then
		return
	end

	local pool = modelPools[modelKeyOf[id]]
	if pool then
		pool.Release(model)
	end
	modelOf[id] = nil
	modelKeyOf[id] = nil
end

local function restoreColors(id: number, def: Types.EnemyDef): ()
	--[[
		У модельного врага цвет живёт в модели. Ручной цвет деталей (тряпьё,
		сталь, глаза) SetTints не трогает — вспыхивает и гаснет кожа, и этого
		достаточно: сигнал «попал» нужен на теле, а не на снаряжении.
	]]
	local model = modelOf[id]
	if model then
		model.SetTints(tintsForModel(modelKeyOf[id], def))
	end

	local part = parts[id]
	if part then
		part.Color = colorFor(def)
	end

	local colors = extraColors[typeIds[id]]
	if not colors then
		return
	end

	local base = (id - 1) * MAX_PARTS
	for slot = 1, #colors do
		local extra = extraParts[base + slot]
		if extra then
			extra.Color = colors[slot]
		end
	end
end

local function applyBuff(id: number, seconds: number): ()
	if not isAlive[id] then
		return
	end

	buffLeft[id] = seconds
	-- Вспышка попадания снимается: её счётчик кончится раньше поля и вернул бы
	-- врагу обычный цвет, то есть показал бы уязвимым того, кто неуязвим.
	flashLeft[id] = nil
	-- Модель тоже: белеть обязано ВСЁ тело, а ручной цвет тряпья и клинка
	-- палитре носителя не подчиняется.
	releaseModel(id)

	local part = parts[id]
	if part then
		part.Color = Palette.Enemy.buffed
	end

	-- Белеет весь враг целиком: голова и меч, оставшиеся своего цвета,
	-- читались бы как «вот сюда бить можно».
	local base = (id - 1) * MAX_PARTS
	for slot = 1, MAX_PARTS do
		local extra = extraParts[base + slot]
		if extra then
			extra.Color = Palette.Enemy.buffed
		end
	end
end

local function applyDespawn(id: number, reason: number): ()
	isAlive[id] = nil
	visible[id] = nil
	health[id] = nil

	--[[
		Глаза уходят сразу, даже когда тело остаётся догорать вспышкой:
		белая вспышка — это уже не враг, а след от него, и пара чёрных
		точек, висящих в воздухе поверх неё, читается как брошенные части.
	]]
	releaseExtras(id)
	releaseModel(id)
	buffLeft[id] = nil
	flashLeft[id] = nil

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
		-- Модельный враг ходил с невидимым телом: вспышке нужно вернуть его,
		-- иначе смерть ближайших врагов проходила бы вообще без следа.
		part.Transparency = 0
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

	local buffSpeed = Balance.Combat.playerWalkSpeed * Balance.Bosses.buffSpeedFactor

	for id = 1, highWater do
		if isAlive[id] then
			local def = Enemies.List[typeIds[id]]
			local speed = def.stats.speed

			--[[
				Усиленный бежит абсолютной скоростью поля — той же, что на
				сервере. Срок кончился здесь же: возвращать цвет отдельным
				проходом по всем врагам ради этого незачем.
			]]
			local remaining = buffLeft[id]
			if remaining then
				remaining -= dt
				if remaining > 0 then
					buffLeft[id] = remaining
					speed = buffSpeed
				else
					buffLeft[id] = nil
					restoreColors(id, def)
				end
			end

			-- Вспышка попадания гаснет так же, как усиление: своим счётчиком
			-- и тем же возвратом цвета.
			local flash = flashLeft[id]
			if flash then
				flash -= dt
				if flash > 0 then
					flashLeft[id] = flash
				else
					flashLeft[id] = nil
					restoreColors(id, def)
				end
			end

			local position = EnemyMotion.Chase(positions[id], playerLocal, speed, dt)

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

local function render(now: number, deltaTime: number, playerLocal: Vector3): ()
	local bobSpeed = Balance.Combat.bobSpeed
	local bobAmplitude = Balance.Combat.bobAmplitude
	local renderDistanceSquared = renderDistance * renderDistance
	local barDistanceSquared = Balance.Combat.healthBarDistance * Balance.Combat.healthBarDistance
	-- count — сколько всего деталей уедет в BulkMoveTo (с глазами),
	-- bodies — сколько это врагов. Оверлей показывает врагов, а не детали.
	local count = 0
	local bodies = 0
	local bars = 0
	local modelled = 0

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
				local extraBase = (id - 1) * MAX_PARTS

				if not inRange then
					if visible[id] ~= false then
						-- Модель уходит вместе с видимостью: иначе она осталась бы
						-- стоять там, где враг скрылся, до самой его смерти.
						releaseModel(id)
						part.Transparency = 1
						for slot = 1, MAX_PARTS do
							local extra = extraParts[extraBase + slot]
							if extra then
								extra.Transparency = 1
							end
						end
						visible[id] = false
					end
					continue
				end

				local def = Enemies.List[typeIds[id]]

				--[[
					Вернуть СВОЮ прозрачность, а не ноль: у слизней тело
					полупрозрачное, и возврат в видимость делал бы их
					непрозрачными до самой смерти. Детали непрозрачны всегда —
					сквозь глаз или клинок тело просвечивать не должно.
				]]
				if visible[id] == false then
					part.Transparency = def.model.transparency or 0
					for slot = 1, MAX_PARTS do
						local extra = extraParts[extraBase + slot]
						if extra then
							extra.Transparency = 0
						end
					end
				end
				visible[id] = true

				local offset = offsets[id]

				--[[
					Модель ближайшим. Взятая один раз, она остаётся у врага,
					пока он жив и виден: перебирать «а кто теперь ближе»
					каждый кадр значило бы мигать моделями в толпе.

					Бюджет считается заново каждый кадр, поэтому освободившееся
					место достаётся следующему врагу без всякой бухгалтерии.
				]]
				local model = modelOf[id]
				if not model and def.modelKey and modelled < modelEnemiesBudget and not buffLeft[id] then
					model = getModelPool(def.modelKey, def).Get()
					model.SetVisible(true)
					modelOf[id] = model
					modelKeyOf[id] = def.modelKey
					part.Transparency = 1
					for slot = 1, MAX_PARTS do
						local extra = extraParts[extraBase + slot]
						if extra then
							extra.Transparency = 1
						end
					end
				end

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

				local center = origin
					+ Vector3.new(position.X + offset.X, def.model.size.Y * 0.5 + bob, position.Z + offset.Z)

				count += 1
				bodies += 1
				moveParts[count] = part

				if model then
					modelled += 1

					-- Тело едет невидимым: на нём висит полоска здоровья
					-- и им же догорает вспышка смерти.
					moveCFrames[count] = CFrame.new(center)

					local distance = math.sqrt(dx * dx + dz * dz)
					local forwardX, forwardZ = 0, -1
					if distance > 1e-3 then
						forwardX = -dx / distance
						forwardZ = -dz / distance
					end

					--[[
						Пивот модели стоит на полу: offset деталей отсчитан
						от него же. Покачивание телу не передаётся — у модели
						есть ноги, и качать её вверх-вниз поверх шага значит
						отрывать её от земли.

						Скорость идёт в Draw как есть: канал step считает шаг
						от пройденного пути, и на ней он и держится.
					]]
					model.Draw(
						CFrame.new(
							center.X,
							origin.Y,
							center.Z,
							-forwardZ,
							0,
							-forwardX,
							0,
							1,
							0,
							forwardX,
							0,
							-forwardZ
						),
						deltaTime,
						def.stats.speed
					)
					continue
				end

				local locals = extraLocal[typeIds[id]]
				if not locals then
					-- Врагу без деталей разворот не нужен и не виден:
					-- самый дешёвый путь остаётся самым частым.
					moveCFrames[count] = CFrame.new(center)
					continue
				end

				--[[
					Враг с деталями разворачивается на игрока целиком: голова,
					меч и глаза обязаны быть с одной стороны тела, а не там,
					куда легли мировые оси.

					Матрица собирается вручную из направления взгляда, а не
					через CFrame.lookAt: поворот тут только вокруг вертикали,
					и полный ортонормированный базис на каждого из трёхсот
					врагов каждый кадр строить незачем.

					dx и dz уже посчитаны выше для проверки дальности —
					остаётся один корень на видимого врага.
				]]
				local distance = math.sqrt(dx * dx + dz * dz)
				local forwardX, forwardZ = 0, -1
				if distance > 1e-3 then
					forwardX = -dx / distance
					forwardZ = -dz / distance
				end

				-- Правый вектор — векторное произведение взгляда на вертикаль.
				local face =
					CFrame.new(center.X, center.Y, center.Z, -forwardZ, 0, -forwardX, 0, 1, 0, forwardX, 0, -forwardZ)

				local tilt = bodyLocal[typeIds[id]]
				moveCFrames[count] = if tilt then face * tilt else face

				for index = 1, #locals do
					local extra = extraParts[extraBase + index]
					if extra then
						count += 1
						moveParts[count] = extra
						moveCFrames[count] = face * locals[index]
					end
				end
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
	activeCount = bodies

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
		render(now, deltaTime, playerLocal)
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
	modelEnemiesBudget = quality.modelEnemies

	local folder = Instance.new("Folder")
	folder.Name = "Enemies"
	folder.Parent = Workspace
	container = folder

	getPool()
	getExtraPool()

	--[[
		Пулы моделей набираются здесь, а не при первой встрече с гоблином:
		собрать два десятка моделей посреди волны — это Instance.new в бою,
		которого во всём рендере врагов нет. Врагов с моделями двое, и обоих
		видно из конфига, а не из того, что успело заспавниться.
	]]
	for _, def in Enemies.List do
		if def.modelKey then
			getModelPool(def.modelKey, def)
		end
	end

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

	-- Пул деталей уходит вместе с основным: они лежали в том же
	-- контейнере, который только что уничтожен.
	local extras = extraPool
	if extras then
		extras.Destroy()
		extraPool = nil
		--[[
			Ссылки на меши обязаны уйти вместе с пулом. Таблица держит их
			по самой детали, и без очистки каждый забег оставлял бы после
			себя по семь сотен записей на уничтоженные части.
		]]
		table.clear(meshOf)
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
		elseif event.kind == Packet.Kind.Buff then
			applyBuff(event.id, event.aux / Packet.BuffScale)
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

--[[
	Вспышка попадания по всем врагам в области.

	КОСМЕТИКА И ТОЛЬКО. Урон считает сервер по своей геометрии; здесь клиент
	лишь показывает, что удар пришёлся, — и потому промах на полстада ничего
	не стоит, а расхождение с сервером невозможно в принципе: отсюда никакой
	урон не следует.

	Координаты локальные, как у всей симуляции врагов.

	Кольцо, а не круг: расходящаяся волна задевает врагов по мере ухода,
	и внутренний радиус отсекает тех, кого она прошла в прошлом кадре.
	start и span задают сектор — ими пользуется клин; nil означает полный круг.

	push = false убирает отскок, оставляя вспышку. Нужен формам, которые бьют
	НЕПРЕРЫВНО: см. комментарий у самого отскока ниже.
]]
function EnemyRenderController.Flash(
	centre: Vector3,
	inner: number,
	outer: number,
	colour: Color3,
	start: number?,
	span: number?,
	push: boolean?
): ()
	if not active then
		return
	end

	local found = hash.Collect(centre, outer, flashHits)
	local half = if span then span * 0.5 else 0
	-- Середина сектора считается заранее и отдельной переменной: приведение
	-- типа посреди арифметики читается двусмысленно и делает то, чего не ждёшь.
	local middle = (start or 0) + half

	for index = 1, found do
		local id = flashHits[index]

		-- Усиленный полем босса неуязвим, и вспышка на нём соврала бы: игрок
		-- обязан видеть, что бить по нему бесполезно.
		if not isAlive[id] or buffLeft[id] then
			continue
		end

		local position = positions[id]
		local dx = position.X - centre.X
		local dz = position.Z - centre.Z
		local distance = math.sqrt(dx * dx + dz * dz)

		-- Радиус самого врага в счёт: волна, прошедшая по краю большого
		-- слизня, задела его — как и на сервере, где это делает CollectHits.
		local radius = Enemies.List[typeIds[id]].stats.radius
		if distance > outer + radius or distance < inner - radius then
			continue
		end

		if span then
			local delta = (math.atan2(dz, dx) - middle + math.pi) % (math.pi * 2) - math.pi
			if math.abs(delta) > half then
				continue
			end
		end

		flashLeft[id] = HIT_FLASH_TIME

		local model = modelOf[id]
		if model then
			model.SetTints(PartModel.TintsFor(colour, colour))
		end

		local part = parts[id]
		if part then
			part.Color = colour
		end

		local base = (id - 1) * MAX_PARTS
		for slot = 1, MAX_PARTS do
			local extra = extraParts[base + slot]
			if extra then
				extra.Color = colour
			end
		end

		--[[
			Отскок делается уже существующей невязкой, которая и так затухает
			к нулю каждый тик. Своего состояния он не заводит, а главное —
			не трогает positions: позиция врага принадлежит серверу, и сдвинуть
			её значило бы показывать не то, по чему считается урон.

			НЕПРЕРЫВНЫМ ФОРМАМ ОТСКОК НЕ ДАВАТЬ. Он рассчитан на одиночное
			попадание: толкнуть один раз и затухнуть. Орбы же зовут вспышку
			КАЖДЫЙ КАДР, пока летят, и полстада за кадр складываются быстрее,
			чем невязка успевает гаснуть, — враг уезжает на метры. Хуже того,
			толчок идёт от орба, а орб крутится между игроком и толпой, так
			что половину круга он сдвигает врагов НА игрока. Выглядело это
			как притягивание толпы вплотную, и урон тут ни при чём: позиции
			на сервере всё это время оставались прежними.
		]]
		if push ~= false and distance > 1e-3 then
			offsets[id] += Vector3.new(dx / distance, 0, dz / distance) * HIT_PUSH
		end
	end
end

function EnemyRenderController.GetActiveCount(): number
	return activeCount
end

function EnemyRenderController.Start(): ()
	-- Раскладка деталей считается один раз на весь сеанс: она зависит
	-- только от Config/Enemies и между забегами не меняется.
	buildLayouts()
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
