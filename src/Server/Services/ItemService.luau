--!strict
--[[
	ItemService — экипировка (раздел 6.1 ТЗ), M6.

	Броня выпадает за прохождение сюжетных уровней и надевается в лобби.
	Бонусы предметов ложатся в тот же RunLoadout, что и бонусы питомца
	и талантов, третьим и последним шагом — порядок задан в CombatService.

	Множители перемножаются с остальными источниками, добавки складываются:
	то же правило, что и у талантов, и по той же причине — сложение процентов
	из трёх систем через этап-другой даёт бессмысленные числа.

	Публичный API:
		ItemService.GrantForStage(player, stage) -> { ItemInstance }
		ItemService.Equip(player, uid)           -> (boolean, string?)
		ItemService.Apply(player, loadout)
		ItemService.BuildView(player)            -> ItemsView?
		ItemService.PushView(player)
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local DataService = require(script.Parent.DataService)
local Elements = require(Shared.Config.Elements)
local Items = require(Shared.Config.Items)
local Net = require(Shared.Net)
local Types = require(Shared.Types)

type ItemInstance = Types.ItemInstance

local ItemService = {}

local viewRemote: RemoteEvent? = nil

--[[
	Генератор выпадения. Без seed намеренно, по той же причине, что и у яиц:
	предсказуемая последовательность лута — это то, что при первой же утечке
	превращается в «посмотреть, что выпадет следующим».
]]
local random = Random.new()

local function equippedItems(player: Player): { ItemInstance }
	local data = DataService.GetProfile(player)
	if not data then
		return {}
	end

	local result: { ItemInstance } = {}
	for _, item in data.inventory.items do
		if data.equipment[item.slot] == item.uid then
			table.insert(result, item)
		end
	end
	return result
end

--[[
	Выдать награду за пройденный уровень.

	Финал локации даёт гарантированный предмет (раздел 5.1 ТЗ), обычный
	уровень — по шансу. За поражение предметов не даётся вовсе: утешительная
	выплата за проигрыш — только Essence и опыт.
]]
function ItemService.GrantForStage(player: Player, stage: Types.StageDef): { ItemInstance }
	local granted: { ItemInstance } = {}
	local count = Items.DropCount(stage.isLocationFinal, random)

	for _ = 1, count do
		--[[
			На финале локации предмет не только гарантирован, но и заведомо
			не мусорный: обещанная награда, оказавшаяся обычным шлемом,
			ощущается обманом.
		]]
		local guaranteed: Types.ItemRarity? = if stage.isLocationFinal then "Rare" else nil
		local item = Items.Roll(stage.index, guaranteed, random)

		if DataService.AddItem(player, item) then
			table.insert(granted, item)
		end
	end

	if #granted > 0 then
		ItemService.PushView(player)
	end

	return granted
end

function ItemService.Equip(player: Player, uid: string): (boolean, string?)
	local data = DataService.GetProfile(player)
	if not data then
		return false, nil
	end

	for _, item in data.inventory.items do
		if item.uid == uid then
			if data.equipment[item.slot] == uid then
				-- Повторное нажатие снимает предмет: отдельная кнопка «снять»
				-- на слот заняла бы место ради действия, которое делают раз в час.
				DataService.SetEquippedItem(player, item.slot, "")
				DataService.SaveNow(player)
				ItemService.PushView(player)
				return true, `{item.slot} unequipped.`
			end

			DataService.SetEquippedItem(player, item.slot, uid)
			DataService.SaveNow(player)
			ItemService.PushView(player)
			return true, `{item.rarity} {item.slot} equipped. Applies to your next run.`
		end
	end

	return false, "You do not own that item."
end

--[[
	Наложить бонусы экипировки на лоадаут.

	AllDamage умножает урон ВСЕХ стихий, поэтому проходит по полному списку:
	у лоадаута может не быть записи для стихии, которую не усилил ни питомец,
	ни таланты, а способность этой стихии в забеге появиться вполне может.
]]
function ItemService.Apply(player: Player, loadout: Types.RunLoadout): ()
	local damageMult = 1

	for _, item in equippedItems(player) do
		for kind, value in item.stats do
			if kind == "MaxHealth" then
				loadout.maxHealth += value
			elseif kind == "WalkSpeed" then
				loadout.walkSpeed += value
			elseif kind == "MagnetRadius" then
				loadout.magnetRadius += value
			elseif kind == "AllDamage" then
				damageMult *= 1 + value
			end
		end
	end

	if damageMult ~= 1 then
		for _, element in Elements.List do
			loadout.elementDamage[element] = (loadout.elementDamage[element] or 1) * damageMult
		end
	end
end

function ItemService.BuildView(player: Player): Types.ItemsView?
	local data = DataService.GetProfile(player)
	if not data then
		return nil
	end

	local views: { Types.ItemView } = {}
	for _, item in data.inventory.items do
		table.insert(views, {
			uid = item.uid,
			slot = item.slot,
			rarity = item.rarity,
			stats = item.stats,
			power = Items.Power(item),
			equipped = data.equipment[item.slot] == item.uid,
		})
	end

	-- Сильные сверху: инвентарь на шестьдесят предметов иначе нечитаем.
	table.sort(views, function(a: Types.ItemView, b: Types.ItemView): boolean
		if a.power == b.power then
			return a.uid < b.uid
		end
		return a.power > b.power
	end)

	return { items = views, equipped = table.clone(data.equipment) }
end

function ItemService.PushView(player: Player): ()
	local remote = viewRemote
	if not remote then
		return
	end

	local view = ItemService.BuildView(player)
	if view then
		remote:FireClient(player, view)
	end
end

function ItemService.Init(): ()
	viewRemote = Net.GetEvent(Net.Id.ItemsView)
end

return ItemService
