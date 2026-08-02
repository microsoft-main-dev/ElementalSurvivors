--!strict
--[[
	LobbyService — лобби целиком строится кодом при старте сервера (раздел 4 ТЗ).
	Ручного строительства в Studio нет: всё, что видно в игре, лежит в git.

	В M0 здесь: атмосфера, пол с бортиками, невидимые стены, точка спавна в центре,
	табличка студии и заглушка портала. Логика слотов арен, выбора режима
	и телепорта появится в M1.

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
local Net = require(Shared.Net)
local Palette = require(Shared.Config.Palette)

local LOBBY_FOLDER_NAME = "Lobby"

local LobbyService = {}

local lobbyFolder: Folder? = nil
local spawnLocation: SpawnLocation? = nil
local notifyEvent: RemoteEvent? = nil

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
	Lighting.FogStart = 140
	Lighting.FogEnd = 420

	for _, child in Lighting:GetChildren() do
		if child:IsA("Sky") or child:IsA("Atmosphere") then
			child:Destroy()
		end
	end
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

	local prompt = buildPortal(folder)
	notifyEvent = Net.GetEvent(Net.Id.Notify)

	prompt.Triggered:Connect(function(player: Player)
		local event = notifyEvent
		if event then
			event:FireClient(player, "Arenas open in the next milestone.")
		end
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
