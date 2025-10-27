shader_type spatial;
render_mode blend_mix, depth_draw_opaque, cull_back, diffuse_burley, specular_schlick_ggx;

uniform sampler2D heightmap_0 : filter_nearest;
uniform sampler2D heightmap_1 : filter_nearest;
uniform sampler2D heightmap_2 : filter_nearest;
uniform sampler2D heightmap_3 : filter_nearest;
uniform sampler2D heightmap_4 : filter_nearest;
uniform sampler2D heightmap_5 : filter_nearest;
uniform sampler2D heightmap_6 : filter_nearest;
uniform sampler2D heightmap_7 : filter_nearest;
uniform sampler2D heightmap_8 : filter_nearest;

uniform vec2 tile_position_0;
uniform vec2 tile_position_1;
uniform vec2 tile_position_2;
uniform vec2 tile_position_3;
uniform vec2 tile_position_4;
uniform vec2 tile_position_5;
uniform vec2 tile_position_6;
uniform vec2 tile_position_7;
uniform vec2 tile_position_8;

uniform int active_tiles;

uniform float tile_size = 256.0;

uniform vec3 color: source_color = vec3(0.82, 0.53, 0.23);
uniform float amplitude = 30.0;
uniform float gain = 0.0;
uniform bool disable_normals = false;
uniform int debug_mode = 0;  // 0=normal, 1=show tiles, 2=show UV, 3=show normal gradient

varying float height_value;
varying vec2 world_pos;
varying vec3 terrain_normal;
varying vec2 tile_uv;
varying float tile_id;

float get_height_from_tile(sampler2D heightmap, vec2 tile_pos, vec2 _world_pos) {
    // Calculate local position within the tile
    vec2 local_pos = _world_pos - (tile_pos * tile_size);
    vec2 uv = fract(local_pos / tile_size);

    // No clamping - allow cross-tile sampling for seamless normals
    // When calculating normals at boundaries, epsilon offsets will correctly
    // sample from adjacent tiles via sample_height_at()
    return texture(heightmap, uv).r;
}

// Sample height at any world position - simple direct lookup
vec4 sample_height_at(vec2 _world_pos) {
    // Determine which tile this position belongs to
    vec2 vertex_tile = floor(_world_pos / tile_size);

    // Find matching tile in our active slots and sample directly
    if (active_tiles > 0 && tile_position_0 == vertex_tile)
        return vec4(get_height_from_tile(heightmap_0, tile_position_0, _world_pos),tile_position_0.x,tile_position_0.y, 0.0);
    if (active_tiles > 1 && tile_position_1 == vertex_tile)
        return vec4(get_height_from_tile(heightmap_1, tile_position_1, _world_pos),tile_position_1.x,tile_position_1.y, 1.0);
    if (active_tiles > 2 && tile_position_2 == vertex_tile)
        return vec4(get_height_from_tile(heightmap_2, tile_position_2, _world_pos),tile_position_2.x,tile_position_2.y, 2.0);
    if (active_tiles > 3 && tile_position_3 == vertex_tile)
        return vec4(get_height_from_tile(heightmap_3, tile_position_3, _world_pos),tile_position_3.x,tile_position_3.y, 3.0);
    if (active_tiles > 4 && tile_position_4 == vertex_tile)
        return vec4(get_height_from_tile(heightmap_4, tile_position_4, _world_pos),tile_position_4.x,tile_position_4.y, 4.0);
    if (active_tiles > 5 && tile_position_5 == vertex_tile)
        return vec4(get_height_from_tile(heightmap_5, tile_position_5, _world_pos),tile_position_5.x,tile_position_5.y, 5.0);
    if (active_tiles > 6 && tile_position_6 == vertex_tile)
        return vec4(get_height_from_tile(heightmap_6, tile_position_6, _world_pos),tile_position_6.x,tile_position_6.y, 6.0);
    if (active_tiles > 7 && tile_position_7 == vertex_tile)
        return vec4(get_height_from_tile(heightmap_7, tile_position_7, _world_pos),tile_position_7.x,tile_position_7.y, 7.0);
    if (active_tiles > 8 && tile_position_8 == vertex_tile)
        return vec4(get_height_from_tile(heightmap_8, tile_position_8, _world_pos),tile_position_8.x,tile_position_8.y, 8.0);

    // Tile not loaded - return mid-height
    return vec4(0.5, 0.0, 0.0, -1.0);
}

