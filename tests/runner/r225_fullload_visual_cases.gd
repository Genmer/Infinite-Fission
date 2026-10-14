# tests/runner/r225_fullload_visual_cases.gd
# R225 用例体：满载敌视觉再降（候选 a+b——纯装饰子件满载隐藏，可否决披露）。
# 契约（锁机制而非实现细节）：
#   ① 精英装饰三件套（皇冠/底影/微光粒）满载门开=隐 / 门关=按分型 want 复显
#   ② Boss 装饰（卫星球/底影）同门；复显走 _ensure_* 单源（boss1 第三球保持隐藏）
#   ③ 满载期出生：装饰即刻隐（无首帧闪现）
#   ④ 池复用安全：门开归还 → 门关重生，装饰随 want 复显（门标志重推导）
#   ⑤ is_batch_broken 口径不回归：装饰隐藏不触碰 _sprite 两通道与根 α；闪白口径如旧
#   ⑥ fullload_flips 不因新隐件震荡（覆写口往返 + 滞回锁存零扰动）
#   ⑦ 红线锁：甲板（E3 外甲板，半身剪影非纯装饰）与本体/反馈通道不入本批（满载仍显）
extends RefCounted

const MAIN_SCENE := "res://scenes/main.tscn"
const DT := 1.0 / 60.0
const WHITE_KEY := "1.000,1.000,1.000|1.000,1.000,1.000"

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
	_test_1_elite_decor_gate()
	_test_2_boss_decor_gate()
	_test_3_spawn_under_fullload()
	_test_4_pool_reuse_rederive()
	_test_5_batch_broken_contract()
	_test_6_flips_stability()
	_test_7_redline_armor_not_cut()
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
	_gl.name = "R225GameLoopUnderTest"
	tree.get_root().add_child(_gl)
	_gl.state = GameConst.GameStatus.MENU
	_gl.current_map_id = MapTable.FIRST_MAP_ID
	_gl.start_run()
	_gl.state = GameConst.GameStatus.MENU          # 冻结波次（静止环境，r212/r213 同构）
	_gl.player.global_position = Vector2(360.0, 900.0)
	Enemy.fullload_override = -1                   # 基线：门关（headless 真值恒关）
	Enemy._fullload_latched = false


func _teardown_game_loop() -> void:
	Enemy.fullload_override = -1                   # 覆写口复位（防跨套件泄漏）
	Enemy._fullload_latched = false
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


func _spawn(p_id: StringName, p_tags: int) -> Enemy:
	var pool := _gl.pools[&"enemy"] as EnemyPool
	var e := pool.acquire() as Enemy
	e.spawn(_fixture_enemy(p_id, 100000.0), 1, p_tags)
	e._fade_left = 0.0                             # 跳过入场渐显（断批口径不受根 α 干扰）
	e.modulate.a = 1.0
	return e


func _release(p_e: Enemy) -> void:
	(_gl.pools[&"enemy"] as EnemyPool).release(p_e)


func _all_hidden(p_e: Enemy) -> bool:
	var crown: Sprite2D = p_e.get("_crown")
	var shadow: Sprite2D = p_e.get("_shadow")
	if crown != null and crown.visible:
		return false
	if shadow != null and shadow.visible:
		return false
	for sp in (p_e.get("_sparkles") as Array):
		if (sp as Sprite2D).visible:
			return false
	for orb in (p_e.get("_satellites") as Array):
		if (orb as Sprite2D).visible:
			return false
	return true


