# scripts/ui/hud.gd
# M-16 HUD（架构 §2.15）：HP/经验/等级/波次/击杀/计时 + 词条栏（构筑统计）+ 波次 toast。
# 方向 C「晴空糖果」贴纸风：白胶囊 HP 条（纯渐变薄荷→柠檬→珊瑚）+ 经验星条 + 波次圆形
# 徽章 + 击杀/计时气泡 + 果冻波次 toast（lore 文案）。process_mode = ALWAYS（暂停/顿帧
# 期间 UI 照常，Q-14）；刷新 = 事件驱动 + 1Hz 兜底（架构 refresh_stats 口径：计时兜底走
# raw 通道 tick）。数值源：Player（HP/经验/等级/词条栏）+ wave_started / enemy_killed 事件。
class_name HUD
extends CanvasLayer

signal pause_requested()                      # 暂停按钮申请（→ GameLoop.request_pause 仲裁）
signal build_details_requested()              # 左下角构筑面板点击（→ 暂停 + buff 详情，用户反馈）

var player: Node2D = null                     # 注入（数值源；Player 宽类型规避循环解析）
var total_damage: float = 0.0                 # 造成的总伤害（damage_resolved 累计；结算屏数据源）

var _hp_fill: Panel = null                    # HP 条填充（比例缩放；圆角 StyleBoxFlat）
var _hp_fill_style: StyleBoxFlat = null       # 填充色随血量渐变（薄荷→柠檬→珊瑚）
var _hp_label: Label = null
var _xp_fill: Panel = null                    # 经验条填充
var _level_label: Label = null
var _wave_label: Label = null
var map_name: String = ""                  # 当前地图名（M2 多地图，HUD 波次前缀）
var _skill_btn: Button = null              # 角色技能键（右下角；冷却中置灰倒计时）
var _gold_label: Label = null                 # 金币（战地黑市货币，M7）
var _boss_banner: Label = null                # Boss 出场横幅（表现层一期）
var _kill_label: Label = null
var _time_label: Label = null
var _build_label: Label = null                # 构筑统计行（面板底行计数，延续原词条栏）
var _build_panel: Control = null              # 构筑面板（左下角：武器图标行 + 词条宝石行——用户反馈）
var _build_sig: String = ""                   # 构筑签名缓存（变化才重建，1Hz 兜底下的防抖）
var _shield_panel: Control = null             # 护盾条（MEC_SHIELD 持有时显示——用户反馈）
var _shield_fill: Panel = null
var _shield_fill_style: StyleBoxFlat = null
var _state_label: Label = null                # 状态提示（LEVEL_UP/PAUSED/GAME_OVER——测试锁定节点名）
var _toast_label: Label = null                # 波次 toast（果冻 pop + lore 文案）
var _toast_left: float = 0.0                  # toast 剩余展示时长（raw 通道）
var _pause_btn: Button = null                 # 暂停按钮（▶⏸ 图形化贴纸；仅 PLAYING 态显示）

var kills: int = 0
var wave: int = 0
var run_elapsed: float = 0.0                  # 计时（raw 通道累计——含顿帧，观感口径）
var _fallback_timer: float = 0.0              # 1Hz 兜底刷新

const HP_BAR_SIZE := Vector2(340.0, 30.0)
const XP_BAR_SIZE := Vector2(292.0, 14.0)
const TOAST_TIME := 1.7                       # 波次 toast 展示时长 s
const TOAST_FADE := 0.3                       # 末段淡出 s


func _ready() -> void:
	# ALWAYS：暂停/顿帧期间 UI 照常（Q-14）
	process_mode = Node.PROCESS_MODE_ALWAYS
	_build_ui()


