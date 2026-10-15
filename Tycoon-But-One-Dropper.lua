--[[
    PuckAFK | Tycoon, but one dropper!  [UPD 4 | v1.9.1 - Core Reliability Hotfix]
    Based on a static inspection of place 109949693269081, the shared Config/Gear
    modules, client controllers, and a client remote trace dated 2026-10-14.

    IMPORTANT: Live server logic is not present in a client-side place dump.
    Server-side pad purchases, purchase confirmations, reward cooldowns and
    gear changes therefore need validation during an actual game session.

    No premium/Robux remotes are used. Uses the game's existing Action remote
    and legitimate near-pad/near-collectible movement where relevant.
--]]

if game.PlaceId ~= 109949693269081 then
    warn('[PuckAFK TBOD] Wrong place. Expected 109949693269081.')
    return
end
if not game:IsLoaded() then game.Loaded:Wait() end

local Players = game:GetService('Players')
local RS = game:GetService('ReplicatedStorage')
local TweenService = game:GetService('TweenService')
local HttpService = game:GetService('HttpService')
local LocalPlayer = Players.LocalPlayer
local Env = (type(getgenv) == 'function' and getgenv()) or _G
if type(Env.PuckTBOD31) == 'table' and type(Env.PuckTBOD31.Unload) == 'function' then
    pcall(Env.PuckTBOD31.Unload)
end

local Config = require(RS:WaitForChild('Shared'):WaitForChild('Config'))
local Gear = require(RS.Shared:WaitForChild('Gear'))
local Workers = require(RS.Shared:WaitForChild('Workers')) -- UPD 4 Hiring Agency
local Halloween = require(RS.Shared:WaitForChild('Halloween')) -- Witch's Hut 2026 event
local Remotes = RS:WaitForChild('Remotes')
local Action = Remotes:WaitForChild('Action')
local Net = Remotes:FindFirstChild('Net')
local Tycoons = workspace:WaitForChild('Tycoons')

local state = {
    alive = true, window = nil, moving = false, busyUntil = 0, tween = nil,
    connections = {}, throttles = {}, failures = {}, seenCodes = {},
    lastRebirth = 0, lastPadId = nil, lastPadAt = 0, worldAttempts = {},
    padConfirmed = false, lastBoughtAt = 0, lastGearRefresh = 0,
    padAcks = {}, padFailures = {}, worldAcks = {}, lastPlot = nil,
    rpcBusy = false, nextRpc = 0, rpcErrors = {},
    rpcActiveToken = 0, rpcBusySince = 0, rpcPending = 0, rpcRecoveries = 0,
    gear = nil, gearDirty = true, lastRebirthCount = tonumber(LocalPlayer:GetAttribute('Rebirths')) or 0,
    counters = {purchases = 0, rebirths = 0, quests = 0, gears = 0, crates = 0, perks = 0, cases = 0, obby = 0, spins = 0},
    gearSnapshotAt = 0, caseDecision = 'Waiting for gear data',
    lastCaseOpenedAt = 0, caseFailures = 0,
    extrasUntil = 0, nextExtrasAt = 0, extrasCycles = 0,
    obbyNextTryAt = 0, obbyFailures = 0, obbyLastReward = 0,
    obbyStatus = 'Not attempted', obbyAckAt = 0, wheelFailures = 0,
    lastGearAttempt = 0, lastWorldActivity = 0, nextIdleCollectAt = 0,
    lastPrioritySwitchAt = 0, idleSince = 0, fallbackCount = 0,
    pickupFailures = {}, idleSkippedExtras = 0, extrasJobs = 0,
    workers = nil, workersDirty = true, workersSnapshotAt = 0, workersStatus = 'Locked',
    workerFailures = 0, workerCases = 0, workerEquips = 0, workerUpgrades = 0,
    floorBuildUntil = 0, floorBuildRebirth = -1,
    eventStatus = 'Waiting for event', eventBrews = 0, eventPurchases = 0,
    eventPails = 0, eventSetEquips = 0, eventBrewResults = {},
    eventNextTryAt = 0, eventFailures = 0, eventLastBuyAt = 0,
    eventLastBrewAt = 0, eventPailLastAt = 0,
    eventLuckSwaps = 0, eventRestores = 0, eventRestoreFailures = 0,
    eventLastGearSnapshot = 0, eventNextRestore = 0,
    currentTask = 'Idle', lastTaskSwitch = 0, startupAt = 0,
    movementFailures = 0, characterChangedAt = 0,
    failedActions = {}, rebirthBlockedUntil = 0,


    status = 'Initialising', lastError = '',
}
Env.PuckTBOD31 = state

local opts = {
    AutoFarm = true, AutoBuyPads = true, ActivityPriority = 'Balanced',
    ExtrasInterval = 15, AutoObby = true, AutoBuildFloor3 = false,
    AutoRebirth = true, AutoPerks = true,
    AutoRewards = true, AutoQuests = true, AutoCodes = true, AutoGroupReward = true,
    AutoLostGears = true, AutoCrates = true, AutoPails = true,
    -- The old AutoHalloweenGear/AutoBrew values are retained for JSON profile
    -- compatibility; AutoHalloweenEvent and HalloweenGoal are the new controls.
    AutoHalloweenGear = true, AutoBrew = false, CandyReserve = 100,
    AutoHalloweenEvent = true, HalloweenGoal = 'Set then Brew',
    WearReaperSet = true, StopBrewAfterCrown = true,

    AutoEquipGear = true, AutoImproveGear = true, AutoFuseGear = true,
    AutoCases = true, AutoCaseLuck = true,
    AutoWorkers = true, AutoHireWorkers = true, AutoUpgradeWorkers = true,
    WorkerCaseType = 'Smart', WorkerTokenReserve = 30,
    CaseType = 'Smart', CaseReserve = 20,
    RebirthMode = 'Smart', BuyMode = 'Balanced',
    Movement = 'Instant', TweenSpeed = 175,
    PadDelay = 28, ReservePercent = 0,
    UseTouchInterest = true, AutoSalvage = false, MaxCollectibleDetour = 1000,
}

local function fmt(n)
    n = tonumber(n) or 0
    if n ~= n then return '?' end
    local abs = math.abs(n)
    if abs >= 1e15 then return string.format('%.2fQ', n / 1e15) end
    if abs >= 1e12 then return string.format('%.2fT', n / 1e12) end
    if abs >= 1e9 then return string.format('%.2fB', n / 1e9) end
    if abs >= 1e6 then return string.format('%.2fM', n / 1e6) end
    if abs >= 1e3 then return string.format('%.2fK', n / 1e3) end
    return tostring(math.floor(n * 100 + 0.5) / 100)
end
local function nattr(key)
    return tonumber(LocalPlayer:GetAttribute(key)) or 0
end
local function say(str)
    state.status = tostring(str)
end
local function notify(message)
    print('[PuckAFK TBOD] ' .. tostring(message))
    local ui = state.ui
    if ui and type(ui.Notify) == 'function' then
        pcall(function() ui:Notify({Title = 'Tycoon, but one dropper', Content = tostring(message), Duration = 3}) end)
    end
end
local function now() return os.clock() end
local function ready(key, delay)
    if (state.throttles[key] or 0) > now() then return false end
    state.throttles[key] = now() + (delay or 1)
    return true
end
-- Serialised server actions: avoids unrelated maintenance workers spamming
-- the same RemoteFunction on top of each other.
-- Bounded single-flight RPC. If InvokeServer never returns, a stale request
-- must not permanently freeze every reward, perk and gear operation. The
-- watchdog permits at most two outstanding requests, and obsolete replies
-- cannot clear a newer request's lock.
local function rpc(key, ...)
    if not state.alive then return {ok = false, msg = 'Unloaded'} end
    local args = table.pack(...)
    if state.rpcBusy and (now() - state.rpcBusySince) > 9 and state.rpcPending < 2 then
        state.rpcBusy = false
        state.rpcRecoveries = state.rpcRecoveries + 1
        state.lastError = 'Recovered stalled server action'
    end
    local waitUntil = now() + 0.85
    while state.alive and state.rpcBusy and now() < waitUntil do task.wait(0.035) end
    if not state.alive then return {ok = false, msg = 'Unloaded'} end
    if state.rpcBusy or state.rpcPending >= 2 then
        return {ok = false, msg = 'Server actions busy; retry later'}
    end
    state.rpcBusy = true
    state.rpcBusySince = now()
    state.rpcActiveToken = state.rpcActiveToken + 1
    local token = state.rpcActiveToken
    local waitUntilThrottle = now() + 4
    while state.alive and now() < state.nextRpc and now() < waitUntilThrottle do
        task.wait(0.04)
    end
    if not state.alive or now() < state.nextRpc then
        if state.rpcActiveToken == token then state.rpcBusy = false end
        return {ok = false, msg = 'Server action cooling down'}
    end
    local finished, worked, result = false, false, nil
    state.rpcPending = state.rpcPending + 1
    task.spawn(function()
        worked, result = pcall(function()
            return Action:InvokeServer(key, table.unpack(args, 1, args.n))
        end)
        finished = true
        state.rpcPending = math.max(0, state.rpcPending - 1)
        if state.rpcActiveToken == token then state.rpcBusy = false end
    end)
    local deadline = now() + 4
    while state.alive and not finished and now() < deadline do task.wait(0.045) end
    if not finished then
        state.lastError = 'Slow server response: ' .. tostring(key)
        state.nextRpc = math.max(state.nextRpc, now() + 0.8)
        return {ok = false, msg = 'Timed out waiting for ' .. tostring(key)}
    end
    if not worked then
        state.lastError = tostring(result)
        state.nextRpc = now() + 0.8
        return {ok = false, msg = tostring(result)}
    end
    local normalized = type(result) == 'table' and result or {ok = result == true, result = result}
    if normalized.msg == 'slow down' then
        state.nextRpc = now() + 0.8
    else
        state.nextRpc = now() + 0.16
    end
    return normalized
end
local function cleanConns()
    for _, c in ipairs(state.connections) do pcall(function() c:Disconnect() end) end
    table.clear(state.connections)
end

local function humanoidParts()
    local char = LocalPlayer.Character
    if not char then return nil, nil end
    local hum = char:FindFirstChildOfClass('Humanoid')
    local root = char:FindFirstChild('HumanoidRootPart')
    if hum and root and hum.Health > 0 and root.Parent then return hum, root end
    return nil, nil
end

local function findPlot()
    local plotId = tonumber(LocalPlayer:GetAttribute('PlotId'))
    if plotId and plotId >= 1 and plotId <= 8 then
        local plot = Tycoons:FindFirstChild('Plot' .. tostring(plotId))
        if plot and (plot:GetAttribute('OwnerId') == nil or tonumber(plot:GetAttribute('OwnerId')) == LocalPlayer.UserId) then
            return plot
        end
    end
    for _, p in ipairs(Tycoons:GetChildren()) do
        if p:IsA('Model') and tonumber(p:GetAttribute('OwnerId')) == LocalPlayer.UserId then return p end
    end
    return nil
