extends Node
## HOOD gun camera (client-side, visual only).
##
## F8        toggle gun camera on/off
## F9        next preset      (shift+F9 previous)
## Hold SHIFT + arrows       move camera  (left/right = X, up/down = Y)
## Hold SHIFT + PgUp/PgDn    move camera  (Z, forward/back along the barrel)
## Hold CTRL  + arrows       rotate       (left/right = yaw, up/down = pitch)
## Hold CTRL  + PgUp/PgDn    roll (cant)
## F10       print current offset/rotation to the log (to bake into a preset)
## F11       reset current preset
##
## Mounts a Camera3D under the local player's first-person weapon view (shotgun
## first, then rifle/pistol, else the normal camera). Never touches the player's
## own camera, so aiming and shooting are unchanged. Remove the override.cfg
## entry to uninstall.

const TAG := "[GunCam] "

# name, position, rotation degrees (pitch, yaw, roll), shows_player
# Positions are relative to the weapon view node. The shotgun's Muzzle marker
# sits at (0.133, -0.032, -0.91); -Z is the barrel direction.
const PRESETS := [
	{"name": "Muzzle forward, canted", "pos": Vector3(0.133, 0.02, -0.95), "rot": Vector3(0, 0, 18), "player": false},
	{"name": "Muzzle looking back at player, canted", "pos": Vector3(0.133, 0.02, -0.95), "rot": Vector3(0, 180, 18), "player": true},
	{"name": "Over the barrel, back at player", "pos": Vector3(0.133, 0.12, -0.6), "rot": Vector3(-8, 180, -12), "player": true},
	{"name": "Side mount, forward", "pos": Vector3(0.28, 0.0, -0.5), "rot": Vector3(0, 0, 0), "player": false},
]

var _enabled := false
var _preset := 0
var _pos_adj: Array = []   # per-preset live adjustments
var _rot_adj: Array = []
var _cam: Camera3D
var _mount: Node
var _player: Node
var _hidden: Dictionary = {}   # MeshInstance3D -> original layers (first-person meshes hidden from GunCam)
var _scan_t := 0.0
const HIDE_LAYER := 1 << 19
const FP_NODES := ["ArmsView", "PistolView", "ShotgunView", "RifleView", "Hand", "Phone"]


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	for p in PRESETS:
		_pos_adj.append(Vector3.ZERO)
		_rot_adj.append(Vector3.ZERO)
	print(TAG, "loaded. F8 toggle, F9 next preset, F10 print, F11 reset")


func _unhandled_input(event: InputEvent) -> void:
	if not (event is InputEventKey) or not event.pressed or event.echo:
		return
	match event.keycode:
		KEY_F8:
			_set_enabled(not _enabled)
		KEY_F9:
			_preset = posmod(_preset + (-1 if event.shift_pressed else 1), PRESETS.size())
			print(TAG, "preset: ", PRESETS[_preset]["name"])
			if _enabled:
				_refresh_body()
		KEY_F10:
			var p: Dictionary = PRESETS[_preset]
			print(TAG, "preset '", p["name"], "' pos=", p["pos"] + _pos_adj[_preset],
				" rot=", p["rot"] + _rot_adj[_preset])
		KEY_F11:
			_pos_adj[_preset] = Vector3.ZERO
			_rot_adj[_preset] = Vector3.ZERO


func _local_player() -> Node:
	var n := get_tree().get_first_node_in_group(&"local_player")
	return n if n != null and is_instance_valid(n) else null


func _set_enabled(on: bool) -> void:
	if on:
		_player = _local_player()
		if _player == null:
			print(TAG, "no local player yet")
			return
		_enabled = true
		print(TAG, "on: ", PRESETS[_preset]["name"])
	else:
		_enabled = false
		_teardown()
		print(TAG, "off")


func _teardown() -> void:
	if _cam != null and is_instance_valid(_cam):
		_cam.queue_free()
	_cam = null
	_mount = null
	_unhide_fp()
	if _player != null and is_instance_valid(_player):
		var real := _player.get("camera") as Camera3D
		if real != null:
			real.make_current()
		if _player.has_method("_apply_view_mode"):
			_player.call("_apply_view_mode")
	_player = null


