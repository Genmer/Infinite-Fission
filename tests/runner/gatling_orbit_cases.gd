# tests/runner/gatling_orbit_cases.gd
# 加特林曳光 + 环绕武器成长/形态用例体（由 test_gatling_orbit.gd 入口加载）。
extends RefCounted

const DT := 1.0 / 120.0
const MAIN_SCENE := "res://scenes/main.tscn"

var tree: SceneTree
var _pass: int = 0
var _fail: int = 0
var _failures: Array[String] = []
var _gl: GameLoop = null


func run(p_tree: SceneTree) -> void:
	tree = p_tree
	seed(42)
	_boot_game_loop()
	_test_gatling_tracer()
	_test_orbit_growth()
	_test_orbit_style_cards()
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
	_gl.player.set("unlocked_slots", 3)           # 测试需装 3 把武器（手枪+加特林+环绕）


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


# ── 加特林曳光 ────────────────────────────────────────────────────
func _test_gatling_tracer() -> void:
	print("── 加特林曳光 ──")
	# 换装加特林：手枪让位（唯一弹道武器 → 加特林）
	var gat_data: WeaponData = _gl.registry.get_weapon(&"W2_gatling")
	var gat: WeaponBase = _gl.player.add_weapon(gat_data)
	_check("前置：加特林装配", gat != null)
	# 直接开火（绕过武器节奏）→ 检查弹体外观
	gat.try_fire()
	var gat_bullets: Array = []
	for p in (_gl.pools[&"projectile"] as ProjectilePool).active_projectiles():
		if p is ProjectileBase and (p as ProjectileBase).team == 0 \
				and p.get("weapon_ref") == gat:
			gat_bullets.append(p)
	_check("加特林：曳光弹出膛", not gat_bullets.is_empty())
	if gat_bullets.is_empty():
		(_gl.pools[&"enemy"] as EnemyPool).release(null) if false else null
		return
	var b: ProjectileBase = gat_bullets[0]
	var sprite: Sprite2D = b.get("_sprite")
	var tex_size: Vector2 = sprite.texture.get_size()
	_check("加特林：弹体贴图为横向曳光条（宽>高 ×4+）", tex_size.x > tex_size.y * 4.0,
		str(tex_size))
	var expected: float = (b.velocity).angle()
	_check("加特林：弹体朝向 = 速度方向", absf(sprite.rotation - expected) < 0.01)
	# 对比：手枪弹仍为圆珠（正方画布）
	var pistol: WeaponBase = _gl.player.weapon_slots[0]
	if pistol != null and is_instance_valid(pistol) and pistol != gat:
		pistol.try_fire()
		for p in (_gl.pools[&"projectile"] as ProjectilePool).active_projectiles():
			if p is ProjectileBase and (p as ProjectileBase).team == 0 \
					and p.get("weapon_ref") == pistol:
				var ps: Sprite2D = p.get("_sprite")
				var psz: Vector2 = ps.texture.get_size()
				_check("手枪：弹体保持圆珠（方形画布，与加特林区分）",
					psz.x == psz.y)
				break
	for b2 in (_gl.pools[&"projectile"] as ProjectilePool).active_projectiles():
		b2.nullify()


# ── 环绕成长 ──────────────────────────────────────────────────────
func _test_orbit_growth() -> void:
	print("── 环绕转速/大小成长 ──")
	var orbit: WeaponBase = _gl.player.add_weapon(_gl.registry.get_weapon(&"W8_orbit_field"))
	_check("前置：环绕力场装配", orbit != null)
	if orbit == null:
		return
	orbit.level = 1
	orbit.call("try_fire")                         # 力场懒创建（首次开火）
	orbit.call("refresh_orbit_field")
	var field: Node = orbit.get("orbit_field")
	_check("前置：力场实体创建", field != null)
	if field == null:
		return
	var r1: float = float(field.get("orbit_radius"))
	var a1: float = float(field.get("angular_speed"))
	# 升到 L3（转速 270 / 半径 100）→ 升到 L5（转速 335 / 半径 120）
	orbit.call("level_up")
	orbit.call("level_up")
	var r3: float = float(field.get("orbit_radius"))
	var a3: float = float(field.get("angular_speed"))
	_check("环绕：L3 转速成长（240→270）", absf(a3 - 270.0) < 0.001, "%.0f" % a3)
	_check("环绕：L3 半径成长（90→100）", absf(r3 - 100.0) < 0.001, "%.0f" % r3)
	orbit.call("level_up")
	orbit.call("level_up")
	var r5: float = float(field.get("orbit_radius"))
	var a5: float = float(field.get("angular_speed"))
	_check("环绕：L5 转速成长（→335）", absf(a5 - 335.0) < 0.001, "%.0f" % a5)
	_check("环绕：L5 半径成长（→120）", absf(r5 - 120.0) < 0.001, "%.0f" % r5)
	_check("环绕：升级即重铺（转速可观测变化）", a1 < a5)


