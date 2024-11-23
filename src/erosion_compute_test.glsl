#[compute]
#version 450

layout(local_size_x = 16, local_size_y = 1, local_size_z = 1) in;

layout(set = 0, binding = 0, std430) restrict buffer HeightMapBuffer {
    float heightmap[];
} height_map;

layout(set = 0, binding = 1, std430) restrict buffer BrushIndicesBuffer {
    int brush_indices[];
} brush_data;

layout(set = 0, binding = 2, std430) restrict buffer BrushWeightsBuffer {
    float brush_weights[];
} brush_weights;

layout(set = 0, binding = 3, std430) restrict buffer RandomBuffer {
    int random_indices[];
} random_data;

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
    float padding1;  // Add padding to maintain 16-byte alignment
    float padding2;
    float padding3;
} params;

void main() {
    // First, let's make sure we're actually modifying values
    uint index = gl_GlobalInvocationID.x;
    if(index >= random_data.random_indices.length()) return;
    
    // Get the actual position we want to modify from random indices
    int pos = random_data.random_indices[index];
    if(pos >= 0 && pos < height_map.heightmap.length()) {
        // Modify the height at this position and its brush area
        for(int i = 0; i < params.brush_length; i++) {
            int offset_index = pos + brush_data.brush_indices[i];
            if(offset_index >= 0 && offset_index < height_map.heightmap.length()) {
                // Apply a simple modification using the brush weights
                float weight = brush_weights.brush_weights[i];
                height_map.heightmap[offset_index] = 
                    height_map.heightmap[offset_index] * (1.0 - weight * 0.1);
            }
        }
    }
}