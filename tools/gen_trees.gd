extends SceneTree
## Bakes realistic barren-tree meshes to res://assets/models/*.res
## Run: godot --headless --path . --script tools/gen_trees.gd
##
## Every tree is grown procedurally (recursive tapering branches with a slight
## gravity bend and irregular forks) so the forest never repeats a silhouette.

const OUT_DIR := "res://assets/models"
const RADIAL_TRUNK := 10
const RADIAL_BRANCH := 6
const BARK_TILE := 0.55   # metres of bark per texture repeat (world-space UVs)


func _init() -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(OUT_DIR))
	var t0 := Time.get_ticks_msec()

	# --- 6 full dead spruce/pine variants ------------------------------------
	for i in 6:
		var rng := RandomNumberGenerator.new()
		rng.seed = 1000 + i * 37
		var mesh := _grow_tree(rng, {
			"trunk_h": rng.randf_range(9.0, 15.0),
			"trunk_r": rng.randf_range(0.42, 0.62),
			"depth": 4,
			"children": rng.randi_range(2, 3),
			"spread": rng.randf_range(0.62, 1.05),
			"up_bias": rng.randf_range(0.22, 0.55),
			"twig": true,
		})
		_save(mesh, "tree_%d.res" % i)

	# --- 2 tall bare snags (no branches, splintered top) ---------------------
	for i in 2:
		var rng := RandomNumberGenerator.new()
		rng.seed = 2500 + i
		var st := SurfaceTool.new()
		st.begin(Mesh.PRIMITIVE_TRIANGLES)
		var h := rng.randf_range(10.0, 16.0)
		var r := rng.randf_range(0.34, 0.5)
		var pts: Array[Vector3] = []
		var radii: Array[float] = []
		for k in 7:
			var t := k / 6.0
			pts.append(Vector3(sin(t * 3.1 + i) * 0.22 * t, h * t, cos(t * 2.2) * 0.18 * t))
			radii.append(r * (1.0 - 0.55 * t))
		_tube(st, pts, radii, RADIAL_TRUNK, true)
		# a few broken stubs
		for k in 3:
			var at := rng.randf_range(0.35, 0.85)
			var base := Vector3(0, h * at, 0)
			var dir := Vector3(rng.randf_range(-1, 1), rng.randf_range(0.1, 0.5), rng.randf_range(-1, 1)).normalized()
			_tube(st, [base, base + dir * rng.randf_range(0.5, 1.3)],
				[r * 0.22, r * 0.05], RADIAL_BRANCH, false)
		_save(_commit(st), "snag_%d.res" % i)

	# --- fallen log (with a couple of broken branch stubs) -------------------
	var rng2 := RandomNumberGenerator.new()
	rng2.seed = 404
	var st2 := SurfaceTool.new()
	st2.begin(Mesh.PRIMITIVE_TRIANGLES)
	var lp: Array[Vector3] = []
	var lr: Array[float] = []
	for k in 6:
		var t := k / 5.0
		lp.append(Vector3(0, 0.42 * (1.0 - t * 0.15), t * 6.0 - 3.0))
		lr.append(0.42 * (1.0 - 0.22 * t))
	_tube(st2, lp, lr, 8, true)
	for k in 2:
		var at := Vector3(0, 0.45, rng2.randf_range(-2.0, 2.0))
		var dir := Vector3(rng2.randf_range(-0.6, 0.6), 0.7, rng2.randf_range(-0.4, 0.4)).normalized()
		_tube(st2, [at, at + dir * 0.9], [0.09, 0.03], 4, false)
	_save(_commit(st2), "log_0.res")

	# --- stump ---------------------------------------------------------------
	var st3 := SurfaceTool.new()
	st3.begin(Mesh.PRIMITIVE_TRIANGLES)
	_tube(st3, [Vector3(0, 0, 0), Vector3(0.015, 0.36, 0.008), Vector3(0.04, 0.72, 0.022)],
		[0.55, 0.46, 0.38], 10, true)
	_save(_commit(st3), "stump_0.res")

	# --- dead shrub: a fan of thin twigs, no leaves --------------------------
	var rng3 := RandomNumberGenerator.new()
	rng3.seed = 77
	var st4 := SurfaceTool.new()
	st4.begin(Mesh.PRIMITIVE_TRIANGLES)
	for k in 12:
		var a := rng3.randf() * TAU
		var base := Vector3(cos(a) * 0.12, 0, sin(a) * 0.12)
		var top := base + Vector3(cos(a) * rng3.randf_range(0.2, 0.7),
			rng3.randf_range(0.5, 1.2), sin(a) * rng3.randf_range(0.2, 0.7))
		_tube(st4, [base, base.lerp(top, 0.55) + Vector3(0, 0.05, 0), top],
			[0.035, 0.022, 0.006], 3, false)
	_save(_commit(st4), "shrub_0.res")

	# --- 3 ribbed pumpkins (some upright, some toppled) ----------------------
	for i in 3:
		var prng := RandomNumberGenerator.new()
		prng.seed = 9100 + i * 13
		_save(_pumpkin(prng, 0.30 + i * 0.045, 8 + i * 2), "pumpkin_%d.res" % i)

	# --- 3 dead twiggy bushes (wide, low, no leaves) -------------------------
	for i in 3:
		var brng := RandomNumberGenerator.new()
		brng.seed = 6400 + i * 71
		_save(_bush(brng, 1.05 + i * 0.16), "bush_%d.res" % i)

	print("[gen_trees] done in %d ms" % (Time.get_ticks_msec() - t0))
	quit(0)


