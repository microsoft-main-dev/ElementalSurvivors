--!strict
--[[
	PurchaseService — покупки за Robux (раздел 9 ТЗ), M7.

	Единственный владелец MarketplaceService.ProcessReceipt. Больше никто
	в проекте к MarketplaceService не обращается: вечных геймпассов в игре нет
	решением владельца, поэтому и проверки владения нет ни одной.

	Клиент в выдаче не участвует физически. Покупка начинается клиентским
	PromptProductPurchase, а дальше Roblox разговаривает только с сервером —
	Remote в этой цепочке нет вообще. Это единственная покупка в игре, которую
	не надо валидировать: подделывать нечего.

	Одноразовость выдачи держится не здесь, а в DataService.ApplyReceipt:
	товар и номер чека попадают в один профиль и сохраняются вместе, а
	«выдано» отвечается только после того, как чек виден в хранилище.
	Здесь — разбор чека и сама выдача.

	Публичный API:
		PurchaseService.BuildView(player) -> StoreView
		PurchaseService.PushView(player)
]]

local MarketplaceService = game:GetService("MarketplaceService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Balance = require(Shared.Config.Balance)
local BoostService = require(script.Parent.BoostService)
local DataService = require(script.Parent.DataService)
local Monetization = require(Shared.Config.Monetization)
local Net = require(Shared.Net)
local Types = require(Shared.Types)

--[[
	Форма чека от Roblox. Описана здесь, а не взята из типов Roblox, ровно
	по нужным полям: так же выглядит и то, что подставляет отладочный прогон.
]]
type Receipt = {
	PlayerId: number,
	PurchaseId: string,
	ProductId: number,
}

--[[
	Отрицательный id, под которым отладочный прогон подставляет товар: у
	незаведённого продукта настоящего id ещё нет, а проверять надо тот же путь.
	Настоящий чек с таким id прийти не может.
]]
local TEST_PRODUCT_ID = -1

local PurchaseService = {}

local storeRemote: RemoteEvent? = nil
local notifyRemote: RemoteEvent? = nil
local testProduct: Types.ProductDef? = nil

local function notify(player: Player, message: string): ()
	local remote = notifyRemote
	if remote then
		remote:FireClient(player, message)
	end
end

--[[
	Собственно выдача товара.

	Профиля не касается напрямую: пользуется теми же публичными операциями
	DataService, что и весь остальной код. Возврат false означает «выдать
	не удалось» — тогда чек не подтверждается и Roblox пришлёт его снова.
]]
local function grantProduct(player: Player, product: Types.ProductDef): boolean
	local grant = product.grant
	local reason = `purchase:{product.key}`

	if product.kind == "prisms" then
		return DataService.AddCurrency(player, "prisms", grant.prisms, reason)
	end

	-- VIP отличается от обычного бустера только тем, куда пишется срок,
	-- и это различие целиком спрятано в DataService.ExtendBoost.
	if product.kind == "boost" or product.kind == "vip" then
		return DataService.ExtendBoost(player, grant.boost, grant.seconds)
	end

	if product.kind == "charge" then
		return DataService.AddCharge(player, grant.charge, grant.count)
	end

	warn(`[PurchaseService] Неизвестный вид товара "{product.kind}" у "{product.key}"`)
	return false
end

--[[
	Разбор чека. Общий путь для настоящих покупок и для отладочного прогона:
	проверять надо тот код, который работает в игре, а не его копию.

	NotProcessedYet — не ошибка, а «попробуй ещё раз позже»: Roblox пришлёт
	этот чек снова, в том числе при следующем заходе игрока. Поэтому во всех
	сомнительных случаях правильный ответ именно такой, а не Granted.
]]
local function handleReceipt(receipt: Receipt): Enum.ProductPurchaseDecision
	local player = Players:GetPlayerByUserId(receipt.PlayerId)
	if not player then
		-- Игрок уже вышел: выдавать некуда, профиль трогать нельзя.
		return Enum.ProductPurchaseDecision.NotProcessedYet
	end

	local product = Monetization.ByProductId[receipt.ProductId]
	if not product and testProduct and receipt.ProductId == TEST_PRODUCT_ID then
		product = testProduct
	end

	if not product then
		--[[
			Товара нет в конфиге. Скорее всего продукт завели в Creator Dashboard,
			а id в Config/Monetization ещё не вписали. Подтверждать нельзя: игрок
			заплатил и не получил ничего. Чек подождёт до правки конфига.
		]]
		warn(`[PurchaseService] Чек на неизвестный productId {receipt.ProductId} от {player.Name}`)
		return Enum.ProductPurchaseDecision.NotProcessedYet
	end

	local granted = DataService.ApplyReceipt(player, receipt.PurchaseId, function()
		return grantProduct(player, product)
	end)

	if not granted then
		return Enum.ProductPurchaseDecision.NotProcessedYet
	end

	DataService.PushView(player)
	PurchaseService.PushView(player)
	notify(player, `Purchased: {product.displayName}`)

	return Enum.ProductPurchaseDecision.PurchaseGranted
end

function PurchaseService.BuildView(player: Player): Types.StoreView
	local products: { Types.StoreProductView } = {}

	for _, product in Monetization.Products do
		table.insert(products, {
			key = product.key,
			displayName = product.displayName,
			description = product.description,
			productId = product.productId,
			available = Monetization.IsConfigured(product),
		})
	end

	return {
		products = products,
		boosts = BoostService.ActiveBoosts(player),
		charges = BoostService.Charges(player),
		essenceMult = BoostService.GetMultipliers(player).essence,
	}
end

function PurchaseService.PushView(player: Player): ()
	local remote = storeRemote
	if not remote or not DataService.GetProfile(player) then
		return
	end
	remote:FireClient(player, PurchaseService.BuildView(player))
end

--[[
	Отладочный прогон критерия приёмки «покупка обрабатывается ровно один раз
	даже при повторной отправке» (Balance.Debug.receiptTest).

	Окно покупки в Studio не открывается вовсе, поэтому без этого рычага
	единственный способ проверить главное место этапа — тратить настоящие Robux
	и надеяться, что Roblox пришлёт повтор.

	Один и тот же чек уходит в настоящий handleReceipt дважды. Баланс печатается
	трижды: до, после первого вызова и после второго. Второй обязан не изменить
	ничего.

	Номер чека включает время запуска: внутри одной сессии два вызова обязаны
	столкнуться друг с другом, а следующий запуск Studio должен начинать
	с чистого листа, иначе проверку нельзя повторить.
]]
local function runReceiptTest(player: Player, productKey: string): ()
	local product = Monetization.ByKey[productKey]
	if not product then
		warn(`[PurchaseService] receiptTest: нет товара с ключом "{productKey}"`)
		return
	end

	local data = DataService.WaitForProfile(player)
	if not data then
		return
	end

	--[[
		Товар подставляется под отрицательный id, если настоящего у него ещё нет:
		так прогон работает до похода в Creator Dashboard и при этом идёт
		по тому же коду, что и настоящая покупка. Конфиг при этом не трогается —
		он заморожен, и правильно.
	]]
	local productId = product.productId
	if not Monetization.IsConfigured(product) then
		productId = TEST_PRODUCT_ID
		testProduct = product
	end

	local receipt: Receipt = {
		PlayerId = player.UserId,
		PurchaseId = `StudioTest_{os.time()}_{player.UserId}`,
		ProductId = productId,
	}

	local function snapshot(): string
		local boosts = {}
		for _, boost in BoostService.ActiveBoosts(player) do
			table.insert(boosts, `{boost.key}:{boost.secondsLeft}с`)
		end
		for _, charge in BoostService.Charges(player) do
			table.insert(boosts, `{charge.key}x{charge.count}`)
		end
		local extras = if #boosts > 0 then table.concat(boosts, ", ") else "нет"
		return `prisms={data.currency.prisms}, бустеры и заряды: {extras}`
	end

	print(`[PurchaseService] receiptTest "{productKey}" — до: {snapshot()}`)

	local first = handleReceipt(receipt)
	print(`[PurchaseService] receiptTest первый вызов: {first.Name}; {snapshot()}`)

	local second = handleReceipt(receipt)
	print(`[PurchaseService] receiptTest повтор: {second.Name}; {snapshot()}`)
	print(
		`[PurchaseService] receiptTest: повтор обязан не изменить ничего — сверьте две последние строки`
	)

	testProduct = nil
end

function PurchaseService.Init(): ()
	storeRemote = Net.GetEvent(Net.Id.StoreView)
	notifyRemote = Net.GetEvent(Net.Id.Notify)

	--[[
		Обработчик ставится в Init, а не в Start: чеки могут прийти в первые же
		секунды жизни сервера, и лучше ответить «позже» из готового обработчика,
		чем не иметь обработчика вовсе.

		pcall обязателен: падение внутри ProcessReceipt Roblox трактует как
		«не обработано» и повторит чек, но без pcall мы не увидим, что именно
		упало, и будем повторять ошибку вечно.
	]]
	MarketplaceService.ProcessReceipt = function(info)
		local receipt: Receipt = {
			PlayerId = info.PlayerId,
			PurchaseId = tostring(info.PurchaseId),
			ProductId = info.ProductId,
		}

		local ok, decision = pcall(handleReceipt, receipt)
		if not ok then
			warn(`[PurchaseService] Обработка чека {receipt.PurchaseId} упала: {decision}`)
			return Enum.ProductPurchaseDecision.NotProcessedYet
		end

		return decision
	end
end

function PurchaseService.Start(): ()
	local function onPlayer(player: Player): ()
		if not DataService.WaitForProfile(player) then
			return
		end

		PurchaseService.PushView(player)

		-- Рычаг работает только в Studio: забытое значение не сможет ничего
		-- выдать на живом сервере. Проверка стоит в коде, а не в конфиге.
		local productKey = Balance.Debug.receiptTest
		if RunService:IsStudio() and #productKey > 0 then
			runReceiptTest(player, productKey)
		end
	end

	Players.PlayerAdded:Connect(function(player)
		task.spawn(onPlayer, player)
	end)

	for _, player in Players:GetPlayers() do
		task.spawn(onPlayer, player)
	end
end

return PurchaseService
