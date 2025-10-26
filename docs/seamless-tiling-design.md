# Seamless Terrain Tiling System Design

## Overview

This document outlines the mathematical approach and implementation strategy for creating seamless, tileable terrain generation supporting infinite terrain streaming.

**Requirements:**
- Tiles can be generated independently (or with minimal dependency on neighbors)
- Perfect visual seamlessness at tile boundaries
- Deterministic generation (same tile always produces same result)
- Support for both Voronoi heightmap generation and hydraulic erosion
- High visual quality is priority

---

## Core Concept: Stable Random Fields

The fundamental principle is that **everything must be deterministic based on world-space coordinates**, not tile-relative coordinates.

Both Voronoi and erosion will use **spatial hashing** to create deterministic, infinite random fields:

```
hash(world_x, world_y, seed) → deterministic_random_value
```

This allows us to "query" what any tile would contain without actually generating it first.

---

## 1. Voronoi Tiling Approach

### Mathematical Foundation

**Problem**: Traditional Voronoi generation creates points in [0,1] normalized space, which doesn't tile seamlessly.

**Solution**: Generate Voronoi points in world-space coordinates using deterministic spatial hashing.

### Algorithm: World-Space Voronoi with Virtual Neighbors

```
For tile at world grid position (tile_x, tile_y):

  Step 1: Calculate world bounds
  ────────────────────────────────
  world_min = (tile_x * TILE_SIZE, tile_y * TILE_SIZE)
  world_max = world_min + (TILE_SIZE, TILE_SIZE)

  Step 2: Generate Voronoi points for 3x3 tile neighborhood
  ──────────────────────────────────────────────────────────
  points = []

  for neighbor_offset in [(-1,-1), (-1,0), (-1,1),
                          ( 0,-1), ( 0, 0), ( 0, 1),
                          ( 1,-1), ( 1, 0), ( 1, 1)]:

    neighbor_tile_pos = (tile_x, tile_y) + neighbor_offset

    // Deterministic RNG seeded by tile position
    rng_seed = hash(neighbor_tile_pos.x,
                    neighbor_tile_pos.y,
                    global_seed)
    rng.seed = rng_seed

    // Generate N Voronoi points in WORLD coordinates
    for i in range(num_points_per_tile):
      point_x = (neighbor_tile_pos.x + rng.randf()) * TILE_SIZE
      point_y = (neighbor_tile_pos.y + rng.randf()) * TILE_SIZE
      points.append(vec2(point_x, point_y))

  Step 3: Calculate height for each pixel
  ────────────────────────────────────────
  for pixel_y in range(TILE_SIZE):
    for pixel_x in range(TILE_SIZE):
      // Convert to world coordinates
      world_pos = world_min + vec2(pixel_x, pixel_y)

      // Find nearest Voronoi point from ALL 9 tiles
      nearest_dist = infinity
      for point in points:
        dist = distance(world_pos, point)
        nearest_dist = min(nearest_dist, dist)

      // Apply height function
      height[pixel_y][pixel_x] = height_function(nearest_dist)
```

### Seamlessness Guarantee

**Why this works:**

Consider a pixel at the boundary between tiles A and B:
- When generating tile A: pixel sees Voronoi points from tiles around A
- When generating tile B: same pixel sees Voronoi points from tiles around B
- Both see the **same set of points** because points are in world-space
- Therefore: **same nearest point → same distance → same height**

The 3x3 neighborhood ensures that even corner pixels can see all relevant Voronoi points.

### Hash Function Requirements

```glsl
// Must be:
// 1. Deterministic (same input → same output)
// 2. Well-distributed (no obvious patterns)
// 3. Fast to compute

uint hash(ivec2 tile_pos, uint seed) {
  // Example implementation using prime number mixing
  uint h = seed;
  h ^= tile_pos.x * 374761393u;
  h ^= tile_pos.y * 668265263u;
  h ^= h >> 13;
  h *= 1274126177u;
  h ^= h >> 16;
  return h;
}

float random(uint seed, uint index) {
  uint h = seed ^ (index * 747796405u);
  h = ((h >> 16) ^ h) * 0x45d9f3bu;
  h = ((h >> 16) ^ h) * 0x45d9f3bu;
  h = (h >> 16) ^ h;
  return float(h) / 4294967296.0; // [0, 1)
}
```

---

## 2. Erosion Tiling Approach

### The Challenge

Hydraulic erosion is fundamentally **causal and order-dependent**:

```
Timeline:
  t=0: Droplet A spawns, erodes position X
  t=1: Heightmap at X is now changed
  t=2: Droplet B flows over position X, behavior affected by erosion
```

