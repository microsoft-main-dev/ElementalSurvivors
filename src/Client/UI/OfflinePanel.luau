--!strict
--[[
	OfflinePanel — окно «Питомцы принесли: …» при входе (раздел 6.1 ТЗ).

	Всё, что здесь показано, посчитал сервер. Кнопка отправляет одно слово
	«забрать» и не сообщает ни суммы, ни времени: сервер пересчитает сам,
	и показанное число ни на что не влияет.

	Окно появляется только тогда, когда есть что забирать: «вы заработали 0»
	на каждом перезаходе раздражает сильнее, чем отсутствующая копейка,
	поэтому порог живёт на сервере и сюда просто не приходит пустой отчёт.

	Публичный API:
		OfflinePanel.Build(parent, send) -> Panel
		panel.Show(report)
		panel.Close()
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Palette = require(Shared.Config.Palette)
local Types = require(Shared.Types)
local UiKit = require(script.Parent.UiKit)

export type Panel = {
	Show: (report: Types.OfflineReport) -> (),
	Close: () -> (),
}

local OfflinePanel = {}

function OfflinePanel.Build(parent: Instance, send: (action: string, target: string?, extra: unknown) -> ()): Panel
	local window = UiKit.Window(parent, "OfflinePanel", "Pet Expeditions")
	window.panel.Size = UDim2.fromScale(0.8, 0.5)

	local amount = UiKit.Label(window.content, "Amount", "", 40, Palette.UI.accent)
	amount.Font = Enum.Font.GothamBold
	amount.Position = UDim2.fromScale(0, 0.08)
	amount.Size = UDim2.new(1, 0, 0, 56)
	amount.TextXAlignment = Enum.TextXAlignment.Center

	local detail = UiKit.Label(window.content, "Detail", "", 16, Palette.UI.subtext)
	detail.Position = UDim2.fromScale(0, 0.42)
	detail.Size = UDim2.new(1, 0, 0, 26)
	detail.TextXAlignment = Enum.TextXAlignment.Center

	local hint =
		UiKit.Label(window.content, "Hint", "Stronger pets earn more and store it for longer.", 14, Palette.UI.subtext)
	hint.Position = UDim2.fromScale(0, 0.58)
	hint.Size = UDim2.new(1, 0, 0, 22)
	hint.TextXAlignment = Enum.TextXAlignment.Center

	local collect = UiKit.Button(window.content, "Collect", "Collect")
	collect.AnchorPoint = Vector2.new(0.5, 1)
	collect.Position = UDim2.fromScale(0.5, 1)
	collect.Size = UDim2.new(0.6, 0, 0, UiKit.ButtonHeight + 6)

	collect.Activated:Connect(function()
		--[[
			Кнопка гасится сразу, до ответа сервера: повторное нажатие
			ничего не удвоит (сервер сдвигает отметку в той же операции,
			что и выдаёт), но и слать второй запрос незачем.
		]]
		UiKit.SetEnabled(collect, false)
		send("ClaimOffline", nil, nil)
		window.screen.Enabled = false
	end)

	local panel: Panel = {
		Show = function(report: Types.OfflineReport)
			amount.Text = `+{UiKit.FormatAmount(report.essence)} Essence`
			detail.Text = string.format(
				"Collected over %s  •  %d/h  •  storage cap %d h",
				UiKit.FormatDuration(report.seconds),
				math.floor(report.ratePerHour),
				report.capHours
			)
			UiKit.SetEnabled(collect, true)
			window.screen.Enabled = true
		end,

		Close = function()
			window.screen.Enabled = false
		end,
	}

	return panel
end

return OfflinePanel
