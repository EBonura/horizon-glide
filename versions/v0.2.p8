pico-8 cartridge // http://www.pico-8.com
version 41
__lua__
-- isometric tactics game
-- with menu and perlin noise terrain

function ceil(x) return -flr(-x) end
function clamp(v, lo, hi) return mid(v, lo, hi) end

-- GAME STATES
----------------------
-- states: "menu", "game"
game_state = "menu"

-- MENU VARIABLES
----------------------
menu_options = {
    {name="map size", values={32, 48, 64}, current=2},
    {name="terrain scale", values={4, 6, 8, 12, 16}, current=3},
    {name="water level", values={-4, -2, 0, 2, 4}, current=3},
    {name="mountains", values={"none", "low", "medium", "high", "extreme"}, current=3},
    {name="seed", values={}, current=1, is_seed=true},
    {name="randomize seed", is_action=true},
    {name="start game", is_action=true}
}
menu_cursor = 1
current_seed = flr(rnd(9999))
preview_tiles = {}
preview_dirty = true  -- flag to regenerate preview only when needed

function _init()
    -- initialize menu
    init_menu()
end

function init_menu()
    game_state = "menu"
    menu_cursor = 1
    preview_dirty = true  -- mark preview as needing regeneration
end

function init_game()
    game_state = "game"
    
    -- get selected options
    local size_option = menu_options[1]
    grid_width = size_option.values[size_option.current]
    grid_height = grid_width
    
    -- isometric tile dimensions
    tile_w = 24
    tile_h = 12
    block_h = 2  -- decreased from 4 to 2 for smoother terrain
    
    -- camera offset
    cam_offset_x = 0
    cam_offset_y = 0
    cam_target_x = 0
    cam_target_y = 0
    
    -- create tile objects
    tiles = {}
    for y=1,grid_height do
        tiles[y] = {}
        for x=1,grid_width do
            tiles[y][x] = tile.new(x, y, 0)
        end
    end
    
    -- generate terrain with selected parameters
    generate_terrain_from_menu()
    
    -- spawn position
    local spawn_x = flr(grid_width/2)
    local spawn_y = flr(grid_height/2)
    
    -- create ship
    ship = ship.new(spawn_x, spawn_y)
    ship.current_altitude = ship:get_terrain_height_at(ship.x, ship.y) + ship.hover_height
    
    -- initialize camera to follow ship
    cam_target_x, cam_target_y = ship:get_camera_target()
    cam_offset_x = cam_target_x
    cam_offset_y = cam_target_y
    
    -- visible tiles cache
    visible_tiles = {}
    
    -- animation timer
    t = 0
end

-- PERLIN NOISE IMPLEMENTATION
----------------------
function fade(t)
    return t * t * t * (t * (t * 6 - 15) + 10)
end

function lerp(a, b, t)
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
    local xi = flr(x) & 255
    local yi = flr(y) & 255
    local xf = x - flr(x)
    local yf = y - flr(y)
    
    local u = fade(xf)
    local v = fade(yf)
    
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
    for i = 0, 255 do
        perm[i] = i
    end
    
    -- shuffle
    for i = 255, 1, -1 do
        local j = flr(rnd(i + 1))
        perm[i], perm[j] = perm[j], perm[i]
    end
    
    -- duplicate for wrapping
    for i = 0, 255 do
        perm[256 + i] = perm[i]
    end
    
    return perm
end

-- MENU FUNCTIONS
----------------------
function generate_preview()
    local scale = menu_options[2].values[menu_options[2].current]
    local water_level = menu_options[3].values[menu_options[3].current]
    local mountain_level = menu_options[4].current
    
    -- use selected map size for preview
    local map_size = menu_options[1].values[menu_options[1].current]
    
    -- use current seed
    local perm = generate_permutation(current_seed)
    
    preview_tiles = {}
    for y = 1, map_size do
        preview_tiles[y] = {}
        for x = 1, map_size do
            -- generate height using perlin noise
            local nx = x / scale
            local ny = y / scale
            
            local height = 0
            local amplitude = 1
            local frequency = 1
            local max_value = 0
            
            -- multiple octaves for more interesting terrain
            for octave = 1, 3 do
                height = height + perlin2d(nx * frequency, ny * frequency, perm) * amplitude
                max_value = max_value + amplitude
                amplitude = amplitude * 0.5
                frequency = frequency * 2
            end
            
            height = height / max_value
            
            -- map to height range based on mountain level (now 0-32)
            local height_range = ({8, 12, 16, 24, 32})[mountain_level]
            height = flr(height * height_range + height_range/2)
            
            -- apply water level and create depth
            if height <= water_level then
                -- create water depth based on how far below water level
                local depth = water_level - height
                if depth >= 3 then
                    height = -3  -- deep water
                else
                    height = -1  -- shallow water
                end
            end
            
            preview_tiles[y][x] = {
                height = height,
                x = x,
                y = y
            }
        end
    end
