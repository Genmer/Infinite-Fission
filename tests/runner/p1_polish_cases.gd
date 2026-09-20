# tests/runner/p1_polish_cases.gd
# P1 清账批次用例体（由 test_p1_polish.gd 入口在 autoload 就绪后运行时加载编译）。
# 真源：FEEDBACK_TRACKER.md 活跃池 R5.12-P1 三条（战前补给 / 金币词条 / 构筑提速三件套）。
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
	_test_pre_boss_shop()
	_test_gold_trait()
	_test_early_build_trio()
	_teardown_game_loop()
	print("────────────────────────────────────────")
	print("汇总：PASS %d / FAIL %d（共 %d 项）" % [_pass, _fail, _pass + _fail])
	if not _failures.is_empty():
		for f in _failures:
			print("  FAIL 详情：%s" % f)


func fail_count() -> int:
	return _fail


# ── 环境 ──────────────────────────────────────────────────────────
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


func _start_map(p_map: StringName) -> void:
	# 解锁链口径（verify_feedback 先例）：通关首关 → 目标图可启动
	Meta.maps_cleared = {}
	Meta.mark_map_cleared(&"world_grass")
	_gl.state = GameConst.GameStatus.MENU
	_gl.current_map_id = MapTable.FIRST_MAP_ID
	_gl._on_menu_start(p_map)


# ── 战前补给（R5.12-P1） ──────────────────────────────────────────
func _test_pre_boss_shop() -> void:
	print("── 战前补给商店 ──")
	_start_map(&"world_grass")
	var final_wave := int(MapTable.get_map(&"world_grass").get("final_wave", 0))
	_check("前置：草原 final_wave 在册（>1）", final_wave > 1)
	# 非 Boss 前一波：不开店
	_gl._on_wave_cleared_pre_boss_shop(final_wave - 3)
	_check("战前补给：普通波清空不开店", not _gl.shop_ui.is_shop_visible()
		and _gl.state == GameConst.GameStatus.PLAYING)
	# final 前一波清空 → 固定商店 + 战前补给标题
	_gl._on_wave_cleared_pre_boss_shop(final_wave - 1)
	_check("战前补给：Boss 前一波清空开店", _gl.shop_ui.is_shop_visible()
		and _gl.state == GameConst.GameStatus.LEVEL_UP)
	_check("战前补给：标题 = 战前补给",
		_gl.shop_ui._title != null and _gl.shop_ui._title.text == "战前补给")
	_gl.shop_ui.close()
	_check("战前补给：关店回 PLAYING", _gl.state == GameConst.GameStatus.PLAYING)
	# final 波清空：走胜利结算（victory pending），不开店
	_gl._on_wave_cleared_pre_boss_shop(final_wave)
	_check("战前补给：final 波清空不复开店", not _gl.shop_ui.is_shop_visible())
	# 黑市默认标题回归（常规开店路径不受污染）
	_gl._on_shop_requested(final_wave - 2)
	if _gl.state == GameConst.GameStatus.LEVEL_UP:
		_check("黑市：常规开店标题 = 战地黑市",
			_gl.shop_ui._title.text == "战地黑市")
		# R37 货架纯净：多轮重抽扫描——玩家侧池（经验/金币/磁吸/技能急速/血量）
		# 不得出现在黑市（全局生效词条配武器前缀 = 「【手枪】经验获取」错乱货）
		var junk_seen := false
		for round in range(12):
			_gl.shop_ui._reroll_wares(true)
			for ware: Dictionary in _gl.shop_ui._wares:
				if String(ware.get("kind", "")) != "trait":
					continue
				var td: TraitData = ware.get("data")
				if td != null and td.pool_id in GameConst.PLAYER_SIDE_POOLS:
					junk_seen = true
		_check("黑市：货架无玩家侧池词条（12 轮重抽纯净）", not junk_seen)
		_gl.shop_ui.close()
	else:
		_check("黑市：常规开店标题 = 战地黑市", false, "未进入 LEVEL_UP")


# ── 金币词条（R5.12-P1） ──────────────────────────────────────────
func _test_gold_trait() -> void:
	var data := _gl.registry.get_trait(&"AFF_GOLD")
	_check("AFF_GOLD：词条入注册表", data != null)
	if data == null:
		return
	_check("AFF_GOLD：pool=ADD / add_gold 通道 / gold_pct 消费键",
		int(data.pool) == GameConst.PoolClass.ADD
		and String(data.pool_id) == "add_gold"
		and String(data.params.get("stat", "")) == "gold_pct")
	_check("AFF_GOLD：卡面前缀【通用】（玩家侧池前缀纪律）",
		String(data.display_name).begins_with("【通用】"))
	# 消费端：挂卡（真 apply_choice 链路）→ Player.gold_find_pct() 跨武器聚合
	var hp_keep: int = int(_gl.player.get("gold"))
	var card := {
		"kind": CardGenerator.CardKind.TRAIT, "id": data.id, "rarity": 0,
		"data": data, "value_scale": 1.0,
		"display_name": data.display_name, "description": data.description,
	}
	_gl.card_generator.apply_choice(card, _gl.player)
	_check("消费端：挂卡后 gold_find_pct() = +20%", 
		absf(_gl.player.gold_find_pct() - 0.2) < 0.0001,
		"实得 %.3f" % _gl.player.gold_find_pct())
	_gl.player.set("gold", hp_keep)


# ── 前期构筑提速三件套（R5.12-P1） ────────────────────────────────
func _test_early_build_trio() -> void:
	var pistol: WeaponData = _gl.registry.get_weapon(&"W1_pistol")
	_check("提速③：手枪 L1 基伤 12→14", pistol != null
		and absf(pistol.upgrade_table[0].base_atk - 14.0) < 0.001)
	_check("提速③：手枪 L2 基伤 →16", pistol != null
		and absf(pistol.upgrade_table[1].base_atk - 16.0) < 0.001)
	# 提速②：槽2 解锁波 w3→w2（常量 + tick 分支同源）
	_check("提速②：槽2 解锁波 = 2", WaveDirector.SLOT2_UNLOCK_WAVE == 2)
	# 提速①：前期货架保底 ≥1 张武器卡（w<5/低级上下文扫描 24 次；需有空槽——
	# 开局单槽被手枪占满时武器池为空是既有口径，故模拟槽2 解锁后的 w2 场景）
	_gl.player.set("unlocked_slots", 2)
	var saw_weapon := false
	for i in range(24):
		var cards: Array = _gl.card_generator.generate_candidates(
			{"player": _gl.player, "wave": 2})
		for c: Dictionary in cards:
			if int(c.get("kind", -1)) == CardGenerator.CardKind.WEAPON:
				saw_weapon = true
		if saw_weapon:
			break
	_check("提速①：前期货架保底武器卡（24 次重抽扫描）", saw_weapon)
	# 权重上调在册（10→14）
	_check("提速①：WEAPON 类别权重 10→14",
		absf(float(CardGenerator.CATEGORY_WEIGHTS.get("WEAPON", 0.0)) - 14.0) < 0.001)