# --------------------------------------------------------------------------- #
# growth
# --------------------------------------------------------------------------- #
func _grow_tree(rng: RandomNumberGenerator, cfg: Dictionary) -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	_grow(st, rng, Vector3.ZERO, Vector3.UP, cfg["trunk_h"], cfg["trunk_r"], 0, cfg)
	return _commit(st)


func _grow(st: SurfaceTool, rng: RandomNumberGenerator, origin: Vector3, dir: Vector3,
		length: float, radius: float, depth: int, cfg: Dictionary) -> void:
	var max_depth: int = cfg["depth"]
	var lean := Vector3(rng.randf_range(-0.12, 0.12), 0.0, rng.randf_range(-0.12, 0.12))
	if depth == 0:
		lean *= 3.0  # trunks are visibly crooked
	var segs := 4 if depth == 0 else 2
	var pts: Array[Vector3] = [origin]
	var radii: Array[float] = [radius]
	var p := origin
	var d := dir
	for k in segs:
		var t := float(k + 1) / segs
		# droop for outer branches, gravity pulls the tips down a little
		d = (d + lean * 0.35 + Vector3.DOWN * (0.05 if depth > 0 else 0.015)).normalized()
		p = p + d * (length / segs)
		pts.append(p)
		radii.append(radius * (1.0 - 0.42 * t))
	_tube(st, pts, radii, RADIAL_TRUNK if depth == 0 else RADIAL_BRANCH, depth == 0)

	if depth >= max_depth:
		if cfg["twig"] and depth <= max_depth:
			_twig_tip(st, rng, p, d, radius)
		return

	var children: int = cfg["children"] if depth == 0 else rng.randi_range(2, 3)
	if depth >= 2:
		children = 2
	for c in children:
		var az := rng.randf() * TAU
		var spread: float = cfg["spread"] * rng.randf_range(0.7, 1.25) * (1.0 - depth * 0.12)
		var up_bias: float = cfg["up_bias"]
		var nd := (d + Vector3(cos(az) * spread, up_bias, sin(az) * spread)).normalized()
		var child_len := length * rng.randf_range(0.58, 0.8)
		var child_rad := radius * rng.randf_range(0.58, 0.74)
		# branches spring from along the last segment, not only its tip
		var start := pts[pts.size() - 2].lerp(p, rng.randf_range(0.55, 1.0))
		_grow(st, rng, start, nd, child_len, child_rad, depth + 1, cfg)


