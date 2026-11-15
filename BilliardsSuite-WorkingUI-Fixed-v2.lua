-- 당구 통합 도우미 (UI 라이브러리 분리 버전 - 고정밀 경로 및 자동 플레이 최적화)
-- UI: https://github.com/Footagesus/WindUI/releases/latest/download/main.lua

local function __patchAI(modules, name)
	local module = modules:FindFirstChild(name) or modules:FindFirstChild(name, true)
	if not (module and module:IsA("ModuleScript")) then return nil end
	local ok, result = pcall(require, module)
	if ok and type(result) == "table" and type(result.Plan) == "function" then return result end
	warn("[당구 패치] " .. name .. " 모듈을 쓸 수 없어 건너뜁니다: " .. (ok and "Plan 함수 없음" or tostring(result)))
	return nil
end

local function __patchReport(modules, poolAI, ai)
	if poolAI and ai then
		print("[당구 패치] 게임 AI 모듈을 찾았습니다. 원래 방식으로 계산합니다.")
		return
	end
	warn("[당구 패치] 게임 AI 모듈이 없어 자체 후보 탐색으로 계산합니다. (포켓볼 AI: "
		.. (poolAI and "있음" or "없음") .. ", 4구·3구 AI: " .. (ai and "있음" or "없음") .. ")")
	local found = {}
	for _, item in ipairs(modules:GetDescendants()) do
		if item:IsA("ModuleScript") and (string.find(item.Name, "AI", 1, true) or string.find(item.Name, "Bot", 1, true)) then
			table.insert(found, item:GetFullName())
		end
	end
	if #found > 0 then warn("[당구 패치] 이름에 AI/Bot 이 들어간 모듈: " .. table.concat(found, ", ")) end
end

local function __patchSeed(raw, limit, selectedState, poolAI, ai)
	if selectedState.PoolMode then
		if not poolAI then return nil end
	elseif not ai then
		return nil
	end
	local ok, seed = pcall(raw, limit, selectedState)
	if not ok then
		warn("[당구 패치] 게임 AI 계산 오류, 자체 계산으로 대신합니다: " .. tostring(seed))
		return nil
	end
	if type(seed) ~= "table" or type(seed.angle) ~= "number" or type(seed.power) ~= "number"
		or seed.angle ~= seed.angle or seed.power ~= seed.power then
		return nil
	end
	seed.side = tonumber(seed.side) or 0
	seed.top = tonumber(seed.top) or 0
	return seed
end

local __patchSeenErrors = {}
local function __patchEval(raw, selectedState, shot, stop)
	local ok, a, b, c = pcall(raw, selectedState, shot, stop)
	if ok then return a, b, c end
	local message = tostring(a)
	if not __patchSeenErrors[message] then
		__patchSeenErrors[message] = true
		warn("[당구 패치] 후보 검증 오류(이 후보는 건너뜀): " .. message)
	end
	return nil, message
end

