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

	# Reachability, tested the way it actually matters: is there room to stand in
	# front of the page? A capsule cast against real collision, not the scattering
	# radius that `_point_inside_prop` uses for trees and props.
	var lab: Dictionary = world.map_builder.labyrinth
	var lab2: Dictionary = other.labyrinth
	var lab_mesh_node: MeshInstance3D = world.map_builder.get_node_or_null("LabyrinthMesh")
	var lab_floor_node: MeshInstance3D = world.map_builder.get_node_or_null("LabyrinthFloor")
	var lab_metal_node: MeshInstance3D = world.map_builder.get_node_or_null("LabyrinthMetal")
	var lab_wires_node: MeshInstance3D = world.map_builder.get_node_or_null("LabyrinthWires")
	var lab_body_node: StaticBody3D = world.map_builder.get_node_or_null("LabyrinthBody")
	var lab_rzone: Area3D = world.map_builder.get_node_or_null("LabyrinthReverbZone")
	var lab_hum0: AudioStreamPlayer3D = world.map_builder.get_node_or_null("SubstationHum_0")
	check("labyrinth_built",
		not lab.is_empty() and int(lab.get("cells", 0)) == 10 and int(lab.get("wall_count", 0)) > 65
		and lab_mesh_node != null and lab_floor_node != null
		and lab_metal_node != null and lab_wires_node != null
		and lab_body_node != null and lab_rzone != null,
		"cells=%d walls=%d" % [int(lab.get("cells", 0)), int(lab.get("wall_count", 0))])
	check("labyrinth_detailed_wires",
		int(lab.get("wire_count", 0)) >= 50 and int(lab.get("conduit_count", 0)) >= 15
		and int(lab.get("junction_boxes", 0)) >= 6 and int(lab.get("substations", 0)) == 2
		and int(lab.get("window_walls", 0)) >= 3 and lab_hum0 != null and lab_hum0.playing,
		"wires=%d conduits=%d boxes=%d windows=%d" % [
			int(lab.get("wire_count", 0)), int(lab.get("conduit_count", 0)),
			int(lab.get("junction_boxes", 0)), int(lab.get("window_walls", 0))])
	check("labyrinth_unique_per_seed",
		String(lab.get("signature", "")) != "" and lab.get("signature") != lab2.get("signature"))
	check("labyrinth_solvable",
		int(lab.get("shortest_path", -1)) >= 4 and int(lab.get("longest_path", -1)) >= 6,
		"shortest=%d longest=%d" % [int(lab.get("shortest_path", -1)), int(lab.get("longest_path", -1))])
	other.queue_free()

	# verify Ogg Vorbis audio migration (all streams OGG, loop flags active, zero WAV files)
	var ogg_ok := false
	var hum_s: AudioStream = Sfx.stream("wire_hum_loop")
	var sc_s: AudioStream = Sfx.stream("jumpscare")
	if hum_s is AudioStreamOggVorbis and sc_s is AudioStreamOggVorbis:
		ogg_ok = (hum_s as AudioStreamOggVorbis).loop and not (sc_s as AudioStreamOggVorbis).loop
	var aud_dir := DirAccess.open("res://assets/audio")
	if aud_dir != null:
		aud_dir.list_dir_begin()
		var fname := aud_dir.get_next()
		while fname != "":
			if fname.ends_with(".wav"):
				ogg_ok = false
			fname = aud_dir.get_next()
		aud_dir.list_dir_end()
	check("ogg_audio_only", ogg_ok)

	# a real heart, not a metronome: two pulses (rest and running), both looped,
	# and the fast one has to actually be faster per beat than the resting one
	var hb_slow: AudioStream = Sfx.stream("heartbeat_loop")
	var hb_fast: AudioStream = Sfx.stream("heartbeat_fast_loop")
	var hb_ok := hb_slow is AudioStreamOggVorbis and hb_fast is AudioStreamOggVorbis
	if hb_ok:
		hb_ok = (hb_slow as AudioStreamOggVorbis).loop and (hb_fast as AudioStreamOggVorbis).loop
		hb_ok = hb_ok and (hb_fast as AudioStreamOggVorbis).get_length() < (hb_slow as AudioStreamOggVorbis).get_length()
	check("heartbeat_two_pulses", hb_ok,
		"rest=%.2fs fast=%.2fs" % [
			(hb_slow as AudioStreamOggVorbis).get_length() if hb_slow is AudioStreamOggVorbis else -1.0,
			(hb_fast as AudioStreamOggVorbis).get_length() if hb_fast is AudioStreamOggVorbis else -1.0])

	# verify Slender's BFS corridor steering reaches the Central Sanctum from an outer gate
	var nav_ok := false
	var ent_cells_chk: Array = lab.get("entrance_cells", [])
	if not ent_cells_chk.is_empty():
		var walker: Vector3 = world.map_builder._lab_cell_to_world(ent_cells_chk[0])
		var goal: Vector3 = lab.get("sanctum_pos", Vector3.ZERO)
		var hit_wall := false
		for _step in 450:
			if Vector2(walker.x - goal.x, walker.z - goal.z).length() < 0.8:
				nav_ok = not hit_wall
				break
			var fdir: Vector3 = world.map_builder.labyrinth_flow_dir(walker, goal)
			if fdir == Vector3.ZERO:
				break
			walker += fdir * 0.45
			if world.map_builder.point_in_labyrinth_wall(walker, 0.15):
				hit_wall = true
				break
	check("labyrinth_slender_navigates", nav_ok)

	# outward-winding normal guard across ALL 4 labyrinth meshes (floor, stone, metal, wires)
	var lab_normals_ok := true
	for lnode in [lab_floor_node, lab_mesh_node, lab_metal_node, lab_wires_node]:
		var mnode: MeshInstance3D = lnode
		if mnode == null or not (mnode.mesh is ArrayMesh):
			lab_normals_ok = false
			continue
		var lm_arr := (mnode.mesh as ArrayMesh).surface_get_arrays(0)
		var lverts: PackedVector3Array = lm_arr[Mesh.ARRAY_VERTEX]
		var lnorms: PackedVector3Array = lm_arr[Mesh.ARRAY_NORMAL]
		var lidx: PackedInt32Array = lm_arr[Mesh.ARRAY_INDEX]
		var bad_lab := 0
		for t in lidx.size() / 3:
			var a0: Vector3 = lverts[lidx[t * 3]]
			var a1: Vector3 = lverts[lidx[t * 3 + 1]]
			var a2: Vector3 = lverts[lidx[t * 3 + 2]]
			var g := (a1 - a0).cross(a2 - a0)
			var n_avg := lnorms[lidx[t * 3]] + lnorms[lidx[t * 3 + 1]] + lnorms[lidx[t * 3 + 2]]
			if g.length() > 1e-9 and n_avg.length() > 1e-6 and g.dot(n_avg) <= 0.0:
				bad_lab += 1
		if lidx.size() == 0 or bad_lab > 0:
			lab_normals_ok = false
			print("[selftest]   %s has %d inverted triangles" % [mnode.name, bad_lab])
	check("labyrinth_normals_outward", lab_normals_ok)

	var trees_clear_of_lab := true
	for tp in world.map_builder.tree_positions:
		if world.map_builder.in_labyrinth(tp, 0.5):
			trees_clear_of_lab = false
			break
	check("labyrinth_trees_excluded", trees_clear_of_lab)

	var all_reachable := true
	var stand_space: PhysicsDirectSpaceState3D = world.get_world_3d().direct_space_state
	var cap := CapsuleShape3D.new()
	cap.radius = 0.3
	cap.height = 1.6
	for spot in world.map_builder.page_spots:
		var sp: Vector3 = spot["pos"] + (spot.get("normal", Vector3(0, 0, 1)) as Vector3) * 1.1
		sp.y = 0.0
		if Vector2(sp.x, sp.z).length() > world.map_builder.HALF - 2.0:
			all_reachable = false
			print("[selftest]   page spot outside the map at ", sp)
			continue
		var qs := PhysicsShapeQueryParameters3D.new()
		qs.shape = cap
		qs.collision_mask = 1
		qs.transform = Transform3D(Basis(), sp + Vector3(0, 0.95, 0))
		var hits := stand_space.intersect_shape(qs, 1)
		if hits.size() > 0:
			all_reachable = false
			print("[selftest]   nowhere to stand at ", sp, " for page ", spot.get("name", "?"), " pinned at ", spot["pos"])
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

	# Keep the approved rind/stem material and its companion mesh labels together.
	var pumpkin_material: Material = world.map_builder._mats["pumpkin"]
	check("pumpkin_uses_rind_stem_shader", pumpkin_material is ShaderMaterial and pumpkin_material.shader.resource_path == "res://shaders/pumpkin_skin.gdshader")
	var pumpkin_masks_ok := true
	for mesh in world.map_builder._pumpkin_meshes:
		var arrays: Array = mesh.surface_get_arrays(0)
		var colors = arrays[Mesh.ARRAY_COLOR]
		var has_rind := false
		var has_stem := false
		if colors != null:
			for color in colors:
				has_rind = has_rind or color.a > 0.5
				has_stem = has_stem or color.a < 0.5
		pumpkin_masks_ok = pumpkin_masks_ok and has_rind and has_stem
	check("pumpkin_meshes_have_rind_stem_masks", pumpkin_masks_ok)

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
	# the panels must SPAN the run: their local X has to lie along the fence line
	# and their local Y has to be up. Hand-derived yaw maths got this 90 degrees
	# wrong once already, and it showed up as a fence standing sideways.
	var panels_ok := true
	var worst := 1.0
	for node_name in ["FencePanels", "FenceRails"]:
		var mmi: MultiMeshInstance3D = world.map_builder.get_node_or_null(node_name)
		if mmi == null:
			continue
		var mm: MultiMesh = mmi.multimesh
		for k in mm.instance_count:
			var t3: Transform3D = mm.get_instance_transform(k)
			var xaxis: Vector3 = t3.basis.x.normalized()
			var yaxis: Vector3 = t3.basis.y.normalized()
			var p := t3.origin
			# outward direction of the nearest side of the square ring
			var outd: Vector3 = (Vector3(p.x, 0, 0) if absf(p.x) > absf(p.z) else Vector3(0, 0, p.z)).normalized()
			var flat := absf(xaxis.dot(outd))
			worst = maxf(worst, flat) if not panels_ok else flat
			if flat > 0.15 or absf(yaxis.dot(Vector3.UP)) < 0.95:
				panels_ok = false
				print("[selftest]   panel ", k, " spans the normal: |x.out|=", flat)
	check("fence_panels_follow_the_line", panels_ok)

	check("gate_is_open", gate_clear, str(gate))

	# --- pages: nailed to real surfaces, dark, and carrying their message -----
	var pages_list: Array = world.pages
	var cloth_ok: bool = pages_list.size() >= 8
	var light_free := cloth_ok
	var dark := cloth_ok
	var texted := cloth_ok
	var sags := cloth_ok
	var anchored := cloth_ok
	var space: PhysicsDirectSpaceState3D = world.get_world_3d().direct_space_state
	for p in pages_list:
		var sheet: Node3D = p.get("cloth")
		if sheet == null or sheet.vertex_count() != 63:
			cloth_ok = false
			continue
		if sheet.has_light():
			light_free = false
		if sheet.is_emissive():
			dark = false
		if not sheet.note_is_visible():
			texted = false
		# the page must have a solid surface right behind it: shoot a short ray
		# through the sheet and expect to hit the wall/panel it is nailed to
		var node: Node3D = p["node"]
		var nrm: Vector3 = p["normal"]
		# start outside and cast in: a ray that begins inside the wall reports no
		# hit at all, because only entry faces are detected
		var from: Vector3 = node.global_position + nrm * 0.30
		var to: Vector3 = node.global_position - nrm * 0.30
		var q := PhysicsRayQueryParameters3D.create(from, to)
		var hit := space.intersect_ray(q)
		if hit.is_empty():
			anchored = false
		for k in 90:
			sheet._simulate(1.0 / 60.0)
		var after: PackedVector3Array = sheet.snapshot()
		var top_y: float = after[0].y
		var drop: float = top_y - after[63 - 1].y
		# hangs at least 85% of its length below the nail, and stays finite
		if drop < 0.49 or after[63 - 1].length() > 20.0:
			sags = false
		for v in after:
			if v.z < 0.005:
				sags = false
				break
	check("pages_are_cloth", cloth_ok, "%d pages" % pages_list.size())
	check("pages_have_no_light", light_free)
	check("pages_are_not_emissive", dark)
	check("pages_show_their_note", texted)
	check("pages_pinned_to_surface", anchored, "%d pages" % pages_list.size())
	# the sheet's normals must face OUT of the wall it hangs on. This is the check
	# that catches the inversion: measured in world space against the surface
	# normal the landmark reported, not against the sheet's own winding.
	var facing := cloth_ok
	for p in pages_list:
		var sheet2: Node3D = p.get("cloth")
		var node2: Node3D = p["node"]
		if sheet2 == null:
			continue
		# no extra simulation here: _rebuild() recomputes normals from the live
		# geometry, and stepping the solver would move the sheet away from the
		# frame the rest of the test measured
		sheet2._rebuild()
		var ns: PackedVector3Array = sheet2.surface_normals()
		if ns.size() == 0:
			facing = false
			continue
		var acc2 := Vector3.ZERO
		for nv in ns:
			acc2 += nv
		var world_avg: Vector3 = (node2.global_transform.basis * (acc2 / float(ns.size()))).normalized()
		var surface_n: Vector3 = (p["normal"] as Vector3).normalized()
		if world_avg.dot(surface_n) < 0.9:
			facing = false
			print("[selftest]   page normals face the wall at ", p.get("landmark"), " dot=", world_avg.dot(surface_n))
	check("page_normals_face_outward", facing)

	check("page_cloth_sags", sags)
	var height_ok := true
	for p in pages_list:
		var y: float = (p["node"] as Node3D).global_position.y
		if y < 1.1 or y > 1.9:
			height_ok = false
	check("pages_at_hand_height", height_ok)

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
	# One rule, no platform or device special cases: pointer motion turns the
	# camera unless a finger is down or the pointer is over a widget. (Encoding a
	# touch_mode condition here is what let a real regression through: the camera
	# could not be turned at all on a touch-capable PC.)
	var flick := InputEventMouseMotion.new()
	flick.relative = Vector2(240, 0)
	var yaw_before_flick: float = player.rotation.y
	player._input(flick)
	check("plain_mouse_looks_in_touch_mode",
		absf(player.rotation.y - yaw_before_flick) > 0.1,
		"%.3f rad" % (player.rotation.y - yaw_before_flick))
	# ... except while a finger is actually on the glass: then the overlay owns it
	player.finger_down = true
	var yaw_before_twin: float = player.rotation.y
	var twin := InputEventMouseMotion.new()
	twin.relative = Vector2(240, 0)
	player._input(twin)
	check("finger_down_blocks_mouse_look",
		absf(player.rotation.y - yaw_before_twin) < 0.001,
		"%.3f rad" % (player.rotation.y - yaw_before_twin))
	player.finger_down = false
	# ... holding a button is drag-look, and that does turn the camera
	var drag := InputEventMouseMotion.new()
	drag.relative = Vector2(240, 0)
	drag.button_mask = MOUSE_BUTTON_MASK_LEFT
	var yaw_before_drag: float = player.rotation.y
	player._input(drag)
	check("mouse_drag_reaches_player", absf(player.rotation.y - yaw_before_drag) > 0.1,
		"%.3f rad" % (player.rotation.y - yaw_before_drag))
	Game.touch_mode = was_touch

	# look control (touch swipe path and mouse path share add_look)
	var yaw_before: float = player.rotation.y
	player.add_look(Vector2(200, 0))
	check("look_rotates_player", absf(player.rotation.y - yaw_before) > 0.1, "%.3f rad" % (player.rotation.y - yaw_before))

	# -------------------------------------------------------------- collision
	# walk straight into the outer stone labyrinth wall and verify it stops us
	var walls: Dictionary = world.map_builder.landmarks[0]
	var wall_pos: Vector3 = walls["pos"]
	player.global_position = wall_pos + Vector3(0, 0.15, float(lab.get("half", 12.25)) + 2.6)
	player.rotation.y = 0.0
	await _wait(0.2)
	start = player.global_position
	player.set_touch_move(Vector2(0, -1))
	await _wait(2.0)
	player.set_touch_move(Vector2.ZERO)
	var travelled: float = (player.global_position - start).length()
	check("wall_blocks_player", travelled > 0.5 and travelled < 3.6,
		"travelled %.2f m before stone wall (unblocked ~5.8 m)" % travelled)

	# ground: player stays on the floor
	await _wait(0.3)
	check("player_on_floor", player.is_on_floor(), str(player.global_position.y))

	# ----------------------------------------------------------- reverb zone
	player.global_position = Vector3(0, 0.15, 0)
	await _wait(0.2)
	check("reverb_zone_outside_dry",
		not Sfx.in_reverb_zone() and Sfx.reverb_wet() < 0.01 and Sfx.wind_cutoff_hz() > 18000.0,
		"wet=%.3f lpf=%.0f" % [Sfx.reverb_wet(), Sfx.wind_cutoff_hz()])
	var sanctum_p: Vector3 = lab.get("sanctum_pos", Vector3.ZERO)
	player.global_position = Vector3(sanctum_p.x, 0.15, sanctum_p.z + 1.0)
	await _wait(0.25)
	check("reverb_zone_inside_wet",
		Sfx.in_reverb_zone() and Sfx.reverb_wet() > 0.45 and Sfx.wind_cutoff_hz() < 1200.0
		and lab_rzone.reverb_bus_enabled,
		"wet=%.3f lpf=%.0f" % [Sfx.reverb_wet(), Sfx.wind_cutoff_hz()])
	player.global_position = Vector3(0, 0.15, 0)
	await _wait(0.2)
	check("reverb_zone_exits_clean",
		not Sfx.in_reverb_zone() and Sfx.reverb_wet() < 0.01,
		"wet=%.3f" % Sfx.reverb_wet())

	# ---------------------------------------------------------------- pickups
	world.autotest_no_pickup = false
	var target: Vector3 = (world.pages[0]["node"] as Node3D).global_position
	var tnrm: Vector3 = world.pages[0]["normal"]
	var stand: Vector3 = target + tnrm * 1.1
	player.global_position = Vector3(stand.x, 0.15, stand.z)
	await _wait(0.5)
	check("page_pickup", Game.pages_collected == 1, "collected=%d" % Game.pages_collected)
	check("hud_page_counter", world.hud.pages_label.text == "1 / 8", world.hud.pages_label.text)
	check("note_shown", world.hud.note_body.text != "")
	check("slender_woken", sl.cooldown < 16.0, "cooldown=%.1f" % sl.cooldown)

	# ------------------------------------------------------------------ AI
	# unoccluded in front of the camera -> seen; behind -> unseen.
	# The forest is procedural, so a fixed heading can end up behind a trunk:
	# turn until the sight line is genuinely clear, then assert the mechanism.
	sl.set_process(false)
	sl.visible = true
	var cam: Camera3D = player.camera
	player.global_position = Vector3(0, 0.2, 5.5)
	player.rotation.y = 0.0
	player.head.rotation.x = 0.0
	await _wait(0.3)
	var sight_space: PhysicsDirectSpaceState3D = get_viewport().world_3d.direct_space_state
	var clear_dir := Vector3(0, 0, -1)
	for k in 24:
		var a := TAU * float(k) / 24.0
		var d := Vector3(sin(a), 0, -cos(a))
		sl.global_position = player.global_position + d * 8.0
		var q := PhysicsRayQueryParameters3D.create(cam.global_position, sl.global_position + Vector3(0, 2.2, 0), 1)
		if sight_space.intersect_ray(q).is_empty():
			clear_dir = d
			break
	sl.global_position = player.global_position + clear_dir * 8.0
	player.rotation.y = atan2(-clear_dir.x, -clear_dir.z)
	await _wait(0.3)
	check("slender_seen_in_front", sl._is_seen_by_player(),
		"dir=%s frustum=%s" % [str(clear_dir), str(cam.is_position_in_frustum(sl.global_position + Vector3(0, 2.2, 0)))])
	sl.global_position = player.global_position + clear_dir * -8.0
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
