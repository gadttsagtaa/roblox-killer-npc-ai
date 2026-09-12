--[[
	ROBLOX R6 KILLER NPC AI SYSTEM
	
	An advanced, production-quality horror-game killer AI with:
	- Intelligent state machine (WANDERING, CHASING, SEARCHING, ATTACKING)
	- True line-of-sight detection with raycasting
	- Roblox PathfindingService integration
	- Multi-player target evaluation and switching
	- Limited, believable memory system
	- Smooth animation transitions
	- Robust stuck detection and recovery
	
	Place this script inside the NPC's HumanoidRootPart or as a child of the character.
]]

local PathfindingService = game:GetService("PathfindingService")
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

-- ============================================================================
-- CONFIGURATION
-- ============================================================================

local CONFIG = {
	-- Movement speeds
	WalkSpeed = 16,
	RunSpeed = 24,
	
	-- Detection
	DetectionRange = 100,
	FieldOfView = 120, -- degrees, ±60 from forward
	
	-- Searching
	SearchDuration = 8, -- seconds to search before giving up
	SearchRadius = 50,
	
	-- Pathfinding
	RepathInterval = 0.4, -- seconds between path recalculations
	TargetPositionUpdateThreshold = 5, -- distance player must move to trigger repath
	PathTimeout = 5, -- seconds before a path is considered failed
	
	-- Wandering
	WanderRadius = 100,
	WanderMinDistance = 30,
	
	-- Animations
	WalkAnimationId = "rbxassetid://112795495877676",
	RunAnimationId = "rbxassetid://113023472048096",
	AnimationPriority = Enum.AnimationPriority.Action,
	
	-- Combat
	KillRange = 5, -- distance at which NPC can kill on touch
	TouchCooldown = 0.5, -- seconds between allowed kills
}

-- ============================================================================
-- STATE ENUM
-- ============================================================================

local STATE = {
	WANDERING = "WANDERING",
	CHASING = "CHASING",
	SEARCHING = "SEARCHING",
	ATTACKING = "ATTACKING",
}

-- ============================================================================
-- KILLER NPC CLASS
-- ============================================================================

local KillerNPC = {}
KillerNPC.__index = KillerNPC

function KillerNPC.new(npcCharacter)
	local self = setmetatable({}, KillerNPC)
	
	-- Character references
	self.Character = npcCharacter
	self.Humanoid = npcCharacter:WaitForChild("Humanoid")
	self.RootPart = npcCharacter:WaitForChild("HumanoidRootPart")
	
	-- Ensure R6 structure
	assert(self.Humanoid, "NPC must have a Humanoid")
	assert(self.RootPart, "NPC must have a HumanoidRootPart")
	
	-- State machine
	self.CurrentState = STATE.WANDERING
	self.StateChanged = false
	
	-- Target tracking
	self.CurrentTarget = nil
	self.TargetLastSeenPosition = nil
	self.TargetLastSeenTime = 0
	self.SearchStartTime = 0
	self.LastTargetUpdateDistance = 0
	
	-- Pathfinding
	self.CurrentPath = nil
	self.PathWaypoints = {}
	self.PathIndex = 1
	self.LastPathTime = 0
	self.PathBlocked = false
	self.StuckCheckTime = 0
	self.LastStuckCheckPosition = self.RootPart.Position
	self.StuckDuration = 0
	
	-- Wandering
	self.WanderTarget = nil
	self.WanderUpdateTime = 0
	
	-- Animation
	self.CurrentAnimation = nil
	self.WalkTrack = nil
	self.RunTrack = nil
	self:_LoadAnimations()
	
	-- Combat
	self.LastKillTime = 0
	
	-- Update tracking
	self.LastUpdateTime = tick()
	self.DeltaTime = 0
	
	-- Connections
	self.Connections = {}
	
	-- Connect to humanoid events
	table.insert(self.Connections, self.Humanoid.Died:Connect(function()
		self:Destroy()
	end))
	
	-- Connect path blocked
	if self.CurrentPath then
		table.insert(self.Connections, self.CurrentPath.Blocked:Connect(function()
			self.PathBlocked = true
		end))
	end
	
	return self
