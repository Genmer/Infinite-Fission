# tests/runner/pkg14_cases.gd
# v1.4.0 自测用例体（由 test_pkg14.gd 入口在 autoload 就绪后运行时加载编译）。
# 覆盖冻结方案 pkg14 用例组 C1~C24（A13_v1.4.0_design.md §7；每恰 1 断言）。
# 隔离纪律（pkg10 同款）：standalone MetaStore 一律 set_save_path(测试档) + 构造即 wipe；
# 每用例独立 store（首见判定互不污染）；收尾仅清测试档（不触碰默认档/真机存档）。
# 夹具分段：C1~C8 standalone MetaStore → C9~C24（后续步骤补齐：微夹具/GameLoop boot）。
extends RefCounted

const TEST_PATH := "user://pkg14_meta_test.cfg"

var tree: SceneTree
var _pass: int = 0
var _fail: int = 0
var _failures: Array[String] = []
var _stores: Array[MetaStore] = []               # 用例独立 store（收尾统一 free）


func run(p_tree: SceneTree) -> void:
	tree = p_tree
	seed(42)
	_ensure_autoloads()
	_test_c1_chip_mark()                          # C1
	_test_c2_relic_mark()                         # C2
	_test_c3_reaction_mark()                      # C3
	_test_c4_unlock_idempotent()                  # C4
	_test_c5_convert_gold()                       # C5
	_test_c6_legacy_missing_sections()            # C6
	_test_c7_dirty_keys()                         # C7
	_test_c8_wipe_clears()                        # C8
	_teardown()
	_summary()


func fail_count() -> int:
	return _fail


# ── 支撑 ──────────────────────────────────────────────────────────
func _check(p_desc: String, p_cond: bool, p_detail: String = "") -> void:
	if p_cond:
		_pass += 1
		print("  PASS %s" % p_desc)
	else:
		_fail += 1
		_failures.append("%s %s" % [p_desc, p_detail])
		print("  FAIL %s %s" % [p_desc, p_detail])


func _summary() -> void:
	print("────────────────────────────────────────")
	print("汇总：PASS %d / FAIL %d（共 %d 项）" % [_pass, _fail, _pass + _fail])
	if not _failures.is_empty():
		for f in _failures:
			print("  FAIL 详情：%s" % f)
	print("════════════════════════════════════════")


func _ensure_autoloads() -> void:
	if EventBus == null or GameConfig == null or DebugStats == null:
		push_error("[pkg14] autoload 未就绪（后续用例级联失败）")


func _new_store() -> MetaStore:
	# 用例独立 store：测试档路径 + 构造即 wipe（首见判定从零开始）
	var s := MetaStore.new()
	s.name = "Pkg14Store%d" % _stores.size()
	tree.get_root().add_child(s)
	s.set_save_path(TEST_PATH)
	s.wipe()
	_stores.append(s)
	return s


func _reload_store() -> MetaStore:
	# 即存反证：同路径新实例显式 load_save（不 wipe）
	var s := MetaStore.new()
	s.name = "Pkg14Reload%d" % _stores.size()
	tree.get_root().add_child(s)
	s.set_save_path(TEST_PATH)
	s.load_save()
	_stores.append(s)
	return s


func _teardown() -> void:
	# 隔离纪律收尾：仅清本 runner 注入的测试档（不触碰默认档——headless 产品侧走
	# meta_save_headless.cfg，真机真实存档零风险）
	for s in _stores:
		if is_instance_valid(s):
			s.wipe()
			s.free()
	_stores.clear()
	var cfg := ConfigFile.new()
	if cfg.load(TEST_PATH) == OK:
		DirAccess.remove_absolute(ProjectSettings.globalize_path(TEST_PATH))


func _read_source(p_path: String) -> String:
	var f := FileAccess.open(p_path, FileAccess.READ)
	if f == null:
		return ""
	return f.get_as_text()


