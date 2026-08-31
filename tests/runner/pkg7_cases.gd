# tests/runner/pkg7_cases.gd
# v0.7.0 自测用例体（由 test_pkg7.gd 入口在 autoload 就绪后运行时加载编译）。
# 覆盖 A6_v0.7.0_design.md 增量（按 U 任务分节；夹具沿用 pkg6 GameLoop 完整 Boot 模式）。
# 确定性：固定 RNG 种子（ChipHandler 默认 seed 4242 / CardGenerator 42 / 金币 42）。
extends RefCounted

const DT := 1.0 / 120.0                          # 120Hz 物理帧

var tree: SceneTree
var _pass: int = 0
var _fail: int = 0
var _failures: Array[String] = []
var _gl: GameLoop = null                         # 共享 GameLoop（Boot 一次）


func run(p_tree: SceneTree) -> void:
	tree = p_tree
	seed(42)
	_ensure_autoloads()
	_boot_game_loop()
	_test_chip_data()                             # U1
	_teardown_game_loop()
	# 汇总
	print("────────────────────────────────────────")
	print("汇总：PASS %d / FAIL %d（共 %d 项）" % [_pass, _fail, _pass + _fail])
	if not _failures.is_empty():
		for f in _failures:
			print("  FAIL 详情：%s" % f)


func fail_count() -> int:
	return _fail


# ── 环境引导（pkg6 夹具模式） ─────────────────────────────────────
func _ensure_autoloads() -> void:
	_check("autoload 就绪（EventBus/GameConfig/DebugStats）",
		EventBus != null and GameConfig != null and DebugStats != null)
	_check("GameConfig 非致命（balance 加载）", not GameConfig.is_fatal() and GameConfig.balance != null)


func _boot_game_loop() -> void:
	_gl = GameLoop.new()
	_gl.name = "GameLoopUnderTest"
	tree.get_root().add_child(_gl)
	_check("Boot：完成且进入 MENU", _gl.boot_ready and _gl.state == GameConst.GameStatus.MENU)


func _teardown_game_loop() -> void:
	tree.paused = false
	if _gl != null:
		_gl.free()
		_gl = null


func _check(p_desc: String, p_cond: bool, p_detail: String = "") -> void:
	if p_cond:
		_pass += 1
		print("  PASS %s" % p_desc)
	else:
		_fail += 1
		_failures.append("%s %s" % [p_desc, p_detail])
		print("  FAIL %s %s" % [p_desc, p_detail])