end

-- ============================================================================
-- ANIMATION MANAGEMENT
-- ============================================================================

function KillerNPC:_LoadAnimations()
	local animator = self.Humanoid:WaitForChild("Animator")
	
	-- Create walk animation
	local walkAnim = Instance.new("Animation")
	walkAnim.AnimationId = CONFIG.WalkAnimationId
	self.WalkTrack = animator:LoadAnimation(walkAnim)
	self.WalkTrack.Priority = CONFIG.AnimationPriority
	self.WalkTrack.Looped = true
	
	-- Create run animation
	local runAnim = Instance.new("Animation")
	runAnim.AnimationId = CONFIG.RunAnimationId
	self.RunTrack = animator:LoadAnimation(runAnim)
	self.RunTrack.Priority = CONFIG.AnimationPriority
	self.RunTrack.Looped = true
end

function KillerNPC:_PlayAnimation(track)
	-- Stop existing animation
	if self.CurrentAnimation and self.CurrentAnimation ~= track then
		if self.CurrentAnimation.IsPlaying then
			self.CurrentAnimation:Stop()
		end
	end
	
	-- Play new animation
	if track and not track.IsPlaying then
		track:Play()
	end
	
	self.CurrentAnimation = track
end

function KillerNPC:_StopAllAnimations()
	if self.WalkTrack and self.WalkTrack.IsPlaying then
		self.WalkTrack:Stop()
	end
	if self.RunTrack and self.RunTrack.IsPlaying then
		self.RunTrack:Stop()
	end
	self.CurrentAnimation = nil
end

-- ============================================================================
-- LINE OF SIGHT / VISION SYSTEM
-- ============================================================================

function KillerNPC:_CanSeePoint(targetPoint, maxDistance)
	--[[
		Raycasts from the NPC's head region to a target point.
		Returns: (canSee: bool, hitPosition: Vector3)
	]]
	
	if not self.RootPart then return false, targetPoint end
	
	local distance = (targetPoint - self.RootPart.Position).Magnitude
	if distance > maxDistance then
		return false, targetPoint
	end
	
	-- Raycast from NPC's approximate eye level
	local rayOrigin = self.RootPart.Position + Vector3.new(0, 1.5, 0)
	local rayDirection = (targetPoint - rayOrigin).Unit * maxDistance
	
	local raycastParams = RaycastParams.new()
	raycastParams:AddToFilter(self.Character)
	raycastParams.FilterType = Enum.RaycastFilterType.Blacklist
	
	local rayResult = workspace:Raycast(rayOrigin, rayDirection, raycastParams)
	
	if rayResult then
		-- Something is in the way
		return false, rayResult.Position
	end
	
	-- Clear line of sight
	return true, targetPoint
end

function KillerNPC:_IsInFieldOfView(targetPosition)
	--[[
		Check if target is within the NPC's field of view.
		FOV is centered on the NPC's forward direction.
	]]
	
	local directionToTarget = (targetPosition - self.RootPart.Position).Unit
	local forwardDirection = self.RootPart.CFrame.LookVector
	
	-- Calculate angle between forward and target direction
	local dotProduct = forwardDirection:Dot(directionToTarget)
	local angle = math.deg(math.acos(math.clamp(dotProduct, -1, 1)))
	
	return angle <= (CONFIG.FieldOfView / 2)
end

function KillerNPC:CanSeePlayer(player)
	--[[
		Comprehensive check: is the player visible to the NPC?
		Returns: (isVisible: bool, visiblePosition: Vector3 or nil)
	]]
	
	if not player or not player.Character then
		return false, nil
	end
	
	local character = player.Character
	local humanoid = character:FindFirstChild("Humanoid")
	local humanoidRootPart = character:FindFirstChild("HumanoidRootPart")
	
	-- Verify character is alive and has required parts
	if not humanoid or not humanoidRootPart or humanoid.Health <= 0 then
		return false, nil
	end
	
	-- Check distance
	local distance = (humanoidRootPart.Position - self.RootPart.Position).Magnitude
	if distance > CONFIG.DetectionRange then
		return false, nil
	end
	
	-- Check field of view
	if not self:_IsInFieldOfView(humanoidRootPart.Position) then
		return false, nil
	end
	
	-- Check line of sight (raycast)
	local canSee, visiblePoint = self:_CanSeePoint(humanoidRootPart.Position, CONFIG.DetectionRange)
	
	return canSee, visiblePoint
