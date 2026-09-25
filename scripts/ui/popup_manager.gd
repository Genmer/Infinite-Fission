# scripts/ui/popup_manager.gd
# M-16 PopupManager（架构 §2.15）：跳字管理（合并/上限/分级）。
# 主入口 on_damage_resolved（damage_resolved 订阅）→ 合并判断 → 池取出 → 样式分级。
# 护栏（E-09/E-17）：同目标 0.12s 合并窗 + 同屏 ≤80（超限合并到既有跳字 / 丢弃 + 计数）。
# tick(raw)：跳字动画推进 + 到期归还（运行期 0 实例化——池循环承担，AC-14.1）。
# 量级分级（P2）：入口按「单次伤害 / 单发基准伤害」判 4 档（白/蓝/紫/金）——
# 基准真源 = 主武器面板 base_atk × crit_mult（baseline_provider 由 GameLoop 注入；
# 缺失/为 0 → 全白降级）。紫档微音 / 金档重音 + 轻震动（trauma 复用既有 hit 档）。
# R186 反应字体：合并注册表分桶键 _mkey(uid, bucket)（直击 0 / 反应 1 / 其余 2 /
# 文字 3）——REACTION 数值与文字永不同桶（§4.d：bucket3 无 merge 入口，文字桶结构性
# 不可被数值并入）——
# ① 同桶窗内照旧合并；② REACTION 结果遇同 uid 直击小字在窗 → upgrade_to_reaction
# 原地升格重弹（active 不涨）；③ 直击遇同 uid 反应大字在窗 → 不吞大字、新起小字下移
# +20px；④ 超导（RXN_ICE_LTG）无 DamageResult 通道 → 订阅 reaction_triggered 起
# 「超导」纯文字标签（注册 bucket3 文字桶，pos+(0,-30) 与同目标数值大字错位防叠；
# 碎裂/过载在此禁处理——管线 settle 已同帧派生跳字，再起会翻倍）；
# ⑤ 密度护栏：同帧反应起字上限 [1,2,3]（按 fx_quality；计数按 rxn 分组且对
# bucket1/bucket3 共同生效）+ 满池回收最老非反应槽 + 反应结算值 ≤0.5 短路（防 54px 大「0」）。
class_name PopupManager
extends Node

var popup_pool: PopupPool = null              # 注入（Boot 期 GameLoop 组装）
var merge_window: float = 0.12                # 同目标短窗合并（E-17；档位化后为「高」档基准）
var active_popups: int = 0                    # 当前活跃跳字数（遥测/测试观测）
var baseline_provider: Callable = Callable()  # 单发基准伤害供给（GameLoop 注入；空 = 分级关闭）
var tier_shake_hook: Callable = Callable()    # 金档轻震动钩子（GameLoop 注入 add_trauma 档位）
const MAX_ACTIVE: int = 80                    # 「高」档同屏上限（中/低档按 fx_quality 缩减）

# R19 特效质量档位（Meta.settings fx_quality：2 高 / 1 中 / 0 低）：
# 同屏跳字上限 80/40/20 + 合并窗 0.12/0.2/0.3s——buff 叠多层 DPS 爆炸时跳字是
# 第一帧耗大头（Label 池逐帧动画），降档 = 上限减半 + 窗口加宽（更积极合并）
static func max_active_for(p_quality: int) -> int:
	return [20, 40, MAX_ACTIVE][clampi(p_quality, 0, 2)]


static func merge_window_for(p_quality: int) -> float:
	return [0.3, 0.2, 0.12][clampi(p_quality, 0, 2)]


func _quality() -> int:
	return clampi(int(Meta.settings("fx_quality")), 0, 2)

# 量级分档阈值（P2 数值真源：相对单发基准伤害的倍率——白 <1.5× / 蓝 ≥1.5× / 紫 ≥3× / 金 ≥6×）
const TIER_BLUE_X := 1.5
const TIER_PURPLE_X := 3.0
const TIER_GOLD_X := 6.0

# R186 反应起字同帧上限（低/中/高画质，对齐 max_active_for 数组风格）：
# 密集弹幕下 54px 双色大字是第一可读性/耗帧大头——同帧超限就近并入本帧已起同反应大字
const REACTION_FRAME_CAP: Array[int] = [1, 2, 3]

