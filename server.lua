local PREFIX = "^5[C7FW ➔ ImperialCAD]^7 "

local communityId = GetConvar("imperial_community_id", "")
local apiKey = GetConvar("imperialAPI", "")

local function getDiscordIdFromIdentifier(identifier)
    if not identifier or identifier == "" then return nil end
    return tostring(identifier):gsub("^discord:", "")
end

local function normalizeHeight(h)
  if type(h) ~= "string" or h == "" then return "Not Set" end
  local ft, inch = h:match("(%d+)%s*ft%s*['\"]?(%d+)")
  if ft and inch then return ("%s'%s"):format(ft, inch) end
  return h
end

local function green(msg)
    print("^2" .. PREFIX .. msg .. "^7")
end

local function red(msg)
    print("^1" .. PREFIX .. msg .. "^7")
end

local function yellow(msg)
    print("^3" .. PREFIX .. msg .. "^7")
end

local function OxExec(query, params, cb)
    if cb then
        exports.oxmysql:execute(query, params or {}, cb)
    else
        exports.oxmysql:execute(query, params or {})
    end
end

local function EnsureImperialTable()
    local sql = [[
        CREATE TABLE IF NOT EXISTS c7_fw_imperialcad (
            char_id VARCHAR(64) NOT NULL,
            discord_id VARCHAR(32) NULL,
            imperial_ssn BIGINT NULL,
            PRIMARY KEY (char_id),
            UNIQUE KEY uq_imperial_ssn (imperial_ssn),
            KEY idx_discord (discord_id)
        ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
    ]]

    OxExec(sql, {}, function()
        green("Database table ensured: c7_fw_imperialcad (char_id, discord_id, imperial_ssn)")
    end)
end

local function TriggerImperialCreated(src, charId, ssn, decoded)
    TriggerEvent("c7fw:ImperialCAD:CharacterCreated", src, {
        char_id = tostring(charId),
        imperial_ssn = tonumber(ssn),
        response = decoded
    })
end

local function TriggerImperialRemoved(src, charId, ssn, decoded)
    TriggerEvent("c7fw:ImperialCAD:CharacterRemoved", src, {
        char_id = tostring(charId),
        imperial_ssn = ssn and tonumber(ssn) or nil,
        response = decoded
    })
end

local function NormalizeImperialResult(res)
    if not res then return nil end

    if type(res) == "table" then
        return res
    end

    if type(res) == "string" then
        local ok, decoded = pcall(function()
            return json.decode(res)
        end)
        if ok and type(decoded) == "table" then
            return decoded
        end
    end

    return nil
end

CreateThread(function()
    Wait(1000)

    print(PREFIX .. "Community ID: " .. tostring(communityId))
    print(PREFIX .. "API Key present: " .. tostring(apiKey ~= ""))

    if communityId == "" then
        red("Missing convar: imperial_community_id")
        return
    end

    if apiKey == "" then
        red("Missing convar: imperialAPI")
        return
    end

    green("ImperialCAD config detected")

    if GetResourceState("ImperialCAD") == "started" then
        green("Dependency ImperialCAD is running, connection established.")
    else
        red("ImperialCAD resource not started")
    end

    if GetResourceState("oxmysql") == "started" then
        green("Dependency oxmysql is running, connection established.")
        EnsureImperialTable()
    else
        red("oxmysql resource not started")
    end

    if GetResourceState("c7-scripts-framework-v3") == "started" then
        green("Dependency C7 Framework V3 (C7FW) is running, connection established.")
    else
        red("C7 Framework V3 (C7FW) resource not started")
    end
end)


--=================================================================
-- EVENT: PLAYER LOADED/UNLOADED -> SET/CLEAR CIVILIAN
--=================================================================

local function GetImperialSSNForPlayer(charId, discordId, cb)
    if charId and charId ~= "" then
        OxExec("SELECT imperial_ssn FROM c7_fw_imperialcad WHERE char_id = ? LIMIT 1", { tostring(charId) }, function(rows)
            local ssn = rows and rows[1] and rows[1].imperial_ssn or nil
            if ssn then
                cb(tonumber(ssn))
                return
            end
            if discordId and discordId ~= "" then
                OxExec("SELECT imperial_ssn, char_id FROM c7_fw_imperialcad WHERE discord_id = ? ORDER BY imperial_ssn DESC LIMIT 1", { tostring(discordId) }, function(rows2)
                    local ssn2 = rows2 and rows2[1] and rows2[1].imperial_ssn or nil
                    cb(ssn2 and tonumber(ssn2) or nil)
                end)
            else
                cb(nil)
            end
        end)
        return
    end

    if discordId and discordId ~= "" then
        OxExec("SELECT imperial_ssn FROM c7_fw_imperialcad WHERE discord_id = ? ORDER BY imperial_ssn DESC LIMIT 1", { tostring(discordId) }, function(rows)
            local ssn = rows and rows[1] and rows[1].imperial_ssn or nil
            cb(ssn and tonumber(ssn) or nil)
        end)
        return
    end

    cb(nil)
end

local function ImperialSetActiveCiv(discordId, ssn)
    local commId = GetConvar("imperial_community_id", "")
    local apiKey = GetConvar("imperialAPI", "")

    if commId == "" or apiKey == "" then
        red("Cannot set active civilian: missing imperial convars")
        return
    end

    if not discordId or discordId == "" then
        red("Cannot set active civilian: missing discord id")
        return
    end

    if not ssn then
        red("Cannot set active civilian: missing ssn")
        return
    end

    local payload = {
        commId = tostring(commId),
        users_discordID = tostring(discordId),
        ssn = tostring(ssn)
    }

    local ok = pcall(function()
        exports["ImperialCAD"]:setActiveCivilian(payload, function(success, res)
            if success then
                green(("Active civilian set via export (discord=%s, ssn=%s)"):format(tostring(discordId), tostring(ssn)))
            else
                red(("Failed to set active civilian via export (discord=%s, ssn=%s)"):format(tostring(discordId), tostring(ssn)))
                if res then print(PREFIX .. "Response: " .. tostring(res)) end
            end
        end)
    end)

    if ok then
        return
    end

    yellow("ImperialCAD export setActiveCivilian not available — using HTTP fallback")

    PerformHttpRequest("https://imperialcad.app/api/1.1/wf/setactivecivilian", function(status, respBody)
        respBody = respBody or ""

        if status ~= 200 then
            red(("SetActiveCivilian failed (HTTP %s)"):format(tostring(status)))
            if respBody ~= "" then print(PREFIX .. "Response: " .. respBody) end
            return
        end

        local decoded = nil
        if respBody ~= "" then
            local ok2, data = pcall(function() return json.decode(respBody) end)
            if ok2 and type(data) == "table" then decoded = data end
        end

        if decoded and decoded.status == "success" then
            green(("Active civilian set via HTTP (discord=%s, ssn=%s)"):format(tostring(discordId), tostring(ssn)))
        else
            red(("SetActiveCivilian returned non-success (discord=%s, ssn=%s)"):format(tostring(discordId), tostring(ssn)))
            if decoded then
                print(PREFIX .. "Response:\n" .. json.encode(decoded, { indent = true }))
            else
                print(PREFIX .. "Raw Response: " .. respBody)
            end
        end
    end, "POST", json.encode(payload), {
        ["Content-Type"] = "application/json",
        ["APIKEY"] = apiKey
    })
end

AddEventHandler("C7FW:PLAYER_LOADED", function(src, payload)
    if not src then return end
    payload = payload or {}

    local charId = nil
    if type(payload) == "table" and type(payload.character) == "table" then
        charId = payload.character.char_id
    end
    if (not charId or charId == "") and exports["c7-scripts-framework-v3"] and exports["c7-scripts-framework-v3"].GetCharID then
        charId = exports["c7-scripts-framework-v3"]:GetCharID(src)
    end

    if not charId or charId == "" then
        red(("PLAYER_LOADED: could not resolve char_id for src=%s"):format(tostring(src)))
        return
    end

    local discordId = nil
    if type(payload.identifiers) == "table" and payload.identifiers.discord then
        discordId = tostring(payload.identifiers.discord):gsub("^discord:", "")
    else
        for _, id in ipairs(GetPlayerIdentifiers(src)) do
            if id:sub(1, 8) == "discord:" then
                discordId = id:sub(9)
                break
            end
        end
    end

    if not discordId or discordId == "" then
        red(("PLAYER_LOADED: missing discord identifier for src=%s (char_id=%s)"):format(tostring(src), tostring(charId)))
        return
    end

    GetImperialSSNForPlayer(charId, discordId, function(ssn)
        if not ssn then
            yellow(("PLAYER_LOADED: no imperial_ssn linked for char_id=%s (src=%s)"):format(tostring(charId), tostring(src)))
            return
        end

        yellow(("PLAYER_LOADED: setting active civilian for src=%s char_id=%s ssn=%s"):format(
            tostring(src), tostring(charId), tostring(ssn)
        ))
        ImperialSetActiveCiv(discordId, ssn)
    end)
end)

AddEventHandler("C7FW:PLAYER_UNLOADED", function(src)
    if not src then return end
    yellow(("PLAYER_UNLOADED: clearing active civilian for src=%s"):format(tostring(src)))
    TriggerClientEvent("c7fw-imperial:clearCiv", src)
end)

--=================================================================
-- EVENT: CHARACTER CREATION
--=================================================================

AddEventHandler("c7fw:CharacterCreated", function(src, payload)
    if not payload or type(payload) ~= "table" then
        red("CharacterCreated fired but payload was invalid")
        return
    end

    yellow(("CharacterCreated detected from src=%s - payload:"):format(tostring(src)))
    print(PREFIX .. (json.encode(payload, { indent = true }) or tostring(payload)))

    if communityId == "" then
        red("Cannot create ImperialCAD character: missing convar imperial_community_id")
        return
    end

    if apiKey == "" then
        red("Cannot create ImperialCAD character: missing convar imperialAPI")
        return
    end

    if GetResourceState("ImperialCAD") ~= "started" then
        red("Cannot create ImperialCAD character: ImperialCAD resource not started")
        return
    end

    local char = payload.character or {}
    local ids = payload.identifiers or {}

    local discordId = getDiscordIdFromIdentifier(ids.discord)
    if not discordId or discordId == "" then
        red(("Cannot create ImperialCAD character: missing discord identifier for src=%s"):format(tostring(src)))
        return
    end


    local body = {
        users_discordID = discordId,
        Fname = tostring(char.char_first_name or "Unknown"),
        Mname = "",
        Lname = tostring(char.char_last_name or "Unknown"),
        Birthdate = tostring(char.char_dob or "Unknown"),
        gender = tostring(char.char_gender or "Unknown"),
        race = tostring(char.char_ethnicity or "Unknown"),
        hairC = "Unknown",
        eyeC = "Unknown",
        height = normalizeHeight(char.char_height or "Unknown"),
        weight = tostring(char.char_weight or "Unknown"),
        postal = "Unknown",
        address = "Unknown",
        city = "Unknown",
        county = "Unknown",
        phonenum = "Unknown",
        dlstatus = "Valid",
        citizenid = tostring(char.char_id or "Unknown")
    }


    if body.Fname == "" or body.Lname == "" or body.Birthdate == "" or body.citizenid == "" then
        red(("Cannot create ImperialCAD character: missing required fields (Fname/Lname/Birthdate/citizenid) for src=%s"):format(tostring(src)))
        yellow("Payload character:\n" .. json.encode(char, { indent = true }))
        return
    end

    yellow(("Creating ImperialCAD character for src=%s citizenid=%s discord=%s"):format(
        tostring(src), tostring(body.citizenid), tostring(discordId)
    ))

    exports["ImperialCAD"]:NewCharacter(body, function(success, res)
        local decoded = NormalizeImperialResult(res)
        if success then
            green(("ImperialCAD character created successfully for citizenid=%s"):format(tostring(body.citizenid)))

            local ssn = nil
            if decoded and type(decoded.response) == "table" then
                ssn = decoded.response.ssn
            end

            if not ssn then
                yellow(("ImperialCAD success but SSN missing in response (citizenid=%s)"):format(tostring(body.citizenid)))
                if res then
                    if type(res) == "table" then
                        print(PREFIX .. "Response:\n" .. json.encode(res, { indent = true }))
                    else
                        print(PREFIX .. "Response:\n" .. tostring(res))
                    end
                end
                return
            end

            OxExec([[
                INSERT INTO c7_fw_imperialcad (char_id, discord_id, imperial_ssn)
                VALUES (?, ?, ?)
                ON DUPLICATE KEY UPDATE
                    char_id = VALUES(char_id),
                    discord_id = VALUES(discord_id)
            ]], { tostring(body.citizenid), tostring(discordId), tonumber(ssn) }, function()
                green(("Linked char_id=%s to imperial_ssn=%s"):format(tostring(body.citizenid), tostring(ssn)))
            end)

            print(PREFIX .. "Response:\n" .. json.encode(res, { indent = true }))

            TriggerImperialCreated(src, body.citizenid, ssn, decoded)

        else
            red(("ImperialCAD NewCharacter failed for citizenid=%s"):format(tostring(body.citizenid)))
            if res then
                if decoded then
                    print(PREFIX .. "Response:\n" .. json.encode(decoded, { indent = true }))
                else
                    print(PREFIX .. "Response:\n" .. tostring(res))
                end
            end
        end
    end)
end)


--=================================================================
-- EVENT: CHARACTER REMOVED
--=================================================================

local function ImperialDeleteCharacterHTTP(ssn, cb)
    local apiKey = GetConvar("imperialAPI", "")
    local commId = GetConvar("imperial_community_id", "")

    if apiKey == "" or commId == "" then
        red("Cannot delete ImperialCAD character: missing imperial convars")
        if cb then cb(false) end
        return
    end

    PerformHttpRequest("https://imperialcad.app/api/1.1/wf/deletecharacter", function(status, body)
        body = body or ""

        if status ~= 200 then
            red(("ImperialCAD HTTP delete failed (status=%s, ssn=%s)"):format(tostring(status), tostring(ssn)))
            if body ~= "" then print(PREFIX .. "Response: " .. body) end
            if cb then cb(false) end
            return
        end

        green(("ImperialCAD HTTP delete success for ssn=%s"):format(tostring(ssn)))
        if cb then cb(true) end
    end, "POST", json.encode({
        commId = tostring(commId),
        ssn = tostring(ssn)
    }), {
        ["Content-Type"] = "application/json",
        ["APIKEY"] = apiKey
    })
end

AddEventHandler("c7fw:CharacterRemoved", function(src, payload)
    if not payload or type(payload) ~= "table" then
        red("CharacterRemoved fired but payload invalid")
        return
    end

    local char = payload.character or {}
    local charId = tostring(char.char_id or "")
    if charId == "" then
        red("CharacterRemoved: missing char_id")
        return
    end

    local discordId = nil
    if type(payload.identifiers) == "table" and payload.identifiers.discord then
        discordId = tostring(payload.identifiers.discord):gsub("^discord:", "")
    else
        for _, id in ipairs(GetPlayerIdentifiers(src)) do
            if id:sub(1, 8) == "discord:" then
                discordId = id:sub(9)
                break
            end
        end
    end

    if not discordId or discordId == "" then
        red(("CharacterRemoved: missing discord id for src=%s (char_id=%s)"):format(tostring(src), charId))
        return
    end

    yellow(("CharacterRemoved detected for char_id=%s (src=%s)"):format(charId, tostring(src)))
    yellow(("Deleting from ImperialCAD using citizenid=%s discord=%s"):format(charId, discordId))

    exports["ImperialCAD"]:DeleteCharacter({
        users_discordID = tostring(discordId),
        citizenid = tostring(charId)
    }, function(success, res)
        if success then
            green(("ImperialCAD DeleteCharacter success for citizenid=%s"):format(charId))
            TriggerImperialRemoved(src, charId, ssn, decoded)
        else
            red(("ImperialCAD DeleteCharacter failed for citizenid=%s"):format(charId))
            if res then
                if type(res) == "table" then
                    print(PREFIX .. "Response:\n" .. json.encode(res, { indent = true }))
                else
                    print(PREFIX .. "Response: " .. tostring(res))
                end
            end
        end

        OxExec("DELETE FROM c7_fw_imperialcad WHERE char_id = ?", { charId }, function()
            green(("DB link removed for char_id=%s"):format(charId))
        end)
    end)
end)