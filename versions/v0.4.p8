pico-8 cartridge // http://www.pico-8.com
version 41
__lua__
-- infinite isometric tactics game
-- with direct tile management

function ceil(x) return -flr(-x) end
function clamp(v, lo, hi) return mid(v, lo, hi) end

-- GAME STATES
----------------------
game_state = "menu"
player_ship = nil
local height_cache = {}  -- cache generated heights
local last_cache_cleanup = 0  -- track last cleanup time


-- TILE SYSTEM CONSTANTS
----------------------
VIEW_RANGE = 6  -- tiles to keep around player
tile_w = 24     -- tile width (move here from init_game)
tile_h = 12     -- tile height (move here from init_game) 
block_h = 2     -- height multiplier (move here from init_game)

-- MENU VARIABLES
----------------------
menu_options = {
    {name="terrain scale", values={12, 16, 20}, current=2},
    {name="water level", values={-4, -3, -2, -1, 0, 1, 2, 3, 4}, current=3},
    {name="min height", values={-4, -2, 0, 2, 4, 6}, current=1},
    {name="max height", values={8, 12, 16, 20, 24, 28}, current=4},
    {name="cliff sharpness", values={"smooth", "normal", "sharp", "extreme"}, current=2},
    {name="seed", values={}, current=1, is_seed=true},
    {name="randomize seed", is_action=true},
    {name="start game", is_action=true}
}
menu_cursor = 1
-- current_seed = flr(rnd(9999))
current_seed = 0
preview_tiles = {}
preview_dirty = true
menu_panels = {}

-- PARTICLE SYSTEM
----------------------
particles = {}

particle = {}
particle.__index = particle

function particle.new(x, y, z, col)
    return setmetatable({
        x = x,
        y = y,
        z = z,  -- start at ship's altitude
        vx = (rnd() - 0.5) * 0.05,  -- very little horizontal spread
        vy = (rnd() - 0.5) * 0.05,
        vz = -rnd() * 0.3 - 0.2,  -- strong upward velocity (negative is up)
        life = 20 + rnd(10),  -- lifetime in frames
        max_life = 30,
        col = col,
        size = 1 + rnd(1)  -- particle size
    }, particle)
end

function particle:update()
    self.x += self.vx
    self.y += self.vy
    self.z += self.vz
    
    -- particles just go up, no gravity
    -- slight deceleration
    self.vz *= 0.95
    
    -- apply drag
    self.vx *= 0.9
    self.vy *= 0.9
    
    self.life -= 1
    
    return self.life > 0
end

function particle:draw(cam_x, cam_y)
    -- convert to screen coordinates
    local sx = cam_x + (self.x - self.y) * tile_w/2
    local sy = cam_y + (self.x + self.y) * tile_h/2 + self.z
    
    -- fade out based on life
    local alpha = self.life / self.max_life
    
    if alpha > 0.5 then
        -- full visibility
        if self.size > 1.5 then
            circfill(sx, sy, 1, self.col)
        else
            pset(sx, sy, self.col)
        end
    elseif alpha > 0.25 then
        -- flickering
        if rnd() > 0.3 then
            pset(sx, sy, self.col)
        end
    else
        -- very faint
        if rnd() > 0.6 then
            pset(sx, sy, self.col)
        end
    end
end

-- PANEL CLASS
----------------------
panel = {}
panel.__index = panel

function panel.new(x, y, w, h, text)
    return setmetatable({
        x = x,
        y = y,
        w = w,
        h = h,
        text = text,
        selected = false,
        expand = 0
    }, panel)
end

function panel:update()
    -- smooth expand/contract when selected
    if self.selected then
        self.expand = min(self.expand + 1, 3)
    else
        self.expand = max(self.expand - 1, 0)
    end
end

function panel:draw()
    local dx = self.x - self.expand
    local dw = self.w + self.expand * 2
    
    -- border corners
    rectfill(dx - 1, self.y - 1, dx + 2, self.y + self.h + 1, 5)
    rectfill(dx + dw - 2, self.y - 1, dx + dw + 1, self.y + self.h + 1, 5)
    
    -- background
    rectfill(dx, self.y, dx + dw, self.y + self.h, 0)
    
    -- text
    local col = self.selected and 11 or 6
    print(self.text, dx + 3, self.y + 2, col)
end

-- TILE CLASS
----------------------
tile = {}
tile.__index = tile

function tile.new(world_x, world_y)
    local t = setmetatable({
        x = world_x,
        y = world_y,
        height = 0,
        -- precompute base screen position
        base_sx = 0,
        base_sy = 0,
        -- colors
        top_col = 3,
        side_col = 1,
        dark_col = 0,
    }, tile)
    
    -- generate height for this position
    t.height = generate_height_at(world_x, world_y)
    -- set colors based on height
    t:update_colors()
    -- calculate base screen position
    t:update_screen_pos()
    
    return t
end

