@tool
extends Node3D

@export_group("Input Settings")
@export var input_heightmap: Texture2D

@export var height_scale: float = 50.0:
  set(value):
    height_scale = value
    if material:
      material.set_shader_parameter("height_scale", value)

@export var terrain_size: Vector2 = Vector2(100, 100)
@export var resolution: int = 255  # Must be power of 2 minus 1

@export_group("Erosion Settings")
@export var erosion_enabled: bool = false:
  set(value):
    erosion_enabled = true
    erode()
    erosion_enabled = false
@export var reset_heightmap: bool = false:
  set(value):
    reset_heightmap = true
    reset()
    reset_heightmap = false

@export var num_erosion_iterations: int = 50000
@export var erosion_seed: int = 0
@export var erosion_brush_radius: int = 3
@export var max_lifetime: int = 30
@export var sediment_capacity_factor: float = 4.0
@export var min_sediment_capacity: float = 0.01
@export var deposit_speed: float = 0.5
@export var erode_speed: float = 0.5
@export var evaporate_speed: float = 0.01
@export var gravity: float = 10.0
@export var start_speed: float = 1.0
@export var start_water: float = 1.0
@export_range(0, 1) var inertia: float = 0.3

@export_group("Voronoi Settings")
@export var generate_voronoi: bool = false:
    set(value):
        generate_voronoi = false
        generate_voronoi_heightmap()
@export var voronoi_seed: int = 0:
    set(value):
        voronoi_seed = value
        generate_voronoi_heightmap()
@export var num_voronoi_points: int = 10:
    set(value):
        num_voronoi_points = value
        generate_voronoi_heightmap()
@export var height_falloff: float = 2.0:
    set(value):
        height_falloff = value
        generate_voronoi_heightmap()
@export_range(-1.0, 1.0) var min_voronoi_height: float = 0.0:
    set(value):
        min_voronoi_height = value
        generate_voronoi_heightmap()
@export_range(0.0, 1.0) var max_voronoi_height: float = 1.0:
    set(value):
        max_voronoi_height = value
        generate_voronoi_heightmap()
@export_range(-1.0, 1.0) var ridge_multiplier: float = 0.0:
    set(value):
        ridge_multiplier = value
        generate_voronoi_heightmap()
@export var amplitude: float = 1.0:
    set(value):
        amplitude = value
        generate_voronoi_heightmap()
enum ScalingType {
    LINEAR,
    QUADRATIC,
    EXPONENTIAL,
    SIGMOID,
    INVERSE,
    POWER,
    COSINE,
}

@export var scaling_type: ScalingType = ScalingType.POWER:
    set(value):
        scaling_type = value
        generate_voronoi_heightmap()

var rd: RenderingDevice
var erosion_compute_shader: RID
var voronoi_compute_shader: RID

var brush_indices: PackedInt32Array
var brush_weights: PackedFloat32Array
var random_indices: PackedInt32Array
var material: ShaderMaterial
var heightmap_image: Image
var heightmap_texture: ImageTexture

var original_input_heightmap: Image = null # Add this to store the original


func _ready():
  reset()
  generate_voronoi_heightmap()

func reset():
  initialize_erosion_compute()
  initialize_voronoi_compute()
  if input_heightmap and not original_input_heightmap:
    original_input_heightmap = input_heightmap.duplicate().get_image()  # Store original on startup
  print("Resetting erosion")
  setup_material()
  setup_heightmap()

func initialize_voronoi_compute():
  if not rd:
      rd = RenderingServer.create_local_rendering_device()

  var shader_file := load("res://src/voronoi_heightmap_compute.glsl")
  var shader_spirv: RDShaderSPIRV = shader_file.get_spirv()
  voronoi_compute_shader = rd.shader_create_from_spirv(shader_spirv)
  print("Voronoi compute shader created", voronoi_compute_shader)

