#[compute]
#version 450

// We'll use a 16x16 workgroup size which is common for 2D operations

layout(local_size_x = 16, local_size_y = 1, local_size_z = 1) in;

// Buffer bindings
layout(set = 0, binding = 0, std430) restrict buffer HeightMapBuffer {
  float heightmap[];
}
height_map;

layout(set = 0, binding = 1, std430) restrict buffer BrushIndicesBuffer {
  int brush_indices[];
}
brush_data;

layout(set = 0, binding = 2, std430) restrict buffer BrushWeightsBuffer {
  float brush_weights[];
}
brush_weights;

layout(set = 0, binding = 3, std430) restrict buffer RandomBuffer {
  int random_indices[];
}
random_data;

// Fixed push constants struct with proper alignment
layout(push_constant) uniform Params {
  // First 16-byte alignment block
  int map_size;
  int brush_length;
  int border_size;
  int max_lifetime;

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

// Helper function to calculate height and gradient at a position
vec3 calculate_height_and_gradient(float pos_x, float pos_y) {
  int coord_x = int(pos_x);
  int coord_y = int(pos_y);

  float x = pos_x - coord_x;
  float y = pos_y - coord_y;

  int node_index = coord_y * params.map_size + coord_x;
  float height_nw = height_map.heightmap[node_index];
  float height_ne = height_map.heightmap[node_index + 1];
  float height_sw = height_map.heightmap[node_index + params.map_size];
  float height_se = height_map.heightmap[node_index + params.map_size + 1];

  float gradient_x =
      (height_ne - height_nw) * (1.0 - y) + (height_se - height_sw) * y;
  float gradient_y =
      (height_sw - height_nw) * (1.0 - x) + (height_se - height_ne) * x;
  float height = height_nw * (1.0 - x) * (1.0 - y) + height_ne * x * (1.0 - y) +
                 height_sw * (1.0 - x) * y + height_se * x * y;

  return vec3(gradient_x, gradient_y, height);
}

void main() {
  uint index = gl_GlobalInvocationID.x;
  if (index >= random_data.random_indices.length())
    return;

  // Initialize droplet
  float pos_x = float(random_data.random_indices[index] % params.map_size);
  float pos_y = float(random_data.random_indices[index] / params.map_size);

  // Safety check for initial position
  if (pos_x < 0 || pos_x >= params.map_size || pos_y < 0 ||
      pos_y >= params.map_size) {
    return;
  }

  int droplet_index = int(pos_y) * params.map_size + int(pos_x);
  for (int i = 0; i < params.brush_length; i++) {
    int brush_offset = brush_data.brush_indices[i];
    int target_index = droplet_index + brush_offset;

    if (target_index >= 0 && target_index < params.map_size * params.map_size) {
      height_map.heightmap[target_index] +=
          0.5 * brush_weights.brush_weights[i];
    }
  }
  return;

  // OLD code
  //  Debug first droplet
  //  Debug first droplet
  //  if (index == 0) {
  //      int droplet_index = int(pos_y) * params.map_size + int(pos_x);

  //     // Bounds check
  //     if(droplet_index >= 0 && droplet_index < params.map_size *
  //     params.map_size) {
  //         // Mark initial position
  //         height_map.heightmap[droplet_index] += 0.1;

  //         // Test brush application
  //         for(int i = 0; i < params.brush_length; i++) {
  //             int brush_offset = brush_data.brush_indices[i];
  //             int target_index = droplet_index + brush_offset;

  //             if(target_index >= 0 && target_index < params.map_size *
  //             params.map_size) {
  //                 height_map.heightmap[target_index] += 0.05 *
  //                 brush_weights.brush_weights[i];
  //             }
  //         }
  //     }
  // }

  //   vec2 dir = vec2(0.0);
  //   float speed = params.start_speed;
  //   float water = params.start_water;
  //   float sediment = 0.0;

  //     // Simulate droplet
  //     for(int lifetime = 0; lifetime < params.max_lifetime; lifetime++) {
  //         int node_x = int(pos_x);
  //         int node_y = int(pos_y);
  //         float cell_offset_x = pos_x - node_x;
  //         float cell_offset_y = pos_y - node_y;
  //         int droplet_index = node_y * params.map_size + node_x;

  //         // Calculate height and gradient
  //         vec3 height_gradient = calculate_height_and_gradient(pos_x,
  //         pos_y); vec2 gradient = vec2(height_gradient.x,
  //         height_gradient.y); float height = height_gradient.z;

  //         // Update direction and position
  //         dir = dir * params.inertia - gradient * (1.0 - params.inertia);
  //         float len = max(0.01, length(dir));
  //         dir = dir / len;

  //         pos_x += dir.x;
  //         pos_y += dir.y;

  //         // Stop if outside map
  //         if(pos_x < params.border_size || pos_x >= params.map_size -
  //         params.border_size ||
  //            pos_y < params.border_size || pos_y >= params.map_size -
  //            params.border_size) {
  //             break;
  //         }

  //         // Calculate new height and deltaHeight
  //         float new_height = calculate_height_and_gradient(pos_x, pos_y).z;
  //         float delta_height = new_height - height;

  //         // Calculate sediment capacity
  //         float sediment_capacity = max(
  //             -delta_height * speed * water *
  //             params.sediment_capacity_factor, params.min_sediment_capacity
  //         );

  //         // If carrying too much sediment or moving uphill
  //         if(sediment > sediment_capacity || delta_height > 0.0) {
  //             // Calculate deposit amount
  //             float amount_to_deposit = delta_height > 0.0 ?
  //                 min(delta_height, sediment) :
  //                 (sediment - sediment_capacity) * params.deposit_speed;

  //             sediment -= amount_to_deposit;

  //             // Add sediment to nodes
  //             if(droplet_index >= 0 && droplet_index < params.map_size *
  //             params.map_size) {
  //                 height_map.heightmap[droplet_index] += amount_to_deposit
  //                 * (1.0 - cell_offset_x) * (1.0 - cell_offset_y);
  //                 height_map.heightmap[droplet_index + 1] +=
  //                 amount_to_deposit * cell_offset_x * (1.0 -
  //                 cell_offset_y); height_map.heightmap[droplet_index +
  //                 params.map_size] += amount_to_deposit * (1.0 -
  //                 cell_offset_x) * cell_offset_y;
  //                 height_map.heightmap[droplet_index + params.map_size + 1]
  //                 += amount_to_deposit * cell_offset_x * cell_offset_y;
  //             }
  //         }
  //         else
  // {
  //             // Erode surface
  //             float amount_to_erode = min(
  //                 (sediment_capacity - sediment) * params.erode_speed,
  //                 -delta_height
  //             );

  //             for(int i = 0; i < params.brush_length; i++) {
  //                 int erode_index = droplet_index +
  //                 brush_data.brush_indices[i]; if(erode_index >= 0 &&
  //                 erode_index < params.map_size * params.map_size) {
  //                     float weighted_erode_amount = amount_to_erode *
  //                     brush_weights.brush_weights[i]; float delta_sediment
  //                     =
  //                     weighted_erode_amount;//min(height_map.heightmap[erode_index],
  //                     weighted_erode_amount);
  //                     height_map.heightmap[erode_index] -= delta_sediment;
  //                     sediment += delta_sediment;
  //                 }
  //             }
  //         }

  //         // Update droplet
  //         speed = sqrt(max(0.0, speed * speed + delta_height *
  //         params.gravity)); water *= (1.0 - params.evaporate_speed);
  //     }
}