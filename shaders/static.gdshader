shader_type canvas_item;
render_mode unshaded;

uniform sampler2D noise_tex : repeat_enable, filter_linear_mipmap;
uniform float intensity : hint_range(0.0, 1.0) = 0.0;
uniform float burst : hint_range(0.0, 1.0) = 0.0;

// Cheap film-grain / VHS static: a single texture fetch is re-used with a
// scrolling offset, so this stays affordable even on software renderers.
void fragment() {
	float t = TIME;
	vec2 uvn = UV * vec2(1.78, 1.0);

	float n = texture(noise_tex, uvn * 4.0 + vec2(t * 0.21, -t * 0.63)).r;
	float n2 = texture(noise_tex, uvn * 0.9 + vec2(t * 0.017, t * 0.009)).b;
	float scan = 0.5 + 0.5 * sin(UV.y * 620.0 + t * 11.0);
	float grain = n * 0.7 + n2 * 0.3;

	float a = intensity * (0.22 + 0.78 * grain);
	a += intensity * 0.07 * scan;
	a = max(a, burst * (0.30 + 0.40 * grain));
	a = clamp(a, 0.0, 0.75);

	vec3 col = mix(vec3(0.004, 0.004, 0.007), vec3(0.60, 0.64, 0.68), grain * 0.8 + scan * 0.2);
	col = mix(col, vec3(1.0, 0.97, 0.94), burst * 0.5);
	COLOR = vec4(col, a);
}
