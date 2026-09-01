# tests/runner/pkg10_cases.gd
# v1.0.0 自测用例体（由 test_pkg10.gd 入口在 autoload 就绪后运行时加载编译）。
# 覆盖冻结方案 pkg10 用例组 M1~M24（A9_v1.0.0_design.md；每恰 1 断言——pkg10 24 项口径）。
# 隔离纪律：runner 引导后第一件事 set_save_path(测试档) + wipe()；每组前置 wipe；
# 收尾 wipe → set_save_path(DEFAULT) → wipe 清残留。
# 确定性：全 0 级恒等锚（M23）与 xp 基线（M18/M23 fixed-seed 同源）；默认选角 CHAR_COURIER
#（id 字典序首，max_hp_pct=0 / xp_mult=1.0——手算锚不受角色乘区干扰）。
extends RefCounted

const TEST_PATH := "user://pkg10_meta_test.cfg"

var tree: SceneTree
var _pass: int = 0
var _fail: int = 0
var _failures: Array[String] = []
var _gl: GameLoop = null                         # 共享 GameLoop（Boot 一次）
var _xp_baseline: float = -1.0                   # M18 捕获的全 0 级 xp 基线（M23 复测对照）


func run(p_tree: SceneTree) -> void:
	tree = p_tree
	seed(42)
	_ensure_autoloads()
	_boot_game_loop()
	# ★ 隔离纪律：runner 引导后第一件事——切测试档路径 + 清残留
	_gl.meta_store.set_save_path(TEST_PATH)
	_gl.meta_store.wipe()
	_test_m1_roundtrip()                          # M1
	_test_m2_corrupt_file()                       # M2
	_test_m3_version_99()                         # M3
	_test_m4_missing_keys()                       # M4
	_test_m5_out_of_range()                       # M5
	_test_m6_price_sequence()                     # M6
	_test_m7_purchase_ok()                        # M7
	_test_m8_purchase_reject()                    # M8
	_test_m9_wipe()                               # M9
	_test_m10_save_failure()                      # M10
	_test_m11_settle()                            # M11
	_test_m12_best_wave()                         # M12
	_test_m13_hpg_inject()                        # M13
	_test_m14_hpg_flat_keep()                     # M14
	_test_m15_atk_inject()                        # M15
	_test_m16_greed_merge()                       # M16
	_test_m17_seed_gold()                         # M17
	_test_m18_xp_factor()                         # M18
	_test_m19_meta_survive()                      # M19
	_test_m20_panel_open_close()                  # M20
	_test_m21_purchase_arbitration()              # M21
	_test_m22_layout_contract()                   # M22
	_test_m23_zero_anchor()                       # M23
	_test_m24_settle_degraded()                   # M24
	_teardown_game_loop()
	# 汇总
	print("────────────────────────────────────────")
	print("汇总：PASS %d / FAIL %d（共 %d 项）" % [_pass, _fail, _pass + _fail])
	if not _failures.is_empty():
		for f in _failures:
			print("  FAIL 详情：%s" % f)


func fail_count() -> int:
	return _fail


# ── 环境引导（pkg9 夹具模式；不占断言名额——pkg10 恰 24 项口径，boot 异常经 M1 级联可见） ──
func _ensure_autoloads() -> void:
	if EventBus == null or GameConfig == null or DebugStats == null:
		push_error("[pkg10] autoload 未就绪（后续用例级联失败）")


func _boot_game_loop() -> void:
	_gl = GameLoop.new()
	_gl.name = "GameLoopUnderTest"
	tree.get_root().add_child(_gl)
	if not (_gl.boot_ready and _gl.state == GameConst.GameStatus.MENU
			and _gl.meta_store != null and _gl.meta_panel != null):
		push_error("[pkg10] Boot 异常（MENU/MetaStore/MetaPanel 未就绪，后续用例级联失败）")


