extends Node3D
## 3D presentation of the (2D) simulation. 2.5D: everything still happens on the arena plane
## in main.gd; this node only *reads* positions every frame and draws them in 3D. Nothing here
## is ever read back by the game, so replays, the AI and the tests are unaffected.
##
## Mapping: 2D pixel (x, y) -> 3D (x, 0, y) around the arena centre, SCALE pixels per metre.
## Press V in game to switch between this and the original 2D view.

const Cfg = preload("res://scripts/game_config.gd")
const FLOOR_SHADER = preload("res://shaders/floor.gdshader")

const SCALE := 40.0
const CAM_PITCH := 55.0             # degrees below horizontal
const CAM_DIST := 22.0
const CAM_FOLLOW := 0.15            # 0 = fixed on the arena centre, 1 = locked on the player
const C_PLAYER := Color(0.35, 0.85, 1.0)
const C_SHADOW := Color(0.7, 0.3, 1.0)
const C_AIMED := Color(1.0, 0.25, 0.3)
const C_EXPLORE := Color(0.35, 0.6, 1.0)
const C_THORN := Color(1.0, 0.2, 0.25)
const C_POCKET := Color(0.35, 0.95, 0.75)
const MAX_THORN_CELLS := 20
const AFTERIMAGES := 12

var game                            # main.gd
var camera: Camera3D

var _center := Cfg.ARENA.get_center()
var _cam_target := Vector3.ZERO
var _clock := 0.0

var _floor_mat: ShaderMaterial
var _heat_img: Image
var _heat_tex: ImageTexture

var _player: Node3D
var _player_body: MeshInstance3D
var _after: Array = []              # [MeshInstance3D, StandardMaterial3D]
var _shadow: Node3D
var _shadow_body: MeshInstance3D
var _shadow_light: OmniLight3D
var _ghost: Node3D
var _ghost_mat: StandardMaterial3D
var _pocket: Node3D
var _pocket_mat: StandardMaterial3D
var _pocket_light: OmniLight3D

var _attacks := {}                  # attack instance id -> Dictionary of nodes/materials
var _flashes: Array = []            # [Node3D, StandardMaterial3D, OmniLight3D, age]
var _spikes: MultiMeshInstance3D
var _tiles: MultiMeshInstance3D
var _particles: MultiMeshInstance3D
var _plan_mesh: ImmediateMesh
var _plan_mat: StandardMaterial3D


func _ready() -> void:
	_build_environment()
	_build_floor()
	_build_actors()
	_build_effects()


# --- Public helpers --------------------------------------------------------------

func to3(p: Vector2, h: float = 0.0) -> Vector3:
	return Vector3((p.x - _center.x) / SCALE, h, (p.y - _center.y) / SCALE)


## Screen position (window pixels) of a 2D arena point lifted to height `h`.
func screen_pos(p: Vector2, h: float = 0.0) -> Vector2:
	if camera == null:
		return p
	return camera.unproject_position(to3(p, h)) + Cfg.ARENA.position


# --- Per frame ----------------------------------------------------------------------

func _process(delta: float) -> void:
	if game == null or game.player == null:
		return
	_clock += delta
	_update_camera(delta)
	_update_player()
	_update_shadow(delta)
	_update_ghost()
	_update_attacks()
	_update_flashes(delta)
	_update_thorns()
	_update_pocket()
	_update_heat()
	_update_plan()
	_update_particles()


func _update_camera(delta: float) -> void:
	var want := to3(_center).lerp(to3(game.player.position), CAM_FOLLOW)
	_cam_target = _cam_target.lerp(want, 1.0 - exp(-4.0 * delta))
	var back := Vector3(0.0, sin(deg_to_rad(CAM_PITCH)), cos(deg_to_rad(CAM_PITCH))) * CAM_DIST
	# Screen shake comes from fx.gd's trauma (the same offset the 2D camera uses).
	var off: Vector2 = game.fx.camera.offset / SCALE if game.fx.camera != null else Vector2.ZERO
	camera.position = _cam_target + back + Vector3(off.x, off.y, 0.0) * 1.5
	camera.look_at(_cam_target + Vector3(off.x, 0.0, off.y) * 0.5, Vector3.UP)


