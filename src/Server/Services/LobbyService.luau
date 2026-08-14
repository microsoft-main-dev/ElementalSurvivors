--!strict
--[[
	LobbyService — лобби целиком строится кодом при старте сервера (раздел 4 ТЗ).
	Ручного строительства в Studio нет: всё, что видно в игре, лежит в git.

	Здесь только геометрия и точки взаимодействия. Панели, которые эти точки
	открывают, — целиком клиентские: сервер не должен участвовать в показе окна,
	его дело — проверять то, что игрок в этом окне нажал (это LobbyNetService).

	Поэтому у промптов проставлен атрибут Panel: клиент по нему понимает, какое
	окно открыть, и ни одного лишнего Remote для этого не нужно.

	Объекты раздела 4: портал, пять яиц, прилавок магазина, стенд питомца,
	колесо фортуны, стенд рекордсменов и доска квестов.

	У последних трёх, как и у портала с яйцами, здесь остался только невидимый
	объём с промптом: сами вещи рисует и анимирует клиент из Config/Props.
	Промпт обязан висеть на серверной детали — созданный клиентом до сервера
	не доедет вовсе.

	Публичный API:
		LobbyService.Init()          -- строит мир
		LobbyService.Start()         -- вешает обработчики
		LobbyService.GetSpawnCFrame() -> CFrame
]]

local Lighting = game:GetService("Lighting")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Balance = require(Shared.Config.Balance)
local Palette = require(Shared.Config.Palette)
local Props = require(Shared.Config.Props)

local LOBBY_FOLDER_NAME = "Lobby"

local LobbyService = {}

local lobbyFolder: Folder? = nil
local spawnLocation: SpawnLocation? = nil

--[[
	Атмосфера. Lighting.Technology выставляется через default.project.json,
	потому что это свойство места и из скрипта не меняется. Всё остальное
	дублируется здесь, чтобы место было корректным даже без синхронизации Rojo.
]]
local function applyLighting(): ()
	Lighting.GlobalShadows = false
	Lighting.EnvironmentDiffuseScale = 0
	Lighting.EnvironmentSpecularScale = 0
	Lighting.Brightness = 2
	Lighting.ClockTime = 14
	Lighting.GeographicLatitude = 0
	Lighting.Ambient = Palette.Lobby.floorAccent
	Lighting.OutdoorAmbient = Palette.Lobby.floorAccent
	Lighting.FogColor = Palette.UI.background
	Lighting.FogStart = Balance.Lobby.fogStart
	Lighting.FogEnd = Balance.Lobby.fogEnd

	--[[
		Atmosphere отключает FogStart/FogEnd целиком, поэтому его быть не должно.
		Вместо стандартного неба — Sky с пустыми текстурами: он даёт ровный тёмный
		фон без единого ассета. Без этого горизонт остаётся ярко-голубым,
		и туман на его фоне не читается.
	]]
	for _, child in Lighting:GetChildren() do
		if child:IsA("Sky") or child:IsA("Atmosphere") then
			child:Destroy()
		end
	end

	local sky = Instance.new("Sky")
	sky.SkyboxBk = ""
	sky.SkyboxDn = ""
	sky.SkyboxFt = ""
	sky.SkyboxLf = ""
	sky.SkyboxRt = ""
	sky.SkyboxUp = ""
	sky.CelestialBodiesShown = false
	sky.StarCount = 0
	sky.Parent = Lighting
end

-- Убирает стандартные объекты пустого места, чтобы они не мешали лобби.
local function clearDefaults(): ()
	for _, child in Workspace:GetChildren() do
		if child.Name == "Baseplate" or child:IsA("SpawnLocation") then
			child:Destroy()
		end
	end
end

local function makePart(name: string, size: Vector3, position: Vector3, color: Color3, parent: Instance): Part
	local part = Instance.new("Part")
	part.Name = name
	part.Size = size
	part.Position = position
	part.Color = color
	part.Material = Enum.Material.SmoothPlastic
	part.Anchored = true
	part.TopSurface = Enum.SurfaceType.Smooth
	part.BottomSurface = Enum.SurfaceType.Smooth
	part.Parent = parent
	return part
