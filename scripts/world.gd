extends Node3D
## The run: builds the forest, spawns the eight pages, drives Slender,
## static/heartbeat feedback and the win/lose flow.

const INTERACT_RADIUS := 2.8

const PAGE_NOTES := [
	"1\n\nHELP ME.\n\nI cannot find the way out. The trees keep moving.",
	"2\n\nHe is tall. Taller than the trees.\n\nDo not look at his face.",
	"3\n\nIt only moves when you look away.\n\nKeep your eyes on the path.",
	"4\n\nI counted eight. There were eight.\n\nNow there are seven.",
	"5\n\nDon't run. He hears running.\n\nWalk. Breathe. Count.",
	"6\n\nThe static in your ears is his voice.\n\nWhen it gets loud, close your eyes.",
	"7\n\nIt is always behind you.\n\nAlways.",
	"8\n\nI found them all. Eight pages.\n\nWhy is he still here?",
]

@onready var map_builder: Node3D = $MapBuilder
var terrain: Node3D = null
@onready var player: CharacterBody3D = $Player
@onready var slender: Node3D = $Slender
@onready var hud: CanvasLayer = $HUD

var pages: Array[Dictionary] = []
var near_page := -1
var world_seed := 0
var touch_ui: Node = null

var _ended := false
var _paused := false
var _start_grace := 0.0
var _autotest: Node = null
var _toast_shown := false
var _objective_stage := 0
var _page_mesh_faces: Dictionary = {}


func _ready() -> void:
	Game.begin_run()
	world_seed = randi()
	if Game.autotest:
		world_seed = 20261030
		# --seed=N lets a run be reproduced (and lets the page-anchor check be
		# swept across layouts instead of trusted on a single lucky seed)
		for a in OS.get_cmdline_user_args():
			if a.begins_with("--seed="):
				world_seed = int(a.get_slice("=", 1))
	_setup_environment()
	_setup_moon()
	map_builder.build(world_seed, Game.quality)
	_setup_terrain()
	# pages resolve their anchor against live collision, so this waits a physics frame
	await _spawn_pages()
	player.global_position = Vector3(0, 0.15, 2.0)
	player.rotation.y = 0.0
	# the camera rig was built during scene load, before the player was placed:
	# re-seat it so the tether's frame matches where we actually stand
	if player.handle != null:
		player.handle.snap()

	slender.setup(player, self, map_builder)
	slender.activate()
	slender.caught_player.connect(_on_caught)
	slender.slender_seen.connect(_on_slender_visibility)
	slender.apparition_started.connect(_on_slender_apparition)

	_connect_hud()
	hud.set_pages(0, Game.TOTAL_PAGES)
	hud.set_touch_ui(Game.touch_mode)
	hud.set_objective("FIND THE EIGHT PAGES")
	_update_touch_toggle_label()

	if Game.touch_mode:
		touch_ui = load("res://scripts/touch_controls.gd").new()
		touch_ui.set_player(player)
		touch_ui.hud = hud
		add_child(touch_ui)
	_sync_pointer()

	Sfx.resume_ambience()
	Sfx.set_loop_volume("static_loop", -60.0)
	Sfx.set_heartbeat(0.0, -60.0)

	if Game.autotest:
		var mode := ""
		for a in OS.get_cmdline_user_args():
			if a.begins_with("--autotest="):
				mode = a.get_slice("=", 1)
		# "flow" is driven by flowtest.gd from the title screen; it must not
		# spawn a second runner inside the world
		var flow := "--flow" in OS.get_cmdline_user_args()
		if mode != "flow" and not flow:
			var script_path := "res://scripts/autotest.gd"
			if mode == "selftest":
				script_path = "res://scripts/selftest.gd"
			elif mode == "camtest":
				script_path = "res://scripts/camera_test.gd"
			elif mode == "mouselive":
				script_path = "res://scripts/mouse_live.gd"
			elif mode == "controls":
				script_path = "res://scripts/controls_test.gd"
			_autotest = load(script_path).new()
			_autotest.world = self
			add_child(_autotest)


