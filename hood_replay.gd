extends Node
## HOOD instant replay (single-player, client-side).
##
## F6   start / stop recording (rolling buffer of the last KEEP_SECONDS)
## F7   start / stop replay of the recorded buffer
##
## While replaying (game is paused, HUD hidden, the real characters and bodies are
## driven from the recording; everything is restored when you exit):
##   Space            pause / play
##   Left / Right     scrub -/+ 2 s        Home / End  jump to start / end
##   [ / ]            slower / faster      (0.125x .. 4x)
##   1  free-fly camera   (WASD move, Q/E down/up, mouse look, Shift fast, Ctrl slow, wheel speed)
##   2  gun camera, looking forward, canted
##   3  gun camera, looking back at the shooter, canted
##   4  orbit camera around the target (mouse to orbit, wheel to zoom)
##   T  next target character (the player first)
##   Shift+arrows / PgUp/PgDn   move the mounted camera,  Ctrl+arrows / PgUp/PgDn  rotate / roll
##   F10  print the mounted camera offsets    F11 reset them
##   H    show / hide the timeline bar
##
## Recorded: the player and nearby NPC characters (global transform + every bone pose)
## and nearby RigidBody3D/vehicles (transform). Not recorded: effects, bullets, sounds.

const TAG := "[Replay] "
const KEEP_SECONDS := 60.0
const HZ := 30.0
const MAX_CHARS := 12
const CHAR_RADIUS := 45.0
const MAX_BODIES := 40
const BODY_RADIUS := 40.0
const MAX_VEH := 12      # vehicles are recorded separately so loose props can't crowd them out
const VEH_RADIUS := 150.0
const SCAN_BUDGET := 1500

enum S { IDLE, RECORDING, REPLAY }

var _state := S.IDLE
var _frames: Array = []        # {t: float, c: {id: [Transform3D, PackedFloat32Array]}, b: {id: Transform3D}}
var _clock := 0.0
var _acc := 0.0

# scene scan (incremental, so there is no hitch)
var _scan_stack: Array = []
var _found_chars: Array = []
var _found_bodies: Array = []
var _cand_chars: Array = []
var _cand_bodies: Array = []
var _found_veh: Array = []
var _cand_veh: Array = []
var _wheel_cache: Dictionary = {}   # vehicle id -> Array of VehicleWheel3D
var _wheels_live: Dictionary = {}   # wheel id -> local Transform3D before replay
var _skel_cache: Dictionary = {}
var _meta: Dictionary = {}      # id -> {model, scale} for building stand-ins
var _standins: Dictionary = {}  # id -> stand-in CharacterVisual for freed nodes

# shot effects (tracers, sounds, flashes, sparks, blood)
var _events: Array = []         # {t, kind, ...}
var _found_pool: Array = []     # pooled nodes found by the scanner (BloodBurst, MuzzleFlash)
var _pool: Array = []
var _prev_state: Dictionary = {}
var _ev_last := -1.0
var _fx: Array = []             # live replay effects: {node, kind, t0, t1, p0, p1}
var _fx_mesh: Mesh
var _fx_mat_spark: StandardMaterial3D
var _fx_mat_blood: StandardMaterial3D

# replay
var _t := 0.0
var _playing := true
var _speed := 1.0
var _mode := 1
var _live: Dictionary = {}     # id -> saved live state
var _hud_saved: Dictionary = {}
var _hud_t := 0.0
var _player: Node
var _real_cam: Camera3D
var _real_cam_visible := true
var _real_cam_xf := Transform3D.IDENTITY
var _real_cam_pim := 0
var _cam: Camera3D
var _free_pos := Vector3.ZERO
var _yaw := 0.0
var _pitch := 0.0
var _free_speed := 4.0
var _orbit_yaw := 0.0
var _orbit_pitch := -0.15
var _orbit_dist := 3.0
var _target_id := 0
var _mount: Node3D
var _mount_t := 0.0
const FP_FORWARD := 0.0 # metres the first-person camera sits in front of the eye point
var _pos_adj := {2: Vector3.ZERO, 3: Vector3.ZERO, 5: Vector3.ZERO}
var _rot_adj := {2: Vector3.ZERO, 3: Vector3.ZERO, 5: Vector3.ZERO}
var _layer: CanvasLayer
var _bar_bg: ColorRect
var _bar_fill: ColorRect
var _label: Label
var _help: Label
var _rec_cam := Transform3D.IDENTITY
var _rec_fov := 75.0
var _rec_cam_ok := false
var _base_fov := 75.0

const HELP_TEXT := """REPLAY CONTROLS   (F4 hide / show this)
Space  pause / play        Left / Right  scrub 2 s
Home / End  start / end    [ / ]  slower / faster
1  free-fly (WASD, Q/E, mouse, wheel speed, Shift fast)
2  gun cam forward        3  gun cam looking back
4  orbit (mouse, wheel)   5  first person   T  next target
Shift + arrows / PgUp PgDn  move gun cam
Ctrl + arrows / PgUp PgDn   rotate / roll gun cam
F10 print offsets   F11 reset   H timeline bar
Esc / F7  exit replay"""


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	process_priority = 1000  # run after the game's own _process so we read final poses
	get_tree().node_added.connect(_on_node_added)
	print(TAG, "loaded. F6 record, F7 replay")


# ------------------------------------------------------------------ shot effect recording

func _script_name(n: Node) -> String:
	var s = n.get_script()
	return String(s.resource_path) if s != null else ""


func _on_node_added(n: Node) -> void:
	if _state != S.RECORDING:
		return
	if n is AudioStreamPlayer3D:
		var st = n.stream
		var rp: String = String(st.resource_path) if st != null else ""
		if rp.contains("/Weapons/") or rp.contains("explosion"):
			_events.append({"t": _clock, "kind": "snd", "stream": st, "vol": n.volume_db,
				"pitch": n.pitch_scale, "maxd": n.max_distance, "unit": n.unit_size,
				"pos": n.global_position if n.is_inside_tree() else Vector3.ZERO})
		return
	if not (n is Node3D):
		return
	if n.name == &"BulletSparks":
		_events.append({"t": _clock, "kind": "spark", "pos": n.global_position,
			"normal": -n.global_basis.z})
		return
	if _script_name(n).ends_with("/projectile.gd"):
		var ev := {"t": _clock, "kind": "proj", "p0": n.global_position, "p1": n.global_position,
			"end": _clock + 0.35, "shotgun": false}
		_events.append(ev)
		n.tree_exiting.connect(_on_proj_exit.bind(ev, n))


func _on_proj_exit(ev: Dictionary, n: Node) -> void:
	if is_instance_valid(n) and n is Node3D:
		ev["p1"] = (n as Node3D).global_position
		ev["end"] = maxf(_clock, float(ev["t"]) + 0.03)


func _poll_pooled() -> void:
	# Blood bursts and the muzzle flash are pooled/reused nodes: detect the moment
	# they switch on.
	for n in _pool:
		if not is_instance_valid(n):
			continue
		var id: int = n.get_instance_id()
		if n is CPUParticles3D:
			var on: bool = n.emitting
			if on and not _prev_state.get(id, false):
				_events.append({"t": _clock, "kind": "blood", "pos": n.global_position,
					"normal": -n.global_basis.z})
			_prev_state[id] = on
		elif n is OmniLight3D:
			var on2: bool = n.visible
			if on2 and not _prev_state.get(id, false):
				_events.append({"t": _clock, "kind": "flash", "pos": n.global_position,
					"energy": n.light_energy})
			_prev_state[id] = on2


