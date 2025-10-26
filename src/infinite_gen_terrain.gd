@tool
extends MeshInstance3D
class_name InfiniteGenTerrain

## Infinite procedurally generated terrain using ErosionGeneratorTiled
## Dynamically generates, fades in/out, and unloads terrain tiles based on player distance

# Tile lifecycle states
enum TileState {
  PENDING,      # Queued for generation
  GENERATING,   # Currently being generated in background thread
  FADING_IN,    # Generated, transitioning to full visibility
  ACTIVE,       # Fully visible and stable
  FADING_OUT,   # Player moving away, transitioning to invisible
  UNLOADED      # Removed from memory
}

# Configuration
@export_group("Distance Settings")
@export var generation_distance: float = 1280.0:  ## Distance at which to start generating tiles (4-5 tiles)
  set(value):
    generation_distance = value
    if is_inside_tree():
      _update_terrain()
@export var unload_distance: float = 2048.0:  ## Distance at which to unload tiles (~8 tiles)
  set(value):
    unload_distance = value
    if is_inside_tree():
      _cleanup_distant_tiles()

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

@export_group("Erosion Parameters")
@export var padding_pixels: int = 128
@export var droplets_per_tile: int = 1000
@export var max_lifetime: int = 30
@export var sediment_capacity_factor: float = 8.0
@export var erode_speed: float = 0.6
@export var deposit_speed: float = 0.6
@export var evaporate_speed: float = 0.01
@export var gravity: float = 10.0
@export var inertia: float = 0.3

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

# Shared erosion generator (reused to avoid creating multiple RenderingDevices)
var erosion_generator: ErosionGeneratorTiled

# Signals for thread communication
signal tile_generated(tile_pos: Vector2i, heightmap: ImageTexture)

class TerrainTile:
  var position: Vector2i
  var heightmap: ImageTexture
  var state: TileState
  var fade_progress: float = 0.0  # 0.0 to 1.0
  var fade_start_time: float = 0.0
  var distance_to_player: float = INF
  var opacity_multiplier: float = 0.0
  var vertical_offset: float = 0.0

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
  erosion_generator.brush_radius = 3
  erosion_generator.debug_output = false
  print("InfiniteGenTerrain: Shared erosion generator created")

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
  _update_tile_fades(delta)
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
  """Update tiles based on player position"""
  if not player_character:
    return

  var player_pos = player_character.global_position
  var player_tile = Vector2i(
    floor(player_pos.x / tile_size),
    floor(player_pos.z / tile_size)
  )

  # Calculate generation radius in tiles
  var gen_radius = int(ceil(generation_distance / tile_size))

  # Check all tiles within generation distance
  for ty in range(player_tile.y - gen_radius, player_tile.y + gen_radius + 1):
    for tx in range(player_tile.x - gen_radius, player_tile.x + gen_radius + 1):
      var tile_pos = Vector2i(tx, ty)
      var tile_center = Vector3(
        tx * tile_size + tile_size * 0.5,
        0,
        ty * tile_size + tile_size * 0.5
      )
      var distance = player_pos.distance_to(tile_center)

      # Skip if too far
      if distance > generation_distance:
        continue

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

    # Get next tile to generate
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
  tile.state = TileState.FADING_IN
  tile.fade_start_time = Time.get_ticks_msec() / 1000.0
  tile.fade_progress = 0.0

  # Set initial fade values
  if enable_opacity_fade:
    tile.opacity_multiplier = 0.0
  else:
    tile.opacity_multiplier = 1.0

  if enable_vertical_morph:
    tile.vertical_offset = -vertical_morph_distance
  else:
    tile.vertical_offset = 0.0

  print("InfiniteGenTerrain: Tile ", tile_pos, " generated, starting fade-in (opacity: ", tile.opacity_multiplier, ", offset: ", tile.vertical_offset, ")")

func _update_tile_fades(delta: float):
  """Update fade animations for all tiles"""
  var current_time = Time.get_ticks_msec() / 1000.0

  for tile_pos in tiles.keys():
    var tile: TerrainTile = tiles[tile_pos]

    if tile.state == TileState.FADING_IN:
      var elapsed = current_time - tile.fade_start_time
      tile.fade_progress = clamp(elapsed / fade_in_duration, 0.0, 1.0)

      # Update fade values
      if enable_opacity_fade:
        tile.opacity_multiplier = smoothstep(0.0, 1.0, tile.fade_progress)
      else:
        tile.opacity_multiplier = 1.0

      if enable_vertical_morph:
        tile.vertical_offset = lerp(-vertical_morph_distance, 0.0, smoothstep(0.0, 1.0, tile.fade_progress))
      else:
        tile.vertical_offset = 0.0

      # Check if fade complete
      if tile.fade_progress >= 1.0:
        tile.state = TileState.ACTIVE
        tile.opacity_multiplier = 1.0
        tile.vertical_offset = 0.0

    elif tile.state == TileState.FADING_OUT:
      var elapsed = current_time - tile.fade_start_time
      tile.fade_progress = clamp(elapsed / fade_out_duration, 0.0, 1.0)

      # Update fade values (reverse of fade in)
      if enable_opacity_fade:
        tile.opacity_multiplier = smoothstep(1.0, 0.0, tile.fade_progress)
      else:
        tile.opacity_multiplier = 1.0

      if enable_vertical_morph:
        tile.vertical_offset = lerp(0.0, -vertical_morph_distance, smoothstep(0.0, 1.0, tile.fade_progress))
      else:
        tile.vertical_offset = 0.0

      # Check if fade complete
      if tile.fade_progress >= 1.0:
        tile.state = TileState.UNLOADED
        tiles.erase(tile_pos)

