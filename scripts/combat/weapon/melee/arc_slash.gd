# scripts/combat/weapon/melee/arc_slash.gd
# M-08 ArcSlash（架构 §2.8.5）：周期挥斩实体——固定角度弧形判定 + 消弹。
# R7：击退权移交霰弹枪（本武器 180px 强击退每刀推飞全屏怪 = 用户实测「闪退」根因）；
# R61 视觉（用户两轮反馈「怎么是个扇子」）：z_index 提层 + 实体刀形抡过（刀身/刃口/
# 护手/柄多边形旋转扫扇角，淡刀残影 + 刀尖短弧光）——R59 弧带方案铺满扇区读感仍是扇子。
# R65 追击者重做（用户重定义 W9）：中心 = 追击刀位（strike_center）、判定窗口放慢
#（0.15→0.34s——用户点名「动画慢点」）；判定口径（query_arc 半径/半角/上限/消弹）不变。
# · 判定窗口 SLASH_WINDOW（窗口外无判定，AC-06.3 ±1° 扇形口径）；朝向 = 开窗时刻
#   刀→目标方向（窗口期内固定不扫摆）。
# · 扇形判定：query_arc（中心角 facing、半角 arc_deg/2、半径 slash_radius）；
#   单斩目标上限 max_targets；同窗同目标单次（_struck 去重）。
# · 消弹（nullify=true，W9）：弧内敌方弹幕 → ProjectileBase.nullify() →
#   OnExpire(NULLIFIED) → 清零 → 弹池回收（AC-06.2 统一收束路径）。
# R243（w2-fengren，§2.1/§2.5/§3.1/§4.5/§6.4）：法器·旋风刀战斗内弯刀化——
# · blade_style 参数化（&"saber" 缺省 / &"greatsword"）+ blade_tint：saber = 深弯月
#   弧刃（刀背控制点加深、刃口 -Y 内收）青绿主填充 + 同色系刀背描线；greatsword =
#   刃身宽 1.6× + 护手十字加宽 + 暗金描边（暗黑底 + 金刃口，w2-melee W13 消费）。
#   残影 2 把与刀尖弧光逻辑保留（R61 :160-179 结构不动），弧光 20°→28°/宽 3.0→4.0
#   （仍仅本体后拖尾，不回退 R59 弧带扇面）。判定零改动：query_arc 扇形口径与
#   OrbitWeapon.SLASH_WINDOW 逐位不动——「视觉是刀在抡，判定是扇形范围」解耦契约保持。
# · 掷骰挡弹（§3.1）：spawn "block_chance"（缺省 -1 = 旧口径 nullify→1.0 否则 0.0，
#   桩夹具零位移）；tick 消弹条件 = 概率 > 0；逐弹 chance>=1.0 确定性 / randf()<chance
#   概率才 nullify()；新增 DebugStats bullet_parry 计数（与 bullet_nullified 并存），
#   emit_bullet_nullified 涟漪保持——W9（nullify=true）行为逐位不变恒 100%。
# · 元素附着钩子（§6.4，inert）：_slash_hit ON_HIT 派发后逐 attach_requests
#   apply_attach（host_elements = weapon._element_pool() 守卫输入；数组空=零行为）。
# · 子斩结构（§4.5 通道 B 载体侧，inert）：spawn "atk_mult"（缺省 1.0，_slash_hit
#   base_atk 乘区）与 "generation"（缺省 0）+ MAX_GENERATION=3 硬帽；窗末一次性
#   ON_EXPIRE 派发（tctx.melee=self）→ 消费 melee_split_request：本窗中心为原点、
#   facing±spread 均布开 count 道子斩窗（半径 ×0.55、atk_mult=inherit_ratio、
#   generation+1）；请求空 = 零行为（w2 词条臂入库前 inert）。
# · 击退快照（§2.5-4）：_slash_hit 击退 = spawn "knockback"（缺省 0.0）+ Σadd_knock
#   （weapon_base 平加池同源）——W9 不传键/快照 0 恒零位移。
# · 质变（w4-prime §7.2）：spawn "transcended"（贴图差驱动位）/ "echo_ratio"+"echo_delay"
#  （W9 碧涛旋舞同心回斩——窗末 0.18s 同心回斩一道：复用 w2-fengren 子斩机制
#   _open_child_slash，atk_mult=echo_ratio 0.5、半径 ×CHILD_RADIUS_RATIO、generation+1、
#   sweep_reverse 回扫读感；echo 子代不带回斩键 = 每斩恰一道不递归）。saber 质变 =
#   blade_tint 加深 + 第二道残影（前导双旋臂）；greatsword 质变 = 刃身再加宽 1.3× +
#   金色裂纹描线（W13 裂地斩黑金巨剑）。判定口径零改动。
# · 二cv#4（W9 五级卡帧排查——「质变切换路径显式失效/重铺受影响贴图」）：池槽重铺
#   （OrbitWeapon._respawn_slash_pool）已覆盖本体槽，但子斩派生路径（_open_child_
#   slash）spawn 键缺 "transcended"——质变后回斩/幻影子窗恒画基础形（贴图差旁路），
#   补传继承。
# · 二cv#5（W13 变色延迟——用户「选了元素，退出主菜单再回来才变颜色」）：blade_tint
#   仅 spawn 快照 → 绘制期改 _live_blade_tint() 实时读宿主 blend_element_color()
#  （选卡即变色）；快照字段保留作回落与测试读回口。greatsword 暗黑底+金刃口分支不动
#  （tint 仍只进渐变插值）。
# · 二cv#2（近战范围虚线——用户「近战的范围显示还是给个吧，虚线的」）：待机期（窗口
#   外）本体槽画分段短弧虚线（半径=slash_radius 判定真值、扇区=arc_deg——W13 质变
#   270° 随槽位字段；α 0.35、色=tint 提亮；fx_quality 0 档隐藏；无新节点）。
class_name ArcSlash
extends Node2D

const STYLE_SABER := &"saber"                 # 旋风刀式（缺省）：深弯月弧刃
const STYLE_GREATSWORD := &"greatsword"       # 阔剑式（w2-melee W13 消费）：宽刃巨剑
const SABER_TINT := Color(0.35, 0.92, 0.55)           # 青绿（旋风刀身份色，§2.1）
const GREATSWORD_TINT := Color(0.16, 0.15, 0.2)       # 暗黑底（§2.5）
const GREATSWORD_EDGE := Color(0.95, 0.78, 0.35)      # 金刃口（§2.5）
const GREATSWORD_OUTLINE := Color(0.52, 0.42, 0.18, 0.9)   # 暗金描边
const GREATSWORD_DEEP := Color(0.35, 0.28, 0.12, 0.95)     # 护手/柄暗金
const GREATSWORD_WIDTH_MULT := 1.6                    # 刃身宽 1.6×（§2.5）
const TIP_ARC_DEG := 28.0                             # 刀尖弧光角（R61 20° → R243 §2.1）
const TIP_ARC_WIDTH := 4.0                            # 弧光描线宽（3.0 → 4.0）
const CHILD_RADIUS_RATIO := 0.55                      # 子斩窗半径比（§4.5 通道 B）
const MAX_GENERATION := 3                             # 子斩代数硬帽（与 request_split 三重闸对齐）
# ── R243 §7.2 质变（w4-prime） ──
const ECHO_DELAY_DEFAULT := 0.18                      # 同心回斩缺省延迟 s（W9 碧涛旋舞键值）
const T2_TINT_DARKEN := 0.18                          # saber 质变 blade_tint 加深档（碧涛旋舞）
const T2_GS_WIDEN := 1.3                              # greatsword 质变刃身再加宽（裂地斩 1.3×）
const T2_GHOST_AHEAD := 2                             # 第二道残影对数（前导双旋臂——碧涛旋舞）
# ── 二cv#2 待机范围虚线（二cx#1 重做：全周圈 + 双描线——分段短弧 dash ~12px gap ~8px） ──
const RANGE_DASH_LEN_PX := 12.0                       # 虚线单段弧长 px
const RANGE_DASH_GAP_PX := 8.0                        # 虚线间隔弧长 px
const RANGE_DASH_ALPHA := 0.75                        # 亮面线透明度（二cx#1：0.35→0.75 对比度）
const RANGE_DASH_RIM_ALPHA := 0.55                    # 暗衬线透明度（亮底图可辨的保证层）
const RANGE_DASH_WIDTH := 2.0                         # 亮面线宽（暗衬 = 本值 +2）
# 二cy#1 剑体顶点表设计半径（blade_visual_scale 分母——表值刀尖 150/W9 L1 同源）
const BLADE_TABLE_R := 150.0

