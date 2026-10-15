# autoload/perf_governor.gd —— 注册名 PerfGovernor（不声明 class_name，§0.1-3 纪律同款）
# R220 模式地基（方案 2026-10-02-R219「优先模式」/拆解契约 §2.1 API 冻结）：
# 「优先模式」两档的全局性能调速器——档位 tier 3高/2中/1低，按 EMA 帧率与模式阈值升降：
# · 帧率优先（perf_mode=0，默认）：EMA < target×0.90 持续 2s 降档（地板 1）、
#   EMA > target×0.95 持续 5s 升档（帽 3）——刀12 弹生成配额/刀13 数值面/刀14 镜预算的
#   生效模式（消费点归火段包按 frame_priority() 分支接线）。
# · 特效优先（perf_mode=1）：EMA < target×0.70 降（地板 2）、> target×0.85 升——保画面的
#   宽松档（降档更迟、地板更高）。
# 采样：每 SAMPLE_S=0.5s 采 Engine.get_frames_per_second() 入 EMA（EMA_ALPHA=0.25，首采
# 直接赋值）；PROCESS_MODE_ALWAYS——暂停/选卡期 _process 照跑（模式观测/节拍累计不停），
# 但 R223 Fix Q 起**非战斗采样整段跳过**（EMA 只收战斗帧率）：vc29 实锤 0:15 降档后
# 0:21 选卡窗 fps120 混入 EMA → 6s 有效性校验假「有效」→ 地板后无新降档可重臂校验
# → tier1 钉死 66 分钟；且长选卡/暂停后污染 EMA 还会开出假升档窗（恢复通道同根病）。
# 转换计时与 R221 Fix B 校验计时本就只在「GameLoop.state==PLAYING ∧ ¬tree.paused」内
# 累计（选卡/暂停期挂起：计时冻结不清零、不清 EMA——主控决策#2）。target = min(fps_cap, 120, 屏幕刷新率)，fps_cap=0（不限）
# 取 120；刷新率不可知（headless/查询失败）不参与钳制（R220 修轮帽语义——上限≠目标）。
# 立即生效：消费端每读 frame_priority()/fx_quality_cap() 直查设置/档——零推送零滞后；
# 模式切换（perf_mode 写口或 mode_override 变化）→ 双侧转换计时清零重累计、tier/EMA
# 保持（防切换瞬间假触发——契约 §2.1 行为5；检测在 _process 模式观测口，单源）。
# 本轮应用面仅 Enemy._fx_q 档帽合成（契约 A5）；其余消费点归弹段/火段包接线。
extends Node

# ── 冻结常量（契约 §2.1 主控照抄） ──────────────────────────────────
const FRAME_DROP_RATIO := 0.90                # 帧率优先：降档阈值（EMA < target×0.90）
const FRAME_RECOVER_RATIO := 0.95             # 帧率优先：升档阈值（EMA > target×0.95）
const FX_DROP_RATIO := 0.70                   # 特效优先：降档阈值（EMA < target×0.70）
const FX_RECOVER_RATIO := 0.85                # 特效优先：升档阈值（EMA > target×0.85）
const DROP_SUSTAIN_S := 2.0                   # 降档持续门槛（秒）
const RECOVER_SUSTAIN_S := 5.0                # 升档持续门槛（秒）
const FX_FLOOR_TIER := 2                      # 特效优先降档地板（帧率优先地板 1）
const EMA_ALPHA := 0.25                       # EMA 平滑系数
const SAMPLE_S := 0.5                         # 采样节拍（秒）
const EFFECT_CHECK_S := 6.0                   # R221 Fix B：降档后有效性校验窗（秒）
const EFFECT_MIN_GAIN := 0.05                 # R221 Fix B：窗末 EMA 改善 <5% = 降档无效