func _connect_hud() -> void:
	hud.resume_pressed.connect(_resume)
	hud.pause_toggled.connect(_toggle_pause)
	hud.restart_pressed.connect(_restart)
	hud.menu_pressed.connect(_to_title)
	hud.touch_toggle_pressed.connect(_toggle_touch_mode)
	hud.camcorder_toggled.connect(_toggle_camcorder_fx)
	hud.handheld_toggled.connect(_toggle_handheld_camera)


# --------------------------------------------------------------------------- #
# scenery
# --------------------------------------------------------------------------- #
func _setup_environment() -> void:
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color(0.012, 0.015, 0.021)
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.17, 0.22, 0.33)
	env.ambient_light_energy = 0.42
	env.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	env.tonemap_exposure = 1.02
	env.fog_enabled = true
	env.fog_light_color = Color(0.014, 0.018, 0.026)
	env.fog_light_energy = 0.38
	env.fog_density = 0.062 if Game.quality >= 1 else 0.072
	env.fog_sky_affect = 1.0
	env.fog_aerial_perspective = 0.4
	env.glow_enabled = Game.quality >= 2
	env.glow_intensity = 0.32
	var we := WorldEnvironment.new()
	we.environment = env
	add_child(we)
	if player != null and player.camera != null:
		player.camera.far = 70.0 if Game.quality >= 1 else 55.0


## One owner for the pointer, with no per-platform branches: the forest holds a
## captured pointer only while the run is live and no screen is asking to be
## clicked. Menus, end screens and the pause state all release it, which is what
## keeps the cursor usable on the death screen and gives it back when you resume.
func _sync_pointer() -> void:
	var want := Game.run_active and not _paused and not _ended and not Game.ui_blocking
	var mode := Input.MOUSE_MODE_CAPTURED if want else Input.MOUSE_MODE_VISIBLE
	if Input.mouse_mode != mode:
		Input.mouse_mode = mode


func _setup_terrain() -> void:
	terrain = load("res://scripts/endless_terrain.gd").new()
	terrain.name = "Terrain"
	add_child(terrain)
	terrain.setup(map_builder, player, Game.quality)


func _setup_moon() -> void:
	var moon := DirectionalLight3D.new()
	moon.light_color = Color(0.52, 0.62, 0.92)
	moon.light_energy = 0.24
	moon.rotation = Vector3(deg_to_rad(-58), deg_to_rad(28), 0)
	moon.shadow_enabled = Game.quality >= 2
	moon.directional_shadow_max_distance = 60.0
	moon.directional_shadow_mode = DirectionalLight3D.SHADOW_ORTHOGONAL
	add_child(moon)


## Support methods for resolving page nails against actual rendered mesh and
## physics collision. Landmark coordinates are only search hints: randomized
## dimensions can put a hint in air, and a collider alone is insufficient if no
## rendered surface exists at the point.
func _collect_anchor_meshes(node: Node, out: Array) -> void:
	for child in node.get_children():
		if child is MeshInstance3D and child.mesh != null:
			out.append(child)
		_collect_anchor_meshes(child, out)


func _mesh_faces(mesh: Mesh) -> PackedVector3Array:
	var key: int = mesh.get_instance_id()
	if _page_mesh_faces.has(key):
		return _page_mesh_faces[key]
	var faces: PackedVector3Array = mesh.get_faces()
	_page_mesh_faces[key] = faces
	return faces


