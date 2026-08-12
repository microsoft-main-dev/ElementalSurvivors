--!strict
--[[
	WheelPanel — колесо фортуны (раздел 4 ТЗ).

	Окно здесь НЕ показывает колесо. Колесо стоит в лобби настоящее, крутится
	по-настоящему, и прятать его за нарисованным поверх экрана — значит
	не показать ни того, ни другого. Поэтому окон два, и оба крошечные:

	1. «Крутить» — кнопка или сколько осталось ждать. Закрывается сразу после
	   нажатия, чтобы игрок смотрел на диск, а не на интерфейс.
	2. Приз — открывается, когда диск остановился, и называет выпавшее.

	ПРИЗ УЖЕ ВЫДАН к моменту показа. Сервер решает и начисляет его в тот же
	миг, когда игрок нажал кнопку, вместе со сдвигом отметки времени — иначе
	вылет посреди анимации съедал бы прокрутку. Кнопка во втором окне поэтому
	ничего не запрашивает: она подтверждает уже случившееся.

	Пауза между ответом сервера и показом приза равна длине звука прокрутки
	(Config/Sounds) — той же, по которой крутится диск. Разъедься они, окно
	назвало бы приз раньше, чем колесо встанет.

	Публичный API:
		WheelPanel.Build(parent, send) -> Panel
		panel.Open()
		panel.Close()
		panel.ShowResult(result)
		panel.SetReadyIn(seconds)
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Icons = require(Shared.Config.Icons)
local Palette = require(Shared.Config.Palette)
local Sounds = require(Shared.Config.Sounds)
local Types = require(Shared.Types)
local UiKit = require(script.Parent.UiKit)

export type Panel = {
	Open: () -> (),
	Close: () -> (),
	ShowResult: (result: Types.WheelResult) -> (),
	SetReadyIn: (seconds: number) -> (),
}

local WheelPanel = {}

function WheelPanel.Build(parent: Instance, send: (action: string, target: string?, extra: unknown) -> ()): Panel
	--[[
		Окно прокрутки. Маленькое намеренно: в нём одна кнопка, и растянутое
		на пол-экрана оно перекрыло бы само колесо, ради которого открыто.
	]]
	local spinWindow = UiKit.Window(parent, "WheelPanel", "Wheel of Fortune")
	spinWindow.panel.Size = UDim2.fromScale(0.52, 0.34)

	local status = UiKit.Label(spinWindow.content, "Status", "", 18, Palette.UI.subtext)
	status.Position = UDim2.fromScale(0, 0.08)
	status.Size = UDim2.new(1, 0, 0, 48)
	status.TextXAlignment = Enum.TextXAlignment.Center
	status.TextWrapped = true

	local spin = UiKit.Button(spinWindow.content, "Spin", "Spin")
	spin.AnchorPoint = Vector2.new(0.5, 1)
	spin.Position = UDim2.fromScale(0.5, 1)
	spin.Size = UDim2.new(0.6, 0, 0, UiKit.ButtonHeight + 6)

	--[[
		Окно приза. Отдельное, а не то же самое с подменённым текстом: первое
		закрывается в момент нажатия и девять секунд не существует вовсе,
		а второе появляется само, когда диск встал.
	]]
	local prizeWindow = UiKit.Window(parent, "WheelPrize", "You won")
	prizeWindow.panel.Size = UDim2.fromScale(0.52, 0.38)

	local icon = UiKit.Image(prizeWindow.content, "Icon", Icons.Currency.essence)
	if icon then
		icon.AnchorPoint = Vector2.new(0.5, 0)
		icon.Position = UDim2.fromScale(0.5, 0.04)
		icon.Size = UDim2.fromOffset(72, 72)
	end

	local prize = UiKit.Label(prizeWindow.content, "Prize", "", 34, Palette.UI.accent)
	prize.Font = Enum.Font.GothamBold
	prize.Position = UDim2.fromScale(0, 0.46)
	prize.Size = UDim2.new(1, 0, 0, 52)
	prize.TextXAlignment = Enum.TextXAlignment.Center

	local next_ = UiKit.Label(prizeWindow.content, "Next", "", 14, Palette.UI.subtext)
	next_.Position = UDim2.fromScale(0, 0.68)
	next_.Size = UDim2.new(1, 0, 0, 22)
	next_.TextXAlignment = Enum.TextXAlignment.Center

	local claim = UiKit.Button(prizeWindow.content, "Claim", "Claim")
	claim.AnchorPoint = Vector2.new(0.5, 1)
	claim.Position = UDim2.fromScale(0.5, 1)
	claim.Size = UDim2.new(0.6, 0, 0, UiKit.ButtonHeight + 6)

	local readyIn = 0
	local spinning = false

	local function render(): ()
		if spinning then
			status.Text = "The wheel is spinning..."
			UiKit.SetEnabled(spin, false)
			return
		end

		if readyIn > 0 then
			status.Text = `Next spin in {UiKit.FormatDuration(readyIn)}`
			UiKit.SetEnabled(spin, false)
			return
		end

		status.Text = "The wheel is ready. One spin per day."
		UiKit.SetEnabled(spin, true)
	end

	spin.Activated:Connect(function()
		if spinning or readyIn > 0 then
			return
		end

		spinning = true
		send("SpinWheel", nil, nil)
		--[[
			Окно уходит сразу, не дожидаясь ответа. Отказ сервера придёт
			всплывающим сообщением, а успех — вращением колеса: и то, и другое
			игрок увидит, стоя перед диском, а не перед окном.
		]]
		spinWindow.screen.Enabled = false
	end)

	claim.Activated:Connect(function()
		prizeWindow.screen.Enabled = false
	end)

	local panel: Panel = {
		Open = function()
			render()
			spinWindow.screen.Enabled = true
		end,

		Close = function()
			spinWindow.screen.Enabled = false
			prizeWindow.screen.Enabled = false
		end,

		SetReadyIn = function(seconds: number)
			readyIn = seconds
			if spinWindow.screen.Enabled then
				render()
			end
		end,

		ShowResult = function(result: Types.WheelResult)
			readyIn = result.nextSpinInSeconds

			--[[
				Ждём ровно столько, сколько крутится диск. Отсчёт идёт здесь,
				а не в контроллере декора: окно и диск подчиняются одному
				числу из Config/Sounds, но каждый живёт своей жизнью, и лишний
				канал между ними ничего бы не добавил.
			]]
			task.delay(Sounds.WheelSpinSeconds, function()
				spinning = false
				prize.Text = `+{UiKit.FormatAmount(result.essence)} Essence`
				next_.Text = `Next spin in {UiKit.FormatDuration(result.nextSpinInSeconds)}`
				prizeWindow.screen.Enabled = true
			end)
		end,
	}

	return panel
end

return WheelPanel
