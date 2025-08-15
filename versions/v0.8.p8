pico-8 cartridge // http://www.pico-8.com
version 41
__lua__
-- HORIZON GLIDE
-- An infinite isometric racing game

-- Helper functions
function ceil(x) return -flr(-x) end
function clamp(v, lo, hi) return mid(v, lo, hi) end
function dist_trig(dx, dy) local ang = atan2(dx, dy) return dx * cos(ang) + dy * sin(ang) end

function fmt2(n)
    local s=flr(n*100+0.5)
    local neg=s<0 if neg then s=-s end
    local int=flr(s/100)
    local frac=s%100
    return (neg and "-" or "")..int.."."..(frac<10 and "0"..frac or frac)
end

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

function create_minimap_cache()
    local cache = {}
    setmetatable(cache, {
        __index = function(t, key)
            -- Unpack: x*200+y formula
            local x = flr(key / 200) - 64
            local y = (key % 200) - 100
            
            local col = get_terrain_color(generate_height_at(x, y))
            rawset(t, key, col)
            return col
        end
    })
    return cache
end


-- MAIN PICO-8 FUNCTIONS
function _init()
    music(0)
    -- game state & modes
    game_state = "startup"
    
    -- startup variables
    startup_phase = "title"
    startup_timer = 0
    startup_view_range = 0
    title_x1 = -64  -- Start HORIZON fully off-screen (8 sprites * 8 pixels)
    title_x2 = 128  -- Start GLIDE fully off-screen
    
    -- menu panels
    play_panel = nil
    customize_panel = nil
    customization_panels = {}
    customize_cursor = 1
    
    -- CREATE PLAYER SHIP RIGHT AWAY
    player_ship = ship.new(0, 0)
    player_ship.is_hovering = true
    
    -- core game variables
    player_score = 0
    display_score = 0
    floating_texts = {}
    particles = {}
    
    -- combat
    enemies = {}
    projectiles = {}
    
    -- camera variables
    cam_offset_x = 64
    cam_offset_y = 64
    cam_target_x = 0
    cam_target_y = 0
    
    -- tile system constants
    view_range = 0
    block_h = 2
    half_tile_width = 12
    half_tile_height = 6
    
    -- terrain generation
    height_cache = {}
    last_cache_cleanup = 0
    terrain_perm = nil
    current_seed = 1337
    
    -- minimap cache with metatable
    minimap_colors = create_minimap_cache()
    
    -- menu configuration (unchanged)
    menu_options = {
        {name="terrain scale", values={8, 10, 12, 14, 16}, current=2},
        {name="water level", values={-4, -3, -2, -1, 0, 1, 2, 3, 4}, current=4},
        {name="seed", values={}, current=1, is_seed=true},
        {name="randomize seed", is_action=true},
    }
    
    menu_cursor = 1
    menu_panels = {}
    
    -- initialization sequence
    terrain_perm = generate_permutation(current_seed)
    height_cache = {}
    tile_manager:init()
    tile_manager:update_player_position(0, 0)
    tile_manager:update_tiles()
    
    -- set ship altitude
    local terrain_h = player_ship:get_terrain_height_at(0, 0)
    player_ship.current_altitude = terrain_h + player_ship.hover_height
end


function update_world()
    local is_startup = (game_state == "startup")
    
    -- Game manager update (game only)
    if not is_startup and game_manager then
        game_manager:update()
    end
    
    -- Ship movement
    if is_startup then
        -- Autonomous movement for startup
        player_ship.vy = -0.1
        player_ship.y += player_ship.vy
        -- Set angle based on velocity
        local svx = (player_ship.vx - player_ship.vy)
        local svy = (player_ship.vx + player_ship.vy) * 0.5
        player_ship.angle = atan2(svx, svy)
        -- Keep hovering
        local terrain_h = player_ship:get_terrain_height_at(player_ship.x, player_ship.y)
        player_ship.current_altitude = terrain_h + player_ship.hover_height
        player_ship.is_hovering = true
    else
        -- Full physics update for game
        player_ship:update()
    end
    
    -- Tile manager updates
    tile_manager:update_player_position(player_ship.x, player_ship.y)
    tile_manager:update_tiles()
    
    -- Particle spawning
    if is_startup then
        if startup_timer % 3 == 0 then
            player_ship:spawn_particles(1, 0)
        end
    elseif player_ship.is_hovering then
        local speed = player_ship:get_speed()
        if speed > 0.01 then
            player_ship.particle_timer += 1
            local spawn_rate = max(1, 5 - flr(speed * 10))
            if player_ship.particle_timer >= spawn_rate then
                player_ship.particle_timer = 0
                player_ship:spawn_particles(1 + flr(speed * 5))
            end
        end
    else
        player_ship.particle_timer = 0
    end
    
    -- Update particles
    local new_particles = {}
    for p in all(particles) do
        if p:update() then add(new_particles, p) end
    end
    particles = new_particles
    if #particles > 100 then
        for i = 1, #particles - 100 do deli(particles, 1) end
    end
    
    -- Camera update
    local target_x, target_y = player_ship:get_camera_target()
    if is_startup then
        cam_offset_x, cam_offset_y = target_x, target_y
    else
        cam_offset_x += (target_x - cam_offset_x) * 0.3
        cam_offset_y += (target_y - cam_offset_y) * 0.3
        cam_target_x, cam_target_y = target_x, target_y
    end
    
    -- Game-only updates
    if not is_startup then
        update_projectiles()
        
        -- Floating texts
        local new_floats = {}
        for f in all(floating_texts) do
            if f:update() then add(new_floats, f) end
        end
        floating_texts = new_floats
        
        -- Score animation
        if display_score < player_score then
            local diff = player_score - display_score
            display_score += (diff < 10) and player_score or (display_score + ceil(diff * 0.1))
        end
        
        -- Cache cleanup
        local current_time = time()
        if current_time - last_cache_cleanup > 2 then
            tile_manager:cleanup_cache()
            last_cache_cleanup = current_time
        end
    end