end

-- ============================================================================
-- TARGET SELECTION & EVALUATION
-- ============================================================================

function KillerNPC:_FindBestTarget()
	--[[
		Evaluate all players and return the best target.
		Priority:
		1. Currently visible players (closest first)
		2. Last known position of current target if still searching
		3. None
	]]
	
	local visiblePlayers = {}
	local currentTime = tick()
	
	-- Scan all players
	for _, player in pairs(Players:GetPlayers()) do
		if player.Character then
			local canSee, visiblePos = self:CanSeePlayer(player)
			if canSee then
				local distance = (visiblePos - self.RootPart.Position).Magnitude
				table.insert(visiblePlayers, {
					Player = player,
					Distance = distance,
					VisiblePosition = visiblePos,
				})
			end
		end
	end
	
	-- Sort by distance
	table.sort(visiblePlayers, function(a, b)
		return a.Distance < b.Distance
	end)
	
	-- Return closest visible player
	if #visiblePlayers > 0 then
		return visiblePlayers[1].Player, visiblePlayers[1].VisiblePosition
	end
	
	-- No visible targets
	return nil, nil
end

function KillerNPC:_SelectNewTarget()
	--[[
		Intelligently select a new target.
		Prioritize visible players over searching.
	]]
	
	local target, visiblePos = self:_FindBestTarget()
	
	if target then
		self.CurrentTarget = target
		self.TargetLastSeenPosition = visiblePos
		self.TargetLastSeenTime = tick()
		return true
	end
	
	-- No valid target found
	self.CurrentTarget = nil
	self.TargetLastSeenPosition = nil
	
	return false
end

-- ============================================================================
-- PATHFINDING
-- ============================================================================

function KillerNPC:_CreatePath(targetPosition)
	--[[
		Create a new path from NPC to target position using PathfindingService.
	]]
	
	if not self.RootPart then return false end
	
	local startPosition = self.RootPart.Position
	
	-- Validate positions
	if (targetPosition - startPosition).Magnitude < 1 then
		return false -- Too close
	end
	
	-- Create path
	local path = PathfindingService:CreatePath({
		AgentRadius = 2,
		AgentHeight = 5,
		AgentCanJump = true,
		WaypointSpacing = 4,
	})
	
	-- Connect blocked signal
	local blockedConn
	blockedConn = path.Blocked:Connect(function(blockedWaypoint)
		self.PathBlocked = true
		blockedConn:Disconnect()
	end)
	table.insert(self.Connections, blockedConn)
	
	-- Compute path
	local success, errorMessage = pcall(function()
		path:ComputeAsync(startPosition, targetPosition)
	end)
	
	if not success or path.Status == Enum.PathStatus.NoPath then
		return false
	end
	
	if path.Status == Enum.PathStatus.Success then
		self.CurrentPath = path
		self.PathWaypoints = path:GetWaypoints()
		self.PathIndex = 1
		self.PathBlocked = false
		self.LastPathTime = tick()
		return true
	end
	
	return false
end

