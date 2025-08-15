pico-8 cartridge // http://www.pico-8.com
version 41
__lua__
-- HORIZON GLIDE
-- An infinite isometric racing game

-- Helper functions
function ceil(x) return -flr(-x) end
function clamp(v, lo, hi) return mid(v, lo, hi) end
function dist_trig(dx, dy) local ang = atan2(dx, dy) return dx * cos(ang) + dy * sin(ang) end

-- Triangle drawing function
function draw_triangle(x1, y1, x2, y2, x3, y3, col)
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
    
    -- Early exit for degenerate triangles
    if y1 == y3 then return end
    
    -- Pre-calculate inverse heights to avoid division in loops
    local inv_h12 = (y2 > y1) and 1 / (y2 - y1) or 0
    local inv_h13 = 1 / (y3 - y1)  -- This can't be zero due to early exit
    local inv_h23 = (y3 > y2) and 1 / (y3 - y2) or 0
    
    -- Pre-calculate deltas
    local dx12, dx13, dx23  = x2 - x1, x3 - x1, x3 - x2
    
    -- Fill triangle using horizontal lines
    for y = y1, y3 do
        local xa, xb
        
        if y <= y2 then
            -- Top half of triangle
            local t = (y - y1)
            xa = (y2 > y1) and x1 + dx12 * t * inv_h12 or x1
            xb = x1 + dx13 * t * inv_h13
        else
            -- Bottom half of triangle
            local t2, t1 = y - y2, y - y1
            xa = (y3 > y2) and x2 + dx23 * t2 * inv_h23 or x2
            xb = x1 + dx13 * t1 * inv_h13
        end
        
        -- Draw horizontal line
        if xa > xb then xa, xb = xb, xa end
        line(xa, y, xb, y, col)
    end
end

-- Game States
game_state = "menu"  -- "startup", "menu", "game"

-- Startup Variables
startup_phase = "intro"  -- "intro", "title", "menu"
startup_timer = 0
startup_ship = nil
startup_view_range = 2
title_x1 = -40  -- HORIZON position
title_x2 = 168  -- GLIDE position
preset_panels = {}
start_panel = nil
current_preset = 1

-- Preset Configurations
presets = {
    {name="island", scale=20, water=2, min=-4, max=12, sharp=1},
    {name="hills", scale=16, water=-2, min=0, max=16, sharp=2},
    {name="mountains", scale=12, water=-3, min=4, max=28, sharp=4},
    {name="custom", scale=16, water=-2, min=-4, max=20, sharp=2}
}

-- Core Game Variables
player_ship = nil
player_score = 0
display_score = 0
floating_texts = {}
particles = {}

-- Camera Variables
cam_offset_x = 0
cam_offset_y = 0
cam_target_x = 0
cam_target_y = 0

-- Tile System Constants
VIEW_RANGE = 7
tile_w = 24
tile_h = 12
block_h = 2

-- Terrain Generation
height_cache = {}
last_cache_cleanup = 0
terrain_perm = nil
current_seed = 0

-- Menu Variables
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
preview_tiles = {}
preview_dirty = true
menu_panels = {}

-- MAIN PICO-8 FUNCTIONS
function _init()
    game_state = "startup"
    startup_phase = "intro"
    startup_timer = 0
    startup_view_range = 2
    title_x1 = -40
    title_x2 = 168
    
    -- Set a nice default seed for startup
    current_seed = 1337
    terrain_perm = generate_permutation(current_seed)
    
    -- Apply island preset for startup visual
    local preset = presets[1]
    menu_options[1].current = 2  -- scale index for 20
    menu_options[2].current = 7  -- water index for 2
    menu_options[3].current = 1  -- min index for -4
    menu_options[4].current = 2  -- max index for 12
    menu_options[5].current = 1  -- sharp index for smooth
    
    -- Initialize view range for startup
    VIEW_RANGE = startup_view_range
    
    -- Clear everything
    particles = {}
    height_cache = {}
    tile_manager:init()
    
    -- Create autonomous ship
    startup_ship = ship.new(0, 0)
    startup_ship.is_hovering = true
    
    -- Initialize tiles around ship
    tile_manager:update_player_position(0, 0)
    tile_manager:update_tiles()
    
    -- Set ship altitude
    local terrain_h = startup_ship:get_terrain_height_at(0, 0)
    startup_ship.current_altitude = terrain_h + startup_ship.hover_height
    
    -- Initialize camera
    cam_offset_x = 64
    cam_offset_y = 64
    
    -- Create preset panels (start below screen)
    preset_panels = {}
    local panel_width = 28
    local panel_spacing = 2
    local total_width = panel_width * 4 + panel_spacing * 3
    local start_x = 64 - total_width / 2
    
    for i, preset in ipairs(presets) do
        local x = start_x + (i-1) * (panel_width + panel_spacing)
        local panel = panel.new(
            x, 140,  -- start below screen
            panel_width, 10,
            preset.name,
            {
                text_col = 6,
                selected_col = 11,
                border_style = "full",
                bg_col = 0,
                border_col = 5,
                text_align = "center",
                slide_speed = 0.15,
            }
        )
        add(preset_panels, panel)
    end
    
    -- Select first preset
    preset_panels[1].selected = true
    current_preset = 1
    
    -- Create start game panel
    start_panel = panel.new(
        48, 150,  -- start below screen
        32, 10,
        "start",
        {
            text_col = 7,
            border_style = "full",
            bg_col = 0,
            border_col = 11,
            text_align = "center",
            slide_speed = 0.15,
        }
    )
