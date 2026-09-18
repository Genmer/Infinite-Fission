# tests/runner/cd_pace_cases.gd
# R29 迟到减CD 专项用例体（由 test_cd_pace.gd 入口在 autoload 就绪后运行时加载编译）。
# 锁定口径：
# · 节拍变短（挂减CD/射速词条、精通升级、过载咆哮、地图祝福）→ 已在倒计时的
#   武器冷却按「新节拍/旧节拍」比例立刻缩短，且 ≤ 新节拍；
# · 节拍变长（增益到期）→ 不回罚：剩余原样保留，下一周期自然生效；
# · 技能急速（add_skillcdr）→ refresh_skill_cd 后基线缩短 + 已在倒计时的
#   skill_cd_left 同比例缩短。
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
	_test_rof_trait_scales_pending()
	_test_cdr_trait_scales_pending_laser()
	_test_longer_interval_no_penalty()
	_test_skill_haste_scales_skill_cd()
	_test_overdrive_scales_weapon_cd()
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


func _fire_once(p_w: WeaponBase) -> float:
	# 直挂节拍进冷却（与 tick 开火分支同式）。R33：tick 无敌人不开火门生效后，
	# 冷却数学用例不再经 tick 开火路径（本套聚焦节拍缩放，索敌门属 weapon_orbit 域）
	p_w.cooldown_left = 0.0
	var iv: float = p_w._fire_interval()
	p_w.cooldown_left = iv
	p_w._last_interval = iv
	return iv


func _trait(p_path: String) -> TraitData:
	return load(p_path) as TraitData


# ── 用例 ──────────────────────────────────────────────────────────
func _test_rof_trait_scales_pending() -> void:
	print("── 射速词条：挂卡即缩当前倒计时（弹道形态 rof 口径）──")
	var w: WeaponBase = _gl.player.weapon_slots[0]
	_check("默认武器在 0 号槽", w != null and w is WeaponBase, "")
	if w == null:
		return
	var before := _fire_once(w)
	var old_iv := w._last_interval
	_check("开火后进入冷却且登记节拍基准", before > 0.0 and is_equal_approx(before, old_iv),
		"before=%.4f old_iv=%.4f" % [before, old_iv])
	_check("AFF_ROF_UP 挂载成功", w.attach_trait(_trait("res://resources/traits/AFF_ROF_UP.tres")), "")
	var after := w.cooldown_left
	var new_iv := w._fire_interval()
	_check("倒计时立刻缩短", after < before - 0.0001,
		"before=%.4f after=%.4f" % [before, after])
	_check("按新旧节拍比例缩放", is_equal_approx(after, before * new_iv / old_iv),
		"after=%.4f expect=%.4f" % [after, before * new_iv / old_iv])
	_check("不超过新节拍", after <= new_iv + 0.0001,
		"after=%.4f new_iv=%.4f" % [after, new_iv])


func _test_cdr_trait_scales_pending_laser() -> void:
	print("── CDR 词条：非弹道形态挂卡即缩（W4 激光 cd 口径）──")
	_gl.player.unlocked_slots = 4
	var w: WeaponBase = _gl.player.add_weapon(_gl.registry.get_weapon(&"W4_pulse_beam"))
	_check("W4 装配成功", w != null, "add_weapon 返回 null")
	if w == null:
		return
	var before := _fire_once(w)
	_check("W4 开火进入冷却", before > 0.0, "before=%.4f" % before)
	var old_iv := w._fire_interval()
	_check("AFF_CDR 挂载成功", w.attach_trait(_trait("res://resources/traits/AFF_CDR.tres")), "")
	var new_iv := w._fire_interval()
	_check("节拍确按 cd×(1−CDR) 收缩", is_equal_approx(new_iv, old_iv * 0.9),
		"old=%.4f new=%.4f" % [old_iv, new_iv])
	_check("倒计时立刻缩短且不超新节拍",
		w.cooldown_left < before - 0.0001 and w.cooldown_left <= new_iv + 0.0001,
		"before=%.4f after=%.4f new_iv=%.4f" % [before, w.cooldown_left, new_iv])


func _test_longer_interval_no_penalty() -> void:
	print("── 增益到期：节拍变长不回罚 ──")
	var p := _gl.player
	var w: WeaponBase = p.weapon_slots[0]
	p.rof_mult = 2.0                       # 增益期内开火：短节拍
	var fast_iv := _fire_once(w)
	_check("增益期短节拍成立", fast_iv > 0.0, "fast_iv=%.4f" % fast_iv)
	p.rof_mult = 1.0                       # 到期：节拍变长
	var remain := w.cooldown_left
	w.refresh_fire_interval()
	_check("剩余冷却原样保留（不回罚）", is_equal_approx(w.cooldown_left, remain),
		"remain=%.4f after=%.4f" % [remain, w.cooldown_left])
	_check("节拍基准已登记新值", is_equal_approx(w._last_interval, w._fire_interval()),
		"last=%.4f now=%.4f" % [w._last_interval, w._fire_interval()])


func _test_skill_haste_scales_skill_cd() -> void:
	print("── 技能急速：已在倒计时的技能CD比例缩短 ──")
	var p := _gl.player
	var w: WeaponBase = p.weapon_slots[0]
	p.refresh_skill_cd()                   # 真机由 start_run→set_character 建基线（测试环境无菜单流，先同步）
	var base_before := p.skill_cd_base
	_check("技能基线 > 0", base_before > 0.0, "base=%.2f" % base_before)
	_check("AFF_SKILL_HASTE 挂载成功", w.attach_trait(_trait("res://resources/traits/AFF_SKILL_HASTE.tres")), "")
	p.skill_cd_left = base_before * 0.8    # 模拟技能已倒计时 80%
	p.refresh_skill_cd()                   # GameLoop card_chosen 挂卡后同款调用
	var base_after := p.skill_cd_base
	_check("基线缩至 ×0.88", is_equal_approx(base_after, base_before * 0.88),
		"before=%.2f after=%.2f" % [base_before, base_after])
	var expect_left := base_before * 0.8 * base_after / base_before
	_check("倒计时按比例立刻缩短", is_equal_approx(p.skill_cd_left, expect_left)
		and p.skill_cd_left < base_before * 0.8 - 0.0001,
		"left=%.2f expect=%.2f" % [p.skill_cd_left, expect_left])
	p.skill_cd_left = 0.0


func _test_overdrive_scales_weapon_cd() -> void:
	print("── 过载咆哮：开启瞬间武器倒计时立刻减半 ──")
	var p := _gl.player
	p.character_id = &"veles"              # 直写角色（绕开 set_character 的整局重置副作用）
	p.skill_cd_left = 0.0
	p.rof_mult = 1.0
	var w: WeaponBase = p.weapon_slots[0]
	var before := _fire_once(w)
	_check("技能就绪且开启成功", p.skill_ready() and p.activate_skill(), "")
	_check("rof_mult 已 ×2", is_equal_approx(p.rof_mult, 2.0), "rof_mult=%.2f" % p.rof_mult)
	_check("武器倒计时立刻减半",
		w.cooldown_left < before - 0.0001 and is_equal_approx(w.cooldown_left, before * 0.5),
		"before=%.4f after=%.4f" % [before, w.cooldown_left])
	p.skill_active_left = 0.0
	p.rof_mult = 1.0
	p.refresh_weapon_intervals()