## Match a collision ray to the visible triangle on the same body. The returned
## point and normal are from the rendered mesh, not an authored hint or an
## oversized primitive collider.
func _visible_anchor_surface(collider: Object, from: Vector3, to: Vector3,
		collision_point: Vector3, collision_normal: Vector3) -> Dictionary:
	if not collider is Node:
		return {}
	# Most landmark props keep their mesh under the StaticBody. The labyrinth is
	# intentionally batched, however, so its collision body and visible mesh are
	# siblings under MapBuilder. Search the collider's owner-level subtree and use
	# a segment/AABB broad phase before looking at any triangles.
	var root: Node = collider as Node
	if root.get_parent() != null:
		root = root.get_parent()
	var meshes: Array = []
	_collect_anchor_meshes(root, meshes)
	var seg_min := Vector3(minf(from.x, to.x), minf(from.y, to.y), minf(from.z, to.z))
	var seg_max := Vector3(maxf(from.x, to.x), maxf(from.y, to.y), maxf(from.z, to.z))
	var seg_box := AABB(seg_min, seg_max - seg_min).grow(0.02)
	var best: Dictionary = {}
	var best_error := 1e9
	for mi in meshes:
		var mesh: Mesh = mi.mesh
		var local_aabb: AABB = mi.get_aabb()
		var minp := Vector3.ZERO
		var maxp := Vector3.ZERO
		for corner_i in 8:
			var corner := Vector3(
				local_aabb.position.x + local_aabb.size.x * float(corner_i & 1),
				local_aabb.position.y + local_aabb.size.y * float((corner_i >> 1) & 1),
				local_aabb.position.z + local_aabb.size.z * float((corner_i >> 2) & 1))
			var wp: Vector3 = mi.global_transform * corner
			if corner_i == 0:
				minp = wp
				maxp = wp
			else:
				minp = minp.min(wp)
				maxp = maxp.max(wp)
		var world_aabb := AABB(minp, maxp - minp)
		if not world_aabb.intersects(seg_box):
			continue
		var faces := _mesh_faces(mesh)
		if faces.size() < 3:
			continue
		var mesh_xf: Transform3D = mi.global_transform
		var inv := mesh_xf.affine_inverse()
		var local_from: Vector3 = inv * from
		var local_to: Vector3 = inv * to
		for fi in range(0, faces.size() - 2, 3):
			var a: Vector3 = faces[fi]
			var b: Vector3 = faces[fi + 1]
			var c: Vector3 = faces[fi + 2]
			var local_hit: Variant = Geometry3D.segment_intersects_triangle(local_from, local_to, a, b, c)
			if not local_hit is Vector3:
				continue
			var world_hit: Vector3 = mesh_xf * (local_hit as Vector3)
			var error: float = world_hit.distance_to(collision_point)
			# Chamfered blocks intentionally have a little collider/mesh offset;
			# still reject surfaces whose rendered skin is materially elsewhere.
			if error > 0.16 or error >= best_error:
				continue
			var local_n := (b - a).cross(c - a).normalized()
			if local_n.length_squared() < 0.5:
				continue
			var world_n: Vector3 = (mesh_xf.basis.inverse().transposed() * local_n).normalized()
			if world_n.dot(collision_normal) < 0.0:
				world_n = -world_n
			if world_n.dot(collision_normal) < 0.65:
				continue
			best_error = error
			best = {"pos": world_hit, "normal": world_n, "body": collider,
				"collision_pos": collision_point, "mesh": mi}
	return best


func _anchor_ray(space: PhysicsDirectSpaceState3D, from: Vector3, to: Vector3,
		required_body: Object = null) -> Dictionary:
	var q := PhysicsRayQueryParameters3D.create(from, to, 1)
	var hit := space.intersect_ray(q)
	if hit.is_empty():
		return {}
	var body: Object = hit.get("collider")
	if required_body != null and body != required_body:
		return {}
	return _visible_anchor_surface(body, from, to, hit["position"], hit["normal"])


## Is there space for the player's actual capsule in front of this surface?
func _stand_room(space: PhysicsDirectSpaceState3D, p: Vector3, n: Vector3) -> bool:
	var stand := p + n * 1.1
	stand.y = 0.0
	var cap := CapsuleShape3D.new()
	cap.radius = 0.3
	cap.height = 1.6
	var q := PhysicsShapeQueryParameters3D.new()
	q.shape = cap
	q.collision_mask = 1
	q.transform = Transform3D(Basis(), stand + Vector3(0, 0.95, 0))
	return space.intersect_shape(q, 1).is_empty()


## A long candidate ray can hit a different overlapping box of the same landmark.
## Recast through the candidate itself and require the first real collision to
## belong to the visible point we chose, not merely to some nearby part of the
## same StaticBody3D.
func _anchor_contacts_exactly(space: PhysicsDirectSpaceState3D, candidate: Dictionary) -> bool:
	var p: Vector3 = candidate["pos"]
	var n: Vector3 = (candidate["normal"] as Vector3).normalized()
	var body: Object = candidate["body"]
	var from: Vector3 = p + n * 0.30
	var to: Vector3 = p - n * 0.30
	var q := PhysicsRayQueryParameters3D.create(from, to, 1)
	var hit := space.intersect_ray(q)
	if hit.is_empty() or hit.get("collider") != body:
		return false
	var visual: Dictionary = _visible_anchor_surface(body, from, to, hit["position"], hit["normal"])
	return not visual.is_empty() and (visual["pos"] as Vector3).distance_to(p) <= 0.08


