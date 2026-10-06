# tests/probe_r237_renderattr_cases.gd（R237 战斗期渲染轴归因用例体——入口运行时加载）
# 复现口径（如实登记，判读须与本节对照）：
# · 夹具=qa_r230_dcscan_cases 同构（content v2 深载构成：world_grove 波表 index==16
#   平铺池循环补位 ≤8/渲染帧 + E7_spitter 射手切片×5 + 精英 affix_ring + 弹池注入
#   + W5_prism L5 镜5；风筝同式（相位推 _gl.frame_stamp——物理帧号）；hp/xp_need 1e12；
#   W2_gatling L5 五词条 PIERCE×3/MULTI×2/BOUNCE×3/KILL_BLAST×2/FRACTAL×2）。
#   哨兵全套同 R230：fullload=1/位图=1/补烤=1/结算帽=-3/调速器冻结 tier2/burst_thin=-3/
#   pool_valve=-3/deathpop_cap=-3 + Meta 内存注入 fx_quality=1/damage_numbers_on/
#   fx_opacity=1.0 + persist_defer 挂起 + 色差件逐帧 RS 隐藏 + APPDATA 沙箱。
# · ★驱动=物理引擎自然驱动（probe_r237_physattr run3-5 定标——勿手动步进）：
#   Engine.physics_ticks_per_second 运行时注入 60Hz（工程默认 120Hz 自然驱动深载
#   崩 8fps 实证，run1 留档）+ 敌血 ×1.0（0.3 会致 MEC_FRACTAL 分裂/死亡新星级联
#   把弹股推顶池帽、敌驻场塌——run1/2 留档）。定标预期：敌 115-120 常驻、弹 280-350
#   （content v2 另加敌弹 ~25）。夹具只做每渲染帧 风筝/补位/臂注入。
# · ★渲ms 读数前提=探针侧关 vsync（DisplayServer.window_set_vsync_mode DISABLED，
#   teardown 还原——窗口显示设置注入，零产品码）：桌面 vsync 开时帧时钳 ~16.7ms，
#   渲ms 刀效差全被吞（真机无此钳——渲ms 13-17ms>菜单 8.4ms 即证）。渲ms 同式键=
#   debug_stats.gd R235 搭车③：当窗渲染帧耗时均值 ms（delta 累计÷帧数；本探针以
#   await process_frame 墙钟间隔计量，注入走查在计量窗起点前——刀臂 replay 开销
#   不入渲ms，方向=低估刀收益，披露）。dc 读数协议=R230 同款（上一完成帧口径）。
# · ★RS 态自愈：_measure_window/_plain_window/_settle/_warm_to_steady 每帧调
#   _replay_masks（无掩码无单件隐藏且非脏=零操作）——任何前序掩码/单件隐藏残留由
#   下一臂首帧全树走查恢复自然可见（P1/P2 → M2b → 快刀臂的臂间恢复不走漏）。
# · 臂序（每臂 ≥40s 稳态测量，双下限 ≥40s 墙钟 且 ≥2400 物理步，帽 75s）：
#   MENU 菜单基线（boot 后未 start_run：dc/渲ms/桶 + P1 谱——增量份额分母）→
#   BATTLE 战斗基线（清场+驻场120+暖 1200 步 → 40s 基线〔M1 dc/渲ms/桶遥测逐秒
#   系列 + M2a 相关性源数据〕→ 60 帧锚 → P1 累积关断 13 族〔边际 dc〕→ 残差窗 →
#   P2 单独可见 13 族 → M2b 敌桶穿插件逐件 dc〔R228 口径：单件 RS 隐藏 窗前后差〕）→
#   K_POP / K_DECOR / K_FX 三快刀臂（各自独立非叠加：同场配对 A/B——清场重驻场
#   暖 1200 步 → 40s 刀关 → 置刀+settle ≥300 步 → 40s 刀开；差=纯刀效，无跨臂漂移）。
# · 三快刀（测量证，禁改产品码）：
#   K_POP 跳字满载门帽 8：popup_manager._active_list 逐帧把最老 (N−8) 条 node
#   visible=false（产品 retire-oldest 同语义——队尾=最新保显）。夹具帽口径披露：
#   桌面 fx_quality=1 帽=40（mobile+满载 24 分支桌面不可达），活口基线≈40——刀效
#   读数=「活>8 全隐」，真机 24→8 外推=按每条 dc 线性折算另列（derive 键）。
#   K_DECOR 敌满载装饰全隐：敌根子件名 Crown/GroundShadow/ArmorPlate/FuseRing/
#   BurnEmber/Sparkle*/Satellite*/BurnFlame* 逐帧 visible=false（R225 刀2 同族——
#   产品 _apply_fullload_decor 在 fullload_override=1 下已隐 皇冠/底影/微光/卫星，
#   本刀测残余面=甲板/FuseRing/余烬/火苗 等未收录件，披露）。
#   K_FX fx 粒子全关：elemental_fx 层根逐帧 visible=false（F7 特效层整体）。
# · 判读白名单：族占比/增量份额/刀后相对降幅（R230 §1.5 同款）；桌面绝对值≠真机
#   ——只做归因排序与相对降幅，不做收益外推。
# 纪律：只读不改游戏代码（scripts/scenes/autoload 零触碰）；禁 user:// 真档写（沙箱+
#   persist_defer 双保险）；禁战斗期烤图（runstart 烤图开局一次性）；无 test_ 前缀不
#   入电池；watchdog 兜底 quit。
extends RefCounted

const MAIN_SCENE := "res://scenes/main.tscn"
const GROVE_TABLE := "res://resources/maps/wave_table_grove.tres"
const PROBE_PHYS_HZ := 60                  # 探针侧物理频率（run1 120Hz 崩 8fps 实证——physattr 同款）
const PROBE_MAX_PHYS_STEPS := 2            # 探针侧物理追赶帽（工程默认 8）：smoke 实证深载步成本
                                          # ~10-15ms 下 8 步追赶自持螺旋（~130ms/帧 7-9fps）把渲ms
                                          # 变成物理轴读数——帽 2 = 螺旋结构性不可达（帧 ≤2步+渲染），
                                          # fps<30 时模拟优雅降速=真机模30/模8 设计内降级同族
const HOLD := 120                          # 驻场敌数（vc40 深载段常驻值）
const TOPUP_PER_FRAME := 8                 # SPAWN_PER_FRAME 同款补位节流
const MEASURE_MIN_WALL_S := 40.0           # 任务下限①：≥40s
const MEASURE_MIN_STEPS := 2400            # 任务下限②：≥2400 物理步（40s×60Hz）
const MEASURE_MAX_WALL_S := 75.0           # 防拖挂帽
const MEASURE_MAX_STEPS := 4500
const SETTLE_KNIFE_STEPS := 300            # 快刀置刀后 settle（5s@60Hz）
const SETTLE_KNIFE_MAX_S := 8.0
const MENU_WARMUP_S := 3.0                 # 菜单入场动画/云层起稳
# ── 饱和暖机（smoke 实证：dc 随战斗模拟时间爬升——变体桶累积+受击闪白断批带展宽
#    ——后才进平台；真机深载 dc 600-1010 对应饱和态，新鲜态读数系统性低估。判稳走
#    物理步=模拟时间（追赶帽 2 下 fps 30-45 时墙钟≠模拟时，步基判稳与 fps 解耦）──
const STEADY_MIN_STEPS := 3600              # 饱和暖机下限（60s 模拟时）
const STEADY_MAX_STEPS := 9000              # 帽（150s 模拟时）
const STEADY_WIN_STEPS := 600               # dc 中位判窗（10s 模拟时；带内振荡 ±15-25%
                                          # 是深载场固有=真机 600-1010 带宽同源——判稳=平台带）
const STEADY_TOL_PCT := 20.0                # 相邻两窗中位变化 ≤20% 判稳
const DISCARD_FRAMES := 3                  # R230 同款读数窗
const SETTLE_FRAMES := 10
const SAMPLE_FRAMES := 30
const ANCHOR_FRAMES := 60                  # P1 望远镜锚（新鲜基线窗）
const PLAYER_HOME := Vector2(360.0, 900.0)
const ENEMY_HP_SCALE := 1.0                # physattr run3-5 定标（0.3=弹股级联坑，头注）
const SANDBOX_MARKER := ".qa_sandbox_r237"
const OUT_JSON := "res://docs/qa/probe_r237_renderattr.json"
# 运行时副本（smoke 档缩短窗——const 不可重赋，各臂读 *_B 变量）
var MEASURE_MIN_WALL_S_B := MEASURE_MIN_WALL_S
var MEASURE_MIN_STEPS_B := MEASURE_MIN_STEPS
var SAMPLE_FRAMES_B := SAMPLE_FRAMES
var STEADY_MIN_STEPS_B := STEADY_MIN_STEPS
var STEADY_MAX_STEPS_B := STEADY_MAX_STEPS
var STEADY_WIN_STEPS_B := STEADY_WIN_STEPS
# ── content v2 构成注入（R230 FG4 fork 同款）─────────────────────────
const SPITTER_ID := &"E7_spitter"           # RANGED 原型（fire_cd 2.4s/弹寿命 5.0s→稳态 ~2 发/射手）
const SPITTER_COUNT := 5
const ELITE_AFFIX := &"affix_ring"          # 精英词缀：8 发环弹/7s + AffixCircle 读条圈
const PRISM_LEVEL := 5
const PRISM_SPLIT := 2                      # MEC_MIRROR_SPLIT×2 → 镜 5（MIRROR_CAP）
# ── 快刀参数 ────────────────────────────────────────────────────────
const KNIFE_POP_KEEP := 8                   # K_POP：跳字保显条数（真机刀口径 24→8 的「8」）
const DECOR_EXACT := {"Crown": true, "GroundShadow": true, "ArmorPlate": true,
	"FuseRing": true, "BurnEmber": true}
