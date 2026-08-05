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
		BossService.Spawn(slot, player, bossKey, health, playerLocal) -> boolean
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
local RNG = require(Shared.Util.RNG)
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
	rng: RNG.RNG,

	--[[
		Стойкие поля (M2+): лечащие и ядовитые лужи шамана. Первые эффекты,
		которые живут дольше кадра, поэтому у босса появился свой список —
		остальные атаки бьют мгновенно и хранить о них нечего.
	]]
	fields: { Field },
}

type Field = {
	kind: Types.BossFieldKind,
	x: number,
	z: number,
	radius: number,
	remaining: number,
	tickInterval: number,
	tickTimer: number,
	damage: number,
	heal: number,
}

local BossService = {}

local states: { [number]: State } = {}
local eventRemote: RemoteEvent? = nil
local stateRemote: UnreliableRemoteEvent? = nil

local deathHandler: ((slot: number, player: Player) -> ())? = nil
local contactHandler: ((player: Player, damage: number) -> ())? = nil

local STATE_INTERVAL = 0.1

--[[
	Сколько врагов опрашивается при поиске скопления под лечащее поле.
	Восьми хватает, чтобы найти толпу, и это восемь запросов к хешу вместо
	перебора всех трёхсот.
]]
local CLUSTER_SAMPLES = 8

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

	--[[
		ГЕОМЕТРИЯ ТЕЛЕГРАФА ОБЯЗАНА СОВПАДАТЬ С ГЕОМЕТРИЕЙ УДАРА.

		Раньше круг рисовался в точке, где стоял игрок в момент начала показа
		(aimX/aimZ), а бил Shockwave по кругу вокруг БОССА. Эти две области
		совпадали только частично: игрок уходил из нарисованного круга и всё
		равно получал урон, или стоял в нём и не получал ничего. Со стороны
		это выглядело как «круг ничего не делает» — и это был не визуальный
		баг, а разъехавшиеся данные.

		Теперь центр телеграфа — сам босс (он на время показа стоит), а форма
		соответствует атаке: круг для Shockwave и Summon, полоса вдоль рывка
		для Charge. harmless говорит клиенту, что эта область не бьёт вовсе:
		Summon только высаживает врагов, и красный круг там был бы обманом.
	]]
	local payload: { [string]: any } = {
		kind = "Telegraph",
		attack = attack.kind,
		shape = "Circle",
		x = state.position.X,
		z = state.position.Z,
		dirX = dx,
		dirZ = dz,
		radius = attack.radius,
		length = 0,
		width = 0,
		duration = attack.telegraph,
		harmless = attack.kind == "Summon",
	}

	if attack.kind == "Charge" then
		payload.shape = "Line"
		-- Ровно тот путь, который босс пролетит: скорость на длительность рывка.
		payload.length = (attack.speed or 0) * Balance.Bosses.chargeSeconds
		payload.width = state.def.radius * 2
	end

	sendEvent(state, payload)

	state.chargeX = dx
	state.chargeZ = dz
end

--[[
	Поставить поле и рассказать о нём клиенту.

	Клиент получает круг один раз: он не двигается, а остаток времени клиент
	отсчитывает сам. Слать его каждый тик значило бы гонять по сети то,
	что обе стороны и так знают.
]]
local function addField(state: State, kind: Types.BossFieldKind, attack: BossAttack, x: number, z: number): ()
	local duration = attack.duration or 0
	local interval = attack.tickInterval or 1

	table.insert(state.fields, {
		kind = kind,
		x = x,
		z = z,
		radius = attack.radius,
		remaining = duration,
		tickInterval = interval,
		-- Первый тик не мгновенный: у игрока есть интервал, чтобы выйти.
		tickTimer = interval,
		damage = attack.damage,
		heal = attack.heal or 0,
	})

	sendEvent(state, {
		kind = "Field",
		field = kind,
		x = x,
		z = z,
		radius = attack.radius,
		duration = duration,
	})
end