func bind_events() -> void:
	# 订阅 player_hit / xp_gained / wave_started / enemy_killed / state_changed / damage_resolved
	EventBus.player_hit.connect(_on_player_hit)
	EventBus.xp_gained.connect(_on_xp_gained)
	EventBus.wave_started.connect(_on_wave_started)
	EventBus.enemy_killed.connect(_on_enemy_killed)
	EventBus.state_changed.connect(_on_state_changed)
	EventBus.damage_resolved.connect(_on_damage_resolved)
	EventBus.boss_spawned.connect(_on_boss_banner)
	Meta.achievements_changed.connect(_on_achievement_toast)   # 信号在 Meta（非 EventBus）
	EventBus.card_chosen.connect(_on_card_chosen_build)


func setup(p_player: Node2D) -> void:
	# 数值源注入
	player = p_player


func refresh_stats() -> void:
	# HP/经验/等级/波次/击杀/计时（事件驱动 + 1Hz 兜底刷新共用）
	if player != null and is_instance_valid(player):
		var hp: float = player.get("hp")
		var max_hp: float = player.get("max_hp")
		var pct := 0.0 if max_hp <= 0.0 else clampf(hp / max_hp, 0.0, 1.0)
		_hp_fill.size = Vector2(maxf((HP_BAR_SIZE.x - 8.0) * pct, 16.0), HP_BAR_SIZE.y - 8.0)
		_hp_fill_style.bg_color = PopPalette.hp_fill(pct)
		_hp_label.text = "HP %d/%d" % [int(round(hp)), int(round(max_hp))]
		var xp: float = player.get("xp")
		var need: float = player.get("xp_need")
		var xp_pct := 0.0 if need <= 0.0 else clampf(xp / need, 0.0, 1.0)
		_xp_fill.size = Vector2(maxf((XP_BAR_SIZE.x - 6.0) * xp_pct, 3.0), XP_BAR_SIZE.y - 6.0)
		_level_label.text = "Lv %d" % int(player.get("level"))
		_build_label.text = _build_summary()
		# 护盾条（MEC_SHIELD 持有才显示：就绪满条亮青；充能期按剩余比例灰蓝）
		var s_interval: float = player.get("shield_interval")
		_shield_panel.visible = s_interval > 0.0
		if s_interval > 0.0:
			var s_ready: bool = player.get("shield_ready")
			var s_timer: float = player.get("shield_timer")
			var s_pct := 1.0 if s_ready else clampf(1.0 - s_timer / maxf(s_interval, 0.01), 0.05, 1.0)
			_shield_fill.size = Vector2(maxf((148.0 - 6.0) * s_pct, 8.0), 36.0 - 6.0)
			_shield_fill_style.bg_color = PopPalette.PLAYER.lerp(
				PopPalette.INK_SOFT, 0.35 * (1.0 - s_pct)) if not s_ready else PopPalette.PLAYER
		var sig := _compute_build_sig()
		if sig != _build_sig:
			_build_sig = sig
			_refresh_build()
	_wave_label.text = ("%s · 第 %d 波" % [map_name, wave]) if map_name != "" \
		else "第 %d 波" % wave
	if _gold_label != null and player != null and is_instance_valid(player):
		_gold_label.text = "◎ %d" % int(player.get("gold"))
	if _skill_btn != null and player != null and is_instance_valid(player):
		var ready_now: bool = bool(player.call(&"skill_ready"))
		_skill_btn.disabled = not ready_now
		_skill_btn.modulate.a = 1.0 if ready_now else 0.55
		_skill_btn.text = "技能" if ready_now else "%ds" % ceili(float(player.get("skill_cd_left")))
	_kill_label.text = "击杀 %d" % kills
	_time_label.text = "%d:%02d" % [int(run_elapsed) / 60, int(run_elapsed) % 60]


func tick(p_raw_delta: float) -> void:
	# ①~⑧ 帧序 UI 阶段（raw 通道）：计时累计 + 1Hz 兜底刷新 + 波次 toast 衰减
	run_elapsed += p_raw_delta
	_fallback_timer += p_raw_delta
	if _fallback_timer >= 1.0:
		_fallback_timer = 0.0
		refresh_stats()
	if _toast_left > 0.0:
		_toast_left = maxf(_toast_left - p_raw_delta, 0.0)
		if _toast_left <= 0.0:
			_toast_label.visible = false
		elif _toast_left < TOAST_FADE:
			_toast_label.modulate.a = _toast_left / TOAST_FADE