# ------------------------------------------------------------------ input

func _input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo:
		match event.keycode:
			KEY_F6:
				_toggle_record()
				return
			KEY_F7:
				_toggle_replay()
				return
		if _state == S.REPLAY:
			# Swallow the key so the game (pause menu, chat, GunCam F8...) never sees it.
			get_viewport().set_input_as_handled()
			if event.keycode == KEY_ESCAPE:
				_stop_replay()
				return
			_replay_key(event)
	elif event is InputEventMouseMotion and _state == S.REPLAY:
		var looking: bool = Input.mouse_mode == Input.MOUSE_MODE_CAPTURED \
			or Input.is_mouse_button_pressed(MOUSE_BUTTON_RIGHT)
		if looking:
			var r: Vector2 = event.relative * 0.0025
			if _mode == 4:
				_orbit_yaw -= r.x
				_orbit_pitch = clampf(_orbit_pitch - r.y, -1.4, 1.4)
			else:
				_yaw -= r.x
				_pitch = clampf(_pitch - r.y, -1.55, 1.55)
	elif event is InputEventMouseButton and event.pressed and _state == S.REPLAY:
		if event.button_index == MOUSE_BUTTON_WHEEL_UP:
			_wheel(-1.0)
		elif event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			_wheel(1.0)


func _wheel(dir: float) -> void:
	if _mode == 4:
		_orbit_dist = clampf(_orbit_dist + dir * 0.3, 0.8, 15.0)
	else:
		_free_speed = clampf(_free_speed * (0.85 if dir < 0.0 else 1.18), 0.5, 60.0)


func _replay_key(event: InputEventKey) -> void:
	var dur := _duration()
	match event.keycode:
		KEY_SPACE:
			_playing = not _playing
			if _playing and _t >= dur:
				_t = 0.0
		KEY_LEFT:
			if not event.shift_pressed and not event.ctrl_pressed:
				_t = clampf(_t - 2.0, 0.0, dur)
		KEY_RIGHT:
			if not event.shift_pressed and not event.ctrl_pressed:
				_t = clampf(_t + 2.0, 0.0, dur)
		KEY_HOME:
			_t = 0.0
		KEY_END:
			_t = dur
		KEY_BRACKETLEFT:
			_speed = maxf(0.125, _speed * 0.5)
		KEY_BRACKETRIGHT:
			_speed = minf(4.0, _speed * 2.0)
		KEY_1, KEY_2, KEY_3, KEY_4, KEY_5:
			_set_mode(event.keycode - KEY_0)
		KEY_T:
			_next_target()
		KEY_F4:
			if _help != null:
				_help.visible = not _help.visible
		KEY_H:
			if _layer != null:
				_layer.visible = not _layer.visible
		KEY_F10:
			if _pos_adj.has(_mode):
				print(TAG, "mode ", _mode, " pos adj=", _pos_adj[_mode], " rot adj=", _rot_adj[_mode])
		KEY_F11:
			if _pos_adj.has(_mode):
				_pos_adj[_mode] = Vector3.ZERO
				_rot_adj[_mode] = Vector3.ZERO


# ------------------------------------------------------------------ recording

func _local_player() -> Node:
	var n := get_tree().get_first_node_in_group(&"local_player")
	return n if n != null and is_instance_valid(n) else null


func _toggle_record() -> void:
	if _state == S.REPLAY:
		return
	if _state == S.RECORDING:
		_state = S.IDLE
		print(TAG, "recording stopped: ", snappedf(_duration(), 0.1), " s, ", _frames.size(), " frames")
		return
	if _local_player() == null:
		print(TAG, "no local player yet")
		return
	_frames.clear()
	_meta.clear()
	_events.clear()
	_prev_state.clear()
	_scan_stack.clear()
	_found_chars = []
	_found_bodies = []
	_found_veh = []
	_wheel_cache.clear()
	_clear_held_cache()
	_clock = 0.0
	_acc = 0.0
	_state = S.RECORDING
	print(TAG, "recording (last ", KEEP_SECONDS, " s kept)")


func _process(delta: float) -> void:
	if _state == S.RECORDING:
		_scan_step()
		_poll_pooled()
		_clock += delta
		_acc += delta
		if _acc >= 1.0 / HZ:
			_acc = fmod(_acc, 1.0 / HZ)
			_capture()
	elif _state == S.REPLAY:
		_replay_process(delta)


func _scan_step() -> void:
	if _scan_stack.is_empty():
		_cand_chars = _found_chars
		_cand_bodies = _found_bodies
		_cand_veh = _found_veh
		_pool = _found_pool
		_found_chars = []
		_found_bodies = []
		_found_veh = []
		_found_pool = []
		_scan_stack.append(get_tree().root)
	var budget := SCAN_BUDGET
	while budget > 0 and not _scan_stack.is_empty():
		var n = _scan_stack.pop_back()
		budget -= 1
		if n == null or not is_instance_valid(n):
			continue
		if _is_character(n):
			_found_chars.append(n)
			continue  # don't descend into the rig
		if n is VehicleBody3D:
			_found_veh.append(n)
		elif n is RigidBody3D:
			_found_bodies.append(n)
		elif (n is CPUParticles3D and String(n.name).begins_with("BloodBurst")) \
				or (n is OmniLight3D and n.name == &"MuzzleFlash"):
			_found_pool.append(n)
		for c in n.get_children():
			_scan_stack.append(c)


func _is_character(n: Node) -> bool:
	var s = n.get_script()
	return s != null and String(s.resource_path).ends_with("character_visual.gd")


func _skeleton_of(n: Node) -> Skeleton3D:
	var id := n.get_instance_id()
	var sk = _skel_cache.get(id)
	if sk == null or not is_instance_valid(sk):
		sk = n.find_child("Skeleton3D", true, false)
		_skel_cache[id] = sk
	return sk


class PreSnap extends SkeletonModifier3D:
	## Runs before the game's aim modifier and keeps the pure animation pose.
	var pose := PackedFloat32Array()

	func _process_modification() -> void:
		var sk := get_skeleton()
		if sk == null:
			return
		var n := sk.get_bone_count()
		pose.resize(n * 10)
		for i in n:
			var o := i * 10
			var p := sk.get_bone_pose_position(i)
			var q := sk.get_bone_pose_rotation(i)
			var s := sk.get_bone_pose_scale(i)
			pose[o] = p.x
			pose[o + 1] = p.y
			pose[o + 2] = p.z
			pose[o + 3] = q.x
			pose[o + 4] = q.y
			pose[o + 5] = q.z
			pose[o + 6] = q.w
			pose[o + 7] = s.x
			pose[o + 8] = s.y
			pose[o + 9] = s.z


