--!strict
--[[
	StagePanel — выбор режима и уровня у портала (раздел 4 ТЗ), M6.

	Сюжетные уровни проходятся строго последовательно, поэтому список
	показывает пройденные, текущий и заблокированные — видеть, что впереди,
	важнее, чем прятать это.

	Список уровней собирается тем же Stages.Get, которым сервер собирает
	настоящий уровень: числа сложности и награды на карточке — это ровно то,
	что будет в бою, а не отдельная витрина, которая однажды разойдётся.

	Бесконечный режим доступен сразу (раздел 4 ТЗ), но подписан как невыгодный
	на низких уровнях. Это мягкое направление, а не блокировка.

	Публичный API:
		StagePanel.Build(parent, send) -> Panel
		panel.Open()
		panel.Close()
		panel.Refresh(unlocked)
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Palette = require(Shared.Config.Palette)
local Stages = require(Shared.Config.Stages)
local UiKit = require(script.Parent.UiKit)

export type Panel = {
	Open: () -> (),
	Close: () -> (),
	Refresh: (unlocked: number) -> (),
}

local StagePanel = {}

local function formatDuration(seconds: number): string
	local total = math.floor(seconds)
	return string.format("%d:%02d", total // 60, total % 60)
end

function StagePanel.Build(parent: Instance, send: (action: string, target: string?, extra: unknown) -> ()): Panel
	local window = UiKit.Window(parent, "StagePanel", "Choose your run")

	local endless = UiKit.Button(window.content, "Endless", "Endless mode", Palette.Element.Dark)
	endless.Size = UDim2.new(1, -8, 0, UiKit.ButtonHeight + 8)
	endless.Activated:Connect(function()
		send("EnterRun", "Endless", 0)
	end)

	local endlessHint = UiKit.Label(
		window.content,
		"EndlessHint",
		"No stages, no boss — survive as long as you can. Less rewarding until your build is strong.",
		12,
		Palette.UI.subtext
	)
	endlessHint.Position = UDim2.fromOffset(4, UiKit.ButtonHeight + 12)
	endlessHint.Size = UDim2.new(1, -8, 0, 18)

	local list = UiKit.Scroll(window.content, "Stages")
	list.Position = UDim2.fromOffset(0, UiKit.ButtonHeight + 36)
	list.Size = UDim2.new(1, 0, 1, -UiKit.ButtonHeight - 36)

	local unlockedStage = 1

	local function render(): ()
		UiKit.ClearList(list)

		window.subtitle.Text =
			`Story progress: stage {math.min(unlockedStage, Stages.TotalLevels)} of {Stages.TotalLevels}`

		for index = 1, Stages.TotalLevels do
			local stage = Stages.Get(index)
			if not stage then
				continue
			end

			local locked = index > unlockedStage
			local cleared = index < unlockedStage

			local accent = if locked
				then Palette.UI.panel
				elseif cleared then Palette.Element.Nature
				else Palette.UI.accent

			local row = UiKit.Row(list, index, accent)
			row.badge.Text = tostring(index)
			row.title.Text = `{stage.location.displayName} {stage.indexInLocation}`

			local final = if stage.isLocationFinal then "  ·  guaranteed item" else ""
			row.subtitle.Text = string.format(
				"%s  ·  enemies x%.2f  ·  %s Essence%s",
				formatDuration(stage.duration),
				stage.enemyHealthMult,
				UiKit.FormatAmount(stage.essence),
				final
			)

			local play = UiKit.Button(row.actions, "Play", if cleared then "Replay" else "Play")
			play.LayoutOrder = 1
			play.Size = UDim2.fromOffset(104, UiKit.ButtonHeight)
			UiKit.SetEnabled(play, not locked)

			if locked then
				play.Text = "Locked"
			else
				play.Activated:Connect(function()
					send("EnterRun", "Story", index)
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

		Refresh = function(unlocked: number)
			unlockedStage = math.max(unlocked, 1)
			if window.screen.Enabled then
				render()
			end
		end,
	}

	return panel
end

return StagePanel