end

local function canGo()
    local hum, root = humanoidParts()
    return state.alive and hum ~= nil and root ~= nil
end
local function moveNear(targetPos, maxDistance, yOffset)
    if not state.alive or typeof(targetPos) ~= 'Vector3' then return false end
    if state.moving then
        -- A previous movement may have been interrupted by respawn, streaming
        -- or an executor tween error. Never leave the farm locked forever.
        if now() - (state.movementStarted or 0) < 7 then return false end
        if state.tween then pcall(function() state.tween:Cancel() end) end
        state.moving, state.tween = false, nil
    end
    local hum, root = humanoidParts()
    if not hum or not root then return false end
    local destination = targetPos + Vector3.new(0, yOffset or 2.8, 0)
    local dist = (root.Position - destination).Magnitude
    if dist <= (maxDistance or 3) then return true end
    state.moving = true
    state.movementStarted = now()
    local arrived = false
    local moved, err = pcall(function()
        if opts.Movement == 'Tween' then
            local speed = math.clamp(tonumber(opts.TweenSpeed) or 175, 80, 400)
            local duration = dist / speed
            local tween = TweenService:Create(root, TweenInfo.new(duration, Enum.EasingStyle.Linear),
                {CFrame = CFrame.new(destination)})
            state.tween = tween
            tween:Play()
            local deadline = now() + math.min(duration + 0.6, 7)
            while state.alive and state.tween == tween and now() < deadline do
                if tween.PlaybackState ~= Enum.PlaybackState.Playing or not canGo() then break end
                task.wait(0.05)
            end
            if tween.PlaybackState == Enum.PlaybackState.Playing then tween:Cancel() end
        else
            root.AssemblyLinearVelocity = Vector3.zero
            root.AssemblyAngularVelocity = Vector3.zero
            root.CFrame = CFrame.new(destination)
            task.wait(0.10)
        end
        local _, nextRoot = humanoidParts()
        arrived = state.alive and nextRoot ~= nil and
            (nextRoot.Position - destination).Magnitude <= math.max(7, maxDistance or 3)
    end)
    if state.tween then pcall(function() state.tween:Cancel() end) end
    state.tween, state.moving = nil, false
    if not moved then
        state.movementFailures = state.movementFailures + 1
        state.lastError = 'Movement: ' .. tostring(err)
    elseif arrived then
        state.busyUntil = now() + 0.12
        state.movementFailures = 0
    else
        state.movementFailures = state.movementFailures + 1
    end
    return arrived
end

local function padPrice(pad)
    local value = tonumber(pad:GetAttribute('Price'))
    if value and value >= 0 then return value end
    return math.huge
end
local function availablePads(plot)
    local padsFolder = plot and plot:FindFirstChild('Pads')
    if not padsFolder then return {} end
    local candidates = {}
    local serverTime = workspace:GetServerTimeNow()
    state.nextConstruction = nil
    -- HUD/Intro use a special Item='Start' pad which is NOT in Config.ById.
    -- Specials are separately indexed at Config.SpecialById.
    for _, obj in ipairs(padsFolder:GetChildren()) do
        if obj:IsA('BasePart') then
            local id = obj:GetAttribute('Item')
            local buildAt = tonumber(obj:GetAttribute('BuildT')) or 0
            if buildAt > serverTime and (not state.nextConstruction or buildAt < state.nextConstruction) then
                state.nextConstruction = buildAt
            end
            if type(id) == 'string' and id ~= 'Group' and id ~= 'VIP' and buildAt <= serverTime then
                local item = id == 'Start' and {Name = 'Start Dropper', Cat = 'Start'} or
                    Config.ById[id] or (Config.SpecialById and Config.SpecialById[id])
                local price = id == 'Start' and (tonumber(obj:GetAttribute('Price')) or 0) or padPrice(obj)
                if item and not item.Pass and not item.Product and not item.Robux and
                    price >= 0 and price < math.huge then
                    table.insert(candidates, {part = obj, id = id, cost = price, item = item})
                end
            end
        end
    end
    return candidates
end

local function upgradeScore(c, cash, income, root)
    if c.id == 'Start' then return math.huge end
    if opts.BuyMode == 'Cheapest' then return -c.cost end
    local item = c.item
    local cat = item.Cat or c.id:sub(1, 1)
    local gain = 1
    for _, k in ipairs({'Mult', 'DV', 'DR', 'CM', 'GM'}) do
        local v = tonumber(item[k])
        if v and v > 1 then gain = gain * v end
    end
    if item.Ore then gain = gain * 2 end -- confirmed in Config.Compute
    if item.Cat == 'Z' and item.PerRebirth and nattr('Rebirths') > 0 then
        gain = gain * (1 + tonumber(item.PerRebirth) * nattr('Rebirths'))
    end
    if tonumber(item.Dup) then gain = gain * (1 + item.Dup) end
    if tonumber(item.Gold) then gain = gain * (1 + 9 * item.Gold) end
    if cat == 'S' or cat == 'E' or cat == 'F' then
        -- Expansions unlock many more income-producing pads.
        gain = math.max(gain, cat == 'S' and 1.6 or 2)
    end
    if cat == 'B' then gain = math.max(gain, 1.07) end
    -- UPD 4: Sky Pier (row 9) and Star Station (row 12) unlock
    -- additional production sections at rebirths 15-19. When a live
    -- expansion pad is affordable, prefer opening a whole new section.
    if cat == 'F' and tonumber(item.SkyRows) and item.SkyRows >= 9 then
        gain = math.max(gain, 3.1)
    end
    -- Purchase-pad prices can vary after discounts. Score by the live cost.
    -- Important: don't let an unaffordable expensive expansion stop cheap upgrades.
    local budget = math.max(1, tonumber(income) or 0)
    local seconds = c.cost / budget
    local score = (math.log(math.max(1.005, gain)) * 12) / math.pow(1 + seconds / 12, 0.58)
    if opts.BuyMode == 'Highest Value' then
        score = math.log(math.max(1.005, gain)) * (1 + math.log10(math.max(1, c.cost))) /
            (1 + seconds / 25)
    end
    if root and c.part then
        -- Reduce zig-zagging between distant machine rows when values are similar.
        local travel = (root.Position - c.part.Position).Magnitude / math.max(80, opts.TweenSpeed)
        score = score / (1 + travel * 0.055)
    end
    return score
end

local function getBestPad(plot, cash, income)
    local choices = availablePads(plot)
    local best, bestScore = nil, -math.huge
    local reserve = cash * (math.clamp(opts.ReservePercent, 0, 75) / 100)
    local nextCost = math.huge
    local _, root = humanoidParts()
    for _, item in ipairs(choices) do
        nextCost = math.min(nextCost, item.cost)
        local failedUntil = state.failures['pad:' .. item.id] or 0
        if item.cost <= cash - reserve and failedUntil <= now() then
            local score = upgradeScore(item, cash, income, root)
            -- Deterministic tie-break removes pad oscillation.
            if score > bestScore + 0.000001 or
                (best and math.abs(score - bestScore) <= 0.000001 and
                    (item.cost < best.cost or (item.cost == best.cost and item.id < best.id))) then
                best, bestScore = item, score
            end
        end
    end
    return best, nextCost, #choices
end

local function buyPad(plot, candidate)
    if not opts.AutoBuyPads or opts.ActivityPriority == 'Extras Only' then return false end
    if not candidate or not candidate.part or not candidate.part.Parent then return false end
    if not plot or findPlot() ~= plot then return false end
    local part, id = candidate.part, candidate.id
    -- Preserve cash for the selected token goal once the basic rebirth is affordable.
    if id ~= 'Start' and opts.AutoRebirth and nattr('RebirthCost') > 0 and
        nattr('Cash') >= nattr('RebirthCost') and not floor3Focus() and
        now() >= (state.rebirthBlockedUntil or 0) then return false end
    if part:GetAttribute('Item') ~= id then return false end
    if id ~= 'Start' and padPrice(part) > nattr('Cash') then return false end
    if (tonumber(part:GetAttribute('BuildT')) or 0) > workspace:GetServerTimeNow() then return false end
    if candidate.cost > nattr('Cash') then return false end
    local oldCash = nattr('Cash')
    local ackAt = state.padAcks[id] or 0
    local startAt = now()
    say('Upgrading: ' .. (candidate.item.Name or id) .. ' ($' .. fmt(candidate.cost) .. ')')
    local top = part.Position + Vector3.new(0, part.Size.Y * 0.5, 0)
    if not moveNear(top, 2, 2.5) then return false end
    local _, root = humanoidParts()
    if not root or not state.alive or not opts.AutoBuyPads or opts.ActivityPriority == 'Extras Only' or not part.Parent then return false end
    -- The game's server accepts pad touches; we do not invent a BuyPad action.
    if opts.UseTouchInterest and type(firetouchinterest) == 'function' then
        pcall(function()
            firetouchinterest(root, part, 0)
            task.wait(0.035)
            if state.alive then firetouchinterest(root, part, 1) end
        end)
    end
    if state.alive and part.Parent and part:IsDescendantOf(plot) then
        root.CFrame = CFrame.new(top + Vector3.new(0, 1.0, 0))
        task.wait(0.13)
    end
    local limit = now() + math.clamp(opts.PadDelay / 100, 0.15, 1.0)
    repeat
        if not state.alive or not part.Parent then break end
        if part:GetAttribute('Item') ~= id or (state.padAcks[id] or 0) > ackAt then break end
        task.wait(0.06)
    until now() >= limit
    -- Cash alone cannot prove a pad purchase: passive rewards / other actions
    -- may change it concurrently. Prefer Bought event or a removed/changed pad.
    local acked = (state.padAcks[id] or 0) > ackAt and
        (state.padAcks[id] or 0) >= startAt
    local removed = part.Parent == nil or part:GetAttribute('Item') ~= id
    local changedCash = candidate.cost > 0 and nattr('Cash') < oldCash
    if acked or removed then
        state.counters.purchases = state.counters.purchases + 1
        state.failures['pad:' .. id] = nil
        state.padFailures[id] = nil
        state.lastBoughtAt = now()
        return true
    end
    local fails = math.min(5, (state.padFailures[id] or 0) + 1)
    state.padFailures[id] = fails
    local backoff = math.min(35, 1.75 * 2 ^ (fails - 1))
    -- A cash delta without server ACK can be replication lag; retry after a
    -- short cooldown rather than falsely marking the upgrade as purchased.
    if changedCash then backoff = math.min(backoff, 2.5) end
    state.failures['pad:' .. id] = now() + backoff
    return false
end

local perkPriority = {'Value', 'Rate', 'Starter', 'Bargain', 'Cash', 'Conveyor',
    'Rush', 'Momentum', 'Tokens', 'Gold', 'Mystery', 'Shrine', 'Crates',
    'Spins', 'Jackpot', 'Scrap', 'Speed', 'Offline', 'LongShift',
    'CatchUp', 'LuckyFinds', 'TowerChamp', 'Jubilee', 'NightCrew'}
