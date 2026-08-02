--!strict
--[[
	RNG — детерминированный генератор по seed.

	Нужен, чтобы сервер и клиент собрали одинаковую арену из одного числа:
	сервер шлёт только seed, декор клиент строит сам и на сервер он не реплицируется.
	Random.new(seed) в Roblox даёт одинаковую последовательность на всех машинах.

	Вызовы через точку, как у остальных утилит.

	Публичный API:
		RNG.new(seed)                    -> RNG
		rng.NextNumber(min, max)         -> number
		rng.NextInteger(min, max)        -> number
		rng.NextAngle()                  -> number   (радианы, 0..2pi)
		rng.NextUnitVector()             -> Vector3  (в плоскости XZ, длина 1)
		rng.NextChoice(list)             -> T
]]

export type RNG = {
	NextNumber: (min: number, max: number) -> number,
	NextInteger: (min: number, max: number) -> number,
	NextAngle: () -> number,
	NextUnitVector: () -> Vector3,
	NextChoice: <T>(list: { T }) -> T,
}

local TAU = math.pi * 2

local RNG = {}

function RNG.new(seed: number): RNG
	local random = Random.new(seed)

	local api = {}

	function api.NextNumber(min: number, max: number): number
		return random:NextNumber(min, max)
	end

	function api.NextInteger(min: number, max: number): number
		return random:NextInteger(min, max)
	end

	function api.NextAngle(): number
		return random:NextNumber(0, TAU)
	end

	function api.NextUnitVector(): Vector3
		local angle = random:NextNumber(0, TAU)
		return Vector3.new(math.cos(angle), 0, math.sin(angle))
	end

	function api.NextChoice<T>(list: { T }): T
		return list[random:NextInteger(1, #list)]
	end

	return api
end

return RNG
