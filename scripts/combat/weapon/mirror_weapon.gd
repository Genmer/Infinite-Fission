# scripts/combat/weapon/mirror_weapon.gd
# R187 W5「万镜回廊」棱镜本体（棱镜组）：折射退役（.tres 真删 refract 五键——锚束
# 经 LaserWeapon 现成常驻通道，refract_* 缺省 0 = 单束校准锚），新增镜面军团编排层。
# · 镜面生成：从场上其他真实武器（排除 W5 自身/空槽/诺亚复制体）锁定——实体 =
#   player.make_mirror_image（共享侧白板构造：源 data+等级开火、栈=棱镜栈 copy_full、
#   ELE 零注册）→ MirrorImage 包装 → player.register_mirror 入册（_mirror_images
#   独立数组：不占武器槽、永不进 _summon_copies、_reset_skill_temp_state 不清）。
# · 镜数轴：laser.mirrors_count_levels 等级曲线 + MEC_MIRROR_SPLIT 词条层数，
#   绝对帽 5（player.mirror_capacity 同源钳 [0,5]）。
# · 指向轴（exclusive_group=prism_pointer 二选一，挂载序取先）：
#   MEC_MIRROR_LOCK 不再重掷（既有指向固化为确定性出口）/
#   MEC_MIRROR_WEIGHT 恒指向面板 DPS 最高武器；缺省 = 波首/获新武器/读档时按
#   「武器槽序 + 固定哈希(武器 id)」确定性重推导（player.deterministic_source_pick 同源
#   ——同组合逐局一致；存档层冻结零新增键，镜面为会话态）。
# · 激光镜帽：指向激光形态源的镜面 ≤ laser.mirror_laser_cap（镜面与本体共享 laser 池
#   ——池满静默降级：超帽镜位确定性替换为非激光候选，无候选则休眠 + mirror_rejected）。
# · 发射预算：镜面组 ≤ laser.mirror_budget_per_s 发/s（滚动 1s 窗 Keeper，MirrorImage
#   逐拍问询——超预算该拍静默跳过 + mirror_budget_skipped 计数）。
# · 强度：mirror_ratio_levels 逐级 + TH_MIRROR_CHOIR（mirror_count≥3 → +0.1，
#   有效帽 0.7）——apply_state 落内壳 meta_atk_pct。
# · 会话态纪律：换局由 player.clear_mirrors 全清（重开随武器重建）；本类不持久化任何
#   镜面字段，读档重建后首拍按组合签名确定性重推导。
class_name MirrorWeapon
extends LaserWeapon

const MIRROR_CAP: int = 5                      # 镜数绝对帽（等级 3 + MEC_MIRROR_SPLIT 2）
const RATIO_CAP: float = 0.7                   # 镜面强度有效帽（TH_MIRROR_CHOIR 加成后仍 ≤0.7）
const BUDGET_WINDOW_S: float = 1.0             # 发射预算滚动窗（600 发/s 口径）
const CHOIR_RATIO_BONUS_FALLBACK := 0.1        # TH_MIRROR_CHOIR 加成缺省（params 缺省回退）
const WEIGHT_DPS_TIE_EPS := 0.001              # 面板 DPS 并列判据（并列取槽序在前——确定性）

var mirrors: Array[MirrorImage] = []           # 镜面实体表（与 player._mirror_images 同集）
var deps_pkg: Dictionary = {}                  # 注入包透传（镜面内壳构造——pipeline/pools/grid/…）
var _composition_sig: String = ""              # 武器槽序+id 组合签名（变化 → 确定性重推导）
var _budget_spent: float = 0.0                 # 本窗已计费发射数（镜面组）
var _budget_window: float = 0.0                # 滚动窗推进游标


func setup(p_data: WeaponData, p_player: Node2D, p_deps: Dictionary) -> void:
	super(p_data, p_player, p_deps)
	deps_pkg = p_deps
	mirrors.clear()
	_composition_sig = ""
	_budget_spent = 0.0
	_budget_window = 0.0
	# R191 引擎侧硬保证：棱镜本体永不出副束（super 置 -1 后此处钉 0）——七张束卡
	# required_weapon 锁 W4 数据侧拦截卡架/回响，直挂 attach_trait 不经门由此兜底，
	# W5 束段指纹恒 ==1（与 laser_weapon.gd 头部「W5 校准锚束单段」注释假设一致）。
	sub_beams_override = 0


func attach_trait(p_trait: TraitData) -> bool:
	# 词条挂载钩子：镜数（MIRROR_SPLIT）/指向（LOCK/WEIGHT 互斥组）/奏鸣（TEMPO）/
	# 强度（间接）挂上即全镜生效——白板语义「一张棱镜卡 = N 镜生效」
	var ok := super(p_trait)
	if ok and p_trait != null:
		_pull_pointer_lock()
		sync_mirrors(true)
	return ok


