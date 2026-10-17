class_name ServerWorld
extends NpcManager
## The server's world in the game (Offline DAoC Rebuilt, owner 2026-10-11): every NPC, monster and bot the Claude
## version's server shows you - NPCCreate / ObjectUpdate / RemoveObject / EquipmentUpdate - drawn with the game's own
## views (Npc: Catacombs figures for the player races, the classic monster models, name plates, click targeting),
## as the old DAoC client drew them. Nothing here thinks: the server runs their brains, fights and movement; between
## its updates a mover keeps walking toward where the server said it is going (the client's own dead reckoning).
## Also the server's chat lines, your health / power / endurance, swings, casts, emotes and deaths.

const RUN_UNITS := 150.0                     # a mover faster than this (units / s) runs, slower walks
const SNAP_M := 6.0                          # an update this far from where it is drawn: jump there
# eChatType -> the chat window's kinds
const CHAT_KINDS := {0: "system", 1: "say", 2: "send", 3: "group", 4: "guild", 5: "broadcast", 6: "emote", 7: "help",
		8: "chatgroup", 9: "advice", 10: "officer", 11: "alliance", 12: "group", 13: "group", 15: "broadcast",
		16: "spells", 17: "combat", 18: "damage_taken", 19: "combat", 20: "merchant", 21: "system", 22: "combat_others",
		23: "combat_others", 24: "combat", 25: "spells", 26: "loot", 27: "resists", 28: "system", 29: "damage_taken",
		30: "combat", 31: "spells", 32: "combat_others", 33: "combat_others", 34: "combat_others", 35: "system",
		36: "merchant", 100: "system"}
# the player races' models whose monsters.json entry has no figure race (named "Norse Male" ...)
const RACE_WORDS := {"briton": "bri", "avalonian": "ava", "highlander": "hig", "saracen": "sar", "inconnu": "inc",
		"norse": "nor", "troll": "tro", "dwarf": "dwa", "kobold": "kob", "valkyn": "val", "celt": "cel",
		"firbolg": "fir", "elf": "elf", "lurikeen": "lur", "sylvan": "syl"}

var viewer: Node
var by_oid := {}                             # object id -> NpcState
var _mover := {}
var objects := {}                            # object id -> Node3D: things the server shows on the ground (ObjectCreate)
const OBJECT_PICK := 1 << 11                 # click layer for ground objects
const PICK_M := 6.0
const BAG_MODEL := 488                       # "bag of coins": what lies there when an item has no world model
const BAKED_M := 2.0                         # a server object this close to a baked zone prop is that prop                          # WorldMgr.PICKUP_DISTANCE-ish: in reach to pick up                             # NpcState -> {speed (units/s), dest (Vector3 or null), target}


func setup_server(v: Node, zone_loader: ZoneLoader, p: Node3D) -> void:
	viewer = v
	zone = zone_loader
	player = p
	var m = JSON.parse_string(FileAccess.get_file_as_string("res://content/monsters/monsters.json"))
	models = m if m is Dictionary else {}
	data = {"equipment": {}, "spawns": []}
	var t = JSON.parse_string(FileAccess.get_file_as_string(zone.dir.path_join("npcs.json"))) \
			if FileAccess.file_exists(zone.dir.path_join("npcs.json")) else null
	if t is Dictionary:
		_con = (t as Dictionary).get("con", [])           # the old server's con table (ConLevels), the same everywhere
		data["examine"] = (t as Dictionary).get("examine", {})
	set_physics_process(true)
	var plates := NamePlates.new()
	plates.manager = self
	add_child(plates)
	Server.world.connect(_on_world)
	# a new region's world (a teleport to the Shrouded Isles): your speed as the server last sent it - it isn't sent
	# again while it stays the same (owner 2026-10-14: a skald companion's speed song stopped working after a zone
	# change until the group was re-formed)
	_apply_max_speed(Server.max_speed_pct)


func _exit_tree() -> void:
	super._exit_tree()
	if Server.world.is_connected(_on_world):
		Server.world.disconnect(_on_world)


## A neighbour zone streamed in / out (RegionWorld): nothing of the game's own joins or goes - the server shows every
## NPC, monster and bot, and removes them itself. (Owner 2026-10-14: NpcManager's add_zone loaded the neighbour's
## offline npcs.json spawns here - client-only fakes on top of the real ones, the Raumerik bounty hunter that only
## said "you target", a second Wretch of Winter, Sheeroe Hills / Malmohus littered - and simulated them every tick.)
func add_zone(_z: ZoneLoader) -> void:
	pass


func remove_zone(_zone_id: int) -> void:
	pass


func _current_zone() -> int:
	return int(region.current.info.id) if region and region.current else int(zone.info.id)


## Region units -> the scene (the zone you are in at the origin).
func scene_pos(gx: float, gy: float, gz: float) -> Vector3:
	return Server.to_local(_current_zone(), gx, gy, gz)


## A zone's offsets (ObjectUpdate) -> the scene.
func _zone_pos(zone_id: int, xoff: int, yoff: int, z: int) -> Vector3:
	var zi := Server.zone_info(zone_id)
	if zi.is_empty():
		return Vector3.INF
	return scene_pos(float(zi.x) * 8192.0 + xoff, float(zi.y) * 8192.0 + yoff, float(z))


func _on_world(kind: String, d: Dictionary) -> void:
	match kind:
		"npc": _add_npc(d)
		"object": _add_object(d)
		"move": _move(d)
		"remove": _remove(int(d.oid), true, int(d.get("type", 1)))
		"equipment": _equip(d)
		"message": _message(d)
		"status": _status(d)
		"combat": _combat(d)
		"cast": _cast(d)
		"spell_effect": _spell_effect(d)
		"interrupt": _interrupt(int(d.caster))
		"emote": _emote(d)
		"death": _death(int(d.oid))
		"revive":
			if int(d.oid) == Server.me_oid:
				_revived_at = Time.get_ticks_msec()
			if int(d.oid) == Server.me_oid and viewer and viewer.player:
				viewer.player.revive()
				if viewer.ui:
					viewer.ui.show_release(false)
		"los": _los(int(d.source), int(d.target))
		"merchant": _merchant(d)
		"pet_window": _pet_window(d)
		"visual_effect": _visual_effect(d)
		"model_change": _model_change(d)
		"riding": _riding(d)
		"raid":                                             # the companion raid window (/raid 40, /raid 80)
			if viewer and viewer.ui:
				viewer.ui.raid_packet(d)
		"max_speed":                                       # your speed in percent of the base run speed (encumbrance,
			if viewer and viewer.player:                     # buffs, snares - the server's, as the old client used it)
				_apply_max_speed(int(d.percent))
		"detail":
			if Server.take_detail(d):                        # an item's hover text (kept for the hover box)
				return
			if viewer and viewer.ui:
				if String(d.caption).to_upper().begins_with("QUEST GUIDE"):   # the guide pages: their own window
					viewer.ui.show_server_guide(d.lines)
				else:
					viewer.ui.show_lines(String(d.caption), d.lines)
		"trainer":
			if viewer and viewer.ui and viewer.ui.trainer and not viewer.ui.trainer.visible:
				viewer.ui.trainer.open()
		"dialog": _dialog(d)
		"sound_effect": _sound_effect(d)
		"door_state": _door_state(d)
		"change_target": _change_target(int(d.oid))
		"siege_window", "siege_close": _siege_window(kind, d)
		"siege_anim": _siege_anim(d)
		"warmap_keeps", "warmap_fights":
			if viewer and viewer.ui and viewer.ui.warmap:
				viewer.ui.warmap.server_update(kind, d)


## The server's SoundEffect: a client sound by its cc_sounds id, as the old client played it (owner 2026-10-14: no
## sound when a quest was taken or done - the server sends QuestBegun 7 / QuestCompleted 11, bells, keep horns; this
## client dropped the packet). Placed (zone + x / y / z, heard within radius) or, all 0, just played.
static var _sound_rows := {}
static var _sound_streams := {}


func _sound_effect(d: Dictionary) -> void:
	if _sound_rows.is_empty():
		var t = JSON.parse_string(FileAccess.get_file_as_string("res://content/sounds/sounds.json"))
		_sound_rows = t.get("sounds", {}) if t is Dictionary else {"_": {}}
	var row: Dictionary = _sound_rows.get(str(int(d.id)), {})
	if row.is_empty():
		push_warning("server sound %d: not in sounds.json (pipeline/build_sounds.py --events)" % int(d.id))
		return
	var file := String(row.file)
	if not _sound_streams.has(file):
		_sound_streams[file] = AudioStreamWAV.load_from_file(ProjectSettings.globalize_path("res://content/sounds".path_join(file)))
	var gain := randf_range(float(row.vol[0]), float(row.vol[1]))
	var placed := int(d.zone) > 0 and int(d.radius) > 0
	var p: Node
	if placed and player:
		var at := _zone_pos(int(d.zone), int(d.x), int(d.y), int(d.z))
		if player.global_position.distance_to(at) > float(d.radius) * 0.025:
			return                                               # out of its radius
		var p3 := AudioStreamPlayer3D.new()
		p3.attenuation_model = AudioStreamPlayer3D.ATTENUATION_DISABLED
		p3.position = at
		p = p3
	else:
		p = AudioStreamPlayer.new()
	p.stream = _sound_streams[file]
	p.bus = "Ambient"
	p.pitch_scale = randf_range(float(row.rate[0]), float(row.rate[1]))
	p.volume_db = linear_to_db(maxf(gain, 0.001))
	add_child(p)
	p.finished.connect(p.queue_free)
	p.play()


