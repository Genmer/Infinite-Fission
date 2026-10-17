# autoload/debug_stats.gd —— 注册名 DebugStats（不声明 class_name，§0.1-3）
# 验收测量面板（架构 §5.5；release 构建剥离，§1.3-7 口径：dev 断言开关关闭）
# 采集口径：帧时间 P50/P95/P99（60s 环形缓冲）、帧序阶段分解（§5.4 ①~⑩ 预算对账）、
# 池命中率/丢弃数（ObjectPool.stats() 聚合）、事件派发计数（EventBus 拉取）、结算计数。
extends Node

const FRAME_BUFFER_CAPACITY := 7200          # 60s @ 120Hz 逐帧序列（环形覆盖写）
const STAGE_BUFFER_CAPACITY := 7200          # 阶段耗时环形缓冲（同窗口）
const FRAME_REPORT_INTERVAL := 60            # 每 60 帧聚合一次（§5.5）

var dev_assertions: bool = true              # Dev 断言开关（release 构建自动关闭）
var _frame_times: Array[float] = []          # 环形缓冲语义（固定容量覆盖写）
var _frame_cursor: int = 0
var _stage_times: Dictionary = {}            # 帧序阶段名 -> Array[float]（环形覆盖写）
var _stage_cursors: Dictionary = {}          # 阶段名 -> 写游标
var _stage_starts: Dictionary = {}           # 阶段名 -> begin 时刻（usec）
var _counters: Dictionary = {}               # 全部计数器（池/管线/总线共用）
var _frame_count: int = 0                    # 帧计数（报表聚合节拍）

# R187 共享组新计数登记表（DebugStats.count 通用字典的键名审计清单——防拼写漂移；
# 消费/写入点：W8 蓄能引爆 / W4 副束叠层超帽 / W5 镜数超帽 / W6 齐射余弹弃发 / W1 弹幕态激活）
const R187_COUNTER_KEYS: Array[StringName] = [
	&"w8_detonations",            # W8 满档引爆次数（验收「逐一吻合」断言源）
	&"laser_subbeam_rejected",    # W4 副激光池满补位失败降级次数（R226 注：语义自 R196 起已非叠层帽拒绝）
	&"mirror_rejected",           # W5 镜面数超绝对帽 5 被拒次数
	&"homing_volley_dropped",     # W6 齐射目标不足/池满余弹弃发次数
	&"volley_state_active",       # W1 弹幕态（TH_VOLLEY_STATE）激活次数
]

# R220 计数器审计块（R220 拆解契约 §2.2 主控冻结三键，照 R187_COUNTER_KEYS 先例）——
# 名单先立防拼写漂移；写点归后续包落地：fit_desc_measures=卡窗预热包 D1（_fit_desc miss
# 实测量测）/ quota_deferred+quota_dropped=火段数值包 C7（刀12 帧率优先弹生成配额 32 发/
# 物理步的超配顺延与队列帽溢出丢弃）。count() 通用字典（:333）对未注册键照样可写可读，
# 后续包任何落地序不受本块阻（trait_pool_discarded 等其余新键走通用通道，不进本名单）。
const R220_COUNTER_KEYS: Array[StringName] = [
	&"fit_desc_measures",         # _fit_desc 实测量测次数（预热后每开窗增量 ≤2 = 刀2 验收口）
	&"quota_deferred",            # 刀12：超配额弹顺延补发队列 +1（仅帧率优先生效）
	&"quota_dropped",             # 刀12：补发队列帽溢出丢弃 +1（顺延非丢弃的对照计数）
]

# R248 反馈收口计数器审计块（照 R187/R220 先例——键名名单先立防拼写漂移；count() 通用
# 字典对未注册键照样可写可读，登记只为审计）。
const R248_COUNTER_KEYS: Array[StringName] = [
	&"graze_hits",                # c4①：无敌窗被击（graze）节流后计数（player.take_contact_damage 唯一发点）
	&"graze_fx",                  # c4①：掠过微光消费计数（game_loop._on_graze_feedback；headless 亦计=唯一副作用）
	&"enemy_bullet_dropped",      # c4②：敌弹保留配额腾位失败丢弃计数（ProjectilePool.acquire(1)）
]

# R269 计数器审计块（照 R187/R220/R248 先例——键名名单先立防拼写漂移；count() 通用
# 字典对未注册键照样可写可读，登记只为审计）。释N=演出/警示件 queue_free 计数（秒差分
# 归因键）；拒N=保帧模式敌弹 team-1 帽拒绝计数（acquire(1) 门内——A 轨 §3.4）。
const R269_COUNTER_KEYS: Array[StringName] = [
	&"perffx_qfree",              # 释N 源：DeathPop/PoisonSplash 超池弃用 + Telegraph 三处回收 queue_free
	&"boost_bullet_capped",       # 拒N 源：boost 开 ∧ team-1 活口 ≥320 时 acquire(1) 拒发（该发未射）
]


func _ready() -> void:
	# release 构建剥离（A1 §3 口径：仅开发/验收构建启用断言与采样）
	if OS.has_feature("release"):
		dev_assertions = false
	# R245 诊断门辅修（切态重开秒窗）：状态切换即复位秒窗累计器——秒窗随态重开，
	# 消除跨界读数（EventBus 先于本类注册〔autoload 序 1<3〕，_ready 期连接安全）
	EventBus.state_changed.connect(_on_state_changed_diag_window)
	# R271 P3：树进出计数一次性接线（node_added/node_removed 秒计数 + 类名直方图——
	# 纯计数不改行为；node_removed 对 queue_free 亦触发〔free 时节点出树同发信号〕）
	get_tree().node_added.connect(_on_diag_node_added)
	get_tree().node_removed.connect(_on_diag_node_removed)


func _on_diag_node_added(p_node: Node) -> void:
	# R271 P3：加N 计数 + 类名直方图（导出期 top-8 dump；脚本类名优先、裸引擎类兜底）
	_diag_node_added += 1
	var s: Script = p_node.get_script()
	var key := p_node.get_class()
	if s != null and not s.resource_path.is_empty():
		key = s.resource_path.get_file()
	_diag_added_hist[key] = int(_diag_added_hist.get(key, 0)) + 1


func _on_diag_node_removed(_p_node: Node) -> void:
	# R271 P3：摘N 计数（直方图只记加侧——释放类归因走 释N/加N 对照）
	_diag_node_removed += 1


func _on_state_changed_diag_window(_p_state: int) -> void:
	# R245 诊断门辅修：渲ms/物步µs 秒窗累计器随态归零（vc56 跨秒窗携带伪影根治的
	# 配套刀——主修状态门之外，渲轴均值也不再跨态平均）
	_diag_reset_window_acc()


func _process(delta: float) -> void:
	# 采样通道（§0.2：_process 仅用于纯表现/DebugStats 采样）
	_push_frame_time(delta)
	_frame_count += 1
	# R271 P5：渲帧N 计数 + 渲峰ms 峰值（渲ms 同窗——渲峰ms ≥ 渲ms 恒成立，p5 断言面）
	_diag_proc_frames += 1
	if delta * 1000.0 > _diag_proc_peak_ms:
		_diag_proc_peak_ms = delta * 1000.0
	# R262b M4：原每 60 渲染帧一次的 frame_report() 调用移除——返回值在此无人消费
	# （真消费=export_csv 导出时点算与测试直调，两者皆显式），而每次调用=全场景树
	# 递归+3×7200 元素 duplicate+sort 的毫秒级尖峰，生产路径纯诊断税。帧时间采样
	# _push_frame_time 保留（导出与秒窗采样共用数据源）。
	_diag_accumulate_window(delta)             # R235 搭车③：渲ms/物步µs 秒窗累计（先累计后采样）
	_diag_maybe_sample()


# ── R205：真机诊断日志（1Hz 环形缓冲 + 主页面一键导出） ────────────
# 背景：vc12 真机战斗恒 10fps 而 dc 仅 300-500（旗舰 SoC 毫无压力）——前三轮假设
# 全证伪，瓶颈在 headless 量不到的设备级成本。本通道每秒采一行「fps/dc/o + 主循环
# 六段毫秒 + 引擎剩余 + 敌弹数 + 风暴差分」，主菜单「导出日志」一键取证。
const DIAG_SAMPLE_MS := 1000                   # 采样节拍
const DIAG_MENU_SAMPLE_MS := 10000             # R262e ③：MENU 态降频节拍（10s/行）
const DIAG_STORM_WARN_EVERY_S := 5             # 风暴差分告警化阈值（仅日志层）

var _diag_lines: Array[String] = []            # 环形缓冲语义（固定容量覆盖写——容量设置驱动）
var _diag_cursor: int = 0
var _diag_ring_cap: int = -1                   # R212：容量档重整位（-1=未初始化；档变化后首笔 push 重整一次）
var _diag_last_ms: int = -1000000              # 首帧即采（会话 0s 头一行）
var _diag_last_storm: int = 0                  # EventBus.storm_warnings 上次快照（差分用）
var _diag_last_phys: int = -1                  # R218 修轮#2：Engine.get_physics_frames() 上次快照
                                                 # （模N=秒内物理帧增量=实际模拟率——帽1 下
                                                 # 模拟率=min(fps,60)，慢动作深度量化口）
var diag_last_export_path: String = ""         # 最近一次导出路径（主菜单展示）


func version_string() -> String:
	# 运行时版本真源：export_apk_versioned.py bump 时烤入 config/version
	# （与 APK 文件名同口径 v0.1.x_vcNN）；桌面裸跑无打包 → 显式占位防老数据混流。
	var v := str(ProjectSettings.get_setting("application/config/version", ""))
	return v if v != "" else "(dev裸跑未打包)"


