--[[
    文件：lua/GroundedQoL/Scripts/json.lua
    职责：轻量级纯 Lua UTF-8 JSON 编解码库，用于 UE4SS Lua 逻辑层与 C++ DX12/DX11 悬浮层之间
          通过原子 JSON 文件（config/catalog/map_live/status/actions）进行状态交换。
    约束：
      - 仅依赖标准 Lua 库，不依赖任何第三方 C 扩展，确保在 UE4SS 内嵌 Lua 环境中零依赖运行。
      - 空表默认编码为对象 "{}"；若需明确编码为空数组 "[]"，请先用 json.array(t) 标记元表。
]]

local json = {}

--- JSON 字符串转义字符映射表（控制字符与引号、反斜杠）。
local escape_char_map = {
    ["\\"] = "\\\\",
    ["\""] = "\\\"",
    ["\b"] = "\\b",
    ["\f"] = "\\f",
    ["\n"] = "\\n",
    ["\r"] = "\\r",
    ["\t"] = "\\t",
}

--- 将单个需要转义的字符转换为合法 JSON 转义序列（其余不可见控制字符转 \uXXXX）。
local function escape_char(c)
    return escape_char_map[c] or string.format("\\u%04x", c:byte())
end

--- 将 Lua 字符串编码为带双引号的合法 JSON 字符串字面量。
local function encode_string(val)
    return '"' .. val:gsub('[%z\1-\31\\"]', escape_char) .. '"'
end

local encode_value

--- 将 Lua table 编码为 JSON 数组或 JSON 对象。
-- @param val   待编码的 Lua table
-- @param stack 递归引用栈，用于检测并阻止循环引用导致的无限递归
local function encode_table(val, stack)
    if stack[val] then error("circular reference") end
    stack[val] = true
    local res = {}

    -- 当表为空或存在下标 1 时，优先检测是否为连续正整数索引数组
    if rawget(val, 1) ~= nil or next(val) == nil then
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
            -- 区分显式空数组 json.array({}) 与普通空对象 {}
            return (getmetatable(val) == json.array_mt) and "[]" or "{}"
        end
    end

    -- 按 JSON 对象编码，仅保留 string/number 类型的键并统一转为字符串键名
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

--- 递归分发任意 Lua 基础类型或 table 的 JSON 编码。
encode_value = function(val, stack)
    local t = type(val)
    if t == "nil" then
        return "null"
    elseif t == "boolean" then
        return val and "true" or "false"
    elseif t == "number" then
        -- 拦截 NaN 与正负无穷，避免生成非标准 JSON 导致 C++ nlohmann::json 解析报错
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
        -- UE4SS userdata 等非标准类型兜底转为字符串，防止编码崩溃
        return encode_string(tostring(val))
    end
end

--- 用于显式标识“空 JSON 数组”的元表。
json.array_mt = {}

--- 将指定表（或新建空表）标记为 JSON 数组，使其即使为空也序列化为 "[]"。
function json.array(t)
    t = t or {}
    setmetatable(t, json.array_mt)
    return t
end

--- 将任意 Lua 值编码为紧凑 JSON 文本。
function json.encode(val)
    return encode_value(val, {})
end

-- ============================================================
-- JSON 解码器（支持完整 UTF-8 与 \uXXXX / UTF-16 代理对解码）
-- ============================================================

--- 将 Unicode 码点转换为 UTF-8 多字节序列（支持基本多文种平面与增补平面）。
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

--- 跳过从位置 i 开始的连续空白字符，返回首个非空白字符的索引。
local function skip_ws(str, i)
    local _, e = str:find("^[ \t\r\n]*", i)
    return (e or (i - 1)) + 1
end

local parse_value

--- 解析双引号包裹的 JSON 字符串，正确展开转义字符与 Unicode 代理对。
local function parse_string(str, i)
    i = i + 1 -- 跳过起始双引号 '"'
    local out = {}
    local idx = 1
    local len = #str
    while i <= len do
        local c = str:byte(i)
        if c == 34 then -- 遇到结束双引号 '"'
            return table.concat(out), i + 1
        elseif c == 92 then -- 遇到反斜杠 '\' 转义前缀
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
                -- 若为高代理项（0xD800~0xDBFF）且紧跟低代理项（0xDC00~0xDFFF），合并还原为完整 Unicode 码点
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
            -- 批量切片拷贝普通字符段，减少逐字符拼接带来的内存分配开销
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

--- 解析 JSON 数值字面量（支持负号、小数与科学计数法）。
local function parse_number(str, i)
    local s, e = str:find("^-?%d+%.?%d*[eE]?[+-]?%d*", i)
    if not s then error("invalid number at " .. i) end
    local num = tonumber(str:sub(s, e))
    if not num then error("bad number at " .. i) end
    return num, e + 1
end

--- 解析 JSON 数组 "[...]"，返回 1-based 连续 Lua 表及下一个解析偏移。
local function parse_array(str, i)
    i = skip_ws(str, i + 1)
    local res = {}
    if str:byte(i) == 93 then return res, i + 1 end -- 空数组 ']'
    local idx = 1
    while true do
        local v
        v, i = parse_value(str, i)
        res[idx] = v
        idx = idx + 1
        i = skip_ws(str, i)
        local c = str:byte(i)
        if c == 93 then return res, i + 1 end -- ']'
        if c ~= 44 then error("expected ',' or ']' at " .. i) end -- ','
        i = skip_ws(str, i + 1)
    end
end

--- 解析 JSON 对象 "{...}"，返回键值 Lua 表及下一个解析偏移。
local function parse_object(str, i)
    i = skip_ws(str, i + 1)
    local res = {}
    if str:byte(i) == 125 then return res, i + 1 end -- 空对象 '}'
    while true do
        if str:byte(i) ~= 34 then error("expected string key at " .. i) end -- 键必须以 '"' 开头
        local k, v
        k, i = parse_string(str, i)
        i = skip_ws(str, i)
        if str:byte(i) ~= 58 then error("expected ':' at " .. i) end -- ':'
        i = skip_ws(str, i + 1)
        v, i = parse_value(str, i)
        res[k] = v
        i = skip_ws(str, i)
        local c = str:byte(i)
        if c == 125 then return res, i + 1 end -- '}'
        if c ~= 44 then error("expected ',' or '}' at " .. i) end -- ','
        i = skip_ws(str, i + 1)
    end
end

--- 根据首字符分派解析任意合法 JSON 值。
parse_value = function(str, i)
    i = skip_ws(str, i)
    local c = str:byte(i)
    if c == 34 then return parse_string(str, i)       -- '"' 字符串
    elseif c == 123 then return parse_object(str, i)  -- '{' 对象
    elseif c == 91 then return parse_array(str, i)    -- '[' 数组
    elseif str:sub(i, i + 3) == "true" then return true, i + 4
    elseif str:sub(i, i + 4) == "false" then return false, i + 5
    elseif str:sub(i, i + 3) == "null" then return nil, i + 4
    else return parse_number(str, i) end
end

--- 安全解码 JSON 字符串；遇到格式错误或空输入时返回 nil 而不抛出异常。
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
