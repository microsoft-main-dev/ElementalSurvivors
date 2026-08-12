--!strict
--[[
	Props — предметы лобби из примитивов: портал, яйца, колесо, деревья.

	Тип у них тот же, что у моделей боссов (Types.ModelDef), и собирает их тот
	же Shared/Util/PartModel. Отдельный файл, а не запись в Config/Models,
	по двум причинам: у предмета лобби нет боевого радиуса, с которым сверяется
	пятно, и деталей ему можно заметно больше — он стоит один и не бежит
	в толпе из трёхсот тел.

	КТО ИХ СТРОИТ. Только клиент (Client/Controllers/LobbyDecorController).
	Это не про репликацию статики — она уезжает один раз при входе, — а про
	АНИМАЦИЮ: крутящееся на сервере колесо слало бы CFrame двадцати игрокам
	каждый кадр, а на клиенте это стоит ноль трафика. Заодно каждый видит своё
	колесо, что и правильно: прокрутка личная.

	Отсюда жёсткое правило: всё, во что игрок упирается или что он нажимает,
	остаётся на сервере (LobbyService). ProximityPrompt, созданный клиентом,
	до сервера не доедет вовсе, поэтому промпты висят на серверных деталях,
	а декор только стоит рядом.

	ЦВЕТА только ручные: стихии у предмета лобби нет, tint здесь запрещён
	валидатором. Имя ищется сначала в Palette.Detail, потом в Palette.Lobby —
	камень и кость общие со всей игрой, а зелень портала принадлежит лобби,
	и дублировать её ради одной таблицы незачем.

	Публичный API:
		Props.ByKey        -- модели по ключу
		Props.Placements   -- что где стоит в лобби
]]

local Balance = require(script.Parent.Balance)
local Branding = require(script.Parent.Branding)
local Eggs = require(script.Parent.Eggs)
local Palette = require(script.Parent.Palette)
local RNG = require(script.Parent.Parent.Util.RNG)
local Types = require(script.Parent.Parent.Types)

type ModelDef = Types.ModelDef
type ModelPartDef = Types.ModelPartDef

local Props = {}

--[[
	Потолок деталей на предмет.

	Поднят до 400 под воксельные яйца. Обычному хватает 158, но вертикальное
	ребро режет каждый ряд натрое, и золотое стоит 317. Предмет лобби это
	выдерживает: он стоит один и не соревнуется за кадр с толпой врагов.
]]
local MAX_PARTS = 400

--[[
	Где предмет стоит в лобби и куда смотрит.

	yaw в градусах вокруг вертикали. Перёд модели — в сторону -Z (как у всего
	остального в проекте), поэтому предмету, который должен смотреть на центр
	лобби с севера, нужен разворот на 180.
]]
--[[
	Точка взаимодействия: невидимый объём с промптом, который строит сервер.

	Живёт рядом с расстановкой намеренно. Промпт обязан висеть на СЕРВЕРНОЙ
	детали (созданный клиентом до сервера не доедет), а видимую вещь рисует
	клиент — и если координаты этих двух считать в разных файлах, они разойдутся
	ровно тогда, когда планировку тронут. Так уже было до перехода на круглую
	площадь: LobbyService считал те же точки своим кодом.
]]
export type Anchor = {
	name: string,
	position: Vector3, -- центр основания, y = 0 — пол
	size: Vector3,
	yaw: number,
	objectText: string,
	panel: string,
	target: string?, -- какое яйцо, для ряда яиц
}

export type Placement = {
	key: string,
	position: Vector3,
	yaw: number,
	--[[
		Покачивание предмета ЦЕЛИКОМ: студы размаха и качаний в секунду.

		Стоит здесь, а не каналом bob у каждой детали. Причина не в экономии
		строк: bob качает деталь отдельно от соседей, и яйцо из четырёх
		ярусов развалилось бы на четыре качающихся блина. Качать надо весь
		предмет разом, а это его положение, то есть placement.
	]]
	bob: number?,
	bobSpeed: number?,
	--[[
		Имя, по которому предмет находит контроллер. Нужно тем, кем управляет
		механика, а не время: диском колеса и его лампами. Остальным не нужно
		вовсе — они живут сами.
	]]
	id: string?,
}

