# scripts/combat/weapon/weapon_base.gd
# M-05~M-08 WeaponBase（架构 §2.8.1）：武器抽象基类（四形态子类按 form 分派）。
# · 冷却/射速节拍 tick(game_delta)：冷却推进 → 满足节拍时 try_fire（射速上限 30/s 双护栏）。
# · 词条挂载 trait_stack（武器主栈 ≤12）：常驻面板聚合（build_panel_snapshot，F-13 母本）
#   + OnHit 注入源（copy_runtime → 投射物/光束运行时栈）。
# · 面板快照：{base_atk, crit_rate, crit_mult, flat_bonus, add_entries[]}——分裂继承比例的
#   母本（F-13）；add_atk 池经 add_entries 入管线步骤 3（F3 衰减真源），其余加算池
#   参数侧聚合（rof/cdr/crit/critdmg/spd/pierce/pellets）。
class_name WeaponBase
extends Node2D

signal leveled(new_level: int)

const MAX_LEVEL: int = 5                       # L1~L5（升级表终值口径）
const AIM_FALLBACK := Vector2.UP               # 无目标时的默认指向（全自动开火持续）
const MILESTONE_VALUE_MULT: float = 1.6         # 满层质变乘区（ADD 池词条挂至 stack_max ×1.6）
# R243 巨刃刀体缩放基准（白——与 OrbitWeapon.GIANT_BLADE_SCALE_BASE 同值 0.25；本侧为
# _giant_blade_value 上移副本的解析源。注意：GDScript 父子类同名 const = parse error
# （同名方法才是遮蔽），故本副本常量独立命名；w2-melee 删除 OrbitWeapon 本地 const 后
# 由 w2 统一收回单源命名）
const R243_GIANT_BLADE_BASE := 0.25
# R289 A：武器族分键映射（诊断 武1µs..武9µs 与 Player 逐武器计时桶同源；未知 id → 9 副桶）。
# 键=WeaponData.id；索引=族号−1（W1→0 … W9→8）。只服务诊断/节流补偿，不做行为分派。
const WPN_FAMILY_INDEX := {
	&"W1_pistol": 0, &"W2_gatling": 1, &"W3_shotgun": 2, &"W4_pulse_beam": 3,
	&"W5_prism": 4, &"W6_micro_missile": 5, &"W7_cluster_rocket": 6,
	&"W8_orbit_field": 7, &"W9_arc_slash": 8,
}
const WPN_FAMILY_OTHER := 9
# R293 模拟刀 B：② 段武器侧查询帧级共享助手（按路径 preload 引用——headless -s
# 套件跑不重扫 global_script_class_cache，新 class_name 裸标识符不可解析；本类声明
# 一份、子类〔OrbitWeapon/HomingWeapon 等〕继承沿用——父子同名 const = parse error）。
const SimQueryShare = preload("res://scripts/combat/weapon/sim_query_share.gd")
# R289 A：本步 weapon.tick 收到 dt×2（深载隔帧节流的执行步）——W8 挡弹概率/帽按此
# 折算（两次判定的等效概率），只读不写（Player.tick 唯一写点）。
static var lod_dt_doubled: bool = false
static var lod_beats: int = 2                  # R291：本执行拍逻辑子拍数（主武器组 2=dt×2 原语义；
                                              # 副武组深载 4=dt×4 四分频——子拍=dt/beats，
                                              # 逐拍复刻守恒对任意 N 成立，Player 每组 tick 前写入）


static func wpn_family_index(p_id: Variant) -> int:
	if p_id == null:
		return WPN_FAMILY_OTHER
	return int(WPN_FAMILY_INDEX.get(StringName(str(p_id)), WPN_FAMILY_OTHER))

var data: WeaponData = null                    # 形态参数（M-14 注入）
var uid: int = 0
var level: int = 1                             # L1~L5（升级表终值口径）
var transcended: bool = false                  # R243 §7.1 质变标志（L5 首次置位单次；
                                               # get_stat base_atk ×atk_mult 单咽喉）
var player: Node2D = null                      # 宿主注入（Player；宽类型规避循环解析）
var meta_atk_pct: float = 0.0                 # 局外养成攻击 + 角色攻击修正（Player 注入）
var trait_stack: TraitStack = null             # 武器级词条（常驻面板聚合 + OnHit 注入源）
var target_strategy: int = GameConst.TargetStrategy.NEAREST
var cooldown_left: float = 0.0
var _last_interval: float = 0.0                # 上次开火节拍（R29 迟到减CD 的比例缩放基准）
var damage_pipeline: RefCounted = null          # 注入（DamagePipeline / 桩——resolve 签名一致）
var projectile_pool: ProjectilePool = null      # 注入（ballistic 场景池）
var enemy_grid: SpaceGrid = null               # 注入（索敌）
var laser_pool: LaserBeamPool = null           # 注入（LASER 形态）
var elemental: ElementalSystem = null          # 注入（元素附着通道）
var relic_handler: RelicHandler = null         # 注入（集成包 B.2：遗物命中乘区问询）
var wave_director: WaveDirector = null         # 注入（集成包 B.4：SYN_FIRST_STRIKE 波首命中位）

var _panel_cache: Dictionary = {}              # 面板快照缓存（词条挂载/升级时失效）
var _blend_gen: int = -1                       # R188②：混色缓存世代锚（-1=未建；setup 复位
                                               # 防复用残留——新栈世代归零可与旧锚撞号）
var _blend_cache := Color.WHITE                # R188②：世代未变时直出的混色缓存（化身/刀体
                                               # 逐帧热路径零重算零数组分配）
var _range_mult_gen: int = -1                  # QA-heal r1：广域乘区世代锚（-1=未建；setup 复位
                                               # 同 _blend_gen 式——复用件旧锚防撞号）
var _range_mult_cache := 1.0                   # QA-heal r1：世代未变直出的 add_range 聚合
                                               #（贴脸豁免圈逐帧折算热路径零字典重建）
var _tc_params: Dictionary = {}                # QA-heal r1：质变参数引用缓存（命中段原样返
                                               # 引用与旧实现同源；空表共享单例——消费侧只读
                                               # .get 零落改）
var _tc_params_src: WeaponData = null          # QA-heal r1：质变缓存 data 引用锚（运行期
                                               # data 不变语义，换 data 即重算——零分配比对）
var _tc_params_built := false                  # QA-heal r1：质变缓存构建位（data==null 的
                                               # 空表结果同样缓存，避免逐调重建）
# ── R246 玩家侧 extern 乘区注入口（fission Ω 改装件 / reaper 收割窗共用；player 写入）──
# 键：rof（_player_rof_mult 尾乘）/ spd / size（弹速/弹体半径尾乘）/ crit（面板暴击加算）/
#     atk（base_atk 尾乘）。空表 = 其余角色零位移（全部读点缺省 0.0/1.0 恒等）；
# 含 rof 的启停由 player 侧配 refresh_fire_interval（R29 即时节拍）。
var extern_buffs: Dictionary = {}

