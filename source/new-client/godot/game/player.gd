class_name Player
extends CharacterBody3D
## Player character with two movement modes, chosen in the (temporary) Esc menu and saved; player only, bots are
## decided separately (owner 2026-10-09):
##   modern (default, WoW-style): full-speed strafing, A/D strafe while the right mouse is held, 65% backpedal, body
##     leans into diagonals, strafing plays the run cycle turned toward the side
##   classic (DAoC): A/D always turn, Q/E side-step at the slow side-step speed with the client's side-step clips,
##     slow backward walk, no lean
## Controls (modern):
##   W forward, S backpedal (65% speed), A/D turn, Q/E strafe (A/D strafe while the right mouse button is held)
##   right mouse: steer (character turns with the mouse), left mouse: orbit the camera only, both: run forward
##   keys from Keybinds (the client's keyboard.dat presets): Space jump, NumLock run lock, ScrollLock walk, T torch;
##   wheel zoom. Swimming stays on the surface (1.65: no diving before Trials of Atlantis)
## Strafing is full run speed. Animations are the client's own clips at the client's rates (nif_character.py).
## Fly mode (set_flying, F6 in the viewer): free flight where the camera points, Space up, Ctrl down, Shift fast.

const RUN_SPEED := 191.0 * 0.025       # DAoC base run speed (191 units/s) in metres per second
const BACK_SPEED := RUN_SPEED * 0.65   # backpedal, as in WoW
const WALK_SPEED := RUN_SPEED * 0.35
const SWIM_SPEED := RUN_SPEED * 0.65
const TURN_RATE := PI                  # keyboard turning, radians per second (180 degrees)
const MOUSE_TURN := 0.005
const JUMP_VELOCITY := 4.6
const GRAVITY := 18.0
const AIR_CONTROL := 0.1               # how much steering survives in the air
const SWIM_DEPTH := 1.25               # water deeper than this over the ground: you swim (shallower: you wade)
const SWIM_FLOAT := 0.3                # swimming, the feet hang this far under the surface: the swim pose is flat
									   # (head 0.47 m over the feet), so the head and upper back stay out of the water
									   # (owner 2026-10-10: at 1.25 m the swimmer was under the surface)
# classic DAoC side-step and backward speed: the figure's stride per side-step / back-walk cycle in gamedata
# monnifs.csv (75 units per 1 s clip), i.e. the speed at which the client's own clips play naturally (gap-fill reading)
const CLASSIC_SIDE_SPEED := 75.0 * 0.025
const CLASSIC_BACK_SPEED := 75.0 * 0.025
# Ground movement copies the client's player update (game.dll 0x4365b2, see WORLD IMPORT LESSONS.md):
#   1. move; 2. ground pick straight down from max(64 units, this frame's drop) above the feet: any floor found above
#   the feet lifts the player onto it (this is the client's step-up: anything up to 64 units = 1.6 m that the pick
#   sees); 3. walls: the collider is tested against collision geometry only, contact normals flattened (pure walls);
#   4. second pick: floor within 1 unit below -> stand on it, else airborne and gravity takes over (no step-down snap).
const PICK_LIFT := 64.0 * 0.025
const FLOOR_SNAP := 1.0 * 0.025
const FALL_HEIGHT := 16.0 * 0.025       # client: only more than 16 units above the floor counts as falling (fall flags at
                                       # game.dll 0x4369e0); smaller drops while walking (downhill, off a step) follow the
                                       # ground, so running down a slope never switches to the falling animation
# The client's wall collider bottom sits above the feet: entity+0x44 is 0 for players (it is the random hover height
# of floating monsters), so the lift comes from the figure's bounding volume, which isn't readable statically. Pinned by
# client data: at the Mag Mell platform the model's own COLLIDEE mesh (houtwall 'collider ext08') covers the 0.26 m
# edge and the client still walks up it, so the bottom is above 0.26 m. Raised 2026-10-09 by the next client case: the
# Lethantis Association tower's stairs (Campacorentin Forest) have 0.37 m and 0.40 m risers (16 units, measured with
# tests/steps_probe.gd) that a walking player climbs in the client, so the bottom is above 0.40 m. Raised 2026-10-11 by
# the owner's old-client video: Caer Gothwaite's doorway (Isle of Glass, 1098 / 1370) has a 0.59 m threshold the client
# walks through without jumping (tests/step_probe.gd stopped at it at 0.45), so the bottom is above 0.59 m. The bots use
# this same value (BotSim reads it from here - bots and players share rules, owner).
const COLLIDER_LIFT := 0.62
const STEP_LEAD := 0.25                 # the wall collider's radius: where the leading-edge floor pick looks
# Ladders (game.dll RE 2026-10-10): touching a 'climb' wall (ZoneLoader ClimbBodies) puts the client in move state 7
# ("You start climbing."): forward climbs at 85 units/s x min(1, speed / 100), back climbs down at the same rate
# (0x439d19); landing while climbing down, or a jump, ends it ("You are no longer climbing.", 0x436b20 / 0x438731).
const CLIMB_SPEED := 85.0 * 0.025
# camera distance, from the client (game.dll 0x4ac407 clamps "cameradistance" to 50..500 units; 1500 only while linked
# to a siege engine / mount, 0x43f60c): 1.25 m to 12.5 m. Test runs keep a free camera (free_camera).
const CAM_MIN := 50.0 * 0.025
const CAM_MAX := 500.0 * 0.025
const CAM_MAX_FREE := 40.0
const CAM_PITCH := deg_to_rad(50.0)     # client: camera pitch clamped to -50..50 degrees (game.dll 0x4ac471)
# The torch, from the client (game.dll 0x43e5a4 "torch on" -> 0x47d4f4): two white point lights on a node 128 units
# (3.2 m) above the figure. Light 1: dimmer 200 x 0.01 = 2.0; light 2 (lights only scene group 0x2459dbc, not drawn
# yet): 200 x 0.0025 = 0.5. Both fall off as 1 / (0.006 d + d^2 / 147456) (d in units): full at ~6.8 m, about 0.6 at
# 10 m, 0.2 at 20 m. On by default, saved ("torchmode" in the client's user.dat); T (or Shift+T) toggles it.
const TORCH_HEIGHT := 128.0 * 0.025
const TORCH_RANGE := 30.0
const TORCH_ENERGY := 3.0              # mine: client dimmer 2.0 against the zone lights' 1.5 -> 2.2 base in this engine
const FLY_SPEED := 18.0
const FLY_FAST := 70.0

