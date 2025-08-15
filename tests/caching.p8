pico-8 cartridge // http://www.pico-8.com
version 41
__lua__

function _init()
    sample_size = 2000
    
    -- Test caches
    multiply_cache = {}      -- Original x*10000+y (might overflow)
    small_mult_cache = {}    -- x*200+y (safe but smaller range)
    shift8_cache = {}        -- (x<<8)|y 
    shift7_cache = {}        -- (x<<7)|y (max 32767)
    divide_cache = {}        -- x*256+y with division to unpack
    metatable_cache = {}     -- With metatable
    
    -- Set up metatable cache
    setmetatable(metatable_cache, {
        __index = function(t, k)
            local v = rnd(100)
            rawset(t, k, v)
            return v
        end
    })
    
    results = {}
    
    -- Generate test coordinates (limited range for safety)
    test_coords = {}
    for i = 1, sample_size do
        add(test_coords, {flr(rnd(100) - 50), flr(rnd(100) - 50)})
    end
end

function _update()
    -- Test original multiply (might overflow)
    local start = stat(1)
    for i = 1, sample_size do
        local coord = test_coords[i]
        local key = coord[1] * 10000 + coord[2]
        local val = multiply_cache[key]
        if not val then multiply_cache[key] = rnd(100) end
    end
    results[1] = stat(1) - start
    
    -- Test safe multiply (x*200+y)
    start = stat(1)
    for i = 1, sample_size do
        local coord = test_coords[i]
        local key = (coord[1] + 64) * 200 + (coord[2] + 100)
        local val = small_mult_cache[key]
        if not val then small_mult_cache[key] = rnd(100) end
    end
    results[2] = stat(1) - start
    
    -- Test bit shift <<8
    start = stat(1)
    for i = 1, sample_size do
        local coord = test_coords[i]
        local key = ((coord[1] + 64) << 8) | (coord[2] + 64)
        local val = shift8_cache[key]
        if not val then shift8_cache[key] = rnd(100) end
    end
    results[3] = stat(1) - start
    
    -- Test bit shift <<7 (guaranteed under 32767)
    start = stat(1)
    for i = 1, sample_size do
        local coord = test_coords[i]
        local key = ((coord[1] + 64) << 7) | (coord[2] + 64)
        local val = shift7_cache[key]
        if not val then shift7_cache[key] = rnd(100) end
    end
    results[4] = stat(1) - start
    
    -- Test x*256+y (for easier unpacking)
    start = stat(1)
    for i = 1, sample_size do
        local coord = test_coords[i]
        local key = (coord[1] + 64) * 256 + (coord[2] + 128)
        local val = divide_cache[key]
        if not val then divide_cache[key] = rnd(100) end
    end
    results[5] = stat(1) - start
    
    -- Test metatable with safe multiply
    start = stat(1)
    for i = 1, sample_size do
        local coord = test_coords[i]
        local key = (coord[1] + 64) * 200 + (coord[2] + 100)
        local val = metatable_cache[key]  -- No if needed!
    end
    results[6] = stat(1) - start
end

function _draw()
    cls()
    print("safe key benchmark ("..sample_size..")", 10, 2, 7)
    print("max pico-8 int: 32767", 10, 9, 5)
    
    local names = {"x*10000", "x*200+y", "x<<8|y", "x<<7|y", "x*256+y", "meta*200"}
    local colors = {8, 11, 12, 10, 14, 9}
    
    -- Check which methods are safe
    local safe = {}
    safe[1] = 50*10000+50 < 32767 and "NO!" or ""  -- Overflows!
    safe[2] = 114*200+200 < 32767 and "ok" or "NO!"
    safe[3] = (114<<8)|128 < 32767 and "ok" or "NO!"
    safe[4] = (114<<7)|128 < 32767 and "ok" or "NO!"
    safe[5] = 114*256+256 < 32767 and "ok" or "NO!"
    safe[6] = "ok"
    
    local y = 20
    for i = 1, 6 do
        print(names[i]..":", 10, y, colors[i])
        local cpu = results[i] or 0
        print(fmt3(cpu), 60, y)
        print(safe[i], 95, y, safe[i]=="ok" and 11 or 8)
        rectfill(110, y + 1, 110 + cpu * 200, y + 4, colors[i])
        y += 9
    end
    
    -- Find fastest SAFE method
    local min_time, fastest = 999, 0
    for i = 1, 6 do
        if results[i] and results[i] < min_time and safe[i] == "ok" then
            min_time = results[i]
            fastest = i
        end
    end
    
    if fastest > 0 then
        print("fastest safe: "..names[fastest], 10, 85, 10)
    end
    
    -- Show key examples
    print("example keys:", 10, 95, 5)
    print("(50,50): "..(50*10000+50), 10, 102, 8)  -- Will overflow!
    print("(50,50): "..((50+64)*200+(50+100)), 10, 109, 11)  -- Safe
end

function fmt3(n)
    return flr(n*1000)/1000
end