const DECOR_PREFIX := ["Sparkle", "Satellite", "BurnFlame"]
const M2_ITEM_SAMPLE := 8                   # M2b 穿插件逐件抽查上限
# ── 13 族分类（R230 content v2 同表）────────────────────────────────
const DOM_ENEMY := 20                       # 内部域码（敌桶域 F1/F2/F3 逐件细分）
const F_COUNT := 13
const F_NAMES: Array[String] = [
	"F1敌桶本体", "F2敌子件装饰", "F3敌桶穿插件", "F4弹桶", "F5碎片桶", "F6粒子发射器",
	"F7特效层", "F8跳字", "F9HUD/BossBar", "F10云背景", "F11玩家树", "F12激光网+残余",
	"F13敌弹",
]
const ENEMY_PROJ_FAM := 13
const FG3_TOL := 5                          # 望远镜闭环容差（R230 同款）
const FG3_TOL_DISCLOSED := 8
const LOAD_ENEMY_BAND := Vector2i(110, 120) # 定标带（run3-5：115-120 常驻）
const LOAD_PROJ_BAND := Vector2i(200, 430)  # 定标 280-350 + content v2 敌弹~25 + 漂移余量（披露带）

var tree: SceneTree
var _gl: GameLoop = null
var _fails: int = 0
var _comp: Array[Dictionary] = []           # 平铺构成池 {data: EnemyData, tags: int}
var _cursor: int = 0
var _smoke: bool = false                    # -- --smoke：管线烟测（不落 JSON）
var _plateau: bool = false                  # -- --plateau：深老化档（run1 实证平台 ~25k 步）
var _phys_hz_project := 120                 # 工程默认物理频率（注入前快照——teardown 还原）
var _phys_steps_project := 8                # 工程默认物理追赶帽（注入前快照——teardown 还原）
var _vsync_prev: int = -1                   # vsync 原值（探针侧关 vsync——渲ms 读数前提，头注）
var _knife := ""                            # 当前快刀（""=无；K_POP/K_DECOR/K_FX）
var _battle_field := false                  # 战斗场态（menu 臂跳过 风筝/补位）
var _steady_warm := {}                     # 饱和暖机曲线（入 JSON——新鲜态→饱和态爬升留档）
# ── R230 掩码机器（RS 层族掩码 + 逐帧重放 + M2b 单件隐藏集）──────────
var _masked: Dictionary = {}               # fam(int) -> true（当前关断族集）
var _exempt: int = 0                       # P2 豁免族
var _mask_dirty: bool = true
var _hidden_items: Dictionary = {}         # instance_id -> true（M2b 单件隐藏集）
var _fam_root_map: Dictionary = {}         # Node -> 域码
var _churn_roots: Array = []               # [[Node, 域码]]——逐帧重放域
var _chrom_node: CanvasItem = null         # 色差件（逐帧 RS 隐藏）
# ── 结果 ────────────────────────────────────────────────────────────
var _results: Dictionary = {}              # MENU/BATTLE/快刀臂（入 JSON）
var _gate_results: Dictionary = {}


func run(p_tree: SceneTree) -> void:
	tree = p_tree
	_smoke = OS.get_cmdline_user_args().has("--smoke")
	_plateau = OS.get_cmdline_user_args().has("--plateau")
	_phys_hz_project = Engine.physics_ticks_per_second
	_phys_steps_project = Engine.max_physics_steps_per_frame
	if _smoke:
		MEASURE_MIN_WALL_S_B = 3.0
		MEASURE_MIN_STEPS_B = 200
		SAMPLE_FRAMES_B = 10
		STEADY_MIN_STEPS_B = 240
		STEADY_MAX_STEPS_B = 600
		STEADY_WIN_STEPS_B = 120
	elif _plateau:
		# run1 实证：判稳门（20%/600步窗）对慢爬升（变体桶累积）过早放行——3600 步
		# dc~300 判稳后场仍在爬（K_NULL 臂 697→959 伪差 −262 超带）；~7min（≈25k 步）
		# 才入 ~1000-1100 平台（=真机深载带上沿）。plateau 档=深老化下限强制。
		STEADY_MIN_STEPS_B = 18000
		STEADY_MAX_STEPS_B = 27000
	seed(20261006)
	print("══ R237 渲染轴归因：MENU 基线 + BATTLE 饱和谱(P1/P2)+M2 断批 + 空刀对照 + 三快刀配对 A/B（%s档%s）══"
		% ["窗口 gl_compatibility",
			" · smoke" if _smoke else (" · plateau 深老化" if _plateau else "")])
	if DisplayServer.get_name() == "headless":
		_gate("G-渲染器在场（本探针=渲染轴归因，headless dc 恒 0 无意义）", false,
			"DisplayServer=headless——须按头注命令窗口跑（勿 --headless）")
		return
	if not _sandbox_check():
		_teardown_static()
		return
	# 探针侧关 vsync（渲ms 读数前提——头注；teardown 还原）
	_vsync_prev = DisplayServer.window_get_vsync_mode()
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	Engine.physics_ticks_per_second = PROBE_PHYS_HZ
	Engine.max_physics_steps_per_frame = PROBE_MAX_PHYS_STEPS   # 追赶螺旋帽（头注）
	if not _boot_base():
		await _teardown()
		return
	await _arm_menu()
	if not _boot_battle():
		await _teardown()
		return
	await _arm_battle()
	# 四刀臂链式共场（饱和态一次建立，臂间不清场——配对 A/B 控漂移，空刀控程式伪差）
	await _arm_knife("K_NULL")
	await _arm_knife("K_POP")
	await _arm_knife("K_DECOR")
	await _arm_knife("K_FX")
	_derive()
	if not _smoke:
		_store_json()
	await _teardown()


func fail_count() -> int:
	return _fails


# ── 引导Ⅰ（菜单前段：哨兵+窗口实例——start_run 之前）────────────────

func _boot_base() -> bool:
	# ★Meta 内存注入须 add_child 前（池预热在 _ready 期——R230 复审节口径，禁
	#   Meta.set_setting 写即存口）；persist_defer 全程挂起（_save 短路零落盘）
	var s: Dictionary = Meta.get("_settings")
	s["fx_quality"] = 1
	s["damage_numbers_on"] = true
	s["fx_opacity"] = 1.0
	Meta.settings_changed.emit(&"fx_quality")
	Meta.begin_persist_defer()
	var scene: PackedScene = load(MAIN_SCENE)
	_gl = scene.instantiate() as GameLoop
	_gl.name = "ProbeR237Renderattr"
	Enemy.fullload_override = 1
	DamagePopup.bitmap_override = 1
	PopupGlyphAtlas.runstart_bake_override = 1
	DamagePipeline.settle_budget_override = -3
	tree.root.add_child(_gl)
	if not (_gl.boot_ready and _gl.state == GameConst.GameStatus.MENU):
		push_error("[probe] Boot 失败：%s" % str(_gl.boot_fatal))
		_fails += 1
		return false
	PerfGovernor.set_process(false)
	PerfGovernor.mode_override = 0
	PerfGovernor.tier_override = 2
	GameFeelDirector.burst_thin_override = -3
	GameLoop.pool_valve_override = -3
	Enemy.deathpop_cap_override = -3
	if _gl.game_feel != null and _gl.game_feel.chromatic_rect != null:
		_chrom_node = _gl.game_feel.chromatic_rect
	_build_fam_roots()
	print("bootⅠ：菜单态就绪 | 哨兵 fullload=1 位图=1 补烤=1 结算帽=-3 tier=2 burst_thin=-3 pool_valve=-3 deathpop_cap=-3 | phys=%dHz（工程 %d）vsync=%d→DISABLED | persist_defer=1"
		% [PROBE_PHYS_HZ, _phys_hz_project, _vsync_prev])
	return true


# ── 引导Ⅱ（战斗段：start_run+构筑+构成）────────────────────────────