var zone: ZoneLoader
var region: RegionWorld                  # seamless zones: the ground / water of whichever loaded zone you stand over
var in_combat := false                 # attack mode: weapon drawn, combat idle (Combat)
var combat_stance := ""                 # "" one-hand, "2h", "staff", "pole" (WeaponModels.stance)
var dead := false
var sitting := false                   # /sit (Combat.sit): sit_down once, then sit_idle until standing up
var speed_mult := 1.0                  # sprint (x1.3, Abilities)
var cc := ""                           # "stun" / "mez" / "root" from monster spells (Casting): no moving
var snare_mult := 1.0                  # snares: the run speed's share left
var shade := false                       # a Necromancer with a servant up (Pets)
var riding := false                     # on a stable horse (HorseRoutes moves you; jump gets you off)
var ride_clip := "ride_horse"          # the rider's pose: ride_horse, or a flight's ride_griffon / _amphitere / _dragonfly
var stealth_mult := 1.0                 # hidden: Abilities.toggle_stealth's speed share
var encumbrance := 1.0                  # PlayerData.encumbrance_mult (refreshed when the inventory changes)
var buff_speed := 1.0                  # speed buffs (Combat from Casting's buff sums): Value % of normal
var _death_played := false
var _action := ""                       # a one-shot clip playing over idle: a swing, a flinch
var _action_left := 0.0
var _gear: Array = []                   # weapon holders on the attach bones
var char_yaw := 0.0                    # where the character faces; forward = -Z rotated by this
var cam_yaw := 0.0                     # camera heading (differs from char_yaw while orbiting with the left mouse)
var cam_pitch := -0.22
var cam_distance := 5.5
var swimming := false
var climbing := false                    # on a ladder (state 7)
var _climb_vy := 0.0
signal landed(fall_speed_units: float)   # touched ground from a fall: the downward speed (units / s)
var flying := false
var autorun := false
# /follow, /stick, /face (patch notes 2001: /follow "until you break off by moving in another direction"; /stick to
# fight closely, "breaks if the target gets outside of a certain range"; /face auto-faces a target)
var track_target: Node3D = null
var track_mode := ""                    # "", "follow", "stick", "face"
var track_name := ""
const FOLLOW_GAP_M := 3.0
const STICK_GAP_M := 1.4
const TRACK_START_M := 1000 * 0.025     # "unless you are relatively close to them"
const STICK_BREAK_M := 1500 * 0.025
var walking := false
var force_clip := ""                   # tests: hold one animation regardless of movement
var movement_mode := "modern"          # "modern" or "classic" (Esc menu)
var input_enabled := true              # false while a menu is open
var mouse_sensitivity := 1.0           # Options: CONTROLS
var invert_mouse := false
var _lmb_world := false                # mouse buttons pressed on the world (not on an interface window)
var _rmb_world := false
var _cursor_at := Vector2.ZERO          # where the cursor was when a mouse-look drag began
var grounded := false
var _air_time := 0.0                   # seconds off the ground (the falling pose waits a moment)
var hold_frames := 12                   # after a spawn / teleport: stand still until the floors are in the physics world
var _last_footing := Vector3.ZERO       # the last spot stood on (a fall into the void comes back here)
var free_camera := false               # test runs only: zoom out past the client's limit
var torch: OmniLight3D
var torch_on := true
var _strides := {}                     # monnifs.csv strides (units per cycle) from the character's .json sidecar
var _clip_len := {}

var _model: Node3D
var sounds: CharacterSounds             # footsteps / swim strokes from the client's creature sound sheet
var _figure := ""
var _anim: AnimationPlayer
var _pivot: Node3D
var _arm: SpringArm3D
var _body_offset := 0.0                # model lean toward diagonal movement, like WoW's 45-degree run
var camera: Camera3D


func _ready() -> void:
	var shape := CollisionShape3D.new()
	var capsule := CapsuleShape3D.new()
	capsule.radius = STEP_LEAD                           # (0.35 caught the next riser of steep stairs before the lift)
	capsule.height = 1.8 - COLLIDER_LIFT
	shape.shape = capsule
	shape.position.y = COLLIDER_LIFT + capsule.height * 0.5
	add_child(shape)
	motion_mode = CharacterBody3D.MOTION_MODE_FLOATING   # every contact is a wall (the client flattens normals)
	collision_layer = 0
	collision_mask = ZoneLoader.LAYER_WALL
	# encumbrance follows the inventory and strength (buffs / debuffs change it too)
	# (the launcher's server game: the server decides your speed - its MaxSpeed packet, encumbrance included -
	# ServerWorld sets `encumbrance` from it; the game's own weight sums don't apply)
	if not Server.active:
		PlayerData.hook(self, PlayerData.inventory_changed, func(): encumbrance = PlayerData.encumbrance_mult())
		PlayerData.hook(self, PlayerData.effects_changed, func(): encumbrance = PlayerData.encumbrance_mult())
		encumbrance = PlayerData.encumbrance_mult()

	torch = OmniLight3D.new()
	torch.name = "Torch"
	torch.position.y = TORCH_HEIGHT
	torch.light_color = Color.WHITE
	torch.omni_range = TORCH_RANGE
	torch.omni_attenuation = 1.0
	torch.shadow_enabled = false                         # the client's fixed-function point lights cast no shadows
	add_child(torch)
	var cfg := ConfigFile.new()
	cfg.load("user://settings.cfg")
	set_torch(bool(cfg.get_value("player", "torch", true)))
	mouse_sensitivity = float(cfg.get_value("player", "mouse_sensitivity", 1.0))
	invert_mouse = bool(cfg.get_value("player", "invert_mouse", false))
	_register_torch.call_deferred()

	_pivot = Node3D.new()
	_pivot.position.y = 1.55
	add_child(_pivot)
	_arm = SpringArm3D.new()
	_arm.spring_length = cam_distance
	_arm.collision_mask = ZoneLoader.LAYER_WALL | ZoneLoader.LAYER_FLOOR | ZoneLoader.LAYER_SCENERY
	_arm.margin = 0.2
	_arm.add_excluded_object(get_rid())
	_pivot.add_child(_arm)
	camera = Camera3D.new()
	camera.far = 1500.0
	camera.fov = 70.0
	_arm.add_child(camera)
	camera.make_current()


func set_model(path: String) -> void:
	var doc := GLTFDocument.new()
	var state := GLTFState.new()
	if doc.append_from_file(path, state) != OK:
		push_warning("player model missing: " + path)
		return
	_model = doc.generate_scene(state) as Node3D
	add_child(_model)
	var meta_path := path.get_basename() + ".json"
	if FileAccess.file_exists(meta_path):
		var meta: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(meta_path))
		_strides = meta.get("strides_units", {})
		_clip_len = meta.get("clip_seconds", {})
		_figure = String(meta.get("sound_figure", meta.get("figure", "")))   # Catacombs cel_m uses the Celt sound set
	var players := _model.find_children("*", "AnimationPlayer", true, false)
	if players.size() > 0:
		_anim = players[0] as AnimationPlayer
		_set_loops()
		Fig3Figure.add_rest_reset(_anim)                     # bones a clip doesn't key go back to rest
		_play("idle")
		var idx = JSON.parse_string(FileAccess.get_file_as_string("res://content/sounds/sounds.json"))
		var sound_set := int(idx.get("model_sound_sets", {}).get(_figure, 0)) if idx is Dictionary else 0
		if sound_set > 0:
			sounds = CharacterSounds.new()
			sounds.name = "Sounds"
			add_child(sounds)
			sounds.setup(_model, _anim, sound_set)
	for node in _model.find_children("*", "MeshInstance3D", true, false):
		var mesh := (node as MeshInstance3D).mesh
		for i in mesh.get_surface_count():
			var mat := mesh.surface_get_material(i) as StandardMaterial3D
			if mat and mat.albedo_texture:
				var img := mat.albedo_texture.get_image()
				img.generate_mipmaps()
				mat.albedo_texture = ImageTexture.create_from_image(img)
				mat.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS_ANISOTROPIC
	_apply_model_yaw()