func _find_mount(player: Node) -> Node:
	var real := player.get("camera") as Camera3D
	if real == null:
		return null
	for n in ["ShotgunView", "RifleView", "PistolView"]:
		var v := real.get_node_or_null(NodePath(n)) as Node3D
		if v != null and v.visible:
			return v
	return real


func _hide_fp(real: Camera3D) -> void:
	# Tag first-person arms/weapon meshes with a layer GunCam doesn't render.
	for n in FP_NODES:
		var root := real.get_node_or_null(NodePath(n))
		if root == null:
			continue
		var meshes: Array = root.find_children("*", "VisualInstance3D", true, false)
		if root is VisualInstance3D:
			meshes.append(root)
		for m in meshes:
			if not _hidden.has(m):
				_hidden[m] = m.layers
			m.layers = HIDE_LAYER


func _unhide_fp() -> void:
	for m in _hidden:
		if is_instance_valid(m):
			m.layers = _hidden[m]
	_hidden.clear()


func _refresh_body() -> void:
	# The game hides the local body in first person; show it when the
	# preset looks back at the player.
	if _player == null:
		return
	var body := _player.get("body_visual") as Node3D
	var show: bool = bool(PRESETS[_preset]["player"])
	if body != null:
		body.visible = show
	if show:
		# Body holds the weapon itself (as in the game's third-person view).
		var ch = _player.get("character")
		if ch != null and ch.has_method("set_held_item") and _player.has_method("_hand_item_id") \
				and _player.has_method("_visual_held_id"):
			ch.call("set_held_item", _player.call("_visual_held_id", _player.call("_hand_item_id")))


func _process(delta: float) -> void:
	if not _enabled:
		return
	if _player == null or not is_instance_valid(_player):
		_set_enabled(false)
		return
	var real := _player.get("camera") as Camera3D
	if real == null:
		return

	var mount := _find_mount(_player)
	if mount == null:
		return
	if _cam == null or not is_instance_valid(_cam) or mount != _mount:
		if _cam != null and is_instance_valid(_cam):
			_cam.queue_free()
		_cam = Camera3D.new()
		_cam.name = "GunCam"
		mount.add_child(_cam)
		_mount = mount

	_adjust(delta)

	var p: Dictionary = PRESETS[_preset]
	# Weapon views other than the shotgun have their own muzzle spot; follow it.
	var base_pos: Vector3 = p["pos"]
	if mount.name != &"ShotgunView":
		var m := mount.get_node_or_null(^"Muzzle") as Node3D
		if m != null:
			base_pos = m.position + (base_pos - Vector3(0.133, -0.032, -0.91))
	_cam.position = base_pos + _pos_adj[_preset]
	var r: Vector3 = p["rot"] + _rot_adj[_preset]
	_cam.basis = Basis.from_euler(Vector3(deg_to_rad(r.x), deg_to_rad(r.y), deg_to_rad(r.z)), EULER_ORDER_YXZ)

	# Mirror the real camera's rendering settings every frame (fov changes when aiming).
	_cam.fov = real.fov
	_cam.near = 0.03
	_cam.far = real.far
	_cam.cull_mask = real.cull_mask
	if PRESETS[_preset]["player"]:
		_scan_t -= delta
		if _scan_t <= 0.0:
			_scan_t = 0.25
			_hide_fp(real)
		_cam.cull_mask &= ~HIDE_LAYER
	else:
		_unhide_fp()
	_cam.environment = real.environment
	_cam.attributes = real.attributes
	if not _cam.current:
		_cam.make_current()
	_refresh_body()


func _adjust(delta: float) -> void:
	var shift := Input.is_key_pressed(KEY_SHIFT)
	var ctrl := Input.is_key_pressed(KEY_CTRL)
	if not shift and not ctrl:
		return
	var h := float(Input.is_key_pressed(KEY_RIGHT)) - float(Input.is_key_pressed(KEY_LEFT))
	var v := float(Input.is_key_pressed(KEY_UP)) - float(Input.is_key_pressed(KEY_DOWN))
	var z := float(Input.is_key_pressed(KEY_PAGEDOWN)) - float(Input.is_key_pressed(KEY_PAGEUP))
	if shift:
		_pos_adj[_preset] += Vector3(h, v, z) * 0.5 * delta
	else:
		_rot_adj[_preset] += Vector3(v, -h, z) * 60.0 * delta