vec3 calculate_normal(vec2 _world_pos) {
    float epsilon = 1.0;

    // Get center height for fallback
    float height_c = sample_height_at(_world_pos).x;

    // Sample heights in all 4 directions, potentially crossing tile boundaries
    float height_r = sample_height_at(_world_pos + vec2(epsilon, 0.0)).x*amplitude;
    float height_l = sample_height_at(_world_pos - vec2(epsilon, 0.0)).x*amplitude;
    float height_t = sample_height_at(_world_pos + vec2(0.0, epsilon)).x*amplitude;
    float height_b = sample_height_at(_world_pos - vec2(0.0, epsilon)).x*amplitude;

    // If any adjacent tile returned default 0.5, use center height for smooth fallback
    if (abs(height_r - 0.5) < 0.01 && abs(height_c - 0.5) > 0.01) height_r = height_c;
    if (abs(height_l - 0.5) < 0.01 && abs(height_c - 0.5) > 0.01) height_l = height_c;
    if (abs(height_t - 0.5) < 0.01 && abs(height_c - 0.5) > 0.01) height_t = height_c;
    if (abs(height_b - 0.5) < 0.01 && abs(height_c - 0.5) > 0.01) height_b = height_c;


    float height_dx = (height_r - height_l) / (2.0 * epsilon);
    float height_dz = (height_t - height_b) / (2.0 * epsilon);

    return normalize(vec3(-height_dx, 1.0, -height_dz));
}

void vertex() {
    // Get world position
    vec4 world_vertex = MODEL_MATRIX * vec4(VERTEX, 1.0);
    world_pos = vec2(world_vertex.x, world_vertex.z);

    // Sample from the matching tile (or default if no match)
    vec4 sample = sample_height_at(world_pos);
    height_value = sample.x;
    vec2 current_tile_pos = sample.yz;
    int tile_index = int(sample.w);


    // Store debug info
    tile_id = float(tile_index);
    vec2 local_pos = world_pos - (current_tile_pos * tile_size);
    tile_uv = local_pos / tile_size;

    terrain_normal = calculate_normal(world_pos);
    // Calculate normal using cross-tile sampling with smooth fallback
    if (disable_normals) {
        terrain_normal = vec3(0.0, 1.0, 0.0);  // Flat normal for debugging
    }

    // Apply height
    VERTEX.y = gain + height_value * amplitude;
    NORMAL = terrain_normal;
}

void fragment() {
    vec3 final_color;

    if (debug_mode == 1) {
        // Debug mode 1: Show tile boundaries with distinct colors
        vec3 tile_colors[9];
        tile_colors[0] = vec3(1.0, 0.0, 0.0);  // Red
        tile_colors[1] = vec3(0.0, 1.0, 0.0);  // Green
        tile_colors[2] = vec3(0.0, 0.0, 1.0);  // Blue
        tile_colors[3] = vec3(1.0, 1.0, 0.0);  // Yellow
        tile_colors[4] = vec3(1.0, 0.0, 1.0);  // Magenta
        tile_colors[5] = vec3(0.0, 1.0, 1.0);  // Cyan
        tile_colors[6] = vec3(1.0, 0.5, 0.0);  // Orange
        tile_colors[7] = vec3(0.5, 0.0, 1.0);  // Purple
        tile_colors[8] = vec3(0.0, 1.0, 0.5);  // Teal

        int idx = int(tile_id);
        if (idx >= 0 && idx < 9) {
            final_color = tile_colors[idx];
        } else {
            final_color = vec3(0.5);  // Gray for invalid
        }
    } else if (debug_mode == 2) {
        // Debug mode 2: Show UV coordinates (reveals wrapping issues)
        final_color = vec3(fract(tile_uv.x), fract(tile_uv.y), 0.0);
    } else if (debug_mode == 3) {
        // Debug mode 3: Visualize normal gradient (shows discontinuities)
        final_color = terrain_normal;
    } else {
        // Normal rendering
        float height = 1.0 - height_value;
        final_color = vec3(height) * color;
        // METALLIC = 1.0 - height;
    }

    ALBEDO = final_color;
    ROUGHNESS = 0.8;
}
