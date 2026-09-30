# tests/runner/r188_idle_cases.gd
# R188 整案验收用例体（由 test_r188_idle.gd 入口在 autoload 就绪后运行时 load()）。
# 真源：docs/design/R188_IDLE_PERF.md 定案（market/buffs/idle/perf 四项全 implement，
# 无 noop 项）——全部非 noop 项验收标准的 headless 落地：
#   §M R188-1 黑市供给：§1.7 五断言（真终局供给/展示=实挂/拒买不扣金/金卡行/终兜底）
#       + 行为口径抽查（刷新价曲线/关店归零/R37）。
#   §H R188-2 高位叠层回归：审计结论「叠层引擎本体全部正常」——按 ask 要求无论 verdict
#       落库并把「正常」口径锁死（§2.5 十组：千层线性/attach 封顶/F4 钳/诅咒全额/乘区
#       护栏/R186 网格/R183 循环/显示修复/成本标度/存档现版绿口径）。
#       存档有损项（混品级降白/运行期卡蒸发/遗物不入档）按 §2.2-1 只注释不落 golden。
#   §P R188-4 性能纵深：套件内可达口径（EventBus 门控 ≥90%/HUD 脏标记同帧一次/
#       敌段 LOD 已拆墓碑守卫（R189c 整体拆除，R199/G8-H04 清账）/w233 建波 ≤5ms+
#       钳 200/高水位 600 拒收/连升合并帽 3/
#       池预热 820）。双压测 500p/800p、风暴档、OrbitField 微基准、180s soak 为
#       tests/stress 专项长锚（设计 §4.8 自有入口），本套件不重复复压。
#   §I R188-3 挂机全链路：§3.9（A 设置双接线/B AUTO 开关/C 选卡真链+诅咒不变量 200
#       seed/D 商店三源零损失/E 结算四案/F soak ≥3000 帧）。
# 夹具口径：seed(42) + main.tscn 全栈启动（GameLoop 真件）+ DT=1/120 手动计帧驱动
#（pkg4/auto_idle 同模式：手动驱动 _physics_process，禁自动帧保证确定性）。
# 分段各自 fresh boot（market/叠层/性能/挂机互不污染——market 枯竭态武器栈残留不外溢）。
# 已知实现缺陷（如实遥测不落常红断言）：gain_xp(1e12) 连升爆发单帧超 50ms 预算线
#（逐级 emit_level_up × meta 成就全表扫，deep_wave_probe 已裁定为 WARN 遥测线）——
# 本套件同口径：排队帽硬闸 + 爆发帧耗时打印。
extends RefCounted

const DT := 1.0 / 120.0                       # 120Hz 物理帧
const MAIN_SCENE := "res://scenes/main.tscn"
const PICK_WINDOW_FRAMES := 72                # 0.6s（0.5s 选卡展示窗 + 裕量）
const SHOP_WINDOW_FRAMES := 140               # 1.2s（0.8s 商店窗 + 裕量）
const RESTART_WINDOW_FRAMES := 420            # 3.5s（3s 重开倒计时 + 裕量）
const VICTORY_WINDOW_FRAMES := 300            # 2.5s（2.2s 通关收尾窗 + 裕量）
const SOAK_FRAMES := 3120                     # 26s ≥ 3000 帧（验收下限）
const STREAK_CAP := 1200                      # 10s（LEVEL_UP/GAME_OVER 连续停留上限 @120Hz）
const BADGE_RECT := Rect2(598.0, 16.0, 106.0, 106.0)   # 波次圆形徽章（hud.gd:961 锁定布局）
const CURSE_SCAN_SEEDS := 200                 # 诅咒硬不变量扫描规模（§3.9-5 ≥200）
const SOAK_TICKS := 120000                    # ⑥ 120Hz 帧粒度 soak 下限（≥120k tick）
const DT_120 := 1.0 / 120.0
const PROBE_WAVE := 233                       # 深层无尽建波探针波次（§4.8-9）
const WAVE_COUNT_CLAMP := 200                 # 与 WaveDirector.WAVE_COUNT_CLAMP 同值
const HIGH_WATER := 600                       # 与 EnemySpawner.SPAWN_QUEUE_HIGH_WATER 同值
const START_WAVE_BUDGET_MS := 5.0
const FRAME_BUDGET_MS := 50.0

var tree: SceneTree
var _pass: int = 0
var _fail: int = 0
var _failures: Array[String] = []
var _gl: GameLoop = null
var _w1: WeaponBase = null
var _overlay: PauseOverlay = null             # ⑧ 显示断言宿主（不进树，纯方法调用）
var _boot_idx: int = 0
var _choice_sizes: Array[int] = []            # choice_made 载荷行宽（普通=1 / 成对=2）
var _card_chosen_count: int = 0               # EventBus.card_chosen 计数（图鉴口径）
var _wave_started_count: int = 0              # EventBus.wave_started 计数（二次重开侦测）
var _spy: Node = null                         # R189：EventBus 订阅 Node 载体（E-12 纪律）


class Spy extends Node:
	# E-12 订阅纪律：仅 Node 派生类可订阅 EventBus（RefCounted 直连被 end_frame
	# 逐帧 push_error——本套件长 soak 下 stderr 洪水 >harness 256KB 上限）。
	# 计数仍落宿主用例体字段，读取点零改动。
	var host: Object = null

	func on_card_chosen(_p_id: StringName, _p_kind: int) -> void:
		if host != null:
			host._card_chosen_count += 1

	func on_wave_started(_p_wave: int) -> void:
		if host != null:
			host._wave_started_count += 1


func run(p_tree: SceneTree) -> void:
	tree = p_tree
	seed(42)
	_normalize_window_for_boot()
	_spy = Spy.new()
	_spy.host = self
	EventBus.card_chosen.connect(_spy.on_card_chosen)
	EventBus.wave_started.connect(_spy.on_wave_started)
	# ── §M R188-1 黑市供给 ──
	_boot("MarketLoop")
	_section("§M R188-1 黑市供给（验收五断言 + 口径抽查）")
	_test_market_supply()
	_teardown()
	# ── §H R188-2 高位叠层回归（「正常」口径锁死） ──
	_boot("HighStackLoop")
	_section("§H R188-2 高位叠层回归（十组「正常」口径锁死）")
	_test_high_stack()
	_teardown()
	# ── §P R188-4 性能纵深（套件内可达口径） ──
	_boot("PerfLoop")
	_section("§P R188-4 性能纵深（门控/脏标记/LOD 墓碑/建波钳制/连升合并/池扩容）")
	_test_perf()
	_teardown()
	# ── §I R188-3 挂机全链路 ──
	_boot("IdleLoop")
	_section("§I R188-3 挂机全链路（设置/开关/选卡/商店/结算/soak）")
	_test_idle()
	_teardown()
	EventBus.card_chosen.disconnect(_spy.on_card_chosen)
	EventBus.wave_started.disconnect(_spy.on_wave_started)
	_spy.host = null
	_spy.free()                                  # Node 载体手动回收（不进树）
	_spy = null
	print("────────────────────────────────────────")
	print("R188 用例分账：PASS %d / FAIL %d（共 %d 项）" % [_pass, _fail, _pass + _fail])
	if not _failures.is_empty():
		for f in _failures:
			print("  FAIL 详情：%s" % f)


func fail_count() -> int:
	return _fail


func total_count() -> int:
	return _pass + _fail


# ── 通用夹具 ──────────────────────────────────────────────────────
func _normalize_window_for_boot() -> void:
	# R195 环境归一（r195_adapt/r194 矩阵套件同款协议）：-s headless 根窗口恒 64×64
	#（override 540×960 不生效），而工程 stretch 设置生效——aspect=expand 下画布随窗
	# 延展为 1280×1280 方幅，§I B 组钉带几何断言（x∈[644,704] 系默认窗口径）即失配。
	# 归一到引擎 boot 等价位：默认窗 = override 540×960（9:16 下 EXPAND≡KEEP，
	# vis==(720,1280) 设计域）；aspect 读 ProjectSettings 单源。断言零改动，仅环境对齐。
	var win: Window = tree.root
	win.content_scale_mode = Window.CONTENT_SCALE_MODE_CANVAS_ITEMS
	match String(ProjectSettings.get_setting("display/window/stretch/aspect", "keep")):
		"keep_width":
			win.content_scale_aspect = Window.CONTENT_SCALE_ASPECT_KEEP_WIDTH
		"keep_height":
			win.content_scale_aspect = Window.CONTENT_SCALE_ASPECT_KEEP_HEIGHT
		"expand":
			win.content_scale_aspect = Window.CONTENT_SCALE_ASPECT_EXPAND
		"ignore":
			win.content_scale_aspect = Window.CONTENT_SCALE_ASPECT_IGNORE
		_:
			win.content_scale_aspect = Window.CONTENT_SCALE_ASPECT_KEEP
	win.size = Vector2i(
		int(ProjectSettings.get_setting("display/window/size/window_width_override", 540)),
		int(ProjectSettings.get_setting("display/window/size/window_height_override", 960)))


func _boot(p_name: String) -> void:
	RunSave.clear()
	var scene: PackedScene = load(MAIN_SCENE)
	_gl = scene.instantiate() as GameLoop
	_gl.name = p_name
	tree.get_root().add_child(_gl)
	_boot_idx += 1
	_check("Boot#%d：完成且进入 MENU" % _boot_idx,
		_gl.boot_ready and _gl.state == GameConst.GameStatus.MENU)
	# Meta 测试隔离（pkg4 同口径）：局外养成清零——字面断言假定全新档案
	Meta.upgrades = {}
	Meta.crystals = 0
	Meta.character_id = &"sentinel"
	Meta.set_setting("auto_select_on", false)
	Meta.set_setting("auto_restart_mode", 0)


func _teardown() -> void:
	tree.paused = false
	RunSave.clear()
	_overlay = null                              # ⑧ 宿主未进树，随 GameLoop 场销毁
	Meta.set_setting("auto_select_on", false)    # 磁盘测试档不留挂机态
	Meta.set_setting("auto_restart_mode", 0)
	Meta.set_run_map(MapTable.FIRST_MAP_ID)
	if _gl != null:
		_gl.free()
		_gl = null


func _check(p_name: String, p_cond: bool, p_detail: String = "") -> void:
	if p_cond:
		_pass += 1
		print("PASS | %s" % p_name)
	else:
		_fail += 1
		_failures.append("%s | %s" % [p_name, p_detail])
		print("FAIL | %s | %s" % [p_name, p_detail])


func _section(p_title: String) -> void:
	print("── %s ──" % p_title)


func _drive_frames(p_n: int) -> void:
	for i in range(p_n):
		_gl._physics_process(DT)


func _drive_until_state(p_state: int, p_max: int) -> int:
	# 逐帧驱动至目标状态（返回用时帧数；超时 -1）
	for i in range(p_max):
		_gl._physics_process(DT)
		if _gl.state == p_state:
			return i + 1
	return -1


func _drive_playing(p_n: int) -> void:
	# 强制 PLAYING 帧驱动：真实战斗中途弹卡/开店即时程序化收口（断言只关心战斗帧遥测）
	var driven := 0
	var guard := 0
	while driven < p_n and guard < p_n * 12:
		guard += 1
		if _gl.state == GameConst.GameStatus.LEVEL_UP:
			if _gl.card_select_ui.is_open:
				_gl.card_select_ui.choose(0)
			continue
		if _gl.shop_ui.is_shop_visible():
			_gl.shop_ui.close()
			continue
		if _gl.state != GameConst.GameStatus.PLAYING:
			break
		_gl._physics_process(DT)
		driven += 1


func _drain_card_window(p_max: int = 50) -> void:
	# 连升排队链收口：choose 同步续弹直至回 PLAYING（pending 帽 3 + 溢出批同帧抽卡）
	for i in range(p_max):
		if _gl.state != GameConst.GameStatus.LEVEL_UP or not _gl.card_select_ui.is_open:
			return
		_gl.card_select_ui.choose(0)


func _kill_player() -> void:
	# 必死一击（pkg4 Q-16 简化路径）：清复活/护盾/无敌 → 接触伤害超血线
	var p := _gl.player
	p.set("revives_left", 0)
	p.set("shield_ready", false)
	p.set("invuln_left", 0.0)
	p.take_contact_damage(float(p.get("hp")) + 1.0)


