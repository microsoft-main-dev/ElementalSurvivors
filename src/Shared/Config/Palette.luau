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

	-- Лобби
	Lobby = table.freeze({
		floor = Color3.fromHex("#20302A"),
		floorAccent = Color3.fromHex("#27392F"),
		border = Color3.fromHex("#175C3D"),
		portal = Color3.fromHex("#4FA97C"),
		portalGlow = Color3.fromHex("#8FD3AC"),
		sign = Color3.fromHex("#1A241F"),
	}),

	-- Интерфейс
	UI = table.freeze({
		background = Color3.fromHex("#122019"),
		panel = Color3.fromHex("#1B2C24"),
		text = Color3.fromHex("#F2F7F4"),
		subtext = Color3.fromHex("#8FD3AC"),
		accent = Color3.fromHex("#4FA97C"),
	}),
}

return table.freeze(Palette)
