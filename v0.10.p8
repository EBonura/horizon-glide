pico-8 cartridge // http://www.pico-8.com
version 41
__lua__
-- HORIZON GLIDE
-- An infinite isometric racing game

-- Helper functions
function dist_trig(dx, dy) local ang = atan2(dx, dy) return dx * cos(ang) + dy * sin(ang) end
function iso(x,y) return cam_offset_x+(x-y)*half_tile_width, cam_offset_y+(x+y)*half_tile_height end


function fmt2(n)
    local s=flr(n*100+0.5)
    local neg=s<0 if neg then s=-s end
    local int=flr(s/100)
    local frac=s%100
    return (neg and "-" or "")..int.."."..(frac<10 and "0"..frac or frac)
end

function draw_triangle(l,t,c,m,r,b,col)
	color(col)
	while t>m or m>b do
		l,t,c,m=c,m,l,t
		while m>b do
			c,m,r,b=r,b,c,m
		end
	end
	local e,j=l,(r-l)/(b-t)
	while m do
		local i=(c-l)/(m-t)
		for t=flr(t),min(flr(m)-1,127) do
			rectfill(l,t,e,t)
			l+=i
			e+=j
		end
		l,t,m,c,b=c,m,b,r
	end
	pset(r,t)
end

-- terrain color lookup tables (top, side, dark triplets; height thresholds)
TERRAIN_PAL_STR = "\1\0\0\12\1\1\15\4\2\3\1\0\11\3\1\4\2\0\6\5\0\7\6\5"
TERRAIN_THRESH  = {-2,0,2,6,12,18,24,99}

function terrain(x, y)
    -- caching
    local key = x..","..y
    local c = cell_cache[key]
    if c then return c[1], c[2], c[3], c[4] end

    -- inline height math
    local scale = menu_options[1].values[menu_options[1].current]
    local water_level = menu_options[2].values[menu_options[2].current]
    local nx, ny = x / scale, y / scale

    local cont = perlin2d(nx * 0.03, ny * 0.03, terrain_perm) * 12

    local hdetail, amp, freq, max_amp = 0, 1, 1, 0
    for i=1,3 do
        hdetail += perlin2d(nx * freq, ny * freq, terrain_perm) * amp
        max_amp += amp
        amp *= 0.5
        freq *= 2
    end
    hdetail = (hdetail / max_amp) * 10

    local rid = perlin2d(nx * 0.5, ny * 0.5, terrain_perm)
    rid = abs(rid) ^ 1.5
    local inland = max(0, (cont/12 + 0.5))
    local mountain = rid * inland * 20

    local h = cont + hdetail + mountain
    h = flr(mid(h - water_level, -4, 28))

    -- inline terrain color lookup
    local top, side, dark
    for i=1,8 do
        if h <= TERRAIN_THRESH[i] then
            local p = (i-1)*3+1
            top  = ord(TERRAIN_PAL_STR, p)
            side = ord(TERRAIN_PAL_STR, p+1)
            dark = ord(TERRAIN_PAL_STR, p+2)
            break
        end
    end

    cell_cache[key] = { top, side, dark, h }
    return top, side, dark, h
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
    -- initialize particle system; reset its list and sync alias
    particle_sys:reset()
    
    -- combat
    enemies = {}
    projectiles = {}
    
    -- camera variables
    cam_offset_x = 64
    cam_offset_y = 64
    
    -- tile system constants
    view_range = 0
    block_h = 2
    half_tile_width = 12
    half_tile_height = 6
    
    -- terrain generation
    last_cache_cleanup = 0
    terrain_perm = nil
    current_seed = 1337

    ws = {} -- water splashes
    
    -- menu configuration (unchanged)
    menu_options = {
        {name="scale", values={8, 10, 12, 14, 16}, current=2},
        {name="water", values={-4, -3, -2, -1, 0, 1, 2, 3, 4}, current=4},
        {name="seed", values={}, current=1, is_seed=true},
        {name="random", is_action=true},  -- shortened name
    }
    
    menu_cursor = 1
    menu_panels = {}
    
    -- initialization sequence
    terrain_perm = generate_permutation(current_seed)
    cell_cache = {}
    tile_manager:init()
    tile_manager:update_player_position(0, 0)
    
    -- set ship altitude
    local terrain_h = player_ship:get_terrain_height_at(0, 0)
    player_ship.current_altitude = terrain_h + player_ship.hover_height
end


