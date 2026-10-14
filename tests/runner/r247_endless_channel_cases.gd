# tests/runner/r247_endless_channel_cases.gd
# R247「渠道矩阵扩充」用例体（由 test_r247_endless_channel.gd 入口在 autoload 就绪后
# 运行时加载）。六断言组分组见入口头注；设计真源 docs/design/sublime/_channels.md §7。
# 纪律：headless 测试档自动隔离（meta_save_test.cfg）+ 首尾快照/还原 Meta 全量运行态
# 防跨套件污染（r245 同式）；组内再自备份/自还原（r191 F17 同式）。纯 Meta 域——
# 零场景零 add_child；数值断言一律对 MapTable final_wave 真值派生，禁止硬抄波数。
extends RefCounted

var tree: SceneTree
var _pass := 0
var _fail := 0
var _failures: Array[String] = []
var _bk: Dictionary = {}


func run(p_tree: SceneTree) -> void:
	tree = p_tree
	seed(247)
	_snapshot_meta()
	_test_g1_table()
	_test_g2_best_read()
	_test_g3_gates()
	_test_g4_settle_chain()
	_test_g5_purchase()
	_test_g6_legacy_save()
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


# ── 快照/还原（r245_diff_star_cases 同式全量口径） ────────────────
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
	Meta.unlocked_characters = _bk["unlocked_characters"]
	Meta.upgrades = _bk["upgrades"]
	Meta.crystals = int(_bk["crystals"])
	Meta.character_id = _bk["character_id"]
	Meta.custom_weapon_id = String(_bk["custom_weapon_id"])
	Meta.set_run_map(MapTable.FIRST_MAP_ID)
	Meta.set_run_difficulty(0)
	Meta.set_run_daily(false)
	Meta._save()


# ── 夹具口 ─────────────────────────────────────────────────────
func _final_wave(p_map_id: StringName) -> int:
	return int(MapTable.get_map(p_map_id).get("final_wave", 1 << 30))


func _tier(p_tiers: Dictionary, p_target: int) -> Dictionary:
	# endless_depth 族档位条目（缺档 → 空 Dictionary）
	var a: Variant = p_tiers.get(p_target, null)
	if a is Dictionary:
		return a as Dictionary
	return {}


func _run_crystals(p_wave: int) -> int:
	# 局结算结晶产出期望值（kills=0 / 难度 0——与 _settle_run_result 同式派生）
	return int(ceil((p_wave * 1.5 + 0.0 / 25.0) * GameConst.difficulty_crystal_mult(0)))


