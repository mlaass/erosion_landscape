@tool
extends HeightmapGenerator
class_name ErosionGeneratorTiled

var erosion_compute_shader: RID  # Classic brush-based shader
var erosion_compute_textured_shader: RID  # Texture-based shader
var brush_indices: PackedInt32Array
var brush_weights: PackedFloat32Array
var voronoi_generator: VoronoiGenerator  # Reused for all Voronoi generation

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

# NEW: Tile position and padding for seamless tiling
var tile_x: int = 0
var tile_y: int = 0
var padding_pixels: int = 128
var droplets_per_tile: int = 500  # Droplets spawned per tile

# Erosion layer control
var enable_erosion: bool = true  # Toggle erosion on/off
var erosion_intensity: float = 1.0  # 0.0 = no erosion, 1.0 = full erosion (opacity blend)

# Texture-based erosion (experimental)
var use_texture_erosion: bool = false  # false = brush mode, true = texture mode
var erosion_texture_path: String = ""
var sediment_texture_path: String = ""
var erosion_texture_scale: float = 32.0  # Size in pixels (32 = 32×32 area)
var sediment_texture_scale: float = 32.0
var rotate_textures_with_flow: bool = true

# Runtime texture data (internal)
var erosion_texture_image: Image = null
var sediment_texture_image: Image = null
var erosion_texture_rid: RID = RID()
var sediment_texture_rid: RID = RID()
var texture_sampler_rid: RID = RID()
var textures_loaded: bool = false

func _init():
  initialize_compute()

func initialize_compute() -> void:
  if not rd:
    rd = RenderingServer.create_local_rendering_device()

  # Load classic brush-based shader
  var shader_file := load("res://src/erosion_compute_tiled.glsl")
  var shader_spirv: RDShaderSPIRV = shader_file.get_spirv()
  erosion_compute_shader = rd.shader_create_from_spirv(shader_spirv)

  # Load texture-based shader
  var textured_shader_file := load("res://src/erosion_compute_textured_tiled.glsl")
  var textured_shader_spirv: RDShaderSPIRV = textured_shader_file.get_spirv()
  erosion_compute_textured_shader = rd.shader_create_from_spirv(textured_shader_spirv)

  create_erosion_brush()

  # Create reusable Voronoi generator
  voronoi_generator = VoronoiGenerator.new()
  voronoi_generator.map_size = map_size
  voronoi_generator.num_points = 8
  voronoi_generator.height_falloff = 2.0
  voronoi_generator.min_height = 0.0
  voronoi_generator.max_height = 1.0
  voronoi_generator.ridge_multiplier = 0.0
  voronoi_generator.amplitude = 1.0
  voronoi_generator.scaling_type = VoronoiGenerator.ScalingType.POWER
  voronoi_generator.debug_output = false

  # === LAYER CONTROL ===
  # Toggle these to test individual layers:
  # - enable_voronoi: false, enable_global_noise: true  → Test noise alone
  # - enable_voronoi: true,  enable_global_noise: false → Test Voronoi alone
  # - enable_voronoi: true,  enable_global_noise: true  → Both layers blended

  voronoi_generator.enable_voronoi = true
  voronoi_generator.enable_global_noise = true

  # Global noise layer - creates large-scale mountain ranges
  voronoi_generator.global_noise_intensity = 0.3  # Intensity of global noise layer
  voronoi_generator.global_noise_frequency = 0.015  # ~26 tile wavelength for mountain ranges
  voronoi_generator.global_noise_octaves = 2  # Reduced from 3 for performance
  voronoi_generator.global_noise_lacunarity = 2.0
  voronoi_generator.global_noise_persistence = 0.5
  voronoi_generator.global_noise_seed = 0

  # Parameter morphing - DISABLED (too expensive for per-pixel computation)
  voronoi_generator.enable_morphing = false
  voronoi_generator.morphing_frequency = 0.01  # ~50 tile wavelength for zone changes
  voronoi_generator.morphing_seed = 1000

  # Ridge morphing: smooth plains → sharp ridges
  voronoi_generator.morph_ridge = false
  voronoi_generator.ridge_min = 0.0
  voronoi_generator.ridge_max = 0.8  # Maximum 0.8 to avoid extreme spikes

  # Num points morphing: disabled (can't vary point count per pixel in shader)
  voronoi_generator.morph_num_points = false
  voronoi_generator.num_points_min = 5
  voronoi_generator.num_points_max = 15

  # Falloff morphing: gentle slopes → steep cliffs
  voronoi_generator.morph_falloff = false
  voronoi_generator.falloff_min = 1.0
  voronoi_generator.falloff_max = 4.0

  # Scaling type morphing (disabled for now - can be complex)
  voronoi_generator.morph_scaling_type = false