If we generate tiles independently without coordination, we get:
- Tile 1: Droplet A erodes, Droplet B responds to erosion
- Tile 2: Droplet B might not see Droplet A's effects if A started in Tile 1

**Result**: Seams at boundaries where erosion patterns don't match.

### Solution: Deterministic Erosion with Virtual Padding

**Strategy**: Create a global, deterministic ordering of ALL droplets in world-space, then simulate only the ones affecting the current tile (plus padding).

#### Key Innovations

1. **Deterministic Droplet Spawning**: Every droplet position is determined by spatial hash
2. **Global Ordering**: Droplets have a consistent execution order across all tiles
3. **Virtual Padding**: Generate extended heightmap to capture erosion flowing from neighbors
4. **Spatial Culling**: Only simulate droplets that could affect the current tile

### Algorithm: Padded Erosion Simulation

```
For tile at (tile_x, tile_y):

  Step 1: Create extended heightmap with padding
  ───────────────────────────────────────────────
  PADDING = 64  // pixels, tune based on max_droplet_travel
  extended_size = TILE_SIZE + 2 * PADDING

  extended_map = allocate_heightmap(extended_size, extended_size)

  Step 2: Fill extended region using Voronoi
  ───────────────────────────────────────────
  extended_world_min = (tile_x * TILE_SIZE - PADDING,
                        tile_y * TILE_SIZE - PADDING)

  // Use Voronoi algorithm to fill entire extended region
  // This gives us the "pre-erosion" heightmap including borders
  generate_voronoi_for_region(extended_map,
                               extended_world_min,
                               extended_size)

  Step 3: Determine which droplets affect this tile
  ──────────────────────────────────────────────────
  // Calculate maximum distance a droplet can travel
  max_travel = max_lifetime * sqrt(2 * gravity * max_height)

  // Search region (droplets outside could flow in)
  search_min = extended_world_min - vec2(max_travel, max_travel)
  search_max = search_min + vec2(extended_size + 2*max_travel,
                                  extended_size + 2*max_travel)

  // Determine which tiles intersect search region
  tile_min = floor(search_min / TILE_SIZE)
  tile_max = ceil(search_max / TILE_SIZE)

  affected_droplets = []

  for ty in range(tile_min.y, tile_max.y + 1):
    for tx in range(tile_min.x, tile_max.x + 1):
      // Deterministic seed for this tile's droplets
      tile_seed = hash(ivec2(tx, ty), global_seed, "droplets")

      for i in range(droplets_per_tile):
        // Deterministic spawn position in WORLD space
        rx = random(tile_seed, i * 2)
        ry = random(tile_seed, i * 2 + 1)

        world_spawn = vec2((tx + rx) * TILE_SIZE,
                           (ty + ry) * TILE_SIZE)

        // Convert to extended map coordinates
        map_pos = world_spawn - extended_world_min

        // Check if droplet could affect extended region
        if (map_pos.x >= -max_travel &&
            map_pos.x <= extended_size + max_travel &&
            map_pos.y >= -max_travel &&
            map_pos.y <= extended_size + max_travel):

          affected_droplets.append({
            world_pos: world_spawn,
            map_pos: map_pos,
            order: hash(world_spawn, global_seed, "order")
          })

  Step 4: Sort droplets by global deterministic order
  ────────────────────────────────────────────────────
  affected_droplets.sort_by(droplet.order)

  Step 5: Simulate erosion with all affected droplets
  ────────────────────────────────────────────────────
  for droplet in affected_droplets:
    simulate_droplet_erosion(extended_map, droplet.map_pos)

  Step 6: Extract center region, discard padding
  ───────────────────────────────────────────────
  final_tile = extended_map[PADDING : PADDING + TILE_SIZE,
                             PADDING : PADDING + TILE_SIZE]

  return final_tile
```

### Seamlessness Guarantee

**Why this works:**

Consider a droplet that flows across the boundary between tiles A and B:

**When generating Tile A:**
- Extended map includes padding into Tile B's region
- Droplet simulated on extended map
- Effects captured in Tile A's portion

**When generating Tile B:**
- Extended map includes padding into Tile A's region
- Same droplet simulated (same world position → same hash → same order)
- Same heightmap state when droplet runs (deterministic ordering)
- Same simulation result → same effects in Tile B's portion

**Critical requirements:**
1. Droplet positions must be deterministic (✓ spatial hash)
2. Droplet order must be consistent (✓ global sort by hash)
3. Heightmap state must be identical (✓ same Voronoi, same droplets)
4. Simulation must be deterministic (✓ already true in current code)

### Padding Size Calculation

