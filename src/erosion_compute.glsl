#[compute]
#version 450

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

layout(set = 0, binding = 3, std430) restrict readonly buffer RandomBuffer {
  int random_indices[];
}
random_data;

// Fixed push constants struct with proper alignment
layout(push_constant) uniform Params {
  // First 16-byte alignment block
  float map_size;
  float brush_length;
  float brush_radius;
  float max_lifetime;

  // Second 16-byte alignment block
  float inertia;
  float sediment_capacity_factor;
  float min_sediment_capacity;
  float deposit_speed;

  // Third 16-byte alignment block
  float erode_speed;
  float evaporate_speed;
  float gravity;
  float start_speed;

  // Fourth 16-byte alignment block
  float start_water;
  float padding1; // Add padding to maintain 16-byte alignment
  float padding2;
  float padding3;
}
params;

void main() {
  uint index = gl_GlobalInvocationID.x;
  if (index >= random_data.random_indices.length()) {
    height_map.heightmap[0] = float(random_data.random_indices.length());
    return;
  }

  height_map.heightmap[6] = float(random_data.random_indices[index]);

  float pos_x = float(random_data.random_indices[index] % int(params.map_size));
  float pos_y = float(random_data.random_indices[index] / int(params.map_size));

  height_map.heightmap[7] = pos_x;
  height_map.heightmap[8] = pos_y;
  height_map.heightmap[9] = params.map_size;

  // Second check - position bounds
  if (pos_x < 0 || pos_x >= int(params.map_size) || pos_y < 0 ||
      pos_y >= int(params.map_size)) {
    // Mark this exit point
    height_map.heightmap[1] = -1.0;
    return;
  }

  int droplet_index = int(pos_y) * int(params.map_size) + int(pos_x);

  // Third check - brush length
  if (int(params.brush_length) > brush_data.brush_indices.length()) {
    // Mark this exit point
    height_map.heightmap[2] = float(brush_data.brush_indices.length());
    height_map.heightmap[22] = params.brush_length;
    return;
  }

  // Fourth check - heightmap bounds
  if (droplet_index >= height_map.heightmap.length()) {
    // Mark this exit point
    height_map.heightmap[3] = float(droplet_index);
    return;
  }

  // If we get here, we should see changes
  for (int i = 0; i < int(params.brush_length); i++) {
    if (i >= brush_weights.brush_weights.length()) {
      height_map.heightmap[4] = float(i); // Mark where we break
      break;
    }

    int brush_offset = brush_data.brush_indices[i];
    int target_index = droplet_index + brush_offset;

    if (target_index >= 0 && target_index < height_map.heightmap.length()) {
      // Increase the effect to make it more visible
      height_map.heightmap[target_index] +=
          .05 * brush_weights.brush_weights[i];
    }
  }

  // Mark successful completion
  height_map.heightmap[5] = 999.0;
}