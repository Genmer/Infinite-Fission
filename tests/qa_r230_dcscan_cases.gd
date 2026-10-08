# tests/qa_r230_dcscan_cases.gd（R230 dc 分族扫描用例体——入口运行时加载）
# 复现口径（如实登记，判读须与本节对照）：
# · 构成：probe_r224_deepload_cases 同构（world_grove 波表 index==16 平铺池循环取样补位
#   ≤8/帧、敌血 ×0.3、风筝轨迹、hp/xp_need 1e12、W2_gatling L5 + 五词条
#   AFF_PIERCE×3/AFF_MULTI×2/MEC_BOUNCE×3/MEC_KILL_BLAST×2/MEC_FRACTAL×2）。
#   ★ content v2（FG4 fork 升级，见下 FG4 条目）：R224 的「无棱镜+敌方弹不在口径」
#   两项定标取舍已补齐——棱镜 W5_prism 镜5 + 敌弹（E7_spitter 射手切片/精英 affix_ring/
#   弹池注入）；content_version=2，旧档（version 1）谱不可比。
# · 三情景（设计 §1.2）：SA 深载驻场（HOLD=120，真机 tier2 形态）/ SAA 锚档（同 SA 但
#   tier_override=3、burst_thin=-2、pool_valve=-2、fullload=0=阀全关锚形态）/ SB 弹幕带
#   （HOLD=30，MULTI 追加叠满抬弹驻场，校准门=弹N p50∈[190,325] 且敌N∈[28,33]）。
#   情景间 static 口重注入 + 清场 + 300 帧复热（单 start_run，波次只起一次）。
# · 真机深载态哨兵全套（R228 qa_r228_ospec_cases:85-92 清单 + 阀门口）：
#   Enemy.fullload_override=1、DamagePopup.bitmap_override=1、
#   PopupGlyphAtlas.runstart_bake_override=1（runstart 烤图=开局一次性，非战斗期——
#   R227 红线不触）、DamagePipeline.settle_budget_override=-3、
#   PerfGovernor.set_process(false)+mode_override=0+tier_override=2、
#   GameFeelDirector.burst_thin_override=-3、GameLoop.pool_valve_override=-3
#   （SAA 锚档按上表换档）。
# · ★ 复审节修正口径（红线级，禁 Meta.set_setting 写即存口）——真机表现态两项补齐 +
#   真档毒化防（三情景统一生效，全部零落盘零产品码）：
#   ① add_child 前 Meta._settings 内存合并注入 {"fx_quality":1,"damage_numbers_on":true,
#      "fx_opacity":1.0} + settings_changed.emit（驱动 enemy 侧 _fx_quality_cache）——
#      对齐真机 mobile 门有效值（特效层/命中粒子两处不吃 tier 帽）；
#   ② Meta.begin_persist_defer() 全程挂起（_save 短路——成就解锁判定同步挂起，零落盘）；
#   ③ 每物理步+每采样前 RS 层强制隐藏 game_feel.chromatic_rect（桌面色差全屏拷贝中和，
#      真机 R203 已整体禁用无此件；产品 tick 在 _process 通道会反复置 visible，故逐帧重申）；
#   ④ 窗口跑强制 APPDATA 沙箱（user:// 根重定向仓内 E 盘——RunSave 波次边界写档/
#      Meta 落盘全部进沙箱，真档零接触；自检 FAIL 即中止，不硬闯）。
# · dc 读数协议（设计 §1.4）：逐帧 RenderingServer.get_rendering_info
#   (TOTAL_DRAW_CALLS_IN_FRAME)（口径=上一完成帧）；手动 _gl._physics_process(1/60)
#   + await process_frame 真渲染帧（R224/R228 泵协议 _pump_process_budget）；基线 60 帧
#   取中位 → P1 累积关断（F1→F12 固定树序，每族弃 3 帧+settle 10 帧+采样 30 帧取中位，
#   边际 dc_i=dc_(i-1)−dc_i）→ 全隐藏残差独立读窗 → P2 单独可见（每族单独开其余全掩）
#   → P3 逆序复跑（仅 SA）。★逐帧族掩码重放（P1/P2/P3 共同基础设施）：关断态每物理步
#   对 churn 域（七池+特效层+_gl 直属演出件）重新套用族掩码——深载期 DeathPop/跳字/
#   粒子/碎片持续新 spawn，一次性关断必被新件污染；「弃 3 帧」只解决读旧帧不解决新件。
# · ★ 掩码实现=RenderingServer.canvas_item_set_visible RS 层逐件驱动（target=自然可见
#   ∧族未掩）：零场景树状态污染（产品 spawn/复用/池归还不被夹具残留毒化，unmask 后下一
#   重放步自动恢复自然可见性），节点 visible 永不触碰。族根不藏单件——敌桶域 F1/F2/F3
#   共存（桶收编敌、穿插件挂桶域）必须逐件分类（qa_r228_ospec_cases:246-329 逐件分类器
#   同思路改造为 RS 掩码驱动）。静态域（HUD/云背景/玩家/UI 屏/杂项）只在掩码集变更时
#   全树走一遍（战斗期不 churn，无需逐帧）。
# · 13 族分类表（设计 §1.3 的 12 族 + FG4 fork v2 扩族）：F1 敌桶本体（敌池域内 Enemy
#   及其非装饰子件）| F2 敌子件装饰（敌根子级名 Crown/GroundShadow/ArmorPlate/
#   FuseRing/Sparkle*/Satellite*）| F3 穿插件（桶域内 DeathPop/PoisonSplash/Telegraph
#   圈——SpellRing/BlinkRing/AffixCircle；自绘件）| F4 弹桶（projectile+homing 池域
#   team=0 玩家弹）| F5 碎片桶（xp 池域）| F6 粒子发射器（粒子池域）| F7 特效层
#   （elemental_fx 层根）| F8 跳字（popup 池域）| F9 HUD/BossBar/UI 屏 | F10 云背景 |
#   F11 玩家树（含棱镜本体+镜面化身——玩家侧内容不入新族）| F12 激光网+残余（laser
#   池域 + BlastStarFx/LevelBurst/相机等未归类 CanvasItem 兜底族）| **F13 敌弹**
#   （弹桶域 team=1 逐件细分——ProjectileBase.team 0=玩家/1=敌，projectile_base.gd:15；
#   v2 扩族键，旧 12 族编号零挪动防跨版本错位）。
# · 决策量白名单（设计 §1.5）：族占比与刀后相对降幅；绝对 dc 只用于夹具内部一致性
#   （FG3 闭环门），不与真机绝对值互比（RTX4070 与手机 GPU 不可等同）。
# · FG4 分叉（设计 §1.6）：SA 基线 dc ≥500 → 主线按谱定刀；<500 → 缺口指向内容差。
#   ★ content_version=2（本跑=FG4 fork 内容注入升级，首跑读数 240/258/263 全 <500
#   已裁定走 fork——缺口=内容差非渲染器）注入三项（全部零产品码，走产品真实路径）：
#   ① 敌方远程弹（R224 QA D4 已知洞）：a) 弹池注入补缺环——手动 spawn 补
#      enemy.projectile_pool（enemy_spawner.gd:112 出生管线同款，无此口 RANGED/词缀
#      _tick 首行判 null 直接 return 不开火）；b) 射手切片 E7_spitter×5 入平铺池
#      （RANGED 原型，E7_spitter.tres：fire_cd 2.4s/bullet_speed 240/spread 10°/
#      fire_range 360；enemy.gd:1013 弹寿命 5.0s→稳态 ~2.08 发/射手，enemy.gd:976
#      _tick_ranged 驻停射击）——切片占比 5/47≈10.6% 与 w17 spitter 占比 4/44≈9%
#      同量级；c) 精英词缀 affix_ring（w16 精英真机经 _elite_affix_roll
#      enemy_spawner.gd:134 得词缀；AFFIX_DEFS enemy.gd:171 cd 7s、enemy.gd:1506
#      释放 8 发环弹+AffixCircle 读条圈=F3 真实穿插件内容）。
#      量级对拍：敌弹稳态 ~15-25（射手）+~5.7（ring 8 发/7s×寿命 5s）≈ 真机 vc34
#      深载带 弹N=26（1:40 行 敌120）量级；SA 门=敌弹 p50>0 硬门+[8,60] 披露带
#      （精调留 post-merge 全量基线）。
#   ② 棱镜（分析报告 FG4 点名内容差——真机镜面军团指纹 R219「火102 镜面军团」；
#      R224 夹具「无棱镜」系弹带定标取舍，v2 升级补齐真构筑面）：W5_prism L5 +
#      MEC_MIRROR_SPLIT×2 → 镜 5（mirror_weapon.gd:26 MIRROR_CAP=5；镜面经
#      mirror_muzzle_cases._make_prism 生产形态装配法）。棱镜本体+镜面化身=玩家树
#      侧内容归 F11、镜面弹走 F4——不另立族键（超出 12 族归类的只有敌弹）。
#   ③ content_version 字段入 JSON schema（本轮=2；旧档缺字段=version 1，FG2 复现源
#      逐档核对版本，异版拒入防跨版本静默混比）。
# · ★ post-merge 统一验证（T8 前置，content v2 刀后）——三浪合并 K1/K4/K2c 全落地：
#   K1 跳字根 alpha 4 档量化（damage_popup.gd Q_ALPHA_STEPS=4，产品级恒开）；
#   K4 HUD Label 语义角色量化色板（theme.gd:179 单源口 label_sticker，产品级恒开，
#   语义色保全在案）；K2c 死亡演出并发帽（enemy.gd DEATHPOP_FX_CAP=10，
#   deathpop_cap_override 四态：-1=自动门/-2=强制关否决/-3=模拟 mobile/1=强开）。
#   ★★ K2c 桌面 auto 态恒关（enemy.gd:411 OS.has_feature("mobile") 桌面=false）——
#   权威臂 SA/SB 用 -3 模拟档（与 burst_thin/pool_valve 同款哨兵约定，代表真机
#   tier2 帽开形态），SAA 锚档用 -2（阀全关=否决档同语义）；K2c 否决臂独立进程
#   （-- --k2c_veto）同内容同刀码仅帽 -2 → 与权威臂 SA 的 F1/F3 差=纯 K2c 刀效。
#   否决臂落独立档 docs/qa/qa_r230_dcscan_k2c_veto.json（不入基线轮转链）。
#   ★ 门禁（_kg_adjudicate，读 docs/qa/qa_r230_dcscan_baseline_v1_ref.json=v1 无刀
#   参照）：KG1 F8 降幅 ≥60%（≤14 带）；K4 F9 降幅 ∈[25,45]；KG2 非目标族漂移
#   ≤±5（内容稳定族 F2/F5/F6/F7/F10/F12 中占比 ≥8% 者硬门，余 INFO——F1 刀效混淆
#   不入 v1 对标走否决臂、F3/F4/F13/F11 内容已变不入 KG2）。
#   ★ FG2 主控重锚：容差 ±25%→±30%，范围 top5 并集→占比 ≥8% 族（任一跑）并集。
# 纪律：只读不改游戏代码；禁 user:// 写入（沙箱+persist_defer 双保险）；禁战斗期烤图
#   （runstart 烤图在开局一次性完成）；无 test_ 前缀不入电池。
extends RefCounted

