# tests/runner/qa_r218_probe_cases.gd
# R218 QA 独立探针（qa 系第三方验证口——r218_simbound 之外的独立复核，不共享断言口径）：
#   ① 帽语义（vc25 二j #1）：源级锚=1 且无 =2 残留；headless 运行时 8/max_fps 0 不动；
#      Meta._apply_fps_cap() 桌面零写点；帽 1 帧序语义=连续 10 帧手动 _physics_process
#      探针段逐帧重建（哨兵键被 clear、恒 16 键、frame_order 契约序）
#   ② 分组N 红线（二j #2）：120 同相位点燃敌 → 组恒 +1（断N=120 vs 组N=1 高计对照）、
#      点燃 2 档+冻结+白=恰 4 组精确断言、根 α 通道入键（渐显 4 档互异 + α0.5 孪生同组）、
#      满载强闪 modulate 通道入键、归还回落
#   ③ 他键（二j #1）：PLAYING 帧在位 ≥0、长跑 10 帧恒 ≥0（段和不得超全函数）、
#      peak 通道 + diag_reset_stage_peaks 清零钩、MENU 帧 _probe_active 旗不写
#   ④ 跳键（二j #4）：PLAYING/LEVEL_UP 双写点各有 popup 键、popup+ui ≤ 原⑧段总量、
#      popup 键= _ui_popup_us 同源、探针关时零写（popup/other 均）
#   ⑤ 满载跳字帽：源级锚 24/40 + 桌面 80/40/20 恒定 + fullload_override 不影响桌面分支
#   ⑥ 契约：DIAG 15 段序锁死（popup 在 fx 后 ui 前、other 殿后）、tags 跳/他、
#      diag 行含 组N 与全 15 段标签、余值三子集跳过（源级锚+合成帧函数级）
#   ⑦ 回归面：R212 跳字排版限批（label_refresh 计数/收敛）不变、R206 峰值采样（尖峰Xms
#      标记+读取后清零钩）仍工作
# 坑位纪律：敌池 _gl.pools[&"enemy"]；elemental 初始 null 自挂 ElementalState.new()；
# 直连池敌手动 append/erase spawner.active；勿二次 release；stage_probe_enabled 手动 true；
# _physics_process(DT) 手动驱动；MENU/PLAYING 态直赋（绕开迁移仲裁，qa_r217 先例）；
# 渐显 4 档 α={0,1/3,2/3,1} 由 tick 内 roundf(fa*3)/3 量化（_fade_left 先减 DT）。
extends RefCounted

const MAIN_SCENE := "res://scenes/main.tscn"
const DT := 1.0 / 60.0
const BATCH_N := 120                            # 满载深谷敌数口径（敌 80-120 上沿）

var tree: SceneTree
var _pass: int = 0
var _fail: int = 0
var _failures: Array[String] = []
var _gl: GameLoop = null                        # ② 用实例（MENU 静场，零帧驱动）
var _gl2: GameLoop = null                       # ①③④⑥⑦ 用实例（帧驱动）
var _other_min_seen: int = 1 << 30              # ①d 长跑期间 他键最小值（≥0 断言源）


func run(p_tree: SceneTree) -> void:
	tree = p_tree
	seed(20261002)
	_boot(&"_gl")
	await tree.process_frame
	await tree.process_frame
	_test_2_tint_groups_redline()
	_teardown(&"_gl")
	_boot(&"_gl2")
	_test_1_cap_semantics()
	_test_3_other_key()
	_test_4_popup_key()
	_test_5_fullload_cap()
	_test_6_contract()
	_test_7_regression()
	_teardown(&"_gl2")
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
		print("  PASS | %s" % p_name)
	else:
		_fail += 1
		_failures.append("%s（%s）" % [p_name, p_detail])
		print("  FAIL | %s（%s）" % [p_name, p_detail])


func _boot(p_slot: String) -> void:
	var scene: PackedScene = load(MAIN_SCENE)
	var gl: GameLoop = scene.instantiate() as GameLoop
	gl.name = "R218QA%s" % p_slot
	tree.get_root().add_child(gl)
	set(p_slot, gl)
	gl.state = GameConst.GameStatus.MENU
	gl.current_map_id = MapTable.FIRST_MAP_ID
	gl.start_run()
	gl.state = GameConst.GameStatus.MENU
	gl.player.global_position = Vector2(360.0, 900.0)