# R3（R186）：超导文字标签与同目标数值大字错位防叠——起字位 = pos + 此偏移
const TEXT_LABEL_OFFSET: Vector2 = Vector2(0.0, -30.0)

# 活跃跳字注册表：_mkey(target_uid, bucket) -> {popup: DamagePopup, window_left: float}
# （R186 分桶键：直击 0 / 反应 1 / 其余 2 / 文字 3——同 uid 多样式并存互不吞）
var _merge_registry: Dictionary = {}
var _active_list: Array[DamagePopup] = []
var _dropped_count: int = 0                   # 满池且无可合并时的丢弃计数
var _rxn_frame_stamp: int = -1                # R186 反应帧计数器（惰性重置判据）
var _rxn_frame_counts: Dictionary = {}        # R186 本帧已起反应数（§5 契约：rxn→计数，按 rxn 分组）
var _rxn_frame_pops: Array[DamagePopup] = []  # R186 本帧已起反应大字（超限并入宿主池，bucket1/3 共用）
var _w8_frame_agg: Dictionary = {}             # R187 本帧按目标聚合结算值（target_uid → 值；w8_detonated 消费）
var _w8_agg_frame: int = -1                    # R187 聚合帧号（GameConfig.frame_stamp 惰性重置）


func setup(p_pool: PopupPool) -> void:
	# 注入池 + 事件订阅（仅 Node 派生类，E-12 ✓）
	popup_pool = p_pool
	EventBus.damage_resolved.connect(on_damage_resolved)
	EventBus.reaction_triggered.connect(on_reaction_triggered)   # R186 超导标签
	EventBus.w8_detonated.connect(on_w8_detonated)               # R187 W8 蓄能满档引爆大字


func on_w8_detonated(p_pos: Vector2, p_target_uid: int) -> void:
	# R187 W8 引爆大字通道（EventBus.w8_detonated → CHARGE_BURST 样式直起跳字）：
	# 值 = 该敌本帧结算聚合（引爆 AoE + 蓄能接触跳同帧合计）；走独立桶 4（不与同 uid
	# 直击白字合并——「引爆大数字被吞」修复）；伤害数字开关同口径生效；
	# w8_detonations 计数归 W8 武器侧单一写点（防双计）。
	if popup_pool == null or not bool(Meta.settings("damage_numbers_on")):
		return
	if GameConfig.frame_stamp != _w8_agg_frame:
		_w8_agg_frame = GameConfig.frame_stamp
		_w8_frame_agg.clear()
	var value := float(_w8_frame_agg.get(p_target_uid, 0.0))
	_w8_frame_agg.erase(p_target_uid)            # 消费一次（防同帧重复起字复用旧值）
	if value <= 0.0:
		return
	if _active_list.size() >= max_active_for(_quality()):
		if not _retire_oldest_non_reaction():
			_dropped_count += 1
			return
	var node := popup_pool.acquire()
	if node == null:
		_dropped_count += 1
		return
	var tier := _tier_for(GameConst.PopupStyle.CHARGE_BURST, value)
	var popup := node as DamagePopup
	popup.show_popup(p_pos, value, GameConst.PopupStyle.CHARGE_BURST, p_target_uid, tier,
		GameConst.Element.KIN)
	_active_list.append(popup)
	var key := _mkey(p_target_uid, 4)
	_merge_registry[key] = {"popup": popup, "window_left": merge_window_for(_quality())}
	active_popups = _active_list.size()
	if tier >= 3 and SfxBank.I != null:
		SfxBank.I.play(&"tier_epic")
		if tier_shake_hook.is_valid():
			tier_shake_hook.call()
	elif tier >= 2 and SfxBank.I != null:
		SfxBank.I.play(&"tier_high")