func _diag_maybe_sample() -> void:
	# 1Hz 节拍采样（_process 通道；无 GameLoop/菜单期也采——状态字随行）
	# R211 采样门：settings("diag_log") 关=每秒不再采样写入（_diag_push 不被调；已存
	# _diag_lines 环形缓冲与游标原样保留，diag_export/diag_clear 不受影响）；重开=下一拍
	# 立即恢复（_diag_last_ms 已过期即首采）。键未注册时 settings() 返回 null→bool(null)
	# =false→not→true，门保持开（自安全）。不放 _ready：autoload 序 DebugStats(3) 早于
	# Meta(4)，彼时读口未就绪；_process 每帧调用时全部 autoload 已注册。
	if not bool(Meta.settings("diag_log")):
		return
	var now := Time.get_ticks_msec()
	if now - _diag_last_ms < DIAG_SAMPLE_MS:
		return
	# R212：LEVEL_UP 选卡期不采样（用户点名：选 buff 时的帧率是选卡 UI 自身成本，混进
	# 日志会污染战斗期读数）。检查放节拍门后（仍 1Hz 频次、每帧零新增树扫描）、放
	# _diag_last_ms 刷新前（节拍不清零：选卡期不消费节拍，退出选卡回 PLAYING 后首拍
	# 立即补采一行再恢复 1Hz；已存 _diag_lines 原样保留）。
	var gl := _diag_find_game_loop()
	if gl != null and int(gl.get("state")) == GameConst.GameStatus.LEVEL_UP:
		return
	# R262e ③：MENU 态降频 10s/行——vc71 实证打完局挂菜单 90 分钟把 120 行环形全占
	# （局内只剩 9 行），战斗期读数被菜单挂机冲掉（「局内日志看看」无数据可看）。
	# MENU 态读数稳态重复（同构行零信息），10s 一行保住趋势采样。节拍语义：MENU 期
	# 不足 10s 不采不消费节拍（同 LEVEL_UP 口径），离开 MENU 首拍立即补采。
	if gl != null and int(gl.get("state")) == GameConst.GameStatus.MENU \
			and now - _diag_last_ms < DIAG_MENU_SAMPLE_MS:
		return
	# R220 刀1：_diag_last_ms 刷新挪到拼行之后——模N 新口径（物理帧差分×1000÷实际采样
	# 墙钟窗）需在窗被覆盖前读到「上次采样 → 本次」的真实墙钟差（原序窗恒 0 不可用；
	# 节拍消费语义不变：本行写完才推进节拍基线，选卡期照旧不消费）。
	_diag_push(_diag_format_line(gl, now))
	_diag_last_ms = now
	_diag_reset_window_acc()                   # R235 搭车③：秒窗累计器随采样节拍复位（直调拼行的测试不复位）


func _diag_find_game_loop() -> Node:
	# GameLoop 非 autoload（main.tscn 场景根「Main」）；测试套件另起实例名——
	# 以 diag_counts 方法特征解析（唯一持有者），找不到返回 null（行内各字段退化）。
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


# ── R235 搭车③：长尾分键秒窗累计器（1Hz 行尾 物步µs/渲ms 键源；零分配纯标量加法）──
# 轴口径：
# · 渲ms（渲染轴）：当窗渲染帧 delta 累计 ms ÷ 帧数 = 均值（自选口径：均值——与 物步µs
#   同窗对账方便；headless 无 vsync/渲染 → 有值无意义，判读须真机）。
# · 物步µs（物理相残差）：Performance.TIME_PHYSICS_PROCESS（CAL0 实证=末步语义——
#   多步帧只含末步成本，非帧内累计）− 同末步段和（R237 修账：原「段和×步数」减项与
#   末步监视器口径错配，多步帧必负→钳 0 伪影；现同末步配对，早步残差不计=保守低估）。
#   语义=引擎物理步本体+物理块内 message_queue flush 执行的延迟调用（⑧popup/敌死亡链
#   DeathPop/Telegraph/桶place/queue_free/⑦b fx——段探针量发射不量执行）+其他节点
#   物理相成本。R237 A/B 已排除物理空间（broadphase/配对/信号）大头——大值嫌疑=延迟
#   冲刷桶。headless 无 vsync → 有值无意义。
#   残差构成披露：scripts 内 _physics_process 唯一实现=game_loop（源级核实）→ 段和
#   覆盖面=GameLoop 十六段+派µs（剔除 移/火/跳 双计子集）；「他」键钳 0 使段和略低
#   估→残差略高估（方向安全，披露不修）。深载多步帧段值只记末步（game_loop 段探针
#   逐步覆盖写）——本口径与末步监视器配对后，早步 GD 成本与早步残差双双不计。
var _diag_render_ms_sum: float = 0.0     # 当窗渲染帧 delta 累计 ms（渲ms 均值分子）
var _diag_render_frames: int = 0         # 当窗渲染帧数（渲ms 分母）
var _diag_phys_mon_us: int = 0           # 当窗物理活跃渲染帧 monitor 累计 µs（物步µs 被减数——末步语义）
var _diag_phys_gd_us: int = 0            # 同窗同末步 GameLoop 段和累计 µs（物步µs 减项——R237 修账去 ×步数）
var _diag_phys_samples: int = 0          # 物理活跃渲染帧数（物步µs 差值分母）
var _diag_phys_acc_last: int = -1        # 上次累计时的物理帧号（变更=本渲染帧有物理步）
var _diag_gl_cache: Node = null          # GameLoop 引用缓存（物理活跃帧读段和——树扫降频）
var _diag_gl_scan_after_ms: int = 0      # 缓存失效重扫节流基线（无 GameLoop 期至多 1Hz 一次树扫）

# ── R269 B 轨：物理残差逐桶计时秒窗累计器（1Hz 行尾 死µs/警µs/桶µs/延µs 键源；────
#    只加计时不改行为——wrap 落在发射/回收路径体首尾，与段和口径无双计（独立观测面
#    非减项，物步µs 减项表零触碰）。static 面：enemy 内嵌类/tex_bucket_host 等 static
#    上下文直调 bucket_begin/end（autoload 单实例下等价实例态）。
#    同键嵌套=深度计数可重入（生产路径 DeathPop.pop→_death_fx_admit→抢占→_release
#    内嵌同键 _release——外层 span 全含内层工作，只记外层=正确归因，内层吸收不双计）。
static var _diag_bucket_us: Dictionary = {}    # StringName 键 -> 当窗累计 µs（采样后复位）
static var _diag_bucket_open: Dictionary = {}  # StringName 键 -> 最外层 begin 时刻 usec
static var _diag_bucket_depth: Dictionary = {} # StringName 键 -> 嵌套深度（0=无在飞 span）

# ── R271 P 轨：二轮定谳键秒窗累计器（1Hz 行尾追加在 促N 之后、尖峰段之前；─────
#    只加计时不改行为——独立观测面非减项，物步µs 减项表（:270-279 区域）零触碰）。
#    键义（设计 §3.1）：步µs=步入口→步出口；隙µs=主哨兵执行→下一步入口（引擎物理
#    服步/帧间其余工作）；延早µs=步入口哨兵（=整步工作+冲刷窗，延早−延≈步µs 自洽锚）；
#    延渲µs=_process 尾哨兵（idle 相冲刷窗）；延峰µs=当窗单次主哨兵延迟峰值（区分
#    「均匀每步几 ms」与「少数尖峰帧几十 ms」——刀面不同）；加N/摘N=SceneTree
#    node_added/node_removed 秒计数（池周转/演出件全量观测面——释N 只覆盖已 wrap 的
#    4 类，加N/摘N 是全量）；绘µs=自绘件 _draw() 当窗累计（&"draw" 桶，H3 专属——
#    wrap 清单 grep 派生全量，verdict 表头披露）；渲帧N=_process 调用秒计数（procHz）；
#    呈帧N=Engine.get_frames_drawn() 秒差分（呈现帧率铁证——headless 无呈现=同源自洽
#    型读数、数值判读只在真机行）；渲峰ms=_process delta 当窗峰值（尖峰硬线 ≤36ms）。
#    多步帧（一渲染帧 >1 物理步）的逐行四分账仅参考——窗口跨界切割在多步帧有理论
#    错位，判读以三哨兵为准（设计 §3.1-P1 注记）。
static var _diag_step_us: int = 0              # 步µs 当窗累计
static var _diag_step_open_us: int = -1        # 在飞步入口时戳（-1=无——嵌套步不存在，防御位）
static var _diag_gap_us: int = 0               # 隙µs 当窗累计
static var _diag_gap_mark_us: int = -1         # 最近主哨兵执行时戳（-1=无前值；步入口消费即清）
static var _diag_flush_peak_us: int = 0        # 延峰µs 当窗峰值（只跟主哨兵 &"flush"）
static var _diag_proc_frames: int = 0          # 渲帧N 当窗计数（DebugStats._process 自身）
static var _diag_proc_peak_ms: float = 0.0     # 渲峰ms 当窗峰值
static var _diag_frames_drawn_mark: int = -1   # 呈帧N 差分基线（-1=下次拉取立基线返 0）
var _diag_node_added: int = 0                  # 加N 当窗计数（实例态：树信号 connect 在 _ready）
var _diag_node_removed: int = 0                # 摘N 当窗计数
static var _diag_added_hist: Dictionary = {}   # 加N 类名直方图（会话累计——diag_export 头部
                                               # top-8 dump，不进行键；按键字符串排序）


static func bucket_begin(p_key: StringName) -> void:
	# R269：计时桶开（深度 0 时记基线；嵌套只增深度——span 计外层）
	var d := int(_diag_bucket_depth.get(p_key, 0))
	if d == 0:
		_diag_bucket_open[p_key] = Time.get_ticks_usec()
	_diag_bucket_depth[p_key] = d + 1


static func bucket_end(p_key: StringName) -> void:
	# R269：计时桶收（深度归零时差值入秒窗累计器；无 begin 直返防脏——钳负防时钟回绕）
	var d := int(_diag_bucket_depth.get(p_key, 0))
	if d <= 0:
		return
	_diag_bucket_depth[p_key] = d - 1
	if d > 1:
		return                              # 内层 span 吸收（外层收口统一入账）
	var t0: Variant = _diag_bucket_open.get(p_key, null)
	_diag_bucket_open.erase(p_key)
	if t0 == null:
		return
	_diag_bucket_us[p_key] = int(_diag_bucket_us.get(p_key, 0)) \
		+ maxi(Time.get_ticks_usec() - int(t0), 0)


static func diag_bucket_window_us(p_key: StringName) -> int:
	# R269：当窗累计直读口（测试与 1Hz 行共用；读取不复位——复位统一 _diag_reset_window_acc）
	return int(_diag_bucket_us.get(p_key, 0))


