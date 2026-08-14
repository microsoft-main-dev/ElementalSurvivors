--!strict
--[[
	ArenaProps — из чего собран декор арены: холмы, деревья, кусты, трава, камни.

	ПОЧЕМУ ЭТО НЕ Config/Props И НЕ Config/Models. У предмета лобби и у модели
	босса цвет запекается при загрузке (part.paint), потому что он один на всю
	игру: сталь клинка везде одинаковая сталь. У декора арены цвет наоборот —
	свойство ЛОКАЦИИ: одна и та же ель на Лесной поляне зелёная и тёплая, а в
	Дремучем лесу почти синяя. Поэтому здесь у детали остаётся ИМЯ цвета, а
	превращает его в Color3 тот, кто строит, — по палитре текущей локации
	(Palette.Arenas[ключ]). Config/Biomes сверяет, что все имена в палитрах есть.

	Второе отличие — материал. Стиль игры плоский (SmoothPlastic и Neon), но
	«стены из деревьев» и трава просят фактуры, а встроенные материалы движка
	(Grass, Ground, Rock, Wood) — не ассеты, и правило 4 их не касается.

	КТО ЧТО СТРОИТ. Тело холма и ствол дерева-препятствия строит СЕРВЕР: это
	настоящая коллизия, а физику игрока проверяет сервер. Клиент их только
	одевает — отсюда пары вида «холм = серверный цилиндр + HillCap». Дерево
	опушки (WallPine, WallBroad) стоит ЗА невидимой стеной, коллизии ему не
	нужно, и оно описано целиком, вместе со стволом.

	Публичный API:
		ArenaProps.ByKey        -> { [string]: Def }
		ArenaProps.List         -> { Def }
		ArenaProps.ColorNames   -> { string }        -- какие имена цвета нужны палитре
		ArenaProps.TreeHeight   -> number            -- высота ствола, к которой подогнаны кроны
		ArenaProps.TreeRadius   -> number            -- радиус ствола, он же радиус препятствия
		ArenaProps.HillParts(radius, height, rng) -> { PartDef }
]]

local RNG = require(script.Parent.Parent.Util.RNG)

local ArenaProps = {}

export type PartDef = {
	shape: "Block" | "Ball" | "Cylinder" | "Wedge",
	size: Vector3,
	offset: Vector3,
	angles: Vector3?, -- градусы, порядок XYZ
	color: string, -- имя из палитры локации, а не готовый цвет
	material: Enum.Material?,
	transparency: number?,
}

export type Def = {
	key: string,
	parts: { PartDef },
	radius: number, -- пятно на полу, стадов (справка для расстановки)
	height: number,
}

--[[
	Ствол дерева-препятствия: его строит сервер, а кроны здесь подогнаны
	именно под эти два числа и масштабируются вместе с ним.

	Радиус ствола И ЕСТЬ радиус препятствия — тот, от которого EnemyService
	расталкивает врагов. Расхождение здесь означало бы, что игрок упирается
	в воздух рядом с деревом, а враги обходят пустое место.
]]
ArenaProps.TreeHeight = 15
ArenaProps.TreeRadius = 1.6

