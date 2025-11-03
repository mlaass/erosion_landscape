#[compute]
#version 450

#define DEBUG 0 // Set to 0 to disable debug outputs
#if DEBUG
#define DEBUG_VALUE(index, value) height_map.heightmap[index] = value
#else
#define DEBUG_VALUE(index, value)
#endif

layout(local_size_x = 16, local_size_y = 1, local_size_z = 1) in;

// Buffer bindings
layout(set = 0, binding = 0, std430) restrict buffer HeightMapBuffer {
  float heightmap[];
}
height_map;

layout(set = 0, binding = 1,
       std430) restrict readonly buffer BrushIndicesBuffer {
  int brush_indices[];
}
brush_data;

layout(set = 0, binding = 2,
       std430) restrict readonly buffer BrushWeightsBuffer {
  float brush_weights[];
}
brush_weights;

// NEW: Droplet list buffer (pre-calculated on CPU)
layout(set = 0, binding = 3,
       std430) restrict readonly buffer DropletListBuffer {
  vec2 droplet_positions[]; // Spawn positions in map-space
}
droplet_list;

// Texture-based erosion support
layout(set = 0, binding = 4) uniform sampler2D erosion_texture;
layout(set = 0, binding = 5) uniform sampler2D sediment_texture;

// Push constants with tiling support
layout(push_constant) uniform Params {
  // Block 1
  float map_size; // Extended map size (tile_size + 2*padding)
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
  float tile_size;    // NEW: actual tile size (without padding)
  float padding_size; // NEW: padding in pixels
  float num_droplets; // NEW: total droplets to simulate

  // Block 5 (NEW)
  float tile_world_x; // NEW: tile X position
  float tile_world_y; // NEW: tile Y position
  float global_seed;  // NEW: global seed
  float padding_5_3;

  // Block 6: Texture erosion parameters
  float use_texture_mode;       // 1.0 = texture mode, 0.0 = brush mode
  float erosion_texture_scale;  // Texture size in pixels
  float sediment_texture_scale; // Sediment texture size in pixels
  float rotate_with_flow;       // 1.0 = rotate textures, 0.0 = no rotation
}
params;

// Spatial hash functions (same as Voronoi)
uint hash(int x, int y, uint seed) {
  uint h = seed;
  h ^= uint(x) * 374761393u;
  h ^= uint(y) * 668265263u;
  h ^= h >> 13;
  h *= 1274126177u;
  h ^= h >> 16;
  return h;
}

float random_float(uint seed, uint index) {
  uint h = seed ^ (index * 747796405u);
  h = ((h >> 16) ^ h) * 0x45d9f3bu;
  h = ((h >> 16) ^ h) * 0x45d9f3bu;
  h = (h >> 16) ^ h;
  return float(h) / 4294967296.0;
}

// Helper function to calculate height and gradient at a position
vec3 calculate_height_and_gradient(float pos_x, float pos_y) {
  int coord_x = int(floor(pos_x));
  int coord_y = int(floor(pos_y));
  float x = fract(pos_x);
  float y = fract(pos_y);

  int node_index = coord_y * int(params.map_size) + coord_x;

  // Bounds checking
  if (node_index >= height_map.heightmap.length() ||
      node_index + 1 >= height_map.heightmap.length() ||
      node_index + int(params.map_size) >= height_map.heightmap.length() ||
      node_index + int(params.map_size) + 1 >= height_map.heightmap.length()) {
    return vec3(0.0);
  }

  float height_nw = height_map.heightmap[node_index];
  float height_ne = height_map.heightmap[node_index + 1];
  float height_sw = height_map.heightmap[node_index + int(params.map_size)];
  float height_se = height_map.heightmap[node_index + int(params.map_size) + 1];

  float gradient_x =
      (height_ne - height_nw) * (1.0 - y) + (height_se - height_sw) * y;
  float gradient_y =
      (height_sw - height_nw) * (1.0 - x) + (height_se - height_ne) * x;
  float height = height_nw * (1.0 - x) * (1.0 - y) + height_ne * x * (1.0 - y) +
                 height_sw * (1.0 - x) * y + height_se * x * y;

  return vec3(gradient_x, gradient_y, height);
}