# ── 测试观测口（displayed 值，headless 断言用——文本口径锁定，勿改） ──
func displayed_hp_text() -> String:
	return _hp_label.text


func displayed_wave() -> int:
	return wave


func displayed_kills() -> int:
	return kills


func displayed_level_text() -> String:
	return _level_label.text


# ── 事件 ──────────────────────────────────────────────────────────
func _on_player_hit(_p_damage: float, _p_source_uid: int) -> void:
	refresh_stats()


func _on_xp_gained(_p_amount: float) -> void:
	refresh_stats()


func _on_wave_started(p_wave: int) -> void:
	wave = p_wave
	_show_toast(Lore.wave_toast(p_wave))
	refresh_stats()


func _on_enemy_killed(_p_enemy: Node2D) -> void:
	kills += 1
	refresh_stats()


func _on_state_changed(p_state: int) -> void:
	# 状态提示（LEVEL_UP/PAUSED/GAME_OVER 覆盖显示；PLAYING 隐藏）+ 状态切换刷新
	# （升级→LEVEL_UP 的 state_changed 晚于 xp_gained——等级数值在此同步）
	match p_state:
		GameConst.GameStatus.LEVEL_UP:
			_state_label.text = "LEVEL UP - choose a card"   # 文案锁定（pkg4 断言）
			_state_label.visible = true
		GameConst.GameStatus.PAUSED:
			_state_label.text = "PAUSED"
			_state_label.visible = true
		GameConst.GameStatus.GAME_OVER:
			_state_label.text = "GAME OVER"
			_state_label.visible = true
		_:
			_state_label.visible = false
	_pause_btn.visible = p_state == GameConst.GameStatus.PLAYING
	if _skill_btn != null:
		_skill_btn.visible = p_state == GameConst.GameStatus.PLAYING   # 暂停按钮仅战斗态显示
	if p_state != GameConst.GameStatus.PLAYING:
		_toast_left = 0.0                     # 状态覆盖期收起波次 toast
		_toast_label.visible = false
	refresh_stats()


func set_map_name(p_name: String) -> void:
	# 地图名注入（GameLoop.start_run → HUD 波次前缀，M2 多地图）
	map_name = p_name


func _on_pause_pressed() -> void:
	# 暂停按钮回调（果冻 punch + 申请信号——仲裁权在 GameLoop）
	StickerTheme.press_punch(_pause_btn)
	pause_requested.emit()


func _on_skill_pressed() -> void:
	# 角色技能键（仲裁在 player.skill_ready；PLAYING 态才生效）
	if player != null and is_instance_valid(player) and bool(player.call(&"skill_ready")):
		player.call(&"activate_skill")


func _on_achievement_toast(p_ach_id: StringName) -> void:
	# 成就达成 toast（右上滑入：名称 + 结晶奖励——养成闭环反馈，M8）
	var reward := 10
	var aname := String(p_ach_id)
	for a in Meta.ACHIEVEMENTS:
		if a.id == p_ach_id:
			reward = int(a.get("reward", 10))
			aname = String(a.name)
			break
	var toast := StickerTheme.label_sticker(Label.new(), 17, PopPalette.GOLD, 4, Color.WHITE, true)
	toast.text = "🏆 成就达成：%s（+%d💎）" % [aname, reward]
	toast.position = Vector2(150.0, 300.0)
	toast.size = Vector2(420.0, 30.0)
	toast.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	toast.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(toast)                               # HUD 自身即 CanvasLayer 宿主
	var tw := toast.create_tween()
	tw.tween_property(toast, "position:y", 260.0, 0.25).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	tw.tween_interval(1.9)
	tw.tween_property(toast, "modulate:a", 0.0, 0.4)
	tw.tween_callback(toast.queue_free)