var slash_radius: float = 150.0
var arc_deg: float = 120.0                    # 扇形角
var facing: float = 0.0                       # 固定角度窗口中心（rad）
var window_left: float = 0.0                  # 判定窗口剩余（R65：0.34s）
var strike_center: Vector2 = Vector2.INF      # R65 刀位中心（INF = 未设 → 跟随宿主）
var max_targets: int = 8                      # 单斩目标上限
var knockback: float = 0.0                   # R243⑨：spawn 快照（缺省 0.0；W9 恒零位移）
var nullify: bool = false                     # 消弹开关（W9=true；旧口径派生源）
# ── R243 弯刀参数化与钩子（spawn 键，全部带缺省——旧调用方零位移） ──
var blade_tint: Color = SABER_TINT            # 主填充（⑩：显式键 > 元素混色 > 身份色）
var blade_style: StringName = STYLE_SABER     # &"saber" | &"greatsword"
var crystal: bool = false                     # R267 视觉刀：水晶配方风格键（spawn 传——
                                              # 激活还需元素池含非 KIN（live 判，选卡即变色
                                              # §2.3）；KIN/空池身份路径零改动 §2.2 豁免）
var block_chance: float = -1.0                # ⑥ 掷骰挡弹概率（-1 = 旧口径 nullify 派生）
var atk_mult: float = 1.0                     # ⑧ 子斩伤害比（缺省 1.0 恒等）
var generation: int = 0                       # ⑧ 子斩代数（缺省 0；硬帽 MAX_GENERATION）
# ── R243 §7.2 质变态（spawn 键，全部带缺省——旧调用方零位移） ──
var transcended: bool = false                 # 贴图差驱动位（saber 加深+前导残影 / greatsword 加宽+金裂纹）
var echo_ratio: float = 0.0                   # 同心回斩伤害比（0 = 禁用；W9 碧涛旋舞 0.5）
var echo_delay: float = ECHO_DELAY_DEFAULT    # 同心回斩延迟 s（0.18）
var sweep_reverse: bool = false               # 回扫视觉（回斩子窗 = 刀身反向扫过；判定不变）
var enemy_grid: SpaceGrid = null              # 注入（扇形判定）
var enemy_bullet_grid: SpaceGrid = null       # 注入（消弹查询；GameLoop 帧序③双网格）
var weapon: WeaponBase = null                 # 结算宿主（OrbitWeapon 注入）

var _struck: Dictionary = {}                  # 同窗已判定目标去重（uid -> true）
var _expire_fired: bool = false               # ⑧ 窗末 ON_EXPIRE 一次性闸（每窗重置）
var _child_slashes: Array[ArcSlash] = []      # ⑧ 本窗派生的子斩窗（由本实体驱动 tick）
var _echo_left: float = -1.0                  # §7.2 同心回斩倒计时（-1 = 未挂账；窗末挂账）
var _echo_center: Vector2 = Vector2.ZERO      # 回斩中心快照（= 本窗中心——同心）
var _echo_facing: float = 0.0                 # 回斩朝向快照（= 本窗 facing；sweep_reverse 回扫）
var _dash_shown: bool = false                 # 二cv#2 待机虚线已在画（切换帧去重——避免逐帧重绘）
var _dash_tint := Color(0.0, 0.0, 0.0, 0.0)   # 二cv#5 追补：待机虚线上帧绘制 tint（色变才补重绘的判定锚）
var _dash_radius: float = -1.0                # R245 §3.4-3：待机虚线上帧绘制半径（升级/乘区
                                              # 变化即重绘的判定锚；-1 = 从未绘制必重挂）
var _tint_gen: int = -1                       # 二cv 评审收口：tint 缓存的词条世代锚（TraitStack.runtime_generation）
var _tint_cache := Color(0.0, 0.0, 0.0, 0.0)  # 同上：世代未变时的 tint 直出缓存（零分配）
var _tint_elem: bool = false                  # R267 视觉刀：同缓存代的「元素池含非 KIN」位
                                              #（水晶路径激活判——与 tint 同源同代更新）
var _bc_gen: int = -1                         # R290：挡弹概率缓存的词条世代锚（TraitStack.runtime_generation）
var _bc_owner: int = 0                        # R290：同上——缓存归属宿主实例 id（换宿主即失效）
var _bc_cache: float = 0.0                    # R290：同上——世代/宿主未变时的直出值（免每拍聚合+call）
var _cand_buf: Array[Node2D] = []             # R188⑧：扇形判定候选拷贝缓冲——query_arc 返回
                                              # space_grid 内部缓冲（space_grid.gd:228 契约：
                                              # 不得跨查询持有），_slash_hit→管线 resolve 可能
                                              # 再查网格，本缓冲即调用方复制（R5 别名契约不破）
var _bullet_buf: Array[Node2D] = []           # R188⑧：消弹弧查询拷贝缓冲（契约同上——逐弹
                                              # nullify 广播链可能再触发查询）
var _tip_buf := PackedVector2Array()          # R188⑨：刀尖弧光顶点缓冲（resize+下标赋值复用；
                                              # draw_polyline 拷贝进 canvas item，共享安全）


func spawn(p_params: Dictionary) -> void:
	slash_radius = maxf(float(p_params.get("slash_radius", 150.0)), 1.0)
	arc_deg = clampf(float(p_params.get("arc_deg", 120.0)), 1.0, 360.0)
	max_targets = maxi(int(p_params.get("max_targets", 8)), 1)
	knockback = float(p_params.get("knockback", 0.0))       # R243⑨：缺省 0（旧 180 死参数退役）
	nullify = bool(p_params.get("nullify", false))
	block_chance = float(p_params.get("block_chance", -1.0))
	atk_mult = maxf(float(p_params.get("atk_mult", 1.0)), 0.0)
	generation = maxi(int(p_params.get("generation", 0)), 0)
	transcended = bool(p_params.get("transcended", false))
	echo_ratio = maxf(float(p_params.get("echo_ratio", 0.0)), 0.0)
	echo_delay = maxf(float(p_params.get("echo_delay", ECHO_DELAY_DEFAULT)), 0.0)
	sweep_reverse = bool(p_params.get("sweep_reverse", false))
	blade_style = StringName(String(p_params.get("blade_style", STYLE_SABER)))
	blade_tint = _resolve_blade_tint(p_params.get("blade_tint", null))
	crystal = bool(p_params.get("crystal", false))       # R267 视觉刀风格键（缺省 false——
	                                                      # 旧调用方/桩夹具零位移）
	window_left = 0.0
	facing = 0.0
	_struck.clear()
	_expire_fired = false
	_echo_left = -1.0
	_dash_shown = false
	_dash_radius = -1.0                          # R245 §3.4-3：重铺后首帧虚线必重绘（半径锚复位）
	_bc_gen = -1                                 # R290：重铺后挡弹概率缓存失效（换宿主/换构筑必重算）
	_clear_children()
	visible = false
	z_index = 5                                  # 敌/玩家之上（R7：原默认 z 被怪精灵压住）


func _resolve_blade_tint(p_explicit: Variant) -> Color:
	# ⑩ tint 层级：显式 "blade_tint" 键 > 元素混色（weapon.blend_element_color——
	# 元素池含非 KIN 时，w3-element 入库后混色生效）> blade_style 身份色
	#（saber 青绿 / greatsword 暗黑底）
	if p_explicit is Color:
		return p_explicit
	var identity: Color = GREATSWORD_TINT if blade_style == STYLE_GREATSWORD else SABER_TINT
	if weapon != null and is_instance_valid(weapon) \
			and weapon.has_method(&"blend_element_color") and weapon.has_method(&"_element_pool"):
		for e in weapon._element_pool():
			if int(e) != GameConst.Element.KIN:
				return weapon.blend_element_color()
	return identity


