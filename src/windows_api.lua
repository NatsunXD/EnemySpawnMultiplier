return function()
    local ffi = require('ffi')
    assert(ffi.abi('64bit'), 'Windows x64 is required')
    ffi.cdef [[
        void *GetModuleHandleA(const char *name);
        uint32_t GetModuleFileNameW(void *module, uint16_t *path, uint32_t capacity);
        void *GetCurrentProcess(void);
        int ReadProcessMemory(void *process, const void *address, void *buffer, size_t size, size_t *read);
        int WriteProcessMemory(void *process, void *address, const void *buffer, size_t size, size_t *written);
        typedef struct {
            void *base; void *allocation_base; uint32_t allocation_protection;
            uint16_t partition; uint16_t reserved; size_t size;
            uint32_t state; uint32_t protection; uint32_t type;
        } HsuMemoryRegion;
        size_t VirtualQuery(const void *address, void *region, size_t size);
        int VirtualProtect(void *address, size_t size, uint32_t new_protect, uint32_t *old_protect);
        void *VirtualAlloc(void *address, size_t size, uint32_t type, uint32_t protect);
        void *CreateFileW(const uint16_t *path, uint32_t access, uint32_t share, void *security,
                          uint32_t disposition, uint32_t flags, void *template_file);
        int ReadFile(void *file, void *buffer, uint32_t size, uint32_t *read, void *overlapped);
        int CloseHandle(void *handle);
        int32_t BCryptOpenAlgorithmProvider(void **algorithm, const uint16_t *name,
                                            const uint16_t *provider, uint32_t flags);
        int32_t BCryptCloseAlgorithmProvider(void *algorithm, uint32_t flags);
        int32_t BCryptCreateHash(void *algorithm, void **hash, void *object, uint32_t object_size,
                                 const void *secret, uint32_t secret_size, uint32_t flags);
        int32_t BCryptHashData(void *hash, const void *data, uint32_t size, uint32_t flags);
        int32_t BCryptFinishHash(void *hash, void *digest, uint32_t size, uint32_t flags);
        int32_t BCryptDestroyHash(void *hash);
    ]]
    local kernel, bcrypt = ffi.load('kernel32'), ffi.load('bcrypt')
    -- LuaJIT retains the first function declaration in the shared VM. Use an
    -- opaque buffer when declaring first so another mod's equivalent struct is
    -- accepted. Cast our own call as well for a typed declaration loaded first.
    local query_region = ffi.cast('size_t (*)(const void *, void *, size_t)', kernel.VirtualQuery)
    -- Used only to make a MEM_PRIVATE, non-executable data page briefly writable
    -- so the decay record can be updated. The previous protection is always
    -- restored immediately; no executable or mapped page is ever touched.
    local protect_region = ffi.cast('int32_t (*)(void *, size_t, uint32_t, uint32_t *)', kernel.VirtualProtect)
    local process = kernel.GetCurrentProcess()
    local api = {}

    function api.module(name)
        local handle = kernel.GetModuleHandleA(name)
        if handle == nil then return nil end
        return ffi.cast('uint8_t *', handle)
    end

    function api.read(address, size)
        local buffer, count = ffi.new('uint8_t[?]', size), ffi.new('size_t[1]')
        local pointer = ffi.cast('const void *', address)
        if kernel.ReadProcessMemory(process, pointer, buffer, size, count) == 0 or count[0] ~= size then
            return nil
        end
        return ffi.string(buffer, size)
    end

    function api.write(address, bytes)
        if not api.writable_data(address, #bytes) then return false end
        local count = ffi.new('size_t[1]')
        local pointer = ffi.cast('void *', address)
        return kernel.WriteProcessMemory(process, pointer, bytes, #bytes, count) ~= 0 and count[0] == #bytes
    end

    function api.pointer(bytes, offset)
        offset = offset or 0
        if not bytes or offset < 0 or offset + 8 > #bytes then return nil end
        local value = ffi.new('uintptr_t[1]')
        ffi.copy(value, bytes:sub(offset + 1, offset + 8), 8)
        if value[0] < 0x10000 or value[0] >= 0x800000000000 then return nil end
        return ffi.cast('uint8_t *', value[0])
    end

    function api.distance(first, second)
        return tonumber(ffi.cast('intptr_t', first) - ffi.cast('intptr_t', second))
    end

    local allocate = ffi.cast('void *(*)(void *, size_t, uint32_t, uint32_t)', kernel.VirtualAlloc)

    function api.alloc_private(size)
        if not size or size <= 0 then return nil end
        local block = allocate(nil, size, 0x3000, 4)
        if block == nil then return nil end
        local address = ffi.cast('uint8_t *', block)
        if not api.writable_data(address, size) then return nil end
        return address
    end

    function api.writable_data(address, size)
        if size <= 0 then return false end
        local cursor = ffi.cast('uint8_t *', address)
        local remaining = size
        local region = ffi.new('HsuMemoryRegion[1]')
        while remaining > 0 do
            if query_region(cursor, region, ffi.sizeof(region[0])) ~= ffi.sizeof(region[0]) then return false end
            -- Settings must already be writable private data, never executable or mapped module pages.
            if region[0].state ~= 0x1000 or region[0].type ~= 0x20000 or region[0].protection ~= 4 then return false end
            local available = tonumber(region[0].size) - api.distance(cursor, region[0].base)
            if available <= 0 then return false end
            local count = math.min(available, remaining)
            cursor, remaining = cursor + count, remaining - count
        end
        return true
    end

    -- Corpse-decay write surface.
    --
    -- The spawn patch insists on exactly PAGE_READWRITE (0x04) MEM_PRIVATE data,
    -- which is right for the live director/config rows it edits. The generated
    -- entity snapshot is different: the game decrypts generated_entities into a
    -- MEM_PRIVATE allocation and leaves it PAGE_READONLY (0x02) or
    -- PAGE_WRITECOPY (0x08). The live test showed exactly that -- a private
    -- header whose every record came back not_writable -- so the strict check
    -- rejected the whole table and the feature silently did nothing.
    --
    -- This path only accepts MEM_PRIVATE, committed, non-executable data pages.
    -- When the page is not already writable it flips the record to
    -- PAGE_READWRITE, performs the write, and restores the original protection.
    local DECAY_PROT_READONLY  = 0x02
    local DECAY_PROT_READWRITE = 0x04
    local DECAY_PROT_WRITECOPY = 0x08
    local decay_last_protection = 0
    local decay_protect_calls = 0

    local function decay_region(address)
        local region = ffi.new('HsuMemoryRegion[1]')
        local pointer = ffi.cast('const void *', address)
        if query_region(pointer, region, ffi.sizeof(region[0])) ~= ffi.sizeof(region[0]) then
            return nil
        end
        if region[0].state ~= 0x1000 or region[0].type ~= 0x20000 then return nil end
        local prot = tonumber(region[0].protection)
        -- PAGE_GUARD / PAGE_NOCACHE and the execute combinations are never
        -- accepted; only plain read-only/writecopy/readwrite data pages are.
        if prot ~= DECAY_PROT_READONLY and prot ~= DECAY_PROT_READWRITE
            and prot ~= DECAY_PROT_WRITECOPY then
            return nil
        end
        local available = tonumber(region[0].size) - api.distance(address, region[0].base)
        if available <= 0 then return nil end
        return region[0], prot, available
    end

    function api.decay_protection(address, size)
        local _, prot, available = decay_region(address)
        if not prot then return nil end
        if size and size > available then return nil end
        return prot
    end

    function api.writable_decay(address, size)
        if not size or size <= 0 then return false end
        local remaining = size
        while remaining > 0 do
            local _, prot, available = decay_region(address)
            if not prot then return false end
            local count = math.min(available, remaining)
            address, remaining = address + count, remaining - count
        end
        return true
    end

    function api.write_decay(address, bytes)
        if not api.writable_decay(address, #bytes) then return false end
        local pointer = ffi.cast('void *', address)
        local count = ffi.new('size_t[1]')
        local prot = api.decay_protection(address, #bytes)
        decay_last_protection = prot or 0
        -- Pages that are already writable (or copy-on-write) need no change.
        if kernel.WriteProcessMemory(process, pointer, bytes, #bytes, count) ~= 0
            and count[0] == #bytes then
            return true
        end
        if prot == nil or prot == DECAY_PROT_READWRITE then return false end
        local old = ffi.new('uint32_t[1]')
        if protect_region(pointer, #bytes, DECAY_PROT_READWRITE, old) == 0 then return false end
        decay_protect_calls = decay_protect_calls + 1
        local ok = kernel.WriteProcessMemory(process, pointer, bytes, #bytes, count) ~= 0
            and count[0] == #bytes
        -- Always restore, even when the write failed, so the game keeps the page
        -- protection it established.
        local restored = ffi.new('uint32_t[1]')
        protect_region(pointer, #bytes, old[0], restored)
        return ok
    end

    function api.decay_status()
        return {protection = decay_last_protection, protect_calls = decay_protect_calls}
    end

    -- Raw region query for the corpse-clear scan.
    --
    -- Contract: `address` is a plain number, and `base` comes back as a plain
    -- number too. LuaJIT refuses to compare a cdata pointer with a number
    -- ("attempt to compare 'number' with 'unsigned char *'"), so the scan would
    -- fault while walking regions if a pointer ever leaked into the cursor.
    -- Callers that need a pointer ask cast_uint8 for it.
    function api.query_region(address)
        if address == nil then return nil end
        local region = ffi.new('HsuMemoryRegion[1]')
        local pointer = ffi.cast('const void *', address)
        if query_region(pointer, region, ffi.sizeof(region[0])) ~= ffi.sizeof(region[0]) then
            return nil
        end
        return tonumber(ffi.cast('uintptr_t', region[0].base)), tonumber(region[0].size),
               region[0].state, region[0].protection, region[0].type
    end

    function api.cast_uint8(address)
        return ffi.cast('uint8_t *', address)
    end

    function api.offset(pointer, bytes)
        return pointer + bytes
    end

    function api.encode_f32(value)
        local buffer = ffi.new('float[1]', value)
        return ffi.string(buffer, 4)
    end

    function api.encode_u32(value)
        local buffer = ffi.new('uint32_t[1]', value)
        return ffi.string(buffer, 4)
    end

    function api.module_hash(module)
        local path = ffi.new('uint16_t[32768]')
        local length = kernel.GetModuleFileNameW(module, path, 32768)
        assert(length > 0 and length < 32768, 'Cannot resolve module file')
        local file = kernel.CreateFileW(path, 0x80000000, 7, nil, 3, 0x08000000, nil)
        assert(file ~= ffi.cast('void *', -1), 'Cannot read module file')
        local algorithm, hash = ffi.new('void *[1]'), ffi.new('void *[1]')
        local ok, result = pcall(function()
            local name = ffi.new('uint16_t[7]', {83, 72, 65, 50, 53, 54, 0})
            assert(bcrypt.BCryptOpenAlgorithmProvider(algorithm, name, nil, 0) == 0, 'SHA256 unavailable')
            assert(bcrypt.BCryptCreateHash(algorithm[0], hash, nil, 0, nil, 0, 0) == 0, 'SHA256 creation failed')
            local buffer, count = ffi.new('uint8_t[1048576]'), ffi.new('uint32_t[1]')
            while true do
                assert(kernel.ReadFile(file, buffer, 1048576, count, nil) ~= 0, 'Module file read failed')
                if count[0] == 0 then break end
                assert(bcrypt.BCryptHashData(hash[0], buffer, count[0], 0) == 0, 'SHA256 update failed')
            end
            local digest, hex = ffi.new('uint8_t[32]'), {}
            assert(bcrypt.BCryptFinishHash(hash[0], digest, 32, 0) == 0, 'SHA256 finish failed')
            for i = 0, 31 do hex[#hex + 1] = string.format('%02X', digest[i]) end
            return table.concat(hex)
        end)
        if hash[0] ~= nil then bcrypt.BCryptDestroyHash(hash[0]) end
        if algorithm[0] ~= nil then bcrypt.BCryptCloseAlgorithmProvider(algorithm[0], 0) end
        kernel.CloseHandle(file)
        if not ok then error(result) end
        return result
    end
    return api
end
