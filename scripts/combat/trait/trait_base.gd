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
var value_mult: float = 1.0                   # 满层质变乘区（ADD 池：挂至 stack_max 时 ×1.6——聚合侧消费）
var cooldown_left: float = 0.0
var proc_rng: RandomNumberGenerator = null    # 触发概率掷骰流（种子按 id 派生，确定性）
var frame_triggered: bool = false             # 本帧已触发（E-03 重入标记）
var in_dispatch: bool = false                 # 单词条重入保护位
var effect: TraitEffect = null                # effect_id → builtin 处理器（§2.9.2）

var _last_trigger_frame: int = -1             # frame_triggered 的帧号真源（懒重置）


var layer_values: Array[float] = []            # 每层自身数值（R12c：同 ID 不同品级逐层独立贡献）
var layer_rarities: Array[int] = []            # 每层稀有度（显示取最高）


func setup(p_data: TraitData) -> void:
	# 绑定定义 + 解析 effect 处理器 + 掷骰流初始化（种子 = hash(id)，可复现）
	data = p_data
	layers = 1
	layer_values = [p_data.value]
	layer_rarities = [p_data.rarity]
	value_mult = 1.0
	cooldown_left = 0.0
	frame_triggered = false
	in_dispatch = false
	_last_trigger_frame = -1
	proc_rng = RandomNumberGenerator.new()
	proc_rng.seed = hash(p_data.id)
	effect = TraitEffect.resolve(p_data.effect_id)


func stacked_add_total() -> float:
	# 叠层当前生效总值（R14 用户裁定改直接叠加）：每层全额贡献——1 层 12%、2 层 24%，
	# 直接线性，不再递减。同 ID 混品级时各按自身品级数值全额相加。
	var total := 0.0
	for v in layer_values:
		total += v * value_mult
	return total


func td_delta() -> float:
	return data.decay_delta if data != null else 0.0


func max_rarity() -> int:
	# 当前生效定义的稀有度（显示着色用）。R38 并集口径：layer_rarities（ADD 逐层
	# 记账）∪ data.rarity——MULT/ELEM「取优覆盖」后 data 恒为当前生效定义
	#（白首挂+金覆盖 → 金名；金首挂白覆盖 → 金名保留，与 ◆ 徽记语义一致）
	var best := 0
	for r in layer_rarities:
		best = maxi(best, int(r))
	if data != null:
		best = maxi(best, int(data.rarity))
	return best


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
