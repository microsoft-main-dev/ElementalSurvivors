--!strict
--[[
	BoostService — действующие бустеры и заряды (M7).

	Бустер ускоряет доход и ничего не даёт в бою: раздел 10 ТЗ запрещает донату
	давать силу, недоступную гриндом. Поэтому здесь только три множителя —
	Essence за забег, потолок копилки экспедиций и скорость готовности колеса.

	Срок не требует ни таймеров, ни событий: множитель считается от os.time()
	в момент запроса. Истёкший бустер перестаёт действовать сам, даже если
	сервер в этот момент ничего не делал.

	Ни одна функция здесь не yield-ится: множители читаются в том числе из
	RewardService.Award, а он вызывается из release-хука DataService.

	Публичный API:
		BoostService.GetMultipliers(player)   -> BoostMultipliers
		BoostService.ConsumeRunCharge(player) -> number
		BoostService.ActiveBoosts(player)     -> { StoreBoostView }
		BoostService.Charges(player)          -> { StoreChargeView }
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local DataService = require(script.Parent.DataService)
local Monetization = require(Shared.Config.Monetization)
local Types = require(Shared.Types)

local BoostService = {}

local function apply(result: Types.BoostMultipliers, def: Types.BoostDef): ()
	-- Разные бустеры перемножаются: VIP и недельный x2 вместе дают x4.
	-- Иначе покупка VIP «съедала» бы уже оплаченный бустер.
	result.essence *= def.essenceMult
	result.offlineCap *= def.offlineCapMult
	result.wheelRate *= def.wheelRate
end

--[[
	Все действующие множители игрока. Единица во всех полях означает «бустеров
	нет» — это же значение возвращается, если профиля ещё нет, поэтому
	вызывающему не нужно проверять загрузку отдельно.
]]
function BoostService.GetMultipliers(player: Player): Types.BoostMultipliers
	local result: Types.BoostMultipliers = { essence = 1, offlineCap = 1, wheelRate = 1 }

	local data = DataService.GetProfile(player)
	if not data then
		return result
	end

	local now = os.time()
	local purchases = data.purchases

	if purchases.vipUntil > now then
		local vip = Monetization.Boosts[Monetization.VipBoostKey]
		if vip then
			apply(result, vip)
		end
	end

	for key, expiry in purchases.boosters do
		if expiry > now then
			--[[
				Незнакомый ключ — это бустер, убранный из конфига после того,
				как его купили. Молча игнорируем: выдумывать за него множитель
				не по чему, а падать из-за старой покупки нельзя.
			]]
			local def = Monetization.Boosts[key]
			if def then
				apply(result, def)
			end
		end
	end

	return result
end

--[[
	Списать заряд под завершившийся забег и вернуть его множитель.
	Единица означает «зарядов не было» — награда не меняется.

	Зарядов за забег тратится ровно один, самый сильный: игрок купил их, чтобы
	получить максимум, а не чтобы сжечь два подряд на одном забеге.

	Порядок обхода таблицы зарядов не определён, поэтому выбор идёт по величине
	множителя, а не «какой первый попался»: одинаковый вход обязан давать
	одинаковый результат.
]]
function BoostService.ConsumeRunCharge(player: Player): number
	local data = DataService.GetProfile(player)
	if not data then
		return 1
	end

	local bestKey: string? = nil
	local bestMult = 1

	for key, count in data.purchases.charges do
		if count > 0 then
			local def = Monetization.Charges[key]
			if def and def.essenceMult > bestMult then
				bestKey = key
				bestMult = def.essenceMult
			end
		end
	end

	if not bestKey then
		return 1
	end

	if not DataService.ConsumeCharge(player, bestKey) then
		return 1
	end

	return bestMult
end

-- Действующие бустеры для витрины, с остатком в секундах.
function BoostService.ActiveBoosts(player: Player): { Types.StoreBoostView }
	local list: { Types.StoreBoostView } = {}

	local data = DataService.GetProfile(player)
	if not data then
		return list
	end

	local now = os.time()
	local purchases = data.purchases

	if purchases.vipUntil > now then
		local vip = Monetization.Boosts[Monetization.VipBoostKey]
		if vip then
			table.insert(list, {
				key = vip.key,
				displayName = vip.displayName,
				secondsLeft = purchases.vipUntil - now,
			})
		end
	end

	for key, expiry in purchases.boosters do
		if expiry > now then
			local def = Monetization.Boosts[key]
			if def then
				table.insert(list, {
					key = def.key,
					displayName = def.displayName,
					secondsLeft = expiry - now,
				})
			end
		end
	end

	-- Порядок обхода таблицы не определён, а список уходит на экран:
	-- без сортировки строки прыгали бы при каждом обновлении витрины.
	table.sort(list, function(a, b)
		return a.secondsLeft > b.secondsLeft
	end)

	return list
end

function BoostService.Charges(player: Player): { Types.StoreChargeView }
	local list: { Types.StoreChargeView } = {}

	local data = DataService.GetProfile(player)
	if not data then
		return list
	end

	for key, count in data.purchases.charges do
		local def = Monetization.Charges[key]
		if def and count > 0 then
			table.insert(list, {
				key = def.key,
				displayName = def.displayName,
				count = count,
			})
		end
	end

	table.sort(list, function(a, b)
		return a.key < b.key
	end)

	return list
end

function BoostService.Start(): ()
	--[[
		Уборка просроченных записей при входе. На права игрока не влияет —
		истёкший срок и так не считается действующим, — но без неё профиль
		постоянного покупателя копил бы мёртвые ключи годами.
	]]
	local function onPlayer(player: Player): ()
		if DataService.WaitForProfile(player) then
			DataService.PruneBoosters(player)
		end
	end

	Players.PlayerAdded:Connect(function(player)
		task.spawn(onPlayer, player)
	end)

	for _, player in Players:GetPlayers() do
		task.spawn(onPlayer, player)
	end
end

return BoostService