# ── 冻结静态读口/注入口（契约 §2.1；消费方 enemy.gd / player.gd /
#    ballistic_weapon.gd / homing_weapon.gd / trait_effect_bounce.gd /
#    mirror_weapon.gd——按契约 §1 各包接线） ─────────────────────────
static var tier: int = 3                      # 3高/2中/1低，默认 3（真值档位——仅真采样驱动档变改写）
static var tier_override: int = -1            # 测试注入 1..3；-1=真值（注入时不跑转换、不计数）
static var mode_override: int = -1            # 测试注入 0/1；-1=真值
static var transitions: int = 0               # 档变计数（含 _ema_inject 伪采样驱动的档变；
                                              # tier_override 直驱的档变不计数——契约行为6）

# ── R269 A 轨：保帧模式（perf_boost）读口/注入口（设计 §3.1） ─────────
# 用户可见、可关的显式降载模式（mobile 垫值默认开、桌面默认关）——与 tier 自动调速器
# 的关系=手动钉地板不参与自动降档：boost 不改 tier 真值、不进 EMA/转换判定；两系统
# 共享面（fx_quality_cap/_deathpop_cap_on）均为「boost 只会更省」单向阀（§3.1 定案）。
static var boost_override: int = -1           # R269：测试注入口（mode_override 同款先例）：
                                              # -1=真值 / 0=强关 / 1=强开


static func boost_mode() -> bool:
	# R269：保帧模式读口。读序：boost_override(0/1) > Meta.settings("perf_boost")（缺省 0）。
	# 每读直查零订阅（frame_priority 同款契约）——设置行写口后下一读即翻转。
	if boost_override == 0:
		return false
	if boost_override == 1:
		return true
	var raw: Variant = Meta.settings("perf_boost")
	var v: int = 0 if raw == null else clampi(int(raw), 0, 1)
	return v == 1


static func strategic_boost_active() -> bool:
	# 策略级降载特性统一生效门，直接锚定既有 boost_mode()
	return boost_mode()


static func boost_res_notch() -> int:
	# R269：分辨率档读口（85/75——仅 boost_mode() 为真时被消费；boost 关时值无意义但
	# 保持档值不回写，重开沿用 §3.1 写口关系）。脏值归 85（_normalized_setting 同口径）。
	var raw: Variant = Meta.settings("boost_res")
	var v: int = 85 if raw == null else clampi(int(raw), 75, 85)
	return 75 if v == 75 else 85


static func boost_diag_state() -> int:
	# R269：促%d 单源纯函数（0=关/1=开85%/2=开75%——诊断行状态键与设置行文案同源，
	# 防显示态与 促%d 不一致；「模式没生效」类报障预防，R230 帽N 零激活盲区教训）
	if not boost_mode():
		return 0
	return 2 if boost_res_notch() == 75 else 1


static func frame_priority() -> bool:
	# true=帧率优先。读序：mode_override(0/1) > Meta.settings("perf_mode")（缺省 0）。
	# 每读直查——设置行写口（set_setting）后下一读即翻转，零订阅零滞后。
	if mode_override == 0:
		return true
	if mode_override == 1:
		return false
	var raw: Variant = Meta.settings("perf_mode")
	var v: int = 0 if raw == null else clampi(int(raw), 0, 1)
	return v == 0


static func effective_tier() -> int:
	# 档读口：tier_override 注入时 tier 直接取注入值（不跑转换——契约行为6）；否则真值 tier。
	# diag 行「调」读数（弹段包 B2）等展示面用本口，勿裸读 tier（注入态会看到旧真值）。
	if tier_override >= 1:
		return clampi(tier_override, 1, 3)
	return tier


