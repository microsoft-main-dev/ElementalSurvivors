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
export type RunEndReason = "Death" | "Left"

--[[
	Профиль игрока (раздел 6 ТЗ).

	Форма записана целиком, хотя M3 пишет только currency.essence, stats и
	progress.endlessBest: это данные, а не системы, и так следующие этапы будут
	заполнять готовые поля, а не мигрировать схему. Пустые ветки (pets,
	equipment, inventory, daily, offline, purchases) типизированы нарочно слабо —
	их настоящая форма появится вместе с самими системами в M4–M7.

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

export type ProfileDaily = {
	lastWheelSpin: number,
	streak: number,
	quests: { unknown },
}

export type ProfileOffline = {
	lastSeen: number,
	claimedAt: number,
}

export type ProfilePurchases = {
	gamepasses: { [string]: boolean },
	battlePass: { unknown },
	vipUntil: number,
}

export type ProfileData = {
	version: number,
	currency: Currency,
	level: number,
	xp: number,
	talentPoints: number,
	talents: { [string]: number },
	pets: { unknown },
	equippedPet: string,
	equipment: { [string]: string },
	inventory: {
		items: { unknown },
		consumables: { [string]: number },
	},
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
}

-- Итоги забега, собранные сервером из серверного же состояния.
export type RunSummary = {
	reason: RunEndReason,
	time: number,
	kills: number,
	level: number,
	abilities: { AbilityView },
}

-- То же плюс начисленное; уходит на экран результатов (раздел 8 ТЗ).
export type RunResult = {
	reason: RunEndReason,
	time: number,
	kills: number,
	level: number,
	abilities: { AbilityView },
	essence: number, -- начислено за этот забег
	newBest: boolean, -- время забега стало рекордом
	currency: Currency, -- баланс уже после начисления
}

-- Причина исчезновения врага; уходит на клиент одним байтом.
export type DespawnReason = "Killed" | "Culled"

return Types
