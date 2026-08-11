--!strict
--[[
	ShopPanel — прилавок лобби (раздел 4 ТЗ).

	В M4 магазин торгует только тем, что в игре существует: пачками яиц
	со скидкой и опытом питомцу. Расходники, батлпасс, VIP и донатная валюта
	из раздела 4 — это M7; они появятся строками в Config/Shop, и панель
	покажет их без единой правки здесь.

	Лоты с опытом кормят экипированного питомца. Отдельного выбора «кого
	кормить» намеренно нет: питомец у игрока экипирован ровно один, и лишний
	шаг в покупке ради выбора из одного варианта — это просто лишний шаг.

	Публичный API:
		ShopPanel.Build(parent, send) -> Panel
		panel.Open()
		panel.Close()
		panel.Refresh(essence, prisms, equippedUid, equippedName)
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Icons = require(Shared.Config.Icons)
local Palette = require(Shared.Config.Palette)
local Shop = require(Shared.Config.Shop)
local UiKit = require(script.Parent.UiKit)

export type Panel = {
	Open: () -> (),
	Close: () -> (),
	Refresh: (essence: number, prisms: number, equippedUid: string, equippedName: string) -> (),
}

local ShopPanel = {}

function ShopPanel.Build(parent: Instance, send: (action: string, target: string?, extra: unknown) -> ()): Panel
	local window = UiKit.Window(parent, "ShopPanel", "Shop")

	local list = UiKit.Scroll(window.content, "List")
	list.Size = UDim2.fromScale(1, 1)

	local essenceBalance = 0
	local prismsBalance = 0
	local equippedUid = ""
	local equippedName = ""

	local function render(): ()
		UiKit.ClearList(list)

		window.subtitle.Text = if equippedName ~= ""
			then `Training goes to your equipped pet: {equippedName}.`
			else "Equip a pet before buying training."

		for order, lot in Shop.Lots do
			local accent = if lot.kind == "egg" then Palette.UI.accent else Palette.Element.Nature
			local row = UiKit.Row(list, order, accent)
			if not UiKit.RowIcon(row, Icons.Shop[lot.key]) then
				row.badge.Text = if lot.kind == "egg" then "10x" else "XP"
			end
			row.title.Text = `{lot.displayName}  ·  {UiKit.FormatAmount(lot.price)} {lot.currency}`
			row.subtitle.Text = lot.description

			local balance = if lot.currency == "essence" then essenceBalance else prismsBalance
			local affordable = balance >= lot.price
			-- Опыт некуда девать без экипированного питомца, поэтому такой лот
			-- гаснет, даже когда денег хватает.
			local usable = lot.kind ~= "petXp" or equippedUid ~= ""

			local buy = UiKit.Button(row.actions, "Buy", "Buy")
			buy.LayoutOrder = 1
			buy.Size = UDim2.fromOffset(96, UiKit.ButtonHeight)
			UiKit.SetEnabled(buy, affordable and usable)
			buy.Activated:Connect(function()
				send("BuyLot", lot.key, if lot.kind == "petXp" then equippedUid else nil)
			end)
		end
	end

	local panel: Panel = {
		Open = function()
			window.screen.Enabled = true
			render()
		end,

		Close = function()
			window.screen.Enabled = false
		end,

		Refresh = function(essence: number, prisms: number, uid: string, name: string)
			essenceBalance = essence
			prismsBalance = prisms
			equippedUid = uid
			equippedName = name
			if window.screen.Enabled then
				render()
			end
		end,
	}

	return panel
end

return ShopPanel
