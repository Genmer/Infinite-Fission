# tests/runner/r245_content_cases.gd
# R245「内容扩容批」流C 用例体（由 test_r245_content.gd 入口在 autoload 就绪后运行时加载）。
# 设计真源 docs/design/2026-10-09-R245-design.md §4（成就+图鉴扩容）/ §7-4 验收 A-F：
#   A 全表 160 条（手写 11 + 阶梯 62（A 组前档 5 + B 组 9 族 20 并入后）+ 单敌 87）+
#     逐 type 计数对账 + 全表 id 唯一（撞 id/撞档守卫零跳过的等价证明——守卫触发会缩量）；
#   E 奖励总额动态求和 == 1800 ≤ 封顶 1850；
#   B 8 信号→records 计数→桶查解锁→结晶入账全链 + A 组事件链（wave_3/level_5/kills_50/
#     weapons_1/runs_1）+ achievements_changed 边沿（HUD toast 复用现有接线，零新 UI）；
#   C 旧档（五键 records / 无 codex.relics 键）load 后新键默认 0、done 不回收 + 新键落盘
#     回读 roundtrip（零迁移）；
#   D RELIC 卡（kind=2）→ codex_relics 收录 + codex_changed + 图鉴「遗物」页签 18 行 +
#     锁定/解锁两态 + 大厅角标分母 133（29+13+73+18）；
#   F 成就面板未完成行「x/y」进度与 _counter_value 一致、已完成行「已完成」无进度段。
# 纪律：headless 测试档自动隔离（meta_save_test.cfg）+ 首尾快照/还原 Meta 全量运行态
# （r246_meta_cases 同式，另含 R245 新键 codex_relics）；纯 Meta 域零 add_child，
# UI 组用 GameLoop 子树（rxn_codex_cases 先例，set_physics_process(false) 防tick）。
extends RefCounted

const ACH_PAGE_SIZE_OF_MENU := 24             # menu_screen.ACH_PAGE_SIZE 同值（duck 取）

var tree: SceneTree
var _pass := 0
var _fail := 0
var _failures: Array[String] = []
var _bk: Dictionary = {}
var _gl = null                               # GameLoop 子树（D/F 组建；用后即释放）


func run(p_tree: SceneTree) -> void:
	tree = p_tree
	seed(245)
	_snapshot_meta()
	_test_a_table_expansion()
	_test_b_signal_chains()
	_test_c_old_save_compat()
	_test_d_relic_codex()
	_test_f_ach_progress()
	_restore_meta()
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
		print("PASS | %s" % p_name)
	else:
		_fail += 1
		_failures.append("%s %s" % [p_name, p_detail])
		print("FAIL | %s | %s" % [p_name, p_detail])


# ── 快照/还原（r246_meta_cases 同式 + R245 新键 codex_relics） ──────
func _snapshot_meta() -> void:
	_bk = {
		"records": Meta.records.duplicate(true),
		"map_records": Meta.map_records.duplicate(true),
		"maps_cleared": Meta.maps_cleared.duplicate(true),
		"daily_records": Meta.daily_records.duplicate(true),
		"achievements_done": Meta.achievements_done.duplicate(true),
		"codex_kills": Meta.codex_kills.duplicate(true),
		"codex_weapons": Meta.codex_weapons.duplicate(true),
		"codex_traits": Meta.codex_traits.duplicate(true),
		"codex_relics": Meta.codex_relics.duplicate(true),
		"unlocked_characters": Meta.unlocked_characters.duplicate(true),
		"upgrades": Meta.upgrades.duplicate(true),
		"crystals": Meta.crystals,
		"character_id": Meta.character_id,
		"custom_weapon_id": Meta.custom_weapon_id,
	}


func _restore_meta() -> void:
	Meta.records = _bk["records"]
	Meta.map_records = _bk["map_records"]
	Meta.maps_cleared = _bk["maps_cleared"]
	Meta.daily_records = _bk["daily_records"]
	Meta.achievements_done = _bk["achievements_done"]
	Meta.codex_kills = _bk["codex_kills"]
	Meta.codex_weapons = _bk["codex_weapons"]
	Meta.codex_traits = _bk["codex_traits"]
	Meta.codex_relics = _bk["codex_relics"]
	Meta.unlocked_characters = _bk["unlocked_characters"]
	Meta.upgrades = _bk["upgrades"]
	Meta.crystals = int(_bk["crystals"])
	Meta.character_id = _bk["character_id"]
	Meta.custom_weapon_id = String(_bk["custom_weapon_id"])
	Meta.set_run_map(MapTable.FIRST_MAP_ID)
	Meta.set_run_difficulty(0)
	Meta.set_run_daily(false)
	Meta._save()


