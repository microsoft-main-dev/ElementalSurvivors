--!strict
--[[
	Models — модели из примитивов (раздел 2.1 ТЗ).

	Модель — это таблица деталей, а не кусок кода: новый босс должен быть
	записью здесь, а собирает её один общий сборщик Shared/Util/PartModel.

	Носят модели пока только боссы. Босс один на арену, и десяток деталей ему
	по карману. Врагам и кристаллам нельзя — их сотни, каждый ходит одной
	деталью из пула, и вторая удвоила бы массив в BulkMoveTo за кадр; им
	останется SpecialMesh со встроенным типом на той же одной детали.

	Ассетов тут нет и не будет: только Part, встроенные MeshType и цвета
	из Palette (раздел 1 ТЗ, пункт про сторонние ассеты).

	СИСТЕМА КООРДИНАТ. offset считается от точки, которой модель стоит на
	полу: Y = 0 — это пол, а не центр модели. Перёд — в сторону -Z, как
	у CFrame.lookAt: туда же смотрит разворот босса.

	ГАБАРИТЫ НЕ ЗАДАЮТСЯ, А СЧИТАЮТСЯ. footprint и height выводит загрузчик
	внизу файла по самим деталям. Это не удобство: footprint сверяется с
	боевым радиусом босса в Config/Bosses, и записанное руками число разошлось
	бы с рисунком при первой же правке — то есть соврало бы игроку, который
	по картинке уворачивается.

	Публичный API:
		Models.List / Models.ByKey
]]

local Palette = require(script.Parent.Palette)
local Types = require(script.Parent.Parent.Types)

type ModelDef = Types.ModelDef
type ModelPartDef = Types.ModelPartDef

local Models = {}

--[[
	Потолок деталей на модель. Не техническое ограничение — босс на арене
	один и уезжает одним BulkMoveTo, — а граница читаемости: силуэт, который
	собирают из мелочей, в бою с тремя сотнями врагов не разглядят.

	Поднят с 16 до 28 под шамана, а затем до 200 под воксельных питомцев:
	у них объём набран кубиками, и даже со слиянием рядов выходит больше сотни.
	Босса это не касается — ему по-прежнему хватает трёх десятков.
]]
local MAX_PARTS = 200

--[[
	Потолок деталей у тела способности (ключ с приставкой Fx).

	Своё число, потому что своя арифметика: моделей питомца на арене одна,
	а тел способностей — по одному на каждый орб и каждый снаряд, то есть
	полтора десятка разом. Двенадцать кубиков на объект при пятнадцати
	объектах — это уже почти двести деталей поверх пяти сотен врагов.
]]
local MAX_FX_PARTS = 12

--[[
	Растеризовать описание в воксели.

	На вход — те же детали, которыми описана гранёная модель: набор шаров
	и коробок. На выход — объём, набранный кубиками, где каждый воксель
	покрашен той деталью, которая его накрыла последней.

	СЛИЯНИЕ РЯДОВ ОБЯЗАТЕЛЬНО. Кубиками по одному медвежонок стоит 481 деталь,
	слитыми рядами — 134. Подряд идущие воксели ОДНОГО цвета собираются в одну
	вытянутую коробку: приём стандартный для воксельных движков, снаружи
	неотличим. Отсюда же ограничение: узор, меняющийся вдоль X, стоит деталей,
	а вдоль Y и Z — бесплатен.

	ПОВЁРНУТЫЕ ДЕТАЛИ ПОДДЕРЖИВАЮТСЯ. Сначала здесь стоял запрет на них — из
	лени, а не по необходимости, — и первый же зверь с крыльями его уронил.
	Поворот считается ровно тем же способом, каким ниже в этом файле считается
	пятно модели, и стоит одного обратного умножения на деталь.

	МЕЛКАЯ ДЕТАЛЬ НЕ ПРОПАДАЕТ, А СТАНОВИТСЯ ОДНИМ ВОКСЕЛЕМ. Проверяется центр
	вокселя, поэтому деталь тоньше сетки может не накрыть ни одного центра и
	исчезнуть бесследно. Так и вышло: у лисы пропали глаза, у совы один глаз
	из двух, у оленя рога целиком. Поэтому при проверке каждая деталь
	раздувается до полутора вокселей по каждой оси — отрезок такой длины
	гарантированно содержит хотя бы один узел сетки.

	Раздувается ТОЛЬКО проверка попадания, не сама деталь: длинный тонкий рог
	остаётся длинным и тонким, он лишь перестаёт быть уже вокселя.

	И раздутая деталь проверяется как КОРОБКА, даже если описана шаром. Одного
	раздувания не хватило: у шара мало иметь по узлу сетки в каждом интервале —
	узел обязан попасть внутрь эллипсоида, а он проходит по углам и промахивается
	мимо всех. Так пропали глаза лисы, щенка и зайца уже ПОСЛЕ раздувания.
	У коробки попадание — это совпадение трёх независимых условий по осям,
	и узел находится всегда.
]]
local function voxelise(blobs: { ModelPartDef }, voxel: number): { ModelPartDef }
	local inverse: { CFrame } = {}
	local halves: { Vector3 } = {}
	-- Деталь пришлось раздувать, значит она мельче сетки и проверяется коробкой.
	local boxed: { boolean } = {}
	local low = { math.huge, math.huge, math.huge }
	local high = { -math.huge, -math.huge, -math.huge }

	-- Ниже этого деталь считается точкой и всё равно занимает один воксель.
	local minimum = voxel * 0.6

	for index, blob in blobs do
		--[[
			Лента и искры растеризацию не переживают: деталь превращается
			в десятки кубиков, и повесить хвост на каждый — это не тот эффект,
			который задумывали. Молча терять их нельзя, поэтому запрещаем.
		]]
		assert(
			blob.trail == nil and blob.particles == nil,
			`[Models] Деталь {index}: лента или искры на растеризуемой детали`
		)

		local angles = blob.angles
		local rotation = if angles
			then CFrame.Angles(math.rad(angles.X), math.rad(angles.Y), math.rad(angles.Z))
			else CFrame.identity
		inverse[index] = rotation:Inverse()

		--[[
			Габаритный ящик повёрнутой детали: |R| * halfSize — строка матрицы
			по модулю, умноженная на полуразмер. Мерить по size, забывая про
			поворот, значит обрезать крыло по его собственной длине.
		]]
		local half = Vector3.new(
			math.max(blob.size.X * 0.5, minimum),
			math.max(blob.size.Y * 0.5, minimum),
			math.max(blob.size.Z * 0.5, minimum)
		)
		halves[index] = half
		boxed[index] = half.X > blob.size.X * 0.5 or half.Y > blob.size.Y * 0.5 or half.Z > blob.size.Z * 0.5

		local right, up = rotation.RightVector, rotation.UpVector
		local back = -rotation.LookVector
		local extent = {
			math.abs(right.X) * half.X + math.abs(up.X) * half.Y + math.abs(back.X) * half.Z,
			math.abs(right.Y) * half.X + math.abs(up.Y) * half.Y + math.abs(back.Y) * half.Z,
			math.abs(right.Z) * half.X + math.abs(up.Z) * half.Y + math.abs(back.Z) * half.Z,
		}
		local offset = { blob.offset.X, blob.offset.Y, blob.offset.Z }

		for axis = 1, 3 do
			low[axis] = math.min(low[axis], offset[axis] - extent[axis])
			high[axis] = math.max(high[axis], offset[axis] + extent[axis])
		end
	end

	--[[
		Какая деталь накрывает точку. Последняя выигрывает: порядок в описании
		и есть порядок слоёв, как при обычной сборке.

		Точка переводится в собственную систему детали обратным поворотом —
		там проверка снова сводится к «внутри шара» или «внутри коробки».
	]]
	local function sample(x: number, y: number, z: number): ModelPartDef?
		local found: ModelPartDef? = nil

		for index, blob in blobs do
			local half = halves[index]
			local point = inverse[index] * Vector3.new(x - blob.offset.X, y - blob.offset.Y, z - blob.offset.Z)
			local dx = point.X / half.X
			local dy = point.Y / half.Y
			local dz = point.Z / half.Z

			local inside = if blob.shape == "Block" or boxed[index]
				then math.abs(dx) <= 1 and math.abs(dy) <= 1 and math.abs(dz) <= 1
				else dx * dx + dy * dy + dz * dz <= 1

			if inside then
				found = blob
			end
		end

		return found
	end

	local parts: { ModelPartDef } = {}
	local counts = {
		math.max(math.floor((high[1] - low[1]) / voxel) + 1, 1),
		math.max(math.floor((high[2] - low[2]) / voxel) + 1, 1),
		math.max(math.floor((high[3] - low[3]) / voxel) + 1, 1),
	}

	for iy = 0, counts[2] - 1 do
		local y = low[2] + (iy + 0.5) * voxel
		for iz = 0, counts[3] - 1 do
			local z = low[3] + (iz + 0.5) * voxel
			local runStart = 0
			local runBlob: ModelPartDef? = nil

			local function emit(from: number, to: number, blob: ModelPartDef): ()
				local width = to - from + 1
				local centre = low[1] + (from + (width - 1) * 0.5 + 0.5) * voxel
				table.insert(parts, {
					shape = "Block",
					size = Vector3.new(width * voxel, voxel, voxel),
					offset = Vector3.new(centre, y, z),
					tint = blob.tint,
					color = blob.color,
					neon = blob.neon,
					transparency = blob.transparency,
					anim = blob.anim,
					animSpeed = blob.animSpeed,
					animAmount = blob.animAmount,
				})
			end

			for ix = 0, counts[1] - 1 do
				local blob = sample(low[1] + (ix + 0.5) * voxel, y, z)
				if blob ~= runBlob then
					if runBlob then
						emit(runStart, ix - 1, runBlob)
					end
					runBlob, runStart = blob, ix
				end
			end

			if runBlob then
				emit(runStart, counts[1] - 1, runBlob)
			end
		end
	end

	return parts
end

-- Крупность вокселя у питомцев одна на всех: разная давала бы у соседних
-- зверей разную «пиксельность», и вместе они читались бы из разных игр.
local PET_VOXEL = 0.18

--[[
	Голубой щенок: висячие уши и белая грудка.

	Описание общее для обеих моделей: воксельной и гранёной.
]]
local FROSTPUP_BLOBS: { ModelPartDef } = {
	{
		shape = "Ball",
		size = Vector3.new(1.5, 1.3, 1.7),
		offset = Vector3.new(0, 0.72, 0.25),
		tint = "primary",
	},
	{
		shape = "Ball",
		size = Vector3.new(1.15, 1.1, 1.1),
		offset = Vector3.new(0, 1.5, -0.5),
		tint = "primary",
	},
	{
		shape = "Ball",
		size = Vector3.new(0.45, 0.8, 0.4),
		offset = Vector3.new(-0.6, 1.42, -0.45),
		tint = "primary",
	},
	{
		shape = "Ball",
		size = Vector3.new(0.45, 0.8, 0.4),
		offset = Vector3.new(0.6, 1.42, -0.45),
		tint = "primary",
	},
	{
		shape = "Ball",
		size = Vector3.new(0.6, 0.45, 0.45),
		offset = Vector3.new(0, 1.3, -1),
		tint = "secondary",
	},
	{
		shape = "Ball",
		size = Vector3.new(0.24, 0.2, 0.2),
		offset = Vector3.new(0, 1.36, -1.2),
		tint = "dark",
	},
	{
		shape = "Ball",
		size = Vector3.new(0.2, 0.22, 0.16),
		offset = Vector3.new(-0.28, 1.62, -0.95),
		tint = "dark",
	},
	{
		shape = "Ball",
		size = Vector3.new(0.2, 0.22, 0.16),
		offset = Vector3.new(0.28, 1.62, -0.95),
		tint = "dark",
	},
	{
		shape = "Ball",
		size = Vector3.new(0.4, 0.4, 0.5),
		offset = Vector3.new(-0.42, 0.22, -0.5),
		tint = "primary",
	},
	{
		shape = "Ball",
		size = Vector3.new(0.4, 0.4, 0.5),
		offset = Vector3.new(0.42, 0.22, -0.5),
		tint = "primary",
	},
	{
		shape = "Ball",
		size = Vector3.new(0.35, 0.5, 0.35),
		offset = Vector3.new(0, 0.95, 1.05),
		tint = "primary",
	},
}

