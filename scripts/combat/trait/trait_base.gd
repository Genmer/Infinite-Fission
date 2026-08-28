# scripts/combat/trait/trait_base.gd
# M-10 TraitBase（架构 §2.9.1）：运行时词条实例。
# · data 为 .tres 定义（只读共享——定义复制=引用复制，E-13）；layers 为运行时叠层（AC-07.4）。
# · 事件闸门：事件钩子声明匹配 → 冷却 → E-03 本帧已触发 → 触发概率掷骰 → 效果分派。
# · 常驻词条（event_hooks 空）不经事件派发——聚合走 TraitStack.aggregate_*（面板/参数侧）。
# · MULT 池乘区词条不经事件派发——贡献在 collect_mult_pools 条件自评（SynergyRules）。
class_name TraitBase
extends RefCounted

var data: TraitData = null                    # 定义（.tres，只读共享）
var layers: int = 1                           # 当前叠层（运行时状态，独立于数据，AC-07.4）
var cooldown_left: float = 0.0
var proc_rng: RandomNumberGenerator = null    # 触发概率掷骰流（种子按 id 派生，确定性）
var frame_triggered: bool = false             # 本帧已触发（E-03 重入标记）
var in_dispatch: bool = false                 # 单词条重入保护位
var effect: TraitEffect = null                # effect_id → builtin 处理器（§2.9.2）

var _last_trigger_frame: int = -1             # frame_triggered 的帧号真源（懒重置）


func setup(p_data: TraitData) -> void:
	# 绑定定义 + 解析 effect 处理器 + 掷骰流初始化（种子 = hash(id)，可复现）
	data = p_data
	layers = 1
	cooldown_left = 0.0
	frame_triggered = false
	in_dispatch = false
	_last_trigger_frame = -1
	proc_rng = RandomNumberGenerator.new()
	proc_rng.seed = hash(p_data.id)
	effect = TraitEffect.resolve(p_data.effect_id)


func can_trigger(p_ctx: TraitContext) -> bool:
	# 冷却 + 概率 + frame_triggered 三闸（架构 §2.9.1 契约）
	if data == null or effect == null:
		return false
	if data.event_hooks.is_empty():
		return false                        # 常驻词条：无事件通道
	if cooldown_left > 0.0:
		return false
	if _last_trigger_frame == GameConfig.frame_stamp:
		return false                        # E-03 本帧已触发
	if data.proc_chance < 1.0:
		if proc_rng == null or proc_rng.randf() > data.proc_chance:
			return false
	return true


func on_event(p_event: int, p_ctx: TraitContext) -> void:
	# 效果入口：闸门 → 内置处理器分发（M-09 派发点按挂载序调用）
	if data == null or effect == null:
		return
	if data.pool == GameConst.PoolClass.MULT:
		return                              # 乘区词条贡献在 collect_mult_pools 求值（hooks 为声明性）
	if not can_trigger(p_ctx):
		return
	if not data.event_hooks.has(p_event):
		return
	if in_dispatch:
		return                              # 单词条重入保护
	in_dispatch = true
	_last_trigger_frame = GameConfig.frame_stamp
	frame_triggered = true
	effect.handle(self, p_ctx)
	in_dispatch = false
	cooldown_left = data.cooldown


func get_contribution(p_ctx: TraitContext) -> float:
	# 乘区贡献（条件自评，注入 DamageContext.mult_pools）：MULT 池经 SynergyRules 求值
	if data == null or data.pool != GameConst.PoolClass.MULT:
		return 0.0
	return SynergyRules.evaluate(self, p_ctx)


func get_decay_sum() -> float:
	# F3 预览值 T(layers)（卡牌 tooltip/DebugStats；结算真源唯一在管线步骤 3）
	if data == null or layers <= 0:
		return 0.0
	return TraitStack.decay_sum(data.value, layers, data.decay_delta)


func reset_runtime() -> void:
	# 分裂继承时的状态重置（层数保留 / 冷却与帧标记清零——按继承规则）
	cooldown_left = 0.0
	frame_triggered = false
	in_dispatch = false
	_last_trigger_frame = -1
