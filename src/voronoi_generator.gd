@tool
extends HeightmapGenerator
class_name VoronoiGenerator

var voronoi_compute_shader: RID

# Voronoi settings
var num_points: int = 10
var height_falloff: float = 2.0
var min_height: float = 0.0
var max_height: float = 1.0
var ridge_multiplier: float = 0.0
var amplitude: float = 1.0
var voronoi_intensity: float = 1.0  # Controls contribution of Voronoi layer (0.0 = none, 1.0 = full)
var seed_value: int = 0
enum ScalingType { LINEAR, QUADRATIC, EXPONENTIAL, SIGMOID, INVERSE, POWER, COSINE }
var scaling_type: ScalingType = ScalingType.POWER

# NEW: Tile position for seamless tiling
var tile_x: int = 0
var tile_y: int = 0

# Layer control flags
var enable_voronoi: bool = true
var enable_global_noise: bool = true

# Global Noise Layer - adds large-scale height variation
var global_noise_intensity: float = 0.3  # Controls contribution of global noise layer (0.0 = none, 1.0 = full)
var global_noise_frequency: float = 0.015  # ~67 units wavelength = ~26 tiles
var global_noise_octaves: int = 3
var global_noise_lacunarity: float = 2.0
var global_noise_persistence: float = 0.5
var global_noise_seed: int = 0

# Parameter Morphing - varies Voronoi parameters across world space
var enable_morphing: bool = true
var morphing_frequency: float = 0.01  # How fast zones change (~100 unit wavelength)
var morphing_seed: int = 1000  # Separate from height noise

# Ridge multiplier morphing
var morph_ridge: bool = true
var ridge_min: float = 0.0
var ridge_max: float = 1.0

# Num points morphing
var morph_num_points: bool = true
var num_points_min: int = 5
var num_points_max: int = 20

# Height falloff morphing
var morph_falloff: bool = true
var falloff_min: float = 1.0
var falloff_max: float = 4.0

# Scaling type morphing (advanced, disabled by default)
var morph_scaling_type: bool = false

func _init():
    initialize_compute()

func initialize_compute() -> void:
    if not rd:
        rd = RenderingServer.create_local_rendering_device()

    var shader_file := load("res://src/voronoi_heightmap_compute.glsl")
    var shader_spirv: RDShaderSPIRV = shader_file.get_spirv()
    voronoi_compute_shader = rd.shader_create_from_spirv(shader_spirv)

func generate_heightmap() -> void:
    generate_voronoi_heightmap()


func generate_voronoi_heightmap():
  if not rd:
      rd = RenderingServer.create_local_rendering_device()

  # First, verify shader is loaded
  if not voronoi_compute_shader:
      printerr("Voronoi compute shader not initialized")
      return

  # No longer need to generate random points - done in shader!

  # Create buffers - only heightmap buffer needed now
  var heightmap_buffer = rd.storage_buffer_create(map_size * map_size * 4)

  # Create uniform set - only heightmap buffer
  var uniforms := [
      create_uniform(heightmap_buffer, 0),
  ]

  # Verify shader and create pipeline first
  var pipeline = rd.compute_pipeline_create(voronoi_compute_shader)
  if not pipeline:
      printerr("Failed to create compute pipeline")
      return

  var uniform_set = rd.uniform_set_create(uniforms, voronoi_compute_shader, 0)
  if not uniform_set:
      printerr("Failed to create uniform set")
      return

  # Set parameters - align to 16 bytes (4 floats per block)
  # MUST stay within 128 bytes (8 blocks) limit!
  var params := PackedFloat32Array([
      # Block 1
      float(map_size),
      float(num_points),
      float(tile_x),
      float(tile_y),

      # Block 2
      height_falloff,
      min_height,
      max_height,
      ridge_multiplier,

      # Block 3
      float(scaling_type),
      amplitude,
      float(seed_value),
      voronoi_intensity,  # Voronoi layer intensity

      # Block 4: Global noise parameters
      global_noise_intensity,  # Global noise layer intensity
      global_noise_frequency,
      global_noise_lacunarity,
      global_noise_persistence,

      # Block 5: Global noise + morphing seeds
      float(global_noise_octaves),
      float(global_noise_seed),
      morphing_frequency,
      float(morphing_seed),

      # Block 6: Morphing ranges - ridge & num_points
      ridge_min,
      ridge_max,
      float(num_points_min),
      float(num_points_max),

      # Block 7: Morphing ranges - falloff + layer enable flags
      falloff_min,
      falloff_max,
      1.0 if enable_voronoi else 0.0,
      1.0 if enable_global_noise else 0.0,

      # Block 8: Morphing enable flags
      1.0 if enable_morphing else 0.0,
      1.0 if morph_ridge else 0.0,
      1.0 if morph_num_points else 0.0,
      1.0 if morph_falloff else 0.0,
  ])

  # Dispatch compute shader
  var compute_list = rd.compute_list_begin()
  rd.compute_list_bind_compute_pipeline(compute_list, pipeline)
  rd.compute_list_bind_uniform_set(compute_list, uniform_set, 0)
  rd.compute_list_set_push_constant(compute_list, params.to_byte_array(), params.size() * 4)

  var workgroup_size = 16
  var num_workgroups = (map_size + workgroup_size - 1) / workgroup_size
  rd.compute_list_dispatch(compute_list, num_workgroups, num_workgroups, 1)

  rd.compute_list_end()
  rd.submit()
  rd.sync()

  # Get results
  var output_bytes = rd.buffer_get_data(heightmap_buffer)
  var height_data = output_bytes.to_float32_array()
  # Cleanup
  rd.free_rid(heightmap_buffer)

  # Create and update heightmap image
  heightmap_image = Image.create(map_size, map_size, false, Image.FORMAT_RF)
  for y in range(map_size):
      for x in range(map_size):
          var height = height_data[y * map_size + x]
          heightmap_image.set_pixel(x, y, Color(height, 0, 0, 0))


  # Update texture for material
  heightmap_image.generate_mipmaps()
  heightmap_texture = ImageTexture.create_from_image(heightmap_image)


  # Debug output
  if debug_output:
    # Find actual min/max heights for verification
    var actual_min_height = 1.0
    var actual_max_height = 0.0
    for height in height_data:
        actual_min_height = min(actual_min_height, height)
        actual_max_height = max(actual_max_height, height)
    print("Voronoi heightmap generation complete")
    print("Tile position: (%d, %d)" % [tile_x, tile_y])
    print("Map size: ", map_size, "x", map_size)
    print("Number of points per tile: ", num_points)
    print("Height range settings: ", min_height, " to ", max_height)
    print("Actual height range: ", actual_min_height, " to ", actual_max_height)
    save_debug_image(heightmap_image, "voronoi_tile_%d_%d" % [tile_x, tile_y])