func open_window(p_facing: float, p_center: Vector2 = Vector2.INF,
		p_radius: float = -1.0) -> void:
	# 挥斩窗口开启（持续 SLASH_WINDOW；窗口中心固定于开窗时刻朝向）。
	# R65：p_center = 刀位世界中心（追击开砍——中心从玩家移到刀，判定口径不变）；
	# p_radius > 0 = 本窗判定半径（巨刃乘区后的面板值）。缺省 → 旧口径（跟随宿主）。
	facing = p_facing
	strike_center = p_center
	if p_radius > 0.0:
		slash_radius = p_radius
	window_left = OrbitWeapon.SLASH_WINDOW
	_struck.clear()
	_expire_fired = false
	visible = true
	queue_redraw()


func tick(p_game_delta: float, p_center: Vector2) -> void:
	# 窗口内：扇形判定（query_arc）+ 击退 + 掷骰消弹；窗口外无判定。
	# ⑧：子斩窗由本实体驱动——本体窗末后仍须续驱子代（否则 gen1 窗冻结永不判定），
	# 故 _tick_children 置于窗口早退之外（本体自身窗口外零判定语义不变）。
	if window_left > 0.0:
		# R65：刀位开窗后中心固定在刀位（不随玩家移动）；宿主中心口径保留给旧调用方
		var center := strike_center if strike_center != Vector2.INF else p_center
		# R10 根因修复：本节点是武器（玩家子节点）的子节点——position 为局部坐标，
		# 此前直接塞 muzzle_position() 全局值 → 视觉画到屏幕外（判定用全局所以只有「虚空伤害」）
		position = weapon.to_local(center) if weapon != null and is_instance_valid(weapon) 		else center
		window_left = maxf(window_left - p_game_delta, 0.0)
		_judge_arc(center)
		var chance := _bullet_block_chance()         # ⑥：>0 才查询掷骰（0 = 零消弹零网格开销）
		if chance > 0.0 and _nullify_due():
			_nullify_enemy_bullets(center, _nullify_fold(chance))
		if window_left <= 0.0 and not _expire_fired:
			# ⑧ 窗末一次性 ON_EXPIRE（§4.5 通道 B 载体侧）+ melee_split_request 消费
			_expire_fired = true
			_dispatch_window_expire(center)
			_arm_echo(center)                        # §7.2 同心回斩挂账（窗末一次性）
		_dash_shown = false                     # 二cv#2：窗口内容回归，虚线切换帧重挂
		queue_redraw()
	elif _range_dash_active():
		# 二cv#2 待机范围虚线：本体槽窗口外保持可见（窗口内刀本体在扫，即范围的动态
		# 演示；窗口外补静态虚线弧）。锚随宿主 muzzle 逐 tick 平移——位移动不换绘制
		# 内容（局部系不变），queue_redraw 仅可见态/首帧切换时一次。
		# 二cv#5 追补：待机期选元素卡 → _live_blade_tint 变色须即刻换色——原 _dash_shown
		# 去重把重绘吞到下一次窗开/闭切换帧（虚线色滞后；刀本体窗口内绘制期实时取色
		# 不受影响）。比较上帧 tint，变了才多一次重绘，去重纪律不破。
		# R245 §3.4-3 追补：半径与上次绘制值不同也触发重绘——升级/乘区变化后虚线圈
		# 当帧刷新，不再保留最长一个冷却周期的陈旧圈（OrbitWeapon.level_up 不重铺
		# _slash_pool，slash_radius 快照陈旧；_draw_range_dash 画的是 weapon live
		# effective 真值，重绘判定须与绘制同源比半径）。
		position = weapon.to_local(weapon.muzzle_position())
		var live_tint := _live_blade_tint()
		var live_r := _range_dash_radius()
		if not visible or not _dash_shown or live_tint != _dash_tint \
				or absf(live_r - _dash_radius) > 0.05:
			visible = true
			_dash_shown = true
			_dash_tint = live_tint
			_dash_radius = live_r
			queue_redraw()
	elif visible:
		visible = false
		queue_redraw()
	_tick_children(p_game_delta, p_center)
	_tick_echo(p_game_delta)                         # §7.2：回斩倒计时（窗闭后仍须推进）


func _bullet_block_chance() -> float:
	# ⑥ 统一掷骰口（§3.1）：spawn 快照 >= 0 优先（W13 传 melee.block_chance 快照）；
	# 缺省 -1 = 旧口径——weapon 真件在侧回落 weapon.bullet_block_chance()（nullify
	# 优先 1.0 + add_block 池即时聚合；W9 恒 1.0 行为逐位不变），无宿主回落 nullify。
	# R290 修轮（vc89 判读：武9µs 占整步 32%）：宿主回落路径按「词条世代 + 宿主实例」缓存
	# 逐拍税（weapon.call 动态派发 + trait_stack.aggregate_panel 全量聚合——W13 概率消弹
	# 非 nullify 路径每拍全量聚合是真税；W9 早退路径也免掉每拍一次 call）。世代 +1
	#（attach/取优/质变）或换宿主即下次调用重取——取值与逐拍直算逐位同源（_live_blade_tint
	# 同款锚）。无 trait_stack 的宿主（桩/旧夹具）不缓存＝直算，行为逐位不变。
	if block_chance >= 0.0:
		return clampf(block_chance, 0.0, 1.0)
	if weapon != null and is_instance_valid(weapon) \
			and weapon.has_method(&"bullet_block_chance"):
		var ts: Variant = weapon.get("trait_stack")
		if ts is TraitStack:
			var gen: int = int((ts as TraitStack).runtime_generation)
			var owner: int = weapon.get_instance_id()
			if gen == _bc_gen and owner == _bc_owner:
				return _bc_cache
			var out := clampf(float(weapon.call(&"bullet_block_chance")), 0.0, 1.0)
			_bc_gen = gen
			_bc_owner = owner
			_bc_cache = out
			return out
		return clampf(float(weapon.call(&"bullet_block_chance")), 0.0, 1.0)
	return 1.0 if nullify else 0.0


var _nullify_ctr: int = 0     # R291 峰值刀：深载消弹查询半频相位（0=查询拍）


func _nullify_due() -> bool:
	# R291 峰值刀：深载期敌弹网格查询隔执行拍一次（查询频次 ×0.5）；boost 关/deep
	# 关 → 恒真（逐拍查询，关态逐位不变）。相位只在深载期翻转——闩解除即刻恢复逐拍。
	if not PerfGovernor.deep_load():
		return true
	_nullify_ctr = 1 - _nullify_ctr
	return _nullify_ctr == 0


func _nullify_fold(p_c: float) -> float:
	# R291：半频折算——两拍合一概率 1−(1−p)²（R289 W8 挡弹同族先例）。W9 nullify
	# 恒 1.0 → 折算不变（纯省查询）；关态原值直传。
	if PerfGovernor.deep_load():
		return 1.0 - (1.0 - p_c) * (1.0 - p_c)
	return p_c


func _judge_arc(p_center: Vector2) -> void:
	# 扇形判定：query_arc（半径/半角/中心角）→ 上限内逐目标结算 + 击退
	# R243 判定零改动：口径与 SLASH_WINDOW 逐位不动（§2.1 解耦契约）
	# R188⑧：候选拷贝进成员缓冲（原裸新建 Array[Node2D] 每帧常量税；挥斩窗 0.34s 内
	# ≈20 帧 × 池槽驱动）——复制语义保持（结算链内内部缓冲会被再查覆写）
	if enemy_grid == null or weapon == null:
		return
	_cand_buf.clear()
	_cand_buf.append_array(enemy_grid.query_arc(p_center, slash_radius,
		facing, deg_to_rad(arc_deg) * 0.5))
	var hit := 0
	# R291 峰值刀：深载命中帽减半——命中管线是事件率税（build_damage_context+词条
	# 派发每命中数百 µs，dt 折算省不掉；vc89 真机 武9µs 占整步 32-43%），帽减半=该
	# 税按扇内候选溢出程度折半。DPS 披露：溢出时 0~50%（被帽截断目标不入 _struck，
	# 同窗后续拍仍可命中——跨拍补偿；候选 ≤ 帽半时零损失零节省）。关态原值逐位不变。
	var cap := max_targets
	if PerfGovernor.deep_load():
		cap = maxi(1, cap >> 1)
	for target in _cand_buf:
		if hit >= cap:
			break
		if target == null or bool(target.get("dead")):
			continue
		var uid := int(target.get("uid"))
		if _struck.has(uid):
			continue
		_struck[uid] = true
		_slash_hit(target, p_center)
		hit += 1