function tile:update_colors()
    local h = self.height
    
    -- Negative and low values are water
    if h <= -2 then
        -- deep water
        self.top_col = 1
        self.side_col = 0
        self.dark_col = 0
    elseif h <= 0 then
        -- shallow water
        self.top_col = 12
        self.side_col = 1
        self.dark_col = 1
    elseif h <= 2 then
        -- sand/beach (transition from water to land)
        self.top_col = 15  -- peach/sand color
        self.side_col = 4   -- brown sides
        self.dark_col = 2
    elseif h <= 6 then
        -- flat grass
        self.top_col = 3
        self.side_col = 1
        self.dark_col = 0
    elseif h <= 12 then
        -- grass hills
        self.top_col = 11
        self.side_col = 3
        self.dark_col = 1
    elseif h <= 18 then
        -- dirt/rocks
        self.top_col = 4
        self.side_col = 2
        self.dark_col = 0
    elseif h <= 24 then
        -- mountains
        self.top_col = 6
        self.side_col = 5
        self.dark_col = 0
    else
        -- snow peaks (25-28)
        self.top_col = 7
        self.side_col = 6
        self.dark_col = 5
    end
end

function tile:update_screen_pos()
    self.base_sx = (self.x - self.y) * tile_w/2
    self.base_sy = (self.x + self.y) * tile_h/2
end

function tile:draw()
    local sx = cam_offset_x + self.base_sx
    local sy = cam_offset_y + self.base_sy
    
    local hw = tile_w/2
    local hh = tile_h/2
    
    -- Water tiles (at or below sea level)
    if self.height <= 0 then
        -- Water is drawn at sea level with wave animation
        local wave_speed = self.height <= -2 and 2 or 3  -- deep vs shallow
        local wave_amp = self.height <= -2 and 1 or 0.5
        
        -- Draw animated water surface
        for dy=-hh,hh do
            local width = hw * (1 - abs(dy)/hh)
            if width > 0 then
                -- Animate with waves
                local wave = sin(time() * wave_speed + (self.x + self.y + dy) * 0.1) * wave_amp
                local water_col = self.height <= -2 and 1 or 12  -- deep or shallow color
                line(sx - width, sy + dy + wave, sx + width, sy + dy + wave, water_col)
            end
        end
        -- No outline, no sides for water - just return
        return
    end
    
    -- Land tiles (elevated above sea level)
    local h = self.height
    sy -= h * block_h  -- elevate based on height
    
    -- Draw elevation sides with occlusion culling
    local h_pixels = block_h * h
    
    -- Check adjacent tiles for occlusion
    -- The camera looks from top-left, so we see the south and east faces
    local south_tile = tile_manager:get_tile(self.x, self.y + 1)  -- tile to the south
    local east_tile = tile_manager:get_tile(self.x + 1, self.y)   -- tile to the east
    
    local draw_south_face = not south_tile or south_tile.height < self.height
    local draw_east_face = not east_tile or east_tile.height < self.height
    
    -- Draw south face (left side in screen space)
    if draw_south_face and h_pixels > 0 then
        for i=0,h_pixels,2 do
            line(sx - hw, sy + i, sx, sy + hh + i, self.side_col)
        end
        for i=1,h_pixels,2 do
            line(sx - hw, sy + i, sx, sy + hh + i, self.side_col)
        end
        line(sx - hw, sy, sx - hw, sy + h_pixels, self.dark_col)
    end
    
    -- Draw east face (right side in screen space)
    if draw_east_face and h_pixels > 0 then
        for i=0,h_pixels,2 do
            line(sx + hw, sy + i, sx, sy + hh + i, self.dark_col)
        end
        for i=1,h_pixels,2 do
            line(sx + hw, sy + i, sx, sy + hh + i, self.dark_col)
        end
        line(sx + hw, sy, sx + hw, sy + h_pixels, self.dark_col)
    end
    
    -- Draw top surface
    for dy=0,hh do
        local width = hw * (1 - dy/hh)
        if dy == 0 then
            line(sx - width, sy, sx + width, sy, self.top_col)
        else
            line(sx - width, sy - dy, sx + width, sy - dy, self.top_col)
            line(sx - width, sy + dy, sx + width, sy + dy, self.top_col)
        end
    end
    
    -- Draw outline (only for land)
    line(sx - hw, sy, sx, sy - hh, self.top_col)
    line(sx, sy - hh, sx + hw, sy, self.top_col)
    line(sx + hw, sy, sx, sy + hh, self.top_col)
    line(sx, sy + hh, sx - hw, sy, self.top_col)
end


-- TILE MANAGER
----------------------
tile_manager = {
    tiles = {},  -- 2D array indexed by [x][y]
    tile_list = {},  -- sorted list for drawing
    min_x = 0,
    min_y = 0,
    max_x = 0,
    max_y = 0,
}

function tile_manager:init()
    self.tiles = {}
    self.tile_list = {}
    self.min_x = 0
    self.min_y = 0
    self.max_x = 0
    self.max_y = 0
end

function tile_manager:get_key(x, y)
    return x..","..y
end

function tile_manager:get_tile(x, y)
    if self.tiles[x] then
        return self.tiles[x][y]
    end
    return nil
end

function tile_manager:add_tile(x, y)
    -- Initialize column if needed
    if not self.tiles[x] then
        self.tiles[x] = {}
    end
    
    -- Add tile if it doesn't exist
    if not self.tiles[x][y] then
        local t = tile.new(x, y)
        self.tiles[x][y] = t
        add(self.tile_list, t)
        
        -- Update bounds
        self.min_x = min(self.min_x, x)
        self.max_x = max(self.max_x, x)
        self.min_y = min(self.min_y, y)
        self.max_y = max(self.max_y, y)
    end
