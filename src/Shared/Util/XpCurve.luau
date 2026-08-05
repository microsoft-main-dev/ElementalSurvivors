--!strict
--[[
	XpCurve — стоимость уровней внутри забега, выведенная из правила.

	ПРАВИЛО: полностью собранный билд должен получаться примерно за
	buildCompleteBefore секунд до выхода босса. Не «за столько-то опыта»,
	а именно за столько-то до конца — иначе при каждой правке длительности
	забега или расписания волн кривую пришлось бы подбирать заново руками.

	Как считается:

		1. Из Config/Waves берётся ожидаемый доход опыта: на каждом отрезке
		   расписания это скорость спавна × средний опыт врага этого отрезка.
		   Интеграл до нужной секунды и есть весь опыт забега.
		2. Число улучшений известно: слотов × уровней − 1 (стартовая
		   способность приходит с питомцем уже первого уровня).
		3. Масштаб кривой решается из уравнения «сумма всех улучшений равна
		   этому доходу». Форма кривой (насколько дорожает каждый следующий
		   уровень) остаётся настройкой в Balance.

	Почему доход считается по СПАВНУ, а не по убийствам: сервер не знает
	заранее, сколько игрок убьёт, но на практике это одно и то же — замер
	владельца дал 18 451 убитых за 12:55 при 17 610 заспавненных по расписанию.
	Разницу закрывает xpIncomeFactor, и он же единственная ручка калибровки,
	если реальный забег разойдётся с расчётом.

	Публичный API:
		XpCurve.ForLevel(level)      -> number
		XpCurve.ProjectedXp(seconds) -> number
		XpCurve.Upgrades             -> number
		XpCurve.Target               -> number
		XpCurve.Describe()           -> string
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Balance = require(Shared.Config.Balance)
local Enemies = require(Shared.Config.Enemies)
local Waves = require(Shared.Config.Waves)

local XpCurve = {}

-- Средний опыт врага на этом отрезке расписания.
local function averageXp(types: { string }): number
	local total = 0
	local count = 0

	for _, key in types do
		local def = Enemies.ByKey[key]
		if def then
			total += def.stats.xp
			count += 1
		end
	end

	return if count > 0 then total / count else 1
end

--[[
	Сколько опыта игрок ожидаемо соберёт за первые seconds секунд.

	Последняя строка расписания действует до конца забега, каким бы длинным
	он ни был: у бесконечного режима конца нет вовсе.
]]
function XpCurve.ProjectedXp(seconds: number): number
	if seconds <= 0 then
		return 0
	end

	local total = 0

	for index, wave in Waves do
		local from = wave.time
		if from >= seconds then
			break
		end

		local nextWave = Waves[index + 1]
		local to = if nextWave then math.min(nextWave.time, seconds) else seconds
		total += wave.spawnRate * averageXp(wave.types) * (to - from)
	end

	return total * Balance.Progression.xpIncomeFactor
end

--[[
	Сколько всего карточек нужно на полный билд.

	Минус один: стартовую способность приносит питомец, и её первый уровень
	игрок не выбирает.
]]
XpCurve.Upgrades = Balance.Progression.maxActiveAbilities * Balance.Progression.maxAbilityLevel - 1

-- К какой секунде билд обязан быть собран.
local completeAt = math.max(Balance.Stages.baseDuration - Balance.Progression.buildCompleteBefore, 1)

XpCurve.CompleteAt = completeAt
XpCurve.Target = XpCurve.ProjectedXp(completeAt)

--[[
	Масштаб кривой из суммы геометрической прогрессии.

	base * (g^n - 1) / (g - 1) = Target, откуда base и берётся. Рост строго
	больше единицы проверяется в Balance, поэтому делить здесь безопасно.
]]
local growth = Balance.Progression.xpGrowth
local series = (growth ^ XpCurve.Upgrades - 1) / (growth - 1)
XpCurve.Base = XpCurve.Target / series

--[[
	Сколько опыта нужно, чтобы уйти с уровня level на следующий.

	Округление вверх до единицы: уровень стоимостью в ноль опыта выдавался бы
	мгновенно и бесконечно.
]]
function XpCurve.ForLevel(level: number): number
	return math.max(math.floor(XpCurve.Base * growth ^ (level - 1) + 0.5), 1)
end

-- Для отладочной печати при старте: по этим числам видно, сходится ли расчёт.
function XpCurve.Describe(): string
	local last = XpCurve.ForLevel(XpCurve.Upgrades)
	return string.format(
		"[XpCurve] билд из %d улучшений собирается к %d с (босс на %d с): "
			.. "ожидаемый опыт %d, база %.2f, рост %.3f, последний уровень стоит %d",
		XpCurve.Upgrades,
		completeAt,
		Balance.Stages.baseDuration,
		math.floor(XpCurve.Target),
		XpCurve.Base,
		growth,
		last
	)
end

return XpCurve
