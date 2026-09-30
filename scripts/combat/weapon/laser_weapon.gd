# scripts/combat/weapon/laser_weapon.gd
# M-06 LaserWeapon（架构 §2.8.3，形态 B）：脉冲光束 W4 / 折射棱镜 W5 同构。
# · try_fire：cd 制维持主光束指向（目标策略：最近/最前）；主束常驻、每帧重定向。
# · _spawn_beam：深度 >2 拒绝 + chain_fused 计数（AC-04.3——W5 折射通道保留）；
#   W4 棱镜副束经同一出束口（p_opts.sub_beam，深度恒 0）。
# · build_tick_context 每跳 ctx 在 LaserBeam._settle_one_tick 构造（灼焦目标侧单池，
#   F-15；W4 裁定 2026-09-25：束私有池 → target_uid 全局单例）。
# · 逐级形态参数（scorch_max_layers/sub_ratio）经形态段 <key>_levels 新增键承载
#   （AC-02.1 仅新增键，不改类）。
# ── W4 五方向定案（2026-09-25 主束常驻化 + 棱镜副束）────────────────
# · 主束常驻化：W4 .tres 删 pulse_duration/tick_rate——spawn lifetime 缺省 0=常驻；
#   跳频 = L 表 rof（_leveled_param("tick_rate", get_stat(&"rof")) 现成通道，8/8/9/9/9）。
# · 副激光：MEC_SPLIT_PRISM 词条栈层数直读（try_fire/tick 维持位直读，仿
#   OrbitWeapon._orbit_link_knives 消费先例——计数键语义：豁免满层质变×1.6 与乘区名额，
#   不走 add 池）。每层 1 副束（stack_max=3 → 段数 1+3=4）；副束 dmg_mult=主×sub_ratio
#   （0.6，L5 ×0.75），focus_mult 恒 1.0（聚焦爬坡主束专属）。
# · 寻的：250px 内最近未锁定目标（复用 _nearest_unhit + REFRACT_SEARCH_RADIUS），
#   主束目标 + 兄弟互斥；目标不足并入主束目标 ×0.5 重叠回退（不叠灼焦、不附着）。
# · 束间拓扑 exclusive_group=laser_topology 三选一（挂载序取先，卡池侧互斥上架）：
#   MEC_BEAM_TRACK 独立寻的（缺省）/ MEC_BEAM_FAN 固定角随主束朝向（反挂机）/
#   MEC_BEAM_COFOCUS 全束钉单体。
# · 节奏词条：MEC_PHASE_SYNC（副束≥2 → 主束聚焦爬坡 15→30%/s，×2 封顶 6.7s→3.35s）；
#   MEC_BEAM_LAG（每存活副束主束跳频 +0.5/s，钳 [0.5,30]）；
#   AFF_CDR 消费点改写（W4 口径：换目标保留聚焦进度 12.5%×层数，4 层=50%；无挂载
#   归零口径与 R91 既有契约一致）；
#   MEC_BEAM_SPECTRA（副束按锁定次序轮转玩家元素池；束元素束侧化，删 KIN 硬编码）。
# · 阈值：TH_PRISM_CHOIR（sub_beam_count≥3 → 副束跳频 +2/s，EF_CHOIR，数据声明驱动）。
# · 表现：副束首次解锁 mechanics_intro 横幅；R183 复制体灰染（copy_tint）。
# ── R183 复制体接线口（player.gd _make_weapon_copy 消费，共享组）──────
#   copy.sub_beams_override = 0   # 复制体强制只出主束（W4 折减定案）
#   copy.copy_tint = true         # 复制体灰染（束色 RARITY_NORMAL）
# ── R195 穿透接线（2026-09-30）────────────────────────────────────
# · _pierce_count() 逐字镜像 ballistic（L 表 pierce + Add_Pierce 衰减聚合）——
#   预算口径 N=pierce=可命中总数（弹体 pierce_left 同源）；AFF_PIERCE 自本批起
#   激光可购（required_forms [0,1]），L 表 pierce=1 不动（平衡非目标）。
# · _spawn_beam 主束传 N、副束/折射束恒 1（束侧 _hit_budget 三重门同源）；
#   _on_tick_post 主束每拍回写 beam.pierce（仿 R191 tick_atk 逐拍回写先例——
#   运行中购卡即时生效；聚合值走 _pierce_cache 面板缓存，逐帧零分配——R188
#   每帧分配红线）。pause 面板穿透列经 pause_overlay.gd:566 has_method
#   守卫自动转正（零改动）。
class_name LaserWeapon
extends WeaponBase