end

function draw_menu()
    cls(1)
    
    -- regenerate preview only if needed
    if preview_dirty then
        generate_preview()
        preview_dirty = false
    end
    
    -- title
    print("isometric tactics", 28, 8, 7)
    print("==================", 28, 14, 5)
    
    -- options
    for i, option in ipairs(menu_options) do
        local y = 24 + i * 8
        local col = (i == menu_cursor) and 11 or 6
        
        if option.is_action then
            -- action buttons
            print("> "..option.name, 4, y, col)
        elseif option.is_seed then
            -- seed display
            print(option.name..":", 4, y, col)
            print(current_seed, 50, y, col)
        else
            -- regular option
            print(option.name..":", 4, y, col)
            local value = option.values[option.current]
            print(tostr(value), 50, y, col)
        end
        
        -- arrows for selected option (not for actions)
        if i == menu_cursor and not option.is_action then
            print("<", 44, y, 11)
            print(">", 58, y, 11)
        end
    end
    
    -- controls
    print("⬅️➡️:change ⬆️⬇️:select", 4, 104, 5)
    print("❎ or 🅾️:confirm", 4, 110, 5)
    
    -- draw preview
    draw_preview()
end

function draw_preview()
    -- get current map size
    local map_size = menu_options[1].values[menu_options[1].current]
    
    -- draw one pixel per tile
    local start_x = 74
    local start_y = 32
    
    for y = 1, map_size do
        for x = 1, map_size do
            local tile = preview_tiles[y][x]
            
            -- determine color based on height (with deep/shallow water)
            local col
            if tile.height <= -3 then
                col = 1   -- deep water (dark blue)
            elseif tile.height <= -1 then
                col = 12  -- shallow water (light blue)
            elseif tile.height >= 24 then
                col = 7   -- snow
            elseif tile.height >= 16 then
                col = 6   -- mountain
            elseif tile.height >= 8 then
                col = 4   -- dirt
            elseif tile.height >= 2 then
                col = 11  -- grass hill
            else
                col = 3   -- flat grass
            end
            
            -- one pixel per tile
            pset(start_x + x - 1, start_y + y - 1, col)
        end
    end
    
    -- draw border around preview
    rect(start_x - 1, start_y - 1, start_x + map_size, start_y + map_size, 5)
end

function update_menu()
    -- navigate options
    if btnp(⬆️) then
        menu_cursor = menu_cursor - 1
        if menu_cursor < 1 then menu_cursor = #menu_options end
    end
    if btnp(⬇️) then
        menu_cursor = menu_cursor + 1
        if menu_cursor > #menu_options then menu_cursor = 1 end
    end
    
    local option = menu_options[menu_cursor]
    
    -- handle action buttons
    if option.is_action then
        if btnp(❎) or btnp(🅾️) then
            if option.name == "start game" then
                init_game()
            elseif option.name == "randomize seed" then
                current_seed = flr(rnd(9999))
                preview_dirty = true
            end
        end
    -- handle seed input
    elseif option.is_seed then
        if btnp(⬅️) then
            current_seed = max(0, current_seed - 1)
            preview_dirty = true
        end
        if btnp(➡️) then
            current_seed = min(9999, current_seed + 1)
            preview_dirty = true
        end
    -- handle regular options
    else
        if btnp(⬅️) then
            option.current = option.current - 1
            if option.current < 1 then option.current = #option.values end
            preview_dirty = true
        end
        if btnp(➡️) then
            option.current = option.current + 1
            if option.current > #option.values then option.current = 1 end
            preview_dirty = true
        end
    end