# ══ G1：表结构（13 角色 + sublime 键 + endless_depth 成就族） ══
func _test_g1_table() -> void:
	print("── G1：表结构（13 角色 / sublime 两键 / endless_depth 成就族） ──")
	_check("G1a CharacterTable：13 角色（R247 +3——medic/vortex/reaper）",
		CharacterTable.count() == 13 and CharacterTable.CHARACTERS.size() == 13,
		"count=%d" % CharacterTable.count())
	# 三新角色条目键齐（数值真源 _channels.md §1.4）
	var medic: Dictionary = CharacterTable.get_character(&"medic")
	var vortex: Dictionary = CharacterTable.get_character(&"vortex")
	var reaper: Dictionary = CharacterTable.get_character(&"reaper")
	_check("G1b medic 键齐：血 75 / 攻 +0% / 门 unlock_endless_depth:20 / 技能「应急修复」/ cd 120",
		String(medic.get("name", "")) == "战地医师·苏"
		and absf(float(medic.get("hp", 0.0)) - 75.0) <= 0.01
		and absf(float(medic.get("atk_pct", 1.0)) - 0.0) <= 0.001
		and int(medic.get("unlock_endless_depth", 0)) == 20
		and String(medic.get("skill_name", "")) == "应急修复"
		and absf(float(medic.get("cd", 0.0)) - 120.0) <= 0.01)
	_check("G1c vortex 键齐：血 55 / 攻 +10% / 门 unlock_endless_depth:50 / 技能「奇点坍缩」/ cd 120",
		String(vortex.get("name", "")) == "坍缩者·汐"
		and absf(float(vortex.get("hp", 0.0)) - 55.0) <= 0.01
		and absf(float(vortex.get("atk_pct", 0.0)) - 0.10) <= 0.001
		and int(vortex.get("unlock_endless_depth", 0)) == 50
		and String(vortex.get("skill_name", "")) == "奇点坍缩"
		and absf(float(vortex.get("cd", 0.0)) - 120.0) <= 0.01)
	_check("G1d reaper 键齐：血 50 / 攻 +20% / 门 unlock_price:240 / 技能「处决时刻」/ cd 120",
		String(reaper.get("name", "")) == "处刑者·刈"
		and absf(float(reaper.get("hp", 0.0)) - 50.0) <= 0.01
		and absf(float(reaper.get("atk_pct", 0.0)) - 0.20) <= 0.001
		and int(reaper.get("unlock_price", 0)) == 240
		and String(reaper.get("skill_name", "")) == "处决时刻"
		and absf(float(reaper.get("cd", 0.0)) - 120.0) <= 0.01)
	_check("G1e 三新角色均有技能（has_skill 契约——非 no_skill/random_dual，GameLoop 零改动）",
		CharacterTable.has_skill(&"medic") and CharacterTable.has_skill(&"vortex")
		and CharacterTable.has_skill(&"reaper")
		and not medic.has("no_skill") and not vortex.has("random_dual"))
	# 10 存量角色 sublime 两键（cards _make_sublime_card/_sublime_available 只读此键）
	var sublime_ok := true
	var sublime_detail := ""
	var new_ids: Array[String] = ["medic", "vortex", "reaper"]
	for c: Dictionary in CharacterTable.CHARACTERS:
		if new_ids.has(String(c.id)):
			continue
		if String(c.get("sublime_name", "")) == "" or String(c.get("sublime_desc", "")) == "":
			sublime_ok = false
			sublime_detail = String(c.id)
	_check("G1f 存量 10 角色 sublime_name/sublime_desc 全量非空（R246 升华卡文案真源落表）",
		sublime_ok, "缺键=%s" % sublime_detail)
	_check("G1g fission 替代升华「本命同调」：sublime_desc 含同调层数口径",
		String(CharacterTable.get_character(&"fission").get("sublime_name", "")) == "本命同调"
		and String(CharacterTable.get_character(&"fission").get("sublime_desc", "")).contains("同调层"))
	_check("G1h 三新角色暂无 sublime 键（升华版未设计——cards/sublime 可用性归集成裁定）",
		not medic.has("sublime_name") and not vortex.has("sublime_name")
		and not reaper.has("sublime_name"))
	# endless_depth 成就族（模板展开 <type>_<target>）
	var tiers: Dictionary = {}
	for a: Dictionary in Meta.ACHIEVEMENTS:
		if String(a.type) == "endless_depth":
			tiers[int(a.target)] = a
	_check("G1i endless_depth 四档在册（endless_depth_10/20/30/50，奖励 0/0/0/100）",
		tiers.size() == 4
		and int(_tier(tiers, 10).get("reward", -1)) == 0
		and int(_tier(tiers, 20).get("reward", -1)) == 0
		and int(_tier(tiers, 30).get("reward", -1)) == 0
		and int(_tier(tiers, 50).get("reward", -1)) == 100,
		"tiers=%d r50=%s" % [tiers.size(), str(_tier(tiers, 50).get("reward", -1))])
	_check("G1j 链终档命名/desc：深渊尽头 · 「任意无尽模式深入 50 层」（与选人文案同词）",
		String(_tier(tiers, 50).get("name", "")) == "深渊尽头"
		and String(_tier(tiers, 50).get("desc", "")) == "任意无尽模式深入 50 层"
		and String(_tier(tiers, 10).get("name", "")) == "初窥深渊")
	_check("G1k 全表规模（11 手写 + 62 阶梯（R245 内容扩容 A 组 5 + B 组 20 并入）+ 87 单敌 = 160 ≤ 200 r191 口径）",
		Meta.ACHIEVEMENTS.size() == 160 and Meta.ACHIEVEMENTS.size() <= 200,
		"n=%d" % Meta.ACHIEVEMENTS.size())
	var reward_sum := 0
	for a2: Dictionary in Meta.ACHIEVEMENTS:
		reward_sum += int(a2.get("reward", 0))
	_check("G1l 全表总奖励 1800 ≤ 1850 新封顶（预算 1565→1800 / 封顶 1600→1850 同步——R245 成就+图鉴扩容批 +235）",
		reward_sum == 1800, "sum=%d" % reward_sum)
	_check("G1m 成就桶注册：_ach_by_type[endless_depth] 恰 4 条（_ready 展开后分桶）",
		Meta._ach_by_type.has("endless_depth")
		and (Meta._ach_by_type["endless_depth"] as Array).size() == 4)