```
Required padding ≥ maximum droplet travel distance

max_travel = max_lifetime * average_speed

where:
  average_speed ≈ sqrt(gravity * average_height * 2)

Recommended:
  PADDING = 2 * max_travel  // Safety margin

Typical values:
  max_lifetime = 30
  gravity = 10
  average_height ≈ 0.5
  → max_travel ≈ 30 * sqrt(10 * 0.5 * 2) ≈ 95 pixels
  → PADDING = 128 pixels (power of 2 for convenience)
```

### Performance Optimization

**Problem**: Simulating all droplets for extended region is expensive.

**Optimizations:**

1. **Spatial Culling**: Only simulate droplets that could reach the tile
   - Start position check: `distance(spawn_pos, tile_center) < max_travel + tile_radius`

2. **Early Termination**: Stop droplets that exit extended region
   ```glsl
   if (droplet.pos.x < 0 || droplet.pos.x >= extended_size ||
       droplet.pos.y < 0 || droplet.pos.y >= extended_size) {
     break; // Droplet left our region
   }
   ```

3. **Workgroup Distribution**: Distribute droplets across GPU workgroups efficiently
   ```glsl
   // One droplet per thread, not one iteration per thread
   layout(local_size_x = 256) in;

   void main() {
     uint droplet_id = gl_GlobalInvocationID.x;
     if (droplet_id >= num_affected_droplets) return;

     simulate_droplet(droplet_id);
   }
   ```

---

## 3. Compute Shader Implementation

### Modified Voronoi Shader

**File**: `src/voronoi_heightmap_compute.glsl`

```glsl
#[compute]
#version 450

layout(local_size_x = 16, local_size_y = 16, local_size_z = 1) in;

// Output heightmap buffer
layout(set = 0, binding = 0, std430) restrict buffer HeightMapBuffer {
  float heightmap[];
} height_map;

// No longer need points buffer - generate on the fly!

layout(push_constant) uniform Params {
  // Block 1
  float map_size;              // Tile size (e.g. 256)
  float num_points_per_tile;   // Points per tile (e.g. 10)
  float tile_world_x;          // Tile position in world grid
  float tile_world_y;

  // Block 2
  float height_falloff;
  float min_height;
  float max_height;
  float ridge_multiplier;

  // Block 3
  float amplitude;
  float scaling_type;
  float global_seed;
  float padding_1;
} params;

// Spatial hash function
uint hash(ivec2 tile_pos, uint seed) {
  uint h = seed;
  h ^= uint(tile_pos.x) * 374761393u;
  h ^= uint(tile_pos.y) * 668265263u;
  h ^= h >> 13;
  h *= 1274126177u;
  h ^= h >> 16;
  return h;
}

// Convert hash to float [0, 1)
float random(uint seed, uint index) {
  uint h = seed ^ (index * 747796405u);
  h = ((h >> 16) ^ h) * 0x45d9f3bu;
  h = ((h >> 16) ^ h) * 0x45d9f3bu;
  h = (h >> 16) ^ h;
  return float(h) / 4294967296.0;
}

// Generate Voronoi points for 3x3 neighborhood
const int MAX_POINTS = 90; // 9 tiles * 10 points
vec2 world_points[MAX_POINTS];
int num_world_points;

void generate_world_points() {
  num_world_points = 0;
  int points_per_tile = int(params.num_points_per_tile);

  // Iterate through 3x3 neighborhood
  for (int dy = -1; dy <= 1; dy++) {
    for (int dx = -1; dx <= 1; dx++) {
      ivec2 neighbor_tile = ivec2(
        int(params.tile_world_x) + dx,
        int(params.tile_world_y) + dy
      );

      uint tile_seed = hash(neighbor_tile, uint(params.global_seed));

      // Generate points for this tile in world coordinates
      for (int i = 0; i < points_per_tile; i++) {
        float rx = random(tile_seed, uint(i * 2));
        float ry = random(tile_seed, uint(i * 2 + 1));

        world_points[num_world_points++] = vec2(
          (float(neighbor_tile.x) + rx) * params.map_size,
          (float(neighbor_tile.y) + ry) * params.map_size
        );
      }
    }
  }
}

void main() {
  ivec2 pixel = ivec2(gl_GlobalInvocationID.xy);

  if (pixel.x >= int(params.map_size) ||
      pixel.y >= int(params.map_size)) {
    return;
  }

  // Generate points for neighborhood
  generate_world_points();

  // Calculate world position of this pixel
  vec2 world_pos = vec2(
    params.tile_world_x * params.map_size + float(pixel.x),
    params.tile_world_y * params.map_size + float(pixel.y)
  );

  // Find nearest Voronoi point
  float min_dist = 1e10;
  for (int i = 0; i < num_world_points; i++) {
    float dist = distance(world_pos, world_points[i]);
    min_dist = min(min_dist, dist);
  }

  // Apply height function (same as current implementation)
  float normalized_dist = min_dist / params.map_size;
  float height;

  // Apply scaling type
  int scale_type = int(params.scaling_type);
  if (scale_type == 0) { // LINEAR
    height = normalized_dist;
  } else if (scale_type == 1) { // QUADRATIC
    height = normalized_dist * normalized_dist;
  } else if (scale_type == 2) { // EXPONENTIAL
    height = exp(params.height_falloff * normalized_dist) - 1.0;
    height /= exp(params.height_falloff) - 1.0;
  } else if (scale_type == 3) { // POWER
    height = pow(normalized_dist, params.height_falloff);
  }
  // ... other scaling types

  // Apply min/max and amplitude
  height = mix(params.min_height, params.max_height, height);
  height *= params.amplitude;

  // Ridge effect
  if (params.ridge_multiplier != 0.0) {
    height = abs(height - 0.5) * 2.0 * params.ridge_multiplier +
             height * (1.0 - params.ridge_multiplier);
  }

  // Write to buffer
  int index = pixel.y * int(params.map_size) + pixel.x;
  height_map.heightmap[index] = height;
}
```