func _teardown_game_loop() -> void:
	tree.paused = false
	# 收尾清残留（隔离纪律）：wipe → 恢复默认路径 → wipe
	if _gl != null and _gl.meta_store != null:
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
	# 开新局夹具：MENU → start_run；PLAYING → GAME_OVER（合法边，不走死亡结算）→ restart_run
	if _gl.state == GameConst.GameStatus.MENU:
		_gl.start_run()
		return
	if _gl.state != GameConst.GameStatus.GAME_OVER:
		_gl.change_state(GameConst.GameStatus.GAME_OVER)
	_gl.restart_run()


func _to_menu() -> void:
	# 回菜单夹具：PLAYING → GAME_OVER（合法边）→ goto_menu（合法边）
	if _gl.state != GameConst.GameStatus.MENU:
		if _gl.state != GameConst.GameStatus.GAME_OVER:
			_gl.change_state(GameConst.GameStatus.GAME_OVER)
		_gl.goto_menu()


func _drop_xp_shard(p_exp_value: float) -> float:
	# xp 掉落夹具（pkg5:365 同款直调口）：裸 Enemy 直构设 exp_value → 掉落 → 返回末位碎片面值
	var enemy := Enemy.new()
	enemy.exp_value = p_exp_value
	var before := _gl.active_shards.size()
	_gl._on_enemy_killed_drop_xp(enemy)
	enemy.free()
	if _gl.active_shards.size() != before + 1:
		return -1.0                               # 掉落失败哨兵
	return float((_gl.active_shards[_gl.active_shards.size() - 1] as XpShard).value)


# ══ M1：存档往返恒等 ══════════════════════════════════════════════
func _test_m1_roundtrip() -> void:
	print("── M1 往返恒等 ──")
	_wipe()
	var s := _store()
	s.crystal = 77
	s.total_runs = 3
	s.total_kills = 123
	s.best_wave = 9
	s._levels[&"hpg"] = 2
	s._levels[&"seed_gold"] = 1
	var saved: bool = s.save()
	var store2 := MetaStore.new()
	store2.set_save_path(TEST_PATH)
	store2.load_save()
	var same: bool = saved and store2.crystal == 77 and store2.total_runs == 3 \
		and store2.total_kills == 123 and store2.best_wave == 9 \
		and store2.level(&"hpg") == 2 and store2.level(&"atk") == 0 \
		and store2.level(&"greed") == 0 and store2.level(&"seed_gold") == 1 \
		and store2.level(&"xp") == 0
	store2.free()
	_check("M1 往返恒等：置值→save→新实例 set_path+load 逐字段相等", same)


# ══ M2：损坏文件 ══════════════════════════════════════════════════
func _test_m2_corrupt_file() -> void:
	print("── M2 损坏文件 ──")
	_wipe()
	var f := FileAccess.open(TEST_PATH, FileAccess.WRITE)
	f.store_64(0x1122334455667788)
	f.store_string("{{{ this is not a config !!!")
	f = null
	_store().load_save()
	var ok: bool = _store().crystal == 0 and _store().total_runs == 0 \
		and _store().total_kills == 0 and _store().best_wave == 0 \
		and _store().level(&"hpg") == 0 and _store().level(&"xp") == 0
	_check("M2 损坏文件（乱码字节）→ 全默认不崩溃", ok)


# ══ M3：save_version=99 拒降读 ════════════════════════════════════
func _test_m3_version_99() -> void:
	print("── M3 高版本档 ──")
	_wipe()
	var cfg := ConfigFile.new()
	cfg.set_value("meta", "save_version", 99)
	cfg.set_value("meta", "crystal", 999)
	cfg.set_value("levels", "hpg", 4)
	cfg.save(TEST_PATH)
	_store().load_save()
	var ok: bool = _store().crystal == 0 and _store().level(&"hpg") == 0 \
		and _store().total_runs == 0
	_check("M3 save_version=99 → 全默认不降读", ok)


