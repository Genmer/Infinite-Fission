# scripts/loop/blessing_handler.gd
# v0.9.0 BlessingHandler（A8 §1）：波次赐福运行时处理器（对齐 relic/chip handler 模式：
# Node + 注入 + reset_run + 自有 rng 流 + 遥测观测口；不订阅信号——wave_cleared 仲裁在 GameLoop）。
# · 三选一：roll_offers 按可用池加权无放回抽 OFFER_COUNT 项；出牌时过滤：
#   slot1 仅 capacity<6 / slot2 仅 capacity<=4 / heal 仅 hp<max_hp；其余恒入
#  （gold/atk/rof/attach——gold 恒可用，池最小 4）；可用池 <3 时 gold 补位（防御行）。
# · stat 三键 = Option A（A8 §2）：atk/rof/attach 走 ChipHandler.blessing_stats 字典，
#   stat_bonus 套装 ×1.10 之后加和（只加和不参与 ≥2 判定、不被放大）；不占 TraitStack、
#   不可 strip；atk 并入后随芯片 ⑥b 段共享 cap_chip_zone。
# · 跳过无补偿：仅 DebugStats 遥测（无信号）。
class_name BlessingHandler
extends Node

const MIN_WAVE: int = 2                        # 赐福起始波（wave_cleared w>=2 才弹）
const BLESSING_RNG_SEED: int = 999             # 赐福 roll 独立 rng 流（测试可注入）
const GOLD_BASE: int = 20                      # 金币包基础值
const GOLD_PER_WAVE: int = 3                   # 逐波增量
const HEAL_RATIO: float = 0.15                 # 回复 15% 最大生命
const ATK_BONUS: float = 0.04                  # 攻击 +4%
const ROF_BONUS: float = 0.03                  # 射速 +3%
const ATTACH_BONUS: float = 0.05               # 附着强度 +5%
const OFFER_COUNT: int = 3                     # 三选一
const KIND_GOLD: StringName = &"gold"
const KIND_HEAL: StringName = &"heal"
const KIND_ATK: StringName = &"atk"
const KIND_ROF: StringName = &"rof"
const KIND_ATTACH: StringName = &"attach"
const KIND_SLOT1: StringName = &"slot1"
const KIND_SLOT2: StringName = &"slot2"
# 权重表（和=100.0；镜像 = BalanceTables.blessing_weights——双源同值纪律，改一处必改两处）
const BLESSING_WEIGHTS: Dictionary = {
	&"gold": 30.0, &"heal": 15.0, &"atk": 25.0, &"rof": 15.0,
	&"attach": 10.0, &"slot1": 4.0, &"slot2": 1.0,
}

var player: Node2D = null                      # 注入（heal 宿主 / 跳字锚点）
var chip_handler: ChipHandler = null           # 注入（slot 容量 / stat 三键寄存）
var game_loop: GameLoop = null                 # 注入（gold 臂走 _add_gold 唯一写入口）
var popup_manager: PopupManager = null         # 注入（跳字；null 静默跳过）
var hud: HUD = null                            # 注入（slot 臂横幅）
var rng: RandomNumberGenerator = RandomNumberGenerator.new()   # 赐福 roll 流（默认 seed 999）
# ── 遥测（测试观测口） ──
var blessings_granted: int = 0                 # 出牌成功累计
var blessings_skipped: int = 0                 # 跳过累计（无补偿，仅遥测）


func setup(p_deps: Dictionary) -> void:
	# Boot 注入（GameLoop._boot_build_presentation：player/chip_handler/game_loop/popup_manager/hud）
	player = p_deps.get("player")
	chip_handler = p_deps.get("chip_handler")
	game_loop = p_deps.get("game_loop")
	popup_manager = p_deps.get("popup_manager")
	hud = p_deps.get("hud")
	reset_run()


func reset_run() -> void:
	# 重开清零（GameLoop._reset_run_state 调用）：rng 重播种 + 双遥测清零（不订阅信号）
	rng.seed = BLESSING_RNG_SEED
	blessings_granted = 0
	blessings_skipped = 0


func set_rng_seed(p_seed: int) -> void:
	# 测试确定性 / 同种子 roll 序列可复现
	rng.seed = p_seed


# ── 数值 / 池 ─────────────────────────────────────────────────────
func gold_amount(p_wave: int) -> int:
	# 金币包面值（基础值——经 _add_gold 仍吃 K_gold，文案已注明）
	return GOLD_BASE + GOLD_PER_WAVE * maxi(p_wave, 0)


func available_pool(p_wave: int) -> Array[StringName]:
	# 可用池（出牌时过滤，A8 §1）：slot1 仅 capacity<6 / slot2 仅 capacity<=4 / heal 仅
	# hp<max_hp；gold/atk/rof/attach 恒入；按权重表插入序返回（p_wave 预留——当前过滤不含波次维度）
	var out: Array[StringName] = []
	var capacity := chip_handler.slot_capacity() \
		if chip_handler != null else ChipHandler.CHIP_SLOT_CAP   # 无 handler → slot 类不出池（apply 同门）
	out.append(KIND_GOLD)
	if player != null and is_instance_valid(player) \
			and float(player.get("hp")) < float(player.get("max_hp")):
		out.append(KIND_HEAL)
	out.append(KIND_ATK)
	out.append(KIND_ROF)
	out.append(KIND_ATTACH)
	if capacity < ChipHandler.CHIP_SLOT_CAP:
		out.append(KIND_SLOT1)
	if capacity <= 4:
		out.append(KIND_SLOT2)
	return out


