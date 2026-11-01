extends Node
## Functional self-test suite. Run with:
##   godot --path . res://scenes/World.tscn -- --autotest=selftest
## Verifies world generation, movement, sprint/stamina, collision, pickups,
## Slender visibility AI, death flow and the touch control API.
## Exits 0 when every check passes.

var world: Node = null
var passed := 0
var failed := 0
const PAGE_COLS := 7
const PAGE_ROWS := 9


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


## The gate leaves are part of the fence but are swung into the forest on purpose,
## so the "panels must span the run" check has to skip them.
func _is_gate_leaf(t3: Transform3D, leaves: Array) -> bool:
	for l in leaves:
		if (l as Transform3D).origin.distance_to(t3.origin) < 0.01:
			return true
	return false


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

	# A seeded heightfield must have real relief, stay level at the spawn clearing,
	# and taper to the fence so the chain-link remains planted in the ground.
	var min_height := 999.0
	var max_height := -999.0
	for x in range(-50, 51, 10):
		for z in range(-50, 51, 10):
			var h := float(world.map_builder.ground_height_at(Vector3(float(x), 0.0, float(z))))
			min_height = minf(min_height, h)
			max_height = maxf(max_height, h)
	check("terrain_height_varies", max_height - min_height > 0.45,
		"range=%.2f m (%.2f to %.2f)" % [max_height - min_height, min_height, max_height])
	check("terrain_spawn_clearing_level",
		absf(world.map_builder.ground_height_at(Vector3(0.0, 0.0, 7.0))) < 0.001)
	check("terrain_fence_edge_level",
		absf(world.map_builder.ground_height_at(Vector3(61.0, 0.0, 0.0))) < 0.001)
	var terrain_visual: MeshInstance3D = world.map_builder.get_node_or_null("GroundMesh") as MeshInstance3D
	var terrain_body: StaticBody3D = world.map_builder.get_node_or_null("GroundCollision") as StaticBody3D
	var terrain_collider: CollisionShape3D = terrain_body.get_node_or_null("TerrainTriangles") if terrain_body != null else null
	check("terrain_mesh_and_collision",
		terrain_visual != null and terrain_visual.mesh is ArrayMesh
		and terrain_collider != null and terrain_collider.shape is ConcavePolygonShape3D)
	var terrain_ray := PhysicsRayQueryParameters3D.create(
		Vector3(0.0, 4.0, 0.0), Vector3(0.0, -2.0, 0.0), 4)
	var terrain_hit: Dictionary = get_viewport().world_3d.direct_space_state.intersect_ray(terrain_ray)
	var terrain_hit_pos: Vector3 = terrain_hit.get("position", Vector3.INF)
	check("terrain_collision_ray_hits_surface",
		not terrain_hit.is_empty() and absf(terrain_hit_pos.y) < 0.05,
		str(terrain_hit_pos))

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
	# queue_free is deferred. Without these boundaries the supposedly isolated
	# second map still contributes its colliders to every following physics query,
	# making the real page placements look blocked by duplicate landmarks.
	await get_tree().process_frame
	await get_tree().physics_frame

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
	# the page's ACTUAL anchor (resolved against real collision), not the authored
	# hint: the hint is what the landmark guessed, the anchor is where the sheet
	# ended up, and it is the anchor a player has to be able to walk up to
	for pg in world.pages:
		if not pg.has("anchor_pos"):
			continue
		var sheet: Node3D = pg.get("cloth")
		var sp: Vector3
		if sheet != null and sheet.has_method("is_pinned") and sheet.is_pinned():
			sp = (pg["anchor_pos"] as Vector3) + (pg["normal"] as Vector3) * 1.1
		else:
			sp = sheet.world_center() if sheet != null and sheet.has_method("world_center") else (pg["node"] as Node3D).global_position
			sp += Vector3.UP * 0.8
		sp.y = float(world.map_builder.ground_height_at(sp))
		var spot := {"name": pg.get("landmark", "?")}
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
			print("[selftest]   nowhere to stand in front of page ", spot.get("name", "?"), " at ", sp)
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
		for surface_i in mesh.get_surface_count():
			var arrays := mesh.surface_get_arrays(surface_i)
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
				print("[selftest]   %s surface %d has %d inverted triangles" % [file, surface_i, bad])
	check("mesh_normals_outward", mesh_ok)

	# The stump must keep bark on its sides and use a distinct, correctly mapped
	# end-grain material for the exposed saw-cut top.
	var stump_mesh: Mesh = world.map_builder._props.get("stump")
	var stump_surfaces_ok := stump_mesh != null and stump_mesh.get_surface_count() == 2
	if stump_surfaces_ok:
		stump_surfaces_ok = stump_mesh.surface_get_material(0) == world.map_builder._mats["bark"] \
			and stump_mesh.surface_get_material(1) == world.map_builder._mats["endgrain"]
	check("stump_separate_bark_and_endgrain_surfaces", stump_surfaces_ok)
	var stump_batch := world.map_builder.get_node_or_null("Stumps") as MultiMeshInstance3D
	var stump_batch_ok: bool = stump_batch != null and stump_batch.multimesh != null \
		and stump_batch.multimesh.mesh != null and stump_batch.material_override == null \
		and stump_batch.multimesh.mesh.surface_get_material(1) == world.map_builder._mats["endgrain"]
	check("stump_batch_preserves_endgrain_surface_material", stump_batch_ok)
	var endgrain_material: Material = world.map_builder._mats.get("endgrain")
	var endgrain_pbr_ok := endgrain_material is StandardMaterial3D
	if endgrain_pbr_ok:
		var endgrain_std := endgrain_material as StandardMaterial3D
		endgrain_pbr_ok = endgrain_std.albedo_texture != null \
			and endgrain_std.albedo_texture.resource_path == "res://assets/textures/endgrain_albedo.png" \
			and endgrain_std.normal_texture != null \
			and endgrain_std.roughness_texture != null \
			and not endgrain_std.uv1_triplanar
	check("stump_cut_face_uses_uv_pbr_endgrain", endgrain_pbr_ok)
	var cut_face_ok := false
	if stump_mesh != null and stump_mesh.get_surface_count() == 2:
		var cut_arrays := stump_mesh.surface_get_arrays(1)
		var cut_vertices: PackedVector3Array = cut_arrays[Mesh.ARRAY_VERTEX]
		var cut_normals: PackedVector3Array = cut_arrays[Mesh.ARRAY_NORMAL]
		var cut_uvs: PackedVector2Array = cut_arrays[Mesh.ARRAY_TEX_UV]
		cut_face_ok = cut_vertices.size() > 0 and cut_normals.size() == cut_vertices.size() and cut_uvs.size() == cut_vertices.size()
		for i in cut_vertices.size():
			if cut_normals[i].dot(Vector3.UP) < 0.98 or cut_uvs[i].x < -0.001 or cut_uvs[i].x > 1.001 \
					or cut_uvs[i].y < -0.001 or cut_uvs[i].y > 1.001:
				cut_face_ok = false
				break
	check("stump_cut_face_has_up_normals_and_cap_uvs", cut_face_ok)

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
		# four full sides (the runs now reach the corners), less the gate opening
		var expected: float = 4.0 * (2.0 * world.map_builder.FENCE_SIDE) \
			- 2.0 * world.map_builder.GATE_OPEN_HALF
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
	# The fence is verified from the transforms it was BUILT from, not from the
	# MultiMesh: get_instance_transform() reads back as identity in a headless run,
	# so a check reading the GPU buffer would pass no matter what the fence did.
	var built_panels: Array = world.map_builder.boundary_panels
	check("fence_panels_exist", built_panels.size() > 100, "%d panels" % built_panels.size())

	# 1) each panel must SPAN the run: local X along the fence line, not the normal
	var panels_ok := true
	var worst := 0.0
	var leaves: Array = world.map_builder.boundary_gate_leaves
	for tr in built_panels:
		var t3: Transform3D = tr
		if _is_gate_leaf(t3, leaves):
			continue
		var xaxis: Vector3 = t3.basis.x.normalized()
		var p: Vector3 = t3.origin
		var outd: Vector3 = (Vector3(p.x, 0, 0) if absf(p.x) > absf(p.z) else Vector3(0, 0, p.z)).normalized()
		var flat := absf(xaxis.dot(outd))
		worst = maxf(worst, flat)
		if flat > 0.15 or absf(t3.basis.y.normalized().dot(Vector3.UP)) < 0.95:
			panels_ok = false
	check("fence_panels_follow_the_line", panels_ok, "worst |x.out| = %.3f" % worst)

	# 2) the runs must MEET at the corners: the outermost fabric has to reach the
	# side distance. Each run used to be truncated to a whole number of panels and
	# stopped 1 m short at both ends, leaving a 2x2 m hole at every corner.
	var half_extent := 0.0
	var segs: Array = []
	for tr in built_panels:
		var t3: Transform3D = tr
		var xaxis: Vector3 = t3.basis.x
		var half_len: float = xaxis.length() * 0.5
		var dir: Vector3 = xaxis.normalized()
		segs.append([Vector2(t3.origin.x, t3.origin.z),
			Vector2(dir.x, dir.z), half_len])
		for e in [t3.origin + dir * half_len, t3.origin - dir * half_len]:
			half_extent = maxf(half_extent, maxf(absf(e.x), absf(e.z)))
	var side: float = world.map_builder.FENCE_SIDE
	check("fence_reaches_the_corners", half_extent >= side - 0.15,
		"outer edge %.2f vs side %.2f" % [half_extent, side])

	# 3) walk the perimeter: no point may be more than two thirds of a bay from
	# fabric (the gate opening is the one intended hole, so it is exempt)
	var holes := 0
	var probes := 0
	var bay: float = world.map_builder.PANEL_WIDTH
	for step in 240:
		var a := TAU * float(step) / 240.0
		var dir2 := Vector3(cos(a), 0.0, sin(a))
		var sc: float = side / maxf(absf(dir2.x), absf(dir2.z))
		var p_on: Vector3 = dir2 * sc
		# the gate sits at +X; skip probes across the opening
		if p_on.x > side - 0.5 and absf(p_on.z) < world.map_builder.GATE_OPEN_HALF + 0.2:
			continue
		var p2 := Vector2(p_on.x, p_on.z)
		var nearest := 1e9
		for sg in segs:
			var c2: Vector2 = sg[0]
			var ax2: Vector2 = sg[1]
			var half_len2: float = sg[2]
			var rel := p2 - c2
			var al := clampf(rel.dot(ax2), -half_len2, half_len2)
			nearest = minf(nearest, p2.distance_to(c2 + ax2 * al))
		probes += 1
		if nearest > bay * 0.667:
			holes += 1
	if holes > 0:
		print("[selftest]   ", holes, " of ", probes, " perimeter probes are in a hole")
	check("fence_has_no_corner_holes", holes == 0, "%d/%d open" % [holes, probes])

	check("gate_is_open", gate_clear, str(gate))

	# --- pages: nailed to real surfaces, dark, and carrying their message -----
	var pages_list: Array = world.pages
	var cloth_ok: bool = pages_list.size() >= 8
	var light_free := cloth_ok
	var dark := cloth_ok
	var texted := cloth_ok
	var sags := cloth_ok
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
		for k in 90:
			sheet._simulate(1.0 / 60.0)
		var after: PackedVector3Array = sheet.snapshot()
		# The actual physical nail is at the top-centre vertex, not the top-left
		# corner. Measure the bottom-centre drop from that fixed point.
		var nail_i: int = PAGE_COLS / 2
		var bottom_i: int = (PAGE_ROWS - 1) * PAGE_COLS + nail_i
		var drop: float = after[nail_i].y - after[bottom_i].y
		# hangs at least 85% of its length below the nail, and stays finite
		if drop < 0.49 or after[bottom_i].length() > 20.0:
			sags = false
		for v in after:
			if v.z < 0.005:
				sags = false
				break
	check("pages_are_cloth", cloth_ok, "%d pages" % pages_list.size())
	check("pages_have_no_light", light_free)
	check("pages_are_not_emissive", dark)
	check("pages_show_their_note", texted)
	# A real pin must pass through a visible page into the same world collider at
	# the actual rendered surface. Exclude the nail itself: counting its cylinder
	# as the supporting wall would reproduce the old fake-positive bug.
	var anchored_ok := true
	var pins_ok := true
	var worst_back := 0.0
	var anchored_flags := 0
	var pin_count := 0
	var ps: PhysicsDirectSpaceState3D = world.get_world_3d().direct_space_state
	for pg in world.pages:
		if pg.get("taken", false):
			continue
		var sheet: Node3D = pg.get("cloth")
		var has_anchor: bool = bool(pg.get("anchored", false))
		var pin_rids: Array[RID] = sheet.pin_rids() if sheet != null and sheet.has_method("pin_rids") else []
		if has_anchor:
			anchored_flags += 1
			pin_count += pin_rids.size()
			if not sheet.is_pinned() or pin_rids.size() != 1:
				pins_ok = false
				print("[selftest]   page ", pg.get("landmark", "?"), " has no single physical nail")
			var pin_node: RigidBody3D = sheet.get_node_or_null("PhysicalPageNail") as RigidBody3D
			if pin_node == null or not pin_node.freeze or pin_node.global_position.distance_to(pg["anchor_pos"]) > 0.01:
				pins_ok = false
				print("[selftest]   page ", pg.get("landmark", "?"), " nail is missing, not fixed, or not at the contact")
			if not (pg.get("anchor_mesh") is MeshInstance3D):
				pins_ok = false
				print("[selftest]   page ", pg.get("landmark", "?"), " has no visible host mesh")
			var ap: Vector3 = pg["anchor_pos"]
			var an: Vector3 = (pg["normal"] as Vector3).normalized()
			var from: Vector3 = ap + an * 0.30
			var to: Vector3 = ap - an * 0.30
			var q2 := PhysicsRayQueryParameters3D.create(from, to, 1)
			q2.exclude = pin_rids
			var h2 := ps.intersect_ray(q2)
			if h2.is_empty():
				anchored_ok = false
				print("[selftest]   page ", pg.get("landmark", "?"), " has no host collision behind the pin")
				continue
			if h2.get("collider") != pg.get("anchor_body"):
				anchored_ok = false
				print("[selftest]   page ", pg.get("landmark", "?"), " pin hits a different body")
			var back: float = (h2["position"] as Vector3).distance_to(ap)
			worst_back = maxf(worst_back, back)
			if back > 0.16:
				anchored_ok = false
				print("[selftest]   page ", pg.get("landmark", "?"), " floats ", back, " m off collision")
			var hn: Vector3 = h2["normal"]
			if hn.dot(an) < 0.65:
				anchored_ok = false
				print("[selftest]   page ", pg.get("landmark", "?"), " nail is not entering its host surface")
			var visual: Dictionary = world._visible_anchor_surface(h2["collider"], from, to, h2["position"], hn)
			if visual.is_empty() or (visual["pos"] as Vector3).distance_to(ap) > 0.08 \
					or visual.get("mesh") != pg.get("anchor_mesh"):
				anchored_ok = false
				print("[selftest]   page ", pg.get("landmark", "?"), " pin is not at its visible host mesh")
		else:
			# No visual surface/collider was found: this page must be genuinely loose,
			# never held by invisible constraints pretending to be a nail.
			if sheet != null and (sheet.is_pinned() or not pin_rids.is_empty()):
				pins_ok = false
				print("[selftest]   loose page ", pg.get("landmark", "?"), " still has a pin")
	check("pages_hang_on_real_geometry", anchored_ok,
		"%d anchored, worst collision offset %.3f m" % [anchored_flags, worst_back])
	check("pages_have_physical_pins", pins_ok, "%d real nails" % pin_count)

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
		var page_pos: Vector3 = (p["node"] as Node3D).global_position
		var y := page_pos.y - float(world.map_builder.ground_height_at(page_pos))
		if y < 1.1 or y > 1.9:
			height_ok = false
	check("pages_at_hand_height", height_ok)

	# --- outside the fence: endless terrain + the road out of the gate --------
	var st: Dictionary = world.terrain.stats() if world.terrain != null else {}
	var terrain_ok: bool = not st.is_empty() and int(st.get("chunks", 0)) >= 9
	check("terrain_chunks", terrain_ok, str(st.get("chunks", 0)))
	var outside_heightfield_collision := false
	for chunk in world.terrain._chunks.values():
		if chunk.get_meta("arena", false):
			continue
		var outside_ground: StaticBody3D = chunk.get_node_or_null("GroundCollision") as StaticBody3D
		var outside_shape: CollisionShape3D = outside_ground.get_child(0) as CollisionShape3D if outside_ground != null else null
		if outside_shape != null and outside_shape.shape is ConcavePolygonShape3D:
			outside_heightfield_collision = true
	check("outside_heightfield_has_mesh_collision", outside_heightfield_collision)
	var outside_probe := Vector3(66.0, 0.0, 0.0)
	var outside_height := float(world.map_builder.ground_height_at(outside_probe))
	var outside_ray := PhysicsRayQueryParameters3D.create(
		Vector3(outside_probe.x, outside_height + 3.0, outside_probe.z),
		Vector3(outside_probe.x, outside_height - 2.0, outside_probe.z), 4)
	var outside_hit: Dictionary = get_viewport().world_3d.direct_space_state.intersect_ray(outside_ray)
	var outside_hit_pos: Vector3 = outside_hit.get("position", Vector3.INF)
	check("outside_terrain_collision_matches_height",
		not outside_hit.is_empty() and absf(outside_hit_pos.y - outside_height) < 0.05,
		"sample=%.3f hit=%s" % [outside_height, str(outside_hit_pos)])
	var outside_tree_count := int(st.get("trees", 0))
	check("terrain_has_trees", outside_tree_count > 300, str(outside_tree_count))
	var outside_collider_count := int(st.get("tree_colliders", 0))
	check("outside_trees_have_real_mesh_colliders",
		outside_collider_count == outside_tree_count and outside_tree_count > 300,
		"%d concave mesh colliders for %d trees" % [outside_collider_count, outside_tree_count])
	var outside_assets_match: bool = world.terrain._trees.size() == world.map_builder._tree_meshes.size()
	if outside_assets_match:
		for i in world.terrain._trees.size():
			outside_assets_match = outside_assets_match and world.terrain._trees[i].resource_path == world.map_builder._tree_meshes[i].resource_path
	check("outside_tree_meshes_match_inside", outside_assets_match)
	check("outside_tree_material_matches_inside", world.terrain.tree_mat == world.map_builder._mats["bark"])
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
	var inside_tree_body := world.map_builder.get_node_or_null("TreeCollision") as StaticBody3D
	var inside_mesh_colliders := 0
	var inside_tree_collision_ok := inside_tree_body != null
	if inside_tree_body != null:
		for child in inside_tree_body.get_children():
			if not child is CollisionShape3D or not (child as CollisionShape3D).shape is ConcavePolygonShape3D:
				inside_tree_collision_ok = false
				continue
			var cs := child as CollisionShape3D
			var mesh_shape := cs.shape as ConcavePolygonShape3D
			inside_tree_collision_ok = inside_tree_collision_ok and mesh_shape.get_faces().size() >= 3
			if inside_mesh_colliders < world.map_builder.tree_collision_instances.size():
				var expected_xf: Transform3D = world.map_builder.tree_collision_instances[inside_mesh_colliders]["transform"]
				inside_tree_collision_ok = inside_tree_collision_ok \
					and cs.transform.origin.distance_to(expected_xf.origin) < 0.001 \
					and cs.transform.basis.x.distance_to(expected_xf.basis.x) < 0.001 \
					and cs.transform.basis.y.distance_to(expected_xf.basis.y) < 0.001 \
					and cs.transform.basis.z.distance_to(expected_xf.basis.z) < 0.001
			inside_mesh_colliders += 1
	inside_tree_collision_ok = inside_tree_collision_ok \
		and inside_mesh_colliders == world.map_builder.tree_collision_instances.size() \
		and inside_mesh_colliders == world.map_builder.tree_count()
	check("inside_trees_use_visible_mesh_colliders", inside_tree_collision_ok,
		"%d mesh colliders" % inside_mesh_colliders)
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
	player.global_position = world.ground_position(Vector3.ZERO, 0.2)
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
	player.global_position = world.ground_position(Vector3.ZERO, 0.2)
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
	var wall_stand := wall_pos + Vector3(0.0, 0.0, float(lab.get("half", 12.25)) + 2.6)
	player.global_position = world.ground_position(wall_stand, 0.15)
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
	player.global_position = world.ground_position(Vector3.ZERO, 0.15)
	await _wait(0.2)
	check("reverb_zone_outside_dry",
		not Sfx.in_reverb_zone() and Sfx.reverb_wet() < 0.01 and Sfx.wind_cutoff_hz() > 18000.0,
		"wet=%.3f lpf=%.0f" % [Sfx.reverb_wet(), Sfx.wind_cutoff_hz()])
	var sanctum_p: Vector3 = lab.get("sanctum_pos", Vector3.ZERO)
	player.global_position = world.ground_position(
		Vector3(sanctum_p.x, 0.0, sanctum_p.z + 1.0), 0.15)
	await _wait(0.25)
	check("reverb_zone_inside_wet",
		Sfx.in_reverb_zone() and Sfx.reverb_wet() > 0.45 and Sfx.wind_cutoff_hz() < 1200.0
		and lab_rzone.reverb_bus_enabled,
		"wet=%.3f lpf=%.0f" % [Sfx.reverb_wet(), Sfx.wind_cutoff_hz()])
	player.global_position = world.ground_position(Vector3.ZERO, 0.15)
	await _wait(0.2)
	check("reverb_zone_exits_clean",
		not Sfx.in_reverb_zone() and Sfx.reverb_wet() < 0.01,
		"wet=%.3f" % Sfx.reverb_wet())

	# ---------------------------------------------------------------- pickups
	var target: Vector3 = (world.pages[0]["node"] as Node3D).global_position
	var tnrm: Vector3 = world.pages[0]["normal"]
	var stand: Vector3 = target + tnrm * 1.1
	player.global_position = world.ground_position(Vector3(stand.x, 0.0, stand.z), 0.15)
	await _wait(0.4)
	var sheet_pick: Node3D = world.pages[0]["cloth"]
	var pin_body: RigidBody3D = sheet_pick.get_node_or_null("PhysicalPageNail") as RigidBody3D
	var center_before: Vector3 = sheet_pick.world_center()
	world.try_pickup(player) # first interaction removes the real nail
	await _wait(0.25)
	var unpin_motion: float = center_before.distance_to(sheet_pick.world_center())
	var unpinned_ok: bool = not sheet_pick.is_pinned() and pin_body != null \
		and not pin_body.freeze and unpin_motion > 0.05
	world.try_pickup(player) # second interaction takes the loose sheet
	check("page_can_be_unpinned", unpinned_ok, "cloth moved %.2f m" % unpin_motion)
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
	player.global_position = world.ground_position(Vector3(0.0, 0.0, 5.5), 0.2)
	player.rotation.y = 0.0
	player.head.rotation.x = 0.0
	await _wait(0.3)
	var sight_space: PhysicsDirectSpaceState3D = get_viewport().world_3d.direct_space_state
	var clear_dir := Vector3(0, 0, -1)
	for k in 24:
		var a := TAU * float(k) / 24.0
		var d := Vector3(sin(a), 0.0, -cos(a))
		sl.global_position = world.ground_position(player.global_position + d * 8.0, 0.0)
		var q := PhysicsRayQueryParameters3D.create(cam.global_position, sl.global_position + Vector3(0, 2.2, 0), 1)
		if sight_space.intersect_ray(q).is_empty():
			clear_dir = d
			break
	sl.global_position = world.ground_position(player.global_position + clear_dir * 8.0, 0.0)
	player.rotation.y = atan2(-clear_dir.x, -clear_dir.z)
	await _wait(0.3)
	check("slender_seen_in_front", sl._is_seen_by_player(),
		"dir=%s frustum=%s" % [str(clear_dir), str(cam.is_position_in_frustum(sl.global_position + Vector3(0, 2.2, 0)))])
	sl.global_position = world.ground_position(player.global_position + clear_dir * -8.0, 0.0)
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
	sl.global_position = world.ground_position(
		player.global_position + Vector3(0.0, 0.0, -2.0), 0.0)
	sl.force_chase()
	await _wait(3.5)
	check("caught_by_slender", sl.dead)
	check("death_screen", world.hud.end_root.visible)
	check("death_title", world.hud.end_title.text == "HE FOUND YOU", world.hud.end_title.text)