end

--[[
	Крыльцо портала и дорожка от круга появления к нему.

	Портал стоит за краем плиты и до этого был ничем с ней не связан: между
	кругом появления и им лежало шестьдесят стадов пустой мостовой. Крыльцо
	заходит на плиту и потому читается её продолжением, а дорожка выложена тем
	же светлым камнем, что и круг: одна кладка от места, где игрок появляется,
	до места, куда он идёт.

	Прямоугольники приходят готовыми из Config/Props — там же, где стоит сам
	портал. Здесь только два тона и два слоя: кайма ниже, заливка выше,
	ровно как у плиты с её бортом и как у круга появления.

	Толщина 0.3 и никакой коллизии: кладка вделана в мостовую, а не лежит на
	ней, и порога под ногами быть не должно.
]]
local function buildPortalWalk(parent: Instance): ()
	local walk = Props.PortalWalk

	local slabs = {
		{ name = "PortalApronRim", slab = walk.apronRim, rim = true },
		{ name = "PortalPathRim", slab = walk.pathRim, rim = true },
		{ name = "PortalApron", slab = walk.apron, rim = false },
		{ name = "PortalPath", slab = walk.path, rim = false },
	}

	for _, entry in slabs do
		local part = Instance.new("Part")
		part.Name = entry.name
		part.Size = Vector3.new(entry.slab.size.X, 0.3, entry.slab.size.Y)
		--[[
			ПОРЯДОК СЛОЁВ У КРУГА ПОЯВЛЕНИЯ, СНИЗУ ВВЕРХ:
			кайма дорожки 0.2, тёмное кольцо круга 0.26, заливка дорожки 0.32,
			светлая середина круга 0.38. Шаг везде 0.06.

			Он именно такой, а не «дорожка целиком под кругом», из-за кольца:
			КАЙМА КРУГА ОБЯЗАНА РАЗОМКНУТЬСЯ ТАМ, ГДЕ ВХОДИТ ДОРОЖКА. Проходя
			поверх неё, кольцо резало светлый камень тёмной дугой — дорожка
			упиралась в бортик вместо того, чтобы втекать в круг. Заливка
			поэтому лежит ВЫШЕ кольца (и разрывает его ровно на свою ширину),
			но НИЖЕ середины круга — иначе она резала бы уже её.

			Наложение вообще неизбежно: прямоугольник с окружностью встык
			не сходятся, по краям ширины остаётся полумесяц голой плиты.
			А на одной высоте лица спорят, и одинаковый цвет с материалом
			от этого не спасают — так и было сделано, и так и не сработало:
			у блока и у цилиндра мостовая проецируется по-разному, и перекрытие
			читалось полосатой кашей. Поэтому спор решается только высотой:
			кто выше — тот и рисуется.
		]]
		part.CFrame = entry.slab.cframe + Vector3.new(0, if entry.rim then 0.2 else 0.32, 0)
		part.Color = if entry.rim then Palette.Lobby.plazaRim else Palette.Lobby.plazaInlay
		part.Material = if entry.rim then Enum.Material.Slate else Enum.Material.Cobblestone
		part.Anchored = true
		part.CanCollide = false
		part.CanQuery = false
		part.CanTouch = false
		part.TopSurface = Enum.SurfaceType.Smooth
		part.BottomSurface = Enum.SurfaceType.Smooth
		part.Parent = parent
	end
end

