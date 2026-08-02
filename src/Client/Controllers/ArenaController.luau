--!strict
--[[
	ArenaController — всё клиентское окружение боя.

	1. Декор арены. Строится здесь, а не на сервере, по seed из RunStarted:
	   RNG детерминирован, поэтому картинка получается «настоящей», но при этом
	   ни один из полусотни партов не реплицируется и не висит в чужих аренах.

	2. Палитра и туман. Lighting в Roblox один на весь сервер, поэтому «своя
	   палитра у каждой локации» (раздел 5.1 ТЗ) через сервер невозможна:
	   на одном сервере до восьми игроков на разных аренах. Зато изменения
	   Lighting, сделанные локальным скриптом, не реплицируются — значит
	   палитру каждый клиент ставит себе сам. Это и делается здесь.

	3. Кольцо автоатаки — единственная боевая обратная связь в M1.
]]

local Lighting = game:GetService("Lighting")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Balance = require(Shared.Config.Balance)
local Net = require(Shared.Net)
local Palette = require(Shared.Config.Palette)
local RNG = require(Shared.Util.RNG)

local PULSE_TIME = 0.28

local ArenaController = {}

local player = Players.LocalPlayer

local decorFolder: Folder? = nil
local pulsePart: Part? = nil
local pulseStartedAt = -1
local pulseRadius = 0

type LightingSnapshot = {
	fogColor: Color3,
	fogStart: number,
	fogEnd: number,
	ambient: Color3,
	outdoorAmbient: Color3,
}

local lobbySnapshot: LightingSnapshot? = nil

local function snapshotLighting(): LightingSnapshot
	return {
		fogColor = Lighting.FogColor,
		fogStart = Lighting.FogStart,
		fogEnd = Lighting.FogEnd,
		ambient = Lighting.Ambient,
		outdoorAmbient = Lighting.OutdoorAmbient,
	}
end

local function restoreLighting(snapshot: LightingSnapshot): ()
	Lighting.FogColor = snapshot.fogColor
	Lighting.FogStart = snapshot.fogStart
	Lighting.FogEnd = snapshot.fogEnd
	Lighting.Ambient = snapshot.ambient
	Lighting.OutdoorAmbient = snapshot.outdoorAmbient
end

local function applyArenaLighting(): ()
	Lighting.FogColor = Palette.Arena.fog
	Lighting.FogStart = Balance.Arena.fogStart
	Lighting.FogEnd = Balance.Arena.fogEnd
	Lighting.Ambient = Palette.Arena.floor
	Lighting.OutdoorAmbient = Palette.Arena.floor
end

--[[
	Декор из примитивов по seed (раздел 5 ТЗ).

	Декор намеренно ПЛОСКИЙ — плиты и полосы на полу высотой меньше стада.
	Сплошных колонн здесь не будет: враги считаются чистой математикой без поиска
	пути, поэтому непроходимая колонна остановила бы игрока, а толпа прошла бы
	сквозь неё насквозь и окружила его — это ловушка, а не укрытие.
	Плоский декор решает ту же задачу (арены по seed отличаются друг от друга)
	и при этом не обещает того, чего не делает.

	Если когда-нибудь понадобятся именно препятствия — это отдельная задача:
	они должны строиться на сервере и учитываться в движении врагов.
]]
local function buildDecor(origin: Vector3, seed: number): ()
	local folder = Instance.new("Folder")
	folder.Name = "ArenaDecor"
	folder.Parent = Workspace

	local rng = RNG.new(seed)
	local half = Balance.Arena.size * 0.5 - 12

	for index = 1, Balance.Arena.decorCount do
		local x = rng.NextNumber(-half, half)
		local z = rng.NextNumber(-half, half)

		local isAccent = rng.NextNumber(0, 1) > 0.82
		local length = rng.NextNumber(10, 34)
		local width = if isAccent then rng.NextNumber(1.2, 2.4) else rng.NextNumber(6, 20)
		local height = rng.NextNumber(0.2, 0.5)

		local part = Instance.new("Part")
		part.Name = `Decor{index}`
		part.Size = Vector3.new(length, height, width)
		part.CFrame = CFrame.new(origin + Vector3.new(x, height * 0.5, z)) * CFrame.Angles(0, rng.NextAngle(), 0)
		part.Color = if isAccent then Palette.Arena.decorAccent else Palette.Arena.decor
		part.Material = if isAccent then Enum.Material.Neon else Enum.Material.SmoothPlastic
		part.Anchored = true
		part.CanCollide = false
		part.CanQuery = false
		part.CanTouch = false
		part.CastShadow = false
		part.TopSurface = Enum.SurfaceType.Smooth
		part.BottomSurface = Enum.SurfaceType.Smooth
		part.Parent = folder
	end

	decorFolder = folder
end

local function getPulsePart(): Part
	local part = pulsePart
	if part then
		return part
	end

	local created = Instance.new("Part")
	created.Name = "AttackPulse"
	created.Shape = Enum.PartType.Cylinder
	created.Material = Enum.Material.Neon
	created.Color = Palette.UI.accent
	created.Anchored = true
	created.CanCollide = false
	created.CanQuery = false
	created.CanTouch = false
	created.CastShadow = false
	created.Transparency = 1
	created.Parent = Workspace
	pulsePart = created
	return created
end

local function onPulse(radius: number): ()
	pulseRadius = radius
	pulseStartedAt = os.clock()
end

local function updatePulse(): ()
	if pulseStartedAt < 0 then
		return
	end

	local part = getPulsePart()
	local elapsed = os.clock() - pulseStartedAt
	if elapsed >= PULSE_TIME then
		pulseStartedAt = -1
		part.Transparency = 1
		return
	end

	local character = player.Character
	local root = if character then character:FindFirstChild("HumanoidRootPart") :: BasePart? else nil
	if not root then
		return
	end

	local progress = elapsed / PULSE_TIME
	local diameter = pulseRadius * 2 * progress

	part.Size = Vector3.new(0.4, diameter, diameter)
	part.CFrame = CFrame.new(root.Position.X, 0.4, root.Position.Z) * CFrame.Angles(0, 0, math.rad(90))
	part.Transparency = 0.35 + 0.65 * progress
end

local function onRunStarted(slot: number, seed: number): ()
	if not lobbySnapshot then
		lobbySnapshot = snapshotLighting()
	end

	applyArenaLighting()
	buildDecor(Vector3.new(slot * Balance.Arena.spacing, 0, 0), seed)
end

local function onRunEnded(_reason: string): ()
	local folder = decorFolder
	if folder then
		folder:Destroy()
		decorFolder = nil
	end

	local snapshot = lobbySnapshot
	if snapshot then
		restoreLighting(snapshot)
	end

	pulseStartedAt = -1
	local part = pulsePart
	if part then
		part.Transparency = 1
	end
end

function ArenaController.Start(): ()
	Net.GetEvent(Net.Id.RunStarted).OnClientEvent:Connect(onRunStarted)
	Net.GetEvent(Net.Id.RunEnded).OnClientEvent:Connect(onRunEnded)
	Net.GetUnreliable(Net.Id.CombatPulse).OnClientEvent:Connect(onPulse)

	RunService.Heartbeat:Connect(updatePulse)
end

return ArenaController
