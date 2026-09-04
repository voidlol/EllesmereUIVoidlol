-------------------------------------------------------------------------------
--  LibEUIExport-1.0
--  Turns (name, type, data) into one copy-paste-safe export string, and back.
--  Two calls, no more:
--
--    local str = LibStub("LibEUIExport-1.0"):Export(name, dataType, data)
--    local result, err = LibStub("LibEUIExport-1.0"):Import(str)
--    -- result = { name = ..., type = ..., data = ... } on success
--    -- result = nil, err (a string) on failure -- Import never throws, the
--    -- input is always something a user pasted in and may be garbage.
--
--  `data` may be any nested combination of string/number/boolean/nil/table
--  (exactly what a settings/profile table is ever made of). Same rationale
--  as EllesmereUI_Profiles.lua's own serializer: no AceSerializer dependency,
--  a few dozen lines cover every value type addon settings actually use.
--  Compression/encoding is LibDeflate (CompressDeflate + EncodeForPrint),
--  the same pairing WeakAuras/M33kAuras-style export strings use -- LibStub
--  resolves it from whichever addon already embeds it (EllesmereUI does),
--  so this library carries no copy of its own.
-------------------------------------------------------------------------------

local MAJOR, MINOR = "LibEUIExport-1.0", 1
local LibEUIExport = LibStub:NewLibrary(MAJOR, MINOR)
if not LibEUIExport then return end -- another copy, same-or-newer, already loaded

-- Resolved lazily (not cached at file scope): the embedding addon may load
-- before whichever addon provides LibDeflate finishes registering it.
local function GetLibDeflate()
    return LibStub and LibStub:GetLibrary("LibDeflate", true)
end

-- Every export string starts with this so Import can reject anything else
-- (a stray WeakAuras string, random text, an empty paste) immediately with a
-- clear error instead of failing deep inside decompression. Bump the digit
-- if the wire format below ever changes incompatibly.
local FORMAT_PREFIX = "EUIX1:"

-------------------------------------------------------------------------------
--  Serializer: Lua value <-> string
--  Format per value: s<len>:<bytes> (string, length-prefixed so embedded
--  delimiters are never ambiguous), n<digits>; (number), T / F (boolean),
--  N (nil), { ... } (table: array part first by raw insertion order, then
--  K<key><value> pairs for every non-array-part key).
-------------------------------------------------------------------------------

