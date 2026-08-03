--!strict
--[[
	Rewards — экономика наград за забег (правило 6 ТЗ: числа здесь, логика в RewardService).

	Числа стартовые и заведомо неточные: настоящую кривую видно только после
	десятка забегов. Крутить нужно эти два значения, код при этом не трогается.

	ЯКОРЬ ЭКОНОМИКИ: десять минут боя ≈ одно базовое яйцо (Config/Eggs).
	Награда за забег и цены — две стороны одного числа, поэтому менять их
	нужно вместе. Если правишь здесь — пройди по ценам в Config/Eggs,
	Config/Shop и Balance.Pets.rarityUpgradeCost, иначе экономика поедет.

	Награда за сюжетный уровень и утешительные 10% за поражение (раздел 5.1 ТЗ)
	появятся в M6 вместе с самими уровнями: сейчас у забега нет условия победы,
	поэтому любой забег считается по одной формуле.
]]

local Balance = require(script.Parent.Balance)
local Types = require(script.Parent.Parent.Types)

local Rewards = {
	Essence = table.freeze({
		perKill = 1, -- за каждого убитого врага
		perMinute = 20, -- за каждую минуту, прожитую на арене
	}),

	--[[
		Опыт персонажа (раздел 6 ТЗ), M5. Считается так же, как валюта, —
		по убийствам и времени: это и есть формула бесконечного режима.
		Фиксированная выдача за сюжетный этап появится в M6 вместе с этапами.

		Числа подобраны так, чтобы забег на десять минут давал несколько
		уровней в начале и заметно меньше ближе к сотому: кривая уровня
		растёт, а выдача за забег — нет.
	]]
	Xp = table.freeze({
		perKill = 0.02,
		perMinute = 25,
	}),
}

--[[
	Сколько Essence начислить за забег.

	Нижней границы («хотя бы N за вход») намеренно нет: она бы превратилась
	в фарм заходом-выходом через портал. Ушёл через две секунды — получил ноль.
]]
function Rewards.EssenceForRun(kills: number, time: number): number
	local essence = kills * Rewards.Essence.perKill + (time / 60) * Rewards.Essence.perMinute
	return math.floor(essence)
end

--[[
	Сколько опыта персонажа начислить за забег.

	Нижней границы нет по той же причине, что и у валюты: она превратилась бы
	в фарм заходом-выходом через портал.
]]
function Rewards.XpForRun(kills: number, time: number): number
	local xp = kills * Rewards.Xp.perKill + (time / 60) * Rewards.Xp.perMinute
	return math.floor(xp)
end

--[[
	Награда за сюжетный уровень (раздел 5.1 ТЗ), M6.

	Здесь награда НЕ зависит от убийств и времени: за уровень платят фиксированно,
	по номеру уровня, и числа приходят готовыми из Stages.Get(index). Иначе
	выгоднее было бы фармить один и тот же лёгкий уровень подольше, вместо того
	чтобы идти дальше.

	Возвращает (Essence, опыт).
]]
function Rewards.ForStage(stage: Types.StageDef, victory: boolean, timeSurvived: number): (number, number)
	if victory then
		return stage.essence, stage.xp
	end

	--[[
		Поражение: доля от полной награды, пропорционально прожитому времени
		(раздел 5.1 ТЗ). Только Essence и опыт — ни предметов, ни Prisms.
		Смысл в том, чтобы неудачные пятнадцать минут не ощущались потерянными,
		но и не стали работающей стратегией фарма: доля мала, а уровень
		при этом не засчитывается.
	]]
	local fraction = math.clamp(timeSurvived / stage.duration, 0, 1) * Balance.Stages.defeatFraction

	return math.floor(stage.essence * fraction), math.floor(stage.xp * fraction)
end

return table.freeze(Rewards)
