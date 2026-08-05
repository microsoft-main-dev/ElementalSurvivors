--!strict
--[[
	Sounds — звуковые Asset ID (M7). Звука в проекте нет ни одного: слоты лежат
	на нулях, пока владелец не пришлёт id из бесплатного Creator Store
	(правило 4 — Asset ID не выдумывать).

	Ноль означает «звука нет» — так же устроен Config/Branding и
	Config/Monetization.productId: SoundController тихо ничего не играет
	для незаведённого слота, а не роняет клиент.

	Смерть врага — исключение из «один слот, один id»: у каждого типа врага
	(Config/Enemies) может быть свой звук. EnemyDeathByKey хранит их по
	строковому ключу врага (тому же, что Enemies.ByKey), без require самого
	Config/Enemies — конфиги в проекте и так ссылаются друг на друга строкой,
	а не жёсткой зависимостью (см. Config/Waves). Враг без своей записи
	(или с нулём) играет общий Ids.EnemyDeath — так новый враг, добавленный
	без звука, не остаётся немым, а получает разумный дефолт.

	VolumeScale — поправка громкости на слот, множитель к общему ползунку
	игрока (sfxVolume/musicVolume из настроек). Разные звуки из разных
	источников редко бывают выровнены по громкости сами по себе, а перекодировать
	чужой ассет нечем — компенсируем в коде, а не переслушиванием при каждом
	плейтесте. 1 — без поправки, это дефолт для всех, у кого владелец
	не просил громче/тише.

	Публичный API:
		Sounds.Ids: { [Types.SoundSlot]: number }
		Sounds.VolumeScale: { [Types.SoundSlot]: number }
		Sounds.EnemyDeathByKey: { [string]: number }
		Sounds.IsConfigured(id: number) -> boolean
		Sounds.EnemyDeathId(enemyKey: string) -> number
]]

local Types = require(script.Parent.Parent.Types)

type SoundSlot = Types.SoundSlot

local Sounds = {}

local ids: { [SoundSlot]: number } = {
	Hit = 0,
	EnemyDeath = 0, -- откат для типа без своей записи в EnemyDeathByKey
	CrystalPickup = 0, -- владелец решил убрать: кристаллы подбираются слишком часто
	LevelUp = 100707963842592,
	CardChosen = 17208361335,
	PlayerHit = 139459336979009,
	PlayerDeath = 120756230063374,
	BossSpawn = 140470545413051,
	BossDeath = 9113216700,
	StageVictory = 5153735602,
	ButtonClick = 88442833509532,
	Purchase = 607662191,
	EggOpen = 3199239299,
	WheelSpin = 5406934065,
	MusicLobby = 9045246197,
	MusicCombat = 9043318222,
}
Sounds.Ids = ids

--[[
	Ключи — Enemies.ByKey. По размеру модели (Config/Enemies): Bat меньше
	Slime меньше Ember (2.2 / 3.2 / 4 стада), поэтому "маленький/средний/
	большой моб" от владельца легли в этом порядке.
]]
local enemyDeathByKey: { [string]: number } = {
	Bat = 140323850218372,
	Slime = 72264591133889,
	Ember = 106879573498735,
}
Sounds.EnemyDeathByKey = enemyDeathByKey

--[[
	Поправки по прослушиванию владельцем: LevelUp и оба музыкальных трека
	звучали громче остальных, BossSpawn — заметно тише. x2 всё ещё было
	не слышно за боем — поднято до x5; если и этого мало, править одну цифру.
]]
local volumeScale: { [SoundSlot]: number } = {
	Hit = 1,
	EnemyDeath = 1,
	CrystalPickup = 1,
	LevelUp = 0.7,
	CardChosen = 1,
	PlayerHit = 1,
	PlayerDeath = 1,
	BossSpawn = 5,
	BossDeath = 1,
	StageVictory = 1,
	ButtonClick = 1,
	Purchase = 1,
	EggOpen = 1,
	WheelSpin = 1,
	MusicLobby = 0.6,
	MusicCombat = 0.6,
}
Sounds.VolumeScale = volumeScale

function Sounds.IsConfigured(id: number): boolean
	return id > 0
end

-- Звук смерти конкретного врага, с откатом на общий Ids.EnemyDeath.
function Sounds.EnemyDeathId(enemyKey: string): number
	local specific = enemyDeathByKey[enemyKey]
	if specific and Sounds.IsConfigured(specific) then
		return specific
	end
	return ids.EnemyDeath
end

table.freeze(Sounds.Ids)
table.freeze(Sounds.EnemyDeathByKey)
table.freeze(Sounds.VolumeScale)

return table.freeze(Sounds)
