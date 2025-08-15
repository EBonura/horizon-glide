pico-8 cartridge // http://www.pico-8.com
version 41
__lua__
-- ISO TILE DRAWING BENCH • v4 (A3 baseline + anchors + outline-precomp) @30fps
-- ⬅️➡️ switch method; logs CPU every frame

-- ====== constants ======
half_w=12
half_h=6
block_h=2
gw,gh=21,21
cx,cy=64,64

-- ====== helpers ======
function get_cols(h)
  local s="\1\0\0\12\1\1\15\4\2\3\1\0\11\3\1\4\2\0\6\5\0\7\6\5"
  local t={-2,0,2,6,12,18,24,99}
  for i=1,8 do
    if h<=t[i] then
      local p=(i-1)*3+1
      return ord(s,p),ord(s,p+1),ord(s,p+2)
    end
  end
end

-- baseline top (your diamond)
function diamond_baseline(sx,sy,c)
  local dx=half_w
  for r=0,half_h do
    line(sx-dx,sy-r,sx+dx,sy-r,c)
    if r>0 then
      line(sx-dx,sy+r,sx+dx,sy+r,c)
    end
    dx-=2
  end
end

-- ====== grid & tiles ======
tiles={}
tile_list={}
function make_grid()
  srand(1337)
  tiles={}
  tile_list={}
  local ox,oy=-flr(gw/2),-flr(gh/2)
  for y=0,gh-1 do
    tiles[y]={}
    for x=0,gw-1 do
      local r=rnd()
      local h
      if r<0.15 then h=flr(rnd(3))-3
      elseif r<0.6 then h=flr(rnd(6))
      elseif r<0.9 then h=6+flr(rnd(10))
      else h=16+flr(rnd(10)) end
      local wx,wy=ox+x,oy+y
      local t={
        x=wx,y=wy,h=h,
        sx=(wx-wy)*half_w,
        sy=(wx+wy)*half_h
      }
      t.top,t.side,t.dark=get_cols(h)
      tiles[y][x]=t
      add(tile_list,t)
    end
  end
  -- depth sort once
  for i=2,#tile_list do
    local k=tile_list[i]
    local kd=k.x+k.y
    local j=i-1
    while j>=1 and (tile_list[j].x+tile_list[j].y)>kd do
      tile_list[j+1]=tile_list[j]
      j-=1
    end
    tile_list[j+1]=k
  end
end

function get_tile(wx,wy)
  local ox,oy=-flr(gw/2),-flr(gh/2)
  local x=wx-ox
  local y=wy-oy
  if y<0 or y>=gh or x<0 or x>=gw then return nil end
  return tiles[y][x]
end

-- ====== precompute (hp, faces, anchors, outlines, ripple) ======
-- stores per tile:
--  hp_px, face_mask (1=s,2=e), out_mask (1=n,2=w),
--  anchors sx0,sy0,lx0,rx0,by0, water_rip (0/1)
function precompute_meta()
  for t in all(tile_list) do
    local hp=max(0,t.h*block_h)
    t.hp_px=hp

    -- faces (south/east)
    if t.h<=0 then
      t.face_mask=0
    else
      local s=get_tile(t.x, t.y+1)
      local e=get_tile(t.x+1, t.y)
      local ds=(not s) or (s.h<t.h)
      local de=(not e) or (e.h<t.h)
      t.face_mask=(ds and 1 or 0)+(de and 2 or 0)
    end

    -- outlines (north/west)
    do
      local n=get_tile(t.x, t.y-1)
      local w=get_tile(t.x-1, t.y)
      local on=(not n) or (n.h<=t.h)
      local ow=(not w) or (w.h<=t.h)
      t.out_mask=(on and 1 or 0)+(ow and 2 or 0)
    end

    -- screen anchors (cx,cy constant in bench)
    t.sx0=cx+t.sx
    t.sy0=cy+t.sy
    t.lx0=t.sx0-half_w
    t.rx0=t.sx0+half_w
    t.by0=t.sy0+half_h

    -- water ripple parity
    t.water_rip=((t.x+t.y)&1)
  end
end

-- ====== sides (anchored) ======
-- two loops (baseline A3)
function sides_two_loops_anch(lx,rx,sy,by,hp,t,mask)
  if (mask&1)>0 then
    for i=0,hp do line(lx,sy+i, t.sx0,by+i, t.side) end
  end
  if (mask&2)>0 then
    for i=0,hp do line(rx,sy+i, t.sx0,by+i, t.dark) end
  end
end

-- incY (same pixels)
function sides_two_loops_incy_anch(lx,rx,sy,by,hp,t,mask)
  if (mask&1)>0 then
    local y=sy local yy=by
    for i=0,hp do line(lx,y, t.sx0,yy, t.side) y+=1 yy+=1 end
  end
  if (mask&2)>0 then
    local y=sy local yy=by
    for i=0,hp do line(rx,y, t.sx0,yy, t.dark) y+=1 yy+=1 end
  end
end