func diag_flush_sentinel(p_enqueued_us: int, p_tag: StringName = &"flush") -> void:
	# R269：延µs 哨兵收（game_loop._physics_process 尾 call_deferred 目标——执行时刻−
	# 入队时刻入 &"flush" 桶）。读数语义=我方物理步返回→message_queue 冲刷执行之间的
	# 延迟工作量上限（对照实验键：延µs≈物步µs→延迟冲刷桶坐实；延µs≈0 而物步µs 大→
	# 引擎物理步嫌疑回潮——引擎 4.3 冲刷点位未文档化，B 轨不预设结论）。
	# R271 P2：p_tag 参化三哨兵——主（步尾，既有 &"flush"）/早（步入口 &"flush_early"）/
	# 渲（idle 尾 &"flush_render"），分别入桶同款通道零新机制；延峰µs 与 隙µs 界只跟
	# 主哨兵（早/渲哨兵执行不推界——否则 idle 相工作会被切出 隙µs 误归物理相位）。
	var d := maxi(Time.get_ticks_usec() - p_enqueued_us, 0)
	_diag_bucket_us[p_tag] = int(_diag_bucket_us.get(p_tag, 0)) + d
	if p_tag == &"flush":
		if d > _diag_flush_peak_us:
			_diag_flush_peak_us = d
		_diag_gap_mark_us = Time.get_ticks_usec()


static func diag_step_begin() -> void:
	# R271 P1/P2：物理步入口（game_loop._physics_process 段序头调）。隙µs=最近主哨兵
	# 执行→本入口（引擎物理服步/帧间其余工作；首步无前值计 0——消费即清防多哨兵重复
	# 推界）；步µs 基线开。零分配纯标量——只加计时不改行为。
	var now := Time.get_ticks_usec()
	if _diag_gap_mark_us >= 0:
		_diag_gap_us += maxi(now - _diag_gap_mark_us, 0)
		_diag_gap_mark_us = -1
	_diag_step_open_us = now


static func diag_step_end() -> void:
	# R271 P1：物理步出口（game_loop._physics_process 段序尾、主哨兵入队前调）。
	if _diag_step_open_us < 0:
		return
	_diag_step_us += maxi(Time.get_ticks_usec() - _diag_step_open_us, 0)
	_diag_step_open_us = -1


func diag_flush_sentinel_early(p_enqueued_us: int) -> void:
	# R271 P2：延早µs 收（步入口哨兵——入队→执行延迟 = 我方整步工作+冲刷窗；
	# 延早−延 ≈ 步µs 为自洽锚；若 延早≈延≫0 且步µs 小 → 窗口在步前即已积压，指向 H1/H5）
	diag_flush_sentinel(p_enqueued_us, &"flush_early")


func diag_flush_sentinel_render(p_enqueued_us: int) -> void:
	# R271 P2：延渲µs 收（GameLoop._process 尾哨兵——idle 相冲刷窗；≈0 → 冲刷成本
	# 集中于物理相位之后；大 → idle 相亦有积压）
	diag_flush_sentinel(p_enqueued_us, &"flush_render")


func _diag_frames_drawn_delta() -> int:
	# R271 P5：呈帧N 秒差分（Engine.get_frames_drawn——拉取立基线、首拉返 0、钳负，
	# 帽N/结N 同款差分纪律；headless 无呈现=同源自洽型读数，数值判读只在真机行）
	var cur := Engine.get_frames_drawn()
	var d := 0 if _diag_frames_drawn_mark < 0 else maxi(cur - _diag_frames_drawn_mark, 0)
	_diag_frames_drawn_mark = cur
	return d


func _diag_gl_cached() -> Node:
	# 每帧版 _diag_find_game_loop：缓存命中 O(1)；失效（测试拆树）后 1s 节流重扫——
	# boot 前/纯探针态不为每帧付树扫
	if is_instance_valid(_diag_gl_cache):
		return _diag_gl_cache
	var now := Time.get_ticks_msec()
	if now < _diag_gl_scan_after_ms:
		return null
	_diag_gl_scan_after_ms = now + 1000
	_diag_gl_cache = _diag_find_game_loop()
	return _diag_gl_cache


func _diag_accumulate_window(p_delta: float) -> void:
	# R235 搭车③：渲染轴/物理服务器步轴秒窗累计（1Hz 采样行读走 → _diag_reset_window_acc）。
	# monitor 只在物理活跃帧累计（TIME_PHYSICS_PROCESS 帧间不复位——空转帧读数为陈值，
	# 以物理帧号变更判重）；段和剔除 移/火 两子集键 + 显式加 派µs/entry（R268：popup 已出
	# 排除表入减项——与本函数减项/「他」键/余值三表同口径，勿按旧「三子集」口径改回）。
	_diag_render_ms_sum += p_delta * 1000.0
	_diag_render_frames += 1
	var pf := Engine.get_physics_frames()
	if pf == _diag_phys_acc_last:
		return
	_diag_phys_acc_last = pf               # R237 修账：步数差分仅作变更检测（减项已同末步口径）
	var gl := _diag_gl_cached()
	# R245 诊断门主修（物理侧状态门）：物理帧判重通过后，仅 PLAYING 态才累计物理侧
	# 三累计器（mon/gd/samples）——离场 PLAYING 深载尾样本与 PAUSED/LEVEL_UP 冻结期
	# 的秒窗跨界携带不再混入 M/D/B/S/L 行物步µs（vc56 菜单行 34.2k/62.9k 越界读数
	# =采样伪影裁定，设计 §2.2）。渲轴两累计器（上方 ms/帧）照常全态累计——菜单
	# fps/渲ms 诊断力保留。工程内脚本直引枚举合法（gl 鸭子口读 state int）。
	if gl == null or int(gl.get("state")) != GameConst.GameStatus.PLAYING:
		return
	var probe_raw: Variant = gl.get("stage_probe_us")
	if not (probe_raw is Dictionary):
		return                           # 无 GameLoop 期（boot 前/纯探针）不采样——空窗均值无归因意义
	_diag_phys_mon_us += int(Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS) * 1000000.0)
	var probe: Dictionary = probe_raw
	var gd_us := int(probe.get(&"dispatch", 0))
	# R244 冲刷桶批：帧入口键入段和（我方 glue 不再误记引擎侧残差——与 dispatch 同款
	# 显式加法；键不进 DIAG_STAGE_ORDER 故行格式不变）
	gd_us += int(probe.get(&"entry", 0))
	for key in DIAG_STAGE_ORDER:
		# R268 性能刀 P2：popup 出排除表（记账洞三表之一）——popup tick 在物理帧内 ⑧段
		# 执行=计入 TIME_PHYSICS_PROCESS 监视器却不出减项 → 物步残差与「他」各背一份
		# 双计（vc77 物步µs 48000-158000 归因被系统性误导）。三表同步：本处/同文件
		# 余值段和/game_loop.gd「他」段和。
		if key != &"player_mv" and key != &"player_wp":
			gd_us += int(probe.get(key, 0))
	_diag_phys_gd_us += gd_us            # R237 修账：同末步配对（monitor 末步语义——
	                                     # ×steps 减项曾致多步帧必负→钳 0 伪影，桌面
	                                     # A/B 四臂实证；早步残差不计=保守低估）
	_diag_phys_samples += 1


func _diag_reset_window_acc() -> void:
	# 秒窗累计器复位（1Hz 采样行 push 后调用；直调 _diag_format_line 的测试不复位）
	_diag_render_ms_sum = 0.0
	_diag_render_frames = 0
	_diag_phys_mon_us = 0
	_diag_phys_gd_us = 0
	_diag_phys_samples = 0
	_diag_bucket_us.clear()                  # R269：B 轨秒窗桶复位（在飞 begin 不清——
	                                         # 迟收样本入新窗，无害不丢样本）
	# R271 P 轨：秒窗键复位（界标记 _diag_gap_mark_us/_diag_frames_drawn_mark 与类名
	# 直方图 _diag_added_hist 为跨界/会话累计器，不随窗清——直方图在 diag_export dump）
	_diag_step_us = 0
	_diag_gap_us = 0
	_diag_flush_peak_us = 0
	_diag_proc_frames = 0
	_diag_proc_peak_ms = 0.0
	_diag_node_added = 0
	_diag_node_removed = 0


func diag_push_calib(p_line: String) -> void:
	# R235 搭车④：校准件一次性行入口（1Hz 采样通道之外直入环形日志——不受 diag_log
	# 采样门拦：用户「导出诊断日志」必然带上六臂读数；不写文件系统/user://）
	_diag_push(p_line)


const DIAG_EVENT_CAP := 120                   # R257 评审M3：事件独立环容量（~20 趟出发链）
var _diag_ev_lines: Array[String] = []        # 事件独立环（事件低频，FIFO remove_at 足够）


func event(p_line: String) -> void:
	# R257：玩法事件入环（出发链事件+状态迁移+选关/迁移拒绝——真机「出发回主页」类
	# 复发时 diag 导出一锤定罪）。**独立环单写**（QA-257-2 修轮改双写后 r208/r211
	# 既有断言破：事件行进 _diag_lines 会改变时间线环行数/diag_clear 返回值口径）——
	# _diag_lines 保持纯 1Hz 性能采样行（既有口径零触碰），事件只入 _diag_ev_lines
	# 独立环（120 行 FIFO 不被性能行冲刷——一次性失败+延迟导出不丢证；导出前置段）。
	# 事件行带 [ev HH:MM:SS] 墙钟前缀（真机对时轴，与性能行运行时轴肉眼可分）。
	var line := "[ev %s] %s" % [Time.get_time_string_from_system().substr(0, 8), p_line]
	_diag_ev_lines.append(line)
	while _diag_ev_lines.size() > DIAG_EVENT_CAP:
		_diag_ev_lines.remove_at(0)


var _diag_last_deathpop_capped: int = -1   # R230 帽N 差分基线（-1=下次拉取立基线返 0）


var _diag_dispatch_last: Dictionary = {}  # R233 修1：派deferred/派drop 差分基线（键→上次值；
                                          # -1 语义同结N=下次拉取立基线返 0——两键独立防双消费）


