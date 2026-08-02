--!strict
--[[
	Pool — пул переиспользуемых объектов (раздел 3.3 ТЗ).

	Смысл: в бою не должно быть ни одного Instance.new. Все части врагов
	создаются заранее, дальше только включаются и выключаются.

	Как и SpatialHash, реализован на замыканиях — отсюда вызовы через точку.

	Публичный API:
		Pool.new(factory, reset, initialSize) -> Pool<T>
		pool.Get()          -> T
		pool.Release(item)
		pool.ReleaseAll()   -- вернуть в пул всё выданное разом (конец забега)
		pool.Size()         -> сколько объектов создано всего
		pool.ActiveCount()  -> сколько сейчас выдано
		pool.Destroy()
]]

export type Pool<T> = {
	Get: () -> T,
	Release: (item: T) -> (),
	ReleaseAll: () -> (),
	Size: () -> number,
	ActiveCount: () -> number,
	Destroy: () -> (),
}

local Pool = {}

--[[
	factory — создаёт новый объект.
	reset   — приводит объект в «выключенное» состояние при возврате в пул.
	initialSize — сколько создать заранее, чтобы не создавать в бою.
]]
function Pool.new<T>(factory: () -> T, reset: ((item: T) -> ())?, initialSize: number?): Pool<T>
	local free: { T } = {}
	local freeCount = 0
	local created = 0

	-- Выданные объекты нужны, чтобы ReleaseAll вернул в пул всё,
	-- а не просто обнулил счётчик.
	local active: { [any]: boolean } = {}
	local activeCount = 0

	local api = {}

	function api.Get(): T
		local item: T
		if freeCount > 0 then
			item = free[freeCount]
			free[freeCount] = nil :: any
			freeCount -= 1
		else
			item = factory()
			created += 1
		end
		active[item] = true
		activeCount += 1
		return item
	end

	function api.Release(item: T): ()
		if not active[item] then
			return
		end
		active[item] = nil
		activeCount -= 1

		if reset then
			reset(item)
		end
		freeCount += 1
		free[freeCount] = item
	end

	function api.ReleaseAll(): ()
		for item in active do
			if reset then
				reset(item)
			end
			freeCount += 1
			free[freeCount] = item
		end
		table.clear(active)
		activeCount = 0
	end

	function api.Size(): number
		return created
	end

	function api.ActiveCount(): number
		return activeCount
	end

	function api.Destroy(): ()
		api.ReleaseAll()
		for index = 1, freeCount do
			local item = free[index] :: any
			if typeof(item) == "Instance" then
				item:Destroy()
			end
		end
		table.clear(free)
		freeCount = 0
		created = 0
	end

	local warmup = initialSize or 0
	for _ = 1, warmup do
		local item = factory()
		created += 1
		if reset then
			reset(item)
		end
		freeCount += 1
		free[freeCount] = item
	end

	return api
end

return Pool