// Apply texture-based erosion/deposition at droplet position
void apply_texture_erosion(int droplet_index, vec2 dir, float amount_to_erode,
                           inout float sediment) {
  float angle = atan(dir.y, dir.x);

  // Build 2D rotation matrix (if rotation enabled)
  mat2 rotation;
  if (params.rotate_with_flow > 0.5) {
    rotation = mat2(cos(angle), -sin(angle), sin(angle), cos(angle));
  } else {
    rotation = mat2(1.0, 0.0, 0.0, 1.0); // Identity matrix (no rotation)
  }

  // Get droplet position in map space
  int droplet_x = droplet_index % int(params.map_size);
  int droplet_y = droplet_index / int(params.map_size);
  vec2 droplet_pos = vec2(float(droplet_x), float(droplet_y));

  // Calculate texture coverage area (in pixels)
  float erosion_radius = params.erosion_texture_scale * 0.5;
  int pixel_range = int(ceil(erosion_radius));

  float total_sediment_eroded = 0.0; // Track total for this droplet

  // Sample texture and apply erosion/deposition
  for (int y = -pixel_range; y <= pixel_range; y++) {
    for (int x = -pixel_range; x <= pixel_range; x++) {
      vec2 offset = vec2(float(x), float(y));

      // Apply rotation
      vec2 rotated_offset = rotation * offset;

      // Calculate UV coordinates (normalized to [0,1])
      vec2 uv = (rotated_offset / params.erosion_texture_scale) + 0.5;

      // Skip if outside texture bounds
      if (uv.x < 0.0 || uv.x > 1.0 || uv.y < 0.0 || uv.y > 1.0) {
        continue;
      }

      // Sample erosion texture for intensity
      float erosion_intensity = texture(erosion_texture, uv).r;

      // Calculate map index for this pixel
      int map_x = droplet_x + x;
      int map_y = droplet_y + y;

      // Bounds check
      if (map_x < 0 || map_x >= int(params.map_size) || map_y < 0 ||
          map_y >= int(params.map_size)) {
        continue;
      }

      int map_index = map_y * int(params.map_size) + map_x;

      if (map_index >= 0 &&
          map_index < int(params.map_size * params.map_size)) {
        // Apply erosion weighted by texture intensity
        float weighted_erode_amount = amount_to_erode * erosion_intensity;
        height_map.heightmap[map_index] -= weighted_erode_amount;
        total_sediment_eroded += weighted_erode_amount;
      }
    }
  }

  // Update sediment once per droplet (not per pixel!)
  sediment += total_sediment_eroded;
}

// Apply texture-based deposition at droplet position
void apply_texture_deposition(int droplet_index, vec2 dir,
                              float amount_to_deposit, inout float sediment) {
  float angle = atan(dir.y, dir.x);

  // Build 2D rotation matrix (if rotation enabled)
  mat2 rotation;
  if (params.rotate_with_flow > 0.5) {
    rotation = mat2(cos(angle), -sin(angle), sin(angle), cos(angle));
  } else {
    rotation = mat2(1.0, 0.0, 0.0, 1.0); // Identity matrix
  }

  // Get droplet position
  int droplet_x = droplet_index % int(params.map_size);
  int droplet_y = droplet_index / int(params.map_size);

  // Calculate texture coverage area
  float sediment_radius = params.sediment_texture_scale * 0.5;
  int pixel_range = int(ceil(sediment_radius));

  float total_sediment_deposited = 0.0; // Track total for this droplet

  // Sample texture and apply deposition
  for (int y = -pixel_range; y <= pixel_range; y++) {
    for (int x = -pixel_range; x <= pixel_range; x++) {
      vec2 offset = vec2(float(x), float(y));
      vec2 rotated_offset = rotation * offset;
      vec2 uv = (rotated_offset / params.sediment_texture_scale) + 0.5;

      if (uv.x < 0.0 || uv.x > 1.0 || uv.y < 0.0 || uv.y > 1.0) {
        continue;
      }

      float deposition_intensity = texture(sediment_texture, uv).r * .01;

      int map_x = droplet_x + x;
      int map_y = droplet_y + y;

      if (map_x < 0 || map_x >= int(params.map_size) || map_y < 0 ||
          map_y >= int(params.map_size)) {
        continue;
      }

      int map_index = map_y * int(params.map_size) + map_x;

      if (map_index >= 0 &&
          map_index < int(params.map_size * params.map_size)) {
        float weighted_deposit_amount =
            amount_to_deposit * deposition_intensity;
        height_map.heightmap[map_index] += weighted_deposit_amount;
        total_sediment_deposited += weighted_deposit_amount;
      }
    }
  }

  // Update sediment once per droplet (not per pixel!)
  sediment -= total_sediment_deposited;
}