# 零基线（B/D/F 组共用的可控起点：records 回五键旧形状证明 .get 口鲁棒性）
func _zero_baseline() -> void:
	Meta.records = {"best_wave": 0, "best_kills": 0, "best_level": 1,
		"total_runs": 0, "total_kills": 0}
	Meta.achievements_done = {}
	Meta.codex_kills = {}
	Meta.codex_weapons = {}
	Meta.codex_traits = {}
	Meta.codex_relics = {}
	Meta.maps_cleared = {}
	Meta.map_records = {}
	Meta.crystals = 0
	Meta.set_run_map(MapTable.FIRST_MAP_ID)
	Meta.set_run_difficulty(0)
	Meta.set_run_daily(false)
	Meta._run_max_wave = 0
	Meta._run_max_level = 1
	Meta._run_kills = 0
	Meta._run_weapons_drawn = 0
	Meta._run_traits_drawn = 0
	Meta._run_reactions = 0
	Meta._run_boss_slain = 0


# 满形状默认 records（C 组专用：_load 的 for key in records 只遍历运行态现存键——
# 真实 boot 流 records 恒为 13 键全形状，缺键回默认 0 语义成立于该前提）
func _records_fresh() -> Dictionary:
	return {
		"best_wave": 0, "best_kills": 0, "best_level": 1,
		"total_runs": 0, "total_kills": 0,
		"total_skill_casts": 0, "total_deaths": 0, "total_graze": 0, "total_blocks": 0,
		"total_milestones": 0, "total_revives": 0, "total_rerolls": 0, "total_alarms": 0,
	}


