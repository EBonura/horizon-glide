pico-8 cartridge // http://www.pico-8.com
version 41
__lua__
-- isometric tactics grid demo
-- optimized with tile class
function ceil(x) return -flr(-x) end
function clamp(v, lo, hi) return mid(v, lo, hi) end

function _init()
    -- grid dimensions
    grid_width = 64
    grid_height = 64
    
    -- isometric tile dimensions
    tile_w = 24  -- width of tile in iso view
    tile_h = 12  -- height of tile in iso view  
    block_h = 4  -- height of a single block
    
    -- camera offset for smooth movement
    cam_offset_x = 0
    cam_offset_y = 0
    cam_target_x = 0
    cam_target_y = 0
    
    -- control modes
    modes = {"move", "height", "paint", "ship"}
    current_mode = 1
    
    -- create tile objects
    tiles = {}
    for y=1,grid_height do
        tiles[y] = {}
        for x=1,grid_width do
            tiles[y][x] = tile.new(x, y, 0)
        end
    end
    
    -- generate terrain
    generate_terrain()
    
    -- cursor position
    cursor_x = 12
    cursor_y = 12
    
    -- create ship
    ship = ship.new(12, 12)
    -- Initialize ship altitude at spawn position
    ship.current_altitude = ship:get_terrain_height_at(ship.x, ship.y) + ship.hover_height
    
    -- initialize camera
    update_camera_target()
    cam_offset_x = cam_target_x
    cam_offset_y = cam_target_y
    
    -- visible tiles cache
    visible_tiles = {}
    
    -- animation timer
    t = 0
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
        -- precalculated screen position (at height 0)
        base_sx = (x - y) * tile_w/2,
        base_sy = (x + y) * tile_h/2,
        -- colors (will be updated when height changes)
        top_col = 11,
        side_col = 3,
        dark_col = 1,
    }, tile)
    t:update_colors()  -- ADD THIS LINE
    return t
end

function tile:set_height(h)
    if self.height ~= h then
        self.height = h
        self:update_colors()
    end
end

function tile:update_colors()
    local h = self.height
    if h == -1 then
        -- water
        self.top_col = 12
        self.side_col = 1
        self.dark_col = 1
    elseif h >= 12 then
        -- snow/peak
        self.top_col = 7
        self.side_col = 6
        self.dark_col = 5
    elseif h >= 8 then
        -- mountain/rock
        self.top_col = 6
        self.side_col = 5
        self.dark_col = 0
    elseif h >= 4 then
        -- dirt/hill
        self.top_col = 4
        self.side_col = 2
        self.dark_col = 0
    elseif h >= 1 then
        -- grass hill
        self.top_col = 11
        self.side_col = 3
        self.dark_col = 1
    else
        -- flat grass
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
        current_altitude = 0,  -- actual altitude above terrain
        angle = 0,
        accel = 0.1,
        friction = 0.85,
        max_speed = 0.5,
        size = 10,
        body_col = 12,
        outline_col = 7,
        shadow_col = 1,
        gravity = 0.2,  -- how fast we fall
        max_climb = 1,  -- maximum height difference we can climb
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
    -- Store old position for collision rollback
    local old_x, old_y = self.x, self.y
    
    -- Convert arrow keys from screen space to grid space
    local input_x = 0
    local input_y = 0
    
    if btn(➡️) then -- screen right
        input_x += self.accel
        input_y -= self.accel
    end
    if btn(⬅️) then -- screen left
        input_x -= self.accel
        input_y += self.accel
    end
    if btn(⬇️) then -- screen down
        input_x += self.accel
        input_y += self.accel
    end
    if btn(⬆️) then -- screen up
        input_x -= self.accel
        input_y -= self.accel
    end
    
    -- Apply the converted input to velocity
    self.vx += input_x * 0.707
    self.vy += input_y * 0.707
    
    -- apply friction
    self.vx *= self.friction
    self.vy *= self.friction
    
    -- clamp to max speed
    local speed = sqrt(self.vx * self.vx + self.vy * self.vy)
    if speed > self.max_speed then
        self.vx = (self.vx / speed) * self.max_speed
        self.vy = (self.vy / speed) * self.max_speed
    end
    
    -- update position
    self.x += self.vx
    self.y += self.vy
    
    -- keep ship in bounds
    self.x = mid(1, self.x, grid_width)
    self.y = mid(1, self.y, grid_height)
    
    -- Check height difference for collision
    local current_terrain = self:get_terrain_height_at(old_x, old_y)
    local new_terrain = self:get_terrain_height_at(self.x, self.y)
    local height_diff = new_terrain - current_terrain
    
    -- If trying to climb too high, block movement
    if height_diff > self.max_climb then
        -- Try sliding along the wall
        local can_move_x = false
        local can_move_y = false
        
        -- Test X movement only
        local terrain_x = self:get_terrain_height_at(self.x, old_y)
        if terrain_x - current_terrain <= self.max_climb then
            can_move_x = true
        end
        
        -- Test Y movement only
        local terrain_y = self:get_terrain_height_at(old_x, self.y)
        if terrain_y - current_terrain <= self.max_climb then
            can_move_y = true
        end
        
        -- Apply sliding movement
        if can_move_x and not can_move_y then
            self.y = old_y
            new_terrain = terrain_x
        elseif can_move_y and not can_move_x then
            self.x = old_x
            new_terrain = terrain_y
        else
            -- Can't move at all, full collision
            self.x = old_x
            self.y = old_y
            self.vx *= -0.2  -- small bounce
            self.vy *= -0.2
            new_terrain = current_terrain
        end
    end
    
    -- Update altitude with gravity
    local target_altitude = new_terrain + self.hover_height
    
    if self.current_altitude > target_altitude then
        -- Fall with gravity
        self.current_altitude -= self.gravity
        if self.current_altitude < target_altitude then
            self.current_altitude = target_altitude
        end
    elseif self.current_altitude < target_altitude then
        -- Snap up when terrain rises (we can climb)
        self.current_altitude = target_altitude
    end
    
    -- update angle based on velocity
    if abs(self.vx) > 0.01 or abs(self.vy) > 0.01 then
        local screen_vx = (self.vx - self.vy)
        local screen_vy = (self.vx + self.vy) * 0.5
        self.angle = atan2(screen_vx, screen_vy)
    end
