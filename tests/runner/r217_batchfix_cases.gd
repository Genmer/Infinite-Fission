# tests/runner/r217_batchfix_cases.gd
# R217 用例体：vc24 定案驱动三刀（二h #1/#4）。
# ① 刀A 染色确定性+档量化：self_modulate 唯一写点 _apply_body_tint——同状态组合敌
#   同帧同色（点燃呼吸 2 档/感电方波 2 值/吟唱 2 档/狂暴两档绝对值/冻结寒滞固定）。
# ② 刀A 闪白量化（满载分支 2 档固定倍率）+ 入场渐显 4 档。
# ③ 刀C player.tick 拆键：移/火两键分立（Player.probe_* 静态累加器）。
# ④ 刀B 遥测：断N（is_batch_broken 敌计数）/跳N（跳字在场）。
# ⑤ 修轮源级锚（评审#5）：self_modulate/modulate 写点白名单 + 余烬满载门 + 余值去子集。
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
	_test_1_deterministic_tint()
	_test_2_flash_and_fade_quantize()
	_test_3_player_split_probe()
	_test_4_telemetry()
	_test_5_source_anchors()
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
	_gl.name = "R217GameLoopUnderTest"
	tree.get_root().add_child(_gl)
	_gl.state = GameConst.GameStatus.MENU
	_gl.current_map_id = MapTable.FIRST_MAP_ID
	_gl.start_run()
	_gl.state = GameConst.GameStatus.MENU
	_gl.player.global_position = Vector2(360.0, 900.0)


func _teardown_game_loop() -> void:
	tree.paused = false
	Enemy.fullload_override = -1
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


func _spawn_enemy(p_id: StringName) -> Enemy:
	var pool := _gl.pools[&"enemy"] as EnemyPool
	var e := pool.acquire() as Enemy
	e.spawn(_fixture_enemy(p_id, 100.0), 1, 0)
	e._fade_left = 0.0                      # 跳过入场渐显（本组只测染色）
	e.modulate.a = 1.0
	return e


func _release_enemy(p_e: Enemy) -> void:
	(_gl.pools[&"enemy"] as EnemyPool).release(p_e)


