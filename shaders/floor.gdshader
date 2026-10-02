shader_type spatial;
// Arena floor for the 3D view: dark tiles with faint glowing grid lines on the arena shaper's
// 12x10 cells, plus the heat map (where you stand most) glowing orange when F1 is on.

uniform sampler2D heat_tex : filter_linear, repeat_disable;
uniform float heat_on = 0.0;
uniform vec2 cells = vec2(12.0, 10.0);

void fragment() {
	vec2 g = fract(UV * cells);
	float line = 1.0 - smoothstep(0.0, 0.025, min(min(g.x, 1.0 - g.x), min(g.y, 1.0 - g.y)));
	float h = texture(heat_tex, UV).r * heat_on;
	ALBEDO = vec3(0.045, 0.05, 0.075) + line * vec3(0.03, 0.04, 0.07);
	ROUGHNESS = 0.55;
	METALLIC = 0.25;
	EMISSION = line * vec3(0.05, 0.09, 0.2) + h * vec3(1.4, 0.55, 0.12);
}
