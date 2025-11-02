#[compute]
#version 450

layout(local_size_x = 16, local_size_y = 16, local_size_z = 1) in;

// Output heightmap buffer
layout(set = 0, binding = 0, std430) restrict buffer HeightMapBuffer {
  float heightmap[];
};

// No points buffer - we generate points deterministically!

// === SIMPLEX NOISE FUNCTIONS ===
// (Included inline since Godot GLSL doesn't support #include)

// Hash function for simplex noise
uint hash_uint(uint x) {
    x ^= x >> 16;
    x *= 0x7feb352du;
    x ^= x >> 15;
    x *= 0x846ca68bu;
    x ^= x >> 16;
    return x;
}

uint hash_int2(ivec2 p, int seed) {
    uint h = uint(seed);
    h = hash_uint(h ^ uint(p.x));
    h = hash_uint(h ^ uint(p.y));
    return h;
}

vec2 gradient_2d(ivec2 corner, int seed) {
    uint h = hash_int2(corner, seed);
    uint index = h & 7u;
    float angle = float(index) * 0.78539816339;
    return vec2(cos(angle), sin(angle));
}

float simplex_noise_2d(vec2 world_pos, int seed) {
    const float F2 = 0.366025403784;
    const float G2 = 0.211324865405;

    float s = (world_pos.x + world_pos.y) * F2;
    vec2 skewed = world_pos + s;
    ivec2 i = ivec2(floor(skewed));

    float t = float(i.x + i.y) * G2;
    vec2 unskewed = vec2(i) - t;
    vec2 d0 = world_pos - unskewed;

    ivec2 i1 = (d0.x > d0.y) ? ivec2(1, 0) : ivec2(0, 1);

    vec2 d1 = d0 - vec2(i1) + G2;
    vec2 d2 = d0 - 1.0 + 2.0 * G2;

    float n0 = 0.0, n1 = 0.0, n2 = 0.0;

    float t0 = 0.5 - dot(d0, d0);
    if (t0 > 0.0) {
        t0 *= t0;
        vec2 g0 = gradient_2d(i, seed);
        n0 = t0 * t0 * dot(g0, d0);
    }

    float t1 = 0.5 - dot(d1, d1);
    if (t1 > 0.0) {
        t1 *= t1;
        vec2 g1 = gradient_2d(i + i1, seed);
        n1 = t1 * t1 * dot(g1, d1);
    }

    float t2 = 0.5 - dot(d2, d2);
    if (t2 > 0.0) {
        t2 *= t2;
        vec2 g2 = gradient_2d(i + ivec2(1, 1), seed);
        n2 = t2 * t2 * dot(g2, d2);
    }

    return 70.0 * (n0 + n1 + n2);
}

float octave_noise(vec2 world_pos, int seed, float frequency, int octaves, float lacunarity, float persistence) {
    float value = 0.0;
    float amplitude = 1.0;
    float max_value = 0.0;
    float freq = frequency;

    for (int i = 0; i < octaves; i++) {
        value += simplex_noise_2d(world_pos * freq, seed + i) * amplitude;
        max_value += amplitude;
        amplitude *= persistence;
        freq *= lacunarity;
    }

    return value / max_value;
}

layout(push_constant) uniform Params {
  // Block 1 (16 bytes)
  float map_size;           // Tile size (e.g. 256)
  float num_points;         // Points per tile
  float tile_world_x;       // Tile X position in world grid
  float tile_world_y;       // Tile Y position in world grid

  // Block 2 (16 bytes)
  float falloff;            // Controls how quickly height falls off with distance
  float min_height;         // Minimum height value
  float max_height;         // Maximum height value
  float ridge_multiplier;

  // Block 3 (16 bytes)
  float scaling_type;       // 0=linear, 1=quadratic, 2=exponential, etc.
  float amplitude;
  float global_seed;        // Global seed for deterministic generation
  float voronoi_intensity;  // Voronoi layer intensity

  // Block 4: Global noise parameters (16 bytes)
  float global_noise_intensity;  // Global noise layer intensity
  float global_noise_frequency;
  float global_noise_lacunarity;
  float global_noise_persistence;

  // Block 5: Global noise + morphing seeds (16 bytes)
  int global_noise_octaves;
  int global_noise_seed;
  float morphing_frequency;
  int morphing_seed;

  // Block 6: Morphing ranges - ridge & num_points (16 bytes)
  float ridge_min;
  float ridge_max;
  float num_points_min;
  float num_points_max;

  // Block 7: Morphing ranges - falloff (16 bytes)
  float falloff_min;
  float falloff_max;
  float enable_voronoi;        // 1.0 = enabled, 0.0 = disabled
  float enable_global_noise;   // 1.0 = enabled, 0.0 = disabled

  // Block 8: Enable flags for morphing (16 bytes)
  float enable_morphing;       // 1.0 = enabled, 0.0 = disabled
  float morph_ridge_enabled;   // 1.0 = enabled, 0.0 = disabled
  float morph_points_enabled;  // 1.0 = enabled, 0.0 = disabled
  float morph_falloff_enabled; // 1.0 = enabled, 0.0 = disabled
};

