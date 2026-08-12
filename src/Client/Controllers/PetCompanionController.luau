--!strict
--[[
	PetCompanionController — питомцы, бегущие рядом с игроками (M7).

	Питомец сопровождает своего хозяина и в лобби, и на арене: наземные держатся
	у земли и подпрыгивают, летающие висят выше и покачиваются — это данные
	питомца (PetModel.flies), а не вывод из стихии.

	ПИТОМЦЕВ ВИДЯТ ВСЕ. Смысл коллекции в том числе в том, чтобы ею хвастаться,
	поэтому контроллер рисует питомцев всех игроков сервера, а не только своего.
	Кто у кого экипирован, приходит атрибутом игрока (Net.Attribute.EquippedPet),
	который ставит сервер: атрибут реплицируется сам и доезжает до тех, кто зашёл
	позже, поэтому ни рассылки, ни запроса при входе здесь нет.

	Чужие питомцы подчиняются настройке «эффекты других игроков» (раздел 2.1 ТЗ):
	All — видно всех, Nearby — только рядом, Off — только своего. Своего видно
	всегда: это его косметика, и прятать её от него самого бессмысленно.

	Чисто визуально. На урон, характеристики и стартовую способность питомец
	влияет через лоадаут, собранный на сервере при входе в бой (CombatService),
	и ничего из этого здесь не считается.

	Чем выше редкость, тем заметнее питомец: неон, свет и искры на орбите берутся
	из Balance.Pets.rarityGlow. Всё создаётся в момент смены питомца, а не в бою —
	инвариант «ноль Instance.new в бою» сохраняется.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Balance = require(Shared.Config.Balance)
local Models = require(Shared.Config.Models)
local Net = require(Shared.Net)
local Palette = require(Shared.Config.Palette)
local PartModel = require(Shared.Util.PartModel)
local Pets = require(Shared.Config.Pets)
local SettingsController = require(script.Parent.SettingsController)
local Types = require(Shared.Types)

local SPARKLE_SIZE = 0.45

local PetCompanionController = {}

local localPlayer = Players.LocalPlayer

type Companion = {
	folder: Folder,
	--[[
		Тело питомца — либо собранная модель (Config/Models), либо одна деталь,
		если модели ему ещё не нарисовали. Заглушка обязана жить: питомцев
		двенадцать, и рисуются они по одному.

		Размер нужен обоим путям — по нему считается высота над землёй и радиус
		орбиты искр, — поэтому лежит отдельным полем, а не спрашивается у детали.
	]]
	model: PartModel.Built?,
	body: BasePart?,
	size: Vector3,
	-- Деталь-держатель PointLight. Своя, потому что у модели одной детали,
	-- на которую его повесить, не существует.
	light: BasePart?,
	sparkles: { BasePart },
	petId: string,
	flies: boolean,
	isLocal: boolean,
	drawn: Vector3,
	phase: number,
	sparklePhase: number,
}

local container: Folder? = nil
local companions: { [Player]: Companion } = {}

local function makePart(name: string, parent: Instance): BasePart
	local part = Instance.new("Part")
	part.Name = name
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.Massless = true
	part.CastShadow = false
	part.Parent = parent
	return part
end

local function destroy(player: Player): ()
	local companion = companions[player]
	if not companion then
		return
	end
	companion.folder:Destroy()
	companions[player] = nil
end

--[[
	Собрать питомца игрока.

	Свет и искры чужим питомцам достаются только на высоком качестве: восемь
	источников света в лобби — это заметная цена за чужую косметику, а свой
	питомец светится всегда.
]]
local function build(player: Player, def: Types.PetDef): ()
	local parent = container
	if not parent then
		return
	end

	destroy(player)

	local isLocal = player == localPlayer
	local rich = isLocal or SettingsController.ResolveQuality() == "High"
	local glow = Balance.Pets.rarityGlow[def.rarity]
	local color = Palette.Element[def.element]

	local folder = Instance.new("Folder")
	folder.Name = `Pet_{player.Name}`
	folder.Parent = parent

	--[[
		Модель, если она нарисована. Красится СВОИМ цветом (Palette.Model.bases),
		а не стихией: питомцы нарисованы зверями, и медвежонок рыжий независимо
		от того, каким огнём он бьёт. Стихию по-прежнему видно — свечением
		редкости вокруг него.
	]]
	local built: PartModel.Built? = nil
	local body: BasePart? = nil
	local lightPart: BasePart? = nil
	local size = def.model.size

	--[[
		Воксельная модель достаётся ВСЕМ, решением владельца.

		Упрощённый вариант остаётся описанным в Config/Models (Models.Lite),
		но не подставляется: свой питомец и чужой выглядят одинаково. Цена
		известна и принята — 115 деталей на питомца, до 2300 в полном лобби.
		Если на телефоне это окажется дорого, подстановка возвращается одной
		строкой здесь, а не переписыванием моделей.
	]]
	local modelDef = if def.model.modelKey then Models.ByKey[def.model.modelKey] else nil
	if modelDef then
		-- Цвет ищется по КЛЮЧУ ПИТОМЦА, а не по ключу модели: у упрощённого
		-- варианта имя другое, а зверь тот же.
		local base = Palette.Model.bases[def.key] or color
		built = PartModel.Build(modelDef, PartModel.TintsFor(base, Palette.Model.accent), folder);
		(built :: PartModel.Built).SetVisible(true)
		size = Vector3.new(modelDef.footprint * 2, modelDef.height, modelDef.footprint * 2)
	else
		local part = makePart("Body", folder)
		part.Size = def.model.size
		part.Color = color
		part.Material = if def.model.neon or glow.neon then Enum.Material.Neon else Enum.Material.SmoothPlastic

		if def.model.shape == "Ball" then
			part.Shape = Enum.PartType.Ball
		elseif def.model.shape == "Cylinder" then
			part.Shape = Enum.PartType.Cylinder
		end
		body = part
	end

	--[[
		Свет висит не на теле, а на собственной детали: у модели «тела» как
		одной детали нет вовсе, а свет должен светить из середины зверя.
	]]
	if glow.brightness > 0 and rich then
		local lamp = makePart("Glow", folder)
		lamp.Size = Vector3.one * 0.2
		lamp.Transparency = 1

		local light = Instance.new("PointLight")
		light.Brightness = glow.brightness
		light.Range = glow.range
		light.Color = color
		light.Shadows = false
		light.Parent = lamp
		lightPart = lamp
	end

	local sparkles: { BasePart } = {}
	if rich then
		for index = 1, glow.sparkles do
			local sparkle = makePart(`Sparkle{index}`, folder)
			sparkle.Shape = Enum.PartType.Ball
			sparkle.Size = Vector3.one * SPARKLE_SIZE
			sparkle.Color = color
			sparkle.Material = Enum.Material.Neon
			table.insert(sparkles, sparkle)
		end
	end

	companions[player] = {
		folder = folder,
		model = built,
		body = body,
		size = size,
		light = lightPart,
		sparkles = sparkles,
		petId = def.key,
		flies = def.model.flies,
		isLocal = isLocal,
		drawn = Vector3.zero,
		phase = 0,
		sparklePhase = 0,
	}
end

--[[
	Питомец игрока изменился (или игрок только что появился).

	Значение атрибута — строка с сервера, но проверяется как чужое: рисуется
	только то, что нашлось в Config/Pets. Неизвестный ключ означает «питомца
	нет», а не ошибку.
]]
local function refresh(player: Player): ()
	local value = player:GetAttribute(Net.Attribute.EquippedPet)
	local petId = if typeof(value) == "string" then value :: string else ""

	local existing = companions[player]
	if existing and existing.petId == petId then
		return
	end

	local def = if petId ~= "" then Pets.ByKey[petId] else nil
	if not def then
		destroy(player)
		return
	end

	build(player, def)
end

local function getRoot(player: Player): BasePart?
	local character = player.Character
	if not character then
		return nil
	end
	return character:FindFirstChild("HumanoidRootPart") :: BasePart?
end

--[[
	Уровень пола под игроком.

	Центр HumanoidRootPart висит примерно в двух стадах над землёй (HipHeight),
	и наземный питомец, поставленный от него, бежал бы по воздуху. Высота бедра
	берётся у Humanoid, а не константой: у R6 и R15 она разная.
]]
local function groundLevel(root: BasePart): number
	local character = root.Parent
	local humanoid = if character then character:FindFirstChildOfClass("Humanoid") else nil
	local hip = if humanoid then humanoid.HipHeight else 0
	return root.Position.Y - root.Size.Y * 0.5 - hip
end

-- Видно ли чужого питомца при текущей настройке эффектов.
local function isVisible(companion: Companion, root: BasePart): boolean
	if companion.isLocal then
		return true
	end

	local mode = SettingsController.Get().othersEffects
	if mode == "Off" then
		return false
	end
	if mode == "All" then
		return true
	end

	local myRoot = getRoot(localPlayer)
	if not myRoot then
		return false
	end

	local distance = Balance.Pets.companion.nearbyDistance
	return (root.Position - myRoot.Position).Magnitude <= distance
end

local function step(companion: Companion, deltaTime: number, root: BasePart): ()
	local part = companion.body
	local numbers = Balance.Pets.companion

	--[[
		Своя точка питомца: сбоку и чуть позади хозяина, в его системе координат.
		Считается от CFrame, а не от позиции, чтобы питомец не перебегал
		с одной стороны на другую при развороте.
	]]
	local height = if companion.flies then numbers.flyHeight else companion.size.Y * 0.5 + numbers.groundClearance
	local target = root.CFrame * Vector3.new(numbers.sideOffset, 0, numbers.backOffset)
	target = Vector3.new(target.X, groundLevel(root) + height, target.Z)

	--[[
		Разрыв больше teleportDistance — это не отставание, а телепорт хозяина
		(вход в бой, возврат в лобби, респавн). Догонять его через всю карту
		питомец не должен.
	]]
	if (companion.drawn - target).Magnitude > numbers.teleportDistance then
		companion.drawn = target
	else
		companion.drawn = companion.drawn:Lerp(target, math.min(deltaTime * numbers.smoothing, 1))
	end

	-- Летающие покачиваются, наземные подпрыгивают: разная частота и амплитуда
	-- на одной и той же синусоиде.
	local speed = if companion.flies then numbers.bobSpeed else numbers.hopSpeed
	local amplitude = if companion.flies then numbers.bobAmplitude else numbers.hopAmplitude
	companion.phase = (companion.phase + deltaTime * speed) % (math.pi * 2)
	local bob = if companion.flies
		then math.sin(companion.phase) * amplitude
		else math.abs(math.sin(companion.phase)) * amplitude

	--[[
		Питомец смотрит туда же, куда хозяин: разворот берётся у корня, а не
		считается из движения — питомец держится сбоку и на развороте хозяина
		двигается вбок, то есть своё направление у него было бы поперёк.
	]]
	local pivot = CFrame.new(companion.drawn + Vector3.new(0, bob, 0)) * (root.CFrame - root.CFrame.Position)

	local lamp = companion.light
	if lamp then
		lamp.CFrame = pivot
	end

	local built = companion.model
	if built then
		--[[
			Модель стоит НА земле: её offset отсчитан от пола, а pivot указывает
			в середину питомца. Опускаем на полвысоты, иначе зверь висит.

			Скорость нулевая: шага у питомцев нет, они подпрыгивают.
		]]
		built.Draw(pivot * CFrame.new(0, -companion.size.Y * 0.5, 0), deltaTime, 0)
	elseif part then
		part.CFrame = pivot
	end

	local count = #companion.sparkles
	if count == 0 then
		return
	end

	companion.sparklePhase = (companion.sparklePhase + deltaTime * numbers.sparkleSpeed) % 1
	local radius = math.max(companion.size.X, companion.size.Z) * 0.8

	-- Орбита считается от пивота, а не от детали тела: у собранной модели
	-- такой детали нет, а искры должны кружить вокруг зверя целиком.
	for index, sparkle in companion.sparkles do
		local angle = (companion.sparklePhase + (index - 1) / count) * math.pi * 2
		sparkle.CFrame = pivot
			* CFrame.new(math.cos(angle) * radius, math.sin(angle * 2) * 0.4, math.sin(angle) * radius)
	end
end

local function onHeartbeat(deltaTime: number): ()
	for player, companion in companions do
		local root = getRoot(player)

		-- Хозяина нет (смерть, загрузка, вышел) или его питомца сейчас не видно.
		if not root or not isVisible(companion, root) then
			companion.folder.Parent = nil
			continue
		end

		if companion.folder.Parent == nil then
			companion.folder.Parent = container
			-- Появившегося питомца ставим сразу на место, а не подтягиваем
			-- через полкарты.
			companion.drawn = root.Position
		end

		step(companion, deltaTime, root)
	end
end

local function watch(player: Player): ()
	refresh(player)
	player:GetAttributeChangedSignal(Net.Attribute.EquippedPet):Connect(function()
		refresh(player)
	end)
end

function PetCompanionController.Start(): ()
	local folder = Instance.new("Folder")
	folder.Name = "PetCompanions"
	folder.Parent = Workspace
	container = folder

	for _, player in Players:GetPlayers() do
		watch(player)
	end
	Players.PlayerAdded:Connect(watch)
	Players.PlayerRemoving:Connect(destroy)

	RunService.Heartbeat:Connect(onHeartbeat)
end

return PetCompanionController
