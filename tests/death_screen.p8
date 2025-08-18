pico-8 cartridge // http://www.pico-8.com
version 41
__lua__

-- fancy transition test cart
-- using palette & memory tricks
-- cycle through effects with ⬅️➡️
-- restart with ❎

effect_idx = 1
effect_names = {
    "vhs tracking",
    "vhs improved",
    "corruption slow",
    "melt fixed",
    "digital break",
    "static takeover",
    "glitch cascade",
    "signal loss"
}

transition_t = 0
transition_active = false
bg_seed = 0

function _init()
    generate_bg()
    start_transition()
end

function _update()
    -- cycle effects
    if btnp(⬅️) then
        effect_idx = effect_idx - 1
        if effect_idx < 1 then effect_idx = #effect_names end
        start_transition()
    end
    if btnp(➡️) then
        effect_idx = effect_idx + 1
        if effect_idx > #effect_names then effect_idx = 1 end
        start_transition()
    end
    
    -- restart current effect
    if btnp(❎) then
        start_transition()
    end
end

function start_transition()
    transition_active = true
    transition_t = 0
    generate_bg()
    -- reset palette
    pal()
    fillp()
end

function generate_bg()
    -- new random seed for background
    bg_seed = rnd(1000)
end

function _draw()
    -- always reset first
    pal()
    fillp()
    
    cls(1)
    
    -- draw random colorful background
    srand(bg_seed)
    for i=1,30 do
        local x = rnd(128)
        local y = rnd(128)
        local r = 4 + rnd(12)
        local c = 1 + flr(rnd(15))
        circfill(x, y, r, c)
    end
    
    -- some rectangles too
    for i=1,10 do
        local x = rnd(100)
        local y = rnd(100)
        local w = 10 + rnd(20)
        local h = 10 + rnd(20)
        local c = 1 + flr(rnd(15))
        rectfill(x, y, x+w, y+h, c)
    end
    
    -- draw the transition effect
    if transition_active then
        transition_t += 1/30  -- increment time
        
        if effect_idx == 1 then
            draw_vhs()
        elseif effect_idx == 2 then
            draw_vhs_improved()
        elseif effect_idx == 3 then
            draw_corruption_slow()
        elseif effect_idx == 4 then
            draw_melt_fixed()
        elseif effect_idx == 5 then
            draw_digital_break()
        elseif effect_idx == 6 then
            draw_static_takeover()
        elseif effect_idx == 7 then
            draw_glitch_cascade()
        elseif effect_idx == 8 then
            draw_signal_loss()
        end
        
        -- auto-restart after 3 seconds
        if transition_t > 3 then
            start_transition()
        end
    end
    
    -- ui (draw after effect)
    pal()  -- reset palette for UI
    fillp()
    print("⬅️➡️ change effect", 2, 2, 7)
    print("❎ restart", 2, 10, 7)
    print(effect_names[effect_idx], 2, 120, 7)
end

-- 1. vhs tracking error (fixed gradual fade)
function draw_vhs()
    local el = transition_t
    
    if el > 0.1 then
        -- horizontal distortion
        for y=0,127,2 do
            local offset = sin(y/20 + el*2) * el * 10
            -- copy line with offset
            for x=0,127 do
                local src_x = (x - offset) % 128
                local c = pget(src_x, y)
                pset(x, y, c)
            end
        end
        
        -- add static noise (increases over time)
        for i=1,el*200 do
            local x = flr(rnd(128))
            local y = flr(rnd(128))
            pset(x, y, rnd() < 0.5 and 0 or 7)
        end
        
        -- gradual black bars from top and bottom
        if el > 1.5 then
            local bar_h = (el - 1.5) * 80
            rectfill(0, 0, 127, bar_h, 0)
            rectfill(0, 127-bar_h, 127, 127, 0)
        end
        
        -- full black at end
        if el > 2.5 then
            rectfill(0, 0, 127, 127, 0)
        end
    end
