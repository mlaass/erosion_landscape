class_name BatchTileManager
extends Node

## Manages batch terrain generation for infinite terrain system
## Precomputes tiles in rectangular batches and detects when player nears boundaries

# Configuration
@export var batch_size: int = 16  ## Size of each batch (batch_size × batch_size tiles)
@export var edge_threshold: int = 2  ## Distance in tiles from boundary to trigger next batch
@export var max_cached_batches: int = 4  ## Maximum number of batches to keep in memory

# State
var precomputed_tiles: Dictionary = {}  ## Dict[Vector2i, BatchTileData] - all precomputed tiles
var precomputed_regions: Array[Rect2i] = []  ## List of regions that have been precomputed
var active_batch_region: Rect2i = Rect2i()  ## Current batch region player is in
var generation_in_progress: bool = false
var erosion_generator: ErosionGeneratorTiled

# Signals
signal batch_started(total_tiles: int)
signal tile_completed(tile_index: int, tile_pos: Vector2i, from_cache: bool)
signal batch_completed(region: Rect2i)

## Tile data container
class BatchTileData:
  var position: Vector2i
  var image: Image
  var texture: ImageTexture

  func _init(pos: Vector2i, img: Image):
    position = pos
    image = img
    texture = ImageTexture.create_from_image(img)

func _init(generator: ErosionGeneratorTiled):
  erosion_generator = generator

func precompute_batch(region: Rect2i, cache_manager = null) -> void:
  """Precompute all tiles in a batch region"""
  if generation_in_progress:
    push_warning("BatchTileManager: Generation already in progress")
    return

  generation_in_progress = true
  var total_tiles = region.size.x * region.size.y
  batch_started.emit(total_tiles)

  print("BatchTileManager: Starting batch generation for region ", region)
  print("  Total tiles: ", total_tiles)

  # Generate tiles in spiral order (from center outward)
  var tiles = get_spiral_tile_order(region)
  var completed = 0

  for tile_pos in tiles:
    var tile_data: BatchTileData = null
    var from_cache = false

    # Check if already precomputed (from previous batch)
    if precomputed_tiles.has(tile_pos):
      tile_data = precomputed_tiles[tile_pos]
      from_cache = true
    # Check cache manager if provided
    elif cache_manager and cache_manager.has_tile(tile_pos):
      tile_data = cache_manager.load_tile(tile_pos)
      from_cache = true
      precomputed_tiles[tile_pos] = tile_data
    else:
      # Generate new tile
      erosion_generator.tile_x = tile_pos.x
      erosion_generator.tile_y = tile_pos.y
      erosion_generator.generate_heightmap()

      tile_data = BatchTileData.new(tile_pos, erosion_generator.heightmap_image.duplicate())
      precomputed_tiles[tile_pos] = tile_data

      # Save to cache if provided
      if cache_manager:
        cache_manager.save_tile(tile_pos, tile_data.image)

    completed += 1
    tile_completed.emit(completed, tile_pos, from_cache)

    # Yield to process frame to keep UI responsive
    await get_tree().process_frame

  # Mark region as precomputed
  precomputed_regions.append(region)
  active_batch_region = region

  generation_in_progress = false
  batch_completed.emit(region)

  print("BatchTileManager: Batch generation completed")

  # Clean up old batches if we have too many
  cleanup_old_batches()

func get_spiral_tile_order(region: Rect2i) -> Array[Vector2i]:
  """Generate spiral pattern from center outward for smoother visual experience"""
  var tiles: Array[Vector2i] = []
  var center = Vector2i(
    region.position.x + region.size.x / 2,
    region.position.y + region.size.y / 2
  )

  # Collect all tiles in region
  for y in range(region.position.y, region.position.y + region.size.y):
    for x in range(region.position.x, region.position.x + region.size.x):
      tiles.append(Vector2i(x, y))

  # Sort by distance to center (closest first)
  tiles.sort_custom(func(a, b):
    var dist_a = center.distance_squared_to(a)
    var dist_b = center.distance_squared_to(b)
    return dist_a < dist_b
  )

  return tiles

func get_tile(tile_pos: Vector2i) -> ImageTexture:
  """Get tile texture if precomputed, null otherwise"""
  if precomputed_tiles.has(tile_pos):
    return precomputed_tiles[tile_pos].texture
  return null

func is_tile_precomputed(tile_pos: Vector2i) -> bool:
  """Check if tile has been precomputed"""
  return precomputed_tiles.has(tile_pos)

func check_boundary_proximity(player_tile: Vector2i) -> bool:
  """Check if player is within edge_threshold tiles of active batch boundary"""
  if active_batch_region.size.x == 0:
    return false

  # Calculate distances to each edge
  var dist_to_min_x = player_tile.x - active_batch_region.position.x
  var dist_to_max_x = (active_batch_region.position.x + active_batch_region.size.x - 1) - player_tile.x
  var dist_to_min_y = player_tile.y - active_batch_region.position.y
  var dist_to_max_y = (active_batch_region.position.y + active_batch_region.size.y - 1) - player_tile.y

  var min_dist = min(dist_to_min_x, dist_to_max_x, dist_to_min_y, dist_to_max_y)

  return min_dist <= edge_threshold

func is_region_precomputed(region: Rect2i) -> bool:
  """Check if a region has already been precomputed"""
  for precomputed_region in precomputed_regions:
    if precomputed_region == region:
      return true
  return false

func predict_next_batch(player_tile: Vector2i, player_velocity: Vector3) -> Rect2i:
  """Predict next batch region based on player position and velocity"""
  # Calculate movement direction from velocity
  var move_dir = Vector2(player_velocity.x, player_velocity.z).normalized()

  # If player is stationary or moving slowly, center batch on player
  if move_dir.length() < 0.1:
    return Rect2i(
      player_tile.x - batch_size / 2,
      player_tile.y - batch_size / 2,
      batch_size,
      batch_size
    )

  # Predict batch center based on movement direction
  var offset = move_dir * float(batch_size) * 0.5
  var next_center = player_tile + Vector2i(int(offset.x), int(offset.y))

  return Rect2i(
    next_center.x - batch_size / 2,
    next_center.y - batch_size / 2,
    batch_size,
    batch_size
  )

func cleanup_old_batches() -> void:
  """Remove oldest batches if we exceed max_cached_batches"""
  if precomputed_regions.size() <= max_cached_batches:
    return

  # Determine how many batches to remove
  var batches_to_remove = precomputed_regions.size() - max_cached_batches

  for i in range(batches_to_remove):
    var old_region = precomputed_regions[0]
    precomputed_regions.remove_at(0)

    # Remove all tiles in old region
    for y in range(old_region.position.y, old_region.position.y + old_region.size.y):
      for x in range(old_region.position.x, old_region.position.x + old_region.size.x):
        var tile_pos = Vector2i(x, y)
        # Only remove if not in any other precomputed region
        var in_other_region = false
        for region in precomputed_regions:
          if region.has_point(tile_pos):
            in_other_region = true
            break
        if not in_other_region:
          precomputed_tiles.erase(tile_pos)

    print("BatchTileManager: Cleaned up old batch ", old_region)