## A Catacombs race figure made on the character screens (CharacterStore entry: prefix + look).
func set_figure(c: Dictionary) -> void:
	var fig := Fig3Figure.new()
	fig.name = "Figure"
	add_child(fig)
	if not fig.load_figure(String(c.get("prefix", "cel_m"))):
		fig.queue_free()
		return
	fig.apply(c.get("look", {}))
	_model = fig
	_anim = fig.anim
	_set_loops()
	_strides = fig.meta.get("strides_units", {})
	_clip_len = fig.meta.get("clip_seconds", {})
	var sound_set := int(fig.meta.get("sound_set", 0))
	if sound_set > 0 and _anim:
		sounds = CharacterSounds.new()
		sounds.name = "Sounds"
		add_child(sounds)
		sounds.setup(fig.model, _anim, sound_set)
	_play("idle")
	_apply_model_yaw()
	refresh_gear.call_deferred()                           # the worn weapons, sheathed


## The server changed your model (ModelChange): a necromancer's shade, a berserker's Vendo form, an illusion - drawn
## as that monster model (monsters.json entry with "gltf") with its own clips; your race model again (an entry
## without "gltf") puts your figure and gear back (owner 2026-10-11: necromancers didn't become shades).
var _morph: Node3D
var _morph_casts := {}                         # a morph model's casting clips (monsters.json cast_clips)
var _unmorphed := {}                     # your figure while morphed: model, anim, strides, clip lengths


func morph(info: Dictionary) -> void:
	if _morph and is_instance_valid(_morph):
		_morph.queue_free()
	_morph = null
	if not _unmorphed.is_empty():
		_model = _unmorphed.model
		_anim = _unmorphed.anim
		_strides = _unmorphed.strides
		_clip_len = _unmorphed.clip_len
		_unmorphed = {}
		_morph_casts = {}
		if _model:
			_model.visible = true
	var path := String(info.get("gltf", ""))
	if path == "" or _model == null:
		_apply_model_yaw()
		return
	# the glTF with its skin, as the NPC views load it (the packed .scn has its textures taken out - drawn untextured,
	# your shade was a plain solid figure)
	var m: Node3D = null
	var ps := NpcManager._pack_model(path)
	if ps:
		m = ps.instantiate() as Node3D
	if m == null:
		push_warning("morph model missing: " + path)
		return
	_unmorphed = {"model": _model, "anim": _anim, "strides": _strides, "clip_len": _clip_len}
	_model.visible = false                                 # your figure and the gear on its bones
	m.scale *= float(info.get("scale", 1.0))
	m.position.y += Npc.figure_look(m, info, get_instance_id())   # skin alpha + hover (the shade floats, see-through)
	add_child(m)
	_morph = m
	_model = m
	var players := m.find_children("*", "AnimationPlayer", true, false)
	_anim = players[0] as AnimationPlayer if players.size() > 0 else null
	_set_loops()
	if _anim:
		Fig3Figure.add_rest_reset(_anim)
	_strides = info.get("strides_units", {})
	_clip_len = info.get("clip_seconds", {})
	_morph_casts = info.get("cast_clips", {})            # (its anim set's own clip per casting style: Npc.clip_for)
	_apply_model_yaw()
	_play("idle")


## The client's clamp clips play once (jump, land, death, swings, flinch, parry, evade); the rest loop.
func _set_loops() -> void:
	if _anim == null:
		return
	for clip in _anim.get_animation_list():
		_anim.get_animation(clip).loop_mode = Animation.LOOP_LINEAR if Fig3Figure.loops(clip) else Animation.LOOP_NONE


func _play(clip: String, speed := 1.0) -> void:
	if _anim == null or not _anim.has_animation(clip):
		return
	if _anim.current_animation != clip:
		_anim.play(clip, 0.15)
	_anim.speed_scale = speed


## Wounded: the 1.65 client's own rule (game.dll 0x438b5c, after the run speed from the server's MaxSpeed percent): below
## 35% health the speed is scaled by health / 35, never under a tenth - the server slows only NPCs (MaxSpeedCalculator),
## so the new client ran at full speed at any health (owner 2026-10-16). Not while flying (the GM speed case).
func _wounded_mult() -> float:
	var pct := int(PlayerData.health * 100.0)
	if flying or pct >= 35:
		return 1.0
	return maxf(pct / 35.0, 0.1)


func set_flying(on: bool) -> void:
	flying = on
	collision_mask = 0 if on else ZoneLoader.LAYER_WALL   # fly through buildings and terrain
	_arm.collision_mask = 0 if on else ZoneLoader.LAYER_WALL | ZoneLoader.LAYER_FLOOR | ZoneLoader.LAYER_SCENERY
	velocity = Vector3.ZERO


# --- combat (game/combat/combat.gd drives these) ------------------------------------------------------------------

func facing() -> float:
	return char_yaw


## The stance's version of a combat clip: combat_idle -> combat_idle_2h / _staff / _pole; attack_med ->
## attack_2h_med ... (canims.csv columns, build_races.py), falling back to the one-hand clip.
func _combat_clip(base: String) -> String:
	return WeaponModels.stance_clip(_anim, combat_stance, base)


## The active weapon's stance (WeaponModels.STANCES; the ranged set: bow / xbow / throw): the clips its swings and
## combat idle use.
func weapon_stance() -> String:
	if PlayerData.active_weapon == "ranged":
		return WeaponModels.ranged_kind(int(PlayerData.item_at(13).get("model", 0)))
	return WeaponModels.stance(int(MeleeMath.weapon(PlayerData).get("model", 0)))


func set_combat(on: bool, stance: String) -> void:
	in_combat = on
	combat_stance = stance
	refresh_gear()


## One swing: a random high / medium / low attack clip for the weapon's stance; hand "left" / "dual" a dual
## wielder's off-hand / both-weapons blow (the server's OneDualWeaponHit / BothDualWeaponHit). Returns the clip played.
func swing(stance: String, hand := "") -> String:
	combat_stance = stance
	var clip := WeaponModels.attack_clip(_anim, combat_stance, hand)
	_one_shot(clip)
	WeaponModels.flex_swing(self, clip)                    # a flex weapon's chain swings with the blow
	return clip


## A defence (canims.csv Parry / Evade / Block columns): the clip for the weapon's stance - one-hand, two-hand or
## polearm / staff; parries and blocks pick the low or the high one.
func defend(kind: String) -> void:
	if dead or _action_left > 0.0:
		return
	var clip := WeaponModels.defend_clip(_anim, combat_stance, kind)
	if clip != "":
		_one_shot(clip)