# ── 形态卡 ────────────────────────────────────────────────────────
func _test_orbit_style_cards() -> void:
	print("── 环绕形态卡 ──")
	_gl.player.set("unlocked_slots", 4)            # 第二把 W8 需要第 4 槽
	for id in [&"MEC_ORBIT_SWORD", &"MEC_ORBIT_AXE", &"MEC_ORBIT_BOLT"]:
		var t: TraitData = _gl.registry.get_trait(id)
		_check("%s：形态卡入注册表（互斥组在册）" % String(id),
			t != null and String(t.params.get("exclusive_group", "")) == "orbit_style")
	var orbit: WeaponBase = _gl.player.add_weapon(_gl.registry.get_weapon(&"W8_orbit_field"))
	_check("前置：环绕力场装配", orbit != null)
	orbit.call("try_fire")                         # 力场懒创建
	orbit.call("refresh_orbit_field")
	var field: Node = orbit.get("orbit_field")
	# 挂剑卡 → 形态 = sword + hit_cd 收紧
	var sword: TraitData = _gl.registry.get_trait(&"MEC_ORBIT_SWORD")
	var base_hit_cd: float = float(field.get("hit_cd"))
	orbit.call("attach_trait", sword)
	_check("形态：挂剑卡 → style = sword", String(field.get("style")) == "sword")
	_check("形态：剑乘区（再命中节奏 +25%）",
		absf(float(field.get("hit_cd")) - base_hit_cd * 0.75) < 0.001)
	# 互斥锁：斧/闪电卡对该武器 _form_allows = false（选中一个其他不再出现）
	var axe: TraitData = _gl.registry.get_trait(&"MEC_ORBIT_AXE")
	var bolt: TraitData = _gl.registry.get_trait(&"MEC_ORBIT_BOLT")
	_check("互斥：斧卡对已锁剑的武器不上架",
		not bool(_gl.card_generator.call("_form_allows", axe, orbit)))
	_check("互斥：闪电卡对已锁剑的武器不上架",
		not bool(_gl.card_generator.call("_form_allows", bolt, orbit)))
	_check("互斥：剑卡自身亦不再上架（同组）",
		not bool(_gl.card_generator.call("_form_allows", sword, orbit)))
	# 挂斧卡（直接挂载通道——互斥门在生成侧，直挂验证乘区）→ 形态 = axe
	orbit.call("attach_trait", axe)
	orbit.call("refresh_orbit_field")
	_check("形态：换挂斧卡 → style = axe", String(field.get("style")) == "axe")
	_check("形态：斧乘区（范围 +25%，L1 基线 90）",
		absf(float(field.get("orbit_radius")) - 90.0 * 1.25) < 0.001,
		"%.1f" % float(field.get("orbit_radius")))
	_check("形态：斧乘区（击退 +60%）",
		absf(float(field.get("knockback")) - 40.0 * 1.6) < 0.001)
	# 未选形态默认 orb
	var plain: WeaponBase = _gl.player.add_weapon(_gl.registry.get_weapon(&"W8_orbit_field"))
	if plain == null:
		_gl.player.weapon_slots[1] = null           # 腾一个槽（池化外武器随 GameLoop 释放）
		plain = _gl.player.add_weapon(_gl.registry.get_weapon(&"W8_orbit_field"))
	if plain == null:
		var slot_desc := ""
		for w in _gl.player.get("weapon_slots"):
			slot_desc += ("W" if w != null else ".")
		print("DBG plain=null unlocked=%s slots=%s" % [str(_gl.player.get("unlocked_slots")), slot_desc])
	else:
		plain.call("try_fire")                     # 力场懒创建（首次开火）
	_check("形态：未选形态默认 orb（浮游球）",
		plain != null and plain.get("orbit_field") != null
		and String(plain.get("orbit_field").get("style")) == "orb")
