# tests/runner/pkg10_extra_cases.gd
# v1.0.0 验收补充用例体（tester 独立复核 + 补漏；由 test_pkg10_extra.gd 入口在 autoload
# 就绪后运行时加载编译）。夹具沿用 pkg10 GameLoop 完整 Boot 模式。
# 隔离纪律：runner 引导后第一件事 set_save_path(测试档) + wipe()；每组前置 wipe；
# 收尾 wipe → set_save_path(DEFAULT) → wipe 清残留（E1 附加档 PATH_B 一并清）。
extends RefCounted

const TEST_PATH := "user://pkg10_extra_meta_test.cfg"
const PATH_B := "user://pkg10_extra_meta_b.cfg"

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
	# ★ 隔离纪律：引导后先切测试档 + 清两档残留
	_gl.meta_store.set_save_path(TEST_PATH)
	_gl.meta_store.wipe()
	_test_e1_set_save_path_reset()                # E1
	_test_e2_second_run_settle()                  # E2
	_test_e3_zero_gold_settle()                   # E3
	_test_e4_greed_negative()                     # E4
	_test_e5_panel_disabled_states()              # E5
	_test_e6_gameover_layout()                    # E6
	_test_e7_save_key_layout()                    # E7
	_test_e8_price_recalc()                       # E8
	_test_e9_max_hp_formula()                     # E9
	_teardown_game_loop()
	# 汇总
	print("────────────────────────────────────────")
	print("汇总：PASS %d / FAIL %d（共 %d 项）" % [_pass, _fail, _pass + _fail])
	if not _failures.is_empty():
		for f in _failures:
			print("  FAIL 详情：%s" % f)


func fail_count() -> int:
	return _fail


# ── 环境引导（pkg10 夹具模式） ─────────────────────────────────────
func _ensure_autoloads() -> void:
	if EventBus == null or GameConfig == null or DebugStats == null:
		push_error("[pkg10_extra] autoload 未就绪（后续用例级联失败）")


func _boot_game_loop() -> void:
	_gl = GameLoop.new()
	_gl.name = "GameLoopUnderTestExtra"
	tree.get_root().add_child(_gl)
	if not (_gl.boot_ready and _gl.state == GameConst.GameStatus.MENU
			and _gl.meta_store != null and _gl.meta_panel != null):
		push_error("[pkg10_extra] Boot 异常（MENU/MetaStore/MetaPanel 未就绪，后续用例级联失败）")


func _teardown_game_loop() -> void:
	tree.paused = false
	# 收尾清残留（隔离纪律）：测试档 + E1 附加档 + 默认档全 wipe
	if _gl != null and _gl.meta_store != null:
		_gl.meta_store.wipe()
		_gl.meta_store.set_save_path(PATH_B)
		_gl.meta_store.wipe()
		_gl.meta_store.set_save_path(MetaStore.DEFAULT_SAVE_PATH)
		_gl.meta_store.wipe()
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


func _store() -> MetaStore:
	return _gl.meta_store


func _wipe() -> void:
	_gl.meta_store.wipe()


func _new_run() -> void:
	# 开新局夹具（pkg10 同款）：MENU → start_run；PLAYING → GAME_OVER（合法边）→ restart_run
	if _gl.state == GameConst.GameStatus.MENU:
		_gl.start_run()
		return
	if _gl.state != GameConst.GameStatus.GAME_OVER:
		_gl.change_state(GameConst.GameStatus.GAME_OVER)
	_gl.restart_run()


func _to_menu() -> void:
	# 回菜单夹具（pkg10 同款）：PLAYING → GAME_OVER（合法边）→ goto_menu（合法边）
	if _gl.state != GameConst.GameStatus.MENU:
		if _gl.state != GameConst.GameStatus.GAME_OVER:
			_gl.change_state(GameConst.GameStatus.GAME_OVER)
		_gl.goto_menu()


