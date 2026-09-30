# scripts/combat/weapon/ballistic_weapon.gd
# M-05 BallisticWeapon（架构 §2.8.2，形态 A）：手枪/加特林/霰弹三变体同构。
# · 手枪：匀速直线 + 微散射（±spread_deg）；霰弹：N=pellets 发散射锥均匀分布；
#   加特林：spin_up_time 预热 → rof_hot 满热（F11 分段：预热→满热→停射 0.8s 冷却重置）。
# · 射速口径：rof_final = rof × (1+ΣAdd_ROF) clamp 30（双护栏；加特林冷/热插值后同样钳制）。
# · 出弹链路：面板快照 + 词条运行时栈（copy_runtime）→ ProjectilePool.acquire →
#   spawn 参数字典（契约冻结，§2.7.1 注）；词条 OnSpawn 期完成体积/反弹预算/元素标记。
# · R187 §2.4 W1「并行弹幕 × 跳弹增值」双路线（数据驱动，无 lateral_gap_levels 键的
#   加特林/霰弹全路径行为不变）：
#   ① 编队几何：lateral_gap_levels 出膛横向偏移（spawn 契约 position 侧）+
#      converge_pct_levels 收束（初速矢量法：外偏弹指向瞄准线上 converge×射程 焦点，
#      直线飞行即达「55% 射程收束 <10px」几何；converge_authored 标记告知弹体侧
#      steer 通道本弹初速已按收束调制，防二次修正）；
#   ② 跳弹增值：bounce_levels 反弹预算（原 :76 硬编码 bounces:0 改读 _leveled_param）+
#      bounce_amp 每跳增伤乘区（命中时点经 inject_relic_pools 注入，帽 +100%）；
#   ③ TH_VOLLEY_STATE 弹幕态（pellets≥6 → 4s 间隔 ×0.8 + 并排 +2 → 3s 散热）；
#   ④ TH_BANK_SHOT 黄金弹（单弹 bounce_count≥12 → 必暴 + 落点弹片）；
#   ⑤ MEC_PARALLEL_CAL / MEC_RICOCHET_HALL 消费（阵宽 +4/层、收束点 +5%/层、回廊标记）；
#   ⑥ 永存弹同屏配额 240（达满 → get_threshold 对 TH_BOUNCE_ETERNAL 断供）。
class_name BallisticWeapon
extends WeaponBase

var spin_up_left: float = 0.0                  # 加特林预热剩余（0 = 非加特林/已满热）
var rof_current: float = 0.0                   # F11：rof × (1+ΣAdd_ROF) clamp 30（当前口径）
var _since_fire: float = 999.0                 # 距上次开火（停射 0.8s 冷却重置判据）
const SPIN_COOLDOWN_RESET := 0.8               # 停射冷却重置（A3 §3.2）

# ── R187 §2.4 W1 并行弹幕/跳弹增值（常量口径） ────────────────────
const FORMATION_PELLET_CAP := 16               # 并排全链硬帽（validator pellets∈[1,16] 域内）
const VOLLEY_OVERFLOW_GAP_MULT := 1.5          # 弹幕态超 16 帽部分转阵宽 +50% 补偿
const PARALLEL_CAL_CONVERGE_STEP := 0.05       # 平行校准收束点步进（55%→70%，3 层封顶）
const ETERNAL_QUOTA := 240                     # 永存弹同屏配额（R187 §2.4 第 6 条）
const ETERNAL_LIFETIME_MARK := 120.0           # 永存态判定线（ON_SPAWN 反弹赠 20s / 永存 999s）
const QUOTA_SCAN_INTERVAL := 0.5               # 配额扫描节流 s（try_fire 时强制刷新）
const BANK_SHARD_RADIUS := 120.0               # 黄金弹落点弹片邻近索敌半径（同 EF_CRIT_SHARD 口径）

var _volley_left: float = 0.0                  # TH_VOLLEY_STATE 弹幕态剩余 s（0 = 未激活）
var _volley_cd_left: float = 0.0               # 弹幕态散热剩余 s
var _volley_announced: bool = false            # 首发激活播报闸（EventBus + toast 仅一次）
var _eternal_quota_full: bool = false          # 永存弹配额达满（TH_BOUNCE_ETERNAL 断供标记）
var _quota_scan_cd: float = 0.0                # 配额扫描节流倒计时