function _update()
    if game_state == "startup" then
        -- tick intro timer
        startup_timer += 1

        -- ===== WORLD (startup/customize) =====
        -- autonomous gentle drift
        player_ship.vy = -0.1
        player_ship.y += player_ship.vy

        -- face along motion
        local svx = (player_ship.vx - player_ship.vy)
        local svy = (player_ship.vx + player_ship.vy) * 0.5
        player_ship.angle = atan2(svx, svy)

        -- hover-lock to terrain
        player_ship.current_altitude = player_ship:get_terrain_height_at(player_ship.x, player_ship.y) + player_ship.hover_height
        player_ship.is_hovering = true

        -- keep tiles streaming in intro/customize
        tile_manager:update_player_position(player_ship.x, player_ship.y)

        -- soft ambient particles
        if startup_timer % 3 == 0 then
            player_ship:spawn_particles(1, 0)
        end

        -- camera snaps to ship
        local tx, ty = player_ship:get_camera_target()
        cam_offset_x, cam_offset_y = tx, ty

        -- ===== PHASE-SPECIFIC UI/ANIM =====
        if startup_phase == "title" then
            -- zoom out & seed tiles while expanding
            if startup_view_range < 7 then
                startup_view_range += 0.5
                view_range = flr(startup_view_range)
                tile_manager:update_tiles()
            end

            -- title slide
            if title_x1 < 20 then title_x1 += 6 end
            if title_x2 > 68 then title_x2 -= 6 end

            -- handoff to menu
            if startup_view_range >= 7 and title_x1 >= 20 and title_x2 <= 68 then
                startup_phase = "menu_select"
                init_menu_select()
            end

        elseif startup_phase == "menu_select" then
            update_menu_select()

        elseif startup_phase == "customize" then
            update_customize()
        end

    elseif game_state == "game" then
        if not player_ship.dead then
            -- ===== WORLD (game) =====
            player_ship:update()
            game_manager:update()

            -- camera ease
            local tx, ty = player_ship:get_camera_target()
            cam_offset_x += (tx - cam_offset_x) * 0.3
            cam_offset_y += (ty - cam_offset_y) * 0.3
        else
            -- dead: check for continue
            if btnp(❎) or btnp(🅾️) then
                player_ship.dead = false
                player_ship.hp = 100
                player_ship.x = 0
                player_ship.y = 0
                game_manager.active_panels = {}
                enemies = {}
                projectiles = {}
            end
        end
        -- projectiles / floating text / score tween / cache
        update_projectiles()

        local new_floats = {}
        for f in all(floating_texts) do
            if f:update() then add(new_floats, f) end
        end
        floating_texts = new_floats

        if display_score < player_score then
            local step = flr((player_score - display_score + 9) / 10)
            display_score += (player_score - display_score < 10) and (player_score - display_score) or step
        end
    end

    -- ===== COMMON: advance particle lifetimes & cap =====
    -- use particle system to update and cap particles
    particle_sys:update()
    
    tile_manager:cleanup_cache()
end


function _draw()
    if game_state == "startup" then
        draw_startup()
    elseif game_state == "game" then
        draw_game()
    end
    -- performance monitoring
    printh("mem: "..tostr(stat(0)).." \t| cpu: "..tostr(stat(1)).." \t| fps: "..tostr(stat(7)))
end




function draw_minimap(x, y)
    local ms, wr = 44, 32
    local px_scale = (wr*2/ms)
    local cx, cy = x + ms/2, y + ms/2
    
    -- Background and border
    rectfill(x-1, y-1, x+ms, y+ms, 0)
    
    -- Cache calculations
    local ship_x = player_ship.x
    local ship_y = player_ship.y
    local half_ms = ms/2
    
    -- Draw terrain pixels
    for py = 0, ms-1 do
        local wy_flr = flr(ship_y + (py - half_ms) * px_scale)
        for px = 0, ms-1 do
            local wx_flr = flr(ship_x + (px - half_ms) * px_scale)
            local col = terrain(wx_flr, wy_flr)
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
    palt(0, false)  -- Make sure black (0) is not transparent
    palt(14, true)  -- Make color 14 transparent
    
    -- Now just draw the sprites with embedded shadows
    draw_vertical_wave_sprites(0, title_x1, 10, 8, 1)  -- HORIZON
    draw_vertical_wave_sprites(16, title_x2, 10 + 10, 6, 1)  -- GLIDE
    
    palt()  -- Reset transparency to defaults
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

function draw_startup()
    cls(1)

    draw_world()
    draw_title_sprites()

    -- draw menu selection panels
    if startup_phase == "menu_select" then
        play_panel:draw()
        customize_panel:draw()
    end
    
    -- draw customization interface directly over the world
    if startup_phase == "customize" then
        -- draw all customization panels
        for p in all(customization_panels) do
            p:draw()
        end
        
        -- draw minimap
        draw_minimap(80, 32)
    end
end

function init_menu_select()
    play_panel = panel.new(-50, 90, nil, nil, "play", 11)
    play_panel.selected = true
    play_panel:set_position(50, 90, false)
    
    customize_panel = panel.new(128, 104, nil, nil, "customize", 12)
    customize_panel:set_position(40, 104, false)
end

