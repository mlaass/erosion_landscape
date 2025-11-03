@tool
extends MeshInstance3D
class_name InfiniteGenTerrain

## Infinite procedurally generated terrain using ErosionGeneratorTiled
## Dynamically generates, fades in/out, and unloads terrain tiles based on player distance

# Tile lifecycle states
enum TileState {
  PENDING,      # Queued for generation
  GENERATING,   # Currently being generated in background thread
  LOADED        # In memory, ready to render
}

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

@export_group("References")
@export var player_character: Node3D  ## Player to track for tile generation
@export var debug_label: Label  ## Optional debug display label

# Internal state
var terrain_material: ShaderMaterial
var tiles: Dictionary = {}  # Key: Vector2i, Value: TerrainTile
var active_tile_slots: Array[TerrainTile] = []  # 4 closest tiles for shader
var last_active_count: int = -1  # For debug output tracking

# Threading
var generation_queue: Array[Vector2i] = []
var generation_queue_set: Dictionary = {}  # For O(1) lookup
var queue_mutex: Mutex
var queue_semaphore: Semaphore
var generation_thread: Thread
var thread_should_exit: bool = false
var currently_generating: int = 0
var cached_player_tile: Vector2i = Vector2i(0, 0)  # Thread-safe cache of player tile position

# Shared erosion generator (reused to avoid creating multiple RenderingDevices)
var erosion_generator: ErosionGeneratorTiled

# Signals for thread communication
signal tile_generated(tile_pos: Vector2i, heightmap: ImageTexture)

class TerrainTile:
  var position: Vector2i
  var heightmap: ImageTexture
  var state: TileState
  var distance_to_player: float = INF

  func _init(pos: Vector2i):
    position = pos
    state = TileState.PENDING
    heightmap = null

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

  # Initialize threading
  queue_mutex = Mutex.new()
  queue_semaphore = Semaphore.new()
  generation_thread = Thread.new()

  # Create shared erosion generator (reused for all tiles to avoid RenderingDevice spam)
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

  # Connect signal
  tile_generated.connect(_on_tile_generated)

  # Start worker thread
  generation_thread.start(_worker_thread_loop)
  print("InfiniteGenTerrain: Worker thread started")

  # Initialize terrain around player
  if player_character:
    print("InfiniteGenTerrain: Player found at ", player_character.global_position)
    _update_terrain()
  else:
    push_warning("InfiniteGenTerrain: No player character assigned!")

func _exit_tree():
  if Engine.is_editor_hint():
    return

  # Signal thread to exit
  thread_should_exit = true
  queue_semaphore.post()  # Wake up thread if waiting

  # Wait for thread to finish
  if generation_thread.is_alive():
    generation_thread.wait_to_finish()

func _physics_process(delta):
  if Engine.is_editor_hint() or not player_character:
    return

  # Move mesh to follow player (like clipmap system)
  _update_mesh_position()

  _update_terrain()
  _update_active_tiles()
  _cleanup_distant_tiles()
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

func _update_terrain():
  """Maintain 25-tile window (5x5 grid around player)"""
  if not player_character:
    return

  var player_pos = player_character.global_position
  var player_tile = Vector2i(
    floor(player_pos.x / tile_size),
    floor(player_pos.z / tile_size)
  )

  # Update cached player tile for worker thread (atomic write, safe without mutex)
  cached_player_tile = player_tile

  # Generate 5x5 grid around player
  for ty in range(player_tile.y - 2, player_tile.y + 3):
    for tx in range(player_tile.x - 2, player_tile.x + 3):
      var tile_pos = Vector2i(tx, ty)

      # Create tile if doesn't exist
      if not tiles.has(tile_pos):
        var new_tile = TerrainTile.new(tile_pos)
        tiles[tile_pos] = new_tile
        _queue_tile_generation(tile_pos)

func _queue_tile_generation(tile_pos: Vector2i):
  """Add tile to generation queue if not already queued"""
  queue_mutex.lock()

  # Check if already in queue or generating
  if generation_queue_set.has(tile_pos):
    queue_mutex.unlock()
    return

  if tiles[tile_pos].state != TileState.PENDING:
    queue_mutex.unlock()
    return

  # Add to queue
  generation_queue.append(tile_pos)
  generation_queue_set[tile_pos] = true
  print("InfiniteGenTerrain: Queued tile ", tile_pos, " for generation")

  queue_mutex.unlock()

  # Wake up worker thread
  queue_semaphore.post()