func _on_boss_banner(p_boss: Node2D) -> void:
	# Boss 出场横幅演出（表现层一期：弹入 → 停留 1.6s → 淡出）
	var ename := "未知聚合体"
	var d: Variant = p_boss.get("data")
	if d != null:
		ename = String(d.get("display_name"))
	_boss_banner.text = "⚠ %s 降临" % ename
	_boss_banner.visible = true
	_boss_banner.pivot_offset = _boss_banner.size * 0.5
	_boss_banner.scale = Vector2(1.6, 1.6)
	_boss_banner.modulate.a = 0.0
	var tw := _boss_banner.create_tween()
	tw.tween_property(_boss_banner, "scale", Vector2.ONE, 0.22)\
		.set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	tw.parallel().tween_property(_boss_banner, "modulate:a", 1.0, 0.18)
	tw.tween_interval(1.6)
	tw.tween_property(_boss_banner, "modulate:a", 0.0, 0.4)
	tw.tween_callback(func() -> void: _boss_banner.visible = false)


func _on_build_gui_input(p_ev: InputEvent) -> void:
	# 左下角构筑面板点击（左键按下即发——详情申请，GameLoop 仲裁暂停 + 详情模式）
	if p_ev is InputEventMouseButton and (p_ev as InputEventMouseButton).pressed \
			and (p_ev as InputEventMouseButton).button_index == MOUSE_BUTTON_LEFT:
		build_details_requested.emit()


func _on_damage_resolved(p_result: DamageResult) -> void:
	# 总伤害统计（结算屏数据源；HUD 不逐次刷新——1Hz 兜底承担）
	total_damage += p_result.final_value


func _build_summary() -> String:
	# 词条栏：武器数 + 武器词条数（构筑统计；正式构筑面板后续迭代）
	if player == null or not is_instance_valid(player):
		return "构筑 -"
	var slots: Array = player.get("weapon_slots")
	var wcount := 0
	var tcount := 0
	for w in slots:
		if w != null and is_instance_valid(w):
			wcount += 1
			var stack: Variant = w.get("trait_stack")
			if stack != null and stack.get("traits") != null:
				tcount += (stack.get("traits") as Array).size()
	return "构筑  W:%d T:%d" % [wcount, tcount]


func _on_card_chosen_build(_card_id: StringName, _target_kind: int) -> void:
	# 选卡应用 → 构筑面板强制重建（1Hz 兜底之外的即时响应）
	_build_sig = ""


func _compute_build_sig() -> String:
	# 构筑签名：武器 uid:level + 词条 id:layers（挂载序）——变化才重建面板
	if player == null or not is_instance_valid(player):
		return "-"
	var sig := ""
	var slots: Array = player.get("weapon_slots")
	for w in slots:
		if w != null and is_instance_valid(w):
			sig += "w%d:%d;" % [int(w.get("uid")), int(w.get("level"))]
			var stack: Variant = w.get("trait_stack")
			if stack != null and stack.get("traits") != null:
				for t: Variant in (stack.get("traits") as Array):
					var tb: Variant = t
					var td: Variant = tb.get("data")
					if td != null:
						sig += "t%s:%d;" % [String(td.get("id")), int(tb.get("layers"))]
	return sig


