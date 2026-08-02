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

-- Причина завершения забега.
export type RunEndReason = "Death" | "Left"

-- Причина исчезновения врага; уходит на клиент одним байтом.
export type DespawnReason = "Killed" | "Culled"

return Types
