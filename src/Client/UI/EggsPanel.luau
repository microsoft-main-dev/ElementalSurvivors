--!strict
--[[
	EggsPanel — яйца-лутбоксы (раздел 4 ТЗ).

	Два вида одного окна:

		список  — все яйца, если игрок нажал кнопку «Eggs» в панели лобби;
		яйцо    — страница конкретного яйца, если игрок подошёл к нему в лобби.

	Раньше оба случая показывали один общий список, и подойти к конкретному
	яйцу означало ровно то же, что нажать общую кнопку. Теперь у яйца есть своя
	страница: картинка, цена, кнопки покупки и ВЕСЬ его пул питомцев с редкостью
	и шансом на каждого.

	Шансы показываются честно: это и требование жанра, и просто правильно.
	Числа берутся из той же таблицы Config/Eggs, по которой сервер и роллит,
	поэтому разойтись они не могут. Шанс конкретного питомца — это шанс его
	редкости, делённый на число питомцев этой редкости: внутри редкости все
	равновероятны (Eggs.Roll).

	Неполученные питомцы показаны силуэтами — чёрными плашками без имени.
	Видно, что в яйце что-то есть, и не видно, что именно: коллекция должна
	открываться игрой, а не чтением интерфейса.

	Публичный API:
		EggsPanel.Build(parent, send) -> Panel
		panel.Open(eggKey?)
		panel.Close()
		panel.Refresh(essence, prisms, petsView)
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
local IMAGE_HEIGHT = 132

export type Panel = {
	Open: (eggKey: string?) -> (),
	Close: () -> (),
	Refresh: (essence: number, prisms: number, petsView: Types.PetsView?) -> (),
	ShowResults: (results: { Types.EggRollResult }) -> (),
}

local EggsPanel = {}

-- Строка шансов по редкостям: "B 60% · A 27% · S 10% · SS 2.7% · SSS 0.3%".
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

-- Шанс на конкретного питомца: шанс редкости, поделённый поровну.
local function petChance(egg: Eggs.EggDef, def: Types.PetDef): number
	local bucket = Pets.ByRarity[def.rarity]
	if not bucket or #bucket == 0 then
		return 0
	end
	return Eggs.Chance(egg, def.rarity) / #bucket
end

local function formatChance(chance: number): string
	local percent = chance * 100
	if percent >= 1 then
		return string.format("%.1f%%", percent)
	end
	-- У SSS в базовом яйце шанс 0.1% на питомца: два знака — это не педантизм,
	-- а разница между «редко» и «никогда».
	return string.format("%.2f%%", percent)
end

function EggsPanel.Build(parent: Instance, send: (action: string, target: string?, extra: unknown) -> ()): Panel
	local window = UiKit.Window(parent, "EggsPanel", "Eggs")

	local list = UiKit.Scroll(window.content, "List")
	list.Size = UDim2.new(1, 0, 1, -RESULT_HEIGHT)

	--[[
		Полоса результатов внизу, а не отдельное окно: после покупки ×10 игрок
		смотрит именно сюда, и закрывать ради этого страницу яйца незачем.
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
	local owned: { [string]: boolean } = {}
	local currentEgg: string? = nil

	local render: () -> ()

	--[[
		Заголовок страницы яйца: картинка (или заглушка её цветом), цена,
		шансы по редкостям и кнопки покупки.
	]]
	local function renderEggHeader(egg: Eggs.EggDef): ()
		local holder = UiKit.Frame(list, "Header", Palette.UI.background)
		holder.LayoutOrder = 0
		holder.Size = UDim2.new(1, -8, 0, IMAGE_HEIGHT)
		holder.BackgroundTransparency = 0.3
		UiKit.Corners(holder, 8)

		local color = Color3.fromHex(egg.color)

		if egg.imageAssetId > 0 then
			local image = Instance.new("ImageLabel")
			image.Name = "Image"
			image.BackgroundTransparency = 1
			image.ScaleType = Enum.ScaleType.Fit
			image.Image = `rbxassetid://{egg.imageAssetId}`
			image.Position = UDim2.fromOffset(8, 8)
			image.Size = UDim2.fromOffset(IMAGE_HEIGHT - 16, IMAGE_HEIGHT - 16)
			image.Parent = holder
		else
			-- Заглушка вместо картинки: цвет яйца и его буква. Ассета ещё нет,
			-- а панель должна выглядеть законченной уже сейчас.
			local placeholder = UiKit.Frame(holder, "Image", color)
			placeholder.Position = UDim2.fromOffset(8, 8)
			placeholder.Size = UDim2.fromOffset(IMAGE_HEIGHT - 16, IMAGE_HEIGHT - 16)
			UiKit.Corners(placeholder, 50)

			local letter =
				UiKit.Label(placeholder, "Letter", string.sub(egg.displayName, 1, 1), 42, Palette.UI.background)
			letter.Size = UDim2.fromScale(1, 1)
			letter.Font = Enum.Font.GothamBold
			letter.TextXAlignment = Enum.TextXAlignment.Center
		end

		local textLeft = IMAGE_HEIGHT + 4

		--[[
			Кнопка возврата к списку стоит справа сверху, а не над кнопками
			покупки: на телефоне ширина панели около трёхсот точек, и всё, что
			встаёт в один ряд с покупкой, оттуда вываливается.
		]]
		local back = UiKit.Button(holder, "Back", "All eggs", Palette.UI.panel)
		back.AnchorPoint = Vector2.new(1, 0)
		back.Position = UDim2.new(1, -8, 0, 8)
		back.Size = UDim2.fromOffset(96, UiKit.ButtonHeight - 12)
		back.Activated:Connect(function()
			currentEgg = nil
			render()
		end)

		local price = UiKit.Label(holder, "Price", `{UiKit.FormatAmount(egg.price)} {egg.currency}`, 20, color)
		price.Font = Enum.Font.GothamBold
		price.Position = UDim2.fromOffset(textLeft, 10)
		-- Ширина с оглядкой на кнопку возврата: длинная цена не должна
		-- заезжать под неё.
		price.Size = UDim2.new(1, -textLeft - 112, 0, 24)

		local description = UiKit.Label(holder, "Description", egg.description, 13, Palette.UI.subtext)
		description.Position = UDim2.fromOffset(textLeft, 36)
		description.Size = UDim2.new(1, -textLeft - 8, 0, 32)
		description.TextWrapped = true

		local odds = UiKit.Label(holder, "Odds", chanceText(egg), 12, Palette.UI.text)
		odds.Position = UDim2.fromOffset(textLeft, 70)
		odds.Size = UDim2.new(1, -textLeft - 8, 0, 18)

		local balance = if egg.currency == "essence" then essenceBalance else prismsBalance

		--[[
			Кнопки покупки делят ширину текстовой колонки пополам в ДОЛЯХ,
			а не в пикселях: при фиксированных размерах вторая кнопка уезжала
			за край панели на телефоне.
		]]
		local buttons = UiKit.Frame(holder, "Buttons")
		buttons.Position = UDim2.fromOffset(textLeft, 92)
		buttons.Size = UDim2.new(1, -textLeft - 8, 0, UiKit.ButtonHeight - 12)

		local buttonsLayout = Instance.new("UIListLayout")
		buttonsLayout.FillDirection = Enum.FillDirection.Horizontal
		buttonsLayout.SortOrder = Enum.SortOrder.LayoutOrder
		buttonsLayout.Padding = UDim.new(0, 6)
		buttonsLayout.Parent = buttons

		local one = UiKit.Button(buttons, "BuyOne", "Buy x1")
		one.LayoutOrder = 1
		one.Size = UDim2.new(0.5, -3, 1, 0)
		UiKit.SetEnabled(one, balance >= egg.price)
		one.Activated:Connect(function()
			send("BuyEgg", egg.key, 1)
		end)

		local bulk = UiKit.Button(buttons, "BuyBulk", `Buy x{BULK_COUNT}`, Palette.UI.panel)
		bulk.LayoutOrder = 2
		bulk.Size = UDim2.new(0.5, -3, 1, 0)
		UiKit.SetEnabled(bulk, balance >= egg.price * BULK_COUNT)
		bulk.Activated:Connect(function()
			send("BuyEgg", egg.key, BULK_COUNT)
		end)
	end

	-- Один питомец пула: силуэт до получения, полноценная строка после.
	local function renderPetRow(egg: Eggs.EggDef, def: Types.PetDef, order: number): ()
		local known = owned[def.key] == true
		local accent = if known then Palette.Element[def.element] else Palette.UI.background

		local row = UiKit.Row(list, order, accent)
		row.badge.Text = def.rarity
		row.badge.TextColor3 = if known then Palette.UI.background else Palette.UI.subtext

		if known then
			row.title.Text = def.displayName
			row.subtitle.Text = def.description
		else
			-- Силуэт: видно редкость и шанс, не видно кто это.
			row.title.Text = "???"
			row.title.TextColor3 = Palette.UI.subtext
			row.subtitle.Text = "Not hatched yet"
		end

		local chance = UiKit.Label(row.actions, "Chance", formatChance(petChance(egg, def)), 15, Palette.UI.text)
		chance.Font = Enum.Font.GothamBold
		chance.Size = UDim2.fromOffset(96, UiKit.ButtonHeight)
		chance.TextXAlignment = Enum.TextXAlignment.Right
	end

	-- Список всех яиц: строка на яйцо, нажатие открывает его страницу.
	local function renderEggList(): ()
		window.title.Text = "Eggs"
		window.subtitle.Text = "Pick an egg to see everything it can hatch."

		for order, egg in Eggs.List do
			local row = UiKit.Row(list, order, Color3.fromHex(egg.color))
			row.frame.Size = UDim2.new(1, -8, 0, UiKit.RowHeight + 10)
			row.badge.Text = if egg.currency == "essence" then "E" else "P"
			row.title.Text = `{egg.displayName}  ·  {UiKit.FormatAmount(egg.price)} {egg.currency}`
			row.subtitle.Text = chanceText(egg)

			local open = UiKit.Button(row.actions, "Open", "Open")
			open.LayoutOrder = 1
			open.Size = UDim2.fromOffset(104, UiKit.ButtonHeight)
			open.Activated:Connect(function()
				currentEgg = egg.key
				render()
			end)
		end
	end

	--[[
		Страница яйца. Питомцы отсортированы от лучшей редкости к худшей:
		игрок открывает яйцо ради верхних строк, и прятать их под двенадцатью
		обычными незачем.
	]]
	local function renderEggPage(egg: Eggs.EggDef): ()
		window.title.Text = egg.displayName
		window.subtitle.Text = "Everything this egg can hatch. Duplicates turn into pet experience."

		renderEggHeader(egg)

		local order = 1
		for index = #Pets.Rarities, 1, -1 do
			local rarity = Pets.Rarities[index]
			if Eggs.Chance(egg, rarity) > 0 then
				for _, def in Pets.ByRarity[rarity] do
					order += 1
					renderPetRow(egg, def, order)
				end
			end
		end
	end

	render = function(): ()
		UiKit.ClearList(list)

		local key = currentEgg
		local egg = if key then Eggs.ByKey[key] else nil
		if egg then
			renderEggPage(egg)
		else
			renderEggList()
		end
	end

	local panel: Panel = {
		Open = function(eggKey: string?)
			window.screen.Enabled = true
			-- Промпт у конкретного яйца открывает именно его страницу:
			-- игрок подошёл к нему, а не к «яйцам вообще».
			currentEgg = eggKey
			render()
		end,

		Close = function()
			window.screen.Enabled = false
		end,

		Refresh = function(essence: number, prisms: number, petsView: Types.PetsView?)
			essenceBalance = essence
			prismsBalance = prisms

			table.clear(owned)
			if petsView then
				for _, pet in petsView.pets do
					owned[pet.petId] = true
				end
			end

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
					-- Дубликат — отдельный питомец под эволюцию, и игрок должен
					-- видеть, сколько таких у него теперь.
					table.insert(parts, `{name} [{rarity}] — duplicate, {result.owned} owned`)
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
