# tests/runner/mirror_muzzle_cases.gd
# R191#2 镜面枪口锚点 + 镜面火花用例体（由 test_mirror_muzzle.gd 入口加载）。
# 真源：R191 用户反馈 #2「枪口不在镜子也不在复制出的加特林身上」。
# · A 锚点组：镜面（W2_gatling 源）实弹出生点 == 外层 MirrorImage 包装体化身枪口
#   （avatar_global 经 inner→parent 别名查册）——≤2.0px 同帧采样；距菱形回退位
#   （inner.global_position）与玩家中心 ≥52px 双负例（修复前出生点==菱形，必红）；
#   MENU 冻结前提 <0.01px；玩家固定屏中心防 clamp；归因键 weapon_uid==inner.uid。
# · B 火花组：镜面开火 ice_shard + MirrorImage.TINT + 0.09s；自熄；本体 star 零回归；
#   fx_quality=0 门；MuzzleFlash 子节点恒 1（零逐发实例化）。
# · 负例：R183 帧内副本（_summon_copies 在册件）首次 find 即命中行为前后不变；
#   无化身（层未驱动）时镜面弹回退菱形位（回退语义保留）。
extends RefCounted

const DT := 1.0 / 120.0
const DT60 := 1.0 / 60.0
const MAIN_SCENE := "res://scenes/main.tscn"
const ANCHOR_EPS := 2.0            # 锚点容差 px（纯浮点余量；修复前 ~82~112px 量级）
const FALLBACK_MIN := 52.0         # 与菱形回退位/玩家中心的最小距离（证明确实换锚）
const FROZEN_EPS := 0.01           # MENU 冻结前提：同态双采零漂移 px
const SAFE_THETA := 3.15           # A1 标定窗起点（化身角 rad——见 _test_anchor_on_avatar）
const PROFILE_FRAMES := 180        # A1 剖面帧数（角扫 2.1 rad，全程避开几何近点）
const SWEEP_FRAMES := 540          # A2 全圆扫掠帧数（跨对齐点——分布断言；360° ≈ 538 帧）
const PLAYER_HOME := Vector2(360.0, 900.0)   # E-15 活动区钳 y∈[768,1268]——驱 tick 合法位

var tree: SceneTree
var _pass: int = 0
var _fail: int = 0
var _failures: Array[String] = []
var _gl: GameLoop = null
var _current_img: MirrorImage = null       # A 组当前包装体（相位标定索引用）
var _prev_character: StringName = &""
var _prev_wave20: bool = false


func run(p_tree: SceneTree) -> void:
	tree = p_tree
	seed(42)
	_boot_game_loop()
	_test_no_avatar_fallback()       # 负例：无化身回退菱形（须先于任何层驱动）
	_test_anchor_on_avatar()         # A. 锚点组（剖面窗逐发硬界 + 全程扫掠分布）
	_test_mirror_spark()             # B. 火花组（冰晶/自熄/本体零回归/低档门）
	_test_r183_copy_unchanged()      # 负例：R183 副本行为前后不变
	_teardown_game_loop()
	print("────────────────────────────────────────")
	print("汇总：PASS %d / FAIL %d（共 %d 项）" % [_pass, _fail, _pass + _fail])
	if not _failures.is_empty():
		for f in _failures:
			print("  FAIL 详情：%s" % f)


func fail_count() -> int:
	return _fail


# ── 环境装配 ──────────────────────────────────────────────────────
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
	_gl.player.unlocked_slots = 6
	_gl.state = GameConst.GameStatus.MENU    # 冻结波次刷怪（用例自管夹具敌）


func _teardown_game_loop() -> void:
	tree.paused = false
	Meta.set_setting("fx_quality", 2)        # 复位出厂档（防污染其他套件）
	if _prev_character != StringName(&""):
		Meta.character_id = _prev_character
	if not _prev_wave20:
		Meta.achievements_done.erase("wave_20")
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
		_failures.append("%s（%s）" % [p_name, p_detail])
		print("FAIL | %s | %s" % [p_name, p_detail])