# ── ① 精英装饰三件套门开关契约 ──────────────────────────────────
func _test_1_elite_decor_gate() -> void:
	print("── ① 精英装饰门开关 ──")
	var e := _spawn(&"E_R225_EL", GameConst.TAG_ELITE)
	var crown: Sprite2D = e.get("_crown")
	var shadow: Sprite2D = e.get("_shadow")
	var sparkles: Array = e.get("_sparkles")
	_check("①门关基线：皇冠建件且可见（want 语义零扰动）",
		crown != null and crown.visible, "crown=%s" % str(crown != null and crown.visible))
	_check("①门关基线：底影可见（精英悬浮件）", shadow != null and shadow.visible,
		"shadow=%s" % str(shadow != null and shadow.visible))
	_check("①门关基线：微光粒 2 颗全可见", sparkles.size() == 2
		and (sparkles[0] as Sprite2D).visible and (sparkles[1] as Sprite2D).visible,
		"n=%d" % sparkles.size())
	Enemy.fullload_override = 1
	e.tick(DT)                                     # 门翻转随 tick 落位
	_check("①门开：皇冠/底影/微光粒全隐（R225 满载纯装饰门）", _all_hidden(e), "")
	_check("①门开：本体 Sprite 不动（visible 保持——只隐装饰不隐敌）",
		(e.get("_sprite") as Sprite2D).visible, "")
	Enemy.fullload_override = 0
	e.tick(DT)
	_check("①门关：皇冠复显（want 单源复显）", crown != null and crown.visible, "")
	_check("①门关：底影/微光粒复显", shadow != null and shadow.visible
		and (sparkles[0] as Sprite2D).visible, "")
	_release(e)


# ── ② Boss 装饰（卫星球/底影）同门 + 复显单源 ────────────────────
func _test_2_boss_decor_gate() -> void:
	print("── ② Boss 装饰门 ──")
	var e := _spawn(&"E6_boss1_R225", GameConst.TAG_BOSS)
	var sats: Array = e.get("_satellites")
	var shadow: Sprite2D = e.get("_shadow")
	var vis0: int = 0
	for orb in sats:
		if (orb as Sprite2D).visible:
			vis0 += 1
	_check("②门关基线：卫星球 boss1=2 颗可见 + 底影可见（分型 want 原样）",
		vis0 == 2 and shadow != null and shadow.visible, "vis=%d" % vis0)
	Enemy.fullload_override = 1
	e.tick(DT)
	_check("②门开：卫星球与底影全隐（3 节点含 boss1 超编第 3 球）", _all_hidden(e), "")
	Enemy.fullload_override = 0
	e.tick(DT)
	var vis1: int = 0
	for orb in sats:
		if (orb as Sprite2D).visible:
			vis1 += 1
	_check("②门关：卫星球复显恰 2 颗（_ensure_satellites 单源——第 3 球保持隐藏非全显）",
		vis1 == 2, "vis=%d" % vis1)
	_check("②门关：底影复显", shadow != null and shadow.visible, "")
	_release(e)


# ── ③ 满载期出生：装饰即刻隐（无首帧闪现） ───────────────────────
func _test_3_spawn_under_fullload() -> void:
	print("── ③ 满载出生即隐 ──")
	Enemy.fullload_override = 1
	var e := _spawn(&"E_R225_B1", GameConst.TAG_ELITE)   # spawn→_sync_visual 尾即施加门
	_check("③满载出生：spawn 返回即隐（tick 前无首帧闪现窗口）", _all_hidden(e), "")
	e.tick(DT)
	_check("③满载出生：tick 后保持隐（门态幂等）", _all_hidden(e), "")
	_release(e)
	Enemy.fullload_override = -1


# ── ④ 池复用安全：门标志重推导 ──────────────────────────────────
func _test_4_pool_reuse_rederive() -> void:
	print("── ④ 池复用重推导 ──")
	Enemy.fullload_override = 1
	var e := _spawn(&"E_R225_P1", GameConst.TAG_ELITE)
	e.tick(DT)
	_check("④门开：装饰隐（前置）", _all_hidden(e), "")
	_release(e)                                    # _reset_state 清门标志 + 装饰强制隐
	Enemy.fullload_override = 0                    # 门回落后再取同一池实例
	var e2 := (_gl.pools[&"enemy"] as EnemyPool).acquire() as Enemy
	_check("④取回同一池实例（复用前提成立）", e2 == e, "same=%s" % str(e2 == e))
	e2.spawn(_fixture_enemy(&"E_R225_P2", 100000.0), 1, GameConst.TAG_ELITE)
	e2._fade_left = 0.0
	e2.modulate.a = 1.0
	var crown: Sprite2D = e2.get("_crown")
	_check("④门关重生：装饰随 want 复显（门标志经池归还清零重推导——不复用旧隐藏态）",
		crown != null and crown.visible and not _all_hidden(e2), "")
	_release(e2)