--[[
	Черепаха: панцирь в два слоя и росток из него.

	Описание общее для обеих моделей: воксельной и гранёной.
]]
local MOSSSPROUT_BLOBS: { ModelPartDef } = {
	{
		shape = "Ball",
		size = Vector3.new(1.9, 1.15, 1.7),
		offset = Vector3.new(0, 0.62, 0.15),
		tint = "dark",
	},
	{
		shape = "Ball",
		size = Vector3.new(1.6, 0.95, 1.45),
		offset = Vector3.new(0, 0.72, 0.15),
		tint = "primary",
	},
	{
		shape = "Ball",
		size = Vector3.new(0.85, 0.8, 0.8),
		offset = Vector3.new(0, 0.62, -1),
		tint = "secondary",
	},
	{
		shape = "Ball",
		size = Vector3.new(0.18, 0.2, 0.14),
		offset = Vector3.new(-0.24, 0.78, -1.32),
		tint = "dark",
	},
	{
		shape = "Ball",
		size = Vector3.new(0.18, 0.2, 0.14),
		offset = Vector3.new(0.24, 0.78, -1.32),
		tint = "dark",
	},
	{
		shape = "Ball",
		size = Vector3.new(0.42, 0.34, 0.5),
		offset = Vector3.new(-0.62, 0.2, -0.5),
		tint = "secondary",
	},
	{
		shape = "Ball",
		size = Vector3.new(0.42, 0.34, 0.5),
		offset = Vector3.new(0.62, 0.2, -0.5),
		tint = "secondary",
	},
	{
		shape = "Ball",
		size = Vector3.new(0.42, 0.34, 0.5),
		offset = Vector3.new(-0.62, 0.2, 0.7),
		tint = "secondary",
	},
	{
		shape = "Ball",
		size = Vector3.new(0.42, 0.34, 0.5),
		offset = Vector3.new(0.62, 0.2, 0.7),
		tint = "secondary",
	},
	{
		shape = "Ball",
		size = Vector3.new(0.16, 0.7, 0.16),
		offset = Vector3.new(0, 1.4, 0.15),
		tint = "secondary",
	},
	{
		shape = "Ball",
		size = Vector3.new(0.6, 0.22, 0.3),
		offset = Vector3.new(-0.32, 1.72, 0.15),
		tint = "secondary",
	},
	{
		shape = "Ball",
		size = Vector3.new(0.6, 0.22, 0.3),
		offset = Vector3.new(0.32, 1.72, 0.15),
		tint = "secondary",
	},
}

--[[
	Мышь: круглые розовые уши больше головы, длинный хвост.

	Описание общее для обеих моделей: воксельной и гранёной.
]]
local SPARKKIT_BLOBS: { ModelPartDef } = {
	{
		shape = "Ball",
		size = Vector3.new(1.35, 1.4, 1.2),
		offset = Vector3.new(0, 0.75, 0.1),
		tint = "primary",
	},
	{
		shape = "Ball",
		size = Vector3.new(0.9, 0.75, 0.55),
		offset = Vector3.new(0, 0.62, -0.5),
		tint = "secondary",
	},
	{
		shape = "Ball",
		size = Vector3.new(1, 0.95, 0.9),
		offset = Vector3.new(0, 1.55, -0.2),
		tint = "primary",
	},
	{
		shape = "Ball",
		size = Vector3.new(0.62, 0.62, 0.24),
		offset = Vector3.new(-0.55, 2.02, -0.15),
		color = "plumeRed",
	},
	{
		shape = "Ball",
		size = Vector3.new(0.62, 0.62, 0.24),
		offset = Vector3.new(0.55, 2.02, -0.15),
		color = "plumeRed",
	},
	{
		shape = "Ball",
		size = Vector3.new(0.4, 0.3, 0.3),
		offset = Vector3.new(0, 1.42, -0.68),
		tint = "secondary",
	},
	{
		shape = "Ball",
		size = Vector3.new(0.16, 0.14, 0.14),
		offset = Vector3.new(0, 1.44, -0.82),
		tint = "dark",
	},
	{
		shape = "Ball",
		size = Vector3.new(0.2, 0.22, 0.14),
		offset = Vector3.new(-0.26, 1.66, -0.62),
		tint = "dark",
	},
	{
		shape = "Ball",
		size = Vector3.new(0.2, 0.22, 0.14),
		offset = Vector3.new(0.26, 1.66, -0.62),
		tint = "dark",
	},
	{
		shape = "Ball",
		size = Vector3.new(0.22, 0.22, 0.9),
		offset = Vector3.new(0, 0.55, 0.95),
		color = "plumeRed",
	},
	{
		shape = "Ball",
		size = Vector3.new(0.3, 0.18, 0.4),
		offset = Vector3.new(-0.34, 0.1, -0.35),
		color = "plumeRed",
	},
	{
		shape = "Ball",
		size = Vector3.new(0.3, 0.18, 0.4),
		offset = Vector3.new(0.34, 0.1, -0.35),
		color = "plumeRed",
	},
}

--[[
	Летучая мышь: крылья двумя плоскостями на сторону, глаза горят.

	Описание общее для обеих моделей: воксельной и гранёной.
]]
local DUSKMOTH_BLOBS: { ModelPartDef } = {
	{
		shape = "Ball",
		size = Vector3.new(0.9, 1.1, 0.8),
		offset = Vector3.new(0, 1.05, 0),
		tint = "primary",
	},
	{
		shape = "Ball",
		size = Vector3.new(0.75, 0.7, 0.7),
		offset = Vector3.new(0, 1.7, -0.15),
		tint = "primary",
	},
	{
		shape = "Ball",
		size = Vector3.new(0.3, 0.5, 0.16),
		offset = Vector3.new(-0.28, 2.12, -0.1),
		tint = "secondary",
	},
	{
		shape = "Ball",
		size = Vector3.new(0.3, 0.5, 0.16),
		offset = Vector3.new(0.28, 2.12, -0.1),
		tint = "secondary",
	},
	{
		shape = "Ball",
		size = Vector3.new(0.18, 0.16, 0.12),
		offset = Vector3.new(-0.2, 1.76, -0.42),
		color = "eggGem",
		neon = true,
	},
	{
		shape = "Ball",
		size = Vector3.new(0.18, 0.16, 0.12),
		offset = Vector3.new(0.2, 1.76, -0.42),
		color = "eggGem",
		neon = true,
	},
	{
		shape = "Block",
		size = Vector3.new(1.5, 0.7, 0.16),
		offset = Vector3.new(-1.15, 1.42, 0.1),
		tint = "secondary",
		angles = Vector3.new(0, 0, 16),
	},
	{
		shape = "Block",
		size = Vector3.new(1.5, 0.7, 0.16),
		offset = Vector3.new(1.15, 1.42, 0.1),
		tint = "secondary",
		angles = Vector3.new(0, 0, -16),
	},
	{
		shape = "Block",
		size = Vector3.new(1, 0.5, 0.14),
		offset = Vector3.new(-1.9, 1.15, 0.1),
		tint = "secondary",
		angles = Vector3.new(0, 0, 24),
	},
	{
		shape = "Block",
		size = Vector3.new(1, 0.5, 0.14),
		offset = Vector3.new(1.9, 1.15, 0.1),
		tint = "secondary",
		angles = Vector3.new(0, 0, -24),
	},
	{
		shape = "Ball",
		size = Vector3.new(0.34, 0.4, 0.3),
		offset = Vector3.new(0, 0.5, 0),
		tint = "primary",
	},
}

--[[
	Цыплёнок: нимб собран кольцом из шести искр — тора в Roblox нет.

	Описание общее для обеих моделей: воксельной и гранёной.
]]
local GLOWFINCH_BLOBS: { ModelPartDef } = {
	{
		shape = "Ball",
		size = Vector3.new(1.5, 1.6, 1.35),
		offset = Vector3.new(0, 0.95, 0),
		tint = "primary",
	},
	{
		shape = "Ball",
		size = Vector3.new(0.34, 0.24, 0.3),
		offset = Vector3.new(0, 1.05, -0.72),
		color = "plumeWarm",
	},
	{
		shape = "Ball",
		size = Vector3.new(0.2, 0.22, 0.14),
		offset = Vector3.new(-0.3, 1.35, -0.58),
		tint = "dark",
	},
	{
		shape = "Ball",
		size = Vector3.new(0.2, 0.22, 0.14),
		offset = Vector3.new(0.3, 1.35, -0.58),
		tint = "dark",
	},
	{
		shape = "Ball",
		size = Vector3.new(0.5, 0.6, 0.3),
		offset = Vector3.new(-0.72, 0.85, 0.05),
		tint = "secondary",
	},
	{
		shape = "Ball",
		size = Vector3.new(0.5, 0.6, 0.3),
		offset = Vector3.new(0.72, 0.85, 0.05),
		tint = "secondary",
	},
	{
		shape = "Ball",
		size = Vector3.new(0.24, 0.18, 0.34),
		offset = Vector3.new(-0.28, 0.12, -0.1),
		color = "plumeWarm",
	},
	{
		shape = "Ball",
		size = Vector3.new(0.24, 0.18, 0.34),
		offset = Vector3.new(0.28, 0.12, -0.1),
		color = "plumeWarm",
	},
	{
		shape = "Ball",
		size = Vector3.new(0.2, 0.12, 0.2),
		offset = Vector3.new(0.0, 2.05, 0.52),
		color = "eggAura",
		neon = true,
	},
	{
		shape = "Ball",
		size = Vector3.new(0.2, 0.12, 0.2),
		offset = Vector3.new(0.45, 2.05, 0.26),
		color = "eggAura",
		neon = true,
	},
	{
		shape = "Ball",
		size = Vector3.new(0.2, 0.12, 0.2),
		offset = Vector3.new(0.45, 2.05, -0.26),
		color = "eggAura",
		neon = true,
	},
	{
		shape = "Ball",
		size = Vector3.new(0.2, 0.12, 0.2),
		offset = Vector3.new(0.0, 2.05, -0.52),
		color = "eggAura",
		neon = true,
	},
	{
		shape = "Ball",
		size = Vector3.new(0.2, 0.12, 0.2),
		offset = Vector3.new(-0.45, 2.05, -0.26),
		color = "eggAura",
		neon = true,
	},
	{
		shape = "Ball",
		size = Vector3.new(0.2, 0.12, 0.2),
		offset = Vector3.new(-0.45, 2.05, 0.26),
		color = "eggAura",
		neon = true,
	},
}

--[[
	Лиса: пышный хвост со светлым кончиком и тёмные лапы.

	Описание общее для обеих моделей: воксельной и гранёной.
]]
local MAGMAHOUND_BLOBS: { ModelPartDef } = {
	{
		shape = "Ball",
		size = Vector3.new(1.3, 1.15, 1.9),
		offset = Vector3.new(0, 0.85, 0.2),
		tint = "primary",
	},
	{
		shape = "Ball",
		size = Vector3.new(0.95, 0.55, 1),
		offset = Vector3.new(0, 0.6, -0.35),
		tint = "secondary",
	},
	{
		shape = "Ball",
		size = Vector3.new(1, 0.95, 0.95),
		offset = Vector3.new(0, 1.5, -0.85),
		tint = "primary",
	},
	{
		shape = "Ball",
		size = Vector3.new(0.4, 0.55, 0.2),
		offset = Vector3.new(-0.4, 2.05, -0.8),
		tint = "secondary",
	},
	{
		shape = "Ball",
		size = Vector3.new(0.4, 0.55, 0.2),
		offset = Vector3.new(0.4, 2.05, -0.8),
		tint = "secondary",
	},
	{
		shape = "Ball",
		size = Vector3.new(0.55, 0.4, 0.6),
		offset = Vector3.new(0, 1.3, -1.45),
		tint = "secondary",
	},
	{
		shape = "Ball",
		size = Vector3.new(0.2, 0.16, 0.16),
		offset = Vector3.new(0, 1.34, -1.72),
		tint = "dark",
	},
	{
		shape = "Ball",
		size = Vector3.new(0.2, 0.22, 0.14),
		offset = Vector3.new(-0.26, 1.62, -1.28),
		tint = "dark",
	},
	{
		shape = "Ball",
		size = Vector3.new(0.2, 0.22, 0.14),
		offset = Vector3.new(0.26, 1.62, -1.28),
		tint = "dark",
	},
	{
		shape = "Ball",
		size = Vector3.new(0.85, 0.9, 1.1),
		offset = Vector3.new(0, 1.15, 1.35),
		tint = "primary",
	},
	{
		shape = "Ball",
		size = Vector3.new(0.62, 0.62, 0.62),
		offset = Vector3.new(0, 1.5, 1.95),
		tint = "secondary",
	},
	{
		shape = "Ball",
		size = Vector3.new(0.32, 0.5, 0.32),
		offset = Vector3.new(-0.42, 0.25, -0.5),
		tint = "dark",
	},
	{
		shape = "Ball",
		size = Vector3.new(0.32, 0.5, 0.32),
		offset = Vector3.new(0.42, 0.25, -0.5),
		tint = "dark",
	},
	{
		shape = "Ball",
		size = Vector3.new(0.32, 0.5, 0.32),
		offset = Vector3.new(-0.42, 0.25, 0.75),
		tint = "dark",
	},
	{
		shape = "Ball",
		size = Vector3.new(0.32, 0.5, 0.32),
		offset = Vector3.new(0.42, 0.25, 0.75),
		tint = "dark",
	},
}

