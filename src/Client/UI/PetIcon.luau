--!strict
--[[
	PetIcon — иконка питомца и звёзды под ней.

	Одна форма на весь проект: где бы ни был показан питомец, он выглядит
	одинаково — круг цвета своей стихии, обводка цвета редкости, инициалы вида,
	а под кругом звёзды его позиции на лестнице цветом своего этапа.

	Картинка зверя приходит из Config/Icons. Пока её нет, в круге рисуются
	инициалы вида, а у слота стихии — её значок; значки специально из основного
	диапазона юникода, а не эмодзи: символ ★ в проекте уже рисуется, а эмодзи
	на части устройств уезжает по базовой линии.

	Кольцо редкости рисуется здесь и только здесь. В самих файлах рамки быть
	не должно: у картинки она своя и не знает про нашу шкалу редкостей, а два
	кольца на одной иконке скажут игроку разное.

	Требование «любой питомец этой стихии» рисуется тем же кругом, но со значком
	стихии вместо инициалов: слот обозначает не конкретного питомца, а условие,
	и подставлять туда чей-то портрет значило бы соврать, кого именно съедят.

	Публичный API:
		PetIcon.Pet(parent, name, petId, stars, size)     -> Icon
		PetIcon.Element(parent, name, element, stars, size) -> Icon
		PetIcon.StarsMarkup(stars)                        -> string
		PetIcon.StageColor(stars)                         -> Color3
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Balance = require(Shared.Config.Balance)
local Icons = require(Shared.Config.Icons)
local Palette = require(Shared.Config.Palette)
local Pets = require(Shared.Config.Pets)
local Types = require(Shared.Types)
local UiKit = require(script.Parent.UiKit)

local PetIcon = {}

-- Высота строки звёзд под кругом. Не масштабируется вместе с иконкой:
-- в сетке ингредиентов и в списке звёзды должны читаться одинаково.
local STAR_HEIGHT = 16
local STAR_SIZE = 13

--[[
	Цвет незаполненной звезды. Не цвет панели: на панели она стала бы невидимой,
	и «три из шести» читалось бы как «три», а сколько всего — никак.
]]
local STAR_EMPTY = Color3.fromHex("#4A5C53")

local ELEMENT_GLYPH: { [Types.Element]: string } = {
	Fire = "▲",
	Ice = "❄",
	Lightning = "⚡",
	Nature = "✿",
	Dark = "◆",
	Light = "☀",
}

export type Icon = {
	frame: Frame, -- корень: его двигают и масштабируют анимации
	body: Frame, -- сам круг без подписи звёзд
	SetDim: (dim: boolean) -> (),
}

-- Цвет этапа: белый, фиолетовый, красный, бриллиантовый.
function PetIcon.StageColor(stars: number): Color3
	local stage = (Pets.StarStage(stars))
	return Palette.Stars[stage] or Palette.Stars[1]
end

--[[
	Имя этапа словом. Цвет звёзд говорит то же самое, но словом однозначно:
	«Purple» не спутать ни с настройками монитора, ни с дальтонизмом.
]]
local STAGE_NAMES = { "White", "Purple", "Red" }

function PetIcon.StageName(stars: number): string
	if stars >= Pets.MaxStars then
		return "Diamond"
	end
	local stage = (Pets.StarStage(stars))
	return STAGE_NAMES[stage] or "?"
end

--[[
	Звёзды строкой RichText: заполненные цветом этапа, пустые — приглушённо.

	Отдельно от иконки, потому что в списках звёзды дописываются прямо в текст
	строки, а заводить ради них лишний фрейм в каждой строке незачем.
]]
function PetIcon.StarsMarkup(stars: number): string
	local color = PetIcon.StageColor(stars)
	local hex = color:ToHex()

	if stars >= Pets.MaxStars then
		return `<font color="#{hex}">◆</font>`
	end

	local _, index = Pets.StarStage(stars)
	local filled = string.rep("★", index)
	local empty = string.rep("★", Balance.Pets.starsPerStage - index)

	local dim = STAR_EMPTY:ToHex()
	return `<font color="#{hex}">{filled}</font><font color="#{dim}">{empty}</font>`
end

--[[
	Общий каркас: круг заданного размера плюс строка звёзд под ним.

	assetId — картинка зверя (или значка стихии), glyph — чем её заменить,
	пока ассета нет, accent — цвет круга, ring — цвет обводки (редкость;
	nil у слота стихии, у которого редкости нет).
]]
local function build(
	parent: Instance,
	name: string,
	size: number,
	accent: Color3,
	ring: Color3?,
	assetId: number?,
	glyph: string,
	stars: number?
): Icon
	local frame = UiKit.Frame(parent, name)
	frame.Size = UDim2.fromOffset(size, size + STAR_HEIGHT)

	local body = UiKit.Frame(frame, "Body", accent)
	body.Size = UDim2.fromOffset(size, size)
	UiKit.Corners(body, size // 2)

	local stroke = Instance.new("UIStroke")
	stroke.Thickness = 2
	stroke.Color = ring or Palette.UI.subtext
	stroke.Transparency = if ring then 0 else 0.4
	stroke.Parent = body

	--[[
		Картинка не на весь круг: зверь, упирающийся в обводку редкости, читается
		как обрезанный. Доля подобрана так, чтобы поля хватало и на кружке в 44
		пикселя (строка списка), и на 56 (подробности).

		Под картинкой круг ПЕРЕКРАШИВАЕТСЯ В НЕЙТРАЛЬНЫЙ. Зверь нарисован цветом
		своей стихии — ровно тем же, каким красится круг, — и на нём он попросту
		исчезает: огненный лис #E2603A на огненном круге #E2603A это один
		сплошной оранжевый блин. Стихию теперь несёт сама картинка, редкость —
		обводка, и дублировать стихию фоном больше не нужно.
	]]
	local image = UiKit.Image(body, "Image", assetId)
	if image then
		body.BackgroundColor3 = Palette.UI.slot
		image.AnchorPoint = Vector2.new(0.5, 0.5)
		image.Position = UDim2.fromScale(0.5, 0.5)
		image.Size = UDim2.fromScale(0.82, 0.82)
	end

	local label =
		UiKit.Label(body, "Glyph", if image then "" else glyph, math.floor(size * 0.42), Palette.UI.background)
	label.Font = Enum.Font.GothamBold
	label.Size = UDim2.fromScale(1, 1)
	label.TextXAlignment = Enum.TextXAlignment.Center

	local starsLabel: TextLabel? = nil
	if stars then
		local text = UiKit.Label(frame, "Stars", PetIcon.StarsMarkup(stars), STAR_SIZE)
		text.RichText = true
		text.Position = UDim2.fromOffset(0, size)
		text.Size = UDim2.fromOffset(size, STAR_HEIGHT)
		text.TextXAlignment = Enum.TextXAlignment.Center
		--[[
			Шесть звёзд в узком слоте иначе обрезаются многоточием, поэтому
			строка ужимается. Ограничение сверху обязательно: без него одна
			бриллиантовая звезда растянулась бы на всю ширину слота.
		]]
		text.TextTruncate = Enum.TextTruncate.None
		text.TextScaled = true

		local limit = Instance.new("UITextSizeConstraint")
		limit.MaxTextSize = STAR_SIZE
		limit.Parent = text

		starsLabel = text
	end

	local icon: Icon = {
		frame = frame,
		body = body,

		--[[
			Тусклый — «этого питомца у тебя нет». Гасится прозрачностью, а не
			серым цветом: серый круг читался бы как ещё одна стихия.
		]]
		SetDim = function(dim: boolean)
			body.BackgroundTransparency = if dim then 0.65 else 0
			label.TextTransparency = if dim then 0.5 else 0
			stroke.Transparency = if dim then 0.75 else (if ring then 0 else 0.4)

			if image then
				image.ImageTransparency = if dim then 0.5 else 0
			end

			local text = starsLabel
			if text then
				text.TextTransparency = if dim then 0.5 else 0
			end
		end,
	}

	return icon
end

-- Инициалы вида: «Ember Cub» -> «EC». Одна буква на слово, максимум две.
local function initials(displayName: string): string
	local letters: { string } = {}
	for word in string.gmatch(displayName, "%S+") do
		table.insert(letters, string.upper(string.sub(word, 1, 1)))
		if #letters == 2 then
			break
		end
	end
	return table.concat(letters)
end

function PetIcon.Pet(parent: Instance, name: string, petId: string, stars: number?, size: number): Icon
	local def = Pets.ByKey[petId]
	if not def then
		return build(parent, name, size, Palette.UI.panel, nil, nil, "?", stars)
	end

	return build(
		parent,
		name,
		size,
		Palette.Element[def.element],
		Palette.Rarity[def.rarity],
		Icons.Pets[petId],
		initials(def.displayName),
		stars
	)
end

function PetIcon.Element(parent: Instance, name: string, element: Types.Element, stars: number?, size: number): Icon
	return build(
		parent,
		name,
		size,
		Palette.Element[element],
		nil,
		Icons.Elements[element],
		ELEMENT_GLYPH[element] or "?",
		stars
	)
end

return PetIcon