func _find_node(p_root: Node, p_name: String) -> Node:
	if String(p_root.name) == p_name:
		return p_root
	for c in p_root.get_children():
		var found := _find_node(c, p_name)
		if found != null:
			return found
	return null


func _on_choice_made_spy(p_cards: Array) -> void:
	_choice_sizes.append(p_cards.size())


# ══ §M R188-1 黑市供给 ═══════════════════════════════════════════
func _test_market_supply() -> void:
	_gl.state = GameConst.GameStatus.MENU
	_gl.current_map_id = MapTable.FIRST_MAP_ID
	_check("§M 前置：常规局开局", _gl.start_run() and _gl.state == GameConst.GameStatus.PLAYING)
	_gl.player.set("unlocked_slots", 5)          # 预留空宿主槽位（多武器是后期常态）
	_gl.player.set("gold", 9999)
	_exhaust_null_target_pool()
	var extra_w: WeaponBase = _gl.player.add_weapon(_gl.registry.get_weapon(&"W3_shotgun"))
	_check("§M 前置：补充空栈宿主武器", extra_w != null)
	var shop := _gl.shop_ui
	shop.open(_gl.player, 20, false)
	_check("① 真终局（枯竭循环后）开店 buyable_count() >= 1",
		shop.buyable_count() >= 1, "buyable=%d" % shop.buyable_count())
	# ② 扩池后：null 口径已枯竭，带 target 容量感知口径仍有非 heal 词条行可供
	var trait_idx := _find_ware("trait", false)
	for attempt in range(4):
		if trait_idx >= 0:
			break
		shop._on_refresh_pressed()               # 付费重掷换宿主签（金币充足，真链重掷）
		trait_idx = _find_ware("trait", false)
	_check("② 词条枯竭态货架有非 heal 词条行（口径对齐扩池生效）", trait_idx >= 0)
	if trait_idx >= 0:
		var ware: Dictionary = shop._wares[trait_idx]
		var target_w: WeaponBase = ware.get("target")
		var tid: StringName = (ware.get("data") as TraitData).id
		var layers0 := _tid_layers(target_w, tid)
		var gold0 := int(_gl.player.get("gold"))
		var price0 := shop._price(ware)
		shop._buy(trait_idx)
		_check("② 展示=实挂：购买后词条 id 落在展示 target 的 trait_stack 上",
			_tid_layers(target_w, tid) == layers0 + 1,
			"tid=%s layers %d→%d" % [tid, layers0, _tid_layers(target_w, tid)])
		_check("② 购买扣金 + 购买即下架（_wares 行清空）",
			int(_gl.player.get("gold")) == gold0 - price0 and shop._wares[trait_idx].is_empty(),
			"gold %d→%d price=%d" % [gold0, int(_gl.player.get("gold")), price0])
	shop.close()
	_test_market_reject_buy()
	_test_market_gold_card()
	_test_market_evergreen()
	_test_market_conventions()


func _exhaust_null_target_pool() -> void:
	# 枯竭循环（配方=market_supply_cases 同款）：null 目标口径反复叠满全部武器侧可售词条
	var targets: Array[WeaponBase] = [_gl.player.weapon_slots[0]]
	var add_ids := [&"W6_micro_missile", &"W8_orbit_field"]
	var add_i := 0
	var overflow := false
	for round_i in range(60):
		var any_left := false
		for category in ["ADD", "MULT", "MECH", "ELEM"]:
			var pool: Array[StringName] = _gl.card_generator._trait_candidates(
				category, _gl.player, [])
			var clean: Array[StringName] = []
			for tid: StringName in pool:
				var td: TraitData = _gl.card_generator.registry.get_trait(tid)
				if td != null and not (td.pool_id in GameConst.PLAYER_SIDE_POOLS):
					clean.append(tid)
			if clean.is_empty():
				continue
			any_left = true
			var src: TraitData = _gl.card_generator.registry.get_trait(clean[0])
			var placed := false
			for w in targets:
				if w.trait_stack.attach(src):
					placed = true
					break
			while not placed and add_i < add_ids.size():
				var extra: WeaponBase = _gl.player.add_weapon(
					_gl.registry.get_weapon(add_ids[add_i]))
				add_i += 1
				if extra != null:
					targets.append(extra)
					if extra.trait_stack.attach(src):
						placed = true
						break
			if not placed:
				overflow = true                  # 槽满也放不下（前置失败信号）
				break
		if overflow or not any_left:
			break
	_check("§M 前置：null 目标候选全部叠满（枯竭复现，无溢出）", not overflow)


func _tid_layers(p_w: WeaponBase, p_tid: StringName) -> int:
	# 目标武器栈上某词条 id 的当前层数（0 = 未挂）
	if p_w == null or not is_instance_valid(p_w) or p_w.trait_stack == null:
		return 0
	for tb in p_w.trait_stack.traits:
		if tb.data != null and tb.data.id == p_tid:
			return int(tb.layers)
	return 0


func _find_ware(p_kind: String, p_evergreen: bool) -> int:
	# 货架上第一个非空且 kind 匹配的行下标（-1 = 无；p_evergreen 过滤常青货标记）
	var shop := _gl.shop_ui
	for i in range(shop._wares.size()):
		var ware: Dictionary = shop._wares[i]
		if ware.is_empty() or String(ware.get("kind")) != p_kind:
			continue
		if p_evergreen and not bool(ware.get("evergreen", false)):
			continue
		return i
	return -1


func _test_market_reject_buy() -> void:
	# ③ 挂满 12 条不同词条（TraitStack.MAX_TRAITS）的武器为 target：拒买不扣金不换宿主
	var w_t: WeaponBase = _gl.player.add_weapon(_gl.registry.get_weapon(&"W5_prism"))
	_check("③ 前置：取得空栈 target 武器", w_t != null and w_t.trait_stack.traits.is_empty())
	if w_t == null:
		return
	var mounted := 0
	for tid: StringName in _gl.card_generator.registry.traits.keys():
		if mounted >= 12:
			break
		var td: TraitData = _gl.card_generator.registry.get_trait(tid)
		if td != null and w_t.trait_stack.attach(td):
			mounted += 1
	_check("③ 前置：target 武器直挂 12 条不同词条（TraitStack.MAX_TRAITS 满栈）",
		mounted == 12, "mounted=%d" % mounted)
	var tid13 := &""
	for tid2: StringName in _gl.card_generator.registry.traits.keys():
		var anywhere := false
		for w in _gl.player.weapon_slots:
			if w != null and is_instance_valid(w) and _tid_layers(w, tid2) > 0:
				anywhere = true
				break
		if not anywhere:
			tid13 = tid2
			break
	_check("③ 前置：取得第 13 条未挂词条（全武器栈均无）", tid13 != &"")
	_gl.player.set("gold", 500)
	var shop := _gl.shop_ui
	shop.open(_gl.player, 12, false)
	# 白盒构造「满栈 target 的行」：复验谓词必须拒买——不扣金、不静默换宿主
	var data13: TraitData = (_gl.card_generator.registry.get_trait(tid13) as TraitData).duplicate()
	shop._wares.append({
		"kind": "trait", "data": data13, "rarity": 0, "target": w_t,
		"base": 40.0, "mult": 1.0,
	})
	var idx := shop._wares.size() - 1
	shop._buy(idx)
	_check("③ 满 12 词条武器为 target 的行：购买不扣金",
		int(_gl.player.get("gold")) == 500, "gold=%d" % int(_gl.player.get("gold")))
	var leaked := 0
	for w in _gl.player.weapon_slots:
		if w != null and is_instance_valid(w):
			leaked += _tid_layers(w, tid13)
	_check("③ 拒买且第 13 条词条未挂到任何武器（不静默换宿主）", leaked == 0,
		"leaked=%d" % leaked)
	shop.close()


func _test_market_gold_card() -> void:
	# ④ REL_BLACK_MARKET 金卡行：价读 .tres params、购买 +1 槽、满槽不上架
	_gl.player.set("unlocked_slots", 3)
	_gl.player.set("gold", 1000)
	_gl.card_generator.owned_relics.append(&"REL_BLACK_MARKET")   # RELIC 通道同源入列口径
	var shop := _gl.shop_ui
	shop.open(_gl.player, 9, false)
	var g_idx := _find_ware("gold_card", false)
	_check("④ 持 REL_BLACK_MARKET 出现金卡行", g_idx >= 0)
	if g_idx >= 0:
		var g_ware: Dictionary = shop._wares[g_idx]
		var bm: RelicData = _gl.card_generator.registry.get_relic(&"REL_BLACK_MARKET")
		var want := int(bm.params.get("gold_card_price", 260))
		_check("④ 金卡价 = .tres params.gold_card_price（260，数据驱动无硬编码）",
			want == 260 and shop._price(g_ware) == want,
			"tres=%d price=%d" % [want, shop._price(g_ware)])
		var slots0 := int(_gl.player.get("unlocked_slots"))
		var gold0 := int(_gl.player.get("gold"))
		shop._buy(g_idx)
		_check("④ 购买金卡 → unlocked_slots +1（SLOT_BONUS 提前解锁帽内下一槽）",
			int(_gl.player.get("unlocked_slots")) == slots0 + 1,
			"slots %d→%d" % [slots0, int(_gl.player.get("unlocked_slots"))])
		_check("④ 购买扣金 260 + 购买即下架",
			int(_gl.player.get("gold")) == gold0 - want and shop._wares[g_idx].is_empty())
	_gl.player.set("unlocked_slots", int(_gl.player.call(&"slot_cap_total")))
	shop._reroll_wares(false)
	_check("④ 满槽不上架（无金卡行）", _find_ware("gold_card", false) < 0)
	shop.close()


func _test_market_evergreen() -> void:
	# ⑤ buyable_count()==0 触发终兜底常青货（FALLBACK_ATK 运行期构造，E-08 不落盘）
	var shop := _gl.shop_ui
	var fb_w: WeaponBase = _gl.player.add_weapon(_gl.registry.get_weapon(&"W4_pulse_beam"))
	_check("⑤ 前置：补充可挂载空栈宿主", fb_w != null)
	for w in _gl.player.weapon_slots:
		if w != null and is_instance_valid(w):
			(w as WeaponBase).set("level", WeaponBase.MAX_LEVEL)
	for rid: StringName in _gl.card_generator.registry.relics.keys():
		if not _gl.card_generator.owned_relics.has(rid):
			_gl.card_generator.owned_relics.append(rid)
	_gl.player.set("hp", _gl.player.get("max_hp"))
	_gl.player.set("gold", 25)
	shop.open(_gl.player, 22, false)
	var fb_idx := _find_ware("trait", true)
	_check("⑤ buyable_count()==0 触发终兜底常青货上架（FALLBACK_ATK 运行期构造）",
		fb_idx >= 0)
	_check("⑤ 保底行可购（buyable_count() >= 1）", shop.buyable_count() >= 1,
		"buyable=%d" % shop.buyable_count())
	if fb_idx >= 0:
		var fb_ware: Dictionary = shop._wares[fb_idx]
		var fb_target: WeaponBase = fb_ware.get("target")
		var layers0 := _tid_layers(fb_target, &"FALLBACK_ATK")
		shop._buy(fb_idx)
		_check("⑤ 购买保底行：FALLBACK_ATK 落展示 target 栈 + 金币 25→0",
			_tid_layers(fb_target, &"FALLBACK_ATK") == layers0 + 1
				and int(_gl.player.get("gold")) == 0)
	# 验收原文动作：清空 _wares → open 立即补保底常青行且可购
	_gl.player.set("gold", 25)
	shop._wares.clear()
	shop.open(_gl.player, 22, false)
	_check("⑤ 清空 _wares 后 open 立即补保底常青行且可购",
		_find_ware("trait", true) >= 0 and shop.buyable_count() >= 1,
		"buyable=%d" % shop.buyable_count())
	shop.close()


