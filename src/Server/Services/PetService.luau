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
type PetLoadout = Types.PetLoadout

local STARTER_FLAG = "starterPet"

local PetService = {}

local viewRemote: RemoteEvent? = nil

--[[
	Лоадаут игрока без питомца. Стартовая способность берётся из Balance —
	это запасной вариант, а не «способность по умолчанию»: попасть сюда можно,
	только если коллекция пуста, а такого после выдачи стартового питомца
	не бывает.
]]
local function emptyLoadout(): PetLoadout
	return {
		petId = "",
		starterAbility = Balance.Progression.starterAbility,
		maxHealth = Balance.Combat.playerMaxHealth,
		walkSpeed = Balance.Combat.playerWalkSpeed,
		magnetRadius = Balance.Pickup.magnetRadius,
		elementDamage = {},
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
	Всё, что питомец даёт забегу.

	Считается на входе в бой и больше не пересчитывается: поменять питомца
	в бою нельзя, а кеш пришлось бы сбрасывать при каждой покупке и улучшении —
	лишний повод однажды забыть его сбросить и выдать игроку чужие бонусы.
]]
function PetService.GetLoadout(player: Player): PetLoadout
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

	local scale = Pets.LevelScale(Pets.LevelForXp(pet.xp))
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

-- Суммарная сила коллекции с затуханием (раздел 6.1 ТЗ).
function PetService.CollectionPower(player: Player): number
	local decay = Balance.Offline.decay
	local total = 0

	for index, pet in PetService.SortedByPower(player) do
		total += powerOf(pet) * decay ^ (index - 1)
	end

	return total
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
		table.insert(views, {
			uid = pet.uid,
			petId = pet.petId,
			level = level,
			xp = xpIntoLevel,
			xpToNext = xpToNext,
			power = Pets.Power(pet.petId, level),
			upgradeCost = Pets.UpgradeCost(pet.petId, level),
			equipped = pet.uid == data.equippedPet,
		})
	end

	local power = PetService.CollectionPower(player)

	return {
		pets = views,
		equipped = data.equippedPet,
		collectionPower = power,
		offlineRatePerHour = OfflineService.RateForPower(power),
		offlineCapHours = OfflineService.CapHoursForPower(power),
	}
end

function PetService.PushView(player: Player): ()
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
