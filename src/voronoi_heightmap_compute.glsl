#[compute]
#version 450

layout(local_size_x = 16, local_size_y = 16, local_size_z = 1) in;

// Output heightmap buffer
layout(set = 0, binding = 0, std430) restrict buffer HeightMapBuffer {
  float heightmap[];
};

// Voronoi points buffer
layout(set = 0, binding = 1, std430) readonly buffer PointsBuffer {
  vec2 points[];
};

layout(push_constant) uniform Params {
  float map_size;
  float num_points;
  float falloff;    // Controls how quickly height falls off with distance
  float min_height; // Minimum height value
  float max_height; // Maximum height value
  float ridge_multiplier;
  float scaling_type; // 0=linear, 1=quadratic, 2=exponential, 3=sigmoid,
                      // 4=inverse
  float amplitude;
};

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

  default: // Fallback to linear
    height = 1.0 - dist;
  }

  return height;
}

float calculate_height(vec2 pos) {
  float closest_dist = 99999.0;
  float second_closest = 99999.0;

  // Find closest and second closest points
  for (int i = 0; i < points.length(); i++) {
    float dist = distance(pos, points[i]);
    if (dist < closest_dist) {
      second_closest = closest_dist;
      closest_dist = dist;
    } else if (dist < second_closest) {
      second_closest = dist;
    }
  }

  // Scale the distance to get a better range
  // Using map_size to normalize the distance
  float normalized_dist = closest_dist;

  // Calculate height based on distance

  float height = 1.0 - normalized_dist; // Linear falloff first
  height =
      apply_scaling(normalized_dist, int(scaling_type), falloff) * amplitude;
  // height = pow(max(0.0, height), falloff); // Then apply falloff power

  // Add ridge variation
  float ridge =
      (second_closest - closest_dist) / closest_dist; // Relative difference

  height += ridge * ridge_multiplier; // Adjust multiplier to control ridge
                                      // intensity

  // Clamp height to [0,1] before mixing
  height = clamp(height, 0.0, 1.0);

  // Map to desired height range
  return mix(min_height, max_height, height);
}

void main() {
  vec2 pixel_coords = gl_GlobalInvocationID.xy;
  if (pixel_coords.x > map_size || pixel_coords.y > map_size) {
    return;
  }

  // Convert to normalized coordinates
  vec2 pos = pixel_coords / map_size;

  // Calculate height and store in buffer
  int index = int(pixel_coords.y) * int(map_size) + int(pixel_coords.x);
  // heightmap[index] = pos.x;
  heightmap[index] = calculate_height(pos);
  // if (index == 50) {
  //   heightmap[index] = 0.555;
  // }
  // heightmap[index] = 0.0; // float(pixel_coords.x) / map_size;
  return;
}