func _test_market_conventions() -> void:
	# 行为口径抽查：刷新价曲线 15×market_mult(wave,9)×1.5ⁿ 不变；关店归零；R37
	_gl.player.set("gold", 99999)
	var shop := _gl.shop_ui
	shop.open(_gl.player, 7, false)
	var curve_ok := true
	for n in range(3):
		shop.set("_refresh_count", n)
		var expect := int(ceil(15.0 * shop.market_mult(7, 9) * pow(1.5, float(n))))
		if int(shop.refresh_cost()) != expect:
			curve_ok = false
	_check("抽查：刷新价曲线不变 15×market_mult(wave,9)×1.5ⁿ（n=0,1,2 逐点相等）", curve_ok)
	shop.set("_refresh_count", 0)
	var c0: int = shop.refresh_cost()
	shop.close()
	shop.open(_gl.player, 7, false)              # 同波重开（行情系数同源——c0 可比）
	_check("抽查：关店 _refresh_count 归零（重开回基准价 ==c0）",
		shop.refresh_count_used() == 0 and int(shop.refresh_cost()) == c0,
		"used=%d cost=%d c0=%d" % [shop.refresh_count_used(), shop.refresh_cost(), c0])
	var side_seen := false
	var checked := 0
	for ware in shop._wares:
		if not ware.is_empty() and String(ware.get("kind")) == "trait":
			var td: TraitData = ware.get("data")
			checked += 1
			if td != null and (td.pool_id in GameConst.PLAYER_SIDE_POOLS):
				side_seen = true
	_check("抽查：R37 玩家侧 5 池词条不出现在黑市货架（扫 %d 行）" % checked,
		checked > 0 and not side_seen)
	shop.close()


# ══ §H R188-2 高位叠层回归（「正常」口径锁死） ════════════════════
func _test_high_stack() -> void:
	_gl.state = GameConst.GameStatus.MENU
	_gl.current_map_id = MapTable.FIRST_MAP_ID
	_check("§H 前置：常规局开局", _gl.start_run() and _gl.state == GameConst.GameStatus.PLAYING)
	_gl.player.set("max_hp", 1000000.0)
	_gl.player.set("hp", 1000000.0)
	_w1 = _gl.player.weapon_slots[0]
	_hsc_linear()
	_hsc_attach_cap()
	_hsc_f4_pool_clamp()
	_hsc_curse_full_and_zero_floor()
	_hsc_mult_guards()
	_hsc_r186_budget_grid()
	_hsc_r183_registry()
	_hsc_display_rendering()
	_hsc_cost_scaling_and_copy_full()
	_hsc_save_green_path()
	_gl.elemental.clear_reaction_mults()
	_gl.relic_handler.reset_run()


func _cfg() -> Object:
	return tree.get_root().get_node("GameConfig")


func _mk_add(p_pool: StringName, p_value: float, p_stack_max: int, p_id: StringName = &"") -> TraitData:
	# 探针词条构造（id 缺省按池派生；同池多 id 场景显式传 p_id 防止并层）
	var td := TraitData.new()
	td.id = p_id if p_id != &"" else StringName("R188_%s" % String(p_pool))
	td.display_name = "r188_probe"
	td.pool = GameConst.PoolClass.ADD
	td.pool_id = p_pool
	td.effect_id = &"EF_STAT"
	td.value = p_value
	td.decay_delta = 0.0
	td.stack_max = p_stack_max
	return td


func _attach_n(p_stack: TraitStack, p_td: TraitData, p_n: int) -> int:
	var ok := 0
	for i in range(p_n):
		if p_stack.attach(p_td):
			ok += 1
	return ok


func _bench_us(p_iters: int, p_callable: Callable) -> float:
	var t0 := Time.get_ticks_usec()
	for i in range(p_iters):
		p_callable.call()
	return float(Time.get_ticks_usec() - t0) / float(p_iters)


func _reset_stack() -> void:
	_w1.trait_stack.clear()
	_w1.call("_invalidate_panel")


func _reacquire_weapon() -> void:
	# _restore_run_state 重建武器节点——恢复后必须重取 slot[0]（否则写孤儿栈）
	_w1 = _gl.player.weapon_slots[0]


func _mounted_of(p_id: StringName) -> TraitBase:
	for tb in _w1.trait_stack.traits:
		if tb.data != null and tb.data.id == p_id:
			return tb
	return null


func _agg_of_id(p_stack: TraitStack, p_pool: StringName, p_id: StringName) -> float:
	# 仅统计 p_id 词条对 p_pool 的贡献（逐 mounted 求和，避免同池跨 ID 混算）
	var total := 0.0
	for m in p_stack.traits:
		if m.data != null and m.data.id == p_id and m.data.pool_id == p_pool:
			for v in m.layer_values:
				total += float(v) * float(m.value_mult)
	return total


func _live_layers_of(p_id: StringName) -> int:
	for wv: Variant in _gl.player.weapon_slots:
		if wv == null or not is_instance_valid(wv):
			continue
		var stack: TraitStack = wv.get("trait_stack")
		if stack == null:
			continue
		for m in stack.traits:
			if m.data != null and m.data.id == p_id:
				return int(m.layers)
	return 0


func _saved_layers_of(p_saved: Dictionary, p_id: String) -> int:
	for wv: Variant in p_saved.get("weapons", []):
		var wd: Dictionary = wv if wv is Dictionary else {}
		for tv: Variant in wd.get("traits", []):
			var td: Dictionary = tv if tv is Dictionary else {}
			if String(td.get("id", "")) == p_id:
				return int(td.get("layers", 0))
	return -1


func _make_dummy(p_pos: Vector2) -> Enemy:
	# 管线结算目标（高血 dummy——E-06 死亡短路：target==null 的 resolve 会被丢弃）
	var e: Enemy = (_gl.pools[&"enemy"] as EnemyPool).acquire()
	var data := EnemyData.new()
	data.id = &"E_R188_DUMMY"
	data.hp_base = 1000000.0
	data.spd_base = 0.0
	data.hitbox_r = 14.0
	e.spawn(data, 1, 0)
	e.position = p_pos
	return e


func _resolve_with_n_adds(p_target: Enemy, p_n: int, p_val: float, p_curse: bool) -> DamageResult:
	# 真管线直注 n 条 add_entry（base 100 / 零暴击）；每发推帧号防同帧幂等折叠
	GameConfig.frame_stamp += 1
	var ctx := DamageContext.make()
	ctx.source_uid = 918000 + p_n + (1 if p_curse else 0)
	ctx.frame_stamp = int(GameConfig.frame_stamp)
	ctx.target = p_target
	ctx.target_uid = int(p_target.get("uid"))
	ctx.pos = p_target.global_position
	ctx.base_atk = 100.0
	ctx.crit_chance = 0.0
	for i in range(p_n):
		ctx.add_entries.append({"pool_id": &"add_atk", "layer": 1, "contrib": p_val,
			"decay_delta": 0.85, "is_curse": p_curse})
	return _gl.pipeline.resolve(ctx)


func _hsc_linear() -> void:
	# ① 千层线性（「每层全额无隐藏饱和」锁死）
	var td := _mk_add(&"add_atk", 0.15, 4000)
	var s := TraitStack.new()
	var got := _attach_n(s, td, 1000)
	var m := s.traits[0]
	_check("①a 1000 层逐层挂载全成功，layers/layer_values 同步 1000",
		got == 1000 and int(m.layers) == 1000 and (m.layer_values as Array).size() == 1000,
		"got=%d layers=%d" % [got, int(m.layers)])
	var agg := float(s.aggregate_panel().get(&"add_atk", 0.0))
	_check("①b 1000 层 aggregate_panel = 150.0（绝对误差 <1e-9，无隐藏饱和）",
		absf(agg - 150.0) < 1e-9, str(agg))
	_check("①c stacked_add_total 与面板同源 150.0",
		absf(m.stacked_add_total() - 150.0) < 1e-9, str(m.stacked_add_total()))
	var before := float(s.aggregate_panel().get(&"add_atk", 0.0))
	s.attach(td)
	var after := float(s.aggregate_panel().get(&"add_atk", 0.0))
	_check("①d 第 1001 层增量恰 +0.15（逐层仍按层生效）",
		absf((after - before) - 0.15) < 1e-12, "%f -> %f" % [before, after])
	var s100 := TraitStack.new()
	_attach_n(s100, td, 100)
	var agg100 := float(s100.aggregate_panel().get(&"add_atk", 0.0))
	_check("①e 100 层 aggregate_panel = 15.0（±1e-9）", absf(agg100 - 15.0) < 1e-9, str(agg100))


func _hsc_attach_cap() -> void:
	# ② attach 门 stack_max 封顶（硬帽真实——非「软帽告警」）
	# R196 有意契约变更：ADD 池帽放宽至 stack_max + OVERCAP_EXT_MAX(5)——超帽层
	# ×0.7 计贡献（trait_stack.gd），非 ADD 池保持原帽；断言随帽平移
	var real_td: TraitData = _gl.registry.get_trait(&"AFF_ATK_UP")
	var s := TraitStack.new()
	var got := _attach_n(s, real_td, 10)
	var over := _attach_n(s, real_td, 1)
	# R196 有意契约变更（原「attach×10 → 恰 3 层，满层再挂拒绝」）：ADD 池恰收 3+5=8 层，第 9 层拒绝
	_check("②a 真卡 AFF_ATK_UP attach×10 → 恰 8 层（stack_max+超帽延伸 5），第 9 层拒绝",
		got == 8 and over == 0 and int(s.traits[0].layers) == 8,
		"got=%d over=%d" % [got, over])
	var fb := _mk_add(&"add_atk", 0.05, 99, &"R188_FALLBACK99")
	var s99 := TraitStack.new()
	var got99 := _attach_n(s99, fb, 200)
	# R196 有意契约变更（原「恰 99 层硬帽」）：ADD 池硬帽平移至 99+OVERCAP_EXT_MAX = 104
	_check("②b 运行期 stack_max=99 载体（FALLBACK 口径）attach×200 → 恰 104 层硬帽（stack_max+5）",
		got99 == 104 and int(s99.traits[0].layers) == 104, str(got99))


func _hsc_f4_pool_clamp() -> void:
	# ③ F4 池钳（设计内显式钳制 + 审计可见，非隐式饱和）
	var caps: Dictionary = _cfg().balance.add_pool_caps
	_check("③a F4 帽真源 add_atk = 2.0", absf(float(caps.get("add_atk", 0.0)) - 2.0) < 1e-12,
		str(caps.get("add_atk")))
	var ms := ModifierStack.new()
	ms.audit = DamageAudit.new()
	var entries: Array[Dictionary] = []
	for i in range(99):
		entries.append({"trait_id": &"R188_FALLBACK99", "pool_id": &"add_atk", "layer": 1,
			"contrib": 0.05, "decay_delta": 0.85, "is_curse": false})
	ms.aggregate_add(entries, caps)
	_check("③b 99×0.05=4.95 → F4 钳 2.0 + audit.clamped_add 记账（饱和可见非隐式）",
		absf(float(ms.add_pool_sum.get(&"add_atk", 0.0)) - 2.0) < 1e-12
		and (ms.audit as DamageAudit).clamped_add.has(&"add_atk"),
		str(ms.add_pool_sum.get(&"add_atk")))
	var dummy := _make_dummy(Vector2(300.0, 500.0))
	var r40 := _resolve_with_n_adds(dummy, 40, 0.05, false)
	var r99 := _resolve_with_n_adds(dummy, 99, 0.05, false)
	_check("③c FALLBACK dmg(40) == dmg(99) == 300（1+F4 帽 2.0）",
		r40 != null and r99 != null
		and absf(float(r40.final_value) - 300.0) < 0.01
		and absf(float(r99.final_value) - 300.0) < 0.01,
		"40=%s 99=%s" % [str(r40.final_value if r40 != null else -1.0),
			str(r99.final_value if r99 != null else -1.0)])
	_check("③d 99 层审计可见（clamped_add）且 R_alarm 不误报",
		r99 != null and (r99.audit as DamageAudit).clamped_add.has(&"add_atk")
		and not bool((r99.audit as DamageAudit).alarm))
	dummy.queue_free()