# ---------------------------------------------------------------- the living

func _model_info(model: int) -> Dictionary:
	var info: Dictionary = models.get(str(model), {})
	if info.is_empty() and not WeaponModels.info(model).is_empty():
		# the server's siege weapons (GameSiegeRam / Catapult / Trebuchet / Ballista / Cauldron - NPCs whose model is an
		# objects.csv row, the client's Heavy Siege Ram 2602, Ranged Catapult 2598, Mounted Trebuchet 2606 ...): drawn
		# with the object's own model (owner 2026-10-14: keep sieges in the new client)
		return {"object_model": model, "name": String(WeaponModels.info(model).get("name", ""))}
	if info.has("race") and info.race == null:                 # player-race models without a figure race in the table
		var nm := String(info.get("name", "")).strip_edges().to_lower()
		for w in RACE_WORDS:
			if nm.begins_with(w):
				info = info.duplicate()
				info["race"] = "%s_%s" % [RACE_WORDS[w], "f" if nm.contains("female") else "m"]
				break
	return info


func _add_npc(d: Dictionary) -> void:
	var oid := int(d.oid)
	_mark_seen(oid)
	# the server sends a living again when you target it (PlayerTargetHandler -> UpdateObjectForPlayer) and when it
	# changes: the same model is updated in place - the view, your target and its name stay
	var old: NpcState = by_oid.get(oid)
	if old and String(old.spawn.get("model", "")) == str(int(d.model)):
		_update_npc(old, d)
		return
	if old:
		_remove(oid, false)
	var f := int(d.flags)
	var f2 := int(d.flags2)
	# the packet's flags -> the database's eFlags (what Npc / NamePlates read)
	var flags := 0
	if f & 0x01: flags |= 0x01                                  # ghost
	if f2 & 0x04: flags |= 0x02                                 # stealthed
	if f2 & 0x02: flags |= 0x04                                 # don't show the name
	if f2 & 0x01: flags |= 0x08                                 # can't target
	if f & 0x10: flags |= 0x10                                  # peace
	if f & 0x20: flags |= 0x20                                  # flying
	if f & 0x04: flags |= 0x40                                  # torch
	var p := scene_pos(float(d.x), float(d.y), float(d.z))
	var spawn := {"id": "srv%d" % oid, "oid": oid, "name": String(d.name), "guild": String(d.guild),
			"realm": f >> 6, "flags": flags, "level": int(d.level) & 0x7F, "size": int(d.size), "model": str(int(d.model)),
			"heading": int(d.heading), "pos": [p.x, p.y, p.z], "equipment": "srv%d" % oid, "aggro_level": 0,
			"aggro_range": 0, "roam": 0, "pet": (f2 & 0x80) != 0, "temp": true}
	spawn["quest"] = _quest_indicator(d)
	var st := NpcState.new(states.size(), spawn, _model_info(int(d.model) & 0x7FFF))
	st.level = int(d.level) & 0x7F
	st.yaw = Server.yaw_of(int(d.heading))
	st.stealthed = false                                        # (the server only sends what you can see)
	st.wait = 1e9                                               # (no roaming of its own)
	states.append(st)
	by_oid[oid] = st
	st.seen_at = Time.get_ticks_msec()
	_mover[st] = {"speed": float(int(d.speed)), "dest": null, "target": 0, "flying": (flags & 0x20) != 0, "sy": p.y}
	_ground(st)
	_unpark(oid, st)


## Livings that just left your view: the server removes them at its visibility edge (~45 m) and sends them again
## when they come back - a bot pacing around that edge had its figure built from scratch each time (15-25 ms a
## build, the stutter near bots even out of combat - owner 2026-10-13). Their built views wait here hidden a while
## and are taken back when the same living returns with the same model, size and flags (new gear: EquipmentUpdate
## dresses it again as before).
const PARK_S := 60.0
const PARK_MAX := 64
var _parked := {}                             # object id -> [view, model, size, flags, name, guild, msec parked]


func _park(oid: int, st: NpcState) -> void:
	var v := st.view as Npc
	var was: Array = _parked.get(oid, [])
	if not was.is_empty() and is_instance_valid(was[0]) and was[0] != v:
		(was[0] as Node).queue_free()
	v.visible = false
	v.process_mode = Node.PROCESS_MODE_DISABLED              # (its click box leaves the physics world with it)
	_parked[oid] = [v, String(st.spawn.get("model", "")), int(st.spawn.get("size", 50)), int(st.spawn.get("flags", 0)),
			String(st.spawn.get("name", "")), String(st.spawn.get("guild", "")), Time.get_ticks_msec()]
	while _parked.size() > PARK_MAX:                         # the longest parked goes
		var oldest := -1
		for k in _parked:
			if oldest < 0 or int(_parked[k][6]) < int(_parked[oldest][6]):
				oldest = k
		_drop_parked(oldest)


func _unpark(oid: int, st: NpcState) -> void:
	var p: Array = _parked.get(oid, [])
	if p.is_empty():
		return
	_parked.erase(oid)
	var v := p[0] as Npc
	if not is_instance_valid(v):
		return
	if String(p[1]) != String(st.spawn.get("model", "")) or int(p[2]) != int(st.spawn.get("size", 50)) 			or int(p[3]) != int(st.spawn.get("flags", 0)) or v.info != st.info:
		v.queue_free()
		return
	v.rebind(st)
	if String(p[4]) != String(st.spawn.get("name", "")) or String(p[5]) != String(st.spawn.get("guild", "")):
		for l in v.get_meta("plate", []):                       # its name plate shows the new name
			(l as Node).queue_free()
		v.set_meta("plate", [])
		v.set_meta("plate_shown", false)
	st.view = v
	active[st.index] = v


func _drop_parked(oid: int) -> void:
	var p: Array = _parked.get(oid, [])
	_parked.erase(oid)
	if not p.is_empty() and is_instance_valid(p[0]):
		(p[0] as Node).queue_free()


## The NPC's quest indicator for you (NPCCreate flags, as eQuestIndicator: 1 available, 2 finish, 4 lesson, 8 lore,
## 16 pending) - QuestMarkers draws its ground circle and map mark.
static func _quest_indicator(d: Dictionary) -> int:
	var f2 := int(d.get("flags2", 0))
	var f3 := int(d.get("flags3", 0))
	if f2 & 0x08: return 1
	if f2 & 0x10: return 2
	if f3 & 0x01: return 4
	if f3 & 0x02: return 8
	if f3 & 0x20: return 16
	return 0


## VisualEffect (0x4C): subtype 7 = an NPC's quest indicator changed (SendNPCsQuestEffect).
func _visual_effect(d: Dictionary) -> void:
	if int(d.effect) != 7:
		return
	var st: NpcState = by_oid.get(int(d.oid))
	if st:
		st.spawn["quest"] = int(d.value)
		quest_marks_changed.emit()


signal quest_marks_changed


func _update_npc(st: NpcState, d: Dictionary) -> void:
	var f := int(d.flags)
	var renamed := String(st.spawn.name) != String(d.name) or String(st.spawn.get("guild", "")) != String(d.guild)
	st.spawn["name"] = String(d.name)
	st.spawn["guild"] = String(d.guild)
	st.spawn["realm"] = f >> 6
	st.spawn["level"] = int(d.level) & 0x7F
	st.level = int(d.level) & 0x7F
	st.spawn["quest"] = _quest_indicator(d)
	var p := scene_pos(float(d.x), float(d.y), float(d.z))
	if st.pos.distance_to(p) > SNAP_M:
		st.pos = p
		if _mover.has(st):
			_mover[st]["sy"] = p.y
		_ground(st)
	if renamed and st.view and is_instance_valid(st.view):        # its name plate shows the new name
		for l in st.view.get_meta("plate", []):
			(l as Node).queue_free()
		st.view.set_meta("plate", [])
		st.view.set_meta("plate_shown", false)