end

-- TILE CLASS
----------------------
tile = {}
tile.__index = tile

function tile.new(x, y, height)
    local t = setmetatable({
        x = x,
        y = y,
        height = height,
        base_sx = (x - y) * tile_w/2,
        base_sy = (x + y) * tile_h/2,
        top_col = 11,
        side_col = 3,
        dark_col = 1,
    }, tile)
    t:update_colors()
    return t
end

function tile:update_colors()
    local h = self.height
    if h <= -3 then
        -- deep water
        self.top_col = 1   -- dark blue
        self.side_col = 0  -- black
        self.dark_col = 0  -- black
    elseif h <= -1 then
        -- shallow water
        self.top_col = 12  -- light blue
        self.side_col = 1  -- dark blue
        self.dark_col = 1  -- dark blue
    elseif h >= 24 then
        -- snow/peak
        self.top_col = 7
        self.side_col = 6
        self.dark_col = 5
    elseif h >= 16 then
        -- mountain/rock
        self.top_col = 6
        self.side_col = 5
        self.dark_col = 0
    elseif h >= 8 then
        -- dirt/hill
        self.top_col = 4
        self.side_col = 2
        self.dark_col = 0
    elseif h >= 2 then
        -- grass hill
        self.top_col = 11
        self.side_col = 3
        self.dark_col = 1
    else
        -- flat grass (0-1)
        self.top_col = 3
        self.side_col = 1
        self.dark_col = 0
    end
end

function tile:get_screen_pos()
    local z = max(0, self.height)
    return cam_offset_x + self.base_sx, 
           cam_offset_y + self.base_sy - z * block_h
end

function tile:is_visible()
    local sx, sy = self:get_screen_pos()
    return sx > -tile_w-4 and sx < 132 + tile_w/2 and 
        sy > -tile_h*8 and sy < 132
end

-- SHIP CLASS
----------------------
ship = {}
ship.__index = ship

function ship.new(start_x, start_y)
    return setmetatable({
        x = start_x or 12,
        y = start_y or 12,
        vx = 0,
        vy = 0,
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
        max_climb = 3,  -- increased from 1 to 3 to handle smoother terrain
    }, ship)
end

function ship:get_terrain_height_at(x, y)
    local gx, gy = flr(x), flr(y)
    if gx >= 1 and gx <= grid_width and gy >= 1 and gy <= grid_height then
        return max(0, tiles[gy][gx].height)
    end
    return 0
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
    
    self.x = mid(1, self.x, grid_width)
    self.y = mid(1, self.y, grid_height)
    
    local current_terrain = self:get_terrain_height_at(old_x, old_y)
    local new_terrain = self:get_terrain_height_at(self.x, self.y)
    local height_diff = new_terrain - current_terrain
    
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
        elseif can_move_y and not can_move_x then
            self.x = old_x
            new_terrain = terrain_y
        else
            self.x = old_x
            self.y = old_y
            self.vx *= -0.2
            self.vy *= -0.2
            new_terrain = current_terrain
        end
    end
    
    local target_altitude = new_terrain + self.hover_height
    
    if self.current_altitude > target_altitude then
        self.current_altitude -= self.gravity
        if self.current_altitude < target_altitude then
            self.current_altitude = target_altitude
        end
    elseif self.current_altitude < target_altitude then
        self.current_altitude = target_altitude
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
    
    local nose_length = self.size
    local tail_length = self.size * 0.5
    local half_width = self.size * 0.4
    
    local points = {}
    
    local fx = sx + cos(self.angle) * nose_length
    local fy = sy + sin(self.angle) * nose_length * 0.5
    add(points, {fx, fy})
    
    local perp_angle = self.angle + 0.25
    
    local base_x = sx - cos(self.angle) * tail_length
    local base_y = sy - sin(self.angle) * tail_length * 0.5
    local blx = base_x - cos(perp_angle) * half_width
    local bly = base_y - sin(perp_angle) * half_width * 0.5
    add(points, {blx, bly})
    
    local brx = base_x + cos(perp_angle) * half_width
    local bry = base_y + sin(perp_angle) * half_width * 0.5
    add(points, {brx, bry})
    
    local terrain_height = self:get_terrain_height_at(self.x, self.y)
    local shadow_y = cam_offset_y + (self.x + self.y) * tile_h/2 - terrain_height * block_h
    for i=1,3 do
        local j = i % 3 + 1
        line(points[i][1], shadow_y, points[j][1], shadow_y, self.shadow_col)
    end
    
    local miny = min(points[1][2], points[2][2], points[3][2])
    local maxy = max(points[1][2], points[2][2], points[3][2])
    for y=miny,maxy do
        local minx, maxx = 128, -1
        for i=1,3 do
            local j = i % 3 + 1
            local y1, y2 = points[i][2], points[j][2]
            if (y1 <= y and y <= y2) or (y2 <= y and y <= y1) then
                if y1 ~= y2 then
                    local x = points[i][1] + (points[j][1] - points[i][1]) * (y - y1) / (y2 - y1)
                    minx = min(minx, x)
                    maxx = max(maxx, x)
                end
            end
        end
        if minx <= maxx then
            line(minx, y, maxx, y, self.body_col)
        end
    end
    
    for i=1,3 do
        local j = i % 3 + 1
        line(points[i][1], points[i][2], points[j][1], points[j][2], self.outline_col)
    end
    
    circfill(points[1][1], points[1][2], 1, 8)
    
    local hover_offset = sin(t * 3) * 0.5
    pset(points[2][1], points[2][2] + hover_offset + 1, 8)
    pset(points[3][1], points[3][2] + hover_offset + 1, 8)
