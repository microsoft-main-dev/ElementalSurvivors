--!strict
--[[
	CombatService — оркестратор забега: вход в бой, состояние игрока,
	урон от касания, смерть и возврат в лобби.

	Сервер авторитетен во всём (правило 3 ТЗ). Единственное, что приходит
	с клиента в бою, — выбор карточки левел-апа, и его обрабатывает
	ProgressionService со всеми проверками.

	Боевого кода здесь нет: способности живут в AbilityService, кристаллы
	в PickupService, уровни в ProgressionService, награда в RewardService.
	Этот сервис только связывает их жизненный цикл с жизненным циклом забега
	и шлёт снимок для HUD.

	Он же отвечает за то, чтобы забег был оплачен ровно один раз и при любом
	исходе: смерть, выход через портал, дисконнект, выключение сервера.

	Публичный API:
		CombatService.BeginRun(player)              -> boolean
		CombatService.EndRun(player, reason)
		CombatService.GetRunStats(player)           -> RunStats?
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local AbilityService = require(script.Parent.AbilityService)
local ArenaService = require(script.Parent.ArenaService)
local Balance = require(Shared.Config.Balance)
local DataService = require(script.Parent.DataService)
local EnemyService = require(script.Parent.EnemyService)
local Net = require(Shared.Net)
local PetService = require(script.Parent.PetService)
local PickupService = require(script.Parent.PickupService)
local ProgressionService = require(script.Parent.ProgressionService)
local RewardService = require(script.Parent.RewardService)
local Types = require(Shared.Types)

export type RunStats = {
	kills: number,
	startedAt: number,
}

type RunState = {
	player: Player,
	slot: number,
	humanoid: Humanoid,
	lastHitAt: number,
	snapshotTimer: number,
	stats: RunStats,
	connections: { RBXScriptConnection },
	ending: boolean,
	awarded: boolean, -- награда за забег уже начислена, второй раз нельзя
}

local ENTER_COOLDOWN = 1.5

local CombatService = {}

local runs: { [Player]: RunState } = {}
local runBySlot: { [number]: RunState } = {}
local lastEnterAttempt: { [Player]: number } = {}

local notifyRemote: RemoteEvent? = nil
local runStartedRemote: RemoteEvent? = nil
local runEndedRemote: RemoteEvent? = nil
local runResultRemote: RemoteEvent? = nil
local snapshotRemote: UnreliableRemoteEvent? = nil

local function notify(player: Player, message: string): ()
	local remote = notifyRemote
	if remote then
		remote:FireClient(player, message)
	end
end

local function getRoot(player: Player): BasePart?
	local character = player.Character
	if not character then
		return nil
	end
	return character:FindFirstChild("HumanoidRootPart") :: BasePart?
end

local function getHumanoid(player: Player): Humanoid?
	local character = player.Character
	if not character then
		return nil
	end
	return character:FindFirstChildOfClass("Humanoid")
end

-- Позиция игрока в локальных координатах его арены.
local function getPlayerLocal(run: RunState): Vector3?
	local root = getRoot(run.player)
	if not root then
		return nil
	end
	local world = root.Position - ArenaService.GetOrigin(run.slot)
	return Vector3.new(world.X, 0, world.Z)
end

local function sendSnapshot(run: RunState): ()
	local remote = snapshotRemote
	if not remote then
		return
	end

	local progress = ProgressionService.GetState(run.slot)
	local snapshot: Types.RunSnapshot = {
		time = EnemyService.GetRunTime(run.slot),
		kills = run.stats.kills,
		level = progress.level,
		xp = progress.xp,
		xpToNext = progress.xpToNext,
		abilities = AbilityService.GetViews(run.slot),
	}

	remote:FireClient(run.player, snapshot)
end

local function onHeartbeat(deltaTime: number): ()
	local snapshotInterval = 1 / Balance.Progression.snapshotRate

	for _, run in runs do
		if run.ending then
			continue
		end

		-- На паузе левел-апа не тикает ничего боевого: ни способности,
		-- ни магнит. Врагов останавливает сам EnemyService.
		if not ProgressionService.IsPaused(run.slot) then
			local playerLocal = getPlayerLocal(run)
			if playerLocal then
				AbilityService.Tick(run.slot, deltaTime, playerLocal)
				PickupService.Tick(run.slot, deltaTime, playerLocal)
			end
		end

		run.snapshotTimer += deltaTime
		if run.snapshotTimer >= snapshotInterval then
			run.snapshotTimer = 0
			sendSnapshot(run)
		end
	end
end

-- Смерть врага от урона: убийство в статистику, кристалл на землю.
local function onEnemyDeath(slot: number, _player: Player, position: Vector3, xp: number): ()
	local run = runBySlot[slot]
	if not run or run.ending then
		return
	end

	run.stats.kills += 1
	PickupService.Drop(slot, position, xp)
end

-- Подобранный опыт уходит в прогрессию — она сама решит, пора ли уровень.
local function onCrystalCollected(slot: number, _player: Player, xp: number): ()
	ProgressionService.AddXp(slot, xp)
end

--[[
	Урон игроку от касания врага. i-frames общие для игрока, а не на источник:
	при сотнях врагов «на источник» означало бы мгновенную смерть в толпе.
]]
local function onContact(player: Player, damage: number): ()
	local run = runs[player]
	if not run or run.ending then
		return
	end

	local now = os.clock()
	if now - run.lastHitAt < Balance.Combat.invulnerability then
		return
	end
	run.lastHitAt = now

	local humanoid = run.humanoid
	if humanoid.Health > 0 then
		humanoid:TakeDamage(damage)
	end
end

--[[
	Итоги забега, собранные из серверного состояния. Снимать их нужно ДО
	остановки сервисов: после StopRun ни времени, ни урона по способностям
	уже не существует.
]]
local function buildSummary(run: RunState, reason: Types.RunEndReason): Types.RunSummary
	return {
		reason = reason,
		time = EnemyService.GetRunTime(run.slot),
		kills = run.stats.kills,
		level = ProgressionService.GetState(run.slot).level,
		abilities = AbilityService.GetViews(run.slot),
	}
end

--[[
	Начисление награды. Вызывается из трёх мест — обычный конец забега, выход
	игрока, выключение сервера, — поэтому защищено флагом: два начисления
	за один забег означали бы дюп валюты.

	Yield-иться здесь нельзя: на выключении сервера времени на это нет.
]]
local function awardRun(run: RunState, reason: Types.RunEndReason): Types.RunResult?
	if run.awarded then
		return nil
	end
	run.awarded = true

	return RewardService.Award(run.player, buildSummary(run, reason))
end

function CombatService.EndRun(player: Player, reason: Types.RunEndReason): ()
	local run = runs[player]
	if not run or run.ending then
		return
	end
	run.ending = true

	-- Награда считается и начисляется до телепорта в лобби (раздел 5 ТЗ).
	local result = awardRun(run, reason)

	for _, connection in run.connections do
		connection:Disconnect()
	end
	table.clear(run.connections)

	EnemyService.StopRun(run.slot)
	AbilityService.StopRun(run.slot)
	PickupService.StopRun(run.slot)
	ProgressionService.StopRun(run.slot)
	ArenaService.Release(player)
	runBySlot[run.slot] = nil
	runs[player] = nil

	local remote = runEndedRemote
	if remote then
		remote:FireClient(player, reason)
	end

	-- Экран результатов отдельным пакетом: RunEnded переключает состояние
	-- клиента, а этот показывает итоги. Если начислять было некуда
	-- (профиль уже закрыт), экрана просто не будет.
	local resultRemote = runResultRemote
	if result and resultRemote then
		resultRemote:FireClient(player, result)
	end

	-- Респавн в лобби: SpawnLocation стоит только там, поэтому LoadCharacter
	-- сам вернёт игрока на место и заодно сбросит здоровье и скорость.
	if player.Parent then
		player:LoadCharacter()
	end
end

function CombatService.BeginRun(player: Player): boolean
	if runs[player] then
		return false
	end

	local now = os.clock()
	local last = lastEnterAttempt[player]
	if last and now - last < ENTER_COOLDOWN then
		return false
	end
	lastEnterAttempt[player] = now

	local root = getRoot(player)
	local humanoid = getHumanoid(player)
	if not root or not humanoid or humanoid.Health <= 0 then
		return false
	end

	-- Забег без профиля некуда засчитать. Попасть сюда без профиля нельзя
	-- (персонаж не спавнится раньше загрузки), но проверка стоит копейку,
	-- а цена ошибки — забег, за который игрок ничего не получит.
	if not DataService.GetProfile(player) then
		notify(player, "Your save data is still loading. Try again in a moment.")
		return false
	end

	local slot = ArenaService.Acquire(player)
	if not slot then
		notify(player, "All arenas are busy. Try again in a moment.")
		return false
	end

	--[[
		Характеристики забега = база плюс бонусы питомца (разделы 5 и 6 ТЗ).
		Лоадаут снимается ровно здесь и на весь забег: сменить питомца в бою
		нельзя, а пересчёт в цикле означал бы, что покупка в лобби чужого
		сервера могла бы изменить идущий бой.
	]]
	local loadout = PetService.GetLoadout(player)

	humanoid.MaxHealth = loadout.maxHealth
	humanoid.Health = loadout.maxHealth
	humanoid.WalkSpeed = loadout.walkSpeed

	root.CFrame = ArenaService.GetSpawnCFrame(slot)

	local run: RunState = {
		player = player,
		slot = slot,
		humanoid = humanoid,
		lastHitAt = 0,
		snapshotTimer = 0,
		stats = { kills = 0, startedAt = os.clock() },
		connections = {},
		ending = false,
		awarded = false,
	}
	runs[player] = run
	runBySlot[slot] = run

	table.insert(
		run.connections,
		humanoid.Died:Connect(function()
			notify(player, "You died. Returning to lobby...")
			task.delay(Balance.Combat.deathReturnDelay, function()
				CombatService.EndRun(player, "Death")
			end)
		end)
	)

	-- Персонаж может быть заменён извне (например, respawn) — тогда забег окончен.
	table.insert(
		run.connections,
		player.CharacterRemoving:Connect(function()
			if runs[player] and not runs[player].ending then
				CombatService.EndRun(player, "Left")
			end
		end)
	)

	local exitPrompt = ArenaService.GetExitPrompt(slot)
	if exitPrompt then
		table.insert(
			run.connections,
			exitPrompt.Triggered:Connect(function(triggeringPlayer: Player)
				-- Проверка права на действие: сработать может только владелец арены.
				if triggeringPlayer == player and ArenaService.IsPlayerInSlot(player, slot) then
					CombatService.EndRun(player, "Left")
				end
			end)
		)
	end

	EnemyService.StartRun(slot, player, ArenaService.GetOrigin(slot), ArenaService.GetSeed(slot))
	PickupService.StartRun(slot, player, loadout.magnetRadius)
	ProgressionService.StartRun(slot, player)
	AbilityService.StartRun(slot, player, loadout)

	-- Радиус магнита уходит на клиент вместе со стартом: кристаллы он
	-- притягивает сам тем же правилом, и без радиуса картинка разойдётся
	-- с тем, что реально подобрано на сервере.
	local remote = runStartedRemote
	if remote then
		remote:FireClient(player, slot, ArenaService.GetSeed(slot), loadout.magnetRadius)
	end
	sendSnapshot(run)

	return true
end

function CombatService.GetRunStats(player: Player): RunStats?
	local run = runs[player]
	return if run then run.stats else nil
end

--[[
	Респавном управляем сами, автоматический выключен.

	Иначе движок возродит игрока по своему таймеру прямо посреди арены,
	и это столкнулось бы с нашим возвратом в лобби. Второе назначение —
	порядок входа: персонаж появляется только после загрузки профиля,
	поэтому заработать что-либо «до профиля» невозможно.
]]
local function onCharacterAdded(player: Player, character: Model): ()
	local humanoid = character:WaitForChild("Humanoid", 10) :: Humanoid?
	if not humanoid then
		return
	end

	humanoid.Died:Connect(function()
		-- Смерть вне забега (страховка): просто возродить в лобби.
		if not runs[player] then
			task.delay(Balance.Combat.deathReturnDelay, function()
				if player.Parent then
					player:LoadCharacter()
				end
			end)
		end
	end)
end

local function onPlayerAdded(player: Player): ()
	player.CharacterAdded:Connect(function(character: Model)
		onCharacterAdded(player, character)
	end)

	if player.Character then
		onCharacterAdded(player, player.Character)
		return
	end

	-- Ждём профиль и только потом впускаем в мир. Не дождались — игрока уже
	-- кикает DataService, спавнить его в лобби бессмысленно и вредно.
	if not DataService.WaitForProfile(player) then
		warn(
			`[CombatService] Персонаж {player.Name} не создан: профиль не загрузился`
		)
		return
	end

	if player.Parent then
		player:LoadCharacter()
	end
end

function CombatService.Init(): ()
	notifyRemote = Net.GetEvent(Net.Id.Notify)
	runStartedRemote = Net.GetEvent(Net.Id.RunStarted)
	runEndedRemote = Net.GetEvent(Net.Id.RunEnded)
	runResultRemote = Net.GetEvent(Net.Id.RunResult)
	snapshotRemote = Net.GetUnreliable(Net.Id.RunSnapshot)

	Players.CharacterAutoLoads = false
end

function CombatService.Start(): ()
	EnemyService.SetContactHandler(onContact)
	EnemyService.SetDeathHandler(onEnemyDeath)
	PickupService.SetCollectHandler(onCrystalCollected)
	RunService.Heartbeat:Connect(onHeartbeat)

	--[[
		Забег, прерванный выходом игрока или выключением сервера, всё равно
		должен быть оплачен: терять четырнадцать минут из-за дисконнекта нельзя.

		Хук вызывается до закрытия сессии профиля, то есть пока в профиль ещё
		можно писать. Дублирования с обработчиком PlayerRemoving ниже не будет:
		порядок этих двух обработчиков не важен, потому что awardRun защищён
		флагом и второй вызов ничего не делает.
	]]
	DataService.SetReleaseHook(function(player: Player)
		local run = runs[player]
		if run then
			awardRun(run, "Left")
		end
	end)

	for _, player in Players:GetPlayers() do
		task.spawn(onPlayerAdded, player)
	end
	Players.PlayerAdded:Connect(onPlayerAdded)

	Players.PlayerRemoving:Connect(function(player: Player)
		local run = runs[player]
		if run then
			awardRun(run, "Left")
			run.ending = true
			for _, connection in run.connections do
				connection:Disconnect()
			end
			EnemyService.StopRun(run.slot)
			AbilityService.StopRun(run.slot)
			PickupService.StopRun(run.slot)
			ProgressionService.StopRun(run.slot)
			runBySlot[run.slot] = nil
			runs[player] = nil
		end
		ArenaService.Release(player)
		lastEnterAttempt[player] = nil
	end)
end

return CombatService