func generate_heightmap() -> void:
  generate_erosion_heightmap_tiled()

func create_erosion_brush():
  brush_indices = PackedInt32Array()
  brush_weights = PackedFloat32Array()
  var weight_sum = 0.0

  # Create a simple 3x3 brush pattern
  for y in range(-1, 2):
    for x in range(-1, 2):
      var dist = sqrt(x * x + y * y)
      var offset = x + (y * (map_size + 2 * padding_pixels))  # Use extended size
      brush_indices.append(offset)
      var weight = max(0.0, 1.0 - (dist / 1.5))
      weight_sum += weight
      brush_weights.append(weight)

  # Normalize weights
  for i in range(brush_weights.size()):
    brush_weights[i] /= weight_sum

  if debug_output:
    print("Created brush with ", brush_indices.size(), " indices")

func create_texture_sampler() -> bool:
  if not rd:
    return false

  # Create sampler with linear filtering for smooth texture sampling
  var sampler_state = RDSamplerState.new()
  sampler_state.mag_filter = RenderingDevice.SAMPLER_FILTER_LINEAR
  sampler_state.min_filter = RenderingDevice.SAMPLER_FILTER_LINEAR
  sampler_state.repeat_u = RenderingDevice.SAMPLER_REPEAT_MODE_CLAMP_TO_EDGE
  sampler_state.repeat_v = RenderingDevice.SAMPLER_REPEAT_MODE_CLAMP_TO_EDGE

  texture_sampler_rid = rd.sampler_create(sampler_state)

  if texture_sampler_rid.is_valid():
    if debug_output:
      print("Created texture sampler")
    return true
  else:
    printerr("Failed to create texture sampler")
    return false

func load_erosion_textures() -> bool:
  if not rd:
    printerr("No rendering device for texture loading")
    return false

  # Validate texture paths
  if erosion_texture_path.is_empty() or sediment_texture_path.is_empty():
    if debug_output:
      print("Texture paths not set, falling back to brush mode")
    use_texture_erosion = false
    return false

  # Load erosion texture
  if FileAccess.file_exists(erosion_texture_path):
    erosion_texture_image = Image.load_from_file(erosion_texture_path)
    if erosion_texture_image == null:
      printerr("Failed to load erosion texture: ", erosion_texture_path)
      use_texture_erosion = false
      return false

    # Convert to RGBAF format for compute shader
    if erosion_texture_image.get_format() != Image.FORMAT_RGBAF:
      erosion_texture_image.convert(Image.FORMAT_RGBAF)

    # Create texture RID
    var texture_format = RDTextureFormat.new()
    texture_format.width = erosion_texture_image.get_width()
    texture_format.height = erosion_texture_image.get_height()
    texture_format.format = RenderingDevice.DATA_FORMAT_R32G32B32A32_SFLOAT
    texture_format.usage_bits = RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT | RenderingDevice.TEXTURE_USAGE_CAN_UPDATE_BIT

    erosion_texture_rid = rd.texture_create(texture_format, RDTextureView.new(), [erosion_texture_image.get_data()])

    if not erosion_texture_rid.is_valid():
      printerr("Failed to create erosion texture RID")
      use_texture_erosion = false
      return false
  else:
    printerr("Erosion texture file not found: ", erosion_texture_path)
    use_texture_erosion = false
    return false

  # Load sediment texture
  if FileAccess.file_exists(sediment_texture_path):
    sediment_texture_image = Image.load_from_file(sediment_texture_path)
    if sediment_texture_image == null:
      printerr("Failed to load sediment texture: ", sediment_texture_path)
      use_texture_erosion = false
      return false

    if sediment_texture_image.get_format() != Image.FORMAT_RGBAF:
      sediment_texture_image.convert(Image.FORMAT_RGBAF)

    var texture_format = RDTextureFormat.new()
    texture_format.width = sediment_texture_image.get_width()
    texture_format.height = sediment_texture_image.get_height()
    texture_format.format = RenderingDevice.DATA_FORMAT_R32G32B32A32_SFLOAT
    texture_format.usage_bits = RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT | RenderingDevice.TEXTURE_USAGE_CAN_UPDATE_BIT

    sediment_texture_rid = rd.texture_create(texture_format, RDTextureView.new(), [sediment_texture_image.get_data()])

    if not sediment_texture_rid.is_valid():
      printerr("Failed to create sediment texture RID")
      use_texture_erosion = false
      return false
  else:
    printerr("Sediment texture file not found: ", sediment_texture_path)
    use_texture_erosion = false
    return false

  # Create sampler
  if not create_texture_sampler():
    use_texture_erosion = false
    return false

  textures_loaded = true
  if debug_output:
    print("Erosion textures loaded successfully")
    print("  Erosion texture: ", erosion_texture_path, " (", erosion_texture_image.get_width(), "x", erosion_texture_image.get_height(), ")")
    print("  Sediment texture: ", sediment_texture_path, " (", sediment_texture_image.get_width(), "x", sediment_texture_image.get_height(), ")")

  return true