## Surface placement is a physics operation: cast against the current scene,
## match that hit to actual visible triangles, and choose an accessible point on
## the same physical object. If no visible surface with collision can be found,
## return `anchored=false`; the page is then loose and receives no fake pin.
func _resolve_anchor(authored: Vector3, normal: Vector3) -> Dictionary:
	var space: PhysicsDirectSpaceState3D = get_world_3d().direct_space_state
	var n := normal.normalized()
	var h_target: float = clampf(authored.y, 1.30, 1.65)
	var center := Vector3(authored.x, h_target, authored.z)
	var primary := _anchor_ray(space, center + n * 1.5, center - n * 1.0)
	var preferred_body: Object = primary.get("body")
	var candidates: Array[Dictionary] = []
	if not primary.is_empty():
		candidates.append(primary)

	# Sweep the actual surface in tangent/height space. This is needed when the
	# authored point lands on a prop edge, or the nearest standing position is
	# blocked by a tree. Every candidate still has to ray-hit collision AND a
	# rendered triangle on the same object.
	var tangent := Vector3(n.z, 0.0, -n.x).normalized()
	if tangent.length_squared() < 0.5:
		tangent = Vector3.RIGHT
	var offsets := [-1.2, -0.8, -0.4, 0.4, 0.8, 1.2]
	for yoff in [-0.25, 0.0, 0.25]:
		for along in offsets:
			var probe: Vector3 = center + tangent * along + Vector3.UP * yoff
			var c := _anchor_ray(space, probe + n * 1.5, probe - n * 1.0, preferred_body)
			if not c.is_empty():
				candidates.append(c)

	# Curved shells and irregular ruins need a radial sweep too. Prefer the
	# original collider first; the second pass can use any nearby visible surface
	# only when the landmark's own surface is physically inaccessible.
	for ring in [0.45, 0.9, 1.4, 2.0, 2.7]:
		for k in 16:
			var a := TAU * float(k) / 16.0
			var d := Vector3(cos(a), 0.0, sin(a))
			var probe: Vector3 = center + d * ring
			var c := _anchor_ray(space, probe + d * 1.5, probe - d * 1.0, preferred_body)
			if not c.is_empty():
				candidates.append(c)

	# Deduplicate and choose the nearest candidate with genuine player clearance.
	var best: Dictionary = {}
	var best_d := 1e9
	var seen: Array[Vector3] = []
	for c in candidates:
		var p: Vector3 = c["pos"]
		var cn: Vector3 = (c["normal"] as Vector3).normalized()
		if cn.y > 0.62 or cn.y < -0.35:
			continue
		var duplicate := false
		for prior in seen:
			if p.distance_to(prior) < 0.08:
				duplicate = true
				break
		if duplicate:
			continue
		seen.append(p)
		if not _anchor_contacts_exactly(space, c):
			continue
		if not _stand_room(space, p, cn):
			continue
		var d2: float = p.distance_to(authored)
		if d2 < best_d:
			best_d = d2
			best = c
	if not best.is_empty():
		best["anchored"] = true
		return best

	# Last chance: search nearby real geometry without insisting on the first
	# body. Do not turn an inaccessible hint into a fake pin; if this also fails,
	# the page is spawned loose and the cloth is free to move.
	if preferred_body != null:
		var free_body_candidates: Array[Dictionary] = []
		for ring in [0.8, 1.6, 2.4, 3.2]:
			for k in 24:
				var a := TAU * float(k) / 24.0
				var d := Vector3(cos(a), 0.0, sin(a))
				var probe: Vector3 = center + d * ring
				var c := _anchor_ray(space, probe + d * 1.6, probe - d * 1.0)
				if not c.is_empty():
					free_body_candidates.append(c)
		var fallback: Dictionary = {}
		var fallback_d := 1e9
		for c in free_body_candidates:
			var p: Vector3 = c["pos"]
			var cn: Vector3 = (c["normal"] as Vector3).normalized()
			if absf(cn.y) > 0.62 or not _anchor_contacts_exactly(space, c) or not _stand_room(space, p, cn):
				continue
			var d2: float = p.distance_to(authored)
			if d2 < fallback_d:
				fallback_d = d2
				fallback = c
		if not fallback.is_empty():
			fallback["anchored"] = true
			fallback["fallback_surface"] = true
			return fallback

	return {"pos": authored + n * 1.5, "normal": n, "body": null, "anchored": false}