func _hsc_curse_full_and_zero_floor() -> void:
	# ④ 诅咒全额线性 + 管线终值钳 0（惩罚语义不衰减、无 NaN）
	var caps: Dictionary = _cfg().balance.add_pool_caps
	var ms := ModifierStack.new()
	var entries: Array[Dictionary] = []
	for i in range(99):
		entries.append({"pool_id": &"add_atk", "layer": 1, "contrib": -0.1,
			"decay_delta": 0.85, "is_curse": true})
	ms.aggregate_add(entries, caps)
	_check("④a 诅咒 99 层线性全额 −9.9（不衰减/不钳——惩罚语义按层全额）",
		absf(float(ms.add_pool_sum.get(&"add_atk", 0.0)) + 9.9) < 1e-9,
		str(ms.add_pool_sum.get(&"add_atk")))
	var curse := _mk_add(&"add_atk", -0.1, 4000, &"R188_CURSE")
	curse.params = {"is_curse": true}
	var s := TraitStack.new()
	_attach_n(s, curse, 1000)
	_check("④b 诅咒 1000 层叠层面全额 −100（无 NaN）",
		is_finite(s.traits[0].stacked_add_total())
		and absf(s.traits[0].stacked_add_total() + 100.0) < 1e-6,
		str(s.traits[0].stacked_add_total()))
	var dummy := _make_dummy(Vector2(300.0, 500.0))
	var rc := _resolve_with_n_adds(dummy, 99, -0.1, true)
	_check("④c 诅咒 99 层 → S 转负、终值钳 0（有限、无 NaN、无误告警）",
		rc != null and float(rc.panel_snapshot) < 0.0 and float(rc.final_value) == 0.0
		and is_finite(float(rc.final_value))
		and not bool((rc.audit as DamageAudit).alarm),
		"S=%s final=%s" % [str(rc.panel_snapshot if rc != null else 0.0),
			str(rc.final_value if rc != null else 0.0)])
	dummy.queue_free()


func _hsc_mult_guards() -> void:
	# ⑤ 乘区护栏（单区钳/top-8/cap_prod/crit/cdr/rof 全显式钳制）
	var ms := ModifierStack.new()
	var one: Array[Dictionary] = [{"pool_id": &"mult_probe", "source_uid": 0,
		"contrib": 5.0, "cap_pool": 2.0, "priority": 0}]
	ms.aggregate_mults(one, int(_cfg().balance.cap_mul_count), float(_cfg().balance.cap_prod))
	_check("⑤a 单区钳：contrib 5.0/cap_pool 2.0 → merged_M = 3.0",
		ms.resolved_mults.size() == 1 and absf(float(ms.resolved_mults[0]["M"]) - 3.0) < 1e-12,
		str(ms.resolved_mults))
	var ms4 := ModifierStack.new()
	ms4.audit = DamageAudit.new()
	var many: Array[Dictionary] = []
	for i in range(20):
		many.append({"pool_id": StringName("mult_p%02d" % i), "source_uid": 0,
			"contrib": 2.0, "cap_pool": 2.0, "priority": 0})
	ms4.aggregate_mults(many, int(_cfg().balance.cap_mul_count), float(_cfg().balance.cap_prod))
	_check("⑤b 乘区名额 top-8（20 区 → 8 入）+ cap_prod 钳 8.0 + 审计 compressed",
		ms4.resolved_mults.size() == 8 and absf(ms4.product_clamped - 8.0) < 1e-12
		and (ms4.audit as DamageAudit).compressed,
		"n=%d prod=%s" % [ms4.resolved_mults.size(), str(ms4.product_clamped)])
	_attach_n(_w1.trait_stack, _mk_add(&"add_crit", 0.08, 4000), 1000)
	_w1.call("_invalidate_panel")
	var snap: Dictionary = _w1.build_panel_snapshot()
	_check("⑤c add_crit 1000 层 → crit_rate 钳 cap_crit_rate=1.0",
		absf(float(snap.get("crit_rate", 0.0)) - 1.0) < 1e-12, str(snap.get("crit_rate")))
	_attach_n(_w1.trait_stack, _mk_add(&"add_skillcdr", 0.12, 4000), 1000)
	_gl.player.call("refresh_skill_cd")
	_check("⑤d add_skillcdr 1000 层 → 技能急速钳 0.6",
		absf(float(_gl.player.call("skill_haste_pct")) - 0.6) < 1e-12,
		str(_gl.player.call("skill_haste_pct")))
	_attach_n(_w1.trait_stack, _mk_add(&"add_rof", 0.12, 4000), 1000)
	var interval := float(_w1.call("_fire_interval"))
	_check("⑤e BALLISTIC add_rof 1000 层 → 节拍钳 1/30 s（cap_rof_per_weapon=30）",
		absf(interval - 1.0 / 30.0) < 0.001, "interval=%f（1/30=%f）" % [interval, 1.0 / 30.0])
	_reset_stack()


func _hsc_r186_budget_grid() -> void:
	# ⑥ R186 每击谐振预算网格（snappedf 60 击帽 + 20/s 回充）+ 120k tick soak
	var rh: RelicHandler = _gl.relic_handler
	rh.reset_run()
	var ok: bool = rh.activate(&"REL_ATTACK_CDR")
	_check("⑥a 激活拉满存款 0.6（20/s×0.01×3 网格化快照）",
		ok and absf(rh._atk_cdr_budget - 0.6) < 1e-12, str(rh._atk_cdr_budget))
	_gl.player.set("skill_cd_left", 120.0)
	for i in range(60):
		rh.on_attack_fired()
	_check("⑥b 满 60 击直减 0.6 → CD 119.4（snappedf 网格无浮点漂移）",
		absf(float(_gl.player.get("skill_cd_left")) - 119.4) < 1e-9,
		str(_gl.player.get("skill_cd_left")))
	_check("⑥c 计费遥测 credits==60 / seconds==0.60",
		int(rh.attack_cdr_credits) == 60 and absf(rh.attack_cdr_seconds - 0.6) < 1e-9,
		"%d / %f" % [rh.attack_cdr_credits, rh.attack_cdr_seconds])
	var cd_before: float = float(_gl.player.get("skill_cd_left"))
	rh.on_attack_fired()
	_check("⑥d 存款枯竭第 61 击不直减（<1 击预算整击丢弃）",
		absf(float(_gl.player.get("skill_cd_left")) - cd_before) < 1e-12)
	rh.tick(1.0)
	_check("⑥e tick(1s) 回充 0.2（20 击/s 口径）", absf(rh._atk_cdr_budget - 0.2) < 1e-12,
		str(rh._atk_cdr_budget))
	rh.tick(2.0)
	_check("⑥f 继续回充钳存款帽 0.6", absf(rh._atk_cdr_budget - 0.6) < 1e-12,
		str(rh._atk_cdr_budget))
	var credits0 := int(rh.attack_cdr_credits)
	for i in range(120):
		rh.on_attack_fired()
	_check("⑥g 同帧 120 击恰 +60 计费 / CD 119.4→118.8（回充-消耗循环无漂移）",
		int(rh.attack_cdr_credits) - credits0 == 60
		and absf(float(_gl.player.get("skill_cd_left")) - 118.8) < 1e-9,
		"credits+%d cd=%s" % [int(rh.attack_cdr_credits) - credits0,
			str(_gl.player.get("skill_cd_left"))])
	rh.tick(2.0)
	_gl.player.set("skill_cd_left", 0.0)
	var b_full: float = rh._atk_cdr_budget
	rh.on_attack_fired()
	_check("⑥h 技能就绪不计费（存款留存）", absf(rh._atk_cdr_budget - b_full) < 1e-12)
	_gl.player.set("skill_cd_left", 120.0)
	for i in range(60):
		rh.on_attack_fired()                     # 存款清零
	var credits_pre := int(rh.attack_cdr_credits)
	for i in range(SOAK_TICKS):
		rh.tick(DT_120)
	_check("⑥i 120k×(1/120s) tick soak：预算恰回帽 0.6、计费零增、无 NaN",
		absf(rh._atk_cdr_budget - 0.6) < 1e-12 and is_finite(rh._atk_cdr_budget)
		and int(rh.attack_cdr_credits) == credits_pre,
		"budget=%s credits=%d" % [str(rh._atk_cdr_budget), int(rh.attack_cdr_credits)])
	rh.reset_run()


func _hsc_r183_registry() -> void:
	# ⑦ R183 反应乘区注册表（uid 键控注销 + 局清）
	var sys := _gl.elemental
	sys.clear_reaction_mults()
	_check("⑦a 清空后 reaction_mult = 1.0", absf(sys.reaction_mult() - 1.0) < 1e-12,
		str(sys.reaction_mult()))
	sys.register_reaction_mult(7, 1.8)
	sys.register_reaction_mult(7, 4.7)
	_check("⑦b 同 uid 重注册覆盖（4.7，非连乘 8.46）", absf(sys.reaction_mult() - 4.7) < 1e-12,
		str(sys.reaction_mult()))
	sys.clear_reaction_mults()                   # 清 ⑦b 残留——千次循环从空表起步
	for i in range(1000):
		sys.register_reaction_mult(i + 100, 4.7)
		sys.unregister_reaction_mult(i + 100)
	_check("⑦c 1000 注册/注销循环 → 表空 + 聚合归 1.0（注销泄漏回归锁）",
		(sys._reaction_mults as Dictionary).is_empty()
		and absf(sys.reaction_mult() - 1.0) < 1e-12,
		"n=%d mult=%s" % [(sys._reaction_mults as Dictionary).size(), str(sys.reaction_mult())])
	sys.register_reaction_mult(1000 + 5, 4.7)
	sys.unregister_reaction_mult(99999)          # 幻影 uid 静默
	_check("⑦d 注销口精确移除 + 幻影 uid 静默",
		(sys._reaction_mults as Dictionary).size() == 1)
	sys.clear_reaction_mults()
	_check("⑦e 局清空回 1.0（start_run/continue_run 两口同源）",
		absf(sys.reaction_mult() - 1.0) < 1e-12, str(sys.reaction_mult()))


func _mk_desc_tb(p_desc: String, p_value: float, p_layers: int) -> TraitBase:
	# ⑧ 显示断言夹具：描述含首个「+N」记号 + 逐层记账值；stack_max=99 防 mount 语义干扰
	var td := TraitData.new()
	td.id = StringName("R188_DSP_%s" % str(p_layers))
	td.display_name = "r188_display"
	td.description = p_desc
	td.pool = GameConst.PoolClass.ADD
	td.pool_id = &"add_atk"
	td.effect_id = &"EF_STAT"
	td.value = p_value
	td.stack_max = 99
	var tb := TraitBase.new()
	tb.setup(td)
	tb.layers = p_layers
	var vals: Array[float] = []
	for i in range(p_layers):
		vals.append(p_value)
	tb.layer_values = vals
	return tb


func _hsc_display_rendering() -> void:
	# ⑧ 详情面板叠层显示（pause_overlay.gd:524 正则修复口径：两位数/小数位全对）
	if _overlay == null:
		_overlay = PauseOverlay.new()            # 不进树：_trait_desc_bbcode 为纯函数段
	var ov := _overlay
	var out1 := ov._trait_desc_bbcode(_mk_desc_tb("攻击 +15%", 0.15, 2))
	_check("⑧a +15%×2 → 「+30%」（金色高亮），不再渲染「+0.3…」",
		out1.contains("+30%") and not out1.contains("+0.3") and out1.contains("ffd54a"),
		str(out1))
	var out2 := ov._trait_desc_bbcode(_mk_desc_tb("攻击 +25", 25.0, 4))
	_check("⑧b +25×4 → 「+100」，不再渲染「1005」",
		out2.contains("+100") and not out2.contains("1005"), str(out2))
	var out3 := ov._trait_desc_bbcode(_mk_desc_tb("攻速 +8%", 0.08, 3))
	_check("⑧c +8%×3 → 「+24%」", out3.contains("+24%"), str(out3))
	var out4 := ov._trait_desc_bbcode(_mk_desc_tb("弹丸 +1", 1.0, 2))
	_check("⑧d +1×2 → 「+2」", out4.contains("+2"), str(out4))
	var desc5 := "攻击 +15%"
	var out5 := ov._trait_desc_bbcode(_mk_desc_tb(desc5, 0.15, 1))
	_check("⑧e 1 层描述逐字不变（不改写）", out5 == desc5, str(out5))
	var desc6 := "攻击 +10%"
	var out6 := ov._trait_desc_bbcode(_mk_desc_tb(desc6, -0.10, 2))
	_check("⑧f 负值（-10%）描述逐字不变（eff≤0 早退不改写）", out6 == desc6, str(out6))


