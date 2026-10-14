# tests/runner/r246_meta_cases.gd
# R246/R247「meta 泳道回归」用例体（由 test_r246_meta.gd 入口在 autoload 就绪后运行时
# 加载；R247 集成终修补建——meta 泳道申报回归套件缺失，样板 r245_diff_star_cases 同式）。
# 覆盖：角色表完整性 / 新角色条目 / 升华键×掷卡可用性一致性（终修判据锁）/ 无尽深度
# 成就门 / 全角色解锁判定矩阵。设计真源 docs/design/sublime/_channels.md §1/§2、
# character_table.gd 表头注释、card_generator.gd _sublime_available（R247 终修）。
# 纪律：headless 测试档自动隔离（meta_save_test.cfg）+ 首尾快照/还原 Meta 全量运行态
# 防跨套件污染（r247_endless_channel_cases 同式）；纯 Meta/表 域零 add_child。
extends RefCounted

var tree: SceneTree
var _pass := 0
var _fail := 0
var _failures: Array[String] = []
var _bk: Dictionary = {}


func run(p_tree: SceneTree) -> void:
	tree = p_tree
	seed(246)
	_snapshot_meta()
	_test_m1_table_integrity()
	_test_m2_new_characters()
	_test_m3_sublime_availability()
	_test_m4_endless_gate()
	_test_m5_unlock_matrix()
	_test_m6_r245_content_locks()
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


# ── 快照/还原（r247_endless_channel_cases 同式全量口径） ──────────
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
		"codex_relics": Meta.codex_relics.duplicate(true),   # R245：遗物收录集（M6 组）
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


# ══ M1：角色表完整性（全表契约审计） ══
func _test_m1_table_integrity() -> void:
	print("── M1：表完整性（13 角色 / id 唯一 / 必备键 / 门型互斥） ──")
	_check("M1a 表规模 13（存量 10 + R247 三新）", CharacterTable.count() == 13)
	# id 唯一 + 必备键齐（hp/atk_pct/cd 数值型；name/desc/skill 域非空留给有技能角色）
	var ids: Dictionary = {}
	var keys_ok := true
	var key_bad := ""
	var cd_ok := true
	var cd_bad := ""
	var hp_ok := true
	for c: Dictionary in CharacterTable.CHARACTERS:
		var cid := String(c.id)
		if ids.has(cid):
			keys_ok = false
			key_bad = cid + "（重复 id）"
		ids[cid] = true
		# 必备键：name/desc/hp/atk_pct/cd 全表；skill_name/skill_desc 仅限有技能角色
		#（fission no_skill 恒缺——其 desc 即「无技能·初始武器自定义」说明）
		var has_skill := not bool(c.get("no_skill", false))
		var ok := c.has("name") and c.has("desc") and c.has("hp") \
			and c.has("atk_pct") and c.has("cd")
		if has_skill:
			ok = ok and c.has("skill_name") and c.has("skill_desc") \
				and String(c.get("skill_name", "")) != "" \
				and String(c.get("skill_desc", "")) != ""
		if not ok:
			keys_ok = false
			key_bad = cid
		# verify_feedback 遍历全角色断言 cd==120（character_table.gd:106 ★ 契约）
		if absf(float(c.get("cd", 0.0)) - 120.0) > 0.01:
			cd_ok = false
			cd_bad = cid
		if float(c.get("hp", 0.0)) <= 0.0:
			hp_ok = false
	_check("M1b 全表 id 唯一 + 必备键齐（name/desc/hp/atk_pct/cd/skill_name/skill_desc）",
		keys_ok, "bad=%s" % key_bad)
	_check("M1c 全表 cd==120（verify_feedback 遍历契约——fission no_skill 仍保 cd 键）",
		cd_ok, "bad=%s" % cd_bad)
	_check("M1d 全表 hp 为正", hp_ok)
	# 门型互斥：unlock_map / unlock_normal_clear / unlock_hard_clear / unlock_endless_depth /
	# unlock_kills / unlock_achievement / unlock_price 七门至多一种（sentinel 免检=无门）
	var gate_keys: Array[String] = ["unlock_map", "unlock_normal_clear", "unlock_hard_clear",
		"unlock_endless_depth", "unlock_kills", "unlock_achievement", "unlock_price"]
	var mutex_ok := true
	var mutex_bad := ""
	for c2: Dictionary in CharacterTable.CHARACTERS:
		var n := 0
		for g in gate_keys:
			if c2.has(g):
				n += 1
		if n > 1:
			mutex_ok = false
			mutex_bad = String(c2.id)
	_check("M1e 解锁门互斥（每角色至多一种门键；sentinel 免费无门）", mutex_ok,
		"bad=%s" % mutex_bad)
	# has_skill 契约：全表唯 fission no_skill（G1 机制组/HUD 技能键可见性消费口）
	var no_skill_ids: Array[String] = []
	for c3: Dictionary in CharacterTable.CHARACTERS:
		if bool(c3.get("no_skill", false)):
			no_skill_ids.append(String(c3.id))
	_check("M1f has_skill 契约：no_skill 唯 fission（其余 12 角色含三新均有技能）",
		no_skill_ids.size() == 1 and no_skill_ids[0] == "fission",
		"got=%s" % str(no_skill_ids))


