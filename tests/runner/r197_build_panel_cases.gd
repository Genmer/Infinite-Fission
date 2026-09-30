# tests/runner/r197_build_panel_cases.gd
# R197 构筑面板竖排两列——QA 独立补强验证（由 test_r197_build_panel.gd 入口运行时加载）。
# 背景：r196_growth ③「竖两列」契约断言在其执行时点玩家武器无词条 → gems 为空 →
#   g_col_x=-1 走 `g_col_x < 0.0` 恒真分支——「宝石列在武器列右侧」对宝石列本身是空转。
#   本套件以真实词条夹具闭合该缺口，并补齐断触/出界/签名联动细粒度断言。
# 覆盖（对照 R197 验收依据 1/3/5）：
#   A 右列·词条宝石实挂：Gem x=74 右列、行距 30、×N 计数贴纸 x=100、列序宝石在武器列右
#     （R198 补 A⑧：×N 贴纸右沿 ≤ content 宽契约——r197-3 cnt 20 宽右对齐同步）
#   B 7 枚截断：8 词条恰渲染 7 枚（Gem7 不存在）+ 最末底沿不溢 content
#   C 左列·武器槽几何：同列 x=0 / 行高均分 / Lv 标签右置 / 锁贴纸居中 / tooltip 文案
#   D 断触口径：content 子树零 MOUSE_FILTER_STOP（面板底 PASS / 图标 PASS / 贴纸 IGNORE 让位）
#   E 出界 + 签名联动：content 全子件不出面板 rect；挂词条 → 签名变化 → 重建；无变化不重建
# 纪律：headless 测试档自动隔离（meta_save_test.cfg）；收尾还原 Meta 状态防跨套件污染。
extends RefCounted

const MAIN_SCENE := "res://scenes/main.tscn"
const PANEL_RECT_POS0 := Rect2(556.0, 196.0, 140.0, 258.0)

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
	await _test_a_gem_column()
	await _test_b_gem_cap7()
	await _test_c_weapon_column()
	_test_d_touch_filters()
	await _test_e_bounds_and_signature()
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


# ── 环境 ──────────────────────────────────────────────────────────
func _snapshot_meta() -> void:
	_snap_panel_pos = int(Meta.settings("panel_pos"))
	_snap_shake_on = bool(Meta.settings("shake_on"))


func _restore_meta() -> void:
	Meta.set_setting("panel_pos", _snap_panel_pos)
	Meta.set_setting("shake_on", _snap_shake_on)
	Meta._save()


func _normalize_window_for_boot() -> void:
	# 同 r194/r195/r196：-s 脚本模式根窗口归一（canvas 域恒等 720×1280）
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
	_gl.name = "R197GameLoopUnderTest"
	tree.get_root().add_child(_gl)
	_gl.state = GameConst.GameStatus.MENU          # 冻结波次刷怪
	_gl.current_map_id = MapTable.FIRST_MAP_ID
	_gl.start_run()
	_gl.player.set("max_hp", 1000000.0)
	_gl.player.set("hp", 1000000.0)
	_gl.player.set("unlocked_slots", 6)
	_gl.player.global_position = Vector2(360.0, 900.0)
	Meta.set_setting("shake_on", false)
	Meta.set_setting("panel_pos", 0)               # 默认右上（本套件几何断言域）
	for i in range(3):
		_gl.player.add_weapon(_gl.registry.get_weapon(&"W1_pistol"))


func _teardown_game_loop() -> void:
	tree.paused = false
	RunSave.clear()
	if _gl != null:
		_gl.free()
		_gl = null


# ── 夹具助手 ──────────────────────────────────────────────────────
func _refresh_and_get_content() -> Control:
	# 引用差集取新 content（同 verify R183 口径——重建后旧件 queue_free 延帧，按 name
	# 取会撞 @Control@N 改名；刷新后等一帧让旧件出树，剩余「不在 before 集合」者为新件）
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
	_gl.hud._build_sig = ""                       # 签名失效（下轮 refresh_stats 强制重建）


func _content_kids(p_content: Control, p_prefix: String) -> Array[Control]:
	var out: Array[Control] = []
	for kid in p_content.get_children():
		if String(kid.name).begins_with(p_prefix) and not kid.is_queued_for_deletion():
			out.append(kid as Control)
	return out


func _attach_distinct(p_w: WeaponBase, p_pool: int, p_want: int, p_seen: Dictionary) -> int:
	# 向 p_w 挂 p_want 个「本套件未挂过的」p_pool 池词条（每 id 1 层）；返回本次成功数
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