func level_up() -> void:
	# 精通升级：镜数曲线/强度曲线逐级成长即时生效（TH_MIRROR_CHOIR 门槛随镜数跨越）
	super.level_up()
	sync_mirrors(true)


func _on_tick_post(p_game_delta: float) -> void:
	# 锚束推进（super：主束重定向/存活段推进/灼焦池清扫）→ 预算窗推进 → 镜面编排
	#（组合签名变化 = 获新武器/读档重建/源失效 → 空闲与失配镜位确定性重推导）
	super._on_tick_post(p_game_delta)
	_advance_budget_window(p_game_delta)
	sync_mirrors(false)


# ── 镜面编排（入场/重掷；玩家侧只供容器与驱动——player.gd 同拍 tick/refresh 镜面） ──
func sync_mirrors(p_force: bool) -> void:
	# 组合签名门（非 force 时仅在武器组合/镜数/实体失效/玩家容器被外部清空时重排
	# ——驱动 11s 指向不变；clear_mirrors 重开口由注册表同步检查感知）
	if data == null or player == null or not is_instance_valid(player):
		return
	var capacity := desired_mirror_count()
	var sig := _composition_signature()
	if not p_force and sig == _composition_sig and mirrors.size() == capacity \
			and _all_sources_alive() and _player_registry_in_sync():
		return
	_composition_sig = sig
	var picks := _assign_sources(_candidate_sources(), capacity)
	_reconcile(picks, capacity)


func desired_mirror_count() -> int:
	# 镜数容量：等级曲线 + MEC_MIRROR_SPLIT 层数（player.mirror_capacity 同源），绝对帽 5
	#（player 为宽类型 Node2D——共享侧 API 一律 call() 动态调用，weapon_base.gd 先例）
	if player == null or not is_instance_valid(player) \
			or not player.has_method(&"mirror_capacity"):
		return 0
	return clampi(int(player.call(&"mirror_capacity", self)), 0, MIRROR_CAP)


func mirror_ratio() -> float:
	# 镜面强度：mirror_ratio_levels 逐级 + TH_MIRROR_CHOIR（mirror_count≥3 → +0.1，
	# 有效帽 0.7——数据声明驱动，params.ratio_bonus 缺省回退）
	if data == null:
		return 0.5
	var ratio := _leveled_param("mirror_ratio", float(data.laser.get("mirror_ratio", 0.5)))
	var th := get_threshold(&"TH_MIRROR_CHOIR")
	if not th.is_empty():
		var need := float(th.get("threshold", 3.0))
		if desired_mirror_count() >= need:
			var params: Variant = th.get("params", {})
			var bonus := CHOIR_RATIO_BONUS_FALLBACK
			if params is Dictionary and (params as Dictionary).has("ratio_bonus"):
				bonus = float((params as Dictionary)["ratio_bonus"])
			ratio += bonus
	return minf(ratio, RATIO_CAP)


# ── 发射预算 Keeper（镜面组滚动窗；MirrorImage 逐拍问询/计费） ─────────────
func budget_per_s() -> float:
	# 镜面组发射预算（laser.mirror_budget_per_s，缺省 600 发/s——镜面预算键落 W5 数据）
	if data == null:
		return 600.0
	return maxf(float(data.laser.get("mirror_budget_per_s", 600.0)), 1.0)


func budget_available() -> bool:
	return _budget_spent < budget_per_s()


func budget_spend(p_shots: float) -> void:
	_budget_spent += maxf(p_shots, 0.0)


func _advance_budget_window(p_game_delta: float) -> void:
	_budget_window += p_game_delta
	if _budget_window >= BUDGET_WINDOW_S:
		_budget_window = fmod(_budget_window, BUDGET_WINDOW_S)
		_budget_spent = 0.0                          # 窗翻转：预算恢复


# ── 指向轴（prism_pointer 二选一；确定性重推导/锁定/最肥镜像） ────────────
func pointer_mode() -> StringName:
	# 挂载序取先（卡池侧 exclusive_group=prism_pointer 互斥上架；引擎侧防御取一）
	if trait_stack != null:
		for tb in trait_stack.traits:
			if tb.data == null:
				continue
			var id: StringName = tb.data.id
			if id == &"MEC_MIRROR_LOCK" or id == &"MEC_MIRROR_WEIGHT":
				return id
	return &""


func laser_mirror_cap() -> int:
	# 激光镜面数帽（镜面与本体共享 laser 池——laser.mirror_laser_cap，缺省 2）
	if data == null:
		return 2
	return maxi(int(data.laser.get("mirror_laser_cap", 2)), 0)


