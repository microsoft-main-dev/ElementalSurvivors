--!strict
--[[
	Packet — компактная упаковка сетевых данных боя в buffer (раздел 2 ТЗ).

	Слать 300 позиций таблицами Lua неприемлемо: каждая таблица — это отдельная
	сериализация с накладными расходами. Тут всё лежит плоско в байтах.

	ВАЖНО про порядок. События идут ОДНИМ потоком в том порядке, в котором
	произошли, а не «сначала все спавны, потом все смерти». Сервер переиспользует
	id умерших врагов почти сразу, поэтому в одной пачке один и тот же id может
	быть сначала освобождён, а потом выдан новому врагу. Если применить их
	не в том порядке, клиент потеряет часть от старого врага (она останется
	висеть на арене) и не покажет нового.

	Форматы (little-endian, как в buffer.write*):

	События (надёжный RemoteEvent, пачкой раз в 100 мс):
		u16 count
		count x { u8 kind, ... }
			kind = Kind.Spawn:   u16 id, u8 typeId, f32 x, f32 z
			kind = Kind.Despawn: u16 id, u8 reason

	Ресинхронизация (UnreliableRemoteEvent, каждый тик по кругу):
		u16 count
		count x { u16 id, f32 x, f32 z, u8 health }

	health — доля здоровья, 0..255. Байт, а не число: полоска над врагом
	не требует точности, а лишние четыре байта на врага в потоке, который идёт
	каждый тик, требуют трафика. Едет в этом же пакете, а не в своём:
	отдельный поток здоровья пришлось бы синхронизировать с этим по порядку,
	а порядок пакетов боя — та вещь, на которой уже обжигались (см. выше).
]]

local Packet = {}

--[[
	Buff занимает ту же короткую раскладку, что и Despawn (вид + id + байт),
	поэтому формат пакета менять не пришлось: длительность усиления влезает
	в поле aux десятыми долями секунды.

	Он обязан идти ТЕМ ЖЕ потоком, что спавны и смерти. Отдельный канал
	разъехался бы с ними по порядку, и усиление доставалось бы врагу,
	который на клиенте ещё не родился или уже умер, — id переиспользуются
	сразу, и это ровно тот баг, на котором тут уже обжигались.
]]
Packet.Kind = table.freeze({
	Spawn = 0,
	Despawn = 1,
	Buff = 2,
})

-- Десятые доли секунды в один байт: до 25.5 с усиления хватает с запасом.
Packet.BuffScale = 10

Packet.Reason = table.freeze({
	Killed = 0,
	Culled = 1,
})

local SPAWN_SIZE = 1 + 2 + 1 + 4 + 4
local DESPAWN_SIZE = 1 + 2 + 1
local RESYNC_SIZE = 2 + 4 + 4 + 1

export type Event = {
	kind: number,
	id: number,
	aux: number, -- typeId для спавна, reason для смерти
	x: number,
	z: number,
}

--[[
	Пишет пачку событий из плоских переиспользуемых массивов: вызывающая сторона
	не должна ничего аллоцировать ради вызова.

	kinds/ids/aux/xs/zs — параллельные массивы, count — сколько записей актуально.
]]
function Packet.WriteEvents(
	kinds: { number },
	ids: { number },
	aux: { number },
	xs: { number },
	zs: { number },
	count: number
): buffer
	local size = 2
	for index = 1, count do
		size += if kinds[index] == Packet.Kind.Spawn then SPAWN_SIZE else DESPAWN_SIZE
	end

	local data = buffer.create(size)
	buffer.writeu16(data, 0, count)
	local offset = 2

	for index = 1, count do
		local kind = kinds[index]
		buffer.writeu8(data, offset, kind)
		buffer.writeu16(data, offset + 1, ids[index])
		buffer.writeu8(data, offset + 3, aux[index])

		if kind == Packet.Kind.Spawn then
			buffer.writef32(data, offset + 4, xs[index])
			buffer.writef32(data, offset + 8, zs[index])
			offset += SPAWN_SIZE
		else
			offset += DESPAWN_SIZE
		end
	end

	return data
end

function Packet.ReadEvents(data: buffer): { Event }
	local events: { Event } = {}

	local count = buffer.readu16(data, 0)
	local offset = 2

	for index = 1, count do
		local kind = buffer.readu8(data, offset)
		local id = buffer.readu16(data, offset + 1)
		local aux = buffer.readu8(data, offset + 3)

		if kind == Packet.Kind.Spawn then
			events[index] = {
				kind = kind,
				id = id,
				aux = aux,
				x = buffer.readf32(data, offset + 4),
				z = buffer.readf32(data, offset + 8),
			}
			offset += SPAWN_SIZE
		else
			events[index] = { kind = kind, id = id, aux = aux, x = 0, z = 0 }
			offset += DESPAWN_SIZE
		end
	end

	return events
end

--[[
	hp и maxHp — плоские массивы сервера по id врага, а не готовые доли:
	считать долю здесь дешевле, чем собирать ради этого третью таблицу
	каждый тик.
]]
function Packet.WriteResync(
	ids: { number },
	positions: { Vector3 },
	hp: { number },
	maxHp: { number },
	count: number
): buffer
	local data = buffer.create(2 + count * RESYNC_SIZE)
	buffer.writeu16(data, 0, count)

	local offset = 2
	for index = 1, count do
		local id = ids[index]
		local position = positions[id]
		buffer.writeu16(data, offset, id)
		buffer.writef32(data, offset + 2, position.X)
		buffer.writef32(data, offset + 6, position.Z)

		local maximum = maxHp[id] or 0
		local fraction = if maximum > 0 then math.clamp(hp[id] / maximum, 0, 1) else 1
		buffer.writeu8(data, offset + 10, math.floor(fraction * 255 + 0.5))

		offset += RESYNC_SIZE
	end

	return data
end

--[[
	Читает ресинк в переданные массивы, чтобы клиент не аллоцировал каждый тик.
	Возвращает количество записей.
]]
function Packet.ReadResync(data: buffer, outIds: { number }, outPositions: { Vector3 }, outHealth: { number }): number
	local count = buffer.readu16(data, 0)
	local offset = 2

	for index = 1, count do
		outIds[index] = buffer.readu16(data, offset)
		outPositions[index] = Vector3.new(buffer.readf32(data, offset + 2), 0, buffer.readf32(data, offset + 6))
		outHealth[index] = buffer.readu8(data, offset + 10) / 255
		offset += RESYNC_SIZE
	end

	return count
end

return Packet