func _slash_hit(p_target: Node2D, p_center: Vector2) -> void:
	# 挥斩结算（武器面板快照展开 → 管线；§4.4 同构时序）
	var ctx := weapon.build_damage_context(p_target)
	ctx.base_atk *= atk_mult                     # ⑧ 子斩伤害比（缺省 1.0 恒等）
	var tctx := TraitContext.new()
	tctx.event = GameConst.TraitEvent.ON_HIT
	tctx.weapon = weapon
	tctx.melee = self
	tctx.target = p_target
	tctx.damage_ctx = ctx
	tctx.host_elements = weapon._element_pool()  # ⑦ 宿主元素全集（§6.4 守卫输入；空池=无限制）
	if weapon.trait_stack != null:
		for pool in weapon.trait_stack.collect_mult_pools(tctx):
			ctx.mult_pools.append(pool)
	weapon.inject_vuln_pool(ctx, p_target)
	if weapon.trait_stack != null:
		weapon.trait_stack.dispatch(GameConst.TraitEvent.ON_HIT, tctx)
	var result: DamageResult = null
	if weapon.damage_pipeline != null:
		result = weapon.damage_pipeline.call(&"resolve", ctx)
	# 落血口径双轨（同 weapon_base.settle_aoe 审查修复）：真件 DamagePipeline 九步 9b
	# 在 resolve 内部已 take_result 落血（_apply_to_target——killed 判定/死亡广播唯一
	# 执行点），本侧再落血即挥斩伤害 ×2；透传桩 resolve 只算不落血，落血职责在调用
	# 方（pkg2/pkg3 桩用例锁定口径，保持不变）。管线为 null 时 result 为 null，本就不落血。
	if result != null and not (weapon.damage_pipeline is DamagePipeline) \
			and p_target.has_method(&"take_result"):
		p_target.call(&"take_result", result)
	# ⑦ 元素附着消费（§6.4，inert）：逐 attach_requests apply_attach（数组空=零行为；
	# 快照取当跳结算结果——免疫怪拒附着在 apply_attach 内部自带）
	if weapon.elemental != null and not tctx.attach_requests.is_empty():
		for request in tctx.attach_requests:
			weapon.elemental.call(&"apply_attach", p_target,
				int(request.get("element", 0)), float(request.get("value", 0.0)),
				{"snapshot": result.final_value if result != null else 0.0})
	_apply_knockback(p_target, p_center)
	DebugStats.count(&"arc_slash_hit")


func _apply_knockback(p_target: Node2D, p_center: Vector2) -> void:
	# ⑨ 击退（§2.5-4）：终值 = spawn "knockback" 快照 + Σadd_knock（weapon_base
	# .knockback_force 同源平加池）——W9 快照恒 0 且平加池词条不上法器 → 零位移逐位
	# 不变；W13（w2-melee）spawn 传 melee.knockback 快照后 MEC_KNOCK 自动生效。
	if p_target == null or not is_instance_valid(p_target):
		return
	var total := knockback
	if weapon != null and is_instance_valid(weapon) and weapon.trait_stack != null:
		total += float(weapon.trait_stack.aggregate_panel().get("add_knock", 0.0))
	if total <= 0.0:
		return
	var to_t: Vector2 = p_target.global_position - p_center
	if to_t.length() <= 1.0:
		return
	if p_target.has_method(&"knockback"):
		p_target.call(&"knockback", to_t.normalized() * total)


func _nullify_enemy_bullets(p_center: Vector2, p_chance: float) -> void:
	# ⑥ 弧内敌方弹掷骰消弹（§3.1）：chance >= 1.0 确定性（W9 恒此臂——行为逐位不变）
	# / randf() < p_chance 概率挡弹；统一 OnExpire(NULLIFIED) 收束（AC-06.2）；
	# bullet_parry 新计数与 bullet_nullified 并存；emit_bullet_nullified 涟漪保持。
	# R188⑧：同 _judge_arc 拷贝契约（成员缓冲零新建）
	# R245 §3.3 查询半径双轨：nullify 确定性消弹（W9/W11/W12 法器族）= slash_radius
	# 全额旧口径逐位不变；概率挡弹（W13 型，not nullify）= OrbitWeapon.BLOCK_RADIUS_
	# TABLE[weapon.level]（法器范围基准×40%——挡弹域 < 攻击圈层级关系落定）。weapon
	# 缺席的概率桩回落全额（无宿主即无 live 口，chance 须经 nullify 才 >0，本分支不可达）。
	if enemy_bullet_grid == null:
		return
	var query_r := slash_radius
	if not nullify and weapon != null and is_instance_valid(weapon):
		query_r = OrbitWeapon.block_radius_for(int(weapon.level))
	_bullet_buf.clear()
	_bullet_buf.append_array(enemy_bullet_grid.query_arc(p_center, query_r,
		facing, deg_to_rad(arc_deg) * 0.5))
	for bullet in _bullet_buf:
		if bullet is ProjectileBase and (bullet as ProjectileBase).team == 1:
			if p_chance >= 1.0 or randf() < p_chance:
				(bullet as ProjectileBase).nullify()
				DebugStats.count(&"bullet_parry")
				DebugStats.count(&"bullet_nullified")
				EventBus.emit_bullet_nullified((bullet as ProjectileBase).global_position)


# ── ⑧ 子斩结构（§4.5 通道 B 载体侧；w2 词条臂入库前请求恒空 = 零行为） ──
func _dispatch_window_expire(p_center: Vector2) -> void:
	# 窗末一次性 ON_EXPIRE 派发（tctx.melee=self）→ 消费 melee_split_request
	if weapon == null or not is_instance_valid(weapon) or weapon.trait_stack == null:
		return
	if not weapon.trait_stack.has_event_hook(GameConst.TraitEvent.ON_EXPIRE):
		return                                   # R210 无挂钩直通同口径（省分配）
	var tctx := TraitContext.new()
	tctx.event = GameConst.TraitEvent.ON_EXPIRE
	tctx.weapon = weapon
	tctx.melee = self
	weapon.trait_stack.dispatch(GameConst.TraitEvent.ON_EXPIRE, tctx)
	_open_child_slashes(p_center, tctx.melee_split_request)


func _open_child_slashes(p_center: Vector2, p_request: Dictionary) -> void:
	# 子斩窗派生：本窗中心为原点、facing±spread 均布 count 道；半径 ×CHILD_RADIUS_RATIO、
	# atk_mult=inherit_ratio、generation+1。请求空/零 count = 零行为；代数硬帽
	# MAX_GENERATION=3 拒绝（与 request_split 三重闸对齐）。
	var count := int(p_request.get("count", 0))
	if count <= 0:
		return
	if generation + 1 > MAX_GENERATION:
		DebugStats.count(&"split_rejected_generation")
		return
	var spread := deg_to_rad(absf(float(p_request.get("spread_deg", 0.0))))
	var ratio := float(p_request.get("inherit_ratio", 0.0))
	for i in range(count):
		var child_facing := facing
		if count > 1:
			child_facing = facing - spread + 2.0 * spread * float(i) / float(count - 1)
		_open_child_slash(p_center, child_facing, ratio)


func _open_child_slash(p_center: Vector2, p_facing: float, p_ratio: float,
		p_reverse: bool = false) -> void:
	# 单道子斩窗（宿主在侧挂武器——与本体同局部系；独立夹具回落父节点）。
	# R243 §7.2：p_reverse = 同心回斩读感（刀身反向扫过——判定口径对称不变）；
	# 子代不带回斩键（echo_ratio 缺省 0）——每斩恰一道不递归。
	var host: Node = weapon if (weapon != null and is_instance_valid(weapon)) else get_parent()
	if host == null:
		host = self
	var child := ArcSlash.new()
	child.name = "ArcSlashChild%d" % (generation + 1)
	host.add_child(child)
	child.weapon = weapon
	child.enemy_grid = enemy_grid
	child.enemy_bullet_grid = enemy_bullet_grid
	child.spawn({
		"slash_radius": maxf(slash_radius * CHILD_RADIUS_RATIO, 1.0),
		"arc_deg": arc_deg,
		"max_targets": max_targets,
		"knockback": knockback,
		"nullify": nullify,
		"block_chance": block_chance,
		"blade_style": blade_style,
		"blade_tint": blade_tint,
		"crystal": crystal,               # R267 视觉刀：子斩/回斩（echo 双武装）继承水晶
		                                  # 风格键——二cv#4「子代贴图差旁路」同教训（质变
		                                  # 键漏传致回斩恒画基础形，本键不重蹈）
		"transcended": transcended,       # 二cv#4：质变贴图差随子斩/回斩继承——此前子代
		                                  # 恒基础形（质变后不刷新的旁路字段；echo 键仍缺省
		                                  # = 子代不回斩，防递归口径不变）
		"atk_mult": p_ratio,
		"generation": generation + 1,
		"sweep_reverse": p_reverse,
	})
	child.open_window(p_facing, p_center)
	_child_slashes.append(child)


