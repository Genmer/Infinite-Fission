# autoload/event_bus.gd —— 注册名 EventBus（不声明 class_name，§0.1-3）
# M-18 事件总线（架构 §2.1）：
# ① 原生类型化信号（最快派发路径）；② 每信号配类型化 emit_* 包装，统一过 _track_dispatch
# ③ 仅 Node 派生类可订阅（E-12：RefCounted 订阅持强引用 → 泄漏；开发期断言）
# ④ 场景重开断言订阅回落基线（泄漏回归）
# ⑤ 事件风暴防护：同事件同帧派发超阈值 → 告警一次 + 计数（§六.4）
#
# 包 0 类型占位说明（架构 §2.1 原签名 → 本包签名）：
#   signal enemy_killed(enemy: Enemy)  → (enemy: Node2D)   —— Enemy 属包 2（scripts/entities/enemy/enemy.gd），
#   signal boss_spawned(enemy: Enemy)  → (enemy: Node2D)      包 0 阶段未落地；Enemy extends Node2D（§2.11），
#   包 2 合入后恢复窄类型标注（信号参数注解不参与运行时校验，语义零差异）。
extends Node

signal state_changed(new_state: int)                       # GameStatus
signal config_fatal(errors: Array)                         # 启动致命错误清单（拒绝启动）
signal data_validated(report: Dictionary)                  # 校验报告：{total, rejected, errors[]}
signal damage_resolved(result: DamageResult)               # 每次结算（跳字/GameFeel/遥测共源）
signal damage_alarm(result: DamageResult)                  # ×500 告警线触发（一局一次/构筑）
signal enemy_killed(enemy: Node2D)                         # 死亡广播（含 tags/exp/位置）
signal boss_spawned(enemy: Node2D)                         # Boss 登场（HUD 血条/GameFeel）
signal player_hit(damage: float, source_uid: int)          # 简化路径受击（Q-16）
signal player_died()                                       # 死亡优先级最高（E-16 仲裁输入）
signal level_up(new_level: int)                            # 升级请求（GameLoop 仲裁）
signal xp_gained(amount: float)
signal gold_changed(total: int)                            # v0.6.0 金币余额变更（A4 §3）
signal wave_started(wave: int)
signal wave_cleared(wave: int)
signal slot_unlocked(slot: int)                            # 武器槽解锁（HUD 提示）
signal reaction_triggered(rxn: int, pos: Vector2, target_uid: int)
signal pool_exhausted(pool_id: StringName)                 # 池满降级计数（DebugStats）
signal chain_fused(depth: int, trait_id: StringName)       # 链式/分叉深度熔断遥测
signal card_chosen(card_id: StringName, target_kind: int)  # 选卡应用完成（遗物回响等）

var _dispatch_count: Dictionary = {}        # StringName(事件) -> int(本帧计数)
const STORM_WARN_THRESHOLD := 128           # 同事件同帧派发上限（§六.4）
const STORM_WARN_DAMAGE_RESOLVED := 600     # damage_resolved 专项告警线（§六.4：结算条目过多定位）

# 遥测观测口（DebugStats/测试读取；正常游戏代码不写）
var storm_warnings: int = 0                 # 风暴告警累计次数
var subscription_leak_errors: int = 0       # 订阅回落断言违例累计（E-12）
var non_node_subscriber_errors: int = 0     # 非 Node 订阅者拦截累计（E-12）
var _subscription_baseline: int = -1        # 首次调用 assert_subscription_baseline 时记录


func _ready() -> void:
	# 事件名注册表快照（供 DataValidator 校验 RelicData.listen_events；§2.1 事件清单表）
	var names: Array[StringName] = []
	for sig in get_signal_list():
		names.append(StringName(String(sig["name"])))
	known_events = names


# EventBus 事件名注册表（§三.4：listen_events ∈ 注册表；_ready 时由信号表冻结）
var known_events: Array[StringName] = []


# ── 类型化派发包装（全部事件统一经 _track_dispatch → signal.emit） ──
func emit_state_changed(new_state: int) -> void:
	_track_dispatch(&"state_changed")
	state_changed.emit(new_state)


func emit_config_fatal(errors: Array) -> void:
	_track_dispatch(&"config_fatal")
	config_fatal.emit(errors)


func emit_data_validated(report: Dictionary) -> void:
	_track_dispatch(&"data_validated")
	data_validated.emit(report)


func emit_damage_resolved(result: DamageResult) -> void:
	_track_dispatch(&"damage_resolved")
	damage_resolved.emit(result)