--[[
	Сова: кисточки на голове и жёлтые глаза — по ним она и узнаётся.

	Описание общее для обеих моделей: воксельной и гранёной.
]]
local GLACIEROWL_BLOBS: { ModelPartDef } = {
	{
		shape = "Ball",
		size = Vector3.new(1.55, 1.75, 1.3),
		offset = Vector3.new(0, 1, 0),
		tint = "primary",
	},
	{
		shape = "Ball",
		size = Vector3.new(1.2, 0.9, 0.9),
		offset = Vector3.new(0, 1.65, -0.15),
		tint = "secondary",
	},
	{
		shape = "Ball",
		size = Vector3.new(0.3, 0.55, 0.2),
		offset = Vector3.new(-0.5, 2.15, 0),
		tint = "dark",
		angles = Vector3.new(0, 0, 18),
	},
	{
		shape = "Ball",
		size = Vector3.new(0.3, 0.55, 0.2),
		offset = Vector3.new(0.5, 2.15, 0),
		tint = "dark",
		angles = Vector3.new(0, 0, -18),
	},
	{
		shape = "Ball",
		size = Vector3.new(0.38, 0.38, 0.22),
		offset = Vector3.new(-0.32, 1.72, -0.6),
		color = "eggAura",
	},
	{
		shape = "Ball",
		size = Vector3.new(0.38, 0.38, 0.22),
		offset = Vector3.new(0.32, 1.72, -0.6),
		color = "eggAura",
	},
	{
		shape = "Ball",
		size = Vector3.new(0.16, 0.18, 0.12),
		offset = Vector3.new(-0.32, 1.72, -0.72),
		tint = "dark",
	},
	{
		shape = "Ball",
		size = Vector3.new(0.16, 0.18, 0.12),
		offset = Vector3.new(0.32, 1.72, -0.72),
		tint = "dark",
	},
	{
		shape = "Ball",
		size = Vector3.new(0.22, 0.3, 0.2),
		offset = Vector3.new(0, 1.48, -0.68),
		color = "plumeWarm",
	},
	{
		shape = "Ball",
		size = Vector3.new(0.45, 1, 0.45),
		offset = Vector3.new(-0.72, 0.95, 0.1),
		tint = "dark",
	},
	{
		shape = "Ball",
		size = Vector3.new(0.45, 1, 0.45),
		offset = Vector3.new(0.72, 0.95, 0.1),
		tint = "dark",
	},
	{
		shape = "Ball",
		size = Vector3.new(0.3, 0.18, 0.4),
		offset = Vector3.new(-0.3, 0.12, -0.15),
		color = "eggAura",
	},
	{
		shape = "Ball",
		size = Vector3.new(0.3, 0.18, 0.4),
		offset = Vector3.new(0.3, 0.12, -0.15),
		color = "eggAura",
	},
}

--[[
	Заяц: длинные уши с розовой изнанкой, пушистый хвост.

	Описание общее для обеих моделей: воксельной и гранёной.
]]
local STORMDRAKE_BLOBS: { ModelPartDef } = {
	{
		shape = "Ball",
		size = Vector3.new(1.25, 1.2, 1.7),
		offset = Vector3.new(0, 0.8, 0.25),
		tint = "primary",
	},
	{
		shape = "Ball",
		size = Vector3.new(0.95, 0.9, 0.9),
		offset = Vector3.new(0, 1.5, -0.6),
		tint = "primary",
	},
	{
		shape = "Ball",
		size = Vector3.new(0.32, 1.2, 0.24),
		offset = Vector3.new(-0.28, 2.35, -0.5),
		tint = "primary",
		angles = Vector3.new(0, 0, 10),
	},
	{
		shape = "Ball",
		size = Vector3.new(0.32, 1.2, 0.24),
		offset = Vector3.new(0.32, 2.35, -0.4),
		tint = "primary",
		angles = Vector3.new(0, 0, -14),
	},
	{
		shape = "Ball",
		size = Vector3.new(0.18, 0.9, 0.12),
		offset = Vector3.new(-0.28, 2.35, -0.56),
		color = "plumeRed",
		angles = Vector3.new(0, 0, 10),
	},
	{
		shape = "Ball",
		size = Vector3.new(0.18, 0.9, 0.12),
		offset = Vector3.new(0.32, 2.35, -0.46),
		color = "plumeRed",
		angles = Vector3.new(0, 0, -14),
	},
	{
		shape = "Ball",
		size = Vector3.new(0.4, 0.3, 0.35),
		offset = Vector3.new(0, 1.3, -1.05),
		tint = "secondary",
	},
	{
		shape = "Ball",
		size = Vector3.new(0.16, 0.14, 0.14),
		offset = Vector3.new(0, 1.34, -1.2),
		tint = "dark",
	},
	{
		shape = "Ball",
		size = Vector3.new(0.22, 0.24, 0.16),
		offset = Vector3.new(-0.3, 1.6, -0.95),
		tint = "dark",
	},
	{
		shape = "Ball",
		size = Vector3.new(0.22, 0.24, 0.16),
		offset = Vector3.new(0.3, 1.6, -0.95),
		tint = "dark",
	},
	{
		shape = "Ball",
		size = Vector3.new(0.45, 0.45, 0.45),
		offset = Vector3.new(0, 0.7, 1.15),
		tint = "secondary",
	},
	{
		shape = "Ball",
		size = Vector3.new(0.4, 0.5, 0.75),
		offset = Vector3.new(-0.48, 0.3, 0.5),
		tint = "primary",
	},
	{
		shape = "Ball",
		size = Vector3.new(0.4, 0.5, 0.75),
		offset = Vector3.new(0.48, 0.3, 0.5),
		tint = "primary",
	},
}

--[[
	Капля тьмы: горящие глаза и осколок, дышащий рядом.

	Описание общее для обеих моделей: воксельной и гранёной.
]]
local VOIDLYNX_BLOBS: { ModelPartDef } = {
	{
		shape = "Ball",
		size = Vector3.new(1.5, 1.5, 1.4),
		offset = Vector3.new(0, 1, 0),
		tint = "primary",
	},
	{
		shape = "Ball",
		size = Vector3.new(1.05, 1, 1),
		offset = Vector3.new(0, 1.72, 0.05),
		tint = "primary",
	},
	{
		shape = "Ball",
		size = Vector3.new(0.6, 0.6, 0.6),
		offset = Vector3.new(0, 2.25, 0.1),
		tint = "primary",
	},
	{
		shape = "Ball",
		size = Vector3.new(0.3, 0.34, 0.3),
		offset = Vector3.new(0, 2.6, 0.15),
		tint = "primary",
	},
	{
		shape = "Ball",
		size = Vector3.new(0.4, 0.34, 0.2),
		offset = Vector3.new(-0.32, 1.15, -0.62),
		color = "eggGem",
		neon = true,
		transparency = 0.1,
	},
	{
		shape = "Ball",
		size = Vector3.new(0.4, 0.34, 0.2),
		offset = Vector3.new(0.32, 1.15, -0.62),
		color = "eggGem",
		neon = true,
		transparency = 0.1,
	},
	{
		shape = "Ball",
		size = Vector3.new(0.26, 0.3, 0.26),
		offset = Vector3.new(-0.95, 1.95, -0.2),
		tint = "secondary",
		neon = true,
		transparency = 0.35,
		anim = "glow",
		animSpeed = 0.4,
		animAmount = 0.25,
	},
}

--[[
	Солнце: восемь лучей по кругу и лицо на диске.

	Описание общее для обеих моделей: воксельной и гранёной.
]]
local SOLARPHOENIX_BLOBS: { ModelPartDef } = {
	{
		shape = "Ball",
		size = Vector3.new(1.7, 1.7, 1.1),
		offset = Vector3.new(0, 1.35, 0),
		tint = "primary",
	},
	{
		shape = "Ball",
		size = Vector3.new(0.24, 0.26, 0.2),
		offset = Vector3.new(-0.34, 1.5, -0.5),
		tint = "dark",
	},
	{
		shape = "Ball",
		size = Vector3.new(0.24, 0.26, 0.2),
		offset = Vector3.new(0.34, 1.5, -0.5),
		tint = "dark",
	},
	{
		shape = "Ball",
		size = Vector3.new(0.3, 0.14, 0.16),
		offset = Vector3.new(0, 1.15, -0.52),
		tint = "dark",
	},
	{
		shape = "Block",
		size = Vector3.new(0.22, 0.6, 0.22),
		offset = Vector3.new(0.0, 2.4, 0),
		color = "eggAura",
		neon = true,
		angles = Vector3.new(0, 0, 0),
	},
	{
		shape = "Block",
		size = Vector3.new(0.22, 0.6, 0.22),
		offset = Vector3.new(0.74, 2.09, 0),
		color = "eggAura",
		neon = true,
		angles = Vector3.new(0, 0, -45),
	},
	{
		shape = "Block",
		size = Vector3.new(0.22, 0.6, 0.22),
		offset = Vector3.new(1.05, 1.35, 0),
		color = "eggAura",
		neon = true,
		angles = Vector3.new(0, 0, -90),
	},
	{
		shape = "Block",
		size = Vector3.new(0.22, 0.6, 0.22),
		offset = Vector3.new(0.74, 0.61, 0),
		color = "eggAura",
		neon = true,
		angles = Vector3.new(0, 0, -135),
	},
	{
		shape = "Block",
		size = Vector3.new(0.22, 0.6, 0.22),
		offset = Vector3.new(0.0, 0.3, 0),
		color = "eggAura",
		neon = true,
		angles = Vector3.new(0, 0, -180),
	},
	{
		shape = "Block",
		size = Vector3.new(0.22, 0.6, 0.22),
		offset = Vector3.new(-0.74, 0.61, 0),
		color = "eggAura",
		neon = true,
		angles = Vector3.new(0, 0, -225),
	},
	{
		shape = "Block",
		size = Vector3.new(0.22, 0.6, 0.22),
		offset = Vector3.new(-1.05, 1.35, 0),
		color = "eggAura",
		neon = true,
		angles = Vector3.new(0, 0, -270),
	},
	{
		shape = "Block",
		size = Vector3.new(0.22, 0.6, 0.22),
		offset = Vector3.new(-0.74, 2.09, 0),
		color = "eggAura",
		neon = true,
		angles = Vector3.new(0, 0, -315),
	},
}

--[[
	Олень: коричневые ноги, мшистая спина, ветвистые рога.

	Описание общее для обеих моделей: воксельной и гранёной.
]]
local VERDANTWARDEN_BLOBS: { ModelPartDef } = {
	{
		shape = "Ball",
		size = Vector3.new(1.15, 1.05, 1.9),
		offset = Vector3.new(0, 1.25, 0.15),
		tint = "dark",
	},
	{
		shape = "Ball",
		size = Vector3.new(1, 0.7, 1.3),
		offset = Vector3.new(0, 1.55, 0.2),
		tint = "primary",
	},
	{
		shape = "Ball",
		size = Vector3.new(0.7, 0.9, 0.7),
		offset = Vector3.new(0, 1.95, -0.8),
		tint = "dark",
		angles = Vector3.new(-20, 0, 0),
	},
	{
		shape = "Ball",
		size = Vector3.new(0.72, 0.7, 0.85),
		offset = Vector3.new(0, 2.5, -1.15),
		tint = "primary",
	},
	{
		shape = "Ball",
		size = Vector3.new(0.3, 0.36, 0.2),
		offset = Vector3.new(-0.4, 2.62, -1),
		tint = "dark",
	},
	{
		shape = "Ball",
		size = Vector3.new(0.3, 0.36, 0.2),
		offset = Vector3.new(0.4, 2.62, -1),
		tint = "dark",
	},
	{
		shape = "Ball",
		size = Vector3.new(0.16, 0.18, 0.12),
		offset = Vector3.new(-0.24, 2.55, -1.5),
		tint = "dark",
	},
	{
		shape = "Ball",
		size = Vector3.new(0.16, 0.18, 0.12),
		offset = Vector3.new(0.24, 2.55, -1.5),
		tint = "dark",
	},
	{
		shape = "Ball",
		size = Vector3.new(0.16, 0.7, 0.16),
		offset = Vector3.new(-0.3, 3.05, -1.05),
		color = "leather",
		angles = Vector3.new(0, 0, 18),
	},
	{
		shape = "Ball",
		size = Vector3.new(0.16, 0.7, 0.16),
		offset = Vector3.new(0.3, 3.05, -1.05),
		color = "leather",
		angles = Vector3.new(0, 0, -18),
	},
	{
		shape = "Ball",
		size = Vector3.new(0.4, 0.14, 0.14),
		offset = Vector3.new(-0.55, 3.3, -1.05),
		color = "leather",
	},
	{
		shape = "Ball",
		size = Vector3.new(0.4, 0.14, 0.14),
		offset = Vector3.new(0.55, 3.3, -1.05),
		color = "leather",
	},
	{
		shape = "Ball",
		size = Vector3.new(0.3, 1.1, 0.3),
		offset = Vector3.new(-0.45, 0.55, -0.5),
		color = "leather",
	},
	{
		shape = "Ball",
		size = Vector3.new(0.3, 1.1, 0.3),
		offset = Vector3.new(0.45, 0.55, -0.5),
		color = "leather",
	},
	{
		shape = "Ball",
		size = Vector3.new(0.3, 1.1, 0.3),
		offset = Vector3.new(-0.45, 0.55, 0.85),
		color = "leather",
	},
	{
		shape = "Ball",
		size = Vector3.new(0.3, 1.1, 0.3),
		offset = Vector3.new(0.45, 0.55, 0.85),
		color = "leather",
	},
}