func _update_player() -> void:
	var pl = game.player
	_player.position = to3(pl.position)
	_face(_player, pl.facing)
	var blink: bool = pl._invuln > 0.0 and int(pl._invuln * 12.0) % 2 == 0
	_player_body.visible = not blink
	_player.scale = Vector3.ONE * (1.0 if pl.alive else 0.6)
	var imgs: Array = pl._afterimages
	for i in AFTERIMAGES:
		var mi: MeshInstance3D = _after[i][0]
		if i < imgs.size():
			var fade := 1.0 - float(imgs[i][1]) / 0.25
			mi.visible = true
			mi.position = to3(imgs[i][0], 0.45)
			mi.scale = Vector3.ONE * (0.6 + 0.4 * fade)
			var m: StandardMaterial3D = _after[i][1]
			m.albedo_color = Color(C_PLAYER, 0.35 * fade)
		else:
			mi.visible = false


func _update_shadow(delta: float) -> void:
	var sh = game.shadow
	var flash: float = sh._flash
	_shadow.position = to3(sh.position, 1.1 + 0.15 * sin(_clock * 2.0))
	var look := to3(game.player.position, _shadow.position.y)
	if look.distance_to(_shadow.position) > 0.05:
		_shadow.look_at(look, Vector3.UP)
	_shadow_body.scale = _shadow_body.scale.lerp(Vector3.ONE * (1.0 + flash * 1.4), 1.0 - exp(-12.0 * delta))
	_shadow_light.light_energy = 1.4 + flash * 10.0


func _update_ghost() -> void:
	var gh = game.ghost
	_ghost.visible = gh.visible
	if not gh.visible:
		return
	_ghost.position = to3(gh.position)
	_face(_ghost, gh.facing)
	var faint: bool = gh.harmless > 0.0 and int(gh.harmless * 10.0) % 2 == 0
	_ghost_mat.albedo_color = Color(0.6, 0.3, 0.95, 0.25 if faint else 0.6)


func _update_attacks() -> void:
	var seen := {}
	for a in game._live_attacks:
		if not is_instance_valid(a):
			continue
		var id: int = a.get_instance_id()
		seen[id] = true
		if not _attacks.has(id):
			_attacks[id] = _make_attack(a)
		var d: Dictionary = _attacks[id]
		var base: Color = C_EXPLORE if a.explored else C_AIMED
		var root: Node3D = d["root"]
		root.position = to3(a.position)
		if a.is_striking():
			if not d["struck"]:
				d["struck"] = true
				_spawn_flash(a.position, base)
			root.visible = false
			continue
		var p := clampf(a._age / a.windup, 0.0, 1.0)
		var pulse := 0.5 + 0.5 * sin(a._age * (8.0 + 30.0 * p))
		var disc_mat: StandardMaterial3D = d["disc_mat"]
		disc_mat.albedo_color = Color(base, 0.06 + 0.25 * p)
		var ring_mat: StandardMaterial3D = d["ring_mat"]
		ring_mat.emission_energy_multiplier = 1.5 + 3.0 * p * pulse
		var inner: MeshInstance3D = d["inner"]
		inner.scale = Vector3.ONE * maxf(0.02, 1.0 - p)
		var light: OmniLight3D = d["light"]
		light.light_energy = 0.4 + 2.5 * p * (0.6 + 0.4 * pulse)
	for id in _attacks.keys():
		if not seen.has(id):
			var old: Node3D = _attacks[id]["root"]
			old.queue_free()
			_attacks.erase(id)


func _update_flashes(delta: float) -> void:
	var keep: Array = []
	for f in _flashes:
		f[3] = float(f[3]) + delta
		var t: float = f[3] / 0.35
		var node: Node3D = f[0]
		if t >= 1.0:
			node.queue_free()
			continue
		var m: StandardMaterial3D = f[1]
		m.albedo_color = Color(1.4, 1.3, 1.2, 0.8 * (1.0 - t))
		node.scale = Vector3(1.0 + 0.4 * t, 1.0, 1.0 + 0.4 * t)
		var l: OmniLight3D = f[2]
		l.light_energy = 9.0 * (1.0 - t)
		keep.append(f)
	_flashes = keep


