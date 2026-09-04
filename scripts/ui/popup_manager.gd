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
var _rxn_cooldowns: Dictionary = {}           # target_uid -> float 冷却（防高频 AOE 刷屏，0.2s）

# 反应名牌文本与专属色板
const REACTION_NAMES: Dictionary = {
	GameConst.ReactionType.RXN_FIR_ICE: "碎裂！",
	GameConst.ReactionType.RXN_FIR_LTG: "过载！",
	GameConst.ReactionType.RXN_ICE_LTG: "超导 · 削抗！",
	GameConst.ReactionType.RXN_WAT_ICE: "冻结！",
	GameConst.ReactionType.RXN_WAT_LTG: "导电！",
	GameConst.ReactionType.RXN_WAT_FIR: "汽爆！",
}

const REACTION_COLORS: Dictionary = {
	GameConst.ReactionType.RXN_FIR_ICE: Color(1.0, 0.55, 0.3),       # 碎裂: 橙红
	GameConst.ReactionType.RXN_FIR_LTG: Color(1.0, 0.85, 0.25),      # 过载: 金黄
	GameConst.ReactionType.RXN_ICE_LTG: Color(0.85, 0.65, 1.0),      # 超导: 电浆紫
	GameConst.ReactionType.RXN_WAT_ICE: Color(0.5, 0.85, 1.0),       # 冻结: 晶蓝
	GameConst.ReactionType.RXN_WAT_LTG: Color(0.7, 0.6, 1.0),        # 导电: 雷电紫白
	GameConst.ReactionType.RXN_WAT_FIR: Color(0.95, 0.95, 1.0),      # 汽爆: 雾气白
}


func setup(p_pool: PopupPool) -> void:
	# 注入池 + 事件订阅（仅 Node 派生类，E-12 ✓）
	popup_pool = p_pool
	EventBus.damage_resolved.connect(on_damage_resolved)
	EventBus.reaction_triggered.connect(on_reaction_triggered)


func on_reaction_triggered(p_rxn: int, p_pos: Vector2, p_target_uid: int) -> void:
	# 剧变反应名牌浮字（碎裂/过载/超导/冻结/导电/汽爆专属彩色汉字提示）
	if not REACTION_NAMES.has(p_rxn):
		return
	if p_target_uid > 0:
		var cd: float = float(_rxn_cooldowns.get(p_target_uid, 0.0))
		if cd > 0.0:
			return
		_rxn_cooldowns[p_target_uid] = 0.2
	var text: String = REACTION_NAMES[p_rxn]
	var col: Color = REACTION_COLORS.get(p_rxn, Color(0.55, 0.85, 1.0))
	show_text_popup(p_pos + Vector2(0.0, -22.0), text, col)


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
	# v1.1.0：乘区明细含 amplify 池 → 数值跳字追加 ‼ 后缀（增幅可读性，E7）
	var suffix := "‼" if p_result.pool_breakdown.has(&"amplify") else ""
	popup.show_popup(p_result.pos, p_result.final_value, p_result.popup_style, uid, "", suffix)
	_active_list.append(popup)
	_merge_registry[uid] = {"popup": popup, "window_left": merge_window}
	active_popups = _active_list.size()

	# 增幅名牌浮字（融化/蒸发汉字名牌，与 ‼ 保持协同）
	if p_result.pool_breakdown.has(&"amplify") and uid > 0:
		var cd: float = float(_rxn_cooldowns.get(uid, 0.0))
		if cd <= 0.0:
			_rxn_cooldowns[uid] = 0.2
			var amp_text := "增幅！"
			var amp_col := Color(1.0, 0.8, 0.3)
			if p_result.element == GameConst.Element.ICE:
				amp_text = "蒸发！"
				amp_col = Color(0.4, 0.8, 1.0)
			elif p_result.element == GameConst.Element.FIR:
				amp_text = "融化！"
				amp_col = Color(1.0, 0.5, 0.2)
			show_text_popup(p_result.pos + Vector2(0.0, -22.0), amp_text, amp_col)


func show_text_popup(p_pos: Vector2, p_text: String, p_color: Color = Color.TRANSPARENT) -> void:
	# v0.7.0 文本跳字通道（金币狂欢 +N / Boss 芯片掉落提示 / 反应名牌）：target_uid=0 入 _active_list
	# 走既有 tick/归还；不入合并注册表（文本不参与数值合并）。popup_manager 未就绪 → 静默跳过。
	if popup_pool == null:
		return
	if _active_list.size() >= MAX_ACTIVE:
		_dropped_count += 1
		return
	var node := popup_pool.acquire()
	if node == null:
		_dropped_count += 1
		return
	var popup := node as DamagePopup
	popup.show_popup(p_pos, 0.0, GameConst.PopupStyle.NORMAL, 0, p_text, "", p_color)
	_active_list.append(popup)
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
	# 反应名牌冷却衰减
	for uid_key in _rxn_cooldowns.keys():
		var cd_val: float = float(_rxn_cooldowns[uid_key]) - p_raw_delta
		if cd_val <= 0.0:
			_rxn_cooldowns.erase(uid_key)
		else:
			_rxn_cooldowns[uid_key] = cd_val
	active_popups = _active_list.size()


func dropped_count() -> int:
	# 遥测：满池/超限丢弃累计
	return _dropped_count


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
	_rxn_cooldowns.clear()
	active_popups = 0


func _retire(p_popup: DamagePopup, p_idx: int) -> void:
	# 归还（池 release 前置钩子调 _reset_state）；注册表同步清除
	var uid := p_popup.target_uid
	var entry: Dictionary = _merge_registry.get(uid, {})
	if not entry.is_empty() and entry["popup"] == p_popup:
		_merge_registry.erase(uid)
	_active_list.remove_at(p_idx)
	popup_pool.release(p_popup)