### Modified Erosion Shader

**File**: `src/erosion_compute.glsl`

```glsl
#[compute]
#version 450

layout(local_size_x = 256, local_size_y = 1, local_size_z = 1) in;

// Heightmap buffer (extended size with padding)
layout(set = 0, binding = 0, std430) restrict buffer HeightMapBuffer {
  float heightmap[];
} height_map;

// Brush indices and weights (unchanged)
layout(set = 0, binding = 1, std430) restrict readonly buffer BrushIndicesBuffer {
  int brush_indices[];
} brush_data;

layout(set = 0, binding = 2, std430) restrict readonly buffer BrushWeightsBuffer {
  float brush_weights[];
} brush_weights;

// NO MORE random_indices buffer - calculate on the fly!

layout(push_constant) uniform Params {
  // Block 1
  float map_size;              // Extended size (TILE_SIZE + 2*PADDING)
  float brush_length;
  float brush_radius;
  float max_lifetime;

  // Block 2
  float inertia;
  float sediment_capacity_factor;
  float min_sediment_capacity;
  float deposit_speed;

  // Block 3
  float erode_speed;
  float evaporate_speed;
  float gravity;
  float start_speed;

  // Block 4
  float start_water;
  float tile_world_x;          // NEW
  float tile_world_y;          // NEW
  float padding_size;          // NEW

  // Block 5
  float global_seed;           // NEW
  float droplets_per_tile;     // NEW
  float num_droplets;          // NEW: total droplets to simulate
  float padding_3;
} params;

// Hash functions (same as Voronoi)
uint hash(ivec2 tile_pos, uint seed) {
  uint h = seed;
  h ^= uint(tile_pos.x) * 374761393u;
  h ^= uint(tile_pos.y) * 668265263u;
  h ^= h >> 13;
  h *= 1274126177u;
  h ^= h >> 16;
  return h;
}

float random(uint seed, uint index) {
  uint h = seed ^ (index * 747796405u);
  h = ((h >> 16) ^ h) * 0x45d9f3bu;
  h = ((h >> 16) ^ h) * 0x45d9f3bu;
  h = (h >> 16) ^ h;
  return float(h) / 4294967296.0;
}

// Calculate gradient at position
vec2 calculate_gradient(vec2 pos) {
  int map_size = int(params.map_size);
  ivec2 coord = ivec2(pos);

  if (coord.x <= 0 || coord.x >= map_size - 1 ||
      coord.y <= 0 || coord.y >= map_size - 1) {
    return vec2(0.0);
  }

  int idx = coord.y * map_size + coord.x;
  float height_l = height_map.heightmap[idx - 1];
  float height_r = height_map.heightmap[idx + 1];
  float height_d = height_map.heightmap[idx - map_size];
  float height_u = height_map.heightmap[idx + map_size];

  return vec2(height_r - height_l, height_u - height_d);
}

void simulate_droplet(vec2 start_pos) {
  vec2 pos = start_pos;
  vec2 dir = vec2(0.0);
  float speed = params.start_speed;
  float water = params.start_water;
  float sediment = 0.0;
  int map_size = int(params.map_size);

  for (int lifetime = 0; lifetime < int(params.max_lifetime); lifetime++) {
    // Check if droplet left the map
    if (pos.x < params.brush_radius ||
        pos.x >= params.map_size - params.brush_radius ||
        pos.y < params.brush_radius ||
        pos.y >= params.map_size - params.brush_radius) {
      break; // Droplet exited extended region
    }

    // Calculate gradient and move droplet
    vec2 gradient = calculate_gradient(pos);

    // Update direction with inertia
    dir = dir * params.inertia - gradient * (1.0 - params.inertia);
    dir = normalize(dir);

    vec2 new_pos = pos + dir;

    // Sample heights
    int idx_old = int(pos.y) * map_size + int(pos.x);
    int idx_new = int(new_pos.y) * map_size + int(new_pos.x);

    float height_old = height_map.heightmap[idx_old];
    float height_new = height_map.heightmap[idx_new];
    float height_delta = height_new - height_old;

    // Calculate sediment capacity
    float capacity = max(-height_delta * speed * water *
                        params.sediment_capacity_factor,
                        params.min_sediment_capacity);

    // Erode or deposit
    if (sediment > capacity || height_delta > 0.0) {
      // Deposit
      float amount = (sediment - capacity) * params.deposit_speed;
      sediment -= amount;

      // Apply to brush area
      for (int i = 0; i < int(params.brush_length); i++) {
        int brush_idx = idx_old + brush_data.brush_indices[i];
        if (brush_idx >= 0 && brush_idx < map_size * map_size) {
          height_map.heightmap[brush_idx] +=
            amount * brush_weights.brush_weights[i];
        }
      }
    } else {
      // Erode
      float amount = min((capacity - sediment) * params.erode_speed,
                         -height_delta);

      for (int i = 0; i < int(params.brush_length); i++) {
        int brush_idx = idx_old + brush_data.brush_indices[i];
        if (brush_idx >= 0 && brush_idx < map_size * map_size) {
          height_map.heightmap[brush_idx] -=
            amount * brush_weights.brush_weights[i];
        }
      }

      sediment += amount;
    }

    // Update droplet properties
    speed = sqrt(speed * speed + height_delta * params.gravity);
    water *= (1.0 - params.evaporate_speed);

    pos = new_pos;
  }
}

void main() {
  uint global_droplet_id = gl_GlobalInvocationID.x;

  if (global_droplet_id >= uint(params.num_droplets)) {
    return;
  }

  // Determine which tile this droplet belongs to
  // This is pre-calculated on CPU and passed in droplet list
  // For now, assume we have a deterministic mapping

  // TODO: CPU side provides list of affected droplets
  // For each droplet: (tile_x, tile_y, local_index, order_hash)

  // This is simplified - full implementation needs CPU-side
  // calculation of affected droplets

  // Placeholder: would receive droplet spawn position
  // from a structured buffer calculated on CPU
  vec2 spawn_pos = vec2(0.0); // TODO: from buffer

  simulate_droplet(spawn_pos);
}
```