func _update_thorns() -> void:
	var ar = game.arena
	var cells: Array = []           # [cell, height scale 0..1, growing?]
	for c in ar.thorns:
		var grow: bool = ar.is_growing(c)
		var s := clampf(float(ar.thorns[c]) / Cfg.ARENA_GROW_TIME, 0.0, 1.0) if grow else 1.0
		cells.append([c, s, grow])
	for c in ar.withering:
		cells.append([c, clampf(float(ar.withering[c]) / Cfg.ARENA_WITHER_TIME, 0.0, 1.0), false])
	cells = cells.slice(0, MAX_THORN_CELLS)

	var mm := _spikes.multimesh
	var n := 0
	var tiles := _tiles.multimesh
	var tn := 0
	for item in cells:
		var r: Rect2 = ar.cell_rect(item[0])
		var s: float = item[1]
		for gx in 3:
			for gy in 3:
				# Deterministic jitter per spike so cells don't look like a grid of identical cones.
				var k := int(item[0]) * 9 + gx * 3 + gy
				var jx := fmod(sin(float(k) * 12.9898) * 43758.5453, 1.0) * 0.25
				var jy := fmod(sin(float(k) * 78.233) * 12345.678, 1.0) * 0.25
				var p := r.position + Vector2((gx + 0.5 + jx) * r.size.x / 3.0, (gy + 0.5 + jy) * r.size.y / 3.0)
				var hs := maxf(0.01, s * (0.8 + 0.4 * absf(jx) * 4.0))
				var b := Basis().scaled(Vector3(1.0, hs, 1.0))
				mm.set_instance_transform(n, Transform3D(b, to3(p, 0.35 * hs)))
				n += 1
		if item[2]:
			var blink := 0.5 + 0.5 * sin(_clock * 18.0)
			tiles.set_instance_transform(tn, Transform3D(Basis().scaled(Vector3(r.size.x / SCALE, 1.0, r.size.y / SCALE)), to3(r.get_center(), 0.015)))
			tiles.set_instance_color(tn, Color(C_THORN.r * 2.0, C_THORN.g * 2.0, C_THORN.b * 2.0, 0.15 + 0.35 * blink))
			tn += 1
	mm.visible_instance_count = n
	tiles.visible_instance_count = tn


func _update_pocket() -> void:
	var ar = game.arena
	var on: bool = ar.pocket >= 0 and ar.pocket_charge > 0.0
	_pocket.visible = on
	if not on:
		return
	var r: Rect2 = ar.cell_rect(ar.pocket)
	_pocket.position = to3(r.get_center())
	var frac: float = ar.pocket_charge / Cfg.POCKET_SHELTER
	_pocket.scale = Vector3.ONE * (0.55 + 0.45 * frac)
	var pulse := 0.5 + 0.5 * sin(_clock * 3.0)
	_pocket_mat.albedo_color = Color(C_POCKET, 0.12 + 0.1 * pulse)
	_pocket_light.light_energy = 0.8 + 1.2 * frac


func _update_heat() -> void:
	var on: bool = game.show_ml
	_floor_mat.set_shader_parameter("heat_on", 0.35 if on else 0.0)
	if not on:
		return
	var ar = game.arena
	var m: float = ar.max_heat()
	for i in ar.heat.size():
		var v: float = ar.heat[i] / m if m > 0.0 else 0.0
		_heat_img.set_pixel(i % 12, floori(i / 12.0), Color(v, 0.0, 0.0))
	_heat_tex.update(_heat_img)


## The future path the Shadow believed you'd take (same as the 2D yellow/blue lines).
func _update_plan() -> void:
	_plan_mesh.clear_surfaces()
	var age: float = game.last_plan_age
	if not game.show_ml or age > 1.6 or game.last_plan.is_empty():
		return
	var fade := 1.0 - age / 1.6
	for item in game.last_plan:
		var path: Array = item["path"]
		if path.size() < 2:
			continue
		var col := Color(0.5, 0.75, 1.6, 0.8 * fade) if item["explored"] else Color(1.6, 1.3, 0.4, 0.8 * fade)
		_plan_mesh.surface_begin(Mesh.PRIMITIVE_LINE_STRIP, _plan_mat)
		for pt in path:
			_plan_mesh.surface_set_color(col)
			_plan_mesh.surface_add_vertex(to3(pt, 0.06))
		_plan_mesh.surface_end()


