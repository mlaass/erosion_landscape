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


varying float height_value;
varying vec2 world_pos;

float get_height_from_tile(sampler2D heightmap, vec2 tile_pos, vec2 _world_pos) {
    vec2 local_pos = _world_pos - tile_pos;
    vec2 uv = (local_pos) / (tile_size);
    return texture(heightmap, uv).r;
}

float get_blend_weight( vec2 tile_pos, vec2 _world_pos) {
    vec2 local_pos = _world_pos - (tile_pos) ;

    // Calculate distance from borders
    vec2 border_dist = clamp(local_pos / blend_border, 0.0, 1.0);
    vec2 inv_border_dist = clamp((tile_size - local_pos) / blend_border, 0.0, 1.0);

    // Combine weights for all edges
    float weight = min(border_dist.x, border_dist.y);
    weight = min(weight, min(inv_border_dist.x, inv_border_dist.y));

    return smoothstep(0.0, 1.0, weight);
}

void vertex() {
    // Get world position by multiplying vertex position with MODEL_MATRIX
    vec4 world_vertex = MODEL_MATRIX * vec4(VERTEX, 1.0);
    world_pos = vec2(world_vertex.x, world_vertex.z);

    float final_height = 0.0;
    float total_weight = 0.0;

    // Sample from active heightmaps
    if (active_tiles > 0) {
        float weight = get_blend_weight(tile_position_0,world_pos);
        float height = get_height_from_tile(heightmap_0, tile_position_0, world_pos);
        final_height += height * weight;
        total_weight +=clamp(1.0*weight, 0.0,1.0);
    }

    if (active_tiles > 1) {
        float weight = get_blend_weight( tile_position_1,world_pos);
        float height = get_height_from_tile(heightmap_1, tile_position_1, world_pos);
        final_height += height * weight;
        total_weight +=clamp(1.0*weight, 0.0,1.0);
    }

    if (active_tiles > 2) {
        float weight = get_blend_weight( tile_position_2,world_pos);
        float height = get_height_from_tile(heightmap_2, tile_position_2, world_pos);
        final_height += height * weight;
        total_weight += clamp(1.0*weight, 0.0,1.0);
    }

    if (active_tiles > 3) {
        float weight = get_blend_weight( tile_position_3,world_pos);
        float height = get_height_from_tile(heightmap_3, tile_position_3, world_pos);
        final_height += height * weight;
        total_weight +=clamp(1.0*weight, 0.0,1.0);
    }

    // Apply final height
    //if (total_weight > 0.0) {
         height_value = final_height / total_weight;
        height_value*=100.;
        VERTEX.y = height_value;
    //}
}

void fragment() {
    // Color based on height
    // Lower areas are darker green, higher areas are lighter/snowier
    vec3 low_color = vec3(0.0, 0.1, 0.0);    // Dark green
    vec3 mid_color = vec3(0.3, 0.5, 0.2);    // Medium green
    vec3 high_color = vec3(0.8, 0.8, 0.8);   // Snow white

    vec3 final_color;
    if (height_value < 0.4) {
        final_color = mix(low_color, mid_color, height_value * 2.5);
    } else {
        final_color = mix(mid_color, high_color, (height_value - 0.4) * 1.67);
    }

    ALBEDO = vec3(height_value) *.001;
    //ALBEDO = vec3(
      //get_blend_weight(tile_position_0, world_pos) +
      //get_blend_weight(tile_position_3, world_pos),
      //get_blend_weight(tile_position_1, world_pos),
      //get_blend_weight(tile_position_2, world_pos) +
      //get_blend_weight(tile_position_3, world_pos)) ;
    // Make higher areas smoother (like snow) and lower areas rougher
    //ROUGHNESS = 1.0;
}
