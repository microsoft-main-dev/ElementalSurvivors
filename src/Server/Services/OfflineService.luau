--!strict
--[[
	OfflineService — экспедиции питомцев, оффлайн-доход (раздел 6.1 ТЗ).

	Пока игрока нет в игре, его питомцы «добывают ресурсы». Доход привязан
	к коллекции, а не к таймеру: это и делает питомцев двойной ценностью —
	сила в бою и пассивный доход.

	Жизненный цикл дохода состоит из двух разных шагов, и путать их нельзя:

		НАЧИСЛЕНИЕ происходит один раз при входе. Промежуток между lastSeen
		и «сейчас» превращается в Essence, кладётся в копилку offline.pending
		и в тот же момент сдвигает lastSeen. Оба действия — одна операция
		DataService.AccrueOffline без yield внутри, поэтому один и тот же
		промежуток не может быть засчитан дважды: после входа его больше нет.

		СБОР — это только выдача копилки игроку. Он ничего не считает и не
		зависит от того, сколько времени прошло.

	Копилка живёт в профиле, а не в памяти сервера: игрок, закрывший окно без
	сбора, ничего не теряет — ни при выходе, ни при вылете сервера. Обрезка
	по потолку выполняется при каждом зачислении, поэтому стопка незабранных
	заходов не обходит ограничение «от 1 до 12 часов».

	Остальные правила раздела 6.1:
		- считает только сервер и только по os.time(); клиент не сообщает,
		  сколько его не было, и вообще ничего не присылает, кроме «забрать»;
		- выдаётся только Essence — ни Prisms, ни предметов, ни опыта, иначе
		  оффлайн начнёт конкурировать с боями, которые и есть игра.

	Публичный API:
		OfflineService.RateForPower(power)      -> number
		OfflineService.CapHoursForPower(power)  -> number
		OfflineService.Accrue(player)           -> number
		OfflineService.Claim(player)            -> number
		OfflineService.PushReport(player)
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Balance = require(Shared.Config.Balance)
local DataService = require(script.Parent.DataService)
local Net = require(Shared.Net)
local PetService = require(script.Parent.PetService)
local Types = require(Shared.Types)

local SECONDS_PER_HOUR = 3600

local OfflineService = {}

local reportRemote: RemoteEvent? = nil

--[[
	Сколько секунд промежутка было зачтено при последнем входе. Нужно только
	для подписи в окне («накоплено за 4 h 20 m») и живёт в памяти: если сервер
	перезапустится, пропадёт подпись, а не деньги.
]]
local lastGap: { [Player]: number } = {}

-- Доход в час при данной суммарной силе коллекции.
function OfflineService.RateForPower(power: number): number
	return Balance.Offline.basePerHour + power * Balance.Offline.essencePerPower
end

--[[
	Потолок накопления. Пороги читаются по порядку, берётся последний,
	который коллекция уже переросла.
]]
function OfflineService.CapHoursForPower(power: number): number
	local hours = Balance.Offline.capTiers[1].hours

	for _, tier in Balance.Offline.capTiers do
		if power >= tier.power then
			hours = tier.hours
		else
			break
		end
	end

	return hours
end

--[[
	Отладка: изобразить, что игрока не было Balance.Debug.offlineTestHours часов,
	чтобы проверять механику, не выжидая эти часы по-настоящему.

	Проверка на Studio стоит здесь, а не в конфиге, намеренно: значение можно
	забыть ненулевым, и единственная защита, которая от этого спасает, — та,
	мимо которой нельзя пройти. Возвращает 0, если рычаг выключен или
	мы не в Studio, и тогда всё считается по реальному времени.
]]
local function forcedElapsed(): number
	if not RunService:IsStudio() then
		return 0
	end

	local hours = Balance.Debug.offlineTestHours
	if hours <= 0 then
		return 0
	end

	return math.floor(hours * SECONDS_PER_HOUR)
end

--[[
	Зачесть промежуток оффлайна в копилку. Возвращает зачтённые секунды —
	ровно то, что было обращено в Essence, уже после обрезки по потолку.

	Вызывается один раз за вход. Повторный вызов ничего не добавит: lastSeen
	к этому моменту уже сдвинут, и промежутка между ним и «сейчас» нет.
]]
function OfflineService.Accrue(player: Player): number
	local data = DataService.GetProfile(player)
	if not data then
		return 0
	end

	local power = PetService.CollectionPower(player)
	local rate = OfflineService.RateForPower(power)
	local capHours = OfflineService.CapHoursForPower(power)
	local lastSeen = data.offline.lastSeen

	local elapsed = forcedElapsed()

	if elapsed <= 0 then
		--[[
			Ноль означает «профиль ещё ни разу не закрывался»: у нового игрока
			отсчитывать не от чего, а начислять «с начала эпохи» — это выдать
			полный потолок ни за что. Отметку при этом всё равно ставим,
			иначе следующий вход попадёт в тот же случай.
		]]
		if lastSeen <= 0 then
			DataService.TouchLastSeen(player)
			return 0
		end

		--[[
			Отрицательная разница означает, что отметка из будущего: часы сервера
			разошлись или профиль пришёл с машины с другим временем. Начислять
			по такой отметке нельзя — это как раз тот случай, когда «щедрая»
			обработка ошибки становится дырой в экономике. Отметку чиним.
		]]
		elapsed = os.time() - lastSeen
		if elapsed <= 0 then
			DataService.TouchLastSeen(player)
			return 0
		end
	end

	local capped = math.min(elapsed, capHours * SECONDS_PER_HOUR)
	local essence = math.floor(rate * capped / SECONDS_PER_HOUR)

	if essence <= 0 then
		-- Промежуток был, но на монету не набралось. Отметку двигаем всё равно:
		-- иначе секунды копились бы вечно и однажды выдали бы «сдачу» за месяц.
		DataService.TouchLastSeen(player)
		return 0
	end

	DataService.AccrueOffline(player, essence, rate * capHours)
	lastGap[player] = capped

	return capped
end

--[[
	Забрать копилку. Ничего не считает: сумма уже лежит в профиле, а показанное
	в окне число ни на что не влияет и в расчёт не принимается.
]]
function OfflineService.Claim(player: Player): number
	local essence = DataService.ClaimOffline(player, "offline:expedition")
	if essence <= 0 then
		return 0
	end

	lastGap[player] = nil

	--[[
		Сейв сразу после выдачи: копилка уже обнулена, и терять именно это
		изменение нельзя — при откате к автосейву деньги оказались бы
		и выданными, и всё ещё лежащими в копилке.
	]]
	DataService.SaveNow(player)

	return essence
end

--[[
	Окно «Питомцы принесли: …». Показывается, только если в копилке что-то есть
	и промежуток был не совсем символическим: «вы заработали 0» на каждом
	перезаходе раздражает сильнее, чем отсутствующая копейка.
]]
function OfflineService.PushReport(player: Player): ()
	local remote = reportRemote
	local data = DataService.GetProfile(player)
	if not remote or not data then
		return
	end

	local pending = math.floor(data.offline.pending)
	local gap = lastGap[player] or 0

	if pending <= 0 or gap < Balance.Offline.minClaimSeconds then
		return
	end

	local power = PetService.CollectionPower(player)

	local report: Types.OfflineReport = {
		seconds = gap,
		essence = pending,
		ratePerHour = OfflineService.RateForPower(power),
		capHours = OfflineService.CapHoursForPower(power),
	}
	remote:FireClient(player, report)
end

--[[
	Отметка lastSeen у всех, кто сейчас онлайн.

	Без этого тика вылет сервера подарил бы игроку доход за время, которое он
	на самом деле провёл в игре: отметка осталась бы от прошлого выхода.
	Копилке тик не вредит — она уже отдельное поле, и её он не трогает.
]]
local function touchLoop(): ()
	while true do
		task.wait(Balance.Offline.lastSeenInterval)
		for _, player in Players:GetPlayers() do
			DataService.TouchLastSeen(player)
		end
	end
end

--[[
	Отладка: начислять порцию дохода, не выходя из игры.

	Нужно, чтобы механику можно было проверить целиком — начисление, потолок
	и сбор, — не выжидая часы. Вызывает ровно те же функции, что и вход
	в игру, поэтому проверяется настоящий путь, а не его имитация.

	Как и forcedElapsed, работает только в Studio.
]]
local function debugTickLoop(): ()
	while true do
		task.wait(Balance.Debug.offlineTickSeconds)
		for _, player in Players:GetPlayers() do
			if OfflineService.Accrue(player) > 0 then
				OfflineService.PushReport(player)
			end
		end
	end
end

function OfflineService.Init(): ()
	reportRemote = Net.GetEvent(Net.Id.OfflineReport)
end

--[[
	Отметку на выходе и на выключении сервера ставит сам DataService: оба пути
	закрытия профиля проходят через него, и второй обработчик PlayerRemoving
	здесь оказался бы гонкой с закрытием сессии.
]]
function OfflineService.Start(): ()
	task.spawn(touchLoop)

	if RunService:IsStudio() and Balance.Debug.offlineTickSeconds > 0 then
		task.spawn(debugTickLoop)
	end

	Players.PlayerRemoving:Connect(function(player: Player)
		lastGap[player] = nil
	end)
end

return OfflineService