func _spawn_pages() -> void:
	var spots: Array = map_builder.page_spots
	# PhysicsServer registers the thousands of tree/prop/map colliders at the end
	# of a step; wait two full steps before choosing a physical nail point.
	await get_tree().physics_frame
	await get_tree().physics_frame
	var note_order := range(spots.size())
	var nrng := Game.rng()
	for i in range(note_order.size() - 1, 0, -1):
		var j := nrng.randi_range(0, i)
		var tmp: int = note_order[i]
		note_order[i] = note_order[j]
		note_order[j] = tmp
	var cloth_script: Script = load("res://scripts/page_cloth.gd")
	for i in spots.size():
		var spot: Dictionary = spots[i]
		var note_index: int = note_order[i] if i < note_order.size() else 0
		var note: String = PAGE_NOTES[note_index % PAGE_NOTES.size()]
		var root := Node3D.new()
		root.name = "Page_%d" % i
		# A pin is spawned only after the hint has been resolved to a real rendered
		# triangle and the same surface's physics collider, with standing clearance.
		# `pos` is that exact visible contact point; the physical nail enters it.
		var authored: Vector3 = spot["pos"]
		var hint_n: Vector3 = spot.get("normal", Vector3(0, 0, 1))
		var anchor := _resolve_anchor(authored, hint_n)
		var pos: Vector3 = anchor["pos"]
		var n: Vector3 = (anchor["normal"] as Vector3).normalized()
		if not anchor["anchored"]:
			push_warning("page %d (%s): no surface found near %s - it is not attached"
				% [i, spot["name"], authored])
		# Construct a full surface frame: local +Z is the actual mesh normal, and
		# local +Y is world-up projected onto the surface. The origin is the actual
		# visual/collision contact point; no guessed 3.5 cm air gap.
		var z_axis := n
		var x_axis := Vector3.UP.cross(z_axis).normalized()
		if x_axis.length_squared() < 0.5:
			x_axis = Vector3.RIGHT
		var y_axis := z_axis.cross(x_axis).normalized()
		var basis := Basis(x_axis, y_axis, z_axis).orthonormalized()
		root.transform = Transform3D(basis, pos)
		var sheet: Node3D = cloth_script.new()
		sheet.name = "Sheet"
		sheet.set("hang_phase", randf() * TAU)
		sheet.set("note_index", (note_index % PAGE_NOTES.size()) + 1)
		sheet.set("pin_at_spawn", bool(anchor["anchored"]))
		sheet.set("floor_height", 0.0)
		root.add_child(sheet)
		add_child(root)
		pages.append({
			"node": root,
			"cloth": sheet,
			"note": note,
			"normal": n,
			"landmark": spot["name"],
			"taken": false,
			"anchored": anchor["anchored"],
			"anchor_pos": pos,
			"anchor_body": anchor.get("body"),
			"anchor_mesh": anchor.get("mesh"),
			"phase": randf() * TAU,
		})


# --------------------------------------------------------------------------- #
# frame update
# --------------------------------------------------------------------------- #
func _process(delta: float) -> void:
	if _ended:
		return
	_start_grace += delta
	_update_pages(delta)
	_update_feedback(delta)
	_update_hud()

	if _start_grace > 3.0 and not _toast_shown:
		_toast_shown = true
		hud.show_toast("FIND THE EIGHT PAGES  —  DO NOT STARE AT HIM", 5.0)