func _twig_tip(st: SurfaceTool, rng: RandomNumberGenerator, p: Vector3, d: Vector3, radius: float) -> void:
	for k in 3:
		var dir := (d + Vector3(rng.randf_range(-0.6, 0.6), rng.randf_range(0.1, 0.6), rng.randf_range(-0.6, 0.6))).normalized()
		_tube(st, [p, p + dir * rng.randf_range(0.18, 0.45)], [radius * 0.5, 0.004], 3, false)


# --------------------------------------------------------------------------- #
# low level: tapered tube along a polyline
# --------------------------------------------------------------------------- #
func _tube(st: SurfaceTool, pts: Array[Vector3], radii: Array[float], sides: int, capped: bool) -> void:
	var rings := pts.size()
	var frames: Array = []
	var prev_right := Vector3.ZERO
	for i in rings:
		var fwd := Vector3.UP
		if i == 0:
			fwd = (pts[1] - pts[0]).normalized()
		elif i == rings - 1:
			fwd = (pts[i] - pts[i - 1]).normalized()
		else:
			fwd = (pts[i + 1] - pts[i - 1]).normalized()
		# parallel transport: reusing one fixed reference vector made the frame
		# snap 180 degrees when the tangent crossed the reference axis, which
		# wound those quads backwards (the "inverted normals" on trunks)
		var right: Vector3
		if prev_right == Vector3.ZERO:
			var ref := Vector3.RIGHT if absf(fwd.dot(Vector3.UP)) > 0.9 else Vector3.UP
			right = fwd.cross(ref).normalized()
		else:
			right = (prev_right - fwd * prev_right.dot(fwd))
			if right.length() < 1e-4:
				right = fwd.cross(Vector3.UP)
			right = right.normalized()
		prev_right = right
		var up := right.cross(fwd).normalized()
		frames.append([fwd, right, up, B(pts, i)])

	for i in rings - 1:
		for s in sides:
			var a0 := TAU * s / sides
			var a1 := TAU * (s + 1) / sides
			var f0: Array = frames[i]
			var f1: Array = frames[i + 1]
			var p00: Vector3 = f0[3] + (f0[1] * cos(a0) + f0[2] * sin(a0)) * radii[i]
			var p01: Vector3 = f0[3] + (f0[1] * cos(a1) + f0[2] * sin(a1)) * radii[i]
			var p10: Vector3 = f1[3] + (f1[1] * cos(a0) + f1[2] * sin(a0)) * radii[i + 1]
			var p11: Vector3 = f1[3] + (f1[1] * cos(a1) + f1[2] * sin(a1)) * radii[i + 1]
			var n0: Vector3 = (f0[1] * cos(a0) + f0[2] * sin(a0)).normalized()
			var n1: Vector3 = (f0[1] * cos(a1) + f0[2] * sin(a1)).normalized()
			# cylindrical UVs: u wraps around (circumference in metres / 2), v along length
			var u0 := (float(s) / sides) * (TAU * radii[i] / BARK_TILE)
			var u1 := (float(s + 1) / sides) * (TAU * radii[i] / BARK_TILE)
			var v0 := _arc_len(pts, i) / BARK_TILE
			var v1 := _arc_len(pts, i + 1) / BARK_TILE
			_quad(st, p00, p10, p11, p01, n0, n0, n1, n1,
				Vector2(u0, v0), Vector2(u0, v1), Vector2(u1, v1), Vector2(u1, v0))

	if capped:
		# both ends get a fan so you never look into a hollow mesh (an open top
		# reads as inverted normals because you see the inside back-faces)
		_cap_fan(st, frames[0], radii[0], sides, -1.0)
		if radii[rings - 1] > 0.02:
			_cap_fan(st, frames[rings - 1], radii[rings - 1], sides, 1.0)


func _cap_fan(st: SurfaceTool, f: Array, radius: float, sides: int, sign_dir: float) -> void:
	var fwd: Vector3 = f[0] * sign_dir
	var right: Vector3 = f[1]
	var up: Vector3 = f[2]
	for s in sides:
		var a0 := TAU * s / sides
		var a1 := TAU * (s + 1) / sides
		var p0: Vector3 = f[3] + (right * cos(a0) + up * sin(a0)) * radius
		var p1: Vector3 = f[3] + (right * cos(a1) + up * sin(a1)) * radius
		var ring := [f[3], p0, p1] if sign_dir < 0.0 else [f[3], p1, p0]
		for v in ring:
			st.set_normal(fwd)
			st.set_uv(Vector2(0.5, 0.5))
			st.add_vertex(v)