end

function ship:get_screen_pos()
    local sx = cam_offset_x + (self.x - self.y) * tile_w/2
    local sy = cam_offset_y + (self.x + self.y) * tile_h/2
    
    -- Use current altitude instead of calculating from terrain
    sy -= self.current_altitude * block_h
    
    return sx, sy
end

function ship:get_camera_target()
    local sx = (self.x - self.y) * tile_w/2
    local sy = (self.x + self.y) * tile_h/2
    
    -- Use current altitude for camera
    sy -= self.current_altitude * block_h
    
    return 64 - sx, 64 - sy
end

function ship:draw()
    local sx, sy = self:get_screen_pos()
    
    -- create proper isosceles triangle
    local nose_length = self.size
    local tail_length = self.size * 0.5
    local half_width = self.size * 0.4
    
    local points = {}
    
    -- front point (nose)
    local fx = sx + cos(self.angle) * nose_length
    local fy = sy + sin(self.angle) * nose_length * 0.5
    add(points, {fx, fy})
    
    -- calculate perpendicular angle for the base points
    local perp_angle = self.angle + 0.25
    
    -- back left point
    local base_x = sx - cos(self.angle) * tail_length
    local base_y = sy - sin(self.angle) * tail_length * 0.5
    local blx = base_x - cos(perp_angle) * half_width
    local bly = base_y - sin(perp_angle) * half_width * 0.5
    add(points, {blx, bly})
    
    -- back right point
    local brx = base_x + cos(perp_angle) * half_width
    local bry = base_y + sin(perp_angle) * half_width * 0.5
    add(points, {brx, bry})
    
    -- draw shadow on ground (at terrain level, not at ship level)
    local terrain_height = self:get_terrain_height_at(self.x, self.y)
    local shadow_y = cam_offset_y + (self.x + self.y) * tile_h/2 - terrain_height * block_h
    for i=1,3 do
        local j = i % 3 + 1
        line(points[i][1], shadow_y, points[j][1], shadow_y, self.shadow_col)
    end
    
    -- fill triangle
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
    
    -- draw ship outline
    for i=1,3 do
        local j = i % 3 + 1
        line(points[i][1], points[i][2], points[j][1], points[j][2], self.outline_col)
    end
    
    -- cockpit dot
    circfill(points[1][1], points[1][2], 1, 8)
    
    -- hovering effect (engines)
    local hover_offset = sin(t * 3) * 0.5
    pset(points[2][1], points[2][2] + hover_offset + 1, 8)
    pset(points[3][1], points[3][2] + hover_offset + 1, 8)
end

