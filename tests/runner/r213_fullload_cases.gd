# tests/runner/r213_fullload_cases.gd
# R213 用例体：渲染四案满载门（vc20 真机定案驱动——120 敌满载 dc361-1020/o2635、
# fps12-35，帧预算大头在引擎侧）。
# 四案同门同判据（Enemy.fullload_dim：mobile 且活敌≥80；headless 以覆写口验收
# ——r207_split 先例）：
#   A 敌状态件归 0 档（染色/余烬保留，降档显隐/回升补建走 30Hz 写点）
#   B 普命中粒子关（CRIT 保留）+ DOT 跳伤表现关（源级锚——on_hit 构造重）
#   C 受击闪白去 shader 化（modulate 白乘；与 self_modulate 染色分通道；门回落
#     边界双通道互复位零残留）
#   D XP 新掉落并最近珠（数值守恒 merge_value；碎片空场仍走新珠）
# 附：定标遥测（diag_counts status_enemies + 诊断行「态」段）与磁/网拆键标签。
extends RefCounted

const MAIN_SCENE := "res://scenes/main.tscn"
const PLAYER_HOME := Vector2(360.0, 900.0)
const DT := 1.0 / 120.0

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
	_test_1_gate_truth_and_override()
	_enter_run_frozen()
	_test_2_a_state_fx_dim()
	_test_3_c_flash_dim()
	_test_4_d_xp_merge()
	_test_5_telemetry()
	_test_6_b_source_anchors_and_desktop_zero()
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
	var scene: PackedScene = load(MAIN_SCENE)
	_gl = scene.instantiate() as GameLoop
	_gl.name = "R213GameLoopUnderTest"
	tree.get_root().add_child(_gl)   # _ready → boot（七池预热同步完成）


func _enter_run_frozen() -> void:
	# r212 同构：start_run 后置回 MENU 冻结波次（静止环境）
	_gl.state = GameConst.GameStatus.MENU
	_gl.current_map_id = MapTable.FIRST_MAP_ID
	_gl.start_run()
	_gl.state = GameConst.GameStatus.MENU
	_gl.player.global_position = PLAYER_HOME


func _teardown_game_loop() -> void:
	Enemy.fullload_override = -1                  # 覆写口复位（防跨套件泄漏）
	Enemy._fullload_latched = false               # 滞回锁存态复位（headless 真值恒 false，防御）
	Meta.set_setting(&"fx_quality", 2)            # 档位回出厂高档（verify ⑪ 同口径）
	tree.paused = false
	RunSave.clear()
	if _gl != null:
		_gl.free()
		_gl = null


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


# ── ① 门真值 + 覆写口三态 ───────────────────────────────────────
func _test_1_gate_truth_and_override() -> void:
	print("── ① 满载门真值与覆写口 ──")
	_check("门限常量 FULLLOAD_ENEMY_MIN == 80（素材 A~D 同判据）",
		Enemy.FULLLOAD_ENEMY_MIN == 80, "min=%d" % Enemy.FULLLOAD_ENEMY_MIN)
	var src := FileAccess.open("res://scripts/entities/enemy/enemy.gd", FileAccess.READ)
	var enemy_src := src.get_as_text() if src != null else ""
	src.close()
	_check("真值门源级锚（mobile ∧ live_count ≥ 门限——headless 不可注入 mobile 特性）",
		enemy_src.contains("OS.has_feature(\"mobile\") and live_count >= FULLLOAD_ENEMY_MIN"),
		"缺真值判据")
	_check("评审#2 滞回结构在位（开 ≥80 / 关 <72 + 锁存态——防 79/80 震荡闪烁）",
		enemy_src.contains("FULLLOAD_ENEMY_RELEASE") and enemy_src.contains("_fullload_latched")
			and enemy_src.contains("&\"fullload_flips\""),
		"缺滞回/翻转计数结构")
	_check("headless 缺省门=关（桌面基准零扰动；override=-1 真值）",
		Enemy.fullload_override == -1 and Enemy.fullload_dim() == false,
		"override=%d dim=%s" % [Enemy.fullload_override, str(Enemy.fullload_dim())])
	Enemy.fullload_override = 1
	_check("覆写口=1 → 门开（headless 模拟满载）", Enemy.fullload_dim() == true,
		"dim=%s" % str(Enemy.fullload_dim()))
	Enemy.fullload_override = 0
	_check("覆写口=0 → 门关（模拟敌数回落）", Enemy.fullload_dim() == false,
		"dim=%s" % str(Enemy.fullload_dim()))
	Enemy.fullload_override = -1
	_check("覆写口复位 -1（真值门）", Enemy.fullload_dim() == false,
		"dim=%s" % str(Enemy.fullload_dim()))


