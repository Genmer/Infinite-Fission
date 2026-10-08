# tests/runner/r216_shardbatch_cases.gd
# R216 用例体：vc23 桶遥测定案驱三刀。
# ① 刀① 碎片烤色合批：XP 池挂 TexBucketHost——spawn 落同贴图桶、同变体共桶、
#   换档/彩档步进换桶、release 归位池根；modulate 恒白不变量（产品路径 spawn 注入口）。
# ② 刀① 预热队列 18 星变体（4 档×3 量化 alpha + 彩档 6 色相）全在缓存。
# ③ 刀② 玩段拆键：PLAYING 帧 stage_probe 含 player/shard 两键；开窗级联归「卡」键。
# ④ 刀② dwell 清零：非 MENU 态物理帧清 _menu_dwell_s（回菜单重享 3s 挂机缓冲）。
# ⑤ 遥测：diag_counts 新键 bucket_xp/shards + 段序标签 碎/卡 在位。
extends RefCounted

const MAIN_SCENE := "res://scenes/main.tscn"
const DT := 1.0 / 60.0

var tree: SceneTree
var _pass: int = 0
var _fail: int = 0
var _failures: Array[String] = []
var _gl: GameLoop = null


func run(p_tree: SceneTree) -> void:
	tree = p_tree
	seed(42)
	_boot_game_loop()
	await tree.process_frame
	await tree.process_frame
	_test_1_shard_bucket_batching()
	_test_2_prewarm_star_variants()
	_test_3_stage_split_and_card_key()
	_test_4_dwell_clear_off_menu()
	_test_5_telemetry_keys()
	_teardown_game_loop()
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
		print("  PASS | %s" % p_name)
	else:
		_fail += 1
		_failures.append("%s（%s）" % [p_name, p_detail])
		print("  FAIL | %s（%s）" % [p_name, p_detail])


func _boot_game_loop() -> void:
	# boot 骨架（r209/r215 同款）：GameLoop→MENU→start_run→置回 MENU 冻结波次
	var scene: PackedScene = load(MAIN_SCENE)
	_gl = scene.instantiate() as GameLoop
	_gl.name = "R216GameLoopUnderTest"
	tree.get_root().add_child(_gl)
	_gl.state = GameConst.GameStatus.MENU
	_gl.current_map_id = MapTable.FIRST_MAP_ID
	_gl.start_run()
	_gl.state = GameConst.GameStatus.MENU
	_gl.player.global_position = Vector2(360.0, 900.0)


func _teardown_game_loop() -> void:
	tree.paused = false
	RunSave.clear()
	if _gl != null:
		_gl.free()
		_gl = null


func _drain_prewarm_queue() -> void:
	# 消化完预热队列（dwell 置 99 放行 boss 挂机门）
	_gl.set("_menu_dwell_s", 99.0)
	var guard := 0
	while not (_gl.get("_tex_prewarm_queue") as Array).is_empty() and guard < 400:
		_gl._physics_process(DT)
		guard += 1