function KillerNPC:_FollowPath()
	--[[
		Move the NPC along the current path.
		Returns: true if path is still being followed, false if completed or failed.
	]]
	
	if not self.CurrentPath or #self.PathWaypoints == 0 then
		return false
	end
	
	-- Check if path is blocked
	if self.PathBlocked then
		return false
	end
	
	-- Check if path has timed out
	if tick() - self.LastPathTime > CONFIG.PathTimeout then
		return false
	end
	
	-- Get current waypoint
	if self.PathIndex > #self.PathWaypoints then
		return false -- Path complete
	end
	
	local waypoint = self.PathWaypoints[self.PathIndex]
	local distance = (waypoint.Position - self.RootPart.Position).Magnitude
	
	-- Move toward waypoint
	if distance > 4 then
		self.Humanoid:MoveTo(waypoint.Position)
	else
		-- Close enough to waypoint, move to next
		self.PathIndex = self.PathIndex + 1
		if self.PathIndex > #self.PathWaypoints then
			return false -- Path complete
		end
	end
	
	return true
end

function KillerNPC:_CalculateStuckDuration()
	--[[
		Detect if the NPC is stuck and return stuck duration in seconds.
	]]
	
	local currentTime = tick()
	if currentTime - self.StuckCheckTime < 0.5 then
		return self.StuckDuration
	end
	
	self.StuckCheckTime = currentTime
	
	local movementDistance = (self.RootPart.Position - self.LastStuckCheckPosition).Magnitude
	self.LastStuckCheckPosition = self.RootPart.Position
	
	if movementDistance < 1 then
		self.StuckDuration = self.StuckDuration + 0.5
	else
		self.StuckDuration = 0
	end
	
	return self.StuckDuration
end

function KillerNPC:_TryRecoverFromStuck()
	--[[
		Attempt to recover if the NPC has been stuck for too long.
	]]
	
	local stuckDuration = self:_CalculateStuckDuration()
	
	if stuckDuration > 3 then
		-- Force repath
		self.PathBlocked = true
		self.StuckDuration = 0
		return true
	end
	
	return false
end

-- ============================================================================
-- STATE: WANDERING
-- ============================================================================

function KillerNPC:_UpdateWandering()
	--[[
		Wander intelligently around the map.
	]]
	
	local currentTime = tick()
	
	-- Try to find a new target
	if self:_SelectNewTarget() then
		self:_TransitionToState(STATE.CHASING)
		return
	end
	
	-- Update wander target periodically
	if not self.WanderTarget or currentTime - self.WanderUpdateTime > 2 then
		self:_GenerateWanderTarget()
		self.WanderUpdateTime = currentTime
	end
	
	-- Follow wander target
	if self.WanderTarget then
		local distanceToWander = (self.WanderTarget - self.RootPart.Position).Magnitude
		
		if distanceToWander < 5 then
			-- Reached wander target
			self.WanderTarget = nil
		else
			-- Create path if needed
			if not self.CurrentPath or self.PathIndex > #self.PathWaypoints then
				self:_CreatePath(self.WanderTarget)
			end
			
			-- Follow path
			if not self:_FollowPath() then
				self:_CreatePath(self.WanderTarget)
			end
			
			-- Check stuck
			self:_TryRecoverFromStuck()
		end
	end
	
	-- Set animation
	self.Humanoid.WalkSpeed = CONFIG.WalkSpeed
	self:_PlayAnimation(self.WalkTrack)
end

function KillerNPC:_GenerateWanderTarget()
	--[[
		Generate a random wander destination using NavMesh.
	]]
	
	local attempts = 0
	
	while attempts < 5 do
		attempts = attempts + 1
		
		-- Random point in wander radius
		local angle = math.random() * math.pi * 2
		local distance = CONFIG.WanderMinDistance + math.random() * (CONFIG.WanderRadius - CONFIG.WanderMinDistance)
		
		local offsetX = math.cos(angle) * distance
		local offsetZ = math.sin(angle) * distance
		local targetPoint = self.RootPart.Position + Vector3.new(offsetX, 0, offsetZ)
		
		-- Try to find ground
		local raycastParams = RaycastParams.new()
		raycastParams:AddToFilter(self.Character)
		raycastParams.FilterType = Enum.RaycastFilterType.Blacklist
		
		local rayResult = workspace:Raycast(
			targetPoint + Vector3.new(0, 50, 0),
			Vector3.new(0, -100, 0),
			raycastParams
		)
		
		if rayResult then
			self.WanderTarget = rayResult.Position + Vector3.new(0, 3, 0)
			return
		end
	end
	
	-- Fallback: use offset directly
	self.WanderTarget = self.RootPart.Position + Vector3.new(
		math.random(-CONFIG.WanderRadius, CONFIG.WanderRadius),
		0,
		math.random(-CONFIG.WanderRadius, CONFIG.WanderRadius)
	)