func _presnap_of(sk: Skeleton3D) -> PreSnap:
	var m := sk.get_node_or_null(^"ReplayPreSnap") as PreSnap
	if m == null:
		m = PreSnap.new()
		m.name = "ReplayPreSnap"
		sk.add_child(m)
		sk.move_child(m, 0)  # before the game's AimOffset modifier
	return m


func _nearest(list: Array, origin: Vector3, radius: float, cap: int) -> Array:
	var scored: Array = []
	for n in list:
		if not is_instance_valid(n) or not (n is Node3D) or not n.is_inside_tree():
			continue
		var d := (n as Node3D).global_position.distance_to(origin)
		if d <= radius:
			scored.append([d, n])
	scored.sort_custom(func(a, b): return a[0] < b[0])
	var out: Array = []
	for i in mini(cap, scored.size()):
		out.append(scored[i][1])
	return out


func _capture() -> void:
	var player := _local_player()
	if player == null:
		return
	var origin: Vector3 = (player as Node3D).global_position
	var chars := _nearest(_cand_chars, origin, CHAR_RADIUS, MAX_CHARS)
	var own = player.get("character")
	if own != null and is_instance_valid(own) and not chars.has(own):
		chars.push_front(own)
	var frame := {"t": _clock, "c": {}, "b": {}}
	for n in chars:
		var sk := _skeleton_of(n)
		var bones := PackedFloat32Array()
		if sk != null:
			# Living characters: record the pose *before* the game's aim modifier runs
			# (so replay can re-apply the look pitch once). Ragdolls: global pose.
			var snap := _presnap_of(sk)
			var rag: bool = n.has_method("is_ragdolling") and bool(n.call("is_ragdolling"))
			if not rag and snap.pose.size() == sk.get_bone_count() * 10:
				bones = snap.pose.duplicate()
			else:
				bones = _read_bones_global(sk)
		var aim = null
		if n.get("_look_pitch") != null:
			aim = [n.get("_look_pitch"), n.get("_look_yaw"), n.get("_body_yaw"), n.get("_armed")]
		var nid: int = n.get_instance_id()
		if not _meta.has(nid):
			# Kept even after the node is freed (dead NPCs are freed ~60 s later),
			# so a stand-in character can be built for the replay.
			var mp := String(n.get("_installed_path")) if n.get("_installed_path") != null else ""
			_meta[nid] = {"model": mp, "scale": (n as Node3D).scale}
		frame["c"][nid] = [(n as Node3D).global_transform, bones, aim, _held_key(n)]
	var pcam := player.get("camera") as Camera3D
	if pcam != null:
		frame["cam"] = [pcam.global_transform, pcam.fov]  # exact first-person view
		if _clock >= _fp_next:
			_fp_next = _clock + 0.5
			_refresh_fp_nodes(pcam)
		frame["fp"] = _capture_fp()  # first-person arms / weapon animation
	for n in _nearest(_cand_bodies, origin, BODY_RADIUS, MAX_BODIES):
		frame["b"][n.get_instance_id()] = (n as Node3D).global_transform
	var wheels := {}
	for v in _nearest(_cand_veh, origin, VEH_RADIUS, MAX_VEH):
		var vid: int = v.get_instance_id()
		frame["b"][vid] = (v as Node3D).global_transform
		var wl = _wheel_cache.get(vid)
		if wl == null:
			wl = _vehicle_parts(v)
			_wheel_cache[vid] = wl
		for w in wl:
			if is_instance_valid(w):
				wheels[w.get_instance_id()] = (w as Node3D).transform  # steering, spin, suspension
	frame["w"] = wheels
	_frames.append(frame)
	while _frames.size() > 2 and _clock - float(_frames[0]["t"]) > KEEP_SECONDS:
		_frames.pop_front()
	while not _events.is_empty() and float(_events[0]["t"]) < float(_frames[0]["t"]):
		_events.pop_front()


var _held_items: Dictionary = {}   # key -> detached copy of the item model a character held
var _held_last: Dictionary = {}    # char id -> [child instance id, key]
var _held_cur: Dictionary = {}     # char id -> key currently shown by the replay
var _held_ours: Dictionary = {}    # char id -> model node the replay attached
var _held_saved: Dictionary = {}   # char id -> the game's own held nodes (restored on exit)


func _held_key(n: Node) -> String:
	# What the character holds in hand right now, as a key into _held_items.
	var ha = n.get("hand_anchor")
	if ha == null or not is_instance_valid(ha):
		return ""
	var child: Node3D = null
	for c in (ha as Node).get_children():
		if c is Node3D and not c.is_queued_for_deletion():
			child = c
			break
	if child == null:
		return ""
	var cid: int = child.get_instance_id()
	var nid: int = n.get_instance_id()
	var last = _held_last.get(nid)
	if last != null and last[0] == cid:
		return last[1]
	var mi := child as MeshInstance3D
	if mi == null:
		var ms: Array = child.find_children("*", "MeshInstance3D", true, false)
		if not ms.is_empty():
			mi = ms[0]
	var mid: int = mi.mesh.get_instance_id() if mi != null and mi.mesh != null else cid
	var key := str(mid)
	if not _held_items.has(key):
		_held_items[key] = child.duplicate()   # never added to the tree until replay
	_held_last[nid] = [cid, key]
	return key


func _apply_held(n: Node, id, key: String) -> void:
	if _held_cur.get(id, "<none>") == key:
		return
	var ha = n.get("hand_anchor")
	if ha == null and n.has_method("_ensure_hand_anchor"):
		n.call("_ensure_hand_anchor")
		ha = n.get("hand_anchor")
	if ha == null or not is_instance_valid(ha):
		return
	_held_cur[id] = key
	if not _held_saved.has(id):
		var saved: Array = []
		for c in (ha as Node).get_children():
			if not c.is_queued_for_deletion():
				saved.append(c)
		for c in saved:
			(ha as Node).remove_child(c)
		_held_saved[id] = saved
	var old = _held_ours.get(id)
	if old != null and is_instance_valid(old):
		if old.get_parent() != null:
			old.get_parent().remove_child(old)
		old.queue_free()
	_held_ours.erase(id)
	if key != "" and _held_items.has(key):
		var cp := (_held_items[key] as Node).duplicate() as Node3D
		if cp != null:
			(ha as Node).add_child(cp)
			_held_ours[id] = cp


func _restore_held() -> void:
	for id in _held_saved:
		var old = _held_ours.get(id)
		if old != null and is_instance_valid(old):
			if old.get_parent() != null:
				old.get_parent().remove_child(old)
			old.queue_free()
		var n := _node_for(id)
		var ha = n.get("hand_anchor") if n != null else null
		for c in _held_saved[id]:
			if not is_instance_valid(c):
				continue
			if ha != null and is_instance_valid(ha) and not _standins.has(id):
				(ha as Node).add_child(c)
			else:
				c.queue_free()
	_held_saved.clear()
	_held_ours.clear()
	_held_cur.clear()


func _clear_held_cache() -> void:
	for k in _held_items:
		if is_instance_valid(_held_items[k]):
			_held_items[k].queue_free()
	_held_items.clear()
	_held_last.clear()