# ══ M2：新角色条目（R247 落表数值真源 _channels.md §1.4） ══
func _test_m2_new_characters() -> void:
	print("── M2：新角色条目（medic/vortex/reaper） ──")
	var medic: Dictionary = CharacterTable.get_character(&"medic")
	var vortex: Dictionary = CharacterTable.get_character(&"vortex")
	var reaper: Dictionary = CharacterTable.get_character(&"reaper")
	_check("M2a medic：战地医师·苏 / 血 75 / 攻 +0% / 门 unlock_endless_depth=20 / 「应急修复」回复 30% +4s 减半",
		String(medic.get("name", "")) == "战地医师·苏"
			and absf(float(medic.get("hp", 0.0)) - 75.0) <= 0.01
			and absf(float(medic.get("atk_pct", 1.0))) <= 0.001
			and int(medic.get("unlock_endless_depth", 0)) == 20
			and String(medic.get("skill_name", "")) == "应急修复"
			and String(medic.get("skill_desc", "")).contains("30%")
			and String(medic.get("skill_desc", "")).contains("减半"))
	_check("M2b vortex：坍缩者·汐 / 血 55 / 攻 +10% / 门 unlock_endless_depth=50 / 「奇点坍缩」3s 牵引 + 120% 末爆",
		String(vortex.get("name", "")) == "坍缩者·汐"
			and absf(float(vortex.get("hp", 0.0)) - 55.0) <= 0.01
			and absf(float(vortex.get("atk_pct", 0.0)) - 0.10) <= 0.001
			and int(vortex.get("unlock_endless_depth", 0)) == 50
			and String(vortex.get("skill_name", "")) == "奇点坍缩"
			and String(vortex.get("skill_desc", "")).contains("3 秒")
			and String(vortex.get("skill_desc", "")).contains("120%"))
	_check("M2c reaper：处刑者·刈 / 血 50 / 攻 +20% / 门 unlock_price=240 / 「处决时刻」6s +50% 伤害窗",
		String(reaper.get("name", "")) == "处刑者·刈"
			and absf(float(reaper.get("hp", 0.0)) - 50.0) <= 0.01
			and absf(float(reaper.get("atk_pct", 0.0)) - 0.20) <= 0.001
			and int(reaper.get("unlock_price", 0)) == 240
			and String(reaper.get("skill_name", "")) == "处决时刻"
			and String(reaper.get("skill_desc", "")).contains("6 秒")
			and String(reaper.get("skill_desc", "")).contains("+50%"))
	# 三新角色非 no_skill / 非 random_dual（GameLoop 零改动契约）
	_check("M2d 三新角色均有技能且非随机双武（has_skill 真——普通版实现归 player.gd）",
		CharacterTable.has_skill(&"medic") and CharacterTable.has_skill(&"vortex")
			and CharacterTable.has_skill(&"reaper")
			and not medic.has("no_skill") and not medic.has("random_dual")
			and not vortex.has("random_dual") and not reaper.has("random_dual"))