func _diag_dispatch_delta(p_key: StringName) -> int:
	# R233 修1（评审 HIGH-1）：派发两计数器（dispatch_deferred/dispatch_stale_drop——
	# 计数点在 damage_pipeline.dispatch_resolved_frame，不经 GameLoop.diag_counts →
	# 差分基线在本类侧）秒差分。口径对齐 _deathpop_capped_delta（帽N）：拉取立基线、
	# 首拉返 0、钳负（跨暂停窗不回吐）；两键各自独立基线（R233 T0 教训——共享基线被
	# 先消费会得 0）；重复拉取增量=0 合法（直调测试同规）。
	var cur := get_counter(p_key)
	var last: int = _diag_dispatch_last.get(p_key, -1)
	_diag_dispatch_last[p_key] = cur
	return 0 if last < 0 else maxi(cur - last, 0)


func _deathpop_capped_delta() -> int:
	# R230 帽N 秒差分：deathpop_capped 计数器（enemy.gd 并发帽许可口的采样拒绝/最老
	# 抢占累计）每秒增量。口径对齐 game_loop._diag_settles_delta（结N）：拉取立基线、
	# 首拉返 0、钳负（跨暂停窗不回吐）；重复拉取增量=0 合法（直调测试同规）。
	var cur := get_counter(&"deathpop_capped")
	var delta := 0 if _diag_last_deathpop_capped < 0 else maxi(cur - _diag_last_deathpop_capped, 0)
	_diag_last_deathpop_capped = cur
	return delta