func _update_active_tiles():
  """Update shader uniforms with 4 closest active tiles"""
  if not player_character:
    return

  var player_pos = player_character.global_position

  # Update distances and collect active tiles
  var active_tiles: Array[TerrainTile] = []
  for tile_pos in tiles.keys():
    var tile: TerrainTile = tiles[tile_pos]

    # Only consider tiles that have heightmaps
    if tile.heightmap == null:
      continue

    # Calculate distance
    var tile_center = Vector3(
      tile_pos.x * tile_size + tile_size * 0.5,
      0,
      tile_pos.y * tile_size + tile_size * 0.5
    )
    tile.distance_to_player = player_pos.distance_to(tile_center)

    # Add to active list if in valid state
    if tile.state in [TileState.FADING_IN, TileState.ACTIVE, TileState.FADING_OUT]:
      active_tiles.append(tile)

  # Sort by distance
  active_tiles.sort_custom(func(a, b): return a.distance_to_player < b.distance_to_player)

  # Take closest 4
  var num_active = min(4, active_tiles.size())

  # Debug output (only print when active count changes)
  if num_active != last_active_count:
    print("InfiniteGenTerrain: Active tiles updated: ", num_active)
    last_active_count = num_active

  # Update shader uniforms
  for i in range(4):
    if i < num_active:
      var tile = active_tiles[i]
      terrain_material.set_shader_parameter("heightmap_" + str(i), tile.heightmap)
      # Pass tile coordinates (not world coordinates)
      # Shader will multiply by (tile_size - blend_border*2) to get world offset
      terrain_material.set_shader_parameter("tile_position_" + str(i),
        Vector2(tile.position.x, tile.position.y))
      terrain_material.set_shader_parameter("tile_opacity_" + str(i), tile.opacity_multiplier)
      terrain_material.set_shader_parameter("tile_vertical_offset_" + str(i), tile.vertical_offset)

      # Debug first tile
      if i == 0:
        print("  Tile 0: pos=", tile.position, " opacity=", tile.opacity_multiplier, " offset=", tile.vertical_offset, " state=", tile.state)
    else:
      # Clear unused slots
      terrain_material.set_shader_parameter("tile_opacity_" + str(i), 0.0)

  terrain_material.set_shader_parameter("active_tiles", num_active)

func _cleanup_distant_tiles():
  """Remove tiles that are too far from player"""
  if not player_character:
    return

  var player_pos = player_character.global_position
  var tiles_to_remove: Array[Vector2i] = []

  for tile_pos in tiles.keys():
    var tile: TerrainTile = tiles[tile_pos]

    var tile_center = Vector3(
      tile_pos.x * tile_size + tile_size * 0.5,
      0,
      tile_pos.y * tile_size + tile_size * 0.5
    )
    var distance = player_pos.distance_to(tile_center)

    # Start fading out if beyond generation distance but not yet fading
    if distance > generation_distance and tile.state == TileState.ACTIVE:
      tile.state = TileState.FADING_OUT
      tile.fade_start_time = Time.get_ticks_msec() / 1000.0
      tile.fade_progress = 0.0

    # Immediately unload if way too far (beyond unload distance)
    if distance > unload_distance:
      if tile.state != TileState.UNLOADED:
        tiles_to_remove.append(tile_pos)

  # Remove distant tiles
  for tile_pos in tiles_to_remove:
    tiles.erase(tile_pos)

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
  var fading_in_count = 0
  var active_count = 0
  var fading_out_count = 0

  var loaded_tiles: Array[Vector2i] = []
  for tile_pos in tiles.keys():
    var tile: TerrainTile = tiles[tile_pos]
    loaded_tiles.append(tile_pos)
    match tile.state:
      TileState.PENDING:
        pending_count += 1
      TileState.GENERATING:
        generating_count += 1
      TileState.FADING_IN:
        fading_in_count += 1
      TileState.ACTIVE:
        active_count += 1
      TileState.FADING_OUT:
        fading_out_count += 1

  # Get queue info
  queue_mutex.lock()
  var queue_size = generation_queue.size()
  var next_tiles = generation_queue.slice(0, min(5, queue_size))
  queue_mutex.unlock()

  # Build debug text
  var debug_text = ""
  debug_text += "=== TERRAIN DEBUG ===\n"
  debug_text += "Player World: (%.1f, %.1f, %.1f)\n" % [player_pos.x, player_pos.y, player_pos.z]
  debug_text += "Player Tile: (%d, %d)\n" % [player_tile.x, player_tile.y]
  debug_text += "\n"
  debug_text += "Total Tiles: %d\n" % tiles.size()
  debug_text += "  Pending: %d\n" % pending_count
  debug_text += "  Generating: %d\n" % generating_count
  debug_text += "  Fading In: %d\n" % fading_in_count
  debug_text += "  Active: %d\n" % active_count
  debug_text += "  Fading Out: %d\n" % fading_out_count
  debug_text += "\n"
  debug_text += "Queue Size: %d\n" % queue_size
  if next_tiles.size() > 0:
    debug_text += "Next in Queue:\n"
    for tile_pos in next_tiles:
      debug_text += "  (%d, %d)\n" % [tile_pos.x, tile_pos.y]

  debug_label.text = debug_text