# ══ M4：缺键 ══════════════════════════════════════════════════════
func _test_m4_missing_keys() -> void:
	print("── M4 缺键 ──")
	_wipe()
	var cfg := ConfigFile.new()
	cfg.set_value("meta", "save_version", 1)
	cfg.set_value("meta", "crystal", 5)
	cfg.save(TEST_PATH)
	_store().load_save()
	var ok: bool = _store().crystal == 5 \
		and _store().level(&"hpg") == 0 and _store().level(&"atk") == 0 \
		and _store().level(&"greed") == 0 and _store().level(&"seed_gold") == 0 \
		and _store().level(&"xp") == 0 \
		and _store().total_runs == 0 and _store().total_kills == 0 \
		and _store().best_wave == 0
	_check("M4 缺键（无 levels/stats 段）→ crystal 保留 + levels/stats 全 0", ok)


# ══ M5：越界钳制 ══════════════════════════════════════════════════
func _test_m5_out_of_range() -> void:
	print("── M5 越界钳制 ──")
	_wipe()
	var cfg := ConfigFile.new()
	cfg.set_value("meta", "save_version", 1)
	cfg.set_value("meta", "crystal", -5)
	cfg.set_value("levels", "hpg", 99)
	cfg.set_value("levels", "seed_gold", -2)
	cfg.save(TEST_PATH)
	_store().load_save()
	var ok: bool = _store().level(&"hpg") == 5 and _store().level(&"seed_gold") == 0 \
		and _store().crystal == 0
	_check("M5 越界钳制：hpg=99→5、seed_gold=-2→0、crystal=-5→0", ok)


# ══ M6：定价序列（逐级迭代冻结） ══════════════════════════════════
func _test_m6_price_sequence() -> void:
	print("── M6 定价序列 ──")
	_wipe()
	var s := _store()
	var ok: bool = s.price(&"hpg") == 100
	s._levels[&"hpg"] = 1
	ok = ok and s.price(&"hpg") == 160
	s._levels[&"hpg"] = 2
	ok = ok and s.price(&"hpg") == 256
	s._levels[&"hpg"] = 3
	ok = ok and s.price(&"hpg") == 410
	s._levels[&"hpg"] = 4
	ok = ok and s.price(&"hpg") == 656
	s._levels[&"hpg"] = 5
	ok = ok and s.price(&"hpg") == -1 and s.is_maxed(&"hpg")
	s._levels[&"seed_gold"] = 1
	ok = ok and s.price(&"seed_gold") == 160
	s._levels[&"seed_gold"] = 2
	ok = ok and s.price(&"seed_gold") == 256
	s._levels[&"seed_gold"] = 3
	ok = ok and s.price(&"seed_gold") == -1 and s.is_maxed(&"seed_gold")
	_check("M6 定价：hpg 100/160/256/410/656 + seed_gold 100/160/256 + 满级 -1/is_maxed", ok,
		"hpg@4=%d seed@2=%d" % [s.price(&"hpg"), s.price(&"seed_gold")])


# ══ M7：purchase 成功 ═════════════════════════════════════════════
func _test_m7_purchase_ok() -> void:
	print("── M7 购买成功 ──")
	_wipe()
	var s := _store()
	s.add_crystal(100)
	var ok: bool = s.purchase(&"hpg")
	ok = ok and s.level(&"hpg") == 1 and s.crystal == 0 \
		and FileAccess.file_exists(TEST_PATH)
	_check("M7 purchase：crystal=100 买 hpg → true / Lv1 / 扣至 0 / 文件落盘", ok)


# ══ M8：拒绝三态（不扣款） ════════════════════════════════════════
func _test_m8_purchase_reject() -> void:
	print("── M8 拒绝三态 ──")
	_wipe()
	var s := _store()
	s.add_crystal(99)
	var ok: bool = not s.purchase(&"hpg") and s.crystal == 99 and s.level(&"hpg") == 0
	s._levels[&"atk"] = 5
	ok = ok and not s.purchase(&"atk") and s.crystal == 99
	var before := s.crystal
	ok = ok and not s.purchase(&"nope") and s.crystal == before
	_check("M8 拒绝三态（余额不足/满级/未知 id）均 false 且不扣款", ok)