local definitions: { ModelDef } = {
	--[[
		Portal — арка входа в забег.

		По референсу владельца: тяжёлая каменная арка с двумя статуями в
		капюшонах на колоннах, перекладина с костяным гербом и светящаяся
		поверхность между колоннами.

		Светится ровно три вещи: сама поверхность, её ядро и по огоньку над
		каждой статуей. Все три дышат каналом glow с разной скоростью —
		синхронное мигание читается как перерисовка экрана, а не как огонь.

		Портал стоит на -Z и смотрит на центр лобби, то есть ставится
		с разворотом на 180 (см. Placements).
	]]
	{
		key = "Portal",
		parts = {
			-- Ступень перед аркой: без неё колонны просто воткнуты в пол.
			{
				shape = "Block",
				size = Vector3.new(26, 0.8, 6),
				offset = Vector3.new(0, 0.4, -1),
				color = "stone",
			},
			{
				shape = "Block",
				size = Vector3.new(5, 3, 5),
				offset = Vector3.new(-9, 1.5, 0),
				color = "stoneDark",
			},
			{
				shape = "Block",
				size = Vector3.new(5, 3, 5),
				offset = Vector3.new(9, 1.5, 0),
				color = "stoneDark",
			},
			{
				shape = "Block",
				size = Vector3.new(3.6, 15, 3.6),
				offset = Vector3.new(-9, 10.5, 0),
				color = "stone",
			},
			{
				shape = "Block",
				size = Vector3.new(3.6, 15, 3.6),
				offset = Vector3.new(9, 10.5, 0),
				color = "stone",
			},
			{
				shape = "Block",
				size = Vector3.new(5, 1.6, 5),
				offset = Vector3.new(-9, 18.8, 0),
				color = "stoneDark",
			},
			{
				shape = "Block",
				size = Vector3.new(5, 1.6, 5),
				offset = Vector3.new(9, 18.8, 0),
				color = "stoneDark",
			},
			-- Статуи: тело, капюшон, провал лица. Лицо — не морда, а тень
			-- под капюшоном: черты на такой высоте всё равно не читаются,
			-- а тёмный провал читается с любого расстояния.
			{
				shape = "Block",
				size = Vector3.new(3, 3.4, 2.6),
				offset = Vector3.new(-9, 21.3, 0),
				color = "stone",
			},
			{
				shape = "Block",
				size = Vector3.new(3, 3.4, 2.6),
				offset = Vector3.new(9, 21.3, 0),
				color = "stone",
			},
			{
				shape = "Ball",
				size = Vector3.new(3.2, 3, 3.2),
				offset = Vector3.new(-9, 23.2, 0.2),
				color = "stoneDark",
			},
			{
				shape = "Ball",
				size = Vector3.new(3.2, 3, 3.2),
				offset = Vector3.new(9, 23.2, 0.2),
				color = "stoneDark",
			},
			{
				shape = "Block",
				size = Vector3.new(1.6, 1.4, 0.6),
				offset = Vector3.new(-9, 23, -1.5),
				color = "shadow",
			},
			{
				shape = "Block",
				size = Vector3.new(1.6, 1.4, 0.6),
				offset = Vector3.new(9, 23, -1.5),
				color = "shadow",
			},
			{
				shape = "Ball",
				size = Vector3.new(2, 2, 2),
				offset = Vector3.new(-9, 25.6, 0),
				color = "portalGlow",
				neon = true,
				anim = "glow",
				animSpeed = 0.45,
				animAmount = 0.25,
			},
			{
				shape = "Ball",
				size = Vector3.new(2, 2, 2),
				offset = Vector3.new(9, 25.6, 0),
				color = "portalGlow",
				neon = true,
				anim = "glow",
				animSpeed = 0.6,
				animAmount = 0.25,
			},
			{
				shape = "Block",
				size = Vector3.new(24, 2.6, 4),
				offset = Vector3.new(0, 20.5, 0),
				color = "stone",
			},
			{
				shape = "Block",
				size = Vector3.new(26, 1, 5),
				offset = Vector3.new(0, 22.3, 0),
				color = "stoneDark",
			},
			-- Костяной герб с рогами: то, что на референсе висит по центру
			-- перекладины и делает арку воротами, а не рамой.
			{
				shape = "Block",
				size = Vector3.new(4, 3, 1.2),
				offset = Vector3.new(0, 22.2, -2),
				color = "bone",
			},
			{
				shape = "Block",
				mesh = "Wedge",
				size = Vector3.new(1, 2, 1),
				offset = Vector3.new(-2.4, 23.4, -1.8),
				angles = Vector3.new(0, 0, 25),
				color = "bone",
			},
			{
				shape = "Block",
				mesh = "Wedge",
				size = Vector3.new(1, 2, 1),
				offset = Vector3.new(2.4, 23.4, -1.8),
				angles = Vector3.new(0, 0, -25),
				color = "bone",
			},
			--[[
				Сама поверхность и её ядро. Полупрозрачны обе, и дышат в
				разном темпе: именно рассинхрон двух слоёв читается как
				«там что-то есть», а один слой — как крашеная доска.
			]]
			{
				shape = "Block",
				size = Vector3.new(14.4, 17, 0.6),
				offset = Vector3.new(0, 9.5, 0),
				color = "portal",
				neon = true,
				transparency = 0.35,
				anim = "glow",
				animSpeed = 0.3,
				animAmount = 0.15,
			},
			{
				shape = "Block",
				size = Vector3.new(10, 13, 0.4),
				offset = Vector3.new(0, 9.2, -0.3),
				color = "portalGlow",
				neon = true,
				transparency = 0.55,
				anim = "glow",
				animSpeed = 0.22,
				animAmount = 0.2,
			},
		},
		footprint = 0,
		height = 0,
	},

	--[[
		EggStand — подставка под яйцо: каменная тумба в три яруса.

		Коллизия у неё серверная и невидимая (LobbyService): промпт обязан
		висеть на серверной детали, а видимую тумбу дешевле нарисовать здесь,
		чем реплицировать её ярусы двадцати игрокам.
	]]
	{
		key = "EggStand",
		parts = {
			{
				shape = "Block",
				size = Vector3.new(6, 0.8, 6),
				offset = Vector3.new(0, 0.4, 0),
				color = "stoneDark",
			},
			{
				shape = "Block",
				size = Vector3.new(4.4, 2, 4.4),
				offset = Vector3.new(0, 1.6, 0),
				color = "stone",
			},
			{
				shape = "Block",
				size = Vector3.new(6, 0.6, 6),
				offset = Vector3.new(0, 2.9, 0),
				color = "stoneDark",
			},
		},
		footprint = 0,
		height = 0,
	},

	--[[
		WheelStand — стойка колеса: основание, два столба, ступица и указатель.

		Указатель сверху, а не сбоку: сектор, на котором колесо встало, обязан
		читаться с одного взгляда, а верхняя точка — единственная, которую
		видно с любого места перед колесом.
	]]
	{
		key = "WheelStand",
		parts = {
			{
				shape = "Block",
				size = Vector3.new(12, 1.4, 7),
				offset = Vector3.new(0, 0.7, 0),
				color = "stoneDark",
			},
			{
				shape = "Block",
				size = Vector3.new(1.8, 14.4, 1.8),
				offset = Vector3.new(-4.6, 8.2, 1.2),
				color = "stone",
			},
			{
				shape = "Block",
				size = Vector3.new(1.8, 14.4, 1.8),
				offset = Vector3.new(4.6, 8.2, 1.2),
				color = "stone",
			},
			-- Ступица: ромб на оси. Не вращается вместе с диском намеренно —
			-- вращающийся центр не добавляет движения, а мешает его заметить.
			{
				shape = "Block",
				size = Vector3.new(2.6, 2.6, 1),
				offset = Vector3.new(0, 15, -1.6),
				angles = Vector3.new(0, 0, 45),
				color = "steel",
			},
			--[[
				Указатель — ступенчатый треугольник из четырёх полос, а не клин.

				Клин в Roblox ориентируется мешем, и предсказать, куда смотрит
				его остриё, нельзя: на капюшоне шамана мы это уже проходили.
				Ступенями остриё смотрит туда, куда его сложили, и заодно
				совпадает по стилю с секторами и яйцами.
			]]
			{
				shape = "Block",
				size = Vector3.new(3.2, 0.7, 1.2),
				offset = Vector3.new(0, 25.4, -1.6),
				color = "eggGem",
				neon = true,
			},
			{
				shape = "Block",
				size = Vector3.new(2.4, 0.7, 1.2),
				offset = Vector3.new(0, 24.7, -1.6),
				color = "eggGem",
				neon = true,
			},
			{
				shape = "Block",
				size = Vector3.new(1.6, 0.7, 1.2),
				offset = Vector3.new(0, 24, -1.6),
				color = "eggGem",
				neon = true,
			},
			{
				shape = "Block",
				size = Vector3.new(0.8, 0.7, 1.2),
				offset = Vector3.new(0, 23.3, -1.6),
				color = "eggGem",
				neon = true,
			},
			{
				shape = "Block",
				size = Vector3.new(1, 2.2, 1),
				offset = Vector3.new(-4.6, 16.5, 1.2),
				color = "hood",
			},
			{
				shape = "Block",
				size = Vector3.new(1, 2.2, 1),
				offset = Vector3.new(4.6, 16.5, 1.2),
				color = "hood",
			},
		},
		footprint = 0,
		height = 0,
	},

	--[[
		Podium — стенд рекордсменов: три места ступенями, как на турнирах.

		Центральная тумба выше боковых, и высота идёт не по порядку слева
		направо, а от центра: второе место слева, третье справа. Так стоят
		настоящие пьедесталы, и место читается высотой, а не подписью.

		Металл у каждого свой — золото, серебро, бронза. Это единственное,
		что отличает тумбы кроме высоты, и вместе они говорят «здесь призовая
		тройка» без единого слова.

		Таблички с именами вешает контроллер (см. Props.PodiumPlates): текст —
		это SurfaceGui, а сборщик предметов делает только детали.
	]]
	{
		key = "Podium",
		parts = {
			{
				shape = "Block",
				size = Vector3.new(17, 1, 9),
				offset = Vector3.new(0, 0.5, 0),
				color = "stoneDark",
			},
			{
				shape = "Block",
				size = Vector3.new(5.2, 5.4, 5.6),
				offset = Vector3.new(0, 3.7, 0),
				color = "eggAura",
			},
			{
				shape = "Block",
				size = Vector3.new(4.6, 3.4, 5.2),
				offset = Vector3.new(-5.2, 2.7, 0),
				color = "steel",
			},
			{
				shape = "Block",
				size = Vector3.new(4.6, 2.6, 5.2),
				offset = Vector3.new(5.2, 2.3, 0),
				color = "leather",
			},
			-- Рама позади: без неё три тумбы висят в пустоте, и таблички
			-- читаются на фоне неба, а не на фоне стенда.
			{
				shape = "Block",
				size = Vector3.new(1, 13, 1),
				offset = Vector3.new(-8, 6.5, 2.8),
				color = "stone",
			},
			{
				shape = "Block",
				size = Vector3.new(1, 13, 1),
				offset = Vector3.new(8, 6.5, 2.8),
				color = "stone",
			},
			{
				shape = "Block",
				size = Vector3.new(17.4, 1.2, 1.4),
				offset = Vector3.new(0, 12.6, 2.8),
				color = "stoneDark",
			},
		},
		footprint = 0,
		height = 0,
	},

	--[[
		QuestBoard — доска объявлений: щит на двух столбах под козырьком,
		с приколотыми листками.

		Листки разного размера и под разными углами намеренно: ровный ряд
		одинаковых бумажек читается таблицей, а не доской, куда их вешали
		по одной. Один листок подрагивает — этого хватает, чтобы доска
		не выглядела нарисованной.
	]]
	{
		key = "QuestBoard",
		parts = {
			{
				shape = "Block",
				size = Vector3.new(1, 10, 1),
				offset = Vector3.new(-4.8, 5, 0.8),
				color = "wood",
			},
			{
				shape = "Block",
				size = Vector3.new(1, 10, 1),
				offset = Vector3.new(4.8, 5, 0.8),
				color = "wood",
			},
			{
				shape = "Block",
				size = Vector3.new(11, 7, 0.6),
				offset = Vector3.new(0, 8, 0),
				color = "leather",
			},
			{
				shape = "Block",
				size = Vector3.new(12.6, 0.8, 2.6),
				offset = Vector3.new(0, 11.9, 0.4),
				color = "wood",
			},
			--[[
				Лампа под козырьком. Светит по-настоящему (light), а не только
				светится: неон в Roblox соседние детали не освещает вовсе,
				и без PointLight щит остался бы тёмным пятном — на нём как раз
				и висит всё, ради чего к доске подходят.
			]]
			{
				shape = "Block",
				size = Vector3.new(10.4, 0.35, 0.5),
				offset = Vector3.new(0, 11.3, -0.5),
				color = "eggAura",
				neon = true,
				light = 16,
			},
			{
				shape = "Block",
				size = Vector3.new(2.6, 3.2, 0.14),
				offset = Vector3.new(-3, 9.2, -0.4),
				angles = Vector3.new(0, 0, 6),
				color = "hide",
			},
			{
				shape = "Block",
				size = Vector3.new(2.2, 2.8, 0.14),
				offset = Vector3.new(0.4, 9.6, -0.4),
				angles = Vector3.new(0, 0, -9),
				color = "hide",
			},
			{
				shape = "Block",
				size = Vector3.new(2.4, 3, 0.14),
				offset = Vector3.new(3.2, 8.4, -0.4),
				angles = Vector3.new(0, 0, 4),
				color = "hide",
			},
			{
				shape = "Block",
				size = Vector3.new(2, 2.6, 0.14),
				offset = Vector3.new(-1.4, 6.6, -0.4),
				angles = Vector3.new(0, 0, -5),
				color = "hide",
				anim = "bob",
				animSpeed = 0.45,
				animAmount = 0.12,
			},
		},
		footprint = 0,
		height = 0,
	},

	--[[
		WheelSign — табличка с легендой колеса: какой цвет сколько даёт.

		Нужна с тех пор, как окно перестало показывать колесо: список призов
		игрок раньше читал там, а теперь ему видно только диск, и без легенды
		цвета не значат ничего.

		Сами строки рисует контроллер (Props.WheelSignFace): текст — это
		SurfaceGui, а сборщик предметов делает только детали.
	]]
	{
		key = "WheelSign",
		parts = {
			{
				shape = "Block",
				size = Vector3.new(0.9, 7, 0.9),
				offset = Vector3.new(0, 3.5, 0.4),
				color = "wood",
			},
			{
				shape = "Block",
				size = Vector3.new(8.4, 7.6, 0.5),
				offset = Vector3.new(0, 10.4, 0),
				color = "leather",
			},
			{
				shape = "Block",
				size = Vector3.new(9, 0.6, 1.2),
				offset = Vector3.new(0, 14.4, 0.2),
				color = "wood",
			},
		},
		footprint = 0,
		height = 0,
	},

	--[[
		ShopStall — торговая палатка по референсу владельца: навес на шестах,
		ковёр под ним, прилавок и товар.

		Крыша двускатная и держится на четырёх шестах, а не лежит плитой:
		скат — единственное, что отличает шатёр от коробки, и без него палатка
		читается ящиком с ножками.

		Тёплая: ткань, дерево, ковёр, два фонаря с настоящим светом. В лобби
		это единственное тёплое пятно, и находится оно взглядом раньше, чем
		читается вывеска.
	]]
	{
		key = "ShopStall",
		parts = {
			-- Ковёр. Лежит первым: он задаёт место, а не украшает его.
			{
				shape = "Block",
				size = Vector3.new(14, 0.16, 11),
				offset = Vector3.new(0, 0.08, 1.4),
				color = "drum",
			},
			{
				shape = "Block",
				size = Vector3.new(11, 0.2, 8),
				offset = Vector3.new(0, 0.18, 1.4),
				color = "leather",
			},
			{
				shape = "Cylinder",
				size = Vector3.new(11, 0.7, 0.7),
				offset = Vector3.new(-6.4, 5.5, -3.4),
				angles = Vector3.new(0, 0, 90),
				color = "wood",
			},
			{
				shape = "Cylinder",
				size = Vector3.new(11, 0.7, 0.7),
				offset = Vector3.new(6.4, 5.5, -3.4),
				angles = Vector3.new(0, 0, 90),
				color = "wood",
			},
			{
				shape = "Cylinder",
				size = Vector3.new(11, 0.7, 0.7),
				offset = Vector3.new(-6.4, 5.5, 5.4),
				angles = Vector3.new(0, 0, 90),
				color = "wood",
			},
			{
				shape = "Cylinder",
				size = Vector3.new(11, 0.7, 0.7),
				offset = Vector3.new(6.4, 5.5, 5.4),
				angles = Vector3.new(0, 0, 90),
				color = "wood",
			},
			-- Два ската и конёк между ними.
			{
				shape = "Block",
				size = Vector3.new(15, 0.4, 6.4),
				offset = Vector3.new(0, 11.4, -2.4),
				angles = Vector3.new(-24, 0, 0),
				color = "hide",
			},
			{
				shape = "Block",
				size = Vector3.new(15, 0.4, 6.4),
				offset = Vector3.new(0, 11.4, 4.4),
				angles = Vector3.new(24, 0, 0),
				color = "hide",
			},
			{
				shape = "Block",
				size = Vector3.new(15.4, 0.5, 0.9),
				offset = Vector3.new(0, 12.7, 1),
				color = "eggAura",
			},
			-- Кайма по краю ската: та самая золотая полоса с референса,
			-- по которой навес читается тканью, а не листом фанеры.
			{
				shape = "Block",
				size = Vector3.new(15.2, 0.5, 0.5),
				offset = Vector3.new(0, 10.1, -5.4),
				color = "eggAura",
			},
			{
				shape = "Block",
				size = Vector3.new(15.2, 0.5, 0.5),
				offset = Vector3.new(0, 10.1, 7.4),
				color = "eggAura",
			},
			-- Прилавок со стороны игрока.
			{
				shape = "Block",
				size = Vector3.new(12, 3.2, 2.4),
				offset = Vector3.new(0, 1.6, -4.2),
				color = "wood",
			},
			{
				shape = "Block",
				size = Vector3.new(12.6, 0.4, 3),
				offset = Vector3.new(0, 3.4, -4.2),
				color = "leather",
			},
			-- Товар: ящики и мешок за прилавком.
			{
				shape = "Block",
				size = Vector3.new(2.2, 2.2, 2.2),
				offset = Vector3.new(-4.4, 1.2, 3.6),
				angles = Vector3.new(0, 18, 0),
				color = "leather",
			},
			{
				shape = "Block",
				size = Vector3.new(1.8, 1.8, 1.8),
				offset = Vector3.new(-4.9, 3.2, 3.2),
				angles = Vector3.new(0, -12, 0),
				color = "wood",
			},
			{
				shape = "Ball",
				size = Vector3.new(2.6, 2.4, 2.6),
				offset = Vector3.new(4.6, 1.2, 3.8),
				color = "hide",
			},
			--[[
				Фонари на передних шестах. Светят по-настоящему: неон в Roblox
				соседние детали не освещает, а вся лавка держится на том, что
				под навесом теплее, чем снаружи.
			]]
			{
				shape = "Ball",
				size = Vector3.new(1.3, 1.5, 1.3),
				offset = Vector3.new(-6.4, 8.4, -3.4),
				color = "eggAura",
				neon = true,
				transparency = 0.2,
				anim = "flicker",
				animSpeed = 0.5,
				animAmount = 0.18,
				light = 18,
			},
			{
				shape = "Ball",
				size = Vector3.new(1.3, 1.5, 1.3),
				offset = Vector3.new(6.4, 8.4, -3.4),
				color = "eggAura",
				neon = true,
				transparency = 0.2,
				anim = "flicker",
				animSpeed = 0.62,
				animAmount = 0.18,
				light = 18,
			},
		},
		footprint = 0,
		height = 0,
	},

	--[[
		Merchant — торговец за прилавком.

		Стоит, а не сидит, как на референсе: сидящего из-за прилавка видно
		по макушку, и разговаривать игрок будет с ящиком.

		Отдельный предмет от палатки, потому что дышит: покачивание задаётся
		предмету целиком (placement), и вместе с ним закачался бы весь навес.
	]]
	{
		key = "Merchant",
		parts = {
			{
				shape = "Cylinder",
				size = Vector3.new(3.4, 3.6, 3.2),
				offset = Vector3.new(0, 1.7, 0),
				angles = Vector3.new(0, 0, 90),
				color = "cloak",
			},
			{
				shape = "Ball",
				size = Vector3.new(3.2, 3, 2.8),
				offset = Vector3.new(0, 4.2, 0),
				color = "cloak",
			},
			{
				shape = "Cylinder",
				size = Vector3.new(2.6, 0.8, 0.8),
				offset = Vector3.new(-1.7, 4.2, -0.6),
				angles = Vector3.new(0, 0, 74),
				color = "cloak",
			},
			{
				shape = "Cylinder",
				size = Vector3.new(2.6, 0.8, 0.8),
				offset = Vector3.new(1.7, 4.2, -0.6),
				angles = Vector3.new(0, 0, -74),
				color = "cloak",
			},
			{
				shape = "Ball",
				size = Vector3.new(0.8, 0.8, 0.8),
				offset = Vector3.new(-2.1, 3, -0.9),
				color = "flesh",
			},
			{
				shape = "Ball",
				size = Vector3.new(0.8, 0.8, 0.8),
				offset = Vector3.new(2.1, 3, -0.9),
				color = "flesh",
			},
			{
				shape = "Ball",
				size = Vector3.new(2.2, 2.2, 2.2),
				offset = Vector3.new(0, 6.3, -0.2),
				color = "flesh",
			},
			-- Зелёные волосы с референса: сзади копна, спереди чёлка.
			{
				shape = "Ball",
				size = Vector3.new(2.5, 2.3, 2.4),
				offset = Vector3.new(0, 6.6, 0.4),
				color = "leaf",
			},
			{
				shape = "Block",
				size = Vector3.new(2.1, 0.6, 0.5),
				offset = Vector3.new(0, 7.1, -1),
				color = "leaf",
			},
			{
				shape = "Ball",
				size = Vector3.new(0.34, 0.34, 0.34),
				offset = Vector3.new(-0.55, 6.3, -1.1),
				color = "eye",
			},
			{
				shape = "Ball",
				size = Vector3.new(0.34, 0.34, 0.34),
				offset = Vector3.new(0.55, 6.3, -1.1),
				color = "eye",
			},
		},
		footprint = 0,
		height = 0,
	},

	--[[
		PetStand — тумба, на которой стоит модель питомца игрока.

		Сам питомец — клиентская модель у каждого своя (LobbyController),
		а тумба одна и та же. Кольцо светится: без него диск на мощёной
		площади не отличить от плитки.
	]]
	{
		key = "PetStand",
		parts = {
			{
				shape = "Cylinder",
				size = Vector3.new(1.2, 14, 14),
				offset = Vector3.new(0, 0.6, 0),
				angles = Vector3.new(0, 0, 90),
				color = "stoneDark",
			},
			{
				shape = "Cylinder",
				size = Vector3.new(0.5, 11.6, 11.6),
				offset = Vector3.new(0, 1.3, 0),
				angles = Vector3.new(0, 0, 90),
				color = "stone",
			},
			{
				shape = "Cylinder",
				size = Vector3.new(0.3, 10, 10),
				offset = Vector3.new(0, 1.5, 0),
				angles = Vector3.new(0, 0, 90),
				color = "portal",
				neon = true,
				transparency = 0.3,
				anim = "glow",
				animSpeed = 0.35,
				animAmount = 0.18,
			},
		},
		footprint = 0,
		height = 0,
	},

	--[[
		Деревья по референсу владельца: низкополигональные, ствол и три-четыре
		гранёных кома кроны. Гранями их делает не форма, а разный оттенок
		соседних комьев — одним тоном крона слипается в зелёный шар.

		Два вида вместо одного: ряд одинаковых деревьев читается забором.
		Разворот в расстановке добавляет к ним ещё немного непохожести
		бесплатно.
	]]
	{
		key = "TreeA",
		parts = {
			{
				shape = "Cylinder",
				size = Vector3.new(9, 1.8, 1.8),
				offset = Vector3.new(0, 4.5, 0),
				angles = Vector3.new(0, 0, 90),
				color = "wood",
			},
			{
				shape = "Block",
				size = Vector3.new(7.6, 5, 7),
				offset = Vector3.new(-0.8, 10, 0.4),
				angles = Vector3.new(0, 18, 0),
				color = "leaf",
			},
			{
				shape = "Block",
				size = Vector3.new(6, 4.4, 6),
				offset = Vector3.new(2.2, 11.6, -1),
				angles = Vector3.new(0, -25, 0),
				color = "leafDark",
			},
			{
				shape = "Block",
				size = Vector3.new(5, 3.6, 5),
				offset = Vector3.new(-1.4, 13.4, -0.6),
				angles = Vector3.new(0, 40, 0),
				color = "leaf",
			},
		},
		footprint = 0,
		height = 0,
	},
	{
		key = "TreeB",
		parts = {
			{
				shape = "Cylinder",
				size = Vector3.new(11, 1.6, 1.6),
				offset = Vector3.new(0, 5.5, 0),
				angles = Vector3.new(0, 0, 90),
				color = "wood",
			},
			{
				shape = "Block",
				size = Vector3.new(6.4, 4.6, 6),
				offset = Vector3.new(1.2, 11.4, 0),
				angles = Vector3.new(0, -14, 0),
				color = "leafDark",
			},
			{
				shape = "Block",
				size = Vector3.new(5.6, 4.2, 5.4),
				offset = Vector3.new(-1.8, 12.8, 0.8),
				angles = Vector3.new(0, 30, 0),
				color = "leaf",
			},
			{
				shape = "Block",
				size = Vector3.new(4.4, 3.4, 4.4),
				offset = Vector3.new(0.6, 14.8, -0.8),
				angles = Vector3.new(0, -38, 0),
				color = "leafDark",
			},
		},
		footprint = 0,
		height = 0,
	},

	--[[
		Фонарь. Единственное здесь, что мигает каналом flicker: ровная
		пульсация на фонаре читается приборной лампой, а живой огонь —
		нет. Плафон полупрозрачный, чтобы мигал свет, а не крашеный кубик.
	]]
	{
		key = "Lamp",
		parts = {
			{
				shape = "Block",
				size = Vector3.new(2.4, 0.6, 2.4),
				offset = Vector3.new(0, 0.3, 0),
				color = "stoneDark",
			},
			{
				shape = "Cylinder",
				size = Vector3.new(9, 0.7, 0.7),
				offset = Vector3.new(0, 4.8, 0),
				angles = Vector3.new(0, 0, 90),
				color = "stoneDark",
			},
			{
				shape = "Block",
				size = Vector3.new(2, 0.4, 2),
				offset = Vector3.new(0, 10.6, 0),
				color = "stoneDark",
			},
			{
				shape = "Ball",
				size = Vector3.new(1.9, 2.2, 1.9),
				offset = Vector3.new(0, 9.4, 0),
				color = "portalGlow",
				neon = true,
				transparency = 0.25,
				anim = "flicker",
				animSpeed = 0.55,
				animAmount = 0.22,
			},
		},
		footprint = 0,
		height = 0,
	},
}

