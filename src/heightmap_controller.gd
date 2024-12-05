@tool
extends Node3D

@export_group("Input Settings")

@export var reset_heightmap: bool = false:
  set(value):
    reset_heightmap = false
    reset()

@export var height_scale: float = 50.0:
    set(value):
        height_scale = value
        if material:
            material.set_shader_parameter("height_scale", value)

@export var target_mesh: MeshInstance3D:
    set(value):
        target_mesh = value
        setup_material()
        update_material_heightmap()

@export var map_size: int = 256:
    set(value):
        map_size = value
        voronoi_generator.map_size = map_size
        erosion_generator.map_size = map_size
@export var input_heightmap: Texture2D:
    set(value):
        input_heightmap = value
        current_heightmap = input_heightmap.get_image()
        update_material_heightmap()

@export var debug_output: bool = false


@export_group("Erosion Settings")
@export var generate_erosion: bool = false:
  set(value):
    generate_erosion = false
    apply_erosion()


@export var num_erosion_iterations: int = 50000
@export var erosion_brush_radius: int = 3
@export var erosion_seed: int = 0
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

@export var scaling_type: VoronoiGenerator.ScalingType = VoronoiGenerator.ScalingType.POWER:
    set(value):
        scaling_type = value
        generate_voronoi_heightmap()


var material: ShaderMaterial
var voronoi_generator: VoronoiGenerator
var erosion_generator: ErosionGenerator
var current_heightmap: Image
var original_input_heightmap: Image = null

func _ready():
    setup_material()
    voronoi_generator = VoronoiGenerator.new()
    erosion_generator = ErosionGenerator.new()
    voronoi_generator.map_size = map_size
    erosion_generator.map_size = map_size
    current_heightmap = input_heightmap.get_image()
    update_material_heightmap()

func setup_material() -> void:
    if target_mesh:
        material = target_mesh.material_override
        if material:
            material.set_shader_parameter("height_scale", height_scale)

func reset():
  # voronoi_generator.reset()
  # erosion_generator.reset()
  if input_heightmap :
    original_input_heightmap = input_heightmap.duplicate().get_image()
  current_heightmap = input_heightmap.get_image()
  setup_material()
  update_material_heightmap()


func generate_voronoi_heightmap() -> void:
    voronoi_generator.seed_value = voronoi_seed
    voronoi_generator.num_points = num_voronoi_points
    voronoi_generator.height_falloff = height_falloff
    voronoi_generator.min_height = min_voronoi_height
    voronoi_generator.max_height = max_voronoi_height
    voronoi_generator.ridge_multiplier = ridge_multiplier
    voronoi_generator.amplitude = amplitude
    voronoi_generator.scaling_type = scaling_type

    voronoi_generator.generate_heightmap()
    current_heightmap = voronoi_generator.heightmap_image
    update_material_heightmap()

func apply_erosion() -> void:
    erosion_generator.num_iterations = num_erosion_iterations
    erosion_generator.brush_radius = erosion_brush_radius
    erosion_generator.seed_value = erosion_seed
    erosion_generator.max_lifetime = max_lifetime
    erosion_generator.sediment_capacity_factor = sediment_capacity_factor
    erosion_generator.min_sediment_capacity = min_sediment_capacity
    erosion_generator.deposit_speed = deposit_speed
    erosion_generator.erode_speed = erode_speed
    erosion_generator.evaporate_speed = evaporate_speed
    erosion_generator.gravity = gravity
    erosion_generator.start_speed = start_speed
    erosion_generator.start_water = start_water
    erosion_generator.inertia = inertia
    erosion_generator.debug_output = debug_output
    if current_heightmap:
        erosion_generator.heightmap_image = current_heightmap
        erosion_generator.generate_heightmap()
        current_heightmap = erosion_generator.heightmap_image
        update_material_heightmap()

func update_material_heightmap() -> void:
    if current_heightmap and material:
        var texture = ImageTexture.create_from_image(current_heightmap)
        material.set_shader_parameter("heightmap", texture)
