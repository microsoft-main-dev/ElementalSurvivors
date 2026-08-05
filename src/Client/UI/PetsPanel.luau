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
local Balance = require(Shared.Config.Balance)
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

--[[
	Звёзды строкой: заполненные и пустые в пределах текущего этапа плюс подпись
	самого этапа. Цвет символами не передать, поэтому этап называется словом —
	«Purple 3/6» читается однозначно и не требует ни одного ассета.

	Финальная позиция — отдельный случай: там одна бриллиантовая звезда,
	а не седьмая красная.
]]
local STAGE_NAMES = { "White", "Purple", "Red" }

local function starText(stars: number): string
	if stars >= Pets.MaxStars then
		return "◆ Diamond"
	end

	local stage, index = Pets.StarStage(stars)
	local name = STAGE_NAMES[stage] or "?"
	local filled = string.rep("★", index)
	local empty = string.rep("☆", Balance.Pets.starsPerStage - index)

	return `{filled}{empty} {name}`
end

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
			row.title.Text = `{def.displayName}  ·  Lv {pet.level}  ·  {starText(pet.stars)}`

			local progress = if pet.xpToNext > 0 then `{pet.xp}/{pet.xp + pet.xpToNext} xp` else "max level"
			--[[
				Копии показываются только когда они есть: строка «0 copies»
				у каждого питомца ничего не сообщает, а место занимает.
				Дубликаты копятся на будущую эволюцию и опыта больше не дают.
			]]
			local starBonus = if pet.starMult > 1 then `  ·  stars x{string.format("%.1f", pet.starMult)}` else ""
			row.subtitle.Text = `{def.element}  ·  power {string.format("%.1f", pet.power)}  ·  {progress}{starBonus}`

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

			--[[
				Эволюция: копии превращаются в звезду. Кнопка гаснет, когда копий
				не хватает, и показывает, сколько их нужно, — иначе игрок
				не понимает, зачем ему дубликаты.
			]]
			local evolve = UiKit.Button(row.actions, "Evolve", "Max", Palette.UI.accent)
			evolve.LayoutOrder = 2
			evolve.Size = UDim2.fromOffset(150, UiKit.ButtonHeight)
			evolve.TextSize = 12

			local recipe = pet.evolve
			if recipe then
				--[[
					Что нужно на звезду, прямо на кнопке: «1×6★ + 2» означает
					одну копию этого же питомца шестизвёздочной и двух любых.
					Без этого игрок не понимает, зачем ему запас питомцев.
				]]
				local parts: { string } = {}
				if recipe.copies > 0 then
					table.insert(parts, `{recipe.haveCopies}/{recipe.copies}×{recipe.copyStars}★ same`)
				end
				if recipe.fodder > 0 then
					table.insert(parts, `{recipe.haveFodder}/{recipe.fodder}×{recipe.fodderStars}★ any`)
				end

				evolve.Text = `★ {table.concat(parts, " + ")}`
				UiKit.SetEnabled(
					evolve,
					recipe.haveCopies >= recipe.copies and recipe.haveFodder >= recipe.fodder + recipe.copies
				)
				evolve.Activated:Connect(function()
					send("EvolvePet", pet.uid, nil)
				end)
			else
				UiKit.SetEnabled(evolve, false)
			end

			local upgrade = UiKit.Button(row.actions, "Upgrade", "Max", Palette.UI.panel)
			upgrade.LayoutOrder = 3
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
