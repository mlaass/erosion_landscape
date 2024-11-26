shader_type spatial;

uniform sampler2D heightmap_0;
uniform sampler2D heightmap_1;
uniform sampler2D heightmap_2;
uniform sampler2D heightmap_3;

uniform vec2 tile_position_0;
uniform vec2 tile_position_1;
uniform vec2 tile_position_2;
uniform vec2 tile_position_3;

uniform int active_tiles;

uniform float tile_size = 256.0;
uniform float blend_border = 32.0;

uniform vec3 color: source_color = vec3(1.,1.,1.);
uniform float amplitude = 30.0;
uniform float gain = 0.0;

varying float height_value;
varying vec2 world_pos;
varying vec3 terrain_normal;
varying float slope;

float get_height_from_tile(sampler2D heightmap, vec2 tile_pos, vec2 _world_pos) {
    vec2 local_pos = _world_pos - (tile_pos*(tile_size-blend_border*2.0));
    vec2 uv = (local_pos) / (tile_size);

    // Simply return the raw height value
    return texture(heightmap, uv).r;
}

float get_blend_weight(vec2 tile_pos, vec2 _world_pos) {
    vec2 local_pos = _world_pos - (tile_pos*(tile_size-blend_border*2.0));

    // Calculate normalized distances from edges (0 at edge, 1 in center)
    vec2 edge_dist = local_pos / blend_border;
    vec2 far_edge_dist = (tile_size - local_pos) / blend_border;

    // Use simple linear interpolation for more predictable blending
    vec2 border_dist = clamp(edge_dist, 0.0, 1.0);
    vec2 inv_border_dist = clamp(far_edge_dist, 0.0, 1.0);

    // Multiply weights linearly
    return border_dist.x * border_dist.y * inv_border_dist.x * inv_border_dist.y;
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

    return normalize(vec3(-height_dx, 1.0, -height_dz));
}

void vertex() {
    // Get world position by multiplying vertex position with MODEL_MATRIX
    vec4 world_vertex = MODEL_MATRIX * vec4(VERTEX, 1.0);
    world_pos = vec2(world_vertex.x, world_vertex.z);

    float final_height = 0.0;
    vec3 final_normal = vec3(0.0, 1.0, 0.0);
    float total_weight = 0.0;

    // Sample from active heightmaps
    if (active_tiles > 0) {
        float weight = get_blend_weight(tile_position_0, world_pos);
        float height = get_height_from_tile(heightmap_0, tile_position_0, world_pos);
        vec3 normal = get_normal_from_tile(heightmap_0, tile_position_0, world_pos);

        final_height += height * weight;
        final_normal += normal * weight;
        total_weight += weight;
    }

    if (active_tiles > 1) {
        float weight = get_blend_weight( tile_position_1,world_pos);
        float height = get_height_from_tile(heightmap_1, tile_position_1, world_pos);
        vec3 normal = get_normal_from_tile(heightmap_1, tile_position_1, world_pos);

        final_height += height * weight;
        final_normal += normal * weight;
        total_weight += weight;
    }

    if (active_tiles > 2) {
        float weight = get_blend_weight( tile_position_2,world_pos);
        float height = get_height_from_tile(heightmap_2, tile_position_2, world_pos);
        vec3 normal = get_normal_from_tile(heightmap_2, tile_position_2, world_pos);

        final_height += height * weight;
        final_normal += normal * weight;
        total_weight += weight;
    }

    if (active_tiles > 3) {
        float weight = get_blend_weight( tile_position_3,world_pos);
        float height = get_height_from_tile(heightmap_3, tile_position_3, world_pos);
        vec3 normal = get_normal_from_tile(heightmap_3, tile_position_3, world_pos);

        final_height += height * weight;
        final_normal += normal * weight;
        total_weight += weight;
    }

    // This is the key change - if total_weight is less than 1.0,
    // it means we're in an edge area without full tile coverage
    height_value = final_height / max(total_weight, 0.25);
    terrain_normal = normalize(final_normal);
    // height_value = final_height / total_weight;
    VERTEX.y = gain + height_value * amplitude;
    NORMAL = terrain_normal;
}

void fragment() {
    float height = 1.-height_value;
    //ALBEDO = vec3(height) *c100olor;
    ALBEDO = vec3(height) *color;
    METALLIC = 1.-height;
    //ALBEDO = vec3(
      //get_blend_weight(tile_position_0, world_pos) +
      //get_blend_weight(tile_position_3, world_pos),
      //get_blend_weight(tile_position_1, world_pos),
      //get_blend_weight(tile_position_2, world_pos) +
      //get_blend_weight(tile_position_3, world_pos)) ;
    // Make higher areas smoother (like snow) and lower areas rougher
    ROUGHNESS = 1.-height;
}
