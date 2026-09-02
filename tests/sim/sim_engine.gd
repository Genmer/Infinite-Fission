# tests/sim/sim_engine.gd
# v1.5.0 TTK 复校工装（A14）：帧循环引擎（单敌封闭；帧序镜像 game_loop:130-208 PLAYING 子集）。
# · run_cell：advance_frame → pipeline.begin_frame → 逐武器 SimWeaponDriver.tick（玩家静止，
#   无投射物飞行——弹丸直达）→ grid.rebuild → enemy.tick → elemental.tick → detect_reactions
#   → pipeline.end_frame → EventBus.end_frame；enemy.dead 即止；TIME_CAP_S 未杀 → NTK(-1)。
#   NTK 早退守卫（A14 §假设）：≥5s 瞬态期后每 5s 采样一次，累计 DPS 投影 finish>1.5×帽
#   且剩余血量>50% → 提前判 NTK——三条件合取下真实 finish>180s 必然 NTK，击杀格永不触发，
#   判定语义逐位保持（≤300s 跑批墙钟预算的实现手段）。
# · hit：直击时序复刻（母本 projectile_base:238-409，行号入注释）——
#   ① uid=next_uid() 每丸独立（:251 命中序数口径）
#   ② ctx 从 build_panel_snapshot 展开（:303-346 同构：base/flat/crit/add_entries/
#      chip_entries>0 才入/element/FIR|ICE→amplify 池 :325-334/target_resist）
#   ③ collect_mult_pools + inject_vuln_pool + ON_HIT dispatch（:265-282 同构）
#   ④ pipeline.resolve
#   ⑤ 非 killed → consume_amplify（:377）
#   ⑥ attach_request → apply_attach（:387-409；弹载荷 attach_value 恒 0——sim 无 ON_SPAWN 期）
# · SimWeaponDriver：镜像 WeaponBase.tick 节拍（不调 try_fire——避免真投射物池依赖）：
#   trait_stack.advance_cooldowns → cooldown 到期发 _pellet_count 丸（逐丸 hit）→
#   _advance_spin → _since_fire=0 → cooldown=_fire_interval()——全部调武器自身方法
#   不重算公式（加特林冷热/芯片 rof/面板缓存全走真路径）。
class_name SimEngine
extends RefCounted

const DT := 1.0 / 120.0                       # 120Hz 逻辑帧
const TIME_CAP_S := 120                       # 单 cell 墙钟上限（超时 NTK）
const U_DESIGN := 0.85                        # 设计 U 值（A14 判定基准线）
const FRAME_CAP: int = TIME_CAP_S * 120       # 14400 帧
const NTK_PROBE_FRAME := 600                  # NTK 早退采样相位（5s 瞬态期后；每 600 帧一查）

static var _probe: Node = null                # 结算计数探针（pkg1 Node 订阅纪律——E-12 拦非 Node）


