extends RefCounted
## Continuous Anny/MakeHuman anatomical body with fitted garments.
## Five batches, baked source geometry, no Python/Anny dependency at runtime.

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
	_add_anatomy()
	_tailoring()
	for side in [-1.0, 1.0]:
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

func _tri(surface: int, a: Vector3, b: Vector3, c: Vector3, na: Vector3, nb: Vector3, nc: Vector3, regions := Vector3(-1,-1,-1), weights := Vector3.ONE) -> void:
	var st := _surfaces[surface]
	var ids := regions if regions.x >= 0 else Vector3(_region,_region,_region)
	var verts := [[a,na,ids.x,weights.x],[b,nb,ids.y,weights.y],[c,nc,ids.z,weights.z]]
	for pair in verts:
		var p: Vector3 = pair[0]
		var n: Vector3 = pair[1]
		var region := int(pair[2])
		if region in [0,4,5] and p.y < 1.13:
			p.y *= 2.0
			n.y *= 0.5
		else: p.y += 1.13
		pair[0] = p
		pair[1] = n.normalized()
	if (verts[1][0]-verts[0][0]).cross(verts[2][0]-verts[0][0]).dot(verts[0][1]+verts[1][1]+verts[2][1]) > 0.0:
		verts = [verts[0],verts[2],verts[1]]
	for pair in verts:
		st.set_color(Color(float(pair[2])/8.0,float(pair[3]),0,1))
		st.set_normal(pair[1])
		st.add_vertex(pair[0])

func _panel(surface: int, points: Array[Vector3]) -> void:
	for i in range(1,points.size()-1):
		_tri(surface,points[0],points[i+1],points[i],Vector3.BACK,Vector3.BACK,Vector3.BACK)

func _add_anatomy() -> void:
	var data: Dictionary = JSON.parse_string(FileAccess.get_file_as_string("res://assets/models/slender_anny.json"))
	for batch: Dictionary in data["batches"]:
		var positions: Array[Vector3] = []
		var normals: Array[Vector3] = []
		for p: Array in batch["vertices"]: positions.append(Vector3(p[0],p[1],p[2]))
		for n: Array in batch["normals"]: normals.append(Vector3(n[0],n[1],n[2]).normalized())
		var ids: Array = batch["regions"]
		var weights: Array = batch["weights"]
		for face: Array in batch["faces"]:
			var a: int = int(face[0])
			var b: int = int(face[1])
			var c: int = int(face[2])
			_tri(int(batch["material"]),positions[a],positions[b],positions[c],normals[a],normals[b],normals[c],Vector3(ids[a],ids[b],ids[c]),Vector3(weights[a],weights[b],weights[c]))

	# Tapered closed nail shells follow each actual fingertip and its hand region.
	for nail: Dictionary in data.get("nails",[]):
		var t: Array = nail.tip
		var a: Array = nail.axis
		var tip := Vector3(t[0],t[1],t[2])
		var axis := Vector3(a[0],a[1],a[2]).normalized()
		var across := axis.cross(Vector3.BACK).normalized()
		var dorsal := across.cross(axis).normalized()
		var base := tip-axis*.015+dorsal*.004
		var point := tip+axis*float(nail.length)+dorsal*.009
		var ring: Array[Vector3] = [base+across*.006,base+dorsal*.004,base-across*.006,base-dorsal*.002]
		_region = 3 if nail.side>0 else 2
		for j in 4:
			var k := (j+1)%4
			var n := (ring[k]-ring[j]).cross(point-ring[j]).normalized()
			_tri(4,ring[j],ring[k],point,n,n,n)
		_tri(4,ring[0],ring[2],ring[1],-axis,-axis,-axis)
		_tri(4,ring[0],ring[3],ring[2],-axis,-axis,-axis)
	_region = 0

func _solid_panel(surface: int, points: Array[Vector3], thickness := 0.006) -> void:
	_panel(surface,points)
	var back: Array[Vector3] = []
	for p in points: back.append(p-Vector3(0,0,thickness))
	for i in range(1,points.size()-1):
		_tri(surface,back[0],back[i],back[i+1],Vector3.FORWARD,Vector3.FORWARD,Vector3.FORWARD)
	for i in points.size():
		var j := (i+1)%points.size()
		var n := (points[j]-points[i]).cross(Vector3.FORWARD).normalized()
		_tri(surface,points[i],points[j],back[i],n,n,n)
		_tri(surface,points[j],back[j],back[i],n,n,n)