# ══ M3：升华键 × 掷卡可用性一致性（R247 终修判据收紧回归锁） ══
func _test_m3_sublime_availability() -> void:
	print("── M3：升华键 × _sublime_available 一致性（终修回归锁） ──")
	# 表键面：存量 10 角色（含 fission 替代升华）两键非空；三新角色无键（升华版未设计）
	var new_ids: Array[String] = ["medic", "vortex", "reaper"]
	var old_ok := true
	var old_bad := ""
	var new_clean := true
	for c: Dictionary in CharacterTable.CHARACTERS:
		var cid := String(c.id)
		if new_ids.has(cid):
			if c.has("sublime_name") or c.has("sublime_desc"):
				new_clean = false
		elif String(c.get("sublime_name", "")) == "" or String(c.get("sublime_desc", "")) == "":
			old_ok = false
			old_bad = cid
	_check("M3a 存量 10 角色 sublime_name/sublime_desc 全量非空（升华文案真源落表）",
		old_ok, "bad=%s" % old_bad)
	_check("M3b 三新角色无 sublime 键（升华版未设计——掷卡侧须由判据拦截）", new_clean)
	# 一致性：13 角色 _sublime_available ⇔ sublime_desc 非空（R247 终修单判据）
	var gen := CardGenerator.new()
	var stub := StubChar.new()
	var avail_ok := true
	var avail_bad := ""
	for c2: Dictionary in CharacterTable.CHARACTERS:
		stub.character_id = c2.id
		var expect := String(c2.get("sublime_desc", "")) != ""
		if gen._sublime_available(stub) != expect:
			avail_ok = false
			avail_bad = "%s（avail=%s expect=%s）" % [String(c2.id),
				str(gen._sublime_available(stub)), str(expect)]
	_check("M3c 一致性：13 角色 _sublime_available ==（sublime_desc 非空）——单判据无 has_skill 旁路",
		avail_ok, "bad=%s" % avail_bad)
	# 三新角色逐一显式断言（破洞卡杜绝的读态锁——QA/评审 P0 收口）
	for new_cid: StringName in [&"medic", &"vortex", &"reaper"]:
		stub.character_id = new_cid
		_check("M3d %s 掷卡不可用（has_skill 真但表无 sublime_desc——「空文案+零行为」破洞卡杜绝）"
			% String(new_cid), not gen._sublime_available(stub))
	stub.free()
	# 动态读表证明（表键=唯一判据）：运行期临时注入 medic sublime_desc → 翻可用 → 还原。
	# const 表嵌套 Dictionary 引用共享（r246_sublime_cases T6 摘键同式）；冻结则源级锚兜底。
	var medic_entry: Dictionary = CharacterTable.get_character(&"medic")
	if not medic_entry.is_read_only():
		medic_entry["sublime_desc"] = "探针临时键（勿存）"
		var stub2 := StubChar.new()
		stub2.character_id = &"medic"
		var now_avail := gen._sublime_available(stub2)
		medic_entry.erase("sublime_desc")
		_check("M3e 动态读表：注入 sublime_desc 即翻可用 / 摘键即还原（表键=唯一判据）",
			now_avail and not medic_entry.has("sublime_desc"))
		stub2.free()
	else:
		_check("M3e 表嵌套冻结不可注入（源级锚兜底：单判据在源）",
			FileAccess.get_file_as_string("res://scripts/cards/card_generator.gd")
				.contains("return String(CharacterTable.get_character(cid).get(\"sublime_desc\", \"\")) != \"\""))


