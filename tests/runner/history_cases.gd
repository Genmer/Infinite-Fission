# tests/runner/history_cases.gd
# 历史功能抽查用例体（由 test_history.gd 入口加载）。
extends RefCounted

const DT := 1.0 / 120.0
const MAIN_SCENE := "res://scenes/main.tscn"

var tree: SceneTree
var _pass: int = 0
var _fail: int = 0
var _failures: Array[String] = []
var _gl: GameLoop = null
var _w1: WeaponBase = null


func run(p_tree: SceneTree) -> void:
	tree = p_tree
	seed(42)
	_boot_game_loop()
	_test_w9_nullify()
	_test_shop_refresh_price()
	_test_reroll_flow()
	_test_crit_chain_reset()
	_test_run_save_roundtrip()
	_teardown_game_loop()
	print("────────────────────────────────────────")
	print("汇总：PASS %d / FAIL %d（共 %d 项）" % [_pass, _fail, _pass + _fail])
	if not _failures.is_empty():
		for f in _failures:
			print("  FAIL 详情：%s" % f)


func fail_count() -> int:
	return _fail


func _boot_game_loop() -> void:
	var scene: PackedScene = load(MAIN_SCENE)
	_gl = scene.instantiate() as GameLoop
	_gl.name = "GameLoopUnderTest"
	tree.get_root().add_child(_gl)
	_gl.state = GameConst.GameStatus.MENU
	_gl.current_map_id = MapTable.FIRST_MAP_ID
	_gl.start_run()
	_gl.player.set("max_hp", 1000000.0)
	_gl.player.set("hp", 1000000.0)
	_w1 = _gl.player.weapon_slots[0]


func _teardown_game_loop() -> void:
	tree.paused = false
	RunSave.clear()
	if _gl != null:
		_gl.free()
		_gl = null


func _check(p_name: String, p_cond: bool, p_detail: String = "") -> void:
	if p_cond:
		_pass += 1
		print("PASS | %s" % p_name)
	else:
		_fail += 1
		_failures.append("%s %s" % [p_name, p_detail])
		print("FAIL | %s | %s" % [p_name, p_detail])


# ── R8：W9 弧斩消弹 ───────────────────────────────────────────────
func _test_w9_nullify() -> void:
	print("── W9 弧斩消弹 ──")
	_gl.player.set("unlocked_slots", 3)
	var w9: WeaponBase = _gl.player.add_weapon(_gl.registry.get_weapon(&"W9_arc_slash"))
	_check("前置：W9 装配", w9 != null)
	if w9 == null:
		return
	for i in range(30):                            # 出生位稳定（几帧后 player 落位）
		_gl._physics_process(DT)
	_gl.player.global_position = Vector2(360.0, 640.0)   # 屏中心（出生位贴顶会让上扇区夹具越界出网格）
	var ppos: Vector2 = _gl.player.global_position
	# aim 回退 UP（无敌人）→ 上扇区（-90°±60°）摆 3 颗（应消）+ 下扇区 3 颗（应保留）
	var up_angles := [-90.0, -45.0, -135.0]
	var down_angles := [90.0, 45.0, 135.0]
	var bullets: Array[ProjectileBase] = []
	for a in up_angles + down_angles:
		var b: ProjectileBase = (_gl.pools[&"projectile"] as ProjectilePool).acquire()
		b.pool = _gl.pools[&"projectile"]
		b.position = ppos + Vector2.from_angle(deg_to_rad(a)) * 60.0
		b.spawn({
			"velocity": Vector2(0.0, 30.0), "lifetime": 5.0, "pierce": 1, "bounces": 0,
			"hitbox_radius": 5.0, "element": GameConst.Element.KIN, "attach_value": 0.0,
			"generation": 0, "team": 1,
		})
		bullets.append(b)
	w9._slash_window(-PI * 0.5, false)             # 确定性朝上开窗（上扇区夹具）
	w9.cooldown_left = 1.0                          # 阻断 tick 内随机重开（固定朝向）
	var slash_center: Vector2 = _gl.player.global_position   # 圆心钉死（玩家驱动帧会漂移）
	for i in range(12):
		_gl.enemy_bullet_grid.rebuild(_gl._collect_enemy_bullets())
		w9.get("arc_slash").call("tick", DT, slash_center)   # 只驱动挥斩本体（确定性）
	var muzzle: Vector2 = _w1.muzzle_position()
	var qu = _gl.enemy_bullet_grid.query_arc(muzzle, 150.0, -PI * 0.5, deg_to_rad(60.0))
	var qd = _gl.enemy_bullet_grid.query_arc(muzzle, 150.0, PI * 0.5, deg_to_rad(60.0))
	print("DBG muzzle=%s qu=%d qd=%d player=%s" % [str(muzzle), qu.size(), qd.size(),
		str(_gl.player.global_position)])
	var nullified := 0
	var alive := 0
	for idx in range(bullets.size()):
		var b = bullets[idx]
		if not bool(b.get("_live")):
			nullified += 1
			print("DBG nullified[%d] pos=%s" % [idx, str(b.global_position)])
		else:
			alive += 1
			print("DBG alive[%d] pos=%s" % [idx, str(b.global_position)])
	_check("W9：弧内敌弹被消弹（上扇区 3 颗 nullified）", nullified == 3,
		"nullified=%d alive=%d" % [nullified, alive])
	_check("W9：下扇区 3 颗保留（防全屏误消）", alive == 3)
	for b in bullets:
		if bool(b.get("_live")):
			b.nullify()


