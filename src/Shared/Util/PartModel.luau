--!strict
--[[
	PartModel — сборщик моделей из примитивов по описанию из Config/Models.

	Один сборщик на все модели: новый босс обязан быть записью в конфиге, а не
	куском кода. Как и остальные утилиты, построен на замыканиях — отсюда
	вызовы через точку: built.Draw(...), а не built:Draw(...).

	ПОЧЕМУ НЕ Model:PivotTo. Модель двигается одним BulkMoveTo, тем же способом,
	что враги и кристаллы: это уже идиома проекта, она не трогает физику и не
	зависит от того, где у Model оказался WorldPivot.

	Анимация знает ровно две вещи: время и пройденный путь. Про бой она не
	знает ничего — поза от атак завязала бы картинку на порядок сетевых
	событий, а именно там у нас уже был баг с перестановкой спавнов и смертей.

	Шаг (канал step) считается от ПУТИ, а не от времени: фаза, привязанная
	к расстоянию, совпадает с землёй сама на любой скорости. Считай мы её
	от времени — получили бы либо ноги, перебирающие на месте, либо шаг
	не в такт движению.

	ЛЕНТА И ИСКРЫ (поля trail и particles у детали). Trail и ParticleEmitter —
	объекты движка, а не ассеты: ни картинки, ни загрузки им не нужно, и
	правило про сторонние ассеты их не касается. Собираются один раз вместе
	с деталью, дальше только включаются и выключаются вместе с моделью —
	создавать их в бою нельзя ровно так же, как и детали.

	Публичный API:
		PartModel.TintsFor(base, accent) -> Tints
		PartModel.Build(def, tints, parent) -> Built
			built.Draw(pivot, deltaTime, speed)
			built.SetVisible(visible)
			built.SetTints(tints)
			built.Height() / built.Footprint()
			built.Destroy()
]]

local Workspace = game:GetService("Workspace")

local Types = require(script.Parent.Parent.Types)

type ModelDef = Types.ModelDef
type ModelPartDef = Types.ModelPartDef

export type Tints = {
	primary: Color3,
	secondary: Color3,
	dark: Color3,
	accent: Color3,
}

export type Built = {
	--[[
		pivot — куда поставить модель: точка на полу и разворот. Y пивота —
		уровень пола, потому что offset деталей отсчитан от него же.

		speed — с какой скоростью модель едет по земле прямо сейчас, студов
		в секунду. Нужна каналу step: шаг отсчитывается от пройденного пути,
		а не от времени, и стоящая модель ноги не переставляет.
	]]
	Draw: (pivot: CFrame, deltaTime: number, speed: number) -> (),
	SetVisible: (visible: boolean) -> (),
	SetTints: (tints: Tints) -> (),
	--[[
		Во сколько раз быстрее идёт собственное время модели. Нужно там, где
		скорость анимации задаёт механика, а не конфиг: огни колеса бегут
		в такт диску, то есть разгоняются и затухают вместе с ним.
	]]
	SetTimeScale: (scale: number) -> (),
	Height: () -> number,
	Footprint: () -> number,
	Destroy: () -> (),
}

--[[
	Лента и искры хранятся вместе со своим описанием: смена палитры носителя
	обязана перекрасить и их, а собрать градиент заново можно только из тех же
	ролей, из которых он собирался в первый раз.
]]
type TrailEntry = {
	trail: Trail,
	def: Types.ModelTrailDef,
}

type ParticleEntry = {
	emitter: ParticleEmitter,
	def: Types.ModelParticlesDef,
}

type Entry = {
	part: BasePart,
	def: ModelPartDef,
	base: CFrame, -- положение детали в системе координат модели
	baseSize: Vector3,
	transparency: number,
	-- Своя фаза, чтобы детали с одинаковой скоростью не качались строем.
	-- У step она задаётся в конфиге: ноги обязаны попадать друг в друга.
	phase: number,
	-- Подвес для step, посчитан один раз: качание вокруг бедра — это
	-- поворот, зажатый между переносом туда и обратно.
	hip: CFrame?,
	hipInverse: CFrame?,
}