# ══ A 右列·词条宝石实挂（补 r196 空转断言） ═══════════════════════
func _test_a_gem_column() -> void:
	print("── A 右列词条宝石实挂（Gem x=74 / ×N 贴纸 / 列序） ──")
	_clear_weapon_traits()
	var w0: WeaponBase = _gl.player.weapon_slots[0]
	var t: TraitData = _gl.registry.get_trait(&"AFF_ATK_UP")
	var ok2 := true
	for i in range(2):
		ok2 = ok2 and w0.attach_trait(t)
	_check("A① 夹具：AFF_ATK_UP 连挂 2 层成功", ok2 and w0.trait_stack.traits.size() == 1
		and int(w0.trait_stack.traits[0].layers) == 2)
	var content := await _refresh_and_get_content()
	_check("A② 前置：新 BuildContent 在位", content != null)
	if content == null:
		return
	var gems := _content_kids(content, "Gem")
	var wpns := _content_kids(content, "Wpn")
	_check("A③ 右列在位：恰 1 枚 Gem（x=74 右列起点）",
		gems.size() == 1 and absf(gems[0].position.x - 74.0) < 0.01,
		"gems=%d x=%s" % [gems.size(), str(gems[0].position if gems.size() > 0 else Vector2.INF)])
	_check("A④ 列序：宝石列 x > 武器列 x（非空转——真实词条夹具）",
		wpns.size() > 0 and absf(wpns[0].position.x) < 0.01
		and gems[0].position.x > wpns[0].position.x,
		"w=%s g=%s" % [str(wpns[0].position.x), str(gems[0].position.x)])
	# ×N 计数贴纸：layers=2 → 「×2」Label 在宝石右侧 x=100
	var cnt: Label = null
	for kid in content.get_children():
		if kid is Label and (kid as Label).text == "×2":
			cnt = kid
	_check("A⑤ ×N 计数贴纸：×2 在位且 x=100（宝石右侧）",
		cnt != null and absf(cnt.position.x - 100.0) < 0.01,
		"cnt=%s" % str(cnt.position if cnt != null else Vector2.INF))
	# R198（r197-3）契约变更新增：×N 贴纸右沿 ≤ content 宽（hud.gd cnt 24→20 宽 + 右对齐，
	# 右沿 100+20=120 == content 宽 :866——旧 24 宽右沿 124>120 的 4px 出界收敛）
	var a8_right := cnt.position.x + cnt.size.x if cnt != null else -1.0
	_check("A⑧ [R198 契约变更] ×N 右沿收敛：cnt 右沿 ≤ content 宽", cnt != null
		and a8_right <= content.size.x + 0.01,
		"right=%s content_w=%s" % [str(a8_right), str(content.size.x)])
	# 第二枚宝石（不同词条）：行距 30 → y=34；1 层无 ×1 贴纸
	var t2: TraitData = _gl.registry.get_trait(&"ELE_IGNITE")
	var ok_e := t2 != null and w0.attach_trait(t2)
	content = await _refresh_and_get_content()
	var gems2 := _content_kids(content, "Gem")
	var cnt_all := 0
	for kid in content.get_children():
		if kid is Label and String((kid as Label).text).begins_with("×"):
			cnt_all += 1
	_check("A⑥ 第二枚：ELE_IGNITE 挂上 → Gem1 y=34（行距 30 起 y=4）",
		ok_e and gems2.size() == 2 and absf(gems2[1].position.y - 34.0) < 0.01,
		"ok=%s n=%d y=%s" % [str(ok_e), gems2.size(),
			str(gems2[1].position.y if gems2.size() > 1 else -1.0)])
	_check("A⑦ 1 层无计数贴纸：仅 ×2 一枚 ×N 标签（layers=1 不标 ×1）", cnt_all == 1,
		"cnt_all=%d" % cnt_all)


# ══ B 7 枚截断（最多 7 枚） ═══════════════════════════════════════
func _test_b_gem_cap7() -> void:
	print("── B 词条宝石 7 枚截断（8 词条恰渲染 7） ──")
	_clear_weapon_traits()
	var w0: WeaponBase = _gl.player.weapon_slots[0]
	var seen: Dictionary = {}
	var got := _attach_distinct(w0, GameConst.PoolClass.ADD, 8, seen)
	if got < 8:                                    # ADD 池不足（required_forms 拒挂等）补 ELEM 池
		got += _attach_distinct(w0, GameConst.PoolClass.ELEM, 8 - got, seen)
	_check("B① 夹具：单武器成功挂 8 个不同词条", got == 8, "got=%d" % got)
	var content := await _refresh_and_get_content()
	_check("B② 前置：BuildContent 在位", content != null)
	if content == null:
		return
	var gems := _content_kids(content, "Gem")
	var names_ok := gems.size() == 7
	for i in range(gems.size()):
		if String(gems[i].name) != "Gem%d" % i:
			names_ok = false
	_check("B③ 截断：恰渲染 7 枚 Gem0..Gem6（第 8 枚不建节点）", names_ok,
		"gems=%d" % gems.size())
	var last_bottom := -1.0
	if gems.size() == 7:
		last_bottom = gems[6].position.y + 22.0
	_check("B④ 最末宝石底沿 ≤ content 高 228（y=184+22=206）",
		last_bottom > 0.0 and last_bottom <= 228.0, "bottom=%.1f" % last_bottom)



