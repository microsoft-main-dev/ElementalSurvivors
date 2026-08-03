--!strict
--[[
	LobbyService — лобби целиком строится кодом при старте сервера (раздел 4 ТЗ).
	Ручного строительства в Studio нет: всё, что видно в игре, лежит в git.

	Здесь только геометрия и точки взаимодействия. Панели, которые эти точки
	открывают, — целиком клиентские: сервер не должен участвовать в показе окна,
	его дело — проверять то, что игрок в этом окне нажал (это LobbyNetService).

	Поэтому у промптов проставлен атрибут Panel: клиент по нему понимает, какое
	окно открыть, и ни одного лишнего Remote для этого не нужно.

	Объекты раздела 4: портал, пять яиц, прилавок магазина и стенд питомца.
	Колесо фортуны, стенд рекордсменов и ежедневные квесты решением владельца
	отнесены к M6 — они опираются на сюжетные уровни и бесконечный режим,
	которых до M6 нет.

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
local Branding = require(Shared.Config.Branding)
local CombatService = require(script.Parent.CombatService)
local Eggs = require(Shared.Config.Eggs)
local Palette = require(Shared.Config.Palette)

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

local function buildFloor(parent: Instance): ()
	local size = Balance.Lobby.floorSize
	local thickness = Balance.Lobby.floorThickness
	local half = size / 2

	-- Пол: верхняя грань ровно на y = 0.
	makePart(
		"Floor",
		Vector3.new(size, thickness, size),
		Vector3.new(0, -thickness / 2, 0),
		Palette.Lobby.floor,
		parent
	)

	-- Центральный акцентный круг — ориентир, чтобы лобби не выглядело пустым квадратом.
	local disc = Instance.new("Part")
	disc.Name = "CenterDisc"
	disc.Shape = Enum.PartType.Cylinder
	disc.Size = Vector3.new(0.2, 44, 44)
	disc.CFrame = CFrame.new(0, 0.06, 0) * CFrame.Angles(0, 0, math.rad(90))
	disc.Color = Palette.Lobby.floorAccent
	disc.Material = Enum.Material.SmoothPlastic
	disc.Anchored = true
	disc.CanCollide = false
	disc.Parent = parent

	local borderHeight = Balance.Lobby.borderHeight
	local wallHeight = Balance.Lobby.wallHeight

	-- Для каждой из четырёх сторон: видимый бортик + невидимая стена над ним.
	local sides: { { offset: Vector3, size: Vector3 } } = {
		{ offset = Vector3.new(0, 0, -half), size = Vector3.new(size + 4, 1, 4) },
		{ offset = Vector3.new(0, 0, half), size = Vector3.new(size + 4, 1, 4) },
		{ offset = Vector3.new(-half, 0, 0), size = Vector3.new(4, 1, size + 4) },
		{ offset = Vector3.new(half, 0, 0), size = Vector3.new(4, 1, size + 4) },
	}

	for index, side in sides do
		local border = makePart(
			`Border{index}`,
			Vector3.new(side.size.X, borderHeight, side.size.Z),
			side.offset + Vector3.new(0, borderHeight / 2, 0),
			Palette.Lobby.border,
			parent
		)
		border.CanCollide = true

		local wall = makePart(
			`Wall{index}`,
			Vector3.new(side.size.X, wallHeight, side.size.Z),
			side.offset + Vector3.new(0, borderHeight + wallHeight / 2, 0),
			Palette.Lobby.border,
			parent
		)
		wall.Transparency = 1
		wall.CanCollide = true
		wall.CanQuery = false
		wall.CanTouch = false
	end
end

local function buildSpawn(parent: Instance): SpawnLocation
	local spawn = Instance.new("SpawnLocation")
	spawn.Name = "LobbySpawn"
	spawn.Size = Vector3.new(12, 1, 12)
	spawn.Position = Vector3.new(0, 0.5, 0)
	spawn.Color = Palette.Lobby.portal
	spawn.Material = Enum.Material.Neon
	spawn.Anchored = true
	spawn.CanCollide = true
	spawn.Neutral = true
	spawn.Duration = 0
	spawn.TopSurface = Enum.SurfaceType.Smooth
	spawn.BottomSurface = Enum.SurfaceType.Smooth
	spawn.Parent = parent
	return spawn
end

--[[
	Табличка студии. Пока Branding.logoWideAssetId == 0, вместо картинки рисуется
	текст — выдумывать Asset ID нельзя (правило 4 ТЗ).
]]
local function buildSign(parent: Instance, position: Vector3): ()
	local board = makePart("StudioSign", Vector3.new(18, 9, 0.6), position, Palette.Lobby.sign, parent)
	board.CanCollide = false

	local surface = Instance.new("SurfaceGui")
	surface.Name = "Display"
	surface.Face = Enum.NormalId.Back
	surface.SizingMode = Enum.SurfaceGuiSizingMode.PixelsPerStud
	surface.PixelsPerStud = 50
	surface.LightInfluence = 0
	surface.Parent = board

	if Branding.logoWideAssetId > 0 then
		local image = Instance.new("ImageLabel")
		image.Size = UDim2.fromScale(1, 1)
		image.BackgroundTransparency = 1
		image.ScaleType = Enum.ScaleType.Fit
		image.Image = `rbxassetid://{Branding.logoWideAssetId}`
		image.Parent = surface
		return
	end

	local title = Instance.new("TextLabel")
	title.Size = UDim2.fromScale(1, 0.55)
	title.Position = UDim2.fromScale(0, 0.12)
	title.BackgroundTransparency = 1
	title.Font = Enum.Font.GothamBold
	title.Text = Branding.studioName
	title.TextColor3 = Palette.UI.text
	title.TextScaled = true
	title.Parent = surface

	local subtitle = Instance.new("TextLabel")
	subtitle.Size = UDim2.fromScale(1, 0.25)
	subtitle.Position = UDim2.fromScale(0, 0.62)
	subtitle.BackgroundTransparency = 1
	subtitle.Font = Enum.Font.Gotham
	subtitle.Text = Branding.studioSuffix
	subtitle.TextColor3 = Palette.UI.subtext
	subtitle.TextScaled = true
	subtitle.Parent = surface
end

--[[
	Заглушка портала: площадка, две неоновые стойки и перекладина.
	Настоящая логика (запрос слота арены, выбор режима, телепорт) — в M1.
]]
local function buildPortal(parent: Instance): ProximityPrompt
	local portal = Instance.new("Folder")
	portal.Name = "Portal"
	portal.Parent = parent

	local center = Vector3.new(0, 0, -Balance.Lobby.portalOffset)

	local pad = Instance.new("Part")
	pad.Name = "Pad"
	pad.Shape = Enum.PartType.Cylinder
	pad.Size = Vector3.new(0.6, 20, 20)
	pad.CFrame = CFrame.new(center + Vector3.new(0, 0.3, 0)) * CFrame.Angles(0, 0, math.rad(90))
	pad.Color = Palette.Lobby.portal
	pad.Material = Enum.Material.Neon
	pad.Anchored = true
	pad.CanCollide = false
	pad.Parent = portal

	for _, side in { -1, 1 } do
		local pillar = makePart(
			`Pillar{side}`,
			Vector3.new(1.6, 22, 1.6),
			center + Vector3.new(side * 9, 11, 0),
			Palette.Lobby.portalGlow,
			portal
		)
		pillar.Material = Enum.Material.Neon
		pillar.CanCollide = false
	end

	local beam =
		makePart("Beam", Vector3.new(20, 1.6, 1.6), center + Vector3.new(0, 22, 0), Palette.Lobby.border, portal)
	beam.CanCollide = false

	buildSign(portal, center + Vector3.new(0, 28, 0))

	local prompt = Instance.new("ProximityPrompt")
	prompt.Name = "EnterPrompt"
	prompt.ObjectText = Branding.gameName
	prompt.ActionText = "Enter arena"
	prompt.HoldDuration = 0
	prompt.MaxActivationDistance = 14
	prompt.RequiresLineOfSight = false
	prompt.Parent = pad

	return prompt
end

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
	Ряд яиц. Их пять, они стоят в линию и различаются цветом и подписью:
	цена и шансы живут в Config/Eggs и показываются в панели, а не на модели —
	иначе правка баланса требовала бы правки геометрии.
]]
local function buildEggs(parent: Instance): ()
	local row = Instance.new("Folder")
	row.Name = "Eggs"
	row.Parent = parent

	local spacing = Balance.Lobby.eggSpacing
	local count = #Eggs.List
	local startX = -(count - 1) * spacing / 2
	local z = Balance.Lobby.eggRowOffset

	for index, egg in Eggs.List do
		local center = Vector3.new(startX + (index - 1) * spacing, 0, z)

		local pedestal = makePart(
			`Pedestal{egg.key}`,
			Vector3.new(6, 3, 6),
			center + Vector3.new(0, 1.5, 0),
			Palette.Lobby.sign,
			row
		)
		pedestal.CanCollide = true

		local shell = Instance.new("Part")
		shell.Name = `Egg{egg.key}`
		shell.Shape = Enum.PartType.Ball
		shell.Size = Vector3.new(4.4, 4.4, 4.4)
		shell.Position = center + Vector3.new(0, 5.4, 0)
		shell.Color = Color3.fromHex(egg.color)
		shell.Material = Enum.Material.Neon
		shell.Anchored = true
		shell.CanCollide = false
		shell.Parent = row

		addPrompt(shell, egg.displayName, "Open", "Eggs", egg.key)
	end