func _boot_battle() -> bool:
	_battle_field = true
	_gl.current_map_id = &"world_grove"
	if not _gl.start_run():
		push_error("[probe] start_run 失败")
		_fails += 1
		return false
	_gl.player.set("xp_need", 1.0e12)       # ≥40s 窗不开选卡
	_gl.player.set("max_hp", 1.0e12)
	_gl.player.set("hp", 1.0e12)
	_gl.player.unlocked_slots = 6
	_gl.player.global_position = PLAYER_HOME
	var gatling: WeaponBase = _gl.player.add_weapon(_gl.registry.get_weapon(&"W2_gatling"))
	if gatling == null:
		push_error("[probe] W2 加特林装配失败")
		_fails += 1
		return false
	gatling.level = 5
	var ok := {"pierce": 0, "multi": 0, "bounce": 0, "nova": 0, "fractal": 0}
	for i in range(3):
		if gatling.attach_trait(_gl.registry.get_trait(&"AFF_PIERCE")):
			ok["pierce"] += 1
	for i in range(2):
		if gatling.attach_trait(_gl.registry.get_trait(&"AFF_MULTI")):
			ok["multi"] += 1
	for i in range(3):
		if gatling.attach_trait(_gl.registry.get_trait(&"MEC_BOUNCE")):
			ok["bounce"] += 1
	for i in range(2):
		if gatling.attach_trait(_gl.registry.get_trait(&"MEC_KILL_BLAST")):
			ok["nova"] += 1
	for i in range(2):
		if gatling.attach_trait(_gl.registry.get_trait(&"MEC_FRACTAL")):
			ok["fractal"] += 1
	var prism := MirrorWeapon.new()
	prism.setup(_gl.registry.get_weapon(&"W5_prism"), _gl.player, _gl.player.get("_deps"))
	prism.meta_atk_pct = 0.0
	if not _gl.player.equip_weapon(prism):
		push_error("[probe] W5 棱镜装配失败")
		_fails += 1
		return false
	prism.level = PRISM_LEVEL
	var split_ok := 0
	for i in range(PRISM_SPLIT):
		if prism.attach_trait(_gl.registry.get_trait(&"MEC_MIRROR_SPLIT")):
			split_ok += 1
	prism.sync_mirrors(true)
	_gate("G-棱镜注入：镜面数=5（content v2 构筑面）", _gl.player.mirror_count() == 5,
		"mirror_count=%d split=%d/%d" % [_gl.player.mirror_count(), split_ok, PRISM_SPLIT])
	_gl.stage_probe_enabled = true
	if not _load_composition():
		return false
	_build_fam_roots()                       # 战斗段 player/hud 全在场——重建全量表
	print("bootⅡ：grove w16 构成 %d（含 %s 射手×%d）压血×%.2f | 构筑=W2 L5 五词条+W5 镜5 | 敌弹注入=spawn 前补 projectile_pool"
		% [_comp.size(), SPITTER_ID, SPITTER_COUNT, ENEMY_HP_SCALE])
	return true


func _load_composition() -> bool:
	var tbl: Resource = load(GROVE_TABLE)
	if tbl == null or not ("entries" in tbl):
		push_error("[probe] 波表加载失败：%s" % GROVE_TABLE)
		_fails += 1
		return false
	var entry: Resource = null
	for e in tbl.get("entries"):
		if int(e.get("index")) == 16:
			entry = e
			break
	if entry == null:
		push_error("[probe] grove 波表无 index==16 条目")
		_fails += 1
		return false
	for c in entry.get("composition"):
		var src: EnemyData = _gl.registry.get_enemy(StringName(c.get("enemy_id")))
		if src == null:
			push_error("[probe] 敌数据缺失：%s" % str(c.get("enemy_id")))
			_fails += 1
			return false
		var data: EnemyData = src.duplicate()
		data.hp_base = data.hp_base * ENEMY_HP_SCALE
		var tags := int(c.get("tags", 0))
		if (tags & GameConst.TAG_ELITE) != 0:
			data.elite_affixes = [ELITE_AFFIX]  # 射击面词缀（8 发环弹/7s——敌弹量级主源）
		for i in range(int(c.get("count", 1))):
			_comp.append({"data": data, "tags": tags})
	var sp_src: EnemyData = _gl.registry.get_enemy(SPITTER_ID)
	if sp_src == null:
		push_error("[probe] 射手数据缺失：%s" % SPITTER_ID)
		_fails += 1
		return false
	var sp_data: EnemyData = sp_src.duplicate()
	sp_data.hp_base = sp_data.hp_base * ENEMY_HP_SCALE
	for i in range(SPITTER_COUNT):
		_comp.append({"data": sp_data, "tags": 0})
	_comp.shuffle()
	return true


func _sandbox_check() -> bool:
	var udir := OS.get_user_data_dir()
	var ok: bool = udir.contains(SANDBOX_MARKER)
	_gate("G-沙箱 user:// 重定向生效（含 %s）" % SANDBOX_MARKER, ok,
		"user_dir=%s%s" % [udir, "" if ok else " ←未重定向！窗口跑必须 APPDATA 指向仓内沙箱，中止防真档污染"])
	return ok


# ── 族根表（菜单段防御式：player 等未建节点跳过；战斗段全量重建）────

func _build_fam_roots() -> void:
	_fam_root_map = {}
	_fam_root_map[_gl.pools[&"enemy"]] = DOM_ENEMY
	_fam_root_map[_gl.pools[&"projectile"]] = 4
	_fam_root_map[_gl.pools[&"homing"]] = 4
	_fam_root_map[_gl.pools[&"xp"]] = 5
	_fam_root_map[_gl.pools[&"particle"]] = 6
	_fam_root_map[_gl.pools[&"popup"]] = 8
	_fam_root_map[_gl.pools[&"laser"]] = 12
	if _gl.elemental_fx != null:
		_fam_root_map[_gl.elemental_fx] = 7
	if _gl.hud != null:
		_fam_root_map[_gl.hud] = 9
	if _gl.boss_bar != null:
		_fam_root_map[_gl.boss_bar] = 9
	if _gl.hurt_indicator != null:
		_fam_root_map[_gl.hurt_indicator] = 9
	var backdrop: Node = _gl.get("_backdrop")
	if backdrop != null:
		_fam_root_map[backdrop] = 10
	if _gl.player != null:
		_fam_root_map[_gl.player] = 11
	for c in _gl.get_children():
		if c is MenuScreen or c is SettingsPanel or c is ShopUi or c is CardSelectUI \
				or c is GameOverScreen or c is PauseOverlay:
			_fam_root_map[c] = 9
	_churn_roots = [
		[_gl.pools[&"enemy"], DOM_ENEMY],
		[_gl.pools[&"projectile"], 4],
		[_gl.pools[&"homing"], 4],
		[_gl.pools[&"xp"], 5],
		[_gl.pools[&"particle"], 6],
		[_gl.pools[&"popup"], 8],
		[_gl.pools[&"laser"], 12],
	]
	if _gl.elemental_fx != null:
		_churn_roots.append([_gl.elemental_fx, 7])


# ── MENU 臂（基线 40s + P1 谱——增量份额分母）───────────────────────

func _arm_menu() -> void:
	print("── MENU 菜单基线（未 start_run：dc/渲ms/桶 + P1 谱）──")
	_knife = ""
	_masked.clear()
	_exempt = 0
	_hidden_items.clear()
	_mask_dirty = true
	var wt0 := Time.get_ticks_msec()
	while Time.get_ticks_msec() - wt0 < int(MENU_WARMUP_S * 1000.0):
		_replay_masks()
		_reaffirm_chromatic()
		await tree.process_frame
	var base := await _measure_window("MENU", "菜单基线（自然态无掩码）")
	var anchor := await _plain_window(ANCHOR_FRAMES)
	var p1_rows: Array = []
	var prev_dc := int(anchor["median"])
	for fam in range(1, F_COUNT + 1):
		_masked[fam] = true
		_mask_dirty = true
		var w := await _mask_window()
		p1_rows.append({"fam": fam, "after_dc": int(w["median"]),
			"marginal_dc": prev_dc - int(w["median"])})
		prev_dc = int(w["median"])
	var resid := await _mask_window()
	_results["MENU"] = {"base": base, "anchor_dc": int(anchor["median"]),
		"residual_dc": int(resid["median"]), "P1": p1_rows,
		"counts": _full_walk_counts()}
	print("MENU 读数：dc p50=%d（p95=%d）| 渲ms=%.2f | fps=%.0f | 桶 敌%d 弹%d 碎%d | Σ边际=%d 残差=%d"
		% [int(base["dc_p50"]), int(base["dc_p95"]), float(base["render_ms_mean"]),
			float(base["fps_mean"]), int(base["bucket_enemy_last"]),
			int(base["bucket_projectile_last"]), int(base["bucket_xp_last"]),
			_sum_marg(p1_rows), int(resid["median"])])


# ── BATTLE 臂（基线 40s + 锚 + P1 + 残差 + P2 + M2）─────────────────

