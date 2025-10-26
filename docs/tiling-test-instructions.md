# Tiling System Test Instructions

## Testing Voronoi Tiling

### Method 1: Using the Test Scene (Recommended)

1. Open Godot editor
2. Open the scene `test_tiling.tscn`
3. In the Inspector panel, check the "Run Voronoi Test" checkbox
4. Watch the console output for progress
5. Generated files will be in the project root:
   - Individual tiles: `voronoi_tile_X_Y.png` and `voronoi_tile_X_Y.exr`
   - Composite image: `voronoi_composite_4x4.png` and `voronoi_composite_4x4.exr`

### Method 2: Manual Testing

1. Open `heightmap_explorer.tscn` or create a new scene
2. Add a `VoronoiGenerator` node (via script)
3. Set parameters:
   ```gdscript
   var gen = VoronoiGenerator.new()
   gen.map_size = 256
   gen.tile_x = 0  # Change this for different tiles
   gen.tile_y = 0  # Change this for different tiles
   gen.seed_value = 12345
   gen.num_points = 8
   gen.generate_heightmap()
   gen.save_heightmap_png("test_tile_0_0.png")
   ```

### What to Look For

1. **Individual Tiles**: Each tile should show a portion of a larger Voronoi pattern
2. **Composite Image**: When arranged in a grid, tiles should connect seamlessly with no visible seams
3. **Console Output**: Should report "PERFECT SEAMLESSNESS!" if tile boundaries match exactly

### Expected Results

- **Seamless boundaries**: Edges of adjacent tiles should have identical height values
- **Continuous patterns**: Voronoi cells should extend naturally across tile boundaries
- **Deterministic**: Same tile coordinates should always produce identical results

## Testing Erosion Tiling (Not Yet Implemented)

Erosion tiling is pending completion of the compute shader updates. The test framework is ready but erosion generation will be skipped until implementation is complete.

## Troubleshooting

### "Voronoi compute shader not initialized"

This error occurs in headless mode because GPU compute shaders require a rendering context. Run the tests from within the Godot editor instead.

### "Cannot load tile image"

If composite generation fails, check that individual tiles were generated successfully first. The script will skip missing tiles.

### Visual Seams Detected

If the verification reports seams, check:
- Are you using the updated `VoronoiGenerator` with `tile_x` and `tile_y` properties?
- Is the compute shader properly compiled (check for shader errors)?
- Are tile positions being set correctly?

## File Locations

All test outputs are saved to the project root directory:

```
erosion_landscape/
├── voronoi_tile_0_0.png    # Individual tiles (PNG for viewing)
├── voronoi_tile_0_0.exr    # Individual tiles (EXR for precision)
├── voronoi_composite_4x4.png    # Full 4x4 grid composite
├── voronoi_composite_4x4.exr    # Full 4x4 grid (high precision)
└── ...
```

## Performance Notes

- Generating a 4x4 grid (16 tiles of 256x256) takes approximately 2-5 seconds on modern hardware
- Each tile generation involves:
  - Hashing 9 tile positions (3x3 neighborhood)
  - Generating points for 9 tiles
  - Computing distances for each pixel to all points
  - Applying height function and scaling

## Next Steps

After verifying Voronoi tiling works correctly:

1. Review the composite images for visual seamlessness
2. Check the console verification output
3. Proceed with erosion tiling implementation
4. Test erosion with padding system
5. Integrate with terrain streaming system
