# tests/runner/r218_simbound_cases.gd
# R218 用例体：vc25 定案驱动三刀（二j #1~#4）。
# ① 刀B 追赶帽 2→1 源级锚（fps≥60 无操作、螺旋段单步）。
# ② 刀A 分组N：敌桶内 distinct 色元组数=真合批分组（同值敌同组——断N 高计的补口径）。
# ③ 刀A 他键：物理帧全函数 − 十五段互斥和（未捕获 GDScript 归因——vc25 余 15-56ms）。
# ④ 刀C 跳键：popup_manager.tick 独立计时与 UI 键分立；满载跳字帽 40→24 源级锚。
extends RefCounted

const MAIN_SCENE := "res://scenes/main.tscn"
const DT := 1.0 / 60.0
const EPS := 0.0001

var tree: SceneTree
var _pass: int = 0
var _fail: int = 0
var _failures: Array[String] = []
var _gl: GameLoop = null


func run(p_tree: SceneTree) -> void:
	tree = p_tree
	seed(42)
	_boot_game_loop()
	await tree.process_frame
	await tree.process_frame
	_test_1_cap_anchor()
	_test_2_tint_groups()
	_test_3_other_key()
	_test_4_popup_split()
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
		print("  PASS | %s" % p_name)
	else:
		_fail += 1
		_failures.append("%s（%s）" % [p_name, p_detail])
		print("  FAIL | %s（%s）" % [p_name, p_detail])


func _boot_game_loop() -> void:
	var main: Node = load(MAIN_SCENE).instantiate()
	tree.root.add_child(main)
	await tree.process_frame
	_gl = tree.root.get_node_or_null("Main") as GameLoop
	if _gl == null:
		for c in tree.root.get_children():
			if c is GameLoop:
				_gl = c
				break


func _teardown_game_loop() -> void:
	if _gl != null:
		_gl.queue_free()
		await tree.process_frame


func _fixture_enemy(p_id: StringName, p_hp: float) -> EnemyData:
	var d := EnemyData.new()
	d.id = p_id
	d.display_name = String(p_id)
	d.hp_base = p_hp
	d.spd_base = 0.0
	d.dmg_base = 0.0
	d.exp_base = 1.0
	d.hitbox_r = 14.0
	d.resist = [0.0, 0.0, 0.0, 0.0]
	return d


func _spawn_enemy(p_id: StringName) -> Enemy:
	var pool := _gl.pools[&"enemy"] as EnemyPool
	var e := pool.acquire() as Enemy
	e.spawn(_fixture_enemy(p_id, 100.0), 1, 0)
	e._fade_left = 0.0
	e.modulate.a = 1.0
	return e


func _release_enemy(p_e: Enemy) -> void:
	(_gl.pools[&"enemy"] as EnemyPool).release(p_e)


# ── ① 刀B 追赶帽源级锚 ────────────────────────────────────────────
func _test_1_cap_anchor() -> void:
	print("── ① 追赶帽 2→1 ──")
	var src: String = FileAccess.get_file_as_string("res://scripts/meta/meta_manager.gd")
	_check("①帽 2→1 源级锚（fps≥60 无操作；螺旋段单步减半）",
		src.contains("Engine.max_physics_steps_per_frame = 1"),
		"缺掐帽 1 行")
	_check("①headless 运行时缺省 8 不动（桌面零扰动）",
		Engine.max_physics_steps_per_frame == 8,
		"actual=%d" % Engine.max_physics_steps_per_frame)


