# tests/runner/r241_boomfix_cases.gd
# R241 回旋刃三修+自动施放用例体（入口运行时 load——cases 禁 test_ 前缀防电池 glob 误收）。
# 覆盖：
# ① 元素染色：FIR 附魔弹体=元素色刃贴图（≠金）；KIN=金原观感；缓存键带色同色同实例
# ② 分裂：回旋母弹子代=迷你回旋刃（boomerang 键+0.55×甩程+代数/元素继承）；
#    EXPIRE 期分裂（lifetime_left≤0）子代寿命地板 1.2s（静默白给修复）；直弹子代不带回旋键
# ③ 边界反弹/速度地板：出程速度≤60 即翻相（一 tick）；近墙+跳弹+999s 永存 8s 内
#    必解决（回收或回相且不滞空）；正常定距甩满翻转语义保持
# ④ 自动施放：键存在+PLAYING 可见/MENU 隐；开关键 Meta 真源+文案双态；
#    开态冷却完成自动施放；暂停门；关态不施放
# ⑤ 套件总项数断言（R231 假绿教训）
extends RefCounted

const MAIN_SCENE := "res://scenes/main.tscn"
const DT := 1.0 / 60.0
const EXPECTED_TOTAL := 18

var tree: SceneTree
var _pass: int = 0
var _fail: int = 0
var _failures: Array[String] = []
var _gl: GameLoop = null


func run(p_tree: SceneTree) -> void:
	tree = p_tree
	seed(20261007)
	_boot_game_loop()
	await tree.process_frame
	await tree.process_frame
	_case1_element_tint()
	_case2_split_children()
	_case3_edge_floor()
	_case4_auto_cast()
	await _cleanup()
	_check("⑤ 套件总项数（EXPECTED=%d——R231 假绿教训）" % EXPECTED_TOTAL,
		_pass + _fail + 1 == EXPECTED_TOTAL, "实得 %d" % (_pass + _fail + 1))
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
	_gl.name = "R241BoomFixGameLoopUnderTest"
	tree.get_root().add_child(_gl)
	_gl.state = GameConst.GameStatus.MENU
	_gl.current_map_id = MapTable.FIRST_MAP_ID
	_gl.start_run()
	_gl.state = GameConst.GameStatus.MENU
	_gl.player.global_position = Vector2(360.0, 900.0)


func _spawn_boom(p_element: int, p_vel: Vector2, p_pos: Vector2,
		p_bounces: int = 0, p_lifetime: float = 3.2, p_range: float = 380.0) -> ProjectileBase:
	# 直连池直发回旋弹（request_split 同款参数口径——绕过武器注入，元素/预算可控）
	var pool := _gl.pools[&"projectile"] as ProjectilePool
	var p := pool.acquire() as ProjectileBase
	p.pool = pool
	p.enemy_grid = _gl.pools[&"enemy"].get("grid") if _gl.pools[&"enemy"].get("grid") != null else null
	p.global_position = p_pos
	p.spawn({
		"position": p_pos,
		"velocity": p_vel,
		"lifetime": p_lifetime,
		"range": p_range,
		"pierce": 1,
		"bounces": p_bounces,
		"boomerang": true,
		"hitbox_radius": 7.0,
		"element": p_element,
		"attach_value": 0.0,
		"generation": 0,
		"panel_snapshot": {"base_atk": 100.0},
		"team": 0,
	})
	return p


func _release_proj(p: ProjectileBase) -> void:
	if p != null and is_instance_valid(p) and bool(p.get("_live")):
		(p.pool as ProjectilePool).release(p)


func _release_all_gen1() -> void:
	# 快照后释放（active_projectiles 迭代中 release 会跳项——数组快照防残留）
	var pool := _gl.pools[&"projectile"] as ProjectilePool
	var victims: Array = []
	for p in pool.active_projectiles():
		var pb := p as ProjectileBase
		if pb != null and int(pb.get("generation")) == 1:
			victims.append(pb)
	for v in victims:
		_release_proj(v)


# ═══ ① 元素染色 ═══════════════════════════════════════════════════════
func _case1_element_tint() -> void:
	print("── ① 回旋刃元素染色（R208 曳光同口径） ──")
	var fir := GameConst.Element.FIR
	var fir_tex: ImageTexture = TextureFactory.boomerang_tex(PopPalette.ELEMENT_COLORS[fir])
	var gold_tex: ImageTexture = TextureFactory.boomerang_tex()
	var pf := _spawn_boom(fir, Vector2(200.0, 0.0), Vector2(360.0, 360.0))
	var pk := _spawn_boom(GameConst.Element.KIN, Vector2(200.0, 0.0), Vector2(360.0, 300.0))
	var sf: Sprite2D = pf.get("_sprite")
	var sk: Sprite2D = pk.get("_sprite")
	_check("①a FIR 附魔弹体=元素色刃贴图", sf != null and sf.texture == fir_tex,
		"tex==%s" % str(sf.texture == fir_tex if sf != null else false))
	_check("①b KIN 弹体=金色原观感（缺省参不变）", sk != null and sk.texture == gold_tex,
		"tex==%s" % str(sk.texture == gold_tex if sk != null else false))
	_check("①c 元素色刃≠金刃（缓存键带色双实例）", fir_tex != gold_tex)
	_release_proj(pf)
	_release_proj(pk)