func generate_erosion_heightmap_tiled():
  if not rd:
    printerr("No rendering device")
    return

  var tile_size = map_size
  var extended_size = tile_size + 2 * padding_pixels

  if debug_output:
    print("\n=== Erosion Tiling Debug ===")
    print("Tile position: (%d, %d)" % [tile_x, tile_y])
    print("Tile size: %d" % tile_size)
    print("Padding: %d pixels" % padding_pixels)
    print("Extended size: %d" % extended_size)

  # Step 1: Generate extended heightmap with Voronoi
  var extended_heightmap = generate_extended_voronoi(tile_x, tile_y, tile_size, padding_pixels)

  if extended_heightmap == null:
    printerr("Failed to generate extended heightmap")
    return

  # Debug: Save extended Voronoi before erosion
  var extended_voronoi_copy: Image = null
  if debug_output:
    # Make a copy for difference calculation later
    extended_voronoi_copy = Image.create(extended_size, extended_size, false, Image.FORMAT_RF)
    extended_voronoi_copy.copy_from(extended_heightmap)

    extended_heightmap.save_png("res://output/png/extended_voronoi_tile_%d_%d.png" % [tile_x, tile_y])
    extended_heightmap.save_exr("res://output/exr/extended_voronoi_tile_%d_%d.exr" % [tile_x, tile_y])
    print("Saved extended Voronoi heightmap to output directory")

  # Early exit if erosion is disabled
  if not enable_erosion:
    if debug_output:
      print("Erosion disabled - skipping erosion simulation")
    # Skip directly to extracting center region
    heightmap_image = Image.create(tile_size, tile_size, false, Image.FORMAT_RF)
    for y in range(tile_size):
      for x in range(tile_size):
        var src_x = x + padding_pixels
        var src_y = y + padding_pixels
        var height = extended_heightmap.get_pixel(src_x, src_y).r
        heightmap_image.set_pixel(x, y, Color(height, 0, 0, 0))
    heightmap_image.generate_mipmaps()
    heightmap_texture = ImageTexture.create_from_image(heightmap_image)
    return

  # Store pre-erosion heightmap for opacity blending
  var pre_erosion_data = PackedFloat32Array()
  if erosion_intensity < 1.0:
    pre_erosion_data.resize(extended_size * extended_size)
    for y in range(extended_size):
      for x in range(extended_size):
        pre_erosion_data[y * extended_size + x] = extended_heightmap.get_pixel(x, y).r

  # Step 2: Calculate affected droplets
  var droplets = calculate_affected_droplets(tile_x, tile_y, tile_size, padding_pixels)

  if debug_output:
    print("Total affected droplets: %d" % droplets.size())

  # Step 3: Convert extended heightmap to buffer
  var map_data = PackedFloat32Array()
  map_data.resize(extended_size * extended_size)

  for y in range(extended_size):
    for x in range(extended_size):
      map_data[y * extended_size + x] = extended_heightmap.get_pixel(x, y).r

  # Step 4: Create droplet positions buffer
  var droplet_positions = PackedVector2Array()
  for droplet in droplets:
    droplet_positions.append(droplet.map_pos)

  if droplet_positions.size() == 0:
    print("Warning: No droplets to simulate")
    heightmap_image = extended_heightmap
    return

  if debug_output:
    print("Simulating %d droplets..." % droplet_positions.size())

  # Step 5: Run erosion on GPU
  var heightmap_buffer = rd.storage_buffer_create(map_data.size() * 4, map_data.to_byte_array())
  var brush_indices_buffer = rd.storage_buffer_create(brush_indices.size() * 4, brush_indices.to_byte_array())
  var brush_weights_buffer = rd.storage_buffer_create(brush_weights.size() * 4, brush_weights.to_byte_array())
  var droplet_buffer = rd.storage_buffer_create(droplet_positions.size() * 8, droplet_positions.to_byte_array())

  # Choose which shader to use
  var active_shader: RID
  if use_texture_erosion and textures_loaded:
    active_shader = erosion_compute_textured_shader
  else:
    active_shader = erosion_compute_shader

  var uniforms := [
    create_uniform(heightmap_buffer, 0),
    create_uniform(brush_indices_buffer, 1),
    create_uniform(brush_weights_buffer, 2),
    create_uniform(droplet_buffer, 3)
  ]

  # Add texture uniforms if using textured shader
  if use_texture_erosion and textures_loaded:
    # Create texture uniforms (binding 4 and 5)
    var erosion_tex_uniform = RDUniform.new()
    erosion_tex_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE
    erosion_tex_uniform.binding = 4
    erosion_tex_uniform.add_id(texture_sampler_rid)
    erosion_tex_uniform.add_id(erosion_texture_rid)
    uniforms.append(erosion_tex_uniform)

    var sediment_tex_uniform = RDUniform.new()
    sediment_tex_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE
    sediment_tex_uniform.binding = 5
    sediment_tex_uniform.add_id(texture_sampler_rid)
    sediment_tex_uniform.add_id(sediment_texture_rid)
    uniforms.append(sediment_tex_uniform)

    if debug_output:
      print("Using texture-based erosion shader")
  else:
    if debug_output:
      print("Using classic brush-based erosion shader")

  var uniform_set = rd.uniform_set_create(uniforms, active_shader, 0)
  var pipeline = rd.compute_pipeline_create(active_shader)

  var params := PackedFloat32Array([
    # Block 1
    float(extended_size),
    float(brush_indices.size()),
    float(brush_radius),
    float(max_lifetime),

    # Block 2
    float(inertia),
    float(sediment_capacity_factor),
    float(min_sediment_capacity),
    float(deposit_speed),

    # Block 3
    float(erode_speed),
    float(evaporate_speed),
    float(gravity),
    float(start_speed),

    # Block 4
    float(start_water),
    float(tile_size),
    float(padding_pixels),
    float(droplet_positions.size()),

    # Block 5
    float(tile_x),
    float(tile_y),
    float(seed_value),
    0.0,  # padding
  ])

  # Add Block 6 only for textured shader (96 bytes total)
  if use_texture_erosion and textures_loaded:
    params.append_array(PackedFloat32Array([
      # Block 6: Texture erosion parameters
      1.0,  # use_texture_mode (always 1.0 in textured shader)
      float(erosion_texture_scale),
      float(sediment_texture_scale),
      1.0 if rotate_textures_with_flow else 0.0,  # rotate_with_flow
    ]))
  # Classic shader uses 80 bytes (5 blocks), textured uses 96 bytes (6 blocks)

  var workgroup_size = 16
  var num_workgroups = (droplet_positions.size() + workgroup_size - 1) / workgroup_size

  var compute_list = rd.compute_list_begin()
  rd.compute_list_bind_compute_pipeline(compute_list, pipeline)
  rd.compute_list_bind_uniform_set(compute_list, uniform_set, 0)
  rd.compute_list_set_push_constant(compute_list, params.to_byte_array(), params.size() * 4)
  rd.compute_list_dispatch(compute_list, num_workgroups, 1, 1)

  rd.compute_list_end()
  rd.submit()
  rd.sync()

  # Step 6: Get results
  var output_bytes = rd.buffer_get_data(heightmap_buffer)
  map_data = output_bytes.to_float32_array()

  # Apply erosion intensity (opacity blend between pre-erosion and post-erosion)
  if erosion_intensity < 1.0 and pre_erosion_data.size() > 0:
    if debug_output:
      print("Blending erosion with intensity: %.2f" % erosion_intensity)
    for i in range(map_data.size()):
      # mix(pre, post, intensity): lerp between pre-erosion and post-erosion
      map_data[i] = lerp(pre_erosion_data[i], map_data[i], erosion_intensity)

  # Cleanup
  rd.free_rid(heightmap_buffer)
  rd.free_rid(brush_indices_buffer)
  rd.free_rid(brush_weights_buffer)
  rd.free_rid(droplet_buffer)

  # Debug: Create difference image to visualize erosion
  if debug_output and extended_voronoi_copy != null:
    print("Generating erosion difference map...")
    var eroded_extended = Image.create(extended_size, extended_size, false, Image.FORMAT_RF)
    for y in range(extended_size):
      for x in range(extended_size):
        eroded_extended.set_pixel(x, y, Color(map_data[y * extended_size + x], 0, 0, 0))

    # Create RGB difference image: red = erosion, green = deposition
    var diff_image = Image.create(extended_size, extended_size, false, Image.FORMAT_RGB8)
    var total_erosion = 0.0
    var total_deposition = 0.0
    var erosion_pixels = 0
    var deposition_pixels = 0

    for y in range(extended_size):
      for x in range(extended_size):
        var before = extended_voronoi_copy.get_pixel(x, y).r
        var after = eroded_extended.get_pixel(x, y).r
        var diff = after - before

        if diff < 0.0:
          # Erosion - show in red
          var intensity = clamp(abs(diff) * 50.0, 0.0, 1.0)  # Scale for visibility
          diff_image.set_pixel(x, y, Color(intensity, 0, 0))
          total_erosion += abs(diff)
          erosion_pixels += 1
        elif diff > 0.0:
          # Deposition - show in green
          var intensity = clamp(diff * 50.0, 0.0, 1.0)
          diff_image.set_pixel(x, y, Color(0, intensity, 0))
          total_deposition += diff
          deposition_pixels += 1
        else:
          # No change - show in dark gray
          diff_image.set_pixel(x, y, Color(0.1, 0.1, 0.1))

    diff_image.save_png("res://output/png/erosion_diff_tile_%d_%d.png" % [tile_x, tile_y])
    print("Erosion statistics:")
    print("  Total erosion: %.6f (%d pixels)" % [total_erosion, erosion_pixels])
    print("  Total deposition: %.6f (%d pixels)" % [total_deposition, deposition_pixels])
    print("  Net change: %.6f" % (total_deposition - total_erosion))
    print("Saved erosion difference map to output/png/")

  # Step 7: Extract center region (discard padding)
  heightmap_image = Image.create(tile_size, tile_size, false, Image.FORMAT_RF)

  # Also extract the center from the original Voronoi for comparison
  var voronoi_center: Image = null
  if debug_output and extended_voronoi_copy != null:
    voronoi_center = Image.create(tile_size, tile_size, false, Image.FORMAT_RF)

  for y in range(tile_size):
    for x in range(tile_size):
      var src_x = x + padding_pixels
      var src_y = y + padding_pixels
      var height = map_data[src_y * extended_size + src_x]
      heightmap_image.set_pixel(x, y, Color(height, 0, 0, 0))

      if voronoi_center != null:
        var voronoi_height = extended_voronoi_copy.get_pixel(src_x, src_y).r
        voronoi_center.set_pixel(x, y, Color(voronoi_height, 0, 0, 0))

  heightmap_image.generate_mipmaps()
  heightmap_texture = ImageTexture.create_from_image(heightmap_image)

  if debug_output:
    # Save final eroded tile (center region only) to output directory
    heightmap_image.save_png("res://output/png/eroded_tile_final_%d_%d.png" % [tile_x, tile_y])
    heightmap_image.save_exr("res://output/exr/eroded_tile_final_%d_%d.exr" % [tile_x, tile_y])

    # Save the extracted center of original Voronoi too
    if voronoi_center != null:
      voronoi_center.save_png("res://output/png/voronoi_center_tile_%d_%d.png" % [tile_x, tile_y])
      voronoi_center.save_exr("res://output/exr/voronoi_center_tile_%d_%d.exr" % [tile_x, tile_y])

      # Create difference image for center tile only
      var center_diff = Image.create(tile_size, tile_size, false, Image.FORMAT_RGB8)
      var tile_erosion = 0.0
      var tile_deposition = 0.0

      for y in range(tile_size):
        for x in range(tile_size):
          var before = voronoi_center.get_pixel(x, y).r
          var after = heightmap_image.get_pixel(x, y).r
          var diff = after - before

          if diff < 0.0:
            var intensity = clamp(abs(diff) * 50.0, 0.0, 1.0)
            center_diff.set_pixel(x, y, Color(intensity, 0, 0))
            tile_erosion += abs(diff)
          elif diff > 0.0:
            var intensity = clamp(diff * 50.0, 0.0, 1.0)
            center_diff.set_pixel(x, y, Color(0, intensity, 0))
            tile_deposition += diff
          else:
            center_diff.set_pixel(x, y, Color(0.1, 0.1, 0.1))

      center_diff.save_png("res://output/png/tile_diff_%d_%d.png" % [tile_x, tile_y])
      print("Tile center statistics:")
      print("  Erosion: %.6f, Deposition: %.6f, Net: %.6f" % [
        tile_erosion, tile_deposition, tile_deposition - tile_erosion
      ])

    print("Saved final eroded tile to output directory")
    print("=== Erosion Complete ===\n")