func _wipe_weapons() -> void:
	# 用例隔离：镜面全清 + 武器槽清空（保留槽位解锁）+ 指向锁/反应注册表复位
	_gl.player.clear_mirrors()
	_gl.player.call(&"set_mirror_locked", false)
	_gl.elemental.clear_reaction_mults()
	var slots: Array = _gl.player.get("weapon_slots")
	for i in range(slots.size()):
		var w: Variant = slots[i]
		if w != null and is_instance_valid(w):
			slots[i] = null
			(w as Node).queue_free()
	_gl.player.unlocked_slots = 6


func _add(p_id: StringName) -> WeaponBase:
	return _gl.player.add_weapon(_gl.registry.get_weapon(p_id))


func _make_prism(p_level: int = 1) -> MirrorWeapon:
	# 棱镜装配（真件 MirrorWeapon——生产形态；注入包透传 player._deps）
	var prism := MirrorWeapon.new()
	prism.setup(_gl.registry.get_weapon(&"W5_prism"), _gl.player, _gl.player.get("_deps"))
	prism.meta_atk_pct = 0.0
	if not _gl.player.equip_weapon(prism):
		prism.free()
		return null
	if p_level > 1:
		prism.level = p_level
	prism.sync_mirrors(true)
	return prism


func _drive_player(p_frames: int, p_dt: float = DT60) -> void:
	for i in range(p_frames):
		GameConfig.advance_frame()
		_gl.player.call(&"tick", p_dt, Vector2.ZERO)


func _layer() -> Node:
	for c in _gl.player.get_children():
		if c is WeaponOrbitAvatars:
			return c
	return null


func _layer_process(p_frames: int, p_dt: float = DT60) -> void:
	# 化身惰性创建 + 公转/朝向同步（无头需手动驱动——先例 weapon_orbit_cases.gd:86）
	var layer := _layer()
	if layer != null:
		for i in range(p_frames):
			layer.call("_process", p_dt)


func _entries() -> Array:
	var layer := _layer()
	if layer == null:
		return []
	return layer.call("_entries_of", _gl.player)


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


func _spawn_fixtures(p_positions: Array[Vector2]) -> Array[Node2D]:
	# 夹具敌（索敌/开火驱动；静态不移动——玩家侧 tick 手动驱动不经过敌 AI 帧）
	var out: Array[Node2D] = []
	for pos in p_positions:
		var enemy := (_gl.pools[&"enemy"] as EnemyPool).acquire()
		enemy.spawn(_fixture_enemy(&"E_G3_FIXTURE", 100000.0), 1, 0)
		enemy.position = pos
		out.append(enemy)
	_gl.enemy_grid.rebuild(out)
	return out


func _release_fixtures(p_enemies: Array[Node2D]) -> void:
	for e in p_enemies:
		if e != null and is_instance_valid(e):
			(_gl.pools[&"enemy"] as EnemyPool).release(e)
	_gl.enemy_grid.rebuild([] as Array[Node2D])


func _new_result() -> Dictionary:
	return {
		"samples": 0, "max_anchor": 0.0, "frozen_violations": 0, "violation": "",
		"min_diamond": INF, "max_diamond": 0.0, "min_player": INF,
		"diamond_ok": 0, "player_ok": 0, "not_diamond": 0,
		"d_sum": 0.0, "p_sum": 0.0, "d_list": [], "p_list": [],
	}


func _median(p_arr: Array) -> float:
	if p_arr.is_empty():
		return 0.0
	var s: Array = p_arr.duplicate()
	s.sort()
	return float(s[int(s.size() / 2)])