**Note**: The erosion shader is more complex and requires CPU-side preprocessing to determine the list of affected droplets. The full implementation needs a two-stage approach:

1. **CPU Stage**: Calculate which droplets affect the current tile
2. **GPU Stage**: Simulate only those droplets

---

## 4. GDScript Implementation Changes

### VoronoiGenerator Modifications

**File**: `src/voronoi_generator.gd`

```gdscript
@tool
extends HeightmapGenerator
class_name VoronoiGenerator

# ... existing properties ...

# NEW: Tile position for seamless tiling
var tile_x: int = 0
var tile_y: int = 0

func generate_voronoi_heightmap():
  if not rd:
      rd = RenderingServer.create_local_rendering_device()

  if not voronoi_compute_shader:
      printerr("Voronoi compute shader not initialized")
      return

  # Generate random points - NO LONGER NEEDED
  # Points are generated in shader from tile position

  # Create buffers
  var heightmap_buffer = rd.storage_buffer_create(map_size * map_size * 4)
  # NO points_buffer needed!

  # Create uniform set
  var uniforms := [
      create_uniform(heightmap_buffer, 0),
  ]

  var pipeline = rd.compute_pipeline_create(voronoi_compute_shader)
  var uniform_set = rd.uniform_set_create(uniforms, voronoi_compute_shader, 0)

  # Set parameters with tile position
  var params := PackedFloat32Array([
      # Block 1
      float(map_size),
      float(num_points),
      float(tile_x),              # NEW
      float(tile_y),              # NEW

      # Block 2
      height_falloff,
      min_height,
      max_height,
      ridge_multiplier,

      # Block 3
      amplitude,
      float(scaling_type),
      float(seed_value),          # global_seed
      0.0,  # padding
  ])

  # Dispatch compute shader
  var compute_list = rd.compute_list_begin()
  rd.compute_list_bind_compute_pipeline(compute_list, pipeline)
  rd.compute_list_bind_uniform_set(compute_list, uniform_set, 0)
  rd.compute_list_set_push_constant(compute_list, params.to_byte_array(), params.size() * 4)

  var workgroup_size = 16
  var num_workgroups = (map_size + workgroup_size - 1) / workgroup_size
  rd.compute_list_dispatch(compute_list, num_workgroups, num_workgroups, 1)

  rd.compute_list_end()
  rd.submit()
  rd.sync()

  # Get results
  var output_bytes = rd.buffer_get_data(heightmap_buffer)
  var height_data = output_bytes.to_float32_array()

  # Cleanup
  rd.free_rid(heightmap_buffer)

  # Create heightmap image
  heightmap_image = Image.create(map_size, map_size, false, Image.FORMAT_RF)
  for y in range(map_size):
      for x in range(map_size):
          var height = height_data[y * map_size + x]
          heightmap_image.set_pixel(x, y, Color(height, 0, 0, 0))

  heightmap_image.generate_mipmaps()
  heightmap_texture = ImageTexture.create_from_image(heightmap_image)

  if debug_output:
    save_debug_image(heightmap_image, "voronoi_tile_%d_%d" % [tile_x, tile_y])
```