# ── ⑤ is_batch_broken 口径不回归 ────────────────────────────────
func _test_5_batch_broken_contract() -> void:
	print("── ⑤ 断批口径不回归 ──")
	Enemy.fullload_override = 1
	var e := _spawn(&"E_R225_BB", GameConst.TAG_ELITE)
	e.tick(DT)
	var sprite: Sprite2D = e.get("_sprite")
	_check("⑤门开装饰隐：无状态敌 is_batch_broken 仍 false（装饰隐藏不入断批账）",
		_all_hidden(e) and not e.is_batch_broken(), "")
	_check("⑤门开装饰隐：sprite_modulate_key 仍纯白键（分组N 口径不被装饰扰动）",
		e.sprite_modulate_key() == WHITE_KEY, "key=%s" % e.sprite_modulate_key())
	e.call(&"_apply_flash", 1.0)
	_check("⑤闪白口径（R237 闪白批化契约迁移）：满载强白变体贴图 + modulate 恒白 + is_batch_broken false（闪白期敌不再断批——原 r217 白乘契约已迁移）",
		sprite.texture == TextureFactory.enemy_tex_flash(e._kind, false, true)
			and sprite.modulate == Color.WHITE and not e.is_batch_broken(),
		"tex=%s mod=%s" % [str(sprite.texture), str(sprite.modulate)])
	e.call(&"_apply_flash", 0.0)
	_check("⑤闪白归零：贴图回本体 + 口径回 false（两通道互复位如旧——R237 迁移）",
		sprite.texture == TextureFactory.enemy_tex(e._kind, false)
			and not e.is_batch_broken(), "tex=%s" % str(sprite.texture))
	_release(e)
	Enemy.fullload_override = -1


# ── ⑥ fullload_flips 不因新隐件震荡 ─────────────────────────────
func _test_6_flips_stability() -> void:
	print("── ⑥ fullload_flips 稳定 ──")
	var base: int = DebugStats.get_counter(&"fullload_flips")
	var e := _spawn(&"E_R225_FL", GameConst.TAG_ELITE)
	var flips: int = base
	for round_i in range(4):
		Enemy.fullload_override = 1 - (round_i % 2)   # 覆写口往返 1/0/1/0
		e.tick(DT)                                    # 新隐件门随翻转落位
		if DebugStats.get_counter(&"fullload_flips") != flips:
			break
	_check("⑥覆写口往返×4：fullload_flips 计数不增（新隐件门不触滞回锁存）",
		DebugStats.get_counter(&"fullload_flips") == base,
		"base=%d now=%d" % [base, DebugStats.get_counter(&"fullload_flips")])
	_check("⑥滞回锁存态保持 false（headless 覆写口不读不写锁存）",
		Enemy._fullload_latched == false,
		"latched=%s" % str(Enemy._fullload_latched))
	_release(e)


# ── ⑦ 红线锁：甲板与本体不入本批 ────────────────────────────────
func _test_7_redline_armor_not_cut() -> void:
	print("── ⑦ 红线锁 ──")
	Enemy.fullload_override = 1
	var e := _spawn(&"E3_R225_AR", 0)              # E3 前缀 → bastion（外甲板分型）
	e.tick(DT)
	var armor: Sprite2D = e.get("_armor_sprite")
	var sprite: Sprite2D = e.get("_sprite")
	_check("⑦满载：甲板仍可见（半身剪影非纯装饰——本批不砍，用户可否决再议）",
		armor != null and armor.visible, "armor=%s" % str(armor != null and armor.visible))
	_check("⑦满载：本体仍可见（敌不消失）", sprite != null and sprite.visible, "")
	# 源级锚：门函数在位且挂 _sync_visual/_tick_visual 两覆盖点；余烬门未被迁移
	var f := FileAccess.open("res://scripts/entities/enemy/enemy.gd", FileAccess.READ)
	var src := f.get_as_text() if f != null else ""
	f.close()
	_check("⑦源级锚：_apply_fullload_decor 双覆盖点（spawn 即刻隐 + tick 翻转落位）",
		src.count("_apply_fullload_decor()") >= 3
			and src.find("_apply_fullload_decor()", src.find("func _sync_visual")) > 0,
		"count=%d" % src.count("_apply_fullload_decor()"))
	_check("⑦源级锚：余烬满载门保持原样（R217 契约未被本批改写）",
		src.contains("_burn_ember.visible = p_burning and not fullload_dim()"), "")
	_release(e)
	Enemy.fullload_override = -1
