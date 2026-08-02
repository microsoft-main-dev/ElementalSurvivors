--!strict
--[[
	SpatialHash — равномерная сетка для поиска соседей (раздел 3.2 ТЗ).

	Работает поверх Structure of Arrays врагов: хеш не владеет данными,
	он только раскладывает индексы по ячейкам и хранит ссылку на массив позиций.

	Внутри — замыкания вместо метатаблиц: обращение к upvalue дешевле поиска
	по __index, а строгая типизация получается без трюков с typeof(setmetatable).
	Поэтому вызовы через точку: hash.Rebuild(...), а не hash:Rebuild(...).

	Позиции — локальные координаты арены (относительно её origin), поэтому
	числа маленькие и точности float хватает с запасом.

	Публичный API:
		SpatialHash.new(cellSize)                       -> SpatialHash
		hash.Rebuild(positions, alive, highWater)       -- раз за тик
		hash.Collect(position, radius, out)             -> count   (без аллокаций)
		hash.ForEachNear(position, radius, fn)                     (не реентерабельно)
		hash.Clear()
]]

export type SpatialHash = {
	Rebuild: (positions: { [number]: Vector3 }, alive: { [number]: boolean }, highWater: number) -> (),
	Collect: (position: Vector3, radius: number, out: { number }) -> number,
	ForEachNear: (position: Vector3, radius: number, fn: (id: number) -> ()) -> (),
	Clear: () -> (),
}

local SpatialHash = {}

-- Упаковка координат ячейки в одно число. Диапазон с огромным запасом:
-- арена 400 стадов при ячейке 8 даёт всего ±25.
local KEY_OFFSET = 16384
local KEY_STRIDE = 32768

local function keyOf(cx: number, cz: number): number
	return (cx + KEY_OFFSET) * KEY_STRIDE + (cz + KEY_OFFSET)
end

function SpatialHash.new(cellSize: number): SpatialHash
	local inverseCell = 1 / cellSize

	-- key -> массив индексов врагов; counts[key] — сколько из них актуальны.
	-- Массивы переиспользуются: в горячем цикле не должно быть аллокаций.
	local cells: { [number]: { number } } = {}
	local counts: { [number]: number } = {}
	local usedKeys: { number } = {}
	local usedCount = 0

	local positionsRef: { [number]: Vector3 } = {}
	local scratch: { number } = {}

	local api = {}

	function api.Clear(): ()
		for index = 1, usedCount do
			counts[usedKeys[index]] = 0
		end
		usedCount = 0
	end

	function api.Rebuild(positions: { [number]: Vector3 }, alive: { [number]: boolean }, highWater: number): ()
		api.Clear()
		positionsRef = positions

		for id = 1, highWater do
			if alive[id] then
				local position = positions[id]
				local key = keyOf(math.floor(position.X * inverseCell), math.floor(position.Z * inverseCell))

				local count = counts[key]
				if count == nil or count == 0 then
					if cells[key] == nil then
						cells[key] = {}
					end
					usedCount += 1
					usedKeys[usedCount] = key
					count = 0
				end

				count += 1
				cells[key][count] = id
				counts[key] = count
			end
		end
	end

	function api.Collect(position: Vector3, radius: number, out: { number }): number
		local minX = math.floor((position.X - radius) * inverseCell)
		local maxX = math.floor((position.X + radius) * inverseCell)
		local minZ = math.floor((position.Z - radius) * inverseCell)
		local maxZ = math.floor((position.Z + radius) * inverseCell)

		local originX, originZ = position.X, position.Z
		local radiusSquared = radius * radius
		local found = 0

		for cx = minX, maxX do
			for cz = minZ, maxZ do
				local key = keyOf(cx, cz)
				local count = counts[key]
				if count ~= nil and count > 0 then
					local cell = cells[key]
					for index = 1, count do
						local id = cell[index]
						local candidate = positionsRef[id]
						local dx = candidate.X - originX
						local dz = candidate.Z - originZ
						if dx * dx + dz * dz <= radiusSquared then
							found += 1
							out[found] = id
						end
					end
				end
			end
		end

		return found
	end

	function api.ForEachNear(position: Vector3, radius: number, fn: (id: number) -> ()): ()
		local found = api.Collect(position, radius, scratch)
		for index = 1, found do
			fn(scratch[index])
		end
	end

	return api
end

return SpatialHash
