--!strict
--[[
	Types — единственное место, где живут общие типы проекта.
]]

local Types = {}

--[[
	Сервис (сервер) и контроллер (клиент) — это ModuleScript, возвращающий таблицу
	с двумя необязательными фазами:

	Init  — вызывается у всех модулей до того, как хоть у одного вызван Start.
	        Здесь нельзя yield-иться: только подготовить своё состояние.
	Start — вызывается после того, как все Init отработали. Здесь можно всё.

	Двухфазность снимает проблему порядка зависимостей: к моменту Start
	любой другой сервис уже проинициализирован.
]]
export type Lifecycle = {
	Init: (() -> ())?,
	Start: (() -> ())?,
}

export type Service = Lifecycle
export type Controller = Lifecycle

-- Стихии (раздел 6 ТЗ). Задают и цвет врага, и направление билда игрока.
export type Element = "Fire" | "Ice" | "Lightning" | "Nature" | "Dark" | "Light"

--[[
	Архетипы поведения врагов (раздел 3.5 ТЗ). Уникальных врагов не рисуем:
	врага задаёт комбинация «архетип × стихия × модификаторы».
	В M1 реализованы Chaser и Swarm, остальные — задел на M6.
]]
export type EnemyArchetype =
	"Chaser"
	| "Charger"
	| "Ranged"
	| "Splitter"
	| "Swarm"
	| "Exploder"
	| "Shielder"
	| "Summoner"

export type EnemyModifier = "Fast" | "Tanky" | "Elite" | "Regenerating" | "Aura"

export type EnemyStats = {
	health: number,
	speed: number,
	damage: number,
	radius: number,
	xp: number,
}

export type EnemyModel = {
	size: Vector3,
	shape: "Block" | "Ball" | "Cylinder",
	neon: boolean,
}

--[[
	Во что враг разваливается при смерти (архетип Splitter).

	nil означает «ни во что». Считается только смерть от урона: зачистка
	по потолку живых и уборка в конце фазы деления не вызывают, иначе
	освобождение места плодило бы врагов.
]]
export type EnemySplit = {
	key: string,
	count: number,
}

--[[
	Дальнобойная атака (архетип Ranged).

	range — дистанция, которую враг держит; motionMargin — ширина полосы,
	внутри которой он стоит и стреляет, а не дёргается вперёд-назад.

	telegraph — трассер перед выстрелом. Он обязателен: снаряд, вылетевший
	без предупреждения из толпы в триста врагов, читается как несправедливость
	ровно так же, как атака босса без телеграфа.

	Снаряды НЕ самонаводящиеся: летят по прямой в ту точку, где игрок был
	в момент выстрела, и от них можно уйти — в этом весь смысл стрелка.
]]
export type EnemyRanged = {
	range: number,
	motionMargin: number,
	cooldown: number,
	telegraph: number,
	damage: number,
	speed: number,
	lifetime: number,
	hitRadius: number,
}

export type EnemyDef = {
	key: string,
	typeId: number, -- индекс в Enemies.List; именно он летит по сети
	displayName: string,
	archetype: EnemyArchetype,
	element: Element,
	modifiers: { EnemyModifier },
	stats: EnemyStats,
	model: EnemyModel,
	splitInto: EnemySplit?,
	ranged: EnemyRanged?,
}

--[[
	Строка расписания волн (раздел 3.5 ТЗ).

	Плотность боя по времени: сколько врагов в секунду и сколько их может быть
	живыми одновременно. Состав врагов сюжетного уровня задаёт сам уровень
	(LocationDef.enemies) — здесь он только для бесконечного режима.

	types действует только там, где локации нет (бесконечный режим): в сюжете
	и обучении состав врагов задаёт сам уровень (StageDef.enemies), и он знает
	про это больше — в том числе с какой секунды какой враг входит в бой.
]]
export type WaveEntry = {
	time: number, -- с какой секунды забега действует
	spawnRate: number, -- врагов в секунду
	types: { string }, -- ключи из Config/Enemies; для забега без локации
	maxAlive: number, -- жёсткий потолок живых врагов
}

--[[
	Формы способностей (раздел 3.4 ТЗ). Логика каждой формы написана один раз
	в AbilityService, а сама способность — строка данных в Config/Abilities.
	В M2 реализованы Orbit, Projectile, Aura и Nova; Cone и Chain — задел.
]]
export type AbilityShape = "Orbit" | "Projectile" | "Aura" | "Nova" | "Cone" | "Chain"

--[[
	Один уровень способности. Поля необязательные намеренно: у разных форм
	разный набор. Корректность проверяет валидатор при старте сервера —
	так строгая типизация не мешает data-driven таблицам.
]]
export type AbilityLevel = {
	damage: number,
	cooldown: number,
	count: number?, -- орбов / снарядов за срабатывание, звеньев у цепи
	radius: number?, -- радиус орбиты, ауры, вспышки; длина клина; дальность прыжка цепи
	hitRadius: number?, -- радиус поражения орба или снаряда
	angularSpeed: number?, -- скорость вращения орбиты, рад/с
	speed: number?, -- скорость снаряда
	lifetime: number?, -- время жизни снаряда
	pierce: number?, -- сколько врагов пробивает снаряд
	angle: number?, -- ширина клина Cone, градусов
	falloff: number?, -- доля урона, доходящая до следующего звена Chain
}