# R187 共享组弹体染色的鸭子查询位（projectile_base._sync_visual 读
# weapon_ref.get("is_mirror_image")）——弹道武器恒 false（非 W5 镜面）；
# 缺省缺位时共享侧 bool(null) 会触发逐弹运行时报错，此位兜底鸭式契约
var is_mirror_image: bool = false


func setup(p_data: WeaponData, p_player: Node2D, p_deps: Dictionary) -> void:
	super(p_data, p_player, p_deps)
	spin_up_left = _spin_up_time()
	rof_current = 0.0
	_since_fire = 999.0
	_volley_left = 0.0
	_volley_cd_left = 0.0
	_volley_announced = false
	_eternal_quota_full = false
	_quota_scan_cd = 0.0


var _muzzle_flash: Sprite2D = null            # 枪口闪光（R19 打击质感：常驻件显隐零实例化）
var _muzzle_timer: float = 0.0


func _show_muzzle_flash() -> void:
	# 枪口星闪 0.05s（特效质量低档关闭；常驻 Sprite 显隐——零逐发实例化）
	# R191#2 镜面分支：镜面开火改冰晶火花（ice_shard + MirrorImage.TINT 银白/冰青染、
	# 0.09s）——发射口火花是唯一「镜面在开火」读感区分（弹体侧曳光判定先于镜面旗标，
	# 读感同源）；常驻 Sprite 显隐复用零新实例，禁走粒子池（全池共享敌向材质、发射器
	# 帽 64，镜面群发必挤兑战斗粒子）。本体星闪原样。
	if _muzzle_flash == null:
		_muzzle_flash = Sprite2D.new()
		_muzzle_flash.name = "MuzzleFlash"
		_muzzle_flash.texture = TextureFactory.star(40, PopPalette.XP)
		_muzzle_flash.visible = false
		add_child(_muzzle_flash)
	if clampi(int(Meta.settings("fx_quality")), 0, 2) <= 0:
		return
	_muzzle_flash.position = to_local(muzzle_position())
	_muzzle_flash.rotation = randf() * TAU
	if is_mirror_image:
		_muzzle_flash.texture = TextureFactory.ice_shard()
		_muzzle_flash.modulate = MirrorImage.TINT
		_muzzle_flash.scale = Vector2.ONE * randf_range(0.5, 0.8)
		_muzzle_timer = 0.09
	else:
		_muzzle_flash.scale = Vector2.ONE * randf_range(0.45, 0.75)
		_muzzle_timer = 0.05
	_muzzle_flash.visible = true


func muzzle_position() -> Vector2:
	# R25 发射口对齐：子弹从对应悬浮化身位置出膛（视觉发射口=武器）
	return _avatar_muzzle()