# ── ② A 案：敌状态件满载归 0 档（染色/余烬保留 + 降档显隐 + 回升补建） ──
func _test_2_a_state_fx_dim() -> void:
	print("── ② A 状态件降档 ──")
	Meta.set_setting(&"fx_quality", 2)             # 高档口径（verify ⑪ 同款钉档）
	var enemy := (_gl.pools[&"enemy"] as EnemyPool).acquire()
	enemy.spawn(_fixture_enemy(&"E_R213_A", 100000.0), 1, 0)
	_gl.elemental.register_host(enemy)
	var st: ElementalState = enemy.elemental
	# 高档建满挂件（感电双弧）→ 覆写=1 降档 → 超额弧隐藏；余烬/染色保留
	st.gauges[GameConst.Element.LTG] = 50.0
	enemy.call(&"_tick_status_fx", DT)
	var arcs_hi: int = (enemy.get("_shock_arcs") as Array).size()
	_check("高档预建：感电弧建件 %d（>0，建满前提）" % arcs_hi, arcs_hi > 0,
		"arcs=%d" % arcs_hi)
	Enemy.fullload_override = 1
	_check("A 门开：_state_fx_q()==0（状态件档归 0）", Enemy._state_fx_q() == 0,
		"q=%d" % Enemy._state_fx_q())
	# 跨 30Hz 写点节拍（R202 ⑤ 写透条件③：签名未变时须节拍到点才刷新挂件显隐——
	# 5×DT > STATUS_FX_WRITE_INTERVAL 1/30，单次调用不跨拍会被节流挡下）
	for i in range(5):
		enemy.call(&"_tick_status_fx", DT)
	var arcs_visible: int = 0
	for arc in (enemy.get("_shock_arcs") as Array):
		if (arc as Line2D).visible:
			arcs_visible += 1
	_check("满载降档：电弧全隐（预算 0——降档显隐机制）", arcs_visible == 0,
		"visible=%d" % arcs_visible)
	var bolt: Line2D = enemy.get("_shock_bolt")
	_check("满载降档：落雷不可见（低档关）", bolt == null or not bolt.visible,
		"bolt=%s" % str(bolt != null and bolt.visible))
	# 点燃：余烬满载同隐（R217 修轮评审#1 有意契约变更——异贴图桶内断批且 断N 不可见，
	# 满载「在烧」读感由本体量化呼吸独自承担，同冻结口径）+ 染色走 self_modulate
	st.gauges[GameConst.Element.LTG] = 0.0
	st.apply(GameConst.Element.FIR, 100.0, 100.0)
	enemy.call(&"_tick_status_fx", DT)
	var ember: Sprite2D = enemy.get("_burn_ember")
	_check("满载点燃：余烬光晕同隐（R217 修轮——异贴图桶内断批根修）",
		ember == null or not ember.visible,
		"ember=%s" % str(ember != null and ember.visible))
	var flames_visible: int = 0
	for f in (enemy.get("_burn_flames") as Array):
		if (f as Sprite2D).visible:
			flames_visible += 1
	_check("满载点燃：火苗全隐（档 0 预算）", flames_visible == 0,
		"flames_visible=%d" % flames_visible)
	var sprite: Sprite2D = enemy.get("_sprite")
	_check("满载点燃：本体染色保留（self_modulate ≠ 纯白——「在烧」读感）",
		sprite != null and sprite.self_modulate != Color.WHITE,
		"tint=%s" % str(sprite.self_modulate if sprite != null else null))
	# 回升：覆写=0 → 30Hz 写点补建/复显
	Enemy.fullload_override = 0
	_check("门回落：_state_fx_q() 回 _fx_q()（高档 2）", Enemy._state_fx_q() == 2,
		"q=%d" % Enemy._state_fx_q())
	for i in range(5):                          # 同跨 30Hz 写点节拍（签名未变）
		enemy.call(&"_tick_status_fx", DT)
	var flames_back: int = 0
	for f in (enemy.get("_burn_flames") as Array):
		if (f as Sprite2D).visible:
			flames_back += 1
	_check("门回落：火苗复显（敌数回落自动恢复）", flames_back > 0,
		"flames_back=%d" % flames_back)
	_gl.elemental.unregister_host(enemy)
	(_gl.pools[&"enemy"] as EnemyPool).release(enemy)