## A style's own animation (styles.csv Animation -> canims.csv column, content/characters/style_clips.json); returns
## the clip played, or "" when this figure has none (the generic swing plays instead).
## An emote (the client's emotes.csv id; build_races.py clip 'emote_<id>'). False when the figure lacks it.
func play_emote(id: int) -> bool:
	var clip := "emote_%d" % id
	if _anim == null or not _anim.has_animation(clip):
		return false
	_one_shot(clip)
	return true


func play_style(animation: int) -> String:
	var clip := String(Player.style_clips().get(str(animation), ""))
	if clip == "" or _anim == null or not _anim.has_animation(clip):
		return ""
	_one_shot(clip)
	WeaponModels.flex_swing(self, clip, true)              # the chain's own style swing
	return clip


static var _style_clips := {}


static func style_clips() -> Dictionary:
	if _style_clips.is_empty():
		var parsed = JSON.parse_string(FileAccess.get_file_as_string("res://content/characters/style_clips.json"))
		_style_clips = parsed if parsed is Dictionary else {"": ""}
	return _style_clips


## The bow (canims Bow Ready / Bow Aim / Bow Fire; a crossbow's Xbow, a thrown weapon's Throw clips): draw, hold the
## aim, loose.
func bow_draw() -> void:
	_one_shot(_ranged() + "_ready")
	_bow_hold = true


func bow_release(fired: bool) -> void:
	_bow_hold = false
	if fired:
		_one_shot(_ranged() + "_fire")
	else:
		_action_left = 0.0


var _bow_hold := false


func _ranged() -> String:
	if combat_stance in WeaponModels.RANGED:
		return combat_stance
	return WeaponModels.ranged_kind(int(PlayerData.item_at(13).get("model", 0)))


func flinch() -> void:
	if _action_left <= 0.0 and not dead:
		_one_shot("flinch")


func _one_shot(clip: String) -> void:
	clip = String(_morph_casts.get(clip, clip))             # (morphed: the form's own clip for a casting style)
	if _anim == null or not _anim.has_animation(clip):
		return
	_action = clip
	_action_left = clip_seconds(clip)
	_anim.play(clip, 0.1)
	_anim.seek(0.0, true)
	_anim.speed_scale = 1.0


## Casting (anims.csv Cast Start / Cast Mid / Cast End): the start once, the mid pose looping while the cast bar
## fills, the end once when the spell lands (an interrupted cast just drops back to idle).
## The spell's own casting style (spells.csv Anim1-3 via SpellFx: Crossed, 1H Circ, Upraised...): start / mid / end
## clip names; the plain cast_start / cast_mid / cast_end when the figure lacks them.
var _cast_clips := ["cast_start", "cast_mid", "cast_end"]


## seconds: the cast's time (the server's SpellCastAnimation); the pose then ends on its own CAST_GRACE after it
## if neither the spell nor an interruption ever comes (owner 2026-10-14: a heal on a companion that died mid-cast, or
## running off while casting, left the casting pose stuck - the server dropped the cast without a word).
const CAST_GRACE := 2.0
var _cast_left := INF


func cast_start(clips: Array = [], seconds := -1.0) -> void:
	casting_spell = true
	_cast_left = seconds if seconds >= 0.0 else INF
	_cast_clips = [String(_morph_casts.get("cast_start", "cast_start")), String(_morph_casts.get("cast_mid", "cast_mid")),
			String(_morph_casts.get("cast_end", "cast_end"))]
	for i in mini(clips.size(), 3):
		var c := String(_morph_casts.get(String(clips[i]), clips[i]))   # a shade / Vendo form: its own cast clips
		if c != "" and _anim and _anim.has_animation(c):
			_cast_clips[i] = c
	_one_shot(_cast_clips[0])


func cast_end(landed := false) -> void:
	casting_spell = false
	if landed:
		_one_shot(_cast_clips[2])
	else:
		_action_left = 0.0


var casting_spell := false


func clip_seconds(clip: String) -> float:
	return float(_clip_len.get(clip, 1.0))


## The figures' "Stand Up" clip (anims.csv) is the 8 s standing idle, not a rise (pelvis never leaves standing height),
## and playing it out slid a moving player along for 4-8 s (owner 2026-10-10): standing up is the sit-down played
## backwards (0.8-1.5 s), and moving cuts it short (_animate).
func sit(on: bool) -> void:
	sitting = on
	if on:
		_one_shot("sit_down")
	elif _anim and _anim.has_animation("sit_down"):
		_action = "stand_up"
		_action_left = clip_seconds("sit_down")
		_anim.play_backwards("sit_down", 0.1)
		_anim.speed_scale = 1.0


func die() -> void:
	dead = true
	sitting = false
	in_combat = false
	refresh_gear()


func revive() -> void:
	dead = false
	_death_played = false
	_action_left = 0.0
	_play("idle")


## Draw the active weapons where the client hangs them (objects.csv flags, owner rules): in attack mode the main
## weapon in the right hand (a left-hand weapon in the left hand); sheathed, one-handers at the belt and two-handers /
## polearms / staffs on the back. A shield is always on the left arm - the client never slings it on the back, and
## with a two-hander drawn it simply isn't shown (owner 2026-10-10). Only the active set shows (Standard: right +
## left, Two Handed: the two-hander, Ranged: the bow - the server's SwitchWeapon rules).
func refresh_gear() -> void:
	if in_combat:
		combat_stance = weapon_stance()                     # another weapon set drawn in attack mode: its stance
	for g in _gear:
		if is_instance_valid(g):
			g.queue_free()
	_gear.clear()
	_gear = dress(_model, PlayerData.item_at, PlayerData.active_weapon, in_combat, true,
			PlayerData.character.get("gear", {}) if PlayerData.character.get("gear") is Dictionary else {})