# ── ① 染色确定性+档量化 ──────────────────────────────────────────
func _test_1_deterministic_tint() -> void:
	print("── ① 染色确定性 ──")
	# 基线：无状态无狂暴 → 纯白（is_batch_broken false = 同批前提）
	var a := _spawn_enemy(&"E_R217_A")
	var b := _spawn_enemy(&"E_R217_B")
	a.call(&"_apply_body_tint", DT)
	b.call(&"_apply_body_tint", DT)
	_check("①基线：无状态敌纯白（不断批）",
		a._sprite.self_modulate.is_equal_approx(Color.WHITE)
			and not a.is_batch_broken(),
		"tint=%s" % str(a._sprite.self_modulate))
	# 点燃：同相位两敌同色；两相位档（sin≥0/ sin<0）色值二选一
	a.elemental = ElementalState.new()
	b.elemental = ElementalState.new()
	a.elemental.burn_timer = 2.0
	b.elemental.burn_timer = 2.0
	a._anim_t = 0.3
	b._anim_t = 0.3
	a.call(&"_apply_body_tint", DT)
	b.call(&"_apply_body_tint", DT)
	_check("①点燃：同相位两敌同色（sin 量化同档）",
		a._sprite.self_modulate.is_equal_approx(b._sprite.self_modulate),
		"%s vs %s" % [str(a._sprite.self_modulate), str(b._sprite.self_modulate)])
	b._anim_t = 0.3 + PI / 6.2            # 反相位（sin 符号翻转）
	b.call(&"_apply_body_tint", DT)
	var c1: Color = a._sprite.self_modulate
	var c2: Color = b._sprite.self_modulate
	_check("①点燃：反相位两档二选一（色不等=呼吸读感保持）且互异", not c1.is_equal_approx(c2), "")
	# 冻结：固定系数 → 任意相位两敌同色
	a.elemental.burn_timer = 0.0
	b.elemental.burn_timer = 0.0
	a.elemental.freeze_timer = 2.0
	b.elemental.freeze_timer = 2.0
	a._anim_t = 0.7
	b._anim_t = 13.7                      # 相位任意
	a.call(&"_apply_body_tint", DT)
	b.call(&"_apply_body_tint", DT)
	_check("①冻结：任意相位两敌同色（固定系数不随相位）",
		a._sprite.self_modulate.is_equal_approx(b._sprite.self_modulate),
		"%s vs %s" % [str(a._sprite.self_modulate), str(b._sprite.self_modulate)])
	# 狂暴：常驻档两敌同色（原逐帧 lerp 收敛链逐敌不同=常驻断批根因）
	a.elemental.freeze_timer = 0.0
	b.elemental.freeze_timer = 0.0
	a.set("_enrage_done", true)
	b.set("_enrage_done", true)
	a.set("_red_tint_left", 0.0)          # 常驻微红档
	b.set("_red_tint_left", 0.0)
	a._anim_t = 2.0
	b._anim_t = 31.0
	a.call(&"_apply_body_tint", DT)
	b.call(&"_apply_body_tint", DT)
	_check("①狂暴常驻：两敌同色（0.18 档绝对值——原收敛链逐敌不同已根除）",
		a._sprite.self_modulate.is_equal_approx(b._sprite.self_modulate),
		"%s vs %s" % [str(a._sprite.self_modulate), str(b._sprite.self_modulate)])
	_check("①狂暴常驻：非白（「一眼狂暴」读感保持）且断批可观测",
		not a._sprite.self_modulate.is_equal_approx(Color.WHITE) and a.is_batch_broken(), "")
	# 入场强红档 vs 常驻档两档互异
	a.set("_red_tint_left", 1.5)
	a.call(&"_apply_body_tint", DT)
	_check("①狂暴入场强红 0.45 档 ≠ 常驻 0.18 档",
		not a._sprite.self_modulate.is_equal_approx(b._sprite.self_modulate), "")
	# 吟唱：两档量化（进度 <0.5 / ≥0.5）
	a.set("_enrage_done", false)
	b.set("_enrage_done", false)
	a.set("_cast_glow", 0.2)
	b.set("_cast_glow", 0.9)
	a.call(&"_apply_body_tint", DT)
	b.call(&"_apply_body_tint", DT)
	_check("①吟唱两档：低进度/高进度互异（量化 2 档非连续）",
		not a._sprite.self_modulate.is_equal_approx(b._sprite.self_modulate), "")
	# 同档吟唱两敌同色
	a.set("_cast_glow", 0.9)
	a.call(&"_apply_body_tint", DT)
	_check("①吟唱同档：两敌同色",
		a._sprite.self_modulate.is_equal_approx(b._sprite.self_modulate), "")
	# 池归还复位
	a.set("_cast_glow", 0.0)
	_release_enemy(a)
	_release_enemy(b)
	_check("①归还：_reset_state 后 self_modulate 回纯白",
		a._sprite.self_modulate.is_equal_approx(Color.WHITE),
		"tint=%s" % str(a._sprite.self_modulate))