static func run_cell(p_env: SimEnv, p_weapons: Array[WeaponBase], p_wave: int,
		p_kind: String, p_seed: int) -> Dictionary:
	# 单 cell：装配敌 → 帧循环 → {ttk_frames, shield_break_frames, hp_total, dps,
	# t_clear_est, n_hits, n_crit}
	p_env.reset_for_cell(p_seed)
	var enemy := SimEnemy.spawn(p_env, p_kind, p_wave)
	if enemy == null:
		return _result(-1, -1, 0.0)
	var hp_total := float(enemy.max_hp + enemy.shield_max)   # EHP 口径（归还前快照）
	var probe := _probe_node()
	probe.set("hits", 0)
	probe.set("crits", 0)
	var drivers: Array[SimWeaponDriver] = []
	for w in p_weapons:
		if w != null and is_instance_valid(w):
			drivers.append(SimWeaponDriver.new(w, p_env))
	var shield_was := enemy.shield_active()
	var shield_break := -1
	var ttk := -1
	var f := 0
	var hp_done_max := 0.0                            # 累计伤害（NTK 早退投影分母）
	while f < FRAME_CAP:
		GameConfig.advance_frame()                # 帧序 0：帧号推进（幂等键时钟）
		p_env.pipeline.begin_frame()              # 帧序 0：幂等缓存清空
		# 帧序② 武器开火（玩家静止——player.tick 的武器调度由 driver 承担）
		for driver in drivers:
			driver.tick(DT)
			if enemy.dead:
				break
		if enemy.dead:
			ttk = f                               # 死亡帧即 TTK（0 计）
			p_env.pipeline.end_frame()
			EventBus.end_frame()
			break
		# 帧序④ 网格重建（sim 无投射物阶段——单敌快照确定性口径）
		var roster: Array[Node2D] = [enemy]
		p_env.grid.rebuild(roster)
		# 帧序⑤ 敌 AI + 元素 tick + 帧末反应检测（E-07）
		enemy.tick(DT)
		p_env.elemental.tick(DT)
		p_env.elemental.detect_reactions()
		p_env.pipeline.end_frame()
		EventBus.end_frame()                      # 事件风暴计数清零（§六.4）
		f += 1
		if shield_break < 0 and shield_was and not enemy.shield_active():
			shield_break = f                      # 盾破帧（观测口口径）
		shield_was = enemy.shield_active()
		# NTK 早退守卫（≤300s 墙钟预算；判定语义保持——三条件合取下 finish>1.5×帽，
		# 必然 NTK：击杀格 ttk≤120s 永不触发；1.5× 安全系数吸收 DPS 爬坡误判，
		# 瞬态期（<5s：加特林预热/熔融平衡/暴击稳态）不采样。A14 §假设留痕）
		if f >= NTK_PROBE_FRAME and (f % NTK_PROBE_FRAME) == 0:
			var done := hp_total - (enemy.hp + enemy.shield_hp)
			if done > hp_done_max:
				hp_done_max = done
			var dps_avg := hp_done_max / (float(f) * DT)
			var remaining := enemy.hp + enemy.shield_hp
			if dps_avg <= 0.000001:
				ttk = -1                          # 零伤害 → 必然 NTK
				p_env.pipeline.end_frame()
				EventBus.end_frame()
				break
			if remaining > 0.5 * hp_total \
					and float(f) * DT + remaining / dps_avg > 1.5 * float(TIME_CAP_S):
				ttk = -1
				p_env.pipeline.end_frame()
				EventBus.end_frame()
				break
	SimEnemy.release(p_env, enemy)
	if ttk < 0:
		return _result(-1, shield_break, hp_total)
	return {
		"ttk_frames": ttk,
		"shield_break_frames": shield_break,
		"hp_total": hp_total,
		"dps": hp_total / maxf(float(ttk) * DT, DT),   # ttk=0（首帧击杀）除零钳 DT
		"t_clear_est": float(ttk) * DT,
		"n_hits": int(probe.get("hits")),
		"n_crit": int(probe.get("crits")),
	}


static func hit(p_env: SimEnv, p_weapon: WeaponBase, p_element: int, p_pellet_idx: int,
		p_target: Node2D) -> DamageResult:
	# 直击时序复刻（母本 projectile_base._submit_hit:238-262 + _build_damage_ctx:303-346 +
	# _prepare_hit_traits:265-282 + _on_settled:368-384 + _apply_elemental:387-409）
	if p_target == null or bool(p_target.get("dead")):
		return null                               # E-06 死亡短路（入口位）
	var uid := GameConst.next_uid()               # ① 每丸独立 uid（source_uid 幂等键分流）
	var ctx := _build_ctx(p_env, p_weapon, uid, p_element, p_target, p_pellet_idx)   # ②
	# ③ 乘区预聚合 + 易伤 + ON_HIT 派发（挂载序）
	var tctx := TraitContext.new()
	tctx.event = GameConst.TraitEvent.ON_HIT
	tctx.projectile = null
	tctx.beam = null
	tctx.melee = null
	tctx.weapon = p_weapon
	tctx.target = p_target
	tctx.damage_ctx = ctx
	p_weapon.inject_relic_pools(ctx, p_target)    # 遗物问询通道（sim 无遗物 → no-op 口径一致）
	if p_weapon.trait_stack != null:
		for pool in p_weapon.trait_stack.collect_mult_pools(tctx):
			ctx.mult_pools.append(pool)
		_inject_vuln_pool(ctx, p_target)
		p_weapon.trait_stack.dispatch(GameConst.TraitEvent.ON_HIT, tctx)
	# ④ 管线九步（真件 resolve 内部落血 9b——take_result 唯一执行点）
	var result: DamageResult = p_env.pipeline.resolve(ctx)
	if result == null:
		return null
	# ⑤ 非 killed → consume_amplify（:377——结算成功且目标未 dead）
	if not result.killed:
		p_env.elemental.consume_amplify(p_target, p_element)
	# ⑥ 元素附着（:387-409 同构；弹载荷 attach_value 恒 0——附着全走 ELE 词条 attach_request）
	if tctx != null and not tctx.attach_request.is_empty():
		var request: Dictionary = tctx.attach_request
		p_env.elemental.apply_attach(p_target, int(request.get("element", GameConst.Element.KIN)),
			float(request.get("value", 0.0)), {
				"snapshot": result.panel_snapshot,
				"hit_damage": result.final_value,
				"overrides": request.get("overrides", {}),
			})
	return result