local function __patchEarly(s, selectedRemote, seed, add, physicsFor, poolPhysics, groupFor, poolLegal, clearLine)
	if seed then return end
	if s.PoolMode then
		local c = poolPhysics.Config
		local balls = s.balls
		local legal = poolLegal(balls, groupFor(s), s.breakShot)
		if s.breakShot then
			local origin = balls[1].p
			local best, bestDistance
			for i = 2, #balls do
				if legal[i] then
					local distance = (balls[i].p - origin).Magnitude
					if not bestDistance or distance < bestDistance then best, bestDistance = i, distance end
				end
			end
			if best then
				local delta = balls[best].p - origin
				local angle = math.atan2(delta.Z, delta.X)
				for _, offset in ipairs({0, 0.002, -0.002, 0.006, -0.006, 0.012, -0.012}) do
					for _, power in ipairs({1, 0.95, 0.85}) do
						add({angle = angle + offset, power = power, side = 0, top = 0})
					end
				end
			end
		elseif s.ballInHand or s.kitchen then
			local kitchenOnly = s.kitchen and not s.ballInHand
			local function validSpot(pos)
				if pos.X < c.Radius or pos.X > c.Width - c.Radius or pos.Z < c.Radius or pos.Z > c.Height - c.Radius then return false end
				if kitchenOnly and pos.X > c.Width * 0.25 then return false end
				if poolPhysics.PocketAt(pos) then return false end
				for i = 2, #balls do
					if not balls[i].pocketed and (balls[i].p - pos).Magnitude < 2 * c.Radius + 0.001 then return false end
				end
				return true
			end
			local spots = {}
			for i = 2, #balls do
				local ball = balls[i]
				if legal[i] then
					for _, pocket in ipairs(poolPhysics.Pockets) do
						local toHole = pocket.hole - ball.p
						if toHole.Magnitude > c.Radius then
							local ghost = ball.p - toHole.Unit * (2 * c.Radius)
							for _, back in ipairs({3, 5, 8, 12, 16}) do
								local pos = ghost - toHole.Unit * (back * c.Radius)
								if validSpot(pos) and clearLine(balls, pos, ghost, 1, i) and clearLine(balls, ball.p, pocket.hole, 1, i) then
									table.insert(spots, {pos = pos, angle = math.atan2(toHole.Z, toHole.X), distance = (ghost - pos).Magnitude + toHole.Magnitude})
									break
								end
							end
						end
					end
				end
			end
			table.sort(spots, function(x, y) return x.distance < y.distance end)
			for k = 1, math.min(#spots, 12) do
				local spot = spots[k]
				local approximate = math.clamp(math.sqrt(2.8 * c.RollingFriction * c.Gravity * spot.distance) / c.MaxSpeed, 0.1, 0.7)
				for _, multiplier in ipairs({1.2, 1.5, 2.0}) do
					add({angle = spot.angle, power = approximate * multiplier, side = 0, top = 0, cue = {spot.pos.X, spot.pos.Z}})
				end
			end
		end
	else
		local physics = physicsFor(s, selectedRemote)
		local c, origin = physics.Config, s.balls[s.turn].p
		local targets = #s.balls == 3 and {3, 3 - s.turn} or {3, 4}
		for _, i in ipairs(targets) do
			local delta = s.balls[i].p - origin
			local distance = delta.Magnitude
			if distance > 2 * c.Radius then
				local base = math.atan2(delta.Z, delta.X)
				for _, f in ipairs({0.6, -0.6, 0.4, -0.4, 0.2, -0.2, 0.8, -0.8, 0.1, -0.1}) do
					local offset = math.asin(math.min(0.99, math.abs(f) * 2 * c.Radius / distance)) * (f > 0 and 1 or -1)
					for _, power in ipairs({0.4, 0.55, 0.7, 0.85, 0.95}) do
						add({angle = base + offset, power = power, side = f > 0 and 0.25 or -0.25, top = 0.15})
					end
				end
			end
		end
	end
end

local function __patchLate(s, seed, add)
	if seed or s.PoolMode then return end
	for index = 0, 143 do
		local angle = index * math.pi / 72
		for _, power in ipairs({0.5, 0.7, 0.85}) do
			add({angle = angle, power = power, side = 0, top = 0.2})
		end
	end
end

-- UI Library (external) — WindUI
local UI_LIB_URL = "https://github.com/Footagesus/WindUI/releases/latest/download/main.lua"
local function loadUILibrary()
	local env = (type(getgenv) == "function" and getgenv()) or _G
	if type(env.WindUI) == "table" and type(env.WindUI.CreateWindow) == "function" then
		return env.WindUI
	end
	if type(env.BilliardsUI) == "table" and type(env.BilliardsUI.CreateWindow) == "function" then
		return env.BilliardsUI
	end
	local source
	local ok, result = pcall(function()
		return game:HttpGet(UI_LIB_URL)
	end)
	if ok and type(result) == "string" and #result > 100 then
		source = result
	else
		local requestFn = (syn and syn.request) or (http and http.request) or http_request or request
		if type(requestFn) == "function" then
			local resp = requestFn({ Url = UI_LIB_URL, Method = "GET" })
			source = resp and (resp.Body or resp.body)
		end
	end
	assert(type(source) == "string" and #source > 100, "당구 UI 라이브러리를 불러오지 못했습니다: " .. tostring(result))
	local chunk, err = loadstring(source)
	assert(chunk, "UI 라이브러리 파싱 실패: " .. tostring(err))
	local lib = chunk()
	assert(type(lib) == "table" and type(lib.CreateWindow) == "function", "UI 라이브러리 형식이 올바르지 않습니다.")
	env.WindUI = lib
	env.BilliardsUI = lib
	return lib
end

local UI = loadUILibrary()

local function startPreview()
	local env = getgenv()
	if env.BilliardsPath then
		env.BilliardsPath.Stop()
	end
	local modules = game:GetService("ReplicatedStorage"):WaitForChild("Billiards", 10)
	assert(modules, "당구 모듈을 찾을 수 없습니다.")
	local preview = require(modules:WaitForChild("ShotPreview", 10))
	local geometry = require(modules:WaitForChild("TableGeometry", 10))
	local guides = require(modules:WaitForChild("GuideLines", 10))
	local originalShow = guides.Show
	local showWrapper
	local original = preview.Predict
	assert(type(original) == "function", "예상 경로 API가 변경되었습니다.")
	local runService = game:GetService("RunService")
	local folder = Instance.new("Folder")
	folder.Name = "당구예상경로"
	folder.Parent = workspace
	local state = {Enabled = true, Calls = 0, Segments = 0, Error = nil, HoldUntil = 0}
	local pool = {}
	local lastCall = 0
	local lastBuild = -math.huge
	local alive = true
	local busy = false
	local wrapper
	local heartbeat
	local colours = {
		Color3.fromRGB(80, 240, 255),
		Color3.fromRGB(255, 200, 65),
		Color3.fromRGB(255, 110, 140),
		Color3.fromRGB(135, 255, 130)
	}
	local function hide()
		for _, part in ipairs(pool) do
			part.Transparency = 1
		end
		state.Segments = 0
	end
	local function segment(a, b, colour, count)
		local length = (b - a).Magnitude
		if length < 0.012 or count >= 320 then
			return count
		end
		count = count + 1
		local part = pool[count]
		if not part then
			part = Instance.new("Part")
			part.Name = "경로"
			part.Anchored = true
			part.CanCollide = false
			part.CanTouch = false
			part.CanQuery = false
			part.CastShadow = false
			part.Material = Enum.Material.Neon
			part.Parent = folder
			pool[count] = part
		end
		part.Size = Vector3.new(0.025, 0.025, length)
		part.CFrame = CFrame.lookAt((a + b) / 2, b)
		part.Color = colour
		part.Transparency = 0.18
		return count
	end
	local function findGeometry(config)
		local views = workspace:FindFirstChild("BilliardsView")
		if not views then return nil end
		local chosen, best
		local camera = workspace.CurrentCamera
		for _, part in ipairs(views:GetDescendants()) do
			if part.Name == "PlayArea" and part:IsA("BasePart") then
				local mismatch = math.abs(part.Size.X / config.VisualScale - config.Width)
					+ math.abs(part.Size.Z / config.VisualScale - config.Height)
				if mismatch < 0.03 then
					local distance = camera and (camera.Focus.Position - part.Position).Magnitude or 0
					if not best or distance < best then
						chosen, best = part, distance
					end
				end
			end
		end
		if not chosen then return nil end
		return geometry.Configure(table.clone(config), chosen)
	end
	local function build(physics, balls, cueIndex, direction, power, spinX, spinY, boost)
		local config = physics.Config
		local geo = findGeometry(config)
		if not geo then
			hide()
			state.Error = "현재 물리 설정에 맞는 PlayArea를 찾지 못했습니다."
			return
		end
		local copies, paths = {}, {}
		for i, ball in ipairs(balls) do
			copies[i] = table.clone(ball)
			paths[i] = {ball.p}
		end
		local cue = copies[cueIndex]
		if not cue or cue.pocketed then hide() return end
		local reach = physics.Reach and physics.Reach(copies, cueIndex, direction) or boost or 1
		physics.Strike(cue, direction, math.clamp(power, 0, 1), spinX, spinY, reach)
		local dt = config.Step
		local steps = math.min(math.ceil(12 / dt), 1200)
		local simulated = 0
		local settledFrames = 0
		for step = 1, steps do
			physics.Step(copies, dt)
			simulated = step * dt
			local moving = false
			for i, ball in ipairs(copies) do
				if not ball.pocketed then
					if step % 2 == 0 or step == steps then
						local path = paths[i]
						if (ball.p - path[#path]).Magnitude > 0.0015 then
							path[#path + 1] = ball.p
						end
					end
					if ball.v.Magnitude > 0.001 or (physics.Slip and physics.Slip(ball).Magnitude > 0.001) then
						moving = true
					end
				end
			end
			if moving then
				settledFrames = 0
			else
				settledFrames = settledFrames + 1
			end
			if settledFrames >= 10 then
				for i, ball in ipairs(copies) do
					if not ball.pocketed then
						local path = paths[i]
						if (ball.p - path[#path]).Magnitude > 0.0015 then
							path[#path + 1] = ball.p
						end
					end
				end
				break
			end
		end
		local count = 0
		for pass = 1, 2 do
			for i, path in ipairs(paths) do
				if (pass == 1 and i == cueIndex) or (pass == 2 and i ~= cueIndex) then
					local colour = i == cueIndex and colours[1] or colours[2 + ((i - 1) % 3)]
					for j = 2, #path do
						local lift = Vector3.new(0, 0.025, 0)
						count = segment(geo:World(path[j - 1]) + lift, geo:World(path[j]) + lift, colour, count)
					end
				end
			end
		end
		for i = count + 1, #pool do pool[i].Transparency = 1 end
		state.Segments = count
		state.SimulatedSeconds = simulated
		state.Error = nil
	end
	wrapper = function(physics, balls, cueIndex, direction, power, spinX, spinY, ...)
		local result = original(physics, balls, cueIndex, direction, power, spinX, spinY, ...)
		if alive then
			lastCall = os.clock()
			state.Calls = state.Calls + 1
			if state.Enabled and not busy and lastCall - lastBuild >= 0.08 then
				lastBuild = lastCall
				busy = true
				local _, selectedPower = ...
				local ok, err = pcall(build, physics, balls, cueIndex, direction, selectedPower or power, spinX, spinY)
				busy = false
				if not ok then
					hide()
					state.Error = tostring(err)
				end
			end
		end
		return result
	end
	function state.SetEnabled(value)
		state.Enabled = true
	end
	function state.DrawPlan(physics, balls, cueIndex, plan)
		if not alive or not state.Enabled then return false end
		local direction = Vector3.new(math.cos(plan.angle), 0, math.sin(plan.angle))
		local drawBalls = balls
		if plan.cue then
			drawBalls = table.clone(balls)
			drawBalls[1] = table.clone(balls[1])
			drawBalls[1].p = Vector3.new(plan.cue[1], 0, plan.cue[2])
			drawBalls[1].pocketed = nil
		end
		local ok, err = pcall(build, physics, drawBalls, cueIndex, direction, plan.power, plan.side, plan.top, plan.BreakBoost)
		if not ok then state.Error = tostring(err) hide() return false end
		lastCall = os.clock()
		state.HoldUntil = 0
		return true
	end
	function state.Stop()
		if not alive then return end
		alive = false
		if preview.Predict == wrapper then preview.Predict = original end
		if guides.Show == showWrapper then guides.Show = originalShow end
		if heartbeat then heartbeat:Disconnect() end
		folder:Destroy()
		if env.BilliardsPath == state then env.BilliardsPath = nil end
	end
	preview.Predict = wrapper
	showWrapper = function(self, ...)
		local shown = originalShow(self, ...)
		if alive and shown then
			lastCall = os.clock()
			if state.Enabled and state.OnPoolGuide and lastCall >= state.HoldUntil and lastCall - lastBuild >= 0.15 then
				lastBuild = lastCall
				local data = ...
				local ok, err = pcall(state.OnPoolGuide, data)
				if not ok then state.Error = tostring(err) end
			end
		end
		return shown
	end
	guides.Show = showWrapper
	heartbeat = runService.Heartbeat:Connect(function()
		if not state.Enabled then hide() end
	end)
	env.BilliardsPath = state
	return state
end

local function startAuto(preview)
	local env = getgenv()
	local modules = game:GetService("ReplicatedStorage"):WaitForChild("Billiards", 10)
	assert(modules, "당구 모듈을 찾지 못했습니다.")
	local basePhysics = require(modules:WaitForChild("Physics", 10))
	local poolPhysics = require(modules:WaitForChild("PoolPhysics", 10))
	local poolAI = __patchAI(modules, "PocketBallAI")
	local ai = __patchAI(modules, "FourBallAI")
	local cueMotion = require(modules:WaitForChild("CueMotion", 10))
	local geometry = require(modules:WaitForChild("TableGeometry", 10))
	local matchClass = require(modules:WaitForChild("Match", 10))
	__patchReport(modules, poolAI, ai) assert(true, "자동 조준 API가 변경되었습니다.")
	if env.BilliardsAuto then env.BilliardsAuto.Stop() end
	local player = game:GetService("Players").LocalPlayer
	local runService = game:GetService("RunService")
	local state = {
		Enabled = false, Status = "경기 상태 확인 중", ShotsSent = 0,
		ShotsAccepted = 0, Error = nil, LastPlan = nil, Thinking = false,
		ThinkSeconds = 8, Level = 6, StrongPlay = true, SmoothCue = true, SmoothCuePreference = true, AimSeconds = 0.8, HumanThinking = true,
		Style = "balanced", StyleName = "균형형",
	}
	local alive, generation = true, 0
	local remote, snapshot, listener, heartbeat, window, statusLabel, toggle, modeLabel, statsLabel
	state.Preview = preview
	state.Version = "20261115_PreciseDirect"
	state.Standalone = true
	local attempted, pending, readyAt
	local lastTick, lastSync = 0, -math.huge
	local tablePhysics, physicsRemote, physicsThree
	local function key(s)
		return table.concat({tostring(s.round), tostring(s.turnId), tostring(s.shots), tostring(s.turn)}, ":")
	end
	local function myTurn(s)
		if s.turnPlayerId ~= nil then return s.turnPlayerId == player.UserId end
		if s.doubles then return false end
		return s.seats and s.seats[s.turn] == player.UserId
	end
	local function ready(s)
		if not s or s.phase ~= "playing" or not myTurn(s) then return false end
		if s.LocalMoving or s.moving or s.striking or s.opening or s.openingWaiting or s.cleaning then return false end
		if (s.winner ~= nil and s.winner ~= 0) or s.stale or not s.balls or not s.balls[s.PoolMode and 1 or s.turn] then return false end
		local now = workspace:GetServerTimeNow()
		if now < (tonumber(s.busyUntil) or 0) then return false end
		local deadline = tonumber(s.turnDeadline)
		return deadline == nil or now + 0.3 < deadline
	end
	local function setStatus(text)
		if state.Status == text then return end
		state.Status = text
		if statusLabel then statusLabel:SetText(text) end
	end
	local function pause(reason)
		state.Enabled = false
		generation = generation + 1
		if toggle then toggle:Set(false, true) end
		setStatus(reason)
	end
	local function physicsFor(s, selectedRemote)
		if s.PoolMode then return poolPhysics end
		local three = s.threeBall == true or (s.rules and s.rules.threeBall == true)
		if tablePhysics and physicsRemote == selectedRemote and physicsThree == three then return tablePhysics end
		local physical = selectedRemote:FindFirstChild("Table")
		physical = physical and physical.Value
		assert(physical, "현재 경기의 테이블을 찾지 못했습니다.")
		local size = physical:GetAttribute("TableSize")
		local viewName = three and size ~= "중대" and "DaedaeView" or "ViewTable"
		local views = workspace:FindFirstChild("BilliardsView")
		local view = views and views:FindFirstChild(viewName)
		local area = view and view:FindFirstChild("PlayArea", true)
		assert(area and area:IsA("BasePart"), "경기에 맞는 PlayArea를 찾지 못했습니다.")
		local physics = basePhysics.ForTable(three)
		geometry.Configure(physics.Config, area)
		tablePhysics, physicsRemote, physicsThree = physics, selectedRemote, three
		return physics
	end
	local function normalizePool(raw)
		local s = table.clone(raw)
		s.PoolMode = true
		s.RawBalls = raw.balls
		s.shots = raw.shotSeq or 0
		s.balls = {}
		for i, b in ipairs(raw.balls or {}) do
			local ball = poolPhysics.NewBall(i, b[1], b[2])
			if b[3] and b[3] ~= 0 then ball.pocketed = b[3] end
			s.balls[i] = ball
		end
		return s
	end
	local function normalizePlanSpin(plan)
		plan.side = math.clamp(tonumber(plan.side) or 0, -0.65, 0.65)
		plan.top = math.clamp(tonumber(plan.top) or 0, -0.65, 0.65)
		local magnitude = math.sqrt(plan.side * plan.side + plan.top * plan.top)
		if magnitude > 0.65 then plan.side, plan.top = plan.side * 0.65 / magnitude, plan.top * 0.65 / magnitude end
		return plan
	end
	function state.EvaluatePool(s, inputPlan, cancelled)
		local group = s.groups and s.groups[s.turn] or nil
		local onEight = group and true or false
		local legal = {}
		for i = 2, 16 do
			local n = i - 1
			if not s.balls[i].pocketed and group and n ~= 8 and ((n < 8) == (group == "low")) then onEight = false end
		end
		for i = 2, 16 do
			local n = i - 1
			legal[i] = s.breakShot or (onEight and n == 8) or
				(not onEight and n ~= 8 and (not group or ((n < 8) == (group == "low"))))
		end
		local deadline = os.clock() + math.clamp(state.ThinkSeconds, 1, 15)
		local function interrupted()
			return not alive or os.clock() > deadline or (cancelled and cancelled())
		end
		local request = {kitchen = s.kitchen == true or s.breakShot == true}
		local plan = table.clone(inputPlan)
		normalizePlanSpin(plan)
		if interrupted() then return nil, "경기 상태 변경 또는 계산 중단" end
		for _, field in ipairs({"angle", "power", "side", "top"}) do
			local n = plan[field]
			assert(type(n) == "number" and n == n and math.abs(n) < math.huge, "포켓볼 타격값 오류")
		end
		assert(plan.power >= 0.005 and plan.power <= 1, "포켓볼 힘 범위 오류")
		assert(Vector2.new(plan.side, plan.top).Magnitude <= 0.6501, "포켓볼 회전 범위 오류")
		local balls = {}
		for i, b in ipairs(s.balls) do balls[i] = table.clone(b) end
		if plan.cue then
			local c = poolPhysics.Config
			local pos = Vector3.new(plan.cue[1], 0, plan.cue[2])
			assert(s.ballInHand or s.breakShot or s.kitchen, "수구 배치 권한 없음")
			assert(pos.X >= c.Radius and pos.X <= c.Width - c.Radius and pos.Z >= c.Radius and pos.Z <= c.Height - c.Radius and not poolPhysics.PocketAt(pos), "수구 배치 범위 오류")
			assert(not request.kitchen or s.ballInHand or pos.X <= c.Width * 0.25, "브레이크 수구 배치 범위 오류")
			for i = 2, 16 do assert(balls[i].pocketed or (balls[i].p - pos).Magnitude >= 2 * c.Radius, "수구 배치 겹침") end
			balls[1].p, balls[1].pocketed = pos, nil
		end
		local first, scratched, eight, own, any, rail = nil, false, false, 0, 0, false
		local pocketedIndices = {}
		local function contact(a, b)
			if not first then if a == 1 then first = b elseif b == 1 then first = a end end
		end
		local function impact(kind)
			if first and kind == "rail" then rail = true end
		end
		local function pocket(i)
			table.insert(pocketedIndices, i)
			if i == 1 then scratched = true elseif i == 9 then eight = true
			else any = any + 1 if legal[i] then own = own + 1 end end
		end
		plan.BreakBoost = s.breakShot and poolPhysics.Config.BreakBoost or 1
		poolPhysics.Strike(balls[1], Vector3.new(math.cos(plan.angle), 0, math.sin(plan.angle)), plan.power, plan.side, plan.top, plan.BreakBoost)
		local settled, frameAt = false, os.clock()
		for _ = 1, math.ceil(30 / poolPhysics.Config.Step) do
			poolPhysics.Step(balls, poolPhysics.Config.Step, contact, impact, pocket)
			if poolPhysics.IsSettled(balls) then settled = true break end
			if os.clock() - frameAt > 0.002 then task.wait() frameAt = os.clock() if interrupted() then return nil, "포켓볼 검증 중 상태 변경 또는 시간 초과" end end
		end
		if not settled then return nil, "포켓볼 정지 확인 시간 초과" end
		plan.VerifiedFoul = scratched or not first or not legal[first] or (not rail and any == 0 and not eight)
		plan.VerifiedScore = group and own or any
		plan.VerifiedWinner = eight and onEight and not plan.VerifiedFoul and s.turn or 0
		plan.VerifiedLoss = eight and not s.breakShot and (not onEight or plan.VerifiedFoul)
		if plan.VerifiedLoss then return nil, "8번 공 조기 포켓 예상 타격 제외" end
		if plan.VerifiedFoul then return nil, "포켓볼 파울 예상 타격 제외" end
		plan.PocketedIndices = pocketedIndices
		return plan, balls
	end

	function state.EvaluateCarom(s, selectedRemote, inputPlan, cancelled)
		assert(s and s.balls and s.turn, "계산할 경기 상태가 없습니다.")
		if s.PoolMode then return state.EvaluatePool(s, inputPlan, cancelled) end
		local physics = physicsFor(s, selectedRemote)
		local balls = {}
		for i, ball in ipairs(s.balls) do
			assert(typeof(ball.p) == "Vector3", "공 위치 형식이 변경되었습니다.")
			balls[i] = physics.NewBall(i, ball.p.X, ball.p.Z)
			balls[i].v = ball.v or Vector3.new()
			balls[i].w = ball.w or Vector3.new()
		end
		local three = #balls == 3
		local final = s.finalThreeCushion and s.finalThreeCushion[s.turn] == true
		local deadline = os.clock() + math.clamp(state.ThinkSeconds, 1, 15)
		local function interrupted()
			return not alive or os.clock() > deadline or (cancelled and cancelled())
		end
		local plan = table.clone(inputPlan)
		normalizePlanSpin(plan)
		if interrupted() then return nil, "경기 상태 변경 또는 계산 중단" end
		for _, field in ipairs({"angle", "power", "side", "top"}) do
			local n = plan[field]
			assert(type(n) == "number" and n == n and math.abs(n) < math.huge, "조준 계산값이 올바르지 않습니다.")
		end
		plan.power = math.clamp(plan.power, cueMotion.MinPower, 1)
		local spin = Vector2.new(plan.side, plan.top)
		assert(spin.Magnitude <= (cueMotion.MaxSpin or 0.65) + 0.0001, "회전값이 허용 범위를 벗어났습니다.")

		local test = matchClass.new(three, physics)
		test:SetRules(s.targetScore or (s.rules and s.rules.target) or 10,
			s.finalRule == true or (s.rules and s.rules.final == true),
			not s.rules or s.rules.penalty ~= false)
		test.balls = {}
		for i, ball in ipairs(balls) do test.balls[i] = table.clone(ball) end
		test.turn = s.turn
		test.scores = {s.scores and s.scores[1] or 0, s.scores and s.scores[2] or 0}
		test.turnStartScore = test.scores[s.turn]
		local scoreBefore = test.scores[s.turn]
		assert(test:Shoot(plan.angle, plan.power, plan.side, plan.top), "물리 엔진이 타격값을 거부했습니다.")
		local frameAt = os.clock()
		for _ = 1, math.ceil(35 / physics.Config.Step) do
			test:Step(physics.Config.Step)
			if not test.moving then break end
			if os.clock() - frameAt > 0.002 then
				task.wait()
				frameAt = os.clock()
				if interrupted() then return nil, "검증 중 경기 상태 변경 또는 시간 초과" end
			end
		end
		if test.moving then return nil, "정지까지 검증하지 못한 타격" end
		plan.VerifiedScore = test.scores[s.turn] - scoreBefore
		plan.VerifiedFoul = test.shot and test.shot.foul == true or false
		plan.VerifiedWinner = test.winner
		if plan.VerifiedFoul or plan.VerifiedScore < 0 then return nil, "파울 예상 타격 제외" end
		return plan, test.balls, test
	end
	local function groupFor(s)
		return s.groups and s.groups[s.turn] or nil
	end
	local function poolLegal(balls, group, breakShot)
		local onEight = group ~= nil
		if group then
			for i = 2, 16 do
				local n = i - 1
				if not balls[i].pocketed and n ~= 8 and ((n < 8) == (group == "low")) then onEight = false end
			end
		end
		local legal = {}
		for i = 2, 16 do
			local n = i - 1
			legal[i] = not balls[i].pocketed and (breakShot or (onEight and n == 8)
				or (not onEight and n ~= 8 and (not group or ((n < 8) == (group == "low")))))
		end
		return legal
	end
	local function clearLine(balls, a, b, skipA, skipB)
		local delta = b - a
		local length2 = delta:Dot(delta)
		if length2 < 1e-10 then return false end
		local width = poolPhysics.Config.Radius * 2.03
		for i, ball in ipairs(balls) do
			if i ~= skipA and i ~= skipB and not ball.pocketed then
				local t = math.clamp((ball.p - a):Dot(delta) / length2, 0, 1)
				if (ball.p - (a + delta * t)).Magnitude < width then return false end
			end
		end
		return true
	end

	function state.PoolChances(balls, group, origin)
		local cue = origin or balls[1].p
		local legal = poolLegal(balls, group, false)
		local choices = {}
		local c = poolPhysics.Config
		for i = 2, 16 do
			if legal[i] then
				local ball = balls[i]
				for _, pocket in ipairs(poolPhysics.Pockets) do
					local toHole = pocket.hole - ball.p
					if toHole.Magnitude > c.Radius then
						local ghost = ball.p - toHole.Unit * (2 * c.Radius)
						local aim = ghost - cue
						if aim.Magnitude > 0.001 and ghost.X >= c.Radius and ghost.X <= c.Width - c.Radius
							and ghost.Z >= c.Radius and ghost.Z <= c.Height - c.Radius then
							local cut = aim.Unit:Dot(toHole.Unit)
							if cut > 0.15 and clearLine(balls, cue, ghost, 1, i) and clearLine(balls, ball.p, pocket.hole, 1, i) then
								local quality = cut * cut / (1 + aim.Magnitude + toHole.Magnitude)
								table.insert(choices, {angle = math.atan2(aim.Z, aim.X), Quality = quality,
									Distance = aim.Magnitude + toHole.Magnitude / math.max(cut * cut, 0.1), Ball = i})
							end
						end
					end
				end
			end
		end
		table.sort(choices, function(a, b) return a.Quality > b.Quality end)
		return choices[1] and choices[1].Quality or 0, choices
	end
	local function nextPoolState(s, plan, balls)
		local nextState = table.clone(s)
		nextState.balls, nextState.RawBalls = balls, {}
		nextState.breakShot, nextState.ballInHand, nextState.kitchen = false, false, false
		nextState.groups = table.clone(s.groups or {})
		if not groupFor(s) and not s.breakShot then
			for _, i in ipairs(plan.PocketedIndices or {}) do
				if i > 1 and i ~= 9 then
					nextState.groups[s.turn] = i < 9 and "low" or "high"
					nextState.groups[3 - s.turn] = i < 9 and "high" or "low"
					break
				end
			end
		end
		for i, b in ipairs(balls) do nextState.RawBalls[i] = {b.p.X, b.p.Z, b.pocketed or 0} end
		return nextState
	end
	local function caromQuality(balls, turn)
		local targets = #balls == 3 and {3, 3 - turn} or {3, 4}
		local cue = balls[turn].p
		local a, b = balls[targets[1]].p, balls[targets[2]].p
		local nearest = math.min((a - cue).Magnitude, (b - cue).Magnitude)
		local spread = (a - b).Magnitude
		return 1 / (1 + spread * 1.5 + math.abs(nearest - 0.4))
	end
	function state.BuildShotCandidates(s, selectedRemote, seed)
		local list, seen = {}, {}
		local style = state.Style or "balanced"
		local function add(p)
			if not p then return end
			local angle = math.atan2(math.sin(p.angle), math.cos(p.angle))
			local power = math.clamp(p.power, s.PoolMode and 0.05 or cueMotion.MinPower, 1)
			local side, top = math.clamp(p.side or 0, -0.65, 0.65), math.clamp(p.top or 0, -0.65, 0.65)
			local spinMagnitude = math.sqrt(side * side + top * top)
			if spinMagnitude > 0.65 then side, top = side * 0.65 / spinMagnitude, top * 0.65 / spinMagnitude end
			local tag = string.format("%.5f:%.4f:%.3f:%.3f", angle, power, side, top)
			if seen[tag] then return end
			seen[tag] = true
			table.insert(list, {angle = angle, power = power, side = side, top = top, cue = p.cue})
		end
		add(seed) __patchEarly(s, selectedRemote, seed, add, physicsFor, poolPhysics, groupFor, poolLegal, clearLine)
		if seed then
			for _, d in ipairs({-0.002, 0.002, -0.005, 0.005, -0.01, 0.01, 0}) do
				for _, scale in ipairs({0.95, 1.05, 0.9, 1.1, 1}) do
					add({angle = seed.angle + d, power = seed.power * scale, side = seed.side, top = seed.top, cue = seed.cue})
				end
			end
			for _, spin in ipairs({{0.1, 0}, {-0.1, 0}, {0, 0.1}, {0, -0.1}, {0.2, 0.1}, {-0.2, 0.1}}) do
				local side, top = math.clamp(seed.side + spin[1], -0.6, 0.6), math.clamp(seed.top + spin[2], -0.6, 0.6)
				if Vector2.new(side, top).Magnitude <= 0.65 then
					add({angle = seed.angle, power = seed.power, side = side, top = top, cue = seed.cue})
				end
			end
		end
		if s.PoolMode then
			local origin = seed and seed.cue and Vector3.new(seed.cue[1], 0, seed.cue[2]) or s.balls[1].p
			local _, choices = state.PoolChances(s.balls, groupFor(s), origin)
			for i = 1, math.min(#choices, 15) do
				local choice = choices[i]
				local c = poolPhysics.Config
				local approximate = math.clamp(math.sqrt(2.8 * c.RollingFriction * c.Gravity * choice.Distance) / c.MaxSpeed, 0.1, 0.65)
				for _, multiplier in ipairs({1.1, 1.4, 1.8, 2.3}) do
					add({angle = choice.angle, power = approximate * multiplier, side = 0, top = 0, cue = seed and seed.cue})
				end
			end
			local legal = poolLegal(s.balls, groupFor(s), s.breakShot)
			for i = 2, 16 do
				if legal[i] then
					local delta = s.balls[i].p - origin
					if delta.Magnitude > 0.001 then
						local angle = math.atan2(delta.Z, delta.X)
						local edge = math.asin(math.min(0.99, 2 * poolPhysics.Config.Radius / delta.Magnitude)) * 0.4
						for _, d in ipairs({0, -edge, edge, -edge*0.5, edge*0.5}) do
							for _, power in ipairs({0.15, 0.25, 0.4}) do add({angle = angle + d, power = power, side = 0, top = 0, cue = seed and seed.cue}) end
						end
					end
				end
			end
		else
			local physics = physicsFor(s, selectedRemote)
			local c, origin = physics.Config, s.balls[s.turn].p
			local targets = #s.balls == 3 and {3, 3 - s.turn} or {3, 4}
			for _, i in ipairs(targets) do
				local p = s.balls[i].p
				for _, target in ipairs({p, Vector3.new(2 * c.Radius - p.X, 0, p.Z),
					Vector3.new(2 * (c.Width - c.Radius) - p.X, 0, p.Z),
					Vector3.new(p.X, 0, 2 * c.Radius - p.Z), Vector3.new(p.X, 0, 2 * (c.Height - c.Radius) - p.Z)}) do
					local delta = target - origin
					local angle = math.atan2(delta.Z, delta.X)
					for _, power in ipairs({0.35, 0.5, 0.65, 0.8, 0.95}) do
						add({angle = angle, power = power, side = 0, top = 0.15})
					end
				end
			end
		end
		__patchLate(s, seed, add)
		if seed and style == "chess" then
			for _, d in ipairs({-0.015, -0.008, 0.008, 0.015}) do
				add({angle = seed.angle + d, power = seed.power * 0.85, side = seed.side * 0.6, top = seed.top * 0.6, cue = seed.cue})
			end
		elseif style == "attack" or style == "art" then
			local baseAngle = seed and seed.angle or 0
			local baseCue = seed and seed.cue or nil
			local powers = {0.25, 0.4, 0.55, 0.7, 0.85, 0.95, 1.0}
			local spins = {{0, 0.15}, {0, 0.35}, {0.25, 0.25}, {-0.25, 0.25}, {0.45, -0.2}, {-0.45, -0.2}}
			for index = 0, 107 do
				local angle = baseAngle + index * math.pi * 2 / 108
				for _, power in ipairs(powers) do
					for _, spin in ipairs(spins) do add({angle = angle, power = power, side = spin[1], top = spin[2], cue = baseCue}) end
				end
			end
		end
		return list
	end

	function state.PlanSnapshot(s, selectedRemote, cancelled)
		assert(s and s.balls and s.turn, "계산할 경기 상태가 없습니다.")
		local started = os.clock()
		local remaining = s.turnDeadline and s.turnDeadline - workspace:GetServerTimeNow() - 1.5 or state.ThinkSeconds
		local budget = math.max(0, math.min(state.ThinkSeconds, remaining))
		if budget < 0.1 then return nil, "계산할 차례 시간이 부족합니다" end
		local deadline = started + budget
		local finishWindow = false
		if s.PoolMode then
			local live = 0
			for i = 2, 16 do if s.balls[i] and not s.balls[i].pocketed then live = live + 1 end end
			finishWindow = live <= 2
		else
			local target = s.targetScore or (s.rules and s.rules.target) or 10
			local current = s.scores and tonumber(s.scores[s.turn]) or 0
			local finalThree = s.finalThreeCushion and s.finalThreeCushion[s.turn] == true
			finishWindow = target - current <= 1 or finalThree
		end
		local function hardCancel() return not alive or (cancelled and cancelled()) end
		local function exhausted() return hardCancel() or os.clock() >= deadline end
		local function seedPlanRaw(limit, selectedState)
			local function stop() return hardCancel() or os.clock() >= limit end
			if selectedState.PoolMode then
				return poolAI.Plan(poolPhysics, {balls = selectedState.RawBalls, group = groupFor(selectedState),
					ballInHand = selectedState.ballInHand, kitchen = selectedState.kitchen == true or selectedState.breakShot == true,
					breakShot = selectedState.breakShot, level = state.Level}, {frameBudget = 0.002, cancelled = stop})
			end
			local three = #selectedState.balls == 3
			return ai.Plan(physicsFor(selectedState, selectedRemote), cueMotion, selectedState.balls, selectedState.turn,
				{targets = three and {3, 3 - selectedState.turn} or {3, 4}, threeCushions = three or
					(selectedState.finalThreeCushion and selectedState.finalThreeCushion[selectedState.turn] == true),
					level = state.Level, frameBudget = 0.002, cancelled = stop})
		end
		local seed = __patchSeed(seedPlanRaw, math.min(deadline, started + math.max(0.1, budget * 0.4)), s, poolAI, ai)
		if hardCancel() then return nil, "경기 상태 변경으로 계산 취소" end
		local candidates = state.BuildShotCandidates(s, selectedRemote, seed)
		local finalists, checked = {}, 0
		local function evaluateRaw(selectedState, shot, stop)
			if selectedState.PoolMode then return state.EvaluatePool(selectedState, shot, stop) end
			return state.EvaluateCarom(selectedState, selectedRemote, shot, stop)
		end
		local function evaluate(a, b, c) return __patchEval(evaluateRaw, a, b, c) end
		local firstDeadline = state.StrongPlay and started + budget * 0.85 or deadline
		for _, shot in ipairs(candidates) do
			if exhausted() or (checked > 0 and os.clock() >= firstDeadline) then break end
			local plan, balls, match = evaluate(s, shot, exhausted)
			checked = checked + 1
			if plan then
				local nextState = s.PoolMode and nextPoolState(s, plan, balls) or table.clone(s)
				local own, opponent
				if s.PoolMode then
					local group = groupFor(nextState)
					own = state.PoolChances(balls, group)
					opponent = state.PoolChances(balls, group and (group == "low" and "high" or "low") or nil)
				else
					nextState.balls, nextState.scores = balls, table.clone(match.scores)
					own, opponent = caromQuality(balls, s.turn), caromQuality(balls, 3 - s.turn)
				end
				local score = (plan.VerifiedWinner == s.turn and 200000 or 0) + plan.VerifiedScore * 2000 + own * 1500 - (opponent or 0) * 300
				score = score - plan.power * 1.5 - math.abs(plan.side) * 0.5
				table.insert(finalists, {Plan = plan, State = nextState, Value = score, Own = own, Opponent = opponent})
			end
		end
		if hardCancel() then return nil, "경기 상태 변경으로 계산 취소" end
		if #finalists == 0 then return nil, "제한시간 안에 검증된 합법 타격을 찾지 못했습니다" end
		table.sort(finalists, function(a, b) return a.Value > b.Value end)
		local best = finalists[1]
		best.Plan.Strategy = best.Plan.VerifiedWinner == s.turn and "승리 및 마무리 경로" or (best.Plan.VerifiedScore > 0 and "최적 득점 및 포지션" or "안전 수비")
		return best.Plan
	end

	local cueStandModule = require(modules:WaitForChild("CueStand", 10))
	local originalCueNew = cueStandModule.new
	local cueNewWrapper
	local cueRecords, cueSeen = {}, {}
	local smoothStage, bypassUntil = nil, 0
	local lastCueDiscovery = 0
	local aimRandom = Random.new()
	state.SmoothFrames = 0
	local function ease(t)
		t = math.clamp(t, 0, 1)
		return t * t * (3 - 2 * t)
	end
	local function attachCue(stand, config, pool)
		if type(stand) ~= "table" or cueSeen[stand] or type(stand.place) ~= "function" or type(stand.frameAt) ~= "function" then return end
		cueSeen[stand] = true
		local record = {Stand = stand, Config = config, Pool = pool, Original = stand.place, Frames = {}, Times = {}}
		local function wrapper(seat, frame, hidden, ...)
			if alive and state.SmoothCue and snapshot and myTurn(snapshot) and seat == snapshot.turn
				and state.Enabled and record.Pool == (snapshot.PoolMode == true) and typeof(frame) == "CFrame" then
				local now = os.clock()
				local stage = smoothStage
				if stage and stage.Generation == generation and stage.Key == key(snapshot) and stage.Remote == remote and not (snapshot.LocalMoving or snapshot.moving or snapshot.striking) then
					local configNow = record.Config or stage.Config
					local shown = state.SampleAimSequence(stage.Sequence, now - stage.At)
					frame = stand.frameAt(configNow, stage.Position, shown.angle, shown.side, shown.top,
						cueMotion.TipGap + shown.power * cueMotion.PullDistance)
					hidden = false
					state.SmoothFrames = state.SmoothFrames + 1
				elseif now >= bypassUntil and ready(snapshot) and not hidden then
					local previous = record.Frames[seat]
					local dt = math.min(now - (record.Times[seat] or now), 0.1)
					if previous and dt > 0 then frame = previous:Lerp(frame, 1 - math.exp(-16 * dt)) end
				end
				record.Frames[seat], record.Times[seat] = frame, now
			else
				record.Frames[seat], record.Times[seat] = frame, os.clock()
			end
			local ok, result = pcall(record.Original, seat, frame, hidden, ...)
			if not ok then state.SmoothError = tostring(result); return nil end
			return result
		end
		record.Wrapper = wrapper
		record.OriginalFrameAt = stand.frameAt
		record.FrameWrapper = function(configNow, position, angle, ...)
			if not smoothStage then record.Angle = angle end
			local ok, result = pcall(record.OriginalFrameAt, configNow, position, angle, ...)
			if ok then return result end
			return CFrame.new()
		end
		stand.frameAt = record.FrameWrapper
		stand.place = wrapper
		table.insert(cueRecords, record)
		state.CueBindings = #cueRecords
	end
	local function discoverCues()
		if type(getconnections) ~= "function" or type(debug.getupvalues) ~= "function" or type(getfenv) ~= "function" then
			state.SmoothError = "현재 실행기에서 기존 큐대 연결 조회를 지원하지 않습니다."
			return
		end
		local visited = {}
		local function visit(fn, depth, pool)
			if depth > 2 or visited[fn] then return end
			visited[fn] = true
			local ok, values = pcall(debug.getupvalues, fn)
			if not ok then return end
			for _, value in pairs(values) do
				if type(value) == "table" then
					attachCue(value.stand or value, value.config, pool)
					if type(value.angle) == "number" and type(value.power) == "number" and value.sentAt ~= nil then
						state.ClientAim = value
					end
					for _, child in pairs(value) do
						if type(child) == "function" then visit(child, depth + 1, pool) end
					end
				elseif type(value) == "function" then visit(value, depth + 1, pool) end
			end
		end
		for _, signal in ipairs({runService.RenderStepped, runService.Heartbeat}) do
			for _, connection in ipairs(getconnections(signal)) do
				local fn = connection.Function
				if type(fn) == "function" then
					local ok, context = pcall(getfenv, fn)
					local owner = ok and context.script
					if owner and (owner.Name == "PocketBallClient" or owner.Name == "FourBallClient") then visit(fn, 0, owner.Name == "PocketBallClient") end
				end
			end
		end
	end
	cueNewWrapper = function(options, ...)
		local stand = originalCueNew(options, ...)
		local area = options.area
		local isPool = options.parent and options.parent.Name == "PocketBallCues"
		if not isPool and area and area.Parent then isPool = string.find(area.Parent.Name, "Pocket", 1, true) ~= nil end
		attachCue(stand, nil, isPool == true)
		return stand
	end
	cueStandModule.new = cueNewWrapper
	discoverCues()

	function state.CreateAimSequence(plan, fromAngle, budget)
		local sequence = {Duration = 0, Phases = {}}
		local current = {angle = fromAngle, power = 0, side = 0, top = 0}
		budget = math.max(0, budget)
		local finalSeconds = math.min(math.clamp(state.AimSeconds, 0.3, 1.2), budget)
		local extra = math.min(math.max(0, budget - finalSeconds), 2.0)
		local function add(target, duration, label)
			local delta = math.atan2(math.sin(target.angle - current.angle), math.cos(target.angle - current.angle))
			local nextValue = {angle = current.angle + delta, power = target.power, side = target.side, top = target.top}
			table.insert(sequence.Phases, {From = current, To = nextValue, At = sequence.Duration, Duration = duration, Label = label})
			sequence.Duration = sequence.Duration + duration
			current = nextValue
		end
		if state.HumanThinking and extra >= 0.8 then
			local sign = aimRandom:NextNumber() < 0.5 and -1 or 1
			local offset = math.rad(aimRandom:NextNumber(4, 12)) * sign
			add({angle = plan.angle + offset, power = plan.power * 0.2, side = 0, top = 0}, extra * 0.5, "조준 정밀 검토 중")
		end
		add(plan, finalSeconds, "최종 조준 및 격발 준비")
		return sequence
	end
	function state.SampleAimSequence(sequence, elapsed)
		local phases = sequence.Phases
		local phase = phases[#phases]
		local index = #phases
		for i, candidate in ipairs(phases) do
			if elapsed < candidate.At + candidate.Duration then phase, index = candidate, i break end
		end
		local u = phase.Duration > 0 and ease((elapsed - phase.At) / phase.Duration) or 1
		local a, b = phase.From, phase.To
		return {angle = a.angle + (b.angle - a.angle) * u, power = a.power + (b.power - a.power) * u,
			side = a.side + (b.side - a.side) * u, top = a.top + (b.top - a.top) * u}, index
	end
	function state.AnimateAim(plan, selectedState, selected, cancelled)
		if cancelled() then return false end
		if not state.SmoothCue then task.wait(0.15) return not cancelled() end
		local physics = physicsFor(selectedState, selected)
		local config = table.clone(physics.Config)
		config.CushionHeight = config.CushionHeight or 0
		config.RailTopRadius = config.RailTopRadius or cueMotion.RailTopRadius
		local cue = selectedState.balls[selectedState.PoolMode and 1 or selectedState.turn]
		local position = plan.cue and Vector3.new(plan.cue[1], 0, plan.cue[2]) or cue.p
		local fromAngle = selectedState.PoolMode and state.ClientAim and state.ClientAim.angle or state.LastAimAngle or plan.angle
		for _, record in ipairs(cueRecords) do
			if record.Pool == (selectedState.PoolMode == true) and record.Angle ~= nil
				and record.Stand.frames and record.Stand.frames[selectedState.turn] then fromAngle = record.Angle break end
		end
		local budget = math.max(0, math.min(3.0, (selectedState.turnDeadline or 0) - workspace:GetServerTimeNow() - 0.8))
		local sequence = state.CreateAimSequence(plan, fromAngle, budget)
		local stage = {Key = key(selectedState), Remote = selected, Position = position,
			Generation = generation, Config = config, At = os.clock(), Sequence = sequence}
		smoothStage = stage
		local lastSend, lastPhase = -math.huge, nil
		while true do
			if cancelled() then if smoothStage == stage then smoothStage = nil end return false end
			local now = os.clock()
			local elapsed = now - stage.At
			local shown, phase = state.SampleAimSequence(sequence, elapsed)
			if lastPhase ~= phase then lastPhase = phase setStatus(sequence.Phases[phase].Label) end
			if now - lastSend >= 0.08 then
				lastSend = now
				selected:FireServer("aim", {turnId = selectedState.turnId, angle = shown.angle,
					power = shown.power, side = shown.side, top = shown.top, cue = plan.cue,
					pulling = phase == #sequence.Phases and shown.power > plan.power * 0.45})
				if elapsed >= sequence.Duration then break end
			end
			runService.RenderStepped:Wait()
		end
		state.LastAimAngle = plan.angle
		bypassUntil = os.clock() + 0.4
		return not cancelled()
	end
	local function resolvePending(s)
		if not pending then return end
		if s.round ~= pending.round then pending = nil return end
		if (s.shots or 0) > pending.shots then
			state.ShotsAccepted = state.ShotsAccepted + 1
			state.LastReceipt = {Accepted = true, TurnId = pending.turnId, Shots = s.shots}
			pending = nil
		elseif s.turnId ~= pending.turnId then
			state.LastReceipt = {Accepted = false, TurnId = pending.turnId}
			pending = nil
		end
	end
	local function bind(selectedRemote)
		smoothStage = nil
		state.LastAimAngle = nil
		discoverCues()
		generation = generation + 1
		if listener then listener:Disconnect() end
		remote, snapshot, pending, attempted = selectedRemote, nil, nil, nil
		state.Remote = selectedRemote and selectedRemote:GetFullName() or nil
		state.LastPlan = nil
		readyAt = nil
		if not selectedRemote then setStatus("포켓볼·4구·3구 경기에 입장하세요") return end
		listener = selectedRemote.OnClientEvent:Connect(function(kind, payload)
			if not alive or remote ~= selectedRemote then return end
			local isPool = selectedRemote.Parent and selectedRemote.Parent.Name == "PocketBallEvents"
			if isPool and kind == "shot" and type(payload) == "table" then
				if snapshot and payload.round == snapshot.round then snapshot.LocalMoving = true end
				if pending and snapshot and payload.round == pending.round and payload.shooter == snapshot.turn and (payload.turnId == nil or payload.turnId == pending.turnId) then
					state.ShotsAccepted = state.ShotsAccepted + 1
					state.LastReceipt = {Accepted = true, TurnId = pending.turnId, Seq = payload.seq}
					pending = nil
				end
				return
			end
			if isPool and kind == "result" and type(payload) == "table" and type(payload.result) == "table" then kind, payload = "state", payload.result end
			if kind == "state" and type(payload) == "table" then
				if isPool then payload = normalizePool(payload) end
				if snapshot and type(payload.sequence) == "number" and payload.sequence <= (snapshot.sequence or -1) then return end
				if payload.slim then
					if not snapshot then return end
					local merged = table.clone(snapshot)
					for k, v in pairs(payload) do merged[k] = v end
					merged.slim, merged.stale = nil, true
					snapshot = merged
				else snapshot = payload end
				state.Snapshot = snapshot
				resolvePending(snapshot)
				if not state.Enabled and not state.Error then setStatus("준비 완료 · 자동 플레이를 켜세요") end
			elseif kind == "error" or kind == "denied" then
				state.Error = tostring(payload)
				pause("타격 거부: " .. state.Error)
			end
		end)
		lastSync = os.clock()
		selectedRemote:FireServer("sync")
	end
	function state.SetStyle(value)
		local styles = {basic = {name = "기본형", level = 6, think = 8}, balanced = {name = "균형형", level = 6, think = 8}, chess = {name = "체스형", level = 7, think = 10}, attack = {name = "공격형", level = 7, think = 10}, art = {name = "예술당구형", level = 6, think = 6}, defense = {name = "방어형", level = 6, think = 8}}
		local preset = styles[value] or styles.balanced
		state.Style = styles[value] and value or "balanced"
		state.StyleName, state.Level, state.ThinkSeconds = preset.name, preset.level, preset.think
		state.LastPlan = nil
		if statusLabel then setStatus("스타일 변경: " .. state.StyleName) end
	end
	function state.SetSmoothCue(value)
		state.SmoothCue = value == true
		state.SmoothCuePreference = state.SmoothCue
		if not state.SmoothCue then smoothStage = nil end
	end
	function state.SetEnabled(value)
		if not alive then return end
		state.Enabled = value == true
		generation = generation + 1
		state.Error = nil
		smoothStage = nil
		if state.Enabled then readyAt = nil end
		if toggle then toggle:Set(state.Enabled, true) end
		setStatus(state.Enabled and "자동 플레이 대기 중" or "자동 플레이 중지")
	end
	function state.Stop()
		if not alive then return end
		alive = false
		state.Enabled = false
		generation = generation + 1
		if listener then listener:Disconnect() end
		if heartbeat then heartbeat:Disconnect() end
		if window then
			local old = window
			window = nil
			state.Window = nil
			pcall(function()
				if type(old.Destroy) == "function" then old:Destroy()
				elseif type(old.Close) == "function" then old:Close() end
			end)
		end
		if cueStandModule.new == cueNewWrapper then cueStandModule.new = originalCueNew end
		for _, record in ipairs(cueRecords) do
			if record.Stand.place == record.Wrapper then record.Stand.place = record.Original end
			if record.Stand.frameAt == record.FrameWrapper then record.Stand.frameAt = record.OriginalFrameAt end
		end
		smoothStage = nil
		if preview then preview.Stop() end
		if env.BilliardsSuite == state then env.BilliardsSuite = nil end
		if env.BilliardsAuto == state then env.BilliardsAuto = nil end
	end
	local function tick()
		if not alive or os.clock() - lastTick < 0.15 then return end
		lastTick = os.clock()
		local events = modules:FindFirstChild("TableEvents")
		local name = player:GetAttribute("BilliardsMatch")
		local poolEvents = modules:FindFirstChild("PocketBallEvents")
		local selectedRemote = type(name) == "string" and ((poolEvents and poolEvents:FindFirstChild(name)) or (events and events:FindFirstChild(name))) or nil
		if selectedRemote ~= remote then bind(selectedRemote) end
		state.SmoothCue = state.SmoothCuePreference == true
		if state.SmoothCue and os.clock() - lastCueDiscovery > 1.5 then
			lastCueDiscovery = os.clock(); pcall(discoverCues)
		end
		if not remote then
			state.Mode = "경기 없음"
			if modeLabel then modeLabel:SetText("포켓볼·4구·3구 자동 감지 · 경기 입장 대기") end
			return
		end
		if snapshot then
			local three = snapshot.threeBall == true or (snapshot.rules and snapshot.rules.threeBall == true)
			state.Mode = snapshot.PoolMode and "포켓볼(8볼)" or (three and "3구" or "4구")
			local final = snapshot.finalThreeCushion and snapshot.finalThreeCushion[snapshot.turn]
			if modeLabel then modeLabel:SetText("현재 모드: " .. state.Mode) end
			if statsLabel then
				statsLabel:SetText(string.format("타격 %d회 · 서버 확인 %d회 · 경로 %d개", state.ShotsSent, state.ShotsAccepted, preview.Segments))
			end
		end
		if pending then
			if os.clock() - pending.at > 4 then
				state.Error = "서버 타격 확인 없음"
				pending = nil
			end
			return
		end
		if snapshot and snapshot.stale and not snapshot.moving and os.clock() - lastSync > 2 then
			lastSync = os.clock()
			remote:FireServer("sync")
		end
		if not state.Enabled then return end
		if not ready(snapshot) then
			readyAt = nil
			setStatus(snapshot and snapshot.phase == "finished" and "경기 종료" or "내 차례와 공 정지 대기 중")
			return
		end
		local shotKey = key(snapshot)
		if attempted == shotKey then return end
		if not readyAt then readyAt = os.clock() return end
		if os.clock() - readyAt < 0.25 then return end

		local selectedState, selected = snapshot, remote
		local token = generation

		-- 실시간 무작위 시뮬레이션을 제거하고 즉시 PlanSnapshot으로 정밀 타격 계산 및 실행
		attempted = shotKey
		state.Thinking = true
		setStatus("고정밀 경로 계산 중...")

		task.spawn(function()
			local function cancelled()
				return not alive or not state.Enabled or generation ~= token or remote ~= selected
			end
			local physics = physicsFor(selectedState, selected)
			local ok, plan = pcall(state.PlanSnapshot, selectedState, selected, cancelled)
			state.Thinking = false

			if cancelled() then return end
			if not ok or not plan then
				setStatus(tostring(plan or "유효한 타격 경로를 찾지 못했습니다"))
				return
			end

			state.LastPlan = plan
			pcall(preview.DrawPlan, physics, selectedState.balls, selectedState.PoolMode and 1 or selectedState.turn, plan)
			setStatus("목표 지점으로 조준 중")

			local aimOK, aimed = pcall(state.AnimateAim, plan, selectedState, selected, cancelled)
			if not aimOK or not aimed or cancelled() then
				smoothStage = nil
				return
			end

			smoothStage = nil
			normalizePlanSpin(plan)
			pending = {round = snapshot.round, turnId = snapshot.turnId, shots = snapshot.shots or 0, at = os.clock()}
			local sent, err = pcall(function()
				selected:FireServer("shoot", {turnId = snapshot.turnId, angle = plan.angle,
					power = plan.power, side = plan.side, top = plan.top, cue = plan.cue,
					impactAt = workspace:GetServerTimeNow() + (cueMotion.StrokeTime or 0.15)})
			end)
			if not sent then
				state.Error = tostring(err)
				pause("타격 전송 오류: " .. state.Error)
				return
			end
			state.ShotsSent = state.ShotsSent + 1
			setStatus(string.format("타격 전송 완료 (%d회)", state.ShotsSent))
		end)
	end

	preview.OnPoolGuide = function(data)
		if not snapshot or not snapshot.PoolMode or snapshot.LocalMoving or not data or not data.start or not data.contact then return end
		local direction = data.contact - data.start
		if direction.Magnitude < 0.0001 then return end
		local cueLength = data.cueLine and (data.cueLine[2] - data.cueLine[1]).Magnitude or 0
		local objectLength = data.objectLine and (data.objectLine[2] - data.objectLine[1]).Magnitude or 0
		local power = math.clamp(math.sqrt(cueLength * cueLength + objectLength * objectLength) / (6 * poolPhysics.Config.Radius), 0.05, 1)
		local plan = {angle = math.atan2(direction.Z, direction.X), power = power, side = 0, top = 0,
			cue = {data.start.X, data.start.Z}, BreakBoost = snapshot.breakShot and poolPhysics.Config.BreakBoost or 1}
		preview.DrawPlan(poolPhysics, snapshot.balls, 1, plan)
		preview.HoldUntil = 0
	end
	env.BilliardsAuto = state
	env.BilliardsSuite = state

	local ok, err = pcall(function()
		window = UI:CreateWindow({
			Title = "당구 통합 도우미",
			Author = "정밀 예측 경로 · 자동 플레이 최적화",
			Icon = "target",
			Folder = "BilliardsSuite",
			Size = UDim2.fromOffset(520, 500),
			MinSize = Vector2.new(400, 320),
			Theme = "Dark",
			Resizable = true,
			HideSearchBar = true,
		})

		local function makeLabel(parent, title, desc)
			local p = parent:Paragraph({ Title = title or "", Desc = desc or "" })
			function p:SetText(t)
				if type(p.SetDesc) == "function" then p:SetDesc(tostring(t or "")) end
			end
			return p
		end

		local mainTab = window:Tab({ Title = "당구 도우미", Icon = "circle-dot" })
		modeLabel = makeLabel(mainTab, "모드", "모드 확인 중")

		mainTab:Toggle({
			Title = "예상 경로 표시",
			Value = true,
			Callback = function(_) preview.SetEnabled(true) end,
		})

		toggle = mainTab:Toggle({
			Title = "자동 플레이",
			Value = false,
			Callback = function(v) state.SetEnabled(v == true) end,
		})

		mainTab:Toggle({
			Title = "큐대 부드럽게 이동",
			Value = true,
			Callback = function(v) state.SetSmoothCue(v == true) end,
		})
		mainTab:Toggle({
			Title = "자연스러운 조준 동작",
			Value = true,
			Callback = function(v) state.HumanThinking = v == true end,
		})

		statusLabel = makeLabel(mainTab, "상태", state.Status or "준비 중")
		statsLabel = makeLabel(mainTab, "통계", "타격 0회 · 서버 확인 0회")

		mainTab:Button({
			Title = "경기 상태 다시 조회",
			Icon = "refresh-cw",
			Callback = function()
				if remote then lastSync = os.clock(); remote:FireServer("sync") end
			end,
		})
		mainTab:Button({
			Title = "완전히 종료",
			Icon = "power",
			Callback = function() state.Stop() end,
		})

		local stylesTab = window:Tab({ Title = "스타일", Icon = "sparkles" })
		stylesTab:Dropdown({
			Title = "플레이 스타일",
			Values = {"균형형 · 득점과 수비", "체스형 · 정밀 계산", "공격형 · 최대 득점", "예술당구형", "방어형"},
			Value = "균형형 · 득점과 수비",
			Callback = function(selected)
				if string.find(selected, "체스") then state.SetStyle("chess")
				elseif string.find(selected, "공격") then state.SetStyle("attack")
				elseif string.find(selected, "예술") then state.SetStyle("art")
				elseif string.find(selected, "방어") then state.SetStyle("defense")
				else state.SetStyle("balanced") end
			end,
		})

		stylesTab:Slider({
			Title = "계산 정밀도 시간",
			Step = 1,
			Value = { Min = 3, Max = 12, Default = 8 },
			Callback = function(v) state.ThinkSeconds = v end,
		})

		state.Window = window
	end)
	if not ok then warn("창 생성 오류: " .. tostring(err)) end

	heartbeat = runService.Heartbeat:Connect(function()
		local ok, err = pcall(tick)
		if not ok then state.Error = tostring(err) pause("자동 플레이 오류: " .. state.Error) end
	end)
	tick()
	print("당구 도우미 로드 완료: 고정밀 예측 경로 및 자동 플레이 활성화 대기 중")
	return state
end

local preview = startPreview()
local ok, suite = pcall(startAuto, preview)
if not ok then preview.Stop() error(suite) end
return suite