const MAIN_SCENE := "res://scenes/main.tscn"
const GROVE_TABLE := "res://resources/maps/wave_table_grove.tres"
const DT60 := 1.0 / 60.0
const HOLD_SA := 120                    # SA/SAA 驻场敌数（vc34 深载段常驻值）
const HOLD_SB := 30                     # SB 驻场敌数（vc34 弹幕带 敌28-33）
const SB_EXTRA_MULTI := 1               # SB 追加 MULTI 层数（累计 ×3——「叠满」待调参旋钮）
const SB_PROJ_CAP := 260                # SB 弹驻场软帽（fixture 侧 pool.soft_limit 定标旋钮——
                                        # 校准史：MULTI ×5/×3 实测均弹 447=默认软帽 448 饱和
                                        # （BOUNCE 10s 寿命地板下消耗不随敌数下降，稳态=帽钳）；
                                        # 改弹驻场帽 260=带 [190,325] 中点，确定性落带）
const WARMUP_FRAMES := 300              # 5s：spin_up + 弹/结算/死亡/贴图惰性建稳态
const BASELINE_FRAMES := 60
const DISCARD_FRAMES := 3               # 可见性切换后弃帧（读旧帧口径）
const SETTLE_FRAMES := 10
const SAMPLE_FRAMES := 30
const TOPUP_PER_FRAME := 8              # SPAWN_PER_FRAME 同款补位节流
const PLAYER_HOME := Vector2(360.0, 900.0)
const ENEMY_HP_SCALE := 0.3             # r224 定标值
const FG3_TOL := 5                      # 闭环门容差（逐帧掩码重放强度下）
const FG3_TOL_DISCLOSED := 8            # churn 高放宽档（须披露）
const SB_PROJ_BAND := Vector2i(190, 325)  # SB 弹N 校准带（vc34 2:15-2:16）
const SB_ENEMY_BAND := Vector2i(28, 33)
const SANDBOX_MARKER := ".qa_sandbox_r230"
const BASELINE_JSON := "res://docs/qa/qa_r230_dcscan_baseline.json"

# ── FG4 fork 内容注入（content_version=2）──────────────────────────
const CONTENT_VERSION := 2
const SPITTER_ID := &"E7_spitter"         # RANGED 原型（w3-w17 表内常驻远程种）
const SPITTER_COUNT := 5                  # 射手切片（平铺池占比 ~10.6%≈w17 spitter 9%）
const ELITE_AFFIX := &"affix_ring"        # 精英词缀取射击面（8 发环弹/7s——敌弹量级主源）
const PRISM_LEVEL := 5                    # 真机镜面军团指纹（镜5=R219 推断）
const PRISM_SPLIT := 2                    # MEC_MIRROR_SPLIT 层数（L5 曲线 3+2=帽 5）
const ENEMY_PROJ_FAM := 13                # 新族键：F13 敌弹（team=1 逐件细分）
const EPROJ_BAND := Vector2i(8, 60)       # SA 敌弹量级披露带（真机 1:40 行 弹26 量级）

# ── post-merge 统一验证（content v2 刀后）─────────────────────────
const FG2_TOL_PCT := 30                   # 主控重锚：两两相对差容差（±25→±30）
const FG2_SHARE_FLOOR := 8.0              # 判门范围：占比 ≥8% 族（任一源）
const VETO_JSON := "res://docs/qa/qa_r230_dcscan_k2c_veto.json"
const V1_REF_JSON := "res://docs/qa/qa_r230_dcscan_baseline_v1_ref.json"
const KG1_FAM := 8                        # K1 目标族（跳字）
const K4_FAM := 9                         # K4 目标族（HUD）
const K2C_FAMS := [1, 3]                  # K2c 读数族（F3 主证/F1 耦合面披露）
const KG2_STABLE_FAMS := [2, 5, 6, 7, 10, 12]   # 内容稳定非目标族（KG2 候选集）

const DOM_ENEMY := 20                   # 内部域码：敌桶域（F1/F2/F3 逐件细分；v2 起
                                        # 与族键空间隔离——13 已被 F13 敌弹占用）
const F_COUNT := 13
const F_NAMES: Array[String] = [
	"F1敌桶本体", "F2敌子件装饰", "F3敌桶穿插件", "F4弹桶", "F5碎片桶", "F6粒子发射器",
	"F7特效层", "F8跳字", "F9HUD/BossBar", "F10云背景", "F11玩家树", "F12激光网+残余",
	"F13敌弹",
]

var tree: SceneTree
var _gl: GameLoop = null
var _fails: int = 0
var _comp: Array[Dictionary] = []
var _cursor: int = 0
var _spawned_total: int = 0
var _hold: int = HOLD_SA                # 当前情景驻场帽（SB=30）
var _is_headless: bool = false
var _smoke_only: bool = false
var _veto_only: bool = false              # -- --k2c_veto：K2c 否决臂（帽关单情景对照）
var _k2c_force_off: bool = false          # 否决臂旗：_scenario 注入帽 -2（压过 -3 档）
var _masked: Dictionary = {}            # fam(int) -> true（当前关断族集）
var _exempt: int = 0                    # P2 豁免族（0=无）
var _mask_dirty: bool = true
var _fam_root_map: Dictionary = {}      # Node -> 域码
var _churn_roots: Array = []            # [[Node, 域码]]——逐帧重放域
var _chrom_node: CanvasItem = null      # 色差件（掩码走查显式跳过+逐帧 RS 隐藏）
var _dc_buf: Array[int] = []            # 当前采样窗读数（_window 填充）
var _gate_results: Dictionary = {}      # 本进程门读数（入 JSON）
var _results: Dictionary = {}           # 情景结果（入 JSON）
var _fg0: Dictionary = {}
var _fg2: Dictionary = {}
var _fg4: Dictionary = {}
var _kg: Dictionary = {}                 # KG 门读数（入 JSON）
var _blade_order: Array = []


func run(p_tree: SceneTree) -> void:
	tree = p_tree
	_is_headless = DisplayServer.get_name() == "headless"
	_smoke_only = OS.get_cmdline_user_args().has("--smoke")
	_veto_only = OS.get_cmdline_user_args().has("--k2c_veto")
	seed(20261004)
	if _is_headless:
		await _arm_headless()
		return
	# ── 窗口臂（真渲染器）──
	if not _sandbox_check():
		_teardown_static()
		return
	if not _boot():
		_teardown()
		return
	if _veto_only:
		await _arm_veto()
	elif _smoke_only:
		await _arm_smoke()
	else:
		await _arm_full()
	_teardown()


func fail_count() -> int:
	return _fails


# ── FG0 headless 对照臂（dc==0=RS 短路证明）──────────────────────────

func _arm_headless() -> void:
	print("══ FG0 对照臂（headless）：dc 读数应恒 0 ══")
	if not _boot():
		_teardown()
		return
	for i in range(HOLD_SA):
		_spawn_one()
	await _frames(WARMUP_FRAMES, 0, {})
	var w := await _window(0, 0)
	var max_dc := int(w["max"])
	_fg0 = {"arm": "headless", "max_dc": max_dc, "samples": SAMPLE_FRAMES}
	_gate("FG0-headless dc 恒 0（RS 短路对照）", max_dc == 0,
		"max_dc=%d（%d 帧采样）" % [max_dc, SAMPLE_FRAMES])
	_teardown()


# ── FG0 窗口烟测臂（-- --smoke：boot+SA 基线窗+P1 闭环——content v2 注入门在此验证）──

func _arm_smoke() -> void:
	print("══ FG0 烟测臂（窗口 gl_compatibility，content v2）：dc>0 + 注入生效 + 13 族闭环 ══")
	_results["SA"] = await _scenario("SA", "SA 深载驻场（smoke 臂：内容注入门+P1 闭环）",
		HOLD_SA, false, 1)
	var res: Dictionary = _results["SA"]
	_fg0 = {"arm": "window-smoke", "baseline_dc": int(res["baseline_dc"]),
		"samples": (res["baseline_dcs"] as Array).size()}
	_gate("FG0-window 首采样段 dc 中位 >0", int(res["baseline_dc"]) > 0,
		"baseline_dc=%d（%d 帧中位）" % [int(res["baseline_dc"]),
		(res["baseline_dcs"] as Array).size()])
	_clear_field()
	# 烟测不写基线 JSON（防污染 T3 轮转链）——FG1 由全量跑承担


# ── K2c 否决臂（-- --k2c_veto）：同内容同刀码仅帽 -2，对照当前基线 SA=纯 K2c 刀效 ──