--[[
	Яйца собираются из Config/Eggs, а не описываются здесь по одному.

	Цвет каждого яйца уже записан в Config/Eggs и уже совпадает с его 2D-иконкой
	в assets/icons/shop — это один факт, и второго места у него быть не должно.
	Блик и тень выводятся из того же цвета, поэтому яйцо любой новой редкости
	получит модель само, стоит появиться строке в Config/Eggs.

	ФОРМА ВОКСЕЛЬНАЯ. Не стопка дисков, а объём, набранный кубиками: ступени
	идут по всем трём осям, а не по одной высоте.

	ПОЧЕМУ ЭТО НЕ СТОИТ ТЫСЯЧ ДЕТАЛЕЙ. Кубиками по одному яйцо такой крупности
	вышло бы в 1327 деталей, а на пятерых — в шесть с половиной тысяч. Поэтому
	сплошной ряд кубиков вдоль одной оси собирается в ОДНУ вытянутую коробку:
	приём стандартный для воксельных движков, снаружи неотличим, а деталей
	остаётся 161 на яйцо и 805 на весь ряд.

	Отсюда же ограничение узора: слияние идёт вдоль X, поэтому рисунок на
	скорлупе может быть только горизонтальным — пояса и кольца. Произвольный
	рисунок означал бы отказ от слияния, то есть те самые тысячи деталей.

	ВЛОЖЕННЫЕ ТАБЛИЦЫ СОБИРАЮТСЯ ЗАНОВО НА КАЖДОЕ ЯЙЦО. Это те самые грабли
	из Config/Talents: шаблон, розданный по ссылке, ловит второй table.freeze
	и роняет модуль при загрузке вместе с сервером и клиентом.
]]
local EGG_VOXEL = 0.32
local EGG_HEIGHT = 5.44
local EGG_WIDTH = 4

