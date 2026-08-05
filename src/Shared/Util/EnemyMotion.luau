--!strict
--[[
	EnemyMotion — вся математика движения врагов.

	Строго чистые функции: ни одного обращения к Instance, ни одного глобального
	состояния. Это требование раздела 3.2 ТЗ — при упоре в CPU движение и
	расталкивание выносятся в parallel Luau без переписывания.

	Тот же код работает на клиенте (раздел 3.3): клиент повторяет ТОЛЬКО Chase.
	Расталкивание остаётся серверным — у клиента другой набор соседей
	(часть врагов ещё не доехала событием спавна), и повторение Separation
	накапливало бы расхождение вместо того, чтобы его гасить.

	Позиции — локальные координаты арены, Y всегда 0: враги двигаются по плоскости,
	высота добавляется только при отрисовке.
]]

local EnemyMotion = {}

-- Шаг к цели по прямой. Возвращает новую позицию.
function EnemyMotion.Chase(position: Vector3, target: Vector3, speed: number, dt: number): Vector3
	local dx = target.X - position.X
	local dz = target.Z - position.Z
	local distanceSquared = dx * dx + dz * dz

	if distanceSquared < 1e-6 then
		return position
	end

	local distance = math.sqrt(distanceSquared)
	local step = math.min(speed * dt, distance)
	local inverse = step / distance

	return Vector3.new(position.X + dx * inverse, 0, position.Z + dz * inverse)
end

--[[
	Движение стрелка: держать дистанцию, а не бежать вплотную.

	Ближе preferredRange — отходит, дальше preferredRange + margin — подходит,
	между ними стоит и стреляет. Полоса нужна обязательно: без неё враг на
	границе дёргался бы вперёд-назад каждый кадр.

	Живёт здесь, а не на сервере, по той же причине, что и Chase: движение
	врагов повторяет клиент, и поведение, известное только серверу, разошлось бы
	картинкой с уроном.
]]
function EnemyMotion.KeepRange(
	position: Vector3,
	target: Vector3,
	speed: number,
	dt: number,
	preferredRange: number,
	margin: number
): Vector3
	local dx = target.X - position.X
	local dz = target.Z - position.Z
	local distanceSquared = dx * dx + dz * dz

	if distanceSquared < 1e-6 then
		return position
	end

	local distance = math.sqrt(distanceSquared)

	if distance > preferredRange + margin then
		return EnemyMotion.Chase(position, target, speed, dt)
	end

	if distance >= preferredRange then
		-- В своей полосе: стоит и стреляет.
		return position
	end

	-- Слишком близко — отходит спиной по той же прямой.
	local step = speed * dt
	local inverse = step / distance
	return Vector3.new(position.X - dx * inverse, 0, position.Z - dz * inverse)
end

--[[
	Мягкое расталкивание соседей, чтобы толпа не слипалась в одну точку.

	neighbourIds/positions — результат SpatialHash.Collect: массив индексов
	и общий массив позиций. Свой собственный id в списке игнорируется.
	Сила падает линейно от радиуса к нулю — это дешевле обратного квадрата
	и не даёт взрывных выбросов при полном совпадении позиций.
]]
function EnemyMotion.Separation(
	selfId: number,
	position: Vector3,
	neighbourIds: { number },
	positions: { [number]: Vector3 },
	count: number,
	radius: number,
	strength: number,
	dt: number
): Vector3
	if count <= 1 then
		return position
	end

	local pushX = 0
	local pushZ = 0
	local inverseRadius = 1 / radius

	for index = 1, count do
		local id = neighbourIds[index]
		if id ~= selfId then
			local other = positions[id]
			local dx = position.X - other.X
			local dz = position.Z - other.Z
			local distanceSquared = dx * dx + dz * dz

			if distanceSquared < 1e-6 then
				-- Позиции совпали: расталкиваем детерминированно, по разнице id,
				-- иначе враги останутся склеенными навсегда.
				local angle = (selfId - id) * 0.7
				pushX += math.cos(angle)
				pushZ += math.sin(angle)
			elseif distanceSquared < radius * radius then
				local distance = math.sqrt(distanceSquared)
				local weight = (1 - distance * inverseRadius) / distance
				pushX += dx * weight
				pushZ += dz * weight
			end
		end
	end

	if pushX == 0 and pushZ == 0 then
		return position
	end

	local scale = strength * dt
	return Vector3.new(position.X + pushX * scale, 0, position.Z + pushZ * scale)
end

--[[
	Выталкивание из колонн арены.

	Поиска пути у врагов нет и не будет — при сотнях врагов он неподъёмен.
	Вместо него: враг идёт к игроку по прямой, а если оказался внутри круга
	колонны, его выносит на её границу. Поскольку преследование продолжает
	тянуть его вперёд, враг соскальзывает вдоль колонны и обходит её.
	Выглядит естественно и стоит один корень на пересечение.

	obstacleIds/positions/radii — как у SpatialHash.Collect: массив индексов
	и общие массивы данных препятствий.
]]
function EnemyMotion.PushOutOfObstacles(
	position: Vector3,
	obstacleIds: { number },
	obstaclePositions: { [number]: Vector3 },
	obstacleRadii: { [number]: number },
	count: number,
	bodyRadius: number
): Vector3
	for index = 1, count do
		local id = obstacleIds[index]
		local center = obstaclePositions[id]
		local minimum = obstacleRadii[id] + bodyRadius

		local dx = position.X - center.X
		local dz = position.Z - center.Z
		local distanceSquared = dx * dx + dz * dz

		if distanceSquared < minimum * minimum then
			if distanceSquared < 1e-6 then
				-- Ровно в центре колонны: выносим в произвольную, но фиксированную сторону.
				position = Vector3.new(center.X + minimum, 0, center.Z)
			else
				local scale = minimum / math.sqrt(distanceSquared)
				position = Vector3.new(center.X + dx * scale, 0, center.Z + dz * scale)
			end
		end
	end

	return position
end

--[[
	Покачивание вместо скелетной анимации (раздел 2.1 ТЗ).
	phase разводит врагов по фазе, чтобы толпа не пульсировала синхронно.
]]
function EnemyMotion.BobOffset(phase: number, time: number, speed: number, amplitude: number): number
	return math.sin(time * speed + phase) * amplitude
end

-- Удержание врага внутри квадратной арены со стороной size (центр в нуле).
function EnemyMotion.ClampToArena(position: Vector3, size: number): Vector3
	local limit = size * 0.5 - 2
	local x = math.clamp(position.X, -limit, limit)
	local z = math.clamp(position.Z, -limit, limit)
	if x == position.X and z == position.Z then
		return position
	end
	return Vector3.new(x, 0, z)
end

return EnemyMotion
