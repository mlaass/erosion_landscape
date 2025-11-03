@tool
extends MeshInstance3D
class_name InfiniteGenTerrain

## Infinite procedurally generated terrain using ErosionGeneratorTiled
## Uses batch precomputation with loading overlay for smooth terrain generation

# Configuration
@export_group("Fade Settings")
@export var fade_in_duration: float = 1.5  ## Duration of fade-in animation in seconds
@export var fade_out_duration: float = 1.0  ## Duration of fade-out animation in seconds
@export var enable_opacity_fade: bool = true  ## Enable alpha/opacity fade effect
@export var enable_vertical_morph: bool = true  ## Enable vertical morphing (rising/sinking)
@export var vertical_morph_distance: float = 50.0  ## How far underground/aboveground to morph

@export_group("Generation Settings")
@export var max_concurrent_generations: int = 1  ## Maximum tiles generating simultaneously (must be 1 for shared generator)
@export var global_seed: int = 12345  ## Seed for terrain generation
@export var tile_size: int = 256  ## Size of each terrain tile in pixels

@export_group("Global Noise Layer")
@export var enable_global_noise: bool = true  ## Enable/disable global noise layer
@export var global_noise_intensity: float = 0.3  ## Intensity/opacity (0.0 = none, 1.0 = full)
@export var global_noise_frequency: float = 0.015  ## Frequency (~26 tile wavelength)
@export var global_noise_octaves: int = 2  ## Number of octaves for detail
@export var global_noise_lacunarity: float = 2.0  ## Frequency multiplier per octave
@export var global_noise_persistence: float = 0.5  ## Amplitude multiplier per octave
@export var global_noise_seed: int = 0  ## Seed for global noise

@export_group("Voronoi Layer")
@export var enable_voronoi: bool = true  ## Enable/disable Voronoi cell layer
@export var voronoi_intensity: float = 1.0  ## Intensity/opacity (0.0 = none, 1.0 = full)
@export var voronoi_num_points: int = 8  ## Number of Voronoi points per tile
@export var voronoi_height_falloff: float = 2.0  ## Height falloff exponent
@export var voronoi_ridge_multiplier: float = 0.0  ## Ridge effect strength

@export_group("Erosion Layer")
@export var enable_erosion: bool = true  ## Enable/disable erosion simulation
@export var erosion_intensity: float = 1.0  ## Intensity/opacity (0.0 = none, 1.0 = full erosion)
@export var padding_pixels: int = 128  ## Padding pixels for seamless erosion
@export var droplets_per_tile: int = 1000  ## Number of droplets to simulate
@export var max_lifetime: int = 30  ## Maximum droplet lifetime
@export var sediment_capacity_factor: float = 8.0  ## Sediment capacity multiplier
@export var erode_speed: float = 0.6  ## Erosion speed
@export var deposit_speed: float = 0.6  ## Sediment deposition speed
@export var evaporate_speed: float = 0.01  ## Water evaporation speed
@export var gravity: float = 10.0  ## Gravity strength
@export var inertia: float = 0.3  ## Droplet momentum/inertia

@export_group("Texture-Based Erosion (Experimental)")
@export var use_texture_erosion: bool = false  ## Toggle between brush and texture mode
@export var erosion_texture_path: String = ""  ## Path to erosion intensity texture (grayscale)
@export var sediment_texture_path: String = ""  ## Path to sediment deposition texture (grayscale)
@export var erosion_texture_scale: float = 32.0  ## Erosion texture size in pixels
@export var sediment_texture_scale: float = 32.0  ## Sediment texture size in pixels
@export var rotate_textures_with_flow: bool = true  ## Rotate textures to align with flow direction

@export_group("Batch Generation")
@export var initial_spawn_tile: Vector2i = Vector2i(0, 0)  ## Initial tile position to center first batch on
@export var batch_size: int = 16  ## Size of each batch (batch_size × batch_size tiles)
@export var edge_threshold: int = 0  ## Distance in tiles from boundary to trigger next batch (0 = only when leaving batch)
@export var max_cached_batches: int = 4  ## Maximum number of batches to keep in memory

@export_group("Disk Cache")
@export var enable_disk_cache: bool = true  ## Enable persistent disk caching of tiles (organized by seed)
@export var show_cache_stats: bool = false  ## Show cache statistics in debug display

@export_group("References")
@export var player_character: Node3D  ## Player to track for tile generation
@export var debug_label: Label  ## Optional debug display label

