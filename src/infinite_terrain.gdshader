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
uniform bool disable_normals = false;

varying float height_value;
varying vec2 world_pos;
varying vec3 terrain_normal;

float get_height_from_tile(sampler2D heightmap, vec2 tile_pos, vec2 _world_pos) {
    // Calculate local position within the tile
    vec2 local_pos = _world_pos - (tile_pos * tile_size);
    vec2 uv = local_pos / tile_size;

    // Clamp to edge when sampling outside tile bounds
    //uv = clamp(uv, 0.0, 1.0);

    return texture(heightmap, uv).r;
}

// Sample height at any world position with bilinear interpolation at tile edges
float sample_height_at(vec2 _world_pos) {
    vec2 sample_tile = floor(_world_pos / tile_size);
    vec2 local_pos = _world_pos - (sample_tile * tile_size);

    // Calculate how far we are from tile edges (0 to tile_size)
    vec2 edge_dist_min = local_pos;  // Distance from left/bottom edges
    vec2 edge_dist_max = vec2(tile_size) - local_pos;  // Distance from right/top edges

    // Check if we're near any edge (within 1 pixel)
    bool near_left = edge_dist_min.x < 1.0;
    bool near_right = edge_dist_max.x < 1.0;
    bool near_bottom = edge_dist_min.y < 1.0;
    bool near_top = edge_dist_max.y < 1.0;

    // If not near any edge, just sample from the current tile
    if (!near_left && !near_right && !near_bottom && !near_top) {
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
        return 0.5;
    }

    // We're near an edge - need to interpolate with adjacent tiles
    // Collect up to 4 tile samples (current + up to 3 neighbors)
    vec2 tiles_to_sample[4];
    float weights[4];
    int num_samples = 0;

    // Current tile
    tiles_to_sample[num_samples] = sample_tile;
    weights[num_samples] = 1.0;
    num_samples++;

    // Neighbor tiles based on which edges we're near
    if (near_left) {
        tiles_to_sample[num_samples] = sample_tile + vec2(-1.0, 0.0);
        weights[num_samples] = 1.0 - edge_dist_min.x;
        num_samples++;
    }
    if (near_right) {
        tiles_to_sample[num_samples] = sample_tile + vec2(1.0, 0.0);
        weights[num_samples] = 1.0 - edge_dist_max.x;
        num_samples++;
    }
    if (near_bottom) {
        tiles_to_sample[num_samples] = sample_tile + vec2(0.0, -1.0);
        weights[num_samples] = 1.0 - edge_dist_min.y;
        num_samples++;
    }
    if (near_top) {
        tiles_to_sample[num_samples] = sample_tile + vec2(0.0, 1.0);
        weights[num_samples] = 1.0 - edge_dist_max.y;
        num_samples++;
    }

    // Normalize weights
    float total_weight = 0.0;
    for (int i = 0; i < num_samples; i++) {
        total_weight += weights[i];
    }
    for (int i = 0; i < num_samples; i++) {
        weights[i] /= total_weight;
    }

    // Sample and blend
    float result = 0.0;
    for (int i = 0; i < num_samples; i++) {
        vec2 tile_coord = tiles_to_sample[i];
        float height = 0.5;  // default

        // Find this tile in our active tiles
        if (active_tiles > 0 && tile_position_0 == tile_coord)
            height = get_height_from_tile(heightmap_0, tile_position_0, _world_pos);
        else if (active_tiles > 1 && tile_position_1 == tile_coord)
            height = get_height_from_tile(heightmap_1, tile_position_1, _world_pos);
        else if (active_tiles > 2 && tile_position_2 == tile_coord)
            height = get_height_from_tile(heightmap_2, tile_position_2, _world_pos);
        else if (active_tiles > 3 && tile_position_3 == tile_coord)
            height = get_height_from_tile(heightmap_3, tile_position_3, _world_pos);
        else if (active_tiles > 4 && tile_position_4 == tile_coord)
            height = get_height_from_tile(heightmap_4, tile_position_4, _world_pos);
        else if (active_tiles > 5 && tile_position_5 == tile_coord)
            height = get_height_from_tile(heightmap_5, tile_position_5, _world_pos);
        else if (active_tiles > 6 && tile_position_6 == tile_coord)
            height = get_height_from_tile(heightmap_6, tile_position_6, _world_pos);
        else if (active_tiles > 7 && tile_position_7 == tile_coord)
            height = get_height_from_tile(heightmap_7, tile_position_7, _world_pos);
        else if (active_tiles > 8 && tile_position_8 == tile_coord)
            height = get_height_from_tile(heightmap_8, tile_position_8, _world_pos);

        result += height * weights[i];
    }

    return result;
}

vec3 calculate_normal(vec2 _world_pos) {
    float epsilon = 1.0;

    // Sample heights in all 4 directions, potentially crossing tile boundaries
    // Since tiles are seamless, edge pixels match adjacent tiles
    float height_r = sample_height_at(_world_pos + vec2(epsilon, 0.0));
    float height_l = sample_height_at(_world_pos - vec2(epsilon, 0.0));
    float height_t = sample_height_at(_world_pos + vec2(0.0, epsilon));
    float height_b = sample_height_at(_world_pos - vec2(0.0, epsilon));

    float height_dx = (height_r - height_l) / (2.0 * epsilon);
    float height_dz = (height_t - height_b) / (2.0 * epsilon);

    return normalize(vec3(-height_dx , 1.0, -height_dz ));
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
    } else if (tile_index == 1) {
        height_value = get_height_from_tile(heightmap_1, tile_position_1, world_pos);
    } else if (tile_index == 2) {
        height_value = get_height_from_tile(heightmap_2, tile_position_2, world_pos);
    } else if (tile_index == 3) {
        height_value = get_height_from_tile(heightmap_3, tile_position_3, world_pos);
    } else if (tile_index == 4) {
        height_value = get_height_from_tile(heightmap_4, tile_position_4, world_pos);
    } else if (tile_index == 5) {
        height_value = get_height_from_tile(heightmap_5, tile_position_5, world_pos);
    } else if (tile_index == 6) {
        height_value = get_height_from_tile(heightmap_6, tile_position_6, world_pos);
    } else if (tile_index == 7) {
        height_value = get_height_from_tile(heightmap_7, tile_position_7, world_pos);
    } else if (tile_index == 8) {
        height_value = get_height_from_tile(heightmap_8, tile_position_8, world_pos);
    } else {
        // No matching tile - use flat default
        height_value = 0.5;
    }

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
    float height = 1.0 - height_value;
    ALBEDO = vec3(height) * color;

    // Material properties based on height
    METALLIC = 1.0 - height;
    ROUGHNESS = 0.8;
}
