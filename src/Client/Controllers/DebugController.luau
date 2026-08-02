--!strict
--[[
	DebugController — отладочный оверлей: FPS, число отрисованных врагов, время забега.

	Существует ради критерия приёмки M1 («300 врагов держат 30+ FPS»): без цифр
	на экране проверить это невозможно. Включается флагом Balance.Debug.showStats
	и удаляется в M7 вместе с остальной отладкой.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Balance = require(Shared.Config.Balance)
local EnemyRenderController = require(script.Parent.EnemyRenderController)
local Net = require(Shared.Net)
local Palette = require(Shared.Config.Palette)

local SAMPLE_WINDOW = 0.5

local DebugController = {}

local label: TextLabel? = nil
local frames = 0
local elapsed = 0
local fps = 0
local runStartedAt = -1

local function onHeartbeat(deltaTime: number): ()
	frames += 1
	elapsed += deltaTime
	if elapsed < SAMPLE_WINDOW then
		return
	end

	fps = frames / elapsed
	frames = 0
	elapsed = 0

	local text = label
	if not text then
		return
	end

	local enemies = EnemyRenderController.GetActiveCount()
	local runTime = if runStartedAt >= 0 then os.clock() - runStartedAt else 0

	text.Text = string.format(
		"FPS %d   |   enemies %d   |   %02d:%02d",
		math.floor(fps + 0.5),
		enemies,
		math.floor(runTime / 60),
		math.floor(runTime % 60)
	)
	text.TextColor3 = if fps >= 30 then Palette.UI.subtext else Palette.UI.danger
end

function DebugController.Start(): ()
	if not Balance.Debug.showStats then
		return
	end

	local playerGui = Players.LocalPlayer:WaitForChild("PlayerGui")

	local screen = Instance.new("ScreenGui")
	screen.Name = "DebugStats"
	screen.ResetOnSpawn = false
	screen.DisplayOrder = 100
	screen.Parent = playerGui

	local text = Instance.new("TextLabel")
	text.Name = "Stats"
	text.AnchorPoint = Vector2.new(0, 0)
	text.Position = UDim2.fromOffset(12, 12)
	text.Size = UDim2.fromOffset(320, 24)
	text.BackgroundColor3 = Palette.UI.panel
	text.BackgroundTransparency = 0.35
	text.BorderSizePixel = 0
	text.Font = Enum.Font.Code
	text.Text = ""
	text.TextColor3 = Palette.UI.subtext
	text.TextSize = 15
	text.TextXAlignment = Enum.TextXAlignment.Left
	text.Parent = screen

	local padding = Instance.new("UIPadding")
	padding.PaddingLeft = UDim.new(0, 8)
	padding.Parent = text

	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 6)
	corner.Parent = text

	label = text

	Net.GetEvent(Net.Id.RunStarted).OnClientEvent:Connect(function()
		runStartedAt = os.clock()
	end)
	Net.GetEvent(Net.Id.RunEnded).OnClientEvent:Connect(function()
		runStartedAt = -1
	end)

	RunService.Heartbeat:Connect(onHeartbeat)
end

return DebugController
