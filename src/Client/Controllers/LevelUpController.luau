--!strict
--[[
	LevelUpController — экран выбора при левел-апе (раздел 3.6 и 8 ТЗ).

	Это единственный момент, когда игрок в бою что-то решает, и единственное
	место во всём клиенте, которое что-то отправляет на сервер. Отправляется
	только номер карточки: сервер сам знает, какие три он предложил, и берёт
	эффект из своей копии, а не из присланных данных.

	Бой на это время стоит на паузе — её ставит сервер, клиент лишь показывает
	карточки. Даже если игрок ничего не нажмёт, сервер через таймаут выберет
	первую и снимет паузу: зависшая арена недопустима.

	Карточки крупные и разнесены: попадание пальцем важнее плотности.

	ЗДЕСЬ ЖЕ ЖИВЁТ РЕДКОСТЬ ВЗЯТОГО. Способность копит множители за забег,
	и по её уровню редкость карточек уже не восстановить — а показать её
	хочется и в бою (цвет ядра эффекта), и в HUD (кайма иконки). Клиент
	сам выбирает карточку, то есть знает это без единого лишнего пакета,
	и хранить знание правильнее там, где оно появляется.

	Публичный API:
		LevelUpController.BestRarity(abilityKey) -> string?
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Abilities = require(Shared.Config.Abilities)
local Cards = require(Shared.Config.Cards)
local Icons = require(Shared.Config.Icons)
local Net = require(Shared.Net)
local Palette = require(Shared.Config.Palette)
local SoundController = require(script.Parent.SoundController)
local Types = require(Shared.Types)
local UiKit = require(script.Parent.Parent.UI.UiKit)

type LevelUpCard = Types.LevelUpCard

--[[
	Отступ содержимого от края карточки: ровно под расширенный борт рамки,
	чтобы шапка не легла на него сверху.
]]
local CARD_INSET = 18

local LevelUpController = {}

local player = Players.LocalPlayer

--[[
	Ранг редкости по ключу: Cards.Rarities идут от частой к редкой, поэтому
	номер в списке и есть «насколько редка». Сравнивать ключи строками было бы
	сравнением ни с чем.
]]
local rarityRank: { [string]: number } = {}
for index, rarity in Cards.Rarities do
	rarityRank[rarity.key] = index
end

-- Лучшая редкость, взятая за этот забег по каждой способности.
local bestRarity: { [string]: string } = {}

-- Что сейчас предложено: нужно, чтобы по номеру выбора узнать редкость.
local offered: { LevelUpCard } = {}

local screen: ScreenGui? = nil
local cardRow: Frame? = nil
local titleLabel: TextLabel? = nil
local choiceRemote: RemoteEvent? = nil
local awaitingChoice = false

local function build(): ()
	local playerGui = player:WaitForChild("PlayerGui")

	local gui = Instance.new("ScreenGui")
	gui.Name = "LevelUp"
	gui.ResetOnSpawn = false
	gui.DisplayOrder = 400
	gui.IgnoreGuiInset = true
	gui.Enabled = false
	gui.Parent = playerGui
	screen = gui

	local backdrop = Instance.new("Frame")
	backdrop.Name = "Backdrop"
	backdrop.Size = UDim2.fromScale(1, 1)
	backdrop.BackgroundColor3 = Palette.UI.background
	backdrop.BackgroundTransparency = 0.35
	backdrop.BorderSizePixel = 0
	--[[
		Ввод дальше не идёт: выбор карточки — единственное решение игрока в бою,
		и мимо карточек нажиматься не должно ничего. Закрытия по клику мимо нет:
		карточку обязаны выбрать.
	]]
	backdrop.Active = true
	backdrop.Parent = gui

	local title = Instance.new("TextLabel")
	title.Name = "Title"
	title.AnchorPoint = Vector2.new(0.5, 0)
	title.Position = UDim2.fromScale(0.5, 0.08)
	title.Size = UDim2.fromScale(0.8, 0.09)
	title.BackgroundTransparency = 1
	title.Font = Enum.Font.GothamBold
	title.Text = "LEVEL UP"
	title.TextColor3 = Palette.UI.text
	title.TextScaled = true
	title.Parent = backdrop
	titleLabel = title

	local row = Instance.new("Frame")
	row.Name = "Cards"
	row.AnchorPoint = Vector2.new(0.5, 0.5)
	row.Position = UDim2.fromScale(0.5, 0.55)
	row.Size = UDim2.fromScale(0.92, 0.6)
	row.BackgroundTransparency = 1
	row.Parent = backdrop
	cardRow = row

	local layout = Instance.new("UIListLayout")
	layout.FillDirection = Enum.FillDirection.Horizontal
	layout.HorizontalAlignment = Enum.HorizontalAlignment.Center
	layout.VerticalAlignment = Enum.VerticalAlignment.Center
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Padding = UDim.new(0.02, 0)
	layout.Parent = row
end

local function hide(): ()
	awaitingChoice = false

	local gui = screen
	if gui then
		gui.Enabled = false
	end

	local row = cardRow
	if row then
		for _, child in row:GetChildren() do
			if child:IsA("TextButton") then
				child:Destroy()
			end
		end
	end
end

--[[
	Запомнить редкость взятого. Только вверх: способность копит множители,
	и одна обычная карточка поверх легендарной не отменяет легендарную.
]]
local function record(card: LevelUpCard?): ()
	if not card then
		return
	end

	local best = bestRarity[card.abilityKey]
	local rank = rarityRank[card.rarity] or 1
	if not best or rank > (rarityRank[best] or 1) then
		bestRarity[card.abilityKey] = card.rarity
	end
end

local function choose(index: number): ()
	if not awaitingChoice then
		return
	end
	awaitingChoice = false
	record(offered[index])
	SoundController.PlaySfx("CardChosen")

	local remote = choiceRemote
	if remote then
		remote:FireServer(index)
	end

	hide()
end

local function buildCard(card: LevelUpCard, index: number, total: number): ()
	local row = cardRow
	if not row then
		return
	end

	local def = Abilities.ByKey[card.abilityKey]
	local rarity = Cards.ByKey[card.rarity]
	local rarityColour = Cards.ColorFor(card.rarity)
	local rank = rarityRank[card.rarity] or 1

	local button = Instance.new("TextButton")
	button.Name = `Card{index}`
	button.LayoutOrder = index
	button.Size = UDim2.fromScale(0.94 / total, 1)
	button.BackgroundColor3 = Palette.UI.panel
	button.BorderSizePixel = 0
	button.AutoButtonColor = true
	button.Text = ""
	button.Parent = row

	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 12)
	corner.Parent = button

	--[[
		РЕДКОСТЬ КРАСИТ ВСЮ КАРТОЧКУ, А НЕ ПОДПИСЬ.

		Раньше шапка была цвета стихии, а редкость — только словом и толщиной
		контура. Разница между Common и Rare при этом не читалась вовсе: рядом
		стояли зелёная, голубая и сиреневая карточки, и цвет означал стихию,
		которую и так видно по значку и названию.

		Красится сам СКИН, а не подложка под ним: рамка карточки — та же
		рисованная рамка, что у окон, и ImageColor3 подмешивает к ней оттенок
		редкости, не ломая ни рисунка, ни фаски. Обычной достаётся чистый белый,
		то есть рамка без изменений; чем реже карточка, тем сильнее оттенок.
	]]
	local frame = UiKit.Skin(button, "FrameWindow")
	if frame then
		frame.ImageColor3 = if rank <= 1 then Color3.new(1, 1, 1) else rarityColour:Lerp(Color3.new(1, 1, 1), 0.55)
		--[[
			Рамка шире, чем у окон. SliceScale растягивает УГЛЫ, а не середину:
			у окна борт в двадцать два пикселя уместен, а карточка — самый
			крупный элемент боя, её смотрят издалека и мельком, и борт такой
			же толщины на ней теряется.

			Свой множитель, а не правка UiKit.SKIN: там числа измерены по самим
			файлам и общие на все окна игры.
		]]
		frame.SliceScale = 1.6
	end

	--[[
		Контур поверх рисованной рамки выглядит наклейкой на дереве, поэтому
		он остаётся только там, где скина нет вовсе (ассет не загрузился или
		снят модерацией) — иначе редкость перестала бы читаться совсем.
	]]
	if not frame then
		local stroke = Instance.new("UIStroke")
		stroke.Color = rarityColour
		stroke.Thickness = 2 + (rank - 1) * 2
		stroke.Parent = button
	end

	--[[
		Всё содержимое живёт внутри отступа от края.

		Подложка скина — потомок кнопки, и UIPadding на самой кнопке сдвинул бы
		и её тоже, то есть ужал бы рамку вместо того, чтобы отодвинуть от неё
		текст (эти грабли в проекте уже описаны). Поэтому отступ держит
		отдельная прозрачная рама, а рамка остаётся во всю карточку.
	]]
	local content = Instance.new("Frame")
	content.Name = "Content"
	content.BackgroundTransparency = 1
	content.Position = UDim2.fromOffset(CARD_INSET, CARD_INSET)
	content.Size = UDim2.new(1, -CARD_INSET * 2, 1, -CARD_INSET * 2)
	content.Parent = button

	local header = Instance.new("Frame")
	header.Size = UDim2.fromScale(1, 0.22)
	header.BackgroundColor3 = rarityColour
	header.BackgroundTransparency = 0.15
	header.BorderSizePixel = 0
	header.Parent = content

	--[[
		Шапка — та же полоса, которой нарисованы здоровье и опыт. Она почти
		белая и красится кодом, поэтому цвет редкости ложится на неё как есть,
		а рисунок остаётся рисованным.
	]]
	local headerSkin = UiKit.Skin(header, "BarFill")
	if headerSkin then
		headerSkin.ImageColor3 = rarityColour
	else
		local headerCorner = Instance.new("UICorner")
		headerCorner.CornerRadius = UDim.new(0, 12)
		headerCorner.Parent = header
	end

	--[[
		Иконка способности крупно, между шапкой и названием.

		В шапке она стояла раньше и там же терялась: шапка занимает 22% высоты
		карточки, значок получался с ноготь, и карточка по-прежнему читалась как
		прямоугольник с текстом. Здесь под неё отведена почти треть карточки —
		это самый частый экран выбора в игре, и решение принимают по картинке,
		а не по описанию.

		Квадрат держит контейнер: значок вписывается в него по меньшей стороне,
		поэтому пропорции не зависят ни от экрана, ни от числа карточек в ряду.
	]]
	local iconHolder = UiKit.Frame(content, "IconHolder")
	iconHolder.Position = UDim2.fromScale(0, 0.24)
	iconHolder.Size = UDim2.fromScale(1, 0.3)

	local icon = UiKit.Image(iconHolder, "Icon", Icons.Abilities[card.abilityKey])
	if icon then
		icon.AnchorPoint = Vector2.new(0.5, 0.5)
		icon.Position = UDim2.fromScale(0.5, 0.5)
		icon.Size = UDim2.fromScale(1, 1)
	end

	local badge = Instance.new("TextLabel")
	badge.Size = UDim2.fromScale(1, 1)
	badge.BackgroundTransparency = 1
	badge.Font = Enum.Font.GothamBold
	--[[
		Редкость подписана ВСЕГДА, включая обычную. Иначе игрок не понимает,
		что редкость вообще существует, пока ему не выпадет редкая, — и не может
		сравнить: «Common» на соседней карточке объясняет, чем хороша «Rare»,
		лучше любого объяснения.
	]]
	local rarityText = if rarity then `  ·  {rarity.displayName}` else ""
	badge.Text = if card.isNew then "NEW" else `LEVEL {card.level}{rarityText}`
	--[[
		Тёмная подпись на светлой шапке и светлая на тёмной. Цвет шапки теперь
		берётся из редкости, а среди четырёх есть и почти белая, и сиреневая:
		одна подпись на всех была бы нечитаемой на одной из них.
	]]
	local _, _, brightness = rarityColour:ToHSV()
	badge.TextColor3 = if brightness > 0.6 then Palette.UI.background else Palette.UI.text
	badge.TextScaled = true
	badge.Parent = header

	--[[
		Потолок кегля. TextScaled тянет надпись во всю высоту шапки, а шапка
		— это пятая часть карточки: на широком экране подпись вырастала вдвое
		крупнее названия способности, ради которого карточку и читают.
	]]
	local badgeSize = Instance.new("UITextSizeConstraint")
	badgeSize.MaxTextSize = 22
	badgeSize.Parent = badge

	local badgePadding = Instance.new("UIPadding")
	badgePadding.PaddingTop = UDim.new(0, 6)
	badgePadding.PaddingBottom = UDim.new(0, 6)
	badgePadding.Parent = badge

	local name = Instance.new("TextLabel")
	name.AnchorPoint = Vector2.new(0.5, 0)
	name.Position = UDim2.fromScale(0.5, 0.56)
	name.Size = UDim2.fromScale(0.86, 0.14)
	name.BackgroundTransparency = 1
	name.Font = Enum.Font.GothamBold
	name.Text = if def then def.displayName else card.abilityKey
	name.TextColor3 = Palette.UI.text
	name.TextScaled = true
	name.Parent = content

	local description = Instance.new("TextLabel")
	description.AnchorPoint = Vector2.new(0.5, 0)
	description.Position = UDim2.fromScale(0.5, 0.72)
	description.Size = UDim2.fromScale(0.86, 0.24)
	description.BackgroundTransparency = 1
	description.Font = Enum.Font.Gotham
	--[[
		На карточке — что игрок получит ЗДЕСЬ И СЕЙЧАС, а не описание
		способности. Описание он прочитал, когда брал её впервые (для новой
		карточки UpgradeText его и вернёт), а решение принимает по прибавке.

		Текст считает клиент из общего конфига: та же функция, что применяет
		улучшение на сервере, поэтому разойтись им не с чем.
	]]
	description.Text = if def then Abilities.UpgradeText(def, card.level, Cards.MultiplierFor(card.rarity)) else ""
	description.TextColor3 = Palette.UI.subtext
	description.TextWrapped = true
	description.TextScaled = true
	description.Parent = content

	button.Activated:Connect(function()
		choose(index)
	end)
end

local function show(level: number, cards: { LevelUpCard }): ()
	local gui = screen
	local row = cardRow
	local title = titleLabel
	if not gui or not row then
		return
	end

	hide()

	if title then
		title.Text = `LEVEL {level}`
	end

	offered = cards

	for index, card in cards do
		buildCard(card, index, #cards)
	end

	awaitingChoice = true
	gui.Enabled = true
end

function LevelUpController.Start(): ()
	build()
	choiceRemote = Net.GetEvent(Net.Id.LevelUpChoice)

	Net.GetEvent(Net.Id.LevelUpOffer).OnClientEvent:Connect(function(level: number, cards: { LevelUpCard })
		show(level, cards)
	end)

	-- Сервер снял паузу сам (таймаут или выбор применён) — экран убираем.
	Net.GetEvent(Net.Id.CombatPaused).OnClientEvent:Connect(function(paused: boolean)
		if not paused then
			--[[
				Пауза снята, а выбор так и не сделан: значит сработал таймаут,
				и сервер взял первую карточку (см. шапку). Записываем её же,
				иначе взятая редкость разошлась бы с настоящей.
			]]
			if awaitingChoice then
				record(offered[1])
			end
			hide()
		end
	end)

	Net.GetEvent(Net.Id.RunEnded).OnClientEvent:Connect(function()
		hide()
		-- Множители способностей забег не переживают, и редкость тоже.
		table.clear(bestRarity)
		table.clear(offered)
	end)
end

function LevelUpController.BestRarity(abilityKey: string): string?
	return bestRarity[abilityKey]
end

return LevelUpController
