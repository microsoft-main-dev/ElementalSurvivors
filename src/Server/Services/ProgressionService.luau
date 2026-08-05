--!strict
--[[
	ProgressionService — уровни внутри забега и выбор карточек (раздел 3.6 ТЗ).

	Эти уровни НЕ сохраняются: они живут ровно один забег. Мета-уровень
	персонажа — другая система и появится в M5.

	Здесь же лежит единственная в проекте обработка клиентского вызова,
	поэтому проверки перечислены явно (раздел 7 ТЗ):
		1. частота вызовов        — RateLimiter
		2. тип и диапазон индекса — number, целое, 1..#offer
		3. право на действие      — игрок должен быть в забеге
		4. состояние              — забег должен стоять на паузе с активным предложением
		5. совпадение             — карточка берётся из того набора, что сервер
		                            сгенерировал и запомнил, клиентские данные
		                            в применении не участвуют вообще

	Публичный API:
		ProgressionService.StartRun(slot, player)
		ProgressionService.StopRun(slot)
		ProgressionService.AddXp(slot, amount)
		ProgressionService.IsPaused(slot)   -> boolean
		ProgressionService.GetState(slot)   -> { level, xp, xpToNext }
		ProgressionService.DebugMaxLevel(slot)
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Abilities = require(Shared.Config.Abilities)
local AbilityService = require(script.Parent.AbilityService)
local Balance = require(Shared.Config.Balance)
local Cards = require(Shared.Config.Cards)
local EnemyService = require(script.Parent.EnemyService)
local Net = require(Shared.Net)
local RateLimiter = require(Shared.Util.RateLimiter)
local Types = require(Shared.Types)
local XpCurve = require(Shared.Util.XpCurve)

type LevelUpCard = Types.LevelUpCard

type Sim = {
	slot: number,
	player: Player,
	level: number,
	xp: number,
	xpToNext: number,
	paused: boolean,
	offer: { LevelUpCard }?,
	offerToken: number,
}

export type State = {
	level: number,
	xp: number,
	xpToNext: number,
}

local ProgressionService = {}

local sims: { [number]: Sim } = {}
local slotByPlayer: { [Player]: number } = {}
local random = Random.new()

local offerRemote: RemoteEvent? = nil
local choiceRemote: RemoteEvent? = nil
local pausedRemote: RemoteEvent? = nil

-- Не больше 8 нажатий за 5 секунд: живому человеку хватает с огромным запасом.
local choiceLimiter = RateLimiter.new(8, 5)

local function setPaused(sim: Sim, paused: boolean): ()
	sim.paused = paused
	EnemyService.SetPaused(sim.slot, paused)

	local remote = pausedRemote
	if remote then
		remote:FireClient(sim.player, paused)
	end
end

--[[
	Кандидаты: поднять уровень тому, что уже есть, и взять новое, если
	не упёрлись в потолок активных. Из кандидатов случайно берутся три.
]]
local function buildOffer(sim: Sim): { LevelUpCard }
	local candidates: { LevelUpCard } = {}

	--[[
		Улучшения того, что уже есть. Способность на потолке в кандидаты
		не попадает: карточка «взять то, что уже максимум» — это мусор,
		а к концу забега таких было бы большинство.
	]]
	for _, view in AbilityService.GetViews(sim.slot) do
		local def = Abilities.ByKey[view.key]
		if def and view.level < Abilities.MaxLevel then
			table.insert(candidates, {
				abilityKey = view.key,
				isNew = false,
				level = view.level + 1,
				rarity = Cards.Roll(random).key,
			})
		end
	end

	--[[
		Новые способности — только пока есть свободный слот, и только базовые:
		уникальную способность питомца карточкой не выдают, её приносят с собой.
	]]
	if AbilityService.CanTakeMore(sim.slot) then
		for _, def in Abilities.BaseList do
			if AbilityService.GetLevel(sim.slot, def.key) == 0 then
				--[[
					Первый уровень редкости не имеет: он ничего не множит,
					способности ещё нет. Показывать «Legendary» на карточке,
					которая даёт ровно то же, что обычная, — обман.
				]]
				table.insert(candidates, {
					abilityKey = def.key,
					isNew = true,
					level = 1,
					rarity = Cards.Common.key,
				})
			end
		end
	end

	-- Перемешиваем и берём сколько есть, но не больше cardsPerLevel.
	for index = #candidates, 2, -1 do
		local swap = random:NextInteger(1, index)
		candidates[index], candidates[swap] = candidates[swap], candidates[index]
	end

	local wanted = math.min(Balance.Progression.cardsPerLevel, #candidates)
	local offer: { LevelUpCard } = table.create(wanted)
	for index = 1, wanted do
		offer[index] = candidates[index]
	end

	return offer
end

local function applyCard(sim: Sim, card: LevelUpCard): ()
	if card.isNew then
		AbilityService.Grant(sim.slot, card.abilityKey)
	else
		-- Множитель берётся из карточки, которую запомнил сервер, а не из того,
		-- что прислал клиент: клиентские данные в применении не участвуют вовсе.
		AbilityService.LevelUp(sim.slot, card.abilityKey, Cards.MultiplierFor(card.rarity))
	end
end

local function offerLevelUp(sim: Sim): ()
	local offer = buildOffer(sim)

	-- Брать больше нечего (всё максимального уровня) — молча идём дальше.
	if #offer == 0 then
		sim.offer = nil
		if sim.paused then
			setPaused(sim, false)
		end
		return
	end

	sim.offer = offer
	sim.offerToken += 1
	local token = sim.offerToken

	if not sim.paused then
		setPaused(sim, true)
	end

	local remote = offerRemote
	if remote then
		remote:FireClient(sim.player, sim.level, offer)
	end

	-- Страховка от зависшей арены: если игрок отошёл, сервер выберет за него.
	task.delay(Balance.Progression.choiceTimeout, function()
		local current = sims[sim.slot]
		if current == sim and sim.offerToken == token and sim.offer then
			ProgressionService.Resolve(sim.player, 1)
		end
	end)
end

local function advanceLevels(sim: Sim): ()
	if sim.offer then
		return -- уже ждём выбора, следующий уровень выдадим после него
	end

	if sim.xp >= sim.xpToNext then
		sim.xp -= sim.xpToNext
		sim.level += 1
		sim.xpToNext = XpCurve.ForLevel(sim.level)
		offerLevelUp(sim)
	end
end

function ProgressionService.AddXp(slot: number, amount: number): ()
	local sim = sims[slot]
	if not sim then
		return
	end

	sim.xp += amount
	advanceLevels(sim)
end

--[[
	Применение выбора. Отдельной публичной функцией, чтобы её мог вызвать
	и таймаут, и обработчик Remote — вся валидация происходит до вызова.
]]
function ProgressionService.Resolve(player: Player, index: number): boolean
	local slot = slotByPlayer[player]
	if not slot then
		return false
	end

	local sim = sims[slot]
	if not sim or not sim.paused then
		return false
	end

	local offer = sim.offer
	if not offer then
		return false
	end

	if index < 1 or index > #offer then
		return false
	end

	applyCard(sim, offer[index])
	sim.offer = nil

	-- Могло накопиться на несколько уровней сразу — тогда пауза продолжается.
	if sim.xp >= sim.xpToNext then
		sim.xp -= sim.xpToNext
		sim.level += 1
		sim.xpToNext = XpCurve.ForLevel(sim.level)
		offerLevelUp(sim)
	else
		setPaused(sim, false)
	end

	return true
end

--[[
	Тестовая кнопка "BossFight" в лобби (M7): выдаёт билд максимального
	уровня — все способности взяты и подняты до предела — одним вызовом,
	без единого клика по карточке и без паузы боя на выбор.

	Studio-only по тому же приёму, что у StageService.DebugRushToBoss.
]]
function ProgressionService.DebugMaxLevel(slot: number): ()
	if not RunService:IsStudio() then
		return
	end

	local sim = sims[slot]
	if not sim then
		return
	end

	local upgrades = 0

	while AbilityService.CanTakeMore(slot) do
		local key: string? = nil
		for _, def in Abilities.BaseList do
			if AbilityService.GetLevel(slot, def.key) == 0 then
				key = def.key
				break
			end
		end
		if not key then
			break
		end
		AbilityService.Grant(slot, key)
		upgrades += 1
	end

	-- Обычной редкостью: тестовая кнопка проверяет боссов, а не везение.
	for _, view in AbilityService.GetViews(slot) do
		while AbilityService.GetLevel(slot, view.key) < Abilities.MaxLevel do
			AbilityService.LevelUp(slot, view.key, 1)
			upgrades += 1
		end
	end

	sim.level = 1 + upgrades
	sim.xp = 0
	sim.xpToNext = XpCurve.ForLevel(sim.level)
end

function ProgressionService.IsPaused(slot: number): boolean
	local sim = sims[slot]
	return if sim then sim.paused else false
end

function ProgressionService.GetState(slot: number): State
	local sim = sims[slot]
	if not sim then
		return { level = 1, xp = 0, xpToNext = XpCurve.ForLevel(1) }
	end
	return { level = sim.level, xp = sim.xp, xpToNext = sim.xpToNext }
end

function ProgressionService.StartRun(slot: number, player: Player): ()
	sims[slot] = {
		slot = slot,
		player = player,
		level = 1,
		xp = 0,
		xpToNext = XpCurve.ForLevel(1),
		paused = false,
		offer = nil,
		offerToken = 0,
	}
	slotByPlayer[player] = slot
end

function ProgressionService.StopRun(slot: number): ()
	local sim = sims[slot]
	if sim then
		slotByPlayer[sim.player] = nil
	end
	sims[slot] = nil
end

function ProgressionService.Init(): ()
	offerRemote = Net.GetEvent(Net.Id.LevelUpOffer)
	choiceRemote = Net.GetEvent(Net.Id.LevelUpChoice)
	pausedRemote = Net.GetEvent(Net.Id.CombatPaused)
end

function ProgressionService.Start(): ()
	--[[
		Кривая опыта выводится из расписания волн, и увидеть, что из этого
		вышло, иначе негде. Печатается только в Studio и только при старте:
		это отчёт о расчёте, а не отладка боя.
	]]
	if RunService:IsStudio() then
		print(XpCurve.Describe())
	end

	local remote = choiceRemote
	if not remote then
		return
	end

	remote.OnServerEvent:Connect(function(player: Player, rawIndex: unknown)
		if not choiceLimiter.Allow(player) then
			warn(`[ProgressionService] Превышена частота выбора карточек: {player.Name}`)
			return
		end

		-- Тип и диапазон проверяются до всего остального: дальше в логику
		-- уходит уже заведомо целое число, а не то, что прислал клиент.
		if typeof(rawIndex) ~= "number" then
			return
		end
		local index = rawIndex :: number
		if index ~= index or index % 1 ~= 0 then
			return
		end

		ProgressionService.Resolve(player, index)
	end)

	Players.PlayerRemoving:Connect(function(player: Player)
		choiceLimiter.Forget(player)
		slotByPlayer[player] = nil
	end)
end

return ProgressionService