# ── §7.2 同心回斩（W9 碧涛旋舞：窗末 0.18s 同心回斩一道，atk_mult=echo_ratio） ──
func _arm_echo(p_center: Vector2) -> void:
	# 窗末回斩挂账（每窗恰一次）：echo_ratio<=0（未质变/无键）或 gen≠0（子斩窗不回斩
	# ——「每斩后一道」的本体口径 + 防递归）时不挂账。
	if echo_ratio <= 0.0 or generation != 0:
		return
	_echo_left = echo_delay
	_echo_center = p_center                       # 同心：回斩中心 = 本窗中心
	_echo_facing = facing


func _tick_echo(p_game_delta: float) -> void:
	# 回斩倒计时推进（窗闭后仍走——tick 尾部常驻段）；到期即开一道同心回斩子窗
	#（复用 _open_child_slash：半径 ×0.55 / atk_mult=echo_ratio / gen+1 / 回扫读感）。
	if _echo_left < 0.0:
		return
	_echo_left -= p_game_delta
	if _echo_left > 0.0:
		return
	_echo_left = -1.0                             # 先销账（到期帧恰开一道）
	_open_child_slash(_echo_center, _echo_facing, echo_ratio, true)


func _tick_children(p_game_delta: float, p_center: Vector2) -> void:
	# 子斩窗推进（不入宿主 _slash_pool——本实体自驱，判定/消弹/窗末递归同构）
	for child in _child_slashes:
		if child != null and is_instance_valid(child):
			child.tick(p_game_delta, p_center)


func _clear_children() -> void:
	for child in _child_slashes:
		if child != null and is_instance_valid(child):
			if child.is_inside_tree():
				child.queue_free()
			else:
				child.free()
	_child_slashes.clear()


func _reset_state() -> void:
	# 清零契约（武器回收期）
	window_left = 0.0
	_struck.clear()
	_expire_fired = false
	_echo_left = -1.0
	_dash_shown = false
	visible = false


func _draw() -> void:
	# R271 P4：绘µs wrap（自绘件 _draw 计时入 &"draw" 桶——只加计不改行为；
	# 原体迁 _draw_r271，早退 return 由委托面兜底不漏收口）
	DebugStats.bucket_begin(&"draw")
	_draw_r271()
	DebugStats.bucket_end(&"draw")


func _draw_r271() -> void:
	# 二cv#2 分流：窗口内 = 实体刀形抡过（_draw_slash_window——范围由刀扫过动态演示）；
	# 窗口外 = 本体槽待机范围虚线弧（_draw_range_dash——静态预览）。
	if not visible:
		return
	if window_left > 0.0:
		_draw_slash_window()
	elif _range_dash_active():
		_draw_range_dash()


func _draw_slash_window() -> void:
	# 挥斩视觉（R61 二次重做——用户复反馈「不是个刀吗，怎么是个扇子」：R59 弯月弧带
	# 方案中主体+三道拖尾弧相邻重叠，半透明弧带几乎铺满 120° 扇区，读感仍是扇子）。
	# 现 = **实体刀形抡过**：刀身多边形绕中心旋转扫过扇角，2 把淡刀残影给运动读感，
	# 刀尖拖短弧光表速度；判定仍为 query_arc 扇形（视觉与判定口径解耦——视觉是刀在抡，
	# 判定是扇形范围）。R243：刀形/配色参数化（blade_style/blade_tint，§2.1/§2.5），
	# 残影 2 把与刀尖弧光逻辑保留（R61 结构不动；弧光 28°/宽 4.0 §2.1 强化）。
	var half := deg_to_rad(arc_deg) * 0.5
	var progress := clampf(1.0 - window_left / OrbitWeapon.SLASH_WINDOW, 0.0, 1.0)
	# 二cy#1 剑体随判定半径缩放：顶点表按 150px 设计半径固化（W13 半径 190→260 再乘
	# 巨刃/广域乘区可达 300+——刀尖 150px 恒定=视觉只有判定圈六成，「没人也攻击/大小
	# 到顶」读感根因）。视觉缩放与 slash_radius 同源（判定真值经 open_window 注入快照）
	# =刀尖贴虚线圈；0.8 下限防桩半径过小时剑形糊成一团，3.4 上限防极端堆叠出屏。
	var bscale := blade_visual_scale()
	var bvec := Vector2(bscale, bscale)
	# §7.2 回扫读感：sweep_reverse（同心回斩子窗）进度镜像——刀身反向扫过（判定对称不变）
	var eff_p := (1.0 - progress) if sweep_reverse else progress
	var sweep := facing - half + 2.0 * half * clampf(eff_p * 1.15, 0.0, 1.0)
	# 残影：2 把淡刀（角度滞后拉开间距不叠本体、α 递减；填充+描边保证**刀形轮廓**可辨
	# ——纯低透明填充会糊成弧形色带，正是「读感像扇子」的残影来源）
	# R267 视觉刀：水晶路径档0 残影砍半（2→1，§2.5-4 降档矩阵）；KIN/身份路径不
	# 参与降档（本就零增量——§2.5-4 尾注）。
	for k in range(1 if (_crystal_visual_on() and _fx_quality() == 0) else 2):
		var tp := eff_p - 0.16 * float(k + 1)
		if tp <= 0.0:
			continue
		var ta := facing - half + 2.0 * half * clampf(tp * 1.15, 0.0, 1.0)
		draw_set_transform(Vector2(), ta, bvec)
		var ga: float = [0.34, 0.16][k]
		_draw_blade(Color(0.62, 0.85, 1.0, ga), Color(0.82, 0.94, 1.0, minf(ga * 1.9, 0.7)), false)
	# §7.2 第二道残影（碧涛旋舞「双旋臂」）：进度前方两把淡刀（加深 tint）——与拖尾残影
	# 合成双臂旋读感；greatsword 不加（W13 质变贴图差 = 加宽+金裂纹）
	if transcended and blade_style != STYLE_GREATSWORD:
		for k in range(T2_GHOST_AHEAD):
			var tf := eff_p + 0.16 * float(k + 1)
			if tf >= 1.0:
				continue
			var tb := facing - half + 2.0 * half * clampf(tf * 1.15, 0.0, 1.0)
			draw_set_transform(Vector2(), tb, bvec)
			var gb: float = 0.30 - 0.12 * float(k)
			# R267 视觉刀：水晶路径前导残影改水晶亮核色（旧 _t2_fill 加深档
			# T2_TINT_DARKEN 正是 §2.1 棕链第 4 环——质变改「更亮」不回棕；
			# α 沿用 gb 口径，KIN 路径 _t2_fill() 逐位不动）
			var ghost_fill: Color = _t2_fill()
			if _crystal_visual_on():
				ghost_fill = CrystalBladeFactory.layer_color(_live_blade_tint(),
					transcended, _fx_quality(), 2)
				ghost_fill.a = 1.0
			_draw_blade(ghost_fill, Color(0.62, 0.85, 1.0, gb), false)
	# 本体刀（顶点渐变：刀背深色 → 刃口亮，R243 配色 blade_tint 主填充；质变 saber 加深）
	draw_set_transform(Vector2(), sweep, bvec)
	var line: Color = GREATSWORD_EDGE if blade_style == STYLE_GREATSWORD \
		else Color(1.0, 1.0, 1.0, 0.95)
	_draw_blade(_t2_fill(), line, true)
	draw_set_transform(Vector2(), 0.0, Vector2.ONE)
	# 刀尖拖出的短弧光（R243 ④：28°、宽 4.0——仍仅本体后拖尾；不再全弧描边）
	# R188⑨：顶点缓冲成员复用（原每帧新建+append——挥斩窗 ≈20 帧常量税；draw_polyline
	# 拷贝进 canvas item，缓冲共享安全）
	_tip_buf.resize(5)
	for i in range(5):
		var a := sweep - deg_to_rad(TIP_ARC_DEG) + deg_to_rad(TIP_ARC_DEG) * float(i) / 4.0
		_tip_buf[i] = Vector2(cos(a), sin(a)) * (slash_radius * 0.97)
	draw_polyline(_tip_buf, Color(1.0, 1.0, 1.0, 0.4), TIP_ARC_WIDTH, true)


