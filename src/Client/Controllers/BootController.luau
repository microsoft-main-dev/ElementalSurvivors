--!strict
--[[
	BootController — экран загрузки с логотипом студии (раздел 2.2 ТЗ).

	Пока Branding.logoSquareAssetId == 0, вместо картинки рисуется текстовая
	заглушка тем же цветом и в той же композиции, что и логотип-выворотка.
	Как только логотип загружен в Roblox — правится одно число в Branding.luau.

	Верстка на UDim2.fromScale + UIAspectRatioConstraint: одинаково работает
	на телефоне и на десктопе, инсет статус-бара игнорируется намеренно
	(экран должен закрывать всё).
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Branding = require(Shared.Config.Branding)
local Palette = require(Shared.Config.Palette)

local HOLD_SECONDS = 1.6
local FADE_SECONDS = 0.4

local BootController = {}

local function buildLogo(parent: Instance): ()
	local holder = Instance.new("Frame")
	holder.Name = "Logo"
	holder.AnchorPoint = Vector2.new(0.5, 0.5)
	holder.Position = UDim2.fromScale(0.5, 0.5)
	holder.Size = UDim2.fromScale(0.36, 0.36)
	holder.BackgroundTransparency = 1
	holder.Parent = parent

	local ratio = Instance.new("UIAspectRatioConstraint")
	ratio.AspectRatio = 1
	ratio.Parent = holder

	if Branding.logoSquareAssetId > 0 then
		--[[
			Светлая плашка под логотипом.

			Логотип нарисован тёмно-зелёным и рассчитан на светлый фон, а экран
			загрузки почти чёрный: контраст тёмно-зелёного на нём около 2:1,
			то есть кольцо и слово «4pots» на голом фоне просто не читались бы.
			Плашка решает это без второго файла; если однажды появится вариант
			«выворотка» со светлыми штрихами, её нужно будет убрать.
		]]
		local plate = Instance.new("Frame")
		plate.Name = "Plate"
		plate.Size = UDim2.fromScale(1, 1)
		plate.BackgroundColor3 = Palette.Brand.white
		plate.BorderSizePixel = 0
		plate.Parent = holder

		local plateCorner = Instance.new("UICorner")
		plateCorner.CornerRadius = UDim.new(0.16, 0)
		plateCorner.Parent = plate

		local image = Instance.new("ImageLabel")
		image.Size = UDim2.fromScale(1, 1)
		image.BackgroundTransparency = 1
		image.ScaleType = Enum.ScaleType.Fit
		image.Image = `rbxassetid://{Branding.logoSquareAssetId}`
		image.Parent = plate
		return
	end

	-- Заглушка: тёмный квадрат со скруглением, белый контур, текст «4pots games».
	local card = Instance.new("Frame")
	card.Size = UDim2.fromScale(1, 1)
	card.BackgroundColor3 = Palette.Brand.dark
	card.BorderSizePixel = 0
	card.Parent = holder

	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0.16, 0)
	corner.Parent = card

	local stroke = Instance.new("UIStroke")
	stroke.Color = Palette.Brand.white
	stroke.Thickness = 3
	stroke.Parent = card

	local title = Instance.new("TextLabel")
	title.AnchorPoint = Vector2.new(0.5, 1)
	title.Position = UDim2.fromScale(0.5, 0.56)
	title.Size = UDim2.fromScale(0.8, 0.3)
	title.BackgroundTransparency = 1
	title.Font = Enum.Font.GothamBold
	title.Text = Branding.studioName
	title.TextColor3 = Palette.Brand.white
	title.TextScaled = true
	title.Parent = card

	local subtitle = Instance.new("TextLabel")
	subtitle.AnchorPoint = Vector2.new(0.5, 0)
	subtitle.Position = UDim2.fromScale(0.5, 0.58)
	subtitle.Size = UDim2.fromScale(0.8, 0.18)
	subtitle.BackgroundTransparency = 1
	subtitle.Font = Enum.Font.Gotham
	subtitle.Text = Branding.studioSuffix
	subtitle.TextColor3 = Palette.Brand.light
	subtitle.TextScaled = true
	subtitle.Parent = card
end

function BootController.Start(): ()
	local playerGui = Players.LocalPlayer:WaitForChild("PlayerGui")

	local screen = Instance.new("ScreenGui")
	screen.Name = "BootScreen"
	screen.IgnoreGuiInset = true
	screen.ResetOnSpawn = false
	screen.DisplayOrder = 1000
	screen.Parent = playerGui

	local backdrop = Instance.new("Frame")
	backdrop.Name = "Backdrop"
	backdrop.Size = UDim2.fromScale(1, 1)
	backdrop.BackgroundColor3 = Palette.UI.background
	backdrop.BorderSizePixel = 0
	backdrop.Parent = screen

	buildLogo(backdrop)

	local caption = Instance.new("TextLabel")
	caption.AnchorPoint = Vector2.new(0.5, 0)
	caption.Position = UDim2.fromScale(0.5, 0.74)
	caption.Size = UDim2.fromScale(0.8, 0.05)
	caption.BackgroundTransparency = 1
	caption.Font = Enum.Font.Gotham
	caption.Text = Branding.gameName
	caption.TextColor3 = Palette.UI.subtext
	caption.TextScaled = true
	caption.Parent = backdrop

	task.wait(HOLD_SECONDS)

	local info = TweenInfo.new(FADE_SECONDS, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
	TweenService:Create(backdrop, info, { BackgroundTransparency = 1 }):Play()
	for _, descendant in backdrop:GetDescendants() do
		if descendant:IsA("TextLabel") then
			TweenService:Create(descendant, info, { TextTransparency = 1 }):Play()
		elseif descendant:IsA("ImageLabel") then
			TweenService:Create(descendant, info, { ImageTransparency = 1 }):Play()
		elseif descendant:IsA("Frame") then
			TweenService:Create(descendant, info, { BackgroundTransparency = 1 }):Play()
		elseif descendant:IsA("UIStroke") then
			TweenService:Create(descendant, info, { Transparency = 1 }):Play()
		end
	end

	task.wait(FADE_SECONDS)
	screen:Destroy()
end

return BootController
