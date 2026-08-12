--!strict
--[[
	LeaderboardPanel — стенд рекордсменов (раздел 4 ТЗ).

	Своё окно, а не раздел общего: к рекордам подходят к подиуму, и открывается
	ровно то, к чему подошли.

	Призовую тройку игрок видит и не открывая окна — она написана на самих
	тумбах (LobbyDecorController). Окно нужно тем, кто хочет посмотреть весь
	список целиком.

	Время показывается в минутах и секундах, а не через UiKit.FormatDuration:
	забег длится минуты, и «12 m» вместо «12:47» съедает ровно то, чем один
	рекорд отличается от другого.

	Публичный API:
		LeaderboardPanel.Build(parent) -> Panel
		panel.Open() / panel.Close()
		panel.Refresh(entries)
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Palette = require(Shared.Config.Palette)
local Types = require(Shared.Types)
local UiKit = require(script.Parent.UiKit)

export type Panel = {
	Open: () -> (),
	Close: () -> (),
	Refresh: (entries: { Types.LeaderboardEntry }) -> (),
}

local LeaderboardPanel = {}

local function formatRun(seconds: number): string
	local total = math.max(math.floor(seconds), 0)
	return string.format("%d:%02d", total // 60, total % 60)
end

function LeaderboardPanel.Build(parent: Instance): Panel
	local window = UiKit.Window(parent, "LeaderboardPanel", "Top endless runs")
	window.subtitle.Text = "Updated every minute"

	local list = UiKit.Scroll(window.content, "List")
	list.Size = UDim2.fromScale(1, 1)

	local entries: { Types.LeaderboardEntry } = {}

	local function render(): ()
		UiKit.ClearList(list)

		if #entries == 0 then
			local empty = UiKit.Label(list, "Empty", "No records yet. Be the first.", 16, Palette.UI.subtext)
			empty.Size = UDim2.new(1, -8, 0, 40)
			return
		end

		for order, entry in entries do
			-- Первая тройка выделена тем же, чем она выделена на подиуме:
			-- призовые места должны читаться одинаково в обоих местах.
			local row = UiKit.Row(list, order, if order <= 3 then Palette.Element.Lightning else Palette.UI.panel)
			row.badge.Text = tostring(entry.rank)
			row.title.Text = entry.name
			row.subtitle.Text = formatRun(entry.seconds)
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

		Refresh = function(top: { Types.LeaderboardEntry })
			entries = top
			if window.screen.Enabled then
				render()
			end
		end,
	}

	return panel
end

return LeaderboardPanel
