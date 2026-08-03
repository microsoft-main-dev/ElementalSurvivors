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
local ItemService = require(script.Parent.ItemService)
local LeaderboardService = require(script.Parent.LeaderboardService)
local QuestService = require(script.Parent.QuestService)
local Rewards = require(Shared.Config.Rewards)
local Stages = require(Shared.Config.Stages)
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

	--[[
		Развилка режимов (раздел 5.1 ТЗ), M6.

		Сюжетный уровень платит фиксированно по номеру уровня, а не по убийствам:
		иначе выгоднее было бы бесконечно фармить один лёгкий уровень, вместо
		того чтобы идти дальше. Проигранный сюжетный уровень даёт утешительную
		долю пропорционально прожитому времени.

		Бесконечный режим считается как раньше — по убийствам и времени.
	]]
	local essence: number
	local xp: number

	local stage = if summary.mode == "Story" then Stages.Get(summary.stageIndex) else nil
	if stage then
		essence, xp = Rewards.ForStage(stage, summary.victory, summary.time)
	else
		essence = Rewards.EssenceForRun(summary.kills, summary.time)
		xp = Rewards.XpForRun(summary.kills, summary.time)
	end

	if essence > 0 then
		DataService.AddCurrency(player, "essence", essence, `run:{summary.mode}:{summary.reason}`)
	end

	--[[
		Опыт персонажа (раздел 6 ТЗ), M5. В отличие от уровней внутри забега,
		этот опыт сохраняется и превращается в очки талантов — правило
		«уровень -> очко» живёт в DataService, здесь только начисление.
	]]
	local levelsGained = if xp > 0 then DataService.AddMetaXp(player, xp) else 0

	--[[
		Рекорд ставится только в бесконечном режиме: стенд рекордсменов —
		это «топ по времени в бесконечном» (раздел 4 ТЗ), и сюжетный забег
		фиксированной длины там не значит ничего.
	]]
	local isEndless = summary.mode == "Endless"
	local _, newBest = DataService.RecordRun(player, summary.kills, summary.time, isEndless)

	--[[
		На стенд уходит рекорд ИЗ ПРОФИЛЯ и после каждого бесконечного забега,
		а не только когда рекорд обновился. Иначе рекорд, поставленный до
		появления стенда, не попал бы на него никогда: игроку пришлось бы
		сначала побить самого себя. Запись в хранилище растёт только вверх,
		поэтому лишние отправки безвредны.
	]]
	if isEndless then
		LeaderboardService.Submit(player, data.progress.endlessBest)
	end

	--[[
		Предметы (раздел 5.1 ТЗ) — только за победу. Проигранный уровень даёт
		утешительную долю валюты и опыта, но ничего уникального: иначе фарм
		поражений стал бы рабочей стратегией.
	]]
	local items: { Types.ItemInstance } = {}
	if stage and summary.victory then
		items = ItemService.GrantForStage(player, stage)
	end

	--[[
		Ежедневные квесты (раздел 4 ТЗ): прогресс тикает из боёв. Записывается
		после начисления, но до сейва — чтобы всё уходило в хранилище разом.
	]]
	QuestService.EnsureFresh(player)
	QuestService.Record(player, "Kills", summary.kills)
	QuestService.Record(player, "Runs", 1)
	QuestService.Record(player, "Survive", math.floor(summary.time))
	if summary.victory then
		QuestService.Record(player, "StageClear", 1)
	end

	--[[
		Сейв сразу после начисления, не дожидаясь автосейва. Автосейв закрывает
		критерий «не больше 60 с потерь», но терять именно награду за забег
		обиднее всего остального вместе взятого.
	]]
	DataService.SaveNow(player)
	DataService.PushView(player)

	return {
		reason = summary.reason,
		mode = summary.mode,
		stageIndex = summary.stageIndex,
		victory = summary.victory,
		time = summary.time,
		kills = summary.kills,
		level = summary.level,
		abilities = summary.abilities,
		essence = essence,
		newBest = newBest,
		currency = { essence = data.currency.essence, prisms = data.currency.prisms },

		xp = xp,
		metaLevel = data.level,
		levelsGained = levelsGained,
		talentPoints = data.talentPoints,
		items = items,
	}
end

return RewardService
