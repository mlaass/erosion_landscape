#[compute]
#version 450

// Workgroup size matches what we dispatch from GDScript
layout(local_size_x = 16, local_size_y = 1, local_size_z = 1) in;

// Buffer bindings
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

// Shader parameters
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

// Helper function to calculate height and gradient at a position
vec3 calculate_height_and_gradient(float pos_x, float pos_y) {
    int coord_x = int(pos_x);
    int coord_y = int(pos_y);
    
    float x = pos_x - coord_x;
    float y = pos_y - coord_y;
    
    int node_index = coord_y * params.map_size + coord_x;
    // Add bounds checking
    if (node_index >= height_map.heightmap.length() || 
        node_index + 1 >= height_map.heightmap.length() || 
        node_index + params.map_size >= height_map.heightmap.length() || 
        node_index + params.map_size + 1 >= height_map.heightmap.length()) {
        return vec3(0.0);
    }
    
    float height_nw = height_map.heightmap[node_index];
    float height_ne = height_map.heightmap[node_index + 1];
    float height_sw = height_map.heightmap[node_index + params.map_size];
    float height_se = height_map.heightmap[node_index + params.map_size + 1];
    
    float gradient_x = (height_ne - height_nw) * (1.0 - y) + (height_se - height_sw) * y;
    float gradient_y = (height_sw - height_nw) * (1.0 - x) + (height_se - height_ne) * x;
    float height = height_nw * (1.0 - x) * (1.0 - y) + 
                   height_ne * x * (1.0 - y) + 
                   height_sw * (1.0 - x) * y + 
                   height_se * x * y;
    
    return vec3(gradient_x, gradient_y, height);
}

void main() {
    uint index = gl_GlobalInvocationID.x;
    if(index >= random_data.random_indices.length()) return;
    
    // Just to test if shader is running at all, add a small amount to every height value
    height_map.heightmap[index] += 0.01;
    
    // Get initial droplet position
    float pos_x = float(random_data.random_indices[index] % params.map_size);
    float pos_y = float(random_data.random_indices[index] / params.map_size);
    vec2 dir = vec2(0.0);
    float speed = params.start_speed;
    float water = params.start_water;
    float sediment = 0.0;

    for(int lifetime = 0; lifetime < params.max_lifetime; lifetime++) {
        // Get droplet position
        int node_x = int(pos_x);
        int node_y = int(pos_y);
        
        // Bounds checking
        if(node_x < params.border_size || node_x >= params.map_size - params.border_size ||
           node_y < params.border_size || node_y >= params.map_size - params.border_size) {
            break;
        }
        
        float cell_offset_x = pos_x - node_x;
        float cell_offset_y = pos_y - node_y;
        int droplet_index = node_y * params.map_size + node_x;

        // Calculate height and gradient
        vec3 height_gradient = calculate_height_and_gradient(pos_x, pos_y);
        vec2 gradient = vec2(height_gradient.x, height_gradient.y);
        float height = height_gradient.z;

        // Update direction
        dir = dir * params.inertia - gradient * (1.0 - params.inertia);
        float len = max(0.01, length(dir));
        dir = dir / len;
        
        pos_x += dir.x;
        pos_y += dir.y;

        float new_height = calculate_height_and_gradient(pos_x, pos_y).z;
        float delta_height = new_height - height;

        float sediment_capacity = max(
            -delta_height * speed * water * params.sediment_capacity_factor,
            params.min_sediment_capacity
        );

        if(sediment > sediment_capacity || delta_height > 0.0) {
            float amount_to_deposit = delta_height > 0.0 ? 
                min(delta_height, sediment) : 
                (sediment - sediment_capacity) * params.deposit_speed;
            
            sediment -= amount_to_deposit;

            // Deposit sediment
            if (droplet_index < height_map.heightmap.length() - params.map_size - 1) {
                height_map.heightmap[droplet_index] += amount_to_deposit * (1.0 - cell_offset_x) * (1.0 - cell_offset_y);
                height_map.heightmap[droplet_index + 1] += amount_to_deposit * cell_offset_x * (1.0 - cell_offset_y);
                height_map.heightmap[droplet_index + params.map_size] += amount_to_deposit * (1.0 - cell_offset_x) * cell_offset_y;
                height_map.heightmap[droplet_index + params.map_size + 1] += amount_to_deposit * cell_offset_x * cell_offset_y;
            }
        }
        else {
            float amount_to_erode = min(
                (sediment_capacity - sediment) * params.erode_speed,
                -delta_height
            );

            for(int i = 0; i < params.brush_length; i++) {
                int erode_index = droplet_index + brush_data.brush_indices[i];
                if(erode_index >= 0 && erode_index < height_map.heightmap.length()) {
                    float weighted_erode_amount = amount_to_erode * brush_weights.brush_weights[i];
                    float delta_sediment = min(height_map.heightmap[erode_index], weighted_erode_amount);
                    height_map.heightmap[erode_index] -= delta_sediment;
                    sediment += delta_sediment;
                }
            }
        }

        speed = sqrt(max(0.0, speed * speed + delta_height * params.gravity));
        water *= (1.0 - params.evaporate_speed);
    }
}