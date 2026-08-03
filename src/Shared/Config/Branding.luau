--!strict
--[[
	Branding — данные студии 4pots games (раздел 2.2 ТЗ).

	Логотипы загружены владельцем в Roblox; исходники PNG лежат в репозитории
	в assets/branding, там же описано, почему под изображением рисуется
	светлая плашка.

	Ноль в любом из полей означает «ассета нет» — тогда вместо картинки
	рисуется текстовая заглушка. Так было до загрузки и так останется,
	если ассет когда-нибудь снимет модерация.
]]

local Branding = {
	studioName = "4pots",
	studioSuffix = "games",
	gameName = "Elemental Survivors",

	-- Квадратная эмблема 512x512: экран загрузки (BootController).
	logoSquareAssetId = 120118234650392,

	-- Горизонтальный логотип 1024x256: табличка у портала (LobbyService).
	logoWideAssetId = 138471269542635,
}

return table.freeze(Branding)