# ══ C1：芯片图鉴 mark（首见/重复/空 id/即存） ═══════════════════════
func _test_c1_chip_mark() -> void:
	print("── C1 芯片 mark ──")
	var s := _new_store()
	var first := s.mark_chip_seen(&"CHIP_ATK")
	var repeat := s.mark_chip_seen(&"CHIP_ATK")
	var empty := s.mark_chip_seen(&"")
	var persisted := _reload_store().chip_seen(&"CHIP_ATK")
	_check("C1 芯片 mark：首见 true / 重复 false / 空 id false / 即存（reload 反证 true）",
		first and not repeat and not empty and persisted,
		"first=%s repeat=%s empty=%s persisted=%s" % [str(first), str(repeat), str(empty),
			str(persisted)])


# ══ C2：遗物图鉴 mark（首见/重复/即存） ═════════════════════════════
func _test_c2_relic_mark() -> void:
	print("── C2 遗物 mark ──")
	var s := _new_store()
	var first := s.mark_relic_seen(&"REL_MIDAS")
	var repeat := s.mark_relic_seen(&"REL_MIDAS")
	var empty := s.mark_relic_seen(&"")
	var persisted := _reload_store().relic_seen(&"REL_MIDAS")
	_check("C2 遗物 mark：首见 true / 重复 false / 空 id false / 即存（reload 反证 true）",
		first and not repeat and not empty and persisted,
		"first=%s repeat=%s empty=%s persisted=%s" % [str(first), str(repeat), str(empty),
			str(persisted)])


# ══ C3：反应图鉴 mark（三组代表键 + 未知 id 拒绝） ═══════════════════
func _test_c3_reaction_mark() -> void:
	print("── C3 反应 mark ──")
	var s := _new_store()
	var rxn := s.mark_reaction_seen("rxn_fir_ice")
	var amp := s.mark_reaction_seen("amp_melt")
	var res := s.mark_reaction_seen("res_fire")
	var repeat := s.mark_reaction_seen("amp_melt")
	var unknown := s.mark_reaction_seen("rxn_bogus")
	var persisted := _reload_store()
	var ok := rxn and amp and res and not repeat and not unknown \
		and persisted.reaction_seen("rxn_fir_ice") and persisted.reaction_seen("amp_melt") \
		and persisted.reaction_seen("res_fire") and not persisted.reaction_seen("rxn_bogus")
	_check("C3 反应 mark：剧变/增幅/共鸣三键首见 true / 重复 false / 未知 id false（warning）"
		+ " / 即存（reload 反证）", ok,
		"rxn=%s amp=%s res=%s repeat=%s unknown=%s" % [str(rxn), str(amp), str(res),
			str(repeat), str(unknown)])


# ══ C4：成就 unlock（首解/幂等/未知 id） ═════════════════════════════
func _test_c4_unlock_idempotent() -> void:
	print("── C4 unlock 幂等 ──")
	var s := _new_store()
	var first := s.unlock_achievement(&"ach_boss1")
	var has := s.has_achievement(&"ach_boss1")
	var repeat := s.unlock_achievement(&"ach_boss1")
	var unknown := s.unlock_achievement(&"ach_nope")
	var persisted := _reload_store().has_achievement(&"ach_boss1")
	_check("C4 unlock 幂等：首解 true / has true / 重复 no-op false / 未知 id false（warning）"
		+ " / 即存（reload 反证 true）",
		first and has and not repeat and not unknown and persisted,
		"first=%s has=%s repeat=%s unknown=%s persisted=%s" % [str(first), str(has),
			str(repeat), str(unknown), str(persisted)])