func _arm_veto() -> void:
	print("══ K2c 否决臂（deathpop_cap_override=-2 帽关）：SA P1+P2 对照权威臂（帽开 -3）══")
	_k2c_force_off = true
	Enemy.deathpop_cap_override = -2
	_results["SA"] = await _scenario("SA", "SA 深载驻场（K2c 否决臂：帽关，余全同权威臂）",
		HOLD_SA, false, 1 | 2)
	var own: Dictionary = _results["SA"]
	var own_marg := _marg_by_fam(own)
	var own_p2: Dictionary = {}
	for r in own.get("P2", []):
		own_p2[int(r["fam"])] = int(r["indep_dc"])
	# 对照源=磁盘 v2 链（当前基线+prev1+prev2=权威 3 跑，逐档核版）F1/F3 边际均值——
	# 抗单跑读数噪声（F3 族 dc 面小，v1 实测边际噪声 ±3）
	var ref_f: Dictionary = {1: [], 3: []}          # fam -> Array[int]
	var ref_f2: Dictionary = {1: [], 3: []}         # P2 indep
	var n_ref := 0
	for path in [BASELINE_JSON, BASELINE_JSON.get_base_dir()
			+ "/qa_r230_dcscan_baseline_prev1.json",
			BASELINE_JSON.get_base_dir() + "/qa_r230_dcscan_baseline_prev2.json"]:
		var txt := FileAccess.get_file_as_string(path)
		if txt.is_empty():
			continue
		var parsed: Variant = JSON.parse_string(txt)
		if not (parsed is Dictionary):
			continue
		var pd: Dictionary = parsed
		if int(pd.get("meta", {}).get("content_version", 1)) != CONTENT_VERSION:
			continue
		var sa: Dictionary = pd.get("scenarios", {}).get("SA", {})
		if sa.is_empty() or not sa.has("P1"):
			continue
		var m := _marg_by_fam(sa)
		if m.has(1):
			(ref_f[1] as Array).append(int(m[1]))
		if m.has(3):
			(ref_f[3] as Array).append(int(m[3]))
		for r in sa.get("P2", []):
			var f := int(r["fam"])
			if ref_f2.has(f):
				(ref_f2[f] as Array).append(int(r["indep_dc"]))
		n_ref += 1
	if n_ref == 0:
		_gate("K2c 否决臂对照源（v2 权威链）", false,
			"无 v2 基线档——先跑权威 3 跑全扫再跑本臂")
		_store_veto_json(own, {})
		_clear_field()
		return
	var avg := func(arr: Array) -> int:
		var s := 0
		for v in arr:
			s += int(v)
		return int(round(float(s) / float(arr.size())))
	var f3_veto := int(own_marg.get(3, 0))
	var f3_ref: int = avg.call(ref_f[3])
	var f1_veto := int(own_marg.get(1, 0))
	var f1_ref: int = avg.call(ref_f[1])
	# K2c 主证=F3 穿插件族（DeathPop/PoisonSplash 自绘件逐件 1 dc——帽收活口直接砍
	# 该族 dc 面）；F1=耦合面披露（pops 与敌本体桶批耦合，方向不限幅）；P2 indep=辅证
	#（单独可见无掩码耦合，信号更净——DEATHPOP_FX_CAP=10 下稳态活口 ~7 不触帽、
	# 风暴带 ~80 收缩 ~8 倍，P1 中位读数对风暴敏感度有限，两证同披露）
	var f3_veto_p2 := int(own_p2.get(3, -1))
	var f3_ref_p2: int = int(avg.call(ref_f2[3])) if not (ref_f2[3] as Array).is_empty() else -1
	_gate("K2c 否决臂：F3 边际 帽关(%d) − 帽开均值(%d,%d跑) > 0（纯刀效主证）"
		% [f3_veto, f3_ref, n_ref], f3_veto - f3_ref > 0,
		"差=%+d（DEATHPOP_FX_CAP=10，enemy.gd:386）" % [f3_veto - f3_ref])
	if f3_veto_p2 >= 0 and f3_ref_p2 >= 0:
		_gate_disclosed("K2c 否决臂辅证：F3 P2 单独可见 帽关(%d) − 帽开(%d) = %+d"
			% [f3_veto_p2, f3_ref_p2, f3_veto_p2 - f3_ref_p2], true,
			"辅证披露（无掩码耦合面；主证门以上行为准）")
	_gate_disclosed("K2c 否决臂：F1 边际 耦合面 差=%+d（披露不判刀）" % [f1_veto - f1_ref],
		true, "帽关=%d 帽开均值=%d（F1 主效混淆面=射手注入，不入对标）" % [f1_veto, f1_ref])
	_gate_info("K2c 否决臂留档：%s（不入基线轮转链）" % VETO_JSON)
	_store_veto_json(own, {"n_refs": n_ref, "f1_marg_ref": f1_ref, "f3_marg_ref": f3_ref,
		"f3_p2_ref": f3_ref_p2})
	_clear_field()


func _store_veto_json(p_own: Dictionary, p_ref: Dictionary) -> void:
	var root: Dictionary = {
		"meta": {
			"date": "2026-10-04",
			"content_version": CONTENT_VERSION,
			"arm": "k2c_veto（deathpop_cap_override=-2 帽关，余同权威臂 SA：哨兵 -3/全load=1/tier2/内容 v2）",
			"reference": "磁盘当前基线 qa_r230_dcscan_baseline.json 的 SA（权威末跑，帽开 -3）",
		},
		"veto_sa": p_own,
		"reference_sa": p_ref,
		"gates": _gate_results,
	}
	var f := FileAccess.open(VETO_JSON, FileAccess.WRITE)
	if f == null:
		_gate("K2c 否决臂 JSON 落盘", false, "打开失败：%s" % VETO_JSON)
		return
	f.store_string(JSON.stringify(root, "\t"))
	f.close()


# ── 全量臂：三情景 × 12 族 × P1/P2/P3 ─────────────────────────────

func _arm_full() -> void:
	_fg0 = {"arm": "window-full", "rendering": _rendering_method_str()}
	print("══ R230 dc 分族扫描全量：SA(P1+P2+P3) / SAA 锚档(P1+P2) / SB 弹幕带(P1) ══")
	_results["SA"] = await _scenario("SA", "SA 深载驻场（真机 tier2 形态，复刻 R224 夹具）",
		HOLD_SA, false, 1 | 2 | 4)
	_results["SAA"] = await _scenario("SAA", "SAA 锚档（阀全关：tier3/burst-2/valve-2/fullload0）",
		HOLD_SA, true, 1 | 2)
	_sb_raise_multi()
	_results["SB"] = await _scenario("SB", "SB 弹幕带（敌30 + MULTI 抬弹驻场，校准门弹N∈[%d,%d]）"
		% [SB_PROJ_BAND.x, SB_PROJ_BAND.y], HOLD_SB, false, 1)
	_fg5_check()
	_fg4_adjudicate()
	_kg_adjudicate()
	_fg2_cross_run()
	_store_baseline()


# ── 引导（R228 同构 + 复审节修正哨兵）──────────────────────────────

func _boot() -> bool:
	# ★ 复审节修正（红线级）：settings 内存注入在 add_child 前（池预热在 _ready 期，
	#   Enemy._fx_q 首读即缓存）——禁 Meta.set_setting（写即存，窗口模式落真档）
	var s: Dictionary = Meta.get("_settings")
	s["fx_quality"] = 1
	s["damage_numbers_on"] = true
	s["fx_opacity"] = 1.0
	Meta.settings_changed.emit(&"fx_quality")
	# ★ 全程挂起 Meta 落盘（begin_persist_defer 后 _save 短路；end/cancel 永不调用）
	Meta.begin_persist_defer()
	var scene: PackedScene = load(MAIN_SCENE)
	_gl = scene.instantiate() as GameLoop
	_gl.name = "QaR230Dcscan"
	# 深载表现态哨兵（必须先于 add_child：池预热在 _ready 期跑，DamagePopup._ready
	# 的位图门晚置会让预热批先装 Label——R228 同款时序）
	Enemy.fullload_override = 1
	DamagePopup.bitmap_override = 1
	PopupGlyphAtlas.runstart_bake_override = 1
	DamagePipeline.settle_budget_override = -3
	tree.root.add_child(_gl)
	_gl.set_physics_process(false)
	if not (_gl.boot_ready and _gl.state == GameConst.GameStatus.MENU):
		push_error("[dcscan] Boot 失败：%s" % str(_gl.boot_fatal))
		_fails += 1
		return false
	PerfGovernor.set_process(false)
	PerfGovernor.mode_override = 0
	PerfGovernor.tier_override = 2
	GameFeelDirector.burst_thin_override = -3
	GameLoop.pool_valve_override = -3
	# K2c 哨兵（post-merge）：桌面 auto 恒关（enemy.gd:411）——-3 模拟档=真机 tier2
	# 帽开形态（_deathpop_cap_on 直入 tier 分支；burst_thin 同款四态约定）。_scenario
	# 逐情景重注入（SAA 锚档=-2 阀全关）；否决臂（-- --k2c_veto）覆盖为 -2。
	Enemy.deathpop_cap_override = -3
	_hold = HOLD_SA
	if _gl.game_feel != null and _gl.game_feel.chromatic_rect != null:
		_chrom_node = _gl.game_feel.chromatic_rect
	_gl.current_map_id = &"world_grove"
	if not _gl.start_run():
		push_error("[dcscan] start_run 失败")
		_fails += 1
		return false
	_gl.player.set("xp_need", 1.0e12)
	_gl.player.set("max_hp", 1.0e12)
	_gl.player.set("hp", 1.0e12)
	_gl.player.unlocked_slots = 6
	_gl.player.global_position = PLAYER_HOME
	var gatling: WeaponBase = _gl.player.add_weapon(_gl.registry.get_weapon(&"W2_gatling"))
	if gatling == null:
		push_error("[dcscan] W2 加特林装配失败")
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
	print("boot.词条：PIERCE×%d/3 MULTI×%d/2 BOUNCE×%d/3 NOVA×%d/2 FRACTAL×%d/2（挂载回执）" % [
		ok["pierce"], ok["multi"], ok["bounce"], ok["nova"], ok["fractal"]])
	# FG4 fork 内容注入②：棱镜（content v2——分析报告 FG4 点名内容差；真机镜面军团
	# 指纹 R219「火102 镜面军团」。装配法=mirror_muzzle_cases._make_prism 生产形态）
	var prism := MirrorWeapon.new()
	prism.setup(_gl.registry.get_weapon(&"W5_prism"), _gl.player, _gl.player.get("_deps"))
	prism.meta_atk_pct = 0.0
	if not _gl.player.equip_weapon(prism):
		push_error("[dcscan] W5 棱镜装配失败")
		_fails += 1
		return false
	prism.level = PRISM_LEVEL
	var split_ok := 0
	for i in range(PRISM_SPLIT):
		if prism.attach_trait(_gl.registry.get_trait(&"MEC_MIRROR_SPLIT")):
			split_ok += 1
	prism.sync_mirrors(true)
	var mirrors_n := int(_gl.player.call(&"mirror_count"))
	_gate("G-棱镜注入：镜面数=5（W5_prism L%d+SPLIT×%d→帽5）" % [PRISM_LEVEL, split_ok],
		mirrors_n == 5 and split_ok == PRISM_SPLIT,
		"mirror_count=%d split=%d/%d（MIRROR_CAP=5，mirror_weapon.gd:26）"
			% [mirrors_n, split_ok, PRISM_SPLIT])
	_gl.stage_probe_enabled = true
	if not _load_composition():
		return false
	_build_fam_roots()
	print("boot.哨兵：fullload=1 位图=1 补烤=%d 结算帽=-3 tier=2 帧率优先 burst_thin=-3 pool_valve=-3 deathpop_cap=%d | Meta 内存注入 fx_quality=%s damage_numbers_on=%s fx_opacity=%s persist_defer 挂起=1（零落盘）| 位图就绪=%d" % [
		1 if PopupGlyphAtlas.runstart_bake_override == 1 else 0,
		Enemy.deathpop_cap_override,
		str(Meta.settings("fx_quality")), str(Meta.settings("damage_numbers_on")),
		str(Meta.settings("fx_opacity")), 1 if PopupGlyphAtlas.ready() else 0])
	print("boot：grove w16 构成 %d（含 %s 射手×%d=content v2）池压血×%.2f；三情景=SA深载/SAA锚档/SB弹幕带" % [
		_comp.size(), SPITTER_ID, SPITTER_COUNT, ENEMY_HP_SCALE])
	return true