# ── ③ C 案：闪白去 shader 化（贴图化闪白/材质零挂 + 门回落零残留；R237 闪白批化
#    契约迁移：满载闪白 modulate 白乘 → 白变体贴图换桶，断言改读 texture 通道） ──
func _test_3_c_flash_dim() -> void:
	print("── ③ C 闪白去 shader 化 ──")
	var enemy := (_gl.pools[&"enemy"] as EnemyPool).acquire()
	enemy.spawn(_fixture_enemy(&"E_R213_C", 100000.0), 1, 0)
	var sprite: Sprite2D = enemy.get("_sprite")
	var material: ShaderMaterial = enemy.get("_material")
	# 满载：白变体贴图 + 零材质（R237 闪白批化契约迁移）
	Enemy.fullload_override = 1
	enemy.call(&"_apply_flash", 1.0)
	_check("满载闪白：不挂 ShaderMaterial（批处理不打断）",
		sprite.material == null, "mat=%s" % str(sprite.material))
	_check("满载闪白：texture==强白变体 且 modulate==WHITE（R237 闪白批化契约迁移——原 modulate 白乘断言改读贴图通道）",
		sprite.texture == TextureFactory.enemy_tex_flash(&"grunt", false, true)
			and sprite.modulate == Color.WHITE,
		"tex=%s mod=%s" % [str(sprite.texture), str(sprite.modulate)])
	enemy.call(&"_apply_flash", 0.0)
	_check("满载闪灭：modulate 复位纯白 + texture 复位本体（R237 契约迁移）",
		sprite.modulate == Color.WHITE
			and sprite.texture == TextureFactory.enemy_tex(&"grunt"),
		"mod=%s tex=%s" % [str(sprite.modulate), str(sprite.texture)])
	# 门回落：shader 路径 + 白乘残留复位
	Enemy.fullload_override = 0
	enemy.call(&"_apply_flash", 1.0)
	_check("回落闪白：材质挂回（原路径）", sprite.material == material,
		"mat=%s" % str(sprite.material))
	_check("回落闪白：满载期白乘残留被复位", sprite.modulate == Color.WHITE,
		"mod=%s" % str(sprite.modulate))
	# 边界：shader 窗内切满载 → 材质摘除改白变体贴图（R237 契约迁移：白乘 → 贴图；
	# 0.5 为强档界点——R217 量化口径 p_amount>=0.5 归强档）
	Enemy.fullload_override = 1
	enemy.call(&"_apply_flash", 0.5)
	_check("窗内切满载：材质摘除 + 强档白变体贴图接管（R237 闪白批化契约迁移）",
		sprite.material == null
			and sprite.texture == TextureFactory.enemy_tex_flash(&"grunt", false, true)
			and sprite.modulate == Color.WHITE,
		"mat=%s tex=%s" % [str(sprite.material), str(sprite.texture)])
	# QA-R213-001 回归锁：满载白变体残留经「门关 + 池复用归零口」必须复位——
	# 门开期受击（白变体在身、材质已摘）→ 门关 → _reset_state/_apply_flash(0.0)
	# → 必须换回本体贴图（R237 契约迁移后残留通道=texture）
	Enemy.fullload_override = 0
	enemy.call(&"_apply_flash", 0.0)
	_check("QA-R213-001：门关后归零口复位白乘/白变体（池复用零残留——R237 契约迁移含贴图通道）",
		sprite.modulate == Color.WHITE and sprite.material == null
			and sprite.texture == TextureFactory.enemy_tex(&"grunt"),
		"mod=%s mat=%s tex=%s" % [str(sprite.modulate), str(sprite.material), str(sprite.texture)])
	enemy.call(&"_apply_flash", 0.0)
	Enemy.fullload_override = -1
	(_gl.pools[&"enemy"] as EnemyPool).release(enemy)


