--!strict
--[[
	Palette — все цвета игры в одном месте.

	Стиль плоский low-poly (раздел 2.1 ТЗ): силуэт и цвет — единственные средства
	различения объектов, поэтому палитра должна быть узкой и контрастной.
	Материалы только SmoothPlastic и Neon, текстур нет.

	Фирменные цвета взяты с логотипа 4pots games.
]]

local Palette = {
	-- Бренд
	Brand = table.freeze({
		dark = Color3.fromHex("#175C3D"),
		mid = Color3.fromHex("#4FA97C"),
		light = Color3.fromHex("#8FD3AC"),
		white = Color3.fromHex("#FFFFFF"),
	}),

	-- Стихии. Цвет врага кодирует его стихию (раздел 2.1 ТЗ).
	Element = table.freeze({
		Fire = Color3.fromHex("#E2603A"),
		Ice = Color3.fromHex("#5FC8E8"),
		Lightning = Color3.fromHex("#E8CE4B"),
		Nature = Color3.fromHex("#6FBF52"),
		Dark = Color3.fromHex("#7A5BC4"),
		Light = Color3.fromHex("#F2EFDF"),
	}),

	--[[
		Редкости питомцев (раздел 6 ТЗ). Цвет — единственный способ отличить
		редкость с одного взгляда: иконок у нас нет, а подпись читается медленнее.
		Шкала намеренно идёт от блёклого к яркому, а не «каждой редкости свой
		случайный цвет»: так порядок виден даже тому, кто впервые видит буквы.
	]]
	Rarity = table.freeze({
		B = Color3.fromHex("#8A9A92"),
		A = Color3.fromHex("#5FC8E8"),
		S = Color3.fromHex("#6FBF52"),
		SS = Color3.fromHex("#E8CE4B"),
		SSS = Color3.fromHex("#E2603A"),
	}),

	--[[
		Этапы звёздной лестницы (эволюция питомцев). Порядок тот же, что
		у Pets.StarStage: белые -> фиолетовые -> красные -> бриллиантовая.

		Звёзды рисуются цветом этапа везде, где показан питомец, поэтому
		цвет обязан лежать здесь, а не в панели: панелей с питомцами уже три.
	]]
	Stars = table.freeze({
		Color3.fromHex("#F2F7F4"),
		Color3.fromHex("#A98BE8"),
		Color3.fromHex("#E2603A"),
		Color3.fromHex("#8FE8F0"),
	}),

	--[[
		Снаряжение в инвентаре. Текстур у предметов нет и не будет до тех пор,
		пока владелец не даст ассеты, поэтому предмет — это цветной квадрат,
		и цвет обязан читаться как материал вещи: сталь шлема, кожа нагрудника,
		тёмная кожа сапог, золото амулета. Редкость поверх этого добавляет
		свечение (см. Client/UI/ItemIcon), а не свой цвет: иначе легендарные
		сапоги перестали бы быть сапогами.
	]]
	Gear = table.freeze({
		Helmet = Color3.fromHex("#9FB3C8"),
		Chest = Color3.fromHex("#A5734B"),
		Boots = Color3.fromHex("#6B4A32"),
		Trinket = Color3.fromHex("#E8CE4B"),
	}),

	-- Лобби
	Lobby = table.freeze({
		floor = Color3.fromHex("#20302A"),
		floorAccent = Color3.fromHex("#27392F"),
		border = Color3.fromHex("#175C3D"),
		portal = Color3.fromHex("#4FA97C"),
		portalGlow = Color3.fromHex("#8FD3AC"),
		sign = Color3.fromHex("#1A241F"),
	}),

	--[[
		Арена. В M1 одна палитра; в M6 их станет 20 по числу локаций (раздел 5.1 ТЗ).

		Пол намеренно светлее тумана: туман виден только как контраст,
		а тёмный туман поверх тёмного пола не читается вообще.
	]]
	Arena = table.freeze({
		floor = Color3.fromHex("#2E4349"),
		floorAccent = Color3.fromHex("#3A5359"),
		decor = Color3.fromHex("#3E5A62"),
		decorAccent = Color3.fromHex("#54A08F"),
		fog = Color3.fromHex("#080E10"),
		exit = Color3.fromHex("#E2603A"),
	}),

	--[[
		Палитры локаций. Ключ берётся из LocationDef.palette, и локация
		без своей записи откатывается на Arena выше — новая локация
		не должна ронять бой из-за забытого цвета.

		Обе лесные, но по-разному: поляна светлее и теплее, дремучий лес
		темнее и холоднее, с плотным туманом. Разница должна читаться
		мгновенно, иначе смена локации не ощущается вовсе.
	]]
	Arenas = table.freeze({
		ForestGlade = table.freeze({
			floor = Color3.fromHex("#33502F"),
			floorAccent = Color3.fromHex("#3F6238"),
			decor = Color3.fromHex("#4A6B3C"),
			decorAccent = Color3.fromHex("#8FD3AC"),
			fog = Color3.fromHex("#0E1A10"),
			exit = Color3.fromHex("#E2603A"),
		}),
		DeepForest = table.freeze({
			floor = Color3.fromHex("#1E2E28"),
			floorAccent = Color3.fromHex("#26382F"),
			decor = Color3.fromHex("#2A3D33"),
			decorAccent = Color3.fromHex("#4FA97C"),
			fog = Color3.fromHex("#060B08"),
			exit = Color3.fromHex("#E2603A"),
		}),
	}),

	--[[
		Секторы колеса фортуны, от дешёвого приза к дорогому.

		Список отдельный, а не «цвет по редкости»: у призов колеса редкости нет,
		есть порядок. Каждый цвет обязан быть виден на тёмной панели — первый
		вариант красил дешёвые секторы цветом самой панели, и половина колеса
		просто не рисовалась.
	]]
	Wheel = table.freeze({
		Color3.fromHex("#2F6B4F"),
		Color3.fromHex("#3E8C6A"),
		Color3.fromHex("#4FA97C"),
		Color3.fromHex("#5FC8E8"),
		Color3.fromHex("#E8CE4B"),
		Color3.fromHex("#E2603A"),
	}),

	-- Интерфейс
	UI = table.freeze({
		background = Color3.fromHex("#122019"),
		panel = Color3.fromHex("#1B2C24"),
		-- Пустая ячейка инвентаря: темнее панели, но не чёрная — ряд пустых
		-- ячеек должен читаться как сетка, а не как дырка в окне.
		slot = Color3.fromHex("#0E1813"),
		text = Color3.fromHex("#F2F7F4"),
		subtext = Color3.fromHex("#8FD3AC"),
		accent = Color3.fromHex("#4FA97C"),
		danger = Color3.fromHex("#E2603A"),
		-- Предупреждение без урона: телеграф призыва (там появятся враги,
		-- но сам круг не бьёт). Красный там был бы обманом.
		warning = Color3.fromHex("#E8CE4B"),
	}),
}

return table.freeze(Palette)