--[[
	Что даёт способности каждый третий уровень (рубеж).

	Count  — снаряды или орбы: +amount штук за срабатывание;
	Radius — радиус орбиты, ауры или вспышки: +amount стадов;
	Pierce — сколько врагов пробивает снаряд: +amount.

	Рубеж всегда одинаков и не зависит от редкости карточки: редкость крутит
	только обычные уровни. Иначе «+1 снаряд» превращался бы в лотерею, а это
	как раз то, ради чего игрок качает способность.
]]
export type AbilityMilestoneKind = "Count" | "Radius" | "Pierce"

export type AbilityMilestone = {
	kind: AbilityMilestoneKind,
	amount: number,
}

--[[
	Рост за ОБЫЧНЫЙ уровень: множители к базе. Урон растёт, кулдаун сокращается.
	Оба множителя применяются к накопленному значению, а не к базовому:
	редкая карточка даёт больше, и её вклад должен остаться в способности
	навсегда, а не потеряться на следующем уровне.
]]
export type AbilityGrowth = {
	damage: number, -- > 1
	cooldown: number, -- < 1
}

--[[
	Откуда способность берётся.

	Base      — базовые: их предлагают карточки в бою;
	Signature — уникальная способность питомца: её нельзя получить карточкой,
	            только принести с собой. Качается картами наравне с базовыми —
	            иначе редкий питомец обесценивался бы к середине забега.
]]
export type AbilitySource = "Base" | "Signature"

export type AbilityDef = {
	key: string,
	typeId: number, -- индекс в Abilities.List, летит по сети
	displayName: string,
	description: string,
	element: Element,
	shape: AbilityShape,
	source: AbilitySource,
	base: AbilityLevel,
	growth: AbilityGrowth,
	milestone: AbilityMilestone,
}

--[[
	Накопленное способностью за забег. Из номера уровня это больше не выводится:
	один и тот же девятый уровень у двух игроков разный, потому что карточки
	падали с разной редкостью.
]]
export type AbilityBonuses = {
	damageMult: number,
	cooldownMult: number,
	count: number, -- добавка к числу снарядов или орбов
	radius: number, -- добавка к радиусу, стадов
	pierce: number,
}

-- Состояние способности в забеге, уходит на клиент для HUD и отрисовки.
export type AbilityView = {
	key: string,
	level: number,
	cooldown: number, -- сколько осталось до срабатывания
	maxCooldown: number, -- ноль означает «кулдауна нет», иконка не затемняется
	phase: number, -- угол орбиты; нужен, чтобы орбы на клиенте совпали с сервером
	damage: number, -- суммарный урон способности за забег
}

--[[
	Карточка выбора при левел-апе.

	rarity — ключ редкости из Config/Cards: она множит прибавку обычного уровня
	и рисуется цветом. Решает её сервер и запоминает вместе с предложением;
	текст улучшения клиент считает сам из общего конфига по ключу, уровню
	и редкости — расходиться им не с чем, функция одна и та же.
]]
export type LevelUpCard = {
	abilityKey: string,
	isNew: boolean,
	level: number, -- каким станет уровень, если взять
	rarity: string,
}

-- Пакет для HUD, шлётся 10 раз в секунду.
export type RunSnapshot = {
	time: number,
	kills: number,
	level: number,
	xp: number,
	xpToNext: number,
	abilities: { AbilityView },
}

-- Причина завершения забега.
export type RunEndReason = "Death" | "Left" | "Victory"

--[[
	Режим забега (раздел 5.1 ТЗ), M6.

	Story — сюжетный уровень: фиксированная длительность, затем босс, победа
	открывает следующий уровень. Endless — бесконечный режим, награда и опыт
	считаются по убийствам и времени.
]]
--[[
	Tutorial — обязательный первый забег новичка (M7, раздел 4 ТЗ). Отдельный
	режим, а не сюжетный уровень с номером ноль: номер сюжетного уровня обязан
	значить одно и то же везде, где встречается, иначе экран результатов,
	открытие следующего уровня и проверка права играть обзаводятся каждый
	своим исключением.
]]
export type RunMode = "Story" | "Endless" | "Tutorial"

--[[
	Фаза сюжетного забега.

	Survival — обычный бой по расписанию волн.
	Sweep    — спавн прекращён, добиваем оставшихся; босс ждёт пустой арены.
	Boss     — бой с боссом.
	Done     — босс убит, забег завершается.

	Sweep существует потому, что ожидание полной зачистки подвешивает забег,
	если последний враг недостижим. В этой фазе оставшиеся стягиваются
	к игроку, а по таймауту убираются принудительно.
]]
export type StagePhase = "Survival" | "Sweep" | "Boss" | "Done"