# ══ A/E 组：表展开审计（160 条 / 逐 type 对账 / 奖励 1800 ≤ 1850） ══
func _test_a_table_expansion() -> void:
	print("── A/E：表展开（160 条 / 逐 type 对账 / 奖励总额 1800 ≤ 封顶 1850） ──")
	# A1 规模（11 手写 + 62 阶梯（A 组 5 + B 组 20 并入）+ 87 单敌 = 160）
	_check("A1 全表规模 == 160（≤500 UI 预留 / ≤200 r191 口径）",
		Meta.ACHIEVEMENTS.size() == 160 and Meta.ACHIEVEMENTS.size() <= 200,
		"n=%d" % Meta.ACHIEVEMENTS.size())
	# A2 id 全局唯一（展开器撞 id 守卫零触发的等价证明——撞档会缩量打破 A1/A3）
	var uniq := {}
	for a: Dictionary in Meta.ACHIEVEMENTS:
		uniq[String(a.id)] = true
	_check("A2 全表 id 唯一（160 条无重复——撞 id/撞档守卫零新增跳过）",
		uniq.size() == 160, "uniq=%d" % uniq.size())
	# A3 逐 type 计数对账（手写 + 阶梯 + A 组前档全量落地；缺档 = 守卫跳过或漏行）
	var per_type := {}
	for a2: Dictionary in Meta.ACHIEVEMENTS:
		var t := String(a2.type)
		per_type[t] = int(per_type.get(t, 0)) + 1
	var expect_type := {
		"total_kills": 7, "run_wave": 7, "run_level": 6, "run_weapons_drawn": 4,
		"run_traits_drawn": 4, "boss_slain": 4, "total_runs": 6, "run_reactions": 3,
		"codex_weapons": 2, "codex_traits": 3, "maps_cleared": 3, "endless_depth": 4,
		"total_skill_casts": 3, "total_deaths": 2, "total_graze": 2, "total_blocks": 2,
		"total_milestones": 2, "total_revives": 2, "total_rerolls": 2, "total_alarms": 2,
		"codex_relics": 3, "enemy_kills": 87,
	}
	var type_ok := true
	var type_bad := ""
	for k: String in expect_type:
		if int(per_type.get(k, -1)) != int(expect_type[k]):
			type_ok = false
			type_bad = "%s=%d(exp %d)" % [k, int(per_type.get(k, -1)), int(expect_type[k])]
	_check("A3 逐 type 计数对账（22 type 全对；手写槽位 + 阶梯档 + A 组前档全量落地）",
		type_ok and per_type.size() == 22, "bad=%s types=%d" % [type_bad, per_type.size()])
	# A4 A 组首局保底 5 条逐条锁（id/名称/奖励——设计 §4.2 A 组表逐字）
	var by_id := {}
	for a3: Dictionary in Meta.ACHIEVEMENTS:
		by_id[String(a3.id)] = a3
	var group_a_ok := by_id.has("total_runs_1") and by_id.has("run_wave_3") \
		and by_id.has("run_level_5") and by_id.has("total_kills_50") \
		and by_id.has("run_weapons_drawn_1")
	if group_a_ok:
		group_a_ok = String(by_id["total_runs_1"].name) == "初次出击" \
			and int(by_id["total_runs_1"].reward) == 10 \
			and String(by_id["run_wave_3"].name) == "站稳浪头" \
			and int(by_id["run_wave_3"].reward) == 5 \
			and String(by_id["run_level_5"].name) == "初阶适应" \
			and int(by_id["run_level_5"].reward) == 10 \
			and String(by_id["total_kills_50"].name) == "初次清场" \
			and int(by_id["total_kills_50"].reward) == 5 \
			and String(by_id["run_weapons_drawn_1"].name) == "新玩具" \
			and int(by_id["run_weapons_drawn_1"].reward) == 5
	_check("A4 A 组首局保底 5 条在册（runs_1/wave_3/level_5/kills_50/weapons_1 名称+奖励逐字）",
		group_a_ok, "by_id=%s" % str(by_id.keys().size()))
	# A5 B 组 9 族终档锁（名称链尾 + desc_fmt 生成样例）
	var b_ok := by_id.has("total_skill_casts_500") \
		and String(by_id["total_skill_casts_500"].name) == "技能大师" \
		and by_id.has("total_deaths_50") and String(by_id["total_deaths_50"].name) == "不死传说" \
		and by_id.has("total_graze_2000") and String(by_id["total_graze_2000"].name) == "擦弹行者" \
		and by_id.has("total_blocks_1000") and String(by_id["total_blocks_1000"].name) == "铜墙铁壁" \
		and by_id.has("total_milestones_30") and String(by_id["total_milestones_30"].name) == "质变大师" \
		and by_id.has("total_revives_15") and String(by_id["total_revives_15"].name) == "轮回行者" \
		and by_id.has("total_rerolls_100") and String(by_id["total_rerolls_100"].name) == "完美主义" \
		and by_id.has("total_alarms_20") and String(by_id["total_alarms_20"].name) == "高危常客" \
		and by_id.has("codex_relics_40") and String(by_id["codex_relics_40"].name) == "全遗之主" \
		and String(by_id["codex_relics_40"].desc) == "图鉴收录 40 件遗物"
	_check("A5 B 组 9 族终档在册（技能大师/不死传说/擦弹行者/铜墙铁壁/质变大师/轮回行者/完美主义/高危常客/全遗之主）",
		b_ok)
	# E 奖励总额动态求和（== 1800 且 ≤ 1850 封顶；含 25 条新增合计 235 的内嵌核算）
	var reward_sum := 0
	for a4: Dictionary in Meta.ACHIEVEMENTS:
		reward_sum += int(a4.get("reward", 0))
	var new_25 := 0
	for a5: Dictionary in Meta.ACHIEVEMENTS:
		var aid := String(a5.id)
		if aid == "total_runs_1" or aid == "run_wave_3" or aid == "run_level_5" \
				or aid == "total_kills_50" or aid == "run_weapons_drawn_1" \
				or String(a5.type) in ["total_skill_casts", "total_deaths", "total_graze",
					"total_blocks", "total_milestones", "total_revives", "total_rerolls",
					"total_alarms", "codex_relics"]:
			new_25 += int(a5.get("reward", 0))
	_check("E1 奖励总额 == 1800 ≤ 封顶 1850（动态求和；新增 25 条合计 235）",
		reward_sum == 1800 and reward_sum <= 1850 and new_25 == 235,
		"sum=%d new=%d" % [reward_sum, new_25])
	# A6 展开幂等（重复调用零新增——_ach_expanded 位）
	Meta._expand_achievements()
	_check("A6 展开幂等（二次 _expand_achievements 后仍 160）",
		Meta.ACHIEVEMENTS.size() == 160)
	# A7 分桶注册（9 新 type 全入 _ach_by_type——漏桶 = 事件口查空 = 永久漏检）
	var bucket_ok := true
	for t2: String in ["total_skill_casts", "total_deaths", "total_graze", "total_blocks",
			"total_milestones", "total_revives", "total_rerolls", "total_alarms", "codex_relics"]:
		if not Meta._ach_by_type.has(t2) or (Meta._ach_by_type[t2] as Array).is_empty():
			bucket_ok = false
	_check("A7 成就桶注册：9 新 type 全入 _ach_by_type（事件口增量查依赖）", bucket_ok)