func _teardown(p_slot: String) -> void:
	tree.paused = false
	Enemy.fullload_override = -1
	var gl: GameLoop = get(p_slot)
	if gl != null:
		if gl.popup_manager != null:
			gl.popup_manager.label_refresh_cap_override = -1
			gl.popup_manager.clear_all()
		gl.stage_probe_enabled = false
		gl.free()
		set(p_slot, null)
	RunSave.clear()


# ── 共用小件 ──────────────────────────────────────────────────────
func _fixture_enemy(p_id: StringName) -> EnemyData:
	var d := EnemyData.new()
	d.id = p_id
	d.display_name = String(p_id)
	d.hp_base = 100.0
	d.spd_base = 0.0                          # 定桩不位移（分组断言只看染色）
	d.dmg_base = 0.0
	d.exp_base = 1.0
	d.hitbox_r = 14.0
	d.resist = [0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0]
	return d


func _spawn_enemy(p_id: StringName, p_gl: GameLoop = null) -> Enemy:
	var loop := p_gl if p_gl != null else _gl
	var pool := loop.pools[&"enemy"] as EnemyPool
	var e := pool.acquire() as Enemy
	e.spawn(_fixture_enemy(p_id), 1, 0)
	e._fade_left = 0.0                        # 跳过入场渐显（分组测独立驱动 α）
	e.modulate.a = 1.0
	return e


func _spawn_fade_enemy(p_id: StringName, p_fade_left: float) -> Enemy:
	# 渐显档专用：不预设 α（spawn 自置 0），_fade_left 交 tick 量化
	var pool := _gl.pools[&"enemy"] as EnemyPool
	var e := pool.acquire() as Enemy
	e.spawn(_fixture_enemy(p_id), 1, 0)
	e._fade_left = p_fade_left
	e.tick(DT)                                # tick 内 _fade_left 先减 DT → α 落 4 档网格
	return e


func _release_enemy(p_e: Enemy, p_gl: GameLoop = null) -> void:
	var loop := p_gl if p_gl != null else _gl
	(loop.pools[&"enemy"] as EnemyPool).release(p_e)


func _attach_burn(p_e: Enemy, p_anim_t: float) -> void:
	if p_e.elemental == null:
		p_e.elemental = ElementalState.new()
	p_e.elemental.burn_timer = 2.0
	p_e._anim_t = p_anim_t


func _append_active(p_e: Enemy, p_gl: GameLoop = null) -> void:
	var loop := p_gl if p_gl != null else _gl
	loop.spawner.active.append(p_e)


func _erase_active(p_e: Enemy, p_gl: GameLoop = null) -> void:
	var loop := p_gl if p_gl != null else _gl
	loop.spawner.active.erase(p_e)


func _extract_int(p_line: String, p_token: String) -> int:
	# 行内 token 后第一个十进制整数（diag 行解析：fps/余）
	var idx := p_line.find(p_token)
	if idx < 0:
		return -1
	var i := idx + p_token.length()
	var digits := ""
	while i < p_line.length() and p_line[i] >= "0" and p_line[i] <= "9":
		digits += p_line[i]
		i += 1
	return int(digits) if digits != "" else -1


func _new_diag_formatter() -> Node:
	# 独立 DebugStats 实例拼行（qa_r217 ⑤d 同口径——不惊动 autoload 单例）
	return (load("res://autoload/debug_stats.gd") as GDScript).new()