--[[
	Локация (раздел 5.1 ТЗ). Двадцать локаций — это данные; конкретный уровень
	внутри локации собирается формулой, а не выписывается руками.
]]
--[[
	Когда враг входит в бой.

	fromStage — с какого уровня ВНУТРИ локации он вообще появляется;
	fromFraction — с какой доли фазы выживания на этом уровне (0 — сразу,
	0.5 — со второй половины).

	Два измерения, а не одно, потому что уровень усложняется и от номера,
	и по ходу самого боя: «большой слизень со второго уровня» и «мечник
	со второй половины шестого» — это одно правило, записанное одинаково.
]]
export type LocationEnemy = {
	key: string, -- ключ из Config/Enemies
	fromStage: number,
	fromFraction: number,
}

export type LocationDef = {
	key: string,
	displayName: string,
	levels: number, -- сколько уровней в этой локации
	palette: string, -- ключ палитры арены в Palette.Arenas
	enemies: { LocationEnemy },
	bossKeys: { string }, -- боссовые архетипы, чередуются внутри локации
}

-- Враг уровня с уже посчитанной секундой появления. Собирается Stages.Get.
export type StageEnemy = {
	key: string,
	fromSeconds: number,
}

--[[
	Собранный сюжетный уровень. Возвращается Stages.Get(index) и нигде
	не хранится: это чистая функция от номера уровня и таблицы локаций.
]]
export type StageDef = {
	index: number, -- сквозной номер, 1..500
	location: LocationDef,
	indexInLocation: number,
	isLocationFinal: boolean, -- финал локации даёт гарантированный предмет
	duration: number, -- секунд фазы выживания
	enemyHealthMult: number,
	enemyDamageMult: number,
	enemySpeedMult: number,
	--[[
		Кто спавнится на этом уровне и с какой секунды. Отсортировано
		по времени: EnemyService идёт по нему курсором, а не пересобирает
		набор каждый спавн.
	]]
	enemies: { StageEnemy },
	bossKey: string,
	bossHealth: number,
	essence: number, -- награда за победу
	xp: number,
}

--[[
	Боссы (разделы 3.5 и 5.1 ТЗ), M6.

	Как и у обычных врагов, уникальных боссов не рисуем: босса задаёт архетип
	с набором фаз и атак, а разнообразие даёт комбинация «архетип × стихия ×
	номер уровня».

	Атаки обязаны иметь телеграф — время, когда область удара уже показана,
	а урона ещё нет. На автобое игрок не может ни блокировать, ни уклоняться
	осознанно, если не видит, куда сейчас ударят; атака без предупреждения
	читается как несправедливость, а не как сложность.
]]
export type BossAttackKind =
	"Charge" -- рывок по прямой через арену
	| "Shockwave" -- расходящееся кольцо от босса
	| "Summon" -- призыв обычных врагов
	| "HealField" -- лечащее поле над скоплением своих призванных
	| "PoisonField" -- ядовитая лужа в случайной точке арены

--[[
	Поля — первые СТОЙКИЕ эффекты в игре: остальные атаки бьют мгновенно.
	Живут duration секунд и тикают раз в tickInterval, поэтому у них свои поля
	в определении атаки.
]]
export type BossAttack = {
	kind: BossAttackKind,
	telegraph: number, -- секунд между показом области и уроном
	cooldown: number,
	damage: number,
	radius: number,
	speed: number?, -- скорость рывка или волны
	count: number?, -- сколько врагов призывает Summon
	--[[
		Кого именно призывает Summon. nil — случайных из тех, что населяют
		уровень; ключ — всегда этого врага. Шаман зовёт своих гоблинов,
		и это его характер, а не то, что подвернулось в текущей волне.
	]]
	summonKey: string?,
	duration: number?, -- сколько живёт поле
	tickInterval: number?, -- как часто поле срабатывает
	heal: number?, -- сколько здоровья возвращает лечащее поле за тик
}

--[[
	Стойкое поле на арене. Уходит на клиент один раз при появлении: круг
	не двигается, а сколько ему осталось, клиент отсчитывает сам.
]]
export type BossFieldKind = "Heal" | "Poison"

--[[
	Фаза боссфайта. Действует та фаза, у которой healthAbove не больше текущей
	доли здоровья; список идёт от полного здоровья к нулю.
]]
export type BossPhase = {
	healthAbove: number, -- 0..1
	moveSpeed: number,
	attacks: { BossAttack },
}

export type BossDef = {
	key: string,
	typeId: number,
	displayName: string,
	element: Element,
	radius: number,
	contactDamage: number,
	model: EnemyModel,
	phases: { BossPhase },
}

-- Состояние босса для клиента: полоса здоровья и телеграфы атак.
export type BossView = {
	key: string,
	health: number,
	maxHealth: number,
	x: number,
	z: number,
}

