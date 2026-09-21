-- technews/zipread.lua — 最小 ZIP 读取器（仅支持 stored / method 0）
--
-- 用途：收藏单篇快照时，从本期 EPUB 里就地取出该条的图片二进制，
-- 免去为了收藏再走一遍网络下载（technews.favorites.add 的首选路径）。
--
-- 为什么可以自己读：technews/epub.lua 构建的 EPUB 是「stored（未压缩）」
-- ZIP——数据字节原样存放，偏移与长度都能从中央目录直接得到。因此这里只实现
-- stored 条目的按偏移读取，不实现 Inflate（method ~= 0 一律拒绝，交回下载路径）。
--
-- 实现取向：不把整期文件读进内存（整期可能十几 MB）。流程：
--   1) 只读文件末尾 ~64KB，从后向前找 EOCD（PK\x05\x06），得到中央目录位置与长度；
--   2) 读中央目录（PK\x01\x02 条目很小、总长通常几百字节），建立 名字 -> 条目 索引；
--   3) extract(name) 按索引 seek 到局部头（PK\x03\x04），跳过文件名/扩展区后
--      读取 comp_size 字节。
-- 任何结构不合法/越界/不支持的方法都返回 nil，调用方据此回退下载。
--
-- 依赖：仅标准 io 与 string（无 KOReader、无 bit 库）。

local zipread = {}

-- 中央目录单个条目的固定头长度（签名到 local header offset，不含名字等变长部分）
local CD_HEADER = 46
-- 局部文件头固定长度（签名到文件名之前）
local LOCAL_HEADER = 30
-- EOCD 固定长度（不含注释）
local EOCD_MIN = 22
-- EOCD 最大可及距离：注释上限 65535 + EOCD 固定长度
local EOCD_SEARCH = 65535 + EOCD_MIN

-- little-endian 解码（ZIP 字段均为小端；数值都在 double 精确范围内）。
-- 越界时返回 nil，由调用方按「结构不合法」处理。
local function le16(data, pos)
    local b1, b2 = data:byte(pos, pos + 1)
    if not b2 then return nil end
    return b1 + b2 * 0x100
end

local function le32(data, pos)
    local b1, b2, b3, b4 = data:byte(pos, pos + 3)
    if not b4 then return nil end
    return b1 + b2 * 0x100 + b3 * 0x10000 + b4 * 0x1000000
end

--- 打开 ZIP/EPUB 文件，成功返回 reader（含 extract/close），失败返回 nil。
-- reader:extract(name) 解出条目原始字节；条目不存在、非 stored 或结构异常均返回 nil。
function zipread.open(path)
    local file = io.open(path, "rb")
    if not file then return nil end

    local size = file:seek("end")
    if not size or size < EOCD_MIN then
        file:close()
        return nil
    end

    -- 1) 定位 EOCD：只读文件尾部（注释上限内），从后向前扫签名。
    --    签名可能在注释/数据里伪出现，故校验「22 + 注释长度恰好到文件尾」。
    local tail_size = math.min(size, EOCD_SEARCH)
    if not file:seek("set", size - tail_size) then
        file:close()
        return nil
    end
    local tail = file:read(tail_size)
    if not tail or #tail ~= tail_size then
        file:close()
        return nil
    end

    local eocd_pos
    for pos = #tail - EOCD_MIN + 1, 1, -1 do
        if tail:sub(pos, pos + 3) == "PK\005\006" then
            local comment_len = le16(tail, pos + 20)
            if comment_len and pos + EOCD_MIN + comment_len - 1 == #tail then
                eocd_pos = pos
                break
            end
        end
    end
    if not eocd_pos then
        file:close()
        return nil
    end

    local entry_count = le16(tail, eocd_pos + 8)  -- 本盘条目数（无分卷，等同总数）
    local cd_size = le32(tail, eocd_pos + 12)     -- 中央目录字节数
    local cd_offset = le32(tail, eocd_pos + 16)   -- 中央目录起始偏移
    if not entry_count or not cd_size or not cd_offset
        or cd_offset + cd_size > size then
        file:close()
        return nil
    end

    -- 2) 读中央目录并建索引
    local index = {}
    if entry_count > 0 then
        if not file:seek("set", cd_offset) then
            file:close()
            return nil
        end
        local central = file:read(cd_size)
        if not central or #central ~= cd_size then
            file:close()
            return nil
        end
        local cursor = 1
        for _ = 1, entry_count do
            if central:sub(cursor, cursor + 3) ~= "PK\001\002" then
                file:close()
                return nil
            end
            local method = le16(central, cursor + 10)
            local comp_size = le32(central, cursor + 20)
            local name_len = le16(central, cursor + 28)
            local extra_len = le16(central, cursor + 30)
            local comment_len = le16(central, cursor + 32)
            local local_offset = le32(central, cursor + 42)
            if not method or not comp_size or not name_len or not extra_len
                or not comment_len or not local_offset then
                file:close()
                return nil
            end
            local name = central:sub(cursor + CD_HEADER,
                cursor + CD_HEADER + name_len - 1)
            if #name ~= name_len then
                file:close()
                return nil
            end
            index[name] = {
                method = method,
                comp_size = comp_size,
                offset = local_offset,
            }
            cursor = cursor + CD_HEADER + name_len + extra_len + comment_len
        end
    end

    -- 3) reader：按需 seek 提取，不缓存文件内容
    local reader = {}

    function reader:extract(name)
        if not file then return nil end
        local entry = index[name]
        if not entry then return nil end
        -- 只支持 stored；method 8（deflate）等压缩条目一律拒绝
        if entry.method ~= 0 then return nil end
        if entry.comp_size == 0 then return "" end
        if entry.offset + LOCAL_HEADER > size then return nil end
        if not file:seek("set", entry.offset) then return nil end
        local header = file:read(LOCAL_HEADER)
        if not header or #header < LOCAL_HEADER
            or header:sub(1, 4) ~= "PK\003\004" then
            return nil
        end
        -- 数据起点 = 局部头 + 文件名长度 + 扩展区长度（以局部头为准，目录值兜底）
        local name_len = le16(header, 27)
        local extra_len = le16(header, 29)
        if not name_len or not extra_len then return nil end
        local data_offset = entry.offset + LOCAL_HEADER + name_len + extra_len
        if data_offset + entry.comp_size > size then return nil end
        if not file:seek("set", data_offset) then return nil end
        local data = file:read(entry.comp_size)
        if not data or #data ~= entry.comp_size then return nil end
        return data
    end

    function reader:close()
        if file then
            file:close()
            file = nil
        end
    end

    return reader
end

return zipread
