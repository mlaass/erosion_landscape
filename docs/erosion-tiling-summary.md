# Erosion Tiling Implementation Summary

## Overview

The erosion tiling system has been implemented to support seamless, tileable hydraulic erosion across infinite terrain. This is significantly more complex than Voronoi tiling due to the order-dependent nature of erosion simulation.

## Key Implementation Details

### 1. Padding System

**Why Padding is Needed:**
- Droplets can flow across tile boundaries
- Effects from neighboring tiles must be captured
- Without padding, edge artifacts would occur

**How It Works:**
```
Tile (256x256) with 128px padding:
┌─────────────────────────────────┐
│ Padding  │    Tile    │ Padding │
│  (128)   │   (256)    │  (128)  │
├──────────┼────────────┼─────────┤
│          │            │         │
│ Extended Map (512x512)          │
│          │            │         │
└─────────────────────────────────┘

After erosion: Extract center 256x256, discard padding
```

### 2. Deterministic Droplet Generation

**Problem:** Each droplet's behavior affects subsequent droplets (causality)

**Solution:**
1. Generate droplet positions deterministically based on tile coordinates
2. Calculate which droplets could affect current tile (spatial search)
3. Sort all droplets by global deterministic order
4. Simulate in sorted order

**Deterministic Properties:**
- Same tile coordinates → same droplets
- Same global order → same simulation result
- Independent generation → tiles can be created in any order

### 3. Affected Droplets Calculation

```gdscript
For tile at (tx, ty):
  1. Calculate max_travel = max_lifetime * sqrt(2 * gravity)
  2. Search region = extended_bounds ± max_travel
  3. For each tile in search region:
     - Generate droplets for that tile (deterministic)
     - Check if droplet could reach our extended region
     - Add to list with global order hash
  4. Sort by global order
  5. Return sorted list
```

**Example:**
```
Tile (1, 1) with padding=128, max_travel=200:
Search region covers tiles (-1,-1) to (3,3) = 5x5 = 25 tiles
Each tile spawns 500 droplets
Potential droplets: 25 * 500 = 12,500
After spatial filtering: ~2,000 actually affect this tile
```

### 4. World-Space Coordinates

Everything operates in world-space:
- Droplet spawn positions: `world_x = (tile_x + random) * tile_size`
- Extended map offset: `world_min = tile_pos * tile_size - padding`
- Map coordinates: `map_pos = world_pos - world_min`

**Guarantees Consistency:**
- Same world position always has same properties
- Neighboring tiles see same droplets
- Results are independent of generation order

## File Structure

### New Files Created:

1. **`src/erosion_compute_tiled.glsl`** - Tiled erosion compute shader
   - Removed random_indices buffer dependency
   - Uses pre-calculated droplet_positions buffer
   - Supports extended map with padding
   - Added tile position parameters

2. **`src/erosion_generator_tiled.gd`** - Tiled erosion generator
   - `tile_x`, `tile_y` properties for tile position
   - `padding_pixels` configurable padding size
   - `droplets_per_tile` controls droplet density
   - Generates extended Voronoi heightmap
   - Calculates affected droplets
   - Extracts center region after erosion

### Original Files Preserved:

- `src/erosion_compute.glsl` - Original non-tiled version
- `src/erosion_generator.gd` - Original non-tiled version

Both versions coexist for backwards compatibility.

## Algorithm Flow

### Complete Pipeline:

```
1. Setup (ErosionGeneratorTiled.generate_erosion_heightmap_tiled):
   ├─ Calculate extended_size = tile_size + 2 * padding
   └─ Create brush patterns for extended size

2. Generate Extended Voronoi:
   ├─ Calculate world offset for extended region
   ├─ Create VoronoiGenerator with extended size
   └─ Generate seamless Voronoi heightmap

3. Calculate Affected Droplets:
   ├─ Determine search radius (max_travel distance)
   ├─ Find all tiles within search region
   ├─ For each tile:
   │  ├─ Generate droplets deterministically
   │  ├─ Convert to extended map coordinates
   │  └─ Check if within bounds
   ├─ Hash each droplet for global ordering
   └─ Sort by hash value

4. Run Erosion on GPU:
   ├─ Create droplet_positions buffer
   ├─ Pass extended heightmap to shader
   ├─ Simulate all droplets in sorted order
   └─ Droplets can flow freely within extended map

5. Extract Result:
   ├─ Read back eroded heightmap from GPU
   ├─ Extract center tile_size x tile_size region
   ├─ Discard padding
   └─ Return final tile
```

## Compute Shader Changes

### Buffer Layout:

**Old (non-tiled):**
```glsl
binding 0: heightmap[]
binding 1: brush_indices[]
binding 2: brush_weights[]
binding 3: random_indices[]  // Pre-generated positions
```

**New (tiled):**
```glsl
binding 0: heightmap[]
binding 1: brush_indices[]
binding 2: brush_weights[]
binding 3: droplet_positions[]  // Pre-calculated from CPU
```

### Push Constants:

**Added Parameters:**
```glsl
float tile_size;        // Actual tile size (without padding)
float padding_size;     // Padding in pixels
float num_droplets;     // Total droplets to simulate
float tile_world_x;     // Tile X in world grid
float tile_world_y;     // Tile Y in world grid
float global_seed;      // Global deterministic seed
```

