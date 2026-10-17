# scripts/core/pools/projectile_pool.gd
# M-13 特化池：ProjectilePool（玩家弹 + 敌弹共用，team 区分；架构 §2.3/§5.1）
# 闸门序：软上限 1500（新弹请求丢弃 + 计数）→ 容量内懒增长 → 硬上限 2000
# （force_recycle_oldest 强制回收最老，FORCED 路径）。
# 类型收紧（集成包 B.8 第二批，pkg0 池用例已迁移真实弹体场景）：
# acquire() -> ProjectileBase（架构原文口径；GDScript 覆写允许返回值协变）。
class_name ProjectilePool
extends ObjectPool

const SOFT_LIMIT_FIELD := &"projectile_soft_limit"    # 全场软上限 1500（BalanceTables 字段键）
const BOOST_TEAM1_CAP: int = 320                # R269 A-5：保帧模式敌弹（team-1）活口帽
                                                #（深载观测量级 450 的 0.71——拒N 持续高=帽过紧
                                                # 第一轮回调信号，§4 待调参；关模式门恒不触）
const BOOST_DEEP_VOLLEY_RESERVE: int = 16      # R289 修轮 4（评审 P1-1）：深载帽沿给多丸武器
                                                # 预留的容量（=并排全链硬帽 16）。单发武器在 headroom
                                                # ≤16 时停火，保证 W3 等整轮武器在槽序靠后仍能齐射；
                                                # 只影响深载，boost 关恒不触。
const BOOST_DEEP_TEAM0_CAP: int = 200           # R289 B：深载（boost ∧ 滞回闩）玩家弹（team-0）
                                                # 活口帽——vc88 空敌窗实测 225-343 颗,弹段 5.6-18.9ms/步；
                                                # 帽 200 截去尾部 ~40% 稳态成本。超帽=该弹丸未生成（武器侧
                                                # try_fire 若整轮 0 丸返回 false → 不写冷却，容量恢复即续射；
                                                # 部分丸被拒的轮次仍按 fired>0 写冷却——多丸武器披露近似）。
                                                # 弹拒N 键直读（按弹丸/执行拍计）；boost 关恒不触。
                                                # 判据用 total_active−team1_live（避免新增 team0 计数器的
                                                # R269 翻转非对称坑）。
var soft_limit: int = 1500
var hard_limit: int = 2000                            # 硬上限（BalanceTables.projectile_hard_limit）
var forced_recycle_count: int = 0                     # FORCED 路径计数（遥测）
var team1_live: int = 0                               # R269：team-1（敌弹）活口计数——一计数两用：
                                                      # B 轨 敌弹N 键直读源（diag_counts plumb）+
                                                      # A 轨模式帽 320 判据（§3.4）；acquire(1)+1 /
                                                      # release 读 node.team==1 −1（_force_recycle_
                                                      # oldest_of_team 同款属性读）；测试可直写注入
                                                      # R269 修1（评审中#1）：活弹 team 翻转点同步
                                                      # note_team1_flip()（反射盾反弹——全库唯一翻转
                                                      # 点 enemy.try_reflect_projectile），另有 1Hz
                                                      # recount_team1() 实扫自愈兜底（见函数注）


func note_team1_flip() -> void:
	# R269 修1（评审中#1）：活弹 team 翻 1 时计数 +1——与 _active_remove 的属性读 −1
	# 配对成环（翻转点调用；防 敌弹N 低报/320 帽门变松的系统性漂移）。
	team1_live += 1


func recount_team1() -> int:
	# R269 修1（评审中#1）：沿 _live_order 实扫 team==1 真值并写回计数器（自愈口——
	# 1Hz 诊断采样（diag_counts）时调用，每秒 O(n) n≤1500 可接受；防未来新翻转点
	# 漏记 note_team1_flip 的兜底。release 钳 0 保留为防御不动。
	var n := 0
	for key in _live_order:
		var p := key as ProjectileBase
		if p != null and p.team == 1:
			n += 1
	team1_live = n
	return n

# 存活弹出借顺序（Dictionary 保插入序 → 取最老 O(1)；release 时 O(1) 擦除）
var _live_order: Dictionary = {}

# 活跃弹列表（包 4 帧序④：GameLoop 逐弹 tick 的数据源；acquire/release 双向维护）
var _active_list: Array[Node2D] = []

# R220 刀8④：活跃槽位索引 map（node → _active_list 下标）——release 的 erase O(n) 线性扫
# 换「尾元素换位 + 尾弹 O(1)」swap-remove（高周转深波 0.5-1ms/步收益，方案书刀8-④）。
# 遍历方契约（game_loop._tick_one_pool 快照缓冲迭代）：tick 内回收（自身/它弹）不再
# 移动未遍历元素——「单帧每活弹恰 tick 一次」红线由调用方快照缓冲兑现；直接倒序迭代
# _active_list 的旧调用方（elite_affix 等自回收型倒序遍历）在 swap-remove 下同样安全
#（当前位换入的是已遍历过的尾元素，倒序步进不重访）。
var _active_index: Dictionary = {}


