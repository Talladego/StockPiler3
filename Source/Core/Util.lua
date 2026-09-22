----------------------------------------------------------------
-- StockPiler3 Core/Util - shared micro-helpers (NowSec, ToNarrow, T, TryCall)
----------------------------------------------------------------

StockPiler3 = StockPiler3 or {}
StockPiler3.Util = StockPiler3.Util or {}
local U = StockPiler3.Util

function U.NowSec()
    if type(GetGameTime) == "function" then
        local t = tonumber(GetGameTime())
        if t ~= nil then
            return t
        end
    end
    if type(FrameCounter) == "number" then
        return FrameCounter * 0.001
    end
    return 0
end

function U.ToNarrow(value)
    if StockPiler3.Persistence and StockPiler3.Persistence.ToNarrow then
        return StockPiler3.Persistence.ToNarrow(value)
    end
    if value == nil then
        return ""
    end
    if type(value) == "string" then
        return value
    end
    if type(value) == "wstring" and type(WStringToString) == "function" then
        local ok, text = pcall(WStringToString, value)
        if ok and type(text) == "string" then
            return text
        end
        return ""
    end
    return tostring(value)
end

function U.T(key, tokens)
    if StockPiler3.T then
        return StockPiler3.T(key, tokens)
    end
    return L"[" .. towstring(tostring(key or "")) .. L"]"
end

function U.TryCall(context, fn, ...)
    if StockPiler3.Debug and StockPiler3.Debug.TryCall then
        return StockPiler3.Debug.TryCall(context, fn, ...)
    end
    if type(fn) ~= "function" then
        return false
    end
    return pcall(fn, ...)
end

function U.TryCallQuiet(context, fn, ...)
    if StockPiler3.Debug and StockPiler3.Debug.TryCallQuiet then
        return StockPiler3.Debug.TryCallQuiet(context, fn, ...)
    end
    if type(fn) ~= "function" then
        return false
    end
    return pcall(fn, ...)
end

function U.CharacterRow(create)
    if StockPiler3.Persistence and StockPiler3.Persistence.GetCharacterBucket then
        return StockPiler3.Persistence.GetCharacterBucket(create ~= false)
    end
    return nil
end
