@tool
extends Node
class_name HeightmapGenerator

# Common properties for heightmap generation
var rd: RenderingDevice
var heightmap_image: Image
var heightmap_texture: ImageTexture
var map_size: int = 256  # Must be power of 2
var debug_output: bool = false

# Abstract methods that must be implemented
func generate_heightmap() -> void:
    push_error("generate_heightmap() not implemented")

func reset() -> void:
    push_error("reset() not implemented")

func save_heightmap_exr(filepath: String ) -> void:
    heightmap_image.save_exr(filepath)
    print("heightmap saved to " + filepath)

# Utility methods
static func create_uniform(buffer: RID, binding: int) -> RDUniform:
    var uniform := RDUniform.new()
    uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
    uniform.binding = binding
    uniform.add_id(buffer)
    return uniform


static func save_debug_image(image: Image, filename: String) -> void:
    image.save_png("res://" + filename + ".png")
    image.save_exr("res://" + filename + ".exr")
    print("Debug heightmap saved to " + filename)