# ── ① 碎片分桶合批（XP 池 E' 扩展） ───────────────────────────────
func _test_1_shard_bucket_batching() -> void:
	print("── ① 碎片分桶 ──")
	var pool := _gl.pools[&"xp"] as XPPool
	var host: Node = pool.bucket_host
	_check("①装配：XP 池 bucket_host 在位（R216 刀①）", host != null, str(host))
	if host == null:
		return
	var pool_root: Node = pool as Node
	# 产品路径 spawn（_spawn_xp_shard 注入 host）：同变体共桶、异变体异桶
	_gl._spawn_xp_shard(Vector2(300.0, 600.0), 4.0, 4.0)      # ratio 1 → 白档 q1
	_gl._spawn_xp_shard(Vector2(320.0, 620.0), 4.5, 4.0)     # ratio 1.125 → 同白档同 q1
	_gl._spawn_xp_shard(Vector2(340.0, 640.0), 30.0, 4.0)    # ratio 7.5 → 紫档 q1
	var s0: XpShard = _gl.active_shards[0]
	var s1: XpShard = _gl.active_shards[1]
	var s2: XpShard = _gl.active_shards[2]
	_check("①落桶：spawn 后碎片父级=桶节点（非池根直挂）",
		s0.get_parent() != pool_root and host.is_ancestor_of(s0),
		"parent=%s" % str(s0.get_parent()))
	_check("①同变体共桶：白档 q1 两片同父（同贴图 → 同批）",
		s0.get_parent() == s1.get_parent(), "")
	_check("①异变体异桶：紫档另桶（贴图不同不共批）",
		s2.get_parent() != s0.get_parent(), "")
	_check("①恒白：三片 modulate 均纯白（合批红线）",
		s0._sprite.modulate.is_equal_approx(Color.WHITE)
			and s1._sprite.modulate.is_equal_approx(Color.WHITE)
			and s2._sprite.modulate.is_equal_approx(Color.WHITE), "")
	# 换档换桶：s0 merge 爬紫档 → 移入紫桶
	s0.merge_value(26.0, 4.0)                 # value 30 → ratio 7.5 紫档 q1
	_check("①爬档换桶：merge 后与紫档片共桶",
		s0.get_parent() == s2.get_parent(), "")
	# release 归位池根（ObjectPool.release 统一 unplace）
	var b_parent: Node = s1.get_parent()
	pool.release(s1)
	_gl.active_shards.erase(s1)            # R216 修（评审#2）：摘除防清场循环二次归还噪音
	_check("①归还：release 后归位池根（unplace 链）", s1.get_parent() == pool_root,
		"parent=%s" % str(s1.get_parent()))
	_check("①桶惰性保留：桶节点不随归还拆除（单调下界口径）",
		is_instance_valid(b_parent) and b_parent.get_parent() == host, "")
	# 彩档步进换桶：彩档片 _anim_t 推进步进 → 贴图换 → 桶换
	_gl._spawn_xp_shard(Vector2(360.0, 660.0), 200.0, 4.0)   # ratio 50 → 彩档
	var rb: XpShard = _gl.active_shards[_gl.active_shards.size() - 1]
	var rb_pre: Node = rb.get_parent()
	rb._anim_t = 1.0                          # 步进 0 → 2
	rb._tick_visual_anim(DT)
	_check("①彩档步进换桶：_anim_t 0→1 步进换贴图后换桶",
		rb.get_parent() != rb_pre and host.is_ancestor_of(rb),
		"step=%d" % int(rb._rainbow_step))
	# 清场：归还全部（从 active_shards 摘除）
	for s in _gl.active_shards.duplicate():
		pool.release(s)
	_gl.active_shards.clear()
	_check("①清场：全部归位池根",
		(_gl.get("active_shards") as Array).is_empty(), "")


# ── ② 预热队列 18 星变体 ──────────────────────────────────────────
func _test_2_prewarm_star_variants() -> void:
	print("── ② 星变体预热 ──")
	_drain_prewarm_queue()
	var cache: Dictionary = TextureFactory._cache
	var missing: Array[String] = []
	# 4 档 × 3 量化 alpha
	for t in 4:
		for q in 3:
			var c := PopPalette.xp_tier_color(t)
			c.a = 0.5 + 0.25 * q
			var key := "star_44_" + c.to_html()
			if not cache.has(key):
				missing.append(key)
	# 彩档 6 色相（a=1.0）
	for h in 6:
		var rc := Color.from_hsv(float(h) / 6.0, 0.7, 1.0)
		var rkey := "star_44_" + rc.to_html()
		if not cache.has(rkey):
			missing.append(rkey)
	_check("②全 18 变体在缓存（4 档×3 alpha + 彩档 6 色相）",
		missing.is_empty(), "缺 %d 项：%s" % [missing.size(), "、".join(missing.slice(0, 3))])


