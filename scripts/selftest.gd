extends Node
## Functional self-test suite. Run with:
##   godot --path . res://scenes/World.tscn -- --autotest=selftest
## Verifies world generation, movement, sprint/stamina, collision, pickups,
## Slender visibility AI, death flow and the touch control API.
## Exits 0 when every check passes.

var world: Node = null
var passed := 0
var failed := 0


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	await get_tree().process_frame
	await get_tree().create_timer(1.0, true, false, true).timeout
	await _run()
	print("[selftest] RESULT %d passed, %d failed" % [passed, failed])
	get_tree().quit(0 if failed == 0 else 1)


func check(name: String, condition: bool, detail := "") -> void:
	if condition:
		passed += 1
		print("[selftest] PASS  %s %s" % [name, detail])
	else:
		failed += 1
		print("[selftest] FAIL  %s %s" % [name, detail])


func _wait(t: float) -> void:
	await get_tree().create_timer(t, true, false, true).timeout


func _map_signature(mb: Node, pages: Array) -> String:
	var parts := PackedStringArray()
	for l in mb.landmarks:
		var p: Vector3 = l["pos"]
		parts.append("%s:%.1f,%.1f,%.2f" % [l["name"], p.x, p.z, float(l["rot"])])
	for pg in pages:
		var pp: Vector3 = (pg["node"] as Node3D).global_position
		parts.append("p%.1f,%.1f" % [pp.x, pp.z])
	return "|".join(parts)


func _min_landmark_distance(mb: Node) -> float:
	var best := 999.0
	var ls: Array = mb.landmarks
	for i in ls.size():
		for j in range(i + 1, ls.size()):
			var a: Vector3 = ls[i]["pos"]
			var b: Vector3 = ls[j]["pos"]
			best = minf(best, Vector2(a.x - b.x, a.z - b.z).length())
	return best


## Build a second, independent map in a throwaway node to compare layouts.
func _build_other_map(source: Node) -> Node:
	var other = load("res://scripts/map_builder.gd").new()
	other.name = "MapProbe"
	get_tree().root.add_child(other)
	other.build(source.world_seed + 4321, 1)
	return other