func _hsc_cost_scaling_and_copy_full() -> void:
	# ⑨ 逐帧聚合成本线性标度（比值断言禁写死绝对 µs）+ copy_full 混品级保真
	var pools: Array[StringName] = [&"add_atk", &"add_rof", &"add_cdr", &"add_crit",
		&"add_critdmg", &"add_spd", &"add_size", &"add_knock", &"add_pickup",
		&"add_xp", &"add_gold", &"add_skillcdr"]
	var t100 := -1.0
	var t1000 := -1.0
	for n in [100, 1000]:
		var stack := TraitStack.new()
		for pid in pools:
			_attach_n(stack, _mk_add(pid, 0.05, 4000), n)
		var t_panel := _bench_us(2000, func() -> void: stack.aggregate_panel())
		print("N=%4d | aggregate_panel %8.3f µs/次" % [n, t_panel])
		if n == 100:
			t100 = t_panel
		else:
			t1000 = t_panel
	var ratio := t1000 / maxf(t100, 0.001)
	_check("⑨a 成本随层数线性标度（1000 层/100 层比值 ∈[5,15]——O(总层数) 无超线性爆炸）",
		t100 > 0.0 and ratio > 5.0 and ratio < 15.0,
		"t100=%f t1000=%f ratio=%f" % [t100, t1000, ratio])
	var sm := TraitStack.new()
	var vals := [0.15, 0.21, 0.39]
	for k in range(vals.size()):
		_attach_n(sm, _mk_add(&"add_atk", vals[k], 4000,
			StringName("R188_MIX_%d" % k)), 50)
	var src_agg := _agg_of_id(sm, &"add_atk", &"R188_MIX_0") \
		+ _agg_of_id(sm, &"add_atk", &"R188_MIX_1") + _agg_of_id(sm, &"add_atk", &"R188_MIX_2")
	var clone := sm.copy_full()
	var full_agg := 0.0
	var full_layers := 0
	for tb in clone.traits:
		full_agg += tb.stacked_add_total()
		full_layers += (tb.layer_values as Array).size()
	_check("⑨b copy_full 混品级保真：源 37.5 → 克隆 37.5（±1e-9）且逐层条目 150 保真",
		absf(src_agg - 37.5) < 1e-9 and absf(full_agg - 37.5) < 1e-9 and full_layers == 150,
		"src=%s clone=%s layers=%d" % [str(src_agg), str(full_agg), full_layers])
	# 注：copy_runtime 逐层值不搬运（单层口径回落）为既有设计口径，本组不落断言。


func _hsc_save_green_path() -> void:
	# ⑩ 存档现版绿口径（layers 整数往返/恢复受 stack_max 钳/满层质变 ×1.6 自然重建）。
	# 存档有损项（混品级降白/运行期卡蒸发/遗物不入档）按 §2.2-1 纪律只注释不落 golden，
	# 待存档立项解冻后再落「读档后==存档前」无损断言。
	_reset_stack()
	var ok3 := true
	for i in range(3):
		ok3 = bool(_w1.attach_trait(_gl.registry.get_trait(&"AFF_ATK_UP"))) and ok3
	var agg_before := _agg_of_id(_w1.trait_stack, &"add_atk", &"AFF_ATK_UP")
	var saved: Dictionary = _gl.serialize_run()
	var saved_layers := _saved_layers_of(saved, "AFF_ATK_UP")
	RunSave.save_run(saved)
	var reloaded := RunSave.load_run()
	var disk_layers := _saved_layers_of(reloaded, "AFF_ATK_UP")
	_gl._restore_run_state(reloaded)
	_reacquire_weapon()
	var live_layers := _live_layers_of(&"AFF_ATK_UP")
	var agg_after := _agg_of_id(_w1.trait_stack, &"add_atk", &"AFF_ATK_UP")
	_check("⑩a layers 往返保真：存 3 = 落盘回读 3 = 恢复实挂 3，聚合 0.45→0.45",
		ok3 and saved_layers == 3 and disk_layers == 3 and live_layers == 3
		and absf(agg_before - 0.45) < 1e-9 and absf(agg_after - 0.45) < 1e-9,
		"saved=%d disk=%d live=%d agg=%s" % [saved_layers, disk_layers, live_layers,
			str(agg_after)])
	_reset_stack()
	var dup: TraitData = (_gl.registry.get_trait(&"AFF_ATK_UP") as Resource).duplicate()
	dup.stack_max = 99
	for i in range(99):
		_w1.attach_trait(dup)
	var saved2: Dictionary = _gl.serialize_run()
	var snap_layers := _saved_layers_of(saved2, "AFF_ATK_UP")
	_gl._restore_run_state(saved2)
	_reacquire_weapon()
	var live2 := _live_layers_of(&"AFF_ATK_UP")
	# R196 有意契约变更（原「回读恰 3」）：ADD 池帽 = stack_max+OVERCAP_EXT_MAX = 3+5 = 8
	_check("⑩b 恢复受 stack_max 钳：存 99 → 回读恰 8（注册表基件帽 3+超帽延伸 5 生效，不越帽）",
		snap_layers == 99 and live2 == 8, "snap=%d live=%d" % [snap_layers, live2])
	_reset_stack()
	Meta.set_run_map(&"world_grove")             # 第 4 关门开（MechanicGate idx≥3）质变口径
	for i in range(3):
		_w1.attach_trait(_gl.registry.get_trait(&"AFF_ATK_UP"))
	var m := _mounted_of(&"AFF_ATK_UP")
	var aggq := _agg_of_id(_w1.trait_stack, &"add_atk", &"AFF_ATK_UP")
	_check("⑩c-预 满层挂载质变 value_mult==1.6（0.15×3×1.6=0.72）",
		m != null and absf(m.value_mult - 1.6) < 1e-12 and absf(aggq - 0.72) < 1e-9,
		"mult=%s agg=%s" % [str(m.value_mult if m != null else -1.0), str(aggq)])
	var saved3: Dictionary = _gl.serialize_run()
	_gl._restore_run_state(saved3)
	_reacquire_weapon()
	var m2 := _mounted_of(&"AFF_ATK_UP")
	var live3 := _live_layers_of(&"AFF_ATK_UP")
	var agg3 := _agg_of_id(_w1.trait_stack, &"add_atk", &"AFF_ATK_UP")
	_check("⑩c 恢复后满层质变再触发：3 层 + value_mult==1.6 + 聚合 0.72",
		live3 == 3 and m2 != null and absf(m2.value_mult - 1.6) < 1e-12
		and absf(agg3 - 0.72) < 1e-9,
		"live=%d mult=%s agg=%s" % [live3,
			str(m2.value_mult if m2 != null else -1.0), str(agg3)])
	Meta.set_run_map(MapTable.FIRST_MAP_ID)


# ══ §P R188-4 性能纵深（套件内可达口径） ═════════════════════════
func _test_perf() -> void:
	_gl.state = GameConst.GameStatus.MENU
	_gl.current_map_id = MapTable.FIRST_MAP_ID
	_check("§P 前置：常规局开局", _gl.start_run() and _gl.state == GameConst.GameStatus.PLAYING)
	_gl.player.set("max_hp", 1000000.0)
	_gl.player.set("hp", 1000000.0)
	_gl.player.set("invuln_left", 9999.0)
	_perf_pool_prewarm()
	_perf_event_bus_gate()
	_perf_hud_dirty_flush()
	_perf_enemy_lod_tombstone()
	_perf_deep_wave_probe()
	_perf_high_water()
	_perf_level_burst()


func _perf_pool_prewarm() -> void:
	# §4.5 档0-10：预热容量 640→≥820（800 弹锚真压 800 弹的容量前提）；软/硬限不动（红线）
	var cap := GameConfig.get_pool_capacity(&"projectile")
	_check("P1 池预热扩容：pool_prewarm.projectile = %d（≥820，800 弹锚容量前提）" % cap,
		cap >= 820, str(cap))
	_check("P1 软/硬限不动（1500/2000——仅预热容量一处变更）",
		int(GameConfig.balance.projectile_soft_limit) == 1500
		and int(GameConfig.balance.projectile_hard_limit) == 2000,
		"%s/%s" % [str(GameConfig.balance.projectile_soft_limit),
			str(GameConfig.balance.projectile_hard_limit)])


func _perf_event_bus_gate() -> void:
	# §4.8-4 门控微探针：关闭态 end_frame 均值（1000 次）较开启态下降 ≥90%
	EventBus.dev_assertions = false
	var t_off := _bench_us(1000, func() -> void: EventBus.end_frame())
	EventBus.dev_assertions = true
	var t_on := _bench_us(1000, func() -> void: EventBus.end_frame())
	EventBus.dev_assertions = false              # 复位默认关（pkg0 用例内自行开）
	var drop := 1.0 - (t_off / maxf(t_on, 0.001))
	_check("P2 EventBus.end_frame 门控：关闭 %.3fµs vs 开启 %.3fµs → 下降 %.1f%%（≥90%%）"
		% [t_off, t_on, drop * 100.0], drop >= 0.9,
		"off=%f on=%f drop=%f" % [t_off, t_on, drop])
	_check("P2 复位：dev_assertions 回默认 false", not EventBus.dev_assertions)


func _perf_hud_dirty_flush() -> void:
	# §4.8-5 HUD 脏标记：同帧 10 次 enemy_killed → 全量 refresh_stats 恰 1 次（同帧 flush）
	var hud := _gl.hud
	hud.set("_fallback_timer", 0.0)              # 关掉 1Hz 兜底对单帧计数的干扰
	var k0: int = hud.displayed_kills()          # R189：先读数（flush 复位 Boot 期残留脏位），
	var calls0: int = hud.refresh_stats_calls    # 再取基线——基线后 delta 只含本帧 10 击杀
	# R189：击杀探针带 uid（对齐真件 Enemy 的 uid 字段口径——裸 Node2D 无 uid 曾打
	# HUD._on_enemy_killed 的 int(null) 构造错误路径，handler 中止行为污染本断言）
	var probe := Node2D.new()
	var uid_s := GDScript.new()
	uid_s.source_code = "extends Node2D\nvar uid: int = 987000\n"
	uid_s.reload()
	probe.set_script(uid_s)
	for i in range(10):
		EventBus.emit_enemy_killed(probe)
	hud.tick(DT)                                 # 帧末同帧 flush（R188-perf 机制本体）
	var calls1: int = hud.refresh_stats_calls
	_check("P3 同帧 10 次 enemy_killed → refresh_stats 恰 1 次（脏标记合并）",
		calls1 - calls0 == 1, "calls %d→%d" % [calls0, calls1])
	_check("P3 displayed_kills 口径逐位一致（+10）", hud.displayed_kills() == k0 + 10,
		"%d vs %d" % [hud.displayed_kills(), k0 + 10])
	_check("P3 观测口读数不触发二次 flush（已同帧消化）",
		hud.refresh_stats_calls == calls1)
	probe.free()


func _perf_enemy_lod_tombstone() -> void:
	# R199/G8-H04 清账：敌段 LOD 断言组随游戏侧 R189c 整体拆除同步注销——原 3 条
	# 性能守卫（豁免谓词自洽/施法·引信·Boss 标签豁免/双相位遥测）依赖的
	# _enemy_lod_full_rate/enemy_lod_skipped/enemy_lod_tick2x 已从 GameLoop 移除，
	# 直调即脚本报错中断、断言从账面静默消失；「P4 前置：波 1 有活跃敌」亦为该组
	# 专用前置，一并注销。等价守卫改为「接口墓碑」（不依赖任何已拆接口）：
	# 锁定已拆状态——若 LOD 接口复活（方法/属性回归 GameLoop），本守卫红，
	# 强制同步补齐真断言而非静默穿过。
	_check("P4 LOD 已拆墓碑：GameLoop 无 _enemy_lod_full_rate 方法（R189c 拆，R199 清账）",
		not _gl.has_method("_enemy_lod_full_rate"))
	_check("P4 LOD 已拆墓碑：GameLoop 无 enemy_lod_skipped/enemy_lod_tick2x 遥测属性（R199）",
		_gl.get("enemy_lod_skipped") == null and _gl.get("enemy_lod_tick2x") == null,
		"skipped=%s tick2x=%s" % [str(_gl.get("enemy_lod_skipped")),
			str(_gl.get("enemy_lod_tick2x"))])