func _diag_format_line(p_gl: Node, p_now_ms: int) -> String:
	# 单行格式（紧凑可人读；headless/无 GameLoop 期各字段安全退化为 0/空）：
	# [m:ss S] fps9 dc412 o891 | 玩3 网1 弹12 敌34 波2 磁1 感0 特0 UI6 | 余44ms | 敌210 弹380 态42 st+3 p60 ri0
	var elapsed := maxi(p_now_ms, 0)             # Time.get_ticks_msec() 即引擎启动起算
	var stamp := "[%d:%02d %s] " % [elapsed / 60000, (elapsed / 1000) % 60, _diag_state(p_gl)]
	var fps := Engine.get_frames_per_second()
	var dc := RenderingServer.get_rendering_info(RenderingServer.RENDERING_INFO_TOTAL_DRAW_CALLS_IN_FRAME)
	var obj := RenderingServer.get_rendering_info(RenderingServer.RENDERING_INFO_TOTAL_OBJECTS_IN_FRAME)
	var parts: Array[String] = []
	var stages_ms := 0.0
	if p_gl != null:
		# 十六段（R207 拆段 + R213/R216/R217/R218 拆键 + R220 刀1 卡键拆分）：玩=②段全量
		# 移=player.tick 增益+移动 火=player.tick 四组武器调度（R217，vc24 玩117 归因）
		# 碎=碎片段+连杀 网=双网格重建 弹=grid_projectile(投射物运动/碰撞)
		# 敌=enemy(元素/分离) 波=wave(遗物/尸体) 磁=磁吸碎片飞行/吸收(→gain_xp 链)
		# 感=feel(选卡消化/game_feel) 特=fx(元素特效层) 跳=popup_manager.tick(R218，
		# 含排版批——vc25 UI 尖峰 53-200ms 归因) UI=ui(HUD/Boss条/震屏)
		# 开=card_open(_open_card_flow 开窗级联) 消=card_drain(_tick_merged_overflow
		# 溢出批消化)（R220 刀1 拆键——原 card 同键混合归因分离）
		# 他=物理帧未捕获 GDScript(R218，段间空隙/编排/事件派发——vc25 余15-56ms
		# 先切我方部分)；探针关时空
		var probe: Dictionary = p_gl.get("stage_probe_us")
		# R217 修轮（评审#2）+R218 刀C+R268 性能刀 P2：移/火 两键是 玩 段严格子集——
		# 余值求和跳过子集键，否则正常帧余被多扣、尖峰帧直接钳 0，误判引擎侧占比。
		# 跳（popup）与 UI 自 R218 刀C 起为兄弟互斥段（game_loop ⑧段内 ui=总−popup，
		# 无子集关系——旧注释「跳是 UI 严格子集」与代码互相矛盾，R268 改写）——R268
		# 起 popup 入段和（否则 popup 执行成本被物步µs/余双计；三表同步：同文件物步
		# gd_us 减项/game_loop.gd「他」段和）
		for key in DIAG_STAGE_ORDER:
			var us := int(probe.get(key, 0))
			if key != &"player_mv" and key != &"player_wp":
				stages_ms += float(us) / 1000.0
			parts.append("%s%d" % [DIAG_STAGE_TAGS.get(key, "?"), int(round(float(us) / 1000.0))])
		# R235 搭车③：dispatch 段（互斥段，原混入 UI 段读数）显式入段和——余值语义不变
		#（不进 DIAG_STAGE_ORDER：行中段不印，行尾「派µs」键直读）
		stages_ms += float(int(probe.get(&"dispatch", 0))) / 1000.0
		# R244 冲刷桶批：帧入口键同款入段和（我方 glue 出「余」的引擎侧部分）
		stages_ms += float(int(probe.get(&"entry", 0))) / 1000.0
		# 余 = 帧预算 − 我方段和（去子集键后=①~⑯互斥段，他已含我方未捕获部分；
		# >0 部分=引擎侧：物理步进+渲染提交+驱动/GC——R218 起帽1 单步不再螺旋放大）
		var frame_ms := 1000.0 / float(maxi(fps, 1))
		parts.append("余%dms" % maxi(int(round(frame_ms - stages_ms)), 0))
		var counts: Dictionary = p_gl.call("diag_counts")
		var storm_delta := EventBus.storm_warnings - _diag_last_storm
		_diag_last_storm = EventBus.storm_warnings
		# R218 修轮#2（评审#2）+R220 刀1 新口径：模=实际模拟率（Hz）——
		# sim_hz = 物理帧差分 × 1000 ÷ 实际采样墙钟窗 ms（p_now_ms − _diag_last_ms，
		# 窗基线在 _diag_maybe_sample 内本行拼完才刷新——跨选卡/暂停窗读真实墙钟差，
		# vc26 模157-363 伪读数的根治口径，方案书刀1-① 定死单一方案）。跨采样窗行
		#（墙钟窗 > 1.5×DIAG_SAMPLE_MS，如选卡退出后首采）模值后缀 `*` 供判读剔除；
		# 首帧 _diag_last_phys=-1 哨兵不出脏值（模0 不带标）。帽1 深谷段模拟率
		# =min(fps,60)，中频段 40-59fps 慢动作深度（0.5×~0.98×）的量化读数。
		var phys_now := Engine.get_physics_frames()
		var sim_hz := 0
		var cross_win := false
		if _diag_last_phys >= 0:
			var win_ms := maxi(p_now_ms - _diag_last_ms, 1)
			sim_hz = int(round(float(phys_now - _diag_last_phys) * 1000.0 / float(win_ms)))
			cross_win = win_ms > (DIAG_SAMPLE_MS * 3) / 2
		_diag_last_phys = phys_now
		# R215 刀D + R216 + R217 + R218：桶e+p+x=E' 分桶数（合批健康度）/磁=磁吸片在场数/
		# 拾=碎片在场总数/跳=跳字在场条数/断=桶内非白敌数（量化后高计口径）/组=敌桶内
		# distinct 色元组数=真合批分组（R218——≤档组合数≈16 为设计达成；组低 dc 高→
		# 断批源在桶外）
		parts.append("敌%d 弹%d 态%d 桶%d+%d+%d 磁%d 拾%d 跳%d 断%d 组%d 模%s st+%d p%d ri%d" % [int(counts.get(&"enemies", 0)),
			int(counts.get(&"projectiles", 0)), int(counts.get(&"status_enemies", 0)),
			int(counts.get(&"bucket_enemy", 0)), int(counts.get(&"bucket_projectile", 0)),
			int(counts.get(&"bucket_xp", 0)),
			int(counts.get(&"magnet_shards", 0)), int(counts.get(&"shards", 0)),
			int(counts.get(&"popups", 0)), int(counts.get(&"tinted_enemies", 0)),
			int(counts.get(&"tint_groups", 0)),
			str(sim_hz) + ("*" if cross_win else ""),
			storm_delta,
			Engine.physics_ticks_per_second, int(counts.get(&"runtime_inst", 0))])
		# R220 刀1 行尾追加（契约 §3.4 冻结格式，追加在 ri%d 之后——既有子串逐位保持）：
		# 结=本秒结算数差分（真机每命中 µs 定标口：弹段ms×1000÷结N）/ 自=自导池在场数
		#（弹N 不含 _homing_pool 的口径纠正）/ 调=PerfGovernor 档 1-3（effective_tier——
		# 注入态读注入值）；档变计数 >0 时追加 变N（真采样驱动的累计档变数）。
		parts.append(" 结%d 自%d 调%d" % [int(counts.get(&"settles", 0)),
			int(counts.get(&"homing_projectiles", 0)), PerfGovernor.effective_tier()])
		if PerfGovernor.transitions > 0:
			parts.append(" 变%d" % PerfGovernor.transitions)
		# R223 修轮（评审#4）：结算预算三轴（顺=超帽顺延 / 冲=冲刷真结算含过期强冲 /
		# 弃=诚实丢弃=亡目标+uid复用+超载修剪）——追加在 变N 之后，既有子串逐位保持
		parts.append(" 顺%d 冲%d 弃%d" % [int(counts.get(&"settles_deferred", 0)),
			int(counts.get(&"settles_flushed", 0)),
			int(counts.get(&"settles_dropped", 0))])
		# R230 帽N=DeathPop/桶内演出件并发帽每秒拒绝/抢占数（秒差分口径对齐 结N/翻N
		# 先例——差分基线在本类侧 _deathpop_capped_delta：拉取立基线、首拉返 0、钳负；
		# 计数点在 enemy.gd 静态许可口，不经 GameLoop.diag_counts）：>0=三重门
		# （mobile∧帧率优先∧tier≤2）+满载敌数门已触发采样拒绝/最老抢占——vc35 真机
		# 验证激活键；门关期恒 0。插入在 弃N 之后、位图R 之前——行尾「补N 裁N」冻结
		# 断言（r229_pool_valve）与 diagfreeze「 裁N」尾锚不变位
		parts.append("帽%d" % _deathpop_capped_delta())
		# R226 仪表补码：位图R=跳字字形图集就绪（0=mobile 跳字 Label 回退态→dc 读数
		# 假阴嫌疑）；翻N=fullload 门翻转秒差分（>2/s=装饰显隐震荡需回报）。
		# R227 补N=新局入口位图补烤毫秒一次性读数（>0=菜单未就绪由开局兜底——激活
		# 路径归因键）。追加在 弃N 之后，既有子串逐位保持
		parts.append(" 位图%d 翻%d 补%d" % [int(counts.get(&"bitmap_ready", 0)),
			int(counts.get(&"fullload_flips_delta", 0)),
			int(counts.get(&"bitmap_bake_ms_delta", 0))])
		# R229 裁N=弹池静载阀门一次性裁闲读数（追加在 补N 之后、尖峰段之前——R226/R227
		# 行尾追加先例，既有子串逐位保持）：>0=三重门（mobile∧帧率优先∧tier≤2）已触发
		# 裁闲，与 o 键对拍即定标 o 是否计隐藏静载；一次性读数——触发后下一采样行 >0，
		# 之后恒归 0
		parts.append("裁%d" % int(counts.get(&"pool_trimmed", 0)))
		# R231 刀B 快N=玩家弹快路径活弹数（当秒末帧分区计数，diag_counts.pfast_live 直读
		# ——非差分、非一次性读数，与 帽N/裁N 的秒差分口径不同源）：快N/弹N≈覆盖率，
		# 真机判读键（用户构筑大量 MEC_BOUNCE/EF_SIZE 时 快N→0=刀未激活，R230 帽N 教训
		# 同款「零激活盲区」预防）。追加在 裁N 之后（行尾新段），既有子串逐位保持——
		# r229_pool_valve「补N 裁N」冻结断言与 r230 帽N 插入位断言已同步迁移。
		parts.append("快%d" % int(counts.get(&"pfast_live", 0)))
		# R232 T1b 结µs=结算轴（resolve+冲刷）当秒每结算均值 µs（分子=pipeline 结算段
		# 累计差分、分母=结N 同真源独立基线差分——vc37 真机单结 µs 直读键，R223 刀3
		# 预算标定输入）。R233 T0 修复：分母基线与结N 键各自独立（diag_counts 内结N 键
		# 先消费共享基线，结µs 复用则二次差分≈0 → 曾退化为每秒累计 µs）。
		# 追加在 快N 之后（行尾新段），既有子串逐位保持——R231 快N 先例；
		# qa_r228_diagfreeze 尾锚正则同步迁移（「 裁N 快N」→「 裁N 快N 结µsN」）。
		parts.append("结µs%d" % int(counts.get(&"settle_us_per", 0)))
		# R233 T1 插µs=渲染帧插值写入每帧均值 µs（决策7 诊断先于行为刀——插值层 T6
		# 未实施期恒 0=关态基线；T6 实施后即有读数，AC-9 深载判据 ≤500µs/帧；分母=
		# 渲染帧数差分，与 结µs 的每结算均值口径不同源）。
		# 追加在 结µs 之后（行尾新段），既有子串逐位保持——R232 结µs 先例；
		# qa_r228_diagfreeze 尾锚正则同步迁移（「 裁N 快N 结µsN」→「 裁N 快N 结µsN 插µsN」）。
		parts.append("插µs%d" % int(counts.get(&"ip_us_per", 0)))
		# R233 修轮（评审 MED-3 + QA LOW-1）：插模拟µs=模拟侧插值两遍历（帧入口恢复+
		# 帧末快照）当秒累计 µs——决策3.3「贴边预算下必须可观测」补全：原快照遍历挂
		# 「他」键计算之后完全不可见/恢复遍历混入「他」聚合。秒差分总量口径（非每帧
		# 均值，与 插µs 每渲染帧均值口径不同源）；快照 T7 无条件跑 → 谓词关/headless
		# 态本键=快照遍历实际成本直读（QA LOW-1 量化 0.1-0.3ms/帧的盲区消解）。
		# 追加在 插µs 之后（行尾新段），既有子串逐位保持——R232 结µs/R233 插µs 先例；
		# qa_r228_diagfreeze/r229/r230 尾锚正则同步迁移。
		parts.append("插模拟µs%d" % int(counts.get(&"ip_sim_us", 0)))
		# R233 修轮（评审 HIGH-1）：派deferredN/派dropN=派发帽顺延/过期前缀丢弃秒差分
		#（计数点 damage_pipeline dispatch_resolved_frame :314/:325——R221 Fix C 起已写
		# DebugStats 计数器但从不上行，真机导出日志唯一取证通道缺位：vc38 AC-2 派发条款
		#（deferred 有界+stale_drop/结N≤现状口径）与 DISPATCH 192 触发判据不可裁定）。
		# 秒差分独立基线（本类侧 _diag_dispatch_delta——T0 教训：与任何共享基线隔离防
		# 双消费得 0）。追加在 插模拟µs 之后（行尾新段），既有子串逐位保持；同上尾锚
		# 正则同步迁移。
		parts.append("派deferred%d 派drop%d" % [_diag_dispatch_delta(&"dispatch_deferred"),
			_diag_dispatch_delta(&"dispatch_stale_drop")])
		# R235 搭车③（R237 修账语义更正）：行尾三新键（追加在 派deferred/派drop 之后、
		# 尖峰段之前——行尾新段先例；既有子串逐位保持，r229/r230_k2/qa_r228 尾锚正则
		# 同步迁移）：
		# · 物步µsN=物理相残差当窗每物理活跃渲染帧均值 µs（monitor 末步−同末步段和，钳负
		#   ——引擎物理步+物理块 message_queue flush 执行的延迟调用〔popup/死亡链/fx——
		#   段探针量发射不量执行〕；R237 A/B 已排除物理空间大头，大值嫌疑=延迟冲刷桶；
		#   深载多步帧早步不计=保守低估；无 GameLoop 空窗不采样；headless 有值无意义；
		#   R244 修B：减项另含 entry 键（帧入口 glue）——与 vc53 前读数不可直接对拍）。
		# · 派µsN=⑧前派发段（dispatch_resolved_frame）末帧直读 µs（段键同口径——探针关
		#   =0；R235 前混入 UI 段读数，现独立分键，UI 段不含派发）。
		# · 渲msN.N=当窗渲染帧耗时均值 ms（渲染轴——深载 fps≤16.6ms 预算线后帧率上限由
		#   渲染轴支配，R243 终点对账硬判据；headless 无 vsync/渲染 → 有值无意义）。
		var _phys_step_us := 0
		if _diag_phys_samples > 0:
			_phys_step_us = maxi(_diag_phys_mon_us - _diag_phys_gd_us, 0) / _diag_phys_samples
		var _render_ms := _diag_render_ms_sum / float(maxi(_diag_render_frames, 1))
		parts.append("物步µs%d 派µs%d 渲ms%.1f" % [_phys_step_us,
			int(probe.get(&"dispatch", 0)), _render_ms])
		# R238：挡N=格挡力场成功格挡次数秒差分（计数点 player.take_contact_damage 格挡
		# 分支 shield_blocks——护盾「选了没生效」真机两报后的效果可判读口：挡N>0=护盾
		# 在挡；挡N 恒 0 而 护盾条在=充能中或接触链缺口；差分基线复用 _diag_dispatch_last
		# 字典（通用 counter 差分，拉取立基线/首拉返 0/钳负）。行尾新段先例，尾锚正则
		# 同步迁移（追加可选组）。
		parts.append("挡%d" % _diag_dispatch_delta(&"shield_blocks"))
		# R269 B 轨八键（追加在 挡N 之后、尖峰段之前——行尾新段先例，既有子串逐位保持；
		# qa_r228_diagfreeze/r229_pool_valve/r230_k2_deathcap 尾锚正则同批迁移，§0.2 声明）：
		# · 死µsN=死亡链演出件（DeathPop/PoisonSplash pop/_release）当秒累计 µs；
		# · 警µsN=Telegraph 三件套创建/挂树/配置当秒累计 µs（enemy.gd 发射点 wrap）；
		# · 桶µsN=贴图桶 place/unplace（含 reparent+MM 注册）当秒累计 µs；
		# · 延µsN=物理相末哨兵冲刷窗当秒累计 µs（对照实验键——语义见 diag_flush_sentinel）；
		# · 释N=演出/警示件 queue_free 秒差分（释放成本以计数做相关归因——_diag_dispatch_delta
		#   通用差分，拉取立基线/首拉返 0/钳负）；
		# · 敌弹N=team-1 活口当秒末直读（快N 同款非差分——diag_counts.enemy_bullets_live）；
		# · 拒N=保帧模式敌弹帽拒绝秒差分（boost_bullet_capped——帽触发深度直读）；
		# · 促%d=保帧模式状态键 0 关/1 开85%/2 开75%（PerfGovernor.boost_diag_state 单源）
		parts.append("死µs%d 警µs%d 桶µs%d 延µs%d 释%d 敌弹%d 拒%d 促%d" % [
			diag_bucket_window_us(&"deathfx"), diag_bucket_window_us(&"telegraph"),
			diag_bucket_window_us(&"bucket"), diag_bucket_window_us(&"flush"),
			_diag_dispatch_delta(&"perffx_qfree"),
			int(counts.get(&"enemy_bullets_live", 0)),
			_diag_dispatch_delta(&"boost_bullet_capped"),
			PerfGovernor.boost_diag_state()])
		# R271 P 轨十一键（追加在 促N 之后、尖峰段之前——行尾新段先例，既有子串逐位
		# 保持；qa_r228_diagfreeze 尾锚正则同批迁移，§0.2 声明）：
		# · 步µs/隙µs/延早µs/延渲µs/延峰µs=步闭环四分账+三哨兵（键义见 R271 累计器块注
		#   ——多步帧行四分账仅参考、判读以三哨兵为准）；
		# · 加N/摘N=SceneTree node_added/node_removed 秒计数；
		# · 绘µsN=自绘件 _draw() 当窗累计（&"draw" 桶——wrap 清单 grep 派生全量，
		#   verdict 表头披露）；
		# · 渲帧N=_process 调用秒计数；呈帧N=get_frames_drawn 秒差分（拉取立基线/
		#   首拉返 0；headless 无呈现=同源自洽型，数值判读只在真机行）；
		# · 渲峰msN.N=_process delta 当窗峰值（尖峰硬线 ≤36ms 判据源；≥渲ms 恒成立）。
		parts.append("步µs%d 隙µs%d 延早µs%d 延渲µs%d 延峰µs%d 加%d 摘%d 绘µs%d 渲帧%d 呈帧%d 渲峰ms%.1f" % [
			_diag_step_us, _diag_gap_us,
			diag_bucket_window_us(&"flush_early"), diag_bucket_window_us(&"flush_render"),
			_diag_flush_peak_us, _diag_node_added, _diag_node_removed,
			diag_bucket_window_us(&"draw"), _diag_proc_frames,
			_diag_frames_drawn_delta(), _diag_proc_peak_ms])
		# R286 九键（追加在 渲峰ms 之后、尖峰段之前——行尾新段先例，既有子串逐位保持；
		# R285 五键上墙=设计修订 v3 移交项 p0c 收口，段窗和四键=本批新增）：
		# · 命µs=R285 四分键（hit_collect 桶——弹 tick 收集段查询+窄相当秒累计）；
		# · 提µs=hit_flush 桶（_flush_hit_pairs 提交链当秒累计——与 R232 结µs 每结算均值
		#   口径不同源，键名避撞 R232 结µs）；
		# · 灭µs=death_flush 桶（死亡 fan-out 冲刷段——键名避撞 R269 死µs 死亡演出件键）；
		# · 回µs=recycle 桶（弹 _recycle→release 链）；ipµs=ip_pass 桶（ip 双遍历合计——
		#   生产谓词关〔sim30_effective false〕恒 0=预期非故障，真机判读勿当失效）；
		# · 段和µs/弹段µs/网段µs/敌段µs=GameLoop 段窗和累计器（十六段+entry+dispatch
		#   秒窗和与 grid_projectile/grid_rebuild/enemy 三段分键——单帧末值口径的窗口和
		#   补全；步µs−段和µs=步内未探针暗区直读键）。
		var _win_sum_v: Variant = p_gl.get("_stage_win_sum_us")
		var _win_proj_v: Variant = p_gl.get("_stage_win_proj_us")
		var _win_grid_v: Variant = p_gl.get("_stage_win_grid_us")
		var _win_enemy_v: Variant = p_gl.get("_stage_win_enemy_us")
		# R287 六段分键（追加在 敌段µs 之后）：vc86 定谳深载 弹+敌+网 仅占步 30-42%，
		# 其余散在未分窗段且尖峰归因 45/47 指向 跳——popup/player/fx/ui/other/dispatch
		# 六段秒窗分键补齐（与 R286 三分键同表同点累计，深载主刀瞄准面）。
		var _win_popup_v: Variant = p_gl.get("_stage_win_popup_us")
		var _win_player_v: Variant = p_gl.get("_stage_win_player_us")
		var _win_fx_v: Variant = p_gl.get("_stage_win_fx_us")
		var _win_ui_v: Variant = p_gl.get("_stage_win_ui_us")
		var _win_other_v: Variant = p_gl.get("_stage_win_other_us")
		var _win_dispatch_v: Variant = p_gl.get("_stage_win_dispatch_us")
		parts.append("命µs%d 提µs%d 灭µs%d 回µs%d ipµs%d 段和µs%d 弹段µs%d 网段µs%d 敌段µs%d 跳段µs%d 玩段µs%d 特段µs%d UI段µs%d 他段µs%d 派段µs%d" % [
			diag_bucket_window_us(&"hit_collect"), diag_bucket_window_us(&"hit_flush"),
			diag_bucket_window_us(&"death_flush"), diag_bucket_window_us(&"recycle"),
			diag_bucket_window_us(&"ip_pass"),
			int(_win_sum_v) if _win_sum_v != null else 0,
			int(_win_proj_v) if _win_proj_v != null else 0,
			int(_win_grid_v) if _win_grid_v != null else 0,
			int(_win_enemy_v) if _win_enemy_v != null else 0,
			int(_win_popup_v) if _win_popup_v != null else 0,
			int(_win_player_v) if _win_player_v != null else 0,
			int(_win_fx_v) if _win_fx_v != null else 0,
			int(_win_ui_v) if _win_ui_v != null else 0,
			int(_win_other_v) if _win_other_v != null else 0,
			int(_win_dispatch_v) if _win_dispatch_v != null else 0])
		if p_gl.has_method("diag_reset_stage_win_sums"):
			p_gl.call("diag_reset_stage_win_sums")
		# R206 秒内尖峰：stage_probe_us 逐帧重建看不见 1Hz 采样间隙的单帧尖峰（真机
		# 实测 UI 秒均 3ms 但单帧 36ms）——峰值 >25ms 追加标记（读取后清零）
		var peak: Dictionary = p_gl.get("stage_probe_us_peak")
		var peak_key: StringName = &""
		var peak_us := 0
		for pk in peak:
			if int(peak[pk]) > peak_us:
				peak_us = int(peak[pk])
				peak_key = pk
		if peak_us >= 25000:
			parts.append("尖峰%s%dms" % [DIAG_STAGE_TAGS.get(peak_key, "?"), int(round(float(peak_us) / 1000.0))])
		if p_gl.has_method("diag_reset_stage_peaks"):
			p_gl.call("diag_reset_stage_peaks")
	return stamp + "fps%d dc%d o%d | %s" % [fps, dc, obj, " ".join(parts)]


