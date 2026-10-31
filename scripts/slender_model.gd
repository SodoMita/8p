extends RefCounted
## Deterministic, smooth procedural creature. Five material batches, no textures,
## no external assets, no per-frame mesh work. Local +Z is the face/player side.

var _region := 0

var _surfaces: Array[SurfaceTool] = []
var _materials: Array[StandardMaterial3D] = []

func build(parent: Node3D) -> Array[MeshInstance3D]:
	_region = 0
	_surfaces.clear()
	_materials = [
		_material(Color(0.065, 0.067, 0.075), 0.91, 0.04), # wool
		_material(Color(0.024, 0.028, 0.036), 0.65, 0.012), # lapels/tie
		_material(Color(0.66, 0.68, 0.65), 0.88, 0.06), # shirt
		_material(Color(0.72, 0.74, 0.69), 0.82, 0.14), # skin
		_material(Color(0.018, 0.021, 0.026), 0.4, 0.008), # shoes/tendrils
	]
	for mat in _materials:
		var st := SurfaceTool.new()
		st.begin(Mesh.PRIMITIVE_TRIANGLES)
		st.set_material(mat)
		_surfaces.append(st)
	_body()
	for side in [-1.0, 1.0]:
		_limbs(side)
		_hand(side)
		_tendrils(side)
	var result: Array[MeshInstance3D] = []
	for i in _surfaces.size():
		var mi := MeshInstance3D.new()
		mi.name = ["Wool", "Satin", "Shirt", "Skin", "LeatherAndTendrils"][i]
		mi.mesh = _surfaces[i].commit()
		mi.material_override = _materials[i]
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		parent.add_child(mi)
		result.append(mi)
	return result

func _material(color: Color, roughness: float, glow: float) -> StandardMaterial3D:
	var mat := StandardMaterial3D.new()
	mat.albedo_color = color
	mat.roughness = roughness
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	mat.emission_enabled = true
	mat.emission = color
	mat.emission_energy_multiplier = glow
	return mat

func _tri(surface: int, a: Vector3, b: Vector3, c: Vector3, na: Vector3, nb: Vector3, nc: Vector3) -> void:
	var st := _surfaces[surface]
	# Godot's front faces are clockwise. Keep winding aligned with the explicit
	# outward normals even for mirrored collar panels and swept tube caps.
	var verts := [[a, na], [b, nb], [c, nc]]
	if (b - a).cross(c - a).dot(na + nb + nc) > 0.0:
		verts = [[a, na], [c, nc], [b, nb]]
	for pair in verts:
		st.set_color(Color(float(_region) / 8.0, 0, 0, 1))
		st.set_normal(pair[1])
		st.add_vertex(pair[0])

func _panel(surface: int, points: Array[Vector3]) -> void:
	# Flat tailoring pieces, slightly raised from the chest, outward +Z normal.
	for i in range(1, points.size() - 1):
		_tri(surface, points[0], points[i + 1], points[i], Vector3.BACK, Vector3.BACK, Vector3.BACK)

func _loft(surface: int, rings: Array[Vector4], depth: float, z := 0.0, segments := 24) -> void:
	# ring = x center, y, x radius, depth radius multiplier (allows flattened chest)
	var positions: Array[Vector3] = []
	var normals: Array[Vector3] = []
	for r in rings.size():
		var ring := rings[r]
		var prev := rings[maxi(0, r - 1)]
		var next := rings[mini(rings.size() - 1, r + 1)]
		var slope := (next.z - prev.z) / maxf(0.0001, next.y - prev.y)
		for j in segments:
			var angle := TAU * float(j) / segments
			positions.append(Vector3(ring.x + cos(angle) * ring.z, ring.y, z + sin(angle) * ring.z * depth * ring.w))
			normals.append(Vector3(cos(angle), -slope, sin(angle) / (depth * ring.w)).normalized())
	for r in rings.size() - 1:
		for j in segments:
			var a := r * segments + j
			var b := r * segments + (j + 1) % segments
			var c := a + segments
			var d := b + segments
			_tri(surface, positions[a], positions[c], positions[b], normals[a], normals[c], normals[b])
			_tri(surface, positions[b], positions[c], positions[d], normals[b], normals[c], normals[d])
	# End caps; tiny pole rings give a smooth, closed head/torso.
	for end in [0, rings.size() - 1]:
		var normal := Vector3.DOWN if end == 0 else Vector3.UP
		var center := Vector3(rings[end].x, rings[end].y, z)
		for j in segments:
			var a: int = end * segments + j
			var b: int = end * segments + (j + 1) % segments
			if end == 0: _tri(surface, center, positions[a], positions[b], normal, normals[a], normals[b])
			else: _tri(surface, center, positions[b], positions[a], normal, normals[b], normals[a])