static func weapon_element(p_weapon: WeaponBase) -> int:
	# 武器元素归属（ElementalSystem._weapon_element 同构：ELEM 词条 params.element
	# 中层数最高者，tie 后挂胜；无 → KIN）
	if p_weapon == null or not is_instance_valid(p_weapon) or p_weapon.trait_stack == null:
		return GameConst.Element.KIN
	var best := GameConst.Element.KIN
	var best_layers := 0
	for mounted in p_weapon.trait_stack.traits:
		var data: TraitData = (mounted as TraitBase).data
		if data == null or data.pool != GameConst.PoolClass.ELEM:
			continue
		var el: Variant = data.params.get("element", null)
		if not (el is int):
			continue
		var element := int(el)
		if element < GameConst.Element.FIR or element > GameConst.Element.WAT:
			continue
		if (mounted as TraitBase).layers >= best_layers:
			best = element
			best_layers = (mounted as TraitBase).layers
	return best


# ── 内部 ──────────────────────────────────────────────────────────
static func _probe_node() -> Node:
	# 结算计数探针（pkg1 Node 订阅纪律：E-12 拦非 Node 订阅者——RefCounted/lambda 恒被拦）；
	# 脚本缓存编译一次，连接常驻（process 退出即回收）
	if _probe == null or not is_instance_valid(_probe):
		var s := GDScript.new()
		s.source_code = "extends Node\n" \
			+ "var hits: int = 0\n" \
			+ "var crits: int = 0\n" \
			+ "func on_resolved(r: DamageResult) -> void:\n" \
			+ "\thits += 1\n" \
			+ "\tif r.is_crit:\n\t\tcrits += 1\n"
		s.reload()
		_probe = Node.new()
		_probe.name = "SimDamageProbe"
		_probe.set_script(s)
		(Engine.get_main_loop() as SceneTree).get_root().add_child(_probe)
		EventBus.damage_resolved.connect(Callable(_probe, "on_resolved"))
	return _probe


static func _build_ctx(p_env: SimEnv, p_weapon: WeaponBase, p_uid: int, p_element: int,
		p_target: Node2D, p_pellet_idx: int) -> DamageContext:
	# projectile_base._build_damage_ctx:303-346 同构（build_panel_snapshot 展开口径）
	var snap := p_weapon.build_panel_snapshot()
	var ctx := DamageContext.make()
	ctx.source_uid = p_uid
	ctx.target = p_target
	ctx.target_uid = int(p_target.get("uid"))
	ctx.frame_stamp = GameConfig.frame_stamp
	ctx.base_atk = float(snap.get("base_atk", 0.0))
	ctx.flat_bonus = float(snap.get("flat_bonus", 0.0))
	ctx.crit_chance = float(snap.get("crit_rate", 0.0))
	ctx.crit_mult = float(snap.get("crit_mult", 2.0))
	var adds: Variant = snap.get("add_entries", [])
	if adds is Array and not (adds as Array).is_empty():
		for entry in adds:
			ctx.add_entries.append(entry)         # 逐项入列（:317 同口径）
	# 芯片 ATK% 独立乘区段（:319-321——>0 才入列，零芯片零开销）
	var chip_pct := float(snap.get("chip_atk_pct", 0.0))
	if chip_pct > 0.0:
		ctx.chip_entries.append({"stat": &"atk_pct", "contrib": chip_pct})
	ctx.element = p_element
	# 增幅双轨（:325-334——FIR/ICE 直击且目标带反向附着 → amplify 乘区池注入）
	if p_env.elemental != null and (p_element == GameConst.Element.FIR
			or p_element == GameConst.Element.ICE):
		var amp := p_env.elemental.try_amplify_factor(p_target, p_element)
		if amp > 1.0:
			ctx.mult_pools.append({
				"pool_id": &"amplify",
				"source_uid": p_uid,
				"contrib": amp - 1.0,
				"cap_pool": amp - 1.0,
				"priority": 0,
			})
	ctx.hit_flags = GameConst.HIT_AFTER_PIERCE    # :356-365——首命中序数 _pierce_hits=1 口径
	ctx.bounce_count = 0
	ctx.pierce_index = 2                          # :339（_pierce_hits + 1，首命中）
	ctx.generation = 0
	ctx.is_first_hit_of_wave = false              # wave_director null → :349-353 安全回退
	ctx.player_hp_pct = _player_hp_pct(p_env)
	ctx.pos = (p_target as Node2D).global_position
	if p_target.has_method(&"get_resist"):
		ctx.target_resist = float(p_target.call(&"get_resist", p_element))   # :336-337
	return ctx


