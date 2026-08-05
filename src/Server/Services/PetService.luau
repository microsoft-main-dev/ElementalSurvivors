--!strict
--[[
	PetService — коллекция питомцев, экипировка и то, что питомец даёт бою
	(разделы 6 и 6.1 ТЗ).

	Питомцы — это классы: экипированный питомец задаёт стартовую способность
	забега, добавляет к характеристикам игрока и усиливает свою стихию.

	Сервис ничего не пишет в профиль напрямую — только через операции
	DataService. Здесь живёт логика «что из этого следует», а не хранение.

	Публичный API:
		PetService.GetLoadout(player)              -> PetLoadout
		PetService.Equip(player, uid)              -> (boolean, string?)
		PetService.Upgrade(player, uid)            -> (boolean, string?)
		PetService.GrantXp(player, uid, amount)    -> (boolean, string?)
		PetService.GrantStarterIfNeeded(player)    -> boolean
		PetService.CollectionPower(player)         -> number
		PetService.SortedByPower(player)           -> { PetInstance }
		PetService.BuildView(player)               -> PetsView?
		PetService.PushView(player)
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Balance = require(Shared.Config.Balance)
local DataService = require(script.Parent.DataService)
local Net = require(Shared.Net)
local Pets = require(Shared.Config.Pets)
local Types = require(Shared.Types)

type PetInstance = Types.PetInstance
type RunLoadout = Types.RunLoadout

local STARTER_FLAG = "starterPet"

local PetService = {}

local viewRemote: RemoteEvent? = nil

--[[
	Лоадаут игрока без питомца. Стартовая способность берётся из Balance —
	это запасной вариант, а не «способность по умолчанию»: попасть сюда можно,
	только если коллекция пуста, а такого после выдачи стартового питомца
	не бывает.
]]
local function emptyLoadout(): RunLoadout
	return {
		petId = "",
		starterAbility = Balance.Progression.starterAbility,
		maxHealth = Balance.Combat.playerMaxHealth,
		walkSpeed = Balance.Combat.playerWalkSpeed,
		magnetRadius = Balance.Pickup.magnetRadius,
		elementDamage = {},
		elementCooldown = {},
	}
end

local function findPet(player: Player, uid: string): PetInstance?
	local data = DataService.GetProfile(player)
	if not data then
		return nil
	end
	for _, pet in data.pets do
		if pet.uid == uid then
			return pet
		end
	end
	return nil
end

--[[
	Базовый лоадаут забега: характеристики персонажа плюс всё, что даёт питомец.

	Дальше поверх него ложатся таланты (TalentService.Apply), а в M6 — экипировка.
	Порядок сборки задаёт CombatService: здесь только питомец.

	Считается на входе в бой и больше не пересчитывается: поменять питомца
	в бою нельзя, а кеш пришлось бы сбрасывать при каждой покупке и улучшении —
	лишний повод однажды забыть его сбросить и выдать игроку чужие бонусы.
]]
function PetService.GetLoadout(player: Player): RunLoadout
	local data = DataService.GetProfile(player)
	if not data then
		return emptyLoadout()
	end

	local pet = findPet(player, data.equippedPet)
	if not pet then
		return emptyLoadout()
	end

	local def = Pets.ByKey[pet.petId]
	if not def then
		-- Питомец из профиля исчез из таблицы: так бывает после правки данных.
		-- Забег важнее, поэтому играем без бонусов, а не падаем.
		warn(`[PetService] У {player.Name} экипирован неизвестный питомец "{pet.petId}"`)
		return emptyLoadout()
	end

	--[[
		Две шкалы усиления: уровень (опыт) и звёзды (эволюция). Перемножаются,
		а не складываются: звезда усиливает питомца целиком, включая то,
		что он уже набрал уровнями.
	]]
	local scale = Pets.LevelScale(Pets.LevelForXp(pet.xp))
		* Pets.StarMultiplier(pet.petId, pet.stars or Pets.StartStars(pet.petId))
	local loadout = emptyLoadout()

	loadout.petId = def.key
	loadout.starterAbility = def.starterAbility
	loadout.maxHealth += def.passives.maxHealth * scale
	loadout.walkSpeed += def.passives.walkSpeed * scale
	loadout.magnetRadius += def.passives.magnetRadius * scale

	-- Масштабируется прибавка, а не сам множитель: иначе питомец с бонусом 1.0
	-- на двадцатом уровне превратился бы в 1.0 * scale и усилил бы стихию
	-- просто за то, что его качали.
	loadout.elementDamage[def.element] = 1 + (def.elementDamage - 1) * scale

	return loadout
end

function PetService.Equip(player: Player, uid: string): (boolean, string?)
	local pet = findPet(player, uid)
	if not pet then
		return false, "You do not own that pet."
	end

	local data = DataService.GetProfile(player)
	if data and data.equippedPet == uid then
		return false, nil
	end

	if not DataService.SetEquippedPet(player, uid) then
		return false, "Could not equip that pet."
	end

	local def = Pets.ByKey[pet.petId]
	PetService.PushView(player)

	--[[
		Смена питомца применится к следующему забегу, а не к текущему:
		лоадаут снимается на входе в бой. Игроку об этом лучше сказать прямо —
		иначе он решит, что экипировка не сработала.
	]]
	return true, if def then `{def.displayName} equipped. Its ability starts your next run.` else nil
end

--[[
	Улучшение за Essence.

	Уровень выводится из опыта, поэтому покупка уровня — это выдача ровно того
	опыта, которого до него не хватало. Второго способа поднять уровень нет:
	будь их два, они бы разошлись.
]]
function PetService.Upgrade(player: Player, uid: string): (boolean, string?)
	local pet = findPet(player, uid)
	if not pet then
		return false, "You do not own that pet."
	end

	local level, _, xpToNext = Pets.LevelForXp(pet.xp)
	if level >= Balance.Pets.maxLevel then
		return false, "That pet is already at max level."
	end

	local cost = Pets.UpgradeCost(pet.petId, level)
	if cost <= 0 then
		return false, "That pet cannot be upgraded."
	end

	-- Списание строго до выдачи: обратный порядок означал бы, что при отказе
	-- в списании уровень уже выдан.
	if not DataService.SpendCurrency(player, "essence", cost, `pet:upgrade:{pet.petId}`) then
		return false, "Not enough Essence."
	end

	DataService.AddPetXp(player, uid, xpToNext)
	PetService.PushView(player)

	local def = Pets.ByKey[pet.petId]
	return true, if def then `{def.displayName} is now level {level + 1}.` else nil
end

-- Опыт питомцу из магазина. Уровень поднимется сам, если опыта хватит.
function PetService.GrantXp(player: Player, uid: string, amount: number): (boolean, string?)
	local pet = findPet(player, uid)
	if not pet then
		return false, "You do not own that pet."
	end

	if not DataService.AddPetXp(player, uid, amount) then
		return false, "Could not train that pet."
	end

	PetService.PushView(player)
	return true, nil
end

--[[
	Стартовый питомец новому игроку.

	Флаг, а не проверка «коллекция пуста»: игрок, распустивший коллекцию
	(такая механика появится позже), не должен получать стартового питомца
	второй раз.
]]
function PetService.GrantStarterIfNeeded(player: Player): boolean
	local data = DataService.GetProfile(player)
	if not data or data.flags[STARTER_FLAG] then
		return false
	end

	-- Экипировать отдельно не нужно: AddPet сам занимает пустой слот.
	local uid = DataService.AddPet(player, Balance.Pets.starterPet)
	DataService.SetFlag(player, STARTER_FLAG, true)

	return uid ~= nil
end

--[[
	Эволюция: съесть других питомцев и получить звезду.

	Рецепт (Config/Pets) требует двух вещей: питомцев ТОГО ЖЕ вида и любых —
	каждого со своей позицией на лестнице. Корм выбирается автоматически,
	по правилу «сначала самых бесполезных»: меньше звёзд, потом меньше опыта.
	Так игрок не скормит случайно то, во что уже вложился.

	Экипированный питомец кормом не станет никогда — это проверяет и профиль.
]]
local function pickFodder(
	data: Types.ProfileData,
	targetUid: string,
	petId: string?,
	stars: number,
	count: number
): { string }?
	if count <= 0 then
		return {}
	end

	local candidates: { PetInstance } = {}
	for _, pet in data.pets do
		local matchesKind = petId == nil or pet.petId == petId
		local atStars = (pet.stars or Pets.StartStars(pet.petId)) == stars

		if matchesKind and atStars and pet.uid ~= targetUid and pet.uid ~= data.equippedPet then
			table.insert(candidates, pet)
		end
	end

	if #candidates < count then
		return nil
	end

	-- Самые невложенные вперёд: их не жалко, и это то, чего ждёт игрок.
	table.sort(candidates, function(a: PetInstance, b: PetInstance): boolean
		if a.xp == b.xp then
			return a.uid < b.uid
		end
		return a.xp < b.xp
	end)

	local chosen: { string } = {}
	for index = 1, count do
		table.insert(chosen, candidates[index].uid)
	end
	return chosen
end

function PetService.Evolve(player: Player, uid: string): (boolean, string?)
	local data = DataService.GetProfile(player)
	if not data then
		return false, nil
	end

	local pet = findPet(player, uid)
	if not pet then
		return false, "You do not own that pet."
	end

	local stars = pet.stars or Pets.StartStars(pet.petId)
	local recipe = Pets.Recipe(stars)
	if not recipe then
		return false, "That pet is already at its final star."
	end

	--[[
		Корм собирается двумя порциями, и вторая ищется уже без первой:
		иначе один и тот же питомец мог бы засчитаться и как копия, и как
		«любой», а съеден был бы один раз.
	]]
	local consume = pickFodder(data, uid, pet.petId, recipe.copyStars, recipe.copies)
	if not consume then
		return false, `Needs {recipe.copies} more copies at {recipe.copyStars}★.`
	end

	local taken: { [string]: boolean } = {}
	for _, victim in consume do
		taken[victim] = true
	end

	local fodder: { string } = {}
	if recipe.fodder > 0 then
		local pool = pickFodder(data, uid, nil, recipe.fodderStars, recipe.fodder + #consume)
		if not pool then
			return false, `Needs {recipe.fodder} pets at {recipe.fodderStars}★.`
		end

		for _, candidate in pool do
			if not taken[candidate] and #fodder < recipe.fodder then
				table.insert(fodder, candidate)
			end
		end

		if #fodder < recipe.fodder then
			return false, `Needs {recipe.fodder} pets at {recipe.fodderStars}★.`
		end
	end

	for _, victim in fodder do
		table.insert(consume, victim)
	end

	if not DataService.EvolvePet(player, uid, consume) then
		return false, "Could not evolve that pet."
	end

	PetService.PushView(player)

	local def = Pets.ByKey[pet.petId]
	return true, if def then `{def.displayName} evolved!` else "Evolved!"
end

--[[
	Сила питомца всегда выводится из опыта, а не из поля level.

	Поле level в профиле — это зеркало, которое поддерживает DataService,
	и оно есть в схеме раздела 6 ТЗ. Но источник правды один — опыт, и вся
	логика читает именно его: иначе рассинхрон уровня и опыта однажды случится
	и будет тихим.
]]
local function powerOf(pet: PetInstance): number
	local level = Pets.LevelForXp(pet.xp)
	return Pets.Power(pet.petId, level)
end

--[[
	Коллекция по убыванию силы. Тот же порядок использует расчёт экспедиций:
	считать «силу» двумя способами нельзя, иначе список в интерфейсе перестанет
	соответствовать выплате.
]]
function PetService.SortedByPower(player: Player): { PetInstance }
	local data = DataService.GetProfile(player)
	if not data then
		return {}
	end

	-- Сила считается один раз на питомца, а не на каждое сравнение.
	local power: { [string]: number } = {}
	for _, pet in data.pets do
		power[pet.uid] = powerOf(pet)
	end

	local sorted = table.clone(data.pets)
	table.sort(sorted, function(a: PetInstance, b: PetInstance): boolean
		local powerA, powerB = power[a.uid], power[b.uid]
		if powerA == powerB then
			-- uid как второй ключ: без него порядок равных питомцев зависел бы
			-- от реализации сортировки и прыгал бы между кадрами.
			return a.uid < b.uid
		end
		return powerA > powerB
	end)

	return sorted
end

--[[
	Суммарная сила коллекции с затуханием (раздел 6.1 ТЗ).

	Считается по ЛУЧШЕМУ экземпляру каждого вида. С появлением эволюции
	коллекция перестала быть уникальной по питомцу, и без этого правила запас
	корма — сотня одинаковых заготовок — поднимал бы оффлайн-доход просто
	за факт хранения. Раздел 6.1 ТЗ этого прямо не допускает, и защита,
	которая раньше держалась на уникальности записей, теперь живёт здесь.
]]
function PetService.CollectionPower(player: Player): number
	local best: { [string]: number } = {}

	for _, pet in PetService.SortedByPower(player) do
		local power = powerOf(pet)
		if power > (best[pet.petId] or 0) then
			best[pet.petId] = power
		end
	end

	local powers: { number } = {}
	for _, power in best do
		table.insert(powers, power)
	end
	table.sort(powers, function(a: number, b: number): boolean
		return a > b
	end)

	local decay = Balance.Offline.decay
	local total = 0
	for index, power in powers do
		total += power * decay ^ (index - 1)
	end

	return total
end

--[[
	Что нужно питомцу на следующую звезду и сколько из этого уже есть.

	Считается на сервере: клиент не должен уметь предсказывать, годится ли
	конкретный питомец кормом, — иначе он покажет одно, а сервер сделает другое.
]]
local function evolveView(data: Types.ProfileData, pet: PetInstance, stars: number): Types.EvolveView?
	local recipe = Pets.Recipe(stars)
	if not recipe then
		return nil
	end

	local haveCopies = 0
	local haveFodder = 0

	for _, candidate in data.pets do
		if candidate.uid == pet.uid or candidate.uid == data.equippedPet then
			continue
		end

		local at = candidate.stars or Pets.StartStars(candidate.petId)
		if at == recipe.copyStars and candidate.petId == pet.petId then
			haveCopies += 1
		end
		if at == recipe.fodderStars then
			haveFodder += 1
		end
	end

	return {
		copies = recipe.copies,
		copyStars = recipe.copyStars,
		fodder = recipe.fodder,
		fodderStars = recipe.fodderStars,
		haveCopies = haveCopies,
		haveFodder = haveFodder,
	}
end

function PetService.BuildView(player: Player): Types.PetsView?
	local data = DataService.GetProfile(player)
	if not data then
		return nil
	end

	--[[
		OfflineService требуется здесь, а не сверху файла: он сам требует
		PetService ради силы коллекции, и взаимная ссылка на верхнем уровне
		повесила бы загрузку сервисов. К моменту первого вызова оба модуля
		уже загружены.
	]]
	local OfflineService = require(script.Parent.OfflineService)

	local views: { Types.PetView } = {}
	for _, pet in PetService.SortedByPower(player) do
		local level, xpIntoLevel, xpToNext = Pets.LevelForXp(pet.xp)
		-- or: у питомцев, полученных до появления звёзд, поля нет.
		local stars = pet.stars or Pets.StartStars(pet.petId)
		table.insert(views, {
			uid = pet.uid,
			petId = pet.petId,
			level = level,
			xp = xpIntoLevel,
			xpToNext = xpToNext,
			power = Pets.Power(pet.petId, level),
			upgradeCost = Pets.UpgradeCost(pet.petId, level),
			equipped = pet.uid == data.equippedPet,
			stars = stars,
			starMult = Pets.StarMultiplier(pet.petId, stars),
			evolve = evolveView(data, pet, stars),
		})
	end

	local power = PetService.CollectionPower(player)

	return {
		pets = views,
		equipped = data.equippedPet,
		collectionPower = power,
		offlineRatePerHour = OfflineService.RateForPower(power),
		-- С учётом бустеров (M7): панель обязана показывать тот потолок,
		-- по которому реально считается копилка, иначе VIP выглядит нерабочим.
		offlineCapHours = OfflineService.CapHoursFor(player, power),
	}
end

--[[
	Публичный питомец: ключ экипированного в атрибуте игрока.

	Питомцами хвастаются — значит их должны видеть все, а не только владелец
	(срез PetsView уходит одному игроку и для этого не годится). Атрибут
	реплицируется всем сам, в том числе тем, кто зайдёт позже, поэтому ни
	рассылки при входе, ни учёта «кому уже отправили» не нужно.

	Наружу уходит только ключ вида питомца — ни uid, ни опыт, ни коллекция.
	Клиент по этому ключу рисует модель, и подделать им нечего: у чужого
	клиента нет ни одного способа записать сюда что-либо.
]]
local function pushPublicPet(player: Player): ()
	local data = DataService.GetProfile(player)
	local petId = ""

	if data then
		for _, pet in data.pets do
			if pet.uid == data.equippedPet then
				petId = pet.petId
				break
			end
		end
	end

	player:SetAttribute(Net.Attribute.EquippedPet, petId)
end

function PetService.PushView(player: Player): ()
	-- Атрибут обновляется здесь же: коллекция меняется только через этот путь,
	-- и второй точки для одного факта заводить незачем.
	pushPublicPet(player)

	local remote = viewRemote
	if not remote then
		return
	end

	local view = PetService.BuildView(player)
	if view then
		remote:FireClient(player, view)
	end
end

function PetService.Init(): ()
	viewRemote = Net.GetEvent(Net.Id.PetsView)
end

return PetService