--[[
	Питомцы (разделы 6 и 6.1 ТЗ). Питомец — это класс: он задаёт стартовую
	способность боя, даёт пассивные бонусы и усиливает свою стихию.

	Редкость влияет на три вещи сразу: шанс из яйца, силу бонусов и вклад
	в оффлайн-доход. Все три коэффициента — в Balance.Pets, здесь только форма.
]]
export type PetRarity = "B" | "A" | "S" | "SS" | "SSS"

-- Пассивные бонусы. Это добавки к базовым значениям, а не множители:
-- складывать добавки безопаснее, чем перемножать проценты из разных систем.
export type PetPassives = {
	maxHealth: number,
	walkSpeed: number,
	magnetRadius: number,
}

export type PetModel = {
	size: Vector3,
	shape: "Block" | "Ball" | "Cylinder",
	neon: boolean,
	--[[
		Летает ли питомец рядом с игроком (M7). Наземные держатся у земли
		и подпрыгивают на бегу, летающие висят выше и покачиваются.

		Это данные, а не вывод из стихии: сова и дракон летают, а рысь и гончая
		нет, хотя стихии у них общие с летающими.
	]]
	flies: boolean,
}

export type PetDef = {
	key: string,
	typeId: number, -- индекс в Pets.List; порядок менять нельзя
	displayName: string,
	description: string,
	rarity: PetRarity,
	element: Element,
	starterAbility: string, -- ключ из Config/Abilities
	passives: PetPassives, -- значения на 1-м уровне питомца
	elementDamage: number, -- множитель урона своей стихии на 1-м уровне
	model: PetModel,
}

-- Питомец в профиле. uid уникален внутри профиля и никогда не переиспользуется.
export type PetInstance = {
	uid: string,
	petId: string,
	level: number,
	xp: number,
	--[[
		Позиция на звёздной лестнице (M2+): 1..StarLadder.Total.

		Одно число, а не «этап + звезда»: этап и номер внутри него выводятся
		из позиции, и два поля, которые обязаны быть согласованы, разъехались бы
		при первой же правке.

		Стартовая позиция зависит от редкости (B ниже, SSS выше) — см.
		Config/Pets. У питомцев, полученных до этой правки, поля нет: читать
		его надо как «стартовая позиция своей редкости».
	]]
	stars: number,
}

--[[
	Всё, что забег получает извне: питомец (раздел 6 ТЗ) и таланты (M5).

	Собирается один раз при входе в бой и за забег не меняется — ни питомца,
	ни дерево в бою не тронуть. Источников бонусов будет больше (экипировка —
	M6), и все они дописываются в эти же поля, а не заводят второй путь.
]]
export type RunLoadout = {
	petId: string, -- пустая строка означает «питомца нет»
	starterAbility: string,
	maxHealth: number,
	walkSpeed: number,
	magnetRadius: number,
	elementDamage: { [Element]: number }, -- множитель урона, 1 = без бонуса
	elementCooldown: { [Element]: number }, -- множитель кулдауна, меньше 1 = чаще
}

-- Строка списка питомцев на клиенте. Все числа уже посчитаны сервером.
export type PetView = {
	uid: string,
	petId: string,
	level: number,
	xp: number, -- опыт внутри текущего уровня
	xpToNext: number, -- сколько нужно до следующего; 0 на максимуме
	power: number,
	upgradeCost: number, -- 0 означает «улучшать некуда»
	equipped: boolean,
	stars: number, -- позиция на звёздной лестнице
	starMult: number, -- во сколько раз звёзды усилили бонусы питомца
	evolve: EvolveView?, -- nil означает «дальше некуда»
}

--[[
	Рецепт одной ступени эволюции.

	copies — сколько нужно питомцев ТОГО ЖЕ вида, fodder — сколько любых.
	У каждого своя требуемая позиция на лестнице: корм для фиолетовых
	и красных ступеней всегда шестизвёздочный, а ранние ступени едят
	питомцев своего уровня.
]]
export type EvolveRecipe = {
	copies: number,
	copyStars: number,
	fodder: number,
	fodderStars: number,
}

-- То же самое плюс то, что у игрока уже есть: панель показывает «2/3».
export type EvolveView = {
	copies: number,
	copyStars: number,
	fodder: number,
	fodderStars: number,
	haveCopies: number,
	haveFodder: number,
}

export type PetsView = {
	pets: { PetView },
	equipped: string, -- uid экипированного питомца
	collectionPower: number,
	offlineRatePerHour: number,
	offlineCapHours: number,
}

-- Результат одного ролла яйца. Дубликат не создаёт вторую запись, а даёт опыт.
export type EggRollResult = {
	petId: string,
	-- Сколько таких питомцев стало в коллекции. Дубликат — это отдельный
	-- питомец, а не опыт и не счётчик: из них строится эволюция.
	duplicate: boolean,
	owned: number,
	level: number, -- уровень питомца после ролла
}

-- Отчёт экспедиций при входе (раздел 6.1 ТЗ). Считает только сервер.
export type OfflineReport = {
	seconds: number, -- сколько времени накопилось (уже обрезано по потолку)
	essence: number,
	ratePerHour: number,
	capHours: number,
}

