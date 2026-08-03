--!strict
--[[
	PetsPanel — коллекция питомцев: экипировка и прокачка (раздел 6 ТЗ).

	Ни одно число здесь не считается: сила, цена улучшения и остаток опыта
	приходят готовыми в PetsView. Клиент не должен уметь предсказывать цену —
	иначе рано или поздно он покажет одну, а сервер спишет другую.

	Публичный API:
		PetsPanel.Build(parent, send) -> Panel
		panel.Open()
		panel.Close()
		panel.Refresh(pets, essence)
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Palette = require(Shared.Config.Palette)
local Pets = require(Shared.Config.Pets)
local Types = require(Shared.Types)
local UiKit = require(script.Parent.UiKit)

export type Panel = {
	Open: () -> (),
	Close: () -> (),
	Refresh: (pets: Types.PetsView?, essence: number) -> (),
}

local PetsPanel = {}

function PetsPanel.Build(parent: Instance, send: (action: string, target: string?, extra: unknown) -> ()): Panel
	local window = UiKit.Window(parent, "PetsPanel", "Pets")

	local list = UiKit.Scroll(window.content, "List")
	list.Size = UDim2.fromScale(1, 1)

	local latest: Types.PetsView? = nil
	local essenceBalance = 0

	local function render(): ()
		UiKit.ClearList(list)

		local view = latest
		if not view then
			return
		end

		window.subtitle.Text = string.format(
			"Collection power %.1f  •  Expeditions %d Essence/h  •  Cap %d h",
			view.collectionPower,
			math.floor(view.offlineRatePerHour),
			view.offlineCapHours
		)

		if #view.pets == 0 then
			local empty = UiKit.Label(list, "Empty", "No pets yet. Hatch an egg to get one.", 16, Palette.UI.subtext)
			empty.Size = UDim2.new(1, -8, 0, 40)
			return
		end

		for order, pet in view.pets do
			local def = Pets.ByKey[pet.petId]
			if not def then
				continue
			end

			local row = UiKit.Row(list, order, Palette.Rarity[def.rarity])
			row.badge.Text = def.rarity
			row.title.Text = `{def.displayName}  ·  Lv {pet.level}`

			local progress = if pet.xpToNext > 0 then `{pet.xp}/{pet.xp + pet.xpToNext} xp` else "max level"
			row.subtitle.Text = `{def.element}  ·  power {string.format("%.1f", pet.power)}  ·  {progress}`

			--[[
				Экипированный питомец не предлагает кнопку «Equip»: нажать её
				можно, но она ничего не сделает, а кнопка, которая ничего
				не делает, читается как поломка.
			]]
			if pet.equipped then
				local mark = UiKit.Label(row.actions, "Equipped", "Equipped", 14, Palette.UI.subtext)
				mark.LayoutOrder = 1
				mark.Size = UDim2.fromOffset(76, UiKit.ButtonHeight)
				mark.TextXAlignment = Enum.TextXAlignment.Center
			else
				local equip = UiKit.Button(row.actions, "Equip", "Equip")
				equip.LayoutOrder = 1
				equip.Size = UDim2.fromOffset(76, UiKit.ButtonHeight)
				equip.Activated:Connect(function()
					send("EquipPet", pet.uid, nil)
				end)
			end

			local upgrade = UiKit.Button(row.actions, "Upgrade", "Max", Palette.UI.panel)
			upgrade.LayoutOrder = 2
			upgrade.Size = UDim2.fromOffset(92, UiKit.ButtonHeight)

			if pet.upgradeCost > 0 then
				upgrade.Text = `Lv+ {UiKit.FormatAmount(pet.upgradeCost)}`
				UiKit.SetEnabled(upgrade, essenceBalance >= pet.upgradeCost)
				upgrade.Activated:Connect(function()
					send("UpgradePet", pet.uid, nil)
				end)
			else
				UiKit.SetEnabled(upgrade, false)
			end
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

		--[[
			Перерисовка только при открытой панели: коллекция обновляется после
			каждой покупки, а перестраивать невидимый список — работа впустую.
		]]
		Refresh = function(pets: Types.PetsView?, essence: number)
			latest = pets
			essenceBalance = essence
			if window.screen.Enabled then
				render()
			end
		end,
	}

	return panel
end

return PetsPanel
