--!strict
--[[
	RewardService — награда за забег.

	Считается только по серверной статистике: клиентские цифры не принимаются
	никогда (раздел 7 ТЗ). Здесь нет ни одного Remote и ни одной подписки на
	клиентский ввод — сервис вызывается изнутри CombatService и всё.

	Сами числа лежат в Config/Rewards, тут только порядок действий:
	начислить -> записать статистику -> сохранить -> собрать пакет для экрана.

	Публичный API:
		RewardService.Award(player, summary) -> RunResult?
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local DataService = require(script.Parent.DataService)
local Rewards = require(Shared.Config.Rewards)
local Types = require(Shared.Types)

local RewardService = {}

--[[
	Начисляет награду за забег и возвращает итоги для экрана результатов.
	nil означает, что начислять было некуда: профиля нет (игрок уже ушёл
	или его кикнуло на загрузке).

	Функция обязана обходиться без yield: её вызывают в том числе из
	release-хука DataService, то есть при выходе игрока и выключении сервера.
]]
function RewardService.Award(player: Player, summary: Types.RunSummary): Types.RunResult?
	local data = DataService.GetProfile(player)
	if not data then
		warn(`[RewardService] Награда без профиля: {player.Name}`)
		return nil
	end

	local essence = Rewards.EssenceForRun(summary.kills, summary.time)
	if essence > 0 then
		DataService.AddCurrency(player, "essence", essence, `run:{summary.reason}`)
	end

	local _, newBest = DataService.RecordRun(player, summary.kills, summary.time)

	--[[
		Сейв сразу после начисления, не дожидаясь автосейва. Автосейв закрывает
		критерий «не больше 60 с потерь», но терять именно награду за забег
		обиднее всего остального вместе взятого.
	]]
	DataService.SaveNow(player)
	DataService.PushView(player)

	return {
		reason = summary.reason,
		time = summary.time,
		kills = summary.kills,
		level = summary.level,
		abilities = summary.abilities,
		essence = essence,
		newBest = newBest,
		currency = { essence = data.currency.essence, prisms = data.currency.prisms },
	}
end

return RewardService
