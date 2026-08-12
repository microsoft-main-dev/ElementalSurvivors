--!strict
--[[
	Bosses — архетипы боссов (разделы 3.5 и 5.1 ТЗ), M6.

	Уникальных боссов не рисуем: босса задаёт архетип с набором фаз и атак,
	а разнообразие даёт комбинация «архетип × стихия × номер уровня». Здоровье
	приходит снаружи, из Stages.Get(index) — один и тот же архетип на первом
	и на тридцатом уровне отличается только числами.

	Боссовый паттерн меняется каждые пять уровней (Balance.Stages.bossRotation),
	перебирая список локации по кругу.

	ТЕЛЕГРАФ ОБЯЗАТЕЛЕН У КАЖДОЙ АТАКИ. На автобое игрок не выбирает, когда
	бить, — единственное, чем он управляет, это позиция. Атака, показанная
	одновременно с уроном, не оставляет ему решения вовсе и читается как
	несправедливость. Валидатор внизу файла это требование проверяет.

	МОДЕЛЬ НЕОБЯЗАТЕЛЬНА. modelKey указывает на Config/Models; без него босс
	рисуется одной деталью по model, как раньше. Заглушка обязана пережить
	любой деф, которому модель ещё не нарисовали.

	Публичный API:
		Bosses.List / Bosses.ByKey
		Bosses.PhaseFor(def, healthFraction) -> BossPhase
]]

local Enemies = require(script.Parent.Enemies)
local Models = require(script.Parent.Models)
local Types = require(script.Parent.Parent.Types)

type BossDef = Types.BossDef
type BossPhase = Types.BossPhase

local Bosses = {}

