extends Node3D

@export var player_character:Node3D
@onready var original_pos = global_position

func _physics_process(delta):
  var p = (player_character.global_position*0.125).round()*8
  global_position = original_pos * Vector3.UP + p* Vector3(1,0,1)
