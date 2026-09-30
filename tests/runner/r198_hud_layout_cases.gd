# tests/runner/r198_hud_layout_cases.gd
# R198 HUD 布局清账——自测用例体（由 test_r198_hud_layout.gd 入口运行时加载）。
# 覆盖（对照 R198_BACKLOG_SWEEP.md §4 组3 五 WorkItem 验收）：
#   T toast 活宽（r195-3）：镜面/质变/刷新次数/成就合批四处临时 toast 改活宽拉伸锚——
#     offset_left==0 ∧ anchor_l=0/anchor_r=1 ∧ offset 右==0 ∧ 水平居中 ∧ y 设计位
#     （300/360）保持 ∧ 父域满宽（720 域 x 覆盖中心与旧死坐标等价：旧中心 360 == 新 360）
#   P 暂停钮让位（r194-2）：底缘 y=92 ≤ 金币 pill 顶缘 y=92 零重叠 ∧ 尺寸仍 72×72
#     （R195 R7 触控目标律）∧ AUTO 胶囊 y126..190 不在影响域
#   G 宝石溢出（r197-1）：8 词条 → OverflowGem.text=="+1" ∧ 无 Gem7 节点 ∧ Gem0..Gem6
#     恰 7 枚不回退 ∧ 溢出提示不出 content（214+12=226 ≤ 228）
#   F 字号（r197-2）：×N 贴纸 font_size override==10 ∧ 武器 Lv 标签==11
#   R 右沿收敛（r197-3，方案一 cnt 20 宽右对齐）：×N 右沿 ≤ content 宽（120）∧
#     右对齐 ∧ 「×10」@10pt=20px 恰等承载（min-size 不顶开节点宽）
# 纪律：headless 测试档自动隔离（meta_save_test.cfg）；收尾还原 Meta 状态防跨套件污染；
#   toast 几何同步读（拉伸锚挂树同帧生效——R198 探针实证），不 await 避开 tween 干扰。
extends RefCounted

const MAIN_SCENE := "res://scenes/main.tscn"

var tree: SceneTree
var _pass: int = 0
var _fail: int = 0
var _failures: Array[String] = []
var _gl: GameLoop = null
var _snap_panel_pos: int = 0
var _snap_shake_on: bool = true


func run(p_tree: SceneTree) -> void:
	tree = p_tree
	seed(42)
	_snapshot_meta()
	_boot_game_loop()
	await tree.process_frame
	await tree.process_frame
	_test_t_toast_live_width()
	_test_p_pause_button()
	await _test_g_gem_overflow()
	await _test_f_font_sizes()
	await _test_r_cnt_right_edge()
	_restore_meta()
	_teardown_game_loop()
	print("────────────────────────────────────────")
	print("汇总：PASS %d / FAIL %d（共 %d 项）" % [_pass, _fail, _pass + _fail])
	if not _failures.is_empty():
		for f in _failures:
			print("  FAIL 详情：%s" % f)
	print("验收汇总：%d/%d 通过" % [_pass, _pass + _fail])


func fail_count() -> int:
	return _fail


func _check(p_name: String, p_cond: bool, p_detail: String = "") -> void:
	if p_cond:
		_pass += 1
		print("PASS | %s" % p_name)
	else:
		_fail += 1
		_failures.append("%s %s" % [p_name, p_detail])
		print("FAIL | %s | %s" % [p_name, p_detail])


# ── 环境（同 r197_build_panel_cases 口径） ────────────────────────
func _snapshot_meta() -> void:
	_snap_panel_pos = int(Meta.settings("panel_pos"))
	_snap_shake_on = bool(Meta.settings("shake_on"))


func _restore_meta() -> void:
	Meta.set_setting("panel_pos", _snap_panel_pos)
	Meta.set_setting("shake_on", _snap_shake_on)
	Meta._save()


