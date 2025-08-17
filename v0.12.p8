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
    return (neg and "-" or "")..flr(s/100).."."..((s%100<10) and "0" or "")..(s%100)
end

function draw_triangle(l,t,c,m,r,b,col)
    color(col)
    while t>m or m>b do
        l,t,c,m=c,m,l,t
        while m>b do c,m,r,b=r,b,c,m end
    end
    local e,j=l,(r-l)/(b-t)
    while m do
        local i=(c-l)/(m-t)
        for t=flr(t),min(flr(m)-1,127) do
            line(l,t,e,t)
            l+=i e+=j
        end
        l,t,m,c,b=c,m,b,r
    end
    pset(r,t)
end


-- terrain color lookup tables (top, side, dark triplets; height thresholds)
TERRAIN_PAL_STR = "\1\0\0\12\1\1\15\4\2\3\1\0\11\3\1\4\2\0\6\5\0\7\6\5"
TERRAIN_THRESH  = {-2,0,2,6,12,18,24,99}

function terrain(x,y)
    -- cache hit ヌ●★ return 4-tuple fast
    local key=x..","..y
    local c=cell_cache[key]
    if c then return unpack(c) end

    -- scaled coords + base continentalness
    local scale=menu_options[1].values[menu_options[1].current]
    local water_level=menu_options[2].values[menu_options[2].current]
    local nx,ny=x/scale,y/scale
    local cont=perlin2d(nx*0.03,ny*0.03,terrain_perm)*12

    -- 3-octave detail
    local hdetail,amp,freq,max_amp=0,1,1,0
    for i=1,3 do
        hdetail+=perlin2d(nx*freq,ny*freq,terrain_perm)*amp
        max_amp+=amp amp*=0.5 freq*=2
    end
    hdetail=(hdetail/max_amp)*10

    -- ridges + inland mountain factor
    local rid=abs(perlin2d(nx*0.5,ny*0.5,terrain_perm))^1.5
    local inland=max(0,cont/12+0.5)
    local mountain=rid*inland*20

    -- final clamped height
    local h=flr(mid(cont+hdetail+mountain - water_level,-4,28))

    -- palette lookup ヌ●★ cache and return via unpack
    for i=1,8 do
        if h<=TERRAIN_THRESH[i] then
            local p=(i-1)*3+1
            local tuple={ord(TERRAIN_PAL_STR,p),ord(TERRAIN_PAL_STR,p+1),ord(TERRAIN_PAL_STR,p+2),h}
            cell_cache[key]=tuple
            return unpack(tuple)
        end
    end
end



-- MAIN PICO-8 FUNCTIONS
function _init()
    music(0)

    palt(0, false)
    palt(14, true)
    
    -- game state & modes
    game_state = "startup"
    
    -- startup variables
    startup_phase = "title"
    startup_timer = 0
    startup_view_range = 0
    title_x1 = -64
    title_x2 = 128
    
    -- menu panels
    play_panel = nil
    customize_panel = nil
    customization_panels = {}
    customize_cursor = 1
    
    -- CREATE PLAYER SHIP RIGHT AWAY
    player_ship = ship.new(0, 0)
    player_ship.is_hovering = true
    
    -- core game variables
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
        {name="random", is_action=true},
    }
    
    menu_cursor = 1
    menu_panels = {}
    
    -- initialization sequence
    terrain_perm = generate_permutation(current_seed)
    cell_cache = {}
    tile_manager:init()
    tile_manager:update_player_position(0, 0)
    
    -- set ship altitude
    player_ship.current_altitude = player_ship:get_terrain_height_at(0, 0) + player_ship.hover_height

    -- === TOP MESSAGE STATE ===
    ui_msg="" ui_vis=0 ui_until=0 ui_col=7
    -- === RIGHT-SLOT ===
    ui_rmsg="" ui_rcol=7
    ui_box_h = 6  -- current height (6 = collapsed to fit in top bar)
    ui_box_target_h = 6  -- target height (6 = collapsed, 26 = expanded)
    ui_typing_started = false
end




function _update()
    if game_state=="startup" then
        -- intro timer + gentle drift
        startup_timer+=1
        player_ship.vy=-0.1
        player_ship.y+=player_ship.vy

        -- face along motion
        local svx=(player_ship.vx-player_ship.vy)
        local svy=(player_ship.vx+player_ship.vy)*0.5
        player_ship.angle=atan2(svx,svy)

        -- hover-lock to terrain
        player_ship.current_altitude=player_ship:get_terrain_height_at(player_ship.x,player_ship.y)+player_ship.hover_height
        player_ship.is_hovering=true

        -- stream tiles
        tile_manager:update_player_position(player_ship.x,player_ship.y)
        tile_manager:update_tiles()

        -- ambient particles
        if startup_timer%3==0 then player_ship:spawn_particles(1,0) end

        -- camera snaps to ship
        local tx,ty=player_ship:get_camera_target()
        cam_offset_x,cam_offset_y=tx,ty

        -- phase logic
        if startup_phase=="title" then
            if startup_view_range<7 then
                startup_view_range+=0.5
                view_range=flr(startup_view_range)
            end
            if title_x1<20 then title_x1+=6 end
            if title_x2>68 then title_x2-=6 end
            if startup_view_range>=7 and title_x1>=20 and title_x2<=68 then
                startup_phase="menu_select"
                init_menu_select()
            end
        elseif startup_phase=="menu_select" then
            update_menu_select()
        else
            update_customize()
        end

    elseif game_state=="game" then
        if not player_ship.dead then
            player_ship:update()
            game_manager:update()
            local tx,ty=player_ship:get_camera_target()
            cam_offset_x+= (tx-cam_offset_x)*0.3
            cam_offset_y+= (ty-cam_offset_y)*0.3
        else
            -- Simple death message based on how long player has been dead
            if not player_ship.death_time then
                player_ship.death_time = time()
                ui_say("game over", 2, 8)
            elseif time() - player_ship.death_time > 2.5 then
                ui_say("❎ to restart", 0, 7)  -- shorter message
            end
            
            if btnp(❎) or btnp(🅾️) then
                player_ship.dead=false
                player_ship.death_time=nil  -- reset death timer
                player_ship.hp=100                
                game_manager:reset()
                enemies,projectiles={},{}
                tile_manager:update_player_position(0, 0)
                ui_msg=""  -- clear any message
            end
        end

        update_projectiles()

        for i=#floating_texts,1,-1 do
            if not floating_texts[i]:update() then
                deli(floating_texts,i)
            end
        end

        if game_manager.display_score < game_manager.player_score then
            local diff = game_manager.player_score - game_manager.display_score
            local step = flr((diff+9)/10)
            game_manager.display_score += (diff<10) and diff or step
        end

        -- tick top message
        ui_tick()
    end

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




