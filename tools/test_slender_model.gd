extends SceneTree
## Headless mesh contract regression test; exits nonzero on failure.
func _initialize() -> void:
	var parent := Node3D.new()
	root.add_child(parent)
	var parts: Array[MeshInstance3D] = load("res://scripts/slender_model.gd").new().build(parent)
	assert(parts.size() == 5, "Five material batches expected")
	var triangles := 0
	var bounds := AABB()
	for part in parts:
		assert(part.material_override.cull_mode == BaseMaterial3D.CULL_DISABLED)
		assert(part.mesh.get_surface_count() == 1)
		var arrays := part.mesh.surface_get_arrays(0)
		var verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
		var normals: PackedVector3Array = arrays[Mesh.ARRAY_NORMAL]
		assert(verts.size() == normals.size())
		assert(verts.size() % 3 == 0)
		triangles += verts.size() / 3
		for i in verts.size():
			assert(verts[i].is_finite() and normals[i].is_finite())
			assert(absf(normals[i].length() - 1.0) < 0.001)
			bounds = bounds.expand(verts[i])
		for i in range(0, verts.size(), 3):
			var cross := (verts[i+1] - verts[i]).cross(verts[i+2] - verts[i])
			assert(cross.dot(normals[i] + normals[i+1] + normals[i+2]) <= 0.00001, "Clockwise winding must agree with outward normals")
	assert(bounds.end.y > 2.75 and bounds.end.y < 2.8)
	assert(bounds.position.y >= 0.0)
	assert(triangles < 40000, "Keep the mobile geometry budget bounded")
	var other := Node3D.new()
	root.add_child(other)
	var copy: Array[MeshInstance3D] = load("res://scripts/slender_model.gd").new().build(other)
	for i in parts.size():
		assert(parts[i].mesh.surface_get_arrays(0)[Mesh.ARRAY_VERTEX] == copy[i].mesh.surface_get_arrays(0)[Mesh.ARRAY_VERTEX], "Reproducible geometry")
	print("[model-test] PASS: 5 batches, %d triangles; finite/unit normals, clockwise winding, double-sided, height, deterministic generation" % triangles)
	parent.queue_free()
	other.queue_free()
	quit()
