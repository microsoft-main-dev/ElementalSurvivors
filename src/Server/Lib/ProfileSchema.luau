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
local Pets = require(Shared.Config.Pets)
local Types = require(Shared.Types)

type ProfileData = Types.ProfileData

local ProfileSchema = {}

ProfileSchema.Version = 3

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

	--[[
		Питомцы (M4). С появлением эволюции (M2+) коллекция БОЛЬШЕ НЕ уникальна
		по petId: дубликат — это отдельный экземпляр со своими звёздами, потому
		что эволюция ест целых питомцев, а не счётчик.

		Защита из раздела 6.1 ТЗ («сотня дубликатов не доит экспедиции»)
		переехала в расчёт: оффлайн-доход считает только лучший экземпляр
		каждого вида — см. PetService.CollectionPower.
	]]
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

	--[[
		Настройки (M7). quality="Auto" не фиксирует устройство на старте —
		клиент разворачивает его в High/Low сам, каждый вход заново, поэтому
		отдельного флага "дефолт уже выбран" не нужно.

		settings появилось у профилей, которые уже существуют. Настоящей
		миграции не нужно — Reconcile дольёт дефолтом при следующей загрузке,
		Version не поднят.
	]]
	settings = {
		quality = "Auto",
		othersEffects = "All",
		sfxVolume = 1,
		musicVolume = 1,
		showDamageMeter = true,
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

	Версия 2 разворачивает счётчик дубликатов в отдельных питомцев: эволюция
	ест целых питомцев, а не число.

	Версия 3 возвращает очки талантов: дерево пересобрано целиком, и старых
	id в нём не осталось.
]]
local Migrations: { (data: ProfileData) -> () } = {
	--[[
		1 -> 2: дубликаты из счётчика превращаются в отдельных питомцев.

		До этой версии дубликат хранился числом copies у единственной записи
		вида. Эволюция ест целых питомцев, поэтому каждая копия разворачивается
		в самостоятельный экземпляр со стартовыми звёздами своей редкости.

		Заодно проставляются звёзды тем, у кого их ещё нет: поле появилось
		вместе с лестницей, а Reconcile внутрь записей массива не заглядывает.
	]]
	[1] = function(data: ProfileData)
		local extra: { Types.PetInstance } = {}

		for _, pet in data.pets do
			local record = pet :: any

			if record.stars == nil then
				record.stars = Pets.StartStars(pet.petId)
			end

			local copies = record.copies or 0
			record.copies = nil

			for _ = 1, copies do
				data.petUidCounter += 1
				table.insert(extra, {
					uid = tostring(data.petUidCounter),
					petId = pet.petId,
					level = 1,
					xp = 0,
					stars = Pets.StartStars(pet.petId),
				})
			end
		end

		for _, pet in extra do
			table.insert(data.pets, pet)
		end
	end,

	--[[
		2 -> 3: дерево талантов пересобрано, вложенные очки возвращаются.

		Ни одного прежнего id в новом дереве нет, а TalentService молча
		пропускает неизвестные узлы — без этой миграции вложенное просто
		исчезло бы вместе с очками, за которые его покупали.

		Возвращается ровно столько, сколько было вложено: считать «сколько
		очков положено по уровню» здесь нельзя — часть их может быть
		не потрачена и уже лежать в talentPoints.
	]]
	[2] = function(data: ProfileData)
		local refunded = 0
		for _, points in data.talents do
			refunded += points
		end

		data.talents = {}
		data.talentPoints += refunded
	end,
}

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