local definitions: { BossDef } = {
	--[[
		Slime King — босс лесной поляны.

		Механики взяты у Bulwark целиком, решением владельца: это первый босс
		в игре, и знакомить с ним игрока надо на понятных движениях — давит
		вширь ударной волной и бросается рывком. Отличается медлительностью
		и размером: это большой слизень, а не другой зверь.
	]]
	{
		key = "SlimeKing",
		typeId = 0,
		displayName = "Slime King",
		element = "Nature",
		radius = 10,
		contactDamage = 20,
		model = { size = Vector3.new(20, 15, 20), shape = "Ball", neon = false },
		modelKey = "SlimeKing",
		phases = {
			{
				healthAbove = 0.5,
				moveSpeed = 6,
				attacks = {
					{ kind = "Shockwave", telegraph = 1.2, cooldown = 6, damage = 24, radius = 32, speed = 40 },
					{ kind = "Charge", telegraph = 1.4, cooldown = 9, damage = 30, radius = 10, speed = 70 },
				},
			},
			{
				healthAbove = 0,
				moveSpeed = 9,
				attacks = {
					{ kind = "Shockwave", telegraph = 1, cooldown = 4.5, damage = 28, radius = 38, speed = 46 },
					{ kind = "Charge", telegraph = 1.1, cooldown = 6.5, damage = 36, radius = 10, speed = 84 },
					--[[
						Ниже половины здоровья король зовёт слизней: призыв
						берёт врагов из набора текущего уровня, то есть на
						поляне это как раз слизни всех введённых видов.
					]]
					{ kind = "Summon", telegraph = 0.9, cooldown = 12, damage = 0, radius = 24, count = 12 },
				},
			},
		},
	},

	--[[
		Bulwark — медленный и тяжёлый. Давит рывками и ударными волнами,
		почти не двигается между атаками. Учит игрока не стоять на месте.
	]]
	{
		key = "Bulwark",
		typeId = 0,
		displayName = "Bulwark",
		element = "Fire",
		radius = 9,
		contactDamage = 22,
		model = { size = Vector3.new(18, 14, 18), shape = "Block", neon = false },
		phases = {
			{
				healthAbove = 0.5,
				moveSpeed = 7,
				attacks = {
					{ kind = "Shockwave", telegraph = 1.1, cooldown = 6, damage = 26, radius = 34, speed = 42 },
					{ kind = "Charge", telegraph = 1.3, cooldown = 9, damage = 34, radius = 9, speed = 78 },
				},
			},
			{
				-- Ниже половины здоровья — быстрее и с призывом: боссфайт
				-- обязан меняться, иначе это просто длинный мешок с HP.
				healthAbove = 0,
				moveSpeed = 10,
				attacks = {
					{ kind = "Shockwave", telegraph = 0.9, cooldown = 4.5, damage = 30, radius = 40, speed = 48 },
					{ kind = "Charge", telegraph = 1, cooldown = 6.5, damage = 40, radius = 9, speed = 92 },
					{ kind = "Summon", telegraph = 0.8, cooldown = 11, damage = 0, radius = 26, count = 14 },
				},
			},
		},
	},

	--[[
		Goblin Shaman — босс дремучего леса.

		Он не дерётся сам ВООБЩЕ: ни волны, ни рывка, только касание для тех,
		кто встал вплотную. Всё, что он делает, — это гонит на игрока орду и
		отнимает у него место.

		Три рычага, и каждый решает свою задачу:

		- Призыв. Основное занятие, постоянный поток мечников.
		- Поле усиления над толпой: попавшие в него неуязвимы и быстры пять
		  секунд. Скорость чуть выше БАЗОВОЙ скорости игрока, поэтому новичок
		  обязан вертеться, а вложившийся в скорость отрывается.
		- Ядовитые лужи — три штуки вокруг игрока за раз, ни одна не под ним.

		И часы: раз в минуту на колонну садится неуязвимый стрелок, который
		живёт до смерти босса. Без него бой с боссом, у которого нет прямых
		атак, можно было бы тянуть бесконечно, просто убегая.

		Скорость самого шамана порезана вдвое решением владельца: догонять
		игрока — не его работа, у него для этого есть орда.
	]]
	{
		key = "GoblinShaman",
		typeId = 0,
		displayName = "Goblin Shaman",
		element = "Dark",
		-- Ужат вместе с моделью (см. Config/Models): пятно сверяется
		-- с радиусом при загрузке, разъехаться им нельзя.
		radius = 5,
		contactDamage = 18,
		model = { size = Vector3.new(13, 15, 13), shape = "Block", neon = true },
		modelKey = "GoblinShaman",
		phases = {
			{
				healthAbove = 0.6,
				moveSpeed = 6,
				attacks = {
					{
						kind = "Summon",
						telegraph = 0.8,
						cooldown = 7,
						damage = 0,
						radius = 22,
						count = 10,
						summonKey = "GoblinSwordsman",
					},
					{
						kind = "PoisonField",
						telegraph = 1,
						cooldown = 9,
						damage = 9,
						radius = 16,
						duration = 12,
						tickInterval = 1,
						areaCount = 3,
					},
					--[[
						Часы боссфайта. Кулдаун ровно минута, и стоит он в ОБЕИХ
						фазах: давление обязано копиться с первой секунды, а не
						с того момента, когда игрок собьёт боссу шесть десятых
						здоровья.
					]]
					{
						kind = "HillArcher",
						telegraph = 1.2,
						cooldown = 60,
						damage = 0,
						radius = 10,
						summonKey = "GoblinArcher",
					},
				},
			},
			{
				healthAbove = 0,
				moveSpeed = 7,
				attacks = {
					{
						kind = "Summon",
						telegraph = 0.7,
						cooldown = 5,
						damage = 0,
						radius = 24,
						count = 14,
						summonKey = "GoblinSwordsman",
					},
					{
						--[[
							Усиление появляется только во второй фазе: в первой игрок
							учится, что призванных надо убивать, во второй — что часть
							из них убить нельзя и от них надо уходить.
						]]
						kind = "BuffField",
						telegraph = 0.9,
						cooldown = 11,
						damage = 0,
						radius = 20,
						duration = 8,
						tickInterval = 1,
						buffSeconds = 5,
					},
					{
						kind = "PoisonField",
						telegraph = 0.8,
						cooldown = 7,
						damage = 12,
						radius = 18,
						duration = 14,
						tickInterval = 1,
						areaCount = 3,
					},
					{
						kind = "HillArcher",
						telegraph = 1.2,
						cooldown = 60,
						damage = 0,
						radius = 10,
						summonKey = "GoblinArcher",
					},
				},
			},
		},
	},

	--[[
		Harrier — быстрый и юркий. Не давит, а не даёт стоять: часто призывает
		и бьёт узкими рывками. Противоположность Bulwark по ощущению
		при том же коде.
	]]
	{
		key = "Harrier",
		typeId = 0,
		displayName = "Harrier",
		element = "Lightning",
		radius = 6.5,
		contactDamage = 16,
		model = { size = Vector3.new(12, 12, 12), shape = "Ball", neon = true },
		phases = {
			{
				healthAbove = 0.6,
				moveSpeed = 15,
				attacks = {
					{ kind = "Charge", telegraph = 0.9, cooldown = 5, damage = 24, radius = 6.5, speed = 110 },
					{ kind = "Summon", telegraph = 0.7, cooldown = 9, damage = 0, radius = 24, count = 10 },
				},
			},
			{
				healthAbove = 0,
				moveSpeed = 19,
				attacks = {
					{ kind = "Charge", telegraph = 0.7, cooldown = 3.5, damage = 28, radius = 6.5, speed = 130 },
					{ kind = "Shockwave", telegraph = 0.8, cooldown = 6, damage = 24, radius = 30, speed = 60 },
					{ kind = "Summon", telegraph = 0.6, cooldown = 8, damage = 0, radius = 24, count = 14 },
				},
			},
		},
	},
}

Bosses.List = definitions
Bosses.ByKey = {} :: { [string]: BossDef }

