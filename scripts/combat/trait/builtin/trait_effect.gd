# scripts/combat/trait/builtin/trait_effect.gd（基类，架构 §2.9.2）
# 内置效果处理器：effect_id → 类映射（六家族签名同构，按 effect_id 分派）。
# 注册表经脚本路径惰性加载（规避 class_name 循环引用的解析顺序问题）；
# 处理器无实例状态 → 单例缓存。register_custom 为测试/内容扩展注册口
# （链式深度熔断等用例注入自定义效果；运行期不注册任何自定义项）。
class_name TraitEffect
extends RefCounted

# effect_id → 处理器脚本路径（六家族；DataValidator.TECH_EFFECT_IDS 为其镜像注册表）
const _BUILTIN_PATHS: Dictionary = {
	&"EF_STAT": "res://scripts/combat/trait/builtin/trait_effect_stat.gd",
	&"EF_SIZE": "res://scripts/combat/trait/builtin/trait_effect_size.gd",
	&"EF_FRACTAL": "res://scripts/combat/trait/builtin/trait_effect_fractal.gd",
	&"EF_BOUNCE": "res://scripts/combat/trait/builtin/trait_effect_bounce.gd",
	&"EF_ELEMENTAL": "res://scripts/combat/trait/builtin/trait_effect_elemental.gd",
	&"EF_MECH": "res://scripts/combat/trait/builtin/trait_effect_mech.gd",
}

static var _instances: Dictionary = {}        # effect_id -> TraitEffect（单例缓存）
static var _custom: Dictionary = {}           # effect_id -> TraitEffect（测试/内容扩展）


static func resolve(p_effect_id: StringName) -> TraitEffect:
	# effect_id → 处理器实例（未知 → null：DataValidator 启动期已剔除悬空项）
	if _custom.has(p_effect_id):
		return _custom[p_effect_id]
	if _instances.has(p_effect_id):
		return _instances[p_effect_id]
	var path: Variant = _BUILTIN_PATHS.get(p_effect_id)
	if path == null:
		return null
	var script: Resource = load(String(path))
	if script is GDScript:
		var instance: TraitEffect = (script as GDScript).new()
		_instances[p_effect_id] = instance
		return instance
	return null


static func register_custom(p_effect_id: StringName, p_effect: TraitEffect) -> void:
	# 测试/内容扩展注册口（优先于内置映射；仅测试期使用）
	_custom[p_effect_id] = p_effect


static func known_effect_ids() -> Array[StringName]:
	# DataValidator 镜像注册表对账用
	var ids: Array[StringName] = []
	for key in _BUILTIN_PATHS:
		ids.append(key)
	for key in _custom:
		ids.append(key)
	return ids


func handle(p_trait: TraitBase, p_ctx: TraitContext) -> void:
	# 抽象：效果执行（子类覆写；基类空实现保证签名同构）
	pass


func evaluate_contribution(p_trait: TraitBase, p_ctx: TraitContext) -> float:
	# 条件乘区贡献（MULT 池词条经 SynergyRules 于 TraitBase.get_contribution 求值）
	return 0.0
