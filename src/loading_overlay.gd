class_name LoadingOverlay
extends CanvasLayer

## Loading overlay for terrain batch generation
## Shows progress bar, status text, and generation log

@onready var progress_bar: ProgressBar = $ColorRect/CenterContainer/PanelContainer/VBoxContainer/ProgressBar
@onready var status_label: Label = $ColorRect/CenterContainer/PanelContainer/VBoxContainer/StatusLabel
@onready var log_text: RichTextLabel = $ColorRect/CenterContainer/PanelContainer/VBoxContainer/ScrollContainer/LogText

func _ready():
	visible = false

func show_loading(total_tiles: int) -> void:
	"""Show loading overlay and initialize progress"""
	visible = true
	progress_bar.max_value = total_tiles
	progress_bar.value = 0
	status_label.text = "Starting terrain generation..."
	log_text.clear()
	log_text.append_text("[b]Terrain Generation Log[/b]\n\n")
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE

func update_progress(completed: int, total: int, tile_pos: Vector2i, from_cache: bool) -> void:
	"""Update progress bar and log with current tile status"""
	progress_bar.value = completed

	var cache_str = " [color=green](cached)[/color]" if from_cache else ""
	status_label.text = "Tile (%d, %d) - %d/%d%s" % [
		tile_pos.x, tile_pos.y, completed, total,
		" (from cache)" if from_cache else ""
	]

	log_text.append_text("[%d/%d] Tile (%d, %d)%s\n" % [
		completed, total, tile_pos.x, tile_pos.y, cache_str
	])

	# Auto-scroll to bottom
	await get_tree().process_frame
	if log_text.get_line_count() > 0:
		log_text.scroll_to_line(log_text.get_line_count() - 1)

func hide_loading() -> void:
	"""Hide loading overlay and restore mouse capture"""
	visible = false
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