end

function ship:get_speed()
    return sqrt(self.vx * self.vx + self.vy * self.vy)
end

-- TERRAIN GENERATION
----------------------
function generate_terrain_from_menu()
    local scale = menu_options[2].values[menu_options[2].current]
    local water_level = menu_options[3].values[menu_options[3].current]
    local mountain_level = menu_options[4].current
    
    local perm = generate_permutation(current_seed)
    
    for y = 1, grid_height do
        for x = 1, grid_width do
            local nx = x / scale
            local ny = y / scale
            
            local height = 0
            local amplitude = 1
            local frequency = 1
            local max_value = 0
            
            for octave = 1, 4 do
                height = height + perlin2d(nx * frequency, ny * frequency, perm) * amplitude
                max_value = max_value + amplitude
                amplitude = amplitude * 0.5
                frequency = frequency * 2
            end
            
            height = height / max_value
            
            -- add some ridged noise for mountains
            if mountain_level >= 4 then
                local ridge = abs(perlin2d(nx * 2, ny * 2, perm))
                ridge = 1 - ridge
                ridge = ridge * ridge
                height = height * 0.7 + ridge * 0.3
            end
            
            -- expanded range 0-32
            local height_range = ({8, 12, 16, 24, 32})[mountain_level]
            height = flr(height * height_range + height_range/2)
            
            -- apply water level and create depth
            if height <= water_level then
                -- create water depth based on how far below water level
                local depth = water_level - height
                if depth >= 3 then
                    height = -3  -- deep water
                else
                    height = -1  -- shallow water
                end
            end
            
            tiles[y][x].height = height
            tiles[y][x]:update_colors()
        end
    end
    
    -- smooth water edges (make shores shallow)
    for y = 2, grid_height - 1 do
        for x = 2, grid_width - 1 do
            if tiles[y][x].height <= -1 then
                -- check if any neighbor is land
                local near_land = false
                for dy = -1, 1 do
                    for dx = -1, 1 do
                        if dy ~= 0 or dx ~= 0 then
                            local ny, nx = y + dy, x + dx
                            if tiles[ny][nx].height >= 0 then
                                near_land = true
                            end
                        end
                    end
                end
                -- if near land and currently deep, make it shallow
                if near_land and tiles[y][x].height <= -3 then
                    tiles[y][x].height = -1
                    tiles[y][x]:update_colors()
                end
            end
        end
    end
end

