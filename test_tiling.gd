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
		run_erosion_test = false  # Trigger reload

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

	# Create output directories
	_create_output_directories()

	var erosion_gen = ErosionGeneratorTiled.new()
	erosion_gen.map_size = TILE_SIZE
	erosion_gen.seed_value = GLOBAL_SEED
	erosion_gen.padding_pixels = 128
	erosion_gen.droplets_per_tile = 1000  # Increased from 500
	erosion_gen.num_iterations = 50000
	erosion_gen.brush_radius = 3
	erosion_gen.max_lifetime = 30
	erosion_gen.sediment_capacity_factor = 8.0  # Increased from 4.0
	erosion_gen.min_sediment_capacity = 0.01
	erosion_gen.deposit_speed = 0.6  # Increased from 0.3
	erosion_gen.erode_speed = 0.6  # Increased from 0.3
	erosion_gen.evaporate_speed = 0.01
	erosion_gen.gravity = 10.0
	erosion_gen.start_speed = 1.0
	erosion_gen.start_water = 1.0
	erosion_gen.inertia = 0.3
	erosion_gen.debug_output = true

	# Generate all tiles in 4x4 grid
	for ty in range(GRID_SIZE):
		for tx in range(GRID_SIZE):
			print("Generating eroded tile (%d, %d)..." % [tx, ty])

			erosion_gen.tile_x = tx
			erosion_gen.tile_y = ty
			erosion_gen.generate_heightmap()

			# Save individual tile
			var tile_filename = "erosion_tile_%d_%d" % [tx, ty]
			erosion_gen.save_heightmap_png(PNG_DIR + tile_filename + ".png")
			erosion_gen.save_heightmap_exr(EXR_DIR + tile_filename + ".exr")

	print("\nGenerating composite erosion image...")
	create_composite_image("erosion", GRID_SIZE, TILE_SIZE)

	print("\nGenerating composite difference image...")
	create_composite_difference_image(GRID_SIZE, TILE_SIZE)

	print("\n--- Erosion Tiling Test Complete ---")
	print("Generated %d tiles" % (GRID_SIZE * GRID_SIZE))
	print("Files saved:")
	print("  - Individual PNG tiles: %s" % PNG_DIR)
	print("  - Individual EXR tiles: %s" % EXR_DIR)
	print("  - Composite PNG: %serosion_composite_4x4.png" % PNG_DIR)
	print("  - Composite EXR: %serosion_composite_4x4.exr" % EXR_DIR)
	print("  - Composite Difference: %serosion_difference_composite_4x4.png" % PNG_DIR)
	print("    (Red = erosion, Green = deposition)")

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

func create_composite_difference_image(grid_size: int, tile_size: int):
	"""Create a composite difference image showing erosion vs deposition across all tiles"""
	var composite_size = grid_size * tile_size
	var composite_diff = Image.create(composite_size, composite_size, false, Image.FORMAT_RGB8)

	var total_erosion = 0.0
	var total_deposition = 0.0
	var max_erosion = 0.0
	var max_deposition = 0.0

	# Load all tile difference images and composite them
	for ty in range(grid_size):
		for tx in range(grid_size):
			var diff_path = PNG_DIR + "tile_diff_%d_%d.png" % [tx, ty]

			# Load tile difference image
			var tile_diff = Image.load_from_file(diff_path)
			if tile_diff == null:
				printerr("Failed to load tile difference: ", diff_path)
				continue

			# Copy tile into composite and accumulate statistics
			for y in range(tile_size):
				for x in range(tile_size):
					var px = tx * tile_size + x
					var py = ty * tile_size + y
					var color = tile_diff.get_pixel(x, y)
					composite_diff.set_pixel(px, py, color)

					# Track erosion (red) and deposition (green)
					if color.r > 0.1:  # Erosion
						var erosion_amount = color.r
						total_erosion += erosion_amount
						max_erosion = max(max_erosion, erosion_amount)
					if color.g > 0.1:  # Deposition
						var deposition_amount = color.g
						total_deposition += deposition_amount
						max_deposition = max(max_deposition, deposition_amount)

	# Save composite difference image
	composite_diff.save_png(PNG_DIR + "erosion_difference_composite_%dx%d.png" % [grid_size, grid_size])

	print("Composite difference image saved: erosion_difference_composite_%dx%d.png" % [grid_size, grid_size])
	print("\nComposite Erosion Statistics:")
	print("  Total erosion (red): %.3f" % total_erosion)
	print("  Total deposition (green): %.3f" % total_deposition)
	print("  Max erosion intensity: %.3f" % max_erosion)
	print("  Max deposition intensity: %.3f" % max_deposition)
	print("  Net change: %.3f" % (total_deposition - total_erosion))