-- unroll x4 (same pixels)
function sides_two_loops_unroll4_anch(lx,rx,sy,by,hp,t,mask)
  if (mask&1)>0 then
    local y=sy local yy=by local i=0
    while i<=hp do
      line(lx,y,   t.sx0,yy,   t.side)
      if i+1<=hp then line(lx,y+1, t.sx0,yy+1, t.side) end
      if i+2<=hp then line(lx,y+2, t.sx0,yy+2, t.side) end
      if i+3<=hp then line(lx,y+3, t.sx0,yy+3, t.side) end
      y+=4 yy+=4 i+=4
    end
  end
  if (mask&2)>0 then
    local y=sy local yy=by local i=0
    while i<=hp do
      line(rx,y,   t.sx0,yy,   t.dark)
      if i+1<=hp then line(rx,y+1, t.sx0,yy+1, t.dark) end
      if i+2<=hp then line(rx,y+2, t.sx0,yy+2, t.dark) end
      if i+3<=hp then line(rx,y+3, t.sx0,yy+3, t.dark) end
      y+=4 yy+=4 i+=4
    end
  end
end

-- ====== water top (anchored) ======
function draw_water_top_anchors(t)
  local wc=(t.h<=-2) and 1 or 12
  diamond_baseline(t.sx0, t.sy0, wc)
  local yb=t.sy0+t.water_rip
  line(t.lx0,yb,t.rx0,yb,(wc==1) and 12 or 7)
end

-- ====== draw tile (anchored, outline-precomp) ======
function draw_tile_anch(t, side_func_anch)
  if t.h<=0 then
    draw_water_top_anchors(t)
    return
  end
  local hp=t.hp_px
  local mask=t.face_mask
  local sy=t.sy0-hp
  local by=t.by0-hp
  if mask>0 then
    side_func_anch(t.lx0,t.rx0,sy,by,hp,t,mask)
  end
  diamond_baseline(t.sx0,sy,t.top)

  -- outlines via precomputed visibility
  local om=t.out_mask
  if (om&1)>0 then line(t.sx0,sy-half_h, t.sx0+half_w,sy, t.top) end -- north
  if (om&2)>0 then line(t.sx0-half_w,sy, t.sx0,sy-half_h, t.top) end -- west
end

-- ====== control method (measure harness overhead) ======
function draw_tile_ctrl(t)
  -- iterate like others but do nothing (for baseline subtraction)
  -- still compute a couple of locals to keep loop shape similar
  local hp=t.hp_px
  local _sy=t.sy0-hp
  -- no drawing
end

-- ====== methods ======
methods={
  -- CTRL: no draw, to measure baseline CPU for this harness
  {name="CTRL0 loop only (no draw)", kind="ctrl"},

  -- A3 family, anchored sides (your fastest)
  {name="V4 A3 + anchors (2 loops)",       kind="anch", side_anch=sides_two_loops_anch},
  {name="V5 A3 + anchors + incY",          kind="anch", side_anch=sides_two_loops_incy_anch},
  {name="V6 A3 + anchors + unroll x4",     kind="anch", side_anch=sides_two_loops_unroll4_anch},

  -- NEW: outline + ripple precomputed (already applied above), so V7–V9
  {name="V7 anchors+precomp outlines (2 loops)",   kind="anch", side_anch=sides_two_loops_anch},
  {name="V8 anchors+precomp + incY",               kind="anch", side_anch=sides_two_loops_incy_anch},
  {name="V9 anchors+precomp + unroll x4",          kind="anch", side_anch=sides_two_loops_unroll4_anch},
}
midx=2 -- default to V4 (anchors)

-- ====== stats ======
stats={}
function reset_stats(i) stats[i]={n=0,sum=0,minv=1,maxv=0,last=0} end
for i=1,#methods do reset_stats(i) end
last_method_for_sample=midx

-- ====== lifecycle ======
function _init()
  make_grid()
  precompute_meta()
  cls()
  printh("=== ISO TILE DRAW BENCH • v4 (A3 baseline + variants) ===","bench_log.txt")
  printh("tip: record CTRL0 avg and subtract from each method avg","bench_log.txt")
end

function _update()
  -- record CPU for previous frame
  local c=stat(1)
  local s=stats[last_method_for_sample]
  s.n+=1 s.sum+=c s.last=c
  if c<s.minv then s.minv=c end
  if c>s.maxv then s.maxv=c end
  printh(methods[last_method_for_sample].name.." cpu="..c.." avg="..(s.sum/s.n),"bench_log.txt")

  if btnp(➡️) then midx+=1 if midx>#methods then midx=1 end reset_stats(midx)
  elseif btnp(⬅️) then midx-=1 if midx<1 then midx=#methods end reset_stats(midx) end
end

function _draw()
  cls(1)
  local m=methods[midx]
  if m.kind=="ctrl" then
    for t in all(tile_list) do draw_tile_ctrl(t) end
  else
    for t in all(tile_list) do draw_tile_anch(t, m.side_anch) end
  end

  rectfill(0,0,127,11,0)
  print("method: "..m.name,2,2,7)

  last_method_for_sample=midx
  printh("mem: "..tostr(stat(0)).." \t| cpu: "..tostr(stat(1)).." \t| fps: "..tostr(stat(7)))
end
