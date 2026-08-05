--!strict
--[[
	PetIcon — иконка питомца и звёзды под ней.

	Одна форма на весь проект: где бы ни был показан питомец, он выглядит
	одинаково — круг цвета своей стихии, обводка цвета редкости, инициалы вида,
	а под кругом звёзды его позиции на лестнице цветом своего этапа.

	Ассетов нет и не будет (правило 4): круг рисуется скруглённым фреймом,
	стихия — символом шрифта. Значки специально из основного диапазона юникода,
	а не эмодзи: символ ★ в проекте уже рисуется, а эмодзи на части устройств
	уезжает по базовой линии.

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

	glyph — то, что написано в круге (инициалы вида или значок стихии),
	accent — цвет круга, ring — цвет обводки (редкость; nil у слота стихии,
	у которого редкости нет).
]]
local function build(
	parent: Instance,
	name: string,
	size: number,
	accent: Color3,
	ring: Color3?,
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

	local label = UiKit.Label(body, "Glyph", glyph, math.floor(size * 0.42), Palette.UI.background)
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
		return build(parent, name, size, Palette.UI.panel, nil, "?", stars)
	end

	return build(
		parent,
		name,
		size,
		Palette.Element[def.element],
		Palette.Rarity[def.rarity],
		initials(def.displayName),
		stars
	)
end

function PetIcon.Element(parent: Instance, name: string, element: Types.Element, stars: number?, size: number): Icon
	return build(parent, name, size, Palette.Element[element], nil, ELEMENT_GLYPH[element] or "?", stars)
end

return PetIcon
