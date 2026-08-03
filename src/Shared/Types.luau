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

export type EnemyDef = {
	key: string,
	typeId: number, -- индекс в Enemies.List; именно он летит по сети
	displayName: string,
	archetype: EnemyArchetype,
	element: Element,
	modifiers: { EnemyModifier },
	stats: EnemyStats,
	model: EnemyModel,
}

-- Строка расписания волн (раздел 3.5 ТЗ).
export type WaveEntry = {
	time: number, -- с какой секунды забега действует
	spawnRate: number, -- врагов в секунду
	types: { string }, -- ключи из Config/Enemies
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
	count: number?, -- орбов / снарядов за срабатывание
	radius: number?, -- радиус орбиты, ауры или вспышки
	hitRadius: number?, -- радиус поражения орба или снаряда
	angularSpeed: number?, -- скорость вращения орбиты, рад/с
	speed: number?, -- скорость снаряда
	lifetime: number?, -- время жизни снаряда
	pierce: number?, -- сколько врагов пробивает снаряд
}

export type AbilityDef = {
	key: string,
	typeId: number, -- индекс в Abilities.List, летит по сети
	displayName: string,
	description: string,
	element: Element,
	shape: AbilityShape,
	levels: { AbilityLevel },
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

-- Карточка выбора при левел-апе.
export type LevelUpCard = {
	abilityKey: string,
	isNew: boolean,
	level: number, -- каким станет уровень, если взять
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
export type RunMode = "Story" | "Endless"

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
export type LocationDef = {
	key: string,
	displayName: string,
	levels: number, -- сколько уровней в этой локации
	palette: string, -- ключ палитры арены
	enemyTypes: { string }, -- ключи из Config/Enemies
	bossKeys: { string }, -- боссовые архетипы, чередуются каждые 5 уровней
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
	enemyTypes: { string },
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

export type BossAttack = {
	kind: BossAttackKind,
	telegraph: number, -- секунд между показом области и уроном
	cooldown: number,
	damage: number,
	radius: number,
	speed: number?, -- скорость рывка или волны
	count: number?, -- сколько врагов призывает Summon
}

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
	duplicate: boolean,
	xpGained: number,
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
	Действия, которые игрок может запросить в лобби. Строка приходит с клиента,
	поэтому список закрытый: всё, чего здесь нет, отбрасывается на входе.
]]
export type LobbyAction =
	"BuyEgg"
	| "EquipPet"
	| "UpgradePet"
	| "BuyLot"
	| "ClaimOffline"
	| "SpendTalent"
	| "ResetTalents"
	| "EnterRun"
	| "SpinWheel"
	| "ClaimQuest"
	| "EquipItem"
	| "Refresh"

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
