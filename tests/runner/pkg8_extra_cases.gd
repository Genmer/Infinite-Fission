# tests/runner/pkg8_extra_cases.gd
# v0.8.0 验收补漏用例体（tester 独立验收；由 test_pkg8_extra.gd 入口在 autoload 就绪后运行时加载编译）。
# 只补 pkg8 未覆盖的验收点，夹具沿用 pkg8 的 GameLoop 完整 Boot 模式；不动业务代码。
# 确定性：全部依赖工程固定种子（副词条流 4243 / 事件流 777 / 卡牌流 42），无随机门值。
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
	_test_recount_v13_v14()                       # 文件对账 + 变体镜像 + 条数 ±3pt
	_test_handcalc_v15_v6()                       # 套装 max_hp 增量 / 诅咒手算 / 四参数公式
	_test_event_gaps_v1_v4()                      # 商店间隙零事件 / 0-1 边界 / 战斗冻结 / 祭坛钳 / 紫卡 floor
	_test_event_gate_wave_reset()                 # 审查 Critical 修复：事件闸随 start_wave 复位（每间隙一 roll）
	_test_character_edges_v18_v19()               # goto_menu 四态拒绝 / 全链零 rejected
	_test_dash_edges_v21_v22()                    # 无敌 0.15s 边界 / 活动区钳制 / 顿帧冻结
	_test_closure_v24()                           # version / PROGRESS 基线 / A7 R8
	_teardown_game_loop()
	# 汇总
	print("────────────────────────────────────────")
	print("汇总：PASS %d / FAIL %d（共 %d 项）" % [_pass, _fail, _pass + _fail])
	if not _failures.is_empty():
		for f in _failures:
			print("  FAIL 详情：%s" % f)


func fail_count() -> int:
	return _fail


# ── 环境引导（pkg8 夹具模式） ─────────────────────────────────────
func _ensure_autoloads() -> void:
	_check("autoload 就绪（EventBus/GameConfig/DebugStats）",
		EventBus != null and GameConfig != null and DebugStats != null)


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


# ══ V13/V14：文件对账 + 变体 stat_key 镜像 + 副词条条数 ±3pt 独立门值 ══
func _test_recount_v13_v14() -> void:
	print("── V13/V14 文件对账与条数门值 ──")
	var reg := _gl.registry
	# 文件系统对账：磁盘 .tres 数 == 注册表类目数（chips=12 / characters=3）
	var chip_files := _count_tres("res://resources/chips", "CHIP_")
	var char_files := _count_tres("res://resources/characters", "CHAR_")
	_check("文件系统对账：resources/chips CHIP_*.tres = 12 == registry.chips",
		chip_files == 12 and reg.chips.size() == 12,
		"files=%d reg=%d" % [chip_files, reg.chips.size()])
	_check("文件系统对账：resources/characters CHAR_*.tres = 3 == registry.characters",
		char_files == 3 and reg.characters.size() == 3,
		"files=%d reg=%d" % [char_files, reg.characters.size()])
	# 4 变体逐枚注册 + stat_key 与基础枚镜像（同键对可同时装备的数据前提）
	var mirror_ok := true
	for pair in [&"CHIP_ATK", &"CHIP_ROF", &"CHIP_CRIT", &"CHIP_HP"]:
		var base := reg.get_chip(pair)
		var variant := reg.get_chip(StringName(String(pair) + "2"))
		if base == null or variant == null or variant.stat_key != base.stat_key:
			mirror_ok = false
	_check("V13：4 变体（ATK2/ROF2/CRIT2/HP2）逐枚注册且 stat_key 镜像基础枚", mirror_ok)
	# 副词条条数分布 ±3pt 独立门值（pkg8 门值为 ±40；此处按验收口径收紧到 ±30）
	var h := _gl.chip_handler
	h.reset_run()
	var counts := {0: 0, 1: 0, 2: 0}
	for i in range(1000):
		var rolled := h.roll_substats(&"atk_pct")
		counts[rolled.size()] += 1
	var c0 := int(counts[0])
	var c1 := int(counts[1])
	var c2 := int(counts[2])
	print("  [实测] 1000 抽条数分布：0 条=%d / 1 条=%d / 2 条=%d" % [c0, c1, c2])
	_check("V14 条数分布 ±3pt：0 条 470~530 / 1 条 320~380 / 2 条 120~180",
		c0 >= 470 and c0 <= 530 and c1 >= 320 and c1 <= 380 and c2 >= 120 and c2 <= 180,
		"%d/%d/%d" % [c0, c1, c2])