func _perf_deep_wave_probe() -> void:
	# §4.8-9 w233 建波探针：公式 fallback 原失控形态 → 单帧 ≤5ms、请求恰 200、pressure 下发
	var director := WaveDirector.new()
	var sp := EnemySpawner.new()
	tree.get_root().add_child(sp)                # _ready：EventBus 订阅挂载
	director.wave_table = null                   # 表缺失 → 公式 fallback（深层无尽原路径）
	director.registry = _gl.registry
	director.spawner = sp
	director.start_wave(PROBE_WAVE)              # 预热一拍（首拍告警 console I/O 摊销）
	sp.spawn_queue.clear()
	var t0 := Time.get_ticks_usec()
	director.start_wave(PROBE_WAVE)
	var ms := float(Time.get_ticks_usec() - t0) / 1000.0
	var queued := sp.queue_count()
	_check("P5 w233 start_wave 稳态单帧 %.3f ms（≤%.1f，原 w293=221.7ms 已结构性消除）"
		% [ms, START_WAVE_BUDGET_MS], ms <= START_WAVE_BUDGET_MS, "ms=%f" % ms)
	_check("P5 生成请求恰 %d（WAVE_COUNT_CLAMP 钳制生效）" % WAVE_COUNT_CLAMP,
		queued == WAVE_COUNT_CLAMP, "queued=%d" % queued)
	var pressure := float(sp.spawn_queue[0].get("pressure", 0.0)) \
		if not sp.spawn_queue.is_empty() else 0.0
	_check("P5 pressure 乘区下发（%.2f ≥ 1.0——变强不变多）" % pressure, pressure >= 1.0,
		str(pressure))
	sp.free()
	director.free()


func _perf_high_water() -> void:
	# §4.8-9 spawn_queue 高水位 600：触顶拒收 + DebugStats 计数同步
	var sp := EnemySpawner.new()
	tree.get_root().add_child(sp)
	for i in range(HIGH_WATER):
		sp.enqueue({"data_id": &"E1_grunt", "wave": 1})
	var before: int = sp.queue_rejected
	sp.enqueue({"data_id": &"E1_grunt", "wave": 1})   # 高水位上再投 → 拒收
	var rejected: int = sp.queue_rejected - before
	_check("P6 高水位 %d 拒收：队列不越线（%d）且 queue_rejected +%d" % [HIGH_WATER,
		sp.queue_count(), rejected],
		sp.queue_count() == HIGH_WATER and rejected >= 1,
		"queue=%d rejected=%d" % [sp.queue_count(), rejected])
	_check("P6 DebugStats 计数同步（spawn_queue_rejected ≥1）",
		int(DebugStats.get_counter(&"spawn_queue_rejected")) >= 1,
		str(DebugStats.get_counter(&"spawn_queue_rejected")))
	sp.free()


func _perf_level_burst() -> void:
	# §4.8-9 连升合并：gain_xp(1e12)（原 4.8 万张选卡冻结形态）→ 排队帽 ≤3、溢出批不弹窗
	_drain_card_window()
	_gl.pending_level_ups = 0
	_gl.merged_overflow_level_ups = 0
	var t0 := Time.get_ticks_usec()
	_gl.player.gain_xp(1e12)
	var burst_ms := float(Time.get_ticks_usec() - t0) / 1000.0
	var burst: int = _gl.player.level_burst_last
	var pending: int = _gl.pending_level_ups
	var merged: int = _gl.merged_overflow_level_ups
	print("[perf-probe] gain_xp(1e12) 帧耗 %.2f ms | 连升 %d 级 | 排队 %d（帽 3）| 溢出批 %d"
		% [burst_ms, burst, pending, merged])
	# R189：spec §4.8-9「全程无单帧 >50ms」口径复位为真断言（连升批单信号入账 +
	# 成就增量分桶后实测 <50ms；原 WARN 遥测线降级已撤销）。
	# R199/H05 注记：本条时敏（跨跑 20.4↔72.1 ms，随机器负载漂移——桌面实例运行期
	# 即可超线），保留断言口径但超预算降为 WARN 记录不拦截；套件判定以 P7 功能断言
	#（排队帽/溢出批/真实弹窗/收口归零）为准，时敏定谳待真机/安静环境（defer）。
	if burst_ms <= FRAME_BUDGET_MS:
		print("[perf-probe] P7 连升爆发帧 %.1f ms ≤ %.0f ms（§4.8-9 单帧预算内——R199/H05 记录线）"
			% [burst_ms, FRAME_BUDGET_MS])
	else:
		print("[perf-probe][WARN] P7 连升爆发帧 %.1f ms > %.0f ms（时敏超预算——记录不拦截，R199/H05）"
			% [burst_ms, FRAME_BUDGET_MS])
	_check("P7 连升 %d 级 → 选卡排队 ≤3（PENDING_LEVEL_UP_CAP 合并帽）" % burst,
		burst >= 100 and pending <= 3, "burst=%d pending=%d" % [burst, pending])
	_check("P7 溢出批不排队（merged_overflow >0，消除 4.8 万张选卡冻结）", merged > 0,
		"merged=%d" % merged)
	_check("P7 真实弹窗批恰 1 窗（溢出批零弹窗——自动选卡计时器只消化真实批）",
		_gl.state == GameConst.GameStatus.LEVEL_UP and _gl.card_select_ui.is_open,
		"state=%d" % _gl.state)
	var t1 := Time.get_ticks_usec()
	_gl.card_select_ui.choose(0)                 # 收口链首选（真链——与手动点击同一条）
	var close_ms := float(Time.get_ticks_usec() - t1) / 1000.0
	# R199/H05 注记：与连升爆发帧同时敏记录线——超预算打印 WARN 不拦截，
	# 判定以功能断言为准（P7 时敏定谳待真机/安静环境，defer）。
	if close_ms <= FRAME_BUDGET_MS:
		print("[perf-probe] P7 choose 收口帧 %.2f ms ≤ %.0f ms（真链首选预算内——R199/H05 记录线）"
			% [close_ms, FRAME_BUDGET_MS])
	else:
		print("[perf-probe][WARN] P7 choose 收口帧 %.2f ms > %.0f ms（时敏超预算——记录不拦截，R199/H05）"
			% [close_ms, FRAME_BUDGET_MS])
	# pending 帽内残余批继续弹窗——逐批 choose 收口；溢出批转分帧消化（R189）：
	# 收口帧只挂批不抽卡，PLAYING 期逐帧 ≤35ms 预算抽卡至批清零。
	# 消化期玩家 immortal + 挂机自动选卡 ON（对齐溢出批的挂机语义——战斗期升级
	# 弹窗自动消化，不阻塞分帧抽卡；结束后复位 OFF 保持套件口径）。
	_gl.player.set("max_hp", 1000000.0)
	_gl.player.set("hp", 1000000.0)
	_gl.player.set("invuln_left", 9999.0)
	Meta.set_setting("auto_select_on", true)
	var t2 := Time.get_ticks_usec()
	_drain_card_window()
	var drain_frames := 0
	# 批清零 + 消化期战斗升级弹窗自动消化（0.5s 窗）双条件——防窗口滞留阻塞批消化
	while (_gl.merged_overflow_level_ups > 0 or _gl.card_select_ui.is_open) \
			and drain_frames < 9000:
		_gl._physics_process(DT)                 # 抽卡在 PLAYING 帧序内分帧消化
		drain_frames += 1
	var drain_ms := float(Time.get_ticks_usec() - t2) / 1000.0
	print("[perf-probe] 溢出批分帧消化 %d 帧 / 全程 %.2f ms（原末批同帧收口 72040 ms 已消除）"
		% [drain_frames, drain_ms])
	Meta.set_setting("auto_select_on", false)    # R189：消化完毕复位（§A 磁盘口径干净）
	_check("P7 收口归零：回 PLAYING、pending/merged 清、无残留卡窗",
		_gl.state == GameConst.GameStatus.PLAYING and _gl.pending_level_ups == 0
		and _gl.merged_overflow_level_ups == 0 and not _gl.card_select_ui.is_open,
		"state=%d pending=%d merged=%d" % [_gl.state, _gl.pending_level_ups,
			_gl.merged_overflow_level_ups])


# ══ §I R188-3 挂机全链路 ═════════════════════════════════════════
func _test_idle() -> void:
	_idle_settings()
	_idle_toggle()
	_idle_auto_pick()
	_idle_shop()
	_idle_settle()
	_idle_soak()


func _idle_settings() -> void:
	# A 设置段（§3.9-2/3：白名单双接线 + 出厂默认）
	_section("A 设置段（auto_select_on / auto_restart_mode 双接线）")
	Meta._settings.erase("auto_select_on")       # 内存抹键模拟旧档缺键——读口回默认表
	Meta._settings.erase("auto_restart_mode")
	_check("A 出厂默认：auto_select_on == false（旧档缺键回默认零迁移）",
		Meta.settings("auto_select_on") == false, str(Meta.settings("auto_select_on")))
	_check("A 出厂默认：auto_restart_mode == 0", Meta.settings("auto_restart_mode") == 0,
		str(Meta.settings("auto_restart_mode")))
	Meta.set_setting("auto_restart_mode", 9)
	_check("A 越界钳制：9 → 2（clampi(0,2) 照 fx_quality 行口径）",
		Meta.settings("auto_restart_mode") == 2, str(Meta.settings("auto_restart_mode")))
	Meta.set_setting("auto_restart_mode", -3)
	_check("A 越界钳制：-3 → 0", Meta.settings("auto_restart_mode") == 0)
	Meta.set_setting("auto_restart_mode", 1)
	_check("A 合法值：1 → 1", Meta.settings("auto_restart_mode") == 1)
	Meta.set_setting("auto_pick_unknown", 1)
	_check("A 未知键忽略：读口 null（DataValidator 白名单口径）",
		Meta.settings("auto_pick_unknown") == null)
	_check("A 未知键忽略：未入 _settings", not Meta._settings.has("auto_pick_unknown"))
	Meta.set_setting("auto_select_on", true)
	var cfg := ConfigFile.new()
	var err := cfg.load(Meta.save_path())
	var vals: Variant = cfg.get_value("settings", "values", {}) if err == OK else {}
	_check("A 磁盘回路：写即落盘（settings/values.auto_select_on==true）",
		vals is Dictionary and bool((vals as Dictionary).get("auto_select_on", false)),
		str(vals))
	var snap: Dictionary = Meta._settings.duplicate()
	Meta._settings = {}
	Meta._load()
	_check("A 磁盘回路：_load() 回读 true", bool(Meta._settings.get("auto_select_on", false)),
		str(Meta._settings))
	Meta._settings = snap.duplicate()            # 快照还原（_load 重读磁盘全段后重放）
	Meta._save()
	_check("A 快照还原：_settings 与进套件前一致", Meta._settings == snap)
	Meta.upgrades = {}
	Meta.crystals = 0
	Meta.character_id = &"sentinel"
	Meta.set_setting("auto_select_on", false)    # B/C 组前置：OFF
	Meta.set_setting("auto_restart_mode", 0)