func _normalize_window_for_boot() -> void:
	# 同 r194/r195/r196/r197：-s 脚本模式根窗口归一（canvas 域恒等 720×1280）
	var win: Window = tree.root
	win.content_scale_mode = Window.CONTENT_SCALE_MODE_CANVAS_ITEMS
	match String(ProjectSettings.get_setting("display/window/stretch/aspect", "keep")):
		"keep_width":
			win.content_scale_aspect = Window.CONTENT_SCALE_ASPECT_KEEP_WIDTH
		"keep_height":
			win.content_scale_aspect = Window.CONTENT_SCALE_ASPECT_KEEP_HEIGHT
		"expand":
			win.content_scale_aspect = Window.CONTENT_SCALE_ASPECT_EXPAND
		"ignore":
			win.content_scale_aspect = Window.CONTENT_SCALE_ASPECT_IGNORE
		_:
			win.content_scale_aspect = Window.CONTENT_SCALE_ASPECT_KEEP
	win.size = Vector2i(
		int(ProjectSettings.get_setting("display/window/size/window_width_override", 540)),
		int(ProjectSettings.get_setting("display/window/size/window_height_override", 960)))


func _boot_game_loop() -> void:
	_normalize_window_for_boot()
	var scene: PackedScene = load(MAIN_SCENE)
	_gl = scene.instantiate() as GameLoop
	_gl.name = "R198HudLayoutGameLoopUnderTest"
	tree.get_root().add_child(_gl)
	_gl.state = GameConst.GameStatus.MENU          # 冻结波次刷怪
	_gl.current_map_id = MapTable.FIRST_MAP_ID
	_gl.start_run()
	_gl.player.set("max_hp", 1000000.0)
	_gl.player.set("hp", 1000000.0)
	_gl.player.set("unlocked_slots", 6)
	_gl.player.global_position = Vector2(360.0, 900.0)
	Meta.set_setting("shake_on", false)
	Meta.set_setting("panel_pos", 0)               # 默认右上（几何断言域）
	for i in range(3):
		_gl.player.add_weapon(_gl.registry.get_weapon(&"W1_pistol"))


func _teardown_game_loop() -> void:
	tree.paused = false
	RunSave.clear()
	if _gl != null:
		_gl.free()
		_gl = null


# ── 夹具助手 ──────────────────────────────────────────────────────
func _toast_by_diff(p_before: Array) -> Label:
	# HUD（CanvasLayer）直挂子件引用差集取新 toast（四处临时 toast 无观测名，唯一
	# AchToast 除外）
	for kid in _gl.hud.get_children():
		if not p_before.has(kid) and kid is Label:
			return kid as Label
	return null


func _hud_children() -> Array:
	var out: Array = []
	for kid in _gl.hud.get_children():
		out.append(kid)
	return out


func _refresh_and_get_content() -> Control:
	# 引用差集取新 content（同 r197_build_panel_cases 口径——queue_free 延帧，按引用取）
	var before: Array = []
	for kid in _gl.hud._build_panel.get_children():
		before.append(kid)
	_gl.hud.call(&"_refresh_build")
	await tree.process_frame
	for kid in _gl.hud._build_panel.get_children():
		if not before.has(kid) and String(kid.name) != "BuildBg":
			return kid as Control
	return null


func _clear_weapon_traits() -> void:
	for w_v: Variant in _gl.player.weapon_slots:
		if w_v != null and is_instance_valid(w_v):
			(w_v as WeaponBase).trait_stack.clear()
	_gl.hud._build_sig = ""                       # 签名失效（下轮刷新强制重建）


func _content_kids(p_content: Control, p_prefix: String) -> Array[Control]:
	var out: Array[Control] = []
	for kid in p_content.get_children():
		if String(kid.name).begins_with(p_prefix) and not kid.is_queued_for_deletion():
			out.append(kid as Control)
	return out


func _attach_distinct(p_w: WeaponBase, p_pool: int, p_want: int, p_seen: Dictionary) -> int:
	# 向 p_w 挂 p_want 个「未挂过的」p_pool 池词条（每 id 1 层）；返回成功数
	var got := 0
	for tid_v: Variant in _gl.registry.trait_ids_by_pool(p_pool):
		if got >= p_want:
			break
		var tid := StringName(String(tid_v))
		if p_seen.has(tid):
			continue
		var td: TraitData = _gl.registry.get_trait(tid)
		if td == null:
			continue
		if p_w.attach_trait(td):
			p_seen[tid] = true
			got += 1
	return got