local function buildFloor(parent: Instance): ()
	local size = Balance.Lobby.floorSize
	local thickness = Balance.Lobby.floorThickness
	local half = size / 2

	--[[
		Поляна: верхняя грань ровно на y = 0.

		Материал тот же, что у пола Лесной поляны на арене (Config/Biomes):
		лобби и первая локация — один и тот же лес, и разная фактура травы
		читалась бы как два разных мира. Встроенный материал движка ассетом
		не является, правило 4 его не касается.
	]]
	local meadow = makePart(
		"Meadow",
		Vector3.new(size, thickness, size),
		Vector3.new(0, -thickness / 2, 0),
		Palette.Lobby.grass,
		parent
	)
	meadow.Material = Enum.Material.LeafyGrass

	--[[
		Мощёная площадь посреди поляны (планировка владельца). Два круга:
		широкий тёмный — кайма, внутренний светлее — сама плитка. Один круг
		читается пятном краски, два — площадью с бортом.

		Лежат чуть выше пола и без коллизии: игрок ходит по поляне, а плита
		только рисуется. Толщина у неё нулевая по смыслу, поэтому и ступеньки
		на краю не возникает.

		ФАКТУРА. Сама плита — Cobblestone: мостовая, то есть ровно то, чем
		площадь и должна быть. Кайма — Slate, крупная и ровная: одна и та же
		мостовая на обоих кругах слила бы борт с плитой, а борт здесь и есть
		единственное, что отделяет площадь от травы.
	]]
	local rim = Instance.new("Part")
	rim.Name = "PlazaRim"
	rim.Shape = Enum.PartType.Cylinder
	rim.Size = Vector3.new(0.3, Balance.Lobby.plazaRadius * 2 + 5, Balance.Lobby.plazaRadius * 2 + 5)
	rim.CFrame = CFrame.new(0, 0.06, 0) * CFrame.Angles(0, 0, math.rad(90))
	rim.Color = Palette.Lobby.plazaRim
	rim.Material = Enum.Material.Slate
	rim.Anchored = true
	rim.CanCollide = false
	rim.Parent = parent

	local plaza = Instance.new("Part")
	plaza.Name = "Plaza"
	plaza.Shape = Enum.PartType.Cylinder
	plaza.Size = Vector3.new(0.3, Balance.Lobby.plazaRadius * 2, Balance.Lobby.plazaRadius * 2)
	plaza.CFrame = CFrame.new(0, 0.14, 0) * CFrame.Angles(0, 0, math.rad(90))
	plaza.Color = Palette.Lobby.plaza
	plaza.Material = Enum.Material.Cobblestone
	plaza.Anchored = true
	plaza.CanCollide = false
	plaza.Parent = parent

	buildPortalWalk(parent)

	local wallHeight = Balance.Lobby.wallHeight

	--[[
		По стороне — одна невидимая стена от самой земли.

		ВИДИМОГО БОРТИКА ЗДЕСЬ БОЛЬШЕ НЕТ. Он был нужен, пока за краем поляны
		начиналось небо: тёмная кайма хоть как-то объясняла, где кончается мир.
		Теперь там стоит лес (LobbyForestController), край объясняет он, а трава
		за стеной продолжается тем же цветом и той же фактурой — и кайма поперёк
		сплошного газона осталась полосой непонятно чего.

		Стена при этом обязана начинаться с нуля, а не с прежних трёх стадов:
		бортик был не только виден, но и был телом, в которое игрок упирался.
	]]
	local sides: { { offset: Vector3, size: Vector3 } } = {
		{ offset = Vector3.new(0, 0, -half), size = Vector3.new(size + 4, 1, 4) },
		{ offset = Vector3.new(0, 0, half), size = Vector3.new(size + 4, 1, 4) },
		{ offset = Vector3.new(-half, 0, 0), size = Vector3.new(4, 1, size + 4) },
		{ offset = Vector3.new(half, 0, 0), size = Vector3.new(4, 1, size + 4) },
	}

	for index, side in sides do
		local wall = makePart(
			`Wall{index}`,
			Vector3.new(side.size.X, wallHeight, side.size.Z),
			side.offset + Vector3.new(0, wallHeight / 2, 0),
			-- Цвет любой: стена прозрачна. Своей записи в палитре у неё поэтому
			-- и нет — мёртвый цвет однажды подобрали бы для чего-нибудь ещё.
			Palette.Lobby.grass,
			parent
		)
		wall.Transparency = 1
		wall.CanCollide = true
		wall.CanQuery = false
		wall.CanTouch = false
	end
end

