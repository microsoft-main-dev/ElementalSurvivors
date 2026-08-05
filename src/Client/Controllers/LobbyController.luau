--!strict
--[[
	LobbyController — интерфейс лобби (разделы 4 и 8 ТЗ).

	Три обязанности и ни одной больше:
		1. кнопки лобби и открытие панелей по ProximityPrompt объектов;
		2. хранение последнего среза профиля и коллекции, пришедших с сервера;
		3. отправка действий одним Remote с серверной валидацией.

	Клиент не считает ничего, что влияет на прогресс: цены, шансы и остатки
	приходят готовыми. Гашеная кнопка «не хватает Essence» — это подсказка,
	а не проверка: настоящая проверка живёт в LobbyNetService, и она же
	единственная, которой можно верить.

	Панели живут в Client/UI: загрузчик сканирует только Controllers, поэтому
	модуль без Init/Start там оказался бы контроллером-пустышкой.

	На время боя весь интерфейс лобби прячется — в бою нет ни одного
	интерактивного элемента, кроме карточек левел-апа (раздел 8 ТЗ).
]]

local Players = game:GetService("Players")
local ProximityPromptService = game:GetService("ProximityPromptService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Balance = require(Shared.Config.Balance)
local DailyPanel = require(script.Parent.Parent.UI.DailyPanel)
local EggsPanel = require(script.Parent.Parent.UI.EggsPanel)
local EvolvePanel = require(script.Parent.Parent.UI.EvolvePanel)
local InventoryPanel = require(script.Parent.Parent.UI.InventoryPanel)
local Net = require(Shared.Net)
local OfflinePanel = require(script.Parent.Parent.UI.OfflinePanel)
local Palette = require(Shared.Config.Palette)
local Pets = require(Shared.Config.Pets)
local SettingsPanel = require(script.Parent.Parent.UI.SettingsPanel)
local ShopPanel = require(script.Parent.Parent.UI.ShopPanel)
local StagePanel = require(script.Parent.Parent.UI.StagePanel)
local StorePanel = require(script.Parent.Parent.UI.StorePanel)
local TalentsPanel = require(script.Parent.Parent.UI.TalentsPanel)
local Types = require(Shared.Types)
local UiKit = require(script.Parent.Parent.UI.UiKit)

local BUTTON_WIDTH = 116
local BUTTON_GAP = 8
local PET_SPIN_SPEED = 0.6 -- оборотов в секунду у модели на стенде

local LobbyController = {}

local player = Players.LocalPlayer

local barGui: ScreenGui? = nil
local inventoryPanel: InventoryPanel.Panel? = nil
local evolvePanel: EvolvePanel.Panel? = nil
local eggsPanel: EggsPanel.Panel? = nil
local shopPanel: ShopPanel.Panel? = nil
local talentsPanel: TalentsPanel.Panel? = nil
local offlinePanel: OfflinePanel.Panel? = nil
local stagePanel: StagePanel.Panel? = nil
local dailyPanel: DailyPanel.Panel? = nil
local storePanel: StorePanel.Panel? = nil
local settingsPanel: SettingsPanel.Panel? = nil

local profileView: Types.ProfileView? = nil
local petsView: Types.PetsView? = nil
local talentsView: Types.TalentsView? = nil
local itemsView: Types.ItemsView? = nil
local questsView: Types.QuestsView? = nil
local storeView: Types.StoreView? = nil
local leaderboard: { Types.LeaderboardEntry } = {}

local petModel: BasePart? = nil
local petSpin = 0
local inRun = false

--[[
	Обучение (M7). Пока тур идёт, открывается только та панель, на которую он
	показывает, а остальные кнопки гасятся. Это подсказка, а не защита: за
	туториал ничего не начисляется, и обходить здесь нечего — потому проверка
	и живёт на клиенте.

	Кнопки складываются по именам, чтобы тур мог зажечь нужную, не зная,
	в каком порядке их построил buildBar.
]]
local barButtons: { [string]: TextButton } = {}
local tutorialFocus: string? = nil
local panelListener: ((name: string) -> ())? = nil

--[[
	Обучающий уровень ещё не пройден: панель у портала показывает только его.
	Состояние приходит тем же TutorialView, что и контроллеру обучения —
	подписаться на готовый пуш дешевле, чем спрашивать соседний контроллер.
]]
local tutorialPending = false

local function send(action: string, target: string?, extra: unknown): ()
	Net.GetEvent(Net.Id.LobbyRequest):FireServer(action, target, extra)
end

--[[
	Имя экипированного питомца для подписи в магазине. Ищется по коллекции,
	а не хранится отдельно: два места для одного факта разъезжаются.
]]
local function equippedInfo(): (string, string)
	local view = petsView
	if not view then
		return "", ""
	end

	for _, pet in view.pets do
		if pet.equipped then
			local def = Pets.ByKey[pet.petId]
			return pet.uid, if def then def.displayName else pet.petId
		end
	end

	return "", ""
end

-- Раздаёт панелям то, что им нужно. Одно место, где сходятся оба среза.
local function refreshPanels(): ()
	local essence = if profileView then profileView.essence else 0
	local prisms = if profileView then profileView.prisms else 0

	local inventory = inventoryPanel
	if inventory then
		inventory.Refresh(petsView, itemsView, storeView, essence)
	end

	--[[
		Меню эволюции обновляется вместе с коллекцией и по ней же узнаёт, что
		эволюция удалась: у питомца стало больше звёзд. Отдельного события
		об успехе нет — это состояние, а не новость.
	]]
	local evolveMenu = evolvePanel
	if evolveMenu then
		evolveMenu.Refresh(petsView)
	end

	local eggs = eggsPanel
	if eggs then
		-- Коллекция нужна панели, чтобы показать неполученных питомцев
		-- силуэтами: что уже есть, знает только этот срез.
		eggs.Refresh(essence, prisms, petsView)
	end

	local shop = shopPanel
	if shop then
		local uid, name = equippedInfo()
		shop.Refresh(essence, prisms, uid, name)
	end

	local talents = talentsPanel
	if talents then
		talents.Refresh(talentsView, essence)
	end

	local stage = stagePanel
	if stage then
		stage.Refresh(if profileView then profileView.storyStage else 1, tutorialPending)
	end

	local daily = dailyPanel
	if daily then
		daily.Refresh(questsView, leaderboard)
	end

	local store = storePanel
	if store then
		store.Refresh(storeView)
	end

	local settings = settingsPanel
	if settings and profileView then
		settings.Refresh(profileView.settings)
	end
end

local function closeAll(): ()
	local inventory = inventoryPanel
	if inventory then
		inventory.Close()
	end
	local evolveMenu = evolvePanel
	if evolveMenu then
		evolveMenu.Close()
	end
	local eggs = eggsPanel
	if eggs then
		eggs.Close()
	end
	local shop = shopPanel
	if shop then
		shop.Close()
	end
	local talents = talentsPanel
	if talents then
		talents.Close()
	end
	local offline = offlinePanel
	if offline then
		offline.Close()
	end
	local stage = stagePanel
	if stage then
		stage.Close()
	end
	local daily = dailyPanel
	if daily then
		daily.Close()
	end
	local store = storePanel
	if store then
		store.Close()
	end
	local settings = settingsPanel
	if settings then
		settings.Close()
	end
end

--[[
	Имя окна, которое на самом деле откроется. Инвентарь один, но разделов
	в нём три, и снаружи их зовут своими именами: промпт у стенда питомцев
	шлёт «Pets», обучение — «Items». Разворачивается это здесь, потому что
	по имени ОКНА живут и фильтр обучения, и подсветка кнопки: без общего
	знаменателя шаг «открой Pets» гасил бы кнопку Inventory как чужую.
]]
local PANEL_OWNER: { [string]: string } = {
	Pets = "Inventory",
	Items = "Inventory",
	Gear = "Inventory",
	Boosts = "Inventory",
}

local function ownerOf(name: string): string
	return PANEL_OWNER[name] or name
end

--[[
	Открытие панели по имени. Одна точка входа и для кнопок нижней панели,
	и для промптов у объектов: иначе объект и кнопка однажды начнут открывать
	разные окна.
]]
local function openPanel(name: string, target: string?): ()
	--[[
		Фильтр тура стоит здесь, а не в обработчике кнопки: панель открывается
		ещё и промптом у объекта лобби, и «заблокировано только с кнопки»
		означало бы, что игрок обходит шаг обучения ногами.
	]]
	local owner = ownerOf(name)
	local focus = tutorialFocus
	if focus and owner ~= ownerOf(focus) then
		return
	end

	closeAll()

	if owner == "Inventory" then
		local inventory = inventoryPanel
		if inventory then
			-- name здесь и есть раздел: «Pets» открывает питомцев, «Items» —
			-- снаряжение, сама кнопка «Inventory» — тот, что был открыт.
			inventory.Open(if name == "Inventory" then nil else name)
		end
	elseif name == "Evolve" then
		--[[
			Единственная панель, которую открывает не кнопка лобби, а строка
			коллекции, — и всё-таки через общую точку входа: target здесь uid
			питомца, а не ключ объекта, но правило «панели открываются одним
			способом» дороже этой разницы.
		]]
		local evolveMenu = evolvePanel
		if evolveMenu and target then
			evolveMenu.Open(target)
		end
	elseif name == "Eggs" then
		local eggs = eggsPanel
		if eggs then
			eggs.Open(target)
		end
	elseif name == "Shop" then
		local shop = shopPanel
		if shop then
			shop.Open()
		end
	elseif name == "Talents" then
		local talents = talentsPanel
		if talents then
			talents.Open()
		end
	elseif name == "Stage" then
		local stage = stagePanel
		if stage then
			stage.Open()
		end
	elseif name == "Store" then
		local store = storePanel
		if store then
			store.Open()
		end
	elseif name == "Settings" then
		local settings = settingsPanel
		if settings then
			settings.Open()
		end
	elseif name == "Quests" or name == "Wheel" or name == "Leaderboard" then
		-- Три объекта лобби делят одну панель: у них одинаковая форма,
		-- а открывается тот раздел, к которому подошёл игрок.
		local daily = dailyPanel
		if daily then
			daily.Open(name)
		end
	end

	--[[
		Слушателю (обучению) сообщается имя ОКНА, а не раздела: шаг «открой
		инвентарь» обязан засчитываться и когда игрок нажал кнопку, и когда
		подошёл к стенду питомцев.
	]]
	local listener = panelListener
	if listener then
		listener(owner)
	end
end

--[[
	Шаг тура обучения: имя панели, которую сейчас ждут от игрока, или nil —
	«тур закончен, лобби снова целиком его».
]]
function LobbyController.SetTutorialFocus(name: string?): ()
	tutorialFocus = name

	-- Сравнение по имени окна: шаг может ждать раздела («Items»), а кнопка
	-- в панели одна и зовётся «Inventory».
	local wanted = if name then ownerOf(name) else nil

	for buttonName, button in barButtons do
		local allowed = wanted == nil or buttonName == wanted
		UiKit.SetEnabled(button, allowed)

		local stroke = button:FindFirstChildOfClass("UIStroke")
		if stroke then
			stroke.Enabled = wanted ~= nil and buttonName == wanted
		end
	end
end

-- Кто-то открыл панель. Слушатель один: обучение — единственное, кому это
-- интересно, а список подписчиков ради одного подписчика не заводят.
function LobbyController.SetPanelListener(fn: (name: string) -> ()): ()
	panelListener = fn
end

--[[
	Модель экипированного питомца на стенде.

	Строится локально: у каждого игрока питомец свой, а серверная геометрия
	лобби одна на всех — репликация личной модели заставила бы всех смотреть
	на чужих питомцев в одной точке.
]]
local function updatePetModel(): ()
	local existing = petModel
	if existing then
		existing:Destroy()
		petModel = nil
	end

	local uid = (equippedInfo())
	if uid == "" then
		return
	end

	local view = petsView
	if not view then
		return
	end

	local petId = ""
	for _, pet in view.pets do
		if pet.uid == uid then
			petId = pet.petId
			break
		end
	end

	local def = Pets.ByKey[petId]
	if not def then
		return
	end

	local part = Instance.new("Part")
	part.Name = "EquippedPet"
	part.Size = def.model.size
	part.Color = Palette.Element[def.element]
	part.Material = if def.model.neon then Enum.Material.Neon else Enum.Material.SmoothPlastic
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.Massless = true

	if def.model.shape == "Ball" then
		part.Shape = Enum.PartType.Ball
	elseif def.model.shape == "Cylinder" then
		part.Shape = Enum.PartType.Cylinder
	end

	part.Parent = Workspace
	petModel = part
end

-- Точка стенда считается из того же числа, что и на сервере (см. LobbyService).
local function petStandPosition(): Vector3
	return Vector3.new(-Balance.Lobby.petStandOffset, 6, 0)
end

local function onHeartbeat(deltaTime: number): ()
	local part = petModel
	if not part then
		return
	end

	petSpin = (petSpin + deltaTime * PET_SPIN_SPEED) % 1
	local bob = math.sin(petSpin * math.pi * 2) * 0.4
	part.CFrame = CFrame.new(petStandPosition() + Vector3.new(0, bob, 0)) * CFrame.Angles(0, petSpin * math.pi * 2, 0)
end

local function buildBar(): ()
	local playerGui = player:WaitForChild("PlayerGui")

	local gui = Instance.new("ScreenGui")
	gui.Name = "LobbyBar"
	gui.ResetOnSpawn = false
	gui.DisplayOrder = 150
	gui.Parent = playerGui
	barGui = gui

	local holder = UiKit.Frame(gui, "Holder")
	holder.AnchorPoint = Vector2.new(0.5, 1)
	holder.Position = UDim2.new(0.5, 0, 1, -14)
	-- Девять кнопок по четыре в ряд — три ряда, и на телефоне они не влезут
	-- в один, поэтому у держателя фиксированная тройная высота.
	holder.Size = UDim2.fromOffset(BUTTON_WIDTH * 4 + BUTTON_GAP * 3, UiKit.ButtonHeight * 3 + BUTTON_GAP * 2)

	local layout = Instance.new("UIListLayout")
	layout.FillDirection = Enum.FillDirection.Horizontal
	layout.HorizontalAlignment = Enum.HorizontalAlignment.Center
	layout.VerticalAlignment = Enum.VerticalAlignment.Bottom
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Wraps = true
	layout.Padding = UDim.new(0, BUTTON_GAP)
	layout.Parent = holder

	--[[
		Ровно те системы, которые существуют. Квесты (M6) появятся здесь
		вместе с собой: кнопка, открывающая пустое окно, хуже отсутствующей.
	]]
	local buttons: { { name: string, text: string } } = {
		{ name = "Stage", text = "Play" },
		--[[
			Одна кнопка на всё имущество игрока: питомцы, снаряжение и расходники
			живут разделами внутри неё. Три кнопки на три вида инвентаря
			занимали треть панели и различались только тем, что в них лежит.
		]]
		{ name = "Inventory", text = "Inventory" },
		{ name = "Eggs", text = "Eggs" },
		{ name = "Shop", text = "Shop" },
		{ name = "Talents", text = "Talents" },
		{ name = "Quests", text = "Daily" },
		{ name = "Store", text = "Store" },
		{ name = "Settings", text = "Settings" },
	}

	for order, entry in buttons do
		local button = UiKit.Button(holder, entry.name, entry.text, Palette.UI.panel)
		button.LayoutOrder = order
		button.Size = UDim2.fromOffset(BUTTON_WIDTH, UiKit.ButtonHeight)
		button.Activated:Connect(function()
			openPanel(entry.name, nil)
		end)

		-- Контур для подсветки шага обучения. Создаётся сразу и выключенным:
		-- иначе тур создавал бы объекты в чужом интерфейсе на ходу.
		local stroke = Instance.new("UIStroke")
		stroke.Color = Palette.UI.accent
		stroke.Thickness = 3
		stroke.Enabled = false
		stroke.Parent = button

		barButtons[entry.name] = button
	end
end

local function setVisible(visible: boolean): ()
	local gui = barGui
	if gui then
		gui.Enabled = visible
	end

	if not visible then
		closeAll()
	end

	local part = petModel
	if part then
		-- В бою стенд лобби всё равно за пять тысяч стадов отсюда, но
		-- невидимая деталь не должна занимать место в рендере.
		part.Transparency = if visible then 0 else 1
	end
end

function LobbyController.Start(): ()
	local playerGui = player:WaitForChild("PlayerGui")

	buildBar()
	inventoryPanel = InventoryPanel.Build(playerGui, send, function(uid: string)
		openPanel("Evolve", uid)
	end)
	evolvePanel = EvolvePanel.Build(playerGui, send, function()
		openPanel("Pets")
	end)
	eggsPanel = EggsPanel.Build(playerGui, send)
	shopPanel = ShopPanel.Build(playerGui, send)
	talentsPanel = TalentsPanel.Build(playerGui, send)
	offlinePanel = OfflinePanel.Build(playerGui, send)
	stagePanel = StagePanel.Build(playerGui, send)
	dailyPanel = DailyPanel.Build(playerGui, send)
	-- Витрине send не нужен: покупка идёт мимо сервера, прямо в Roblox.
	storePanel = StorePanel.Build(playerGui)
	settingsPanel = SettingsPanel.Build(playerGui, send)

	--[[
		Промпты объектов лобби. Какое окно открыть, написано в атрибуте самого
		промпта, который поставил сервер: клиент не сопоставляет объекты
		с окнами по имени детали, иначе переименование парта тихо ломало бы
		взаимодействие.
	]]
	ProximityPromptService.PromptTriggered:Connect(function(prompt: ProximityPrompt, triggeringPlayer: Player)
		if triggeringPlayer ~= player then
			return
		end

		local panel = prompt:GetAttribute("Panel")
		if typeof(panel) == "string" then
			local target = prompt:GetAttribute("Target")
			openPanel(panel :: string, if typeof(target) == "string" then target :: string else nil)
		end
	end)

	Net.GetEvent(Net.Id.ProfileView).OnClientEvent:Connect(function(view: Types.ProfileView)
		profileView = view
		refreshPanels()
	end)

	Net.GetEvent(Net.Id.PetsView).OnClientEvent:Connect(function(view: Types.PetsView)
		petsView = view
		refreshPanels()
		updatePetModel()
	end)

	Net.GetEvent(Net.Id.TalentsView).OnClientEvent:Connect(function(view: Types.TalentsView)
		talentsView = view
		refreshPanels()
	end)

	Net.GetEvent(Net.Id.ItemsView).OnClientEvent:Connect(function(view: Types.ItemsView)
		itemsView = view
		refreshPanels()
	end)

	Net.GetEvent(Net.Id.QuestsView).OnClientEvent:Connect(function(view: Types.QuestsView)
		questsView = view
		refreshPanels()
	end)

	Net.GetEvent(Net.Id.TutorialView).OnClientEvent:Connect(function(view: Types.TutorialView)
		tutorialPending = view.needsRun
		refreshPanels()
	end)

	Net.GetEvent(Net.Id.StoreView).OnClientEvent:Connect(function(view: Types.StoreView)
		storeView = view
		refreshPanels()
	end)

	Net.GetEvent(Net.Id.LeaderboardView).OnClientEvent:Connect(function(top: { Types.LeaderboardEntry })
		leaderboard = top
		refreshPanels()
	end)

	Net.GetEvent(Net.Id.WheelResult).OnClientEvent:Connect(function(result: Types.WheelResult)
		local daily = dailyPanel
		if daily then
			daily.ShowSpin(result)
		end
	end)

	Net.GetEvent(Net.Id.EggResult).OnClientEvent:Connect(function(results: { Types.EggRollResult })
		local eggs = eggsPanel
		if eggs then
			eggs.ShowResults(results)
		end
	end)

	--[[
		Окно экспедиций не показывается поверх боя. В бою нет ни одного
		интерактивного элемента, кроме карточек левел-апа (раздел 8 ТЗ),
		и всплывшая панель означала бы, что игрок либо жмёт её вслепую,
		либо теряет здоровье, пока читает. Копилка при этом никуда
		не девается — она лежит в профиле и дождётся возвращения в лобби.
	]]
	Net.GetEvent(Net.Id.OfflineReport).OnClientEvent:Connect(function(report: Types.OfflineReport)
		local offline = offlinePanel
		if offline and not inRun then
			offline.Show(report)
		end
	end)

	Net.GetEvent(Net.Id.RunStarted).OnClientEvent:Connect(function()
		inRun = true
		setVisible(false)
	end)

	Net.GetEvent(Net.Id.RunEnded).OnClientEvent:Connect(function()
		inRun = false
		setVisible(true)
		-- Забег меняет баланс, а срез профиля мог прийти до начисления.
		send("Refresh", nil, nil)
	end)

	RunService.Heartbeat:Connect(onHeartbeat)
end

return LobbyController
