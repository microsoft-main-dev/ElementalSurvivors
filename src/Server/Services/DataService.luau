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
		DataService.GetProfile(player)                          -> ProfileData?
		DataService.WaitForProfile(player, timeout?)            -> ProfileData?
		DataService.AddCurrency(player, kind, amount, reason)   -> boolean
		DataService.SpendCurrency(player, kind, amount, reason) -> boolean
		DataService.RecordRun(player, kills, duration)          -> (boolean, boolean)
		DataService.AddPet(player, petId)                       -> (string?, boolean, number)
		DataService.AddPetXp(player, uid, amount)               -> boolean
		DataService.SetEquippedPet(player, uid)                 -> boolean
		DataService.SetFlag(player, name, value)                -> boolean
		DataService.AddMetaXp(player, amount)                   -> number
		DataService.SpendTalentPoint(player, nodeId, maxPoints) -> boolean
		DataService.ResetTalents(player)                        -> number
		DataService.TouchLastSeen(player)
		DataService.AccrueOffline(player, amount, cap)          -> boolean
		DataService.ClaimOffline(player, reason)                -> number
		DataService.SaveNow(player)
		DataService.SetReleaseHook(fn)
		DataService.PushView(player)
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Balance = require(Shared.Config.Balance)
local Net = require(Shared.Net)
local Pets = require(Shared.Config.Pets)
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
	local sign = if amount >= 0 then "+" else ""
	print(`[DataService] {player.Name} {sign}{amount} {kind} ({reason}); баланс: {balance}`)
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
	Списание валюты. Единственная операция, которая уменьшает баланс, и она же
	единственное место, где проверяется, хватает ли денег: если проверку делать
	в вызывающем коде, рано или поздно появится путь, где её забыли.

	Проверка и списание идут подряд без yield — между ними физически не может
	вклиниться вторая покупка того же игрока.
]]
function DataService.SpendCurrency(player: Player, kind: Types.CurrencyKind, amount: number, reason: string): boolean
	if amount <= 0 or not isSaneAmount(amount) then
		warn(`[DataService] Отклонено списание {amount} {kind} у {player.Name} ({reason})`)
		return false
	end

	local data = DataService.GetProfile(player)
	if not data then
		return false
	end

	local currency = data.currency
	local balance: number

	if kind == "essence" then
		if currency.essence < amount then
			return false
		end
		balance = currency.essence - amount
		currency.essence = balance
	else
		if currency.prisms < amount then
			return false
		end
		balance = currency.prisms - amount
		currency.prisms = balance
	end

	logGrant(player, kind, -amount, reason, balance)

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

--[[
	Питомцы (раздел 6 ТЗ).

	Коллекция уникальна по petId: дубликат не создаёт вторую запись, а уходит
	опытом в уже имеющегося. Так решено не только потому, что этого требует ТЗ,
	но и ради экономики — раздел 6.1 прямо предупреждает, что коллекция из
	сотни дубликатов не должна доить оффлайн-доход лучше топовой.

	Возвращает (uid, дубликат ли, сколько опыта ушло дубликатом).
	uid равен nil, только если писать было некуда.
]]
function DataService.AddPet(player: Player, petId: string): (string?, boolean, number)
	local data = DataService.GetProfile(player)
	if not data then
		return nil, false, 0
	end

	local def = Pets.ByKey[petId]
	if not def then
		warn(
			`[DataService] Попытка выдать несуществующего питомца "{petId}" игроку {player.Name}`
		)
		return nil, false, 0
	end

	for _, pet in data.pets do
		if pet.petId == petId then
			local xp = Pets.DuplicateXp(petId)
			pet.xp += xp
			pet.level = Pets.LevelForXp(pet.xp)
			print(`[DataService] {player.Name} дубликат {petId}: +{xp} опыта питомцу`)
			return pet.uid, true, xp
		end
	end

	-- Счётчик живёт в профиле: uid обязан оставаться уникальным всю жизнь
	-- аккаунта, а серверы приходят и уходят.
	data.petUidCounter += 1
	local uid = tostring(data.petUidCounter)

	table.insert(data.pets, { uid = uid, petId = petId, level = 1, xp = 0 })
	print(`[DataService] {player.Name} получил питомца {petId} (uid {uid})`)

	-- Первый питомец экипируется сам: пустой слот при непустой коллекции —
	-- это забытый игроком бонус, а не осмысленный выбор.
	if data.equippedPet == "" then
		data.equippedPet = uid
	end

	return uid, false, 0
