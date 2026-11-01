extends RefCounted
## Builds reusable static collision shapes from the rendered lower-trunk triangles.
## The player only reaches the first few metres of a tree; using the actual mesh
## there gives accurate trunk contact without loading every high branch triangle
## into physics for hundreds of streamed trees.

const PLAYER_CONTACT_HEIGHT := 3.0
const GROUND_TOLERANCE := 0.35


static func from_visible_mesh(mesh: Mesh) -> ConcavePolygonShape3D:
	if mesh == null:
		return null
	var collision_mesh := ArrayMesh.new()
	for surface_i in mesh.get_surface_count():
		var arrays: Array = mesh.surface_get_arrays(surface_i)
		if arrays.size() <= Mesh.ARRAY_VERTEX or arrays[Mesh.ARRAY_VERTEX] == null:
			continue
		var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
		var indices: PackedInt32Array = arrays[Mesh.ARRAY_INDEX] if arrays[Mesh.ARRAY_INDEX] != null else PackedInt32Array()
		var source_count := indices.size() if not indices.is_empty() else vertices.size()
		var faces := PackedVector3Array()
		for first in range(0, source_count - 2, 3):
			var i0: int = indices[first] if not indices.is_empty() else first
			var i1: int = indices[first + 1] if not indices.is_empty() else first + 1
			var i2: int = indices[first + 2] if not indices.is_empty() else first + 2
			var a := vertices[i0]
			var b := vertices[i1]
			var c := vertices[i2]
			if maxf(a.y, maxf(b.y, c.y)) > PLAYER_CONTACT_HEIGHT:
				continue
			if minf(a.y, minf(b.y, c.y)) < -GROUND_TOLERANCE:
				continue
			faces.append(a)
			faces.append(b)
			faces.append(c)
		if faces.is_empty():
			continue
		var collision_arrays: Array = []
		collision_arrays.resize(Mesh.ARRAY_MAX)
		collision_arrays[Mesh.ARRAY_VERTEX] = faces
		collision_mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, collision_arrays)
	if collision_mesh.get_surface_count() == 0:
		return null
	return collision_mesh.create_trimesh_shape()