func try_fire() -> bool:
	# N=pellets 发 × 散射锥均匀分布 → ProjectilePool.acquire（软上限池侧拒绝）
	# R187 编队：并排横向偏移（position 侧）+ 收束初速矢量；无编队键的变体走原锥形路径
	if data == null or projectile_pool == null:
		return false
	_maybe_enter_volley()                         # TH_VOLLEY_STATE 发射驱动触发检查
	_refresh_eternal_quota()                      # 永存弹配额刷新（断供判定先行）
	var pellets := _volley_pellet_count()
	var speed := _projectile_speed()   # AFF_PROJ_SPD 弹速池消费在 _projectile_speed 内（勿二次叠乘）
	var size_mult := _proj_size_mult()                    # AFF_AREA 体积池（死卡接线）
	var formation := _formation_enabled()
	# R196 FIX-1 时序上移：gap/converge 原在共享 jitter 判定之后取值——有效编队判定
	# 依赖二值，取值上移先于 jitter（类型化 := 赋值时序：先取值后判定）
	var gap := _lateral_gap() * _volley_gap_mult()
	var converge := _converge_pct()
	# R196 FIX-1 有效编队判定（RC1 主修）：编队键在册 ∧（有效阵宽>0 ∨ 有效收束>0）。
	# 原门只判键在册——W1 L1/L2 lateral_gap_levels/converge_pct_levels 全 0 时编队路
	# 退化：全丸共享同一次 jitter、offset=gap×位差=0、且跳过 _spread_angle 锥形分布
	# → N 弹同点同速像素重合（多重装填实发 2/4 弹探针 max_dist=0.0000px 复现，
	# 「多重装填没生效还是单发」直接根因）。退化时回落原逐丸锥形路径（弹丸按锥角
	# 均布，多重装填弹丸可见）。阵宽乘区 _volley_gap_mult∈{1.0,1.5} 恒正——
	# gap>0 ⟺ _lateral_gap()>0，判定等价；_formation_enabled 本体不动
	#（REL_ECHO 回响防绕门约束）。
	var formation_active := formation and (gap > 0.0 or converge > 0.0)
	# 编队微散射：并排编队全丸共享同一抖动角（同拍同向——编队几何全程确定性，验收②；
	# 单丸/非编队变体/编队退化回落保持原逐丸随机抖动）
	var volley_jitter := 0.0
	if formation_active and pellets > 1:
		volley_jitter = randf_range(-deg_to_rad(_spread_deg()), deg_to_rad(_spread_deg()))
	var aim_dir := aim_direction().rotated(volley_jitter)
	var perp := aim_dir.orthogonal()
	var corridor := _corridor_active()
	var bank_armed := _bank_shot_armed()
	var bounce_amp := _bounce_amp()
	var dir := aim_dir
	var fired := 0
	for i in range(pellets):
		var proj := projectile_pool.acquire() as ProjectileBase
		if proj == null:
			DebugStats.count(&"w1_spawn_dropped")   # 池满丢弃计数（AC-14.4 拒收率审计口）
			break                             # 池满：后续丸丢弃（AC-14.4）
		_inject_projectile_deps(proj)
		var offset := 0.0
		if formation and pellets > 1:
			offset = gap * (float(i) - float(pellets - 1) * 0.5)
		var spawn_pos := muzzle_position() + perp * offset
		var shot_dir := aim_dir
		if formation and converge > 0.0 and absf(offset) > 0.01:
			# 收束几何（55% 射程落线）：外偏弹初速指「瞄准线上 converge×射程 处焦点」
			# ——直线飞行即收束。弹侧 steer 通道（_apply_converge_steer）对
			# converge_authored 弹让位（双通道叠加会在收束点过冲翻到镜像侧——
			# ⑤ 上限阀 30s soak 的活弹构成按本几何标定，评审 R8 键名死路已修：
			# lateral_offset 全量入弹，走廊镜像 / 非授权收束场景由弹侧通道执行）
			var focal := muzzle_position() + aim_dir * (_range() * converge)
			var to_focal := focal - spawn_pos
			if to_focal.length_squared() > 1.0:
				shot_dir = to_focal.normalized()
		var angle := 0.0
		if not formation_active or pellets <= 1:
			angle = _spread_angle(i, pellets)   # R196 FIX-1：编队退化/非编队回落原锥形逐丸分布（单丸=锥内随机抖动）
		var range_left := _range()
		# G4 回旋刃：出程减速 + 回程返航由弹体自身接管——寿命走固定 3.2s 兜底
		#（常规弹 range/speed×1.5 会在回程中途过期截断双程伤害）
		var is_boom := bool(data.ballistic.get("boomerang", false))
		proj.spawn({
			"position": spawn_pos,
			"velocity": shot_dir.rotated(angle) * speed,
			"lifetime": 3.2 if is_boom else maxf(range_left / maxf(speed, 1.0), 0.1) * 1.5,
			"range": range_left,
			"pierce": _pierce_count(),
			"bounces": _bounce_budget(),
			"boomerang": is_boom,
			"hitbox_radius": data.hitbox_r * size_mult,
			"element": _shot_element(),
			"attach_value": 0.0,
			"generation": 0,
			"weapon_uid": uid,
			"weapon_ref": self,
			"panel_snapshot": build_panel_snapshot(),
			"trait_stack": trait_stack.copy_runtime() if trait_stack != null else null,
			"team": 0,
			# ── R187 编队/跳弹扩展键（弹体侧共享通道消费；缺省中性值对其他变体零影响） ──
			"lateral_offset": offset,            # 出膛横向偏移（回廊 offset 镜像基准）
			"converge_pct": converge,            # 收束点（0 = 不收束）
			"converge_authored": formation and converge > 0.0 and absf(offset) > 0.01,
			"bounce_amp": bounce_amp,            # 每跳增伤（命中时点乘区真源在武器侧）
			"corridor": corridor,                # MEC_RICOCHET_HALL 回廊标记（反弹镜像编队回场）
			"bank_shot": bank_armed,             # TH_BANK_SHOT 在册（金染表现读数）
		})
		fired += 1
	if fired > 0:
		_since_fire = 0.0
		_advance_spin()
		_show_muzzle_flash()
	return fired > 0


