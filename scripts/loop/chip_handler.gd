# scripts/loop/chip_handler.gd
# v0.7.0 ChipHandler（A6 §2）：芯片运行时处理器（对齐 relic_handler 模式：Node + 注入 +
# reset_run + bind_events 幂等 + 遥测观测口）。
# · 槽位：3 槽（wave 1/10/20 经 EventBus.chip_slot_unlocked 逐波解锁）；同 id 唯一；
#   芯片数值取 values[rarity]（rarity 0~3 = 白/蓝/紫/金）。
# · stat 消费分两路：max_hp 装备即改 player.max_hp 并回补 HP（A6 §2 特殊键）；
#   其余 stat_key 由消费点问询 stat_bonus（atk_pct/rof/crit/critdmg → 武器面板，
#   gold/xp → GameLoop，attach_strength → ElementalSystem——A6 §3）。
# · 芯片 ATK% 不入 weapon trait_stack，走管线 ⑥b 芯片独立乘区段（cap_chip_zone 钳制）。
# · rarity roll 单一真源 = CardGenerator.rarity_weights_for（静态纯函数）+ 自有 rng 流
#  （默认 seed 4242，测试可注入）。
class_name ChipHandler
extends Node

const MAX_CHIP_SLOTS: int = 3
const CHIP_RNG_SEED: int = 4242
const CONVERT_RATIO: float = 0.5               # Boss 掉落转金币 = round(定价 × 0.5)
# 芯片定价（主 Agent 裁定 2026-09-01：独立于卡架的更高档——常驻件定价 白60/蓝110/紫180/金300）
const CHIP_PRICES: Dictionary = {0: 60, 1: 110, 2: 180, 3: 300}

var registry: DataRegistry = null              # 注入（chip id → ChipData）
var player: Node2D = null                      # 注入（max_hp 键宿主 / 全武器面板失效宿主）
var rng: RandomNumberGenerator = RandomNumberGenerator.new()   # 芯片 roll 流（seed 4242）
var unlocked_slots: int = 0                    # 已解锁槽位数（0~3；wave 1/10/20 解锁）
var equipped: Array[Dictionary] = []           # 已装备（{chip: ChipData, rarity: int}）
# ── 遥测（测试观测口） ──
var chips_granted: int = 0                     # 芯片装备成功累计（Boss 掉落 + 商店购买共用 equip 单点）
var chips_converted: int = 0                   # 转金币次数（池空/已持有/槽满）
var gold_from_convert: int = 0                 # 转金币累计面值

var _events_bound: bool = false


func setup(p_deps: Dictionary) -> void:
	# Boot 注入（GameLoop._boot_build_actors：registry/player——先于芯片流就绪）
	registry = p_deps.get("registry")
	player = p_deps.get("player")
	reset_run()


func reset_run() -> void:
	# 重开清零（GameLoop._reset_run_state 调用；装备/槽位每场重来 + rng 重播种）
	equipped.clear()
	unlocked_slots = 0
	rng.seed = CHIP_RNG_SEED
	chips_granted = 0
	chips_converted = 0
	gold_from_convert = 0


func set_rng_seed(p_seed: int) -> void:
	# 测试确定性 / 同种子掉落序列可复现
	rng.seed = p_seed


func bind_events() -> void:
	# 首次调用绑定（幂等守卫）；槽位解锁事件与死亡归还无读取竞态（波次解锁在
	# wave_started 后派发），本订阅仍按纪律在 Boot 期提前连接。
	if _events_bound:
		return
	_events_bound = true
	EventBus.chip_slot_unlocked.connect(_on_chip_slot_unlocked)


func _on_chip_slot_unlocked(p_slot: int) -> void:
	# 槽位解锁（幂等取大；越界入参钳 1~3 防御）
	unlocked_slots = maxi(unlocked_slots, clampi(p_slot, 1, MAX_CHIP_SLOTS))


# ── 查询 ──────────────────────────────────────────────────────────
func free_slots() -> int:
	# 空槽 = 已解锁槽 − 已装备（审查裁定 2026-09-01：解锁门控真实生效——
	# 未解锁即 0 空槽，w1/w10/w20 节奏约束商店购买与 Boss 掉落转金币）
	return maxi(unlocked_slots - equipped.size(), 0)


