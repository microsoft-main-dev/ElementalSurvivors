--!strict
--[[
	DailyPanel — ежедневные квесты, колесо фортуны и стенд рекордсменов
	(раздел 4 ТЗ), M6.

	Три объекта в одном файле намеренно: у всех трёх одинаковая форма —
	список строк, приходящий с сервера, и одна кнопка. Три почти одинаковых
	файла разошлись бы при первой же правке вёрстки.

	Какой раздел открыт, задаёт вызывающий: у каждого объекта в лобби свой
	промпт, и игрок, подошедший к колесу, должен увидеть колесо.

	Публичный API:
		DailyPanel.Build(parent, send) -> Panel
		panel.Open(section)   -- "Quests" | "Wheel" | "Leaderboard"
		panel.Close()
		panel.Refresh(quests, leaderboard)
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Balance = require(Shared.Config.Balance)
local Palette = require(Shared.Config.Palette)
local Types = require(Shared.Types)
local UiKit = require(script.Parent.UiKit)

export type Panel = {
	Open: (section: string) -> (),
	Close: () -> (),
	Refresh: (quests: Types.QuestsView?, leaderboard: { Types.LeaderboardEntry }?) -> (),
	ShowSpin: (result: Types.WheelResult) -> (),
}

local DailyPanel = {}

local QUEST_TEXT: { [string]: string } = {
	Kills = "Defeat enemies",
	Runs = "Finish runs",
	Survive = "Survive seconds",
	StageClear = "Clear a story stage",
}

local function formatTime(seconds: number): string
	local total = math.max(math.floor(seconds), 0)
	if total >= 3600 then
		return `{total // 3600} h {(total % 3600) // 60} m`
	end
	return string.format("%d:%02d", total // 60, total % 60)
end

function DailyPanel.Build(parent: Instance, send: (action: string, target: string?, extra: unknown) -> ()): Panel
	local window = UiKit.Window(parent, "DailyPanel", "Daily")

	local list = UiKit.Scroll(window.content, "List")
	list.Size = UDim2.new(1, 0, 1, -UiKit.ButtonHeight - 8)

	local action = UiKit.Button(window.content, "Action", "Spin")
	action.AnchorPoint = Vector2.new(0.5, 1)
	action.Position = UDim2.fromScale(0.5, 1)
	action.Size = UDim2.new(0.6, 0, 0, UiKit.ButtonHeight)
	action.Visible = false
	action.Activated:Connect(function()
		send("SpinWheel", nil, nil)
	end)

	local section = "Quests"
	local questsView: Types.QuestsView? = nil
	local leaderboard: { Types.LeaderboardEntry } = {}

	-- Состояние колеса: сколько ждать и что выпало в прошлый раз.
	local wheelReadyIn = 0
	local lastPrizeIndex = 0
	local lastPrizeName = ""

	local function renderQuests(): ()
		local view = questsView
		window.title.Text = "Daily quests"
		action.Visible = false

		if not view or #view.quests == 0 then
			local empty = UiKit.Label(list, "Empty", "Quests are being prepared...", 16, Palette.UI.subtext)
			empty.Size = UDim2.new(1, -8, 0, 40)
			return
		end

		window.subtitle.Text = `Resets in {formatTime(view.resetsInSeconds)}`

		for order, quest in view.quests do
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

	--[[
		Колесо.

		Список призов показывается целиком и с шансами. Лутбокс, содержимое
		которого игрок не видит, — это не интрига, а непонятно за что выданное
		число: до этого игрок не знал даже, что вообще может выпасть.

		Проценты считаются из тех же весов Balance.Daily.wheelPrizes, по которым
		сервер и роллит, поэтому разойтись они не могут.
	]]
	local function renderWheel(): ()
		local prizes = Balance.Daily.wheelPrizes

		window.title.Text = "Wheel of fortune"
		action.Visible = true

		local ready = wheelReadyIn <= 0
		action.Text = if ready then "SPIN" else `Ready in {formatTime(wheelReadyIn)}`
		UiKit.SetEnabled(action, ready)

		window.subtitle.Text = if lastPrizeName ~= ""
			then `You won: {lastPrizeName}`
			else "One free spin every 24 hours. All prizes are Essence."

		local total = 0
		for _, prize in prizes do
			total += prize.weight
		end

		for order, prize in prizes do
			local chance = prize.weight / total * 100
			--[[
				Крупные призы подсвечены ярче: шкала от блёклого к яркому
				читается быстрее, чем сравнение шести чисел глазами.
			]]
			local accent = if order >= #prizes - 1
				then Palette.Element.Lightning
				elseif order >= #prizes - 3 then Palette.Element.Nature
				else Palette.UI.panel

			local row = UiKit.Row(list, order, accent)
			row.badge.Text = string.format("%.0f%%", chance)
			row.title.Text = prize.displayName
			row.subtitle.Text = string.format("Chance %.1f%%", chance)

			-- Выпавший приз остаётся отмеченным до закрытия панели:
			-- иначе результат прокрутки исчезает быстрее, чем его успевают
			-- прочитать, и колесо снова выглядит как случайное число.
			if order == lastPrizeIndex then
				row.frame.BackgroundTransparency = 0
				row.title.Text = `{prize.displayName}   <-- YOU WON`
			end
		end
	end

	local function renderLeaderboard(): ()
		window.title.Text = "Top endless runs"
		window.subtitle.Text = "Updated every minute"
		action.Visible = false

		if #leaderboard == 0 then
			local empty = UiKit.Label(list, "Empty", "No records yet. Be the first.", 16, Palette.UI.subtext)
			empty.Size = UDim2.new(1, -8, 0, 40)
			return
		end

		for order, entry in leaderboard do
			local row = UiKit.Row(list, order, if order <= 3 then Palette.Element.Lightning else Palette.UI.panel)
			row.badge.Text = tostring(entry.rank)
			row.title.Text = entry.name
			row.subtitle.Text = formatTime(entry.seconds)
		end
	end

	local function render(): ()
		UiKit.ClearList(list)

		if section == "Wheel" then
			renderWheel()
		elseif section == "Leaderboard" then
			renderLeaderboard()
		else
			renderQuests()
		end
	end

	local panel: Panel = {
		Open = function(which: string)
			section = which
			window.screen.Enabled = true
			render()
		end,

		Close = function()
			window.screen.Enabled = false
		end,

		Refresh = function(quests: Types.QuestsView?, top: { Types.LeaderboardEntry }?)
			if quests then
				questsView = quests
				wheelReadyIn = quests.wheelReadyInSeconds
			end
			if top then
				leaderboard = top
			end
			if window.screen.Enabled then
				render()
			end
		end,

		--[[
			Результат прокрутки. Приходит отдельным пакетом, а не в общем
			обновлении: выпавший приз надо отметить в списке, и знать, какой
			именно, панель может только отсюда.
		]]
		ShowSpin = function(result: Types.WheelResult)
			lastPrizeIndex = result.prizeIndex
			lastPrizeName = result.displayName
			wheelReadyIn = result.nextSpinInSeconds
			section = "Wheel"
			window.screen.Enabled = true
			render()
		end,
	}

	return panel
end

return DailyPanel
