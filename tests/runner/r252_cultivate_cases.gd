# tests/runner/r252_cultivate_cases.gd
# R252 需求①「培养上限提帽」用例体（入口 test_r252_cultivate.gd 运行时 load——
# -s 编译期禁引工程类名纪律；cases 文件命名禁带 test_ 前缀）。验收锚（R252 设计 §1.5）：
#  C1 帽表：8 轨 max_lv == {life:10, atk:10, magnet:6, cdr:6, xp_gain:6, start_gold:5,
#     reroll:5, revive:3}；base_cost == {20,30,25,35,30,25,30,80}（首级价锁共存）。
#  C2 轨总价：buy_upgrade 逐级实购累加 == {1100,1650,525,735,630,375,450,480}。
#  C3 老档迁移：构造旧满级档（atk:5/life:5）→ _load 后保持 → 续购 atk Lv6 恰扣 30×6=180。
#  C4 满级拒绝：购至新帽后再购返 false、crystals 不变。
#  C5 终值锚：满级读口 hp/atk/magnet/cdr/xp/start_gold/reroll/revive 全表。
#  C6 复活叠加：养成 3 + difficulty_revives [0,1,3] → 3/4/6（game_loop 叠加点读数语义）。
#  C7 结算乘区锁：difficulty_crystal_mult 不动（[1.0,1.3,1.6]——E11 乘区锁）+
#     _settle_run_result 函数体内结晶公式源码锚（公式不动；复跑 test_r247_endless_channel
#     即为该锚的行为级验收——设计 §1.5 C7 口径）。
# 测试卫生：headless 走 meta_save_test.cfg 独立档；开套件快照内存+档字节，收尾原样还原
# （防全解锁/购买位残留跨套件串扰——并行代理共用工程 user:// 目录）。
extends RefCounted

const META_SRC := "res://scripts/meta/meta_manager.gd"

# R252 设计 §1.2 期望表（id → 值）
const EXP_MAX_LV := {"life": 10, "atk": 10, "magnet": 6, "cdr": 6, "xp_gain": 6, "start_gold": 5, "reroll": 5, "revive": 3}
const EXP_BASE_COST := {"life": 20, "atk": 30, "magnet": 25, "cdr": 35, "xp_gain": 30, "start_gold": 25, "reroll": 30, "revive": 80}
const EXP_TRACK_TOTAL := {"life": 1100, "atk": 1650, "magnet": 525, "cdr": 735, "xp_gain": 630, "start_gold": 375, "reroll": 450, "revive": 480}

var tree: SceneTree
var _pass: int = 0
var _fail: int = 0
var _failures: Array[String] = []
# Meta 快照（套件隔离）
var _snap_crystals: int = 0
var _snap_upgrades: Dictionary = {}
var _snap_codex_traits: Dictionary = {}
var _snap_custom_weapon: String = ""
var _snap_blessing: String = ""
var _had_save: bool = false
var _save_text: String = ""


func run(p_tree: SceneTree) -> void:
	tree = p_tree
	await tree.process_frame
	_snap_meta()
	_test_c1_cap_table()
	_test_c2_track_total()
	_test_c3_old_save_migration()
	_test_c4_max_level_reject()
	_test_c5_final_value_anchors()
	_test_c6_revive_stack()
	_test_c7_settle_lock()
	_restore_meta()
	print("验收汇总：PASS %d / FAIL %d（共 %d 项）" % [_pass, _fail, _pass + _fail])
	if not _failures.is_empty():
		for f in _failures:
			print("  FAIL | %s" % f)


func fail_count() -> int:
	return _fail


func _check(p_name: String, p_cond: bool, p_detail: String = "") -> void:
	if p_cond:
		_pass += 1
		print("  ok | %s" % p_name)
	else:
		_fail += 1
		_failures.append("%s %s" % [p_name, p_detail])
		print("  FAIL | %s %s" % [p_name, p_detail])


# ── Meta 快照/还原（档 + 内存双面） ────────────────────────────────
func _snap_meta() -> void:
	_snap_crystals = Meta.crystals
	_snap_upgrades = Meta.upgrades.duplicate()
	_snap_codex_traits = Meta.codex_traits.duplicate()
	_snap_custom_weapon = Meta.custom_weapon_id
	_snap_blessing = Meta.blessing_trait_id
	var sp := Meta.save_path()
	_had_save = FileAccess.file_exists(sp)
	if _had_save:
		_save_text = FileAccess.get_file_as_string(sp)