// Spatial hash function for deterministic random values
uint hash(int x, int y, uint seed) {
  uint h = seed;
  h ^= uint(x) * 374761393u;
  h ^= uint(y) * 668265263u;
  h ^= h >> 13;
  h *= 1274126177u;
  h ^= h >> 16;
  return h;
}

// Convert hash to float [0, 1)
float hash_to_float(uint h) {
  return float(h) / 4294967296.0;
}

// Generate deterministic random float from seed and index
float random_float(uint seed, uint index) {
  uint h = seed ^ (index * 747796405u);
  h = ((h >> 16) ^ h) * 0x45d9f3bu;
  h = ((h >> 16) ^ h) * 0x45d9f3bu;
  h = (h >> 16) ^ h;
  return float(h) / 4294967296.0;
}

float apply_scaling(float dist, int type, float falloff) {
  float height = 0.0;

  switch (type) {
  case 0: // Linear
    height = 1.0 - dist;
    break;

  case 1: // Quadratic
    height = 1.0 - (dist * dist);
    break;

  case 2: // Exponential
    height = exp(-falloff * dist);
    break;

  case 3: // Sigmoid
    height = 1.0 / (1.0 + exp(falloff * (dist - 0.5)));
    break;

  case 4: // Inverse
    height = 1.0 / (1.0 + falloff * dist);
    break;

  case 5: // Power
    height = pow(max(0.0, 1.0 - dist), falloff);
    break;

  case 6: // Cosine
    height = 0.5 * (1.0 + cos(dist * falloff * 3.14159));
    break;

  default: // Fallback to linear
    height = 1.0 - dist;
  }

  return height;
}

// Generate world-space Voronoi points for 3x3 tile neighborhood
const int MAX_TILES = 9;
const int MAX_POINTS = 90; // 9 tiles * max 10 points per tile
vec2 world_points[MAX_POINTS];
int num_world_points = 0;

void generate_world_points(int local_num_points) {
  int points_per_tile = local_num_points;

  // Generate points for 3x3 neighborhood
  for (int dy = -1; dy <= 1; dy++) {
    for (int dx = -1; dx <= 1; dx++) {
      int neighbor_tile_x = int(tile_world_x) + dx;
      int neighbor_tile_y = int(tile_world_y) + dy;

      // Deterministic seed for this tile
      uint tile_seed = hash(neighbor_tile_x, neighbor_tile_y, uint(global_seed));

      // Generate points for this tile in world coordinates
      for (int i = 0; i < points_per_tile && num_world_points < MAX_POINTS; i++) {
        float rx = random_float(tile_seed, uint(i * 2));
        float ry = random_float(tile_seed, uint(i * 2 + 1));

        // Point position in world space
        world_points[num_world_points] = vec2(
          (float(neighbor_tile_x) + rx) * map_size,
          (float(neighbor_tile_y) + ry) * map_size
        );
        num_world_points++;
      }
    }
  }
}

