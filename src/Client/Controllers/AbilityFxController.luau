--!strict
--[[
	AbilityFxController — владелец забега для эффектов способностей.

	Здесь только события и цикл: когда начался забег, что пришло с сервера,
	когда пауза, когда конец. Как выглядит каждая форма — в Client/Fx/FxForms,
	из чего сделаны детали — в Client/Fx/FxKit.

	Разделено потому, что дальше у каждой из пятнадцати способностей будет
	собственное тело, хвост и искры: держать это в одном файле с подпиской
	на Remote — значит получить полторы тысячи строк, где половина про сеть,
	а половина про геометрию.

	Урона здесь нет и быть не может: всё это чистая косметика.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Balance = require(Shared.Config.Balance)
local FxForms = require(script.Parent.Parent.Fx.FxForms)
local FxKit = require(script.Parent.Parent.Fx.FxKit)
local Net = require(Shared.Net)
local SettingsController = require(script.Parent.SettingsController)
local Types = require(Shared.Types)

local AbilityFxController = {}

local player = Players.LocalPlayer

local active = false
local paused = false

local function getPlayerWorld(): Vector3?
	local character = player.Character
	if not character then
		return nil
	end
	local root = character:FindFirstChild("HumanoidRootPart") :: BasePart?
	return if root then root.Position else nil
end

--[[
	Свернуть забег: формы отдают всё, что держали, обратно в пулы.

	Порядок обязателен. FxForms.Clear роняет детали в пулы, и только после
	этого пулам есть что складывать; наоборот — и на арене останутся висеть
	орбы забега, которого уже нет.
]]
local function shutdown(): ()
	FxForms.Clear()
	FxKit.Clear()
end

local function onHeartbeat(deltaTime: number): ()
	if not active or paused then
		-- На паузе эффекты замирают вместе с боем: сервер их тоже не считает.
		return
	end

	FxForms.Step(deltaTime, os.clock(), getPlayerWorld())
end

function AbilityFxController.Start(): ()
	Net.GetEvent(Net.Id.RunStarted).OnClientEvent:Connect(function(slot: number)
		shutdown()

		-- Качество читается один раз на весь забег, тем же способом, что
		-- у EnemyRenderController/CrystalRenderController.
		local tier = Balance.Quality[SettingsController.ResolveQuality()]
		local fxQuality: FxKit.Quality = {
			trails = tier.fxTrails,
			sparks = tier.fxSparks,
			waveSegments = tier.fxWaveSegments,
		}

		FxKit.Init(fxQuality)
		FxForms.Begin(Vector3.new(slot * Balance.Arena.spacing, 0, 0), fxQuality)

		paused = false
		active = true
	end)

	Net.GetEvent(Net.Id.CombatPaused).OnClientEvent:Connect(function(value: boolean)
		paused = value
		FxForms.ClearTransient()
	end)

	Net.GetEvent(Net.Id.RunEnded).OnClientEvent:Connect(function()
		active = false
		shutdown()
	end)

	Net.GetUnreliable(Net.Id.RunSnapshot).OnClientEvent:Connect(function(snapshot: Types.RunSnapshot)
		FxForms.SetViews(snapshot.abilities)
	end)

	Net.GetUnreliable(Net.Id.AbilityFx).OnClientEvent
		:Connect(function(kind: string, key: string, payload: { { x: number, z: number, dx: number, dz: number } })
			if not active then
				return
			end
			FxForms.Spawn(kind, key, payload)
		end)

	RunService.Heartbeat:Connect(onHeartbeat)
end

return AbilityFxController