const MAX_REFRACT_DEPTH: int = 2               # 折射分叉深度硬上限（B_spec；AC-04.3——W5）
const REFRACT_SEARCH_RADIUS := 250.0           # 折射/副束寻的半径（§5.2-5）
const CHOIR_SEARCH_RADIUS := 350.0             # §2.1.11 N=2 束质变：副束≥2 → 索敌半径 350px
const SUB_RATIO_FALLBACK := 0.5                # 重叠回退折价（并入主束目标 ×0.5）
const FAN_GAP_DEG := 24.0                      # MEC_BEAM_FAN 扇形相邻束夹角
const LAG_TICK_PER_SUB := 0.5                  # MEC_BEAM_LAG 每存活副束主束跳频增量
const CHOIR_TICK_BONUS := 2.0                  # TH_PRISM_CHOIR 副束跳频增量（params 缺省回退）
const FOCUS_RAMP_BASE := 0.15                  # R91 聚焦爬坡 15%/s（×2 封顶 6.7s 满）
const FOCUS_RAMP_SYNC := 0.30                  # PHASE_SYNC 双倍爬坡（×2 封顶 3.35s 满）
const CDR_FOCUS_KEEP_PER_LAYER := 0.125        # AFF_CDR 换目标聚焦保留 12.5%×层数（4 层=50%）
const TOPOLOGY_IDS: Array[StringName] = [
	&"MEC_BEAM_TRACK", &"MEC_BEAM_FAN", &"MEC_BEAM_COFOCUS"]   # laser_topology 三选一

var active_beams: Array[LaserBeam] = []        # 本武器存活光束段
var tick_accumulator: float = 0.0              # tick_rate 节拍（主束重定向缓存）
var _main_beam: LaserBeam = null
var _focus_uid: int = 0                        # R91 聚焦目标（W4：同目标持续照射伤害爬坡）
var _focus_time: float = 0.0                   # 持续照射秒数（+15%/s，封顶 +100%）
var _focus_enabled: bool = false               # 形态键 focus_ramp（W4 专属——W5 分光不变）
var _sub_beam_intro_done: bool = false         # 副束解锁横幅一次性闸
var _scorch_sweep_left: float = 0.0            # 灼焦目标池死亡 uid 清扫倒计时
# R183 复制体折减口（player.gd _make_weapon_copy 接线；正数/0 = 强制副束数，-1 = 按词条栈）
var sub_beams_override: int = -1
var copy_tint: bool = false                    # 复制体灰染（束色 RARITY_NORMAL）
var _pierce_cache: int = -1                    # 穿透预算缓存（-1=脏；失效点同 _panel_cache）


func setup(p_data: WeaponData, p_player: Node2D, p_deps: Dictionary) -> void:
	super(p_data, p_player, p_deps)
	active_beams.clear()
	tick_accumulator = 0.0
	_main_beam = null
	_pierce_cache = -1
	_focus_enabled = bool(data.laser.get("focus_ramp", false)) if data != null else false
	_focus_uid = 0
	_focus_time = 0.0
	_sub_beam_intro_done = false
	_scorch_sweep_left = LaserBeam.SCORCH_POOL_SWEEP_INTERVAL
	sub_beams_override = -1
	copy_tint = false


func _exit_tree() -> void:
	# 宿主离场（R183 复制体还原/换装/清场）→ 存活光束统一回收：W4 主束常驻
	# （lifetime=0）且光束挂池不挂宿主——宿主释放后无人驱动即永占池名额 + 冻结残影。
	# 与 GameLoop 残留清场序同一收束口径（_recycle 幂等：非 live 短路；双序安全）。
	for beam in active_beams:
		if beam != null and is_instance_valid(beam) and beam.is_live():
			beam._recycle()
	active_beams.clear()


func try_fire() -> bool:
	# 维持主光束（无目标也保持指向 UP——全自动开火持续）+ 副束补位
	if laser_pool == null:
		return false
	if _main_beam == null or not is_instance_valid(_main_beam) or not _main_beam.is_live():
		var beam := _spawn_beam(muzzle_position(), aim_direction(), 0, 1.0, 0)
		if beam == null:
			return false                       # 池满：拒绝新光束段（AC-14.4）
		_main_beam = beam
	_refresh_sub_beams()
	return true


