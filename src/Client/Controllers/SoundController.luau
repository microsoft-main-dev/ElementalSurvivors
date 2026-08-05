--!strict
--[[
	SoundController — звук (M7). Asset ID пока на нулях (Config/Sounds), поэтому
	этот контроллер сейчас ничего не слышно не играет — код и точки подключения
	готовы до того, как владелец пришлёт id (правило 4, тот же приём, что у
	Config/Branding и Config/Monetization).

	Большая часть слотов слушает уже существующие Remote напрямую — отдельного
	"звукового" канала заводить не пришлось. Исключения, у которых нет сетевого
	события:
		- ButtonClick  — дёргает UiKit.Button на каждый клик.
		- CardChosen   — дёргает LevelUpController в момент выбора карточки,
		                 раньше, чем уйдёт LevelUpChoice.
		- Purchase     — MarketplaceService.PromptProductPurchaseFinished,
		                 настоящий клиентский сигнал успеха покупки; ждать
		                 подтверждения от ProcessReceipt не нужно, у покупки
		                 и так нет обратного Remote (раздел "Store" в M7).

	Слот Hit ("попадание по врагу") сюда сознательно не подключен: клиент
	не получает событие подтверждённого попадания — CollectHits считает урон
	только на сервере (раздел 3.3 ТЗ, дальний хитбокс). Слот лежит в конфиге,
	но играть ему пока нечего; подключать имитацию по AbilityFx не стал —
	это было бы "попадание" не по факту, а по касанию.

	Смерти врагов и подбор кристаллов приходят пачками по несколько десятков
	за раз — звук здесь один на пачку, а не один на каждого: иначе после
	появления настоящих id первый же нормальный забег превратится в трещотку.
	У смерти врага при этом свой звук на тип (Config/Sounds.EnemyDeathId):
	контроллер держит собственную карту id -> typeId по событиям спавна —
	ту же, что EnemyRenderController строит для себя, отдельно, потому что
	общего кеша разобранных пакетов между контроллерами в проекте нет.
]]

