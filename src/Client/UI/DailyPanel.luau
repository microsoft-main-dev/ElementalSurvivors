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
local Icons = require(Shared.Config.Icons)
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

--[[
	Длительность анимации прокрутки, секунд. Подогнана под длину звука
	WheelSpin (Config/Sounds) — владелец слушал ассет и сообщил 9 секунд.
	Не Balance: это не баланс, а хронометраж под конкретный купленный ассет,
	поменяется вместе с ним, а не при перебалансировке.
]]
local WHEEL_SPIN_DURATION = 9
local WHEEL_SPIN_LOOPS = 4 -- сколько полных оборотов делает колесо, для вида

--[[
	Колесо рисуется спицами: круглый сектор в Roblox без картинки не нарисовать,
	а рисовать его нечем — ассетов у проекта нет (правило 4). Сектор набирается
	узкими прямоугольниками от центра, все одного цвета, поэтому их перекрытие
	у центра не видно. То, что всё-таки видно у самой оси, закрывает ступица.

	Шаг в четыре градуса: девяносто спиц на круг — это дёшево для одной панели
	и достаточно мелко, чтобы край сектора не выглядел ступенькой.
]]
local WHEEL_RADIUS = 128
local WHEEL_SPOKE_STEP = 4
local WHEEL_HUB_RADIUS = 46

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

	--[[
		Колесо. Углы секторов пропорциональны весам призов, а не равны между
		собой: колесо с одинаковыми секторами и разными шансами показывает
		игроку неправду. Тонкий сектор на сто тысяч Essence — это и есть
		честно показанный шанс, только нарисованный.
	]]
	local WHEEL_BOX = WHEEL_RADIUS * 2 + 40

	local wheelHolder = UiKit.Frame(window.content, "Wheel")
	wheelHolder.AnchorPoint = Vector2.new(0.5, 0)
	wheelHolder.Position = UDim2.fromScale(0.5, 0)
	wheelHolder.Size = UDim2.fromOffset(WHEEL_BOX, WHEEL_BOX)
	wheelHolder.Visible = false

	--[[
		Колесо собрано в пикселях: спицы — это повёрнутые прямоугольники, и
		доли экрана им не подходят. Поэтому целиком масштабируется готовое:
		на телефоне в альбомной ориентации содержимое окна около двухсот точек
		в высоту, а колесо — почти триста, и без этого оно просто не влезало.

		Считается от места, оставшегося под кнопкой прокрутки, и никогда
		не увеличивает колесо выше единицы.
	]]
	local wheelScale = Instance.new("UIScale")
	wheelScale.Parent = wheelHolder

	local function fitWheel(): ()
		local available = window.content.AbsoluteSize
		local height = available.Y - UiKit.ButtonHeight - 16
		local factor = math.min(available.X / WHEEL_BOX, height / WHEEL_BOX, 1)
		wheelScale.Scale = math.max(factor, 0.35)
	end

	window.content:GetPropertyChangedSignal("AbsoluteSize"):Connect(fitWheel)

	local disc = UiKit.Frame(wheelHolder, "Disc")
	disc.AnchorPoint = Vector2.new(0.5, 0.5)
	disc.Position = UDim2.fromScale(0.5, 0.5)
	disc.Size = UDim2.fromOffset(WHEEL_RADIUS * 2, WHEEL_RADIUS * 2)

	--[[
		Границы секторов в градусах, от указателя по часовой стрелке.
		Считаются один раз: веса живут в конфиге и в бою не меняются.
	]]
	local prizes = Balance.Daily.wheelPrizes
	local sectorStart: { number } = {}
	local sectorEnd: { number } = {}

	do
		local total = 0
		for _, prize in prizes do
			total += prize.weight
		end

		local cursor = 0
		for index, prize in prizes do
			sectorStart[index] = cursor / total * 360
			cursor += prize.weight
			sectorEnd[index] = cursor / total * 360
		end
	end

	--[[
		Спицы и подписи строятся один раз: перерисовка колеса — это поворот,
		а не пересборка интерфейса.

		ВСЁ ПОВОРАЧИВАЕМОЕ ЯКОРИТСЯ ЗА СЕРЕДИНУ. Roblox вращает элемент вокруг
		его центра, а не вокруг AnchorPoint: спица, прижатая низом к центру
		диска, крутилась вокруг собственной середины, и вместо круга получался
		комок, смещённый от ступицы. При AnchorPoint (0.5, 0.5) центр и якорь
		совпадают, и точка вращения перестаёт зависеть от того, как именно
		движок это трактует.
	]]
	for index, prize in prizes do
		local from = sectorStart[index]
		local to = sectorEnd[index]
		local color = Palette.Wheel[(index - 1) % #Palette.Wheel + 1]

		local angle = from
		while angle < to do
			local step = math.min(WHEEL_SPOKE_STEP, to - angle)
			-- Ширина по внешнему краю: у центра спицы перекрываются, и это
			-- незаметно — они одного цвета, а ось закрыта ступицей.
			local width = math.max(2 * WHEEL_RADIUS * math.tan(math.rad(step) / 2), 2) + 1

			-- Середина спицы — на половине радиуса по её же направлению.
			local middleAngle = angle + step / 2
			local radians = math.rad(middleAngle)
			local half = WHEEL_RADIUS / 2

			local spoke = UiKit.Frame(disc, `Spoke{index}_{math.floor(angle)}`, color)
			spoke.AnchorPoint = Vector2.new(0.5, 0.5)
			spoke.Position = UDim2.new(0.5, math.sin(radians) * half, 0.5, -math.cos(radians) * half)
			spoke.Size = UDim2.fromOffset(width, WHEEL_RADIUS)
			spoke.Rotation = middleAngle

			angle += step
		end

		--[[
			Подпись сектора: сумма приза, написанная ВДОЛЬ радиуса.

			Поперёк не годится: у самого крупного приза вес 2, то есть сектор
			шириной около семи градусов, и подпись поперёк него налезла бы
			на соседние. Вдоль радиуса длина надписи ложится в свободные
			восемьдесят точек между ступицей и краем, а поперёк остаётся
			только высота строки.
		]]
		local middle = (from + to) / 2
		local radians = math.rad(middle)
		local distance = (WHEEL_HUB_RADIUS + WHEEL_RADIUS) / 2

		local label = UiKit.Label(disc, `Prize{index}`, UiKit.FormatAmount(prize.essence), 14, Palette.UI.text)
		label.AnchorPoint = Vector2.new(0.5, 0.5)
		-- Ноль градусов — вверх, дальше по часовой стрелке: так же, как рисуются
		-- спицы, поэтому подпись всегда попадает в свой сектор.
		label.Position = UDim2.new(0.5, math.sin(radians) * distance, 0.5, -math.cos(radians) * distance)
		label.Size = UDim2.fromOffset(WHEEL_RADIUS - WHEEL_HUB_RADIUS - 8, 18)
		label.Rotation = middle + 90
		label.Font = Enum.Font.GothamBold
		label.TextXAlignment = Enum.TextXAlignment.Center
		label.TextStrokeColor3 = Palette.UI.background
		label.TextStrokeTransparency = 0.2
	end

	-- Ступица поверх осей: она же прячет перекрытие спиц у центра.
	local hub = UiKit.Frame(wheelHolder, "Hub", Palette.UI.background)
	hub.AnchorPoint = Vector2.new(0.5, 0.5)
	hub.Position = UDim2.fromScale(0.5, 0.5)
	hub.Size = UDim2.fromOffset(WHEEL_HUB_RADIUS * 2, WHEEL_HUB_RADIUS * 2)
	UiKit.Corners(hub, WHEEL_HUB_RADIUS)

	--[[
		В ступице либо картинка приза, либо слово «Essence». Всё, что раздаёт
		колесо, — это Essence, поэтому картинка одна на все секторы: подписывать
		каждый сектор ещё и значком значило бы повторить одно и то же
		восемь раз по кругу.
	]]
	local hubImage = UiKit.Image(hub, "Icon", Icons.Misc.WheelPrize)
	if hubImage then
		hubImage.AnchorPoint = Vector2.new(0.5, 0.5)
		hubImage.Position = UDim2.fromScale(0.5, 0.5)
		hubImage.Size = UDim2.fromScale(0.7, 0.7)
	else
		local hubLabel = UiKit.Label(hub, "Text", "Essence", 13, Palette.UI.subtext)
		hubLabel.Size = UDim2.fromScale(1, 1)
		hubLabel.TextXAlignment = Enum.TextXAlignment.Center
	end

	-- Указатель сверху, вне диска: он не должен вращаться вместе с ним.
	local pointerImage = UiKit.Image(wheelHolder, "Pointer", Icons.Ui.Pointer)
	if pointerImage then
		pointerImage.AnchorPoint = Vector2.new(0.5, 0)
		pointerImage.Position = UDim2.fromScale(0.5, 0)
		pointerImage.Size = UDim2.fromOffset(32, 36)
		pointerImage.ZIndex = 3
	else
		local pointer = UiKit.Label(wheelHolder, "Pointer", "▼", 30, Palette.UI.danger)
		pointer.AnchorPoint = Vector2.new(0.5, 0)
		pointer.Position = UDim2.fromScale(0.5, 0)
		pointer.Size = UDim2.fromOffset(40, 34)
		pointer.TextXAlignment = Enum.TextXAlignment.Center
		pointer.ZIndex = 3
	end

	local section = "Quests"
	local questsView: Types.QuestsView? = nil
	local leaderboard: { Types.LeaderboardEntry } = {}

	-- Состояние колеса: сколько ждать и что выпало в прошлый раз.
	local wheelReadyIn = 0
	-- Что выпало в прошлый раз. Индекс больше не нужен: выпавший сектор
	-- показывает само колесо, остановившееся под указателем.
	local lastPrizeName = ""
	-- Идёт прокрутка: lastPrizeIndex уже бегает по списку, но это ещё
	-- не окончательный результат — "YOU WON" до конца анимации не пишем.
	local spinning = false

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
		window.title.Text = "Wheel of fortune"
		action.Visible = true

		local ready = wheelReadyIn <= 0
		action.Text = if spinning then "..." elseif ready then "SPIN" else `Ready in {formatTime(wheelReadyIn)}`
		UiKit.SetEnabled(action, ready and not spinning)

		--[[
			Шансы больше не выписаны списком: их показывает сама ширина сектора.
			В подписи остаётся то, чего по картинке не видно, — правило одной
			бесплатной прокрутки и результат прошлой.
		]]
		window.subtitle.Text = if spinning
			then "Spinning..."
			elseif lastPrizeName ~= "" then `You won: {lastPrizeName}`
			else "One free spin every 24 hours. Sector width is the chance."
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

		-- Колесо занимает место списка целиком: это не строки, а одна картинка.
		local isWheel = section == "Wheel"
		wheelHolder.Visible = isWheel
		list.Visible = not isWheel

		if isWheel then
			-- Размер окна к моменту первого показа уже известен, а сигнал
			-- изменения с тех пор мог и не приходить.
			fitWheel()
		end

		if isWheel then
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

			Сервер уже решил приз в момент ответа — анимация ничего не решает,
			только скрывает мгновенный ответ за той же паузой, что и звук
			WheelSpin (он запускается в тот же момент, из SoundController,
			по тому же Remote). Подсветка обходит список несколько раз
			и замедляется к концу, приземляясь ровно на настоящий приз:
			шаг всегда попадает в цель по формуле, а не подгоняется на глаз.
		]]
		ShowSpin = function(result: Types.WheelResult)
			if spinning then
				return
			end

			wheelReadyIn = result.nextSpinInSeconds
			section = "Wheel"
			window.screen.Enabled = true
			spinning = true
			lastPrizeName = ""
			render()

			task.spawn(function()
				--[[
					Куда встать: середина выпавшего сектора должна оказаться
					под указателем наверху. Сектор нарисован по часовой стрелке
					от нуля, поэтому диск доворачивается на минус его середину.

					Приземление считается по формуле, а не подгоняется на глаз:
					сервер уже решил приз, и колесо обязано остановиться ровно
					на нём, иначе анимация начнёт врать про результат.
				]]
				local index = math.clamp(result.prizeIndex, 1, #prizes)
				local middle = (sectorStart[index] + sectorEnd[index]) / 2
				local target = WHEEL_SPIN_LOOPS * 360 - middle

				local startRotation = disc.Rotation % 360
				disc.Rotation = startRotation

				local elapsed = 0
				while elapsed < WHEEL_SPIN_DURATION do
					elapsed += task.wait()
					local t = math.min(elapsed / WHEEL_SPIN_DURATION, 1)
					-- Замедление к концу: ease-out четвёртой степени. Колесо,
					-- останавливающееся равномерно, читается как выключенное,
					-- а не как остановившееся.
					local eased = 1 - (1 - t) ^ 4
					disc.Rotation = startRotation + (target - startRotation) * eased
				end

				disc.Rotation = target % 360
				spinning = false
				lastPrizeName = result.displayName
				if window.screen.Enabled and section == "Wheel" then
					render()
				end
			end)
		end,
	}

	return panel
end

return DailyPanel
