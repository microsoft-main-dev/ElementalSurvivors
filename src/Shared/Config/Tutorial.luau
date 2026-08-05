--!strict
--[[
	Tutorial — сценарий обучения новичка (M7, раздел 4 ТЗ).

	Здесь только данные: порядок шагов, их тексты, условия закрытия и награда
	за обучающий уровень. Логика (TutorialService на сервере, TutorialController
	на клиенте) их читает и не знает ни одной строки текста.

	Обучение состоит из трёх частей, идущих строго в этом порядке:

		Intro    — лобби до боя: питомец и дорога к порталу;
		RunHints — подсказки в самом бою;
		Outro    — лобби после победы: яйцо, питомец, талант, предмет.

	Между Intro и Outro лежит обучающий уровень, и его победа — единственный
	переключатель между половинами (флаг профиля ставит сервер).

	Награда за уровень выражена, а не задана числом: Essence — это ровно цена
	самого дешёвого яйца за Essence, потому что сразу после боя туториал
	обязывает купить яйцо, и денег обязано хватить ровно. Опыт считает сервер
	как остаток до следующего уровня персонажа — за обучение выдаётся ровно
	один уровень, то есть ровно одно очко таланта, которое тут же и тратится.

	Публичный API:
		Tutorial.RunHints: { Types.TutorialRunHint }
		Tutorial.Intro: { Types.TutorialStep }
		Tutorial.Outro: { Types.TutorialStep }
		Tutorial.RewardEssence: number
		Tutorial.RewardItemRarity: Types.ItemRarity
]]

local Eggs = require(script.Parent.Eggs)
local Types = require(script.Parent.Parent.Types)

local Tutorial = {}

--[[
	Цена самого дешёвого яйца за Essence. Считается по таблице, а не вписана
	числом: правка цены в Config/Eggs не должна оставлять новичка с суммой,
	которой не хватает на обязательную покупку.
]]
local function cheapestEssenceEgg(): number
	local cheapest = math.huge

	for _, egg in Eggs.List do
		if egg.currency == "essence" and egg.price < cheapest then
			cheapest = egg.price
		end
	end

	assert(cheapest < math.huge, "[Tutorial] В Config/Eggs нет ни одного яйца за Essence")
	return cheapest
end

Tutorial.RewardEssence = cheapestEssenceEgg()

--[[
	Редкость предмета за обучающего босса. Самая низкая намеренно: предмет
	здесь нужен, чтобы объяснить слот и кнопку Equip, а не чтобы одеть игрока
	на десять уровней вперёд.
]]
Tutorial.RewardItemRarity = "Common" :: Types.ItemRarity

--[[
	Подсказки боя.

	Первая — про движение: в игре с автобоем это единственное, что игрок должен
	делать руками, и именно этого он не знает. Вторая говорит то, ради чего
	раздел 4 ТЗ вообще требует туториал: стрелять не нужно. Дальше кристаллы,
	карточка и босс — остальные три правила забега.

	holdSeconds у подсказок с условием большие намеренно: это потолок, а не
	длительность. Обычно подсказка уходит за секунду-две, потому что игрок
	сделал то, о чём его попросили.
]]
local runHints: { Types.TutorialRunHint } = {
	{
		id = "Move",
		text = "Move to survive — enemies chase you",
		trigger = "Move",
		waitSeconds = 0,
		holdSeconds = 15,
	},
	{
		id = "AutoAttack",
		text = "You attack automatically. There are no attack buttons",
		trigger = "Timer",
		waitSeconds = 0,
		holdSeconds = 6,
	},
	{
		id = "Crystals",
		text = "Walk over crystals to gain XP",
		trigger = "Crystal",
		waitSeconds = 0,
		holdSeconds = 20,
	},
	{
		id = "LevelUp",
		text = "Level up — pick one card to get stronger",
		trigger = "LevelUp",
		waitSeconds = 0,
		holdSeconds = 25,
	},
	--[[
		Ровно та секунда, на которой расписание волн вводит второй тип врагов
		(Config/Waves, строка time = 60). Число здесь и число там — одно и то же
		событие, поэтому если строку в расписании подвинут, эту надо подвинуть
		следом: подсказка про новых врагов, приходящая до самих врагов, учит
		неправде.
	]]
	{
		id = "Waves",
		text = "Stages get harder as they run: tougher enemies keep joining the fight",
		trigger = "Timer",
		waitSeconds = 60,
		holdSeconds = 8,
	},
	{
		id = "Boss",
		text = "A boss ends every stage. This one is weakened — beat it",
		trigger = "Boss",
		waitSeconds = 0,
		holdSeconds = 8,
	},
}
Tutorial.RunHints = runHints