# ══ B 组：8 信号→计数→解锁全链 + A 组事件链 ══
func _test_b_signal_chains() -> void:
	print("── B：信号→计数→解锁全链（8 技巧/经历信号 + A 组事件链） ──")
	# B1 skill_cast ×100 → total_skill_casts==100 → 20/100 两档解锁 +10（500 未达）
	_zero_baseline()
	for i in range(100):
		EventBus.emit_skill_cast(Vector2.ZERO, "sentinel")
	_check("B1 skill_cast ×100 → records 计数 100 + total_skill_casts_20/100 解锁 +10 结晶（500 档未达）",
		int(Meta.records.get("total_skill_casts", -1)) == 100
			and Meta.is_ach_done(&"total_skill_casts_20")
			and Meta.is_ach_done(&"total_skill_casts_100")
			and not Meta.is_ach_done(&"total_skill_casts_500")
			and Meta.crystals == 10, "c=%d cry=%d" % [int(Meta.records.get("total_skill_casts", -1)), Meta.crystals])
	# B2 player_died ×50 → 10/50 两档 +20
	_zero_baseline()
	for i2 in range(50):
		EventBus.emit_player_died()
	_check("B2 player_died ×50 → total_deaths_10/50 解锁 +20",
		int(Meta.records.get("total_deaths", -1)) == 50
			and Meta.is_ach_done(&"total_deaths_10") and Meta.is_ach_done(&"total_deaths_50")
			and Meta.crystals == 20)
	# B3 graze ×2000 → 200/2000 两档 +15
	_zero_baseline()
	for i3 in range(2000):
		EventBus.emit_graze(Vector2.ZERO)
	_check("B3 graze ×2000 → total_graze_200/2000 解锁 +15",
		int(Meta.records.get("total_graze", -1)) == 2000
			and Meta.is_ach_done(&"total_graze_200") and Meta.is_ach_done(&"total_graze_2000")
			and Meta.crystals == 15)
	# B4 格挡双信号同计（shield_blocked ×50 + bullet_nullified ×50 → blocks==100 → 100 档解锁 0 结晶）
	_zero_baseline()
	for i4 in range(50):
		EventBus.emit_shield_blocked(Vector2.ZERO)
	for i5 in range(50):
		EventBus.emit_bullet_nullified(Vector2.ZERO)
	_check("B4 格挡/消弹双信号同计 total_blocks（50+50==100 → 固若金汤解锁零通胀）",
		int(Meta.records.get("total_blocks", -1)) == 100
			and Meta.is_ach_done(&"total_blocks_100")
			and not Meta.is_ach_done(&"total_blocks_1000")
			and Meta.crystals == 0)
	# B5 trait_milestone ×30 → 5/30 两档 +15
	_zero_baseline()
	for i6 in range(30):
		EventBus.emit_trait_milestone(&"MEC_HIT_BURST", "连击", 2.0)
	_check("B5 trait_milestone ×30 → total_milestones_5/30 解锁 +15",
		int(Meta.records.get("total_milestones", -1)) == 30
			and Meta.is_ach_done(&"total_milestones_5") and Meta.is_ach_done(&"total_milestones_30")
			and Meta.crystals == 15)
	# B6 revive_burst ×15 → 3/15 两档 +10
	_zero_baseline()
	for i7 in range(15):
		EventBus.emit_revive_burst(Vector2.ZERO, 0)
	_check("B6 revive_burst ×15 → total_revives_3/15 解锁 +10",
		int(Meta.records.get("total_revives", -1)) == 15
			and Meta.is_ach_done(&"total_revives_3") and Meta.is_ach_done(&"total_revives_15")
			and Meta.crystals == 10)
	# B7 reroll_granted ×100 → 10/100 两档 +10（按事件计数非按 count 参数）
	_zero_baseline()
	for i8 in range(100):
		EventBus.emit_reroll_granted(3)
	_check("B7 reroll_granted ×100 → total_rerolls_10/100 解锁 +10",
		int(Meta.records.get("total_rerolls", -1)) == 100
			and Meta.is_ach_done(&"total_rerolls_10") and Meta.is_ach_done(&"total_rerolls_100")
			and Meta.crystals == 10)
	# B8 damage_alarm ×20 → 1/20 两档 +5+10（首档即奖——×500 告警是高光时刻）
	_zero_baseline()
	var dr := DamageResult.new()
	for i9 in range(20):
		EventBus.emit_damage_alarm(dr)
	_check("B8 damage_alarm ×20 → total_alarms_1/20 解锁 +15",
		int(Meta.records.get("total_alarms", -1)) == 20
			and Meta.is_ach_done(&"total_alarms_1") and Meta.is_ach_done(&"total_alarms_20")
			and Meta.crystals == 15)
	# B9 achievements_changed 边沿（解锁即发——HUD toast 复用现有接线零新 UI 的信号前提）
	_zero_baseline()
	var fired: Array[String] = []
	var spy := func(p_aid: StringName) -> void: fired.append(String(p_aid))
	Meta.achievements_changed.connect(spy)
	EventBus.emit_damage_alarm(dr)
	Meta.achievements_changed.disconnect(spy)
	_check("B9 解锁边沿：achievements_changed 恰发一次（total_alarms_1——现有 toast 消费口）",
		fired.size() == 1 and fired[0] == "total_alarms_1", "fired=%s" % str(fired))
	# ── A 组事件链 ──
	# B10 run_wave_3：wave_started(3) 事件解锁 +5（早死局也过 w3）
	_zero_baseline()
	EventBus.emit_wave_started(3)
	_check("B10 A组 wave_started(3) → run_wave_3「站稳浪头」解锁 +5",
		Meta.is_ach_done(&"run_wave_3") and Meta.crystals == 5)
	# B11 run_level_5：level_up(5) 事件解锁 +10
	_zero_baseline()
	EventBus.emit_level_up(5)
	_check("B11 A组 level_up(5) → run_level_5「初阶适应」解锁 +10",
		Meta.is_ach_done(&"run_level_5") and Meta.crystals == 10)
	# B12 total_kills_50：enemy_killed ×50 事件解锁 +5（连带 first_blood +10 = 15；
	# E1_grunt 单敌 50 档奖励 0 不掺账）
	_zero_baseline()
	var stub := StubEnemy.new()
	for i10 in range(50):
		EventBus.emit_enemy_killed(stub)
	stub.free()
	_check("B12 A组 enemy_killed ×50 → total_kills_50「初次清场」+first_blood 合计 +15",
		Meta.is_ach_done(&"total_kills_50") and Meta.is_ach_done(&"first_blood")
			and int(Meta.records.get("total_kills", -1)) == 50 and Meta.crystals == 15,
		"cry=%d" % Meta.crystals)
	# B13 run_weapons_drawn_1：card_chosen(WEAPON) 解锁 +5（连带 codex_weapons_5 未达）
	_zero_baseline()
	EventBus.emit_card_chosen(&"W3_shotgun", 4)
	_check("B13 A组 card_chosen(kind=WEAPON) → run_weapons_drawn_1「新玩具」解锁 +5",
		Meta.is_ach_done(&"run_weapons_drawn_1") and Meta.crystals == 5
			and Meta.is_weapon_unlocked(&"W3_shotgun"))
	# B14 total_runs_1：GAME_OVER 结算解锁 +10（局产出 0 波 0 杀 → 纯成就 +10）
	_zero_baseline()
	Meta._on_state_changed(GameConst.GameStatus.GAME_OVER)
	_check("B14 A组 首局结算 → total_runs_1「初次出击」解锁 +10（零局产出下纯成就入账）",
		Meta.is_ach_done(&"total_runs_1") and Meta.crystals == 10
			and int(Meta.records.get("total_runs", -1)) == 1,
		"cry=%d" % Meta.crystals)