end

local function findPet(data: ProfileData, uid: string): Types.PetInstance?
	for _, pet in data.pets do
		if pet.uid == uid then
			return pet
		end
	end
	return nil
end

--[[
	Опыт питомцу. Уровень не хранится независимо от опыта, а пересчитывается
	из него функцией Pets.LevelForXp: два независимых поля рано или поздно
	разъедутся, и разъедутся они в пользу игрока.
]]
function DataService.AddPetXp(player: Player, uid: string, amount: number): boolean
	if amount <= 0 or not isSaneAmount(amount) then
		return false
	end

	local data = DataService.GetProfile(player)
	if not data then
		return false
	end

	local pet = findPet(data, uid)
	if not pet then
		return false
	end

	pet.xp += amount
	pet.level = Pets.LevelForXp(pet.xp)
	return true
end

function DataService.SetEquippedPet(player: Player, uid: string): boolean
	local data = DataService.GetProfile(player)
	if not data then
		return false
	end

	if not findPet(data, uid) then
		return false
	end

	data.equippedPet = uid
	return true
end

function DataService.SetFlag(player: Player, name: string, value: boolean): boolean
	local data = DataService.GetProfile(player)
	if not data then
		return false
	end
	data.flags[name] = value
	return true
end

--[[
	Мета-уровень персонажа (раздел 6 ТЗ), M5. Возвращает, сколько уровней взято.

	Уровень и очки талантов начисляются здесь и только здесь: «уровень -> очко»
	это правило профиля, и если его продублировать где-то ещё, две реализации
	однажды разойдутся в пользу игрока.

	Yield внутри нет: функция вызывается из RewardService, а тот — в том числе
	из release-хука, то есть при выходе игрока и выключении сервера.
]]
function DataService.AddMetaXp(player: Player, amount: number): number
	if amount <= 0 or not isSaneAmount(amount) then
		return 0
	end

	local data = DataService.GetProfile(player)
	if not data then
		return 0
	end

	data.xp += amount

	local gained = 0
	local maxLevel = Balance.Meta.maxLevel

	while data.level < maxLevel do
		local need = Balance.MetaXpForLevel(data.level)
		if data.xp < need then
			break
		end

		data.xp -= need
		data.level += 1
		data.talentPoints += Balance.Meta.pointsPerLevel
		gained += 1
	end

	--[[
		На максимальном уровне опыт больше не копится: иначе он рос бы вечно
		и однажды выдал бы пачку уровней при поднятии потолка в патче.
	]]
	if data.level >= maxLevel then
		data.xp = 0
	end

	if gained > 0 then
		print(
			`[DataService] {player.Name} уровень {data.level} (+{gained}), очков талантов: {data.talentPoints}`
		)
	end

	return gained
end

--[[
	Вложить очко в узел дерева.

	Здесь проверяется только то, чем владеет профиль: есть ли свободное очко
	и не переполнен ли узел. Законность самого узла — что он существует
	и что открыт сосед — проверяет TalentService: это правило игры, а не
	правило хранения. Разделение то же, что у SpendCurrency, который владеет
	проверкой баланса и ничего не знает о том, что покупается.
]]
function DataService.SpendTalentPoint(player: Player, nodeId: string, maxPoints: number): boolean
	local data = DataService.GetProfile(player)
	if not data then
		return false
	end

	if data.talentPoints <= 0 then
		return false
	end

	local current = data.talents[nodeId] or 0
	if current >= maxPoints then
		return false
	end

	data.talentPoints -= 1
	data.talents[nodeId] = current + 1
	return true
