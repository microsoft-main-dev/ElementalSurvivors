--!strict
--[[
	CombatService — оркестратор забега: вход в бой, состояние игрока, автоатака,
	урон от касания, смерть и возврат в лобби.

	Сервер авторитетен во всём (правило 3 ТЗ): клиент не присылает ни одного
	сообщения о бое. Вход — через ProximityPrompt (дистанцию проверяет движок),
	выход и смерть решает сервер, урон и убийства считает только он.

	Базовая автоатака M1 — импульс по площади вокруг игрока по кулдауну.
	Активных кнопок нет и не будет (раздел 3.6 ТЗ): единственное решение игрока
	в бою появится в M2 вместе с карточками левел-апа.

	Публичный API:
		CombatService.BeginRun(player)              -> boolean
		CombatService.EndRun(player, reason)
		CombatService.GetRunStats(player)           -> RunStats?
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local ArenaService = require(script.Parent.ArenaService)
local Balance = require(Shared.Config.Balance)
local EnemyService = require(script.Parent.EnemyService)
local Net = require(Shared.Net)
local Types = require(Shared.Types)

export type RunStats = {
	kills: number,
	startedAt: number,
}

type RunState = {
	player: Player,
	slot: number,
	humanoid: Humanoid,
	attackTimer: number,
	lastHitAt: number,
	stats: RunStats,
	connections: { RBXScriptConnection },
	ending: boolean,
}

local ENTER_COOLDOWN = 1.5

local CombatService = {}

local runs: { [Player]: RunState } = {}
local lastEnterAttempt: { [Player]: number } = {}
local attackBuffer: { number } = {}

local notifyRemote: RemoteEvent? = nil
local runStartedRemote: RemoteEvent? = nil
local runEndedRemote: RemoteEvent? = nil
local pulseRemote: UnreliableRemoteEvent? = nil

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

--[[
	Автоатака: импульс по площади вокруг игрока.
	Цели ищет EnemyService через пространственный хеш, урон считает только сервер.
]]
local function attackStep(run: RunState, dt: number): ()
	run.attackTimer -= dt
	if run.attackTimer > 0 then
		return
	end
	run.attackTimer += Balance.Combat.autoAttack.cooldown

	local root = getRoot(run.player)
	if not root then
		return
	end

	local origin = ArenaService.GetOrigin(run.slot)
	local world = root.Position - origin
	local localPosition = Vector3.new(world.X, 0, world.Z)

	local radius = Balance.Combat.autoAttack.radius
	local damage = Balance.Combat.autoAttack.damage
	local count = EnemyService.Collect(run.slot, localPosition, radius, attackBuffer)

	local kills = 0
	for index = 1, count do
		if EnemyService.Damage(run.slot, attackBuffer[index], damage) then
			kills += 1
		end
	end
	run.stats.kills += kills

	local remote = pulseRemote
	if remote then
		remote:FireClient(run.player, radius)
	end
end

local function onHeartbeat(deltaTime: number): ()
	for _, run in runs do
		if not run.ending then
			attackStep(run, deltaTime)
		end
	end
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

function CombatService.EndRun(player: Player, reason: Types.RunEndReason): ()
	local run = runs[player]
	if not run or run.ending then
		return
	end
	run.ending = true

	for _, connection in run.connections do
		connection:Disconnect()
	end
	table.clear(run.connections)

	EnemyService.StopRun(run.slot)
	ArenaService.Release(player)
	runs[player] = nil

	local remote = runEndedRemote
	if remote then
		remote:FireClient(player, reason)
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

	local slot = ArenaService.Acquire(player)
	if not slot then
		notify(player, "All arenas are busy. Try again in a moment.")
		return false
	end

	humanoid.MaxHealth = Balance.Combat.playerMaxHealth
	humanoid.Health = Balance.Combat.playerMaxHealth
	humanoid.WalkSpeed = Balance.Combat.playerWalkSpeed

	root.CFrame = ArenaService.GetSpawnCFrame(slot)

	local run: RunState = {
		player = player,
		slot = slot,
		humanoid = humanoid,
		attackTimer = Balance.Combat.autoAttack.cooldown,
		lastHitAt = 0,
		stats = { kills = 0, startedAt = os.clock() },
		connections = {},
		ending = false,
	}
	runs[player] = run

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

	local remote = runStartedRemote
	if remote then
		remote:FireClient(player, slot, ArenaService.GetSeed(slot))
	end

	return true
end

function CombatService.GetRunStats(player: Player): RunStats?
	local run = runs[player]
	return if run then run.stats else nil
end

--[[
	Респавном управляем сами, автоматический выключен.

	Иначе движок возродит игрока по своему таймеру прямо посреди арены,
	и это столкнётся с нашим возвратом в лобби. Заодно это то, что понадобится
	в M3: персонаж должен появляться только после того, как загружен профиль.
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
	else
		player:LoadCharacter()
	end
end

function CombatService.Init(): ()
	notifyRemote = Net.GetEvent(Net.Id.Notify)
	runStartedRemote = Net.GetEvent(Net.Id.RunStarted)
	runEndedRemote = Net.GetEvent(Net.Id.RunEnded)
	pulseRemote = Net.GetUnreliable(Net.Id.CombatPulse)

	Players.CharacterAutoLoads = false
end

function CombatService.Start(): ()
	EnemyService.SetContactHandler(onContact)
	RunService.Heartbeat:Connect(onHeartbeat)

	for _, player in Players:GetPlayers() do
		task.spawn(onPlayerAdded, player)
	end
	Players.PlayerAdded:Connect(onPlayerAdded)

	Players.PlayerRemoving:Connect(function(player: Player)
		local run = runs[player]
		if run then
			run.ending = true
			for _, connection in run.connections do
				connection:Disconnect()
			end
			EnemyService.StopRun(run.slot)
			runs[player] = nil
		end
		ArenaService.Release(player)
		lastEnterAttempt[player] = nil
	end)
end

return CombatService