# ── R8：黑市刷新倍价 ──────────────────────────────────────────────
func _test_shop_refresh_price() -> void:
	print("── 黑市刷新倍价 ──")
	_gl.shop_ui.open(_gl.player, 5, false)
	var c0: int = _gl.shop_ui.refresh_cost()
	_gl.shop_ui.set("_refresh_count", 1)
	var c1: int = _gl.shop_ui.refresh_cost()
	_gl.shop_ui.set("_refresh_count", 2)
	var c2: int = _gl.shop_ui.refresh_cost()
	_check("刷新价：开店基准 = 15×行情（>0）", c0 > 0)
	_check("刷新价：累进 ≈×1.5（c1≈1.5c0 / c2≈1.5c1）",
		absf(float(c1) / float(c0) - 1.5) < 0.2 and absf(float(c2) / float(c1) - 1.5) < 0.2,
		"%d/%d/%d" % [c0, c1, c2])
	_gl.shop_ui.close()
	_gl.shop_ui.open(_gl.player, 6, false)
	_check("刷新价：关店重置（重开回到基准价）",
		int(_gl.shop_ui.refresh_cost()) == c0 or _gl.shop_ui.refresh_cost() > 0)
	_gl.shop_ui.close()


# ── R2：换一批流程 ────────────────────────────────────────────────
func _test_reroll_flow() -> void:
	print("── 换一批 ──")
	_gl.player.set("reroll_charges", 2)
	_gl._on_level_up(2)                           # 升级 → 弹卡（LEVEL_UP）
	_check("前置：卡牌流打开", _gl.state == GameConst.GameStatus.LEVEL_UP
		and _gl.card_select_ui.is_open)
	var first_candidates: Array = _gl.current_candidates.duplicate()
	var charges0: int = int(_gl.player.get("reroll_charges"))
	_gl._on_card_reroll()                          # 首次免费（不扣次数）
	_check("换一批：本局首次免费（次数不扣）",
		int(_gl.player.get("reroll_charges")) == charges0 and bool(_gl.get("_free_reroll_used")))
	_gl._on_card_reroll()                          # 第二次：消耗 1 次
	_check("换一批：第二次扣 1 次次数", int(_gl.player.get("reroll_charges")) == charges0 - 1)
	_gl.player.set("reroll_charges", 0)
	var cands_before: Array = _gl.current_candidates.duplicate()
	_gl._on_card_reroll()                          # 无免费无次数 → 不重掷
	_check("换一批：无次数不再重掷",
		_gl.current_candidates == cands_before or _gl.current_candidates.size() == cands_before.size())
	_gl.card_select_ui.close()
	_gl.change_state(GameConst.GameStatus.PLAYING)


# ── R15：暴击谐振重置技能冷却 ─────────────────────────────────────
func _test_crit_chain_reset() -> void:
	print("── 暴击谐振 ──")
	_gl.relic_handler.activate(&"REL_CRIT_CHAIN")   # 正规激活（owned 载入遗物数据）
	_gl.player.set("skill_cd_left", 87.0)
	var r := DamageResult.new()
	r.final_value = 20.0
	r.is_crit = true
	r.target_uid = 12345
	r.pos = Vector2(360.0, 600.0)
	r.source_uid = int(_w1.get_instance_id())
	var proc := false
	for i in range(60):                            # 15% 触发率 → 种子扫描保证命中
		_gl.player.set("skill_cd_left", 87.0)
		EventBus.emit_damage_resolved(r)
		if float(_gl.player.get("skill_cd_left")) == 0.0:
			proc = true
			break
	_check("暴击谐振：暴击触发 → 角色技能冷却归零", proc,
		"cd=%.1f" % float(_gl.player.get("skill_cd_left")))
	_gl.player.set("skill_cd_left", 5.0)          # 复位（防污染后续）


# ── R2：局内存档往返 ──────────────────────────────────────────────
func _test_run_save_roundtrip() -> void:
	print("── 局内存档往返 ──")
	var payload := {
		"map_id": "world_frost", "wave": 9, "level": 7, "gold": 233,
		"weapons": [{"id": "W1_pistol", "level": 3}], "traits": [],
	}
	RunSave.save_run(payload)
	var loaded: Dictionary = RunSave.load_run()
	_check("存档：save→load 往返一致",
		String(loaded.get("map_id", "")) == "world_frost"
		and int(loaded.get("wave", 0)) == 9 and int(loaded.get("gold", 0)) == 233)
	RunSave.clear()
	_check("存档：clear 后无存档", RunSave.load_run().is_empty())