-- CAMERA FUNCTIONS
----------------------
function update_visible_tiles()
    visible_tiles = {}

    local hw = tile_w/2
    local hh = tile_h/2

    local sx_min = -tile_w-4 - cam_offset_x
    local sx_max = 132 + tile_w/2 - cam_offset_x
    local sy_min = -tile_h*8 - cam_offset_y - 16
    local sy_max = 132 - cam_offset_y + 16

    local u_min = sx_min / hw
    local u_max = sx_max / hw
    local v_min = sy_min / hh
    local v_max = sy_max / hh

    local x_min = flr((u_min + v_min)/2) - 2
    local x_max = ceil((u_max + v_max)/2) + 2
    local y_min = flr((v_min - u_max)/2) - 2
    local y_max = ceil((v_max - u_min)/2) + 2

    x_min = clamp(x_min, 1, grid_width)
    x_max = clamp(x_max, 1, grid_width)
    y_min = clamp(y_min, 1, grid_height)
    y_max = clamp(y_max, 1, grid_height)

    for y=y_min,y_max do
        for x=x_min,x_max do
            local tile = tiles[y][x]
            if tile:is_visible() then
                add(visible_tiles, tile)
            end
        end
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
    ship:update()
    cam_target_x, cam_target_y = ship:get_camera_target()
    
    -- smooth camera movement
    cam_offset_x += (cam_target_x - cam_offset_x) * 0.15
    cam_offset_y += (cam_target_y - cam_offset_y) * 0.15
    
    -- update visible tiles list
    update_visible_tiles()
    
    t += 0.02
end

function _draw()
    if game_state == "menu" then
        draw_menu()
    elseif game_state == "game" then
        draw_game()
    end
end

function draw_game()
    cls(1)
    
    -- only draw visible tiles
    for tile in all(visible_tiles) do
        if tile.height <= -1 then
            draw_water_tile(tile)
        else
            draw_tile(tile)
        end
    end
    
    -- draw ship
    ship:draw()
    
    -- draw ui
    draw_ui()
end

-- DRAWING FUNCTIONS
----------------------
function draw_tile(tile)
    local sx, sy = tile:get_screen_pos()
    local h = tile.height
    
    if h > 0 then
        local h_pixels = block_h * h
        for i=0,h_pixels do
            line(sx - tile_w/2, sy + i, sx, sy + tile_h/2 + i, tile.side_col)
        end
        line(sx - tile_w/2, sy, sx - tile_w/2, sy + h_pixels, tile.dark_col)
        
        for i=0,h_pixels do
            line(sx + tile_w/2, sy + i, sx, sy + tile_h/2 + i, tile.dark_col)
        end
        line(sx + tile_w/2, sy, sx + tile_w/2, sy + h_pixels, tile.dark_col)
    end
    
    local hw = tile_w/2
    local hh = tile_h/2
    for dy=-hh,hh do
        local width = hw * (1 - abs(dy)/hh)
        line(sx - width, sy + dy, sx + width, sy + dy, tile.top_col)
    end
    
    draw_iso_outline(sx, sy, tile_w, tile_h, tile.top_col)
end

function draw_water_tile(tile)
    local sx, sy = tile:get_screen_pos()
    sy = sy + block_h

    -- animated water with different wave patterns for deep/shallow
    local wave_speed = tile.height <= -3 and 2 or 3  -- deep water waves slower
    local wave_amp = tile.height <= -3 and 0.5 or 1  -- deep water has smaller waves
    local wave = sin(t * wave_speed + sx/30 + sy/30) * wave_amp
    
    -- use appropriate water color
    local water_col = tile.top_col

    local hw = tile_w/2
    local hh = tile_h/2
    for dy=-hh,hh do
        local width = hw * (1 - abs(dy)/hh)
        line(sx - width, sy + dy + wave, sx + width, sy + dy + wave, water_col)
    end
end

function draw_iso_outline(x, y, w, h, col)
    local hw, hh = w/2, h/2
    line(x - hw, y, x, y - hh, col)
    line(x, y - hh, x + hw, y, col)
    line(x + hw, y, x, y + hh, col)
    line(x, y + hh, x - hw, y, col)
end

function draw_ui()
    -- simple HUD
    rectfill(0, 120, 127, 127, 0)
    print("spd:"..tostr(ship:get_speed(), true, 2), 2, 121, 7)
    print("pos:["..tostr(ship.x, true, 1)..","..tostr(ship.y, true, 1).."]", 40, 121, 7)
    print("🅾️+❎:menu", 88, 121, 5)
end