--[[
	Сколько верхних слоёв не строится вовсе.

	Самый верхний при этой крупности выходит шириной в два вокселя и сидит
	на слое шириной в пять. Такая шапочка читается не кончиком яйца, а
	отдельной нашлёпкой — целостность силуэта она рвёт сильнее, чем добавляет
	округлости. Профиль при этом не трогается: доли высоты остаются прежними,
	и узор на скорлупе не съезжает.
]]
local EGG_TOP_TRIM = 1

--[[
	Профиль яйца: доля от половины ширины на высоте t (0 — низ, 1 — верх).

	Эллипс со степенью 0.62 и перекосом 0.3. Каждый множитель делает своё:
	эллипс скругляет ОБА конца, степень чуть подбирает бока, чтобы середина
	не выглядела бочкой, а перекос сдвигает толстое место ниже середины
	и сужает верх.

	ПЕРВЫЙ ВАРИАНТ БЫЛ КАПЛЕЙ. Там стоял синус со степенью 0.78, и она
	растягивала верх в остриё: радиус уходил в ноль слишком полого, и вместо
	тупого конца получалась вытянутая макушка. Скругляет концы именно эллипс —
	у него на краю вертикальная касательная, а у синуса нет.
]]
local function eggRadius(t: number): number
	local s = 2 * t - 1
	return (math.max(1 - s * s, 0) ^ 0.62) * (1 - 0.3 * s)