## fx.gd's particles (it keeps simulating them in 3D mode) drawn as glowing billboards.
func _update_particles() -> void:
	var parts: Array = game.fx._parts
	var mm := _particles.multimesh
	var n := mini(parts.size(), mm.instance_count)
	for i in n:
		var p: Array = parts[i]
		var t: float = p[2] / p[3]
		var c: Color = p[4]
		var s: float = p[5] / 2.5
		mm.set_instance_transform(i, Transform3D(Basis().scaled(Vector3.ONE * s), to3(p[0], 0.25 + 0.6 * t)))
		mm.set_instance_color(i, Color(c.r * 2.2, c.g * 2.2, c.b * 2.2, t))
	mm.visible_instance_count = n


# --- Construction ------------------------------------------------------------------

func _build_environment() -> void:
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color(0.015, 0.015, 0.03)
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.3, 0.32, 0.5)
	env.ambient_light_energy = 0.35
	env.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	env.glow_enabled = true
	env.glow_intensity = 0.9
	env.glow_bloom = 0.08
	env.glow_hdr_threshold = 0.85
	env.glow_blend_mode = Environment.GLOW_BLEND_MODE_ADDITIVE
	env.fog_enabled = true
	env.fog_light_color = Color(0.08, 0.06, 0.16)
	env.fog_density = 0.012
	var we := WorldEnvironment.new()
	we.environment = env
	add_child(we)

	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-62.0, 25.0, 0.0)
	sun.light_color = Color(0.6, 0.65, 1.0)
	sun.light_energy = 0.35
	sun.shadow_enabled = true
	add_child(sun)

	camera = Camera3D.new()
	camera.fov = 50.0
	camera.position = Vector3(0.0, sin(deg_to_rad(CAM_PITCH)), cos(deg_to_rad(CAM_PITCH))) * CAM_DIST
	add_child(camera)
	camera.make_current()
	camera.look_at(Vector3.ZERO, Vector3.UP)


func _build_floor() -> void:
	var size := Cfg.ARENA.size / SCALE
	var floor_mesh := PlaneMesh.new()
	floor_mesh.size = size
	_heat_img = Image.create_empty(12, 10, false, Image.FORMAT_RF)
	_heat_tex = ImageTexture.create_from_image(_heat_img)
	_floor_mat = ShaderMaterial.new()
	_floor_mat.shader = FLOOR_SHADER
	_floor_mat.set_shader_parameter("heat_tex", _heat_tex)
	var fl := MeshInstance3D.new()
	fl.mesh = floor_mesh
	fl.material_override = _floor_mat
	add_child(fl)

	# Low glowing walls around the arena.
	var wall_mat := _mat(Color(0.08, 0.1, 0.18), Color(0.3, 0.4, 0.9), 1.2)
	var t := 0.15
	var h := 0.35
	for spec in [[Vector3(0, h / 2, -size.y / 2 - t / 2), Vector3(size.x + 2 * t, h, t)],
			[Vector3(0, h / 2, size.y / 2 + t / 2), Vector3(size.x + 2 * t, h, t)],
			[Vector3(-size.x / 2 - t / 2, h / 2, 0), Vector3(t, h, size.y)],
			[Vector3(size.x / 2 + t / 2, h / 2, 0), Vector3(t, h, size.y)]]:
		var box := BoxMesh.new()
		box.size = spec[1]
		var w := MeshInstance3D.new()
		w.mesh = box
		w.material_override = wall_mat
		w.position = spec[0]
		add_child(w)


