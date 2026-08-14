--!strict
--[[
	FxForms — как выглядит каждая ФОРМА способности.

	Разделение простое: то, что выводится из состояния, клиент считает сам,
	а по сети идёт только то, что вывести нельзя.

		Orbit  — положение орбов полностью задаётся уровнем и фазой, а фаза
		         и так приходит в снимке для HUD. Ноль отдельного трафика.
		         Между снимками фаза крутится локально с той же скоростью,
		         поэтому орбы на экране совпадают с теми, что бьют на сервере.
		Aura   — кольцо радиусом из конфига, тоже чистое состояние.
		Nova   — момент вспышки предсказать нельзя, приходит событием.
		Projectile — рождение снаряда приходит событием, дальше он летит
		         по прямой, и клиент повторяет это точно.
		Cone, Chain — бьют мгновенно, приходят событием, рисуется только след.

	Урона здесь нет и быть не может: всё это чистая косметика.

	ЧЕМ ФОРМА ОТЛИЧАЕТСЯ ОТ СПОСОБНОСТИ. Форма отвечает за то, ЧТО происходит,
	и она одна на несколько способностей. Чем это нарисовано — берётся из поля
	fx конкретной способности: тело (модель из Config/Models), залп искр,
	ширина дуги. Тело есть у каждой из пятнадцати, и это проверяет валидатор
	Config/Abilities — поэтому запасного пути «способность без тела» здесь
	нет: он молча превращал бы новую способность в серый шар.

	Ни одной детали, ленты и излучателя модуль не создаёт сам — всё берётся
	у FxKit и возвращается туда же. Причина расписана в его шапке.

	Публичный API:
		FxForms.Begin(origin, quality)         -- начало забега
		FxForms.SetViews(views)               -- снимок состояния способностей
		FxForms.Spawn(kind, key, payload)     -- событие с сервера
		FxForms.Step(deltaTime, now, playerWorld)
		FxForms.ClearTransient()              -- гаснущее: пауза
		FxForms.Clear()                       -- всё: конец забега
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Abilities = require(Shared.Config.Abilities)
local Cards = require(Shared.Config.Cards)
local EnemyRenderController = require(script.Parent.Parent.Controllers.EnemyRenderController)
local FxKit = require(script.Parent.FxKit)
local LevelUpController = require(script.Parent.Parent.Controllers.LevelUpController)
local Palette = require(Shared.Config.Palette)
local PartModel = require(Shared.Util.PartModel)
local Types = require(Shared.Types)

type AbilityDef = Types.AbilityDef
type AbilityLevel = Types.AbilityLevel
type AbilityView = Types.AbilityView
type FxPayload = { { x: number, z: number, dx: number, dz: number } }

--[[
	ВОЛНА — общий механизм вспышки и клина.

	И то и другое — стена, уходящая от игрока наружу и растущая в размерах.
	Разница ровно в одном: у Nova она замкнута в кольцо, у Cone это дуга
	шириной в угол клина. Держать два похожих механизма врозь незачем: они
	разошлись бы при первой же правке, и «почему у клина волна оседает,
	а у вспышки нет» стало бы отдельным багом.

	Плоский круг, растущий по полу, читался белым блином: у него нет ни
	объёма, ни направления. Полосы веером у клина так полосами и читались.

	Начальный радиус не нулевой: в нуле все сегменты сходятся в точку,
	и первый кадр выглядит вспышкой в лицо.
]]
local WAVE_START = 1.5

-- Кольцу нужно пройти двадцать стадов так, чтобы глаз проследил путь;
-- клину — до тридцати четырёх, и он поэтому чуть быстрее.
local NOVA_TIME = 0.45
local NOVA_WALL = 3.5
local NOVA_THICK = 0.5

--[[
	Клин — не кусок кольца, а клинок.

	Кольцо Nova везде одинаковой высоты: удар расходится во все стороны, и
	выделять в нём нечего. У клина есть середина, и он обязан читаться лезвием
	— высоким и толстым по центру, сходящим на нет к краям. Отсюда профиль:
	доля высоты и толщины считается по положению отрезка в дуге.

	Показатель степени решает, насколько лезвие «пузатое». 0.6 даёт заметно
	выпуклую середину; единица дала бы ровный эллипс, а двойка — иглу.
]]
local CONE_TIME = 0.3
local CONE_WALL = 4.2
local CONE_THICK = 0.34
local CONE_TAPER = 0.6

--[[
	Сколько отрезков в дуге клина: считается по углу, а не задано числом.
	У клина в 110 градусов и у клина в 45 отрезки обязаны быть одной длины,
	иначе узкий выглядит гранёным, а широкий рваным.

	Шаг в восемь градусов, а не в двенадцать: отрезков должно хватить,
	чтобы лезвие успело сойти на нет. На четырёх остриё выглядит обрубленным.
]]
local CONE_ARC_STEP = 8
local CONE_ARC_MIN = 5
local CONE_ARC_MAX = 14

-- Сколько живёт узел цепи и её дуга: они не расширяются, а просто гаснут.
local FLASH_TIME = 0.22

--[[
	На сколько изломов бьётся звено цепи.

	Молния не летает по линейке. Прямая лента между двумя врагами — это палка,
	соединяющая их, и никаким цветом это не лечится; излом стоит двух лишних
	дуг на звено.
]]
local CHAIN_JAG = 3

--[[
	Сколько украшений едет по кольцу ауры и как быстро.

	Четыре, а не «по числу чего-нибудь»: границу очерчивает контур, украшения
	лишь показывают, что кольцо живое.
]]
local AURA_DECOR = 4
local AURA_SPEED = 0.55

--[[
	Из скольких зубцов набран контур ауры — то же число, что у кольца Nova
	(quality.waveSegments, Balance.Quality): и то и другое кольцо, различать
	их сегментами незачем. На High это двадцать четыре: на радиусе 10 это
	отрезки примерно по два стада, и кольцо читается кругом, а не
	многоугольником. Зубцы через один разной высоты — ровная лента выглядит
	забором, а рваная языками пламени.
]]

-- Высота, на которой идёт дуга цепи и висят её узлы.
local CHAIN_HEIGHT = 2.2

-- Насколько широко бьёт узел цепи. Своё число: сервер выбирает цель молнии
-- сам, и радиуса попадания у формы нет вовсе — есть дальность прыжка.
local CHAIN_HIT = 2.5

local FxForms = {}

local origin = Vector3.zero
local views: { AbilityView } = {}

-- Значение по умолчанию совпадает с High, тем же способом и по той же
-- причине, что в FxKit: ничего не должно рисоваться до первого Begin.
local quality: FxKit.Quality = { trails = true, sparks = true, waveSegments = 24 }

-- Собственная фаза кольца ауры: сервер её не считает и слать не может —
-- украшения не бьют, они только показывают границу.
local auraPhase = 0

--[[
	Выданное тело способности.

	Ключ модели хранится рядом с телом, чтобы вернуть его в свой пул,
	не отыскивая заново способность: список переживает и смену уровня,
	и её исчезновение, а ключ модели у выданного тела уже не спросишь.
]]
type Visual = {
	body: PartModel.Built,
	bodyKey: string,
}

-- Летящие снаряды: только для вида, поэтому состояние минимальное.
type Shard = {
	visual: Visual,
	position: Vector3,
	direction: Vector3,
	speed: number,
	life: number,
	hitRadius: number,
	flash: Color3,
}
local shards: { Shard } = {}

-- Кольца орбит и аур пересобираются каждый кадр из состояния.
local ringByKey: { [string]: { Visual } } = {}
local auraParts: { [string]: Part } = {}
local auraRingByKey: { [string]: { Part } } = {}

--[[
	Расходящаяся стена: кольцо у Nova, лезвие у Cone.

	start — угол левого края, span — насколько дуга широка. У кольца span
	равен полному обороту, и тогда края смыкаются сами.

	taper — насколько дуга сходит на нет к краям. Ноль означает ровную стену.

	Цвет хранится разложенным по тону, насыщенности и яркости: волна красится
	ОДНИМ цветом своей стихии, а разница между её частями и между началом
	и концом делается насыщенностью и яркостью. Два разных цвета читались бы
	двумя разными вещами, слипшимися в одну.
]]
type Wave = {
	parts: { Part },
	centre: Vector3,
	start: number,
	span: number,
	radius: number,
	wall: number,
	thickness: number,
	taper: number,
	life: number,
	startedAt: number,
	hue: number,
	saturation: number,
	value: number,
	-- Докуда волна дошла в прошлом кадре: вспышка попадания достаётся
	-- только тем, кого она задела ИМЕННО СЕЙЧАС, а не всем внутри круга.
	passed: number,
	flash: Color3,
}
local waves: { Wave } = {}

--[[
	Гаснущее: дуги цепи и тела мгновенных форм.

	Один список на обоих, потому что жизнь у них одинаковая — появиться,
	прожить свой срок и вернуться в пул. Разница только в том, что дуга
	гаснет прозрачностью, а тело гаснуть не умеет вовсе и просто исчезает
	в конце: оно живёт доли секунды, и затухание на нём никто не успел бы
	заметить.
]]
type Fade = {
	beam: FxKit.BeamRig?,
	body: PartModel.Built?,
	bodyKey: string?,
	pivot: CFrame?,
	startedAt: number,
	life: number,
	from: number, -- прозрачность в начале
}
local fades: { Fade } = {}

-- Залпы искр: держатся, пока не догорят их частицы.
type Burst = {
	rig: FxKit.BurstRig,
	startedAt: number,
}
local bursts: { Burst } = {}

--[[
	Характеристики для отрисовки по текущему уровню способности.

	Уровень ищется перебором: способностей у игрока единицы, а держать рядом
	второй индекс по ключу — это второе место, которое обязано совпадать
	с первым.
]]
local function statsFor(def: AbilityDef): AbilityLevel
	local level = 1
	for _, candidate in views do
		if candidate.key == def.key then
			level = candidate.level
			break
		end
	end
	return Abilities.VisualStats(def, level)
end

--[[
	Палитра тела: основной цвет — стихия, второй — ядро огонька, искры,
	голова ленты и остриё лезвия.

	ВТОРОЙ ЦВЕТ ПОКАЗЫВАЕТ РЕДКОСТЬ. Обычная карточка оставляет второй цвет
	стихии, а редкая, эпическая и легендарная зажигают ядро своим — и это
	единственное место, где взятая редкость вообще видна в бою. Отдельной
	каймы для этого не заводится: обводка на каждом орбе, снаряде и узле цепи
	— это три десятка Highlight в кадре, а движок рисует их до тридцати одного.

	Основной цвет не трогается никогда: стихию обязано быть видно всегда,
	иначе легендарный огонь перестанет быть огнём.
]]
local function tintsFor(def: AbilityDef): PartModel.Tints
	local rarity = LevelUpController.BestRarity(def.key)
	local accent = if rarity and rarity ~= Cards.Common.key
		then Cards.ColorFor(rarity)
		else Palette.ElementAccent[def.element]

	return PartModel.TintsFor(Palette.Element[def.element], accent)
end

-- Какой редкостью уже покрашено кольцо способности: перекрашивать каждый
-- кадр незачем, а взятая карточка обязана быть видна в тот же миг.
local tintedRarity: { [string]: string } = {}

--[[
	Взять тело способности.

	Приведение типов, а не проверка: тело есть у каждой способности, это
	обеспечивает валидатор Config/Abilities. Проверять здесь второй раз —
	значит заводить в бою ветку, которая не может выполниться.
]]
--[[
	Цвет вспышки попадания: цвет стихии, выбеленный наполовину.

	Чистый белый одинаков у всех шести и читается «врага задело чем-то»;
	цвет стихии без выбеливания теряется на самом враге, который тоже цветной.
	Считается один раз на стихию — это цвет, а не состояние.
]]
local flashColours: { [string]: Color3 } = {}

local function flashColour(element: Types.Element): Color3
	local existing = flashColours[element]
	if existing then
		return existing
	end

	local made = Palette.ElementAccent[element]:Lerp(Color3.new(1, 1, 1), 0.45)
	flashColours[element] = made
	return made
end

local function newBody(def: AbilityDef): Visual
	local fx = def.fx :: Types.AbilityFxDef
	local bodyKey = fx.body :: string
	local body = FxKit.GetBody(bodyKey, tintsFor(def))

	--[[
		Цвета назначаются и телу из пула: пул запомнил их при сборке, а с тех
		пор игрок мог взять легендарную карточку. Дешевле, чем разбираться,
		новое это тело или лежавшее.
	]]
	body.SetTints(tintsFor(def))
	return { body = body, bodyKey = bodyKey }
end

local function releaseVisual(visual: Visual): ()
	FxKit.ReleaseBody(visual.bodyKey, visual.body)
end

--[[
	Сколько тел этой способности уже создано. Прогрев, а не подсчёт живых:
	пул после возврата их не уничтожает.
]]
local warmedByKey: { [string]: number } = {}

--[[
	Создать тела заранее.

	Тело собирает PartModel, а это десяток Instance.new на штуку. Первое
	срабатывание цепи одиннадцатого звена создало бы одиннадцать тел разом
	посреди боя — ровно тот рывок, ради борьбы с которым заведён FxKit.

	Момент выбран сам собой: способность появляется в снимке на выборе
	карточки, то есть на паузе левел-апа, и число тел растёт там же, на рубеже.
	Взятое тут же возвращается — до отрисовки кадра оно снова невидимо.
]]
local function ensureBodies(def: AbilityDef, count: number): ()
	local have = warmedByKey[def.key] or 0
	if count <= have then
		return
	end
	warmedByKey[def.key] = count

	local warm = table.create(count - have)
	for index = 1, count - have do
		warm[index] = newBody(def)
	end
	for _, visual in warm do
		releaseVisual(visual)
	end
end

--[[
	Пивот тела, висящего в воздухе.

	Модель отсчитывает offset от пола, а орб и снаряд висят над ним: пивот
	опускается на половину высоты, иначе тело болталось бы над собственной
	траекторией на всю свою высоту.
]]
local function hoverPivot(visual: Visual, position: Vector3): CFrame
	return CFrame.new(position - Vector3.new(0, visual.body.Height() * 0.5, 0))
end

-- Скорость нулевая: канал step телу эффекта не нужен, ногами оно не перебирает.
local function drawVisual(visual: Visual, pivot: CFrame, deltaTime: number): ()
	visual.body.Draw(pivot, deltaTime, 0)
end

local function addFade(entry: Fade): ()
	table.insert(fades, entry)
end

local function addBurst(def: AbilityDef, position: Vector3): ()
	local fx = def.fx
	local count = if fx then fx.burst else nil
	if not count then
		return
	end

	-- На Low FxKit.Burst не создаёт залп и возвращает nil — тогда и запоминать
	-- в bursts нечего, эффект просто не рисуется.
	local rig = FxKit.Burst(position, Palette.ElementAccent[def.element], count)
	if not rig then
		return
	end

	table.insert(bursts, {
		rig = rig,
		startedAt = os.clock(),
	})
end

--[[
	Тело мгновенной формы: появляется на месте удара и живёт свой срок.

	Пивот отдаётся вызывающим целиком, вместе с разворотом: столб вспышки
	стоит на полу прямо, клин смотрит туда же, куда бьёт, а узел цепи —
	туда, где оказался враг.
]]
local function addFlashBody(def: AbilityDef, pivot: CFrame, life: number): ()
	local visual = newBody(def)

	addFade({
		body = visual.body,
		bodyKey = visual.bodyKey,
		pivot = pivot,
		startedAt = os.clock(),
		life = life,
		from = 0,
	})
end

local function getAura(key: string, element: Types.Element): Part
	local existing = auraParts[key]
	if existing then
		return existing
	end

	local part = FxKit.Get(Enum.PartType.Cylinder)
	part.Color = Palette.Element[element]
	--[[
		Заливка почти прозрачна. Аура радиусом в двадцать стадов — это круг
		на пол-экрана, и залитый даже вполсилы он закрывает собой и врагов,
		и кристаллы, и всё, что игрок обязан видеть. Область показывает
		контур, а заливка только подсказывает, что она есть.

		Материал обычный, а не неон: неон не темнеет от прозрачности и светит
		на 0.93 почти так же, как на нуле, — прозрачность на нём не работает.
	]]
	part.Material = Enum.Material.SmoothPlastic
	part.Transparency = 0.93
	auraParts[key] = part
	return part
end

--[[
	Контур ауры: венец из коротких отрезков по самому краю радиуса.

	Крутится вместе с украшениями — неподвижное кольцо на земле выглядит
	нарисованным на полу, а не принадлежащим игроку.
]]
local function stepAuraRing(key: string, element: Types.Element, radius: number, centre: Vector3): ()
	local ring = auraRingByKey[key]
	if not ring then
		ring = {}
		auraRingByKey[key] = ring
	end

	local step = math.pi * 2 / quality.waveSegments
	-- Длина зубца — хорда с нахлёстом: без него между зубцами видны просветы,
	-- и кольцо читается пунктиром, а не кольцом.
	local chord = 2 * radius * math.sin(step * 0.5) * 1.08

	for index = 1, quality.waveSegments do
		local tall = index % 2 == 0

		local part = ring[index]
		if not part then
			part = FxKit.Get(Enum.PartType.Block)
			part.Color = if tall then Palette.ElementAccent[element] else Palette.Element[element]
			part.Transparency = 0.12
			ring[index] = part
		end

		local height = if tall then 0.95 else 0.5
		local angle = auraPhase + step * (index - 1)
		local x, z = math.cos(angle), math.sin(angle)

		part.Size = Vector3.new(chord, height, 0.28)
		-- Зубец стоит поперёк радиуса: его длина идёт по касательной,
		-- иначе кольцо превращается в звезду из спиц.
		part.CFrame = CFrame.new(centre.X + x * radius, centre.Y + height * 0.5, centre.Z + z * radius)
			* CFrame.Angles(0, math.atan2(-x, -z), 0)
	end
end

local function releaseAuraRing(key: string): ()
	local ring = auraRingByKey[key]
	if not ring then
		return
	end

	for _, part in ring do
		FxKit.Release(part)
	end
	auraRingByKey[key] = nil
end

--[[
	Кольцо одинаковых частей вокруг игрока: орбы орбиты и украшения ауры.

	Одна функция на обе формы, потому что задача у них одна — разложить
	по окружности ровно столько частей, сколько нужно в этом кадре, и вернуть
	лишние. Разное у них только то, откуда берётся фаза и стоят ли части
	на полу.
]]
local function stepRing(
	def: AbilityDef,
	count: number,
	radius: number,
	phase: number,
	centre: Vector3,
	deltaTime: number,
	grounded: boolean,
	flashRadius: number?
): ()
	local ring = ringByKey[def.key]
	if not ring then
		ring = {}
		ringByKey[def.key] = ring
	end

	--[[
		Взятая редкость меняет второй цвет тела. Кольцо живёт весь забег,
		поэтому смену надо не только учесть при выдаче, но и донести до тех,
		кто уже летает.
	]]
	local rarity = LevelUpController.BestRarity(def.key) or Cards.Common.key
	if tintedRarity[def.key] ~= rarity then
		tintedRarity[def.key] = rarity
		local tints = tintsFor(def)
		for _, visual in ring do
			visual.body.SetTints(tints)
		end
	end

	local step = math.pi * 2 / count

	for index = 1, count do
		local visual = ring[index]
		if not visual then
			visual = newBody(def)
			ring[index] = visual
		end

		local angle = phase + step * (index - 1)
		local position = Vector3.new(centre.X + math.cos(angle) * radius, centre.Y, centre.Z + math.sin(angle) * radius)

		drawVisual(visual, if grounded then CFrame.new(position) else hoverPivot(visual, position), deltaTime)

		--[[
			Орб жжёт всё, обо что трётся. Украшениям ауры радиус не передают
			вовсе: аура бьёт по всей области каждые полсекунды, и вспышка
			на всей толпе разом — это уже не отклик, а мигание экрана.
		]]
		--[[
			Отскока у орба нет намеренно (последний аргумент). Вспышка зовётся
			здесь каждый кадр, пока орб летит, а отскок рассчитан на одиночное
			попадание: складываясь кадр за кадром, он уводил врага на метры,
			причём в сторону от орба — то есть половину круга ПРЯМО НА игрока.
			Толпа выглядела притянутой вплотную, хотя на сервере никто никуда
			не двигался.
		]]
		if flashRadius then
			EnemyRenderController.Flash(position - origin, 0, flashRadius, flashColour(def.element), nil, nil, false)
		end
	end

	for index = #ring, count + 1, -1 do
		releaseVisual(ring[index])
		ring[index] = nil :: any
	end
end

local function stepStateDriven(deltaTime: number, playerWorld: Vector3): ()
	local seenRings: { [string]: boolean } = {}
	local seenAuras: { [string]: boolean } = {}

	auraPhase = (auraPhase + AURA_SPEED * deltaTime) % (math.pi * 2)

	for _, view in views do
		local def = Abilities.ByKey[view.key]
		if not def then
			continue
		end
		local data = Abilities.VisualStats(def, view.level)

		--[[
			Сколько тел этой способности бывает на арене разом. У орбиты это
			орбы, у снаряда — залп, у цепи — узлы на всех врагах звена;
			у ауры число своё, а мгновенной вспышке хватает одного.
		]]
		local shape = def.shape
		if shape == "Orbit" or shape == "Projectile" or shape == "Chain" then
			ensureBodies(def, data.count :: number)
		elseif shape == "Aura" then
			ensureBodies(def, AURA_DECOR)
		else
			ensureBodies(def, 1)
		end

		if def.shape == "Orbit" then
			-- Фаза из снимка докручивается локально: между снимками 0.1 с,
			-- за которые орб уходит заметно далеко.
			view.phase = (view.phase + (data.angularSpeed :: number) * deltaTime) % (math.pi * 2)

			seenRings[view.key] = true
			stepRing(
				def,
				data.count :: number,
				data.radius :: number,
				view.phase,
				playerWorld,
				deltaTime,
				false,
				data.hitRadius :: number
			)
		elseif def.shape == "Aura" then
			seenAuras[view.key] = true
			local radius = data.radius :: number

			local part = getAura(view.key, def.element)
			part.Size = Vector3.new(0.3, radius * 2, radius * 2)
			part.CFrame = CFrame.new(playerWorld.X, 0.5, playerWorld.Z) * CFrame.Angles(0, 0, math.rad(90))

			-- Контур и украшения стоят на полу арены, а не на высоте игрока:
			-- аура лежит на земле, и висящие в воздухе шипы к ней не относятся.
			local ground = Vector3.new(playerWorld.X, origin.Y, playerWorld.Z)
			stepAuraRing(view.key, def.element, radius, ground)

			seenRings[view.key] = true
			stepRing(def, AURA_DECOR, radius, auraPhase, ground, deltaTime, true)
		end
	end

	-- Способность пропала целиком (конец забега разобран отдельно).
	for key, ring in ringByKey do
		if not seenRings[key] then
			for _, visual in ring do
				releaseVisual(visual)
			end
			ringByKey[key] = nil
		end
	end

	for key, part in auraParts do
		if not seenAuras[key] then
			FxKit.Release(part)
			auraParts[key] = nil
			releaseAuraRing(key)
		end
	end
end

local function stepShards(deltaTime: number): ()
	local index = 1
	while index <= #shards do
		local shard = shards[index]
		shard.life -= deltaTime

		if shard.life <= 0 then
			releaseVisual(shard.visual)
			shards[index] = shards[#shards]
			shards[#shards] = nil :: any
		else
			shard.position += shard.direction * (shard.speed * deltaTime)

			-- Перёд модели — в сторону -Z, туда же смотрит lookAt: остриё
			-- обязано смотреть вперёд, а не вбок.
			local visual = shard.visual
			local pivot = hoverPivot(visual, origin + shard.position + Vector3.new(0, 2.5, 0))
			drawVisual(visual, CFrame.lookAt(pivot.Position, pivot.Position + shard.direction), deltaTime)

			-- Снаряд пробивает толпу насквозь, поэтому вспышка достаётся
			-- каждому, мимо кого он прошёл, а не первому встречному.
			EnemyRenderController.Flash(shard.position, 0, shard.hitRadius, shard.flash)
			index += 1
		end
	end
end

local function stepFades(now: number, deltaTime: number): ()
	local index = 1
	while index <= #fades do
		local fade = fades[index]
		local progress = (now - fade.startedAt) / fade.life

		if progress >= 1 then
			local beam = fade.beam
			if beam then
				FxKit.ReleaseBeam(beam)
			end

			local body, bodyKey = fade.body, fade.bodyKey
			if body and bodyKey then
				FxKit.ReleaseBody(bodyKey, body)
			end

			fades[index] = fades[#fades]
			fades[#fades] = nil :: any
		else
			local beam = fade.beam
			if beam then
				beam.beam.Transparency = NumberSequence.new(fade.from + (1 - fade.from) * progress)
			end

			local body, pivot = fade.body, fade.pivot
			if body and pivot then
				body.Draw(pivot, deltaTime, 0)
			end

			index += 1
		end
	end
end

local function stepBursts(now: number): ()
	local index = 1
	while index <= #bursts do
		local burst = bursts[index]
		if now - burst.startedAt >= FxKit.BurstLife then
			FxKit.ReleaseBurst(burst.rig)
			bursts[index] = bursts[#bursts]
			bursts[#bursts] = nil :: any
		else
			index += 1
		end
	end
end

local function stepWaves(now: number): ()
	local index = 1
	while index <= #waves do
		local wave = waves[index]
		local progress = (now - wave.startedAt) / wave.life

		if progress >= 1 then
			for _, part in wave.parts do
				FxKit.Release(part)
			end
			waves[index] = waves[#waves]
			waves[#waves] = nil :: any
		else
			--[[
				Волна замедляется к краю: равномерное расширение читается
				растущим кругом, а с затуханием — ударом, который выдохся.
			]]
			local eased = 1 - (1 - progress) * (1 - progress)
			local radius = WAVE_START + (wave.radius - WAVE_START) * eased
			local count = #wave.parts
			local step = wave.span / count
			-- Хорда растёт вместе с радиусом сама: дуга расширяется ровно
			-- потому, что уходит дальше, а угол у неё свой и не меняется.
			local chord = 2 * radius * math.sin(step * 0.5) * 1.06
			local transparency = 0.1 + 0.9 * progress
			-- Стена оседает по мере ухода: волна выдыхается, а не обрывается.
			local settle = 1 - 0.35 * progress
			local centre = wave.centre

			--[[
				Уходящая волна густеет и темнеет: цвет тот же, но насыщенность
				растёт, а яркость падает. Так волна остывает, а не просто тает.
			]]
			local saturation = math.clamp(wave.saturation * (1 + 0.3 * progress), 0, 1)
			local value = wave.value * (1 - 0.25 * progress)

			--[[
				Волна задевает врагов по мере ухода: вспышка достаётся кольцу
				между тем, где стена была в прошлом кадре, и тем, где она
				сейчас. Круг целиком дал бы засветку всей области с первого
				кадра, и волна перестала бы читаться идущей.

				У кольца сектора нет, и угол не передаётся вовсе.
			]]
			local sector = wave.span < math.pi * 2
			EnemyRenderController.Flash(
				wave.centre - origin,
				wave.passed,
				radius,
				wave.flash,
				if sector then wave.start else nil,
				if sector then wave.span else nil
			)
			wave.passed = radius

			for segment, part in wave.parts do
				local angle = wave.start + step * (segment - 0.5)
				local x, z = math.cos(angle), math.sin(angle)

				--[[
					Профиль лезвия: доля от полной высоты по положению отрезка
					в дуге. У кольца taper нулевой, и профиль везде единица.
				]]
				local profile = 1
				if wave.taper > 0 then
					local across = (segment - 0.5) / count * 2 - 1
					profile = (1 - across * across) ^ wave.taper
				end

				local height = wave.wall * profile * settle
				part.Size = Vector3.new(chord, height, wave.thickness * (0.4 + 0.6 * profile))
				part.Transparency = transparency
				-- Середина лезвия раскалена: там ярче и бледнее, к остриям
				-- цвет густеет. У кольца профиль ровный, и разницы нет.
				part.Color = Color3.fromHSV(
					wave.hue,
					math.clamp(saturation * (1.2 - 0.35 * profile), 0, 1),
					math.clamp(value * (0.78 + 0.3 * profile), 0, 1)
				)
				part.CFrame = CFrame.new(centre.X + x * radius, centre.Y + height * 0.5, centre.Z + z * radius)
					* CFrame.Angles(0, math.atan2(-x, -z), 0)
			end

			index += 1
		end
	end
end

--[[
	Пустить волну.

	Цвет не задаётся: он весь выводится из стихии и раскладывается по HSV
	один раз здесь, а разница между частями волны и между её началом и концом
	делается насыщенностью и яркостью в stepWaves.
]]
type WaveSpec = {
	centre: Vector3,
	start: number,
	span: number,
	segments: number,
	radius: number,
	wall: number,
	thickness: number,
	taper: number,
	life: number,
}

local function addWave(def: AbilityDef, spec: WaveSpec): ()
	local parts = table.create(spec.segments)
	for segment = 1, spec.segments do
		parts[segment] = FxKit.Get(Enum.PartType.Block)
	end

	local hue, saturation, value = Palette.Element[def.element]:ToHSV()

	table.insert(waves, {
		passed = WAVE_START,
		flash = flashColour(def.element),
		parts = parts,
		centre = spec.centre,
		start = spec.start,
		span = spec.span,
		radius = spec.radius,
		wall = spec.wall,
		thickness = spec.thickness,
		taper = spec.taper,
		life = spec.life,
		startedAt = os.clock(),
		hue = hue,
		saturation = saturation,
		value = value,
	})
end

local function spawnShards(def: AbilityDef, payload: FxPayload): ()
	local data = statsFor(def)

	for _, entry in payload do
		table.insert(shards, {
			visual = newBody(def),
			hitRadius = data.hitRadius :: number,
			flash = flashColour(def.element),
			position = Vector3.new(entry.x, 0, entry.z),
			direction = Vector3.new(entry.dx, 0, entry.dz),
			speed = data.speed :: number,
			life = data.lifetime :: number,
		})
	end
end

local function spawnNova(def: AbilityDef, payload: FxPayload): ()
	local entry = payload[1]
	if not entry then
		return
	end

	local data = statsFor(def)
	local centre = origin + Vector3.new(entry.x, 0, entry.z)

	-- Кольцо: полный оборот, края смыкаются сами, стена везде одной высоты.
	addWave(def, {
		centre = centre,
		start = 0,
		span = math.pi * 2,
		segments = quality.waveSegments,
		radius = data.radius :: number,
		wall = NOVA_WALL,
		thickness = NOVA_THICK,
		taper = 0,
		life = NOVA_TIME,
	})

	-- Столб бьёт из земли, поэтому пивот стоит на полу, а не опускается
	-- на половину высоты, как у висящего орба.
	addFlashBody(def, CFrame.new(centre), NOVA_TIME)
	addBurst(def, centre + Vector3.new(0, 1, 0))
end

--[[
	Клин Cone: дуга, вылетающая из игрока.

	Ни заливки, ни лучей по краям. Дуга уходит от игрока и расширяется —
	расширяется сама, потому что её угол постоянен, а радиус растёт, —
	и доходит ровно до дальней границы клина. Тем же механизмом, что кольцо
	Nova: там полный оборот, здесь сектор.

	Лучи по краям убраны намеренно: они выходили из самого персонажа
	и торчали сквозь него белыми палками.
]]
local function spawnCone(def: AbilityDef, payload: FxPayload): ()
	local entry = payload[1]
	if not entry then
		return
	end

	local data = statsFor(def)
	local length = data.radius :: number
	local angle = math.rad(data.angle :: number)
	local centre = origin + Vector3.new(entry.x, 0, entry.z)

	--[[
		Угол в системе координат волны: там точка на окружности — это
		(cos, sin) по мировым осям. У прежних полос знак Z был обратный,
		потому что деталь разворачивали через yaw.
	]]
	local heading = math.atan2(entry.dz, entry.dx)
	local segments = math.clamp(math.round(math.deg(angle) / CONE_ARC_STEP), CONE_ARC_MIN, CONE_ARC_MAX)

	addWave(def, {
		centre = centre,
		start = heading - angle * 0.5,
		span = angle,
		segments = segments,
		radius = length,
		wall = CONE_WALL,
		thickness = CONE_THICK,
		taper = CONE_TAPER,
		life = CONE_TIME,
	})

	-- Направление с сервера уже единичное (aimDirection), поэтому нормировать
	-- его тут нечем и незачем: нулевой вектор уронил бы lookAt.
	local direction = Vector3.new(entry.dx, 0, entry.dz)
	addFlashBody(def, CFrame.lookAt(centre, centre + direction), FLASH_TIME)
	addBurst(def, centre + Vector3.new(0, 1.2, 0) + direction * (length * 0.45))
end

--[[
	Цепь: дуга на каждое звено и узел на каждом враге, куда она прыгнула.

	В полях направления лежит ПОЛНЫЙ вектор до следующего звена, а не единичный
	(см. tickChain на сервере), поэтому конец звена берётся прямо из него.
]]
local function spawnChain(def: AbilityDef, payload: FxPayload): ()
	local fx = def.fx
	local width = (if fx then fx.beam else nil) or 0.5
	local head = Palette.Element[def.element]
	local tail = Palette.ElementAccent[def.element]
	local now = os.clock()

	for _, entry in payload do
		local length = math.sqrt(entry.dx * entry.dx + entry.dz * entry.dz)
		if length <= 0.1 then
			continue
		end

		local from = origin + Vector3.new(entry.x, CHAIN_HEIGHT, entry.z)
		local to = origin + Vector3.new(entry.x + entry.dx, CHAIN_HEIGHT, entry.z + entry.dz)

		--[[
			Излом. Середины звена уводятся вбок по перпендикуляру, стороны
			чередуются, величина случайна — повторяющийся зигзаг одинаковой
			амплитуды читается пилой, а не молнией.
		]]
		local perpendicular = Vector3.new(-entry.dz, 0, entry.dx) / length
		local previous = from

		for index = 1, CHAIN_JAG do
			local point = to
			if index < CHAIN_JAG then
				local side = if index % 2 == 0 then 1 else -1
				local shift = length * 0.08 * side * (0.6 + math.random() * 0.8)
				point = from:Lerp(to, index / CHAIN_JAG) + perpendicular * shift
			end

			addFade({
				beam = FxKit.GetBeam(previous, point, width, head, tail),
				startedAt = now,
				life = FLASH_TIME,
				from = 0,
			})
			previous = point
		end

		local landing = Vector3.new(entry.x + entry.dx, 0, entry.z + entry.dz)
		EnemyRenderController.Flash(landing, 0, CHAIN_HIT, flashColour(def.element))

		local node = origin + landing
		addFlashBody(def, CFrame.new(node), FLASH_TIME)
		addBurst(def, node + Vector3.new(0, CHAIN_HEIGHT, 0))
	end
end

function FxForms.Begin(value: Vector3, fxQuality: FxKit.Quality): ()
	origin = value
	quality = fxQuality
end

function FxForms.SetViews(value: { AbilityView }): ()
	views = value
end

function FxForms.Spawn(kind: string, key: string, payload: FxPayload): ()
	local def = Abilities.ByKey[key]
	if not def then
		return
	end

	if kind == "Projectile" then
		spawnShards(def, payload)
	elseif kind == "Cone" then
		spawnCone(def, payload)
	elseif kind == "Chain" then
		spawnChain(def, payload)
	elseif kind == "Nova" then
		spawnNova(def, payload)
	end
end

function FxForms.Step(deltaTime: number, now: number, playerWorld: Vector3?): ()
	stepShards(deltaTime)
	stepWaves(now)
	stepFades(now, deltaTime)
	stepBursts(now)

	if playerWorld then
		stepStateDriven(deltaTime, playerWorld)
	end
end

--[[
	Гаснущее: расходящиеся волны, следы мгновенных форм и залпы искр.

	Отдельно от Clear, потому что снимается на паузе: эти эффекты привязаны
	к абсолютному времени и после снятия паузы схлопнулись бы мгновенно.
]]
function FxForms.ClearTransient(): ()
	for _, wave in waves do
		for _, part in wave.parts do
			FxKit.Release(part)
		end
	end
	table.clear(waves)

	for _, fade in fades do
		local beam = fade.beam
		if beam then
			FxKit.ReleaseBeam(beam)
		end

		local body, bodyKey = fade.body, fade.bodyKey
		if body and bodyKey then
			FxKit.ReleaseBody(bodyKey, body)
		end
	end
	table.clear(fades)

	for _, burst in bursts do
		FxKit.ReleaseBurst(burst.rig)
	end
	table.clear(bursts)
end

function FxForms.Clear(): ()
	FxForms.ClearTransient()

	for key, ring in ringByKey do
		for _, visual in ring do
			releaseVisual(visual)
		end
		ringByKey[key] = nil
	end
	table.clear(tintedRarity)

	for key, part in auraParts do
		FxKit.Release(part)
		auraParts[key] = nil
		releaseAuraRing(key)
	end

	for _, shard in shards do
		releaseVisual(shard.visual)
	end
	table.clear(shards)

	table.clear(views)
end

return FxForms