func _load_composition() -> bool:
	var tbl: Resource = load(GROVE_TABLE)
	if tbl == null or not ("entries" in tbl):
		push_error("[dcscan] 波表加载失败：%s" % GROVE_TABLE)
		_fails += 1
		return false
	var entry: Resource = null
	for e in tbl.get("entries"):
		if int(e.get("index")) == 16:
			entry = e
			break
	if entry == null:
		push_error("[dcscan] grove 波表无 index==16 条目")
		_fails += 1
		return false
	for c in entry.get("composition"):
		var src: EnemyData = _gl.registry.get_enemy(StringName(c.get("enemy_id")))
		if src == null:
			push_error("[dcscan] 敌数据缺失：%s" % str(c.get("enemy_id")))
			_fails += 1
			return false
		var data: EnemyData = src.duplicate()
		data.hp_base = data.hp_base * ENEMY_HP_SCALE
		var tags := int(c.get("tags", 0))
		# FG4 fork 内容注入①c：精英词缀（真机 w16 精英经 spawner._elite_affix_roll
		# enemy_spawner.gd:134 滚词缀——手动 spawn 补齐同款；取射击面 affix_ring=
		# AFFIX_DEFS cd 7s（enemy.gd:171），释放 8 发环弹（enemy.gd:1506）+ AffixCircle
		# 读条圈=F3 真实穿插件内容。双词缀 30% 面不入（确定性优先，披露）
		if (tags & GameConst.TAG_ELITE) != 0:
			var affixes: Array[StringName] = [ELITE_AFFIX]
			data.elite_affixes = affixes
		for i in range(int(c.get("count", 1))):
			_comp.append({"data": data, "tags": tags})
	# FG4 fork 内容注入①b：敌方远程弹射手切片（R224 QA D4 已知洞——真机深载带敌方
	# 持续射弹而夹具零敌弹。E7_spitter=RANGED 原型：fire_cd 2.4s/bullet_speed 240/
	# spread 10°/fire_range 360（E7_spitter.tres）；enemy.gd:1013 弹寿命 5.0s→驻停
	# 射击稳态 ~2.08 发/射手（enemy.gd:976 _tick_ranged）。切片 5/47≈10.6%≈w17
	# spitter 占比 4/44≈9% → 驻场 120 含 ~12.8 射手 → 敌弹稳态 ~15-25+ring ~5.7
	# ≈ 真机 vc34 深载带 弹N=26（1:40 行 敌120）量级）
	var sp_src: EnemyData = _gl.registry.get_enemy(SPITTER_ID)
	if sp_src == null:
		push_error("[dcscan] 射手数据缺失：%s" % SPITTER_ID)
		_fails += 1
		return false
	var sp_data: EnemyData = sp_src.duplicate()
	sp_data.hp_base = sp_data.hp_base * ENEMY_HP_SCALE
	for i in range(SPITTER_COUNT):
		_comp.append({"data": sp_data, "tags": 0})
	_comp.shuffle()
	return true


var _sb_proj_soft_orig: int = -1         # SB 软帽原值（teardown 还原）


func _sb_raise_multi() -> void:
	# SB 定标双旋钮（fixture 侧，产品态用后即还原）：①追加 MULTI 层（「叠满」×3）；
	# ②弹驻场软帽 SB_PROJ_CAP=260——BOUNCE 10s 寿命地板下消耗不随敌数下降，MULTI
	# 旋钮只能顶到软帽饱和（校准史 ×5/×3 均 447），故以软帽钳活弹落带 [190,325] 中点
	for w in _gl.player.weapon_slots:
		if w is WeaponBase and (w as WeaponBase).data != null \
				and (w as WeaponBase).data.id == &"W2_gatling":
			var added := 0
			for i in range(SB_EXTRA_MULTI):
				if (w as WeaponBase).attach_trait(_gl.registry.get_trait(&"AFF_MULTI")):
					added += 1
			var pp := _gl.pools[&"projectile"] as ProjectilePool
			_sb_proj_soft_orig = pp.soft_limit
			pp.soft_limit = SB_PROJ_CAP
			print("SB.构筑：追加 MULTI×%d（累计 ×%d）+ 弹软帽 %d→%d（校准旋钮，teardown 还原）" % [
				added, 2 + added, _sb_proj_soft_orig, SB_PROJ_CAP])
			return
	_gate("SB MULTI 追加装配", false, "weapon_slots 未找到 W2_gatling")


# ── 沙箱自检（窗口跑红线：user:// 不写——RunSave 波次边界会写档）──────

func _sandbox_check() -> bool:
	var udir := OS.get_user_data_dir()
	var ok: bool = udir.contains(SANDBOX_MARKER)
	_gate("G-沙箱 user:// 重定向生效（含 %s）" % SANDBOX_MARKER, ok,
		"user_dir=%s%s" % [udir, "" if ok else " ←未重定向！窗口跑必须 APPDATA 指向仓内沙箱，中止防真档污染"])
	return ok


# ── 族根表 ─────────────────────────────────────────────────────────

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
	# churn 域（逐帧重放）：七池 + 特效层（新 spawn 全在此）；静态域（HUD/云背景/玩家/
	# UI 屏/杂项 F12）战斗期不 churn——掩码集变更时全树走一遍即可
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


# ── 情景主体 ───────────────────────────────────────────────────────

func _scenario(p_key: String, p_label: String, p_hold: int, p_anchor: bool,
		p_proto: int) -> Dictionary:
	print("── %s ──" % p_label)
	# static 口重注入（SAA 锚档=阀全关形态；其余=真机 tier2 深载形态）
	Enemy.fullload_override = 0 if p_anchor else 1
	PerfGovernor.tier_override = 3 if p_anchor else 2
	GameFeelDirector.burst_thin_override = -2 if p_anchor else -3
	GameLoop.pool_valve_override = -2 if p_anchor else -3
	Enemy.deathpop_cap_override = -2 if (p_anchor or _k2c_force_off) else -3
			# K2c：锚档=帽关（阀全关同语义）；否决臂 _k2c_force_off=同内容同刀码仅帽关
	_hold = p_hold
	_masked.clear()
	_exempt = 0
	_mask_dirty = true
	_clear_field()
	_spawned_total = 0
	for i in range(p_hold):
		_spawn_one()
	await _frames(WARMUP_FRAMES, 0, {})
	var res := await _baseline_phase()
	var frame := WARMUP_FRAMES + BASELINE_FRAMES
	# P1 累积关断（主读数；固定树序 F1→F12）
	var p1_rows: Array = []
	var prev_dc := int(res["baseline_dc"])
	if (p_proto & 1) != 0:
		for fam in range(1, F_COUNT + 1):
			_masked[fam] = true
			_mask_dirty = true
			var after := await _window(frame, 0)
			frame = int(after["frame"])
			p1_rows.append({"fam": fam, "after_dc": int(after["median"]),
				"marginal_dc": prev_dc - int(after["median"])})
			prev_dc = int(after["median"])
		# 全隐藏残差独立读窗（FG3 望远镜恒等的残差项）
		var resid := await _window(frame, 0)
		frame = int(resid["frame"])
		res["residual_dc"] = int(resid["median"])
	else:
		res["residual_dc"] = prev_dc
	# P2 单独可见（辅读数；每族单独开、其余全掩，掩码同样逐帧重放）
	var p2_rows: Array = []
	if (p_proto & 2) != 0:
		for fam in range(1, F_COUNT + 1):
			_masked.clear()
			for f2 in range(1, F_COUNT + 1):
				if f2 != fam:
					_masked[f2] = true
			_exempt = fam
			_mask_dirty = true
			var w2 := await _window(frame, fam)
			frame = int(w2["frame"])
			p2_rows.append({"fam": fam, "indep_dc": int(w2["median"]),
				"live": int(w2["live_median"])})
		_exempt = 0
	# P3 逆序复跑（合批耦合次序敏感度；仅 SA 真机档）
	var p3_rows: Array = []
	if (p_proto & 4) != 0:
		_masked.clear()
		_mask_dirty = true
		frame = await _frames(DISCARD_FRAMES + SETTLE_FRAMES, frame, {})
		var prev3 := int(res["baseline_dc"])
		for fi in range(F_COUNT):
			var fam := F_COUNT - fi
			_masked[fam] = true
			_mask_dirty = true
			var w3 := await _window(frame, 0)
			frame = int(w3["frame"])
			p3_rows.append({"fam": fam, "after_dc": int(w3["median"]),
				"marginal_dc": prev3 - int(w3["median"])})
			prev3 = int(w3["median"])
	_report_scenario(p_key, res, p1_rows, p2_rows, p3_rows)
	res["P1"] = p1_rows
	res["P2"] = p2_rows
	res["P3"] = p3_rows
	res["hold"] = p_hold
	res["anchor"] = p_anchor
	_clear_field()
	return res