func _arm_battle() -> void:
	print("── BATTLE 战斗基线（深载自然驱动：敌%d 驻场 + P1/P2 谱 + M2 断批归因）──" % HOLD)
	_knife = ""
	_masked.clear()
	_exempt = 0
	_hidden_items.clear()
	_mask_dirty = true
	_clear_field()
	_cursor = 0
	_steady_warm = await _warm_to_steady("BATTLE")
	var base := await _measure_window("BATTLE", "战斗深载基线（饱和稳态自然态无掩码）")
	var anchor := await _plain_window(ANCHOR_FRAMES)
	# P1 累积关断（主读数：边际 dc——R230 同口径固定树序 F1→F13）
	var p1_rows: Array = []
	var prev_dc := int(anchor["median"])
	for fam in range(1, F_COUNT + 1):
		_masked[fam] = true
		_mask_dirty = true
		var w := await _mask_window()
		p1_rows.append({"fam": fam, "after_dc": int(w["median"]),
			"marginal_dc": prev_dc - int(w["median"])})
		prev_dc = int(w["median"])
	var resid := await _mask_window()
	# P2 单独可见（辅读数：每族单独开其余全掩）
	var p2_rows: Array = []
	for fam in range(1, F_COUNT + 1):
		_masked.clear()
		for f2 in range(1, F_COUNT + 1):
			if f2 != fam:
				_masked[f2] = true
		_exempt = fam
		_mask_dirty = true
		var w2 := await _mask_window()
		p2_rows.append({"fam": fam, "indep_dc": int(w2["median"])})
	_exempt = 0
	_masked.clear()
	_hidden_items.clear()
	_mask_dirty = true
	var m2 := await _m2_breakbatch(base)
	_results["BATTLE"] = {"base": base, "anchor_dc": int(anchor["median"]),
		"residual_dc": int(resid["median"]), "P1": p1_rows, "P2": p2_rows,
		"counts": _full_walk_counts(), "m2": m2, "steady_warm": _steady_warm}
	var marg := _marg_by_fam(p1_rows)
	_dump_sec_series(base, "BATTLE")
	print("BATTLE 读数：dc p50=%d（p95=%d）| 渲ms=%.2f | fps=%.0f | 敌=%d 弹=%d 跳=%d 敌弹=%d | 桶 敌%d 弹%d 碎%d"
		% [int(base["dc_p50"]), int(base["dc_p95"]), float(base["render_ms_mean"]),
			float(base["fps_mean"]), int(base["enemies_p50"]),
			int(base["projectiles_p50"]), int(base["popups_p50"]),
			int(base["eproj_p50"]), int(base["bucket_enemy_last"]),
			int(base["bucket_projectile_last"]), int(base["bucket_xp_last"])])
	print("  分族边际（P1）：F1=%d F2=%d F3=%d F4=%d F5=%d F6=%d F7=%d F8=%d F9=%d F10=%d F11=%d F12=%d F13=%d"
		% [marg.get(1, 0), marg.get(2, 0), marg.get(3, 0), marg.get(4, 0),
			marg.get(5, 0), marg.get(6, 0), marg.get(7, 0), marg.get(8, 0),
			marg.get(9, 0), marg.get(10, 0), marg.get(11, 0), marg.get(12, 0),
			marg.get(13, 0)])
	# 门：负载带（定标复现——敌 115-120 常驻硬门；弹带披露）
	_gate("G-负载带：敌 p50∈[%d,%d]（定标 115-120 常驻）" % [LOAD_ENEMY_BAND.x,
		LOAD_ENEMY_BAND.y], int(base["enemies_p50"]) >= LOAD_ENEMY_BAND.x
		and int(base["enemies_p50"]) <= LOAD_ENEMY_BAND.y,
		"敌=%d 弹=%d 跳=%d 敌弹=%d" % [int(base["enemies_p50"]),
			int(base["projectiles_p50"]), int(base["popups_p50"]),
			int(base["eproj_p50"])])
	_gate_disclosed("G-弹带披露：弹 p50∈[%d,%d]（定标 280-350+content v2 敌弹+漂移）"
		% [LOAD_PROJ_BAND.x, LOAD_PROJ_BAND.y],
		int(base["projectiles_p50"]) >= LOAD_PROJ_BAND.x
			and int(base["projectiles_p50"]) <= LOAD_PROJ_BAND.y,
		"弹=%d（带外=构筑旋钮再调，披露不阻塞）" % int(base["projectiles_p50"]))
	_gate("G-敌弹注入生效（content v2）：敌弹 p50>0", int(base["eproj_p50"]) > 0,
		"敌弹=%d" % int(base["eproj_p50"]))
	# FG3 望远镜闭环（R230 同款门）
	var sum_marg := _sum_marg(p1_rows)
	var closure := int(anchor["median"]) - sum_marg - int(resid["median"])
	if absi(closure) <= FG3_TOL:
		_gate("FG3[BATTLE] 望远镜闭环 ≤±%d" % FG3_TOL, true, "closure=%d" % closure)
	elif absi(closure) <= FG3_TOL_DISCLOSED:
		_gate_disclosed("FG3[BATTLE] 望远镜闭环 ≤±%d（churn 放宽档）" % FG3_TOL_DISCLOSED,
			true, "closure=%d（>±%d——深载 churn 中位读数噪声）" % [closure, FG3_TOL])
	else:
		_gate("FG3[BATTLE] 望远镜闭环 ≤±%d" % FG3_TOL_DISCLOSED, false,
			"closure=%d（超放宽档——查掩码重放泄漏）" % closure)
	# 共场链式：不清场（饱和态延续至四刀臂——臂间 _settle drain 由 _arm_knife 承担）


# ── M2：断批归因（桶-dc 相关性 + 敌桶穿插件逐件 dc）────────────────

func _m2_breakbatch(p_base: Dictionary) -> Dictionary:
	# M2a：基线窗逐秒系列上的 桶计数×dc 相关性（涨桶=变体断批嫌疑——真机 vc40
	# 桶遥测战斗期 1+3+12 的桌面侧对拍；桶数=host 子桶数=不同贴图数单调下界，
	# 桶内挂件断批不可见——diag_counts R215 刀D 解读边界照登）
	var sec: Array = p_base.get("sec_series", [])
	var m2a := {"samples": sec.size(),
		"r_buckets_vs_dc": _pearson_jsonable(sec, "buckets_sum", "dc_p50"),
		"r_bucket_enemy_vs_dc": _pearson_jsonable(sec, "bucket_enemy", "dc_p50"),
		"r_enemies_vs_dc": _pearson_jsonable(sec, "enemies", "dc_p50"),
		"note": "桶数=单调下界（桶内挂件断批不可见）；null=系列常量无方差——夹具构成固定→桶稳定，真机涨桶=内容变体入场，桌面不可复现即结论本身"}
	# M2b：敌桶穿插件逐件 dc（R228 口径——单件 RS 隐藏 vs 紧邻无隐藏参照窗差=该件 dc 面；
	#   ★逐件交错参照（A-B-A-B）：深载场 dc 带 ±15-25% 固有振荡，共用远端基线会被
	#   漂移淹没（smoke 实证 均值 −51=漂移伪影）——局域差分杀慢漂移）
	var items := _collect_f3_items()
	var per_item: Array = []
	for i in range(mini(M2_ITEM_SAMPLE, items.size())):
		var it: CanvasItem = items[i]
		var iid := it.get_instance_id()
		var ref := await _plain_window(SETTLE_FRAMES + SAMPLE_FRAMES_B)
		_hidden_items = {iid: true}
		_mask_dirty = true
		var w := await _mask_window()
		per_item.append({"name": String(it.name), "kind": _f3_kind(it),
			"ref_dc": int(ref["median"]), "hide_dc": int(w["median"]),
			"dc_delta": int(ref["median"]) - int(w["median"])})
		_hidden_items.clear()
		_mask_dirty = true
	var end_w := await _plain_window(SETTLE_FRAMES + SAMPLE_FRAMES_B)
	var deltas: Array[int] = []
	for r in per_item:
		deltas.append(int(r["dc_delta"]))
	var mean_d := 0
	for d in deltas:
		mean_d += d
	if not deltas.is_empty():
		mean_d = int(round(float(mean_d) / float(deltas.size())))
	var dmax := 0
	for d in deltas:
		dmax = maxi(dmax, d)
	var breakers := 0
	for d in deltas:
		if d >= 5:
			breakers += 1
	var m2b := {"f3_live": items.size(), "sampled": per_item.size(),
		"per_item": per_item, "per_item_dc_mean": mean_d, "per_item_dc_max": dmax,
		"breakers_ge5dc": breakers,
		"drift_check": int(end_w["median"]),
		"protocol": "逐件交错参照（A-B-A-B 局域差分杀漂移）：无隐藏参照窗 vs 单件 RS 隐藏窗，各 弃3+settle10+采样30 中位（R228 ospec 逐件口径）"}
	print("M2：相关性 桶和×dc r=%s（n=%d）｜穿插件 live=%d 抽查=%d 逐件dc 均值=%d 峰=%d（≥5dc 断批嫌疑件 %d）｜末参照=%d"
		% [str(m2a["r_buckets_vs_dc"]), sec.size(), items.size(), per_item.size(),
			mean_d, dmax, breakers, int(end_w["median"])])
	return {"correlation": m2a, "through_items": m2b}


func _f3_kind(p_n: Node) -> String:
	if p_n is Enemy.DeathPop:
		return "DeathPop"
	if p_n is Enemy.PoisonSplash:
		return "PoisonSplash"
	if p_n is Telegraph.TelegraphCircle or p_n is Telegraph.TelegraphFan \
			or p_n is Telegraph.TelegraphLine:
		return "Telegraph"
	return "Other"


func _collect_f3_items() -> Array:
	# 敌桶域内 F3 穿插件活口（R230 分类器同款判定——DeathPop/PoisonSplash/Telegraph 圈）
	var out: Array = []
	var queue: Array = [_gl.pools[&"enemy"]]
	while not queue.is_empty():
		var n: Node = queue.pop_front()
		if _classify_enemy_domain(n) == 3 and n is CanvasItem \
				and (n as CanvasItem).is_visible_in_tree():
			out.append(n)
		for c in n.get_children():
			queue.append(c)
	return out


# ── 快刀臂（配对 A/B：同场 刀关 40s → 置刀 settle → 刀开 40s）────────