function draw_minimap(x,y)
    -- sizes + step (each minimap pixel = s world units)
    local ms,wr=44,32
    local s=(wr*2)/ms

    -- background
    rectfill(x-1,y-1,x+ms,y+ms,0)

    -- world window start at ship - wr, then step by s
    local ship_x,ship_y=player_ship.x,player_ship.y
    local start_wx,start_wy=ship_x-wr,ship_y-wr

    -- raster terrain
    for py=0,ms-1 do
        local wy=flr(start_wy+py*s)
        local wx=start_wx
        for px=0,ms-1 do
            pset(x+px,y+py,terrain(flr(wx),wy))
            wx+=s
        end
    end

    -- view box + player dot
    local cx,cy=x+ms/2,y+ms/2
    local vb=ms*view_range/wr  -- ms*(2*vr)/(2*wr)
    rect(cx-vb/2,cy-vb/2,cx+vb/2,cy+vb/2,7)
    circfill(cx,cy,1,8) pset(cx,cy,8)
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

    -- title
    draw_vertical_wave_sprites(0,title_x1,10,8,1)
    draw_vertical_wave_sprites(16,title_x2,20,6,1)

    -- ui
    if startup_phase=="menu_select" then
        play_panel:draw() customize_panel:draw()
    elseif startup_phase=="customize" then
        for p in all(customization_panels) do p:draw() end
        draw_minimap(80,32)
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
            
            -- Update all panel texts (skip actions; show seed correctly)
            for p in all(customization_panels) do
                if p.option_index then
                    local o = menu_options[p.option_index]
                    if o.is_action then
                        p.text = "random"
                    else
                        p.text = "⬅️ "..o.name..": "..(o.is_seed and current_seed or tostr(o.values[o.current])).." ➡️"
                    end
                end
            end

            
            regenerate_world_live()
        end
    elseif option.is_seed then
        local changed=false
        if btnp(⬅️) then current_seed=(current_seed-1)%10000 changed=true end
        if btnp(➡️) then current_seed=(current_seed+1)%10000 changed=true end
        if changed then current_panel.text="⬅️ "..option.name..": "..current_seed.." ➡️" end
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



function regenerate_world_live()
    -- new terrain + clear cache
    terrain_perm=generate_permutation(current_seed)
    cell_cache={}

    -- rebuild tiles around current ship position
    tile_manager:init()
    tile_manager:update_player_position(player_ship.x,player_ship.y)
    tile_manager:update_tiles()

    -- reset altitude to new terrain
    player_ship.current_altitude=player_ship:get_terrain_height_at(player_ship.x,player_ship.y)+player_ship.hover_height
end


function update_menu_select()
    -- update panels
    play_panel:update() customize_panel:update()

    -- toggle selection with up/down
    if btnp(⬆️) or btnp(⬇️) then
        local s=play_panel.selected
        play_panel.selected=not s
        customize_panel.selected=s
    end

    -- confirm
    if btnp(❎) or btnp(🅾️) then
        if play_panel.selected then
            view_range=7
            init_game()
        else
            enter_customize_mode()
        end
    end
end


function enter_customize_mode()
    startup_phase="customize" customize_cursor=1 customization_panels={}
    local y_start,y_spacing,delay_step=32,12,2
    local panel_index=0

    for i=1,#menu_options do
        local option=menu_options[i]
        if not option.is_action then
            local y=y_start+panel_index*y_spacing
            local p=panel.new(-60,y,66,9,"⬅️ "..option.name..": "..(option.is_seed and current_seed or tostr(option.values[option.current])).." ➡️",6)
            p.option_index=i p.anim_delay=panel_index*delay_step
            p:set_position(6,y,false) add(customization_panels,p)
            panel_index+=1
        end
    end

    local ry=y_start+3*y_spacing
    local rp=panel.new(-60,ry,66,9,"random",5)
    rp.option_index=4 rp.anim_delay=panel_index*delay_step
    rp:set_position(6,ry,false) add(customization_panels,rp)

    local sb=panel.new(50,128,nil,12,"play",11)
    sb.is_start=true sb.anim_delay=(panel_index+1)*delay_step+4
    sb:set_position(50,105,false) add(customization_panels,sb)

    customization_panels[1].selected=true
end