function update_customize()
    -- update all panels
    for p in all(customization_panels) do
        p:update()
    end
    
    -- navigation
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
    
    -- handle start game button
    if current_panel.is_start then
        if btnp(❎) or btnp(🅾️) then
            view_range = 7
            init_game()
        end
        return
    end
    
    -- get the option this panel represents
    local option_index = current_panel.option_index
    if not option_index then return end
    
    local option = menu_options[option_index]
    
    -- store old value to detect changes
    local old_value = nil
    if option.is_seed then
        old_value = current_seed
    elseif not option.is_action then
        old_value = option.values[option.current]
    end
    
    -- handle value changes
    if option.is_action then
        if btnp(❎) or btnp(🅾️) then
            -- Randomize ALL options
            -- Scale (option 1)
            menu_options[1].current = flr(rnd(#menu_options[1].values)) + 1
            
            -- Water (option 2)
            menu_options[2].current = flr(rnd(#menu_options[2].values)) + 1
            
            -- Seed (option 3)
            current_seed = flr(rnd(9999))
            
            -- Update all panel texts
            for p in all(customization_panels) do
            if p.option_index==1 then
                p.text="⬅️ scale: "..menu_options[1].values[menu_options[1].current].." ➡️"
            elseif p.option_index==2 then
                p.text="⬅️ water: "..menu_options[2].values[menu_options[2].current].." ➡️"
            elseif p.option_index==3 then
                p.text="⬅️ seed: "..current_seed.." ➡️"
            end
            end
            
            regenerate_world_live()
        end
    elseif option.is_seed then
        if btnp(⬅️) then
            current_seed = max(0, current_seed - 1)
            current_panel.text = "⬅️ " .. option.name .. ": " .. current_seed .. " ➡️"
        end
        if btnp(➡️) then
            current_seed = min(9999, current_seed + 1)
            current_panel.text = "⬅️ " .. option.name .. ": " .. current_seed .. " ➡️"
        end
    else
        if btnp(⬅️) then
            option.current -= 1
            if option.current < 1 then option.current = #option.values end
            current_panel.text = "⬅️ " .. option.name .. ": " .. tostr(option.values[option.current]) .. " ➡️"
        end
        if btnp(➡️) then
            option.current += 1
            if option.current > #option.values then option.current = 1 end
            current_panel.text = "⬅️ " .. option.name .. ": " .. tostr(option.values[option.current]) .. " ➡️"
        end
    end
    
    -- check if value changed and regenerate world if so
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
    cell_cache = {}
    
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
    local y_spacing = 12
    local panel_index = 0
    local delay_step = 2  -- frames between each panel animation start
    
    for i, option in ipairs(menu_options) do
        if not option.is_action then
            local y = y_start + panel_index * y_spacing
            -- Arrows on far sides
            local text = "⬅️ " .. option.name .. ": " .. 
                (option.is_seed and current_seed or tostr(option.values[option.current])) .. " ➡️"
            
            local p = panel.new(-60, y, 66, 9, text, 6)
            p.option_index = i
            p.anim_delay = panel_index * delay_step  -- stagger the animations
            p:set_position(6, y, false)
            add(customization_panels, p)
            panel_index += 1
        end
    end
    
    -- randomize button with delay
    local rp = panel.new(-60, y_start + 3 * y_spacing, 66, 9, "random", 5)
    rp.option_index = 4
    rp.anim_delay = panel_index * delay_step  -- continue the stagger
    rp:set_position(6, y_start + 3 * y_spacing, false)
    add(customization_panels, rp)
    
    -- start button - slides up last with extra delay
    local sb = panel.new(50, 128, nil, 12, "play", 11)
    -- play_panel = panel.new(-50, 90, nil, nil, "play", 11)

    sb.is_start = true
    sb.anim_delay = (panel_index + 1) * delay_step + 4  -- extra delay for emphasis
    sb:set_position(50, 105, false)
    add(customization_panels, sb)
    
    customization_panels[1].selected = true
end



-- GAME FUNCTIONS
function init_game()
    game_state = "game"
    
    -- 𝘳eset scores/ui
    player_score, display_score = 0, 0
    floating_texts = {}
    -- reset particle system
    particle_sys:reset()
    
    -- 𝘯need to reset 𝘴hip state for game mode
    game_manager = game_manager.new()
    
    -- prevent immediate shooting
    player_ship.last_shot_time = time()
    
    -- 𝘶pdate tiles for full view range
    tile_manager:update_player_position(player_ship.x, player_ship.y)
    
    -- 𝘦nsure altitude is correct
    player_ship.current_altitude = player_ship:get_terrain_height_at(player_ship.x, player_ship.y) + player_ship.hover_height
    last_cache_cleanup = time()
end

function draw_ws()
    local nxt={}
    for s in all(ws) do
        s.r+=0.18 s.life-=1
        local last=nil
        for a=0,1,0.06 do
            local wx=s.x+cos(a)*s.r
            local wy=s.y+sin(a)*s.r
            local _,_,_,h=terrain(flr(wx),flr(wy))
            if h<=0 then
                local px,py=iso(wx,wy)
                -- connect short segments so it reads as a circle, not particles
                if last then line(last[1],last[2],px,py,(h<=-2) and 12 or 7) end
                last={px,py}
            else
                last=nil -- break at land edges
            end
        end
        if s.life>0 then add(nxt,s) end
    end
    ws=nxt
end


function draw_world()
    -- water first
    for t in all(tile_manager.tile_list) do if t.height<=0 then t:draw() end end
    -- rings on top of water
    draw_ws()
    -- land on top (hides any ring bits near shore)
    for t in all(tile_manager.tile_list) do if t.height>0 then t:draw() end end

    particle_sys:draw(cam_offset_x,cam_offset_y)
    if not player_ship.dead then player_ship:draw() end
end



function draw_game()
    cls(1)
    
    draw_world()
    
    -- DRAW PROJECTILES
    draw_projectiles()
    
    -- 3. Draw game events (circles, beacons, etc - but NOT their UI panels)
    if game_manager.state == "active" and game_manager.current_event then
        game_manager.current_event:draw()
    end

    -- Draw Cursor
    if player_ship.target and player_ship.target.get_screen_pos then
        local tsx, tsy = player_ship.target:get_screen_pos()
        rect(tsx - 8, tsy - 8, tsx + 8, tsy + 8, 8)  -- red square
    end
        
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
    local filled=flr(value*15/max_value)
    for i=0,14 do
        local s=x+i*4
        rectfill(s,y,s+2,y+2,(i<filled) and filled_col or empty_col)
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

function panel.new(x, y, w, h, text, col, life)
    return setmetatable({
        x = x,
        y = y,
        w = w or (#text*4+12),
        h = h or 10,
        text = text,
        col = col or 5,
        selected = false,
        expand = 0,
        target_x = x,
        target_y = y,
        life = life or -1,  -- -1 means infinite
        anim_delay = 0,
    }, panel)
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
    -- handle animation delay
    if self.anim_delay > 0 then
        self.anim_delay -= 1
        return true  -- don't move yet, just countdown
    end
    
    -- smooth movement (fixed speed of 0.2)
    if self.x != self.target_x or self.y != self.target_y then
        self.x += (self.target_x - self.x) * 0.2
        self.y += (self.target_y - self.y) * 0.2
        
        -- snap when close
        if abs(self.x - self.target_x) < 0.5 then self.x = self.target_x end
        if abs(self.y - self.target_y) < 0.5 then self.y = self.target_y end
    end

    -- expand/contract when selected
    if self.selected then
        self.expand = min(self.expand + 1, 3)
    else
        self.expand = max(self.expand - 1, 0)
    end
    
    -- handle life countdown
    if self.life > 0 then
        self.life -= 1
        return self.life > 0
    elseif self.life == 0 then
        return false
    end

    return true
end

-- draw function remains the same
function panel:draw()
    -- calculate position with expand and pulse
    local dx = self.x - self.expand
    local dy = self.y
    local dw = self.w + self.expand * 2
    local dh = self.h

    -- pulse when selected (fixed speed and amount)
    if self.selected then
        local pulse = sin(time() * 6) * 1
        dx -= pulse / 2
        dy -= pulse / 2
        dw += pulse
        dh += pulse
    end

    -- black background
    rectfill(dx, dy, dx + dw, dy + dh, 0)

    -- full border (always 1 pixel)
    rect(dx - 1, dy - 1, dx + dw, dy + dh, self.col)

    -- centered text
    local text_x = dx + (dw - #self.text * 4) / 2
    local text_y = dy + (dh - 5) / 2
    
    -- use panel color when selected, white otherwise
    print(self.text, text_x, text_y, self.selected and self.col or 7)
end

-- PARTICLE SYSTEM
particle = {}
particle.__index = particle

function particle.new(x, y, z, col, behavior)
    local p = {
        x = x,
        y = y,
        z = z,
        vx = (rnd() - 0.5) * 0.05,
        vy = (rnd() - 0.5) * 0.05,
        vz = -rnd() * 0.3 - 0.2,
        life = 20 + rnd(10),
        max_life = 30,
        col = col,
        size = 1 + rnd(1),
        behavior = behavior or "smoke"  -- default is smoke
    }
    
    -- Explosion setup - spread out fast then slow down
    if behavior == "explosion" then
        local angle = rnd()
        local speed = 1 + rnd(2)  -- fast initial speed
        p.vx = cos(angle) * speed
        p.vy = sin(angle) * speed
        p.vz = (rnd() - 0.5) * 2  -- some go up, some down
        p.life = 20 + rnd(10)
        p.max_life = 30
        p.size = 1 + rnd(2)
        -- cycle through explosion colors: white->yellow->orange->red
        p.col = ({7, 10, 9, 8})[flr(rnd(4)) + 1]
    end
    
    return setmetatable(p, particle)
end

function particle:update()
    self.x += self.vx
    self.y += self.vy
    self.z += self.vz

    if self.behavior == "explosion" then
        -- explosion particles slow down quickly
        self.vx *= 0.85
        self.vy *= 0.85
        self.vz *= 0.9
        -- and fall after initial burst
        self.vz -= 0.1
    else
        -- smoke behavior (your existing code)
        -- particles just go up, no gravity
        -- slight deceleration
        self.vz *= 0.95
        -- apply drag
        self.vx *= 0.9
        self.vy *= 0.9
    end

    self.life -= 1
    return self.life > 0
end

function particle:draw(cam_x, cam_y)
    -- convert to screen coordinates
    local sx,sy = iso(self.x,self.y) sy+=self.z

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

-- particle system: manages particle list without instantiation
particle_sys = {particles={}}

-- reset the particle list and keep the global alias in sync
function particle_sys:reset()
    self.particles = {}
end

-- spawn multiple particles with optional count (defaults to 1)
function particle_sys:spawn(x, y, z, col, num)
    local n = num or 1
    for i=1,n do
        local px = x + (rnd() - 0.5) * 0.1
        local py = y + (rnd() - 0.5) * 0.1
        add(self.particles, particle.new(px, py, z, col, "smoke"))
    end
end

function particle_sys:explode(x, y, z, size)
    for i=1,size do
        add(self.particles, particle.new(x, y, z, nil, "explosion"))
    end
end

-- update particles, remove dead ones and enforce a maximum count
function particle_sys:update()
    local np = {}
    for p in all(self.particles) do
        if p:update() then add(np, p) end
    end
    self.particles = np
    while #self.particles > 100 do
        deli(self.particles,1)
    end
end

-- draw particles relative to the camera
function particle_sys:draw(cx, cy)
    for p in all(self.particles) do
        p:draw(cx, cy)
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
        -- event_types = {"circles", "combat"},
        event_types = {"combat"},

        active_panels = {},
        next_event_index = 1,

        -- difficulty progression (flat vars)
        difficulty_circle_round   = 0,
        difficulty_rings_base     = 3,
        difficulty_rings_step     = 1,
        difficulty_base_time      = 5,
        difficulty_recharge_start = 2,
        difficulty_recharge_step  = 0.2,
        difficulty_recharge_min   = 0.5,
        
        -- combat difficulty
        difficulty_combat_round = 0,
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
            if self.current_event.completed then
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
    local event_type = self.event_types[self.next_event_index]
    self.next_event_index = self.next_event_index % #self.event_types + 1

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
    
    local message = success and "eVENT cOMPLETE!" or "eVENT fAILED!"
    local col = success and 11 or 8
    
    local cp = panel.new(30, 90, nil, nil, message, col, 90)
    cp:set_position(30, 105, false)
    cp.selected = success

    self:add_panel(cp)
    
    -- increase difficulty only if success
    if success then
        if self.current_event and self.current_event.is_combat then
            self.difficulty_combat_round += 1
        else
            self.difficulty_circle_round += 1
        end
    end
    
    self.current_event = nil
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
    self.instruction_panel = panel.new(20, 4, nil, nil,"reach all "..#self.circles.." circles!", 8)
    game_manager:add_panel(self.instruction_panel)

    self.timer_panel = panel.new(48, 16, 40, nil, "0.00s", 5)
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
        self.timer_panel.text = fmt2(max(0, time_left)).."S"
    end

    -- check current ring
    local circle = self.circles[self.current_target]
    if circle and not circle.collected then
        local dx, dy = player_ship.x - circle.x, player_ship.y - circle.y
        local dist = dist_trig(dx, dy)

        if dist < circle.radius then
            circle.collected = true
            sfx(61)

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
                    self.instruction_panel.text = remaining.." circle"..(remaining>1 and "s" or "").." left"
                end
            end
        end
    end
end


function circle_event:draw()
    for i, circle in ipairs(self.circles) do
        if not circle.collected then
            local sx,sy = iso(circle.x,circle.y)
            local _,_,_,terrain_h = terrain(flr(circle.x), flr(circle.y))
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
    draw_arrow_to(target.x, target.y, player_ship.x, player_ship.y, 8, 1.5)
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
        max_speed = is_enemy and 0.4 or 0.5,
        size = 10,
        body_col = is_enemy and 8 or 12,
        outline_col = 7,
        shadow_col = 1,
        gravity = 0.2,
        max_climb = 3,
        is_hovering = false,
        particle_timer = 0,
        ramp_boost = 0.2,
        -- combat
        is_enemy = is_enemy,
        max_hp = is_enemy and 50 or 100,  -- <-- ADD THIS
        hp = is_enemy and 50 or 100,      -- <-- UPDATE THIS
        target = nil,
        fire_timer = 0,
        focus = 0,
        ai_phase = is_enemy and rnd(4) or 0,
    }, ship)
end


-- Modify ship:ai_update()
function ship:ai_update()
    if not player_ship then return end

    -- base vector to player
    local dx = player_ship.x - self.x
    local dy = player_ship.y - self.y
    local dist = dist_trig(dx, dy)
    
    -- determine AI mode based on health and distance
    local mode -- true = chase, false = flee
    
    if self.hp <= 30 then
        -- low health: flee, but not if already too far
        mode = dist > 15  -- if too far, approach instead
    elseif dist > 20 then
        -- very far: always approach
        mode = true
    else
        -- middle range: toggle between chase/flee every 2 seconds
        mode = (flr(time() + self.ai_phase) % 6) < 3
    end
    
    -- flip direction for fleeing
    if not mode then
        dx, dy = -dx, -dy
    end

    -- separation from other enemies
    for e in all(enemies) do
        if e ~= self then
            local ex, ey = self.x - e.x, self.y - e.y
            local d = dist_trig(ex, ey)
            if d < 4 then
                local w = 4 - d
                dx += ex * w
                dy += ey * w
            end
        end
    end

    -- apply movement
    local m = dist_trig(dx, dy)
    if m > 0.1 then
        local a = self.accel * 0.7 / m
        self.vx += dx * a
        self.vy += dy * a
    end

    -- update targeting (shared logic)
    local has_target = self:update_targeting()
    
    -- fire when chasing and have a valid target (not when fleeing)
    if mode and has_target then
        self.fire_timer -= 1
        if self.fire_timer <= 0 then
            self:fire_at()
            self.fire_timer = 10
        end
    end
end

function ship:update_cursor()
    self.focus -= min(2, self.focus)
    
    -- find nearest enemy in front
    local best_dist = 15  -- max targeting range
    local found_enemy = nil
    for e in all(enemies) do
        local dx, dy = e.x - self.x, e.y - self.y
        local dist = dist_trig(dx, dy)
        
        if dist < best_dist then
            -- check if roughly in front (simplified dot product)
            local fx = cos(self.angle)
            local fy = sin(self.angle)
            local dot = (dx*fx + dy*fy) / max(0.0001, dist)
            
            if dot > 0.5 then  -- in front cone
                best_dist = dist
                found_enemy = e
            end
        end
    end
    
    if found_enemy then
        self.target = found_enemy
        self.focus = min(100, self.focus + 5)
    else
        -- No enemy - target a point in front
        local world_angle = atan2(self.vx, self.vy)
        self.target = {
            x = self.x + cos(world_angle) * 10,
            y = self.y + sin(world_angle) * 10
        }
    end
end

function ship:fire_at()
    if not self.target then return end  -- safety check
    
    local dx, dy = self.target.x - self.x, self.target.y - self.y
    local dist = dist_trig(dx, dy)
    
    if dist < 15 then
        -- create projectile with ship velocity + projectile velocity
        add(projectiles, {
            x = self.x,
            y = self.y,
            z = self.current_altitude,
            vx = self.vx + dx/dist * 0.5,  -- ship velocity + projectile velocity
            vy = self.vy + dy/dist * 0.5,
            life = 30,
            owner = self,
        })
        sfx(63)
    end
end


function ship:get_terrain_height_at(x, y)
    local _,_,_,h = terrain(x, y)
    return max(0, h)
end

function ship:update_targeting()
    self.focus -= min(2, self.focus)
    
    -- determine potential targets based on who we are
    local targets = self.is_enemy and {player_ship} or enemies
    
    -- find best target in front cone
    local best_dist = 15  -- max targeting range
    local found_target = nil
    
    for t in all(targets) do
        local dx, dy = t.x - self.x, t.y - self.y
        local dist = dist_trig(dx, dy)
        
        if dist < best_dist then
            -- check if roughly in front (simplified dot product)
            local fx = cos(self.angle)
            local fy = sin(self.angle)
            local dot = (dx*fx + dy*fy) / max(0.0001, dist)
            
            if dot > 0.5 then  -- in front cone (120°)
                best_dist = dist
                found_target = t
            end
        end
    end
    
    if found_target then
        self.target = found_target
        self.focus = min(100, self.focus + 5)
        return true  -- we have a valid target
    else
        -- no valid target - for player, target a point in front
        if not self.is_enemy then
            local world_angle = atan2(self.vx, self.vy)
            self.target = {
                x = self.x + cos(world_angle) * 10,
                y = self.y + sin(world_angle) * 10
            }
        else
            self.target = nil
        end
        return false  -- no valid target
    end
end

function ship:update()
    if self.is_enemy then
        self:ai_update()
    else
        tile_manager:update_player_position(self.x, self.y)

        -- existing player input
        local input_x, input_y = 0, 0

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
        
        -- update targeting (shared logic)
        self:update_targeting()
        
        -- player shooting
        if btn(❎) then
            if not self.last_shot_time then self.last_shot_time = 0 end
            if time() - self.last_shot_time > 0.1 then
                self:fire_at()
                self.last_shot_time = time()
            end
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

    local current_terrain = self:get_terrain_height_at(old_x, old_y)
    local new_terrain = self:get_terrain_height_at(self.x, self.y)
    local height_diff = new_terrain - current_terrain

    -- Check if we hit a wall that's too steep
    if height_diff > self.max_climb then
        local can_move_x, can_move_y = false, false
        
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
        self.vz = height_diff * self.ramp_boost * speed * 10
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

    -- expanding water rings only when moving fast enough
    if self.is_hovering and self:get_speed() > 0.2 and self:get_terrain_height_at(self.x,self.y) <= 0 then
        self.st = (self.st or 0) + 1
        if self.st > 3 then
            add(ws, {x=self.x, y=self.y, r=0, life=28})
            self.st = 0
        end
    end
end

function ship:get_screen_pos()
    local sx,sy=iso(self.x,self.y)
    sy -= self.current_altitude * block_h
    return sx, sy
end

function ship:get_camera_target()
    local sx,sy = (self.x - self.y) * half_tile_width, (self.x + self.y) * half_tile_height
    sy -= self.current_altitude * block_h
    
    -- camera focus on nearest enemy when close
    if not self.is_enemy then
        local ne, nd = nil, 10  -- max focus distance
        for e in all(enemies) do
            local d = dist_trig(e.x - self.x, e.y - self.y)
            if d < nd then ne, nd = e, d end
        end
        if ne then
            -- midpoint between player and enemy
            local mx, my = (self.x + ne.x) * 0.5, (self.y + ne.y) * 0.5
            sx = (mx - my) * half_tile_width
            sy = (mx + my) * half_tile_height - self.current_altitude * block_h
        end
    end
    
    return 64 - sx, 64 - sy
end

function ship:get_triangle_points()
    local sx, sy = self:get_screen_pos()
    local ship_len = self.size * 0.8
    local fx, fy = sx + cos(self.angle) * ship_len, sy + sin(self.angle) * ship_len * 0.5
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
    
    -- thrusters
    if self.is_hovering then
        local c = sin(time() * 5) > 0 and 10 or 9
        pset(points[2][1], points[2][2], c)
        pset(points[3][1], points[3][2], c)
    end
    
    -- enemy health bar only
    if self.is_enemy then
        local w = self.hp / self.max_hp * 10
        rectfill(sx - 5, sy - 10, sx + 5, sy - 9, 5)  -- grey background
        rectfill(sx - 5, sy - 10, sx - 5 + w, sy - 9, 8)  -- red health
    end
end

function ship:get_speed()
    return dist_trig(self.vx, self.vy)
end

function ship:spawn_particles(num, col_override)
    -- spawn exhaust particles at the ship's position
    particle_sys:spawn(
        self.x, self.y,
        -self.current_altitude * block_h,
        col_override or (self:get_terrain_height_at(self.x,self.y) <= 0 and 7 or 0),
        num
    )
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
                -- apply damage
                t.hp -= 5
                p.life = 0
                
                -- SMALL EXPLOSION when projectile hits
                particle_sys:explode(p.x, p.y, 
                    -t.current_altitude * block_h, 
                    10)  -- 10 particles for hit
                
                -- death check
                if t.hp <= 0 then
                    sfx(62)  -- play death sound
                    
                    -- BIG EXPLOSION when ship dies
                    particle_sys:explode(t.x, t.y, 
                        -t.current_altitude * block_h, 
                        20)  -- 20 particles for death
                    
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
        local sx,sy = iso(p.x,p.y) sy-=p.z*block_h
        circfill(sx, sy, 2, 0)
        circfill(sx, sy, 1, p.owner.is_enemy and 8 or 12)  -- red for enemies, blue for player
    end
end

-- COMBAT EVENT
combat_event = {}
combat_event.__index = combat_event

function combat_event.new()
    local self = setmetatable({
        completed = false,
        success = false,
        instruction_panel = nil,
        start_count = 0,
        switched = false,
        is_combat = true  -- marker for difficulty tracking
    }, combat_event)

    -- intro banner
    self.instruction_panel = panel.new(64 - 50, 4, nil, nil, "enemy wave incoming!", 8)
    game_manager:add_panel(self.instruction_panel)

    -- progressive difficulty: 2 + round number, max 6
    local num_enemies = min(2 + game_manager.difficulty_combat_round, 6)
    
    enemies = {}
    for i=1,num_enemies do
        local a, d = rnd(1), 10 + rnd(5)
        local ex = player_ship.x + cos(a) * d
        local ey = player_ship.y + sin(a) * d
        local e  = ship.new(ex, ey, true)
        e.hp = 50
        add(enemies, e)
    end

    self.start_count = #enemies
    return self
end

function combat_event:update()
    -- update enemies
    for e in all(enemies) do
        e:update()
    end

    local remaining = #enemies

    -- wave cleared ヌ●★ finish (no "0 enemies left" flash)
    if remaining == 0 then
        self.completed, self.success = true, true
        player_score += 1000
        if self.instruction_panel then
            game_manager:remove_panel(self.instruction_panel)
            self.instruction_panel = nil
        end
        return
    end

    -- switch text only after first kill, then keep it updated
    if self.instruction_panel then
        if (not self.switched) and remaining < self.start_count then
            self.switched = true
        end
        if self.switched then
            self.instruction_panel.text =
                (remaining == 1) and "1 enemy left" or (remaining.." enemies left")
        end
    end

    -- player death ヌ●★ game over
    if player_ship.hp <= 0 then
        self.completed, self.success = true, false
        player_ship.dead = true
        game_manager.active_panels = {}
        local gop = panel.new(44, 50, nil, nil, "game over", 8)
        game_manager:add_panel(gop)
        local cp = panel.new(24, 80, nil, nil, "press ❎ to restart", 8, 90)
        game_manager:add_panel(cp)
        if self.instruction_panel then
            game_manager:remove_panel(self.instruction_panel)
            self.instruction_panel = nil
        end
        return
    end
end

function combat_event:draw()
    for e in all(enemies) do
        e:draw()
        draw_arrow_to(e.x, e.y, player_ship.x, player_ship.y, 8, 1.5)
    end
end



function draw_arrow_to(target_x, target_y, source_x, source_y, col, orbit_dist)
    local dx, dy = target_x - source_x, target_y - source_y
    if dist_trig(dx, dy) < 2 then return end
    local angle = atan2(dx, dy)
    
    local arrow_x = source_x + cos(angle) * orbit_dist
    local arrow_y = source_y + sin(angle) * orbit_dist
    
    local sx,sy = iso(arrow_x,arrow_y)
    sy -= player_ship.current_altitude * block_h
    
    local screen_dx, screen_dy = (dx - dy) * half_tile_width, (dx + dy) * half_tile_height
    local screen_angle = atan2(screen_dx, screen_dy)
    
    local arrow_size = 6
    local tip_x = sx + cos(screen_angle) * arrow_size
    local tip_y = sy + sin(screen_angle) * arrow_size * 0.5
    
    local back_angle = screen_angle + 0.5
    local back1_x = sx + cos(back_angle - 0.18) * arrow_size * 0.7
    local back1_y = sy + sin(back_angle - 0.18) * arrow_size * 0.35
    local back2_x = sx + cos(back_angle + 0.18) * arrow_size * 0.7
    local back2_y = sy + sin(back_angle + 0.18) * arrow_size * 0.35
    
    draw_triangle(tip_x, tip_y, back1_x, back1_y, back2_x, back2_y, col)
end

-- TILE CLASS
tile = {}
tile.__index = tile

function tile.new(x,y)
    local top, side, dark, h = terrain(x,y)
    local bsx, bsy=(x-y)*half_tile_width, (x+y)*half_tile_height
    local hp=(h>0) and (h*block_h) or 0

    -- one-time neighbor checks
    local _,_,_,h_s = terrain(x,   y+1)
    local _,_,_,h_e = terrain(x+1, y  )
    local _,_,_,h_n = terrain(x,   y-1)
    local _,_,_,h_w = terrain(x-1, y  )

    local face=((h_s<h) and 1 or 0) + ((h_e<h) and 2 or 0)
    local out =((h_n<=h) and 1 or 0) + ((h_w<=h) and 2 or 0)

    return setmetatable({
        x=x,y=y,height=h,
        top_col=top, side_col=side, dark_col=dark,
        base_sx=bsx, base_sy=bsy,
        hp=hp, face=face, out=out,
        r=(x+y)&1,
        lb=bsx-half_tile_width,
        rb=bsx+half_tile_width,
        by=bsy+half_tile_height
    }, tile)
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
    local sx, sy=cam_offset_x+self.base_sx, cam_offset_y+self.base_sy

    -- WATER: top diamond + 1-line ripple
    if self.height<=0 then
        local c=(self.height<=-2) and 1 or 12
        diamond(sx,sy,c)
        -- slow vertical wobble with per-tile phase
        local yb=flr(sy+self.r+sin(time()+(self.x+self.y)/8))
        line(cam_offset_x+self.lb, yb, cam_offset_x+self.rb, yb, (c==1) and 12 or 7)
        return
    end

    -- LAND: V4 (anchored 2 loops), then top + outlines
    local hp=self.hp
    local sy2=sy-hp
    local by=cam_offset_y+self.by-hp
    local lx=cam_offset_x+self.lb
    local rx=cam_offset_x+self.rb
    local m=self.face

    if (m&1)>0 then for i=0,hp do line(lx,sy2+i, sx,by+i, self.side_col) end end -- south
    if (m&2)>0 then for i=0,hp do line(rx,sy2+i, sx,by+i, self.dark_col) end end -- east

    diamond(sx,sy2,self.top_col)
end



-- TILE MANAGER
tile_manager = {
    tiles = {},
    tile_list = {},
    min_x = 0,
    min_y = 0,
    max_x = 0,
    max_y = 0,
}


function tile_manager:init()
    self.tiles = {}
    self.tile_list = {}
    self.min_x, self.max_x, self.min_y, self.max_y = 0,0,0,0
    self.player_x, self.player_y = self.player_x or 0, self.player_y or 0
    self.dx_pending, self.dy_pending = 0, 0
    self.view_range_cached = view_range
end

function tile_manager:add_tile(x,y)
    if not self.tiles[x] then self.tiles[x]={} end
    if not self.tiles[x][y] then
        local t=tile.new(x,y)
        self.tiles[x][y]=t
        -- Insert sorted
        local k=t.x+t.y
        local i=#self.tile_list
        while i>0 and (self.tile_list[i].x+self.tile_list[i].y)>k do i-=1 end
        add(self.tile_list,t,i+1)
    end
end

function tile_manager:remove_tile(x, y)
    if self.tiles[x] and self.tiles[x][y] then
        local t = self.tiles[x][y]
        del(self.tile_list, t)
        self.tiles[x][y] = nil
        
        -- Clean up empty columns
        if not next(self.tiles[x]) then self.tiles[x]=nil end
    end
end

function tile_manager:update_player_position(px, py)
    local nx, ny = flr(px), flr(py)
    local ox, oy = self.player_x or nx, self.player_y or ny
    if nx == ox and ny == oy then return end
    self.dx_pending, self.dy_pending = nx - ox, ny - oy
    self.player_x, self.player_y = nx, ny
    self:update_tiles()
end

function tile_manager:update_tiles()
    local nminx, nminy = self.player_x - view_range, self.player_y - view_range
    local nmaxx, nmaxy = self.player_x + view_range, self.player_y + view_range
    local first_fill = #self.tile_list == 0  -- UNCOMMENT THIS LINE
    local range_changed = self.view_range_cached ~= view_range

    -- first fill or view range changed: do a full (rare) rebuild
    if first_fill or range_changed then
        for x=nminx,nmaxx do
            for y=nminy,nmaxy do 
                self:add_tile(x,y) 
            end
        end
        self.min_x, self.max_x, self.min_y, self.max_y = nminx, nmaxx, nminy, nmaxy
        self.view_range_cached = view_range
        self.dx_pending, self.dy_pending = 0, 0
        return
    end

    local dx, dy = self.dx_pending or 0, self.dy_pending or 0
    if dx == 0 and dy == 0 then return end

    -- moved in x?
    if dx > 0 then
        for y=nminy,nmaxy do self:add_tile(nmaxx, y) end
        for y=self.min_y,self.max_y do self:remove_tile(self.min_x, y) end
    elseif dx < 0 then
        for y=nminy,nmaxy do self:add_tile(nminx, y) end
        for y=self.min_y,self.max_y do self:remove_tile(self.max_x, y) end
    end

    -- moved in y?
    if dy > 0 then
        for x=nminx,nmaxx do self:add_tile(x, nmaxy) end
        for x=self.min_x,self.max_x do self:remove_tile(x, self.min_y) end
    elseif dy < 0 then
        for x=nminx,nmaxx do self:add_tile(x, nminy) end
        for x=self.min_x,self.max_x do self:remove_tile(x, self.max_y) end
    end

    self.min_x, self.max_x, self.min_y, self.max_y = nminx, nmaxx, nminy, nmaxy
    self.dx_pending, self.dy_pending = 0, 0
end


function tile_manager:cleanup_cache()
    if time() - last_cache_cleanup > 1 then
        -- cover tiles AND minimap
        local tile_r = view_range * 2
        local mini_r = 36  -- wr(32) + margin
        local R = max(tile_r, mini_r)


        local x1, y1 = self.player_x - R, self.player_y - R
        local x2, y2 = self.player_x + R, self.player_y + R

        local new_cache = {}
        for k,c in pairs(cell_cache) do
            -- k is "x,y"
            local parts = split(k, ",", true) -- convert_numbers=true
            local x, y = parts[1], parts[2]
            if x>=x1 and x<=x2 and y>=y1 and y<=y2 then
                new_cache[k] = c
            end
        end
        cell_cache = new_cache
        last_cache_cleanup = time()
    end
end




-- TERRAIN GENERATION
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




__gfx__
000eeeee000000000000000000000000000000000000000000000000eeee000eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee
0c0eeeee0c0ccccccccc0ccccccccc0c0ccccccccc0ccccccccc0cc00eee0c0eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee
0c0000000c0c0000000c0c0000000c0c000000cc000c0000000c0c0cc0ee0c0eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee
0ccccccccc0c0eeeee0c0ccccccccc0c0e000c00ee0c0eeeee0c0c000c000c0eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee
0c0000000c0c0000000c0c0000cc000c000cc000000c0000000c0c0ee0cc0c0eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee
0c0eeeee0c0ccccccccc0c0ee000cc0c0ccccccccc0ccccccccc0c0eee00cc0eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee
000eeeee000000000000000eeee0000000000000000000000000000eeeee000eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee
eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee
0000000000000eeeeeee000000000000e0000000000eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee
0ccccccccc0c0eeeeeee0c0cccccccc00ccccccccc0eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee
0c000000000c0eeeeeee0c0c0000000c0c000000000eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee
0c00cccccc0c0eeeeeee0c0c0eeeee0c0cccccccc0eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee
0c0000000c0c000000000c0c0000000c0c000000000eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee
0ccccccccc0ccccccccc0c0cccccccc00ccccccccc0eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee
00000000000000000000000000000000e0000000000eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee
eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee
eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee
eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee
eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee
eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee
eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee
eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee
eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee
eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee
eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee
eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee
eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee
eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee
eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee
eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee
eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee
eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee
eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee
eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee
eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee
eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee
eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee
eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee
eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee
eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee
eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee
eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee
eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee
eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee
eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee
eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee
eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee
eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee
eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee
eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee
eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee
eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee
eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee
eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee
eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee
eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee
eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee
eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee
eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee
eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee
eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee
eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee
eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee
eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee
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
001000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
001000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
001000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
001000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
001000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
001000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
001000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
001000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
001000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
001000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
001000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
001000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
001000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
001000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
001000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
001000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
001000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
001000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
001000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
001000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
001000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
001000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
001000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
001000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
001000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
001000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
001000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
001000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
000200000375005750087500c750127501a7501e750257502f7503a7503f750007000070000700007000070000700007000070000700007000070000700007000070000700007000070000700007000070000700
000500003b650356502f6502965025650206501c6501765013650116500f6500d6500c6500a650096500965008650076500765006650056600465004650036400264002640016300063000630006200061000600
150100003f66033660256601d660146600e6600b660086600766006660056600566005660046600466003660036600566008660096603d6000060000600006000060000600006000060000600006000060000600
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