func generate_extended_voronoi(tx: int, ty: int, tile_size: int, padding: int) -> Image:
  """Generate Voronoi heightmap for extended region (tile + padding)"""
  var extended_size = tile_size + 2 * padding

  if debug_output:
    print("\n--- Generating Extended Voronoi ---")
    print("Target tile: (%d, %d)" % [tx, ty])
    print("Tile size: %d, Padding: %d" % [tile_size, padding])
    print("Extended size: %d" % extended_size)

  # Generate multiple Voronoi tiles and composite them to cover the extended region
  # We need to generate a region that includes the padding area around our tile

  # For simplicity, generate a larger single tile that covers the extended region
  # Calculate which tiles we need to partially include
  var tiles_needed = []

  # Main tile
  tiles_needed.append(Vector2i(tx, ty))

  # Add neighboring tiles if padding extends into them
  if padding > 0:
    tiles_needed.append(Vector2i(tx - 1, ty))
    tiles_needed.append(Vector2i(tx + 1, ty))
    tiles_needed.append(Vector2i(tx, ty - 1))
    tiles_needed.append(Vector2i(tx, ty + 1))
    tiles_needed.append(Vector2i(tx - 1, ty - 1))
    tiles_needed.append(Vector2i(tx + 1, ty - 1))
    tiles_needed.append(Vector2i(tx - 1, ty + 1))
    tiles_needed.append(Vector2i(tx + 1, ty + 1))

  if debug_output:
    print("Generating %d tiles for extended region..." % tiles_needed.size())

  # Create the extended image by sampling from generated tiles
  var extended_image = Image.create(extended_size, extended_size, false, Image.FORMAT_RF)

  # Reuse shared Voronoi generator (configured once in initialize_compute)
  voronoi_generator.seed_value = seed_value
  voronoi_generator.map_size = tile_size

  var pixels_written = 0
  for tile_pos in tiles_needed:
    voronoi_generator.tile_x = tile_pos.x
    voronoi_generator.tile_y = tile_pos.y
    voronoi_generator.generate_heightmap()

    # Verify the heightmap was generated
    if voronoi_generator.heightmap_image == null:
      printerr("Failed to generate Voronoi for tile (%d, %d)" % [tile_pos.x, tile_pos.y])
      continue

    # Calculate which part of this tile we need for our extended region
    # Extended region world bounds: (tx * tile_size - padding, ty * tile_size - padding)
    # This tile world bounds: (tile_pos.x * tile_size, tile_pos.y * tile_size)

    var tile_world_x = tile_pos.x * tile_size
    var tile_world_y = tile_pos.y * tile_size
    var extended_world_x = tx * tile_size - padding
    var extended_world_y = ty * tile_size - padding

    # Calculate overlap
    var overlap_start_x = max(0, extended_world_x - tile_world_x)
    var overlap_start_y = max(0, extended_world_y - tile_world_y)
    var overlap_end_x = min(tile_size, extended_world_x + extended_size - tile_world_x)
    var overlap_end_y = min(tile_size, extended_world_y + extended_size - tile_world_y)

    if debug_output:
      print("  Tile (%d, %d): overlap region (%d,%d) to (%d,%d)" % [
        tile_pos.x, tile_pos.y, overlap_start_x, overlap_start_y, overlap_end_x, overlap_end_y
      ])

    # Copy the overlapping region
    var tile_pixels = 0
    for y in range(overlap_start_y, overlap_end_y):
      for x in range(overlap_start_x, overlap_end_x):
        if x >= 0 and x < tile_size and y >= 0 and y < tile_size:
          var world_x = tile_world_x + x
          var world_y = tile_world_y + y
          var extended_x = world_x - extended_world_x
          var extended_y = world_y - extended_world_y

          if extended_x >= 0 and extended_x < extended_size and extended_y >= 0 and extended_y < extended_size:
            var color = voronoi_generator.heightmap_image.get_pixel(x, y)
            extended_image.set_pixel(extended_x, extended_y, color)
            tile_pixels += 1

    pixels_written += tile_pixels
    if debug_output:
      print("    Copied %d pixels from this tile" % tile_pixels)

  if debug_output:
    print("Total pixels written: %d / %d (%.1f%%)" % [
      pixels_written, extended_size * extended_size,
      100.0 * pixels_written / (extended_size * extended_size)
    ])

    # Check for any unwritten (black) pixels
    var black_pixels = 0
    for y in range(extended_size):
      for x in range(extended_size):
        if extended_image.get_pixel(x, y).r == 0.0:
          black_pixels += 1

    if black_pixels > 0:
      print("WARNING: %d pixels remain unwritten (black)!" % black_pixels)
    else:
      print("All pixels successfully written")

    print("--- Extended Voronoi Complete ---\n")

  return extended_image

