shader_type canvas_item;
// Full-screen hit effect: chromatic aberration (red and blue channels pushed apart from the
// centre) plus a red vignette. `amount` is 0 when idle; post_fx.gd hides the rect then.

uniform sampler2D screen_tex : hint_screen_texture, filter_linear;
uniform float amount : hint_range(0.0, 1.0) = 0.0;

void fragment() {
	vec2 uv = SCREEN_UV;
	vec2 dir = uv - vec2(0.5);
	float k = amount * 0.014;
	float r = texture(screen_tex, uv + dir * k).r;
	float g = texture(screen_tex, uv).g;
	float b = texture(screen_tex, uv - dir * k).b;
	vec3 col = vec3(r, g, b);
	float vig = smoothstep(0.3, 0.8, length(dir)) * amount;
	col = mix(col, vec3(0.55, 0.0, 0.06), vig * 0.5);
	COLOR = vec4(col, 1.0);
}