func focus_multiplier() -> float:
	# R91 聚焦乘区：同目标持续照射 +15%/s（PHASE_SYNC 副束≥2 时 +30%/s），封顶 ×2
	# ——换目标按 AFF_CDR 层数保留进度（缺省归零口径不变）
	if not _focus_enabled:
		return 1.0
	return 1.0 + minf(_focus_time * _focus_rate(), 1.0)


func _on_tick_post(p_game_delta: float) -> void:
	# 主束重定向 + 副束补位/再瞄准 + 存活光束推进（死亡段裁剪）+ 灼焦池清扫
	var aim := aim_direction()
	if _main_beam != null and _main_beam.is_live():
		_main_beam.set_origin(muzzle_position())
		_main_beam.set_aim(aim)
		# R191 逐拍回写：常驻束（lifetime=0）不重建而镜面 meta_atk_pct（ratio）mid-run
		# 随 apply_state 变化——每拍刷新每跳 ATK（仿 _refresh_sub_beams tick_rate 回写先例）
		_main_beam.tick_atk = _tick_atk()
		# R195 逐拍回写：运行中购买 AFF_PIERCE 穿透预算即时生效（仿上方 R191 先例——
		# 常驻束不重建，预算随栈聚合 add_pierce 逐拍刷新）
		_main_beam.pierce = _pierce_count()
		# R91 聚焦爬坡：主束当前命中目标与上次一致 → 计时累积；换目标保留/归零
		var hit_uid := _main_beam.last_hit_uid
		if hit_uid > 0 and hit_uid == _focus_uid:
			if _focus_enabled:
				_focus_time += p_game_delta
		else:
			_focus_time = _focus_time * (_cdr_focus_keep() if _focus_enabled else 0.0)
			_focus_uid = hit_uid
		if _focus_enabled:
			_main_beam.focus_mult = focus_multiplier()
			_main_beam.apply_focus_visual(_focus_time)
	_refresh_sub_beams()
	_update_sub_aims(aim)
	for beam in active_beams.duplicate():
		if beam.is_live():
			beam.tick(p_game_delta)
		else:
			active_beams.erase(beam)
	_scorch_sweep_left -= p_game_delta
	if _scorch_sweep_left <= 0.0:
		_scorch_sweep_left = LaserBeam.SCORCH_POOL_SWEEP_INTERVAL
		LaserBeam.sweep_scorch_pool(enemy_grid)   # 死亡 uid 惰性回收（目标侧单池）


