--!strict
--[[
	Stages — сюжетная прогрессия (раздел 5.1 ТЗ), M6.

	ГЛАВНОЕ ПРАВИЛО ЭТОГО ФАЙЛА: пятисот записей здесь нет. Локация — это данные,
	а конкретный уровень собирается функцией Stages.Get(index) из этих данных
	и кривых в Balance.Stages. Добавить локацию — значит дописать одну строку
	в Locations, и тридцать или сорок уровней появятся сами.

	Структура из ТЗ: 20 локаций, в локациях 1–5 по 10 уровней, 6–10 по 20,
	11–15 по 30, 16–20 по 40. Итого 500. Количество уровней тоже выводится
	по правилу, а не проставляется руками у каждой локации.

	В первой версии описана одна локация (решение владельца). Остальные
	добавляются данными — код при этом не трогается, и именно это
	проверяется на приёмке.

	Публичный API:
		Stages.Locations                  -> { LocationDef }
		Stages.TotalLevels                -> number
		Stages.Get(index)                 -> StageDef?
		Stages.LocationFor(index)         -> (LocationDef?, indexInLocation)
		Stages.IsLocationFinal(index)     -> boolean
]]

local Balance = require(script.Parent.Balance)
local Types = require(script.Parent.Parent.Types)

type LocationDef = Types.LocationDef
type StageDef = Types.StageDef

local Stages = {}

--[[
	Сколько уровней в локации по её номеру (раздел 5.1 ТЗ).

	Правило, а не поле в каждой записи: числа заданы один раз, и локация
	не может случайно получить чужой размер из-за копипасты.
]]
local function levelsInLocation(locationIndex: number): number
	if locationIndex <= 5 then
		return 10
	elseif locationIndex <= 10 then
		return 20
	elseif locationIndex <= 15 then
		return 30
	end
	return 40
end

--[[
	Локации. В первой версии одна — этого достаточно, чтобы проверить кривую
	сложности, а вторая добавляется строкой ниже без единой правки кода.

	palette — ключ таблицы в Config/Palette: визуально локации отличаются
	палитрой и туманом при нулевой стоимости (раздел 5.1 ТЗ).
]]
local locations: { LocationDef } = {
	{
		key = "Emberfall",
		displayName = "Emberfall",
		levels = 0, -- проставляется ниже по правилу
		palette = "Arena",
		enemyTypes = { "Slime", "Bat", "Ember" },
		bossKeys = { "Bulwark", "Harrier" },
	},
}

Stages.Locations = locations

--[[
	Начало каждой локации в сквозной нумерации. Считается один раз при загрузке:
	Get вызывается на каждом входе в бой и на отрисовке списка уровней,
	и пересчитывать эту таблицу каждый раз незачем.
]]
local firstLevelOf: { number } = {}
local total = 0

for index, location in locations do
	location.levels = levelsInLocation(index)
	firstLevelOf[index] = total + 1
	total += location.levels

	assert(
		#location.enemyTypes > 0,
		`[Stages] У локации "{location.key}" пустой список врагов`
	)
	assert(#location.bossKeys > 0, `[Stages] У локации "{location.key}" нет ни одного босса`)

	table.freeze(location.enemyTypes)
	table.freeze(location.bossKeys)
	table.freeze(location)
end

Stages.TotalLevels = total

--[[
	Какой локации принадлежит уровень и какой он по счёту внутри неё.
	Возвращает nil, если номер за пределами описанных локаций.
]]
function Stages.LocationFor(index: number): (LocationDef?, number)
	if index < 1 or index > total or index % 1 ~= 0 then
		return nil, 0
	end

	for locationIndex = #locations, 1, -1 do
		local first = firstLevelOf[locationIndex]
		if index >= first then
			return locations[locationIndex], index - first + 1
		end
	end

	return nil, 0
end

function Stages.IsLocationFinal(index: number): boolean
	local location, indexInLocation = Stages.LocationFor(index)
	return location ~= nil and indexInLocation == location.levels
end

--[[
	Собрать уровень.

	Чистая функция: одинаковый номер всегда даёт одинаковый уровень, ничего
	не кешируется и не хранится. Сервер и клиент могут звать её независимо
	и получат одно и то же.
]]
function Stages.Get(index: number): StageDef?
	local location, indexInLocation = Stages.LocationFor(index)
	if not location then
		return nil
	end

	local numbers = Balance.Stages
	local step = index - 1

	--[[
		Боссовый паттерн меняется каждые bossRotation уровней (раздел 5.1 ТЗ),
		перебирая список локации по кругу. Так десять уровней дают два разных
		боссфайта, а не один и тот же десять раз.
	]]
	local rotation = math.floor(step / numbers.bossRotation)
	local bossKey = location.bossKeys[rotation % #location.bossKeys + 1]

	return {
		index = index,
		location = location,
		indexInLocation = indexInLocation,
		isLocationFinal = indexInLocation == location.levels,

		duration = numbers.baseDuration,

		enemyHealthMult = numbers.enemyHealthGrowth ^ step,
		enemyDamageMult = numbers.enemyDamageGrowth ^ step,
		-- Скорость зажата потолком: быстрые враги на автобое читаются
		-- не как сложность, а как нечестность.
		enemySpeedMult = math.min(numbers.enemySpeedGrowth ^ step, numbers.enemySpeedCap),
		enemyTypes = location.enemyTypes,

		bossKey = bossKey,
		bossHealth = math.floor(numbers.bossHealthBase * numbers.bossHealthGrowth ^ step + 0.5),

		essence = math.floor(numbers.essenceBase * numbers.essenceGrowth ^ step + 0.5),
		xp = math.floor(numbers.xpBase * numbers.xpGrowth ^ step + 0.5),
	}
end

table.freeze(locations)
table.freeze(firstLevelOf)

return Stages
