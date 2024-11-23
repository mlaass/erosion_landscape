shader_type spatial;

uniform sampler2D heightmap;
uniform float height_scale = 50.0;

void vertex() {
    float height = texture(heightmap, UV).r;
    VERTEX.y = height * height_scale;
}

void fragment() {
    // Simple shading based on height
    float height = texture(heightmap, UV).r;
    ALBEDO = vec3(height);
}