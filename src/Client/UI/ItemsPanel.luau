--!strict
--[[
	ItemsPanel — инвентарь экипировки (разделы 6.1 и 8 ТЗ), M6.

	Показывает предметы по убыванию силы и отмечает надетые. Повторное нажатие
	на надетый предмет снимает его — отдельная кнопка «снять» у каждой строки
	заняла бы место ради действия, которое делают раз в час.

	Ни одно число здесь не считается: сила и характеристики приходят готовыми.

	Публичный API:
		ItemsPanel.Build(parent, send) -> Panel
		panel.Open() / panel.Close()
		panel.Refresh(view)
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Items = require(Shared.Config.Items)
local Palette = require(Shared.Config.Palette)
local Types = require(Shared.Types)
local UiKit = require(script.Parent.UiKit)

export type Panel = {
	Open: () -> (),
	Close: () -> (),
	Refresh: (view: Types.ItemsView?) -> (),
}

local ItemsPanel = {}

-- «+12.4 health · +0.03 damage» — характеристики строкой, как они выпали.
local function statsText(stats: { [string]: number }): string
	local parts: { string } = {}

	for kind, value in stats do
		if kind == "AllDamage" then
			table.insert(parts, `+{math.floor(value * 100 + 0.5)}% damage`)
		elseif kind == "MaxHealth" then
			table.insert(parts, `+{value} health`)
		elseif kind == "WalkSpeed" then
			table.insert(parts, `+{value} speed`)
		else
			table.insert(parts, `+{value} pickup`)
		end
	end

	table.sort(parts)
	return table.concat(parts, "  ·  ")
end

function ItemsPanel.Build(parent: Instance, send: (action: string, target: string?, extra: unknown) -> ()): Panel
	local window = UiKit.Window(parent, "ItemsPanel", "Equipment")

	local list = UiKit.Scroll(window.content, "List")
	list.Size = UDim2.fromScale(1, 1)

	local latest: Types.ItemsView? = nil

	local function render(): ()
		UiKit.ClearList(list)

		local view = latest
		if not view or #view.items == 0 then
			local empty =
				UiKit.Label(list, "Empty", "No equipment yet. Clear story stages to find some.", 16, Palette.UI.subtext)
			empty.Size = UDim2.new(1, -8, 0, 40)
			return
		end

		local equippedCount = 0
		for _ in view.equipped do
			equippedCount += 1
		end
		window.subtitle.Text = `{#view.items} items  ·  {equippedCount} of {#Items.Slots} slots filled`

		for order, item in view.items do
			local rarity = Items.RarityByKey[item.rarity]
			local row = UiKit.Row(list, order, Color3.fromHex(if rarity then rarity.color else "#8A9A92"))

			row.badge.Text = string.sub(item.slot, 1, 2)
			row.title.Text = `{item.rarity} {item.slot}  ·  power {math.floor(item.power)}`
			row.subtitle.Text = statsText(item.stats)

			local button = UiKit.Button(row.actions, "Equip", if item.equipped then "Unequip" else "Equip")
			button.LayoutOrder = 1
			button.Size = UDim2.fromOffset(112, UiKit.ButtonHeight)
			if item.equipped then
				button.BackgroundColor3 = Palette.UI.panel
			end
			button.Activated:Connect(function()
				send("EquipItem", item.uid, nil)
			end)
		end
	end

	local panel: Panel = {
		Open = function()
			window.screen.Enabled = true
			render()
		end,

		Close = function()
			window.screen.Enabled = false
		end,

		Refresh = function(view: Types.ItemsView?)
			latest = view
			if window.screen.Enabled then
				render()
			end
		end,
	}

	return panel
end

return ItemsPanel
