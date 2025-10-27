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
    vec2 uv = local_pos / tile_size;

    // No clamping - allow cross-tile sampling for seamless normals
    // When calculating normals at boundaries, epsilon offsets will correctly
    // sample from adjacent tiles via sample_height_at()
    return texture(heightmap, uv).r;
}

// Sample height at any world position - simple direct lookup
float sample_height_at(vec2 _world_pos) {
    // Determine which tile this position belongs to
    vec2 sample_tile = floor(_world_pos / tile_size);

    // Find matching tile in our active slots and sample directly
    if (active_tiles > 0 && tile_position_0 == sample_tile)
        return get_height_from_tile(heightmap_0, tile_position_0, _world_pos);
    if (active_tiles > 1 && tile_position_1 == sample_tile)
        return get_height_from_tile(heightmap_1, tile_position_1, _world_pos);
    if (active_tiles > 2 && tile_position_2 == sample_tile)
        return get_height_from_tile(heightmap_2, tile_position_2, _world_pos);
    if (active_tiles > 3 && tile_position_3 == sample_tile)
        return get_height_from_tile(heightmap_3, tile_position_3, _world_pos);
    if (active_tiles > 4 && tile_position_4 == sample_tile)
        return get_height_from_tile(heightmap_4, tile_position_4, _world_pos);
    if (active_tiles > 5 && tile_position_5 == sample_tile)
        return get_height_from_tile(heightmap_5, tile_position_5, _world_pos);
    if (active_tiles > 6 && tile_position_6 == sample_tile)
        return get_height_from_tile(heightmap_6, tile_position_6, _world_pos);
    if (active_tiles > 7 && tile_position_7 == sample_tile)
        return get_height_from_tile(heightmap_7, tile_position_7, _world_pos);
    if (active_tiles > 8 && tile_position_8 == sample_tile)
        return get_height_from_tile(heightmap_8, tile_position_8, _world_pos);

    // Tile not loaded - return mid-height
    return 0.5;
}

vec3 calculate_normal(vec2 _world_pos) {
    float epsilon = 1.0;

    // Get center height for fallback
    float height_c = sample_height_at(_world_pos);

    // Sample heights in all 4 directions, potentially crossing tile boundaries
    float height_r = sample_height_at(_world_pos + vec2(epsilon, 0.0));
    float height_l = sample_height_at(_world_pos - vec2(epsilon, 0.0));
    float height_t = sample_height_at(_world_pos + vec2(0.0, epsilon));
    float height_b = sample_height_at(_world_pos - vec2(0.0, epsilon));

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

    // Determine which tile this vertex belongs to
    vec2 vertex_tile = floor(world_pos / tile_size);

    // Find matching tile in our 9 shader slots
    int tile_index = -1;
    if (active_tiles > 0 && tile_position_0 == vertex_tile) tile_index = 0;
    else if (active_tiles > 1 && tile_position_1 == vertex_tile) tile_index = 1;
    else if (active_tiles > 2 && tile_position_2 == vertex_tile) tile_index = 2;
    else if (active_tiles > 3 && tile_position_3 == vertex_tile) tile_index = 3;
    else if (active_tiles > 4 && tile_position_4 == vertex_tile) tile_index = 4;
    else if (active_tiles > 5 && tile_position_5 == vertex_tile) tile_index = 5;
    else if (active_tiles > 6 && tile_position_6 == vertex_tile) tile_index = 6;
    else if (active_tiles > 7 && tile_position_7 == vertex_tile) tile_index = 7;
    else if (active_tiles > 8 && tile_position_8 == vertex_tile) tile_index = 8;

    // Sample from the matching tile (or default if no match)
    vec2 current_tile_pos;
    if (tile_index == 0) {
        height_value = get_height_from_tile(heightmap_0, tile_position_0, world_pos);
        current_tile_pos = tile_position_0;
    } else if (tile_index == 1) {
        height_value = get_height_from_tile(heightmap_1, tile_position_1, world_pos);
        current_tile_pos = tile_position_1;
    } else if (tile_index == 2) {
        height_value = get_height_from_tile(heightmap_2, tile_position_2, world_pos);
        current_tile_pos = tile_position_2;
    } else if (tile_index == 3) {
        height_value = get_height_from_tile(heightmap_3, tile_position_3, world_pos);
        current_tile_pos = tile_position_3;
    } else if (tile_index == 4) {
        height_value = get_height_from_tile(heightmap_4, tile_position_4, world_pos);
        current_tile_pos = tile_position_4;
    } else if (tile_index == 5) {
        height_value = get_height_from_tile(heightmap_5, tile_position_5, world_pos);
        current_tile_pos = tile_position_5;
    } else if (tile_index == 6) {
        height_value = get_height_from_tile(heightmap_6, tile_position_6, world_pos);
        current_tile_pos = tile_position_6;
    } else if (tile_index == 7) {
        height_value = get_height_from_tile(heightmap_7, tile_position_7, world_pos);
        current_tile_pos = tile_position_7;
    } else if (tile_index == 8) {
        height_value = get_height_from_tile(heightmap_8, tile_position_8, world_pos);
        current_tile_pos = tile_position_8;
    } else {
        // No matching tile - use flat default
        height_value = 0.5;
        current_tile_pos = vec2(0.0);
    }

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
        final_color = terrain_normal * 0.5 + 0.5;
    } else {
        // Normal rendering
        float height = 1.0 - height_value;
        final_color = vec3(height) * color;
        METALLIC = 1.0 - height;
    }

    ALBEDO = final_color;
    ROUGHNESS = 0.8;
}