func is_equipped(p_chip_id: StringName) -> bool:
	for entry in equipped:
		var chip: ChipData = entry.get("chip")
		if chip != null and chip.id == p_chip_id:
			return true
	return false


func equip(p_chip_id: StringName, p_rarity: int) -> bool:
	# 装备（五门 fail-fast）：registry null / get_chip null / 已装备 / 无空槽 → false。
	# 成功：入列 + max_hp 键特殊处理（max_hp 上抬 + HP 等量回补，钳新上限）+ 全武器面板失效。
	if registry == null:
		return false
	var data := registry.get_chip(p_chip_id)
	if data == null or is_equipped(p_chip_id) or free_slots() <= 0:
		return false
	var rarity := clampi(p_rarity, 0, data.values.size() - 1)
	equipped.append({"chip": data, "rarity": rarity})
	if data.stat_key == &"max_hp" and player != null and is_instance_valid(player):
		var value := float(data.values[rarity]) if data.values.size() > 0 else 0.0
		var new_max := float(player.get("max_hp")) + value
		player.set("max_hp", new_max)
		player.set("hp", minf(float(player.get("hp")) + value, new_max))
	_invalidate_all_weapon_panels()
	chips_granted += 1
	DebugStats.count(&"chip_equipped")
	return true


func stat_bonus(p_stat: StringName) -> float:
	# Σ 已装备同 stat_key 芯片的 values[rarity]（消费点唯一问询口；无装备 → 0.0）
	var total := 0.0
	for entry in equipped:
		var chip: ChipData = entry.get("chip")
		if chip == null or chip.stat_key != p_stat:
			continue
		var rarity := clampi(int(entry.get("rarity", 0)), 0, chip.values.size() - 1)
		if chip.values.size() > 0:
			total += chip.values[rarity]
	return total


func slot_snapshot() -> Array[Dictionary]:
	# 槽位面板快照（ShopUI.set_chip_slots 消费）：已装备项
	# {chip_id, display_name, stat_key, rarity, value_text}；空槽 {} 占位至 MAX_CHIP_SLOTS。
	var out: Array[Dictionary] = []
	for entry in equipped:
		var chip: ChipData = entry.get("chip")
		if chip == null:
			out.append({})
			continue
		var rarity := clampi(int(entry.get("rarity", 0)), 0, chip.values.size() - 1)
		var value_text := ""
		if chip.values.size() > 0:
			if chip.stat_key == &"max_hp":
				value_text = "+%d" % int(round(chip.values[rarity]))
			else:
				value_text = "+%d%%" % int(round(chip.values[rarity] * 100.0))
		out.append({
			"chip_id": chip.id,
			"display_name": chip.display_name,
			"stat_key": chip.stat_key,
			"rarity": rarity,
			"value_text": value_text,
		})
	while out.size() < MAX_CHIP_SLOTS:
		out.append({})
	return out


# ── 商店货架 / Boss 掉落 ──────────────────────────────────────────
func roll_shop_offers(p_wave: int) -> Array[Dictionary]:
	# 商店芯片货架（未持有池按 id 排序无放回抽取）：格数 = 1（wave<10 或可用 <2）否则 2；
	# 每格 {chip_id, rarity, price}（契约键）+ display_name/value_text（显示装饰键，
	# ShopUI 无 registry 引用——A6 §4 留痕）；池空 → []（空架 disabled）。
	var out: Array[Dictionary] = []
	if registry == null:
		return out
	var pool := _unowned_pool()
	if pool.is_empty():
		return out
	var count := 1
	if p_wave >= 10 and pool.size() >= 2:
		count = 2
	var remaining := pool.duplicate()
	for i in range(count):
		if remaining.is_empty():
			break
		var idx := rng.randi_range(0, remaining.size() - 1)
		var chip_id: StringName = remaining[idx]
		remaining.remove_at(idx)                 # 无放回
		var rarity := roll_rarity(p_wave)
		out.append({
			"chip_id": chip_id,
			"rarity": rarity,
			"price": price_for_rarity(rarity),
			"display_name": _chip_display_name(chip_id),
			"value_text": _chip_value_text(chip_id, rarity),
		})
	return out