func _range_dash_active() -> bool:
	# 二cv#2 待机虚线显示条件：零代（子斩/回斩窗为瞬态不画）+ 宿主在侧 + 本体槽
	#（weapon.arc_slash == self——W9 多刀池/幻影斩追加槽各画一条会叠影，只画本体）
	# + 近战类（二cx#3：法器 talisman 不画——用户「2个法器也不是虚线范围吧」双圈根因
	#   =W9 碧涛旋舞 weapon_class=talisman 走本机制也在画；法器攻击体是追击/飞出形态，
	#   玩家位虚线圈不指示其真实攻击范围。缺省 weapon_class=melee 保旧夹具口径）
	# + fx_quality 非 0 档（低档隐藏）。
	if generation != 0:
		return false
	if weapon == null or not is_instance_valid(weapon):
		return false
	if weapon.get("arc_slash") != self:
		return false
	var wdata: Variant = weapon.get("data")
	if wdata != null:
		var mseg: Variant = wdata.get("melee")
		if mseg is Dictionary \
				and String((mseg as Dictionary).get("weapon_class", "melee")) != "melee":
			return false
	return _fx_quality() > 0


func _fx_quality() -> int:
	# 特效质量档（elemental_fx_layer 同口径镜像：钳 [0,2] + mobile 降档——Meta 单一真源）
	var q := clampi(int(Meta.settings("fx_quality")), 0, 2)
	if OS.has_feature("mobile"):
		q = mini(q, 1)
	return q


func _live_blade_tint() -> Color:
	# 二cv#5 变色延迟修复：blade_tint 仅 spawn 快照（⑩ 层级解析结果——保留作测试读回
	# 口与回落），绘制期从宿主元素池实时取色（blend_element_color）——选卡即变色，
	# 不再等实体重铺。空池/无宿主回落快照（= 身份色或显式键）。
	# 二cv 评审收口：_element_pool() 每调新建数组（逐帧常量税——R188/R225 先例），
	# 按宿主 TraitStack.runtime_generation 脏标缓存：attach/取优/质变即世代 +1 →
	# 下次调用重取（verify「二cv#5 追补」同帧跟随契约保持）；世代不变缓存直出。
	if weapon != null and is_instance_valid(weapon) \
			and weapon.has_method(&"blend_element_color") and weapon.has_method(&"_element_pool"):
		var gen: int = -1
		var ts: Variant = weapon.get("trait_stack")
		if ts is TraitStack:
			gen = int((ts as TraitStack).runtime_generation)
		if gen == _tint_gen:
			return _tint_cache
		var out := blade_tint
		var elem_found := false
		for e in weapon._element_pool():
			if int(e) != GameConst.Element.KIN:
				out = weapon.blend_element_color()
				elem_found = true                # R267 视觉刀：元素位同代落缓存（_elem_tinted）
				break
		_tint_gen = gen
		_tint_cache = out
		_tint_elem = elem_found
		return out
	return blade_tint


func _elem_tinted() -> bool:
	# R267 视觉刀：元素染色判（live——_live_blade_tint 同缓存代直出；无宿主恒 false
	# = 身份/桩路径不进水晶配方，§2.2 豁免）
	if weapon != null and is_instance_valid(weapon) \
			and weapon.has_method(&"blend_element_color") and weapon.has_method(&"_element_pool"):
		_live_blade_tint()
		return _tint_elem
	return false


func _crystal_visual_on() -> bool:
	# R267 视觉刀：水晶路径总激活判（spawn 风格键 × 元素池非 KIN——§2.3 刀体站点
	# 口径：blend 稳定混色一把混色水晶刀，选卡即变色契约保持）
	return crystal and _elem_tinted()


func _range_dash_radius() -> float:
	# R245 §3.4-3 待机虚线半径单源（重绘判定与绘制共用——避免两处各读漂移）：
	# weapon 在侧 = effective_slash_radius 判定真值（live 读表，升级/乘区即时反映），
	# 否则回落 spawn slash_radius 快照（桩/旧调用方口径）。
	var r := slash_radius
	if weapon != null and is_instance_valid(weapon) and weapon.has_method(&"effective_slash_radius"):
		r = float(weapon.call(&"effective_slash_radius"))   # 判定真值同源（melee_sanctuary_r 同式）
	return maxf(r, 1.0)


func _draw_range_dash() -> void:
	# 二cx#1 近战范围虚线重做（用户「还是没范围提示」——二cv 版真机等效不可见）：
	# ① 全周圈（原局部 ±half 恒锁东向——节点 rotation 从不设置，140° 弧只贴玩家东侧，
	# 且攻击实际朝索敌方向，虚线所指与挥砍方向无关）；② 双描线对比度（原单层 tint
	# 提亮 α0.35 宽 2px——亮底图上通道差实测 ~15/255 等效隐形）。现 = 暗衬线
	# （tint 压暗、宽+2）叠亮面线（tint 提亮）——明暗底图均可辨。半径仍 = effective
	# _slash_radius 判定真值（与交战门 CLEAVE_ENGAGE_MULT 圈同源——敌入圈即开砍，
	# 虚线即「靠近才攻击」的攻击范围预告）。虚线 = 分段短弧（无新节点；重绘仅
	# 切换帧/色变帧/半径变帧，tick 侧去重不变）。色 = 实时 tint（元素选卡即变）。
	# R245 §3.4-3：半径取值迁 _range_dash_radius 单源。
	var r := _range_dash_radius()
	var seg := RANGE_DASH_LEN_PX / r                    # 单段弧长 → 圆心角 rad
	var gap := RANGE_DASH_GAP_PX / r
	var rim := _live_blade_tint().darkened(0.55)
	rim.a = RANGE_DASH_RIM_ALPHA
	var face := _live_blade_tint().lightened(0.55)
	face.a = RANGE_DASH_ALPHA
	var a := 0.0
	while a < TAU:
		var a1 := minf(a + seg, TAU)
		draw_arc(Vector2.ZERO, r, a, a1, 4, rim, RANGE_DASH_WIDTH + 2.0, true)
		draw_arc(Vector2.ZERO, r, a, a1, 4, face, RANGE_DASH_WIDTH, true)
		a = a1 + gap


func blade_visual_scale() -> float:
	# 二cy#1 剑体视觉缩放（与判定半径同源）：顶点表按 BLADE_TABLE_R=150 设计固化，
	# 半径成长（W13 逐级/巨刃/广域乘区、W9 逐级 150→230）不再「剑不跟着圈长大」。
	# 消费点 = _draw_slash_window 的 draw_set_transform 缩放（判定/顶点表零改动）。
	return clampf(slash_radius / BLADE_TABLE_R, 0.8, 3.4)


func _a95(p_c: Color) -> Color:
	# 本体填充统一 α 0.95（R61 口径；Color 值语义——参数即副本直改返回）
	p_c.a = 0.95
	return p_c


func _t2_fill() -> Color:
	# §7.2 质变主填充：saber（碧涛旋舞）tint 加深 T2_TINT_DARKEN 档；greatsword
	# 底色恒暗黑不加色（W13 质变差在加宽+金裂纹）；未质变 = 原色零位移。
	# 二cv#5：tint 改 _live_blade_tint()（绘制期实时元素混色——快照仅回落）。
	var tint := _live_blade_tint()
	if transcended and blade_style != STYLE_GREATSWORD:
		return tint.darkened(T2_TINT_DARKEN)
	return tint