func on_damage_resolved(p_result: DamageResult) -> void:
	# 主入口：分桶合并判断 → 升格/护栏 → 池取出 → 样式分级。
	# 设置页伤害数字开关（P3）：入口短路——跳字/档音/档震全关（伤害结算管线不受影响）
	if popup_pool == null:
		return
	if not bool(Meta.settings("damage_numbers_on")):
		return
	# R187 W8 引爆大字数据源：逐帧按目标聚合结算值（w8_detonated 消费后清除——
	# CHARGE_BURST 大字 = 该敌本帧全部结算之和，含引爆 AoE 溅射）
	if GameConfig.frame_stamp != _w8_agg_frame:
		_w8_agg_frame = GameConfig.frame_stamp
		_w8_frame_agg.clear()
	_w8_frame_agg[p_result.target_uid] = float(_w8_frame_agg.get(p_result.target_uid, 0.0)) \
		+ maxf(float(p_result.final_value), 0.0)
	var uid := p_result.target_uid
	var style := p_result.popup_style
	# R4c（R186）：反应结算值 ≤0.5 短路不起新字——碎裂基数为剩余 DOT 可为 0
	# （≤0.5 口径：DOT ceil 下 0.5 会显示为 1，round 下 0.4 已显「0」，均防 54px 大「0」）
	if style == GameConst.PopupStyle.REACTION and p_result.final_value <= 0.5:
		return
	var bucket := _style_bucket(style)
	var key := _mkey(uid, bucket)
	var entry: Dictionary = _merge_registry.get(key, {})
	if not entry.is_empty():
		# 同桶合并窗内：数值累加（E-17；窗口刷新由 merge 内部承担）
		var popup: DamagePopup = entry["popup"]
		if is_instance_valid(popup) and popup.is_active:
			popup.merge(p_result.final_value)
			return
		_merge_registry.erase(key)
	if bucket == 1:
		# R2b（R186）升格：同 uid 直击小字在窗 → 数值并入原地换反应样式重弹
		# （注册表 bucket0 删除 → bucket1 指向同 popup；_active_list/active_popups 不涨）
		if _upgrade_direct_to_reaction(uid, key, p_result):
			return
		# R4a（R186）同帧反应起字上限：超限就近并入本帧已起同反应大字（位置不动）
		if not _reaction_frame_allow(p_result.element, p_result.pos, p_result.final_value):
			return
	# R2c（R186）：直击结果遇同 uid 反应大字在窗 → 不并入大字，新起小字下移 +20px 防叠
	var offset := Vector2.ZERO
	if bucket == 0 and _reaction_host_alive(uid):
		offset = Vector2(0.0, 20.0)
	# 新跳字：同屏上限（E-09 + R19 档位化）→ 满时丢弃 + 计数；REACTION 满池可先回收
	# 最老非反应槽兜底（R4b——大字优先级更高；全是反应槽则丢弃）
	if _active_list.size() >= max_active_for(_quality()):
		if bucket != 1 or not _retire_oldest_non_reaction():
			_dropped_count += 1
			return
	var node := popup_pool.acquire()
	if node == null:
		_dropped_count += 1
		return
	var tier := _tier_for(style, p_result.final_value)
	var popup := node as DamagePopup
	popup.show_popup(p_result.pos + offset, p_result.final_value, style, uid, tier,
		p_result.element)
	_active_list.append(popup)
	_merge_registry[key] = {"popup": popup, "window_left": merge_window_for(_quality())}
	active_popups = _active_list.size()
	if bucket == 1:
		_rxn_frame_pops.append(popup)
		_rxn_frame_counts[p_result.element] = int(_rxn_frame_counts.get(p_result.element, 0)) + 1
	# 量级档音效/震动联动（紫微音 / 金重音+轻震动；节流由 SfxBank 70ms 承担；
	# 合并窗内不重复触发——仅新起跳字时判档）
	if tier >= 3:
		if SfxBank.I != null:
			SfxBank.I.play(&"tier_epic")
		if tier_shake_hook.is_valid():
			tier_shake_hook.call()
	elif tier >= 2 and SfxBank.I != null:
		SfxBank.I.play(&"tier_high")