# ══ V15/V6：手算对照（套装 max_hp 增量 / 诅咒 3 层受击 / 四参数公式） ══
func _test_handcalc_v15_v6() -> void:
	print("── V15/V6 手算对照 ──")
	var h := _gl.chip_handler
	var c := _gl.curse_handler
	var player := _gl.player
	# V15：max_hp 套装 equip 第 2 枚——player.max_hp 增量（套装口径）+ hp 同步
	# 手算：respawn 基线 max=hp=100 → equip CHIP_HP 白(+20)：prescale=120 → max=120，hp=minf(100+20,120)=120
	#       → equip CHIP_HP2 白(+15)：prescale=(20+15)×1.10=38.5 → max=138.5（Δ=+18.5），
	#         hp=minf(120+15,138.5)=135.0（回补口径=新枚面值，钳 max）
	player.respawn()
	c.reset_run()
	h.reset_run()
	h.unlocked_slots = 3
	_check("V15 夹具：基线 max=hp=100 → equip CHIP_HP 白 → max=120 / hp=120",
		h.equip(&"CHIP_HP", 0) and is_equal_approx(player.max_hp, 120.0)
		and is_equal_approx(player.hp, 120.0),
		"max=%s hp=%s" % [str(player.max_hp), str(player.hp)])
	_check("V15：equip 第 2 枚 max_hp（CHIP_HP2 白）→ max_hp=138.5（Δ+18.5 套装口径）+ hp 同步 135.0",
		h.equip(&"CHIP_HP2", 0) and is_equal_approx(player.max_hp, 138.5)
		and is_equal_approx(player.hp, 135.0),
		"max=%s hp=%s" % [str(player.max_hp), str(player.hp)])
	# V6：诅咒 3 层受击手算（10 × (1+0.08×3) = 12.4）
	player.respawn()
	c.reset_run()
	c.add_curse(3)
	player.invuln_left = 0.0
	var hp3: float = player.hp
	player.take_contact_damage(10.0)
	_check("V6 手算：诅咒 3 层受击 10 → 扣 12.4（×(1+0.08×3)=×1.24）",
		is_equal_approx(hp3 - player.hp, 12.4) and is_equal_approx(c.dmg_taken_mult(), 1.24),
		"drop=%s" % str(hp3 - player.hp))
	# V6：compute_max_hp 四参数组合手算（本组合 pkg8 未用过）：
	# (100×(1+0.3) + 35 + 15) × (1−0.04×3) = 180 × 0.88 = 158.4
	_check("V6 手算：compute_max_hp(0.3, 35, 15, 3) = 158.4（四参数逐参对照）",
		is_equal_approx(Player.compute_max_hp(0.3, 35.0, 15.0, 3), 158.4),
		str(Player.compute_max_hp(0.3, 35.0, 15.0, 3)))
	c.reset_run()