local EMBER_CUB_BLOBS: { ModelPartDef } = {
	{
		shape = "Ball",
		size = Vector3.new(1.56, 1.326, 1.716),
		offset = Vector3.new(0, 0.741, 0.117),
		tint = "primary",
	},
	-- Светлое брюхо: без него зверь читается одним рыжим пятном.
	{
		shape = "Ball",
		size = Vector3.new(0.936, 0.702, 0.546),
		offset = Vector3.new(0, 0.562, -0.585),
		tint = "secondary",
	},
	{
		shape = "Ball",
		size = Vector3.new(1.17, 1.092, 1.092),
		offset = Vector3.new(0, 1.443, -0.39),
		tint = "primary",
	},
	{
		shape = "Ball",
		size = Vector3.new(0.484, 0.484, 0.328),
		offset = Vector3.new(-0.406, 1.934, -0.273),
		tint = "primary",
	},
	{
		shape = "Ball",
		size = Vector3.new(0.484, 0.484, 0.328),
		offset = Vector3.new(0.406, 1.934, -0.273),
		tint = "primary",
	},
	{
		shape = "Ball",
		size = Vector3.new(0.608, 0.468, 0.39),
		offset = Vector3.new(0, 1.295, -0.874),
		tint = "secondary",
	},
	{
		shape = "Ball",
		size = Vector3.new(0.234, 0.187, 0.187),
		offset = Vector3.new(0, 1.388, -1.03),
		tint = "dark",
	},
	{
		shape = "Ball",
		size = Vector3.new(0.203, 0.203, 0.156),
		offset = Vector3.new(-0.281, 1.599, -0.842),
		tint = "dark",
	},
	{
		shape = "Ball",
		size = Vector3.new(0.203, 0.203, 0.156),
		offset = Vector3.new(0.281, 1.599, -0.842),
		tint = "dark",
	},
	{
		shape = "Ball",
		size = Vector3.new(0.429, 0.429, 0.546),
		offset = Vector3.new(-0.468, 0.218, -0.429),
		tint = "primary",
	},
	{
		shape = "Ball",
		size = Vector3.new(0.429, 0.429, 0.546),
		offset = Vector3.new(0.468, 0.218, -0.429),
		tint = "primary",
	},
	{
		shape = "Ball",
		size = Vector3.new(0.429, 0.429, 0.546),
		offset = Vector3.new(-0.468, 0.218, 0.585),
		tint = "primary",
	},
	{
		shape = "Ball",
		size = Vector3.new(0.429, 0.429, 0.546),
		offset = Vector3.new(0.468, 0.218, 0.585),
		tint = "primary",
	},
	--[[
		Огненный хохолок. Дышит прозрачностью, а не размером: пламя
		должно мерцать, а раздувающийся шарик читается дыханием.
	]]
	{
		shape = "Ball",
		size = Vector3.new(0.39, 0.585, 0.39),
		offset = Vector3.new(0, 2.09, -0.39),
		color = "eggAura",
		neon = true,
		transparency = 0.15,
		anim = "flicker",
		animSpeed = 0.7,
		animAmount = 0.2,
	},
}

local definitions: { ModelDef } = {
	--[[
		Slime King — босс лесной поляны.

		Читаться должен как большой слизень, а не как другой зверь: полупрозрачное
		тело с тёмным ядром внутри, растёкшаяся юбка по земле и капли, которые
		качаются вразнобой. Королём его делает только корона — она же
		единственное, что не красится стихией.
	]]
	{
		key = "SlimeKing",
		parts = {
			-- Юбка задаёт пятно на полу, и её диаметр — это и есть footprint,
			-- то есть боевой радиус босса. Менять только вместе с ним.
			{
				shape = "Cylinder",
				size = Vector3.new(2.6, 20, 20),
				offset = Vector3.new(0, 1.3, 0),
				angles = Vector3.new(0, 0, 90),
				tint = "primary",
				transparency = 0.1,
			},
			{
				shape = "Ball",
				size = Vector3.new(18, 15, 18),
				offset = Vector3.new(0, 7.5, 0),
				tint = "primary",
				transparency = 0.3,
				anim = "pulse",
				animSpeed = 0.5,
				animAmount = 0.06,
			},
			-- Ядро видно сквозь тело и дышит в своём темпе. Именно рассинхрон
			-- двух пульсаций и читается как «живое», один общий выглядел бы
			-- как равномерно надувающийся шар.
			{
				shape = "Ball",
				size = Vector3.new(8, 8, 8),
				offset = Vector3.new(0, 6, 0),
				tint = "dark",
				transparency = 0.15,
				anim = "pulse",
				animSpeed = 0.33,
				animAmount = 0.1,
			},
			{
				shape = "Ball",
				size = Vector3.new(3.4, 3.4, 3.4),
				offset = Vector3.new(3.8, 9.7, -7.4),
				tint = "dark",
			},
			{
				shape = "Ball",
				size = Vector3.new(3.4, 3.4, 3.4),
				offset = Vector3.new(-3.8, 9.7, -7.4),
				tint = "dark",
			},
			{
				shape = "Cylinder",
				size = Vector3.new(1.4, 11, 11),
				offset = Vector3.new(0, 14.2, 0),
				angles = Vector3.new(0, 0, 90),
				tint = "accent",
			},
			{
				shape = "Block",
				size = Vector3.new(2.2, 4, 2.2),
				offset = Vector3.new(4.4, 16.2, 0),
				angles = Vector3.new(0, 45, 0),
				tint = "accent",
			},
			{
				shape = "Block",
				size = Vector3.new(2.2, 4, 2.2),
				offset = Vector3.new(-4.4, 16.2, 0),
				angles = Vector3.new(0, 45, 0),
				tint = "accent",
			},
			{
				shape = "Block",
				size = Vector3.new(2.2, 4, 2.2),
				offset = Vector3.new(0, 16.2, 4.4),
				angles = Vector3.new(0, 45, 0),
				tint = "accent",
			},
			{
				shape = "Block",
				size = Vector3.new(2.2, 4, 2.2),
				offset = Vector3.new(0, 16.2, -4.4),
				angles = Vector3.new(0, 45, 0),
				tint = "accent",
			},
			-- Капли качаются с разными скоростями намеренно: одинаковые
			-- выглядят как одна деталь, продублированная три раза.
			{
				shape = "Ball",
				size = Vector3.new(2.6, 2.6, 2.6),
				offset = Vector3.new(7.6, 3.2, 3.4),
				tint = "secondary",
				transparency = 0.15,
				anim = "bob",
				animSpeed = 0.7,
				animAmount = 0.7,
			},
			{
				shape = "Ball",
				size = Vector3.new(2.6, 2.6, 2.6),
				offset = Vector3.new(-6.9, 4.4, -4.2),
				tint = "secondary",
				transparency = 0.15,
				anim = "bob",
				animSpeed = 0.9,
				animAmount = 0.6,
			},
			{
				shape = "Ball",
				size = Vector3.new(2.6, 2.6, 2.6),
				offset = Vector3.new(2.4, 2.6, -7.9),
				tint = "secondary",
				transparency = 0.15,
				anim = "bob",
				animSpeed = 0.55,
				animAmount = 0.8,
			},
		},
		footprint = 0,
		height = 0,
	},

	--[[
		Goblin Shaman — босс дремучего леса. Крылатый шаман по референсу
		владельца, но без крыльев: из четырёх плоскостей крыло так и не
		сложилось, а торчащие за спиной лопасти читались мусором.

		Правки по итогам теста: весь силуэт ужат в полтора раза (высота 17
		вместо 26 — он был выше всего, что есть в игре), плечи и руки
		высушены, на маске появились красные узоры. Он колдун, а не боец,
		и мускулатура обещала не то.

		РАЗМЕР МОДЕЛИ И БОЕВОЙ РАДИУС ЕДУТ ВМЕСТЕ. Радиус в Config/Bosses
		уменьшен с 7 до 5 тем же полутора разам: пятно сверяется с ним
		при загрузке, и оставить старый радиус значило бы обещать игроку
		попадание по воздуху вокруг ужатой модели.

		Шкура красится базовым цветом из Palette.Model.bases, всё остальное —
		ручные цвета: кость маски, красный узор, кожа, сталь, перья убора.

		Не светится ничего. Глаз нет: лицо закрыто маской, и это её работа.
	]]
	{
		key = "GoblinShaman",
		parts = {
			--[[
				Ноги и ступни ходят: канал step качает их вокруг бедра на
				высоте 5 — там, где кончается нога. Ступня качается вокруг
				ТОЙ ЖЕ точки и с той же фазой, иначе отрывается от ноги.

				Правая пара сдвинута на полцикла: это и есть шаг, а не
				приседание. Цикл на 5.5 стада пути — при скорости шамана
				это чуть больше двух шагов в секунду.
			]]
			{
				shape = "Block",
				size = Vector3.new(2.3, 1.1, 3.3),
				offset = Vector3.new(-1.9, 0.55, -0.55),
				tint = "primary",
				anim = "step",
				animSpeed = 0.18,
				animAmount = 26,
				animPhase = 0,
				animPivotY = 5,
			},
			{
				shape = "Block",
				size = Vector3.new(2.3, 1.1, 3.3),
				offset = Vector3.new(1.9, 0.55, -0.55),
				tint = "primary",
				anim = "step",
				animSpeed = 0.18,
				animAmount = 26,
				animPhase = 0.5,
				animPivotY = 5,
			},
			{
				shape = "Cylinder",
				size = Vector3.new(4, 2.5, 2.5),
				offset = Vector3.new(-1.9, 2.95, 0.4),
				angles = Vector3.new(0, 0, 90),
				tint = "primary",
				anim = "step",
				animSpeed = 0.18,
				animAmount = 26,
				animPhase = 0,
				animPivotY = 5,
			},
			{
				shape = "Cylinder",
				size = Vector3.new(4, 2.5, 2.5),
				offset = Vector3.new(1.9, 2.95, 0.4),
				angles = Vector3.new(0, 0, 90),
				tint = "primary",
				anim = "step",
				animSpeed = 0.18,
				animAmount = 26,
				animPhase = 0.5,
				animPivotY = 5,
			},
			{
				shape = "Cylinder",
				size = Vector3.new(1.3, 6.3, 6.3),
				offset = Vector3.new(0, 5.1, 0),
				angles = Vector3.new(0, 0, 90),
				color = "leather",
			},
			-- Брюхо светлее спины: на референсе оно почти жёлтое, и без этой
			-- разницы туша складывается в одно пятно.
			{
				shape = "Ball",
				size = Vector3.new(5.6, 4.4, 5),
				offset = Vector3.new(0, 6.4, -0.15),
				tint = "secondary",
			},
			-- Грудь у́же брюха, а не шире: у колдуна верх должен быть сухим,
			-- иначе силуэт обещает драку врукопашную.
			{
				shape = "Ball",
				size = Vector3.new(6, 4.7, 5.2),
				offset = Vector3.new(0, 8.7, 0.25),
				tint = "primary",
			},
			{
				shape = "Ball",
				size = Vector3.new(2.8, 2.8, 2.8),
				offset = Vector3.new(-2.8, 10.1, 0.4),
				tint = "primary",
			},
			{
				shape = "Ball",
				size = Vector3.new(2.8, 2.8, 2.8),
				offset = Vector3.new(2.8, 10.1, 0.4),
				tint = "primary",
			},
			-- Обе руки подняты, как на референсе. Угол почти вертикальный
			-- не для красоты: разведённые в стороны руки вылезают за пятно.
			{
				shape = "Cylinder",
				size = Vector3.new(5, 1.6, 1.6),
				offset = Vector3.new(-3, 11.7, -0.4),
				angles = Vector3.new(0, 0, 70),
				tint = "primary",
			},
			{
				shape = "Cylinder",
				size = Vector3.new(5, 1.6, 1.6),
				offset = Vector3.new(3, 11.7, -0.4),
				angles = Vector3.new(0, 0, -70),
				tint = "primary",
			},
			{
				shape = "Ball",
				size = Vector3.new(3.6, 3.5, 3.6),
				offset = Vector3.new(0, 11.9, -0.65),
				tint = "primary",
			},
			-- Маска и есть лицо. Она плоская и светлая, поэтому читается
			-- с любого расстояния — в отличие от глаз, которых тут нет.
			{
				shape = "Block",
				size = Vector3.new(2.9, 3.1, 0.9),
				offset = Vector3.new(0, 11.9, -2.25),
				color = "bone",
			},
			--[[
				Узор на маске: две косые полосы и черта под ними. Лежит
				поверх маски отдельными деталями — рисовать по поверхности
				нечем, текстур в игре нет вовсе.
			]]
			{
				shape = "Block",
				size = Vector3.new(0.35, 1.6, 0.15),
				offset = Vector3.new(-0.65, 12.3, -2.75),
				angles = Vector3.new(0, 0, 25),
				color = "plumeRed",
			},
			{
				shape = "Block",
				size = Vector3.new(0.35, 1.6, 0.15),
				offset = Vector3.new(0.65, 12.3, -2.75),
				angles = Vector3.new(0, 0, -25),
				color = "plumeRed",
			},
			{
				shape = "Block",
				size = Vector3.new(2.1, 0.3, 0.15),
				offset = Vector3.new(0, 11.1, -2.75),
				color = "plumeRed",
			},
			-- Убор: пять перьев веером, все разного цвета и наклона.
			{
				shape = "Block",
				size = Vector3.new(0.75, 4.3, 0.2),
				offset = Vector3.new(0, 15.1, -0.95),
				color = "plumeWarm",
			},
			{
				shape = "Block",
				size = Vector3.new(0.75, 4, 0.2),
				offset = Vector3.new(-1.25, 14.8, -1),
				angles = Vector3.new(0, 0, 13),
				color = "plumeCool",
			},
			{
				shape = "Block",
				size = Vector3.new(0.75, 4, 0.2),
				offset = Vector3.new(1.25, 14.8, -1),
				angles = Vector3.new(0, 0, -13),
				color = "plumeRed",
			},
			{
				shape = "Block",
				size = Vector3.new(0.7, 3.5, 0.2),
				offset = Vector3.new(-2.3, 14.3, -1.05),
				angles = Vector3.new(0, 0, 27),
				color = "plumeTeal",
			},
			{
				shape = "Block",
				size = Vector3.new(0.7, 3.5, 0.2),
				offset = Vector3.new(2.3, 14.3, -1.05),
				angles = Vector3.new(0, 0, -27),
				color = "plumeWarm",
			},
			{
				shape = "Cylinder",
				size = Vector3.new(6.7, 0.55, 0.55),
				offset = Vector3.new(-4, 12.3, -0.4),
				angles = Vector3.new(0, 0, 90),
				color = "leather",
			},
			{
				shape = "Ball",
				size = Vector3.new(1.7, 1.6, 1.7),
				offset = Vector3.new(-4, 16, -0.4),
				color = "bone",
			},
			{
				shape = "Block",
				mesh = "Wedge",
				size = Vector3.new(0.67, 3.7, 0.4),
				offset = Vector3.new(4.3, 14.3, -0.8),
				angles = Vector3.new(0, 0, -20),
				color = "steel",
			},
			-- Кисти оберега под маской: на референсе их видно первыми,
			-- потому что они единственное яркое пятно на груди.
			{
				shape = "Block",
				size = Vector3.new(1.6, 2, 0.35),
				offset = Vector3.new(0, 9.1, -2.8),
				color = "plumeRed",
			},
		},
		footprint = 0,
		height = 0,
	},
}