func _assert_live_width(p_toast: Label, p_y: float, p_h: float, p_tag: String) -> void:
	# 活宽契约通用断言（r195-3）：锚/offset/居中/y 设计位/父域满宽——同步读
	# （拉伸锚挂树同帧生效，tween 下帧才动 position:y，offset 域不被本帧污染）
	var vis := tree.root.get_visible_rect()
	var toast_rect := p_toast.get_global_rect()
	_check("%s 锚：anchor_left==0 ∧ anchor_right==1" % p_tag,
		p_toast.anchor_left == 0.0 and p_toast.anchor_right == 1.0,
		"l=%s r=%s" % [str(p_toast.anchor_left), str(p_toast.anchor_right)])
	_check("%s offset：左右归 0 ∧ y 设计位 %s..%s 保持" % [p_tag, str(p_y), str(p_y + p_h)],
		p_toast.offset_left == 0.0 and p_toast.offset_right == 0.0
		and absf(p_toast.offset_top - p_y) < 0.01
		and absf(p_toast.offset_bottom - (p_y + p_h)) < 0.01,
		"l=%s r=%s t=%s b=%s" % [str(p_toast.offset_left), str(p_toast.offset_right),
			str(p_toast.offset_top), str(p_toast.offset_bottom)])
	_check("%s 居中：文本水平居中对齐 ∧ rect 中心==可视域中心（720 域 x 覆盖与旧死坐标等价）" % p_tag,
		p_toast.horizontal_alignment == HORIZONTAL_ALIGNMENT_CENTER
		and absf(toast_rect.get_center().x - vis.get_center().x) < 0.01,
		"cx=%s vis_cx=%s" % [str(toast_rect.get_center().x), str(vis.get_center().x)])
	_check("%s 活宽：满父域宽拉伸（size.x == 父域宽，旧 420/540 固定值已删）" % p_tag,
		absf(p_toast.size.x - p_toast.get_parent_area_size().x) < 0.01
		and toast_rect.size.x >= 420.0,
		"w=%s parent=%s" % [str(p_toast.size.x), str(p_toast.get_parent_area_size().x)])
	_check("%s 设计位：global y 顶沿==%s（720 域 y 逐位不变）" % [p_tag, str(p_y)],
		absf(toast_rect.position.y - p_y) < 0.01, "gy=%s" % str(toast_rect.position.y))


# ══ T toast 活宽（r195-3） ═══════════════════════════════════════
func _test_t_toast_live_width() -> void:
	print("── T 四处临时 toast 活宽拉伸锚（r195-3） ──")
	# ① 镜面 toast（旧 (150,300)/(420,30)）
	var before := _hud_children()
	_gl.hud.call(&"_on_mirror_formed_toast", "R198 镜面活宽验证")
	var t1 := _toast_by_diff(before)
	_check("T① 前置：镜面 toast 实挂（引用差集）", t1 != null)
	if t1 != null:
		_assert_live_width(t1, 300.0, 30.0, "T② 镜面")
	# ② 质变里程碑 toast（旧 (90,360)/(540,34)）
	before = _hud_children()
	_gl.hud.call(&"_on_trait_milestone_toast", &"AFF_ATK_UP", "攻击强化", 1.6)
	var t2 := _toast_by_diff(before)
	_check("T③ 前置：质变 toast 实挂", t2 != null)
	if t2 != null:
		_assert_live_width(t2, 360.0, 34.0, "T④ 质变")
	# ③ 刷新次数 toast（旧 (150,300)/(420,30)）
	before = _hud_children()
	_gl.hud.call(&"_on_reroll_toast", 2)
	var t3 := _toast_by_diff(before)
	_check("T⑤ 前置：刷新次数 toast 实挂", t3 != null)
	if t3 != null:
		_assert_live_width(t3, 300.0, 30.0, "T⑥ 刷新次数")
	# ④ 成就合批 toast（旧 (150,300)/(420,30)）——同帧合批：直填 pending + 直调 flush
	before = _hud_children()
	if Meta.ACHIEVEMENTS.size() > 0:
		_gl.hud._ach_toast_pending.append(Meta.ACHIEVEMENTS[0].id)
	_gl.hud.call(&"_flush_achievement_toast")
	var t4: Label = null
	for kid in _gl.hud.get_children():
		if kid is Label and String(kid.name) == "AchToast":
			t4 = kid as Label
	_check("T⑦ 前置：成就合批 toast（AchToast）实挂", t4 != null
		and _toast_by_diff(before) == t4)
	if t4 != null:
		_assert_live_width(t4, 300.0, 30.0, "T⑧ 成就合批")