# ══ C 组：旧档零迁移（缺键回 0 / done 不回收 / 新键 roundtrip） ══
func _test_c_old_save_compat() -> void:
	print("── C：旧档零迁移（五键 records / 无 relics 键 → 默认 0；done 只增） ──")
	var bk_path: String = Meta.save_path()
	# C1 旧档形状：records 仅五键、codex 无 relics、achievements.done 含旧 id
	var cfg := ConfigFile.new()
	cfg.set_value("records", "total_runs", 3)
	cfg.set_value("records", "total_kills", 123)
	cfg.set_value("achievements", "done", ["first_blood", "wave_10"])
	cfg.set_value("codex", "kills", {"E1_grunt": 5})
	cfg.save(bk_path)
	Meta.records = _records_fresh()
	Meta.achievements_done = {}
	Meta.codex_relics = {}                       # _load 为累积回填不清运行态（r196 先例：先清再载）
	Meta._load()
	_check("C1 旧档 load：五键回读（runs=3/kills=123）+ 8 新累计键缺省回 0",
		int(Meta.records.get("total_runs", -1)) == 3
			and int(Meta.records.get("total_kills", -1)) == 123
			and int(Meta.records.get("total_skill_casts", -1)) == 0
			and int(Meta.records.get("total_alarms", -1)) == 0
			and int(Meta.records.get("total_graze", -1)) == 0,
		"r=%s" % str(Meta.records))
	_check("C2 旧档 load：codex.relics 缺键 → 空表（累积回填不新增键，降级不崩）",
		Meta.codex_relics.is_empty())
	_check("C3 done 不回收：first_blood/wave_10 保留 + 新 id（total_runs_1）不在 done（待达成）",
		Meta.achievements_done.has("first_blood") and Meta.achievements_done.has("wave_10")
			and not Meta.achievements_done.has("total_runs_1"))
	# C4 新键 roundtrip：计数 + 收录落盘 → 清运行态 → load 回读
	Meta.records["total_graze"] = 7
	Meta.records["total_skill_casts"] = 21
	Meta.mark_relic_codex(&"REL_PHOENIX")
	Meta._save()
	Meta.records = _records_fresh()
	Meta.codex_relics = {}
	Meta._load()
	_check("C4 新键落盘 roundtrip：graze=7/skill_casts=21 回读 + REL_PHOENIX 收录持久",
		int(Meta.records.get("total_graze", -1)) == 7
			and int(Meta.records.get("total_skill_casts", -1)) == 21
			and Meta.is_relic_unlocked(&"REL_PHOENIX"),
		"g=%d s=%d relic=%s" % [int(Meta.records.get("total_graze", -1)),
			int(Meta.records.get("total_skill_casts", -1)),
			str(Meta.is_relic_unlocked(&"REL_PHOENIX"))])