end

function _update()
    if game_state == "startup" then
        update_startup()
    elseif game_state == "menu" then
        update_menu()
    elseif game_state == "game" then
        update_game()
    end
end

function _draw()
    if game_state == "startup" then
        draw_startup()
    elseif game_state == "menu" then
        draw_menu()
    elseif game_state == "game" then
        draw_game()
    end
    -- performance monitoring
    printh("mem: "..tostr(stat(0)).." \t| cpu: "..tostr(stat(1)).." \t| fps: "..tostr(stat(7)))
end


-- STARTUP SCREEN FUNCTIONS
function update_startup()
    startup_timer += 1
    
    -- Update tile manager
    tile_manager:update_player_position(startup_ship.x, startup_ship.y)
    tile_manager:update_tiles()
    
    -- Update ship altitude
    local terrain_h = startup_ship:get_terrain_height_at(startup_ship.x, startup_ship.y)
    startup_ship.current_altitude = terrain_h + startup_ship.hover_height
    startup_ship.is_hovering = true
    
    -- Generate particles
    if startup_timer % 3 == 0 then
        local px = startup_ship.x + (rnd() - 0.5) * 0.1
        local py = startup_ship.y + (rnd() - 0.5) * 0.1
        local ship_z = -startup_ship.current_altitude * block_h
        add(particles, particle.new(px, py, ship_z, 0))
    end
    
    -- Update particles
    local new_particles = {}
    for p in all(particles) do
        if p:update() then
            add(new_particles, p)
        end
    end
    particles = new_particles
    
    -- Camera follows ship
    local sx = (startup_ship.x - startup_ship.y) * tile_w/2
    local sy = (startup_ship.x + startup_ship.y) * tile_h/2 - startup_ship.current_altitude * block_h
    cam_offset_x = 64 - sx
    cam_offset_y = 64 - sy
    
    -- Phase transitions
    if startup_phase == "intro" then
        if startup_timer > 60 then  -- 2 seconds
            startup_phase = "title"
        end
    elseif startup_phase == "title" then
        -- Animate view range expansion
        if startup_view_range < 7 then
            startup_view_range += 0.1
            VIEW_RANGE = flr(startup_view_range)
            tile_manager:update_tiles()
        end
        
        -- Slide title in
        if title_x1 < 20 then
            title_x1 += 3
        end
        if title_x2 > 68 then
            title_x2 -= 3
        end
        
        -- After title is in place, show menu
        if startup_timer > 150 and startup_phase == "title" then
            startup_phase = "menu"
        end
    elseif startup_phase == "menu" then
        -- Slide panels up
        for i, panel in ipairs(preset_panels) do
            panel:set_position(panel.x, 95, false)
        end
        start_panel:set_position(48, 108, false)
        
        -- Update panels
        for panel in all(preset_panels) do
            panel:update()
        end
        start_panel:update()
        
        -- Handle input
        if btnp(⬅️) then
            preset_panels[current_preset].selected = false
            current_preset = max(1, current_preset - 1)
            preset_panels[current_preset].selected = true
        end
        if btnp(➡️) then
            preset_panels[current_preset].selected = false
            current_preset = min(4, current_preset + 1)
            preset_panels[current_preset].selected = true
        end
        
        -- Start game
        if btnp(❎) or btnp(🅾️) then
            -- Apply selected preset
            local preset = presets[current_preset]
            if current_preset < 4 then  -- not custom
                for i, v in ipairs(menu_options[1].values) do
                    if v == preset.scale then menu_options[1].current = i end
                end
                for i, v in ipairs(menu_options[2].values) do
                    if v == preset.water then menu_options[2].current = i end
                end
                for i, v in ipairs(menu_options[3].values) do
                    if v == preset.min then menu_options[3].current = i end
                end
                for i, v in ipairs(menu_options[4].values) do
                    if v == preset.max then menu_options[4].current = i end
                end
                menu_options[5].current = preset.sharp
            end
            
            -- Start the game
            VIEW_RANGE = 7  -- reset to normal
            init_game()
        end
    end
end