# ── ④ D 案：满载 XP 并珠（数值守恒 + 最近合并 + 空场新珠） ──
func _test_4_d_xp_merge() -> void:
	print("── ④ D XP 并珠 ──")
	var shards: Array = _gl.get("active_shards")
	shards.clear()                                 # 静止环境（frozen run 无自然掉落）
	# 门关：独立掉落
	Enemy.fullload_override = 0
	_gl.call(&"_spawn_xp_shard", Vector2(100.0, 200.0), 10.0, 4.0)
	_gl.call(&"_spawn_xp_shard", Vector2(600.0, 200.0), 20.0, 4.0)
	_check("门关：两次掉落两颗独立珠", shards.size() == 2, "size=%d" % shards.size())
	# 门开：新掉落并入最近珠（数量不变 + 面值守恒）
	Enemy.fullload_override = 1
	_gl.call(&"_spawn_xp_shard", Vector2(120.0, 200.0), 40.0, 4.0)   # 距第一颗 20px、第二颗 480px
	_check("门开：新掉落不占新珠（并最近）", shards.size() == 2, "size=%d" % shards.size())
	var near: XpShard = shards[0]
	var far: XpShard = shards[1]
	_check("并珠目标=最近碎片", near.value == 50.0 and far.value == 20.0,
		"near=%f far=%f" % [near.value, far.value])
	_check("数值守恒：面值合计 == 掉落合计（10+20+40）",
		near.value + far.value == 70.0, "sum=%f" % (near.value + far.value))
	# 空场边界：无活跃碎片仍走新珠
	for s in shards.duplicate():
		(_gl.pools[&"xp"] as XPPool).release(s)
	shards.clear()
	_gl.call(&"_spawn_xp_shard", Vector2(300.0, 300.0), 5.0, 4.0)
	_check("空场边界：无活跃碎片走新珠", shards.size() == 1 and (shards[0] as XpShard).value == 5.0,
		"size=%d" % shards.size())
	Enemy.fullload_override = -1
	for s in shards.duplicate():
		(_gl.pools[&"xp"] as XPPool).release(s)
	shards.clear()