# ══ D 组：RELIC 卡 → codex_relics 收录 + 遗物页签 + 角标分母 133 ══
func _test_d_relic_codex() -> void:
	print("── D：RELIC 卡收录 / 遗物页签 18 行 / 角标分母 133 ──")
	_gl = GameLoop.new()
	_gl.name = "GameLoopForR245Content"
	tree.get_root().add_child(_gl)
	_gl.set_physics_process(false)
	var menu = _gl.menu_screen
	# D0 前置：registry 遗物清单 18 件（resources/relics 目录真源）+ 图鉴四域分母 133
	var n_enemies: int = menu.registry.enemies.size()
	var n_weapons: int = menu.registry.weapons.size()
	var n_traits: int = menu.registry.traits.size()
	var n_relics: int = menu.registry.relics.size()
	_check("D0 registry 四域规模（怪 29 / 武 13 / 词条 73 / 遗物 40 → 分母 155）",
		n_enemies == 29 and n_weapons == 13 and n_traits == 73 and n_relics == 40,
		"e=%d w=%d t=%d r=%d" % [n_enemies, n_weapons, n_traits, n_relics])
	_zero_baseline()
	menu._refresh_lobby_counts()
	_check("D1 角标分母 155：零基线文案「图鉴 0/155」（29+13+73+40·R253+6 遗物）",
		(menu._lobby_btns["codex"] as Button).text == "图鉴 0/155",
		"txt=%s" % (menu._lobby_btns["codex"] as Button).text)
	# D2 RELIC 卡应用（card_chosen kind=2，EventBus 全链——card_generator 侧零改动契约）
	var relic_ids: Array = menu.registry.relics.keys()
	var first_relic: StringName = StringName(String(relic_ids[0]))
	var codex_fired := {"n": 0}
	var spy2 := func() -> void: codex_fired["n"] = int(codex_fired["n"]) + 1
	Meta.codex_changed.connect(spy2)
	EventBus.emit_card_chosen(first_relic, 2)
	Meta.codex_changed.disconnect(spy2)
	_check("D2 RELIC 卡 → codex_relics 收录 + codex_changed 恰发一次（角标/面板刷新口）",
		Meta.is_relic_unlocked(first_relic) and Meta.codex_relics.size() == 1
			and int(codex_fired["n"]) == 1)
	menu._refresh_lobby_counts()
	_check("D3 收录后角标「图鉴 1/155」（获得口径与其余三页一致·R253 后分母）",
		(menu._lobby_btns["codex"] as Button).text == "图鉴 1/155",
		"txt=%s" % (menu._lobby_btns["codex"] as Button).text)
	# D4 收录 6 件 → codex_relics_6 解锁（收集族链通）+ 幂等重发不涨（R252C 首档 5→6）
	for i in range(5):
		EventBus.emit_card_chosen(StringName(String(relic_ids[i + 1])), 2)
	EventBus.emit_card_chosen(first_relic, 2)     # 幂等：已收录重发
	_check("D4 收录 6 件 → codex_relics_6「遗物收藏家」解锁（0 结晶）+ 重复应用幂等不涨",
		Meta.codex_relics.size() == 6 and Meta.is_ach_done(&"codex_relics_6")
			and Meta.crystals == 0,
		"n=%d cry=%d" % [Meta.codex_relics.size(), Meta.crystals])
	# D5 遗物页签：第五页签存在 + 18 行全量 + 锁定态「？？？」
	_check("D5a 图鉴第五页签「遗物」在册（5 页签：怪物/武器/词条/反应/遗物）",
		menu._codex_tabs.size() == 5 and menu._codex_tabs.has("遗物"))
	menu._on_lobby_pressed("codex")
	menu._on_codex_tab("遗物")
	var rows := _live_rows(menu._panel_list)
	_check("D5b 遗物页 40 行全量（registry.relics 同源·R253 后）", rows.size() == 40,
		"n=%d" % rows.size())
	var locked_name := false
	var locked_desc := false
	for r in rows:
		var labels: Array = []
		for c in r.get_children():
			if c is Label:
				labels.append(c)
		if labels.size() >= 2:
			var nm := String((labels[0] as Label).text)
			var ds := String((labels[1] as Label).text)
			if nm == "？？？":
				locked_name = true
				locked_desc = locked_desc or ds == "未解锁：获得后展示详情"
	_check("D5c 锁定态：未收录行名「？？？」+「未解锁：获得后展示详情」",
		locked_name and locked_desc)
	# D6 解锁态：已收录行显示 display_name 真源（registry 读表，非硬编码）
	var unlocked_ok := false
	var first_def: RelicData = menu.registry.get_relic(first_relic)
	for r2 in rows:
		var labels2: Array = []
		for c2 in r2.get_children():
			if c2 is Label:
				labels2.append(c2)
		if labels2.size() >= 2 and String((labels2[0] as Label).text) == String(first_def.display_name) \
				and String((labels2[1] as Label).text) == String(first_def.description):
			unlocked_ok = true
	_check("D6 解锁态：已收录行名/描述 = RelicData display_name/description 真源读表",
		unlocked_ok, "want=%s" % String(first_def.display_name))
	_gl.free()
	_gl = null


