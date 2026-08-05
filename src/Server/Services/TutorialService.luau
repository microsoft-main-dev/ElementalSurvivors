--!strict
--[[
	TutorialService — обязательное обучение новичка (M7, раздел 4 ТЗ).

	Раздел 4 требует, чтобы новый игрок не гулял по лобби свободно: его ведут
	по объектам, уводят в короткий бой и объясняют механики. Пропуска нет,
	повтора нет.

	Здесь живёт ровно то, чем обязан владеть сервер:

		- два флага в профиле;
		- право играть тот или иной режим до конца обучения;
		- одноразовая награда за обучающий уровень.

	Подсказки сервер не ведёт — всё, что для них нужно, у клиента уже есть,
	и гонять это на сервер значило бы завести сетевой поток ради текста
	на экране.

	ДВА ФЛАГА, А НЕ ОДИН ШАГ С НОМЕРОМ

		flags.tutorialCleared — обучающий уровень ВЫИГРАН;
		flags.tutorial        — обучение закончено целиком.

	Первый ставится по победе, а не по входу в бой. Проигравший новичок
	останется без 14 000 Essence, на которые обучение тут же обязывает купить
	яйцо, — то есть застрянет на шаге, который ему нечем пройти. Пока уровень
	не выигран, он единственный доступный; после победы — единственный
	недоступный, потому что награда за него одноразовая.

	Промежуточные шаги в профиле не хранятся: за них ничего не начисляется,
	а прерванная половина обучения начинается заново с начала. Это дешевле,
	чем номер шага, который придётся поддерживать при каждой правке сценария.

	Публичный API:
		TutorialService.PushView(player)
		TutorialService.AllowsPlay(player)        -> boolean
		TutorialService.CanPlayTutorial(player)   -> boolean
		TutorialService.AwardRun(player, victory) -> (number, number, { ItemInstance })
		TutorialService.Complete(player)
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Balance = require(Shared.Config.Balance)
local DataService = require(script.Parent.DataService)
local ItemService = require(script.Parent.ItemService)
local Net = require(Shared.Net)
local Tutorial = require(Shared.Config.Tutorial)
local Types = require(Shared.Types)

-- Имена флагов в профиле. Строка живёт в одном месте по той же причине,
-- по которой имена Remote лежат в Net.Id.
local FLAG_CLEARED = "tutorialCleared"
local FLAG_DONE = "tutorial"

--[[
	Номер уровня, по которому роллится предмет за обучающего босса. Предмет
	должен быть слабым (он объясняет слот, а не одевает игрока), поэтому
	берётся первый уровень, а не нулевой: у Items.Roll ноль означал бы
	характеристики ниже любого настоящего дропа.
]]
local ITEM_STAGE_INDEX = 1

local TutorialService = {}

local viewRemote: RemoteEvent? = nil

function TutorialService.PushView(player: Player): ()
	local remote = viewRemote
	local data = DataService.GetProfile(player)
	if not remote or not data then
		return
	end

	local view: Types.TutorialView = {
		needsRun = not data.flags[FLAG_CLEARED],
		needsLobbyTour = not data.flags[FLAG_DONE],
	}
	remote:FireClient(player, view)
end

--[[
	Можно ли играть обычные режимы. Профиль ещё не загружен — не наше дело:
	вход в бой без профиля отказывает сам и с понятным сообщением, а «сначала
	пройди обучение» в этот момент было бы просто неправдой.
]]
function TutorialService.AllowsPlay(player: Player): boolean
	local data = DataService.GetProfile(player)
	if not data then
		return true
	end
	return data.flags[FLAG_CLEARED] == true
end

function TutorialService.CanPlayTutorial(player: Player): boolean
	local data = DataService.GetProfile(player)
	if not data then
		return false
	end
	return not data.flags[FLAG_CLEARED]
end

--[[
	Награда за обучающий уровень. Возвращает (Essence, опыт, предметы).

	Выдаётся только за победу и только один раз: после неё режим больше
	не пускают, поэтому второго вызова с victory просто не бывает. Поражение
	не платит НИЧЕГО — утешительные 10%, как у сюжетного уровня, здесь были бы
	1 400 Essence за две минуты, повторяемые бесконечно.

	Опыт — ровно остаток до следующего уровня персонажа: за обучение
	выдаётся ровно один уровень, то есть ровно одно очко таланта, которое
	туториал тут же и заставляет потратить.

	Yield-иться нельзя: вызывается из RewardService, а тот — в том числе
	из release-хука DataService.
]]
function TutorialService.AwardRun(player: Player, victory: boolean): (number, number, { Types.ItemInstance })
	local data = DataService.GetProfile(player)
	if not data or not victory then
		return 0, 0, {}
	end

	-- Второй раз флаг не ставится, но и не мешает: SetFlag идемпотентен.
	DataService.SetFlag(player, FLAG_CLEARED, true)

	--[[
		Остаток до следующего уровня. На потолке уровней опыт не начисляется
		вовсе: он всё равно обнулился бы в AddMetaXp, а очка таланта за него
		уже не дадут.
	]]
	local xp = 0
	if data.level < Balance.Meta.maxLevel then
		xp = math.max(Balance.MetaXpForLevel(data.level) - data.xp, 1)
	end

	local items: { Types.ItemInstance } = {}
	local item = ItemService.GrantOne(player, ITEM_STAGE_INDEX, Tutorial.RewardItemRarity)
	if item then
		table.insert(items, item)
	end

	return Tutorial.RewardEssence, xp, items
end

--[[
	Обучение пройдено целиком. Ничего, кроме флага, здесь не происходит:
	за вторую половину не начисляется ничего, поэтому и проверять клиенту
	нечего — соврав, он получит только пропущенные объяснения.
]]
function TutorialService.Complete(player: Player): ()
	DataService.SetFlag(player, FLAG_DONE, true)
end

--[[
	Сброс обучения (Balance.Debug.resetTutorial).

	Проверка на Studio стоит здесь, а не в конфиге, тем же приёмом, что
	у WheelService.DebugResetIfNeeded: значение можно забыть включённым,
	и единственная защита — та, мимо которой нельзя пройти.
]]
local function debugResetIfNeeded(player: Player): ()
	if not RunService:IsStudio() or not Balance.Debug.resetTutorial then
		return
	end
	DataService.SetFlag(player, FLAG_CLEARED, false)
	DataService.SetFlag(player, FLAG_DONE, false)
end

local function onPlayerAdded(player: Player): ()
	if not DataService.WaitForProfile(player) then
		return
	end

	debugResetIfNeeded(player)
	TutorialService.PushView(player)
end

function TutorialService.Init(): ()
	viewRemote = Net.GetEvent(Net.Id.TutorialView)
end

function TutorialService.Start(): ()
	for _, player in Players:GetPlayers() do
		task.spawn(onPlayerAdded, player)
	end
	Players.PlayerAdded:Connect(function(player: Player)
		task.spawn(onPlayerAdded, player)
	end)
end

return TutorialService