# ══ M9：wipe ══════════════════════════════════════════════════════
func _test_m9_wipe() -> void:
	print("── M9 wipe ──")
	_wipe()
	var s := _store()
	s.add_crystal(50)
	s.record_run(1, 2)
	s.save()
	var ok: bool = FileAccess.file_exists(TEST_PATH)
	s.wipe()
	ok = ok and not FileAccess.file_exists(TEST_PATH) and s.crystal == 0 \
		and s.total_runs == 0 and s.best_wave == 0
	_check("M9 wipe：文件不存在反证 + 内存全默认", ok)


# ══ M10：写失败内存保留 ═══════════════════════════════════════════
func _test_m10_save_failure() -> void:
	print("── M10 写失败 ──")
	_wipe()
	_store().set_save_path("user://pkg10_no_such_dir_xyz/meta.cfg")   # 不存在目录
	_store().add_crystal(50)
	var ok: bool = not _store().save() and _store().crystal == 50
	_store().set_save_path(TEST_PATH)             # 恢复（set_save_path 自带内存复位）
	_wipe()
	_check("M10 写失败（不存在目录）→ save false + 内存态保留", ok)


# ══ M11：死亡结转（一次闸） ═══════════════════════════════════════
func _test_m11_settle() -> void:
	print("── M11 结转 ──")
	_wipe()
	var ok: bool = _gl.start_run() and _gl.state == GameConst.GameStatus.PLAYING
	_gl._add_gold(45)                             # greed 0（wipe 过）→ gold == 45
	_gl.hud.kills = 7
	_gl.hud.wave = 3
	_gl._on_player_died()
	ok = ok and _gl.state == GameConst.GameStatus.GAME_OVER
	ok = ok and _store().crystal == 45 and _store().total_runs == 1 \
		and _store().total_kills == 7 and _store().best_wave == 3
	ok = ok and _gl.game_over_screen.crystal_text() == "结晶 +45"
	ok = ok and _gl.game_over_screen.summary_text().contains("击杀")
	_gl._on_player_died()                         # 再调：状态守卫 + 一次闸双保险
	ok = ok and _store().crystal == 45 and _store().total_runs == 1
	_check("M11 结转：crystal 增量==gold + 结算行「结晶 +45」+ 战绩入档 + 重入不重复", ok)


# ══ M12：best_wave 不回退 ═════════════════════════════════════════
func _test_m12_best_wave() -> void:
	print("── M12 best_wave ──")
	_wipe()
	var s := _store()
	s.record_run(0, 10)
	var ok: bool = s.best_wave == 10
	s.record_run(0, 4)
	ok = ok and s.best_wave == 10
	s.record_run(0, 25)
	ok = ok and s.best_wave == 25
	_check("M12 best_wave 单调不回退（10 → 4 保持 → 25 抬升）", ok)


# ══ M13：hpg 注入（手算锚） ═══════════════════════════════════════
func _test_m13_hpg_inject() -> void:
	print("── M13 hpg 注入 ──")
	_wipe()
	_store()._levels[&"hpg"] = 2
	_new_run()
	var ok: bool = is_equal_approx(float(_gl.player.get("max_hp")), 110.0)
	_wipe()
	_new_run()
	ok = ok and is_equal_approx(float(_gl.player.get("max_hp")), 100.0)
	_check("M13 hpg 注入：2 级 → max_hp 110（100+5×2 手算）；0 级 → 100 恒等锚", ok,
		"max_hp=%s" % str(_gl.player.get("max_hp")))


# ══ M14：meta flat 与商店 flat 共存 ═══════════════════════════════
func _test_m14_hpg_flat_keep() -> void:
	print("── M14 meta flat 保持 ──")
	_wipe()
	_store()._levels[&"hpg"] = 2
	_new_run()
	var ok: bool = is_equal_approx(float(_gl.player.get("max_hp")), 110.0)
	_gl.player.max_hp_bonus_flat += 10.0          # 商店式 maxhp flat（同池共存）
	_gl.curse_handler.recompute_max_hp()
	ok = ok and is_equal_approx(float(_gl.player.get("max_hp")), 120.0)
	_check("M14 meta flat 保持：hpg=2 + max_hp_bonus_flat+=10 + recompute → 120", ok,
		"max_hp=%s" % str(_gl.player.get("max_hp")))