--[[
	Древо талантов (раздел 6 ТЗ), M5.

	Узел — это данные: где он нарисован, с кем соединён, сколько очков в него
	влезает и что он даёт. Логика рисования и применения написана один раз
	и про конкретные узлы не знает ничего.

	Стихийные эффекты усиливают всю стихию целиком, а не отдельную
	способность: так талант остаётся осмысленным независимо от того,
	какие карточки легли в забеге.
]]
export type TalentEffectKind =
	"ElementDamage" -- +perPoint к множителю урона стихии
	| "ElementCooldown" -- -perPoint к множителю кулдауна стихии
	| "MaxHealth" -- +perPoint к максимуму здоровья
	| "WalkSpeed" -- +perPoint к скорости
	| "MagnetRadius" -- +perPoint к радиусу притяжения кристаллов

export type TalentEffect = {
	kind: TalentEffectKind,
	perPoint: number,
}

export type TalentNode = {
	id: string,
	displayName: string,
	element: Element?, -- nil у общих узлов
	position: Vector2, -- в условных единицах дерева, масштаб задаёт панель
	connections: { string }, -- связи двусторонние, обратные достраиваются при загрузке
	maxPoints: number,
	effect: TalentEffect,
}

-- Свёрнутое дерево: то, во что превращаются вложенные очки.
export type TalentBonuses = {
	elementDamage: { [Element]: number },
	elementCooldown: { [Element]: number },
	maxHealth: number,
	walkSpeed: number,
	magnetRadius: number,
	spent: number, -- сколько очков вложено всего; от него считается цена сброса
}

export type TalentsView = {
	level: number,
	xp: number, -- опыт внутри текущего уровня
	xpToNext: number, -- 0 на максимальном уровне
	points: number, -- нераспределённые очки
	spent: { [string]: number }, -- id узла -> вложено
	resetCost: number,
	bonuses: TalentBonuses,
}

--[[
	Экипировка (раздел 6.1 ТЗ), M6.

	Предметы не описываются поштучно: предмет — это ролл «слот × редкость ×
	набор характеристик». Характеристики намеренно те же, что уже умеет
	лоадаут забега, чтобы экипировка добавлялась данными, а не кодом в бою.
]]
export type ItemSlot = "Helmet" | "Chest" | "Boots" | "Trinket"
export type ItemRarity = "Common" | "Rare" | "Epic" | "Legendary"

-- AllDamage — множитель ко всем стихиям, остальные — добавки к базе.
export type ItemStatKind = "MaxHealth" | "WalkSpeed" | "MagnetRadius" | "AllDamage"

export type ItemInstance = {
	uid: string, -- выдаёт профиль, уникален на всю жизнь аккаунта
	slot: ItemSlot,
	rarity: ItemRarity,
	stageIndex: number, -- с какого уровня выпал; от него зависели числа
	stats: { [string]: number },
}

export type ItemView = {
	uid: string,
	slot: ItemSlot,
	rarity: ItemRarity,
	stats: { [string]: number },
	power: number,
	equipped: boolean,
}

export type ItemsView = {
	items: { ItemView },
	equipped: { [string]: string }, -- слот -> uid
}

--[[
	Ежедневные квесты (раздел 4 ТЗ), M6. Прогресс тикает из боёв,
	награда забирается вручную — иначе игрок не заметит, что что-то получил.
]]
export type QuestKind = "Kills" | "Runs" | "Survive" | "StageClear"

export type QuestView = {
	id: string,
	kind: QuestKind,
	displayName: string,
	target: number,
	progress: number,
	essence: number,
	claimed: boolean,
}

export type QuestsView = {
	quests: { QuestView },
	resetsInSeconds: number,
	-- Сколько ждать бесплатной прокрутки колеса; 0 означает «можно сейчас».
	-- Живёт здесь, а не отдельным пакетом: и то, и другое — ежедневное,
	-- и панель у них общая.
	wheelReadyInSeconds: number,
}

-- Результат прокрутки колеса фортуны (раздел 4 ТЗ).
export type WheelResult = {
	prizeIndex: number,
	displayName: string,
	essence: number,
	nextSpinInSeconds: number,
}

-- Строка стенда рекордсменов (раздел 4 ТЗ), M6.
export type LeaderboardEntry = {
	rank: number,
	userId: number,
	name: string,
	seconds: number,
}

--[[
	Монетизация (раздел 9 ТЗ), M7.

	Вечных геймпассов в игре нет решением владельца: всё, что продаётся за Robux, —
	повторяемая покупка через дев-продукт. Отсюда главное следствие для всей ветки:
	единственный вход денег в игру — ProcessReceipt, и защищать от двойной выдачи
	надо ровно одно место, а не каждый товар по отдельности.
]]
export type ProductKind = "prisms" | "boost" | "charge" | "vip"