func _build_actors() -> void:
	var r := Cfg.PLAYER_RADIUS / SCALE

	# Player: glowing capsule with a nose that shows where you face.
	_player = Node3D.new()
	add_child(_player)
	_player_body = _capsule(r, 0.9, _mat(C_PLAYER, C_PLAYER, 1.6))
	_player.add_child(_player_body)
	var nose := MeshInstance3D.new()
	var nb := BoxMesh.new()
	nb.size = Vector3(0.1, 0.1, 0.25)
	nose.mesh = nb
	nose.material_override = _mat(Color.WHITE, Color.WHITE, 2.0)
	nose.position = Vector3(0.0, 0.15, -r - 0.1)    # relative to the capsule's centre
	_player_body.add_child(nose)
	_player.add_child(_light(C_PLAYER, 1.2, 3.0, Vector3(0, 0.9, 0)))
	for i in AFTERIMAGES:
		var m := _mat(C_PLAYER, C_PLAYER, 1.0, 0.3, true)
		var mi := MeshInstance3D.new()
		var cap := CapsuleMesh.new()
		cap.radius = r
		cap.height = 0.9
		mi.mesh = cap
		mi.material_override = m
		mi.visible = false
		add_child(mi)
		_after.append([mi, m])

	# Shadow: a floating dark orb with a purple light and two eyes that track you.
	_shadow = Node3D.new()
	add_child(_shadow)
	_shadow_body = MeshInstance3D.new()
	var sph := SphereMesh.new()
	sph.radius = 0.4
	sph.height = 0.8
	_shadow_body.mesh = sph
	var sm := _mat(Color(0.06, 0.02, 0.12), C_SHADOW, 0.6)
	sm.metallic = 0.6
	sm.roughness = 0.25
	sm.rim_enabled = true
	sm.rim = 1.0
	_shadow_body.material_override = sm
	_shadow.add_child(_shadow_body)
	for side in [-1.0, 1.0]:
		var eye := MeshInstance3D.new()
		var es := SphereMesh.new()
		es.radius = 0.07
		es.height = 0.14
		eye.mesh = es
		eye.material_override = _mat(Color(1.0, 0.4, 0.9), Color(1.0, 0.4, 0.9), 6.0)
		eye.position = Vector3(side * 0.14, 0.06, -0.36)
		_shadow_body.add_child(eye)
	_shadow_light = _light(C_SHADOW, 1.4, 4.5, Vector3.ZERO)
	_shadow_light.shadow_enabled = true
	_shadow.add_child(_shadow_light)

	# Ghost: a see-through purple copy of you.
	_ghost = Node3D.new()
	add_child(_ghost)
	_ghost_mat = _mat(Color(0.6, 0.3, 0.95, 0.6), Color(0.75, 0.4, 1.0), 1.5, 0.6)
	_ghost.add_child(_capsule(r, 0.9, _ghost_mat))
	_ghost.add_child(_light(Color(0.75, 0.4, 1.0), 1.0, 3.0, Vector3(0, 0.9, 0)))
	_ghost.visible = false

	# Blind spot: a soft green dome.
	_pocket = Node3D.new()
	add_child(_pocket)
	var dome := MeshInstance3D.new()
	var ds := SphereMesh.new()
	var cell := minf(Cfg.ARENA.size.x / 12.0, Cfg.ARENA.size.y / 10.0) / SCALE
	ds.radius = cell * 0.5
	ds.height = cell * 0.5
	ds.is_hemisphere = true
	dome.mesh = ds
	_pocket_mat = _mat(Color(C_POCKET, 0.2), C_POCKET, 1.2, 0.2, true)
	_pocket_mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	dome.material_override = _pocket_mat
	_pocket.add_child(dome)
	_pocket_light = _light(C_POCKET, 1.5, 2.5, Vector3(0, 0.4, 0))
	_pocket.add_child(_pocket_light)
	_pocket.visible = false


func _build_effects() -> void:
	# Thorn spikes (one MultiMesh for all cells) and blinking warning tiles.
	var cone := CylinderMesh.new()
	cone.top_radius = 0.0
	cone.bottom_radius = 0.16
	cone.height = 0.7
	cone.radial_segments = 6
	cone.rings = 1
	var thorn_mat := _mat(Color(0.3, 0.03, 0.06), C_THORN, 1.4)
	thorn_mat.metallic = 0.4
	_spikes = _multimesh(cone, thorn_mat, MAX_THORN_CELLS * 9, false)

	var tile := PlaneMesh.new()
	tile.size = Vector2(1.0, 1.0)
	var tile_mat := _mat(Color.WHITE, Color.BLACK, 0.0, 1.0, true)
	tile_mat.vertex_color_use_as_albedo = true
	_tiles = _multimesh(tile, tile_mat, MAX_THORN_CELLS, true)

	var quad := QuadMesh.new()
	quad.size = Vector2(0.14, 0.14)
	var pm := _mat(Color.WHITE, Color.BLACK, 0.0, 1.0, true)
	pm.vertex_color_use_as_albedo = true
	pm.billboard_mode = BaseMaterial3D.BILLBOARD_ENABLED
	_particles = _multimesh(quad, pm, 600, true)

	_plan_mesh = ImmediateMesh.new()
	_plan_mat = _mat(Color.WHITE, Color.BLACK, 0.0, 1.0, true)
	_plan_mat.vertex_color_use_as_albedo = true
	var plan := MeshInstance3D.new()
	plan.mesh = _plan_mesh
	add_child(plan)


