--!strict
--[[
	LobbyDecorController — декор лобби: собирает предметы из Config/Props
	и анимирует их локально.

	ПОЧЕМУ НА КЛИЕНТЕ. Не ради экономии на репликации статики — она уезжает
	один раз при входе, — а ради анимации: пульсирующая на сервере поверхность
	портала слала бы CFrame двадцати игрокам каждый кадр. Здесь это стоит ноль
	трафика, и каждый видит своё.

	Всё, во что игрок упирается или что нажимает, по-прежнему строит сервер
	(LobbyService): ProximityPrompt, созданный клиентом, до сервера не доедет
	вовсе, а коллизию игрока сервер проверяет сам.

	Анимация останавливается на время забега. Лобби в пяти тысячах стадов
	от арены и всё равно не видно, а два десятка деталей, которые гоняются
	через BulkMoveTo в бою с тремя сотнями врагов, — это отнятый кадр там,
	где он дороже всего.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Balance = require(Shared.Config.Balance)
local Net = require(Shared.Net)
local Palette = require(Shared.Config.Palette)
local PartModel = require(Shared.Util.PartModel)
local Props = require(Shared.Config.Props)
local Sounds = require(Shared.Config.Sounds)
local Types = require(Shared.Types)
local UiKit = require(script.Parent.Parent.UI.UiKit)

local LobbyDecorController = {}

type Placed = {
	built: PartModel.Built,
	pivot: CFrame,
	--[[
		Покачивание предмета целиком (Props.Placement.bob). Сдвигает ПИВОТ,
		а не отдельные детали: яйцо из четырёх ярусов, качающихся каждый
		сам по себе, развалилось бы на четыре блина.
	]]
	bob: number,
	bobSpeed: number,
	phase: number,
	-- Поворот вокруг собственной оси Z. Ненулевой только у диска колеса:
	-- он единственный, чьим положением управляет механика, а не время.
	spin: number,
}

local placed: { Placed } = {}
local byId: { [string]: Placed } = {}
local paused = false
local elapsed = 0

--[[
	Прокрутка колеса. Диск крутится ровно столько же, сколько идёт звук
	(Config/Sounds), потому что окно называет приз в тот же момент — иначе
	диск встанет раньше или позже, чем игрок прочтёт результат.

	Сектор известен ЗАРАНЕЕ: приз решил сервер, и прокрутка ничего не решает,
	а только прячет мгновенный ответ. Поэтому угол считается по формуле и
	приходит в цель точно, а не подгоняется на глаз.
]]
local WHEEL_TURNS = 4
local plates: { TextLabel } = {}
local wheelSpin = 0
local wheelFrom = 0
local wheelTo = 0
local wheelLeft = 0

--[[
	Таблички призовой тройки. Текст — это SurfaceGui, а сборщик предметов делает
	только детали, поэтому таблички вешаются здесь, поверх готового подиума.

	Точки берутся из Props.PodiumPlates: высота тумбы и высота таблички над
	ней обязаны жить рядом, иначе разъедутся при первой же правке пьедестала.
]]
local function buildPlates(parent: Instance, base: CFrame): ()
	for index, offset in Props.PodiumPlates do
		local anchor = Instance.new("Part")
		anchor.Name = `PodiumPlate{index}`
		anchor.Size = Vector3.new(0.2, 0.2, 0.2)
		anchor.CFrame = base * CFrame.new(offset)
		anchor.Anchored = true
		anchor.CanCollide = false
		anchor.CanQuery = false
		anchor.CanTouch = false
		anchor.Transparency = 1
		anchor.Parent = parent

		local billboard = Instance.new("BillboardGui")
		billboard.Name = "Plate"
		billboard.Size = UDim2.fromOffset(150, 46)
		billboard.AlwaysOnTop = false
		billboard.LightInfluence = 0
		billboard.MaxDistance = 120
		billboard.Adornee = anchor
		billboard.Parent = anchor

		local label = Instance.new("TextLabel")
		label.Size = UDim2.fromScale(1, 1)
		label.BackgroundTransparency = 1
		label.Font = Enum.Font.GothamBold
		label.TextColor3 = Palette.UI.text
		label.TextStrokeTransparency = 0.4
		label.TextScaled = true
		label.Text = "—"
		label.Parent = billboard

		plates[index] = label
	end
end

--[[
	Легенда колеса: какой цвет сколько даёт.

	Понадобилась с тех пор, как окно перестало показывать колесо. Раньше список
	призов игрок читал там; теперь он видит только диск, и без таблички цвета
	не значат ничего.

	Цвета берутся из той же Palette.Wheel, которой красится диск, а суммы —
	из Balance.Daily.wheelPrizes. Ни одного числа здесь не записано: разъедься
	табличка с колесом, она врала бы увереннее, чем молчала.
]]
local function buildWheelSign(parent: Instance, base: CFrame): ()
	local face = Props.WheelSignFace

	local board = Instance.new("Part")
	board.Name = "WheelSignFace"
	board.Size = Vector3.new(face.size.X, face.size.Y, 0.2)
	board.CFrame = base * CFrame.new(face.offset)
	board.Anchored = true
	board.CanCollide = false
	board.CanQuery = false
	board.CanTouch = false
	board.Transparency = 1
	board.Parent = parent

	local surface = Instance.new("SurfaceGui")
	surface.Name = "Legend"
	surface.Face = Enum.NormalId.Front
	surface.SizingMode = Enum.SurfaceGuiSizingMode.PixelsPerStud
	surface.PixelsPerStud = 50
	surface.LightInfluence = 0
	surface.Parent = board

	local holder = Instance.new("Frame")
	holder.Size = UDim2.fromScale(1, 1)
	holder.BackgroundTransparency = 1
	holder.Parent = surface

	UiKit.Padding(holder, 12)

	local layout = Instance.new("UIListLayout")
	layout.FillDirection = Enum.FillDirection.Vertical
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Padding = UDim.new(0, 6)
	layout.Parent = holder

	local title = UiKit.Label(holder, "Title", "Wheel prizes", 22, Palette.UI.text)
	title.Font = Enum.Font.GothamBold
	title.Size = UDim2.new(1, 0, 0, 34)
	title.TextXAlignment = Enum.TextXAlignment.Center
	title.LayoutOrder = 0

	for index, prize in Balance.Daily.wheelPrizes do
		local row = Instance.new("Frame")
		row.Name = `Prize{index}`
		row.Size = UDim2.new(1, 0, 0, 38)
		row.BackgroundTransparency = 1
		row.LayoutOrder = index
		row.Parent = holder

		-- Образец цвета ровно того же оттенка, что и сектор: игрок сверяет
		-- квадратик с диском глазами, и любая поправка «для читаемости»
		-- сделала бы это сличение невозможным.
		local swatch = Instance.new("Frame")
		swatch.Size = UDim2.fromOffset(34, 34)
		swatch.Position = UDim2.fromOffset(0, 2)
		swatch.BackgroundColor3 = Palette.Wheel[(index - 1) % #Palette.Wheel + 1]
		swatch.BorderSizePixel = 0
		swatch.Parent = row
		UiKit.Corners(swatch, 6)

		local label = UiKit.Label(row, "Amount", prize.displayName, 20, Palette.UI.text)
		label.Position = UDim2.fromOffset(44, 0)
		label.Size = UDim2.new(1, -44, 1, 0)
		label.TextXAlignment = Enum.TextXAlignment.Left
	end
end

local function build(): ()
	local parent = Instance.new("Folder")
	parent.Name = "LobbyDecor"
	parent.Parent = Workspace

	--[[
		Тинты предмету лобби не нужны: у него нет стихии, и все его детали
		крашены вручную (Config/Props это требует валидатором). Сборщик всё
		равно просит палитру, поэтому отдаём заведомо неиспользуемую.
	]]
	local tints = PartModel.TintsFor(Palette.Lobby.portal, Palette.Lobby.portalGlow)

	for _, placement in Props.Placements do
		local def = Props.ByKey[placement.key]
		if not def then
			warn(`[LobbyDecor] Неизвестный предмет "{placement.key}"`)
			continue
		end

		local built = PartModel.Build(def, tints, parent)
		built.SetVisible(true)

		local pivot = CFrame.new(placement.position) * CFrame.Angles(0, math.rad(placement.yaw), 0)
		-- Первая раскладка сразу, а не с первым кадром: иначе предмет
		-- мелькнёт в начале координат.
		built.Draw(pivot, 0, 0)

		local entry: Placed = {
			built = built,
			pivot = pivot,
			bob = placement.bob or 0,
			bobSpeed = placement.bobSpeed or 0,
			-- Своя фаза от номера: одинаковая на всех превратила бы ряд яиц
			-- в один качающийся объект.
			phase = #placed * 1.37,
			spin = 0,
		}

		table.insert(placed, entry)
		if placement.id then
			byId[placement.id] = entry
		end

		if placement.key == "Podium" then
			buildPlates(parent, pivot)
		elseif placement.key == "WheelSign" then
			buildWheelSign(parent, pivot)
		end
	end
end

--[[
	Шаг прокрутки. Замедление кубическое: диск идёт быстро и мягко встаёт,
	приходя ровно на нужный сектор. Огни бегут в такт — их собственное время
	ускоряется вместе с диском и затухает вместе с ним.
]]
local function stepWheel(deltaTime: number): ()
	local disc = byId.WheelDisc
	if not disc or wheelLeft <= 0 then
		return
	end

	wheelLeft = math.max(wheelLeft - deltaTime, 0)

	local total = Sounds.WheelSpinSeconds
	local done = math.clamp((total - wheelLeft) / total, 0, 1)
	local eased = 1 - (1 - done) ^ 3

	wheelSpin = wheelFrom + (wheelTo - wheelFrom) * eased
	disc.spin = wheelSpin

	local lamps = byId.WheelLamps
	if lamps then
		-- Скорость огней падает вместе со скоростью диска: производная того
		-- же замедления, поэтому огни встают ровно тогда же, когда и он.
		lamps.built.SetTimeScale(1 + 7 * (1 - done) ^ 2)
	end
end

local function onHeartbeat(deltaTime: number): ()
	if paused then
		return
	end

	elapsed += deltaTime
	stepWheel(deltaTime)

	for _, entry in placed do
		local pivot = entry.pivot
		if entry.bob > 0 then
			local lift = math.sin((elapsed * entry.bobSpeed + entry.phase) * math.pi * 2) * entry.bob
			pivot += Vector3.new(0, lift, 0)
		end
		if entry.spin ~= 0 then
			-- Вокруг СВОЕЙ оси Z: диск стоит лицом к игроку, и вертеться
			-- он должен в своей плоскости, а не вокруг мировой вертикали.
			pivot *= CFrame.Angles(0, 0, entry.spin)
		end

		-- Скорость нулевая: предметы лобби никуда не идут, шагать нечему.
		entry.built.Draw(pivot, deltaTime, 0)
	end
end

-- Запустить колесо на приз с этим номером.
function LobbyDecorController.SpinWheel(prizeIndex: number): ()
	local disc = byId.WheelDisc
	if not disc then
		return
	end

	--[[
		Угол сектора спрашивается у Config/Props, а не считается здесь.

		Сектора нарезаны по весам призов, то есть неравные, и раскладка живёт
		ровно в одном месте — там же, где рисуется диск. Посчитай клиент то же
		самое своей формулой, они разъехались бы при первой правке весов,
		и колесо вставало бы на сектор одного цвета, называя приз другого.

		ЗНАК ПОВОРОТА. Деталь сектора стоит в точке (sin θ, cos θ), а поворот
		диска на s переводит её в (sin(θ − s), cos(θ − s)). Под указатель,
		то есть на угол ноль, сектор приходит при s = ПЛЮС θ.

		Минус здесь уже стоял и давал ровно зеркальный сектор 360 − θ: колесо
		вставало на голубые двадцать тысяч, а выдавало две. Проверять это
		сверкой WheelAngleFor с раскладкой бесполезно — они согласованы между
		собой при любом знаке, ошибка живёт в самом повороте.
	]]
	local circle = math.pi * 2
	local target = math.rad(Props.WheelAngleFor(prizeIndex))

	--[[
		Довод до цели считается по остатку и потому всегда отрицателен: колесо
		крутится в одну сторону и не может «доехать назад». Полные обороты
		добавляются сверху — они ни на что не влияют, кроме зрелища.
	]]
	wheelFrom = wheelSpin % circle
	local approach = (target - wheelFrom) % circle - circle

	wheelTo = wheelFrom - circle * WHEEL_TURNS + approach
	wheelSpin = wheelFrom
	wheelLeft = Sounds.WheelSpinSeconds
end

--[[
	Обновить призовую тройку на подиуме.

	Данные те же, что у окна рекордов: список уже приходит клиенту, и второго
	канала ради трёх табличек заводить не нужно. Пустое место — прочерк, а не
	пустая табличка: пустая читается сломанной.
]]
function LobbyDecorController.SetLeaderboard(entries: { Types.LeaderboardEntry }): ()
	for index, label in plates do
		local entry = entries[index]
		if entry then
			local minutes = math.floor(entry.seconds / 60)
			local seconds = math.floor(entry.seconds % 60)
			-- Имя и время двумя строками: перенос собирается конкатенацией,
			-- внутри интерполяции он читался бы настоящим переводом строки.
			label.Text = `{index}. {entry.name}` .. "\n" .. string.format("%d:%02d", minutes, seconds)
		else
			label.Text = `{index}. —`
		end
	end
end

function LobbyDecorController.Start(): ()
	build()

	Net.GetEvent(Net.Id.RunStarted).OnClientEvent:Connect(function()
		paused = true
	end)

	Net.GetEvent(Net.Id.RunEnded).OnClientEvent:Connect(function()
		paused = false
	end)

	RunService.Heartbeat:Connect(onHeartbeat)
end

return LobbyDecorController
