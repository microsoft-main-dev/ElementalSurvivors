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
-- Псевдоним, а не Decor: ниже экспортируется тип с таким же именем, и внутри
-- псевдонима типа модуль и тип различить было бы нечем.
local DecorKit = require(script.Parent.Decor)
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
	Единица декора живёт в Shared/Util/Decor: её строит не только арена.
	Имя здесь остаётся прежним — на него ссылается весь клиентский декор.
]]
export type Decor = DecorKit.Item

local ArenaLayout = {}

local MAX_ATTEMPTS_PER_ITEM = 40
local MIN_GAP = 8 -- минимальный просвет между препятствиями, чтобы не было глухих стен
local TREE_GAP = 4 -- дереву у подножия холма тесниться можно, оно тонкое
local EXIT_CLEARANCE = 22

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
]]
function ArenaLayout.Decor(seed: number, biome: Biomes.BiomeDef, scatter: number, grass: number): { Decor }
	local obstacles = ArenaLayout.Generate(seed)

	--[[
		Единственное, чем расстановка арены отличается от расстановки поляны
		лобби: там мелочь обходит препятствия, здесь — площадь и предметы.
		Всё остальное общее и живёт в Shared/Util/Decor.
	]]
	local function blocked(position: Vector3): boolean
		for _, obstacle in obstacles do
			local dx = position.X - obstacle.position.X
			local dz = position.Z - obstacle.position.Z
			if dx * dx + dz * dz < obstacle.radius * obstacle.radius then
				return true
			end
		end

		return false
	end

	return DecorKit.Scatter(seed + 2, biome, scatter, grass, Balance.Arena.size * 0.5 - 10, blocked)
end

--[[
	Опушка: стена леса за периметром арены.

	Сама расстановка общая (Shared/Util/Decor) — такая же опушка стоит вокруг
	поляны лобби. Здесь остаются только числа арены; смещение seed сохранено,
	иначе тот же seed дал бы другой лес, чем до переезда.
]]
function ArenaLayout.TreeLine(seed: number, biome: Biomes.BiomeDef, step: number): { Decor }
	local numbers = Balance.Arena
	return DecorKit.TreeRing(seed + 3, biome, step, numbers.size * 0.5, numbers.treeLineOffset, numbers.treeLineDepth)
end

return ArenaLayout