end

function tile_manager:remove_tile(x, y)
    if self.tiles[x] and self.tiles[x][y] then
        local t = self.tiles[x][y]
        del(self.tile_list, t)
        self.tiles[x][y] = nil
        
        -- Clean up empty columns
        local has_tiles = false
        for k,v in pairs(self.tiles[x]) do
            has_tiles = true
            break
        end
        if not has_tiles then
            self.tiles[x] = nil
        end
    end
end

function tile_manager:update_player_position(px, py)
    local new_x = flr(px)
    local new_y = flr(py)
    
    if new_x != self.player_x or new_y != self.player_y then
        self.player_x = new_x
        self.player_y = new_y
        self:update_tiles()
    end
end

function tile_manager:update_tiles()
    -- Define the window bounds
    local new_min_x = self.player_x - VIEW_RANGE
    local new_max_x = self.player_x + VIEW_RANGE
    local new_min_y = self.player_y - VIEW_RANGE
    local new_max_y = self.player_y + VIEW_RANGE
    
    -- Add new tiles within range
    for x = new_min_x, new_max_x do
        for y = new_min_y, new_max_y do
            if not self.tiles[x] or not self.tiles[x][y] then
                self:add_tile(x, y)
            end
        end
    end
    
    -- Remove tiles outside range
    local to_remove = {}
    for x = self.min_x, self.max_x do
        if self.tiles[x] then
            for y = self.min_y, self.max_y do
                if self.tiles[x][y] then
                    if x < new_min_x or x > new_max_x or y < new_min_y or y > new_max_y then
                        add(to_remove, {x=x, y=y})
                    end
                end
            end
        end
    end
    
    for coord in all(to_remove) do
        self:remove_tile(coord.x, coord.y)
    end
    
    -- Update bounds
    self.min_x = new_min_x
    self.max_x = new_max_x
    self.min_y = new_min_y
    self.max_y = new_max_y
    
    -- Sort tiles for drawing
    self:sort_tiles()
end

-- Keep the rest of tile_manager functions the same
function tile_manager:sort_tiles()
    -- tiles are usually nearly sorted, so insertion sort is faster
    for i = 2, #self.tile_list do
        local key = self.tile_list[i]
        local key_depth = key.x + key.y
        local j = i - 1
        
        while j >= 1 and (self.tile_list[j].x + self.tile_list[j].y) > key_depth do
            self.tile_list[j + 1] = self.tile_list[j]
            j = j - 1
        end
        
        self.tile_list[j + 1] = key
    end
end

function tile_manager:cleanup_cache()
    -- only keep heights near the player
    local new_cache = {}
    for y = self.player_y - VIEW_RANGE * 2, self.player_y + VIEW_RANGE * 2 do
        for x = self.player_x - VIEW_RANGE * 2, self.player_x + VIEW_RANGE * 2 do
            local key = x..","..y
            if height_cache[key] then
                new_cache[key] = height_cache[key]
            end
        end
    end
    height_cache = new_cache
end

function tile_manager:get_height_at(x, y)
    local t = self:get_tile(x, y)
    if t then
        return t.height
    end
    -- generate if not loaded
    return generate_height_at(x, y)
end

function tile_manager:get_color_at(x, y)
    local t = self:get_tile(x, y)
    if t then
        return t.top_col
    end
    -- if tile doesn't exist, generate temporary one to get color
    local h = generate_height_at(x, y)
    -- replicate color logic from tile:update_colors
    if h <= -2 then
        return 1  -- deep water
    elseif h <= 0 then
        return 12  -- shallow water
    elseif h <= 2 then
        return 15  -- sand
    elseif h <= 6 then
        return 3  -- grass
    elseif h <= 12 then
        return 11  -- grass hills
    elseif h <= 18 then
        return 4  -- dirt
    elseif h <= 24 then
        return 6  -- mountains
    else
        return 7  -- snow
    end
end

-- PERLIN NOISE IMPLEMENTATION
----------------------
function fade(t)
    return t * t * t * (t * (t * 6 - 15) + 10)
end

local function lerp(a, b, t)
    return a + t * (b - a)
end

function grad(hash, x, y)
    local h = hash % 4
    if h == 0 then return x + y
    elseif h == 1 then return -x + y
    elseif h == 2 then return x - y
    else return -x - y
    end
end



function perlin2d(x, y, perm)
    local xi = flr(x) & 127  -- Use 127 instead of 255
    local yi = flr(y) & 127
    local xf = x - flr(x)
    local yf = y - flr(y)
    
    -- Simplified fade - use cheaper approximation
    local u = xf * xf * (3 - 2 * xf)  -- Cheaper than the 6-15-10 version
    local v = yf * yf * (3 - 2 * yf)
    
    local aa = perm[perm[xi] + yi]
    local ab = perm[perm[xi] + yi + 1]
    local ba = perm[perm[xi + 1] + yi]
    local bb = perm[perm[xi + 1] + yi + 1]
    
    local x1 = lerp(grad(aa, xf, yf), grad(ba, xf - 1, yf), u)
    local x2 = lerp(grad(ab, xf, yf - 1), grad(bb, xf - 1, yf - 1), u)
    
    return lerp(x1, x2, v)
end