func generate_voronoi_heightmap():
  if not rd:
      rd = RenderingServer.create_local_rendering_device()


  # First, verify shader is loaded
  if not voronoi_compute_shader:
      printerr("Voronoi compute shader not initialized")
      return

  var map_size = resolution + 1

  # Generate random points for Voronoi cells
  var rng = RandomNumberGenerator.new()
  rng.seed = voronoi_seed
  var points = PackedVector2Array()
  for i in range(num_voronoi_points):
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
      float(num_voronoi_points),
      height_falloff,
      min_voronoi_height,  # Complete first 16-byte block

      max_voronoi_height,
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

  # Get results and verify changes
  var output_bytes = rd.buffer_get_data(heightmap_buffer)
  var height_data = output_bytes.to_float32_array()

  # Debug output
  print("Voronoi heightmap generation complete")
  print("Map size: ", map_size, "x", map_size)
  print("Number of points: ", num_voronoi_points)
  print("points: ",points)
  print("Height range settings: ", min_voronoi_height, " to ", max_voronoi_height)

  # Find actual min/max heights for verification
  var min_height = 1.0
  var max_height = 0.0
  for height in height_data:
      min_height = min(min_height, height)
      max_height = max(max_height, height)
  print("Actual height range: ", min_height, " to ", max_height)

  # Create and update heightmap image
  heightmap_image = Image.create(map_size, map_size, false, Image.FORMAT_RF)
  for y in range(map_size):
      for x in range(map_size):
          var height = height_data[y * map_size + x]
          heightmap_image.set_pixel(x, y, Color(height, 0, 0, 0))

  heightmap_image.save_png("res://voronoi_heightmap_debug.png")
  # Save debug image as 32-bit EXR
  heightmap_image.save_exr("res://voronoi_heightmap_debug.exr")
  print("Debug heightmap saved to voronoi_heightmap_debug.exr")

  # Update texture for material
  heightmap_image.generate_mipmaps()
  heightmap_texture = ImageTexture.create_from_image(heightmap_image)
  if material:
      material.set_shader_parameter("heightmap", heightmap_texture)
      print("Heightmap texture updated in material")
  else:
      printerr("No material found to update")

  # Cleanup
  rd.free_rid(heightmap_buffer)
  rd.free_rid(points_buffer)

func initialize_erosion_compute():
  rd = RenderingServer.create_local_rendering_device()

  var shader_file := load("res://src/erosion_compute.glsl")
  var shader_spirv: RDShaderSPIRV = shader_file.get_spirv()
  erosion_compute_shader = rd.shader_create_from_spirv(shader_spirv)

  create_erosion_brush()

func setup_material():
  var mesh_instance = get_parent() if get_parent() is MeshInstance3D else null
  if mesh_instance:
    material = mesh_instance.material_override
    print("material %s"%material)

  # Move heightmap setup to setup_heightmap() function
  if material:
    material.set_shader_parameter("height_scale", height_scale)

func setup_heightmap():
  var mesh_instance = get_parent()

  # Setup mesh if needed
  if not mesh_instance is MeshInstance3D:
    print("Error: Parent must be a MeshInstance3D", mesh_instance)
    return

  # Reset heightmap to original state
  if original_input_heightmap:
    print("Resetting heightmap image")
    heightmap_image = original_input_heightmap.duplicate()
    heightmap_image.convert(Image.FORMAT_RF)
    heightmap_image.resize(resolution + 1, resolution + 1)
    heightmap_image.generate_mipmaps()
    heightmap_texture = ImageTexture.create_from_image(heightmap_image)
    if material:
      print("Setting heightmap texture")
      material.set_shader_parameter("heightmap", heightmap_texture)
    return

func create_erosion_brush():
  brush_indices = PackedInt32Array()
  brush_weights = PackedFloat32Array()
  var weight_sum = 0.0
  var map_size = resolution + 1

  # Create a simple 3x3 brush pattern
  # This will affect the center cell and its 8 neighbors
  for y in range(-1, 2):  # -1, 0, 1
    for x in range(-1, 2):  # -1, 0, 1
      # Calculate distance from center
      var dist = sqrt(x * x + y * y)

      # Calculate offset in the 1D heightmap array
      var offset = x + (y * map_size)
      brush_indices.append(offset)

      # Weight is 1.0 at center, decreasing with distance
      var weight = max(0.0, 1.0 - (dist / 1.5))
      weight_sum += weight
      brush_weights.append(weight)

  # Normalize weights so they sum to 1.0
  for i in range(brush_weights.size()):
    brush_weights[i] /= weight_sum

  print("Created brush with ", brush_indices.size(), " indices")
  print("Brush indices: ", Array(brush_indices))
  print("Brush weights: ", Array(brush_weights))

func save_debug_images(original_data: PackedFloat32Array, eroded_data: PackedFloat32Array, map_size: int):
  # Create a new image for the difference visualization
  var diff_image = Image.create(map_size, map_size, false, Image.FORMAT_RGB8)

  # Find the maximum difference for normalization
  var max_diff = 0.0
  for i in range(original_data.size()):
    var diff = abs(eroded_data[i] - original_data[i])
    max_diff = max(max_diff, diff)

  # Create difference visualization
  # Red = erosion (height decreased)
  # Green = deposition (height increased)
  # Black = no change
  for y in range(map_size):
    for x in range(map_size):
      var idx = y * map_size + x
      var diff = eroded_data[idx] - original_data[idx]
      var color: Color

      if abs(diff) < 0.0001:  # No significant change
        color = Color.BLACK
      elif diff > 0:  # Deposition
        color = Color(0, diff/max_diff, 0)
      else:  # Erosion
        color = Color(-diff/max_diff, 0, 0)

      diff_image.set_pixel(x, y, color)

  # Save images
  heightmap_image.save_png("res://eroded_heightmap.png")
  heightmap_image.save_exr("res://eroded_heightmap.exr")  # Save as 32-bit EXR
  diff_image.save_png("res://erosion_difference.png")