--[[
	Что именно выдаётся за покупку. Все четыре вида лежат в одной таблице,
	потому что товар может быть только одним из них: пустая строка и ноль
	означают «этот вид выдачи к товару не относится».
]]
export type ProductGrant = {
	prisms: number,
	boost: string, -- ключ бустера
	seconds: number, -- на сколько продлевается бустер или VIP
	charge: string, -- ключ заряда
	count: number, -- сколько зарядов
}

export type ProductDef = {
	key: string,
	kind: ProductKind,
	--[[
		Числовой id из Creator Dashboard. Ноль означает «продукт ещё не заведён»:
		лот показывается неактивным, а не роняет панель — ровно как ноль
		в Config/Branding означает «ассета нет».
	]]
	productId: number,
	displayName: string,
	description: string,
	grant: ProductGrant,
}

--[[
	Бустер — временной множитель. Ничего не даёт в бою: раздел 10 ТЗ запрещает
	донату давать силу, поэтому ускоряется только доход.
]]
export type BoostDef = {
	key: string,
	displayName: string,
	essenceMult: number,
	offlineCapMult: number,
	wheelRate: number, -- во сколько раз быстрее готово колесо фортуны
}

-- Заряд — одноразовый множитель на один засчитанный забег.
export type ChargeDef = {
	key: string,
	displayName: string,
	essenceMult: number,
}

export type BoostMultipliers = {
	essence: number,
	offlineCap: number,
	wheelRate: number,
}

export type StoreProductView = {
	key: string,
	displayName: string,
	description: string,
	productId: number,
	-- false означает, что продукт не заведён в Creator Dashboard.
	available: boolean,
}

export type StoreBoostView = {
	key: string,
	displayName: string,
	secondsLeft: number,
}

export type StoreChargeView = {
	key: string,
	displayName: string,
	count: number,
}

export type StoreView = {
	products: { StoreProductView },
	boosts: { StoreBoostView },
	charges: { StoreChargeView },
	-- Текущий множитель Essence со всеми бустерами; 1 означает «бустеров нет».
	essenceMult: number,
}

--[[
	Обучение новичка (M7, раздел 4 ТЗ).

	Что гасит подсказку боя. Список закрытый: и Config/Tutorial, и разбор
	в TutorialController ссылаются на эти же имена, поэтому опечатка ловится
	типизацией, а не подсказкой, которая молча висит до конца забега.

		Move     — пока персонаж не сдвинулся с места;
		Timer    — просто держится holdSeconds и уходит;
		Crystal  — пока не подобран первый кристалл опыта;
		LevelUp  — ждёт паузы левел-апа и висит, пока карточка не выбрана;
		Boss     — ждёт выхода босса и висит holdSeconds.
]]
export type TutorialTrigger = "Move" | "Timer" | "Crystal" | "LevelUp" | "Boss"

export type TutorialRunHint = {
	id: string,
	text: string,
	trigger: TutorialTrigger,
	--[[
		Не показывать раньше этой секунды забега. Ноль — показывать сразу,
		как дошла очередь. Нужно подсказкам, привязанным к моменту самого
		уровня, а не к действию игрока: про усложнение по времени бессмысленно
		говорить до того, как в бой войдёт второй тип врагов.
	]]
	waitSeconds: number,
	--[[
		Сколько держать подсказку. У Timer это вся её жизнь, у остальных —
		потолок: подсказка уходит и по своему условию, и по этому времени,
		чтобы игрок, не понявший её, не читал одно и то же весь забег.
	]]
	holdSeconds: number,
}

--[[
	Чем закрывается шаг обучения в лобби.

	Обязательным шаг делается только там, где выполнить его точно можно:
	яйцо покупается ровно на выданную за туториал награду, предмет и очко
	таланта тоже выданы этим же забегом. Всё остальное объясняется текстом
	с кнопкой — иначе туториал застрянет на шаге, который игроку нечем
	пройти (из яйца может выпасть дубликат стартового питомца, и экипировать
	будет нечего).

		Next        — прочитал и нажал кнопку;
		OpenPanel   — открыл нужную панель (кнопкой или промптом у объекта);
		EnterRun    — вошёл в бой;
		BuyEgg      — купил яйцо;
		SpendTalent — вложил очко таланта;
		EquipItem   — надел предмет.
]]
export type TutorialAdvance = "Next" | "OpenPanel" | "EnterRun" | "BuyEgg" | "SpendTalent" | "EquipItem"

--[[
	Шаг обучения в лобби.

	panel — имя панели из LobbyController.openPanel: пока шаг идёт, открыть
	можно только её. Пустая строка означает «шаг ничего не открывает и лобби
	не ограничивает».

	arrow — над каким объектом лобби висит стрелка. Имя то же, что у панели
	(объекты подписаны атрибутом Panel на своём промпте), пустая строка —
	без стрелки.
]]
export type TutorialStep = {
	id: string,
	text: string,
	advance: TutorialAdvance,
	panel: string,
	arrow: string,
}