# ══ G2：聚合读口 best_endless_depth（跨键取最大） ══
func _test_g2_best_read() -> void:
	print("── G2：聚合读口 best_endless_depth（无后缀/#1/#2 全键取最大） ──")
	var bk_mr: Dictionary = Meta.map_records.duplicate(true)
	Meta.map_records = {}
	_check("G2a 空表 → 0", Meta.best_endless_depth() == 0)
	Meta.map_records = {
		"world_grass": {"endless_depth": 3},
		"world_frost#1": {"endless_depth": 7},
		"world_swamp#2": {"endless_depth": 5},
	}
	_check("G2b 三键各深度 3/7/5（无后缀/#1/#2）→ 聚合取最大 7",
		Meta.best_endless_depth() == 7, "got=%d" % Meta.best_endless_depth())
	_check("G2c 旧读口 endless_depth() 语义不动：分图只认无后缀键（grass=3 / frost 无键=0）",
		Meta.endless_depth(&"world_grass") == 3 and Meta.endless_depth(&"world_frost") == 0)
	Meta.map_records = {"world_grass": {"best_wave": 12}}
	_check("G2d 旧档记录缺 endless_depth 键 → 聚合 0（降级不崩）",
		Meta.best_endless_depth() == 0)
	Meta.map_records = {"dirty": 42}
	_check("G2e 非字典脏值记录 → 跳过不崩（is Dictionary 守卫）",
		Meta.best_endless_depth() == 0)
	Meta.map_records = bk_mr


# ══ G3：角色门 unlock_endless_depth（阈值边界 + 分档驱动） ══
func _test_g3_gates() -> void:
	print("── G3：角色门（medic 20 / vortex 50 · #1/#2 分档键同样驱动） ──")
	var bk_mr: Dictionary = Meta.map_records.duplicate(true)
	Meta.map_records = {}
	_check("G3a 深度 0：medic/vortex 双锁",
		not Meta.is_character_unlocked(&"medic") and not Meta.is_character_unlocked(&"vortex"))
	Meta.map_records = {"world_grass": {"best_wave": 29, "endless_depth": 19}}
	_check("G3b 深度 19（无后缀键）：双锁仍持（阈值 20/50）",
		not Meta.is_character_unlocked(&"medic") and not Meta.is_character_unlocked(&"vortex"))
	Meta.map_records["world_grass"]["endless_depth"] = 20
	_check("G3c 深度 20：medic 解锁 / vortex 仍锁",
		Meta.is_character_unlocked(&"medic") and not Meta.is_character_unlocked(&"vortex"))
	Meta.map_records = {"world_frost#1": {"best_wave": 65, "endless_depth": 50}}
	_check("G3d 困难键（#1）深度 50：vortex 解锁（分档盲区修复——聚合口吃 #N 键）且 medic 恒开",
		Meta.is_character_unlocked(&"vortex") and Meta.is_character_unlocked(&"medic"))
	Meta.map_records = {"world_swamp#2": {"best_wave": 80, "endless_depth": 49}}
	_check("G3e 地狱键（#2）深度 49：vortex 锁（49 < 50 阈值边界）",
		not Meta.is_character_unlocked(&"vortex"))
	_check("G3f reaper 不随深度解锁（唯一直购门 240 结晶）",
		not Meta.is_character_unlocked(&"reaper"))
	Meta.map_records = bk_mr