func _tube(surface: int, points: Array[Vector3], radii: Array[float], segments := 10, flatten := 1.0) -> void:
	var pos: Array[Vector3] = []
	var normals: Array[Vector3] = []
	for i in points.size():
		var tangent := (points[mini(i + 1, points.size() - 1)] - points[maxi(0, i - 1)]).normalized()
		var axis := Vector3.FORWARD
		if absf(tangent.dot(axis)) > 0.94: axis = Vector3.RIGHT
		var u := tangent.cross(axis).normalized()
		var v := tangent.cross(u).normalized()
		for j in segments:
			var angle := TAU * float(j) / segments
			var radial := u * cos(angle) + v * sin(angle) * flatten
			pos.append(points[i] + radii[i] * radial)
			normals.append((u * cos(angle) + v * sin(angle) / flatten).normalized())
	for i in points.size() - 1:
		for j in segments:
			var a := i * segments + j
			var b := i * segments + (j + 1) % segments
			var c := a + segments
			var d := b + segments
			_tri(surface, pos[a], pos[b], pos[c], normals[a], normals[b], normals[c])
			_tri(surface, pos[b], pos[d], pos[c], normals[b], normals[d], normals[c])
	for end in [0, points.size() - 1]:
		var normal := (points[0] - points[1]).normalized() if end == 0 else (points[-1] - points[-2]).normalized()
		for j in segments:
			var a: int = end * segments + j
			var b: int = end * segments + (j + 1) % segments
			if end == 0: _tri(surface, points[end], pos[b], pos[a], normal, normals[b], normals[a])
			else: _tri(surface, points[end], pos[a], pos[b], normal, normals[a], normals[b])

func _body() -> void:
	# Structured shoulders, a high waist and a slightly flared long jacket hem.
	_loft(0, [Vector4(0, 1.04, 0.153, 1), Vector4(0, 1.09, 0.166, 1), Vector4(0, 1.4, 0.15, 1), Vector4(0, 1.66, 0.137, 1), Vector4(0, 1.9, 0.174, 1), Vector4(0, 2.13, 0.232, 0.84), Vector4(0, 2.22, 0.21, 0.82), Vector4(0, 2.26, 0.085, 1)], 0.74)
	# White shirt inset and pointed collar, not a floating rectangular tie.
	_panel(2, [Vector3(-0.087, 2.245, 0.158), Vector3(0.087, 2.245, 0.158), Vector3(0.026, 1.86, 0.158), Vector3(-0.026, 1.86, 0.158)])
	_loft(2, [Vector4(0, 2.225, 0.074, 1), Vector4(0, 2.3, 0.067, 1)], 0.9)
	for side in [-1.0, 1.0]:
		_panel(2, [Vector3(0.012 * side, 2.267, 0.176), Vector3(0.082 * side, 2.263, 0.176), Vector3(0.066 * side, 2.145, 0.18)])
		_panel(1, [Vector3(0.092 * side, 2.243, 0.145), Vector3(0.193 * side, 2.158, 0.172), Vector3(0.131 * side, 2.09, 0.172), Vector3(0.157 * side, 2.043, 0.168), Vector3(0.025 * side, 1.838, 0.15)])
		# Welt pocket and jacket seam, restrained rather than noisy decoration.
		_panel(1, [Vector3(0.067 * side, 1.46, 0.112), Vector3(0.136 * side, 1.48, 0.084), Vector3(0.137 * side, 1.463, 0.085), Vector3(0.068 * side, 1.444, 0.113)])
	_panel(1, [Vector3(0, 2.233, 0.187), Vector3(0.027, 2.202, 0.194), Vector3(0, 2.166, 0.195), Vector3(-0.027, 2.202, 0.194)])
	# Segmented blade, pinned under the knot; GPU follows the constrained chain.
	_region = 8
	for i in 4:
		var top_y := 2.176 - float(i) * 0.074
		var bottom_y := top_y - 0.074
		var top_w := 0.014 + float(i) * 0.005
		var bottom_w := 0.014 + float(i + 1) * 0.005 if i < 3 else 0.0005
		_panel(1, [Vector3(-top_w, top_y, 0.185), Vector3(top_w, top_y, 0.185), Vector3(bottom_w, bottom_y, 0.185), Vector3(-bottom_w, bottom_y, 0.185)])
	_region = 0
	_tube(3, [Vector3(0, 2.27, 0), Vector3(0, 2.39, 0.005)], [0.057, 0.062], 16)
	_region = 1
	# Egg-shaped skull: narrower chin, broad cranium. Deliberately no facial features.
	_loft(3, [Vector4(0, 2.348, 0.012, 1), Vector4(0, 2.367, 0.061, 1), Vector4(0, 2.407, 0.103, 1), Vector4(0, 2.475, 0.139, 1), Vector4(0, 2.555, 0.16, 1), Vector4(0, 2.635, 0.165, 1), Vector4(0, 2.7, 0.139, 1), Vector4(0, 2.752, 0.087, 1), Vector4(0, 2.772, 0.008, 1)], 0.85, 0.022, 32)