local PartModel = {}

local SHAPES: { [string]: Enum.PartType } = {
	Block = Enum.PartType.Block,
	Ball = Enum.PartType.Ball,
	Cylinder = Enum.PartType.Cylinder,
}

local MESHES: { [string]: Enum.MeshType } = {
	Head = Enum.MeshType.Head,
	Sphere = Enum.MeshType.Sphere,
	Wedge = Enum.MeshType.Wedge,
}

--[[
	Палитра модели из цвета стихии.

	Три оттенка одного цвета вместо трёх независимых: силуэт должен читаться
	как один объект своей стихии, а не как собранный из разноцветных кубиков.
	accent приходит отдельно — это металл короны и рун, и он от стихии
	не зависит (Palette.Model).
]]
function PartModel.TintsFor(base: Color3, accent: Color3): Tints
	return {
		primary = base,
		secondary = base:Lerp(Color3.new(1, 1, 1), 0.35),
		dark = base:Lerp(Color3.new(0, 0, 0), 0.55),
		accent = accent,
	}
end

local function tintOf(tints: Tints, role: Types.ModelTint?): Color3
	if role == "secondary" then
		return tints.secondary
	elseif role == "dark" then
		return tints.dark
	elseif role == "accent" then
		return tints.accent
	end
	return tints.primary
end

-- Ручной цвет детали важнее палитры носителя: одежда и металл не меняются
-- вместе со стихией. Проставлен он или нет, решил загрузчик Models.
local function colorOf(tints: Tints, partDef: ModelPartDef): Color3
	return partDef.paint or tintOf(tints, partDef.tint)
end

--[[
	Раскрасить ленту: переход от цвета у детали к цвету на излёте.

	Смысл ленты именно в переходе. Одноцветная лента — это та же палка,
	которой эффекты и были до сих пор, только волочащаяся следом.
]]
local function paintTrail(entry: TrailEntry, tints: Tints): ()
	local head = tintOf(tints, entry.def.tint)
	local tail = tintOf(tints, entry.def.tailTint or entry.def.tint)
	entry.trail.Color = ColorSequence.new(head, tail)
end