# ══ M4：无尽深度成就门（endless_depth 四档族 + 聚合计数） ══
func _test_m4_endless_gate() -> void:
	print("── M4：无尽深度成就门（四档族 / best_endless_depth 聚合 / 计数口一致） ──")
	# 四档族（模板展开 <type>_<target>；奖励 0/0/0/100——链终档唯一奖励点）
	var tiers: Dictionary = {}
	for a: Dictionary in Meta.ACHIEVEMENTS:
		if String(a.type) == "endless_depth":
			tiers[int(a.target)] = a
	_check("M4a endless_depth 四档在册（10/20/30/50，奖励 0/0/0/100）",
		ters_ok(tiers), "tiers=%s" % str(tiers.keys()))
	_check("M4b 成就桶注册：_ach_by_type[endless_depth] 恰 4 条",
		Meta._ach_by_type.has("endless_depth")
			and (Meta._ach_by_type["endless_depth"] as Array).size() == 4)
	# 聚合读口（跨图跨 #1/#2 分档取最大；脏值降级不崩）
	var bk_mr: Dictionary = Meta.map_records.duplicate(true)
	Meta.map_records = {}
	var best0: int = Meta.best_endless_depth()
	Meta.map_records = {"world_grass": {"endless_depth": 3},
		"world_frost#1": {"endless_depth": 7}, "world_swamp#2": {"endless_depth": 5}}
	var best_mix: int = Meta.best_endless_depth()
	Meta.map_records = {"world_grass": {"best_wave": 12}, "dirty": 42}
	var best_dirty: int = Meta.best_endless_depth()
	Meta.map_records = bk_mr
	_check("M4c best_endless_depth 聚合：空表 0 / 混合分档键取最大 7 / 缺键与脏值降级 0",
		best0 == 0 and best_mix == 7 and best_dirty == 0,
		"b0=%d mix=%d dirty=%d" % [best0, best_mix, best_dirty])
	# 计数口一致（成就检查链与角色门共用同源计数——_counter_value 私有口直读）
	Meta.map_records = {"world_grass": {"endless_depth": 23}}
	var counter: int = int(Meta._counter_value("endless_depth"))
	Meta.map_records = bk_mr
	_check("M4d 成就计数口与聚合读口同源（_counter_value(endless_depth)==best_endless_depth）",
		counter == 23, "counter=%d" % counter)


func ters_ok(p_tiers: Dictionary) -> bool:
	# M4a 四档判（独立小函数防单行过长）
	if p_tiers.size() != 4:
		return false
	for t in [10, 20, 30, 50]:
		if not p_tiers.has(t):
			return false
	return int(p_tiers[10].get("reward", -1)) == 0 \
		and int(p_tiers[20].get("reward", -1)) == 0 \
		and int(p_tiers[30].get("reward", -1)) == 0 \
		and int(p_tiers[50].get("reward", -1)) == 100


