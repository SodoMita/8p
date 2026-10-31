shader_type spatial;
// World-space corrosion: consistent texel density across differently sized props.
uniform vec4 paint_color : source_color = vec4(0.16, 0.19, 0.17, 1.0);
uniform vec4 rust_color : source_color = vec4(0.28, 0.105, 0.038, 1.0);
uniform float corrosion : hint_range(0.0, 1.0) = 0.45;
varying vec3 world_pos;
float hash(vec3 p) {
	p = fract(p * 0.1031);
	p += dot(p, p.yzx + 33.33);
	return fract((p.x + p.y) * p.z);
}
float noise3(vec3 p) {
	vec3 i = floor(p);
	vec3 f = fract(p);
	f = f * f * (3.0 - 2.0 * f);
	return mix(mix(mix(hash(i), hash(i + vec3(1,0,0)), f.x),
		mix(hash(i + vec3(0,1,0)), hash(i + vec3(1,1,0)), f.x), f.y),
		mix(mix(hash(i + vec3(0,0,1)), hash(i + vec3(1,0,1)), f.x),
		mix(hash(i + vec3(0,1,1)), hash(i + vec3(1,1,1)), f.x), f.y), f.z);
}
void vertex() { world_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz; }
void fragment() {
	float patches = noise3(world_pos * 3.5);
	float pits = noise3(world_pos * 48.0);
	float streaks = noise3(world_pos * vec3(16.0, 0.65, 16.0));
	float rust = smoothstep(1.0 - corrosion - 0.16, 1.0 - corrosion + 0.16, patches * 0.7 + streaks * 0.3);
	ALBEDO = mix(paint_color.rgb, rust_color.rgb, rust) * (0.72 + pits * 0.38);
	ROUGHNESS = mix(0.48, 0.97, rust);
	METALLIC = mix(0.65, 0.06, rust);
}