const FP_ROOTS := ["ArmsView", "PistolView", "ShotgunView", "RifleView", "Hand", "Phone"]
const PART_NAMES := ["Door_FL", "DoorFL", "Door_FR", "DoorFR", "Trunk", "Trunk_L", "TrunkL",
		"Trunk_R", "TrunkR", "VanDoor_Left", "VanDoor_Right", "Hood", "Bonnet"]
var _fp_nodes: Array = []
var _fp_skels: Array = []
var _fp_next := 0.0
var _fp_live: Array = []


func _vehicle_parts(v: Node) -> Array:
	# Wheels (steering/spin/suspension) and door / trunk panels (open or closed).
	var out: Array = v.find_children("*", "VehicleWheel3D", true, false)
	for c in v.find_children("*", "Node3D", true, false):
		if c is CollisionObject3D or c is VehicleWheel3D:
			continue
		if not PART_NAMES.has(String(c.name)):
			continue
		var nested := false
		var p := c.get_parent()
		while p != null and p != v:
			if out.has(p):
				nested = true
				break
			p = p.get_parent()
		if not nested:
			out.append(c)
	return out


func _refresh_fp_nodes(cam: Camera3D) -> void:
	var nodes: Array = []
	var skels: Array = []
	for rn in FP_ROOTS:
		var root := cam.get_node_or_null(NodePath(rn)) as Node3D
		if root == null:
			continue
		nodes.append(root)
		for c in root.find_children("*", "Node3D", true, false):
			nodes.append(c)
			if c is Skeleton3D:
				skels.append(c)
	_fp_nodes = nodes   # new arrays each time: older frames keep their own lists
	_fp_skels = skels


func _capture_fp() -> Array:
	var xfs: Array = []
	var vis := PackedByteArray()
	vis.resize(_fp_nodes.size())
	for i in _fp_nodes.size():
		var nd = _fp_nodes[i]
		if is_instance_valid(nd):
			xfs.append((nd as Node3D).transform)
			vis[i] = 1 if (nd as Node3D).visible else 0
		else:
			xfs.append(Transform3D.IDENTITY)
	var bones: Array = []
	for sk in _fp_skels:
		bones.append(_read_bones(sk) if is_instance_valid(sk) else PackedFloat32Array())
	return [_fp_nodes, xfs, vis, _fp_skels, bones]


func _apply_fp(fp: Array) -> void:
	var nodes: Array = fp[0]
	var xfs: Array = fp[1]
	var vis: PackedByteArray = fp[2]
	for i in nodes.size():
		var nd = nodes[i]
		if is_instance_valid(nd):
			(nd as Node3D).transform = xfs[i]
			(nd as Node3D).visible = vis[i] != 0
	var skels: Array = fp[3]
	var bones: Array = fp[4]
	for i in skels.size():
		var sk = skels[i]
		if is_instance_valid(sk) and not (bones[i] as PackedFloat32Array).is_empty():
			_write_bones(sk, bones[i], bones[i], 0.0)


func _read_bones_global(sk: Skeleton3D) -> PackedFloat32Array:
	# Local poses derived from the *global* pose, so ragdoll physics and skeleton
	# modifiers (aim offset) are captured too, not just the animation pose.
	var n := sk.get_bone_count()
	var out := PackedFloat32Array()
	out.resize(n * 10)
	var g: Array = []
	g.resize(n)
	for i in n:
		g[i] = sk.get_bone_global_pose(i)
	# A ragdolling (dead) NPC is driven by PhysicalBone3D bodies, which the skeleton
	# pose may not reflect yet: take their world transforms as the truth.
	var sim = sk.get_node_or_null(^"Ragdoll")
	if sim != null and sim is PhysicalBoneSimulator3D and sim.active:
		var inv := sk.global_transform.affine_inverse()
		for pb in sim.get_children():
			if pb is PhysicalBone3D:
				var bi: int = pb.get_bone_id()
				if bi >= 0 and bi < n:
					g[bi] = inv * (pb as PhysicalBone3D).global_transform * (pb as PhysicalBone3D).body_offset.affine_inverse()
	for i in n:
		var par := sk.get_bone_parent(i)
		var loc: Transform3D = g[i] if par < 0 else (g[par] as Transform3D).affine_inverse() * (g[i] as Transform3D)
		var p := loc.origin
		var q := loc.basis.get_rotation_quaternion()
		var s := loc.basis.get_scale()
		var o := i * 10
		out[o] = p.x
		out[o + 1] = p.y
		out[o + 2] = p.z
		out[o + 3] = q.x
		out[o + 4] = q.y
		out[o + 5] = q.z
		out[o + 6] = q.w
		out[o + 7] = s.x
		out[o + 8] = s.y
		out[o + 9] = s.z
	return out


func _duration() -> float:
	if _frames.size() < 2:
		return 0.0
	return float(_frames[-1]["t"]) - float(_frames[0]["t"])


# ------------------------------------------------------------------ replay

func _toggle_replay() -> void:
	if _state == S.REPLAY:
		_stop_replay()
		return
	if _state == S.RECORDING:
		_state = S.IDLE
	if _frames.size() < 2:
		print(TAG, "nothing recorded (F6 first)")
		return
	_start_replay()