local function buyPerk()
    if not opts.AutoPerks or not ready('perk', 1.5) then return end
    -- Actual balance is Tokens, not Perk_Tokens; latter is a bool for the Token perk.
    local tokens = nattr('Tokens')
    if tokens < 2 then return end
    for _, key in ipairs(perkPriority) do
        local item = Config.PerkByKey and Config.PerkByKey[key]
        if item then
            local level = 0
            local maxLevel = 1
            if type(item.Levels) == 'table' then
                level = tonumber(LocalPlayer:GetAttribute('PerkLv_' .. key)) or 0
                maxLevel = #item.Levels
            elseif LocalPlayer:GetAttribute('Perk_' .. key) == true then
                level = 1
            end
            local cost = item.Levels and tonumber(item.Levels[level + 1]) or tonumber(item.Cost)
            if level < maxLevel and cost and cost <= tokens and ready('perk:' .. key, 6) then
                local res = rpc('BuyPerk', key)
                if res.ok then
                    state.counters.perks = state.counters.perks + 1
                    state.throttles.perk = now() + 0.5
                    say('Permanent perk: ' .. (item.Name or key))
                    return
                end
                state.throttles['perk:' .. key] = now() + 25
            end
        end
    end
end

-- Optional UPD 4 showcase mode: let new floor expansions run for a short
-- limited session when first entering each new rebirth tier. Off by default
-- to preserve the user's fast-rebirth progression preference.
local function floor3Focus()
    if not opts.AutoBuildFloor3 or nattr('Rebirths') < 15 then return false end
    local r = nattr('Rebirths')
    if state.floorBuildRebirth ~= r then
        state.floorBuildRebirth = r
        state.floorBuildUntil = now() + 75
    end
    return now() < state.floorBuildUntil
end
local function rebirthMultiplier()
    if opts.RebirthMode == 'Extra Tokens' then return 4 end
    if opts.RebirthMode == 'Balanced' then return 2 end
    if opts.RebirthMode ~= 'Smart' then return 1 end
    -- Adaptive: only wait for bonus token thresholds if passive production
    -- can reach them quickly. Otherwise rebirth now and unlock the next run.
    local cost, cash, income = nattr('RebirthCost'), nattr('Cash'), nattr('Income')
    if cost <= 0 or cash < cost then return 1 end
    if income <= 0 then return 1 end
    if (4 * cost - cash) / income <= 18 then return 4 end
    if (2 * cost - cash) / income <= 9 then return 2 end
    return 1
end
local function rebirthTick()
    if not opts.AutoFarm or not opts.AutoRebirth or not ready('rebirth-scan', 0.55) then return false end
    if floor3Focus() then return false end
    local cost = nattr('RebirthCost')
    local cash = nattr('Cash')
    local target = cost * rebirthMultiplier()
    if cost <= 0 or cash < target or now() - state.lastRebirth < 6 then return false end
    -- Rebirth is a normal in-game action; it isn't the monetised AutoRebirth entitlement.
    state.lastRebirth = now()
    say('Rebirthing ($' .. fmt(cash) .. '/' .. fmt(cost) .. ')')
    local response = rpc('Rebirth')
    if response.ok then
        state.counters.rebirths = state.counters.rebirths + 1
        table.clear(state.failures)
        state.lastPadAt = 0
        state.lastPadId = nil
        say('Rebirth completed')
        task.wait(0.6)
        return true
    end
    state.lastError = tostring(response.msg or 'Rebirth was not accepted')
    -- Server can reject a rebirth even when the client has enough cash.
    -- Resume factory work temporarily rather than indefinitely saving.
    state.rebirthBlockedUntil = now() + 12
    state.throttles['rebirth-scan'] = now() + 3
    return false
end

local function questTick()
    if not opts.AutoQuests or not ready('quests', 11) then return end
    local result = rpc('Quests')
    if not result.ok then return end
    for _, kind in ipairs({'Daily', 'Weekly', 'Ach'}) do
        for _, quest in ipairs(type(result[kind]) == 'table' and result[kind] or {}) do
            if quest.Key and not quest.Claimed and tonumber(quest.Goal) and tonumber(quest.Prog)
                and tonumber(quest.Prog) >= tonumber(quest.Goal) then
                if state.alive and ready('quest:' .. kind .. ':' .. tostring(quest.Key), 24) then
                    local claim = rpc('ClaimQuest', kind, quest.Key)
                    if claim.msg == 'slow down' then task.wait(0.18); claim = rpc('ClaimQuest', kind, quest.Key) end
                    if claim.ok then
                        state.counters.quests = state.counters.quests + 1
                        say('Claimed ' .. string.lower(kind) .. ' quest')
                    end
                    task.wait(0.13)
                end
            end
        end
    end
end

local function rewardsTick()
    if not opts.AutoRewards then return end
    -- Daily interval is 20 hours with a 48-hour grace period. The server has final say.
    if ready('daily', 55) then
        local last = nattr('DailyLast')
        local current = workspace:GetServerTimeNow()
        if last <= 0 or current - last >= (Config.DailyCooldown or 72000) - 3 then
            local result = rpc('ClaimDaily')
            if result.ok then say('Claimed daily reward') end
        end
    end
    if opts.AutoGroupReward and not state.groupAttempted and ready('group-reward', 15) then
        local member = false
        if Config.Group and tonumber(Config.Group.Id) then
            local ok, result = pcall(function() return LocalPlayer:IsInGroup(Config.Group.Id) end)
            member = ok and result == true
        end
        if member then
            local claim = rpc('ClaimGroup')
            if claim.ok then
                state.groupAttempted = true
                say('Claimed free group reward')
            else
                state.throttles['group-reward'] = now() + 300
            end
        end
    end
    -- Client wheel UI allows a *free* spin after WheelNext, even if
    -- WheelSpins is zero. v1.3 ignored this and skipped recurring free spins.
    local wheelNext = nattr('WheelNext')
    local freeSpinReady = wheelNext <= workspace:GetServerTimeNow()
    if nattr('Income') > 0 and (nattr('WheelSpins') > 0 or freeSpinReady)
        and ready('spin', 2.5) then
        local result = rpc('Spin')
        if result.ok then
            state.wheelFailures = 0
            state.counters.spins = state.counters.spins + 1
            say('Collected free wheel spin')
        else
            -- Avoid repeatedly invoking when the server rejects an early spin.
            state.wheelFailures = math.min(6, state.wheelFailures + 1)
            state.throttles.spin = now() + math.min(80, 4 * (2 ^ (state.wheelFailures - 1)))
        end
    end
end
local function codesTick()
    if not opts.AutoCodes or not ready('codes', 30) then return end
    -- UPD 4 adds WORKERS, UPDATE4 and 1MILVISITS. Other codes may expire.
    local all = {'WORKERS','UPDATE4','1MILVISITS','BOOST','FREE','RELEASE'}
    for code in pairs(Config.Codes or {}) do
        local exists = false
        for _, value in ipairs(all) do if value == code then exists = true break end end
        if not exists then table.insert(all, code) end
    end
    for _, code in ipairs(all) do
        if not state.alive then return end
        if not state.seenCodes[code] then
            state.seenCodes[code] = true
            local res = rpc('Redeem', code)
            if res.ok then say('Redeemed free code ' .. code) end
            task.wait(0.18)
        end
    end
end

local function lostGearTarget()
    local folder = workspace:FindFirstChild('LostGears')
    if not folder then return nil end
    local _, root = humanoidParts()
    if not root then return nil end
    local nearest, bestDist = nil, math.huge
    for _, model in ipairs(folder:GetChildren()) do
        local index = tonumber(model.Name:match('^LostGear(%d+)$'))
        local spot = model:GetAttribute('Spot')
        local lost = state.gear and state.gear.Lost
        -- Skip rewards already completed in the current collection round.
        local alreadyOwned = index and type(lost) == 'table' and
            (lost['g' .. index] == true or lost[index] == true or lost[tostring(index)] == true)
        if index and not alreadyOwned and typeof(spot) == 'Vector3'
            and (state.worldAttempts['gear:' .. index] or 0) <= now() then
            local dist = (root.Position - spot).Magnitude
            if dist < bestDist then
                bestDist, nearest = dist, {kind = 'gear', key = 'gear:' .. index, index = index, pos = spot, obj = model}
            end
        end
    end
    return nearest
end

local function pickupCenter(model)
    -- Crates and pails have decorative 90-stud beams. Model:GetPivot()
    -- can target the BEAM midpoint, tens of studs above the real pickup.
    local first = model:FindFirstChildWhichIsA('BasePart')
    return first and first.Position or model:GetPivot().Position
end