# ── ② 刀A 分组N：真合批分组 ────────────────────────────────────────
func _test_2_tint_groups() -> void:
	print("── ② 分组N ──")
	var counts0: Dictionary = _gl.diag_counts()
	_check("②diag_counts 新键 tint_groups 在位（MENU 空场=0，敌入场≥1——下方 +1 用例证）",
		counts0.has(&"tint_groups") and int(counts0[&"tint_groups"]) >= 0,
		"keys=%s" % str(counts0.keys()))
	var base_groups: int = int(counts0[&"tint_groups"])
	# 3 只同状态（冻结固定系数）敌 → 同帧同色同组：分组 +1 而非 +3（断N 高计的对照）
	var frozen: Array[Enemy] = []
	for i in 3:
		var e := _spawn_enemy(&"E_R218_G%d" % i)
		var st := ElementalState.new()
		st.freeze_timer = 5.0
		e.elemental = st
		e.call(&"_apply_body_tint", 0.0)
		frozen.append(e)
		_gl.spawner.active.append(e)
	var c1: Dictionary = _gl.diag_counts()
	_check("②3 只同状态敌 → 分组 +1（同值同批——真合批分组语义）",
		int(c1[&"tint_groups"]) == base_groups + 1,
		"base=%d now=%d" % [base_groups, int(c1[&"tint_groups"])])
	_check("②对照：断N 计 3（非白敌数——高计口径，分组才是断批上限）",
		int(c1[&"tinted_enemies"]) >= 3,
		"tinted=%d" % int(c1[&"tinted_enemies"]))
	# 1 只异档敌（满载强闪——R237 闪白批化契约迁移后走白变体贴图、modulate 恒白，
	# 与冻结蓝染异键）→ 分组再 +1（distinct 元组=分组上限——语义不变仍成立）
	Enemy.fullload_override = 1
	var fl := _spawn_enemy(&"E_R218_FL")
	fl.call(&"_apply_flash", 1.0)
	_gl.spawner.active.append(fl)
	var c2: Dictionary = _gl.diag_counts()
	_check("②异档敌入场 → 分组 +1（distinct 元组=分组上限）",
		int(c2[&"tint_groups"]) == base_groups + 2,
		"base=%d now=%d" % [base_groups, int(c2[&"tint_groups"])])
	fl.call(&"_apply_flash", 0.0)
	Enemy.fullload_override = -1
	_gl.spawner.active.erase(fl)
	_release_enemy(fl)

	for e in frozen:
		_gl.spawner.active.erase(e)
		_release_enemy(e)
	var c3: Dictionary = _gl.diag_counts()
	_check("②归还后分组回基线",
		int(c3[&"tint_groups"]) == base_groups,
		"base=%d now=%d" % [base_groups, int(c3[&"tint_groups"])])
	# 修轮#1 用例（评审盲区）——R237 闪白批化契约迁移：满载闪白贴图化后三敌 modulate
	# 全白同组（恰 +1），强/弱/本体档差移至贴图通道三态分明（修轮#1「浮点键不折叠」
	# 语义由贴图桶承接——同贴图同桶=同批）
	Enemy.fullload_override = 1
	var mix: Array[Enemy] = []
	var ids: Array[StringName] = [&"E_R218_M0", &"E_R218_M1", &"E_R218_M2"]
	for i in 3:
		var me := _spawn_enemy(ids[i])
		mix.append(me)
		_gl.spawner.active.append(me)
	mix[0].call(&"_apply_flash", 1.0)               # 强档白变体
	mix[1].call(&"_apply_flash", 0.3)               # 弱档白变体
	# mix[2] 保持本体
	var cm: Dictionary = _gl.diag_counts()
	_check("②闪白混合场：强/弱/本体 三敌 → 分组恰 +1（modulate 全白同键）+ 贴图三态分明（R237 契约迁移）",
		int(cm[&"tint_groups"]) == base_groups + 1
			and mix[0]._sprite.texture != mix[1]._sprite.texture
			and mix[1]._sprite.texture != mix[2]._sprite.texture
			and mix[0]._sprite.texture != mix[2]._sprite.texture,
		"base=%d now=%d" % [base_groups, int(cm[&"tint_groups"])])
	for me in mix:
		me.call(&"_apply_flash", 0.0)
		_gl.spawner.active.erase(me)
		_release_enemy(me)
	Enemy.fullload_override = -1