func _arm_knife(p_key: String) -> void:
	var labels := {
		"K_NULL": "空刀对照（R232 falsify 先例——同程零注入，Δ 应≈0：程式伪差/漂移带定量）",
		"K_POP": "跳字满载门 帽→%d（_active_list 最老 N−%d 条 visible=false 逐帧）"
			% [KNIFE_POP_KEEP, KNIFE_POP_KEEP],
		"K_DECOR": "敌满载装饰全隐（Crown/GroundShadow/ArmorPlate/FuseRing/BurnEmber/Sparkle*/Satellite*/BurnFlame* 逐帧 visible=false）",
		"K_FX": "fx 粒子全关（elemental_fx 层根 visible=false 逐帧）",
	}
	print("── %s %s ──" % [p_key, labels[p_key]])
	_knife = ""
	_masked.clear()
	_exempt = 0
	_hidden_items.clear()
	_mask_dirty = true
	await _settle(SETTLE_KNIFE_STEPS, SETTLE_KNIFE_MAX_S)     # 臂间 drain（共场链式——不清场）
	var off := await _measure_window(p_key + "_OFF", "刀关基线（同场配对）")
	_knife = p_key
	await _settle(SETTLE_KNIFE_STEPS, SETTLE_KNIFE_MAX_S)
	var on := await _measure_window(p_key + "_ON", "刀开（%s）" % p_key)
	_knife = ""
	_dump_sec_series(off, p_key + "_OFF")
	_dump_sec_series(on, p_key + "_ON")
	var dc_delta := int(off["dc_p50"]) - int(on["dc_p50"])
	var ms_delta := float(off["render_ms_mean"]) - float(on["render_ms_mean"])
	var dc_pct := 0.0 if int(off["dc_p50"]) <= 0 \
			else float(dc_delta) / float(int(off["dc_p50"])) * 100.0
	_results[p_key] = {"off": off, "on": on, "dc_delta": dc_delta,
		"dc_drop_pct": snappedf(dc_pct, 0.1),
		"render_ms_delta": snappedf(ms_delta, 0.03),
		"label": labels[p_key]}
	print("读数：dc %d→%d（Δ=%+d / %.1f%%）| 渲ms %.2f→%.2f（Δ=%+.2f）| fps %.0f→%.0f | 步/帧 %.2f→%.2f | 刀态校验 %s"
		% [int(off["dc_p50"]), int(on["dc_p50"]), dc_delta, dc_pct,
			float(off["render_ms_mean"]), float(on["render_ms_mean"]), ms_delta,
			float(off["fps_mean"]), float(on["fps_mean"]),
			float(off["steps_per_frame"]), float(on["steps_per_frame"]),
			_knife_verify_line(p_key, on)])
	_gate("G-%s 配对窗成立（两窗 ≥%.0fs×0.9 且 ≥%d 步）" % [p_key, MEASURE_MIN_WALL_S_B,
			MEASURE_MIN_STEPS_B],
		float(off["wall_s"]) >= MEASURE_MIN_WALL_S_B * 0.9
			and float(on["wall_s"]) >= MEASURE_MIN_WALL_S_B * 0.9,
		"off=%.1fs on=%.1fs" % [float(off["wall_s"]), float(on["wall_s"])])
	# 刀态生效校验（快刀面各自硬门；空刀=程式伪差带门——带=max(10dc, 8%)：深载场
	# dc 带 ±15-25% 固有振荡，40s 窗中位平均后残差带按 8% 定，快刀 |Δ| 须超带才可信）
	if p_key == "K_NULL":
		var band := maxi(10, int(float(int(off["dc_p50"])) * 0.08))
		_gate("G-K_NULL 空刀伪差带：|dcΔ| ≤max(10, 8%%)=%d（超标=配对程式伪差大，快刀读数降级披露）"
				% band, absi(dc_delta) <= band,
			"dcΔ=%+d（带=%d）渲msΔ=%+.2f（R232 falsify 同构）" % [dc_delta, band, ms_delta])
	elif p_key == "K_POP":
		_gate("G-K_POP 生效：跳字可见 p50 ≤%d" % (KNIFE_POP_KEEP + 1),
			int(on["popups_visible_p50"]) <= KNIFE_POP_KEEP + 1,
			"可见=%d（活口=%d——桌面帽 40 口径，真机 24→8 外推见 derive）"
				% [int(on["popups_visible_p50"]), int(on["popups_p50"])])
	elif p_key == "K_DECOR":
		_gate("G-K_DECOR 生效：装饰可见 p50=0（churn 首帧闪现容差 ≤1）",
			int(on["decor_visible_p50"]) <= 1,
			"可见=%d（产品满载门已隐大部分——本刀=残余面，解读见头注）"
				% int(on["decor_visible_p50"]))
	else:
		_gate("G-K_FX 生效：fx 层隐藏采样占比 ≥99%%", float(on["fx_hidden_frac"]) >= 0.99,
			"隐藏占比=%.2f" % float(on["fx_hidden_frac"]))


func _knife_verify_line(p_key: String, p_on: Dictionary) -> String:
	match p_key:
		"K_POP":
			return "跳字可见 p50=%d/活口%d" % [int(p_on["popups_visible_p50"]), int(p_on["popups_p50"])]
		"K_DECOR":
			return "装饰可见 p50=%d" % int(p_on["decor_visible_p50"])
		"K_FX":
			return "fx 隐藏占比=%.2f" % float(p_on["fx_hidden_frac"])
	return "-"


func _dump_sec_series(p_w: Dictionary, p_tag: String) -> void:
	# 逐秒系列首/中/末行（漂移归因诊断——dc 增长定位到 敌/弹/跳/桶/染色 哪条轴）
	var sec: Array = p_w.get("sec_series", [])
	if sec.is_empty():
		return
	for idx in [0, sec.size() / 2, sec.size() - 1]:
		var r: Dictionary = sec[idx]
		print("  [%s 秒系列#%d] t=%.0fs dc=%d 敌=%d 弹=%d 跳=%d 碎=%d 态敌=%d 队=%d 桶=%d/%d/%d 染=%d 组=%d"
			% [p_tag, idx, float(r["sec"]), int(r["dc_p50"]), int(r["enemies"]),
				int(r["projectiles"]), int(r["popups"]), int(r["shards"]),
				int(r["status_enemies"]), int(r["spawn_queue"]),
				int(r["bucket_enemy"]), int(r["bucket_projectile"]),
				int(r["bucket_xp"]), int(r["tinted_enemies"]),
				int(r["tint_groups"])])


func _apply_knife() -> void:
	# 逐帧重放（churn 新件+产品复显封堵）；replay 在 await 前=计量窗外（渲ms 不含，头注）
	match _knife:
		"K_POP":
			var lst: Array = _gl.popup_manager.get("_active_list")
			var over := lst.size() - KNIFE_POP_KEEP
			for i in range(maxi(over, 0)):
				var p: Node = lst[i]
				if p != null and is_instance_valid(p):
					(p as CanvasItem).visible = false
		"K_DECOR":
			for e in _gl.spawner.active:
				for c in (e as Node).get_children():
					var nm := String(c.name)
					if DECOR_EXACT.has(nm) or nm.begins_with("Sparkle") \
							or nm.begins_with("Satellite") or nm.begins_with("BurnFlame"):
						if c is CanvasItem:
							(c as CanvasItem).visible = false
		"K_FX":
			if _gl.elemental_fx != null:
				_gl.elemental_fx.visible = false


# ── 采样窗（自然驱动主循环：注入→await→读上一完成帧）───────────────