# ── ② 分组N 红线（真合批分组上限） ─────────────────────────────────
func _test_2_tint_groups_redline() -> void:
	print("── ② 分组N 红线 ──")
	var field_empty: bool = _gl.spawner.active.is_empty()
	_check("②pre 静场空表（MENU 零帧驱动——分组断言零背景噪声）", field_empty,
		"active=%d" % _gl.spawner.active.size())
	var counts0: Dictionary = _gl.diag_counts()
	_check("②pre 新键 tint_groups 在位且空场=0",
		counts0.has(&"tint_groups") and int(counts0[&"tint_groups"]) == 0,
		"groups=%s keys=%s" % [str(counts0.get(&"tint_groups", "缺")), str(counts0.keys())])
	var base_groups: int = int(counts0[&"tint_groups"])

	# ②a 同状态同帧 ×N（120 同相位点燃）：分组恒 +1（任意数量不增组）
	var pool := _gl.pools[&"enemy"] as EnemyPool
	var cap := GameConfig.get_pool_capacity(&"enemy")
	var n: int = mini(BATCH_N, cap - int(pool.stats()["live"]))
	_check("②pre 池容量夹具：可取 %d 敌（容量 %d）" % [n, cap], n >= 100,
		"n=%d cap=%d live=%d" % [n, cap, int(pool.stats()["live"])])
	var arr: Array[Enemy] = []
	for i in range(n):
		var e := _spawn_enemy(StringName("E_QA218_G%d" % i))
		_attach_burn(e, 0.3)                  # 全员同相位同档
		e.call(&"_apply_body_tint", DT)
		_append_active(e)
		arr.append(e)
	var c1: Dictionary = _gl.diag_counts()
	_check("②a %d 只同相位点燃敌 → 分组恒 +1（组=合批上限，与敌数无关）" % n,
		int(c1[&"tint_groups"]) == base_groups + 1,
		"base=%d now=%d" % [base_groups, int(c1[&"tint_groups"])])
	_check("②a2 高计对照：断N=%d vs 组N=1（断N 逐敌计数≠断批分组——R218 补口径）" % n,
		int(c1[&"tinted_enemies"]) == n and int(c1[&"tint_groups"]) == 1,
		"断N=%d 组N=%d" % [int(c1[&"tinted_enemies"]), int(c1[&"tint_groups"])])
	for e in arr:
		_erase_active(e)
		_release_enemy(e)
	arr.clear()
	var c2: Dictionary = _gl.diag_counts()
	_check("②a3 归还回落：分组回基线 0",
		int(c2[&"tint_groups"]) == base_groups,
		"base=%d now=%d" % [base_groups, int(c2[&"tint_groups"])])

	# ②b 多档混合精确断言：点燃高档×2 + 点燃低档×2 + 冻结×2 + 白板×2 = 恰 4 组
	var mix_spec := [0, 0, 1, 1, 2, 2, 3, 3]      # 0=点燃高档 1=点燃低档 2=冻结 3=白
	for i in range(mix_spec.size()):
		var e := _spawn_enemy(StringName("E_QA218_M%d" % i))
		match int(mix_spec[i]):
			0:
				_attach_burn(e, (PI - 0.02) / 6.2)   # sin 微正 → 高档
			1:
				_attach_burn(e, (PI + 0.02) / 6.2)   # sin 微负 → 低档
			2:
				if e.elemental == null:
					e.elemental = ElementalState.new()
				e.elemental.freeze_timer = 5.0
			_:
				pass                                  # 洁净白板
		e.call(&"_apply_body_tint", DT)
		_append_active(e)
		arr.append(e)
	var c3: Dictionary = _gl.diag_counts()
	_check("②b 点燃 2 档+冻结+白 = 恰 4 组（=distinct 元组数精确断言）",
		int(c3[&"tint_groups"]) == base_groups + 4,
		"base=%d now=%d" % [base_groups, int(c3[&"tint_groups"])])
	for e in arr:
		_erase_active(e)
		_release_enemy(e)
	arr.clear()

	# ②c 根 α 通道入键：同白板 tint、渐显 4 档 α={0,1/3,2/3,1} → 4 组互异
	var fls: Array[float] = [0.12, 0.09, 0.06, 0.03]
	var alphas: Array[float] = []
	for i in range(fls.size()):
		var e := _spawn_fade_enemy(StringName("E_QA218_F%d" % i), fls[i])
		alphas.append(e.modulate.a)
		_append_active(e)
		arr.append(e)
	var alpha_set := {}
	for a in alphas:
		alpha_set[a] = true
	_check("②c1 渐显 4 档 α 网格齐现 {0,1/3,2/3,1}（tick 量化前置）",
		alpha_set.size() == 4 and alpha_set.has(0.0) and alpha_set.has(1.0),
		"alphas=%s" % str(alphas))
	var c4: Dictionary = _gl.diag_counts()
	_check("②c2 同 tint 异根 α → 4 组（α 入键——渐显敌独立成批）",
		int(c4[&"tint_groups"]) == base_groups + 4,
		"base=%d now=%d" % [base_groups, int(c4[&"tint_groups"])])
	# ②c3 非量化 α=0.5 孪生：首个 → +1 新组；次个同值 → 不增组（α 恒 +1 语义）
	var half1 := _spawn_enemy(&"E_QA218_H1")
	half1.modulate.a = 0.5
	_append_active(half1)
	arr.append(half1)
	var c5: Dictionary = _gl.diag_counts()
	var half2 := _spawn_enemy(&"E_QA218_H2")
	half2.modulate.a = 0.5
	_append_active(half2)
	arr.append(half2)
	var c6: Dictionary = _gl.diag_counts()
	_check("②c3 α=0.5 首个入新组（+1）、孪生同值不增组（α 通道同值同组）",
		int(c5[&"tint_groups"]) == base_groups + 5
			and int(c6[&"tint_groups"]) == base_groups + 5,
		"half1=%d half2=%d（base=%d）" % [int(c5[&"tint_groups"]),
			int(c6[&"tint_groups"]), base_groups])
	for e in arr:
		_erase_active(e)
		_release_enemy(e)
	arr.clear()

	# ②d modulate 通道入键：满载强闪（WHITE×2.4 写 _sprite.modulate）→ +1
	Enemy.fullload_override = 1
	for i in range(3):
		var e := _spawn_enemy(StringName("E_QA218_FL%d" % i))
		e.call(&"_apply_flash", 1.0)
		_append_active(e)
		arr.append(e)
	var c7: Dictionary = _gl.diag_counts()
	_check("②d 满载强闪敌 → 分组 +1（modulate.to_html 通道参与元组键）",
		int(c7[&"tint_groups"]) == base_groups + 1,
		"base=%d now=%d" % [base_groups, int(c7[&"tint_groups"])])
	Enemy.fullload_override = -1
	for e in arr:
		_erase_active(e)
		_release_enemy(e)
	arr.clear()
	var c8: Dictionary = _gl.diag_counts()
	_check("②e 归还回落（全用例终态）：分组回基线 0",
		int(c8[&"tint_groups"]) == base_groups,
		"base=%d now=%d" % [base_groups, int(c8[&"tint_groups"])])