# ══ F 组：成就面板行内 x/y 进度 ══
func _test_f_ach_progress() -> void:
	print("── F：成就面板行内进度（x/y 与 _counter_value 一致 / 已完成无进度段） ──")
	_gl = GameLoop.new()
	_gl.name = "GameLoopForR245Progress"
	tree.get_root().add_child(_gl)
	_gl.set_physics_process(false)
	var menu = _gl.menu_screen
	_zero_baseline()
	Meta.records["total_graze"] = 7             # 7/200 的可见进度
	menu._on_lobby_pressed("ach")
	var row = _find_ach_row(menu, "刀尖舞者")
	_check("F1 未完成行进度：total_graze=7 →「刀尖舞者」行含「7/200」（值 = _counter_value）",
		row != null and _row_desc(row).contains("7/200"),
		"row=%s desc=%s" % [str(row != null), _row_desc(row) if row != null else ""])
	# F2 进度一致性：改计数 199 → 重建 → 「199/200」；done 边沿 200 → 「已完成」无 x/y
	Meta.records["total_graze"] = 199
	menu._rebuild_achievements()
	var row2 = _find_ach_row(menu, "刀尖舞者")
	_check("F2 计数推进 → 行内进度实时跟随（199/200）",
		row2 != null and _row_desc(row2).contains("199/200"),
		"desc=%s" % (_row_desc(row2) if row2 != null else ""))
	Meta.records["total_graze"] = 200
	# R252 迁移：P6 大厅详情面板作用域批落盘（menu_screen.gd:712 _on_lobby_pressed →
	# _panel_begin_defer）期间 _persist_defer_depth>0，_check_achievements 首行深度门
	# 挂起（meta_manager.gd:1201——R189「批内挂起、收口结清」契约）。生产结清点 =
	# _on_panel_close → end_persist_defer → _check_achievements；面板打开期无计数推进，
	# 挂起无行为差。故达标翻转断言先走生产收口再重建行。
	Meta._check_achievements()
	menu._on_panel_close()                    # P6 包络收口：end → 成就扫描结清（总 200 达标）
	menu._rebuild_achievements()
	var row3 = _find_ach_row(menu, "刀尖舞者")
	_check("F3 达标翻转：解锁后行含「已完成」且无进度段（200/200 不重复显示）",
		row3 != null and _row_desc(row3).contains("已完成")
			and not _row_desc(row3).contains("200/200")
			and Meta.is_ach_done(&"total_graze_200"),
		"desc=%s" % (_row_desc(row3) if row3 != null else ""))
	# F4 敌族行进度（enemy_kills def.enemy 子键路径）：E1_grunt 击杀 12 → 「12/50」
	Meta.codex_kills = {"E1_grunt": 12}
	Meta.achievements_done = {}
	menu._rebuild_achievements()
	var row4 = _find_ach_row(menu, "杂兵克星")
	_check("F4 单敌族行进度：codex_kills E1_grunt=12 →「杂兵克星」行含「12/50」（def.enemy 路径）",
		row4 != null and _row_desc(row4).contains("12/50"),
		"desc=%s" % (_row_desc(row4) if row4 != null else ""))
	_gl.free()
	_gl = null