# R220 刀1（契约 §3.1）：十五段→十六段——原 &"card" 同键混合（开窗级联+溢出消化）拆
# card_open（开=_open_card_flow 全路径唯一计量）/ card_drain（消=_tick_merged_overflow
# PLAYING 期溢出批消化）两子键，插位不变（ui 之后、other 之前）。
# R235 搭车③注：&"dispatch" 段键（⑧前派发段）在 game_loop.stage_probe_us 内但不进
# 本表——行中段不印（行尾「派µs」键直读）；他键差分和与 debug_stats 段和均显式收录。
const DIAG_STAGE_ORDER: Array[StringName] = [
	&"player", &"player_mv", &"player_wp", &"shard", &"grid_rebuild", &"grid_projectile",
	&"enemy", &"wave", &"feel_shard", &"feel", &"fx", &"popup", &"ui",
	&"card_open", &"card_drain", &"other",
]

const DIAG_STAGE_TAGS: Dictionary = {
	&"player": "玩", &"player_mv": "移", &"player_wp": "火", &"shard": "碎",
	&"grid_rebuild": "网", &"grid_projectile": "弹",
	&"enemy": "敌", &"wave": "波", &"feel_shard": "磁", &"feel": "感",
	&"fx": "特", &"popup": "跳", &"ui": "UI",
	&"card_open": "开", &"card_drain": "消", &"other": "他",
}


func _diag_state(p_gl: Node) -> String:
	# 状态字（1 字符；GameConst.GameStatus 枚举序：BOOT/MENU/PLAYING/PAUSED/LEVEL_UP/GAME_OVER）
	if p_gl == null:
		return "-"
	match int(p_gl.get("state")):
		GameConst.GameStatus.BOOT:
			return "B"
		GameConst.GameStatus.MENU:
			return "M"
		GameConst.GameStatus.PLAYING:
			return "P"
		GameConst.GameStatus.PAUSED:
			return "S"
		GameConst.GameStatus.LEVEL_UP:
			return "L"
		GameConst.GameStatus.GAME_OVER:
			return "D"
	return "?"


func _diag_capacity() -> int:
	# R212：环形容量读口（diag_log_len 档 60/120/240/360 行，默认 240——缺键经默认表
	# 回退；clampi 兜脏档）。原 const DIAG_CAPACITY=900 删除改此动态读口。禁放 _ready
	# 读一次缓存：autoload 序 DebugStats(3) 早于 Meta(4)，彼时读口未就绪（:75 注同口径）；
	# _process/_diag_push 调用时点全部就绪。
	return clampi(int(Meta.settings("diag_log_len")), 60, 360)


func _diag_push(p_line: String) -> void:
	# R212：容量设置驱动。容量档变化后的首笔 push 触发一次重整（_relinearize_diag）：
	# 缩容=裁最旧只留最新 N 条、扩容=游标旋转转正，统一收敛到自洽态
	#（size<cap：cursor==size 纯追加态，物理序=时间序 / size==cap：[cursor]=最旧槽
	#  环形覆盖态）——两态互达不漏行不错位。
	var cap := _diag_capacity()
	if cap != _diag_ring_cap:
		_relinearize_diag(cap)
	if _diag_lines.size() < cap:
		_diag_lines.append(p_line)
	else:
		_diag_lines[_diag_cursor] = p_line
	_diag_cursor = (_diag_cursor + 1) % cap


func _relinearize_diag(p_cap: int) -> void:
	# R212：容量档变化重整（幂等——同档二次调用零位移）：
	# · 先转正：环形覆盖态（游标位=最旧）的物理序是旋转序，扩容后若不转正、追加段会
	#   接在旋转缝上（乱序）；纯追加态（cursor==size）本就时间序零动。
	# · 再裁旧：超容即从头裁最旧（remove_at(0)），只保留最新 N 条——旧条丢弃。
	# · 游标对齐：追加态 = size（续写尾端）；满环态 size==cap → 0（指向最旧槽）。
	var n := _diag_lines.size()
	if _diag_cursor > 0 and _diag_cursor < n:
		var rotated: Array[String] = []
		for i in range(n):
			rotated.append(_diag_lines[(i + _diag_cursor) % n])
		_diag_lines = rotated
	while _diag_lines.size() > p_cap:
		_diag_lines.remove_at(0)
	_diag_cursor = _diag_lines.size() % p_cap
	_diag_ring_cap = p_cap