func _start_replay() -> void:
	_player = _local_player()
	if _player == null:
		return
	var gc := get_node_or_null(^"/root/GunCam")
	if gc != null and gc.has_method("_set_enabled"):
		gc.call("_set_enabled", false)

	# Remember and later restore every node we're going to drive.
	_live.clear()
	var ids := {}
	for f in _frames:
		for id in f["c"]:
			ids[id] = "c"
		for id in f["b"]:
			ids[id] = "b"
	for id in ids:
		if not is_instance_id_valid(id):
			continue
		var n := instance_from_id(id) as Node3D
		if n == null:
			continue
		var st := {"xf": n.global_transform, "vis": n.visible, "kind": ids[id]}
		# The game uses physics interpolation; with physics paused the drawn pose would
		# be stale (cars invisible / offset). Draw the transforms we set exactly.
		st["pim"] = n.physics_interpolation_mode
		n.physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF
		if ids[id] == "c":
			# NPCs are culled by hiding their "Visual" parent; show it during replay.
			# Parked/vacated/culled NPCs hide an ancestor (Visual / Npc root) and dead
			# bodies fade to transparency 1: remember and undo that for the replay.
			var chain: Array = []
			var anc := n.get_parent()
			while anc is Node3D:
				chain.append([anc, (anc as Node3D).visible])
				(anc as Node3D).visible = true
				anc = anc.get_parent()
			st["chain"] = chain
			var trs: Array = []
			for gi in n.find_children("*", "GeometryInstance3D", true, false):
				trs.append([gi, (gi as GeometryInstance3D).transparency])
				(gi as GeometryInstance3D).transparency = 0.0
			st["tr"] = trs
			# A dead NPC's ragdoll simulator would fight the poses we write.
			var skx := _skeleton_of(n)
			if skx != null:
				var sim = skx.get_node_or_null(^"Ragdoll")
				if sim != null and sim is PhysicalBoneSimulator3D:
					st["sim"] = sim.active
					sim.active = false
			var sk := _skeleton_of(n)
			if sk != null:
				st["bones"] = _read_bones(sk)
		_live[id] = st

	_wheels_live.clear()
	for f in _frames:
		for wid in f.get("w", {}):
			if not _wheels_live.has(wid) and is_instance_id_valid(wid):
				var wn := instance_from_id(wid) as Node3D
				if wn != null:
					_wheels_live[wid] = wn.transform

	var n_c := 0
	var n_c_live := 0
	var n_b := 0
	var n_b_live := 0
	for id in ids:
		if ids[id] == "c":
			n_c += 1
			if _live.has(id):
				n_c_live += 1
		else:
			n_b += 1
			if _live.has(id):
				n_b_live += 1
	print(TAG, "recorded characters: ", n_c, " (", n_c_live, " still exist), bodies: ", n_b, " (", n_b_live, " still exist)")

	_real_cam = _player.get("camera") as Camera3D
	if _real_cam != null:
		_real_cam_visible = _real_cam.visible
		_real_cam_xf = _real_cam.transform
		_refresh_fp_nodes(_real_cam)
		_fp_live = _capture_fp()   # restored on exit (the game only re-applies it on change)
		_real_cam_pim = _real_cam.physics_interpolation_mode
		_real_cam.physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF
		_real_cam.visible = false  # first-person arms / weapon models: shown only in first-person mode

	_cam = Camera3D.new()
	_cam.name = "ReplayCam"
	_cam.physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF
	_cam.near = 0.03
	if _real_cam != null:
		_cam.fov = _real_cam.fov
		_base_fov = _real_cam.fov
		_cam.far = _real_cam.far
		_cam.cull_mask = _real_cam.cull_mask
		_cam.environment = _real_cam.environment
		_cam.attributes = _real_cam.attributes
		_free_pos = _real_cam.global_position
		var e := _real_cam.global_basis.get_euler(EULER_ORDER_YXZ)
		_yaw = e.y
		_pitch = e.x
	# The 3D world lives in the game's own SubViewport (own_world_3d); the camera
	# must be inside it or it renders an empty grey world.
	var vp: Node = _real_cam.get_viewport() if _real_cam != null else null
	(vp if vp != null else self).add_child(_cam)
	_cam.make_current()
	_make_standins(ids, vp if vp != null else self)

	var own = _player.get("character")
	_target_id = own.get_instance_id() if own != null else 0
	_t = 0.0
	_playing = true
	_speed = 1.0
	_mode = 1
	_state = S.REPLAY
	get_tree().paused = true
	_hide_hud()
	_build_overlay()
	_refresh_body_and_item()
	if _live.has(_target_id):
		_live[_target_id]["vis"] = true  # own character is normally hidden in first person
	print(TAG, "replay start: ", snappedf(_duration(), 0.1), " s. 1 free, 2/3 gun cam, 4 orbit, F7 exit")


func _stop_replay() -> void:
	_state = S.IDLE
	for id in _live:
		if _standins.has(id):
			continue
		if not is_instance_id_valid(id):
			continue
		var n := instance_from_id(id) as Node3D
		if n == null:
			continue
		var st: Dictionary = _live[id]
		n.global_transform = st["xf"]
		n.visible = st["vis"]
		if st.has("pim"):
			n.physics_interpolation_mode = st["pim"]
		n.reset_physics_interpolation()
		if st.has("chain"):
			for c in st["chain"]:
				if is_instance_valid(c[0]):
					(c[0] as Node3D).visible = c[1]
		if st.has("tr"):
			for c in st["tr"]:
				if is_instance_valid(c[0]):
					(c[0] as GeometryInstance3D).transparency = c[1]
		if st.has("sim"):
			var skr := _skeleton_of(n)
			var simr = skr.get_node_or_null(^"Ragdoll") if skr != null else null
			if simr != null and simr is PhysicalBoneSimulator3D:
				simr.active = st["sim"]
		if st.has("bones"):
			var sk := _skeleton_of(n)
			if sk != null:
				_write_bones(sk, st["bones"], st["bones"], 0.0)
	_restore_held()
	for wid in _wheels_live:
		if is_instance_id_valid(wid):
			var wr := instance_from_id(wid) as Node3D
			if wr != null:
				wr.transform = _wheels_live[wid]
	_wheels_live.clear()
	for id in _standins:
		if is_instance_valid(_standins[id]):
			_standins[id].queue_free()
	_standins.clear()
	_live.clear()
	_clear_fx()
	_ev_last = -1.0
	if _cam != null and is_instance_valid(_cam):
		_cam.queue_free()
	_cam = null
	if _layer != null and is_instance_valid(_layer):
		_layer.queue_free()
	_layer = null
	_restore_hud()
	if _real_cam != null and is_instance_valid(_real_cam):
		_real_cam.visible = _real_cam_visible
		_real_cam.transform = _real_cam_xf
		if not _fp_live.is_empty():
			_apply_fp(_fp_live)
		_fp_live = []
		_real_cam.physics_interpolation_mode = _real_cam_pim as Node.PhysicsInterpolationMode
		_real_cam.reset_physics_interpolation()
		_real_cam.make_current()
	if _player != null and is_instance_valid(_player) and _player.has_method("_apply_view_mode"):
		_player.call("_apply_view_mode")
	get_tree().paused = false
	_mount = null
	print(TAG, "replay stopped")


# ------------------------------------------------------------------ shot effect replay

func _fx_world() -> Node:
	var vp: Node = _real_cam.get_viewport() if _real_cam != null and is_instance_valid(_real_cam) else null
	return vp if vp != null else self


func _clear_fx() -> void:
	for f in _fx:
		if is_instance_valid(f["node"]):
			f["node"].queue_free()
	_fx.clear()


func _free_later(n: Node, secs: float) -> void:
	# create_timer defaults to process_always, so it runs while the tree is paused.
	get_tree().create_timer(secs).timeout.connect(func() -> void:
		if is_instance_valid(n):
			n.queue_free())


func _replay_events(t_abs: float) -> void:
	# Jumped (scrub / start / loop): just re-anchor, don't fire a burst of old events.
	if _ev_last < 0.0 or t_abs < _ev_last - 0.0001 or t_abs - _ev_last > 0.5:
		_clear_fx()
		_ev_last = t_abs
		return
	for ev in _events:
		var et: float = ev["t"]
		if et <= _ev_last or et > t_abs:
			continue
		_spawn_event(ev)
	_ev_last = t_abs
	# animate / expire tracers
	for i in range(_fx.size() - 1, -1, -1):
		var f: Dictionary = _fx[i]
		var node: Node3D = f["node"]
		if not is_instance_valid(node):
			_fx.remove_at(i)
			continue
		if f["kind"] == "tracer":
			if t_abs > f["t1"]:
				node.queue_free()
				_fx.remove_at(i)
				continue
			var w := clampf((t_abs - f["t0"]) / maxf(f["t1"] - f["t0"], 0.001), 0.0, 1.0)
			node.global_position = (f["p0"] as Vector3).lerp(f["p1"], w)