--[[
		EmberCub — питомец, по иконке assets/icons/pets/pet_ember_cub.png.

		ЗАЧЕМ ПИТОМЦАМ МОДЕЛИ ЗДЕСЬ, А НЕ В Config/Props. Это существо, а не
		предмет: правила у него те же, что у босса, — деталь называет роль
		цвета, а красит её базовый цвет из Palette.Model.bases.

		ОПИСАНИЕ ОДНО, МОДЕЛИ ДВЕ. Ниже лежит форма зверя эллипсоидами; из неё
		получаются и воксельный медвежонок (EmberCub), и гранёный (EmberCubLite).
		Второй — не черновик, а рабочий вариант для ЧУЖИХ питомцев: своего игрок
		видит вблизи и подробным, а в лобби их на экране столько, сколько
		игроков на сервере. Воксельный стоит 115 деталей, гранёный — 14,
		и на двадцати игроках это разница между 2300 и 280.

		Хохолок — единственное, что светится, и он мерцает: по нему питомец
		читается огненным, не перекрашивая рыжую шкуру. Растеризация переносит
		и свечение, и мерцание — воксели наследуют их у своей детали.
	]]
table.insert(definitions, {
	key = "EmberCub",
	parts = voxelise(EMBER_CUB_BLOBS, PET_VOXEL),
	footprint = 0,
	height = 0,
})

table.insert(definitions, {
	key = "EmberCubLite",
	parts = EMBER_CUB_BLOBS,
	footprint = 0,
	height = 0,
})

--[[
	Упрощённый вариант модели: чем рисовать чужого питомца, когда подробным
	его рисовать дорого. Ключ без записи здесь упрощённого варианта не имеет
	и рисуется как есть.
]]
Models.Lite = {
	EmberCub = "EmberCubLite",
	FrostPup = "FrostPupLite",
	MossSprout = "MossSproutLite",
	SparkKit = "SparkKitLite",
	DuskMoth = "DuskMothLite",
	GlowFinch = "GlowFinchLite",
	MagmaHound = "MagmaHoundLite",
	GlacierOwl = "GlacierOwlLite",
	StormDrake = "StormDrakeLite",
	VoidLynx = "VoidLynxLite",
	SolarPhoenix = "SolarPhoenixLite",
	VerdantWarden = "VerdantWardenLite",
} :: { [string]: string }

table.insert(definitions, {
	key = "FrostPup",
	parts = voxelise(FROSTPUP_BLOBS, PET_VOXEL),
	footprint = 0,
	height = 0,
})

table.insert(definitions, {
	key = "FrostPupLite",
	parts = FROSTPUP_BLOBS,
	footprint = 0,
	height = 0,
})

table.insert(definitions, {
	key = "MossSprout",
	parts = voxelise(MOSSSPROUT_BLOBS, PET_VOXEL),
	footprint = 0,
	height = 0,
})

table.insert(definitions, {
	key = "MossSproutLite",
	parts = MOSSSPROUT_BLOBS,
	footprint = 0,
	height = 0,
})

table.insert(definitions, {
	key = "SparkKit",
	parts = voxelise(SPARKKIT_BLOBS, PET_VOXEL),
	footprint = 0,
	height = 0,
})

table.insert(definitions, {
	key = "SparkKitLite",
	parts = SPARKKIT_BLOBS,
	footprint = 0,
	height = 0,
})

table.insert(definitions, {
	key = "DuskMoth",
	parts = voxelise(DUSKMOTH_BLOBS, PET_VOXEL),
	footprint = 0,
	height = 0,
})

table.insert(definitions, {
	key = "DuskMothLite",
	parts = DUSKMOTH_BLOBS,
	footprint = 0,
	height = 0,
})

table.insert(definitions, {
	key = "GlowFinch",
	parts = voxelise(GLOWFINCH_BLOBS, PET_VOXEL),
	footprint = 0,
	height = 0,
})

table.insert(definitions, {
	key = "GlowFinchLite",
	parts = GLOWFINCH_BLOBS,
	footprint = 0,
	height = 0,
})

table.insert(definitions, {
	key = "MagmaHound",
	parts = voxelise(MAGMAHOUND_BLOBS, PET_VOXEL),
	footprint = 0,
	height = 0,
})

table.insert(definitions, {
	key = "MagmaHoundLite",
	parts = MAGMAHOUND_BLOBS,
	footprint = 0,
	height = 0,
})

table.insert(definitions, {
	key = "GlacierOwl",
	parts = voxelise(GLACIEROWL_BLOBS, PET_VOXEL),
	footprint = 0,
	height = 0,
})

table.insert(definitions, {
	key = "GlacierOwlLite",
	parts = GLACIEROWL_BLOBS,
	footprint = 0,
	height = 0,
})

table.insert(definitions, {
	key = "StormDrake",
	parts = voxelise(STORMDRAKE_BLOBS, PET_VOXEL),
	footprint = 0,
	height = 0,
})

table.insert(definitions, {
	key = "StormDrakeLite",
	parts = STORMDRAKE_BLOBS,
	footprint = 0,
	height = 0,
})

table.insert(definitions, {
	key = "VoidLynx",
	parts = voxelise(VOIDLYNX_BLOBS, PET_VOXEL),
	footprint = 0,
	height = 0,
})

table.insert(definitions, {
	key = "VoidLynxLite",
	parts = VOIDLYNX_BLOBS,
	footprint = 0,
	height = 0,
})

table.insert(definitions, {
	key = "SolarPhoenix",
	parts = voxelise(SOLARPHOENIX_BLOBS, PET_VOXEL),
	footprint = 0,
	height = 0,
})

table.insert(definitions, {
	key = "SolarPhoenixLite",
	parts = SOLARPHOENIX_BLOBS,
	footprint = 0,
	height = 0,
})

table.insert(definitions, {
	key = "VerdantWarden",
	parts = voxelise(VERDANTWARDEN_BLOBS, PET_VOXEL),
	footprint = 0,
	height = 0,
})

table.insert(definitions, {
	key = "VerdantWardenLite",
	parts = VERDANTWARDEN_BLOBS,
	footprint = 0,
	height = 0,
})

--[[
	ТЕЛА СПОСОБНОСТЕЙ (приставка Fx).

	Отличаются от всего остального в этом файле двумя вещами.

	Первое: их не растеризует voxelise. Огонёк из семи кубиков и так выглядит
	воксельным — кубики и есть воксели, — а прогнанный через сетку шар даёт
	полсотни деталей на объект, которых на арене бывает пятнадцать разом.
	Растеризатор нужен там, где форму задают шары и её надо огранить; здесь
	форму сразу задают коробки.

	Второе: потолок деталей свой, MAX_FX_PARTS вместо двухсот. Орбов на девятом
	уровне пять, орбитальных способностей три, и это ещё до снарядов: цена тела
	умножается на пятнадцать, а цена питомца — на один.

	Модель по-прежнему стоит на полу: offset отсчитывается от Y = 0, и загрузчик
	ловит деталь, ушедшую под него. Орб висит в воздухе, поэтому форма ставит
	пивот на половину высоты ниже центра орба — см. FxForms.
]]

--[[
	Огненный орб (FireOrbit): воксельный огонёк.

	Ядро неподвижно, а языки пламени облетают его вокруг оси модели (канал
	spin поворачивает деталь ВОКРУГ оси, а не вокруг себя). Отсюда и берётся
	вращение: сам орб уже едет по орбите вокруг игрока, и второе вращение,
	наложенное на первое, читается как живой огонь, а не как крутящийся кубик.
]]
table.insert(definitions, {
	key = "FxFireOrbit",
	parts = {
		-- Внешний ореол: дышит прозрачностью и потому в BulkMoveTo не попадает.
		{
			shape = "Block",
			size = Vector3.new(1.32, 1.32, 1.32),
			offset = Vector3.new(0, 0.86, 0),
			tint = "primary",
			neon = true,
			transparency = 0.62,
			anim = "glow",
			animSpeed = 1.6,
			animAmount = 0.22,
		},
		--[[
			Ядро несёт хвост. Орб идёт по орбите радиусом 8 со скоростью около
			трёх радиан в секунду, то есть примерно 24 стада в секунду: за
			0.4 с лента растягивается на треть окружности, и вращение читается
			даже когда сам орб скрыт за игроком.
		]]
		{
			shape = "Block",
			size = Vector3.new(0.94, 0.94, 0.94),
			offset = Vector3.new(0, 0.86, 0),
			tint = "primary",
			neon = true,
			trail = {
				length = 0.8,
				lifetime = 0.4,
				tint = "accent",
				tailTint = "primary",
				transparency = 0.15,
			},
		},
		--[[
			Жёлтое ядро — тот самый второй цвет стихии (Palette.ElementAccent).
			Оно же сыплет искры: они принадлежат самой горячей точке огонька,
			а не его краю.
		]]
		{
			shape = "Block",
			size = Vector3.new(0.5, 0.58, 0.5),
			offset = Vector3.new(0, 0.94, 0),
			tint = "accent",
			neon = true,
			particles = {
				rate = 9,
				size = 0.42,
				speed = 2.2,
				lifetime = 0.55,
				spread = 18,
				-- Искры всплывают, а не разлетаются шаром: огонь тянет вверх.
				rise = 5,
				tint = "accent",
			},
		},
		--[[
			Языки пламени вынесены на поверхность ореола (радиус 0.66 равен его
			полуразмеру): внутри они утонули бы в его свечении, и вращение,
			ради которого всё и затевалось, перестало бы читаться.
		]]
		{
			shape = "Block",
			size = Vector3.new(0.3, 0.46, 0.3),
			offset = Vector3.new(0.66, 1.02, 0),
			tint = "accent",
			neon = true,
			anim = "spin",
			animSpeed = 1.1,
		},
		{
			shape = "Block",
			size = Vector3.new(0.3, 0.46, 0.3),
			offset = Vector3.new(-0.33, 0.7, 0.57),
			tint = "primary",
			neon = true,
			anim = "spin",
			animSpeed = 1.1,
		},
		{
			shape = "Block",
			size = Vector3.new(0.3, 0.46, 0.3),
			offset = Vector3.new(-0.33, 1.18, -0.57),
			tint = "primary",
			neon = true,
			anim = "spin",
			animSpeed = 1.1,
		},
		-- Искра над огоньком: летит быстрее языков и в другую сторону.
		{
			shape = "Block",
			size = Vector3.new(0.2, 0.2, 0.2),
			offset = Vector3.new(0.34, 1.52, -0.34),
			tint = "accent",
			neon = true,
			anim = "spin",
			animSpeed = -1.9,
		},
	},
	footprint = 0,
	height = 0,
})

