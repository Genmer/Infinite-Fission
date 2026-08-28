# scripts/ui/popup_manager.gd
# M-16 PopupManager（架构 §2.15）：跳字管理（合并/上限/分级）。
# 主入口 on_damage_resolved（damage_resolved 订阅）→ 合并判断 → 池取出 → 样式分级。
# 护栏（E-09/E-17）：同目标 0.12s 合并窗 + 同屏 ≤80（超限合并到既有跳字 / 丢弃 + 计数）。
# tick(raw)：跳字动画推进 + 到期归还（运行期 0 实例化——池循环承担，AC-14.1）。
class_name PopupManager
extends Node

var popup_pool: PopupPool = null              # 注入（Boot 期 GameLoop 组装）
var merge_window: float = 0.12                # 同目标短窗合并（E-17）
var active_popups: int = 0                    # 当前活跃跳字数（遥测/测试观测）
const MAX_ACTIVE: int = 80                    # 同屏上限（超限合并/丢弃，E-09）

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
	var popup := node as DamagePopup
	popup.show_popup(p_result.pos, p_result.final_value, p_result.popup_style, uid)
	_active_list.append(popup)
	_merge_registry[uid] = {"popup": popup, "window_left": merge_window}
	active_popups = _active_list.size()


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


func _retire(p_popup: DamagePopup, p_idx: int) -> void:
	# 归还（池 release 前置钩子调 _reset_state）；注册表同步清除
	var uid := p_popup.target_uid
	var entry: Dictionary = _merge_registry.get(uid, {})
	if not entry.is_empty() and entry["popup"] == p_popup:
		_merge_registry.erase(uid)
	_active_list.remove_at(p_idx)
	popup_pool.release(p_popup)