function draw_startup()
    cls(1)
    
    -- Draw world
    for tile in all(tile_manager.tile_list) do
        tile:draw()
    end
    
    -- Draw particles
    for p in all(particles) do
        p:draw(cam_offset_x, cam_offset_y)
    end
    
    -- Draw ship
    startup_ship:draw()
    
    -- Draw title (using print for now since we don't have sprites)
    if startup_phase != "intro" then
        print("horizon", title_x1, 20, 7)
        print("glide", title_x2, 20, 7)
    end
    
    -- Draw menu panels
    if startup_phase == "menu" then
        for panel in all(preset_panels) do
            panel:draw()
        end
        start_panel:draw()
    end
end

-- MENU FUNCTIONS
function init_menu()
    game_state = "menu"
    menu_cursor = 1
    preview_dirty = true
    
    -- create panels for each menu option with new styling
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
        
        -- Create panel with custom options
        local panel_options = {
            text_col = 6,
            selected_col = 11,
            border_style = "corners",
            bg_col = 0,
            border_col = 5,
        }
        
        -- Action buttons get different styling
        if option.is_action then
            panel_options.text_col = 7
            panel_options.border_col = option.name == "start game" and 11 or 5
        end
        
        menu_panels[i] = panel.new(4, y, 64, 8, text, panel_options)
    end
    
    -- select first panel
    menu_panels[1].selected = true
end

function update_menu()
    -- navigation
    if btnp(⬆️) then
        menu_panels[menu_cursor].selected = false
        menu_cursor -= 1
        if menu_cursor < 1 then menu_cursor = #menu_options end
        menu_panels[menu_cursor].selected = true
    end
    if btnp(⬇️) then
        menu_panels[menu_cursor].selected = false
        menu_cursor += 1
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
            option.current -= 1
            if option.current < 1 then option.current = #option.values end
            preview_dirty = true
            panel.text = option.name .. ": " .. tostr(option.values[option.current])
        end
        if btnp(➡️) then
            option.current += 1
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

function draw_menu()
    cls(1)
    
    if preview_dirty then
        generate_preview()
        preview_dirty = false
    end
    
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
end

function reset_terrain_state()
  terrain_perm = generate_permutation(current_seed) -- new seed/permutation
  height_cache = {}                                 -- drop old heights
  tile_manager:init()                               -- drop all tiles
end

-- GAME FUNCTIONS
function init_game()
    music(0)
    game_state = "game"

    -- full rebuild so tiles match the chosen preset/seed
    reset_terrain_state()

    -- scores/ui/etc...
    player_score, display_score = 0, 0
    floating_texts, particles = {}, {}

    -- ship & tiles
    game_manager = game_manager.new()
    player_ship = ship.new(0, 0)

    tile_manager:update_player_position(0, 0)
    tile_manager:update_tiles()

    -- make ship altitude match new terrain at its position
    player_ship.current_altitude =
        player_ship:get_terrain_height_at(player_ship.x, player_ship.y)
        + player_ship.hover_height

    -- camera
    cam_target_x, cam_target_y = player_ship:get_camera_target()
    cam_offset_x, cam_offset_y = cam_target_x, cam_target_y

    last_cache_cleanup = time()
end


function update_game()
    -- return to menu
    if btn(🅾️) and btn(❎) then
        init_menu()
        return
    end
    
    -- update game manager
    game_manager:update()
    
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
    
    -- Update floating texts
    local new_floats = {}
    for f in all(floating_texts) do
        if f:update() then
            add(new_floats, f)
        end
    end
    floating_texts = new_floats
    
    -- Animate display score towards actual score
    if display_score < player_score then
        local diff = player_score - display_score
        if diff < 10 then
            display_score = player_score  -- snap to target if close
        else
            display_score += ceil(diff * 0.1)  -- move 10% of the way
        end
    end
    
    -- cleanup cache every 2 seconds using time()
    local current_time = time()
    if current_time - last_cache_cleanup > 2 then
        tile_manager:cleanup_cache()
        last_cache_cleanup = current_time
    end
end

function draw_game()
    cls(1)
    
    -- 1. Draw world elements first
    -- Draw all tiles
    for tile in all(tile_manager.tile_list) do
        tile:draw()
    end
    
    -- 2. Draw particles (behind ship)
    for p in all(particles) do
        p:draw(cam_offset_x, cam_offset_y)
    end
    
    -- 3. Draw game events (circles, beacons, etc - but NOT their UI panels)
    if game_manager.state == "active" and game_manager.current_event then
        game_manager.current_event:draw()
    end
    
    -- 4. Draw ship
    player_ship:draw()
    
    -- 5. Draw floating texts (score popups)
    for f in all(floating_texts) do
        f:draw()
    end
    
    -- 6. Draw UI elements last (including all panels)
    draw_ui()
    
    -- 7. Draw all panels on top of everything
    for p in all(game_manager.active_panels) do
        p:draw()
    end
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
    
    -- Draw score on the right side
    local score_text = "score: " .. flr(display_score)
    print(score_text, 127 - #score_text * 4, 121, 10)  -- yellow color
end


-- FLOATING TEXT CLASS
floating_text = {}
floating_text.__index = floating_text

function floating_text.new(x, y, text, col)
    return setmetatable({
        x = x,
        y = y,
        text = text,
        col = col or 7,
        life = 60,
        vy = -1,
    }, floating_text)
end

function floating_text:update()
    self.y += self.vy
    self.vy *= 0.95  -- slow down over time
    self.life -= 1
    return self.life > 0
end

function floating_text:draw()
    -- Draw black background box
    local text_width = #self.text * 4
    local text_height = 5
    rectfill(self.x - text_width/2 - 1, self.y - 1, 
                self.x + text_width/2, self.y + text_height, 0)

    -- Draw white text
    print(self.text, self.x - text_width/2, self.y, 7)
end

-- PANEL CLASS
panel = {}
panel.__index = panel

function panel.new(x, y, w, h, text, options)
    options = options or {}
    return setmetatable({
        x = x,
        y = y,
        w = w,
        h = h,
        text = text,
        selected = false,
        expand = 0,
        bg_col = options.bg_col or 0,
        border_col = options.border_col or 5,
        text_col = options.text_col or 7,
        selected_col = options.selected_col or 11,
        border_style = options.border_style or "corners",
        border_width = options.border_width or 1,
        text_align = options.text_align or "left",
        text_padding = options.text_padding or 3,
        target_x = x,
        target_y = y,
        slide_speed = options.slide_speed or 0.2,
        pulse = options.pulse or false,
        pulse_amount = options.pulse_amount or 2,
        pulse_speed = options.pulse_speed or 4,
        shadow = options.shadow or false,
        shadow_col = options.shadow_col or 1,
        shadow_offset = options.shadow_offset or 1,
        icon = options.icon,
        icon_x = options.icon_x or 2,
        icon_y = options.icon_y or 2,
        life = options.life or -1,
    }, panel)
end

function panel:set_text(new_text)
    self.text = new_text
end

function panel:set_position(x, y, instant)
    if instant then
        self.x = x
        self.y = y
        self.target_x = x
        self.target_y = y
    else
        self.target_x = x
        self.target_y = y
    end
end

function panel:update()
    -- Smooth movement to target
    if self.x != self.target_x or self.y != self.target_y then
        self.x += (self.target_x - self.x) * self.slide_speed
        self.y += (self.target_y - self.y) * self.slide_speed
        
        -- Snap when close enough
        if abs(self.x - self.target_x) < 0.5 then self.x = self.target_x end
        if abs(self.y - self.target_y) < 0.5 then self.y = self.target_y end
    end

    -- Smooth expand/contract when selected
    if self.selected then
        self.expand = min(self.expand + 1, 3)
    else
        self.expand = max(self.expand - 1, 0)
    end
    
    -- Handle life countdown
    if self.life > 0 then
        self.life -= 1
        return self.life > 0  -- return false when life reaches 0
    elseif self.life == 0 then
        return false  -- panel should be removed
    end

    return true  -- panel still active (infinite life when life == -1)
end

function panel:draw()
    -- Calculate actual position with expansion and pulse
    local dx = self.x - self.expand
    local dy = self.y
    local dw = self.w + self.expand * 2
    local dh = self.h

    -- Apply pulse effect
    if self.pulse then
        local pulse_offset = sin(time() * self.pulse_speed) * self.pulse_amount
        dx -= pulse_offset / 2
        dy -= pulse_offset / 2
        dw += pulse_offset
        dh += pulse_offset
    end

    -- Draw shadow if enabled
    if self.shadow then
        rectfill(dx + self.shadow_offset, dy + self.shadow_offset, 
                dx + dw + self.shadow_offset, dy + dh + self.shadow_offset, 
                self.shadow_col)
    end

    -- Draw background
    rectfill(dx, dy, dx + dw, dy + dh, self.bg_col)

    -- Draw border based on style
    if self.border_style == "corners" then
        -- Original corner style
        rectfill(dx - 1, dy - 1, dx + 2, dy + dh + 1, self.border_col)
        rectfill(dx + dw - 2, dy - 1, dx + dw + 1, dy + dh + 1, self.border_col)
    elseif self.border_style == "full" then
        -- Full border
        for i = 0, self.border_width - 1 do
            rect(dx - i - 1, dy - i - 1, dx + dw + i, dy + dh + i, self.border_col)
        end
    end
    -- "none" style skips border drawing

    -- Draw icon if present
    if self.icon then
        self.icon(dx + self.icon_x, dy + self.icon_y)
    end

    -- Calculate text position based on alignment
    local text_x = dx + self.text_padding
    local text_y = dy + (dh - 5) / 2  -- center vertically (5 is text height)

    if self.text_align == "center" then
        text_x = dx + (dw - #self.text * 4) / 2
    elseif self.text_align == "right" then
        text_x = dx + dw - #self.text * 4 - self.text_padding
    end

    -- If there's an icon, offset text
    if self.icon then
        text_x += 8  -- assuming icon is about 8 pixels wide
    end

    -- Draw text
    local col = self.selected and self.selected_col or self.text_col
    print(self.text, text_x, text_y, col)
end

-- PARTICLE SYSTEM
particle = {}
particle.__index = particle

function particle.new(x, y, z, col)
    return setmetatable({
        x = x,
        y = y,
        z = z,
        vx = (rnd() - 0.5) * 0.05,
        vy = (rnd() - 0.5) * 0.05,
        vz = -rnd() * 0.3 - 0.2,
        life = 20 + rnd(10),
        max_life = 30,
        col = col,
        size = 1 + rnd(1)
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



-- GAME MANAGER
game_manager = {}
game_manager.__index = game_manager

function game_manager.new()
    return setmetatable({
        state = "idle",
        current_event = nil,
        idle_start_time = time(),
        idle_duration = 3,
        event_types = {"circles"},
        completion_panel = nil,
        active_panels = {},
    }, game_manager)
end

function game_manager:update()
    if self.state == "idle" then
        if time() - self.idle_start_time >= self.idle_duration then
            self:start_random_event()
        end
    elseif self.state == "active" then
        if self.current_event then
            self.current_event:update()
            if self.current_event:is_complete() then
                self:end_event(self.current_event.success)
            end
        end
    end
    
    local new_panels = {}
    for p in all(self.active_panels) do
        if p:update() then
            add(new_panels, p)
        end
    end
    self.active_panels = new_panels
end

function game_manager:add_panel(panel)
    add(self.active_panels, panel)
end

function game_manager:start_random_event()
    local event_type = self.event_types[flr(rnd(#self.event_types)) + 1]
    
    if event_type == "circles" then
        self.current_event = circle_event.new()
    end
    
    self.state = "active"
end

function game_manager:end_event(success)
    self.state = "idle"
    self.idle_start_time = time()
    
    local message = success and "EVENT COMPLETE!" or "EVENT FAILED!"
    local panel_col = success and 11 or 8
    
    local text_width = #message * 4 + 16
    local panel_x = 64 - text_width / 2
    local panel_y = 105
    
    self.completion_panel = panel.new(
        panel_x, panel_y + 10,
        text_width, 12,
        message,
        {
            text_col = panel_col,
            bg_col = 0,
            border_col = panel_col,
            border_style = "full",
            text_align = "center",
            shadow = true,
            pulse = success,
            pulse_amount = 1,
            pulse_speed = 8,
            life = 90,
        }
    )
    
    self.completion_panel:set_position(panel_x, panel_y, false)
    self:add_panel(self.completion_panel)
    
    if success then
        self:create_success_particles()
    end
    
    self.current_event = nil
end

function game_manager:create_success_particles()
    if self.completion_panel then
        local cx = self.completion_panel.x + self.completion_panel.w / 2
        local cy = self.completion_panel.y + self.completion_panel.h / 2
        
        for i = 1, 20 do
            local angle = rnd(1)
            local speed = 1 + rnd(2)
            local px = cx + cos(angle) * 2
            local py = cy + sin(angle) * 2
        end
    end
end

function game_manager:draw()
    if self.state == "active" and self.current_event then
        self.current_event:draw()
    end
end

function game_manager:remove_panel(panel_to_remove)
    del(self.active_panels, panel_to_remove)
end

-- CIRCLE RACE EVENT
circle_event = {}
circle_event.__index = circle_event

function circle_event.new()
    local self = setmetatable({
        start_time = time(),
        duration = 10,  -- 10 seconds to complete
        circles = {},
        current_target = 1,
        completed = false,
        success = false,  -- track if player succeeded
        timer_panel = nil,  -- panel for showing timer
        instruction_panel = nil,  -- panel for showing instructions
    }, circle_event)
    
    -- Generate 3 circles at random positions around the player
    for i = 1, 3 do
        local angle = rnd(1)
        local distance = 8 + rnd(4)  -- 8-12 tiles away
        local cx = player_ship.x + cos(angle) * distance
        local cy = player_ship.y + sin(angle) * distance
        
        add(self.circles, {
            x = cx,
            y = cy,
            radius = 1.2,  -- Increased from 0.5 to match larger visual
            collected = false
        })
    end
    
    -- Create instruction panel
    local instruction_text = "reach all circles!"
    local panel_width = #instruction_text * 4 + 12
    self.instruction_panel = panel.new(
        64 - panel_width / 2, 4,
        panel_width, 10,
        instruction_text,
        {
            text_col = 7,
            bg_col = 0,
            border_col = 8,
            border_style = "full",
            text_align = "center",
            shadow = true,
        }
    )
    game_manager:add_panel(self.instruction_panel)
    
    -- Create timer panel (positioned at top)
    self.timer_panel = panel.new(
        48, 16,
        32, 10,
        "10",
        {
            text_col = 7,
            bg_col = 0,
            border_col = 5,
            border_style = "full",
            text_align = "center",
            shadow = true,
        }
    )
    game_manager:add_panel(self.timer_panel)
    
    return self
end

function circle_event:update()
    -- Update timer
    local time_left = self.duration - (time() - self.start_time)
    
    if time_left <= 0 then
        self.completed = true
        self.success = false
        -- Remove panels when event ends
        if self.timer_panel then
            game_manager:remove_panel(self.timer_panel)
            self.timer_panel = nil
        end
        if self.instruction_panel then
            game_manager:remove_panel(self.instruction_panel)
            self.instruction_panel = nil
        end
        return
    end
    
    -- Update timer panel text and color
    if self.timer_panel then
        self.timer_panel:set_text(tostr(flr(time_left)))
        
        -- Change color when time is running out
        if time_left < 3 then
            self.timer_panel.text_col = 8  -- red
            self.timer_panel.border_col = 8
            self.timer_panel.pulse = true
            self.timer_panel.pulse_speed = 10
            self.timer_panel.pulse_amount = 1
        elseif time_left < 5 then
            self.timer_panel.text_col = 9  -- orange
            self.timer_panel.border_col = 9
        end
    end
    
    -- Check if player reached current target circle
    local circle = self.circles[self.current_target]
    if circle and not circle.collected then
        local dx = player_ship.x - circle.x
        local dy = player_ship.y - circle.y
        local dist = sqrt(dx * dx + dy * dy)
        
        if dist < circle.radius then
            circle.collected = true
            
            -- Award points for collecting circle
            local points = 100
            player_score += points
            
            -- Create floating text at player position
            local sx, sy = player_ship:get_screen_pos()
            add(floating_texts, floating_text.new(sx, sy - 10, "+" .. points, 7))
            
            -- Create collection notification panel WITH LIFETIME
            local collect_text = "circle " .. self.current_target .. "/3!"
            local panel_width = #collect_text * 4 + 12
            local collect_panel = panel.new(
                64 - panel_width / 2, 95,  -- Lower position, but not at very bottom
                panel_width, 10,
                collect_text,
                {
                    text_col = 11,
                    bg_col = 0,
                    border_col = 11,
                    border_style = "full",
                    text_align = "center",
                    pulse = true,
                    pulse_amount = 2,
                    pulse_speed = 8,
                    shadow = true,
                    life = 60,  -- Added: 2 seconds at 30fps
                }
            )
            game_manager:add_panel(collect_panel)
            
            self.current_target += 1
            
            -- Check if all circles collected
            if self.current_target > #self.circles then
                self.completed = true
                self.success = true
                
                -- Award completion bonus
                local bonus = 500
                player_score += bonus
                add(floating_texts, floating_text.new(sx, sy - 20, "BONUS +" .. bonus, 7))
                
                -- Remove timer and instruction panels
                if self.timer_panel then
                    game_manager:remove_panel(self.timer_panel)
                    self.timer_panel = nil
                end
                if self.instruction_panel then
                    game_manager:remove_panel(self.instruction_panel)
                    self.instruction_panel = nil
                end
            else
                -- Update instruction for next circle
                if self.instruction_panel then
                    self.instruction_panel:set_text("circle " .. self.current_target .. " is next!")
                    self.instruction_panel.text_col = 8  -- make it red to match the target
                end
            end
        end
    end
end

function circle_event:is_complete()
    return self.completed
end

function circle_event:draw()
    for i, circle in ipairs(self.circles) do
        if not circle.collected then
            -- Convert world position to screen
            local sx = cam_offset_x + (circle.x - circle.y) * tile_w/2
            local sy = cam_offset_y + (circle.x + circle.y) * tile_h/2
            
            -- Get terrain height at circle position
            local terrain_h = tile_manager:get_height_at(flr(circle.x), flr(circle.y))
            local base_y = sy - terrain_h * block_h
            
            local col = i == self.current_target and 8 or 2  -- bright red for target, dark red for others
            
            -- 1. Main circle boundary (clean, single line)
            local base_radius = 10
            if i == self.current_target then
                base_radius += sin(time() * 2) * 1.5  -- Gentle pulsing
            end
            
            -- Draw clean isometric circle
            for angle = 0, 1, 0.01 do  -- Finer steps for smoother circle
                local px = sx + cos(angle) * base_radius
                local py = base_y + sin(angle) * base_radius * 0.5
                pset(px, py, col)
            end
            
            -- 3. Rotating particle emitters (much cleaner)
            if i == self.current_target then  -- Only for current target to reduce clutter
                local rotation = time() * 0.3  -- Slow rotation
                
                -- Two emitters on opposite sides
                for emitter = 0, 1 do
                    local angle = rotation + emitter * 0.5
                    local emitter_x = sx + cos(angle) * base_radius * 0.9
                    local emitter_y = base_y + sin(angle) * base_radius * 0.45  -- Account for isometric
                    
                    -- Emit just a few particles going up
                    if flr(time() * 30) % 3 == 0 then  -- Controlled emission rate
                        for h = 0, 10 do
                            if h % 3 == 0 then  -- Sparse particles
                                pset(emitter_x, emitter_y - h, col)
                            end
                        end
                    end
                end
            end
        end
    end
    
    -- Draw directional arrow for current target
    local target = self.circles[self.current_target]
    if target and not target.collected then
        self:draw_direction_arrow(target)
    end
end

function circle_event:draw_direction_arrow(target)
    -- Calculate direction to target
    local dx = target.x - player_ship.x
    local dy = target.y - player_ship.y
    local dist = dist_trig(dx, dy)
    
    -- Skip if too close
    if dist < 2 then return end
    
    -- Normalize direction
    dx = dx / dist
    dy = dy / dist
    
    -- Calculate angle for arrow position around player
    local angle = atan2(dx, dy)
    
    -- Position arrow in orbit around player (in world space)
    local orbit_dist = 1.5  -- distance from player in world units
    local arrow_x = player_ship.x + cos(angle) * orbit_dist
    local arrow_y = player_ship.y + sin(angle) * orbit_dist
    
    -- Convert to screen coordinates
    local sx = cam_offset_x + (arrow_x - arrow_y) * tile_w/2
    local sy = cam_offset_y + (arrow_x + arrow_y) * tile_h/2
    
    -- Adjust for player's altitude
    sy -= player_ship.current_altitude * block_h
    
    -- Calculate arrow rotation in screen space
    -- Account for isometric transformation
    local screen_dx = (dx - dy) * tile_w/2
    local screen_dy = (dx + dy) * tile_h/2
    local screen_angle = atan2(screen_dx, screen_dy)
    
    -- Calculate arrow triangle points
    local arrow_size = 6  -- Increased from 4 to 6
    local arrow_col = 8  -- bright red
    
    -- Tip of the arrow (pointing toward target)
    local tip_x = sx + cos(screen_angle) * arrow_size
    local tip_y = sy + sin(screen_angle) * arrow_size * 0.5  -- squash for isometric
    
    -- Back corners of the arrow (wider angle for better visibility)
    local back_angle = screen_angle + 0.5
    local back1_x = sx + cos(back_angle - 0.18) * arrow_size * 0.7  -- Slightly wider
    local back1_y = sy + sin(back_angle - 0.18) * arrow_size * 0.35
    local back2_x = sx + cos(back_angle + 0.18) * arrow_size * 0.7
    local back2_y = sy + sin(back_angle + 0.18) * arrow_size * 0.35
    
    -- Draw filled arrow triangle using the triangle function
    draw_triangle(tip_x, tip_y, back1_x, back1_y, back2_x, back2_y, arrow_col)
end

-- SHIP CLASS
ship = {}
ship.__index = ship

function ship.new(start_x, start_y)
    return setmetatable({
        x = start_x,
        y = start_y,
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
        ramp_boost = 0.2,
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

    
    local speed = self:get_speed()

    if speed > self.max_speed then
        self.vx *= self.max_speed / speed
        self.vy *= self.max_speed / speed
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
    local sx, sy = (self.x - self.y) * tile_w/2, (self.x + self.y) * tile_h/2
    sy -= self.current_altitude * block_h
    return 64 - sx, 64 - sy
end

function ship:draw()
    local sx, sy = self:get_screen_pos()
    local nose_length, tail_length = self.size * 0.8, self.size * 0.8    
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
    
    -- Draw shadow (same triangle, but projected on ground)
    local terrain_height = self:get_terrain_height_at(self.x, self.y)
    local shadow_y = cam_offset_y + (self.x + self.y) * tile_h/2 - terrain_height * block_h
    
    -- Calculate shadow offset (how much shadow is displaced from ship)
    local shadow_offset = (self.current_altitude - terrain_height) * block_h
    
    -- Draw filled shadow (pass coordinates directly)
    draw_triangle(
        points[1][1], points[1][2] + shadow_offset,
        points[2][1], points[2][2] + shadow_offset,
        points[3][1], points[3][2] + shadow_offset,
        self.shadow_col
    )
    
    -- Draw ship body (pass coordinates directly)
    draw_triangle(
        points[1][1], points[1][2],
        points[2][1], points[2][2],
        points[3][1], points[3][2],
        self.body_col
    )
    
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
    end
end

function ship:get_speed()
    return dist_trig(self.vx, self.vy )
end


-- TILE CLASS
tile = {}
tile.__index = tile

function tile.new(world_x, world_y)
    local t = setmetatable({
        x = world_x,
        y = world_y,
        height = generate_height_at(world_x, world_y),
        base_sx = (world_x - world_y) * tile_w/2,
        base_sy = (world_x + world_y) * tile_h/2,
        top_col = 3,
        side_col = 1,
        dark_col = 0,
    }, tile)
    t:update_colors()
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


-- Precompute half-width/half-height once
HW = tile_w >> 1  -- 24 >> 1 = 12
HH = tile_h >> 1  -- 12 >> 1 = 6

function diamond(sx, sy, c)
    local dx = HW
    for r = 0, HH do
        line(sx - dx, sy - r, sx + dx, sy - r, c)
        if r > 0 then
        line(sx - dx, sy + r, sx + dx, sy + r, c)
        end
        dx -= 2
    end
end


function tile:draw()
    local sx = cam_offset_x + self.base_sx
    local sy = cam_offset_y + self.base_sy

    -- WATER (≤0): flat diamond + single highlight sweep
    if self.height <= 0 then
        local wc = (self.height <= -2) and 1 or 12
        diamond(sx, sy, wc)
        -- cheap highlight ripple (one line)
        local p = sin(time() * 2 + ((self.x + self.y) << 1) * 0.05)
        local yh = (p >= 0) and 1 or 0
        line(sx - HW, sy + yh, sx + HW, sy + yh, (wc == 1) and 12 or 7)
        return
    end

    -- LAND
    local h  = self.height
    local hp = (block_h * h)      -- pixels of side height
    sy -= hp                      -- lift top by side height (fewer ops later)

    -- neighbor occlusion (south/east faces only)
    local s = tile_manager:get_tile(self.x,     self.y + 1)
    local e = tile_manager:get_tile(self.x + 1, self.y    )
    local draw_s = (not s) or (s.height < h)
    local draw_e = (not e) or (e.height < h)

    -- SOUTH FACE (left face)
    if draw_s and hp > 0 then
        -- top edge of south face starts at (sx-HW, sy) to (sx, sy+HH)
        -- we draw hp slanted scanlines downward
        for i = 0, hp do
        line(sx - HW, sy + i, sx, sy + HH + i, self.side_col)
        end
    end

    -- EAST FACE (right face)
    if draw_e and hp > 0 then
        for i = 0, hp do
        line(sx + HW, sy + i, sx, sy + HH + i, self.dark_col)
        end
    end

    -- TOP DIAMOND
    diamond(sx, sy, self.top_col)

    -- EXPOSED OUTLINES (only draw what’s visible)
    -- north and west edges matter most in iso; gate on higher/equal neighbors
    local n = tile_manager:get_tile(self.x,     self.y - 1)
    local w = tile_manager:get_tile(self.x - 1, self.y    )

    if (not n) or (n.height <= h) then
        line(sx, sy - HH, sx + HW, sy, self.top_col)
    end
    if (not w) or (w.height <= h) then
        line(sx - HW, sy, sx, sy - HH, self.top_col)
    end
end



-- TILE MANAGER
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
    -- keep a window around the player, but no strings
    local ny1 = self.player_y - VIEW_RANGE * 2
    local ny2 = self.player_y + VIEW_RANGE * 2
    local nx1 = self.player_x - VIEW_RANGE * 2
    local nx2 = self.player_x + VIEW_RANGE * 2

    local new_cache = {}
    for y = ny1, ny2 do
        local row = height_cache[y]
        if row then
            local new_row = {}
            for x = nx1, nx2 do
                local h = row[x]
                if h ~= nil then
                    new_row[x] = h
                end
            end
            if next(new_row) then
                new_cache[y] = new_row
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


-- TERRAIN GENERATION
function grad(hash, x, y)
    local h = hash % 4
    if h == 0 then return x + y
    elseif h == 1 then return -x + y
    elseif h == 2 then return x - y
    else return -x - y
    end
end

function perlin2d(x,y,p)
    local fx,fy=flr(x),flr(y)
    local xi,yi=fx&127,fy&127
    local xf,yf=x-fx,y-fy
    local u=xf*xf*(3-2*xf)
    local v=yf*yf*(3-2*yf)
    local px,px1=p[xi],p[xi+1]
    local a,b=px+yi,px1+yi
    local aa,ab,ba,bb=p[a],p[a+1],p[b],p[b+1]
    local ax=((aa&1)<1 and xf or -xf)+((aa&2)<2 and yf or -yf)
    local bx=((ba&1)<1 and xf-1 or 1-xf)+((ba&2)<2 and yf or -yf)
    local cx=((ab&1)<1 and xf or -xf)+((ab&2)<2 and yf-1 or 1-yf)
    local dx=((bb&1)<1 and xf-1 or 1-xf)+((bb&2)<2 and yf-1 or 1-yf)
    local x1=ax+(bx-ax)*u
    local x2=cx+(dx-cx)*u
    return x1+(x2-x1)*v
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

function generate_height_at(world_x, world_y)
    local row = height_cache[world_y]
    if row then
        local h = row[world_x]
        if h ~= nil then return h end
    end

    local scale = menu_options[1].values[menu_options[1].current]
    local water_level = menu_options[2].values[menu_options[2].current]
    local min_height = menu_options[3].values[menu_options[3].current]
    local max_height = menu_options[4].values[menu_options[4].current]
    local sharpness = menu_options[5].current

    local nx = world_x / scale
    local ny = world_y / scale

    -- 3 lightweight octaves
    local height = 0
    local amp = 1
    local freq = 1
    local max_amp = 0

    for _=1,3 do
        height += perlin2d(nx * freq, ny * freq, terrain_perm) * amp
        max_amp += amp
        amp *= 0.5
        freq *= 2
    end

    height /= max_amp -- [-1,1]

    -- sharpness shaping (kept, but reuses a single extra noise sample for 3/4)
    if sharpness == 2 then
        height = sgn(height) * abs(height) ^ 0.8
    elseif sharpness == 3 or sharpness == 4 then
        local r = perlin2d(nx * 2, ny * 2, terrain_perm)
        r = 1 - abs(r)
        if sharpness == 3 then
            height = height * 0.8 + r * 0.2
            height = sgn(height) * abs(height) ^ 0.5
        else
            r *= r
            height = height * 0.6 + r * 0.4
            height = sgn(height) * abs(height) ^ 0.3
        end
    end

    -- map to your range
    height = min_height + (height + 1) * 0.5 * (max_height - min_height)
    height -= water_level
    height = flr(clamp(height, -4, 28))

    -- store in 2D cache
    if not row then
        row = {}
        height_cache[world_y] = row
    end
    row[world_x] = height
    return height
end

__gfx__
eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee00000000000000000000000000000000
ceeeeeeececccccccccecccccccccececccccccccecccccccccecceeeeeeceeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee00000000000000000000000000000000
ceeeeeeececeeeeeeececeeeeeeececeeeeeecceeeceeeeeeecececceeeeceeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee00000000000000000000000000000000
ccccccccceceeeeeeececcccccccceceeeeeceeeeeceeeeeeececeeeceeeceeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee00000000000000000000000000000000
ceeeeeeececeeeeeeececeeeecceeeceeecceeeeeeceeeeeeececeeeecceceeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee00000000000000000000000000000000
ceeeeeeececcccccccceceeeeeeccececcccccccceccccccccceceeeeeecceeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee00000000000000000000000000000000
eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee00000000000000000000000000000000
eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee00000000000000000000000000000000
eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee00000000000000000000000000000000
ccccccccceceeeeeeeeececccccccceeccccccccceeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee00000000000000000000000000000000
ceeeeeeeeeceeeeeeeeececeeeeeeececeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee00000000000000000000000000000000
ceecccccceceeeeeeeeececeeeeeeececccccccceeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee00000000000000000000000000000000
ceeeeeeececeeeeeeeeececeeeeeeececeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee00000000000000000000000000000000
cccccccccecccccccccececccccccceeccccccccceeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee00000000000000000000000000000000
eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee00000000000000000000000000000000
eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee00000000000000000000000000000000
__map__
000000000000000000000000000e000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
0000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
000000000e0e0000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
00000000000e00000e0e00000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
0000000000000e0e00000e000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
000000000000000e00000e000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
00000000000000000e0e00000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
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
011000001d7421d7421d7421d7421d7421d7421d7421d7421d7421d7421d7421d7421d7421d7421d7421d7421d7421d7421d7421d7421d7421d7421d7421d7421d7421d7421d7421d7421d7421d7421d7421d742
010b00001007300000000000000010605300041007300000106750000010073000001060500000000000000010073000000000000000106050000000000000001067500000100730000010675000000400500000
030b000020335203351d3351d3351f3351f33520335203351d3351d3351f3351f33520335203351d3351d3351f3351f3351b3351b3351d3351d3351f3351f3351b3351b3351d3351d3351f3351f3351b3351b335
030b000020335203351d3351d3351f3351f33520335203351d3351d3351f3351f33524335243352233522335203052030520335203351f3051f3051f3351f3351f3051f3051f3351f33520335203351f3351f335
030b00001d3451d34511345113451d3451d34511345113451d3451d34529345293451d3451d34511345113451d3451d34529345293451d3451d34529345293451d3451d34511345113451d3451d3453534535345
030b00001d3451d3451d3451d3451d3451d3451d3451d34522345223451f3051f3451f3451b3051b3451b3451d3451d3451d3451d3451d3451d3451d3451d3451d3451d3451d3451d3451d3451d3451d3451d345
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
00 0b141b13
00 1c021d44
00 1c031e44
00 1c041d44
02 01051f44