local Debris = game:GetService("Debris")
local MarketplaceService = game:GetService("MarketplaceService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local SoundService = game:GetService("SoundService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Enemies = require(Shared.Config.Enemies)
local Net = require(Shared.Net)
local Packet = require(Shared.Util.Packet)
local Sounds = require(Shared.Config.Sounds)
local Types = require(Shared.Types)

local SFX_LIFETIME = 10 -- с запасом на самый долгий одноразовый звук

--[[
	Контактный урон бьёт каждый тик, пока враг касается игрока (раздел 3.3 ТЗ) —
	без троттлинга PlayerHit превратился бы в непрерывный треск, а не в звук
	отдельного удара.
]]
local PLAYER_HIT_COOLDOWN = 1

--[[
	Экран итогов забега (M7): раньше музыка боя обрывалась одновременно
	со звуком победы/поражения, и на фоне музыки его было не разобрать.

	RESULT_SOUND_DELAY — пауза после остановки музыки, прежде чем играть итог.
	RESULT_MUSIC_RESUME_DELAY — сколько после этого молчать, прежде чем снова
	включить музыку лобби. Оба — ориентир, а не хронометраж под конкретный
	ассет: поправить одной цифрой, когда станет слышно, сколько реально
	длится звук StageVictory.
]]
local RESULT_SOUND_DELAY = 0.6
local RESULT_MUSIC_RESUME_DELAY = 4

local SoundController = {}

local player = Players.LocalPlayer

local sfxVolume = 1
local musicVolume = 1
local musicLobby: Sound? = nil
local musicCombat: Sound? = nil
local healthConnection: RBXScriptConnection? = nil
local lastHealth = 0
-- os.clock() последнего PlayerHit; -math.huge, чтобы самый первый удар
-- в забеге не ждал кулдауна от предыдущей жизни.
local lastPlayerHitAt = -math.huge

-- id врага (из пакета) -> typeId, только пока враг жив. Нужна лишь затем,
-- чтобы на Despawn узнать, кто именно умер: Despawn несёт причину, а не тип.
local enemyTypeIds: { [number]: number } = {}

--[[
	Увеличивается на каждый RunStarted и RunResult. Отложенный "вернуть музыку
	лобби" после итогов забега (см. RunResult ниже) сверяется с этим числом
	перед тем, как сработать: если игрок успел начать новый забег или пришёл
	новый результат раньше, чем истекла пауза, старое включение лобби-музыки
	не должно перебивать музыку уже идущего боя.
]]
local resultToken = 0

local function playSoundId(id: number, name: string, scale: number): ()
	if sfxVolume <= 0 or not Sounds.IsConfigured(id) then
		return
	end

	local sound = Instance.new("Sound")
	sound.Name = name
	sound.SoundId = `rbxassetid://{id}`
	sound.Volume = sfxVolume * scale
	sound.Parent = SoundService
	sound:Play()
	Debris:AddItem(sound, SFX_LIFETIME)
end

function SoundController.PlaySfx(slot: Types.SoundSlot): ()
	playSoundId(Sounds.Ids[slot], slot, Sounds.VolumeScale[slot] or 1)
end

-- MusicLobby и MusicCombat взаимоисключающие: играть должен ровно один трек.
function SoundController.PlayMusic(slot: Types.SoundSlot): ()
	local lobby = musicLobby
	local combat = musicCombat
	if not lobby or not combat then
		return
	end
	lobby.Playing = slot == "MusicLobby"
	combat.Playing = slot == "MusicCombat"
end

-- Тишина между боем и звуком итога (см. RESULT_SOUND_DELAY).
local function stopMusic(): ()
	local lobby = musicLobby
	if lobby then
		lobby.Playing = false
	end
	local combat = musicCombat
	if combat then
		combat.Playing = false
	end
end

local function makeMusicTrack(slot: Types.SoundSlot): Sound
	local sound = Instance.new("Sound")
	sound.Name = slot
	sound.Looped = true
	sound.Volume = musicVolume * (Sounds.VolumeScale[slot] or 1)
	local id = Sounds.Ids[slot]
	if Sounds.IsConfigured(id) then
		sound.SoundId = `rbxassetid://{id}`
	end
	sound.Parent = SoundService
	return sound
end

local function onProfileView(view: Types.ProfileView): ()
	sfxVolume = view.settings.sfxVolume
	musicVolume = view.settings.musicVolume

	local lobby = musicLobby
	if lobby then
		lobby.Volume = musicVolume * (Sounds.VolumeScale.MusicLobby or 1)
	end
	local combat = musicCombat
	if combat then
		combat.Volume = musicVolume * (Sounds.VolumeScale.MusicCombat or 1)
	end
end

--[[
	Пачка спавнов/смертей. Звук смерти проигрывается не больше одного раза
	за вызов, сколько бы врагов в пачке ни умерло: играет первый убитый —
	с настоящими id это может звучать чуть однобоко при массовой резне,
	но альтернатива (звук на каждого) после появления реальных id превратила
	бы забег в трещотку.

	Карта typeId ведётся по ВСЕМ событиям пачки, а не только до первого
	совпадения: иначе записи для врагов после первого убитого в этой же
	пачке остались бы висеть в enemyTypeIds навсегда (id переиспользуются
	почти сразу, но не мгновенно).
]]
local function onEnemyEvents(data: buffer): ()
	local played = false

	for _, event in Packet.ReadEvents(data) do
		if event.kind == Packet.Kind.Spawn then
			enemyTypeIds[event.id] = event.aux
			continue
		end

		local typeId = enemyTypeIds[event.id]
		enemyTypeIds[event.id] = nil

		if not played and event.aux == Packet.Reason.Killed and typeId then
			local def = Enemies.List[typeId]
			if def then
				played = true
				playSoundId(Sounds.EnemyDeathId(def.key), "EnemyDeath", Sounds.VolumeScale.EnemyDeath or 1)
			end
		end
	end
end

local function onCrystalEvents(data: buffer): ()
	for _, event in Packet.ReadEvents(data) do
		if event.kind == Packet.Kind.Despawn then
			SoundController.PlaySfx("CrystalPickup")
			return
		end
	end
end

local function onBossEvent(payload: { [string]: any }): ()
	if payload.kind == "Spawn" then
		SoundController.PlaySfx("BossSpawn")
	elseif payload.kind == "Despawn" then
		SoundController.PlaySfx("BossDeath")
	end
end

-- PlayerDeath здесь не висит: он играет в итогах забега (RunResult), не в
-- момент смерти — см. комментарий там.
local function bindHealth(character: Model): ()
	local existing = healthConnection
	if existing then
		existing:Disconnect()
	end

	local humanoid = character:WaitForChild("Humanoid", 5) :: Humanoid?
	if not humanoid then
		return
	end

	lastHealth = humanoid.Health
	healthConnection = humanoid.HealthChanged:Connect(function(health: number)
		if health < lastHealth then
			local now = os.clock()
			if now - lastPlayerHitAt >= PLAYER_HIT_COOLDOWN then
				lastPlayerHitAt = now
				SoundController.PlaySfx("PlayerHit")
			end
		end
		lastHealth = health
	end)
end

function SoundController.Start(): ()
	musicLobby = makeMusicTrack("MusicLobby")
	musicCombat = makeMusicTrack("MusicCombat")
	SoundController.PlayMusic("MusicLobby")

	Net.GetEvent(Net.Id.ProfileView).OnClientEvent:Connect(onProfileView)

	Net.GetEvent(Net.Id.RunStarted).OnClientEvent:Connect(function()
		resultToken += 1 -- обрывает отложенное возвращение музыки лобби с прошлого забега
		SoundController.PlayMusic("MusicCombat")
		table.clear(enemyTypeIds)
	end)
	Net.GetEvent(Net.Id.RunEnded).OnClientEvent:Connect(function()
		stopMusic()
		table.clear(enemyTypeIds)
	end)

	Net.GetEvent(Net.Id.EnemyEvents).OnClientEvent:Connect(onEnemyEvents)
	Net.GetEvent(Net.Id.CrystalEvents).OnClientEvent:Connect(onCrystalEvents)
	Net.GetEvent(Net.Id.BossEvent).OnClientEvent:Connect(onBossEvent)
	Net.GetEvent(Net.Id.LevelUpOffer).OnClientEvent:Connect(function()
		SoundController.PlaySfx("LevelUp")
	end)
	Net.GetEvent(Net.Id.EggResult).OnClientEvent:Connect(function()
		SoundController.PlaySfx("EggOpen")
	end)
	Net.GetEvent(Net.Id.WheelResult).OnClientEvent:Connect(function()
		SoundController.PlaySfx("WheelSpin")
	end)
	--[[
		Итоги забега (M7). Музыка уже остановлена в RunEnded — здесь только
		пауза, звук итога и возврат музыки лобби. PlayerDeath — исход "не
		победа" целиком (смерть или досрочный выход), а не только момент
		смерти: раньше он играл сразу на Humanoid.Died, под музыку боя, и там
		был неслышен ровно по той же причине, что и StageVictory.
	]]
	Net.GetEvent(Net.Id.RunResult).OnClientEvent:Connect(function(result: Types.RunResult)
		resultToken += 1
		local myToken = resultToken

		task.spawn(function()
			task.wait(RESULT_SOUND_DELAY)
			SoundController.PlaySfx(if result.victory then "StageVictory" else "PlayerDeath")

			task.wait(RESULT_MUSIC_RESUME_DELAY)
			if resultToken == myToken then
				SoundController.PlayMusic("MusicLobby")
			end
		end)
	end)

	player.CharacterAdded:Connect(bindHealth)
	if player.Character then
		bindHealth(player.Character)
	end

	MarketplaceService.PromptProductPurchaseFinished:Connect(
		function(userId: number, _productId: number, wasPurchased: boolean)
			if wasPurchased and userId == player.UserId then
				SoundController.PlaySfx("Purchase")
			end
		end
	)
end

return SoundController