# ══ E1：set_save_path 复位语义 + 不自动加载 ═══════════════════════
func _test_e1_set_save_path_reset() -> void:
	print("── E1 set_save_path 复位语义 ──")
	# 预置：档 B 已有存档（crystal=88）；测试档写满内存态
	var cfg := ConfigFile.new()
	cfg.set_value("meta", "save_version", 1)
	cfg.set_value("meta", "crystal", 88)
	cfg.save(PATH_B)
	_wipe()
	var s := _store()
	s.crystal = 50
	s.total_runs = 3
	s._levels[&"hpg"] = 2
	# 切路径：内存复位全默认 + 不自动加载档 B 的 88 + 不产生写档
	s.set_save_path(PATH_B)
	var ok: bool = s.crystal == 0 and s.total_runs == 0 and s.level(&"hpg") == 0
	ok = ok and not FileAccess.file_exists(PATH_B) == false   # 档 B 仍在（复位不删文件）
	# 显式 load_save 才载入档 B
	s.load_save()
	ok = ok and s.crystal == 88
	# 清理：两档全擦
	s.wipe()
	s.set_save_path(TEST_PATH)
	s.wipe()
	_check("E1 set_save_path：切换即复位内存（50/3/hpg2→全 0）+ 不自动加载档 B（88 需显式 load）",
		ok, "crystal=%d" % s.crystal)


# ══ E2：再次出击再死再结转（二局累积） ════════════════════════════
func _test_e2_second_run_settle() -> void:
	print("── E2 二局结转 ──")
	_wipe()
	var ok: bool = _gl.start_run() and _gl.state == GameConst.GameStatus.PLAYING
	_gl._add_gold(30)
	_gl.hud.kills = 2
	_gl.hud.wave = 2
	_gl._on_player_died()
	ok = ok and _store().crystal == 30 and _store().total_runs == 1 \
		and _store().total_kills == 2 and _store().best_wave == 2 \
		and _gl.game_over_screen.crystal_text() == "结晶 +30"
	# 再次出击（GAME_OVER → restart_run → PLAYING；一次闸随局复位）→ 再死 → 再结转
	_new_run()
	ok = ok and _gl.state == GameConst.GameStatus.PLAYING and _gl.gold == 0
	_gl._add_gold(12)
	_gl.hud.kills = 5
	_gl.hud.wave = 4
	_gl._on_player_died()
	ok = ok and _store().crystal == 42 and _store().total_runs == 2 \
		and _store().total_kills == 7 and _store().best_wave == 4 \
		and _gl.game_over_screen.crystal_text() == "结晶 +12"
	_check("E2 二局结转：再出击再死 → crystal 30+12=42 / runs 2 / kills 2+5=7 累计 / best_wave 4 / 行回文本局 +12",
		ok, "crystal=%d runs=%d" % [_store().crystal, _store().total_runs])


# ══ E3：gold=0 正常路径结转 ═══════════════════════════════════════
func _test_e3_zero_gold_settle() -> void:
	print("── E3 零金结转 ──")
	_wipe()
	var ok: bool = _gl.start_run() and _gl.state == GameConst.GameStatus.PLAYING \
		and _gl.gold == 0
	_gl.hud.kills = 0
	_gl.hud.wave = 1
	_gl._on_player_died()
	ok = ok and _store().crystal == 0 and _store().total_runs == 1 \
		and _gl.game_over_screen.crystal_text() == "结晶 +0"
	_check("E3 零金结转（正常路径非降级）：gold=0 →「结晶 +0」+ crystal 不变 + runs 仍 +1", ok,
		"runs=%d" % _store().total_runs)


# ══ E4：greed 负增量不缩放 ═══════════════════════════════════════
func _test_e4_greed_negative() -> void:
	print("── E4 负增量 ──")
	_wipe()
	_store()._levels[&"seed_gold"] = 1
	_store()._levels[&"greed"] = 2
	_new_run()
	var ok: bool = _gl.gold == 25
	_gl._add_gold(-20)                            # 负增量：×1.1 缩放则为 -22 → 3；冻结语义为原样 -20 → 5
	ok = ok and _gl.gold == 5
	_check("E4 greed 负增量不缩放：seed 25 → _add_gold(-20) → 恰 5（非 3，负数消费不经 K_gold）", ok,
		"gold=%d" % _gl.gold)


