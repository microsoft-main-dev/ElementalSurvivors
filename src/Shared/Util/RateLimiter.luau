--!strict
--[[
	RateLimiter — счётчик вызовов на игрока (раздел 7 ТЗ).

	Вешается на каждый Remote, который принимает данные от клиента. Скользящее
	окно: не больше maxCalls вызовов за window секунд. Превышение возвращает
	false, а вызывающая сторона решает, что делать — игнорировать или логировать.

	Вызовы через точку, как у остальных утилит.

	Публичный API:
		RateLimiter.new(maxCalls, window) -> RateLimiter
		limiter.Allow(player)   -> boolean
		limiter.Forget(player)                    -- вызывать на PlayerRemoving
]]

export type RateLimiter = {
	Allow: (player: Player) -> boolean,
	Forget: (player: Player) -> (),
}

local RateLimiter = {}

function RateLimiter.new(maxCalls: number, window: number): RateLimiter
	-- На игрока хранится кольцо отметок времени: без аллокаций на каждый вызов.
	local stamps: { [Player]: { number } } = {}
	local cursors: { [Player]: number } = {}

	local api = {}

	function api.Allow(player: Player): boolean
		local ring = stamps[player]
		if not ring then
			ring = table.create(maxCalls, 0)
			stamps[player] = ring
			cursors[player] = 0
		end

		local cursor = cursors[player] % maxCalls + 1
		local now = os.clock()

		-- Самая старая отметка в кольце: если она свежее окна, лимит исчерпан.
		if now - ring[cursor] < window then
			return false
		end

		ring[cursor] = now
		cursors[player] = cursor
		return true
	end

	function api.Forget(player: Player): ()
		stamps[player] = nil
		cursors[player] = nil
	end

	return api
end

return RateLimiter