end

--[[
	Узор на скорлупе: цвет ОДНОГО вокселя.

	Задаётся в трёх измерениях, а не как картинка на передней стороне: яйцо
	стоит в лобби и его обходят кругом. Плоский рисунок, налепленный спереди,
	с боков превратился бы в размазанное пятно.

	Поэтому завиток Greater — это наклонное КОЛЬЦО (срез плоскостью под углом),
	а оправа Prime — меридианы через полюса. С фронта они совпадают с иконкой,
	а с любой другой стороны выглядят так, будто так и задумано.

	ЦЕНА УЗОРА ЗАВИСИТ ОТ ЕГО ОСИ, и это не мелочь. Ряды вокселей сливаются
	вдоль X, поэтому узор, который вдоль X не меняется, не стоит НИЧЕГО:
	наклонное кольцо и горизонтальный поясок оставляют яйцо на прежних 158
	деталях. А вертикальное ребро режет каждый ряд натрое и поднимает
	счёт до 317.
]]
local function eggVoxelColor(
	key: string,
	x: number,
	z: number,
	layerIndex: number,
	layers: number,
	t: number,
	radius: number,
	shine: Color3,
	shade: Color3,
	base: Color3
): Color3
	if key == "Greater" then
		--[[
			Наклонное кольцо: расстояние до плоскости, повёрнутой на 28
			градусов. Считается по высоте и глубине, x не участвует —
			отсюда и нулевая цена.
		]]
		local height = (layerIndex - 0.5) - layers * 0.5
		if math.abs(height * 0.883 + z * 0.469) < 1.15 then
			return shine
		end
	elseif key == "Prime" then
		--[[
			Кольцо на высоте камня: горизонтальная полоса вокруг всего яйца,
			из которой камень выступает спереди. Кольцо зависит только от
			высоты, поэтому целые слои красятся одним куском и стоят даром.
		]]
		if t > 0.44 and t < 0.56 then
			if -z > radius * 0.5 and math.abs(x) <= 1.5 then
				return Palette.Detail.eggGem
			end
			return shade
		end

		--[[
			Рёбра оправы: два взаимно перпендикулярных среза через ось яйца.
			Ширина у них ПОСТОЯННАЯ, в вокселях, — и это исправление.

			Раньше ребро задавалось углом в десять градусов, а угол на разной
			глубине покрывает разное число вокселей: у передней стенки три,
			у бока один. Отсюда и бралось пятно под камнем — ребро там просто
			раздувалось.

			Срез |z| <= 1 достаётся бесплатно: он красит целые ряды и выходит
			на поверхность только по бокам. Платит один |x| <= 1 — он режет
			каждый ряд натрое.
		]]
		if radius > 1.5 and (math.abs(x) <= 1 or math.abs(z) <= 1) then
			return shade
		end
	end

	return base
end