func _measure_window(p_key: String, p_label: String) -> Dictionary:
	# ≥40s 且 ≥2400 步（双下限；帽 75s/4500 步）；逐帧 dc+渲ms；逐秒 diag 快照
	var dc_arr: Array[int] = []
	var ms_arr: Array[float] = []
	var sec_series: Array = []
	var sec_dc: Array[int] = []
	var fps_arr: Array[float] = []
	var en_arr: Array[int] = []
	var proj_arr: Array[int] = []
	var pop_arr: Array[int] = []
	var eproj_arr: Array[int] = []
	var popvis_arr: Array[int] = []
	var decorvis_arr: Array[int] = []
	var fxhidden := 0
	var fxchecks := 0
	var pf0 := Engine.get_physics_frames()
	var wt0 := Time.get_ticks_msec()
	var sec_last_ms := wt0
	var sec0 := wt0
	var snap := _sec_snapshot()
	en_arr.append(int(snap["enemies"]))
	proj_arr.append(int(snap["projectiles"]))
	pop_arr.append(int(snap["popups"]))
	eproj_arr.append(int(snap["eproj"]))
	while true:
		if _battle_field:
			_kite()
			_topup()
		_apply_knife()
		# 刀态计数在渲染前（_apply_knife 刚执行、产品物理未复显）——量「渲染帧实见」
		match _knife:
			"K_POP":
				popvis_arr.append(_count_visible_popups())
			"K_DECOR":
				decorvis_arr.append(_count_visible_decor())
			"K_FX":
				fxchecks += 1
				if _gl.elemental_fx == null or not _gl.elemental_fx.visible:
					fxhidden += 1
		_replay_masks()
		_reaffirm_chromatic()
		var t0 := Time.get_ticks_usec()
		await tree.process_frame
		var dt_ms := (Time.get_ticks_usec() - t0) / 1000.0
		dc_arr.append(_read_dc())
		ms_arr.append(dt_ms)
		sec_dc.append(_read_dc())
		var now_ms := Time.get_ticks_msec()
		if now_ms - sec_last_ms >= 1000:                    # 墙钟 ~1s 节流（fps 无关）
			sec_last_ms = now_ms
			fps_arr.append(float(Engine.get_frames_per_second()))
			var s2 := _sec_snapshot()
			en_arr.append(int(s2["enemies"]))
			proj_arr.append(int(s2["projectiles"]))
			pop_arr.append(int(s2["popups"]))
			eproj_arr.append(int(s2["eproj"]))
			sec_series.append({
				"sec": (now_ms - sec0) / 1000.0,
				"dc_p50": _median_i_arr(sec_dc),
				"buckets_sum": int(s2["bucket_enemy"]) + int(s2["bucket_projectile"]) + int(s2["bucket_xp"]),
				"bucket_enemy": int(s2["bucket_enemy"]),
				"bucket_projectile": int(s2["bucket_projectile"]),
				"bucket_xp": int(s2["bucket_xp"]),
				"enemies": int(s2["enemies"]), "projectiles": int(s2["projectiles"]),
				"popups": int(s2["popups"]),
				"shards": int(s2["shards"]),
				"status_enemies": int(s2["status_enemies"]),
				"spawn_queue": int(s2["spawn_queue"]),
				"tint_groups": int(s2["tint_groups"]),
				"tinted_enemies": int(s2["tinted_enemies"]),
			})
			sec_dc.clear()
		var wall_s := (Time.get_ticks_msec() - wt0) / 1000.0
		var steps_done := Engine.get_physics_frames() - pf0
		if (wall_s >= MEASURE_MIN_WALL_S_B and steps_done >= MEASURE_MIN_STEPS_B) \
				or wall_s >= MEASURE_MAX_WALL_S or steps_done >= MEASURE_MAX_STEPS:
			break
	var s_end := _sec_snapshot()
	en_arr.append(int(s_end["enemies"]))
	proj_arr.append(int(s_end["projectiles"]))
	pop_arr.append(int(s_end["popups"]))
	eproj_arr.append(int(s_end["eproj"]))
	if fps_arr.is_empty():
		fps_arr.append(float(Engine.get_frames_per_second()))
	var sorted_dc: Array[int] = dc_arr.duplicate()
	sorted_dc.sort()
	var sorted_ms: Array[float] = ms_arr.duplicate()
	sorted_ms.sort()
	return {
		"label": p_label, "wall_s": (Time.get_ticks_msec() - wt0) / 1000.0,
		"steps": Engine.get_physics_frames() - pf0, "frames": dc_arr.size(),
		"steps_per_frame": float(Engine.get_physics_frames() - pf0) / float(maxi(dc_arr.size(), 1)),
		"dc_p50": _median_i_arr(dc_arr),
		"dc_p95": (sorted_dc[int(float(sorted_dc.size()) * 0.95)] if not sorted_dc.is_empty() else 0),
		"render_ms_mean": snappedf(_mean_f(ms_arr), 0.001),
		"render_ms_p95": snappedf(sorted_ms[int(float(sorted_ms.size()) * 0.95)] if not sorted_ms.is_empty() else 0.0, 0.001),
		"fps_mean": snappedf(_mean_f(fps_arr), 0.1),
		"enemies_p50": _median_i_arr(en_arr), "projectiles_p50": _median_i_arr(proj_arr),
		"popups_p50": _median_i_arr(pop_arr), "eproj_p50": _median_i_arr(eproj_arr),
		"bucket_enemy_last": int(s_end["bucket_enemy"]),
		"bucket_projectile_last": int(s_end["bucket_projectile"]),
		"bucket_xp_last": int(s_end["bucket_xp"]),
		"tint_groups_last": int(s_end["tint_groups"]),
		"sec_series": sec_series,
		"popups_visible_p50": _median_i_arr(popvis_arr),
		"decor_visible_p50": _median_i_arr(decorvis_arr),
		"fx_hidden_frac": float(fxhidden) / float(maxi(fxchecks, 1)),
	}


func _sec_snapshot() -> Dictionary:
	var d := _gl.diag_counts()
	var eproj := 0
	for pr in (_gl.pools[&"projectile"] as ProjectilePool).active_projectiles():
		if pr is ProjectileBase and (pr as ProjectileBase).team == 1:
			eproj += 1
	return {"enemies": int(d.get(&"enemies", 0)),
		"projectiles": int(d.get(&"projectiles", 0)),
		"popups": int(d.get(&"popups", 0)),
		"eproj": eproj,
		"shards": int(d.get(&"shards", 0)),
		"status_enemies": int(d.get(&"status_enemies", 0)),
		"bucket_enemy": int(d.get(&"bucket_enemy", 0)),
		"bucket_projectile": int(d.get(&"bucket_projectile", 0)),
		"bucket_xp": int(d.get(&"bucket_xp", 0)),
		"tint_groups": int(d.get(&"tint_groups", 0)),
		"tinted_enemies": int(d.get(&"tinted_enemies", 0)),
		"spawn_queue": _gl.spawner.spawn_queue.size()}


func _warm_to_steady(p_tag: String) -> Dictionary:
	# 饱和暖机（物理步基=模拟时间）：dc 中位 600 步判窗，相邻两窗变化 ≤STEADY_TOL_PCT
	# 判稳（STEADY_MIN_STEPS 起判，STEADY_MAX_STEPS 帽）。返回暖机曲线（尾 12 窗+桶计数）。
	var curve: Array = []
	var win_dc: Array[int] = []
	var st0 := Engine.get_physics_frames()
	var wt0 := Time.get_ticks_msec()
	var last_med := -1
	var prev_med := -1
	while true:
		_kite()
		_topup()
		_apply_knife()
		_replay_masks()
		_reaffirm_chromatic()
		await tree.process_frame
		win_dc.append(_read_dc())
		if Engine.get_physics_frames() - st0 >= (curve.size() + 1) * STEADY_WIN_STEPS_B:
			var med := _median_i_arr(win_dc)
			var dsn := _sec_snapshot()
			curve.append({"t": (Time.get_ticks_msec() - wt0) / 1000.0,
				"steps": Engine.get_physics_frames() - st0, "dc_p50": med,
				"bucket_e": int(dsn["bucket_enemy"]), "bucket_p": int(dsn["bucket_projectile"]),
				"bucket_x": int(dsn["bucket_xp"]), "tint_groups": int(dsn["tint_groups"]),
				"enemies": int(dsn["enemies"]), "projectiles": int(dsn["projectiles"])})
			prev_med = last_med
			last_med = med
			win_dc.clear()
			var steps_done := Engine.get_physics_frames() - st0
			if steps_done >= STEADY_MIN_STEPS_B and prev_med > 0 and last_med > 0 \
					and absf(float(last_med - prev_med)) / float(maxi(prev_med, 1)) * 100.0 <= STEADY_TOL_PCT:
				print("  [%s 饱和暖机] %d 步（%.0fs 墙钟）dc %d→%d（≤%.0f%% 判稳）" % [p_tag,
					steps_done, (Time.get_ticks_msec() - wt0) / 1000.0,
					prev_med, last_med, STEADY_TOL_PCT])
				break
			if steps_done >= STEADY_MAX_STEPS_B:
				print("  [%s 饱和暖机] %d 步达帽退出（dc %d→%d 未判稳——如实披露）" % [
					p_tag, steps_done, prev_med, last_med])
				break
	return {"wall_s": (Time.get_ticks_msec() - wt0) / 1000.0,
		"steps": Engine.get_physics_frames() - st0,
		"curve_tail": curve.slice(maxi(curve.size() - 12, 0))}


func _settle(p_steps: int, p_max_s: float) -> void:
	var pf0 := Engine.get_physics_frames()
	var wt0 := Time.get_ticks_msec()
	while Engine.get_physics_frames() - pf0 < p_steps \
			and Time.get_ticks_msec() - wt0 < int(p_max_s * 1000.0):
		_kite()
		_topup()
		_apply_knife()
		_replay_masks()
		_reaffirm_chromatic()
		await tree.process_frame


func _plain_window(p_n: int) -> Dictionary:
	# 自然态无掩码读数窗（锚/漂移复核——逐帧读 dc 取中位；_replay_masks 自愈残留）
	var buf: Array[int] = []
	for i in range(p_n):
		if _battle_field:
			_kite()
			_topup()
		_apply_knife()
		_replay_masks()
		_reaffirm_chromatic()
		await tree.process_frame
		buf.append(_read_dc())
	return {"median": _median_i_arr(buf), "max": (buf.max() if not buf.is_empty() else 0)}


func _mask_window() -> Dictionary:
	# R230 同款读数窗：弃 3 + settle 10 + 采样 30 取中位（掩码逐帧重放在窗内发生）
	var buf: Array[int] = []
	for i in range(DISCARD_FRAMES + SETTLE_FRAMES + SAMPLE_FRAMES_B):
		if _battle_field:
			_kite()
			_topup()
		_replay_masks()
		_reaffirm_chromatic()
		await tree.process_frame
		if i >= DISCARD_FRAMES + SETTLE_FRAMES:
			buf.append(_read_dc())
	return {"median": _median_i_arr(buf), "max": (buf.max() if not buf.is_empty() else 0)}


func _replay_masks() -> void:
	# RS 态自愈入口（头注）：脏→全树走查；掩码/单件隐藏在场→churn 域重放；否则零操作
	if _mask_dirty:
		_walk_apply(tree.root, 0, {})
		_mask_dirty = false
	elif not _masked.is_empty() or _exempt != 0 or not _hidden_items.is_empty():
		for r in _churn_roots:
			_walk_apply(r[0], int(r[1]), {})
		for c in _gl.get_children():
			if not _fam_root_map.has(c):
				_walk_apply(c, 0, {})


# ── 风筝/补位（physattr 同款——相位推物理帧号）──────────────────────