### ErosionGenerator Modifications

**File**: `src/erosion_generator.gd`

```gdscript
@tool
extends HeightmapGenerator
class_name ErosionGenerator

# ... existing properties ...

# NEW: Tile position and padding
var tile_x: int = 0
var tile_y: int = 0
var padding_pixels: int = 128

func generate_erosion_heightmap():
  if not rd or not heightmap_image:
    printerr("No rendering device or heightmap")
    return

  var tile_size = map_size
  var extended_size = tile_size + 2 * padding_pixels

  # Step 1: Create extended heightmap with padding
  # Fill using Voronoi in world-space
  var voronoi_gen = VoronoiGenerator.new()
  voronoi_gen.map_size = extended_size
  voronoi_gen.tile_x = tile_x  # Adjust for padding offset
  voronoi_gen.tile_y = tile_y
  voronoi_gen.seed_value = seed_value
  # ... copy other voronoi parameters ...

  # IMPORTANT: Account for padding offset
  # The extended map starts at world position:
  # (tile_x * tile_size - padding, tile_y * tile_size - padding)
  # Need to calculate effective tile position for Voronoi
  var world_offset_x = float(tile_x * tile_size - padding_pixels)
  var world_offset_y = float(tile_y * tile_size - padding_pixels)
  voronoi_gen.tile_x = floor(world_offset_x / extended_size)
  voronoi_gen.tile_y = floor(world_offset_y / extended_size)

  voronoi_gen.generate_heightmap()
  var extended_heightmap = voronoi_gen.heightmap_image

  # Step 2: Calculate affected droplets
  var affected_droplets = calculate_affected_droplets(
    tile_x, tile_y, tile_size, padding_pixels
  )

  print("Tile (%d, %d): %d affected droplets" % [
    tile_x, tile_y, affected_droplets.size()
  ])

  # Step 3: Convert extended heightmap to buffer
  var map_data = PackedFloat32Array()
  map_data.resize(extended_size * extended_size)

  for y in range(extended_size):
    for x in range(extended_size):
      map_data[y * extended_size + x] = extended_heightmap.get_pixel(x, y).r

  # Step 4: Run erosion on GPU
  # TODO: Need to restructure compute shader to accept droplet list
  # For now, this is a placeholder

  # Step 5: Extract center region
  heightmap_image = Image.create(tile_size, tile_size, false, Image.FORMAT_RF)
  for y in range(tile_size):
    for x in range(tile_size):
      var src_x = x + padding_pixels
      var src_y = y + padding_pixels
      var height = map_data[src_y * extended_size + src_x]
      heightmap_image.set_pixel(x, y, Color(height, 0, 0, 0))

  heightmap_image.generate_mipmaps()
  heightmap_texture = ImageTexture.create_from_image(heightmap_image)

func calculate_affected_droplets(tx: int, ty: int,
                                  tile_size: int,
                                  padding: int) -> Array:
  """
  Calculate which droplets could affect this tile.
  Returns array of: {world_pos: Vector2, order: int}
  """
  var droplets = []

  # Calculate search bounds in world space
  var max_travel = max_lifetime * sqrt(2 * gravity * 1.0)  # Assume max height = 1.0

  var world_min = Vector2(
    tx * tile_size - padding - max_travel,
    ty * tile_size - padding - max_travel
  )
  var world_max = Vector2(
    (tx + 1) * tile_size + padding + max_travel,
    (ty + 1) * tile_size + padding + max_travel
  )

  # Determine tile range to check
  var tile_min_x = floor(world_min.x / tile_size)
  var tile_min_y = floor(world_min.y / tile_size)
  var tile_max_x = ceil(world_max.x / tile_size)
  var tile_max_y = ceil(world_max.y / tile_size)

  var rng = RandomNumberGenerator.new()

  for search_ty in range(tile_min_y, tile_max_y + 1):
    for search_tx in range(tile_min_x, tile_max_x + 1):
      # Deterministic seed for this tile
      var tile_seed = hash_tile_position(search_tx, search_ty, seed_value)
      rng.seed = tile_seed

      # Generate droplets for this tile
      for i in range(num_iterations / 100):  # Adjust droplets_per_tile
        var rx = rng.randf()
        var ry = rng.randf()

        var world_spawn = Vector2(
          (search_tx + rx) * tile_size,
          (search_ty + ry) * tile_size
        )

        # Check if this droplet could affect our region
        if (world_spawn.x >= world_min.x and world_spawn.x <= world_max.x and
            world_spawn.y >= world_min.y and world_spawn.y <= world_max.y):

          droplets.append({
            "world_pos": world_spawn,
            "order": hash_position(world_spawn, seed_value)
          })

  # Sort by global order
  droplets.sort_custom(func(a, b): return a.order < b.order)

  return droplets

func hash_tile_position(tx: int, ty: int, seed: int) -> int:
  var h = seed
  h ^= tx * 374761393
  h ^= ty * 668265263
  h ^= h >> 13
  h *= 1274126177
  h ^= h >> 16
  return h

func hash_position(pos: Vector2, seed: int) -> int:
  var h = seed
  h ^= int(pos.x * 1000.0) * 374761393
  h ^= int(pos.y * 1000.0) * 668265263
  h ^= h >> 13
  h *= 1274126177
  h ^= h >> 16
  return h
```