# ── ① 帽语义（追赶帽 2→1） ─────────────────────────────────────────
func _test_1_cap_semantics() -> void:
	print("── ① 帽语义 ──")
	# ①a 源级锚：=1 且无第二处赋值（=2 残留即回归）
	var src: String = FileAccess.get_file_as_string("res://scripts/meta/meta_manager.gd")
	_check("①a 源级锚：Engine.max_physics_steps_per_frame = 1（fps≥60 无操作/螺旋段单步减半）",
		src.contains("Engine.max_physics_steps_per_frame = 1"), "缺掐帽 1 行")
	_check("①a2 赋值唯一性：max_physics_steps_per_frame 全文件恰 1 处赋值（无 =2 残留）",
		src.count("max_physics_steps_per_frame = ") == 1
			and not src.contains("max_physics_steps_per_frame = 2"),
		"count=%d" % src.count("max_physics_steps_per_frame = "))
	# ①b 运行时：headless 缺省 8 / max_fps 0 不动（桌面零扰动）
	_check("①b headless 运行时：max_physics_steps_per_frame==8 且 max_fps==0（缺省不动）",
		Engine.max_physics_steps_per_frame == 8 and Engine.max_fps == 0,
		"steps=%d fps=%d" % [Engine.max_physics_steps_per_frame, Engine.max_fps])
	# ①c _apply_fps_cap 桌面/headless 零写点（mobile 门早退）
	Meta._apply_fps_cap()
	_check("①c Meta._apply_fps_cap() 后仍 8/0（桌面分支零写点）",
		Engine.max_physics_steps_per_frame == 8 and Engine.max_fps == 0,
		"steps=%d fps=%d" % [Engine.max_physics_steps_per_frame, Engine.max_fps])
	# ①d 帽 1 帧序语义：连续 10 帧手动 _physics_process——探针段逐帧重建无残留
	_gl2.stage_probe_enabled = true
	_gl2.state = GameConst.GameStatus.PLAYING
	var expected_order: Array = [&"input", &"player", &"grid_projectile", &"enemy",
		&"wave", &"feel", &"ui"]
	_other_min_seen = 1 << 30
	var frames_ok := true
	var size_ok := true
	var sentinel_ok := true
	var order_ok := true
	for i in range(10):
		_gl2.stage_probe_us[&"__qa_sentinel__"] = 1   # 上帧残留哨兵（合法键应被 clear）
		_gl2._physics_process(DT)
		if _gl2.stage_probe_us.has(&"__qa_sentinel__"):
			sentinel_ok = false
		if _gl2.stage_probe_us.size() != 16:
			size_ok = false
		var other_us := int(_gl2.stage_probe_us.get(&"other", -1))
		if other_us < 0:
			frames_ok = false
		_other_min_seen = mini(_other_min_seen, other_us)
		if i == 0:
			var fo: Array = _gl2.frame_order
			var fo_eq := fo.size() == expected_order.size()
			if fo_eq:
				for k in range(fo.size()):
					if StringName(fo[k]) != StringName(expected_order[k]):
						fo_eq = false
						break
			order_ok = fo_eq
	_check("①d 10 帧连续驱动：探针段逐帧重建（哨兵键每帧被 clear——无残留无累积）",
		sentinel_ok, "")
	_check("①d2 每帧恒 16 键（十五段+他——卡/特/跳/派 键不缺位不增键；R235 ③ 派发段常驻后 15→16）", size_ok,
		"末帧 size=%d" % _gl2.stage_probe_us.size())
	_check("①d3 帧序契约：frame_order 七步序（①输入→②玩家→④网格投射→⑤敌→⑥波→⑦感→⑧UI）",
		order_ok, str(_gl2.frame_order))
	_check("①d4 长跑他键非负：10 帧恒 ≥0（段和不得超全函数）", frames_ok,
		"min_other=%d" % (_other_min_seen if _other_min_seen < (1 << 30) else -1))