func _spawn_beam(p_origin: Vector2, p_dir: Vector2, p_depth: int, p_dmg_mult: float,
		p_target_uid: int, p_exclusions: Array[int] = [], p_opts: Dictionary = {}) -> LaserBeam:
	# 深度 >2 拒绝 + chain_fused 计数（AC-04.3）；p_opts.sub_beam=棱镜副束出束口
	if p_depth > MAX_REFRACT_DEPTH:
		DebugStats.count(&"laser_refract_rejected")
		EventBus.emit_chain_fused(p_depth, &"laser_refract")
		return null
	var is_sub := bool(p_opts.get("sub_beam", false))
	var beam := laser_pool.acquire() as LaserBeam
	if beam == null:
		if is_sub:
			DebugStats.count(&"laser_subbeam_rejected")   # 池满降级计数（副束补位失败）
		return null
	# 跳频 = 形态表 tick_rate × (1+ΣAdd_ROF)（射速强化对激光的真实收益——每秒照射
	# 结算跳数；2026-08-31 修复：此前 add_rof 仅 BallisticWeapon 消费，激光抽到射速卡
	# 是死卡。用户口径澄清：射速=束内结算跳频；冷却(AFF_CDR)=脉冲间隔 cd 缩短）。
	# W4 主束常驻化：.tres 删 tick_rate → 缺省回退 L 表 rof（8/8/9/9/9）。
	# R199 D13：基准式拆出为 _base_tick_rate()（refresh_fire_interval 回刷口同源复用）
	var tick_rate := _base_tick_rate()
	if is_sub:
		# TH_PRISM_CHOIR（sub_beam_count≥3 → 副束跳频 +2/s；数据声明驱动）
		tick_rate = clampf(tick_rate + _choir_tick_bonus(), 0.5, 30.0)
	elif _lag_bonus() > 0.0:
		# MEC_BEAM_LAG：每存活副束主束跳频 +0.5/s（钳 [0.5,30]）
		tick_rate = clampf(tick_rate + _lag_bonus(), 0.5, 30.0)
	beam.weapon = self
	beam.damage_pipeline = damage_pipeline
	beam.enemy_grid = enemy_grid
	beam.pool = laser_pool
	beam.spawn({
		"position": p_origin,
		"dir": p_dir,
		"depth": p_depth,
		"dmg_mult": p_dmg_mult,
		"tick_atk": _tick_atk(),
		"tick_rate": tick_rate,
		# R195 穿透预算：主束 = _pierce_count()（预算口径 N=pierce 可命中总数），
		# 副束/折射束恒 1（束侧 _hit_budget depth==0 ∧ ¬sub_beam ∧ ¬overlap_fallback 门同源防御）
		"pierce": _pierce_count() if (p_depth == 0 and not is_sub) else 1,
		"beam_length": float(data.laser.get("beam_length", 560.0)),
		"beam_width": float(data.laser.get("beam_width", 14.0)),
		# 脉冲寿命 s（0=常驻——W4 删 pulse_duration 后缺省 0=常驻主束定案；W5 口径不变）
		"lifetime": _leveled_param("pulse_duration",
			float(data.laser.get("pulse_duration", 0.0))),
		"scorch_max_layers": int(_leveled_param("scorch_max_layers",
			float(data.laser.get("scorch_max_layers", 5)))),
		"scorch_per_layer": float(data.laser.get("scorch_per_layer", 0.08)),
		"is_refraction": p_depth > 0,
		"refract_beams": int(_leveled_param("refract_beams",
			float(data.laser.get("refract_beams", 0)))),
		"refract_ratio": _leveled_param("refract_ratio",
			float(data.laser.get("refract_ratio", 0.6))),
		"refract_depth": int(_leveled_param("refract_depth",
			float(data.laser.get("refract_depth", 2)))),
		"panel_snapshot": build_panel_snapshot(),
		"trait_stack": trait_stack.copy_runtime() if trait_stack != null else null,
		"weapon_uid": uid,
		"weapon_ref": self,
		"target_uid": p_target_uid,
		"exclusions": p_exclusions,
		"team": 0,
		# W4 副束扩展键（主束缺省安全）：元素束侧化 + 重叠回退 + R183 灰染
		"element": int(p_opts.get("element", dominant_element())),
		"sub_beam": is_sub,
		"overlap_fallback": bool(p_opts.get("overlap_fallback", false)),
		"gray_tint": copy_tint,
	})
	active_beams.append(beam)
	if is_sub:
		_emit_subbeam_spawned(sub_beams_override >= 0 or copy_tint)   # 副束生成遥测（R187）
	return beam


func _on_beam_refracted(p_hit_pos: Vector2, p_parent: LaserBeam, p_count: int) -> void:
	# 命中带折射词条 → 分叉子光束：p_count 枚，向最近未命中目标（250px 内 ≠ 原目标，§5.2-5）
	# 排除集语义分离：子束继承「祖先链已命中集」快照（防回打祖先/已打过的目标），
	# 不含子束自己刚锁定的目标——否则子束首触锁定目标即被短路，深度 2 链不可达。
	if enemy_grid == null:
		return
	var exclusions := p_parent.hit_exclusions()
	var remaining := p_count
	while remaining > 0:
		var target := _nearest_unhit(p_hit_pos, exclusions)
		if target == null:
			break
		# 锁定目标只追加进寻的排除集（多分叉兄弟互斥）；子束携带追加前快照
		var child_exclusions: Array[int] = []
		child_exclusions.assign(exclusions)
		exclusions.append(int(target.get("uid")))
		var dir := ((target as Node2D).global_position - p_hit_pos).normalized()
		if dir == Vector2.ZERO:
			dir = Vector2.UP
		# 折射率乘区（二段 = ratio²：子束 dmg_mult = 父 × ratio）
		if _spawn_beam(p_hit_pos, dir, p_parent.depth + 1,
				p_parent.dmg_mult * p_parent.refract_ratio,
				int(target.get("uid")), child_exclusions) == null:
			break                             # 深度拒绝/池满：分叉终止
		remaining -= 1
		DebugStats.count(&"laser_refract_spawned")