--[[
	Точка появления игрока.

	САМА ПЛОЩАДКА НЕВИДИМА. Неоновый квадрат посреди мостовой читался наклейкой:
	он и раньше был чужеродным, а с фактурой плиты стал вычурным. Место
	появления показывает не он, а вделанный в плиту круг — тех же камней,
	что и площадь, только светлее.

	ПОВОРОТ НА 180. Персонаж появляется лицом туда, куда смотрит площадка,
	а смотрела она на портал — то есть игрок каждый раз начинал спиной ко всему,
	ради чего в лобби заходят: к лавке, яйцам, колесу и стендам. Портал
	за спиной, и это правильно: к нему идут сознательно, а витрины должны
	попадаться на глаза сами.

	Развернуть саму планировку было бы тем же самым с точки зрения игрока,
	но подвинуло бы каждую точку, промпт и объём в Config/Props.
]]
local function buildSpawn(parent: Instance): SpawnLocation
	local spawn = Instance.new("SpawnLocation")
	spawn.Name = "LobbySpawn"
	spawn.Size = Vector3.new(12, 1, 12)
	-- Верх заподлицо с плитой: приподнятая площадка давала ступеньку под ногами.
	spawn.CFrame = CFrame.new(0, -0.5, 0) * CFrame.Angles(0, math.pi, 0)
	spawn.Transparency = 1
	spawn.Anchored = true
	--[[
		Коллизии нет: игрок стоит на поляне, а площадка теперь утоплена в неё.
		С коллизией она была бы невидимым порогом ровно там, где игрок
		появляется.
	]]
	spawn.CanCollide = false
	spawn.Neutral = true
	spawn.Duration = 0
	spawn.TopSurface = Enum.SurfaceType.Smooth
	spawn.BottomSurface = Enum.SurfaceType.Smooth
	spawn.Parent = parent

	--[[
		Круг, вделанный в мостовую. Два кольца, а не одно пятно: внешнее
		темнее плиты, внутреннее светлее — так круг читается выложенным,
		а не нарисованным поверх.

		ВЫСОТЫ КОЛЕЦ ЧЕРЕДУЮТСЯ С ВЫСОТАМИ ДОРОЖКИ: тёмное кольцо на 0.26 лежит
		между её каймой (0.2) и её заливкой (0.32), а светлая середина на 0.38 —
		выше всего. Так дорожка разрывает кольцо ровно на свою ширину и втекает
		в круг, а не упирается в бортик. Подробности — в buildPortalWalk.
	]]
	-- Радиус живёт в Config/Props: от него отсчитывается начало дорожки
	-- к порталу, и лежат они на одной высоте.
	local diameter = Props.SpawnInlayRadius * 2

	local outer = Instance.new("Part")
	outer.Name = "SpawnInlayOuter"
	outer.Shape = Enum.PartType.Cylinder
	outer.Size = Vector3.new(0.3, diameter, diameter)
	outer.CFrame = CFrame.new(0, 0.26, 0) * CFrame.Angles(0, 0, math.rad(90))
	outer.Color = Palette.Lobby.plazaRim
	outer.Material = Enum.Material.Slate
	outer.Anchored = true
	outer.CanCollide = false
	outer.CanQuery = false
	outer.CanTouch = false
	outer.Parent = parent

	local inner = Instance.new("Part")
	inner.Name = "SpawnInlayInner"
	inner.Shape = Enum.PartType.Cylinder
	inner.Size = Vector3.new(0.3, diameter - 4, diameter - 4)
	inner.CFrame = CFrame.new(0, 0.38, 0) * CFrame.Angles(0, 0, math.rad(90))
	inner.Color = Palette.Lobby.plazaInlay
	inner.Material = Enum.Material.Cobblestone
	inner.Anchored = true
	inner.CanCollide = false
	inner.CanQuery = false
	inner.CanTouch = false
	inner.Parent = parent

	return spawn
end

--[[
	ТАБЛИЧКИ СТУДИИ НАД ПОРТАЛОМ БОЛЬШЕ НЕТ (решение владельца). Она висела
	в тридцати стадах над землёй прямо на линии взгляда на портал и была
	единственным объектом лобби, который ничего не делает и никуда не ведёт.

	Логотип от этого никуда не делся: он показывается на экране загрузки
	(BootController), где ему и место — там его видит каждый вошедший, а не
	только тот, кто поднял камеру над воротами.
]]

