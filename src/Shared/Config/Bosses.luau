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

	Публичный API:
		Bosses.List / Bosses.ByKey
		Bosses.PhaseFor(def, healthFraction) -> BossPhase
]]

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

		Не давит телом, а управляет боем: постоянно зовёт мечников, лечит
		скопления своих и засеивает арену ядовитыми лужами. Драться с ним
		в толпе собственных призванных — и есть его механика: убивать их
		бесполезно, пока стоит лечащее поле, а отойти мешают лужи.
	]]
	{
		key = "GoblinShaman",
		typeId = 0,
		displayName = "Goblin Shaman",
		element = "Dark",
		radius = 7,
		contactDamage = 18,
		model = { size = Vector3.new(13, 15, 13), shape = "Block", neon = true },
		phases = {
			{
				healthAbove = 0.6,
				moveSpeed = 11,
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
					},
					{ kind = "Shockwave", telegraph = 1, cooldown = 8, damage = 22, radius = 26, speed = 44 },
				},
			},
			{
				healthAbove = 0,
				moveSpeed = 13,
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
							Лечение появляется только во второй фазе: в первой
							игрок учится, что призванных надо убивать, во второй —
							что сначала надо выйти из-под лечения.
						]]
						kind = "HealField",
						telegraph = 0.9,
						cooldown = 11,
						damage = 0,
						radius = 20,
						duration = 8,
						tickInterval = 1,
						heal = 14,
					},
					{
						kind = "PoisonField",
						telegraph = 0.8,
						cooldown = 7,
						damage = 12,
						radius = 18,
						duration = 14,
						tickInterval = 1,
					},
					{ kind = "Shockwave", telegraph = 0.9, cooldown = 6.5, damage = 26, radius = 30, speed = 50 },
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
			elseif attack.kind == "HealField" or attack.kind == "PoisonField" then
				assert(
					attack.duration ~= nil and attack.duration > 0,
					`[Bosses] "{def.key}", фаза {phaseIndex}: {attack.kind} без длительности`
				)
				assert(
					attack.tickInterval ~= nil and attack.tickInterval > 0,
					`[Bosses] "{def.key}", фаза {phaseIndex}: {attack.kind} без интервала тика`
				)
				if attack.kind == "HealField" then
					assert(
						attack.heal ~= nil and attack.heal > 0,
						`[Bosses] "{def.key}", фаза {phaseIndex}: лечащее поле никого не лечит`
					)
				else
					assert(
						attack.damage > 0,
						`[Bosses] "{def.key}", фаза {phaseIndex}: ядовитое поле не наносит урона`
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
