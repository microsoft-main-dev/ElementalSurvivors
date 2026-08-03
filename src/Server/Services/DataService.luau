--!strict
--[[
	DataService — единственное место в проекте, которое трогает DataStore.

	Профиль игрока — единственный источник правды (раздел 2 ТЗ). Клиент никогда
	не сообщает, сколько ему начислить, и вообще не участвует в записи: наружу
	отсюда торчат только конкретные операции («начислить валюту», «записать
	итоги забега»), а не универсальная «поменяй мне вот это поле». Так список
	того, что вообще может изменить профиль, виден целиком в этом файле.

	Session locking даёт ProfileStore: пока сессия профиля занята одним сервером,
	второй её не откроет, а если откроет силой — первый узнает об этом через
	OnSessionEnd и кикнет игрока. Без этого две вкладки одного аккаунта на разных
	серверах спокойно дюпили бы валюту.

	Порядок входа жёсткий: профиль -> персонаж. Пока профиль не загружен,
	персонажа в мире нет (CharacterAutoLoads выключен в CombatService), поэтому
	заработать что-либо без профиля физически невозможно.

	Публичный API:
		DataService.GetProfile(player)                        -> ProfileData?
		DataService.WaitForProfile(player, timeout?)          -> ProfileData?
		DataService.AddCurrency(player, kind, amount, reason) -> boolean
		DataService.RecordRun(player, kills, duration)        -> (boolean, boolean)
		DataService.SaveNow(player)
		DataService.SetReleaseHook(fn)
		DataService.PushView(player)
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Balance = require(Shared.Config.Balance)
local Net = require(Shared.Net)
local ProfileSchema = require(script.Parent.Parent.Lib.ProfileSchema)
local ProfileStore = require(script.Parent.Parent.Lib.ProfileStore)
local Types = require(Shared.Types)

type ProfileData = Types.ProfileData
type Profile = ProfileStore.Profile<ProfileData>

local KICK_LOAD_FAILED = "Could not load your save data. Please rejoin in a moment."
local KICK_SESSION_TAKEN = "Your save data was opened on another server."

local POLL_INTERVAL = 0.1

local DataService = {}

local store: ProfileStore.ProfileStore<ProfileData>? = nil
local profiles: { [Player]: Profile } = {}
local releaseHook: ((player: Player) -> ())? = nil
local viewRemote: RemoteEvent? = nil

--[[
	Все изменения валюты и предметов логируются (раздел 7 ТЗ). Пока это просто
	серверный лог: разбирать по нему аномалии можно уже сейчас, а внешняя
	аналитика появится не раньше M7.
]]
local function logGrant(player: Player, kind: string, amount: number, reason: string, balance: number): ()
	print(`[DataService] {player.Name} +{amount} {kind} ({reason}); баланс: {balance}`)
end

local function isSaneAmount(value: number): boolean
	-- NaN, бесконечность и дробные значения в профиль попасть не должны:
	-- одно такое число ломает и сериализацию, и все последующие сравнения.
	return value == value and value ~= math.huge and value ~= -math.huge and value % 1 == 0
end

function DataService.GetProfile(player: Player): ProfileData?
	local profile = profiles[player]
	if not profile then
		return nil
	end
	return profile.Data :: ProfileData
end

--[[
	Ждёт загрузки профиля. Нужен всем, кто должен что-то сделать «после входа»:
	порядок Start у сервисов ничего не гарантирует, а профиль грузится с задержкой
	в сеть. Возвращает nil, если игрок ушёл или загрузка не удалась.
]]
function DataService.WaitForProfile(player: Player, timeout: number?): ProfileData?
	local deadline = os.clock() + (timeout or Balance.Data.profileWaitTimeout)

	while os.clock() < deadline do
		local data = DataService.GetProfile(player)
		if data then
			return data
		end
		if player.Parent ~= Players then
			return nil
		end
		task.wait(POLL_INTERVAL)
	end

	return DataService.GetProfile(player)
end

function DataService.PushView(player: Player): ()
	local remote = viewRemote
	local data = DataService.GetProfile(player)
	if not remote or not data then
		return
	end

	local view: Types.ProfileView = {
		essence = data.currency.essence,
		prisms = data.currency.prisms,
		endlessBest = data.progress.endlessBest,
		totalRuns = data.stats.totalRuns,
	}
	remote:FireClient(player, view)
end

--[[
	Начисление валюты. Только положительное: списание — это отдельная операция
	с проверкой баланса, и появится она вместе с первым магазином (M4).
]]
function DataService.AddCurrency(player: Player, kind: Types.CurrencyKind, amount: number, reason: string): boolean
	if amount <= 0 or not isSaneAmount(amount) then
		warn(
			`[DataService] Отклонено начисление {amount} {kind} игроку {player.Name} ({reason})`
		)
		return false
	end

	local data = DataService.GetProfile(player)
	if not data then
		warn(`[DataService] Начисление {amount} {kind} без профиля: {player.Name} ({reason})`)
		return false
	end

	-- Ветка вместо currency[kind] намеренно: так строгая типизация видит,
	-- что записывается число в конкретное поле, а не что угодно куда угодно.
	local currency = data.currency
	local balance: number

	if kind == "essence" then
		balance = currency.essence + amount
		currency.essence = balance
	else
		balance = currency.prisms + amount
		currency.prisms = balance
	end

	logGrant(player, kind, amount, reason, balance)

	DataService.PushView(player)
	return true
end

--[[
	Итоги забега в статистику профиля.
	Возвращает (записано ли, стало ли время рекордом).
]]
function DataService.RecordRun(player: Player, kills: number, duration: number): (boolean, boolean)
	local data = DataService.GetProfile(player)
	if not data then
		return false, false
	end

	if not isSaneAmount(kills) or kills < 0 then
		warn(`[DataService] Некорректное число убийств у {player.Name}: {kills}`)
		return false, false
	end

	-- Время приходит в секундах с дробной частью — округляем при записи,
	-- потому что в профиле дробям делать нечего.
	local seconds = math.floor(math.max(duration, 0))

	local stats = data.stats
	stats.totalRuns += 1
	stats.totalKills += kills
	stats.playtime += seconds

	local newBest = seconds > data.progress.endlessBest
	if newBest then
		data.progress.endlessBest = seconds
	end

	return true, newBest
end

function DataService.SaveNow(player: Player): ()
	-- На выключении сервера ProfileStore сохраняет всех сам, и очередь запросов
	-- там и так плотная: свой Save в этот момент только мешает.
	if ProfileStore.IsClosing then
		return
	end

	local profile = profiles[player]
	if profile and profile:IsActive() then
		profile:Save()
	end
end

--[[
	Хук, который вызывается перед закрытием сессии профиля.

	Нужен из-за забегов: игрок, вышедший на четырнадцатой минуте, должен получить
	награду, а не потерять её. Прямой вызов CombatService отсюда сделал бы
	круговую зависимость (CombatService -> RewardService -> DataService),
	поэтому подписывается сам CombatService, как он уже делает у EnemyService.

	Хук обязан отработать без единого yield: он выполняется в том числе при
	выключении сервера, где право на паузу уже никто не гарантирует.
]]
function DataService.SetReleaseHook(fn: (player: Player) -> ()): ()
	releaseHook = fn
end

local function runReleaseHook(player: Player): ()
	local hook = releaseHook
	if not hook then
		return
	end

	local ok, err = pcall(hook, player)
	if not ok then
		warn(`[DataService] Release-хук упал на {player.Name}: {err}`)
	end
end

local function releaseProfile(player: Player): ()
	local profile = profiles[player]
	if not profile then
		return
	end

	runReleaseHook(player)

	profiles[player] = nil
	profile:EndSession()
end

local function loadProfile(player: Player): ()
	local activeStore = store
	if not activeStore then
		return
	end

	--[[
		Cancel прекращает попытки, если игрок ушёл, не дождавшись загрузки:
		иначе сессия откроется уже пустому месту и будет держать лок.
		Тип params в библиотеке описывает только Steal, поэтому здесь каст —
		это граница с чужим кодом, дальше идут только наши типы.
	]]
	local params = {
		Cancel = function(): boolean
			return player.Parent ~= Players
		end,
	} :: any

	local profile = activeStore:StartSessionAsync(ProfileSchema.KeyFor(player.UserId), params)

	if not profile then
		-- Сюда попадаем, если игрок ушёл во время загрузки или DataStore недоступен.
		if player.Parent == Players then
			warn(`[DataService] Профиль {player.Name} не загрузился`)
			player:Kick(KICK_LOAD_FAILED)
		end
		return
	end

	profile:AddUserId(player.UserId) -- GDPR: профиль привязан к аккаунту
	profile:Reconcile() -- дольёт поля, добавленные в Template после прошлого входа

	local data = profile.Data :: ProfileData
	if ProfileSchema.Migrate(data) then
		-- Смигрированный профиль сохраняем сразу: иначе миграция будет
		-- выполняться заново каждый вход, пока не сработает автосейв.
		profile:Save()
	end

	--[[
		Сессию перехватил другой сервер. Для игрока это означает, что дальше
		его действия никуда не сохранятся, поэтому единственный честный выход —
		отключить его, а не давать играть в пустоту.
	]]
	profile.OnSessionEnd:Connect(function()
		profiles[player] = nil
		if player.Parent == Players then
			player:Kick(KICK_SESSION_TAKEN)
		end
	end)

	-- Игрок мог уйти, пока шла загрузка: сессию нужно закрыть, лок не держим.
	if player.Parent ~= Players then
		profile:EndSession()
		return
	end

	profiles[player] = profile
	DataService.PushView(player)
end

function DataService.Init(): ()
	viewRemote = Net.GetEvent(Net.Id.ProfileView)

	-- У ProfileStore автосейв по умолчанию раз в 300 с, а критерий приёмки M3 —
	-- потеря не более 60 с прогресса при вылете сервера.
	ProfileStore.SetConstant("AUTO_SAVE_PERIOD", Balance.Data.autosaveInterval)

	-- Единственный каст на границе с библиотекой: её Template типизирован через
	-- JSONAcceptable, наш — через ProfileData. Дальше везде наши типы.
	local created: any = ProfileStore.New(ProfileSchema.StoreName, ProfileSchema.Template :: any)
	store = created

	--[[
		Выключение сервера. Сами профили сохранит ProfileStore (у него свой
		BindToClose), нам нужно лишь успеть дописать в них незавершённые забеги.

		Подписка стоит в Init намеренно: свой BindToClose библиотека вешает
		позже, из потока, который ждёт ответа DataStore, — так наш обработчик
		оказывается первым в очереди. Внутри нет ни одного yield, поэтому,
		начавшись, он дописывает профиль целиком до того, как начнётся сейв.
	]]
	game:BindToClose(function()
		for player in profiles do
			runReleaseHook(player)
		end
	end)
end

function DataService.Start(): ()
	for _, player in Players:GetPlayers() do
		task.spawn(loadProfile, player)
	end

	Players.PlayerAdded:Connect(function(player: Player)
		task.spawn(loadProfile, player)
	end)

	Players.PlayerRemoving:Connect(releaseProfile)
end

return DataService