func _spread_angle(p_i: int, p_total: int) -> float:
	# 第 i 丸在总锥内的均匀角度（spread_deg 为半锥角 ±；单丸 = 锥内随机抖动）
	var spread := deg_to_rad(_spread_deg())
	if p_total <= 1:
		return randf_range(-spread, spread)
	return -spread + spread * 2.0 * float(p_i) / float(p_total - 1)


func _on_tick_post(p_game_delta: float) -> void:
	# 加特林冷却重置：停射 0.8s → 预热归零（F11 分段第三段）
	_since_fire += p_game_delta
	if _spin_up_time() > 0.0 and _since_fire >= SPIN_COOLDOWN_RESET:
		spin_up_left = _spin_up_time()
	# 枪口闪光自熄（R19 打击质感）
	if _muzzle_timer > 0.0:
		_muzzle_timer = maxf(_muzzle_timer - p_game_delta, 0.0)
		if _muzzle_timer <= 0.0 and _muzzle_flash != null:
			_muzzle_flash.visible = false
	# R187 弹幕态计时推进（激活 → 散热 → 就绪）+ 永存配额节流刷新
	if _volley_left > 0.0:
		_volley_left = maxf(_volley_left - p_game_delta, 0.0)
		if _volley_left <= 0.0:
			var params: Dictionary = _volley_cfg().get("params", {})
			_volley_cd_left = maxf(float(params.get("cooldown_s", 3.0)), 0.0)
	elif _volley_cd_left > 0.0:
		_volley_cd_left = maxf(_volley_cd_left - p_game_delta, 0.0)
	_quota_scan_cd -= p_game_delta
	if _quota_scan_cd <= 0.0:
		_refresh_eternal_quota()


func _fire_interval() -> float:
	# F11：rof × (1+ΣAdd_ROF) clamp 30；加特林 = 冷/热按预热进度插值；
	# 玩家侧射速合成（过载咆哮 × 地图祝福，词缀二期；与基类同口径经 _player_rof_mult）
	# R187：TH_VOLLEY_STATE 弹幕态激活期开火间隔 ×0.8（interval_mult 乘在间隔上
	# 而非 rof 上——×0.8 = 开火加快 25%，与「_fire_interval×0.8」验收口径同式）
	var interval := 1.0 / clampf(_effective_rof() * (1.0 + _add_rof()) * _player_rof_mult(), 0.1, _cap_rof())
	if _volley_left > 0.0:
		interval *= maxf(float(_volley_cfg().get("params", {}).get("interval_mult", 0.8)), 0.1)
	return interval


func _effective_rof() -> float:
	# 加特林冷/热插值（预热进度 0→1：rof → rof_hot）；非加特林 = 表值
	var cold := get_stat(&"rof")
	var hot := _rof_hot()
	if _spin_up_time() <= 0.0 or hot <= 0.0:
		return cold
	var progress := 1.0 - spin_up_left / maxf(_spin_up_time(), 0.01)
	return lerpf(cold, hot, clampf(progress, 0.0, 1.0))


func _advance_spin() -> void:
	# 开火推进预热（预热→满热）
	if _spin_up_time() > 0.0:
		spin_up_left = maxf(spin_up_left - _fire_interval(), 0.0)


func _add_rof() -> float:
	# ΣAdd_ROF（F3 衰减聚合，TraitStack.aggregate_panel）
	if trait_stack == null:
		return 0.0
	return float(trait_stack.aggregate_panel().get("add_rof", 0.0))


func _pellet_count() -> int:
	# pellets = L 表值 + Add_Pellets 线性层（A3 §4.2：多重装填 +1 共享散射锥）
	var extra := 0
	if trait_stack != null:
		extra = int(round(float(trait_stack.aggregate_panel().get("add_pellets", 0.0))))
	return maxi(int(get_stat(&"pellets")) + extra, 1)


func _pierce_count() -> int:
	# pierce = L 表值 + Add_Pierce 线性层（穿透弹头 +1）
	var extra := 0
	if trait_stack != null:
		extra = int(round(float(trait_stack.aggregate_panel().get("add_pierce", 0.0))))
	return maxi(int(get_stat(&"pierce")) + extra, 0)


