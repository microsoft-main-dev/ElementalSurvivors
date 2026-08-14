--!strict
--[[
	Decor — постройка статичного декора: детали моделей из Config/ArenaProps,
	стена леса по периметру и задник за ней.

	ПОЧЕМУ ОТДЕЛЬНЫМ МОДУЛЕМ. Всё это жило внутри ArenaDecorController и было
	на своём месте ровно до тех пор, пока лес рос только на арене. У поляны
	лобби беда та же самая, ради которой задник и появился: за краем — пустое
	небо, и без стены деревьев место читается плитой, висящей в воздухе.
	Второй экземпляр той же геометрии разъехался бы с первым при первой правке
	размеров, и лобби с Лесной поляной перестали бы быть одним лесом.

	Числа сюда НЕ переехали: их даёт вызывающий. У арены и лобби разный размер
	площадки и разный запас до опушки, а конструкция одна.

	Состояния нет, вызовы через точку.

	Публичный API:
		Decor.Color(palette, name)                                   -> Color3
		Decor.Part(parent, name, size, cframe, color, material)      -> BasePart
		Decor.Piece(parent, def, pivot, scale, palette)              -> ()
		Decor.PlaceAll(parent, items, origin, palette, chunk, alive) -> (boolean, number)
		Decor.Scatter(seed, biome, scatter, grass, half, blocked)    -> { Item }
		Decor.TreeRing(seed, biome, step, half, offset, depth)       -> { Item }
		Decor.Backdrop(parent, origin, palette, biome, half, offset, depth, height) -> ()
]]

local ArenaProps = require(script.Parent.Parent.Config.ArenaProps)
local Biomes = require(script.Parent.Parent.Config.Biomes)
local RNG = require(script.Parent.RNG)

local Decor = {}

--[[
	Единица декора: что поставить, где и какого размера.

	parts заполнены только у холма — его детали считаются от радиуса и высоты
	функцией ArenaProps.HillParts, а не берутся готовой записью. У всех
	остальных стоит ключ модели, и детали берутся из ArenaProps.ByKey.
]]
export type Item = {
	key: string,
	parts: { ArenaProps.PartDef }?,
	position: Vector3,
	yaw: number, -- градусы
	scale: number,
}

-- Сколько деталей создаётся между уступками кадра.
local PARTS_PER_CHUNK = 120

-- Сколько раз мелочь пробует встать, прежде чем не встать вовсе.
local SCATTER_ATTEMPTS = 8

local SHAPES: { [string]: Enum.PartType } = {
	Block = Enum.PartType.Block,
	Ball = Enum.PartType.Ball,
	Cylinder = Enum.PartType.Cylinder,
}

--[[
	Цвет по имени из палитры локации.

	Имена сверены при загрузке (Config/Biomes требует их у каждой палитры),
	поэтому здесь остаётся только откат на белый — на случай, если деталь
	добавят раньше, чем цвет.
]]
function Decor.Color(palette: any, name: string): Color3
	return palette[name] or Color3.new(1, 1, 1)
end

local colorOf = Decor.Color

function Decor.Part(
	parent: Instance,
	name: string,
	size: Vector3,
	cframe: CFrame,
	color: Color3,
	material: Enum.Material
): BasePart
	local part = Instance.new("Part")
	part.Name = name
	part.Size = size
	part.CFrame = cframe
	part.Color = color
	part.Material = material
	part.Anchored = true
	--[[
		Ни коллизии, ни лучей, ни касаний. Коллизия здесь была бы прямым
		враньём: препятствия арены перечислены в ArenaLayout, и то, чего в этом
		списке нет, враги обходить не умеют. В лобби у края уже стоит своя
		невидимая стена, и вторая, из деревьев, ей только мешала бы.
	]]
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.CastShadow = false
	part.TopSurface = Enum.SurfaceType.Smooth
	part.BottomSurface = Enum.SurfaceType.Smooth
	part.Parent = parent
	return part
end