---

## 5. Testing Strategy

### Phase 1: Voronoi Tiling Test

1. **Single Tile Baseline**
   ```gdscript
   var gen = VoronoiGenerator.new()
   gen.tile_x = 0
   gen.tile_y = 0
   gen.map_size = 256
   gen.seed_value = 12345
   gen.generate_heightmap()
   gen.save_heightmap_png("test_tile_0_0.png")
   ```

2. **Adjacent Tiles**
   ```gdscript
   # Generate 2x2 grid
   for ty in range(2):
     for tx in range(2):
       gen.tile_x = tx
       gen.tile_y = ty
       gen.generate_heightmap()
       gen.save_heightmap_png("test_tile_%d_%d.png" % [tx, ty])
   ```

3. **Seamlessness Verification**
   - Load all 4 tiles in image editor
   - Arrange in 2x2 grid
   - Zoom in on boundaries
   - Check for discontinuities

4. **Pixel-Perfect Test**
   ```gdscript
   # Generate tile (0, 0) and tile (1, 0)
   # Compare right edge of (0,0) with left edge of (1,0)

   var tile_00 = generate_tile(0, 0)
   var tile_10 = generate_tile(1, 0)

   for y in range(256):
     var edge_00 = tile_00.get_pixel(255, y).r
     var edge_10 = tile_10.get_pixel(0, y).r
     assert(abs(edge_00 - edge_10) < 0.001,
            "Seam detected at y=%d" % y)
   ```

### Phase 2: Erosion Tiling Test

1. **Padding Verification**
   - Generate extended map, save before erosion
   - Verify padding region contains correct Voronoi data

2. **Droplet Count Test**
   - Log number of affected droplets per tile
   - Verify reasonable numbers (not too many/few)

3. **Determinism Test**
   ```gdscript
   # Generate same tile twice
   var tile_a = generate_eroded_tile(0, 0)
   var tile_b = generate_eroded_tile(0, 0)

   # Should be pixel-identical
   for y in range(256):
     for x in range(256):
       assert(tile_a.get_pixel(x,y) == tile_b.get_pixel(x,y))
   ```

4. **Boundary Erosion Test**
   - Generate tiles with droplets that cross boundaries
   - Verify erosion patterns match at edges

---

## 6. Performance Considerations

### Expected Performance

**Voronoi Generation:**
- Current: ~5ms for 256x256 tile (9 tiles worth of points)
- Overhead: Minimal (hash calculations are fast)

**Erosion Generation:**
- Current: ~50ms for 256x256 tile with 50k iterations
- With padding: ~80ms (128px padding ≈ 1.5x area)
- With droplet culling: ~60ms (fewer droplets to simulate)

### Optimization Strategies

1. **Tile Caching**
   ```gdscript
   var tile_cache: Dictionary = {}  # Key: Vector2i(tx, ty), Value: Image

   func get_tile(tx: int, ty: int) -> Image:
     var key = Vector2i(tx, ty)
     if not tile_cache.has(key):
       tile_cache[key] = generate_tile(tx, ty)
     return tile_cache[key]
   ```

2. **Async Generation**
   ```gdscript
   func generate_tile_async(tx: int, ty: int) -> void:
     # Run in separate thread
     var thread = Thread.new()
     thread.start(_generate_tile_thread.bind(tx, ty))
   ```