# ── R220 刀3②：threshold_traits 预索引（get_threshold O(1)——原 :240 逐条
#    StringName(str()) 线性扫，命中链热点每次掷转换） ──
var _threshold_index: Dictionary = {}          # threshold_id → entry（setup 构建一次；
                                               # 重复 id 保留首个 = 原线性扫语义）

# ── R220 刀7：单拍索敌缓存（tick 栈内 has_target_now 与 try_fire→aim_direction
#    的二次 query_nearest(1600) 全网格扫合并为一次；缓存键 tick 拍序——headless
#    手驱/直调 try_fire 路径不受缓存影响，语义逐位保真） ──
var _tick_seq: int = 0                         # tick 拍序（缓存纪元）
var _in_tick: bool = false                     # tick 调用栈标记（仅栈内缓存生效）
var _acq_cache_seq: int = -1                   # 缓存写入时拍序
var _acq_cache_target: Node2D = null           # 缓存目标（null=本拍已知无目标）

# ── R220 刀12：帧率优先弹生成配额（每步 32 发全组共享——player 火段入口重置余量；
#    顺延 1-2 帧交错散开防预算恢复瞬间再对齐，quota_deferred/quota_dropped 计数）──
var _quota_def_a: int = 0                      # 顺延丸·下一帧到期份额（交错散开对半分）
var _quota_def_b: int = 0                      # 顺延丸·下下帧到期份额
var _quota_pending: int = 0                    # 已到期待并入下一次 try_fire 的丸数


static func melee_mode_of(p_melee: Dictionary) -> String:
	# R243 行为模式键单源（§1.2）：显式 mode 优先；缺省回落 nullify 旧口径
	#（true→slash / false→orbit——测试桩夹具兼容）。_instantiate_weapon 分派与
	# OrbitWeapon._is_slash_mode 扩义（w2-melee）共用本口。
	return String(p_melee.get("mode",
		"slash" if bool(p_melee.get("nullify", false)) else "orbit"))


# ── QA-heal r1：逐级参数键静态缓存（<key>_levels 串拼每调新建 String = R188/R225
#    「逐帧分配=常量税」形态；键名映射全局不变——零失效面，五形态 _leveled_param
#    副本共用本口） ──
static var _lp_keys: Dictionary = {}


static func _leveled_key(p_key: String) -> String:
	if not _lp_keys.has(p_key):
		_lp_keys[p_key] = p_key + "_levels"
	return _lp_keys[p_key]


func bullet_block_chance() -> float:
	# R243 统一掷骰口（§3.1，供 w2/w3 各拦截点消费——本波次先置 inert）：
	# nullify 键（法器确定性消弹）优先返 1.0；否则 melee.block_chance 基线 + Σadd_block
	# 池（MEC_BULLET_PARRY 成长通道，w3 入库后自动聚合）；clamp [0,1]；非 form 3 返 0。
	if data == null or data.form != GameConst.WeaponForm.MELEE:
		return 0.0
	if bool(data.melee.get("nullify", false)):
		return 1.0
	var base := float(data.melee.get("block_chance", 0.0))
	var bonus := 0.0
	if trait_stack != null:
		bonus = float(trait_stack.aggregate_panel().get("add_block", 0.0))
	return clampf(base + bonus, 0.0, 1.0)


func blend_element_color() -> Color:
	# R188②：实例级世代缓存口——混色是 trait_stack 词条集的纯函数（attach/质变/取优
	# 即 bump runtime_generation，trait_stack.gd:51/:57-62），世代未变直出缓存
	#（化身 _process/刀体绘制逐帧热路径原每调重建 Array[Color]——常量税）。
	# 守卫须 `is TraitStack` 判型：测试桩 trait_stack 可为 null/非栈（bool(null) 是
	# 运行时错纪律，arc_slash._live_blade_tint 同式先例）——非栈走原计算体不写缓存，
	# 桩行为逐位保真。
	var ts: Variant = trait_stack
	if not (ts is TraitStack):
		return _blend_compute()
	var gen := (ts as TraitStack).runtime_generation
	if gen == _blend_gen:
		return _blend_cache
	var out := _blend_compute()
	_blend_gen = gen
	_blend_cache = out
	return out


func _blend_compute() -> Color:
	# R243 多元素混色计算体（§6.5；评审修复——原非 KIN 色 RGB 均值对 3+ 元素发灰：
	# 火+冰+雷 ≈洗灰紫 s≈0.2）：改 HSV 色相圆周矢量均值插值 + 饱和度保真——
	# · 空池 = 中性白；单元素 = 该色本体（与 dominant_element() 逐位同色，零位移——
	#   激光与跳字仍走 dominant，本口供化身/环绕体/刀体混色消费）；
	# · 多元素：色相 = 圆周矢量均值（等权），饱和度 = 成员最大值（≥3 元素保底 0.6 拉
	#   饱和防洗灰），明度 = 成员均值（亮度稳定）；
	# · 色相对跖抵消（矢量长 < 0.35，如火+冰）→ 回落最高饱和成员的色相（主色代表语义，
	#   与 dominant_element 衔接），避免圆周均值落点随机漂移。
	# R188②：内容原样搬移（缓存未命中/桩路径共用），逐位语义不变
	var cols: Array[Color] = []
	for e in _element_pool():
		if e == GameConst.Element.KIN:
			continue
		cols.append(PopPalette.ELEMENT_COLORS[e])
	if cols.is_empty():
		return Color.WHITE
	if cols.size() == 1:
		return cols[0]
	var hx := 0.0
	var hy := 0.0
	var sat_max := 0.0
	var val_sum := 0.0
	for c in cols:
		hx += cos(c.h * TAU)
		hy += sin(c.h * TAU)
		sat_max = maxf(sat_max, c.s)
		val_sum += c.v
	var hue: float
	if Vector2(hx, hy).length() < 0.35:
		var best: Color = cols[0]
		for c in cols:
			if c.s > best.s:
				best = c
		hue = best.h
	else:
		hue = fposmod(atan2(hy, hx) / TAU, 1.0)
	var sat := sat_max
	if cols.size() >= 3:
		sat = maxf(sat, 0.6)                   # ≥3 元素保底拉饱和（防洗灰）
	return Color.from_hsv(hue, clampf(sat, 0.0, 1.0), val_sum / float(cols.size()))


func _giant_blade_layers() -> int:
	# R243 巨刃层数（MEC_GIANT_BLADE）上移副本（原 OrbitWeapon.gd:181-190 本地版暂留
	# 遮蔽——w2-melee 删除后零改名切换；W11/W12/W13 各自消费同款乘区轴）
	if trait_stack == null:
		return 0
	var layers := 0
	for tb in trait_stack.traits:
		var td: Variant = tb.get("data")
		if td != null and (td as TraitData).params.has("knife_scale"):
			layers += int(tb.get("layers"))
	return layers


