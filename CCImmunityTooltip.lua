-- CC Immunity Tooltip - Main Logic
-- Displays creature CC immunities in tooltips

local addonName = "CCImmunityTooltip"
local frame = CreateFrame("Frame")

-- ─── Configuration ──────────────────────────────────────────────────────────

-- CC type display names and colors
local ccTypes = {
    sheep = { name = "Polymorph", color = "|cFFFF6EB4" },
    fear = { name = "Fear", color = "|cFF9482C9" },
    stun = { name = "Stun", color = "|cFFFFC125" },
    charm = { name = "Charm/MC", color = "|cFFFFB6C1" },
    slow = { name = "Slow", color = "|cFF00BFFF" },
    root = { name = "Root", color = "|cFF228B22" },
    banish = { name = "Banish", color = "|cFF9370DB" },
    sleep = { name = "Sleep", color = "|cFF87CEEB" },
}

-- Bit flags for CC types (must match CCImmunityData.lua)
-- Based on official WoW MECHANIC_IMMUNITY_MASK values
local CC_BITS = {
    charm = 1,      -- MECHANIC_CHARM (ID 1) - includes Mind Control
    sheep = 2,      -- MECHANIC_DISORIENTED (ID 2) - Polymorph/Sap
    fear = 16,      -- MECHANIC_FEAR (ID 5)
    root = 64,      -- MECHANIC_ROOT (ID 7)
    slow = 1024,    -- MECHANIC_SNARE (ID 11) - Slows/Snare
    stun = 2048,    -- MECHANIC_STUN (ID 12)
    sleep = 512,    -- MECHANIC_SLEEP (ID 10)
    banish = 131072, -- MECHANIC_BANISH (ID 17) - 2^17
}

-- Creature type immunities (fallback when not in database)
local creatureTypeImmunities = {
    ["Mechanical"] = { sheep = true, charm = true },
    ["Undead"] = { sheep = true, charm = true },
    ["Elemental"] = { sheep = true },
    ["Demon"] = {},
}

-- World boss immunities (auto-applied)
local bossImmunities = {
    sheep = true, fear = true, charm = true,
    sleep = true, banish = true,
}

