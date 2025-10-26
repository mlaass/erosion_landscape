#[compute]
#version 450

layout(local_size_x = 16, local_size_y = 16, local_size_z = 1) in;

// Output heightmap buffer
layout(set = 0, binding = 0, std430) restrict buffer HeightMapBuffer {
  float heightmap[];
};

// No points buffer - we generate points deterministically!

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
  float padding_1;
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

void generate_world_points() {
  int points_per_tile = int(num_points);

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

float calculate_height(vec2 world_pos) {
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

  // Calculate height based on distance
  float height = apply_scaling(normalized_dist, int(scaling_type), falloff) * amplitude;

  // Add ridge variation
  if (closest_dist > 0.0) {
    float ridge = (second_closest - closest_dist) / closest_dist;
    height += ridge * ridge_multiplier;
  }

  // Clamp height to [0,1] before mixing
  height = clamp(height, 0.0, 1.0);

  // Map to desired height range
  return mix(min_height, max_height, height);
}

void main() {
  ivec2 pixel_coords = ivec2(gl_GlobalInvocationID.xy);

  if (pixel_coords.x >= int(map_size) || pixel_coords.y >= int(map_size)) {
    return;
  }

  // Generate world-space points for 3x3 neighborhood
  generate_world_points();

  // Calculate world position of this pixel
  vec2 world_pos = vec2(
    tile_world_x * map_size + float(pixel_coords.x),
    tile_world_y * map_size + float(pixel_coords.y)
  );

  // Calculate height and store in buffer
  int index = pixel_coords.y * int(map_size) + pixel_coords.x;
  heightmap[index] = calculate_height(world_pos);
}