function generate_permutation(seed)
    srand(seed)
    local perm = {}
    -- Use only 128 values for faster wrapping
    for i = 0, 127 do
        perm[i] = flr(rnd(128))
    end
    -- duplicate for wrapping
    for i = 0, 127 do
        perm[128 + i] = perm[i]
    end
    return perm
end

-- TERRAIN GENERATION
----------------------
terrain_perm = nil

function generate_height_at(world_x, world_y)
    -- check cache first
    local cache_key = world_x..","..world_y
    if height_cache[cache_key] then
        return height_cache[cache_key]
    end
    
    if not terrain_perm then
        terrain_perm = generate_permutation(current_seed)
    end
    
    local scale = menu_options[1].values[menu_options[1].current]
    local water_level = menu_options[2].values[menu_options[2].current]  
    local min_height = menu_options[3].values[menu_options[3].current]
    local max_height = menu_options[4].values[menu_options[4].current]
    local sharpness = menu_options[5].current
    
    local nx = world_x / scale
    local ny = world_y / scale
    
    local height = 0
    local amplitude = 1
    local frequency = 1
    local max_value = 0
    
    -- 3 octaves for performance
    for octave = 1, 3 do
        height = height + perlin2d(nx * frequency, ny * frequency, terrain_perm) * amplitude
        max_value = max_value + amplitude
        amplitude = amplitude * 0.5
        frequency = frequency * 2
    end
    
    height = height / max_value  -- now in range -1 to 1
    
    -- Apply sharpness transformation
    -- 1=smooth (no change), 2=normal (slight), 3=sharp (steep), 4=extreme (cliffs)
    if sharpness == 2 then
        -- normal: slight sharpening
        height = sgn(height) * abs(height) ^ 0.8
    elseif sharpness == 3 then
        -- sharp: create more pronounced edges
        height = sgn(height) * abs(height) ^ 0.5
        -- add some ridged noise for variety
        local ridge = abs(perlin2d(nx * 2, ny * 2, terrain_perm))
        ridge = 1 - ridge
        height = height * 0.8 + ridge * 0.2
    elseif sharpness == 4 then
        -- extreme: very steep cliffs
        height = sgn(height) * abs(height) ^ 0.3
        -- add strong ridged noise
        local ridge = abs(perlin2d(nx * 2, ny * 2, terrain_perm))
        ridge = 1 - ridge
        ridge = ridge * ridge  -- make ridges sharper
        height = height * 0.6 + ridge * 0.4
    end
    -- sharpness == 1 (smooth) leaves height unchanged
    
    -- Map from [-1, 1] to [min_height, max_height]
    height = min_height + (height + 1) * 0.5 * (max_height - min_height)
    
    -- Water level adjustment shifts everything up/down
    -- Subtract water_level so negative values raise terrain (less water)
    -- and positive values lower terrain (more water)
    height = height - water_level
    
    -- Clamp to our actual range
    height = flr(clamp(height, -4, 28))
    
    -- cache the result
    height_cache[cache_key] = height
    
    return height
end

-- SHIP CLASS
----------------------
ship = {}
ship.__index = ship

function ship.new(start_x, start_y)
    return setmetatable({
        x = start_x or 0,
        y = start_y or 0,
        vx = 0,
        vy = 0,
        vz = 0,
        hover_height = 1,
        current_altitude = 0,
        angle = 0,
        accel = 0.1,
        friction = 0.85,
        max_speed = 0.5,
        size = 10,
        body_col = 12,
        outline_col = 7,
        shadow_col = 1,
        gravity = 0.2,
        max_climb = 3,
        is_hovering = false,
        particle_timer = 0,
        ramp_boost = 0.2,  -- multiplier for converting horizontal speed to vertical when hitting ramp
    }, ship)
end

function ship:get_terrain_height_at(x, y)
    local height = tile_manager:get_height_at(flr(x), flr(y))
    return max(0, height)
end

