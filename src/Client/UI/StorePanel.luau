--!strict
--[[
	StorePanel — витрина за Robux (раздел 4 ТЗ), M7.

	Единственная панель в проекте, у которой нет ни одного действия на сервер.
	Покупка запускается прямо отсюда через MarketplaceService: дальше Roblox
	разговаривает с сервером напрямую, и клиенту нечего ни просить, ни
	подтверждать. Поэтому здесь нет ни send, ни проверки баланса — Robux
	считает Roblox, а не мы.

	Что панель показывает, приходит готовым в StoreView: список товаров, уже
	действующие бустеры с остатком времени и купленные заряды. Клиент не решает,
	что доступно, — сервер присылает флаг available, и товар без заведённого
	productId гаснет с подписью, вместо того чтобы открыть пустое окно покупки.

	Публичный API:
		StorePanel.Build(parent) -> Panel
		panel.Open()
		panel.Close()
		panel.Refresh(view)
]]

local MarketplaceService = game:GetService("MarketplaceService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Icons = require(Shared.Config.Icons)
local Palette = require(Shared.Config.Palette)
local Types = require(Shared.Types)
local UiKit = require(script.Parent.UiKit)

export type Panel = {
	Open: () -> (),
	Close: () -> (),
	Refresh: (view: Types.StoreView?) -> (),
}

local StorePanel = {}

function StorePanel.Build(parent: Instance): Panel
	local window = UiKit.Window(parent, "StorePanel", "Store")

	local list = UiKit.Scroll(window.content, "List")
	list.Size = UDim2.fromScale(1, 1)

	local current: Types.StoreView? = nil

	local function render(): ()
		UiKit.ClearList(list)

		local view = current
		if not view then
			window.subtitle.Text = "Loading…"
			return
		end

		window.subtitle.Text = if view.essenceMult > 1
			then `Your runs currently pay {view.essenceMult}x Essence.`
			else "Boosts speed up rewards. They never make you stronger in combat."

		local order = 0

		--[[
			Действующие бустеры идут первыми и не имеют кнопки: это состояние,
			а не товар. Без них человек, купивший неделю x2, не может нигде
			увидеть, сколько у него осталось.
		]]
		for _, boost in view.boosts do
			order += 1
			local row = UiKit.Row(list, order, Palette.Element.Light)
			-- «ON» без картинки не теряется: остаток времени всё равно в подписи.
			if not UiKit.RowIcon(row, Icons.Consumables[boost.key]) then
				row.badge.Text = "ON"
			end
			row.title.Text = boost.displayName
			row.subtitle.Text = `Active for another {UiKit.FormatDuration(boost.secondsLeft)}`
		end

		for _, charge in view.charges do
			order += 1
			local row = UiKit.Row(list, order, Palette.Element.Light)
			--[[
				Количество переезжает в заголовок, только если метку занял значок:
				показывать «x3» в обоих местах разом — это два источника одного
				числа, и однажды они разойдутся.
			]]
			if UiKit.RowIcon(row, Icons.Consumables[charge.key]) then
				row.title.Text = `{charge.displayName}  ·  x{charge.count}`
			else
				row.badge.Text = `x{charge.count}`
				row.title.Text = charge.displayName
			end
			row.subtitle.Text = "Spent automatically on your next finished run."
		end

		for _, product in view.products do
			order += 1
			local row = UiKit.Row(list, order, Palette.UI.accent)
			if not UiKit.RowIcon(row, Icons.Products[product.key]) then
				row.badge.Text = "R$"
			end
			row.title.Text = product.displayName
			row.subtitle.Text = if product.available
				then product.description
				else `{product.description}  ·  not on sale yet`

			local buy = UiKit.Button(row.actions, "Buy", "Buy")
			buy.LayoutOrder = 1
			buy.Size = UDim2.fromOffset(96, UiKit.ButtonHeight)
			UiKit.SetEnabled(buy, product.available)
			buy.Activated:Connect(function()
				if not product.available then
					return
				end
				MarketplaceService:PromptProductPurchase(Players.LocalPlayer, product.productId)
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

		Refresh = function(view: Types.StoreView?)
			current = view
			if window.screen.Enabled then
				render()
			end
		end,
	}

	return panel
end

return StorePanel