func _blade_polygon() -> PackedVector2Array:
	# 刀身顶点表（测试读回口——R243 §2.1 saber 深弯月 / 二cu greatsword DNF 巨剑直刃）：
	# 刀背（+Y 侧）→ 刀尖 → 刀刃（-Y 侧）。saber = 弯月控制点表；greatsword = 二cu 重画
	#（用户「阔剑应该是dnf 巨剑那种形象」）：平行等宽厚重直刃 + 长斜角巨尖（旧版弯月 ×1.6
	# = 弯刀加宽，非巨剑直刃读感）；顶点序（脊根→脊平→尖→刃肩→刃平×2→刃根→跟凹）
	# 与 saber 同构 8 顶点（顶点渐变 cols 数组两式共用）。w = 1.6（GREATSWORD_WIDTH_MULT）
	# ×质变 1.3（T2_GS_WIDEN）口径不变。
	# R188⑨：按 (style×transcended) 四键 static 字典缓存——顶点只依赖这两离散位，挥斩窗
	# ≈20 帧×(本体+残影) 逐次重建是常量税；PackedVector2Array 值语义 COW，读回口改不动
	# 缓存本体，rcu/fengren/prime 顶点断言内容逐位不变照绿。
	var key := (2 if transcended else 0) + (1 if blade_style == STYLE_GREATSWORD else 0)
	var cached: Variant = _poly_cache.get(key)
	if cached is PackedVector2Array:
		return cached
	var w := GREATSWORD_WIDTH_MULT * (T2_GS_WIDEN if transcended else 1.0) \
		if blade_style == STYLE_GREATSWORD else 1.0
	var poly := PackedVector2Array([
		Vector2(36.0, 9.0 * w), Vector2(118.0, 9.0 * w), Vector2(150.0, -1.0 * w),
		Vector2(118.0, -9.0 * w), Vector2(84.0, -9.0 * w), Vector2(52.0, -9.0 * w),
		Vector2(36.0, -9.0 * w), Vector2(28.0, 0.0),
	]) if blade_style == STYLE_GREATSWORD else PackedVector2Array([
		Vector2(38.0, 6.0 * w), Vector2(95.0, 14.0 * w), Vector2(128.0, 6.0 * w),
		Vector2(150.0, -10.0 * w),
		Vector2(140.0, -20.0 * w), Vector2(100.0, -13.0 * w), Vector2(65.0, -11.0 * w),
		Vector2(38.0, -6.0 * w),
	])
	_poly_cache[key] = poly
	return poly


func _draw_blade(p_fill: Color, p_line: Color, p_full: bool) -> void:
	# 刀体（刀身局部系：+X = 出刃方向，刀尖在 slash_radius 端；-Y = 挥动前进侧 = 刃口）。
	# 柄在玩家/化身近端（r≈8..34），刀身 r≈38..slash_radius。
	# R243 blade_style 参数化：saber = 深弯月弧刃（刀背控制点 Vector2(38,6)→(95,14)
	# →(128,6)→(150,-10)、刃口 -Y 侧弧线内收）；greatsword = 同轮廓刃身宽 1.6×
	#（刀身 Y ×1.6）+ 护手十字加宽 + 暗金描边。
	var greatsword := blade_style == STYLE_GREATSWORD
	# R243 §7.2：w 与 _blade_polygon 同源（greatsword 1.6×；质变再 ×1.3——描线/护手/裂纹
	# 与加宽刀身对齐）
	var w := (GREATSWORD_WIDTH_MULT * (T2_GS_WIDEN if transcended else 1.0)) \
		if greatsword else 1.0
	var blade := _blade_polygon()
	var lines := _blade_lines(w)                 # R188⑨：顶点表 static 缓存（w 档键）
	if p_full and _crystal_visual_on():
		# R267 视觉刀 §2.4：水晶本体路径（元素染色变体——W9 saber/W13 greatsword）：
		# 外壳半透 + 过渡/亮核装色 + 白刃缘 + 内折射线（档2 五层）；顶点表/描线缓存/
		# 判定零动（_poly_cache 四键读回口照绿——§2.6-d）。KIN/空池身份站点不进此
		# 分支（§2.2 豁免——逐位现绘制）。
		_draw_crystal_body(blade, lines, greatsword)
		var deep_guard: Color = GREATSWORD_DEEP if greatsword else Color(0.16, 0.28, 0.45, 0.95)
		draw_colored_polygon(lines["guard"], deep_guard)
		draw_colored_polygon(lines["hilt"], deep_guard)
		return
	if p_full:
		# 顶点渐变（刀背深 → 刃口亮：刃/背一眼可分；本体 α 0.95 同 R61 口径）
		var cols := PackedColorArray()
		if greatsword:
			# 暗黑刃身（tint 底）→ 金刃口（§2.5 双色：底 Color(0.16,0.15,0.2) + 金刃口）
			cols.append(_a95(p_fill))
			cols.append(_a95(p_fill))
			cols.append(_a95(p_fill.lerp(GREATSWORD_EDGE, 0.25)))
			cols.append(_a95(p_fill.lerp(GREATSWORD_EDGE, 0.6)))
			cols.append(_a95(p_fill.lerp(GREATSWORD_EDGE, 0.85)))
			cols.append(_a95(p_fill.lerp(GREATSWORD_EDGE, 0.6)))
			cols.append(_a95(p_fill.lerp(GREATSWORD_EDGE, 0.35)))
			cols.append(_a95(p_fill.lerp(GREATSWORD_EDGE, 0.15)))
		else:
			# 青绿主填充梯度：刀背同色系加深 → 刃口提亮
			cols.append(_a95(p_fill.darkened(0.45)))
			cols.append(_a95(p_fill.darkened(0.30)))
			cols.append(_a95(p_fill.lightened(0.10)))
			cols.append(_a95(p_fill.lightened(0.45)))
			cols.append(_a95(p_fill.lightened(0.70)))
			cols.append(_a95(p_fill.lightened(0.45)))
			cols.append(_a95(p_fill.lightened(0.25)))
			cols.append(_a95(p_fill.darkened(0.20)))
		draw_polygon(blade, cols)
		# 刃口亮线（锋利读感；-Y 侧 = 旋转前进方向，刃口领先进刀）
		# 二cu greatsword 直刃化：刃口/刀背 = 平直线段（旧弯月弧线表仅 saber 消费）
		# R188⑨：顶点表走 static 缓存直出（draw_polyline 拷贝进 canvas item 共享安全）
		if greatsword:
			draw_polyline(lines["edge_gs"], p_line, 3.5, true)
		else:
			draw_polyline(lines["edge_saber"], p_line, 3.5, true)
		# 刀背描线（同色系加深，压出背面轮廓——刀形立体感）
		var spine: Color = GREATSWORD_OUTLINE if greatsword \
			else p_fill.darkened(0.55)
		spine.a = 0.8
		if greatsword:
			draw_polyline(lines["spine_gs"], spine, 2.0, true)
		else:
			draw_polyline(lines["spine_saber"], spine, 2.0, true)
		if greatsword:
			# 暗金描边（阔剑身份——全轮廓勾边，§2.5）
			draw_polyline(blade, GREATSWORD_OUTLINE, 2.0, true)
			if transcended:
				# §7.2 裂地斩金色裂纹（刃面两道折线描金——黑金巨剑质变读感）
				var crack := GREATSWORD_EDGE
				crack.a = 0.85
				draw_polyline(lines["crack_a"], crack, 1.8, true)
				draw_polyline(lines["crack_b"], crack, 1.6, true)
	else:
		# 残影：低透明填充 + 全轮廓描边——保住刀形剪影（无描边会糊成弧形色带）
		draw_colored_polygon(blade, p_fill)
		draw_polyline(blade, p_line, 2.0, true)
	# 护手（径向短横档）+ 柄（近端深色握把，加粗保证可辨）——greatsword 十字加宽（Y×1.6）
	var deep: Color = GREATSWORD_DEEP if greatsword else Color(0.16, 0.28, 0.45, 0.95)
	draw_colored_polygon(lines["guard"], deep)
	draw_colored_polygon(lines["hilt"], deep)


