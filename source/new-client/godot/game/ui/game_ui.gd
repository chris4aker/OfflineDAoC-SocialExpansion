class_name GameUI
extends CanvasLayer
## The 1.65 in-game interface (UI BUILD PLAN.md), built from the client's own UI bitmaps (UiArt) and laid out in the
## client's 800x600 units, scaled to the window height (UI scale in Options). Every window is a ClassicWindow that
## moves by its corner handle and remembers where it was; Options > WINDOWS puts closed ones back.
## Default places are the client's default.ini [Panels-800x600], anchored to the nearest screen edge:
##   Stats 608,0 (right panel: CHARACTER / SKILLS / MAGIC / COMBAT / GROUP / INVENTORY)
##   Quickbar 304,489 / Quickbar2 304,531 / Quickbar3 0,338 (vertical)    ChatWindow0 Main 0,381 312x195
##   ChatWindow1 Combat (closed)   MiniGroup 477,370   MiniPet 665,446 (opens with a pet)   Compass 363,470
##   TimeDisplay 127,0   status (rightbot: you, your experience, your target) bottom right
## The window keys (Show Stats C, Inventory I, ...) come from Keybinds.

const BASE_H := 600.0                    # the client's layout height
const TABS := ["character", "inventory", "skills", "combat", "magic", "group"]   # the icons on control.bmp, left to right; Warcry guide 2004: "the Status Window, the Backpack and Paperdoll, the Skills Window, the Combat Window, the Magic Window, and the Group Window"
const TAB_X := [13, 41, 70, 98, 126, 154]            # the tab icons on right.bmp / the sheets (measured, original px)
const TAB_W := [25, 25, 25, 25, 25, 25]
const SHEETS := {"character": "charsheet", "skills": "skillsheet", "magic": "magicsheet", "combat": "combstylesheet",
				 "group": "group", "inventory": "old_pperdoll"}
const SHOW_ACTIONS := {"show_stats": "character", "show_skills": "skills", "show_spells": "magic",
					   "show_combat": "combat", "show_group": "group", "show_inventory": "inventory"}
## Options > WINDOWS: every window a player can close, with its button label.
const RESTORABLE := [["panel", "CHARACTER PANEL"], ["status", "STATUS"], ["chat", "CHAT"], ["chat_combat", "COMBAT CHAT"],
		["quickbar1", "QUICKBAR 1"], ["quickbar2", "QUICKBAR 2"], ["quickbar3", "QUICKBAR 3"], ["minigroup", "GROUP"],
		["minipet", "PET"], ["compass", "COMPASS"], ["time", "TIME"], ["info", "INFORMATION"], ["map", "MAP"],
		["journal", "QUEST JOURNAL"], ["conc", "CONCENTRATION"], ["benefits", "BENEFITS"], ["warmap", "WAR MAP"],
		["target", "TARGET"], ["raid", "RAID"]]

var root: Control
var ui_scale := 1.0
var windows := {}
var defaults := {}                       # id -> [position, visible] (Options > WINDOWS > RESET)
var right_panel: ClassicWindow
var sheet_tab := "character"
var _sheet_bg: TextureRect
var _sheet_body: Control
var _strip: TextureRect
var _tab_lit: Array = []
var _tab_hover: Array = []
var _status_bars := {}
var _status_name: Label
var _target_name: Label
var _target_bar: TextureRect
var _target_pct: Label
var _jewels: Array = []
var _jewels_lit := -1
var _bubble_bar: TextureRect
var chat: ChatWindow
var chat_combat: ChatWindow
var quickbars: Array = []
var options: OptionsWindow
var clear_target := Callable()               # set by the zone viewer: drops the current target (Esc)
var merchant: MerchantWindow
var vault: VaultWindow
var exchange: ExchangeWindow
var journal: JournalWindow
var guide: ClassicWindow
var quest_abandon: Callable                               # QuestEngine.abandon (set by the zone viewer)
signal item_dropped_on_world(slot: int, screen_pos: Vector2)   # zone viewer: an NPC under it (smith repair, sell)
var map_window: MapWindow
var casting: Casting
var _cast_bar: Control
var _cast_fill: ColorRect
var _cast_name: Label
var _effects_bar: HBoxContainer
var npc_dialog: NpcDialog
var trainer: TrainerWindow
const TRANSIENT := ["npc_dialog", "trainer", "merchant", "vault", "exchange", "guide", "info", "release", "siege"]
const INFO_W := 160.0                                     # the information window's width (interact.bmp is 300)
const INFO_WIDE := 320.0                                  # ... for a server text with long lines (/stables routes)
var _compass_letters: Control
var _clock: Label
var player: Node3D
var sky: Node                            # SkySystem: the game clock on the time display
var hidden_all := false


func _ready() -> void:
	layer = 5
	root = Control.new()
	root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(root)
	root.theme = UiArt.tooltip_theme()
	var cfg := ConfigFile.new()
	cfg.load(UiArt.settings_path)
	ui_scale = float(cfg.get_value("interface", "ui_scale", 1.0))
	get_viewport().size_changed.connect(_rescale)
	_rescale()
	var drop := WorldDrop.new()                            # behind every window: items dragged onto the world / an NPC
	drop.ui = self
	root.add_child(drop)
	_build()


func _rescale() -> void:
	var vp := get_viewport().get_visible_rect().size
	var s := vp.y / BASE_H * 0.78 * ui_scale             # the client at 800x600 = 1:1; readable default at 1080p
	root.scale = Vector2(s, s)
	root.size = vp / s


## Virtual (client-unit) size of the screen.
func area() -> Vector2:
	return root.size


func set_ui_scale(v: float) -> void:
	ui_scale = v
	_rescale()


## A default.ini position (800x600) on this screen: kept against the nearest edge.
func client_pos(x: float, y: float) -> Vector2:
	var a := area()
	return Vector2(x if x < 400 else a.x - (800 - x), y if y < 300 else a.y - (600 - y))


func _add(w: ClassicWindow, pos: Vector2, visible_default: bool) -> void:
	root.add_child(w)
	defaults[w.window_id] = [pos, visible_default]
	w.restore(visible_default)
	if w.window_id in TRANSIENT:
		w.visible = false                                  # conversations start closed (only their place is kept)
	windows[w.window_id] = w


func _window(id: String, frame: String, rect: Rect2, pos: Vector2, visible_default: bool) -> ClassicWindow:
	var w := ClassicWindow.new()
	w.setup(id, frame, rect, pos)
	_add(w, pos, visible_default)
	return w


func _bar(parent: Control, tex: String, r: Rect2) -> TextureRect:
	var bar := TextureRect.new()
	bar.texture = UiArt.tex(tex)
	bar.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	bar.stretch_mode = TextureRect.STRETCH_SCALE
	bar.position = r.position
	bar.size = r.size
	bar.mouse_filter = Control.MOUSE_FILTER_IGNORE
	parent.add_child(bar)
	return bar