--[[
	Состояние обучения, одним пуском при входе. Промежуточные шаги на сервер
	не ходят: за туториал ничего не начисляется, валидировать нечего, а второй
	счётчик шагов в профиле был бы вторым местом для одного факта.
]]
export type TutorialView = {
	-- Обучающий забег ещё не выигран: в лобби идёт первая половина обучения,
	-- а у портала доступен только он (раздел 4 ТЗ).
	needsRun: boolean,
	-- Вторая половина обучения (яйцо, питомец, талант, предмет) не пройдена.
	needsLobbyTour: boolean,
}

--[[
	Действия, которые игрок может запросить в лобби. Строка приходит с клиента,
	поэтому список закрытый: всё, чего здесь нет, отбрасывается на входе.
]]
export type LobbyAction =
	"BuyEgg"
	| "EquipPet"
	| "UpgradePet"
	| "EvolvePet"
	| "BuyLot"
	| "ClaimOffline"
	| "SpendTalent"
	| "ResetTalents"
	| "EnterRun"
	| "SpinWheel"
	| "ClaimQuest"
	| "EquipItem"
	| "Refresh"
	| "SetSetting"
	| "TutorialDone"
	| "DebugBossFight"

--[[
	Звуковой слот (M7). Список закрытый: и Config/Sounds, и все места, которые
	просят звук, ссылаются на эти же имена, поэтому опечатка в строке ловится
	типизацией, а не молчанием в бою.
]]
export type SoundSlot =
	"Hit"
	| "EnemyDeath"
	| "CrystalPickup"
	| "LevelUp"
	| "CardChosen"
	| "PlayerHit"
	| "PlayerDeath"
	| "BossSpawn"
	| "BossDeath"
	| "StageVictory"
	| "ButtonClick"
	| "Purchase"
	| "EggOpen"
	| "WheelSpin"
	| "MusicLobby"
	| "MusicCombat"

--[[
	Настройки игрока (M7, раздел 2.1 ТЗ). Хранятся в профиле — другой
	персистентности в Roblox нет.

	quality = "Auto" не фиксируется на устройстве один раз при первом входе:
	это режим, который клиент разворачивает в High/Low по текущему вьюпорту
	каждый раз сам (SettingsController.ResolveQuality). Так режим остаётся
	верным, даже если игрок зашёл с телефона, а потом с компьютера.
]]
export type QualityMode = "Auto" | "High" | "Low"

--[[
	Эффекты донатной косметики других игроков в лобби (раздел 2.1 ТЗ). Хранится
	и показывается в настройках уже сейчас, но применить пока негде: ни одного
	Trail/ParticleEmitter/Highlight на экипировке в проекте нет — M6 сделал
	только числовые статы предметов. Поле ждёт визуальную косметику, а не
	наоборот.
]]
export type OthersEffectsMode = "All" | "Nearby" | "Off"

export type ProfileSettings = {
	quality: QualityMode,
	othersEffects: OthersEffectsMode,
	sfxVolume: number, -- 0..1
	musicVolume: number, -- 0..1
	-- Видимость панели DamageMeter (счётчик урона по способностям, M2).
	showDamageMeter: boolean,
}

--[[
	Профиль игрока (раздел 6 ТЗ).

	Форма записана целиком, хотя M3 писал только currency.essence, stats и
	progress.endlessBest: это данные, а не системы, и так следующие этапы
	заполняют готовые поля, а не мигрируют схему. M4 добавил к этому pets,
	equippedPet и offline. Оставшиеся ветки (equipment, inventory, daily,
	purchases) типизированы нарочно слабо — их настоящая форма появится
	вместе с самими системами в M5–M7.

	Ограничения ProfileStore: никаких Vector3/Color3/Instance/функций, никаких
	смешанных таблиц и дыр в массивах. Всё, что попадает в профиль, — числа,
	строки, булевы и таблицы из них.
]]
export type CurrencyKind = "essence" | "prisms"

export type Currency = {
	essence: number, -- обычная, добывается гриндом
	prisms: number, -- донатная, появится в M7
}

export type ProfileProgress = {
	storyStage: number, -- номер открытого сюжетного уровня (M6)
	endlessBest: number, -- лучшее время забега, секунд
}

export type ProfileStats = {
	totalRuns: number,
	totalKills: number,
	playtime: number, -- суммарное время в боях, секунд
}

--[[
	Квест в профиле. Хранится целиком, а не ссылкой на таблицу заданий:
	правка Config/Quests не должна менять условия у задания, которое игрок
	уже начал выполнять сегодня.
]]
export type ProfileQuest = {
	id: string,
	kind: QuestKind,
	target: number,
	progress: number,
	essence: number,
	claimed: boolean,
}

export type ProfileDaily = {
	lastWheelSpin: number,
	streak: number,
	quests: { ProfileQuest },
	-- Когда набор заданий сменится. Серверное время, не клиентское.
	resetAt: number,
}

