--!strict
--[[
	ProfileSchema — форма профиля, дефолты нового игрока и миграции (раздел 6 ТЗ).

	Лежит отдельно от DataService намеренно: схема — это данные, и меняться она
	будет каждый следующий этап, а логика загрузки и сейва — почти никогда.

	Как добавлять поле:
		1. добавить его в Template с дефолтом;
		2. если старым профилям нужно не просто дефолтное значение, а пересчёт —
		   поднять Version и дописать функцию в Migrations;
		3. если хватает дефолта — Version не трогать: Profile:Reconcile()
		   у ProfileStore сам дольёт недостающие ключи при следующей загрузке.

	Version поднимается только под настоящую миграцию, иначе она обесценится.

	Публичный API:
		ProfileSchema.Version                -> number
		ProfileSchema.StoreName              -> string
		ProfileSchema.Template               -> ProfileData
		ProfileSchema.KeyFor(userId)         -> string
		ProfileSchema.Migrate(data)          -> boolean
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Types = require(Shared.Types)

type ProfileData = Types.ProfileData

local ProfileSchema = {}

ProfileSchema.Version = 1

--[[
	Имя DataStore. Менять его — значит обнулить всем игрокам прогресс, поэтому
	версия схемы в имя не входит: версионирование живёт внутри данных.
]]
ProfileSchema.StoreName = "PlayerData"

--[[
	Дефолты нового игрока — полная форма из раздела 6 ТЗ.

	Пустые ветки (equipment, inventory, daily, purchases) лежат здесь заранее:
	это данные, а не системы следующих этапов, и так M5–M7 будут заполнять
	готовые поля, а не мигрировать схему на живых игроках.

	M3 писал отсюда currency.essence, stats.* и progress.endlessBest.
	M4 добавил pets, petUidCounter, equippedPet, flags и offline.

	petUidCounter и flags появились в M4 у профилей, которые уже существуют.
	Настоящей миграции им не нужно: Profile:Reconcile() дольёт оба поля
	дефолтом при следующей загрузке, поэтому Version не поднят.
]]
local template: ProfileData = {
	version = ProfileSchema.Version,

	currency = { essence = 0, prisms = 0 },

	-- Мета-уровень персонажа и таланты — M5, пока лежат нулями.
	level = 1,
	xp = 0,
	talentPoints = 0,
	talents = {},

	-- Питомцы (M4). Коллекция уникальна по petId: дубликат уходит опытом
	-- в уже имеющегося питомца, а не заводит вторую запись.
	pets = {},
	petUidCounter = 0,
	equippedPet = "",

	-- Одноразовые отметки: "стартовый питомец выдан" и далее по этапам.
	flags = {},

	-- Экипировка (M6): слот -> uid надетого предмета.
	equipment = {},
	inventory = {
		items = {},
		consumables = {},
	},
	itemUidCounter = 0,

	progress = {
		storyStage = 1,
		endlessBest = 0,
	},

	-- Ежедневные квесты и колесо (M6). resetAt = 0 означает «набор ещё
	-- не выдавался», и он будет собран при первом входе.
	daily = {
		lastWheelSpin = 0,
		streak = 0,
		quests = {},
		resetAt = 0,
	},

	--[[
		Экспедиции питомцев (раздел 6.1 ТЗ). lastSeen — отметка серверного
		времени, от которой считается накопление; ноль означает «профиль ещё
		ни разу не закрывался», и дохода за него не начисляется.
	]]
	offline = {
		lastSeen = 0,
		claimedAt = 0,
		pending = 0,
	},

	--[[
		Покупки за Robux (M7). gamepasses и battlePass остаются пустыми:
		вечных пасов в игре нет решением владельца, батлпасс отложен за MVP.

		boosters, charges и receipts появились у профилей, которые уже
		существуют. Настоящей миграции им не нужно — Reconcile дольёт все три
		дефолтом при следующей загрузке, поэтому Version не поднят.
	]]
	purchases = {
		gamepasses = {},
		battlePass = {},
		vipUntil = 0,
		boosters = {},
		charges = {},
		receipts = {},
	},

	stats = {
		totalRuns = 0,
		totalKills = 0,
		playtime = 0,
	},
}

ProfileSchema.Template = template

--[[
	Миграции. Migrations[n] переводит профиль с версии n на версию n + 1
	и обязана быть идемпотентной по смыслу: она выполняется ровно один раз,
	но упасть посреди неё нельзя — профиль останется полусмигрированным.

	В версии 1 миграций нет и быть не может: это первая схема.
]]
local Migrations: { (data: ProfileData) -> () } = {}

--[[
	Приводит профиль к текущей версии. Возвращает true, если данные изменились —
	вызывающий по этому признаку решает, надо ли сохранять сразу.
]]
function ProfileSchema.Migrate(data: ProfileData): boolean
	local version = data.version

	-- Профиль новее нашей схемы: сервер откатили на старую версию кода.
	-- Трогать такие данные нельзя — молча потеряем то, чего не понимаем.
	if version > ProfileSchema.Version then
		warn(
			`[ProfileSchema] Профиль версии {version} новее схемы {ProfileSchema.Version}: `
				.. `миграция не выполняется, данные оставлены как есть`
		)
		return false
	end

	if version == ProfileSchema.Version then
		return false
	end

	while data.version < ProfileSchema.Version do
		local migrate = Migrations[data.version]
		if not migrate then
			warn(
				`[ProfileSchema] Нет миграции с версии {data.version} — профиль оставлен как есть`
			)
			return false
		end

		migrate(data)
		data.version += 1
	end

	return true
end

function ProfileSchema.KeyFor(userId: number): string
	return `Player_{userId}`
end

return ProfileSchema