end

--[[
	Сброс дерева. Возвращает, сколько очков вернулось.

	Валюту за сброс списывает вызывающий ДО вызова: если списывать после,
	неудачное списание оставит дерево уже сброшенным и бесплатным.
]]
function DataService.ResetTalents(player: Player): number
	local data = DataService.GetProfile(player)
	if not data then
		return 0
	end

	local refunded = 0
	for _, points in data.talents do
		refunded += points
	end

	if refunded <= 0 then
		return 0
	end

	table.clear(data.talents)
	data.talentPoints += refunded

	print(
		`[DataService] {player.Name} сбросил дерево талантов, возвращено очков: {refunded}`
	)
	return refunded
end

--[[
	Отметка «игрок был здесь» для экспедиций (раздел 6.1 ТЗ).

	Только os.time() сервера: ни часовой пояс, ни системное время устройства
	в расчёт не входят и на сервер не приходят вовсе.
]]
function DataService.TouchLastSeen(player: Player): ()
	local data = DataService.GetProfile(player)
	if data then
		data.offline.lastSeen = os.time()
	end
end

--[[
	Зачисление промежутка оффлайна в копилку.

	Ключевая операция всей механики: доход за промежуток и сдвиг lastSeen
	происходят вместе и без yield между ними. Именно это делает двойное
	начисление невозможным — любой путь, где деньги посчитаны, а отметка
	осталась старой, при следующем входе посчитает тот же промежуток снова.

	cap — потолок копилки: она обрезается при каждом зачислении, поэтому
	стопка незабранных заходов не превращается в обход потолка накопления.
]]
function DataService.AccrueOffline(player: Player, amount: number, cap: number): boolean
	local data = DataService.GetProfile(player)
	if not data then
		return false
	end

	if amount <= 0 or not isSaneAmount(amount) then
		return false
	end

	local offline = data.offline
	offline.lastSeen = os.time()
	offline.pending = math.floor(math.min(offline.pending + amount, math.max(cap, 0)))

	return true
end

--[[
	Забрать копилку. Возвращает выданное; ноль означает, что забирать было нечего.

	Обнуление стоит до начисления намеренно: если AddCurrency почему-то не
	пройдёт, игрок потеряет выплату — это неприятно, но безопасно. Обратный
	порядок при той же ошибке оставил бы копилку полной после успешной
	выдачи, а это уже дюп.
]]
function DataService.ClaimOffline(player: Player, reason: string): number
	local data = DataService.GetProfile(player)
	if not data then
		return 0
	end

	local offline = data.offline
	local amount = math.floor(offline.pending)
	if amount <= 0 then
		return 0
	end

	offline.pending = 0
	offline.claimedAt = os.time()

	if not DataService.AddCurrency(player, "essence", amount, reason) then
		return 0
	end

	return amount
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

--[[
	Отметка «профиль закрывается вот сейчас» для экспедиций питомцев.

	Живёт здесь, а не в OfflineService, по одной причине: оба пути закрытия
	профиля проходят через этот файл, и подписываться на PlayerRemoving вторым
	обработчиком было бы гонкой — releaseProfile успел бы убрать профиль
	из таблицы раньше, чем чужой обработчик до него дотянулся.

	Yield-иться нельзя: путь общий с выключением сервера.
]]
local function markSeen(player: Player): ()
	local profile = profiles[player]
	if not profile then
		return
	end

	local data = profile.Data :: ProfileData
	data.offline.lastSeen = os.time()
end

local function releaseProfile(player: Player): ()
	local profile = profiles[player]
	if not profile then
		return
	end

	runReleaseHook(player)
	markSeen(player)

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
			markSeen(player)
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