## A figure's worn gear, shared with the character select screen (owner 2026-10-10: the staff / armour didn't show
## there): armour parts on a Fig3Figure (pipeline/build_armor.py), and the active weapon set on its bones. item_at:
## slot -> item Dictionary ({} when empty). Returns the bone attachments made.
## gear: the server's look flags for this character - {"hood": bool, "cloak_hidden": bool, "helm_hidden": bool}.
static func dress(model: Node3D, item_at: Callable, active_weapon: String, combat: bool, armor := true, gear := {}) -> Array:
	var made: Array = []
	if armor and model is Fig3Figure:                               # worn armour on the figure (pipeline/build_armor.py)
		var fig := model as Fig3Figure
		var female := String(fig.meta.get("prefix", "")).ends_with("_f")
		var parts := {}
		var tints := {}
		for slot in [22, 23, 25, 27, 28]:
			var it: Dictionary = item_at.call(slot)
			if not it.is_empty():
				var p := Fig3Figure.armor_parts(int(it.get("model", 0)), female)
				parts.merge(p, true)
				for k in p:                                         # its dye on the parts it draws
					tints[k] = Fig3Figure.dye(int(it.get("color", 0)))
		var cl: Dictionary = item_at.call(26)                  # the cloak (its hood: /hood)
		if not cl.is_empty():
			var cp := Fig3Figure.armor_parts(int(cl.get("model", 0)), female)
			if cp.has("cloak"):
				parts["cloak"] = cp.cloak
				tints["cloak"] = Fig3Figure.dye(int(cl.get("color", 0)))
		fig.hood_up = bool(gear.get("hood", false))
		fig.cloak_hidden = bool(gear.get("cloak_hidden", false))
		fig.helm_hidden = bool(gear.get("helm_hidden", false))
		fig.set_armor(parts, tints)
		var hm: Dictionary = item_at.call(21)                  # the helm / hat
		fig.set_helm(int(hm.get("model", 0)) if not hm.is_empty() else 0, fig.helm_hidden, int(hm.get("color", 0)))
	var skel: Skeleton3D = null
	if model:
		var found := model.find_children("*", "Skeleton3D", true, false)
		skel = found[0] if found.size() > 0 else null
	if skel == null:
		return made
	var sets := {"standard": [10, 11], "twohand": [12], "ranged": [13]}
	for slot in sets.get(active_weapon, [10, 11]):
		var it: Dictionary = item_at.call(slot)
		if it.is_empty():
			continue
		var model_id := int(it.get("model", 0))
		# an NPC with a shield model in its right hand too (shield merchants' NPCEquipment lists it in both hands): the
		# client draws the right hand's one only (owner 2026-10-11: a shield in both hands; the old client: right arm)
		var shield_model := int(WeaponModels.info(model_id).get("shield", 0)) > 0
		var right: Dictionary = item_at.call(10)
		if slot == 11 and shield_model and int(WeaponModels.info(int(right.get("model", 0))).get("shield", 0)) > 0:
			continue
		var shield: bool = int(it.get("object_type", 0)) == ItemDb.SHIELD_TYPE or (shield_model and slot == 11)
		var on_back: bool = int(it.get("hand", 0)) == 1 or slot == 12 or slot == 13 or WeaponModels.stance(model_id) in ["2h", "pole", "staff", "scy"]
		var bone := ""
		# objects.csv "On Belt": only weapons marked sheathable go to the belt / back outside attack mode; the rest -
		# every staff (stance 4, all 118 marked 0), most polearms and bows - stay in the hand (owner 2026-10-10)
		var sheathes := int(WeaponModels.info(model_id).get("belt", 1)) == 1
		if shield:
			bone = "Bip01 L Shield"
		elif combat or not sheathes:
			# the skeleton's "Held" nodes under each hand match the weapon NIF's HELD frame (the client's grip point)
			bone = "Bip01 L Held" if slot == 11 or slot == 13 else "Bip01 R Held"
		elif on_back:
			bone = "Bip01 R Back"
		else:
			bone = "Bip01 R Belt" if slot == 11 else "Bip01 L Belt"
		var idx := skel.find_bone(bone)
		var w := WeaponModels.make(model_id, combat)
		if idx < 0 or w == null:
			push_warning("gear: no %s (bone %d) or no model %d" % [bone, idx, model_id])
			continue
		WeaponModels.dye(w, int(it.get("color", 0)))           # its luster / enamel
		var at := BoneAttachment3D.new()
		at.bone_name = bone
		skel.add_child(at)
		at.add_child(w)
		WeaponModels.add_effect(w, int(it.get("effect", 0)))   # its glow / flame (an item's weapon effect)
		made.append(at)
	return made


## /follow /stick /face: false (and the reason in chat) when the target can't be tracked.
func start_track(mode: String, target: Node3D, target_name: String) -> bool:
	if target == null or not is_instance_valid(target):
		PlayerData.message.emit("You must select a target to %s!" % mode, "system")
		return false
	if target == self:
		PlayerData.message.emit("You can't %s yourself!" % mode, "system")
		return false
	if mode == track_mode and target == track_target:   # the same command again turns it off, as the old client did
		stop_track()                                     # (in-game check 2026-10-17: a second /stick stuck again)
		return false
	if mode != "face" and global_position.distance_to(target.global_position) > TRACK_START_M:
		PlayerData.message.emit("%s is too far away to %s." % [target_name, mode], "system")
		return false
	stop_track(true)
	track_target = target
	track_mode = mode
	track_name = target_name
	autorun = false                                   # patch notes: stick / follow / face turns run lock off
	PlayerData.message.emit({"follow": "You are now following %s.", "stick": "You are now sticking to %s.",
			"face": "You are now facing %s."}[mode] % target_name, "system")
	return true


func stop_track(quiet := false) -> void:
	if track_mode != "" and not quiet:
		PlayerData.message.emit({"follow": "You are no longer following %s.", "stick": "You are no longer sticking to %s.",
				"face": "You are no longer facing %s."}[track_mode] % track_name, "system")
	track_mode = ""
	track_target = null


func face(yaw_radians: float) -> void:
	char_yaw = yaw_radians
	cam_yaw = yaw_radians
	_body_offset = 0.0
	_apply_model_yaw()


func _apply_model_yaw() -> void:
	if _model:
		_model.rotation.y = char_yaw + PI + _body_offset   # the converted model faces +Z


## The pointer is over an interface window (owner 2026-10-11: scrolling a long server menu also zoomed the camera -
## a list that reached its end let the wheel through).
func _over_window() -> bool:
	var c := get_viewport().gui_get_hovered_control()
	while c:
		if c is ClassicWindow:
			return c.is_visible_in_tree()
		c = c.get_parent() as Control
	return false