func _build() -> void:
	var a := area()
	# --- status panel (bottom right): rows measured on rightbot.bmp - your name, three bars (x 30-120 at y 19 / 30.5 /
	# 40, percent box x 4-17), the experience jewels (y 50-60), then your target: name bar (y 70-80) and its health
	# (percent box x 3-19, bar y 82-89). Bar order health / power / endurance: to check against a 1.65 screenshot.
	var st := _window("status", "rightbot", Rect2(), Vector2(a.x - 128, a.y - 96), true)
	st.closable = false
	_status_name = UiArt.label(PlayerData.display_name(), 7, UiArt.GOLD_HI)
	_status_name.position = Vector2(14, 3)                 # the name bar's dark inside: x 14-116, y 3-11
	_status_name.size = Vector2(102, 8)
	_status_name.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_status_name.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	st.add_child(_status_name)
	# owner 2026-10-10 (from the 1.65 client): health red, endurance GREEN above power. Power is YELLOW (owner,
	# bot plan phase 1: "purple ... should be yellow"): the client's bluefull is a purple-blue (avg 87, 49, 226) and
	# game.dll never names it - its interface list loads yellowfull (0x54f6d8)
	for spec in [["health", "redfull", Rect2(30, 19.5, 90, 6)], ["endurance", "greenfull", Rect2(30, 31, 90, 6)],
			["power", "yellowfull", Rect2(30, 40.5, 90, 6)]]:
		_status_bars[spec[0]] = [_bar(st, spec[1], spec[2]), spec[2].size.x]
	# the experience, as the 1.64 manual / in-game help: "The line of blue circles represents 100% of the experience
	# needed to reach the next level ... The long blue bar represents one bubble. When it is filled, the next bubble
	# will become highlighted" (owner 2026-10-15: no way to see how far the next bubble is). The jewels in the box's
	# scalloped top (expjwl_bg empty / expjwl_full lit - lit only when whole, as the period text), the bubble's bar
	# (bluebg / bluefull) along its bottom (the box's dark inside: x 28-119, y 49-61).
	# the small boxes left of the bars name them (owner 2026-10-15: "HP ... END ... POW ... EXP"; they were empty) -
	# each box's dark inside measured on rightbot.bmp
	for lb in [["HP", Rect2(5, 18, 12, 8)], ["END", Rect2(5, 28, 18, 9)], ["POW", Rect2(4, 40, 20, 8)],
			["EXP", Rect2(5, 51, 17, 9)]]:
		var l := UiArt.label(lb[0], 6, UiArt.CREAM)
		l.position = (lb[1] as Rect2).position
		l.size = (lb[1] as Rect2).size
		l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		l.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		l.mouse_filter = Control.MOUSE_FILTER_IGNORE
		st.add_child(l)
	for i in 10:                                           # the 10 experience jewels of the current level
		var j := TextureRect.new()
		j.texture = UiArt.region("expjwl_bg", Rect2(i * 12.8, 0, 12.8, 16))
		j.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		j.stretch_mode = TextureRect.STRETCH_SCALE
		j.position = Vector2(30 + i * 9.0, 49.5)
		j.size = Vector2(9.0, 8.5)
		j.mouse_filter = Control.MOUSE_FILTER_IGNORE
		st.add_child(j)
		_jewels.append(j)
	_bar(st, "bluebg", Rect2(30, 58.5, 90, 2.5))
	_bubble_bar = _bar(st, "bluefull", Rect2(30, 58.5, 90, 2.5))
	_target_name = UiArt.label("", 8, UiArt.CREAM)
	_target_name.position = Vector2(6, 70)
	_target_name.size = Vector2(114, 10)
	_target_name.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_target_name.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_target_name.clip_text = true
	st.add_child(_target_name)
	_target_pct = UiArt.label("", 6, UiArt.CREAM)
	_target_pct.position = Vector2(3, 81)
	_target_pct.size = Vector2(16, 9)
	_target_pct.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_target_pct.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	st.add_child(_target_pct)
	_target_bar = _bar(st, "redfull", Rect2(22, 82.5, 98, 6))
	_target_bar.visible = false
	PlayerData.target_changed.connect(_refresh_target)

	# --- quickbars (default.ini: 1 above 2 at the bottom centre, 3 vertical on the left, closed)
	for bar in 3:
		var q := Quickbar.new()
		q.bar = bar
		q.vertical = bool(_saved("interface", "quickbar%d_vertical" % (bar + 1), bar == 2))
		var pos: Vector2 = [Vector2(a.x * 0.5 - 96, a.y - 111), Vector2(a.x * 0.5 - 96, a.y - 69),
				client_pos(0, 338 - 186)][bar]
		q.setup("quickbar%d" % (bar + 1), "hbar_vert" if q.vertical else "hbar_horz", Rect2(), pos)
		q.build()
		_add(q, pos, bar < 2)
		quickbars.append(q)

	# --- chat: two separate boxes (owner 2026-10-09: "two separate boxes like the new version" - default.ini
	# ChatWindow0 Main / ChatWindow1 Combat), the combat box on top, the chat box (typing line) below it at the
	# bottom left; each moves and resizes on its own and shows its own message types (Options > CHAT)
	for spec in [["chat", "main", Vector2(0, a.y - 126), Vector2(312, 122)],
			["chat_combat", "combat", Vector2(0, a.y - 126 - 104), Vector2(312, 102)]]:
		var c := ChatWindow.new()
		c.role = spec[1]
		c.resizable = true
		c.size = spec[3]
		c.setup(spec[0], "chatext", Rect2(), spec[2])
		c.build()
		_add(c, spec[2], true)
		if spec[1] == "main":
			chat = c
			PlayerData.macro_run.connect(c.run_line)        # a /macro on the quickbar types its command
		else:
			chat_combat = c
	message("Welcome to Dark Age of Camelot.", "system")
	message("Type /help for a list of commands.", "help")

	# --- compass (default.ini 363,470: just above the quickbars) - the client's letter strip, N NE E ... NW
	var comp := ClassicWindow.new()
	comp.window_id = "compass"
	comp.name = "compass"
	comp.closable = false
	comp.size = Vector2(112, 22)
	comp.mouse_filter = Control.MOUSE_FILTER_STOP
	var back := ColorRect.new()
	back.color = Color(0, 0, 0, 0.45)
	back.size = comp.size
	back.mouse_filter = Control.MOUSE_FILTER_IGNORE
	comp.add_child(back)
	var clip := Control.new()
	clip.clip_contents = true
	clip.position = Vector2(2, 3)
	clip.size = Vector2(108, 16)
	clip.mouse_filter = Control.MOUSE_FILTER_IGNORE
	comp.add_child(clip)
	_compass_letters = Control.new()
	_compass_letters.mouse_filter = Control.MOUSE_FILTER_IGNORE
	clip.add_child(_compass_letters)
	for k in 3:                                            # three copies side by side so the strip wraps
		var t := UiArt.picture("compass_bar")
		t.size = Vector2(256, 16)                          # 512x32 shown at half size: 32 units per letter
		t.position = Vector2(k * 256, 0)
		_compass_letters.add_child(t)
	var tick := ColorRect.new()
	tick.color = UiArt.GOLD_HI
	tick.position = Vector2(55.5, 0)
	tick.size = Vector2(1, 3)
	tick.mouse_filter = Control.MOUSE_FILTER_IGNORE
	comp.add_child(tick)
	var comp_pos := Vector2(a.x * 0.5 - 56, a.y - 134)
	comp.position = comp_pos
	_add(comp, comp_pos, true)

	# --- time display (default.ini 127,0): the game clock on timedisp.bmp
	var tm := _window("time", "timedisp", Rect2(), client_pos(127, 0), true)
	_clock = UiArt.label("", 10, UiArt.CREAM)
	_clock.position = Vector2(10, 9)
	_clock.size = Vector2(80, 16)
	_clock.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	tm.add_child(_clock)

	# --- information window (default.ini InfoPage 305,11 300x448 = interact.bmp), the client's "small object window":
	# right-click an item = its standard information, Shift+I = the delve; hovering an item only names it
	# owner 2026-10-09: half the width and only as tall as its text - a nine-patch keeps the frame's handle / close
	# (19 px top bar), scroll track (13 px right) and stone foot (33 px) at full size
	var info := ClassicWindow.new()
	info.resizable = true
	info.patch = [6, 19, 13, 33]
	info.min_size = Vector2(120, 90)
	info.size = Vector2(INFO_W, 150)
	info.setup("info", "interact", Rect2(), client_pos(305, 11))
	_add(info, client_pos(305, 11), false)
	info.visible = false                                  # opens only to show something (an old save had it open)
	var title := UiArt.label("", 11, UiArt.GOLD_HI)
	title.name = "Title"
	title.position = Vector2(12, 21)
	title.size = Vector2(INFO_W - 27, 16)
	title.clip_text = true
	info.add_child(title)
	var body := RichTextLabel.new()
	body.name = "Body"
	body.position = Vector2(12, 39)
	body.size = Vector2(INFO_W - 27, 20)
	body.fit_content = true
	body.scroll_active = false
	body.add_theme_font_override("normal_font", UiArt.font(true))
	body.add_theme_font_size_override("normal_font_size", 10)
	body.add_theme_color_override("default_color", UiArt.CREAM)
	UiArt.themed(body)
	info.add_child(body)
	info.resized_by_user.connect(func():
		if not body.fit_content:
			body.size = Vector2(info.size.x - 27, maxf(info.size.y - body.position.y - 8 - 33, 20))
		(info.get_node("Title") as Label).size.x = info.size.x - 27)
	_build_release()
	_build_cast_bar()
	npc_dialog = NpcDialog.new()                          # NPC talk with clickable [keywords] (npctalk.bmp)
	npc_dialog.setup("npc_dialog", "npctalk", Rect2(), client_pos(208, 140))
	_add(npc_dialog, client_pos(208, 140), false)
	npc_dialog.build()
	trainer = TrainerWindow.new()                         # training at your trainer (training.bmp)
	trainer.setup("trainer", "training", Rect2(), client_pos(225, 60))
	_add(trainer, client_pos(225, 60), false)
	trainer.build()
	# --- quest journal (default.ini QuestLog 124,130; J) and the QUEST GUIDE text window
	journal = JournalWindow.new()
	journal.setup("journal", "questbg", Rect2(), client_pos(124, 130))
	_add(journal, client_pos(124, 130), false)
	journal.build()
	journal.guide_requested.connect(show_guide)
	journal.remove_requested.connect(func(id: String):
		if quest_abandon.is_valid():
			quest_abandon.call(id))
	_build_guide()
	map_window = MapWindow.new()                          # M: the zone map (owner request; post-1.65 feature)
	map_window.resizable = true
	map_window.max_size = Vector2(1100, 1100)
	map_window.patch = [6, 19, 13, 33]
	map_window.size = Vector2(MapWindow.MAP_SIZE + 27, MapWindow.MAP_SIZE + MapWindow.TOP + 8 + 12)
	map_window.setup("map", "interact", Rect2(), Vector2(area().x * 0.5 - 150, 40))
	_add(map_window, Vector2(area().x * 0.5 - 150, 40), false)
	map_window.build()
	map_window.player = player
	PlayerData.delve.connect(show_info.bind(true))
	PlayerData.skill_info.connect(show_skill_info)
	PlayerData.summary.connect(show_info.bind(false))

	# --- mini group (default.ini 477,370) and pet window (665,446, opens when a pet is summoned)
	_build_minigroup()
	_build_target()
	_build_raid()
	_build_minipet()
	_build_conc()
	_build_benefits()
	_build_warmap()
	PlayerData.window_toggle.connect(func(id: String):
		if windows.has(id):
			if windows[id].visible:
				windows[id].hide_window()
			else:
				windows[id].show_window())
	PlayerData.disband_requested.connect(func():
		if PlayerData.group.is_empty():
			PlayerData.message.emit("You are not in a group.", "system")
		else:
			PlayerData.group.clear()
			PlayerData.group_changed.emit()
			PlayerData.message.emit("You leave your group.", "system"))

	# --- right panel with the six sheets (default.ini Stats 608,0: open)
	right_panel = _window("panel", "right", Rect2(0, 0, 192, 448), Vector2(a.x - 192, 0), true)
	_sheet_bg = UiArt.picture("charsheet")
	right_panel.add_child(_sheet_bg)
	# the tab strip: control.bmp rows of 32 px = normal / hover / dimmed / selected, drawn over every sheet
	_strip = UiArt.picture("control", Rect2(0, 0, 192, 32))
	right_panel.add_child(_strip)
	for i in TABS.size():
		var lit := UiArt.picture("control", Rect2(TAB_X[i], 96 + 3, TAB_W[i], 24))
		lit.position = Vector2(TAB_X[i], 3)
		lit.visible = false
		right_panel.add_child(lit)
		_tab_lit.append(lit)
		var hover := UiArt.picture("control", Rect2(TAB_X[i], 32 + 3, TAB_W[i], 24))
		hover.position = Vector2(TAB_X[i], 3)
		hover.visible = false
		right_panel.add_child(hover)
		_tab_hover.append(hover)
		var hot := Button.new()
		hot.flat = true
		hot.focus_mode = Control.FOCUS_NONE
		hot.position = Vector2(TAB_X[i], 3)
		hot.size = Vector2(TAB_W[i], 24)
		hot.tooltip_text = TABS[i].to_upper()
		for k in ["normal", "hover", "pressed", "focus"]:
			hot.add_theme_stylebox_override(k, StyleBoxEmpty.new())
		hot.mouse_entered.connect(func(): hover.visible = true)
		hot.mouse_exited.connect(func(): hover.visible = false)
		hot.pressed.connect(func():                        # the old client: the open sheet's tab folds it away to the
			_tab_clicked(TABS[i]))                         # strip of six tabs; any tab opens its sheet again (owner)
		right_panel.add_child(hot)
	_sheet_body = Control.new()
	_sheet_body.size = right_panel.size
	_sheet_body.mouse_filter = Control.MOUSE_FILTER_IGNORE
	right_panel.add_child(_sheet_body)
	_set_sheet(String(_saved("interface", "sheet", "character")))
	_collapse(bool(_saved("interface", "sheet_collapsed", false)))

	# --- merchant (default.ini Merchant 450,0): opens on a right-click on a merchant
	merchant = MerchantWindow.new()
	merchant.setup("merchant", "merchant", Rect2(), client_pos(450, 0))
	root.add_child(merchant)
	merchant.visible = false
	merchant.build()
	windows["merchant"] = merchant
	# --- vault (default.ini Bank 6,22): opens on a right-click on a vault keeper
	vault = VaultWindow.new()
	vault.setup("vault", "vault", Rect2(), client_pos(6, 22))
	root.add_child(vault)
	vault.visible = false
	vault.build()
	windows["vault"] = vault
	if Server.active:                                       # the server's vault keepers (Server.vault_open)
		PlayerData.hook(self, Server.vault_open, func(title: String, first: int, count: int): vault.open_range(title, first, count))
	# --- the Realm Exchange (the server's broker: its [Browse the exchange] / [Manage my listings]) - black granite
	exchange = ExchangeWindow.new()
	exchange.resizable = true                                # (only to lay the granite out as a nine-patch)
	exchange.patch = [3, 12, 12, 3]
	exchange.size = ExchangeWindow.SIZE
	exchange.setup("exchange", "chatext", Rect2(0, 64, 512, 64), client_pos(100, 40))
	exchange.resizable = false
	root.add_child(exchange)
	exchange.visible = false
	exchange.build()
	windows["exchange"] = exchange

	# --- options (Esc)
	options = OptionsWindow.new()
	options.ui = self
	options.setup("options", "options", Rect2(), Vector2(a.x * 0.5 - 192, a.y * 0.5 - 210))
	root.add_child(options)
	options.visible = false
	options.build()
	windows["options"] = options

	PlayerData.changed.connect(_refresh)
	PlayerData.message.connect(message)
	options.movement_changed.connect(func(mode: String):
		if player:
			player.movement_mode = mode)
	_refresh()