# ══ G4：结算全链（深度落账 → 阶梯成就 → 角色门；每日局分流） ══
func _test_g4_settle_chain() -> void:
	print("── G4：结算全链（GAME_OVER 落账 + 阶梯成就 + 50 档 +100 结晶） ──")
	var bk_done: Dictionary = Meta.achievements_done.duplicate()
	var bk_records: Dictionary = Meta.records.duplicate()
	var bk_crystals: int = Meta.crystals
	var bk_mr: Dictionary = Meta.map_records.duplicate(true)
	var bk_daily: Dictionary = Meta.daily_records.duplicate(true)
	# 清残留单局计数（前置局尾结算改道 grass——其落账随后被零基线整体覆盖）
	Meta.set_run_daily(false)
	Meta.set_run_map(&"world_grass")
	Meta.set_run_difficulty(0)
	Meta._on_state_changed(GameConst.GameStatus.GAME_OVER)
	# 零基线：记录/结晶/分图全零；成就预置「除无尽深度族外全达成」——跨族噪声归零
	#（结晶增量因此只含局产出 + endless_depth 族奖励，可精确对账）
	Meta.records = {"best_wave": 0, "best_kills": 0, "best_level": 1,
		"total_runs": 0, "total_kills": 0}
	Meta.crystals = 0
	Meta.map_records = {}
	Meta.achievements_done = {}
	for a: Dictionary in Meta.ACHIEVEMENTS:
		if String(a.type) != "endless_depth":
			Meta.achievements_done[String(a.id)] = true
	# 每日局分流：只记 daily_best——不写深度、不解锁（与 fission/echo 口径一致）
	var frost_final := _final_wave(&"world_frost")
	# R253 自净：daily_record 落盘且按当日 key 取历史最大——同日复跑/前序每日用例的
	# best 残留会压死本组「照记 ==frost+80」断言（实测 233>95 恒真），段前清当日键
	Meta.daily_records.erase(Meta.daily_date_key())
	Meta.set_run_daily(true)
	Meta.set_run_map(&"world_frost")
	Meta._on_wave_started(frost_final + 80)
	Meta._on_state_changed(GameConst.GameStatus.GAME_OVER)
	_check("G4a 每日局分流：不落 map_records（深度零落账）且聚合 0",
		Meta.map_records.is_empty() and Meta.best_endless_depth() == 0,
		"mr=%s best=%d" % [str(Meta.map_records.keys()), Meta.best_endless_depth()])
	_check("G4b 每日局：不解锁无尽深度成就 + 零结晶产出（分流早退）",
		not Meta.is_ach_done(&"endless_depth_10") and Meta.crystals == 0)
	_check("G4c 每日局：daily_best 照记（best_wave = final+80）",
		int(Meta.daily_record("").get("best_wave", 0)) == frost_final + 80)
	Meta.set_run_daily(false)
	# 常规局全链：grass final+10 → 深度 10（入门档解锁·零结晶）
	var fw := _final_wave(&"world_grass")
	Meta.set_run_map(&"world_grass")
	Meta.set_run_difficulty(0)
	Meta._on_wave_started(fw + 10)
	Meta._on_state_changed(GameConst.GameStatus.GAME_OVER)
	_check("G4d 深度 10 落账：endless_depth_10 解锁 / 20 档未达 / 分图读口同步",
		Meta.endless_depth(&"world_grass") == 10 and Meta.best_endless_depth() == 10
		and Meta.is_ach_done(&"endless_depth_10")
		and not Meta.is_ach_done(&"endless_depth_20"))
	_check("G4e 深度 10：medic 仍锁（19<20）且中间档零结晶通胀（结晶=局产出）",
		not Meta.is_character_unlocked(&"medic")
		and Meta.crystals == _run_crystals(fw + 10),
		"cry=%d exp=%d" % [Meta.crystals, _run_crystals(fw + 10)])
	# 深度 20：medic 门翻转（与 endless_depth_20 同源同阈值——解锁时刻恒同步）
	Meta._on_wave_started(fw + 20)
	Meta._on_state_changed(GameConst.GameStatus.GAME_OVER)
	_check("G4f 深度 20：endless_depth_20 解锁 + medic 解锁 / vortex 仍锁（门-成就同步边沿）",
		Meta.is_ach_done(&"endless_depth_20") and Meta.is_character_unlocked(&"medic")
		and not Meta.is_character_unlocked(&"vortex"))
	_check("G4g 深度 20：结晶累计 = 两局产出（20 档奖励 0）",
		Meta.crystals == _run_crystals(fw + 10) + _run_crystals(fw + 20),
		"cry=%d" % Meta.crystals)
	# 深度 50：30/50 档连发 + 链终 100 结晶 + vortex 门翻转
	Meta._on_wave_started(fw + 50)
	Meta._on_state_changed(GameConst.GameStatus.GAME_OVER)
	_check("G4h 深度 50：30/50 档齐解锁 + vortex 解锁（终局双奖励：成就+角色）",
		Meta.is_ach_done(&"endless_depth_30") and Meta.is_ach_done(&"endless_depth_50")
		and Meta.is_character_unlocked(&"vortex"))
	_check("G4i 深度 50：结晶增量 = 局产出 + 100（链终档唯一奖励点）",
		Meta.crystals == _run_crystals(fw + 10) + _run_crystals(fw + 20)
		+ _run_crystals(fw + 50) + 100,
		"cry=%d exp=%d" % [Meta.crystals, _run_crystals(fw + 10)
			+ _run_crystals(fw + 20) + _run_crystals(fw + 50) + 100])
	# 还原
	Meta.achievements_done = bk_done
	Meta.records = bk_records
	Meta.crystals = bk_crystals
	Meta.map_records = bk_mr
	Meta.daily_records = bk_daily