# ══ E5：MetaPanel 满级/余额不足 disabled ══════════════════════════
func _test_e5_panel_disabled_states() -> void:
	print("── E5 面板禁用态 ──")
	_to_menu()
	_wipe()
	var s := _store()
	s.crystal = 0
	_gl._on_meta_requested()
	var btns: Array[Button] = _gl.meta_panel._row_buttons
	var ok: bool = _gl.meta_panel.is_open() and btns.size() == 5
	for b in btns:                                # 余额 0 < 全条目价 100 → 5 行全 disabled
		ok = ok and b.disabled
	s.crystal = 100
	_gl.meta_panel.refresh()                      # crystal==price=100 → 恰可购 → 5 行全 enabled
	for b in btns:
		ok = ok and not b.disabled
	s._levels[&"hpg"] = 5                         # 满级行：disabled + 「已满级」文案
	_gl.meta_panel.refresh()
	ok = ok and btns[0].disabled and String(btns[0].text).contains("已满级")
	for i in range(1, 5):
		ok = ok and not (btns[i] as Button).disabled
	s.crystal = 99                                # 余额不足：未满级行全 disabled
	_gl.meta_panel.refresh()
	for i in range(1, 5):
		ok = ok and (btns[i] as Button).disabled
	_gl.meta_panel.close()
	_check("E5 面板禁用态：0 结晶全 disabled / 恰 100 全可购 / hpg 满级行 disabled+已满级 / 99 结晶未满级行全 disabled",
		ok)


# ══ E6：结算屏结晶行与双按钮无交集 ═══════════════════════════════
func _test_e6_gameover_layout() -> void:
	print("── E6 结算屏布局 ──")
	_wipe()
	_gl.start_run()
	_gl._on_player_died()                         # 进 GAME_OVER（结算屏显示态）
	var root: Control = _gl.game_over_screen._root
	var buttons: Array[Control] = []
	for child in root.get_children():
		if child is Button:
			buttons.append(child)
	var ok: bool = buttons.size() == 2            # 「再次出击」+「返回选角」
	var crystal: Control = _gl.game_over_screen._crystal_label
	var crystal_rect := Rect2(crystal.position, crystal.size)
	for b in buttons:
		var btn_rect := Rect2(b.position, b.size)
		ok = ok and not crystal_rect.intersects(btn_rect)
		# 几何契约硬断言：结晶行 y 严格不低于任一按钮底边（y=624 > 612）
		ok = ok and crystal.position.y >= b.position.y + b.size.y - 0.001
	ok = ok and _gl.game_over_screen.crystal_text() == "结晶 +0"
	_check("E6 结算屏布局：双按钮恰 2 + 结晶行矩形与按钮两两无交集 + y 严格高于按钮底边", ok,
		"crystal_y=%.0f btn_bottom=%.0f" % [crystal.position.y,
		(buttons[0] as Control).position.y + (buttons[0] as Control).size.y])