func _ring_band(surface: int, bottom: float, top: float, inner_bottom: Vector2, outer_bottom: Vector2, inner_top: Vector2, outer_top: Vector2, segments := 48) -> void:
	# A closed annular solid: inner/outer walls and top/bottom lips. The hole is
	# genuinely open around the neck, not the capped cylinder of the old collar.
	var rings: Array = []
	for spec in [[bottom,inner_bottom],[bottom,outer_bottom],[top,outer_top],[top,inner_top]]:
		var ring: Array[Vector3] = []
		for j in segments:
			var a := TAU*float(j)/segments
			ring.append(Vector3(cos(a)*spec[1].x,spec[0],0.012+sin(a)*spec[1].y))
		rings.append(ring)
	for k in 4:
		var next := (k+1)%4
		for j in segments:
			var nj := (j+1)%segments
			var a: Vector3 = rings[k][j]
			var b: Vector3 = rings[k][nj]
			var c: Vector3 = rings[next][j]
			var d: Vector3 = rings[next][nj]
			var middle := (a+b+c+d)*0.25
			var n := Vector3.UP if k==2 else (Vector3.DOWN if k==0 else Vector3(middle.x,0,middle.z).normalized()*(1.0 if k==1 else -1.0))
			_tri(surface,a,b,c,n,n,n)
			_tri(surface,b,d,c,n,n,n)

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

func _knot() -> void:
	# Beveled, tapered rectangular silk knot, with a flat front and real depth.
	var rings: Array = []
	for shape in [[2.165,.012,.009],[2.185,.022,.013],[2.213,.026,.014],[2.240,.017,.010]]:
		var y: float = shape[0]
		var w: float = shape[1]
		var d: float = shape[2]
		var b := .004
		var ring: Array[Vector3] = []
		for xz in [Vector2(-w+b,-d),Vector2(w-b,-d),Vector2(w,-d+b),Vector2(w,d-b),Vector2(w-b,d),Vector2(-w+b,d),Vector2(-w,d-b),Vector2(-w,-d+b)]:
			ring.append(Vector3(xz.x,y,.180+xz.y))
		rings.append(ring)
	for i in 3:
		for j in 8:
			var k := (j+1)%8
			var a: Vector3 = rings[i][j]
			var b: Vector3 = rings[i][k]
			var c: Vector3 = rings[i+1][j]
			var d: Vector3 = rings[i+1][k]
			var n := Vector3((a+b).x,0,(a+b).z-.36).normalized()
			_tri(1,a,b,c,n,n,n)
			_tri(1,b,d,c,n,n,n)
	for end in [0,3]:
		for j in 8:
			var n := Vector3.DOWN if end==0 else Vector3.UP
			_tri(1,Vector3(0,2.165 if end==0 else 2.240,.18),rings[end][j],rings[end][(j+1)%8],n,n,n)

func _tailoring() -> void:
	_region = 0
	# Shirt and volumetric notch lapels fit the baked jacket's chest profile.
	for side in [-1.0,1.0]:
		_solid_panel(1,[Vector3(.092*side,2.243,.145),Vector3(.193*side,2.158,.177),Vector3(.131*side,2.09,.177),Vector3(.157*side,2.043,.173),Vector3(.025*side,1.838,.155)])
	# Rounded closed dress shoes fitted over the Anny feet, not exposed toe shapes.
	for side in [-1.0,1.0]:
		_region = 4 if side < 0 else 5
		_loft(4,[Vector4(.13*side,.003,.076,1),Vector4(.13*side,.022,.077,1),Vector4(.13*side,.070,.072,1),Vector4(.13*side,.112,.041,.65)],1.95,.061,24)
	_region = 0
	# White collar stand, real dark tie loop around it, and folded outer collar.
	_ring_band(2,2.245,2.300,Vector2(.067,.060),Vector2(.073,.067),Vector2(.067,.060),Vector2(.073,.067))
	_ring_band(1,2.262,2.286,Vector2(.076,.070),Vector2(.081,.075),Vector2(.076,.070),Vector2(.081,.075))
	_ring_band(2,2.247,2.301,Vector2(.085,.079),Vector2(.091,.085),Vector2(.073,.067),Vector2(.079,.073))
	for side in [-1.0,1.0]:
		_solid_panel(2,[Vector3(.012*side,2.275,.092),Vector3(.085*side,2.255,.112),Vector3(.065*side,2.145,.182)])
		# Both sides of the loop feed into the knot beneath the collar points.
		_tube(1,[Vector3(.031*side,2.274,.077),Vector3(.024*side,2.248,.120),Vector3(.010*side,2.231,.173)],[.010,.011,.010],8,.42)
	# A solid Windsor-style knot, not a flat decorative diamond.
	_knot()
	# Physical blade hangs from the base of that knot (CPU constraint root).
	_region = 8
	for i in 4:
		var y := 2.176-float(i)*.074
		var width := .014+float(i)*.005
		var next_width := .014+float(i+1)*.005 if i<3 else .0005
		_panel(1,[Vector3(-width,y,.185),Vector3(width,y,.185),Vector3(next_width,y-.074,.185),Vector3(-next_width,y-.074,.185)])
	_region = 0

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