# Internal state
var terrain_material: ShaderMaterial
var current_shader_tiles: Array[Vector2i] = []  # Track which tiles are currently in shader (avoid redundant uploads)

# Batch system
var batch_manager: BatchTileManager
var loading_overlay: LoadingOverlay
var erosion_generator: ErosionGeneratorTiled
var cache_manager: TileCacheManager

func _ready():
  if Engine.is_editor_hint():
    return

  print("InfiniteGenTerrain: Initializing...")

  # Initialize material (try override first, then active material)
  terrain_material = get_surface_override_material(0)
  if not terrain_material:
    terrain_material = get_active_material(0)

  if not terrain_material:
    push_error("InfiniteGenTerrain: No material assigned to mesh")
    return

  print("InfiniteGenTerrain: Material found: ", terrain_material)

  # Ensure material has transparency enabled
  if terrain_material is ShaderMaterial:
    # Material transparency is handled by the shader's render_mode
    var shader_code = terrain_material.shader.get_code() if terrain_material.shader else ""
    if "ALPHA" in shader_code:
      print("InfiniteGenTerrain: Shader uses ALPHA, transparency should work")

  # Create shared erosion generator
  erosion_generator = ErosionGeneratorTiled.new()
  erosion_generator.map_size = tile_size
  erosion_generator.seed_value = global_seed
  erosion_generator.padding_pixels = padding_pixels
  erosion_generator.brush_radius = 3
  erosion_generator.debug_output = false

  # === GLOBAL NOISE LAYER ===
  erosion_generator.voronoi_generator.enable_global_noise = enable_global_noise
  erosion_generator.voronoi_generator.global_noise_intensity = global_noise_intensity
  erosion_generator.voronoi_generator.global_noise_frequency = global_noise_frequency
  erosion_generator.voronoi_generator.global_noise_octaves = global_noise_octaves
  erosion_generator.voronoi_generator.global_noise_lacunarity = global_noise_lacunarity
  erosion_generator.voronoi_generator.global_noise_persistence = global_noise_persistence
  erosion_generator.voronoi_generator.global_noise_seed = global_noise_seed

  # === VORONOI LAYER ===
  erosion_generator.voronoi_generator.enable_voronoi = enable_voronoi
  erosion_generator.voronoi_generator.voronoi_intensity = voronoi_intensity
  erosion_generator.voronoi_generator.num_points = voronoi_num_points
  erosion_generator.voronoi_generator.height_falloff = voronoi_height_falloff
  erosion_generator.voronoi_generator.ridge_multiplier = voronoi_ridge_multiplier
  erosion_generator.voronoi_generator.min_height = 0.0
  erosion_generator.voronoi_generator.max_height = 1.0
  erosion_generator.voronoi_generator.amplitude = 1.0
  erosion_generator.voronoi_generator.scaling_type = VoronoiGenerator.ScalingType.POWER

  # === EROSION LAYER ===
  erosion_generator.enable_erosion = enable_erosion
  erosion_generator.erosion_intensity = erosion_intensity
  erosion_generator.droplets_per_tile = droplets_per_tile
  erosion_generator.max_lifetime = max_lifetime
  erosion_generator.sediment_capacity_factor = sediment_capacity_factor
  erosion_generator.min_sediment_capacity = 0.01
  erosion_generator.deposit_speed = deposit_speed
  erosion_generator.erode_speed = erode_speed
  erosion_generator.evaporate_speed = evaporate_speed
  erosion_generator.gravity = gravity
  erosion_generator.start_speed = 1.0
  erosion_generator.start_water = 1.0
  erosion_generator.inertia = inertia

  # === TEXTURE-BASED EROSION ===
  erosion_generator.use_texture_erosion = use_texture_erosion
  erosion_generator.erosion_texture_path = erosion_texture_path
  erosion_generator.sediment_texture_path = sediment_texture_path
  erosion_generator.erosion_texture_scale = erosion_texture_scale
  erosion_generator.sediment_texture_scale = sediment_texture_scale
  erosion_generator.rotate_textures_with_flow = rotate_textures_with_flow

  # Load texture if texture mode enabled
  if use_texture_erosion:
    var loaded = erosion_generator.load_erosion_textures()
    if not loaded:
      print("Warning: Failed to load erosion textures, falling back to classic brush mode")
      erosion_generator.use_texture_erosion = false

  var mode_str = "texture mode" if erosion_generator.use_texture_erosion else "brush mode"
  print("InfiniteGenTerrain: Shared erosion generator created with 3 layers (erosion: %s)" % mode_str)

  # Create disk cache manager
  if enable_disk_cache:
    cache_manager = TileCacheManager.new(global_seed)
    cache_manager.cache_enabled = true
    var cache_stats = cache_manager.get_cache_stats()
    print("InfiniteGenTerrain: Disk cache enabled for seed %d (%d cached tiles, %.2f MB)" % [global_seed, cache_stats["total_tiles"], cache_stats["total_size_mb"]])
  else:
    print("InfiniteGenTerrain: Disk cache disabled")

  # Create batch manager
  batch_manager = BatchTileManager.new(erosion_generator)
  batch_manager.batch_size = batch_size
  batch_manager.edge_threshold = edge_threshold
  batch_manager.max_cached_batches = max_cached_batches
  add_child(batch_manager)
  print("InfiniteGenTerrain: BatchTileManager created (batch_size: %d, edge_threshold: %d, max_cached: %d)" % [batch_size, edge_threshold, max_cached_batches])

  # Create loading overlay
  var overlay_scene = load("res://src/loading_overlay.tscn")
  loading_overlay = overlay_scene.instantiate()
  add_child(loading_overlay)
  print("InfiniteGenTerrain: LoadingOverlay created")

  # Connect batch manager signals
  batch_manager.batch_started.connect(_on_batch_started)
  batch_manager.tile_completed.connect(_on_tile_completed)
  batch_manager.batch_completed.connect(_on_batch_completed)

  # Precompute initial batch
  var initial_region = Rect2i(
    initial_spawn_tile.x - batch_size / 2,
    initial_spawn_tile.y - batch_size / 2,
    batch_size,
    batch_size
  )
  print("InfiniteGenTerrain: Starting initial batch generation for region ", initial_region)
  batch_manager.precompute_batch(initial_region, cache_manager)