-- Spell IDs that grant temporary immunity (don't learn from these)
local temporaryImmunityAuras = {
    [710] = true,   -- Banish (Rank 1)
    [18647] = true, -- Banish (Rank 2)
    [33786] = true, -- Cyclone
    [1022] = true,  -- Blessing of Protection
    [642] = true,   -- Divine Shield
}

-- Aura names that indicate temporary immunity (anti-boost mechanics, etc.)
local temporaryImmunityNames = {
    ["Diminishing Returns"] = true,
    ["CC Immunity"] = true,
    ["Stun Immunity"] = true,
    ["Root Immunity"] = true,
    ["Snare Immunity"] = true,
}

-- Track when creatures were recently CC'd (for anti-boost detection)
local recentCCApplications = {} -- [guid] = { [ccBit] = timestamp }
local ANTI_BOOST_WINDOW = 60 -- seconds to track CC applications

-- ─── State Management ───────────────────────────────────────────────────────

-- Learned immunities (saved between sessions)
local learnedImmunities = { normal = {}, heroic = {} }

-- GUID tracking for combat log
local guidToCreatureID = {}
local guidToUnit = {}

-- ─── Helper Functions ───────────────────────────────────────────────────────

local function GetCreatureIDFromGUID(guid)
    if not guid then return nil end
    local unitType, _, _, _, _, mobID = strsplit("-", guid)
    if unitType == "Creature" or unitType == "Vehicle" then
        return tonumber(mobID)
    end
    return nil
end

local function GetDifficulty()
    local name, instanceType, difficultyID, difficultyName = GetInstanceInfo()
    
    -- TBC Anniversary uses difficultyID 174 for heroic
    if difficultyID == 2 or difficultyID == 174 or 
       (difficultyName and difficultyName:lower():find("heroic")) then
        return "heroic"
    end
    return "normal"
end

local function IsHeroic()
    return GetDifficulty() == "heroic"
end

local function TrackUnit(unit)
    if not UnitExists(unit) then return end
    local guid = UnitGUID(unit)
    if not guid then return end
    local creatureID = GetCreatureIDFromGUID(guid)
    if creatureID then
        guidToCreatureID[guid] = creatureID
        guidToUnit[guid] = unit
    end
end

local function GetNameForCreatureGUID(guid, creatureID)
    -- Verify the cached unit token still points at this GUID before trusting its name.
    -- Unit tokens like "target" / "mouseover" become stale when the player changes target,
    -- which previously caused PvP messages like "Learned: PlayerName is immune to ...".
    local unit = guidToUnit[guid]
    if unit and UnitExists(unit) and UnitGUID(unit) == guid then
        local name = UnitName(unit)
        if name then return name end
    end
    return "ID:" .. (creatureID or "?")
end

local function HasTemporaryImmunity(guid)
    local unit = guidToUnit[guid]
    if not unit or not UnitExists(unit) or UnitGUID(unit) ~= guid then return false end
    
    -- Check debuffs for temporary immunity spells
    local i = 1
    while true do
        local name, _, _, _, _, _, _, _, _, spellID = UnitDebuff(unit, i)
        if not spellID then break end
        if temporaryImmunityAuras[spellID] then return true end
        
        -- Check aura name for anti-boost mechanics
        if name and temporaryImmunityNames[name] then return true end
        i = i + 1
    end
    
    -- Check buffs for temporary immunity spells
    i = 1
    while true do
        local name, _, _, _, _, _, _, _, _, spellID = UnitBuff(unit, i)
        if not spellID then break end
        if temporaryImmunityAuras[spellID] then return true end
        
        -- Check aura name for anti-boost mechanics
        if name and temporaryImmunityNames[name] then return true end
        i = i + 1
    end
    
    return false
end

-- ─── Bitflag Decoding ───────────────────────────────────────────────────────

local function DecodeBitflag(flag)
    if not flag or flag == 0 then return {} end
    local immunities = {}
    for ccKey, bitValue in pairs(CC_BITS) do
        if bit.band(flag, bitValue) ~= 0 then
            immunities[ccKey] = true
        end
    end
    return immunities
end

local function EncodeBitflag(immunities)
    local flag = 0
    for ccKey, value in pairs(immunities) do
        if value and CC_BITS[ccKey] then
            flag = bit.bor(flag, CC_BITS[ccKey])
        end
    end
    return flag
end

-- ─── Immunity Resolution ────────────────────────────────────────────────────

local function GetTooltipCreatureInfo()
    local name, unit = GameTooltip:GetUnit()
    if not unit or not UnitExists(unit) then return nil end
    
    local guid = UnitGUID(unit)
    local creatureID = GetCreatureIDFromGUID(guid)
    
    if creatureID then
        guidToCreatureID[guid] = creatureID
        guidToUnit[guid] = unit
    end
    
    return {
        name = UnitName(unit),
        type = UnitCreatureType(unit),
        classification = UnitClassification(unit),
        id = creatureID,
    }
end

local function GetAllImmunities(creatureInfo)
    if not creatureInfo then return nil end

    local heroic = IsHeroic()
    local immunities = {}

    -- Check if this creature is overridden (ignore static DB)
    local isOverride = false
    if CCImmunityTooltipDB and CCImmunityTooltipDB.overrides then
        local difficulty = heroic and "heroic" or "normal"
        if CCImmunityTooltipDB.overrides[difficulty] and CCImmunityTooltipDB.overrides[difficulty][creatureInfo.id] then
            isOverride = true
        end
    end

    -- World bosses: blanket immunities
    if creatureInfo.classification == "worldboss" then
        for cc in pairs(bossImmunities) do immunities[cc] = true end
    end

    -- Static database (skip if overridden)
    if not isOverride then
        -- Static database: shared (applies to both normal + heroic)
        if creatureInfo.id and CCImmunityDB.Both[creatureInfo.id] then
            local decoded = DecodeBitflag(CCImmunityDB.Both[creatureInfo.id])
            for cc, v in pairs(decoded) do immunities[cc] = v end
        end

        -- Static database: normal immunities (always apply)
        if creatureInfo.id and CCImmunityDB.Normal[creatureInfo.id] then
            local decoded = DecodeBitflag(CCImmunityDB.Normal[creatureInfo.id])
            for cc, v in pairs(decoded) do immunities[cc] = v end
        end

        -- Static database: additional heroic immunities
        if heroic and creatureInfo.id and CCImmunityDB.Heroic[creatureInfo.id] then
            local decoded = DecodeBitflag(CCImmunityDB.Heroic[creatureInfo.id])
            for cc, v in pairs(decoded) do immunities[cc] = v end
        end
    end

    -- Learned from combat log: normal
    local learnedNormal = learnedImmunities.normal
    if learnedNormal and creatureInfo.id and learnedNormal[creatureInfo.id] then
        for cc, v in pairs(learnedNormal[creatureInfo.id]) do
            immunities[cc] = v
        end
    end

    -- Learned from combat log: heroic
    if heroic then
        local learnedHeroic = learnedImmunities.heroic
        if learnedHeroic and creatureInfo.id and learnedHeroic[creatureInfo.id] then
            for cc, v in pairs(learnedHeroic[creatureInfo.id]) do
                immunities[cc] = v
            end
        end
    end

    -- Creature type fallback (skip if overridden or has learned data)
    local hasLearnedData = (learnedNormal and creatureInfo.id and learnedNormal[creatureInfo.id])
                           or (heroic and learnedImmunities.heroic and creatureInfo.id and learnedImmunities.heroic[creatureInfo.id])
    if not isOverride and not hasLearnedData then
        if creatureInfo.type and creatureTypeImmunities[creatureInfo.type] then
            for cc, v in pairs(creatureTypeImmunities[creatureInfo.type]) do
                if immunities[cc] == nil then immunities[cc] = v end
            end
        end
    end

    return next(immunities) and immunities or nil
end

-- ─── Tooltip Integration ────────────────────────────────────────────────────

local function AddImmunityInfo(tooltip)
    local creatureInfo = GetTooltipCreatureInfo()
    if not creatureInfo then return end
    local immunities = GetAllImmunities(creatureInfo)
    if not immunities then return end

    local immuneList = {}
    local notImmuneList = {}
    local totalCCTypesExceptBanish = 0
    local immuneCountExceptBanish = 0
    local hasBanish = false
    local isBanishable = (creatureInfo.type == "Elemental" or creatureInfo.type == "Demon")
    
    -- Trackable CC types excluding banish (banish is shown separately and only matters
    -- for Elementals/Demons). These must all be keys in CC_BITS — phantom entries here
    -- break the "ALL CC" threshold because immuneCountExceptBanish can never reach the total.
    local allCCTypes = { "sheep", "fear", "stun", "charm", "slow", "root", "sleep" }
    totalCCTypesExceptBanish = #allCCTypes
    
    -- Check which CC types are NOT immune
    for _, ccKey in ipairs(allCCTypes) do
        if not immunities[ccKey] and ccTypes[ccKey] then
            table.insert(notImmuneList, ccTypes[ccKey].name)
        end
    end
    
    -- Build immunity list
    for ccKey, immune in pairs(immunities) do
        if immune and ccTypes[ccKey] then
            if ccKey == "banish" then
                if isBanishable then
                    hasBanish = true
                end
            elseif ccKey ~= "mc" then  -- Skip mc since it's the same as charm
                immuneCountExceptBanish = immuneCountExceptBanish + 1
                local ccInfo = ccTypes[ccKey]
                table.insert(immuneList, ccInfo.color .. ccInfo.name .. "|r")
            end
        end
    end

    if #immuneList > 0 or hasBanish then
        table.sort(immuneList)
        tooltip:AddLine(" ")
        local diffTag = IsHeroic() and " |cFF00CCFF(Heroic)|r" or ""
        
        -- If immune to all CC (excluding banish), show simplified message
        if immuneCountExceptBanish >= totalCCTypesExceptBanish then
            if hasBanish then
                tooltip:AddLine("|cFFFF4500Immune to:|r |cFFFFFFFFALL CC (including Banish)|r" .. diffTag, 1, 1, 1, true)
            else
                -- Immune to everything except banish
                if isBanishable then
                    tooltip:AddLine("|cFFFF4500Immune to:|r |cFFFFFFFFALL CC (except Banish)|r" .. diffTag, 1, 1, 1, true)
                else
                    tooltip:AddLine("|cFFFF4500Immune to:|r |cFFFFFFFFALL CC|r" .. diffTag, 1, 1, 1, true)
                end
            end
        -- If missing 1-3 immunities (i.e., immune to a majority of 4+/7), show "ALL CC (except...)".
        -- 3 is the crossover: at 3 missing the "except" list is the same length as the immune list,
        -- but the "except" form is more useful because it tells you what actually works.
        elseif #notImmuneList > 0 and #notImmuneList <= 3 then
            local exceptList = table.concat(notImmuneList, ", ")
            if hasBanish then
                tooltip:AddLine("|cFFFF4500Immune to:|r |cFFFFFFFFALL CC (except " .. exceptList .. ")|r" .. diffTag, 1, 1, 1, true)
            else
                if isBanishable then
                    tooltip:AddLine("|cFFFF4500Immune to:|r |cFFFFFFFFALL CC (except Banish, " .. exceptList .. ")|r" .. diffTag, 1, 1, 1, true)
                else
                    tooltip:AddLine("|cFFFF4500Immune to:|r |cFFFFFFFFALL CC (except " .. exceptList .. ")|r" .. diffTag, 1, 1, 1, true)
                end
            end
        else
            -- Not immune to most things, show the list
            if hasBanish then
                table.insert(immuneList, ccTypes["banish"].color .. ccTypes["banish"].name .. "|r")
            end
            tooltip:AddLine("|cFFFF4500Immune to:|r " .. table.concat(immuneList, ", ") .. diffTag, 1, 1, 1, true)
        end
    end
end

GameTooltip:HookScript("OnTooltipSetUnit", function(tooltip)
    AddImmunityInfo(tooltip)
end)

-- ─── Event Handlers ─────────────────────────────────────────────────────────

frame:RegisterEvent("ADDON_LOADED")
frame:RegisterEvent("UPDATE_MOUSEOVER_UNIT")
frame:RegisterEvent("PLAYER_TARGET_CHANGED")
frame:RegisterEvent("PLAYER_FOCUS_CHANGED")
frame:RegisterEvent("NAME_PLATE_UNIT_ADDED")

-- Periodic cleanup of tracking data
local lastCleanup = 0
local CLEANUP_INTERVAL = 300 -- Clean every 5 minutes

frame:SetScript("OnEvent", function(self, event, ...)
    if event == "ADDON_LOADED" and ... == addonName then
        -- Load saved data
        if CCImmunityTooltipDB then
            if CCImmunityTooltipDB.learnedImmunities then
                local saved = CCImmunityTooltipDB.learnedImmunities
                if saved.normal or saved.heroic then
                    learnedImmunities = saved
                else
                    -- Old format migration
                    learnedImmunities = { normal = saved, heroic = {} }
                end
            end
        else
            CCImmunityTooltipDB = {}
        end
        print("|cFFFF4500CC Immunity Tooltip|r loaded. Type /ccimmunity for help.")

    elseif event == "UPDATE_MOUSEOVER_UNIT" then
        TrackUnit("mouseover")
        
        -- Periodic cleanup
        local now = GetTime()
        if now - lastCleanup > CLEANUP_INTERVAL then
            lastCleanup = now
            -- Clean up old CC application tracking
            for guid, ccData in pairs(recentCCApplications) do
                for ccBit, timestamp in pairs(ccData) do
                    if now - timestamp > ANTI_BOOST_WINDOW then
                        ccData[ccBit] = nil
                    end
                end
                if not next(ccData) then
                    recentCCApplications[guid] = nil
                end
            end
        end

    elseif event == "PLAYER_TARGET_CHANGED" then
        TrackUnit("target")

    elseif event == "PLAYER_FOCUS_CHANGED" then
        TrackUnit("focus")

    elseif event == "NAME_PLATE_UNIT_ADDED" then
        TrackUnit(...)
    end
end)

-- ─── Auto-Learning (placeholder - implemented in CCImmunitySpells.lua) ──────

-- The spell mapping and combat log handler are in CCImmunitySpells.lua
-- to keep this file focused on core logic

-- ─── Slash Commands ─────────────────────────────────────────────────────────

SLASH_CCIMMUNITY1 = "/ccimmunity"

-- ─── Spell ID to CC Type Mapping (for Auto-Learning) ───────────────────────

local spellToCC = {
    -- Polymorph (sheep=2, MECHANIC_DISORIENTED)
    [118]=2, [12824]=2, [12825]=2, [12826]=2, [28270]=2, [28271]=2, [28272]=2,
    -- Fear (fear=16, MECHANIC_FEAR)
    [5782]=16, [6213]=16, [6215]=16, [5484]=16, [5485]=16, [8122]=16, [8124]=16, [10888]=16, [10890]=16, [5246]=16, [1513]=16,
    -- Stun (stun=2048, MECHANIC_STUN)
    [853]=2048, [5588]=2048, [5589]=2048, [408]=2048, [8643]=2048, [1833]=2048, [12809]=2048, [46968]=2048, [20253]=2048,
    -- Mind Control (charm=1, MECHANIC_CHARM) - MC and Charm share same mechanic
    [605]=1, [10911]=1, [10912]=1,
    -- Root (root=64, MECHANIC_ROOT)
    [339]=64, [1062]=64, [5195]=64, [5196]=64, [9852]=64, [9853]=64, [122]=64, [865]=64, [6131]=64, [10230]=64, [19306]=64, [19185]=64,
    -- Slow (slow=1024, MECHANIC_SNARE)
    [116]=1024, [205]=1024, [837]=1024, [7322]=1024, [6136]=1024, [1715]=1024, [2974]=1024,
    -- Banish (banish=131072, MECHANIC_BANISH)
    [710]=131072, [18647]=131072,
    -- Charm (charm=1, MECHANIC_CHARM) - same as Mind Control
    [13181]=1, [1098]=1,
    -- Sleep (sleep=512, MECHANIC_SLEEP)
    [2637]=512, [18657]=512, [18658]=512, [9484]=512, [9485]=512, [19503]=512,
}

-- ─── Auto-Learning from Combat Log ──────────────────────────────────────────

local function LearnImmunity(creatureID, ccBit, destGUID, difficulty)
    if not creatureID or not ccBit then return end
    difficulty = difficulty or GetDifficulty()

    -- Convert bit to ccKey for storage
    local ccKey
    for k, v in pairs(CC_BITS) do
        if v == ccBit then ccKey = k break end
    end
    if not ccKey then return end

    -- Check if this creature is marked as override (ignore static DB)
    local isOverride = false
    if CCImmunityTooltipDB and CCImmunityTooltipDB.overrides then
        if CCImmunityTooltipDB.overrides[difficulty] and CCImmunityTooltipDB.overrides[difficulty][creatureID] then
            isOverride = true
        end
    end

    -- Check if already in static database (unless overridden)
    local inStaticDB = false
    if not isOverride then
        -- Check DB_BOTH (applies to all difficulties)
        if CCImmunityDB.Both[creatureID] then
            if bit.band(CCImmunityDB.Both[creatureID], ccBit) ~= 0 then
                inStaticDB = true
            end
        end
        
        -- Check DB_NORMAL (applies to both normal and heroic base)
        if not inStaticDB and CCImmunityDB.Normal[creatureID] then
            if bit.band(CCImmunityDB.Normal[creatureID], ccBit) ~= 0 then
                inStaticDB = true
            end
        end
        
        -- Check DB_HEROIC if in heroic difficulty
        if not inStaticDB and difficulty == "heroic" and CCImmunityDB.Heroic[creatureID] then
            if bit.band(CCImmunityDB.Heroic[creatureID], ccBit) ~= 0 then
                inStaticDB = true
            end
        end
        
        -- Already in static database, don't learn
        if inStaticDB then return false end
    end

    if not learnedImmunities[difficulty] then
        learnedImmunities[difficulty] = {}
    end
    if not learnedImmunities[difficulty][creatureID] then
        learnedImmunities[difficulty][creatureID] = {}
    end

    if not learnedImmunities[difficulty][creatureID][ccKey] then
        learnedImmunities[difficulty][creatureID][ccKey] = true
        if CCImmunityTooltipDB then
            CCImmunityTooltipDB.learnedImmunities = learnedImmunities
        end
        
        local name = GetNameForCreatureGUID(destGUID, creatureID)
        local ccName = ccTypes[ccKey] and ccTypes[ccKey].name or ccKey
        local diff = difficulty == "heroic" and "|cFF00CCFFHeroic|r" or "Normal"
        print("|cFFFF4500[CC Immunity]|r Learned (" .. diff .. "): " .. name .. " is immune to " .. ccName)
        return true
    end
    return false
end

frame:RegisterEvent("COMBAT_LOG_EVENT_UNFILTERED")

local originalSetScript = frame:GetScript("OnEvent")
frame:SetScript("OnEvent", function(self, event, ...)
    -- Call original handler first
    if originalSetScript and event ~= "COMBAT_LOG_EVENT_UNFILTERED" then
        originalSetScript(self, event, ...)
    end
    
    -- Combat log handling
    if event == "COMBAT_LOG_EVENT_UNFILTERED" then
        local timestamp, subevent, hideCaster,
              sourceGUID, sourceName, sourceFlags, sourceRaidFlags,
              destGUID, destName, destFlags, destRaidFlags,
              spellID, spellName, spellSchool, missType = CombatLogGetCurrentEventInfo()

        local ccBit = spellToCC[spellID]
        if not ccBit then return end
        
        -- Only act on non-player NPCs. GetCreatureIDFromGUID returns nil for Players, Pets,
        -- and anything else without a creature ID, so PvP and pet combat is ignored entirely.
        local creatureID = guidToCreatureID[destGUID] or GetCreatureIDFromGUID(destGUID)
        if not creatureID then return end

        guidToCreatureID[destGUID] = creatureID
        
        -- Track successful CC applications (for anti-boost detection AND auto-override)
        if subevent == "SPELL_AURA_APPLIED" then
            -- Check if static DB says this should be immune
            local difficulty = GetDifficulty()
            local shouldBeImmune = false
            
            -- Check static databases
            if CCImmunityDB.Both[creatureID] and bit.band(CCImmunityDB.Both[creatureID], ccBit) ~= 0 then
                shouldBeImmune = true
            elseif CCImmunityDB.Normal[creatureID] and bit.band(CCImmunityDB.Normal[creatureID], ccBit) ~= 0 then
                shouldBeImmune = true
            elseif difficulty == "heroic" and CCImmunityDB.Heroic[creatureID] and bit.band(CCImmunityDB.Heroic[creatureID], ccBit) ~= 0 then
                shouldBeImmune = true
            end
            
            -- Auto-override if static DB is wrong
            if shouldBeImmune then
                -- Initialize override system
                if not CCImmunityTooltipDB then CCImmunityTooltipDB = {} end
                if not CCImmunityTooltipDB.overrides then
                    CCImmunityTooltipDB.overrides = { normal = {}, heroic = {} }
                end
                
                -- Check if not already overridden
                if not CCImmunityTooltipDB.overrides[difficulty][creatureID] then
                    -- Set override
                    CCImmunityTooltipDB.overrides[difficulty][creatureID] = true
                    
                    -- Copy static DB to learned
                    if not learnedImmunities[difficulty] then
                        learnedImmunities[difficulty] = {}
                    end
                    if not learnedImmunities[difficulty][creatureID] then
                        learnedImmunities[difficulty][creatureID] = {}
                    end
                    
                    -- Copy from all static DBs
                    if CCImmunityDB.Both[creatureID] then
                        local decoded = DecodeBitflag(CCImmunityDB.Both[creatureID])
                        for cc, v in pairs(decoded) do
                            if v and ccTypes[cc] then
                                learnedImmunities[difficulty][creatureID][cc] = true
                            end
                        end
                    end
                    if CCImmunityDB.Normal[creatureID] then
                        local decoded = DecodeBitflag(CCImmunityDB.Normal[creatureID])
                        for cc, v in pairs(decoded) do
                            if v and ccTypes[cc] then
                                learnedImmunities[difficulty][creatureID][cc] = true
                            end
                        end
                    end
                    if difficulty == "heroic" and CCImmunityDB.Heroic[creatureID] then
                        local decoded = DecodeBitflag(CCImmunityDB.Heroic[creatureID])
                        for cc, v in pairs(decoded) do
                            if v and ccTypes[cc] then
                                learnedImmunities[difficulty][creatureID][cc] = true
                            end
                        end
                    end
                    
                    CCImmunityTooltipDB.learnedImmunities = learnedImmunities
                    
                    local name = GetNameForCreatureGUID(destGUID, creatureID)
                    local ccKey
                    for k, v in pairs(CC_BITS) do
                        if v == ccBit then ccKey = k break end
                    end
                    local ccName = (ccKey and ccTypes[ccKey] and ccTypes[ccKey].name) or "Unknown"
                    print("|cFFFF4500[CC Immunity]|r Auto-override: " .. name .. " (static DB wrong about " .. ccName .. ")")
                end
                
                -- Remove the incorrect immunity from learned list
                local ccKey
                for k, v in pairs(CC_BITS) do
                    if v == ccBit then ccKey = k break end
                end
                if ccKey and learnedImmunities[difficulty] and learnedImmunities[difficulty][creatureID] then
                    learnedImmunities[difficulty][creatureID][ccKey] = nil
                    CCImmunityTooltipDB.learnedImmunities = learnedImmunities
                end
            end
            
            -- Track for anti-boost (only for stuns, roots, slows)
            if ccBit == 2048 or ccBit == 64 or ccBit == 1024 then
                if not recentCCApplications[destGUID] then
                    recentCCApplications[destGUID] = {}
                end
                recentCCApplications[destGUID][ccBit] = GetTime()
            end
            return
        end

        -- Handle IMMUNE events
        if subevent ~= "SPELL_MISSED" or missType ~= "IMMUNE" then return end

        -- Check for temporary immunity
        if HasTemporaryImmunity(destGUID) then return end
        
        -- Anti-boost detection: Don't learn if this CC was recently successfully applied
        if recentCCApplications[destGUID] and recentCCApplications[destGUID][ccBit] then
            local timeSinceApplication = GetTime() - recentCCApplications[destGUID][ccBit]
            if timeSinceApplication < ANTI_BOOST_WINDOW then
                -- This is likely anti-boost immunity, not a permanent immunity
                return
            end
        end

        local wasNew = LearnImmunity(creatureID, ccBit, destGUID, GetDifficulty())
        
        if wasNew then
            local _, unit = GameTooltip:GetUnit()
            if unit and UnitExists(unit) then
                local tipGUID = UnitGUID(unit)
                if tipGUID and guidToCreatureID[tipGUID] == creatureID then
                    -- Refresh tooltip by simulating mouseover
                    GameTooltip:SetUnit(unit)
                end
            end
        end
    end
end)

-- ─── Slash Commands ─────────────────────────────────────────────────────────

SLASH_CCIMMUNITY1 = "/ccimmunity"
SLASH_CCIMMUNITY2 = "/ccim"
SlashCmdList["CCIMMUNITY"] = function(msg)
    local cmd, rest = strsplit(" ", msg, 2)
    cmd = string.lower(cmd or "")
    
    if cmd == "set" then
        -- Parse difficulty
        local difficulty, ccList
        local firstWord = strsplit(" ", rest or "", 2)
        if firstWord == "heroic" or firstWord == "normal" then
            difficulty = firstWord
            ccList = rest:sub(#firstWord + 2)
        else
            difficulty = GetDifficulty()
            ccList = rest
        end
        
        local guid = UnitGUID("target")
        if not guid then
            print("|cFFFF4500[CC Immunity]|r No target selected.")
            return
        end
        
        local creatureID = GetCreatureIDFromGUID(guid)
        if not creatureID then
            print("|cFFFF4500[CC Immunity]|r Target is not a creature.")
            return
        end
        
        if not learnedImmunities[difficulty] then
            learnedImmunities[difficulty] = {}
        end
        if not learnedImmunities[difficulty][creatureID] then
            learnedImmunities[difficulty][creatureID] = {}
        end
        
        -- Parse CC types
        local added = {}
        for ccType in string.gmatch(ccList or "", "%S+") do
            ccType = string.lower(ccType)
            if ccTypes[ccType] then
                learnedImmunities[difficulty][creatureID][ccType] = true
                table.insert(added, ccTypes[ccType].name)
            end
        end
        
        if #added > 0 then
            CCImmunityTooltipDB.learnedImmunities = learnedImmunities
            local diffTag = difficulty == "heroic" and "|cFF00CCFFHeroic|r" or "Normal"
            print("|cFFFF4500[CC Immunity]|r Set (" .. diffTag .. "): " .. table.concat(added, ", "))
        else
            print("|cFFFF4500[CC Immunity]|r No valid CC types specified.")
        end
        
    elseif cmd == "clear" then
        local difficulty = strsplit(" ", rest or "")
        if difficulty ~= "heroic" and difficulty ~= "normal" then
            difficulty = GetDifficulty()
        end
        
        local guid = UnitGUID("target")
        if not guid then
            print("|cFFFF4500[CC Immunity]|r No target selected.")
            return
        end
        
        local creatureID = GetCreatureIDFromGUID(guid)
        if creatureID and learnedImmunities[difficulty] then
            learnedImmunities[difficulty][creatureID] = nil
            CCImmunityTooltipDB.learnedImmunities = learnedImmunities
            local diffTag = difficulty == "heroic" and "|cFF00CCFFHeroic|r" or "Normal"
            print("|cFFFF4500[CC Immunity]|r Cleared (" .. diffTag .. ").")
        end
        
    elseif cmd == "list" then
        print("|cFFFF4500CC Immunity - Learned Immunities:|r")
        for difficulty, creatures in pairs(learnedImmunities) do
            for id, immunities in pairs(creatures) do
                local ccList = {}
                for ccKey in pairs(immunities) do
                    if ccTypes[ccKey] then
                        table.insert(ccList, ccTypes[ccKey].name)
                    end
                end
                if #ccList > 0 then
                    local diffTag = difficulty == "heroic" and "|cFF00CCFF[Heroic]|r" or "[Normal]"
                    print(diffTag .. " ID:" .. id .. ": " .. table.concat(ccList, ", "))
                end
            end
        end
        
    elseif cmd == "override" then
        local difficulty = strsplit(" ", rest or "")
        if difficulty ~= "heroic" and difficulty ~= "normal" then
            difficulty = GetDifficulty()
        end
        
        local guid = UnitGUID("target")
        if not guid then
            print("|cFFFF4500[CC Immunity]|r No target selected.")
            return
        end
        
        local creatureID = GetCreatureIDFromGUID(guid)
        if not creatureID then
            print("|cFFFF4500[CC Immunity]|r Target is not a creature.")
            return
        end
        
        -- Initialize override list if needed
        if not CCImmunityTooltipDB.overrides then
            CCImmunityTooltipDB.overrides = { normal = {}, heroic = {} }
        end
        
        -- Copy static database immunities to learned list before overriding
        if not learnedImmunities[difficulty] then
            learnedImmunities[difficulty] = {}
        end
        if not learnedImmunities[difficulty][creatureID] then
            learnedImmunities[difficulty][creatureID] = {}
        end
        
        local copiedCount = 0
        
        -- Copy from DB_BOTH
        if CCImmunityDB.Both[creatureID] then
            local decoded = DecodeBitflag(CCImmunityDB.Both[creatureID])
            for cc, v in pairs(decoded) do
                if v and ccTypes[cc] then
                    learnedImmunities[difficulty][creatureID][cc] = true
                    copiedCount = copiedCount + 1
                end
            end
        end
        
        -- Copy from DB_NORMAL
        if CCImmunityDB.Normal[creatureID] then
            local decoded = DecodeBitflag(CCImmunityDB.Normal[creatureID])
            for cc, v in pairs(decoded) do
                if v and ccTypes[cc] then
                    learnedImmunities[difficulty][creatureID][cc] = true
                    copiedCount = copiedCount + 1
                end
            end
        end
        
        -- Copy from DB_HEROIC if in heroic
        if difficulty == "heroic" and CCImmunityDB.Heroic[creatureID] then
            local decoded = DecodeBitflag(CCImmunityDB.Heroic[creatureID])
            for cc, v in pairs(decoded) do
                if v and ccTypes[cc] then
                    learnedImmunities[difficulty][creatureID][cc] = true
                    copiedCount = copiedCount + 1
                end
            end
        end
        
        -- Mark this creature as overridden (ignore static DB)
        CCImmunityTooltipDB.overrides[difficulty][creatureID] = true
        CCImmunityTooltipDB.learnedImmunities = learnedImmunities
        
        local diffTag = difficulty == "heroic" and "|cFF00CCFFHeroic|r" or "Normal"
        local name = UnitName("target")
        print("|cFFFF4500[CC Immunity]|r Override set for " .. (name or "ID:" .. creatureID) .. " (" .. diffTag .. ")")
        print("Copied " .. copiedCount .. " immunities from static DB to learned list.")
        print("Use '/ccim remove <type>' to remove incorrect immunities.")
        print("Static database will be ignored - only learned immunities will show.")
        
    elseif cmd == "remove" then
        local difficulty, ccList
        local firstWord = strsplit(" ", rest or "", 2)
        if firstWord == "heroic" or firstWord == "normal" then
            difficulty = firstWord
            ccList = rest:sub(#firstWord + 2)
        else
            difficulty = GetDifficulty()
            ccList = rest
        end
        
        local guid = UnitGUID("target")
        if not guid then
            print("|cFFFF4500[CC Immunity]|r No target selected.")
            return
        end
        
        local creatureID = GetCreatureIDFromGUID(guid)
        if not creatureID then
            print("|cFFFF4500[CC Immunity]|r Target is not a creature.")
            return
        end
        
        if not learnedImmunities[difficulty] or not learnedImmunities[difficulty][creatureID] then
            print("|cFFFF4500[CC Immunity]|r No learned immunities to remove.")
            return
        end
        
        -- Remove specified CC types
        local removed = {}
        for ccType in string.gmatch(ccList or "", "%S+") do
            ccType = string.lower(ccType)
            if ccTypes[ccType] and learnedImmunities[difficulty][creatureID][ccType] then
                learnedImmunities[difficulty][creatureID][ccType] = nil
                table.insert(removed, ccTypes[ccType].name)
            end
        end
        
        if #removed > 0 then
            CCImmunityTooltipDB.learnedImmunities = learnedImmunities
            local diffTag = difficulty == "heroic" and "|cFF00CCFFHeroic|r" or "Normal"
            print("|cFFFF4500[CC Immunity]|r Removed (" .. diffTag .. "): " .. table.concat(removed, ", "))
        else
            print("|cFFFF4500[CC Immunity]|r No valid CC types to remove.")
        end
        
    elseif cmd == "debug" then
        local guid = UnitGUID("target")
        if not guid then
            print("|cFFFF4500[CC Immunity]|r No target selected.")
            return
        end
        
        local creatureID = GetCreatureIDFromGUID(guid)
        if not creatureID then
            print("|cFFFF4500[CC Immunity]|r Target is not a creature.")
            return
        end
        
        local name = UnitName("target")
        local difficulty = GetDifficulty()
        
        print("|cFFFF4500[CC Immunity Debug]|r")
        print("  Name: " .. (name or "Unknown"))
        print("  ID: " .. creatureID)
        print("  Difficulty: " .. difficulty)
        print("  Classification: " .. (UnitClassification("target") or "normal"))
        print("  Type: " .. (UnitCreatureType("target") or "Unknown"))
        
        -- Check static databases
        local bothFlag = CCImmunityDB.Both[creatureID]
        local normalFlag = CCImmunityDB.Normal[creatureID]
        local heroicFlag = CCImmunityDB.Heroic[creatureID]
        
        if bothFlag then
            local imms = DecodeBitflag(bothFlag)
            local list = {}
            for cc in pairs(imms) do
                if ccTypes[cc] then table.insert(list, ccTypes[cc].name) end
            end
            print("  DB_BOTH (flag=" .. bothFlag .. "): " .. table.concat(list, ", "))
        end
        
        if normalFlag then
            local imms = DecodeBitflag(normalFlag)
            local list = {}
            for cc in pairs(imms) do
                if ccTypes[cc] then table.insert(list, ccTypes[cc].name) end
            end
            print("  DB_NORMAL (flag=" .. normalFlag .. "): " .. table.concat(list, ", "))
        end
        
        if heroicFlag then
            local imms = DecodeBitflag(heroicFlag)
            local list = {}
            for cc in pairs(imms) do
                if ccTypes[cc] then table.insert(list, ccTypes[cc].name) end
            end
            print("  DB_HEROIC (flag=" .. heroicFlag .. "): " .. table.concat(list, ", "))
        end
        
        if not bothFlag and not normalFlag and not heroicFlag then
            print("  Not in static database")
        end
        
        -- Check learned
        if learnedImmunities.normal and learnedImmunities.normal[creatureID] then
            local list = {}
            for cc in pairs(learnedImmunities.normal[creatureID]) do
                if ccTypes[cc] then table.insert(list, ccTypes[cc].name) end
            end
            print("  Learned (Normal): " .. table.concat(list, ", "))
        end
        
        if learnedImmunities.heroic and learnedImmunities.heroic[creatureID] then
            local list = {}
            for cc in pairs(learnedImmunities.heroic[creatureID]) do
                if ccTypes[cc] then table.insert(list, ccTypes[cc].name) end
            end
            print("  Learned (Heroic): " .. table.concat(list, ", "))
        end
        
    else
        print("|cFFFF4500[CC Immunity Tooltip]|r Commands:")
        print("  /ccim set [difficulty] <types>     - Manually add immunities for target")
        print("  /ccim remove [difficulty] <types>  - Remove specific immunities")
        print("  /ccim clear [difficulty]           - Clear ALL learned immunities for target")
        print("  /ccim override [difficulty]        - Copy static DB to learned, ignore static")
        print("  /ccim list                         - List all learned immunities")
        print("  /ccim debug                        - Show debug info for current target")
        print("  [difficulty] = 'heroic' or 'normal' (defaults to current)")
        print("  CC types: sheep, fear, stun, charm, slow, root, banish, sleep")
        print("  Note: 'charm' covers both Charm and Mind Control (same mechanic)")
        print(" ")
        print("Workflow to fix incorrect static data:")
        print("  1. Target mob and use /ccim override")
        print("  2. Use /ccim remove <type> to remove incorrect immunities")
        print("  3. Try CCs in-game to learn the real immunities")
    end
end