# ══ U1：芯片数据层 ════════════════════════════════════════════════
func _test_chip_data() -> void:
	print("── U1 芯片数据层 ──")
	var reg := _gl.registry
	# 封闭注册表 + manifest 类目
	_check("CHIP_STAT_KEYS 恰好 8 键（A6 §1 冻结表）", GameConst.CHIP_STAT_KEYS.size() == 8)
	for key in [&"atk_pct", &"rof", &"crit_rate", &"crit_dmg", &"attach_strength",
			&"gold_gain", &"max_hp", &"xp_gain"]:
		if not GameConst.CHIP_STAT_KEYS.has(key):
			_check("CHIP_STAT_KEYS 含 %s" % String(key), false)
	_check("chips 类目注册 8 枚（0 剔除）", reg.chips.size() == 8,
		"实际 %d" % reg.chips.size())
	# 冻结数值表（id -> [stat_key, values 白/蓝/紫/金]）
	var table := {
		&"CHIP_ATK": [&"atk_pct", [0.10, 0.16, 0.24, 0.35]],
		&"CHIP_ROF": [&"rof", [0.08, 0.12, 0.18, 0.25]],
		&"CHIP_CRIT": [&"crit_rate", [0.05, 0.08, 0.12, 0.18]],
		&"CHIP_CRITDMG": [&"crit_dmg", [0.15, 0.25, 0.40, 0.60]],
		&"CHIP_ATTACH": [&"attach_strength", [0.15, 0.25, 0.35, 0.50]],
		&"CHIP_GOLD": [&"gold_gain", [0.10, 0.18, 0.28, 0.40]],
		&"CHIP_HP": [&"max_hp", [20.0, 35.0, 55.0, 80.0]],
		&"CHIP_XP": [&"xp_gain", [0.08, 0.14, 0.22, 0.32]],
	}
	var names := {
		&"CHIP_ATK": "攻击核心", &"CHIP_ROF": "超频模块", &"CHIP_CRIT": "精准校准",
		&"CHIP_CRITDMG": "暴伤放大器", &"CHIP_ATTACH": "元素共鸣器", &"CHIP_GOLD": "贪婪金币",
		&"CHIP_HP": "生命方舟", &"CHIP_XP": "经验汲取",
	}
	for id in table:
		var chip := reg.get_chip(id)
		if chip == null:
			_check("芯片 %s 注册加载" % String(id), false)
			continue
		var row: Array = table[id]
		var vals: Array = row[1]
		var ok: bool = chip.stat_key == row[0] and chip.values.size() == 4
		for i in range(4):
			ok = ok and is_equal_approx(chip.values[i], float(vals[i]))
		_check("芯片 %s 数值冻结（stat_key + 4 档）" % String(id), ok,
			"stat=%s vals=%s" % [String(chip.stat_key), str(chip.values)])
		_check("芯片 %s 中文名/描述非空" % String(id),
			chip.display_name == names[id] and chip.description != "")
	# validator：全部 0 错误
	var v := DataValidator.new()
	var all_clean := true
	for id in reg.chips:
		var c := reg.get_chip(id)
		if not v.validate_chip(c).is_empty():
			all_clean = false
	_check("validate_chip：8 枚全部 0 错误", all_clean)
	# validator 剔除路径：坏数据逐一判错（仅 error 级触发剔除；warning 不剔除）
	var bad := ChipData.new()
	_check("validate_chip：空 id 报错", _has_error(v.validate_chip(bad)))
	bad.id = &"CHIP_BAD"
	_check("validate_chip：stat_key 悬空报错", _has_error(v.validate_chip(bad)))
	bad.stat_key = &"no_such_stat"
	_check("validate_chip：stat_key 越界报错", _has_error(v.validate_chip(bad)))
	bad.stat_key = &"atk_pct"
	_check("validate_chip：values 缺档报错（3 项）", _has_error(v.validate_chip(bad)))
	bad.values = [0.1, 0.0, 0.2, 0.3]
	_check("validate_chip：values 含 ≤0 报错", _has_error(v.validate_chip(bad)))
	bad.values = [0.3, 0.2, 0.2, 0.1]
	_check("validate_chip：values 非单调报错", _has_error(v.validate_chip(bad)))
	bad.values = [0.1, 0.2, 0.2, 0.3]
	bad.display_name = "测试芯片"
	_check("validate_chip：合法构造 0 错误 0 告警", v.validate_chip(bad).is_empty())
	var unnamed := ChipData.new()
	unnamed.id = &"CHIP_UNNAMED"
	unnamed.stat_key = &"atk_pct"
	unnamed.values = [0.1, 0.2, 0.3, 0.4]
	var unnamed_verdicts := v.validate_chip(unnamed)
	_check("validate_chip：display_name 空 → 仅 warning（不剔除）",
		not unnamed_verdicts.is_empty() and not _has_error(unnamed_verdicts))
	# registry 剔除闭环（内存注入坏件 → validate_all → rejected 含 chips → erase）
	bad.values = [0.1, 0.2]                          # 重新注入错误（缺档）
	reg.chips[&"CHIP_BAD"] = bad
	var result: Dictionary = v.validate_all(reg)
	var rejected_chips := false
	for r in result["rejected"]:
		if r.get("category") == &"chips":
			rejected_chips = true
	_check("validate_all：坏芯片进 rejected（chips 类目闭环）", rejected_chips)
	reg.chips.erase(&"CHIP_BAD")
	_check("get_chip：未命中返回 null", reg.get_chip(&"CHIP_NOPE") == null)


func _has_error(p_verdicts: Array) -> bool:
	# validator 语义：仅 SEV_ERROR 触发剔除（warning 不剔除）
	for v in p_verdicts:
		if String(v.get("severity", DataValidator.SEV_ERROR)) == DataValidator.SEV_ERROR:
			return true
	return false
