----------------------------------------------------------------
-- StockPiler3 RecipeTooltip -- Potions-tab recipe hover + colored rows
-- Same row kinds / separators as Watch status tip (ShowColoredRows).
----------------------------------------------------------------

StockPiler3 = StockPiler3 or {}
StockPiler3.RecipeTooltip = StockPiler3.RecipeTooltip or {}
local RecipeTooltip = StockPiler3.RecipeTooltip

-- Yellow stats line (matches stock item-bonus tint when available).
local COLOR_STATS = { 220, 180, 60 }

local function T(key, tokens)
    return StockPiler3.Util.T(key, tokens)
end

RecipeTooltip.SEP_LINE = T("recipe.sep")

-- DefaultTooltip XML ships 17 rows; grow for long recipes (perCraft copies + seps).
local RECIPE_TOOLTIP_MAX_ROWS = 32

local function RgbDef(rgb)
    if not rgb then
        return nil
    end
    return { r = rgb[1] or 255, g = rgb[2] or 255, b = rgb[3] or 255 }
end

--- Ensure DefaultTooltip has at least `want` row windows and Tooltips.NUM_ROWS >= want.
--- Same approach as StockPiler2 harvest tip (CreateWindowFromTemplate TooltipRow).
function RecipeTooltip.EnsureRows(want)
    want = tonumber(want) or 0
    if want < 1 then
        return tonumber(Tooltips and Tooltips.NUM_ROWS) or 17
    end
    if want > RECIPE_TOOLTIP_MAX_ROWS then
        want = RECIPE_TOOLTIP_MAX_ROWS
    end
    local have = tonumber(Tooltips and Tooltips.NUM_ROWS) or 17
    if have >= want then
        return have
    end
    if type(DoesWindowExist) ~= "function"
        or type(CreateWindowFromTemplate) ~= "function"
        or not DoesWindowExist("DefaultTooltip")
    then
        return have
    end
    for rowNum = have + 1, want do
        local rowName = "DefaultTooltipRow" .. tostring(rowNum)
        if not DoesWindowExist(rowName) then
            local ok = pcall(CreateWindowFromTemplate, rowName, "TooltipRow", "DefaultTooltip")
            if not ok or not DoesWindowExist(rowName) then
                break
            end
            if type(WindowClearAnchors) == "function" and type(WindowAddAnchor) == "function" then
                WindowClearAnchors(rowName)
                local prev = "DefaultTooltipRow" .. tostring(rowNum - 1)
                WindowAddAnchor(rowName, "bottomleft", prev, "topleft", 0, 5)
                WindowAddAnchor(rowName, "bottomright", prev, "topright", 0, 5)
            end
        end
        have = rowNum
    end
    if Tooltips and (tonumber(Tooltips.NUM_ROWS) or 0) < have then
        Tooltips.NUM_ROWS = have
    end
    return have
end

local function RecipeTooltipColor(kind, role)
    if not Tooltips then
        return nil
    end
    if kind == "title" then
        return Tooltips.COLOR_HEADING
    end
    if kind == "meta" then
        return Tooltips.COLOR_EXTRA_TEXT_DEFAULT
    end
    if kind == "separator" then
        return Tooltips.COLOR_ITEM_DEFAULT_GRAY
    end
    if kind == "ingredient" then
        return Tooltips.COLOR_ACTION
    end
    if kind == "effect" or kind == "bonus" or kind == "positive" or kind == "negative" then
        return Tooltips.COLOR_ITEM_BONUS or Tooltips.COLOR_HEADING
    end
    if kind == "warning" or kind == "block" then
        return Tooltips.COLOR_WARNING
    end
    if kind == "stocked" then
        return Tooltips.COLOR_ABILITY_STATE_READY or Tooltips.COLOR_HEADING
    end
    return Tooltips.COLOR_BODY
end

local function SetRecipeTooltipRowColor(row, color)
    if not color or not Tooltips then
        return
    end
    if Tooltips.SetTooltipColorDef then
        Tooltips.SetTooltipColorDef(row, 1, color)
    elseif Tooltips.SetTooltipColor then
        Tooltips.SetTooltipColor(row, 1, color.r or 255, color.g or 255, color.b or 255)
    end
end

