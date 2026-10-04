----------------------------------------------------------------
-- StockPiler3 Planner/Reservations -- demand snapshot by specKey
-- Prio-ordered bag allocation stays in Planner.FillWatchRowCraftable;
-- this stores the spec reservation map on the plan for Grow/Refine/Buy.
----------------------------------------------------------------

StockPiler3 = StockPiler3 or {}
StockPiler3.Reservations = StockPiler3.Reservations or {}
local Res = StockPiler3.Reservations

function Res.FromDemand(demand)
    local out = {}
    if type(demand) ~= "table" then
        return out
    end
    for specKey, drow in pairs(demand) do
        if type(drow) == "table" then
            out[specKey] = {
                specKey = specKey,
                have = tonumber(drow.have) or 0,
                absolute = tonumber(drow.absolute) or 0,
                deficit = tonumber(drow.deficit) or 0,
                plantUid = tonumber(drow.plantUid) or 0,
                seedUid = tonumber(drow.seedUid) or 0,
            }
        end
    end
    return out
end