-- GAME FUNCTIONS
function init_game()
    game_state = "game"
    
    -- Reset UI
    floating_texts = {}

    -- reset particle system
    particle_sys:reset()
    
    -- game manager
    game_manager = game_manager.new()
    
    -- prevent immediate shooting
    player_ship.last_shot_time = time()
    
    -- Update tiles for full view range
    tile_manager:update_player_position(player_ship.x, player_ship.y)
    
    -- Ensure altitude is correct
    player_ship.current_altitude = player_ship:get_terrain_height_at(player_ship.x, player_ship.y) + player_ship.hover_height
    last_cache_cleanup = time()

    -- === wipe top texts (new) ===
    ui_msg="" ui_vis=0 ui_until=0
    ui_rmsg=""
end



function draw_world()
    -- water first
    for t in all(tile_manager.tile_list) do if t.height<=0 then t:draw() end end

    -- water rings (update + draw)
    for i=#ws,1,-1 do
        local s=ws[i]
        s.r+=0.18 s.life-=1
        local lx,ly
        for a=0,1,0.06 do
            local wx,wy=s.x+cos(a)*s.r,s.y+sin(a)*s.r
            local _,_,_,h=terrain(flr(wx),flr(wy))
            if h<=0 then
                local px,py=iso(wx,wy)
                if lx then line(lx,ly,px,py,(h<=-2) and 12 or 7) end
                lx,ly=px,py
            else
                lx,ly=nil,nil -- break at land edges
            end
        end
        if s.life<=0 then deli(ws,i) end
    end

    -- land on top
    for t in all(tile_manager.tile_list) do if t.height>0 then t:draw() end end

    -- fx + ship
    particle_sys:draw()
    if not player_ship.dead then player_ship:draw() end
end



function draw_game()
    cls(1)
    draw_world()

    -- projectiles
    for p in all(projectiles) do
        local sx,sy=iso(p.x,p.y) sy-=p.z*block_h
        circfill(sx,sy,2,0)
        circfill(sx,sy,1,p.owner.is_enemy and 8 or 12)
    end

    -- current event visuals (not UI)
    if game_manager.state=="active" and game_manager.current_event then
        game_manager.current_event:draw()
    end

    -- target cursor
    if not player_ship.dead and player_ship.target and player_ship.target.get_screen_pos then
        local tx,ty=player_ship.target:get_screen_pos()
        rect(tx-8,ty-8,tx+8,ty+8,8)
    end

    -- floating texts
    for f in all(floating_texts) do f:draw() end

    -- ui (top + bottom)
    draw_ui()
end




function draw_segmented_bar(x, y, value, max_value, filled_col, empty_col)
    local filled=flr(value*15/max_value)
    for i=0,14 do
        local s=x+i*4
        rectfill(s,y,s+2,y+2,(i<filled) and filled_col or empty_col)
    end
end