function ship:get_speed()
    return sqrt(self.vx * self.vx + self.vy * self.vy)
end

-- TERRAIN GENERATION
----------------------
function generate_terrain()
    -- create terrain
    for y=1,grid_height do
        for x=1,grid_width do
            local height = 0
            
            -- hill 1
            local dist1 = abs(x - 8) + abs(y - 8)
            if dist1 < 6 then
                height = max(height, (6 - dist1) * 2)
            end
            
            -- hill 2
            local dist2 = abs(x - 18) + abs(y - 12)
            if dist2 < 5 then
                height = max(height, (5 - dist2) * 2)
            end
            
            -- hill 3
            local dist3 = abs(x - 6) + abs(y - 18)
            if dist3 < 4 then
                height = max(height, (4 - dist3) * 2)
            end
            
            -- random variation
            if rnd(1) > 0.6 then
                height = min(height + flr(rnd(3)), 15)
            end
            
            tiles[y][x]:set_height(height)
        end
    end
    
    -- river
    for i=1,grid_width do
        local river_y = 14 + flr(sin(i/3) * 2)
        if river_y > 0 and river_y <= grid_height then
            tiles[river_y][i]:set_height(-1)
            if river_y > 1 then 
                tiles[river_y-1][i]:set_height(min(tiles[river_y-1][i].height, 0))
            end
            if river_y < grid_height then 
                tiles[river_y+1][i]:set_height(min(tiles[river_y+1][i].height, 0))
            end
        end
    end
    
    -- lake
    for y=4,7 do
        for x=16,20 do
            if abs(x-18) + abs(y-5.5) < 3.5 then
                tiles[y][x]:set_height(-1)
            end
        end
    end
end

-- CAMERA & MODE FUNCTIONS
----------------------
function update_camera_target()
    local tile = tiles[cursor_y][cursor_x]
    local sx, sy = tile:get_screen_pos()
    cam_target_x = 64 - tile.base_sx
    cam_target_y = 64 - tile.base_sy + max(0, tile.height) * block_h
end

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

function handle_move_mode()
    if btnp(⬅️) and cursor_x > 1 then
        cursor_x -= 1
    end
    if btnp(➡️) and cursor_x < grid_width then
        cursor_x += 1
    end
    if btnp(⬆️) and cursor_y > 1 then
        cursor_y -= 1
    end
    if btnp(⬇️) and cursor_y < grid_height then
        cursor_y += 1
    end
    
    update_camera_target()
end

function handle_height_mode()
    local tile = tiles[cursor_y][cursor_x]
    
    if btnp(⬆️) then
        tile:set_height(min(tile.height + 1, 15))
    end
    if btnp(⬇️) then
        tile:set_height(max(tile.height - 1, -1))
    end
    if btnp(➡️) then
        tile:set_height(min(tile.height + 4, 15))
    end
    if btnp(⬅️) then
        tile:set_height(max(tile.height - 4, -1))
    end
    update_camera_target()
end

function handle_paint_mode()
    local paint_height = tiles[cursor_y][cursor_x].height
    
    if btn(🅾️) then
        if btnp(⬅️) and cursor_x > 1 then
            cursor_x -= 1
            tiles[cursor_y][cursor_x]:set_height(paint_height)
        end
        if btnp(➡️) and cursor_x < grid_width then
            cursor_x += 1
            tiles[cursor_y][cursor_x]:set_height(paint_height)
        end
        if btnp(⬆️) and cursor_y > 1 then
            cursor_y -= 1
            tiles[cursor_y][cursor_x]:set_height(paint_height)
        end
        if btnp(⬇️) and cursor_y < grid_height then
            cursor_y += 1
            tiles[cursor_y][cursor_x]:set_height(paint_height)
        end
        update_camera_target()
    else
        handle_move_mode()
    end
end

function handle_ship_mode()
    ship:update()
    cam_target_x, cam_target_y = ship:get_camera_target()
end

-- MAIN UPDATE & DRAW
----------------------
function _update()
    -- cycle modes
    if btnp(❎) then
        current_mode += 1
        if current_mode > #modes then
            current_mode = 1
        end
    end
    
    -- handle current mode
    if modes[current_mode] == "move" then
        handle_move_mode()
    elseif modes[current_mode] == "height" then
        handle_height_mode()
    elseif modes[current_mode] == "paint" then
        handle_paint_mode()
    elseif modes[current_mode] == "ship" then
        handle_ship_mode()
    end
    
    -- smooth camera movement
    cam_offset_x += (cam_target_x - cam_offset_x) * 0.15
    cam_offset_y += (cam_target_y - cam_offset_y) * 0.15
    
    -- update visible tiles list
    update_visible_tiles()
    
    t += 0.02