func _refresh_build() -> void:
	# 构筑面板重建：武器图标行（5 槽位含空槽态，Lv 角标）+ 词条宝石行（跨武器聚合挂载序）
	if _build_panel == null or player == null or not is_instance_valid(player):
		return
	for child in _build_panel.get_children():
		if child.name != "BuildBg":
			child.queue_free()
	var content := Control.new()
	content.name = "BuildContent"
	content.position = Vector2(10.0, 8.0)
	content.size = Vector2(232.0, 98.0)
	content.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_build_panel.add_child(content)
	# ① 武器图标行（5 槽：持有=武器图标+Lv 角标；空槽=描边圆环占位）
	var slots: Array = player.get("weapon_slots")
	var unlocked: int = int(player.get("unlocked_slots"))
	for i in range(5):
		var w: Variant = slots[i] if i < slots.size() else null
		var slot_x := float(i) * 46.0
		var icon := TextureRect.new()
		icon.name = "Wpn%d" % i
		icon.position = Vector2(slot_x, 0.0)
		icon.custom_minimum_size = Vector2(40.0, 40.0)
		icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
		if w != null and is_instance_valid(w):
			var wdata: Variant = w.get("data")
			icon.texture = TextureFactory.weapon_icon(
				StringName(str(wdata.get("id"))) if wdata != null else &"W_MISSING")
			content.add_child(icon)
			var lv := StickerTheme.label_sticker(Label.new(), 11, PopPalette.INK, 0, Color.WHITE, true)
			lv.text = "Lv%d" % int(w.get("level"))
			lv.size = Vector2(40.0, 13.0)
			lv.position = Vector2(slot_x, 40.0)
			lv.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
			content.add_child(lv)
		else:
			var locked := i >= unlocked
			icon.texture = TextureFactory.ring_tex(
				PopPalette.INK_SOFT if locked else PopPalette.INK_SOFT.lerp(Color.WHITE, 0.4),
				36, 2.6)
			icon.modulate.a = 0.35 if locked else 0.6
			content.add_child(icon)
	# ② 词条宝石行（跨武器聚合挂载序，最多 7 枚：类别章形 + ×层数）
	var gems: Array = []
	for w in slots:
		if w == null or not is_instance_valid(w):
			continue
		var stack: Variant = w.get("trait_stack")
		if stack == null or stack.get("traits") == null:
			continue
		for t: Variant in (stack.get("traits") as Array):
			var tb: Variant = t
			var td: Variant = tb.get("data")
			if td != null:
				gems.append({"pool": int(td.get("pool")), "layers": int(tb.get("layers")),
					"tid": StringName(str(td.get("id")))})
	for gi in range(mini(gems.size(), 7)):
		var gx := float(gi % 7) * 32.0
		var gem_icon := TextureRect.new()
		gem_icon.name = "Gem%d" % gi
		gem_icon.texture = TextureFactory.type_icon(1, int(gems[gi]["pool"]))
		gem_icon.position = Vector2(gx, 60.0)
		gem_icon.custom_minimum_size = Vector2(24.0, 24.0)
		gem_icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		gem_icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		gem_icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
		content.add_child(gem_icon)
		if int(gems[gi]["layers"]) > 1:
			var cnt := StickerTheme.label_sticker(Label.new(), 10, PopPalette.INK, 0, Color.WHITE, true)
			cnt.text = "×%d" % int(gems[gi]["layers"])
			cnt.size = Vector2(20.0, 12.0)
			cnt.position = Vector2(gx + 2.0, 82.0)
			content.add_child(cnt)