--[[
	Заглушка портала: площадка, две неоновые стойки и перекладина.
	Настоящая логика (запрос слота арены, выбор режима, телепорт) — в M1.
]]
--[[
	Точка взаимодействия. Атрибут Panel говорит клиенту, какое окно открыть:
	сервер о самих окнах ничего не знает и знать не должен.

	MaxActivationDistance небольшой намеренно — объекты стоят рядом, и широкая
	зона означала бы, что игрок целится в яйцо, а открывается магазин.
]]
local function addPrompt(parent: BasePart, objectText: string, actionText: string, panel: string, key: string?): ()
	local prompt = Instance.new("ProximityPrompt")
	prompt.Name = "OpenPrompt"
	prompt.ObjectText = objectText
	prompt.ActionText = actionText
	prompt.HoldDuration = 0
	prompt.MaxActivationDistance = 12
	prompt.RequiresLineOfSight = false
	prompt:SetAttribute("Panel", panel)
	if key then
		prompt:SetAttribute("Target", key)
	end
	prompt.Parent = parent
end

--[[
	Невидимый объём взаимодействия для предмета, который рисует клиент.

	Сервер держит только то, во что игрок упирается и что он нажимает:
	промпт, созданный клиентом, до сервера не доедет вовсе, а коллизию
	игрока сервер проверяет сам. Сама вещь при этом живёт в Config/Props —
	туда же уходит и вся её анимация.

	Размер обязан примерно совпадать с видимым предметом: игрок упирается
	в то, что видит, и расхождение читается как дыра в мире.
]]
--[[
	Точки взаимодействия. Все до единой берутся из Config/Props: там же, где
	эти вещи расставлены и нарисованы.

	Раньше каждая имела свою функцию, которая считала координаты сама из чисел
	Balance. Пока всё стояло по осям, это сходилось; на круглой площади объекты
	стоят под углом, и второй расчёт разъехался бы с первым в тот же день.
]]
local function buildAnchors(parent: Instance): ()
	for _, anchor in Props.Anchors do
		local part = Instance.new("Part")
		part.Name = anchor.name
		part.Size = anchor.size
		part.CFrame = CFrame.new(anchor.position + Vector3.new(0, anchor.size.Y * 0.5, 0))
			* CFrame.Angles(0, math.rad(anchor.yaw), 0)
		part.Color = Palette.Lobby.sign
		part.Material = Enum.Material.SmoothPlastic
		part.Anchored = true
		part.CanCollide = true
		part.Transparency = 1
		part.TopSurface = Enum.SurfaceType.Smooth
		part.BottomSurface = Enum.SurfaceType.Smooth
		part.Parent = parent

		addPrompt(part, anchor.objectText, "Open", anchor.panel, anchor.target)
	end
end

function LobbyService.Init(): ()
	applyLighting()
	clearDefaults()

	local existing = Workspace:FindFirstChild(LOBBY_FOLDER_NAME)
	if existing then
		existing:Destroy()
	end

	local folder = Instance.new("Folder")
	folder.Name = LOBBY_FOLDER_NAME
	folder.Parent = Workspace

	buildFloor(folder)
	spawnLocation = buildSpawn(folder)
	buildAnchors(folder)

	lobbyFolder = folder
	print(
		`[LobbyService] Лобби построено: {Balance.Lobby.floorSize}x{Balance.Lobby.floorSize} стадов`
	)
end

function LobbyService.Start(): ()
	print(
		`[LobbyService] Лобби построено: {Balance.Lobby.floorSize}x{Balance.Lobby.floorSize} стадов`
	)
end

--[[
	Куда ставить персонажа, если это делает код, а не сам SpawnLocation.

	Приподнято над площадкой: сама она утоплена в плиту заподлицо, и её
	собственный CFrame поставил бы персонажа ногами в пол.
]]
function LobbyService.GetSpawnCFrame(): CFrame
	local spawn = spawnLocation
	if spawn then
		return spawn.CFrame + Vector3.new(0, 3, 0)
	end
	return CFrame.new(0, Balance.Lobby.floorThickness, 0)
end

function LobbyService.GetFolder(): Folder?
	return lobbyFolder
end

return LobbyService
