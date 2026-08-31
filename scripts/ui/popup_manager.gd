# scripts/ui/popup_manager.gd
# M-16 PopupManager（架构 §2.15）：跳字管理（合并/上限/分级）。
# 主入口 on_damage_resolved（damage_resolved 订阅）→ 合并判断 → 池取出 → 样式分级。
# 护栏（E-09/E-17）：同目标 0.12s 合并窗 + 同屏 ≤80（超限合并到既有跳字 / 丢弃 + 计数）。
# tick(raw)：跳字动画推进 + 到期归还（运行期 0 实例化——池循环承担，AC-14.1）。
# 量级分级（P2）：入口按「单次伤害 / 单发基准伤害」判 4 档（白/蓝/紫/金）——
# 基准真源 = 主武器面板 base_atk × crit_mult（baseline_provider 由 GameLoop 注入；
# 缺失/为 0 → 全白降级）。紫档微音 / 金档重音 + 轻震动（trauma 复用既有 hit 档）。
class_name PopupManager
extends Node

var popup_pool: PopupPool = null              # 注入（Boot 期 GameLoop 组装）
var merge_window: float = 0.12                # 同目标短窗合并（E-17）
var active_popups: int = 0                    # 当前活跃跳字数（遥测/测试观测）
var baseline_provider: Callable = Callable()  # 单发基准伤害供给（GameLoop 注入；空 = 分级关闭）
var tier_shake_hook: Callable = Callable()    # 金档轻震动钩子（GameLoop 注入 add_trauma 档位）
const MAX_ACTIVE: int = 80                    # 同屏上限（超限合并/丢弃，E-09）

# 量级分档阈值（P2 数值真源：相对单发基准伤害的倍率——白 <1.5× / 蓝 ≥1.5× / 紫 ≥3× / 金 ≥6×）
const TIER_BLUE_X := 1.5
const TIER_PURPLE_X := 3.0
const TIER_GOLD_X := 6.0

# 活跃跳字注册表：target_uid -> {popup: DamagePopup, window_left: float}（合并窗判据）
var _merge_registry: Dictionary = {}
var _active_list: Array[DamagePopup] = []
var _dropped_count: int = 0                   # 满池且无可合并时的丢弃计数


func setup(p_pool: PopupPool) -> void:
	# 注入池 + 事件订阅（仅 Node 派生类，E-12 ✓）
	popup_pool = p_pool
	EventBus.damage_resolved.connect(on_damage_resolved)


func on_damage_resolved(p_result: DamageResult) -> void:
	# 主入口：合并判断 → 池取出 → 样式分级
	if popup_pool == null:
		return
	var uid := p_result.target_uid
	var entry: Dictionary = _merge_registry.get(uid, {})
	if not entry.is_empty():
		# 合并窗内：数值累加（E-17；窗口刷新由 merge 内部承担）
		var popup: DamagePopup = entry["popup"]
		if is_instance_valid(popup) and popup.is_active:
			popup.merge(p_result.final_value)
			return
		_merge_registry.erase(uid)
	# 新跳字：同屏上限（E-09）→ 满时丢弃 + 计数（合并降级目标不存在则直接丢）
	if _active_list.size() >= MAX_ACTIVE:
		_dropped_count += 1
		return
	var node := popup_pool.acquire()
	if node == null:
		_dropped_count += 1
		return
	var tier := _tier_for(p_result.popup_style, p_result.final_value)
	var popup := node as DamagePopup
	popup.show_popup(p_result.pos, p_result.final_value, p_result.popup_style, uid, tier)
	_active_list.append(popup)
	_merge_registry[uid] = {"popup": popup, "window_left": merge_window}
	active_popups = _active_list.size()
	# 量级档音效/震动联动（紫微音 / 金重音+轻震动；节流由 SfxBank 70ms 承担；
	# 合并窗内不重复触发——仅新起跳字时判档）
	if tier >= 3:
		if SfxBank.I != null:
			SfxBank.I.play(&"tier_epic")
		if tier_shake_hook.is_valid():
			tier_shake_hook.call()
	elif tier >= 2 and SfxBank.I != null:
		SfxBank.I.play(&"tier_high")


func tick(p_raw_delta: float) -> void:
	# 跳字动画（raw 通道，顿帧期间照常）+ 合并窗推进 + 到期归还
	var idx := _active_list.size() - 1
	while idx >= 0:
		var popup := _active_list[idx]
		if not is_instance_valid(popup) or not popup.is_active:
			_active_list.remove_at(idx)
			idx -= 1
			continue
		popup.tick(p_raw_delta)
		if popup.life_left() <= 0.0:
			_retire(popup, idx)
		idx -= 1
	# 合并窗倒计时（到期移除判据条目——跳字本体仍在展示期）
	for uid in _merge_registry.keys():
		var entry: Dictionary = _merge_registry[uid]
		entry["window_left"] = float(entry["window_left"]) - p_raw_delta
		if float(entry["window_left"]) <= 0.0:
			_merge_registry.erase(uid)
	active_popups = _active_list.size()


func dropped_count() -> int:
	# 遥测：满池/超限丢弃累计
	return _dropped_count


func _tier_for(p_style: int, p_value: float) -> int:
	# 量级档判定（P2）：仅直击样式 NORMAL/CRIT 参与；基准 = baseline_provider()（主武器
	# 面板 base_atk × crit_mult）。基准缺失/≤0 → 全白（分级安全关闭）；合并窗内不重判。
	if p_style != GameConst.PopupStyle.NORMAL and p_style != GameConst.PopupStyle.CRIT:
		return 0
	if baseline_provider.is_null():
		return 0
	var base: float = float(baseline_provider.call())
	if base <= 0.0:
		return 0
	var ratio := p_value / base
	if ratio >= TIER_GOLD_X:
		return 3
	if ratio >= TIER_PURPLE_X:
		return 2
	if ratio >= TIER_BLUE_X:
		return 1
	return 0


func clear_all() -> void:
	# 清场归还（GameLoop._reset_run_state 重开口径，审查 Fix 1）：全部活跃跳字归还池 +
	# 注册表清空（防重开后残留跳字/合并窗指向已归还实例）
	var idx := _active_list.size() - 1
	while idx >= 0:
		var popup := _active_list[idx]
		_active_list.remove_at(idx)
		if is_instance_valid(popup):
			popup_pool.release(popup)
		idx -= 1
	_merge_registry.clear()
	active_popups = 0


func _retire(p_popup: DamagePopup, p_idx: int) -> void:
	# 归还（池 release 前置钩子调 _reset_state）；注册表同步清除
	var uid := p_popup.target_uid
	var entry: Dictionary = _merge_registry.get(uid, {})
	if not entry.is_empty() and entry["popup"] == p_popup:
		_merge_registry.erase(uid)
	_active_list.remove_at(p_idx)
	popup_pool.release(p_popup)