func _restore_meta() -> void:
	Meta.crystals = _snap_crystals
	Meta.upgrades = _snap_upgrades
	Meta.codex_traits = _snap_codex_traits
	Meta.custom_weapon_id = _snap_custom_weapon
	Meta.blessing_trait_id = _snap_blessing
	var sp := Meta.save_path()
	if _had_save:
		var f := FileAccess.open(sp, FileAccess.WRITE)
		if f != null:
			f.store_string(_save_text)
			f.close()
		Meta._load()                              # 按原档字节重载（内存随档还原）
	else:
		DirAccess.remove_absolute(ProjectSettings.globalize_path(sp))
		# 无原档：内存快照已还原，测试期写出的档删除即可（下次 _load 缺档=首启口径）


# ── C1 帽表 ───────────────────────────────────────────────────────
func _test_c1_cap_table() -> void:
	print("── C1 帽表：max_lv 提帽 ×8 + base_cost 不动 ──")
	_check("C1 前置：UPGRADES 恒 8 轨（不加轨）", Meta.UPGRADES.size() == 8,
		"size=%d" % Meta.UPGRADES.size())
	var max_hit := 0
	var cost_hit := 0
	for u in Meta.UPGRADES:
		var id := String(u.id)
		if int(u.max_lv) == int(EXP_MAX_LV.get(id, -1)):
			max_hit += 1
		else:
			_failures.append("C1 max_lv %s=%d 期望 %d" % [id, int(u.max_lv), int(EXP_MAX_LV.get(id, -1))])
		if int(u.base_cost) == int(EXP_BASE_COST.get(id, -1)):
			cost_hit += 1
	_check("C1 帽表：8 轨 max_lv == {life:10, atk:10, magnet:6, cdr:6, xp_gain:6, start_gold:5, reroll:5, revive:3}",
		max_hit == 8, "hit=%d/8" % max_hit)
	_check("C1 首级价锁共存：8 轨 base_cost 不动 {20,30,25,35,30,25,30,80}",
		cost_hit == 8, "hit=%d/8" % cost_hit)


# ── C2 轨总价（buy_upgrade 实购累加） ─────────────────────────────
func _test_c2_track_total() -> void:
	print("── C2 轨总价：逐级实购累加 == {1100,1650,525,735,630,375,450,480} ──")
	Meta.upgrades = {}
	Meta.crystals = 1 << 22                            # 充裕预算（本组只核价格曲线）
	var all_ok := true
	var detail := ""
	for u in Meta.UPGRADES:
		var id := String(u.id)
		var total := 0
		var bought_ok := true
		for _lv in range(int(u.max_lv)):
			var cost := Meta.upgrade_cost(StringName(id))   # = base_cost × (当前级+1)
			if not Meta.buy_upgrade(StringName(id)):
				bought_ok = false
				break
			total += cost
		if not bought_ok or total != int(EXP_TRACK_TOTAL.get(id, -1)):
			all_ok = false
			detail += " %s:%d" % [id, total]
	_check("C2 轨总价：8 轨逐级实购累加全中（含 buy_upgrade 满级前全通）",
		all_ok, detail)


# ── C3 老档迁移（旧满级 → 保持 + 续购新帽） ────────────────────────
func _test_c3_old_save_migration() -> void:
	print("── C3 老档迁移：旧满级原样保留、从旧帽续购 ──")
	var cfg := ConfigFile.new()
	cfg.set_value("meta", "crystals", 1000)
	cfg.set_value("meta", "upgrades", {"atk": 5, "life": 5})   # 旧帽满级（R252 前口径）
	cfg.set_value("meta", "character", "sentinel")
	cfg.save(Meta.save_path())
	Meta._load()
	_check("C3 迁移：旧档 atk/life Lv5 原样保留（无钳制回退路径）",
		Meta.upgrade_level(&"atk") == 5 and Meta.upgrade_level(&"life") == 5,
		"atk=%d life=%d" % [Meta.upgrade_level(&"atk"), Meta.upgrade_level(&"life")])
	var c0 := Meta.crystals
	var bought := Meta.buy_upgrade(&"atk")
	_check("C3 续购：旧满级续购 Lv6 成功且恰扣 30×6=180",
		bought and Meta.upgrade_level(&"atk") == 6 and Meta.crystals == c0 - 180,
		"bought=%s lv=%d d crystals=%d" % [str(bought), Meta.upgrade_level(&"atk"), c0 - Meta.crystals])


# ── C4 满级拒绝 ───────────────────────────────────────────────────
func _test_c4_max_level_reject() -> void:
	print("── C4 满级拒绝：新帽购满后再购返 false、crystals 不变 ──")
	Meta.upgrades = {"life": 10, "atk": 10}            # 新帽满级（直写探针口径）
	Meta.crystals = 999999
	var c0 := Meta.crystals
	_check("C4 满级拒绝：life/atk 再购返 false",
		not Meta.buy_upgrade(&"life") and not Meta.buy_upgrade(&"atk"))
	_check("C4 结晶零扣：拒绝路径 crystals 不变", Meta.crystals == c0,
		"%d → %d" % [c0, Meta.crystals])


