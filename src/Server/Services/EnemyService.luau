--!strict
--[[
	EnemyService — симуляция врагов (раздел 3 ТЗ). Сердце игры.

	Враги на сервере — НЕ Instance, а записи в плоских массивах (Structure of Arrays).
	id врага — это индекс в массивах, освобождённые id переиспользуются через free-list.
	Никаких table.remove в горячем цикле, никаких Humanoid, никаких Script на врага.

	Один Heartbeat на весь сервер (а не на арену, как предлагало ТЗ): при восьми
	аренах восемь подписок дают лишние накладные расходы на ровном месте,
	а поведение получается идентичное.

	Шаг симуляции фиксированный (1/30 с) и накапливается аккумулятором, поэтому
	результат не зависит от FPS сервера. Больше maxStepsPerFrame шагов за кадр
	не делаем — иначе просадка порождает спираль смерти.

	Позиции хранятся В ЛОКАЛЬНЫХ координатах арены (Y всегда 0). Мировая позиция
	получается прибавлением origin арены. Так числа остаются маленькими,
	а математика — чистой и готовой к переносу в parallel Luau.

	Публичный API:
		EnemyService.StartRun(slot, player, origin, seed, stage?)
		EnemyService.StopRun(slot)
		EnemyService.Damage(slot, id, amount)              -> boolean  (true = убит)
		EnemyService.Collect(slot, localPosition, radius, out) -> count
		EnemyService.GetAliveCount(slot)                   -> number
		EnemyService.GetRunTime(slot)                      -> number
		EnemyService.SetContactHandler(fn)                 -- урон игроку от касания
		EnemyService.SetSpawnEnabled(slot, enabled)        -- конец фазы выживания
		EnemyService.SetSweeping(slot, sweeping)           -- стягивание оставшихся
		EnemyService.ClearAll(slot)                        -> number   (убрано молча)
		EnemyService.Buff(slot, position, radius, seconds) -> count    (поле босса)
		EnemyService.FireShot(slot, from, toward, ranged)  -> boolean  (стрелок босса)
		EnemyService.GetObstacles(slot)                    -> { ArenaLayout.Obstacle }
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local ArenaLayout = require(Shared.Util.ArenaLayout)
local Balance = require(Shared.Config.Balance)
local Enemies = require(Shared.Config.Enemies)
local EnemyMotion = require(Shared.Util.EnemyMotion)
local Net = require(Shared.Net)
local Packet = require(Shared.Util.Packet)
local RNG = require(Shared.Util.RNG)
local SpatialHash = require(Shared.Util.SpatialHash)
local Types = require(Shared.Types)
local Waves = require(Shared.Config.Waves)

type EnemyDef = Types.EnemyDef

type Sim = {
	slot: number,
	player: Player,
	origin: Vector3,
	rng: RNG.RNG,
	hash: SpatialHash.SpatialHash,

	time: number,
	accumulator: number,
	paused: boolean, -- забег на паузе из-за выбора карточки левел-апа

	--[[
		Масштаб от номера сюжетного уровня (раздел 5.1 ТЗ). В бесконечном режиме
		все три равны единице. Множители лежат в симуляции, а не применяются
		к таблице врагов: Config/Enemies один на все уровни и правиться от
		номера уровня не должен.
	]]
	healthMult: number,
	damageMult: number,
	speedMult: number,

	--[[
		Расписание врагов уровня: кто и с какой секунды. Пустое означает
		«локации нет» (бесконечный режим) — тогда состав берётся из волн.

		activeTypes — уже введённые в бой ключи, курсор идёт по schedule
		вперёд и никогда не возвращается: время забега не убывает.
	]]
	enemySchedule: { Types.StageEnemy },
	activeTypes: { string },
	activeCount: number,
	scheduleCursor: number,

	--[[
		Сколько стрелков сейчас на арене. Считается отдельно от общего числа
		живых: у них свой потолок, и перебирать ради него всех врагов каждый
		спавн было бы дороже, чем держать счётчик.
	]]
	rangedAlive: number,

	--[[
		Стрелки (архетип Ranged). Кулдаун — по id врага, а снаряды лежат
		в собственных плоских массивах: их единицы, но заводить под них
		Instance или таблицу на штуку незачем — схема та же, что у врагов
		и у снарядов способностей.
	]]
	shootCooldown: { number },
	shotPosition: { Vector3 },
	shotDirection: { Vector3 },
	shotDamage: { number },
	shotSpeed: { number },
	shotHitRadius: { number },
	shotLife: { number },
	shotDelay: { number },
	shotAlive: { boolean },
	shotFree: { number },
	shotFreeCount: number,
	shotHighWater: number,
	shotQueue: { { x: number, z: number, dx: number, dz: number, delay: number, speed: number, life: number } },

	--[[
		Спавн выключается в конце фазы выживания: босс выходит на пустую арену
		(решение владельца). Пока spawnEnabled = false, новых врагов не появляется.
	]]
	spawnEnabled: boolean,

	--[[
		Фаза добивания. Оставшиеся стягиваются к игроку с повышенной скоростью,
		иначе один враг, застрявший за колонной, подвесил бы забег навсегда.
	]]
	sweeping: boolean,

	-- Structure of Arrays
	positions: { Vector3 },
	nextPositions: { Vector3 },
	hp: { number },
	-- Здоровье при спавне. Нужно только затем, чтобы клиент мог нарисовать
	-- полоску: доля считается при упаковке ресинка, а не хранится отдельно.
	maxHp: { number },
	typeId: { number },
	phase: { number },
	alive: { boolean },
	--[[
		Сколько секунд врагу осталось быть усиленным полем босса. Ноль или
		отсутствие — обычный враг.

		Усиленный неуязвим и бежит с абсолютной скоростью (не множителем):
		она задана долей от базовой скорости игрока и не зависит от того,
		кого именно усилили, — иначе слизень и гоблин удирали бы по-разному
		от одного и того же поля.
	]]
	buffLeft: { number },

	freeList: { number },
	freeCount: number,
	highWater: number,
	aliveCount: number,

	-- Волны
	waveIndex: number,
	spawnCredit: number,
	cullTimer: number,

	-- Репликация. События лежат ОДНИМ потоком в порядке возникновения:
	-- id умерших переиспользуются сразу, и перестановка спавнов со смертями
	-- ломала бы соответствие id врагу на клиенте.
	eventTimer: number,
	eventKinds: { number },
	eventIds: { number },
	eventAux: { number },
	eventX: { number },
	eventZ: { number },
	eventCount: number,
	resyncCursor: number,
	resyncCredit: number,
	resyncIds: { number },

	-- Колонны арены: статичные круги, из которых врагов выталкивает.
	-- Хеш строится один раз при старте забега — препятствия не двигаются.
	obstacleHash: SpatialHash.SpatialHash,
	obstaclePositions: { Vector3 },
	obstacleRadii: { number },
	obstacleQueryRadius: number,
	-- Тот же набор целиком: у колонны есть ещё и высота, а её просит
	-- BossService, чтобы посадить стрелка на верхушку.
	obstacleList: { ArenaLayout.Obstacle },

	-- Переиспользуемые буферы под запросы к хешам
	neighbours: { number },
	obstacleHits: { number },
}

local EnemyService = {}

-- Ёмкость массивов: потолок живых из таблицы волн плюс запас на кадр смерти.
local CAPACITY = (function(): number
	local maxAlive = 0
	for _, wave in Waves do
		maxAlive = math.max(maxAlive, wave.maxAlive)
	end
	return maxAlive + 100
end)()

-- Самый крупный враг: по нему считается радиус поиска касаний.
local maxEnemyRadius = (function(): number
	local largest = 0
	for _, def in Enemies.List do
		largest = math.max(largest, def.stats.radius)
	end
	return largest
end)()

local sims: { [number]: Sim } = {}
local contactHandler: ((player: Player, damage: number) -> ())? = nil
local deathHandler: ((slot: number, player: Player, position: Vector3, xp: number) -> ())? = nil

local eventsRemote: RemoteEvent? = nil
local resyncRemote: UnreliableRemoteEvent? = nil
local shotsRemote: UnreliableRemoteEvent? = nil

local function getPlayerLocalPosition(sim: Sim): Vector3?
	local character = sim.player.Character
	if not character then
		return nil
	end
	local root = character:FindFirstChild("HumanoidRootPart") :: BasePart?
	if not root then
		return nil
	end
	local world = root.Position - sim.origin
	return Vector3.new(world.X, 0, world.Z)
end

local function currentWave(sim: Sim): Types.WaveEntry
	local index = sim.waveIndex
	while index < #Waves and Waves[index + 1].time <= sim.time do
		index += 1
	end
	sim.waveIndex = index
	return Waves[index]
end

local function allocate(sim: Sim): number?
	if sim.freeCount == 0 then
		return nil
	end
	local id = sim.freeList[sim.freeCount]
	sim.freeCount -= 1
	if id > sim.highWater then
		sim.highWater = id
	end
	return id
end

local function pushEvent(sim: Sim, kind: number, id: number, aux: number, x: number, z: number): ()
	local index = sim.eventCount + 1
	sim.eventCount = index
	sim.eventKinds[index] = kind
	sim.eventIds[index] = id
	sim.eventAux[index] = aux
	sim.eventX[index] = x
	sim.eventZ[index] = z
end

local function release(sim: Sim, id: number, reason: number): ()
	sim.alive[id] = false
	sim.aliveCount -= 1

	-- Стрелки считаются отдельно: у них свой потолок присутствия на арене.
	if Enemies.List[sim.typeId[id]].ranged then
		sim.rangedAlive -= 1
	end
	sim.freeCount += 1
	sim.freeList[sim.freeCount] = id

	pushEvent(sim, Packet.Kind.Despawn, id, reason, 0, 0)
end

--[[
	Появление одного врага вокруг точки center на расстоянии radius.

	Обычный спавн зовёт это с позицией игрока и большим радиусом — «по окружности
	чуть больше видимой области, никогда в кадре». Призыв босса зовёт с позицией
	босса и маленьким: призванные обязаны появиться рядом с ним, иначе призыв
	не читается как его действие.
]]
local function spawnOne(sim: Sim, def: EnemyDef, center: Vector3, radius: number): ()
	local id = allocate(sim)
	if not id then
		return
	end

	local direction = sim.rng.NextUnitVector()
	local position = EnemyMotion.ClampToArena(center + direction * radius, Balance.Arena.size)

	sim.positions[id] = position
	sim.nextPositions[id] = position
	local health = def.stats.health * sim.healthMult
	sim.hp[id] = health
	sim.maxHp[id] = health

	--[[
		Кулдаун выстрела сбрасывается при спавне обязательно: id
		переиспользуются, и новый стрелок унаследовал бы остаток от предыдущего
		владельца этого id — то есть выстрелил бы сразу, едва появившись.
	]]
	if def.ranged then
		sim.shootCooldown[id] = def.ranged.cooldown
	end
	sim.typeId[id] = def.typeId
	sim.phase[id] = sim.rng.NextNumber(0, 6.28)
	--[[
		Усиление снимается на спавне по той же причине, что и кулдаун выстрела:
		id переиспользуются, и новорождённый гоблин унаследовал бы остаток
		неуязвимости от того, кто умер под этим номером.
	]]
	sim.buffLeft[id] = 0
	sim.alive[id] = true
	sim.aliveCount += 1
	if def.ranged then
		sim.rangedAlive += 1
	end

	pushEvent(sim, Packet.Kind.Spawn, id, def.typeId, position.X, position.Z)
end

--[[
	Из кого спавнить прямо сейчас. Возвращает список и сколько его первых
	элементов разрешено брать.

	Состав врагов — вторая половина усложнения уровня по времени (первая —
	плотность): минуту идут только самые слабые типы локации, дальше
	расписание вводит следующие. Список локации отсортирован от слабого
	к сильному, поэтому «первые N» — это и есть постепенное усложнение.

	Забег без локации (бесконечный режим) берёт состав прямо из расписания.
	Отдельная функция, а не две строки на месте, потому что мест два —
	обычный спавн и призыв босса, — и разъехаться им нельзя.
]]
local function currentTypes(sim: Sim, wave: Types.WaveEntry): ({ string }, number)
	if #sim.enemySchedule == 0 then
		return wave.types, #wave.types
	end

	--[[
		Курсор идёт вперёд по расписанию, пока очередной враг не окажется
		в будущем. Расписание отсортировано по времени, время забега не убывает,
		поэтому за весь забег этот цикл суммарно сделает столько шагов, сколько
		в расписании записей.
	]]
	while sim.scheduleCursor <= #sim.enemySchedule do
		local entry = sim.enemySchedule[sim.scheduleCursor]
		if entry.fromSeconds > sim.time then
			break
		end
		sim.activeCount += 1
		sim.activeTypes[sim.activeCount] = entry.key
		sim.scheduleCursor += 1
	end

	return sim.activeTypes, sim.activeCount
end

--[[
	Свободный слот под вражеский снаряд.

	Свободный список, как у врагов и у снарядов способностей: снарядов
	стрелков на арене единицы, но выделять таблицу на каждый выстрел ради
	этого всё равно незачем.
]]
local function allocateShot(sim: Sim): number?
	if sim.shotFreeCount > 0 then
		local id = sim.shotFree[sim.shotFreeCount]
		sim.shotFreeCount -= 1
		return id
	end

	if sim.shotHighWater >= Balance.Combat.maxEnemyShots then
		return nil
	end

	sim.shotHighWater += 1
	return sim.shotHighWater
end

local function releaseShot(sim: Sim, id: number): ()
	sim.shotAlive[id] = false
	sim.shotFreeCount += 1
	sim.shotFree[sim.shotFreeCount] = id
end

--[[
	Потолок стрелков на арене прямо сейчас.

	Доля от текущего потолка живых, зажатая снизу и сверху: четверо в начале
	забега и десять к концу. Растёт вместе с толпой, но не превращает бой
	в град стрел.
]]
local function rangedLimit(wave: Types.WaveEntry): number
	local numbers = Balance.Combat
	return math.clamp(math.floor(wave.maxAlive * numbers.rangedShare + 0.5), numbers.rangedMin, numbers.rangedMax)
end

--[[
	Кого спавнить из активного набора.

	Обычно это случайный тип, но у стрелков есть свой потолок: когда он выбран,
	выбор смещается на следующий тип по кругу, а не отменяет спавн вовсе —
	иначе к концу забега арена пустела бы каждый раз, когда роллом выпадал
	стрелок. Обход по кругу конечен: типов единицы.
]]
local function pickSpawnType(sim: Sim, types: { string }, count: number, wave: Types.WaveEntry): EnemyDef?
	if count <= 0 then
		return nil
	end

	local start = sim.rng.NextInteger(1, count)
	local limit = rangedLimit(wave)

	for offset = 0, count - 1 do
		local def = Enemies.ByKey[types[(start + offset - 1) % count + 1]]
		if def and (not def.ranged or sim.rangedAlive < limit) then
			return def
		end
	end

	return nil
end

local function spawnStep(sim: Sim, dt: number, playerLocal: Vector3): ()
	-- Конец фазы выживания: новых врагов больше не появляется, арена
	-- расчищается под боссфайт.
	if not sim.spawnEnabled then
		sim.spawnCredit = 0
		return
	end

	local wave = currentWave(sim)
	if sim.aliveCount >= wave.maxAlive then
		sim.spawnCredit = 0
		return
	end

	sim.spawnCredit += wave.spawnRate * dt

	local types, count = currentTypes(sim, wave)
	-- Никого ещё не ввели в бой: спавнить нечего, и выбирать случайного
	-- из пустого набора нельзя.
	if count == 0 then
		sim.spawnCredit = 0
		return
	end

	while sim.spawnCredit >= 1 and sim.aliveCount < wave.maxAlive do
		sim.spawnCredit -= 1
		local def = pickSpawnType(sim, types, count, wave)
		if def then
			spawnOne(sim, def, playerLocal, Balance.Combat.spawnRadius)
		end
	end
end

--[[
	Спавн конкретного типа в точке — разделение Splitter при смерти.

	Отдельно от SpawnBurst: тот берёт случайного из текущего набора уровня,
	а здесь тип известен заранее и случайность не нужна вовсе.

	Потолок живых соблюдается: мега-слизень, лопнувший на переполненной арене,
	не должен пробивать ограничение, на котором держится производительность.
]]
local function spawnSplit(sim: Sim, split: Types.EnemySplit, position: Vector3): ()
	local def = Enemies.ByKey[split.key]
	if not def then
		warn(`[EnemyService] Неизвестный враг деления "{split.key}"`)
		return
	end

	local wave = currentWave(sim)
	for _ = 1, split.count do
		if sim.aliveCount >= wave.maxAlive then
			break
		end
		-- Радиус разлёта — по размеру самого потомка: иначе половинки
		-- рождаются внутри друг друга и первым делом расталкиваются.
		spawnOne(sim, def, position, def.stats.radius * 2)
	end
end

--[[
	Призыв пачки врагов вокруг точки — атака Summon у босса.

	Потолок живых соблюдается: призыв не должен пробивать ограничение,
	на котором держится производительность.
]]
function EnemyService.SpawnBurst(slot: number, center: Vector3, count: number, radius: number, key: string?): number
	local sim = sims[slot]
	if not sim then
		return 0
	end

	local wave = currentWave(sim)
	local spawned = 0

	--[[
		Ключ задан — призывается именно этот враг. Так шаман зовёт своих
		гоблинов, а не случайных обитателей уровня: «призывает мечников» —
		это его характер, а не то, что подвернулось в текущей волне.
	]]
	local fixed = if key then Enemies.ByKey[key] else nil
	if key and not fixed then
		warn(`[EnemyService] Неизвестный призываемый враг "{key}"`)
		return 0
	end

	local types, typeCount = currentTypes(sim, wave)
	if not fixed and typeCount == 0 then
		return 0
	end

	for _ = 1, count do
		if sim.aliveCount >= wave.maxAlive then
			break
		end
		local def = fixed or pickSpawnType(sim, types, typeCount, wave)
		if def then
			spawnOne(sim, def, center, radius)
			spawned += 1
		end
	end

	return spawned
end

local function moveStep(sim: Sim, dt: number, playerLocal: Vector3): ()
	local positions = sim.positions
	local nextPositions = sim.nextPositions
	local alive = sim.alive
	local typeIds = sim.typeId
	local neighbours = sim.neighbours
	local hash = sim.hash

	hash.Rebuild(positions, alive, sim.highWater)

	local separationRadius = Balance.Combat.separationRadius
	local separationStrength = Balance.Combat.separationStrength
	local arenaSize = Balance.Arena.size

	--[[
		В фазе добивания оставшиеся идут к игроку заметно быстрее. Это не
		сложность, а страховка: босс ждёт пустой арены, и враг, застрявший
		в дальнем углу за колонной, иначе остановил бы забег насовсем.
	]]
	local speedMult = sim.speedMult
	if sim.sweeping then
		speedMult *= Balance.Stages.sweepSpeedMult
	end

	local buffLeft = sim.buffLeft
	local buffSpeed = Balance.Combat.playerWalkSpeed * Balance.Bosses.buffSpeedFactor

	for id = 1, sim.highWater do
		if alive[id] then
			local def = Enemies.List[typeIds[id]]
			local position = positions[id]
			local speed = def.stats.speed * speedMult

			--[[
				Усиленный бежит с АБСОЛЮТНОЙ скоростью поля, а не со своей,
				умноженной на что-то: смысл усиления в том, что от него не
				убежать, и он не должен зависеть от того, кого усилили.

				Отсчёт идёт здесь же, в шаге движения: отдельный проход по
				пяти сотням врагов ради одного вычитания не нужен.
			]]
			local remaining = buffLeft[id]
			if remaining and remaining > 0 then
				remaining -= dt
				buffLeft[id] = remaining
				if remaining > 0 then
					speed = buffSpeed
				end
			end

			--[[
				Стрелок держит дистанцию, остальные бегут вплотную. В фазе
				добивания стрелок тоже бежит: там задача не стрелять, а дойти,
				иначе он останется стоять в углу и подвесит выход босса.
			]]
			local ranged = def.ranged
			if ranged and not sim.sweeping then
				position = EnemyMotion.KeepRange(position, playerLocal, speed, dt, ranged.range, ranged.motionMargin)
			else
				position = EnemyMotion.Chase(position, playerLocal, speed, dt)
			end

			local count = hash.Collect(position, separationRadius, neighbours)
			position = EnemyMotion.Separation(
				id,
				position,
				neighbours,
				positions,
				count,
				separationRadius,
				separationStrength,
				dt
			)

			if sim.obstacleQueryRadius > 0 then
				local hits =
					sim.obstacleHash.Collect(position, sim.obstacleQueryRadius + def.stats.radius, sim.obstacleHits)
				if hits > 0 then
					position = EnemyMotion.PushOutOfObstacles(
						position,
						sim.obstacleHits,
						sim.obstaclePositions,
						sim.obstacleRadii,
						hits,
						def.stats.radius
					)
				end
			end

			nextPositions[id] = EnemyMotion.ClampToArena(position, arenaSize)
		end
	end

	-- Двойная буферизация: все читают старые позиции, пишут в новые.
	-- Так шаг детерминирован и его можно будет посчитать параллельно.
	sim.positions = nextPositions
	sim.nextPositions = positions
end

--[[
	Выстрелы стрелков.

	Порядок такой же, как у босса: сначала трассер, потом удар. Снаряд
	рождается не сразу, а через telegraph секунд — ровно столько у игрока есть,
	чтобы уйти с линии. Летит по прямой в точку, где игрок был в момент
	выстрела: самонаведение отняло бы у уклонения всякий смысл.

	Кулдаун у каждого стрелка свой и тикает даже когда он вне дистанции —
	иначе подошедший стрелок стрелял бы залпом за всё время ожидания.
]]
local function shootStep(sim: Sim, dt: number, playerLocal: Vector3): ()
	local positions = sim.positions
	local alive = sim.alive
	local typeIds = sim.typeId
	local cooldowns = sim.shootCooldown
	local queued = 0

	for id = 1, sim.highWater do
		if not alive[id] then
			continue
		end

		local ranged = Enemies.List[typeIds[id]].ranged
		if not ranged then
			continue
		end

		local remaining = (cooldowns[id] or ranged.cooldown) - dt
		if remaining > 0 then
			cooldowns[id] = remaining
			continue
		end

		local position = positions[id]
		local dx = playerLocal.X - position.X
		local dz = playerLocal.Z - position.Z
		local distance = math.sqrt(dx * dx + dz * dz)

		-- Вне дистанции не стреляет, но и кулдаун не копит: держим его
		-- на нуле, чтобы выстрел случился сразу, как игрок войдёт в радиус.
		if distance > ranged.range + ranged.motionMargin or distance < 1e-3 then
			cooldowns[id] = 0
			continue
		end

		cooldowns[id] = ranged.cooldown

		local dirX, dirZ = dx / distance, dz / distance
		local shotId = allocateShot(sim)
		if shotId then
			sim.shotPosition[shotId] = position
			sim.shotDirection[shotId] = Vector3.new(dirX, 0, dirZ)
			sim.shotDamage[shotId] = ranged.damage
			sim.shotSpeed[shotId] = ranged.speed
			sim.shotHitRadius[shotId] = ranged.hitRadius
			sim.shotLife[shotId] = ranged.lifetime
			-- Пока задержка не вышла, снаряд не летит и не бьёт: на экране
			-- в это время трассер.
			sim.shotDelay[shotId] = ranged.telegraph
			sim.shotAlive[shotId] = true
		end

		queued += 1
		sim.shotQueue[queued] = {
			x = position.X,
			z = position.Z,
			dx = dirX,
			dz = dirZ,
			delay = ranged.telegraph,
			speed = ranged.speed,
			life = ranged.lifetime,
		}
	end

	if queued > 0 then
		local remote = shotsRemote
		if remote then
			local payload = table.create(queued)
			for index = 1, queued do
				payload[index] = sim.shotQueue[index]
			end
			remote:FireClient(sim.player, payload)
		end
	end
end

--[[
	Полёт вражеских снарядов и попадание по игроку.

	Цель одна — игрок, поэтому ни хеша, ни списка целей тут не нужно:
	одна проверка расстояния на снаряд.
]]
local function shotStep(sim: Sim, dt: number, playerLocal: Vector3): ()
	local handler = contactHandler
	local reach = Balance.Combat.playerRadius

	for id = 1, sim.shotHighWater do
		if not sim.shotAlive[id] then
			continue
		end

		local delay = sim.shotDelay[id]
		if delay > 0 then
			sim.shotDelay[id] = delay - dt
			continue
		end

		local life = sim.shotLife[id] - dt
		if life <= 0 then
			releaseShot(sim, id)
			continue
		end
		sim.shotLife[id] = life

		local position = sim.shotPosition[id] + sim.shotDirection[id] * (sim.shotSpeed[id] * dt)
		sim.shotPosition[id] = position

		local dx = position.X - playerLocal.X
		local dz = position.Z - playerLocal.Z
		local hit = sim.shotHitRadius[id] + reach

		if dx * dx + dz * dz <= hit * hit then
			if handler then
				handler(sim.player, sim.shotDamage[id])
			end
			releaseShot(sim, id)
		end
	end
end

local function contactStep(sim: Sim, playerLocal: Vector3): ()
	local handler = contactHandler
	if not handler then
		return
	end

	local positions = sim.positions
	local alive = sim.alive
	local typeIds = sim.typeId
	local playerRadius = Balance.Combat.playerRadius
	local padding = Balance.Combat.contactPadding

	-- Через хеш, а не полным перебором: касание проверяется каждый тик,
	-- и лишние 300 итераций тут стоят дороже, чем сам поиск соседей.
	-- Хеш построен по позициям прошлого тика — расхождение меньше половины стада.
	local reach = playerRadius + maxEnemyRadius + padding
	local count = sim.hash.Collect(playerLocal, reach, sim.neighbours)

	-- Достаточно самого сильного касания за тик: i-frames всё равно съедят остальные.
	local worst = 0
	for index = 1, count do
		local id = sim.neighbours[index]
		if alive[id] then
			local def = Enemies.List[typeIds[id]]
			local exactReach = playerRadius + def.stats.radius + padding
			local position = positions[id]
			local dx = position.X - playerLocal.X
			local dz = position.Z - playerLocal.Z
			if dx * dx + dz * dz <= exactReach * exactReach and def.stats.damage > worst then
				worst = def.stats.damage
			end
		end
	end

	if worst > 0 then
		handler(sim.player, worst * sim.damageMult)
	end
end

local CULL_INTERVAL = 0.5

local function cullStep(sim: Sim, dt: number, playerLocal: Vector3): ()
	sim.cullTimer += dt
	if sim.cullTimer < CULL_INTERVAL then
		return
	end
	sim.cullTimer = 0

	local wave = Waves[sim.waveIndex]
	if sim.aliveCount < wave.maxAlive then
		return
	end

	-- Потолок достигнут: молча убираем самых дальних, чтобы освободить место.
	local positions = sim.positions
	local alive = sim.alive
	local cullRadius = Balance.Combat.cullRadius
	local cullRadiusSquared = cullRadius * cullRadius

	for id = 1, sim.highWater do
		if alive[id] then
			local position = positions[id]
			local dx = position.X - playerLocal.X
			local dz = position.Z - playerLocal.Z
			if dx * dx + dz * dz > cullRadiusSquared then
				release(sim, id, Packet.Reason.Culled)
			end
		end
	end
end

local function collectResync(sim: Sim, wanted: number): number
	local limit = sim.highWater
	if limit == 0 or sim.aliveCount == 0 then
		return 0
	end

	local found = 0
	local scanned = 0
	local cursor = sim.resyncCursor
	local target = math.min(wanted, sim.aliveCount)

	while found < target and scanned < limit do
		cursor += 1
		if cursor > limit then
			cursor = 1
		end
		scanned += 1
		if sim.alive[cursor] then
			found += 1
			sim.resyncIds[found] = cursor
		end
	end

	sim.resyncCursor = cursor
	return found
end

local function replicationStep(sim: Sim, dt: number): ()
	-- События спавна и смерти — надёжным каналом, пачкой раз в eventInterval.
	sim.eventTimer += dt
	if sim.eventTimer >= Balance.Combat.eventInterval then
		sim.eventTimer = 0
		if sim.eventCount > 0 then
			local remote = eventsRemote
			if remote then
				local data = Packet.WriteEvents(
					sim.eventKinds,
					sim.eventIds,
					sim.eventAux,
					sim.eventX,
					sim.eventZ,
					sim.eventCount
				)
				remote:FireClient(sim.player, data)
			end
			sim.eventCount = 0
		end
	end

	-- Круговая ресинхронизация точных позиций — ненадёжным каналом.
	sim.resyncCredit += Balance.Combat.resyncPerSecond * dt
	local wanted = math.floor(sim.resyncCredit)
	if wanted > 0 then
		sim.resyncCredit -= wanted
		local found = collectResync(sim, wanted)
		if found > 0 then
			local remote = resyncRemote
			if remote then
				remote:FireClient(
					sim.player,
					Packet.WriteResync(sim.resyncIds, sim.positions, sim.hp, sim.maxHp, found)
				)
			end
		end
	end
end

local function step(sim: Sim, dt: number): ()
	sim.time += dt

	local playerLocal = getPlayerLocalPosition(sim)
	if not playerLocal then
		return
	end

	spawnStep(sim, dt, playerLocal)
	moveStep(sim, dt, playerLocal)
	-- Выстрелы после движения: стрелок целится оттуда, где он уже стоит.
	shootStep(sim, dt, playerLocal)
	shotStep(sim, dt, playerLocal)
	contactStep(sim, playerLocal)
	cullStep(sim, dt, playerLocal)
end

local function onHeartbeat(deltaTime: number): ()
	local tickRate = Balance.Combat.tickRate
	local maxSteps = Balance.Combat.maxStepsPerFrame

	for _, sim in sims do
		if sim.paused then
			-- На паузе время забега не идёт и накопленная дельта не копится:
			-- иначе после возврата симуляция рванёт вперёд на всю паузу.
			sim.accumulator = 0
			continue
		end

		sim.accumulator += deltaTime

		local steps = 0
		while sim.accumulator >= tickRate and steps < maxSteps do
			sim.accumulator -= tickRate
			steps += 1
			step(sim, tickRate)
		end

		-- Сервер не успевает: остаток отбрасываем, иначе догоняние снежным комом.
		if sim.accumulator >= tickRate then
			sim.accumulator = 0
		end

		if steps > 0 then
			replicationStep(sim, steps * tickRate)
		end
	end
end

function EnemyService.Init(): ()
	eventsRemote = Net.GetEvent(Net.Id.EnemyEvents)
	resyncRemote = Net.GetUnreliable(Net.Id.EnemyResync)
	shotsRemote = Net.GetUnreliable(Net.Id.EnemyShots)
end

function EnemyService.Start(): ()
	RunService.Heartbeat:Connect(onHeartbeat)
end

function EnemyService.SetContactHandler(handler: (player: Player, damage: number) -> ()): ()
	contactHandler = handler
end

--[[
	Готовит статичные препятствия арены: позиции, радиусы и хеш по ним.
	Расстановка берётся из того же ArenaLayout, из которого сервер построил
	колонны, а клиент — свою копию для симуляции.
]]
local function buildObstacles(
	seed: number
): (SpatialHash.SpatialHash, { Vector3 }, { number }, number, { ArenaLayout.Obstacle })
	local layout = ArenaLayout.Generate(seed)

	local positions: { Vector3 } = {}
	local radii: { number } = {}
	local occupied: { boolean } = {}
	local maxRadius = 0

	for index, obstacle in layout do
		positions[index] = obstacle.position
		radii[index] = obstacle.radius
		occupied[index] = true
		maxRadius = math.max(maxRadius, obstacle.radius)
	end

	-- Ячейка крупнее боевой: препятствий мало и они большие.
	local hash = SpatialHash.new(Balance.Combat.cellSize * 2)
	hash.Rebuild(positions, occupied, #layout)

	return hash, positions, radii, maxRadius, layout
end

--[[
	Начало забега. stage равен nil в бесконечном режиме: тогда враги
	не масштабируются и набор берётся из расписания волн.
]]
function EnemyService.StartRun(slot: number, player: Player, origin: Vector3, seed: number, stage: Types.StageDef?): ()
	local obstacleHash, obstaclePositions, obstacleRadii, obstacleQueryRadius, obstacleList = buildObstacles(seed)

	local sim: Sim = {
		slot = slot,
		player = player,
		origin = origin,
		rng = RNG.new(seed),
		hash = SpatialHash.new(Balance.Combat.cellSize),

		time = 0,
		accumulator = 0,
		paused = false,

		healthMult = if stage then stage.enemyHealthMult else 1,
		damageMult = if stage then stage.enemyDamageMult else 1,
		speedMult = if stage then stage.enemySpeedMult else 1,
		enemySchedule = if stage then stage.enemies else {},
		activeTypes = {},
		activeCount = 0,
		scheduleCursor = 1,
		rangedAlive = 0,

		shootCooldown = {},
		shotPosition = {},
		shotDirection = {},
		shotDamage = {},
		shotSpeed = {},
		shotHitRadius = {},
		shotLife = {},
		shotDelay = {},
		shotAlive = {},
		shotFree = {},
		shotFreeCount = 0,
		shotHighWater = 0,
		shotQueue = {},

		spawnEnabled = true,
		sweeping = false,

		positions = table.create(CAPACITY, Vector3.zero),
		nextPositions = table.create(CAPACITY, Vector3.zero),
		hp = table.create(CAPACITY, 0),
		maxHp = table.create(CAPACITY, 0),
		typeId = table.create(CAPACITY, 1),
		phase = table.create(CAPACITY, 0),
		alive = table.create(CAPACITY, false),
		buffLeft = table.create(CAPACITY, 0),

		freeList = table.create(CAPACITY, 0),
		freeCount = CAPACITY,
		highWater = 0,
		aliveCount = 0,

		waveIndex = 1,
		spawnCredit = 0,
		cullTimer = 0,

		eventTimer = 0,
		eventKinds = {},
		eventIds = {},
		eventAux = {},
		eventX = {},
		eventZ = {},
		eventCount = 0,
		resyncCursor = 0,
		resyncCredit = 0,
		resyncIds = {},

		obstacleHash = obstacleHash,
		obstaclePositions = obstaclePositions,
		obstacleRadii = obstacleRadii,
		obstacleList = obstacleList,
		obstacleQueryRadius = obstacleQueryRadius,

		neighbours = {},
		obstacleHits = {},
	}

	-- Free-list заполняем в обратном порядке, чтобы id выдавались с единицы:
	-- плотные id дают компактный обход массивов.
	for index = 1, CAPACITY do
		sim.freeList[index] = CAPACITY - index + 1
	end

	sims[slot] = sim
end

--[[
	Управление фазами сюжетного забега (раздел 5.1 ТЗ).

	Босс выходит на пустую арену, поэтому фаза выживания заканчивается
	остановкой спавна, а не мгновенной зачисткой: оставшихся игрок добивает сам.
]]
function EnemyService.SetSpawnEnabled(slot: number, enabled: boolean): ()
	local sim = sims[slot]
	if sim then
		sim.spawnEnabled = enabled
		if not enabled then
			sim.spawnCredit = 0
		end
	end
end

-- Стягивание оставшихся к игроку: см. комментарий про застрявших в moveStep.
function EnemyService.SetSweeping(slot: number, sweeping: boolean): ()
	local sim = sims[slot]
	if sim then
		sim.sweeping = sweeping
	end
end

--[[
	Принудительно убрать всех живых. Последний рубеж страховки: если враг
	недостижим даже после стягивания (баг в обходе колонн, мёртвая зона),
	забег обязан продолжиться, а не зависнуть навсегда.

	Уходит причиной Culled — это исчезновение, а не убийство: ни опыта,
	ни кристаллов за него не даётся.
]]
function EnemyService.ClearAll(slot: number): number
	local sim = sims[slot]
	if not sim then
		return 0
	end

	local removed = 0
	for id = 1, sim.highWater do
		if sim.alive[id] then
			release(sim, id, Packet.Reason.Culled)
			removed += 1
		end
	end

	return removed
end

function EnemyService.StopRun(slot: number): ()
	sims[slot] = nil
end

function EnemyService.SetPaused(slot: number, paused: boolean): ()
	local sim = sims[slot]
	if sim then
		sim.paused = paused
	end
end

function EnemyService.SetDeathHandler(handler: (slot: number, player: Player, position: Vector3, xp: number) -> ()): ()
	deathHandler = handler
end

--[[
	Лечение врагов в радиусе — исцеляющее поле босса-шамана.

	Лечит до исходного здоровья и не воскрешает: мёртвый id уже свободен
	и мог быть выдан новому врагу.
]]
--[[
	Усилить всех своих в круге: неуязвимость и скорость на seconds секунд.

	Событие уходит ТЕМ ЖЕ потоком, что спавны и смерти, — иначе клиент
	получил бы усиление для id, который у него ещё не родился или уже умер.

	Повторное попадание в поле продлевает усиление, а не складывается с ним:
	враг, простоявший в поле всю его жизнь, обязан выйти оттуда усиленным
	ровно на seconds, а не на минуту.
]]
function EnemyService.Buff(slot: number, position: Vector3, radius: number, seconds: number): number
	local sim = sims[slot]
	if not sim or seconds <= 0 then
		return 0
	end

	local count = sim.hash.Collect(position, radius + maxEnemyRadius, sim.neighbours)
	local buffed = 0
	local aux = math.clamp(math.floor(seconds * Packet.BuffScale + 0.5), 1, 255)

	for index = 1, count do
		local id = sim.neighbours[index]
		if sim.alive[id] and (sim.buffLeft[id] or 0) < seconds then
			sim.buffLeft[id] = seconds
			pushEvent(sim, Packet.Kind.Buff, id, aux, 0, 0)
			buffed += 1
		end
	end

	return buffed
end

--[[
	Выстрел из точки в точку чужими руками: стрелок босса сидит на колонне,
	живёт в BossService и врагом не является вовсе, но снаряды у него те же.

	Второй системы вражеских снарядов заводить нельзя: попадание по игроку,
	трассер и потолок снарядов уже написаны здесь ровно один раз.
]]
function EnemyService.FireShot(slot: number, from: Vector3, toward: Vector3, ranged: Types.EnemyRanged): boolean
	local sim = sims[slot]
	if not sim then
		return false
	end

	local dx = toward.X - from.X
	local dz = toward.Z - from.Z
	local distance = math.sqrt(dx * dx + dz * dz)
	if distance < 1e-3 then
		return false
	end

	local shotId = allocateShot(sim)
	if not shotId then
		return false
	end

	local dirX, dirZ = dx / distance, dz / distance
	sim.shotPosition[shotId] = from
	sim.shotDirection[shotId] = Vector3.new(dirX, 0, dirZ)
	sim.shotDamage[shotId] = ranged.damage
	sim.shotSpeed[shotId] = ranged.speed
	sim.shotHitRadius[shotId] = ranged.hitRadius
	sim.shotLife[shotId] = ranged.lifetime
	sim.shotDelay[shotId] = ranged.telegraph
	sim.shotAlive[shotId] = true

	local remote = shotsRemote
	if remote then
		remote:FireClient(sim.player, {
			{
				x = from.X,
				z = from.Z,
				dx = dirX,
				dz = dirZ,
				delay = ranged.telegraph,
				speed = ranged.speed,
				life = ranged.lifetime,
			},
		})
	end

	return true
end

--[[
	Колонны арены — их читает BossService, чтобы посадить стрелка на верхушку.
	Отдаётся тот самый набор из ArenaLayout, по которому расталкиваются враги
	и который строит ArenaService: второго источника правды о том, где стоят
	колонны, быть не должно.
]]
function EnemyService.GetObstacles(slot: number): { ArenaLayout.Obstacle }
	local sim = sims[slot]
	if not sim then
		return {}
	end
	return sim.obstacleList
end

--[[
	Точка, вокруг которой врагов больше всего, — куда шаману ставить лечение.

	Не перебор всей арены: берём несколько живых врагов и считаем соседей
	у каждого. Идеального центра это не даёт, но «где толпа» определяет
	уверенно и стоит несколько запросов к хешу вместо сотен.
]]
function EnemyService.FindCluster(slot: number, radius: number, samples: number): Vector3?
	local sim = sims[slot]
	if not sim or sim.aliveCount == 0 then
		return nil
	end

	local best: Vector3? = nil
	local bestCount = 0
	local checked = 0
	local cursor = 0

	while checked < samples and cursor < sim.highWater do
		cursor += 1
		if not sim.alive[cursor] then
			continue
		end

		checked += 1
		local position = sim.positions[cursor]
		local count = sim.hash.Collect(position, radius, sim.neighbours)
		if count > bestCount then
			bestCount = count
			best = position
		end
	end

	return best
end

-- Возвращает «убит ли» и сколько урона реально прошло (для счётчика по способностям).
function EnemyService.Damage(slot: number, id: number, amount: number): (boolean, number)
	local sim = sims[slot]
	if not sim or not sim.alive[id] then
		return false, 0
	end

	--[[
		Усиленный не получает урона вовсе. Возвращается честный ноль, а не
		«урон прошёл»: счётчик урона за забег не должен считать то, чего
		не было, иначе экран результатов покажет вклад, которого нет.
	]]
	local buffed = sim.buffLeft[id]
	if buffed and buffed > 0 then
		return false, 0
	end

	local health = sim.hp[id]
	local dealt = math.min(amount, health)

	local remaining = health - amount
	if remaining > 0 then
		sim.hp[id] = remaining
		return false, dealt
	end

	local position = sim.positions[id]
	local def = Enemies.List[sim.typeId[id]]
	release(sim, id, Packet.Reason.Killed)

	-- Дроп опыта и счётчик убийств висят на этом хуке: только смерть от урона,
	-- отсечение дальних врагов по потолку награды не даёт.
	local handler = deathHandler
	if handler then
		handler(slot, sim.player, position, def.stats.xp)
	end

	--[[
		Разделение (архетип Splitter) — только здесь, то есть только при смерти
		от урона. В release по потолку живых и в ClearAll его нет намеренно:
		враг, уничтоженный ради освобождения места, не должен плодить новых.

		После хука смерти, а не до: сначала игрок получает опыт за убитого,
		потом на арене появляются потомки.
	]]
	local split = def.splitInto
	if split then
		spawnSplit(sim, split, position)
	end

	return true, dealt
end

--[[
	Враги в радиусе с учётом их собственного размера.

	Collect сравнивает расстояние между центрами, и для поиска соседей этого
	достаточно. Но для попадания способности это неверно: крупный враг радиусом
	два стада не получал урона, если его центр был чуть дальше радиуса удара,
	хотя визуально способность проходила прямо сквозь него. Здесь к радиусу
	добавляется радиус конкретного врага.
]]
function EnemyService.CollectHits(slot: number, position: Vector3, radius: number, out: { number }): number
	local sim = sims[slot]
	if not sim then
		return 0
	end

	local candidates = sim.neighbours
	local found = sim.hash.Collect(position, radius + maxEnemyRadius, candidates)

	local count = 0
	for index = 1, found do
		local id = candidates[index]
		if sim.alive[id] then
			local def = Enemies.List[sim.typeId[id]]
			local reach = radius + def.stats.radius
			local candidate = sim.positions[id]
			local dx = candidate.X - position.X
			local dz = candidate.Z - position.Z
			if dx * dx + dz * dz <= reach * reach then
				count += 1
				out[count] = id
			end
		end
	end

	return count
end

--[[
	Ближайшие к точке враги — для наведения способностей.
	Живых в радиусе обычно десятки, а нужны единицы, поэтому вместо сортировки
	идёт частичный выбор: count проходов по списку кандидатов.
]]
function EnemyService.FindNearest(
	slot: number,
	position: Vector3,
	radius: number,
	count: number,
	out: { number }
): number
	local sim = sims[slot]
	if not sim then
		return 0
	end

	local candidates = sim.neighbours
	local found = sim.hash.Collect(position, radius, candidates)
	if found == 0 then
		return 0
	end

	local wanted = math.min(count, found)
	local positions = sim.positions

	for slotIndex = 1, wanted do
		local bestIndex = slotIndex
		local best = math.huge

		for index = slotIndex, found do
			local candidate = positions[candidates[index]]
			local dx = candidate.X - position.X
			local dz = candidate.Z - position.Z
			local distance = dx * dx + dz * dz
			if distance < best then
				best = distance
				bestIndex = index
			end
		end

		candidates[slotIndex], candidates[bestIndex] = candidates[bestIndex], candidates[slotIndex]
		out[slotIndex] = candidates[slotIndex]
	end

	return wanted
end

-- Позиция врага в локальных координатах арены; nil, если он уже мёртв.
function EnemyService.GetPosition(slot: number, id: number): Vector3?
	local sim = sims[slot]
	if not sim or not sim.alive[id] then
		return nil
	end
	return sim.positions[id]
end

function EnemyService.Collect(slot: number, localPosition: Vector3, radius: number, out: { number }): number
	local sim = sims[slot]
	if not sim then
		return 0
	end
	return sim.hash.Collect(localPosition, radius, out)
end

function EnemyService.GetAliveCount(slot: number): number
	local sim = sims[slot]
	return if sim then sim.aliveCount else 0
end

function EnemyService.GetRunTime(slot: number): number
	local sim = sims[slot]
	return if sim then sim.time else 0
end

return EnemyService