func _move(d: Dictionary) -> void:
	if door_oids.has(int(d.oid)):                                  # a door's health (keep doors under attack)
		var info: Dictionary = doors.get(door_oids[int(d.oid)], {})
		info["health"] = int(d.health)
		if target_door == int(d.oid):
			PlayerData.target["health"] = float(d.health) / 100.0
			PlayerData.target_changed.emit()
		return
	var st: NpcState = by_oid.get(int(d.oid))
	if st == null:
		return
	var p := _zone_pos(int(d.zone), int(d.x), int(d.y), int(d.z))
	if p == Vector3.INF:
		return                                                  # (not seen: a place we can't draw keeps nothing alive)
	st.seen_at = Time.get_ticks_msec()
	var mv: Dictionary = _mover.get(st, {})
	mv["srv_pos"] = p                                           # where the server has it (a rider: checked by _seat_riders)
	mv["srv_at"] = st.seen_at
	mv["flying"] = (int(d.flags) & 0x20) != 0
	mv["water"] = (int(d.flags) & 0x10) != 0                    # the server's "underwater" (npc.IsUnderwater)
	mv["sy"] = p.y                                              # the server's Z: every height is found from it (_ground)
	mv["speed"] = float(int(d.speed))                           # (before _ground: a mover goes on the ground)
	_mover[st] = mv
	if st.pos.distance_to(p) > SNAP_M or float(d.speed) == 0.0:
		st.pos = p
	else:
		st.pos = st.pos.lerp(p, 0.5)                            # close: ease into the server's place
	_ground(st)
	st.yaw = Server.yaw_of(int(d.heading))
	mv["target"] = int(d.target)
	mv["dest"] = null
	if int(d.tx) != 0 or int(d.ty) != 0:
		var dp := _zone_pos(int(d.tzone), int(d.tx), int(d.ty), int(d.tz))
		if dp != Vector3.INF:
			mv["dest"] = dp
	var hp := int(d.health)
	_set_health(st, hp)
	if int(d.oid) == pet_oid and not PlayerData.pet.is_empty():   # your pet's health on the pet window
		PlayerData.pet["health"] = st.health
		PlayerData.pet_changed.emit()


func _set_health(st: NpcState, pct: int) -> void:
	var was := st.alive
	st.health = pct / 100.0
	st.alive = pct > 0
	if was and not st.alive:
		st.mode = NpcState.Mode.DEAD
		st.corpse_left = 1e9                                    # the body stays until the server removes it
		if st.view:
			(st.view as Npc).play_death(true)
	elif not was and st.alive:
		st.mode = NpcState.Mode.IDLE


func _ground(st: NpcState) -> void:
	var mv: Dictionary = _mover.get(st, {})
	if bool(mv.get("flying", false)):
		return
	# Every height is found from the server's own Z for it (its last update), never from where it is drawn now
	# (owner 2026-10-14: bots stood on each other and up in a pine tree): the floor pick looks 1.2 m above the height
	# it starts from, so starting from the drawn height let a walker that met a tree, a fixture or a rock ratchet up it
	# 1.2 m at a time, tick after tick - the server's next update only pulled it halfway back.
	var ref := float(mv.get("sy", st.pos.y))
	var at := Vector3(st.pos.x, ref, st.pos.z)
	# in deep water (owner 2026-10-14: companion bots stood on top of the water): the server holds a swimmer at the
	# surface (AutonomousNavigationSurface) and flags it underwater; it swims there - your own swim height
	# (Player.SWIM_FLOAT) - unless a floor above the water is under it (a bridge, a pier). A creature the server keeps
	# deep down (a water beetle) stays at its own depth.
	var w := _water_at(at)
	if w > -INF and w - _grid_at(at) > Player.SWIM_DEPTH and (bool(mv.get("water", false)) or ref < w + 0.5):
		var f := floor_at(at)
		if f <= w:
			st.swimming = true
			st.pos.y = w - Player.SWIM_FLOAT if ref > w - 1.5 else ref
			return
	st.swimming = false
	# the drawn surface under the server's Z: the ground, or a building floor / porch / bridge just below it (the
	# ground alone pulled indoor NPCs down through house floors - owner 2026-10-11: merchants sunk into the floor)
	var g := floor_at(at)
	# a walker the server has far above everything under it is on the ground (owner 2026-10-15: stable masters' route
	# horses galloping at treetop height): the server moves along a path in straight lines between its points, and
	# the horse routes' points sit ~65 m apart, on the ground - over a dip the line runs up to 50 m in the air. Only a
	# mover: one standing still keeps the server's Z (an upper floor the drawn world has no floor for).
	if g > -INF and ref - g >= 4.0 and float(mv.get("speed", 0.0)) > 0.0:
		st.pos.y = g
		return
	st.pos.y = g if g > -INF and absf(g - ref) < 4.0 else ref  # the server's Z, on the drawn ground where they agree


## kind: the server's RemoveObject type - 0 a dead NPC (its body stays a while: Npc.make_corpse), 1 a living NPC,
## 2 a player.
func _remove(oid: int, park := true, kind := 1) -> void:
	if door_oids.has(oid):
		doors.erase(door_oids[oid])
		door_oids.erase(oid)
		if target_door == oid:
			target_door = 0
			PlayerData.set_target({})
		return
	if objects.has(oid):
		var o: Node3D = objects[oid]
		objects.erase(oid)
		if is_instance_valid(o):
			o.queue_free()
		return
	var st: NpcState = by_oid.get(oid)
	if st == null:
		return
	if kind == 0 and st.alive:
		_set_health(st, 0)                                     # removed dead without a health update first (a pet's,
															# a spell's, another's kill): dead all the same - attack
															# mode on it ends (owner 2026-10-14)
	by_oid.erase(oid)
	_mover.erase(st)
	if st.view:
		if st.view == target:
			clear_target()
		if kind == 0 and st.view is Npc and is_instance_valid(st.view):
			(st.view as Npc).make_corpse()                    # (frees itself once it has sunk)
		elif park and st.alive and is_instance_valid(st.view):
			_park(oid, st)
		else:
			st.view.queue_free()
		st.view = null
	states.erase(st)
	var views := {}
	for i in states.size():                                     # indices are the views' keys
		var s: NpcState = states[i]
		s.index = i
		if s.view:
			views[i] = s.view
	active = views


func _equip(d: Dictionary) -> void:
	var oid := int(d.oid)
	var rows := []
	for it in d.get("items", []):
		rows.append({"slot": int(it.slot), "model": int(it.model), "color": int(it.get("color", 0)),
				"effect": int(it.get("effect", 0))})
	var st: NpcState = by_oid.get(oid)
	var gear := {"hood": (int(d.get("hood", 0)) & 1) != 0, "cloak_hidden": (int(d.get("hidden", 0)) & 1) != 0,
			"helm_hidden": (int(d.get("hidden", 0)) & 2) != 0}
	# the same gear again (the server sends it with every create - a living coming back into view): nothing to redo
	var same: bool = data.equipment.get("srv%d" % oid) == rows and (st == null or st.spawn.get("gear") == gear)
	data.equipment["srv%d" % oid] = rows
	if st:                                                         # its cloak hood and hidden cloak / helm (/hood ...)
		st.spawn["gear"] = gear
	var ws := int(d.get("weapon_slots", 0xFF))
	if same:
		# the same gear, maybe another weapon set active (a bow drawn): only the weapons hang again
		if st and int(st.spawn.get("weapon_slots", -1)) != ws:
			if st.view and st.view.has_method("set_weapon_slots"):
				st.view.set_weapon_slots(ws)
			else:
				st.spawn["weapon_slots"] = ws
		return
	if st:
		st.spawn["weapon_slots"] = ws
	if st and st.view:                                          # dressed again with the new gear
		if st.view == target:
			target = null
		active.erase(st.index)
		st.view.queue_free()
		st.view = null


## ModelChange (0xDB): a living takes another model - a necromancer's shade (822), a berserker's Vendo form, illusions,
## a companion's or bot's too (owner 2026-10-11: companion necromancers stayed human). Its view is made again with
## the new model; yours morphs (Player.morph).
func _model_change(d: Dictionary) -> void:
	var oid := int(d.oid)
	var info := _model_info(int(d.model) & 0x7FFF)
	if oid == Server.me_oid:
		if viewer and viewer.player:
			viewer.player.morph(info)
		return
	var st: NpcState = by_oid.get(oid)
	if st == null or String(st.spawn.get("model", "")) == str(int(d.model)):
		return
	st.spawn["model"] = str(int(d.model))
	if int(d.get("size", 0)) > 0:
		st.spawn["size"] = int(d.size)
	st.info = info
	if st.view:                                                  # drawn again with the new model
		var was_target: bool = st.view == target
		if was_target:
			target = null
		active.erase(st.index)
		st.view.queue_free()
		st.view = null


func _death(oid: int) -> void:
	if oid == Server.me_oid:
		if viewer and viewer.player:
			if not viewer.player.dead and viewer.player.sounds:
				viewer.player.sounds.event("die")
			viewer.player.die()
			if viewer.ui:
				viewer.ui.show_release(true)                    # the death window (RELEASE sends /release)
		return
	var st: NpcState = by_oid.get(oid)
	if st:
		_set_health(st, 0)


## The mover: between the server's updates each moving living walks on toward its destination (or along its heading)
## at the speed the server gave - no thinking of its own.
## Livings the server no longer shows (owner 2026-10-14: companions dismissed long ago still stood where they were left,
## client-side dummies after a death, a release or a teleport): the server re-sends every NPC in your range every
## world_npc_update_interval (5 s) and simply stops once one is out of range (6,000 units) or gone - it sends no
## RemoveObject then (ClientService.UpdateNpcs). The old client dropped what wasn't updated any more; so does this:
## no word of it for STALE_MS and it goes.
const STALE_MS := 15000
var _stale_check := 0.0