# ══ M5：解锁判定链（13 角色门型矩阵——is_character_unlocked 全分支） ══
func _test_m5_unlock_matrix() -> void:
	print("── M5：解锁判定矩阵（零基线 → 逐门翻转；判定链 meta_manager.gd:389-417） ──")
	var bk_mr: Dictionary = Meta.map_records.duplicate(true)
	var bk_mc: Dictionary = Meta.maps_cleared.duplicate(true)
	var bk_ad: Dictionary = Meta.achievements_done.duplicate(true)
	var bk_uc: Dictionary = Meta.unlocked_characters.duplicate(true)
	var bk_rec: Dictionary = Meta.records.duplicate(true)
	var bk_cry: int = Meta.crystals
	# 零基线：除 sentinel（免费底座）外 12 角色全锁
	Meta.map_records = {}
	Meta.maps_cleared = {}
	Meta.achievements_done = {}
	Meta.unlocked_characters = {}
	Meta.records = {"best_wave": 0, "best_kills": 0, "best_level": 1,
		"total_runs": 0, "total_kills": 0}
	var all_locked := true
	var locked_bad := ""
	for c: Dictionary in CharacterTable.CHARACTERS:
		var unlocked := Meta.is_character_unlocked(c.id)
		var expect_unlocked := String(c.id) == "sentinel"
		if unlocked != expect_unlocked:
			all_locked = false
			locked_bad = String(c.id)
	_check("M5a 零基线：仅 sentinel 解锁（免检门），其余 12 角色全锁", all_locked,
		"bad=%s" % locked_bad)
	# 通关门 ×3（veles ①草原 / bulwark ②冰原 / mank ⑤沼泽——maps_cleared 直置）
	Meta.mark_map_cleared(&"world_grass")
	_check("M5b 通关门：veles（①晴空草原 maps_cleared）翻转 / bulwark·mank 仍锁",
		Meta.is_character_unlocked(&"veles")
			and not Meta.is_character_unlocked(&"bulwark")
			and not Meta.is_character_unlocked(&"mank"))
	Meta.mark_map_cleared(&"world_frost")
	Meta.mark_map_cleared(&"world_swamp")
	_check("M5c 通关门：bulwark（②寒霜冰原）+ mank（⑤翠毒沼泽）翻转",
		Meta.is_character_unlocked(&"bulwark") and Meta.is_character_unlocked(&"mank"))
	# 分档门 ×2（fission 普通档 / echo 困难档——map_records best_wave ≥ final_wave）
	var fw := int(MapTable.get_map(&"world_grass").get("final_wave", 1 << 30))
	Meta.map_records = {"world_grass": {"best_wave": fw}}
	_check("M5d fission：普通档通关记录（best_wave==final_wave 无 # 后缀）→ 解锁 / echo 仍锁",
		Meta.is_character_unlocked(&"fission") and not Meta.is_character_unlocked(&"echo"))
	Meta.map_records = {"world_grass#1": {"best_wave": fw}}
	_check("M5e echo：困难档记录（#1 键）→ 解锁（剥后缀查表口径）/ fission 回锁（仅普档键）",
		Meta.is_character_unlocked(&"echo") and not Meta.is_character_unlocked(&"fission"))
	# 深度门 ×2（阈值边界：19/20、49/50——#2 键同样驱动，聚合口径）
	Meta.map_records = {"world_swamp#2": {"endless_depth": 19}}
	_check("M5f 深度门边界：19 层 medic/vortex 双锁（阈值 20/50）",
		not Meta.is_character_unlocked(&"medic") and not Meta.is_character_unlocked(&"vortex"))
	Meta.map_records = {"world_swamp#2": {"endless_depth": 20}}
	_check("M5g 深度门边界：20 层（地狱 #2 键）medic 解锁 / vortex 仍锁",
		Meta.is_character_unlocked(&"medic") and not Meta.is_character_unlocked(&"vortex"))
	Meta.map_records = {"world_swamp#2": {"endless_depth": 50}}
	_check("M5h 深度门边界：50 层 vortex 解锁（链终双奖：成就 +100 与角色门同沿）",
		Meta.is_character_unlocked(&"vortex"))
	# 击杀门（vera：图鉴累计 500——records.total_kills）
	Meta.records = {"best_wave": 0, "best_kills": 0, "best_level": 1,
		"total_runs": 0, "total_kills": 499}
	_check("M5i 击杀门边界：499 vera 锁 / 500 翻转（records.total_kills）",
		not Meta.is_character_unlocked(&"vera"))
	Meta.records["total_kills"] = 500
	_check("M5i 击杀门边界：500 vera 解锁", Meta.is_character_unlocked(&"vera"))
	# 成就门（noah：wave_20「深入敌阵」——achievements_done 直置）
	_check("M5j 成就门：未达成 wave_20 时 noah 锁", not Meta.is_character_unlocked(&"noah"))
	Meta.achievements_done = {"wave_20": true}
	_check("M5j 成就门：wave_20 达成 noah 解锁", Meta.is_character_unlocked(&"noah"))
	# 购买门 ×3（价梯 80/160/240——unlocked_characters 永久键 + purchase_character 扣费）
	_check("M5k 价梯表键：ranger 80 / zero 160 / reaper 240（结晶价梯 80→160→240 顺延）",
		int(CharacterTable.get_character(&"ranger").get("unlock_price", 0)) == 80
			and int(CharacterTable.get_character(&"zero").get("unlock_price", 0)) == 160
			and int(CharacterTable.get_character(&"reaper").get("unlock_price", 0)) == 240)
	Meta.crystals = 80
	var bought: bool = Meta.purchase_character(&"ranger")
	_check("M5l 购买门：80 结晶恰足买 ranger（扣费归零 + 永久解锁 / zero·reaper 仍锁）",
		bought and Meta.crystals == 0 and Meta.is_character_unlocked(&"ranger")
			and not Meta.is_character_unlocked(&"zero")
			and not Meta.is_character_unlocked(&"reaper"))
	# 门-成就同步（depth 20：medic 门与 endless_depth_20 成就同源同阈值）
	Meta.map_records = {"world_grass": {"endless_depth": 20}}
	Meta.achievements_done = {}
	Meta._check_achievements()
	var sync_ok: bool = Meta.is_character_unlocked(&"medic") \
		and Meta.is_ach_done(&"endless_depth_20")
	_check("M5m 门-成就同步：深度 20 落账后 medic 解锁 ⇔ endless_depth_20 达成（同源同阈值）",
		sync_ok)
	# 还原（全量）
	Meta.map_records = bk_mr
	Meta.maps_cleared = bk_mc
	Meta.achievements_done = bk_ad
	Meta.unlocked_characters = bk_uc
	Meta.records = bk_rec
	Meta.crystals = bk_cry


