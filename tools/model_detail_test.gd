extends SceneTree
## Structural checks for the pumpkin/concrete follow-up.
func _initialize() -> void:
	var failures := 0
	for variant in 3:
		var mesh: ArrayMesh = load("res://assets/models/pumpkin_%d.res" % variant)
		var arrays := mesh.surface_get_arrays(0)
		var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
		var normals: PackedVector3Array = arrays[Mesh.ARRAY_NORMAL]
		var colors: PackedColorArray = arrays[Mesh.ARRAY_COLOR]
		var stem := 0
		var skin := 0
		for i in vertices.size():
			if not vertices[i].is_finite() or not normals[i].is_finite() or normals[i].length() < 0.9:
				failures += 1
			if colors[i].a < 0.5:
				stem += 1
			else:
				skin += 1
		if stem == 0 or skin == 0:
			failures += 1
		print("[model_detail_test] pumpkin %d: %d skin vertices, %d stem vertices" % [variant, skin, stem])
	var map = load("res://scripts/map_builder.gd").new()
	var concrete: ArrayMesh = map._chamfered_concrete(Vector3(4, 3, 0.4), Vector3.ZERO)
	if concrete.get_aabb().size.distance_to(Vector3(4,3,0.4)) > 0.001:
		failures += 1
	var indices: PackedInt32Array = concrete.surface_get_arrays(0)[Mesh.ARRAY_INDEX]
	if indices.size() != 44 * 3:
		failures += 1
	print("[model_detail_test] concrete: %d triangles, original collision bounds retained" % (indices.size() / 3))
	map.free()
	print("[model_detail_test] failures: ", failures)
	quit(0 if failures == 0 else 1)