function ship:update()
    local old_x, old_y = self.x, self.y
    
    local input_x = 0
    local input_y = 0
    
    if btn(➡️) then
        input_x += self.accel
        input_y -= self.accel
    end
    if btn(⬅️) then
        input_x -= self.accel
        input_y += self.accel
    end
    if btn(⬇️) then
        input_x += self.accel
        input_y += self.accel
    end
    if btn(⬆️) then
        input_x -= self.accel
        input_y -= self.accel
    end
    
    self.vx += input_x * 0.707
    self.vy += input_y * 0.707
    
    self.vx *= self.friction
    self.vy *= self.friction
    
    local speed = sqrt(self.vx * self.vx + self.vy * self.vy)
    if speed > self.max_speed then
        self.vx = (self.vx / speed) * self.max_speed
        self.vy = (self.vy / speed) * self.max_speed
    end
    
    self.x += self.vx
    self.y += self.vy
    
    -- update tile manager with new position
    tile_manager:update_player_position(self.x, self.y)
    
    local current_terrain = self:get_terrain_height_at(old_x, old_y)
    local new_terrain = self:get_terrain_height_at(self.x, self.y)
    local height_diff = new_terrain - current_terrain
    
    -- Check if we hit a wall that's too steep
    if height_diff > self.max_climb then
        local can_move_x = false
        local can_move_y = false
        
        local terrain_x = self:get_terrain_height_at(self.x, old_y)
        if terrain_x - current_terrain <= self.max_climb then
            can_move_x = true
        end
        
        local terrain_y = self:get_terrain_height_at(old_x, self.y)
        if terrain_y - current_terrain <= self.max_climb then
            can_move_y = true
        end
        
        if can_move_x and not can_move_y then
            self.y = old_y
            new_terrain = terrain_x
            height_diff = new_terrain - current_terrain
        elseif can_move_y and not can_move_x then
            self.x = old_x
            new_terrain = terrain_y
            height_diff = new_terrain - current_terrain
        else
            self.x = old_x
            self.y = old_y
            self.vx *= -0.2
            self.vy *= -0.2
            new_terrain = current_terrain
            height_diff = 0
        end
    end
    
    -- RAMP PHYSICS: Only apply when we're hovering/following terrain
    if self.is_hovering and height_diff > 0 and speed > 0.01 then
        -- Going up a ramp while hovering - convert to vertical velocity and launch!
        local boost = height_diff * self.ramp_boost * speed * 10
        self.vz = boost
        -- We're now airborne!
        self.is_hovering = false
    end
    
    -- Update altitude with physics
    local target_altitude = new_terrain + self.hover_height
    
    -- Check if we're currently hovering (at target altitude)
    if self.is_hovering then
        -- Follow terrain while hovering
        self.current_altitude = target_altitude
        -- Keep vertical velocity at 0 while hovering
        self.vz = 0
    else
        -- We're airborne - apply physics
        
        -- Apply vertical velocity
        self.current_altitude += self.vz
        
        -- Apply gravity
        self.vz -= self.gravity
        
        -- Check if we've reached ground level
        if self.current_altitude <= target_altitude then
            -- Landing - return to hovering (no bounce)
            self.current_altitude = target_altitude
            self.vz = 0
            self.is_hovering = true
        end
        
        -- Apply air dampening
        self.vz *= 0.98
    end
    
    -- Spawn particles when hovering AND moving
    if self.is_hovering and speed > 0.01 then
        self.particle_timer += 1
        
        local spawn_rate = max(1, 5 - flr(speed * 10))
        
        if self.particle_timer >= spawn_rate then
            self.particle_timer = 0
            
            local terrain_height = self:get_terrain_height_at(self.x, self.y)
            local particle_col = terrain_height <= 0 and 7 or 0
            
            local num_particles = 1 + flr(speed * 5)
            for i = 1, num_particles do
                local px = self.x + (rnd() - 0.5) * 0.1
                local py = self.y + (rnd() - 0.5) * 0.1
                
                local ship_z = -self.current_altitude * block_h
                local p = particle.new(px, py, ship_z, particle_col)
                
                add(particles, p)
            end
        end
    else
        self.particle_timer = 0
    end
    
    if abs(self.vx) > 0.01 or abs(self.vy) > 0.01 then
        local screen_vx = (self.vx - self.vy)
        local screen_vy = (self.vx + self.vy) * 0.5
        self.angle = atan2(screen_vx, screen_vy)
    end
end

function ship:get_screen_pos()
    local sx = cam_offset_x + (self.x - self.y) * tile_w/2
    local sy = cam_offset_y + (self.x + self.y) * tile_h/2
    sy -= self.current_altitude * block_h
    return sx, sy
end

function ship:get_camera_target()
    local sx = (self.x - self.y) * tile_w/2
    local sy = (self.x + self.y) * tile_h/2
    sy -= self.current_altitude * block_h
    return 64 - sx, 64 - sy
end