func acquire(p_team: int = 0) -> ProjectileBase:
	# 类型收窄（架构原文口径）；超软上限 → null + 计数（调用方丢弃）。
	# c4② 敌弹保留配额（二cp#1：满场玩家弹时敌弹开火全被软上限吞掉——Boss 残血反杀
	# 弹幕真空）：p_team==1（敌弹）超软上限时沿 _live_order 插入序挤掉最老玩家弹
	#（team==0）腾位后重试一次；无玩家弹可挤仍 _register_miss + 返 null（口径不变）。
	# p_team==0（缺省=全部旧调用点）路径逐位不变——pkg0「超软上限→null+misses」锁零扰动。
	# R269 A-5：team-1 模式帽门在软上限判断**之前**（§3.4）——boost 开 ∧ team-1 活口 ≥320
	# → _register_miss + boost_bullet_capped（拒N 源）+ 返 null（该发未射，开火 CD 已消耗
	# ——与玩家弹 quota_dropped 同语义家族）；boost 关 → 门恒不触（含 headless 全部套件）。
	if p_team == 1 and PerfGovernor.boost_mode() and team1_live >= BOOST_TEAM1_CAP:
		_register_miss()
		DebugStats.count(&"boost_bullet_capped", 1)
		return null
	# R289 B：深载玩家弹帽（门序在敌弹帽之后、软上限之前——超帽拒绝即返，不进腾位链）。
	# boost 关/deep 关恒不触（deep_load 内含 boost 门）。
	if p_team == 0 and PerfGovernor.deep_load() \
			and total_active() - team1_live >= BOOST_DEEP_TEAM0_CAP:
		_register_miss()
		DebugStats.count(&"deep_bullet_capped", 1)
		return null
	if total_active() >= soft_limit:
		if p_team == 1 and _force_recycle_oldest_of_team(0):
			# 腾位成功重试一次：soft 判据已让位，直接走容量内路径
			var retry := super.acquire()
			if retry != null:
				_track_acquired(retry, p_team)
				return retry as ProjectileBase
		_register_miss()
		if p_team == 1:
			DebugStats.count(&"enemy_bullet_dropped", 1)   # 1Hz 丢弃遥测（腾位失败）
		return null
	var node := super.acquire()
	if node == null and total_active() >= hard_limit:
		# 硬上限触达：回收最老存活弹（FORCED 路径）后重试一次
		force_recycle_oldest()
		node = super.acquire()
	if node != null:
		_track_acquired(node, p_team)
	return node as ProjectileBase


func _track_acquired(p_node: Node, p_team: int) -> void:
	# acquire 成功路径的三账本登记（原 acquire 内联段抽取——敌弹腾位重试共用）
	_live_order[p_node] = true
	_active_list.append(p_node)
	_active_index[p_node] = _active_list.size() - 1
	if p_team == 1:
		team1_live += 1                      # R269：team-1 活口计数（敌弹N/模式帽共用——
		                                     # team 真源=acquire 参，spawn 期赋值与本计数同调）


func _force_recycle_oldest_of_team(p_team: int) -> bool:
	# c4②：按 team 过滤的 force_recycle_oldest——沿 _live_order 插入序找第一颗
	# team==p_team 的存活弹强制回收（FORCED 原因 meta 同硬上限口径）。无可挤件返 false。
	for key in _live_order:
		var pb: Variant = (key as Node).get("team")
		if typeof(pb) == TYPE_INT and int(pb) == p_team:
			forced_recycle_count += 1
			(key as Node).set_meta(&"_recycle_reason", GameConst.RecycleReason.FORCED)
			release(key)
			return true
	return false


func release(node: Node) -> void:
	# 架构原文签名 release(p: ProjectileBase)；GDScript 覆写不允许参数收窄，保持 Node 签名。
	# 清零契约由基类 _before_repool → p._reset_state() 承担（唯一清零入口）。
	_live_order.erase(node)
	_active_remove(node)
	super.release(node)


func _active_remove(node: Node) -> void:
	# R220 刀8④：O(1) swap-remove（原 _active_list.erase 线性扫）。尾元素换入被删槽并
	# 同步其索引项，尾弹 pop O(1)；非成员（重复归还被基类拦截前已擦 map 的幂等路径）直返。
	var idx: Variant = _active_index.get(node, -1)
	if typeof(idx) != TYPE_INT or int(idx) < 0:
		return
	var i := int(idx)
	var last := _active_list[_active_list.size() - 1]
	if last != node:
		_active_list[i] = last
		_active_index[last] = i
	_active_list.remove_at(_active_list.size() - 1)
	_active_index.erase(node)
	var pb: Variant = node.get("team")          # R269：team-1 活口计数递减（release 路径一次
	if typeof(pb) == TYPE_INT and int(pb) == 1: # 属性读——_force_recycle_oldest_of_team 同款模式）
		team1_live = maxi(team1_live - 1, 0)


func active_projectiles() -> Array[Node2D]:
	# 活跃弹列表（包 4 GameLoop 帧序④ tick 数据源；遍历方需倒序防回收重入）
	return _active_list


func force_recycle_oldest() -> void:
	# 硬上限 2000 触达时：回收最老存活弹（FORCED 路径）。
	# 回收原因经 meta 传递，包 2 的 ProjectileBase 在 _reset_state/_recycle 统一收束时消费。
	var oldest: Node = null
	for key in _live_order:
		oldest = key
		break
	if oldest == null:
		return
	forced_recycle_count += 1
	oldest.set_meta(&"_recycle_reason", GameConst.RecycleReason.FORCED)
	release(oldest)


func total_active() -> int:
	# 全场投射物计数（软/硬闸门判据）
	return _live_count


func team0_headroom() -> int:
	# R289 修轮（评审 P2-3）：深载玩家弹帽剩余容量（=帽 − team0 活口；钳 0）。
	# 多丸武器开火前整轮容量预检用——不足整轮时整轮跳（不写 CD），防 W3 等 9 丸
	# 武器在帽沿只出 1 丸的 1/9 残轮悬崖。
	return maxi(BOOST_DEEP_TEAM0_CAP - (total_active() - team1_live), 0)