func _nearest_unhit(p_pos: Vector2, p_exclusions: Array[int]) -> Node2D:
	# 最近未命中目标（排除集内目标；确定性距离升序）。
	# §2.1.11 N=2 束质变：副束数 ≥2（读 MEC_SPLIT_PRISM 层数）→ 索敌半径 250→350px；
	# 主束/单副束场景维持 250px 原口径（W5 无 SPLIT_PRISM 声明 → 恒 250 零波及）。
	if enemy_grid == null:
		return null
	var radius := CHOIR_SEARCH_RADIUS if _sub_beam_count() >= 2 else REFRACT_SEARCH_RADIUS
	var candidates: Array[Node2D] = []
	candidates.append_array(enemy_grid.query_circle(p_pos, radius))
	var best: Node2D = null
	var best_d := INF
	for cand in candidates:
		if bool(cand.get("dead")) or p_exclusions.has(int(cand.get("uid"))):
			continue
		var d := p_pos.distance_squared_to((cand as Node2D).global_position)
		if d < best_d:
			best_d = d
			best = cand
	return best


func attach_trait(p_trait: TraitData) -> bool:
	# 词条挂载钩子（副束/拓扑卡挂上即时补位——横幅与束数徽标即挂即现）
	var ok := super(p_trait)
	if ok and laser_pool != null and p_trait != null \
			and (p_trait.id == &"MEC_SPLIT_PRISM" or TOPOLOGY_IDS.has(p_trait.id)):
		_refresh_sub_beams()
	return ok


# ── 副激光（MEC_SPLIT_PRISM） ─────────────────────────────────────
func _sub_beam_count() -> int:
	# 副束数 = MEC_SPLIT_PRISM 挂载直读（仿 OrbitWeapon._orbit_link_knives 消费先例：
	# 参数构造侧直读挂载表——计数键语义，豁免满层质变×1.6 与乘区名额，不走 add 池）。
	# §2.1.3 品质梯：value 取整 × 层数（白 1.45→1 / 蓝 2.03→2 / 紫 2.9→3 每层）——
	# 卡面「+2/+3」与消费端一致（蓝紫卡此前恒 +1 的缩水修复）。
	# R183 折减口：sub_beams_override ≥ 0 → 强制覆盖（复制体 = 0 只出主束）。
	if sub_beams_override >= 0:
		return sub_beams_override
	if trait_stack == null:
		return 0
	for tb in trait_stack.traits:
		if tb.data != null and tb.data.id == &"MEC_SPLIT_PRISM":
			return maxi(int(round(float(tb.data.value))), 1) * tb.layers
	return 0


func _refresh_sub_beams() -> void:
	# 副束补位（want = 词条层数；存活不足逐个按拓扑规格生成；池满拒绝终止本轮）
	if laser_pool == null or data == null:
		return
	var want := _sub_beam_count()
	if want <= 0:
		return
	var alive := _alive_sub_beams()
	var spawned := false
	for i in range(alive.size(), want):
		var spec := _sub_spec(i, alive)
		if spec.is_empty():
			break                              # 全场无目标：延迟补位（敌现即射）
		var beam := _spawn_beam(muzzle_position(), spec["dir"], 0, spec["mult"],
			spec["target"], spec["excl"], {
				"sub_beam": true,
				"element": spec["element"],
				"overlap_fallback": spec["fallback"],
			})
		if beam == null:
			break                              # 池满：终止补位（laser_subbeam_rejected 已计）
		alive.append(beam)
		spawned = true
	if _main_beam != null and _main_beam.is_live() and _lag_bonus() > 0.0:
		_main_beam.tick_rate = _main_tick_rate()   # 副束增减即时传导主束跳频（BEAM_LAG）
	if spawned and not _sub_beam_intro_done:
		_sub_beam_intro_done = true
		EventBus.emit_mechanics_intro("棱镜分束：副激光 ×%d 上线" % _alive_sub_beams().size())


