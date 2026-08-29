# autoload/game_config.gd —— 注册名 GameConfig（不声明 class_name，§0.1-3）
# M-19 配置/数值表加载与降级（架构 §2.2）：
# 加载顺序（最优先，其它模块 Boot 前置）：读 version → cfg → .tres → 校验 → 降级/致命 → emit config_ready
# 致命集（§六.2）：res_logic 错 / pool_prewarm 任一 ≤0 / cap_prod ≤0 → config_fatal（GameLoop 拒绝启动）
# 非致命：字段级回退默认值 + 告警
extends Node

const PATH_BALANCE := "res://data/balance/balance_tables.tres"
const PATH_CONSTANTS := "res://data/balance/global_constants.cfg"
const PATH_VERSION := "res://data/version.cfg"

# 期望键表（A3 §0.1 GlobalConstants.cfg；缺失键 → 默认值 + 告警）。
# player_pickup_radius 取 B_spec Q-13 裁定 120px（A3 §0.1 原值 90 已被 B_spec 覆盖）。
# player_base_hp 回退默认同 cfg 真源 60（主控裁定 2026-08-29 张力口径回注）。
const _EXPECTED_CONSTANTS: Dictionary = {
	&"res_logic_width": 720.0,
	&"res_logic_height": 1280.0,
	&"player_base_hp": 60.0,
	&"player_base_speed": 280.0,
	&"player_pickup_radius": 120.0,
	&"contact_tick": 0.6,
	&"hp_growth_per_wave": 1.12,
	&"dmg_growth_per_wave": 1.06,
	&"spd_growth_per_wave": 0.008,
	&"exp_inflation_per_wave": 1.085,
	&"cap_synergy_product": 8.0,
	&"cap_cdr_sum": 0.6,
	&"cap_rof_per_weapon": 30.0,
	&"crit_cap_rate": 1.0,
}

var balance: BalanceTables = null                  # 校验后的全局常数（§三.8）
var frame_stamp: int = 0                           # 全局帧号（幂等键/审计公共帧标识）
var fatal_errors: Array = []                       # 致命级错误（池容量 0 等）

var _constants: Dictionary = {}                    # cfg 键值内存表
var _declared_data_version: int = -1               # version.cfg 声明值（-1 = 未读到）

signal config_ready()


func _ready() -> void:
	# 加载顺序：version → constants(cfg) → balance(.tres) → 校验 → 分级（致命/降级）→ config_ready
	_load_version()
	_load_constants()
	_load_balance()
	if not fatal_errors.is_empty():
		# 致命 → EventBus.config_fatal（GameLoop 停在 BOOT，展示 boot_error 清单；§六.2）
		EventBus.emit_config_fatal(fatal_errors)
	config_ready.emit()


func _load_version() -> void:
	# version.cfg 数据版本字段（AC-13.5，不匹配仅告警，不迁移）
	var cfg := ConfigFile.new()
	if cfg.load(PATH_VERSION) != OK:
		push_warning("[GameConfig] version.cfg 缺失（跳过数据版本比对）")
		return
	_declared_data_version = int(cfg.get_value("data", "data_version", -1))


func _load_constants() -> void:
	# ConfigFile → 内存表（缺失键 → 默认值 + 告警；非致命）
	var cfg := ConfigFile.new()
	if cfg.load(PATH_CONSTANTS) != OK:
		push_warning("[GameConfig] global_constants.cfg 缺失：全部键回退默认值（非致命）")
	# 期望键：缺失告警 + 默认
	for key in _EXPECTED_CONSTANTS:
		var fallback := float(_EXPECTED_CONSTANTS[key])
		if cfg.has_section_key("constants", String(key)):
			_constants[key] = float(cfg.get_value("constants", String(key), fallback))
		else:
			push_warning("[GameConfig] global_constants.cfg 缺键：%s → 默认 %s" % [key, str(fallback)])
			_constants[key] = fallback
	# 附加键（超出期望集的键也纳入内存表，便于 get_constant 查询）
	if cfg.has_section("constants"):
		for extra in cfg.get_section_keys("constants"):
			var ekey := StringName(String(extra))
			if not _constants.has(ekey):
				_constants[ekey] = float(cfg.get_value("constants", String(extra), 0.0))


func _load_balance() -> void:
	# ResourceLoader.load → DataValidator 校验（致命/降级分级处理）
	if not ResourceLoader.exists(PATH_BALANCE):
		balance = BalanceTables.new()
		fatal_errors.append("[GameConfig] 致命：%s 缺失（回退全默认值，拒绝启动）" % PATH_BALANCE)
		return
	var loaded: Resource = ResourceLoader.load(PATH_BALANCE, "", ResourceLoader.CACHE_MODE_REUSE)
	if loaded == null or not (loaded is BalanceTables):
		balance = BalanceTables.new()
		fatal_errors.append("[GameConfig] 致命：%s 加载失败或类型不符（拒绝启动）" % PATH_BALANCE)
		return
	balance = loaded
	# 数据版本比对（AC-13.5：不匹配仅告警）
	if _declared_data_version >= 0 and _declared_data_version != balance.data_version:
		push_warning("[GameConfig] 数据版本不匹配：version.cfg=%d vs balance_tables.tres=%d（不迁移）"
			% [_declared_data_version, balance.data_version])
	# 校验 + 分级处置：致命 → 记 fatal_errors（拒绝启动）；非致命 → 字段级回退默认值 + 告警
	var validator := DataValidator.new()
	var defaults := BalanceTables.new()
	for v in validator.validate_balance(balance):
		var field := String(v.get("field", ""))
		var msg := String(v.get("message", ""))
		if bool(v.get("fatal", false)):
			fatal_errors.append("[GameConfig] 致命：%s：%s（已回退默认值，拒绝启动）" % [field, msg])
		else:
			push_warning("[GameConfig] 降级：%s：%s（回退默认值）" % [field, msg])
		# 字段级回退默认值（保证后续 Boot 流程可用；致命时 GameLoop 仍拒绝进入 MENU）
		if field != "" and defaults.get(field) != null:
			balance.set(field, defaults.get(field))


func get_constant(key: StringName, default: float) -> float:
	# cfg 键值查询（带默认）
	return float(_constants.get(key, default))


func get_pool_capacity(pool_id: StringName) -> int:
	# 池容量（致命校验项：≤0 拒绝启动——已在 _load_balance 分级处置；此处仅查询）
	return int(balance.pool_prewarm.get(pool_id, 0))


func advance_frame() -> void:
	# GameLoop 每物理帧调用：frame_stamp += 1（2^24 位宽回绕，§4.1）
	frame_stamp += 1
	if frame_stamp > 0xFFFFFF:
		frame_stamp = 0


func is_fatal() -> bool:
	# true → GameLoop 拒绝进入 MENU，展示错误清单
	return not fatal_errors.is_empty()