func _draw_crystal_body(p_blade: PackedVector2Array, p_lines: Dictionary,
		p_greatsword: bool) -> void:
	# R267 视觉刀 §2.2/§2.4：水晶本体绘制（即时形态——壳/体/缘/折射四段装色）。
	# · 棕修 = 明度策略反转：亮核 v≥0.75（CORE_V_MIN）> 棕判据 v≤0.62 上界，
	#   darkened 梯度（arc_slash.gd:706-714 原刀背压暗）在本路径整体退役；
	# · 全部色表经 CrystalBladeFactory.crystal_cols（static 缓存直出——绘制期
	#   零新建，§2.6-g 零分配断言面）；外壳顶点 crystal_shell_poly 同缓存；
	# · 降档矩阵（§2.5-4）：档2 五层（壳+体+缘+折射） / 档1 三层（体+缘） /
	#   档0 单层平涂+缘（crystal_cols 档0 即平涂色表）。
	var q := _fx_quality()
	var fill := _live_blade_tint()
	if q >= 2:
		var shell_poly := CrystalBladeFactory.crystal_shell_poly(blade_style, transcended,
			CrystalBladeFactory.SHELL_EXPAND)
		if not shell_poly.is_empty():
			var shell_cols := CrystalBladeFactory.crystal_cols(blade_style, fill,
				transcended, q, CrystalBladeFactory.LAYER_SHELL)
			if not shell_cols.is_empty():
				draw_polygon(shell_poly, shell_cols)
	draw_polygon(p_blade, CrystalBladeFactory.crystal_cols(blade_style, fill,
		transcended, q, CrystalBladeFactory.LAYER_BODY))
	# 修轮①评审：全轮廓描边——淡元素（ICE/ANE）过渡层 α0.45 合成到亮底
	# #eef3ff 上亮度差仅 ~8% 近隐形（旧 darkened 剪影对比拆除后无替代）；OUTLINE
	# 轮廓线对齐烘焙态藏青描边（palette 单源），顶点走 _poly_cache 缓存零分配。
	draw_polyline(p_blade, CrystalBladeFactory.crystal_outline_color(), 1.8, true)
	var edge_key := "edge_gs" if p_greatsword else "edge_saber"
	draw_polyline(p_lines[edge_key],
		Color(1.0, 1.0, 1.0, CrystalBladeFactory.ALPHA_EDGE), 3.5, true)
	if q >= 2:
		# 内折射亮线（刃脊——水晶折射读感；档1/0 砍）
		var refract: Color = CrystalBladeFactory.layer_color(fill, transcended, q, 4)
		var spine_key := "spine_gs" if p_greatsword else "spine_saber"
		draw_polyline(p_lines[spine_key], refract, 1.5, true)


# ── R243 §7.2 W9 碧涛旋舞图标（texture_factory <id>_t2 委托位——static func） ─────
# 共享工厂 weapon_icon_t2 缓存键机制（w1 已备）；委托注册（_delegate_weapon_icon
# paths 增 "W9_arc_slash" → 本脚本）属共享文件改动，已在任务产出说明登记。
# 默认 = 青绿弯刀单臂；质变 = 加深青绿双旋臂（第二道旋臂残影形）。

static var _icon_cache: Dictionary = {}    # 图标本地缓存（键 base/t2——勿写共享 _cache）
static var _poly_cache: Dictionary = {}    # R188⑨：刀身顶点表 (style×transcended) 四键缓存
static var _line_cache: Dictionary = {}    # R188⑨：刃口/刀背/裂纹/护手/柄顶点表按 w 档缓存
                                           #（w 恰三档 1.0/1.6/2.08；draw_polyline/
                                           # draw_colored_polygon 顶点拷贝进 canvas item——
                                           # 共享缓冲安全）


static func _blade_lines(p_w: float) -> Dictionary:
	# R188⑨：绘制期顶点表按 w 档 static 缓存（原 _draw_blade 每帧每把刀 6-8 个
	# PackedVector2Array 字面量重建——挥斩窗 ≈20 帧 × 本体+残影常量税）；键取 w×100
	# 整数档（浮点乘积恒定：w 只从三档常量来），表内容与原字面量逐位一致
	var key := roundi(p_w * 100.0)
	var cached: Variant = _line_cache.get(key)
	if cached is Dictionary:
		return cached
	var w := p_w
	var d := {
		"edge_gs": PackedVector2Array([
			Vector2(150.0, -1.0 * w), Vector2(118.0, -9.0 * w),
			Vector2(84.0, -9.0 * w), Vector2(36.0, -9.0 * w),
		]),
		"edge_saber": PackedVector2Array([
			Vector2(140.0, -20.0 * w), Vector2(100.0, -13.0 * w),
			Vector2(65.0, -11.0 * w), Vector2(38.0, -6.0 * w),
		]),
		"spine_gs": PackedVector2Array([
			Vector2(36.0, 9.0 * w), Vector2(118.0, 9.0 * w), Vector2(150.0, -1.0 * w),
		]),
		"spine_saber": PackedVector2Array([
			Vector2(38.0, 6.0 * w), Vector2(95.0, 14.0 * w), Vector2(128.0, 6.0 * w),
		]),
		"crack_a": PackedVector2Array([
			Vector2(64.0, -7.0 * w), Vector2(92.0, 3.0 * w), Vector2(118.0, -4.0 * w),
		]),
		"crack_b": PackedVector2Array([
			Vector2(56.0, 5.0 * w), Vector2(84.0, 11.0 * w), Vector2(112.0, 6.0 * w),
		]),
		"guard": PackedVector2Array([
			Vector2(34.0, -10.0 * w), Vector2(38.0, -10.0 * w),
			Vector2(38.0, 10.0 * w), Vector2(34.0, 10.0 * w),
		]),
		"hilt": PackedVector2Array([
			Vector2(6.0, -4.5 * w), Vector2(34.0, -4.5 * w),
			Vector2(34.0, 4.5 * w), Vector2(6.0, 4.5 * w),
		]),
	}
	_line_cache[key] = d
	return d


static func weapon_icon_tex(p_transcended: bool) -> ImageTexture:
	# R243 W9 图标（56px 画布朝上 -Y——化身 +90° 朝向补偿口径）：深弯月大弯刀；
	# 质变 = blade_tint 加深 + 第二道旋臂（双旋臂读感）。
	var key := "t2" if p_transcended else "base"
	if _icon_cache.has(key):
		return _icon_cache[key]
	var tex: ImageTexture = TextureFactory._render(56, 56,
		TextureFactory._shade(_icon_layers(p_transcended)))
	_icon_cache[key] = tex
	return tex


static func _icon_layers(p_transcended: bool) -> Array:
	# 图层集（TextureFactory._shade 契约同 orbit_field._icon_layers）。
	var tint := SABER_TINT
	if p_transcended:
		tint = SABER_TINT.darkened(T2_TINT_DARKEN)     # 碧涛旋舞加深档
	var deep := tint.darkened(0.45)
	# 主旋臂：深弯月大弯刀（刀背外弧鼓出 +X、刃口 -X 内收，尖朝上 -Y）
	var blade := PackedVector2Array([
		Vector2(2.0, -24.0), Vector2(8.5, -18.0), Vector2(11.0, -9.0),
		Vector2(9.5, -1.0), Vector2(5.0, 3.0), Vector2(1.0, -2.0),
		Vector2(1.5, -12.0),
	])
	var layers: Array = [
		# R267 视觉刀：水晶外壳层（图标水晶版——身份青绿未钳，§2.2 钳制仅限元素
		# 染色路径；c′ 防混搭的半透特征层）
		{"sd": TextureFactory._poly_sd(CrystalBladeFactory.expand_poly(blade,
			CrystalBladeFactory.ICON_SHELL_EXPAND)),
			"fill": CrystalBladeFactory.icon_shell_color(tint), "ow": 0.0},
		{"sd": TextureFactory._poly_sd(blade), "fill": tint, "ow": 2.4},
		# 刃口白高光
		{"sd": TextureFactory._poly_sd(PackedVector2Array([
			Vector2(1.0, -20.0), Vector2(2.2, -8.0), Vector2(5.5, 0.5),
			Vector2(6.8, -1.5), Vector2(4.2, -8.5), Vector2(3.2, -19.0),
		])), "fill": Color(1.0, 1.0, 1.0, 0.88), "ow": 0.0},
		# 护手 + 柄
		{"sd": TextureFactory._box_at(Vector2(0.0, 5.0), Vector2(7.5, 2.0), 1.1),
			"fill": deep, "ow": 2.0},
		{"sd": TextureFactory._box_at(Vector2(0.0, 11.0), Vector2(1.7, 4.4), 1.0),
			"fill": deep, "ow": 2.0},
	]
	if p_transcended:
		# 第二道旋臂（左侧镜像小弯月——「双旋臂」质变读感）
		layers.append({"sd": TextureFactory._poly_sd(PackedVector2Array([
			Vector2(-3.5, -17.0), Vector2(-9.0, -12.0), Vector2(-11.5, -5.0),
			Vector2(-10.0, 1.5), Vector2(-6.5, -1.0), Vector2(-6.0, -9.5),
		])), "fill": tint.darkened(0.22), "ow": 1.8})
	CrystalBladeFactory.note_icon_built(&"W9_arc_slash")   # R267 c′ 机制标记
	return layers