func _baseline_phase() -> Dictionary:
	# 基线窗：无掩码稳态采样（dc+stage_probe+池活口），窗尾全树快照一次取族活口
	var dcs: Array[int] = []
	var stage: Dictionary = {}
	var proj_series: Array[int] = []
	var enemy_series: Array[int] = []
	var popup_series: Array[int] = []
	var eproj_series: Array[int] = []       # content v2：敌弹（team=1）驻场读数
	var spitter_series: Array[int] = []     # content v2：射手（E7_spitter）驻场读数
	for i in range(BASELINE_FRAMES):
		await _physics_and_pump(i, {})
		_reaffirm_chromatic()
		dcs.append(_read_dc())
		var sp: Dictionary = _gl.stage_probe_us
		for k in sp:
			if not stage.has(k):
				stage[k] = [] as Array[float]
			(stage[k] as Array[float]).append(float(sp[k]) / 1000.0)
		proj_series.append(int(((_gl.pools[&"projectile"] as ProjectilePool).stats())["live"]))
		enemy_series.append(_gl.spawner.active.size())
		popup_series.append(int(_gl.popup_manager.active_popups))
		var ec := 0
		for pr in (_gl.pools[&"projectile"] as ProjectilePool).active_projectiles():
			if pr is ProjectileBase and (pr as ProjectileBase).team == 1:
				ec += 1
		eproj_series.append(ec)
		var sc := 0
		for e2 in _gl.spawner.active:
			if e2 is Enemy and (e2 as Enemy).data != null \
					and (e2 as Enemy).data.id == SPITTER_ID:
				sc += 1
		spitter_series.append(sc)
	var baseline_dc := _median_i_arr(dcs)
	var counts := _full_walk_counts()
	var stage_p50: Dictionary = {}
	for k in stage:
		stage_p50[String(k)] = snappedf(_median_f(stage[k]), 0.01)
	var res: Dictionary = {
		"baseline_dc": baseline_dc, "baseline_dcs": Array(dcs), "residual_dc": baseline_dc,
		"stage_p50_ms": stage_p50, "counts": counts,
		"live": {"proj_live": _median_i_arr(proj_series),
			"enemy_live": _median_i_arr(enemy_series),
			"popup_live": _median_i_arr(popup_series),
			"eproj_live": _median_i_arr(eproj_series),
			"spitter_live": _median_i_arr(spitter_series)},
	}
	print("  基线 dc=%d（%d 帧中位）| 敌=%d 弹=%d 跳字=%d 敌弹=%d 射手=%d | 族活口快照：F1本体=%d F2装饰=%d F3穿插件=%d F6粒子=%d F8跳字=%d F13敌弹=%d" % [
		baseline_dc, dcs.size(), res["live"]["enemy_live"], res["live"]["proj_live"],
		res["live"]["popup_live"], res["live"]["eproj_live"], res["live"]["spitter_live"],
		int(counts.get(1, 0)), int(counts.get(2, 0)),
		int(counts.get(3, 0)), int(counts.get(6, 0)), int(counts.get(8, 0)),
		int(counts.get(13, 0))])
	return res


# ── 逐帧步进/采样窗（掩码重放在这里发生）──────────────────────────

func _frames(p_n: int, p_frame: int, p_count: Dictionary) -> int:
	for i in range(p_n):
		await _physics_and_pump(p_frame + i, p_count)
		_reaffirm_chromatic()
	return p_frame + p_n


func _window(p_frame: int, p_count_fam: int) -> Dictionary:
	# 一个读数窗 = 弃 3 帧 + settle 10 帧 + 采样 30 帧取中位（设计 §1.4）。
	# p_count_fam>0 时逐帧收集该族 RS 可见件数（每帧独立快照，窗尾取中位——P2 存活列）
	_dc_buf.clear()
	var f := p_frame
	var series: Array[int] = []
	for i in range(DISCARD_FRAMES + SETTLE_FRAMES):
		var cnt := {}
		await _physics_and_pump(f, cnt)
		_reaffirm_chromatic()
		if p_count_fam > 0:
			series.append(int(cnt.get(p_count_fam, 0)))
		f += 1
	for i in range(SAMPLE_FRAMES):
		var cnt := {}
		await _physics_and_pump(f, cnt)
		_reaffirm_chromatic()
		_dc_buf.append(_read_dc())
		if p_count_fam > 0:
			series.append(int(cnt.get(p_count_fam, 0)))
		f += 1
	var max_dc := 0
	for v in _dc_buf:
		max_dc = maxi(max_dc, int(v))
	return {"frame": f, "median": _median_i_arr(_dc_buf), "max": max_dc,
		"live_median": _median_i_arr(series)}


func _physics_and_pump(p_frame: int, p_count: Dictionary) -> void:
	_kite(p_frame)
	_gl._physics_process(DT60)
	_topup()
	if _mask_dirty:
		_walk_apply(tree.root, 0, p_count)  # 掩码集变更→全树走一遍（含静态域）
		_mask_dirty = false
	elif not _masked.is_empty() or _exempt != 0:
		_churn_replay(p_count)              # 逐物理步重放（churn 域——新 spawn 件重显封堵）
	await _pump_process_budget()


func _kite(p_frame: int) -> void:
	var ang := float(p_frame) * 0.35 / 60.0
	_gl.player.global_position = Vector2(360.0 + cos(ang) * 140.0,
		660.0 + sin(ang) * 200.0)


func _spawn_one() -> void:
	var c: Dictionary = _comp[_cursor % _comp.size()]
	_cursor += 1
	var e := (_gl.pools[&"enemy"] as EnemyPool).acquire() as Enemy
	if e == null:
		return
	e.bucket_host = (_gl.pools[&"enemy"] as EnemyPool).bucket_host
	# FG4 fork 内容注入①a：弹池注入补出生管线缺环（R224 QA D4 根因）——
	# enemy_spawner.gd:112 出生管线同款；无此口 RANGED 敌 _tick_ranged/精英词缀
	# _tick_elite_affixes 首行判 projectile_pool==null 直接 return（不开火）
	e.projectile_pool = _gl.pools[&"projectile"]
	e.spawn(c["data"], 16, int(c["tags"]))
	e.global_position = Vector2(randf() * 680.0 + 20.0, randf() * 1180.0 + 40.0)
	_gl.spawner.active.append(e)
	_spawned_total += 1


func _topup() -> void:
	var alive: int = _gl.spawner.active.size()
	var want := mini(TOPUP_PER_FRAME, _hold - alive)
	for i in range(want):
		_spawn_one()


func _pump_process_budget() -> void:
	# r228 同款：手动物理驱动下泵引擎 _process 时钟至累计墙钟 ≥1/60s（演出件按真实
	# 寿命到期自清；游戏逻辑全走手动 _physics_process，泵帧不双推游戏态）
	var t0 := Time.get_ticks_usec()
	while Time.get_ticks_usec() - t0 < 16667:
		await tree.process_frame


func _read_dc() -> int:
	return RenderingServer.get_rendering_info(
		RenderingServer.RENDERING_INFO_TOTAL_DRAW_CALLS_IN_FRAME)


func _reaffirm_chromatic() -> void:
	# 桌面色差件逐帧重申 RS 隐藏（产品 tick 在 _process 通道反复置 visible——泵帧窗内
	# 会顶回；真机 R203 整体禁用无此件，不中和则全屏拷贝污染全族读数）
	if _chrom_node != null and is_instance_valid(_chrom_node) \
			and _chrom_node.get_canvas_item().is_valid():
		RenderingServer.canvas_item_set_visible(_chrom_node.get_canvas_item(), false)


# ── RS 层族掩码（零场景树状态污染）────────────────────────────────

func _churn_replay(p_count: Dictionary) -> void:
	# 逐物理步重放：churn 域新 spawn 件（DeathPop/跳字/粒子/碎片/演出件）会被产品
	# 置回可见——RS 层逐件重申 target=自然可见∧族未掩（一次性关断必被新件污染，
	# 「弃 3 帧」只解决读旧帧——设计 §1.4 掩码重放条款）
	for r in _churn_roots:
		_walk_apply(r[0], int(r[1]), p_count)
	# _gl 直属演出件（BlastStarFx/LevelBurst——kill_blast churn，F12 域外件）
	for c in _gl.get_children():
		if _fam_root_map.has(c):
			continue
		_walk_apply(c, 0, p_count)


