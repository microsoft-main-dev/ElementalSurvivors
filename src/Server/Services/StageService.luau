--!strict
--[[
	StageService — фазы сюжетного забега и сюжетный прогресс (раздел 5.1 ТЗ), M6.

	Один забег = один уровень: фаза выживания, затем босс. Победа над боссом
	открывает следующий уровень, поражение — нет.

	ФАЗЫ И ПОЧЕМУ ИХ ЧЕТЫРЕ

		Survival — обычный бой по расписанию волн, ограниченный по времени.
		Sweep    — спавн выключен, игрок добивает оставшихся.
		Boss     — арена пуста, идёт боссфайт.
		Done     — босс убит, забег завершается победой.

	Sweep существует не для красоты. Босс выходит на пустую арену (решение
	владельца), а значит забег зависит от того, будут ли убиты ВСЕ враги.
	Один недостижимый враг — застрявший за препятствием, оказавшийся в мёртвой
	зоне обхода, отошедший за край — подвесил бы уровень навсегда. Поэтому
	страховка в три шага, все числа в Balance.Stages:

		1. спавн остановлен, оставшиеся помечены;
		2. через sweepDelay они начинают стягиваться к игроку;
		3. через sweepTimeout оставшиеся убираются молча, босс выходит.

	Третий шаг обязателен: без него любая будущая ошибка в поиске пути
	превращается в бесконечный забег, из которого игрок выходит только
	через портал, теряя весь прогресс уровня.

	Публичный API:
		StageService.Begin(slot, player, stageIndex) -> StageDef?
		StageService.BeginTutorial(slot, player)     -> StageDef
		StageService.Tick(slot, dt, playerLocal)
		StageService.GetPhase(slot)                  -> StagePhase?
		StageService.GetStage(slot)                  -> StageDef?
		StageService.StopRun(slot)
		StageService.CanPlay(player, stageIndex)     -> boolean
		StageService.HighestUnlocked(player)         -> number
		StageService.SetVictoryHandler(fn)
		StageService.DebugUnlockIfNeeded(player)
		StageService.DebugRushToBoss(slot, playerLocal)
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Balance = require(Shared.Config.Balance)
local BossService = require(script.Parent.BossService)
local DataService = require(script.Parent.DataService)
local EnemyService = require(script.Parent.EnemyService)
local Net = require(Shared.Net)
local Stages = require(Shared.Config.Stages)
local Types = require(Shared.Types)

type StageDef = Types.StageDef
type StagePhase = Types.StagePhase

type State = {
	slot: number,
	player: Player,
	stage: StageDef,
	phase: StagePhase,
	sweepTimer: number,
	sweeping: boolean,
	--[[
		Обучающий уровень (M7). Отличается ровно одним: победа над его боссом
		не двигает сюжетный прогресс. Всё остальное — фазы, добивание, босс —
		у него общее с настоящим уровнем намеренно: туториал, показывающий
		механики, которых потом не будет, не учит ничему.
	]]
	isTutorial: boolean,
}

local StageService = {}

local states: { [number]: State } = {}
local phaseRemote: RemoteEvent? = nil
local victoryHandler: ((slot: number, player: Player) -> ())? = nil

local function pushPhase(state: State): ()
	local remote = phaseRemote
	if remote then
		remote:FireClient(state.player, {
			phase = state.phase,
			stageIndex = state.stage.index,
			remaining = EnemyService.GetAliveCount(state.slot),
			duration = state.stage.duration,
		})
	end
end

local function setPhase(state: State, phase: StagePhase): ()
	if state.phase == phase then
		return
	end
	state.phase = phase
	pushPhase(state)
end

--[[
	Выход босса. Позиция игрока нужна затем, чтобы босс не родился на нём:
	раньше он появлялся в центре арены, куда игрока и ставит спавн.
]]
local function beginBoss(state: State, playerLocal: Vector3): ()
	setPhase(state, "Boss")
	EnemyService.SetSweeping(state.slot, false)
	BossService.Spawn(state.slot, state.player, state.stage.bossKey, state.stage.bossHealth, playerLocal)
end

--[[
	Самый высокий доступный уровень. storyStage в профиле — это «первый
	непройденный», поэтому играть можно всё вплоть до него включительно.
]]
function StageService.HighestUnlocked(player: Player): number
	local data = DataService.GetProfile(player)
	if not data then
		return 1
	end
	return math.min(data.progress.storyStage, Stages.TotalLevels)
end

--[[
	Открыть весь сюжет (Balance.Debug.unlockAllStages).

	Проверка на Studio стоит здесь, а не в конфиге, тем же приёмом, что
	у WheelService.DebugResetIfNeeded: значение можно забыть включённым,
	и единственная защита — та, мимо которой нельзя пройти.
]]
function StageService.DebugUnlockIfNeeded(player: Player): ()
	if not RunService:IsStudio() or not Balance.Debug.unlockAllStages then
		return
	end
	DataService.DebugUnlockStages(player, Stages.TotalLevels)
end

--[[
	Право играть уровень. Проверяется на сервере при каждом входе в бой:
	номер приходит с клиента и до этой проверки не значит ничего.
]]
function StageService.CanPlay(player: Player, stageIndex: number): boolean
	if stageIndex ~= stageIndex or stageIndex % 1 ~= 0 or stageIndex < 1 then
		return false
	end
	if stageIndex > Stages.TotalLevels then
		return false
	end
	return stageIndex <= StageService.HighestUnlocked(player)
end

local function beginWith(slot: number, player: Player, stage: StageDef, isTutorial: boolean): StageDef
	local state: State = {
		slot = slot,
		player = player,
		stage = stage,
		phase = "Survival",
		sweepTimer = 0,
		sweeping = false,
		isTutorial = isTutorial,
	}
	states[slot] = state

	pushPhase(state)
	return stage
end

function StageService.Begin(slot: number, player: Player, stageIndex: number): StageDef?
	local stage = Stages.Get(stageIndex)
	if not stage then
		return nil
	end

	return beginWith(slot, player, stage, false)
end

-- Обучающий уровень (M7, раздел 4 ТЗ). Номера у него нет: он собирается
-- из первого сюжетного и в сюжетной нумерации не участвует.
function StageService.BeginTutorial(slot: number, player: Player): StageDef
	return beginWith(slot, player, Stages.Tutorial(), true)
end

function StageService.Tick(slot: number, dt: number, playerLocal: Vector3): ()
	local state = states[slot]
	if not state then
		return
	end

	if state.phase == "Survival" then
		if EnemyService.GetRunTime(slot) >= state.stage.duration then
			-- Спавн выключается, но живые остаются: их добивает игрок.
			EnemyService.SetSpawnEnabled(slot, false)
			state.sweepTimer = 0
			state.sweeping = false
			setPhase(state, "Sweep")
		end
		return
	end

	if state.phase == "Sweep" then
		state.sweepTimer += dt

		if EnemyService.GetAliveCount(slot) == 0 then
			beginBoss(state, playerLocal)
			return
		end

		-- Шаг 2 страховки: стягиваем оставшихся к игроку.
		if not state.sweeping and state.sweepTimer >= Balance.Stages.sweepDelay then
			state.sweeping = true
			EnemyService.SetSweeping(slot, true)
		end

		-- Шаг 3: терпение кончилось, оставшиеся убираются молча.
		if state.sweepTimer >= Balance.Stages.sweepTimeout then
			local removed = EnemyService.ClearAll(slot)
			if removed > 0 then
				warn(
					`[StageService] Уровень {state.stage.index}: {removed} врагов убрано по таймауту добивания — `
						.. `они не дошли до игрока за {Balance.Stages.sweepTimeout} с`
				)
			end
			beginBoss(state, playerLocal)
		end

		return
	end
end

--[[
	Босс убит. Уровень засчитывается здесь, а не в награде: открытие следующего
	уровня — это факт прохождения, и он не должен зависеть от того, удалось ли
	начислить валюту.
]]
local function onBossKilled(slot: number, player: Player): ()
	local state = states[slot]
	if not state or state.phase == "Done" then
		return
	end

	--[[
		Урон боссу и урон игроку считаются независимо, и добивающий удар
		по боссу может прийти в тот же момент, когда игрока уже убили: без
		этой проверки уровень засчитывался пройденным даже игроку, умершему
		на боссе. Победа требует, чтобы игрок был жив в момент смерти босса.
	]]
	local character = player.Character
	local humanoid = if character then character:FindFirstChildOfClass("Humanoid") :: Humanoid? else nil
	if not humanoid or humanoid.Health <= 0 then
		return
	end

	setPhase(state, "Done")

	--[[
		Обучающий уровень сюжет не двигает: он собран из первого уровня, и
		засчитать его пройденным значило бы открыть второй уровень тому, кто
		первый ещё не играл. Награду за него выдаёт TutorialService — она
		одноразовая и живёт вместе с флагом обучения, а не с прогрессом.
	]]
	if not state.isTutorial then
		DataService.AdvanceStoryStage(player, state.stage.index)
	end

	local handler = victoryHandler
	if handler then
		handler(slot, player)
	end
end

--[[
	Тестовая кнопка "BossFight" в лобби (M7): пропускает Survival и Sweep
	и выводит босса сразу, чтобы проверять баланс боссов, не пережидая
	фазу выживания заново на каждую правку.

	Studio-only, проверка стоит здесь и только здесь — тем же приёмом,
	что OfflineService.forcedElapsed: значение нельзя забыть включённым,
	потому что включать тут нечего, рычаг — сама кнопка.
]]
function StageService.DebugRushToBoss(slot: number, playerLocal: Vector3): ()
	if not RunService:IsStudio() then
		return
	end

	local state = states[slot]
	if not state or state.phase ~= "Survival" then
		return
	end

	EnemyService.SetSpawnEnabled(slot, false)
	EnemyService.ClearAll(slot)
	beginBoss(state, playerLocal)
end

function StageService.GetPhase(slot: number): StagePhase?
	local state = states[slot]
	return if state then state.phase else nil
end

function StageService.GetStage(slot: number): StageDef?
	local state = states[slot]
	return if state then state.stage else nil
end

function StageService.StopRun(slot: number): ()
	states[slot] = nil
end

function StageService.SetVictoryHandler(handler: (slot: number, player: Player) -> ()): ()
	victoryHandler = handler
end

function StageService.Init(): ()
	phaseRemote = Net.GetEvent(Net.Id.StagePhase)
end

function StageService.Start(): ()
	BossService.SetDeathHandler(onBossKilled)
end

return StageService
