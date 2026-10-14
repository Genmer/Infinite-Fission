# scripts/combat/trait/builtin/trait_effect_fractal.gd
# 几何分裂家族（EF_FRACTAL）：split_request 输出——三重闸门（代数 ≤3 / 单次 ≤8 / 全场软上限）
# 在引擎侧 ProjectileBase.request_split 执行（E-01），本效果只声明请求参数。
# 触发时点：ON_EXPIRE（母弹穿透耗尽或消亡时，A3 §4.4——两路径均收束 _recycle → ON_EXPIRE）。
# 层数递进（二ct 口径重写）：分裂继承不再分层读表（1 层 40% / 2 层 45% 退役）——
# **全部分裂体统一 = 母体当前值 × 70%**（伤害 × hitbox；视觉经 effective_radius
# 自动跟随——主体变大分裂跟着变大，恒 70% 动态）。用户裁定：「所有分裂都应该是
# 只有原伤 70%，不然有点超标，大小范围也只有 70%」。
# TH_FRACTAL_ECHO（A3 §3.11，分裂深度 ≥3）：子代词条定义继承扩展至乘区词条（定义复制、
# 子代条件自评——F-13 口径）——echo 比例增益（原 maxf 60%）随分层读表一并退役。
# R243 §4.5 通道 B（近战臂，w3-trait）：宿主形态双臂化——projectile 缺位而 melee 在场
#（ArcSlash 窗末 / OrbitField._consume_melee_split 派发）时走近战臂，同参数表写
# melee_split_request（count/spread_deg/inherit_ratio/echo 与投射物臂逐位同源）；TH_FRACTAL_ECHO
# 深度判定按臂取源：投射物臂读弹代数、近战臂读子斩代数（p_ctx.melee.generation——ArcSlash
# 字段，子斩 gen+1；OrbitField 无代数键 = 母引爆深度 0，echo 只属链式子代）。
extends TraitEffect

# 二ct：全部分裂统一继承比（伤害 + 尺寸单源；引擎侧 hitbox/掷斧震荡同乘此值）
const SPLIT_INHERIT := 0.7


func handle(p_trait: TraitBase, p_ctx: TraitContext) -> void:
	# 早退守卫放宽（§4.5-2）：ON_EXPIRE 且两宿主全缺位才 return——近战事件
	#（tctx.melee 在场、projectile 恒 null）自此进入本效果。
	if p_ctx.event != GameConst.TraitEvent.ON_EXPIRE:
		return
	if p_ctx.projectile == null and p_ctx.melee == null:
		return
	var count := int(round(p_trait.data.value))
	var spread := float(p_trait.data.params.get("spread_deg", 28.0))
	var inherit := SPLIT_INHERIT                   # 二ct：恒 70%（分层 40/45/echo 60 退役）
	if p_trait.layers >= 2:
		# R60：层 2 枚数 = max(表值, 层 1 枚数 + 1)——品质缩放后层 1 枚数抬升时
		#（蓝 3 / 紫 4 / 金 5），层 2 不再被写死的 count_lv2=3 反超压回（升层减枚）
		count = maxi(int(p_trait.data.params.get("count_lv2", count)), count + 1)
		spread = float(p_trait.data.params.get("spread_deg_lv2", spread))
	var echo := false
	if p_ctx.weapon != null:
		var threshold: Dictionary = p_ctx.weapon.get_threshold(&"TH_FRACTAL_ECHO")
		if not threshold.is_empty() \
				and _split_depth(p_ctx) + 1 >= int(threshold.get("threshold", 3)):
			echo = true                          # 比例增益随分层读表退役（恒 SPLIT_INHERIT）
	var request := {
		"count": count,
		"spread_deg": spread,
		"inherit_ratio": inherit,
		"echo": echo,
	}
	if p_ctx.projectile != null:
		p_ctx.split_request = request
	else:
		# 通道 B 输出槽（ArcSlash._open_child_slashes / OrbitField._consume_melee_split
		# 消费——键集同 split_request；消费侧自带代数闸，本效果只声明请求参数）
		p_ctx.melee_split_request = request


func _split_depth(p_ctx: TraitContext) -> int:
	# 分裂深度（echo 阈值判定输入）：投射物臂 = 弹代数；近战臂 = 子斩代数
	#（melee.generation——ArcSlash 字段；OrbitField 无此键，.get 返 null → 0 母引爆）。
	# Node2D 弱类型取值：属性缺位 .get 返 NIL，int(NIL) 非法——typeof 显式判型。
	if p_ctx.projectile != null:
		return p_ctx.projectile.generation
	var gen_v: Variant = p_ctx.melee.get("generation")
	if typeof(gen_v) == TYPE_INT or typeof(gen_v) == TYPE_FLOAT:
		return int(gen_v)
	return 0
