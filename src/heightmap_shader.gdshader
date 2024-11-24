shader_type spatial;

uniform sampler2D heightmap;
uniform float height_scale = 50.0;
uniform vec3 color: source_color = vec3(1.,1.,1.);

void vertex() {
    float height = texture(heightmap, UV).r;
    VERTEX.y = height * height_scale;
}

void fragment() {
    // Simple shading based on height
    float height = 1.-texture(heightmap, UV).r;
    ALBEDO = vec3(height) *color;
}