void main() {
  uint droplet_id = gl_GlobalInvocationID.x;

  // Check if this thread has a droplet to simulate
  if (droplet_id >= uint(params.num_droplets)) {
    return;
  }

  // Get droplet spawn position from pre-calculated list
  vec2 spawn_pos = droplet_list.droplet_positions[droplet_id];
  float pos_x = spawn_pos.x;
  float pos_y = spawn_pos.y;

  // Bounds check for starting position
  if (pos_x < 0.0 || pos_x >= params.map_size || pos_y < 0.0 ||
      pos_y >= params.map_size) {
    return;
  }

  // Initialize droplet properties
  vec2 dir = vec2(0.0);
  float speed = params.start_speed;
  float water = params.start_water;
  float sediment = 0.0;

  // Simulate droplet
  for (int lifetime = 0; lifetime < int(params.max_lifetime); lifetime++) {
    int node_x = int(pos_x);
    int node_y = int(pos_y);
    float cell_offset_x = pos_x - float(node_x);
    float cell_offset_y = pos_y - float(node_y);
    int droplet_index = node_y * int(params.map_size) + node_x;

    // Calculate height and gradient
    vec3 height_gradient = calculate_height_and_gradient(pos_x, pos_y);
    vec2 gradient = vec2(height_gradient.x, height_gradient.y);
    float height = height_gradient.z;

    // Update direction and position
    dir = dir * params.inertia - gradient * (1.0 - params.inertia);
    float len = max(0.01, length(dir));
    dir = dir / len;

    pos_x += dir.x;
    pos_y += dir.y;

    // Stop if outside extended map (including padding region)
    if (pos_x < params.brush_radius ||
        pos_x >= params.map_size - params.brush_radius ||
        pos_y < params.brush_radius ||
        pos_y >= params.map_size - params.brush_radius) {
      break;
    }

    // Calculate new height and deltaHeight
    float new_height = calculate_height_and_gradient(pos_x, pos_y).z;
    float delta_height = new_height - height;

    // Calculate sediment capacity
    float sediment_capacity =
        max(-delta_height * speed * water * params.sediment_capacity_factor,
            params.min_sediment_capacity);

    // If carrying too much sediment or moving uphill
    if (sediment > sediment_capacity || delta_height > 0.0) {
      // Calculate deposit amount
      float amount_to_deposit =
          delta_height > 0.0
              ? min(delta_height, sediment)
              : (sediment - sediment_capacity) * params.deposit_speed;

      // Apply deposition: texture mode or classic bilinear mode
      if (params.use_texture_mode > 0.5) {
        // TEXTURE MODE: Apply textured deposition
        apply_texture_deposition(droplet_index, dir, amount_to_deposit,
                                 sediment);
      } else {
        // CLASSIC MODE: Bilinear distribution deposition
        sediment -= amount_to_deposit;

        if (droplet_index >= 0 &&
            droplet_index < int(params.map_size * params.map_size)) {
          height_map.heightmap[droplet_index] +=
              amount_to_deposit * (1.0 - cell_offset_x) * (1.0 - cell_offset_y);
          height_map.heightmap[droplet_index + 1] +=
              amount_to_deposit * cell_offset_x * (1.0 - cell_offset_y);
          height_map.heightmap[droplet_index + int(params.map_size)] +=
              amount_to_deposit * (1.0 - cell_offset_x) * cell_offset_y;
          height_map.heightmap[droplet_index + int(params.map_size) + 1] +=
              amount_to_deposit * cell_offset_x * cell_offset_y;
        }
      }
    } else {
      // Erode surface
      float amount_to_erode = min(
          (sediment_capacity - sediment) * params.erode_speed, -delta_height);

      // Apply erosion: texture mode or classic brush mode
      if (params.use_texture_mode > 0.5) {
        // TEXTURE MODE: Apply textured erosion
        apply_texture_erosion(droplet_index, dir, amount_to_erode, sediment);
      } else {
        // CLASSIC MODE: Brush-based erosion
        for (int i = 0; i < int(params.brush_length); i++) {
          int erode_index = droplet_index + brush_data.brush_indices[i];

          if (erode_index >= 0 &&
              erode_index < int(params.map_size * params.map_size)) {
            float weighted_erode_amount =
                amount_to_erode * brush_weights.brush_weights[i];
            // No clamping - allow erosion to create negative heights
            // (underwater/valleys)
            height_map.heightmap[erode_index] -= weighted_erode_amount;
            sediment += weighted_erode_amount;
          }
        }
      }
    }

    // Update droplet speed
    speed = sqrt(max(0.0, speed * speed + delta_height * params.gravity));
    water *= (1.0 - params.evaporate_speed);
  }
}