# --------------------------------------------------------------------------- #
# pumpkin: a ribbed, squashed sphere of revolution with a dry stem
# --------------------------------------------------------------------------- #
func _pumpkin(rng: RandomNumberGenerator, radius: float, lobes: int) -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	const RINGS := 24
	const SEGMENTS := 72
	var squash := rng.randf_range(0.72, 0.88)
	var phase := rng.randf() * TAU
	var profile := Vector3(radius, squash, phase)
	for i in RINGS:
		for j in SEGMENTS:
			var corners := [Vector2(j / float(SEGMENTS), i / float(RINGS)),
				Vector2(j / float(SEGMENTS), (i + 1) / float(RINGS)),
				Vector2((j + 1) / float(SEGMENTS), (i + 1) / float(RINGS)),
				Vector2((j + 1) / float(SEGMENTS), i / float(RINGS))]
			for k in [0, 1, 2, 0, 2, 3]:
				var uv: Vector2 = corners[k]
				var a := uv.x * TAU
				var phi := uv.y * PI
				var p := _pumpkin_point(a, phi, lobes, profile)
				# Numerical derivatives follow the lobes, dents and flattened base.
				var dp := _pumpkin_point(a, clampf(phi + 0.001, 0.0001, PI - 0.0001), lobes, profile) - _pumpkin_point(a, clampf(phi - 0.001, 0.0001, PI - 0.0001), lobes, profile)
				var da := _pumpkin_point(a + 0.001, clampf(phi, 0.0001, PI - 0.0001), lobes, profile) - _pumpkin_point(a - 0.001, clampf(phi, 0.0001, PI - 0.0001), lobes, profile)
				var n := dp.cross(da).normalized()
				st.set_normal(n)
				st.set_uv(uv)
				var groove := pow(0.5 + 0.5 * cos(lobes * a), 5.0)
				st.set_color(Color(1.0 - groove * 0.24, 1.0 - groove * 0.32, 1.0 - groove * 0.4, 1.0))
				st.add_vertex(p)
	# Alpha is a material-region mask, not transparency. One batched mesh/material.
	st.set_color(Color(0.75, 0.68, 0.48, 0.0))
	var crown := _pumpkin_point(0, PI, lobes, profile)
	var bend := Vector3(cos(phase), 0, sin(phase)) * radius * 0.18
	_tube(st, [crown - Vector3.UP * 0.018, crown + Vector3.UP * radius * 0.20,
		crown + Vector3.UP * radius * 0.44 + bend,
		crown + Vector3.UP * radius * 0.56 + bend * 1.8],
		[radius * 0.15, radius * 0.115, radius * 0.08, radius * 0.065], 9, true)
	return _commit(st)


func _pumpkin_point(a: float, phi: float, lobes: int, profile: Vector3) -> Vector3:
	var h := -cos(phi)
	var fade := sin(phi)
	var groove := pow(0.5 + 0.5 * cos(lobes * a), 5.0)
	var rib := 1.0 - 0.15 * groove * pow(fade, 0.6)
	var wobble := 1.0 + 0.035 * sin(a * 3.0 + profile.z) * fade
	var r := profile.x * fade * rib * wobble
	var y := profile.x * profile.y * h
	# A settled flat bottom and deeply inset stem socket.
	y = maxf(y, -profile.x * profile.y * 0.87)
	y -= profile.x * 0.16 * smoothstep(0.78, 1.0, h)
	return Vector3(cos(a) * r, y, sin(a) * r)