func _sample_anchor_shots(p_img: MirrorImage, p_inner: WeaponBase, p_frames: int,
		p_result: Dictionary) -> void:
	# 逐帧：layer._process(1/60) → 冻结双采（<0.01px）→ player.tick（镜面节拍开火）
	# → 当拍新弹同帧采样（此前样本已 nullify 出池——活表内 uid 匹配者即本拍生成）。
	var layer := _layer()
	var pool: ProjectilePool = _gl.pools[&"projectile"]
	for f in range(p_frames):
		layer.call("_process", DT60)
		var oracle_v: Variant = layer.call("avatar_global", p_img)
		if oracle_v == null:
			continue
		var oracle: Vector2 = oracle_v
		var oracle2_v: Variant = layer.call("avatar_global", p_img)
		if oracle.distance_to(oracle2_v) > FROZEN_EPS:
			p_result["frozen_violations"] = int(p_result["frozen_violations"]) + 1
		GameConfig.advance_frame()
		_gl.player.call(&"tick", DT60, Vector2.ZERO)
		for p in pool.active_projectiles():
			var pb := p as ProjectileBase
			if pb == null or pb.team != 0 or pb.weapon_uid != p_inner.uid:
				continue
			var sp: Vector2 = pb.global_position
			p_result["samples"] = int(p_result["samples"]) + 1
			var d_anchor: float = sp.distance_to(oracle)
			p_result["max_anchor"] = maxf(float(p_result["max_anchor"]), d_anchor)
			if d_anchor > ANCHOR_EPS and String(p_result["violation"]) == "":
				p_result["violation"] = "f=%d spawn=%s oracle=%s inner=%s player=%s drag=%s" % [
					f, str(sp), str(oracle), str(p_inner.global_position),
					str(_gl.player.global_position), str(_gl.player.get("_drag_accum"))]
			var d_diamond: float = sp.distance_to(p_inner.global_position)
			var d_player: float = sp.distance_to(_gl.player.global_position)
			p_result["min_diamond"] = minf(float(p_result["min_diamond"]), d_diamond)
			p_result["max_diamond"] = maxf(float(p_result["max_diamond"]), d_diamond)
			p_result["min_player"] = minf(float(p_result["min_player"]), d_player)
			p_result["diamond_ok"] = int(p_result["diamond_ok"]) + (1 if d_diamond >= FALLBACK_MIN else 0)
			p_result["player_ok"] = int(p_result["player_ok"]) + (1 if d_player >= FALLBACK_MIN else 0)
			p_result["not_diamond"] = int(p_result["not_diamond"]) + (1 if d_diamond > 2.0 else 0)
			p_result["d_sum"] = float(p_result["d_sum"]) + d_diamond
			p_result["p_sum"] = float(p_result["p_sum"]) + d_player
			p_result["d_list"].append(d_diamond)
			p_result["p_list"].append(d_player)
			pb.call("nullify")     # 采样即消弹（活表恒净——下拍匹配者必为新弹）


func _warm_avatar_angle(p_layer: Node, p_theta: float) -> void:
	# 推进公转相位至包装体化身角进入 [p_theta, p_theta+0.05) 窗（确定性标定）：
	# 化身枪口 = 化身位 + aim×18 前伸，公转全程会扫过菱形标记位/玩家中心邻域
	# （几何近点 ~1.4px/36px——近点出生是正确行为而非缺陷）；≥52px 硬界剖面须把
	# 采样窗标定在安全弧（化身角 ∈ [~2.87, ~5.61]，对最坏 bob 半径 54px 仍 ≥52px）。
	var idx: int = _entries().find(_current_img)
	if idx < 0:
		return
	var n := maxi(_entries().size(), 1)
	var guard := 0
	while guard < 4000:
		var theta: float = fposmod(float(p_layer.get("_spin")) + TAU * float(idx) / float(n), TAU)
		if theta >= p_theta and theta < p_theta + 0.05:
			return
		p_layer.call("_process", DT60)
		guard += 1


