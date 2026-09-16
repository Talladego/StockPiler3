----------------------------------------------------------------
-- StockPiler3 Core/EventBus — internal pub/sub
----------------------------------------------------------------

StockPiler3.EventBus = StockPiler3.EventBus or {}

local Bus = StockPiler3.EventBus
local subs = {}
local nextToken = 0

StockPiler3.Events = StockPiler3.Events or {
    INVENTORY_DIRTY = "sp3.inventory.dirty",
    INVENTORY_SNAPSHOT = "sp3.inventory.snapshot",
    GARDEN_DIRTY = "sp3.garden.dirty",
    GARDEN_SNAPSHOT = "sp3.garden.snapshot",
    PLAN_INVALIDATED = "sp3.plan.invalidated",
    PLAN_UPDATED = "sp3.plan.updated",
    PHASE_CHANGED = "sp3.phase.changed",
    OP_COMPLETED = "sp3.op.completed",
    CMD_HARVEST = "sp3.cmd.harvest",
    CMD_BREW_LOAD = "sp3.cmd.brew.load",
    CMD_BREW_PERFORM = "sp3.cmd.brew.perform",
    SESSION_LOADED = "sp3.session.loaded",
    KNOWLEDGE_UPDATED = "sp3.knowledge.updated",
    REFINE_OUTSTANDING = "sp3.refine.outstanding",
    VENDOR_UPDATED = "sp3.vendor.updated",
}

function Bus.Subscribe(eventName, fn)
    eventName = tostring(eventName or "")
    if eventName == "" or type(fn) ~= "function" then
        return false
    end
    local list = subs[eventName]
    if list == nil then
        list = {}
        subs[eventName] = list
    end
    for i = 1, #list do
        local entry = list[i]
        if type(entry) == "table" and entry.fn == fn then
            return entry.token
        end
    end
    nextToken = nextToken + 1
    local token = nextToken
    list[#list + 1] = { token = token, fn = fn }
    return token
end

function Bus.Unsubscribe(token)
    token = tonumber(token)
    if token == nil then
        return false
    end
    for eventName, list in pairs(subs) do
        if type(list) == "table" then
            for i = #list, 1, -1 do
                local entry = list[i]
                if type(entry) == "table" and entry.token == token then
                    table.remove(list, i)
                    if #list == 0 then
                        subs[eventName] = nil
                    end
                    return true
                end
            end
        end
    end
    return false
end

function Bus.UnsubscribeAll(eventName)
    if eventName == nil then
        subs = {}
        return
    end
    subs[tostring(eventName)] = nil
end

function Bus.Fire(eventName, payload)
    eventName = tostring(eventName or "")
    local list = subs[eventName]
    local n = type(list) == "table" and #list or 0
    if StockPiler3.Debug and StockPiler3.Debug.EventTraceNote then
        local summary = ""
        if type(payload) == "table" then
            if payload.snapGen then
                summary = summary .. "snapGen=" .. tostring(payload.snapGen) .. " "
            end
            if payload.reason then
                summary = summary .. "reason=" .. tostring(payload.reason) .. " "
            end
            if payload.phase then
                summary = summary .. "phase=" .. tostring(payload.phase) .. " "
            end
        end
        StockPiler3.Debug.EventTraceNote(eventName, summary, n)
    end
    if n <= 0 then
        return
    end
    local handlers = {}
    for i = 1, n do
        local entry = list[i]
        local fn = type(entry) == "table" and entry.fn or entry
        if type(fn) == "function" then
            handlers[#handlers + 1] = fn
        end
    end
    for i = 1, #handlers do
        StockPiler3.Debug.TryCallQuiet("EventBus." .. eventName, handlers[i], payload)
    end
end