# ══ C 左列·武器槽几何 + 锁槽 ══════════════════════════════════════
func _test_c_weapon_column() -> void:
	print("── C 左列武器槽（同列/行距/Lv 右置/锁贴纸居中/tooltip） ──")
	# 锁槽夹具（修正版）：start_run 已在槽 0 装初始手枪——释放槽 1..3 武器只留初始枪，
	# unlocked=3 → 槽 1/2 空但已解锁（暗环）、槽 3/4 空且未解锁（Lock3/Lock4）
	_clear_weapon_traits()
	for i in range(1, 4):
		var w_v: WeaponBase = _gl.player.weapon_slots[i]
		if w_v != null and is_instance_valid(w_v):
			_gl.player.weapon_slots[i] = null
			w_v.queue_free()
	_gl.player.set("unlocked_slots", 3)
	var content := await _refresh_and_get_content()
	_check("C① 前置：BuildContent 在位", content != null)
	if content == null:
		return
	var wpns := _content_kids(content, "Wpn")
	var locks := _content_kids(content, "Lock")
	_check("C② 帽 5 画满：恰 5 个 Wpn 同列 x=0", wpns.size() == 5
		and absf(wpns[0].position.x) < 0.01,
		"n=%d x=%s" % [wpns.size(), str(wpns[0].position.x if wpns.size() > 0 else Vector2.INF)])
	# 行高 228/5=45.6，icon_size=clampf(45.6-8,20,32)=32 → icon y = i*45.6 + 6.8
	var row_h := 228.0 / 5.0
	var icon_size := clampf(row_h - 8.0, 20.0, 32.0)
	var pitch_ok := wpns.size() == 5
	for i in range(wpns.size()):
		var expect_y := float(i) * row_h + (row_h - icon_size) * 0.5
		if absf(wpns[i].position.y - expect_y) > 0.01:
			pitch_ok = false
	_check("C③ 行高均分：Wpn_i y = i×45.6 + (45.6-32)/2（自上而下竖排）", pitch_ok,
		"icon=%s y0=%s" % [str(icon_size), str(wpns[0].position.y)])
	# Lv 标签右置：x = icon_size+4 = 36，文本 Lv1（槽 0 初始手枪 Lv1）
	var lv: Label = null
	for kid in content.get_children():
		if kid is Label and absf((kid as Label).position.x - (icon_size + 4.0)) < 0.01 \
				and String((kid as Label).text).begins_with("Lv"):
			lv = kid
	_check("C④ Lv 标签右置：x=36（图标右侧）且文本 Lv1",
		lv != null and lv.text == "Lv1", "lv=%s" % (lv.text if lv != null else "null"))
	# 锁槽：恰 2 枚（Lock3/Lock4）+ 锁贴纸在暗环中心
	var lock_names_ok := locks.size() == 2 \
		and String(locks[0].name) in ["Lock3", "Lock4"] \
		and String(locks[1].name) in ["Lock3", "Lock4"]
	_check("C⑤ 锁槽计数：恰 Lock3/Lock4（unlocked=3、空且未解锁槽 3/4）", lock_names_ok,
		"locks=%d" % locks.size())
	var lock_center_ok := locks.size() == 2
	for lock in locks:
		var idx := int(String(lock.name).trim_prefix("Lock"))
		var expect := Vector2((icon_size - 14.0) * 0.5,
			float(idx) * row_h + (row_h - 14.0) * 0.5)
		if lock.position.distance_to(expect) > 0.01:
			lock_center_ok = false
	_check("C⑥ 锁贴纸居中：Lock_i 位于暗环中心 ((32-14)/2, row_y+(45.6-14)/2)", lock_center_ok,
		"pos0=%s" % str(locks[0].position if locks.size() > 0 else Vector2.INF))
	# tooltip：持有武器行含 Lv 与机制注记；锁槽行（Wpn3/Wpn4）含解锁途径说明
	var tip_w: String = wpns[0].tooltip_text if wpns.size() > 0 else ""
	var tip_lock_hits := 0
	for w in wpns:
		if String(w.name) in ["Wpn3", "Wpn4"] and w.tooltip_text.contains("尚未解锁"):
			tip_lock_hits += 1
	_check("C⑦ tooltip：武器行含 Lv1；两锁槽行均含「尚未解锁」（悬停说明保留）",
		tip_w.contains("Lv1") and tip_lock_hits == 2,
		"tip_w_len=%d lock_hits=%d" % [tip_w.length(), tip_lock_hits])
	# 现状锁定（观察口径，非缺陷）：空槽但已解锁的暗环行保持创建初值 IGNORE——
	# 无 tooltip、非 STOP（拖动链/悬停零影响），与验收「武器图标/锁槽 PASS」不冲突
	var ring_ignore_ok := true
	for w in wpns:
		if String(w.name) in ["Wpn1", "Wpn2"] \
				and (w as Control).mouse_filter != Control.MOUSE_FILTER_IGNORE:
			ring_ignore_ok = false
	_check("C⑧ [现状] 空槽已解锁暗环行 Wpn1/2 mouse_filter == IGNORE（无 tooltip 非 STOP，观察口径）",
		ring_ignore_ok)
	# 还原：全 5 槽占满（供 D 断触全 PASS 断言的确定性状态）
	_gl.player.set("unlocked_slots", 6)
	for i in range(4):
		_gl.player.add_weapon(_gl.registry.get_weapon(&"W1_pistol"))