func _projectile_speed() -> float:
	# proj_speed × (1+ΣAdd_Spd)（弹道加速 +18%）
	var mult := 0.0
	if trait_stack != null:
		mult = float(trait_stack.aggregate_panel().get("add_spd", 0.0))
	return float(data.ballistic.get("proj_speed", 620.0)) * (1.0 + mult)


func _range() -> float:
	return maxf(float(data.ballistic.get("range", 680.0)), 10.0)


func _spread_deg() -> float:
	# 半锥角（A3 §3.1/§3.2：±2°/±6°；§3.3 霰弹 26° 锥 = ±13°）
	return _leveled_param("spread_deg", float(data.ballistic.get("spread_deg", 2.0)))


func _rof_hot() -> float:
	# 满热射速（加特林变体 >0 生效；L 表递进）
	return _leveled_param("rof_hot", float(data.ballistic.get("rof_hot", 0.0)))


func _spin_up_time() -> float:
	return _leveled_param("spin_up_time", float(data.ballistic.get("spin_up_time", 0.0)))


func _leveled_param(p_key: String, p_default: float) -> float:
	# 逐级形态参数（形态段新增键 <key>_levels: Array[float]——AC-02.1 仅新增键；
	# A3 §3.2/§3.3：加特林 spin_up/rof_hot 与霰弹 L5 锥角随等级变化）
	var levels: Variant = data.ballistic.get(String(p_key) + "_levels", null)
	if levels is Array and level >= 1 and level <= (levels as Array).size():
		return float((levels as Array)[level - 1])
	return p_default


func _inject_projectile_deps(p_proj: ProjectileBase) -> void:
	# 依赖注入（非初始值，不走 spawn 参数字典——契约 §2.7.1 注）
	p_proj.damage_pipeline = damage_pipeline
	p_proj.enemy_grid = enemy_grid
	p_proj.pool = projectile_pool
	p_proj.elemental = elemental


# ── R187 §2.4 W1 并行弹幕 × 跳弹增值（数据驱动消费；无编队键变体全路径零影响） ──

func inject_relic_pools(p_ctx: DamageContext, p_target: Node2D) -> void:
	# 命中时点附加消费（投射物路径唯一调用点 = ProjectileBase._prepare_hit_traits，
	# 先于管线 ⑦ 暴击掷骰——ctx.bounce_count 已在 _build_damage_ctx 落值）：
	# 基类遗物乘区先行，弹道增值段随后（非投射物路径 bounce_count=0 → 附加段全跳过）
	super(p_ctx, p_target)
	if p_ctx == null or p_ctx.bounce_count <= 0:
		return
	_inject_bounce_amp(p_ctx)
	_apply_bank_shot(p_ctx)


func get_threshold(p_threshold_id: StringName) -> Dictionary:
	# 永存弹同屏配额（R187 §2.4 第 6 条）：达满 240 后对 TH_BOUNCE_ETERNAL 断供——
	# EF_BOUNCE._maybe_eternal 在 ON_BOUNCE 期经本查询读不到阈值 → 新弹不再获永续
	# lifetime（既有弹不受影响）；其余阈值原样透传（TH_CRIT_SHARD/TH_VOLLEY_STATE…）
	if p_threshold_id == &"TH_BOUNCE_ETERNAL" and _eternal_quota_full:
		return {}
	return super(p_threshold_id)


func _formation_enabled() -> bool:
	# 编队几何门（纯数据驱动）：ballistic 段在册 lateral_gap_levels 才有编队语义——
	# 加特林/霰弹无此键全路径不变；REL_ECHO 把 MEC_PARALLEL_CAL 回响挂到 W2 时
	# 因 W2 无编队键 add_gap 不生效（验收⑥防回响绕门负例）
	return data != null and data.ballistic.has("lateral_gap_levels")


func _lateral_gap() -> float:
	# 阵宽：L 表 lateral_gap_levels（L3/L5=12 → 2 丸 ±6 / 3 丸 ±12）+ MEC_PARALLEL_CAL 增量
	var gap := _leveled_param("lateral_gap", 0.0)
	if not _formation_enabled() or gap <= 0.0:
		return 0.0
	return gap + _parallel_cal_gap()