end

-- ============================================================================
-- STATE: CHASING
-- ============================================================================

function KillerNPC:_UpdateChasing()
	--[[
		Chase the current target with pathfinding.
	]]
	
	if not self.CurrentTarget or not self.CurrentTarget.Character then
		self:_TransitionToState(STATE.WANDERING)
		return
	end
	
	-- Check if we can still see the target
	local targetChar = self.CurrentTarget.Character
	local targetHumanoidRootPart = targetChar:FindFirstChild("HumanoidRootPart")
	local targetHumanoid = targetChar:FindFirstChild("Humanoid")
	
	if not targetHumanoidRootPart or not targetHumanoid or targetHumanoid.Health <= 0 then
		self:_TransitionToState(STATE.WANDERING)
		return
	end
	
	local canSee, visiblePos = self:CanSeePlayer(self.CurrentTarget)
	
	if canSee then
		-- Update last seen position
		self.TargetLastSeenPosition = visiblePos
		self.TargetLastSeenTime = tick()
		self.SearchStartTime = tick()
		
		-- Check if target has moved significantly
		local positionChange = (visiblePos - (self.LastTargetUpdateDistance > 0 and self.TargetLastSeenPosition or visiblePos)).Magnitude
		
		if positionChange > CONFIG.TargetPositionUpdateThreshold or not self.CurrentPath or self.PathIndex > #self.PathWaypoints then
			-- Repath to target's current position
			if tick() - self.LastPathTime > CONFIG.RepathInterval then
				self:_CreatePath(visiblePos)
				self.LastTargetUpdateDistance = positionChange
			end
		end
		
		-- Check if we can kill the target
		local distanceToTarget = (targetHumanoidRootPart.Position - self.RootPart.Position).Magnitude
		if distanceToTarget < CONFIG.KillRange then
			self:_AttemptKill(self.CurrentTarget)
			return
		end
	else
		-- Lost line of sight
		self:_TransitionToState(STATE.SEARCHING)
		return
	end
	
	-- Follow path
	if not self:_FollowPath() then
		self:_CreatePath(self.TargetLastSeenPosition or targetHumanoidRootPart.Position)
	end
	
	-- Check stuck
	self:_TryRecoverFromStuck()
	
	-- Set animation and speed
	self.Humanoid.WalkSpeed = CONFIG.RunSpeed
	self:_PlayAnimation(self.RunTrack)
end

-- ============================================================================
-- STATE: SEARCHING
-- ============================================================================

function KillerNPC:_UpdateSearching()
	--[[
		Search for the target around last known position.
	]]
	
	if not self.TargetLastSeenPosition then
		self:_TransitionToState(STATE.WANDERING)
		return
	end
	
	local currentTime = tick()
	local searchElapsed = currentTime - self.SearchStartTime
	
	-- Check if search has timed out
	if searchElapsed > CONFIG.SearchDuration then
		self:_TransitionToState(STATE.WANDERING)
		return
	end
	
	-- Try to reacquire the target
	if self.CurrentTarget and self.CurrentTarget.Character then
		local canSee, visiblePos = self:CanSeePlayer(self.CurrentTarget)
		if canSee then
			self:_TransitionToState(STATE.CHASING)
			return
		end
	end
	
	-- Search around last known position
	local distanceToSearch = (self.TargetLastSeenPosition - self.RootPart.Position).Magnitude
	
	if distanceToSearch < 3 then
		-- Reached search point, wander around it
		local searchAngle = math.sin(currentTime) * 30
		local searchOffset = Vector3.new(
			math.cos(math.rad(searchAngle)) * CONFIG.SearchRadius,
			0,
			math.sin(math.rad(searchAngle)) * CONFIG.SearchRadius
		)
		
		local searchTarget = self.TargetLastSeenPosition + searchOffset
		
		if not self.CurrentPath or self.PathIndex > #self.PathWaypoints then
			self:_CreatePath(searchTarget)
		end
	else
		-- Move to last known position
		if not self.CurrentPath or self.PathIndex > #self.PathWaypoints then
			self:_CreatePath(self.TargetLastSeenPosition)
		end
	end
	
	-- Follow path
	if not self:_FollowPath() then
		self:_CreatePath(self.TargetLastSeenPosition)
	end
	
	-- Check stuck
	self:_TryRecoverFromStuck()
	
	-- Set animation and speed
	self.Humanoid.WalkSpeed = CONFIG.RunSpeed
	self:_PlayAnimation(self.RunTrack)