func roll_offers(p_wave: int) -> Array[Dictionary]:
	# 三选一 roll（自有 999 流）：剩余池加权无放回抽 OFFER_COUNT 项 → 恰 3 项
	# {kind, label, detail}；池 <3 → gold 补位防御行（构造上不可达：gold 恒可用且池最小 4）
	var out: Array[Dictionary] = []
	var remaining := available_pool(p_wave)
	for i in range(OFFER_COUNT):
		if remaining.is_empty():
			out.append(_make_offer(KIND_GOLD, p_wave))   # 防御行（不可达）
			continue
		var kind := _weighted_kind(remaining)
		remaining.erase(kind)                    # 无放回
		out.append(_make_offer(kind, p_wave))
	return out


func apply(p_kind: StringName, p_wave: int) -> bool:
	# 出牌（A8 §1）：门 fail-fast（chip_handler null → false；gold 需 game_loop / heal 需
	# player）；逐臂生效 → 成功统一 blessing_granted 信号 + 双遥测。slot 臂 got<=0（已满 6）
	# → false 不派发信号；未知 kind 拒绝。
	if chip_handler == null:
		return false
	match p_kind:
		KIND_GOLD:
			if game_loop == null:
				return false
			game_loop._add_gold(gold_amount(p_wave))
			_popup("金币包 +%d（基础值）" % gold_amount(p_wave))
		KIND_HEAL:
			if player == null or not is_instance_valid(player):
				return false
			var hp := float(player.get("hp"))
			var max_hp := float(player.get("max_hp"))
			player.set("hp", minf(hp + max_hp * HEAL_RATIO, max_hp))
			_popup("赐福：回复 15% 生命")
		KIND_ATK, KIND_ROF, KIND_ATTACH:
			# stat 三键 = Option A：寄存 ChipHandler.blessing_stats（套装段之后加和）
			var key := &"atk_pct"
			var delta := ATK_BONUS
			var text := "赐福：攻击 +4%"
			if p_kind == KIND_ROF:
				key = &"rof"
				delta = ROF_BONUS
				text = "赐福：射速 +3%"
			elif p_kind == KIND_ATTACH:
				key = &"attach_strength"
				delta = ATTACH_BONUS
				text = "赐福：附着强度 +5%"
			chip_handler.add_blessing_stat(key, delta)
			chip_handler.invalidate_panels()     # atk/rof/attach 段即时生效（全武器面板失效）
			_popup(text)
		KIND_SLOT1, KIND_SLOT2:
			var got := chip_handler.add_bonus_slots(1 if p_kind == KIND_SLOT1 else 2)
			if got <= 0:
				return false                     # 槽已满 6：无效果不派发信号
			_popup("赐福：芯片槽位 +%d" % got)
			if hud != null:
				hud.show_banner("芯片槽位 +%d" % got)
		_:
			return false                         # 未知 kind 拒绝
	EventBus.emit_blessing_granted(p_kind, p_wave)
	blessings_granted += 1
	DebugStats.count(&"blessing_granted")
	return true


func count_skip() -> void:
	# 跳过（无补偿，仅遥测；无信号）
	blessings_skipped += 1
	DebugStats.count(&"blessing_skipped")


# ── 内部 ──────────────────────────────────────────────────────────
func _weighted_kind(p_pool: Array[StringName]) -> StringName:
	# 池内加权抽取（权重真源 BLESSING_WEIGHTS；消费自有 rng 流——同种子可复现）
	var total := 0.0
	for kind in p_pool:
		total += maxf(float(BLESSING_WEIGHTS.get(kind, 0.0)), 0.0)
	if total <= 0.0:
		return p_pool[0]
	var roll := rng.randf() * total
	for kind in p_pool:
		roll -= maxf(float(BLESSING_WEIGHTS.get(kind, 0.0)), 0.0)
		if roll <= 0.0:
			return kind
	return p_pool[p_pool.size() - 1]


func _make_offer(p_kind: StringName, p_wave: int) -> Dictionary:
	# 选项结构（BlessingUI 文本真源；label/detail 文案冻结于 A8 §1）
	var label := ""
	var detail := ""
	match p_kind:
		KIND_GOLD:
			label = "金币包"
			detail = "获得 %d 金币（基础值）" % gold_amount(p_wave)
		KIND_HEAL:
			label = "小回复"
			detail = "回复 15% 最大生命"
		KIND_ATK:
			label = "攻击强化"
			detail = "攻击 +4%"
		KIND_ROF:
			label = "射速强化"
			detail = "射速 +3%"
		KIND_ATTACH:
			label = "附着强化"
			detail = "附着强度 +5%"
		KIND_SLOT1:
			label = "芯片槽位 +1"
			detail = "芯片槽上限 +1（上限 6）"
		KIND_SLOT2:
			label = "芯片槽位 +2"
			detail = "芯片槽上限 +2（上限 6）"
	return {"kind": p_kind, "label": label, "detail": detail}


func _popup(p_text: String) -> void:
	# 跳字统一口（popup_manager/player 缺失静默跳过——headless/降级不崩溃）
	if popup_manager == null or player == null or not is_instance_valid(player):
		return
	popup_manager.show_text_popup(player.global_position + Vector2(0.0, -60.0), p_text)