func _sub_spec(p_index: int, p_alive: Array[LaserBeam]) -> Dictionary:
	# 单副束规格（拓扑分派；主束目标+兄弟互斥排除集；重叠回退 ×0.5）
	var ratio := _leveled_param("sub_ratio", 0.6)
	var excl: Array[int] = []
	var main_uid := _focus_uid
	if main_uid <= 0:
		var mt := acquire_target()
		if mt != null:
			main_uid = int(mt.get("uid"))
	if main_uid > 0:
		excl.append(main_uid)
	for s in p_alive:
		if s.target_uid > 0:
			excl.append(s.target_uid)
	var element := _sub_element(p_index)
	match _beam_topology():
		&"fan":
			# MEC_BEAM_FAN：固定角随主束朝向（反挂机——不索敌、常驻扫场）
			var offset := (float(p_index) - float(_sub_beam_count() - 1) * 0.5) \
				* deg_to_rad(FAN_GAP_DEG)
			return {"dir": aim_direction().rotated(offset), "mult": ratio, "target": 0,
				"excl": excl, "element": element, "fallback": false}
		&"cofocus":
			# MEC_BEAM_COFOCUS：全束钉单体（与主束同目标，全额折价——束间拓扑定案）
			return {"dir": aim_direction(), "mult": ratio, "target": main_uid,
				"excl": excl, "element": element, "fallback": false}
		_:
			# MEC_BEAM_TRACK（缺省）：250px 内最近未锁定目标；不足 → 并入主束目标
			# ×0.5 重叠回退（不叠灼焦不附着）
			var target := _nearest_unhit(muzzle_position(), excl)
			if target != null:
				var dir := ((target as Node2D).global_position - muzzle_position()).normalized()
				if dir == Vector2.ZERO:
					dir = Vector2.UP
				return {"dir": dir, "mult": ratio, "target": int(target.get("uid")),
					"excl": excl, "element": element, "fallback": false}
			var fallback := acquire_target()
			if fallback == null:
				return {}
			return {"dir": aim_direction(), "mult": SUB_RATIO_FALLBACK,
				"target": int(fallback.get("uid")),
				"excl": excl, "element": element, "fallback": true}


func _alive_sub_beams() -> Array[LaserBeam]:
	# 存活副束集（active_beams 挂载序 = 锁定次序——SPECTRA 轮转真源）
	var out: Array[LaserBeam] = []
	for b in active_beams:
		if b != null and is_instance_valid(b) and b.is_live() and b != _main_beam:
			out.append(b)
	return out


func _update_sub_aims(p_aim: Vector2) -> void:
	# 拓扑逐帧再瞄准（track 束侧 _resolve_aim 自主锁定，此处不干预）
	match _beam_topology():
		&"fan":
			var alive := _alive_sub_beams()
			for i in range(alive.size()):
				var offset := (float(i) - float(alive.size() - 1) * 0.5) * deg_to_rad(FAN_GAP_DEG)
				alive[i].set_aim(p_aim.rotated(offset))
		&"cofocus":
			for s in _alive_sub_beams():
				if _focus_uid > 0:
					s.target_uid = _focus_uid    # 全束钉单体（跟随主束聚焦目标）
				else:
					s.target_uid = 0
					s.set_aim(p_aim)
		_:
			pass


func _sub_element(p_index: int) -> int:
	# MEC_BEAM_SPECTRA：副束按锁定次序轮转玩家元素池（ELE 词条挂载序去重）；
	# 未挂 → 主束附魔元素（dominant/KIN）
	var pool := _spectra_elements()
	if _has_trait(&"MEC_BEAM_SPECTRA") and not pool.is_empty():
		return pool[p_index % pool.size()]
	return dominant_element()


func _spectra_elements() -> Array[int]:
	# 玩家元素池（ELE 词条 params.element 挂载序去重——SPECTRA 轮转源）
	var out: Array[int] = []
	if trait_stack == null:
		return out
	for tb in trait_stack.traits:
		var td: Variant = tb.get("data")
		if td != null and int(td.pool) == GameConst.PoolClass.ELEM \
				and (td as TraitData).params.has("element"):
			var e := int((td as TraitData).params["element"])
			if not out.has(e):
				out.append(e)
	return out


func _beam_topology() -> StringName:
	# laser_topology 三选一：挂载序取先（卡池侧 exclusive_group 互斥上架；引擎侧防御取一）
	if trait_stack != null:
		for tb in trait_stack.traits:
			if tb.data == null:
				continue
			var id: StringName = tb.data.id
			if id == &"MEC_BEAM_FAN":
				return &"fan"
			if id == &"MEC_BEAM_COFOCUS":
				return &"cofocus"
			if id == &"MEC_BEAM_TRACK":
				return &"track"
	return &"track"