# ══ D 断触口径（content 子树零 STOP） ═════════════════════════════
func _test_d_touch_filters() -> void:
	print("── D 断触口径（零 STOP：面板底/图标 PASS、贴纸 IGNORE 让位） ──")
	var content := await _refresh_and_get_content()
	_check("D① 前置：BuildContent 在位", content != null)
	if content == null:
		return
	var stop_hits: Array[String] = []
	for kid in content.get_children():
		if (kid as Control).mouse_filter == Control.MOUSE_FILTER_STOP:
			stop_hits.append(String(kid.name))
	_check("D② content 子树零 MOUSE_FILTER_STOP（拖动链/tooltip 不被吞）", stop_hits.is_empty(),
		str(stop_hits))
	var wpn_pass := true
	for kid in content.get_children():
		if String(kid.name).begins_with("Wpn") \
				and (kid as Control).mouse_filter != Control.MOUSE_FILTER_PASS:
			wpn_pass = false
	_check("D③ 全 5 槽持有武器态：全部 Wpn* mouse_filter == PASS（R196 断触补口保持）", wpn_pass)
	_check("D④ 面板底 BuildPanel mouse_filter == PASS（点击走 gui_input、拖动放行）",
		_gl.hud._build_panel.mouse_filter == Control.MOUSE_FILTER_PASS)


# ══ E 出界 + 签名联动 ═════════════════════════════════════════════
func _test_e_bounds_and_signature() -> void:
	print("── E 内容出界 + 签名驱动重建/防抖 ──")
	var content := await _refresh_and_get_content()
	_check("E① 前置：BuildContent 在位", content != null)
	if content == null:
		return
	var panel: Control = _gl.hud._build_panel
	var pr := panel.get_global_rect().grow(1.0)
	var out_hits: Array[String] = []
	for kid in content.get_children():
		if not pr.encloses((kid as Control).get_global_rect()):
			out_hits.append("%s@%s" % [String(kid.name), str((kid as Control).get_global_rect())])
	_check("E② 内容零出界：content 全子件 global rect ⊆ 面板 rect(+1px)",
		out_hits.is_empty(), str(out_hits))
	# 签名联动：挂词条 → _compute_build_sig 变化 → refresh_stats 重建（引用差集）
	var w0: WeaponBase = _gl.player.weapon_slots[0]
	var sig0: String = _gl.hud._compute_build_sig()
	var td: TraitData = _gl.registry.get_trait(&"AFF_CRIT_RATE")
	var attached := td != null and w0.attach_trait(td)
	var sig1: String = _gl.hud._compute_build_sig()
	_check("E③ 签名：挂词条（AFF_CRIT_RATE 1 层）→ _compute_build_sig 变化",
		attached and sig1 != sig0, "attached=%s" % str(attached))
	var before: Array = []
	for kid in panel.get_children():
		before.append(kid)
	_gl.hud.refresh_stats()                        # 1Hz 兜底路径（签名变化 → 重建）
	await tree.process_frame
	var rebuilt: Control = null
	for kid in panel.get_children():
		if not before.has(kid) and String(kid.name) != "BuildBg":
			rebuilt = kid as Control
	_check("E④ 重建：refresh_stats 检出签名变化 → 新 BuildContent 实例（引用差集）",
		rebuilt != null and rebuilt != content)
	# 防抖：无变化再刷 → 不重建（1Hz 防抖语义——签名相同零重建）
	var before2: Array = []
	for kid in panel.get_children():
		before2.append(kid)
	_gl.hud.refresh_stats()
	await tree.process_frame
	var same := true
	for kid in panel.get_children():
		if not before2.has(kid) and String(kid.name) != "BuildBg":
			same = false
	_check("E⑤ 防抖：签名未变 → refresh_stats 不重建（实例保持）", same)
	_clear_weapon_traits()
