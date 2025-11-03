class_name TileCacheManager
extends Node

## Manages persistent disk caching of terrain tiles
## Saves tiles as .exr files organized by seed in user save directory

var cache_base_path: String = "user://terrain_cache"
var current_seed: int = 0
var cache_enabled: bool = true

func _init(seed: int):
  current_seed = seed

func get_cache_dir() -> String:
  """Get the cache directory path for current seed"""
  return "%s/seed_%d" % [cache_base_path, current_seed]

func ensure_cache_dir() -> bool:
  """Create cache directory if it doesn't exist"""
  var dir = DirAccess.open("user://")
  if not dir:
    push_error("TileCacheManager: Failed to open user:// directory")
    return false

  # Create base cache directory
  if not dir.dir_exists("terrain_cache"):
    var err = dir.make_dir("terrain_cache")
    if err != OK:
      push_error("TileCacheManager: Failed to create terrain_cache directory: ", err)
      return false

  # Create seed-specific directory
  var seed_dir = "terrain_cache/seed_%d" % current_seed
  if not dir.dir_exists(seed_dir):
    var err = dir.make_dir(seed_dir)
    if err != OK:
      push_error("TileCacheManager: Failed to create seed directory: ", err)
      return false

  return true

func get_tile_path(tile_pos: Vector2i) -> String:
  """Get the file path for a tile"""
  return "%s/tile_%d_%d.exr" % [get_cache_dir(), tile_pos.x, tile_pos.y]

func has_tile(tile_pos: Vector2i) -> bool:
  """Check if a tile exists in cache"""
  if not cache_enabled:
    return false

  var path = get_tile_path(tile_pos)
  return FileAccess.file_exists(path)

func save_tile(tile_pos: Vector2i, image: Image) -> bool:
  """Save a tile to disk as EXR"""
  if not cache_enabled:
    return false

  if not ensure_cache_dir():
    return false

  var path = get_tile_path(tile_pos)
  var err = image.save_exr(path)

  if err != OK:
    push_error("TileCacheManager: Failed to save tile (%d, %d): %d" % [tile_pos.x, tile_pos.y, err])
    return false

  return true

func load_tile(tile_pos: Vector2i) -> Image:
  """Load a tile from disk"""
  if not cache_enabled:
    return null

  var path = get_tile_path(tile_pos)
  if not FileAccess.file_exists(path):
    return null

  var image = Image.new()
  var err = image.load(path)

  if err != OK:
    push_error("TileCacheManager: Failed to load tile (%d, %d): %d" % [tile_pos.x, tile_pos.y, err])
    return null

  return image

func get_cache_stats() -> Dictionary:
  """Get statistics about the cache"""
  var stats = {
    "seed": current_seed,
    "cache_dir": get_cache_dir(),
    "total_tiles": 0,
    "total_size_mb": 0.0
  }

  var dir = DirAccess.open(get_cache_dir())
  if not dir:
    return stats

  dir.list_dir_begin()
  var file_name = dir.get_next()

  while file_name != "":
    if not dir.current_is_dir() and file_name.ends_with(".exr"):
      stats["total_tiles"] += 1
      # Approximate size (EXR files are typically 1-2 KB for heightmaps)
      var file_path = get_cache_dir() + "/" + file_name
      var file = FileAccess.open(file_path, FileAccess.READ)
      if file:
        stats["total_size_mb"] += file.get_length() / 1024.0 / 1024.0
        file.close()

    file_name = dir.get_next()

  dir.list_dir_end()
  return stats

func clear_cache() -> void:
  """Delete all cached tiles for current seed"""
  var dir = DirAccess.open(get_cache_dir())
  if not dir:
    return

  dir.list_dir_begin()
  var file_name = dir.get_next()
  var deleted_count = 0

  while file_name != "":
    if not dir.current_is_dir() and file_name.ends_with(".exr"):
      dir.remove(file_name)
      deleted_count += 1
    file_name = dir.get_next()

  dir.list_dir_end()
  print("TileCacheManager: Cleared %d tiles from cache" % deleted_count)

func get_cache_size_mb() -> float:
  """Get total cache size in megabytes"""
  var stats = get_cache_stats()
  return stats["total_size_mb"]