func _mark_seen(oid: int) -> void:
	var st: NpcState = by_oid.get(oid)
	if st:
		st.seen_at = Time.get_ticks_msec()


func _drop_stale(delta: float) -> void:
	_stale_check -= delta
	if _stale_check > 0.0:
		return
	_stale_check = 2.0
	var now := Time.get_ticks_msec()
	var gone := []
	for oid in by_oid:
		var st: NpcState = by_oid[oid]
		if st.alive and now - st.seen_at > STALE_MS and int(oid) != pet_oid:
			gone.append(int(oid))
	for oid in gone:
		_remove(oid, true, 1)


func _physics_body(delta: float) -> void:
	_drop_stale(delta)
	_sweep_gathers()
	var now_ms := Time.get_ticks_msec()
	for st in _mover:
		var s: NpcState = st
		var mv: Dictionary = _mover[st]
		var speed := float(mv.speed)
		if not s.alive:
			continue
		if s.ride_clip != "":
			continue                                            # riding: the steed carries it (_seat_riders)
		if speed <= 0.0:
			s.mode = NpcState.Mode.FIGHT if int(mv.target) != 0 or now_ms < s.combat_until else NpcState.Mode.IDLE
			s.running = false
			s.fighting = int(mv.target) != 0 or now_ms < s.combat_until
			continue
		var step := speed * 0.025 * delta
		var dest = mv.dest
		if dest is Vector3:
			var to: Vector3 = dest - s.pos
			to.y = 0.0
			if to.length() <= step:
				s.pos = Vector3(dest.x, s.pos.y, dest.z)
				mv["speed"] = 0.0
			else:
				s.pos += to.normalized() * step
				s.yaw = atan2(to.x, to.z)
		else:
			s.pos += Vector3(sin(s.yaw), 0.0, cos(s.yaw)) * step
		_ground(s)
		s.mode = NpcState.Mode.WALK
		s.running = speed >= RUN_UNITS
		s.fighting = int(mv.target) != 0 or now_ms < s.combat_until   # chasing its target: weapons stay drawn
	_seat_riders()


## The old server's con table (npcs.json "con"); without it the level difference.
func con_level(player_level: int, npc_level: int) -> int:
	if _con.is_empty() or player_level < 0 or player_level >= _con.size():
		return clampi(npc_level - player_level, -3, 3)
	var row: Array = _con[player_level]
	return int(row[npc_level]) if npc_level >= 0 and npc_level < row.size() else 3


# ---------------------------------------------------------------- you and the server

## Targeting on the server, as the old client did: "You target [X]." here, the examine line from the server (the
## examine bit), the in-view bits so it doesn't answer "Target is not in view."
func select(n: Npc) -> void:
	if n == null or not n.state.alive:
		return
	target = n
	var nm := String(n.spawn.name)
	var lower := nm.length() > 0 and nm[0] == nm[0].to_lower()
	if not _server_chose_target:                           # the server already said "You target ..."
		PlayerData.message.emit(("You target the [%s]." % nm) if lower else ("You target [%s]." % nm), "system")
	PlayerData.set_target({"name": nm, "level": n.state.level, "con_color": n.con_color(PlayerData.level),
			"health": n.state.health, "guild": String(n.spawn.get("guild", ""))})
	if Server.client:
		Server.client.call("Target", int(n.spawn.get("oid", 0)), 0x8000 | 0x6000)


func clear_target() -> void:
	target_door = 0
	super.clear_target()
	if Server.client and Server.playing:
		Server.client.call("Target", 0, 0)


func interact(n: Npc) -> void:
	if n == null or Server.client == null:
		return
	var r := Server.to_region(_current_zone(), player.global_position)
	Server.client.call("Interact", int(n.spawn.get("oid", 0)), int(r.x), int(r.y))


func update_views(max_build: int) -> void:
	super.update_views(max_build)
	var now := Time.get_ticks_msec()
	for oid in _parked.keys():                                   # parked too long: let go
		if now - int(_parked[oid][6]) > PARK_S * 1000.0:
			_drop_parked(oid)
	if target and is_instance_valid(target):
		PlayerData.target["health"] = target.state.health


func _message(d: Dictionary) -> void:
	var t := int(d.type)
	if t == 0x64:                                       # CT_SocialInterface: the social window's data, not chat
		_social(String(d.text))
		return
	var kind := String(CHAT_KINDS.get(t, "system"))
	var text := String(d.text)
	if bool(d.get("popup", false)) and viewer and viewer.ui and viewer.ui.npc_dialog:
		# an NPC talking to you (SayTo -> the popup window): its words in the NPC window, [keywords] clickable
		var who := String(PlayerData.target.get("name", ""))
		viewer.ui.npc_dialog.say("srv%d" % _target_oid(), who, text)
		PlayerData.message.emit(text, "npc")
		return
	if t >= 0xC8 and t <= 0xCB:                                 # screen centre (zone names, warnings)
		if viewer and viewer.ui and viewer.ui.has_method("center_message"):
			viewer.ui.center_message(text, t == 0xC9 or t == 0xCB)      # (the Smaller pair: area descriptions)
		if t < 0xCA:
			return
		kind = "system"
	PlayerData.message.emit(text, kind)


## The server's social-window lines (CT_SocialInterface - the old client filled its social window with them; they were
## printed raw: 'N,0,0,1 day,"The forces of Hibernia have captured Caer Benowyc!"'): /friend window's friends
## ("TF" clears, "F,place,name,level,class,"zone or last played"") and /news ("N,type,place,when,"text"") as lists in
## the information window; the guild window's lines are left out (no guild window).
var _social_title := ""
var _social_lines: Array = []
var _social_due := false


func _social(text: String) -> void:
	var f := _csv(text)
	if f.is_empty():
		return
	match String(f[0]):
		"TF":
			_social_title = "FRIENDS"
			_social_lines = []
		"F":
			if f.size() >= 6:
				_social_title = "FRIENDS"
				var cls := Server.class_name_of(int(f[4]))
				_social_lines.append("%s  (level %s %s)  %s" % [f[2], f[3], cls, f[5]])
		"N":
			if f.size() >= 5:
				if _social_title != "NEWS":
					_social_title = "NEWS"
					_social_lines = []
				_social_lines.append("%s - %s ago" % [f[4], f[3]])
		_:
			return
	if not _social_due:                                  # the lines come in a burst: shown once it has passed
		_social_due = true
		get_tree().create_timer(0.4).timeout.connect(func():
			_social_due = false
			if viewer and viewer.ui:
				viewer.ui.show_lines(_social_title, _social_lines if not _social_lines.is_empty() else ["(none)"])
			if _social_title == "NEWS":
				_social_title = "")


## Comma-separated fields, "quoted" ones whole.
static func _csv(text: String) -> Array:
	var out := []
	var cur := ""
	var quoted := false
	for ch in text:
		if ch == "\"":
			quoted = not quoted
		elif ch == "," and not quoted:
			out.append(cur)
			cur = ""
		else:
			cur += ch
	out.append(cur)
	return out


func _status(d: Dictionary) -> void:
	# (no pain cry here: hurts come with the server's CombatAnimation - blows, spells, DoT ticks - _combat_sounds. A
	# health update also comes from gear and buffs changing your Constitution - owner 2026-10-15: a cry on equipping)
	PlayerData.max_hp = maxi(1, int(d.max_health))
	PlayerData.hp = int(d.health)
	PlayerData.health = float(d.health_pct) / 100.0
	PlayerData.max_power = int(d.max_mana)
	PlayerData.power_pts = int(d.mana)
	PlayerData.power = float(d.mana_pct) / 100.0
	PlayerData.end_pts = int(d.endurance)
	PlayerData.endurance = float(d.endurance_pct) / 100.0
	Server.max_conc = int(d.get("max_conc", 0))
	Server.conc_left = int(d.get("conc", 0))
	# the server's word on sitting (0x02): /sit, /rest, /quit's countdown sit you there; a sit it refused stands you
	var sit := (int(d.get("sitting", 0)) & 0x02) != 0
	if viewer and viewer.player and viewer.player.sitting != sit and not viewer.player.dead 			and Time.get_ticks_msec() - int(viewer.sit_changed_at) > 1500:
		viewer.player.sit(sit)
	PlayerData.changed.emit()


func _view_of(oid: int) -> Node:
	if oid == Server.me_oid and viewer:
		return viewer.player
	var st: NpcState = by_oid.get(oid)
	return st.view if st else null


func _view_call(oid: int, method: String) -> void:
	var v := _view_of(oid)
	if v and v.has_method(method):
		v.call(method)


const SPELL_RESULT := 0x14                     # CombatAnimation's result for spell damage (SpellHandler.DamageTarget)