# ── ② 闪白量化 + 入场渐显量化 ────────────────────────────────────
func _test_2_flash_and_fade_quantize() -> void:
	print("── ② 闪白/渐显量化 ──")
	Enemy.fullload_override = 1                  # 满载分支（R237 后闪白走白变体贴图换桶）
	var e1 := _spawn_enemy(&"E_R217_F1")
	var e2 := _spawn_enemy(&"E_R217_F2")
	e1.call(&"_apply_flash", 1.0)
	e2.call(&"_apply_flash", 0.8)
	_check("②强闪同档：两敌同强白变体贴图 且 modulate 同白（同批——R237 闪白批化契约迁移）",
		e1._sprite.texture == e2._sprite.texture
			and e1._sprite.texture == TextureFactory.enemy_tex_flash(&"grunt", false, true)
			and e1._sprite.modulate.is_equal_approx(e2._sprite.modulate),
		"same=%s mod=%s" % [str(e1._sprite.texture == e2._sprite.texture),
			str(e1._sprite.modulate)])
	e2.call(&"_apply_flash", 0.3)
	_check("②弱闪另档：弱白变体 ≠ 强变体（两档互异，CRIT/普击强度差并入两档——R237 契约迁移）",
		e2._sprite.texture == TextureFactory.enemy_tex_flash(&"grunt", false, false)
			and e1._sprite.texture != e2._sprite.texture,
		"t2_ok=%s" % str(e2._sprite.texture == TextureFactory.enemy_tex_flash(&"grunt", false, false)))
	e2.call(&"_apply_flash", 0.0)
	_check("②归零复位：modulate 回纯白 + texture 回本体（R237 契约迁移）",
		e2._sprite.modulate.is_equal_approx(Color.WHITE)
			and e2._sprite.texture == TextureFactory.enemy_tex(&"grunt"),
		"mod=%s" % str(e2._sprite.modulate))
	Enemy.fullload_override = -1
	# 入场渐显 4 档
	var f := _spawn_enemy(&"E_R217_F3")
	f._fade_left = 0.0                        # _spawn_enemy 已跳过；直接驱动各档
	var tiers := [0.0, 0.09, 0.06, 0.03]      # fade_left 残量 → 期望档 1/2/3 档位
	var seen: Array[float] = []
	var ok := true
	var got := ""
	for fl in tiers:
		f._fade_left = fl
		f.tick(DT)
		var a: float = f.modulate.a
		var tier := roundf(a * 3.0) / 3.0
		if absf(a - tier) > EPS:
			ok = false
			got = "fl=%s a=%.4f" % [str(fl), a]
		if not seen.has(a):
			seen.append(a)
	_check("②渐显 4 档：alpha 恒落 {0,1/3,2/3,1} 网格（连续值逐敌断批已除）",
		ok and seen.size() >= 3, "seen=%d %s" % [seen.size(), got])
	_release_enemy(e1)
	_release_enemy(e2)
	_release_enemy(f)


# ── ③ player.tick 拆键（移/火） ───────────────────────────────────
func _test_3_player_split_probe() -> void:
	print("── ③ player 拆键 ──")
	_gl.stage_probe_enabled = true
	_gl.state = GameConst.GameStatus.PLAYING
	_gl._physics_process(DT)
	var probe: Dictionary = _gl.stage_probe_us
	_check("③帧探针：player_mv/player_wp 两键分立（玩段下钻）",
		probe.has(&"player_mv") and probe.has(&"player_wp"),
		"probe=%s" % str(probe.keys()))
	Player.reset_stage_probe()
	_check("③清零：reset_stage_probe 后静态累加器归零",
		Player.probe_pre_us == 0 and Player.probe_weapons_us == 0, "")
	_check("③段序：移/火标签在位（R220 刀1 后十六段）",
		str(DebugStats.DIAG_STAGE_TAGS.get(&"player_mv", "")) == "移"
			and str(DebugStats.DIAG_STAGE_TAGS.get(&"player_wp", "")) == "火"
			and DebugStats.DIAG_STAGE_ORDER.size() == 16,
		"tags=%s size=%d" % [str(DebugStats.DIAG_STAGE_TAGS), DebugStats.DIAG_STAGE_ORDER.size()])


# ── ④ 遥测（断N/跳N） ────────────────────────────────────────────
func _test_4_telemetry() -> void:
	print("── ④ 遥测 ──")
	var counts: Dictionary = _gl.diag_counts()
	_check("④diag_counts 新键（断批敌数/跳字在场）",
		counts.has(&"tinted_enemies") and counts.has(&"popups"),
		str(counts.keys()))
	Enemy.fullload_override = 1
	var base: int = int((_gl.diag_counts())[&"tinted_enemies"])   # 开局风暴敌在渐显窗内
	# （根 α<1——R217 修轮#3 起正确计入断N），回落断言改对称基线（非恒 0）
	var e := _spawn_enemy(&"E_R217_T1")
	e.call(&"_apply_flash", 1.0)                # 闪白窗内 → 贴图桶化（modulate 恒白不再断批）
	_gl.spawner.active.append(e)                # 直连池敌手动挂活跃表（diag_counts 遍历源）
	var counts2: Dictionary = _gl.diag_counts()
	_check("④断N：闪白敌在场 → tinted_enemies==基线（R237 闪白批化契约迁移：满载闪白贴图换桶，modulate 恒白——闪白期敌不再断批正是本刀目的）",
		int(counts2[&"tinted_enemies"]) == base,
		"base=%d tinted=%d" % [base, int(counts2[&"tinted_enemies"])])
	e.call(&"_apply_flash", 0.0)
	Enemy.fullload_override = -1
	_gl.spawner.active.erase(e)
	_release_enemy(e)
	var counts3: Dictionary = _gl.diag_counts()
	_check("④断N 回落：闪白归零归还后回基线（风暴渐显敌恒在账——1Hz 采样健康度口）",
		int(counts3[&"tinted_enemies"]) == base,
		"base=%d tinted=%d" % [base, int(counts3[&"tinted_enemies"])])