--[[
	Мотылёк света (MoteHalo): та же орбита, что у огненного орба, и потому
	нарочно другой силуэт. Огонёк — сгусток с языками наружу, мотылёк —
	мелкое ядро с искрами-спутниками: одинаковый ход по кругу обязан
	читаться разными вещами.
]]
table.insert(definitions, {
	key = "FxMoteHalo",
	parts = {
		{
			shape = "Block",
			size = Vector3.new(1, 1, 1),
			offset = Vector3.new(0, 0.55, 0),
			tint = "secondary",
			neon = true,
			transparency = 0.6,
			anim = "glow",
			animSpeed = 2.2,
			animAmount = 0.25,
		},
		{
			shape = "Block",
			size = Vector3.new(0.62, 0.62, 0.62),
			offset = Vector3.new(0, 0.55, 0),
			tint = "primary",
			neon = true,
			trail = { length = 0.55, lifetime = 0.3, tint = "accent", tailTint = "primary", transparency = 0.2 },
			particles = { rate = 6, size = 0.3, speed = 1.6, lifetime = 0.5, spread = 25, rise = 2, tint = "accent" },
		},
		{
			shape = "Block",
			size = Vector3.new(0.2, 0.2, 0.2),
			offset = Vector3.new(0.5, 0.72, 0),
			tint = "accent",
			neon = true,
			anim = "spin",
			animSpeed = 1.8,
		},
		{
			shape = "Block",
			size = Vector3.new(0.2, 0.2, 0.2),
			offset = Vector3.new(-0.35, 0.4, 0.36),
			tint = "accent",
			neon = true,
			anim = "spin",
			animSpeed = 1.8,
		},
		{
			shape = "Block",
			size = Vector3.new(0.16, 0.16, 0.16),
			offset = Vector3.new(0, 0.9, -0.45),
			tint = "secondary",
			neon = true,
			anim = "spin",
			animSpeed = -2.4,
		},
	},
	footprint = 0,
	height = 0,
})

--[[
	Клыки пустоты (VoidFangs): мини-чёрная дыра.

	Ядро НЕ неоновое — единственное такое тело во всём наборе. Тьма, которая
	светится, перестаёт быть тьмой; свечение отдано ореолу и осколкам, летящим
	по кольцу вокруг ядра.
]]
table.insert(definitions, {
	key = "FxVoidFangs",
	parts = {
		{
			shape = "Block",
			size = Vector3.new(1.15, 1.15, 1.15),
			offset = Vector3.new(0, 0.62, 0),
			tint = "primary",
			neon = true,
			transparency = 0.55,
			anim = "glow",
			animSpeed = 1.4,
			animAmount = 0.2,
		},
		{
			shape = "Block",
			size = Vector3.new(0.66, 0.66, 0.66),
			offset = Vector3.new(0, 0.62, 0),
			tint = "dark",
			trail = { length = 0.7, lifetime = 0.35, tint = "accent", tailTint = "dark", transparency = 0.25 },
			particles = { rate = 5, size = 0.34, speed = 1.2, lifetime = 0.5, spread = 40, rise = 0.5, tint = "accent" },
		},
		{
			shape = "Block",
			size = Vector3.new(0.34, 0.12, 0.16),
			offset = Vector3.new(0.62, 0.62, 0),
			tint = "accent",
			neon = true,
			anim = "spin",
			animSpeed = 1.6,
		},
		{
			shape = "Block",
			size = Vector3.new(0.34, 0.12, 0.16),
			offset = Vector3.new(-0.62, 0.62, 0),
			tint = "accent",
			neon = true,
			anim = "spin",
			animSpeed = 1.6,
		},
		{
			shape = "Block",
			size = Vector3.new(0.16, 0.12, 0.34),
			offset = Vector3.new(0, 0.62, 0.62),
			tint = "secondary",
			neon = true,
			anim = "spin",
			animSpeed = 1.6,
		},
		{
			shape = "Block",
			size = Vector3.new(0.16, 0.12, 0.34),
			offset = Vector3.new(0, 0.62, -0.62),
			tint = "secondary",
			neon = true,
			anim = "spin",
			animSpeed = 1.6,
		},
	},
	footprint = 0,
	height = 0,
})

--[[
	СНАРЯДЫ. Перёд модели — в сторону -Z (как у CFrame.lookAt), поэтому длинная
	ось лежит по Z: форма разворачивает тело по вектору полёта, и остриё обязано
	смотреть вперёд, а не вбок.

	Лента у снаряда короче, чем у орба: он летит по прямой, и длинный хвост
	превращается в неподвижную палку позади — ровно в то, чем снаряды и были
	до сих пор.
]]
table.insert(definitions, {
	key = "FxIceShard",
	parts = {
		{
			shape = "Block",
			size = Vector3.new(0.34, 0.34, 1.25),
			offset = Vector3.new(0, 0.5, 0),
			tint = "primary",
			neon = true,
			trail = { length = 0.55, lifetime = 0.28, tint = "accent", tailTint = "primary", transparency = 0.2 },
			particles = { rate = 5, size = 0.26, speed = 1.4, lifetime = 0.4, spread = 30, tint = "secondary" },
		},
		{
			shape = "Block",
			size = Vector3.new(0.18, 0.18, 0.4),
			offset = Vector3.new(0, 0.5, -0.75),
			tint = "accent",
			neon = true,
		},
		{
			shape = "Block",
			size = Vector3.new(0.14, 0.4, 0.5),
			offset = Vector3.new(0.22, 0.52, 0.2),
			tint = "secondary",
			neon = true,
		},
		{
			shape = "Block",
			size = Vector3.new(0.14, 0.4, 0.5),
			offset = Vector3.new(-0.22, 0.52, 0.2),
			tint = "secondary",
			neon = true,
		},
		{
			shape = "Block",
			size = Vector3.new(0.26, 0.26, 0.26),
			offset = Vector3.new(0, 0.5, 0.68),
			tint = "accent",
			neon = true,
			anim = "glow",
			animSpeed = 3,
			animAmount = 0.3,
		},
	},
	footprint = 0,
	height = 0,
})

--[[
	Игла тьмы: тоньше и длиннее ледяного осколка втрое.

	Их бывает восемь разом (два базовых плюс два за каждый рубеж), поэтому
	деталей меньше всех и искр нет вовсе: восемь потоков частиц на экране —
	это уже не залп, а туман.
]]
table.insert(definitions, {
	key = "FxShadowNeedle",
	parts = {
		{
			shape = "Block",
			size = Vector3.new(0.2, 0.2, 1),
			offset = Vector3.new(0, 0.4, 0),
			tint = "primary",
			neon = true,
			trail = { length = 0.4, lifetime = 0.3, tint = "accent", tailTint = "primary", transparency = 0.25 },
		},
		{
			shape = "Block",
			size = Vector3.new(0.12, 0.12, 0.34),
			offset = Vector3.new(0, 0.4, -0.62),
			tint = "accent",
			neon = true,
		},
		{
			shape = "Block",
			size = Vector3.new(0.1, 0.24, 0.2),
			offset = Vector3.new(0.14, 0.42, 0.3),
			tint = "dark",
		},
		{
			shape = "Block",
			size = Vector3.new(0.1, 0.24, 0.2),
			offset = Vector3.new(-0.14, 0.42, 0.3),
			tint = "dark",
		},
		{
			shape = "Block",
			size = Vector3.new(0.16, 0.16, 0.16),
			offset = Vector3.new(0, 0.4, 0.55),
			tint = "accent",
			neon = true,
			anim = "glow",
			animSpeed = 4,
			animAmount = 0.35,
		},
	},
	footprint = 0,
	height = 0,
})

--[[
	Семя: единственный снаряд, который не светится целиком. Природа — это
	плотная вещь с живыми листьями, а не сгусток энергии, и листья крутятся
	вокруг оси полёта.
]]
table.insert(definitions, {
	key = "FxSeedVolley",
	parts = {
		{
			shape = "Block",
			size = Vector3.new(0.46, 0.5, 0.6),
			offset = Vector3.new(0, 0.4, 0),
			tint = "primary",
			trail = { length = 0.42, lifetime = 0.25, tint = "accent", tailTint = "primary", transparency = 0.3 },
			particles = { rate = 4, size = 0.24, speed = 1.2, lifetime = 0.45, spread = 35, tint = "accent" },
		},
		{
			shape = "Block",
			size = Vector3.new(0.24, 0.24, 0.24),
			offset = Vector3.new(0, 0.4, -0.3),
			tint = "accent",
			neon = true,
		},
		{
			shape = "Block",
			size = Vector3.new(0.3, 0.08, 0.34),
			offset = Vector3.new(0.3, 0.5, 0.16),
			tint = "secondary",
			anim = "spin",
			animSpeed = 2.2,
		},
		{
			shape = "Block",
			size = Vector3.new(0.3, 0.08, 0.34),
			offset = Vector3.new(-0.3, 0.5, 0.16),
			tint = "secondary",
			anim = "spin",
			animSpeed = 2.2,
		},
		{
			shape = "Block",
			size = Vector3.new(0.14, 0.14, 0.14),
			offset = Vector3.new(0, 0.62, 0.3),
			tint = "accent",
			neon = true,
			anim = "glow",
			animSpeed = 3,
			animAmount = 0.3,
		},
	},
	footprint = 0,
	height = 0,
})

--[[
	АУРЫ. Тело здесь — не сама аура, а украшение на её кольце: четыре штуки
	медленно едут по краю радиуса, показывая границу области.

	Ленты у них нет намеренно. Кольцо и так очерчено диском на полу, а четыре
	ленты, идущие по одной окружности, слились бы в неё же — только дороже.
]]
table.insert(definitions, {
	key = "FxThornAura",
	parts = {
		{
			shape = "Block",
			size = Vector3.new(0.42, 0.34, 0.42),
			offset = Vector3.new(0, 0.17, 0),
			tint = "dark",
		},
		{
			shape = "Block",
			size = Vector3.new(0.26, 0.62, 0.26),
			offset = Vector3.new(0, 0.62, 0),
			tint = "primary",
			anim = "bob",
			animSpeed = 0.9,
			animAmount = 0.06,
		},
		{
			shape = "Block",
			size = Vector3.new(0.12, 0.3, 0.12),
			offset = Vector3.new(0, 1.05, 0),
			tint = "accent",
			neon = true,
		},
		{
			shape = "Block",
			size = Vector3.new(0.3, 0.1, 0.16),
			offset = Vector3.new(0.24, 0.45, 0),
			tint = "secondary",
		},
		{
			shape = "Block",
			size = Vector3.new(0.3, 0.1, 0.16),
			offset = Vector3.new(-0.24, 0.6, 0.1),
			tint = "secondary",
		},
	},
	footprint = 0,
	height = 0,
})