end

-- 2. improved vhs with more effects
function draw_vhs_improved()
    local el = transition_t
    
    -- phase 1: slight distortion
    if el > 0.1 then
        for y=0,127,1 do
            local offset = sin(y/15 + el*3) * (el * 5)
            for x=0,127 do
                local src_x = (x - offset) % 128
                local c = pget(src_x, y)
                pset(x, y, c)
            end
        end
    end
    
    -- phase 2: color degradation
    if el > 0.8 then
        local degrade = (el - 0.8) * 2
        for y=flr(rnd(128)),127,8 do
            for x=0,127 do
                local c = pget(x, y)
                if rnd() < degrade then
                    c = c > 7 and c - 8 or c
                end
                pset(x, y, c)
            end
        end
    end
    
    -- phase 3: increasing static
    if el > 0.3 then
        local static_amt = (el - 0.3) * 300
        for i=1,static_amt do
            local x = flr(rnd(128))
            local y = flr(rnd(128))
            local c = rnd() < el/3 and 0 or (rnd() < 0.5 and 5 or 6)
            pset(x, y, c)
        end
    end
    
    -- phase 4: black creeping in
    if el > 1.8 then
        local black_pct = (el - 1.8) * 2
        for i=1,black_pct*2000 do
            pset(flr(rnd(128)), flr(rnd(128)), 0)
        end
    end
    
    -- ensure full black
    if el > 2.8 then
        rectfill(0, 0, 127, 127, 0)
    end
end

-- 3. corruption effect (slower)
function draw_corruption_slow()
    local el = transition_t
    
    if el > 0.1 then
        -- corrupt memory gradually
        local intensity = el / 2  -- slower
        for i=1,intensity*50 do
            local addr = 0x6000 + flr(rnd(0x2000))
            local val = peek(addr)
            
            -- gradually more corruption
            if rnd() < intensity*0.7 then
                if el < 1 then
                    -- early: just flip some bits
                    val = bxor(val, (1 << flr(rnd(8))))
                elseif el < 2 then
                    -- middle: more aggressive
                    val = rnd() < 0.3 and 0 or bxor(val, 0xFF)
                else
                    -- late: mostly black
                    val = rnd() < 0.8 and 0 or val
                end
            end
            poke(addr, val)
        end
    end
    
    -- ensure full black
    if el > 2.8 then
        rectfill(0, 0, 127, 127, 0)
    end
end

-- 4. melt down (fixed gradual)
function draw_melt_fixed()
    local el = transition_t
    
    if el > 0.1 then
        -- pixels drip down
        for i=1,el*30 do
            local x = flr(rnd(128))
            local y = flr(rnd(100))
            local c = pget(x, y)
            
            -- drip length increases over time
            local drip_len = el * 15
            for j=1,drip_len do
                if y+j < 128 then
                    -- mix with existing color
                    local existing = pget(x, y+j)
                    if existing != 0 or c == 0 then
                        pset(x, y+j, c)
                    end
                end
            end
        end
        
        -- darken colors over time
        if el > 1.5 then
            local darken = (el - 1.5) * 2
            for y=0,127 do
                for x=0,127 do
                    if rnd() < darken*0.3 then
                        local c = pget(x, y)
                        -- darken color
                        if c == 7 then c = 6
                        elseif c == 6 then c = 5
                        elseif c == 15 then c = 14
                        elseif c == 14 then c = 2
                        elseif c == 10 then c = 9
                        elseif c == 9 then c = 4
                        elseif c != 0 and rnd() < darken then c = 0
                        end
                        pset(x, y, c)
                    end
                end
            end
        end
    end
    
    -- ensure full black
    if el > 2.8 then
        rectfill(0, 0, 127, 127, 0)
    end
end