## The mini group window (default.ini MiniGroup 330,447): a stone strip with one line per member - the power gem
## (8x8gems.bmp: period Warcry guide "the mana level as a glowing sphere, with a bright yellow-white being completely
## full, and a dull gray being empty"), the name and the health bar. It stays where you put it when you leave.
var _mini_rows: VBoxContainer
var _mini_empty: Label


## The TARGET window (the original client's, owner 2026-10-11): your target's name in its con colour, its health,
## and FACE / FOLLOW / STICK / INVITE / ASSIST / ATTACK - each the slash command the client gave for it.
var _tw_name: Label
var _tw_pct: Label
var _tw_bar: Control
var _tw_bg: Control
const TW_SIZE := Vector2(186, 78)


func _build_target() -> void:
	var pos := client_pos(650, 370)
	var w := ClassicWindow.new()
	# the stretchable stone frame at one fixed size (a non-resizable window keeps its art's own size, which left
	# the buttons hanging out of it - owner 2026-10-11)
	w.resizable = true
	w.patch = [6, 6, 6, 6]
	w.min_size = TW_SIZE
	w.max_size = TW_SIZE
	w.size = TW_SIZE
	w.setup("target", "leftbot", Rect2(), pos)
	_add(w, pos, true)
	w.set_window_size(TW_SIZE)
	# the target: its name in its con colour, then the percent and the health bar (only while there is a target)
	_tw_name = UiArt.label("", 9, UiArt.CREAM)
	_tw_name.position = Vector2(8, 8)
	_tw_name.size = Vector2(TW_SIZE.x - 16, 12)
	_tw_name.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_tw_name.clip_text = true
	w.add_child(_tw_name)
	_tw_pct = UiArt.label("", 7, UiArt.CREAM)
	_tw_pct.position = Vector2(8, 22)
	_tw_pct.size = Vector2(22, 10)
	_tw_pct.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	w.add_child(_tw_pct)
	_tw_bg = _bar(w, "redbg", Rect2(32, 24, TW_SIZE.x - 42, 6))
	_tw_bg.modulate = Color(1, 1, 1, 0.5)
	_tw_bar = _bar(w, "redfull", Rect2(32, 24, TW_SIZE.x - 42, 6))
	var cmds := [["FACE", "face"], ["FOLLOW", "follow"], ["STICK", "stick"], ["INVITE", "invite"], ["ASSIST", "assist"],
			["ATTACK", "attack"]]
	var bw := floorf((TW_SIZE.x - 16 - 2 * 4) / 3.0)
	for i in cmds.size():
		var b := UiArt.button(cmds[i][0], Vector2(bw, 15), 8)
		b.position = Vector2(8 + (i % 3) * (bw + 4), 36 + (i / 3) * 18)
		var cmd: String = cmds[i][1]
		b.pressed.connect(func(): _target_command(cmd))
		w.add_child(b)
	PlayerData.target_changed.connect(_refresh_target_window)
	_refresh_target_window()


func _refresh_target_window() -> void:
	if _tw_name == null:
		return
	var t := PlayerData.target
	_tw_name.text = String(t.get("name", "")).to_upper()
	_tw_name.add_theme_color_override("font_color", t.get("con_color", UiArt.CREAM))
	_tw_bar.visible = not t.is_empty()
	_tw_bg.visible = not t.is_empty()
	_tw_bar.size.x = (TW_SIZE.x - 42) * clampf(float(t.get("health", 1.0)), 0.0, 1.0)
	_tw_pct.text = "" if t.is_empty() else "%d" % roundi(100.0 * float(t.get("health", 1.0)))


func _target_command(cmd: String) -> void:
	if cmd == "attack":
		PlayerData.attack_toggle_requested.emit()
	elif cmd in ["face", "follow", "stick"]:               # the client's own commands, in the server's game too: the
		PlayerData.track_requested.emit(cmd)                # server has none of them ("No such command (/follow)",
	elif Server.active:                                     # 2026-10-17); typed /follow already went this way
		Server.command("/" + cmd)                           # the server's commands, as the client's buttons sent them
	elif cmd == "invite":
		PlayerData.invite_requested.emit("")
	else:
		message("You can't do that here.", "system")


## The RAID window (the companion raid of /raid 40 and /raid 80, as the old client's native raid extension drew it):
## five columns of members - name, health, power - eight rows for 40, sixteen for 80. It opens when the server opens
## the raid and closes with it; it can be moved anywhere. A click on a member targets them.
const RAID_COLS := 5
const RAID_CELL := Vector2(92, 21)
var _raid: ClassicWindow
var _raid_cells: Array = []
var _raid_oids: Array = []
var raid_active := false                       # the server has a raid open (Options > WINDOWS: RAID only then)


func _build_raid() -> void:
	var pos := client_pos(60, 60)
	_raid = ClassicWindow.new()
	_raid.resizable = false
	_raid.patch = [6, 6, 6, 6]
	_raid.size = Vector2(12 + RAID_COLS * (RAID_CELL.x + 2), 16 + 8 * RAID_CELL.y)
	_raid.setup("raid", "leftbot", Rect2(), pos)
	_add(_raid, pos, false)
	_raid.visible = false


func _raid_capacity(capacity: int) -> void:
	for c in _raid_cells:
		(c as Node).queue_free()
	_raid_cells.clear()
	_raid_oids.clear()
	var rows := int(ceil(capacity / float(RAID_COLS)))
	for i in capacity:
		var cell := Control.new()
		cell.position = Vector2(6 + (i % RAID_COLS) * (RAID_CELL.x + 2), 8 + (i / RAID_COLS) * RAID_CELL.y)
		cell.size = RAID_CELL
		cell.mouse_filter = Control.MOUSE_FILTER_STOP
		var n := UiArt.label("", 7, UiArt.CREAM)
		n.name = "N"
		n.position = Vector2(1, 0)
		n.size = Vector2(RAID_CELL.x - 2, 9)
		n.clip_text = true
		cell.add_child(n)
		var hbg := _bar(cell, "redbg", Rect2(1, 10, RAID_CELL.x - 4, 4))
		hbg.modulate = Color(1, 1, 1, 0.5)
		var hb := _bar(cell, "redfull", Rect2(1, 10, RAID_CELL.x - 4, 4))
		hb.name = "Hp"
		hb.size.x = 0
		var pbg := _bar(cell, "bluebg", Rect2(1, 15, RAID_CELL.x - 4, 3))
		pbg.modulate = Color(1, 1, 1, 0.5)
		var pb := _bar(cell, "bluefull", Rect2(1, 15, RAID_CELL.x - 4, 3))
		pb.name = "Pw"
		pb.size.x = 0
		var idx := i
		cell.gui_input.connect(func(e: InputEvent):
			if e is InputEventMouseButton and e.pressed and e.button_index == MOUSE_BUTTON_LEFT and idx < _raid_oids.size():
				raid_target.emit(int(_raid_oids[idx])))
		_raid.add_child(cell)
		_raid_cells.append(cell)
		_raid_oids.append(0)
	_raid.set_window_size(Vector2(12 + RAID_COLS * (RAID_CELL.x + 2), 16 + rows * RAID_CELL.y))


signal raid_target(oid: int)                     # a raid member clicked (ServerWorld targets them)


func raid_packet(d: Dictionary) -> void:
	match int(d.op):
		2:                                                 # open: 40 or 80 slots
			var cap := int(d.slot)
			if cap != _raid_cells.size():
				_raid_capacity(cap)
			raid_active = true
			if not _raid.visible:
				restore_window("raid")
		1:
			var i := int(d.slot)
			if i < 0 or i >= _raid_cells.size():
				return
			var cell: Control = _raid_cells[i]
			var nm := String(d.name)
			(cell.get_node("N") as Label).text = nm
			var w := RAID_CELL.x - 4
			(cell.get_node("Hp") as Control).size.x = w * clampf(int(d.health) / 100.0, 0.0, 1.0) if nm != "" else 0.0
			(cell.get_node("Pw") as Control).size.x = w * clampf(int(d.power) / 100.0, 0.0, 1.0) if nm != "" else 0.0
			_raid_oids[i] = int(d.oid)
		3:                                                 # the raid closed
			raid_active = false
			_raid.hide_window()


func _build_minigroup() -> void:
	var pos := client_pos(477, 370)
	var w := ClassicWindow.new()
	w.resizable = true
	w.patch = [6, 6, 6, 6]
	w.min_size = Vector2(150, 26)
	w.size = Vector2(150, 26)
	w.setup("minigroup", "leftbot", Rect2(), pos)
	_add(w, pos, false)
	_mini_empty = UiArt.label("YOU ARE NOT IN A GROUP", 7, UiArt.DIM)
	_mini_empty.position = Vector2(6, 8)
	_mini_empty.size = Vector2(138, 10)
	_mini_empty.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	w.add_child(_mini_empty)
	_mini_rows = VBoxContainer.new()
	_mini_rows.position = Vector2(7, 7)
	_mini_rows.add_theme_constant_override("separation", 2)
	w.add_child(_mini_rows)