func _giant_blade_value() -> float:
	# R243 巨刃刀体缩放真源上移副本（原 OrbitWeapon.gd:193-206；R199 F01 data.value 口径
	# 随迁——value≤0 回落 GIANT_BLADE_SCALE_BASE，存量断言零位移）
	if trait_stack != null:
		for tb in trait_stack.traits:
			var td: Variant = tb.get("data")
			if td != null and (td as TraitData).params.has("knife_scale"):
				var v := float((td as TraitData).value)
				if v > 0.0:
					return v
				break
	return R243_GIANT_BLADE_BASE


func _orbit_link_count() -> int:
	# R243 武器数量+（MEC_ORBIT_LINK）上移副本，更名 _orbit_link_count（§4.3——各武器
	# 消费侧自行 mini(计算值, 帽)；LOCAL 池同 ID 取优、value 取整梯 +1/+2/+3/+4 每层。
	# OrbitWeapon 本地 _orbit_link_knives 暂留遮蔽，w2-melee 切换后零改名）
	if trait_stack == null:
		return 0
	var knives := 0
	for tb in trait_stack.traits:
		if tb.data != null and tb.data.id == &"MEC_ORBIT_LINK":
			knives = maxi(int(round(float(tb.data.value))), 1) * tb.layers
			break
	return knives


func _range_mult() -> float:
	# R243 AFF_RANGE（add_range 池）乘区上移副本（原 OrbitWeapon.gd:173-178；W11 飞行
	# 射程 / W12 震荡半径的新消费点与 W8/W9/W13 既有消费同轴）
	# QA-heal r1 常量税收口：贴脸豁免圈（player.gd 逐帧折算 melee_sanctuary_r）每步经
	# effective_slash_radius 触达本口，原每调 aggregate_panel() 新建聚合字典——改世代
	# 脏标缓存（_blend_gen 同式先例）；失效面与 _panel_cache 同口径（attach_trait/
	# MILESTONE 质变/取优换定义 → bump_runtime_generation）
	if trait_stack == null:
		return 1.0
	var gen := trait_stack.runtime_generation
	if gen == _range_mult_gen:
		return _range_mult_cache
	_range_mult_gen = gen
	_range_mult_cache = 1.0 + float(trait_stack.aggregate_panel().get("add_range", 0.0))
	return _range_mult_cache


func setup(p_data: WeaponData, p_player: Node2D, p_deps: Dictionary) -> void:
	# 绑定数据/宿主/依赖注入包（§2.8.1：deps = pipeline/projectile_pool/enemy_grid/…）
	data = p_data
	player = p_player
	uid = GameConst.next_uid()
	trait_stack = TraitStack.new()
	damage_pipeline = p_deps.get("pipeline")
	projectile_pool = p_deps.get("projectile_pool")
	enemy_grid = p_deps.get("enemy_grid")
	laser_pool = p_deps.get("laser_pool")
	elemental = p_deps.get("elemental")
	relic_handler = p_deps.get("relic_handler")
	wave_director = p_deps.get("wave_director")
	cooldown_left = 0.0
	level = 1
	transcended = false                        # R243 §7.1：质变态位随装配复位（复用件零残留）
	_blend_gen = -1                            # R188②：混色缓存随装配复位（新栈世代从 0
	                                           # 起算，可与旧锚撞号——不复位即吐陈旧色）
	_range_mult_gen = -1                       # QA-heal r1：广域乘区缓存随装配复位
	                                           #（_blend_gen 同式——复用件旧锚防撞号）
	_tc_params_built = false                   # QA-heal r1：质变参数缓存随装配复位
	                                           #（src 引用锚双保险——同 data 重装配亦重建）
	_rebuild_threshold_index()                 # R220 刀3②：阈值预索引（setup 构建一次）
	_invalidate_panel()


func _rebuild_threshold_index() -> void:
	# R220 刀3②：threshold_traits → Dictionary(threshold_id→entry) 预索引。
	# 重复 id 保留首个（原线性扫返回首个匹配的语义）；构建点=setup（数据侧静态表，
	# 运行期不热更——get_threshold 内 size 防御校验兜测试 mutate 场景）。
	_threshold_index.clear()
	if data == null:
		return
	for entry in data.threshold_traits:
		var key := StringName(str(entry.get("threshold_id", "")))
		if not _threshold_index.has(key):
			_threshold_index[key] = entry


func tick(p_game_delta: float) -> void:
	# 冷却推进 → 满足节拍时 try_fire（子类行为）；词条冷却推进
	if data == null:
		return
	_tick_seq += 1                             # R220 刀7：单拍缓存纪元（tick 开头推进）
	_in_tick = true
	_tick_quota_defer()                        # R220 刀12：顺延到期推进（开火前并入）
	if trait_stack != null:
		trait_stack.advance_cooldowns(p_game_delta)
	var _fired := false
	var _billed := false
	if lod_dt_doubled:
		# R289 修轮 3（QA-R289-R2-01）：逐逻辑拍复刻关态冷却递推，而不是用 ceil 反推
		# 拍数——W2 冷/热档恰为 5/4 拍整数边界，关态浮点残差会多耗 1 拍，ceil 反推
		# 却跨过该拍，长窗系统性偏快（300 步 58/50=+16%）。子拍与 60Hz 路径同一减法
		# 顺序（maxf(cd−dt,0)），整数边界/浮点残差逐位同构。
		# R291 修轮（QA-R291-D1）：子拍内联开火——每子拍「cd>0 推进 / cd==0 且有目标
		# 即开火」，批内 N 子拍与关态 N 步同一减法链逐位同序（QA 240 拍×8 组 bit 级
		# 锁步复验）；快武器（间隔 < 执行拍子拍数）单执行拍可多次开火。原「拍尾一次
		# 开火+补偿」在 4 拍执行拍下会把副武组开火率钳到 15/s（QA 实测 tempo 镜 480
		# 步系统性 −25%）。lod_beats 由 Player 写点配对（主组 2 / 副武组深载 4）。
		var _n := lod_beats
		var _sub := p_game_delta / float(_n)
		for _k in range(_n):
			if cooldown_left > 0.0:
				cooldown_left = maxf(cooldown_left - _sub, 0.0)
			elif has_target_now():
				if try_fire():
					_fired = true
					_last_interval = _fire_interval()      # 名义间隔（遗物 CDR/间隔缩放口径）
					cooldown_left = _last_interval
					# 多开火拍逐次计费（拍外单次计费会漏计本拍第 2+ 发）。
					if relic_handler != null:
						relic_handler.on_attack_fired(_last_interval)
						_billed = true
			# cd==0 且无目标：保持就绪零推进（R33）——与关态逐步同序
	else:
		if cooldown_left > 0.0:
			cooldown_left = maxf(cooldown_left - p_game_delta, 0.0)
		elif has_target_now():                  # R33：无敌人不开火（冷却保持就绪，敌现即射）
			_fired = try_fire()
			if _fired:
				cooldown_left = _fire_interval()
				_last_interval = cooldown_left
	if _fired and not _billed:
		# R186 每击谐振计费口（开火口径：一枪=一击，霰弹 9 丸仍 1 击——relic_handler
		# .on_attack_fired 注释裁定；不走 damage_resolved：结算侧幂等键折叠多弹丸）。
		# try_fire 成功位 = 全形态唯一真实开火咽喉（四形态子类均经本 tick 基类；
		# 直调 try_fire 的测试/技能特殊通道不计费）。此前接线缺失成「假遗物」：
		# 激活横幅照播、技能 CD 永不直减——仅测试直调 push 口掩盖死卡。
		# R198（二aw-2）：传本次开火节拍 _last_interval（LOD 分支=名义间隔）——慢速
		# 武器按间隔比例折算计费（relic_handler.on_attack_fired 口径 9），每秒 CDR
		# 收益与射速解耦。
		if relic_handler != null:
			relic_handler.on_attack_fired(_last_interval)
	_on_tick_post(p_game_delta)
	_in_tick = false                           # R220 刀7：缓存纪元关闭（tick 栈外真查）


