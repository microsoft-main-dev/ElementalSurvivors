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
		DataService.EvolvePet(player, uid)                      -> boolean
		DataService.SetEquippedPet(player, uid)                 -> boolean
		DataService.SetFlag(player, name, value)                -> boolean
		DataService.SetSetting(player, key, value)              -> boolean
		DataService.ResetWheelCooldown(player)                  -> boolean
		DataService.AddMetaXp(player, amount)                   -> number
		DataService.SpendTalentPoint(player, nodeId, maxPoints) -> boolean
		DataService.ResetTalents(player)                        -> number
		DataService.ExtendBoost(player, key, seconds)           -> boolean
		DataService.AddCharge(player, key, count)               -> boolean
		DataService.ConsumeCharge(player, key)                  -> boolean
		DataService.PruneBoosters(player)
		DataService.ApplyReceipt(player, purchaseId, grant)     -> boolean
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
local Items = require(Shared.Config.Items)
local Monetization = require(Shared.Config.Monetization)
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

--[[
	Сколько ждать, пока чек покупки окажется в хранилище, и как часто проверять.

	Тридцати секунд хватает на несколько попыток сейва подряд: ProfileStore
	повторяет неудачные сохранения сам. Если не уложились — покупка остаётся
	неподтверждённой, и Roblox пришлёт её снова, вплоть до следующего захода
	игрока. Это медленно, но не теряет денег, а поспешное подтверждение теряет.
]]
local RECEIPT_SAVE_TIMEOUT = 30
local RECEIPT_POLL = 0.2

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
		storyStage = data.progress.storyStage,
		settings = data.settings,
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
function DataService.RecordRun(
	player: Player,
	kills: number,
	duration: number,
	countAsBest: boolean
): (boolean, boolean)
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

	--[[
		Рекорд обновляется только там, где он что-то значит. endlessBest —
		это лучшее время В БЕСКОНЕЧНОМ режиме (раздел 4 ТЗ), и сюжетный забег
		фиксированной длины не должен туда попадать: иначе стенд рекордсменов
		превратится в список тех, кто дольше всех проходил длинный уровень.
	]]
	local newBest = countAsBest and seconds > data.progress.endlessBest
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

	--[[
		Дубликат — это ОТДЕЛЬНЫЙ питомец, а не опыт и не счётчик: эволюция ест
		целых питомцев (решение владельца, по образцу Dragon Traveller).

		Уникальность коллекции по petId на этом заканчивается. Защита из
		раздела 6.1 ТЗ, чтобы запас корма не доил экспедиции, переехала
		в расчёт дохода: он считает лучший экземпляр каждого вида.
	]]
	local owned = 0
	for _, pet in data.pets do
		if pet.petId == petId then
			owned += 1
		end
	end

	-- Счётчик живёт в профиле: uid обязан оставаться уникальным всю жизнь
	-- аккаунта, а серверы приходят и уходят.
	data.petUidCounter += 1
	local uid = tostring(data.petUidCounter)

	table.insert(data.pets, {
		uid = uid,
		petId = petId,
		level = 1,
		xp = 0,
		-- Стартовая позиция на звёздной лестнице зависит от редкости.
		stars = Pets.StartStars(petId),
	})
	print(
		`[DataService] {player.Name} получил питомца {petId} (uid {uid}), всего таких {owned + 1}`
	)

	-- Первый питомец экипируется сам: пустой слот при непустой коллекции —
	-- это забытый игроком бонус, а не осмысленный выбор.
	if data.equippedPet == "" then
		data.equippedPet = uid
	end

	return uid, owned > 0, owned + 1
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