func _tick_minigroup() -> void:
	var w: ClassicWindow = windows.get("minigroup")
	if w == null or not w.visible:
		return
	var rows: Array = PlayerData.group_rows()
	_mini_empty.visible = rows.is_empty()
	while _mini_rows.get_child_count() < rows.size():
		var r := Control.new()
		r.custom_minimum_size = Vector2(136, 10)
		r.mouse_filter = Control.MOUSE_FILTER_STOP                # a click on the row targets the member (owner 2026-10-14)
		var ri := _mini_rows.get_child_count()
		r.gui_input.connect(func(e: InputEvent):
			if e is InputEventMouseButton and e.pressed and e.button_index == MOUSE_BUTTON_LEFT:
				var rows_now: Array = PlayerData.group_rows()
				if ri < rows_now.size():
					PlayerData.member_clicked.emit(rows_now[ri]))
		var gem := TextureRect.new()
		gem.name = "Gem"
		gem.expand_mode = TextureRect.EXPAND_IGNORE_SIZE     # the art is x4: draw the gem at its 8 x 8 layout size
		gem.size = Vector2(8, 8)
		gem.position = Vector2(0, 1)
		gem.mouse_filter = Control.MOUSE_FILTER_IGNORE
		r.add_child(gem)
		var n := UiArt.label("", 7, UiArt.CREAM)
		n.name = "N"
		n.position = Vector2(11, 0)
		n.size = Vector2(62, 10)
		n.clip_text = true
		r.add_child(n)
		var bg := _bar(r, "redbg", Rect2(76, 2, 60, 6))
		bg.modulate = Color(1, 1, 1, 0.5)
		var hb := _bar(r, "redfull", Rect2(76, 2, 60, 6))
		hb.name = "Hp"
		_mini_rows.add_child(r)
	for idx in _mini_rows.get_child_count():
		var r: Control = _mini_rows.get_child(idx)
		r.visible = idx < rows.size()
		if not r.visible:
			continue
		var m: Dictionary = rows[idx]
		var gem_i := clampi(4 - int(floor(clampf(float(m.get("power", 0.0)), 0.0, 1.0) * 4.0 + 0.5)), 0, 4)
		(r.get_node("Gem") as TextureRect).texture = UiArt.region("8x8gems", Rect2(0, gem_i * 8, 8, 8))
		(r.get_node("N") as Label).text = String(m.get("name", "")).to_upper()
		(r.get_node("Hp") as Control).size.x = 60.0 * clampf(float(m.get("hp", 0.0)), 0.0, 1.0)
	var want := Vector2(150, 14.0 + maxf(1, rows.size()) * 12.0)
	if absf(w.size.y - want.y) > 0.5:
		w.set_window_size(want)


## BENEFITS (owner 2026-10-10, the later client's "Group Enhancements"; 1.65 showed the members' enchantments on the
## group page - "1.65 EXCEPTIONS MADE.txt"): each member's name, class and level with the effects on them, two to a
## row, in the stone frame.
var _benefits: ClassicWindow
var _benefits_list: GridContainer
var _benefits_empty: Label
var _benefits_sig := ""


func _build_benefits() -> void:
	_benefits = ClassicWindow.new()
	_benefits.resizable = true
	_benefits.patch = [6, 19, 13, 33]
	_benefits.min_size = Vector2(240, 120)
	_benefits.size = Vector2(300, 330)
	var at := Vector2(area().x * 0.5 - 150, 80)
	_benefits.setup("benefits", "interact", Rect2(), at)
	_add(_benefits, at, false)
	var title := UiArt.label("GROUP BENEFITS", 11, UiArt.GOLD_HI)
	title.position = Vector2(12, 21)
	title.size = Vector2(276, 16)
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_benefits.add_child(title)
	_benefits_empty = UiArt.label("YOU ARE NOT IN A GROUP", 9, UiArt.DIM)
	_benefits_empty.position = Vector2(12, 50)
	_benefits_empty.size = Vector2(276, 14)
	_benefits_empty.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_benefits.add_child(_benefits_empty)
	_benefits_list = GridContainer.new()
	_benefits_list.columns = 2
	_benefits_list.position = Vector2(12, 42)
	_benefits_list.add_theme_constant_override("h_separation", 8)
	_benefits_list.add_theme_constant_override("v_separation", 10)
	_benefits.add_child(_benefits_list)


func _tick_benefits() -> void:
	if _benefits == null or not _benefits.visible:
		return
	var rows: Array = PlayerData.group_rows()
	_benefits_empty.visible = rows.is_empty()
	var parts := []
	for m in rows:
		var ic := []
		for e in m.get("effects", []):
			ic.append(str(e.get("icon", 0)))
		parts.append("%s:%d:%s" % [String(m.get("name", "")), int(m.get("level", 1)), ",".join(ic)])
	var sig := "|".join(parts)
	if sig == _benefits_sig:
		return
	_benefits_sig = sig
	for c in _benefits_list.get_children():
		c.queue_free()
	for m in rows:
		var box := VBoxContainer.new()
		box.custom_minimum_size = Vector2(134, 0)
		box.add_theme_constant_override("separation", 1)
		var head := HBoxContainer.new()
		var n := UiArt.label(String(m.get("name", "")).to_upper(), 8, UiArt.GOLD_HI)
		n.custom_minimum_size = Vector2(106, 10)
		n.clip_text = true
		head.add_child(n)
		head.add_child(UiArt.label(str(int(m.get("level", 1))), 8, UiArt.CREAM))
		box.add_child(head)
		box.add_child(UiArt.label(String(m.get("class_name", "")).to_upper(), 7, UiArt.CREAM))
		var icons := HFlowContainer.new()
		icons.add_theme_constant_override("h_separation", 2)
		icons.custom_minimum_size = Vector2(134, 16)
		for e in m.get("effects", []):
			var ic := TextureRect.new()
			ic.texture = ItemDb.icon(int(e.get("icon", 0)))
			ic.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
			ic.custom_minimum_size = Vector2(15, 15)
			ic.tooltip_text = String(e.get("name", "")).to_upper()
			icons.add_child(ic)
		box.add_child(icons)
		_benefits_list.add_child(box)


## The realm war map (/realmwar).
var warmap: WarMapWindow


var siege: SiegeWindow


## The siege weapon you control (owner 2026-10-14): opened by the server when you take control of one.
func siege_window_open(d: Dictionary) -> void:
	if siege == null:
		siege = SiegeWindow.new()
		siege.resizable = true
		siege.patch = [6, 19, 13, 33]
		siege.min_size = SiegeWindow.BODY
		siege.max_size = SiegeWindow.BODY
		siege.size = SiegeWindow.BODY
		var at := Vector2(area().x * 0.5 + 120, 120)
		siege.setup("siege", "interact", Rect2(), at)
		_add(siege, at, false)
		siege.build()
	siege.show_siege(d)


func siege_window_close() -> void:
	if siege and siege.visible:
		siege.hide_window()


func _build_warmap() -> void:
	warmap = WarMapWindow.new()
	warmap.resizable = true
	warmap.patch = [6, 19, 13, 33]
	warmap.min_size = Vector2(342, 458)                  # the client's 330 x 416 body inside the stone frame (each realm
	warmap.max_size = Vector2(406, 458)                  # page sets its own: Midgard 394 x 352)
	warmap.size = Vector2(342, 458)
	var at := Vector2(area().x * 0.5 - 171, 30)
	warmap.setup("warmap", "interact", Rect2(), at)
	_add(warmap, at, false)
	warmap.player = player
	warmap.build()


## The concentration window (default800.ini MiniConc=546,484, 128x96 = leftbot_scrl.bmp with its scroll arrows):
## the pool left as a bar with used / max points, then every concentration buff you keep up as an icon, six to a
## row, paged by the arrows; shift + right-click an icon cancels it (Warcry interface guide 2004).
var _conc_win: ClassicWindow
var _conc_bar: TextureRect
var _conc_text: Label
var _conc_grid: GridContainer
var _conc_page := 0
var _conc_sig := ""


func _build_conc() -> void:
	var pos := client_pos(546, 484)
	_conc_win = _window("conc", "leftbot_scrl", Rect2(), pos, false)
	if SpellRules.mana_stat(PlayerData.class_id()) < 0:
		_conc_win.visible = false                          # no casting stat, no concentration: it stays shut
	var bg := _bar(_conc_win, "yellowbg", Rect2(8, 14, 100, 7))
	bg.modulate = Color(1, 1, 1, 0.6)
	_conc_bar = _bar(_conc_win, "yellowfull", Rect2(8, 14, 100, 7))
	_conc_text = UiArt.label("", 7, UiArt.CREAM)
	_conc_text.position = Vector2(8, 3)
	_conc_text.size = Vector2(100, 10)
	_conc_text.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_conc_win.add_child(_conc_text)
	_conc_grid = GridContainer.new()
	_conc_grid.columns = 6
	_conc_grid.position = Vector2(7, 26)
	_conc_grid.add_theme_constant_override("h_separation", 1)
	_conc_grid.add_theme_constant_override("v_separation", 1)
	_conc_win.add_child(_conc_grid)
	for d in [[-1, Rect2(115, 10, 12, 12)], [1, Rect2(115, 76, 12, 12)]]:  # the art's up / down arrows
		var b := Button.new()
		b.flat = true
		b.focus_mode = Control.FOCUS_NONE
		for k in ["normal", "hover", "pressed", "focus"]:
			b.add_theme_stylebox_override(k, StyleBoxEmpty.new())
		b.position = d[1].position
		b.size = d[1].size
		b.pressed.connect(func():
			_conc_page = maxi(0, _conc_page + int(d[0]))
			_conc_sig = "")
		_conc_win.add_child(b)