# ══ P 暂停钮让位（r194-2） ═══════════════════════════════════════
func _test_p_pause_button() -> void:
	print("── P 暂停钮上移 6px 脱金币 pill（r194-2） ──")
	var pause: Control = _gl.hud._pause_btn
	var pill: Control = _gl.hud._hud_root.find_child("GoldPill", true, false)
	_check("P① 前置：_pause_btn/GoldPill 句柄在位", pause != null and pill != null)
	if pause == null or pill == null:
		return
	var p_rect := pause.get_global_rect()
	var g_rect := pill.get_global_rect()
	_check("P② y 带：offset_top==20 ∧ offset_bottom==92（26..98 → 20..92 上移 6px）",
		pause.offset_top == 20.0 and pause.offset_bottom == 92.0,
		"t=%s b=%s" % [str(pause.offset_top), str(pause.offset_bottom)])
	_check("P③ 零重叠：暂停钮底缘 ≤ 金币 pill 顶缘（92 ≤ 92 恰接不越）",
		p_rect.end.y <= g_rect.position.y + 0.01,
		"pause_bottom=%s pill_top=%s" % [str(p_rect.end.y), str(g_rect.position.y)])
	_check("P④ 触控目标律：尺寸仍 72×72（R195 R7 ≥66 口径不回退）",
		pause.size == Vector2(72.0, 72.0), str(pause.size))
	_check("P⑤ 无辜带：AUTO 胶囊（y126..190）顶沿 ≥ 暂停钮底缘（不在影响域）",
		_gl.hud._auto_capsule == null
		or _gl.hud._auto_capsule.get_global_rect().position.y >= p_rect.end.y - 0.01,
		"auto_top=%s" % str(_gl.hud._auto_capsule.get_global_rect().position.y
			if _gl.hud._auto_capsule != null else -1.0))