const BOW_PREPARE := 0x3E80                     # CombatAnimation's style for a bow drawn (PacketLib186.BowPrepare)
const BOW_SHOOT := 0x3E83                       # ... and loosed (BowShoot; the stance byte = the arrow's flight time)
const ONE_DUAL := 0x3E81                        # ... a dual wielder's left weapon blow (OneDualWeaponHit)
const BOTH_DUAL := 0x3E82                       # ... both weapons (BothDualWeaponHit)


func _combat(d: Dictionary) -> void:
	var a := _view_of(int(d.attacker))
	# a bow drawn / loosed (AttackAction's ranged attack): the archer's bow clips, not a melee swing (owner 2026-10-15:
	# the bone archers swung a sword at range); the arrow's hit (a bow as the weapon) swings nothing either
	var bow_anim := int(d.style) == BOW_PREPARE or int(d.style) == BOW_SHOOT
	var ranged := int(d.weapon) > 0 and int(WeaponModels.info(int(d.weapon)).get("stance", 0)) in [5, 6, 8]
	if bow_anim:
		var shoot := int(d.style) == BOW_SHOOT
		if a is Npc:
			if shoot:
				(a as Npc).bow_release()
			else:
				(a as Npc).bow_draw()
		elif a is Player and int(d.attacker) == Server.me_oid:
			if shoot:
				(a as Player).bow_release(true)
			else:
				(a as Player).bow_draw()
		if not shoot:
			return                                     # (no target, nothing hit yet)
	# a dual wielder's blow (WeaponAction: OneDualWeaponHit - the left weapon -, BothDualWeaponHit): canims Att Left /
	# Att Dual (owner 2026-10-15: "all clips need to be proper ... so nothing is incorrect or using the wrong clip")
	var hand: String = {ONE_DUAL: "left", BOTH_DUAL: "dual"}.get(int(d.style), "")
	var styled := not bow_anim and hand == "" and int(d.style) > 0 and int(d.result) == 11      # a styled hit: its style animation (and chain swing)
	var style_anim := _style_anim(int(d.style)) if styled else 0
	# spell damage - a damage over time's tick, a bolt landing - only hurts the target: the caster doesn't swing
	# (owner 2026-10-14: "when a damage over time spell does damage ... the caster swings his hand like a melee
	# attack even at range")
	var spell := (int(d.result) & 0x7F) == SPELL_RESULT
	# its weapons out while it fights (owner 2026-10-15: a gamebot bard used its styles with the drum still in its hand
	# - its position packets carry no target, so it never counted as fighting)
	var ast: NpcState = by_oid.get(int(d.attacker))
	if ast and not spell:
		ast.combat_until = Time.get_ticks_msec() + 6000
		ast.fighting = true
		if a is Npc and not bow_anim and not ranged:
			(a as Npc).show_weapon_for(int(d.weapon))
	if spell or bow_anim or ranged:
		pass
	elif a is Npc:
		if styled:
			(a as Npc).play_style(style_anim)
		else:
			(a as Npc).play_attack(hand)
	elif a is Player and int(d.attacker) == Server.me_oid:
		if not styled or (a as Player).play_style(style_anim) == "":
			(a as Player).swing((a as Player).weapon_stance(), hand)
	var v := _view_of(int(d.defender))
	var result := int(d.result)
	var kind: String = {1: "parry", 2: "block", 3: "evade"}.get(result, "")
	_combat_sounds(a, v, d, styled)
	if v is Npc:
		if kind != "":
			(v as Npc).play_defend(kind)
		elif result >= 10:
			(v as Npc).flinch()
	elif v is Player:
		if kind != "":
			(v as Player).defend(kind)
		elif result >= 10:
			(v as Player).flinch()
	var st: NpcState = by_oid.get(int(d.defender))
	if st and int(d.health) <= 100:
		_set_health(st, int(d.health))
	if target and is_instance_valid(target) and target.state == st:
		PlayerData.target["health"] = st.health
		PlayerData.target_changed.emit()


## The blow's sounds, the client's sheets as offline combat plays them (owner 2026-10-13: "no damage taken for
## players or monsters, no weapon attack sounds, no death sounds, no monster sounds"): the attacker's swing - its
## weapon's sound set (cc_weapons 'use', 'style_use' for a style) or a monster's attack cry (cc_creatures) - then
## on the defender the weapon striking it (hit_light / hit_medium by the share of health it took, style_hit) and
## its pain cry, a parried / blocked clang, an evade. Deaths cry out where the death is seen (_set_health, _death).
const WEAPONLESS := 19                          # cc_weapons.csv: a creature's bare attacks (Combat.WEAPONLESS)


func _combat_sounds(a: Node, v: Node, d: Dictionary, styled: bool) -> void:
	var ws := int(WeaponModels.info(int(d.weapon)).get("sound_set", 0)) if int(d.weapon) > 0 else 0
	var a_snd := _sounds_of(a) if (int(d.result) & 0x7F) != SPELL_RESULT else null   # (a spell: its own sounds)
	if a_snd:
		if ws > 0:
			a_snd.weapon(ws, "style_use" if styled else "use")
		else:
			a_snd.event("attack")
	var v_snd := _sounds_of(v)
	if v_snd == null:
		return
	var result := int(d.result)
	if (result & 0x7F) == SPELL_RESULT:                    # spell damage (a bolt, a DoT's tick): the target's pain only
		var sst: NpcState = by_oid.get(int(d.defender))
		var was: float = sst.health if sst else (PlayerData.health if v is Player else 1.0)
		if int(d.health) > 0:
			_pain(v, "pain_medium" if was - float(int(d.health)) / 100.0 >= 0.1 else "pain_light")
		return
	match result:
		1, 2:                                            # parried / blocked: by the defender's weapon / shield
			var dws := int(WeaponModels.info(int(d.shield)).get("sound_set", 0)) if int(d.shield) > 0 else 0
			v_snd.weapon(dws if dws > 0 else WEAPONLESS, "parried" if result == 1 else "blocked")
		3:
			v_snd.event("evade")
		10, 11:
			var st: NpcState = by_oid.get(int(d.defender))
			var before: float = st.health if st else (PlayerData.health if v is Player else 1.0)
			var after := float(int(d.health)) / 100.0
			var heavy := before - after >= 0.1
			v_snd.weapon(ws if ws > 0 else WEAPONLESS, "style_hit" if result == 11 else ("hit_medium" if heavy else "hit_light"))
			if int(d.health) > 0:
				_pain(v, "pain_heavy" if result == 11 else ("pain_medium" if heavy else "pain_light"))


## A pain cry, at most one a PAIN_MS per character (a blow and the health update after it are one hurt).
const PAIN_MS := 700


func _pain(v: Node, key: String) -> void:
	var snd := _sounds_of(v)
	if snd == null or not is_instance_valid(v):
		return
	var now := Time.get_ticks_msec()
	if now - int(v.get_meta("pain_at", -100000)) < PAIN_MS:
		return
	v.set_meta("pain_at", now)
	snd.event(key)


# ---------------------------------------------------------------- spells (the client's effects: SpellFx)
# SpellCastAnimation / SpellEffectAnimation carry the spell's client effect (spells.csv): the caster's casting style
# and hand glows while it casts, then the cast effect, the bolt flying, the hit (or resist) on the target.

var _gathers := {}                           # caster object id -> [client effect, the hand-glow handles]
var _burst := {}                             # "caster:effect" -> when its last effect packet came (msec)
const BURST_MS := 400
const RESTORE_QUIET_MS := 3000               # after PlayerInit: your restored buffs' effects are not shown (_spell_effect)


func _sounds_of(v: Node) -> CharacterSounds:
	if v is Npc:
		return (v as Npc).sounds
	if v is Player:
		return v.get("sounds")
	return null


func _cast(d: Dictionary) -> void:
	var oid := int(d.caster)
	var v := _view_of(oid)
	var ce := int(d.spell)
	_late_cast.erase(oid)
	if v == null:
		if by_oid.has(oid) and int(d.get("time", 0)) > 0:
			_cast_late(oid, ce, int(d.time) / 10.0)
		return
	_interrupt(oid, false)
	if int(d.get("time", 0)) == 0:
		# an instant (the server sends a harmful instant's cast at 0 s - SpellHandler): the old client showed no casting
		# motion and no gathering glow, only the spell on its target (owner 2026-10-15: the Sluaghbinder's instant
		# DoTs had a little cast animation and an effect under the character) - _spell_effect lands it plainly
		_instant[oid] = [ce, Time.get_ticks_msec()]
		return
	_cast_begin(oid, v, ce, int(d.get("time", 0)) / 10.0)          # cast time in tenths of a second


func _cast_begin(oid: int, v: Node, ce: int, seconds: float) -> void:
	var anims: Array = SpellFx.effect(ce).get("anims", [])
	if v is Player:
		(v as Player).cast_start(anims, seconds)
	elif v is Npc:
		(v as Npc).cast_start(anims, seconds)
	_gathers[oid] = [ce, SpellFx.begin(ce, v as Node3D, _sounds_of(v)),
			Time.get_ticks_msec() + int(seconds * 1000.0) + GATHER_GRACE_MS]


