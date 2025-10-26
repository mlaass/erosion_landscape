# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

This is a Godot 4.3 project that implements procedural terrain generation with hydraulic erosion simulation using compute shaders. The project features Voronoi-based heightmap generation and GPU-accelerated erosion, with real-time visualization and parameter tweaking capabilities.

## Running the Project

- Open the project in Godot 4.3+
- Press F5 or click the Play button to run the main scene
- The project uses the Forward+ renderer

## Project Architecture

### Heightmap Generation System

The project uses a modular generator architecture:

- **HeightmapGenerator** (`src/heightmap_generator.gd`): Abstract base class that defines the common interface for all heightmap generators. Provides utility methods for saving heightmaps as EXR/PNG and creating shader uniforms.

- **VoronoiGenerator** (`src/voronoi_generator.gd`): Generates heightmaps using Voronoi diagrams via compute shader (`src/voronoi_heightmap_compute.glsl`). Supports various scaling types (linear, quadratic, exponential, sigmoid, power, cosine) and ridge effects.

- **ErosionGenerator** (`src/erosion_generator.gd`): Applies hydraulic erosion simulation to existing heightmaps using compute shader (`src/erosion_compute.glsl`). Simulates water droplets that erode and deposit sediment based on physical parameters.

### Controller Architecture

Two controller scripts provide editor integration:

- **ErosionController** (`src/erosion_controller.gd`): Legacy monolithic controller that combines both Voronoi generation and erosion in a single script. Uses `@tool` directive for live editor updates.

- **HeightmapController** (`src/heightmap_controller.gd`): Modern modular controller that uses the generator classes. This is the preferred approach for new development. Manages the current heightmap state and applies generators in sequence.

### Compute Shaders

- **erosion_compute.glsl**: Implements hydraulic erosion algorithm. Each thread simulates a water droplet that flows downhill, eroding terrain based on velocity and sediment capacity. Uses brush patterns for erosion effects.

- **voronoi_heightmap_compute.glsl**: Generates Voronoi cell-based heightmaps with distance-based height falloff and various scaling functions.

### Terrain Rendering

- **terrain-system.gd**: Implements infinite terrain using a tile-based system with 4-texture blending. Generates terrain tiles on-demand based on camera position, with seamless blending at borders.

- **terrain-vertex-shader.gdshader** / **infinite_terrain.gdshader**: Vertex displacement shaders that sample heightmaps to create 3D terrain geometry.

- **heightmap_shader.gdshader**: Shader for rendering heightmaps with normal mapping and ambient occlusion effects, including steep slope banding visualization.

### Player & Controls

- **player_character.gd**: First-person character controller with two modes:
  - Gravity mode: Standard FPS movement with jumping
  - Free-fly mode: Noclip-style 6DOF movement for terrain inspection

- **main.gd**: Orbit camera controller for heightmap preview scenes (mouse drag to rotate, scroll to zoom).

## Key Technical Details

### Compute Shader Parameters

All compute shaders use 16-byte aligned push constants. When modifying parameters:
- Group parameters into 4-float (16-byte) blocks
- Use padding floats to maintain alignment
- Parameters are passed as `PackedFloat32Array`

### Heightmap Format

- Heightmaps use `Image.FORMAT_RF` (single-channel 32-bit float)
- Debug outputs saved as both PNG (8-bit visualization) and EXR (32-bit precision)
- Resolution must be power of 2 for optimal performance (typically 256x256)

### RenderingDevice Usage

All generators use `RenderingServer.create_local_rendering_device()` for compute shader execution:
1. Create storage buffers from packed arrays
2. Create uniform sets binding buffers to shader
3. Dispatch compute shader with appropriate workgroup counts
4. Sync and retrieve results
5. Clean up RIDs to prevent leaks

### Erosion Brush System

The erosion brush defines affected pixels around a droplet:
- Stored as parallel arrays: `brush_indices` (offsets) and `brush_weights` (influence)
- Weights are normalized to sum to 1.0
- Default is 3x3 brush with distance-based falloff

## Common Development Workflows

### Adding New Heightmap Generator

1. Extend `HeightmapGenerator` class
2. Implement `generate_heightmap()` method
3. Create corresponding `.glsl` compute shader
4. Add controls in `HeightmapController` export variables

### Modifying Erosion Parameters

Parameters are in `ErosionGenerator`:
- `num_iterations`: Total droplets to simulate
- `sediment_capacity_factor`: How much sediment water can carry
- `erode_speed`: How quickly terrain erodes
- `deposit_speed`: How quickly sediment deposits
- `inertia`: Droplet momentum (0 = instant direction change, 1 = no turning)

### Debugging Compute Shaders

- Set `debug_output = true` on generator instances
- Check console for parameter validation and height ranges
- Debug images saved to project root as PNG/EXR
- Erosion difference maps show red (erosion) and green (deposition)

## Scene Structure

- **heightmap_explorer.tscn**: Main scene for testing Voronoi and erosion with orbit camera
- **erosion_explorer.tscn**: Alternative erosion testing scene
- **infinite_terrain.tscn**: Demo of infinite tiled terrain system
- **player/player_character.tscn**: First-person character for terrain exploration

## Input Mappings

Defined in `project.godot`:
- WASD: Movement (forward/left/backward/right)
- Space: Jump or ascend (free-fly)
- Shift: Crouch or descend (free-fly)
- Ctrl: Speed boost
- ESC: Toggle mouse capture
- Mouse: Look around (when captured)
- never add attribution to commits