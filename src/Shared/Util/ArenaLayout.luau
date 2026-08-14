--!strict
--[[
	ArenaLayout — расстановка препятствий и декора арены по seed.

	Единственный источник правды о том, где на арене что стоит. У препятствий
	пользователей трое:
	- ArenaService строит из этого настоящие Part с коллизией;
	- EnemyService расталкивает от них врагов;
	- EnemyRenderController делает то же самое в клиентской симуляции.

	Именно поэтому генерация лежит в Shared и детерминирована: сервер и клиент
	обязаны получить из одного seed один и тот же набор, иначе враги на экране
	будут обходить не то, что на сервере.

	ПРЕПЯТСТВИЙ ДВА ВИДА — холм и дерево. Оба круглые в плане, и круга хватает:
	расталкивание сравнивает расстояние с радиусом. Всё остальное на арене
	(кусты, трава, камни, коряги) коллизии не имеет вовсе, живёт только
	на клиенте и в Generate не попадает.

	Координаты локальные для арены (центр в нуле, Y = 0).

	Публичный API:
		ArenaLayout.Generate(seed)                        -> { Obstacle }
		ArenaLayout.ObstacleDecor(seed, biome)            -> { Decor }
		ArenaLayout.Decor(seed, biome, scatter, grass)    -> { Decor }
		ArenaLayout.TreeLine(seed, biome, step)           -> { Decor }
]]

local ArenaProps = require(script.Parent.Parent.Config.ArenaProps)
local Balance = require(script.Parent.Parent.Config.Balance)
local Biomes = require(script.Parent.Parent.Config.Biomes)
local RNG = require(script.Parent.RNG)

export type Obstacle = {
	kind: "Hill" | "Tree",
	position: Vector3,
	--[[
		Габарит коллизии: X и Z — диаметр, Y — высота. Препятствия круглые,
		поэтому X всегда равен Z, а сервер строит из этого цилиндр.
	]]
	size: Vector3,
	angle: number,
	radius: number, -- радиус круга столкновения
	scale: number, -- множитель модели; у холма всегда 1, размеры у него свои
}

--[[
	Единица декора: что поставить, где и какого размера.

	parts заполнены только у холма — его детали считаются от радиуса и высоты
	функцией ArenaProps.HillParts, а не берутся готовой записью. У всех
	остальных стоит ключ модели, и детали берутся из ArenaProps.ByKey.
]]
export type Decor = {
	key: string,
	parts: { ArenaProps.PartDef }?,
	position: Vector3,
	yaw: number, -- градусы
	scale: number,
}

local ArenaLayout = {}

local MAX_ATTEMPTS_PER_ITEM = 40
local MIN_GAP = 8 -- минимальный просвет между препятствиями, чтобы не было глухих стен
local TREE_GAP = 4 -- дереву у подножия холма тесниться можно, оно тонкое
local EXIT_CLEARANCE = 22
local SCATTER_ATTEMPTS = 8

--[[
	Свободна ли точка: не в круге спавна игрока, не на площадке выхода и
	не внутри уже поставленного препятствия.
]]
local function isClear(x: number, z: number, radius: number, placed: { Obstacle }, gap: number): boolean
	local clearCenter = Balance.Arena.decorClearRadius
	if x * x + z * z < (clearCenter + radius) ^ 2 then
		return false
	end

	local exitDz = z - Balance.Arena.exitOffset
	if x * x + exitDz * exitDz < (EXIT_CLEARANCE + radius) ^ 2 then
		return false
	end

	for _, other in placed do
		local dx = x - other.position.X
		local dz = z - other.position.Z
		local minimum = radius + other.radius + gap
		if dx * dx + dz * dz < minimum * minimum then
			return false
		end
	end

	return true
end

function ArenaLayout.Generate(seed: number): { Obstacle }
	local numbers = Balance.Arena
	local rng = RNG.new(seed)
	local half = numbers.size * 0.5 - 24

	local result: { Obstacle } = {}

	--[[
		Холмы идут первыми, деревья вторыми и оба вида — из одного потока
		случайных чисел. Порядок здесь важен не эстетически: seed обязан
		давать один и тот же набор у сервера и у клиента, а перестановка
		вызовов rng меняет всё, что после неё.
	]]
	local attempts = 0
	while #result < numbers.hillCount and attempts < numbers.hillCount * MAX_ATTEMPTS_PER_ITEM do
		attempts += 1

		local x = rng.NextNumber(-half, half)
		local z = rng.NextNumber(-half, half)
		local radius = rng.NextNumber(numbers.hillRadiusMin, numbers.hillRadiusMax)
		--[[
			Высота ВЫВОДИТСЯ из радиуса, а не бросается отдельно: узкий и
			высокий холм — это колонна, от которой мы как раз и уходим.
			Самый узкий получает минимум высоты, самый широкий — максимум,
			и пропорция остаётся холмом на всём диапазоне.
		]]
		local spread = math.max(numbers.hillRadiusMax - numbers.hillRadiusMin, 1e-3)
		local fraction = (radius - numbers.hillRadiusMin) / spread
		local height = numbers.hillHeightMin + (numbers.hillHeightMax - numbers.hillHeightMin) * fraction

		if isClear(x, z, radius, result, MIN_GAP) then
			table.insert(result, {
				kind = "Hill",
				position = Vector3.new(x, 0, z),
				size = Vector3.new(radius * 2, height, radius * 2),
				angle = rng.NextAngle(),
				radius = radius,
				scale = 1,
			})
		end
	end

	local trees = 0
	attempts = 0
	while trees < numbers.treeCount and attempts < numbers.treeCount * MAX_ATTEMPTS_PER_ITEM do
		attempts += 1

		local x = rng.NextNumber(-half, half)
		local z = rng.NextNumber(-half, half)
		local scale = rng.NextNumber(numbers.treeScaleMin, numbers.treeScaleMax)
		--[[
			Радиус препятствия — это радиус ствола, и ничей больше. Крона
			шире, но сквозь неё игрок проходит: упираться в воздух под
			веткой он не должен.
		]]
		local radius = ArenaProps.TreeRadius * scale

		if isClear(x, z, radius, result, TREE_GAP) then
			trees += 1
			table.insert(result, {
				kind = "Tree",
				position = Vector3.new(x, 0, z),
				size = Vector3.new(radius * 2, ArenaProps.TreeHeight * scale, radius * 2),
				angle = rng.NextAngle(),
				radius = radius,
				scale = scale,
			})
		end
	end

	return result
