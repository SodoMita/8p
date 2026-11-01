class_name TerrainSurface
extends RefCounted
## Builds a shared, smoothly-normaled grid mesh from a world-space height sampler.
## The same ArrayMesh can be rendered and used as a static trimesh collider.


static func build_grid(center: Vector3, size: Vector2, cells_x: int, cells_z: int,
		height_sampler: Callable, vertical_offset := 0.0) -> ArrayMesh:
	var nx := maxi(cells_x, 1)
	var nz := maxi(cells_z, 1)
	var step_x := size.x / float(nx)
	var step_z := size.y / float(nz)
	var start_x := center.x - size.x * 0.5
	var start_z := center.z - size.y * 0.5
	var vertices := PackedVector3Array()
	var normals := PackedVector3Array()
	var uvs := PackedVector2Array()
	var indices := PackedInt32Array()
	vertices.resize((nx + 1) * (nz + 1))
	normals.resize((nx + 1) * (nz + 1))
	uvs.resize((nx + 1) * (nz + 1))

	for z in range(nz + 1):
		for x in range(nx + 1):
			var world_x := start_x + float(x) * step_x
			var world_z := start_z + float(z) * step_z
			var index := z * (nx + 1) + x
			var height := _sample(height_sampler, world_x, world_z) + vertical_offset
			vertices[index] = Vector3(world_x, height, world_z)
			uvs[index] = Vector2(world_x, world_z)

			# Central differences keep the lighting continuous across cell edges.
			var left := _sample(height_sampler, world_x - step_x * 0.5, world_z)
			var right := _sample(height_sampler, world_x + step_x * 0.5, world_z)
			var back := _sample(height_sampler, world_x, world_z - step_z * 0.5)
			var front := _sample(height_sampler, world_x, world_z + step_z * 0.5)
			var slope_x := (right - left) / step_x
			var slope_z := (front - back) / step_z
			normals[index] = Vector3(-slope_x, 1.0, -slope_z).normalized()

	for z in range(nz):
		for x in range(nx):
			var a := z * (nx + 1) + x
			var b := a + 1
			var c := a + nx + 1
			var d := c + 1
			# Godot's concave triangle collision treats the opposite winding as
			# its walkable/front face; render normals are supplied independently.
			indices.append(a)
			indices.append(b)
			indices.append(c)
			indices.append(b)
			indices.append(d)
			indices.append(c)

	var arrays: Array = []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = vertices
	arrays[Mesh.ARRAY_NORMAL] = normals
	arrays[Mesh.ARRAY_TEX_UV] = uvs
	arrays[Mesh.ARRAY_INDEX] = indices
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return mesh


static func _sample(height_sampler: Callable, x: float, z: float) -> float:
	if not height_sampler.is_valid():
		return 0.0
	return float(height_sampler.call(Vector3(x, 0.0, z)))