--[[
	Эволюция питомца: съесть перечисленных и получить звезду.

	Кого именно съесть, решает PetService — это правило игры. Здесь только
	хранение: убрать указанные записи и поднять звезду. Экипированный питомец
	не съедается ни при каких условиях, и проверка стоит здесь, потому что
	факт экипировки принадлежит профилю.
]]
function DataService.EvolvePet(player: Player, uid: string, consume: { string }): boolean
	local data = DataService.GetProfile(player)
	if not data then
		return false
	end

	local pet = findPet(data, uid)
	if not pet then
		return false
	end

	local doomed: { [string]: boolean } = {}
	for _, victim in consume do
		if victim == uid or victim == data.equippedPet then
			return false
		end
		doomed[victim] = true
	end

	--[[
		Сначала убеждаемся, что на месте все: съесть половину и обнаружить,
		что второй половины нет, — это потерянные питомцы без звезды.
	]]
	local found = 0
	for _, candidate in data.pets do
		if doomed[candidate.uid] then
			found += 1
		end
	end
	if found ~= #consume then
		return false
	end

	local kept: { Types.PetInstance } = {}
	for _, candidate in data.pets do
		if not doomed[candidate.uid] then
			table.insert(kept, candidate)
		end
	end
	data.pets = kept

	pet.stars = (pet.stars or Pets.StartStars(pet.petId)) + 1
	print(
		`[DataService] {player.Name} эволюционировал {pet.petId}: звёзд {pet.stars}, съедено {#consume}`
	)
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

-- Значение приемлемой громкости или nil. NaN/бесконечность отбрасываются целиком,
-- а не приводятся к границе — приведение спрятало бы поломанный клиент.
local function readVolume(value: unknown): number?
	if typeof(value) ~= "number" then
		return nil
	end
	local number = value :: number
	if number ~= number or number == math.huge or number == -math.huge then
		return nil
	end
	return math.clamp(number, 0, 1)
end

--[[
	Единственная запись в settings (раздел 2.1 ТЗ, M7). Ключ и значение приходят
	с клиента, поэтому оба проверяются здесь и только здесь — так же, как
	AddCurrency проверяет сумму, а не доверяет ей.

	Один универсальный сеттер, а не пять именованных функций: у всех пяти полей
	одна и та же форма записи (одно значение профиля из закрытого набора),
	и пять функций отличались бы только именем поля и способом валидации.
]]
function DataService.SetSetting(player: Player, key: string, value: unknown): boolean
	local data = DataService.GetProfile(player)
	if not data then
		return false
	end

	local settings = data.settings

	if key == "quality" then
		if value ~= "Auto" and value ~= "High" and value ~= "Low" then
			return false
		end
		settings.quality = value :: Types.QualityMode
	elseif key == "othersEffects" then
		if value ~= "All" and value ~= "Nearby" and value ~= "Off" then
			return false
		end
		settings.othersEffects = value :: Types.OthersEffectsMode
	elseif key == "sfxVolume" then
		local volume = readVolume(value)
		if not volume then
			return false
		end
		settings.sfxVolume = volume
	elseif key == "musicVolume" then
		local volume = readVolume(value)
		if not volume then
			return false
		end
		settings.musicVolume = volume
	elseif key == "showDamageMeter" then
		if typeof(value) ~= "boolean" then
			return false
		end
		settings.showDamageMeter = value :: boolean
	else
		return false
	end

	DataService.PushView(player)
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
	Экипировка (раздел 6.1 ТЗ), M6.

	Инвентарь ограничен потолком не ради интерфейса, а ради профиля:
	неограниченный список однажды упрётся в лимит размера данных DataStore,
	и упрётся молча. При переполнении вытесняется самый слабый НЕ надетый
	предмет — надетое трогать нельзя, иначе игрок лишится того, чем играет.

	Возвращает uid или nil, если положить было некуда.
]]
function DataService.AddItem(player: Player, item: Types.ItemInstance): string?
	local data = DataService.GetProfile(player)
	if not data then
		return nil
	end

	local items = data.inventory.items

	if #items >= Balance.Items.maxItems then
		local worstIndex, worstPower = nil :: number?, math.huge

		for index, candidate in items do
			local isEquipped = data.equipment[candidate.slot] == candidate.uid
			if not isEquipped then
				local power = Items.Power(candidate)
				if power < worstPower then
					worstIndex, worstPower = index, power
				end
			end
		end

		if not worstIndex then
			-- Всё надето и всё занято: класть некуда, но и выбрасывать нечего.
			return nil
		end

		table.remove(items, worstIndex)
	end

	data.itemUidCounter += 1
	local uid = `i{data.itemUidCounter}`
	item.uid = uid
	table.insert(items, item)

	print(`[DataService] {player.Name} получил предмет {item.rarity} {item.slot} (uid {uid})`)
	return uid
