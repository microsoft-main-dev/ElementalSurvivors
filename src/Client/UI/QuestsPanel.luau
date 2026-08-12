--!strict
--[[
	QuestsPanel — ежедневные квесты (раздел 4 ТЗ).

	Своё окно, а не раздел общего: к квестам подходят к доске объявлений,
	и открывается ровно то, к чему подошли. Раньше квесты, колесо и рекорды
	делили одну панель с переключателем разделов, и это обходило требование
	владельца «взаимодействовать с объектом» не выходя из окна.

	Кнопка «Claim» гасится по тем же данным, что показывают прогресс: это
	подсказка, а не проверка. Настоящая живёт в LobbyNetService и она же
	единственная, которой можно верить.

	Публичный API:
		QuestsPanel.Build(parent, send) -> Panel
		panel.Open() / panel.Close()
		panel.Refresh(view)
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Palette = require(Shared.Config.Palette)
local Types = require(Shared.Types)
local UiKit = require(script.Parent.UiKit)

export type Panel = {
	Open: () -> (),
	Close: () -> (),
	Refresh: (view: Types.QuestsView?) -> (),
}

local QuestsPanel = {}

-- Что именно делать, человеческими словами. Ключи — QuestView.kind.
local QUEST_TEXT: { [string]: string } = {
	Kills = "Defeat enemies",
	Runs = "Finish runs",
	Survive = "Survive seconds",
	StageClear = "Clear a story stage",
}

function QuestsPanel.Build(parent: Instance, send: (action: string, target: string?, extra: unknown) -> ()): Panel
	local window = UiKit.Window(parent, "QuestsPanel", "Daily quests")

	local list = UiKit.Scroll(window.content, "List")
	list.Size = UDim2.fromScale(1, 1)

	local view: Types.QuestsView? = nil

	local function render(): ()
		UiKit.ClearList(list)

		local quests = view
		if not quests or #quests.quests == 0 then
			window.subtitle.Text = ""
			local empty = UiKit.Label(list, "Empty", "Quests are being prepared...", 16, Palette.UI.subtext)
			empty.Size = UDim2.new(1, -8, 0, 40)
			return
		end

		window.subtitle.Text = `Resets in {UiKit.FormatDuration(quests.resetsInSeconds)}`

		for order, quest in quests.quests do
			local done = quest.progress >= quest.target
			local accent = if quest.claimed
				then Palette.UI.panel
				elseif done then Palette.Element.Nature
				else Palette.UI.accent

			local row = UiKit.Row(list, order, accent)
			row.badge.Text = if quest.claimed then "OK" else `{math.floor(quest.progress / quest.target * 100)}%`
			row.title.Text = QUEST_TEXT[quest.kind] or quest.kind
			row.subtitle.Text = `{quest.progress} / {quest.target}  ·  {UiKit.FormatAmount(quest.essence)} Essence`

			local claim = UiKit.Button(row.actions, "Claim", if quest.claimed then "Claimed" else "Claim")
			claim.LayoutOrder = 1
			claim.Size = UDim2.fromOffset(112, UiKit.ButtonHeight)
			UiKit.SetEnabled(claim, done and not quest.claimed)

			if done and not quest.claimed then
				claim.Activated:Connect(function()
					send("ClaimQuest", quest.id, nil)
				end)
			end
		end
	end

	local panel: Panel = {
		Open = function()
			window.screen.Enabled = true
			render()
		end,

		Close = function()
			window.screen.Enabled = false
		end,

		Refresh = function(next_: Types.QuestsView?)
			view = next_
			if window.screen.Enabled then
				render()
			end
		end,
	}

	return panel
end

return QuestsPanel