func _walk_apply(p_root: Node, p_root_fam: int, p_count: Dictionary) -> void:
	# BFS：fam 继承 + 域根覆盖 + 敌桶域逐件细分（F1/F2/F3 共存一域——层级根开关
	# 关不掉单族，R228 复盘同结论）；对每个 CanvasItem 驱动
	# RS.canvas_item_set_visible(target=自然可见∧族未掩)。节点 visible 永不触碰。
	var queue: Array = [[p_root, p_root_fam]]
	while not queue.is_empty():
		var head: Array = queue.pop_front()
		var n: Node = head[0]
		var fam := int(head[1])
		if _fam_root_map.has(n):
			fam = int(_fam_root_map[n])
		# FG4 fork 扩族（content v2）：弹桶域逐件细分——team=1 敌弹独立 F13（ProjectileBase
		# .team 0=玩家/1=敌，projectile_base.gd:15；玩家弹留 F4——敌弹 dc 面此前混入
		# F4 读数为 0，v2 起独立成族）
		if fam == 4 and n is ProjectileBase \
				and (n as ProjectileBase).team == 1:
			fam = ENEMY_PROJ_FAM
		var eff_fam := fam
		var child_inh := fam
		if fam == DOM_ENEMY:
			eff_fam = _classify_enemy_domain(n)
			if eff_fam == 2 or eff_fam == 3:
				child_inh = eff_fam            # 装饰/穿插件子树整体同族
			else:
				child_inh = DOM_ENEMY          # 敌本体与其子件——子级继续域内细分
		if n is CanvasItem and n != _chrom_node:
			var cfam := eff_fam
			if cfam == 0 or cfam == DOM_ENEMY:
				cfam = 12                      # 未归类 CanvasItem → 兜底族
			var ci := n as CanvasItem
			var target: bool = ci.is_visible_in_tree() \
				and (not _masked.has(cfam) or cfam == _exempt)
			var rid := ci.get_canvas_item()
			if rid.is_valid():
				RenderingServer.canvas_item_set_visible(rid, target)
			if target:
				# 无守卫恒计数（fresh 空 dict=本帧计数起点，is_empty 守卫会让首件
				# 永远写不进——初版实证 P2 存活列全 0 的根因）
				p_count[cfam] = int(p_count.get(cfam, 0)) + 1
		for c in n.get_children():
			queue.append([c, child_inh])


func _classify_enemy_domain(p_n: Node) -> int:
	# 敌桶域逐件细分：装饰名集（敌根子级——enemy.gd:401-406/:2051-2124 建名）→ F2；
	# 自绘穿插件（DeathPop/PoisonSplash/Telegraph 圈——enemy.gd:909/:952/:1036/:1135
	# pop 点）→ F3；其余（Enemy 本体 + Visual 精灵等）→ F1
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
	# 全树快照（无掩码自然态族活口——基线窗尾一次）
	var cnt := {}
	_walk_apply(tree.root, 0, cnt)
	return cnt


# ── 情景报告与门 ───────────────────────────────────────────────────

func _report_scenario(p_key: String, p_res: Dictionary, p_p1: Array, p_p2: Array,
		p_p3: Array) -> void:
	var baseline := int(p_res["baseline_dc"])
	print("══ [%s] 分族表：族 | 存活(P2中位) | 边际dc(P1) | 占比%% | 单独dc(P2) | P2−P1 | 逆序边际(P3) ══" % p_key)
	var p2_by_fam: Dictionary = {}
	for r in p_p2:
		p2_by_fam[int(r["fam"])] = r
	var p3_by_fam: Dictionary = {}
	for r in p_p3:
		p3_by_fam[int(r["fam"])] = r
	var sum_marg := 0
	for r in p_p1:
		var fam := int(r["fam"])
		var marg := int(r["marginal_dc"])
		sum_marg += marg
		var share := 0.0 if baseline == 0 else float(marg) / float(baseline) * 100.0
		var live := 0
		var indep := 0
		if p2_by_fam.has(fam):
			live = int(p2_by_fam[fam]["live"])
			indep = int(p2_by_fam[fam]["indep_dc"])
		var p3m := "—"
		if p3_by_fam.has(fam):
			p3m = str(int(p3_by_fam[fam]["marginal_dc"]))
		print("  %s | live=%d | 边际=%+d | %.1f%% | 单独=%d | P2−P1=%+d | P3逆序=%s" % [
			F_NAMES[fam - 1], live, marg, share, indep, indep - marg, p3m])
	var residual := int(p_res["residual_dc"])
	var closure := absi(baseline - sum_marg - residual)
	print("  闭环（FG3）：基线 %d − Σ边际 %d − 残差 %d = %+d（容差 ±%d，放宽 ±%d 须披露）" % [
		baseline, sum_marg, residual, baseline - sum_marg - residual, FG3_TOL,
		FG3_TOL_DISCLOSED])
	if closure <= FG3_TOL:
		_gate("FG3[%s] 望远镜闭环 ≤±%d" % [p_key, FG3_TOL], true, "closure=%d" % closure)
	elif closure <= FG3_TOL_DISCLOSED:
		_gate_disclosed("FG3[%s] 望远镜闭环 ≤±%d（churn 放宽档）" % [p_key, FG3_TOL_DISCLOSED],
			true, "closure=%d（>±%d——深载 spawn churn 中位读数噪声；掩码执行强度=逐物理步重放全程在岗）"
				% [closure, FG3_TOL])
	else:
		_gate("FG3[%s] 望远镜闭环 ≤±%d" % [p_key, FG3_TOL_DISCLOSED], false,
			"closure=%d（超放宽档——查掩码重放泄漏）" % closure)
	# S-B 校准门（弹N 落带内才算有效跑——设计 §1.2）
	if p_key == "SB":
		var proj := int(p_res["live"]["proj_live"])
		var enemy := int(p_res["live"]["enemy_live"])
		_gate("SB 校准门：弹N p50∈[%d,%d] 且 敌N p50∈[%d,%d]" % [SB_PROJ_BAND.x,
			SB_PROJ_BAND.y, SB_ENEMY_BAND.x, SB_ENEMY_BAND.y],
			proj >= SB_PROJ_BAND.x and proj <= SB_PROJ_BAND.y
				and enemy >= SB_ENEMY_BAND.x and enemy <= SB_ENEMY_BAND.y,
			"弹=%d 敌=%d（超带=构筑旋钮再调，调参史随报告披露）" % [proj, enemy])
	# FG4 fork 内容注入门（content v2）：SA 深载面敌弹必须 >0（硬门）且落披露带
	#（真机 vc34 深载带弹N=26@1:40 行量级；[8,60] 宽披露带，精调留 post-merge 全量）。
	# SAA/SB 不设硬门只留档——SAA 锚档读数供 vc35 锚对拍；SB 软帽 260 下敌弹与玩家
	# 弹竞争池位（acquire 超帽 null），敌弹读数可能被玩家弹挤近 0=产品真实行为
	var eproj := int(p_res["live"].get("eproj_live", 0))
	var spitter := int(p_res["live"].get("spitter_live", 0))
	if p_key == "SA":
		_gate("SA 敌弹注入生效：敌弹 p50>0（team=1，D4 洞补齐）", eproj > 0,
			"敌弹=%d 射手=%d" % [eproj, spitter])
		_gate_disclosed("SA 敌弹量级对拍：敌弹 p50∈[%d,%d]（真机 1:40 行 弹26 量级带）"
			% [EPROJ_BAND.x, EPROJ_BAND.y], eproj >= EPROJ_BAND.x and eproj <= EPROJ_BAND.y,
			"敌弹=%d 射手=%d（披露类：精调=post-merge 全量基线调参）" % [eproj, spitter])
	else:
		_gate_info("[%s] 敌弹读数留档：敌弹=%d 射手=%d（不设硬门，见上注）" % [p_key, eproj, spitter])
	# stage_probe 主源留档（S-B CPU 侧余桶归因）
	var stage: Dictionary = p_res["stage_p50_ms"]
	if not stage.is_empty():
		var keys: Array = stage.keys()
		keys.sort()
		var parts: Array[String] = []
		for k in keys:
			parts.append("%s=%.2f" % [k, float(stage[k])])
		print("  stage_probe p50 ms：%s" % " ".join(parts))


func _fg5_check() -> void:
	# FG5：SAA 锚档中阀门族边际 dc ≥ SA 真机档且方向符合（阀门关=不减薄）；锚段读数
	# 留档供 vc35 真机锚对拍。F6 粒子=硬门（实测信号面 24-29 dc）；F4 弹池=披露类门
	#（偏差披露：弹桶合批后 dc 面≈1-4，±0 比较低于中位读数噪声带——阀门 trim_free_to
	# 作用于池空闲栈容量非活弹 dc 面，实测两轮 SA 0/+4、SAA +2/−1 全在 ±5 内翻转）。
	# 分析清单与代码现实冲突处，以代码现实为准并在此记录——FG5 方向主证=F6+池活口对。
	if not (_results.has("SA") and _results.has("SAA")):
		return
	var sa_marg := _marg_by_fam(_results["SA"])
	var saa_marg := _marg_by_fam(_results["SAA"])
	var sa_v6 := int(sa_marg.get(6, 0))
	var saa_v6 := int(saa_marg.get(6, 0))
	_gate("FG5 锚档方向：F6 粒子 锚档边际(%d) ≥ SA 真机档(%d)" % [saa_v6, sa_v6],
		saa_v6 >= sa_v6,
		"差=%+d（阀门关=不减薄；SAA 粒子活口 64 vs SA 11 同向佐证）" % [saa_v6 - sa_v6])
	var sa_v4 := int(sa_marg.get(4, 0))
	var saa_v4 := int(saa_marg.get(4, 0))
	_gate_disclosed("FG5 锚档方向：F4 弹池 锚档边际(%d) vs SA(%d) 噪声带 ±%d" % [saa_v4, sa_v4,
		FG3_TOL], absi(saa_v4 - sa_v4) <= FG3_TOL,
		"差=%+d（披露类：弹桶 dc 面≈1-4 合批近零，方向无信号——阀门作用于空闲栈容量非活弹 dc 面，见 _fg5_check 头注偏差记录）"
			% [saa_v4 - sa_v4])
	_gate_info("FG5 锚段留档：SA fullload=1/tier=2 vs SAA fullload=0/tier=3（vc35 真机锚对拍基准）")


func _marg_by_fam(p_res: Dictionary) -> Dictionary:
	var out := {}
	for r in p_res.get("P1", []):
		out[int(r["fam"])] = int(r["marginal_dc"])
	return out


# ── KG 门（post-merge 刀效判定：v1 无刀参照档对标——内容稳定族 delta=纯刀效）──────