end

function _update()
    if game_state == "startup" then
        startup_timer += 1
        
        -- Shared world update
        update_world()
        
        -- Phase-specific logic
        if startup_phase == "title" then
            -- View range expansion
            if startup_view_range < 7 then
                startup_view_range += 0.5
                view_range = flr(startup_view_range)
                tile_manager:update_tiles()
            end
            -- Title sliding
            if title_x1 < 20 then title_x1 += 6 end
            if title_x2 > 68 then title_x2 -= 6 end
            
            -- Transition immediately after zoom completes
            if startup_view_range >= 7 and title_x1 >= 20 and title_x2 <= 68 then
                startup_phase = "menu_select"
                init_menu_select()
            end
        elseif startup_phase == "menu_select" then
            update_menu_select()
        elseif startup_phase == "customize" then
            update_customize()
        end
    elseif game_state == "menu" then
        update_menu()  -- if this exists
    elseif game_state == "game" then
        update_world()  -- Just call update_world!
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



function draw_minimap(x, y)
    local ms, wr = 50, 32
    local px_scale = (wr*2/ms)
    local cx, cy = x + ms/2, y + ms/2
    
    -- Background and border
    rectfill(x-1, y-1, x+ms, y+ms, 0)
    rect(x-2, y-2, x+ms+1, y+ms+1, 5)
    
    -- Cache calculations
    local ship_x = player_ship.x
    local ship_y = player_ship.y
    local half_ms = ms/2
    
    -- Draw terrain pixels
    for py = 0, ms-1 do
        local wy_base = ship_y + (py - half_ms) * px_scale
        local wy_flr = flr(wy_base)
        
        for px = 0, ms-1 do
            local wx_base = ship_x + (px - half_ms) * px_scale
            local wx_flr = flr(wx_base)
            
            -- Safe key: x*200+y (supports x:-64 to 99, y:-100 to 99)
            local key = (wx_flr + 64) * 200 + (wy_flr + 100)
            local col = minimap_colors[key]  -- No if check!
            
            pset(x + px, y + py, col)
        end
    end
    
    -- View box
    local vbs = ms * (view_range * 2) / (wr * 2)
    rect(cx - vbs/2, cy - vbs/2, cx + vbs/2, cy + vbs/2, 7)
    
    -- Player position
    circfill(cx, cy, 1, 8)
    pset(cx, cy, 8)
end


function draw_title_sprites()
    local title_y = 10  -- Y position for HORIZON
    local shadow_offset = 1
    
    -- Draw outline using 4 shadows (palette swapped)
    pal(12, 0)  -- Replace cyan with black for outline
    pal(7, 0)   -- Replace white with black too
    
    -- Draw 4 directional shadows for outline effect
    local directions = {
        {shadow_offset, 0},    -- right
        {-shadow_offset, 0},   -- left
        {0, shadow_offset},    -- down
        {0, -shadow_offset}    -- up
    }
    
    for i=1,#directions do
        local dx, dy = directions[i][1], directions[i][2]
        
        -- HORIZON outline
        draw_vertical_wave_sprites(0, title_x1 + dx, title_y + dy, 8, 1)
        
        -- GLIDE outline
        draw_vertical_wave_sprites(16, title_x2 + dx, title_y + 10 + dy, 6, 1)
    end
    
    pal()  -- Reset palette once
    
    -- Draw actual text with vertical wave animation on top
    draw_vertical_wave_sprites(0, title_x1, title_y, 8, 1)  -- HORIZON
    draw_vertical_wave_sprites(16, title_x2, title_y + 10, 6, 1)  -- GLIDE
end

-- Function to draw sprites with vertical wave animation
function draw_vertical_wave_sprites(sprite_start, x, y, width_in_sprites, height_in_sprites)
    -- Calculate wave position (moves from left to right)
    local wave_speed = 0.5  -- How fast the wave travels
    local wave_width = 20  -- Width of the wave in pixels
    local wave_amplitude = 2  -- How far pixels move up/down
    
    -- Wave position that loops across the text width
    local total_width = width_in_sprites * 8
    local wave_position = (time() * wave_speed * 100) % (total_width + wave_width * 2) - wave_width
    
    -- Draw each vertical strip
    for strip_x = 0, total_width - 1 do
        -- Calculate distance from wave center
        local distance_from_wave = abs(strip_x - wave_position)
        
        -- Calculate wave offset (only affects pixels near the wave)
        local wave_offset = 0
        if distance_from_wave < wave_width then
            -- Create a smooth bump using cosine
            local wave_progress = distance_from_wave / wave_width
            wave_offset = cos(wave_progress * 0.5) * wave_amplitude
        end
        
        -- Use sspr to draw just this vertical strip with offset
        sspr(
            sprite_start % 16 * 8 + strip_x,  -- source x in sprite sheet
            flr(sprite_start / 16) * 8,  -- source y in sprite sheet
            1,  -- source width (just one column)
            height_in_sprites * 8,  -- source height
            x + strip_x,  -- destination x
            y - wave_offset,  -- destination y (subtract for upward bump)
            1,  -- destination width
            height_in_sprites * 8  -- destination height
        )
    end
end