static func fx_quality_cap() -> int:
	# tier→fx_quality 帽：3→2 / 2→1 / 1→0。生效门（契约 §2.1，顺序冻结）：
	# ① tier_override∈[1,3] → 按注入值映射（测试直驱，无视平台）；
	# ② R269：boost_mode() → 0（保帧模式钉 0 档——用户显式开关非调速器耦合；插在
	#    tier_override 注入之后=注入优先序保测试通道，压过一切 tier 映射的单向阀）；
	# ③ 否则 OS.has_feature("mobile") → 按 tier 映射（R203 mobile 门同款平台门先例）；
	# ④ 非 mobile 且无注入 → 恒 2（零扰动桌面/headless 既有口径——r202_g3/fx_quality
	#   旧断言在默认 tier=3 下逐位不变；契约 §8 #12 承重墙，A 包不得省略）
	if tier_override >= 1:
		return clampi(tier_override, 1, 3) - 1
	if boost_mode():
		return 0                              # R269：保帧模式钉 0 档（用户显式开关，非调速器耦合）
	if OS.has_feature("mobile"):
		return clampi(tier, 1, 3) - 1
	return 2


# 可测性注入口（契约 §2.1 补充，不进产品读口）
static var _ema_inject: float = -1.0          # <0=真值 EMA；测试注入伪 EMA 驱动转换序

# ── 运行期状态（实例侧；测试经 _test_reset 复位 / 直驱 _process 确定性步进） ──
var _ema: float = -1.0                        # EMA（<0=未初始化，首采直接赋值）
var _sample_acc: float = 0.0                  # 采样节拍累计（SAMPLE_S 结清）
var _drop_acc: float = 0.0                    # 降档持续计时（独立于升档侧；条件翻转即清零）
var _recover_acc: float = 0.0                 # 升档持续计时（独立于降档侧；条件翻转即清零）
var _last_mode: int = -1                      # 上次观测模式（0/1；变化→双侧计时清零，tier/EMA 保持）
var _gl_ref: WeakRef = null                   # GameLoop 弱引用缓存（照 DebugStats._diag_find_game_loop 先例）
var _drop_ema: float = -1.0                   # R221 Fix B：最近降档时刻 EMA 快照（<0=无待校验降档）
var _drop_hold: float = 0.0                   # R221 Fix B：降档后战斗态累计时长（秒）
var _drop_frozen: bool = false                # R221 Fix B：降档无效冻结（本局不再降档；模式切换清）


func _ready() -> void:
	# 暂停/选卡期采样不停（PROCESS_MODE_ALWAYS——契约行为1/3；转换计时另受战斗态门）
	process_mode = Node.PROCESS_MODE_ALWAYS


func notify_new_run() -> void:
	# R222 Fix G（vc28 日志 ❌：调1 变2 全程钉死——上一局 tier1 跨局带入，本局地板
	# 无降可发 ⇒ Fix B 有效性反馈无触发面，自然升档深载不可达 ⇒ 会话级永久最低特效）：
	# **新局重臂 tier=3**——GameLoop 三新局入口（start_run / restart_run / continue_run）
	# change_state 成功后直调（正信号）；continue_endless 同局延续/暂停恢复/选卡收口
	# **不**调（评审修轮：状态观测闩（GAME_OVER/MENU 置位）在暂停重开漏臂、无尽继续
	# 误臂两处语义不符——闩方案已拆）。重臂后深载新局自动重走 2s×2 降档+6s 有效性
	# 校验（vc27/vc28 型钉死在 Fix B 局内反馈下自愈：无效→回升+冻结）。
	# transitions 不计（非真采样档变）；EMA/_last_mode 保持（契约：只动 tier/冻结/计时）。
	tier = 3
	_drop_frozen = false
	_drop_ema = -1.0
	_drop_hold = 0.0
	_drop_acc = 0.0
	_recover_acc = 0.0


func _process(delta: float) -> void:
	# 模式切换检测（perf_mode 写口或 mode_override 变化——轮询单源，覆盖两通道；测试
	# 直驱 _process 亦走本路径）：双侧转换计时清零重累计、tier/EMA 保持（契约行为5）
	var mode_now := 0 if frame_priority() else 1
	if _last_mode < 0:
		_last_mode = mode_now
	elif mode_now != _last_mode:
		_last_mode = mode_now
		_drop_acc = 0.0
		_recover_acc = 0.0
		# R221 Fix B：模式切换=新阈值体系——降档冻结/校验窗一并清零重计
		_drop_ema = -1.0
		_drop_hold = 0.0
		_drop_frozen = false
	# 采样节拍常走（暂停/选卡期不停——挂起的只是转换计时）
	_sample_acc += delta
	while _sample_acc >= SAMPLE_S:
		_sample_acc -= SAMPLE_S
		_sample_tick()


