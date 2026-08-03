--!strict
--[[
	BossService — боссфайт сюжетного уровня (разделы 3.5 и 5.1 ТЗ), M6.

	Босс — единственный на арену, поэтому он не живёт в плоских массивах, как
	обычные враги: там эта схема нужна ради сотен сущностей, а здесь она была бы
	усложнением без выигрыша. Позиция, здоровье и состояние атаки — обычные поля.

	Координаты локальные для арены, Y = 0 — как у всего остального в бою.

	Устройство атаки: телеграф -> удар -> кулдаун. Телеграф обязателен и
	проверяется валидатором в Config/Bosses: на автобое игрок управляет только
	позицией, и атака, показанная одновременно с уроном, не оставляет ему
	решения вовсе.

	Урон боссу наносят те же способности, что и врагам: AbilityService после
	каждого попадания по толпе спрашивает CollectHit. Отдельного пути урона
	по боссу нет — иначе половина форм однажды перестала бы его задевать.

	Публичный API:
		BossService.Spawn(slot, player, bossKey, health) -> boolean
		BossService.Tick(slot, dt, playerLocal)
		BossService.CollectHit(slot, position, radius)   -> boolean
		BossService.Damage(slot, amount)                 -> (boolean, number)
		BossService.IsActive(slot)                       -> boolean
		BossService.StopRun(slot)
		BossService.SetDeathHandler(fn)
		BossService.SetContactHandler(fn)
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Balance = require(Shared.Config.Balance)
local Bosses = require(Shared.Config.Bosses)
local EnemyMotion = require(Shared.Util.EnemyMotion)
local EnemyService = require(script.Parent.EnemyService)
local Net = require(Shared.Net)
local Types = require(Shared.Types)

type BossDef = Types.BossDef
type BossAttack = Types.BossAttack

type State = {
	slot: number,
	player: Player,
	def: BossDef,

	position: Vector3,
	health: number,
	maxHealth: number,

	-- Кулдауны атак текущей фазы, по индексу атаки внутри фазы.
	cooldowns: { number },

	--[[
		Активная атака. Пока telegraph > 0, урона нет — область уже показана,
		но удар ещё не случился. Это и есть окно, в которое игрок уходит.
	]]
	attack: BossAttack?,
	telegraph: number,
	aimX: number,
	aimZ: number,

	-- Рывок: пока время не вышло, босс летит по прямой и не преследует.
	chargeTime: number,
	chargeX: number,
	chargeZ: number,

	stateTimer: number,
	dead: boolean,
}

local BossService = {}

local states: { [number]: State } = {}
local eventRemote: RemoteEvent? = nil
local stateRemote: UnreliableRemoteEvent? = nil

local deathHandler: ((slot: number, player: Player) -> ())? = nil
local contactHandler: ((player: Player, damage: number) -> ())? = nil

local STATE_INTERVAL = 0.1

local function sendEvent(state: State, payload: { [string]: any }): ()
	local remote = eventRemote
	if remote then
		remote:FireClient(state.player, payload)
	end
end

--[[
	Выбор атаки: первая готовая из текущей фазы.

	По порядку, а не случайно, намеренно — порядок в данных становится
	приоритетом, и поведение босса можно менять, не трогая код.
]]
local function pickAttack(state: State): (BossAttack?, number)
	local fraction = state.health / state.maxHealth
	local phase = Bosses.PhaseFor(state.def, fraction)

	for index, attack in phase.attacks do
		if (state.cooldowns[index] or 0) <= 0 then
			return attack, index
		end
	end

	return nil, 0
end

local function beginAttack(state: State, attack: BossAttack, playerLocal: Vector3): ()
	state.attack = attack
	state.telegraph = attack.telegraph
	state.aimX = playerLocal.X
	state.aimZ = playerLocal.Z

	local dx = playerLocal.X - state.position.X
	local dz = playerLocal.Z - state.position.Z
	local length = math.sqrt(dx * dx + dz * dz)
	if length > 1e-4 then
		dx, dz = dx / length, dz / length
	else
		dx, dz = 1, 0
	end

	sendEvent(state, {
		kind = "Telegraph",
		attack = attack.kind,
		x = state.position.X,
		z = state.position.Z,
		aimX = state.aimX,
		aimZ = state.aimZ,
		dirX = dx,
		dirZ = dz,
		radius = attack.radius,
		duration = attack.telegraph,
	})

	state.chargeX = dx
	state.chargeZ = dz
end

--[[
	Момент удара. Телеграф закончился, область уже была показана —
	теперь считается урон.
]]
local function executeAttack(state: State, attack: BossAttack, playerLocal: Vector3): ()
	sendEvent(state, {
		kind = "Attack",
		attack = attack.kind,
		x = state.position.X,
		z = state.position.Z,
		aimX = state.aimX,
		aimZ = state.aimZ,
		radius = attack.radius,
	})

	if attack.kind == "Shockwave" then
		--[[
			Волна бьёт по кольцу от босса. Урон считается в момент удара
			по текущей позиции игрока: волна на клиенте расходится плавно,
			но решение игрок принял, пока шёл телеграф.
		]]
		local dx = playerLocal.X - state.position.X
		local dz = playerLocal.Z - state.position.Z
		if dx * dx + dz * dz <= attack.radius * attack.radius then
			local handler = contactHandler
			if handler then
				handler(state.player, attack.damage)
			end
		end
	elseif attack.kind == "Charge" then
		-- Урон рывка наносится касанием во время движения, а не сразу:
		-- уклонившийся в сторону игрок обязан остаться целым.
		state.chargeTime = attack.radius > 0 and 0.9 or 0
	elseif attack.kind == "Summon" then
		EnemyService.SpawnBurst(state.slot, state.position, attack.count or 0, attack.radius)
	end
end

local function moveStep(state: State, dt: number, playerLocal: Vector3): ()
	if state.chargeTime > 0 then
		local attack = state.attack
		local speed = if attack and attack.speed then attack.speed else 60
		state.chargeTime -= dt
		state.position = EnemyMotion.ClampToArena(
			state.position + Vector3.new(state.chargeX, 0, state.chargeZ) * speed * dt,
			Balance.Arena.size
		)
		return
	end

	-- Во время телеграфа босс стоит: иначе показанная область уезжает
	-- вместе с ним и перестаёт что-либо обещать.
	if state.telegraph > 0 then
		return
	end

	local fraction = state.health / state.maxHealth
	local phase = Bosses.PhaseFor(state.def, fraction)
	state.position = EnemyMotion.ClampToArena(
		EnemyMotion.Chase(state.position, playerLocal, phase.moveSpeed, dt),
		Balance.Arena.size
	)
end

local function contactStep(state: State, playerLocal: Vector3): ()
	local handler = contactHandler
	if not handler then
		return
	end

	local reach = state.def.radius + Balance.Combat.playerRadius
	local dx = playerLocal.X - state.position.X
	local dz = playerLocal.Z - state.position.Z

	if dx * dx + dz * dz <= reach * reach then
		-- Во время рывка касание бьёт сильнее: это и есть урон атаки Charge.
		local attack = state.attack
		local damage = state.def.contactDamage
		if state.chargeTime > 0 and attack and attack.kind == "Charge" then
			damage = attack.damage
		end
		handler(state.player, damage)
	end
end

function BossService.Tick(slot: number, dt: number, playerLocal: Vector3): ()
	local state = states[slot]
	if not state or state.dead then
		return
	end

	local fraction = state.health / state.maxHealth
	local phase = Bosses.PhaseFor(state.def, fraction)

	for index in phase.attacks do
		local left = (state.cooldowns[index] or 0) - dt
		state.cooldowns[index] = if left < 0 then 0 else left
	end

	if state.telegraph > 0 then
		state.telegraph -= dt
		if state.telegraph <= 0 then
			state.telegraph = 0
			local attack = state.attack
			if attack then
				executeAttack(state, attack, playerLocal)
			end
		end
	elseif state.chargeTime <= 0 then
		local attack, index = pickAttack(state)
		if attack then
			state.cooldowns[index] = attack.cooldown
			beginAttack(state, attack, playerLocal)
		end
	end

	moveStep(state, dt, playerLocal)
	contactStep(state, playerLocal)

	state.stateTimer += dt
	if state.stateTimer >= STATE_INTERVAL then
		state.stateTimer = 0
		local remote = stateRemote
		if remote then
			remote:FireClient(state.player, {
				x = state.position.X,
				z = state.position.Z,
				health = state.health,
				maxHealth = state.maxHealth,
			})
		end
	end
end

--[[
	Задела ли область способности босса.

	Радиус босса учитывается так же, как радиус врага в EnemyService.CollectHits:
	сравнение центров при боссе диаметром в восемнадцать стадов означало бы,
	что половина попаданий проходит сквозь него.
]]
function BossService.CollectHit(slot: number, position: Vector3, radius: number): boolean
	local state = states[slot]
	if not state or state.dead then
		return false
	end

	local reach = radius + state.def.radius
	local dx = position.X - state.position.X
	local dz = position.Z - state.position.Z
	return dx * dx + dz * dz <= reach * reach
end

-- Возвращает (убит ли, сколько урона реально нанесено).
function BossService.Damage(slot: number, amount: number): (boolean, number)
	local state = states[slot]
	if not state or state.dead or amount <= 0 then
		return false, 0
	end

	local dealt = math.min(amount, state.health)
	state.health -= dealt

	if state.health > 0 then
		return false, dealt
	end

	state.dead = true
	sendEvent(state, { kind = "Despawn" })

	local handler = deathHandler
	if handler then
		handler(state.slot, state.player)
	end

	return true, dealt
end

function BossService.Spawn(slot: number, player: Player, bossKey: string, health: number): boolean
	local def = Bosses.ByKey[bossKey]
	if not def then
		warn(`[BossService] Неизвестный босс "{bossKey}"`)
		return false
	end

	--[[
		Босс появляется в центре арены, а не рядом с игроком: он должен быть
		виден целиком в момент выхода, а не вырасти вплотную к лицу.
	]]
	local state: State = {
		slot = slot,
		player = player,
		def = def,

		position = Vector3.zero,
		health = health,
		maxHealth = health,

		cooldowns = {},

		attack = nil,
		telegraph = 0,
		aimX = 0,
		aimZ = 0,

		chargeTime = 0,
		chargeX = 0,
		chargeZ = 0,

		stateTimer = 0,
		dead = false,
	}

	states[slot] = state

	sendEvent(state, {
		kind = "Spawn",
		boss = def.key,
		x = state.position.X,
		z = state.position.Z,
		radius = def.radius,
		maxHealth = health,
	})

	return true
end

function BossService.IsActive(slot: number): boolean
	local state = states[slot]
	return state ~= nil and not state.dead
end

function BossService.StopRun(slot: number): ()
	states[slot] = nil
end

function BossService.SetDeathHandler(handler: (slot: number, player: Player) -> ()): ()
	deathHandler = handler
end

function BossService.SetContactHandler(handler: (player: Player, damage: number) -> ()): ()
	contactHandler = handler
end

function BossService.Init(): ()
	eventRemote = Net.GetEvent(Net.Id.BossEvent)
	stateRemote = Net.GetUnreliable(Net.Id.BossState)
end

return BossService