-- Modified draw_startup function
function draw_startup()
    cls(1)

    -- Always draw world first (background)
    for tile in all(tile_manager.tile_list) do
        tile:draw()
    end

    -- Always draw particles
    for p in all(particles) do
        p:draw(cam_offset_x, cam_offset_y)
    end

    -- Always draw ship
    player_ship:draw()

    -- Draw title using SPRITES with wave effect
    draw_title_sprites()

    -- Draw menu selection panels
    if startup_phase == "menu_select" then
        play_panel:draw()
        customize_panel:draw()
    end
    
    -- Draw customization interface directly over the world
    if startup_phase == "customize" then
        -- Draw all customization panels
        for p in all(customization_panels) do
            p:draw()
        end
        
        -- Draw minimap
        draw_minimap(74, 32)
        
        -- Draw controls hint at bottom
        print("⬆️⬇️:select ⬅️➡️:change", 26, 120, 5)
    end
end

function init_menu_select()
    -- Play panel slides in from the left
    play_panel = panel.new(-50, 90, nil, nil, "play",  {col=11, border_style="full", pulse=true})
    play_panel.selected = true
    play_panel:set_position(50, 90, false)  -- Slide to final position
    
    -- Customize panel slides in from the right
    customize_panel = panel.new(128, 104, nil, nil, "customize", {col=12, border_style="full"})
    customize_panel:set_position(40, 104, false)  -- Slide to final position
end

function update_customize()
    -- Update all panels
    for p in all(customization_panels) do
        p:update()
    end
    
    -- Navigation
    if btnp(⬆️) then
        customization_panels[customize_cursor].selected = false
        customize_cursor -= 1
        if customize_cursor < 1 then customize_cursor = #customization_panels end
        customization_panels[customize_cursor].selected = true
    end
    if btnp(⬇️) then
        customization_panels[customize_cursor].selected = false
        customize_cursor += 1
        if customize_cursor > #customization_panels then customize_cursor = 1 end
        customization_panels[customize_cursor].selected = true
    end
    
    local current_panel = customization_panels[customize_cursor]
    
    -- Handle Start Game button
    if current_panel.is_start then
        if btnp(❎) or btnp(🅾️) then
            view_range = 7
            init_game()
        end
        return
    end
    
    -- Get the option this panel represents
    local option_index = current_panel.option_index
    if not option_index then return end
    
    local option = menu_options[option_index]
    
    -- Store old value to detect changes
    local old_value = nil
    if option.is_seed then
        old_value = current_seed
    elseif not option.is_action then
        old_value = option.values[option.current]
    end
    
    -- Handle value changes
    if option.is_action then
        if btnp(❎) or btnp(🅾️) then
            if option.name == "randomize seed" then
                current_seed = flr(rnd(9999))
                -- Update seed panel text
                for p in all(customization_panels) do
                    if p.option_index == 3 then  -- Seed option index
                        p.text = "seed: " .. current_seed
                    end
                end
                regenerate_world_live()
            end
        end
    elseif option.is_seed then
        if btnp(⬅️) then
            current_seed = max(0, current_seed - 1)
            current_panel.text = option.name .. ": " .. current_seed
        end
        if btnp(➡️) then
            current_seed = min(9999, current_seed + 1)
            current_panel.text = option.name .. ": " .. current_seed
        end
    else
        if btnp(⬅️) then
            option.current -= 1
            if option.current < 1 then option.current = #option.values end
            current_panel.text = option.name .. ": " .. tostr(option.values[option.current])
        end
        if btnp(➡️) then
            option.current += 1
            if option.current > #option.values then option.current = 1 end
            current_panel.text = option.name .. ": " .. tostr(option.values[option.current])
        end
    end
    
    -- Check if value changed and regenerate world if so
    local new_value = nil
    if option.is_seed then
        new_value = current_seed
    elseif not option.is_action then
        new_value = option.values[option.current]
    end
    
    if old_value != nil and new_value != nil and old_value != new_value then
        regenerate_world_live()
    end
end

-- Regenerate world in real-time
function regenerate_world_live()
    -- Store ship position
    local ship_x, ship_y = player_ship.x, player_ship.y
    
    -- Generate new terrain with current settings
    terrain_perm = generate_permutation(current_seed)
    height_cache = {}
    
    -- Reset minimap cache with metatable
    minimap_colors = create_minimap_cache()
    
    -- Clear and regenerate tiles
    tile_manager:init()
    tile_manager:update_player_position(ship_x, ship_y)
    tile_manager:update_tiles()
    
    -- Adjust ship altitude to new terrain
    local new_height = player_ship:get_terrain_height_at(ship_x, ship_y)
    player_ship.current_altitude = new_height + player_ship.hover_height
end

function update_menu_select()
    -- Update panels
    play_panel:update()
    customize_panel:update()
    
    -- Handle input - now using up/down instead of left/right
    if btnp(⬆️) or btnp(⬇️) then
        -- Toggle selection
        play_panel.selected = not play_panel.selected
        customize_panel.selected = not customize_panel.selected
        
        -- Update visual properties
        play_panel.pulse = play_panel.selected
        customize_panel.pulse = customize_panel.selected
    end
    
    -- Confirm selection
    if btnp(❎) or btnp(🅾️) then
        if play_panel.selected then
            -- Start game with current terrain
            view_range = 7
            init_game()
        else
            -- Enter customization mode
            enter_customize_mode()
        end
    end
end