# ── ③ 他键（全函数 − 十五段互斥和） ────────────────────────────────
func _test_3_other_key() -> void:
	print("── ③ 他键 ──")
	var probe: Dictionary = _gl2.stage_probe_us
	_check("③a PLAYING 帧他键在位且 ≥0（①d 末帧原样——逐帧重建语义）",
		probe.has(&"other") and int(probe.get(&"other", -1)) >= 0,
		"other=%s" % str(probe.get(&"other", "缺")))
	# ③b peak 通道 + 清零钩
	_check("③b 他键 peak 通道在位（秒内尖峰口径）",
		_gl2.stage_probe_us_peak.has(&"other"),
		"peak keys=%s" % str(_gl2.stage_probe_us_peak.keys()))
	_gl2.diag_reset_stage_peaks()
	_check("③b2 diag_reset_stage_peaks 后无 other（清零钩——DebugStats 读取后清口径）",
		_gl2.stage_probe_us_peak.is_empty(), str(_gl2.stage_probe_us_peak.keys()))
	_gl2.stage_probe_us[&"__qa_sentinel__"] = 1
	_gl2._physics_process(DT)
	_check("③b3 次帧他键 peak 再现（钩后继续采样）",
		_gl2.stage_probe_us_peak.has(&"other") and int(_gl2.stage_probe_us_peak[&"other"]) >= 0,
		"peak_other=%s" % str(_gl2.stage_probe_us_peak.get(&"other", "缺")))
	# ③c MENU 帧 _probe_active 旗不写（无段记录 → 不算他）
	_gl2.state = GameConst.GameStatus.MENU
	_gl2.stage_probe_us = {&"__qa_sentinel__": 1}
	_gl2._physics_process(DT)
	var menu_probe: Dictionary = _gl2.stage_probe_us
	_check("③c MENU 帧：探针字典原样（哨兵仍在、无 other/popup 键——_probe_active 旗未置位）",
		menu_probe.size() == 1 and menu_probe.has(&"__qa_sentinel__")
			and not menu_probe.has(&"other") and not menu_probe.has(&"popup"),
		"keys=%s" % str(menu_probe.keys()))
	_gl2.stage_probe_us = {}
	_gl2.state = GameConst.GameStatus.PLAYING