func grant_boss_chip(p_wave: int) -> Dictionary:
	# Boss 芯片掉落（A6 §6）：{granted, chip_id, rarity, converted_gold}。
	# 可用池空 / roll 已持有 / 无空槽 → 转金币（convert_gold；遥测 chips_converted/
	# gold_from_convert）；其余 equip 成功 → granted=true。
	var out := {"granted": false, "chip_id": &"", "rarity": 0, "converted_gold": 0}
	if registry == null:
		return out
	var rarity := roll_rarity(p_wave)
	out["rarity"] = rarity
	var pool := _full_pool()
	if pool.is_empty():
		out["converted_gold"] = _convert(rarity)
		return out
	var chip_id: StringName = pool[rng.randi_range(0, pool.size() - 1)]
	out["chip_id"] = chip_id
	if is_equipped(chip_id) or free_slots() <= 0:
		out["converted_gold"] = _convert(rarity)
		return out
	if equip(chip_id, rarity):
		out["granted"] = true
		return out
	out["converted_gold"] = _convert(rarity)     # equip 五门兜底（理论不可达）
	return out


func price_for_rarity(p_rarity: int) -> int:
	return int(CHIP_PRICES.get(clampi(p_rarity, 0, 3), 0))


func convert_gold(p_rarity: int) -> int:
	return int(round(float(price_for_rarity(p_rarity)) * CONVERT_RATIO))


func roll_rarity(p_wave: int) -> int:
	# 稀有度 roll：权重表单一真源 CardGenerator.rarity_weights_for（A3 §6.1 公式）
	# + 自有 rng 流（与卡牌/金币流独立，同种子可复现）
	var weights := CardGenerator.rarity_weights_for(p_wave)
	return int(_weighted_key(weights))


# ── 内部 ──────────────────────────────────────────────────────────
func _unowned_pool() -> Array[StringName]:
	# 未持有芯片池（按 id 排序——确定性；roll 抽取在调用方）
	var out: Array[StringName] = []
	if registry == null:
		return out
	for id in registry.chips:
		if not is_equipped(id):
			out.append(id)
	out.sort()
	return out


func _full_pool() -> Array[StringName]:
	# 全量芯片池（按 id 排序；Boss 掉落 roll 全池——已持有 → 转金币语义）
	var out: Array[StringName] = []
	if registry == null:
		return out
	for id in registry.chips:
		out.append(id)
	out.sort()
	return out


func _convert(p_rarity: int) -> int:
	# 转金币单点（遥测累计；面值 = convert_gold(rarity)）
	var gold := convert_gold(p_rarity)
	chips_converted += 1
	gold_from_convert += gold
	DebugStats.count(&"chip_converted")
	DebugStats.count(&"chip_convert_gold", gold)   # v0.7.0 U5：转金币面值遥测
	return gold


func _chip_display_name(p_chip_id: StringName) -> String:
	# 货架显示名（registry 直查；悬空 id → id 字面量降级）
	var data := registry.get_chip(p_chip_id) if registry != null else null
	return data.display_name if data != null else String(p_chip_id)


func _chip_value_text(p_chip_id: StringName, p_rarity: int) -> String:
	# 货架档位值文本（与 slot_snapshot 同口径）
	var data := registry.get_chip(p_chip_id) if registry != null else null
	if data == null or data.values.is_empty():
		return ""
	var rarity := clampi(p_rarity, 0, data.values.size() - 1)
	if data.stat_key == &"max_hp":
		return "+%d" % int(round(data.values[rarity]))
	return "+%d%%" % int(round(data.values[rarity] * 100.0))


func _weighted_key(p_weights: Dictionary) -> Variant:
	# 权重随机抽取（同 CardGenerator._weighted_key 口径；消费自有 rng 流）
	var total := 0.0
	for key in p_weights:
		total += maxf(float(p_weights[key]), 0.0)
	if total <= 0.0:
		return null
	var roll := rng.randf() * total
	for key in p_weights:
		roll -= maxf(float(p_weights[key]), 0.0)
		if roll <= 0.0:
			return key
	return p_weights.keys().back()


func _invalidate_all_weapon_panels() -> void:
	# 装备/卸下芯片后全武器面板失效（芯片 crit 折算/atk 段在面板快照与 ⑥b 段）
	if player == null or not is_instance_valid(player):
		return
	var slots: Variant = player.get("weapon_slots")
	if slots is Array:
		for w in (slots as Array):
			if w is WeaponBase and is_instance_valid(w):
				(w as WeaponBase).invalidate_panel()