# ══ V1~V4：商店间隙零事件 / 40% 种子注入 0-1 边界 / 事件期战斗冻结 / 祭坛钳 / 紫卡 floor ══
func _test_event_gaps_v1_v4() -> void:
	print("── V1~V4 事件补漏 ──")
	var wd := _gl.wave_director
	var ed := _gl.event_director
	# ── w9/19/29 黑市商店间隙：零事件 + 事件流零消费 + 停留 BUFFER（真路径 shop_requested） ──
	var fired: Array = []
	var cb := func(p_wave: int, p_idx: int) -> void: fired.append([p_wave, p_idx])
	wd.event_requested.connect(cb)
	var gaps_ok := true
	var gap_detail := ""
	for w in [9, 19, 29]:
		wd.reset_event_state()
		var v0: float = wd._event_rng.randf()      # 首抽基准（reset 已重播种 777）
		wd.reset_event_state()                     # 重播种 → 流首抽回到 v0
		fired.clear()
		wd._shop_gapped = false                    # 夹具复位：单店闸由 start_wave 复位（此处直构间隙）
		wd.current_wave = w
		wd._phase = WaveDirector.WavePhase.BUFFER
		wd.buffer_left = 0.0
		wd._extra_shop_pending = false
		wd.tick(DT)
		var v1: float = wd._event_rng.randf()      # 间隙走完后流首抽仍应为 v0（零消费）
		if not fired.is_empty() or wd._event_gapped or not is_equal_approx(v1, v0) \
				or wd.current_wave != w:
			gaps_ok = false
			gap_detail += "w%d(fired=%d gapped=%s wave=%d) " % [w, fired.size(),
				str(wd._event_gapped), wd.current_wave]
		# 清理真路径副作用：商店可能被打开 → 关回 PLAYING
		if _gl.state == GameConst.GameStatus.SHOP:
			_gl.shop_ui.close()
			_gl.change_state(GameConst.GameStatus.PLAYING)
	wd.event_requested.disconnect(cb)
	wd.reset_event_state()
	_check("V1：w9/19/29 商店间隙零事件（不 fire / 不消耗闸 / 事件流零消费 / 停留 BUFFER）",
		gaps_ok, gap_detail)
	# ── 40% 种子注入：首抽 <0.4 → 触发；≥0.4 → 不触发（0/1 两端边界行为） ──
	var seed_low := -1
	var seed_high := -1
	for s in range(1, 1000):
		wd._event_rng.seed = s
		var v: float = wd._event_rng.randf()
		if seed_low < 0 and v < WaveDirector.EVENT_CHANCE:
			seed_low = s
		elif seed_high < 0 and v >= WaveDirector.EVENT_CHANCE:
			seed_high = s
		if seed_low > 0 and seed_high > 0:
			break
	var boundary_ok := seed_low > 0 and seed_high > 0
	if boundary_ok:
		var fire_ok := _run_event_gate(wd, seed_low, fired, cb, true)
		var quiet_ok := _run_event_gate(wd, seed_high, fired, cb, false)
		boundary_ok = fire_ok and quiet_ok
	wd.reset_event_state()
	_check("V1：40% 种子注入边界——首抽<0.4 触发 / 首抽≥0.4 不触发（两态闸均消耗）", boundary_ok,
		"low=%d high=%d" % [seed_low, seed_high])
	# ── 事件期战斗冻结（帧序）：事件复用 SHOP 态 → 战斗帧序不跑，仅 ⑦feel⑧ui raw 通道 ──
	_gl.start_run()
	var player := _gl.player
	var pos0: Vector2 = player.global_position
	var phase0: int = _gl.wave_director._phase
	var active0: int = _gl.spawner.active.size()
	_gl._open_event_flow(4, 0)
	var opened := _gl.state == GameConst.GameStatus.SHOP and tree.paused
	for i in range(10):
		_gl._physics_process(DT)
	var frozen_order: Array[StringName] = [&"feel", &"ui"]
	_check("V1：事件期战斗冻结——状态 SHOP+paused / 位置·波相·场上敌零变化 / 帧序=[feel,ui]",
		opened and _gl.state == GameConst.GameStatus.SHOP
		and player.global_position == pos0
		and _gl.wave_director._phase == phase0
		and _gl.spawner.active.size() == active0
		and _gl.frame_order == frozen_order,
		"order=%s" % str(_gl.frame_order))
	_gl._on_event_leave()
	_check("V1：事件离开恢复 PLAYING + 解除 paused", _gl.state == GameConst.GameStatus.PLAYING
		and not tree.paused)
	# ── 祭坛 HP 钳 ≥1 不致死：hp=2 → 献祭 20%（cost=maxf(0.4,1)=1）→ hp=1 存活 ──
	ed.reset_run()
	c_reset(_gl.curse_handler)
	player.respawn()
	player.hp = 2.0
	var r: Dictionary = ed.apply_option(0, 0)
	_check("V3 祭坛：hp=2 献祭 → cost 钳 1 → hp=1（≥1 不致死）+ ok",
		bool(r.get("ok")) and is_equal_approx(player.hp, 1.0) and not player._dead,
		"hp=%s" % str(player.hp))
	# ── 紫卡 floor：EVENTS[0] 选项A floor==2 → generate_candidates 首张 rarity ≥ 2 ──
	var floor_ok := false
	var opt0: Dictionary = (EventDirector.EVENTS[0].get("options") as Array)[0]
	if int(opt0.get("floor", -1)) == 2:
		var cards := ed.card_generator.generate_candidates({
			"player": player, "wave": 10, "min_rarity_floor": 2,
		})
		if not cards.is_empty():
			floor_ok = int((cards[0] as Dictionary).get("rarity", -1)) >= 2
	_check("V3 祭坛：紫卡 floor——EVENTS[0].floor=2 → 赐卡首张 rarity≥2", floor_ok)
	_gl.change_state(GameConst.GameStatus.GAME_OVER)
	_gl.goto_menu()