func _worker_thread_loop():
  """Background thread loop for tile generation"""
  while not thread_should_exit:
    # Wait for work
    queue_semaphore.wait()

    if thread_should_exit:
      break

    # Check if we can generate more tiles
    queue_mutex.lock()
    if currently_generating >= max_concurrent_generations or generation_queue.is_empty():
      queue_mutex.unlock()
      continue

    # Sort queue by distance to player (closest first) and remove tiles outside 5x5 window
    # Use cached player tile (thread-safe, updated by main thread)
    var player_tile = cached_player_tile

    # Remove queued tiles outside 5x5 window
    var i = 0
    while i < generation_queue.size():
      var queued_tile_pos = generation_queue[i]
      # Check if tile is in 5x5 grid around player
      if abs(queued_tile_pos.x - player_tile.x) > 2 or abs(queued_tile_pos.y - player_tile.y) > 2:
        generation_queue.remove_at(i)
        generation_queue_set.erase(queued_tile_pos)
        print("Worker thread: Removed ", queued_tile_pos, " from queue (outside 5x5 window)")
      else:
        i += 1

    # Sort remaining queue by distance to player tile (Manhattan distance for simplicity)
    generation_queue.sort_custom(func(a, b):
      var dist_a = abs(a.x - player_tile.x) + abs(a.y - player_tile.y)
      var dist_b = abs(b.x - player_tile.x) + abs(b.y - player_tile.y)
      return dist_a < dist_b
    )

    # Check again after cleanup
    if generation_queue.is_empty():
      queue_mutex.unlock()
      continue

    # Get next tile to generate (closest to player)
    var tile_pos = generation_queue.pop_front()
    generation_queue_set.erase(tile_pos)
    currently_generating += 1
    queue_mutex.unlock()

    print("Worker thread: Starting generation of tile ", tile_pos)

    # Generate tile
    var heightmap = _generate_tile_heightmap(tile_pos)

    print("Worker thread: Completed generation of tile ", tile_pos)

    # Signal main thread
    call_deferred("emit_signal", "tile_generated", tile_pos, heightmap)

    # Decrement counter
    queue_mutex.lock()
    currently_generating -= 1
    queue_mutex.unlock()

func _generate_tile_heightmap(tile_pos: Vector2i) -> ImageTexture:
  """Generate heightmap for a tile using shared ErosionGeneratorTiled"""
  # Just set the tile position and generate (reuses same RenderingDevice)
  erosion_generator.tile_x = tile_pos.x
  erosion_generator.tile_y = tile_pos.y
  erosion_generator.generate_heightmap()

  return erosion_generator.heightmap_texture

func _on_tile_generated(tile_pos: Vector2i, heightmap: ImageTexture):
  """Called when a tile finishes generating"""
  if not tiles.has(tile_pos):
    print("InfiniteGenTerrain: Warning - received tile ", tile_pos, " but it doesn't exist in tiles dict")
    return

  var tile = tiles[tile_pos]
  tile.heightmap = heightmap
  tile.state = TileState.LOADED

  print("InfiniteGenTerrain: Tile ", tile_pos, " loaded and ready to render")

func _update_active_tiles():
  """Update shader uniforms with 3x3 grid (9 tiles) around player"""
  if not player_character:
    return

  var player_pos = player_character.global_position
  var player_tile = Vector2i(
    floor(player_pos.x / tile_size),
    floor(player_pos.z / tile_size)
  )

  # Collect tiles in 3x3 grid that are loaded
  var rendering_tiles: Array[TerrainTile] = []
  for ty in range(player_tile.y - 1, player_tile.y + 2):
    for tx in range(player_tile.x - 1, player_tile.x + 2):
      var tile_pos = Vector2i(tx, ty)
      if tiles.has(tile_pos):
        var tile = tiles[tile_pos]
        if tile.heightmap != null and tile.state == TileState.LOADED:
          rendering_tiles.append(tile)

  # Store for debug display
  active_tile_slots = rendering_tiles

  # Update shader uniforms (up to 9 tiles)
  var num_to_render = min(9, rendering_tiles.size())
  for i in range(9):
    if i < num_to_render:
      var tile = rendering_tiles[i]
      terrain_material.set_shader_parameter("heightmap_" + str(i), tile.heightmap)
      terrain_material.set_shader_parameter("tile_position_" + str(i),
        Vector2(tile.position.x, tile.position.y))
    else:
      # Clear unused slots
      terrain_material.set_shader_parameter("heightmap_" + str(i), null)

  terrain_material.set_shader_parameter("active_tiles", num_to_render)