func _limbs(s: float) -> void:
	_region = 2 if s < 0 else 3
	# Sleeves hang from rounded shoulders; subtle elbow bend avoids pipe limbs.
	_tube(0, [Vector3(0.2*s, 2.19, 0), Vector3(0.26*s, 2.13, 0), Vector3(0.295*s, 1.94, 0.005), Vector3(0.34*s, 1.67, 0.015), Vector3(0.354*s, 1.55, 0.028), Vector3(0.374*s, 1.25, 0.052), Vector3(0.394*s, 0.99, 0.07)], [0.07, 0.093, 0.075, 0.057, 0.059, 0.044, 0.037], 16, 0.82)
	_tube(2, [Vector3(0.394*s, 1.012, 0.07), Vector3(0.397*s, 0.974, 0.071)], [0.037, 0.035], 12, 0.8)
	_region = 4 if s < 0 else 5
	_tube(0, [Vector3(0.093*s, 1.2, 0), Vector3(0.106*s, 1.04, 0), Vector3(0.118*s, 0.77, 0.015), Vector3(0.121*s, 0.59, 0.026), Vector3(0.127*s, 0.36, 0.005), Vector3(0.13*s, 0.09, 0.01)], [0.087, 0.089, 0.07, 0.063, 0.052, 0.05], 16, 0.91)
	# Rounded elongated dress shoes, toes towards +Z.
	_loft(4, [Vector4(0.13*s, 0.008, 0.048, 1), Vector4(0.13*s, 0.022, 0.068, 1), Vector4(0.13*s, 0.064, 0.064, 1), Vector4(0.13*s, 0.097, 0.04, 0.8)], 2.0, 0.058, 20)

func _hand(s: float) -> void:
	_region = 2 if s < 0 else 3
	# Flattened palm; four individually tapered fingers plus the hooked thumb.
	_tube(3, [Vector3(0.397*s, 0.982, 0.072), Vector3(0.404*s, 0.929, 0.075), Vector3(0.415*s, 0.847, 0.082)], [0.027, 0.041, 0.033], 12, 0.52)
	for f in 4:
		var spread := (float(f) - 1.5) * 0.021
		var length := [0.127, 0.17, 0.157, 0.12][f] as float
		var x := (0.415 + spread) * s
		_tube(3, [Vector3(x, 0.856, 0.082), Vector3(x + spread*0.28*s, 0.856-length*0.5, 0.083), Vector3(x + spread*0.4*s, 0.856-length*0.84, 0.106), Vector3(x + spread*0.35*s, 0.856-length, 0.124)], [0.011, 0.0095, 0.007, 0.0025], 8)
	_tube(3, [Vector3(0.377*s, 0.924, 0.08), Vector3(0.351*s, 0.878, 0.084), Vector3(0.342*s, 0.824, 0.11), Vector3(0.35*s, 0.807, 0.129)], [0.016, 0.012, 0.008, 0.003], 8)

func _tendrils(s: float) -> void:
	_region = 6 if s < 0 else 7
	# Cubic arcs rooted on the back. Curvature is smooth and tips taper to nothing;
	# asymmetry avoids a rigid spider/crown silhouette and never obscures the face.
	for i in 3:
		var start := Vector3(0.12*s, 1.98 - i*0.21, -0.1)
		var c1 := Vector3((0.47+i*0.1)*s, 2.21-i*0.18, -0.48)
		var c2 := Vector3((0.91+i*0.08)*s, 2.52-i*0.42 + (0.07 if s > 0 else 0.0), -0.5)
		var end := Vector3((0.87+i*0.13)*s, 2.01-i*0.47, -0.24)
		var points: Array[Vector3] = []
		var radii: Array[float] = []
		for j in 21:
			var t := float(j)/20.0
			points.append(start.bezier_interpolate(c1, c2, end, t))
			radii.append(lerpf(0.037 - i*0.004, 0.0006, pow(t, 0.8)))
		_tube(4, points, radii, 10)
