# scripts/combat/trait/builtin/trait_effect_fractal.gd
# 几何分裂家族（EF_FRACTAL）：split_request 输出——三重闸门（代数 ≤3 / 单次 ≤8 / 全场软上限）
# 在引擎侧 ProjectileBase.request_split 执行（E-01），本效果只声明请求参数。
# 触发时点：ON_EXPIRE（母弹穿透耗尽或消亡时，A3 §4.4——两路径均收束 _recycle → ON_EXPIRE）。
# 层数递进（A3 §4.4）：1 层 = 2 枚/±28°/继承 40%；2 层 = 3 枚/±22°/继承 45%。
# TH_FRACTAL_ECHO（A3 §3.11，分裂深度 ≥3）：子代词条定义继承扩展至乘区词条（定义复制、
# 子代条件自评——F-13 口径），继承比例提升 60%。
extends TraitEffect


func handle(p_trait: TraitBase, p_ctx: TraitContext) -> void:
	if p_ctx.event != GameConst.TraitEvent.ON_EXPIRE or p_ctx.projectile == null:
		return
	var count := int(p_trait.data.value)
	var spread := float(p_trait.data.params.get("spread_deg", 28.0))
	var inherit := float(p_trait.data.value2)
	if p_trait.layers >= 2:
		count = int(p_trait.data.params.get("count_lv2", count))
		spread = float(p_trait.data.params.get("spread_deg_lv2", spread))
		inherit = float(p_trait.data.params.get("inherit_lv2", inherit))
	var echo := false
	if p_ctx.weapon != null:
		var threshold: Dictionary = p_ctx.weapon.get_threshold(&"TH_FRACTAL_ECHO")
		if not threshold.is_empty() \
				and p_ctx.projectile.generation + 1 >= int(threshold.get("threshold", 3)):
			echo = true
			var th_params: Dictionary = threshold.get("params", {})
			inherit = maxf(inherit, float(th_params.get("inherit_ratio", 0.6)))
	p_ctx.split_request = {
		"count": count,
		"spread_deg": spread,
		"inherit_ratio": inherit,
		"echo": echo,
	}