func _update_pages(_delta: float) -> void:
	near_page = -1
	var best := INF
	for i in pages.size():
		var p: Dictionary = pages[i]
		if p["taken"]:
			continue
		var sheet: Node3D = p.get("cloth")
		var center: Vector3 = sheet.world_center() if sheet != null and sheet.has_method("world_center") 			else (p["node"] as Node3D).global_position
		var d := player.global_position.distance_to(center)
		# A nailed page is never silently collected on proximity: the player first
		# has to pull the visible nail, then explicitly take the loose sheet.
		if d < INTERACT_RADIUS and d < best:
			best = d
			near_page = i
	var prompt := ""
	var touch_action := "TAKE"
	if near_page >= 0:
		var page_sheet: Node3D = pages[near_page].get("cloth")
		var pinned: bool = page_sheet != null and page_sheet.has_method("is_pinned") and page_sheet.is_pinned()
		if pinned:
			prompt = "TAP  UNPIN" if Game.touch_mode else "E  —  PULL THE PIN"
			touch_action = "UNPIN"
		else:
			prompt = "TAP  TAKE" if Game.touch_mode else "E  —  TAKE PAGE"
		hud.show_prompt(prompt)
	else:
		hud.show_prompt("")
	if touch_ui != null:
		touch_ui.set_pickup_available(near_page >= 0, touch_action)

func _update_feedback(delta: float) -> void:
	var diff := Game.difficulty()
	var intensity := 0.03 + 0.42 * diff
	var dist := 9999.0
	var seen := false
	if slender.visible:
		dist = player.global_position.distance_to(slender.global_position)
		seen = slender.visible_now
		var proximity := clampf(1.0 - dist / 32.0, 0.0, 1.0)
		intensity += proximity * 0.5
		if seen:
			intensity += 0.32 + clampf(slender.seen_time, 0.0, 3.0) * 0.1
	if slender.mode == slender.Mode.CHASE:
		intensity += 0.28
	intensity = clampf(intensity, 0.0, 0.85)
	hud.set_static(intensity)

	# the camcorder reacts to the same danger: tape damage, tearing, signal
	# loss, a zoom creep and the IR lamp when the torch is off
	var dread := clampf((intensity - 0.06) / 0.72, 0.0, 1.0)
	if slender.mode == slender.Mode.CHASE:
		dread = maxf(dread, 0.85)
	hud.set_dread(dread)
	hud.set_camcorder_ir(not player.flashlight_on)

	# audio: heartbeat + static + drone get louder as he closes in. The pulse
	# itself is driven by the body, not only by him: sprinting empties the
	# stamina bar, and an empty bar is a running heart whether or not anything
	# is chasing you.
	var heartbeat := -60.0
	if slender.visible and dist < 34.0:
		heartbeat = lerpf(-40.0, -6.0, clampf(1.0 - dist / 34.0, 0.0, 1.0))
	if slender.mode == slender.Mode.CHASE:
		heartbeat = -4.0
	var exertion := clampf(1.0 - player.stamina / player.STAMINA_MAX, 0.0, 1.0)
	var pulse := maxf(dread, exertion * 0.8)
	if exertion > 0.15 and heartbeat < -40.0:
		# being winded is audible on its own, quietly, at the bottom of the mix
		heartbeat = lerpf(-46.0, -26.0, exertion)
	Sfx.set_heartbeat(pulse, heartbeat)
	Sfx.set_loop_volume("static_loop", -60.0 + 52.0 * clampf(intensity, 0.0, 1.0))
	Sfx.set_loop_volume("drone_loop", -18.0 + 9.0 * diff)

	# flashlight dies out when he is close and you can see him
	if slender.visible and seen and dist < 26.0:
		player.flicker = lerpf(player.flicker, clampf(1.0 - dist / 26.0, 0.0, 0.95), delta * 4.0)
	else:
		player.flicker = maxf(0.0, player.flicker - delta * 1.5)


func _update_hud() -> void:
	hud.set_stamina(player.stamina)
	var stage := 0
	if Game.pages_collected >= 2:
		stage = 1
	if Game.pages_collected >= 5:
		stage = 2
	if Game.pages_collected >= 7:
		stage = 3
	if stage != _objective_stage:
		_objective_stage = stage
		match stage:
			1: hud.show_toast("HE KNOWS YOU ARE HERE", 3.0)
			2: hud.show_toast("THE STATIC IS HIS VOICE", 3.0)
			3: hud.show_toast("ONE PAGE LEFT", 3.0)