func _spawn_event(ev: Dictionary) -> void:
	var world := _fx_world()
	match ev["kind"]:
		"snd":
			var p := AudioStreamPlayer3D.new()
			p.process_mode = Node.PROCESS_MODE_ALWAYS
			p.stream = ev["stream"]
			p.volume_db = ev["vol"]
			p.pitch_scale = ev["pitch"]
			p.max_distance = ev["maxd"]
			p.unit_size = ev["unit"]
			p.bus = &"Sfx"
			world.add_child(p)
			p.global_position = ev["pos"]
			p.finished.connect(p.queue_free)
			p.play()
		"flash":
			var l := OmniLight3D.new()
			l.process_mode = Node.PROCESS_MODE_ALWAYS
			l.light_color = Color(1.0, 0.82, 0.45)
			l.omni_range = 3.2
			l.shadow_enabled = false
			l.light_energy = ev["energy"]
			world.add_child(l)
			l.global_position = ev["pos"]
			_free_later(l, 0.06)
		"spark":
			_puff(world, ev["pos"], ev["normal"], false)
		"blood":
			_puff(world, ev["pos"], ev["normal"], true)
		"proj":
			var m := MeshInstance3D.new()
			m.process_mode = Node.PROCESS_MODE_ALWAYS
			var box := BoxMesh.new()
			box.size = Vector3(0.022, 0.022, 0.28)
			m.mesh = box
			var mat := StandardMaterial3D.new()
			mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
			mat.albedo_color = Color(1.0, 0.85, 0.3)
			m.material_override = mat
			m.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
			world.add_child(m)
			var p0: Vector3 = ev["p0"]
			var p1: Vector3 = ev["p1"]
			m.global_position = p0
			if p0.distance_to(p1) > 0.01:
				m.look_at(p1, Vector3.UP)
			_fx.append({"node": m, "kind": "tracer", "t0": ev["t"], "t1": ev["end"], "p0": p0, "p1": p1})


func _puff(world: Node, pos: Vector3, normal: Vector3, blood: bool) -> void:
	var c := CPUParticles3D.new()
	c.process_mode = Node.PROCESS_MODE_ALWAYS
	if _fx_mesh == null:
		var sm := SphereMesh.new()
		sm.radius = 0.02
		sm.height = 0.04
		sm.radial_segments = 4
		sm.rings = 2
		_fx_mesh = sm
	c.mesh = _fx_mesh
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.albedo_color = Color(0.55, 0.02, 0.02) if blood else Color(1.0, 0.8, 0.35)
	c.material_override = mat
	c.one_shot = true
	c.explosiveness = 1.0
	c.amount = 14 if blood else 18
	c.lifetime = 0.45 if blood else 0.25
	c.direction = normal
	c.spread = 55.0
	c.initial_velocity_min = 1.0
	c.initial_velocity_max = 3.5
	c.gravity = Vector3(0, -9.0, 0)
	world.add_child(c)
	c.global_position = pos
	c.emitting = true
	_free_later(c, 1.0)


func _node_for(id) -> Node3D:
	if _standins.has(id):
		var s = _standins[id]
		return s as Node3D if is_instance_valid(s) else null
	if is_instance_id_valid(id):
		return instance_from_id(id) as Node3D
	return null


func _make_standins(ids: Dictionary, world: Node) -> void:
	# Characters that were freed since they were recorded (dead NPCs are removed
	# ~60 s after dying) get a stand-in built from the saved model path.
	var scene := load("res://scenes/characters/base_character.tscn") as PackedScene
	if scene == null:
		return
	var made := 0
	for id in ids:
		if ids[id] != "c" or _live.has(id):
			continue
		var meta: Dictionary = _meta.get(id, {})
		var ch := scene.instantiate() as Node3D
		if ch == null:
			continue
		var mp: String = meta.get("model", "")
		if mp != "" and ResourceLoader.exists(mp):
			ch.set("model_scene", load(mp))
		world.add_child(ch)
		ch.scale = meta.get("scale", Vector3.ONE)
		var tree := ch.get_node_or_null(^"AnimTree")
		if tree != null:
			tree.set("active", false)
		_standins[id] = ch
		_live[id] = {"xf": ch.global_transform, "vis": true, "kind": "c", "standin": true}
		made += 1
	print(TAG, "stand-ins built for freed characters: ", made)


func _refresh_body_and_item() -> void:
	# The local body is normally hidden in first person; show it and its weapon.
	if _player == null:
		return
	var body := _player.get("body_visual") as Node3D
	if body != null:
		body.visible = true
	var ch = _player.get("character")
	if ch != null:
		ch.visible = true
		if ch.has_method("set_held_item") and _player.has_method("_hand_item_id") \
				and _player.has_method("_visual_held_id"):
			ch.call("set_held_item", _player.call("_visual_held_id", _player.call("_hand_item_id")))


func _replay_process(delta: float) -> void:
	get_tree().paused = true
	if _playing:
		_t = minf(_t + delta * _speed, _duration())
		if _t >= _duration():
			_playing = false
	_apply_time(_t)
	_replay_events(float(_frames[0]["t"]) + _t)
	_hud_t += delta
	if _hud_t > 1.0:
		_hud_t = 0.0
		_reassert_hud()
	_update_camera(delta)
	_update_overlay()


func _index_for(t_abs: float) -> int:
	var lo := 0
	var hi := _frames.size() - 1
	while lo < hi:
		var mid := (lo + hi + 1) >> 1
		if float(_frames[mid]["t"]) <= t_abs:
			lo = mid
		else:
			hi = mid - 1
	return lo


func _apply_time(t_rel: float) -> void:
	var t_abs := float(_frames[0]["t"]) + t_rel
	var i := _index_for(t_abs)
	var a: Dictionary = _frames[i]
	var b: Dictionary = _frames[mini(i + 1, _frames.size() - 1)]
	var span := float(b["t"]) - float(a["t"])
	var w := 0.0 if span <= 0.0001 else clampf((t_abs - float(a["t"])) / span, 0.0, 1.0)
	if _mode == 5 and a.has("fp") and b.has("fp"):
		_apply_fp(a["fp"] if w < 0.5 else b["fp"])
	_rec_cam_ok = a.has("cam") and b.has("cam")
	if _rec_cam_ok:
		_rec_cam = (a["cam"][0] as Transform3D).interpolate_with(b["cam"][0], w)
		_rec_fov = lerpf(a["cam"][1], b["cam"][1], w)

	# Vehicle wheels: local transforms carry steering, spin and suspension travel.
	for wid in _wheels_live:
		var wa = a.get("w", {}).get(wid)
		var wb = b.get("w", {}).get(wid)
		if wa == null and wb == null:
			continue
		var wn := instance_from_id(wid) as Node3D if is_instance_id_valid(wid) else null
		if wn != null:
			var xa: Transform3D = wa if wa != null else wb
			var xb: Transform3D = wb if wb != null else wa
			wn.transform = xa.interpolate_with(xb, w)

	for id in _live:
		var n := _node_for(id)
		if n == null:
			continue
		var kind: String = _live[id]["kind"]
		var key := "c" if kind == "c" else "b"
		var ea = a[key].get(id)
		var eb = b[key].get(id)
		if ea == null and eb == null:
			n.visible = false
			continue
		# Present in the recording: show it (a culled NPC may be hidden right now).
		n.visible = true if kind == "c" else _live[id]["vis"]
		var ta: Transform3D
		var tb: Transform3D
		if kind == "c":
			ta = (ea if ea != null else eb)[0]
			tb = (eb if eb != null else ea)[0]
		else:
			ta = ea if ea != null else eb
			tb = eb if eb != null else ea
		n.global_transform = ta.interpolate_with(tb, w)
		if kind == "c":
			var sk := _skeleton_of(n)
			if sk != null:
				var ba: PackedFloat32Array = (ea if ea != null else eb)[1]
				var bb: PackedFloat32Array = (eb if eb != null else ea)[1]
				_write_bones(sk, ba, bb, w)
				# Re-apply the look pitch/yaw (the game's aim modifier doesn't run while paused).
				var ra: Array = ea if ea != null else eb
				var rb: Array = eb if eb != null else ea
				if ra.size() > 3:
					_apply_held(n, id, String(ra[3]))
				if ra.size() > 2 and rb.size() > 2 and ra[2] != null and rb[2] != null \
						and n.has_method("apply_aim_to_skeleton"):
					var aa: Array = ra[2]
					var ab: Array = rb[2]
					n.set("_look_pitch", lerpf(aa[0], ab[0], w))
					n.set("_look_yaw", lerp_angle(aa[1], ab[1], w))
					n.set("_body_yaw", lerp_angle(aa[2], ab[2], w))
					n.set("_armed", aa[3])
					n.set("_hit_bone", -1)
					n.call("apply_aim_to_skeleton", sk)