func has_target_now() -> bool:
	# R33 无敌人不开火门（用户反馈「没有敌人的时候不要射击」）：索敌成功才进入
	# try_fire——无敌人冷却保持就绪，敌人一出现即刻开火（不补等节拍；加特林预热
	# 也随门保持，波间不清零）。子类覆写：OrbitWeapon（W8 力场常驻非射击放行，
	# W9 挥砍窗同门防空挥）；try_fire 直调路径不受门控（测试/技能特殊通道）。
	return acquire_target() != null


func try_fire() -> bool:
	# ★ 开火入口（抽象：子类实现开火行为；软上限检查在 ProjectilePool）
	return false


func attach_trait(p_trait: TraitData) -> bool:
	# 词条挂载（单武器 ≤12，超出拒绝 + 计数；卡牌流前置过滤）
	if trait_stack == null or p_trait == null:
		return false
	var attached := trait_stack.attach(p_trait)
	if attached:
		# 满层质变（2026-08-31 用户反馈「哪些 buff 到什么程度会质变」）：ADD 池词条挂至
		# stack_max → 数值乘区 ×1.6（TraitBase.value_mult，聚合侧消费）+ 里程碑广播
		#（HUD 金色 toast + 音效——「一大波爽感」节点）。幂等：已质变（mult>1）不重触。
		# 大关门（2026-09-13）：满层质变第 4 关「翡翠树海」解锁（MechanicGate 节奏表）
		if p_trait.pool == GameConst.PoolClass.ADD and p_trait.stack_max >= 2 \
				and MechanicGate.milestone_unlocked():
			for mounted in trait_stack.traits:
				if mounted.data != null and mounted.data.id == p_trait.id \
						and mounted.layers >= p_trait.stack_max \
						and is_equal_approx(mounted.value_mult, 1.0):
					mounted.value_mult = MILESTONE_VALUE_MULT
					# R226 评审 M1 追溯补差：add_hp 直挂增量按挂载时点 mult 落账（前层
					# ×1.0、触发层 ×1.6），聚合侧全层追溯 ×1.6——质变触发帧一次性补齐
					# 血条差额，血条=面板逐位一致。同 id 触发（常规路径）扣掉已按 ×1.6
					# 落账的触发层；异 id 晚开门触发（追溯全层）则全额补差
					if mounted.data.pool_id == &"add_hp" and player != null:
						var retro := 0.0
						for vk in mounted.layer_values:
							retro += float(vk)
						retro *= MILESTONE_VALUE_MULT - 1.0
						if mounted.data.id == p_trait.id:
							retro -= float(p_trait.value) * (MILESTONE_VALUE_MULT - 1.0)
						player.call(&"apply_max_hp_up", retro)
					_invalidate_panel()
					EventBus.emit_trait_milestone(p_trait.id, p_trait.display_name,
						MILESTONE_VALUE_MULT)
					DebugStats.count(&"trait_milestone")
					break
		_invalidate_panel()
		refresh_fire_interval()          # R29 迟到减CD：挂卡即缩当前倒计时（add_cdr/add_rof/质变）
		if p_trait.pool == GameConst.PoolClass.ADD \
				and p_trait.pool_id == &"add_hp" and player != null:
			# AFF_HP_UP 消费点（原死池接线修复）：add_hp 池逐层落地玩家血条——A3 §4.2
			# 每层 max_hp +25；上限增量同步回补等量当前血（主控裁定 2026-08-29）。
			# 挂载收束口接线：选卡与 REL_ECHO 回响复制共用本路径。
			# R226 有意契约变更（用户拍板「肉鸽别搞上限」）：R196 超帽层 ×0.7 折算退役，
			# 全层全额回加；评审 M1 修复——直挂同乘 value_mult（满层质变 ×1.6 同步血条），
			# 血条=面板聚合=卡面承诺三口径逐位一致
			var hp_gain := p_trait.value
			for mounted_hp in trait_stack.traits:
				if mounted_hp.data != null and mounted_hp.data.id == p_trait.id:
					hp_gain *= mounted_hp.value_mult
					break
			player.call(&"apply_max_hp_up", hp_gain)
		if p_trait.pool == GameConst.PoolClass.ELEM \
				and p_trait.params.has("reaction_mult") and elemental != null:
			# ELE_REACTION_VOID：反应强化注册到 ElementalSystem（全局聚合）
			# R69 品质梯分化：改读 data.value（旧读 params.reaction_mult 固定 ×1.8——
			# 四品质完全一样；value 语义 = 反应乘数，白 1.8 → 蓝/紫/金 ×2.5/×3.4/×4.7）
			# R226 QA-1 修复：注册值按挂载取优定义（mounted.data.value）——原读 p_trait.value
			# 而 register_reaction_mult 是覆写语义；叠层帽时代 stack_max=1 二挂被拒不可达，
			# 无限叠后「金(×4.68) 先挂、白(×1.8) 后挂」会把注册降级到 1.8（挂载侧 data
			# 仍取优金 4.68=注册与聚合失诺）。取优口径与 MULT 池一致
			var reg_value := float(p_trait.value)
			for mounted_ele in trait_stack.traits:
				if mounted_ele.data != null and mounted_ele.data.id == p_trait.id:
					reg_value = float(mounted_ele.data.value)
					break
			elemental.register_reaction_mult(uid,
				maxf(reg_value, float(p_trait.params.get("reaction_mult", 1.8))))
		if p_trait.id == &"MEC_SHIELD" and player != null:
			# MEC_SHIELD 消费点接线（A3 §4.4 格挡力场：每 interval_s 护盾挡 1 次接触伤害）。
			# 层数取挂载后的 TraitBase（p_trait 是 TraitData 定义，无 layers 运行时字段——
			# 2026-08-31 P0 修复：直读 p_trait.layers 运行时崩溃致护盾条不显示）。
			# R69：充能倍率取同 ID 挂载最优 value（白 8s/蓝 5.7s/紫 4.2s/金 3.1s）。
			# R253 独立计时（用户口径「多武器护盾独立计时」取代 R238 H3 全槽聚合）：只报
			# 宿主自己的层数与最优倍率，p_uid=自身 uid——每武器一份独立单元（各自几何
			# 充能各自就绪，跨武器不聚合不覆写；H3 原缺陷「后挂白卡覆写回 8s」由独立
			# 单元天然消解——每把武器只写自己的键）。
			var self_layers := 0
			var self_mult := 1.0
			if trait_stack != null:
				for mounted in trait_stack.traits:
					if mounted.data != null and mounted.data.id == p_trait.id:
						self_layers += mounted.layers
						self_mult = maxf(self_mult, float(mounted.data.value))
			if self_layers > 0:
				player.call(&"apply_shield_trait", self_layers, p_trait.params, self_mult, uid)
	return attached