func _tick_conc() -> void:
	if _conc_win != null and _conc_win.visible and Server.active:
		_tick_server_conc()
		return
	if _conc_win == null or not _conc_win.visible or casting == null:
		return
	var mx: int = casting.max_conc()
	var used: int = casting.conc_used()
	_conc_text.text = "CONCENTRATION %d / %d" % [mx - used, mx] if mx > 0 else "NO CONCENTRATION"
	_conc_bar.size.x = 100.0 * (clampf(float(mx - used) / float(mx), 0.0, 1.0) if mx > 0 else 0.0)
	var list: Array = casting.conc_effects()
	var pages := maxi(1, ceili(list.size() / 18.0))
	_conc_page = mini(_conc_page, pages - 1)
	var sig := "%d|%s" % [_conc_page, ",".join(list.map(func(e): return str(e.spell.get("spellid", 0))))]
	if sig == _conc_sig:
		return
	_conc_sig = sig
	for c in _conc_grid.get_children():
		c.queue_free()
	for i in range(_conc_page * 18, mini(list.size(), _conc_page * 18 + 18)):
		var e: Dictionary = list[i]
		var ic := TextureRect.new()
		ic.texture = ItemDb.icon(int(e.icon))
		ic.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		ic.custom_minimum_size = Vector2(16, 16)
		var on_whom := "YOU" if e.on is String else String((e.on as NpcState).spawn.name).to_upper()
		ic.tooltip_text = "%s ON %s (%d CONCENTRATION)
SHIFT + RIGHT-CLICK TO CANCEL" % [String(e.spell.get("name", "")).to_upper(), on_whom, int(e.conc)]
		ic.mouse_filter = Control.MOUSE_FILTER_STOP
		var idx := i
		ic.gui_input.connect(func(ev):
			if ev is InputEventMouseButton and ev.pressed and ev.button_index == MOUSE_BUTTON_RIGHT and ev.shift_pressed:
				casting.cancel_conc(idx)
				_conc_sig = "")
		_conc_grid.add_child(ic)


## The concentration window on the server: its pool from the status packet, its spells from ConcentrationList.
## Shift + right-click cancels one (RemoveConcentrationEffect) once the client has that request (DaocClient).
func _tick_server_conc() -> void:
	var mx := Server.max_conc
	_conc_text.text = "CONCENTRATION %d / %d" % [Server.conc_left, mx] if mx > 0 else "NO CONCENTRATION"
	_conc_bar.size.x = 100.0 * (clampf(float(Server.conc_left) / float(mx), 0.0, 1.0) if mx > 0 else 0.0)
	var list: Array = Server.conc_list
	var pages := maxi(1, ceili(list.size() / 18.0))
	_conc_page = mini(_conc_page, pages - 1)
	var sig := "s%d|%s" % [_conc_page, ",".join(list.map(func(e): return "%s:%s" % [e.name, e.owner]))]
	if sig == _conc_sig:
		return
	_conc_sig = sig
	for c in _conc_grid.get_children():
		c.queue_free()
	for i in range(_conc_page * 18, mini(list.size(), _conc_page * 18 + 18)):
		var e: Dictionary = list[i]
		var ic := TextureRect.new()
		ic.texture = ItemDb.icon(int(e.icon))
		ic.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		ic.custom_minimum_size = Vector2(16, 16)
		var can_cancel: bool = Server.client.has_method("RemoveConcentration")
		ic.tooltip_text = "%s ON %s (%d CONCENTRATION)%s" % [String(e.name).to_upper(), String(e.owner).to_upper(),
				int(e.conc), "
SHIFT + RIGHT-CLICK TO CANCEL" if can_cancel else ""]
		ic.mouse_filter = Control.MOUSE_FILTER_STOP
		var idx := int(e.index)
		ic.gui_input.connect(func(ev):
			if ev is InputEventMouseButton and ev.pressed and ev.button_index == MOUSE_BUTTON_RIGHT and ev.shift_pressed 					and Server.client.has_method("RemoveConcentration"):
				Server.client.call("RemoveConcentration", idx))
		_conc_grid.add_child(ic)


## A pet command button dragged off the pet window: a quickbar slot that gives the command.
func _pet_cmd_drag(_at: Vector2, b: Button, label: String) -> Variant:
	var prev := UiArt.button(label, b.size, 8)
	prev.modulate = Color(1, 1, 1, 0.8)
	b.set_drag_preview(prev)
	return {"kind": "petcmd", "id": label.to_lower(), "icon": -1, "name": "PET " + label}


## The pet window (minipet.bmp 128x128): name, health, the pet commands. Opens when a pet is summoned (owner).
func _build_minipet() -> void:
	var pos := Vector2(area().x - 130, area().y - 96 - 132)     # default.ini 665,446: right side, above the status
	var w := _window("minipet", "minipet", Rect2(), pos, false)
	var n := UiArt.label("", 8, UiArt.GOLD_HI)
	n.name = "PetName"
	n.position = Vector2(14, 2)
	n.size = Vector2(100, 11)
	n.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	w.add_child(n)
	var hb := _bar(w, "redfull", Rect2(8, 17, 112, 6))
	hb.name = "PetHealth"
	_pet_bar = hb
	var rows := [["AGGRESSIVE", "DEFENSIVE"], ["PASSIVE", "FOLLOW"], ["STAY", "ATTACK"], ["RELEASE"]]
	for r in rows.size():
		var cols: Array = rows[r]
		var bw := (112.0 - (cols.size() - 1) * 2.0) / cols.size()
		for c in cols.size():
			var b := UiArt.button(cols[c], Vector2(bw, 15), 8)
			b.position = Vector2(8 + c * (bw + 2), 28 + r * 17)
			b.pressed.connect(PlayerData.pet_command.bind(String(cols[c]).to_lower()))
			# hold the left button and drag a command onto a quickbar, as in the client (owner 2026-10-10)
			b.set_drag_forwarding(_pet_cmd_drag.bind(b, String(cols[c])), Callable(), Callable())
			w.add_child(b)
	# the pet's buffs: a granite strip under the 1.65 pet window (owner 2026-10-10, from the later client - "1.65
	# EXCEPTIONS MADE.txt"); Options > WINDOWS > PET BUFFS turns it off
	_pet_buffs = Control.new()
	_pet_buffs.position = Vector2(0, 126)
	_pet_buffs.size = Vector2(128, 26)
	_pet_buffs.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var holder := Control.new()
	holder.scale = Vector2(0.25, 0.25)
	holder.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var np := NinePatchRect.new()
	np.texture = UiArt.tex("chatext")
	np.region_rect = Rect2(0, 64 * UiArt.K, 512 * UiArt.K, 64 * UiArt.K)
	for side in [[SIDE_LEFT, 3], [SIDE_TOP, 4], [SIDE_RIGHT, 4], [SIDE_BOTTOM, 3]]:
		np.set_patch_margin(side[0], int(side[1] * UiArt.K))
	np.size = _pet_buffs.size * 4.0
	np.mouse_filter = Control.MOUSE_FILTER_IGNORE
	holder.add_child(np)
	_pet_buffs.add_child(holder)
	_pet_icons = HBoxContainer.new()
	_pet_icons.position = Vector2(4, 3)
	_pet_icons.add_theme_constant_override("separation", 1)
	_pet_icons.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_pet_buffs.add_child(_pet_icons)
	w.add_child(_pet_buffs)
	_pet_buffs.visible = bool(_saved("windows", "pet_buffs", true))
	PlayerData.hook(self, PlayerData.pet_changed, func():
		if PlayerData.pet.is_empty():
			w.hide_window()
		else:
			(w.get_node("PetName") as Label).text = String(PlayerData.pet.get("name", "")).to_upper()
			w.show_window())


## A greyscale (and dimmed) version of a texture: a bar with nothing behind it.
static var _grey: ShaderMaterial


static func _grey_material() -> ShaderMaterial:
	if _grey == null:
		var sh := Shader.new()
		sh.code = "shader_type canvas_item;\nvoid fragment() {\n\tvec4 c = texture(TEXTURE, UV) * COLOR;\n" \
				+ "\tfloat l = dot(c.rgb, vec3(0.299, 0.587, 0.114)) * 0.7;\n\tCOLOR = vec4(vec3(l), c.a);\n}\n"
		_grey = ShaderMaterial.new()
		_grey.shader = sh
	return _grey


func _saved(section: String, key: String, def):
	var cfg := ConfigFile.new()
	cfg.load(UiArt.settings_path)
	return cfg.get_value(section, key, def) if cfg.has_section_key(section, key) else def


## A message for the chat boxes: each box shows it if that message type is switched on for it.
func message(text: String, kind := "system") -> void:
	for c in [chat_combat, chat]:
		if c:
			c.add_line(text, kind)


## The information window for an item (shift-click on it).
## The death window. 1.65 had one way back: release to your bind point (period FAQ: "releasing ... are returned to
## your bind point"); the later client's city / house choices came with New Frontiers and house teleports (1.68),
## so they are left out. Same stone frame and buttons as the rest of the UI (no period picture of it survives).
func _build_release() -> void:
	var w := ClassicWindow.new()
	w.resizable = true
	w.patch = [6, 19, 13, 33]
	w.size = Vector2(200, 112)
	var at := Vector2(area().x * 0.5 - 100, area().y * 0.32)
	w.setup("release", "interact", Rect2(), at)
	w.closable = false
	root.add_child(w)
	windows["release"] = w
	w.visible = false
	var title := UiArt.label("YOU HAVE DIED", 11, UiArt.GOLD_HI)
	title.position = Vector2(12, 21)
	title.size = Vector2(173, 16)
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	w.add_child(title)
	var text := UiArt.label("RELEASE TO RETURN TO YOUR BIND POINT.", 8, UiArt.CREAM)
	text.position = Vector2(12, 40)
	text.size = Vector2(173, 14)
	text.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	w.add_child(text)
	var b := UiArt.button("RELEASE", Vector2(90, 18), 10)
	b.position = Vector2(54, 58)
	b.pressed.connect(func(): PlayerData.release_requested.emit())
	w.add_child(b)
	# the old server's "Release Timer" (SendTimerWindow, RELEASE_TIME): the automatic release counting down
	var timer := UiArt.label("", 8, UiArt.CREAM)
	timer.position = Vector2(12, 82)
	timer.size = Vector2(173, 14)
	timer.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	w.add_child(timer)
	PlayerData.hook(self, PlayerData.release_timer, func(left: float):
		timer.text = "" if left < 0.0 else "RELEASE TIMER  %d:%02d" % [int(left) / 60, int(left) % 60])


## The cast bar over the quickbars (fills for the cast time) and the effects bar (the player's buffs / debuffs:
## icon + border, seconds left on hover) under the status panel.
func _build_cast_bar() -> void:
	_cast_bar = Control.new()
	_cast_bar.size = Vector2(160, 14)
	_cast_bar.position = Vector2(area().x * 0.5 - 80, area().y - 110)
	_cast_bar.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_cast_bar.visible = false
	root.add_child(_cast_bar)
	var bg := ColorRect.new()
	bg.color = Color(0.05, 0.05, 0.05, 0.85)
	bg.size = _cast_bar.size
	_cast_bar.add_child(bg)
	_cast_fill = ColorRect.new()
	_cast_fill.color = Color(0.85, 0.65, 0.25)
	_cast_fill.position = Vector2(1, 1)
	_cast_fill.size = Vector2(0, 12)
	_cast_bar.add_child(_cast_fill)
	_cast_name = UiArt.label("", 8, UiArt.CREAM)
	_cast_name.size = _cast_bar.size
	_cast_name.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_cast_name.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_cast_bar.add_child(_cast_name)
	# the client's spell effect icons: top left (default800.ini SpellEffect=10,4), each with its time left
	_effects_bar = HBoxContainer.new()
	_effects_bar.position = client_pos(10, 4)
	_effects_bar.add_theme_constant_override("separation", 4)
	_effects_bar.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(_effects_bar)
	PlayerData.effects_changed.connect(_refresh_effects)
	PlayerData.changed.connect(func():                      # constitution lost / restored shows or hides its icon
		if (PlayerData.con_lost > 0) != _con_icon_shown:
			_refresh_effects()
		_stats_dirty = true)
	PlayerData.effects_changed.connect(func(): _stats_dirty = true)
	_refresh_effects()


func show_cast(spell_name: String, frac: float) -> void:
	# owner 2026-10-10: the 1.65 client had no cast bar - the casting animation is the only cue. Kept built (hidden).
	if true or frac < 0.0:
		_cast_bar.visible = false
		return
	_cast_bar.visible = true
	_cast_name.text = spell_name.to_upper()
	_cast_fill.size.x = (_cast_bar.size.x - 2) * clampf(frac, 0.0, 1.0)


## The effect icons: your timed spell effects, and constitution lost at death (the client's Constitution debuff
## icon, 50, until a healer restores it). Under each timed one its time left (owner 2026-10-10, as the old client
## showed it); in its last ten seconds the icon blinks (patch notes, 13 Sep 2001: "Effect icons now blink for ten
## seconds before they go away").
var _con_icon_shown := false
var _effect_rows: Array = []                 # [icon TextureRect, time Label, effect index or -1]


func _refresh_effects() -> void:
	for c in _effects_bar.get_children():
		c.queue_free()
	_effect_rows.clear()
	_con_icon_shown = PlayerData.con_lost > 0
	if _con_icon_shown:
		_effect_box(50, 0, "CONSTITUTION LOST: %d (A HEALER CAN RESTORE IT)" % PlayerData.con_lost, -1)
	var effs := _player_effects()
	for i in effs.size():
		_effect_box(int(effs[i].icon), int(effs[i].border), String(effs[i].name).to_upper(), i, int(effs[i].get("fx", -1)))
	_tick_effects()


## Your effects: the server's list (UpdateIcons) when the server is the game, else the game's own spells.
func _player_effects() -> Array:
	if Server.active:
		return Server.effects_list()
	return casting.player_effects() if casting else []


const EFFECT_ICON := 32.0                     # px (the client's 20; owner 2026-10-10: "make the spell icons bigger")


## An effect icon: hovering one shows what it does - the server's delve of it (DetailRequest 5, asked when the pointer
## reaches it; owner 2026-10-14: "hovering over buffs and debuffs doesn't tell you anything"), else its name.
class EffectBox extends Control:
	var fx := -1
	var title := ""

	func _notification(what: int) -> void:
		if what == NOTIFICATION_MOUSE_ENTER and Server.active and fx > 0:
			Server.prefetch_effect(fx, title)

	func _make_custom_tooltip(_for_text: String) -> Object:
		if not Server.active or fx <= 0:
			return null
		var d := Server.effect_lines(fx)
		return null if d.is_empty() else ItemTooltip.text_box(String(d.caption), d.lines)


func _effect_box(icon: int, border: int, tip: String, index: int, fx := -1) -> void:
	var box := EffectBox.new()
	box.fx = fx
	box.title = tip
	box.custom_minimum_size = Vector2(EFFECT_ICON, EFFECT_ICON + 12)
	box.tooltip_text = tip
	box.mouse_filter = Control.MOUSE_FILTER_PASS
	var ic := TextureRect.new()
	ic.texture = ItemDb.icon(icon)
	ic.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	ic.size = Vector2(EFFECT_ICON, EFFECT_ICON)
	ic.mouse_filter = Control.MOUSE_FILTER_IGNORE
	box.add_child(ic)
	if border >= 0:
		var b := TextureRect.new()
		b.texture = ItemDb.border(border)
		b.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		b.size = Vector2(EFFECT_ICON, EFFECT_ICON)
		b.mouse_filter = Control.MOUSE_FILTER_IGNORE
		ic.add_child(b)
	var t := UiArt.label("", 8, UiArt.CREAM)
	t.position = Vector2(-8, EFFECT_ICON)
	t.size = Vector2(EFFECT_ICON + 16, 12)
	t.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	t.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 1))
	t.add_theme_constant_override("shadow_offset_x", 1)
	t.add_theme_constant_override("shadow_offset_y", 1)
	box.add_child(t)
	_effects_bar.add_child(box)
	_effect_rows.append([ic, t, index])


