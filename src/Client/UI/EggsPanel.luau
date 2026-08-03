--!strict
--[[
	EggsPanel — яйца-лутбоксы (раздел 4 ТЗ).

	Шансы показываются честно и прямо в списке: это и требование жанра,
	и просто правильно. Числа берутся из той же таблицы Config/Eggs, по которой
	сервер и роллит, поэтому разойтись они не могут.

	Донатные яйца показываются всегда, но купить их нельзя, пока Prisms
	не появятся в игре (M7): лутбокс, о котором игрок не знает,
	ничего не мотивирует.

	Публичный API:
		EggsPanel.Build(parent, send) -> Panel
		panel.Open(eggKey?)
		panel.Close()
		panel.Refresh(essence, prisms)
		panel.ShowResults(results)
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Eggs = require(Shared.Config.Eggs)
local Palette = require(Shared.Config.Palette)
local Pets = require(Shared.Config.Pets)
local Types = require(Shared.Types)
local UiKit = require(script.Parent.UiKit)

local BULK_COUNT = 10
local RESULT_HEIGHT = 92

export type Panel = {
	Open: (eggKey: string?) -> (),
	Close: () -> (),
	Refresh: (essence: number, prisms: number) -> (),
	ShowResults: (results: { Types.EggRollResult }) -> (),
}

local EggsPanel = {}

-- Строка шансов: "B 60% · A 27% · S 10% · SS 2.7% · SSS 0.3%".
local function chanceText(egg: Eggs.EggDef): string
	local parts: { string } = {}
	for _, rarity in Pets.Rarities do
		local chance = Eggs.Chance(egg, rarity) * 100
		if chance > 0 then
			-- Мелкие шансы без дробей превратились бы в честный, но бесполезный «0%».
			local formatted = if chance < 1 then string.format("%.1f", chance) else string.format("%.0f", chance)
			table.insert(parts, `{rarity} {formatted}%`)
		end
	end
	return table.concat(parts, " · ")
end

function EggsPanel.Build(parent: Instance, send: (action: string, target: string?, extra: unknown) -> ()): Panel
	local window = UiKit.Window(parent, "EggsPanel", "Eggs")
	window.subtitle.Text = "Odds are shown for every egg. Duplicates turn into pet experience."

	local list = UiKit.Scroll(window.content, "List")
	list.Size = UDim2.new(1, 0, 1, -RESULT_HEIGHT)

	--[[
		Полоса результатов внизу, а не отдельное окно: после покупки ×10 игрок
		смотрит именно сюда, и закрывать ради этого список яиц незачем.
	]]
	local resultsBox = UiKit.Frame(window.content, "Results", Palette.UI.background)
	resultsBox.AnchorPoint = Vector2.new(0, 1)
	resultsBox.Position = UDim2.fromScale(0, 1)
	resultsBox.Size = UDim2.new(1, 0, 0, RESULT_HEIGHT - 8)
	resultsBox.BackgroundTransparency = 0.3
	UiKit.Corners(resultsBox, 8)
	UiKit.Padding(resultsBox, 8)

	local resultsLabel = UiKit.Label(resultsBox, "Text", "Nothing hatched yet.", 14, Palette.UI.subtext)
	resultsLabel.Size = UDim2.fromScale(1, 1)
	resultsLabel.TextWrapped = true
	resultsLabel.TextYAlignment = Enum.TextYAlignment.Top

	local essenceBalance = 0
	local prismsBalance = 0

	-- Кнопки перестраиваются целиком при каждом обновлении баланса: список
	-- короткий и фиксированный, экономить здесь нечего.
	local function render(): ()
		UiKit.ClearList(list)

		for order, egg in Eggs.List do
			local row = UiKit.Row(list, order, Color3.fromHex(egg.color))
			row.frame.Size = UDim2.new(1, -8, 0, UiKit.RowHeight + 10)
			row.badge.Text = if egg.currency == "essence" then "E" else "P"
			row.title.Text = `{egg.displayName}  ·  {UiKit.FormatAmount(egg.price)} {egg.currency}`
			row.subtitle.Text = chanceText(egg)

			local balance = if egg.currency == "essence" then essenceBalance else prismsBalance

			local one = UiKit.Button(row.actions, "BuyOne", "x1")
			one.LayoutOrder = 1
			one.Size = UDim2.fromOffset(62, UiKit.ButtonHeight)
			UiKit.SetEnabled(one, balance >= egg.price)
			one.Activated:Connect(function()
				send("BuyEgg", egg.key, 1)
			end)

			local bulk = UiKit.Button(row.actions, "BuyBulk", `x{BULK_COUNT}`, Palette.UI.panel)
			bulk.LayoutOrder = 2
			bulk.Size = UDim2.fromOffset(70, UiKit.ButtonHeight)
			UiKit.SetEnabled(bulk, balance >= egg.price * BULK_COUNT)
			bulk.Activated:Connect(function()
				send("BuyEgg", egg.key, BULK_COUNT)
			end)
		end
	end

	local panel: Panel = {
		Open = function(eggKey: string?)
			window.screen.Enabled = true
			-- Промпт у конкретного яйца подписывает панель этим яйцом:
			-- игрок подошёл к нему, а не к «яйцам вообще».
			local egg = if eggKey then Eggs.ByKey[eggKey] else nil
			window.title.Text = if egg then egg.displayName else "Eggs"
			render()
		end,

		Close = function()
			window.screen.Enabled = false
		end,

		Refresh = function(essence: number, prisms: number)
			essenceBalance = essence
			prismsBalance = prisms
			if window.screen.Enabled then
				render()
			end
		end,

		ShowResults = function(results: { Types.EggRollResult })
			local parts: { string } = {}
			for _, result in results do
				local def = Pets.ByKey[result.petId]
				local name = if def then def.displayName else result.petId
				local rarity = if def then def.rarity else "?"
				if result.duplicate then
					table.insert(parts, `{name} [{rarity}] — duplicate, +{result.xpGained} xp`)
				else
					table.insert(parts, `{name} [{rarity}] — NEW`)
				end
			end

			resultsLabel.Text = if #parts > 0 then table.concat(parts, "\n") else "Nothing hatched yet."
		end,
	}

	return panel
end

return EggsPanel