func get_stat(p_key: StringName) -> float:
	# 当前等级终值（upgrade_table[level-1]）
	# R243 §7.1 质变单咽喉：transcended 时 base_atk × transcend.atk_mult——面板快照
	#（build_panel_snapshot）与全部结算路径经本口读攻击力，质变乘区自动生效。
	if data == null or level < 1 or level > data.upgrade_table.size():
		return 0.0
	var v := float(data.upgrade_table[level - 1].get(p_key))
	if p_key == &"base_atk" and transcended:
		v *= float(_transcend_params().get("atk_mult", 1.0))
	return v


func get_current_atk() -> float:
	# F2：get_stat("base_atk") × g_global（g_global 当前 = 1）
	return get_stat(&"base_atk")


func build_panel_snapshot() -> Dictionary:
	# 面板段快照（分裂继承比例的母本，F-13）：add_atk 池以原始条目入 add_entries
	# （衰减职责在管线步骤 3）；crit 参数武器侧聚合（F3 同式预览）。
	if not _panel_cache.is_empty():
		return _panel_cache
	var aggregate: Dictionary = trait_stack.aggregate_panel() if trait_stack != null else {}
	var crit_rate := 0.05
	var crit_dmg := 2.0
	if data != null:
		crit_rate = data.crit_rate
		crit_dmg = data.crit_dmg
	var crit_cap := 1.0
	if GameConfig.balance != null:
		crit_cap = GameConfig.balance.cap_crit_rate
	var snapshot := {
		"base_atk": get_current_atk() * (1.0 + meta_atk_pct)
			* (1.0 + float(extern_buffs.get(&"atk", 0.0))),   # 局外养成/角色修正 + R246 extern atk 尾乘
		"crit_rate": clampf(crit_rate + float(aggregate.get("add_crit", 0.0))
			+ float(extern_buffs.get(&"crit", 0.0)), 0.0, crit_cap),   # R246 extern crit 键
		"crit_mult": crit_dmg + float(aggregate.get("add_critdmg", 0.0)),
		"flat_bonus": 0.0,
		"add_entries": trait_stack.aggregate_add_entries() if trait_stack != null else [],
	}
	_panel_cache = snapshot
	return snapshot


func build_damage_context(p_target: Node2D) -> DamageContext:
	# 武器侧聚合 ctx（近战/光束等无投射物路径；投射物路径经 panel_snapshot 展开）
	var snapshot := build_panel_snapshot()
	var ctx := DamageContext.make()
	ctx.source_uid = uid
	ctx.target = p_target
	ctx.target_uid = int(p_target.get("uid"))
	ctx.frame_stamp = GameConfig.frame_stamp
	ctx.base_atk = float(snapshot.get("base_atk", 0.0))
	ctx.flat_bonus = float(snapshot.get("flat_bonus", 0.0))
	ctx.crit_chance = float(snapshot.get("crit_rate", 0.0))
	ctx.crit_mult = float(snapshot.get("crit_mult", 2.0))
	var entries: Variant = snapshot.get("add_entries", [])
	if entries is Array:
		for entry in entries:
			ctx.add_entries.append(entry)
	ctx.element = GameConst.Element.KIN
	ctx.is_first_hit_of_wave = is_wave_first_hit()   # B.4：波首命中位（SYN_FIRST_STRIKE）
	# R199 F10：玩家血线条件输入（PLAYER_HP_BELOW 背水 / PLAYER_HP_ABOVE 壁垒——
	# 条件真源 synergy_rules.gd 直读 ctx.player_hp_pct）。近战 builder 此前零写口，
	# 字段恒默认 1.0：背水残血永不加伤（死卡）、壁垒反向失真为残血仍恒触发。投射物
	# 路径先例 projectile_base.gd:486 同源（_player_hp_pct → player.get_hp_pct）。
	ctx.player_hp_pct = player_hp_pct()
	if p_target != null:
		ctx.pos = p_target.global_position
		ctx.target_resist = _read_resist(p_target)
	inject_vuln_pool(ctx, p_target)
	inject_relic_pools(ctx, p_target)                # B.2：遗物命中时点独立乘区（TROPHY/MOMENTUM）
	return ctx


func collect_context_mults(p_ctx: DamageContext, p_tctx: TraitContext) -> void:
	# 词条乘区预聚合（§4.4 ②：光束/近战路径）+ 目标侧易伤乘区注入（A2 §1.8 vuln 池）
	if trait_stack != null:
		for pool in trait_stack.collect_mult_pools(p_tctx):
			p_ctx.mult_pools.append(pool)
	inject_vuln_pool(p_ctx, p_tctx.target)
	inject_relic_pools(p_ctx, p_tctx.target)         # B.2：同 ctx 二次注入由 has_mult_pool 去重


func get_threshold(p_threshold_id: StringName) -> Dictionary:
	# 通用质变阈值查询（A3 §3.11；threshold_traits 声明，词条效果侧消费）
	# R220 刀3②：预索引 O(1) 字典读（原逐条 StringName(str()) 线性扫——命中链热点）；
	# size 防御校验兜数据侧 mutate（测试直改 threshold_traits 场景自动重建索引）
	if data == null:
		return {}
	if _threshold_index.size() != data.threshold_traits.size():
		_rebuild_threshold_index()
	return _threshold_index.get(p_threshold_id, {})


