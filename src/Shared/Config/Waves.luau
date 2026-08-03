--!strict
--[[
	Waves — расписание спавна по времени боя (раздел 3.5 ТЗ).

	Строки должны идти по возрастанию time. Действует последняя строка,
	у которой time <= прошедшего времени забега.

	spawnRate — врагов в секунду, maxAlive — жёсткий потолок живых.
	При достижении потолка дальние враги удаляются молча.

	КРИВАЯ РАСТЯНУТА НА ВЕСЬ ЗАБЕГ (M6). Прежние числа выводили арену на потолок
	в 300 врагов уже к полутора минутам: они подбирались в M1 под проверку FPS,
	а не под игру. На практике это означало, что толпа была максимальной
	с самого начала, зачищалась даже стартовой способностью и заливала игрока
	опытом — билд собирался за полторы минуты, а дальше забег не менялся.

	Теперь спавн растёт от 2 врагов в секунду до 36 и выходит на потолок
	к 7:15, то есть к последней минуте сюжетного забега (8 минут,
	Balance.Stages.baseDuration). Начало стало спокойным, конец — прежним.

	Бесконечному режиму та же таблица годится без изменений: после последней
	строки действует она, то есть максимальная плотность держится сколько угодно.

	Потолок живых поднимается вместе со скоростью. Это не только про баланс:
	300 врагов на арене — граница, на которой проверялся FPS, и раньше времени
	к ней подходить незачем.
]]

local Types = require(script.Parent.Parent.Types)

type WaveEntry = Types.WaveEntry

local Waves: { WaveEntry } = {
	-- Первые две минуты: разминка. Игрок успевает взять первые улучшения
	-- прежде, чем толпа начнёт что-то из себя представлять.
	{ time = 0, spawnRate = 2, types = { "Slime" }, maxAlive = 30 },
	{ time = 30, spawnRate = 3, types = { "Slime" }, maxAlive = 45 },
	{ time = 60, spawnRate = 4, types = { "Slime", "Bat" }, maxAlive = 60 },
	{ time = 90, spawnRate = 5, types = { "Slime", "Bat" }, maxAlive = 80 },

	-- Со второй минуты плотность растёт равномерно до конца забега.
	{ time = 120, spawnRate = 7, types = { "Slime", "Bat" }, maxAlive = 100 },
	{ time = 165, spawnRate = 9, types = { "Slime", "Bat", "Ember" }, maxAlive = 125 },
	{ time = 210, spawnRate = 12, types = { "Slime", "Bat", "Ember" }, maxAlive = 150 },
	{ time = 255, spawnRate = 15, types = { "Slime", "Bat", "Ember" }, maxAlive = 180 },
	{ time = 300, spawnRate = 19, types = { "Slime", "Bat", "Ember" }, maxAlive = 210 },
	{ time = 345, spawnRate = 23, types = { "Slime", "Bat", "Ember" }, maxAlive = 240 },
	{ time = 390, spawnRate = 28, types = { "Slime", "Bat", "Ember" }, maxAlive = 270 },

	-- Последняя минута сюжетного забега и всё, что дальше в бесконечном.
	{ time = 435, spawnRate = 33, types = { "Slime", "Bat", "Ember" }, maxAlive = 300 },
	{ time = 480, spawnRate = 36, types = { "Slime", "Bat", "Ember" }, maxAlive = 300 },
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
