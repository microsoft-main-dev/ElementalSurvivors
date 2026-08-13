--!strict
--[[
	FxKit — из чего сделаны эффекты способностей: детали и тела, все из пулов.

	Правило «ноль Instance.new в бою» во всём клиенте нарушал ровно один
	модуль — отрисовка способностей: Nova, Cone и Chain создавали деталь на
	каждое срабатывание и уничтожали её через доли секунды. Один только Cone
	за пятнадцатиминутный забег — это около трёх тысяч созданий и уничтожений,
	и каждое из них заставляет движок собрать новый объект отрисовки. Пока
	эффект был одной неоновой палкой, цена терялась в шуме; с телом из вокселей
	она вырастет на порядок, и переделывать пришлось бы то, что только что
	нарисовали.

	ПУЛЫ И ПАПКА ЖИВУТ МЕЖДУ ЗАБЕГАМИ. Уничтожать их в конце забега — значит
	платить созданием полусотни деталей на первых секундах следующего боя ради
	памяти, которой не жалко: деталь без родителя движку ничего не стоит.
	Заодно исчезает целый класс ошибок: папка забега, уничтоженная раньше,
	чем в пул вернулись лежащие в ней детали, раздавала бы следующему забегу
	уничтоженные.

	ТЕЛА — ОТДЕЛЬНЫЙ ПУЛ. Тело собирает PartModel, а это десяток Instance.new
	на штуку, и в бою так делать нельзя. Поэтому тело каждого вида собирается
	один раз за сессию при первом появлении своей способности и дальше только
	показывается и прячется. Первое появление приходится на выбор карточки,
	то есть на паузу левел-апа, — единственный момент боя, когда рывок не виден.

	Публичный API:
		FxKit.Init()                       -- начало забега
		FxKit.Get(shape) -> Part
		FxKit.Release(part)
		FxKit.GetBody(modelKey, tints) -> PartModel.Built
		FxKit.ReleaseBody(modelKey, body)
		FxKit.GetBeam(from, to, width, head, tail) -> BeamRig
		FxKit.ReleaseBeam(rig)
		FxKit.Burst(position, color, count) -> BurstRig
		FxKit.ReleaseBurst(rig)
		FxKit.Clear()                      -- вернуть всё в пулы
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Models = require(Shared.Config.Models)
local PartModel = require(Shared.Util.PartModel)
local Pool = require(Shared.Util.Pool)

local FxKit = {}

--[[
	Сколько деталей каждой формы создать заранее.

	Block — контуры: венец ауры (двадцать четыре зубца на каждую, а аур
	у игрока бывает две), расходящиеся стены Nova (ещё двадцать четыре на
	каждую вспышку) и края клина. Отсюда и число.
	Cylinder — заливка аур, её единицы.

	Шара в списке нет: всё, что раньше было неоновым шаром или палкой, теперь
	собственное тело способности, а тела живут в своих пулах.

	Числа с запасом: пул при нехватке создаст ещё, но создаст уже в бою —
	ровно то, чего этот модуль и заведён избегать.
]]
local WARMUP: { [Enum.PartType]: number } = {
	[Enum.PartType.Block] = 120,
	[Enum.PartType.Cylinder] = 4,
}

--[[
	Дуга между двумя точками (Beam) и её концы.

	Beam соединяет две точки привязки, и точки эти обязаны на чём-то висеть,
	поэтому у дуги два собственных якоря — невидимые детали, которые никуда,
	кроме концов дуги, не ставятся.
]]
export type BeamRig = {
	from: Part,
	to: Part,
	beam: Beam,
}

-- Залп искр: деталь с излучателем, который ничего не льёт постоянно,
-- а выбрасывает порцию по требованию.
export type BurstRig = {
	part: Part,
	emitter: ParticleEmitter,
}

--[[
	Сколько живёт залп искр. Держать деталь дольше незачем, а короче нельзя:
	вместе с ней исчезнут и её частицы, оборвавшись на полпути.
]]
local BURST_LIFE = 0.55
FxKit.BurstLife = BURST_LIFE

local container: Folder? = nil
local pools: { [Enum.PartType]: Pool.Pool<Part> } = {}
local bodyPools: { [string]: Pool.Pool<PartModel.Built> } = {}
local beamPool: Pool.Pool<BeamRig>? = nil
local burstPool: Pool.Pool<BurstRig>? = nil

-- Из какого пула пришла деталь. Иначе Release пришлось бы звать, помня форму,
-- а на месте возврата (гаснущая вспышка, улетевший снаряд) её уже никто не знает.
local poolOf: { [Part]: Pool.Pool<Part> } = {}

local function getContainer(): Folder
	local existing = container
	if existing then
		return existing
	end

	local folder = Instance.new("Folder")
	folder.Name = "AbilityFx"
	folder.Parent = Workspace
	container = folder
	return folder
end

local function makePart(shape: Enum.PartType): Part
	local part = Instance.new("Part")
	part.Shape = shape
	part.Material = Enum.Material.Neon
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.Massless = true
	part.CastShadow = false
	return part
end

local function resetPart(part: Part): ()
	part.Parent = nil
	-- Прозрачность гасят и Nova, и вспышки клина. Деталь, вернувшаяся в пул
	-- невидимой, досталась бы следующему хозяину невидимой.
	part.Transparency = 0
	-- Материал меняет заливка ауры: неон не темнеет от прозрачности и светит
	-- почти так же ярко на 0.93, как на нуле. Без возврата следующий круг
	-- Nova достался бы из пула тусклым пластиком.
	part.Material = Enum.Material.Neon
end

local function getPool(shape: Enum.PartType): Pool.Pool<Part>
	local existing = pools[shape]
	if existing then
		return existing
	end

	local created = Pool.new(function(): Part
		return makePart(shape)
	end, resetPart, WARMUP[shape] or 8)
	pools[shape] = created
	return created
end

-- Невидимая деталь-держатель: точка привязки дуги или излучатель залпа.
-- Своя, потому что и то и другое обязано висеть на детали, а показывать
-- саму деталь при этом не надо.
local function makeAnchor(): Part
	local part = Instance.new("Part")
	part.Size = Vector3.new(0.1, 0.1, 0.1)
	part.Transparency = 1
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.Massless = true
	part.CastShadow = false

	local attachment = Instance.new("Attachment")
	attachment.Parent = part
	return part
end

local function getBeamPool(): Pool.Pool<BeamRig>
	local existing = beamPool
	if existing then
		return existing
	end

	local created = Pool.new(function(): BeamRig
		local from = makeAnchor()
		local to = makeAnchor()

		local beam = Instance.new("Beam")
		beam.Attachment0 = from:FindFirstChildOfClass("Attachment")
		beam.Attachment1 = to:FindFirstChildOfClass("Attachment")
		beam.FaceCamera = true
		-- Свечение вполсилы: молния, светящаяся в полную, выгорает добела
		-- и теряет цвет стихии — а он тут единственное, что её называет.
		beam.LightEmission = 0.5
		-- Излом рисуется НЕСКОЛЬКИМИ дугами подряд (см. spawnChain), поэтому
		-- каждой отдельной хватает пары сегментов: гнуть её незачем.
		beam.Segments = 2
		beam.Parent = from

		return { from = from, to = to, beam = beam }
	end, function(rig: BeamRig)
		rig.from.Parent = nil
		rig.to.Parent = nil
	end, 36)
	beamPool = created
	return created
end

local function getBurstPool(): Pool.Pool<BurstRig>
	local existing = burstPool
	if existing then
		return existing
	end

	local created = Pool.new(function(): BurstRig
		local part = makeAnchor()

		local emitter = Instance.new("ParticleEmitter")
		emitter.Texture = "rbxasset://textures/particles/sparkles_main.dds"
		--[[
			Постоянного потока нет: залп выбрасывается вызовом Emit, и он
			работает независимо от Enabled. Постоянный поток пришлось бы
			включать и выключать по таймеру, то есть держать второе состояние
			там, где хватает одного вызова.
		]]
		emitter.Rate = 0
		emitter.Enabled = false
		--[[
			Не в полную силу: два десятка светящихся во всю мощь искр
			на светлой стихии сливаются в белое пятно, за которым не видно
			ни тела способности, ни врагов.
		]]
		emitter.LightEmission = 0.35
		emitter.Lifetime = NumberRange.new(0.25, BURST_LIFE)
		emitter.Speed = NumberRange.new(4, 9)
		emitter.SpreadAngle = Vector2.new(180, 180)
		-- Искры оседают, а не висят: разлёт во все стороны без падения
		-- читается облаком, а не ударом.
		emitter.Acceleration = Vector3.new(0, -8, 0)
		emitter.Size = NumberSequence.new({
			NumberSequenceKeypoint.new(0, 0.3),
			NumberSequenceKeypoint.new(1, 0),
		})
		emitter.Transparency = NumberSequence.new({
			NumberSequenceKeypoint.new(0, 0.1),
			NumberSequenceKeypoint.new(1, 1),
		})
		emitter.Parent = part

		return { part = part, emitter = emitter }
	end, function(rig: BurstRig)
		rig.part.Parent = nil
	end, 12)
	burstPool = created
	return created
end

function FxKit.Init(): ()
	getContainer()
	for shape in WARMUP do
		getPool(shape)
	end
	getBeamPool()
	getBurstPool()
end

function FxKit.Get(shape: Enum.PartType): Part
	local pool = getPool(shape)
	local part = pool.Get()
	poolOf[part] = pool
	part.Parent = getContainer()
	return part
end

function FxKit.Release(part: Part): ()
	local pool = poolOf[part]
	if not pool then
		return
	end
	poolOf[part] = nil
	pool.Release(part)
end

--[[
	Тело эффекта.

	tints запоминаются первым обращением: вид тела принадлежит ровно одной
	способности, а её стихия за забег не меняется. Разошлись бы они — цвет
	пришлось бы навязывать каждому выданному телу заново, каждый кадр
	перекрашивая десяток деталей.
]]
function FxKit.GetBody(modelKey: string, tints: PartModel.Tints): PartModel.Built
	local pool = bodyPools[modelKey]
	if not pool then
		local def = assert(Models.ByKey[modelKey], `[FxKit] Нет модели тела "{modelKey}"`)

		pool = Pool.new(function(): PartModel.Built
			return PartModel.Build(def, tints, getContainer())
		end, function(body: PartModel.Built)
			body.SetVisible(false)
		end)
		bodyPools[modelKey] = pool
	end

	local body = pool.Get()
	body.SetVisible(true)
	return body
end

function FxKit.ReleaseBody(modelKey: string, body: PartModel.Built): ()
	local pool = bodyPools[modelKey]
	if pool then
		pool.Release(body)
	end
end

--[[
	Дуга от точки к точке.

	Ширину и цвет задаёт вызывающий: у цепи молний она одна, у длинной дуги
	другая, а цвет — стихия способности. Прозрачность крутится снаружи,
	пока дуга гаснет.
]]
function FxKit.GetBeam(from: Vector3, to: Vector3, width: number, head: Color3, tail: Color3): BeamRig
	local rig = getBeamPool().Get()
	local parent = getContainer()

	rig.from.CFrame = CFrame.new(from)
	rig.to.CFrame = CFrame.new(to)
	rig.from.Parent = parent
	rig.to.Parent = parent

	rig.beam.Width0 = width
	-- Сужение к концу: дуга обязана иметь направление, иначе она читается
	-- палкой, соединяющей двух врагов, а не прыжком молнии.
	rig.beam.Width1 = width * 0.55
	rig.beam.Color = ColorSequence.new(head, tail)
	rig.beam.Transparency = NumberSequence.new(0)

	return rig
end

function FxKit.ReleaseBeam(rig: BeamRig): ()
	getBeamPool().Release(rig)
end

function FxKit.Burst(position: Vector3, color: Color3, count: number): BurstRig
	local rig = getBurstPool().Get()
	rig.part.CFrame = CFrame.new(position)
	rig.part.Parent = getContainer()
	rig.emitter.Color = ColorSequence.new(color)
	rig.emitter:Emit(count)
	return rig
end

function FxKit.ReleaseBurst(rig: BurstRig): ()
	getBurstPool().Release(rig)
end

function FxKit.Clear(): ()
	for _, pool in pools do
		pool.ReleaseAll()
	end
	table.clear(poolOf)

	for _, pool in bodyPools do
		pool.ReleaseAll()
	end

	getBeamPool().ReleaseAll()
	getBurstPool().ReleaseAll()
end

return FxKit