func _read_bones(sk: Skeleton3D) -> PackedFloat32Array:
	var out := PackedFloat32Array()
	out.resize(sk.get_bone_count() * 10)
	for i in sk.get_bone_count():
		var p := sk.get_bone_pose_position(i)
		var q := sk.get_bone_pose_rotation(i)
		var s := sk.get_bone_pose_scale(i)
		var o := i * 10
		out[o] = p.x
		out[o + 1] = p.y
		out[o + 2] = p.z
		out[o + 3] = q.x
		out[o + 4] = q.y
		out[o + 5] = q.z
		out[o + 6] = q.w
		out[o + 7] = s.x
		out[o + 8] = s.y
		out[o + 9] = s.z
	return out


func _write_bones(sk: Skeleton3D, a: PackedFloat32Array, b: PackedFloat32Array, w: float) -> void:
	var count := mini(int(mini(a.size(), b.size()) / 10.0), sk.get_bone_count())
	for i in count:
		var o := i * 10
		var pa := Vector3(a[o], a[o + 1], a[o + 2])
		var pb := Vector3(b[o], b[o + 1], b[o + 2])
		var qa := Quaternion(a[o + 3], a[o + 4], a[o + 5], a[o + 6])
		var qb := Quaternion(b[o + 3], b[o + 4], b[o + 5], b[o + 6])
		var sa := Vector3(a[o + 7], a[o + 8], a[o + 9])
		var sb := Vector3(b[o + 7], b[o + 8], b[o + 9])
		sk.set_bone_pose_position(i, pa.lerp(pb, w))
		sk.set_bone_pose_rotation(i, qa.slerp(qb, w))
		sk.set_bone_pose_scale(i, sa.lerp(sb, w))


# ------------------------------------------------------------------ cameras

func _chars_now() -> Array:
	var out: Array = []
	for id in _live:
		if _live[id]["kind"] == "c":
			var n := _node_for(id)
			if n != null and n.visible:
				out.append(n)
	return out


func _next_target() -> void:
	var list := _chars_now()
	if list.is_empty():
		return
	var own = _player.get("character") if _player != null else null
	# stable order: the player first, then by instance id
	list.sort_custom(func(a, b):
		var ra: int = -1 if a == own else a.get_instance_id()
		var rb: int = -1 if b == own else b.get_instance_id()
		return ra < rb)
	var idx := 0
	for i in list.size():
		if list[i].get_instance_id() == _target_id:
			idx = (i + 1) % list.size()
			break
	_target_id = list[idx].get_instance_id()
	_mount = null
	print(TAG, "target: ", _target_name())
	# In free-fly the target is otherwise invisible: fly to a spot behind it, looking at it.
	var tn := _target()
	if _mode == 1 and tn != null:
		var focus := tn.global_position + Vector3(0, 1.2, 0)
		var back := tn.global_basis.z.normalized()
		_free_pos = focus + back * 3.0 + Vector3(0, 0.6, 0)
		var dir := (focus - _free_pos).normalized()
		_yaw = atan2(-dir.x, -dir.z)
		_pitch = asin(clampf(dir.y, -1.0, 1.0))


func _target_name() -> String:
	var t := _target()
	if t == null:
		return "none"
	if _player != null and t == _player.get("character"):
		return "player"
	if _standins.has(t.get_instance_id()):
		return "NPC (rebuilt)"
	var p := t.get_parent()
	if p != null and p.name == &"Visual" and p.get_parent() != null:
		p = p.get_parent()
	return String(p.name) if p != null else String(t.name)


func _set_mode(m: int) -> void:
	_mode = m
	_mount = null
	if m == 1 and _cam != null:
		var e := _cam.global_basis.get_euler(EULER_ORDER_YXZ)
		_free_pos = _cam.global_position
		_yaw = e.y
		_pitch = e.x
	print(TAG, "camera mode ", m)


func _target() -> Node3D:
	if _target_id != 0 and is_instance_id_valid(_target_id):
		return instance_from_id(_target_id) as Node3D
	return null


func _find_mount(target: Node3D) -> Node3D:
	var m := target.find_child("Muzzle", true, false) as Node3D
	if m != null:
		return m
	var h := target.get_node_or_null(^"HandSocket") as Node3D
	return h if h != null else target


func _update_camera(delta: float) -> void:
	if _cam == null:
		return
	var tgt := _target()
	if _mode != 5:
		_cam.fov = _base_fov
		_set_fp_view(false)
	if _mode == 5 and tgt != null:
		_first_person(tgt)
		return
	if _mode == 1 or tgt == null:
		_free_fly(delta)
		return
	if _mode == 4:
		var focus := tgt.global_position + Vector3(0, 1.2, 0)
		var basis := Basis.from_euler(Vector3(_orbit_pitch, _orbit_yaw, 0), EULER_ORDER_YXZ)
		_cam.global_transform = Transform3D(basis, focus + basis * Vector3(0, 0, _orbit_dist))
		return
	# gun cam (modes 2 and 3)
	_mount_t -= delta
	if _mount == null or not is_instance_valid(_mount) or _mount_t <= 0.0:
		_mount = _find_mount(tgt)
		_mount_t = 0.5
	_adjust_mount(delta)
	# gun forward: back along the barrel and slightly left (from the camera's view)
	var pos := Vector3(-0.04, 0.035, -0.02) if _mode == 2 else Vector3(0.0, 0.06, -0.12)
	var rot := Vector3(0, 0, 18) if _mode == 2 else Vector3(0, 180, -15)
	pos += _pos_adj[_mode]
	rot += _rot_adj[_mode]
	var local := Transform3D(Basis.from_euler(Vector3(deg_to_rad(rot.x), deg_to_rad(rot.y), deg_to_rad(rot.z)), EULER_ORDER_YXZ), pos)
	_cam.global_transform = _mount.global_transform * local