static func find_prism(p_player: Node2D) -> MirrorWeapon:
	# 在场棱镜查询（HUD 镜面角标/测试/集成接线口；无棱镜 → null）
	if p_player == null or not is_instance_valid(p_player):
		return null
	var slots: Variant = p_player.get("weapon_slots")
	if not (slots is Array):
		return null
	for w in (slots as Array):
		if w is MirrorWeapon and is_instance_valid(w):
			return w
	return null


# ── 内部：指向推导与镜面重排 ─────────────────────────────────────
func _candidate_sources() -> Array[WeaponBase]:
	# 可映照源集：weapon_slots 真实武器（排除 W5 自身/空槽——deterministic_source_pick
	# 同池口径；诺亚复制体在 _summon_copies 不入扫描——临时件永不产出永久件）
	var out: Array[WeaponBase] = []
	var slots: Variant = player.get("weapon_slots")
	if not (slots is Array):
		return out
	for w in (slots as Array):
		if w != null and is_instance_valid(w) and w is WeaponBase \
				and (w as WeaponBase).data != null \
				and String((w as WeaponBase).data.id) != "W5_prism":
			out.append(w)
	return out


func _composition_signature() -> String:
	# 组合签名 = 槽序:武器 id 全列（含自身——镜面指向随组合确定性重推导的真源键）
	var parts: Array[String] = []
	var slots: Variant = player.get("weapon_slots")
	if slots is Array:
		for i in range((slots as Array).size()):
			var w: Variant = (slots as Array)[i]
			if w != null and is_instance_valid(w) and (w as WeaponBase).data != null:
				parts.append("%d:%s" % [i, String((w as WeaponBase).data.id)])
			else:
				parts.append("%d:-" % i)
	return "|".join(parts)


func _assign_sources(p_candidates: Array[WeaponBase], p_capacity: int) -> Array[WeaponBase]:
	# 指向推导：缺省/LOCK = deterministic_source_pick 逐镜位哈希重推导（LOCK 保留仍
	# 在场的既有指向——「不再重掷」）；WEIGHT = 恒指向面板 DPS 最高武器。
	# 之后统一过激光镜帽：超帽激光镜位确定性替换为非激光候选（无 → 休眠 + 计数）。
	var picks: Array[WeaponBase] = []
	if p_capacity <= 0 or p_candidates.is_empty():
		return picks
	var mode := pointer_mode()
	for i in range(p_capacity):
		if mode == &"MEC_MIRROR_LOCK" and i < mirrors.size() \
				and mirrors[i] != null and is_instance_valid(mirrors[i]) \
				and not mirrors[i].is_queued_for_deletion():
			var keep: WeaponBase = mirrors[i].source_weapon
			if keep != null and is_instance_valid(keep) and keep.data != null \
					and _in_sources(keep, p_candidates):
				picks.append(keep)                   # LOCK：既有指向固化（波首/获新武器不重掷）
				continue
		picks.append(player.call(&"deterministic_source_pick", i))
	if mode == &"MEC_MIRROR_WEIGHT":
		var best := _max_panel_dps_source(p_candidates)
		if best != null:
			for i in range(picks.size()):
				picks[i] = best                      # 最肥镜像：全镜恒指向面板 DPS 最高武器
	# 激光镜帽过滤（性能护栏：镜面激光 ≤ mirror_laser_cap 面，与本体共享 laser 池）
	var laser_used := 0
	var capped: Array[WeaponBase] = []
	var cap := laser_mirror_cap()
	for i in range(picks.size()):
		var pick: WeaponBase = picks[i]
		if pick != null and pick.data.form == GameConst.WeaponForm.LASER:
			if laser_used < cap:
				laser_used += 1
				capped.append(pick)
				continue
			var sub := _substitute_non_laser(p_candidates, i)
			if sub != null:
				capped.append(sub)                   # 确定性替补（槽序首个非激光候选）
			else:
				DebugStats.count(&"mirror_rejected")
				capped.append(null)                  # 池满静默降级：镜位休眠（锚束标记）
		else:
			capped.append(pick)
	return capped