func _sample_tick() -> void:
	# 单次采样：EMA 更新 +（战斗态 ∧ ¬paused ∧ 无 tier_override 注入时）转换判定。
	# R223 Fix Q：战斗门提前到 EMA 更新之前——非战斗采样（选卡/暂停/菜单）整段跳过，
	# EMA=纯战斗帧率（vc29 ❌：选卡窗 fps120 污染校验窗/假升档窗，见文件头注）。
	if not _in_battle():
		return
	var sample := _ema_inject if _ema_inject >= 0.0 else float(Engine.get_frames_per_second())
	if _ema < 0.0:
		_ema = sample                           # EMA 未初始化：首采直接赋值
	else:
		_ema = _ema * (1.0 - EMA_ALPHA) + sample * EMA_ALPHA
	if tier_override >= 1:
		return                                  # tier_override 直驱：不跑转换（契约行为6）
	var target := _target_fps()
	var fx_mode := not frame_priority()         # 特效优先
	var drop_ratio := FX_DROP_RATIO if fx_mode else FRAME_DROP_RATIO
	var recover_ratio := FX_RECOVER_RATIO if fx_mode else FRAME_RECOVER_RATIO
	var floor_tier := FX_FLOOR_TIER if fx_mode else 1
	# 双侧独立持续判定：条件翻转即清零该侧计时（契约行为4）
	if _ema < float(target) * drop_ratio:
		_drop_acc += SAMPLE_S
	else:
		_drop_acc = 0.0
	if _ema > float(target) * recover_ratio:
		_recover_acc += SAMPLE_S
	else:
		_recover_acc = 0.0
	# R221 Fix B：待校验降档的计时推进（战斗态采样内——与转换计时同门）
	if _drop_ema >= 0.0:
		_drop_hold += SAMPLE_S
	# 档变（真采样驱动）：transitions+=1 并即时生效——fx_quality_cap() 即时读档无需推送
	if _drop_acc >= DROP_SUSTAIN_S and tier > floor_tier and not _drop_frozen:
		tier -= 1
		transitions += 1
		_drop_acc = 0.0                         # 同侧再降需重新累计满 2s
		_recover_acc = 0.0
		# R221 Fix B：降档快照重臂校验窗（连续再降以最近一次降档为校验基准）
		_drop_ema = _ema
		_drop_hold = 0.0
	elif _recover_acc >= RECOVER_SUSTAIN_S and tier < 3:
		tier += 1
		transitions += 1
		_recover_acc = 0.0
		_drop_acc = 0.0
		_drop_ema = -1.0                        # 自然升档已还档——校验窗作废
		_drop_hold = 0.0
	elif _drop_ema >= 0.0 and _drop_hold >= EFFECT_CHECK_S:
		# R221 Fix B：有效性反馈（vc27 回归 #2——降档对模拟成本型卡顿无效仍钉死
		# tier1 整局）：降档 EFFECT_CHECK_S 后 EMA 改善 < EFFECT_MIN_GAIN 判无效
		# → 回升一档 + _drop_frozen 冻结本局后续降档（升档通道保持——真好转仍可升）。
		# 改善达标 → 窗关闭，特效档保持（降档正在起作用，下次恶化重走 2s 降档）。
		var gain := 1.0
		if _drop_ema > 0.0:
			gain = (_ema - _drop_ema) / _drop_ema
		_drop_ema = -1.0
		_drop_hold = 0.0
		if gain < EFFECT_MIN_GAIN and tier < 3:
			tier += 1
			transitions += 1
			_recover_acc = 0.0
			_drop_frozen = true


