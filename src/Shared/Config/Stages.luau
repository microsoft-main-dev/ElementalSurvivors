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
		Stages.Tutorial()                 -> StageDef
]]

local Balance = require(script.Parent.Balance)
local Types = require(script.Parent.Parent.Types)

type LocationDef = Types.LocationDef
type StageDef = Types.StageDef

local Stages = {}

--[[
	Сколько уровней в локации.

	РАСХОЖДЕНИЕ С ТЗ, решение владельца. Раздел 5.1 задаёт 10 уровней в первых
	пяти локациях, дальше 20, 30 и 40 — итого 500. Владелец решил менять
	локацию каждые пять уровней, поэтому размер стал одним числом в Balance,
	а не лесенкой по номеру локации. При двадцати локациях это даст сто
	уровней, а не пятьсот.

	Правило, а не поле в каждой записи: число задано один раз, и локация
	не может случайно получить чужой размер из-за копипасты.
]]
local function levelsInLocation(): number
	return Balance.Stages.levelsInLocation
end

--[[
	Локации. В первой версии одна — этого достаточно, чтобы проверить кривую
	сложности, а вторая добавляется строкой ниже без единой правки кода.

	palette — ключ таблицы в Config/Palette: визуально локации отличаются
	палитрой и туманом при нулевой стоимости (раздел 5.1 ТЗ).

	enemies — кто населяет локацию и когда появляется: с какого уровня внутри
	локации и с какой доли фазы выживания. Это и есть кривая усложнения,
	и она живёт здесь, а не в расписании волн: волны знают только время,
	а «большой слизень со второго уровня» — это ещё и номер уровня.
]]
local locations: { LocationDef } = {
	--[[
		Лесная поляна: только слизни, и вводятся они постепенно.

		Первый уровень — обычные слизни и ничего больше: это первое, что видит
		игрок после обучения, и знакомить его сразу с тремя видами незачем.
		Дальше на каждом уровне прибавляется по виду, а мега-слизень, который
		разваливается на двух больших, приходит последним.
	]]
	{
		key = "ForestGlade",
		displayName = "Forest Glade",
		levels = 0, -- проставляется ниже по правилу
		palette = "ForestGlade",
		enemies = {
			{ key = "Slime", fromStage = 1, fromFraction = 0 },
			{ key = "BigSlime", fromStage = 2, fromFraction = 0.5 },
			{ key = "MegaSlime", fromStage = 4, fromFraction = 0.5 },
		},
		bossKeys = { "SlimeKing" },
	},

	--[[
		Дремучий лес: все слизни с первого же уровня локации, и к ним гоблины.

		Гоблины появятся вместе со своим кодом (мечник и лучник — следующий
		кусок работы). Пока локация играется на слизнях: она честно сложнее
		первой за счёт того, что все три вида идут с самого начала.
	]]
	{
		key = "DeepForest",
		displayName = "Deep Forest",
		levels = 0,
		palette = "DeepForest",
		enemies = {
			{ key = "Slime", fromStage = 1, fromFraction = 0 },
			{ key = "BigSlime", fromStage = 1, fromFraction = 0 },
			{ key = "MegaSlime", fromStage = 1, fromFraction = 0.35 },
			-- Мечник — со второй половины первого уровня локации, лучник —
			-- со второй половины третьего: решение владельца.
			{ key = "GoblinSwordsman", fromStage = 1, fromFraction = 0.5 },
			{ key = "GoblinArcher", fromStage = 3, fromFraction = 0.5 },
		},
		bossKeys = { "GoblinShaman" },
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
	location.levels = levelsInLocation()
	firstLevelOf[index] = total + 1
	total += location.levels

	assert(#location.enemies > 0, `[Stages] У локации "{location.key}" пустой список врагов`)
	assert(#location.bossKeys > 0, `[Stages] У локации "{location.key}" нет ни одного босса`)

	--[[
		Первый уровень локации обязан кем-то населяться с нулевой секунды:
		враг, введённый позже, оставил бы начало уровня пустым, а игрока —
		без опыта и без понимания, что происходит.
	]]
	local hasOpener = false
	for _, entry in location.enemies do
		assert(
			entry.fromStage >= 1 and entry.fromStage <= location.levels,
			`[Stages] У локации "{location.key}" враг "{entry.key}" появляется на уровне {entry.fromStage}, `
				.. `которого в ней нет`
		)
		assert(
			entry.fromFraction >= 0 and entry.fromFraction < 1,
			`[Stages] У локации "{location.key}" враг "{entry.key}": доля появления вне диапазона [0, 1)`
		)
		if entry.fromStage == 1 and entry.fromFraction == 0 then
			hasOpener = true
		end
		table.freeze(entry)
	end

	assert(
		hasOpener,
		`[Stages] У локации "{location.key}" никто не спавнится с начала первого уровня`
	)

	table.freeze(location.enemies)
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
		перебирая список локации по кругу.

		Счёт идёт ВНУТРИ локации, а не по сквозному номеру: иначе первый уровень
		второй локации продолжал бы чужую нумерацию и брал бы второго босса там,
		где у локации он один.
	]]
	local rotation = math.floor((indexInLocation - 1) / numbers.bossRotation)
	local bossKey = location.bossKeys[rotation % #location.bossKeys + 1]

	--[[
		Кто спавнится на этом уровне и с какой секунды. Доля превращается
		в секунды здесь, чтобы бой сравнивал два числа, а не пересчитывал
		проценты на каждом спавне.
	]]
	local duration = numbers.baseDuration
	local enemies: { Types.StageEnemy } = {}

	for _, entry in location.enemies do
		if entry.fromStage <= indexInLocation then
			table.insert(enemies, {
				key = entry.key,
				-- На уровнях выше того, где враг введён, он идёт с самого начала:
				-- «со второй половины» относится только к дебютному уровню.
				fromSeconds = if entry.fromStage == indexInLocation then entry.fromFraction * duration else 0,
			})
		end
	end

	table.sort(enemies, function(a: Types.StageEnemy, b: Types.StageEnemy): boolean
		return a.fromSeconds < b.fromSeconds
	end)

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
		enemies = enemies,

		bossKey = bossKey,
		bossHealth = math.floor(numbers.bossHealthBase * numbers.bossHealthGrowth ^ step + 0.5),

		essence = math.floor(numbers.essenceBase * numbers.essenceGrowth ^ step + 0.5),
		xp = math.floor(numbers.xpBase * numbers.xpGrowth ^ step + 0.5),
	}
end

--[[
	Обучающий уровень (M7, раздел 4 ТЗ).

	Собирается из первого сюжетного уровня, ослабленного множителями
	Balance.Tutorial: так он остаётся тем же боем с теми же врагами и тем же
	боссом, что и настоящая игра, — а туториал, показывающий механики,
	которых потом не будет, не учит ничему.

	index = 0 и в сюжетной нумерации не участвует: Get(0) по-прежнему nil,
	CanPlay ноль не пропускает, storyStage не двигается. Ноль здесь нужен
	только затем, чтобы у StageDef было чем заполнить обязательное поле,
	и он же — признак «это не сюжетный уровень» для всех, кто получит
	этот StageDef на руки.
]]
function Stages.Tutorial(): StageDef
	local first = Stages.Get(1)
	assert(
		first,
		"[Stages] Нет первого уровня — обучающий уровень собирать не из чего"
	)

	local numbers = Balance.Tutorial

	return {
		index = 0,
		location = first.location,
		indexInLocation = 0,
		isLocationFinal = false,

		duration = numbers.duration,

		enemyHealthMult = first.enemyHealthMult * numbers.enemyHealthMult,
		enemyDamageMult = first.enemyDamageMult * numbers.enemyDamageMult,
		enemySpeedMult = first.enemySpeedMult * numbers.enemySpeedMult,
		--[[
			Тот же набор, что у первого уровня локации: обучение показывает
			ту игру, в которую игрок будет играть, а не облегчённую версию
			с другими врагами.
		]]
		enemies = first.enemies,

		bossKey = first.bossKey,
		bossHealth = math.floor(first.bossHealth * numbers.bossHealthMult + 0.5),

		--[[
			Награда обучающего уровня не отсюда: она одноразовая, выражена
			через цену яйца и остаток опыта до уровня, и живёт в Config/Tutorial.
			Здесь нули, чтобы обычный путь начисления по StageDef ничего
			не выплатил, если однажды забудет про режим.
		]]
		essence = 0,
		xp = 0,
	}
end

table.freeze(locations)
table.freeze(firstLevelOf)

return Stages
