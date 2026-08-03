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

	-- Интерфейс
	UI = table.freeze({
		background = Color3.fromHex("#122019"),
		panel = Color3.fromHex("#1B2C24"),
		text = Color3.fromHex("#F2F7F4"),
		subtext = Color3.fromHex("#8FD3AC"),
		accent = Color3.fromHex("#4FA97C"),
		danger = Color3.fromHex("#E2603A"),
	}),
}

return table.freeze(Palette)