static func _inject_vuln_pool(p_ctx: DamageContext, p_target: Node2D) -> void:
	# projectile_base._inject_vuln_pool:285-300 同构（has_mult_pool 去重 + 冰冻易伤池）
	if p_target == null or WeaponBase.has_mult_pool(p_ctx, &"vuln"):
		return
	var state: Variant = p_target.get("elemental")
	if state is ElementalState:
		var factor := (state as ElementalState).get_vuln_factor()
		if factor > 1.0:
			p_ctx.mult_pools.append({
				"pool_id": &"vuln",
				"source_uid": 0,
				"contrib": factor - 1.0,
				"cap_pool": factor - 1.0,
				"priority": 0,
			})


static func _player_hp_pct(p_env: SimEnv) -> float:
	# 背水协议条件（projectile_base._player_hp_pct:647-652 同构）
	if p_env.player != null and is_instance_valid(p_env.player):
		return p_env.player.get_hp_pct()
	return 1.0


static func _result(p_ttk: int, p_shield_break: int, p_hp_total: float) -> Dictionary:
	# NTK 统一出口（dps/t_clear_est 无意义占位 -1/0）
	return {
		"ttk_frames": p_ttk,
		"shield_break_frames": p_shield_break,
		"hp_total": p_hp_total,
		"dps": 0.0,
		"t_clear_est": -1.0,
		"n_hits": 0,
		"n_crit": 0,
	}


# ── 内部类：武器节拍驱动器（WeaponBase.tick 无 try_fire 镜像） ──────────
class SimWeaponDriver:
	extends RefCounted

	# T1~T7b 模板全弹道（BALLISTIC）——驱动器按 BallisticWeapon 静态收窄
	#（_pellet_count/_advance_spin/_since_fire 为 BallisticWeapon 成员）
	var weapon: BallisticWeapon = null
	var _env: SimEnv = null                       # hit 提交环境 + 目标宿主（host()）

	func _init(p_weapon: WeaponBase, p_env: SimEnv) -> void:
		weapon = p_weapon as BallisticWeapon
		_env = p_env
		if weapon == null:
			push_error("[SimEngine] 仅支持 BALLISTIC 形态驱动（T1~T7b 全弹道口径）")
			assert(p_weapon == null)

	func tick(p_game_delta: float) -> void:
		# WeaponBase.tick:55-66 节拍镜像：词条冷却 → 冷却推进 → 到期发弹 → 后处理钩子
		if weapon == null or not is_instance_valid(weapon) or weapon.data == null:
			return
		if weapon.trait_stack != null:
			weapon.trait_stack.advance_cooldowns(p_game_delta)
		if weapon.cooldown_left > 0.0:
			weapon.cooldown_left = maxf(weapon.cooldown_left - p_game_delta, 0.0)
		else:
			_fire_pellets()
			weapon._advance_spin()                # 加特林预热推进（内部再调 _fire_interval）
			weapon._since_fire = 0.0              # 停射冷却重置判据（BallisticWeapon 口径）
			weapon.cooldown_left = weapon._fire_interval()   # 节拍唯一真源（不重算公式）
		weapon._on_tick_post(p_game_delta)        # 加特林停射计时推进（_since_fire += dt）

	func _fire_pellets() -> void:
		# BallisticWeapon.try_fire 的直达镜像：_pellet_count 丸逐丸 hit（无散射 RNG——
		# 单敌封闭口径，A14 §2 假设留痕：散布角不进 TTK）
		var target := _env.host()
		if target == null:
			return
		var pellets := weapon._pellet_count()
		var element := SimEngine.weapon_element(weapon)
		for i in range(pellets):
			if bool(target.get("dead")):
				return
			SimEngine.hit(_env, weapon, element, i, target)
