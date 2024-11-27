shader_type spatial;


uniform sampler2D heightmap;
uniform float height_scale = 50.0;
uniform float map_size = 512.0;
uniform vec3 color: source_color = vec3(1.,1.,1.);


float hval(vec2 pos){
  return  texture(heightmap,vec2(.5,.5)+ pos/map_size).r * height_scale;
}

void vertex() {
  float height = hval(VERTEX.xz);
  VERTEX.y = height ;
  vec2 e = vec2(3.5, 0.0);
  vec3 normal = normalize(vec3(hval(VERTEX.xz - e) - hval(VERTEX.xz + e), 2.0 * e.x, hval(VERTEX.xz - e.yx) - hval(VERTEX.xz + e.yx)));
  NORMAL = normal;
}

void fragment() {
    // Simple shading based on height
    float height = texture(heightmap, UV).r;
    ALBEDO = vec3(smoothstep(0.0,1.0,AO)) * vec3(1.-height) *color;
    ALBEDO = vec3(smoothstep(0.0,1.0,AO)) * color;
    //ALBEDO = vec3(AO) ;
    //ALBEDO =  vec3(height) *color;
    METALLIC = clamp(height, 0., .5);
    ROUGHNESS = clamp(height, .75, 1.);
}