func on_reaction_triggered(p_rxn: int, p_pos: Vector2, p_uid: int) -> void:
	# R186 超导文字标签（R3）：RXN_ICE_LTG 走纯减益无 DamageResult（elemental_system
	# 只削抗+广播）→ 此处经池起一张 value=0、style=REACTION、element=RXN_ICE_LTG 的
	# 跳字，DamagePopup.REACTION 分支 value≤0 显示表内文字「超导」。
	# 碎裂/过载禁在此处理：管线每次 settle 已广播 reaction_triggered（damage_pipeline
	# :117；燎原传火也广播 RXN_FIR_ICE）——二次起字会翻倍刷屏。
	if popup_pool == null:
		return
	if not bool(Meta.settings("damage_numbers_on")):
		return
	if p_rxn != GameConst.ReactionType.RXN_ICE_LTG:
		return
	# R4a（§4.7）：超导标签同吃帧上限（按 rxn 分组计数）——多次超导同帧齐爆防刷屏
	if not _reaction_frame_allow(p_rxn, p_pos, 0.0):
		return
	# R2d/R3-D：文字 REACTION 注册 bucket3（数值与文字永不同桶）——同 uid 碎裂/过载
	# 数值大字在 bucket1 窗内互不吞，本标签与数值大字并存
	var key := _mkey(p_uid, 3)
	var entry: Dictionary = _merge_registry.get(key, {})
	if not entry.is_empty():
		# 同 uid 超导标签已在窗（bucket3）：不重复起标签
		var popup: DamagePopup = entry["popup"]
		if is_instance_valid(popup) and popup.is_active:
			return
		_merge_registry.erase(key)
	# R4b：满池先回收最老非反应槽；全是反应槽则丢弃 + 计数
	if _active_list.size() >= max_active_for(_quality()) and not _retire_oldest_non_reaction():
		_dropped_count += 1
		return
	var node := popup_pool.acquire()
	if node == null:
		_dropped_count += 1
		return
	var popup := node as DamagePopup
	# R3：pos+(0,-30) 与同目标数值大字错位防叠
	popup.show_popup(p_pos + TEXT_LABEL_OFFSET, 0.0, GameConst.PopupStyle.REACTION, p_uid, 0, p_rxn)
	popup.text_mode = true                        # §5 契约：文字桶标记（_popup_bucket 清退判据）
	_active_list.append(popup)
	_merge_registry[key] = {"popup": popup, "window_left": merge_window_for(_quality())}
	active_popups = _active_list.size()
	_rxn_frame_pops.append(popup)
	_rxn_frame_counts[p_rxn] = int(_rxn_frame_counts.get(p_rxn, 0)) + 1


static func _style_bucket(p_style: int) -> int:
	# R186 注册表分桶：NORMAL/CRIT→0 / REACTION→1 / 其余（DOT/HEAL/XP/IMMUNE）→2
	# R187：CHARGE_BURST→4 独立桶——W8 引爆大数字不再与同 uid 直击白字同桶合并
	#（「引爆大数字被吞进白字」修复本体；_mkey uid×8+bucket 容纳 0~7）
	if p_style == GameConst.PopupStyle.NORMAL or p_style == GameConst.PopupStyle.CRIT:
		return 0
	if p_style == GameConst.PopupStyle.REACTION:
		return 1
	if p_style == GameConst.PopupStyle.CHARGE_BURST:
		return 4
	return 2


static func _popup_bucket(p_popup: DamagePopup) -> int:
	# §5 契约：注册表桶位真源——REACTION 文字（text_mode）→3，其余按样式分桶
	# （_retire 清键与此同源，bucket3 文字条目不漏清、不误清 bucket1）
	if p_popup.text_mode:
		return 3
	return _style_bucket(p_popup.style)


static func _mkey(p_uid: int, p_bucket: int) -> int:
	# R186 分桶注册表键（uid < 2^20 × 8 → 无整型溢出；同 uid 三桶互不碰撞）
	return p_uid * 8 + p_bucket


func _upgrade_direct_to_reaction(p_uid: int, p_rxn_key: int, p_result: DamageResult) -> bool:
	# R186 R2b：REACTION 结果并入同 uid 直击小字（bucket0 在窗）——upgrade_to_reaction
	# 数值累加 + 原地换反应样式重弹；注册表 bucket0 删除 → bucket1 指向同 popup。
	# 到此路径时 bucket1 键必为空（同桶合并已先行消费），覆写无碰撞。
	var direct_key := _mkey(p_uid, 0)
	var entry: Dictionary = _merge_registry.get(direct_key, {})
	if entry.is_empty():
		return false
	var host: DamagePopup = entry["popup"]
	if not is_instance_valid(host) or not host.is_active:
		_merge_registry.erase(direct_key)
		return false
	host.upgrade_to_reaction(p_result.final_value, p_result.element)
	_merge_registry.erase(direct_key)
	_merge_registry[p_rxn_key] = {"popup": host, "window_left": merge_window_for(_quality())}
	return true