function ship:draw()
    local sx, sy = self:get_screen_pos()
    
    local nose_length = self.size * 0.8
    local tail_length = self.size * 0.8
    
    local points = {}
    
    -- Calculate triangle points around center (sx, sy)
    local fx = sx + cos(self.angle) * nose_length
    local fy = sy + sin(self.angle) * nose_length * 0.5
    add(points, {fx, fy})
    
    -- Back points equidistant from center
    local back_angle = self.angle + 0.5
    local blx = sx + cos(back_angle - 0.15) * tail_length
    local bly = sy + sin(back_angle - 0.15) * tail_length * 0.5
    add(points, {blx, bly})
    
    local brx = sx + cos(back_angle + 0.15) * tail_length
    local bry = sy + sin(back_angle + 0.15) * tail_length * 0.5
    add(points, {brx, bry})
    
    -- Helper function to draw a filled triangle
    local function draw_triangle(p1, p2, p3, col)
        local x1, y1 = p1[1], p1[2]
        local x2, y2 = p2[1], p2[2]
        local x3, y3 = p3[1], p3[2]
        
        -- Sort points by y coordinate
        if y2 < y1 then
            x1, y1, x2, y2 = x2, y2, x1, y1
        end
        if y3 < y1 then
            x1, y1, x3, y3 = x3, y3, x1, y1
        end
        if y3 < y2 then
            x2, y2, x3, y3 = x3, y3, x2, y2
        end
        
        -- Fill triangle using horizontal lines
        for y = y1, y3 do
            local xa, xb
            
            if y <= y2 then
                -- Top half of triangle
                if y2 - y1 > 0 then
                    xa = x1 + (x2 - x1) * (y - y1) / (y2 - y1)
                else
                    xa = x1
                end
                if y3 - y1 > 0 then
                    xb = x1 + (x3 - x1) * (y - y1) / (y3 - y1)
                else
                    xb = x1
                end
            else
                -- Bottom half of triangle
                if y3 - y2 > 0 then
                    xa = x2 + (x3 - x2) * (y - y2) / (y3 - y2)
                else
                    xa = x2
                end
                if y3 - y1 > 0 then
                    xb = x1 + (x3 - x1) * (y - y1) / (y3 - y1)
                else
                    xb = x3
                end
            end
            
            -- Draw horizontal line
            if xa and xb then
                line(min(xa, xb), y, max(xa, xb), y, col)
            end
        end
    end
    
    -- Draw shadow (same triangle, but projected on ground)
    local terrain_height = self:get_terrain_height_at(self.x, self.y)
    local shadow_y = cam_offset_y + (self.x + self.y) * tile_h/2 - terrain_height * block_h
    
    -- Calculate shadow offset (how much shadow is displaced from ship)
    local shadow_offset = (self.current_altitude - terrain_height) * block_h
    
    -- Create shadow points (same shape, but at ground level)
    local shadow_points = {
        {points[1][1], points[1][2] + shadow_offset},
        {points[2][1], points[2][2] + shadow_offset},
        {points[3][1], points[3][2] + shadow_offset}
    }
    
    -- Draw filled shadow
    draw_triangle(shadow_points[1], shadow_points[2], shadow_points[3], self.shadow_col)
    
    -- Draw ship body
    draw_triangle(points[1], points[2], points[3], self.body_col)
    
    -- Draw ship outline
    for i=1,3 do
        local j = i % 3 + 1
        line(points[i][1], points[i][2], points[j][1], points[j][2], self.outline_col)
    end
    
    -- Simple thruster effects
    if self.is_hovering then
        -- Simple pulsing thrusters at back corners
        local pulse = sin(time() * 5)
        
        -- Main thruster dots
        if pulse > 0 then
            pset(points[2][1], points[2][2], 10)  -- yellow
            pset(points[3][1], points[3][2], 10)
        else
            pset(points[2][1], points[2][2], 9)   -- orange
            pset(points[3][1], points[3][2], 9)
        end
        
        -- Small exhaust trail below
        if rnd() > 0.3 then
            pset(points[2][1], points[2][2] + 1, 8)
            pset(points[3][1], points[3][2] + 1, 8)
        end
    end
end

function ship:get_speed()
    return sqrt(self.vx * self.vx + self.vy * self.vy)
end

-- INIT FUNCTIONS
----------------------
function _init()
    init_menu()
end

function init_menu()
    game_state = "menu"
    menu_cursor = 1
    preview_dirty = true
    
    -- create panels for each menu option
    menu_panels = {}
    for i, option in ipairs(menu_options) do
        local y = 24 + i * 10
        local text = option.name
        if not option.is_action then
            if option.is_seed then
                text = text .. ": " .. current_seed
            else
                text = text .. ": " .. tostr(option.values[option.current])
            end
        end
        menu_panels[i] = panel.new(4, y, 64, 8, text)
    end
    
    -- select first panel
    menu_panels[1].selected = true
end

function init_game()
    game_state = "game"
    
    -- camera offset
    cam_offset_x = 0
    cam_offset_y = 0
    cam_target_x = 0
    cam_target_y = 0
    
    -- clear particles when starting game
    particles = {}
    
    -- create ship at origin (use different variable name!)
    player_ship = ship.new(0, 0)
    
    -- Only load tiles we don't already have
    tile_manager:update_player_position(0, 0)
    tile_manager:update_tiles()
    
    player_ship.current_altitude = player_ship:get_terrain_height_at(player_ship.x, player_ship.y) + player_ship.hover_height
    
    -- initialize camera
    cam_target_x, cam_target_y = player_ship:get_camera_target()
    cam_offset_x = cam_target_x
    cam_offset_y = cam_target_y
    
    -- initialize cache cleanup timer
    last_cache_cleanup = time()
end

-- MENU FUNCTIONS
----------------------
function generate_preview()
    local scale = menu_options[1].values[menu_options[1].current]
    local water_level = menu_options[2].values[menu_options[2].current]
    local min_height = menu_options[3].values[menu_options[3].current]
    local max_height = menu_options[4].values[menu_options[4].current]
    local sharpness = menu_options[5].current
    
    local map_size = 64
    
    -- Clear the height cache when regenerating
    height_cache = {}
    
    -- Generate new permutation with current seed
    terrain_perm = generate_permutation(current_seed)
    
    -- Clear and initialize tile manager
    tile_manager:init()
    
    preview_tiles = {}
    for y = 1, map_size do
        preview_tiles[y] = {}
        for x = 1, map_size do
            -- Generate actual world coordinates (centered around origin)
            local world_x = x - 32
            local world_y = y - 32
            
            -- Create the actual tile using tile_manager
            tile_manager:add_tile(world_x, world_y)
            local tile = tile_manager:get_tile(world_x, world_y)
            
            -- Store reference for preview drawing
            preview_tiles[y][x] = tile
        end
    end
    
    -- No water smoothing needed anymore!
end

function draw_menu()
    cls(1)
    
    if preview_dirty then
        generate_preview()
        preview_dirty = false
    end
    
    print("infinite terrain", 32, 8, 7)
    print("================", 32, 14, 5)
    
    -- draw all panels
    for p in all(menu_panels) do
        p:draw()
    end
    
    print("⬅️➡️:change ⬆️⬇️:select", 4, 106, 5)
    print("❎ or 🅾️:confirm", 4, 114, 5)
    
    draw_preview()