func _kg_adjudicate() -> void:
	var sa: Dictionary = _results.get("SA", {})
	var own_marg := _marg_by_fam(sa)
	var own_base := int(sa.get("baseline_dc", 0))
	var txt := FileAccess.get_file_as_string(V1_REF_JSON)
	var parsed: Variant = JSON.parse_string(txt) if not txt.is_empty() else null
	if not (parsed is Dictionary) or not (parsed as Dictionary).has("scenarios"):
		_gate_info("KG 门：v1 参照档缺失（%s）——刀效对标跳过（如实披露，不算 FAIL）"
			% V1_REF_JSON)
		return
	var v1_sa: Dictionary = (parsed as Dictionary)["scenarios"].get("SA", {})
	if v1_sa.is_empty() or not v1_sa.has("P1"):
		_gate_info("KG 门：v1 参照档无 SA P1——刀效对标跳过（披露）")
		return
	var v1_marg := _marg_by_fam(v1_sa)
	var v1_base := int(v1_sa.get("baseline_dc", 0))
	_kg = {"v1_ref": V1_REF_JSON, "v1_baseline_dc": v1_base, "v2_baseline_dc": own_base,
		"note": "对标限内容稳定族（F8/F9 刀目标内容未变；F1 刀效混淆走 K2c 否决臂；F3/F4/F13/F11 内容已变不入对标）"}
	# KG1（K1 跳字）：降幅 ≥60%（主控口径应落 ≤14 带）
	var f8_v1 := int(v1_marg.get(KG1_FAM, 0))
	var f8_v2 := int(own_marg.get(KG1_FAM, 0))
	var drop8 := f8_v1 - f8_v2
	var drop8_pct := 0.0 if f8_v1 <= 0 else float(drop8) / float(f8_v1) * 100.0
	_kg["kg1"] = {"v1": f8_v1, "v2": f8_v2, "drop": drop8,
		"drop_pct": snappedf(drop8_pct, 0.1)}
	_gate("KG1 F8 跳字：降幅 ≥60%%（v1 %d → 刀后 %d）" % [f8_v1, f8_v2],
		drop8_pct >= 60.0, "降幅=%.1f%%（差=%+d；主控预期带 ≤14）" % [drop8_pct, drop8])
	# K4（HUD）：降幅 ∈[25,45]（主控口径；刀面原预期 −15~−45）
	var f9_v1 := int(v1_marg.get(K4_FAM, 0))
	var f9_v2 := int(own_marg.get(K4_FAM, 0))
	var drop9 := f9_v1 - f9_v2
	_kg["k4"] = {"v1": f9_v1, "v2": f9_v2, "drop": drop9}
	_gate("K4 F9 HUD：降幅 ∈[25,45]（v1 %d → 刀后 %d）" % [f9_v1, f9_v2],
		drop9 >= 25 and drop9 <= 45, "差=%+d" % drop9)
	# KG2：内容稳定非目标族漂移 ≤±5（占比 ≥8% 硬门，余 INFO——误伤面）
	var kg2_rows: Array = []
	for fam_v in KG2_STABLE_FAMS:
		var fam := int(fam_v)
		var v1v := int(v1_marg.get(fam, 0))
		var v2v := int(own_marg.get(fam, 0))
		var drift := v2v - v1v
		var sh_v1 := 0.0 if v1_base <= 0 else float(v1v) / float(v1_base) * 100.0
		var sh_v2 := 0.0 if own_base <= 0 else float(v2v) / float(own_base) * 100.0
		kg2_rows.append({"fam": fam, "v1": v1v, "v2": v2v, "drift": drift,
			"share_v1": snappedf(sh_v1, 0.1), "share_v2": snappedf(sh_v2, 0.1)})
		if sh_v1 >= FG2_SHARE_FLOOR or sh_v2 >= FG2_SHARE_FLOOR:
			_gate("KG2 F%d %s：非目标漂移 ≤±5" % [fam, F_NAMES[fam - 1]],
				absi(drift) <= 5, "漂移=%+d（v1 %d→v2 %d；占比 %.1f%%→%.1f%%）"
					% [drift, v1v, v2v, sh_v1, sh_v2])
		else:
			_gate_info("KG2 F%d %s：漂移=%+d（占比 %.1f%%/%.1f%% 均 <8%%——INFO 不硬门）"
				% [fam, F_NAMES[fam - 1], drift, sh_v1, sh_v2])
	_kg["kg2"] = kg2_rows


# ── FG4 走向裁定（设计 §1.6 机械执行）─────────────────────────────

func _fg4_adjudicate() -> void:
	var baseline := int(_results.get("SA", {}).get("baseline_dc", 0))
	var verdict := ""
	if baseline >= 500:
		verdict = "主线：渲染器合批差异/敌子件/特效堆叠嫌疑在 PC 复现，缺口可归因——按谱定刀"
	else:
		verdict = "fork：缺口不在渲染器在内容差（敌方弹/棱镜/真实构筑）——夹具升级一浪后重扫，刀序顺延"
	_fg4 = {"sa_baseline_dc": baseline, "threshold": 500, "verdict": verdict}
	_gate_info("FG4 裁定：SA 基线 dc=%d %s 500 → %s" % [baseline,
		">=" if baseline >= 500 else "<", verdict])
	# post-merge FG4 重裁定：v2 内容+刀后 S-A dc 对真机深载带的剩余缺口账（写实不猜：
	# 两桶构成 PC 侧不可分离，量化移交 vc35 真机读法 VG1/VG3 锚段对拍）
	var gap_lo := maxi(700 - baseline, 0)
	var gap_hi := maxi(990 - baseline, 0)
	_fg4["real_band"] = [700, 990]
	_fg4["gap_account"] = "夹具 v2（敌方弹/棱镜/词缀内容注入+K1/K4/K2c 刀后）SA dc=%d vs 真机 vc34 深载带 700-990 → 剩余缺口 %d~%d dc。构成两桶（写实不拆分）：①内容差残余=夹具仍未复刻的真机构成面（真实构筑未知项/波次过渡态/地图词缀/未入场敌种构成）；②平台面=PC 4070 与手机 GPU/驱动差异（FG4 v1 裁定已消灭『渲染器合批差异』主嫌疑线，此残面为 GPU 侧填充/带宽类，PC 不可量化）。" % [baseline, gap_lo, gap_hi]
	_gate_info("FG4 缺口账：%s" % _fg4["gap_account"])
	# 刀序建议（按谱机械裁定：边际 dc ×(族占比≥8%) 过筛 → 降序；刀↔族映射见设计 §2）
	var marg := _marg_by_fam(_results.get("SA", {}))
	var shares := _shares_of(_results.get("SA", {}))
	var rows: Array = []
	for fam in range(1, F_COUNT + 1):
		var m := int(marg.get(fam, 0))
		var sh := float(shares.get(fam, 0.0))
		if sh >= 8.0 and m > 0:
			rows.append({"fam": fam, "marginal": m, "share": sh})
	rows.sort_custom(func(a, b): return int(a["marginal"]) > int(b["marginal"]))
	var blade_map := {
		8: "K1跳字根alpha量化", 2: "K2甲板分桶", 3: "K2穿插件并发帽(sprite化待谱)",
		6: "K3粒子活口帽", 9: "K4HUD配色量化", 7: "K5电链sprite化",
		4: "K3同向(SB段复核)", 12: "K5部分(laser)/无候选",
		13: "敌弹族F13(无候选刀→backlog)",   # content v2 扩族——R230 候选池无敌弹刀
	}
	_blade_order = []
	var line: Array[String] = []
	for r in rows:
		var fam := int(r["fam"])
		var blade := String(blade_map.get(fam, "无候选刀(进backlog)"))
		_blade_order.append({"fam": fam, "fam_name": F_NAMES[fam - 1],
			"marginal_dc": int(r["marginal"]), "share_pct": snappedf(float(r["share"]), 0.1),
			"blade": blade})
		line.append("%s(F%d 边际%+d/%.1f%%)" % [blade, fam, int(r["marginal"]), float(r["share"])])
	_gate_info("刀序建议（谱降序，≤4 把、文件集互斥由主控裁定）：%s" % " ".join(line))


func _shares_of(p_res: Dictionary) -> Dictionary:
	var baseline := int(p_res.get("baseline_dc", 0))
	var out := {}
	if baseline <= 0:
		return out
	for r in p_res.get("P1", []):
		out[int(r["fam"])] = float(int(r["marginal_dc"])) / float(baseline) * 100.0
	return out


# ── FG2 跨进程复现（读 prev1/prev2 轮转档 + 本跑，≥3 源才判门）───────