# ══ M15：atk 注入 ═════════════════════════════════════════════════
func _test_m15_atk_inject() -> void:
	print("── M15 atk 注入 ──")
	_wipe()
	_store()._levels[&"atk"] = 1
	_new_run()
	var ok: bool = is_equal_approx(_gl.chip_handler.stat_bonus(&"atk_pct"), 0.03)
	_wipe()
	_new_run()
	ok = ok and is_equal_approx(_gl.chip_handler.stat_bonus(&"atk_pct"), 0.0)
	_check("M15 atk 注入：1 级 → stat_bonus(atk_pct)==0.03；0 级 → 0.0", ok)


# ══ M16：greed 合并段 ═════════════════════════════════════════════
func _test_m16_greed_merge() -> void:
	print("── M16 greed 合并段 ──")
	_wipe()
	_store()._levels[&"greed"] = 2
	_new_run()
	_gl._add_gold(100)
	var ok: bool = _gl.gold == 110                # 100 × (1+0.05×2) = 110
	_check("M16 greed 合并段：greed=2 → _add_gold(100) → gold==110（meta 段并入 K_gold 通道）", ok,
		"gold=%d" % _gl.gold)


# ══ M17：开局金不被放大 ═══════════════════════════════════════════
func _test_m17_seed_gold() -> void:
	print("── M17 开局金 ──")
	_wipe()
	_store()._levels[&"seed_gold"] = 1
	_store()._levels[&"greed"] = 2
	_new_run()
	var ok: bool = _gl.gold == 25                 # 25，非 27（greed 不放大开局金）
	_store()._levels[&"seed_gold"] = 2
	_new_run()
	ok = ok and _gl.gold == 50
	_wipe()
	_new_run()
	ok = ok and _gl.gold == 0
	_check("M17 开局金：seed=1+greed=2 → 25（直注入不放大）；seed=2 → 50；全 0 → 0", ok,
		"gold=%d" % _gl.gold)


# ══ M18：xp 第 4 因子（fixed-seed 同源基线） ═══════════════════════
func _test_m18_xp_factor() -> void:
	print("── M18 xp 因子 ──")
	_wipe()
	_new_run()
	_xp_baseline = _drop_xp_shard(10.0)           # 全 0 级基线（同种子同源）
	_store()._levels[&"xp"] = 1
	_new_run()
	var v1 := _drop_xp_shard(10.0)
	var ok: bool = is_equal_approx(v1, _xp_baseline * 1.05)
	_wipe()
	_new_run()
	ok = ok and is_equal_approx(_drop_xp_shard(10.0), _xp_baseline)
	_check("M18 xp 因子：1 级 → 碎片面值==基线×1.05（fixed-seed）；0 级==基线", ok,
		"base=%s v1=%s" % [str(_xp_baseline), str(v1)])


# ══ M19：meta 跨局存活 ════════════════════════════════════════════
func _test_m19_meta_survive() -> void:
	print("── M19 跨局存活 ──")
	_wipe()
	_store()._levels[&"atk"] = 2
	_store().save()
	_store().load_save()                          # 从盘载入
	_new_run()
	var snap: Dictionary = _store().meta_stats_snapshot()
	var ok: bool = is_equal_approx(_gl.chip_handler.stat_bonus(&"atk_pct"),
		float(snap.get(&"atk_pct", -1.0))) \
		and is_equal_approx(_gl.chip_handler.stat_bonus(&"atk_pct"), 0.06)
	_check("M19 跨局存活：载入后 restart_run → stat_bonus 仍含 meta == store 快照（0.06）", ok)


# ══ M20：面板开闭 ═════════════════════════════════════════════════
func _test_m20_panel_open_close() -> void:
	print("── M20 面板开闭 ──")
	_wipe()
	_to_menu()
	var ok: bool = _gl.state == GameConst.GameStatus.MENU and not _gl.meta_panel.is_open()
	_gl._on_meta_requested()
	ok = ok and _gl.meta_panel.is_open()
	_gl.menu_screen.start_requested.emit()        # 开局 → state_changed(PLAYING) → 强制收起
	ok = ok and _gl.state == GameConst.GameStatus.PLAYING and not _gl.meta_panel.is_open()
	_check("M20 面板开闭：入口开 → is_open；start_requested → PLAYING 且面板自动关", ok)