end

function _draw()
    cls(1)
    
    -- only draw visible tiles
    for tile in all(visible_tiles) do
        if tile.height == -1 then
            draw_water_tile(tile)
        else
            draw_tile(tile)
        end
    end
    
    -- draw cursor (only when not in ship mode)
    if modes[current_mode] ~= "ship" then
        draw_cursor()
    end
    
    -- draw ship
    if modes[current_mode] == "ship" then
        ship:draw()
    end
    
    -- draw ui
    draw_ui()
    -- debug output
    printh("mem: "..tostr(stat(0)).." | cpu: "..tostr(stat(1)).." | fps: "..tostr(stat(7)))
end

-- DRAWING FUNCTIONS
----------------------
function draw_tile(tile)
    local sx, sy = tile:get_screen_pos()
    local h = tile.height
    
    -- only draw sides if has height
    if h > 0 then
        -- left face
        local h_pixels = block_h * h
        for i=0,h_pixels do
            line(sx - tile_w/2, sy + i, sx, sy + tile_h/2 + i, tile.side_col)
        end
        line(sx - tile_w/2, sy, sx - tile_w/2, sy + h_pixels, tile.dark_col)
        
        -- right face
        for i=0,h_pixels do
            line(sx + tile_w/2, sy + i, sx, sy + tile_h/2 + i, tile.dark_col)
        end
        line(sx + tile_w/2, sy, sx + tile_w/2, sy + h_pixels, tile.dark_col)
    end
    
    -- top face
    local hw = tile_w/2
    local hh = tile_h/2
    for dy=-hh,hh do
        local width = hw * (1 - abs(dy)/hh)
        line(sx - width, sy + dy, sx + width, sy + dy, tile.top_col)
    end
    
    -- grid outline
    draw_iso_outline(sx, sy, tile_w, tile_h, tile.top_col)
end

function draw_water_tile(tile)
    local sx, sy = tile:get_screen_pos()
    sy = sy + block_h

    -- animated water
    local wave = sin(t + sx/30 + sy/30) * 1
    local water_col = 12

    -- draw water surface
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

function draw_cursor()
    local tile = tiles[cursor_y][cursor_x]
    local sx, sy = tile:get_screen_pos()
    
    local pulse = sin(t) * 2
    
    -- mode colors
    local col = 7
    if modes[current_mode] == "move" then
        col = 11
    elseif modes[current_mode] == "height" then
        col = 12
    elseif modes[current_mode] == "paint" then
        col = 8
    end
    
    if (flr(t*4) % 2 == 0) col = 10
    
    -- cursor outline
    for i=-1,1 do
        draw_iso_outline(sx, sy - pulse + i, tile_w + 2, tile_h + 1, col)
    end
    
    -- corner markers
    local corners = {
        {-tile_w/2 - 2, 0},
        {0, -tile_h/2 - 1},
        {tile_w/2 + 2, 0},
        {0, tile_h/2 + 1}
    }
    
    for c in all(corners) do
        circfill(sx + c[1], sy + c[2] - pulse, 1, 8)
        pset(sx + c[1], sy + c[2] - pulse, col)
    end
end

function draw_ui()
    rectfill(0, 0, 127, 14, 0)
    rect(0, 0, 127, 14, 5)
    
    local mode_col = ({move=11, height=12, paint=8, ship=10})[modes[current_mode]]
    print("mode: "..modes[current_mode], 2, 2, mode_col)
    
    local control_text = ({
        move="arrows:move",
        height="⬆️⬇️:+1 ⬅️➡️:+4",
        paint="🅾️+arrows:paint",
        ship="arrows:fly"
    })[modes[current_mode]]
    print(control_text, 2, 8, 7)
    
    if modes[current_mode] == "ship" then
        print("spd:"..tostr(ship:get_speed(), true, 2), 80, 2, 7)
        print("["..tostr(ship.x, true, 1)..","..tostr(ship.y, true, 1).."]", 80, 8, 7)
    else
        local h = tiles[cursor_y][cursor_x].height
        local height_text = h == -1 and "water" or "h:"..h
        print(height_text, 80, 2, 7)
        print("["..cursor_x..","..cursor_y.."]", 80, 8, 7)
    end
end
