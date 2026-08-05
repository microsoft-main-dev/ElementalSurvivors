--!strict
--[[
	EvolvePanel — отдельное меню эволюции одного питомца.

	Посередине круг с иконкой того, кого улучшаем, ниже — иконки того, что
	для этого нужно: сначала копии его вида, потом слоты его стихии. Под каждой
	иконкой звёзды требуемой ступени, недостающие иконки тусклые.

	Ничего не считает: и состав рецепта, и «хватает ли» приходят в EvolveView
	готовыми. Поле ready сервер считает тем же кодом, которым потом и
	эволюционирует, поэтому кнопка гаснет ровно тогда, когда сервер откажет.

	Успех виден не по сообщению, а по коллекции: панель запоминает, на скольких
	звёздах был питомец в момент нажатия, и играет анимацию, когда придёт срез,
	где звёзд стало больше. Отдельного Remote «эволюция удалась» нет намеренно —
	это не событие, а следствие уже приходящего состояния, и второй канал для
	одного факта разъехался бы с первым.

	Публичный API:
		EvolvePanel.Build(parent, send, onBack) -> Panel
		panel.Open(uid)
		panel.Close()
		panel.Refresh(pets)
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Palette = require(Shared.Config.Palette)
local PetIcon = require(script.Parent.PetIcon)
local Pets = require(Shared.Config.Pets)
local Types = require(Shared.Types)
local UiKit = require(script.Parent.UiKit)

export type Panel = {
	Open: (uid: string) -> (),
	Close: () -> (),
	Refresh: (pets: Types.PetsView?) -> (),
}

local EvolvePanel = {}

local TARGET_SIZE = 132
local SLOT_SIZE = 72
local SLOT_GAP = 10
local SLOTS_PER_ROW = 4 -- ингредиентов бывает до семи: на телефоне это две строки

-- Длительности анимации. Вся она укладывается в полторы секунды: это награда,
-- а не заставка, и второй раз её будут пропускать.
local PULL_TIME = 0.4
local PULL_STAGGER = 0.05
local FLASH_TIME = 0.28
local POP_TIME = 0.22
local RESULT_HOLD = 2.6

-- Сколько ждать ответа сервера, прежде чем вернуть кнопку.
local REPLY_TIMEOUT = 3

function EvolvePanel.Build(
	parent: Instance,
	send: (action: string, target: string?, extra: unknown) -> (),
	onBack: () -> ()
): Panel
	local window = UiKit.Window(parent, "EvolvePanel", "Evolve")

	local stage = UiKit.Frame(window.content, "Stage")
	stage.Size = UDim2.fromScale(1, 1)

	--[[
		Слой анимации поверх содержимого: иконки летят к центру уже вне сетки,
		иначе раскладка тащила бы их обратно каждым кадром.
	]]
	local overlay = UiKit.Frame(stage, "Overlay")
	overlay.Size = UDim2.fromScale(1, 1)
	overlay.ZIndex = 5
	overlay.Visible = false

	local targetHolder = UiKit.Frame(stage, "Target")
	targetHolder.AnchorPoint = Vector2.new(0.5, 0)
	targetHolder.Position = UDim2.new(0.5, 0, 0, 8)
	targetHolder.Size = UDim2.fromOffset(TARGET_SIZE, TARGET_SIZE + 20)

	local targetName = UiKit.Label(stage, "Name", "", 20)
	targetName.Font = Enum.Font.GothamBold
	targetName.AnchorPoint = Vector2.new(0.5, 0)
	targetName.Position = UDim2.new(0.5, 0, 0, TARGET_SIZE + 32)
	targetName.Size = UDim2.new(1, -16, 0, 24)
	targetName.TextXAlignment = Enum.TextXAlignment.Center

	--[[
		Одна строка на два сообщения: чего не хватает и чем всё кончилось.
		Второе длиннее и на телефоне не помещается в строку, поэтому подпись
		переносится, а не обрезается многоточием.
	]]
	local needLabel = UiKit.Label(stage, "Need", "", 14, Palette.UI.subtext)
	needLabel.AnchorPoint = Vector2.new(0.5, 0)
	needLabel.Position = UDim2.new(0.5, 0, 0, TARGET_SIZE + 58)
	needLabel.Size = UDim2.new(1, -16, 0, 40)
	needLabel.TextXAlignment = Enum.TextXAlignment.Center
	needLabel.TextTruncate = Enum.TextTruncate.None
	needLabel.TextWrapped = true

	--[[
		Сетка, а не строка: семь ингредиентов в строку не помещаются на телефоне,
		а UIGridLayout переносит их сам и не требует считать ширину руками.
	]]
	local slots = UiKit.Frame(stage, "Slots")
	slots.AnchorPoint = Vector2.new(0.5, 0)
	slots.Position = UDim2.new(0.5, 0, 0, TARGET_SIZE + 104)
	slots.Size = UDim2.new(1, -16, 1, -TARGET_SIZE - 172)

	local grid = Instance.new("UIGridLayout")
	grid.CellSize = UDim2.fromOffset(SLOT_SIZE, SLOT_SIZE + 20)
	grid.CellPadding = UDim2.fromOffset(SLOT_GAP, SLOT_GAP)
	grid.FillDirectionMaxCells = SLOTS_PER_ROW
	grid.HorizontalAlignment = Enum.HorizontalAlignment.Center
	grid.SortOrder = Enum.SortOrder.LayoutOrder
	grid.Parent = slots

	local buttons = UiKit.Frame(stage, "Buttons")
	buttons.AnchorPoint = Vector2.new(0.5, 1)
	buttons.Position = UDim2.new(0.5, 0, 1, -4)
	buttons.Size = UDim2.fromOffset(300, UiKit.ButtonHeight)

	local buttonsLayout = Instance.new("UIListLayout")
	buttonsLayout.FillDirection = Enum.FillDirection.Horizontal
	buttonsLayout.HorizontalAlignment = Enum.HorizontalAlignment.Center
	buttonsLayout.VerticalAlignment = Enum.VerticalAlignment.Center
	buttonsLayout.SortOrder = Enum.SortOrder.LayoutOrder
	buttonsLayout.Padding = UDim.new(0, 8)
	buttonsLayout.Parent = buttons

	local back = UiKit.Button(buttons, "Back", "Inventory", Palette.UI.panel)
	back.LayoutOrder = 1
	back.Size = UDim2.fromOffset(96, UiKit.ButtonHeight)

	local evolve = UiKit.Button(buttons, "Evolve", "Evolve")
	evolve.LayoutOrder = 2
	evolve.Size = UDim2.fromOffset(160, UiKit.ButtonHeight)

	local latest: Types.PetsView? = nil
	local currentUid: string? = nil
	-- Сколько звёзд было в момент нажатия. nil — «эволюции не ждём».
	local pendingStars: number? = nil
	local playing = false
	-- Номер последнего запроса: по нему таймер понимает, что ждёт уже не свой ответ.
	local requests = 0

	local function findPet(uid: string): Types.PetView?
		local view = latest
		if not view then
			return nil
		end
		for _, pet in view.pets do
			if pet.uid == uid then
				return pet
			end
		end
		return nil
	end

	local render: () -> ()

	--[[
		Анимация успеха. Иконки съеденных тянутся в центр, вспышка, и на месте
		цели появляется её новый вид с подписью.

		Работает по копиям иконок на отдельном слое: настоящие уже не годятся,
		следующий же render сотрёт их вместе со всей сеткой.
	]]
	local function playEvolution(pet: Types.PetView): ()
		playing = true

		local SoundController = require(script.Parent.Parent.Controllers.SoundController)

		for _, child in overlay:GetChildren() do
			child:Destroy()
		end
		overlay.Visible = true

		local center = UDim2.new(0.5, 0, 0, 8 + TARGET_SIZE // 2)

		--[[
			Слоты копируются вместе с их экранными позициями: сетка уже разложила
			их, и повторять её арифметику ради анимации незачем.

			AbsolutePosition меряется в пикселях экрана, а Position, который мы
			из неё складываем, — в единицах панели. На телефоне между ними стоит
			UIScale окна, и без деления на него иконки стартовали бы мимо своих
			мест ровно на столько, на сколько ужат интерфейс.
		]]
		local uiScale = window.panel:FindFirstChildOfClass("UIScale")
		local scaleFactor = if uiScale then uiScale.Scale else 1

		local flying: { Frame } = {}
		for _, child in slots:GetChildren() do
			if child:IsA("Frame") then
				local clone = child:Clone()
				clone.Position = UDim2.fromOffset(
					(child.AbsolutePosition.X - stage.AbsolutePosition.X) / scaleFactor,
					(child.AbsolutePosition.Y - stage.AbsolutePosition.Y) / scaleFactor
				)
				clone.AnchorPoint = Vector2.zero
				clone.ZIndex = 6
				clone.Parent = overlay
				table.insert(flying, clone)
			end
		end

		slots.Visible = false
		needLabel.Text = ""

		-- Задержка у каждой иконки своя: одновременный полёт семи кругов
		-- читается как один рывок, а не как «съели по очереди».
		for index, clone in flying do
			local delayed = TweenInfo.new(
				PULL_TIME,
				Enum.EasingStyle.Quad,
				Enum.EasingDirection.In,
				0,
				false,
				(index - 1) * PULL_STAGGER
			)
			TweenService:Create(clone, delayed, {
				Position = center,
				Size = UDim2.fromOffset(0, 0),
			}):Play()
		end

		task.wait(PULL_TIME + #flying * PULL_STAGGER)

		for _, clone in flying do
			clone:Destroy()
		end

		-- Вспышка: круг из центра наружу. Ассетов не требует и читается
		-- одинаково на любой палитре.
		local flash = UiKit.Frame(overlay, "Flash", Palette.UI.text)
		flash.AnchorPoint = Vector2.new(0.5, 0.5)
		flash.Position = center
		flash.Size = UDim2.fromOffset(TARGET_SIZE // 2, TARGET_SIZE // 2)
		flash.ZIndex = 7
		UiKit.Corners(flash, TARGET_SIZE)

		SoundController.PlaySfx("LevelUp")

		TweenService:Create(flash, TweenInfo.new(FLASH_TIME, Enum.EasingStyle.Quad), {
			Size = UDim2.fromOffset(TARGET_SIZE * 2, TARGET_SIZE * 2),
			BackgroundTransparency = 1,
		}):Play()

		-- Новая иконка появляется под вспышкой, а не после неё: иначе между
		-- исчезновением корма и появлением результата видна пустая панель.
		render()
		slots.Visible = false
		-- render вернул кнопке её обычное состояние, а во время анимации
		-- нажимать нечего: следующая ступень будет собрана уже из другого корма.
		UiKit.SetEnabled(evolve, false)

		local scale = Instance.new("UIScale")
		scale.Scale = 0.4
		scale.Parent = targetHolder
		TweenService:Create(scale, TweenInfo.new(POP_TIME, Enum.EasingStyle.Back, Enum.EasingDirection.Out), {
			Scale = 1,
		}):Play()

		local def = Pets.ByKey[pet.petId]
		local name = if def then def.displayName else pet.petId
		needLabel.RichText = true
		needLabel.TextColor3 = Palette.UI.text
		needLabel.Text =
			`You have evolved your "{name}" to {PetIcon.StarsMarkup(pet.stars)} {PetIcon.StageName(pet.stars)}`

		task.wait(FLASH_TIME)
		flash:Destroy()

		task.wait(RESULT_HOLD)

		if scale.Parent then
			scale:Destroy()
		end
		overlay.Visible = false
		slots.Visible = true
		playing = false

		--[[
			Перерисовка в конце берёт последний пришедший срез, а не тот,
			с которого анимация начиналась: пока она шла, коллекция могла
			измениться ещё раз.
		]]
		render()
	end

	-- Один слот: копия вида или «любой питомец этой стихии».
	local function buildSlot(
		order: number,
		recipe: Types.EvolveView,
		petId: string?,
		stars: number,
		filled: boolean
	): ()
		local icon = if petId
			then PetIcon.Pet(slots, `Slot{order}`, petId, stars, SLOT_SIZE)
			else PetIcon.Element(slots, `Slot{order}`, recipe.fodderElement, stars, SLOT_SIZE)

		icon.frame.LayoutOrder = order
		icon.SetDim(not filled)
	end

	render = function(): ()
		for _, child in slots:GetChildren() do
			if not child:IsA("UIGridLayout") then
				child:Destroy()
			end
		end
		for _, child in targetHolder:GetChildren() do
			child:Destroy()
		end

		local uid = currentUid
		local pet = if uid then findPet(uid) else nil
		if not pet then
			window.subtitle.Text = "That pet is gone."
			UiKit.SetEnabled(evolve, false)
			return
		end

		local def = Pets.ByKey[pet.petId]
		local name = if def then def.displayName else pet.petId

		PetIcon.Pet(targetHolder, "Icon", pet.petId, pet.stars, TARGET_SIZE)

		window.title.Text = "Evolve"
		window.subtitle.Text = `{name}  ·  Lv {pet.level}  ·  {PetIcon.StageName(pet.stars)}`
		targetName.Text = name
		targetName.TextColor3 = if def then Palette.Element[def.element] else Palette.UI.text

		local recipe = pet.evolve
		if not recipe then
			needLabel.RichText = false
			needLabel.TextColor3 = Palette.UI.subtext
			needLabel.Text = "This pet is at its final star."
			UiKit.SetEnabled(evolve, false)
			return
		end

		local order = 0
		for index = 1, recipe.copies do
			order += 1
			buildSlot(order, recipe, pet.petId, recipe.copyStars, index <= recipe.haveCopies)
		end
		for index = 1, recipe.fodder do
			order += 1
			buildSlot(order, recipe, nil, recipe.fodderStars, index <= recipe.haveFodder)
		end

		needLabel.RichText = false
		needLabel.TextColor3 = Palette.UI.subtext

		if recipe.ready then
			needLabel.Text = "Ready to evolve."
		else
			--[[
				Не хватает чего-то одного — про него и говорим. Копии дороже
				корма, поэтому они первыми: игрок должен знать, чего именно ждать
				из яиц.
			]]
			local missingCopies = recipe.copies - recipe.haveCopies
			if missingCopies > 0 then
				needLabel.Text = `Needs {missingCopies} more {name} at {recipe.copyStars}★.`
			else
				local missing = recipe.fodder - recipe.haveFodder
				needLabel.Text = `Needs {missing} more {recipe.fodderElement} pets at {recipe.fodderStars}★.`
			end
		end

		UiKit.SetEnabled(evolve, recipe.ready)
	end

	evolve.Activated:Connect(function()
		if playing then
			return
		end

		local uid = currentUid
		local pet = if uid then findPet(uid) else nil
		local recipe = if pet then pet.evolve else nil
		if not uid or not pet or not recipe or not recipe.ready then
			return
		end

		--[[
			Кнопка гаснет до ответа сервера, и это не косметика: два быстрых
			нажатия — это две эволюции, вторая уже за другой комплект корма.

			Отказ сервер сообщает только текстом, коллекция при нём не меняется
			и Refresh не приходит, поэтому кнопку возвращает таймер. Он же
			страхует от потерянного пакета: панель не имеет права остаться
            с мёртвой кнопкой навсегда.
		]]
		requests += 1
		local id = requests

		pendingStars = pet.stars
		UiKit.SetEnabled(evolve, false)
		send("EvolvePet", uid, nil)

		task.delay(REPLY_TIMEOUT, function()
			if id ~= requests or pendingStars == nil or playing then
				return
			end
			pendingStars = nil
			if window.screen.Enabled then
				render()
			end
		end)
	end)

	back.Activated:Connect(function()
		if playing then
			return
		end
		onBack()
	end)

	local panel: Panel = {
		Open = function(uid: string)
			currentUid = uid
			pendingStars = nil
			window.screen.Enabled = true
			render()
		end,

		Close = function()
			window.screen.Enabled = false
			pendingStars = nil
		end,

		Refresh = function(pets: Types.PetsView?)
			latest = pets

			if not window.screen.Enabled then
				return
			end

			--[[
				Пришёл срез, где у ожидаемого питомца звёзд стало больше, — это
				и есть «сервер согласился». Отказ звёзд не меняет, поэтому
				анимация на нём не запускается, а игрок видит обычное сообщение.
			]]
			local uid = currentUid
			local was = pendingStars
			local pet = if uid then findPet(uid) else nil

			if pet and was and pet.stars > was and not playing then
				pendingStars = nil
				task.spawn(playEvolution, pet)
				return
			end

			if not playing then
				render()
			end
		end,
	}

	return panel
end

return EvolvePanel
