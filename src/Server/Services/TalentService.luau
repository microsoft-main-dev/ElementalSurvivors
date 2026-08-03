--!strict
--[[
	TalentService — древо талантов (раздел 6 ТЗ), M5.

	Отвечает за три вещи: законность вложения очка, сброс дерева за валюту
	и превращение вложенных очков в бонусы забега.

	Сервис ничего не пишет в профиль напрямую — только через операции
	DataService. Разделение проверок такое же, как у покупок: профиль владеет
	вопросом «есть ли свободное очко и не переполнен ли узел», а здесь живёт
	правило игры — «узел существует и открыт хотя бы один сосед».

	Бонусы складываются в тот же RunLoadout, который уже собрал питомец:
	источников бонусов будет больше (экипировка — M6), и все они должны
	сходиться в одну структуру, а не заводить каждый свой путь до боя.

	Публичный API:
		TalentService.GetBonuses(player)          -> TalentBonuses
		TalentService.Apply(player, loadout)
		TalentService.Spend(player, nodeId)       -> (boolean, string?)
		TalentService.Reset(player)               -> (boolean, string?)
		TalentService.ResetCost(player)           -> number
		TalentService.BuildView(player)           -> TalentsView?
		TalentService.PushView(player)
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Balance = require(Shared.Config.Balance)
local DataService = require(script.Parent.DataService)
local Net = require(Shared.Net)
local Talents = require(Shared.Config.Talents)
local Types = require(Shared.Types)

type TalentBonuses = Types.TalentBonuses

local TalentService = {}

local viewRemote: RemoteEvent? = nil

local function emptyBonuses(): TalentBonuses
	return {
		elementDamage = {},
		elementCooldown = {},
		maxHealth = 0,
		walkSpeed = 0,
		magnetRadius = 0,
		spent = 0,
	}
end

--[[
	Свернуть вложенные очки в бонусы.

	Проход идёт по профилю, а не по всем узлам дерева: вложенных узлов
	единицы, а узлов в дереве десятки. Неизвестные id молча пропускаются —
	так профиль переживает удаление узла из данных, а не ломается на входе.
]]
function TalentService.GetBonuses(player: Player): TalentBonuses
	local bonuses = emptyBonuses()

	local data = DataService.GetProfile(player)
	if not data then
		return bonuses
	end

	for nodeId, points in data.talents do
		local node = Talents.ById[nodeId]
		if not node or points <= 0 then
			continue
		end

		bonuses.spent += points

		local effect = node.effect
		local amount = effect.perPoint * points
		local element = node.element

		if effect.kind == "ElementDamage" and element then
			bonuses.elementDamage[element] = (bonuses.elementDamage[element] or 1) + amount
		elseif effect.kind == "ElementCooldown" and element then
			bonuses.elementCooldown[element] = (bonuses.elementCooldown[element] or 1) - amount
		elseif effect.kind == "MaxHealth" then
			bonuses.maxHealth += amount
		elseif effect.kind == "WalkSpeed" then
			bonuses.walkSpeed += amount
		elseif effect.kind == "MagnetRadius" then
			bonuses.magnetRadius += amount
		end
	end

	--[[
		Кулдаун зажимается снизу: дерево, набранное целиком в одну стихию,
		иначе однажды доведёт множитель до нуля и превратит способность
		в непрерывный луч, а деление на период — в деление на ноль.
	]]
	for element, value in bonuses.elementCooldown do
		bonuses.elementCooldown[element] = math.max(value, Balance.Talents.minCooldownMult)
	end

	return bonuses
end

--[[
	Наложить бонусы талантов на лоадаут, который уже собрал питомец.

	Множители перемножаются, а не складываются: сложение процентов из двух
	систем через пару этапов даст +300% и сломает баланс, а перемножение
	остаётся управляемым, сколько бы источников ни добавилось.
]]
function TalentService.Apply(player: Player, loadout: Types.RunLoadout): ()
	local bonuses = TalentService.GetBonuses(player)

	loadout.maxHealth += bonuses.maxHealth
	loadout.walkSpeed += bonuses.walkSpeed
	loadout.magnetRadius += bonuses.magnetRadius

	for element, multiplier in bonuses.elementDamage do
		loadout.elementDamage[element] = (loadout.elementDamage[element] or 1) * multiplier
	end

	for element, multiplier in bonuses.elementCooldown do
		loadout.elementCooldown[element] = (loadout.elementCooldown[element] or 1) * multiplier
	end
end

function TalentService.ResetCost(player: Player): number
	local data = DataService.GetProfile(player)
	if not data then
		return 0
	end

	local spent = 0
	for _, points in data.talents do
		spent += points
	end

	if spent <= 0 then
		return 0
	end

	return Balance.Talents.resetCostBase + Balance.Talents.resetCostPerPoint * spent
end

--[[
	Вложить очко.

	Правило раздела 6 ТЗ: узел открывается, только если открыт хотя бы один
	соседний. Корень — единственное исключение, иначе правилу не с чего было бы
	начаться. Проверка идёт по серверным данным целиком: с клиента приходит
	только id, и он ни на что, кроме поиска узла, не влияет.
]]
function TalentService.Spend(player: Player, nodeId: string): (boolean, string?)
	local node = Talents.ById[nodeId]
	if not node then
		return false, nil
	end

	local data = DataService.GetProfile(player)
	if not data then
		return false, nil
	end

	if data.talentPoints <= 0 then
		return false, "No talent points left. Level up to earn more."
	end

	if (data.talents[nodeId] or 0) >= node.maxPoints then
		return false, "That talent is already maxed."
	end

	if not Talents.IsRoot(nodeId) then
		local unlocked = false
		for _, neighbourId in Talents.Neighbours(nodeId) do
			if (data.talents[neighbourId] or 0) > 0 then
				unlocked = true
				break
			end
		end

		if not unlocked then
			return false, "Invest in a connected talent first."
		end
	end

	if not DataService.SpendTalentPoint(player, nodeId, node.maxPoints) then
		return false, nil
	end

	DataService.SaveNow(player)
	TalentService.PushView(player)

	return true, nil
end

--[[
	Сброс дерева за валюту (критерий приёмки M5).

	Порядок жёсткий: сначала списать, потом сбросить. Обратный порядок при
	неудачном списании оставил бы дерево сброшенным бесплатно.
]]
function TalentService.Reset(player: Player): (boolean, string?)
	local cost = TalentService.ResetCost(player)
	if cost <= 0 then
		return false, "Nothing to reset."
	end

	if not DataService.SpendCurrency(player, "essence", cost, "talents:reset") then
		return false, "Not enough Essence."
	end

	local refunded = DataService.ResetTalents(player)
	DataService.SaveNow(player)
	TalentService.PushView(player)

	return true, `Talent tree reset. {refunded} points returned.`
end

function TalentService.BuildView(player: Player): Types.TalentsView?
	local data = DataService.GetProfile(player)
	if not data then
		return nil
	end

	local atMax = data.level >= Balance.Meta.maxLevel

	return {
		level = data.level,
		xp = data.xp,
		xpToNext = if atMax then 0 else Balance.MetaXpForLevel(data.level),
		points = data.talentPoints,
		-- Копия, а не сам профиль: наружу профильные таблицы не отдаются никогда.
		spent = table.clone(data.talents),
		resetCost = TalentService.ResetCost(player),
		bonuses = TalentService.GetBonuses(player),
	}
end

function TalentService.PushView(player: Player): ()
	local remote = viewRemote
	if not remote then
		return
	end

	local view = TalentService.BuildView(player)
	if view then
		remote:FireClient(player, view)
	end
end

function TalentService.Init(): ()
	viewRemote = Net.GetEvent(Net.Id.TalentsView)
end

return TalentService