func calculate_affected_droplets(tx: int, ty: int, tile_size: int, padding: int) -> Array:
  """Calculate which droplets could affect this tile"""
  var droplets = []

  # Calculate maximum travel distance
  var max_travel = max_lifetime * sqrt(2.0 * gravity * 1.0)  # Assume max height = 1.0

  # World bounds of extended region
  var world_min_x = tx * tile_size - padding
  var world_min_y = ty * tile_size - padding
  var world_max_x = (tx + 1) * tile_size + padding
  var world_max_y = (ty + 1) * tile_size + padding

  # Expand search region by max travel distance
  var search_min_x = world_min_x - max_travel
  var search_min_y = world_min_y - max_travel
  var search_max_x = world_max_x + max_travel
  var search_max_y = world_max_y + max_travel

  # Determine which tiles to check for droplets
  var tile_min_x = floor(search_min_x / tile_size)
  var tile_min_y = floor(search_min_y / tile_size)
  var tile_max_x = ceil(search_max_x / tile_size)
  var tile_max_y = ceil(search_max_y / tile_size)

  var rng = RandomNumberGenerator.new()

  # Check each tile in search region
  for search_ty in range(tile_min_y, tile_max_y + 1):
    for search_tx in range(tile_min_x, tile_max_x + 1):
      # Deterministic seed for this tile
      var tile_seed = hash_tile_position(search_tx, search_ty, seed_value)
      rng.seed = tile_seed

      # Generate droplets for this tile
      for i in range(droplets_per_tile):
        var rx = rng.randf()
        var ry = rng.randf()

        # World-space spawn position
        var world_spawn_x = (search_tx + rx) * tile_size
        var world_spawn_y = (search_ty + ry) * tile_size

        # Check if this droplet could affect our extended region
        if (world_spawn_x >= search_min_x and world_spawn_x <= search_max_x and
          world_spawn_y >= search_min_y and world_spawn_y <= search_max_y):

          # Convert to extended map coordinates
          var map_x = world_spawn_x - world_min_x
          var map_y = world_spawn_y - world_min_y

          # Global order hash for sorting
          var order_hash = hash_position(world_spawn_x, world_spawn_y, seed_value)

          droplets.append({
            "world_pos": Vector2(world_spawn_x, world_spawn_y),
            "map_pos": Vector2(map_x, map_y),
            "order": order_hash
          })

  # Sort by global deterministic order
  droplets.sort_custom(func(a, b): return a.order < b.order)

  return droplets

func hash_tile_position(tx: int, ty: int, seed: int) -> int:
  """Hash tile position to get deterministic seed"""
  var h = seed
  h ^= tx * 374761393
  h ^= ty * 668265263
  h ^= h >> 13
  h *= 1274126177
  h ^= h >> 16
  return h

func hash_position(x: float, y: float, seed: int) -> int:
  """Hash world position for global ordering"""
  var h = seed
  h ^= int(x * 1000.0) * 374761393
  h ^= int(y * 1000.0) * 668265263
  h ^= h >> 13
  h *= 1274126177
  h ^= h >> 16
  return h