func _tick_effects() -> void:
	if _effect_rows.is_empty():
		return
	var effs := _player_effects()
	var blink := int(Time.get_ticks_msec() / 250) % 2 == 0
	for row in _effect_rows:
		var i: int = row[2]
		if i < 0 or i >= effs.size():
			continue
		var left := float(effs[i].seconds)
		(row[1] as Label).text = _time_left(left)
		(row[0] as TextureRect).modulate.a = 0.3 if left <= 10.0 and blink else 1.0


static func _time_left(sec: float) -> String:
	if sec <= 0.0 or sec > 1e8:                            # a concentration buff has no time limit
		return ""
	var s := ceili(sec)
	if s >= 3600:
		return "%dH" % (s / 3600)
	if s >= 60:
		return "%d:%02d" % [s / 60, s % 60]
	return "%dS" % s


## The QUEST GUIDE window (interact.bmp nine-patch): a quest's period Allakhazam walkthrough (QuestDb guides) with
## its source line, as the 0.35 OfflineDAoC showed it; quests without one say so.
func _build_guide() -> void:
	guide = ClassicWindow.new()
	guide.resizable = true
	guide.patch = [6, 19, 13, 33]
	guide.min_size = Vector2(220, 140)
	guide.size = Vector2(380, 340)
	guide.setup("guide", "interact", Rect2(), client_pos(330, 60))
	_add(guide, client_pos(330, 60), false)
	guide.visible = false
	var title := UiArt.label("QUEST GUIDE", 11, UiArt.GOLD_HI)
	title.name = "Title"
	title.position = Vector2(12, 21)
	title.size = Vector2(340, 16)
	title.clip_text = true
	guide.add_child(title)
	var body := RichTextLabel.new()
	body.name = "Body"
	body.position = Vector2(12, 40)
	body.size = Vector2(350, 260)
	body.bbcode_enabled = true
	body.add_theme_font_override("normal_font", UiArt.font(false))
	body.add_theme_font_size_override("normal_font_size", 10)
	body.add_theme_color_override("default_color", UiArt.CREAM)
	body.add_theme_font_override("bold_font", UiArt.font(true))
	body.add_theme_font_size_override("bold_font_size", 10)
	UiArt.themed(body)
	guide.add_child(body)
	# the text follows the window when it is resized
	body.anchor_right = 1.0
	body.anchor_bottom = 1.0
	body.offset_right = -18.0
	body.offset_bottom = -40.0
	title.anchor_right = 1.0
	title.offset_right = -40.0


func show_guide(quest_id: String) -> void:
	var q := QuestDb.quest(quest_id) if quest_id != "" else {}
	var body := guide.get_node("Body") as RichTextLabel
	(guide.get_node("Title") as Label).text = ("QUEST GUIDE - " + String(q.get("name", ""))).to_upper() if not q.is_empty() else "QUEST GUIDE"
	var lines := ["[color=#9a9184]Period-accurate Allakhazam quest guide information (2001-2004).[/color]", ""]
	if q.is_empty():
		lines.append("You have no active quests. Accept a quest and click QUEST GUIDE again.")
	else:
		var g := QuestDb.guide(String(q.name))
		if g.is_empty():
			lines.append("There is no period guide for this quest. Your journal:")
			lines.append("")
			var steps: Array = q.get("steps", [])
			var n := int(PlayerData.quests.get(quest_id, {}).get("step", 1))
			lines.append(String(steps[n - 1].get("text", "")) if n >= 1 and n <= steps.size() else "")
		else:
			for l in g.get("lines", []):
				lines.append(str(l))
				lines.append("")
			var upd = g.get("updated")                  # may be null (the journal-steps stand-ins): str(), never String()
			lines.append("[color=#9a9184]%s%s[/color]" % [str(g.get("source", "")), ("   (last updated %s)" % str(upd)) if upd != null and str(upd) != "" else ""])
	body.text = "\n".join(lines)
	body.scroll_to_line(0)
	guide.show_window()


