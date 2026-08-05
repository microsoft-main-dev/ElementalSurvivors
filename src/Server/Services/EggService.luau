--!strict
--[[
	EggService — яйца-лутбоксы и лоты магазина (раздел 4 ТЗ).

	Единственное место, где валюта превращается в питомцев. Порядок операций
	жёсткий и одинаковый для всех покупок:

		проверить лот -> посчитать цену -> списать -> и только потом выдать.

	Обратный порядок («выдадим, потом спишем») — это дюп при первом же отказе
	в списании, поэтому выдача идёт строго после успешного SpendCurrency,
	а само списание атомарно внутри DataService.

	Здесь же стенд проверки шансов: критерий приёмки M4 требует 10 000 роллов,
	и делать это руками через покупку невозможно. Симуляция считает по тем же
	таблицам той же функцией Eggs.Roll, но профиля и валюты не касается вовсе.

	Публичный API:
		EggService.BuyEgg(player, eggKey, count) -> (boolean, { EggRollResult }, string?)
		EggService.BuyLot(player, lotKey, uid)   -> (boolean, { EggRollResult }, string?)
		EggService.SimulateRolls(eggKey, count)  -> { [PetRarity]: number }
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Balance = require(Shared.Config.Balance)
local DataService = require(script.Parent.DataService)
local Eggs = require(Shared.Config.Eggs)
local PetService = require(script.Parent.PetService)
local Pets = require(Shared.Config.Pets)
local Shop = require(Shared.Config.Shop)
local Types = require(Shared.Types)

type EggRollResult = Types.EggRollResult
type PetRarity = Types.PetRarity

-- Потолок на одну покупку. Даже если клиент попросит миллион роллов,
-- дальше этого числа запрос не пройдёт: цена считается умножением.
local MAX_ROLLS = 10

local EggService = {}

--[[
	Общий генератор для боевых роллов.

	Один на сервер и без seed намеренно: детерминизм здесь не нужен и вреден —
	предсказуемая последовательность лутбокса это то, что при первой же утечке
	превращается в «зайти, посмотреть, что выпадет следующим».
]]
local random = Random.new()

--[[
	Выдать питомцев по уже оплаченным роллам.

	Отделено от покупки, чтобы у выдачи был ровно один путь: и яйцо у стойки,
	и пачка из магазина проходят здесь.
]]
local function grantRolls(player: Player, eggKey: string, count: number): { EggRollResult }
	local egg = Eggs.ByKey[eggKey]
	local results: { EggRollResult } = {}

	if not egg then
		return results
	end

	for _ = 1, count do
		local petId = Eggs.Roll(egg, random)
		local uid, duplicate, owned = DataService.AddPet(player, petId)

		if uid then
			local level = 1
			local data = DataService.GetProfile(player)
			if data then
				for _, pet in data.pets do
					if pet.uid == uid then
						level = Pets.LevelForXp(pet.xp)
						break
					end
				end
			end

			table.insert(results, {
				petId = petId,
				duplicate = duplicate,
				owned = owned,
				level = level,
			})
		end
	end

	return results
end

--[[
	Покупка яйца у стойки в лобби.

	count приходит с клиента, поэтому зажимается в 1..MAX_ROLLS до всего
	остального: цена считается умножением, и непроверенное число здесь —
	это отрицательная или бесконечная стоимость.
]]
function EggService.BuyEgg(player: Player, eggKey: string, count: number): (boolean, { EggRollResult }, string?)
	local egg = Eggs.ByKey[eggKey]
	if not egg then
		return false, {}, nil
	end

	if count ~= count or count % 1 ~= 0 then
		return false, {}, nil
	end

	local rolls = math.clamp(count, 1, MAX_ROLLS)
	local price = egg.price * rolls

	if not DataService.SpendCurrency(player, egg.currency, price, `egg:{eggKey}x{rolls}`) then
		local what = if egg.currency == "essence" then "Essence" else "Prisms"
		return false, {}, `Not enough {what}.`
	end

	local results = grantRolls(player, eggKey, rolls)

	PetService.PushView(player)
	DataService.SaveNow(player)

	return true, results, nil
end

--[[
	Покупка лота магазина. uid нужен только лотам с опытом питомцу:
	игрок выбирает, кого кормить, и этот выбор проверяется как всё остальное —
	питомец должен быть его.
]]
function EggService.BuyLot(player: Player, lotKey: string, uid: string): (boolean, { EggRollResult }, string?)
	local lot = Shop.ByKey[lotKey]
	if not lot then
		return false, {}, nil
	end

	if lot.kind == "petXp" then
		--[[
			Проверка владения идёт ДО списания: иначе игрок с невалидным uid
			заплатит и не получит ничего. Саму проверку делает PetService,
			здесь только порядок.
		]]
		local data = DataService.GetProfile(player)
		if not data then
			return false, {}, nil
		end

		local owned = false
		for _, pet in data.pets do
			if pet.uid == uid then
				owned = true
				break
			end
		end

		if not owned then
			return false, {}, "Pick a pet to train first."
		end

		if not DataService.SpendCurrency(player, lot.currency, lot.price, `shop:{lotKey}`) then
			return false, {}, "Not enough Essence."
		end

		PetService.GrantXp(player, uid, lot.count)
		DataService.SaveNow(player)

		return true, {}, "Training complete."
	end

	-- lot.kind == "egg": цена лота уже учитывает скидку за пачку,
	-- поэтому списывается она, а не count цен яйца.
	local egg = Eggs.ByKey[lot.target]
	if not egg then
		return false, {}, nil
	end

	if not DataService.SpendCurrency(player, lot.currency, lot.price, `shop:{lotKey}`) then
		local what = if lot.currency == "essence" then "Essence" else "Prisms"
		return false, {}, `Not enough {what}.`
	end

	local results = grantRolls(player, lot.target, math.min(lot.count, MAX_ROLLS))

	PetService.PushView(player)
	DataService.SaveNow(player)

	return true, results, nil
end

--[[
	Стенд проверки шансов (критерий приёмки M4).

	Никакого профиля и никакой валюты: чистая арифметика над теми же таблицами
	и той же функцией ролла, что и в покупке. Seed фиксированный — прогон
	воспроизводим, и расхождение в распределении означает ошибку в данных,
	а не невезение.
]]
function EggService.SimulateRolls(eggKey: string, count: number): { [PetRarity]: number }
	local tally: { [PetRarity]: number } = {}
	for _, rarity in Pets.Rarities do
		tally[rarity] = 0
	end

	local egg = Eggs.ByKey[eggKey]
	if not egg then
		return tally
	end

	local testRandom = Random.new(20240501)
	for _ = 1, count do
		local def = Pets.ByKey[Eggs.Roll(egg, testRandom)]
		if def then
			tally[def.rarity] += 1
		end
	end

	return tally
end

-- Печатает распределение рядом с ожидаемым: сверять глазами, без терминала.
local function runRollTest(count: number): ()
	print(`[EggService] Проверка шансов яиц: {count} роллов на яйцо`)

	for _, egg in Eggs.List do
		local tally = EggService.SimulateRolls(egg.key, count)
		local parts: { string } = {}

		for _, rarity in Pets.Rarities do
			local got = tally[rarity]
			local expected = Eggs.Chance(egg, rarity) * 100
			if got > 0 or expected > 0 then
				table.insert(
					parts,
					string.format("%s %.2f%% (ожидалось %.2f%%)", rarity, got / count * 100, expected)
				)
			end
		end

		print(`  {egg.displayName}: {table.concat(parts, ", ")}`)
	end
end

function EggService.Start(): ()
	local count = Balance.Debug.eggRollTest
	if count > 0 then
		runRollTest(count)
	end
end

return EggService
