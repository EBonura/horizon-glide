pico-8 cartridge // http://www.pico-8.com
version 41
__lua__

-- explosion test cart
-- click to spawn explosions

particles = {}
explosion_size = 1  -- start with small

function _init()
    cls()
end

function _update()
    -- change explosion size
    if btnp(⬅️) then
        explosion_size = max(0.5, explosion_size - 0.5)
    end
    if btnp(➡️) then
        explosion_size = min(3, explosion_size + 0.5)
    end
    
    -- spawn explosion on click
    if btnp(❎) then
        explode(64, 64, explosion_size)
    end
    
    -- spawn at random position
    if btnp(🅾️) then
        explode(20 + rnd(88), 20 + rnd(88), explosion_size)
    end
    
    -- update particles
    local new_p = {}
    for p in all(particles) do
        p.life -= 1
        
        -- drift and slow down
        p.x += p.vx
        p.y += p.vy
        p.vx *= 0.9
        p.vy *= 0.9
        
        if p.life > 0 then
            add(new_p, p)
        end
    end
    particles = new_p
end

function _draw()
    cls(1)
    
    -- draw all particles
    for p in all(particles) do
        local alpha = p.life / p.max_life
        
        -- color progression
        local col = 7  -- white
        if alpha < 0.8 then col = 10 end  -- yellow
        if alpha < 0.5 then col = 9 end   -- orange  
        if alpha < 0.3 then col = 8 end   -- red
        if alpha < 0.15 then col = 2 end  -- dark red
        
        circfill(p.x, p.y, p.size, col)
    end
    
    -- instructions
    print("⬅️➡️ size: " .. explosion_size, 2, 2, 7)
    print("❎ = explode at center", 2, 10, 7)
    print("🅾️ = explode at random", 2, 18, 7)
    print("particles: "..#particles, 2, 120, 6)
end

function explode(x, y, size_multiplier)
    size_multiplier = size_multiplier or 1
    
    -- scale particle counts based on size
    local big_count = flr(3 * size_multiplier)
    local med_count = flr(5 * size_multiplier)
    local small_count = flr(4 * size_multiplier)
    
    -- spawn big circles (core)
    for i=1,big_count do
        add(particles, {
            x = x + (rnd()-0.5) * 4 * size_multiplier,
            y = y + (rnd()-0.5) * 4 * size_multiplier,
            vx = (rnd()-0.5) * 0.5 * size_multiplier,
            vy = (rnd()-0.5) * 0.5 * size_multiplier,
            size = (3 + rnd(2)) * size_multiplier,
            life = 15,
            max_life = 15
        })
    end
    
    -- spawn medium circles
    for i=1,med_count do
        add(particles, {
            x = x + (rnd()-0.5) * 6 * size_multiplier,
            y = y + (rnd()-0.5) * 6 * size_multiplier,
            vx = (rnd()-0.5) * 1 * size_multiplier,
            vy = (rnd()-0.5) * 1 * size_multiplier,
            size = (2 + rnd(1)) * size_multiplier,
            life = 20,
            max_life = 20
        })
    end
    
    -- spawn small circles (outer)
    for i=1,small_count do
        add(particles, {
            x = x + (rnd()-0.5) * 8 * size_multiplier,
            y = y + (rnd()-0.5) * 8 * size_multiplier,
            vx = (rnd()-0.5) * 1.5 * size_multiplier,
            vy = (rnd()-0.5) * 1.5 * size_multiplier,
            size = 1 * size_multiplier,
            life = 25,
            max_life = 25
        })
    end
end