# ── 负例. 无化身回退菱形（avatar_global → null → inner.global_position） ──
func _test_no_avatar_fallback() -> void:
	print("── 负例. 无化身回退（层未驱动 → 镜面弹出生点 == 菱形标记位） ──")
	_wipe_weapons()
	_gl.player.global_position = PLAYER_HOME             # E-15 钳制区合法位
	_add(&"W2_gatling")
	var prism := _make_prism(1)
	if prism == null or prism.mirrors.is_empty():
		_check("前置：镜面在场", false)
		return
	var img: MirrorImage = prism.mirrors[0]
	var inner: WeaponBase = img.inner
	_check("前置：inner 为镜面行为壳（is_mirror_image）", inner != null
		and bool(inner.get("is_mirror_image")))
	var layer := _layer()
	_check("前置：化身未建（_avatars 空——层从未驱动）",
		layer != null and (layer.get("_avatars") as Array).is_empty())
	var fixtures := _spawn_fixtures([Vector2(360.0, 300.0)] as Array[Vector2])
	img.cooldown_left = 0.0
	_drive_player(1)                         # 一拍：镜面节拍开火（查册两级落空 → 回退）
	var spawned := Vector2.INF
	var hit_uid := false
	for p in (_gl.pools[&"projectile"] as ProjectilePool).active_projectiles():
		var pb := p as ProjectileBase
		if pb != null and pb.team == 0 and pb.weapon_uid == inner.uid:
			spawned = pb.global_position
			hit_uid = true
			pb.call("nullify")
	_check("负例：镜面弹已出膛（归因键 weapon_uid==inner.uid）", hit_uid)
	_check("负例：无化身时出生点 == inner.global_position（菱形回退语义保留）",
		hit_uid and spawned.distance_to(inner.global_position) <= 0.01,
		"d=%.4f" % spawned.distance_to(inner.global_position))
	_release_fixtures(fixtures)
	_wipe_weapons()