### Main Loop Changes:

```glsl
// OLD: Get position from random_indices
float pos_x = float(random_indices[index] % map_size);

// NEW: Get position from pre-calculated list
vec2 spawn_pos = droplet_positions[droplet_id];
float pos_x = spawn_pos.x;
```

## Performance Considerations

### Computational Cost:

**Per-Tile Generation Time (estimated):**
```
Voronoi generation:     ~5ms  (extended size)
Droplet calculation:    ~50ms (CPU-side)
Erosion simulation:     ~200ms (depends on droplet count)
Extraction:             ~2ms
────────────────────────────────
Total:                  ~250-300ms per tile
```

**Factors Affecting Performance:**
- `padding_pixels`: Larger padding = more area to compute
- `droplets_per_tile`: More droplets = longer simulation
- `max_lifetime`: Longer lifetime = more iterations per droplet

### Optimization Strategies:

1. **Reduce Padding** (if acceptable):
   - 64px instead of 128px
   - Requires shorter max_lifetime

2. **Adjust Droplet Density**:
   - Fewer droplets_per_tile (e.g., 300 instead of 500)
   - Trade-off: less detailed erosion

3. **LOD System** (future):
   - Generate distant tiles with fewer droplets
   - Higher detail near camera

4. **Caching**:
   - Save generated tiles to disk
   - Only regenerate when parameters change

## Testing

### How to Test:

1. Open `test_tiling.tscn` in Godot editor
2. Check **"Run Erosion Test"** in Inspector
3. Wait for generation (16 tiles × ~250ms = ~60 seconds for 4x4 grid)
4. Check output files in `output/png/` and `output/exr/`
5. View `erosion_composite_4x4.png` for full grid

### Expected Results:

- **Seamless boundaries:** Erosion patterns should flow naturally across tile edges
- **Deterministic:** Same tile coordinates produce identical results
- **Continuous features:** River-like erosion channels should extend across tiles

### Verification:

The test script will:
1. Generate each tile independently
2. Create composite image
3. Check boundaries for discontinuities
4. Report maximum difference and seam errors

**Success Criteria:**
- Max boundary difference < 0.01 (visually seamless)
- No obvious artifacts at tile boundaries
- Erosion features continuous across grid

## Known Limitations

### Current Implementation:

1. **Generation Time:** ~250-300ms per tile
   - 4x4 grid takes ~60 seconds
   - Acceptable for pre-generation, slow for real-time

2. **Memory Usage:** Extended maps use 4x memory during generation
   - 512x512 temporary map for 256x256 tile
   - Freed after extraction

3. **Droplet Search:** CPU-side calculation can be slow
   - Searching 25 tiles for droplets
   - Could be optimized with spatial partitioning

### Future Improvements:

1. **GPU Droplet Calculation:**
   - Move droplet determination to compute shader
   - Eliminate CPU-side bottleneck

2. **Incremental Erosion:**
   - Support adding more droplets to existing tiles
   - Useful for progressive refinement

3. **Parallel Generation:**
   - Generate multiple tiles simultaneously
   - Use worker threads

## Comparison: Voronoi vs Erosion Tiling

| Aspect | Voronoi | Erosion |
|--------|---------|---------|
| **Complexity** | Simple | Complex |
| **Generation Time** | ~5ms | ~250ms |
| **Padding Required** | No | Yes (128px) |
| **Causality** | None | Order-dependent |
| **Seamlessness** | Perfect | Visually seamless |
| **Memory Overhead** | 1x | 4x (temporary) |
| **CPU Computation** | Minimal | Moderate (droplet calc) |

## Usage Example

```gdscript
# Create erosion generator
var erosion = ErosionGeneratorTiled.new()

# Configure settings
erosion.map_size = 256
erosion.tile_x = 0
erosion.tile_y = 0
erosion.padding_pixels = 128
erosion.droplets_per_tile = 500
erosion.seed_value = 12345

# Erosion parameters
erosion.max_lifetime = 30
erosion.erode_speed = 0.3
erosion.deposit_speed = 0.3

# Generate tile
erosion.generate_heightmap()

# Save result
erosion.save_heightmap_png("tile_0_0.png")
```

## Integration with Terrain System

**Next Steps:**

1. Update `TerrainManager` to use tiled generators:
   ```gdscript
   func _generate_heightmap(tile: TerrainTile):
       # Generate Voronoi
       voronoi_gen.tile_x = tile.position.x
       voronoi_gen.tile_y = tile.position.y
       voronoi_gen.generate_heightmap()

       # Apply erosion
       erosion_gen.tile_x = tile.position.x
       erosion_gen.tile_y = tile.position.y
       erosion_gen.heightmap_image = voronoi_gen.heightmap_image
       erosion_gen.generate_heightmap()

       tile.heightmap = erosion_gen.heightmap_texture
   ```

2. Add caching layer to avoid regeneration

3. Implement streaming/unloading for distant tiles

## Conclusion

The erosion tiling system provides seamless, infinite terrain with hydraulic erosion. While more complex and slower than Voronoi tiling, it produces realistic, naturally-flowing terrain features that extend seamlessly across tile boundaries.

The system is deterministic, allowing tiles to be generated independently in any order while maintaining consistency. This enables true infinite terrain streaming for large-scale game worlds.
