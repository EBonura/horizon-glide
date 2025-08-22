pico-8 cartridge // http://www.pico-8.com
version 43
__lua__
-- HORIZON GLIDE
-- An infinite isometric racing game

-- Helper functions
function dist_trig(dx, dy) local ang = atan2(dx, dy) return dx * cos(ang) + dy * sin(ang) end
function iso(x,y) return cam_offset_x+(x-y)*half_tile_width, cam_offset_y+(x+y)*half_tile_height end


function fmt2(n)
    local s=flr(n*100+0.5)
    local neg=s<0 if neg then s=-s end
    return (neg and "-" or "")..flr(s/100).."."..sub("0"..(s%100),-2)
end


function draw_triangle(l,t,c,m,r,b,col)
    while t>m or m>b do
        l,t,c,m=c,m,l,t
        while m>b do c,m,r,b=r,b,c,m end
    end
    local e,j=l,(r-l)/(b-t)
    while m do
        local i=(c-l)/(m-t)
        for t=flr(t),min(flr(m)-1,127) do
        line(l,t,e,t,col)
        l+=i e+=j
        end
        l,t,m,c,b=c,m,b,r
    end
end


-- terrain color lookup tables (top, side, dark triplets; height thresholds)
TERRAIN_PAL_STR = "\1\0\0\12\1\1\15\4\2\3\1\0\11\3\1\4\2\0\6\5\0\7\6\5"
TERRAIN_THRESH  = {-2,0,2,6,12,18,24,99}

function terrain(x,y)
    -- cache hit
    local key=x..","..y
    local c=cell_cache[key]
    if c then return unpack(c) end

    -- scaled coords + base continentalness
    local scale=menu_options[1].values[menu_options[1].current]
    local water_level=menu_options[2].values[menu_options[2].current]
    local nx,ny=x/scale,y/scale
    local cont=perlin2d(nx*.03,ny*.03,terrain_perm)*15

    -- 3 fixed octaves (normalized by 1.75), then scaled by 10
    local hdetail=( perlin2d(nx,ny,terrain_perm)
                    + perlin2d(nx*2,ny*2,terrain_perm)*.5
                    + perlin2d(nx*4,ny*4,terrain_perm)*.25 )*(15/1.75)  -- was 10/1.75

    -- ridges + inland mountain factor (inlined)
    local rid=abs(perlin2d(nx*.5,ny*.5,terrain_perm))^1.5
    local mountain=rid*max(0,cont/15+.5)*30

    -- final clamped height
    local h=flr(mid(cont+hdetail+mountain-water_level,-4,28))

    -- palette lookup + cache
    local i=1
    while h>TERRAIN_THRESH[i] do i+=1 end
    local p=(i-1)*3+1
    cell_cache[key]={ord(TERRAIN_PAL_STR,p),ord(TERRAIN_PAL_STR,p+1),ord(TERRAIN_PAL_STR,p+2),h}
    return unpack(cell_cache[key])
end

function terrain_h(x,y,clamp)
    local _,_,_,h=terrain(x,y)
    return clamp and max(0,h) or h
end



-- MAIN PICO-8 FUNCTIONS
function _init()
    music(32)

    palt(0,false) palt(14,true)

    -- state + startup
    game_state,startup_phase="startup","title"
    startup_timer,startup_view_range=0,0
    title_x1,title_x2=-64,128

    -- camera + tile constants (needed before tile_manager)
    cam_offset_x,cam_offset_y=64,64
    view_range,half_tile_width,half_tile_height,block_h=0,12,6,2

    -- containers & cursors
    enemies,collectibles,projectiles,floating_texts,ws,menu_panels,customization_panels={},{},{},{},{},{},{}
    customize_cursor,menu_cursor=1,1

    -- player
    player_ship=ship.new(0,0)
    player_ship.is_hovering=true

    -- menu options (MUST be set before any terrain() call)
    menu_options={
        {name="sCALE",  values={8,10,12,14,16}, current=2},
        {name="wATER",  values={-4,-3,-2,-1,0,1,2,3,4}, current=4},
        {name="sEED",   values={}, current=1, is_seed=true},
        {name="rANDOM", is_action=true},
    }

    -- terrain + tiles (terrain() uses menu_options)
    last_cache_cleanup,current_seed=0,1337
    terrain_perm,cell_cache=generate_permutation(current_seed),{}
    tile_manager:init()
    tile_manager:update_player_position(0,0)

    -- set ship altitude after tiles/terrain exist
    player_ship:set_altitude()

    -- top/right UI (no ui_typing_started needed)
    ui_msg,ui_vis,ui_until,ui_col,ui_rmsg="",0,0,7,""
    ui_box_h,ui_box_target_h=6,6
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
        player_ship:set_altitude()
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
        if player_ship.dead then
            -- enter new death flow once
            enter_death()
        else
            player_ship:update()
            game_manager:update()
            local tx,ty=player_ship:get_camera_target()
            cam_offset_x+= (tx-cam_offset_x)*0.3
            cam_offset_y+= (ty-cam_offset_y)*0.3
        end

        update_projectiles()
        manage_collectibles()


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

        ui_tick()

    else -- "death"
        update_death()
    end

    particle_sys:update()
    tile_manager:cleanup_cache()
end