# ── ④ 跳键（popup_manager.tick 独立计时） ──────────────────────────
func _test_4_popup_key() -> void:
	print("── ④ 跳键 ──")
	# ④a PLAYING 帧：popup/ui 双键分立，popup+ui ≤ 原⑧段总量（=旧 ui 口径包含关系）
	_gl2.stage_probe_us = {}
	_gl2._physics_process(DT)
	var probe: Dictionary = _gl2.stage_probe_us
	var popup_us := int(probe.get(&"popup", -1))
	var ui_us := int(probe.get(&"ui", -1))
	_check("④a PLAYING 帧 popup/ui 两键分立在位且 ≥0",
		probe.has(&"popup") and probe.has(&"ui") and popup_us >= 0 and ui_us >= 0,
		"popup=%d ui=%d" % [popup_us, ui_us])
	_check("④a2 包含关系：popup ≤ popup+ui 且原⑧段总量为正（跳字是⑧子集）",
		popup_us <= popup_us + ui_us and popup_us + ui_us > 0,
		"popup=%d 总=%d" % [popup_us, popup_us + ui_us])
	_check("④a3 同源：popup 键 == _ui_popup_us 成员（独立计时直写，非事后分摊）",
		int(_gl2._ui_popup_us) == popup_us,
		"member=%d key=%d" % [int(_gl2._ui_popup_us), popup_us])
	# ④b LEVEL_UP 双写点：选卡态同样有 popup 键（树暂停下 raw 臂）
	_gl2.change_state(GameConst.GameStatus.LEVEL_UP)
	_gl2.stage_probe_us = {}
	_gl2._physics_process(DT)
	var lv_probe: Dictionary = _gl2.stage_probe_us
	_check("④b LEVEL_UP 帧 popup 键在位且 ≥0（第二写点——选卡期跳字归因不盲区）",
		lv_probe.has(&"popup") and int(lv_probe.get(&"popup", -1)) >= 0,
		"popup=%s keys=%s" % [str(lv_probe.get(&"popup", "缺")), str(lv_probe.keys())])
	var gl_src: String = FileAccess.get_file_as_string("res://scripts/loop/game_loop.gd")
	_check("④b2 源级锚：popup/ui 扣除写点 PLAYING+LEVEL_UP 各一处（双写点=2）",
		gl_src.count("stage_probe_us[&\"popup\"] = _ui_popup_us") == 2
			and gl_src.count("stage_probe_us[&\"ui\"] = _ui_total_us - _ui_popup_us") == 2,
		"popup=%d ui=%d" % [gl_src.count("stage_probe_us[&\"popup\"] = _ui_popup_us"),
			gl_src.count("stage_probe_us[&\"ui\"] = _ui_total_us - _ui_popup_us")])
	_gl2.change_state(GameConst.GameStatus.PLAYING)
	# ④c 探针关时零写：popup/other 均不落（stage_probe_enabled=false 口径）
	_gl2.stage_probe_enabled = false
	_gl2.diag_reset_stage_peaks()
	_gl2.stage_probe_us = {}
	_gl2._physics_process(DT)
	_check("④c 探针关：PLAYING 帧零写（stage_probe_us 空、peak 空——诊断关闭零成本契约）",
		_gl2.stage_probe_us.is_empty() and _gl2.stage_probe_us_peak.is_empty(),
		"probe=%s peak=%s" % [str(_gl2.stage_probe_us.keys()),
			str(_gl2.stage_probe_us_peak.keys())])


# ── ⑤ 满载跳字帽（24/40 mobile 门内） ──────────────────────────────
func _test_5_fullload_cap() -> void:
	print("── ⑤ 满载跳字帽 ──")
	var pm_src: String = FileAccess.get_file_as_string("res://scripts/ui/popup_manager.gd")
	_check("⑤a 源级锚：cap = 24 if Enemy.fullload_dim() else 40（mobile 高档门内满载帽；R220 调速器档帽接线改 return→cap 变量形态）",
		pm_src.contains("cap = 24 if Enemy.fullload_dim() else 40"), "缺满载帽 24 行")
	_check("⑤b 桌面/headless 恒定：80/40/20（帽改动零扰动）",
		PopupManager.max_active_for(2) == 80 and PopupManager.max_active_for(1) == 40
			and PopupManager.max_active_for(0) == 20,
		"hi=%d mid=%d lo=%d" % [PopupManager.max_active_for(2),
			PopupManager.max_active_for(1), PopupManager.max_active_for(0)])
	Enemy.fullload_override = 1
	var hi_override: int = PopupManager.max_active_for(2)
	Enemy.fullload_override = -1
	_check("⑤c fullload_override=1 不影响桌面分支（mobile 门先决——override 只改 mobile 门内读数）",
		hi_override == 80 and PopupManager.max_active_for(2) == 80,
		"override_hi=%d" % hi_override)