func _battle_gl() -> Node:
	# GameLoop 解析（R222 Fix G 抽出——_process 局间闩与 _in_battle 共用）
	var gl: Node = null
	if _gl_ref != null:
		gl = _gl_ref.get_ref() as Node
	if gl == null or not is_instance_valid(gl):
		gl = _find_game_loop()
		if gl == null:
			return null
		_gl_ref = weakref(gl)
	return gl


func _in_battle() -> bool:
	# 战斗态判定：GameLoop 在树 ∧ state==PLAYING ∧ ¬tree.paused（契约行为3）。
	# PROCESS_MODE_ALWAYS 下本函数在暂停期照跑——paused 检查即挂起口。
	var tree := get_tree()
	if tree == null or tree.paused:
		return false
	var gl := _battle_gl()
	return gl != null and int(gl.get("state")) == GameConst.GameStatus.PLAYING


func _find_game_loop() -> Node:
	# GameLoop 非 autoload（main.tscn 根「Main」；测试套件另起实例名）——照
	# DebugStats._diag_find_game_loop() 先例：root "Main" 短路 + has_method("diag_counts")
	# 特征扫描，找不到返回 null（非战斗态挂起口径）
	var tree := get_tree()
	if tree == null or tree.get_root() == null:
		return null
	var gl := tree.get_root().get_node_or_null("Main")
	if gl != null and gl.has_method("diag_counts"):
		return gl
	for child in tree.get_root().get_children():
		if child != self and child.has_method("diag_counts"):
			return child
	return null


static func _target_fps() -> int:
	# target = min(fps_cap, 120, 屏幕刷新率)；fps_cap=0（不限）取 120（契约行为2——
	# clampi(0,1,120) 会得 1，故 0/负值显式归 120 再钳帽）。
	# R220 修轮（评审产品）：「帧率上限」是帽不是保底目标——vsync/面板刷新率决定可达
	# 帧率。60Hz 面板 + cap120/不限 时 EMA≈60 < 0.90×120 恒降档钉死 tier1 且
	# 0.95×120 永不可达=永不升档（稳态=特效最差+帧率依旧上不去）。target 与屏幕刷新率
	# 取小修正帽语义；刷新率不可知（headless/查询失败 → -1/0）不钳，保持旧口径。
	var raw: Variant = Meta.settings("fps_cap")
	var v: int = 120 if raw == null else int(raw)
	if v <= 0:
		v = 120
	v = mini(v, 120)
	var refresh := _screen_refresh_cap()
	if refresh > 0:
		v = mini(v, refresh)
	return v


static var _refresh_cap_cache: int = -2      # -2=未查询（首查缓存）/ -1=不可知（不钳）

static func _screen_refresh_cap() -> int:
	# 屏幕刷新率帽（静态缓存一次——会话内显示器不热插拔的工程假设；窗口跨屏移动的
	# 边缘场景接受首屏值）。headless 返回 -1（本会话探针实证）→ 不参与钳制。
	if _refresh_cap_cache == -2:
		var rr := DisplayServer.screen_get_refresh_rate()
		_refresh_cap_cache = int(rr) if rr > 0.0 else -1
	return _refresh_cap_cache


func _test_reset() -> void:
	# 测试隔离口（不进产品读口）：只复位实例侧（EMA/节拍/双侧计时/模式观测/GL 缓存）——
	# EMA 清空使下一采直接赋值（注入值即刻生效）。静态面（tier/transitions 与注入口
	# tier_override/mode_override/_ema_inject）由用例显式管理（冻结 API，勿在此暗改）
	_ema = -1.0
	_sample_acc = 0.0
	_drop_acc = 0.0
	_recover_acc = 0.0
	_last_mode = -1
	_gl_ref = null
	_drop_ema = -1.0
	_drop_hold = 0.0
	_drop_frozen = false