local function eggParts(key: string, color: Color3, premium: boolean): { ModelPartDef }
	local shine = color:Lerp(Color3.new(1, 1, 1), 0.42)
	local shade = color:Lerp(Color3.new(0, 0, 0), 0.32)

	local parts: { ModelPartDef } = {}
	local total = math.round(EGG_HEIGHT / EGG_VOXEL)
	local layers = total - EGG_TOP_TRIM
	local maxRadius = EGG_WIDTH * 0.5 / EGG_VOXEL

	for index = 1, layers do
		-- Доля высоты считается от ПОЛНОГО профиля: срезанная макушка не
		-- должна сдвигать узор на оставшихся слоях.
		local t = (index - 0.5) / total
		local radius = eggRadius(t) * maxRadius
		local y = (index - 0.5) * EGG_VOXEL
		local base = shade:Lerp(shine, t * 0.8 + 0.1)

		for z = -math.floor(radius), math.floor(radius) do
			local half = math.sqrt(math.max(radius * radius - z * z, 0))
			--[[
				Длина ряда округляется до целого числа вокселей: без округления
				концы рядов легли бы по гладкой дуге, и ступеней по краю
				не осталось бы вовсе.
			]]
			local run = math.round(half * 2)
			if run < 1 then
				continue
			end

			--[[
				Ряд режется на куски ОДНОГО ЦВЕТА, и каждый кусок — одна
				коробка. Ряд, которого узор не касается, так и остаётся одной
				деталью: платит только место, где узор ряд пересекает.
			]]
			local first = -math.floor(run / 2)
			local runStart = 0
			local runColor: Color3? = nil

			local function emit(fromStep: number, toStep: number, paint: Color3): ()
				local width = toStep - fromStep + 1
				local centre = first + (fromStep + toStep) * 0.5
				table.insert(parts, {
					shape = "Block",
					size = Vector3.new(width * EGG_VOXEL, EGG_VOXEL, EGG_VOXEL),
					offset = Vector3.new(centre * EGG_VOXEL, y, z * EGG_VOXEL),
					paint = paint,
				})
			end

			for step = 0, run - 1 do
				local voxel = eggVoxelColor(key, first + step, z, index, layers, t, radius, shine, shade, base)
				if runColor == nil then
					runColor, runStart = voxel, step
				elseif voxel ~= runColor then
					emit(runStart, step - 1, runColor)
					runColor, runStart = voxel, step
				end
			end

			if runColor then
				emit(runStart, run - 1, runColor)
			end
		end
	end

	--[[
		Наружное убранство осталось только у платных яиц, и это не случайность:
		оно и есть то, чем они отличаются на полке. Осколки и ореол видно
		с другого конца лобби, а полосой такого не скажешь.
	]]
	if not premium then
		return parts
	end

	if key == "Prism" then
		-- Осколки облетают кристалл. Единственное, что у яиц двигается
		-- само по себе: остальные качаются целиком через placement.
		for index = 1, 3 do
			local angle = (index - 1) * (math.pi * 2 / 3)
			table.insert(parts, {
				shape = "Block",
				size = Vector3.new(0.7, 1.2, 0.5),
				offset = Vector3.new(math.cos(angle) * 3.1, 1.8 + index * 0.7, math.sin(angle) * 3.1),
				angles = Vector3.new(0, 45, 0),
				paint = shine,
				anim = "spin",
				animSpeed = 0.12,
			})
		end
	elseif key == "Radiant" then
		-- Ореол и лучи. Ореол дышит прозрачностью, лучи стоят: мигающие
		-- лучи читались бы аварийной сигнализацией.
		table.insert(parts, {
			shape = "Ball",
			size = Vector3.new(6.8, 6.8, 6.8),
			offset = Vector3.new(0, 2.6, 0),
			color = "eggAura",
			neon = true,
			transparency = 0.72,
			anim = "glow",
			animSpeed = 0.25,
			animAmount = 0.12,
		})
		for _, degrees in { 0, 62, -62, 108, -108 } do
			local angle = math.rad(degrees)
			table.insert(parts, {
				shape = "Block",
				size = Vector3.new(0.45, 2.6, 0.45),
				offset = Vector3.new(math.sin(angle) * 3.7, 2.6 + math.cos(angle) * 3.7, 0),
				angles = Vector3.new(0, 0, -degrees),
				color = "eggAura",
				neon = true,
			})
		end
	end

	return parts
end

--[[
	Колесо фортуны. Два предмета, а не один: стойка стоит, а диск крутится.

	Разделены по той же причине, что тумба и яйцо: вращать надо только диск,
	и вращение — это положение предмета, то есть placement. Будь они одним
	предметом, вместе с секторами поворачивались бы столб и указатель.

	Секторов вдвое больше, чем призов: каждый приз занимает два противоположных
	сектора. Шесть секторов на таком диаметре выглядят пустой тарелкой, а
	соответствие «сектор — приз» остаётся однозначным в обе стороны.

	Диск описан кодом, а не двенадцатью записями руками: сектор отличается
	от сектора только углом, и переписывать один и тот же прямоугольник
	двенадцать раз — это двенадцать мест, где можно ошибиться.
]]
local WHEEL_RADIUS = 8.5
--[[
	Диск нарезан на равные ломтики, а СЕКТОР ПРИЗА набирается из них по весу.

	Так сделано ради того же требования, что и у прежнего плоского колеса:
	углы секторов пропорциональны шансам. Колесо с одинаковыми секторами и
	разными шансами показывает игроку неправду, а тонкий ломтик на сто тысяч
	Essence — это и есть честно показанный шанс, только нарисованный.

	Тридцать ломтиков по двенадцать градусов: мельче не нужно, потому что самый
	редкий приз весит два процента от сотни, то есть занимает семь градусов,
	и на этой сетке он всё равно получит свой ломтик.
]]
local WHEEL_SLICES = 30
-- Лампы по ободу. Их число к призам отношения не имеет: это украшение,
-- и делить их по весам значило бы врать второй раз, уже мелочью.
local WHEEL_LAMPS = 12

--[[
	Какому призу принадлежит доля круга. Возвращает номер приза в
	Balance.Daily.wheelPrizes.

	Раскладка по весам считается ЗДЕСЬ и больше нигде: клиенту нужно знать,
	где остановить диск, и если он посчитает то же самое своей формулой,
	однажды колесо встанет не на тот сектор.
]]
local function wheelPrizeAt(fraction: number): number
	local prizes = Balance.Daily.wheelPrizes

	local total = 0
	for _, prize in prizes do
		total += prize.weight
	end

	local target = fraction * total
	local accumulated = 0
	for index, prize in prizes do
		accumulated += prize.weight
		if target <= accumulated then
			return index
		end
	end

	return #prizes
end

