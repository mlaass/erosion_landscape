@tool
extends Node

# Test script for generating tiled heightmaps
# This generates a 4x4 grid of tiles and saves them as images for visual inspection
#
# To run: Add this node to a scene in the editor and click "Run Test" in the inspector

const TILE_SIZE = 256
const GRID_SIZE = 4  # 4x4 grid
const GLOBAL_SEED = 12345

# Output directories
const OUTPUT_DIR = "res://output/"
const PNG_DIR = OUTPUT_DIR + "png/"
const EXR_DIR = OUTPUT_DIR + "exr/"

@export var run_voronoi_test: bool = false:
	set(value):
		if value:
			print("=== Starting Voronoi Tiling Test ===")
			test_voronoi_tiling()
			print("\n=== Voronoi Test Complete ===")
		run_voronoi_test = false

@export var run_erosion_test: bool = false:
	set(value):
		if value:
			print("=== Starting Erosion Tiling Test ===")
			test_erosion_tiling()
			print("\n=== Erosion Test Complete ===")
		run_erosion_test = false

func test_voronoi_tiling():
	print("\n--- Testing Voronoi Tiling ---")

	# Create output directories
	_create_output_directories()

	var voronoi_gen = VoronoiGenerator.new()
	voronoi_gen.map_size = TILE_SIZE
	voronoi_gen.seed_value = GLOBAL_SEED
	voronoi_gen.num_points = 8
	voronoi_gen.height_falloff = 2.0
	voronoi_gen.min_height = 0.0
	voronoi_gen.max_height = 1.0
	voronoi_gen.ridge_multiplier = 0.0
	voronoi_gen.amplitude = 1.0
	voronoi_gen.scaling_type = VoronoiGenerator.ScalingType.POWER
	voronoi_gen.debug_output = false

	# Generate all tiles in 4x4 grid
	for ty in range(GRID_SIZE):
		for tx in range(GRID_SIZE):
			print("Generating Voronoi tile (%d, %d)..." % [tx, ty])

			voronoi_gen.tile_x = tx
			voronoi_gen.tile_y = ty
			voronoi_gen.generate_heightmap()

			# Save individual tile
			var tile_filename = "voronoi_tile_%d_%d" % [tx, ty]
			voronoi_gen.save_heightmap_png(PNG_DIR + tile_filename + ".png")
			voronoi_gen.save_heightmap_exr(EXR_DIR + tile_filename + ".exr")

	print("\nGenerating composite Voronoi image...")
	create_composite_image("voronoi", GRID_SIZE, TILE_SIZE)

	print("\n--- Voronoi Tiling Test Complete ---")
	print("Generated %d tiles" % (GRID_SIZE * GRID_SIZE))
	print("Files saved:")
	print("  - Individual PNG tiles: %s" % PNG_DIR)
	print("  - Individual EXR tiles: %s" % EXR_DIR)
	print("  - Composite PNG: %svoronoi_composite_4x4.png" % PNG_DIR)
	print("  - Composite EXR: %svoronoi_composite_4x4.exr" % EXR_DIR)

func test_erosion_tiling():
	print("\n--- Testing Erosion Tiling ---")
	print("(Not yet implemented - pending erosion shader updates)")
	# TODO: Implement after erosion tiling is complete

func _create_output_directories():
	"""Create output directory structure if it doesn't exist"""
	var dir = DirAccess.open("res://")

	# Create main output directory
	if not dir.dir_exists(OUTPUT_DIR):
		dir.make_dir(OUTPUT_DIR)
		print("Created directory: ", OUTPUT_DIR)

	# Create PNG subdirectory
	if not dir.dir_exists(PNG_DIR):
		dir.make_dir(PNG_DIR)
		print("Created directory: ", PNG_DIR)

	# Create EXR subdirectory
	if not dir.dir_exists(EXR_DIR):
		dir.make_dir(EXR_DIR)
		print("Created directory: ", EXR_DIR)

func create_composite_image(prefix: String, grid_size: int, tile_size: int):
	"""Create a composite image from all tiles for easy visual inspection"""
	var composite_size = grid_size * tile_size
	var composite = Image.create(composite_size, composite_size, false, Image.FORMAT_RF)

	# Load and composite all tiles
	for ty in range(grid_size):
		for tx in range(grid_size):
			var tile_path = EXR_DIR + "%s_tile_%d_%d.exr" % [prefix, tx, ty]

			# Load tile
			var tile_img = Image.load_from_file(tile_path)
			if tile_img == null:
				printerr("Failed to load tile: ", tile_path)
				continue

			# Copy tile into composite
			for y in range(tile_size):
				for x in range(tile_size):
					var px = tx * tile_size + x
					var py = ty * tile_size + y
					var color = tile_img.get_pixel(x, y)
					composite.set_pixel(px, py, color)

	# Save composite
	composite.save_exr(EXR_DIR + "%s_composite_%dx%d.exr" % [prefix, grid_size, grid_size])

	# Create RGB version for PNG
	var composite_rgb = Image.create(composite_size, composite_size, false, Image.FORMAT_RGB8)
	for y in range(composite_size):
		for x in range(composite_size):
			var h = composite.get_pixel(x, y).r
			composite_rgb.set_pixel(x, y, Color(h, h, h))
	composite_rgb.save_png(PNG_DIR + "%s_composite_%dx%d.png" % [prefix, grid_size, grid_size])

	print("Composite image saved: %s_composite_%dx%d.png/exr" % [prefix, grid_size, grid_size])

	# Verify seamlessness at some boundaries
	verify_seams(composite, tile_size, grid_size, prefix)

func verify_seams(composite: Image, tile_size: int, grid_size: int, prefix: String):
	"""Check for discontinuities at tile boundaries"""
	print("\nVerifying tile seamlessness...")

	var max_diff = 0.0
	var seam_errors = 0
	var tolerance = 0.001  # Acceptable floating point error

	# Check vertical boundaries
	for ty in range(grid_size):
		for tx in range(grid_size - 1):
			var boundary_x = (tx + 1) * tile_size
			for y in range(ty * tile_size, (ty + 1) * tile_size):
				var left = composite.get_pixel(boundary_x - 1, y).r
				var right = composite.get_pixel(boundary_x, y).r
				var diff = abs(left - right)
				max_diff = max(max_diff, diff)
				if diff > tolerance:
					seam_errors += 1
					if seam_errors <= 5:  # Only print first few errors
						print("  Vertical seam at (%d, %d): diff = %.6f" % [boundary_x, y, diff])

	# Check horizontal boundaries
	for ty in range(grid_size - 1):
		for tx in range(grid_size):
			var boundary_y = (ty + 1) * tile_size
			for x in range(tx * tile_size, (tx + 1) * tile_size):
				var top = composite.get_pixel(x, boundary_y - 1).r
				var bottom = composite.get_pixel(x, boundary_y).r
				var diff = abs(top - bottom)
				max_diff = max(max_diff, diff)
				if diff > tolerance:
					seam_errors += 1
					if seam_errors <= 5:
						print("  Horizontal seam at (%d, %d): diff = %.6f" % [x, boundary_y, diff])

	print("\n%s Seamlessness Report:" % prefix.capitalize())
	print("  Maximum boundary difference: %.6f" % max_diff)
	print("  Seam errors (> %.6f): %d" % [tolerance, seam_errors])
	if seam_errors == 0:
		print("  ✓ PERFECT SEAMLESSNESS!")
	elif max_diff < 0.01:
		print("  ✓ Visually seamless (minor floating point errors)")
	else:
		print("  ✗ SEAMS DETECTED - investigation needed")