func emit_damage_alarm(result: DamageResult) -> void:
	_track_dispatch(&"damage_alarm")
	damage_alarm.emit(result)


func emit_enemy_killed(enemy: Node2D) -> void:
	_track_dispatch(&"enemy_killed")
	enemy_killed.emit(enemy)


func emit_boss_spawned(enemy: Node2D) -> void:
	_track_dispatch(&"boss_spawned")
	boss_spawned.emit(enemy)


func emit_player_hit(damage: float, source_uid: int) -> void:
	_track_dispatch(&"player_hit")
	player_hit.emit(damage, source_uid)


func emit_player_died() -> void:
	_track_dispatch(&"player_died")
	player_died.emit()


func emit_level_up(new_level: int) -> void:
	_track_dispatch(&"level_up")
	level_up.emit(new_level)


func emit_xp_gained(amount: float) -> void:
	_track_dispatch(&"xp_gained")
	xp_gained.emit(amount)


func emit_gold_changed(total: int) -> void:
	_track_dispatch(&"gold_changed")
	gold_changed.emit(total)


func emit_wave_started(wave: int) -> void:
	_track_dispatch(&"wave_started")
	wave_started.emit(wave)


func emit_wave_cleared(wave: int) -> void:
	_track_dispatch(&"wave_cleared")
	wave_cleared.emit(wave)


func emit_slot_unlocked(slot: int) -> void:
	_track_dispatch(&"slot_unlocked")
	slot_unlocked.emit(slot)


func emit_reaction_triggered(rxn: int, pos: Vector2, target_uid: int) -> void:
	_track_dispatch(&"reaction_triggered")
	reaction_triggered.emit(rxn, pos, target_uid)


func emit_pool_exhausted(pool_id: StringName) -> void:
	_track_dispatch(&"pool_exhausted")
	pool_exhausted.emit(pool_id)


func emit_chain_fused(depth: int, trait_id: StringName) -> void:
	_track_dispatch(&"chain_fused")
	chain_fused.emit(depth, trait_id)


func emit_card_chosen(card_id: StringName, target_kind: int) -> void:
	_track_dispatch(&"card_chosen")
	card_chosen.emit(card_id, target_kind)


# ── 计数 / 风暴防护 / 订阅纪律 ─────────────────────────────────────
func _track_dispatch(event: StringName) -> void:
	# 帧计数 + 超阈值告警一次（每帧每事件仅一次）
	var count := int(_dispatch_count.get(event, 0)) + 1
	_dispatch_count[event] = count
	if count == STORM_WARN_THRESHOLD:
		storm_warnings += 1
		push_warning("[EventBus] 事件风暴：%s 本帧已派发 %d 次（阈值 %d）" % [event, count, STORM_WARN_THRESHOLD])
	if event == &"damage_resolved" and count == STORM_WARN_DAMAGE_RESOLVED:
		storm_warnings += 1
		push_warning("[EventBus] 结算风暴：damage_resolved 本帧已派发 %d 次（定位：结算条目过多）" % count)


func end_frame() -> void:
	# GameLoop 帧末调用：清零计数 + 订阅纪律开发期断言（E-12）
	_check_node_subscribers()
	_dispatch_count.clear()


func get_dispatch_count(event: StringName) -> int:
	# DebugStats 查询
	return int(_dispatch_count.get(event, 0))


func assert_subscription_baseline() -> void:
	# 断言订阅数回落（泄漏回归，E-12）；首次调用记录基线（场景加载前调用）。
	var total := _total_connections()
	if _subscription_baseline < 0:
		_subscription_baseline = total
		return
	if total > _subscription_baseline:
		subscription_leak_errors += 1
		push_error("[EventBus] 订阅数未回落（泄漏嫌疑）：当前 %d > 基线 %d" % [total, _subscription_baseline])


func _total_connections() -> int:
	var total := 0
	for sig in get_signal_list():
		total += get_signal_connection_list(String(sig["name"])).size()
	return total


func _check_node_subscribers() -> void:
	# 仅 Node 派生类可订阅（E-12：RefCounted 连接持强引用 → 泄漏）；开发期拦截计数。
	for sig in get_signal_list():
		var sname := String(sig["name"])
		for conn in get_signal_connection_list(sname):
			var obj: Object = conn["callable"].get_object()
			if obj != null and not (obj is Node):
				non_node_subscriber_errors += 1
				push_error("[EventBus] 非 Node 订阅者被拦截（E-12）：%s ← %s" % [sname, str(conn["callable"])])
