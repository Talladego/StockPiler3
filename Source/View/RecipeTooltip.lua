----------------------------------------------------------------
-- StockPiler3 RecipeTooltip -- Potions-tab recipe hover
----------------------------------------------------------------

StockPiler3 = StockPiler3 or {}
StockPiler3.RecipeTooltip = StockPiler3.RecipeTooltip or {}
local RecipeTooltip = StockPiler3.RecipeTooltip

local function T(key, tokens)
    if StockPiler3.T then
        return StockPiler3.T(key, tokens)
    end
    return L"[" .. towstring(tostring(key or "")) .. L"]"
end

local function RoleLabel(role)
    role = tostring(role or "")
    if role == "" then
        return T("ui.item_fallback")
    end
    return towstring(string.upper(string.sub(role, 1, 1)) .. string.sub(role, 2))
end

local function SlotTitle(slot)
    if type(slot) ~= "table" then
        return T("ui.item_fallback")
    end
    if slot.name ~= nil and slot.name ~= L"" then
        return slot.name
    end
    local uid = tonumber(slot.uid) or tonumber(slot.uniqueID) or 0
    if uid > 0 then
        local items = StockPiler3.Knowledge and StockPiler3.Knowledge.Items and StockPiler3.Knowledge.Items()
        local row = type(items) == "table" and items[tostring(uid)] or nil
        if type(row) == "table" and row.name ~= nil then
            return row.name
        end
    end
    return T("ui.item_fallback")
end

function RecipeTooltip.Show(mouseoverWindow, recipeData)
    mouseoverWindow = mouseoverWindow or (SystemData and SystemData.ActiveWindow and SystemData.ActiveWindow.name)
    if mouseoverWindow == nil or mouseoverWindow == "" or type(recipeData) ~= "table" then
        return
    end
    local name = recipeData.name or T("ui.potion_fallback")
    local lines = {}
    lines[#lines + 1] = T("recipe.title", { name = name })
    local level = tonumber(recipeData.potionLevel) or 0
    if level > 0 then
        lines[#lines + 1] = T("recipe.level", { level = tostring(level) })
    end
    local yield = tonumber(recipeData.recipeYield) or 0
    if yield > 0 then
        lines[#lines + 1] = T("recipe.yield", { yield = tostring(yield) })
    end
    local rate = tonumber(recipeData.successRate)
    local ok = tonumber(recipeData.brewSuccesses) or 0
    local att = tonumber(recipeData.brewAttempts) or 0
    if rate ~= nil and att > 0 then
        local pct = math.floor((rate * 100) + 0.5)
        lines[#lines + 1] = T("recipe.success", {
            pct = tostring(pct),
            ok = tostring(ok),
            att = tostring(att),
        })
    end
    lines[#lines + 1] = L"---"
    local materials = recipeData.materials or recipeData.slots or {}
    if type(materials) == "table" then
        for i = 1, #materials do
            local slot = materials[i]
            if type(slot) == "table" then
                lines[#lines + 1] = T("recipe.role_mat", {
                    role = RoleLabel(slot.role or slot.slotRole),
                    title = SlotTitle(slot),
                })
            end
        end
    end
    local body = lines[1] or L""
    for i = 2, #lines do
        body = body .. L"\n" .. lines[i]
    end
    Tooltips.CreateTextOnlyTooltip(mouseoverWindow, body)
    Tooltips.AnchorTooltip(Tooltips.ANCHOR_WINDOW_RIGHT)
end