# ── ⑥ 契约（DIAG 段序/标签/组N/余值三子集） ────────────────────────
func _test_6_contract() -> void:
	print("── ⑥ 契约 ──")
	# ⑥a 十六段序锁死（R220 刀1：card 拆 card_open/card_drain；popup 插 fx 后 ui 前、other 殿后）
	var order: Array[StringName] = [&"player", &"player_mv", &"player_wp", &"shard",
		&"grid_rebuild", &"grid_projectile", &"enemy", &"wave", &"feel_shard",
		&"feel", &"fx", &"popup", &"ui", &"card_open", &"card_drain", &"other"]
	_check("⑥a DIAG_STAGE_ORDER 十六段序锁死（popup 位次 fx<popup<ui、other 殿后）",
		DebugStats.DIAG_STAGE_ORDER == order and DebugStats.DIAG_STAGE_ORDER.size() == 16,
		str(DebugStats.DIAG_STAGE_ORDER))
	# ⑥b tags：跳/他/开/消 全 16 键映射
	var tags_ok: bool = DebugStats.DIAG_STAGE_TAGS.size() == 16
	for key in DebugStats.DIAG_STAGE_ORDER:
		if not DebugStats.DIAG_STAGE_TAGS.has(key):
			tags_ok = false
	_check("⑥b tags 全 16 键映射 + 跳/他/开/消 对位",
		tags_ok and str(DebugStats.DIAG_STAGE_TAGS.get(&"popup", "")) == "跳"
			and str(DebugStats.DIAG_STAGE_TAGS.get(&"other", "")) == "他"
			and str(DebugStats.DIAG_STAGE_TAGS.get(&"card_open", "")) == "开"
			and str(DebugStats.DIAG_STAGE_TAGS.get(&"card_drain", "")) == "消",
		"tags=%s" % str(DebugStats.DIAG_STAGE_TAGS))
	# ⑥c 合成帧函数级：非子集段精确落行 + 余值三子集跳过（子集合计 6s 不进余值）
	var ds: Node = _new_diag_formatter()
	_gl2.stage_probe_us = {&"player": 1000, &"player_mv": 2000000, &"player_wp": 2000000,
		&"popup": 2000000, &"ui": 2000, &"other": 3000}
	var line_syn: String = String(ds.call(&"_diag_format_line", _gl2, Time.get_ticks_msec()))
	var seg_ok: bool = line_syn.contains("玩1") and line_syn.contains("移2000") \
		and line_syn.contains("火2000") and line_syn.contains("跳2000") \
		and line_syn.contains("UI2") and line_syn.contains("他3")
	_check("⑥c 合成探针帧：十五段逐标签落行（玩1/移2000/火2000/跳2000/UI2/他3）", seg_ok,
		line_syn.right(160))
	var fps := maxi(_extract_int(line_syn, "fps"), 1)
	var expect_yu := maxi(int(round(1000.0 / float(fps) - 6.0)), 0)
	var actual_yu := _extract_int(line_syn, "余")
	_check("⑥c2 余值三子集跳过（函数级）：余=%d == 帧预算−6ms 非子集和（6s 子集被跳过）" % expect_yu,
		actual_yu == expect_yu,
		"actual=%d expect=%d fps=%d" % [actual_yu, expect_yu, fps])
	# ⑥d 空探针帧：全 16 段零值逐位落行 + 组N 与 diag_counts 同源
	_gl2.stage_probe_us = {}
	var counts: Dictionary = _gl2.diag_counts()
	var line_zero: String = String(ds.call(&"_diag_format_line", _gl2, Time.get_ticks_msec()))
	var zero16 := "玩0 移0 火0 碎0 网0 弹0 敌0 波0 磁0 感0 特0 跳0 UI0 开0 消0 他0"
	_check("⑥d 空探针帧：十六段零值全串逐位落行（段序+标签一体锁）",
		line_zero.contains(zero16), line_zero.right(160))
	_check("⑥d2 diag 行含 组N 且与 diag_counts 同源（组%d）" % int(counts[&"tint_groups"]),
		line_zero.contains("组%d" % int(counts[&"tint_groups"])), line_zero.right(160))
	ds.free()
	# ⑥e 余值跳过源级锚（debug_stats 三子集条件）
	var ds_src: String = FileAccess.get_file_as_string("res://autoload/debug_stats.gd")
	_check("⑥e 源级锚：余值求和跳过 移/火/跳 三子集键（他已含未捕获部分）",
		ds_src.contains("if key != &\"player_mv\" and key != &\"player_wp\" and key != &\"popup\":"),
		"缺三子集跳过门")


