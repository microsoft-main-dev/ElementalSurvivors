--!strict
--[[
	InventoryPanel — один инвентарь на все виды имущества игрока.

	Раньше это были три отдельные кнопки лобби и два списка строк. Списки
	заменены классической сеткой ячеек: предмет — это квадрат с иконкой,
	а не строка с текстом и кнопкой. Кнопки действий из строк переехали вниз,
	в область подробностей, и существуют в одном экземпляре: в сетке из сорока
	ячеек сорок кнопок «Equip» — это не интерфейс, а стена.

	Три раздела:
		Pets   — коллекция питомцев (экипировка, уровень, вход в эволюцию);
		Gear   — снаряжение, плюс ряд надетого над сеткой;
		Boosts — бустеры и заряды (M7). Только показ: заряды тратятся сами
		         в конце забега, а бустеры идут по времени.

	Ни одно число здесь не считается: сила, цены и остатки приходят готовыми
	с сервера. Клиент не должен уметь предсказывать цену — иначе он однажды
	покажет одну, а сервер спишет другую.

	Публичный API:
		InventoryPanel.Build(parent, send, onEvolve) -> Panel
		panel.Open(section?)
		panel.Close()
		panel.Refresh(pets, items, store, essence)
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local ItemIcon = require(script.Parent.ItemIcon)
local Items = require(Shared.Config.Items)
local Palette = require(Shared.Config.Palette)
local PetIcon = require(script.Parent.PetIcon)
local Pets = require(Shared.Config.Pets)
local Types = require(Shared.Types)
local UiKit = require(script.Parent.UiKit)

export type Panel = {
	Open: (section: string?) -> (),
	Close: () -> (),
	Refresh: (pets: Types.PetsView?, items: Types.ItemsView?, store: Types.StoreView?, essence: number) -> (),
}

local InventoryPanel = {}

--[[
	Имена разделов совпадают с именами, которыми панель открывают снаружи
	(промпт у стенда питомцев шлёт «Pets», обучение — «Items»). Одна строка
	на раздел и на алиас: два имени для одного раздела разъехались бы.
]]
InventoryPanel.Sections = table.freeze({ "Pets", "Gear", "Boosts" })

local SECTION_BY_ALIAS: { [string]: string } = {
	Pets = "Pets",
	Items = "Gear",
	Gear = "Gear",
	Boosts = "Boosts",
}

local DETAIL_HEIGHT = 116
local DETAIL_WIDTH = 240
local CONTROLS_HEIGHT = 36
local EQUIPPED_SIZE = 62
local EQUIPPED_HEIGHT = 82
local ICON_SIZE = 52
local MIN_SLOTS = 24 -- сколько ячеек рисуется, даже если инвентарь пуст

--[[
	С какой ширины подробности переезжают вправо колонкой.

	Дело не в красоте, а в высоте: телефон в альбомной ориентации даёт окну
	около 260 точек, и ярусы вкладки + сортировка + надетое + подробности
	съедают их целиком, не оставив сетке ни одной строки. Зато ширины там
	с избытком — туда подробности и уходят.
]]
local WIDE_CONTENT = 620

-- Кнопки в колонке подробностей: две в ряд, максимум три штуки — значит два ряда.
local WIDE_BUTTON_WIDTH = 108
local WIDE_BUTTON_HEIGHT = 34
local WIDE_ACTIONS_HEIGHT = WIDE_BUTTON_HEIGHT * 2 + 6

-- Критерии сортировки питомцев. Порядок кнопок — этот же.
local PET_SORTS = table.freeze({ "Type", "Rarity", "Power", "Stars" })

--[[
	Подвкладки снаряжения. «All» первым, потому что с него начинают; дальше
	порядок слотов из конфига, чтобы он совпадал с рядом надетого над сеткой.
]]
local GEAR_ALL = "All"

-- Редкость числом: и у питомцев, и у предметов она задана порядком в конфиге,
-- а сравнивать надо числа.
local PET_RARITY_RANK: { [string]: number } = {}
for index, rarity in Pets.Rarities do
	PET_RARITY_RANK[rarity] = index
end

local ITEM_RARITY_RANK: { [string]: number } = {}
for index, def in Items.Rarities do
	ITEM_RARITY_RANK[def.key] = index
end

-- «+12.4 health · +3% damage» — характеристики предмета строкой, как выпали.
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

--[[
	Сравнение по одному числу с общим правилом ничьих: сначала сила, потом uid.

	Сила вторым ключом не для красоты: при сортировке по виду или редкости
	внутри группы игрок ждёт сильных сверху. uid третьим — чтобы порядок равных
	не зависел от реализации table.sort и не прыгал между перерисовками.
]]
local function compare(
	rankA: number,
	rankB: number,
	powerA: number,
	powerB: number,
	uidA: string,
	uidB: string,
	desc: boolean
): boolean
	if rankA ~= rankB then
		return if desc then rankA > rankB else rankA < rankB
	end
	if powerA ~= powerB then
		return powerA > powerB
	end
	return uidA < uidB
end

function InventoryPanel.Build(
	parent: Instance,
	send: (action: string, target: string?, extra: unknown) -> (),
	onEvolve: (uid: string) -> ()
): Panel
	local window = UiKit.Window(parent, "InventoryPanel", "Inventory")
	--[[
		Окно шире и выше стандартного: у него, в отличие от остальных, три яруса
		(вкладки, сетка, подробности), и на телефоне в альбомной ориентации
		обычные 0.82 высоты оставляли сетке одну неполную строку.
	]]
	window.panel.Size = UDim2.fromScale(0.94, 0.92)

	local petsView: Types.PetsView? = nil
	local itemsView: Types.ItemsView? = nil
	local storeView: Types.StoreView? = nil
	local essenceBalance = 0

	--[[
		Выделение своё у каждого раздела: переключил вкладку, вернулся —
		выбранный предмет остался тем же. Одно поле на всех означало бы,
		что выбор питомца стирается заходом в снаряжение.
	]]
	local selected: { [string]: string? } = {}

	--[[
		Порядок показа. По умолчанию «сильные сверху» — тот же порядок, в котором
		коллекция приходит с сервера, чтобы включение сортировки ничего
		не перетасовало на пустом месте.
	]]
	local petSortKey = "Power"
	local petSortDesc = true
	local gearSortDesc = true
	local gearSlot = GEAR_ALL

	local render: () -> ()

	local tabs = UiKit.Tabs(window.content, InventoryPanel.Sections, function()
		render()
	end)

	-- Строка сортировки: критерии у питомцев, подвкладки слотов у снаряжения.
	-- Содержимое своё у каждого раздела, поэтому строится заново в render.
	local controls = UiKit.Frame(window.content, "Controls")
	controls.Size = UDim2.new(1, 0, 0, CONTROLS_HEIGHT)

	local controlsLayout = Instance.new("UIListLayout")
	controlsLayout.FillDirection = Enum.FillDirection.Horizontal
	controlsLayout.VerticalAlignment = Enum.VerticalAlignment.Center
	controlsLayout.SortOrder = Enum.SortOrder.LayoutOrder
	controlsLayout.Padding = UDim.new(0, 6)
	controlsLayout.Parent = controls

	-- Ряд надетого снаряжения. Живёт только во вкладке Gear, поэтому прячется,
	-- а не пересоздаётся: четыре слота — это четыре слота всегда.
	local equippedRow = UiKit.Frame(window.content, "Equipped")
	equippedRow.Size = UDim2.new(1, 0, 0, EQUIPPED_HEIGHT)

	local equippedLayout = Instance.new("UIListLayout")
	equippedLayout.FillDirection = Enum.FillDirection.Horizontal
	equippedLayout.HorizontalAlignment = Enum.HorizontalAlignment.Center
	equippedLayout.SortOrder = Enum.SortOrder.LayoutOrder
	equippedLayout.Padding = UDim.new(0, UiKit.SlotGap)
	equippedLayout.Parent = equippedRow

	local grid = UiKit.Grid(window.content, "Grid", UiKit.SlotSize, UiKit.SlotHeight)

	--[[
		Подробности выбранного: иконка, название, характеристики и ЕДИНСТВЕННЫЙ
		набор кнопок действия на всё окно.
	]]
	local detail = UiKit.Frame(window.content, "Detail", Palette.UI.background)
	detail.AnchorPoint = Vector2.new(0, 1)
	detail.Position = UDim2.fromScale(0, 1)
	detail.Size = UDim2.new(1, 0, 0, DETAIL_HEIGHT)
	detail.BackgroundTransparency = 0.3
	UiKit.Corners(detail, 8)

	local detailIcon = UiKit.Frame(detail, "Icon")
	detailIcon.Position = UDim2.fromOffset(10, 10)
	detailIcon.Size = UDim2.fromOffset(64, 80)

	local detailTitle = UiKit.Label(detail, "Title", "", 18)
	detailTitle.Font = Enum.Font.GothamBold
	detailTitle.RichText = true
	detailTitle.Position = UDim2.fromOffset(86, 12)
	detailTitle.Size = UDim2.new(1, -96, 0, 24)

	local detailText = UiKit.Label(detail, "Text", "", 13, Palette.UI.subtext)
	detailText.Position = UDim2.fromOffset(86, 38)
	-- Ровно до кнопок и ни пикселем ниже: характеристики легендарного предмета
	-- занимают две строки, и третья заехала бы под них.
	detailText.Size = UDim2.new(1, -96, 0, 26)
	detailText.TextWrapped = true
	detailText.TextTruncate = Enum.TextTruncate.None

	local actions = UiKit.Frame(detail, "Actions")
	actions.AnchorPoint = Vector2.new(0, 1)
	actions.Position = UDim2.new(0, 86, 1, -8)
	actions.Size = UDim2.new(1, -96, 0, UiKit.ButtonHeight - 8)

	local actionsLayout = Instance.new("UIListLayout")
	actionsLayout.FillDirection = Enum.FillDirection.Horizontal
	actionsLayout.SortOrder = Enum.SortOrder.LayoutOrder
	actionsLayout.Padding = UDim.new(0, 6)
	actionsLayout.Parent = actions

	local function clearChildren(holder: Instance): ()
		for _, child in holder:GetChildren() do
			if not child:IsA("UIGridLayout") and not child:IsA("UIListLayout") then
				child:Destroy()
			end
		end
	end

	--[[
		Широкая раскладка или узкая. Считается по фактической ширине содержимого,
		а не по «телефон или нет»: поворот экрана меняет её на лету, и никакого
		списка устройств для этого знать не нужно.

		AbsoluteSize у ещё ни разу не показанного окна равен нулю — на этот
		случай откат на вьюпорт, иначе первое открытие всегда было бы узким.
	]]
	local wideLayout = false

	local function isWide(): boolean
		local width = window.content.AbsoluteSize.X
		if width <= 0 then
			local camera = Workspace.CurrentCamera
			width = if camera then camera.ViewportSize.X * 0.9 else 1000
		end
		return width >= WIDE_CONTENT
	end

	--[[
		Кнопка действия. Размер зависит от раскладки: в колонке справа кнопки
		идут столбиком во всю её ширину, в полосе снизу — в ряд своей ширины.
		Одно место, где это решается, — иначе три вызывающих обязаны помнить
		про обе раскладки.
	]]
	local function actionButton(name: string, text: string, color: Color3?, width: number): TextButton
		local button = UiKit.Button(actions, name, text, color)
		button.Size = if wideLayout
			then UDim2.fromOffset(WIDE_BUTTON_WIDTH, WIDE_BUTTON_HEIGHT)
			else UDim2.fromOffset(width, UiKit.ButtonHeight - 8)
		return button
	end

	-- Подробности: колонкой справа на широком экране, полосой снизу на узком.
	local function layoutDetail(): ()
		local top = UiKit.TabHeight + 8

		if wideLayout then
			detail.AnchorPoint = Vector2.new(1, 0)
			detail.Position = UDim2.new(1, 0, 0, top)
			detail.Size = UDim2.new(0, DETAIL_WIDTH, 1, -top)

			detailIcon.AnchorPoint = Vector2.zero
			detailIcon.Position = UDim2.fromOffset(8, 8)

			detailTitle.Position = UDim2.fromOffset(76, 12)
			detailTitle.Size = UDim2.new(1, -84, 0, 24)
			detailTitle.TextXAlignment = Enum.TextXAlignment.Left

			--[[
				Высота текста считается от высоты колонки, а не числом: в альбомной
				ориентации телефона колонке достаётся вдвое меньше места, чем
				на десктопе, и фиксированная высота там залезла бы на кнопки.
			]]
			detailText.Position = UDim2.fromOffset(76, 40)
			detailText.Size = UDim2.new(1, -84, 1, -(40 + WIDE_ACTIONS_HEIGHT + 16))
			detailText.TextXAlignment = Enum.TextXAlignment.Left

			actions.AnchorPoint = Vector2.new(0.5, 1)
			actions.Position = UDim2.new(0.5, 0, 1, -8)
			actions.Size = UDim2.new(1, -16, 0, WIDE_ACTIONS_HEIGHT)
			actionsLayout.FillDirection = Enum.FillDirection.Horizontal
			--[[
				Кнопки переносятся по две в ряд, а не идут столбиком: столбик
				из трёх занимает половину колонки, и на коротком экране
				характеристикам не остаётся ни строки.
			]]
			actionsLayout.Wraps = true
			actionsLayout.HorizontalAlignment = Enum.HorizontalAlignment.Center
		else
			detail.AnchorPoint = Vector2.new(0, 1)
			detail.Position = UDim2.fromScale(0, 1)
			detail.Size = UDim2.new(1, 0, 0, DETAIL_HEIGHT)

			detailIcon.AnchorPoint = Vector2.zero
			detailIcon.Position = UDim2.fromOffset(10, 10)

			detailTitle.Position = UDim2.fromOffset(86, 12)
			detailTitle.Size = UDim2.new(1, -96, 0, 24)
			detailTitle.TextXAlignment = Enum.TextXAlignment.Left

			detailText.Position = UDim2.fromOffset(86, 38)
			detailText.Size = UDim2.new(1, -96, 0, 26)
			detailText.TextXAlignment = Enum.TextXAlignment.Left

			actions.AnchorPoint = Vector2.new(0, 1)
			actions.Position = UDim2.new(0, 86, 1, -8)
			actions.Size = UDim2.new(1, -96, 0, UiKit.ButtonHeight - 8)
			actionsLayout.FillDirection = Enum.FillDirection.Horizontal
			actionsLayout.Wraps = false
			actionsLayout.HorizontalAlignment = Enum.HorizontalAlignment.Left
		end
	end

	local function findPet(uid: string): Types.PetView?
		local view = petsView
		if view then
			for _, pet in view.pets do
				if pet.uid == uid then
					return pet
				end
			end
		end
		return nil
	end

	local function findItem(uid: string): Types.ItemView?
		local view = itemsView
		if view then
			for _, item in view.items do
				if item.uid == uid then
					return item
				end
			end
		end
		return nil
	end

	--[[
		Ячейка сетки: рамка, иконка и подпись под ней. Всё, что различается
		между разделами, приходит параметрами — иначе получилось бы три почти
		одинаковых вёрстки, которые разъедутся при первой же правке.
	]]
	local function buildCell(order: number, caption: string, captionColor: Color3, highlight: Color3?): TextButton
		local cell = UiKit.Slot(grid, `Cell{order}`, order)

		local border = cell:FindFirstChild("Border")
		if highlight and border and border:IsA("UIStroke") then
			border.Color = highlight
			border.Thickness = 3
		end

		if caption ~= "" then
			local label = UiKit.Label(cell, "Caption", caption, 12, captionColor)
			label.AnchorPoint = Vector2.new(0.5, 1)
			label.Position = UDim2.new(0.5, 0, 1, -4)
			label.Size = UDim2.new(1, -6, 0, 14)
			label.TextXAlignment = Enum.TextXAlignment.Center
			label.RichText = true
		end

		return cell
	end

	-- Цвет рамки ячейки: выделенная важнее надетой, иначе выбранный надетый
	-- предмет ничем не отличался бы от просто надетого.
	local function borderColor(isSelected: boolean, isEquipped: boolean): Color3?
		if isSelected then
			return Palette.UI.text
		end
		if isEquipped then
			return Palette.UI.accent
		end
		return nil
	end

	local function choose(section: string, uid: string): ()
		selected[section] = uid
		render()
	end

	--[[
		=== ПОДРОБНОСТИ ===
	]]
	local function renderPetDetail(pet: Types.PetView): ()
		local def = Pets.ByKey[pet.petId]
		local name = if def then def.displayName else pet.petId

		PetIcon.Pet(detailIcon, "Icon", pet.petId, pet.stars, 56)

		detailTitle.Text = `{name}  ·  Lv {pet.level}  ·  {PetIcon.StarsMarkup(pet.stars)}`

		local progress = if pet.xpToNext > 0 then `{pet.xp}/{pet.xp + pet.xpToNext} xp` else "max level"
		local starBonus = if pet.starMult > 1 then `  ·  stars x{string.format("%.1f", pet.starMult)}` else ""
		local element = if def then def.element else "?"
		detailText.Text = `{element}  ·  power {string.format("%.1f", pet.power)}  ·  {progress}{starBonus}`

		if pet.equipped then
			local mark = actionButton("Equipped", "Equipped", Palette.UI.panel, 84)
			mark.LayoutOrder = 1
			UiKit.SetEnabled(mark, false)
		else
			local equip = actionButton("Equip", "Equip", nil, 84)
			equip.LayoutOrder = 1
			equip.Activated:Connect(function()
				send("EquipPet", pet.uid, nil)
			end)
		end

		local upgrade = actionButton("Upgrade", "Max", Palette.UI.panel, 104)
		upgrade.LayoutOrder = 2
		if pet.upgradeCost > 0 then
			upgrade.Text = `Lv+ {UiKit.FormatAmount(pet.upgradeCost)}`
			UiKit.SetEnabled(upgrade, essenceBalance >= pet.upgradeCost)
			upgrade.Activated:Connect(function()
				send("UpgradePet", pet.uid, nil)
			end)
		else
			UiKit.SetEnabled(upgrade, false)
		end

		--[[
			Эволюция открывает своё меню, а не эволюционирует сразу: состав
			ступени — это до семи иконок со своими звёздами, и в подпись
			кнопки он не помещается.
		]]
		local recipe = pet.evolve
		local ready = recipe ~= nil and recipe.ready
		local evolve = actionButton("Evolve", "Evolve", if ready then Palette.UI.accent else Palette.UI.panel, 96)
		evolve.LayoutOrder = 3
		if recipe then
			evolve.Activated:Connect(function()
				onEvolve(pet.uid)
			end)
		else
			evolve.Text = "Max star"
			UiKit.SetEnabled(evolve, false)
		end
	end

	local function renderItemDetail(item: Types.ItemView): ()
		ItemIcon.Build(detailIcon, "Icon", item.slot, item.rarity, 56)

		local color = ItemIcon.RarityColor(item.rarity):ToHex()
		detailTitle.Text = `<font color="#{color}">{item.rarity}</font> {item.slot}  ·  power {math.floor(item.power)}`
		detailText.Text = statsText(item.stats)

		local equip = actionButton(
			"Equip",
			if item.equipped then "Unequip" else "Equip",
			if item.equipped then Palette.UI.panel else Palette.UI.accent,
			104
		)
		equip.LayoutOrder = 1
		equip.Activated:Connect(function()
			send("EquipItem", item.uid, nil)
		end)
	end

	local function renderEmptyDetail(section: string): ()
		detailTitle.Text = "Nothing selected"
		detailText.Text = if section == "Boosts"
			then "Boosters multiply Essence only. Charges are spent at the end of a run."
			else "Tap an item to see what it does."
	end

	--[[
		=== СОРТИРОВКА ===

		Порядок только отображательный: сравниваются поля, которые УЖЕ пришли
		в срезе. Сила питомца здесь не считается заново — её считает сервер,
		и второго способа посчитать её в проекте нет.
	]]
	local function petRank(pet: Types.PetView): number
		local def = Pets.ByKey[pet.petId]

		if petSortKey == "Type" then
			-- typeId — порядок записи в конфиге: одинаковые виды встают рядом,
			-- а поскольку таблица идёт от B к SSS, заодно группируются редкости.
			return if def then def.typeId else 0
		elseif petSortKey == "Rarity" then
			return if def then PET_RARITY_RANK[def.rarity] or 0 else 0
		elseif petSortKey == "Stars" then
			return pet.stars
		end

		return pet.power
	end

	local function sortedPets(list: { Types.PetView }): { Types.PetView }
		local copy = table.clone(list)
		table.sort(copy, function(a: Types.PetView, b: Types.PetView): boolean
			return compare(petRank(a), petRank(b), a.power, b.power, a.uid, b.uid, petSortDesc)
		end)
		return copy
	end

	local function sortedItems(list: { Types.ItemView }): { Types.ItemView }
		local copy: { Types.ItemView } = {}
		for _, item in list do
			-- Подвкладка фильтрует до сортировки: сортировать то, что не покажем,
			-- незачем, а порядок внутри слота от этого не зависит.
			if gearSlot == GEAR_ALL or item.slot == gearSlot then
				table.insert(copy, item)
			end
		end

		table.sort(copy, function(a: Types.ItemView, b: Types.ItemView): boolean
			local rankA = ITEM_RARITY_RANK[a.rarity] or 0
			local rankB = ITEM_RARITY_RANK[b.rarity] or 0
			return compare(rankA, rankB, a.power, b.power, a.uid, b.uid, gearSortDesc)
		end)
		return copy
	end

	-- Стрелка направления на активном чипе. У неактивного её нет: четыре стрелки
	-- в ряд означали бы, что сортировок четыре одновременно.
	local function arrow(desc: boolean): string
		return if desc then " ▼" else " ▲"
	end

	local function buildPetControls(): ()
		for order, key in PET_SORTS do
			local active = key == petSortKey
			local chip = UiKit.Chip(controls, key, if active then key .. arrow(petSortDesc) else key, 68, active)
			chip.LayoutOrder = order
			chip.Activated:Connect(function()
				if petSortKey == key then
					-- Повторное нажатие переворачивает порядок: отдельная кнопка
					-- направления удвоила бы строку ради одного бита.
					petSortDesc = not petSortDesc
				else
					petSortKey = key
					petSortDesc = true
				end
				render()
			end)
		end
	end

	local function buildGearControls(): ()
		local order = 0

		local function slotChip(name: string): ()
			order += 1
			local chip = UiKit.Chip(controls, name, name, 54, name == gearSlot)
			chip.LayoutOrder = order
			chip.Activated:Connect(function()
				gearSlot = name
				render()
			end)
		end

		slotChip(GEAR_ALL)
		for _, slot in Items.Slots do
			slotChip(slot)
		end

		--[[
			Сортировка у снаряжения одна — по редкости, поэтому чип не выбирает
			критерий, а только переворачивает порядок. Внутри редкости предметы
			идут по силе (см. compare): «эпический с лучшими характеристиками»
			и есть то, что ищут в этом списке.
		]]
		order += 1
		local sort = UiKit.Chip(controls, "Sort", `Rarity{arrow(gearSortDesc)}`, 76, true)
		sort.LayoutOrder = order
		sort.Activated:Connect(function()
			gearSortDesc = not gearSortDesc
			render()
		end)
	end

	--[[
		=== РАЗДЕЛЫ ===
	]]
	local function renderPets(): number
		local view = petsView
		local chosen = selected.Pets

		window.subtitle.Text = if view
			then string.format(
				"%d pets  ·  collection power %.1f  ·  expeditions %d Essence/h",
				#view.pets,
				view.collectionPower,
				math.floor(view.offlineRatePerHour)
			)
			else "Loading..."

		local count = 0
		if view then
			for order, pet in sortedPets(view.pets) do
				count += 1
				local caption = `Lv {pet.level}`
				local cell = buildCell(order, caption, Palette.UI.subtext, borderColor(pet.uid == chosen, pet.equipped))

				local icon = PetIcon.Pet(cell, "Icon", pet.petId, pet.stars, ICON_SIZE)
				icon.frame.AnchorPoint = Vector2.new(0.5, 0)
				icon.frame.Position = UDim2.new(0.5, 0, 0, 5)

				cell.Activated:Connect(function()
					choose("Pets", pet.uid)
				end)
			end
		end

		return count
	end

	local function renderGear(): number
		local view = itemsView
		local chosen = selected.Gear

		--[[
			Ряд надетого строится по списку слотов, а не по надетым предметам:
			пустой слот обязан быть виден, иначе «у меня ничего нет в ногах»
			выглядит как «слота для ног не существует».
		]]
		clearChildren(equippedRow)
		equippedRow.Visible = true

		for order, slot in Items.Slots do
			local holder = UiKit.Frame(equippedRow, `Slot{slot}`)
			holder.LayoutOrder = order
			holder.Size = UDim2.fromOffset(EQUIPPED_SIZE, EQUIPPED_HEIGHT)

			local box = UiKit.Slot(holder, "Box", order)
			box.Size = UDim2.fromOffset(EQUIPPED_SIZE, EQUIPPED_SIZE)

			local uid = if view then view.equipped[slot] else nil
			local item = if uid then findItem(uid) else nil
			if item then
				ItemIcon.Build(box, "Icon", item.slot, item.rarity, EQUIPPED_SIZE - 14)
				box.Activated:Connect(function()
					choose("Gear", item.uid)
				end)
			end

			local label = UiKit.Label(holder, "Name", slot, 11, Palette.UI.subtext)
			label.Position = UDim2.fromOffset(0, EQUIPPED_SIZE + 2)
			label.Size = UDim2.new(1, 0, 0, 14)
			label.TextXAlignment = Enum.TextXAlignment.Center
		end

		local equippedCount = 0
		if view then
			for _ in view.equipped do
				equippedCount += 1
			end
		end

		local shown = if view then sortedItems(view.items) else {}
		local total = if view then #view.items else 0

		--[[
			Показано из всего: подвкладка прячет часть инвентаря, и без этого
			числа «у меня было восемь предметов, стало два» читается как потеря,
			а не как фильтр.
		]]
		local filter = if gearSlot == GEAR_ALL then "" else `  ·  {#shown} {gearSlot}`
		window.subtitle.Text = `{total} items  ·  {equippedCount} of {#Items.Slots} slots filled{filter}`

		local count = 0
		if view then
			for order, item in shown do
				count += 1
				local color = ItemIcon.RarityColor(item.rarity)
				local cell = buildCell(order, item.slot, color, borderColor(item.uid == chosen, item.equipped))

				local icon = ItemIcon.Build(cell, "Icon", item.slot, item.rarity, ICON_SIZE)
				icon.frame.AnchorPoint = Vector2.new(0.5, 0)
				icon.frame.Position = UDim2.new(0.5, 0, 0, 8)

				cell.Activated:Connect(function()
					choose("Gear", item.uid)
				end)
			end
		end

		return count
	end

	--[[
		Расходники: бустеры (идут по времени) и заряды (штуки). Оба приходят
		в StoreView — это тот же срез, по которому рисуется витрина, поэтому
		вкладка не может разойтись с магазином.
	]]
	local function renderBoosts(): number
		local view = storeView
		local chosen = selected.Boosts
		local mult = if view then view.essenceMult else 1

		window.subtitle.Text = if mult > 1
			then `Essence x{string.format("%.10g", mult)} while boosters last`
			else "No boosters running. Charges are spent at the end of a run."

		local order = 0
		if view then
			--[[
				Бустер и заряд — разные вещи с одинаковым ключом («x2» бывает
				и тем, и другим), поэтому выделение хранит вид вместе с ключом.
			]]
			for _, boost in view.boosts do
				order += 1
				local uid = `boost:{boost.key}`
				local cell = buildCell(
					order,
					UiKit.FormatDuration(boost.secondsLeft),
					Palette.UI.accent,
					borderColor(uid == chosen, false)
				)

				local icon = ItemIcon.Consumable(cell, "Icon", ICON_SIZE)
				icon.frame.AnchorPoint = Vector2.new(0.5, 0)
				icon.frame.Position = UDim2.new(0.5, 0, 0, 8)

				cell.Activated:Connect(function()
					choose("Boosts", uid)
				end)
			end

			for _, charge in view.charges do
				order += 1
				local uid = `charge:{charge.key}`
				local cell = buildCell(order, `x{charge.count}`, Palette.UI.text, borderColor(uid == chosen, false))

				local icon = ItemIcon.Consumable(cell, "Icon", ICON_SIZE)
				icon.frame.AnchorPoint = Vector2.new(0.5, 0)
				icon.frame.Position = UDim2.new(0.5, 0, 0, 8)

				cell.Activated:Connect(function()
					choose("Boosts", uid)
				end)
			end
		end

		return order
	end

	--[[
		Подробности расходника. Ищется по тому же ключу, которым выделен, —
		иначе выбранный бустер «терялся» бы при каждом обновлении витрины.
	]]
	local function renderBoostDetail(uid: string): boolean
		local view = storeView
		if not view then
			return false
		end

		for _, boost in view.boosts do
			if uid == `boost:{boost.key}` then
				ItemIcon.Consumable(detailIcon, "Icon", 56)
				detailTitle.Text = boost.displayName
				detailText.Text =
					`Running for {UiKit.FormatDuration(boost.secondsLeft)} more. Boosters multiply Essence only.`
				return true
			end
		end

		for _, charge in view.charges do
			if uid == `charge:{charge.key}` then
				ItemIcon.Consumable(detailIcon, "Icon", 56)
				detailTitle.Text = charge.displayName
				detailText.Text = `{charge.count} left. One is spent automatically at the end of a run.`
				return true
			end
		end

		return false
	end

	render = function(): ()
		clearChildren(grid)
		clearChildren(actions)
		clearChildren(detailIcon)
		clearChildren(controls)

		local section = tabs.Current()

		wideLayout = isWide()
		layoutDetail()

		--[[
			Ярусы складываются сверху вниз одним счётчиком: строка сортировки
			есть не у всех разделов, ряд надетого — только у снаряжения, и сетка
			занимает то, что осталось. Считать её положение в двух местах значило
			бы однажды забыть одно из них.
		]]
		local gridTop = UiKit.TabHeight + 8

		--[[
			Всё, что стоит над сеткой, обязано ужаться вместе с ней: в широкой
			раскладке правую четверть окна занимают подробности, и ряд надетого,
			выровненный по центру полной ширины, уехал бы под них.
		]]
		local bandWidth = if wideLayout then -DETAIL_WIDTH - 8 else 0
		controls.Size = UDim2.new(1, bandWidth, 0, CONTROLS_HEIGHT)
		equippedRow.Size = UDim2.new(1, bandWidth, 0, EQUIPPED_HEIGHT)

		controls.Visible = section ~= "Boosts"
		if controls.Visible then
			controls.Position = UDim2.fromOffset(0, gridTop)
			if section == "Pets" then
				buildPetControls()
			else
				buildGearControls()
			end
			gridTop += CONTROLS_HEIGHT + 8
		end

		if section == "Gear" then
			equippedRow.Position = UDim2.fromOffset(0, gridTop)
			gridTop += EQUIPPED_HEIGHT + 8
		else
			equippedRow.Visible = false
		end

		grid.Position = UDim2.fromOffset(0, gridTop)
		grid.Size = if wideLayout
			then UDim2.new(1, -DETAIL_WIDTH - 8, 1, -gridTop)
			else UDim2.new(1, 0, 1, -gridTop - DETAIL_HEIGHT - 8)

		local filled = if section == "Pets"
			then renderPets()
			elseif section == "Gear" then renderGear()
			else renderBoosts()

		--[[
			Пустые ячейки до минимума: инвентарь с тремя предметами обязан
			выглядеть как инвентарь, а не как список из трёх строк. Это и есть
			разница между сеткой и списком, ради которой всё затевалось.
		]]
		for index = filled + 1, MIN_SLOTS do
			local cell = UiKit.Slot(grid, `Empty{index}`, index)
			cell.BackgroundTransparency = 0.55
		end

		local chosen = selected[section]
		if section == "Pets" then
			local pet = if chosen then findPet(chosen) else nil
			if pet then
				renderPetDetail(pet)
			else
				renderEmptyDetail(section)
			end
		elseif section == "Gear" then
			local item = if chosen then findItem(chosen) else nil
			if item then
				renderItemDetail(item)
			else
				renderEmptyDetail(section)
			end
		elseif not (chosen ~= nil and renderBoostDetail(chosen)) then
			renderEmptyDetail(section)
		end
	end

	--[[
		Поворот телефона меняет раскладку сам. Перерисовка не меняет размер
		содержимого (он от панели, а не от детей), поэтому зациклиться здесь
		нечему.
	]]
	window.content:GetPropertyChangedSignal("AbsoluteSize"):Connect(function()
		if window.screen.Enabled and isWide() ~= wideLayout then
			render()
		end
	end)

	local panel: Panel = {
		Open = function(section: string?)
			--[[
				Раздел приходит снаружи под своим внешним именем: промпт у стенда
				питомцев шлёт «Pets», обучение — «Items». Разворачивается он
				здесь, чтобы у вызывающих не заводилось знание о вкладках.
			]]
			local wanted = if section then SECTION_BY_ALIAS[section] else nil
			window.screen.Enabled = true
			tabs.Select(wanted or tabs.Current())
		end,

		Close = function()
			window.screen.Enabled = false
		end,

		Refresh = function(pets: Types.PetsView?, items: Types.ItemsView?, store: Types.StoreView?, essence: number)
			petsView = pets
			itemsView = items
			storeView = store
			essenceBalance = essence

			--[[
				Перерисовка только при открытом окне: срезы приходят после каждой
				покупки, а перестраивать невидимую сетку — работа впустую.
			]]
			if window.screen.Enabled then
				render()
			end
		end,
	}

	return panel
end

return InventoryPanel