-- 5. digital break
function draw_digital_break()
    local el = transition_t
    
    -- horizontal tears
    if el > 0.2 then
        for i=1,el*5 do
            local y = flr(rnd(128))
            local h = 1 + flr(rnd(3))
            local shift = flr(rnd(20)) - 10
            
            -- shift this horizontal band
            for dy=0,h-1 do
                if y+dy < 128 then
                    for x=0,127 do
                        local src_x = (x - shift) % 128
                        local c = pget(src_x, y+dy)
                        pset(x, y+dy, c)
                    end
                end
            end
        end
    end
    
    -- digital artifacts (blocks)
    if el > 0.8 then
        local blocks = (el - 0.8) * 50
        for i=1,blocks do
            local x = flr(rnd(16)) * 8
            local y = flr(rnd(16)) * 8
            local c = rnd() < el/3 and 0 or flr(rnd(16))
            rectfill(x, y, x+7, y+7, c)
        end
    end
    
    -- black takeover
    if el > 2 then
        local pct = (el - 2) * 3000
        for i=1,pct do
            pset(flr(rnd(128)), flr(rnd(128)), 0)
        end
    end
    
    if el > 2.8 then
        rectfill(0, 0, 127, 127, 0)
    end
end

-- 6. static takeover
function draw_static_takeover()
    local el = transition_t
    
    -- increasing static
    local static_level = el / 3
    
    for y=0,127 do
        for x=0,127 do
            if rnd() < static_level then
                -- static colors
                local c = 0
                if el < 1 then
                    -- colored static
                    c = rnd() < 0.3 and pget(x,y) or (rnd() < 0.5 and 5 or 6)
                elseif el < 2 then
                    -- darker static
                    c = rnd() < 0.5 and 0 or (rnd() < 0.5 and 5 or 1)
                else
                    -- mostly black
                    c = rnd() < 0.9 and 0 or 5
                end
                pset(x, y, c)
            end
        end
    end
    
    if el > 2.8 then
        rectfill(0, 0, 127, 127, 0)
    end
end

-- 7. glitch cascade
function draw_glitch_cascade()
    local el = transition_t
    
    -- vertical glitch bands cascading down
    local cascade_y = el * 60
    
    for y=0,min(127, cascade_y) do
        -- intensity based on distance from cascade front
        local intensity = 1 - (cascade_y - y) / 20
        intensity = max(0, min(1, intensity))
        
        for x=0,127 do
            if rnd() < intensity then
                local c = pget(x, y)
                -- glitch the color
                if intensity > 0.7 then
                    c = 0  -- black at the front
                elseif intensity > 0.3 then
                    c = rnd() < 0.5 and 0 or bxor(c, flr(rnd(16)))
                else
                    -- light corruption
                    if rnd() < 0.3 then
                        c = bxor(c, (1 << flr(rnd(4))))
                    end
                end
                pset(x, y, c)
            end
        end
    end
    
    if el > 2.5 then
        rectfill(0, 0, 127, 127, 0)
    end
end

-- 8. signal loss (tv losing signal)
function draw_signal_loss()
    local el = transition_t
    
    -- rolling horizontal bands
    local roll_offset = el * 30
    
    for y=0,127 do
        local band_y = (y + roll_offset) % 40
        local in_band = band_y < el * 15
        
        for x=0,127 do
            local c = pget(x, y)
            
            if in_band then
                -- in the interference band
                if rnd() < 0.7 then
                    c = rnd() < el/3 and 0 or (rnd() < 0.5 and 6 or 5)
                end
            else
                -- outside band - gradual degradation
                if rnd() < el*0.2 then
                    c = c > 7 and 5 or c
                end
            end
            
            pset(x, y, c)
        end
    end
    
    -- increase black over time
    if el > 1.5 then
        local black_amt = (el - 1.5) * 4000
        for i=1,black_amt do
            pset(flr(rnd(128)), flr(rnd(128)), 0)
        end
    end
    
    if el > 2.8 then
        rectfill(0, 0, 127, 127, 0)
    end
end