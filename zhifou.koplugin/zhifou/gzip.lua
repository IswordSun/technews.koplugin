-- zhifou/gzip.lua — gzip / zlib(deflate) 解压（FFI 直接调 zlib）
--
-- 为什么需要它：feed/HTML/JSON 打开 gzip 后能小一个数量级，而 KOReader 自带的
-- ffi/zlib.lua 只封装了 compress/uncompress（zlib 包装格式），解不了 HTTP 的
-- gzip（RFC1952）。实测「读首诗再睡觉」的 feed：2.01MB → 209KB，正是它每次抓取
-- 撞穿 30s 总超时（→ 重试 4 次 ≈ 卡两分钟）的根因。
--
-- 兼容性：libz 在 KOReader 各平台构建里本来就存在（base/ffi/zlib.lua 就在用），
-- 这里按「ffi.loadlib → ffi.load」顺序探测；探测失败时 inflate 返回错误而不是抛错。

local ffi = require("ffi")

-- 与 zlib.h 一致的结构体。用 C 类型声明（uInt/uLong 随平台 ABI 变化），
-- 32 位真机与 64 位模拟器都对。
ffi.cdef[[
typedef unsigned char Bytef;
typedef unsigned int uInt;
typedef unsigned long uLong;
typedef struct z_stream_s {
    Bytef    *next_in;
    uInt      avail_in;
    uLong     total_in;
    Bytef    *next_out;
    uInt      avail_out;
    uLong     total_out;
    char     *msg;
    void     *state;
    void     *zalloc;
    void     *zfree;
    void     *opaque;
    int       data_type;
    uLong     adler;
    uLong     reserved;
} z_stream;
const char *zlibVersion(void);
int inflateInit2_(z_stream *strm, int windowBits, const char *version, int stream_size);
int inflate(z_stream *strm, int flush);
int inflateEnd(z_stream *strm);
]]

local gzip = {}

-- 单次输出的块大小（避免为未知大小的解压结果一次性分配内存）
gzip.CHUNK = 256 * 1024

-- gzip（RFC1952）/ zlib（RFC1950）/ 裸 deflate 三种窗口位
local GZIP_BITS = 31       -- 16 + MAX_WBITS
local ZLIB_BITS = 15
local RAW_BITS = -15

local libz          -- 探测结果缓存：库对象 / false（不可用）
local libz_loaded = false

local function load_libz()
    if libz_loaded then return libz end
    libz_loaded = true
    -- KOReader 用 ffi.loadlib 找随包分发的库（处理版本号后缀）
    local ok, lib = pcall(function()
        if ffi.loadlib then return ffi.loadlib("z", 1) end
        error("no ffi.loadlib")
    end)
    if ok and lib then
        libz = lib
        return libz
    end
    for _, name in ipairs({ "z", "libz.so.1", "libz.so", "libz.dylib", "zlib1" }) do
        local loaded, candidate = pcall(ffi.load, name)
        if loaded and candidate then
            libz = candidate
            return libz
        end
    end
    libz = false
    return nil
end

--- zlib 是否可用（诊断用）
function gzip.available()
    return load_libz() ~= nil
end

--- 按魔数判断压缩格式对应的 windowBits
function gzip.window_bits(data)
    if #data >= 2 and data:byte(1) == 0x1F and data:byte(2) == 0x8B then
        return GZIP_BITS
    end
    -- zlib 头：CMF 低 4 位 = 8（deflate），且 (CMF*256+FLG) % 31 == 0
    local cmf, flg = data:byte(1), data:byte(2)
    if cmf and flg and cmf % 16 == 8 and (cmf * 256 + flg) % 31 == 0 then
        return ZLIB_BITS
    end
    return RAW_BITS
end

-- 单次尝试：失败返回 nil, 错误（含 zlib 的消息）
local function inflate_with(lib, data, bits, chunk)
    local strm = ffi.new("z_stream")
    local rc = lib.inflateInit2_(strm, bits, lib.zlibVersion(), ffi.sizeof("z_stream"))
    if rc ~= 0 then
        return nil, string.format("inflateInit2 失败(%d)", rc)
    end
    local out = {}
    local buf = ffi.new("uint8_t[?]", chunk)
    strm.next_in = ffi.cast("Bytef *", data)
    strm.avail_in = #data
    local result, err
    while true do
        strm.next_out = buf
        strm.avail_out = chunk
        local ret = lib.inflate(strm, 0)   -- Z_NO_FLUSH
        local produced = chunk - tonumber(strm.avail_out)
        if produced > 0 then
            out[#out + 1] = ffi.string(buf, produced)
        end
        if ret == 1 then                   -- Z_STREAM_END
            result = table.concat(out)
            break
        elseif ret ~= 0 then               -- 负值 = 错误码
            local msg = strm.msg
            err = string.format("解压失败(%d)%s", ret,
                msg ~= nil and (": " .. ffi.string(msg)) or "")
            break
        elseif tonumber(strm.avail_in) == 0 then
            err = "数据不完整"
            break
        end
    end
    lib.inflateEnd(strm)
    return result, err
end

--- 解压 gzip / zlib / 裸 deflate 数据。
-- @param data 压缩数据
-- @param opts 可选 { window_bits = 数字, chunk = 字节数 }
-- @return 解压后的字符串；失败返回 nil, 原因
function gzip.inflate(data, opts)
    if type(data) ~= "string" or #data == 0 then
        return nil, "空数据"
    end
    local lib = load_libz()
    if not lib then return nil, "zlib 不可用" end
    local chunk = (opts and opts.chunk) or gzip.CHUNK
    local bits = (opts and opts.window_bits) or gzip.window_bits(data)
    local plain, err = inflate_with(lib, data, bits, chunk)
    if plain then return plain end
    -- 魔数判断不了「裸 deflate」：按 zlib 解失败时再按裸流试一次
    if not (opts and opts.window_bits) and bits ~= RAW_BITS then
        local retry, retry_err = inflate_with(lib, data, RAW_BITS, chunk)
        if retry then return retry end
        err = err or retry_err
    end
    return nil, err
end

return gzip
