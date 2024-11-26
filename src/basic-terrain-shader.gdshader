shader_type spatial;

uniform sampler2D heightmap_0;
uniform vec2 tile_position_0 = vec2(0.0, 0.0);
uniform float tile_size = 256.0;

// Add this varying declaration at the top level
varying float height_value;

void vertex() {
    // Get world position
    vec2 world_pos = vec2(VERTEX.x, VERTEX.z);

    // Calculate UV coordinates
    vec2 uv = (world_pos - tile_position_0) / tile_size;

    // Sample height from texture
    float height = texture(heightmap_0, uv).r;

    // Pass height to fragment shader
    height_value = height;

    // Apply height
    VERTEX.y = height * 30.0;
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

    ALBEDO = final_color;
    // Make higher areas smoother (like snow) and lower areas rougher
    ROUGHNESS = mix(0.9, 0.1, height_value);
}