# ══ C5：convert_gold 软上限（七值锚） ════════════════════════════════
func _test_c5_convert_gold() -> void:
	print("── C5 convert_gold ──")
	var ok := MetaStore.convert_gold(-1) == 0 \
		and MetaStore.convert_gold(0) == 0 \
		and MetaStore.convert_gold(250) == 250 \
		and MetaStore.convert_gold(500) == 500 \
		and MetaStore.convert_gold(501) == 500 \
		and MetaStore.convert_gold(600) == 550 \
		and MetaStore.convert_gold(1000) == 750
	_check("C5 convert_gold 七值：-1→0 / 0→0 / 250→250 / 500→500 / 501→500 / 600→550 / 1000→750", ok,
		"vals=%d,%d,%d,%d,%d,%d,%d" % [MetaStore.convert_gold(-1), MetaStore.convert_gold(0),
			MetaStore.convert_gold(250), MetaStore.convert_gold(500), MetaStore.convert_gold(501),
			MetaStore.convert_gold(600), MetaStore.convert_gold(1000)])


# ══ C6：旧档缺节容忍（v1.3.0 档零迁移） ═════════════════════════════
func _test_c6_legacy_missing_sections() -> void:
	print("── C6 旧档缺节 ──")
	var s := _new_store()                         # 先建 store（构造即 wipe）再写旧形档
	var cfg := ConfigFile.new()
	cfg.set_value("meta", "save_version", 1)
	cfg.set_value("meta", "crystal", 7)
	cfg.set_value("levels", "atk", 2)
	cfg.set_value("levels", "hpg", 0)
	cfg.set_value("levels", "greed", 0)
	cfg.set_value("levels", "seed_gold", 0)
	cfg.set_value("levels", "xp", 0)
	cfg.set_value("stats", "total_runs", 3)
	cfg.set_value("stats", "total_kills", 40)
	cfg.set_value("stats", "best_wave", 9)
	var write_err := cfg.save(TEST_PATH)
	s.load_save()
	var ok := write_err == OK and s.crystal == 7 and s.level(&"atk") == 2 \
		and s.total_kills == 40 and s.best_wave == 9 \
		and not s.chip_seen(&"CHIP_ATK") and not s.relic_seen(&"REL_MIDAS") \
		and not s.reaction_seen("rxn_fir_ice") and not s.has_achievement(&"ach_boss1")
	_check("C6 旧档缺节容忍：v1.3.0 形档（无 [seen]/[achievements]）读入静默空——"
		+ "既有段照常载入 + 四表全空", ok)


# ══ C7：脏键容忍（非 String 键跳过 / 脏型节空） ═════════════════════
func _test_c7_dirty_keys() -> void:
	print("── C7 脏键 ──")
	var s := _new_store()                         # 先建 store（构造即 wipe）再写脏档
	var cfg := ConfigFile.new()
	cfg.set_value("meta", "save_version", 1)
	cfg.set_value("meta", "crystal", 0)
	cfg.set_value("seen", "chips", {"CHIP_ATK": true, 123: true})
	cfg.set_value("seen", "relics", {"REL_MIDAS": true})
	cfg.set_value("seen", "reactions", "not_a_dict")
	var write_err := cfg.save(TEST_PATH)
	s.load_save()
	var ok := write_err == OK and s.chip_seen(&"CHIP_ATK") \
		and not s.chip_seen(&"CHIP_ATK2") and s.relic_seen(&"REL_MIDAS") \
		and not s.reaction_seen("rxn_fir_ice")
	_check("C7 脏键容忍：seen.chips 混入 int 键被跳过（String 键收录）/ reactions 脏型"
		+ " warning + 空表 / 其余键正常", ok)


# ══ C8：wipe 清四表 ═════════════════════════════════════════════════
func _test_c8_wipe_clears() -> void:
	print("── C8 wipe ──")
	var s := _new_store()
	s.mark_chip_seen(&"CHIP_ATK")
	s.mark_relic_seen(&"REL_MIDAS")
	s.mark_reaction_seen("amp_vapor")
	s.unlock_achievement(&"ach_wave10")
	s.wipe()
	var ok := not s.chip_seen(&"CHIP_ATK") and not s.relic_seen(&"REL_MIDAS") \
		and not s.reaction_seen("amp_vapor") and not s.has_achievement(&"ach_wave10") \
		and not FileAccess.file_exists(TEST_PATH)
	_check("C8 wipe：图鉴三表 + 成就表全清 + 存档文件删除", ok)