func _reaction_frame_allow(p_rxn: int, p_pos: Vector2, p_value: float) -> bool:
	# R186 R4a：同帧反应起字上限（低/中/高 = 1/2/3）——GameConfig.frame_stamp 惰性重置
	# 计数（knocktext 节流先例）；计数按 rxn 分组（§5 契约 _rxn_frame_counts，跨反应
	# 互不挤占；同 rxn 的数值大字 bucket1 与文字标签 bucket3 共用同一份预算）；
	# 超限并入本帧已起同反应大字（数值累加位置不动），无宿主则丢弃 + 计数。
	var frame := GameConfig.frame_stamp
	if frame != _rxn_frame_stamp:
		_rxn_frame_stamp = frame
		_rxn_frame_counts.clear()
		_rxn_frame_pops.clear()
	if int(_rxn_frame_counts.get(p_rxn, 0)) < REACTION_FRAME_CAP[clampi(_quality(), 0, 2)]:
		return true
	var host := _nearest_frame_reaction(p_rxn, p_pos)
	if host != null and not (p_value > 0.0 and host.text_mode):
		# §4.d：bucket3 文字桶无 merge 入口——带值并入禁入文字标签（文字标签只吃
		# 0.0 重置计时保文案；数值宿主照旧累加）
		host.merge(p_value)
		return false
	_dropped_count += 1
	return false


func _nearest_frame_reaction(p_rxn: int, p_pos: Vector2) -> DamagePopup:
	# R186：本帧已起的同反应大字里就近取超限并入宿主（无则 null）
	var best: DamagePopup = null
	var best_d := INF
	for popup: DamagePopup in _rxn_frame_pops:
		if not is_instance_valid(popup) or not popup.is_active:
			continue
		if popup.style != GameConst.PopupStyle.REACTION or popup.element != p_rxn:
			continue
		var d := popup.position.distance_squared_to(p_pos)
		if d < best_d:
			best_d = d
			best = popup
	return best


func _reaction_host_alive(p_uid: int) -> bool:
	# R186 R2c 判据：同 uid 反应大字（bucket1）是否在窗且活跃（失效条目顺手清除）
	var key := _mkey(p_uid, 1)
	var entry: Dictionary = _merge_registry.get(key, {})
	if entry.is_empty():
		return false
	var popup: DamagePopup = entry["popup"]
	if is_instance_valid(popup) and popup.is_active:
		return true
	_merge_registry.erase(key)
	return false


func _retire_oldest_non_reaction() -> bool:
	# R186 R4b：从最老（_active_list[0]）起回收第一张非 REACTION 槽（强制归还池）；
	# 全是反应槽 → false（调用方丢弃 + 计数）
	for i in range(_active_list.size()):
		var popup: DamagePopup = _active_list[i]
		if popup.style != GameConst.PopupStyle.REACTION:
			_retire(popup, i)
			return true
	return false


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
	# R187：CHARGE_BURST 参与量级档（引爆大额结算吃金档音效/震动——表现与功能同版本交付）
	if p_style != GameConst.PopupStyle.NORMAL and p_style != GameConst.PopupStyle.CRIT \
			and p_style != GameConst.PopupStyle.CHARGE_BURST:
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
	# 归还（池 release 前置钩子调 _reset_state）；注册表按分桶键同步清除（R186：
	# 单 uid 键清不干净——升格后 popup.style 已是 REACTION 条目迁 bucket1，超导
	# 文字条目在 bucket3——桶位统一由 _popup_bucket 判定）
	var key := _mkey(p_popup.target_uid, _popup_bucket(p_popup))
	var entry: Dictionary = _merge_registry.get(key, {})
	if not entry.is_empty() and entry["popup"] == p_popup:
		_merge_registry.erase(key)
	_active_list.remove_at(p_idx)
	popup_pool.release(p_popup)
