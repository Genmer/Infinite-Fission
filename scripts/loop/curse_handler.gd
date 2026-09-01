# scripts/loop/curse_handler.gd
# v0.8.0 CurseHandler（A7 §V6 诅咒运行时；对齐 relic_handler/chip_handler 模式：Node + 注入 +
# reset_run + 遥测观测口）。
# · 层数：0~5（MAX_CURSE_LAYERS）；每层三乘区——受伤 ×(1+0.08n) / 金币掉率 +0.15n /
#   max_hp ×(1−0.04n)（公式唯一真源 Player.compute_max_hp）。
# · recompute_max_hp 是运行期 max_hp 唯一写入口（芯片 max_hp 装备/商店 maxhp/诅咒增减/
#   reset_run 全部经此）——prescale = base×(1+char_pct) + chip.stat_bonus(max_hp)（含套装）
#   + player.max_hp_bonus_flat + meta_hp_flat（v1.0.0 局外段，A9）；new_max = maxf(prescale×(1−0.04n), 1.0)。
# · 写回后 EventBus.emit_curse_changed(curse_count, player.max_hp) 广播（HUD 诅咒标签共源）。
# ★ 本类内部对 player 不判 null（setup 注入先于一切流；调用方 curse_handler==null 时自行兜底）。
class_name CurseHandler
extends Node

const MAX_CURSE_LAYERS: int = 5
const DMG_TAKEN_PER_LAYER: float = 0.08        # 每层受伤乘区增量（×(1+0.08n)）
const GOLD_DROP_PER_LAYER: float = 0.15        # 每层金币掉率增量（+0.15n）
const MAXHP_PER_LAYER: float = 0.04            # 每层 max_hp 衰减（×(1−0.04n)）

var curse_count: int = 0                       # 当前诅咒层数（0~5）
# ── 遥测（测试观测口） ──
var curses_taken: int = 0                      # 累计获得层数（含事件/卡流/契约）
var curses_purged: int = 0                     # 累计净化层数

var player: Player = null                      # 注入（max_hp/hp 宿主 + char_pct 问询）
var chip_handler: ChipHandler = null           # 注入（stat_bonus(max_hp) 问询——含套装聚合）
var meta_hp_flat: float = 0.0                  # v1.0.0 局外生命 flat（A9）：GameLoop run 开始注入；
                                               # recompute 每次算入；不存 player 字段 respawn 不清


func setup(p_deps: Dictionary) -> void:
	# Boot 注入（GameLoop._boot_build_actors：player/chip_handler——先于诅咒流就绪）
	player = p_deps.get("player")
	chip_handler = p_deps.get("chip_handler")
	reset_run()


func reset_run() -> void:
	# 重开清零（GameLoop._reset_run_state 调用）：层数/遥测清零 + max_hp 重导出基线
	#（respawn 侧 compute_max_hp(char_pct,0,0,0) 已复位；此处 recompute 保持口径统一）
	curse_count = 0
	curses_taken = 0
	curses_purged = 0
	recompute_max_hp()


func add_curse(p_layers: int = 1) -> int:
	# 加层（钳上限，返回实际增量；0 = 已满层拒绝）
	if p_layers <= 0:
		return 0
	var actual: int = mini(p_layers, MAX_CURSE_LAYERS - curse_count)
	if actual <= 0:
		return 0
	curse_count += actual
	curses_taken += actual
	recompute_max_hp()
	return actual


func remove_curse(p_layers: int = 1) -> int:
	# 减层（钳 0 下限，返回实际移除量）
	if p_layers <= 0:
		return 0
	var actual: int = mini(p_layers, curse_count)
	if actual <= 0:
		return 0
	curse_count -= actual
	curses_purged += actual
	recompute_max_hp()
	return actual


func is_maxed() -> bool:
	return curse_count >= MAX_CURSE_LAYERS


func dmg_taken_mult() -> float:
	# 受伤乘区（Player.take_contact_damage 消费；n=0 → 1.0 恒等）
	return 1.0 + DMG_TAKEN_PER_LAYER * float(curse_count)


func gold_drop_bonus() -> float:
	# 金币掉率加成（GameLoop._on_enemy_killed_drop_gold 消费；n=0 → 0.0 恒等）
	return GOLD_DROP_PER_LAYER * float(curse_count)


func recompute_max_hp(p_heal_delta: float = 0.0) -> void:
	# ★ 运行期 max_hp 唯一写入口（A7 §V6 冻结公式；v1.0.0 prescale 增 + meta_hp_flat）：
	# prescale = base×(1+char_pct) + chip.stat_bonus(max_hp) + player.max_hp_bonus_flat
	#            + meta_hp_flat
	# new_max  = maxf(prescale×(1−0.04n), 1.0)
	# heal_delta>0 → hp = minf(hp+Δ, new_max)（芯片回补口径）；否则 hp = hp×new_max/old_max
	#（比例缩放，钳 [0,new_max]）。写回后 curse_changed 广播。
	var base: float = GameConfig.get_constant(&"player_base_hp", 100.0)
	var char_pct: float = player.char_max_hp_pct()
	var chip_sum: float = chip_handler.stat_bonus(&"max_hp") if chip_handler != null else 0.0
	var prescale: float = base * (1.0 + char_pct) + chip_sum + player.max_hp_bonus_flat \
		+ meta_hp_flat
	var old_max: float = player.max_hp
	var new_max: float = maxf(prescale * (1.0 - MAXHP_PER_LAYER * float(curse_count)), 1.0)
	player.max_hp = new_max
	if p_heal_delta > 0.0:
		player.hp = minf(player.hp + p_heal_delta, new_max)
	else:
		player.hp = clampf(player.hp * new_max / old_max if old_max > 0.0 else new_max, 0.0, new_max)
	EventBus.emit_curse_changed(curse_count, player.max_hp)