func _run_event_gate(p_wd: WaveDirector, p_seed: int, p_fired: Array, p_cb: Callable,
		p_expect_fire: bool) -> bool:
	# 种子注入单次闸演练：reset → 注入 seed → 显式构造 w5 BUFFER 间隙 → tick → 校验触发态。
	# 判 roll 发生 = 流消耗证明（tick 前预读下一抽，tick 后下一抽不同 ⇔ 闸 roll 过）——
	# 闸态本身不能作判据：quiet 路径 tick 会继续落入 start_wave（v0.8.0 审查修复后闸随波复位）
	p_wd.reset_event_state()
	p_wd._event_rng.seed = p_seed
	var v_next: float = p_wd._event_rng.randf()      # 下一抽预读
	p_wd.reset_event_state()
	p_wd._event_rng.seed = p_seed
	p_fired.clear()
	p_wd.event_requested.connect(p_cb)
	p_wd.current_wave = 5
	p_wd._phase = WaveDirector.WavePhase.BUFFER
	p_wd.buffer_left = 0.0
	p_wd._event_gapped = false
	p_wd._extra_shop_pending = false
	p_wd.tick(DT)
	p_wd.event_requested.disconnect(p_cb)
	var v_after: float = p_wd._event_rng.randf()
	var rolled: bool = not is_equal_approx(v_after, v_next)
	if _gl.state == GameConst.GameStatus.SHOP:
		_gl.event_ui.close()
		_gl.change_state(GameConst.GameStatus.PLAYING)
	var fired_ok: bool = (p_fired.size() == 1) if p_expect_fire else (p_fired.is_empty())
	return fired_ok and rolled