func _kite() -> void:
	if _gl.player == null:
		return
	var ang := float(_gl.frame_stamp) * 0.35 / float(PROBE_PHYS_HZ)
	_gl.player.global_position = Vector2(360.0 + cos(ang) * 140.0,
		660.0 + sin(ang) * 200.0)


func _spawn_one() -> void:
	var c: Dictionary = _comp[_cursor % _comp.size()]
	_cursor += 1
	var e := (_gl.pools[&"enemy"] as EnemyPool).acquire() as Enemy
	if e == null:
		return
	e.bucket_host = (_gl.pools[&"enemy"] as EnemyPool).bucket_host
	e.projectile_pool = _gl.pools[&"projectile"]   # R224 QA D4 出生管线缺环补齐（R230 同款）
	e.spawn(c["data"], 16, int(c["tags"]))
	e.global_position = Vector2(randf() * 680.0 + 20.0, randf() * 1180.0 + 40.0)
	_gl.spawner.active.append(e)


func _topup() -> void:
	var alive: int = _gl.spawner.active.size()
	var want := mini(TOPUP_PER_FRAME, HOLD - alive)
	for i in range(want):
		_spawn_one()


func _read_dc() -> int:
	return RenderingServer.get_rendering_info(
		RenderingServer.RENDERING_INFO_TOTAL_DRAW_CALLS_IN_FRAME)


func _reaffirm_chromatic() -> void:
	if _chrom_node != null and is_instance_valid(_chrom_node) \
			and _chrom_node.get_canvas_item().is_valid():
		RenderingServer.canvas_item_set_visible(_chrom_node.get_canvas_item(), false)


func _count_visible_popups() -> int:
	var lst: Array = _gl.popup_manager.get("_active_list")
	var n := 0
	for p in lst:
		if p != null and is_instance_valid(p) and (p as CanvasItem).visible:
			n += 1
	return n


func _count_visible_decor() -> int:
	var n := 0
	for e in _gl.spawner.active:
		for c in (e as Node).get_children():
			var nm := String(c.name)
			if c is CanvasItem and (c as CanvasItem).visible \
					and (DECOR_EXACT.has(nm) or nm.begins_with("Sparkle")
						or nm.begins_with("Satellite") or nm.begins_with("BurnFlame")):
				n += 1
	return n


# ── RS 层族掩码（R230 机器原样 + 单件隐藏集扩展）────────────────────

func _walk_apply(p_root: Node, p_root_fam: int, p_count: Dictionary) -> void:
	var queue: Array = [[p_root, p_root_fam]]
	while not queue.is_empty():
		var head: Array = queue.pop_front()
		var n: Node = head[0]
		var fam := int(head[1])
		if _fam_root_map.has(n):
			fam = int(_fam_root_map[n])
		if fam == 4 and n is ProjectileBase \
				and (n as ProjectileBase).team == 1:
			fam = ENEMY_PROJ_FAM
		var eff_fam := fam
		var child_inh := fam
		if fam == DOM_ENEMY:
			eff_fam = _classify_enemy_domain(n)
			if eff_fam == 2 or eff_fam == 3:
				child_inh = eff_fam
			else:
				child_inh = DOM_ENEMY
		if n is CanvasItem and n != _chrom_node:
			var cfam := eff_fam
			if cfam == 0 or cfam == DOM_ENEMY:
				cfam = 12                      # 未归类 CanvasItem → 兜底族
			var ci := n as CanvasItem
			var target: bool = ci.is_visible_in_tree() \
				and (not _masked.has(cfam) or cfam == _exempt) \
				and not _hidden_items.has(n.get_instance_id())
			var rid := ci.get_canvas_item()
			if rid.is_valid():
				RenderingServer.canvas_item_set_visible(rid, target)
			if target:
				p_count[cfam] = int(p_count.get(cfam, 0)) + 1
		for c in n.get_children():
			queue.append([c, child_inh])


func _classify_enemy_domain(p_n: Node) -> int:
	if p_n.get_parent() is Enemy:
		var nm := String(p_n.name)
		if nm.begins_with("Sparkle") or nm.begins_with("Satellite") \
				or nm == "Crown" or nm == "GroundShadow" \
				or nm == "ArmorPlate" or nm == "FuseRing":
			return 2
	if p_n is Enemy:
		return 1
	if p_n is Enemy.DeathPop or p_n is Enemy.PoisonSplash:
		return 3
	if p_n is Telegraph.TelegraphCircle or p_n is Telegraph.TelegraphFan \
			or p_n is Telegraph.TelegraphLine:
		return 3
	return 1


func _full_walk_counts() -> Dictionary:
	var cnt := {}
	_walk_apply(tree.root, 0, cnt)
	return cnt


# ── 判读派生（增量份额 / 快刀降幅 / 真机外推——报告引用本节算出）────

func _derive() -> void:
	var menu: Dictionary = _results.get("MENU", {}).get("base", {})
	var battle: Dictionary = _results.get("BATTLE", {}).get("base", {})
	if menu.is_empty() or battle.is_empty():
		return
	var inc := int(battle["dc_p50"]) - int(menu["dc_p50"])
	var marg := _marg_by_fam(_results["BATTLE"]["P1"])
	var rows: Array = []
	for fam in range(1, F_COUNT + 1):
		var mv := int(marg.get(fam, 0))
		var share := 0.0 if inc <= 0 else float(mv) / float(inc) * 100.0
		rows.append({"fam": fam, "fam_name": F_NAMES[fam - 1], "marginal_dc": mv,
			"share_of_increment_pct": snappedf(share, 0.1)})
	rows.sort_custom(func(a, b): return int(a["marginal_dc"]) > int(b["marginal_dc"]))
	var d := {"menu_dc": int(menu["dc_p50"]), "battle_dc": int(battle["dc_p50"]),
		"increment_dc": inc, "increment_table": rows,
		"menu_render_ms": float(menu["render_ms_mean"]),
		"battle_render_ms": float(battle["render_ms_mean"]),
		"render_ms_increment": snappedf(float(battle["render_ms_mean"])
			- float(menu["render_ms_mean"]), 0.001)}
	# 快刀派生：K_POP 真机外推（每条 dc 线性折算 24→8=16 条 vs 夹具 N−8 条）
	if _results.has("K_POP"):
		var kp: Dictionary = _results["K_POP"]
		var hidden_n := maxi(int(kp["off"]["popups_p50"]) - KNIFE_POP_KEEP, 0)
		var per_pop := 0.0 if hidden_n <= 0 \
				else float(kp["dc_delta"]) / float(hidden_n)
		d["k_pop_per_popup_dc"] = snappedf(per_pop, 0.01)
		d["k_pop_device_24to8_est_dc"] = snappedf(per_pop * 16.0, 0.1)
	# 空刀对照带（R232 falsify 同构——快刀 Δ 的可信度界：|刀Δ| > 空刀带 才可信）
	var null_band := 0
	if _results.has("K_NULL"):
		var kn: Dictionary = _results["K_NULL"]
		d["k_null_dc_delta"] = int(kn["dc_delta"])
		d["k_null_render_ms_delta"] = float(kn["render_ms_delta"])
		null_band = maxi(10, int(float(int(kn["off"]["dc_p50"])) * 0.08))
		d["k_null_band_dc"] = null_band
		for k in ["K_POP", "K_DECOR", "K_FX"]:
			if _results.has(k):
				_results[k]["credible_vs_null_band"] = absi(int(_results[k]["dc_delta"])) > null_band
	# 桶菜单→战斗增量（真机「1+3+12」桌面对拍键）
	d["bucket_delta"] = {
		"enemy": int(battle["bucket_enemy_last"]) - int(menu["bucket_enemy_last"]),
		"projectile": int(battle["bucket_projectile_last"]) - int(menu["bucket_projectile_last"]),
		"xp": int(battle["bucket_xp_last"]) - int(menu["bucket_xp_last"]),
		"menu": [int(menu["bucket_enemy_last"]), int(menu["bucket_projectile_last"]),
			int(menu["bucket_xp_last"])],
		"battle": [int(battle["bucket_enemy_last"]), int(battle["bucket_projectile_last"]),
			int(battle["bucket_xp_last"])],
	}
	_results["derive"] = d
	var top: Array[String] = []
	for i in range(mini(6, rows.size())):
		var r: Dictionary = rows[i]
		top.append("%s=%ddc(%.0f%%)" % [r["fam_name"], int(r["marginal_dc"]),
			float(r["share_of_increment_pct"])])
	print("── 派生：菜单 dc=%d → 战斗 dc=%d（增量 %+d，渲ms %.2f→%.2f）｜增量份额前列：%s"
		% [d["menu_dc"], d["battle_dc"], inc, d["menu_render_ms"],
			d["battle_render_ms"], " ".join(top)])
	var kline: Array[String] = []
	for k in ["K_NULL", "K_POP", "K_DECOR", "K_FX"]:
		if not _results.has(k):
			continue
		var kk: Dictionary = _results[k]
		kline.append("%s dcΔ=%+d(%.1f%%) 渲msΔ=%+.2f" % [k, int(kk["dc_delta"]),
			float(kk["dc_drop_pct"]), float(kk["render_ms_delta"])])
	print("── 快刀： %s" % " | ".join(kline))
	if d.has("k_pop_device_24to8_est_dc"):
		print("── K_POP 真机外推：每条=%.2fdc → 24→8（16 条）≈%.0fdc" % [
			float(d["k_pop_per_popup_dc"]), float(d["k_pop_device_24to8_est_dc"])])