# --------------------------------------------------------------------------- #
# pages
# --------------------------------------------------------------------------- #
func try_pickup(_p: Node) -> void:
	if _paused or _ended or near_page < 0:
		return
	var page: Dictionary = pages[near_page]
	var sheet: Node3D = page.get("cloth")
	if sheet != null and sheet.has_method("is_pinned") and sheet.is_pinned():
		# One press visibly pulls the real nail and frees the cloth. A second press
		# takes the loose page; no proximity auto-pickup can skip the physical act.
		sheet.unpin()
		hud.show_toast("NAIL PULLED", 1.2)
		_update_pages(0.0)
		return
	_collect(near_page)


func pickup_page(index: int) -> void:
	if index < 0 or index >= pages.size() or pages[index]["taken"]:
		return
	var sheet: Node3D = pages[index].get("cloth")
	if sheet != null and sheet.has_method("is_pinned") and sheet.is_pinned():
		sheet.unpin()
		return
	_collect(index)


func _collect(i: int) -> void:
	var p: Dictionary = pages[i]
	if p["taken"] or _ended or _paused:
		return
	p["taken"] = true
	var node: Node3D = p["node"]
	node.queue_free()
	near_page = -1
	if touch_ui != null:
		touch_ui.set_pickup_available(false)
	hud.show_prompt("")

	Game.register_page(p["note"])
	hud.set_pages(Game.pages_collected, Game.TOTAL_PAGES)
	hud.show_note(p["note"])
	hud.flash(0.35, 0.5)
	hud.static_burst(0.55)
	hud.camcorder_glitch(0.75)
	Sfx.play("page", -2.0, randf_range(0.95, 1.05))
	# picking a page always wakes him up a little
	slender.cooldown = maxf(2.5, slender.cooldown - 2.0)

	if Game.pages_collected >= Game.TOTAL_PAGES:
		_win()


# --------------------------------------------------------------------------- #
# slender events
# --------------------------------------------------------------------------- #
func _on_slender_apparition() -> void:
	hud.static_burst(0.5)
	hud.camcorder_glitch(0.55)
	player.shake_amount = 0.008


func _on_slender_visibility(is_visible: bool) -> void:
	if is_visible and slender.mode == slender.Mode.APPARITION:
		hud.static_burst(0.25)
		hud.camcorder_glitch(0.3)
		Sfx.play("appear_near", -20.0, randf_range(0.96, 1.04))


func on_apparition() -> void:
	_on_slender_apparition()


func on_chase_start() -> void:
	_on_chase_start()


func _on_chase_start() -> void:
	hud.static_burst(0.7)
	hud.camcorder_glitch(0.95)
	hud.camcorder_punch(0.35)
	player.shake_amount = 0.02
	hud.show_toast("RUN", 1.4)


func noise_emitted(_pos: Vector3, radius: float) -> void:
	slender.on_noise(_pos, radius)


# --------------------------------------------------------------------------- #
# endings
# --------------------------------------------------------------------------- #
func _on_caught() -> void:
	if _ended:
		return
	_ended = true
	Game.freeze_clock()
	player.freeze()
	player.touch_move = Vector2.ZERO

	# pull him right in front of the lens
	var cam: Camera3D = player.camera
	var fwd := -cam.global_transform.basis.z
	fwd.y = 0.0
	if fwd.length() < 0.05:
		fwd = -Vector3(cam.global_transform.basis.z.x, 0.0, cam.global_transform.basis.z.z).normalized()
		if fwd.length() < 0.05:
			pass
	fwd = fwd.normalized()
	slender.global_position = cam.global_position + fwd * 1.15 - Vector3(0, 2.2, 0)
	slender.global_position.y = 0.0
	slender.scale = Vector3(1.15, 1.15, 1.15)
	var dir := cam.global_position - slender.global_position
	dir.y = 0.0
	slender.rotation.y = atan2(dir.x, dir.z)
	slender.visible = true
	slender.set_process(false)

	player.look_at_point(slender.head_position())
	player.shake_amount = 0.06
	hud.set_static(0.30)
	hud.static_burst(0.55)
	hud.camcorder_glitch(1.0)
	hud.camcorder_punch(0.8)
	hud.set_dread(1.0)
	hud.flash(0.5, 0.14)
	player.flicker = 1.0
	# open the mix right before he hits: the forest falls away, only him left
	Sfx.fade_loop("wind_loop", -34.0, 0.20)
	Sfx.fade_loop("drone_loop", -34.0, 0.20)
	Sfx.play("jumpscare", -4.0)
	Sfx.set_heartbeat(1.0, -6.0)
	Sfx.set_loop_volume("static_loop", -12.0)

	await get_tree().create_timer(1.7).timeout
	_sync_pointer()
	hud.fade_to_black(0.7)
	await get_tree().create_timer(0.8).timeout
	Game.finish_run(false)
	hud.show_end(false, Game.pages_collected, Game.run_time)
	_sync_pointer()


