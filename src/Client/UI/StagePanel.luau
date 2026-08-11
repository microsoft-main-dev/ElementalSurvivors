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

	Кнопка "Boss Fight (test)" видна только в Studio (M7): текущий открытый
	уровень входит сразу с максимальным билдом и без фазы выживания — чтобы
	проверять баланс боссов, не пережидая забег заново на каждую правку.
	CombatService всё равно не пустит её мимо Studio, но показывать мёртвую
	кнопку живому игроку незачем.

	Публичный API:
		StagePanel.Build(parent, send) -> Panel
		panel.Open()
		panel.Close()
		panel.Refresh(unlocked)
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Balance = require(Shared.Config.Balance)
local Icons = require(Shared.Config.Icons)
local Palette = require(Shared.Config.Palette)
local Stages = require(Shared.Config.Stages)
local Types = require(Shared.Types)
local UiKit = require(script.Parent.UiKit)

export type Panel = {
	Open: () -> (),
	Close: () -> (),
	Refresh: (unlocked: number, tutorialPending: boolean) -> (),
}

-- Высота шапки локации. Ниже баннер перестаёт читаться, выше он съедает строку
-- уровня: на телефоне в списке помещается три-четыре строки, и это весь экран.
local LOCATION_HEIGHT = 72

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

	-- Studio-only тестовая кнопка — резервируем место под неё только там же.
	local isStudio = RunService:IsStudio()
	local listTop = UiKit.ButtonHeight + 36

	--[[
		По кнопке на локацию: у каждой свой босс, и добраться до второго
		по-настоящему — это полтора часа игры. Кнопка ведёт на первый уровень
		своей локации и сразу выводит босса.

		Собираются по списку локаций, а не выписаны руками: третья локация
		получит свою кнопку сама.
	]]
	if isStudio then
		local width = 1 / #Stages.Locations

		for index, location in Stages.Locations do
			local first = (index - 1) * Stages.Locations[1].levels + 1
			local button =
				UiKit.Button(window.content, `BossFight{index}`, `Boss: {location.displayName}`, Palette.UI.danger)
			button.Position = UDim2.new((index - 1) * width, 4, 0, listTop)
			button.Size = UDim2.new(width, -8, 0, UiKit.ButtonHeight)
			button.TextSize = 14
			button.Activated:Connect(function()
				send("DebugBossFight", nil, first)
			end)
		end

		listTop += UiKit.ButtonHeight + 8
	end

	local list = UiKit.Scroll(window.content, "Stages")
	list.Position = UDim2.fromOffset(0, listTop)
	list.Size = UDim2.new(1, 0, 1, -listTop)

	local unlockedStage = 1
	local tutorialPending = false

	--[[
		Пока обучающий уровень не пройден, он единственный доступный
		(M7, раздел 4 ТЗ). Список сюжетных уровней и бесконечный режим при
		этом не гасятся, а не показываются вовсе: погашенные строки на пятьсот
		уровней — это не «пока нельзя», а стена, за которой не видно кнопки,
		которую от игрока ждут.

		Отказывает всё равно сервер (CombatService): здесь только вид.
	]]
	local function renderTutorial(): ()
		window.subtitle.Text = "Tutorial — learn the basics, then the story opens up"

		local row = UiKit.Row(list, 1, Palette.UI.accent)
		row.badge.Text = "!"
		row.title.Text = "Tutorial stage"
		row.subtitle.Text = string.format(
			"%s  ·  weakened enemies  ·  weakened boss  ·  pays for your first egg",
			formatDuration(Balance.Tutorial.duration)
		)

		local play = UiKit.Button(row.actions, "Play", "Play")
		play.LayoutOrder = 1
		play.Size = UDim2.fromOffset(104, UiKit.ButtonHeight)
		play.Activated:Connect(function()
			send("EnterRun", "Tutorial", 0)
		end)
	end

	--[[
		Шапка локации перед её первым уровнем.

		Отдельной строкой, а не иконкой в метке: баннер широкий, а метка
		квадратная 44x44, и вписать туда полосу 512x224 можно только изуродовав
		её. Без ассета остаётся одна подпись — десять уровней двух локаций
		подряд иначе читаются как один сплошной список.
	]]
	local function renderLocationHeader(location: Types.LocationDef, order: number): ()
		local holder = UiKit.Frame(list, `Location{order}`, Palette.UI.background)
		holder.LayoutOrder = order
		holder.Size = UDim2.new(1, -8, 0, LOCATION_HEIGHT)
		holder.BackgroundTransparency = 0.3
		UiKit.Corners(holder, 8)

		local banner = UiKit.Image(holder, "Banner", Icons.Locations[location.key])
		if banner then
			-- Crop, а не Fit: полоса обязана занять строку целиком, иначе вокруг
			-- неё останутся поля и шапка перестанет быть шапкой.
			banner.ScaleType = Enum.ScaleType.Crop
			UiKit.Corners(banner, 8)
		end

		local title = UiKit.Label(holder, "Title", location.displayName, 18)
		title.Font = Enum.Font.GothamBold
		title.Position = UDim2.fromOffset(12, 8)
		title.Size = UDim2.new(1, -24, 0, 24)
		-- Обводка нужна только поверх баннера, но безвредна и без него.
		title.TextStrokeColor3 = Palette.UI.background
		title.TextStrokeTransparency = 0.1
	end

	local function render(): ()
		UiKit.ClearList(list)

		endless.Visible = not tutorialPending
		endlessHint.Visible = not tutorialPending

		if tutorialPending then
			renderTutorial()
			return
		end

		window.subtitle.Text =
			`Story progress: stage {math.min(unlockedStage, Stages.TotalLevels)} of {Stages.TotalLevels}`

		--[[
			Порядок строк больше не равен номеру уровня: между локациями
			вклинивается шапка. Отдельный счётчик обязателен — при LayoutOrder
			по номеру уровня шапка второй локации встала бы в один слот
			с уровнем и одна из них ушла бы под другую.
		]]
		local order = 0
		local currentLocation = ""

		for index = 1, Stages.TotalLevels do
			local stage = Stages.Get(index)
			if not stage then
				continue
			end

			if stage.location.key ~= currentLocation then
				currentLocation = stage.location.key
				order += 1
				renderLocationHeader(stage.location, order)
			end

			local locked = index > unlockedStage
			local cleared = index < unlockedStage

			local accent = if locked
				then Palette.UI.panel
				elseif cleared then Palette.Element.Nature
				else Palette.UI.accent

			order += 1
			local row = UiKit.Row(list, order, accent)
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

		Refresh = function(unlocked: number, pending: boolean)
			unlockedStage = math.max(unlocked, 1)
			tutorialPending = pending
			if window.screen.Enabled then
				render()
			end
		end,
	}

	return panel
end

return StagePanel