## Casts the server ends without a word (owner 2026-10-15: a companion's hands glowed on forever once the monster it
## was casting at died, or once it broke off the cast to follow you - no spell effect, no interrupt): the hand glow
## and the casting pose go GATHER_GRACE_MS past the cast's time, or the moment the caster moves.
const GATHER_GRACE_MS := 1500


func _sweep_gathers() -> void:
	var now := Time.get_ticks_msec()
	var done := []
	for oid in _gathers:
		var g: Array = _gathers[oid]
		var st: NpcState = by_oid.get(oid)
		var moving := st != null and float((_mover.get(st, {}) as Dictionary).get("speed", 0.0)) > 0.0
		if moving or now > int(g[2]):
			done.append(oid)
	for oid in done:
		var g: Array = _gathers[oid]
		_gathers.erase(oid)
		SpellFx.drop(g[1])
		var v := _view_of(oid)
		if v is Npc:
			(v as Npc).cast_end(false)


## A cast by a living whose view isn't built yet (owner 2026-10-15: a "/spawn necromancer" companion casts its Call
## Minor Zombie Servant the moment it appears, while its figure and gear still load on a worker - NpcManager._prepared,
## up to PREP_GIVE_UP_MS - and the cast showed no animation at all): it starts once the view is there, for the time
## left. A newer cast, the spell landing or an interrupt in between drops it.
var _late_cast := {}                        # caster oid -> msec its cast packet came


func _cast_late(oid: int, ce: int, seconds: float) -> void:
	var at := Time.get_ticks_msec()
	_late_cast[oid] = at
	var v := await _view_soon(oid, NpcManager.PREP_GIVE_UP_MS + 1500)
	if v == null or int(_late_cast.get(oid, -1)) != at:
		return
	_late_cast.erase(oid)
	var left := seconds - (Time.get_ticks_msec() - at) / 1000.0
	if left > 0.3:
		_cast_begin(oid, v, ce, left)


var _instant := {}                          # caster oid -> [client effect, msec]: a 0 s cast packet (an instant spell)
var _revived_at := -100000                  # when you last came back to life (Revive)
const REVIVE_QUIET_MS := 5000


## Resurrection illness: on a release or a resurrection the server makes you cast it on yourself (GamePlayer
## OnRevive: CastSpell 2435 / 8181, ClientEffect 3421 "Sickening Spores", no cast packet before it). The old client
## showed no casting motion for it (owner 2026-10-15: "resurrecting at a bindstone casts a cast animation of
## resurrection illness on yourself") - only its effect on you.
func _revive_sickness(d: Dictionary, now: int) -> bool:
	return int(d.caster) == Server.me_oid and int(d.target) == Server.me_oid and now - _revived_at < REVIVE_QUIET_MS


func _spell_effect(d: Dictionary) -> void:
	var caster := _view_of(int(d.caster)) as Node3D
	var target := _view_of(int(d.target)) as Node3D
	var ce := int(d.spell)
	_late_cast.erase(int(d.caster))                              # (landed before its caster was drawn: no cast now)
	var handles: Array = []
	var g: Array = _gathers.get(int(d.caster), [])
	var was_cast := not g.is_empty()
	if was_cast:
		handles = g[1]
		_gathers.erase(int(d.caster))
	var now := Time.get_ticks_msec()
	if not was_cast and int(d.caster) == Server.me_oid and int(d.target) == Server.me_oid \
			and now - Server.init_at < RESTORE_QUIET_MS:
		# logging in: PlayerInit restarts every saved buff of yours at once (EffectHelper.RestoreAllEffects - each a
		# new StartSpell and its effect animation); the old client shows none of them (owner 2026-10-14: a shaman's
		# concentration buffs all went off at once, "almost sounds like an actual explosion")
		SpellFx.drop(handles)
		return
	var toid := int(d.target)
	if was_cast and target == null and by_oid.has(toid):
		# a summon (owner 2026-10-14: pet summons' casting animation / sound timing - bonedancer, sluaghbinder ...): the
		# server sends the spell's effect on the pet the moment it enters the world, and in the old client the pet was
		# drawn that same moment - the caster's release (end clip, cast effect, cast sound), the pet and its summon
		# effect all together. Here the pet's files load on a worker first (NpcManager._prepared), so the caster holds
		# its casting pose until the pet is drawn, then everything goes off at once.
		target = await _view_soon(toid)
		if caster and not is_instance_valid(caster):
			caster = null
	var resisted := int(d.success) == 0
	var key := "%d:%d" % [int(d.caster), ce]
	var repeat := now - int(_burst.get(key, -100000)) < BURST_MS
	var inst: Array = _instant.get(int(d.caster), [])
	var instant := not was_cast and inst.size() == 2 and int(inst[0]) == ce and now - int(inst[1]) < 3000
	if instant:
		_instant.erase(int(d.caster))
	if was_cast:
		if caster is Player:
			(caster as Player).cast_end(true)
		elif caster is Npc:
			(caster as Npc).cast_end(true)
	elif caster and not repeat and not instant and not _revive_sickness(d, now):
		# no cast before it (a song's pulse, an instant spell): the caster plays the spell's own cast motion and, for
		# an instrument song, its music (owner 2026-10-11: a minstrel's regeneration song had no animation or sound -
		# the Lute set's only sound is the instrument's, played when a cast starts)
		var anims: Array = SpellFx.effect(ce).get("anims", [])
		var clip := ""
		for c in [1, 0, 2]:
			if c < anims.size() and String(anims[c]) != "":
				clip = String(anims[c])
				break
		if clip != "" and caster.has_method("_one_shot") and not (caster is Player and (caster as Player).casting_spell):
			caster.call("_one_shot", clip)
		SpellFx.sound(_sounds_of(caster), int(SpellFx.effect(ce).get("sound_set", 0)), "gather")
	# one burst, one sound: the server sends a spell's effect once per target (a group buff on eight: eight packets
	# at once) - the old client's sound engine didn't stack the same sound eight times (owner 2026-10-11: druid buffs
	# "almost like explosions"); every target still shows its effect
	_burst[key] = now
	var quiet := int(d.get("no_sound", 0)) != 0                 # the server's "no sound" (a song's pulses)
	var cast_snd: CharacterSounds = null if repeat or quiet else _sounds_of(caster)
	var land := func():
		var t: Node3D = target
		if t == null and by_oid.has(toid):
			t = await _view_soon(toid)                     # just created (a summoned pet): its view is still loading
		if t and is_instance_valid(t):
			# the spell's landing sound from the target - or, from a target with no sound set of its own (a new pet's
			# model), from the caster: the sound is the spell's, not the model's
			var own: CharacterSounds = _sounds_of(t)
			var hit_snd: CharacterSounds = null if repeat or quiet else (own if own else cast_snd)
			SpellFx.land(ce, t, float(t.get("height")) if t is Npc else 1.8, hit_snd, resisted)
	if instant and int(SpellFx.effect(ce).get("projectile", 0)) == 0:
		SpellFx.sound(cast_snd, int(SpellFx.effect(ce).get("sound_set", 0)), "cast")   # (its sound, then the target's)
		land.call()
	elif caster and is_instance_valid(caster):
		SpellFx.fire(ce, handles, caster, cast_snd, target, land)
	else:
		SpellFx.drop(handles)
		land.call()


## A living the server just created, once its view is built (its files load on a worker first - NpcManager._prepared):
## the summon effect lands on a necromancer's servant the moment it appears (owner 2026-10-14: "the zombie just
## appears"). Null after 3 s, or when it is gone.
func _view_soon(oid: int, wait_ms := 3000) -> Node3D:
	var until := Time.get_ticks_msec() + wait_ms
	while Time.get_ticks_msec() < until and by_oid.has(oid):
		await get_tree().process_frame
		var v := _view_of(oid)
		if v:
			return v as Node3D
	return null


func _interrupt(oid: int, fizzle := true) -> void:
	_late_cast.erase(oid)
	if fizzle:                                        # (the server's InterruptAnimation: a drawn bow is lowered too)
		var bv := _view_of(oid)
		if bv is Npc:
			(bv as Npc).bow_cancel()
		elif bv is Player and oid == Server.me_oid and bool(bv.get("_bow_hold")):
			(bv as Player).bow_release(false)
	var g: Array = _gathers.get(oid, [])
	if g.is_empty():
		return
	_gathers.erase(oid)
	var v := _view_of(oid)
	if fizzle:
		SpellFx.fizzle(int(g[0]), g[1], _sounds_of(v))
		if v is Player:
			(v as Player).cast_end(false)
		elif v is Npc:
			(v as Npc).cast_end(false)
	else:
		SpellFx.drop(g[1])