func _unhandled_input(event: InputEvent) -> void:
	if not input_enabled:
		return
	# only presses that reach the world steer / look; a click on an interface window is taken by the window
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		_lmb_world = event.pressed
	elif event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_RIGHT:
		_rmb_world = event.pressed
	var rmb := _rmb_world and Input.is_mouse_button_pressed(MOUSE_BUTTON_RIGHT)
	var lmb := _lmb_world and Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT)
	if event is InputEventMouseMotion and (rmb or lmb):
		var dy: float = event.relative.y * (-1.0 if invert_mouse else 1.0) * mouse_sensitivity
		cam_yaw -= event.relative.x * MOUSE_TURN * mouse_sensitivity
		if free_camera:
			cam_pitch = clampf(cam_pitch - dy * 0.004, -1.35, 0.6)
		else:
			cam_pitch = clampf(cam_pitch - dy * 0.004, -CAM_PITCH, CAM_PITCH)
		if rmb:
			char_yaw = cam_yaw                          # steering: the character follows the camera
	elif event is InputEventMouseButton:
		if event.button_index in [MOUSE_BUTTON_LEFT, MOUSE_BUTTON_RIGHT]:
			# hide the cursor while dragging, as WoW does, and put it back where the drag began (capturing the mouse
			# parks it in the middle of the window; the owner saw every click jump the cursor to the centre)
			if (rmb or lmb) and Input.mouse_mode != Input.MOUSE_MODE_CAPTURED:
				_cursor_at = get_viewport().get_mouse_position()
				Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
			elif not (rmb or lmb) and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
				Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
				get_viewport().warp_mouse(_cursor_at)
			if event.pressed and event.button_index == MOUSE_BUTTON_RIGHT:
				char_yaw = cam_yaw                      # right-click snaps the character to the camera heading
		elif event.button_index in [MOUSE_BUTTON_WHEEL_UP, MOUSE_BUTTON_WHEEL_DOWN] and _over_window():
			pass                                        # the wheel over a window scrolls it, never the camera
		elif event.pressed and event.button_index == MOUSE_BUTTON_WHEEL_UP:
			cam_distance = maxf(CAM_MIN, cam_distance * 0.88)
		elif event.pressed and event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			cam_distance = minf(CAM_MAX_FREE if free_camera else CAM_MAX, cam_distance / 0.88)
	if (event is InputEventKey or event is InputEventMouseButton) and event.is_pressed() and not event.is_echo():
		# the client's bindable actions (Keybinds: keyboard.dat presets, rebindable incl. mouse buttons)
		if Keybinds.pressed(event, "run_lock"):
			autorun = not autorun
		elif Keybinds.pressed(event, "torch") or (event is InputEventKey and event.shift_pressed
				and Keybinds.pressed(_unshifted(event), "torch")):   # its key or Shift + its key, as the client
			set_torch(not torch_on)
			var cfg := ConfigFile.new()
			cfg.load("user://settings.cfg")
			cfg.set_value("player", "torch", torch_on)
			cfg.save("user://settings.cfg")
		elif Keybinds.pressed(event, "walk"):
			walking = not walking
		elif Keybinds.pressed(event, "move_forward") or Keybinds.pressed(event, "move_back"):
			autorun = false


func _unshifted(event: InputEventKey) -> InputEventKey:
	var e := event.duplicate() as InputEventKey
	e.shift_pressed = false
	return e


func _key(k: Key) -> bool:
	return input_enabled and not dead and Input.is_physical_key_pressed(k)


func _act(id: String) -> bool:
	return input_enabled and not dead and not _ui_typing() and Keybinds.held(id)


func _ui_typing() -> bool:
	var f := get_viewport().gui_get_focus_owner()       # typing in chat / a text box doesn't move the character
	return f is LineEdit or f is TextEdit


## A new place (spawn, teleport, zone entry): hold still a few physics frames - the floors' collision is only there
## after the physics world has stepped once, and a city or dungeon has no terrain grid to catch a fall.
func hold() -> void:
	hold_frames = 12
	velocity = Vector3.ZERO


func _physics_process(delta: float) -> void:
	var t0 := Time.get_ticks_usec()
	_physics_step(delta)
	Perf.phys_add("player", Time.get_ticks_usec() - t0)        # (Perf's live log: the physics tick by part)


func _physics_step(delta: float) -> void:
	if hold_frames > 0:
		hold_frames -= 1
		velocity = Vector3.ZERO
		return
	if not Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT):
		_lmb_world = false
	if not Input.is_mouse_button_pressed(MOUSE_BUTTON_RIGHT):
		_rmb_world = false
	if not (_lmb_world or _rmb_world) and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED and input_enabled:
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE              # a release the world never saw (over a window)
		get_viewport().warp_mouse(_cursor_at)
	var rmb := input_enabled and _rmb_world and not dead       # a dead character doesn't move (both buttons either)
	var lmb := input_enabled and _lmb_world and not dead
	if riding:                                        # the horse carries you; the camera still orbits
		velocity = Vector3.ZERO
		if input_enabled and _act("jump"):
			PlayerData.dismount_requested.emit()          # PlayerDismountRequestHandler
		var clip := ride_clip if _anim and _anim.has_animation(ride_clip) else "ride_horse"
		if _anim and _anim.has_animation(clip) and _anim.current_animation != clip:
			_anim.get_animation(clip).loop_mode = Animation.LOOP_LINEAR
			_anim.play(clip, 0.2)
		_pivot.rotation = Vector3(cam_pitch, cam_yaw, 0.0)
		_arm.spring_length = lerpf(_arm.spring_length, cam_distance, minf(1.0, delta * 10.0))
		return
	if dead:
		autorun = false
	var classic := movement_mode == "classic"
	if rmb and lmb:
		autorun = false
	var fwd := _act("move_forward") or (rmb and lmb) or autorun
	var back := _act("move_back")
	var left := _act("turn_left")
	var right := _act("turn_right")
	if track_mode != "":
		var manual := fwd or back or _act("strafe_left") or _act("strafe_right") or (track_mode != "face" and (left or right))
		var gone: bool = track_target == null or not is_instance_valid(track_target) or not track_target.is_inside_tree() 				or (track_target.has_method("is_alive") and not track_target.is_alive())
		var far: bool = track_target != null and is_instance_valid(track_target) and track_mode == "stick" 				and global_position.distance_to(track_target.global_position) > STICK_BREAK_M
		if manual or gone or far or dead:
			stop_track()
		else:
			var d := track_target.global_position - global_position
			char_yaw = atan2(-d.x, -d.z)
			var gap := Vector2(d.x, d.z).length()
			if track_mode == "follow" and gap > FOLLOW_GAP_M or track_mode == "stick" and gap > STICK_GAP_M:
				fwd = true
	var strafe := 0.0
	var turn := 0.0
	if rmb and not classic:                           # modern: with the right mouse held, A/D strafe
		strafe += (1.0 if right else 0.0) - (1.0 if left else 0.0)
	else:
		turn += (1.0 if left else 0.0) - (1.0 if right else 0.0)
	strafe += (1.0 if _act("strafe_right") else 0.0) - (1.0 if _act("strafe_left") else 0.0)
	strafe = clampf(strafe, -1.0, 1.0)
	var ahead := (1.0 if fwd else 0.0) - (1.0 if back else 0.0)

	if flying:
		_fly(delta, ahead, strafe, turn)
		return

	char_yaw += turn * TURN_RATE * delta
	var moving := absf(ahead) > 0.0 or absf(strafe) > 0.0
	if not lmb and (moving or absf(turn) > 0.0):
		cam_yaw = lerp_angle(cam_yaw, char_yaw, minf(1.0, delta * 8.0))   # camera swings back behind
	if not rmb and not lmb and absf(turn) > 0.0:
		cam_yaw = char_yaw

	var local := Vector3(strafe, 0.0, -ahead)
	if local.length() > 1.0:
		local = local.normalized()                    # diagonals are not faster
	var water := _water_h(global_position.x, global_position.z) if zone else -INF
	var bed := _ground_h(global_position.x, global_position.z, global_position.y) if zone else -INF
	swimming = water - bed > SWIM_DEPTH and global_position.y < water + 0.05     # deep enough, and in it (not above)
	if sounds:
		sounds.surface = "swim" if swimming else ("water" if water - global_position.y > 0.1 else "dirt")
	var speed := RUN_SPEED
	if swimming:
		speed = SWIM_SPEED
	elif ahead < 0.0:
		speed = CLASSIC_BACK_SPEED if classic else BACK_SPEED   # backpedalling, straight or diagonal
	elif classic and ahead == 0.0 and strafe != 0.0:
		speed = CLASSIC_SIDE_SPEED                    # DAoC's slow side-step
	elif walking or _key(KEY_SHIFT):
		speed = WALK_SPEED
	var wish := local.rotated(Vector3.UP, char_yaw) * speed * speed_mult * buff_speed * snare_mult * encumbrance * stealth_mult \
			* _wounded_mult()
	if cc != "":
		wish = Vector3.ZERO                             # stunned / mesmerized / rooted: no moving

	if not climbing and not swimming and ahead > 0.0 and cc == "" and _climb_ahead():
		climbing = true
		PlayerData.message.emit("You start climbing.", "system")
	if climbing and (_act("jump") or swimming or cc != "" or dead):
		_stop_climbing()
	if climbing:
		# up while pressing forward (into the ladder: the climb wall holds you), down with back, still otherwise
		var rate := minf(1.0, speed_mult * buff_speed * snare_mult * encumbrance)
		_climb_vy = CLIMB_SPEED * rate * (1.0 if ahead > 0.0 else (-1.0 if ahead < 0.0 else 0.0))
		var push := wish if ahead > 0.0 else Vector3.ZERO
		velocity = Vector3(push.x, _climb_vy, push.z)
		grounded = false
		_client_move(delta)
		if ahead < 0.0 and grounded:
			_stop_climbing()                              # down at the bottom
		elif ahead > 0.0 and not _climb_ahead():
			_stop_climbing()                              # over the top: stepped off onto the floor
		_air_time = 0.0
		_animate(ahead, strafe, speed, delta)
		_pivot.rotation = Vector3(cam_pitch, cam_yaw, 0.0)
		_arm.spring_length = lerpf(_arm.spring_length, cam_distance, minf(1.0, delta * 10.0))
		return
	if swimming:
		velocity.x = wish.x
		velocity.z = wish.z
		# 1.65: surface swimming only (diving came with Trials of Atlantis, 1.70) - held at the surface
		velocity.y = clampf((water - SWIM_FLOAT - global_position.y) * 4.0, -3.0, 3.0)
	elif grounded:
		velocity.x = wish.x
		velocity.z = wish.z
		velocity.y = JUMP_VELOCITY if _act("jump") else 0.0
	else:
		# airborne: keep the take-off momentum, a little steering
		velocity.x = lerpf(velocity.x, wish.x, AIR_CONTROL * delta * 10.0)
		velocity.z = lerpf(velocity.z, wish.z, AIR_CONTROL * delta * 10.0)
		velocity.y -= GRAVITY * delta
	_client_move(delta)
	_air_time = 0.0 if grounded or swimming else _air_time + delta

	if zone and zone.city and grounded:
		_last_footing = global_position
	if zone and zone.city and _last_footing != Vector3.ZERO and global_position.y < _last_footing.y - 300.0:
		global_position = _last_footing + Vector3(0, 0.3, 0)   # fell out of a city / dungeon: back where you stood
		velocity = Vector3.ZERO
	if zone and not zone.city and global_position.y < _ground_h(global_position.x, global_position.z, global_position.y) - 2.0:
		global_position.y = _ground_h(global_position.x, global_position.z) + 0.5   # fell through: recover

	_animate(ahead, strafe, speed, delta)
	_pivot.rotation = Vector3(cam_pitch, cam_yaw, 0.0)
	_arm.spring_length = lerpf(_arm.spring_length, cam_distance, minf(1.0, delta * 10.0))