func _reconcile(p_picks: Array[WeaponBase], p_capacity: int) -> void:
	# 镜面重排：指向未变的镜位原镜复用（保留 fired_shots_total 等会话态），失配镜位
	# 重建（make_mirror_image 白板构造 → MirrorImage 包装 → register_mirror 入册）；
	# 裁剪冗余镜位；新指向播报「棱镜映照：镜面承接了 X」。
	var wanted_ratio := mirror_ratio()
	var next: Array[MirrorImage] = []
	var reuse_pool := mirrors.duplicate()
	var fresh_names: Array[String] = []
	for i in range(p_capacity):
		if i >= p_picks.size():
			break
		var want: WeaponBase = p_picks[i]
		var img: MirrorImage = null
		if want != null:
			for cand in reuse_pool:
				if cand != null and is_instance_valid(cand) \
						and not cand.is_queued_for_deletion() \
						and cand.source_weapon == want:
					img = cand
					reuse_pool.erase(cand)
					break
		if img == null:
			if want == null:
				continue                             # 休眠镜位（不入册——镜数即实体数）
			img = MirrorImage.new()
			img.name = "MirrorImage%d" % i
			if not img.setup_mirror(self, want, wanted_ratio, i):
				img.free()
				DebugStats.count(&"mirror_rejected")
				continue                             # 构造失败（源失效竞态）：镜位休眠
			if player.call(&"register_mirror", img, MIRROR_CAP):
				fresh_names.append(String(want.data.display_name))
			else:
				img.queue_free()                     # register_mirror 帽拒（已计 mirror_rejected）
				img = null
				continue
		else:
			img.apply_state(wanted_ratio)            # 复用镜位：强度/栈/源等级随镜首重铺
		next.append(img)
	for stale in reuse_pool:
		_retire_mirror(stale)
	mirrors = next
	if not fresh_names.is_empty():
		EventBus.emit_mirror_formed("棱镜映照：镜面承接了 %s" % "、".join(fresh_names))


func _retire_mirror(p_img: MirrorImage) -> void:
	# 镜面退役（失配/裁剪）：玩家侧容器同步摘除 + 实体回收（重开走 clear_mirrors 全清）
	if p_img == null:
		return
	var arr: Variant = player.get("_mirror_images")
	if arr is Array:
		(arr as Array).erase(p_img)
	if is_instance_valid(p_img):
		p_img.queue_free()


func _in_sources(p_weapon: WeaponBase, p_candidates: Array[WeaponBase]) -> bool:
	return p_candidates.has(p_weapon)


func _substitute_non_laser(p_candidates: Array[WeaponBase], _p_index: int) -> WeaponBase:
	# 激光镜帽挤出的确定性替补：候选集槽序首个非激光武器（同组合同镜位恒同替补——
	# 确定性不破）；无非激光候选 → null（镜位休眠——池满静默降级口径）
	for cand in p_candidates:
		if cand != null and is_instance_valid(cand) and cand.data != null \
				and cand.data.form != GameConst.WeaponForm.LASER:
			return cand
	return null


func _max_panel_dps_source(p_candidates: Array[WeaponBase]) -> WeaponBase:
	# 面板 DPS 最高源（WEIGHT 指向真源）：面板 atk × 节拍（弹道 rof / 其余 1÷cd）；
	# 并列取槽序在前（候选集本身槽序——严格大于比较即确定性）
	var best: WeaponBase = null
	var best_dps := -1.0
	for cand in p_candidates:
		var dps := _panel_dps(cand)
		if dps > best_dps + WEIGHT_DPS_TIE_EPS:
			best_dps = dps
			best = cand
	return best


func _panel_dps(p_weapon: WeaponBase) -> float:
	if p_weapon == null or not is_instance_valid(p_weapon) or p_weapon.data == null:
		return 0.0
	var atk := float(p_weapon.build_panel_snapshot().get("base_atk", 0.0))
	if p_weapon.data.form == GameConst.WeaponForm.BALLISTIC:
		return atk * maxf(float(p_weapon.get_stat(&"rof")), 0.1)
	return atk / maxf(float(p_weapon.get_stat(&"cd")), 0.01)


func _pull_pointer_lock() -> void:
	# MEC_MIRROR_LOCK 挂载态同步（player._mirror_locked 共享旗——「挂卡后波首不重掷」
	# 确定性出口；卸载口径：LOCK 不在挂载表即回退重掷流）
	if player != null and is_instance_valid(player) and player.has_method(&"set_mirror_locked"):
		player.call(&"set_mirror_locked", pointer_mode() == &"MEC_MIRROR_LOCK")


func _all_sources_alive() -> bool:
	for img in mirrors:
		if img == null or not is_instance_valid(img) or img.is_queued_for_deletion():
			return false
		if img.source_weapon == null or not is_instance_valid(img.source_weapon):
			return false
	return true


func _player_registry_in_sync() -> bool:
	# 玩家侧容器同步检查（clear_mirrors 重开口感知：外部清空后本侧残影不复用不复活
	# ——下一拍编排按确定性规则重推导重建）
	var arr: Variant = player.get("_mirror_images")
	if not (arr is Array):
		return false
	for img in mirrors:
		if img != null and (arr as Array).find(img) < 0:
			return false
	return true