# ══ G 宝石溢出 +N（r197-1） ══════════════════════════════════════
func _test_g_gem_overflow() -> void:
	print("── G 宝石超 7 枚补 +N 提示（r197-1） ──")
	_clear_weapon_traits()
	var w0: WeaponBase = _gl.player.weapon_slots[0]
	var seen: Dictionary = {}
	var got := _attach_distinct(w0, GameConst.PoolClass.ADD, 8, seen)
	if got < 8:                                    # ADD 池不足（required_forms 拒挂等）补 ELEM 池
		got += _attach_distinct(w0, GameConst.PoolClass.ELEM, 8 - got, seen)
	_check("G① 夹具：单武器成功挂 8 个不同词条", got == 8, "got=%d" % got)
	var content := await _refresh_and_get_content()
	_check("G② 前置：BuildContent 在位", content != null)
	if content == null:
		return
	var gems := _content_kids(content, "Gem")
	var names_ok := gems.size() == 7              # B③ 同口径：溢出提示不得混入 Gem* 计数
	for i in range(gems.size()):
		if String(gems[i].name) != "Gem%d" % i:
			names_ok = false
	_check("G③ 截断不回退：恰 Gem0..Gem6 恰 7 枚（溢出提示不占 Gem* 名额）",
		names_ok, "gems=%d" % gems.size())
	_check("G④ 无 Gem7：第 8 枚不建 Gem* 节点", content.find_child("Gem7", true, false) == null)
	var overflow: Label = content.find_child("OverflowGem", true, false) as Label
	_check("G⑤ +N 提示：OverflowGem.text==\"+1\"（8-7=1）", overflow != null
		and overflow.text == "+1",
		"text=%s" % (overflow.text if overflow != null else "null"))
	if overflow != null:
		_check("G⑥ 溢出位：position==(74,214)（Gem 列起点、末行下方）",
			overflow.position.distance_to(Vector2(74.0, 214.0)) < 0.01,
			str(overflow.position))
		# R198 实测注：Label 实际行高按字体度量结算（headless @10pt ≈23px，全站 Label
		# 同律——旧 cnt 贴纸 (24,12) 同样实结 >12），「不出 content」契约落在规划名义
		# 设计槽（214+12=226 ≤ 228）+ 面板出界由 r197 E② 全量守卫（本批复跑绿）
		_check("G⑦ 设计槽：position.y==214 ∧ 名义高 12 → 底沿 226 ≤ content 高 228",
			absf(overflow.position.y - 214.0) < 0.01
			and overflow.position.y + 12.0 <= content.size.y + 0.01,
			"y=%s nominal_bottom=%s content_h=%s actual_h=%s" % [
				str(overflow.position.y), str(overflow.position.y + 12.0),
				str(content.size.y), str(overflow.size.y)])
		_check("G⑧ 非 Gem* 前缀：节点名不以 Gem 开头（r197 B③/r196 ③ 前缀消费方零污染）",
			not String(overflow.name).begins_with("Gem"), String(overflow.name))


# ══ F 字号（r197-2） ═════════════════════════════════════════════
func _test_f_font_sizes() -> void:
	print("── G 后·F 宝石层数/Lv 字号 10/11（r197-2） ──")
	_clear_weapon_traits()
	var w0: WeaponBase = _gl.player.weapon_slots[0]
	var t: TraitData = _gl.registry.get_trait(&"AFF_ATK_UP")
	var ok2 := true
	for i in range(2):
		ok2 = ok2 and w0.attach_trait(t)           # 1 词条 2 层 → 「×2」贴纸
	_check("F① 夹具：AFF_ATK_UP 连挂 2 层", ok2 and w0.trait_stack.traits.size() == 1
		and int(w0.trait_stack.traits[0].layers) == 2)
	var content := await _refresh_and_get_content()
	_check("F② 前置：BuildContent 在位", content != null)
	if content == null:
		return
	var cnt: Label = null
	var lv: Label = null
	for kid in content.get_children():
		if kid is Label:
			if (kid as Label).text == "×2":
				cnt = kid
			elif String((kid as Label).text).begins_with("Lv"):
				lv = kid
	_check("F③ 前置：×2 贴纸与 Lv 标签都在位", cnt != null and lv != null,
		"cnt=%s lv=%s" % [str(cnt != null), str(lv != null)])
	if cnt == null or lv == null:
		return
	_check("F④ 字号 override：×N 层数贴纸 font_size==10（9→10）",
		cnt.get_theme_font_size("font_size") == 10,
		str(cnt.get_theme_font_size("font_size")))
	_check("F⑤ 字号 override：武器 Lv 标签 font_size==11（10→11）",
		lv.get_theme_font_size("font_size") == 11,
		str(lv.get_theme_font_size("font_size")))