func _animate(ahead: float, strafe: float, speed: float, delta: float) -> void:
	# diagonal movement leans the body toward the travel direction (WoW turns the legs 45 degrees)
	# pure strafing turns the body most of the way toward the side and keeps the run cycle going: the client's own
	# side-step clips are DAoC's slow shuffle, which looked frozen at full strafe speed (owner, 2026-10-09)
	var target_offset := 0.0
	var classic := movement_mode == "classic"
	if classic:
		pass                                          # classic: the body always faces forward
	elif ahead > 0.0 and strafe != 0.0:
		target_offset = -strafe * PI * 0.25
	elif ahead < 0.0 and strafe != 0.0:
		target_offset = strafe * PI * 0.25
	elif ahead == 0.0 and strafe != 0.0:
		target_offset = -strafe * PI * 0.4
	_body_offset = lerp_angle(_body_offset, target_offset, minf(1.0, delta * 10.0))
	_apply_model_yaw()
	_action_left -= delta
	var moving := ahead != 0.0 or strafe != 0.0
	if casting_spell:
		_cast_left -= delta
		# moving ends the casting pose at once (as the old client: moving interrupts a cast - the server says so a
		# moment later), and a cast nothing came back for ends after its time
		if (moving and Server.active) or _cast_left < -CAST_GRACE:
			cast_end(false)
	if moving and _action == "stand_up":
		_action_left = 0.0                            # walking off from a sit goes straight into the run
	if dead:
		if not _death_played:                         # once, then the last frame holds (the clip doesn't loop)
			_death_played = true
			_one_shot("death")
	elif force_clip != "":
		_play(force_clip)
	elif _action_left > 0.0 and (grounded or swimming):
		# a swing / flinch / cast end plays out even while moving (owner 2026-10-10: moving cut swings off, and
		# stopping mid-swing left the run clip playing): the 1.65 client has no upper / lower body blending, so a
		# started full-body action finishes, sliding along, and movement takes over after it. In the water too
		# (owner 2026-10-14: combat while swimming as the original) - the figures have no swimming swings or casts
		# (anims.csv / canims.csv), so the same full-body clips play at the surface
		pass
	elif climbing:
		# the figure's anims.csv Ladder clip (Cat_CL_H_up.kfa, "climb up"): run backwards going down, held still
		_play("ladder" if _anim and _anim.has_animation("ladder") else "idle", signf(_climb_vy))
	elif sitting and not moving:
		_play("sit_idle")
	elif swimming and not moving and casting_spell:
		_play(_cast_clips[1])                         # a cast held in the water (moving stops a cast)
	elif swimming and not moving and _bow_hold:
		_play(_ranged() + "_aim")
	elif swimming:
		_play("swim")
	elif not grounded and (velocity.y > 0.0 or _air_time > 0.15):
		_play("jump")                                 # a jump, or a real fall - not a short drop off a ledge
	elif ahead < 0.0:
		_play("walk_back", _sync("walk_back", "back", speed))
	elif classic and ahead == 0.0 and strafe != 0.0:
		var clip := "strafe_right" if strafe > 0.0 else "strafe_left"
		_play(clip, _sync(clip, "strafe", speed))
	elif ahead >= 0.0 and (ahead > 0.0 or strafe != 0.0):
		if speed == WALK_SPEED:
			_play("walk", _sync("walk", "walk", speed))
		else:
			_play("run", _sync("run", "run", speed))
	elif casting_spell:
		_play(_cast_clips[1])
	elif _bow_hold:
		_play(_ranged() + "_aim")
	else:
		_play(_combat_clip("combat_idle") if in_combat else "idle")