end

--[[
	Надеть предмет. Пустой uid снимает то, что надето в этом слоте.
]]
function DataService.SetEquippedItem(player: Player, slot: string, uid: string): boolean
	local data = DataService.GetProfile(player)
	if not data then
		return false
	end

	if uid == "" then
		data.equipment[slot] = nil
		return true
	end

	for _, item in data.inventory.items do
		if item.uid == uid then
			-- Слот берётся у предмета, а не с клиента: иначе шлем можно было бы
			-- надеть в слот ботинок и получить бонусы дважды.
			data.equipment[item.slot] = uid
			return true
		end
	end

	return false
end

--[[
	Ежедневные квесты и колесо (раздел 4 ТЗ), M6.

	Набор заданий хранится в профиле целиком: правка Config/Quests не должна
	менять условия у задания, которое игрок уже начал выполнять сегодня.
]]
function DataService.SetDailyQuests(player: Player, quests: { Types.ProfileQuest }, resetAt: number): boolean
	local data = DataService.GetProfile(player)
	if not data then
		return false
	end

	data.daily.quests = quests
	data.daily.resetAt = resetAt
	return true
end

-- Прогресс квеста. Больше цели не копится: лишние единицы ничего не значат.
function DataService.AddQuestProgress(player: Player, kind: Types.QuestKind, amount: number): boolean
	if amount <= 0 then
		return false
	end

	local data = DataService.GetProfile(player)
	if not data then
		return false
	end

	local changed = false
	for _, quest in data.daily.quests do
		if quest.kind == kind and not quest.claimed and quest.progress < quest.target then
			quest.progress = math.min(quest.progress + amount, quest.target)
			changed = true
		end
	end

	return changed
end

--[[
	Забрать награду за квест. Отметка ставится ДО начисления по той же причине,
	что и у копилки экспедиций: неудачное начисление лучше, чем невыбранная
	отметка при удачном.
]]
function DataService.ClaimQuest(player: Player, questId: string): number
	local data = DataService.GetProfile(player)
	if not data then
		return 0
	end

	for _, quest in data.daily.quests do
		if quest.id == questId then
			if quest.claimed or quest.progress < quest.target then
				return 0
			end

			quest.claimed = true
			if DataService.AddCurrency(player, "essence", quest.essence, `quest:{questId}`) then
				return quest.essence
			end
			return 0
		end
	end

	return 0
end

--[[
	Прокрутка колеса. Отметка времени сдвигается в той же операции, что и выдача,
	и до неё — ровно как у экспедиций: любой путь, где приз выдан, а отметка
	осталась старой, даёт бесконечные бесплатные прокрутки.
]]
function DataService.ClaimWheel(player: Player, essence: number): boolean
	local data = DataService.GetProfile(player)
	if not data then
		return false
	end

	data.daily.lastWheelSpin = os.time()
	data.daily.streak += 1

	return DataService.AddCurrency(player, "essence", essence, "wheel:daily")
end

--[[
	Отладочный сброс кулдауна колеса (Balance.Debug.resetWheelOnJoin, M7).
	Отдельная операция, а не переиспользование ClaimWheel: тот ещё и начисляет
	Essence, а сброс должен только освобождать колесо, не платя за это.
]]
function DataService.ResetWheelCooldown(player: Player): boolean
	local data = DataService.GetProfile(player)
	if not data then
		return false
	end

	data.daily.lastWheelSpin = 0
	return true
end

--[[
	Открыть следующий сюжетный уровень (раздел 5.1 ТЗ), M6.

	Только вперёд и только на один шаг: storyStage — это «первый непройденный»,
	и уменьшать его нельзя ни при каких обстоятельствах. Повторное прохождение
	уже пройденного уровня ничего не открывает и профиль не меняет.
]]
function DataService.AdvanceStoryStage(player: Player, clearedIndex: number): boolean
	local data = DataService.GetProfile(player)
	if not data then
		return false
	end

	if not isSaneAmount(clearedIndex) or clearedIndex < 1 then
		return false
	end

	if clearedIndex < data.progress.storyStage then
		return false
	end

	data.progress.storyStage = clearedIndex + 1
	print(
		`[DataService] {player.Name} прошёл уровень {clearedIndex}, открыт {data.progress.storyStage}`
	)
	return true
