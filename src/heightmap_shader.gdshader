shader_type spatial;


uniform sampler2D heightmap;
uniform float height_scale = 50.0;
uniform float map_size = 512.0;
uniform vec3 color: source_color = vec3(1.,1.,1.);
uniform vec3 slope_color: source_color = vec3(0.6, 0.4, 0.2); // Brown color for steep slopes
uniform float slope_threshold = 0.7; // Adjust this to control when slopes start being colored differently
uniform float slope_threshold_offset = 0.2; // Adjust this to control when slopes start being colored differently
uniform sampler2D steepness_texture;
uniform vec2 steepness_scale = vec2(1.0, 1.0); // x for position scaling, y for height scaling
uniform float height_cutoff = 0.5; // Above this height, ignore steepness
uniform float height_cutoff_min = 0.1; // Below this height, ignore steepness
uniform float height_transition_offset = 0.1; // Controls smoothness of height transitions
uniform sampler2D flat_texture; // Texture for non-steep areas
uniform vec2 flat_scale = vec2(1.0, 1.0); // Same as steepness_scale but for flat areas


varying float steepness;

float hval(vec2 pos){
  return  texture(heightmap,vec2(.5,.5)+ pos/map_size).r * height_scale;
}

void vertex() {
  float height = hval(VERTEX.xz);
  VERTEX.y = height ;
  vec2 e = vec2(3.5, 0.0);
  vec3 normal = normalize(vec3(hval(VERTEX.xz - e) - hval(VERTEX.xz + e), 2.0 * e.x, hval(VERTEX.xz - e.yx) - hval(VERTEX.xz + e.yx)));
  NORMAL = normal;
  steepness = (1.0 - dot(NORMAL, vec3(0.0, 1.0, 0.0))) * 2.0; // or even * 4.0
}

void fragment() {
    float height = texture(heightmap, UV).r;

    // Create UV coordinates for both textures
    vec2 texture_uv = vec2(
        VERTEX.x * steepness_scale.x,
        (1.-height) * steepness_scale.y
    );

    // Sample both textures
    vec3 steep_color = texture(steepness_texture, texture_uv).rgb;
    vec3 flat_color = texture(flat_texture, texture_uv * flat_scale).rgb;

    // Calculate steepness factor with height cutoffs
    float steepness_factor = smoothstep(slope_threshold, slope_threshold + slope_threshold_offset, steepness);

    // Apply both height cutoffs with smooth transitions
    float height_factor = smoothstep(height_cutoff_min, height_cutoff_min + height_transition_offset, height) *
                         smoothstep(height_cutoff + height_transition_offset, height_cutoff, height);

    steepness_factor *= height_factor;

    // Blend between flat and steep colors
    vec3 final_color = mix(flat_color, steep_color, steepness_factor);

    ALBEDO = vec3(smoothstep(0.0, 1.0, AO)) * final_color;

    METALLIC = clamp(height, 0., .5);
    ROUGHNESS = clamp(height, .75, 1.);
}