# ══ M21：购买仲裁 ═════════════════════════════════════════════════
func _test_m21_purchase_arbitration() -> void:
	print("── M21 购买仲裁 ──")
	_to_menu()
	_wipe()
	_store().add_crystal(200)
	_gl._on_meta_requested()
	var ok: bool = _gl.meta_panel.is_open()
	_gl._on_meta_purchase(&"hpg")                 # 面板开 + MENU → 成功
	ok = ok and _store().level(&"hpg") == 1 and _store().crystal == 100
	ok = ok and String(_gl.meta_panel._balance_label.text).contains("100")   # 刷新回写
	_gl.meta_panel.close()                        # 面板关
	var before := _store().crystal
	_gl._on_meta_purchase(&"atk")                 # 面板关直调 → 拒绝
	ok = ok and _store().level(&"atk") == 0 and _store().crystal == before
	_check("M21 购买仲裁：面板开+MENU 购买成功并刷新；面板关直调拒绝不扣款", ok)


# ══ M22：布局契约 ═════════════════════════════════════════════════
func _test_m22_layout_contract() -> void:
	print("── M22 布局契约 ──")
	var rects := _gl.meta_panel.layout_rects()
	var ok: bool = rects.size() == 6
	for i in range(rects.size()):
		for j in range(i + 1, rects.size()):
			if (rects[i] as Rect2).intersects(rects[j] as Rect2):
				ok = false
	var stats_text: String = String(_gl.menu_screen._stats_label.text)
	ok = ok and stats_text.contains("最佳波次") and stats_text.contains("总局数") \
		and stats_text.contains("累计击杀") and stats_text.contains("结晶")
	_check("M22 布局：layout_rects 6 项两两无交集；菜单统计行文本含四段", ok, stats_text)


# ══ M23：全 0 级与 v0.9.0 恒等锚 ══════════════════════════════════
func _test_m23_zero_anchor() -> void:
	print("── M23 全 0 级恒等锚 ──")
	_wipe()
	_new_run()
	var ok: bool = is_equal_approx(float(_gl.player.get("max_hp")), 100.0)
	_gl._add_gold(100)
	ok = ok and _gl.gold == 100                   # 无缩放（K_gold=0）
	ok = ok and is_equal_approx(_gl.chip_handler.stat_bonus(&"gold_gain"), 0.0) \
		and is_equal_approx(_gl.chip_handler.stat_bonus(&"atk_pct"), 0.0)
	var snap: Dictionary = _store().meta_stats_snapshot()
	ok = ok and is_equal_approx(float(snap.get(&"atk_pct", 1.0)), 0.0) \
		and is_equal_approx(float(snap.get(&"gold_gain", 1.0)), 0.0)
	ok = ok and is_equal_approx(_gl.meta_store.xp_mult(), 1.0) \
		and is_equal_approx(_gl.meta_store.meta_hp_flat(), 0.0) \
		and _gl.meta_store.starting_gold() == 0
	ok = ok and is_equal_approx(_drop_xp_shard(10.0), _xp_baseline)   # xp 基线（fixed-seed）
	_check("M23 全 0 级恒等锚：max_hp 100 / _add_gold 无缩放 / 快照 0.0 / xp 基线与 v0.9.0 行为一致",
		ok)


# ══ M24：settle 降级 ══════════════════════════════════════════════
func _test_m24_settle_degraded() -> void:
	print("── M24 settle 降级 ──")
	var saved_store: MetaStore = _gl.meta_store
	_gl.meta_store = null                         # 临时置 null（降级路径）
	_gl._on_player_died()
	var ok: bool = _gl.state == GameConst.GameStatus.GAME_OVER \
		and _gl.game_over_screen.crystal_text() == "结晶 +0"
	_gl.meta_store = saved_store
	_check("M24 settle 降级：meta_store 置 null → 死亡不崩溃且 crystal_text==「结晶 +0」", ok)