end

--[[
	Открыть сюжет целиком (отладка, Studio-only — проверку делает StageService).

	Отдельная операция, а не вызов AdvanceStoryStage с большим числом: та
	описывает прохождение уровня и печатает об этом, а это — «считай, что всё
	уже пройдено». Прогресс только растёт: рычаг не должен уметь отнимать
	у профиля пройденное.
]]
function DataService.DebugUnlockStages(player: Player, stage: number): boolean
	local data = DataService.GetProfile(player)
	if not data or not isSaneAmount(stage) or stage <= data.progress.storyStage then
		return false
	end

	data.progress.storyStage = stage
	print(`[DataService] {player.Name}: сюжет открыт до уровня {stage} (отладка)`)
	return true
end

--[[
	=== Покупки за Robux (M7) ===

	Вечных геймпассов в игре нет решением владельца, поэтому второго пути выдачи
	не существует: всё, что куплено за Robux, приходит сюда через ApplyReceipt.
	Профиль хранит только то, чего не хранит сам Roblox, — сроки бустеров,
	заряды и список обработанных чеков.
]]

-- Текущий срок бустера. VIP лежит отдельно: поле purchases.vipUntil есть
-- в схеме с M3 (раздел 6 ТЗ), и второе место для того же факта не нужно.
local function boostExpiry(data: ProfileData, key: string): number
	if key == Monetization.VipBoostKey then
		return data.purchases.vipUntil
	end
	return data.purchases.boosters[key] or 0
end

--[[
	Продлить бустер.

	Одинаковые бустеры складываются по времени, а не заменяют друг друга: купить
	сутки поверх недоигранного часа и потерять этот час — прямой повод к возврату
	средств. Отсчёт идёт от конца текущего срока, если он ещё не вышел, и от
	«сейчас», если вышел.

	Накопленный срок обрезается по потолку: бесконечное складывание превращает
	бустер во вторую экономику.
]]
function DataService.ExtendBoost(player: Player, key: string, seconds: number): boolean
	if seconds <= 0 or not isSaneAmount(seconds) then
		warn(
			`[DataService] Отклонено продление бустера "{key}" на {seconds} с: {player.Name}`
		)
		return false
	end

	local data = DataService.GetProfile(player)
	if not data then
		return false
	end

	local now = os.time()
	local from = math.max(boostExpiry(data, key), now)
	local expiry = math.min(from + seconds, now + Balance.Monetization.boostCapSeconds)

	if key == Monetization.VipBoostKey then
		data.purchases.vipUntil = expiry
	else
		data.purchases.boosters[key] = expiry
	end

	print(`[DataService] {player.Name} бустер {key} действует ещё {expiry - now} с`)
	return true
end

-- Выдать заряды — одноразовые множители на забег.
function DataService.AddCharge(player: Player, key: string, count: number): boolean
	if count <= 0 or not isSaneAmount(count) then
		warn(`[DataService] Отклонена выдача {count} зарядов "{key}": {player.Name}`)
		return false
	end

	local data = DataService.GetProfile(player)
	if not data then
		return false
	end

	local charges = data.purchases.charges
	local balance = (charges[key] or 0) + count
	charges[key] = balance

	print(`[DataService] {player.Name} +{count} заряд {key}; осталось: {balance}`)
	return true
end

--[[
	Списать один заряд. Возвращает false, если списывать было нечего.

	Проверка и списание идут подряд без yield — как в SpendCurrency, и по той же
	причине: между ними не должен вклиниться второй забег того же игрока.
]]
function DataService.ConsumeCharge(player: Player, key: string): boolean
	local data = DataService.GetProfile(player)
	if not data then
		return false
	end

	local charges = data.purchases.charges
	local balance = charges[key] or 0
	if balance <= 0 then
		return false
	end

	balance -= 1
	-- Ноль не храним: пустые ключи копились бы в профиле у всех, кто хоть раз
	-- что-то купил, и разбирать их потом было бы не по чему.
	charges[key] = if balance > 0 then balance else nil

	print(`[DataService] {player.Name} потратил заряд {key}; осталось: {balance}`)
	return true