# ── C5 终值锚（斜率不动 × 新帽） ──────────────────────────────────
func _test_c5_final_value_anchors() -> void:
	print("── C5 终值锚：满级读口全表 ──")
	var full := {}
	for u in Meta.UPGRADES:
		full[String(u.id)] = int(u.max_lv)
	Meta.upgrades = full
	_check("C5 满级读口：hp_bonus==100.0 / atk_pct==0.40 / magnet_pct==0.90 / skill_cdr_pct==0.48",
		absf(Meta.hp_bonus() - 100.0) <= 0.001 and absf(Meta.atk_pct() - 0.40) <= 0.0001
			and absf(Meta.magnet_pct() - 0.90) <= 0.0001 and absf(Meta.skill_cdr_pct() - 0.48) <= 0.0001,
		"hp=%.1f atk=%.3f mag=%.3f cdr=%.3f" % [Meta.hp_bonus(), Meta.atk_pct(), Meta.magnet_pct(), Meta.skill_cdr_pct()])
	_check("C5 满级读口：xp_pct==0.48 / start_gold==100 / reroll_bonus==5 / revive_charges==3",
		absf(Meta.xp_pct() - 0.48) <= 0.0001 and Meta.start_gold() == 100
			and Meta.reroll_bonus() == 5 and Meta.revive_charges() == 3,
		"xp=%.3f gold=%d reroll=%d revive=%d" % [Meta.xp_pct(), Meta.start_gold(), Meta.reroll_bonus(), Meta.revive_charges()])


# ── C6 复活叠加（game_loop 叠加点读数语义） ───────────────────────
func _test_c6_revive_stack() -> void:
	print("── C6 复活叠加：养成 3 + difficulty_revives [0,1,3] ──")
	var full := {}
	for u in Meta.UPGRADES:
		full[String(u.id)] = int(u.max_lv)
	Meta.upgrades = full
	_check("C6 叠加：普通 3+0==3 / 困难 3+1==4 / 地狱 3+3==6（线性相加语义不动）",
		Meta.revive_charges() + GameConst.difficulty_revives(0) == 3
			and Meta.revive_charges() + GameConst.difficulty_revives(1) == 4
			and Meta.revive_charges() + GameConst.difficulty_revives(2) == 6,
		"r=%d/%d/%d" % [Meta.revive_charges() + GameConst.difficulty_revives(0),
			Meta.revive_charges() + GameConst.difficulty_revives(1),
			Meta.revive_charges() + GameConst.difficulty_revives(2)])
	_check("C6 附赠表不动：difficulty_revives == [0,1,3]（R252 不改表）",
		GameConst.difficulty_revives(0) == 0 and GameConst.difficulty_revives(1) == 1
			and GameConst.difficulty_revives(2) == 3)


# ── C7 结算乘区锁（公式不动；r247 复跑为行为级验收） ───────────────
func _test_c7_settle_lock() -> void:
	print("── C7 结算锁：crystal 乘区表 + 公式源码锚（函数体区间裁剪） ──")
	_check("C7 乘区表不动：difficulty_crystal_mult == [1.0,1.3,1.6]（E11 地狱 ×1.6 锁）",
		is_equal_approx(GameConst.difficulty_crystal_mult(0), 1.0)
			and is_equal_approx(GameConst.difficulty_crystal_mult(1), 1.3)
			and is_equal_approx(GameConst.difficulty_crystal_mult(2), 1.6),
		"%.2f/%.2f/%.2f" % [GameConst.difficulty_crystal_mult(0),
			GameConst.difficulty_crystal_mult(1), GameConst.difficulty_crystal_mult(2)])
	# 源码计数锚纪律：函数体区间裁剪（_settle_run_result 至下一 func）
	var src := FileAccess.get_file_as_string(META_SRC)
	var f0 := src.find("func _settle_run_result")
	var body := ""
	if f0 >= 0:
		var f1 := src.find("\nfunc ", f0 + 10)
		body = src.substr(f0, (f1 if f1 > f0 else src.length()) - f0)
	_check("C7 公式源码锚：_settle_run_result 体内结晶公式字面不动（行为级验收=复跑 test_r247_endless_channel）",
		body.contains("_run_max_wave * 1.5 + _run_kills / 25.0")
			and body.contains("GameConst.difficulty_crystal_mult(_run_difficulty)"),
		"body_len=%d" % body.length())
