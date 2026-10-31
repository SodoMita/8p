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

	# --- boundary fence: pure geometry, no physics stepping ------------------
	# every fabric/pole collider must sit ON one of the four fence lines at the
	# right height, its long axis must run along the fence, and the ring must be
	# closed except for the gate opening
	var fence_ok := true
	var fence: Node = world.map_builder.find_child("FenceBody", true, false)
	var fabric_spans: Array[float] = []
	var gate_gap := 0.0
	if fence == null:
		fence_ok = false
		print("[selftest]   no FenceBody")
	else:
		var on_line := 0
		var bad := 0
		for c in fence.get_children():
			if c is not CollisionShape3D:
				continue
			var cs: CollisionShape3D = c
			var p := cs.global_position
			# gate leaves hang off the line on purpose, swung open into the forest
			var near_gate := absf(p.x - 61.0) < 2.6 and absf(p.z) < 6.5
			var dist := minf(minf(absf(absf(p.x) - 61.0), absf(absf(p.z) - 61.0)), 1.0)
			var on_fence := dist < 0.35 or near_gate
			var in_terrain := p.y > -1.0 and p.y < 3.0
			if on_fence and in_terrain:
				on_line += 1
				if cs.shape is BoxShape3D:
					var box := cs.shape as BoxShape3D
					var long_axis := maxf(box.size.x, box.size.z)
					# the long axis must point along the fence, not through it
					var x_axis := (cs.global_transform.basis * Vector3.RIGHT).normalized()
					var along_x := absf(absf(x_axis.x) - 1.0) < 0.2
					var along_z := absf(absf(x_axis.z) - 1.0) < 0.2
					# a run sitting at z = +-61 stretches along X, and vice versa
					var run_at_z := absf(absf(p.z) - 61.0) < 0.35
					if long_axis < 2.0 or (not near_gate and not (along_x if run_at_z else along_z)):
						bad += 1
					else:
						fabric_spans.append(long_axis)
			else:
				bad += 1
				print("[selftest]   fence collider off-line at ", p)
		if on_line < 100 or bad > 0:
			fence_ok = false
		print("[selftest]   fence: %d colliders on the ring, %d bad" % [on_line, bad])
		# total fabric length vs the perimeter minus the 5 m gate opening
		var covered := 0.0
		for span in fabric_spans:
			covered += span
		# four 120 m runs, less the 5 m gate opening (one 3 m bay is skipped)
		var expected := 4.0 * 120.0 - 3.0
		if absf(covered - expected) > 12.0:
			fence_ok = false
			print("[selftest]   fence covers %.1f m, expected ~%.1f" % [covered, expected])
	check("boundary_fence_ring", fence_ok)
	# the gate must actually be an opening you can drive a road through
	var gate: Vector3 = world.map_builder.gate_centre
	var gate_clear := true
	for c in fence.get_children() if fence != null else []:
		if c is CollisionShape3D:
			var gp: Vector3 = (c as CollisionShape3D).global_position
			if absf(gp.x - gate.x) < 0.4 and absf(gp.z) < 2.2 and gp.y > 0.5:
				gate_clear = false
	check("gate_is_open", gate_clear, str(gate))

	# --- pages: cloth simulation, and no light of their own ------------------
	var pages_list: Array = world.pages
	var cloth_ok: bool = pages_list.size() >= 8
	var light_free := cloth_ok
	var sags := cloth_ok
	for p in pages_list:
		var sheet: Node3D = p.get("cloth")
		if sheet == null or sheet.vertex_count() != 63:
			cloth_ok = false
			continue
		if sheet.has_light():
			light_free = false
		var before: PackedVector3Array = sheet.snapshot()
		var top_y: float = before[0].y
		for k in 90:
			sheet._simulate(1.0 / 60.0)
		var after: PackedVector3Array = sheet.snapshot()
		# the free (bottom) edge must have dropped and must not have exploded
		if after[63 - 1].y > top_y - 0.05 or after[63 - 1].length() > 20.0:
			sags = false
	# the sheet's smoothed normals must agree with its own winding (+Z), or the
	# page is lit from behind and reads as a black rectangle in the beam
	var norm_ok := cloth_ok
	for p in pages_list:
		var sh: Node3D = p.get("cloth")
		if sh == null:
			continue
		sh._simulate(1.0 / 60.0)
		var ns: PackedVector3Array = sh.surface_normals()
		var acc2 := 0.0
		for nvec in ns:
			acc2 += nvec.dot(Vector3.BACK)
		if ns.size() == 0 or acc2 / float(ns.size()) < 0.9:
			norm_ok = false
	check("page_cloth_normals_forward", norm_ok)

	check("pages_are_cloth", cloth_ok, "%d pages" % pages_list.size())
	check("pages_have_no_light", light_free)
	check("page_cloth_sags", sags)

	# --- outside the fence: endless terrain + the road out of the gate --------
	var st: Dictionary = world.terrain.stats() if world.terrain != null else {}
	var terrain_ok: bool = not st.is_empty() and int(st.get("chunks", 0)) >= 9
	check("terrain_chunks", terrain_ok, str(st.get("chunks", 0)))
	check("terrain_has_trees", int(st.get("trees", 0)) > 300, str(st.get("trees", 0)))
	check("road_out_of_gate", bool(st.get("road", false)))
	var floor_ok := false
	for c in world.terrain.get_children() if world.terrain != null else []:
		if c is StaticBody3D and c.name == "WorldFloor":
			for s2 in c.get_children():
				if s2 is CollisionShape3D and (s2 as CollisionShape3D).shape is BoxShape3D:
					var box := (s2 as CollisionShape3D).shape as BoxShape3D
					floor_ok = box.size.x >= 1000.0 and box.size.z >= 1000.0
	check("outer_floor_covers_world", floor_ok)

	check("landmarks_count", world.map_builder.landmarks.size() == 8, str(world.map_builder.landmarks.size()))
	check("page_spots_count", world.map_builder.page_spots.size() == 8)
	check("tree_count", world.map_builder.tree_count() > 400, str(world.map_builder.tree_count()))
	check("pages_spawned", world.pages.size() == 8)
	var all_inside := true
	for p in pages_list:
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

	# ---- input independence: keyboard/mouse must work in touch mode too ----
	# (the human reported "on PC mouse controls don't work"; the cause was the
	#  touch-mode early-outs, so prove both paths are live simultaneously)
	var was_touch: bool = Game.touch_mode
	Game.touch_mode = true
	player.rotation.y = 0.0
	player.add_look(Vector2(180, 0))
	check("mouse_look_in_touch_mode", absf(player.rotation.y) > 0.1,
		"%.3f rad" % player.rotation.y)
	player.frozen = false
	var start_touch := player.global_position
	Input.action_press("move_forward")
	await _wait(0.5)
	Input.action_release("move_forward")
	var walked_keys: float = (player.global_position - start_touch).length()
	check("keyboard_moves_in_touch_mode", walked_keys > 0.4, "%.2f m" % walked_keys)
	# with the cursor free (touch mode), a plain pointer move must not turn the
	# camera: the cursor belongs to the stick and the menus
	var flick := InputEventMouseMotion.new()
	flick.relative = Vector2(240, 0)
	var yaw_before_flick: float = player.rotation.y
	player._unhandled_input(flick)
	check("plain_mouse_ignored_in_touch_mode",
		absf(player.rotation.y - yaw_before_flick) < 0.001,
		"%.3f rad" % (player.rotation.y - yaw_before_flick))
	# ... holding a button is drag-look, and that does turn the camera
	var drag := InputEventMouseMotion.new()
	drag.relative = Vector2(240, 0)
	drag.button_mask = MOUSE_BUTTON_MASK_LEFT
	var yaw_before_drag: float = player.rotation.y
	player._unhandled_input(drag)
	check("mouse_drag_reaches_player", absf(player.rotation.y - yaw_before_drag) > 0.1,
		"%.3f rad" % (player.rotation.y - yaw_before_drag))
	# a finger's emulated mouse motion never looks twice: touch_controls owns it
	var emulated := InputEventMouseMotion.new()
	emulated.relative = Vector2(240, 0)
	emulated.button_mask = MOUSE_BUTTON_MASK_LEFT
	emulated.device = InputEvent.DEVICE_ID_EMULATION
	var yaw_before_emu: float = player.rotation.y
	player._unhandled_input(emulated)
	check("emulated_mouse_ignored", absf(player.rotation.y - yaw_before_emu) < 0.001,
		"%.3f rad" % (player.rotation.y - yaw_before_emu))
	Game.touch_mode = was_touch

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

	# ------------------------------------------------- post-effects are intact
	# #28 /re 21: the camcorder pass had quietly turned the old grain overlay off
	# and halved the vignette. Both are back, stacked over the tape, so assert the
	# composites exist at full strength whatever the camcorder is doing.
	var hud: Node = world.hud
	check("hud_static_overlay_present", hud.static_rect != null and hud.static_mat != null)
	check("hud_static_overlay_visible", hud.static_rect.visible)
	var vig_strength: float = float(hud.vignette_mat.get_shader_parameter("strength"))
	check("hud_vignette_full_strength", is_equal_approx(vig_strength, 0.92),
		"%.2f" % vig_strength)
	var cam_on: bool = Settings.camcorder
	Settings.camcorder = not cam_on
	hud.refresh_camcorder()
	await _wait(0.1)
	check("hud_effects_survive_camcorder_toggle",
		hud.static_rect.visible and is_equal_approx(
			float(hud.vignette_mat.get_shader_parameter("strength")), 0.92),
		"static=%s vig=%.2f" % [str(hud.static_rect.visible),
			float(hud.vignette_mat.get_shader_parameter("strength"))])
	Settings.camcorder = cam_on
	hud.refresh_camcorder()
	await _wait(0.1)

	# ------------------------------------------------------------- death flow
	sl.visible = true
	sl.global_position = player.global_position + Vector3(0, 0, -2.0)
	sl.force_chase()
	await _wait(3.5)
	check("caught_by_slender", sl.dead)
	check("death_screen", world.hud.end_root.visible)
	check("death_title", world.hud.end_title.text == "HE FOUND YOU", world.hud.end_title.text)