table.insert(definitions, {
	key = "FxEmberTrail",
	parts = {
		{
			shape = "Block",
			size = Vector3.new(0.44, 0.44, 0.44),
			offset = Vector3.new(0, 0.28, 0),
			tint = "primary",
			neon = true,
			anim = "glow",
			animSpeed = 1.8,
			animAmount = 0.2,
		},
		{
			shape = "Block",
			size = Vector3.new(0.24, 0.24, 0.24),
			offset = Vector3.new(0, 0.34, 0),
			tint = "accent",
			neon = true,
			particles = { rate = 5, size = 0.28, speed = 1.6, lifetime = 0.5, spread = 20, rise = 4, tint = "accent" },
		},
		{
			shape = "Block",
			size = Vector3.new(0.2, 0.4, 0.2),
			offset = Vector3.new(0, 0.62, 0),
			tint = "accent",
			neon = true,
			anim = "bob",
			animSpeed = 1.6,
			animAmount = 0.08,
		},
		{
			shape = "Block",
			size = Vector3.new(0.12, 0.12, 0.12),
			offset = Vector3.new(0.2, 0.75, -0.1),
			tint = "accent",
			neon = true,
			anim = "spin",
			animSpeed = 2,
		},
	},
	footprint = 0,
	height = 0,
})

--[[
	ВСПЫШКИ (Nova). Тело стоит НА ПОЛУ в центре вспышки и живёт треть секунды,
	пока расходится круг. Пивот ему не опускают — в отличие от орба, столб
	бьёт из земли, а не висит в воздухе.

	Искры у всех трёх щедрые: тело видно доли секунды, и весь его смысл —
	объяснить, откуда взялся круг.
]]
table.insert(definitions, {
	key = "FxStormNova",
	parts = {
		{
			shape = "Block",
			size = Vector3.new(0.95, 3.2, 0.95),
			offset = Vector3.new(0, 1.6, 0),
			tint = "primary",
			neon = true,
			transparency = 0.6,
			anim = "glow",
			animSpeed = 3,
			animAmount = 0.3,
		},
		{
			shape = "Block",
			size = Vector3.new(0.55, 3, 0.55),
			offset = Vector3.new(0, 1.5, 0),
			tint = "accent",
			neon = true,
			anim = "flicker",
			animSpeed = 6,
			animAmount = 0.35,
			particles = { rate = 20, size = 0.35, speed = 5, lifetime = 0.4, spread = 60, rise = 6, tint = "accent" },
		},
		{
			shape = "Block",
			size = Vector3.new(0.22, 1.2, 0.22),
			offset = Vector3.new(0.5, 0.9, 0.2),
			tint = "primary",
			neon = true,
			anim = "spin",
			animSpeed = 1.4,
		},
		{
			shape = "Block",
			size = Vector3.new(0.22, 1, 0.22),
			offset = Vector3.new(-0.45, 1.6, -0.25),
			tint = "primary",
			neon = true,
			anim = "spin",
			animSpeed = 1.4,
		},
		{
			shape = "Block",
			size = Vector3.new(1.6, 0.16, 1.6),
			offset = Vector3.new(0, 0.08, 0),
			tint = "accent",
			neon = true,
			transparency = 0.35,
		},
	},
	footprint = 0,
	height = 0,
})

table.insert(definitions, {
	key = "FxLightBurst",
	parts = {
		{
			shape = "Block",
			size = Vector3.new(1.6, 1.6, 1.6),
			offset = Vector3.new(0, 1.2, 0),
			tint = "primary",
			neon = true,
			transparency = 0.65,
			anim = "glow",
			animSpeed = 2.5,
			animAmount = 0.25,
		},
		{
			shape = "Block",
			size = Vector3.new(0.8, 0.8, 0.8),
			offset = Vector3.new(0, 1.2, 0),
			tint = "accent",
			neon = true,
			anim = "glow",
			animSpeed = 4,
			animAmount = 0.25,
			particles = { rate = 24, size = 0.32, speed = 6, lifetime = 0.35, spread = 70, tint = "accent" },
		},
		{
			shape = "Block",
			size = Vector3.new(1.4, 0.18, 0.18),
			offset = Vector3.new(0.9, 1.2, 0),
			tint = "primary",
			neon = true,
		},
		{
			shape = "Block",
			size = Vector3.new(1.4, 0.18, 0.18),
			offset = Vector3.new(-0.9, 1.2, 0),
			tint = "primary",
			neon = true,
		},
		{
			shape = "Block",
			size = Vector3.new(0.18, 0.18, 1.4),
			offset = Vector3.new(0, 1.2, 0.9),
			tint = "primary",
			neon = true,
		},
		{
			shape = "Block",
			size = Vector3.new(0.18, 0.18, 1.4),
			offset = Vector3.new(0, 1.2, -0.9),
			tint = "primary",
			neon = true,
		},
		{
			shape = "Block",
			size = Vector3.new(0.18, 1.4, 0.18),
			offset = Vector3.new(0, 1.2, 0),
			tint = "secondary",
			neon = true,
		},
	},
	footprint = 0,
	height = 0,
})

table.insert(definitions, {
	key = "FxFrostBurst",
	parts = {
		{
			shape = "Block",
			size = Vector3.new(0.5, 2.2, 0.5),
			offset = Vector3.new(0, 1.1, 0),
			tint = "primary",
			neon = true,
			particles = { rate = 18, size = 0.3, speed = 4, lifetime = 0.45, spread = 55, rise = 2, tint = "secondary" },
		},
		{
			shape = "Block",
			size = Vector3.new(0.34, 1.4, 0.34),
			offset = Vector3.new(0.5, 0.7, 0.2),
			tint = "secondary",
			neon = true,
		},
		{
			shape = "Block",
			size = Vector3.new(0.3, 1.1, 0.3),
			offset = Vector3.new(-0.45, 0.55, -0.25),
			tint = "secondary",
			neon = true,
		},
		{
			shape = "Block",
			size = Vector3.new(0.26, 0.26, 0.26),
			offset = Vector3.new(0, 2.25, 0),
			tint = "accent",
			neon = true,
			anim = "glow",
			animSpeed = 2.5,
			animAmount = 0.3,
		},
		{
			shape = "Block",
			size = Vector3.new(1.5, 0.14, 1.5),
			offset = Vector3.new(0, 0.07, 0),
			tint = "accent",
			neon = true,
			transparency = 0.45,
		},
	},
	footprint = 0,
	height = 0,
})

--[[
	КЛИНЬЯ (Cone). Тело лежит горизонтально и смотрит туда же, куда бьёт удар:
	перёд — в сторону -Z, поэтому длина набирается по Z, а ширина по X.

	Полосы, из которых собран сам клин, никуда не делись: тело показывает,
	чем ударили, а полосы — по какой площади.
]]
table.insert(definitions, {
	key = "FxWingGust",
	parts = {
		{
			shape = "Block",
			size = Vector3.new(2.2, 0.16, 0.9),
			offset = Vector3.new(0, 1, -0.5),
			tint = "primary",
			neon = true,
			transparency = 0.35,
		},
		{
			shape = "Block",
			size = Vector3.new(2.6, 0.1, 0.3),
			offset = Vector3.new(0, 1, -1.1),
			tint = "accent",
			neon = true,
			transparency = 0.25,
			particles = { rate = 22, size = 0.34, speed = 5, lifetime = 0.4, spread = 45, tint = "accent" },
		},
		{
			shape = "Block",
			size = Vector3.new(0.5, 0.12, 0.7),
			offset = Vector3.new(1, 1, -0.2),
			tint = "dark",
		},
		{
			shape = "Block",
			size = Vector3.new(0.5, 0.12, 0.7),
			offset = Vector3.new(-1, 1, -0.2),
			tint = "dark",
		},
		{
			shape = "Block",
			size = Vector3.new(0.3, 0.3, 0.3),
			offset = Vector3.new(0, 1.1, -1.5),
			tint = "accent",
			neon = true,
			anim = "spin",
			animSpeed = 2.5,
		},
	},
	footprint = 0,
	height = 0,
})

table.insert(definitions, {
	key = "FxSolarFlare",
	parts = {
		{
			shape = "Block",
			size = Vector3.new(0.3, 0.14, 2.2),
			offset = Vector3.new(0, 1, -1.1),
			tint = "accent",
			neon = true,
		},
		{
			shape = "Block",
			size = Vector3.new(0.24, 0.12, 1.8),
			offset = Vector3.new(0.55, 1, -0.95),
			tint = "primary",
			neon = true,
		},
		{
			shape = "Block",
			size = Vector3.new(0.24, 0.12, 1.8),
			offset = Vector3.new(-0.55, 1, -0.95),
			tint = "primary",
			neon = true,
		},
		{
			shape = "Block",
			size = Vector3.new(0.18, 0.1, 1.3),
			offset = Vector3.new(1, 1, -0.75),
			tint = "secondary",
			neon = true,
			transparency = 0.2,
		},
		{
			shape = "Block",
			size = Vector3.new(0.18, 0.1, 1.3),
			offset = Vector3.new(-1, 1, -0.75),
			tint = "secondary",
			neon = true,
			transparency = 0.2,
		},
		{
			shape = "Block",
			size = Vector3.new(0.5, 0.3, 0.5),
			offset = Vector3.new(0, 1, 0),
			tint = "accent",
			neon = true,
			anim = "glow",
			animSpeed = 3,
			animAmount = 0.3,
			particles = { rate = 20, size = 0.3, speed = 5, lifetime = 0.4, spread = 50, tint = "accent" },
		},
	},
	footprint = 0,
	height = 0,
})

--[[
	ЦЕПИ. Тело — узел на КАЖДОМ враге, куда прыгнула молния, а сама дуга между
	узлами рисуется лентой Beam (см. FxForms). Узлов бывает до семи за
	срабатывание, живут они те же 0.22 секунды, что и дуга.

	Обе цепные способности — молнии, поэтому различать их приходится не цветом,
	а размером и повадкой: искра мелкая и суетливая, дуга крупная и с вертикалью.
]]
table.insert(definitions, {
	key = "FxChainSpark",
	parts = {
		{
			shape = "Block",
			size = Vector3.new(0.4, 0.4, 0.4),
			offset = Vector3.new(0, 1.6, 0),
			tint = "accent",
			neon = true,
			anim = "glow",
			animSpeed = 5,
			animAmount = 0.3,
			particles = { rate = 14, size = 0.28, speed = 3, lifetime = 0.3, spread = 80, tint = "accent" },
		},
		{
			shape = "Block",
			size = Vector3.new(0.14, 0.9, 0.14),
			offset = Vector3.new(0, 1.6, 0),
			tint = "primary",
			neon = true,
		},
		{
			shape = "Block",
			size = Vector3.new(0.9, 0.14, 0.14),
			offset = Vector3.new(0, 1.6, 0),
			tint = "primary",
			neon = true,
		},
		{
			shape = "Block",
			size = Vector3.new(0.16, 0.16, 0.16),
			offset = Vector3.new(0.42, 1.85, 0.15),
			tint = "accent",
			neon = true,
			anim = "spin",
			animSpeed = 3,
		},
		{
			shape = "Block",
			size = Vector3.new(0.14, 0.14, 0.14),
			offset = Vector3.new(-0.38, 1.35, -0.2),
			tint = "accent",
			neon = true,
			anim = "spin",
			animSpeed = -3,
		},
	},
	footprint = 0,
	height = 0,
})

table.insert(definitions, {
	key = "FxStormArc",
	parts = {
		{
			shape = "Block",
			size = Vector3.new(1, 1, 1),
			offset = Vector3.new(0, 1.7, 0),
			tint = "primary",
			neon = true,
			transparency = 0.62,
			anim = "glow",
			animSpeed = 3,
			animAmount = 0.3,
		},
		{
			shape = "Block",
			size = Vector3.new(0.55, 0.55, 0.55),
			offset = Vector3.new(0, 1.7, 0),
			tint = "accent",
			neon = true,
			anim = "glow",
			animSpeed = 6,
			animAmount = 0.35,
			particles = { rate = 18, size = 0.32, speed = 4, lifetime = 0.35, spread = 70, tint = "accent" },
		},
		{
			shape = "Block",
			size = Vector3.new(0.2, 1.6, 0.2),
			offset = Vector3.new(0, 1.7, 0),
			tint = "primary",
			neon = true,
			anim = "flicker",
			animSpeed = 7,
			animAmount = 0.4,
		},
		{
			shape = "Block",
			size = Vector3.new(1.4, 0.18, 0.18),
			offset = Vector3.new(0, 1.7, 0),
			tint = "primary",
			neon = true,
		},
		{
			shape = "Block",
			size = Vector3.new(0.18, 0.18, 1.4),
			offset = Vector3.new(0, 1.7, 0),
			tint = "secondary",
			neon = true,
		},
		{
			shape = "Block",
			size = Vector3.new(0.2, 0.2, 0.2),
			offset = Vector3.new(0.5, 2.1, -0.2),
			tint = "accent",
			neon = true,
			anim = "spin",
			animSpeed = 3.5,
		},
	},
	footprint = 0,
	height = 0,
})