func _test_event_gate_wave_reset() -> void:
	print("── V1 审查修复：事件闸随 start_wave 复位 ──")
	var wd := _gl.wave_director
	# 找「第1抽<0.4（首间隙触发）且第3抽<0.4（次间隙触发）」的种子
	#（触发后 randi_range 消耗第2抽选事件号——流推进口径）
	var seed2 := -1
	for s in range(1, 2000):
		wd._event_rng.seed = s
		var a: float = wd._event_rng.randf()
		if a >= WaveDirector.EVENT_CHANCE:
			continue
		wd._event_rng.randi_range(0, WaveDirector.EVENT_KINDS - 1)   # 第2抽=事件号
		var b: float = wd._event_rng.randf()
		if b < WaveDirector.EVENT_CHANCE:
			seed2 = s
			break
	var fired: Array = []
	var cb := func(p_wave: int, p_idx: int) -> void: fired.append([p_wave, p_idx])
	var ok := seed2 > 0
	var detail := "seed2=%d" % seed2
	if ok:
		wd.event_requested.connect(cb)
		# 第一次间隙（w4）：命中 → 闸消耗
		wd.reset_event_state()
		wd._event_rng.seed = seed2
		fired.clear()
		wd._shop_gapped = false
		wd.current_wave = 4
		wd._phase = WaveDirector.WavePhase.BUFFER
		wd.buffer_left = 0.0
		wd._extra_shop_pending = false
		wd.tick(DT)
		var first_fired: bool = fired.size() == 1 and wd._event_gapped
		if _gl.state == GameConst.GameStatus.SHOP:
			_gl.event_ui.close()
			_gl.change_state(GameConst.GameStatus.PLAYING)
		# ★修复点：start_wave(5) 应复位闸（缺复位=每局限一次 roll）
		wd.start_wave(5)
		var gate_reset: bool = wd._event_gapped == false
		fired.clear()
		wd._shop_gapped = false
		wd._phase = WaveDirector.WavePhase.BUFFER
		wd.buffer_left = 0.0
		wd._extra_shop_pending = false
		wd.tick(DT)
		var second_fired: bool = fired.size() == 1
		if _gl.state == GameConst.GameStatus.SHOP:
			_gl.event_ui.close()
			_gl.change_state(GameConst.GameStatus.PLAYING)
		wd.event_requested.disconnect(cb)
		wd.reset_event_state()
		ok = first_fired and gate_reset and second_fired
		detail = "first=%s reset=%s second=%s" % [str(first_fired), str(gate_reset), str(second_fired)]
	_check("V1 修复：start_wave 复位事件闸——连续两合格间隙各自 roll（审查 Critical）", ok, detail)


func c_reset(p_c: CurseHandler) -> void:
	p_c.reset_run()


func _count_tres(p_dir_path: String, p_prefix: String) -> int:
	var dir := DirAccess.open(p_dir_path)
	if dir == null:
		return -1
	var n: int = 0
	dir.list_dir_begin()
	var fname: String = dir.get_next()
	while fname != "":
		if not dir.current_is_dir() and fname.begins_with(p_prefix) and fname.ends_with(".tres"):
			n += 1
		fname = dir.get_next()
	dir.list_dir_end()
	return n