float calculate_height(vec2 world_pos, float local_ridge, float local_falloff) {
  float closest_dist = 99999.0;
  float second_closest = 99999.0;

  // Find closest and second closest points in world space
  for (int i = 0; i < num_world_points; i++) {
    float dist = distance(world_pos, world_points[i]);
    if (dist < closest_dist) {
      second_closest = closest_dist;
      closest_dist = dist;
    } else if (dist < second_closest) {
      second_closest = dist;
    }
  }

  // Normalize distance by map size for consistent scaling
  float normalized_dist = closest_dist / map_size;

  // Calculate height based on distance using LOCAL falloff
  float height = apply_scaling(normalized_dist, int(scaling_type), local_falloff) * amplitude;

  // Add ridge variation using LOCAL ridge multiplier
  if (closest_dist > 0.0) {
    float ridge = (second_closest - closest_dist) / closest_dist;
    height += ridge * local_ridge;
  }

  // No clamping - allow full range for better additive blending

  // Map to desired height range
  return mix(min_height, max_height, height);
}

void main() {
  ivec2 pixel_coords = ivec2(gl_GlobalInvocationID.xy);

  if (pixel_coords.x >= int(map_size) || pixel_coords.y >= int(map_size)) {
    return;
  }

  // Calculate world position of this pixel (CRITICAL: world-space, not tile-local!)
  vec2 world_pos = vec2(
    tile_world_x * map_size + float(pixel_coords.x),
    tile_world_y * map_size + float(pixel_coords.y)
  );

  // === STEP 1: Sample morphing noise to determine local parameters ===
  float morph_value = 0.5;  // Default (no morphing)
  if (enable_morphing > 0.5) {
    // Sample infinite global morphing noise field at this world position
    morph_value = octave_noise(
      world_pos,
      morphing_seed,
      morphing_frequency,
      2,  // Use 2 octaves for smooth zones
      2.0,
      0.5
    );
    // Map from [-1,1] to [0,1]
    morph_value = morph_value * 0.5 + 0.5;
  }

  // === STEP 2: Calculate local parameters based on morph_value ===
  float local_ridge = ridge_multiplier;  // Default
  float local_falloff = falloff;         // Default
  // Note: num_points morphing disabled - can't vary point count per pixel

  if (morph_ridge_enabled > 0.5) {
    local_ridge = mix(ridge_min, ridge_max, morph_value);
  }

  if (morph_falloff_enabled > 0.5) {
    local_falloff = mix(falloff_min, falloff_max, morph_value);
  }

  // === STEP 3: Calculate layer heights ===
  float voronoi_height = 0.5;  // Default mid-height
  float global_height = 0.5;   // Default mid-height

  // Voronoi layer
  if (enable_voronoi > 0.5) {
    // Generate Voronoi points (use BASE num_points for entire tile)
    generate_world_points(int(num_points));
    voronoi_height = calculate_height(world_pos, local_ridge, local_falloff);
  }

  // Global noise layer
  if (enable_global_noise > 0.5) {
    // Use simple hash-based noise (much faster than simplex)
    vec2 noise_pos = world_pos * global_noise_frequency;
    ivec2 i = ivec2(floor(noise_pos));
    vec2 f = fract(noise_pos);

    // Smooth interpolation
    f = f * f * (3.0 - 2.0 * f);

    // Sample 4 corners
    float a = hash_to_float(hash(i.x, i.y, uint(global_noise_seed)));
    float b = hash_to_float(hash(i.x + 1, i.y, uint(global_noise_seed)));
    float c = hash_to_float(hash(i.x, i.y + 1, uint(global_noise_seed)));
    float d = hash_to_float(hash(i.x + 1, i.y + 1, uint(global_noise_seed)));

    // Bilinear interpolation
    global_height = mix(mix(a, b, f.x), mix(c, d, f.x), f.y);
  }

  // === STEP 4: Blend layers using ADDITIVE blending ===
  // Start with base height (mid-point)
  float final_height = 0.5;

  // Add global noise layer contribution (deviation from 0.5)
  if (enable_global_noise > 0.5) {
    final_height += (global_height - 0.5) * global_noise_intensity;
  }

  // Add Voronoi layer contribution (deviation from 0.5)
  if (enable_voronoi > 0.5) {
    final_height += (voronoi_height - 0.5) * voronoi_intensity;
  }

  // No clamping - allow full range of heights (can go negative or > 1.0)

  // === STEP 5: Store final height ===
  int index = pixel_coords.y * int(map_size) + pixel_coords.x;
  heightmap[index] = final_height;
}