# ═══ ② 分裂子代 ═══════════════════════════════════════════════════════
func _case2_split_children() -> void:
	print("── ② 回旋分裂子代（迷你回旋刃+寿命地板） ──")
	var pool := _gl.pools[&"projectile"] as ProjectilePool
	var pm := _spawn_boom(GameConst.Element.FIR, Vector2(300.0, 0.0), Vector2(360.0, 360.0))
	pm.request_split(2, 28.0, 0.4)
	var kids: Array = []
	for p in pool.active_projectiles():
		var pb := p as ProjectileBase
		if pb != null and int(pb.get("generation")) == 1:
			kids.append(pb)
	_check("②a 回旋母弹 request_split(2) → 2 子代且子代=回旋形态（_boomerang）",
		kids.size() == 2 and bool(kids[0].get("_boomerang")) and bool(kids[1].get("_boomerang")),
		"n=%d" % kids.size())
	if kids.size() == 2:
		_check("②b 子代甩程=0.55×母程（380×0.55=209）",
			_approx(float(kids[0].get("_boom_range")), 209.0, 0.5)
				and _approx(float(kids[1].get("_boom_range")), 209.0, 0.5),
			"r=%s" % str(kids[0].get("_boom_range")))
		_check("②c 子代继承元素 FIR + 代数 1 + pierce 1 + bounces 0",
			int(kids[0].get("element")) == GameConst.Element.FIR
				and int(kids[0].get("pierce_left")) == 1
				and int(kids[0].get("bounces_left")) == 0)
	else:
		_check("②b 子代甩程=0.55×母程（380×0.55=209）", false, "子代缺失")
		_check("②c 子代继承元素 FIR + 代数 1 + pierce 1 + bounces 0", false, "子代缺失")
	_release_proj(pm)
	for k in kids:
		_release_proj(k)
	# EXPIRE 期分裂：母弹 lifetime_left 已 ≤0（消亡点分裂）——子代寿命地板 1.2s
	var pe := _spawn_boom(GameConst.Element.KIN, Vector2(300.0, 0.0), Vector2(360.0, 360.0))
	pe.set("lifetime_left", -0.5)
	pe.request_split(2, 28.0, 0.4)
	var floor_kid: ProjectileBase = null
	for p in pool.active_projectiles():
		var pb := p as ProjectileBase
		if pb != null and int(pb.get("generation")) == 1:
			floor_kid = pb
			break
	_check("②d EXPIRE 期分裂（母 lifetime≤0）子代寿命地板 ≥1.2s",
		floor_kid != null and float(floor_kid.get("lifetime_left")) >= 1.19,
		"lt=%s" % str(float(floor_kid.get("lifetime_left")) if floor_kid != null else -1.0))
	_release_proj(pe)
	_release_all_gen1()                      # 清场：②d 双子代全释放（防 ②e 误读残留）
	# 直弹子代不带回旋键（非回旋武器分裂语义不变）
	var ps := _spawn_boom(GameConst.Element.KIN, Vector2(300.0, 0.0), Vector2(360.0, 360.0))
	ps.set("_boomerang", false)
	ps.request_split(2, 28.0, 0.4)
	var straight_kid_boom := false
	for p in pool.active_projectiles():
		var pb := p as ProjectileBase
		if pb != null and int(pb.get("generation")) == 1 and bool(pb.get("_boomerang")):
			straight_kid_boom = true
	_check("②e 直弹（非回旋）子代不带回旋键", not straight_kid_boom)
	_release_proj(ps)
	_release_all_gen1()