function enter_customize_mode()
    startup_phase = "customize"
    customize_cursor = 1
    customization_panels = {}
    
    local y_start = 32
    local y_spacing = 10
    local panel_index = 0
    
    for i, option in ipairs(menu_options) do
        if not option.is_action then
            local y = y_start + panel_index * y_spacing
            local text = option.name .. ": " .. 
                (option.is_seed and current_seed or tostr(option.values[option.current]))
            
            local p = panel.new(-70, y, 56, 9, text, 
                {text_col=6, col=11, text_align="left"})
            p.option_index = i
            p:set_position(2, y, false)
            add(customization_panels, p)
            panel_index += 1
        end
    end
    
    -- Add randomize button
    local rp = panel.new(-70, y_start + 3 * y_spacing, 56, 9, "randomize seed",
        {col=5, text_align="left"})
    rp.option_index = 4
    rp:set_position(2, y_start + 3 * y_spacing, false)
    add(customization_panels, rp)
    
    -- Start button - auto width, taller height
    local sb = panel.new(48, 120, 32, nil, "start game",
        {col=11, border_style="full", pulse=true, tall=true})
    sb.is_start = true
    sb:set_position(48, 105, false)
    add(customization_panels, sb)
    
    customization_panels[1].selected = true
end


function reset_terrain_state()
    terrain_perm = generate_permutation(current_seed) -- new seed/permutation
    height_cache = {}                                 -- drop old heights
    tile_manager:init()                               -- drop all tiles
end

-- GAME FUNCTIONS
function init_game()
    game_state = "game"
    
    -- Reset terrain with chosen settings
    reset_terrain_state()
    
    -- Reset scores/ui
    player_score, display_score = 0, 0
    floating_texts, particles = {}, {}
    
    -- SHIP IS ALREADY CREATED AND POSITIONED!
    -- Just need to reset its state for game mode
    game_manager = game_manager.new()
    
    -- Update tiles for full view range
    tile_manager:update_player_position(player_ship.x, player_ship.y)
    tile_manager:update_tiles()
    
    -- Ensure altitude is correct
    player_ship.current_altitude = player_ship:get_terrain_height_at(player_ship.x, player_ship.y) + player_ship.hover_height
    last_cache_cleanup = time()
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
    
    -- DRAW PROJECTILES
    draw_projectiles()
    
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

function draw_segmented_bar(x, y, value, max_value, filled_col, empty_col)
    local rect_width = 3
    local rect_height = 3
    local spacing = 1
    local max_bars = 15
    
    -- Calculate how many bars to fill
    local ratio = value / max_value
    local filled_bars = flr(ratio * max_bars)
    
    -- Draw each segment
    for i = 0, max_bars - 1 do
        local seg_x = x + i * (rect_width + spacing)
        local col = i < filled_bars and filled_col or empty_col
        rectfill(seg_x, y, seg_x + rect_width - 1, y + rect_height - 1, col)
    end
end