# ══ G5：购买门（reaper 240 三拒 + 扣费解锁） ══
func _test_g5_purchase() -> void:
	print("── G5：购买门（reaper 240 结晶：不足/已购/无价格三拒 + 扣费解锁） ──")
	var bk_crystals: int = Meta.crystals
	var bk_unlocked: Dictionary = Meta.unlocked_characters.duplicate()
	Meta.unlocked_characters = {}
	Meta.crystals = 239
	_check("G5a 结晶 239 不足（240 门）→ 拒购且不解锁",
		not Meta.purchase_character(&"reaper")
		and not Meta.is_character_unlocked(&"reaper"))
	Meta.crystals = 240
	_check("G5b 240 恰足 → 购买成功 + 扣费归零 + 永久解锁（unlocked_characters 落键）",
		Meta.purchase_character(&"reaper") and Meta.crystals == 0
		and Meta.is_character_unlocked(&"reaper")
		and Meta.unlocked_characters.has("reaper"))
	_check("G5c 已购重复购买 → false（幂等拒）",
		not Meta.purchase_character(&"reaper"))
	Meta.crystals = 1000
	_check("G5d 无价格角色拒购：medic（unlock_endless_depth 门，price=0）→ false 且不写购",
		not Meta.purchase_character(&"medic")
		and not Meta.unlocked_characters.has("medic"))
	Meta.crystals = bk_crystals
	Meta.unlocked_characters = bk_unlocked.duplicate()


# ══ G6：旧档兼容（无新键记录 → 读 0 门锁；存档段结构零新增键） ══
func _test_g6_legacy_save() -> void:
	print("── G6：旧档兼容（无 endless_depth 键/成就键的存量档零迁移） ──")
	var bk_mr: Dictionary = Meta.map_records.duplicate(true)
	var bk_done: Dictionary = Meta.achievements_done.duplicate()
	Meta.map_records = {"world_grass": {"best_wave": 12, "best_kills": 3, "best_level": 2}}
	Meta.achievements_done = {}
	_check("G6a 旧档（记录无 endless_depth 键 / 成就无新键）：读口 0 + 双门锁 + 成就未达",
		Meta.best_endless_depth() == 0 and Meta.endless_depth(&"world_grass") == 0
		and not Meta.is_character_unlocked(&"medic")
		and not Meta.is_character_unlocked(&"vortex")
		and not Meta.is_ach_done(&"endless_depth_10"))
	var ac: Vector2i = Meta.achievement_count()
	_check("G6b 成就墙计数口不崩（面板消费口；总数 = 全表条数 ≥130）",
		ac.y == Meta.ACHIEVEMENTS.size() and ac.y >= 130, "y=%d n=%d" % [ac.y, Meta.ACHIEVEMENTS.size()])
	Meta._save()
	var cfg := ConfigFile.new()
	var loaded: bool = cfg.load(Meta.save_path()) == OK
	var ach_key_count: int = (cfg.get_section_keys("achievements") as Array).size() if loaded else -1
	var has_done: bool = (cfg.get_section_keys("achievements") as Array).has("done") if loaded else false
	_check("G6c 存档结构零新增键：achievements 段仍仅 done 键（门=派生谓词+achievements_done 既有键）",
		loaded and ach_key_count == 1 and has_done,
		"loaded=%s keys=%d" % [str(loaded), ach_key_count])
	Meta.map_records = bk_mr
	Meta.achievements_done = bk_done