func _fg2_cross_run() -> void:
	# 三源=本跑 + 磁盘当前档（=上一跑——本函数在 _store_baseline 轮转之前执行，
	# prev 链此时只有上上跑以远的档案）+ prev1（=上上跑）
	var sources: Array = []
	var own := _share_profile(_results.get("SA", {}), "run")
	if not own.is_empty():
		sources.append(own)
	for pair in [["lastrun", BASELINE_JSON], ["prev1", BASELINE_JSON.get_base_dir()
			+ "/qa_r230_dcscan_baseline_prev1.json"]]:
		var txt := FileAccess.get_file_as_string(pair[1])
		if txt.is_empty():
			continue
		var parsed: Variant = JSON.parse_string(txt)
		if parsed is Dictionary and (parsed as Dictionary).has("scenarios"):
			# content_version 跨版本防护（content v2）：旧档缺字段=version 1——异版
			# 档不入复现源（防跨版本静默混比：v1 无敌弹/棱镜内容，谱不可比）
			var pver := int((parsed as Dictionary).get("meta", {}).get("content_version", 1))
			if pver != CONTENT_VERSION:
				_gate_info("FG2 跨版本防护：档 %s content_version=%d ≠ %d——不入复现源"
					% [pair[0], pver, CONTENT_VERSION])
				continue
			var prof := _share_profile((parsed as Dictionary)["scenarios"].get("SA", {}),
				String(pair[0]))
			if not prof.is_empty():
				sources.append(prof)
	_fg2 = {"sources": sources.size(), "profiles": sources}
	if sources.size() < 3:
		_gate_info("FG2 复现：独立进程源 %d/3（本次不判门——第 3 跑起判）" % sources.size())
		return
	# 两两相对差（主控重锚 post-merge）：占比 ≥8% 族（任一源）并集，|a−b|/mean ≤±30%
	var fails: Array[String] = []
	var detail: Array[String] = []
	for i in range(sources.size()):
		for j in range(i + 1, sources.size()):
			var a: Dictionary = sources[i]
			var b: Dictionary = sources[j]
			var fams: Array = (a["share_by_fam"] as Dictionary).keys()
			for f in (b["share_by_fam"] as Dictionary).keys():
				if not fams.has(f):
					fams.append(f)
			for f in fams:
				var va := float((a["share_by_fam"] as Dictionary).get(f, 0.0))
				var vb := float((b["share_by_fam"] as Dictionary).get(f, 0.0))
				var mean := (va + vb) * 0.5
				if mean <= 0.5:
					continue                        # 双方都近零的族不判（占比噪声地板）
				var rel := absf(va - vb) / mean * 100.0
				var in_scope: bool = va >= FG2_SHARE_FLOOR or vb >= FG2_SHARE_FLOOR
				if in_scope and rel > float(FG2_TOL_PCT):
					fails.append("%s×%s F%d %.1f/%.1f(散布%.0f%%)" % [a["tag"], b["tag"],
						f, va, vb, rel])
				elif in_scope:
					detail.append("%s×%s F%d %.0f%%" % [a["tag"], b["tag"], f, rel])
	_fg2["pair_fails"] = fails
	var ok := fails.is_empty()
	if ok:
		_gate("FG2 复现门：占比≥8%% 族两两相对差 ≤±%d%%（v2 档 %d 源）"
			% [FG2_TOL_PCT, sources.size()], true,
			"超差族无（明细 %s）" % " ".join(detail))
	else:
		_gate("FG2 复现门：占比≥8%% 族两两相对差 ≤±%d%%（v2 档 %d 源）"
			% [FG2_TOL_PCT, sources.size()], false,
			"超差族：%s" % " ".join(fails))


func _share_profile(p_sa: Dictionary, p_tag: String) -> Dictionary:
	if p_sa.is_empty() or not p_sa.has("P1"):
		return {}
	var baseline := int(p_sa.get("baseline_dc", 0))
	if baseline <= 0:
		return {}
	var shares := _shares_of(p_sa)
	var rows: Array = []
	for fam in shares:
		rows.append({"fam": fam, "share": float(shares[fam])})
	rows.sort_custom(func(a, b): return float(a["share"]) > float(b["share"]))
	var top5: Array = []
	var top5_sum := 0.0
	for i in range(mini(5, rows.size())):
		top5.append(rows[i]["fam"])
		top5_sum += float(rows[i]["share"])
	return {"tag": p_tag, "baseline_dc": baseline,
		"share_by_fam": shares, "top5": top5,
		"top5_sum_pct": snappedf(top5_sum, 0.1)}


# ── 基线 JSON 落盘（R224 轮转先例：写前 prev1←当前、prev2←prev1、prev3←prev2）──

func _store_baseline() -> void:
	_rotate_baseline()
	var root: Dictionary = {
		"meta": {
			"date": "2026-10-04",
			# ★ content_version（content v2）：FG4 fork 内容注入升级——FG2 复现源逐档
			#   核对版本，旧档（缺字段=1）拒入防跨版本静默混比
			"content_version": CONTENT_VERSION,
			"content_notes": "FG4 fork v2 内容注入：敌方远程弹（E7_spitter×%d 射手切片+精英 affix_ring+弹池注入补出生管线缺环——R224 QA D4 洞）+ 棱镜（W5_prism L%d+MEC_MIRROR_SPLIT×%d=镜5）；分类器 12→13 族（F13 敌弹=team1）"
				% [SPITTER_COUNT, PRISM_LEVEL, PRISM_SPLIT],
			"package": "pc-window-gl-compatibility-fixture（校准对象=真机 vc34 深载带 dc700-990）",
			"map": "world_grove w16（敌血 ×0.3 定标复本）",
			"build": "W2_gatling L5 + PIERCE×3/MULTI×2/BOUNCE×3/NOVA×2/FRACTAL×2 + W5_prism L%d 镜5（SB 追加 MULTI×%d；content v2 构筑面）"
				% [PRISM_LEVEL, SB_EXTRA_MULTI],
			"governor": "frozen, mode=frame_priority, tier_override=2（SAA=3）",
			"sentinels": "fullload=1 bitmap=1 runstart_bake=1 settle=-3 burst_thin=-3 pool_valve=-3 deathpop_cap=-3（SAA：fullload=0/tier3/-2/-2/帽-2）；fx_quality=1/damage_numbers_on=1/fx_opacity=1.0 内存注入；chromatic 逐帧 RS 隐藏；persist_defer 挂起；APPDATA 沙箱",
			"blades": "post-merge 三浪合并全开：K1 跳字 alpha 4 档量化（damage_popup.gd，产品级恒开）/K4 HUD Label 语义角色量化色板（theme.gd，产品级恒开）/K2c 死亡演出并发帽 DEATHPOP_FX_CAP=10（enemy.gd，夹具哨兵 -3 模拟档=真机 tier2 帽开形态；SAA=-2 锚档阀全关；桌面 auto 恒关）",
			"rendering": _rendering_method_str(),
			"user_dir_sandbox": OS.get_user_data_dir(),
			"protocol": "基线 60 帧/族 弃3+settle10+采样30 取中位/P1 F1→F13/P2 单独可见/P3 逆序（仅SA）/逐帧族掩码重放（RS 层，节点 visible 零触碰）",
			"decision_quantities": "族占比与刀后相对降幅（白名单）；绝对 dc 仅夹具内部一致性，不与真机互比",
			"seed": 20261004,
		},
		"fg0": _fg0,
		"fg2": _fg2,
		"fg4": _fg4,
		"kg": _kg,
		"blade_order": _blade_order,
		"scenarios": _results,
		"gates": _gate_results,
	}
	var f := FileAccess.open(BASELINE_JSON, FileAccess.WRITE)
	if f == null:
		_gate("FG1 基线 JSON 落盘", false, "打开失败：%s" % BASELINE_JSON)
		return
	f.store_string(JSON.stringify(root, "\t"))
	f.close()
	_gate("FG1 基线 JSON 落盘（含 3 情景×%d 族×P1/P2/P3，content_version=%d）" % [F_COUNT, CONTENT_VERSION], true, BASELINE_JSON)


func _rotate_baseline() -> void:
	var dir := BASELINE_JSON.get_base_dir() + "/"
	var chain: Array[String] = [
		dir + "qa_r230_dcscan_baseline_prev1.json",
		dir + "qa_r230_dcscan_baseline_prev2.json",
		dir + "qa_r230_dcscan_baseline_prev3.json",
	]
	for i in range(chain.size() - 1, 0, -1):
		var src_text := FileAccess.get_file_as_string(chain[i - 1])
		if src_text.is_empty():
			continue
		var fw := FileAccess.open(chain[i], FileAccess.WRITE)
		if fw != null:
			fw.store_string(src_text)
			fw.close()
	if not FileAccess.file_exists(BASELINE_JSON):
		return
	var cur_text := FileAccess.get_file_as_string(BASELINE_JSON)
	if cur_text.is_empty():
		return
	var f1 := FileAccess.open(chain[0], FileAccess.WRITE)
	if f1 != null:
		f1.store_string(cur_text)
		f1.close()


# ── 清场/收尾（r224 同构）──────────────────────────────────────────

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
	# 沙箱自检失败路径（boot 未跑）：仅还原本进程可还原的 static 口
	GameFeelDirector.burst_thin_override = -1
	GameLoop.pool_valve_override = -1
	Enemy.deathpop_cap_override = -1


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
	if _gl != null and _sb_proj_soft_orig > 0:
		var pp := _gl.pools[&"projectile"] as ProjectilePool
		if pp != null:
			pp.soft_limit = _sb_proj_soft_orig
	if _gl != null:
		_gl.queue_free()
		await tree.process_frame
		await tree.process_frame
	# 注：Meta._settings 内存注入不还原（进程即弃——零落盘零残留，复审节口径）


# ── 门/统计工具 ────────────────────────────────────────────────────

func _rendering_method_str() -> String:
	# CLI --rendering-method 旗标不落 ProjectSettings——扫命令行，缺省回退工程设置
	var rmethod := str(ProjectSettings.get_setting_with_override(
		&"rendering/renderer/rendering_method"))
	var args := OS.get_cmdline_args()
	for i in range(args.size() - 1):
		if String(args[i]) == "--rendering-method":
			rmethod = String(args[i + 1])
	return rmethod


func _gate(p_label: String, p_ok: bool, p_detail: String) -> void:
	if p_ok:
		print("  PASS | %s（%s）" % [p_label, p_detail])
	else:
		print("  FAIL | %s（%s）" % [p_label, p_detail])
		_fails += 1
	_gate_results[p_label] = {"ok": p_ok, "detail": p_detail}


func _gate_disclosed(p_label: String, p_ok: bool, p_detail: String) -> void:
	# 披露类门：如实记 FAIL* 但不阻塞退出码（放宽理由已随行披露，不冒充通过）
	if p_ok:
		print("  PASS | %s（%s）" % [p_label, p_detail])
	else:
		print("  FAIL* | %s（%s）——披露类失配，不阻塞（详见用例体头注）" % [p_label, p_detail])
	_gate_results[p_label] = {"ok": p_ok, "detail": p_detail, "disclosed": true}


func _gate_info(p_line: String) -> void:
	print("  INFO | %s" % p_line)


func _median_i(p_arr: Array) -> int:
	if p_arr.is_empty():
		return 0
	var s := p_arr.duplicate()
	s.sort()
	return int(s[s.size() / 2])


func _median_i_arr(p_arr: Array[int]) -> int:
	if p_arr.is_empty():
		return 0
	var s := p_arr.duplicate()
	s.sort()
	return s[s.size() / 2]


func _median_f(p_arr: Array[float]) -> float:
	if p_arr.is_empty():
		return 0.0
	var s := p_arr.duplicate()
	s.sort()
	return s[s.size() / 2]