func settle_aoe(p_pos: Vector2, p_radius: float, p_atk: float, p_secondary: bool,
		p_exclude: Node2D = null) -> void:
	# 圆查询逐敌独立结算（死亡新星/TH_SIZE_NOVA 冲击波/武器 AOE 通道；网格距离精判口径）。
	# p_exclude：主结算目标排除（冲击波不重复结算本跳直击目标，同构 Homing._blast_secondaries）
	# 落血口径双轨：真件管线 resolve 内部落血（9b）；透传桩由本方法落血（见循环内注释）
	if enemy_grid == null or damage_pipeline == null:
		return
	var candidates: Array[Node2D] = []
	candidates.append_array(enemy_grid.query_circle(p_pos, p_radius))
	for target in candidates:
		if target == null or target == p_exclude or bool(target.get("dead")):
			continue
		var ctx := DamageContext.make()
		ctx.source_uid = uid
		ctx.target = target
		ctx.target_uid = int(target.get("uid"))
		ctx.frame_stamp = GameConfig.frame_stamp
		ctx.base_atk = maxf(p_atk, 0.0)
		ctx.element = GameConst.Element.KIN
		if p_secondary:
			ctx.hit_flags |= GameConst.HIT_IS_AOE_SECONDARY
		ctx.pos = (target as Node2D).global_position
		var result: DamageResult = damage_pipeline.call(&"resolve", ctx)
		if result == null:
			continue
		# 落血口径双轨（审查修复 A）：真件 DamagePipeline 九步 9b 在 resolve 内部已
		# take_result 落血（_apply_to_target——killed 判定/死亡广播唯一执行点），调用方
		# 再落血即 AOE 范围伤害 ×2（TH_SIZE_NOVA/MEC_KILL_BLAST/遗物清屏冲击）；透传桩
		# resolve 只算不落血，落血职责在调用方（pkg3 桩用例锁定口径，保持不变）。
		if damage_pipeline is DamagePipeline:
			continue
		if target.has_method(&"take_result"):
			target.call(&"take_result", result)


func acquire_target() -> Node2D:
	# 索敌（目标策略：NEAREST/FOREMOST/LOWEST_HP/LOCKED——M1 实现 NEAREST 全量口径）
	# R220 刀7：单拍缓存——tick 栈内 has_target_now 与 try_fire→aim_direction 的二次
	# query_nearest(1600) 全网格扫合并为一次（缓存键 tick 拍序 + _in_tick 栈标记；
	# 直调 try_fire/测试路径栈外恒真查，语义逐位保真；query_nearest 不过滤 dead，
	# 帧内二查本就同值——缓存无漂移）
	# R293 模拟刀 B：帧级共享——② 段网格为 ④ 冻结快照（敌位只在 ⑤ 变，R231 语义
	# 锚），同帧同键 query_nearest 结果恒同 ⇒ 经 SimQueryShare 跨武器共享（键=网格
	# 实例+纪元三轴〔② 相位括号/frame_stamp/_stamp〕+origin+reach；括号由 player.tick
	# 武器段开合——括号/栈外恒原查询；惰性首查者付费留在本武器计时窗内——武9µs/
	# 副武µs 归因链不断）。条目存裸最近节点，下方 dead 过滤逐调用执行
	#（与原口径逐位同法——前序武器击杀唯一敌时本拍正确返 null 非假阳）。实查调用
	# 形状保持 query_nearest（r220 计数桩「一拍恰 1 次」锁）；空场 is_empty() O(1)
	# 早退（R287 口径：快照空 ⇒ 任何查询必零候选）。slash 模式覆写见 OrbitWeapon
	#（1600 圆扫条目派生——与基类条目分命名空间）。
	if _in_tick and _acq_cache_seq == _tick_seq:
		return _acq_cache_target
	var found: Node2D = null
	if enemy_grid != null:
		var origin := muzzle_position()
		var cand := SimQueryShare.shared_nearest(_in_tick, enemy_grid,
			origin, SimQueryShare.TARGET_REACH)
		if cand != null and not bool(cand.get("dead")):
			found = cand
	_acq_cache_seq = _tick_seq
	_acq_cache_target = found
	return found


func aim_direction() -> Vector2:
	# 开火指向：目标方向 / 无目标回退 UP（全自动开火持续）
	var target := acquire_target()
	if target != null:
		var dir := (target.global_position - muzzle_position()).normalized()
		if dir != Vector2.ZERO:
			return dir
	return AIM_FALLBACK


func muzzle_position() -> Vector2:
	# 出射点（宿主位置；武器随宿主平移）。弹道/自导（R25）/激光（R201）子类覆写为
	# 化身出膛口；力场型近战保持本体位（W8/W9 圆心锚角色——分类语义）。
	return global_position


func _element_pool() -> Array[int]:
	# R220 刀7：元素附魔候选池构建（原 _shot_element 每调用逐词条扫描——hoist 出
	# pellets 循环一次构建；空池 = KIN 回退口径不变）
	var elems: Array[int] = []
	if trait_stack == null:
		return elems
	for tb in trait_stack.traits:
		var td: Variant = tb.get("data")
		if td != null and int(td.pool) == GameConst.PoolClass.ELEM \
				and (td as TraitData).params.has("element"):
			elems.append(int((td as TraitData).params["element"]))
	return elems


func _element_pick(p_elems: Array[int]) -> int:
	# R220 刀7：逐发元素掷取（★必须留在 pellets 循环内——多元素逐发独立随机语义
	# 保真，方案书刀7 评审修正：hoist 的只是候选数组构建，randi 逐发）
	if p_elems.is_empty():
		return GameConst.Element.KIN
	return p_elems[randi() % p_elems.size()]


func _shot_element() -> int:
	# R26 元素附魔（用户点名「每个武器选择元素附魔，攻击颜色变对应」）：
	# 武器挂 ELE 卡 → 该武器攻击即该元素（弹体配色/伤害元素/附着统一）；
	# 多元素共存 → 每发随机取一（点燃+冰 = 一会红一会蓝）。
	# R220 刀7：内部改经 _element_pool + _element_pick 两步（行为逐位等价；
	# ballistic pellets 热路径 hoist 候选构建后循环内只留 randi 掷取）
	return _element_pick(_element_pool())


func dominant_element() -> int:
	# R87 元素共鸣染色源：首个非中性附魔元素（单元素=该色；多元素=主色稳定显示，
	# 弹体仍逐发随机——染色与弹道口径解耦，避免化身每帧闪色）
	if trait_stack == null:
		return GameConst.Element.KIN
	for tb in trait_stack.traits:
		var td: Variant = tb.get("data")
		if td != null and int(td.pool) == GameConst.PoolClass.ELEM 				and (td as TraitData).params.has("element") 				and int((td as TraitData).params["element"]) != GameConst.Element.KIN:
			return int((td as TraitData).params["element"])
	return GameConst.Element.KIN


func _avatar_muzzle(p_no_screen_clamp: bool = false) -> Vector2:
	# 悬浮化身出膛口（R25 发射口对齐）：子弹从对应武器化身位置出膛——
	# 「发射口和武器对不上」禁令；化身不可用回退本体位。p_no_screen_clamp：
	# R253 激光族豁免 12px 屏幕钳制（束锚纯视觉——防贴边束与化身脱钩）
	if player != null and is_instance_valid(player) 			and player.has_method(&"weapon_muzzle_global"):
		return player.call(&"weapon_muzzle_global", self, p_no_screen_clamp)
	return global_position


