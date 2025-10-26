shader_type spatial;
render_mode blend_mix, depth_draw_opaque, cull_back, diffuse_burley, specular_schlick_ggx;

uniform sampler2D heightmap_0;
uniform sampler2D heightmap_1;
uniform sampler2D heightmap_2;
uniform sampler2D heightmap_3;
uniform sampler2D heightmap_4;
uniform sampler2D heightmap_5;
uniform sampler2D heightmap_6;
uniform sampler2D heightmap_7;
uniform sampler2D heightmap_8;

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

varying float height_value;
varying vec2 world_pos;
varying vec3 terrain_normal;

float get_height_from_tile(sampler2D heightmap, vec2 tile_pos, vec2 _world_pos) {
    // Calculate local position within the tile
    vec2 local_pos = _world_pos - (tile_pos * tile_size);
    vec2 uv = local_pos / tile_size;

    return texture(heightmap, uv).r;
}

vec3 get_normal_from_tile(sampler2D heightmap, vec2 tile_pos, vec2 _world_pos) {
    float epsilon = 1.0;
    vec2 dx = vec2(epsilon, 0.0);
    vec2 dz = vec2(0.0, epsilon);

    float height_r = get_height_from_tile(heightmap, tile_pos, _world_pos + dx);
    float height_l = get_height_from_tile(heightmap, tile_pos, _world_pos - dx);
    float height_t = get_height_from_tile(heightmap, tile_pos, _world_pos + dz);
    float height_b = get_height_from_tile(heightmap, tile_pos, _world_pos - dz);

    float height_dx = (height_r - height_l) / (2.0 * epsilon);
    float height_dz = (height_t - height_b) / (2.0 * epsilon);

    return normalize(vec3(-height_dx * amplitude, 1.0, -height_dz * amplitude));
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
    if (tile_index == 0) {
        height_value = get_height_from_tile(heightmap_0, tile_position_0, world_pos);
        terrain_normal = get_normal_from_tile(heightmap_0, tile_position_0, world_pos);
    } else if (tile_index == 1) {
        height_value = get_height_from_tile(heightmap_1, tile_position_1, world_pos);
        terrain_normal = get_normal_from_tile(heightmap_1, tile_position_1, world_pos);
    } else if (tile_index == 2) {
        height_value = get_height_from_tile(heightmap_2, tile_position_2, world_pos);
        terrain_normal = get_normal_from_tile(heightmap_2, tile_position_2, world_pos);
    } else if (tile_index == 3) {
        height_value = get_height_from_tile(heightmap_3, tile_position_3, world_pos);
        terrain_normal = get_normal_from_tile(heightmap_3, tile_position_3, world_pos);
    } else if (tile_index == 4) {
        height_value = get_height_from_tile(heightmap_4, tile_position_4, world_pos);
        terrain_normal = get_normal_from_tile(heightmap_4, tile_position_4, world_pos);
    } else if (tile_index == 5) {
        height_value = get_height_from_tile(heightmap_5, tile_position_5, world_pos);
        terrain_normal = get_normal_from_tile(heightmap_5, tile_position_5, world_pos);
    } else if (tile_index == 6) {
        height_value = get_height_from_tile(heightmap_6, tile_position_6, world_pos);
        terrain_normal = get_normal_from_tile(heightmap_6, tile_position_6, world_pos);
    } else if (tile_index == 7) {
        height_value = get_height_from_tile(heightmap_7, tile_position_7, world_pos);
        terrain_normal = get_normal_from_tile(heightmap_7, tile_position_7, world_pos);
    } else if (tile_index == 8) {
        height_value = get_height_from_tile(heightmap_8, tile_position_8, world_pos);
        terrain_normal = get_normal_from_tile(heightmap_8, tile_position_8, world_pos);
    } else {
        // No matching tile - use flat default
        height_value = 0.5;
        terrain_normal = vec3(0.0, 1.0, 0.0);
    }

    // Apply height
    VERTEX.y = gain + height_value * amplitude;
    NORMAL = terrain_normal;
}

void fragment() {
    float height = 1.0 - height_value;
    ALBEDO = vec3(height) * color;

    // Material properties based on height
    METALLIC = 1.0 - height;
    ROUGHNESS = 0.8;
}
