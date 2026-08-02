--!strict
--[[
	Packet — компактная упаковка сетевых данных боя в buffer (раздел 2 ТЗ).

	Слать 300 позиций таблицами Lua неприемлемо: каждая таблица — это отдельная
	сериализация с накладными расходами. Тут всё лежит плоско в байтах.

	Форматы (little-endian, как в buffer.write*):

	События (надёжный RemoteEvent, пачкой раз в 100 мс):
		u16 spawnCount
		spawnCount x { u16 id, u8 typeId, f32 x, f32 z }
		u16 despawnCount
		despawnCount x { u16 id, u8 reason }

	Ресинхронизация (UnreliableRemoteEvent, каждый тик по кругу):
		u16 count
		count x { u16 id, f32 x, f32 z }

	Причины исчезновения кодируются числами — см. Packet.Reason.
]]

local Packet = {}

Packet.Reason = table.freeze({
	Killed = 0,
	Culled = 1,
})

local SPAWN_SIZE = 2 + 1 + 4 + 4
local DESPAWN_SIZE = 2 + 1
local RESYNC_SIZE = 2 + 4 + 4

--[[
	Пишет пачку событий. Массивы плоские и переиспользуемые — вызывающая сторона
	не должна ничего аллоцировать ради вызова.
]]
function Packet.WriteEvents(
	spawnIds: { number },
	spawnTypeIds: { number },
	spawnPositions: { Vector3 },
	spawnCount: number,
	despawnIds: { number },
	despawnReasons: { number },
	despawnCount: number
): buffer
	local size = 2 + spawnCount * SPAWN_SIZE + 2 + despawnCount * DESPAWN_SIZE
	local data = buffer.create(size)

	buffer.writeu16(data, 0, spawnCount)
	local offset = 2

	for index = 1, spawnCount do
		local position = spawnPositions[index]
		buffer.writeu16(data, offset, spawnIds[index])
		buffer.writeu8(data, offset + 2, spawnTypeIds[index])
		buffer.writef32(data, offset + 3, position.X)
		buffer.writef32(data, offset + 7, position.Z)
		offset += SPAWN_SIZE
	end

	buffer.writeu16(data, offset, despawnCount)
	offset += 2

	for index = 1, despawnCount do
		buffer.writeu16(data, offset, despawnIds[index])
		buffer.writeu8(data, offset + 2, despawnReasons[index])
		offset += DESPAWN_SIZE
	end

	return data
end

export type SpawnRecord = { id: number, typeId: number, position: Vector3 }
export type DespawnRecord = { id: number, reason: number }

function Packet.ReadEvents(data: buffer): ({ SpawnRecord }, { DespawnRecord })
	local spawns: { SpawnRecord } = {}
	local despawns: { DespawnRecord } = {}

	local spawnCount = buffer.readu16(data, 0)
	local offset = 2

	for index = 1, spawnCount do
		spawns[index] = {
			id = buffer.readu16(data, offset),
			typeId = buffer.readu8(data, offset + 2),
			position = Vector3.new(buffer.readf32(data, offset + 3), 0, buffer.readf32(data, offset + 7)),
		}
		offset += SPAWN_SIZE
	end

	local despawnCount = buffer.readu16(data, offset)
	offset += 2

	for index = 1, despawnCount do
		despawns[index] = {
			id = buffer.readu16(data, offset),
			reason = buffer.readu8(data, offset + 2),
		}
		offset += DESPAWN_SIZE
	end

	return spawns, despawns
end

function Packet.WriteResync(ids: { number }, positions: { Vector3 }, count: number): buffer
	local data = buffer.create(2 + count * RESYNC_SIZE)
	buffer.writeu16(data, 0, count)

	local offset = 2
	for index = 1, count do
		local position = positions[ids[index]]
		buffer.writeu16(data, offset, ids[index])
		buffer.writef32(data, offset + 2, position.X)
		buffer.writef32(data, offset + 6, position.Z)
		offset += RESYNC_SIZE
	end

	return data
end

--[[
	Читает ресинк в переданные массивы, чтобы клиент не аллоцировал каждый тик.
	Возвращает количество записей.
]]
function Packet.ReadResync(data: buffer, outIds: { number }, outPositions: { Vector3 }): number
	local count = buffer.readu16(data, 0)
	local offset = 2

	for index = 1, count do
		outIds[index] = buffer.readu16(data, offset)
		outPositions[index] = Vector3.new(buffer.readf32(data, offset + 2), 0, buffer.readf32(data, offset + 6))
		offset += RESYNC_SIZE
	end

	return count
end

return Packet