func _parallel_cal_gap() -> float:
	# MEC_PARALLEL_CAL「平行校准」：阵宽 +value×层数（白 4px/层，品质梯随 value）
	if not _formation_enabled():
		return 0.0
	return _trait_value_sum(&"MEC_PARALLEL_CAL")


func _converge_pct() -> float:
	# 收束点：L 表 converge_pct_levels（L5=0.55）+ MEC_PARALLEL_CAL 每层 +5%（55%→70%）
	var pct := _leveled_param("converge_pct", 0.0)
	if not _formation_enabled() or pct <= 0.0:
		return 0.0
	return minf(pct + PARALLEL_CAL_CONVERGE_STEP * float(_trait_layers(&"MEC_PARALLEL_CAL")), 0.9)


func _corridor_active() -> bool:
	# MEC_RICOCHET_HALL「回廊弹幕」：反弹后 offset 镜像保持编队回场（执行在弹体侧
	# 共享通道）——武器侧只传 corridor 标记 + lateral_offset 基准（编队门内生效）
	return _formation_enabled() and _trait_layers(&"MEC_RICOCHET_HALL") > 0


func _bounce_budget() -> int:
	# 跳弹增值轴：反弹预算改读 L 表（原硬编码 0）；validator 域 [0,5]
	return clampi(int(round(_leveled_param("bounce", 0.0))), 0, 5)


func _bounce_amp() -> float:
	# 跳弹增值：每次反弹后命中伤害 +12%（加算乘区；标量在册时 _levels 同键可逐级覆盖）
	return maxf(_leveled_param("bounce_amp", float(data.ballistic.get("bounce_amp", 0.0))), 0.0)


func _bounce_amp_cap() -> float:
	# 增值加算帽（+100%）
	return maxf(_leveled_param("bounce_amp_cap", float(data.ballistic.get("bounce_amp_cap", 1.0))), 0.0)


func _bank_shot_armed() -> bool:
	return not get_threshold(&"TH_BANK_SHOT").is_empty()


func _inject_bounce_amp(p_ctx: DamageContext) -> void:
	# 跳弹增值乘区：contrib = bounce_count × amp（加算，帽 +100%）——与 SYN_BOUNCE_SPEC/
	# REL_MOMENTUM 同走 mult_pools 名额/钳制（增值链整体仍受 cap_prod 8.0 截断）
	var amp := _bounce_amp()
	if amp <= 0.0:
		return
	var contrib := minf(float(p_ctx.bounce_count) * amp, _bounce_amp_cap())
	if contrib <= 0.0:
		return
	p_ctx.mult_pools.append({
		"pool_id": &"bounce_amp",
		"source_uid": 0,
		"contrib": contrib,
		"cap_pool": _bounce_amp_cap(),
		"priority": 0,
	})


func _apply_bank_shot(p_ctx: DamageContext) -> void:
	# TH_BANK_SHOT「黄金弹」：单弹累计反弹 ≥ threshold(12) 升格——本次命中必暴
	#（管线 _roll_crit chance≥1 短路真值）+ 落点弹片（邻近单体 0.5×暴伤，同
	# EF_CRIT_SHARD 结算通道：真件管线 9b 内部落血）
	var t := get_threshold(&"TH_BANK_SHOT")
	if t.is_empty():
		return
	if float(p_ctx.bounce_count) < float(t.get("threshold", 12.0)):
		return
	p_ctx.crit_chance = 1.0
	DebugStats.count(&"bank_shot_gold")
	var params: Dictionary = t.get("params", {})
	var target := _bank_shard_target(p_ctx)
	if target == null or damage_pipeline == null or not damage_pipeline.has_method(&"resolve"):
		return
	var ctx := DamageContext.make()
	ctx.source_uid = uid
	ctx.target = target
	ctx.target_uid = int(target.get("uid"))
	ctx.frame_stamp = GameConfig.frame_stamp
	ctx.base_atk = maxf(p_ctx.base_atk * p_ctx.crit_mult * float(params.get("shard_ratio", 0.5)), 0.0)
	ctx.element = GameConst.Element.KIN
	ctx.hit_flags |= GameConst.HIT_IS_AOE_SECONDARY
	ctx.pos = (target as Node2D).global_position
	damage_pipeline.call(&"resolve", ctx)
	DebugStats.count(&"bank_shard_triggered")