# ═══ ③ 边界反弹/速度地板 ══════════════════════════════════════════════
func _case3_edge_floor() -> void:
	print("── ③ 边界反弹死刃守卫（速度地板翻相） ──")
	var p1 := _spawn_boom(GameConst.Element.KIN, Vector2(50.0, 0.0), Vector2(360.0, 360.0))
	p1.tick(DT)
	_check("③a 出程速度 50≤地板 60 → 一 tick 内翻相（phase 1）",
		int(p1.get("_boom_phase")) == 1, "phase=%s" % str(p1.get("_boom_phase")))
	_release_proj(p1)
	# 近墙+跳弹+永存门（999s）：8s 内必解决（回收或回相且速度>50——不死刃滞空）
	var p2 := _spawn_boom(GameConst.Element.KIN, Vector2(-500.0, 0.0), Vector2(60.0, 360.0),
		2, 999.0)
	var i := 0
	while i < 480 and bool(p2.get("_live")):
		p2.tick(DT)
		i += 1
	var live2 := bool(p2.get("_live"))
	_check("③b 近墙+跳弹+999s 永存：8s 内解决（回收，或回相且不滞空）",
		not live2 or (int(p2.get("_boom_phase")) == 1
			and (p2.get("velocity") as Vector2).length() > 50.0),
		"live=%s phase=%s" % [str(live2), str(p2.get("_boom_phase"))])
	_release_proj(p2)
	# 正常定距甩满翻转语义保持（R78 零回归）
	var p3 := _spawn_boom(GameConst.Element.KIN, Vector2(520.0, 0.0), Vector2(360.0, 360.0),
		0, 5.0)
	var j := 0
	while j < 150 and int(p3.get("_boom_phase")) == 0:
		p3.tick(DT)
		j += 1
	_check("③c 正常甩满 380px 翻转保持（距离判定，非速度）",
		int(p3.get("_boom_phase")) == 1 and j < 150, "steps=%d" % j)
	_release_proj(p3)

# ═══ ④ 技能自动施放 ═══════════════════════════════════════════════════
func _case4_auto_cast() -> void:
	print("── ④ 技能自动施放开关（HUD） ──")
	var hud := _gl.hud
	var btn: Button = hud.find_child("SkillAutoCast", true, false) as Button
	hud._on_state_changed(GameConst.GameStatus.MENU)   # 直赋 state 不发事件——显式置 MENU
	_check("④a 键存在且 PLAYING 可见/MENU 隐（技能键同门）",
		btn != null and btn.is_visible_in_tree() == false,   # MENU → 隐
		"btn=%s vis=%s" % [str(btn), str(btn.is_visible_in_tree() if btn != null else "n/a")])
	if btn == null:
		return
	hud._on_state_changed(GameConst.GameStatus.PLAYING)
	_check("④a2 PLAYING 态可见", btn.is_visible_in_tree())
	# 开关键：Meta 真源+文案双态
	Meta.set_setting("skill_auto_cast", false)
	hud._on_skill_auto_pressed()
	var on_ok := bool(Meta.settings("skill_auto_cast")) \
		and String((btn.find_child("SkillAutoCastText", true, false) as Label).text) == "自动施放"
	hud._on_skill_auto_pressed()
	var off_ok := not bool(Meta.settings("skill_auto_cast")) \
		and String((btn.find_child("SkillAutoCastText", true, false) as Label).text) == "手动施放"
	_check("④b 开关键：Meta 真源翻转+文案双态（开=金「自动施放」/关=灰「手动施放」）",
		on_ok and off_ok, "on=%s off=%s" % [str(on_ok), str(off_ok)])
	# 施放帧：开态+冷却完成 → 自动施放（cd 落值=技能已放）
	Meta.set_setting("skill_auto_cast", true)
	_gl.player.set("skill_cd_left", 0.0)
	hud.tick(DT)
	_check("④c 开态冷却完成 → 自动施放（skill_cd_left 落值）",
		float(_gl.player.get("skill_cd_left")) > 0.0,
		"cd=%s" % str(_gl.player.get("skill_cd_left")))
	# 暂停门：模态期不施放
	_gl.player.set("skill_cd_left", 0.0)
	tree.paused = true
	hud.tick(DT)
	var paused_ok := float(_gl.player.get("skill_cd_left")) <= 0.0
	tree.paused = false
	_check("④d 暂停/模态期不施放", paused_ok, "cd=%s" % str(_gl.player.get("skill_cd_left")))
	# 关态：不施放
	Meta.set_setting("skill_auto_cast", false)
	hud.tick(DT)
	_check("④e 关态不施放（手动现状）", float(_gl.player.get("skill_cd_left")) <= 0.0,
		"cd=%s" % str(_gl.player.get("skill_cd_left")))
	_gl.player.set("skill_cd_left", 0.0)
	hud._on_state_changed(GameConst.GameStatus.MENU)


func _approx(a: float, b: float, tol: float) -> bool:
	return absf(a - b) <= tol


func _cleanup() -> void:
	Meta.set_setting("skill_auto_cast", false)   # 源默认关复位（防跨套件泄漏）
	tree.paused = false
	RunSave.clear()
	if _gl != null:
		_gl.free()
		_gl = null