# ── 节奏词条（PHASE_SYNC / BEAM_LAG / AFF_CDR / PRISM_CHOIR） ──────
func _focus_rate() -> float:
	# 主束聚焦爬坡速率：MEC_PHASE_SYNC 且存活副束≥2 → 30%/s（×2 封顶 3.35s）；缺省 15%/s
	if _has_trait(&"MEC_PHASE_SYNC") and _alive_sub_beams().size() >= 2:
		return FOCUS_RAMP_SYNC
	return FOCUS_RAMP_BASE


func _cdr_focus_keep() -> float:
	# AFF_CDR 消费点改写（W4 口径）：换目标保留聚焦进度 12.5%×层数（4 层=50%；
	# 未挂载 = 0 → 归零重聚，R91 既有契约不变）
	if trait_stack == null:
		return 0.0
	var layers := 0
	for tb in trait_stack.traits:
		if tb.data != null and tb.data.id == &"AFF_CDR":
			layers += tb.layers
	return clampf(CDR_FOCUS_KEEP_PER_LAYER * float(layers), 0.0, 1.0)


func _lag_bonus() -> float:
	# MEC_BEAM_LAG：每存活副束主束跳频 +value/s ×层数（未挂载/无存活副束 = 0）。
	# R199 F02：旧实现 LAG_TICK_PER_SUB(0.5) 常数 + _has_trait 存在性判断——既不乘
	# data.value 也不乘层数（金卡卡面「+1.3 跳/s」实发 +0.5；stack_max=2 第二层零效果）。
	# 改读挂载条目 value×layers（品质缩放沿 card_generator value×scale 链路）；value≤0
	#（桩夹具零声明）回落 LAG_TICK_PER_SUB 旧口径，存量断言零位移。钳制在消费侧 [0.5,30]。
	if trait_stack == null:
		return 0.0
	for tb in trait_stack.traits:
		if tb.data != null and tb.data.id == &"MEC_BEAM_LAG":
			var per_sub := float(tb.data.value)
			if per_sub <= 0.0:
				per_sub = LAG_TICK_PER_SUB
			return per_sub * float(tb.layers) * float(_alive_sub_beams().size())
	return 0.0


func _main_tick_rate() -> float:
	# 主束跳频终值（BEAM_LAG 动态重算口；钳 [0.5,30]）
	var base := _base_tick_rate()
	var lag := _lag_bonus()
	if lag <= 0.0:
		return base
	return clampf(base + lag, 0.5, 30.0)


func refresh_fire_interval() -> void:
	# R199 D13：rof 变更回刷常驻束跳频。束 tick_rate 只在 _spawn_beam 瞬间定格（束体
	# lifetime=0 常驻不重建），过载咆哮/双生回响/改造者·枢 CDR 折算（player.rof_mult/
	# comp_rof_mult/map_rof_mult——player.refresh_weapon_intervals 逐武器鸭子调本口）
	# 与 AFF_ROF 挂卡在增益期对激光族此前零收益。对齐 :325 BEAM_LAG 回写先例（只写
	# tick_rate，束内 _tick_left 下拍自然按新间隔续走）；事件驱动调用（挂卡/技能启停/
	# 升级），非逐帧路径——R188 每帧分配红线不适用。
	super()
	_refresh_beam_tick_rates()


func _refresh_beam_tick_rates() -> void:
	# 常驻束跳频重导出（口径同 _spawn_beam 逐束分派：主束含 BEAM_LAG、副束含 CHOIR、
	# 折射束纯基准；非 live 束跳过——回收序在 _reset_state 清 weapon 前安全）
	for beam in active_beams:
		if beam == null or not is_instance_valid(beam) or not beam.is_live():
			continue
		if beam == _main_beam:
			beam.tick_rate = _main_tick_rate()
		elif beam.sub_beam:
			beam.tick_rate = clampf(_base_tick_rate() + _choir_tick_bonus(), 0.5, 30.0)
		else:
			beam.tick_rate = _base_tick_rate()


func _base_tick_rate() -> float:
	# 跳频基准（不含 BEAM_LAG/CHOIR 修饰——_spawn_beam 既有公式拆出复用）
	return clampf(_leveled_param("tick_rate", get_stat(&"rof"))
		* (1.0 + _add_rof()) * _player_rof_mult(), 0.5, 30.0)