end

-- Убрать просроченные бустеры. Чистая уборка: на права игрока не влияет,
-- потому что истёкший срок и так не считается действующим.
function DataService.PruneBoosters(player: Player): ()
	local data = DataService.GetProfile(player)
	if not data then
		return
	end

	local now = os.time()
	for key, expiry in data.purchases.boosters do
		if expiry <= now then
			data.purchases.boosters[key] = nil
		end
	end
end

--[[
	Проверить, попал ли чек в ХРАНИЛИЩЕ. Не в профиль в памяти — именно в то,
	что уже сохранено: подтвердить покупку раньше сейва значит подарить товар
	первому же вылету сервера.

	LastSavedData — снимок последнего успешного сохранения, и у профиля, который
	ещё ни разу не сохранялся после появления ветки receipts, её там просто нет.
	Поэтому разбор идёт через any с проверками типов, а не по схеме.
]]
local function receiptSaved(profile: Profile, purchaseId: string): boolean
	local saved = profile.LastSavedData :: any
	if typeof(saved) ~= "table" then
		return false
	end

	local purchases = saved.purchases
	if typeof(purchases) ~= "table" then
		return false
	end

	local receipts = purchases.receipts
	if typeof(receipts) ~= "table" then
		return false
	end

	return table.find(receipts, purchaseId) ~= nil
end

--[[
	Выдача по чеку дев-продукта — единственный вход денег за Robux в игру.

	grant вызывается ТОЛЬКО если этот чек ещё не обрабатывался. Он не получает
	профиль: внутри ему доступны те же публичные операции DataService, что и
	всем остальным, поэтому список того, что может изменить профиль, по-прежнему
	целиком виден в этом файле.

	Порядок действий и есть защита от двойной выдачи:
		1. чек уже в кольце -> выдача пропускается, но подтверждение всё равно
		   ждёт сейва: чек мог быть записан и не сохранён;
		2. выдача и запись чека происходят в одном профиле, поэтому либо
		   сохранятся вместе, либо не сохранятся вместе;
		3. true возвращается только после того, как чек виден в сохранённых
		   данных. До тех пор покупка считается необработанной, и Roblox
		   пришлёт её снова — это правильный исход, а не потеря денег игрока.

	Yield-ится (ждёт сейва), поэтому из release-хука вызывать нельзя.
]]
function DataService.ApplyReceipt(player: Player, purchaseId: string, grant: () -> boolean): boolean
	local profile = profiles[player]
	if not profile or not profile:IsActive() then
		return false
	end

	local data = profile.Data :: ProfileData
	local receipts = data.purchases.receipts

	if table.find(receipts, purchaseId) == nil then
		if not grant() then
			warn(`[DataService] Выдача по чеку {purchaseId} не состоялась: {player.Name}`)
			return false
		end

		table.insert(receipts, purchaseId)
		while #receipts > Balance.Monetization.receiptLogSize do
			table.remove(receipts, 1)
		end
	end

	--[[
		На выключении сервера ProfileStore сохраняет всех сам, и очередь запросов
		там плотная: свой Save в этот момент только мешает. Ждать результата это
		не отменяет — данные всё равно уедут, и чек в них будет виден.
	]]
	if not ProfileStore.IsClosing then
		profile:Save()
	end

	local deadline = os.clock() + RECEIPT_SAVE_TIMEOUT
	while os.clock() < deadline do
		if receiptSaved(profile, purchaseId) then
			return true
		end
		-- Сессия закрылась (игрок ушёл, сессию перехватил другой сервер):
		-- ждать больше нечего, и подтверждать нечего.
		if not profile:IsActive() then
			return false
		end
		task.wait(RECEIPT_POLL)
	end

	warn(`[DataService] Чек {purchaseId} не сохранился за {RECEIPT_SAVE_TIMEOUT} с: {player.Name}`)
	return false
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