--[[
	Середина сектора приза в градусах от верха диска, по часовой стрелке.

	Отдаётся наружу, потому что это нужно клиенту: диск обязан остановиться
	так, чтобы под указателем оказался выпавший приз.
]]
function Props.WheelAngleFor(prizeIndex: number): number
	local prizes = Balance.Daily.wheelPrizes

	local total = 0
	for _, prize in prizes do
		total += prize.weight
	end

	local before = 0
	for index = 1, math.clamp(prizeIndex, 1, #prizes) - 1 do
		before += prizes[index].weight
	end

	local span = prizes[math.clamp(prizeIndex, 1, #prizes)].weight
	return (before + span * 0.5) / total * 360
end

--[[
	Один ломтик — три полосы, а не один прямоугольник.

	ПОЧЕМУ НЕ ПРЯМОУГОЛЬНИК. Ломтик сужается к центру, а прямоугольник нет:
	они сходились у ступицы и втрое перекрывали друг друга. Совпавшие плоскости
	в Roblox мерцают при движении камеры — на ходьбе центр колеса хаотично
	шевелился, и это были не артефакты отрисовки, а честно наложенные детали.

	Ширина каждой полосы считается по ВНУТРЕННЕЙ дуге её кольца, поэтому
	полосы не перекрываются нигде.
]]
local function wheelSectorBands(): { { inner: number, outer: number } }
	local first = WHEEL_RADIUS * 0.38
	local last = WHEEL_RADIUS * 0.94
	local bands = {}
	for index = 1, 3 do
		table.insert(bands, {
			inner = first + (last - first) * (index - 1) / 3,
			outer = first + (last - first) * index / 3,
		})
	end
	return bands
end

local function wheelDiscParts(): { ModelPartDef }
	local parts: { ModelPartDef } = {
		-- Обод. Цилиндр с осью вдоль Z: развёрнут на 90 по Y, поэтому
		-- круглые торцы смотрят на игрока.
		{
			shape = "Cylinder",
			size = Vector3.new(1.4, WHEEL_RADIUS * 2, WHEEL_RADIUS * 2),
			offset = Vector3.new(0, 0, 0),
			angles = Vector3.new(0, 90, 0),
			color = "eggAura",
		},
	}

	local step = 360 / WHEEL_SLICES
	local halfAngle = math.tan(math.rad(step * 0.5))
	local bands = wheelSectorBands()

	for slice = 1, WHEEL_SLICES do
		local middleAngle = (slice - 0.5) * step
		local prizeIndex = wheelPrizeAt(middleAngle / 360)
		-- Цвета призов те же, что были у плоского колеса: игрок уже мог
		-- запомнить, какого цвета сотня тысяч.
		local paint = Palette.Wheel[(prizeIndex - 1) % #Palette.Wheel + 1]
		local angle = math.rad(middleAngle)

		for _, band in bands do
			local middle = (band.inner + band.outer) * 0.5
			table.insert(parts, {
				shape = "Block",
				size = Vector3.new(2 * band.inner * halfAngle * 0.92, band.outer - band.inner, 0.4),
				offset = Vector3.new(math.sin(angle) * middle, math.cos(angle) * middle, -1),
				angles = Vector3.new(0, 0, -middleAngle),
				paint = paint,
			})
		end
	end

	return parts
end

--[[
	Лампы по ободу — отдельный предмет, потому что они НЕ вращаются.

	Крутится диск, а огни бегут по кругу, оставаясь на раме: так устроено
	любое ярмарочное колесо, и именно неподвижность ламп делает вращение
	заметным. Крутись они вместе с диском, бег огней был бы не виден вовсе.

	Бег даётся сдвигом фазы: у каждой лампы он свой, по её номеру, поэтому
	волна обходит круг сама, от одного времени. Когда появится механика,
	скорость волны привяжется к скорости диска.
]]
local function wheelLampParts(): { ModelPartDef }
	local parts: { ModelPartDef } = {}

	for index = 1, WHEEL_LAMPS do
		local angle = math.rad((index - 1) * 360 / WHEEL_LAMPS)
		table.insert(parts, {
			shape = "Ball",
			size = Vector3.new(1.1, 1.1, 1.1),
			offset = Vector3.new(math.sin(angle) * (WHEEL_RADIUS + 0.9), math.cos(angle) * (WHEEL_RADIUS + 0.9), -1.2),
			color = "eggAura",
			neon = true,
			transparency = 0.45,
			anim = "glow",
			animSpeed = 0.5,
			animAmount = 0.45,
			animPhase = (index - 1) / WHEEL_LAMPS,
		})
	end

	return parts
end

table.insert(definitions, {
	key = "WheelLamps",
	parts = wheelLampParts(),
	footprint = 0,
	height = 0,
})

table.insert(definitions, {
	key = "WheelDisc",
	parts = wheelDiscParts(),
	footprint = 0,
	height = 0,
})

for _, egg in Eggs.List do
	table.insert(definitions, {
		key = `Egg{egg.key}`,
		--[[
			Платность берётся из валюты, а не из списка ключей: яйцо за Essence
			получает узор пластинами, платное — ещё и наружное убранство.
			Новое яйцо подчинится правилу само, стоит ему появиться
			в Config/Eggs.
		]]
		parts = eggParts(egg.key, Color3.fromHex(egg.color), egg.currency ~= "essence"),
		footprint = 0,
		height = 0,
	})
end

--[[
	Цветы на поляне. Три расцветки, по две детали: стебель и головка.

	Больше двух деталей им не нужно — цветок в лобби виден с десятка стадов
	и читается пятном цвета, а не лепестками. Расцветки взяты из уже
	существующих: белая кость, жёлтое сияние и синее перо.
]]
local FLOWER_HEADS = { "bone", "eggAura", "plumeCool" }

for index, head in FLOWER_HEADS do
	table.insert(definitions, {
		key = `Flower{index}`,
		parts = {
			{
				shape = "Cylinder",
				size = Vector3.new(1.1, 0.14, 0.14),
				offset = Vector3.new(0, 0.55, 0),
				angles = Vector3.new(0, 0, 90),
				paint = Palette.Detail.leaf,
			},
			{
				shape = "Ball",
				size = Vector3.new(0.7, 0.45, 0.7),
				offset = Vector3.new(0, 1.15, 0),
				color = head,
			},
		},
		footprint = 0,
		height = 0,
	})
end

Props.List = definitions
Props.ByKey = {} :: { [string]: ModelDef }

--[[
	Расстановка. Числа те же, что были у старого портала (Balance.Lobby),
	чтобы планировка не поехала: владелец оставил её как есть.
]]
--[[
	ПЛАНИРОВКА ЛОББИ ЖИВЁТ ЗДЕСЬ И БОЛЬШЕ НИГДЕ.

	По схеме владельца: круглая площадь посреди зелёной поляны, объекты стоят
	по её краю лицом к центру, зелень и цветы — за площадью.

	Раньше те же координаты считались ещё и в LobbyService — своим кодом, из тех
	же чисел Balance. Пока всё стояло по осям, это сходилось; с объектами под
	углом разъехалось бы в первый же день. Теперь сервер берёт точки отсюда
	(Props.Anchors), и разъезжаться нечему.
]]
local PLAZA = Balance.Lobby.plazaRadius

--[[
	Где что стоит. yaw считается так, чтобы лицевая сторона (-Z) смотрела
	в центр площади: для точки (x, z) это atan2(x, z) в градусах.
]]
local function facingCentre(x: number, z: number): number
	return math.deg(math.atan2(x, z))
end

local LAYOUT = {
	portal = Vector3.new(0, 0, -PLAZA - 1),
	leaderboard = Vector3.new(-PLAZA * 0.71, 0, 0),
	quests = Vector3.new(PLAZA * 0.71, 0, 0),
	shop = Vector3.new(-PLAZA * 0.62, 0, PLAZA * 0.55),
	wheel = Vector3.new(PLAZA * 0.62, 0, PLAZA * 0.55),
	petStand = Vector3.new(0, 0, PLAZA * 0.37),
	eggRow = PLAZA * 0.86,
	eggSpacing = 16,
}

--[[
	Точка, где клиент ставит модель питомца на стенде. Экспортируется, потому
	что нужна и стенду, и LobbyController: одно место, две стороны.
]]
Props.PetStand = LAYOUT.petStand + Vector3.new(0, 6, 0)

--[[
	Куда контроллер вешает таблички подиума, относительно его основания.
	Порядок тот же, что у мест: первое, второе, третье.

	Лежит рядом с расстановкой, а не рядом с самими тумбами, по той же причине,
	по которой здесь лежит вся планировка: высота тумбы и высота таблички над
	ней обязаны меняться вместе.
]]
Props.PodiumPlates = {
	Vector3.new(0, 7.6, 0),
	Vector3.new(-5.2, 5.6, 0),
	Vector3.new(5.2, 4.8, 0),
} :: { Vector3 }

--[[
	Где у таблички колеса лицевая сторона и какого она размера, относительно
	основания. Отсюда контроллер узнаёт, куда вешать SurfaceGui со строками.
]]
Props.WheelSignFace = {
	offset = Vector3.new(0, 10.4, -0.3),
	size = Vector2.new(8.4, 7.6),
}

local placements: { Placement } = {
	{ key = "Portal", position = LAYOUT.portal, yaw = 180 },
	{
		key = "Podium",
		position = LAYOUT.leaderboard,
		yaw = facingCentre(LAYOUT.leaderboard.X, LAYOUT.leaderboard.Z),
		id = "Podium",
	},
	{ key = "QuestBoard", position = LAYOUT.quests, yaw = facingCentre(LAYOUT.quests.X, LAYOUT.quests.Z) },
	{ key = "ShopStall", position = LAYOUT.shop, yaw = facingCentre(LAYOUT.shop.X, LAYOUT.shop.Z) },
	{ key = "PetStand", position = LAYOUT.petStand, yaw = 0 },
	{
		key = "Merchant",
		position = LAYOUT.shop + Vector3.new(0, 0, 0),
		yaw = facingCentre(LAYOUT.shop.X, LAYOUT.shop.Z),
		bob = 0.12,
		bobSpeed = 0.22,
	},
}

--[[
	Ряд яиц вдоль южного края площади. Тумба и яйцо — отдельные предметы:
	качается только яйцо, подставка стоять обязана.
]]
local eggStart = -(#Eggs.List - 1) * LAYOUT.eggSpacing / 2

for index, egg in Eggs.List do
	local base = Vector3.new(eggStart + (index - 1) * LAYOUT.eggSpacing, 0, LAYOUT.eggRow)

	table.insert(placements, { key = "EggStand", position = base, yaw = 0 })
	table.insert(placements, {
		key = `Egg{egg.key}`,
		position = base + Vector3.new(0, 3.2, 0),
		yaw = 0,
		-- Вразнобой: пять яиц, качающихся строем, читаются одной деталью.
		bob = 0.35,
		bobSpeed = 0.3 + index * 0.04,
	})
end

--[[
	Колесо: стойка, диск, лампы и табличка с легендой.

	Диск и лампы стоят на высоте ступицы и получают имена — ими управляет
	механика прокрутки, а не время.
]]
local wheelYaw = facingCentre(LAYOUT.wheel.X, LAYOUT.wheel.Z)
local wheelHub = LAYOUT.wheel + Vector3.new(0, 15, 0)

table.insert(placements, { key = "WheelStand", position = LAYOUT.wheel, yaw = wheelYaw })
table.insert(placements, { key = "WheelDisc", position = wheelHub, yaw = wheelYaw, id = "WheelDisc" })
table.insert(placements, { key = "WheelLamps", position = wheelHub, yaw = wheelYaw, id = "WheelLamps" })

--[[
	Табличка с легендой стоит сбоку от колеса, ближе к площади, и развёрнута
	к подходящему игроку: он читает её, пока диск крутится, и перекрывать
	колесо она не должна.
]]
local wheelRight = CFrame.Angles(0, math.rad(wheelYaw), 0) * Vector3.new(15, 0, -4)
table.insert(placements, { key = "WheelSign", position = LAYOUT.wheel + wheelRight, yaw = wheelYaw + 25 })

--[[
	Зелень за площадью. Раскладывается по seed, а не списком координат:
	деревьев и цветов теперь под сотню, и просматривать такой список глазами
	уже дороже, чем довериться генератору.

	Возражение против генератора — «однажды поставит дерево в проход» — снято
	конструкцией: кольцо начинается за краем площади, и попасть внутрь дерево
	физически не может. Seed постоянный, поэтому у всех игроков поляна одна
	и та же: разные деревья у стоящих рядом читались бы поломкой.
]]
local greenery = RNG.new(20260812)
local edge = Balance.Lobby.floorSize * 0.5 - 6

for index = 1, 30 do
	local angle = greenery.NextNumber(0, math.pi * 2)
	local distance = greenery.NextNumber(PLAZA + 9, edge)
	table.insert(placements, {
		key = if index % 2 == 0 then "TreeA" else "TreeB",
		position = Vector3.new(math.sin(angle) * distance, 0, math.cos(angle) * distance),
		yaw = greenery.NextNumber(0, 360),
	})
end

for index = 1, 54 do
	local angle = greenery.NextNumber(0, math.pi * 2)
	local distance = greenery.NextNumber(PLAZA + 4, edge)
	table.insert(placements, {
		key = `Flower{index % 3 + 1}`,
		position = Vector3.new(math.sin(angle) * distance, 0, math.cos(angle) * distance),
		yaw = greenery.NextNumber(0, 360),
	})
end

-- Фонари по краю площади: свет там, где игрок ходит между объектами.
for index = 1, 6 do
	local angle = math.rad((index - 1) * 60 + 30)
	table.insert(placements, {
		key = "Lamp",
		position = Vector3.new(math.sin(angle) * (PLAZA - 5), 0, math.cos(angle) * (PLAZA - 5)),
		yaw = 0,
	})
end

--[[
	Объёмы, в которые игрок упирается и на которых висят промпты.

	Размер примерно повторяет видимую вещь: игрок обязан упираться в то,
	что видит, и расхождение читается дырой в мире.
]]
local anchors: { Anchor } = {
	{
		name = "Portal",
		position = LAYOUT.portal + Vector3.new(0, 0, 3),
		size = Vector3.new(16, 6, 5),
		yaw = 180,
		objectText = Branding.gameName,
		panel = "Stage",
	},
	{
		name = "Leaderboard",
		position = LAYOUT.leaderboard,
		size = Vector3.new(9, 6, 17),
		yaw = facingCentre(LAYOUT.leaderboard.X, LAYOUT.leaderboard.Z),
		objectText = "Hall of Records",
		panel = "Leaderboard",
	},
	{
		name = "Quests",
		position = LAYOUT.quests,
		size = Vector3.new(3, 6, 11),
		yaw = facingCentre(LAYOUT.quests.X, LAYOUT.quests.Z),
		objectText = "Quest Board",
		panel = "Quests",
	},
	{
		--[[
			У лавки объём стоит по прилавку, а не по всей палатке: под навес
			игрок заходить не должен, но и обходить лавку по дуге незачем.
			Смещение считается в повёрнутой системе самой лавки.
		]]
		name = "Shop",
		position = LAYOUT.shop
			+ CFrame.Angles(0, math.rad(facingCentre(LAYOUT.shop.X, LAYOUT.shop.Z)), 0) * Vector3.new(0, 0, -4.2),
		size = Vector3.new(12, 4, 3),
		yaw = facingCentre(LAYOUT.shop.X, LAYOUT.shop.Z),
		objectText = "Shop",
		panel = "Shop",
	},
	{
		name = "Pets",
		position = LAYOUT.petStand,
		size = Vector3.new(14, 4, 14),
		yaw = 0,
		objectText = "Pets",
		panel = "Pets",
	},
	{
		name = "Wheel",
		position = LAYOUT.wheel,
		size = Vector3.new(12, 6, 7),
		yaw = wheelYaw,
		objectText = "Wheel of Fortune",
		panel = "Wheel",
	},
}

for index, egg in Eggs.List do
	table.insert(anchors, {
		name = `Egg{egg.key}`,
		position = Vector3.new(eggStart + (index - 1) * LAYOUT.eggSpacing, 0, LAYOUT.eggRow),
		size = Vector3.new(6, 3.2, 6),
		yaw = 0,
		objectText = egg.displayName,
		panel = "Eggs",
		target = egg.key,
	})
end

Props.Anchors = anchors
Props.Placements = placements

--[[
	Цвет по имени: сначала общая таблица деталей, потом палитра лобби.

	Две таблицы, а не одна: камень и кость общие со всей игрой и живут
	в Detail, а зелень портала принадлежит лобби и уже там записана —
	копировать её сюда значило бы завести второе место для одного цвета.
]]
local function resolveColor(name: string): Color3?
	local detail: any = Palette.Detail
	local lobby: any = Palette.Lobby
	return detail[name] or lobby[name]
end

for _, def in definitions do
	assert(Props.ByKey[def.key] == nil, `[Props] Дубликат ключа "{def.key}"`)
	Props.ByKey[def.key] = def

	assert(#def.parts > 0, `[Props] Предмет "{def.key}" без деталей`)
	assert(#def.parts <= MAX_PARTS, `[Props] У "{def.key}" деталей больше {MAX_PARTS}`)

	local footprint = 0
	local height = 0

	for index, part in def.parts do
		--[[
			Стихии у предмета лобби нет, поэтому роль в палитре носителя ему
			задать нельзя: только цвет. Задаётся он либо ИМЕНЕМ из палитры,
			либо готовым Color3 — так его ставит генератор яиц, где блик и
			тень выводятся из цвета самого яйца и своего имени не имеют.

			Забытый цвет оставил бы деталь белой, а это на каменной арке
			заметят не сразу.
		]]
		assert(
			part.tint == nil,
			`[Props] "{def.key}", деталь {index}: tint у предмета лобби не бывает`
		)

		if part.paint == nil then
			assert(
				part.color ~= nil,
				`[Props] "{def.key}", деталь {index}: не задан ни color, ни paint`
			)

			local paint = resolveColor(part.color :: string)
			assert(
				paint ~= nil,
				`[Props] "{def.key}", деталь {index}: нет цвета "{part.color}" ни в Detail, ни в Lobby`
			)
			part.paint = paint
		end

		--[[
			Габариты считаются без учёта поворота, в отличие от Config/Models.
			Там пятно сверяется с боевым радиусом босса и обязано быть точным,
			здесь его никто не проверяет — это справка, а не инвариант.
		]]
		local half = part.size * 0.5
		footprint = math.max(footprint, math.abs(part.offset.X) + half.X, math.abs(part.offset.Z) + half.Z)
		height = math.max(height, part.offset.Y + half.Y)

		table.freeze(part)
	end

	def.footprint = footprint
	def.height = height

	table.freeze(def.parts)
	table.freeze(def)
end

table.freeze(definitions)
table.freeze(Props.ByKey)
table.freeze(Props.Placements)
table.freeze(Props.PodiumPlates)
-- Props.PetStand не морозится: это Vector3, а не таблица. table.freeze на нём
-- бросает исключение и роняет модуль, а с ним и всё лобби.
table.freeze(Props.Anchors)
table.freeze(Props.WheelSignFace)

return Props