end

-- ============================================================================
-- ATTACKING / KILLING
-- ============================================================================

function KillerNPC:_AttemptKill(player)
	--[[
		Attempt to kill a player on contact.
	]]
	
	if not player or not player.Character then
		return false
	end
	
	local humanoid = player.Character:FindFirstChild("Humanoid")
	if not humanoid or humanoid.Health <= 0 then
		return false
	end
	
	-- Check kill cooldown
	if tick() - self.LastKillTime < CONFIG.TouchCooldown then
		return false
	end
	
	-- Kill the player
	humanoid.Health = 0
	self.LastKillTime = tick()
	
	-- Clear target and transition
	self.CurrentTarget = nil
	self.TargetLastSeenPosition = nil
	self:_TransitionToState(STATE.WANDERING)
	
	return true
end

-- ============================================================================
-- STATE MACHINE
-- ============================================================================

function KillerNPC:_TransitionToState(newState)
	--[[
		Transition to a new state.
	]]
	
	if self.CurrentState == newState then
		return
	end
	
	self.CurrentState = newState
	self.StateChanged = true
	
	-- Clear path on state transition for smooth behavior
	self.CurrentPath = nil
	self.PathWaypoints = {}
	self.PathIndex = 1
	self.PathBlocked = false
	
	if newState == STATE.WANDERING then
		self.SearchStartTime = 0
		self.CurrentTarget = nil
		self.TargetLastSeenPosition = nil
	elseif newState == STATE.SEARCHING then
		self.SearchStartTime = tick()
	end
end

function KillerNPC:Update()
	--[[
		Main update loop. Call this every heartbeat.
	]]
	
	if not self.Character or not self.Humanoid or self.Humanoid.Health <= 0 then
		return
	end
	
	-- Calculate delta time
	local currentTime = tick()
	self.DeltaTime = currentTime - self.LastUpdateTime
	self.LastUpdateTime = currentTime
	
	-- Update based on state
	if self.CurrentState == STATE.WANDERING then
		self:_UpdateWandering()
	elseif self.CurrentState == STATE.CHASING then
		self:_UpdateChasing()
	elseif self.CurrentState == STATE.SEARCHING then
		self:_UpdateSearching()
	end
	
	self.StateChanged = false
end

function KillerNPC:Destroy()
	--[[
		Cleanup and disconnect all events.
	]]
	
	self:_StopAllAnimations()
	self.Humanoid:MoveTo(self.RootPart.Position)
	
	for _, connection in pairs(self.Connections) do
		if connection then
			connection:Disconnect()
		end
	end
	
	self.Connections = {}
	self.CurrentPath = nil
	self.Character = nil
end

-- ============================================================================
-- INITIALIZATION
-- ============================================================================

-- Find the NPC character
local npcCharacter = script.Parent
if npcCharacter == workspace then
	-- Script might be in ServerScriptService
	npcCharacter = script.Parent.Parent
end

-- Create the AI
local killer = KillerNPC.new(npcCharacter)

-- Main loop
local connection
connection = RunService.Heartbeat:Connect(function()
	if killer.Character and killer.Humanoid.Health > 0 then
		killer:Update()
	else
		connection:Disconnect()
		killer:Destroy()
	end
end)

return killer