# ── F/D 组行定位辅助 ──
func _live_rows(p_list: Node) -> Array:
	var out: Array = []
	for c in p_list.get_children():
		if not c.is_queued_for_deletion():
			out.append(c)
	return out


func _find_ach_row(p_menu, p_name: String):
	# 按成就名跨页定位行（页容量 24：先切「全部」页签算目标页再重建扫描——
	# 同 verify_feedback 翻页口径）。成就行子节点 = [mark(✓/·), name_l, desc_l]——
	# 名匹配扫全部 Label（不按位序，防 mark 挡位）。
	p_menu._ach_tab = "全部"
	var list: Array = p_menu._ach_filtered()
	var idx := -1
	for i in range(list.size()):
		if String(list[i].name) == p_name:
			idx = i
			break
	if idx < 0:
		return null
	p_menu._ach_page = idx / ACH_PAGE_SIZE_OF_MENU
	p_menu._rebuild_achievements()
	for r in _live_rows(p_menu._panel_list):
		for c in r.get_children():
			if c is Label and String((c as Label).text) == p_name:
				return r
	return null


func _row_desc(p_row) -> String:
	# 成就行尾 Label（desc_l——mark/name/desc 三 Label 的最后一个）
	var last_label: Label = null
	for c in p_row.get_children():
		if c is Label:
			last_label = c
	return String(last_label.text) if last_label != null else ""


# ── 假人（enemy_killed 的 Node2D 域 data/tags 读口） ──
class StubEnemy extends Node2D:
	var data := {"id": &"E1_grunt"}