func _emote(d: Dictionary) -> void:
	var v := _view_of(int(d.oid))
	if v and v.has_method("play_emote"):
		v.call("play_emote", int(d.emote))
	# the emote's own effect and sound, as the client's emotes.csv "Spell" column gives them: a level gained
	# (GamePlayer.OnLevelUp, eEmote.LvlUp 0x2A) the trifecta (owner 2026-10-15: none at 1 -> 2 on the server), /bind
	# (GamePlayer.Bind sends the realm's bind emote to everyone in view, you too) the bindstone rings and sound
	# (owner 2026-10-16) - the server only sends the emote id, the client draws the rest
	var fx := int(EMOTE_FX.get(int(d.emote), 0))
	if fx and v is Node3D:
		var snd = v.get("sounds")
		SpellFx.emote(fx, v, snd as CharacterSounds)


## emotes.csv (gamedata.mpk): emote id -> its client effect (Spell column), every row that has one
const EMOTE_FX := {18: 8001, 20: 8000, 21: 8300, 42: 8007, 43: 8005, 44: 8006, 45: 4054, 72: 8008, 73: 8010,
		74: 8006, 75: 8009}


## The server asks whether one living can see another (its LoS checks for spells, archery, aggro): a ray between their
## heads against the zone's walls, floors and buildings, as the client answered from its own world.
## The server's line-of-sight question (its spells and attacks wait for the client's answer). One chest-to-chest ray
## said "not in view" through a tree-house platform, a branch or a floor edge between two chests (owner 2026-10-15,
## Grove of Domnann: "you can't see your target from here" on an instant DoT, "not in view" on a monster hitting you
## in melee). Within melee reach it is always seen; further, seen when any of three heights (knees, chest, head) is
## clear, each ray starting a little outside both bodies.
const LOS_NEAR_M := 6.0
const LOS_HEIGHTS := [0.6, 1.5, 2.2]


func _los(source: int, target_oid: int) -> void:
	var a := _view_pos(source)
	var b := _view_pos(target_oid)
	Server.client.call("LosReply", source, target_oid, a == Vector3.INF or b == Vector3.INF or sees(a, b))


func sees(a: Vector3, b: Vector3) -> bool:
	if Vector2(a.x - b.x, a.z - b.z).length() <= LOS_NEAR_M:
		return true
	var dir := Vector3(b.x - a.x, 0, b.z - a.z).normalized() * 0.4
	var space := get_world_3d().direct_space_state
	for h in LOS_HEIGHTS:
		var q := PhysicsRayQueryParameters3D.create(a + dir + Vector3(0, h, 0), b - dir + Vector3(0, h, 0),
				ZoneLoader.LAYER_WALL | ZoneLoader.LAYER_FLOOR)
		q.hit_back_faces = false
		if space.intersect_ray(q).is_empty():
			return true
	return false


## Your target in view, for the position packets' action flags (the server's melee needs it: AttackComponent's
## "IsObjectInFront && TargetInView", set from every position update - ProcessActionFlags).
func target_in_view(from: Vector3) -> bool:
	if target == null or not is_instance_valid(target):
		return false
	return sees(from, target.global_position)


func _view_pos(oid: int) -> Vector3:
	if oid == Server.me_oid and viewer and viewer.player:
		return viewer.player.global_position
	var st: NpcState = by_oid.get(oid)
	return st.pos if st else Vector3.INF


# ---------------------------------------------------------------- objects on the ground (ObjectCreate)

## A world object the server shows: monster drops, items people dropped, the server's own placed objects. Doors are
## the zone's own (drawn with the land); everything else gets its item model where the server says.
func _add_object(d: Dictionary) -> void:
	var oid := int(d.oid)
	_remove(oid)
	if int(d.door) >= 0:
		# a door (GameDoor / GameKeepDoor / GameRelicDoor): the zone draws it - this is the server's object for it, the
		# one to target (keep doors are attacked) and whose health the server's updates carry
		doors[int(d.door)] = {"oid": oid, "name": String(d.name), "health": 100, "realm": (int(d.flags) >> 4) & 3}
		door_oids[oid] = int(d.door)
		return
	var model := int(d.model) & 0x7FFF
	var p := scene_pos(float(d.x), float(d.y), float(d.z))
	if not (model in RELIC_MODELS) and _baked_prop_near(p):
		return                                                     # the zone already has it (baked, with its fixes)
		# (never a relic: it lies on its pad - a baked world object right under it)
	var m := WeaponModels.make_world(model)
	if m == null:
		m = WeaponModels.make_world(BAG_MODEL)                     # loot without a world model: the brown bag
	if m == null:
		return
	var holder := Node3D.new()
	add_child(holder)
	holder.add_child(m)
	var g := ground_at(p)
	if g > -INF and absf(g - p.y) < 4.0:
		p.y = maxf(p.y, g)
	holder.position = p
	holder.rotation.y = Server.yaw_of(int(d.heading))
	var body := StaticBody3D.new()
	body.collision_layer = OBJECT_PICK
	body.collision_mask = 0
	var shape := CollisionShape3D.new()
	var sphere := SphereShape3D.new()
	sphere.radius = 0.45
	shape.shape = sphere
	shape.position.y = 0.2
	body.add_child(shape)
	holder.add_child(body)
	body.set_meta("server_object", oid)
	holder.set_meta("name", String(d.name))
	holder.set_meta("model", model)
	objects[oid] = holder


## A left click on a ground object asks the server to pick it up. True when the click hit one.
func click_object(cam: Camera3D, screen_pos: Vector2) -> bool:
	var from := cam.project_ray_origin(screen_pos)
	var q := PhysicsRayQueryParameters3D.create(from, from + cam.project_ray_normal(screen_pos) * 60.0, OBJECT_PICK)
	var hit := get_world_3d().direct_space_state.intersect_ray(q)
	if hit.is_empty() or not hit.collider.has_meta("server_object"):
		return false
	var oid := int(hit.collider.get_meta("server_object"))
	var r := Server.to_region(_current_zone(), player.global_position)
	# the server picks up what you have targeted (PlayerPickUpRequestHandler); a relic is taken with a use
	# (GameRelic.Interact -> TryPickup: carried to your realm's pad), not picked up (owner 2026-10-14: relic raids)
	Server.client.call("Target", oid, 0x8000 | 0x6000)
	var holder: Node3D = objects.get(oid)
	if holder and int(holder.get_meta("model", 0)) in RELIC_MODELS:
		Server.client.call("Interact", oid, int(r.x), int(r.y))
	else:
		Server.client.call("PickUp", int(r.x), int(r.y), oid)
	return true


func _target_oid() -> int:
	return int(target.spawn.get("oid", 0)) if target and is_instance_valid(target) else 0


# ---------------------------------------------------------------- the server's windows

var _merchant_pages := {}                    # page -> [runtime item ids] for the merchant window
var _merchant_at := 0


func _merchant(d: Dictionary) -> void:
	if viewer == null or viewer.ui == null or viewer.ui.merchant == null:
		return
	var now := Time.get_ticks_msec()
	if now - _merchant_at > 1500:                              # a new window (its pages come together)
		_merchant_pages = {}
	_merchant_at = now
	var pg := int(d.page)
	var ids := []
	for it in d.get("items", []):
		var id := "srvm:%d:%d" % [pg, int(it.index)]
		ItemDb.add_runtime(id, {"id": id, "name": String(it.name), "level": int(it.level), "dps_af": int(it.value1),
				"spd_abs": int(it.spd_abs), "hand": int(it.hand), "type_damage": int(it.type_damage),
				"object_type": int(it.object_type), "weight": int(it.value2), "price": int(it.price), "model": int(it.model),
				"icon": Server.item_icon(int(it.model)), "maxcondition": 100, "condition": 100, "maxdurability": 100,
				"durability": 100, "quality": 100, "server": true})
		ids.append(id)
	_merchant_pages[pg] = ids
	var who := String(PlayerData.target.get("name", "Merchant"))
	viewer.ui.merchant.open_server(who, _merchant_pages, int(d.window))


var _open_notes := {}                         # the OK boxes showing (their text): the same one isn't stacked


func _dialog(d: Dictionary) -> void:
	if viewer == null or viewer.ui == null:
		return
	var text := String(d.text)
	# the free-level notice (GamePlayer.OnLevelUp sends it as an OK box at every level while you could take one): the
	# owner never had it pop up in the original client - a line in the system window instead (owner 2026-10-13: it
	# popped up non stop)
	if int(d.type) == 0 and int(d.code) == 0 and text.to_lower().contains("free level"):
		PlayerData.message.emit(text, "system")
		return
	var reply := func(answer: int):
		Server.client.call("DialogResponse", int(d.data1), int(d.data2), int(d.data3), int(d.code), answer)
	if int(d.type) == 0:
		if _open_notes.has(text):
			return
		_open_notes[text] = true
		var done := func():
			_open_notes.erase(text)
			reply.call(1)
		UiArt.confirm(viewer.ui.root, "", text, "OK", "CLOSE", done, done)
	else:
		UiArt.confirm(viewer.ui.root, "", String(d.text), "ACCEPT", "DECLINE", func(): reply.call(1), func(): reply.call(0))


# ---------------------------------------------------------------- your pet (PetWindow)

var pet_oid := 0
var max_speed_pct := 100