func erode():
  if not rd or not heightmap_image:
    printerr("No rendering device or heightmap")
    return

  if input_heightmap and not original_input_heightmap:
    original_input_heightmap = input_heightmap.duplicate()  # Store original on startup

  var map_size = resolution +1

  # Validate parameters
  if brush_indices.size() == 0 or brush_weights.size() == 0:
    printerr("Invalid brush data")
    return

  if map_size <= 0:
    printerr("Invalid map size")
    return

  # Debug print parameters
  print("Debug Info:")
  print("Map Size: ", map_size)
  print("Brush Length: ", brush_indices.size())
  print("Erosion Params:")
  print("- Iterations: ", num_erosion_iterations)
  print("- Brush Radius: ", erosion_brush_radius)
  print("- Inertia: ", inertia)
  print("- Sediment Capacity Factor: ", sediment_capacity_factor)

  # Convert image to height data
  var map_data = PackedFloat32Array()
  map_data.resize(map_size * map_size)
  var original_data = PackedFloat32Array()
  original_data.resize(map_size * map_size)

  # Store and verify heightmap data
  var min_height = 1.0
  var max_height = 0.0
  for y in range(map_size):
    for x in range(map_size):
      var height = heightmap_image.get_pixel(x, y).r
      map_data[y * map_size + x] = height
      original_data[y * map_size + x] = height
      min_height = min(min_height, height)
      max_height = max(max_height, height)

  print("Height Range: ", min_height, " to ", max_height)
  print("First few height values: ", Array(map_data).slice(0, 10))


  # Add parameter range validation
  print("Parameter validation:")
  print("Map size: ", map_size)
  print("Brush size: ", brush_indices.size())
  print("Random indices size: ", random_indices.size())
  print("Height range: ", min_height, " to ", max_height)


  # Create random indices for droplets
  random_indices = PackedInt32Array()
  random_indices.resize(num_erosion_iterations)
  for i in range(num_erosion_iterations):
    var x = randi_range(erosion_brush_radius, map_size - erosion_brush_radius)
    var y = randi_range(erosion_brush_radius, map_size - erosion_brush_radius)
    random_indices[i] = y * map_size + x

  print("First few random indices: ", Array(random_indices).slice(0, 10))
  print("Brush weights: ", Array(brush_weights).slice(0, 5))
  print("Brush indices: ", Array(brush_indices).slice(0, 5))

  # Create compute shader buffers
  var heightmap_buffer = rd.storage_buffer_create(map_data.size() * 4, map_data.to_byte_array())
  var brush_indices_buffer = rd.storage_buffer_create(brush_indices.size() * 4, brush_indices.to_byte_array())
  var brush_weights_buffer = rd.storage_buffer_create(brush_weights.size() * 4, brush_weights.to_byte_array())
  var random_buffer = rd.storage_buffer_create(random_indices.size() * 4, random_indices.to_byte_array())

  # Create uniforms and verify
  var uniforms := [
    create_uniform(heightmap_buffer, 0),
    create_uniform(brush_indices_buffer, 1),
    create_uniform(brush_weights_buffer, 2),
    create_uniform(random_buffer, 3)
  ]

  var uniform_set = rd.uniform_set_create(uniforms, erosion_compute_shader, 0)
  var pipeline = rd.compute_pipeline_create(erosion_compute_shader)

  var params := PackedFloat32Array([
    # First 16-byte block (4 ints)
    float(map_size),
    float(brush_indices.size()),
    float(erosion_brush_radius),
    float(max_lifetime),

    # Second 16-byte block (4 floats)
    float(inertia),
    float(sediment_capacity_factor),
    float(min_sediment_capacity),
    float(deposit_speed),

    # Third 16-byte block (4 floats)
    float(erode_speed),
    float(evaporate_speed),
    float(gravity),
    float(start_speed),

    # Fourth 16-byte block (4 floats)
    float(start_water),
    float(0), # padding
    float(0),  # padding
    float(0),   # padding
  ])

  print("Parameters array size: ", params.size())  # Should be 16 now
  print("Push constant size in bytes: ", params.size() * 4)  # Should be 64 bytes

  var workgroup_size = 16
  # We need enough total threads to cover our num_erosion_iterations
  var total_threads_needed = num_erosion_iterations
  var num_workgroups = (num_erosion_iterations + workgroup_size - 1) / workgroup_size

  print("Debug dispatch info:")
  print("- Total iterations needed: ", total_threads_needed)
  print("- Workgroups: ", num_workgroups)
  print("- Total threads: ", num_workgroups * workgroup_size)

  var compute_list = rd.compute_list_begin()
  rd.compute_list_bind_compute_pipeline(compute_list, pipeline)
  rd.compute_list_bind_uniform_set(compute_list, uniform_set, 0)
  rd.compute_list_set_push_constant(compute_list, params.to_byte_array(), params.size() * 4)
  rd.compute_list_dispatch(compute_list, num_workgroups, 1, 1)

  rd.compute_list_end()
  rd.submit()
  rd.sync()

  # Get results and verify changes
  var output_bytes = rd.buffer_get_data(heightmap_buffer)
  map_data = output_bytes.to_float32_array()

  # Check if any changes occurred
  var max_diff = 0.0
  var changes_detected = false
  for i in range(map_data.size()):
    var diff = abs(map_data[i] - original_data[i])
    max_diff = max(max_diff, diff)
    if diff > 0.0001:
      changes_detected = true
      #print("Change detected at index ", i, ": ", original_data[i], " -> ", map_data[i])
      #if i < 10:  # Only print first few changes
        #print("Diff at ", i, ": ", diff)

  print("Maximum difference: ", max_diff)
  print("Changes detected: ", changes_detected)

  # Update heightmap image
  for y in range(map_size):
    for x in range(map_size):
      var height = map_data[y * map_size + x]
      heightmap_image.set_pixel(x, y, Color(height, 0, 0, 0))

  # Save debug images
  var diff_image = Image.create(map_size, map_size, false, Image.FORMAT_RGB8)
  for y in range(map_size):
    for x in range(map_size):
      var idx = y * map_size + x
      var diff = map_data[idx] - original_data[idx]
      var color: Color
      if abs(diff) < 0.0001:
        color = Color.BLACK
      elif diff > 0:
        color = Color(0, diff/max_diff, 0)
      else:
        color = Color(-diff/max_diff, 0, 0)
      diff_image.set_pixel(x, y, color)

  heightmap_image.save_exr("res://eroded_heightmap.exr")  # Save as 32-bit EXR
  heightmap_image.save_png("res://eroded_heightmap.png")
  diff_image.save_png("res://erosion_difference.png")

  # Update texture
  heightmap_image.generate_mipmaps()
  heightmap_texture = ImageTexture.create_from_image(heightmap_image)
  material.set_shader_parameter("heightmap", heightmap_texture)

  # Cleanup
  rd.free_rid(heightmap_buffer)
  rd.free_rid(brush_indices_buffer)
  rd.free_rid(brush_weights_buffer)
  rd.free_rid(random_buffer)

  # After running the compute shader:
  print("First few heights before: ", Array(original_data).slice(0, 5))
  print("First few heights after: ", Array(map_data).slice(0, 5))
  print("First few brush indices: ", Array(brush_indices).slice(0, 5))
  print("First random position: ", random_indices[0] % map_size, ", ", random_indices[0] / map_size)

  # After getting results:
  print("Height changes at first droplet position:")
  var first_pos = random_indices[0]
  var x = first_pos % map_size
  var y = first_pos / map_size
  for dy in range(-1, 2):
    var row = []
    for dx in range(-1, 2):
      var idx = (y + dy) * map_size + (x + dx)
      if idx >= 0 and idx < map_data.size():
        row.append("%.3f" % (map_data[idx] - original_data[idx]))
      else:
        row.append("X")
    print(row)

  # In the erode() function, after creating buffers:
  print("\nDebug Info:")
  print("Map dimensions: ", map_size, "x", map_size)
  print("Total heightmap size: ", map_data.size())
  print("Brush pattern size: ", brush_indices.size())
  print("Sample brush indices: ", Array(brush_indices).slice(0, 5))
  print("Sample brush weights: ", Array(brush_weights).slice(0, 5))
  print("First droplet position: ", random_indices[0] % map_size, ",", random_indices[0] / map_size)
  print("First droplet index: ", random_indices[0])

  # After getting results:
  if changes_detected:
    print("\nChanges detected at indices:")
    var count = 0
    for i in range(map_data.size()):
      if abs(map_data[i] - original_data[i]) > 0.0001:
        print("Index ", i, ": ", original_data[i], " -> %f"% map_data[i])
        count += 1
        if count >= 10:  # Only show first 10 changes
          break

func create_uniform(buffer: RID, binding: int) -> RDUniform:
  var uniform := RDUniform.new()
  uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
  uniform.binding = binding
  uniform.add_id(buffer)
  return uniform