## 0.36c: a page of the server's QUEST GUIDE (QuestGuide.cs, /task and the journal's button) in the guide window -
## the quest and page in the title, the walkthrough as paragraphs (each numbered step its own, lines the period page
## broke mid-sentence joined back), the source notes and the paging hint in grey at the bottom (owner 2026-10-11: the
## page in the small information window ran off its bottom).
func show_server_guide(lines: Array) -> void:
	var esc := func(t: String) -> String: return t.replace("[", "[lb]")
	var title := "QUEST GUIDE"
	var notes: Array = []
	var body_lines: Array = []
	var page_re := RegEx.create_from_string("^(.*) - page ([0-9]+) of ([0-9]+)$")
	var step_re := RegEx.create_from_string("^([0-9]+)[).:] *(.*)$")
	var first := true
	for raw in lines:
		var l := String(raw).strip_edges()
		if first and l != "":
			first = false
			var m := page_re.search(l)
			if m:
				title = "QUEST GUIDE - %s  (PAGE %s OF %s)" % [m.get_string(1).to_upper(), m.get_string(2), m.get_string(3)]
				continue
		var low := l.to_lower()
		if low.begins_with("period-accurate") or low.begins_with("source:") or low.begins_with("walkthrough last updated") \
				or low.begins_with("click quest guide") or low.begins_with("quest guide information") \
				or low.begins_with("(2001") or low.begins_with("as archived") or low.begins_with("(wayback"):
			notes.append(l)
			continue
		if not notes.is_empty() and body_lines.is_empty() and l != "" and not step_re.search(l) and low != "steps:" \
				and (notes[-1] as String).length() > 0 and not (notes[-1] as String).ends_with(".") \
				and l.substr(0, 1) == l.substr(0, 1).to_lower() and l.substr(0, 1) != l.substr(0, 1).to_upper():
			notes[-1] = String(notes[-1]) + " " + l            # a note's own wrapped line
			continue
		body_lines.append(l)
	var out: Array = []
	for item in body_lines:
		var l := String(item)
		if l == "":
			if not out.is_empty() and String(out[-1]) != "":
				out.append("")
			continue
		var m := step_re.search(l)
		if m:                                              # a numbered step: its own paragraph, number in bold
			if not out.is_empty() and String(out[-1]) != "":
				out.append("")
			out.append("[b]%s)[/b] %s" % [m.get_string(1), esc.call(m.get_string(2))])
			continue
		var lead := l.substr(0, 1)
		var lower_start := lead == lead.to_lower() and lead != lead.to_upper()
		if lower_start and not out.is_empty() and String(out[-1]) != "" \
				and not String(out[-1]).ends_with(".") and not String(out[-1]).ends_with(":"):
			out[-1] = String(out[-1]) + " " + esc.call(l)     # the period page's mid-sentence line break
			continue
		if l.ends_with(":"):                               # a heading (Steps:, Rewards:)
			if not out.is_empty() and String(out[-1]) != "":
				out.append("")
			out.append("[b]%s[/b]" % esc.call(l.to_upper()))
			continue
		out.append(esc.call(l))
	if not notes.is_empty():
		out.append("")
		for n in notes:
			out.append("[color=#9a9184]%s[/color]" % esc.call(String(n)))
	(guide.get_node("Title") as Label).text = title
	var body := guide.get_node("Body") as RichTextLabel
	body.text = "\n".join(out)
	body.scroll_to_line(0)
	guide.show_window()


func show_release(on: bool) -> void:
	var w: ClassicWindow = windows.get("release")
	if w:
		w.visible = on


## The server's screen-centre lines (CT_ScreenCenter 0xC8 / ...Smaller 0xC9, and the "_And_CT_System" pair also in
## the chat): quest goal progress ("...: 2/5"), quests completed, realm event announcements ("Realm-wide one-line
## announcements at the top of the screen", RealmEventNotices), area descriptions as you enter. The client shows them
## in the upper middle of the screen, a few seconds each, the newest under the older ones. They went nowhere before
## (owner 2026-10-15: no quest kill progress on screen, no realm announcements).
const CENTER_SECONDS := 5.0
const CENTER_LINES := 4
var _center_box: VBoxContainer


func center_message(text: String, small := false) -> void:
	text = text.strip_edges()
	if text == "" or root == null:
		return
	if _center_box == null or not is_instance_valid(_center_box):
		_center_box = VBoxContainer.new()
		_center_box.mouse_filter = Control.MOUSE_FILTER_IGNORE
		_center_box.alignment = BoxContainer.ALIGNMENT_BEGIN
		_center_box.add_theme_constant_override("separation", 2)
		root.add_child(_center_box)
	var a := area()
	_center_box.position = Vector2(a.x * 0.15, a.y * 0.16)
	_center_box.size = Vector2(a.x * 0.7, 0)
	for c in _center_box.get_children():                  # the same line again: shown afresh, not twice
		if c is Label and (c as Label).text == text.to_upper():
			c.queue_free()
	var l := UiArt.label(text, 11 if small else 15, UiArt.CREAM if small else UiArt.GOLD_HI)
	l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	l.custom_minimum_size = Vector2(a.x * 0.7, 0)
	l.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.85))
	l.add_theme_constant_override("outline_size", 3)
	_center_box.add_child(l)
	while _center_box.get_child_count() > CENTER_LINES:
		var old := _center_box.get_child(0)
		_center_box.remove_child(old)
		old.queue_free()
	var tw := l.create_tween()
	tw.tween_interval(CENTER_SECONDS - 1.0)
	tw.tween_property(l, "modulate:a", 0.0, 1.0)
	tw.tween_callback(l.queue_free)


func show_info(it: Dictionary, full := true) -> void:
	var w: ClassicWindow = windows.info
	(w.get_node("Title") as Label).text = String(it.get("name", "")).to_upper()
	var body := w.get_node("Body") as RichTextLabel
	body.text = "\n".join(ItemDb.delve(it) if full else ItemDb.summary(it))
	_fit_info(w, body)


## Lines of text in the information window under a title (the /task snapshot).
func show_lines(title: String, lines: Array) -> void:
	var w: ClassicWindow = windows.info
	(w.get_node("Title") as Label).text = title.to_upper()
	var body := w.get_node("Body") as RichTextLabel
	body.text = "
".join(lines)
	_fit_info(w, body, INFO_W if lines.all(func(l): return String(l).length() <= 34) else INFO_WIDE)


## The information window around its text: as tall as the text, at most the screen below the window - a longer text
## (the server's /stables pages, owner 2026-10-15: "cut off in the box") scrolls inside it, and a resize by hand
## keeps the scroll.
func _fit_info(w: ClassicWindow, body: RichTextLabel, width := INFO_W) -> void:
	(w.get_node("Title") as Label).size.x = width - 27
	body.size = Vector2(width - 27, 20)
	body.fit_content = true
	body.scroll_active = false
	w.show_window()
	await get_tree().process_frame                        # the text's height, then the window fits around it
	var full := body.position.y + body.get_content_height() + 8 + 33
	var room := (w.get_parent_area_size().y - w.position.y) / maxf(w.scale.y, 0.01) - 8.0
	var cap := minf(w.max_size.y, maxf(room, w.min_size.y))
	if full <= cap:
		w.set_window_size(Vector2(width, full))
		return
	w.set_window_size(Vector2(width, cap))
	_info_scroll(w, body)


func _info_scroll(w: ClassicWindow, body: RichTextLabel) -> void:
	body.fit_content = false
	body.scroll_active = true
	body.size = Vector2(w.size.x - 27, maxf(w.size.y - body.position.y - 8 - 33, 20))
	body.scroll_to_line(0)

## A spell / style / ability's information in the information window (SkillInfo: the old DelveInfo lines).
func show_skill_info(entry: Dictionary) -> void:
	if Server.active:
		return                         # the server's own text (ZoneViewer._server_skill_info); the game's spell table
								# read a server spell's place as one of its own ids (owner 2026-10-14: Fungal Pin
								# showed a buff)
	var w: ClassicWindow = windows.info
	(w.get_node("Title") as Label).text = String(entry.get("name", "")).to_upper()
	var body := w.get_node("Body") as RichTextLabel
	body.text = "
".join(SkillInfo.lines(entry))
	_fit_info(w, body)


## Options > WINDOWS: put a closed window back where it was.
func restore_window(id: String) -> void:
	if windows.has(id):
		windows[id].show_window()


## Options > WINDOWS > RESET: every window back to its default place and default open / closed state.
func reset_layout() -> void:
	for id in defaults:
		var w: ClassicWindow = windows[id]
		w.position = defaults[id][0]
		w.visible = defaults[id][1]
		w.save_position()


func show_sheet(tab: String) -> void:
	_tab_clicked(tab)


## A sheet's tab (or its key): the open sheet folds away, leaving the strip of six tabs (the old client's way - the
## bar never goes); another tab, or the folded one, opens that sheet.
func _tab_clicked(tab: String) -> void:
	if right_panel.visible and sheet_tab == tab and not _collapsed:
		_collapse(true)
		return
	if sheet_tab != tab:
		_set_sheet(tab)
	_collapse(false)
	right_panel.show_window()


var _collapsed := false
const STRIP_H := 32.0
const PANEL_H := 448.0


func _collapse(on: bool) -> void:
	_collapsed = on
	_sheet_bg.visible = not on
	_sheet_body.visible = not on
	if right_panel.frame:
		right_panel.frame.visible = not on                  # (the window's own stone backing - owner: a grey block stayed)
	for i in TABS.size():
		_tab_lit[i].visible = (not on) and TABS[i] == sheet_tab
	right_panel.size.y = STRIP_H if on else PANEL_H         # (folded: the world under it takes the clicks)
	var cfg := ConfigFile.new()
	cfg.load(UiArt.settings_path)
	cfg.set_value("interface", "sheet_collapsed", on)
	cfg.save(UiArt.settings_path)


func _set_sheet(tab: String) -> void:
	if not SHEETS.has(tab):
		tab = "character"
	sheet_tab = tab
	_sheet_bg.texture = UiArt.tex(SHEETS[tab])
	var skin := "control"                                  # one tab strip (cyan) for every sheet, the inventory too (owner)
	_strip.texture = UiArt.region(skin, Rect2(0, 0, 192, 32))
	for i in TABS.size():
		_tab_lit[i].texture = UiArt.region(skin, Rect2(TAB_X[i], 96 + 3, TAB_W[i], 24))
		_tab_hover[i].texture = UiArt.region(skin, Rect2(TAB_X[i], 32 + 3, TAB_W[i], 24))
		_tab_lit[i].visible = TABS[i] == tab and not _collapsed
	for c in _sheet_body.get_children():
		c.queue_free()
	match tab:
		"character": CharacterSheet.build(_sheet_body)
		"inventory": InventorySheet.build(_sheet_body, self)
		_: PanelSheets.build(_sheet_body, tab)
	var cfg := ConfigFile.new()
	cfg.load(UiArt.settings_path)
	cfg.set_value("interface", "sheet", tab)
	cfg.save(UiArt.settings_path)


func _refresh() -> void:
	_status_name.text = PlayerData.display_name().to_upper()
	for k in _status_bars:
		var frac: float = PlayerData.get(k)
		_status_bars[k][0].size.x = _status_bars[k][1] * clampf(frac, 0.0, 1.0)
	var xp := clampf(PlayerData.exp_frac, 0.0, 1.0) * 10.0
	var lit := int(xp)
	if lit != _jewels_lit:
		_jewels_lit = lit
		for i in 10:
			_jewels[i].texture = UiArt.region("expjwl_full" if i < lit else "expjwl_bg", Rect2(i * 12.8, 0, 12.8, 16))
	_bubble_bar.size.x = 90.0 * (xp - float(lit))           # this bubble's share


func _refresh_target() -> void:
	var t := PlayerData.target
	_target_name.text = String(t.get("name", "")).to_upper()
	_target_name.add_theme_color_override("font_color", t.get("con_color", UiArt.CREAM))
	_target_bar.visible = not t.is_empty()
	_target_bar.size.x = 98.0 * clampf(float(t.get("health", 1.0)), 0.0, 1.0)
	_target_pct.text = "" if t.is_empty() else "%d" % roundi(100.0 * float(t.get("health", 1.0)))


