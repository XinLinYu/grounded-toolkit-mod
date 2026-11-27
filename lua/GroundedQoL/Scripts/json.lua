-- 轻量纯 Lua UTF-8 JSON 编解码库（用于 UE4SS Lua 与 C++ ImGui 悬浮菜单通信）
local json = {}

local escape_char_map = {
    ["\\"] = "\\\\",
    ["\""] = "\\\"",
    ["\b"] = "\\b",
    ["\f"] = "\\f",
    ["\n"] = "\\n",
    ["\r"] = "\\r",
    ["\t"] = "\\t",
}

local function escape_char(c)
    return escape_char_map[c] or string.format("\\u%04x", c:byte())
end

local function encode_string(val)
    return '"' .. val:gsub('[%z\1-\31\\"]', escape_char) .. '"'
end

local encode_value

local function encode_table(val, stack)
    if stack[val] then error("circular reference") end
    stack[val] = true
    local res = {}
    if rawget(val, 1) ~= nil or next(val) == nil then
        -- 优先检测是否为连续数组
        local n = 0
        local is_array = true
        for k in pairs(val) do
            if type(k) ~= "number" or k <= 0 or math.floor(k) ~= k then
                is_array = false
                break
            end
            if k > n then n = k end
        end
        if is_array and next(val) ~= nil then
            for i = 1, n do
                res[i] = encode_value(val[i], stack)
            end
            stack[val] = nil
            return "[" .. table.concat(res, ",") .. "]"
        elseif next(val) == nil then
            stack[val] = nil
            return (getmetatable(val) == json.array_mt) and "[]" or "{}"
        end
    end
    local idx = 1
    for k, v in pairs(val) do
        if type(k) == "string" or type(k) == "number" then
            res[idx] = encode_string(tostring(k)) .. ":" .. encode_value(v, stack)
            idx = idx + 1
        end
    end
    stack[val] = nil
    return "{" .. table.concat(res, ",") .. "}"
end

encode_value = function(val, stack)
    local t = type(val)
    if t == "nil" then
        return "null"
    elseif t == "boolean" then
        return val and "true" or "false"
    elseif t == "number" then
        if val ~= val or val == math.huge or val == -math.huge then
            return "0"
        end
        if math.type and math.type(val) == "integer" then
            return tostring(val)
        end
        return string.format("%.6g", val)
    elseif t == "string" then
        return encode_string(val)
    elseif t == "table" then
        return encode_table(val, stack)
    else
        return encode_string(tostring(val))
    end
end

json.array_mt = {}

function json.array(t)
    t = t or {}
    setmetatable(t, json.array_mt)
    return t
end

function json.encode(val)
    return encode_value(val, {})
end

-- 解码器
local function codepoint_to_utf8(n)
    if n <= 0x7f then
        return string.char(n)
    elseif n <= 0x7ff then
        return string.char(0xc0 + math.floor(n / 64), 0x80 + (n % 64))
    elseif n <= 0xffff then
        return string.char(
            0xe0 + math.floor(n / 4096),
            0x80 + (math.floor(n / 64) % 64),
            0x80 + (n % 64))
    else
        return string.char(
            0xf0 + math.floor(n / 262144),
            0x80 + (math.floor(n / 4096) % 64),
            0x80 + (math.floor(n / 64) % 64),
            0x80 + (n % 64))
    end
end

local function skip_ws(str, i)
    local _, e = str:find("^[ \t\r\n]*", i)
    return (e or (i - 1)) + 1
end

local parse_value