--[[
	Какая фаза действует при данной доле здоровья.

	Список идёт от полного здоровья к нулю, берётся первая подходящая.
	Последняя фаза обязана иметь healthAbove = 0 — иначе на добивании
	босс остался бы вообще без атак.
]]
function Bosses.PhaseFor(def: BossDef, healthFraction: number): BossPhase
	for _, phase in def.phases do
		if healthFraction > phase.healthAbove then
			return phase
		end
	end
	return def.phases[#def.phases]
end

for index, def in definitions do
	def.typeId = index
	assert(Bosses.ByKey[def.key] == nil, `[Bosses] Дубликат ключа "{def.key}"`)
	Bosses.ByKey[def.key] = def

	--[[
		Пятно модели обязано совпасть с боевым радиусом.

		Это тот же инвариант, что «геометрия телеграфа совпадает с геометрией
		удара», только с другой стороны: игрок уворачивается по картинке, а
		сервер считает касание по radius. Модель шире радиуса — босс бьёт
		сквозь собственное тело; у́же — задевает воздухом.

		Допуск в 15% нужен на неровный силуэт: у слизня край юбки и есть
		граница, а вот у шамана шире всего облетающие руны, и требовать
		от них точного совпадения с радиусом бессмысленно.
	]]
	if def.modelKey then
		local model = Models.ByKey[def.modelKey]
		assert(model ~= nil, `[Bosses] У "{def.key}" неизвестная модель "{def.modelKey}"`)
		assert(
			math.abs(model.footprint - def.radius) <= def.radius * 0.15,
			`[Bosses] У "{def.key}" пятно модели {string.format("%.1f", model.footprint)} `
				.. `не сходится с боевым радиусом {def.radius}`
		)
	end

	assert(#def.phases > 0, `[Bosses] У "{def.key}" нет ни одной фазы`)
	assert(
		def.phases[#def.phases].healthAbove == 0,
		`[Bosses] У "{def.key}" последняя фаза должна иметь healthAbove = 0, иначе на добивании босс останется без атак`
	)

	local previous = math.huge
	for phaseIndex, phase in def.phases do
		assert(
			phase.healthAbove < previous,
			`[Bosses] У "{def.key}" фазы должны идти по убыванию healthAbove (фаза {phaseIndex})`
		)
		previous = phase.healthAbove

		assert(#phase.attacks > 0, `[Bosses] У "{def.key}" фаза {phaseIndex} без атак`)

		for _, attack in phase.attacks do
			assert(
				attack.telegraph > 0,
				`[Bosses] "{def.key}", фаза {phaseIndex}: атака {attack.kind} без телеграфа — `
					.. `на автобое это читается как несправедливость`
			)
			assert(
				attack.cooldown > attack.telegraph,
				`[Bosses] "{def.key}", фаза {phaseIndex}: кулдаун {attack.kind} не больше телеграфа — `
					.. `атака начнётся раньше, чем закончится показ`
			)
			if attack.kind == "Summon" then
				assert(attack.count ~= nil, `[Bosses] "{def.key}", фаза {phaseIndex}: Summon без count`)
			elseif attack.kind == "HillArcher" then
				--[[
					Стрелок босса стреляет тем же, чем обычный гоблин-лучник:
					набор снаряда берётся из его определения по этому ключу.
					Ключ без дальнобойности — это стрелок, который не стреляет.
				]]
				local summoned = if attack.summonKey then Enemies.ByKey[attack.summonKey] else nil
				assert(
					summoned ~= nil and summoned.ranged ~= nil,
					`[Bosses] "{def.key}", фаза {phaseIndex}: HillArcher без дальнобойного summonKey`
				)
			elseif attack.kind == "BuffField" or attack.kind == "PoisonField" then
				assert(
					attack.duration ~= nil and attack.duration > 0,
					`[Bosses] "{def.key}", фаза {phaseIndex}: {attack.kind} без длительности`
				)
				assert(
					attack.tickInterval ~= nil and attack.tickInterval > 0,
					`[Bosses] "{def.key}", фаза {phaseIndex}: {attack.kind} без интервала тика`
				)
				if attack.kind == "BuffField" then
					assert(
						attack.buffSeconds ~= nil and attack.buffSeconds > 0,
						`[Bosses] "{def.key}", фаза {phaseIndex}: поле усиления никого не усиливает`
					)
				else
					assert(
						attack.damage > 0,
						`[Bosses] "{def.key}", фаза {phaseIndex}: ядовитое поле не наносит урона`
					)
					assert(
						(attack.areaCount or 1) >= 1,
						`[Bosses] "{def.key}", фаза {phaseIndex}: areaCount меньше единицы`
					)
				end
			else
				assert(attack.speed ~= nil, `[Bosses] "{def.key}", фаза {phaseIndex}: {attack.kind} без speed`)
			end
			table.freeze(attack)
		end

		table.freeze(phase.attacks)
		table.freeze(phase)
	end

	table.freeze(def.phases)
	table.freeze(def.model)
	table.freeze(def)
end

table.freeze(definitions)
table.freeze(Bosses.ByKey)

return Bosses