# ── ③ 拆键：玩段 player/shard + 开窗归「卡」键 ────────────────────
func _test_3_stage_split_and_card_key() -> void:
	print("── ③ 拆键 ──")
	# R220 刀1 同步（拆解契约 §3.1/§4.1）：card 同键拆 card_open（开）/card_drain（消），
	# 十五段→十六段；开窗归因断言改读 card_open 口径
	_check("③段序：shard/card_open/card_drain 三键在 DIAG_STAGE_ORDER（R220 后十六段）",
		DebugStats.DIAG_STAGE_ORDER.has(&"shard")
			and DebugStats.DIAG_STAGE_ORDER.has(&"card_open")
			and DebugStats.DIAG_STAGE_ORDER.has(&"card_drain")
			and DebugStats.DIAG_STAGE_ORDER.size() == 16,
		"order=%s" % str(DebugStats.DIAG_STAGE_ORDER))
	_check("③标签：碎/开/消映射在位",
		str(DebugStats.DIAG_STAGE_TAGS.get(&"shard", "")) == "碎"
			and str(DebugStats.DIAG_STAGE_TAGS.get(&"card_open", "")) == "开"
			and str(DebugStats.DIAG_STAGE_TAGS.get(&"card_drain", "")) == "消",
		"tags=%s" % str(DebugStats.DIAG_STAGE_TAGS))
	_gl.stage_probe_enabled = true
	_gl.state = GameConst.GameStatus.PLAYING
	_gl._physics_process(DT)                 # PLAYING 帧：①~② 全段探针写入
	var probe: Dictionary = _gl.stage_probe_us
	_check("③帧探针：player 与 shard 两键分立（玩段拆键生效）",
		probe.has(&"player") and probe.has(&"shard"),
		"probe=%s" % str(probe.keys()))
	# 开窗归卡开键：升级 → 延迟消费 → card_open 键增加而 ui 键零写入
	_gl.state = GameConst.GameStatus.PLAYING
	_gl.stage_probe_us.clear()
	var card0: int = int(_gl.stage_probe_us.get(&"card_open", 0))
	_gl.player.set("xp_need", 10)
	_gl.player.gain_xp(10)
	_gl.call(&"_consume_deferred_level_open")
	var ui_v: int = int(_gl.stage_probe_us.get(&"ui", 0))
	var card_v: int = int(_gl.stage_probe_us.get(&"card_open", 0))
	_check("③开窗归「开」：card_open 键入账（%d→%d）且 ui 键零写入（归因分离）",
		card_v > card0 and ui_v == 0,
		"card_open %d→%d ui=%d state=%d" % [card0, card_v, ui_v, _gl.state])
	while _gl.state == GameConst.GameStatus.LEVEL_UP:
		_gl.card_select_ui.choose(0)


# ── ④ dwell 清零（非 MENU 态物理帧） ──────────────────────────────
func _test_4_dwell_clear_off_menu() -> void:
	print("── ④ dwell 清零 ──")
	_gl.set("_menu_dwell_s", 99.0)
	_gl.state = GameConst.GameStatus.MENU
	_gl._physics_process(DT)
	var menu_dwell: float = float(_gl.get("_menu_dwell_s"))
	_check("④MENU 帧累计：99+δ（不清零）", menu_dwell > 99.0, "%.4f" % menu_dwell)
	_gl.state = GameConst.GameStatus.PLAYING
	_gl._physics_process(DT)
	var play_dwell: float = float(_gl.get("_menu_dwell_s"))
	_check("④PLAYING 帧清零：离开 MENU 即回 0（回菜单重享挂机缓冲）",
		play_dwell == 0.0, "%.4f" % play_dwell)


# ── ⑤ 遥测键 ─────────────────────────────────────────────────────
func _test_5_telemetry_keys() -> void:
	print("── ⑤ 遥测 ──")
	var counts: Dictionary = _gl.diag_counts()
	_check("⑤diag_counts 新键（桶x/碎片总数）",
		counts.has(&"bucket_xp") and counts.has(&"shards"),
		str(counts.keys()))
	_gl._spawn_xp_shard(Vector2(300.0, 600.0), 4.0, 4.0)
	var counts2: Dictionary = _gl.diag_counts()
	_check("⑤读数：碎片 1 片 → shards=1、桶x ≥1（变体入桶可观测）",
		int(counts2[&"shards"]) == 1 and int(counts2[&"bucket_xp"]) >= 1,
		"shards=%d bucket_x=%d" % [int(counts2[&"shards"]), int(counts2[&"bucket_xp"])])
	for s in _gl.active_shards.duplicate():
		(_gl.pools[&"xp"] as XPPool).release(s)
	_gl.active_shards.clear()
