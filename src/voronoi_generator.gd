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
var seed_value: int = 0
enum ScalingType { LINEAR, QUADRATIC, EXPONENTIAL, SIGMOID, INVERSE, POWER, COSINE }
var scaling_type: ScalingType = ScalingType.POWER

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


  # Generate random points for Voronoi cells
  var rng = RandomNumberGenerator.new()
  if seed_value > 0:
    rng.seed = seed_value
  var points = PackedVector2Array()
  for i in range(num_points):
      points.append(Vector2(rng.randf(), rng.randf()))
  # points[0] = Vector2(.5,.5)
  # Create buffers
  var heightmap_buffer = rd.storage_buffer_create(map_size * map_size * 4)
  var points_buffer = rd.storage_buffer_create(points.size() * 8, points.to_byte_array())

  # Create uniform set
  var uniforms := [
      create_uniform(heightmap_buffer, 0),
      create_uniform(points_buffer, 1)
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
  var params := PackedFloat32Array([
      float(map_size),
      float(num_points),
      height_falloff,
      min_height,  # Complete first 16-byte block

      max_height,
      ridge_multiplier,
      float(scaling_type),
      amplitude,
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
  rd.free_rid(points_buffer)

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
    print("Map size: ", map_size, "x", map_size)
    print("Number of points: ", num_points)
    print("points: ",points)
    print("Height range settings: ", min_height, " to ", max_height)
    print("Actual height range: ", actual_min_height, " to ", actual_max_height)
    save_debug_image(heightmap_image, "voronoi_heightmap_debug")