local function worldTarget(allowGear, maxDetour, forceGear, forcePail)
    if state.moving then return nil end
    local _, root = humanoidParts()
    if not root then return nil end
    maxDetour = tonumber(maxDetour) or opts.MaxCollectibleDetour
    local targets = {}
    if opts.AutoCrates then
        local crate = workspace:FindFirstChild('MysteryCrate')
        if crate and crate:IsA('Model') and (state.worldAttempts['crate'] or 0) <= now() then
            targets[#targets + 1] = {kind='crate', key='crate', pos=pickupCenter(crate), obj=crate}
        end
    end
    if opts.AutoPails and workspace:GetAttribute('HalloweenOn') == true then
        local pail = workspace:FindFirstChild('CandyPail')
        if pail and pail:IsA('Model') and (state.worldAttempts['pail'] or 0) <= now() then
            targets[#targets + 1] = {kind='pail', key='pail', pos=pickupCenter(pail), obj=pail}
        end
    end
    if allowGear and opts.AutoLostGears then
        local candidate = lostGearTarget()
        if candidate then targets[#targets + 1] = candidate end
    end
    local best, closest, gearChoice, gearDist = nil, math.huge, nil, math.huge
    for _, target in ipairs(targets) do
        local dist = (root.Position - target.pos).Magnitude
        if dist <= maxDetour then
            if dist < closest then best, closest = target, dist end
            if target.kind == 'gear' and dist < gearDist then
                gearChoice, gearDist = target, dist
            end
        end
    end
    -- A continuous supply of crates can otherwise prevent lost-gear rounds.
    -- Give gears an explicit service slot every 12 seconds when available.
    if forcePail then
        for _, candidate in ipairs(targets) do
            if candidate.kind == 'pail' and
                (root.Position - candidate.pos).Magnitude <= maxDetour then
                return candidate
            end
        end
        return nil
    end
    if forceGear then return gearChoice end
    if opts.AutoPails and workspace:GetAttribute('HalloweenOn') == true then
        for _, candidate in ipairs(targets) do
            if candidate.kind == 'pail' and
                (root.Position - candidate.pos).Magnitude <= maxDetour then return candidate end
        end
    end
    if gearChoice and now() - state.lastGearAttempt >= 10 then return gearChoice end
    return best
end

local function worldTick(allowGear, maxDetour, forceGear, forcePail)
    if not state.alive or not canGo() or now() < state.busyUntil then return false end
    local target = worldTarget(allowGear, maxDetour, forceGear, forcePail)
    if not target then return false end
    if target.kind == 'gear' then state.lastGearAttempt = now() end
    local delay = target.kind == 'gear' and 4 or 3
    state.worldAttempts[target.key] = now() + delay
    say('Collecting ' .. (target.kind == 'crate' and 'mystery crate' or
        target.kind == 'pail' and 'candy pail' or 'lost gear'))
    local ackBefore = state.worldAcks[target.key] or 0
    local moved = moveNear(target.pos, 3, 0.6)
    if not moved then
        local failures = math.min(5, (state.pickupFailures[target.key] or 0) + 1)
        state.pickupFailures[target.key] = failures
        state.worldAttempts[target.key] = now() + math.min(120, 8 * 2 ^ (failures - 1))
        return true -- failed movement backs off; try another activity
    end
    local succeeded = false
    if target.kind == 'gear' then
        -- LostGears/LostGearN are local decorations. The game's GearUI actually
        -- calls Action('LostGear', index) after approaching the Spot.
        -- Merely teleporting to the model does NOT collect the reward.
        local _, root = humanoidParts()
        if root and (root.Position - target.pos).Magnitude < 5.9 then
            local result = rpc('LostGear', target.index)
            succeeded = result.ok == true
            if succeeded then
                state.worldAcks[target.key] = now()
                state.gearDirty = true
                state.counters.gears = state.counters.gears + 1
                -- An accepted gear stays visually visible on some clients.
                -- Wait for refreshed GearData, or a new collection round.
                state.worldAttempts[target.key] = now() + 90
                state.pickupFailures[target.key] = nil
                say('Collected lost gear #' .. tostring(target.index))
            else
                local failures = math.min(5, (state.pickupFailures[target.key] or 0) + 1)
                state.pickupFailures[target.key] = failures
                state.worldAttempts[target.key] = now() + math.min(180, 12 * 2 ^ (failures - 1))
            end
        end
    else
        -- Crates/pails are proximity-based; only the server Got flag counts.
        local deadline = now() + 1.1
        repeat
            if not state.alive or (state.worldAcks[target.key] or 0) > ackBefore
                or not target.obj.Parent then break end
            task.wait(0.10)
        until now() >= deadline
        succeeded = (state.worldAcks[target.key] or 0) > ackBefore
        if succeeded then
            state.pickupFailures[target.key] = nil
            state.worldAttempts[target.key] = now() + 6
        else
            local failures = math.min(4, (state.pickupFailures[target.key] or 0) + 1)
            state.pickupFailures[target.key] = failures
            state.worldAttempts[target.key] = now() + math.min(90, 7 * 2 ^ (failures - 1))
        end
    end
    if succeeded then
        state.extrasJobs = state.extrasJobs + 1
        if target.kind == 'pail' then
            state.eventStatus = 'Collected Halloween candy pail'
        end
    end
    state.lastWorldActivity = now()
    return true -- an attempted collectible trip is useful work, including failed/denied trips
end

-- Obby markers were confirmed in the uploaded RBXL as AttributesSerialize
-- `ObbyReward = true` (two tower reward pads); ObbyNext is player cooldown.
-- The server is authoritative. A teleport or client touch is NOT proof of reward.
local function obbyRewardPart()
    local world = workspace:FindFirstChild('World')
    local obby = world and world:FindFirstChild('Obby')
    if not obby then return nil end
    local _, root = humanoidParts()
    if not root then return nil end
    local best, bestCost = nil, math.huge
    for _, obj in ipairs(obby:GetDescendants()) do
        if obj:IsA('BasePart') and obj:GetAttribute('ObbyReward') == true then
            -- Two reward triggers exist; favor nearby eligible finish pads.
            local travel = (root.Position - obj.Position).Magnitude
            local cost = travel + (obj.CanTouch and 0 or 100)
            if cost < bestCost then best, bestCost = obj, cost end
        end
    end
    return best
end

local function obbyTick()
    if not opts.AutoObby or not state.alive or not canGo() or state.moving
        or now() < state.obbyNextTryAt then return false end
    local serverTime = workspace:GetServerTimeNow()
    local oldNext = nattr('ObbyNext')
    local oldAck = state.obbyAckAt or 0
    if oldNext > serverTime + 1 then
        state.obbyStatus = 'Cooldown ' .. tostring(math.ceil(oldNext - serverTime)) .. 's'
        state.obbyNextTryAt = now() + math.min(30, math.max(3, oldNext - serverTime - 1))
        return false
    end
    local reward = obbyRewardPart()
    if not reward then
        state.obbyStatus = 'Reward trigger not streamed in'
        state.obbyNextTryAt = now() + 20
        return false
    end
    -- Directly reach the ObbyReward platform. Never target an arbitrary tallest
    -- decoration, which can be above the real reward pad.
    state.obbyStatus = 'Teleporting to reward'
    say('Obby: visiting finish reward')
    state.obbyNextTryAt = now() + 10
    local target = reward.Position + Vector3.new(0, reward.Size.Y * 0.5, 0)
    if not moveNear(target, 3, 2.1) then
        state.obbyStatus = 'Cannot reach reward'
        state.obbyNextTryAt = now() + 30
        return true
    end
    if not state.alive or not reward.Parent then return true end
    local _, root = humanoidParts()
    if not root then return true end
    -- A normal short contact plus touch fallback, with no invented reward RPC.
    root.AssemblyLinearVelocity = Vector3.zero
    root.CFrame = CFrame.new(reward.Position + Vector3.new(0, math.min(2.2, reward.Size.Y * 0.5 + 1.4), 0))
    if opts.UseTouchInterest and type(firetouchinterest) == 'function' then
        pcall(function()
            firetouchinterest(root, reward, 0)
            task.wait(0.06)
            if state.alive and reward.Parent then firetouchinterest(root, reward, 1) end
        end)
    end
    local deadline = now() + 2.4
    while state.alive and now() < deadline do
        if (state.obbyAckAt or 0) > oldAck or
            nattr('ObbyNext') > math.max(oldNext, serverTime) + 1 then break end
        task.wait(0.12)
    end
    local rewarded = (state.obbyAckAt or 0) > oldAck or
        nattr('ObbyNext') > math.max(oldNext, serverTime) + 1
    if rewarded then
        state.counters.obby = state.counters.obby + 1
        state.obbyFailures = 0
        state.obbyLastReward = now()
        state.obbyStatus = 'Reward collected'
        state.obbyNextTryAt = now() + 10
        say('Obby reward claimed')
    else
        state.obbyFailures = math.min(5, state.obbyFailures + 1)
        state.obbyNextTryAt = now() + math.min(180, 15 * 2 ^ (state.obbyFailures - 1))
        state.obbyStatus = 'No server confirmation; retry later'
    end
    return true
end

-- New Witch's Hut controller, sourced from Shared.Halloween and HalloweenUI.
-- Candy comes from pumpkins on the conveyor, pails, rebirths and playtime;
-- server-side production is automatic and must not be spoofed.
local function eventOn()
    return Halloween and Halloween.On() and workspace:GetAttribute('HalloweenOn') == true
end
local function reaperOwned(snapshot)
    if not snapshot or type(snapshot.I) ~= 'table' then return false end
    local set = Gear.SetByKey and Gear.SetByKey.Reaper
    if not set then return false end
    for _, id in ipairs(set.Pieces or {}) do
        if not snapshot.I[id] then return false end
    end
    return true
end
local function eventNeedsBrew(snapshot)
    if not snapshot or type(snapshot.I) ~= 'table' then return true end
    local limited = Halloween.Brew and Halloween.Brew.Limited
    local rare = Halloween.Brew and Halloween.Brew.Rare
    -- Complete BOTH unique brew prizes. A lucky early Crown should not
    -- strand the Mummy Wraps pity reward unfinished.
    if opts.StopBrewAfterCrown and limited and rare and
        snapshot.I[limited] and snapshot.I[rare] then return false end
    return true
end
local function halloweenTick()
    if not opts.AutoHalloweenEvent or not state.alive then return end
    if not eventOn() then
        state.eventStatus = 'Event is currently inactive'
        return
    end
    if now() < state.eventNextTryAt or not ready('event-plan', 2.5) then return end
    local inv = state.gear
    local goal = opts.HalloweenGoal
    local candy = nattr('Candy')
    if not inv or type(inv.I) ~= 'table' or type(inv.E) ~= 'table' or
        state.gearDirty or now() - state.gearSnapshotAt > 24 then
        state.eventStatus = 'Refreshing Witch gear inventory'
        return
    end
    local missing, nextItem, wantedTotal = 0, nil, 0
    for _, item in ipairs(Halloween.Shop or {}) do
        if not inv.I[item.Id] then
            missing = missing + 1
            wantedTotal = wantedTotal + (tonumber(item.Cost) or 0)
            if not nextItem or (tonumber(item.Cost) or math.huge) < nextItem.Cost then
                nextItem = item
            end
        end
    end
    local shopFirst = goal == 'Set then Brew' or goal == 'Set Only' or
        (goal == 'Brew First' and not eventNeedsBrew(inv))
    local buyEventGear = goal ~= 'Brew Only'
    local doBrew = goal ~= 'Set Only'
    if buyEventGear and missing > 0 and (shopFirst or candy < (Halloween.Brew.Cost or 75)) then
        -- Buy only *unowned* event items, in ascending cost order. Never spend
        -- any candy reserved for an affordable missing Reaper item on brews.
        if nextItem and candy >= nextItem.Cost then
            if not ready('witch-buy:' .. nextItem.Id, 5) then return end
            local reply = rpc('HalloweenBuy', nextItem.Id)
            if reply.ok then
                state.eventPurchases = state.eventPurchases + 1
                state.eventLastBuyAt = now()
                state.eventFailures = 0
                state.gearDirty = true
                state.eventLastGearSnapshot = state.gearSnapshotAt
                state.eventNextTryAt = now() + 2.7
                state.eventStatus = 'Purchased ' .. (Gear.ById[nextItem.Id] and Gear.ById[nextItem.Id].Name or nextItem.Id) ..
                    ' (' .. (4 - missing + 1) .. '/4)'
                say("Witch's Hut: " .. state.eventStatus)
            else
                state.eventFailures = math.min(5, state.eventFailures + 1)
                state.eventNextTryAt = now() + math.min(90, 6 * 2 ^ (state.eventFailures - 1))
                state.eventStatus = 'Event purchase rejected; retrying later'
            end
        else
            state.eventStatus = ('Saving candy for Reaper (%s/%s next; %s total remaining)')
                :format(fmt(candy), fmt(nextItem and nextItem.Cost or 0), fmt(wantedTotal))
        end
        return
    end
    if missing == 0 and opts.WearReaperSet and reaperOwned(inv) then
        local equipped = Gear.Total({I = inv.I, E = inv.E})
        if not (equipped.Sets and equipped.Sets.Reaper) and ready('witch-set', 8) then
            local result = rpc('GearEquipSet', 'Reaper')
            if result.ok then
                state.eventSetEquips = state.eventSetEquips + 1
                state.gearDirty = true
                state.eventNextTryAt = now() + 2.6
                state.eventStatus = 'Equipped Reaper: +40% candy'
            else
                state.throttles['witch-set'] = now() + 25
            end
            return
        end
    end
    if doBrew and eventNeedsBrew(inv) then
        local cost = tonumber(Halloween.Brew and Halloween.Brew.Cost) or 75
        local reserve = math.max(0, tonumber(opts.CandyReserve) or 0)
        -- In Brew First mode, preserve the explicitly requested reserve only.
        -- In Set then Brew mode, all shop items must already be owned.
        if candy < cost + reserve then
            state.eventStatus = ('Saving for brew (%s/%s candy, pity %s/%s)')
                :format(fmt(candy), fmt(cost + reserve), fmt(nattr('BrewPity')),
                    fmt(Halloween.Brew.Pity or 15))
            return
        end
        if not ready('witch-brew', 6) then return end
        local result = rpc('HalloweenBrew')
        if result.ok then
            local rewardKey = tostring(result.Key or 'Unknown')
            state.eventBrewResults[rewardKey] = (state.eventBrewResults[rewardKey] or 0) + 1
            state.eventBrews = state.eventBrews + 1
            state.eventLastBrewAt = now()
            state.eventFailures = 0
            state.eventNextTryAt = now() + 3.5
            if rewardKey == 'Rare' or rewardKey == 'Limited' then state.gearDirty = true end
            state.eventStatus = ('Brew #%d: %s'):format(state.eventBrews, rewardKey)
            say("Witch's Hut: " .. state.eventStatus)
        else
            state.eventFailures = math.min(5, state.eventFailures + 1)
            state.eventNextTryAt = now() + math.min(90, 6 * 2 ^ (state.eventFailures - 1))
            state.eventStatus = 'Cauldron rejected request; cooling down'
        end
        return
    end
    state.eventStatus = not eventNeedsBrew(inv) and 'Mummy Wraps + Pumpkin King obtained; brew complete'
        or (missing == 0 and 'Reaper complete; event goals reached' or
           ('Saving event gear (%d pieces remaining)'):format(missing))
end

local gearWeights = {Cash=3, Drop=3, Luck=15, Double=2.5,
    Rebirth=2.5, Scrap=0.7, Speed=0.08}
local function loadoutScore(inventory, equipped)
    local summary = Gear.Total({I=inventory, E=equipped})
    local score = 0
    for key, weight in pairs(gearWeights) do
        score = score + (tonumber(summary.Stats and summary.Stats[key]) or 0) * weight
    end
    score = score + (tonumber(summary.Overload) or 0) * 7 +
        (tonumber(summary.Candy) or 0) * 2 + (summary.Glitch and 5 or 0)
    return score
end
local function bestLoadout(inventory, equipped)
    local choices = {}
    for id, owned in pairs(inventory) do
        local item = Gear.ById[id]
        if item and item.Slot and type(owned) == 'table' then
            choices[item.Slot] = choices[item.Slot] or {}
            table.insert(choices[item.Slot], id)
        end
    end
    local chosen = table.clone(equipped)
    for _, slot in ipairs(Gear.Slots) do
        if not inventory[chosen[slot.Key]] then chosen[slot.Key] = nil end
    end
    local scoreCache = {}
    local function scored(E)
        local keys = {}
        for _, slot in ipairs(Gear.Slots) do keys[#keys+1] = tostring(E[slot.Key] or '-') end
        local sig = table.concat(keys, '|')
        if scoreCache[sig] == nil then scoreCache[sig] = loadoutScore(inventory, E) end
        return scoreCache[sig]
    end
    -- Multiple complete sets can be compared; skip the misleading individual
    -- improvement step that breaks a complete set before testing the whole set.
    local seeds = {chosen}
    for _, set in ipairs(Gear.Sets or {}) do
        local full, proposal = true, table.clone(chosen)
        for _, id in ipairs(set.Pieces or {}) do
            local item = Gear.ById[id]
            if not item or not inventory[id] then full = false break end
            proposal[item.Slot] = id
        end
        if full then seeds[#seeds + 1] = proposal end
    end
    -- Also seed from per-slot highest personal bonus, not only worn pieces.
    local greedy = table.clone(chosen)
    for _, slot in ipairs(Gear.Slots) do
        local best = greedy[slot.Key]
        local gain = -math.huge
        for _, id in ipairs(choices[slot.Key] or {}) do
            local item = Gear.ById[id]
            local stats = Gear.ItemStats(item, inventory[id])
            local value = 0
            for key, weight in pairs(gearWeights) do value = value + (stats[key] or 0) * weight end
            if value > gain then best, gain = id, value end
        end
        greedy[slot.Key] = best
    end
    seeds[#seeds + 1] = greedy
    local bestPlan = chosen
    local bestScore = scored(chosen)
    for _, seed in ipairs(seeds) do
        local plan = table.clone(seed)
        for _ = 1, 3 do
            local didChange = false
            for _, slot in ipairs(Gear.Slots) do
                local slotKey = slot.Key
                local winning = plan[slotKey]
                local value = scored(plan)
                for _, id in ipairs(choices[slotKey] or {}) do
                    if id ~= winning then
                        local probe = table.clone(plan)
                        probe[slotKey] = id
                        local score = scored(probe)
                        if score > value + 0.01 then winning, value = id, score end
                    end
                end
                if winning ~= plan[slotKey] then plan[slotKey] = winning; didChange = true end
            end
            if not didChange then break end
        end
        if scored(plan) > bestScore + 0.01 then bestPlan, bestScore = plan, scored(plan) end
    end
    return bestPlan
end

local function autoGear()
    if not (opts.AutoEquipGear or opts.AutoImproveGear or opts.AutoFuseGear) then return end
    if not state.gear or type(state.gear.I) ~= 'table' or type(state.gear.E) ~= 'table' then return end
    local d = state.gear
    local preserveReaper = opts.AutoHalloweenEvent and opts.WearReaperSet and
        eventOn() and reaperOwned(d)
    if preserveReaper then
        local worn = Gear.Total({I = d.I, E = d.E})
        if not (worn.Sets and worn.Sets.Reaper) then
            if ready('event-set-equip', 8) and not state.gearDirty then
                local result = rpc('GearEquipSet', 'Reaper')
                if result.ok then
                    state.gearDirty = true
                    state.eventSetEquips = state.eventSetEquips + 1
                    state.eventStatus = 'Wearing full Reaper set (+40% candy)'
                    state.eventNextRestore = now() + 3
                else
                    state.throttles['event-set-equip'] = now() + 24
                end
            end
            return
        end
    end
    if opts.AutoEquipGear and not preserveReaper and ready('equip-gear', 5) then
        local chosen = bestLoadout(d.I, d.E)
        for _, slot in ipairs(Gear.Slots) do
            local id = chosen[slot.Key]
            if id and id ~= d.E[slot.Key] and ready('equip:' .. slot.Key, 4) then
                local result = rpc('GearEquip', id)
                if result.ok then
                    state.gearDirty = true
                    say('Equipped ' .. (Gear.ById[id].Name or id))
                end
                -- Allow GearData to update before switching more items.
                return
            end
        end
    end
    if not ready('gear-improve', 5) then return end
    local scrap = nattr('Scrap')
    local best, bestValue = nil, -math.huge
    for _, slot in ipairs(Gear.Slots) do
        local id = d.E[slot.Key]
        local item = id and Gear.ById[id]
        local owned = id and d.I[id]
        if item and type(owned) == 'table' then
            local level = tonumber(owned.L) or 1
            local tier = tonumber(owned.T) or 1
            local copies = tonumber(owned.C) or 0
            local extra = Gear.NeedsCopies(item) and 1 or 0
            if opts.AutoImproveGear and level < Gear.MaxLevel then
                local cost = Gear.UpgradeCost(item, level)
                if cost <= scrap and copies >= extra then
                    local value = (tonumber(item.Stats and item.Stats.Cash) or 0) * 3 +
                        (tonumber(item.Stats and item.Stats.Drop) or 0) * 3 + 10
                    value = value / math.max(1, cost)
                    if value > bestValue then bestValue = value; best = {action = 'GearUpgrade', id = id} end
                end
            end
            if opts.AutoFuseGear and tier < #Gear.TierMult and level >= Gear.MaxLevel then
                local cost = Gear.FuseCost(item, tier)
                local needed = Gear.NeedsCopies(item) and Gear.FuseCopiesFor(item) or 0
                if cost <= scrap and copies >= needed then
                    local value = 8 / math.max(1, cost)
                    if value > bestValue then bestValue = value; best = {action = 'GearFuse', id = id} end
                end
            end
        end
    end
    if best then
        local result = rpc(best.action, best.id)
        if result.ok then
            state.gearDirty = true
            say(best.action .. ': ' .. best.id)
        else
            state.throttles['gear-improve'] = now() + 15
        end
    end
end

local function salvageTick()
    if not opts.AutoSalvage or not state.gear or not ready('salvage', 9) then return end
    local inv = state.gear.I
    if type(inv) ~= 'table' then return end
    for id, owned in pairs(inv) do
        local item = Gear.ById[id]
        if item and not item.Event and type(owned) == 'table' and
            Gear.Rarity[item.Rarity] and (Gear.Rarity[item.Rarity].Salvage or 0) > 0 then
            local copies = tonumber(owned.C) or 0
            local reserve = 1
            if opts.AutoImproveGear and (tonumber(owned.L) or 1) < Gear.MaxLevel then
                reserve = reserve + (Gear.MaxLevel - (tonumber(owned.L) or 1))
            end
            if opts.AutoFuseGear and (tonumber(owned.T) or 1) < #Gear.TierMult then
                reserve = math.max(reserve, (Gear.FuseCopiesFor(item) or 3) + 1)
            end
            if copies > reserve and ready('salvage:' .. id, 20) then
                local res = rpc('GearSalvage', id, 1)
                if res.ok then state.gearDirty = true; say('Salvaged excess ' .. (item.Name or id)) end
                return
            end
        end
    end
end

-- The in-game Blacksmith has two scrap-priced toolboxes and one Robux-only
-- Royal toolbox. Only the scrap-priced entries are considered, even if future
-- game updates accidentally expose additional cases in the same table.
local function decideToolbox()
    local owned = state.gear and state.gear.I
    if type(owned) ~= 'table' then
        return nil, 'Waiting for Blacksmith inventory'
    end
    local hasSlot, distinct, highGrade = {}, 0, 0
    for id, row in pairs(owned) do
        local item = Gear.ById[id]
        if item and not item.Event and type(row) == 'table' and item.Slot then
            hasSlot[item.Slot] = true
            distinct = distinct + 1
            local rarity = Gear.Rarity[item.Rarity]
            if rarity and (tonumber(rarity.Order) or 0) >= 4 then
                highGrade = highGrade + 1
            end
        end
    end
    local missing = 0
    for _, slot in ipairs(Gear.Slots) do
        if not hasSlot[slot.Key] then missing = missing + 1 end
    end
    local key = opts.CaseType
    local reason
    if key == 'Smart' then
        if missing > 0 then
            key = 'Scrap'
            reason = string.format('Fill equipment slots (%d missing)', missing)
        elseif distinct < 10 and highGrade < 2 then
            key = 'Scrap'
            reason = string.format('Build affordable collection (%d owned)', distinct)
        elseif distinct >= 15 and highGrade >= 4 and Gear.CaseByKey.Grinder then
            key = 'Grinder'
            reason = 'Seeking UPD 4 exclusive Grinder gear'
        else
            key = 'Forge'
            reason = 'Saving for higher-rarity gear'
        end
    else
        reason = 'Manual ' .. tostring(key) .. ' strategy'
    end
    local case = Gear.CaseByKey[key]
    if not case or case.Robux or case.ProductId or
        type(case.Cost) ~= 'number' or case.Cost <= 0 then
        return nil, 'Selected toolbox is not scrap-priced'
    end
    return case, reason
end

-- Spend scrap on a useful equipped-gear upgrade before opening another
-- toolbox. A constant CaseReserve by itself can otherwise keep a player
-- permanently below their next upgrade/fusion cost.
local function smartScrapReserve()
    if not (opts.AutoImproveGear or opts.AutoFuseGear) then return 0 end
    local d = state.gear
    if not d or type(d.I) ~= 'table' or type(d.E) ~= 'table' then return 0 end
    local goal = math.huge
    for _, slot in ipairs(Gear.Slots) do
        local id = d.E[slot.Key]
        local item = id and Gear.ById[id]
        local row = id and d.I[id]
        if item and type(row) == 'table' then
            local level, tier, copies = tonumber(row.L) or 1, tonumber(row.T) or 1, tonumber(row.C) or 0
            if opts.AutoImproveGear and level < Gear.MaxLevel and
                copies >= (Gear.NeedsCopies(item) and 1 or 0) then
                goal = math.min(goal, tonumber(Gear.UpgradeCost(item, level)) or math.huge)
            end
            if opts.AutoFuseGear and tier < #Gear.TierMult and level >= Gear.MaxLevel and
                copies >= (Gear.NeedsCopies(item) and Gear.FuseCopiesFor(item) or 0) then
                goal = math.min(goal, tonumber(Gear.FuseCost(item, tier)) or math.huge)
            end
        end
    end
    -- Very expensive future upgrades shouldn't halt every toolbox forever.
    if goal < math.huge and goal <= 2000 then return goal end
    return 0
end

local function caseTick()
    if not opts.AutoCases or not ready('case-check', 2) then return end
    -- Never buy from stale/missing inventory: a case can create a new item,
    -- upgrade a previous copy or fill a missing equipment slot.
    if state.gearDirty or not state.gear or not state.gearSnapshotAt or
        now() - state.gearSnapshotAt > 35 then
        state.caseDecision = 'Refreshing gear before buying'
        return
    end
    local case, reason = decideToolbox()
    if not case then state.caseDecision = reason; return end
    local scrap = nattr('Scrap')
    local reserve = math.max(0, tonumber(opts.CaseReserve) or 0, smartScrapReserve())
    local target = case.Cost + reserve
    if scrap < target then
        state.caseDecision = string.format('Save %d/%d Scrap for %s (%s)',
            math.floor(scrap), math.floor(target), case.Name, reason)
        return
    end
    if not ready('case-open', 5) then return end
    -- UPD 4 added CaseLuck. Equip a lucky set only during a toolbox opening,
    -- then restore the best farming set; never buy the paid 2x Luck product.
    local changedForLuck = false
    local restoreReaper = opts.AutoHalloweenEvent and opts.WearReaperSet and
        eventOn() and reaperOwned(state.gear)
    if opts.AutoCaseLuck and opts.AutoEquipGear and state.gear and
        type(state.gear.I) == 'table' and type(state.gear.E) == 'table' then
        local best = Gear.Best(state.gear, 'Luck')
        local prev = Gear.Total({I = state.gear.I, E = state.gear.E}).Stats.CaseLuck or 0
        local improved = Gear.Total({I = state.gear.I, E = best}).Stats.CaseLuck or 0
        -- When collecting event candy, only interrupt the full Reaper bonus
        -- for a substantial case and a meaningful luck improvement.
        local minDelta = restoreReaper and 10 or 0.1
        local worthwhile = not restoreReaper or case.Cost >= 150
        if worthwhile and improved - prev >= minDelta then
            local luck = rpc('GearEquipBest', 'Luck')
            if luck.ok then
                changedForLuck = true
                state.eventLuckSwaps = state.eventLuckSwaps + 1
                state.gearDirty = true
                task.wait(0.25)
            end
        end
    end
    -- Each case is purchased once against a current inventory snapshot.
    local result = rpc('OpenCase', case.Key)
    if changedForLuck and state.alive then
        -- If Reaper was active, restore the exact four pieces, not a
        -- best-cash loadout that breaks the 40% candy set bonus.
        local restored = restoreReaper and rpc('GearEquipSet', 'Reaper')
            or rpc('GearEquipBest')
        if restored.ok then
            state.eventRestores = state.eventRestores + 1
            state.gearDirty = true
        else
            state.eventRestoreFailures = state.eventRestoreFailures + 1
            state.gearDirty = true
            state.eventNextRestore = now() + 3
        end
    end
    if result.ok then
        state.counters.cases = state.counters.cases + 1
        state.lastCaseOpenedAt = now()
        state.gearDirty = true
        state.caseFailures = 0
        state.throttles['case-open'] = now() + 4
        local reward = result.Id and Gear.ById[result.Id]
        local obtained = reward and reward.Name or 'new gear'
        state.caseDecision = 'Opened ' .. case.Name .. ': ' .. obtained
        say(state.caseDecision)
    else
        state.caseFailures = math.min(state.caseFailures + 1, 6)
        local delay = math.min(120, 8 * (2 ^ (state.caseFailures - 1)))
        state.throttles['case-open'] = now() + delay
        state.caseDecision = 'Toolbox waiting: ' .. tostring(result.msg or 'server rejected action')
    end
end

-- UPD 4: workers are permanent team bonuses purchased with rebirth tokens.
-- Two free slots unlock at 50 rebirths. The third is Robux and excluded.
local function workerScore(item, owned)
    local lvl = type(owned) == 'table' and tonumber(owned.L) or 1
    local stats = Workers.StatsAt(item, lvl or 1)
    -- Token workers accelerate worker/ perk progression; cash workers speed up
    -- rebirths; Scrap workers fund gear and toolbox progression.
    return (stats.Tokens or 0) * 5 + (stats.Cash or 0) * 2.5 + (stats.Scrap or 0) * 1.8
end
local function workerPriorityTokens()
    -- Do not spend the last tokens needed for near-term permanent perks.
    local hold = math.max(0, tonumber(opts.WorkerTokenReserve) or 30)
    if not opts.AutoPerks then return hold end
    for _, key in ipairs({'Value','Rate','Bargain','Cash','Tokens','CatchUp'}) do
        local perk = Config.PerkByKey and Config.PerkByKey[key]
        if perk and LocalPlayer:GetAttribute('Perk_' .. key) ~= true then
            hold = math.max(hold, math.min(125, tonumber(perk.Cost) or 0))
            break
        end
    end
    return hold
end
local function chooseWorkerCase(data)
    if opts.WorkerCaseType ~= 'Smart' then return Workers.CaseByKey[opts.WorkerCaseType] end
    local owned = data.I or {}
    local count, rare, top = 0, 0, 0
    for id, row in pairs(owned) do
        if Workers.ById[id] and type(row) == 'table' then
            count = count + 1
            local rank = Workers.RankOf(Workers.ById[id].Rarity)
            if rank >= 3 then rare = rare + 1 end
            if rank >= 5 then top = top + 1 end
        end
    end
    if count < 2 then return Workers.CaseByKey.Intern end
    if rare < 2 then return Workers.CaseByKey.Office end
    if top < 2 then return Workers.CaseByKey.Executive end
    return Workers.CaseByKey.Tycoon
end
local function workerTick()
    if not opts.AutoWorkers or nattr('Rebirths') < Workers.Unlock or
        not ready('worker-plan', 3) then return end
    local data = state.workers
    if type(data) ~= 'table' or type(data.I) ~= 'table' or type(data.E) ~= 'table' then
        state.workersStatus = 'Checking Hiring Agency inventory'
        return
    end
    if state.workersDirty or now() - state.workersSnapshotAt > 40 then
        state.workersStatus = 'Refreshing workers before spending tokens'
        return
    end
    local tokens = nattr('Tokens')
    local reserve = workerPriorityTokens()
    local owned = data.I
    local scored = {}
    for id, row in pairs(owned) do
        local item = Workers.ById[id]
        if item and type(row) == 'table' then
            scored[#scored+1] = {id=id, item=item, row=row, score=workerScore(item,row)}
        end
    end
    table.sort(scored, function(a,b)
        return a.score > b.score or (a.score == b.score and a.id < b.id)
    end)
    -- Always equip the two/three strongest distinct owned workers, in place.
    local cap = Workers.SlotsOf(data)
    for slot=1, math.min(cap,#scored) do
        local id = scored[slot].id
        if data.E['S' .. slot] ~= id and ready('worker-equip-' .. slot, 7) then
            local res = rpc('EquipWorker', id, slot)
            if res.ok then
                state.workersDirty = true
                state.workerEquips = state.workerEquips + 1
                state.workersStatus = 'Assigned ' .. scored[slot].item.Name
            else state.throttles['worker-equip-' .. slot] = now() + 18 end
            return
        end
    end
    -- Level the strongest active worker before gambling more tokens, but
    -- prefer hiring when an equipment slot is still empty.
    local missing = #scored < cap
    if opts.AutoUpgradeWorkers and not missing then
        local choice, advantage = nil, -math.huge
        for slot=1, cap do
            local id = data.E['S' .. slot]
            local row = id and owned[id]
            local item = id and Workers.ById[id]
            if item and type(row) == 'table' then
                local level = tonumber(row.L) or 1
                local cost = Workers.UpgradeCost(item, level)
                if cost and cost > 0 and tokens >= cost + reserve then
                    local improvement = workerScore(item,{L=level+1}) - workerScore(item,row)
                    local gain = improvement / math.sqrt(cost)
                    if gain > advantage then advantage, choice = gain, id end
                end
            end
        end
        if choice and ready('worker-upgrade', 12) then
            local res = rpc('UpgradeWorker', choice)
            if res.ok then
                state.workerUpgrades = state.workerUpgrades + 1
                state.workersDirty = true
                state.workersStatus = 'Promoted ' .. (Workers.ById[choice].Name or choice)
            else state.throttles['worker-upgrade'] = now() + 30 end
            return
        end
    end
    if not opts.AutoHireWorkers or not ready('worker-hire', 20) then return end
    local case = chooseWorkerCase(data)
    if not case or not case.Cost then return end
    if tokens < case.Cost + reserve then
        state.workersStatus = string.format('Saving tokens %s/%s for %s',
            fmt(tokens),fmt(case.Cost+reserve),case.Name)
        return
    end
    local res = rpc('HireWorker',case.Key)
    if res.ok then
        state.workerCases = state.workerCases + 1
        state.workersDirty = true
        state.workersStatus = 'Hired: ' .. tostring(res.Id or case.Name)
        say(state.workersStatus)
    else
        state.workerFailures = math.min(6,state.workerFailures+1)
        state.throttles['worker-hire'] = now() + math.min(180,12*2^(state.workerFailures-1))
        state.workersStatus = 'Hiring attempt rejected; backing off'
    end
end
local function runWorkerRefresh()
    local last = 0
    while state.alive do
        if opts.AutoWorkers and nattr('Rebirths') >= Workers.Unlock then
            local age = now() - last
            if (state.workersDirty and age > 3) or
                (now() - state.workersSnapshotAt > 35 and age > 8) then
                last = now()
                local result = rpc('Workers')
                if result.ok then
                    state.workers = {
                        I=result.I or {}, E=result.E or {}, P=result.P or {},
                        N=result.N or 0, Extra=result.Extra or 0,
                    }
                    state.workersDirty = false
                    state.workersSnapshotAt = now()
                end
            end
        end
        task.wait(1.4)
    end
end

if Net and Net:IsA('RemoteEvent') then
    table.insert(state.connections, Net.OnClientEvent:Connect(function(event, data)
        if not state.alive then return end
        if event == 'GearData' and type(data) == 'table' then
            local oldLost = state.gear and state.gear.Lost
            local newLost = data.Lost
            if type(oldLost) == 'table' and type(newLost) == 'table' then
                local oldCount, newCount = 0, 0
                for _, v in pairs(oldLost) do if v == true then oldCount = oldCount + 1 end end
                for _, v in pairs(newLost) do if v == true then newCount = newCount + 1 end end
                if newCount < oldCount then
                    for key in pairs(state.worldAttempts) do
                        if string.sub(key, 1, 5) == 'gear:' then state.worldAttempts[key] = nil end
                    end
                end
            end
            state.gear = data
            state.gearSnapshotAt = now()
            state.gearDirty = false
        elseif event == 'WorkerData' and type(data) == 'table' then
            state.workers = data
            state.workersDirty = false
            state.workersSnapshotAt = now()
        elseif event == 'WorkersUnlocked' then
            state.workersDirty = true
        elseif event == 'CrateGone' and type(data) == 'table' and data.Got then
            state.counters.crates = state.counters.crates + 1
            state.worldAcks.crate = now()
            state.worldAttempts.crate = now() + 10
        elseif event == 'PailGone' and type(data) == 'table' and data.Got then
            state.eventPails = state.eventPails + 1
            state.eventPailLastAt = now()
            state.worldAcks.pail = now()
            state.worldAttempts.pail = now() + 10
        elseif event == 'Obby' then
            -- Actual reward broadcast: UI shows cash and 2x multiplier bonus.
            state.obbyAckAt = now()
        elseif event == 'Rebirthed' then
            state.lastRebirth = now()
            table.clear(state.failures)
        elseif event == 'Bought' and type(data) == 'table' then
            if type(data.Id) == 'string' then state.padAcks[data.Id] = now() end
            state.throttles['pad-cycle'] = now() + 0.12
        elseif event == 'TooPoor' then
            state.throttles['pad-cycle'] = now() + 1
        end
    end))
end

local okUI, loadedUI = pcall(function()
    local source = game:HttpGet('https://raw.githubusercontent.com/PuckAFK/Puck-Loader/refs/heads/main/ui/PuckUI.lua')
    return loadstring(source)()
end)
if not okUI or type(loadedUI) ~= 'table' then
    warn('[PuckAFK TBOD] UI load failed. Check executor HttpGet/loadstring permissions: ' .. tostring(loadedUI))
    state.alive = false
    cleanConns()
    if Env.PuckTBOD31 == state then Env.PuckTBOD31 = nil end
    return
end
state.ui = loadedUI
local ui = loadedUI
local win = ui:CreateWindow({
    Name = 'PuckAFK | One Dropper', Title = 'PuckAFK | One Dropper',
    Width = 510, Height = 460, GuiName = 'PuckAFK_TBOD31',
    ConfigId = 'Tycoon_But_One_Dropper_UPD31',
    Configs = {AutoSave = true, AutoLoad = true, DefaultProfile = 'default'},
})
state.window = win

local farmTab = win:CreateTab('Autofarm')
local extrasTab = win:CreateTab('Extras')
local settingsTab = win:CreateTab('Settings')
farmTab:CreateSection('Smart Progression')

local function toggle(tab, title, key)
    return tab:CreateToggle({Name = title, Flag = 'TBOD_' .. key,
        CurrentValue = opts[key], Callback = function(value) opts[key] = value == true end})
end
local function dropdown(tab, title, key, choices)
    return tab:CreateDropdown({Name = title, Flag = 'TBOD_' .. key,
        Options = choices, CurrentOption = {opts[key]}, Callback = function(value)
            if type(value) == 'table' then value = value[1] end
            if value ~= nil then opts[key] = tostring(value) end
        end})
end
local function slider(tab, title, key, min, max, increment)
    return tab:CreateSlider({Name = title, Flag = 'TBOD_' .. key,
        Range = {min, max}, Increment = increment, CurrentValue = opts[key],
        Callback = function(value) opts[key] = tonumber(value) or opts[key] end})
end

toggle(farmTab, 'Smart Autofarm', 'AutoFarm')
toggle(farmTab, 'Auto Buy Upgrade Pads', 'AutoBuyPads')
dropdown(farmTab, 'Farming Focus', 'ActivityPriority',
    {'Balanced','Extras First','Upgrades First','Extras Only'})
toggle(farmTab, 'Automatic Rebirths', 'AutoRebirth')
toggle(farmTab, 'Explore New Sky Floors Before Rebirth', 'AutoBuildFloor3')
toggle(farmTab, 'Buy Permanent Perks', 'AutoPerks')
dropdown(farmTab, 'Upgrade Priority', 'BuyMode', {'Balanced','Cheapest','Highest Value'})
dropdown(farmTab, 'Rebirth Strategy', 'RebirthMode', {'Smart','Fast','Balanced','Extra Tokens'})
farmTab:CreateSection('Progress')
local stateLabel = farmTab:CreateLabel('Finding your plot...')
local statsLabel = farmTab:CreateLabel('Upgrades: 0 | Rebirths: 0')
local walletLabel = farmTab:CreateLabel('Cash: ... | Tokens: ...')

extrasTab:CreateSection('Free Rewards')
toggle(extrasTab, 'Daily Rewards + Wheel', 'AutoRewards')
toggle(extrasTab, 'Daily, Weekly + Achievements', 'AutoQuests')
toggle(extrasTab, 'Redeem Known Free Codes', 'AutoCodes')
toggle(extrasTab, 'Group Cash (Existing Members)', 'AutoGroupReward')
extrasTab:CreateSection('World Collectibles')
toggle(extrasTab, 'Collect Mystery Crates', 'AutoCrates')
toggle(extrasTab, 'Collect Halloween Candy Pails', 'AutoPails')
toggle(extrasTab, 'Hunt Lost Gears', 'AutoLostGears')
toggle(extrasTab, 'Auto Obby Reward (Teleport)', 'AutoObby')
extrasTab:CreateSection("Halloween · Witch's Hut")
toggle(extrasTab, 'Auto Complete Halloween Event', 'AutoHalloweenEvent')
dropdown(extrasTab, 'Halloween Goal', 'HalloweenGoal',
    {'Set then Brew','Brew First','Set Only','Brew Only'})
toggle(extrasTab, 'Wear Reaper Set for +40% Candy', 'WearReaperSet')
toggle(extrasTab, 'Stop When Both Rare + Crown Are Owned', 'StopBrewAfterCrown')
slider(extrasTab, 'Keep Candy Reserve for Brews', 'CandyReserve', 0, 500, 25)
local eventLabel = extrasTab:CreateLabel('Halloween: waiting for candy and gear')
extrasTab:CreateSection('UPD 4 · Hiring Agency')
toggle(extrasTab, 'Auto Workers (50 Rebirths)', 'AutoWorkers')
toggle(extrasTab, 'Hire Worker Briefcases', 'AutoHireWorkers')
toggle(extrasTab, 'Upgrade Owned Workers', 'AutoUpgradeWorkers')
dropdown(extrasTab, 'Worker Briefcase Strategy', 'WorkerCaseType', {'Smart','Intern','Office','Executive','Tycoon'})
local workerLabel = extrasTab:CreateLabel('Workers: unlock at 50 rebirths')
extrasTab:CreateSection('Blacksmith + Equipment')
toggle(extrasTab, 'Equip Best Owned Gear', 'AutoEquipGear')
toggle(extrasTab, 'Upgrade Best Gear', 'AutoImproveGear')
toggle(extrasTab, 'Fuse Max-Level Gear (Optional)', 'AutoFuseGear')
toggle(extrasTab, 'Smart Auto Toolboxes (No Robux)', 'AutoCases')
toggle(extrasTab, 'Salvage Excess Copies (Optional)', 'AutoSalvage')
dropdown(extrasTab, 'Toolbox Strategy', 'CaseType', {'Smart','Scrap','Forge','Grinder'})
toggle(extrasTab, 'Use Lucky Gear For Toolboxes', 'AutoCaseLuck')
slider(extrasTab, 'Keep Scrap Reserve for Cases', 'CaseReserve', 0, 500, 5)
local caseLabel = extrasTab:CreateLabel('Toolboxes: waiting for inventory')
local obbyLabel = extrasTab:CreateLabel('Obby: waiting for reward status')

settingsTab:CreateSection('Movement + Speed')
dropdown(settingsTab, 'Movement Mode', 'Movement', {'Instant','Tween'})
slider(settingsTab, 'Tween Travel Speed', 'TweenSpeed', 80, 400, 10)
slider(settingsTab, 'Purchase Check Delay (x100)', 'PadDelay', 12, 100, 4)
-- Control uses integer hundredths for cross-executor slider precision.
-- Stored as integer hundredths: 28 = 0.28 seconds.
toggle(settingsTab, 'Touch Interest Fallback', 'UseTouchInterest')
slider(settingsTab, 'Cash Reserve Percent', 'ReservePercent', 0, 75, 5)
slider(settingsTab, 'Maximum Collectible Detour', 'MaxCollectibleDetour', 80, 1800, 20)
slider(settingsTab, 'Extras Check Interval (Seconds)', 'ExtrasInterval', 8, 30, 1)
slider(settingsTab, 'Reserve Rebirth Tokens For Perks', 'WorkerTokenReserve', 0, 500, 10)
settingsTab:CreateSection('Management')
settingsTab:CreateLabel('Configs tab supports autosave, autoload, profiles and JSON export/import.')
settingsTab:CreateLabel('No gamepasses or Robux purchase prompts are used.')

local function unload()
    if not state.alive then return end
    state.alive = false
    opts.AutoFarm = false
    if state.tween then pcall(function() state.tween:Cancel() end) end
    cleanConns()
    local window = state.window
    state.window = nil
    if window then pcall(function() window:Destroy() end) end
    if Env.PuckTBOD31 == state then Env.PuckTBOD31 = nil end
    print('[PuckAFK TBOD] Unloaded cleanly')
end
state.Unload = unload
settingsTab:CreateButton({Name = 'UNLOAD PuckAFK', Callback = unload})
win:SetCloseCallback(unload)

-- PuckUI is responsible for persistent profile save/load; this script only stores
-- the boolean/numeric/dropdown options above and deliberately never uploads config.
-- PuckUI automatically generates its complete Configs tab.

-- Opportunistic scheduler:
--   (1) Scheduled extras windows have a maximum gap, even when pads are affordable.
--   (2) Any economic/plot/build/rebirth wait immediately yields to collectibles.
--   (3) Maintenance independently collects spins, quests, perks, Blacksmith rewards.
-- This prevents repeated Saving / Waiting status loops from starving other tasks.
local function extrasWorkTick()
    if not state.alive or not canGo() then return false end
    -- Halloween pails are spawned client-side and disappear in ~100s.
    -- Always take an available pail before long Obby/gear detours.
    if opts.AutoPails and eventOn() and
        worldTick(false, opts.MaxCollectibleDetour, false, true) then return true end
    -- Guarantee gear rounds; Obby cannot repeatedly preempt them. Spare
    -- cycles still collect crates, pails and the available Obby reward.
    if opts.AutoLostGears and now() - state.lastGearAttempt >= 10 and
        worldTick(true, opts.MaxCollectibleDetour, true) then return true end
    if opts.AutoObby and obbyTick() then return true end
    return worldTick(true, opts.MaxCollectibleDetour)
end

local function extrasActive()
    local mode = opts.ActivityPriority
    if not opts.AutoBuyPads or mode == 'Extras Only' then return true end
    local interval = math.clamp(tonumber(opts.ExtrasInterval) or 15, 8, 30)
    if state.nextExtrasAt == 0 then
        state.nextExtrasAt = now() + math.min(5, interval * 0.35)
    end
    if now() >= state.nextExtrasAt and now() >= state.extrasUntil then
        local window = mode == 'Extras First' and 14 or mode == 'Upgrades First' and 5 or 10
        state.extrasUntil = now() + window
        state.nextExtrasAt = state.extrasUntil + interval
        state.extrasCycles = state.extrasCycles + 1
    end
    return now() < state.extrasUntil
end

local function idleToExtras(reason)
    -- A failed/locked/pending upgrade is not a reason to stand still when
    -- reward spots, crates, or gears may be waiting elsewhere.
    if now() >= state.nextIdleCollectAt then
        state.nextIdleCollectAt = now() + 0.55
        if extrasWorkTick() then
            state.fallbackCount = state.fallbackCount + 1
            return true
        end
    end
    say(reason .. ' | rewards and gears checked')
    task.wait(0.18)
    return false
end

local function runFarm()
    while state.alive do
        local ok, err = pcall(function()
            if not opts.AutoFarm then
                say('Autofarm OFF (check saved Configs / Autofarm toggle)')
                task.wait(0.35)
                return
            end
            if not canGo() then
                say('Recovering character')
                task.wait(0.3)
                return
            end
            if state.busyUntil > now() then task.wait(0.06); return end
            if rebirthTick() then return end
            if extrasActive() then
                if not extrasWorkTick() then
                    state.nextIdleCollectAt = now() + 0.55
                    if opts.AutoBuyPads and opts.ActivityPriority ~= 'Extras Only' then
                        -- No eligible pickups: release the extras window early.
                        -- Keeping an empty time window would waste upgrades.
                        state.extrasUntil = now()
                        local interval = math.clamp(tonumber(opts.ExtrasInterval) or 15, 8, 30)
                        state.nextExtrasAt = now() + math.max(4, interval * 0.6)
                        state.idleSkippedExtras = state.idleSkippedExtras + 1
                        say('No extras ready; returning to upgrades')
                    else
                        say('Monitoring gears, wheel, Obby and rewards')
                        task.wait(0.24)
                    end
                end
                return
            end
            local plot = findPlot()
            if not plot then
                idleToExtras('Waiting for your plot')
                return
            end
            -- Nearby pickups can interrupt travel without losing scheduled gear rounds.
            if worldTick(false, 60) then return end
            if opts.AutoRebirth then
                local cost = nattr('RebirthCost')
                local cash = nattr('Cash')
                if cost > 0 and cash >= cost and not floor3Focus() and
                    now() >= (state.rebirthBlockedUntil or 0) then
                    local multiple = rebirthMultiplier()
                    -- If we have enough for the base rebirth but want more tokens,
                    -- upgrade buying must pause, NOT the whole autofarm.
                    idleToExtras('Saving for rebirth: $' .. fmt(cash) .. '/$' .. fmt(cost * multiple))
                    return
                end
            end
            local cash = nattr('Cash')
            local income = nattr('Income')
            local candidate, nextPrice, count = getBestPad(plot, cash, income)
            if state.lastPlot ~= plot then
                state.lastPlot = plot
                table.clear(state.padFailures)
                table.clear(state.failures)
            end
            if candidate and opts.AutoBuyPads and opts.ActivityPriority ~= 'Extras Only' then
                -- Pad cooldown is only 0.1s. Don't leave for a distant gear
                -- between two normal consecutive successful purchases.
                if not ready('pad-cycle', 0.10) then
                    task.wait(0.06)
                    return
                end
                if not buyPad(plot, candidate) then
                    idleToExtras('Upgrade waiting for confirmation')
                end
                task.wait(0.04)
                return
            end
            local buildRemaining = state.nextConstruction and state.nextConstruction - workspace:GetServerTimeNow() or 0
            if buildRemaining > 0 and buildRemaining < 8 then
                idleToExtras('Building next upgrade (' .. math.ceil(buildRemaining) .. 's)')
            elseif count == 0 then
                idleToExtras(buildRemaining > 0 and
                    ('Waiting for construction (' .. math.ceil(buildRemaining) .. 's)') or
                    'No available upgrades; checking extras')
            elseif nextPrice < math.huge then
                idleToExtras('Saving: $' .. fmt(cash) .. '/$' .. fmt(nextPrice))
            else
                idleToExtras('Waiting for upgrades')
            end
        end)
        if not ok then
            state.lastError = tostring(err)
            warn('[PuckAFK TBOD][Farm] ' .. tostring(err))
            task.wait(0.4)
        end
        task.wait(0.06)
    end
end
-- Keep wheel spins/daily reward checks independent from slow inventory scans.
-- Gear loadout optimisation must never delay the next free wheel spin.
local function runFastRewards()
    while state.alive do
        local ok, err = pcall(rewardsTick)
        if not ok then
            state.lastError = tostring(err)
            warn('[PuckAFK TBOD][Fast Rewards] ' .. tostring(err))
        end
        task.wait(0.85)
    end
end

local function runMaintenance()
    local loops = {buyPerk, workerTick, questTick, codesTick, autoGear, caseTick, halloweenTick, salvageTick}
    local index = 0
    while state.alive do
        index = index % #loops + 1
        local fn = loops[index]
        local ok, err = pcall(fn)
        if not ok then
            state.lastError = tostring(err)
            warn('[PuckAFK TBOD][Rewards] ' .. tostring(err))
        end
        task.wait(0.22)
    end
end
local function runGearRefresh()
    local lastRequest = 0
    while state.alive do
        if opts.AutoEquipGear or opts.AutoImproveGear or opts.AutoFuseGear or opts.AutoCases or opts.AutoLostGears or opts.AutoHalloweenEvent or opts.AutoSalvage then
            local elapsed = now() - lastRequest
            local stale = not state.gear or now() - state.gearSnapshotAt > 25
            if now() >= (state.throttles['gear-resync'] or 0) and
                ((state.gearDirty and elapsed >= 2.5) or (stale and elapsed >= 5)) then
                lastRequest = now()
                local response = rpc('GearData') -- server broadcasts GearData
                if not response.ok then
                    state.throttles['gear-resync'] = now() + 6
                end
            end
        end
        task.wait(1.3)
    end
end
local function runStatus()
    while state.alive do
        pcall(function()
            local title = state.status
            if state.lastError ~= '' then title = title .. ' | Last error: ' .. state.lastError:sub(1, 35) end
            if stateLabel then stateLabel:Set(title) end
            if statsLabel then
                statsLabel:Set(string.format('Pads %d  |  Rebirths %s  |  Spins %d  |  Gears %d  |  Obby %d',
                    state.counters.purchases, fmt(nattr('Rebirths')), state.counters.spins, state.counters.gears, state.counters.obby))
            end
            if walletLabel then
                walletLabel:Set(string.format('Cash $%s  |  Income $%s/s  |  Tokens %s',
                    fmt(nattr('Cash')), fmt(nattr('Income')), fmt(nattr('Tokens'))))
            end
            if eventLabel then eventLabel:Set('Halloween: ' .. tostring(state.eventStatus) ..
                ' | Candy ' .. fmt(nattr('Candy')) .. ' | Brews ' .. tostring(state.eventBrews) ..
                ' | Pails ' .. tostring(state.eventPails)) end
            if obbyLabel then obbyLabel:Set('Obby: ' .. tostring(state.obbyStatus)) end
            if workerLabel then workerLabel:Set('Workers: ' .. (nattr('Rebirths') < Workers.Unlock and
                ('Unlock at '..Workers.Unlock..' rebirths') or state.workersStatus)) end
            if caseLabel then
                caseLabel:Set(string.format('Scrap %s  |  Cases %d  |  %s',
                    fmt(nattr('Scrap')), state.counters.cases, state.caseDecision or 'Idle'))
            end
        end)
        task.wait(0.75)
    end
end

-- PadDelay is persisted as hundredths of a second (28 means 0.28s).
-- PuckUI loads the selected profile after controls are registered.

task.spawn(runFarm)
task.spawn(runFastRewards)
task.spawn(runMaintenance)
task.spawn(runGearRefresh)
task.spawn(runWorkerRefresh)
task.spawn(runStatus)
notify("v1.9.1 UPD 4 | core recovery, rebirth/pad fixes, reliable gear collection")