local function parse_string(str, i)
    i = i + 1 -- 跳过起始双引号
    local out = {}
    local idx = 1
    local len = #str
    while i <= len do
        local c = str:byte(i)
        if c == 34 then -- '"'
            return table.concat(out), i + 1
        elseif c == 92 then -- '\'
            i = i + 1
            local esc = str:sub(i, i)
            if esc == '"' or esc == "\\" or esc == "/" then
                out[idx] = esc; idx = idx + 1; i = i + 1
            elseif esc == "b" then out[idx] = "\b"; idx = idx + 1; i = i + 1
            elseif esc == "f" then out[idx] = "\f"; idx = idx + 1; i = i + 1
            elseif esc == "n" then out[idx] = "\n"; idx = idx + 1; i = i + 1
            elseif esc == "r" then out[idx] = "\r"; idx = idx + 1; i = i + 1
            elseif esc == "t" then out[idx] = "\t"; idx = idx + 1; i = i + 1
            elseif esc == "u" then
                local hex = str:sub(i + 1, i + 4)
                local cp = tonumber(hex, 16) or 0
                i = i + 5
                -- 处理 UTF-16 代理对
                if cp >= 0xd800 and cp <= 0xdbff and str:sub(i, i + 1) == "\\u" then
                    local hex2 = str:sub(i + 2, i + 5)
                    local cp2 = tonumber(hex2, 16) or 0
                    if cp2 >= 0xdc00 and cp2 <= 0xdfff then
                        cp = 0x10000 + (cp - 0xd800) * 0x400 + (cp2 - 0xdc00)
                        i = i + 6
                    end
                end
                out[idx] = codepoint_to_utf8(cp); idx = idx + 1
            else
                out[idx] = esc; idx = idx + 1; i = i + 1
            end
        else
            local next_special = str:find('[\\"]', i)
            if not next_special then
                error("unterminated string")
            end
            out[idx] = str:sub(i, next_special - 1)
            idx = idx + 1
            i = next_special
        end
    end
    error("unterminated string")
end

local function parse_number(str, i)
    local s, e = str:find("^-?%d+%.?%d*[eE]?[+-]?%d*", i)
    if not s then error("invalid number at " .. i) end
    local num = tonumber(str:sub(s, e))
    if not num then error("bad number at " .. i) end
    return num, e + 1
end

local function parse_array(str, i)
    i = skip_ws(str, i + 1)
    local res = {}
    if str:byte(i) == 93 then return res, i + 1 end
    local idx = 1
    while true do
        local v
        v, i = parse_value(str, i)
        res[idx] = v
        idx = idx + 1
        i = skip_ws(str, i)
        local c = str:byte(i)
        if c == 93 then return res, i + 1 end
        if c ~= 44 then error("expected ',' or ']' at " .. i) end
        i = skip_ws(str, i + 1)
    end
end

local function parse_object(str, i)
    i = skip_ws(str, i + 1)
    local res = {}
    if str:byte(i) == 125 then return res, i + 1 end
    while true do
        if str:byte(i) ~= 34 then error("expected string key at " .. i) end
        local k, v
        k, i = parse_string(str, i)
        i = skip_ws(str, i)
        if str:byte(i) ~= 58 then error("expected ':' at " .. i) end
        i = skip_ws(str, i + 1)
        v, i = parse_value(str, i)
        res[k] = v
        i = skip_ws(str, i)
        local c = str:byte(i)
        if c == 125 then return res, i + 1 end
        if c ~= 44 then error("expected ',' or '}' at " .. i) end
        i = skip_ws(str, i + 1)
    end
end

parse_value = function(str, i)
    i = skip_ws(str, i)
    local c = str:byte(i)
    if c == 34 then return parse_string(str, i)
    elseif c == 123 then return parse_object(str, i)
    elseif c == 91 then return parse_array(str, i)
    elseif str:sub(i, i + 3) == "true" then return true, i + 4
    elseif str:sub(i, i + 4) == "false" then return false, i + 5
    elseif str:sub(i, i + 3) == "null" then return nil, i + 4
    else return parse_number(str, i) end
end

function json.decode(str)
    if type(str) ~= "string" or str == "" then return nil end
    local ok, val = pcall(function()
        local res = parse_value(str, 1)
        return res
    end)
    if ok then return val end
    return nil
end

return json