# ── A. 锚点组（外层包装体化身枪口） ───────────────────────────────
func _test_anchor_on_avatar() -> void:
	print("── A. 锚点组（镜面弹出生点 = 外层 MirrorImage 化身枪口） ──")
	_wipe_weapons()
	_gl.player.global_position = PLAYER_HOME             # 玩家固定活动区中心防 clamp
	_add(&"W2_gatling")
	var prism := _make_prism(1)
	_check("前置：1 镜在场", prism != null and _gl.player.mirror_count() == 1
		and prism.mirrors.size() == 1)
	if prism == null or prism.mirrors.is_empty():
		return
	var img: MirrorImage = prism.mirrors[0]
	_current_img = img
	var inner: WeaponBase = img.inner
	var layer := _layer()
	_layer_process(3)                        # 显式驱动 2-3 拍建化身（先例口径）
	var entries := _entries()
	var idx: int = entries.find(img)
	_check("前置：包装体入册（entries.find(outer) 首查命中）", idx >= 0)
	var avatars: Array = layer.get("_avatars")
	_check("前置：包装体化身已建且可见",
		idx >= 0 and idx < avatars.size() and (avatars[idx] as Sprite2D).visible)
	# 夹具敌放远（600px 正上方）：化身角全 sweep 内 aim 恒 ≈ 竖直向上（±10° 内）——
	# 枪口前伸方向稳定，A1 安全弧标定边界不含瞄准方向漂移项
	var fixtures := _spawn_fixtures([Vector2(360.0, 300.0)] as Array[Vector2])
	_gl.player.rof_mult = 10.0               # 加特林镜面节拍推到钳 30/s（采样量）
	_gl.player.refresh_weapon_intervals()
	# A1 剖面窗：公转相位标定到化身角 3.0 rad（安全弧起点）→ 180 帧逐发硬界
	_warm_avatar_angle(layer, SAFE_THETA)
	var a1 := _new_result()
	_sample_anchor_shots(img, inner, PROFILE_FRAMES, a1)
	var a1_n := int(a1["samples"])
	_check("A1：采样量 ≥ 60 发（30/s 钳 × 3s 窗）", a1_n >= 60, str(a1_n))
	_check("A1：MENU 冻结前提（同态双采零漂移 <%.2fpx）" % FROZEN_EPS,
		int(a1["frozen_violations"]) == 0, str(a1["frozen_violations"]))
	_check("A1：逐发 |spawn−avatar_global(outer)| ≤ %.1fpx（同帧采样）" % ANCHOR_EPS,
		a1_n > 0 and float(a1["max_anchor"]) <= ANCHOR_EPS,
		"max=%.4fpx n=%d %s" % [float(a1["max_anchor"]), a1_n, str(a1["violation"])])
	_check("A1：逐发 |spawn−inner.global_position| ≥ %.0fpx（非菱形回退位）" % FALLBACK_MIN,
		a1_n > 0 and float(a1["min_diamond"]) >= FALLBACK_MIN,
		"min=%.1fpx" % float(a1["min_diamond"]))
	_check("A1：逐发 |spawn−玩家中心| ≥ %.0fpx（非玩家中心回退）" % FALLBACK_MIN,
		a1_n > 0 and float(a1["min_player"]) >= FALLBACK_MIN,
		"min=%.1fpx" % float(a1["min_player"]))
	# A2 全程扫掠：继续 240 帧（跨对齐点——化身枪口扫过菱形邻域是正确几何，
	# 分布口径断言：锚点逐发成立 + 中位距离 + 非菱形重合占比）
	var a2 := _new_result()
	_sample_anchor_shots(img, inner, SWEEP_FRAMES, a2)
	var a2_n := int(a2["samples"])
	var total_n := a1_n + a2_n
	_check("A2：累计采样 ≥240 帧驱动且 ≥120 发（≥240 帧采 mirror 弹口径）",
		total_n >= 120, "总帧 %d 发 %d" % [PROFILE_FRAMES + SWEEP_FRAMES, total_n])
	_check("A2：扫掠期逐发 |spawn−avatar_global(outer)| ≤ %.1fpx" % ANCHOR_EPS,
		a2_n > 0 and float(a2["max_anchor"]) <= ANCHOR_EPS,
		"max=%.4fpx n=%d" % [float(a2["max_anchor"]), a2_n])
	_check("A2：扫掠期 |spawn−菱形| 中位距离 ≥%.0fpx" % FALLBACK_MIN,
		a2_n > 0 and _median(a2["d_list"]) >= FALLBACK_MIN,
		"median=%.1fpx" % _median(a2["d_list"]))
	_check("A2：扫掠期 |spawn−玩家中心| 中位距离 ≥%.0fpx" % FALLBACK_MIN,
		a2_n > 0 and _median(a2["p_list"]) >= FALLBACK_MIN,
		"median=%.1fpx" % _median(a2["p_list"]))
	_check("A2：扫掠期出生点非菱形重合占比 ≥ 0.9（修复前 == 0——出生点恒为菱形）",
		a2_n > 0 and float(int(a2["not_diamond"])) / float(a2_n) >= 0.9,
		"%d/%d" % [int(a2["not_diamond"]), a2_n])
	# 修复前错位标定（探针口径：化身枪口 ↔ 菱形距离带 = 修复前出生点错位量）
	print(("  标定：化身枪口 ↔ 菱形回退位 距离带 %.1f~%.1f px（修复前出生点即菱形——"
		+ "错位即此带；修复后出生点贴合化身 ≤%.4fpx）")
		% [float(a2["min_diamond"]), float(a2["max_diamond"]), float(a2["max_anchor"])])
	_gl.player.rof_mult = 1.0
	_gl.player.refresh_weapon_intervals()
	_release_fixtures(fixtures)
	_wipe_weapons()