local definitions: { Def } = {
	--[[
		Крона лиственного дерева: три гранёных кома разного оттенка.

		Гранями крону делает не форма, а разный оттенок соседних комьев —
		ровно то же правило, что у деревьев лобби. Одним тоном крона
		слипается в зелёный шар на любом количестве деталей.
	]]
	{
		key = "CrownBroad",
		parts = {
			{
				shape = "Block",
				size = Vector3.new(9.6, 5.4, 8.8),
				offset = Vector3.new(-0.6, 13.6, 0.4),
				angles = Vector3.new(0, 18, 0),
				color = "leaf",
				material = Enum.Material.LeafyGrass,
			},
			{
				shape = "Block",
				size = Vector3.new(7.6, 4.6, 7.2),
				offset = Vector3.new(1.8, 16.2, -0.8),
				angles = Vector3.new(0, -26, 0),
				color = "leafDark",
				material = Enum.Material.LeafyGrass,
			},
			{
				shape = "Block",
				size = Vector3.new(5.6, 3.8, 5.4),
				offset = Vector3.new(-1.2, 18.4, -0.4),
				angles = Vector3.new(0, 42, 0),
				color = "leaf",
				material = Enum.Material.LeafyGrass,
			},
			-- Ветка из-под кроны: без неё ствол входит в ком свечкой и дерево
			-- читается грибом.
			{
				shape = "Cylinder",
				size = Vector3.new(5.2, 0.8, 0.8),
				offset = Vector3.new(2.4, 12.2, 0),
				angles = Vector3.new(0, 0, 34),
				color = "trunk",
				material = Enum.Material.Wood,
			},
		},
		radius = 0,
		height = 0,
	},

	--[[
		Крона ели: четыре яруса, каждый уже и повёрнут относительно нижнего.

		Поворот обязателен. Ярусы, поставленные строго друг на друга, дают
		ступенчатую пирамиду с одной вертикальной гранью — а повёрнутые
		читаются лапами.
	]]
	{
		key = "CrownPine",
		parts = {
			{
				shape = "Block",
				size = Vector3.new(8.8, 3.2, 8.8),
				offset = Vector3.new(0, 9.4, 0),
				angles = Vector3.new(0, 12, 0),
				color = "needleDark",
				material = Enum.Material.LeafyGrass,
			},
			{
				shape = "Block",
				size = Vector3.new(7, 3, 7),
				offset = Vector3.new(0, 12.4, 0),
				angles = Vector3.new(0, -28, 0),
				color = "needle",
				material = Enum.Material.LeafyGrass,
			},
			{
				shape = "Block",
				size = Vector3.new(5.2, 2.8, 5.2),
				offset = Vector3.new(0, 15.2, 0),
				angles = Vector3.new(0, 20, 0),
				color = "needleDark",
				material = Enum.Material.LeafyGrass,
			},
			{
				shape = "Block",
				size = Vector3.new(3.4, 2.6, 3.4),
				offset = Vector3.new(0, 17.6, 0),
				angles = Vector3.new(0, -14, 0),
				color = "needle",
				material = Enum.Material.LeafyGrass,
			},
			-- Макушка: ель без острия читается кустом.
			{
				shape = "Block",
				size = Vector3.new(1.6, 2.4, 1.6),
				offset = Vector3.new(0, 19.6, 0),
				angles = Vector3.new(0, 30, 0),
				color = "needleDark",
				material = Enum.Material.LeafyGrass,
			},
		},
		radius = 0,
		height = 0,
	},

	--[[
		Сухостой: три голые ветки и ничего больше.

		Нужен не ради разнообразия, а ради ориентира: на однотонном тёмном полу
		чащи одинаковые ели не дают глазу зацепиться, и игрок теряет, где он
		уже был. Голый ствол виден издалека и не путается с живым деревом.

		ВСЕ ВЕТКИ ОБЯЗАНЫ ВРАСТАТЬ В СТВОЛ, а ствол кончается на высоте
		ArenaProps.TreeHeight — его строит сервер, и выше этой отметки держаться
		уже не за что. Ветка, поднятая выше, висит в небе отдельной палкой:
		так и было, и это видно с любого конца арены. Проверка простая:
		offset.Y плюс половина длины ветки обязаны остаться ниже TreeHeight,
		а горизонтальный вынос — меньше половины её длины, иначе ветка
		не дотягивается до ствола вбок.

		Кроны живых деревьев этого правила не требуют: у них ярусы стоят друг
		на друге сплошняком и держатся один за другой.
	]]
	{
		key = "CrownDead",
		parts = {
			{
				shape = "Cylinder",
				size = Vector3.new(6.4, 0.9, 0.9),
				offset = Vector3.new(1.8, 9.6, 0.4),
				angles = Vector3.new(0, 24, 42),
				color = "trunkDark",
				material = Enum.Material.Wood,
			},
			{
				shape = "Cylinder",
				size = Vector3.new(5.6, 0.8, 0.8),
				offset = Vector3.new(-1.6, 11.4, -0.6),
				angles = Vector3.new(0, -38, -50),
				color = "trunkDark",
				material = Enum.Material.Wood,
			},
			{
				shape = "Cylinder",
				size = Vector3.new(4.2, 0.7, 0.7),
				offset = Vector3.new(0.4, 13, 1),
				angles = Vector3.new(0, 70, 38),
				color = "trunkDark",
				material = Enum.Material.Wood,
			},
			--[[
				Обломанная макушка: сухое дерево с ровным срезом читается
				столбом. Тоньше ствола и наклонена, а нижней половиной сидит
				внутри него — над верхом торчит меньше стада, и «отдельной
				палкой» это не выглядит.
			]]
			{
				shape = "Cylinder",
				size = Vector3.new(3.4, 1.9, 1.9),
				offset = Vector3.new(0.3, 14.4, 0),
				angles = Vector3.new(0, 0, 74),
				color = "trunkDark",
				material = Enum.Material.Wood,
			},
		},
		radius = 0,
		height = 0,
	},

	--[[
		Деревья опушки. Описаны целиком, со стволом: они стоят за невидимой
		стеной, коллизии им не нужно, и серверной половины у них нет.

		Деталей у них меньше, чем у деревьев на арене, намеренно: опушки идёт
		полторы сотни стволов по периметру, и каждая лишняя деталь умножается
		на это число. Разглядывать их вблизи игрок всё равно не может —
		между ним и опушкой стена.
	]]
	{
		key = "WallPine",
		parts = {
			{
				shape = "Cylinder",
				size = Vector3.new(10, 1.8, 1.8),
				offset = Vector3.new(0, 5, 0),
				angles = Vector3.new(0, 0, 90),
				color = "trunkDark",
				material = Enum.Material.Wood,
			},
			{
				shape = "Block",
				size = Vector3.new(9.6, 5.2, 9.6),
				offset = Vector3.new(0, 9.6, 0),
				angles = Vector3.new(0, 16, 0),
				color = "needleDark",
				material = Enum.Material.LeafyGrass,
			},
			{
				shape = "Block",
				size = Vector3.new(7, 4.6, 7),
				offset = Vector3.new(0, 14, 0),
				angles = Vector3.new(0, -24, 0),
				color = "needle",
				material = Enum.Material.LeafyGrass,
			},
			{
				shape = "Block",
				size = Vector3.new(4, 4.2, 4),
				offset = Vector3.new(0, 18, 0),
				angles = Vector3.new(0, 34, 0),
				color = "needleDark",
				material = Enum.Material.LeafyGrass,
			},
		},
		radius = 0,
		height = 0,
	},
	{
		key = "WallBroad",
		parts = {
			{
				shape = "Cylinder",
				size = Vector3.new(11, 2, 2),
				offset = Vector3.new(0, 5.5, 0),
				angles = Vector3.new(0, 0, 90),
				color = "trunk",
				material = Enum.Material.Wood,
			},
			{
				shape = "Block",
				size = Vector3.new(10.4, 6, 9.6),
				offset = Vector3.new(0, 12.4, 0),
				angles = Vector3.new(0, 22, 0),
				color = "leaf",
				material = Enum.Material.LeafyGrass,
			},
			{
				shape = "Block",
				size = Vector3.new(7.6, 5, 7.2),
				offset = Vector3.new(0.8, 16.2, -0.6),
				angles = Vector3.new(0, -30, 0),
				color = "leafDark",
				material = Enum.Material.LeafyGrass,
			},
		},
		radius = 0,
		height = 0,
	},

	--[[
		Мелочь без коллизии. Всё, что здесь есть, игрок и враги проходят
		насквозь, поэтому сюда попадает только то, через что пройти
		правдоподобно: куст по колено, папоротник, трава, камень, пень,
		коряга, гриб, цветок. Дерева здесь нет и быть не может — дерево,
		сквозь которое ходят, читается поломкой, и потому оно препятствие.
	]]
	{
		key = "Bush",
		parts = {
			{
				shape = "Ball",
				size = Vector3.new(4.2, 3, 4),
				offset = Vector3.new(0, 1.4, 0),
				color = "leaf",
				material = Enum.Material.LeafyGrass,
			},
			{
				shape = "Ball",
				size = Vector3.new(3, 2.4, 3),
				offset = Vector3.new(1.2, 2.2, -0.6),
				color = "leafDark",
				material = Enum.Material.LeafyGrass,
			},
		},
		radius = 0,
		height = 0,
	},
	{
		key = "Fern",
		parts = {
			{
				shape = "Wedge",
				size = Vector3.new(0.5, 2.6, 2.2),
				offset = Vector3.new(0, 1.3, 0.6),
				angles = Vector3.new(-18, 0, 0),
				color = "leafDark",
				material = Enum.Material.Grass,
			},
			{
				shape = "Wedge",
				size = Vector3.new(0.5, 2.4, 2),
				offset = Vector3.new(0.7, 1.2, -0.5),
				angles = Vector3.new(16, 130, 0),
				color = "leaf",
				material = Enum.Material.Grass,
			},
			{
				shape = "Wedge",
				size = Vector3.new(0.5, 2.2, 1.8),
				offset = Vector3.new(-0.8, 1.1, -0.4),
				angles = Vector3.new(14, -120, 0),
				color = "leafDark",
				material = Enum.Material.Grass,
			},
		},
		radius = 0,
		height = 0,
	},
	{
		key = "GrassTuft",
		parts = {
			{
				shape = "Wedge",
				size = Vector3.new(0.35, 1.8, 1),
				offset = Vector3.new(0, 0.9, 0),
				angles = Vector3.new(-12, 20, 0),
				color = "blade",
				material = Enum.Material.Grass,
			},
			{
				shape = "Wedge",
				size = Vector3.new(0.35, 1.5, 0.9),
				offset = Vector3.new(0.5, 0.75, 0.3),
				angles = Vector3.new(10, 140, 0),
				color = "blade",
				material = Enum.Material.Grass,
			},
			-- Сухая былинка в каждом кустике: ровно зелёная трава читается
			-- ковром, а разнотон — травой.
			{
				shape = "Wedge",
				size = Vector3.new(0.3, 1.3, 0.8),
				offset = Vector3.new(-0.45, 0.65, -0.25),
				angles = Vector3.new(14, -110, 0),
				color = "bladeDry",
				material = Enum.Material.Grass,
			},
		},
		radius = 0,
		height = 0,
	},
	{
		key = "Rock",
		parts = {
			{
				shape = "Block",
				size = Vector3.new(3.4, 2.2, 3),
				offset = Vector3.new(0, 0.9, 0),
				angles = Vector3.new(6, 24, -8),
				color = "rock",
				material = Enum.Material.Rock,
			},
			{
				shape = "Block",
				size = Vector3.new(2, 1.4, 1.8),
				offset = Vector3.new(1.4, 0.7, 0.8),
				angles = Vector3.new(-5, -30, 10),
				color = "rockDark",
				material = Enum.Material.Rock,
			},
		},
		radius = 0,
		height = 0,
	},
	{
		key = "Stump",
		parts = {
			{
				shape = "Cylinder",
				size = Vector3.new(2.2, 3.2, 3.2),
				offset = Vector3.new(0, 1.1, 0),
				angles = Vector3.new(0, 0, 90),
				color = "trunkDark",
				material = Enum.Material.Wood,
			},
			-- Срез светлее коры: пень без него — просто чурбак.
			{
				shape = "Cylinder",
				size = Vector3.new(0.3, 3, 3),
				offset = Vector3.new(0, 2.3, 0),
				angles = Vector3.new(0, 0, 90),
				color = "trunk",
				material = Enum.Material.Wood,
			},
		},
		radius = 0,
		height = 0,
	},
	{
		key = "Log",
		parts = {
			{
				shape = "Cylinder",
				size = Vector3.new(7, 2, 2),
				offset = Vector3.new(0, 1, 0),
				angles = Vector3.new(0, 0, 0),
				color = "trunkDark",
				material = Enum.Material.Wood,
			},
			{
				shape = "Cylinder",
				size = Vector3.new(2.4, 0.7, 0.7),
				offset = Vector3.new(2.2, 1.6, 0.8),
				angles = Vector3.new(0, 40, 26),
				color = "trunk",
				material = Enum.Material.Wood,
			},
		},
		radius = 0,
		height = 0,
	},
	{
		key = "Mushroom",
		parts = {
			{
				shape = "Cylinder",
				size = Vector3.new(1.2, 0.5, 0.5),
				offset = Vector3.new(0, 0.6, 0),
				angles = Vector3.new(0, 0, 90),
				-- Ножка коры, а не шляпки: bloom — цвет пятна, которое должно
				-- быть видно, и ножка того же цвета съела бы весь эффект.
				color = "trunkDark",
				material = Enum.Material.Wood,
			},
			{
				shape = "Ball",
				size = Vector3.new(1.8, 1, 1.8),
				offset = Vector3.new(0, 1.2, 0),
				color = "bloom",
				material = Enum.Material.SmoothPlastic,
			},
		},
		radius = 0,
		height = 0,
	},
	{
		key = "Flower",
		parts = {
			{
				shape = "Cylinder",
				size = Vector3.new(1.4, 0.2, 0.2),
				offset = Vector3.new(0, 0.7, 0),
				angles = Vector3.new(0, 0, 90),
				color = "blade",
				material = Enum.Material.Grass,
			},
			{
				shape = "Block",
				size = Vector3.new(0.8, 0.25, 0.8),
				offset = Vector3.new(0, 1.4, 0),
				angles = Vector3.new(0, 30, 0),
				color = "bloom",
				material = Enum.Material.SmoothPlastic,
			},
		},
		radius = 0,
		height = 0,
	},
}