# ══ E7：存档键布局契约逐节 diff ══════════════════════════════════
func _test_e7_save_key_layout() -> void:
	print("── E7 存档键布局 ──")
	_wipe()
	var s := _store()
	s.crystal = 7
	s.total_runs = 2
	s.total_kills = 9
	s.best_wave = 5
	s._levels[&"hpg"] = 1
	s._levels[&"greed"] = 3
	s._levels[&"xp"] = 2
	s.save()
	var cfg := ConfigFile.new()
	var ok: bool = cfg.load(TEST_PATH) == OK
	var meta_keys: Array = Array(cfg.get_section_keys("meta"))
	meta_keys.sort()
	ok = ok and meta_keys == ["crystal", "save_version"]
	var level_keys: Array = Array(cfg.get_section_keys("levels"))
	level_keys.sort()
	ok = ok and level_keys == ["atk", "greed", "hpg", "seed_gold", "xp"]
	var stat_keys: Array = Array(cfg.get_section_keys("stats"))
	stat_keys.sort()
	ok = ok and stat_keys == ["best_wave", "total_kills", "total_runs"]
	ok = ok and cfg.get_sections().size() == 3    # 恰三节，无多余节
	ok = ok and int(cfg.get_value("meta", "save_version", -1)) == 1 \
		and int(cfg.get_value("meta", "crystal", -1)) == 7 \
		and int(cfg.get_value("levels", "hpg", -1)) == 1 \
		and int(cfg.get_value("levels", "greed", -1)) == 3 \
		and int(cfg.get_value("levels", "xp", -1)) == 2 \
		and int(cfg.get_value("levels", "atk", -1)) == 0 \
		and int(cfg.get_value("levels", "seed_gold", -1)) == 0 \
		and int(cfg.get_value("stats", "total_runs", -1)) == 2 \
		and int(cfg.get_value("stats", "total_kills", -1)) == 9 \
		and int(cfg.get_value("stats", "best_wave", -1)) == 5
	_check("E7 存档键布局契约：[meta] 恰 2 键 / [levels] 恰 5 键（封闭表）/ [stats] 恰 3 键 / 恰 3 节 / 值逐项对账",
		ok, str(cfg.get_sections()))


# ══ E8：定价独立复算（逐级迭代 vs pow 一次算） ═══════════════════
func _test_e8_price_recalc() -> void:
	print("── E8 定价复算 ──")
	_wipe()
	var s := _store()
	# 独立重算：p0=100；p(n+1)=round(p(n)×1.6)——与 store.price 逐级对照
	var p := 100
	var ok: bool = s.price(&"hpg") == p and s.price(&"seed_gold") == p   # Lv0 基价双双 100
	for lv in range(1, 5):
		p = int(round(float(p) * 1.6))
		s._levels[&"hpg"] = lv
		ok = ok and s.price(&"hpg") == p          # 100→160→256→410→656 逐级一致
	# pow 一次算钉死：round(100×1.6^4)=655 ≠ 冻结 656（实现必须是逐级迭代）
	var pow_val := int(round(100.0 * pow(1.6, 4)))
	ok = ok and pow_val == 655 and s.price(&"hpg") == 656
	# seed_gold 满 3 级封顶（Lv1/2 已在 pkg10 M6；此处补 Lv0 与封闭性）
	s._levels[&"seed_gold"] = 3
	ok = ok and s.price(&"seed_gold") == -1 and s.is_maxed(&"seed_gold")
	_check("E8 定价独立复算：逐级 round 序列 100/160/256/410/656 与 store 一致 + pow 一次算=655 钉死非 pow + seed_gold Lv0=100",
		ok, "pow=%d store=%d" % [pow_val, s.price(&"hpg")])


# ══ E9：max_hp 公式真源手算（static 直调） ════════════════════════
func _test_e9_max_hp_formula() -> void:
	print("── E9 公式真源 ──")
	# 冻结公式：maxf((base×(1+char_pct) + chip_sum + flat + meta_flat) × (1−0.04n), 1.0)
	# M14 场景手算走静态真源直证：(100×1.0 + 0 + 10(商店) + 10(meta hpg2) ) × (1−0) = 120
	var mixed: float = Player.compute_max_hp(0.0, 0.0, 10.0, 0, 10.0)
	var ok: bool = is_equal_approx(mixed, 120.0)
	# 恒等锚（默认第 5 参）：(100+0+0+0)×1 = 100
	ok = ok and is_equal_approx(Player.compute_max_hp(0.0, 0.0, 0.0, 0), 100.0)
	# 诅咒交互：同上 ×(1−0.04×2)=0.92 → 110.4
	ok = ok and is_equal_approx(Player.compute_max_hp(0.0, 0.0, 10.0, 2, 10.0), 110.4)
	# meta flat 单独通道：meta 10 无商店 flat → 110
	ok = ok and is_equal_approx(Player.compute_max_hp(0.0, 0.0, 0.0, 0, 10.0), 110.0)
	_check("E9 公式真源手算：(100+0+10+10)×1=120；恒等锚 100；×0.92→110.4；meta 单独 110", ok,
		"mixed=%s" % str(mixed))
