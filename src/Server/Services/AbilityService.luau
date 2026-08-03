--!strict
--[[
	AbilityService — способности игрока в бою (раздел 3.4 ТЗ).

	Логика формы (shape) написана здесь ровно один раз. Сама способность —
	строка данных в Config/Abilities: чтобы добавить седьмую способность,
	этот файл трогать не нужно.

	Формы в M2:
		Orbit      орбы вращаются вокруг игрока и бьют то, что задевают
		Projectile снаряды летят в ближайших врагов, пробивают насквозь
		Aura       постоянный круг вокруг игрока, урон по кулдауну
		Nova       вспышка от игрока на весь радиус разом

	Урон, цели и убийства считает только сервер. На клиент уходит лишь то,
	что нельзя вывести из состояния: рождение снаряда и момент вспышки.
	Орбиты и ауры клиент рисует сам — их положение полностью определяется
	уровнем способности и фазой, которые и так есть в снимке для HUD.

	Бонус питомца к своей стихии (раздел 6 ТЗ) снимается один раз, при выдаче
	способности, и лежит в её runtime множителем. Считать его в цикле боя было
	бы и лишней работой, и лишним поводом однажды забыть про него в одной
	из форм: множитель применяется там же, где берётся урон уровня.

	Публичный API:
		AbilityService.StartRun(slot, player, loadout)
		AbilityService.StopRun(slot)
		AbilityService.Grant(slot, key)        -> boolean
		AbilityService.LevelUp(slot, key)      -> boolean
		AbilityService.GetViews(slot)          -> { AbilityView }
		AbilityService.CanTakeMore(slot)       -> boolean
		AbilityService.Tick(slot, dt, playerLocal)
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Abilities = require(Shared.Config.Abilities)
local Balance = require(Shared.Config.Balance)
local BossService = require(script.Parent.BossService)
local EnemyService = require(script.Parent.EnemyService)
local Net = require(Shared.Net)
local Types = require(Shared.Types)

type AbilityDef = Types.AbilityDef
type AbilityView = Types.AbilityView

type Runtime = {
	def: AbilityDef,
	level: number,
	timer: number,
	phase: number,
	-- Множители от питомца и талантов: 1, если стихия способности им чужая.
	-- Кулдаун меньше единицы означает «срабатывает чаще».
	damageMult: number,
	cooldownMult: number,
	damage: number, -- накопленный урон за забег, для HUD и экрана результатов
	-- Когда этот враг последний раз получал урон именно от этой способности.
	-- Нужно формам с постоянным контактом (Orbit), см. tickOrbit.
	hitTimes: { [number]: number },
}

type Sim = {
	slot: number,
	player: Player,
	abilities: { Runtime },
	byKey: { [string]: Runtime },

	-- Бонусы питомца и талантов к стихиям, снятые на входе в бой. Поменяться
	-- за забег они не могут: ни питомца, ни дерево в бою не тронуть.
	elementDamage: { [Types.Element]: number },
	elementCooldown: { [Types.Element]: number },

	-- Снаряды: те же плоские массивы, что и у врагов, только меньше.
	projPosition: { Vector3 },
	projDirection: { Vector3 },
	projSpeed: { number },
	projDamage: { number },
	projPierce: { number },
	projLife: { number },
	projHitRadius: { number },
	projLastHit: { number },
	projOwner: { Runtime? }, -- какой способности засчитывать урон снаряда
	projAlive: { boolean },
	projFree: { number },
	projFreeCount: number,
	projHighWater: number,

	targets: { number },
	hits: { number },
	fxQueue: { { x: number, z: number, dx: number, dz: number } },
}

local AbilityService = {}

local CAPACITY = Balance.Combat.maxProjectiles

local sims: { [number]: Sim } = {}
local fxRemote: UnreliableRemoteEvent? = nil

local function allocateProjectile(sim: Sim): number?
	if sim.projFreeCount == 0 then
		return nil
	end
	local id = sim.projFree[sim.projFreeCount]
	sim.projFreeCount -= 1
	if id > sim.projHighWater then
		sim.projHighWater = id
	end
	return id
end

local function releaseProjectile(sim: Sim, id: number): ()
	sim.projAlive[id] = false
	sim.projFreeCount += 1
	sim.projFree[sim.projFreeCount] = id
end

--[[
	Ключ босса в таблице hitTimes. Id врагов начинаются с единицы, поэтому ноль
	свободен — отдельная таблица под одну запись была бы лишней сущностью.
]]
local BOSS_HIT_KEY = 0

--[[
	Урон боссу от области способности.

	Босс проверяется отдельным вызовом, а не живёт в общих массивах врагов:
	массивы там ради сотен сущностей, а босс на арене один. Но путь урона общий
	с врагами по форме — если бы у босса был свой, половина форм однажды
	перестала бы его задевать.
]]
local function damageBoss(sim: Sim, runtime: Runtime, position: Vector3, radius: number, damage: number): ()
	if not BossService.CollectHit(sim.slot, position, radius) then
		return
	end
	local _, dealt = BossService.Damage(sim.slot, damage)
	runtime.damage += dealt
end

local function sendFx(sim: Sim, kind: string, key: string, count: number): ()
	local remote = fxRemote
	if not remote or count == 0 then
		return
	end

	local payload = table.create(count)
	for index = 1, count do
		local entry = sim.fxQueue[index]
		payload[index] = { x = entry.x, z = entry.z, dx = entry.dx, dz = entry.dz }
	end

	remote:FireClient(sim.player, kind, key, payload)
end

--[[
	Orbit — орбы вращаются вокруг игрока и бьют то, чего касаются.

	Изначально урон наносился раз в cooldown секунд по текущему положению орба,
	и это было неправильно: за полсекунды орб проходит по дуге десяток стадов,
	а радиус поражения у него три. Между замерами он телепортировался сквозь
	толпу и попадал только по тем, кто случайно оказался под ним в момент замера.

	Правильно так, как это устроено в жанре: контакт проверяется каждый кадр,
	а cooldown становится задержкой ПОВТОРНОГО удара по тому же врагу.
	Тогда орб реально косит всех, кого задевает, но не превращается
	в бесконечный урон в упор.
]]
local function tickOrbit(sim: Sim, runtime: Runtime, dt: number, playerLocal: Vector3, now: number): ()
	local data = runtime.def.levels[runtime.level]
	local count = data.count :: number
	local radius = data.radius :: number
	local hitRadius = data.hitRadius :: number
	-- У Orbit cooldown — это задержка ПОВТОРНОГО удара по тому же врагу,
	-- поэтому множитель кулдауна здесь ускоряет именно её.
	local repeatDelay = data.cooldown * runtime.cooldownMult
	local damage = data.damage * runtime.damageMult
	local hitTimes = runtime.hitTimes

	runtime.phase = (runtime.phase + (data.angularSpeed :: number) * dt) % (math.pi * 2)

	local step = math.pi * 2 / count
	for index = 0, count - 1 do
		local angle = runtime.phase + step * index
		local orb = playerLocal + Vector3.new(math.cos(angle), 0, math.sin(angle)) * radius

		-- У босса своя отметка повторного удара: он один, а орбов несколько,
		-- и без неё каждый орб бил бы его каждый кадр.
		local lastBossHit = hitTimes[BOSS_HIT_KEY]
		if lastBossHit == nil or now - lastBossHit >= repeatDelay then
			if BossService.CollectHit(sim.slot, orb, hitRadius) then
				hitTimes[BOSS_HIT_KEY] = now
				damageBoss(sim, runtime, orb, hitRadius, damage)
			end
		end

		local hits = EnemyService.CollectHits(sim.slot, orb, hitRadius, sim.hits)
		for hitIndex = 1, hits do
			local enemyId = sim.hits[hitIndex]
			local last = hitTimes[enemyId]
			if last == nil or now - last >= repeatDelay then
				hitTimes[enemyId] = now
				local _, dealt = EnemyService.Damage(sim.slot, enemyId, damage)
				runtime.damage += dealt
			end
		end
	end
end

-- Aura — постоянный круг вокруг игрока, урон по всем внутри по кулдауну.
local function tickAura(sim: Sim, runtime: Runtime, playerLocal: Vector3): ()
	local data = runtime.def.levels[runtime.level]
	local damage = data.damage * runtime.damageMult
	local radius = data.radius :: number
	local hits = EnemyService.CollectHits(sim.slot, playerLocal, radius, sim.hits)
	for index = 1, hits do
		local _, dealt = EnemyService.Damage(sim.slot, sim.hits[index], damage)
		runtime.damage += dealt
	end
	damageBoss(sim, runtime, playerLocal, radius, damage)
end

-- Nova — то же по геометрии, но разовая вспышка, и клиент рисует волну.
local function tickNova(sim: Sim, runtime: Runtime, playerLocal: Vector3): ()
	local data = runtime.def.levels[runtime.level]
	local damage = data.damage * runtime.damageMult
	local radius = data.radius :: number
	local hits = EnemyService.CollectHits(sim.slot, playerLocal, radius, sim.hits)
	for index = 1, hits do
		local _, dealt = EnemyService.Damage(sim.slot, sim.hits[index], damage)
		runtime.damage += dealt
	end
	damageBoss(sim, runtime, playerLocal, radius, damage)

	sim.fxQueue[1] = { x = playerLocal.X, z = playerLocal.Z, dx = 0, dz = 0 }
	sendFx(sim, "Nova", runtime.def.key, 1)
end

--[[
	Projectile — залп в ближайших врагов. Если целей меньше, чем снарядов,
	лишние летят веером, а не пропадают: способность не должна простаивать
	из-за того, что рядом один враг.
]]
local function fireProjectiles(sim: Sim, runtime: Runtime, playerLocal: Vector3): ()
	local data = runtime.def.levels[runtime.level]
	local count = data.count :: number

	local found =
		EnemyService.FindNearest(sim.slot, playerLocal, Balance.Combat.abilitySearchRadius, count, sim.targets)
	if found == 0 then
		return
	end

	local queued = 0
	local spread = math.pi / 9

	for index = 1, count do
		local id = allocateProjectile(sim)
		if not id then
			break
		end

		local direction: Vector3
		local targetPosition = EnemyService.GetPosition(sim.slot, sim.targets[math.min(index, found)])
		if targetPosition then
			local delta = targetPosition - playerLocal
			local length = math.sqrt(delta.X * delta.X + delta.Z * delta.Z)
			direction = if length > 1e-4
				then Vector3.new(delta.X / length, 0, delta.Z / length)
				else Vector3.new(1, 0, 0)
		else
			direction = Vector3.new(1, 0, 0)
		end

		-- Снаряды сверх числа целей расходятся веером от направления на цель.
		if index > found then
			local offset = (index - found) * spread * (if index % 2 == 0 then 1 else -1)
			local cos, sin = math.cos(offset), math.sin(offset)
			direction = Vector3.new(direction.X * cos - direction.Z * sin, 0, direction.X * sin + direction.Z * cos)
		end

		sim.projPosition[id] = playerLocal
		sim.projDirection[id] = direction
		sim.projSpeed[id] = data.speed :: number
		sim.projDamage[id] = data.damage * runtime.damageMult
		sim.projPierce[id] = data.pierce :: number
		sim.projLife[id] = data.lifetime :: number
		sim.projHitRadius[id] = data.hitRadius :: number
		sim.projLastHit[id] = 0
		sim.projOwner[id] = runtime
		sim.projAlive[id] = true

		queued += 1
		sim.fxQueue[queued] = { x = playerLocal.X, z = playerLocal.Z, dx = direction.X, dz = direction.Z }
	end

	sendFx(sim, "Projectile", runtime.def.key, queued)
end

local function stepProjectiles(sim: Sim, dt: number): ()
	for id = 1, sim.projHighWater do
		if sim.projAlive[id] then
			local life = sim.projLife[id] - dt
			if life <= 0 then
				releaseProjectile(sim, id)
				continue
			end
			sim.projLife[id] = life

			local position = sim.projPosition[id] + sim.projDirection[id] * (sim.projSpeed[id] * dt)
			sim.projPosition[id] = position

			--[[
				Босс проверяется первым и снимает пробойность так же, как враг:
				снаряд с pierce = 3 обязан застревать в боссе, а не пролетать
				сквозь него, потому что тот не лежит в общих массивах.
			]]
			local owner = sim.projOwner[id]
			if owner and BossService.CollectHit(sim.slot, position, sim.projHitRadius[id]) then
				local _, dealt = BossService.Damage(sim.slot, sim.projDamage[id])
				owner.damage += dealt

				local pierce = sim.projPierce[id] - 1
				sim.projPierce[id] = pierce
				if pierce <= 0 then
					releaseProjectile(sim, id)
					continue
				end
			end

			local hits = EnemyService.CollectHits(sim.slot, position, sim.projHitRadius[id], sim.hits)
			for index = 1, hits do
				local enemyId = sim.hits[index]
				-- Один враг за тик, и не тот же самый, что в прошлый: иначе снаряд
				-- с pierce = 3 выжигал бы всю пробойность об одну цель.
				if enemyId ~= sim.projLastHit[id] then
					local _, dealt = EnemyService.Damage(sim.slot, enemyId, sim.projDamage[id])
					if owner then
						owner.damage += dealt
					end
					sim.projLastHit[id] = enemyId

					local pierce = sim.projPierce[id] - 1
					sim.projPierce[id] = pierce
					if pierce <= 0 then
						releaseProjectile(sim, id)
					end
					break
				end
			end
		end
	end
end

function AbilityService.Tick(slot: number, dt: number, playerLocal: Vector3): ()
	local sim = sims[slot]
	if not sim then
		return
	end

	local now = os.clock()

	for _, runtime in sim.abilities do
		local data = runtime.def.levels[runtime.level]
		local shape = runtime.def.shape

		-- У Orbit нет «срабатывания»: он бьёт постоянным контактом,
		-- поэтому кулдаун у него означает совсем другое (см. tickOrbit).
		if shape == "Orbit" then
			tickOrbit(sim, runtime, dt, playerLocal, now)
			continue
		end

		runtime.timer -= dt
		local fired = runtime.timer <= 0
		if fired then
			runtime.timer += data.cooldown * runtime.cooldownMult
		end

		if fired then
			if shape == "Aura" then
				tickAura(sim, runtime, playerLocal)
			elseif shape == "Nova" then
				tickNova(sim, runtime, playerLocal)
			elseif shape == "Projectile" then
				fireProjectiles(sim, runtime, playerLocal)
			end
		end
	end

	stepProjectiles(sim, dt)
end

function AbilityService.Grant(slot: number, key: string): boolean
	local sim = sims[slot]
	if not sim or sim.byKey[key] then
		return false
	end
	if #sim.abilities >= Balance.Progression.maxActiveAbilities then
		return false
	end

	local def = Abilities.ByKey[key]
	if not def then
		return false
	end

	local cooldownMult = sim.elementCooldown[def.element] or 1

	local runtime: Runtime = {
		def = def,
		level = 1,
		timer = def.levels[1].cooldown * cooldownMult,
		phase = 0,
		-- Множители снимаются здесь, а не при каждом ударе: за забег они
		-- не меняются, а забыть про бонус в одной из форм — легко.
		damageMult = sim.elementDamage[def.element] or 1,
		cooldownMult = cooldownMult,
		damage = 0,
		hitTimes = {},
	}
	table.insert(sim.abilities, runtime)
	sim.byKey[key] = runtime
	return true
end

function AbilityService.LevelUp(slot: number, key: string): boolean
	local sim = sims[slot]
	if not sim then
		return false
	end

	local runtime = sim.byKey[key]
	if not runtime or runtime.level >= #runtime.def.levels then
		return false
	end

	runtime.level += 1
	return true
end

function AbilityService.GetViews(slot: number): { AbilityView }
	local sim = sims[slot]
	if not sim then
		return {}
	end

	local views: { AbilityView } = table.create(#sim.abilities)
	for index, runtime in sim.abilities do
		-- У Orbit кулдаун не показываем: он не «перезаряжается», а бьёт постоянно,
		-- и затемнение иконки означало бы неправду.
		local isOrbit = runtime.def.shape == "Orbit"
		views[index] = {
			key = runtime.def.key,
			level = runtime.level,
			cooldown = if isOrbit then 0 else math.max(runtime.timer, 0),
			-- С множителем: иначе иконка в HUD затемнялась бы по «бумажному»
			-- кулдауну и расходилась бы с тем, как способность реально бьёт.
			maxCooldown = if isOrbit then 0 else runtime.def.levels[runtime.level].cooldown * runtime.cooldownMult,
			phase = runtime.phase,
			damage = math.floor(runtime.damage),
		}
	end
	return views
end

function AbilityService.CanTakeMore(slot: number): boolean
	local sim = sims[slot]
	if not sim then
		return false
	end
	return #sim.abilities < Balance.Progression.maxActiveAbilities
end

function AbilityService.GetLevel(slot: number, key: string): number
	local sim = sims[slot]
	if not sim then
		return 0
	end
	local runtime = sim.byKey[key]
	return if runtime then runtime.level else 0
end

--[[
	Начало забега. Стартовую способность задаёт питомец (раздел 6 ТЗ), поэтому
	сюда приходит весь его лоадаут целиком, а не один ключ: бонус к стихии
	нужен ровно тогда же, когда и способность.
]]
function AbilityService.StartRun(slot: number, player: Player, loadout: Types.RunLoadout): ()
	local sim: Sim = {
		slot = slot,
		player = player,
		abilities = {},
		byKey = {},

		elementDamage = loadout.elementDamage,
		elementCooldown = loadout.elementCooldown,

		projPosition = table.create(CAPACITY, Vector3.zero),
		projDirection = table.create(CAPACITY, Vector3.zero),
		projSpeed = table.create(CAPACITY, 0),
		projDamage = table.create(CAPACITY, 0),
		projPierce = table.create(CAPACITY, 0),
		projLife = table.create(CAPACITY, 0),
		projHitRadius = table.create(CAPACITY, 0),
		projLastHit = table.create(CAPACITY, 0),
		projOwner = table.create(CAPACITY, nil :: Runtime?),
		projAlive = table.create(CAPACITY, false),
		projFree = table.create(CAPACITY, 0),
		projFreeCount = CAPACITY,
		projHighWater = 0,

		targets = {},
		hits = {},
		fxQueue = {},
	}

	for index = 1, CAPACITY do
		sim.projFree[index] = CAPACITY - index + 1
	end

	sims[slot] = sim
	AbilityService.Grant(slot, loadout.starterAbility)
end

function AbilityService.StopRun(slot: number): ()
	sims[slot] = nil
end

function AbilityService.Init(): ()
	fxRemote = Net.GetUnreliable(Net.Id.AbilityFx)
end

return AbilityService
