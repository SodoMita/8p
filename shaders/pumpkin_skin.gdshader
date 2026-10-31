shader_type spatial;
render_mode cull_disabled;
// Vertex alpha distinguishes woody stem from rind without another draw call.
varying vec3 world_pos;
varying vec3 outward_normal;
varying vec3 region_color;
varying float rind;
float hash(vec3 p) {
 p = fract(p * 0.1031); p += dot(p, p.yzx + 33.33);
 return fract((p.x + p.y) * p.z);
}
float noise3(vec3 p) {
 vec3 i = floor(p); vec3 f = fract(p); f = f*f*(3.0-2.0*f);
 return mix(mix(mix(hash(i),hash(i+vec3(1,0,0)),f.x),mix(hash(i+vec3(0,1,0)),hash(i+vec3(1,1,0)),f.x),f.y),mix(mix(hash(i+vec3(0,0,1)),hash(i+vec3(1,0,1)),f.x),mix(hash(i+vec3(0,1,1)),hash(i+vec3(1,1,1)),f.x),f.y),f.z);
}
void vertex() {
 world_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
 outward_normal = normalize(MODEL_NORMAL_MATRIX * NORMAL);
 region_color = COLOR.rgb;
 rind = COLOR.a;
}
void fragment() {
 // Preserve baked outward normals on the double-sided rind.
 NORMAL = normalize((VIEW_MATRIX * vec4(outward_normal, 0.0)).xyz);
 float flecks = noise3(world_pos * 120.0);
 float patches = noise3(world_pos * 13.0);
 float veins = noise3(world_pos * vec3(80.0, 8.0, 80.0));
 vec3 orange = mix(vec3(0.26,0.065,0.012),vec3(0.62,0.24,0.035), patches * 0.65 + 0.2);
 orange *= (0.83 + flecks * 0.26) * region_color;
 float soil = (1.0-smoothstep(0.02,0.18,world_pos.y)) * (0.3 + patches * 0.65);
 orange = mix(orange,vec3(0.065,0.043,0.021),soil);
 vec3 woody = mix(vec3(0.075,0.065,0.026),vec3(0.23,0.19,0.075),veins) * (0.8 + flecks * 0.3);
 ALBEDO = mix(woody,orange,step(0.5,rind));
 ROUGHNESS = mix(0.94,0.67 + flecks * 0.17,step(0.5,rind));
 SPECULAR = 0.28;
}