function draw_ui()
    -- Black band at bottom
    rectfill(0, 119, 127, 127, 0)
    
    -- HEALTH BAR (top bar)
    local health_col = player_ship.hp > 30 and 11 or 8  -- green if healthy, red if low
    draw_segmented_bar(4, 120, player_ship.hp, 100, health_col, 5)
    
    -- Speed bar (bottom bar)
    local current_speed = player_ship:get_speed()
    draw_segmented_bar(4, 124, current_speed, player_ship.max_speed, 8, 5)
    
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
    
    -- Smart width: if w is nil/false, auto-calculate from text
    if not w then
        w = #text * 4 + (options.padding or 12)
    end
    
    -- Smart height: if h is nil/false, use default
    if not h then
        h = options.tall and 12 or 10
    end
    
    -- Smart colors: if col provided, use it for both border and selected
    local col = options.col
    
    return setmetatable({
        x = x,
        y = y,
        w = w,
        h = h,
        text = text,
        selected = false,
        expand = 0,
        bg_col = options.bg_col or 0,
        border_col = options.border_col or col or 5,
        text_col = options.text_col or 7,
        selected_col = options.selected_col or col or 11,
        border_style = options.border_style or "corners",
        border_width = options.border_width or 1,
        text_align = options.text_align or "center",
        text_padding = options.text_padding or 3,
        target_x = x,
        target_y = y,
        slide_speed = options.slide_speed or 0.2,
        pulse = options.pulse or false,
        pulse_amount = options.pulse_amount or (options.pulse and 1) or 2,
        pulse_speed = options.pulse_speed or (options.pulse and 6) or 4,
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
    local sx = cam_x + (self.x - self.y) * half_tile_width
    local sy = cam_y + (self.x + self.y) * half_tile_height + self.z

    -- fade out based on life
    local alpha = self.life / self.max_life

    if alpha > 0.5 then
        if self.size > 1.5 then
            circfill(sx, sy, 1, self.col)
        else
            pset(sx, sy, self.col)
        end
    elseif (alpha > 0.25 and rnd() > 0.3) or (alpha <= 0.25 and rnd() > 0.6) then
        pset(sx, sy, self.col)
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
        event_types = {"circles", "combat"},  -- ADDED combat
        completion_panel = nil,
        active_panels = {},

        -- difficulty progression (flat vars)
        difficulty_circle_round   = 0,
        difficulty_rings_base     = 3,
        difficulty_rings_step     = 1,
        difficulty_base_time      = 5,
        difficulty_recharge_start = 2,
        difficulty_recharge_step  = 0.2,
        difficulty_recharge_min   = 0.5,
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
        local num_rings = self.difficulty_rings_base
                          + self.difficulty_circle_round * self.difficulty_rings_step
        local recharge  = max(self.difficulty_recharge_min,
                              self.difficulty_recharge_start - self.difficulty_circle_round * self.difficulty_recharge_step)
        local base_time = self.difficulty_base_time

        self.current_event = circle_event.new({
            num_rings = num_rings,
            base_time = base_time,
            recharge_seconds = recharge
        })
    elseif event_type == "combat" then
        self.current_event = combat_event.new()
    end

    self.state = "active"
end


function game_manager:end_event(success)
    self.state = "idle"
    self.idle_start_time = time()
    
    local message = success and "EVENT COMPLETE!" or "EVENT FAILED!"
    local col = success and 11 or 8
    
    local cp = panel.new(64 - 40, 115, nil, nil, message, 
        {col=col, border_style="full", shadow=true, pulse=success, life=90})
    cp:set_position(64 - 40, 105, false)
    self:add_panel(cp)
    
    -- increase difficulty only if success
    if success then
        self.difficulty_circle_round += 1
    end
    
    self.current_event = nil
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

function circle_event.new(opt)
    opt = opt or {}
    local self = setmetatable({
        base_time        = opt.base_time or 10,
        recharge_seconds = opt.recharge_seconds or 4,
        end_time         = 0,

        per_ring_points    = 100,
        completion_bonus   = 500,
        total_points_award = 0,

        circles = {},
        current_target = 1,
        completed = false,
        success = false,

        timer_panel = nil,
        instruction_panel = nil,
    }, circle_event)

    local ring_count = opt.num_rings or 3

    -- generate rings
    for i = 1, ring_count do
        local angle = rnd(1)
        local distance = 8 + rnd(4)
        local cx = player_ship.x + cos(angle) * distance
        local cy = player_ship.y + sin(angle) * distance
        add(self.circles, { x=cx, y=cy, radius=1.2, collected=false })
    end

    -- init timer
    self.end_time = time() + self.base_time

    -- one-time payout if completed (no per-ring score during play)
    self.total_points_award = #self.circles * self.per_ring_points + self.completion_bonus

    -- UI
    self.instruction_panel = panel.new(64 - 50, 4, nil, nil,
        "reach all "..#self.circles.." circles!", {col=8, border_style="full", shadow=true, padding=12})
    game_manager:add_panel(self.instruction_panel)

    self.timer_panel = panel.new(48, 16, 40, nil, "0.00s", {col=5, border_style="full", shadow=true})
    game_manager:add_panel(self.timer_panel)

    return self
end


function circle_event:update()
    -- time left based on moving end_time
    local time_left = self.end_time - time()

    if time_left <= 0 then
        -- time out: fail
        self.completed = true
        self.success = false
        if self.timer_panel then game_manager:remove_panel(self.timer_panel) self.timer_panel = nil end
        if self.instruction_panel then game_manager:remove_panel(self.instruction_panel) self.instruction_panel = nil end
        return
    end

    -- update timer UI with 2 decimal places
    if self.timer_panel then
        local shown = self.end_time - time()
        self.timer_panel:set_text(fmt2(max(0, shown)).."S")

        
        -- color / pulse changes
        if time_left < 3 then
            self.timer_panel.text_col = 8  -- red
            self.timer_panel.border_col = 8
            self.timer_panel.pulse = true
            self.timer_panel.pulse_speed = 10
            self.timer_panel.pulse_amount = 1
        elseif time_left < 5 then
            self.timer_panel.text_col = 9  -- orange
            self.timer_panel.border_col = 9
            self.timer_panel.pulse = false
        else
            self.timer_panel.text_col = 7
            self.timer_panel.border_col = 5
            self.timer_panel.pulse = false
        end
    end

    -- check current ring
    local circle = self.circles[self.current_target]
    if circle and not circle.collected then
        local dx = player_ship.x - circle.x
        local dy = player_ship.y - circle.y
        local dist = sqrt(dx*dx + dy*dy)

        if dist < circle.radius then
            circle.collected = true

            -- only give extra time if this isn't the last ring
            local sx, sy = player_ship:get_screen_pos()
            if self.current_target < #self.circles then
                self.end_time += self.recharge_seconds
                add(floating_texts, floating_text.new(sx, sy - 10, "+"..fmt2(self.recharge_seconds).."s", 7))
            end

            self.current_target += 1

            if self.current_target > #self.circles then
                -- success: single payout once
                self.completed = true
                self.success = true

                if self.timer_panel then game_manager:remove_panel(self.timer_panel) self.timer_panel = nil end
                if self.instruction_panel then game_manager:remove_panel(self.instruction_panel) self.instruction_panel = nil end

                player_score += self.total_points_award
                add(floating_texts, floating_text.new(sx, sy - 20, "+"..self.total_points_award, 7))
            else
                if self.instruction_panel then
                    local remaining = #self.circles - self.current_target + 1
                    self.instruction_panel:set_text(remaining.." circle"..(remaining>1 and "s" or "").." left")
                    self.instruction_panel.text_col = 8
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
            local sx = cam_offset_x + (circle.x - circle.y) * half_tile_width
            local sy = cam_offset_y + (circle.x + circle.y) * half_tile_height
            local terrain_h = tile_manager:get_height_at(flr(circle.x), flr(circle.y))
            local base_y = sy - terrain_h * block_h
            local col = (i == self.current_target) and 8 or 2

            local base_radius = 10
            if i == self.current_target then
                base_radius += sin(time() * 2) * 1.5
            end

            for a = 0, 1, 0.01 do
                local px = sx + cos(a) * base_radius
                local py = base_y + sin(a) * base_radius * 0.5
                pset(px, py, col)
            end

            if i == self.current_target then
                local rotation = time() * 0.3
                for emitter = 0, 1 do
                    local ang = rotation + emitter * 0.5
                    local ex = sx + cos(ang) * base_radius * 0.9
                    local ey = base_y + sin(ang) * base_radius * 0.45
                    if flr(time() * 30) % 3 == 0 then
                        for h = 0, 10 do
                            if h % 3 == 0 then pset(ex, ey - h, col) end
                        end
                    end
                end
            end
        end
    end

    -- direction arrow to current target
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
    local sx = cam_offset_x + (arrow_x - arrow_y) * half_tile_width
    local sy = cam_offset_y + (arrow_x + arrow_y) * half_tile_height
    
    -- Adjust for player's altitude
    sy -= player_ship.current_altitude * block_h
    
    -- Calculate arrow rotation in screen space
    -- Account for isometric transformation
    local screen_dx = (dx - dy) * half_tile_width
    local screen_dy = (dx + dy) * half_tile_height
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

function ship.new(start_x, start_y, is_enemy)
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
        body_col = is_enemy and 8 or 12,
        outline_col = 7,
        shadow_col = 1,
        gravity = 0.2,
        max_climb = 3,
        is_hovering = false,
        particle_timer = 0,
        ramp_boost = 0.2,
        -- COMBAT
        is_enemy = is_enemy,
        hp = 100,
        target = nil,
        fire_timer = 0,
        focus = 0,
    }, ship)
end


function ship:ai_update()
    if not player_ship then return end
    
    -- simple chase AI
    local dx = player_ship.x - self.x
    local dy = player_ship.y - self.y
    local dist = sqrt(dx*dx + dy*dy)
    
    if dist > 2 then
        -- normalize and apply movement
        dx = dx / dist * self.accel * 0.7
        dy = dy / dist * self.accel * 0.7
        self.vx += dx
        self.vy += dy
    end
    
    -- shoot if close and facing player
    if dist < 10 then
        self.fire_timer -= 1
        if self.fire_timer <= 0 then
            self:fire_at(player_ship)
            self.fire_timer = 10
        end
    end
end


function ship:update_cursor()
    self.target = nil
    self.focus -= min(2, self.focus)
    
    -- find nearest enemy in front
    local best_dist = 15  -- max targeting range
    for e in all(enemies) do
        local dx = e.x - self.x
        local dy = e.y - self.y
        local dist = sqrt(dx*dx + dy*dy)
        
        if dist < best_dist then
            -- check if roughly in front (simplified dot product)
            local fx = cos(self.angle)
            local fy = sin(self.angle)
            local dot = (dx*fx + dy*fy) / dist
            
            if dot > 0.5 then  -- in front cone
                best_dist = dist
                self.target = e
            end
        end
    end
    
    if self.target then
        self.focus = min(100, self.focus + 5)
    end
end

function ship:fire_at(target)
    if not target or self.hp <= 0 then return end
    
    local dx = target.x - self.x
    local dy = target.y - self.y
    local dist = sqrt(dx*dx + dy*dy)
    
    if dist < 15 then
        -- create projectile
        add(projectiles, {
            x = self.x,
            y = self.y,
            z = self.current_altitude,
            vx = dx/dist * 2,
            vy = dy/dist * 2,
            owner = self,
            life = 30
        })
    end
end


function ship:get_terrain_height_at(x, y)
    local height = tile_manager:get_height_at(flr(x), flr(y))
    return max(0, height)
end

function ship:update()
    if self.is_enemy then
        self:ai_update()
    else
        -- existing player input
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
        
        -- ADD: player shooting with cursor
        self:update_cursor()
        if btn(❎) then
            self:fire_at(self.target)
        end
    end

    local old_x, old_y = self.x, self.y

    self.vx *= self.friction
    self.vy *= self.friction

    local speed = self:get_speed()

    if speed > self.max_speed then
        self.vx *= self.max_speed / speed
        self.vy *= self.max_speed / speed
    end

    self.x += self.vx
    self.y += self.vy

    -- ONLY update tile manager for player ship!
    if not self.is_enemy then
        tile_manager:update_player_position(self.x, self.y)
    end

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
        elseif can_move_y and not can_move_x then
            self.x = old_x
            new_terrain = terrain_y
        else
            self.x, self.y = old_x, old_y
            self.vx, self.vy = self.vx * -0.2, self.vy * -0.2
            new_terrain = current_terrain
            height_diff = 0
            return  -- early return to skip height_diff recalc
        end
        height_diff = new_terrain - current_terrain
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
            local num_particles = 1 + flr(speed * 5)
            self:spawn_particles(num_particles)
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
    local sx = cam_offset_x + (self.x - self.y) * half_tile_width
    local sy = cam_offset_y + (self.x + self.y) * half_tile_height
    sy -= self.current_altitude * block_h
    return sx, sy
end

function ship:get_camera_target()
    local sx, sy = (self.x - self.y) * half_tile_width, (self.x + self.y) * half_tile_height
    sy -= self.current_altitude * block_h
    return 64 - sx, 64 - sy
end

function ship:get_triangle_points()
    local sx, sy = self:get_screen_pos()
    local ship_len = self.size * 0.8
    local fx = sx + cos(self.angle) * ship_len
    local fy = sy + sin(self.angle) * ship_len * 0.5
    local back_angle = self.angle + 0.5
    local blx = sx + cos(back_angle - 0.15) * ship_len
    local bly = sy + sin(back_angle - 0.15) * ship_len * 0.5
    local brx = sx + cos(back_angle + 0.15) * ship_len
    local bry = sy + sin(back_angle + 0.15) * ship_len * 0.5
    return {{fx,fy},{blx,bly},{brx,bry}}, sx, sy
end

function ship:draw()
    local points, sx, sy = self:get_triangle_points()
    
    -- shadow
    local terrain_height = self:get_terrain_height_at(self.x, self.y)
    local shadow_offset = (self.current_altitude - terrain_height) * block_h
    draw_triangle(
        points[1][1], points[1][2] + shadow_offset,
        points[2][1], points[2][2] + shadow_offset,
        points[3][1], points[3][2] + shadow_offset,
        self.shadow_col
    )
    
    -- body
    draw_triangle(
        points[1][1], points[1][2],
        points[2][1], points[2][2],
        points[3][1], points[3][2],
        self.body_col
    )
    
    -- outline
    for i=1,3 do
        local j = i % 3 + 1
        line(points[i][1], points[i][2], points[j][1], points[j][2], self.outline_col)
    end
    
    -- thrusters (simplified)
    if self.is_hovering then
        local c = sin(time() * 5) > 0 and 10 or 9
        pset(points[2][1], points[2][2], c)
        pset(points[3][1], points[3][2], c)
    end
    
    -- cursor/health in one conditional
    if self.is_enemy then
        if self.hp < 100 then
            local w = self.hp / 100 * 10
            rectfill(sx - 5, sy - 10, sx - 5 + w, sy - 9, 8)
        end
    elseif self.target then
        local tsx, tsy = self.target:get_screen_pos()
        local f = self.focus / 100
        local size = 8 - f * 3
        local col = f >= 1 and (flr(time()*10)%2==0 and 10 or 7) or 8
        line(tsx - size, tsy, tsx - size/2, tsy, col)
        line(tsx + size/2, tsy, tsx + size, tsy, col)
        line(tsx, tsy - size/2, tsx, tsy - size/4, col)
        line(tsx, tsy + size/4, tsx, tsy + size/2, col)
    end
end

function ship:get_speed()
    return dist_trig(self.vx, self.vy )
end

function ship:spawn_particles(num, col_override)
    local terrain_h = self:get_terrain_height_at(self.x, self.y)
    local col = col_override or (terrain_h <= 0 and 7 or 0)
    for i = 1, num or 1 do
        local px = self.x + (rnd() - 0.5) * 0.1
        local py = self.y + (rnd() - 0.5) * 0.1
        local ship_z = -self.current_altitude * block_h
        add(particles, particle.new(px, py, ship_z, col))
    end
end

function update_projectiles()
    local new_proj = {}
    for p in all(projectiles) do
        p.x += p.vx
        p.y += p.vy
        p.life -= 1
        
        -- check hits
        local targets = p.owner.is_enemy and {player_ship} or enemies
        for t in all(targets) do
            local dx = t.x - p.x
            local dy = t.y - p.y
            if dx*dx + dy*dy < 0.5 then
                t.hp -= 10
                p.life = 0
                -- death check
                if t.hp <= 0 then
                    if t.is_enemy then
                        del(enemies, t)
                        player_score += 200
                    else
                        -- player death - restart or something
                    end
                end
            end
        end
        
        if p.life > 0 then add(new_proj, p) end
    end
    projectiles = new_proj
end

function draw_projectiles()
    for p in all(projectiles) do
        local sx = cam_offset_x + (p.x - p.y) * half_tile_width
        local sy = cam_offset_y + (p.x + p.y) * half_tile_height - p.z * block_h
        circfill(sx, sy, 1, 10)
    end
end

-- COMBAT EVENT
combat_event = {}
combat_event.__index = combat_event

function combat_event.new()
    local self = setmetatable({
        completed = false,
        success = false,
        wave = 1,
    }, combat_event)
    
    -- spawn enemies
    enemies = {}
    for i = 1, 2 + self.wave do
        local angle = rnd(1)
        local dist = 10 + rnd(5)
        local ex = player_ship.x + cos(angle) * dist
        local ey = player_ship.y + sin(angle) * dist
        local e = ship.new(ex, ey, true)
        e.hp = 50
        add(enemies, e)
    end
    
    return self
end

function combat_event:update()
    -- update enemies
    for e in all(enemies) do
        e:update()
    end
    
    -- check completion
    if #enemies == 0 then
        self.completed = true
        self.success = true
        player_score += 1000
    elseif player_ship.hp <= 0 then
        self.completed = true
        self.success = false
    end
end

function combat_event:is_complete()
    return self.completed
end

function combat_event:draw()
    -- draw enemies
    for e in all(enemies) do
        e:draw()
    end
end

-- TILE CLASS
tile = {}
tile.__index = tile

function tile.new(world_x, world_y)
    local t = setmetatable({
        x = world_x,
        y = world_y,
        height = generate_height_at(world_x, world_y),
        base_sx = (world_x - world_y) * half_tile_width,
        base_sy = (world_x + world_y) * half_tile_height,
        top_col = 3,
        side_col = 1,
        dark_col = 0,
    }, tile)
    t:update_colors()
    return t
end

function get_terrain_color(h)
    local s = "\1\0\0\12\1\1\15\4\2\3\1\0\11\3\1\4\2\0\6\5\0\7\6\5"
    local t = {-2,0,2,6,12,18,24,99}
    for i=1,8 do
        if h <= t[i] then
            local p = (i-1)*3+1
            return ord(s,p), ord(s,p+1), ord(s,p+2)  -- top, side, dark
        end
    end
end

function tile:update_colors()
    self.top_col, self.side_col, self.dark_col = get_terrain_color(self.height)
end

function diamond(sx, sy, c)
    local dx = half_tile_width
    for r = 0, half_tile_height do
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

    -- WATER (ヌ웃さ0): flat diamond + single highlight sweep
    if self.height <= 0 then
        local wc = (self.height <= -2) and 1 or 12
        diamond(sx, sy, wc)
        -- cheap highlight ripple (one line)
        local p = sin(time() * 2 + ((self.x + self.y) << 1) * 0.05)
        local yh = (p >= 0) and 1 or 0
        line(sx - half_tile_width, sy + yh, sx + half_tile_width, sy + yh, (wc == 1) and 12 or 7)
        return
    end

    -- LAND
    local h  = self.height
    local hp = (block_h * h)      -- pixels of side height
    sy -= hp                      -- lift top by side height (fewer ops later)

    -- neighbor occlusion (south/east faces only)
    local s = tile_manager:get_tile(self.x, self.y + 1)
    local e = tile_manager:get_tile(self.x + 1, self.y)
    local draw_s = not s or s.height < h
    local draw_e = not e or e.height < h

    -- SOUTH FACE (left face)
    if draw_s and hp > 0 then
        -- top edge of south face starts at (sx-half_tile_width, sy) to (sx, sy+half_tile_height)
        -- we draw hp slanted scanlines downward
        for i = 0, hp do
        line(sx - half_tile_width, sy + i, sx, sy + half_tile_height + i, self.side_col)
        end
    end

    -- EAST FACE (right face)
    if draw_e and hp > 0 then
        for i = 0, hp do
        line(sx + half_tile_width, sy + i, sx, sy + half_tile_height + i, self.dark_col)
        end
    end

    -- TOP DIAMOND
    diamond(sx, sy, self.top_col)

    -- EXPOSED OUTLINES (only draw whatヌ█▥s visible)
    -- north and west edges matter most in iso; gate on higher/equal neighbors
    local n = tile_manager:get_tile(self.x,     self.y - 1)
    local w = tile_manager:get_tile(self.x - 1, self.y    )

    if (not n) or (n.height <= h) then
        line(sx, sy - half_tile_height, sx + half_tile_width, sy, self.top_col)
    end
    if (not w) or (w.height <= h) then
        line(sx - half_tile_width, sy, sx, sy - half_tile_height, self.top_col)
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
    local new_min_x = self.player_x - view_range
    local new_max_x = self.player_x + view_range
    local new_min_y = self.player_y - view_range
    local new_max_y = self.player_y + view_range

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
    -- keep a window around the player
    local ny1 = self.player_y - view_range * 2
    local ny2 = self.player_y + view_range * 2
    local nx1 = self.player_x - view_range * 2
    local nx2 = self.player_x + view_range * 2

    local new_cache = {}
    for y = ny1, ny2 do
        for x = nx1, nx2 do
            local key = x * 10000 + y
            local h = height_cache[key]
            if h then
                new_cache[key] = h
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
    -- 1) cache lookup - use numeric key
    local key = world_x * 10000 + world_y  -- assumes coords < 10000
    local cached_height = height_cache[key]
    if cached_height then return cached_height end

    -- 2) read current menu values
    local scale = menu_options[1].values[menu_options[1].current]
    local water_level = menu_options[2].values[menu_options[2].current]

    -- 3) normalized coords
    local nx = world_x / scale
    local ny = world_y / scale

    -- 4) continentalness: HUGE blobs that push land up or down
    local cont = perlin2d(nx * 0.03, ny * 0.03, terrain_perm)  -- [-1,1]
    local base = cont * 12  -- INCREASED from 8 to 12 for more variation

    -- 5) terrain detail with better amplitude
    local hdetail = 0
    local amp = 1
    local freq = 1
    local max_amp = 0
    
    for i = 1, 3 do
        hdetail += perlin2d(nx * freq, ny * freq, terrain_perm) * amp
        max_amp += amp
        amp *= 0.5
        freq *= 2
    end
    hdetail /= max_amp  -- [-1,1]
    hdetail *= 10  -- INCREASED from 8 to 10

    -- 6) mountain ridges - MORE AGGRESSIVE
    local rid = perlin2d(nx * 0.5, ny * 0.5, terrain_perm)
    -- Make mountains appear more often (not just when rid > 0)
    rid = abs(rid)  -- Use absolute value for ridge-like mountains
    rid = rid ^ 1.5  -- Less aggressive power (was ^2)
    
    -- Mountains appear when we're above sea level
    local inland = max(0, (cont + 0.5))  -- More lenient inland detection
    local mountain = rid * inland * 20  -- Slightly increased from 18

    -- 7) combine everything
    local height = base + hdetail + mountain

    -- 8) apply water level and expand range before clamping
    height = height - water_level
    
    -- 9) IMPORTANT: Clamp to valid range but with better distribution
    height = clamp(height, -4, 28)
    height = flr(height)

    -- 10) store in cache with numeric key
    height_cache[key] = height
    return height
