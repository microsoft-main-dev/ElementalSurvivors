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
	Один недостижимый враг — застрявший за колонной, оказавшийся в мёртвой
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
		StageService.Tick(slot, dt)
		StageService.GetPhase(slot)                  -> StagePhase?
		StageService.GetStage(slot)                  -> StageDef?
		StageService.StopRun(slot)
		StageService.CanPlay(player, stageIndex)     -> boolean
		StageService.HighestUnlocked(player)         -> number
		StageService.SetVictoryHandler(fn)
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

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

local function beginBoss(state: State): ()
	setPhase(state, "Boss")
	EnemyService.SetSweeping(state.slot, false)
	BossService.Spawn(state.slot, state.player, state.stage.bossKey, state.stage.bossHealth)
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

function StageService.Begin(slot: number, player: Player, stageIndex: number): StageDef?
	local stage = Stages.Get(stageIndex)
	if not stage then
		return nil
	end

	states[slot] = {
		slot = slot,
		player = player,
		stage = stage,
		phase = "Survival",
		sweepTimer = 0,
		sweeping = false,
	}

	pushPhase(states[slot])
	return stage
end

function StageService.Tick(slot: number, dt: number): ()
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
			beginBoss(state)
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
			beginBoss(state)
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

	setPhase(state, "Done")
	DataService.AdvanceStoryStage(player, state.stage.index)

	local handler = victoryHandler
	if handler then
		handler(slot, player)
	end
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