--[[
	Холм собирается функцией, а не записью в таблице.

	Причина в том, что у холма нет одного размера: расстановка выдаёт радиус
	и высоту в диапазоне, а деталь, повёрнутую вокруг вертикали, нельзя
	растянуть по осям мира — размеры пришлось бы пересчитывать в её
	собственных осях, и первая же наклонная деталь дала бы перекос.
	Проще посчитать размеры сразу, чем масштабировать готовые.

	Тело холма (цилиндр на всю высоту) строит СЕРВЕР — оно и есть коллизия.
	Здесь только то, чем клиент его накрывает: земляная шапка, валуны у
	подножия и мох на макушке.

	ВЫСОТА — не украшение. Игрок не должен иметь возможности запрыгнуть на
	холм: враги расталкиваются от круга препятствия, и стоящий на макушке
	оказался бы недосягаем для всей арены разом. Диапазон высот задан в
	Balance.Arena и обязан оставаться выше прыжка (Roblox по умолчанию
	даёт около 7.2 стада).
]]
function ArenaProps.HillParts(radius: number, height: number, rng: RNG.RNG): { PartDef }
	local parts: { PartDef } = {}

	--[[
		Земляной купол.

		Ширина ровно по телу, а центр — РОВНО НА ВЕРХУШКЕ цилиндра. Это не
		произвол: самое широкое сечение шара приходится на его центр, поэтому
		ниже верхушки купол нигде не выходит за круг коллизии — нависшего
		края, под которым игрок упирался бы в воздух, не возникает вовсе.
		Купол, посаженный ниже, оставлял бы вокруг себя видимое кольцо
		плоского среза, и холм читался бы столовой горой.
	]]
	table.insert(parts, {
		shape = "Ball",
		size = Vector3.new(radius * 2, height * 0.5, radius * 2),
		offset = Vector3.new(0, height, 0),
		color = "earth",
		material = Enum.Material.Ground,
	})

	-- Мох на макушке: он и делает бугор бугром, а не земляной тумбой.
	table.insert(parts, {
		shape = "Ball",
		size = Vector3.new(radius * 1.55, height * 0.34, radius * 1.55),
		offset = Vector3.new(0, height * 1.08, 0),
		color = "moss",
		material = Enum.Material.Grass,
	})

	table.insert(parts, {
		shape = "Ball",
		size = Vector3.new(radius * 0.9, height * 0.22, radius * 0.8),
		offset = Vector3.new(radius * 0.3, height * 1.14, -radius * 0.2),
		color = "leafDark",
		material = Enum.Material.Grass,
	})

	--[[
		Валуны у подножия. Они закрывают стык цилиндра с полом: без них холм
		стоит на арене приклеенным кружком, и видно, что это цилиндр.
	]]
	local stones = 4
	local turn = rng.NextAngle()

	for index = 1, stones do
		local angle = turn + (index - 1) * math.pi * 2 / stones + rng.NextNumber(-0.3, 0.3)
		local distance = radius * rng.NextNumber(0.82, 0.98)
		local size = radius * rng.NextNumber(0.16, 0.26)

		table.insert(parts, {
			shape = "Block",
			size = Vector3.new(size * 2, size * 1.6, size * 1.8),
			offset = Vector3.new(math.sin(angle) * distance, size * 0.7, math.cos(angle) * distance),
			angles = Vector3.new(0, math.deg(angle) + rng.NextNumber(-30, 30), rng.NextNumber(-8, 8)),
			color = if index % 2 == 0 then "rock" else "rockDark",
			material = Enum.Material.Rock,
		})
	end

	return parts