func level_up() -> void:
	# 武器精通卡应用 → leveled 信号；Lv5 = 质变置位（R243 §7.1：transcended 首次置位
	# + 面板失效 + 节拍刷新 + 子类 _on_transcend 重铺钩子 + 质变里程碑播报——文本 =
	# display_name + " · " + 质变名（transcend.name；无名回落「终极形态」），mult=0 表
	# 纯里程碑）。幂等双闸：① level 已帽（==MAX_LEVEL）时本函数整体短路——重复
	# level_up 不递增也不再触发；② transcended 单次置位（防异常路径二次播报）。
	if level < MAX_LEVEL:
		level += 1
		_invalidate_panel()
		refresh_fire_interval()          # R29：精通改 cd/rof 终值 → 当前倒计时同步缩放
		leveled.emit(level)
		if level >= MAX_LEVEL and data != null and not transcended:
			transcended = true
			_invalidate_panel()
			refresh_fire_interval()      # 质变 atk_mult 入面板 → 当前倒计时同步缩放
			_on_transcend()              # 子类重铺钩子（行为参数/实体即时切换第二形态）
			var t_name := String(_transcend_params().get("name", ""))
			var suffix := " · " + t_name if not t_name.is_empty() else " · 终极形态"
			EventBus.emit_trait_milestone(StringName("max_%s" % String(data.id)),
				String(data.display_name) + suffix, 0.0)
			DebugStats.count(&"weapon_max_milestone")


func _transcend_params() -> Dictionary:
	# R243 §7.1 质变形态参数（形态段可选键 "transcend": {...}——validator §1.5 结构校验；
	# 遍历 melee/ballistic/laser/homing 四段读首个在册段；无 → 空表（无名时播报回落
	# 「终极形态」、atk_mult 缺省 1.0 = 恒等）。
	# QA-heal r1 常量税收口：贴脸豁免圈/化身扫弧逐帧经 _tc_mult 触达，原每调新建四段
	# 数组字面量——改 data 引用锚缓存（data 运行期不变；换 data 即重算；命中段原样
	# 返引用与旧实现同源，空表共享单例——消费侧只读 .get 零落改）
	if _tc_params_built and _tc_params_src == data:
		return _tc_params
	_tc_params_built = true
	_tc_params_src = data
	_tc_params = {}
	if data != null:
		for seg: Variant in [data.melee, data.ballistic, data.laser, data.homing]:
			if seg is Dictionary and (seg as Dictionary).has("transcend"):
				var tc: Variant = (seg as Dictionary)["transcend"]
				if tc is Dictionary:
					_tc_params = tc
					break
	return _tc_params


func _on_transcend() -> void:
	# 质变重铺钩子（§7.1）：子类覆写——行为参数（半径/弧角/orbs/外环等）与常驻实体
	# 在此按 transcended 切第二形态；基类空实现（形态参数零消费武器零位移）。
	pass


func _tc_mult(p_key: String, p_default: float) -> float:
	# 质变数值键读取助手（仅 transcended 生效）：形态参数消费侧统一口——未质变恒返
	# p_default（=键缺省，零位移）；质变后读 transcend.<key>（缺省同 p_default）。
	if not transcended:
		return p_default
	return float(_transcend_params().get(p_key, p_default))


# ── 内部 ──────────────────────────────────────────────────────────
func _player_rof_mult() -> float:
	# 玩家侧射速合成倍率：过载咆哮（角色技能）× 地图祝福·射速（词缀二期「狂热」+6%，
	# 数值真源 map_table.gd）× 无技能角色 CDR 折算（comp_rof_mult——改造者·枢契约，
	# player.refresh_skill_cd 真源、有技能角色恒 1.0；此前零消费为死写，角色机制补偿
	# 未兑现）——基类与 BallisticWeapon 覆写共用（两形态同一口径）
	if player == null or not is_instance_valid(player):
		return 1.0
	return maxf(float(player.get("rof_mult")) * float(player.get("map_rof_mult"))
		* float(player.get("comp_rof_mult"))
		* (1.0 + float(extern_buffs.get(&"rof", 0.0))), 0.1)   # R246 extern rof 尾乘（Ω-超频）


func knockback_force() -> float:
	# 武器击退力（R7：击退权移交霰弹枪——data.ballistic.knockback；0 = 无击退。
	# 质量分级/冲量衰减/击退小字均在 Enemy.knockback 内统一处理）
	if data == null:
		return 0.0
	var kb := float(data.ballistic.get("knockback", 0.0))
	if trait_stack != null:
		kb += float(trait_stack.aggregate_panel().get("add_knock", 0.0))   # 动能冲击词条（R12）
	return kb


func _proj_spd_mult() -> float:
	# AFF_PROJ_SPD（add_spd 池）弹速 ×(1+Σ)——弹道/自导两形态开火参数共用
	#（2026-09-13 死卡接线：此前该池全工程零消费）
	# R246 extern spd 尾乘（fission Ω-推进——player 注入，空表恒等）
	var mult := 1.0
	if trait_stack != null:
		mult = 1.0 + float(trait_stack.aggregate_panel().get("add_spd", 0.0))
	return mult * (1.0 + float(extern_buffs.get(&"spd", 0.0)))


func _proj_size_mult() -> float:
	# AFF_AREA（add_size 池）弹体碰撞半径 ×(1+Σ)——同上死卡接线（与 MEC_SIZE_STACK
	# 的 size_mult 独立叠乘：一为常驻池、一为该词条专属质变通道）
	# R246 extern size 尾乘（fission Ω-聚焦——player 注入，空表恒等）
	var mult := 1.0
	if trait_stack != null:
		mult = 1.0 + float(trait_stack.aggregate_panel().get("add_size", 0.0))
	return mult * (1.0 + float(extern_buffs.get(&"size", 0.0)))


func _fire_interval() -> float:
	# 节拍间隔：BALLISTIC = 1/rof（子类覆写射速口径）；其余形态 = cd × (1−ΣCDR)
	if data == null:
		return 1.0
	if data.form == GameConst.WeaponForm.BALLISTIC:
		var rof := clampf(get_stat(&"rof"), 0.1, _cap_rof())
		return 1.0 / (rof * _player_rof_mult())
	var cd := maxf(get_stat(&"cd"), 0.01)
	var cdr := 0.0
	if trait_stack != null:
		cdr = float(trait_stack.aggregate_panel().get("add_cdr", 0.0))
	# R226 有意契约变更（用户拍板「肉鸽别搞上限」）：cap_cdr_sum 钳退役（BalanceTables
	# 数据遗留不消费）——AFF_CDR 无限叠全额生效；(1−cdr) 保 0.1 数学地板（间隔不归零，
	# 与技能急速 refresh_skill_cd 同款地板口径；BALLISTIC 侧另有 cap_rof 30/s 射速阀）
	return cd * maxf(1.0 - maxf(cdr, 0.0), 0.1) / _player_rof_mult()