--[[
	Первая половина: лобби до боя.

	Стартовый питомец выдан входом в лобби (механизм с M4), поэтому туториал
	его не выдаёт, а объясняет. Порядок «сначала кто ты, потом куда идти»:
	уводить в бой раньше, чем игрок понял, откуда взялась его способность,
	значит показать бой, в котором всё происходит само по себе.
]]
local intro: { Types.TutorialStep } = {
	{
		id = "PetIntro",
		text = "You already have a pet. It decides which ability you start a run with. Open Inventory",
		advance = "OpenPanel",
		--[[
			Питомцы, снаряжение и расходники живут разделами одного инвентаря,
			поэтому шаги ждут именно окно: кнопки «Pets» в лобби больше нет,
			а подсветка и фильтр тура работают по имени кнопки.
		]]
		panel = "Inventory",
		arrow = "Pets",
	},
	{
		id = "PetEffects",
		text = "Pets also boost one element, add stats, and earn Essence on expeditions while you are away",
		advance = "Next",
		panel = "",
		arrow = "",
	},
	{
		id = "GoToPortal",
		text = "Time to fight. Head to the portal",
		advance = "OpenPanel",
		panel = "Stage",
		arrow = "Stage",
	},
	{
		id = "StartRun",
		text = "Start the tutorial stage — two minutes, one weakened boss",
		advance = "EnterRun",
		panel = "Stage",
		arrow = "",
	},
}
Tutorial.Intro = intro

--[[
	Вторая половина: лобби после победы.

	Порядок продиктован тем, что игрок только что получил: деньги (яйцо),
	питомца из яйца, очко таланта, предмет. Каждый шаг тратит ровно то, что
	выдал обучающий уровень, — поэтому ни один из обязательных шагов
	не может оказаться невыполнимым.
]]
local outro: { Types.TutorialStep } = {
	{
		id = "EggIntro",
		text = "The stage paid you exactly one egg. Open Eggs",
		advance = "OpenPanel",
		panel = "Eggs",
		arrow = "Eggs",
	},
	{
		id = "BuyEgg",
		text = "Buy the Basic Egg — rarer pets are stronger and start you with better abilities",
		advance = "BuyEgg",
		panel = "Eggs",
		arrow = "",
	},
	{
		id = "PetsAgain",
		text = "Equip your best pet in the Pets tab. Duplicates are not wasted — they evolve the pet you own",
		advance = "OpenPanel",
		panel = "Inventory",
		arrow = "Pets",
	},
	{
		id = "TalentsIntro",
		text = "Winning gave you a character level, and every level is one talent point. Open Talents",
		advance = "OpenPanel",
		panel = "Talents",
		arrow = "Talents",
	},
	{
		id = "SpendTalent",
		text = "Spend your point. Talents are permanent, apply to every run, and can be reset for Essence",
		advance = "SpendTalent",
		panel = "Talents",
		arrow = "",
	},
	{
		id = "GearIntro",
		text = "The boss also dropped gear. Open Inventory and switch to the Gear tab",
		advance = "OpenPanel",
		panel = "Inventory",
		arrow = "Items",
	},
	{
		id = "EquipItem",
		text = "Tap the item, then Equip. Four slots, one item each, bonuses stack with your pet and talents",
		advance = "EquipItem",
		panel = "Inventory",
		arrow = "",
	},
	{
		id = "Done",
		text = "That's everything. Stages, eggs, talents and gear — the rest is yours to grind",
		advance = "Next",
		panel = "",
		arrow = "",
	},
}
Tutorial.Outro = outro

for _, hint in runHints do
	table.freeze(hint)
end
for _, step in intro do
	table.freeze(step)
end
for _, step in outro do
	table.freeze(step)
end

table.freeze(Tutorial.RunHints)
table.freeze(Tutorial.Intro)
table.freeze(Tutorial.Outro)

return table.freeze(Tutorial)
