class_name TerrainManager
extends Node

# Configuration
const TILE_SIZE := 256  # Size of each terrain tile in pixels
const BLEND_BORDER := 32  # Width of the blending border

@onready var terrain_mesh: MeshInstance3D = $TerrainMesh
var terrain_material: ShaderMaterial

# Store generated tiles
var tiles: Dictionary = {}  # Key: Vector2i, Value: TerrainTile
var active_textures: Array[TerrainTile]  # Currently bound textures

class TerrainTile:
    var position: Vector2i
    var heightmap: ImageTexture
    var seed: int
    var distance_to_camera: float  # For sorting
    
    func _init(pos: Vector2i, s: int):
        position = pos
        seed = s
        heightmap = null

func _ready():
    terrain_material = terrain_mesh.get_surface_override_material(0)
    # Ensure shader uniforms exist
    _update_shader_uniforms(Vector3.ZERO)

# Update active tiles based on camera position
func update_terrain(camera_position: Vector3):
    var camera_tile := Vector2i(
        floor(camera_position.x / TILE_SIZE),
        floor(camera_position.z / TILE_SIZE)
    )
    
    # Get current tile and its corners
    var needed_tiles := _get_corner_tiles(camera_tile, camera_position)
    
    # Generate/update tiles as needed
    for tile_pos in needed_tiles:
        if not tiles.has(tile_pos):
            var new_tile := TerrainTile.new(tile_pos, hash(str(tile_pos)))
            tiles[tile_pos] = new_tile
            _generate_heightmap(new_tile)
    
    # Update shader uniforms
    _update_shader_uniforms(camera_position)

# Get the four closest corner tiles to the camera position
func _get_corner_tiles(center_tile: Vector2i, camera_pos: Vector3) -> Array[Vector2i]:
    var local_pos := Vector2(
        fposmod(camera_pos.x, TILE_SIZE),
        fposmod(camera_pos.z, TILE_SIZE)
    )
    
    # Determine which corners we need based on position within tile
    var corners: Array[Vector2i] = []
    corners.append(center_tile)  # Current tile always included
    
    # Add relevant corner tiles based on position within current tile
    if local_pos.x < BLEND_BORDER:
        corners.append(center_tile + Vector2i(-1, 0))
        if local_pos.y < BLEND_BORDER:
            corners.append(center_tile + Vector2i(-1, -1))
        elif local_pos.y > TILE_SIZE - BLEND_BORDER:
            corners.append(center_tile + Vector2i(-1, 1))
    elif local_pos.x > TILE_SIZE - BLEND_BORDER:
        corners.append(center_tile + Vector2i(1, 0))
        if local_pos.y < BLEND_BORDER:
            corners.append(center_tile + Vector2i(1, -1))
        elif local_pos.y > TILE_SIZE - BLEND_BORDER:
            corners.append(center_tile + Vector2i(1, 1))
    
    if local_pos.y < BLEND_BORDER:
        corners.append(center_tile + Vector2i(0, -1))
    elif local_pos.y > TILE_SIZE - BLEND_BORDER:
        corners.append(center_tile + Vector2i(0, 1))
    
    return corners

# Update shader uniforms with current tiles
func _update_shader_uniforms(camera_pos: Vector3):
    var needed_tiles := _get_corner_tiles(
        Vector2i(floor(camera_pos.x / TILE_SIZE), floor(camera_pos.z / TILE_SIZE)),
        camera_pos
    )
    
    # Update distances and sort tiles by distance to camera
    var tile_list := []
    for tile_pos in needed_tiles:
        var tile: TerrainTile = tiles[tile_pos]
        var tile_center := Vector3(
            tile_pos.x * TILE_SIZE + TILE_SIZE/2,
            0,
            tile_pos.y * TILE_SIZE + TILE_SIZE/2
        )
        tile.distance_to_camera = camera_pos.distance_to(tile_center)
        tile_list.append(tile)
    
    tile_list.sort_custom(func(a, b): return a.distance_to_camera < b.distance_to_camera)
    
    # Update shader uniforms
    for i in range(min(4, tile_list.size())):
        var tile: TerrainTile = tile_list[i]
        terrain_material.set_shader_parameter(
            "heightmap_" + str(i),
            tile.heightmap
        )
        terrain_material.set_shader_parameter(
            "tile_position_" + str(i),
            Vector2(tile.position.x * TILE_SIZE, tile.position.y * TILE_SIZE)
        )
    
    # Set number of active tiles
    terrain_material.set_shader_parameter("active_tiles", min(4, tile_list.size()))
    terrain_material.set_shader_parameter("camera_position", camera_pos)

func _generate_heightmap(tile: TerrainTile):
    var img := Image.create(TILE_SIZE, TILE_SIZE, false, Image.FORMAT_RF)
    seed(tile.seed)
    
    # Your heightmap generation code here
    # This is a placeholder
    for x in range(TILE_SIZE):
        for y in range(TILE_SIZE):
            var height := randf()  # Replace with your noise generation
            img.set_pixel(x, y, Color(height, 0, 0))
    
    tile.heightmap = ImageTexture.create_from_image(img)