function _draw()
    if game_state=="startup" then
        draw_startup()
    elseif game_state=="game" then
        draw_game()
    else -- "death"
        draw_death()
    end
    -- perf monitor
    printh("mem: "..tostr(stat(0)).." \t| cpu: "..tostr(stat(1)).." \t| fps: "..tostr(stat(7)))
end



-- death flow (digital break effect)
function enter_death()
    game_state="death"
    death_t=time()
    death_cd=10
    death_phase=0          -- 0=digital break, 1=fully black
    death_closed_at=nil
    ui_msg="" ui_rmsg="" ui_box_target_h=6
end

function update_death()
    local el=time()-death_t
    
    -- transition to black screen phase after 2.5 seconds
    if death_phase==0 and el>2.5 then 
        death_phase=1
        death_closed_at=time()
    end
    
    if btnp(❎) then init_game() return end
    if time()-death_t>death_cd then _init() end
end

function draw_death()
    local el=time()-death_t
    
    -- digital break effect phase
    if death_phase==0 then
        -- draw the game world first
        cls(1) 
        draw_world()
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
        if el > 1.5 then
            local pct = (el - 1.5) * 3000
            for i=1,pct do
                pset(flr(rnd(128)), flr(rnd(128)), 0)
            end
        end
    
    -- fully black -> show death screen UI
    else
        cls(0)
        
        -- wait half second before showing UI
        local t=time()-death_closed_at
        if t < 0.5 then
            -- just black screen, no UI yet
            return
        end
        
        local cx=64
        
        -- score (top)
        local s="score: "..flr(game_manager.player_score)
        print(s,cx-#s*2,30,7)

        -- face (center) with pink transparent + eye crackle
        palt(14,true) palt(0,false)
        if t<3 then if rnd()<0.4 then pal(8,0) end else pal(8,0) end
        local fx,fy=cx-12,64-12
        spr(64,fx,fy,3,3)
        pal()

        -- continue (bottom)
        local c=flr(max(0,death_cd-(time()-death_t))+0.99)
        local msg="continue? ("..c..")  ❎"
        print(msg,cx-#msg*2,92,6)
    end
end






function draw_minimap(x,y)
    local ms=44
    local step=64/ms  -- (wr*2)/ms with wr=32
    local start_wx, start_wy = player_ship.x-32, player_ship.y-32

    -- background
    rectfill(x-1,y-1,x+ms,y+ms,0)

    -- raster terrain
    for py=0,ms-1 do
        local wy=flr(start_wy+py*step)
        for px=0,ms-1 do
            pset(x+px,y+py, terrain(flr(start_wx+px*step), wy))
        end
    end

    -- view box + player dot
    local cx,cy=x+ms/2,y+ms/2
    local vb=ms*view_range/32
    rect(cx-vb/2,cy-vb/2,cx+vb/2,cy+vb/2,7)
    circfill(cx,cy,1,8)
end



-- Function to draw sprites with vertical wave animation
function draw_vertical_wave_sprites(sprite_start, x, y, width_in_sprites)
    local width_px = width_in_sprites * 8
    local wave_pos = (time() * 50) % (width_px + 40) - 20  -- 40=2*20
    for strip_x = 0, width_px - 1 do
        local distance = abs(strip_x - wave_pos)
        local wave_offset = (distance < 20) and cos(distance * 0.025) * 2 or 0  -- 0.025=0.5/20
        sspr((sprite_start % 16) * 8 + strip_x, flr(sprite_start / 16) * 8, 1, 8, x + strip_x, y - wave_offset, 1, 8)
    end
end

function draw_startup()
    cls(1)
    draw_world()

    -- title
    draw_vertical_wave_sprites(0,  title_x1,10,8)
    draw_vertical_wave_sprites(16, title_x2,20,6)

    -- ui
    if startup_phase=="menu_select" then
        play_panel:draw() customize_panel:draw()
    elseif startup_phase=="customize" then
        for p in all(customization_panels) do p:draw() end
        draw_minimap(82,32)
    end
end



function init_menu_select()
    play_panel = panel.new(-50, 90, nil, nil, "play", 11)
    play_panel.selected = true
    play_panel:set_position(50, 90)
    
    customize_panel = panel.new(128, 104, nil, nil, "customize", 12)
    customize_panel:set_position(40, 104)
end


function update_customize()
    -- update all panels
    for p in all(customization_panels) do p:update() end

    -- navigation
    local d=(btnp(⬆️) and -1) or (btnp(⬇️) and 1) or 0
    if d!=0 then
        customization_panels[customize_cursor].selected=false
        customize_cursor+=d
        if customize_cursor<1 then customize_cursor=#customization_panels end
        if customize_cursor>#customization_panels then customize_cursor=1 end
        customization_panels[customize_cursor].selected=true
    end

    local p=customization_panels[customize_cursor]
    if p.is_start then
        if btnp(❎) then view_range=7 init_game() end
        return
    end

    local idx=p.option_index
    if not idx then return end
    local o=menu_options[idx]

    -- randomize all
    if o.is_action then
        if btnp(❎) then
            menu_options[1].current=flr(rnd(#menu_options[1].values))+1
            menu_options[2].current=flr(rnd(#menu_options[2].values))+1
            current_seed=flr(rnd(9999))
            for q in all(customization_panels) do
                if q.option_index then
                    local oo=menu_options[q.option_index]
                    q.text=oo.is_action and "random" or ("⬅️ "..oo.name..": "..(oo.is_seed and current_seed or tostr(oo.values[oo.current])).." ➡️")
                end
            end
            regenerate_world_live()
        end
        return
    end

    -- left/right adjustments
    local lr=(btnp(⬅️) and -1) or (btnp(➡️) and 1) or 0
    if lr==0 then return end

    if o.is_seed then
        current_seed=(current_seed+lr)%10000
        p.text="⬅️ "..o.name..": "..current_seed.." ➡️"
    else
        o.current+=lr
        if o.current<1 then o.current=#o.values end
        if o.current>#o.values then o.current=1 end
        p.text="⬅️ "..o.name..": "..tostr(o.values[o.current]).." ➡️"
    end
    regenerate_world_live()
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
    player_ship:set_altitude()
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
    if btnp(❎) then
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
        local o=menu_options[i]
        local y=y_start+panel_index*y_spacing
        local text=o.is_action and "random" or ("⬅️ "..o.name..": "..(o.is_seed and current_seed or tostr(o.values[o.current])).." ➡️  ")
        local col=o.is_action and 5 or 6
        local p=panel.new(-60,y,68,9,text,col)
        p.option_index=i p.anim_delay=panel_index*delay_step
        p:set_position(6,y) add(customization_panels,p)
        panel_index+=1
    end

    local sb=panel.new(50,128,nil,12,"play",11)
    sb.is_start=true sb.anim_delay=(panel_index+1)*delay_step+4
    sb:set_position(50,105) add(customization_panels,sb)

    customization_panels[1].selected=true
end







-- GAME FUNCTIONS
function init_game()
    music(0)
    -- Reset palette
    pal()
    palt(0,false) 
    palt(14,true)
    game_state = "game"
    
    -- Reset UI
    floating_texts = {}

    -- reset particle system
    particle_sys.list={}
    
    -- game manager
    game_manager = gm.new()
    
    -- Reset player ship state
    player_ship.dead = false
    player_ship.hp = player_ship.max_hp
    
    -- prevent immediate shooting
    player_ship.last_shot_time = time() + 0.5
    
    -- Update tiles for full view range
    tile_manager:update_player_position(player_ship.x, player_ship.y)
    
    -- Ensure altitude is correct
    player_ship:set_altitude()
    last_cache_cleanup = time()

    -- wipe top texts
    ui_msg="" 
    ui_vis=0 
    ui_until=0
    ui_rmsg=""

    collectibles = {}
    for i = 1, 8 do  -- spawn 8 items
        local a, d = rnd(), 15 + rnd(20)
        add(collectibles, collectible.new(cos(a) * d, sin(a) * d))
    end
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
            local h=terrain_h(flr(wx),flr(wy))
            if h<=0 then
                local px,py=iso(wx,wy)
                if lx then line(lx,ly,px,py,(h<=-2) and 12 or 7) end
                lx,ly=px,py
            else lx=nil end
        end
        if s.life<=0 then deli(ws,i) end
    end

    -- land on top
    for t in all(tile_manager.tile_list) do if t.height>0 then t:draw() end end

    -- fx + ship
    particle_sys:draw()
    for c in all(collectibles) do c:draw() end
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
    -- Top bar
    rectfill(0,0,127,7,0)
    
    -- Box
    local h = flr(ui_box_h)
    rectfill(0,1,27,h,0) 
    rect(0,1,27,h,5)
    
    -- Always draw green lines
    if h > 3 then
        -- Horizontal lines
        for y=3,h-2,4 do
            line(1,y,26,y,3)
        end
        -- Vertical lines
        for x=4,24,6 do
            line(x,2,x,h-1,3)
        end
    end
    
    -- Only draw sprite when expanded enough
    if h > 25 then
        spr(64,2,3,3,3)
        
        -- Mouth animation
        if ui_msg!="" and ui_box_h>25 and (time()*8)%2<1 then
            spr(99,10,19)
        end
    end
    
    -- Text (only show if typing has started)
    if ui_msg!="" and ui_box_h>25 then
        print(sub(ui_msg,1,ui_vis),30,2,ui_col)
    end
    
    -- Right slot stays the same
    if ui_rmsg!="" then
        local w=#ui_rmsg*4
        print(ui_rmsg, 127-w-2, 2, 5)
    end

    -- bottom HUD
    rectfill(0, 119, 127, 127, 0)

    local health_col = player_ship.hp > 30 and 11 or 8
    draw_segmented_bar(4, 120, player_ship.hp, 100, health_col, 5)

    draw_segmented_bar(4, 124, player_ship.ammo, player_ship.max_ammo, 12, 5)

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
    local w=#self.text*4
    local x1=self.x-w/2
    local y1=self.y
    rectfill(x1-1,y1-1,x1+w,y1+5,0)
    print(self.text,x1,y1,self.col)
end

-- PANEL CLASS
panel = {}
panel.__index = panel

function panel.new(x,y,w,h,text,col)
    return setmetatable({
        x=x,y=y,
        w=w or (#text*4+12),
        h=h or 10,
        text=text,
        col=col or 5,
        selected=false,
        expand=0,
        target_x=x, target_y=y,
        anim_delay=0,
    },panel)
end

function panel:set_position(x,y,instant)
    self.target_x,self.target_y=x,y
    if instant then self.x,self.y=x,y end
end


function panel:update()
    if self.anim_delay>0 then self.anim_delay-=1 return true end

    -- smooth move
    if self.x!=self.target_x or self.y!=self.target_y then
        self.x+=(self.target_x-self.x)*0.2
        self.y+=(self.target_y-self.y)*0.2
        if abs(self.x-self.target_x)<0.5 then self.x=self.target_x end
        if abs(self.y-self.target_y)<0.5 then self.y=self.target_y end
    end

    -- expand/contract
    self.expand=self.selected and min(self.expand+1,3) or max(self.expand-1,0)
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


-- PARTICLE SYSTEM
particle_sys={list={}}

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

-- EXPLOSIONS
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
            local col=alpha<0.15 and 2 or alpha<0.3 and 8 or alpha<0.5 and 9 or alpha<0.8 and 10 or 7
            circfill(screen_x,screen_y,p.size,col)
        end
    end
end




-- Game Manager
gm = {}
gm.__index = gm

function gm.new()
    local self=setmetatable({
        idle_duration=5,
        event_types={"combat","circles"},

        difficulty_rings_base=3,
        difficulty_rings_step=1,
        difficulty_base_time=5,
        difficulty_recharge_start=2,
        difficulty_recharge_step=0.1,
        difficulty_recharge_min=1,
        difficulty_level=0
    },gm)
    self:reset()
    return self
end

function gm:reset()
    self.state="idle"
    self.current_event=nil
    self.idle_start_time=nil
    self.next_event_index=1
    self.player_score=0
    self.display_score=0
    self.difficulty_level=0
end

function gm:update()
    -- tutorial (minimal tokens)
    if not self.tut then
        -- Skip tutorial checks during grace period (reuse last_shot_time)
        if player_ship.last_shot_time > time() then
            return  -- skip everything during grace period
        end
        
        -- Track what player has done (persist across frames)
        self.tut_moved = self.tut_moved or btn(⬆️) or btn(⬇️) or btn(⬅️) or btn(➡️)
        self.tut_shot = self.tut_shot or btn(❎)
        self.tut_collected = self.tut_collected or player_ship.ammo > 50
        
        -- Check what hasn't been done yet (priority: move > shoot > collect)
        local new_msg = nil
        if not self.tut_moved then
            new_msg = "arrow keys to move"
        elseif not self.tut_shot then
            new_msg = "❎ tO sHOOT"
        elseif not self.tut_collected then
            new_msg = "cOLLECT aMMO"
        elseif not self.tut_complete then
            -- Show completion message once
            new_msg = "hORIZON gLIDE bEGINS!"
            self.tut_complete = true
            self.tut_complete_time = time() + 2  -- show for 2 seconds
        elseif time() > self.tut_complete_time then
            -- Tutorial fully complete after message shown
            self.tut = true
            ui_say("", 0, 7)
            self.idle_start_time = time()
            return
        else
            -- Waiting for completion message to finish
            return
        end
        
        -- Only update UI if message changed
        if new_msg != self.tut_msg then
            self.tut_msg = new_msg
            local dur = (new_msg == "good luck!") and 2 or 99
            local col = (new_msg == "good luck!") and 11 or 7
            ui_say(new_msg, dur, col)
        end
        return  -- skip events during tutorial
    end
    
    -- original update code
    if self.state=="idle" then
        if time()-self.idle_start_time>=self.idle_duration then
            self:start_random_event()
        end
    else
        local e=self.current_event
        if e then
            e:update()
            if e.completed then self:end_event(e.success) end
        end
    end
end

function gm:start_random_event()
    local event_type=self.event_types[self.next_event_index]
    self.next_event_index=self.next_event_index%#self.event_types+1
    if event_type=="circles" then
        self.current_event=circle_event.new()
    else
        self.current_event=combat_event.new()
    end
    self.state="active"
end

function gm:end_event(success)
    self.state="idle" self.idle_start_time=time() ui_rmsg=""
    if success or not(player_ship and player_ship.dead) then
        ui_say(success and "event complete!" or "event failed",3,success and 11 or 8)
    end
    if success and self.next_event_index==1 then
        self.difficulty_level+=1
    end
    self.current_event=nil
end









-- CIRCLE RACE EVENT
circle_event = {}
circle_event.__index = circle_event

function circle_event.new()
    local r=game_manager.difficulty_level
    local self=setmetatable({
        base_time=game_manager.difficulty_base_time,
        recharge_seconds=max(game_manager.difficulty_recharge_min,game_manager.difficulty_recharge_start-r*game_manager.difficulty_recharge_step),
        circles={},
        current_target=1
    },circle_event)

    local n=game_manager.difficulty_rings_base+r*game_manager.difficulty_rings_step
    for i=1,n do
        local a,d=rnd(1),8+rnd(4)
        add(self.circles,{x=player_ship.x+cos(a)*d,y=player_ship.y+sin(a)*d,radius=1.5,collected=false})
    end

    self.end_time=time()+self.base_time
    ui_say("cOLLECT "..#self.circles.." cIRCLES!",3,8)
    ui_rmsg=fmt2(self.base_time).."s"
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
        ui_rmsg=""
        return
    end

    -- update right slot timer independently of left message
    ui_rmsg = fmt2(max(0, time_left)).."s"

    -- rings
    local circle = self.circles[self.current_target]
    if circle and not circle.collected then
        local dx, dy = player_ship.x - circle.x, player_ship.y - circle.y
        local dist = dist_trig(dx, dy)

        if dist < circle.radius then
            circle.collected = true
            sfx(61)

            -- heal 10hp per ring
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
                -- success - full heal on completion
                player_ship.hp = player_ship.max_hp
                local award=#self.circles*100+500
                self.completed,self.success=true,true
                local sx,sy=player_ship:get_screen_pos()
                game_manager.player_score+=award
                add(floating_texts,floating_text.new(sx,sy-10,"+"..award,7))
                add(floating_texts,floating_text.new(sx,sy-20,"full hp!",11))
                ui_say("event complete!",3,11)
                ui_rmsg=""
            else
                -- progress message (right slot keeps updating separately)
                local remaining=#self.circles-self.current_target+1
                ui_say(remaining.." circle"..(remaining>1 and "s" or "").." left",2,10)
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
            local base_y=sy-terrain_h(cx,cy)*block_h

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
        draw_arrow_to(target.x, target.y)
    end
end


-- COLLECTIBLES
collectible = {}
collectible.__index = collectible

function collectible.new(x, y)
    return setmetatable({x=x, y=y, collected=false}, collectible)
end

function collectible:update()
    if self.collected then return false end
    local dx, dy = player_ship.x - self.x, player_ship.y - self.y
    local dist2 = dist_trig(dx, dy)
    if dist2 > 20 then return false end
    
    if dist2 < 1 then
        self.collected = true
        sfx(61)
        local sx, sy = player_ship:get_screen_pos()
        player_ship.ammo = min(player_ship.ammo + 10, player_ship.max_ammo)
        add(floating_texts, floating_text.new(sx, sy - 10, "+10ammo", 12))
        game_manager.player_score += 25
        return false
    end
    return true
end

function collectible:draw()
    if not self.collected then
        local sx, sy = iso(self.x, self.y)
        spr(67, sx - 8, sy - terrain_h(flr(self.x), flr(self.y)) * block_h - 8, 2, 2)
    end
end

function manage_collectibles()
    -- remove far ones
    for i = #collectibles, 1, -1 do
        if not collectibles[i]:update() then
            deli(collectibles, i)
        end
    end
    
    -- spawn new ones if needed
    while #collectibles < 10 do  -- maintain 6 items
        local a, d = rnd(), 8 + rnd(15)
        local x, y = player_ship.x + cos(a) * d, player_ship.y + sin(a) * d
        add(collectibles, collectible.new(x, y))
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
        size = 11,
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
        hp = is_enemy and 50 or 1,
        target = nil,
        ai_phase = is_enemy and rnd(6) or 0,
        max_ammo = is_enemy and 9999 or 100,
        ammo = is_enemy and 9999 or 50,
        last_shot_time = 0
    }, ship)
end

function ship:set_altitude()
    self.current_altitude = terrain_h(self.x, self.y, true) + self.hover_height
end

function ship:ai_update()
    -- base vector to player
    local dx,dy=player_ship.x-self.x,player_ship.y-self.y
    local dist=dist_trig(dx,dy)

    -- chase/flee mode (health ratio check once)
    local q=self.hp/self.max_hp
    local mode=(q<=0.3 and dist>15) or (q>0.3 and (dist>20 or ((time()+self.ai_phase)%6)<3))
    if not mode then dx,dy=-dx,-dy end

    -- separation
    for e in all(enemies) do
        if e~=self then
            local ex,ey=self.x-e.x,self.y-e.y
            local d=dist_trig(ex,ey)
            if d<4 then local w=4-d dx+=ex*w dy+=ey*w end
        end
    end

    -- steer toward chosen vector
    local m=dist_trig(dx,dy)
    if m>0.1 then self.vx+=dx*self.accel/m self.vy+=dy*self.accel/m end

    -- fire
    if mode and self:update_targeting() and (not self.last_shot_time or time()-self.last_shot_time>self.fire_rate) then
        self:fire_at() self.last_shot_time=time()
    end
end



function ship:fire_at()
    if not self.target then return end
    
    if self.ammo<=0 then
        if not self.is_enemy and (not self.last_no_ammo_msg or time()-self.last_no_ammo_msg>2) then
            ui_say("no ammo!",2,8)
            self.last_no_ammo_msg=time()
        end
        return
    end
    
    local dx, dy = self.target.x - self.x, self.target.y - self.y
    local dist = dist_trig(dx, dy)
    
    add(projectiles, {
        x = self.x,
        y = self.y,
        z = self.current_altitude,
        vx = self.vx + dx/dist * self.projectile_speed,
        vy = self.vy + dy/dist * self.projectile_speed,
        life = self.projectile_life,
        owner = self,
    })
    self.ammo-=1
    sfx(63)
end

function ship:update_targeting()
    local fx,fy=cos(self.angle),sin(self.angle)
    local best,found=15,nil
    local list=self.is_enemy and {player_ship} or enemies
    for t in all(list) do
        if t~=self then
            local dx,dy=t.x-self.x,t.y-self.y
            local d=dist_trig(dx,dy)
            if d<best and (dx*fx+dy*fy)>.5*d then best=d found=t end
        end
    end
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
    -- AI or player
    if self.is_enemy then
        self:ai_update()
    else
        tile_manager:update_player_position(self.x,self.y)

        -- player input (iso mapping via rx/ry)
        local rx=(btn(➡️) and 1 or 0)-(btn(⬅️) and 1 or 0)
        local ry=(btn(⬇️) and 1 or 0)-(btn(⬆️) and 1 or 0)
        self.vx+=(rx+ry)*self.accel*0.707
        self.vy+=(-rx+ry)*self.accel*0.707

        -- targeting & fire
        self:update_targeting()
        if btn(❎) and (not self.last_shot_time or time()-self.last_shot_time>self.fire_rate) then
            self:fire_at()
            self.last_shot_time=time()
        end
    end

    -- movement & clamp
    self.vx*=self.friction self.vy*=self.friction
    local speed=dist_trig(self.vx,self.vy)
    local s=(speed>self.max_speed) and (self.max_speed/speed) or 1
    self.vx*=s self.vy*=s
    self.x+=self.vx self.y+=self.vy

    -- terrain ramp launch
    local new_terrain=terrain_h(self.x,self.y)
    local height_diff=new_terrain-terrain_h(self.x-self.vx,self.y-self.vy)
    if self.is_hovering and height_diff>0 and speed>0.01 then
        self.vz=min(height_diff*self.ramp_boost*speed*15, 1.5)  -- cap vertical velocity
        self.is_hovering=false
    end

    -- altitude physics
    local target_altitude=new_terrain+self.hover_height
    if self.is_hovering then
        self.current_altitude=target_altitude self.vz=0
    else
        self.current_altitude+=self.vz
        self.vz-=self.gravity
        if self.current_altitude<=target_altitude then
            self.current_altitude=target_altitude self.vz=0 self.is_hovering=true
        end
        self.vz*=0.98
    end

    -- exhaust particles
    if self.is_hovering and speed>0.01 then
        self.particle_timer+=1
        local spawn_rate=max(1,5-flr(speed*10))
        if self.particle_timer>=spawn_rate then
            self.particle_timer=0
            self:spawn_particles(1+flr(speed*5))
        end
    else
        self.particle_timer=0
    end

    -- facing (always compute; cheaper than guarding)
    self.angle=atan2(self.vx-self.vy,(self.vx+self.vy)*0.5)

    -- water rings
    if self.is_hovering and speed>0.2 then
        self.st=(self.st or 0)+1
        if self.st>4 then add(ws,{x=self.x,y=self.y,r=0,life=28}) self.st=0 end
    end
end



function ship:get_screen_pos()
    local screen_x, screen_y = iso(self.x, self.y)
    return screen_x, screen_y - self.current_altitude * block_h
end


function ship:get_camera_target()
    local fx,fy=self.x,self.y
    if not self.is_enemy then
        local best,ne=10
        for e in all(enemies) do
            local d=dist_trig(e.x-fx,e.y-fy)
            if d<best then best=d ne=e end
        end
        self.cam_blend=(self.cam_blend or 0)+(ne and 0.02 or -0.03)
        self.cam_blend=mid(0,self.cam_blend,0.2)
        if ne and self.cam_blend>0 then 
            fx+=(ne.x-fx)*self.cam_blend 
            fy+=(ne.y-fy)*self.cam_blend 
        end
    end
    local sx=(fx-fy)*half_tile_width
    local sy=(fx+fy)*half_tile_height - self.current_altitude*block_h
    return 64-sx,64-sy
end



function ship:draw()
    local sx, sy = self:get_screen_pos()
    local ship_len = self.size * 0.8
    local half_ship_len = ship_len * 0.5

    -- tip + rear corners
    local fx, fy = sx + cos(self.angle) * ship_len, sy + sin(self.angle) * half_ship_len
    local back_angle = self.angle + 0.5
    local p2x = sx + cos(back_angle - 0.15) * ship_len
    local p2y = sy + sin(back_angle - 0.15) * half_ship_len
    local p3x = sx + cos(back_angle + 0.15) * ship_len
    local p3y = sy + sin(back_angle + 0.15) * half_ship_len

    -- shadow
    local terrain_height = terrain_h(self.x, self.y)
    local shadow_offset = (self.current_altitude - terrain_height) * block_h
    draw_triangle(fx, fy + shadow_offset, p2x, p2y + shadow_offset, p3x, p3y + shadow_offset, self.shadow_col)

    -- body
    draw_triangle(fx, fy, p2x, p2y, p3x, p3y, self.body_col)

    -- outline
    line(fx,  fy,  p2x, p2y, self.outline_col)
    line(p2x, p2y, p3x, p3y, self.outline_col)
    line(p3x, p3y, fx,  fy,  self.outline_col)

    -- thrusters
    if self.is_hovering then
        local c = (sin(time() * 5) > 0) and 10 or 9
        pset(p2x, p2y, c)
        pset(p3x, p3y, c)
    end

    -- enemy health bar
    if self.is_enemy then
        local w = self.hp / self.max_hp * 10
        rectfill(sx - 5, sy - 10, sx + 5, sy - 9, 5)
        rectfill(sx - 5, sy - 10, sx - 5 + w, sy - 9, 8)
    end
end


function ship:spawn_particles(num, col_override)
    -- spawn exhaust particles at the ship's position
    particle_sys:spawn(
        self.x, self.y,
        -self.current_altitude * block_h,
        col_override or (terrain_h(self.x,self.y) <= 0 and 7 or 0),
        num
    )
end

function update_projectiles()
    for i=#projectiles,1,-1 do
        local p=projectiles[i]
        p.x+=p.vx p.y+=p.vy p.life-=1

        local targets=p.owner.is_enemy and {player_ship} or enemies
        for t in all(targets) do
            local dx,dy=t.x-p.x,t.y-p.y
            if dx*dx+dy*dy<0.5 then
                t.hp-=3 
                p.life=0
                particle_sys:explode(p.x,p.y,-t.current_altitude*block_h,0.8)
                if t.hp<=0 then
                    sfx(62)
                    particle_sys:explode(t.x,t.y,-t.current_altitude*block_h,3)
                    if t.is_enemy then
                        del(enemies,t)
                        game_manager.player_score+=200
                    end
                end
            end
        end

        if p.life<=0 then deli(projectiles,i) end
    end
end


function ui_say(t,d,c)
    ui_msg=t
    ui_vis,ui_col,ui_until,ui_box_target_h= 0,(c or 7),(d and time()+d or 0),26
end


function ui_tick()
    -- tween box height
    if ui_box_h != ui_box_target_h then
        ui_box_h += (ui_box_target_h - ui_box_h) * 0.2
        if abs(ui_box_h - ui_box_target_h) < 0.5 then ui_box_h = ui_box_target_h end
    end

    -- nothing to type yet or box not expanded
    if ui_msg=="" or ui_box_h<=25 then return end

    -- typewriter
    if ui_vis < #ui_msg then
        ui_vis = min(ui_vis + ((#ui_msg > 15) and 3 or 1), #ui_msg)
    end

    -- timeout ヌ●★ clear & collapse
    if ui_until>0 and time()>ui_until then
        ui_msg="" ui_vis=0 ui_until=0
        ui_box_target_h=6
    end
end




-- COMBAT EVENT
combat_event = {}
combat_event.__index = combat_event

function combat_event.new()
    local self=setmetatable({completed=false,success=false,start_count=0,is_combat=true,last_msg=nil},combat_event)
    ui_say("enemy wave incoming!",3,8)

    local n=min(1+game_manager.difficulty_level,6)
    enemies={}
    for i=1,n do
        local a,d=rnd(1),10+rnd(5)
        local ex=player_ship.x+cos(a)*d
        local ey=player_ship.y+sin(a)*d
        local e=ship.new(ex,ey,true) e.hp=50
        add(enemies,e)
    end
    self.start_count=#enemies
    return self
end



function combat_event:update()
    for e in all(enemies) do e:update() end
    local remaining=#enemies

    if remaining==0 then
        self.completed,self.success=true,true
        game_manager.player_score+=1000
        return
    end

    -- show remaining only after first kill; avoid repeats
    if remaining<self.start_count then
        local msg=(remaining==1) and "1 enemy left" or (remaining.." enemies left")
        if self.last_msg!=msg then ui_say(msg,3,8) self.last_msg=msg end
    end

    if player_ship.hp<=0 then
        self.completed,self.success=true,false
        player_ship.dead=true
        ui_rmsg=""
    end
end


function combat_event:draw()
    for e in all(enemies) do
        e:draw()
        draw_arrow_to(e.x, e.y)
    end
end


function draw_arrow_to(tx,ty)
    local px,py=player_ship.x,player_ship.y
    local dx,dy=tx-px,ty-py
    if dx*dx+dy*dy<4 then return end

    -- orbit point in world space (1.5)
    local a=atan2(dx,dy)
    local sx,sy=iso(px+cos(a)*1.5, py+sin(a)*1.5)
    sy-=player_ship.current_altitude*block_h

    -- screen-facing angle from iso delta
    local sa=atan2((dx-dy)*half_tile_width, (dx+dy)*half_tile_height)

    -- arrow triangle (size 6, color 8)
    local s=6
    local b=sa+0.5
    draw_triangle(
        sx+cos(sa)*s,       sy+sin(sa)*s*0.5,
        sx+cos(b-0.18)*s*.7, sy+sin(b-0.18)*s*.35,
        sx+cos(b+0.18)*s*.7, sy+sin(b+0.18)*s*.35,
        8)
end



-- TILE CLASS
tile = {}
tile.__index = tile

function tile.new(x,y)
    local top,side,dark,h=terrain(x,y)
    local bsx,bsy=(x-y)*half_tile_width,(x+y)*half_tile_height
    local hp=(h>0) and h*block_h or 0

    -- only need south/east for face shading
    local hs,he=terrain_h(x,  y+1),terrain_h(x+1,y)
    local face=((hs<h) and 1 or 0)+((he<h) and 2 or 0)

    return setmetatable({
        x=x,y=y,height=h,
        top_col=top,side_col=side,dark_col=dark,
        base_sx=bsx,base_sy=bsy,
        hp=hp,face=face,
        r=(x+y)&1,
        lb=bsx-half_tile_width,
        rb=bsx+half_tile_width,
        by=bsy+half_tile_height
    },tile)
end



function diamond(sx,sy,c)
    for r=0,half_tile_height do
        local w=half_tile_width-r*2
        line(sx-w,sy-r,sx+w,sy-r,c)
        line(sx-w,sy+r,sx+w,sy+r,c)
    end
end



function tile:draw()
    local sx,sy=cam_offset_x+self.base_sx,cam_offset_y+self.base_sy
    local lb,rb=cam_offset_x+self.lb,cam_offset_x+self.rb

    -- water
    if self.height<=0 then
        diamond(sx,sy,self.top_col)
        local yb=flr(sy+self.r+sin(time()+(self.x+self.y)/8))
        line(lb,yb,rb,yb,(self.height<=-2) and 12 or 1)
        return
    end

    -- land: faces then top (no outer check)
    local hp=self.hp
    local sy2=sy-hp
    local by=cam_offset_y+self.by-hp
    local m=self.face
    for i=0,hp do
        if (m&1)>0 then line(lb,sy2+i,sx,by+i,self.side_col) end
        if (m&2)>0 then line(rb,sy2+i,sx,by+i,self.dark_col) end
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
    self.tiles, self.tile_list = {}, {}
    self.min_x, self.max_x, self.min_y, self.max_y = 0,0,0,0
    self.player_x, self.player_y = self.player_x or 0, self.player_y or 0
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
    local xi,yi=fx&255,fy&255
    local xf,yf=x-fx,y-fy
    local u=xf*xf*(3-2*xf)
    local v=yf*yf*(3-2*yf)

    -- hash corners
    local a,b=p[xi]+yi,p[(xi+1)&255]+yi
    local aa,ab,ba,bb=p[a&255],p[(a+1)&255],p[b&255],p[(b+1)&255]

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
    for i=0,511 do p[i]=rnd(256) end
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
e00eeee000000000eeeeeeeeeeeeeeeeeeeeeeee0000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
e00eee00555555d500eeeeeeeeeeeeeeeeeeeeee0000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
e05ee005d555555d500eeeeeeeeeeeeeeeeeeeee0000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
e05ee0dd5dddddd5dd0eeeeeeeee000000000eee0000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
e05e00ddd6ddddd5dd00eeeeeee0ccc0cc7700ee0000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
e05e05d6d6dddd5ddd50eeeeeee0c1c0cc7770ee0000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
e05005ddd6dddd5dd5500eeeeee0c1c011cc00ee0000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
e00505666d6ddd5ddd5050eeeee0c1c0000000ee0000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
e0650500665555ddd05050eeeee0c1c0cc7700ee0000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
e065000000000000000050eeeee0c1c0cc7770ee0000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
e065000888000088800050eeeee0ccc011cc00ee0000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
e055050088055088005050eeeeee000000000eee0000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
ee050560005665000d5050eeeeeeeeeeeeeeeeee0000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
eee0005665666dddd5000eeeeeeeeeeeeeeeeeee0000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
eeee0506666ddddd5050eeeeeeeeeeeeeeeeeeee0000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
eeee0500666ddddd0050eeeeeeeeeeeeeeeeeeee0000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
eeee0500560000d50050eeee560000d5eeeeeeee0000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
eeee0050506666050500eeee560000d5eeeeeeee0000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
eeeee00050666605000eeeee50666605eeeeeeee0000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
eeeeee0005dddd5000eeeeee00dddd00eeeeeeee0000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
eeeeeee0055555500eeeeeee05555550eeeeeeee0000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
eeeeeeee00000000eeeeeeee00000000eeeeeeee0000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee0000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee0000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
__sfx__
010b00001007300000000000000010675300040000000000100730000010073000001067500000000000000010073000000000000000106750000000000000001007300000000000000010675000000000000000
010b00001007300000000000000010675300040000000000100730000010073000001067500000000000000010073000000000000000106750000000000000001007300000000000000010675000001067510675
c30b0000110400000011040000001104000000110400000011040000001104000000110400000011040000000d040000000d040000000d040000000d040000000f040000000f040000000f040000000f04000000
c30b0000110400000011040000001104000000110400000011040000001104000000110400000011040000000f040000000f040000000f040000000f040000000f040000000f040000000f040000000f04000000
c30b00000d040000000d040000000d040000000d040000000d040000000d040000000d040000000d040000000f040000000f040000000f040000000f040000000f040000000f040000000f040000000f04000000
c30b0000110400000011040000001104000000110400000011040000001104000000110400000011040000000f0420f0420f0420f0420f0420f0420f0420f0420f0420f0420f0420f0420f0420f0420f0420f042
450b0000203300000020330000001d33000000203300000020330000001d33000000203300000024330000001f330000001f330000001b330000001f3300000022330000001b3300000022330000002233000000
450b0000203300000020330000001d33000000203300000020330000001d33000000203300000024330000001b3121b3121b3121b3121b3221b3221b3221b3221b3321b3321b3321b3321b3421b3421b3421b342
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
c70b000020345203451d3451d3451f3451f34520345203451d3451d3451f3451f34520345203451b3451b3451d3451f3001d3051d3301d3051d3001d3251f3001d3051d3201d3051d3001d3151f3001c3051d310
c70b000020345203451d3451d3451f3451f34520345203451d3451d3451f3451f34520345203451b3451b3451c3451f3001d3051c3301d3051d3001c3251f3001d3051c3201d3051d3001c3151f3001c3051c310
d70b00000525505255052550525505255052550525505255052550525505255052550525505255052550525505255052550525505255052550525505255052550525505255052550525505255052550525505255
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
00 41424344
00 41424344
00 41424344
00 41424344
00 41424344
00 41424344
00 41424344
00 41424344
01 21234344
02 22234344