func _marg_by_fam(p_rows: Array) -> Dictionary:
	var out := {}
	for r in p_rows:
		out[int(r["fam"])] = int(r["marginal_dc"])
	return out


func _sum_marg(p_rows: Array) -> int:
	var s := 0
	for r in p_rows:
		s += int(r["marginal_dc"])
	return s


# ── JSON 留档（性能结论唯一依据）─────────────────────────────────────

func _store_json() -> void:
	var rmethod := str(ProjectSettings.get_setting_with_override(
		&"rendering/renderer/rendering_method"))
	var args := OS.get_cmdline_args()
	for i in range(args.size() - 1):
		if String(args[i]) == "--rendering-method":
			rmethod = String(args[i + 1])
	var root: Dictionary = {
		"meta": {
			"date": "2026-10-06",
			"package": "desktop-window-probe（归因对象=真机 vc40 深载渲染轴：渲ms 13-17 vs 菜单 8.4，dc 600-1010）",
			"rendering_project_setting": rmethod,
			"adapter_api": RenderingServer.get_video_adapter_api_version(),
			"physics_hz_project": _phys_hz_project, "physics_hz_probe": PROBE_PHYS_HZ,
			"physics_catchup_cap": "探针侧 Engine.max_physics_steps_per_frame %d→%d（teardown 还原）——smoke 实证默认 8 下深载步成本 ~10-15ms 的 8 步追赶自持螺旋（~130ms/帧 7-9fps）把渲ms 变物理轴读数；帽 2=螺旋结构性不可达，fps<30 时模拟优雅降速=真机模30/模8 设计内降级同族" % [_phys_steps_project, PROBE_MAX_PHYS_STEPS],
			"vsync": "探针侧 DISABLED（原 %d，teardown 还原）——渲ms 读数前提：vsync 开时帧时钳 ~16.7ms 刀效差全被吞；真机无此钳" % _vsync_prev,
			"user_dir": OS.get_user_data_dir(),
			"hold": HOLD, "hp_scale": ENEMY_HP_SCALE,
			"build": "W2_gatling L5 + PIERCE×3/MULTI×2/BOUNCE×3/KILL_BLAST×2/FRACTAL×2 + W5_prism L5 镜5（content v2：E7_spitter×%d+精英 affix_ring+弹池注入）" % SPITTER_COUNT,
			"governor": "frozen, mode=frame_priority, tier_override=2, settle=-3, burst_thin=-3, pool_valve=-3, deathpop_cap=-3, fullload=1, bitmap=1, runstart_bake=1",
			"drive": "物理引擎自然驱动 60Hz（勿手动步进——probe_r237_physattr run3-5 定标：敌 115-120 常驻/弹 280-350；120Hz 崩帧与敌血 0.3 弹股级联两坑不复踩）",
			"render_ms_formula": "当窗渲染帧耗时均值 ms（debug_stats R235 搭车③ 同式：delta 累计÷帧数；探针以 await process_frame 墙钟间隔计量，刀臂 replay 走查在计量窗起点前——刀渲ms 收益低估方向，披露）",
			"measure": {"min_wall_s": MEASURE_MIN_WALL_S, "min_steps": MEASURE_MIN_STEPS,
				"steady_warm": "饱和暖机（物理步基=模拟时间）：dc 中位 %d 步判窗相邻两窗 ≤%d%% 判稳（min %d 步 帽 %d 步）——smoke 实证 dc 随模拟时间爬升（变体桶累积+受击闪白断批带展宽）后才平台，真机深载 dc 600-1010 对应饱和态" % [STEADY_WIN_STEPS, int(STEADY_TOL_PCT), STEADY_MIN_STEPS, STEADY_MAX_STEPS],
				"window": "弃3+settle10+采样30 中位（R230 同款）",
				"knives": "四臂链式共场（饱和态一次建立不清场）：空刀对照 K_NULL（R232 falsify 先例——程式伪差带）+ 三刀各自独立非叠加 配对 A/B（刀关40s→置刀settle→刀开40s）"},
			"note": "桌面绝对值≠真机——只做归因排序与相对降幅，不做收益外推；桶数=单调下界（桶内挂件断批不可见）",
			"plateau_mode": _plateau,
			"plateau_note": "run1 实证：dc 随模拟时间爬升（变体桶累积+受击闪白断批），3600 步判稳过早、~25k 步入 ~1000-1100 平台（=真机深载带 600-1010 上沿同量级）——plateau 档=深老化 min %d 步后测量" % STEADY_MIN_STEPS_B,
			"seed": 20261006,
		},
		"menu": _results.get("MENU", {}),
		"battle": _results.get("BATTLE", {}),
		"knives": {"K_NULL": _results.get("K_NULL", {}), "K_POP": _results.get("K_POP", {}),
			"K_DECOR": _results.get("K_DECOR", {}), "K_FX": _results.get("K_FX", {})},
		"derive": _results.get("derive", {}),
		"gates": _gate_results.duplicate(true),
	}
	var f := FileAccess.open(OUT_JSON, FileAccess.WRITE)
	if f == null:
		_gate("G-JSON 落盘", false, "打开失败：%s" % OUT_JSON)
		return
	f.store_string(JSON.stringify(root, "\t"))
	f.close()
	_gate("G-JSON 落盘", true, OUT_JSON)


# ── 清场/收尾 ────────────────────────────────────────────────────────

func _clear_field() -> void:
	for e in _gl.spawner.active.duplicate():
		_gl.elemental.unregister_host(e)
		(_gl.pools[&"enemy"] as EnemyPool).release(e)
	_gl.spawner.active.clear()
	_gl.spawner.spawn_queue.clear()
	for p in (_gl.pools[&"projectile"] as ProjectilePool).active_projectiles().duplicate():
		(_gl.pools[&"projectile"] as ObjectPool).release(p)
	for s in (_gl.active_shards as Array).duplicate():
		(_gl.pools[&"xp"] as XPPool).release(s)
	_gl.active_shards.clear()


func _teardown_static() -> void:
	# 沙箱自检失败路径（boot 未跑）：仅还原本进程注入的引擎级设置
	if _phys_hz_project != Engine.physics_ticks_per_second:
		Engine.physics_ticks_per_second = _phys_hz_project
	Engine.max_physics_steps_per_frame = _phys_steps_project
	if _vsync_prev >= 0:
		DisplayServer.window_set_vsync_mode(_vsync_prev)


func _teardown() -> void:
	DamagePipeline.settle_budget_override = -1
	DamagePopup.bitmap_override = -1
	PopupGlyphAtlas.runstart_bake_override = -1
	Enemy.fullload_override = -1
	PerfGovernor.mode_override = -1
	PerfGovernor.tier_override = -1
	PerfGovernor.set_process(true)
	GameFeelDirector.burst_thin_override = -1
	GameLoop.pool_valve_override = -1
	Enemy.deathpop_cap_override = -1
	Engine.physics_ticks_per_second = _phys_hz_project
	Engine.max_physics_steps_per_frame = _phys_steps_project
	if _vsync_prev >= 0:
		DisplayServer.window_set_vsync_mode(_vsync_prev)
	if _gl != null:
		_gl.queue_free()
		await tree.process_frame
		await tree.process_frame
	# Meta._settings 内存注入不还原（进程即弃——零落盘零残留，R230 口径）


# ── 门/统计工具 ─────────────────────────────────────────────────────

func _gate(p_label: String, p_ok: bool, p_detail: String) -> void:
	if p_ok:
		print("  PASS | %s（%s）" % [p_label, p_detail])
	else:
		print("  FAIL | %s（%s）" % [p_label, p_detail])
		_fails += 1
	_gate_results[p_label] = {"ok": p_ok, "detail": p_detail}


func _gate_disclosed(p_label: String, p_ok: bool, p_detail: String) -> void:
	if p_ok:
		print("  PASS | %s（%s）" % [p_label, p_detail])
	else:
		print("  FAIL* | %s（%s）——披露类失配：不阻塞（口径见用例体头注）" % [p_label, p_detail])
	_gate_results[p_label] = {"ok": p_ok, "detail": p_detail, "disclosed": true}


func _median_i_arr(p_arr: Array[int]) -> int:
	if p_arr.is_empty():
		return 0
	var s := p_arr.duplicate()
	s.sort()
	return int(s[s.size() / 2])


func _mean_f(p_arr: Array[float]) -> float:
	if p_arr.is_empty():
		return 0.0
	var s := 0.0
	for v in p_arr:
		s += float(v)
	return s / float(p_arr.size())


func _pearson_jsonable(p_rows: Array, p_key_a: String, p_key_b: String) -> Variant:
	# 秒系列相关系数；任一系列零方差 → null（JSON 无 NaN——判读侧作「常量无方差」）
	var a: Array[float] = []
	var b: Array[float] = []
	for r in p_rows:
		a.append(float(r.get(p_key_a, 0)))
		b.append(float(r.get(p_key_b, 0)))
	var n := a.size()
	if n < 3:
		return null
	var ma := _mean_f(a)
	var mb := _mean_f(b)
	var cov := 0.0
	var va := 0.0
	var vb := 0.0
	for i in range(n):
		cov += (a[i] - ma) * (b[i] - mb)
		va += (a[i] - ma) * (a[i] - ma)
		vb += (b[i] - mb) * (b[i] - mb)
	if va <= 0.0 or vb <= 0.0:
		return null
	return snappedf(cov / sqrt(va * vb), 0.001)