func _exit_tree():
  if Engine.is_editor_hint():
    return

  # Cleanup (batch manager will be freed automatically as child node)

func _physics_process(delta):
  if Engine.is_editor_hint() or not player_character:
    return

  # Skip terrain updates during batch generation
  if batch_manager and batch_manager.generation_in_progress:
    return

  # Move mesh to follow player (like clipmap system)
  _update_mesh_position()

  # Update active tiles from batch
  _update_active_tiles_from_batch()

  # Check if player is near boundary
  var player_pos = player_character.global_position
  var player_tile = Vector2i(
    floor(player_pos.x / tile_size),
    floor(player_pos.z / tile_size)
  )

  if batch_manager.check_boundary_proximity(player_tile):
    var player_velocity = player_character.velocity if player_character.has_method("get_velocity") else Vector3.ZERO
    var next_region = batch_manager.predict_next_batch(player_tile, player_velocity)

    # Only generate if this region hasn't been precomputed yet
    if not batch_manager.is_region_precomputed(next_region):
      print("InfiniteGenTerrain: Player near boundary at ", player_tile, " - generating next batch ", next_region)
      if player_character.has_method("set"):
        player_character.paused = true  # Pause player movement
      batch_manager.precompute_batch(next_region, cache_manager)

  _update_debug_display()

func _update_mesh_position():
  """Move the mesh to follow the player for optimal coverage"""
  if not player_character:
    return

  # Snap to grid for stability (8-unit increments)
  var player_pos = player_character.global_position
  var snapped_pos = (player_pos * 0.125).round() * 8.0

  # Keep original Y position, only follow in XZ plane
  var target_pos = Vector3(snapped_pos.x, global_position.y, snapped_pos.z)
  global_position = target_pos

## Batch generation signal handlers

func _on_batch_started(total_tiles: int):
  """Called when batch generation starts"""
  print("InfiniteGenTerrain: Batch generation started (%d tiles)" % total_tiles)
  loading_overlay.show_loading(total_tiles)

func _on_tile_completed(tile_index: int, tile_pos: Vector2i, from_cache: bool):
  """Called when each tile completes"""
  var total_tiles = batch_size * batch_size
  loading_overlay.update_progress(tile_index, total_tiles, tile_pos, from_cache)

func _on_batch_completed(region: Rect2i):
  """Called when batch generation completes"""
  print("InfiniteGenTerrain: Batch generation completed for region ", region)
  loading_overlay.hide_loading()

  # Unpause player if paused
  if player_character and player_character.has_method("set"):
    player_character.paused = false