func _win() -> void:
	if _ended:
		return
	_ended = true
	Game.freeze_clock()
	player.freeze()
	slender.deactivate()
	hud.show_toast("EIGHT PAGES", 2.0)
	Sfx.play("win", -9.0)
	Sfx.set_heartbeat(0.0, -60.0)
	Sfx.set_loop_volume("static_loop", -6.0)
	hud.set_static(0.8)

	await get_tree().create_timer(2.2).timeout
	hud.fade_to_black(1.6)
	await get_tree().create_timer(1.8).timeout
	Game.finish_run(true)
	hud.show_end(true, Game.pages_collected, Game.run_time)
	_sync_pointer()


# --------------------------------------------------------------------------- #
# menus / flow
# --------------------------------------------------------------------------- #
func _toggle_pause() -> void:
	if _ended:
		return
	_paused = not _paused
	get_tree().paused = _paused
	player.touch_move = Vector2.ZERO
	player.touch_sprint = false
	if touch_ui != null:
		touch_ui.clear_input()
	if _paused:
		hud.show_pause()
	else:
		hud.hide_pause()
	_sync_pointer()


func _resume() -> void:
	if _paused:
		_toggle_pause()


func _restart() -> void:
	get_tree().paused = false
	Game.ui_blocking = false
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	get_tree().reload_current_scene()


func _to_title() -> void:
	get_tree().paused = false
	Game.ui_blocking = false
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	Sfx.stop_all_loops()
	get_tree().change_scene_to_file("res://scenes/Title.tscn")


func _toggle_touch_mode() -> void:
	Game.touch_mode = not Game.touch_mode
	Settings.force_touch = Game.touch_mode
	Settings.save_settings()
	_restart()


func _update_touch_toggle_label() -> void:
	hud.update_touch_toggle_label(Game.touch_mode)


func _toggle_camcorder_fx() -> void:
	Settings.camcorder = not Settings.camcorder
	Settings.save_settings()
	hud.refresh_camcorder()
	_update_touch_toggle_label()


func _toggle_handheld_camera() -> void:
	Settings.camcorder_physics = not Settings.camcorder_physics
	Settings.save_settings()
	if player != null and player.handle != null:
		player.handle.set_physics_mode(Settings.camcorder_physics and Game.quality >= 1)
	_update_touch_toggle_label()


func _notification(what: int) -> void:
	if what == NOTIFICATION_APPLICATION_FOCUS_OUT:
		if Game.run_active and not _paused and not _ended and not Game.autotest:
			_toggle_pause()
	elif what == NOTIFICATION_APPLICATION_FOCUS_IN:
		# coming back to the window re-applies the same policy, so the camera is
		# never left feeling dead after an alt-tab
		_sync_pointer()


func unfreeze_player_after_pickups() -> void:
	player.frozen = false


func enable_touch_preview() -> void:
	Game.touch_mode = true
	if touch_ui == null:
		touch_ui = load("res://scripts/touch_controls.gd").new()
		touch_ui.set_player(player)
		touch_ui.hud = hud
		add_child(touch_ui)
	hud.set_touch_ui(true)
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE


func page_positions() -> Array[Vector3]:
	var out: Array[Vector3] = []
	for p in pages:
		if not p["taken"]:
			var sheet: Node3D = p.get("cloth")
			out.append(sheet.world_center() if sheet != null and sheet.has_method("world_center") 				else (p["node"] as Node3D).global_position)
	return out