# ══ V18/V19：goto_menu 仅 GAME_OVER（四态拒绝）/ 选角→开局全链零 rejected_transitions ══
func _test_character_edges_v18_v19() -> void:
	print("── V18/V19 角色链边沿 ──")
	var player := _gl.player
	# 前置：上一段已 goto_menu 落 MENU；start_run 进 PLAYING 后逐态拒绝
	_gl.start_run()
	var rj0: int = _gl.rejected_transitions
	_check("V19：goto_menu 自 PLAYING 拒绝（false + 状态保持 + rejected+1）",
		not _gl.goto_menu() and _gl.state == GameConst.GameStatus.PLAYING
		and _gl.rejected_transitions == rj0 + 1)
	_gl.change_state(GameConst.GameStatus.SHOP)
	_check("V19：goto_menu 自 SHOP 拒绝", not _gl.goto_menu()
		and _gl.state == GameConst.GameStatus.SHOP and _gl.rejected_transitions == rj0 + 2)
	_gl.change_state(GameConst.GameStatus.PLAYING)
	_gl.change_state(GameConst.GameStatus.PAUSED)
	_check("V19：goto_menu 自 PAUSED 拒绝", not _gl.goto_menu()
		and _gl.state == GameConst.GameStatus.PAUSED and _gl.rejected_transitions == rj0 + 3)
	_gl.change_state(GameConst.GameStatus.PLAYING)
	_gl.change_state(GameConst.GameStatus.LEVEL_UP)
	_check("V19：goto_menu 自 LEVEL_UP 拒绝", not _gl.goto_menu()
		and _gl.state == GameConst.GameStatus.LEVEL_UP and _gl.rejected_transitions == rj0 + 4)
	# 清理：GAME_OVER → goto_menu 合法边回 MENU
	_gl.change_state(GameConst.GameStatus.GAME_OVER)
	_check("V19：goto_menu 自 GAME_OVER 合法（对照）", _gl.goto_menu()
		and _gl.state == GameConst.GameStatus.MENU)
	# 选角（SCHOLAR）→ 开局全链 10 条合法边：rejected_transitions 增量恒 0
	_gl.menu_screen.set_selection(1)
	var rj1: int = _gl.rejected_transitions
	var chain_ok := true
	chain_ok = _gl.start_run() and chain_ok                    # MENU→PLAYING
	chain_ok = _gl.change_state(GameConst.GameStatus.LEVEL_UP) and chain_ok
	chain_ok = _gl.change_state(GameConst.GameStatus.PLAYING) and chain_ok
	chain_ok = _gl.change_state(GameConst.GameStatus.SHOP) and chain_ok
	chain_ok = _gl.change_state(GameConst.GameStatus.PLAYING) and chain_ok
	chain_ok = _gl.change_state(GameConst.GameStatus.PAUSED) and chain_ok
	chain_ok = _gl.change_state(GameConst.GameStatus.PLAYING) and chain_ok
	chain_ok = _gl.change_state(GameConst.GameStatus.GAME_OVER) and chain_ok
	chain_ok = _gl.restart_run() and chain_ok                  # GAME_OVER→PLAYING（角色感知重开）
	chain_ok = _gl.change_state(GameConst.GameStatus.GAME_OVER) and chain_ok
	chain_ok = _gl.goto_menu() and chain_ok                    # GAME_OVER→MENU
	_check("V18：选角 SCHOLAR → 开局全链（含升级/商店/暂停/重开/回菜单）零 rejected_transitions",
		chain_ok and _gl.current_character.id == &"CHAR_SCHOLAR"
		and _gl.rejected_transitions == rj1,
		"chain=%s Δ=%d" % [str(chain_ok), _gl.rejected_transitions - rj1])
	_gl.menu_screen.set_selection(0)                           # 复位默认角色
	if tree.paused:
		tree.paused = false


