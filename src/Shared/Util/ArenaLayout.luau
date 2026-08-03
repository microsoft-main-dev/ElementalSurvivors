--!strict
--[[
	ArenaLayout — расстановка декора арены по seed.

	Единственный источник правды о том, где на арене стоят колонны. Пользуются им трое:
	- ArenaService строит из этого настоящие Part с коллизией;
	- EnemyService расталкивает от них врагов;
	- EnemyRenderController делает то же самое в клиентской симуляции.

	Именно поэтому генерация лежит в Shared и детерминирована: сервер и клиент
	обязаны получить из одного seed один и тот же набор, иначе враги на экране
	будут обходить не те колонны, что на сервере.

	Координаты локальные для арены (центр в нуле, Y = 0).

	Публичный API:
		ArenaLayout.Generate(seed) -> { Obstacle }
]]

local Balance = require(script.Parent.Parent.Config.Balance)
local RNG = require(script.Parent.RNG)

export type Obstacle = {
	position: Vector3,
	size: Vector3,
	angle: number,
	radius: number, -- радиус круга столкновения; коробки почти квадратные, круга хватает
}

local ArenaLayout = {}

local MAX_ATTEMPTS_PER_ITEM = 40
local MIN_GAP = 8 -- минимальный просвет между колоннами, чтобы не было глухих стен
local EXIT_CLEARANCE = 22

function ArenaLayout.Generate(seed: number): { Obstacle }
	local rng = RNG.new(seed)
	local half = Balance.Arena.size * 0.5 - 24
	local clearCenter = Balance.Arena.decorClearRadius
	local exitZ = Balance.Arena.exitOffset

	local result: { Obstacle } = {}
	local wanted = Balance.Arena.decorCount
	local attempts = 0

	while #result < wanted and attempts < wanted * MAX_ATTEMPTS_PER_ITEM do
		attempts += 1

		local x = rng.NextNumber(-half, half)
		local z = rng.NextNumber(-half, half)
		local width = rng.NextNumber(6, 15)
		local height = rng.NextNumber(9, 26)
		local radius = width * 0.5

		-- Точка появления игрока и площадка выхода должны остаться свободными.
		if x * x + z * z < (clearCenter + radius) ^ 2 then
			continue
		end

		local exitDz = z - exitZ
		if x * x + exitDz * exitDz < (EXIT_CLEARANCE + radius) ^ 2 then
			continue
		end

		local overlaps = false
		for _, other in result do
			local dx = x - other.position.X
			local dz = z - other.position.Z
			local minimum = radius + other.radius + MIN_GAP
			if dx * dx + dz * dz < minimum * minimum then
				overlaps = true
				break
			end
		end

		if not overlaps then
			table.insert(result, {
				position = Vector3.new(x, 0, z),
				size = Vector3.new(width, height, width),
				angle = rng.NextAngle(),
				radius = radius,
			})
		end
	end

	return result
end

return ArenaLayout