# --------------------------------------------------------------------------- #
# dead bush: a broad fan of arching twigs, dense enough to read as a mass
# --------------------------------------------------------------------------- #
func _bush(rng: RandomNumberGenerator, height: float) -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	# short woody stump the twigs spring from
	_tube(st, [Vector3(0, -0.05, 0), Vector3(rng.randf_range(-0.04, 0.04), height * 0.16, rng.randf_range(-0.04, 0.04))],
		[0.085, 0.06], 6, true)
	# twigs branch recursively inside a squashed hemisphere, so the silhouette is
	# a dense clump rather than a fan of spokes
	var mains := rng.randi_range(11, 15)
	for m in mains:
		var a := rng.randf() * TAU
		var out := Vector3(cos(a), 0, sin(a))
		var start := Vector3(out.x * 0.05, height * 0.14, out.z * 0.05)
		var dir := (out * rng.randf_range(0.45, 0.95) + Vector3.UP * rng.randf_range(0.7, 1.25)).normalized()
		_bush_branch(st, rng, start, dir, height * rng.randf_range(0.45, 0.62), 0.026, 0, height)
	return _commit(st)


func _bush_branch(st: SurfaceTool, rng: RandomNumberGenerator, origin: Vector3,
		dir: Vector3, length: float, radius: float, depth: int, height: float) -> void:
	# keep every segment short and gently curved, and stop twigs from drifting
	# outside the clump's dome
	var segs := 3
	var pts: Array[Vector3] = [origin]
	var radii: Array[float] = [radius]
	var p := origin
	var d := dir
	var lean := Vector3(rng.randf_range(-0.25, 0.25), rng.randf_range(-0.1, 0.15), rng.randf_range(-0.25, 0.25))
	for k in segs:
		d = (d + lean * 0.4 + Vector3.UP * 0.06).normalized()
		var nxt := p + d * (length / segs)
		# fold back toward the dome if the twig strays out of bounds
		var flat := Vector2(nxt.x, nxt.z).length()
		var cap := height * (0.62 - 0.10 * depth)
		if flat > cap:
			nxt.x *= cap / flat
			nxt.z *= cap / flat
		if nxt.y > height * 1.05:
			nxt.y = height * 1.05
		d = (nxt - p).normalized()
		p = nxt
		pts.append(p)
		radii.append(radius * (1.0 - 0.30 * float(k + 1) / segs))
	_tube(st, pts, radii, 3, false)
	if depth >= 2 or radius < 0.008:
		return
	var kids := rng.randi_range(2, 3)
	for c in kids:
		var az := rng.randf() * TAU
		var nd := (d + Vector3(cos(az) * 0.55, rng.randf_range(-0.05, 0.35), sin(az) * 0.55)).normalized()
		var start: Vector3 = pts[rng.randi_range(1, segs - 1)]
		_bush_branch(st, rng, start, nd, length * rng.randf_range(0.45, 0.65),
			radius * rng.randf_range(0.5, 0.62), depth + 1, height)


func B(pts: Array[Vector3], i: int) -> Vector3:
	return pts[i]


func _arc_len(pts: Array[Vector3], upto: int) -> float:
	var total := 0.0
	for i in range(1, upto + 1):
		total += pts[i].distance_to(pts[i - 1])
	return total


func _quad(st: SurfaceTool, a: Vector3, b: Vector3, c: Vector3, d: Vector3,
		na: Vector3, nb: Vector3, nc: Vector3, nd: Vector3,
		ua: Vector2, ub: Vector2, uc: Vector2, ud: Vector2) -> void:
	st.set_normal(na); st.set_uv(ua); st.add_vertex(a)
	st.set_normal(nb); st.set_uv(ub); st.add_vertex(b)
	st.set_normal(nc); st.set_uv(uc); st.add_vertex(c)
	st.set_normal(na); st.set_uv(ua); st.add_vertex(a)
	st.set_normal(nc); st.set_uv(uc); st.add_vertex(c)
	st.set_normal(nd); st.set_normal(nd); st.set_uv(ud); st.add_vertex(d)


func _commit(st: SurfaceTool) -> ArrayMesh:
	st.index()
	st.generate_tangents()
	return st.commit()


func _save(mesh: ArrayMesh, name: String) -> void:
	var path := OUT_DIR + "/" + name
	var err := ResourceSaver.save(mesh, path)
	var tris := 0
	for s in mesh.get_surface_count():
		tris += mesh.surface_get_array_len(s) / 3
	print("[gen_trees] %s  %d tris  err=%d" % [name, int(tris), err])