## Your speed (the server's MaxSpeed percent) on your figure.
func _apply_max_speed(pct: int) -> void:
	max_speed_pct = pct
	if viewer and viewer.player:
		viewer.player.encumbrance = clampf(float(pct) / 100.0, 0.0, 3.0) if pct > 0 else 1.0


func _pet_window(d: Dictionary) -> void:
	Server.pet_icons = d.get("icons", []) if int(d.action) != 0 else []
	if int(d.action) == 0:
		pet_oid = 0
		PlayerData.set_pet({})
		return
	pet_oid = int(d.oid)
	var st: NpcState = by_oid.get(pet_oid)
	var mode: String = {1: "aggressive", 2: "defensive", 3: "passive"}.get(int(d.aggro), "defensive")
	PlayerData.set_pet({"name": String(st.spawn.name) if st else "Pet", "health": st.health if st else 1.0, "mode": mode})


# ---------------------------------------------------------------- keeps: doors, siege weapons, relics (owner 2026-10-14)

const RELIC_MODELS := [630, 631, 632, 633, 634, 635]     # objects.csv: the six realm relics
var doors := {}                              # the client's door id -> {oid, name, health %, realm}: the server's doors
var door_oids := {}                          # object id -> door id
var target_door := 0                         # the targeted door's object id (its health on the target window)


## A door clicked (ZoneDoor, the zone's own): the server is asked (DoorRequest: it opens it for whoever may pass, an
## enemy keep door stays shut) and, when it has an object for the door, the door is targeted - keep doors are
## attacked like any target (GameKeepDoor: health, broken = open for good). As the client did.
func request_door(door: ZoneDoor) -> void:
	if door == null or door.door_id < 0 or Server.client == null:
		return
	var info: Dictionary = doors.get(door.door_id, {})
	if not info.is_empty():
		if target:
			target = null
		target_door = int(info.oid)
		PlayerData.set_target({"name": String(info.name) if String(info.name) != "" else "door", "level": 0,
				"con_color": Color.WHITE, "health": float(info.health) / 100.0})
		Server.client.call("Target", int(info.oid), 0x8000 | 0x6000)
	Server.client.call("DoorRequest", door.door_id, 0 if door.is_open else 1)


## DoorState: open / shut a door of a loaded zone (both leaves of a double door).
func _door_state(d: Dictionary) -> void:
	var id := int(d.door_id)
	var loaders: Array = (viewer.region.zones.values() if viewer and viewer.get("region") and viewer.region else [])
	if loaders.is_empty() and zone:
		loaders = [zone]
	for zl in loaders:
		if zl and (zl as ZoneLoader).door_by_id.has(id):
			for door in zl.door_by_id[id]:
				(door as ZoneDoor).set_server_state(bool(d.open))


## The siege weapon you control (SiegeWeaponInterface): its window - load, arm, aim, fire, move, stop, repair,
## salvage, release - with its ammunition; closed when you let it go.
func _siege_window(kind: String, d: Dictionary) -> void:
	if viewer == null or viewer.ui == null:
		return
	if kind == "siege_close":
		viewer.ui.siege_window_close()
	else:
		viewer.ui.siege_window_open(d)


## SiegeWeaponAnimation: a siege weapon aiming / arming / loading / firing (every siege weapon in view, yours or
## not). Firing plays its spell effect (SiegeWeapon.Effect, a spells.csv effect: the catapult's boulder 0x89C, the
## ballista's bolt 0x89A ...) on what it hit.
func _siege_anim(d: Dictionary) -> void:
	var sst: NpcState = by_oid.get(int(d.oid))
	if sst and sst.view:
		(sst.view as Npc).play_siege(int(d.action))        # the weapon itself: winding up, loading, firing
	if int(d.action) != 4 or int(d.effect) <= 0:
		return
	var at := Vector3.INF
	var tst: NpcState = by_oid.get(int(d.target))
	if tst:
		at = tst.pos
	elif int(d.target) == Server.me_oid and viewer and viewer.player:
		at = viewer.player.global_position
	else:
		at = scene_pos(float(d.x), float(d.y), float(d.z))      # the ground target (region units)
	if at == Vector3.INF:
		return
	var mark := Node3D.new()
	add_child(mark)
	mark.global_position = at
	SpellFx.play(int(d.effect), mark, 1.8)
	get_tree().create_timer(8.0).timeout.connect(mark.queue_free)


# ---------------------------------------------------------------- riders (Riding)

var _riders := {}                            # rider object id -> steed object id


func _riding(d: Dictionary) -> void:
	if int(d.rider) == Server.me_oid:                          # you, on a stable master's horse (or off it)
		if viewer:
			viewer.call("_server_mount", int(d.steed) if int(d.mount) != 0 else 0)
		return
	var rider: NpcState = by_oid.get(int(d.rider))
	if int(d.mount) == 0:
		_riders.erase(int(d.rider))
		if rider:
			rider.ride_clip = ""
		return
	_riders[int(d.rider)] = int(d.steed)
	if rider:
		rider.ride_clip = "ride_horse"


## Each rider sits in its steed's saddle (the model's saddle node, else 1.3 m up its back), facing its way. A ride the
## server has left behind ends here (owner 2026-10-15: stable masters' horses lingering, along zone borders most, long
## after the riding bot had moved on): the rider's own server position more than RIDE_LOST_M from its steed - a
## dismount we never got (out of range), a horse whose updates stopped at a zone edge - and the rider goes on alone;
## the riderless horse then lasts only as long as the server keeps sending it (STALE_MS).
const RIDE_LOST_M := 12.0


func _seat_riders() -> void:
	var now := Time.get_ticks_msec()
	for r in _riders.keys():
		var rider: NpcState = by_oid.get(r)
		var steed: NpcState = by_oid.get(_riders[r])
		if rider == null or steed == null:
			if rider:
				rider.ride_clip = ""
			_riders.erase(r)
			continue
		var rm: Dictionary = _mover.get(rider, {})
		if rm.get("srv_pos") is Vector3 and now - int(rm.get("srv_at", 0)) < 3000 				and Vector2((rm.srv_pos as Vector3).x - steed.pos.x, (rm.srv_pos as Vector3).z - steed.pos.z).length() > RIDE_LOST_M:
			rider.ride_clip = ""
			rider.pos = rm.srv_pos
			_riders.erase(r)
			_ground(rider)
			continue
		rider.pos = seat_of(steed)
		rider.yaw = steed.yaw
		rider.mode = NpcState.Mode.IDLE


## A steed's saddle: its model's saddle node, else 1.3 m up its back.
func seat_of(steed: NpcState) -> Vector3:
	if steed.view and is_instance_valid(steed.view):
		var sn := steed.view.find_child("saddle*", true, false) as Node3D
		if sn:
			return sn.global_position
	return steed.pos + Vector3(0, 1.3, 0)


## A raid window slot clicked: target that member (its view if drawn, else straight on the server).
## The server's ChangeTarget (/target <name>, /assist): select that object as a click would - the client then sends
## its Target packet, which is what sets the server's target. Missing until 2026-10-17: "/target Haralhelm" answered
## "[GM] You target Haralhelm." but the target window stayed empty and /invite found no target.
var _server_chose_target := false


func _change_target(oid: int) -> void:
	if oid <= 0:
		if target or target_door:
			clear_target()
		return
	_server_chose_target = true
	target_oid(oid)
	_server_chose_target = false


func target_oid(oid: int) -> void:
	if oid <= 0:
		return
	if oid == Server.me_oid and viewer:
		viewer.target_self()
		return
	var st: NpcState = by_oid.get(oid)
	if st and st.view and is_instance_valid(st.view):
		select(st.view as Npc)
	elif Server.client:
		Server.client.call("Target", oid, 0x8000 | 0x6000)


## The zones' baked props (pipeline/build_zone.py world_objects: the old server's WorldObject rows - tents,
## campfires, banners - placed with the land and hand-fixed) stand where the server's same objects are; a server
## object within BAKED_M of one is it, so it isn't drawn twice.
func _baked_prop_near(p: Vector3) -> bool:
	var zls: Array = region.zones.values() if region else [zone]
	for zl in zls:
		var z := zl as ZoneLoader
		if z == null:
			continue
		var off: Vector3 = z.position
		for f in z.info.get("fixtures", []):
			if String(f.get("source", "")) != "world_object":
				continue
			var fp: Array = f.pos
			if Vector2(float(fp[0]) + off.x - p.x, float(fp[2]) + off.z - p.z).length() <= BAKED_M:
				return true
	return false


## The packet's style number (a styles.csv row: the style's Icon / TwoHandAnimation) -> its canims animation.
static var _style_anims := {}


static func _style_anim(style: int) -> int:
	if _style_anims.is_empty():
		var t = JSON.parse_string(FileAccess.get_file_as_string("res://content/rules/style_anims.json")) 				if FileAccess.file_exists("res://content/rules/style_anims.json") else null
		_style_anims = t if t is Dictionary else {"_": 0}
	return int(_style_anims.get(str(style), 0))