func _idle_toggle() -> void:
	# B AUTO 开关（§3.9-1 B 组：几何/落盘/五态可见性/模态期可点机制）
	_section("B AUTO 开关（几何落位 + 五态可见性 + 模态期可点）")
	var btn: Button = _gl.hud._auto_btn
	_check("B 开关存在（hud._auto_btn 胶囊按钮）", btn != null)
	if btn == null:
		return
	_check("B 开关几何：落位 x∈[644,704]×y∈[126,190]（波次徽章右/Boss 相位点外唯一空闲带）",
		btn.position.x >= 644.0 and btn.position.x + btn.size.x <= 704.0
		and btn.position.y >= 126.0 and btn.position.y + btn.size.y <= 190.0,
		"pos=%s size=%s" % [str(btn.position), str(btn.size)])
	var auto_rect := Rect2(btn.position, btn.size)
	var pause_rect := Rect2(_gl.hud._pause_btn.position, _gl.hud._pause_btn.size)
	_check("B 开关几何：与暂停钮矩形不相交", not auto_rect.intersects(pause_rect),
		"auto=%s pause=%s" % [str(auto_rect), str(pause_rect)])
	_check("B 开关几何：与波次徽章矩形不相交", not auto_rect.intersects(BADGE_RECT),
		"auto=%s badge=%s" % [str(auto_rect), str(BADGE_RECT)])
	var hover_found := false
	for zone: Dictionary in _gl.hud._hover_zones:
		if zone.get("ctrl") == _gl.hud._auto_capsule:
			hover_found = true
			break
	_check("B 悬停说明：AUTO 胶囊经 _add_hover 注册（三档 mode 语义）", hover_found)
	var st0: bool = bool(Meta.settings("auto_select_on"))
	btn.pressed.emit()
	_check("B 点击翻转：Meta 落值取反（读写单一真源，无缓存 bool）",
		bool(Meta.settings("auto_select_on")) == (not st0), str(Meta.settings("auto_select_on")))
	var cfg := ConfigFile.new()
	var ok := cfg.load(Meta.save_path()) == OK
	var vals: Variant = cfg.get_value("settings", "values", {}) if ok else {}
	_check("B 点击翻转：写即落盘", vals is Dictionary
		and bool((vals as Dictionary).get("auto_select_on", false)) == (not st0), str(vals))
	btn.pressed.emit()
	_check("B 二次点击：回原值（无缓存态）", bool(Meta.settings("auto_select_on")) == st0)
	_check("B 模态期可点机制：HUD process_mode=ALWAYS（tree.paused 冻结战斗仍可切）",
		_gl.hud.process_mode == Node.PROCESS_MODE_ALWAYS)
	_check("B 模态期可点机制：三模态 root 均 MOUSE_FILTER_IGNORE（选卡/商店/结算不拦截）",
		_gl.card_select_ui._root.mouse_filter == Control.MOUSE_FILTER_IGNORE
		and _gl.shop_ui._root.mouse_filter == Control.MOUSE_FILTER_IGNORE
		and _gl.game_over_screen._root.mouse_filter == Control.MOUSE_FILTER_IGNORE)
	_check("B 可见性：MENU 隐藏", not btn.visible)
	_check("B 可见性：PLAYING 显示",
		_gl.start_run() and _gl.state == GameConst.GameStatus.PLAYING and btn.visible)
	_gl._on_level_up(2)
	_check("B 可见性：LEVEL_UP 显示（自动开关恰在选卡期工作，不照抄暂停钮仅 PLAYING）",
		_gl.state == GameConst.GameStatus.LEVEL_UP and btn.visible)
	_gl.card_select_ui.choose(0)
	_check("B 清场：选卡回 PLAYING", _gl.state == GameConst.GameStatus.PLAYING)
	_gl.request_pause()
	_check("B 可见性：PAUSED 隐藏",
		_gl.state == GameConst.GameStatus.PAUSED and not btn.visible)
	_gl.request_resume()
	_gl.player.set("max_hp", 1000000.0)
	_gl.player.set("hp", 1000000.0)
	_kill_player()
	_check("B 可见性：GAME_OVER 隐藏",
		_gl.state == GameConst.GameStatus.GAME_OVER and not btn.visible)
	_gl.quit_to_menu()
	_check("B 可见性：回 MENU 隐藏",
		_gl.state == GameConst.GameStatus.MENU and not btn.visible)


func _idle_auto_pick() -> void:
	# C 选卡真链（§3.9-4/5/6：0.5s 展示窗/描金/成对协议/诅咒不变量 200 seed/OFF 零干预）
	_section("C 选卡真链（0.5s 窗 + 描金 + 成对协议 + 诅咒硬不变量）")
	Meta.set_setting("auto_select_on", true)
	_gl.card_generator.rng.seed = 4242
	_check("C 前置：常规局开局", _gl.start_run() and _gl.state == GameConst.GameStatus.PLAYING)
	_gl.player.set("max_hp", 1000000.0)
	_gl.player.set("hp", 1000000.0)
	_gl.player.set("invuln_left", 9999.0)
	_gl.card_select_ui.choice_made.connect(_on_choice_made_spy)
	# C1 ON 自动选（0.6s 内恰一次 + pkg4 LEVEL UP 文案 + 描金 = 策略首选）
	_choice_sizes.clear()
	var cc0 := _card_chosen_count
	_gl.player.gain_xp(_gl.player.xp_need)
	_check("C1 前置：升级弹卡（LEVEL_UP）",
		_gl.state == GameConst.GameStatus.LEVEL_UP and _gl.card_select_ui.is_open)
	_check("C1 pkg4:296 口径：0.5s 展示窗内 LEVEL UP 文案不变",
		_gl.hud._state_label.text == "LEVEL UP - choose a card",
		str(_gl.hud._state_label.text))
	_gl._physics_process(DT)                     # 展示窗首帧：策略预选描金
	var want_pick := AutoIdleStrategy.pick(_gl.current_candidates, false)
	var hl := _gl.card_select_ui.highlighted_slots()
	var want_hl: Array[int] = [want_pick]
	_check("C1 描金 = 策略首选（单卡槽位一致）",
		want_pick >= 0 and hl == want_hl, "pick=%d hl=%s" % [want_pick, str(hl)])
	var used := _drive_until_state(GameConst.GameStatus.PLAYING, PICK_WINDOW_FRAMES)
	_check("C1 0.6s 内自动选完成", used > 0 and used <= PICK_WINDOW_FRAMES, "frames=%d" % used)
	_check("C1 choice_made 恰一次（普通单张）",
		_choice_sizes.size() == 1 and _choice_sizes[0] == 1, str(_choice_sizes))
	_check("C1 card_chosen 恰 +1（Meta 图鉴口径真链）", _card_chosen_count == cc0 + 1,
		"%d → %d" % [cc0, _card_chosen_count])
	_check("C1 state 回 PLAYING", _gl.state == GameConst.GameStatus.PLAYING)
	# C2 双级连升逐次消化（排队 → 每级各选一次）。经验曲线 14×lv^1.4——固定 2.5×xp_need
	# 在高等级段只跨一个阈值（经验余量随 map 祝福浮动，非确定性夹具）；改按 1.2×need
	# 逐次投喂至恰 +2 级（每次投喂至多跨 1 阈值，曲线单调递增保证），连升形态确定。
	_choice_sizes.clear()
	var cc1 := _card_chosen_count
	var lv0 := int(_gl.player.get("level"))
	var feeds := 0
	while int(_gl.player.get("level")) < lv0 + 2 and feeds < 40:
		_gl.player.gain_xp(_gl.player.xp_need * 1.2)
		feeds += 1
	_check("C2 前置：双级连升首级弹卡 + 排队 1（投喂 %d 次）" % feeds,
		_gl.state == GameConst.GameStatus.LEVEL_UP and _gl.pending_level_ups == 1,
		"pending=%d lv=%d" % [_gl.pending_level_ups, int(_gl.player.get("level"))])
	var used2 := -1
	for i in range(200):
		_gl._physics_process(DT)
		if _gl.state == GameConst.GameStatus.PLAYING and _gl.pending_level_ups == 0:
			used2 = i + 1
			break
	_check("C2 逐次消化：两次各选 1 次后回 PLAYING",
		used2 > 0 and _choice_sizes.size() == 2 and _gl.pending_level_ups == 0,
		"frames=%d sizes=%s" % [used2, str(_choice_sizes)])
	_check("C2 card_chosen 恰 +2", _card_chosen_count == cc1 + 2,
		"%d → %d" % [cc1, _card_chosen_count])
	# C3 成对槽位协议（地狱 → dual）：策略槽位 ∈[4,9]、同行双亮、整行带走
	_choice_sizes.clear()
	_gl._difficulty = 2                          # 地狱 → GameConst.difficulty_dual_pick 恒真
	var cc2 := _card_chosen_count
	_gl.player.gain_xp(_gl.player.xp_need)
	_check("C3 前置：地狱成对货架 6 卡",
		_gl.state == GameConst.GameStatus.LEVEL_UP and _gl.current_candidates.size() == 6,
		"n=%d" % _gl.current_candidates.size())
	_gl._physics_process(DT)
	var slot_probe := AutoIdleStrategy.pick(_gl.current_candidates, true)
	var hl2 := _gl.card_select_ui.highlighted_slots()
	_check("C3 成对策略槽位 ∈[4,9] 且同行双亮（描金 2 槽）",
		slot_probe >= 4 and slot_probe <= 9 and hl2.size() == 2,
		"slot=%d hl=%s" % [slot_probe, str(hl2)])
	var used3 := _drive_until_state(GameConst.GameStatus.PLAYING, PICK_WINDOW_FRAMES)
	_check("C3 成对整行：choice_made 载荷 2 张",
		used3 > 0 and _choice_sizes.size() == 1 and _choice_sizes[0] == 2,
		"frames=%d sizes=%s" % [used3, str(_choice_sizes)])
	_check("C3 card_chosen 恰 +2（成对两卡各应用一次）", _card_chosen_count == cc2 + 2,
		"%d → %d" % [cc2, _card_chosen_count])
	_gl._difficulty = 0                          # 还原难度（后续组常规口径）
	# C4 诅咒硬不变量：200 seed 扫描（GAMBLER 诅咒局面，含成对 6 卡）恒指向非诅咒卡/行
	var gen := _gl.card_generator
	var ctx := {"player": _gl.player, "wave": 30, "deal_count": 6, "curse_last": true,
		"min_rarity_floor": -1}
	var scenarios := 0
	var ok_curse := true
	var detail := ""
	for s in range(CURSE_SCAN_SEEDS):
		gen.rng.seed = s
		gen._slot_rng.seed = s
		var cands := gen.generate_candidates(ctx)
		if cands.size() < 4 or not bool(cands[3].get("cursed", false)):
			ok_curse = false
			detail = "seed=%d 非诅咒局面（夹具失真）" % s
			break
		scenarios += 1
		var i_single := AutoIdleStrategy.pick(cands, false)
		if i_single < 0 or i_single >= cands.size() \
				or bool(cands[i_single].get("cursed", false)):
			ok_curse = false
			detail = "seed=%d 普通输出指向诅咒（i=%d）" % [s, i_single]
			break
		var slot := AutoIdleStrategy.pick(cands, true)
		if slot < 4 or slot > 9:
			ok_curse = false
			detail = "seed=%d 成对输出越界（slot=%d）" % [s, slot]
			break
		for k in range(2):
			var li := slot - 4 + k
			if li < cands.size() and bool(cands[li].get("cursed", false)):
				ok_curse = false
				detail = "seed=%d 成对行含诅咒（slot=%d）" % [s, slot]
				break
		if not ok_curse:
			break
	_check("C4 诅咒硬不变量：%d seed 扫描（含成对 6 卡）恒指向非诅咒卡/行"
		% CURSE_SCAN_SEEDS, ok_curse and scenarios == CURSE_SCAN_SEEDS, detail)
	# C5 OFF 零干预
	Meta.set_setting("auto_select_on", false)
	_choice_sizes.clear()
	_gl.player.gain_xp(_gl.player.xp_need)
	_check("C5 前置：OFF 弹卡",
		_gl.state == GameConst.GameStatus.LEVEL_UP and _gl.card_select_ui.is_open)
	_drive_frames(120)                           # 1s > 0.6s 窗
	_check("C5 OFF 零干预：1s 后仍 LEVEL_UP 未选",
		_gl.state == GameConst.GameStatus.LEVEL_UP and _gl.card_select_ui.is_open
		and _choice_sizes.is_empty(), str(_choice_sizes))
	_gl.card_select_ui.choose(0)
	_check("C5 清场：回 PLAYING", _gl.state == GameConst.GameStatus.PLAYING)