func _make_attack(a) -> Dictionary:
	var base: Color = C_EXPLORE if a.explored else C_AIMED
	var rad: float = a.radius / SCALE
	var root := Node3D.new()
	add_child(root)

	var disc := MeshInstance3D.new()
	var cyl := CylinderMesh.new()
	cyl.top_radius = rad
	cyl.bottom_radius = rad
	cyl.height = 0.02
	disc.mesh = cyl
	var disc_mat := _mat(Color(base, 0.1), Color.BLACK, 0.0, 0.1, true)
	disc.material_override = disc_mat
	disc.position.y = 0.02
	root.add_child(disc)

	var ring := MeshInstance3D.new()
	var tor := TorusMesh.new()
	tor.inner_radius = rad - 0.05
	tor.outer_radius = rad + 0.04
	ring.mesh = tor
	var ring_mat := _mat(base, base, 1.5)
	ring.material_override = ring_mat
	ring.position.y = 0.04
	root.add_child(ring)

	var inner := MeshInstance3D.new()
	var tor2 := TorusMesh.new()
	tor2.inner_radius = rad - 0.04
	tor2.outer_radius = rad + 0.02
	inner.mesh = tor2
	inner.material_override = _mat(base, base, 1.0)
	inner.position.y = 0.05
	root.add_child(inner)

	var light := _light(base, 0.4, rad * 1.8, Vector3(0, 0.7, 0))
	root.add_child(light)
	return {"root": root, "disc_mat": disc_mat, "ring_mat": ring_mat, "inner": inner,
			"light": light, "struck": false}


## A column of light where a strike lands.
func _spawn_flash(at: Vector2, base: Color) -> void:
	var root := Node3D.new()
	add_child(root)
	root.position = to3(at)
	var col := MeshInstance3D.new()
	var cyl := CylinderMesh.new()
	cyl.top_radius = Cfg.ATTACK_RADIUS / SCALE * 0.7
	cyl.bottom_radius = Cfg.ATTACK_RADIUS / SCALE
	cyl.height = 5.0
	col.mesh = cyl
	col.position.y = 2.5
	var m := _mat(Color(1.4, 1.3, 1.2, 0.8), Color.BLACK, 0.0, 0.8, true)
	col.material_override = m
	root.add_child(col)
	var l := _light(Color(1.0, 0.9, 0.85).lerp(base, 0.4), 9.0, 6.0, Vector3(0, 1.0, 0))
	root.add_child(l)
	_flashes.append([root, m, l, 0.0])


# --- Small builders ------------------------------------------------------------------

func _mat(albedo: Color, emission: Color = Color.BLACK, energy: float = 0.0,
		alpha: float = 1.0, unshaded: bool = false) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = Color(albedo, alpha)
	if energy > 0.0:
		m.emission_enabled = true
		m.emission = emission
		m.emission_energy_multiplier = energy
	if alpha < 1.0 or unshaded:
		m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	if unshaded:
		m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	return m


func _capsule(radius: float, height: float, m: Material) -> MeshInstance3D:
	var cap := CapsuleMesh.new()
	cap.radius = radius
	cap.height = height
	var mi := MeshInstance3D.new()
	mi.mesh = cap
	mi.material_override = m
	mi.position.y = height * 0.5
	return mi


func _light(col: Color, energy: float, rng: float, at: Vector3) -> OmniLight3D:
	var l := OmniLight3D.new()
	l.light_color = col
	l.light_energy = energy
	l.omni_range = rng
	l.position = at
	return l


func _multimesh(mesh: Mesh, m: Material, count: int, colors: bool) -> MultiMeshInstance3D:
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.use_colors = colors
	mm.mesh = mesh
	mm.instance_count = count
	mm.visible_instance_count = 0
	var mmi := MultiMeshInstance3D.new()
	mmi.multimesh = mm
	mmi.material_override = m
	add_child(mmi)
	return mmi


## Turn a node so its -Z axis points along a 2D facing vector.
func _face(n: Node3D, facing: Vector2) -> void:
	if facing.length_squared() > 0.0001:
		n.rotation.y = atan2(-facing.x, -facing.y)