# ── 程序化 UI 组装（方向 C 贴纸风） ────────────────────────────────
func _build_ui() -> void:
	var root := Control.new()
	root.name = "Root"
	root.theme = StickerTheme.theme()
	root.set_anchors_preset(Control.PRESET_FULL_RECT)
	root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(root)

	# HP 白胶囊（圆角 + 藏青描边；填充 = 纯渐变，克制无表情）
	var hp_panel := _sticker_panel(root, Vector2(24.0, 24.0), HP_BAR_SIZE, 15.0)
	_hp_fill = Panel.new()
	_hp_fill.name = "HpFill"
	_hp_fill_style = StyleBoxFlat.new()
	_hp_fill_style.bg_color = PopPalette.SUCCESS
	_hp_fill_style.set_corner_radius_all(8)
	_hp_fill.add_theme_stylebox_override("panel", _hp_fill_style)
	_hp_fill.position = Vector2(4.0, 4.0)
	_hp_fill.size = HP_BAR_SIZE - Vector2(8.0, 8.0)
	_hp_fill.mouse_filter = Control.MOUSE_FILTER_IGNORE
	hp_panel.add_child(_hp_fill)
	_hp_label = StickerTheme.label_sticker(Label.new(), 18, PopPalette.INK, 0, Color.WHITE, true)
	_hp_label.name = "HpText"
	_hp_label.size = Vector2(HP_BAR_SIZE.x, 24.0)
	_hp_label.position = Vector2(0.0, 3.0)
	_hp_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	hp_panel.add_child(_hp_label)

	# 经验星条（柠檬星图标 + 白胶囊细条）
	var star_icon := TextureRect.new()
	star_icon.name = "XpStar"
	star_icon.texture = TextureFactory.star(32)
	star_icon.position = Vector2(26.0, 60.0)
	star_icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(star_icon)
	var xp_panel := _sticker_panel(root, Vector2(54.0, 63.0), XP_BAR_SIZE, 7.0)
	_xp_fill = Panel.new()
	_xp_fill.name = "XpFill"
	var xp_style := StyleBoxFlat.new()
	xp_style.bg_color = PopPalette.XP
	xp_style.set_corner_radius_all(4)
	_xp_fill.add_theme_stylebox_override("panel", xp_style)
	_xp_fill.position = Vector2(3.0, 3.0)
	_xp_fill.size = Vector2(3.0, XP_BAR_SIZE.y - 6.0)
	_xp_fill.mouse_filter = Control.MOUSE_FILTER_IGNORE
	xp_panel.add_child(_xp_fill)
	_level_label = StickerTheme.label_sticker(Label.new(), 18, PopPalette.INK, 0, Color.WHITE, true)
	_level_label.name = "LevelText"
	_level_label.text = "Lv 1"
	_level_label.position = Vector2(356.0, 60.0)
	root.add_child(_level_label)

	# 波次圆形徽章（右上）
	var badge := _sticker_panel(root, Vector2(598.0, 16.0), Vector2(106.0, 106.0), 53.0)
	var badge_cap := StickerTheme.label_sticker(Label.new(), 13, PopPalette.INK_SOFT)
	badge_cap.text = "WAVE"
	badge_cap.size = Vector2(106.0, 16.0)
	badge_cap.position = Vector2(0.0, 22.0)
	badge_cap.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	badge.add_child(badge_cap)
	_wave_label = StickerTheme.label_sticker(Label.new(), 26, PopPalette.INK, 0, Color.WHITE, true)
	_wave_label.name = "WaveText"
	_wave_label.text = "第 0 波"
	_wave_label.size = Vector2(106.0, 30.0)
	_wave_label.position = Vector2(0.0, 44.0)
	_wave_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	badge.add_child(_wave_label)

	# 击杀气泡 + 计时气泡
	var kill_pill := _sticker_panel(root, Vector2(24.0, 92.0), Vector2(150.0, 36.0), 18.0)
	_kill_label = StickerTheme.label_sticker(Label.new(), 18, PopPalette.INK, 0, Color.WHITE, true)
	_kill_label.name = "KillText"
	_kill_label.text = "击杀 0"
	_kill_label.size = Vector2(150.0, 24.0)
	_kill_label.position = Vector2(0.0, 6.0)
	_kill_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	kill_pill.add_child(_kill_label)
	var time_pill := _sticker_panel(root, Vector2(184.0, 92.0), Vector2(112.0, 36.0), 18.0)
	_time_label = StickerTheme.label_sticker(Label.new(), 18, PopPalette.INK_SOFT)
	_time_label.name = "TimeText"
	_time_label.text = "0:00"
	_time_label.size = Vector2(112.0, 24.0)
	_time_label.position = Vector2(0.0, 6.0)
	_time_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	time_pill.add_child(_time_label)

	# 角色技能键（右下角——用户反馈「不同的角色有不同的技能」）：冷却中置灰倒计时
	var skill_btn := Button.new()
	skill_btn.name = "SkillButton"
	skill_btn.text = "技能"
	skill_btn.add_theme_font_size_override("font_size", 20)
	skill_btn.add_theme_font_override("font", StickerTheme.font_bold())
	skill_btn.position = Vector2(610.0, 1112.0)
	skill_btn.size = Vector2(86.0, 86.0)
	skill_btn.pivot_offset = skill_btn.size * 0.5
	skill_btn.pressed.connect(_on_skill_pressed)
	skill_btn.button_down.connect(func() -> void: StickerTheme.press_punch(skill_btn))
	root.add_child(skill_btn)
	_skill_btn = skill_btn
		# 金币 pill（左上，护盾条同款贴纸风——战地黑市货币）
	var gold_pill := _sticker_panel(root, Vector2(24.0, 44.0), Vector2(132.0, 36.0), 18.0)
	gold_pill.name = "GoldPill"
	gold_pill.modulate.a = 0.94
	_gold_label = StickerTheme.label_sticker(Label.new(), 17, PopPalette.XP, 0, Color.WHITE, true)
	_gold_label.text = "◎ 0"
	_gold_label.set_anchors_preset(Control.PRESET_FULL_RECT)
	_gold_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_gold_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	gold_pill.add_child(_gold_label)
	# Boss 出场横幅（演出：缩放弹入 → 停留 → 淡出）
	_boss_banner = StickerTheme.label_sticker(Label.new(), 30, PopPalette.ENEMY, 6, Color.WHITE, true)
	_boss_banner.name = "BossBanner"
	_boss_banner.text = ""
	_boss_banner.position = Vector2(0.0, 210.0)
	_boss_banner.size = Vector2(720.0, 46.0)
	_boss_banner.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_boss_banner.visible = false
	_boss_banner.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(_boss_banner)
		# 构筑面板（左下角，避开弹幕主区——用户反馈 2026-08-29：当前持有武器+词条要展示；
	# 二轮反馈「点击左下角，可以看 buff 详情」→ 面板可点击 → 暂停 + 构筑详情卡）
	var build_root := Control.new()
	build_root.name = "BuildPanel"
	build_root.position = Vector2(24.0, 1124.0)
	build_root.size = Vector2(252.0, 132.0)
	build_root.mouse_filter = Control.MOUSE_FILTER_STOP
	build_root.gui_input.connect(_on_build_gui_input)
	root.add_child(build_root)
	_build_panel = build_root
	var build_bg := _sticker_panel(build_root, Vector2.ZERO, Vector2(252.0, 132.0), 16.0)
	build_bg.name = "BuildBg"
	build_bg.modulate.a = 0.92
	build_bg.mouse_filter = Control.MOUSE_FILTER_PASS               # 点击穿透到 BuildPanel
	_build_label = StickerTheme.label_sticker(Label.new(), 14, PopPalette.INK_SOFT)
	_build_label.name = "BuildText"
	_build_label.text = "构筑 · 点击查看详情"
	_build_label.size = Vector2(252.0, 18.0)
	_build_label.position = Vector2(0.0, 110.0)
	_build_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	build_bg.add_child(_build_label)

	# 护盾条（时间气泡右侧；MEC_SHIELD 持有才显示——用户反馈「单独的护盾条」）
	_shield_panel = _sticker_panel(root, Vector2(306.0, 92.0), Vector2(148.0, 36.0), 18.0)
	_shield_panel.name = "ShieldBar"
	_shield_panel.modulate.a = 0.94
	_shield_panel.visible = false
	var shield_icon := TextureRect.new()
	shield_icon.name = "ShieldIcon"
	shield_icon.texture = TextureFactory.shield_bubble()
	shield_icon.position = Vector2(4.0, 4.0)
	shield_icon.custom_minimum_size = Vector2(28.0, 28.0)
	shield_icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	shield_icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	shield_icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_shield_panel.add_child(shield_icon)
	_shield_fill = Panel.new()
	_shield_fill.name = "ShieldFill"
	_shield_fill_style = StyleBoxFlat.new()
	_shield_fill_style.bg_color = PopPalette.PLAYER
	_shield_fill_style.set_corner_radius_all(6)
	_shield_fill.add_theme_stylebox_override("panel", _shield_fill_style)
	_shield_fill.position = Vector2(34.0, 3.0)
	_shield_fill.size = Vector2(3.0, 30.0)
	_shield_fill.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_shield_panel.add_child(_shield_fill)
	var shield_tag := StickerTheme.label_sticker(Label.new(), 12, PopPalette.INK_SOFT)
	shield_tag.text = "护盾"
	shield_tag.position = Vector2(36.0, 8.0)
	shield_tag.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_shield_panel.add_child(shield_tag)

	# 暂停按钮（右上角贴纸图标：白底圆角 + 藏青 ⏸ 双竖条；仅 PLAYING 态显示——
	# 用户反馈 2026-08-29「没有暂停的地方」；申请经信号 → GameLoop 仲裁）
	_pause_btn = Button.new()
	_pause_btn.name = "PauseButton"
	for style_name in ["normal", "hover", "pressed", "focus", "disabled"]:
		_pause_btn.add_theme_stylebox_override(style_name, StyleBoxEmpty.new())
	_pause_btn.position = Vector2(514.0, 26.0)
	_pause_btn.size = Vector2(66.0, 66.0)
	_pause_btn.pivot_offset = _pause_btn.size * 0.5
	_pause_btn.pressed.connect(_on_pause_pressed)
	var pause_icon := TextureRect.new()
	pause_icon.name = "PauseIcon"
	pause_icon.texture = TextureFactory.ui_glyph(0)
	pause_icon.set_anchors_preset(Control.PRESET_FULL_RECT)
	pause_icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	pause_icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	pause_icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_pause_btn.add_child(pause_icon)
	_pause_btn.visible = false                   # 初始 MENU 态隐藏（state_changed 驱动）
	root.add_child(_pause_btn)

	# 波次 toast（果冻 pop；居中，避开 Boss 条与状态提示行）
	_toast_label = StickerTheme.label_sticker(Label.new(), 34, PopPalette.INK, 12, Color.WHITE, true)
	_toast_label.name = "WaveToast"
	_toast_label.text = ""
	_toast_label.size = Vector2(720.0, 44.0)
	_toast_label.position = Vector2(0.0, 392.0)
	_toast_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_toast_label.visible = false
	root.add_child(_toast_label)

	# 状态提示（测试锁定节点名与文案口径）
	_state_label = StickerTheme.label_sticker(Label.new(), 32, PopPalette.INK, 12, Color.WHITE, true)
	_state_label.name = "StateLabel"
	_state_label.text = ""
	_state_label.size = Vector2(720.0, 44.0)
	_state_label.position = Vector2(0.0, 212.0)
	_state_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_state_label.visible = false
	root.add_child(_state_label)
	refresh_stats()


func _sticker_panel(p_parent: Control, p_pos: Vector2, p_size: Vector2, p_radius: float) -> Panel:
	# 贴纸面板工厂（白底 + 藏青描边 + 底部厚投影；HUD 专用轻量版，无投影避免顶部杂乱）
	var panel := Panel.new()
	var sb := StickerTheme.panel_style(p_radius, 3, false)
	panel.add_theme_stylebox_override("panel", sb)
	panel.position = p_pos
	panel.size = p_size
	panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	p_parent.add_child(panel)
	return panel


func _show_toast(p_text: String) -> void:
	# 波次 toast：果冻 squash & stretch 出现（重要 UI 元素全局动效口径）
	_toast_label.text = p_text
	_toast_label.visible = true
	_toast_label.modulate.a = 1.0
	_toast_left = TOAST_TIME
	StickerTheme.squash_pop(_toast_label)