# ══ V21/22：冲刺无敌 0.15s 边界 / 活动区钳制 / 顿帧冻结 ══
func _test_dash_edges_v21_v22() -> void:
	print("── V21/V22 冲刺补漏 ──")
	var player := _gl.player
	_gl.curse_handler.reset_run()
	# 0.15s 边界（120Hz 离散推进，避开浮点临界：17 帧=0.1417s < 0.15 < 19 帧=0.1583s）
	player.respawn()
	player.invuln_left = 0.0                    # 清重生无敌（隔离变量）
	player._drag_accum = Vector2(30.0, 0.0)
	player.tick(DT, Vector2.ZERO)
	player.try_dash()
	for i in range(17):
		player.tick(DT, Vector2.ZERO)
	var hp_a: float = player.hp
	player.take_contact_damage(10.0)
	_check("V21：冲刺无敌 0.1417s（<0.15s）仍免伤", player.dash_invuln_left > 0.0
		and is_equal_approx(player.hp, hp_a))
	player.invuln_left = 0.0                    # 清上一跳写入的受击无敌
	for i in range(2):
		player.tick(DT, Vector2.ZERO)
	var hp_b: float = player.hp
	player.take_contact_damage(10.0)
	_check("V21：0.1583s（≥0.15s）冲刺无敌结束 → 可受伤（0 诅咒扣 10 恒等）",
		player.dash_invuln_left == 0.0 and is_equal_approx(hp_b - player.hp, 10.0),
		"dash_invuln=%s drop=%s" % [str(player.dash_invuln_left), str(hp_b - player.hp)])
	# 活动区钳制：冲刺位移不得越界（x∈[r,720−r] / y∈[768,1264]）
	player.respawn()
	player.invuln_left = 0.0
	player.dash_cd_left = 0.0
	player.global_position = Vector2(360.0, 780.0)
	player._drag_accum = Vector2(0.0, -30.0)
	player.tick(DT, Vector2.ZERO)               # 建立方向 (0,-1)
	player.try_dash()
	for i in range(5):
		player.tick(DT, Vector2.ZERO)
	_check("V21：冲刺撞上缘 → y 钳 768（0.6×1280）且 x 不受扰",
		is_equal_approx(player.global_position.y, 1280.0 * 0.6)
		and is_equal_approx(player.global_position.x, 360.0),
		str(player.global_position))
	player.dash_left = 0.0
	player.dash_cd_left = 0.0
	player.global_position = Vector2(700.0, 900.0)
	player._drag_accum = Vector2(30.0, 0.0)
	player.tick(DT, Vector2.ZERO)               # 建立方向 (1,0)
	player.try_dash()
	for i in range(5):
		player.tick(DT, Vector2.ZERO)
	_check("V21：冲刺撞右缘 → x 钳 720−r(16)=704 且 y 不受扰",
		is_equal_approx(player.global_position.x, 720.0 - player.hitbox_radius)
		and is_equal_approx(player.global_position.y, 900.0),
		str(player.global_position))
	# 顿帧冻结：game_delta=0（time_scale≈0 口径）→ 冲刺计时与位移全部冻结
	player.respawn()
	player.invuln_left = 0.0
	player.dash_cd_left = 0.0
	player.global_position = Vector2(360.0, 900.0)
	player._drag_accum = Vector2(30.0, 0.0)
	player.tick(DT, Vector2.ZERO)
	player.try_dash()
	var dash0: float = player.dash_left
	var cd0: float = player.dash_cd_left
	var inv0: float = player.dash_invuln_left
	var pos0: Vector2 = player.global_position
	for i in range(5):
		player.tick(0.0, Vector2.ZERO)           # 顿帧：game_delta = raw × time_scale ≈ 0
	_check("V21：顿帧冻结——dash/冷却/无敌三计时与位置零变化（game_delta=0 五帧）",
		is_equal_approx(player.dash_left, dash0) and is_equal_approx(player.dash_cd_left, cd0)
		and is_equal_approx(player.dash_invuln_left, inv0)
		and player.global_position == pos0)
	player.respawn()


# ══ V24：version / PROGRESS 基线 / A7 假设清单（文档面独立核对） ══
func _test_closure_v24() -> void:
	print("── V24 收尾核对 ──")
	var version: String = ProjectSettings.get_setting("application/config/version", "")
	_check("V24：version=0.8.0（project.godot application/config/version）", version == "0.8.0",
		version)
	var progress_text := _read_text("res://PROGRESS.md")
	_check("V24：PROGRESS §7 基线含全 runner 合计 1257（独立实测一致）",
		not progress_text.is_empty() and progress_text.contains("1257")
		and progress_text.contains("pkg8 160"))
	var a7_text := _read_text("res://docs/analysis/A7_v0.8.0_design.md")
	_check("V24：A7 设计留痕存在且假设清单含 R8",
		not a7_text.is_empty() and a7_text.contains("R8"))


func _read_text(p_path: String) -> String:
	var f := FileAccess.open(p_path, FileAccess.READ)
	if f == null:
		return ""
	return f.get_as_text()