--[[
	Тик полей: лечение своим, урон игроку.

	Урон идёт тем же обработчиком касания, что и всё остальное, — значит
	i-frames у игрока общие, и лужа не пробивает их отдельным путём.
]]
local function fieldStep(state: State, dt: number, playerLocal: Vector3): ()
	local index = 1

	while index <= #state.fields do
		local field = state.fields[index]
		field.remaining -= dt

		if field.remaining <= 0 then
			-- Порядок не важен: поля независимы, и дешевле переставить последнее.
			state.fields[index] = state.fields[#state.fields]
			state.fields[#state.fields] = nil :: any
			continue
		end

		field.tickTimer -= dt
		if field.tickTimer <= 0 then
			field.tickTimer += field.tickInterval

			if field.kind == "Heal" then
				EnemyService.Heal(state.slot, Vector3.new(field.x, 0, field.z), field.radius, field.heal)
			else
				local dx = playerLocal.X - field.x
				local dz = playerLocal.Z - field.z
				if dx * dx + dz * dz <= field.radius * field.radius then
					local handler = contactHandler
					if handler then
						handler(state.player, field.damage)
					end
				end
			end
		end

		index += 1
	end
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
		-- уклонившийся в сторону игрок обязан остаться целым. Длительность
		-- общая с клиентом (он по ней рисует полосу), поэтому из конфига.
		state.chargeTime = Balance.Bosses.chargeSeconds
	elseif attack.kind == "Summon" then
		EnemyService.SpawnBurst(state.slot, state.position, attack.count or 0, attack.radius, attack.summonKey)
	elseif attack.kind == "HealField" then
		--[[
			Лечение ставится НАД СКОПЛЕНИЕМ призванных, а не под боссом:
			в этом вся механика — игрок должен выбирать, гнать ли толпу
			из-под лечения или бить самого шамана.

			Толпы нет — лечим вокруг себя: поле, поставленное в пустоту,
			выглядело бы как промах босса, а не как решение игрока.
		]]
		local cluster = EnemyService.FindCluster(state.slot, attack.radius, CLUSTER_SAMPLES)
		local center = cluster or state.position
		addField(state, "Heal", attack, center.X, center.Z)
	elseif attack.kind == "PoisonField" then
		--[[
			Ядовитая лужа — в случайной точке арены, а не под игроком: она
			должна отнимать место, а не бить наверняка. Точка не ближе
			собственного радиуса к краю, иначе половина лужи уходит за стену.
		]]
		local limit = Balance.Arena.size * 0.5 - attack.radius
		local x = state.rng.NextNumber(-limit, limit)
		local z = state.rng.NextNumber(-limit, limit)
		addField(state, "Poison", attack, x, z)
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
	fieldStep(state, dt, playerLocal)
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

--[[
	Позиция живого босса или nil, если его нет.

	Нужна нацеливанию способностей: направленные формы выбирают цель среди
	врагов из плоских массивов, а босс в них не лежит — без этой функции
	они его просто не видят.
]]
function BossService.GetPosition(slot: number): Vector3?
	local state = states[slot]
	if not state or state.dead then
		return nil
	end
	return state.position
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

--[[
	Где босс выходит.

	НЕ в центре арены и НЕ на игроке. Раньше он появлялся ровно в центре —
	там же, где игрока ставит спавн, — и в половине забегов рождался прямо
	на нём: игрок получал несколько касаний, ещё не увидев противника.

	Точка берётся в стороне от игрока, В СТОРОНУ ЦЕНТРА арены: так босс
	не выходит в стене за спиной и всегда оказывается на открытом месте.
	Игрок в самом центре — направление берётся любое фиксированное, лишь бы
	не нулевое.
]]
local function spawnPosition(playerLocal: Vector3): Vector3
	local length = math.sqrt(playerLocal.X * playerLocal.X + playerLocal.Z * playerLocal.Z)
	local dirX, dirZ = 1, 0

	if length > 1e-3 then
		dirX, dirZ = -playerLocal.X / length, -playerLocal.Z / length
	end

	local distance = Balance.Bosses.spawnDistance
	return EnemyMotion.ClampToArena(
		Vector3.new(playerLocal.X + dirX * distance, 0, playerLocal.Z + dirZ * distance),
		Balance.Arena.size
	)
end

function BossService.Spawn(slot: number, player: Player, bossKey: string, health: number, playerLocal: Vector3): boolean
	local def = Bosses.ByKey[bossKey]
	if not def then
		warn(`[BossService] Неизвестный босс "{bossKey}"`)
		return false
	end

	local state: State = {
		slot = slot,
		player = player,
		def = def,

		position = spawnPosition(playerLocal),
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

		fields = {},
		--[[
			Свой генератор на боссфайт: ядовитые лужи должны ложиться
			по-разному от забега к забегу, но не тянуть общий Random,
			от которого зависит расстановка колонн и роллы яиц.
		]]
		rng = RNG.new(os.clock() * 1000 % 2147483647),
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