--[[
	Экспедиции питомцев (раздел 6.1 ТЗ).

	pending — уже посчитанный, но ещё не забранный доход. Он лежит в профиле,
	а не в памяти сервера, по двум причинам сразу: игрок, закрывший окно без
	сбора, ничего не теряет, а промежуток времени между двумя заходами
	засчитывается ровно один раз — он превращается в pending в тот же момент,
	когда сдвигается lastSeen.
]]
export type ProfileOffline = {
	lastSeen: number,
	claimedAt: number,
	pending: number,
}

--[[
	Покупки за Robux (M7).

	Вечных геймпассов в игре нет, поэтому здесь лежит только то, чего не хранит
	сам Roblox: сроки, заряды и список обработанных чеков.
]]
export type ProfilePurchases = {
	--[[
		Остаётся пустым навсегда. Ветка сохранена потому, что форма профиля
		из раздела 6 ТЗ описана целиком: удалить её дешевле один раз, а вот
		объяснить через полгода, куда она делась, — дороже.
	]]
	gamepasses: { [string]: boolean },
	-- Батлпасс отложен за MVP решением владельца.
	battlePass: { unknown },
	-- Когда истекает VIP, серверное os.time(). Ноль — VIP не покупался.
	vipUntil: number,
	-- Ключ бустера -> время окончания. Просроченные записи чистятся при входе.
	boosters: { [string]: number },
	-- Ключ заряда -> сколько штук осталось.
	charges: { [string]: number },
	--[[
		Кольцо последних обработанных purchaseId — то самое место, которым
		покупка делается одноразовой: чек, который уже здесь, второй раз
		не начисляет ничего.

		Кольцо, а не бесконечный список: Roblox перестаёт слать чек сразу после
		того, как выдача подтверждена, поэтому хранить их вечно незачем, а
		профиль растёт бесконечно только у тех, кто платит больше всех.
	]]
	receipts: { string },
}

export type ProfileData = {
	version: number,
	currency: Currency,
	level: number,
	xp: number,
	talentPoints: number,
	talents: { [string]: number },
	pets: { PetInstance },
	--[[
		Счётчик uid питомцев. Живёт в профиле, а не в сервисе: uid обязан быть
		уникальным на всём протяжении жизни аккаунта, а серверы приходят и уходят.
	]]
	petUidCounter: number,
	equippedPet: string,
	--[[
		Одноразовые отметки («стартовый питомец выдан», позже — «туториал пройден»).
		Отдельная ветка нужна, чтобы такие флаги не расползались по чужим по смыслу
		полям: их будет много, а форма у всех одинаковая.
	]]
	flags: { [string]: boolean },
	-- Слот -> uid надетого предмета (M6).
	equipment: { [string]: string },
	inventory: {
		items: { ItemInstance },
		consumables: { [string]: number },
	},
	-- Счётчик uid предметов; та же роль, что у petUidCounter.
	itemUidCounter: number,
	progress: ProfileProgress,
	daily: ProfileDaily,
	offline: ProfileOffline,
	purchases: ProfilePurchases,
	settings: ProfileSettings,
	stats: ProfileStats,
}

--[[
	Срез профиля для клиента. Профиль целиком на клиент не уходит никогда:
	показывать нужно немногое, а лишние поля — это лишний повод им поверить.
]]
export type ProfileView = {
	essence: number,
	prisms: number,
	endlessBest: number,
	totalRuns: number,
	-- Первый непройденный сюжетный уровень (M6): по нему панель у портала
	-- решает, что уже открыто.
	storyStage: number,
	settings: ProfileSettings,
}

-- Итоги забега, собранные сервером из серверного же состояния.
export type RunSummary = {
	reason: RunEndReason,
	mode: RunMode,
	stageIndex: number, -- 0 в бесконечном режиме
	victory: boolean, -- босс убит; в бесконечном режиме всегда false
	time: number,
	kills: number,
	level: number,
	abilities: { AbilityView },
}

-- То же плюс начисленное; уходит на экран результатов (раздел 8 ТЗ).
export type RunResult = {
	reason: RunEndReason,
	mode: RunMode,
	stageIndex: number,
	victory: boolean,
	time: number,
	kills: number,
	level: number, -- уровень внутри забега, он не сохраняется
	abilities: { AbilityView },
	essence: number, -- начислено за этот забег, уже с множителем
	-- Множитель бустеров и заряда (M7); 1 означает «покупок не было».
	-- Нужен на экране: без него заплативший не видит, что покупка сработала.
	essenceMult: number,
	newBest: boolean, -- время забега стало рекордом
	currency: Currency, -- баланс уже после начисления

	-- Мета-прогрессия (M5): опыт персонажа, который забег НЕ сбрасывает.
	xp: number, -- начислено за этот забег
	metaLevel: number, -- уровень персонажа после начисления
	levelsGained: number, -- сколько уровней взято за этот забег
	talentPoints: number, -- нераспределённых очков после начисления

	-- Выпавшая экипировка (M6). Только за победу на сюжетном уровне.
	items: { ItemInstance },
}

-- Причина исчезновения врага; уходит на клиент одним байтом.
export type DespawnReason = "Killed" | "Culled"

return Types
