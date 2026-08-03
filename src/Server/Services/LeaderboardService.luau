--!strict
--[[
	LeaderboardService — стенд рекордсменов (раздел 4 ТЗ), M6.

	Топ-10 по времени в бесконечном режиме через OrderedDataStore.

	ЕДИНСТВЕННЫЙ ВЛАДЕЛЕЦ OrderedDataStore в проекте. Профиль пишет только
	DataService, рекорды — только этот сервис. Причина та же, что и у профиля:
	хранилище с квотами и лимитами запросов не должно быть доступно отовсюду,
	иначе однажды в него начнут писать три сервиса, и разбираться, кто исчерпал
	бюджет запросов, будет негде.

	Рекорд отправляется не при каждом забеге, а только когда он действительно
	улучшил личный: проверку делает DataService.RecordRun, сюда приходит уже
	готовое «это рекорд».

	Топ читается раз в 60 с и кешируется. Читать его на каждый запрос клиента
	нельзя: у OrderedDataStore жёсткие лимиты, а стенд смотрят все сразу.

	В Studio без доступа к API сервис молча выключается: ошибки DataStore
	не должны мешать локальной проверке остальной игры.

	Публичный API:
		LeaderboardService.Submit(player, seconds)
		LeaderboardService.GetTop() -> { LeaderboardEntry }
]]

local DataStoreService = game:GetService("DataStoreService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Balance = require(Shared.Config.Balance)
local Net = require(Shared.Net)
local Types = require(Shared.Types)

local STORE_NAME = "EndlessBest"
local TOP_COUNT = 10

local LeaderboardService = {}

local store: OrderedDataStore? = nil
local cached: { Types.LeaderboardEntry } = {}
local viewRemote: RemoteEvent? = nil

--[[
	Имя игрока по UserId. OrderedDataStore хранит только числа, поэтому имена
	приходится доставать отдельно; кеш нужен, чтобы не дёргать веб-API
	на каждое обновление стенда.
]]
local nameCache: { [number]: string } = {}

local function resolveName(userId: number): string
	local cachedName = nameCache[userId]
	if cachedName then
		return cachedName
	end

	local player = Players:GetPlayerByUserId(userId)
	if player then
		nameCache[userId] = player.Name
		return player.Name
	end

	local ok, name = pcall(function()
		return Players:GetNameFromUserIdAsync(userId)
	end)

	local resolved = if ok and typeof(name) == "string" then name else `Player {userId}`
	nameCache[userId] = resolved
	return resolved
end

--[[
	Отправить личный рекорд на стенд.

	Зовётся после КАЖДОГО забега в бесконечном режиме и получает рекорд
	из профиля, а не время последнего забега. Так было не всегда, и это была
	ошибка: отправка только на новом личном рекорде означала, что рекорд,
	поставленный до появления стенда, на стенд не попадал никогда — игроку
	пришлось бы сначала побить самого себя. Теперь стенд догоняет профиль
	за один любой забег.

	Запись через UpdateAsync, а не SetAsync: значение может только расти.
	SetAsync затёр бы рекорд меньшим числом, если два сервера одного игрока
	отправят записи вразнобой или если профиль когда-нибудь откатится.

	Ошибки проглатываются намеренно: недоступный DataStore не должен ломать
	конец забега, за который игроку уже начислена награда.
]]
function LeaderboardService.Submit(player: Player, seconds: number): ()
	local activeStore = store
	if not activeStore or seconds <= 0 then
		return
	end

	local best = math.floor(seconds)

	task.spawn(function()
		local ok, err = pcall(function()
			activeStore:UpdateAsync(tostring(player.UserId), function(previous: number?): number
				return math.max(previous or 0, best)
			end)
		end)

		if ok then
			print(`[LeaderboardService] {player.Name}: рекорд {best} с отправлен на стенд`)
		else
			warn(`[LeaderboardService] Не удалось записать рекорд {player.Name}: {err}`)
		end
	end)
end

function LeaderboardService.GetTop(): { Types.LeaderboardEntry }
	return cached
end

local function refresh(): ()
	local activeStore = store
	if not activeStore then
		return
	end

	local ok, pages = pcall(function()
		return activeStore:GetSortedAsync(false, TOP_COUNT)
	end)

	if not ok or not pages then
		warn(`[LeaderboardService] Не удалось прочитать стенд: {pages}`)
		return
	end

	local entries: { Types.LeaderboardEntry } = {}

	local readOk, readErr = pcall(function()
		for rank, row in (pages :: DataStorePages):GetCurrentPage() do
			local userId = tonumber(row.key)
			if userId then
				table.insert(entries, {
					rank = rank,
					userId = userId,
					name = resolveName(userId),
					seconds = row.value :: number,
				})
			end
		end
	end)

	if not readOk then
		warn(`[LeaderboardService] Ошибка разбора страницы стенда: {readErr}`)
		return
	end

	cached = entries

	local remote = viewRemote
	if remote then
		remote:FireAllClients(entries)
	end
end

local function refreshLoop(): ()
	while true do
		refresh()
		task.wait(Balance.Leaderboard.refreshInterval)
	end
end

function LeaderboardService.Init(): ()
	viewRemote = Net.GetEvent(Net.Id.LeaderboardView)

	--[[
		Доступ к DataStore берётся один раз и через pcall: в Studio без
		включённого доступа к API вызов падает, и тогда сервис просто молчит,
		а не роняет загрузку сервера.
	]]
	local ok, result = pcall(function()
		return DataStoreService:GetOrderedDataStore(STORE_NAME)
	end)

	if ok then
		store = result
	else
		warn(`[LeaderboardService] OrderedDataStore недоступен, стенд выключен: {result}`)
	end
end

function LeaderboardService.Start(): ()
	if not store then
		return
	end

	-- В Studio стенд обновляется тоже: иначе его нечем проверить до публикации.
	if RunService:IsStudio() then
		print(
			"[LeaderboardService] Стенд рекордсменов работает в Studio: данные общие с живой игрой"
		)
	end

	task.spawn(refreshLoop)

	-- Новый игрок должен увидеть стенд сразу, а не через минуту.
	Players.PlayerAdded:Connect(function(player: Player)
		local remote = viewRemote
		if remote and #cached > 0 then
			remote:FireClient(player, cached)
		end
	end)
end

return LeaderboardService