# ── ③ 刀A 他键：未捕获 GDScript 归因 ───────────────────────────────
func _test_3_other_key() -> void:
	print("── ③ 他键 ──")
	_gl.stage_probe_enabled = true
	_gl.state = GameConst.GameStatus.PLAYING
	_gl._physics_process(DT)
	var probe: Dictionary = _gl.stage_probe_us
	_check("③PLAYING 帧他键在位且 ≥0（全函数−段和）",
		probe.has(&"other") and int(probe.get(&"other", -1)) >= 0,
		"other=%s" % str(probe.get(&"other", "缺")))
	_check("③他峰值通道在位（秒内尖峰口径）",
		_gl.stage_probe_us_peak.has(&"other"),
		"peak keys=%s" % str(_gl.stage_probe_us_peak.keys()))
	_check("③十五段段序：popup 在 ui 前、other 殿后",
		DebugStats.DIAG_STAGE_ORDER.find(&"popup") < DebugStats.DIAG_STAGE_ORDER.find(&"ui")
			and DebugStats.DIAG_STAGE_ORDER.rfind(&"other") == DebugStats.DIAG_STAGE_ORDER.size() - 1,
		"order=%s" % str(DebugStats.DIAG_STAGE_ORDER))


# ── ④ 刀C 跳键 + 满载跳字帽 ────────────────────────────────────────
func _test_4_popup_split() -> void:
	print("── ④ 跳键拆分 ──")
	var probe: Dictionary = _gl.stage_probe_us
	_check("④PLAYING 帧跳键在位且 ≥0（popup_manager.tick 独立计时）",
		probe.has(&"popup") and int(probe.get(&"popup", -1)) >= 0,
		"popup=%s" % str(probe.get(&"popup", "缺")))
	_check("④跳/他标签映射在位",
		str(DebugStats.DIAG_STAGE_TAGS.get(&"popup", "")) == "跳"
			and str(DebugStats.DIAG_STAGE_TAGS.get(&"other", "")) == "他",
		"tags=%s" % str(DebugStats.DIAG_STAGE_TAGS))
	var gl_src: String = FileAccess.get_file_as_string("res://scripts/loop/game_loop.gd")
	_check("④跳键源级锚：⑧ 段写点 = 总量−跳 双处（UI 键扣除跳字耗时）",
		gl_src.count("stage_probe_us[&\"popup\"] = _ui_popup_us") == 2
			and gl_src.count("stage_probe_us[&\"ui\"] = _ui_total_us - _ui_popup_us") == 2,
		"popup 写点=%d ui 扣除=%d" % [gl_src.count("stage_probe_us[&\"popup\"] = _ui_popup_us"),
			gl_src.count("stage_probe_us[&\"ui\"] = _ui_total_us - _ui_popup_us")])
	var pm_src: String = FileAccess.get_file_as_string("res://scripts/ui/popup_manager.gd")
	_check("④满载跳字帽源级锚：40→24（mobile 高档门内 fullload_dim；R220 调速器档帽接线改 return→cap 变量形态）",
		pm_src.contains("cap = 24 if Enemy.fullload_dim() else 40"),
		"缺满载帽 24 行")
	_check("④桌面高档帽不变（80——满载 24 只在 mobile 门内）",
		PopupManager.max_active_for(2) == 80 and PopupManager.max_active_for(1) == 40
			and PopupManager.max_active_for(0) == 20,
		"hi=%d mid=%d lo=%d" % [PopupManager.max_active_for(2),
			PopupManager.max_active_for(1), PopupManager.max_active_for(0)])
	# 他键段和口径：余值求和跳过 移/火 两子集（debug_stats 源级锚）
	# R268 追认迁移（主会话授权窄迁移）：R268 P2 有意把 popup 移出排除表（tick 归我方
	# 段和入减项——debug_stats.gd「R268 性能刀 P2：popup 出排除表」注释在案，勿按旧
	# 「三子集」口径改回）；锚文本重锚 R268 后现状，意图不变=锁排除表成员语义
	#（两子集跳过门在位 + popup 出表语义锚在位，防任一侧静默回退）。
	var ds_src: String = FileAccess.get_file_as_string("res://autoload/debug_stats.gd")
	_check("④余值求和跳过 移/火 两子集键，popup 已入减项（他已含未捕获部分——R268 P2 后口径）",
		ds_src.contains("if key != &\"player_mv\" and key != &\"player_wp\":")
			and ds_src.contains("R268 性能刀 P2：popup 出排除表"),
		"缺两子集跳过门或 popup 出表语义锚")