func _first_person(tgt: Node3D) -> void:
	var own = _player.get("character") if _player != null else null
	if tgt == own and _rec_cam_ok:
		# the player's exact recorded view (position, look direction, aim zoom)
		# Pushed forward out of the head model (the eye point is inside the skull mesh).
		# Shift + PgUp/PgDn / arrows nudge it, F10 prints the result.
		_adjust_mount(get_process_delta_time())
		var padj: Vector3 = _pos_adj[5]
		var off: Vector3 = Vector3(0.0, 0.0, -FP_FORWARD) + padj
		var r: Vector3 = _rot_adj[5]
		_cam.global_transform = _rec_cam * Transform3D(
			Basis.from_euler(Vector3(deg_to_rad(r.x), deg_to_rad(r.y), deg_to_rad(r.z)), EULER_ORDER_YXZ), off)
		_cam.fov = _rec_fov
		# Real first-person view: hide the player's body, and bring the game's own
		# first-person arms / weapon (children of the real camera) to the recorded view.
		_set_fp_view(true)
		if _real_cam != null and is_instance_valid(_real_cam):
			_real_cam.global_transform = _cam.global_transform
		return
	_set_fp_view(false)
	# Other characters: approximate from the head bone, facing their body direction.
	_cam.fov = _base_fov
	var sk := _skeleton_of(tgt)
	var pos := tgt.global_position + Vector3(0, 1.6, 0)
	if sk != null:
		var hi := sk.find_bone("head")
		if hi >= 0:
			pos = (sk.global_transform * sk.get_bone_global_pose(hi)).origin + Vector3(0, 0.08, 0)
	var fwd := -tgt.global_basis.z
	_cam.global_transform = Transform3D(Basis.looking_at(fwd, Vector3.UP), pos + fwd * 0.12)


func _set_fp_view(on: bool) -> void:
	# on: player body hidden, first-person arms/weapon shown. off: the reverse.
	if _player == null or not is_instance_valid(_player):
		return
	var body := _player.get("body_visual") as Node3D
	if body != null:
		body.visible = not on
	if _real_cam != null and is_instance_valid(_real_cam):
		_real_cam.visible = on


func _adjust_mount(delta: float) -> void:
	var shift := Input.is_key_pressed(KEY_SHIFT)
	var ctrl := Input.is_key_pressed(KEY_CTRL)
	if not shift and not ctrl:
		return
	var h := float(Input.is_key_pressed(KEY_RIGHT)) - float(Input.is_key_pressed(KEY_LEFT))
	var v := float(Input.is_key_pressed(KEY_UP)) - float(Input.is_key_pressed(KEY_DOWN))
	var z := float(Input.is_key_pressed(KEY_PAGEDOWN)) - float(Input.is_key_pressed(KEY_PAGEUP))
	if shift:
		_pos_adj[_mode] += Vector3(h, v, z) * 0.5 * delta
	else:
		_rot_adj[_mode] += Vector3(v, -h, z) * 60.0 * delta


func _free_fly(delta: float) -> void:
	var basis := Basis.from_euler(Vector3(_pitch, _yaw, 0), EULER_ORDER_YXZ)
	var d := Vector3.ZERO
	if Input.is_key_pressed(KEY_W): d.z -= 1
	if Input.is_key_pressed(KEY_S): d.z += 1
	if Input.is_key_pressed(KEY_A): d.x -= 1
	if Input.is_key_pressed(KEY_D): d.x += 1
	if Input.is_key_pressed(KEY_E): d.y += 1
	if Input.is_key_pressed(KEY_Q): d.y -= 1
	var sp := _free_speed
	if Input.is_key_pressed(KEY_SHIFT): sp *= 3.0
	if Input.is_key_pressed(KEY_CTRL): sp *= 0.25
	_free_pos += basis * d * sp * delta
	_cam.global_transform = Transform3D(basis, _free_pos)


# ------------------------------------------------------------------ HUD

func _hide_hud() -> void:
	_hud_saved.clear()
	for n in get_tree().root.find_children("*", "CanvasLayer", true, false):
		if n == _layer:
			continue
		_hud_saved[n] = n.visible
		n.visible = false
	# Controls that aren't inside a CanvasLayer or a SubViewport (in-world screens)
	for n in get_tree().root.find_children("*", "Control", true, false):
		# never hide the container that displays the 3D world
		if n is SubViewportContainer or n.get_parent() is Control or _under_layer_or_viewport(n):
			continue
		_hud_saved[n] = n.visible
		n.visible = false


func _under_layer_or_viewport(n: Node) -> bool:
	var p := n.get_parent()
	while p != null:
		if p is CanvasLayer or p is SubViewport:
			return true
		p = p.get_parent()
	return false


func _reassert_hud() -> void:
	for n in _hud_saved:
		if is_instance_valid(n) and n.visible:
			n.visible = false


func _restore_hud() -> void:
	for n in _hud_saved:
		if is_instance_valid(n):
			n.visible = _hud_saved[n]
	_hud_saved.clear()


# ------------------------------------------------------------------ timeline overlay

func _build_overlay() -> void:
	_layer = CanvasLayer.new()
	_layer.layer = 200
	_layer.process_mode = Node.PROCESS_MODE_ALWAYS
	add_child(_layer)
	var root := Control.new()
	root.set_anchors_preset(Control.PRESET_FULL_RECT)
	root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_layer.add_child(root)
	_bar_bg = ColorRect.new()
	_bar_bg.color = Color(0, 0, 0, 0.55)
	_bar_bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_bar_bg.anchor_left = 0.05
	_bar_bg.anchor_right = 0.95
	_bar_bg.anchor_top = 1.0
	_bar_bg.anchor_bottom = 1.0
	_bar_bg.offset_top = -28
	_bar_bg.offset_bottom = -20
	root.add_child(_bar_bg)
	_bar_fill = ColorRect.new()
	_bar_fill.color = Color(1, 0.35, 0.3, 0.95)
	_bar_fill.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_bar_bg.add_child(_bar_fill)
	_label = Label.new()
	_label.anchor_left = 0.05
	_label.anchor_right = 0.95
	_label.anchor_top = 1.0
	_label.anchor_bottom = 1.0
	_label.offset_top = -56
	_label.offset_bottom = -30
	_label.add_theme_color_override(&"font_outline_color", Color.BLACK)
	_label.add_theme_constant_override(&"outline_size", 4)
	root.add_child(_label)
	_help = Label.new()
	_help.text = HELP_TEXT
	_help.position = Vector2(16, 16)
	_help.add_theme_color_override(&"font_outline_color", Color.BLACK)
	_help.add_theme_constant_override(&"outline_size", 4)
	root.add_child(_help)


func _update_overlay() -> void:
	if _layer == null:
		return
	var dur := maxf(_duration(), 0.001)
	_bar_fill.size = Vector2(_bar_bg.size.x * clampf(_t / dur, 0.0, 1.0), _bar_bg.size.y)
	var names := {1: "free", 2: "gun fwd", 3: "gun back", 4: "orbit", 5: "first person"}
	_label.text = "REPLAY %s  %.1f / %.1f s  x%s  cam: %s  target: %s  (T next)" % [
		"▶" if _playing else "❚❚", _t, dur, str(_speed), names.get(_mode, "?"), _target_name()]
