--!strict
--[[
	NotificationController — короткие всплывающие сообщения от сервера.

	Единственный потребитель Remote в M0: показывает текст, который прислал
	портал-заглушка. Дальше сюда же пойдут сообщения о наградах и ошибках.

	Позиционирование учитывает GuiService:GetGuiInset(), чтобы плашка не уезжала
	под вырез экрана на телефонах (раздел 2 ТЗ).
]]

local GuiService = game:GetService("GuiService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Net = require(Shared.Net)
local Palette = require(Shared.Config.Palette)

local VISIBLE_SECONDS = 2.5
local FADE_SECONDS = 0.25

local NotificationController = {}

local label: TextLabel? = nil
local hideToken = 0

local function build(): TextLabel
	local playerGui = Players.LocalPlayer:WaitForChild("PlayerGui")

	local screen = Instance.new("ScreenGui")
	screen.Name = "Notifications"
	screen.ResetOnSpawn = false
	screen.DisplayOrder = 500
	screen.Parent = playerGui

	local text = Instance.new("TextLabel")
	text.Name = "Toast"
	text.AnchorPoint = Vector2.new(0.5, 1)
	text.Position = UDim2.new(0.5, 0, 1, -24 - GuiService:GetGuiInset().Y)
	text.Size = UDim2.new(0.6, 0, 0, 48)
	text.BackgroundColor3 = Palette.UI.panel
	text.BackgroundTransparency = 1
	text.BorderSizePixel = 0
	text.Font = Enum.Font.Gotham
	text.Text = ""
	text.TextColor3 = Palette.UI.text
	text.TextTransparency = 1
	text.TextSize = 18
	text.TextWrapped = true
	text.Parent = screen

	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 8)
	corner.Parent = text

	local padding = Instance.new("UIPadding")
	padding.PaddingLeft = UDim.new(0, 12)
	padding.PaddingRight = UDim.new(0, 12)
	padding.Parent = text

	local sizeConstraint = Instance.new("UISizeConstraint")
	sizeConstraint.MinSize = Vector2.new(220, 44)
	sizeConstraint.MaxSize = Vector2.new(520, 96)
	sizeConstraint.Parent = text

	return text
end

local function show(message: string): ()
	local target = label
	if not target then
		return
	end

	hideToken += 1
	local token = hideToken

	target.Text = message
	local fadeIn = TweenInfo.new(FADE_SECONDS, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
	TweenService:Create(target, fadeIn, { BackgroundTransparency = 0.15, TextTransparency = 0 }):Play()

	task.delay(VISIBLE_SECONDS, function()
		if token ~= hideToken then
			return
		end
		TweenService:Create(target, fadeIn, { BackgroundTransparency = 1, TextTransparency = 1 }):Play()
	end)
end

function NotificationController.Start(): ()
	label = build()

	Net.GetEvent(Net.Id.Notify).OnClientEvent:Connect(function(message: unknown)
		if typeof(message) == "string" then
			show(message)
		end
	end)
end

return NotificationController
