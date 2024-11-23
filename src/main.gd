extends Node3D

var rotation_speed: float = 0.005
var zoom_speed: float = 0.5
var min_zoom: float = 0.01
var max_zoom: float = 500.0

func _ready() -> void:
    %Camera3D.current = true

func _unhandled_input(event: InputEvent) -> void:
    if event is InputEventMouseMotion:
        if event.button_mask == MOUSE_BUTTON_MASK_LEFT:
            print("Rotating: ", event.relative)
            rotate_y(event.relative.x * rotation_speed)
            rotate_x(-event.relative.y * rotation_speed)
            rotation.x = clamp(rotation.x, -PI/2, PI/2)

    elif event is InputEventMouseButton:
        var zoom_delta = zoom_speed * (%Camera3D.position.z * 0.1)
        if event.button_index == MOUSE_BUTTON_WHEEL_UP:
            %Camera3D.position.z = clamp(%Camera3D.position.z - zoom_delta, min_zoom, max_zoom)
        elif event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
            %Camera3D.position.z = clamp(%Camera3D.position.z + zoom_delta, min_zoom, max_zoom)