end


__gfx__
0000000000000000000000000000000000000000000000000000000000000000eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee00000000000000000000000000000000
c0000000c0ccccccccc0ccccccccc0c0ccccccccc0ccccccccc0cc000000c000eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee00000000000000000000000000000000
c0000000c0c0000000c0c0000000c0c000000cc000c0000000c0c0cc0000c000eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee00000000000000000000000000000000
ccccccccc0c0000000c0ccccccccc0c00000c00000c0000000c0c000c000c000eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee00000000000000000000000000000000
c0000000c0c0000000c0c0000cc000c000cc000000c0000000c0c0000cc0c000eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee00000000000000000000000000000000
c0000000c0ccccccccc0c000000cc0c0ccccccccc0ccccccccc0c000000cc000eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee00000000000000000000000000000000
0000000000000000000000000000000000000000000000000000000000000000eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee00000000000000000000000000000000
0000000000000000000000000000000000000000000000000000000000000000eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee00000000000000000000000000000000
0000000000000000000000000000000000000000000000000000000000000000eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee00000000000000000000000000000000
ccccccccc0c000000000c0cccccccc00ccccccccc00000000000000000000000eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee00000000000000000000000000000000
c000000000c000000000c0c0000000c0c0000000000000000000000000000000eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee00000000000000000000000000000000
c00cccccc0c000000000c0c0000000c0cccccccc000000000000000000000000eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee00000000000000000000000000000000
c0000000c0c000000000c0c0000000c0c0000000000000000000000000000000eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee00000000000000000000000000000000
ccccccccc0ccccccccc0c0cccccccc00ccccccccc00000000000000000000000eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee00000000000000000000000000000000
0000000000000000000000000000000000000000000000000000000000000000eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee00000000000000000000000000000000
0000000000000000000000000000000000000000000000000000000000000000eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee00000000000000000000000000000000
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

