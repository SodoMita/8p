shader_type canvas_item;
render_mode unshaded;

uniform float strength : hint_range(0.0, 1.0) = 0.9;
uniform float inner : hint_range(0.0, 1.0) = 0.28;
uniform float outer : hint_range(0.0, 1.5) = 0.82;

void fragment() {
	vec2 d = (UV - vec2(0.5)) * vec2(1.15, 1.0);
	float v = smoothstep(inner, outer, length(d));
	COLOR = vec4(0.0, 0.0, 0.0, clamp(v * strength, 0.0, 1.0));
}