end

ArenaProps.List = definitions
ArenaProps.ByKey = {} :: { [string]: Def }

--[[
	Имена цветов, которые декор спрашивает у палитры локации.

	Собираются из самих моделей, а не переписываются руками: список, который
	надо обновлять вслед за деталями, разъедется в первый же день, а сверку
	палитр (Config/Biomes) он кормит целиком.

	Цвета холма добавляются отдельно — его детали собираются функцией, и
	пройтись по ним циклом при загрузке не по чему.
]]
local colorNames: { [string]: boolean } = {
	-- Холм: его детали собирает HillParts, и пройтись по ним циклом
	-- при загрузке не по чему.
	earth = true,
	moss = true,
	rock = true,
	rockDark = true,
	--[[
		Пол, его пятна, бок платформы и задник опушки деталями не описаны
		вовсе — их строят ArenaService и ArenaDecorController сами. Но
		палитре они нужны ровно так же, и сверка обязана их требовать.
	]]
	floor = true,
	floorAccent = true,
	patch = true,
	earthDark = true,
	wall = true,
}

for _, def in definitions do
	assert(ArenaProps.ByKey[def.key] == nil, `[ArenaProps] Дубликат ключа "{def.key}"`)
	ArenaProps.ByKey[def.key] = def

	assert(#def.parts > 0, `[ArenaProps] Модель "{def.key}" без деталей`)

	local radius = 0
	local height = 0

	for index, part in def.parts do
		assert(part.color ~= "", `[ArenaProps] "{def.key}", деталь {index}: пустое имя цвета`)
		colorNames[part.color] = true

		--[[
			Габариты считаются без учёта поворота, как у предметов лобби:
			это справка для расстановки (на сколько отодвинуть соседа),
			а не боевой радиус, с которым что-то сверяется.
		]]
		local half = part.size * 0.5
		radius = math.max(radius, math.abs(part.offset.X) + half.X, math.abs(part.offset.Z) + half.Z)
		height = math.max(height, part.offset.Y + half.Y)

		table.freeze(part)
	end

	def.radius = radius
	def.height = height

	table.freeze(def.parts)
	table.freeze(def)
end

local names: { string } = {}
for name in colorNames do
	table.insert(names, name)
end
table.sort(names)

ArenaProps.ColorNames = names

table.freeze(definitions)
table.freeze(ArenaProps.ByKey)
table.freeze(ArenaProps.ColorNames)

return ArenaProps
