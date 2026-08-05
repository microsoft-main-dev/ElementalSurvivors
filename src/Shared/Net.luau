--!strict
--[[
	Net — единственная точка создания и получения Remote-объектов.

	Сервер создаёт Remote при первом запросе, клиент дожидается его появления.
	Прямых Instance.new("RemoteEvent") нигде больше в проекте быть не должно:
	так весь сетевой контракт виден в одном месте, и туда же позже вешается
	rate limit и валидация (раздел 7 ТЗ).

	Публичный API:
		Net.Id                  -- имена всех Remote проекта, чтобы не разъезжались строки
		Net.GetEvent(name)      -> RemoteEvent
		Net.GetUnreliable(name) -> UnreliableRemoteEvent   -- частые числовые потоки
		Net.GetFunction(name)   -> RemoteFunction          -- только сервер -> клиент, не в горячем пути
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local FOLDER_NAME = "Net"
local WAIT_TIMEOUT = 15

local IS_SERVER = RunService:IsServer()

local Net = {}

--[[
	Имена Remote-ов. Обе стороны берут строку отсюда, а не пишут литерал.

	Клиент -> сервер тут ровно один: выбор карточки при левел-апе. Это
	единственное решение игрока в бою (раздел 3.6 ТЗ), всё остальное решает
	сервер. Меньше Remote — меньше поверхности для читерства.
]]
Net.Id = table.freeze({
	-- Сервер -> клиент: короткое всплывающее сообщение игроку.
	Notify = "Notify",

	-- Сервер -> клиент: забег начался (слот арены и seed для генерации арены).
	RunStarted = "RunStarted",

	-- Сервер -> клиент: забег закончился (причина).
	RunEnded = "RunEnded",

	-- Сервер -> клиент: пачка событий спавна/смерти врагов, buffer, раз в 100 мс.
	EnemyEvents = "EnemyEvents",

	-- Сервер -> клиент: круговая ресинхронизация точных позиций, buffer, каждый тик.
	EnemyResync = "EnemyResync",

	-- Сервер -> клиент: появление и подбор кристаллов опыта, buffer, раз в 100 мс.
	CrystalEvents = "CrystalEvents",

	-- Сервер -> клиент: сработала способность (снаряды, вспышки) — только визуал.
	AbilityFx = "AbilityFx",

	-- Сервер -> клиент: состояние забега для HUD, 10 раз в секунду.
	RunSnapshot = "RunSnapshot",

	-- Сервер -> клиент: смена фазы сюжетного забега и сколько врагов осталось
	-- добить. Редкое событие, надёжным каналом.
	StagePhase = "StagePhase",

	--[[
		Сервер -> клиент: выстрелы дальнобойных врагов.

		Шлётся один раз на выстрел, в момент начала трассера. Позиций каждый
		кадр не шлём: снаряд летит по прямой с известной скоростью, и клиент
		доводит его сам — ровно как со снарядами способностей.
	]]
	EnemyShots = "EnemyShots",

	-- Сервер -> клиент: появление и смерть босса, телеграфы и сами атаки.
	-- Надёжным каналом: пропущенный телеграф — это удар из ниоткуда.
	BossEvent = "BossEvent",

	-- Сервер -> клиент: позиция и здоровье босса, 10 раз в секунду.
	BossState = "BossState",

	-- Сервер -> клиент: топ-10 стенда рекордсменов, раз в 60 с.
	LeaderboardView = "LeaderboardView",

	-- Сервер -> клиент: инвентарь экипировки и что надето.
	ItemsView = "ItemsView",

	-- Сервер -> клиент: ежедневные квесты с прогрессом.
	QuestsView = "QuestsView",

	-- Сервер -> клиент: что выпало на колесе фортуны.
	WheelResult = "WheelResult",

	-- Сервер -> клиент: бой встал на паузу или снялся с неё.
	CombatPaused = "CombatPaused",

	-- Сервер -> клиент: три карточки на выбор при левел-апе.
	LevelUpOffer = "LevelUpOffer",

	-- Сервер -> клиент: срез профиля (валюты и пара чисел) для HUD лобби.
	-- Шлётся при загрузке профиля и после каждого изменения баланса.
	ProfileView = "ProfileView",

	-- Сервер -> клиент: итоги забега с уже начисленной наградой.
	-- Отдельно от RunEnded: тот управляет состоянием клиента, этот — только экран.
	RunResult = "RunResult",

	-- Сервер -> клиент: коллекция питомцев, экипированный и ставка экспедиций.
	-- Шлётся после каждого изменения коллекции; клиент ничего не пересчитывает.
	PetsView = "PetsView",

	-- Сервер -> клиент: что выпало из яйца (пачкой, если ролл был кратный).
	EggResult = "EggResult",

	-- Сервер -> клиент: сколько принесли экспедиции, пока игрока не было.
	OfflineReport = "OfflineReport",

	-- Сервер -> клиент: дерево талантов — уровень, очки и вложенное по узлам.
	-- Шлётся после каждого изменения; клиент ничего не пересчитывает.
	TalentsView = "TalentsView",

	--[[
		Сервер -> клиент: витрина за Robux и активные бустеры (M7).

		Обратного вызова у витрины нет: покупка запускается клиентским
		PromptProductPurchase, а дальше Roblox разговаривает с сервером напрямую.
		Это единственная покупка в игре, у которой нет клиентского Remote,
		и поэтому единственная, которую не надо валидировать.
	]]
	StoreView = "StoreView",

	--[[
		Сервер -> клиент: состояние обучения новичка (M7, раздел 4 ТЗ).

		Шлётся один раз при входе: сервер владеет флагами и фактом
		принудительного забега, а сами подсказки клиент ведёт сам — всё, что им
		нужно (движение персонажа, кристаллы, карточки), у него уже есть.
	]]
	TutorialView = "TutorialView",

	-- КЛИЕНТ -> СЕРВЕР: выбранная карточка. Единственный клиентский вызов в бою,
	-- поэтому проверяется полностью: право, состояние, диапазон, кулдаун.
	LevelUpChoice = "LevelUpChoice",

	--[[
		КЛИЕНТ -> СЕРВЕР: действие в лобби (купить яйцо, экипировать питомца,
		улучшить, купить лот, забрать доход экспедиций).

		Один Remote на все действия намеренно: так весь клиентский ввод лобби
		проходит через один обработчик с одним rate limit — по той же причине,
		по которой профиль пишет только DataService.
	]]
	LobbyRequest = "LobbyRequest",
})

--[[
	Атрибуты игрока, видимые всем клиентам.

	Атрибут — не Remote, но это такой же сетевой контракт: сервер пишет, все
	клиенты читают, и имя обязано лежать там же, где остальные имена, а не
	строкой в двух файлах.

	EquippedPet — ключ экипированного питомца. Именно атрибут, а не Remote,
	потому что это не событие, а состояние: атрибут реплицируется всем сам,
	доезжает до тех, кто зашёл позже, и не требует ни рассылки при входе,
	ни списка «кому мы уже отправили». Пишет его только сервер (PetService).
]]
Net.Attribute = table.freeze({
	EquippedPet = "EquippedPet",
})

local cachedRoot: Folder? = nil

local function getRoot(): Folder
	local cached = cachedRoot
	if cached then
		return cached
	end

	local root: Folder
	if IS_SERVER then
		local existing = ReplicatedStorage:FindFirstChild(FOLDER_NAME)
		if existing then
			root = existing :: Folder
		else
			local folder = Instance.new("Folder")
			folder.Name = FOLDER_NAME
			folder.Parent = ReplicatedStorage
			root = folder
		end
	else
		local found = ReplicatedStorage:WaitForChild(FOLDER_NAME, WAIT_TIMEOUT)
		assert(
			found,
			`[Net] Папка "{FOLDER_NAME}" не появилась за {WAIT_TIMEOUT} с — сервер не стартовал?`
		)
		root = found :: Folder
	end

	cachedRoot = root
	return root
end

-- Общая реализация для всех трёх типов Remote.
local function getRemote(className: string, name: string): Instance
	local root = getRoot()

	if IS_SERVER then
		local existing = root:FindFirstChild(name)
		if existing then
			assert(
				existing.ClassName == className,
				`[Net] Remote "{name}" уже создан как {existing.ClassName}, а запрошен как {className}`
			)
			return existing
		end

		local remote = Instance.new(className)
		remote.Name = name
		remote.Parent = root
		return remote
	end

	local found = root:WaitForChild(name, WAIT_TIMEOUT)
	assert(found, `[Net] Remote "{name}" не появился за {WAIT_TIMEOUT} с`)
	assert(
		found.ClassName == className,
		`[Net] Remote "{name}" имеет класс {found.ClassName}, ожидался {className}`
	)
	return found
end

function Net.GetEvent(name: string): RemoteEvent
	return getRemote("RemoteEvent", name) :: RemoteEvent
end

function Net.GetUnreliable(name: string): UnreliableRemoteEvent
	return getRemote("UnreliableRemoteEvent", name) :: UnreliableRemoteEvent
end

function Net.GetFunction(name: string): RemoteFunction
	return getRemote("RemoteFunction", name) :: RemoteFunction
end

return Net
