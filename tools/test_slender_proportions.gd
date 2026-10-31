extends SceneTree
## Checks actual built geometry against source, not just proportion metadata.
func _initialize() -> void:
	var data: Dictionary = JSON.parse_string(FileAccess.get_file_as_string("res://assets/models/slender_anny.json"))
	assert(data.finger_metrics.size()==10 and data.nails.size()==10)
	for digit: Dictionary in data.finger_metrics:
		assert(absf(digit.after/digit.before-2.0)<0.00001, "Each actual anatomical finger must be 2x knuckle-to-tip length")
	var host := Node3D.new()
	root.add_child(host)
	var parts: Array[MeshInstance3D] = load("res://scripts/slender_model.gd").new().build(host)
	var skin: PackedVector3Array = parts[3].mesh.surface_get_arrays(0)[Mesh.ARRAY_VERTEX]
	var actual := {}
	for p in skin: actual[key(p)]=true
	var batch: Dictionary = data.batches[0]
	for i in batch.vertices.size():
		var v: Array = batch.vertices[i]
		var p := Vector3(v[0],v[1],v[2])
		var r := int(batch.regions[i])
		if r in [0,4,5] and p.y<1.13: p.y*=2.0
		else: p.y+=1.13
		assert(actual.has(key(p)), "Runtime skin must preserve shifted hands/head and doubled lower anatomy")
	var dark: PackedVector3Array = parts[4].mesh.surface_get_arrays(0)[Mesh.ARRAY_VERTEX]
	var nail_points := {}
	for p in dark: nail_points[key(p)]=true
	for nail: Dictionary in data.nails:
		var t: Array = nail.tip
		var a: Array = nail.axis
		var tip := Vector3(t[0],t[1],t[2])
		var axis := Vector3(a[0],a[1],a[2]).normalized()
		var across := axis.cross(Vector3.BACK).normalized()
		var dorsal := across.cross(axis).normalized()
		var point := tip+axis*float(nail.length)+dorsal*.009+Vector3(0,1.13,0)
		assert(nail_points.has(key(point)), "Each physical nail point must track its anatomical fingertip")
	var motion: RefCounted = load("res://scripts/slender_animation.gd").new()
	motion.reset_pose()
	assert(motion.HIP_Y==2.26 and motion.LEG==1.06)
	assert(absf(motion.feet[0].y-.14)<.00001)
	assert(absf(motion.TIE_ROOT.y-3.306)<.00001)
	print("[proportions-test] PASS: ten 2x anatomical fingers, ten pointed nails, actual runtime skin mapping; 2x thigh/shin bones, matching IK and translated tie")
	host.queue_free()
	quit()
func key(p: Vector3) -> String:
	# Match after float32 conversion (SurfaceTool vertices are PackedVector3).
	var rounded := PackedVector3Array([p])[0]
	return "%.6f/%.6f/%.6f" % [rounded.x,rounded.y,rounded.z]
