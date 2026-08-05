--!strict
--[[
	TutorialController — сценарий обучения новичка (M7, раздел 4 ТЗ).

	Сервер (TutorialService) владеет флагами, правом играть режимы и наградой;
	сюда приходит только TutorialView — «обучающий уровень ещё не выигран»
	и «вторая половина не пройдена». Всё остальное контроллер видит сам:
	какую панель открыл игрок, купил ли яйцо, вложил ли очко, надел ли предмет,
	сдвинулся ли персонаж, встал ли бой на паузу левел-апа.

	Ни одного нового сетевого потока ради текста на экране не заводится:
	каждый шаг закрывается тем срезом, который сервер и так шлёт.

	Порядок жёсткий и определён Config/Tutorial:

		Intro    — лобби до боя (питомец, дорога к порталу);
		RunHints — подсказки в самом бою;
		Outro    — лобби после победы (яйцо, питомец, талант, предмет).

	Обе половины лобби прерываются входом в бой и начинаются заново: номера
	шага в профиле нет, и это дешевле, чем поддерживать его при каждой правке
	сценария.

	Конец второй половины — единственное, что уходит на сервер (TutorialDone).
	Соврать этим можно только себе: за обучение не начисляется ничего, и всё,
	что даёт подделка, — пропущенные объяснения.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local LobbyController = require(script.Parent.LobbyController)
local Net = require(Shared.Net)
local Tutorial = require(Shared.Config.Tutorial)
local TutorialArrow = require(script.Parent.Parent.UI.TutorialArrow)
local TutorialOverlay = require(script.Parent.Parent.UI.TutorialOverlay)
local Types = require(Shared.Types)

-- Насколько надо отойти, чтобы подсказка про движение считалась понятой.
local MOVE_DISTANCE = 8

local POLL_INTERVAL = 0.1

-- Сколько подсказка висит в любом случае, даже если её условие уже выполнено.
local MIN_SHOW_SECONDS = 2.5

--[[
	Пауза перед половиной обучения в лобби. Нужна не ради экрана результатов
	(он выше подсказки и честно закрывает её, пока игрок его не закроет),
	а ради возвращения персонажа: шаг, начатый в момент телепорта, показывал бы
	стрелкой на объект, которого игрок ещё не видит.
]]
local LOBBY_DELAY = 1.5

-- Через сколько после боя спросить состояние обучения самому, если ответ
-- на Refresh от LobbyController так и не пришёл.
local VIEW_FALLBACK_DELAY = 3

local TutorialController = {}

local player = Players.LocalPlayer

local overlay: TutorialOverlay.Overlay? = nil
local arrow: TutorialArrow.Arrow? = nil

-- Что осталось пройти. Приходит с сервера, гасится по мере прохождения.
local needsRun = false
local needsLobbyTour = false
local hasView = false

local inRun = false
local paused = false
local bossOut = false
local gainedXp = false
local runTime = 0

--[[
	Признаки закрытия шагов лобби. Каждый ставится обработчиком того среза,
	который сервер шлёт и без обучения: своих запросов контроллер не делает.
]]
local openedPanel: string? = nil
local boughtEgg = false
local nextPressed = false
local talentPoints = -1 -- -1 означает «дерево ещё не приходило»
local talentSpent = false

--[[
	Экипировка считается версиями, а не проверкой «надето хоть что-то»:
	у игрока, который проходит обучение не с нуля (сброшенный флаг, старый
	профиль), слоты уже заняты, и такой шаг закрылся бы сам, ничего
	не объяснив. Версия растёт при каждом изменении набора надетого,
	а шаг ждёт изменения, случившегося ПОСЛЕ его начала.
]]
local equipSignature = ""
local equipVersion = 0
local equipBaseline = 0

local hintsRunning = false
local stepsRunning = false

--[[
	После забега состояние обучения устарело: победа ставит флаг на сервере,
	а RunEnded приходит раньше, чем срез с этим флагом. Запустить половину
	лобби по устаревшему виду — значит показать выигравшему новичку первую
	половину заново и увести его в уже пройденный уровень.

	Поэтому после боя ждём пуш и только по нему решаем, какая половина идёт.
]]
local viewStale = false

local function show(text: string, showNext: boolean): ()
	local panel = overlay
	if panel then
		panel.Show(text, showNext)
	end
end

local function hide(): ()
	local panel = overlay
	if panel then
		panel.Hide()
	end
end

local function pointArrow(panel: string): ()
	local pointer = arrow
	if not pointer then
		return
	end

	if panel == "" then
		pointer.Hide()
	else
		pointer.PointTo(panel)
	end
end

local function hideArrow(): ()
	local pointer = arrow
	if pointer then
		pointer.Hide()
	end
end

--[[
	Отпечаток надетого. Ключи сортируются: порядок обхода таблицы в Lua
	не определён, и без сортировки один и тот же набор давал бы разные строки,
	то есть «изменение» на ровном месте.
]]
local function equipmentSignature(equipped: { [string]: string }): string
	local slots: { string } = {}
	for slot in equipped do
		table.insert(slots, slot)
	end
	table.sort(slots)

	local parts: { string } = {}
	for _, slot in slots do
		table.insert(parts, `{slot}={equipped[slot]}`)
	end

	return table.concat(parts, ",")
end

local function rootPosition(): Vector3?
	local character = player.Character
	if not character then
		return nil
	end
	local root = character:FindFirstChild("HumanoidRootPart") :: BasePart?
	return if root then root.Position else nil
end

--[[
	Ждёт условия, но не дольше отпущенного времени. Потолок есть у каждой
	подсказки боя намеренно: игрок, не понявший её, не должен читать одно и то же
	весь забег — подсказка уходит сама, а забег продолжается.
]]
local function waitUntil(predicate: () -> boolean, timeout: number): ()
	local deadline = os.clock() + timeout
	while os.clock() < deadline do
		if predicate() then
			return
		end
		task.wait(POLL_INTERVAL)
	end
end

local function hintSatisfied(hint: Types.TutorialRunHint, start: Vector3?): () -> boolean
	return function(): boolean
		-- Забег кончился — досматривать подсказку некому.
		if not inRun then
			return true
		end

		if hint.trigger == "Move" then
			local now = rootPosition()
			return start ~= nil and now ~= nil and (now - start).Magnitude >= MOVE_DISTANCE
		elseif hint.trigger == "Crystal" then
			return gainedXp
		elseif hint.trigger == "LevelUp" then
			-- Карточка выбрана (или сервер снял паузу по таймауту).
			return not paused
		end

		-- Timer и Boss: живут ровно своё время.
		return false
	end
end

--[[
	Подсказка, которой нужно дождаться своего события: про карточку — паузы
	левел-апа, про босса — его выхода. Показать их заранее значит объяснять
	то, чего на экране нет, а после — то, что игрок уже сделал наугад.
]]
local function waitForTrigger(hint: Types.TutorialRunHint): ()
	-- Подсказка, привязанная к моменту уровня, ждёт этот момент независимо
	-- от того, как быстро игрок прошёл предыдущие.
	while inRun and runTime < hint.waitSeconds do
		task.wait(POLL_INTERVAL)
	end

	if hint.trigger == "LevelUp" then
		while inRun and not paused do
			task.wait(POLL_INTERVAL)
		end
	elseif hint.trigger == "Boss" then
		while inRun and not bossOut do
			task.wait(POLL_INTERVAL)
		end
	end
end

--[[
	Подсказки боя. Идут одна за другой: следующая начинается там, где кончилась
	предыдущая, поэтому двух сразу на экране не бывает.
]]
local function runHints(): ()
	for _, hint in Tutorial.RunHints do
		if not inRun then
			break
		end

		waitForTrigger(hint)
		if not inRun then
			break
		end

		--[[
			Минимум времени на прочтение. Без него подсказка про кристаллы
			мигала бы на одну десятую секунды: к третьему шагу игрок обычно
			уже подобрал первый кристалл, и условие снятия выполнено раньше,
			чем подсказка появилась. Условие проверяется от позиции на момент
			показа, поэтому эта пауза не мешает шагу про движение.
		]]
		local satisfied = hintSatisfied(hint, rootPosition())
		show(hint.text, false)
		task.wait(MIN_SHOW_SECONDS)
		if inRun then
			waitUntil(satisfied, math.max(hint.holdSeconds - MIN_SHOW_SECONDS, 0))
		end
		hide()
	end

	hide()
	hintsRunning = false
end

-- Выполнено ли условие шага лобби. Все признаки уже собраны обработчиками —
-- здесь только выбор нужного.
local function stepDone(step: Types.TutorialStep): boolean
	local advance = step.advance

	if advance == "Next" then
		return nextPressed
	elseif advance == "OpenPanel" then
		return openedPanel == step.panel
	elseif advance == "EnterRun" then
		return inRun
	elseif advance == "BuyEgg" then
		return boughtEgg
	elseif advance == "SpendTalent" then
		--[[
			Тратить нечего — шаг пропускается. Такое бывает у профиля
			на максимальном уровне: очка за обучающий уровень ему не дали,
			и требовать вложить его значило бы навсегда подвесить обучение.
		]]
		return talentSpent or talentPoints == 0
	elseif advance == "EquipItem" then
		return equipVersion > equipBaseline
	end

	return true
end

--[[
	Половина обучения в лобби. Прерывается входом в бой: шаг про вход в бой
	этим и заканчивается, а остальные при этом остаются непройденными
	и начнутся заново.
]]
local function runSteps(steps: { Types.TutorialStep }, isFinal: boolean): ()
	task.wait(LOBBY_DELAY)

	local completed = true

	for _, step in steps do
		if inRun and step.advance ~= "EnterRun" then
			completed = false
			break
		end

		openedPanel = nil
		boughtEgg = false
		nextPressed = false
		talentSpent = false
		equipBaseline = equipVersion

		--[[
			Фокус лобби ставится по шагу: пока он идёт, открыть можно только
			ту панель, которую от игрока ждут. Шаг без панели (объяснение
			с кнопкой) лобби не ограничивает.
		]]
		LobbyController.SetTutorialFocus(if step.panel ~= "" then step.panel else nil)
		pointArrow(step.arrow)
		show(step.text, step.advance == "Next")

		while not stepDone(step) do
			task.wait(POLL_INTERVAL)
			if inRun and step.advance ~= "EnterRun" then
				completed = false
				break
			end
		end
	end

	LobbyController.SetTutorialFocus(nil)
	hideArrow()
	hide()
	stepsRunning = false

	--[[
		Флаг ставится только за пройденную до конца ВТОРУЮ половину: первая
		заканчивается входом в бой, и обучение после неё ещё не закончено.
		Прерванная половина не засчитывается вовсе — при следующем входе она
		начнётся сначала.
	]]
	if isFinal and completed then
		needsLobbyTour = false
		Net.GetEvent(Net.Id.LobbyRequest):FireServer("TutorialDone", nil, nil)
	end
end

local function startStepsIfNeeded(): ()
	if stepsRunning or inRun or viewStale or not needsLobbyTour then
		return
	end

	--[[
		Половина выбирается по одному признаку — выигран ли обучающий уровень.
		Второго счётчика для этого не нужно: он и есть флаг профиля.
	]]
	local isFinal = not needsRun
	local steps = if isFinal then Tutorial.Outro else Tutorial.Intro
	if #steps == 0 then
		return
	end

	stepsRunning = true
	task.spawn(runSteps, steps, isFinal)
end

--[[
	Пуш приходит и при входе, и после каждого возвращения из боя (Refresh).

	Первый задаёт состояние целиком: иначе «ничего не нужно» от сервера было бы
	неотличимо от ещё не полученного вида. Дальнейшие только гасят — обучение,
	уже отправившее TutorialDone, не должно начаться заново от пуша, который
	сервер собрал до записи флага.
]]
local function onView(view: Types.TutorialView): ()
	viewStale = false

	if hasView then
		needsRun = needsRun and view.needsRun
		needsLobbyTour = needsLobbyTour and view.needsLobbyTour
	else
		hasView = true
		needsRun = view.needsRun
		needsLobbyTour = view.needsLobbyTour
	end

	startStepsIfNeeded()
end

local function onRunStarted(_slot: number, _seed: number, _magnet: number, mode: Types.RunMode): ()
	inRun = true
	paused = false
	bossOut = false
	gainedXp = false
	runTime = 0

	-- Подсказки боя — только в обучающем забеге. В обычном они были бы
	-- объяснением того, что игрок уже прошёл.
	if mode == "Tutorial" and not hintsRunning then
		hintsRunning = true
		task.spawn(runHints)
	end
end

local function onRunEnded(): ()
	inRun = false
	paused = false
	bossOut = false
	viewStale = true
	hide()

	--[[
		Половину лобби запустит пуш: LobbyController шлёт Refresh на этом же
		событии, сервер отвечает срезом обучения, и по нему уже видно, победил
		игрок или нет.

		Своя запоздалая попытка — страховка ровно на один случай: ответ не
		дошёл. Тогда обучение спросит само, а не встанет молча.
	]]
	task.delay(VIEW_FALLBACK_DELAY, function()
		if viewStale and not inRun then
			Net.GetEvent(Net.Id.LobbyRequest):FireServer("Refresh", nil, nil)
		end
	end)
end

function TutorialController.Start(): ()
	local playerGui = player:WaitForChild("PlayerGui")

	local built = TutorialOverlay.Build(playerGui)
	built.SetNextHandler(function()
		nextPressed = true
	end)
	overlay = built
	arrow = TutorialArrow.Build(playerGui)

	LobbyController.SetPanelListener(function(name: string)
		openedPanel = name
	end)

	Net.GetEvent(Net.Id.TutorialView).OnClientEvent:Connect(onView)
	Net.GetEvent(Net.Id.RunStarted).OnClientEvent:Connect(onRunStarted)
	Net.GetEvent(Net.Id.RunEnded).OnClientEvent:Connect(onRunEnded)

	Net.GetEvent(Net.Id.CombatPaused).OnClientEvent:Connect(function(value: boolean)
		paused = value
	end)

	--[[
		Выход босса виден по смене фазы уровня — отдельного признака не нужно.
		Пакет фазы типизирован свободно там же, где его читает HUD: это срез
		серверного состояния, у которого нет отдельного типа в Types.
	]]
	Net.GetEvent(Net.Id.StagePhase).OnClientEvent:Connect(function(payload: { [string]: any })
		if payload.phase == "Boss" then
			bossOut = true
		end
	end)

	Net.GetUnreliable(Net.Id.RunSnapshot).OnClientEvent:Connect(function(snapshot: Types.RunSnapshot)
		-- Первый подобранный кристалл виден по опыту: отдельного события
		-- «кристалл подобран» на клиенте нет, а опыт приходит и так.
		if snapshot.xp > 0 or snapshot.level > 1 then
			gainedXp = true
		end

		-- Время забега считает сервер, и подсказки по времени идут от него же:
		-- свой таймер разошёлся бы с расписанием волн на паузе левел-апа.
		runTime = snapshot.time
	end)

	Net.GetEvent(Net.Id.EggResult).OnClientEvent:Connect(function(results: { Types.EggRollResult })
		if #results > 0 then
			boughtEgg = true
		end
	end)

	--[[
		Очко таланта. Считается по срезу дерева, а не по факту нажатия:
		нажатие может быть отклонено сервером (узел уже полон, соседа нет),
		и шаг закрывался бы, ничего не изменив.
	]]
	Net.GetEvent(Net.Id.TalentsView).OnClientEvent:Connect(function(view: Types.TalentsView)
		if talentPoints >= 0 and view.points < talentPoints then
			talentSpent = true
		end
		talentPoints = view.points
	end)

	-- То же и с предметом: важен факт смены надетого, а не клик по кнопке.
	Net.GetEvent(Net.Id.ItemsView).OnClientEvent:Connect(function(view: Types.ItemsView)
		local signature = equipmentSignature(view.equipped)
		if signature ~= equipSignature then
			equipSignature = signature
			equipVersion += 1
		end
	end)
end

return TutorialController
