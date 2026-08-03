--!strict
--[[
	QuestService — ежедневные квесты (раздел 4 ТЗ), M6.

	Три задания в день, прогресс тикает из боёв, награда забирается вручную:
	молча начисленная награда не замечается, а квест, который надо забрать,
	возвращает игрока в лобби.

	Сутки считаются по серверному os.time(). Клиент не сообщает ни своего
	времени, ни часового пояса — иначе перевод часов на телефоне давал бы
	свежий набор заданий когда угодно.

	Набор заданий хранится в профиле целиком, а не ссылкой на таблицу:
	правка Config/Quests не должна менять условия у задания, которое игрок
	уже начал выполнять сегодня.

	Публичный API:
		QuestService.EnsureFresh(player)
		QuestService.Record(player, kind, amount)
		QuestService.Claim(player, questId) -> (boolean, string?)
		QuestService.BuildView(player)      -> QuestsView?
		QuestService.PushView(player)
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Balance = require(Shared.Config.Balance)
local DataService = require(script.Parent.DataService)
local Net = require(Shared.Net)
local Types = require(Shared.Types)

type ProfileQuest = Types.ProfileQuest
type QuestKind = Types.QuestKind

local QuestService = {}

local viewRemote: RemoteEvent? = nil

--[[
	Шаблоны заданий. Цели умеренные намеренно: ежедневка должна закрываться
	за пару забегов, а не требовать отдельного вечера — иначе она превращается
	в обязанность, а не в повод зайти.
]]
local TEMPLATES: { { kind: QuestKind, displayName: string, target: number, reward: number } } = {
	{ kind = "Kills", displayName = "Defeat 20 000 enemies", target = 20000, reward = 1 },
	{ kind = "Kills", displayName = "Defeat 40 000 enemies", target = 40000, reward = 2 },
	{ kind = "Runs", displayName = "Finish 2 runs", target = 2, reward = 1 },
	{ kind = "Runs", displayName = "Finish 4 runs", target = 4, reward = 2 },
	{ kind = "Survive", displayName = "Survive 15 minutes total", target = 900, reward = 1 },
	{ kind = "StageClear", displayName = "Clear a story stage", target = 1, reward = 2 },
}

local random = Random.new()

--[[
	Момент следующего сброса. Привязан к суткам от эпохи, а не к «сейчас плюс
	24 часа»: иначе у игрока, зашедшего в 23:59, сутки сдвигались бы каждый день.
]]
local function nextResetAt(): number
	local period = Balance.Daily.resetPeriod
	return (os.time() // period + 1) * period
end

local function buildQuests(): { ProfileQuest }
	local pool = table.clone(TEMPLATES)
	local quests: { ProfileQuest } = {}
	local wanted = math.min(Balance.Daily.questCount, #pool)

	for index = 1, wanted do
		local pick = random:NextInteger(1, #pool)
		local template = pool[pick]
		table.remove(pool, pick)

		table.insert(quests, {
			id = `q{index}`,
			kind = template.kind,
			target = template.target,
			progress = 0,
			essence = Balance.Daily.questEssenceBase * template.reward,
			claimed = false,
		})
	end

	return quests
end

--[[
	Выдать свежий набор, если сутки сменились. Зовётся при входе и после забега:
	игрок вполне может сидеть в игре через полночь.
]]
function QuestService.EnsureFresh(player: Player): boolean
	local data = DataService.GetProfile(player)
	if not data then
		return false
	end

	if os.time() < data.daily.resetAt and #data.daily.quests > 0 then
		return false
	end

	DataService.SetDailyQuests(player, buildQuests(), nextResetAt())
	QuestService.PushView(player)
	return true
end

function QuestService.Record(player: Player, kind: QuestKind, amount: number): ()
	if DataService.AddQuestProgress(player, kind, amount) then
		QuestService.PushView(player)
	end
end

function QuestService.Claim(player: Player, questId: string): (boolean, string?)
	local essence = DataService.ClaimQuest(player, questId)
	if essence <= 0 then
		return false, nil
	end

	DataService.SaveNow(player)
	QuestService.PushView(player)
	return true, `Quest reward: {essence} Essence.`
end

function QuestService.BuildView(player: Player): Types.QuestsView?
	local data = DataService.GetProfile(player)
	if not data then
		return nil
	end

	local views: { Types.QuestView } = {}
	for _, quest in data.daily.quests do
		table.insert(views, {
			id = quest.id,
			kind = quest.kind,
			-- Подпись собирается из данных задания, а не хранится в профиле:
			-- текст — это интерфейс, и в сохранении ему делать нечего.
			displayName = quest.kind,
			target = quest.target,
			progress = quest.progress,
			essence = quest.essence,
			claimed = quest.claimed,
		})
	end

	return {
		quests = views,
		resetsInSeconds = math.max(data.daily.resetAt - os.time(), 0),
	}
end

function QuestService.PushView(player: Player): ()
	local remote = viewRemote
	if not remote then
		return
	end

	local view = QuestService.BuildView(player)
	if view then
		remote:FireClient(player, view)
	end
end

function QuestService.Init(): ()
	viewRemote = Net.GetEvent(Net.Id.QuestsView)
end

return QuestService