--[[
	ГОБЛИНЫ. Одна порода на троих: мечник в волне, стрелок в волне и
	неуязвимый стрелок на холме у шамана — это одни и те же существа,
	и выглядеть они обязаны роднёй.

	Тряпьё, сталь и дерево красятся ВРУЧНУЮ через Palette.Detail: обноски
	не меняются вместе со стихией, а зелёным остаётся то, что зелёное, —
	кожа. Стихия у гоблина Dark, и покрасить его ею целиком значило бы
	получить фиолетового робота (то же правило, что у гоблина-шамана).

	Ноги идут каналом step: он считается от ПУТИ, а не от времени, поэтому
	бегущая толпа не перебирает ногами на месте и не разъезжается с землёй
	на разной скорости.
]]
local GOBLIN_LEG = { swing = 34, pivot = 1.35, rate = 0.32 }

table.insert(definitions, {
	key = "GoblinSwordsman",
	parts = {
		{
			shape = "Block",
			size = Vector3.new(0.42, 1.35, 0.5),
			offset = Vector3.new(0.36, 0.68, 0),
			color = "leather",
			anim = "step",
			animSpeed = GOBLIN_LEG.rate,
			animAmount = GOBLIN_LEG.swing,
			animPivotY = GOBLIN_LEG.pivot,
		},
		{
			shape = "Block",
			size = Vector3.new(0.42, 1.35, 0.5),
			offset = Vector3.new(-0.36, 0.68, 0),
			color = "leather",
			anim = "step",
			animSpeed = GOBLIN_LEG.rate,
			animAmount = GOBLIN_LEG.swing,
			animPivotY = GOBLIN_LEG.pivot,
			-- Ровно противофаза: иначе ноги шагают строем.
			animPhase = 0.5,
		},
		{
			shape = "Block",
			size = Vector3.new(1.25, 1.45, 0.9),
			offset = Vector3.new(0, 2.05, 0),
			color = "leather",
		},
		{
			shape = "Block",
			size = Vector3.new(1.05, 0.9, 0.9),
			offset = Vector3.new(0, 3.1, 0),
			tint = "primary",
		},
		-- Уши: главная примета гоблина в силуэте, и стоят они две детали.
		{
			shape = "Block",
			size = Vector3.new(0.4, 0.2, 0.2),
			offset = Vector3.new(0.66, 3.15, 0),
			tint = "primary",
		},
		{
			shape = "Block",
			size = Vector3.new(0.4, 0.2, 0.2),
			offset = Vector3.new(-0.66, 3.15, 0),
			tint = "primary",
		},
		{
			shape = "Block",
			size = Vector3.new(0.18, 0.18, 0.12),
			offset = Vector3.new(0.26, 3.15, -0.46),
			color = "eye",
		},
		{
			shape = "Block",
			size = Vector3.new(0.18, 0.18, 0.12),
			offset = Vector3.new(-0.26, 3.15, -0.46),
			color = "eye",
		},
		{
			shape = "Block",
			size = Vector3.new(0.36, 0.9, 0.36),
			offset = Vector3.new(0.78, 2.1, -0.2),
			tint = "primary",
		},
		--[[
			Клинок торчит вбок и вперёд намеренно: у бегущей на тебя толпы
			силуэт читается по контуру, а меч, прижатый к телу, в контур
			не попадает вовсе.
		]]
		{
			shape = "Block",
			size = Vector3.new(0.2, 1.7, 0.2),
			offset = Vector3.new(1, 2.9, -0.45),
			angles = Vector3.new(-35, 0, -12),
			color = "steel",
		},
	},
	footprint = 0,
	height = 0,
})

table.insert(definitions, {
	key = "GoblinArcher",
	parts = {
		{
			shape = "Block",
			size = Vector3.new(0.42, 1.35, 0.5),
			offset = Vector3.new(0.36, 0.68, 0),
			color = "leather",
			anim = "step",
			animSpeed = GOBLIN_LEG.rate,
			animAmount = GOBLIN_LEG.swing,
			animPivotY = GOBLIN_LEG.pivot,
		},
		{
			shape = "Block",
			size = Vector3.new(0.42, 1.35, 0.5),
			offset = Vector3.new(-0.36, 0.68, 0),
			color = "leather",
			anim = "step",
			animSpeed = GOBLIN_LEG.rate,
			animAmount = GOBLIN_LEG.swing,
			animPivotY = GOBLIN_LEG.pivot,
			animPhase = 0.5,
		},
		{
			shape = "Block",
			size = Vector3.new(1.2, 1.4, 0.85),
			offset = Vector3.new(0, 2, 0),
			color = "leather",
		},
		-- Капюшон вместо голой макушки: стрелок обязан отличаться от мечника
		-- силуэтом, а не только тем, что стоит дальше.
		{
			shape = "Block",
			size = Vector3.new(1.05, 0.9, 0.9),
			offset = Vector3.new(0, 3, 0),
			tint = "primary",
		},
		{
			shape = "Block",
			size = Vector3.new(1.15, 0.26, 1),
			offset = Vector3.new(0, 3.5, 0),
			color = "hood",
		},
		{
			shape = "Block",
			size = Vector3.new(0.38, 0.2, 0.2),
			offset = Vector3.new(0.64, 3.02, 0),
			tint = "primary",
		},
		{
			shape = "Block",
			size = Vector3.new(0.38, 0.2, 0.2),
			offset = Vector3.new(-0.64, 3.02, 0),
			tint = "primary",
		},
		{
			shape = "Block",
			size = Vector3.new(0.18, 0.18, 0.12),
			offset = Vector3.new(0.26, 3.05, -0.44),
			color = "eye",
		},
		{
			shape = "Block",
			size = Vector3.new(0.18, 0.18, 0.12),
			offset = Vector3.new(-0.26, 3.05, -0.44),
			color = "eye",
		},
		{
			shape = "Block",
			size = Vector3.new(0.34, 0.85, 0.34),
			offset = Vector3.new(0.74, 2.05, -0.2),
			tint = "primary",
		},
		{
			shape = "Block",
			size = Vector3.new(0.18, 0.9, 0.18),
			offset = Vector3.new(0.88, 2.5, -0.5),
			angles = Vector3.new(0, 0, 12),
			color = "wood",
		},
		{
			shape = "Block",
			size = Vector3.new(0.18, 0.9, 0.18),
			offset = Vector3.new(0.88, 1.7, -0.5),
			angles = Vector3.new(0, 0, -12),
			color = "wood",
		},
	},
	footprint = 0,
	height = 0,
})

Models.List = definitions
Models.ByKey = {} :: { [string]: ModelDef }

--[[
	Половина габаритного ящика детали после её поворота.

	Обычная формула |R| * halfSize: строка матрицы по модулю, умноженная на
	полуразмер, даёт габарит вдоль мировой оси. Нужна для footprint и height —
	мерить их по size, забывая про angles, значит промахнуться ровно на
	стоящем цилиндре, у которого высота лежит в X.
]]
local function extentOf(part: ModelPartDef): Vector3
	local angles = part.angles
	if not angles then
		return part.size * 0.5
	end

	local rotation = CFrame.Angles(math.rad(angles.X), math.rad(angles.Y), math.rad(angles.Z))
	local right = rotation.RightVector
	local up = rotation.UpVector
	local look = -rotation.LookVector
	local half = part.size * 0.5

	return Vector3.new(
		math.abs(right.X) * half.X + math.abs(up.X) * half.Y + math.abs(look.X) * half.Z,
		math.abs(right.Y) * half.X + math.abs(up.Y) * half.Y + math.abs(look.Y) * half.Z,
		math.abs(right.Z) * half.X + math.abs(up.Z) * half.Y + math.abs(look.Z) * half.Z
	)
end

for _, def in definitions do
	assert(Models.ByKey[def.key] == nil, `[Models] Дубликат ключа "{def.key}"`)
	Models.ByKey[def.key] = def

	assert(#def.parts > 0, `[Models] Модель "{def.key}" без деталей`)
	assert(#def.parts <= MAX_PARTS, `[Models] У модели "{def.key}" деталей больше {MAX_PARTS}`)

	-- Тела способностей живут по своему потолку: их на арене полтора десятка.
	local isFx = string.sub(def.key, 1, 2) == "Fx"
	assert(
		not isFx or #def.parts <= MAX_FX_PARTS,
		`[Models] У тела способности "{def.key}" деталей больше {MAX_FX_PARTS}`
	)

	--[[
		Лент и потоков искр на модель — не больше одной штуки каждого.

		Это не техническое ограничение, а цена: и то и другое рисуется каждый
		кадр, а тел способностей на арене полтора десятка. Вторая лента на той
		же модели вдвое дороже и при этом почти не видна — она идёт по той же
		траектории, что первая.
	]]
	local trailCount = 0
	local particleCount = 0

	local footprint = 0
	local height = 0

	for index, part in def.parts do
		assert(
			part.size.X > 0 and part.size.Y > 0 and part.size.Z > 0,
			`[Models] "{def.key}", деталь {index}: нулевой размер`
		)

		--[[
			Цвет задаётся ровно одним способом. Деталь без обоих осталась бы
			белой, а с обоими — молча выбрала бы один, и вопрос «почему шлем
			не красится» пришлось бы разбирать в бою.
		]]
		if part.color then
			assert(part.tint == nil, `[Models] "{def.key}", деталь {index}: заданы и tint, и color`)
			local paint = Palette.Detail[part.color]
			assert(
				paint ~= nil,
				`[Models] "{def.key}", деталь {index}: нет цвета "{part.color}" в Palette.Detail`
			)
			part.paint = paint
		else
			assert(
				part.tint ~= nil,
				`[Models] "{def.key}", деталь {index}: не задан ни tint, ни color`
			)
		end

		local extent = extentOf(part)
		footprint = math.max(footprint, math.abs(part.offset.X) + extent.X, math.abs(part.offset.Z) + extent.Z)
		height = math.max(height, part.offset.Y + extent.Y)

		--[[
			Ничего не торчит из-под пола. Мелкая на вид проверка ловит главную
			ошибку правки offset: деталь, ушедшая под арену, не видна, и её
			начинают двигать наугад, ломая заодно соседние.
		]]
		assert(
			part.offset.Y - extent.Y >= -0.05,
			`[Models] "{def.key}", деталь {index}: уходит под пол на {string.format(
				"%.2f",
				extent.Y - part.offset.Y
			)}`
		)

		--[[
			pulse держит низ детали на месте и потому считает его по size.Y
			напрямую. С поворотом это уже не низ, и деталь поехала бы вбок.
		]]
		assert(
			part.anim ~= "pulse" or part.angles == nil,
			`[Models] "{def.key}", деталь {index}: pulse на повёрнутой детали`
		)

		if part.anim then
			--[[
				Ноль означает забытую скорость, а не «стоять»: анимация без неё
				молча не идёт. Знак при этом осмыслен — отрицательный spin
				крутит деталь в другую сторону, и искра над огоньком летит
				навстречу языкам пламени.
			]]
			assert(
				(part.animSpeed or 0) ~= 0,
				`[Models] "{def.key}", деталь {index}: анимация {part.anim} без animSpeed`
			)
			assert(
				part.anim == "spin" or (part.animAmount or 0) > 0,
				`[Models] "{def.key}", деталь {index}: анимация {part.anim} без animAmount`
			)
			--[[
				Шаг без подвеса — это деталь, крутящаяся вокруг собственного
				центра: нога уедет сквозь пол, а ступня улетит от ноги.
			]]
			assert(
				part.anim ~= "step" or (part.animPivotY or 0) > 0,
				`[Models] "{def.key}", деталь {index}: step без animPivotY`
			)
		end

		local trail = part.trail
		if trail then
			trailCount += 1
			assert(
				trail.length > 0,
				`[Models] "{def.key}", деталь {index}: у ленты нулевая ширина`
			)
			assert(
				trail.lifetime > 0,
				`[Models] "{def.key}", деталь {index}: у ленты нулевое время жизни`
			)
			table.freeze(trail)
		end

		local particles = part.particles
		if particles then
			particleCount += 1
			assert(
				particles.rate > 0,
				`[Models] "{def.key}", деталь {index}: искры с нулевым потоком`
			)
			assert(
				particles.size > 0,
				`[Models] "{def.key}", деталь {index}: искры нулевого размера`
			)
			assert(
				particles.lifetime > 0,
				`[Models] "{def.key}", деталь {index}: искры с нулевым временем жизни`
			)
			table.freeze(particles)
		end

		table.freeze(part)
	end

	assert(trailCount <= 1, `[Models] У модели "{def.key}" лент больше одной`)
	assert(particleCount <= 1, `[Models] У модели "{def.key}" потоков искр больше одного`)

	def.footprint = footprint
	def.height = height

	table.freeze(def.parts)
	table.freeze(def)
end

table.freeze(definitions)
table.freeze(Models.ByKey)

return Models
