--!strict
--[[
	Waves — расписание спавна по времени боя (раздел 3.5 ТЗ).

	Строки должны идти по возрастанию time. Действует последняя строка,
	у которой time <= прошедшего времени забега.

	spawnRate — врагов в секунду, maxAlive — жёсткий потолок живых.
	При достижении потолка дальние враги удаляются молча.

	Числа M1 подобраны так, чтобы к 90-й секунде на арене гарантированно
	было 300 врагов — это нужно для проверки критерия приёмки по FPS.
]]

local Types = require(script.Parent.Parent.Types)

type WaveEntry = Types.WaveEntry

local Waves: { WaveEntry } = {
	{ time = 0, spawnRate = 6, types = { "Slime" }, maxAlive = 80 },
	{ time = 20, spawnRate = 14, types = { "Slime", "Bat" }, maxAlive = 160 },
	{ time = 45, spawnRate = 24, types = { "Slime", "Bat" }, maxAlive = 240 },
	{ time = 75, spawnRate = 32, types = { "Slime", "Bat", "Ember" }, maxAlive = 300 },
	{ time = 150, spawnRate = 36, types = { "Slime", "Bat", "Ember" }, maxAlive = 300 },
}

for index, entry in Waves do
	if index > 1 then
		assert(
			entry.time > Waves[index - 1].time,
			"[Waves] Строки должны идти по возрастанию time"
		)
	end
	table.freeze(entry.types)
	table.freeze(entry)
end

return table.freeze(Waves)