func _update_active_tiles_from_batch():
  """Update shader uniforms with 3x3 grid (9 tiles) around player from batch manager"""
  if not player_character:
    return

  var player_pos = player_character.global_position
  var player_tile = Vector2i(
    floor(player_pos.x / tile_size),
    floor(player_pos.z / tile_size)
  )

  # Collect tiles in 3x3 grid from batch manager
  var rendering_tiles: Array[ImageTexture] = []
  var new_shader_tiles: Array[Vector2i] = []

  for ty in range(player_tile.y - 1, player_tile.y + 2):
    for tx in range(player_tile.x - 1, player_tile.x + 2):
      var tile_pos = Vector2i(tx, ty)
      var tile_texture = batch_manager.get_tile(tile_pos)

      if tile_texture:
        rendering_tiles.append(tile_texture)
        new_shader_tiles.append(tile_pos)

  # Only update shader if tiles changed (avoid GPU uploads every frame)
  var tiles_changed = false
  if new_shader_tiles.size() != current_shader_tiles.size():
    tiles_changed = true
  else:
    for i in range(new_shader_tiles.size()):
      if new_shader_tiles[i] != current_shader_tiles[i]:
        tiles_changed = true
        break

  if not tiles_changed:
    return  # No change, skip shader parameter updates

  # Tiles changed - update shader parameters
  current_shader_tiles = new_shader_tiles.duplicate()

  var num_to_render = min(9, rendering_tiles.size())
  for i in range(9):
    if i < num_to_render:
      terrain_material.set_shader_parameter("heightmap_" + str(i), rendering_tiles[i])
      terrain_material.set_shader_parameter("tile_position_" + str(i),
        Vector2(new_shader_tiles[i].x, new_shader_tiles[i].y))
    else:
      # Clear unused slots
      terrain_material.set_shader_parameter("heightmap_" + str(i), null)

  terrain_material.set_shader_parameter("active_tiles", num_to_render)

func _update_debug_display():
  """Update debug HUD with batch terrain system information"""
  if not debug_label:
    return

  if not player_character:
    return

  var player_pos = player_character.global_position
  var player_tile = Vector2i(
    floor(player_pos.x / tile_size),
    floor(player_pos.z / tile_size)
  )

  # Get memory info
  var memory_static = OS.get_static_memory_usage() / 1024.0 / 1024.0  # MB
  var memory_peak = OS.get_static_memory_peak_usage() / 1024.0 / 1024.0  # MB

  # Get batch info
  var total_precomputed = batch_manager.precomputed_tiles.size()
  var num_batches = batch_manager.precomputed_regions.size()
  var is_generating = "YES" if batch_manager.generation_in_progress else "NO"

  # Get active region info
  var active_region = batch_manager.active_batch_region
  var dist_to_edge = "N/A"
  if active_region.size.x > 0:
    var dist_to_min_x = player_tile.x - active_region.position.x
    var dist_to_max_x = (active_region.position.x + active_region.size.x - 1) - player_tile.x
    var dist_to_min_y = player_tile.y - active_region.position.y
    var dist_to_max_y = (active_region.position.y + active_region.size.y - 1) - player_tile.y
    var min_dist = min(dist_to_min_x, dist_to_max_x, dist_to_min_y, dist_to_max_y)
    dist_to_edge = str(min_dist)

  # Build debug text
  var debug_text = ""
  debug_text += "=== BATCH TERRAIN DEBUG ===\n"
  debug_text += "Memory: %.1f MB (peak: %.1f MB)\n" % [memory_static, memory_peak]
  debug_text += "\n"
  debug_text += "Player World: (%.1f, %.1f, %.1f)\n" % [player_pos.x, player_pos.y, player_pos.z]
  debug_text += "Player Tile: (%d, %d)\n" % [player_tile.x, player_tile.y]
  debug_text += "\n"
  debug_text += "Generating: %s\n" % is_generating
  debug_text += "Batch Size: %d×%d (%d tiles)\n" % [batch_size, batch_size, batch_size * batch_size]
  debug_text += "Batches Loaded: %d\n" % num_batches
  debug_text += "Tiles Precomputed: %d\n" % total_precomputed
  debug_text += "Distance to Edge: %s tiles\n" % dist_to_edge
  debug_text += "\n"
  debug_text += "Active Batch Region:\n"
  if active_region.size.x > 0:
    debug_text += "  Position: (%d, %d)\n" % [active_region.position.x, active_region.position.y]
    debug_text += "  Size: %d×%d\n" % [active_region.size.x, active_region.size.y]
  else:
    debug_text += "  (none)\n"
  debug_text += "\n"
  debug_text += "Rendering (3x3 grid): %d (max 9)\n" % current_shader_tiles.size()

  debug_label.text = debug_text