# ── ⑤ 修轮源级锚（评审#5——r213 B1 先例：grep 源码断言唯一写点不变量） ──
func _test_5_source_anchors() -> void:
	print("── ⑤ 修轮源级锚 ──")
	var f := FileAccess.open("res://scripts/entities/enemy/enemy.gd", FileAccess.READ)
	var src := f.get_as_text() if f != null else ""
	f.close()
	# self_modulate 写点白名单：仅 _apply_body_tint（每帧确定性重算）与 _reset_status_fx
	# （池归还复位 WHITE）——未来在 tick 尾再引入 lerp(当前值,…) 收敛链（本次根因形态）
	# 会立刻踩锚，不依赖任何用例恰好覆盖该路径
	var bad_tint := 0
	var idx := src.find("_sprite.self_modulate =")
	while idx >= 0:
		var line_start := src.rfind("\n", idx) + 1
		var line := src.substr(line_start, src.find("\n", idx) - line_start)
		if not (line.strip_edges().begins_with("_sprite.self_modulate = Color.WHITE")
				or line.strip_edges().begins_with("_sprite.self_modulate = tint")):
			bad_tint += 1
		idx = src.find("_sprite.self_modulate =", idx + 1)
	_check("⑤源级锚：enemy.gd self_modulate 写点仅 白复位/染色重算 两形态（当前各 1 处）",
		bad_tint == 0 and src.count("_sprite.self_modulate = Color.WHITE") == 1
			and src.count("_sprite.self_modulate = tint") == 1,
		"bad=%d white=%d tint=%d" % [bad_tint,
			src.count("_sprite.self_modulate = Color.WHITE"),
			src.count("_sprite.self_modulate = tint")])
	# modulate 写点白名单：仅 _apply_flash 满载两档/复位（全部 Color.WHITE 赋值形态）
	var bad_mod := 0
	idx = src.find("_sprite.modulate =")
	while idx >= 0:
		var line_start := src.rfind("\n", idx) + 1
		var line := src.substr(line_start, src.find("\n", idx) - line_start)
		if not line.strip_edges().begins_with("_sprite.modulate = Color.WHITE"):
			bad_mod += 1
		idx = src.find("_sprite.modulate =", idx + 1)
	_check("⑤源级锚：_sprite.modulate 写点全为 WHITE 赋值（量化 2.4×/1.5× 经乘法仍同值）",
		bad_mod == 0,
		"bad=%d" % bad_mod)
	# 余烬满载门（评审#1）：异贴图挂件满载必须隐藏
	_check("⑤源级锚：余烬满载随 A案挂件同隐（visible 门含 fullload_dim）",
		src.contains("_burn_ember.visible = p_burning and not fullload_dim()"),
		"缺余烬满载门")
	# 余值去子集（评审#2）：debug_stats 求和必须跳过 移/火 两键
	var ds := FileAccess.open("res://autoload/debug_stats.gd", FileAccess.READ)
	var ds_src := ds.get_as_text() if ds != null else ""
	ds.close()
	_check("⑤源级锚：余值求和跳过 移/火/跳 三子集键（不双计）",
		ds_src.contains("if key != &\"player_mv\" and key != &\"player_wp\" and key != &\"popup\":"),
		"缺子集跳过门")