end

--[[
	Чем клиент одевает препятствия: шапка и валуны на холм, крона на ствол.

	По одной записи на препятствие и тем же порядком, что у Generate. Тело
	холма и ствол дерева сюда не входят — их строит сервер, они и есть
	коллизия, и рисовать их вторым слоем значило бы удвоить геометрию.

	Свой поток случайных чисел: вид кроны выбирает биом, а биома у сервера
	нет вовсе, и подмешивать эти жеребьёвки в общий поток Generate нельзя —
	расстановка препятствий обязана остаться одинаковой у обеих сторон.
]]
function ArenaLayout.ObstacleDecor(seed: number, biome: Biomes.BiomeDef): { Decor }
	local rng = RNG.new(seed + 1)
	local result: { Decor } = {}

	for _, obstacle in ArenaLayout.Generate(seed) do
		if obstacle.kind == "Hill" then
			table.insert(result, {
				key = "Hill",
				parts = ArenaProps.HillParts(obstacle.radius, obstacle.size.Y, rng),
				position = obstacle.position,
				yaw = math.deg(obstacle.angle),
				scale = 1,
			})
		else
			local species = Biomes.Pick(biome.trees, rng)
			table.insert(result, {
				key = species.key,
				parts = nil,
				position = obstacle.position,
				yaw = math.deg(obstacle.angle),
				-- Размер кроны задаёт расстановка, а не биом: крона обязана
				-- совпасть со стволом, который сервер уже построил.
				scale = obstacle.scale,
			})
		end
	end

	return result
end

--[[
	Мелочь без коллизии: кусты, папоротник, камни, пни, коряги и трава.

	Внутрь препятствий не попадает (куст, торчащий из холма, читается
	ошибкой), но круг спавна и площадку выхода не обходит: сквозь эту
	мелочь ходят, и запрещать ей расти там, где стоит игрок, незачем.

	Трава считается отдельным списком, потому что у неё свой бюджет: она
	дешевле всего поштучно и её больше всего, и режется на слабых машинах
	первой.
]]
function ArenaLayout.Decor(seed: number, biome: Biomes.BiomeDef, scatter: number, grass: number): { Decor }
	local rng = RNG.new(seed + 2)
	local obstacles = ArenaLayout.Generate(seed)
	local half = Balance.Arena.size * 0.5 - 10

	local result: { Decor } = {}

	local function place(list: { Biomes.Species }, count: number): ()
		for _ = 1, count do
			--[[
				Несколько попыток на предмет, а не поиск свободного места
				до победного: не поместившийся куст просто не ставится.
				Пустое место в лесу глазу незаметно, а зависший цикл
				на старте забега — очень даже.
			]]
			for _ = 1, SCATTER_ATTEMPTS do
				local x = rng.NextNumber(-half, half)
				local z = rng.NextNumber(-half, half)

				local blocked = false
				for _, obstacle in obstacles do
					local dx = x - obstacle.position.X
					local dz = z - obstacle.position.Z
					if dx * dx + dz * dz < obstacle.radius * obstacle.radius then
						blocked = true
						break
					end
				end

				if not blocked then
					local species = Biomes.Pick(list, rng)
					table.insert(result, {
						key = species.key,
						parts = nil,
						position = Vector3.new(x, 0, z),
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
	Опушка: стена леса за периметром арены.

	Стволы стоят ЗА невидимой стеной и коллизии не имеют — она там уже есть.
	Глубина у каждого своя, поэтому один проход по периметру даёт неровную
	полосу в несколько стволов, а не забор в одну линию.

	step приходит из качества: периметр арены — 1600 стадов, и цена шага
	умножается на полторы сотни стволов.
]]
function ArenaLayout.TreeLine(seed: number, biome: Biomes.BiomeDef, step: number): { Decor }
	local numbers = Balance.Arena
	local rng = RNG.new(seed + 3)
	local half = numbers.size * 0.5
	local near = half + numbers.treeLineOffset
	local far = near + numbers.treeLineDepth

	local result: { Decor } = {}

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
			local depth = rng.NextNumber(near, far)
			local offset = rng.NextNumber(-step * 0.4, step * 0.4)
			local species = Biomes.Pick(biome.treeLine, rng)

			table.insert(result, {
				key = species.key,
				parts = nil,
				position = side * depth + along * (position + offset),
				yaw = rng.NextNumber(0, 360),
				scale = rng.NextNumber(species.minScale, species.maxScale),
			})

			position += step
		end
	end

	return result
end

return ArenaLayout