end

function draw_preview()
    local map_size = 48
    local start_x = 74
    local start_y = 24
    
    for y = 1, map_size do
        for x = 1, map_size do
            local tile = preview_tiles[y][x]
            pset(start_x + x - 1, start_y + y - 1, tile.top_col)
        end
    end
    
    rect(start_x - 1, start_y - 1, start_x + map_size, start_y + map_size, 5)
end

function update_menu()
    -- navigation
    if btnp(⬆️) then
        menu_panels[menu_cursor].selected = false
        menu_cursor = menu_cursor - 1
        if menu_cursor < 1 then menu_cursor = #menu_options end
        menu_panels[menu_cursor].selected = true
    end
    if btnp(⬇️) then
        menu_panels[menu_cursor].selected = false
        menu_cursor = menu_cursor + 1
        if menu_cursor > #menu_options then menu_cursor = 1 end
        menu_panels[menu_cursor].selected = true
    end
    
    local option = menu_options[menu_cursor]
    local panel = menu_panels[menu_cursor]
    
    if option.is_action then
        if btnp(❎) or btnp(🅾️) then
            if option.name == "start game" then
                init_game()
            elseif option.name == "randomize seed" then
                current_seed = flr(rnd(9999))
                preview_dirty = true
                -- update seed panel text
                menu_panels[6].text = "seed: " .. current_seed
            end
        end
    elseif option.is_seed then
        if btnp(⬅️) then
            current_seed = max(0, current_seed - 1)
            preview_dirty = true
            panel.text = option.name .. ": " .. current_seed
        end
        if btnp(➡️) then
            current_seed = min(9999, current_seed + 1)
            preview_dirty = true
            panel.text = option.name .. ": " .. current_seed
        end
    else
        if btnp(⬅️) then
            option.current = option.current - 1
            if option.current < 1 then option.current = #option.values end
            preview_dirty = true
            panel.text = option.name .. ": " .. tostr(option.values[option.current])
        end
        if btnp(➡️) then
            option.current = option.current + 1
            if option.current > #option.values then option.current = 1 end
            preview_dirty = true
            panel.text = option.name .. ": " .. tostr(option.values[option.current])
        end
    end
    
    -- update all panels
    for p in all(menu_panels) do
        p:update()
    end
end

-- MAIN UPDATE & DRAW
----------------------
function _update()
    if game_state == "menu" then
        update_menu()
    elseif game_state == "game" then
        update_game()
    end
end

function update_game()
    -- return to menu
    if btn(🅾️) and btn(❎) then
        init_menu()
        return
    end
    
    -- update ship
    player_ship:update()
    cam_target_x, cam_target_y = player_ship:get_camera_target()
    
    -- smooth camera movement (higher = less lag)
    cam_offset_x += (cam_target_x - cam_offset_x) * 0.3
    cam_offset_y += (cam_target_y - cam_offset_y) * 0.3
    
    -- update particles
    local new_particles = {}
    for p in all(particles) do
        if p:update() then
            add(new_particles, p)
        end
    end
    particles = new_particles
    
    -- limit max particles for performance
    if #particles > 100 then
        -- remove oldest particles
        for i = 1, #particles - 100 do
            deli(particles, 1)
        end
    end
    
    -- cleanup cache every 2 seconds using time()
    local current_time = time()
    if current_time - last_cache_cleanup > 2 then
        tile_manager:cleanup_cache()
        last_cache_cleanup = current_time
    end
end

function _draw()
    if game_state == "menu" then
        draw_menu()
    elseif game_state == "game" then
        draw_game()
    end
    -- performance monitoring
    printh("mem: "..tostr(stat(0)).." \t| cpu: "..tostr(stat(1)).." \t| fps: "..tostr(stat(7)))
end

function draw_game()
    cls(1)
    
    -- draw all tiles using their draw method
    for tile in all(tile_manager.tile_list) do
        tile:draw()
    end
    
    -- draw particles (before ship so they appear behind)
    for p in all(particles) do
        p:draw(cam_offset_x, cam_offset_y)
    end
    
    -- draw ship
    player_ship:draw()
    
    -- draw ui
    draw_ui()
end

function draw_ui()
    -- Black band at bottom
    rectfill(0, 120, 127, 127, 0)
    
    -- Speed bar configuration
    local bar_x = 4
    local bar_y = 122
    local rect_width = 3
    local rect_height = 4
    local spacing = 1
    local max_bars = 20  -- total number of rectangles
    
    -- Calculate current speed and how many bars to fill
    local current_speed = player_ship:get_speed()
    local speed_ratio = current_speed / player_ship.max_speed
    local filled_bars = flr(speed_ratio * max_bars)
    
    -- Draw the speed bar
    for i = 0, max_bars - 1 do
        local x = bar_x + i * (rect_width + spacing)
        local col = i < filled_bars and 8 or 5  -- red if filled, grey if not
        rectfill(x, bar_y, x + rect_width - 1, bar_y + rect_height - 1, col)
    end
    
    -- Menu hint (on the black band)
    print("🅾️+❎:menu", 88, 121, 5)
end