# ── B. 火花组（镜面开火读感 + 本体零回归） ────────────────────────
func _test_mirror_spark() -> void:
	print("── B. 火花组（ice_shard/TINT/0.09s · 自熄 · star 零回归 · 低档门） ──")
	_wipe_weapons()
	_gl.player.global_position = PLAYER_HOME
	Meta.set_setting("fx_quality", 2)
	var gatling: WeaponBase = _add(&"W2_gatling")
	var prism := _make_prism(1)
	if prism == null or prism.mirrors.is_empty() or gatling == null:
		_check("前置：镜面与本体加特林在场", false)
		return
	var img: MirrorImage = prism.mirrors[0]
	var inner: WeaponBase = img.inner
	var fixtures := _spawn_fixtures([Vector2(360.0, 300.0)] as Array[Vector2])
	_layer_process(3)
	# ① 镜面开火 → 冰晶火花（常驻件首建即显）
	img.cooldown_left = 0.0
	_drive_player(1)
	var flash: Sprite2D = inner.get("_muzzle_flash")
	_check("B①：镜面开火建 MuzzleFlash（常驻件非空）", flash != null)
	if flash == null:
		_release_fixtures(fixtures)
		_wipe_weapons()
		return
	_check("B①：开火帧 visible == true", bool(flash.visible))
	_check("B①：texture == TextureFactory.ice_shard()", flash.texture == TextureFactory.ice_shard())
	_check("B①：modulate == MirrorImage.TINT（银白/冰青单源）",
		flash.modulate == MirrorImage.TINT, str(flash.modulate))
	_check("B①：_muzzle_timer > 0（0.09s 口径）", float(inner.get("_muzzle_timer")) > 0.0,
		"%.4f" % float(inner.get("_muzzle_timer")))
	# ② 自熄：撤敌（无敌门不续射）→ 驱动 ≥0.2s → visible == false
	_release_fixtures(fixtures)
	_drive_player(14)                        # 0.233s @60Hz > 0.09s
	_check("B②：驱动 ≥0.2s 后自熄（visible == false）", not bool(flash.visible))
	# ③ 本体零回归：槽位加特林 flash 仍 star(40, XP)/0.05s
	fixtures = _spawn_fixtures([Vector2(360.0, 300.0)] as Array[Vector2])
	gatling.cooldown_left = 0.0
	_drive_player(1)
	var gflash: Sprite2D = gatling.get("_muzzle_flash")
	_check("B③：本体开火建 MuzzleFlash", gflash != null)
	_check("B③：本体 texture 仍 == TextureFactory.star(40, PopPalette.XP)",
		gflash != null and gflash.texture == TextureFactory.star(40, PopPalette.XP))
	_check("B③：本体 flash visible 且 _muzzle_timer > 0（0.05s 口径）",
		gflash != null and bool(gflash.visible) and float(gatling.get("_muzzle_timer")) > 0.0,
		"%.4f" % (float(gatling.get("_muzzle_timer")) if gflash != null else -1.0))
	# ④ fx_quality=0 门：开火后 visible 恒 false（既有门不放宽）
	_release_fixtures(fixtures)
	_drive_player(14)                        # 先熄尽（防前火残留 visible 污染断言）
	Meta.set_setting("fx_quality", 0)
	fixtures = _spawn_fixtures([Vector2(360.0, 300.0)] as Array[Vector2])
	img.cooldown_left = 0.0
	var fired_uid := false
	var live0: int = int((_gl.pools[&"projectile"] as ProjectilePool).stats()["live"])
	_drive_player(1)
	for p in (_gl.pools[&"projectile"] as ProjectilePool).active_projectiles():
		var pb := p as ProjectileBase
		if pb != null and pb.team == 0 and pb.weapon_uid == inner.uid:
			fired_uid = true
			pb.call("nullify")
	_check("B④：低档门开火路径到达（镜面弹已出膛，live %d→%d）" % [live0,
		int((_gl.pools[&"projectile"] as ProjectilePool).stats()["live"])], fired_uid)
	_check("B④：fx_quality=0 开火后 visible == false（门不放宽）",
		flash != null and not bool(flash.visible)
		and is_equal_approx(float(inner.get("_muzzle_timer")), 0.0))
	Meta.set_setting("fx_quality", 2)
	# ⑤ 零逐发实例化：连发后单 inner 名为 MuzzleFlash 的子节点恒 1
	img.cooldown_left = 0.0
	_drive_player(24)                        # 多拍连发
	var flash_count := 0
	for c in inner.get_children():
		if c is Sprite2D and String(c.name) == "MuzzleFlash":
			flash_count += 1
	_check("B⑤：连发后 MuzzleFlash 子节点恒 1（零逐发实例化）", flash_count == 1,
		str(flash_count))
	_release_fixtures(fixtures)
	_wipe_weapons()