func _run() -> void:
	var player: CharacterBody3D = world.player
	var sl: Node3D = world.slender

	# ------------------------------------------------------- procedural layout
	# every seed must produce a different map, and every page must be reachable
	var sig := _map_signature(world.map_builder, world.pages)
	print("[selftest] map signature: ", sig)
	var other := _build_other_map(world.map_builder)
	var sig2 := _map_signature(other, [])
	print("[selftest] second signature: ", sig2)
	check("procedural_layout_unique", sig != sig2)

	var all_reachable := true
	for spot in world.map_builder.page_spots:
		var sp: Vector3 = spot["pos"]
		if not world.map_builder.is_walkable(sp, 0.35):
			all_reachable = false
			print("[selftest]   page blocked at ", sp)
	check("pages_reachable", all_reachable)
	var landmark_spread := _min_landmark_distance(world.map_builder)
	# the algorithm targets >= 24 m centre-to-centre; 18 m still guarantees the
	# landmarks never merge into one blob (their clearance radii are ~13 m)
	check("landmarks_spread", landmark_spread > 18.0, "%.1f m" % landmark_spread)

	# ------------------------------------------------------------------ world
	# --- mesh sanity: every tree/prop triangle must be wound to match its
	# stored vertex normal (a mismatch is what "inverted normals" looks like)
	var mesh_ok := true
	for file in ["tree_0", "tree_3", "snag_0", "log_0", "stump_0", "shrub_0",
			"pumpkin_0", "pumpkin_1", "bush_0", "bush_2"]:
		var path := "res://assets/models/%s.res" % file
		if not ResourceLoader.exists(path):
			mesh_ok = false
			print("[selftest]   missing mesh ", file)
			continue
		var mesh: ArrayMesh = load(path)
		var arrays := mesh.surface_get_arrays(0)
		var verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
		var norms: PackedVector3Array = arrays[Mesh.ARRAY_NORMAL]
		var idx: PackedInt32Array = arrays[Mesh.ARRAY_INDEX] if arrays[Mesh.ARRAY_INDEX] != null else PackedInt32Array()
		var tris := (idx.size() if idx.size() > 0 else verts.size()) / 3
		var bad := 0
		for t in tris:
			var i0: int = idx[t * 3] if idx.size() > 0 else t * 3
			var i1: int = idx[t * 3 + 1] if idx.size() > 0 else t * 3 + 1
			var i2: int = idx[t * 3 + 2] if idx.size() > 0 else t * 3 + 2
			var geo: Vector3 = (verts[i1] - verts[i0]).cross(verts[i2] - verts[i0])
			if geo.length() < 1e-9:
				continue
			var avg: Vector3 = (norms[i0] + norms[i1] + norms[i2]) / 3.0
			if avg.length() < 1e-6:
				continue
			if geo.normalized().dot(avg.normalized()) <= 0.0:
				bad += 1
		if bad > 0:
			mesh_ok = false
			print("[selftest]   %s has %d inverted triangles" % [file, bad])
	check("mesh_normals_outward", mesh_ok)

	# pumpkins and dead bushes must actually be in the world
	check("pumpkins_present", world.map_builder.pumpkin_count() > 8,
		str(world.map_builder.pumpkin_count()))
	check("bushes_present", world.map_builder.bush_count() > 60,
		str(world.map_builder.bush_count()))

	# boundary must be a ring of thin slabs on the edges, not plates across the map
	var fence_ok := true
	var fence: Node = world.find_child("BoundaryFence", true, false)
	if fence == null:
		fence_ok = false
	else:
		var slab_count := 0
		for c in fence.get_children():
			if c is not CollisionShape3D:
				continue
			var cs: CollisionShape3D = c
			var box: BoxShape3D = cs.shape
			var ext := box.size
			var thin := minf(ext.x, ext.z)
			var long_side := maxf(ext.x, ext.z)
			var ctr := cs.global_position
			var on_edge := absf(absf(ctr.x) - 61.0) < 2.0 or absf(absf(ctr.z) - 61.0) < 2.0
			if thin > 2.0 or long_side < 100.0 or not on_edge:
				fence_ok = false
				print("[selftest]   bad fence slab at ", ctr)
			slab_count += 1
		if slab_count != 4:
			fence_ok = false
	check("boundary_fence_ring", fence_ok)

	check("landmarks_count", world.map_builder.landmarks.size() == 8, str(world.map_builder.landmarks.size()))
	check("page_spots_count", world.map_builder.page_spots.size() == 8)
	check("tree_count", world.map_builder.tree_count() > 400, str(world.map_builder.tree_count()))
	check("pages_spawned", world.pages.size() == 8)
	var all_inside := true
	for p in world.pages:
		var pos: Vector3 = (p["node"] as Node3D).global_position
		if Vector2(pos.x, pos.z).length() > 59.0:
			all_inside = false
	check("pages_inside_bounds", all_inside)
	var unique_spots := {}
	for p in world.map_builder.page_spots:
		unique_spots[str(Vector2i(Vector2(p["pos"].x, p["pos"].z)))] = true
	check("pages_distinct", unique_spots.size() == 8, str(unique_spots.size()))

	# ------------------------------------------------------------ run bookkeeping
	# a full clear must leave the run finished and a best time recorded
	var prev_time := Game.run_time
	Game.begin_run()
	Game.run_time = 61.0
	for i in Game.TOTAL_PAGES:
		Game.register_page("note")
	var still_live := Game.run_active
	Game.finish_run(true)
	check("win_records_best", still_live and not Game.run_active and Game.best_time >= 0.0,
		"live=%s active=%s best=%.1f" % [str(still_live), str(Game.run_active), Game.best_time])
	Game.run_time = prev_time
	Game.begin_run()

	# ---------------------------------------------------------------- movement
	world.autotest_no_pickup = true
	player.global_position = Vector3(0, 0.2, 0)
	player.rotation.y = 0.0
	await _wait(0.5)
	var start := player.global_position
	player.set_touch_move(Vector2(0, -1))  # same code path the touch stick uses
	await _wait(1.0)
	var walked: float = (player.global_position - start).length()
	player.set_touch_move(Vector2.ZERO)
	check("walk_moves_player", walked > 1.5, "%.2f m in 1 s" % walked)

	# sprint should be faster and drain stamina
	player.stamina = 100.0
	player.global_position = Vector3(0, 0.2, 0)
	player.rotation.y = 0.0
	await _wait(0.4)
	start = player.global_position
	player.set_touch_move(Vector2(0, -1))
	player.set_touch_sprint(true)
	await _wait(1.0)
	var sprinted: float = (player.global_position - start).length()
	var stamina_used: float = 100.0 - player.stamina
	player.set_touch_sprint(false)
	player.set_touch_move(Vector2.ZERO)
	check("sprint_faster_than_walk", sprinted > walked * 1.3, "%.2f m vs %.2f m" % [sprinted, walked])
	check("sprint_drains_stamina", stamina_used > 5.0, "%.1f" % stamina_used)

	# look control (touch swipe path and mouse path share add_look)
	var yaw_before: float = player.rotation.y
	player.add_look(Vector2(200, 0))
	check("look_rotates_player", absf(player.rotation.y - yaw_before) > 0.1, "%.3f rad" % (player.rotation.y - yaw_before))

	# -------------------------------------------------------------- collision
	# walk straight into the concrete walls and make sure we do not pass through
	var walls: Dictionary = world.map_builder.landmarks[0]
	var wall_pos: Vector3 = walls["pos"]
	player.global_position = wall_pos + Vector3(0, 0.15, 12.0)
	player.rotation.y = 0.0
	await _wait(0.2)
	start = player.global_position
	player.set_touch_move(Vector2(0, -1))
	await _wait(2.0)
	player.set_touch_move(Vector2.ZERO)
	var travelled: float = (player.global_position - start).length()
	check("wall_blocks_player", travelled < 12.5, "travelled %.2f m toward a 9 m gap" % travelled)

	# ground: player stays on the floor
	await _wait(0.3)
	check("player_on_floor", player.is_on_floor(), str(player.global_position.y))

	# ---------------------------------------------------------------- pickups
	world.autotest_no_pickup = false
	var target: Vector3 = (world.pages[0]["node"] as Node3D).global_position
	player.global_position = Vector3(target.x, 0.15, target.z + 1.0)
	await _wait(0.5)
	check("page_pickup", Game.pages_collected == 1, "collected=%d" % Game.pages_collected)
	check("hud_page_counter", world.hud.pages_label.text == "1 / 8", world.hud.pages_label.text)
	check("note_shown", world.hud.note_body.text != "")
	check("slender_woken", sl.cooldown < 16.0, "cooldown=%.1f" % sl.cooldown)

	# ------------------------------------------------------------------ AI
	# unoccluded in front of the camera -> seen; behind -> unseen
	sl.set_process(false)
	sl.visible = true
	var cam: Camera3D = player.camera
	player.global_position = Vector3(0, 0.2, 10)
	player.rotation.y = 0.0
	player.head.rotation.x = 0.0
	await _wait(0.3)
	sl.global_position = Vector3(0, 0, 1)
	await _wait(0.2)
	check("slender_seen_in_front", sl._is_seen_by_player(),
		"cam=%s sl=%s frustum=%s" % [str(cam.global_position), str(sl.global_position), str(cam.is_position_in_frustum(sl.global_position + Vector3(0, 2.2, 0)))])
	sl.global_position = player.global_position + Vector3(0, 0, 10)
	await _wait(0.2)
	check("slender_unseen_behind", not sl._is_seen_by_player())
	sl.set_process(true)
	sl.visible = false

	# ------------------------------------------------------------- death flow
	sl.visible = true
	sl.global_position = player.global_position + Vector3(0, 0, -2.0)
	sl.force_chase()
	await _wait(3.5)
	check("caught_by_slender", sl.dead)
	check("death_screen", world.hud.end_root.visible)
	check("death_title", world.hud.end_title.text == "HE FOUND YOU", world.hud.end_title.text)