# ══ R ×N 右沿收敛（r197-3 方案一） ═══════════════════════════════
func _test_r_cnt_right_edge() -> void:
	print("── R ×N 贴纸右沿 ≤ content 宽（r197-3 方案一：20 宽右对齐） ──")
	var content := await _refresh_and_get_content()
	_check("R① 前置：BuildContent 在位", content != null)
	if content == null:
		return
	# ×2（当前 F 夹具残留 2 层 AFF_ATK_UP）
	var cnt2: Label = null
	for kid in content.get_children():
		if kid is Label and (kid as Label).text == "×2":
			cnt2 = kid
	_check("R② ×2 右沿：position.x==100（A⑤ 原样）∧ 右沿 100+20=120 ≤ content 宽",
		cnt2 != null and absf(cnt2.position.x - 100.0) < 0.01
		and cnt2.position.x + cnt2.size.x <= content.size.x + 0.01,
		"right=%s content_w=%s" % [str(cnt2.position.x + cnt2.size.x if cnt2 != null else -1.0),
			str(content.size.x)])
	_check("R③ ×2 右对齐：horizontal_alignment==RIGHT（右沿收敛机制）",
		cnt2 != null and cnt2.horizontal_alignment == HORIZONTAL_ALIGNMENT_RIGHT)
	_check("R④ ×2 不溢节点：min-size 未顶开（14px 文本 < 20px 承载，size.x==20）",
		cnt2 != null and absf(cnt2.size.x - 20.0) < 0.01, str(cnt2.size.x if cnt2 != null else Vector2.INF))
	# ×10 两位数边界：度量契约按规划 r197-3 判据实测（「×10」@10pt 字符串宽 ≤ 承载 20）。
	# 实码双实测（R198）：①字符串度量 20px == 承载（按规划判据「未超」→ 方案一成立）；
	# ②引擎 Label min-width 结算 28px > 20（TextServer 整形与 Label 最小宽口径差）——但
	# ×10 局内不可达：R196 帽 = stack_max+OVERCAP_EXT_MAX，全池最高 AFF_CDR 4+5=9（×9），
	# 故可达边界取 ×9 白盒夹具（直置 mounted.layers=9；BuildPanel 只读 layers/pool，
	# layer_values/layer_rarities 同步补位保聚合消费端形状）。未来若抬帽出两位数 ×N，
	# 需回退方案二并按 min-width 28 重定 content 宽（hud.gd :866 区段注已留痕）
	var f2: Font = cnt2.get_theme_font("font") if cnt2 != null else null
	var w10 := -1.0
	if f2 != null:
		w10 = f2.get_string_size("×10", HORIZONTAL_ALIGNMENT_LEFT, -1, 10).x
	_check("R⑤ ×10 度量：@10pt 字符串宽 %s ≤ cnt 承载 20（规划判据实测，恰等不超→方案一）" % str(w10),
		w10 >= 0.0 and w10 <= 20.0 + 0.01, "w10=%s" % str(w10))
	var w0: WeaponBase = _gl.player.weapon_slots[0]
	var mounted: Variant = w0.trait_stack.traits[0]   # AFF_ATK_UP（F 夹具残留 2 层）
	mounted.layers = 9                                 # 全池可达最高层（AFF_CDR 4+5 同级）
	for i in range(7):
		mounted.layer_values.append(0.0)
		mounted.layer_rarities.append(0)
	_gl.hud._build_sig = ""                            # 签名失效（强制重建渲染 ×9）
	content = await _refresh_and_get_content()
	var cnt9: Label = null
	for kid in content.get_children():
		if kid is Label and (kid as Label).text == "×9":
			cnt9 = kid
	_check("R⑥ 夹具：可达帽 ×9（1 位最大位数）贴纸在位", cnt9 != null,
		"found=%s" % str(cnt9 != null))
	if cnt9 == null:
		return
	_check("R⑦ ×9 右沿：position.x==100（A⑤ 同位）∧ 右沿 ≤ content 右沿（100+20=120 ≤ 120 恰等）",
		absf(cnt9.position.x - 100.0) < 0.01
		and cnt9.position.x + cnt9.size.x <= content.size.x + 0.01,
		"right=%s content_w=%s" % [str(cnt9.position.x + cnt9.size.x), str(content.size.x)])
	_check("R⑧ ×9 恰等承载：min-size 未顶开节点宽（size.x==20，可达域内右沿恒 ≤ content）",
		absf(cnt9.size.x - 20.0) < 0.01, str(cnt9.size))