# ══ M6：R245 内容扩容契约锁（成就总数/奖励/封顶——设计 §4.2/§8 流C 指定本文件承载） ══
func _test_m6_r245_content_locks() -> void:
	print("── M6：R245 内容扩容锁（160 条 / 1800 ≤ 1850 / B 组计数口全注册） ──")
	# M6a 总数：135→160（A 组首局保底 5 + B 组 9 族 20）
	_check("M6a 成就总数 == 160（R245 内容扩容：135 + A 组 5 + B 组 20）",
		Meta.ACHIEVEMENTS.size() == 160, "n=%d" % Meta.ACHIEVEMENTS.size())
	# M6b 奖励总额 == 1800（新增 25 条合计 235：A 组 35 + B 组 200）
	var reward_sum := 0
	for a: Dictionary in Meta.ACHIEVEMENTS:
		reward_sum += int(a.get("reward", 0))
	_check("M6b 全表总奖励 == 1800 ≤ 封顶 1850（结晶经济同步核）",
		reward_sum == 1800 and reward_sum <= 1850, "sum=%d" % reward_sum)
	# M6c B 组 9 族计数口全注册（_counter_value + _check_achievements counters 双口——
	# 漏登记 = 补检永久漏检，R192 注释口径）；敌族 def.enemy 子键路径既有覆盖不重测
	var bk_rec: Dictionary = Meta.records.duplicate(true)
	var bk_rl: Dictionary = Meta.codex_relics.duplicate(true)
	Meta.records = {"best_wave": 0, "best_kills": 0, "best_level": 1,
		"total_runs": 0, "total_kills": 0}
	Meta.records["total_skill_casts"] = 500
	Meta.records["total_deaths"] = 50
	Meta.records["total_graze"] = 2000
	Meta.records["total_blocks"] = 1000
	Meta.records["total_milestones"] = 30
	Meta.records["total_revives"] = 15
	Meta.records["total_rerolls"] = 100
	Meta.records["total_alarms"] = 20
	var cv_ok := true
	var cv_bad := ""
	for pair in [["total_skill_casts", 500], ["total_deaths", 50], ["total_graze", 2000],
			["total_blocks", 1000], ["total_milestones", 30], ["total_revives", 15],
			["total_rerolls", 100], ["total_alarms", 20]]:
		if int(Meta._counter_value(String(pair[0]))) != int(pair[1]):
			cv_ok = false
			cv_bad = String(pair[0])
	_check("M6c B 组 8 累计族 _counter_value 计数口全注册（值直读）", cv_ok, "bad=%s" % cv_bad)
	Meta.codex_relics = {}
	for i in range(40):
		Meta.codex_relics["REL_%02d" % i] = true
	_check("M6d codex_relics 计数口：收录 40 → _counter_value == 40（全遗之主链终口径；R252C 池 34 + R253 六件）",
		int(Meta._counter_value("codex_relics")) == 40)
	# M6e 全表补检口含 9 新键（_check_achievements counters 字典——静态字段无，行为级代验：
	# 满计数全表扫后 9 族链终全解锁；本组 achievements_done 由 M5 已还原，此处再备份）
	var bk_ad2: Dictionary = Meta.achievements_done.duplicate(true)
	var bk_cry2: int = Meta.crystals
	Meta.achievements_done = {}
	Meta.crystals = 0
	Meta._check_achievements()
	var chain_ok := Meta.is_ach_done(&"total_skill_casts_500") \
		and Meta.is_ach_done(&"total_deaths_50") and Meta.is_ach_done(&"total_graze_2000") \
		and Meta.is_ach_done(&"total_blocks_1000") and Meta.is_ach_done(&"total_milestones_30") \
		and Meta.is_ach_done(&"total_revives_15") and Meta.is_ach_done(&"total_rerolls_100") \
		and Meta.is_ach_done(&"total_alarms_20") and Meta.is_ach_done(&"codex_relics_40")   # R253 targets 34→40（id 随档派生）
	_check("M6e 满计数全表扫：9 族链终全解锁（counters 字典 9 键注册的行为级代验）", chain_ok)
	Meta.achievements_done = bk_ad2
	Meta.crystals = bk_cry2
	Meta.records = bk_rec
	Meta.codex_relics = bk_rl


# ── 假人（_sublime_available 形参 Node 域 character_id 读口） ──
class StubChar extends Node:
	var character_id: StringName = &"sentinel"
