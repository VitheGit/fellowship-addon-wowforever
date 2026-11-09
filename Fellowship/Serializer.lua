-- Serializer: a message is a list of records, each record a list of string fields.
-- Records are joined by \30 (record separator), fields by \31 (unit separator).
-- Those two bytes and NUL are stripped from any value, so user text can never break framing.
local _, ns = ...
local S = {}
ns.Serializer = S

local RS, FS = "\30", "\31"
S.RS, S.FS = RS, FS

function S.Clean(v)
    if v == nil then return "" end
    return (tostring(v):gsub("[%z\30\31]", ""))
end

function S.EncodeRecord(rec)
    local out = {}
    for i = 1, #rec do out[i] = S.Clean(rec[i]) end
    return table.concat(out, FS)
end

-- records: list of records, or already-encoded record strings
function S.Encode(records)
    local out = {}
    for i, rec in ipairs(records) do
        out[i] = type(rec) == "string" and rec or S.EncodeRecord(rec)
    end
    return table.concat(out, RS)
end

function S.Decode(str)
    local records = {}
    for rec in (str .. RS):gmatch("(.-)" .. RS) do
        local fields = {}
        for f in (rec .. FS):gmatch("(.-)" .. FS) do fields[#fields + 1] = f end
        records[#records + 1] = fields
    end
    return records
end
