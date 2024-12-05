@tool
extends HeightmapGenerator
class_name ErosionGenerator

var erosion_compute_shader: RID
var brush_indices: PackedInt32Array
var brush_weights: PackedFloat32Array
var random_indices: PackedInt32Array

# Erosion settings
var num_iterations: int = 50000
var seed_value: int = 0
var brush_radius: int = 3
var max_lifetime: int = 30
var sediment_capacity_factor: float = 4.0
var min_sediment_capacity: float = 0.01
var deposit_speed: float = 0.5
var erode_speed: float = 0.5
var evaporate_speed: float = 0.01
var gravity: float = 10.0
var start_speed: float = 1.0
var start_water: float = 1.0
var inertia: float = 0.3

func _init():
  initialize_compute()

func initialize_compute() -> void:
  if not rd:
      rd = RenderingServer.create_local_rendering_device()

  var shader_file := load("res://src/erosion_compute.glsl")
  var shader_spirv: RDShaderSPIRV = shader_file.get_spirv()
  erosion_compute_shader = rd.shader_create_from_spirv(shader_spirv)
  create_erosion_brush()

func generate_heightmap() -> void:
  generate_erosion_heightmap()


func create_erosion_brush():
  brush_indices = PackedInt32Array()
  brush_weights = PackedFloat32Array()
  var weight_sum = 0.0

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


func generate_erosion_heightmap():
  if not rd or not heightmap_image:
    printerr("No rendering device or heightmap")
    return


  # Validate parameters
  if brush_indices.size() == 0 or brush_weights.size() == 0:
    printerr("Invalid brush data")
    return

  if map_size <= 0:
    printerr("Invalid map size")
    return

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

  if debug_output:
    print("Debug Info:")
    print("Map Size: ", map_size)
    print("Brush Length: ", brush_indices.size())
    print("Erosion Params:")
    print("- Iterations: ", num_iterations)
    print("- Brush Radius: ", brush_radius)
    print("- Brush size: ", brush_indices.size())
    print("- Inertia: ", inertia)
    print("- Sediment Capacity Factor: ", sediment_capacity_factor)
    print("Parameter validation:")
    print("- Height Range: ", min_height, " to ", max_height)
    print("- First few height values: ", Array(map_data).slice(0, 10))
    print("- Random indices size: ", random_indices.size())


  # Create random indices for droplets using a seeded RNG
  var rng = RandomNumberGenerator.new()
  if seed_value > 0:
    rng.seed = seed_value

  random_indices = PackedInt32Array()
  random_indices.resize(num_iterations)
  for i in range(num_iterations):
    var _x = rng.randi_range(brush_radius, map_size - brush_radius)
    var _y = rng.randi_range(brush_radius, map_size - brush_radius)
    random_indices[i] = _y * map_size + _x

  if debug_output:
    print("- First few random indices: ", Array(random_indices).slice(0, 10))
    print("- Brush weights: ", Array(brush_weights).slice(0, 5))
    print("- Brush indices: ", Array(brush_indices).slice(0, 5))

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
    float(brush_radius),
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


  var workgroup_size = 16
  # We need enough total threads to cover our num_erosion_iterations
  var total_threads_needed = num_iterations
  var num_workgroups = (num_iterations + workgroup_size - 1) / workgroup_size

  if debug_output:
    print("- Parameters array size: ", params.size())  # Should be 16 now
    print("- Push constant size in bytes: ", params.size() * 4)  # Should be 64 bytes
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
  var changes_detected = false
  if debug_output:
    var max_diff = 0.0
    for i in range(map_data.size()):
      var diff = abs(map_data[i] - original_data[i])
      max_diff = max(max_diff, diff)
      if diff > 0.0001:
        changes_detected = true


    print("Maximum difference: ", max_diff)
    print("Changes detected: ", changes_detected)
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
    diff_image.save_png("res://erosion_difference.png")
    #end debug

  # TODO: This is a temporary hack to get the heightmap to update
  # TODO: better to use set_data if possibe, without having to set each pixel
  #heightmap_image.set_data(map_data)
  heightmap_image = Image.create(map_size, map_size, false, Image.FORMAT_RF)
  # Update heightmap image
  for y in range(map_size):
    for x in range(map_size):
      var height = map_data[y * map_size + x]
      heightmap_image.set_pixel(x, y, Color(height, height, height, 0))


  # Update texture
  heightmap_image.generate_mipmaps()
  heightmap_texture = ImageTexture.create_from_image(heightmap_image)
  if debug_output:
    save_debug_image(heightmap_image, "eroded_heightmap_debug")
  save_heightmap_exr("res://eroded_heightmap.exr")
  save_heightmap_png("res://eroded_heightmap.png")

  # Cleanup
  rd.free_rid(heightmap_buffer)
  rd.free_rid(brush_indices_buffer)
  rd.free_rid(brush_weights_buffer)
  rd.free_rid(random_buffer)

  if debug_output:
    # After running the compute shader:
    print("First few heights before: ", Array(original_data).slice(0, 5))
    print("First few heights after: ", Array(map_data).slice(0, 5))
    print("First few brush indices: ", Array(brush_indices).slice(0, 5))
    print("First random position: ", random_indices[0] % map_size, ", ", random_indices[0] / map_size)

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

    if changes_detected:
      print("\nChanges detected at indices:")
      var count = 0
      for i in range(map_data.size()):
        if abs(map_data[i] - original_data[i]) > 0.0001:
          print("Index ", i, ": ", original_data[i], " -> %f"% map_data[i])
          count += 1
          if count >= 10:  # Only show first 10 changes
            break
