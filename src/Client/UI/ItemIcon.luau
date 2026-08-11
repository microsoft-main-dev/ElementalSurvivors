--!strict
--[[
	ItemIcon — иконка предмета в ячейке инвентаря.

	Картинка слота приходит из Config/Icons. Пока её нет, предмет — это цветной
	квадрат, и цвет говорит, ЧТО это: сталь шлема, кожа нагрудника, тёмная кожа
	сапог, золото амулета (Palette.Gear). Редкость в обоих случаях добавляется
	поверх свечением, а не своим цветом: легендарные сапоги обязаны остаться
	сапогами.

	«Неон» в плоском интерфейсе — это обводка цвета редкости, градиент и, у
	легендарных, медленная пульсация. Настоящего Neon-материала у GuiObject нет,
	и подделывать его картинкой было бы тем самым выдуманным ассетом.

	Публичный API:
		ItemIcon.Build(parent, name, slot, rarity, size) -> Icon
		ItemIcon.Consumable(parent, name, key, size)     -> Icon
		ItemIcon.RarityColor(rarity)                     -> Color3
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Icons = require(Shared.Config.Icons)
local Items = require(Shared.Config.Items)
local Palette = require(Shared.Config.Palette)
local Types = require(Shared.Types)
local UiKit = require(script.Parent.UiKit)

local ItemIcon = {}

--[[
	Насколько редкость светится. Обычный предмет не светится вовсе: если
	светятся все, свечение перестаёт что-либо значить.
]]
local GLOW: { [Types.ItemRarity]: { thickness: number, pulse: boolean } } = {
	Common = { thickness = 0, pulse = false },
	Rare = { thickness = 2, pulse = false },
	Epic = { thickness = 3, pulse = false },
	Legendary = { thickness = 3, pulse = true },
}

local PULSE_SPEED = 1.1 -- полных циклов в секунду

export type Icon = {
	frame: Frame,
}

function ItemIcon.RarityColor(rarity: Types.ItemRarity): Color3
	local def = Items.RarityByKey[rarity]
	return if def then Color3.fromHex(def.color) else Palette.UI.subtext
end

--[[
	Квадрат предмета. Размер задаётся снаружи: в ряду надетого снаряжения
	ячейки меньше, чем в самой сетке, а иконка одна и та же.
]]
function ItemIcon.Build(
	parent: Instance,
	name: string,
	slot: Types.ItemSlot,
	rarity: Types.ItemRarity,
	size: number
): Icon
	local frame = UiKit.Frame(parent, name, Palette.Gear[slot] or Palette.UI.subtext)
	frame.AnchorPoint = Vector2.new(0.5, 0.5)
	frame.Position = UDim2.fromScale(0.5, 0.5)
	frame.Size = UDim2.fromOffset(size, size)
	UiKit.Corners(frame, 8)

	local glow = GLOW[rarity] or GLOW.Common

	--[[
		У картинки предмета своя плашка, поэтому подложка и градиент под ней
		не нужны: они просвечивали бы по краям скругления цветной каймой.
		Без картинки всё остаётся как было.
	]]
	local image = UiKit.Image(frame, "Image", Icons.Gear[slot])
	if image then
		frame.BackgroundTransparency = 1
	else
		--[[
			Градиент сверху вниз даёт квадрату объём: без него он читается как
			плашка интерфейса, а не как предмет. У обычных он слабее, у редких
			сильнее — это второй, тихий признак редкости помимо обводки.
		]]
		local gradient = Instance.new("UIGradient")
		gradient.Rotation = 90
		gradient.Color = ColorSequence.new({
			ColorSequenceKeypoint.new(0, Color3.new(1, 1, 1)),
			ColorSequenceKeypoint.new(1, Color3.fromRGB(150, 150, 150)),
		})
		gradient.Parent = frame
	end

	if glow.thickness > 0 then
		local stroke = Instance.new("UIStroke")
		stroke.Name = "Glow"
		stroke.Color = ItemIcon.RarityColor(rarity)
		stroke.Thickness = glow.thickness
		stroke.Parent = frame

		if glow.pulse then
			--[[
				Пульсация живёт на Heartbeat, а не на Tween: иконок в сетке
				до полусотни, и полсотни висящих твинов дороже одного обработчика,
				который считает синус. Соединение снимается вместе с иконкой —
				перерисовка сетки уничтожает её целиком.
			]]
			local phase = 0
			local connection: RBXScriptConnection
			connection = RunService.Heartbeat:Connect(function(deltaTime: number)
				if not stroke.Parent then
					connection:Disconnect()
					return
				end
				phase = (phase + deltaTime * PULSE_SPEED) % 1
				stroke.Transparency = 0.35 + math.sin(phase * math.pi * 2) * 0.35
			end)
		end
	end

	return { frame = frame }
end

--[[
	Расходник (бустеры и заряды M7): key — ключ бустера или заряда из
	Config/Monetization. Картинка у него та же, что у соответствующего товара
	в магазине: это один и тот же предмет, просто в одном месте его покупают,
	а в другом он лежит.

	Пока картинок нет, все расходники выглядят одинаково — акцентный квадрат,
	а отличает их подпись: заводить таблицу цветов ради трёх записей значило бы
	завести ещё одно место, где они перечислены.
]]
function ItemIcon.Consumable(parent: Instance, name: string, key: string, size: number): Icon
	local frame = UiKit.Frame(parent, name, Palette.UI.accent)
	frame.AnchorPoint = Vector2.new(0.5, 0.5)
	frame.Position = UDim2.fromScale(0.5, 0.5)
	frame.Size = UDim2.fromOffset(size, size)
	UiKit.Corners(frame, 8)

	local image = UiKit.Image(frame, "Image", Icons.Consumables[key])
	if image then
		frame.BackgroundTransparency = 1
	else
		local gradient = Instance.new("UIGradient")
		gradient.Rotation = 90
		gradient.Color = ColorSequence.new({
			ColorSequenceKeypoint.new(0, Color3.new(1, 1, 1)),
			ColorSequenceKeypoint.new(1, Color3.fromRGB(150, 150, 150)),
		})
		gradient.Parent = frame
	end

	local stroke = Instance.new("UIStroke")
	stroke.Name = "Glow"
	stroke.Color = Palette.UI.subtext
	stroke.Thickness = 2
	stroke.Parent = frame

	return { frame = frame }
end

return ItemIcon
