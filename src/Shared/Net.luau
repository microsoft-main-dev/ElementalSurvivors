--!strict
--[[
	Net — единственная точка создания и получения Remote-объектов.

	Сервер создаёт Remote при первом запросе, клиент дожидается его появления.
	Прямых Instance.new("RemoteEvent") нигде больше в проекте быть не должно:
	так весь сетевой контракт виден в одном месте, и туда же позже вешается
	rate limit и валидация (раздел 7 ТЗ).

	Публичный API:
		Net.Id                  -- имена всех Remote проекта, чтобы не разъезжались строки
		Net.GetEvent(name)      -> RemoteEvent
		Net.GetUnreliable(name) -> UnreliableRemoteEvent   -- частые числовые потоки
		Net.GetFunction(name)   -> RemoteFunction          -- только сервер -> клиент, не в горячем пути
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local FOLDER_NAME = "Net"
local WAIT_TIMEOUT = 15

local IS_SERVER = RunService:IsServer()

local Net = {}

-- Имена Remote-ов. Обе стороны берут строку отсюда, а не пишут литерал.
Net.Id = table.freeze({
	-- Сервер -> клиент: короткое всплывающее сообщение игроку.
	Notify = "Notify",
})

local cachedRoot: Folder? = nil

local function getRoot(): Folder
	local cached = cachedRoot
	if cached then
		return cached
	end

	local root: Folder
	if IS_SERVER then
		local existing = ReplicatedStorage:FindFirstChild(FOLDER_NAME)
		if existing then
			root = existing :: Folder
		else
			local folder = Instance.new("Folder")
			folder.Name = FOLDER_NAME
			folder.Parent = ReplicatedStorage
			root = folder
		end
	else
		local found = ReplicatedStorage:WaitForChild(FOLDER_NAME, WAIT_TIMEOUT)
		assert(
			found,
			`[Net] Папка "{FOLDER_NAME}" не появилась за {WAIT_TIMEOUT} с — сервер не стартовал?`
		)
		root = found :: Folder
	end

	cachedRoot = root
	return root
end

-- Общая реализация для всех трёх типов Remote.
local function getRemote(className: string, name: string): Instance
	local root = getRoot()

	if IS_SERVER then
		local existing = root:FindFirstChild(name)
		if existing then
			assert(
				existing.ClassName == className,
				`[Net] Remote "{name}" уже создан как {existing.ClassName}, а запрошен как {className}`
			)
			return existing
		end

		local remote = Instance.new(className)
		remote.Name = name
		remote.Parent = root
		return remote
	end

	local found = root:WaitForChild(name, WAIT_TIMEOUT)
	assert(found, `[Net] Remote "{name}" не появился за {WAIT_TIMEOUT} с`)
	assert(
		found.ClassName == className,
		`[Net] Remote "{name}" имеет класс {found.ClassName}, ожидался {className}`
	)
	return found
end

function Net.GetEvent(name: string): RemoteEvent
	return getRemote("RemoteEvent", name) :: RemoteEvent
end

function Net.GetUnreliable(name: string): UnreliableRemoteEvent
	return getRemote("UnreliableRemoteEvent", name) :: UnreliableRemoteEvent
end

function Net.GetFunction(name: string): RemoteFunction
	return getRemote("RemoteFunction", name) :: RemoteFunction
end

return Net