func _bank_shard_target(p_ctx: DamageContext) -> Node2D:
	# 落点弹片目标：命中位置邻近最近存活单体（排除直击主目标——弹射语义；确定性）
	if enemy_grid == null:
		return null
	var pos := p_ctx.pos
	var exclude: Node2D = p_ctx.target as Node2D
	var best: Node2D = null
	var best_d := INF
	for cand in enemy_grid.query_circle(pos, BANK_SHARD_RADIUS):
		if cand == null or cand == exclude or bool(cand.get("dead")):
			continue
		var d := pos.distance_squared_to((cand as Node2D).global_position)
		if d < best_d:
			best_d = d
			best = cand
	return best


# ── TH_VOLLEY_STATE 弹幕态（4s 激活 → 3s 散热，占空比自平衡） ─────────

func _volley_cfg() -> Dictionary:
	return get_threshold(&"TH_VOLLEY_STATE")


func _maybe_enter_volley() -> void:
	# 发射驱动触发：并排基础弹数 ≥ threshold(6) 且非激活/散热中 → 进弹幕态；
	# 首发激活派 EventBus（trait_milestone 金色 toast 通道）+ DebugStats 计数
	if _volley_left > 0.0 or _volley_cd_left > 0.0:
		return
	var t := _volley_cfg()
	if t.is_empty():
		return
	if float(_pellet_count()) < float(t.get("threshold", 6.0)):
		return
	var params: Dictionary = t.get("params", {})
	_volley_left = maxf(float(params.get("duration_s", 4.0)), 0.1)
	DebugStats.count(&"volley_state_active")
	if not _volley_announced:
		_volley_announced = true
		EventBus.emit_trait_milestone(&"TH_VOLLEY_STATE", "弹幕形态·并排全开", 0.0)


func _volley_extra_pellets() -> int:
	if _volley_left <= 0.0:
		return 0
	return int(round(float(_volley_cfg().get("params", {}).get("extra_pellets", 2.0))))


func _volley_pellet_count() -> int:
	# 并排弹数 = 基础 + 弹幕态 +2，全链 clamp[1,16]（超帽部分转阵宽补偿，见 _volley_gap_mult）
	return clampi(_pellet_count() + _volley_extra_pellets(), 1, FORMATION_PELLET_CAP)


func _volley_gap_mult() -> float:
	# 弹幕态超帽补偿：基础+加成 > 16 帽 → 阵宽 ×1.5
	if _volley_left <= 0.0:
		return 1.0
	if _pellet_count() + _volley_extra_pellets() > FORMATION_PELLET_CAP:
		return VOLLEY_OVERFLOW_GAP_MULT
	return 1.0


# ── 永存弹同屏配额（240） ─────────────────────────────────────────

func _refresh_eternal_quota() -> void:
	# 统计本武器在场永存弹（lifetime ≥ 判定线 120s；ON_SPAWN 反弹赠仅 20s 不误判），
	# 达配额 → _eternal_quota_full（get_threshold 对 TH_BOUNCE_ETERNAL 断供生效）
	_quota_scan_cd = QUOTA_SCAN_INTERVAL
	_eternal_quota_full = false
	if projectile_pool == null or data == null:
		return
	if get_threshold(&"TH_BOUNCE_ETERNAL").is_empty():
		return
	var live := 0
	for p in projectile_pool.active_projectiles():
		var pb := p as ProjectileBase
		if pb != null and pb.weapon_uid == uid and pb.lifetime_left >= ETERNAL_LIFETIME_MARK:
			live += 1
	_eternal_quota_full = live >= ETERNAL_QUOTA


# ── 挂载表查询（同 id 聚合；先判有效再赋值） ───────────────────────

func _trait_layers(p_id: StringName) -> int:
	if trait_stack == null:
		return 0
	var layers := 0
	for tb in trait_stack.traits:
		if tb == null or tb.data == null or tb.data.id != p_id:
			continue
		layers += tb.layers
	return layers


func _trait_value_sum(p_id: StringName) -> float:
	# 同 id 词条 value×层数 求和（品质梯随 value——金卡 value 已按稀有度缩放落卡）
	if trait_stack == null:
		return 0.0
	var total := 0.0
	for tb in trait_stack.traits:
		if tb == null or tb.data == null or tb.data.id != p_id:
			continue
		total += float(tb.data.value) * float(tb.layers)
	return total