--[[
	Одна деталь модели декора.

	scale множит и размер, и смещение: дерево вдвое выше обязано быть вдвое
	толще и нести крону вдвое дальше от земли. Поворот применяется ПОСЛЕ
	смещения, как и во всех сборщиках проекта, иначе наклонённая деталь
	уезжала бы вместе с наклоном.
]]
function Decor.Piece(parent: Instance, def: ArenaProps.PartDef, pivot: CFrame, scale: number, palette: any): ()
	local angles = def.angles
	local rotation = if angles
		then CFrame.Angles(math.rad(angles.X), math.rad(angles.Y), math.rad(angles.Z))
		else CFrame.identity

	local cframe = pivot * CFrame.new(def.offset * scale) * rotation

	if def.shape == "Wedge" then
		-- Клин — отдельный класс, а не форма Part: тонкие былинки травы
		-- и листья папоротника собираются только из него.
		local wedge = Instance.new("WedgePart")
		wedge.Name = "Blade"
		wedge.Size = def.size * scale
		wedge.CFrame = cframe
		wedge.Color = colorOf(palette, def.color)
		wedge.Material = def.material or Enum.Material.SmoothPlastic
		wedge.Anchored = true
		wedge.CanCollide = false
		wedge.CanQuery = false
		wedge.CanTouch = false
		wedge.CastShadow = false
		wedge.Parent = parent
		return
	end

	local part = Decor.Part(
		parent,
		"Piece",
		def.size * scale,
		cframe,
		colorOf(palette, def.color),
		def.material or Enum.Material.SmoothPlastic
	)
	part.Shape = SHAPES[def.shape] or Enum.PartType.Block
end

--[[
	Разложить пачку декора, уступая кадр каждые PARTS_PER_CHUNK деталей.

	Тысяча Instance.new в одном кадре — это заметный рывок ровно в тот момент,
	когда игрок входит в бой или в лобби.

	Возвращает false, если постройку пора бросить (alive сказал «нет»), и
	счётчик деталей текущей порции. Счётчик передаётся между вызовами, а не
	живёт в модуле: постройка прошлого забега может ещё доживать свой кадр
	рядом с новой, и общий счётчик перемешал бы их границы.
]]
function Decor.PlaceAll(
	parent: Instance,
	items: { Item },
	origin: Vector3,
	palette: any,
	chunk: number,
	alive: () -> boolean
): (boolean, number)
	for _, item in items do
		local parts = item.parts or ArenaProps.ByKey[item.key].parts
		local pivot = CFrame.new(origin + item.position) * CFrame.Angles(0, math.rad(item.yaw), 0)

		for _, def in parts do
			Decor.Piece(parent, def, pivot, item.scale, palette)
		end

		chunk += #parts
		if chunk >= PARTS_PER_CHUNK then
			chunk = 0
			task.wait()
			if not alive() then
				return false, chunk
			end
		end
	end

	return true, chunk
end

--[[
	Опушка: стена леса по квадратному периметру площадки со стороной half * 2.

	Стволы стоят ЗА невидимой стеной и коллизии не имеют — она там уже есть.
	Глубина у каждого своя, поэтому один проход по периметру даёт неровную
	полосу в несколько стволов, а не забор в одну линию.

	step приходит из качества: периметр арены — 1600 стадов, и цена шага
	умножается на полторы сотни стволов.
]]
function Decor.TreeRing(
	seed: number,
	biome: Biomes.BiomeDef,
	step: number,
	half: number,
	offset: number,
	depth: number
): { Item }
	local rng = RNG.new(seed)
	local near = half + offset
	local far = near + depth

	local result: { Item } = {}

	--[[
		Проход по четырём сторонам. Вдоль стороны идём от -far до +far,
		чтобы углы закрылись сами: стволы соседних сторон там встретятся
		и встанут гуще, а угол — это как раз то место, откуда видно
		дальше всего.
	]]
	local sides = { Vector3.new(0, 0, -1), Vector3.new(0, 0, 1), Vector3.new(-1, 0, 0), Vector3.new(1, 0, 0) }

	for _, side in sides do
		local along = Vector3.new(side.Z, 0, side.X)
		local position = -far

		while position <= far do
			local depthHere = rng.NextNumber(near, far)
			local shift = rng.NextNumber(-step * 0.4, step * 0.4)
			local species = Biomes.Pick(biome.treeLine, rng)

			table.insert(result, {
				key = species.key,
				parts = nil,
				position = side * depthHere + along * (position + shift),
				yaw = rng.NextNumber(0, 360),
				scale = rng.NextNumber(species.minScale, species.maxScale),
			})

			position += step
		end
	end

	return result
end