__map__
0000000000000000000000000001000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
__sfx__
010b00001007300000000000000010675300040000000000100730000010073000001067500000000000000010073000000000000000106750000000000000001007300000000000000010675000000000000000
010b00001007300000000000000010675300040000000000100730000010073000001067500000000000000010073000000000000000106750000000000000001007300000000000000010675000001067510675
010b0000110400000011040000001104000000110400000011040000001104000000110400000011040000000d040000000d040000000d040000000d040000000f040000000f040000000f040000000f04000000
010b0000110400000011040000001104000000110400000011040000001104000000110400000011040000000f040000000f040000000f040000000f040000000f040000000f040000000f040000000f04000000
010b00000d040000000d040000000d040000000d040000000d040000000d040000000d040000000d040000000f040000000f040000000f040000000f040000000f040000000f040000000f040000000f04000000
010b0000110400000011040000001104000000110400000011040000001104000000110400000011040000000f0420f0420f0420f0420f0420f0420f0420f0420f0420f0420f0420f0420f0420f0420f0420f042
050b0000203300000020330000001d33000000203300000020330000001d33000000203300000024330000001f330000001f330000001b330000001f3300000022330000001b3300000022330000002233000000
050b0000203300000020330000001d33000000203300000020330000001d33000000203300000024330000001b3121b3121b3121b3121b3221b3221b3221b3221b3321b3321b3321b3321b3421b3421b3421b342
010b0000247402474024740247402c7402c7402c7402c7402b7402b7402b7402b7402774027740277402774029740297402974029740297402974024740247402474024740247402474022740227402274022740
010b00002474024740247402474027740277402074020740207402074020740207402274022740227402274024740247402474024740277402774027740277402774027740277402774029740297402974029740
010b00002974229742297422974229742297422974229742297422974229742297422974229742297421f7421f7421f7421f7421f7421f7421f7421f7421f7421f7421f7421f7421f7421f7421f7421f7421f742
150b00001007300000000000000010675300040000000000000000000010073000001067500000000000000010073000000000000000106750000000000000001007310623106231063310643106531066310673
450b000029240292402922029210302403024030220302102c2402c2402c2202c2102b2402b2402c2402c2402b2402b2402b2202b21027240272402b2402b2402b2202b2102e2502e2402c2402c2402b2402b240
450b000029240292402922029210302403024030220302102c2402c240292402924030240302402e2402e2402e2202e2102c2402c2402c2202c2102b2402b2402b2202b21027240272402c2402c2402b2402b240
450b000029240292402924029240292402924029240292402924029240292202921029240292402b2402b2402c2402c2402c2402c2402c2202c2102b2402b2402b2202b210000000000030240302402c2402c240
450b00002924229242292422924229242292422924229242292422924229242292422924229242292422924229242292422924229242292422924229242292422924229242292422924229242292422924229242
470b00000534000300113400030005340003001134000300053400030011340003000534000300113400030001340003000d3400030001340003000d3400030003340003000f3400030003340003000f34000300
470b00000534000300113400030005340003001134000300053400030011340003000534000300113400030003340003000f3400030003340003000f3400030003340003000f3400030003340003000f34000300
470b000001340003000d3400030001340003000d3400030001340003000d3400030001340003000d3400030003340003000f3400030003340003000f3400030003340003000f3400030003340003000f34000300
470b00000534000300113400030005340003001134000300053400030011340003000534000300113400030005340003001134000300053400030011340003000534000300113400030005340003001134000300
010b00001104000000110400000011040000001104000000110400000011040000001104000000110400000011040000001104000000110400000011040000000f04000000110400000014040000001304000000
010b00001007300000000000000010675300040000000000100030000010073000001067500000000000000010073000000000000000106750000000000000001000300000100730000010675000000400500000
010b000029740297402974024740247402474030740307402e7402e7402e7402e7402b7402b7402c7402c7402e7402e7402e7402e740277402774022740227402274022740277402774027740277402274022750
010b00002b7502b750000002b7522c7502b700297502975029750297502975029750297502975029750000002b7502b750000002b7522c7502b70029750297502975029750297502975029750297502975000000
010b000029740297402974024740247402474030740307402e7402e7402e7402e7402b7402b7402c7402c7402e7402e7402e7402e740277402774033740337403370033700317403174031700317003074030740
010b0000307423074230742307423074230742307423074230742307423074230742307423074230742307422c7402c74000000000002b7502b75000000000002c7502c75000000000002e7502e7500000000000
010b000020740207402074020740207402074020740207402075020750207502075020750227502575024750227502275022750227502275022750227202271022750227501f7001f7501f7501b7001b7501b750
001000001d7421d7421d7421d7421d7421d7421d7421d7421d7421d7421d7421d7421d7421d7421d7421d7421d7421d7421d7421d7421d7421d7421d7421d7421d7421d7421d7421d7421d7421d7421d7421d742
010b00000534711347147470534711347147470534711347053471134714747053471134714747053471134705347113471474705347113471474705347113470534711347147470534711347147470534711347
__music__
01 02064344
00 03060844
00 04060944
00 05070a0b
00 00020c10
00 01030d11
00 00040e12
00 0b050f11
00 00020c10
00 01030d11
00 00040e12
00 0b050f11
00 15041612
00 15141713
00 15041812
00 15141913
00 15041612
00 15141713
00 15041a12
02 0b141b13