func diag_export() -> Dictionary:
	# 导出入口（主菜单按钮调用）：{path, text}；文件名带版本（用户点名防老数据混流）。
	var ver := version_string()
	var header := "=== Infinite Fission 真机诊断日志 ===\n版本: %s | Godot %s\n设备: %s | 窗口 %s | 屏 %s\n渲染: %s (mobile覆写 %s) | stretch %s | physics %dHz | 追赶帽 %d\n采样 1Hz × %d 行环形 | 导出于会话 %s\n口径声明（R220）：段序=十六段（开=card_open 开窗级联 / 消=card_drain 溢出批消化——原卡键拆分）；模N=物理帧差分×1000÷实际采样墙钟窗，跨窗行（墙钟窗>1.5s，如选卡退出后首采）模值带 * 供判读剔除（vc26 模157-363 伪读数口径修正）；弹段探针每帧清零（diag 1Hz 读单帧末值）而 fps=Engine 平滑值——两者窗口错位，弹段读数与同帧 fps 不可直接互除对账；damage_resolved 派发时点=⑧ UI 段前统一保序批化（R220 刀11——跳字当帧起跳口径）；尾段读法（R220 修轮补）：结N=本秒伤害结算数差分（每命中µs 定标口=弹段ms×1000÷结N）/ 自N=自导池在场数（弹N 不含自导）/ 调N=调速器档 1低-3高（PerfGovernor）/ 变N=真采样驱动累计档变数（>0 才出现）；顺/冲/弃（R223 刀R）=结算预算顺延数/冲刷真结算数/诚实丢弃数（秒差分——深载 tier1-3 生效〔二cv#8 帧率：tier3 并档 tier2 同帽，原 tier≤2 恒缺席〕，判读口径：结N≈帽×模N 为预期稳态而非失效（R233 修2 口径更正：原「帽(48/96)×帧率」未含 30Hz 档——现 60Hz 档帽 48/96×模60〔96 档含 tier3〕、30Hz 档帽 96/192×模30），弃N 持续高=真实伤害卸载形态需回报）；模N 分段预期（R233 修2 补）：中载段恒 30=满频，深载 overrun 段 8-14=设计内降级形态（见 R233 设计决策1b，非 30Hz 刀失效）；位图R/翻N（R226）=跳字字形图集就绪 0/1（位图0=mobile 跳字 Label 回退态，dc 读数按旧路径解读）/满载装饰门翻转秒差分（>2/s=滞回震荡需回报）；补N（R227）=新局入口位图补烤毫秒一次性读数（>0=菜单停留不足由开局兜底执行，激活路径归因键）；裁N（R229）=弹池静载阀门一次性裁闲读数（>0=三重门 mobile∧帧率优先∧tier≤2 已触发裁闲，与 o 键对拍即定标 o 是否计隐藏静载；触发后下一采样行 >0 之后恒 0）；快N（R231）=玩家弹快路径活弹数（当秒末帧直读）；结µs（R232 T1b）=结算轴（resolve+冲刷）当秒每结算均值 µs（分子=结算段累计差分、分母=结N 同真源独立基线差分——R233 T0 修复：与结N 键同帧同窗各自拉取，修前复用结N 共享基线曾致读数=每秒累计 µs 需手动÷结N；真机单结 µs 直读键，vc37 判读与结算预算标定输入；反应通道与弹侧 ctx 构建/词条预聚合不在窗内）；插µs（R233 T1）=渲染帧插值写入每帧均值 µs（分子=渲染帧插值写入累计差分、分母=渲染帧数差分同窗均值——决策7 诊断先于行为刀，插值层 R233 T6 实施前恒 0=关态基线，实施后深载判据 ≤500µs/帧）；插模拟µs（R233 修轮）=模拟侧插值两遍历（帧入口恢复+帧末快照）当秒累计 µs（秒差分总量口径非每帧均值——快照 T7 无条件保鲜，谓词关/headless 态=快照遍历实际成本直读，恢复遍历同谓词零执行不计）；派deferredN/派dropN（R233 修轮）=派发帽超帽顺延数/过期窗前缀丢弃数秒差分（派发帽 60Hz 档 48/步、30Hz 档 96/步；两键独立差分基线——vc38 AC-2 派发条款与 DISPATCH 192 触发判据的真机取证口）；物步µsN（R235 搭车③/R237 修账）=物理相残差当窗每物理活跃渲染帧均值 µs（=Performance.TIME_PHYSICS_PROCESS 末步语义−同末步 GameLoop 段和，钳负——原「段和×步数」减项与末步监视器口径错配系 R237 桌面 A/B 四臂实证伪影已修；语义=引擎物理步+物理块 message_queue flush 执行的延迟调用〔⑧popup/敌死亡链 DeathPop/Telegraph/桶place/queue_free/⑦b fx——段探针量发射不量执行〕+其他节点物理相成本；R237 A/B 已排除物理空间 broadphase/配对/信号大头——大值嫌疑=延迟冲刷桶；多步帧早步不计=保守低估；headless 有值无意义；R244 修B：减项另含 entry 键（帧入口 glue 出残差）——与 vc53 前读数不可直接对拍，且 MENU 态预热已迁渲染轴〔修A〕菜单行读数自此≈0；R245 起物理侧仅 PLAYING 态采样：M/D/B 行物步µs 恒 0（=无样本，非读数），与 R244 前菜单行读数不可对拍；跨态伪影根除；R268 起 物步µs/他/余 三读数减项含 popup 段（popup tick 在物理帧内执行归我方段和——历史真机行与 R268 前不可对拍））；派µsN（R235 搭车③）=⑧段前派发段 dispatch_resolved_frame 末帧直读 µs（R235 前混入 UI 段——现独立分键，UI 段读数不含派发；探针关=0；R268 P1 起 mobile 升格反应大字排版并入 R212 tick 限批——显形滞后 ≤6 帧（60Hz 0.1s，顿帧期按帽累计；脏龄 ≥0.25s 超龄强制臂保底不饿死））；渲msN.N（R235 搭车③渲染轴）=当窗渲染帧耗时均值 ms（_process delta 累计÷帧数——自选均值口径；深载 fps≤16.6ms 预算线后帧率上限由渲染轴支配，R243 终点对账硬判据；headless 无 vsync/渲染 → 有值无意义）；挡N（R238）=格挡力场成功格挡秒差分（差分基线复用 _diag_dispatch_last 通用通道）；死µsN/警µsN/桶µsN/延µsN（R269 B 轨）=死亡链演出件（DeathPop/PoisonSplash pop/_release）/Telegraph 三件套创建挂树配置/贴图桶 place-unplace/物理相末哨兵冲刷窗的当秒累计 µs（秒窗桶——只加计时不改行为，与段和口径无双计非减项；延µs=我方物理步返回→message_queue 冲刷执行的延迟工作量上限对照键：延µs≈物步µs→延迟冲刷桶坐实，延µs≈0 而物步µs 大→引擎物理步嫌疑）；释N（R269）=演出/警示件 queue_free 秒差分（释放成本以计数做相关归因）；敌弹N（R269）=team-1 敌弹活口当秒末直读（快N 同款非差分）；拒N（R269）=保帧模式敌弹帽（320）拒绝秒差分（拒N 持续高=帽过紧回调信号）；促N（R269）=保帧模式状态键 0 关/1 开85%%/2 开75%%（boost_diag_state 单源——「模式没生效」报障预防）；校准行（R235 搭车④）=Phase0 六臂微基准（A 属性轴/B SoA 数组/C RefCounted/D local/E 逐弹方法/F 批处理）真机读数一次性行——菜单停留门后自动跑，臂Nµs/帧+比A/B+比E/F=真机数据化系数（每帧一迭代缓存冷口径，桌面紧循环档不外推）；R271 键（行尾追加在 促N 之后）：步µs/隙µs/延早µs/延渲µs/延峰µs=步闭环四分账+三哨兵（步µs=步入口→出口累计、隙µs=主哨兵执行→下一步入口=引擎物理服步/帧间其余工作、延早µs=步入口哨兵〔=整步+冲刷窗，延早−延≈步µs 自洽锚〕、延渲µs=_process 尾哨兵〔idle 相冲刷窗〕、延峰µs=当窗单次主哨兵延迟峰值——多步帧行四分账仅参考、判读以三哨兵为准）；加N/摘N=SceneTree node_added/node_removed 秒计数（池周转/演出件全量观测面）；绘µs=自绘件 _draw() 当窗累计（wrap 清单见 R271 verdict 表）；渲帧N=_process 调用秒计数；呈帧N=get_frames_drawn 秒差分（呈现帧率铁证——渲帧N≈60 且 呈帧N≈fps → 节拍解耦坐实，渲ms=节拍周期；headless 无呈现=同源自洽型，数值判读只在真机行）；渲峰ms=_process delta 当窗峰值（尖峰硬线 ≤36ms）；R286 键（行尾追加在 渲峰ms 之后）：命µs/提µs/灭µs/回µs/ipµs=R285 四分键+ip 桶当秒累计（探针关门内计时——命/提 关态自然 0；ipµs 生产谓词关〔插值层关〕恒 0=预期非故障勿当失效；提µs 与 R232 结µs 每结算均值口径不同源、灭µs 与 R269 死µs 死亡演出件键不同源）；段和µs/弹段µs/网段µs/敌段µs=十六段+entry+dispatch 秒窗累计和与 grid_projectile/grid_rebuild/enemy 三段分键（单帧末值口径的窗口和补全；步µs−段和µs=步内未探针暗区直读【R286 修轮边界披露：①仅连续 P 行可判读——步µs 无状态门全态累计而段和仅 PLAYING 累计，选卡/暂停跨态行（L 行、模带* 补采行）暗区虚高不判读；②段和丢状态迁移边界步表——PLAYING→升级/暂停迁移的最后一个完整步与 card_open 开窗级联段不入账（结构性低估非暗区）；③子集键 移/火 不入段和（玩段内含——与余/物步µs 减项口径对齐）】；弹段µs=④ 弹 tick+冲刷全段、含查询；非 PLAYING 态窗不累计读数 0）；R287 键（行尾追加在 敌段µs 之后）：跳段µs/玩段µs/特段µs/UI段µs/他段µs/派段µs=popup/player/fx/ui/other/dispatch 六段秒窗分键（与 R286 三分键同表同点累计——vc86 定谳深载〔敌90〕弹+敌+网仅占步 30-42%%、其余 58-70%% 散在未分窗段且尖峰归因 45/47 指向跳，六键=深载主刀瞄准面；跳段µs=popup 跳字管线、玩段µs=player 含移/火子键、UI段µs=ui 非跳字部分、派段µs=dispatch 结算派发〔与 派µs 单帧末值口径不同源此为窗和〕；R287 空场早退刀后清场/弹重窗 命µs≈0=刀生效预期态非故障（与 vc86 前空场读数 96-134k 不可对拍）；六键边界口径同段和µs（仅连续 P 行可判读/丢状态迁移边界步表/L→P 跨窗首帧一帧归属不判读）；非 PLAYING 态窗不累计读数 0）\n" % [
		ver,
		str(Engine.get_version_info().get("string", "?")),
		OS.get_name(),
		str(get_window().size) if get_window() != null else "?",
		str(DisplayServer.screen_get_size()),
		str(ProjectSettings.get_setting("rendering/renderer/rendering_method", "?")),
		str(ProjectSettings.get_setting("rendering/renderer/rendering_method.mobile", "?")),
		str(ProjectSettings.get_setting("display/window/stretch/mode", "?")),
		Engine.physics_ticks_per_second,
		Engine.max_physics_steps_per_frame,
		_diag_capacity(),
		Time.get_time_string_from_system(),
	]
	var body := "\n".join(_diag_lines) + "\n"
	# R271 P3：加N 类名直方图 top-8（一次性 dump 进导出头部——不进行键；按键字符串
	# 排序后取计数 top-8，§0.4 排序纪律）
	if not _diag_added_hist.is_empty():
		var hist_keys: Array = _diag_added_hist.keys()
		hist_keys.sort()                       # §0.4：按键字符串排序（确定序）
		var top: Array = []
		for k in hist_keys:
			top.append({"cls": k, "n": int(_diag_added_hist[k])})
		top.sort_custom(func(a, b):
			if int(a["n"]) != int(b["n"]):
				return int(a["n"]) > int(b["n"])
			return String(a["cls"]) < String(b["cls"]))
		var parts8: Array[String] = []
		for i in range(mini(8, top.size())):
			parts8.append("%s=%d" % [str(top[i]["cls"]), int(top[i]["n"])])
		body = "── 加N 类直方图 top-8（会话累计 node_added）── %s\n%s" % [" ".join(parts8), body]
	# R257 评审M3：事件段前置（独立环只存事件不被性能行冲刷——用户「失败后过几分钟
	# 才导出」的常态下，混合时间线环里的事件行可能已被冲走，独立环是取证主段）
	if not _diag_ev_lines.is_empty():
		body = "── 玩法事件（独立环 %d/%d 行——出发链/状态迁移/拒绝，不受性能行冲刷） ──\n%s\n────────\n%s" % [
			_diag_ev_lines.size(), DIAG_EVENT_CAP, "\n".join(_diag_ev_lines), body]
	var text := header + body
	var dt := Time.get_time_string_from_system().replace(":", "")
	var fname := "diag_%s_%s.txt" % [ver.replace(".", "_").replace("/", "_"), dt]
	var path := "user://%s" % fname
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f != null:
		f.store_string(text)
		f.close()
		diag_last_export_path = ProjectSettings.globalize_path(path)
	else:
		push_error("[DebugStats] 诊断日志写盘失败：%s" % path)
		diag_last_export_path = ""
	return {"path": path, "text": text}