--[[
	Мелочь без коллизии по квадрату со стороной half * 2: кусты, папоротник,
	камни, пни, коряги, грибы и трава.

	Куда ей нельзя — решает вызывающий предикатом. У арены это круги препятствий
	(куст, торчащий из холма, читается ошибкой), у поляны лобби — площадь,
	кладка портала и уже стоящие предметы. Общего правила тут нет и быть
	не может, а всё остальное общее.

	Трава идёт отдельным списком, потому что у неё свой бюджет: она дешевле
	всего поштучно и её больше всего, и режется на слабых машинах первой.
]]
function Decor.Scatter(
	seed: number,
	biome: Biomes.BiomeDef,
	scatter: number,
	grass: number,
	half: number,
	blocked: (Vector3) -> boolean
): { Item }
	local rng = RNG.new(seed)
	local result: { Item } = {}

	local function place(list: { Biomes.Species }, count: number): ()
		for _ = 1, count do
			--[[
				Несколько попыток на предмет, а не поиск свободного места
				до победного: не поместившийся куст просто не ставится.
				Пустое место в лесу глазу незаметно, а зависший цикл
				на старте забега — очень даже.
			]]
			for _ = 1, SCATTER_ATTEMPTS do
				local position = Vector3.new(rng.NextNumber(-half, half), 0, rng.NextNumber(-half, half))

				if not blocked(position) then
					local species = Biomes.Pick(list, rng)
					table.insert(result, {
						key = species.key,
						parts = nil,
						position = position,
						yaw = rng.NextNumber(0, 360),
						scale = rng.NextNumber(species.minScale, species.maxScale),
					})
					break
				end
			end
		end
	end

	place(biome.scatter, scatter)
	place(biome.grass, grass)

	return result
end

--[[
	Земля за площадкой и стена леса за ней.

	Оба нужны по одной причине: за краем — пустое небо, и без них площадка
	читается плитой, висящей в воздухе, что бы на ней ни росло. Туман здесь
	не помощник: на скайбокс он не действует вовсе, небо прячется только
	геометрией.

	half — половина стороны площадки, offset и depth — те же, что у опушки:
	задник обязан стоять ЗА ней, и считать его отдельным числом значило бы
	однажды подвинуть деревья и оставить стену на месте.
]]
function Decor.Backdrop(
	parent: Instance,
	origin: Vector3,
	palette: any,
	biome: Biomes.BiomeDef,
	half: number,
	offset: number,
	depth: number,
	height: number
): ()
	-- Запас за опушкой: стена стоит не вплотную к последнему стволу, иначе
	-- лес читается нарисованным на ней, а не растущим перед ней.
	local band = half + offset + depth + 27
	local reach = band + 8
	local width = reach - half
	local middle = half + width * 0.5

	--[[
		Подстилка под опушкой — КОЛЬЦО из четырёх блоков, а не один блин.

		Блин был проще, но его верх приходилось топить ниже пола площадки: два
		совпадающих по высоте лица (его и пола) мерцают друг сквозь друга.
		Утопленный блин, в свою очередь, оставлял ступеньку — деревья опушки
		висели над землёй, а под стеной леса светилась щель.

		Кольцо не пересекается с полом вовсе, поэтому его верх ставится ровно
		на ноль: земля за краем продолжается без стыка, и всё, что на ней
		стоит, стоит на ней по-настоящему. Швов между четырьмя кусками
		не видно — они одного цвета и материала и сходятся вплотную.
	]]
	local plates = {
		{ offset = Vector3.new(0, 0, -middle), size = Vector3.new(reach * 2, 2, width) },
		{ offset = Vector3.new(0, 0, middle), size = Vector3.new(reach * 2, 2, width) },
		{ offset = Vector3.new(-middle, 0, 0), size = Vector3.new(width, 2, half * 2) },
		{ offset = Vector3.new(middle, 0, 0), size = Vector3.new(width, 2, half * 2) },
	}

	for index, plate in plates do
		local ground = Decor.Part(
			parent,
			`OuterGround{index}`,
			plate.size,
			CFrame.new(origin + plate.offset + Vector3.new(0, -1, 0)),
			colorOf(palette, "floor"),
			biome.floorMaterial
		)
		ground.TopSurface = Enum.SurfaceType.Smooth
	end

	local sides = {
		Vector3.new(0, 0, -band),
		Vector3.new(0, 0, band),
		Vector3.new(-band, 0, 0),
		Vector3.new(band, 0, 0),
	}

	--[[
		Стена уходит НИЖЕ земли на пару стадов.

		Поставленная точно на ноль, она давала светящуюся щель по всему
		периметру: любая неточность в стыке двух граней — это просвет,
		а за просветом небо, которое туман не красит вовсе.
	]]
	local sink = 3
	local total = height + sink

	for index, sideOffset in sides do
		local length = band * 2 + 12
		local size = if sideOffset.X == 0 then Vector3.new(length, total, 6) else Vector3.new(6, total, length)

		Decor.Part(
			parent,
			`Backdrop{index}`,
			size,
			CFrame.new(origin + sideOffset + Vector3.new(0, total * 0.5 - sink, 0)),
			colorOf(palette, "wall"),
			Enum.Material.Slate
		)
	end
end

return Decor