3. **LOD System**
   - Generate lower resolution tiles for distant terrain
   - Progressively refine as player approaches

---

## 7. Integration with Terrain System

### Update TerrainManager

**File**: `src/terrain-system.gd`

```gdscript
class_name TerrainManager
extends Node

const TILE_SIZE := 256
const BLEND_BORDER := 32

@onready var terrain_mesh: MeshInstance3D = $TerrainMesh
var terrain_material: ShaderMaterial

var tiles: Dictionary = {}  # Key: Vector2i, Value: TerrainTile
var voronoi_generator: VoronoiGenerator
var erosion_generator: ErosionGenerator

class TerrainTile:
    var position: Vector2i
    var heightmap: ImageTexture
    var distance_to_camera: float

    func _init(pos: Vector2i):
        position = pos
        heightmap = null

func _ready():
    terrain_material = terrain_mesh.get_surface_override_material(0)

    # Create generators
    voronoi_generator = VoronoiGenerator.new()
    erosion_generator = ErosionGenerator.new()

    # Configure generators
    voronoi_generator.map_size = TILE_SIZE
    erosion_generator.map_size = TILE_SIZE
    # ... set other parameters ...

    _update_shader_uniforms(Vector3.ZERO)

func update_terrain(camera_position: Vector3):
    var camera_tile := Vector2i(
        floor(camera_position.x / TILE_SIZE),
        floor(camera_position.z / TILE_SIZE)
    )

    var needed_tiles := _get_corner_tiles(camera_tile, camera_position)

    for tile_pos in needed_tiles:
        if not tiles.has(tile_pos):
            var new_tile := TerrainTile.new(tile_pos)
            tiles[tile_pos] = new_tile
            _generate_heightmap(new_tile)

    _update_shader_uniforms(camera_position)

func _generate_heightmap(tile: TerrainTile):
    # Set tile position
    voronoi_generator.tile_x = tile.position.x
    voronoi_generator.tile_y = tile.position.y

    # Generate Voronoi
    voronoi_generator.generate_heightmap()

    # Apply erosion
    erosion_generator.tile_x = tile.position.x
    erosion_generator.tile_y = tile.position.y
    erosion_generator.heightmap_image = voronoi_generator.heightmap_image.duplicate()
    erosion_generator.generate_heightmap()

    # Create texture
    tile.heightmap = erosion_generator.heightmap_texture

    print("Generated tile (%d, %d)" % [tile.position.x, tile.position.y])
```

---

## 8. Known Limitations & Future Work

### Current Limitations

1. **Erosion Compute Shader**: Requires significant refactoring to support droplet lists
   - Current shader assumes pre-generated random indices
   - Need to pass structured droplet data from CPU

2. **Memory Usage**: Extended maps use more memory
   - 256x256 tile with 128px padding = 512x512 = 4x memory during generation
   - Mitigated by only keeping final tile in memory

3. **Generation Time**: Padding increases computation
   - Need to profile and optimize
   - Consider reducing padding for distant tiles (LOD)

### Future Enhancements

1. **Multi-threaded Generation**
   - Generate multiple tiles in parallel
   - Use worker threads for CPU-side calculations

2. **Incremental Erosion**
   - Support adding more droplets to existing tiles
   - Requires careful state management

3. **Compression**
   - Compress generated tiles for storage
   - Procedural generation on-demand vs caching trade-off

4. **Advanced Seamlessness**
   - Blend between different biomes/generators
   - Smooth transitions between terrain types

---

## 9. Summary

### Key Takeaways

✅ **Voronoi Tiling**: Straightforward using world-space points and spatial hashing

✅ **Erosion Tiling**: Complex but achievable with deterministic droplet ordering and padding

✅ **Seamlessness**: Guaranteed by deterministic world-space generation

✅ **Performance**: Acceptable with optimization (caching, culling, LOD)

### Implementation Roadmap

1. **Week 1**: Implement Voronoi tiling
   - Modify shader and generator
   - Test seamlessness with 3x3 grid

2. **Week 2**: Implement erosion padding infrastructure
   - Extended map generation
   - Droplet calculation algorithm

3. **Week 3**: Refactor erosion compute shader
   - Support droplet lists
   - Implement deterministic ordering

4. **Week 4**: Integration and testing
   - Update TerrainManager
   - Performance profiling
   - Visual quality verification

### Success Criteria

- [ ] Adjacent tiles have pixel-perfect seam matching
- [ ] Same tile generates identically on multiple runs
- [ ] Tiles can be generated in any order
- [ ] Visible 5x5 grid with smooth transitions
- [ ] Generation time < 100ms per tile
- [ ] No visible artifacts at tile boundaries