# ── ⑤ 定标遥测：status_enemies 计数 + 诊断行「态」段 + 磁/网拆键 ──
func _test_5_telemetry() -> void:
	print("── ⑤ 定标遥测 ──")
	var counts: Dictionary = _gl.diag_counts()
	_check("diag_counts 新键 status_enemies 在位（int ≥0）",
		counts.has(&"status_enemies") and int(counts[&"status_enemies"]) >= 0,
		"counts=%s" % str(counts.keys()))
	# 真实计数：往 spawner.active 注入一状态敌一无状态敌（测毕即还原）
	var enemy_a := (_gl.pools[&"enemy"] as EnemyPool).acquire()
	enemy_a.spawn(_fixture_enemy(&"E_R213_T1", 100.0), 1, 0)
	_gl.elemental.register_host(enemy_a)
	(enemy_a.elemental as ElementalState).gauges[GameConst.Element.FIR] = 60.0
	var enemy_b := (_gl.pools[&"enemy"] as EnemyPool).acquire()
	enemy_b.spawn(_fixture_enemy(&"E_R213_T2", 100.0), 1, 0)
	_gl.elemental.register_host(enemy_b)
	var active: Array = _gl.spawner.get("active")
	active.append(enemy_a)
	active.append(enemy_b)
	var cnt: int = int(_gl.diag_counts()[&"status_enemies"])
	_check("状态敌计数真实值（带元素 1/2）", cnt == 1, "cnt=%d" % cnt)
	active.erase(enemy_a)
	active.erase(enemy_b)
	_gl.elemental.unregister_host(enemy_a)
	_gl.elemental.unregister_host(enemy_b)
	(_gl.pools[&"enemy"] as EnemyPool).release(enemy_a)
	(_gl.pools[&"enemy"] as EnemyPool).release(enemy_b)
	# 诊断行：态段 + 磁/网标签
	var line: String = DebugStats._diag_format_line(_gl, Time.get_ticks_msec())
	_check("诊断行含「态」段（A 案定标口径）", line.contains("态"),
		"line=%s" % line)
	_check("拆键标签在位（网=grid_rebuild / 磁=feel_shard）",
		str(DebugStats.DIAG_STAGE_TAGS.get(&"grid_rebuild", "")) == "网"
			and str(DebugStats.DIAG_STAGE_TAGS.get(&"feel_shard", "")) == "磁",
		"tags=%s" % str(DebugStats.DIAG_STAGE_TAGS))
	_check("九段序齐（r207 已锁 size；本套锁两新键在序）",
		DebugStats.DIAG_STAGE_ORDER.has(&"grid_rebuild")
			and DebugStats.DIAG_STAGE_ORDER.has(&"feel_shard"),
		"order=%s" % str(DebugStats.DIAG_STAGE_ORDER))


# ── ⑥ B 案源级锚 + 桌面零扰动 ──────────────────────────────────
func _test_6_b_source_anchors_and_desktop_zero() -> void:
	print("── ⑥ B 源级锚 + 桌面零扰动 ──")
	var gf := FileAccess.open("res://scripts/gamefeel/game_feel_director.gd", FileAccess.READ)
	var gf_src := gf.get_as_text() if gf != null else ""
	gf.close()
	_check("B1 源级锚：普命中粒子满载 return（CRIT 保留）",
		gf_src.contains("fullload_dim() and not p_result.is_crit"),
		"缺 B1 门")
	_check("B1 顿帧/震屏/色差不受门影响（return 在 trauma/chromatic 之后）",
		gf_src.find("fullload_dim() and not p_result.is_crit") > gf_src.find("add_trauma_for_level(level)"),
		"门序错位")
	var fx := FileAccess.open("res://scripts/gamefeel/elemental_fx_layer.gd", FileAccess.READ)
	var fx_src := fx.get_as_text() if fx != null else ""
	fx.close()
	_check("B2 源级锚：DOT 跳伤表现满载关（门在预算消费点之前）",
		fx_src.contains("if Enemy.fullload_dim():")
			and fx_src.find("if Enemy.fullload_dim():") < fx_src.find("DOT_SPARK_BUDGET[_fx_quality()]"),
		"缺 B2 门或位置不在预算读之前")
	# 桌面零扰动：门关时 _state_fx_q 逐档 == _fx_q
	Enemy.fullload_override = -1
	for q in [0, 1, 2]:
		Meta.set_setting(&"fx_quality", q)
		_check("桌面零扰动：fx_quality=%d 时 _state_fx_q()==_fx_q()" % q,
			Enemy._state_fx_q() == Enemy._fx_q(),
			"state_q=%d fx_q=%d" % [Enemy._state_fx_q(), Enemy._fx_q()])
	Meta.set_setting(&"fx_quality", 2)
	_check("音效门不换口（SfxBank 四处仍 _fx_q——满载不静音）",
		Enemy._fx_q() == 2, "fx_q=%d" % Enemy._fx_q())