# ── ⑦ 回归面（R212 限批 / R206 峰值采样） ──────────────────────────
func _test_7_regression() -> void:
	print("── ⑦ 回归面 ──")
	# ⑦a R212 跳字排版限批：label_refresh 计数不受 R218 帽/拆键改动影响
	var pm: PopupManager = _gl2.popup_manager
	var numbers_prev: bool = bool(Meta.settings("damage_numbers_on"))
	var quality_prev: int = int(Meta.settings("fx_quality"))
	Meta.set_setting("damage_numbers_on", true)
	Meta.set_setting("fx_quality", 2)
	pm.clear_all()
	pm.label_refresh_cap_override = 6
	for i in range(40):
		var r := DamageResult.new()
		r.final_value = 10.0
		r.target_uid = 218000 + i
		r.pos = Vector2(360.0, 400.0)
		r.popup_style = GameConst.PopupStyle.NORMAL
		pm.on_damage_resolved(r)
	for i in range(40):                           # 同 uid 二次结算 → merge 只置脏
		var r2 := DamageResult.new()
		r2.final_value = 5.0
		r2.target_uid = 218000 + i
		r2.pos = Vector2(360.0, 400.0)
		r2.popup_style = GameConst.PopupStyle.NORMAL
		pm.on_damage_resolved(r2)
	var dirty0 := 0
	for p in pm._active_list:
		if p._label_dirty:
			dirty0 += 1
	_check("⑦a 前置：40 张活跃弹字全置脏（merge 置脏链不受拆键计时影响）",
		pm._active_list.size() == 40 and dirty0 == 40,
		"active=%d dirty=%d" % [pm._active_list.size(), dirty0])
	DamagePopup.refresh_label_calls = 0
	pm.tick(DT)
	var batch1: int = DamagePopup.refresh_label_calls
	_check("⑦a2 限批生效：首帧排版刷新 ∈ (0,6]（R212 刀5 口径原样）",
		batch1 > 0 and batch1 <= 6, "batch=%d" % batch1)
	var frames := 1
	var dirty_left := 1
	while frames < 12:
		var d := 0
		for p in pm._active_list:
			if p._label_dirty:
				d += 1
		if d == 0:
			dirty_left = 0
			break
		pm.tick(DT)
		frames += 1
	_check("⑦a3 轮转收敛：40 张脏字 ≤7 帧全清（ceil(40/6)=7——帽改动后节奏不变）",
		dirty_left == 0 and frames <= 7, "frames=%d dirty=%d" % [frames, dirty_left])
	pm.label_refresh_cap_override = 0
	for i in range(40):
		var r3 := DamageResult.new()
		r3.final_value = 5.0
		r3.target_uid = 218000 + i
		r3.pos = Vector2(360.0, 400.0)
		r3.popup_style = GameConst.PopupStyle.NORMAL
		pm.on_damage_resolved(r3)
	DamagePopup.refresh_label_calls = 0
	pm.tick(DT)
	_check("⑦a4 不限批对照（覆写 0）：一帧 40 张全量刷新（桌面行为不变）",
		DamagePopup.refresh_label_calls == 40,
		"calls=%d" % DamagePopup.refresh_label_calls)
	pm.clear_all()
	pm.label_refresh_cap_override = -1
	Meta.set_setting("damage_numbers_on", numbers_prev)
	Meta.set_setting("fx_quality", quality_prev)

	# ⑦b R206 峰值采样：尖峰Xms 标记 + 读取后清零钩仍工作（他键峰值走同一通道）
	_gl2.stage_probe_enabled = true
	_gl2.stage_probe_us = {}
	_gl2.diag_reset_stage_peaks()
	_gl2._physics_process(DT)
	_check("⑦b 探针帧后 peak 有机值在位（other 通道采样仍挂）",
		_gl2.stage_probe_us_peak.has(&"other"),
		str(_gl2.stage_probe_us_peak.keys()))
	_gl2.stage_probe_us_peak[&"ui"] = 30000       # 注入 30ms UI 峰值（≥25ms 标记阈）
	var ds2: Node = _new_diag_formatter()
	var line_peak: String = String(ds2.call(&"_diag_format_line", _gl2, Time.get_ticks_msec()))
	ds2.free()
	_check("⑦b2 尖峰标记：行含「尖峰UI30ms」（R206 口径 + 新他键峰值同表）",
		line_peak.contains("尖峰UI30ms"), line_peak.right(120))
	_check("⑦b3 读取后清零：diag_reset_stage_peaks 钩随采样触发（峰值不跨秒残留）",
		_gl2.stage_probe_us_peak.is_empty(), str(_gl2.stage_probe_us_peak.keys()))
	_gl2.stage_probe_enabled = false