local function SerializeValue(v, parts)
    local t = type(v)
    if t == "string" then
        parts[#parts + 1] = "s"
        parts[#parts + 1] = tostring(#v)
        parts[#parts + 1] = ":"
        parts[#parts + 1] = v
    elseif t == "number" then
        parts[#parts + 1] = "n"
        parts[#parts + 1] = tostring(v)
        parts[#parts + 1] = ";"
    elseif t == "boolean" then
        parts[#parts + 1] = v and "T" or "F"
    elseif t == "nil" then
        parts[#parts + 1] = "N"
    elseif t == "table" then
        parts[#parts + 1] = "{"
        local n = #v
        for i = 1, n do
            SerializeValue(v[i], parts)
        end
        for k, val in pairs(v) do
            local kt = type(k)
            if kt == "number" and k >= 1 and k <= n and k == math.floor(k) then
                -- already covered by the array part above
            else
                parts[#parts + 1] = "K"
                SerializeValue(k, parts)
                SerializeValue(val, parts)
            end
        end
        parts[#parts + 1] = "}"
    else
        error("LibEUIExport: cannot serialize a " .. t .. " value", 0)
    end
end

local function Serialize(v)
    local parts = {}
    SerializeValue(v, parts)
    return table.concat(parts)
end

-- Recursive-descent reader over the format above. Throws on malformed input
-- (missing delimiter, unknown tag, truncated stream); Import wraps every call
-- in pcall so a corrupt/garbage paste turns into an error string, not a taint.
local DeserializeValue -- forward decl (mutually referenced via table branch)

local function ReadDelimited(str, pos, stopChar)
    local i = str:find(stopChar, pos, true)
    if not i then error("LibEUIExport: truncated value at position " .. pos, 0) end
    return str:sub(pos, i - 1), i + 1
end

DeserializeValue = function(str, pos)
    local tag = str:sub(pos, pos)
    if tag == "s" then
        local lenStr, afterLen = ReadDelimited(str, pos + 1, ":")
        local len = tonumber(lenStr)
        if not len then error("LibEUIExport: bad string length at position " .. pos, 0) end
        local val = str:sub(afterLen, afterLen + len - 1)
        return val, afterLen + len
    elseif tag == "n" then
        local numStr, after = ReadDelimited(str, pos + 1, ";")
        local val = tonumber(numStr)
        if not val then error("LibEUIExport: bad number at position " .. pos, 0) end
        return val, after
    elseif tag == "T" then
        return true, pos + 1
    elseif tag == "F" then
        return false, pos + 1
    elseif tag == "N" then
        return nil, pos + 1
    elseif tag == "{" then
        local t = {}
        pos = pos + 1
        local i = 1
        while str:sub(pos, pos) ~= "}" do
            if pos > #str then error("LibEUIExport: unterminated table", 0) end
            if str:sub(pos, pos) == "K" then
                local k, val
                k, pos = DeserializeValue(str, pos + 1)
                val, pos = DeserializeValue(str, pos)
                t[k] = val
            else
                local val
                val, pos = DeserializeValue(str, pos)
                t[i] = val
                i = i + 1
            end
        end
        return t, pos + 1
    else
        error("LibEUIExport: unknown tag '" .. tostring(tag) .. "' at position " .. pos, 0)
    end
end

local function Deserialize(str)
    local val = DeserializeValue(str, 1)
    return val
end

-------------------------------------------------------------------------------
--  Public API
-------------------------------------------------------------------------------

-- Export(name, dataType, data) -> string
-- `name` and `dataType` must be plain strings (e.g. a profile name and
-- "profile"/"tweak"/whatever the caller wants to distinguish on import).
-- Throws on bad arguments or missing LibDeflate -- those are caller bugs,
-- not user input, so failing loud is correct here (unlike Import below).
function LibEUIExport:Export(name, dataType, data)
    if type(name) ~= "string" then
        error("LibEUIExport:Export(name, type, data): name must be a string", 2)
    end
    if type(dataType) ~= "string" then
        error("LibEUIExport:Export(name, type, data): type must be a string", 2)
    end
    local LibDeflate = GetLibDeflate()
    if not LibDeflate then
        error("LibEUIExport:Export: LibDeflate is not available", 2)
    end

    local serialized = Serialize({ name = name, type = dataType, data = data })
    local compressed = LibDeflate:CompressDeflate(serialized)
    local encoded = LibDeflate:EncodeForPrint(compressed)
    return FORMAT_PREFIX .. encoded
end

-- Import(inputStr) -> { name, type, data } | nil, errorMessage
-- Never throws: the input always originates from a paste box, so any
-- failure (wrong prefix, corrupt encoding, truncated data) is reported as
-- nil + a message instead of an error the caller has to pcall around.
function LibEUIExport:Import(inputStr)
    if type(inputStr) ~= "string" then
        return nil, "input is not a string"
    end
    local LibDeflate = GetLibDeflate()
    if not LibDeflate then
        return nil, "LibDeflate is not available"
    end

    local body = inputStr:match("^%s*(.-)%s*$") -- trim whitespace from copy/paste
    if body:sub(1, #FORMAT_PREFIX) ~= FORMAT_PREFIX then
        return nil, "not a recognized export string"
    end
    body = body:sub(#FORMAT_PREFIX + 1)
    if body == "" then
        return nil, "empty export string"
    end

    local decoded = LibDeflate:DecodeForPrint(body)
    if not decoded then
        return nil, "could not decode string"
    end

    local decompressed = LibDeflate:DecompressDeflate(decoded)
    if not decompressed then
        return nil, "could not decompress data"
    end

    local ok, envelope = pcall(Deserialize, decompressed)
    if not ok then
        return nil, "could not parse data (" .. tostring(envelope) .. ")"
    end
    if type(envelope) ~= "table" or type(envelope.name) ~= "string" or type(envelope.type) ~= "string" then
        return nil, "malformed export data"
    end

    return { name = envelope.name, type = envelope.type, data = envelope.data }
end