func diag_clear() -> int:
	# R208：用户点名主动清空——早期少量怪的数据没必要导出（开局清一次，打到重载段
	# 再导出=缓冲只留有效取证窗）。返回清掉行数（按钮反馈用）；风暴差分基线不动
	# （每次采样自更新，清缓冲不影响 delta 口径）。
	# QA-257-2：返回值口径回退=时间线环行数（R208/R211 既有断言零触碰）；事件独立环
	# 同清但不计入返回（事件行数无既有消费者——B20/B21 直读环不走本口）
	var n := _diag_lines.size()
	_diag_lines.clear()
	_diag_cursor = 0
	_diag_ev_lines.clear()                        # R257 M3：事件独立环同清（口径一致）
	return n


func diag_copy_to_clipboard(p_text: String) -> bool:
	# 全文复制（导出对话框按钮；headless 无剪贴板后端 → 静默 false 不炸测试）
	var ds_name := DisplayServer.get_name()
	if ds_name == "headless" or ds_name == "":
		return false
	DisplayServer.clipboard_set(p_text)
	return true


# ── 帧阶段计时（GameLoop 帧序各阶段入口；§5.4 预算对账） ──────────
func begin_stage(p_stage: StringName) -> void:
	_stage_starts[p_stage] = Time.get_ticks_usec()


func end_stage(p_stage: StringName) -> void:
	var t0: int = _stage_starts.get(p_stage, 0)
	if t0 == 0:
		push_warning("[DebugStats] end_stage 无对应 begin_stage：%s" % p_stage)
		return
	_stage_starts.erase(p_stage)
	var ms := float(Time.get_ticks_usec() - t0) / 1000.0
	if not _stage_times.has(p_stage):
		var buf: Array[float] = []
		_stage_times[p_stage] = buf
		_stage_cursors[p_stage] = 0
	var buf: Array[float] = _stage_times[p_stage]
	if buf.size() < STAGE_BUFFER_CAPACITY:
		buf.append(ms)
	else:
		var cursor: int = _stage_cursors[p_stage]
		buf[cursor] = ms
		_stage_cursors[p_stage] = (cursor + 1) % STAGE_BUFFER_CAPACITY


# ── 计数器通道（池/管线/总线共用） ─────────────────────────────────
func count(p_key: StringName, p_delta: int = 1) -> void:
	_counters[p_key] = int(_counters.get(p_key, 0)) + p_delta


func get_counter(p_key: StringName) -> int:
	return int(_counters.get(p_key, 0))


# ── 帧报表（每 60 帧聚合；p50/p95/p99 + 阶段分解 + 池/事件快照） ──
func frame_report() -> Dictionary:
	var report := {
		"p50": percentile_ms(0.50),
		"p95": percentile_ms(0.95),
		"p99": percentile_ms(0.99),
		"stage_breakdown": _stage_breakdown(),
		"pools": _pool_snapshot(),
		"events": _event_snapshot(),
		"counters": _counters.duplicate(),
	}
	return report


func percentile_ms(q: float) -> float:
	# 帧时间分位数（秒 → 毫秒）；空缓冲返回 0
	if _frame_times.is_empty():
		return 0.0
	var sorted := _frame_times.duplicate()
	sorted.sort()
	var idx: int = clampi(int(floor(q * float(sorted.size()))), 0, sorted.size() - 1)
	return sorted[idx] * 1000.0


func _stage_breakdown() -> Dictionary:
	var out := {}
	for stage in _stage_times:
		var buf: Array[float] = _stage_times[stage]
		if buf.is_empty():
			continue
		var sorted: Array[float] = buf.duplicate()
		sorted.sort()
		var total := 0.0
		for v in sorted:
			total += v
		var p95_i: int = clampi(int(floor(0.95 * float(sorted.size()))), 0, sorted.size() - 1)
		out[stage] = {
			"samples": sorted.size(),
			"mean_ms": total / float(sorted.size()),
			"p95_ms": sorted[p95_i],
		}
	return out


func _pool_snapshot() -> Dictionary:
	# 池命中率/丢弃数聚合（ObjectPool.stats() 拉取；§5.5 埋点表）
	var out := {}
	for pool in _collect_pools():
		out[pool.pool_id] = pool.stats()
	return out


func _event_snapshot() -> Dictionary:
	# 事件派发计数快照（EventBus._dispatch_count 拉取；风暴告警 + 结算计数口径）
	var tree := get_tree()
	if tree == null or tree.get_root() == null:
		return {}
	var bus: Node = tree.get_root().get_node_or_null("EventBus")
	if bus == null:
		return {}
	var counts: Dictionary = bus.get("_dispatch_count")
	var out := {}
	for key in counts:
		out[key] = counts[key]
	return out


# ── CSV 导出（模式 B 回归与验收归档） ─────────────────────────────
func export_csv(p_path: String) -> void:
	var f := FileAccess.open(p_path, FileAccess.WRITE)
	if f == null:
		push_error("[DebugStats] CSV 导出失败：%s" % p_path)
		return
	f.store_line("section,key,value")
	var rep := frame_report()
	f.store_line("frame,p50_ms,%s" % str(rep["p50"]))
	f.store_line("frame,p95_ms,%s" % str(rep["p95"]))
	f.store_line("frame,p99_ms,%s" % str(rep["p99"]))
	for stage in rep["stage_breakdown"]:
		var info: Dictionary = rep["stage_breakdown"][stage]
		f.store_line("stage,%s.p95_ms,%s" % [stage, str(info["p95_ms"])])
		f.store_line("stage,%s.mean_ms,%s" % [stage, str(info["mean_ms"])])
	for key in rep["counters"]:
		f.store_line("counter,%s,%s" % [key, str(rep["counters"][key])])
	f.close()


# ── AC 断言（验收口径；Dev 断言开关关闭时恒真） ───────────────────
func assert_zero_instantiations() -> bool:
	# AC-14.1：运行期实例化计数 = 0（10 分钟 soak）
	if not dev_assertions:
		return true
	var ok := true
	for pool in _collect_pools():
		if pool.runtime_instantiate_count > 0:
			ok = false
			push_error("[DebugStats] AC-14.1 违例：池 %s 运行期实例化 %d 次"
				% [pool.pool_id, pool.runtime_instantiate_count])
	return ok


func assert_pools_clean() -> bool:
	# AC-14.3：池污染断言（取出/归还双向清洁 + 拒绝归还拦截）
	if not dev_assertions:
		return true
	var ok := true
	for pool in _collect_pools():
		if pool.pollution_count > 0 or pool.rejected_release_count > 0:
			ok = false
			push_error("[DebugStats] AC-14.3 违例：池 %s 污染 %d 次 / 拒绝归还 %d 次"
				% [pool.pool_id, pool.pollution_count, pool.rejected_release_count])
	return ok


# ── 内部：帧缓冲与池发现 ──────────────────────────────────────────
func _push_frame_time(p_seconds: float) -> void:
	if _frame_times.size() < FRAME_BUFFER_CAPACITY:
		_frame_times.append(p_seconds)
	else:
		_frame_times[_frame_cursor] = p_seconds
	_frame_cursor = (_frame_cursor + 1) % FRAME_BUFFER_CAPACITY


func _collect_pools() -> Array[ObjectPool]:
	# 场景树扫描发现 ObjectPool 实例（DebugStats 只读拉取，池不反向依赖；§1.2 依赖矩阵）
	var out: Array[ObjectPool] = []
	var tree := get_tree()
	if tree != null:
		_walk_pools(tree.get_root(), out)
	return out


func _walk_pools(node: Node, out: Array[ObjectPool]) -> void:
	if node is ObjectPool:
		out.append(node)
	for child in node.get_children():
		_walk_pools(child, out)
