# Horizon Glide

A retro-styled isometric arcade racing game built in PICO-8.

## About

Horizon Glide is an infinite isometric racing game featuring procedurally generated terrain. Race and fight with your hovering ship through dynamic landscapes with varying elevation, from water levels to mountain peaks.

![Horizon Glide Screenshot](assets/v0%209-restore1_0.png)

## Features

- **Infinite terrain generation** - Explore endless procedurally generated worlds
- **Isometric perspective** - Classic retro arcade racing viewpoint
- **Dynamic terrain** - Multiple biomes with varying heights and colors
- **Customizable settings** - Adjust terrain scale and water levels

## Controls

- Arrow keys: Move your ship
- X shoot
- The ship automatically hovers above the terrain

## Technical Details

Built using PICO-8's Lua scripting with custom implementations for:
- Perlin noise terrain generation
- Tile-based world streaming
- Particle systems for visual effects

## Files

- `v0.9b.p8` - Main game cartridge (latest version)
- `versions/` - Development history
- `tests/` - Testing cartridges for specific features

## Running

Load the cartridge in PICO-8:
```
load horizon-glide/v0.9b.p8
run
```