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

	-- Лобби
	Lobby = table.freeze({
		floor = Color3.fromHex("#20302A"),
		floorAccent = Color3.fromHex("#27392F"),
		border = Color3.fromHex("#175C3D"),
		portal = Color3.fromHex("#4FA97C"),
		portalGlow = Color3.fromHex("#8FD3AC"),
		sign = Color3.fromHex("#1A241F"),
	}),

	-- Арена. В M1 одна палитра; в M6 их станет 20 по числу локаций (раздел 5.1 ТЗ).
	Arena = table.freeze({
		floor = Color3.fromHex("#1C2A2E"),
		floorAccent = Color3.fromHex("#243539"),
		decor = Color3.fromHex("#2C4046"),
		decorAccent = Color3.fromHex("#38565E"),
		fog = Color3.fromHex("#0D1719"),
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