# ── 负例. R183 副本行为前后不变（首次 find 即命中，父链别名不触发） ──
func _test_r183_copy_unchanged() -> void:
	print("── 负例. R183 副本（_summon_copies 在册件首次 find 即命中） ──")
	_wipe_weapons()
	_gl.player.global_position = PLAYER_HOME
	_prev_character = Meta.character_id
	_prev_wave20 = bool(Meta.achievements_done.get("wave_20", false))
	Meta.character_id = &"noah"
	Meta.achievements_done["wave_20"] = true # 诺亚解锁门（w5 用例同口径直授）
	_gl.player.set_character(&"noah")
	_gl.player.set("max_hp", 1000000.0)
	_gl.player.set("hp", 1000000.0)
	_gl.player.set("skill_cd_left", 0.0)
	_gl.player.unlocked_slots = 6
	var gatling: WeaponBase = _add(&"W2_gatling")
	if gatling == null:
		_check("前置：本体加特林在场", false)
		return
	_layer_process(3)
	_check("负例前置：诺亚技能施放（_summon_copies 通道）",
		bool(_gl.player.call(&"activate_skill")))
	var copies: Array = _gl.player.get("_summon_copies")
	_layer_process(3)                        # entries 扩建副本化身
	var entries := _entries()
	_check("负例前置：帧内副本在册（≥1）", not copies.is_empty(), str(copies.size()))
	var fixtures := _spawn_fixtures([Vector2(360.0, 300.0)] as Array[Vector2])
	var all_anchored := true
	var detail := ""
	for c in copies:
		var copy := c as WeaponBase
		if copy == null or not is_instance_valid(copy):
			continue
		# 首次 find 即命中：副本 ∈ entries（_summon_copies 段）；父链目标是玩家
		# （非 WeaponBase）——别名分支对该路径零触达（行为前后不变）
		if entries.find(copy) < 0 or copy.get_parent() != _gl.player:
			all_anchored = false
			detail = "find=%d parent=%s" % [entries.find(copy), str(copy.get_parent())]
			continue
		var av_v: Variant = _layer().call("avatar_global", copy)
		var wm_v: Variant = _gl.player.call("weapon_muzzle_global", copy)
		if av_v == null or wm_v == null \
				or (wm_v as Vector2).distance_to(av_v as Vector2) > 0.01:
			all_anchored = false
			detail = "avatar=%s muzzle=%s" % [str(av_v), str(wm_v)]
			continue
		copy.cooldown_left = 0.0
	_drive_player(1)                         # 副本节拍开火 → 出生点锚定自身化身
	for p in (_gl.pools[&"projectile"] as ProjectilePool).active_projectiles():
		var pb := p as ProjectileBase
		if pb == null or pb.team != 0:
			continue
		var src: WeaponBase = pb.get("weapon_ref")
		if src == null or not (copies.has(src)):
			continue
		var av2_v: Variant = _layer().call("avatar_global", src)
		if av2_v == null or pb.global_position.distance_to(av2_v as Vector2) > ANCHOR_EPS:
			all_anchored = false
			detail = "spawn=%s avatar=%s" % [str(pb.global_position), str(av2_v)]
		pb.call("nullify")
	_check("负例：副本 weapon_muzzle_global 首查命中 + 出生点锚定自身化身（零变化）",
		all_anchored, detail)
	_release_fixtures(fixtures)
	_wipe_weapons()