function draw_ui()
    -- === TOP BAR ===
    rectfill(0,0,127,7,0)
    
    -- Always draw the box (expanding/collapsing), positioned 1 pixel from top
    local h = flr(ui_box_h)
    rectfill(0,1,27,h,0)  -- starts at y=1 instead of y=0
    rect(0,1,27,h,5)
    
    -- Always draw green lines (adjust to current height)
    if h > 3 then  -- only if there's room
        -- Horizontal lines (fewer when collapsed)
        for y=3,h-2,4 do
            line(1,y,26,y,3)
        end
        -- Vertical lines (adjust height to box size)
        for x=4,24,6 do
            line(x,2,x,h-1,3)
        end
    end
    
    -- Only draw sprite when expanded enough
    if h > 25 then
        spr(64,2,3,3,3)  -- moved down 1 pixel (was 2,2 now 2,3)
        
        -- Mouth animation
        if ui_msg!="" and ui_typing_started and (time()*8)%2<1 then
            spr(99,10,19)  -- moved down 1 pixel (was 18 now 19)
        end
    end
    
    -- Text (only show if typing has started)
    if ui_msg!="" and ui_typing_started then
        print(sub(ui_msg,1,ui_vis),30,2,ui_col)
    end
    
    -- Right slot stays the same
    if ui_rmsg!="" then
        local w=#ui_rmsg*4
        print(ui_rmsg, 127-w-2, 2, ui_rcol)
    end

    -- === BOTTOM HUD (unchanged) ===
    rectfill(0, 119, 127, 127, 0)
    
    local health_col = player_ship.hp > 30 and 11 or 8
    draw_segmented_bar(4, 120, player_ship.hp, 100, health_col, 5)
    
    local current_speed = player_ship:get_speed()
    draw_segmented_bar(4, 124, current_speed, player_ship.max_speed, 8, 5)
    
    local score_text = "score: " .. flr(game_manager.display_score)
    print(score_text, 127 - #score_text * 4, 121, 10)
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
    rectfill(self.x - text_width/2 - 1, self.y - 1, self.x + text_width/2, self.y + 5, 0)

    -- Draw white text
    print(self.text, self.x - text_width/2, self.y, self.col)
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

function panel:set_position(x,y,instant)
    self.target_x,self.target_y=x,y
    if instant then self.x,self.y=x,y end
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
    -- position + size (include expand)
    local dx,dy,dw,dh=self.x-self.expand,self.y,self.w+self.expand*2,self.h

    -- pulse when selected
    if self.selected then
        local p=sin(time()*6)
        dx-=p*0.5 dy-=p*0.5 dw+=p dh+=p
    end

    -- bg + border
    rectfill(dx,dy,dx+dw,dy+dh,0)
    rect(dx-1,dy-1,dx+dw,dy+dh,self.col)

    -- centered text
    print(self.text, dx+(dw-#self.text*4)/2, dy+(dh-5)/2, self.selected and self.col or 7)
end


-- === UNIFIED PARTICLE SYSTEM (all in world coords) ===
particle_sys={list={}}

function particle_sys:reset()
    self.list={}
end

-- kind: 0=smoke, 1=blast (all use world coords)
local function make_particle(x,y,z,vx,vy,size,life,kind,col)
    return {
        x=x,y=y,z=z or 0,
        vx=vx,vy=vy,vz=0,
        size=size,
        life=life,max_life=life,
        kind=kind,
        col=col
    }
end

-- SMOKE (world space)
function particle_sys:spawn(x,y,z,col,count)
    count=count or 1
    for i=1,count do
        local p=make_particle(
            x+(rnd()-.5)*.1,
            y+(rnd()-.5)*.1,
            z,
            (rnd()-.5)*.05,
            (rnd()-.5)*.05,
            1+rnd(1),
            20+rnd(10),
            0,  -- smoke
            col or 0)
        p.vz=-rnd()*0.3-0.2
        add(self.list,p)
    end
end

-- EXPLOSIONS (now in world space)
function particle_sys:explode(wx,wy,z,scale)
    local function add_group(radius,speed,size_px,life,count)
        for i=1,count do
            -- Create particles in world space with world velocities
            local angle = rnd()
            local dist = rnd() * radius * scale * 0.1  -- convert pixel radius to world units
            local vel = rnd() * speed * scale * 0.01   -- convert pixel speed to world units
            
            add(self.list, make_particle(
                wx + cos(angle) * dist,
                wy + sin(angle) * dist,
                z + rnd() * 0.5,  -- slight vertical variation
                cos(angle) * vel,
                sin(angle) * vel,
                size_px * scale,
                life,
                1))  -- all explosions are kind=1 (blast)
        end
    end
    -- core / medium / outer (fireballs)
    add_group(4,0.5,3+rnd(2),15,flr(3*scale))
    add_group(6,1.0,2+rnd(1),20,flr(5*scale))
    add_group(8,1.5,1,      25,flr(4*scale))
    -- removed debris line
end

function particle_sys:update()
    for i=#self.list,1,-1 do
        local p=self.list[i]
        
        -- all particles use world physics
        p.x+=p.vx 
        p.y+=p.vy 
        p.z+=p.vz
        p.vx*=0.9 
        p.vy*=0.9 
        p.vz*=0.95
        
        p.life-=1
        if p.life<=0 then deli(self.list,i) end
    end
    while #self.list>100 do deli(self.list,1) end
end

function particle_sys:draw()
    for p in all(self.list) do
        -- ALL particles project from world to screen
        local screen_x,screen_y=iso(p.x,p.y) 
        screen_y+=p.z  -- z is in screen units (negative = up)
        
        if p.kind==0 then
            -- smoke rendering
            local alpha=p.life/p.max_life
            if alpha>0.5 then
                if p.size>1.5 then
                    circfill(screen_x,screen_y,1,p.col)
                else
                    pset(screen_x,screen_y,p.col)
                end
            elseif (alpha>0.25 and rnd()>0.3) or (alpha<=0.25 and rnd()>0.6) then
                pset(screen_x,screen_y,p.col)
            end
        else
            -- blast rendering (kind==1)
            local alpha=p.life/p.max_life
            local col=7
            if alpha<0.8 then col=10 end
            if alpha<0.5 then col=9 end
            if alpha<0.3 then col=8 end
            if alpha<0.15 then col=2 end
            circfill(screen_x,screen_y,p.size,col)
        end
    end
end




-- GAME MANAGER
game_manager = {}
game_manager.__index = game_manager

function game_manager.new()
    local self = setmetatable({
        -- just create the object with placeholder values
        idle_duration = 5,
        event_types = {"combat", "circles"},
        
        -- difficulty settings that don't reset
        difficulty_rings_base = 3,
        difficulty_rings_step = 1,
        difficulty_base_time = 5,
        difficulty_recharge_start = 2,
        difficulty_recharge_step = 0.2,
        difficulty_recharge_min = 0.5,
    }, game_manager)
    
    self:reset()  -- initialize all the resettable fields
    return self
end

function game_manager:reset()
    self.state = "idle"
    self.current_event = nil
    self.idle_start_time = time()
    self.next_event_index = 1
    self.difficulty_circle_round = 0
    self.difficulty_combat_round = 0
    self.player_score = 0
    self.display_score = 0
end



function game_manager:update()
    -- state machine
    if self.state=="idle" then
        if time()-self.idle_start_time>=self.idle_duration then
            self:start_random_event()
        end
    else -- "active"
        local e=self.current_event
        if e then
            e:update()
            if e.completed then self:end_event(e.success) end
        end
    end
end



function game_manager:start_random_event()
    -- pick event type and advance pointer
    local event_type=self.event_types[self.next_event_index]
    self.next_event_index=self.next_event_index%#self.event_types+1

    if event_type=="circles" then
        local r=self.difficulty_circle_round
        self.current_event=circle_event.new({
            num_rings=self.difficulty_rings_base+r*self.difficulty_rings_step,
            base_time=self.difficulty_base_time,
            recharge_seconds=max(self.difficulty_recharge_min,self.difficulty_recharge_start-r*self.difficulty_recharge_step)
        })
    else
        -- "combat"
        self.current_event=combat_event.new()
    end

    -- activate
    self.state="active"
end


function game_manager:end_event(success)
    -- return to idle
    self.state="idle"
    self.idle_start_time=time()

    -- clear right slot (timer etc.)
    ui_rmsg=""

    -- if the player died, don't show message here (let update loop handle it)
    if (not success) and player_ship and player_ship.dead then
        -- do nothing - death messages handled in _update
    else
        ui_say(success and "event complete!" or "event failed", 3, success and 11 or 8)
    end

    -- difficulty bump on success
    if success then
        if self.current_event and self.current_event.is_combat then
            self.difficulty_combat_round+=1
        else
            self.difficulty_circle_round+=1
        end
    end

    -- clear current event
    self.current_event=nil
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
        success = false
    }, circle_event)

    local ring_count = opt.num_rings or 3

    for i = 1, ring_count do
        local angle = rnd(1)
        local distance = 8 + rnd(4)
        local cx = player_ship.x + cos(angle) * distance
        local cy = player_ship.y + sin(angle) * distance
        add(self.circles, { x=cx, y=cy, radius=1.2, collected=false })
    end

    self.end_time = time() + self.base_time
    self.total_points_award = #self.circles * self.per_ring_points + self.completion_bonus

    -- Intro message
    ui_say("reach all "..#self.circles.." circles!", 3, 8)
    -- Seed right slot immediately (doesn't fight the left message)
    ui_rset(fmt2(self.base_time).."s", 5)

    return self
end






function circle_event:update()
    local now = time()
    local time_left = self.end_time - now

    -- timeout -> fail
    if time_left <= 0 then
        self.completed = true
        self.success = false
        ui_say("event failed", 3, 8)
        ui_rmsg="" -- clear right slot
        return
    end

    -- update right slot timer independently of left message
    ui_rset(fmt2(max(0, time_left)).."s", 5)

    -- rings
    local circle = self.circles[self.current_target]
    if circle and not circle.collected then
        local dx, dy = player_ship.x - circle.x, player_ship.y - circle.y
        local dist = dist_trig(dx, dy)

        if dist < circle.radius then
            circle.collected = true
            sfx(61)

            -- heal
            local health_gain = 10
            player_ship.hp = min(player_ship.hp + health_gain, player_ship.max_hp)

            -- bonus time (not on last)
            if self.current_target < #self.circles then
                self.end_time += self.recharge_seconds
                local sx, sy = player_ship:get_screen_pos()
                add(floating_texts, floating_text.new(sx, sy - 10, "+"..fmt2(self.recharge_seconds).."s"))
                add(floating_texts, floating_text.new(sx, sy - 20, "+10hp", 11))
            end

            self.current_target += 1

            if self.current_target > #self.circles then
                -- success
                self.completed, self.success = true, true
                local sx, sy = player_ship:get_screen_pos()
                game_manager.player_score += self.total_points_award
                add(floating_texts, floating_text.new(sx, sy - 20, "+"..self.total_points_award, 7))
                ui_say("event complete!", 3, 11)
                ui_rmsg="" -- clear right slot
            else
                -- progress message (right slot keeps updating separately)
                local remaining = #self.circles - self.current_target + 1
                ui_say(remaining.." circle"..(remaining>1 and "s" or "").." left", 2, 10)
            end
        end
    end
end






function circle_event:draw()
    -- cache time for animation
    local t=time()

    -- draw all uncollected rings
    for i=1,#self.circles do
        local circle=self.circles[i]
        if not circle.collected then
            local sx,sy=iso(circle.x,circle.y)
            local cx,cy=flr(circle.x),flr(circle.y)
            local _,_,_,terrain_h=terrain(cx,cy)
            local base_y=sy-terrain_h*block_h

            -- highlight current target
            local cur=(i==self.current_target)
            local base_radius=10+(cur and sin(t*2)*1.5 or 0)
            local col=cur and 8 or 2

            -- ring outline
            for a=0,1,0.01 do
                pset(sx+cos(a)*base_radius, base_y+sin(a)*base_radius*0.5, col)
            end

            -- rotating emitters on current target
            if cur then
                local rot=t*0.3
                local tick=flr(t*30)
                if tick%3==0 then
                    for emitter=0,1 do
                        local ang=rot+emitter*0.5
                        local ex=sx+cos(ang)*base_radius*0.9
                        local ey=base_y+sin(ang)*base_radius*0.45
                        for h=0,10,3 do pset(ex,ey-h,col) end
                    end
                end
            end
        end
    end

    -- direction arrow to current target
    local target=self.circles[self.current_target]
    if target and not target.collected then
        draw_arrow_to(target.x,target.y,player_ship.x,player_ship.y,8,1.5)
    end
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
        accel = 0.05,
        friction = 0.9,
        max_speed = is_enemy and 0.32 or 0.4,
        projectile_speed = 0.4,
        projectile_life = 40,
        fire_rate = is_enemy and 0.15 or 0.1,
        size = 12,
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
        max_hp = is_enemy and 50 or 100,
        hp = is_enemy and 50 or 100,
        target = nil,
        ai_phase = is_enemy and rnd(6) or 0,
    }, ship)
end


function ship:ai_update()
    if not player_ship then return end

    -- base vector to player
    local dx=player_ship.x-self.x
    local dy=player_ship.y-self.y
    local dist=dist_trig(dx,dy)

    -- chase/flee mode (flee at 40% health)
    local mode=(self.hp/self.max_hp<=0.3 and dist>15) or 
            (self.hp/self.max_hp>0.3 and (dist>20 or ((time()+self.ai_phase)%6)<3))
    if not mode then dx,dy=-dx,-dy end

    -- separation from other enemies
    for e in all(enemies) do
        if e~=self then
            local ex,ey=self.x-e.x,self.y-e.y
            local d=dist_trig(ex,ey)
            if d<4 then local w=4-d dx+=ex*w dy+=ey*w end
        end
    end

    -- apply movement toward chosen steer vector
    local m=dist_trig(dx,dy)
    if m>0.1 then
        local a=self.accel/m
        self.vx+=dx*a self.vy+=dy*a
    end

    -- chase fire: target update + cooldown
    if mode and self:update_targeting() and (not self.last_shot_time or time()-self.last_shot_time>self.fire_rate) then
        self:fire_at() self.last_shot_time=time()
    end
end


function ship:fire_at()
    if not self.target then return end
    
    local dx, dy = self.target.x - self.x, self.target.y - self.y
    local dist = dist_trig(dx, dy)
    
    if dist < 15 then
        add(projectiles, {
            x = self.x,
            y = self.y,
            z = self.current_altitude,
            vx = self.vx + dx/dist * self.projectile_speed,
            vy = self.vy + dy/dist * self.projectile_speed,
            life = self.projectile_life,
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
    -- forward vector
    local fx,fy=cos(self.angle),sin(self.angle)

    -- search best target (ヌ웃さ15, in front: dot > 0.5*dist)
    local best,found=15,nil
    if self.is_enemy then
        local t=player_ship
        local dx,dy=t.x-self.x,t.y-self.y
        local d=dist_trig(dx,dy)
        if d<best and (dx*fx+dy*fy)>.5*d then found=t end
    else
        for t in all(enemies) do
            local dx,dy=t.x-self.x,t.y-self.y
            local d=dist_trig(dx,dy)
            if d<best and (dx*fx+dy*fy)>.5*d then best=d found=t end
        end
    end

    -- assign target or aim ahead
    if found then self.target=found return true end
    if not self.is_enemy then
        local a=atan2(self.vx,self.vy)
        self.target={x=self.x+cos(a)*10,y=self.y+sin(a)*10}
    else
        self.target=nil
    end
    return false
end

function ship:update()
    -- AI or player input
    if self.is_enemy then
        self:ai_update()
    else
        tile_manager:update_player_position(self.x, self.y)

        -- player input
        local ax = self.accel
        local input_x = (btn(➡️) and ax or 0) + (btn(⬅️) and -ax or 0) + (btn(⬇️) and ax or 0) + (btn(⬆️) and -ax or 0)
        local input_y = (btn(➡️) and -ax or 0) + (btn(⬅️) and  ax or 0) + (btn(⬇️) and  ax or 0) + (btn(⬆️) and -ax or 0)
        self.vx += input_x * 0.707
        self.vy += input_y * 0.707

        -- targeting and shooting
        self:update_targeting()
        if btn(❎) and (not self.last_shot_time or time() - self.last_shot_time > self.fire_rate) then
            self:fire_at()
            self.last_shot_time = time()
        end
    end

    -- movement and speed clamp
    self.vx *= self.friction
    self.vy *= self.friction
    local speed = self:get_speed()
    if speed > self.max_speed then
        local s = self.max_speed / speed
        self.vx *= s
        self.vy *= s
    end
    self.x += self.vx
    self.y += self.vy

    -- terrain and ramp launch
    local new_terrain = self:get_terrain_height_at(self.x, self.y)
    local height_diff = new_terrain - self:get_terrain_height_at(self.x - self.vx, self.y - self.vy)
    if self.is_hovering and height_diff > 0 and speed > 0.01 then
        self.vz = height_diff * self.ramp_boost * speed * 10
        self.is_hovering = false
    end

    -- altitude physics
    local target_altitude = new_terrain + self.hover_height
    if self.is_hovering then
        self.current_altitude = target_altitude
        self.vz = 0
    else
        self.current_altitude += self.vz
        self.vz -= self.gravity
        if self.current_altitude <= target_altitude then
            self.current_altitude = target_altitude
            self.vz = 0
            self.is_hovering = true
        end
        self.vz *= 0.98
    end

    -- exhaust particles
    if self.is_hovering and speed > 0.01 then
        self.particle_timer += 1
        local spawn_rate = max(1, 5 - flr(speed * 10))
        if self.particle_timer >= spawn_rate then
            self.particle_timer = 0
            self:spawn_particles(1 + flr(speed * 5))
        end
    else
        self.particle_timer = 0
    end

    -- update facing
    if abs(self.vx) > 0.01 or abs(self.vy) > 0.01 then
        self.angle = atan2(self.vx - self.vy, (self.vx + self.vy) * 0.5)
    end

    -- water rings
    if self.is_hovering and speed > 0.2 then
        self.st = (self.st or 0) + 1
        if self.st > 4 then
            add(ws, {x = self.x, y = self.y, r = 0, life = 28})
            self.st = 0
        end
    end
end


function ship:get_screen_pos()
    local screen_x, screen_y = iso(self.x, self.y)
    return screen_x, screen_y - self.current_altitude * block_h
end


function ship:get_camera_target()
    -- choose world-space focus point
    local focus_x, focus_y = self.x, self.y
    if not self.is_enemy then
        local nearest_enemy, nearest_dist = nil, 10
        for e in all(enemies) do
            local dist = dist_trig(e.x - self.x, e.y - self.y)
            if dist < nearest_dist then nearest_enemy, nearest_dist = e, dist end
        end
        if nearest_enemy then
            focus_x, focus_y = (self.x + nearest_enemy.x) * 0.5, (self.y + nearest_enemy.y) * 0.5
        end
    end

    -- project focus point into camera offset
    local screen_x, screen_y = (focus_x - focus_y) * half_tile_width, (focus_x + focus_y) * half_tile_height - self.current_altitude * block_h
    return 64 - screen_x, 64 - screen_y
end



function ship:get_triangle_points()
    local sx, sy = self:get_screen_pos()
    local ship_len = self.size * 0.8
    local half_ship_len = ship_len * 0.5
    local fx, fy = sx + cos(self.angle) * ship_len, sy + sin(self.angle) * half_ship_len
    local back_angle = self.angle + 0.5
    return {
        {fx, fy},
        {sx + cos(back_angle - 0.15) * ship_len, sy + sin(back_angle - 0.15) * half_ship_len},
        {sx + cos(back_angle + 0.15) * ship_len, sy + sin(back_angle + 0.15) * half_ship_len}
    }, sx, sy
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
                particle_sys:explode(p.x, p.y, -t.current_altitude * block_h, 0.8)
                
                -- death check
                if t.hp <= 0 then
                    sfx(62)  -- play death sound
                    
                    -- BIG EXPLOSION when ship dies
                    particle_sys:explode(t.x, t.y, -t.current_altitude * block_h, 3)
                    
                    if t.is_enemy then
                        del(enemies, t)
                        game_manager.player_score += 200
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

function ui_say(t,d,c)
    ui_msg=t
    ui_vis=0
    ui_col=c or 7
    ui_until=d and (time()+d) or 0
    ui_box_target_h = 26  -- expand when message starts
    ui_typing_started = false
end

function ui_rset(t,c)
    ui_rmsg=t
    ui_rcol=c or 7
end

function ui_tick()
    -- Expand/collapse box
    if ui_box_h != ui_box_target_h then
        ui_box_h += (ui_box_target_h - ui_box_h) * 0.2
        if abs(ui_box_h - ui_box_target_h) < 0.5 then 
            ui_box_h = ui_box_target_h 
        end
    end
    
    -- Start typing only when box is expanded
    if ui_box_h > 25 then
        ui_typing_started = true
    end
    
    -- Only type if box is ready
    if ui_msg!="" and ui_typing_started then
        if ui_vis<#ui_msg then 
            local speed = (#ui_msg > 15) and 3 or 1
            ui_vis = min(ui_vis + speed, #ui_msg)
        end
        if ui_until>0 and time()>ui_until then
            ui_msg="" 
            ui_vis=0
            ui_until=0
            ui_box_target_h = 6  -- collapse when message ends
            ui_typing_started = false
        end
    end
end



-- COMBAT EVENT
combat_event = {}
combat_event.__index = combat_event

function combat_event.new()
    local self = setmetatable({
        completed = false,
        success = false,
        start_count = 0,
        switched = false,
        is_combat = true,
        last_msg = nil   -- track last message shown
    }, combat_event)

    -- top message
    ui_say("enemy wave incoming!",3,8)

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

    -- wave cleared
    if remaining == 0 then
        self.completed, self.success = true, true
        game_manager.player_score += 1000
        return
    end

    -- after first kill, show remaining (only when it changes)
    if (not self.switched) and remaining < self.start_count then
        self.switched = true
        self.last_msg = nil
    end
    if self.switched then
        local msg = (remaining==1) and "1 enemy left" or (remaining.." enemies left")
        if self.last_msg ~= msg then
            ui_say(msg, 3, 8)
            self.last_msg = msg
        end
    end

    -- player death: mark completed/failed; end_event will show messages
    if player_ship.hp <= 0 then
        self.completed, self.success = true, false
        player_ship.dead = true
        ui_rmsg = "" -- clear right slot (timer etc.)
        return
    end
end






function combat_event:draw()
    for e in all(enemies) do
        e:draw()
        draw_arrow_to(e.x, e.y, player_ship.x, player_ship.y, 8, 1.5)
    end
end



function draw_arrow_to(target_x,target_y,source_x,source_y,col,orbit_dist)
    -- vector to target; skip if very close
    local dx,dy=target_x-source_x,target_y-source_y
    if dx*dx+dy*dy<4 then return end

    -- orbit point around source (world space)
    local a=atan2(dx,dy)
    local ax,ay=source_x+cos(a)*orbit_dist, source_y+sin(a)*orbit_dist

    -- project to screen
    local sx,sy=iso(ax,ay)
    sy-=player_ship.current_altitude*block_h

    -- screen-facing angle from isometric delta
    local sdx,sdy=(dx-dy)*half_tile_width,(dx+dy)*half_tile_height
    local sa=atan2(sdx,sdy)

    -- arrow triangle
    local s=6
    local tx,ty=sx+cos(sa)*s, sy+sin(sa)*s*0.5
    local ba=sa+0.5
    local bx,by=s*0.7,s*0.35
    draw_triangle(
        tx,ty,
        sx+cos(ba-0.18)*bx, sy+sin(ba-0.18)*by,
        sx+cos(ba+0.18)*bx, sy+sin(ba+0.18)*by,
        col
    )
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
    local sx,sy=cam_offset_x+self.base_sx,cam_offset_y+self.base_sy
    local lb,rb=cam_offset_x+self.lb,cam_offset_x+self.rb

    -- water: top diamond + single ripple (opposite blue)
    if self.height<=0 then
        diamond(sx,sy,self.top_col)
        local yb=flr(sy+self.r+sin(time()+(self.x+self.y)/8))
        line(lb,yb,rb,yb,(self.height<=-2) and 12 or 1)
        return
    end

    -- land: faces then top
    local hp=self.hp
    local sy2=sy-hp
    local by=cam_offset_y+self.by-hp
    local m=self.face
    if (m&1)>0 or (m&2)>0 then
        for i=0,hp do
            if (m&1)>0 then line(lb,sy2+i,sx,by+i,self.side_col) end
            if (m&2)>0 then line(rb,sy2+i,sx,by+i,self.dark_col) end
        end
    end
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
    local row=self.tiles[x]
    if not row then row={} self.tiles[x]=row end
    if row[y] then return end

    local t=tile.new(x,y)
    row[y]=t

    -- insert sorted by (x+y)
    local list=self.tile_list
    local k=t.x+t.y
    local i=#list
    while i>0 and (list[i].x+list[i].y)>k do i-=1 end
    add(list,t,i+1)
end


function tile_manager:remove_tile(x,y)
    local row=self.tiles[x]
    if row and row[y] then
        del(self.tile_list,row[y])
        row[y]=nil
        if not next(row) then self.tiles[x]=nil end
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
    local nminx,nminy=self.player_x-view_range,self.player_y-view_range
    local nmaxx,nmaxy=self.player_x+view_range,self.player_y+view_range

    -- first fill or range change ヌ●★ full rebuild
    if #self.tile_list<1 or self.view_range_cached!=view_range then
        for x=nminx,nmaxx do for y=nminy,nmaxy do self:add_tile(x,y) end end
        self.min_x,self.max_x,self.min_y,self.max_y=nminx,nmaxx,nminy,nmaxy
        self.view_range_cached=view_range self.dx_pending,self.dy_pending=0,0
        return
    end

    local dx,dy=self.dx_pending or 0,self.dy_pending or 0
    if dx==0 and dy==0 then return end

    -- moved in x?
    if dx>0 then
        for y=nminy,nmaxy do self:add_tile(nmaxx,y) end
        for y=self.min_y,self.max_y do self:remove_tile(self.min_x,y) end
    elseif dx<0 then
        for y=nminy,nmaxy do self:add_tile(nminx,y) end
        for y=self.min_y,self.max_y do self:remove_tile(self.max_x,y) end
    end

    -- moved in y?
    if dy>0 then
        for x=nminx,nmaxx do self:add_tile(x,nmaxy) end
        for x=self.min_x,self.max_x do self:remove_tile(x,self.min_y) end
    elseif dy<0 then
        for x=nminx,nmaxx do self:add_tile(x,nminy) end
        for x=self.min_x,self.max_x do self:remove_tile(x,self.max_y) end
    end

    self.min_x,self.max_x,self.min_y,self.max_y=nminx,nmaxx,nminy,nmaxy
    self.dx_pending,self.dy_pending=0,0
end




function tile_manager:cleanup_cache()
    -- run at most ~1s
    local t=time()
    if t-last_cache_cleanup<=1 then return end

    -- keep cells near player (covers tiles + minimap)
    local R=max(view_range*2,36)
    local x1,y1=self.player_x-R,self.player_y-R
    local x2,y2=self.player_x+R,self.player_y+R

    -- prune in place
    for k in pairs(cell_cache) do
        local p=split(k,",",true) -- "x,y" -> numbers
        local x,y=p[1],p[2]
        if x<x1 or x>x2 or y<y1 or y>y2 then
            cell_cache[k]=nil
        end
    end

    last_cache_cleanup=t
end





-- TERRAIN GENERATION
function perlin2d(x,y,p)
    local fx,fy=flr(x),flr(y)
    local xi,yi=fx&127,fy&127
    local xf,yf=x-fx,y-fy
    local u=xf*xf*(3-2*xf)
    local v=yf*yf*(3-2*yf)

    -- hash corners (no px/px1 locals)
    local a,b=p[xi]+yi,p[xi+1]+yi
    local aa,ab,ba,bb=p[a],p[a+1],p[b],p[b+1]

    -- gradients
    local ax=((aa&1)<1 and xf or -xf)+((aa&2)<2 and yf or -yf)
    local bx=((ba&1)<1 and xf-1 or 1-xf)+((ba&2)<2 and yf or -yf)
    local cx=((ab&1)<1 and xf or -xf)+((ab&2)<2 and yf-1 or 1-yf)
    local dx=((bb&1)<1 and xf-1 or 1-xf)+((bb&2)<2 and yf-1 or 1-yf)

    -- bilerp via one temp
    local x1=ax+(bx-ax)*u
    return x1+((cx+(dx-cx)*u)-x1)*v
end



function generate_permutation(seed)
    srand(seed)
    local p={}
    for i=0,127 do
        local v=flr(rnd(128))
        p[i],p[i+128]=v,v
    end
    return p
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
e00eeee000000000eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee
e00eee00555555d500eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee
e05ee005d555555d500eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee
e05ee0dd5dddddd5dd0eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee
e05e00ddd6ddddd5dd00eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee
e05e05d6d6dddd5ddd50eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee
e05005ddd6dddd5dd5500eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee
e00505666d6ddd5ddd5050eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee
e0650500665555ddd05050eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee
e065000000000000000050eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee
e065000888000088800050eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee
e055050088055088005050eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee
ee050560005665000d5050eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee
eee0005665666dddd5000eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee
eeee0506666ddddd5050eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee
eeee0500666ddddd0050eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee
eeee0500560000d50050eeee560000d5eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee
eeee0050506666050500eeee560000d5eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee
eeeee00050666605000eeeee50666605eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee
eeeeee0005dddd5000eeeeee00dddd00eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee
eeeeeee0055555500eeeeeee05555550eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee
eeeeeeee00000000eeeeeeee00000000eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee
eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee
eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee
0eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee
0eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee
0eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee
0eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee
0eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee
0eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee
0eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee
0eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee
000000000000000000000000eeeeeeeeeeeeeeee0000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
000000000000000000000000eeeeeeeeeeeeeeee0000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
000000000000000000000000eeeeeeeeeeeeeeee0000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
000000000000000000000000eeeeeeeeeeeeeeee0000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
000000000000000000000000eeeeeeeeeeeeeeee0000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
000000000000000000000000eeeeeeeeeeeeeeee0000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
000000000000000000000000eeeeeeeeeeeeeeee0000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
000000000000000000000000eeeeeeeeeeeeeeee0000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
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