function PartModel.Build(def: ModelDef, tints: Tints, parent: Instance): Built
	local folder = Instance.new("Folder")
	folder.Name = `Model_{def.key}`
	folder.Parent = parent

	local entries: { Entry } = {}
	-- Массивы для BulkMoveTo переиспользуются: их длина не меняется никогда,
	-- модель не теряет и не добавляет деталей.
	local moveParts: { BasePart } = {}
	local moveCFrames: { CFrame } = {}
	local pulsed: { Entry } = {}
	local trails: { TrailEntry } = {}
	local particles: { ParticleEntry } = {}
	--[[
		glow трогает прозрачность, а не геометрию, поэтому идёт отдельным
		списком и в BulkMoveTo не участвует вовсе. Списки не пересекаются:
		деталь несёт ровно один канал.
	]]
	local glowing: { Entry } = {}

	local visible = false
	local elapsed = 0
	local timeScale = 1

	--[[
		Пройденный путь и «идёт ли сейчас» для канала step.

		stride копит СТАДЫ, а не секунды: фаза шага, привязанная к пути,
		совпадает с землёй на любой скорости сама. gait сглаживает пуск и
		остановку — без него ноги замирали бы посреди шага в тот кадр,
		когда босс встал, и разъезжались бы рывком, когда он тронулся.
	]]
	local stride = 0
	local gait = 0

	--[[
		Есть ли у модели хоть одна деталь, которая двигается. Если нет —
		её геометрию достаточно разложить один раз и больше не трогать:
		предмет лобби стоит на месте всю сессию, и гонять его два десятка
		деталей через BulkMoveTo каждый кадр ради мигающего света незачем.

		Сравнение с прошлым пивотом обязательно: неподвижная модель, которую
		всё же переставили, обязана переехать.
	]]
	local moving = false
	local placed = false
	local lastPivot = CFrame.identity

	for index, partDef in def.parts do
		local part = Instance.new("Part")
		part.Name = `{def.key}_{index}`
		part.Anchored = true
		part.CanCollide = false
		part.CanQuery = false
		part.CanTouch = false
		part.Massless = true
		part.CastShadow = false
		part.Shape = SHAPES[partDef.shape] or Enum.PartType.Block
		part.Size = partDef.size
		part.Color = colorOf(tints, partDef)
		part.Material = if partDef.neon then Enum.Material.Neon else Enum.Material.SmoothPlastic
		-- Собранная модель невидима: её показывают на спавне босса, а до
		-- того она обязана не висеть посреди арены.
		part.Transparency = 1

		--[[
			Свет создаётся один раз вместе с деталью и больше не трогается:
			он не анимируется вовсе. Мигать умеет прозрачность (канал glow),
			а дёргать Brightness каждый кадр — это уже настоящая нагрузка.
		]]
		if partDef.light then
			local light = Instance.new("PointLight")
			light.Range = partDef.light
			light.Brightness = 1.2
			light.Color = part.Color
			light.Shadows = false
			light.Parent = part
		end

		--[[
			Лента за деталью. Две точки привязки задают её ширину, и вертикаль
			здесь не случайна: лента, натянутая поперёк движения, читается
			хвостом, а натянутая вдоль — схлопывается в нитку.

			Выключена до показа модели, как и всё остальное: собранная модель
			висит невидимой до спавна и хвостом по арене мести не должна.
		]]
		local trailDef = partDef.trail
		if trailDef then
			local half = trailDef.length * 0.5

			local top = Instance.new("Attachment")
			top.Position = Vector3.new(0, half, 0)
			top.Parent = part

			local bottom = Instance.new("Attachment")
			bottom.Position = Vector3.new(0, -half, 0)
			bottom.Parent = part

			local trail = Instance.new("Trail")
			trail.Attachment0 = top
			trail.Attachment1 = bottom
			trail.Lifetime = trailDef.lifetime
			trail.FaceCamera = true
			--[[
				Лента светится, но не выжигает себя добела. Единица означает
				«свети своим цветом поверх всего», и на ярких стихиях лента
				от этого теряет цвет целиком: жёлтая полоса становится белой.
			]]
			trail.LightEmission = 0.5
			trail.Transparency = NumberSequence.new({
				NumberSequenceKeypoint.new(0, trailDef.transparency or 0),
				NumberSequenceKeypoint.new(1, 1),
			})
			trail.Enabled = false
			trail.Parent = part

			local entry: TrailEntry = { trail = trail, def = trailDef }
			paintTrail(entry, tints)
			table.insert(trails, entry)
		end

		--[[
			Искры. Текстура не задаётся: встроенная в движок годится, а любая
			другая была бы загруженным ассетом.

			Rate — постоянный поток, а не залп: искры принадлежат телу, которое
			живёт, пока живёт способность, и вспышками тут управлять нечем.
		]]
		local particlesDef = partDef.particles
		if particlesDef then
			local spread = particlesDef.spread or 0
			local emitter = Instance.new("ParticleEmitter")
			--[[
				Путь rbxasset — файл внутри самого движка, а не загруженный
				ассет: номера у него нет, модерация ему не грозит. Проставлен
				явно, хотя он же и стоит по умолчанию: молчаливая зависимость
				от значения по умолчанию — это невидимые искры в тот день,
				когда Roblox его поменяет.
			]]
			emitter.Texture = "rbxasset://textures/particles/sparkles_main.dds"
			emitter.Rate = particlesDef.rate
			emitter.Lifetime = NumberRange.new(particlesDef.lifetime * 0.6, particlesDef.lifetime)
			emitter.Speed = NumberRange.new(particlesDef.speed * 0.5, particlesDef.speed)
			emitter.SpreadAngle = Vector2.new(spread, spread)
			emitter.Acceleration = Vector3.new(0, particlesDef.rise or 0, 0)
			emitter.Color = ColorSequence.new(tintOf(tints, particlesDef.tint))
			-- Искра гаснет, уменьшаясь: обрыв на полном размере читается
			-- морганием, а не затуханием.
			emitter.Size = NumberSequence.new({
				NumberSequenceKeypoint.new(0, particlesDef.size),
				NumberSequenceKeypoint.new(1, 0),
			})
			emitter.Transparency = NumberSequence.new({
				NumberSequenceKeypoint.new(0, 0.1),
				NumberSequenceKeypoint.new(1, 1),
			})
			-- По той же причине, что у ленты: искры на светлой стихии
			-- сливаются в белое облако, если светятся в полную силу.
			emitter.LightEmission = 0.4
			emitter.Enabled = false
			emitter.Parent = part

			table.insert(particles, { emitter = emitter, def = particlesDef })
		end

		local meshType = if partDef.mesh then MESHES[partDef.mesh] else nil
		if meshType then
			local mesh = Instance.new("SpecialMesh")
			mesh.MeshType = meshType
			mesh.Parent = part
		end

		part.Parent = folder

		local angles = partDef.angles
		local rotation = if angles
			then CFrame.Angles(math.rad(angles.X), math.rad(angles.Y), math.rad(angles.Z))
			else CFrame.identity

		local hip = if partDef.animPivotY then CFrame.new(0, partDef.animPivotY, 0) else nil

		local entry: Entry = {
			part = part,
			def = partDef,
			base = CFrame.new(partDef.offset) * rotation,
			baseSize = partDef.size,
			transparency = partDef.transparency or 0,
			phase = if partDef.animPhase then partDef.animPhase * math.pi * 2 else index * 1.37,
			hip = hip,
			hipInverse = if hip then hip:Inverse() else nil,
		}

		entries[index] = entry
		moveParts[index] = part
		moveCFrames[index] = CFrame.identity

		if partDef.anim == "pulse" then
			table.insert(pulsed, entry)
			moving = true
		elseif partDef.anim == "glow" or partDef.anim == "flicker" then
			table.insert(glowing, entry)
		elseif partDef.anim ~= nil then
			moving = true
		end
	end

	local api = {}

	function api.Draw(pivot: CFrame, deltaTime: number, speed: number): ()
		if not visible then
			return
		end

		elapsed += deltaTime * timeScale
		stride += speed * deltaTime

		--[[
			Порог в один стад в секунду — это дрожание интерполяции, а не
			ходьба. Ниже него ноги сводятся в стойку, а не замирают
			в том положении, в котором их застала остановка.
		]]
		local walking = if speed > 1 then 1 else 0
		gait += (walking - gait) * math.min(deltaTime * 8, 1)

		--[[
			pulse меняет размер, а не положение, поэтому идёт отдельным
			проходом до BulkMoveTo: новый размер нужен ниже, чтобы посчитать
			центр детали, у которой низ остаётся на месте.
		]]
		for _, entry in pulsed do
			local rate = entry.def.animSpeed or 1
			local amount = entry.def.animAmount or 0
			local wave = math.sin((elapsed * rate + entry.phase) * math.pi * 2) * amount

			-- Вертикаль тянется, горизонталь поджимается: так пульсация
			-- читается как дыхание, а не как равномерно надувающийся шар.
			local sizeY = entry.baseSize.Y * (1 + wave)
			local sizeXZ = 1 - wave * 0.5
			entry.part.Size = Vector3.new(entry.baseSize.X * sizeXZ, sizeY, entry.baseSize.Z * sizeXZ)
		end

		--[[
			Прозрачность светящихся. Свет дышит вокруг СВОЕЙ прозрачности,
			а не от нуля: у поверхности портала она и так не нулевая, и
			размах, отсчитанный от нуля, гасил бы её в ноль каждый цикл.
		]]
		for _, entry in glowing do
			local rate = entry.def.animSpeed or 1
			local amount = entry.def.animAmount or 0
			local time = elapsed * rate + entry.phase
			local wave = math.sin(time * math.pi * 2)

			--[[
				Пламя вместо лампы: вторая волна несоизмеримой частоты ломает
				период, и рисунок не повторяется на глаз. Чистая синусоида
				на фонаре читается приборной сигнализацией.
			]]
			if entry.def.anim == "flicker" then
				wave = (wave + math.sin(time * 6.7 * math.pi * 2) * 0.6) / 1.6
			end

			entry.part.Transparency = math.clamp(entry.transparency + wave * amount, 0, 1)
		end

		if not moving and placed and pivot == lastPivot then
			return
		end
		placed = true
		lastPivot = pivot

		for index, entry in entries do
			local cf = entry.base
			local anim = entry.def.anim

			if anim == "spin" then
				-- Поворот слева: деталь облетает ось модели, а не крутится
				-- вокруг себя. На шаре вращение вокруг себя не видно вовсе.
				cf = CFrame.Angles(0, elapsed * (entry.def.animSpeed or 1) * math.pi * 2, 0) * cf
			elseif anim == "bob" then
				local rate = entry.def.animSpeed or 1
				local amount = entry.def.animAmount or 0
				local lift = math.sin((elapsed * rate + entry.phase) * math.pi * 2) * amount
				cf += Vector3.new(0, lift, 0)
			elseif anim == "pulse" then
				-- Низ детали остаётся на месте: слизень дышит, стоя на полу,
				-- а не всплывает над ним.
				local bottom = entry.def.offset.Y - entry.baseSize.Y * 0.5
				cf *= CFrame.new(0, entry.part.Size.Y * 0.5 + bottom - entry.def.offset.Y, 0)
			elseif anim == "step" then
				local hip = entry.hip
				local hipInverse = entry.hipInverse
				if hip and hipInverse then
					--[[
						Размах гасится gait, а не обнуляется скоростью: так
						шаг затухает за пару кадров вместо того, чтобы
						оборваться на середине.

						Поворот вокруг X качает деталь вперёд-назад, а зажатый
						между переносами он делает это вокруг бедра — и нога,
						и ступня ходят по одной дуге.
					]]
					local swing = math.rad(entry.def.animAmount or 0)
						* math.sin(stride * (entry.def.animSpeed or 1) * math.pi * 2 + entry.phase)
						* gait
					cf = hip * CFrame.Angles(swing, 0, 0) * hipInverse * cf
				end
			end

			moveCFrames[index] = pivot * cf
		end

		Workspace:BulkMoveTo(moveParts, moveCFrames, Enum.BulkMoveMode.FireCFrameChanged)
	end

	function api.SetVisible(value: boolean): ()
		if visible == value then
			return
		end
		visible = value

		for _, entry in entries do
			entry.part.Transparency = if value then entry.transparency else 1
		end

		for _, entry in trails do
			--[[
				Лента помнит пройденный путь и НЕ забывает его, пока не истёк
				lifetime. Тело, взятое из пула в другой точке арены, дорисовало
				бы полосу от места, где его спрятали, до места, где показали, —
				через пол-арены. Отсюда Clear перед показом.
			]]
			if value then
				entry.trail:Clear()
			end
			entry.trail.Enabled = value
		end

		for _, entry in particles do
			entry.emitter.Enabled = value
		end
	end

	function api.SetTimeScale(scale: number): ()
		timeScale = math.max(scale, 0)
	end

	function api.SetTints(value: Tints): ()
		for _, entry in entries do
			-- Крашеные детали смену палитры не замечают вовсе.
			if entry.def.paint == nil then
				entry.part.Color = tintOf(value, entry.def.tint)
			end
		end

		for _, entry in trails do
			paintTrail(entry, value)
		end

		for _, entry in particles do
			entry.emitter.Color = ColorSequence.new(tintOf(value, entry.def.tint))
		end
	end

	function api.Height(): number
		return def.height
	end

	function api.Footprint(): number
		return def.footprint
	end

	function api.Destroy(): ()
		folder:Destroy()
		table.clear(entries)
		table.clear(moveParts)
		table.clear(moveCFrames)
		table.clear(pulsed)
		table.clear(glowing)
		table.clear(trails)
		table.clear(particles)
	end

	return api
end

return PartModel
