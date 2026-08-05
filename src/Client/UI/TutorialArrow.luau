--!strict
--[[
	TutorialArrow — стрелка над объектом лобби (M7, раздел 4 ТЗ).

	Раздел 4 требует «провести по объектам»: подсказки текстом мало, новичок
	не знает, где в лобби стоит портал. Стрелка висит над самим объектом
	и покачивается — этого достаточно, чтобы её заметили, и на это не нужно
	ни одного ассета (правило 4: всё визуальное — примитивы и текст).

	Цель ищется по тому же атрибуту Panel на ProximityPrompt, по которому
	LobbyController решает, какое окно открыть. Своего списка объектов
	у обучения нет намеренно: два списка одного и того же однажды разъедутся,
	и стрелка станет показывать на переименованную деталь.

	BillboardGui живёт в PlayerGui и наводится через Adornee, а не кладётся
	в саму деталь: геометрия лобби серверная и общая для всех, а стрелка
	личная — её видит только тот, кого сейчас учат.

	Публичный API:
		TutorialArrow.Build(parent) -> Arrow
		Arrow.PointTo(panel)
		Arrow.Hide()
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local Palette = require(ReplicatedStorage:WaitForChild("Shared").Config.Palette)

local HEIGHT_STUDS = 7 -- насколько выше центра детали висит стрелка
local BOB_AMPLITUDE = 0.7
local BOB_SPEED = 2.2
local SIZE_STUDS = 5

local TutorialArrow = {}

export type Arrow = {
	PointTo: (panel: string) -> (),
	Hide: () -> (),
}

--[[
	Деталь, к которой привязан промпт с этим атрибутом. Кешировать результат
	нечего: объекты лобби строятся один раз при старте сервера, но реплицируются
	не мгновенно, и первый поиск может честно ничего не найти.
]]
local function findTarget(panel: string): BasePart?
	for _, descendant in Workspace:GetDescendants() do
		if descendant:IsA("ProximityPrompt") and descendant:GetAttribute("Panel") == panel then
			local parent = descendant.Parent
			if parent and parent:IsA("BasePart") then
				return parent
			end
		end
	end

	return nil
end

function TutorialArrow.Build(parent: Instance): Arrow
	local billboard = Instance.new("BillboardGui")
	billboard.Name = "TutorialArrow"
	-- Размер в стадах, а не в пикселях: стрелка над далёким порталом не должна
	-- занимать полэкрана, а над соседним яйцом — теряться.
	billboard.Size = UDim2.fromScale(SIZE_STUDS, SIZE_STUDS)
	billboard.StudsOffsetWorldSpace = Vector3.new(0, HEIGHT_STUDS, 0)
	billboard.AlwaysOnTop = true
	billboard.LightInfluence = 0
	billboard.MaxDistance = 500
	billboard.ResetOnSpawn = false
	billboard.Enabled = false
	billboard.Parent = parent

	local glyph = Instance.new("TextLabel")
	glyph.Name = "Glyph"
	glyph.BackgroundTransparency = 1
	glyph.Size = UDim2.fromScale(1, 1)
	glyph.Font = Enum.Font.GothamBold
	-- Текстовый треугольник вместо картинки: ассетов у проекта нет.
	glyph.Text = "▼"
	glyph.TextColor3 = Palette.UI.accent
	glyph.TextScaled = true
	glyph.TextStrokeColor3 = Palette.UI.background
	glyph.TextStrokeTransparency = 0.2
	glyph.Parent = billboard

	local bob = 0
	local connection: RBXScriptConnection? = nil

	local function stopBob(): ()
		local existing = connection
		if existing then
			existing:Disconnect()
			connection = nil
		end
	end

	local function PointTo(panel: string): ()
		local target = findTarget(panel)
		if not target then
			billboard.Enabled = false
			billboard.Adornee = nil
			stopBob()
			return
		end

		billboard.Adornee = target
		billboard.Enabled = true

		if connection then
			return
		end

		connection = RunService.Heartbeat:Connect(function(deltaTime: number)
			bob = (bob + deltaTime * BOB_SPEED) % (math.pi * 2)
			billboard.StudsOffsetWorldSpace = Vector3.new(0, HEIGHT_STUDS + math.sin(bob) * BOB_AMPLITUDE, 0)
		end)
	end

	local function Hide(): ()
		billboard.Enabled = false
		billboard.Adornee = nil
		stopBob()
	end

	return { PointTo = PointTo, Hide = Hide }
end

return TutorialArrow