func _register_torch() -> void:
	if zone:
		zone.add_dynamic_light(torch, TORCH_ENERGY)


func set_torch(on: bool) -> void:
	torch_on = on
	if torch:
		torch.visible = on


## The client's order (see PICK_LIFT): vertical integrate, floor pick at the new spot (lift onto anything within the
## pick range), slide along walls at that height, then stand on a floor within 1 unit or fall.
func _client_move(delta: float) -> void:
	var feet_before := global_position.y
	var vy := velocity.y
	var y := feet_before + vy * delta
	var step := Vector3(velocity.x, 0.0, velocity.z) * delta
	var floor_y := _floor_below(Vector3(global_position.x + step.x, y, global_position.z + step.z), feet_before)
	var on_ladder := climbing and _climb_ahead()
	if floor_y > y and not on_ladder:
		y = floor_y                                     # 2. lifted onto the floor (the client's step-up)
	if step.length() > 0.0001 and grounded and not on_ladder:
		# ...and at the collider's leading edge: a step no taller than the collider's lift (one the walls would let
		# through anyway) lifts you as you reach it, so steep narrow stairs (0.40 m risers on 0.25 m treads at the
		# Lethantis tower) don't catch the next riser before the centre is over the step
		var lead := global_position + step.normalized() * (STEP_LEAD + 0.02)
		var lead_y := _floor_below(Vector3(lead.x, y, lead.z), feet_before)
		if lead_y > y and lead_y - y <= COLLIDER_LIFT:
			y = lead_y
	global_position.y = y
	velocity = Vector3(velocity.x, 0.0, velocity.z)
	move_and_slide()                                    # 3. walls only, horizontal
	global_position.y = y                               # flattened normals: walls never push up or down
	velocity.y = vy
	floor_y = _floor_below(global_position, feet_before)
	var was_grounded := grounded
	# (+1 unit: the client's "more than 16 units" - a 16-unit stair riser measures 16.0x in floats and must not fall)
	if climbing and vy >= 0.0:
		grounded = false                                # on the ladder: held by it, not standing
	elif was_grounded and vy <= 0.0 and not swimming and global_position.y - floor_y <= FALL_HEIGHT + 0.025:
		global_position.y = floor_y                     # walking down: stay on the ground (not a fall in the client)
		grounded = true
		velocity.y = 0.0
		_last_footing = global_position
	elif global_position.y - floor_y <= FLOOR_SNAP and vy <= 0.0:
		global_position.y = maxf(global_position.y, floor_y) if swimming else floor_y
		if not was_grounded and not swimming and not flying and vy < 0.0:
			landed.emit(-vy / 0.025)                    # PlayerPositionUpdateHandler: fall damage on touching ground
		grounded = not swimming
		velocity.y = 0.0 if not swimming else velocity.y
	else:
		grounded = false
		if swimming and global_position.y < floor_y:
			global_position.y = floor_y                 # swimming along the lake bed


## A ladder's climb wall right in front of the character (ZoneLoader's ClimbBodies), at the collider's bottom (0.5 m)
## or chest height: climbing lasts until the collider's bottom is over the top of the climb wall.
func _climb_ahead() -> bool:
	var fwd := Vector3(-sin(char_yaw), 0.0, -cos(char_yaw))
	var space := get_world_3d().direct_space_state
	for h in [0.5, 1.2]:
		var from := global_position + Vector3(0, h, 0)
		var q := PhysicsRayQueryParameters3D.create(from, from + fwd * (STEP_LEAD + 0.3), ZoneLoader.LAYER_WALL)
		q.hit_back_faces = true
		var hit := space.intersect_ray(q)
		if not hit.is_empty() and hit.collider is Node and (hit.collider as Node).name == "ClimbBodies":
			return true
	return false


func _stop_climbing() -> void:
	if climbing:
		climbing = false
		_climb_vy = 0.0
		PlayerData.message.emit("You are no longer climbing.", "system")


func _ground_h(x: float, z: float, near_y := INF) -> float:
	return region.height_at(x, z, near_y) if region else zone.height_at(x, z, near_y)


func _water_h(x: float, z: float) -> float:
	return region.water_level_at(x, z) if region else zone.water_level_at(x, z)


## Seamless zones: you crossed a border and the scene moved by -d.
func rebase(d: Vector3) -> void:
	if _last_footing != Vector3.ZERO:
		_last_footing -= d


## Height of the floor under p: a ray straight down from max(64 units, this frame's drop) above the feet against the
## floor layer (terrain + every visible face), like the client's pick (game.dll 0x467692). -INF when nothing is hit.
func _floor_below(p: Vector3, feet_before: float) -> float:
	var start := p.y + maxf(PICK_LIFT, feet_before - p.y)
	var best := -INF
	if zone and not zone.city:
		# (a city's grid is the HIGHEST floor at each point - roofs, wall tops: as a floor its slopes between a street
		# and a wall lifted you up onto the wall, owner 2026-10-10 "an invisible bowl" in Camelot; cities use the pick)
		var t := _ground_h(p.x, p.z)
		if t <= start:
			best = t
	var q := PhysicsRayQueryParameters3D.create(Vector3(p.x, start, p.z), Vector3(p.x, start - 500.0, p.z),
			ZoneLoader.LAYER_FLOOR)
	q.hit_back_faces = false
	var hit := get_world_3d().direct_space_state.intersect_ray(q)
	if hit and hit.position.y > best:
		best = hit.position.y
	return best


## Playback rate that makes a clip's feet match the ground: movement speed / (stride per cycle / cycle length).
func _sync(clip: String, stride_key: String, speed_mps: float) -> float:
	var stride := float(_strides.get(stride_key, 0.0))
	var length := float(_clip_len.get(clip, 0.0))
	if stride <= 0.0 or length <= 0.0:
		return 1.0
	return clampf((speed_mps / 0.025) / (stride / length), 0.3, 3.0)


func _fly(delta: float, ahead: float, strafe: float, turn: float) -> void:
	# fly where the camera looks: forward/back along the view (pitch included), strafe sideways, Space up, Ctrl down
	cam_yaw += turn * TURN_RATE * delta
	char_yaw = cam_yaw
	var basis := Basis(Vector3.UP, cam_yaw) * Basis(Vector3.RIGHT, cam_pitch)
	var move := basis * Vector3(strafe, 0.0, -ahead)
	if _key(KEY_SPACE):
		move.y += 1.0
	if _key(KEY_CTRL):
		move.y -= 1.0
	var spd := FLY_FAST if _key(KEY_SHIFT) else FLY_SPEED
	if move.length() > 0.01:
		global_position += move.normalized() * spd * delta
	velocity = Vector3.ZERO
	_apply_model_yaw()
	_pivot.rotation = Vector3(cam_pitch, cam_yaw, 0.0)
	_arm.spring_length = lerpf(_arm.spring_length, cam_distance, minf(1.0, delta * 10.0))
	_play(force_clip if force_clip != "" else "idle")