var _pet_bar: TextureRect
var _pet_buffs: Control
var _pet_icons: HBoxContainer
var _pet_sig := ""


## The pet buff strip: up to 7 icons (14 px) with the time left in small type.
func _tick_pet_buffs() -> void:
	if _pet_buffs == null or not _pet_buffs.is_visible_in_tree():
		return
	var effs: Array = Server.pet_effects_list() if Server.active else (casting.pet_effects() if casting else [])
	var sig := ",".join(effs.map(func(e): return "%s%d" % [String(e.name), int(e.icon)]))
	if sig != _pet_sig:
		_pet_sig = sig
		for c in _pet_icons.get_children():
			c.queue_free()
		for e in effs.slice(0, 7):
			var box := Control.new()
			box.custom_minimum_size = Vector2(16, 20)
			box.tooltip_text = String(e.name).to_upper()
			box.mouse_filter = Control.MOUSE_FILTER_PASS
			var ic := TextureRect.new()
			ic.texture = ItemDb.icon(int(e.icon))
			ic.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
			ic.size = Vector2(14, 14)
			ic.position = Vector2(1, 0)
			ic.mouse_filter = Control.MOUSE_FILTER_IGNORE
			box.add_child(ic)
			var t := UiArt.label("", 5, UiArt.CREAM)
			t.name = "T"
			t.position = Vector2(-4, 13)
			t.size = Vector2(24, 7)
			t.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
			box.add_child(t)
			_pet_icons.add_child(box)
	var blink := int(Time.get_ticks_msec() / 250) % 2 == 0
	for i in mini(effs.size(), _pet_icons.get_child_count()):
		var box: Control = _pet_icons.get_child(i)
		var left := float(effs[i].seconds)
		(box.get_node("T") as Label).text = _time_left(left)
		box.modulate.a = 0.3 if left <= 10.0 and blink else 1.0


## Options > WINDOWS > PET BUFFS.
func set_pet_buffs(on: bool) -> void:
	if _pet_buffs:
		_pet_buffs.visible = on
	var cfg := ConfigFile.new()
	cfg.load(UiArt.settings_path)
	cfg.set_value("windows", "pet_buffs", on)
	cfg.save(UiArt.settings_path)


var _stats_dirty := false


func _process(_delta: float) -> void:
	var t0 := Time.get_ticks_usec()
	_process_inner(_delta)
	Perf.proc_add("ui", Time.get_ticks_usec() - t0)   # (the live log: process by part)


func _process_inner(_delta: float) -> void:
	_tick_effects()
	_tick_pet_buffs()
	_tick_conc()
	if not PlayerData.self_effects.is_valid() and (casting or Server.active):
		PlayerData.self_effects = _player_effects          # the group page's own effects too
	if Engine.get_process_frames() % 10 == 0:              # the group windows' live bars
		_tick_minigroup()
		_tick_benefits()
		if sheet_tab == "group" and _sheet_body and _sheet_body.is_visible_in_tree():
			PanelSheets.update_group(_sheet_body)
	if _stats_dirty and Engine.get_process_frames() % 15 == 0:   # the character sheet follows buffs / losses
		_stats_dirty = false
		if sheet_tab == "character" and _sheet_body and _sheet_body.is_visible_in_tree():
			for c in _sheet_body.get_children():
				c.queue_free()
			CharacterSheet.build(_sheet_body)
	if _pet_bar:                                           # the pet's health (Pets keeps PlayerData.pet.health)
		var no_pet := PlayerData.pet.is_empty()
		# no pet summoned: the bar full and greyed out (owner 2026-10-11)
		_pet_bar.size.x = 112.0 * (1.0 if no_pet else clampf(float(PlayerData.pet.get("health", 1.0)), 0.0, 1.0))
		var want: Material = _grey_material() if no_pet else null
		if _pet_bar.material != want:
			_pet_bar.material = want
	if player and _compass_letters:
		# 512 px strip = N NE E SE S SW W NW at 64 px each, shown at 256 units: 32 units per 45 degrees, N at 16
		var yaw: float = player.get("char_yaw") if player.get("char_yaw") != null else 0.0
		var heading := fposmod(-rad_to_deg(yaw), 360.0)          # 0 = north, 90 = east
		var x := 16.0 + heading / 360.0 * 256.0                  # where the heading sits on one copy
		_compass_letters.position.x = 54.0 - 256.0 - x
	if _clock:
		if sky and sky.has_method("clock_text"):
			_clock.text = String(sky.clock_text()).to_upper()
		else:
			var t := Time.get_time_dict_from_system()
			_clock.text = "%02d:%02d" % [t.hour, t.minute]


func _unhandled_input(event: InputEvent) -> void:
	if (event is InputEventKey and event.pressed and not event.echo) or (event is InputEventMouseButton and event.pressed):
		if handle_input(event):
			get_viewport().set_input_as_handled()


## Window keys (Keybinds) and Esc (options open / close; it never closes the character panel).
func handle_input(event: InputEvent) -> bool:
	if (chat and chat.typing()) or (options and options.capturing()):
		return false
	if get_viewport().gui_get_focus_owner() is LineEdit:    # typing in a text box (the exchange's search name ...)
		return false
	for w in [["weapon_right", "standard"], ["weapon_two_hand", "twohand"], ["weapon_ranged", "ranged"]]:
		if Keybinds.pressed(event, w[0]):
			PlayerData.set_active_weapon(w[1])
			return true
	if Keybinds.pressed(event, "show_journal") and journal:
		journal.toggle_window()
		return true
	if Keybinds.pressed(event, "show_map") and map_window:
		map_window.player = player
		map_window.toggle_window()
		return true
	for action in SHOW_ACTIONS:
		if Keybinds.pressed(event, action):
			show_sheet(SHOW_ACTIONS[action])
			return true
	if Keybinds.pressed(event, "delve") and merchant and merchant.visible and PlayerData.delve_id != "":
		show_info(ItemDb.item(PlayerData.delve_id))
		return true
	if Keybinds.pressed(event, "delve") and PlayerData.selected_slot >= 0:
		show_info(PlayerData.item_at(PlayerData.selected_slot))
		return true
	if Keybinds.pressed(event, "sell") and merchant and merchant.visible and get_viewport().gui_is_dragging() 			and InventorySheet.is_item(get_viewport().gui_get_drag_data()):
		# the item held up with the left button (owner 2026-10-11: pick it up, Shift+S - it sold in the old client)
		var held := int(get_viewport().gui_get_drag_data().slot)
		get_viewport().gui_cancel_drag()
		PlayerData.sell(held, merchant.npc_name)
		return true
	if Keybinds.pressed(event, "sell") and merchant and merchant.visible and PlayerData.selected_slot >= 0:
		PlayerData.sell(PlayerData.selected_slot, merchant.npc_name)
		return true
	if Keybinds.pressed(event, "use_item") and PlayerData.selected_slot >= 0:
		var it := PlayerData.item_at(PlayerData.selected_slot)
		if PlayerData.is_backpack(PlayerData.selected_slot) and not PlayerData.slots_for(it).is_empty():
			PlayerData.equip(PlayerData.selected_slot)
		elif Server.active and not it.is_empty():
			# the server's use (GamePlayer.UseSlot): a poison onto the readied weapon, a potion drunk, a charge used
			# (owner 2026-10-15: poisons - U on one did nothing on the server)
			Server.use("srv:%d" % PlayerData.selected_slot)
		elif PlayerData.is_backpack(PlayerData.selected_slot) and not it.is_empty():
			PlayerData.item_used.emit(String(PlayerData.entry(PlayerData.selected_slot).id))   # quest items: use_item steps
		elif not it.is_empty():
			PlayerData.message.emit("You can't use the %s." % it.get("name", "item"), "error")
		return true
	if Keybinds.pressed(event, "show_compass"):
		windows.compass.toggle_window()
		return true
	# Alt+Z as well, whatever Toggle Interface is bound to (owner 2026-10-15: the old client hid the interface on Alt+Z)
	if Keybinds.pressed(event, "toggle_interface") or (event is InputEventKey and event.pressed and not event.echo
			and event.alt_pressed and not event.ctrl_pressed and event.physical_keycode == KEY_Z):
		hidden_all = not hidden_all
		root.visible = not hidden_all
		return true
	if Keybinds.pressed(event, "chat") or (event is InputEventKey and event.pressed and event.keycode == KEY_ENTER):
		chat.start_typing()
		return true
	if Keybinds.pressed(event, "reply"):
		chat.start_typing("/r ")
		return true
	for sc in [["chat_page_up", -1], ["chat_page_down", 1]]:
		if Keybinds.pressed(event, sc[0]):
			chat.scroll(sc[1])
			return true
	for bar in 3:
		for slot in 10:
			if Keybinds.pressed(event, "qb%d_%d" % [bar + 1, slot + 1]):
				quickbars[bar].use_slot(slot)
				return true
	for bank in 10:                                        # Shift+1-0: quickbar 1's bank (patch 1.54)
		if Keybinds.pressed(event, "qbank_%d" % (bank + 1)):
			quickbars[0].set_bank(bank)
			return true
	if event is InputEventKey and event.pressed and event.keycode == KEY_ESCAPE:
		# owner (checked in the client): Esc untargets. Open options close first; with nothing targeted, Esc opens them
		if not options.visible and not PlayerData.target.is_empty() and clear_target.is_valid():
			clear_target.call()
		else:
			options.toggle_window()
		return true
	return false



## The world behind the windows as a drop target, only while something is being dragged (otherwise it lets every
## click through): an inventory item let go over the world goes to the zone viewer, which finds the NPC under the
## cursor - a smith repairs it ("[Give Smith an item to be repaired]"), a merchant buys it.
class WorldDrop extends Control:
	var ui: GameUI

	func _ready() -> void:
		set_anchors_preset(Control.PRESET_FULL_RECT)
		mouse_filter = Control.MOUSE_FILTER_IGNORE

	func _notification(what: int) -> void:
		if what == NOTIFICATION_DRAG_BEGIN:
			mouse_filter = Control.MOUSE_FILTER_STOP
		elif what == NOTIFICATION_DRAG_END:
			mouse_filter = Control.MOUSE_FILTER_IGNORE

	func _can_drop_data(_pos: Vector2, data: Variant) -> bool:
		return InventorySheet.is_item(data)

	func _drop_data(_pos: Vector2, data: Variant) -> void:
		ui.item_dropped_on_world.emit(int(data.slot), get_viewport().get_mouse_position())