func _cleanup_distant_tiles():
  """Remove tiles outside 5x5 window"""
  if not player_character:
    return

  var player_pos = player_character.global_position
  var player_tile = Vector2i(
    floor(player_pos.x / tile_size),
    floor(player_pos.z / tile_size)
  )

  var tiles_to_remove: Array[Vector2i] = []

  for tile_pos in tiles.keys():
    # Check if tile is outside 5x5 grid around player
    if abs(tile_pos.x - player_tile.x) > 2 or abs(tile_pos.y - player_tile.y) > 2:
      tiles_to_remove.append(tile_pos)

  # Remove distant tiles and free memory
  for tile_pos in tiles_to_remove:
    var tile: TerrainTile = tiles[tile_pos]
    # Free heightmap texture to release GPU memory
    if tile.heightmap:
      tile.heightmap = null
    tiles.erase(tile_pos)
    print("InfiniteGenTerrain: Unloaded tile ", tile_pos, " (outside 5x5 window)")

func _update_debug_display():
  """Update debug HUD with terrain system information"""
  if not debug_label:
    return

  if not player_character:
    return

  var player_pos = player_character.global_position
  var player_tile = Vector2i(
    floor(player_pos.x / tile_size),
    floor(player_pos.z / tile_size)
  )

  # Count tiles by state
  var pending_count = 0
  var generating_count = 0
  var loaded_count = 0

  var loaded_tiles: Array[Vector2i] = []
  for tile_pos in tiles.keys():
    var tile: TerrainTile = tiles[tile_pos]
    loaded_tiles.append(tile_pos)
    match tile.state:
      TileState.PENDING:
        pending_count += 1
      TileState.GENERATING:
        generating_count += 1
      TileState.LOADED:
        loaded_count += 1

  # Get currently rendering tiles (from active_tile_slots)
  var rendering_tiles: Array[String] = []
  for i in range(min(9, active_tile_slots.size())):
    var tile = active_tile_slots[i]
    rendering_tiles.append("  [%d] (%d, %d)" % [
      i, tile.position.x, tile.position.y
    ])

  # Get queue info
  queue_mutex.lock()
  var queue_size = generation_queue.size()
  var next_tiles = generation_queue.slice(0, min(5, queue_size))
  queue_mutex.unlock()

  # Get memory info
  var memory_static = OS.get_static_memory_usage() / 1024.0 / 1024.0  # MB
  var memory_peak = OS.get_static_memory_peak_usage() / 1024.0 / 1024.0  # MB

  # Build debug text
  var debug_text = ""
  debug_text += "=== TERRAIN DEBUG ===\n"
  debug_text += "Memory: %.1f MB (peak: %.1f MB)\n" % [memory_static, memory_peak]
  debug_text += "\n"
  debug_text += "Player World: (%.1f, %.1f, %.1f)\n" % [player_pos.x, player_pos.y, player_pos.z]
  debug_text += "Player Tile: (%d, %d)\n" % [player_tile.x, player_tile.y]
  debug_text += "\n"
  debug_text += "RENDERING NOW (shader slots):\n"
  if rendering_tiles.size() > 0:
    for tile_info in rendering_tiles:
      debug_text += tile_info + "\n"
  else:
    debug_text += "  (none)\n"
  debug_text += "\n"
  debug_text += "Tiles in Memory: %d (max 25)\n" % tiles.size()
  debug_text += "  Pending: %d\n" % pending_count
  debug_text += "  Generating: %d\n" % generating_count
  debug_text += "  Loaded: %d\n" % loaded_count
  debug_text += "Rendering (3x3 grid): %d (max 9)\n" % active_tile_slots.size()
  debug_text += "\n"
  debug_text += "Queue Size: %d\n" % queue_size
  if next_tiles.size() > 0:
    debug_text += "Next in Queue:\n"
    for tile_pos in next_tiles:
      var tile_center = Vector3(
        tile_pos.x * tile_size + tile_size * 0.5,
        0,
        tile_pos.y * tile_size + tile_size * 0.5
      )
      var dist = player_pos.distance_to(tile_center)
      debug_text += "  (%d, %d) - dist: %.0f\n" % [tile_pos.x, tile_pos.y, dist]

  debug_label.text = debug_text