func _tick_atk() -> float:
	# 每跳基础 ATK = L 表 base_atk × (1+meta_atk_pct)（R191 修复：此前 _spawn_beam 裸
	# get_current_atk() 使 meta_atk_pct 在激光伤害路径零消费——镜面 W4 恒按 100% 源强度
	# 出束，违背 R187「镜面伤害=源面板×mirror_ratio」；面板式对齐弹道路径先例
	# weapon_base.build_panel_snapshot）。meta=0 夹具数值不变（存量断言零位移）。
	return get_current_atk() * (1.0 + meta_atk_pct)


func _invalidate_panel() -> void:
	# R195 红线配套：主束逐拍回写 _pierce_count() 走每帧 _on_tick_post 路径，聚合值
	# 随面板缓存（_pierce_cache）挂同一失效链（weapon_base 挂卡/质变/升级、mirror、
	# player 广播全部虚派发到本覆写）——每帧零分配，购卡/升级当拍即失效重算。
	super()
	_pierce_cache = -1


func _pierce_count() -> int:
	# R195 穿透预算 N（逐字镜像 ballistic_weapon.gd:256-261）：pierce = L 表值 +
	# Add_Pierce 线性层（穿透弹头 AFF_PIERCE 自本批起激光可购——F3 衰减聚合与弹体
	# 同式）；预算口径 N=pierce=可命中总数（弹体 pierce_left 同源，pkg2:464-469 锁定）。
	# pause 面板穿透列经 pause_overlay.gd:566 has_method("_pierce_count") 守卫自动转正。
	# R195 红线：本函数在 _on_tick_post 每帧消费——aggregate_panel() 每调新建
	# Dictionary（trait_stack.gd:144），不可逐帧直调；聚合值走 _pierce_cache
	#（失效链同 _panel_cache，见 _invalidate_panel 覆写），逐帧零分配。
	if _pierce_cache < 0:
		var extra := 0
		if trait_stack != null:
			extra = int(round(float(trait_stack.aggregate_panel().get("add_pierce", 0.0))))
		_pierce_cache = maxi(int(get_stat(&"pierce")) + extra, 0)
	return _pierce_cache


func _choir_tick_bonus() -> float:
	# TH_PRISM_CHOIR（sub_beam_count≥3 → 副束跳频 +2/s）：数据声明驱动，
	# params.tick_rate_bonus 缺省回退常量（EF_CHOIR 处理器白名单由共享组落位）
	var th := get_threshold(&"TH_PRISM_CHOIR")
	if th.is_empty() or float(th.get("threshold", 3.0)) > float(_sub_beam_count()):
		return 0.0
	var params: Variant = th.get("params", {})
	if params is Dictionary and (params as Dictionary).has("tick_rate_bonus"):
		return float((params as Dictionary)["tick_rate_bonus"])
	return CHOIR_TICK_BONUS


func _has_trait(p_id: StringName) -> bool:
	if trait_stack == null:
		return false
	for tb in trait_stack.traits:
		if tb.data != null and tb.data.id == p_id:
			return true
	return false


# ── 表现/遥测 ─────────────────────────────────────────────────────
func _emit_subbeam_spawned(p_is_copy: bool) -> void:
	# 新信号 laser_subbeam_spawned(owner_kind)（共享组 R187 落点，EventBus.emit_laser_
	# subbeam_spawned 包装派发）——HUD 束数徽标 + R183 折减断言通道。owner_kind ∈
	# {SUBBEAM_OWNER_BODY=0 本体, SUBBEAM_OWNER_COPY=1 复制体}（复制体折减后恒不发，
	# COPY 值保留断言用——GameConst 归属字段口径）。
	EventBus.emit_laser_subbeam_spawned(
		GameConst.SUBBEAM_OWNER_COPY if p_is_copy else GameConst.SUBBEAM_OWNER_BODY)


func _leveled_param(p_key: String, p_default: float) -> float:
	# 逐级形态参数（形态段新增键 <key>_levels: Array[float]——A3 §3.4/§3.5 逐级递进）
	var levels: Variant = data.laser.get(String(p_key) + "_levels", null)
	if levels is Array and level >= 1 and level <= (levels as Array).size():
		return float((levels as Array)[level - 1])
	return p_default


func _add_rof() -> float:
	# ΣAdd_ROF（射速强化词条池聚合——与 BallisticWeapon._add_rof 同源同式；激光消费点
	# = tick_rate 跳频乘区，见 _spawn_beam）
	if trait_stack == null:
		return 0.0
	return float(trait_stack.aggregate_panel().get("add_rof", 0.0))