func refresh_fire_interval() -> void:
	# R29 迟到减CD（用户反馈「角色cd应该立刻见效、减少」）：减CD/射速词条、满层质变×1.6、
	# 精通升级、过载咆哮等改节拍的时点，已在倒计时的冷却按新旧间隔比例立刻缩短——
	# 不再等本回合自然走完才享受新射速。节拍变长（增益到期）不回罚：剩余原样保留，
	# 下一周期自然按新节拍（防「增益结束反被拖慢」的负反馈手感）。冷却中且基准未知
	#（_last_interval=0，如 setup 后未开火即挂卡）只登记基准不缩放。
	if data == null:
		return
	var new_interval := _fire_interval()
	if _last_interval <= 0.0 or is_equal_approx(new_interval, _last_interval):
		_last_interval = new_interval
		return
	if cooldown_left > 0.0 and new_interval < _last_interval:
		cooldown_left = minf(cooldown_left * new_interval / _last_interval, new_interval)
	_last_interval = new_interval


func _cap_rof() -> float:
	# 单武器射速封顶 30/s（性能双护栏）
	if GameConfig.balance != null:
		return GameConfig.balance.cap_rof_per_weapon
	return 30.0


func _on_tick_post(p_game_delta: float) -> void:
	# 子类逐帧附加调度钩子（光束推进/近战实体推进等）
	pass


func _invalidate_panel() -> void:
	_panel_cache = {}
	# R220 刀5：主栈运行世代 bump + 清借出池（三失效面统一口——①选卡 attach_trait
	# ②MILESTONE 质变 value_mult ③MULT/ELE 取优换定义在 trait_stack.attach 内自 bump；
	# 方案书刀5：只重置运行位不重建词条集 = 新弹带旧栈，故借出件按世代弃件重建）
	if trait_stack != null:
		trait_stack.bump_runtime_generation()


# ── R220 刀12：帧率优先弹生成配额闸（player 侧配额口的武器侧消费） ──────────
func _spawn_quota_allow(p_want: int, p_due: int = 0) -> int:
	# 刀12 配额闸（ballistic pellets 循环消费点）：p_want=本拍新丸、p_due=到期顺延丸
	# （优先通道——due 池先放行，未获部分回落普通池竞争）。帧率优先经 player 配额口
	# 放行（每步 32 发/物理步全组硬帽，新丸+补发合计 ≤32）；超配部分顺延 1-2 帧交错
	# 散开（每拍顺延对半分两帧到期——防预算恢复瞬间再对齐）+ 队列帽溢出丢弃；
	# 特效优先/无宿主 → 全放行（零行为差——契约「特效优先=无配额」）。
	var want_total := p_want + p_due
	if not PerfGovernor.frame_priority() or player == null or not is_instance_valid(player) \
			or not player.has_method(&"quota_request"):
		return want_total
	var allowed := 0
	var due_need := p_due
	if due_need > 0 and player.has_method(&"quota_request_due"):
		var due_take := int(player.call(&"quota_request_due", due_need))
		allowed += due_take
		due_need -= due_take
	allowed += int(player.call(&"quota_request", p_want + due_need))
	if allowed < want_total:
		_defer_shots(want_total - allowed)
	return allowed


func _defer_shots(p_overflow: int) -> void:
	# 刀12 超配顺延记账：quota_deferred 计数 + 1-2 帧交错散开 + 队列帽溢出丢弃
	var dropped := 0
	if player != null and is_instance_valid(player) and player.has_method(&"quota_enqueue"):
		dropped = int(player.call(&"quota_enqueue", p_overflow))
	if dropped > 0:
		DebugStats.count(&"quota_dropped", dropped)
	var queued := p_overflow - dropped
	if queued > 0:
		DebugStats.count(&"quota_deferred", queued)
		var half := (queued + 1) / 2
		_quota_def_a += half                     # 下一帧到期一半
		_quota_def_b += queued - half            # 下下帧到期余半（1-2 帧交错散开）


func _tick_quota_defer() -> void:
	# 刀12 顺延推进（tick 开头）：到期份额出队入 _quota_pending——下一次 try_fire 的
	# pellets 并入补发（编队 offset 随新总数重排；队列占用回落 player 侧帽记账）
	if _quota_def_a <= 0 and _quota_def_b <= 0:
		return
	var due := _quota_def_a
	_quota_def_a = _quota_def_b
	_quota_def_b = 0
	if due > 0:
		_quota_pending += due
		if player != null and is_instance_valid(player) and player.has_method(&"quota_dequeue"):
			player.call(&"quota_dequeue", due)


func _read_resist(p_target: Node2D) -> float:
	# 目标抗性快照（KIN 通道；光束/近战为动能伤害）
	if p_target != null and p_target.has_method(&"get_resist"):
		return float(p_target.call(&"get_resist", GameConst.Element.KIN))
	return 0.0


func inject_vuln_pool(p_ctx: DamageContext, p_target: Node2D) -> void:
	# 目标侧易伤乘区注入（A2 §1.8：vuln 池在⑤入池——冰冻易伤 ×1.25 正式路径）。
	# 集成包 B.7 去重：build_damage_context 与 collect_context_mults 双入口共用本方法，
	# 同一 ctx 已含 vuln 池时跳过（管线防御层虽可 max 合并，注入侧去重保名额/审计干净）。
	if p_target == null or has_mult_pool(p_ctx, &"vuln"):
		return
	var state: Variant = p_target.get("elemental")
	if state is ElementalState:
		var factor := (state as ElementalState).get_vuln_factor()
		if factor > 1.0:
			p_ctx.mult_pools.append({
				"pool_id": &"vuln",
				"source_uid": 0,
				"contrib": factor - 1.0,
				"cap_pool": factor - 1.0,
				"priority": 0,
			})


func inject_relic_pools(p_ctx: DamageContext, p_target: Node2D) -> void:
	# 遗物命中时点独立乘区（集成包 B.2：REL_BOSS_TROPHY / REL_MOMENTUM——
	# 数值/池名/目标 tag 全部由 RelicData.params 数据驱动，问询 RelicHandler）
	if relic_handler != null:
		relic_handler.inject_hit_mult_pools(p_ctx, p_target)


func is_wave_first_hit() -> bool:
	# 波首命中位（B.4 接线：SYN_FIRST_STRIKE「本波首杀前」条件——
	# WaveDirector.wave_first_kill_done 置位前均为 true；无导演引用（测试环境）→ false 安全）
	return wave_director != null and not wave_director.wave_first_kill_done


func player_hp_pct() -> float:
	# R199 F10：玩家血线条件输入共用口（近战 build_damage_context + 激光束自建 ctx——
	# laser_beam._settle_one_tick 经本武器问询；无玩家/未暴露 get_hp_pct → 1.0 满血安全值，
	# 投射物路径 projectile_base._player_hp_pct 同式）
	if player != null and is_instance_valid(player) and player.has_method(&"get_hp_pct"):
		return float(player.call(&"get_hp_pct"))
	return 1.0


static func has_mult_pool(p_ctx: DamageContext, p_pool_id: StringName) -> bool:
	# ctx 乘区池去重判据（B.7 易伤去重 / 遗物乘区幂等注入共用）
	if p_ctx == null:
		return false
	for pool in p_ctx.mult_pools:
		if StringName(String(pool.get("pool_id", ""))) == p_pool_id:
			return true
	return false
