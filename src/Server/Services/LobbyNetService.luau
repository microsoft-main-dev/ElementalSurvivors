--!strict
--[[
	LobbyNetService — единственная точка приёма клиентского ввода в лобби.

	Причина ровно та же, по которой профиль пишет только DataService: список
	того, что игрок вообще может попросить, обязан помещаться в один файл.
	Здесь этот список закрытый, и всё, чего в нём нет, отбрасывается на входе.

	Что проверяется у каждого запроса (раздел 7 ТЗ):
		- rate limit на игрока;
		- действие входит в закрытый список;
		- типы и длина аргументов (строка с клиента — это не ключ, а строка);
		- право: игрок не в забеге, покупка по балансу, питомец принадлежит ему.

	Сами проверки владения и баланса делают сервисы, которые этим владеют:
	здесь только вход, валидация формы и маршрутизация.

	Он же выполняет вход в лобби: выдать стартового питомца новому игроку,
	отправить коллекцию и показать отчёт экспедиций. Порядок именно такой —
	отчёт считается от коллекции, поэтому питомец должен появиться раньше.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local CombatService = require(script.Parent.CombatService)
local DataService = require(script.Parent.DataService)
local EggService = require(script.Parent.EggService)
local ItemService = require(script.Parent.ItemService)
local Net = require(Shared.Net)
local OfflineService = require(script.Parent.OfflineService)
local PetService = require(script.Parent.PetService)
local PurchaseService = require(script.Parent.PurchaseService)
local QuestService = require(script.Parent.QuestService)
local RateLimiter = require(Shared.Util.RateLimiter)
local StageService = require(script.Parent.StageService)
local TalentService = require(script.Parent.TalentService)
local TutorialService = require(script.Parent.TutorialService)
local Types = require(Shared.Types)
local WheelService = require(script.Parent.WheelService)

--[[
	Лимит: 12 действий за 3 секунды. Заметно выше, чем успевает нажать человек
	(покупка ×10 — это один вызов, а не десять), и заметно ниже, чем нужно,
	чтобы что-нибудь заспамить.
]]
local RATE_MAX_CALLS = 12
local RATE_WINDOW = 3

-- Ключи в проекте короткие; всё длиннее — это не ключ, а попытка что-то сломать.
local MAX_KEY_LENGTH = 32

local LobbyNetService = {}

local requestRemote: RemoteEvent? = nil
local notifyRemote: RemoteEvent? = nil
local eggResultRemote: RemoteEvent? = nil
local limiter = RateLimiter.new(RATE_MAX_CALLS, RATE_WINDOW)

--[[
	Закрытый список действий. Строка с клиента сверяется с ним и больше нигде
	не используется как есть.

	Список типизирован как { LobbyAction }, а множество для проверки строится
	из него: так добавить действие мимо описанного в Types контракта нельзя —
	типизация не пропустит. Само множество по строке, потому что с клиента
	приходит именно строка, а не значение из union.
]]
local ALLOWED_ACTIONS: { Types.LobbyAction } = {
	"BuyEgg",
	"EquipPet",
	"UpgradePet",
	"EvolvePet",
	"BuyLot",
	"ClaimOffline",
	"SpendTalent",
	"ResetTalents",
	"EnterRun",
	"SpinWheel",
	"ClaimQuest",
	"EquipItem",
	"Refresh",
	"SetSetting",
	"TutorialDone",
	"DebugBossFight",
}

local ALLOWED: { [string]: boolean } = {}
for _, action in ALLOWED_ACTIONS do
	ALLOWED[action] = true
end

local function notify(player: Player, message: string?): ()
	local remote = notifyRemote
	if remote and message then
		remote:FireClient(player, message)
	end
end

-- Строка приемлемой формы или nil. Ничего не «чинит»: подозрительный
-- аргумент отбрасывается целиком, а не приводится к чему-то похожему.
local function readKey(value: unknown): string?
	if typeof(value) ~= "string" then
		return nil
	end
	local text = value :: string
	if #text == 0 or #text > MAX_KEY_LENGTH then
		return nil
	end
	return text
end

local function readCount(value: unknown): number
	if typeof(value) ~= "number" then
		return 1
	end
	local number = value :: number
	-- NaN и бесконечность до арифметики цены допускать нельзя.
	if number ~= number or number == math.huge or number == -math.huge then
		return 1
	end
	return math.floor(number)
end

--[[
	Результат покупки яйца — на клиент. Показывать нечего, если ничего
	не выпало: пустая пачка означает, что выдача не состоялась.
]]
local function sendEggResults(player: Player, results: { Types.EggRollResult }): ()
	local remote = eggResultRemote
	if not remote or #results == 0 then
		return
	end
	remote:FireClient(player, results)
end

--[[
	Третий аргумент значит разное у разных действий: у покупки яйца это число
	роллов, у лота с опытом — uid питомца. Разбирается он поэтому не на входе,
	а в ветке своего действия: общий «универсальный» разбор здесь означал бы,
	что каждое действие получает и то, чего не просило.
]]
local function handle(player: Player, action: string, target: string?, extra: unknown): ()
	if action == "Refresh" then
		PetService.PushView(player)
		TalentService.PushView(player)
		ItemService.PushView(player)
		-- Бустеры могли истечь, пока игрок был в бою.
		PurchaseService.PushView(player)
		-- Сутки могли смениться, пока игрок был в бою.
		QuestService.EnsureFresh(player)
		QuestService.PushView(player)
		--[[
			Обучение: Refresh приходит и после возвращения из боя, то есть
			ровно тогда, когда обязательный забег закончился и пора вести
			тур по лобби. Второго канала под это заводить не надо.
		]]
		TutorialService.PushView(player)
		DataService.PushView(player)
		return
	end

	if action == "ResetTalents" then
		local _, message = TalentService.Reset(player)
		notify(player, message)
		return
	end

	--[[
		Вход в бой. Режим и номер уровня приходят с клиента и проверяются
		целиком внутри CombatService: право играть уровень, свободный слот,
		кулдаун входа. Здесь только разбор аргументов.
	]]
	if action == "EnterRun" then
		--[[
			Режим — из закрытого списка, а не «всё, что не Story, — Endless»:
			с появлением обучающего режима (M7) такая развилка молча пускала бы
			опечатку в бесконечный режим.
		]]
		local mode: Types.RunMode
		if target == "Story" then
			mode = "Story"
		elseif target == "Tutorial" then
			mode = "Tutorial"
		elseif target == "Endless" then
			mode = "Endless"
		else
			return
		end

		CombatService.BeginRun(player, mode, readCount(extra))
		return
	end

	--[[
		Тестовые кнопки боссов (M7): по одной на локацию, номер уровня приходит
		третьим аргументом. CombatService сам не пускает их мимо Studio.
	]]
	if action == "DebugBossFight" then
		CombatService.BeginBossFightTest(player, readCount(extra))
		return
	end

	--[[
		Тур по лобби пройден (M7, раздел 4 ТЗ). Аргументов нет и быть не может:
		шаги тура — это клиентский рисунок, а на сервере от него остаётся один
		флаг «обучение закончено».
	]]
	if action == "TutorialDone" then
		TutorialService.Complete(player)
		return
	end

	if action == "SpinWheel" then
		local _, message = WheelService.Spin(player)
		notify(player, message)
		return
	end

	if action == "ClaimOffline" then
		local essence = OfflineService.Claim(player)
		if essence > 0 then
			notify(player, `Expedition rewards collected: {essence} Essence.`)
		end
		return
	end

	if action == "BuyEgg" then
		if not target then
			return
		end
		local ok, results, message = EggService.BuyEgg(player, target, readCount(extra))
		if ok then
			sendEggResults(player, results)
		end
		notify(player, message)
		return
	end

	if action == "BuyLot" then
		if not target then
			return
		end
		-- Лоту с опытом нужен uid питомца; лоту с яйцами он не нужен вовсе,
		-- и пустая строка там ни на что не влияет.
		local ok, results, message = EggService.BuyLot(player, target, readKey(extra) or "")
		if ok then
			sendEggResults(player, results)
		end
		notify(player, message)
		return
	end

	if not target then
		return
	end

	--[[
		Настройки (M7, раздел 2.1 ТЗ). target — ключ поля, extra — значение;
		разбор и вся валидация — внутри DataService.SetSetting, здесь только
		передача. Сообщение об ошибке не шлём: неверное значение — это либо
		рассинхрон версий клиента и сервера, либо испорченный ввод, а не то,
		что нужно объяснять игроку.
	]]
	if action == "SetSetting" then
		DataService.SetSetting(player, target, extra)
		return
	end

	if action == "EquipPet" then
		local _, message = PetService.Equip(player, target)
		notify(player, message)
		return
	end

	if action == "UpgradePet" then
		local _, message = PetService.Upgrade(player, target)
		notify(player, message)
		return
	end

	if action == "EvolvePet" then
		local _, message = PetService.Evolve(player, target)
		notify(player, message)
		return
	end

	if action == "SpendTalent" then
		local _, message = TalentService.Spend(player, target)
		notify(player, message)
		return
	end

	if action == "EquipItem" then
		local _, message = ItemService.Equip(player, target)
		notify(player, message)
		return
	end

	if action == "ClaimQuest" then
		local _, message = QuestService.Claim(player, target)
		notify(player, message)
	end
end

local function onRequest(player: Player, action: unknown, target: unknown, extra: unknown): ()
	if not limiter.Allow(player) then
		return
	end

	local name = readKey(action)
	if not name or not ALLOWED[name] then
		return
	end

	--[[
		В забеге лобби недоступно. Это не столько защита от читерства, сколько
		защита от самой ситуации: покупка на четырнадцатой минуте боя изменила
		бы профиль, который в этот момент вот-вот получит награду за забег.
	]]
	if CombatService.GetRunStats(player) then
		return
	end

	if not DataService.GetProfile(player) then
		return
	end

	handle(player, name, readKey(target), extra)
end

--[[
	Вход игрока в лобби. Порядок обязателен и весь состоит из зависимостей:
	стартовый питомец меняет коллекцию, от коллекции считается доход
	экспедиций, а окно показывается уже по начисленной копилке.
]]
local function onPlayerAdded(player: Player): ()
	if not DataService.WaitForProfile(player) then
		return
	end

	PetService.GrantStarterIfNeeded(player)
	StageService.DebugUnlockIfNeeded(player)
	OfflineService.Accrue(player)
	QuestService.EnsureFresh(player)
	WheelService.DebugResetIfNeeded(player)

	PetService.PushView(player)
	TalentService.PushView(player)
	ItemService.PushView(player)
	QuestService.PushView(player)
	OfflineService.PushReport(player)
end

function LobbyNetService.Init(): ()
	requestRemote = Net.GetEvent(Net.Id.LobbyRequest)
	notifyRemote = Net.GetEvent(Net.Id.Notify)
	eggResultRemote = Net.GetEvent(Net.Id.EggResult)
end

function LobbyNetService.Start(): ()
	local remote = requestRemote
	if remote then
		remote.OnServerEvent:Connect(onRequest)
	end

	for _, player in Players:GetPlayers() do
		task.spawn(onPlayerAdded, player)
	end
	Players.PlayerAdded:Connect(function(player: Player)
		task.spawn(onPlayerAdded, player)
	end)

	Players.PlayerRemoving:Connect(function(player: Player)
		limiter.Forget(player)
	end)
end

return LobbyNetService
