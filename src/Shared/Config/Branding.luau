--!strict
--[[
	Branding — данные студии 4pots games (раздел 2.2 ТЗ).

	Asset ID логотипов пока равны нулю: пока там ноль, вместо картинки рисуется
	текстовая заглушка. Никаких выдуманных ID в коде нет и быть не должно —
	после загрузки логотипов в Roblox сюда вписываются реальные числа,
	и это единственная правка, которая для этого нужна.
]]

local Branding = {
	studioName = "4pots",
	studioSuffix = "games",
	gameName = "Elemental Survivors",

	-- Квадратная иконка (вариант «выворотка»): экран загрузки.
	logoSquareAssetId = 0,

	-- Горизонтальный логотип: табличка у портала.
	logoWideAssetId = 0,
}

return table.freeze(Branding)
