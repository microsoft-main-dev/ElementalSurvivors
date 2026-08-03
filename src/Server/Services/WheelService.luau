--!strict
--[[
	WheelService — колесо фортуны (раздел 4 ТЗ), M6.

	Раз в 24 часа бесплатно. Дополнительные прокрутки за донатную валюту —
	это M7: Prisms до тех пор не заработать, и продавать за них нечего.

	Сутки считаются по серверному os.time() и по отметке в профиле. Клиент
	не сообщает ни своего времени, ни того, крутил ли он сегодня: единственное,
	что от него приходит, — «хочу крутить».

	Все призы — Essence. Выдавать колесом предметы или Prisms значило бы дать
	бесплатный источник того, что должно добываться игрой.

	Публичный API:
		WheelService.Spin(player)        -> (boolean, string?)
		WheelService.NextSpinIn(player)  -> number
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Balance = require(Shared.Config.Balance)
local DataService = require(script.Parent.DataService)
local Net = require(Shared.Net)
local Types = require(Shared.Types)

local WheelService = {}

local resultRemote: RemoteEvent? = nil
local random = Random.new()

-- Сколько секунд осталось до бесплатной прокрутки. Ноль означает «можно сейчас».
function WheelService.NextSpinIn(player: Player): number
	local data = DataService.GetProfile(player)
	if not data then
		return Balance.Daily.wheelPeriod
	end

	local elapsed = os.time() - data.daily.lastWheelSpin
	--[[
		Отрицательное значение означает отметку из будущего — часы разошлись
		или профиль пришёл с машины с другим временем. Трактуем как «нельзя»
		и ждём полный период: «щедрая» обработка такой ошибки здесь означала бы
		бесплатные прокрутки без ограничения.
	]]
	if elapsed < 0 then
		return Balance.Daily.wheelPeriod
	end

	return math.max(Balance.Daily.wheelPeriod - elapsed, 0)
end

function WheelService.Spin(player: Player): (boolean, string?)
	local data = DataService.GetProfile(player)
	if not data then
		return false, nil
	end

	if WheelService.NextSpinIn(player) > 0 then
		return false, "The wheel is not ready yet."
	end

	local prizes = Balance.Daily.wheelPrizes

	local total = 0
	for _, prize in prizes do
		total += prize.weight
	end

	local roll = random:NextNumber(0, total)
	local accumulated = 0
	local chosenIndex = #prizes

	for index, prize in prizes do
		accumulated += prize.weight
		if roll <= accumulated then
			chosenIndex = index
			break
		end
	end

	local prize = prizes[chosenIndex]

	--[[
		Отметка времени сдвигается внутри той же операции, что и выдача,
		и до неё — как у экспедиций и квестов. Любой путь, где приз выдан,
		а отметка осталась старой, превращается в бесконечное колесо.
	]]
	if not DataService.ClaimWheel(player, prize.essence) then
		return false, nil
	end

	DataService.SaveNow(player)

	--[[
		Панель показывает и список призов, и кулдаун, поэтому после прокрутки
		её надо обновить целиком. Требуется лениво: QuestService сам зовёт
		WheelService ради времени до прокрутки, и ссылка на верхнем уровне
		повесила бы загрузку сервисов.
	]]
	local QuestService = require(script.Parent.QuestService)
	QuestService.PushView(player)

	local remote = resultRemote
	if remote then
		local result: Types.WheelResult = {
			prizeIndex = chosenIndex,
			displayName = prize.displayName,
			essence = prize.essence,
			nextSpinInSeconds = WheelService.NextSpinIn(player),
		}
		remote:FireClient(player, result)
	end

	return true, `Wheel: {prize.displayName}!`
end

function WheelService.Init(): ()
	resultRemote = Net.GetEvent(Net.Id.WheelResult)
end

return WheelService