func _idle_shop() -> void:
	# D 商店自动离店（§3.9-7：三源汇总口 + 战前补给源，金币零变动）
	_section("D 商店自动离店（三源汇总 + 零损失）")
	Meta.set_setting("auto_select_on", true)
	# D1 波表 SHOP 源
	var g0 := int(_gl.player.get("gold"))
	_gl._on_shop_requested(5)
	_check("D1 前置：黑市开店（LEVEL_UP）",
		_gl.state == GameConst.GameStatus.LEVEL_UP and _gl.shop_ui.is_shop_visible())
	var used := _drive_until_shop_closed(SHOP_WINDOW_FRAMES)
	_check("D1 0.8s 后自动离店", used > 0 and used <= SHOP_WINDOW_FRAMES, "frames=%d" % used)
	_check("D1 state 回 PLAYING", _gl.state == GameConst.GameStatus.PLAYING)
	_check("D1 金币零变动（不代买不烧金）", int(_gl.player.get("gold")) == g0,
		"%d → %d" % [g0, int(_gl.player.get("gold"))])
	# D2 战前补给源（final Boss 波前一波清空 → 固定商店）
	var final_wave := int(MapTable.get_map(_gl.current_map_id).get("final_wave", 10))
	var g1 := int(_gl.player.get("gold"))
	_gl._on_wave_cleared_pre_boss_shop(final_wave - 1)
	_check("D2 前置：战前补给开店",
		_gl.state == GameConst.GameStatus.LEVEL_UP and _gl.shop_ui.is_shop_visible())
	var used2 := _drive_until_shop_closed(SHOP_WINDOW_FRAMES)
	_check("D2 战前补给自动离店", used2 > 0 and used2 <= SHOP_WINDOW_FRAMES,
		"frames=%d" % used2)
	_check("D2 金币零变动", int(_gl.player.get("gold")) == g1,
		"%d → %d" % [g1, int(_gl.player.get("gold"))])
	# D2 隔离收口（防 D2 态泄漏进 D3——战前补给源漏挂自动窗时手动关店回 PLAYING）
	if _gl.shop_ui.is_shop_visible():
		_gl.shop_ui.close()
	_check("D2 收口：回 PLAYING（D3 独立前置）", _gl.state == GameConst.GameStatus.PLAYING)
	# D3 REL_BLACK_MARKET 追加商店波排程源（relic_handler 排程 → 同汇 _on_shop_requested）
	_gl.relic_handler.pending_shop_waves = 1
	var g2 := int(_gl.player.get("gold"))
	_gl._on_relic_shop_wave(9)
	_check("D3 前置：遗物排程开店（三源同汇口）",
		_gl.state == GameConst.GameStatus.LEVEL_UP and _gl.shop_ui.is_shop_visible())
	var used3 := _drive_until_shop_closed(SHOP_WINDOW_FRAMES)
	_check("D3 遗物排程源自动离店", used3 > 0 and used3 <= SHOP_WINDOW_FRAMES,
		"frames=%d" % used3)
	_check("D3 金币零变动", int(_gl.player.get("gold")) == g2,
		"%d → %d" % [g2, int(_gl.player.get("gold"))])
	Meta.set_setting("auto_select_on", false)


func _drive_until_shop_closed(p_max: int) -> int:
	for i in range(p_max):
		_gl._physics_process(DT)
		if not _gl.shop_ui.is_shop_visible():
			return i + 1
	return -1


func _idle_settle() -> void:
	# E 结算四案（§3.9-8/9：mode0 负向/mode1 重开+点按取消/mode2 自动无尽/每日回退）
	_section("E 结算自动重开（mode0/1/2 + 每日回退）")
	Meta.set_setting("auto_select_on", false)    # E 组只测重开域（选卡域 C 组已锁）
	Meta.set_setting("auto_restart_mode", 0)
	var runs0 := int(Meta.records["total_runs"])
	_kill_player()
	_check("E1 前置：死亡进 GAME_OVER", _gl.state == GameConst.GameStatus.GAME_OVER)
	_drive_frames(600)                           # 5s
	_check("E1 mode0 负向：5s 仍 GAME_OVER 不重开", _gl.state == GameConst.GameStatus.GAME_OVER)
	_check("E1 mode0 负向：无倒计时挂起", not _gl.game_over_screen.is_auto_countdown_active())
	_check("E1 mode0 结算恰 +1（total_runs 无双记）", int(Meta.records["total_runs"]) == runs0 + 1,
		"%d → %d" % [runs0, int(Meta.records["total_runs"])])
	_check("E1 mode0 手动重开放行（既有契约）",
		_gl.restart_run() and _gl.state == GameConst.GameStatus.PLAYING)
	# E2 mode1 点按取消：倒计时挂起 → 按 RestartButton → 取消不重开（无双记）
	Meta.set_setting("auto_restart_mode", 1)
	var runs1 := int(Meta.records["total_runs"])
	_kill_player()
	_drive_frames(120)                           # 1s（< 3s 倒计时）
	var cd_label := _find_node(_gl.game_over_screen, "AutoCountdownLabel") as Label
	_check("E2 mode1 倒计时挂起（GameLoop 每帧喂秒）",
		_gl.game_over_screen.is_auto_countdown_active()
		and _gl.game_over_screen.auto_countdown_left() > 0.0,
		"active=%s left=%f" % [str(_gl.game_over_screen.is_auto_countdown_active()),
			_gl.game_over_screen.auto_countdown_left()])
	_check("E2 倒计时文案：卡面内 Label（N 秒后自动再来一局 · 点按取消）",
		cd_label != null and cd_label.visible
		and cd_label.text.contains("秒后自动再来一局") and cd_label.text.contains("点按取消"),
		str(cd_label.text if cd_label != null else "<null>"))
	var restart_btn := _find_node(_gl.game_over_screen, "RestartButton") as Button
	_check("E2 前置：RestartButton 在", restart_btn != null)
	restart_btn.pressed.emit()
	_check("E2 点按取消：立即回 PLAYING", _gl.state == GameConst.GameStatus.PLAYING)
	_check("E2 点按取消：倒计时撤销 + 文案收起",
		not _gl.game_over_screen.is_auto_countdown_active()
		and (cd_label == null or not cd_label.visible))
	var ws_mark := _wave_started_count
	_drive_frames(360)                           # 再 3s：残留计时若未取消会二次重开
	_check("E2 点按取消：无二次重开（wave_started 不再派发）",
		_wave_started_count == ws_mark, "%d vs %d" % [_wave_started_count, ws_mark])
	_check("E2 mode1 结算恰 +1（无双记）", int(Meta.records["total_runs"]) == runs1 + 1,
		"%d → %d" % [runs1, int(Meta.records["total_runs"])])
	# E3 mode1 不干预：~3s 自动重开 + total_runs 恰 +1
	var runs2 := int(Meta.records["total_runs"])
	_kill_player()
	var used := _drive_until_state(GameConst.GameStatus.PLAYING, RESTART_WINDOW_FRAMES)
	_check("E3 mode1 ~3s 自动重开（restart_run 真链）", used > 0 and used <= RESTART_WINDOW_FRAMES,
		"frames=%d" % used)
	_check("E3 mode1 结算恰 +1（无双记）", int(Meta.records["total_runs"]) == runs2 + 1,
		"%d → %d" % [runs2, int(Meta.records["total_runs"])])
	# E4 mode2 通关自动无尽：通关屏 ~3s → continue_endless 真链（波次越过 final_wave）
	Meta.set_setting("auto_restart_mode", 2)
	_check("E4 前置：非每日局", not Meta.is_run_daily())
	var final_wave := int(MapTable.get_map(_gl.current_map_id).get("final_wave", 10))
	_gl._on_wave_cleared_victory(final_wave)     # 清 final 波 → 2.2s 收尾窗 → 通关屏
	var vused := _drive_until_state(GameConst.GameStatus.GAME_OVER, VICTORY_WINDOW_FRAMES)
	_check("E4 前置：通关收尾窗 → 通关屏（无尽出口可见）",
		vused > 0 and _gl.game_over_screen.is_endless_offer_visible(), "frames=%d" % vused)
	var eused := _drive_until_state(GameConst.GameStatus.PLAYING, RESTART_WINDOW_FRAMES)
	_check("E4 mode2 ~3s 自动无尽（continue_endless 真链）", eused > 0, "frames=%d" % eused)
	_check("E4 波次越过 final_wave（保构筑续打）",
		_gl.wave_director.current_wave > final_wave,
		"wave=%d final=%d" % [_gl.wave_director.current_wave, final_wave])
	_gl.request_pause()
	_gl.quit_to_menu()                           # PAUSED → MENU（清场）
	# E5 每日局回退：mode1/2 一律停结算（5s 后仍 GAME_OVER——防无限重刷当日）
	_check("E5 前置：每日局开局",
		_gl.start_run(Meta.daily_seed(Meta.daily_date_key())) and Meta.is_run_daily())
	_kill_player()
	_drive_frames(600)                           # 5s
	_check("E5 每日局 mode2 回退：5s 仍 GAME_OVER", _gl.state == GameConst.GameStatus.GAME_OVER)
	Meta.set_setting("auto_restart_mode", 1)
	_check("E5 每日局手动重开放行", _gl.restart_run()
		and _gl.state == GameConst.GameStatus.PLAYING)
	_kill_player()
	_drive_frames(600)
	_check("E5 每日局 mode1 回退：5s 仍 GAME_OVER", _gl.state == GameConst.GameStatus.GAME_OVER)
	Meta.set_setting("auto_restart_mode", 0)
	_gl.quit_to_menu()                           # GAME_OVER → MENU（清场）


func _idle_soak() -> void:
	# F 全链 soak（§3.9-10：全开 + mode2 ≥3000 帧；无 >10s 停留 / 波次单调不减）
	_section("F 全链 soak（全开 + mode2，%d 帧 ≥3000）" % SOAK_FRAMES)
	Meta.set_setting("auto_select_on", true)
	Meta.set_setting("auto_restart_mode", 2)
	_check("F 前置：常规局开局", _gl.start_run() and _gl.state == GameConst.GameStatus.PLAYING)
	_gl.player.set("max_hp", 1000000.0)          # 存活性垫层（soak 不测死亡数值，测出口不漏接）
	_gl.player.set("hp", 1000000.0)
	_choice_sizes.clear()
	var prev_wave := _gl.wave_director.current_wave
	var prev_state := _gl.state
	var lu_streak := 0
	var go_streak := 0
	var max_lu := 0
	var max_go := 0
	var wave_violations := 0
	var max_wave := prev_wave
	for i in range(SOAK_FRAMES):
		_gl._physics_process(DT)
		var st := _gl.state
		lu_streak = (lu_streak + 1) if st == GameConst.GameStatus.LEVEL_UP else 0
		go_streak = (go_streak + 1) if st == GameConst.GameStatus.GAME_OVER else 0
		max_lu = maxi(max_lu, lu_streak)
		max_go = maxi(max_go, go_streak)
		# 重开瞬间（GAME_OVER→PLAYING）波次合法归 1——单帧豁免；其余波次回退均计违例
		var grace := prev_state == GameConst.GameStatus.GAME_OVER \
			and st == GameConst.GameStatus.PLAYING
		var w := _gl.wave_director.current_wave
		if w < prev_wave and not grace:
			wave_violations += 1
		prev_wave = w
		max_wave = maxi(max_wave, w)
		prev_state = st
	_check("F soak：LEVEL_UP 连续停留 ≤10s（%d 帧）" % STREAK_CAP, max_lu <= STREAK_CAP,
		"max=%d" % max_lu)
	_check("F soak：GAME_OVER 连续停留 ≤10s（%d 帧）" % STREAK_CAP, max_go <= STREAK_CAP,
		"max=%d" % max_go)
	_check("F soak：波次单调不减（重开瞬间豁免）", wave_violations == 0,
		"violations=%d" % wave_violations)
	# 遥测（如实报告，不作硬断言：推进速度依赖自然战斗强度）
	print("[idle soak] 遥测：max_wave=%d 自动选卡 %d 次 max_lu=%d帧 max_go=%d帧 波次违例=%d"
		% [max_wave, _choice_sizes.size(), max_lu, max_go, wave_violations])
	Meta.set_setting("auto_select_on", false)
	Meta.set_setting("auto_restart_mode", 0)