function RecipeTooltip.AppendSeparator(rows)
    if type(rows) ~= "table" then
        return
    end
    rows[#rows + 1] = { text = RecipeTooltip.SEP_LINE or T("recipe.sep"), kind = "separator" }
end

--- Shared colored text-only tooltip (Status / Craftable / Recipe use the same kinds).
--- rows: { { text = L"...", kind = "...", color? }, ... }
function RecipeTooltip.ShowColoredRows(anchorWindow, rows, anchor, maxRows)
    if type(rows) ~= "table" then
        rows = {}
    end
    if not Tooltips or type(Tooltips.CreateTextOnlyTooltip) ~= "function" then
        return
    end
    local want = tonumber(maxRows) or #rows
    if want < #rows then
        want = #rows
    end
    local engineMax = RecipeTooltip.EnsureRows(want)
    Tooltips.CreateTextOnlyTooltip(anchorWindow)
    engineMax = tonumber(Tooltips.NUM_ROWS) or engineMax
    local limit = engineMax
    if tonumber(maxRows) and tonumber(maxRows) < limit then
        limit = tonumber(maxRows)
    end
    local rowCount = math.min(#rows, limit)
    for i = 1, rowCount do
        local entry = rows[i]
        if type(entry) ~= "table" then
            entry = { text = entry, kind = "body" }
        end
        Tooltips.SetTooltipText(i, 1, entry.text or L"", false)
        SetRecipeTooltipRowColor(i, entry.color or RecipeTooltipColor(entry.kind, entry.role))
    end
    for i = rowCount + 1, engineMax do
        Tooltips.SetTooltipText(i, 1, L"", false)
    end
    Tooltips.Finalize()
    Tooltips.AnchorTooltip(anchor or Tooltips.ANCHOR_WINDOW_RIGHT)
end

--- Fit row budget without dropping ingredient dividers (--- before next ingredient).
local function TrimRecipeTooltipRows(rows, limit)
    limit = tonumber(limit) or 17
    if type(rows) ~= "table" or #rows <= limit then
        return rows
    end

    local function isIngredientDivider(i)
        local prev = rows[i - 1]
        local nextRow = rows[i + 1]
        if not (nextRow and nextRow.kind == "ingredient") or not prev then
            return false
        end
        return prev.kind == "bonus"
            or prev.kind == "ingredient"
            or prev.kind == "body"
            or prev.kind == "stocked"
            or prev.kind == "effect"
            or prev.kind == "positive"
            or prev.kind == "negative"
    end

    -- Prefer dropping optional meta (yield / success) before any separators.
    for i = #rows, 1, -1 do
        if #rows <= limit then
            return rows
        end
        local r = rows[i]
        if r.kind == "meta" then
            table.remove(rows, i)
        end
    end

    -- Drop non-ingredient separators only (keep --- between materials).
    while #rows > limit do
        local removed = false
        for i = #rows, 1, -1 do
            if rows[i].kind == "separator" and not isIngredientDivider(i) then
                table.remove(rows, i)
                removed = true
                break
            end
        end
        if not removed then
            break
        end
    end
    return rows
end

local function ResolveSlot(slot)
    if type(slot) ~= "table" then
        return nil, nil
    end
    local RS = StockPiler3.RecipeSpec
    local spec = slot.spec
    if RS and RS.ResolveSlotSpec then
        spec = RS.ResolveSlotSpec(slot) or spec
    end
    return slot, spec
end

local function SlotHeaderAndStats(slot, spec, tipContext)
    local MS = StockPiler3.MaterialSpec
    local role = slot.role or (type(spec) == "table" and spec.role) or nil
    local parts = nil
    if MS and MS.NeedLabelParts and type(spec) == "table" then
        parts = MS.NeedLabelParts(spec, tipContext)
    end
    local header = parts and parts.header or nil
    if header == nil or header == L"" then
        local roleTitle = (MS and MS.RoleTitle and MS.RoleTitle(role))
            or towstring(tostring(role or "mat"))
        header = roleTitle
    end
    local stats = parts and parts.detail or L""
    return header, stats, role
end

--- Append one fingerprint ingredient block (header + yellow stats).
local function AppendIngredientSection(rows, header, stats, role, statsColor)
    rows[#rows + 1] = {
        text = header,
        kind = "ingredient",
        role = role,
    }
    if stats ~= nil and stats ~= L"" then
        rows[#rows + 1] = {
            text = stats,
            kind = "bonus",
            role = role,
            color = statsColor,
        }
    end
end

--- Recipe tip rows: title/meta, then one section per perCraft unit (no names / Have-Need).
function RecipeTooltip.BuildRows(recipeData)
    if type(recipeData) ~= "table" then
        return {}
    end
    local name = recipeData.name or T("ui.potion_fallback")
    local rows = {
        {
            text = T("recipe.title", { name = name }),
            kind = "title",
        },
    }

    local function appendMeta(text)
        if text and text ~= L"" then
            rows[#rows + 1] = { text = text, kind = "meta" }
        end
    end

    local level = tonumber(recipeData.potionLevel) or 0
    if level > 0 then
        appendMeta(T("recipe.level", { level = tostring(level) }))
    end
    local yield = tonumber(recipeData.recipeYield) or 0
    if yield > 0 then
        appendMeta(T("recipe.yield", { yield = tostring(yield) }))
    end
    local rate = tonumber(recipeData.successRate)
    local ok = tonumber(recipeData.brewSuccesses) or 0
    local att = tonumber(recipeData.brewAttempts) or 0
    if rate ~= nil and att > 0 then
        local pct = math.floor((rate * 100) + 0.5)
        appendMeta(T("recipe.success", {
            pct = tostring(pct),
            ok = tostring(ok),
            att = tostring(att),
        }))
    end

    local recipe = recipeData.recipe
    local RS = StockPiler3.RecipeSpec
    if type(recipe) == "table" and RS and RS.HydrateRecipeSlots then
        RS.HydrateRecipeSlots(recipe)
    end
    local materials = recipeData.materials
    if type(materials) ~= "table" and type(recipe) == "table" then
        materials = recipe.slots
    end
    if type(materials) ~= "table" or #materials == 0 then
        return rows
    end

    RecipeTooltip.AppendSeparator(rows)

    local statsColor = RgbDef(COLOR_STATS)
    if Tooltips and Tooltips.COLOR_ITEM_BONUS then
        statsColor = Tooltips.COLOR_ITEM_BONUS
    end

    -- Potion Effect (from Use:) fills incomplete mains that omit craftingBonus EFFECT.
    local tipContext = nil
    local effectKey = recipeData.effectKey
    if (type(effectKey) ~= "string" or effectKey == "") and type(recipe) == "table" then
        effectKey = recipe.effectKey
    end
    if type(effectKey) == "string" and effectKey ~= "" then
        tipContext = { effectKey = effectKey }
    elseif RS and RS.NormalizeEffectKeyForUi and type(recipeData.potionUid) == "number" then
        -- Resolve from potion record when recipeData was built without effectKey.
        local potions = StockPiler3.Knowledge and StockPiler3.Knowledge.Potions
            and StockPiler3.Knowledge.Potions()
        local pk = RS.PotionKeyFromUid and RS.PotionKeyFromUid(recipeData.potionUid)
        local potion = type(potions) == "table" and pk and potions[pk] or nil
        if type(potion) == "table" and type(potion.effectKey) == "string" and potion.effectKey ~= "" then
            tipContext = { effectKey = potion.effectKey }
        end
    end

    local sectionShown = 0
    for i = 1, #materials do
        local slot, spec = ResolveSlot(materials[i])
        if type(slot) == "table" then
            local header, stats, role = SlotHeaderAndStats(slot, spec, tipContext)
            local copies = math.max(1, tonumber(slot.perCraft) or 1)
            for _ = 1, copies do
                if sectionShown > 0 then
                    RecipeTooltip.AppendSeparator(rows)
                end
                sectionShown = sectionShown + 1
                AppendIngredientSection(rows, header, stats, role, statsColor)
            end
        end
    end
    return rows
end

function RecipeTooltip.Show(mouseoverWindow, recipeData)
    mouseoverWindow = mouseoverWindow or (SystemData and SystemData.ActiveWindow and SystemData.ActiveWindow.name)
    if mouseoverWindow == nil or mouseoverWindow == "" or type(recipeData) ~= "table" then
        return
    end
    local rows = RecipeTooltip.BuildRows(recipeData)
    local engineMax = RecipeTooltip.EnsureRows(#rows)
    TrimRecipeTooltipRows(rows, engineMax)
    RecipeTooltip.ShowColoredRows(
        mouseoverWindow,
        rows,
        Tooltips and Tooltips.ANCHOR_WINDOW_RIGHT,
        engineMax
    )
end