end

-- Прилавок магазина. Лоты — в Config/Shop, здесь только тумба и точка входа.
local function buildShop(parent: Instance): ()
	local center = Vector3.new(Balance.Lobby.shopOffset, 0, 0)

	local counter =
		makePart("ShopCounter", Vector3.new(8, 5, 14), center + Vector3.new(0, 2.5, 0), Palette.Lobby.sign, parent)
	counter.CanCollide = true

	local sign =
		makePart("ShopSign", Vector3.new(1, 4, 12), center + Vector3.new(0, 7, 0), Palette.Lobby.portalGlow, parent)
	sign.Material = Enum.Material.Neon
	sign.CanCollide = false

	addPrompt(counter, "Shop", "Browse", "Shop")
end

--[[
	Стенд питомца. Сам питомец на нём — модель клиента: она у каждого игрока
	своя, а серверная геометрия одна на всех.
]]
local function buildPetStand(parent: Instance): ()
	local center = Vector3.new(-Balance.Lobby.petStandOffset, 0, 0)

	local base = Instance.new("Part")
	base.Name = "PetStand"
	base.Shape = Enum.PartType.Cylinder
	base.Size = Vector3.new(1.2, 14, 14)
	base.CFrame = CFrame.new(center + Vector3.new(0, 0.6, 0)) * CFrame.Angles(0, 0, math.rad(90))
	base.Color = Palette.Lobby.border
	base.Material = Enum.Material.SmoothPlastic
	base.Anchored = true
	base.CanCollide = true
	base.Parent = parent

	local glow = Instance.new("Part")
	glow.Name = "PetStandGlow"
	glow.Shape = Enum.PartType.Cylinder
	glow.Size = Vector3.new(0.2, 10, 10)
	glow.CFrame = CFrame.new(center + Vector3.new(0, 1.3, 0)) * CFrame.Angles(0, 0, math.rad(90))
	glow.Color = Palette.Lobby.portal
	glow.Material = Enum.Material.Neon
	glow.Anchored = true
	glow.CanCollide = false
	glow.Parent = parent

	--[[
		Позицию для модели питомца клиент считает сам из того же
		Balance.Lobby.petStandOffset: одно число в конфиге, две стороны,
		никакой репликации ради статичной точки.
	]]
	addPrompt(base, "Pets", "Manage", "Pets")
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
	buildEggs(folder)
	buildShop(folder)
	buildPetStand(folder)

	local prompt = buildPortal(folder)

	-- Дистанцию и наличие персонажа проверяет сам ProximityPrompt на сервере,
	-- остальные проверки (свободный слот, повторный вход, кулдаун) — в CombatService.
	prompt.Triggered:Connect(function(player: Player)
		CombatService.BeginRun(player)
	end)

	lobbyFolder = folder
end

function LobbyService.Start(): ()
	print(
		`[LobbyService] Лобби построено: {Balance.Lobby.floorSize}x{Balance.Lobby.floorSize} стадов`
	)
end

function LobbyService.GetSpawnCFrame(): CFrame
	local spawn = spawnLocation
	if spawn then
		return spawn.CFrame
	end
	return CFrame.new(0, Balance.Lobby.floorThickness, 0)
end

function LobbyService.GetFolder(): Folder?
	return lobbyFolder
end

return LobbyService
