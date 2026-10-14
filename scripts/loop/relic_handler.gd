# scripts/loop/relic_handler.gd
# 集成包 B.2：遗物运行时效果处理器（11 遗物 listen_events 分发执行；效果语义真源 A3 §5）。
# · 激活：CardGenerator.apply_choice 选出遗物卡 → EventBus.card_chosen(kind=RELIC) →
#   activate(id)（每场唯一 unique；owned 入列 + 常驻位生效 + EventBus 事件绑定）。
# · 分发契约：事件回调统一按「owned 且该遗物 listen_events 含本事件」守卫（listen_events
#   即 DataValidator 校验过的 EventBus 真信号名）——语义与 .tres 声明一致。
# · 命中时点乘区（REL_BOSS_TROPHY / REL_MOMENTUM）：伤害在管线内已定，无法事后修正——
#   由武器/投射物侧在 ctx 构建期经 inject_hit_mult_pools() 问询注入独立乘区池
#   （A2 §1.8 vuln 同路径）；damage_resolved 订阅仅承担遥测计数（pool_breakdown 反查）。
# · 占位（A3 §6.5 商店本期不做）：REL_BLACK_MARKET 仅排程计数 pending_shop_waves。
class_name RelicHandler
extends Node

var registry: DataRegistry = null             # 注入（relic id → RelicData）
var player: Node2D = null                     # 注入（治疗/复活/冷却重置宿主）
var rng: RandomNumberGenerator = RandomNumberGenerator.new()   # 概率掷骰（测试可注种子）

var owned: Array[RelicData] = []              # 本局已激活遗物（unique 每场唯一）
# ── 常驻位（activate 时按 effect_id 生效） ──
var xp_mult_factor: float = 1.0               # REL_MIDAS：经验倍率（掉落侧折算）
var extra_deal_cards: int = 0                 # REL_GAMBLER：三选一 → 四选一（+1）
var curse_last_card: bool = false             # REL_GAMBLER：第 4 张必带诅咒
var death_cheat_uses: int = 0                 # REL_PHOENIX：致死保留 1 HP 剩余次数
# ── 波内/排程位 ──
var reroll_pending: bool = false              # REL_WORDS_TIDE：本波卡货架重随申请
var rarity_floor_next: int = -1               # REL_OVERCLOCK：下一张卡稀有度保底（<0 无）
var elite_kill_done_this_wave: bool = false   # REL_OVERCLOCK：本波精英首杀已发生
var pending_shop_waves: int = 0               # REL_BLACK_MARKET：商店波排程计数（占位）
# ── 遥测（测试观测口） ──
var phoenix_triggered: int = 0
var crit_chain_resets: int = 0
var _crit_chain_cd_left: float = 0.0            # R66 暴击谐振内部冷却剩余（30s 一触发）
# ── R186 每击谐振（REL_ATTACK_CDR：开火口径计费 + 每秒预算封顶） ──
var attack_cdr_credits: int = 0                # 计费击数遥测（测试观测口）
var attack_cdr_seconds: float = 0.0            # 累计直减秒数遥测
var _atk_cdr_budget: float = 0.0               # 计费预算存款（1 信用 = cd_per_attack；activate 拉满）
var _frenzy_stacks: int = 0                    # R72 连杀狂热层数（击杀叠层，窗口衰减）
var _frenzy_left: float = 0.0                  # 狂热窗口剩余
var _thorns_cd_left: float = 0.0               # R72 荆棘王座反击内冷
var _lifesteal_cd_left: float = 0.0            # R72 汲血刻印回复内冷
var echo_copies: int = 0
var elite_dmg_hits: int = 0                   # pool_breakdown 含 elite_dmg 的结算数
var momentum_hits: int = 0                    # pool_breakdown 含 bounce_dmg 的结算数
# ── R252 遗物扩容新增运行态（16 件——层/窗口/uid 记忆/波内有效位） ──
var _pyre_cd_left: float = 0.0                 # REL_PYRE 尸爆内冷剩余
var _faultless_stacks: int = 0                 # REL_FAULTLESS_CHAIN 无瑕层数（受击清零）
var _elite_window_left: float = 0.0            # REL_ELITE_WINDOW 猎杀时刻窗口剩余
var _mark_target_iid: int = 0                  # REL_FOCUS_MARK 同目标记忆（instance id——
                                               # 池化 Enemy.uid 会复用，instance id 不复用）
var _mark_steps: int = 0                       # REL_FOCUS_MARK 连续命中层数
var _resonant_stacks: int = 0                  # REL_RESONANT_TOUCH 反应叠层（窗口到期清零）
var _resonant_left: float = 0.0                # REL_RESONANT_TOUCH 窗口剩余
var _tithe_paid_wave: bool = false             # REL_BLOOD_TITHE 本波已付费（波内有效位）
# ── R253 防御/控制向六件运行态（霜寒守卫内冷 / 金钟罩节拍 / 减伤维护） ──
var _frost_ward_cd_left: float = 0.0           # REL_FROST_WARD 受击寒波内冷剩余
var _aegis_clock_left: float = 0.0             # REL_AEGIS_CLOCK 下次自动授盾倒计时（<0=未持）
var _uid_target_refs: Dictionary = {}          # Enemy.uid → 实体引用记忆（GUILLOTINE
                                               # damage_resolved 无 target 载荷，inject 期
                                               # 捕获；容量护栏 32 防池化回绕污染）

var _events_bound: bool = false


func setup(p_deps: Dictionary) -> void:
	# Boot 注入（GameLoop._boot_build_actors：registry/player——先于卡牌流就绪）
	registry = p_deps.get("registry")
	player = p_deps.get("player")
	reset_run()


func reset_run() -> void:
	# 重开清零（GameLoop._reset_run_state 调用；owned 清空 = 遗物每场重新获取）
	owned.clear()
	xp_mult_factor = 1.0
	extra_deal_cards = 0
	curse_last_card = false
	death_cheat_uses = 0
	reroll_pending = false
	rarity_floor_next = -1
	_frenzy_stacks = 0                          # R72 新遗物运行态清零
	_frenzy_left = 0.0
	if player != null and is_instance_valid(player):
		player.set("skill_cd_relic_mult", 1.0)  # R80 时之沙乘区随局清零
	_thorns_cd_left = 0.0
	_lifesteal_cd_left = 0.0
	elite_kill_done_this_wave = false
	pending_shop_waves = 0
	phoenix_triggered = 0
	crit_chain_resets = 0
	_crit_chain_cd_left = 0.0                    # R66：暴击谐振内冷复位
	_atk_cdr_budget = 0.0                        # R186：每击谐振预算存款清零
	attack_cdr_credits = 0                       # R186：计费遥测清零
	attack_cdr_seconds = 0.0
	echo_copies = 0
	elite_dmg_hits = 0
	momentum_hits = 0
	# R252 遗物扩容运行态清零（层/窗口/uid 记忆/波内有效位——死亡重开全清）
	_pyre_cd_left = 0.0
	_faultless_stacks = 0
	_elite_window_left = 0.0
	_mark_target_iid = 0
	_mark_steps = 0
	_resonant_stacks = 0
	_resonant_left = 0.0
	_tithe_paid_wave = false
	# R253 防御/控制向清零（金钟罩负值=未持重臂）
	_frost_ward_cd_left = 0.0
	_aegis_clock_left = 0.0
	if player != null and is_instance_valid(player):
		player.set("relic_dr", 0.0)            # R253 减伤乘区随局清零
	_uid_target_refs.clear()


func has_relic(p_id: StringName) -> bool:
	for data in owned:
		if data.id == p_id:
			return true
	return false


func owned_count() -> int:
	return owned.size()


func activate(p_id: StringName) -> bool:
	# 激活遗物（card_chosen kind=RELIC 通道；重复/悬空 id 拒绝）
	if registry == null:
		return false
	var data := registry.get_relic(p_id)
	if data == null or has_relic(p_id):
		return false
	owned.append(data)
	bind_events()
	_apply_passive(data)
	DebugStats.count(&"relic_activated")
	return true


# ── 查询接口（GameLoop 卡牌流 / 掉落侧；武器侧乘区问询） ──────────
func xp_mult() -> float:
	# REL_MIDAS：经验获取倍率（GameLoop 掉落侧折算——碎片面值即最终入账值）
	return xp_mult_factor


func deal_count() -> int:
	# REL_GAMBLER：发牌数（三选一 3 / 四选一 4）
	return 3 + extra_deal_cards


func curse_requested() -> bool:
	# REL_GAMBLER：末位卡必带诅咒（A3 §5；诅咒净化 A3 §9.3-10 占位）
	return curse_last_card


func consume_reroll() -> bool:
	# REL_WORDS_TIDE：消费本波货架重随申请（每波一次）
	var pending := reroll_pending
	reroll_pending = false
	return pending


func take_rarity_floor() -> int:
	# REL_OVERCLOCK：消费下一张卡稀有度保底（无 → -1）
	var floor_value := rarity_floor_next
	rarity_floor_next = -1
	return floor_value


func bounce_momentum_bonus(p_bounce_count: int) -> float:
	# REL_MOMENTUM：反弹层数伤害加成（+8%×层，上限 10 层；A3 §5 / A2 §1.8 bounce_dmg 区）
	var data := _owned_effect(&"REL_EF_BOUNCE_MOMENTUM")
	if data == null or p_bounce_count <= 0:
		return 0.0
	var layers := mini(p_bounce_count, int(data.params.get("max_layers", 10)))
	return float(data.params.get("per_bounce_pct", 0.0)) * float(layers)


func elite_dmg_bonus(p_target: Node2D) -> float:
	# REL_BOSS_TROPHY：对精英/Boss 独立乘区（×1.25 → contrib 0.25；tags 由 .tres params 驱动）
	var data := _owned_effect(&"REL_EF_ELITE_DMG")
	if data == null or p_target == null:
		return 0.0
	var mask := 0
	var tag_list: Variant = data.params.get("tags", [])
	if tag_list is Array:
		for t in (tag_list as Array):
			mask |= int(t)
	if mask == 0 or (int(p_target.get("tags")) & mask) == 0:
		return 0.0
	return float(data.params.get("mult", 1.0)) - 1.0


func inject_hit_mult_pools(p_ctx: DamageContext, p_target: Node2D) -> void:
	# 命中时点独立乘区注入（WeaponBase/ProjectileBase ctx 构建期调用；A2 §1.8 独立乘区路径）
	if p_ctx == null:
		return
	var elite_data := _owned_effect(&"REL_EF_ELITE_DMG")
	if elite_data != null:
		var contrib := elite_dmg_bonus(p_target)
		if contrib > 0.0:
			var pool_id := StringName(String(elite_data.params.get("pool", "elite_dmg")))
			if not WeaponBase.has_mult_pool(p_ctx, pool_id):
				p_ctx.mult_pools.append({
					"pool_id": pool_id,
					"source_uid": 0,
					"contrib": contrib,
					"cap_pool": contrib,
					"priority": 0,
				})
	# R72 新乘区遗物注入（frenzy 狂热 / double_tap 双发 / glass 玻璃大炮）
	var frenzy_data := _owned_effect(&"REL_EF_KILL_FRENZY")
	if frenzy_data != null:
		var f_contrib := frenzy_dmg_bonus()
		if f_contrib > 0.0:
			p_ctx.mult_pools.append({
				"pool_id": &"frenzy_dmg", "source_uid": 0,
				"contrib": f_contrib, "cap_pool": f_contrib, "priority": 0,
			})
	var tap_data := _owned_effect(&"REL_EF_DOUBLE_TAP")
	if tap_data != null and rng.randf() < float(tap_data.params.get("chance", 0.15)):
		var tap_contrib := float(tap_data.params.get("mult", 1.0))
		p_ctx.mult_pools.append({
			"pool_id": &"double_tap", "source_uid": 0,
			"contrib": tap_contrib, "cap_pool": tap_contrib, "priority": 0,
		})
	var glass_data := _owned_effect(&"REL_EF_GLASS")
	if glass_data != null:
		var g_contrib := float(glass_data.params.get("bonus", 0.4))
		p_ctx.mult_pools.append({
			"pool_id": &"glass_dmg", "source_uid": 0,
			"contrib": g_contrib, "cap_pool": g_contrib, "priority": 0,
		})
	var momentum_data := _owned_effect(&"REL_EF_BOUNCE_MOMENTUM")
	if momentum_data != null:
		var m_contrib := bounce_momentum_bonus(p_ctx.bounce_count)
		if m_contrib > 0.0:
			var m_pool := StringName(String(momentum_data.params.get("pool", "bounce_dmg")))
			if not WeaponBase.has_mult_pool(p_ctx, m_pool):
				p_ctx.mult_pools.append({
					"pool_id": m_pool,
					"source_uid": 0,
					"contrib": m_contrib,
					"cap_pool": m_contrib,
					"priority": 0,
				})
	# ── R252 遗物扩容注入段（贪婪/无瑕/先手/裂颅/猎杀窗/印记/血税）──
	# GUILLOTINE uid 记忆：damage_resolved 载荷无 target 实体，命中时点捕获 uid → 引用
	#（enemy_killed 池化归还后 is_instance_valid/uid 双校验自失效；容量护栏防回绕）
	if p_target is Enemy and is_instance_valid(p_target) and not (p_target as Enemy).dead:
		if _uid_target_refs.size() > 32:
			_uid_target_refs.clear()
		_uid_target_refs[int((p_target as Enemy).uid)] = p_target
	# REL_GREED_MATRIX 贪婪矩阵：每持有 per_gold 金币 +step 伤害（cap_steps 档封顶）
	var greed_data := _owned_effect(&"REL_EF_GREED_GOLD")
	if greed_data != null and player != null and is_instance_valid(player):
		var per_gold := maxf(float(greed_data.params.get("per_gold", 20.0)), 1.0)
		var g_steps := mini(int(floor(float(player.get("gold")) / per_gold)),
			int(greed_data.params.get("cap_steps", 10)))
		_push_inject_pool(p_ctx,
			StringName(String(greed_data.params.get("pool", "greed_dmg"))),
			float(greed_data.params.get("step", 0.05)) * float(g_steps))
	# REL_FAULTLESS_CHAIN 无瑕链路：层数 × step（层数在 enemy_killed 叠 / player_hit 清）
	var fault_data := _owned_effect(&"REL_EF_FAULTLESS")
	if fault_data != null and _faultless_stacks > 0:
		_push_inject_pool(p_ctx,
			StringName(String(fault_data.params.get("pool", "faultless_dmg"))),
			float(fault_data.params.get("step", 0.02)) * float(_faultless_stacks))
	# REL_VANGUARD 先手矩阵：目标满血（hp ≥ max_hp）首次命中 ×mult → contrib = mult−1
	var vanguard_data := _owned_effect(&"REL_EF_VANGUARD")
	if vanguard_data != null and p_target != null and is_instance_valid(p_target):
		var v_max: float = p_target.get("max_hp")
		if v_max > 0.0 and float(p_target.get("hp")) >= v_max:
			_push_inject_pool(p_ctx,
				StringName(String(vanguard_data.params.get("pool", "vanguard_dmg"))),
				maxf(float(vanguard_data.params.get("mult", 2.0)) - 1.0, 0.0))
	# REL_CRIMSON_RUSH 裂颅狂潮：玩家血线 < pct → +step（ctx.player_hp_pct 现成条件输入）
	var crimson_data := _owned_effect(&"REL_EF_CRIMSON_RUSH")
	if crimson_data != null \
			and p_ctx.player_hp_pct > 0.0 \
			and p_ctx.player_hp_pct < float(crimson_data.params.get("pct", 0.5)):
		_push_inject_pool(p_ctx,
			StringName(String(crimson_data.params.get("pool", "lowhp_dmg"))),
			float(crimson_data.params.get("step", 0.30)))
	# REL_ELITE_WINDOW 猎杀时刻：窗口内 +step（窗口在 enemy_killed 置位 / tick 衰减）
	var window_data := _owned_effect(&"REL_EF_ELITE_WINDOW")
	if window_data != null and _elite_window_left > 0.0:
		_push_inject_pool(p_ctx,
			StringName(String(window_data.params.get("pool", "elite_window_dmg"))),
			float(window_data.params.get("step", 0.25)))
	# REL_FOCUS_MARK 猎杀印记：同目标连续命中逐发 +step（instance id 判同目标；换目标清零）
	var focus_data := _owned_effect(&"REL_EF_FOCUS_MARK")
	if focus_data != null and p_target != null and is_instance_valid(p_target):
		var iid := p_target.get_instance_id()
		if _mark_target_iid == iid:
			_mark_steps = mini(_mark_steps + 1, int(focus_data.params.get("cap", 10)))
		else:
			_mark_target_iid = iid
			_mark_steps = 1
		_push_inject_pool(p_ctx,
			StringName(String(focus_data.params.get("pool", "focus_dmg"))),
			float(focus_data.params.get("step", 0.03)) * float(_mark_steps))
	# REL_BLOOD_TITHE 血税契约：波开付费成功 → 本波 +step（欠费波哑火）
	var tithe_data := _owned_effect(&"REL_EF_BLOOD_TITHE")
	if tithe_data != null and _tithe_paid_wave:
		_push_inject_pool(p_ctx,
			StringName(String(tithe_data.params.get("pool", "tithe_dmg"))),
			float(tithe_data.params.get("step", 0.15)))
	# REL_RESONANT_TOUCH 共鸣触媒：反应窗口内层数 × step（层在 reaction_triggered 叠）
	var resonant_data := _owned_effect(&"REL_EF_RESONANT")
	if resonant_data != null and _resonant_stacks > 0 and _resonant_left > 0.0:
		_push_inject_pool(p_ctx,
			StringName(String(resonant_data.params.get("pool", "resonant_dmg"))),
			float(resonant_data.params.get("step", 0.06)) * float(_resonant_stacks))


# ── 事件分发（listen_events 契约守卫） ────────────────────────────
func bind_events() -> void:
	# 首次调用绑定（幂等）；GameLoop 在 Boot 期提前调用——保证 enemy_killed/player_hit
	# 等事件派发时本处理器先于池归还清零读取实体字段（连接序 = 派发序）。
	# owned 为空时全部守卫短路——无行为差异，无泄漏。
	if _events_bound:
		return
	_events_bound = true
	EventBus.wave_started.connect(_on_wave_started)
	EventBus.wave_cleared.connect(_on_wave_cleared)
	EventBus.enemy_killed.connect(_on_enemy_killed)
	EventBus.player_hit.connect(_on_player_hit)
	EventBus.damage_resolved.connect(_on_damage_resolved)
	EventBus.card_chosen.connect(_on_card_chosen)
	# R252 遗物扩容三连（回调内部按 _listens/_owned_effect 守卫——连接常驻，owned 空
	# 时全部短路，无行为差异）：
	EventBus.reaction_triggered.connect(_on_reaction_triggered)   # REL_RESONANT_TOUCH（表内域）
	EventBus.level_up.connect(_on_level_up)                       # REL_LEVEL_TREASURY 单级臂（表内域）
	# ★ REL_LEVEL_TREASURY 批臂特判直连：level_up_batch 不在 DataValidator.EVENT_NAMES
	# 表（data_validator.gd:34-40）——.tres 声明会被悬空剔除，故只能代码 connect；守卫走
	# _owned_effect（_on_level_up_batch 注释详述特判缘由）
	EventBus.level_up_batch.connect(_on_level_up_batch)
	# ★ R253 REL_SAFE_ORBIT 特判直连：mine_dodged 不在 EVENT_NAMES 表——同
	# REL_LEVEL_TREASURY 先例（代码 connect，守卫走 _owned_effect；owned 空短路）
	EventBus.mine_dodged.connect(_on_mine_dodged_relic)


func _listens(p_effect_id: StringName, p_event: StringName) -> bool:
	# owned 中存在该 effect 且其 listen_events 声明了本事件（.tres 契约）
	for data in owned:
		if data.effect_id == p_effect_id:
			return data.listen_events.has(p_event)
	return false


func _weapon_by_uid(p_uid: int) -> WeaponBase:
	# 来源武器解析（R15：暴击谐振按暴击来源重置；未命中任何槽位 → null）
	if player == null or not is_instance_valid(player):
		return null
	for w in player.get("weapon_slots"):
		if w != null and is_instance_valid(w) and int(w.get("uid")) == p_uid:
			return w
	return null


func _owned_effect(p_effect_id: StringName) -> RelicData:
	for data in owned:
		if data.effect_id == p_effect_id:
			return data
	return null


func _apply_passive(p_data: RelicData) -> void:
	# 常驻位生效（A3 §5 数值）
	match p_data.effect_id:
		&"REL_EF_XP_MULT":
			xp_mult_factor = float(p_data.params.get("mult", 1.0))
		&"REL_EF_CARD_EXTRA":
			extra_deal_cards = maxi(int(p_data.params.get("cards", 4)) - 3, 0)
			curse_last_card = true
		&"REL_EF_DEATH_CHEAT":
			death_cheat_uses += maxi(int(p_data.params.get("uses", 1)), 0)
		&"REL_EF_GLASS":
			# R72 玻璃大炮：伤害 +40%（命中时点乘区注入），最大生命 −25%（一次性代价）
			if player != null and is_instance_valid(player):
				var mhp: float = player.get("max_hp")
				player.set("max_hp", mhp * 0.75)
				player.set("hp", minf(float(player.get("hp")), mhp * 0.75))
		&"REL_EF_SKILL_HASTE":
			# R72 时之沙：角色技能冷却 ×0.8。R80 改写常驻乘区（skill_cd_relic_mult）
			# 并走 refresh——直写 skill_cd_base 会被挂卡重算覆盖（用户实测「有遗物仍 120s」）
			if player != null and is_instance_valid(player):
				var mult := float(p_data.params.get("mult", 0.8))
				player.set("skill_cd_relic_mult", mult)
				if player.has_method(&"refresh_skill_cd"):
					player.call(&"refresh_skill_cd")
		&"REL_EF_ATTACK_CDR":
			# R186 每击谐振：预算存款激活拉满 + 全屏横幅。推（on_attack_fired）+tick（回充）
			# 驱动、listen_events 留空 → _listens 恒 false 不可用，守卫走 _owned_effect
			#（先例 REL_EF_BOUNCE_MOMENTUM）；skill_cd_relic_mult 不碰——与时之沙/技能急速乘法正交
			_atk_cdr_budget = _attack_cdr_bank_cap(p_data)
			EventBus.emit_mechanics_intro("⚡ 每击谐振：攻击加速技能冷却（≤20 击/秒）")
		_:
			pass                                # 事件驱动型遗物无常驻位


func _on_wave_started(_p_wave: int) -> void:
	# 波开行重置（OVERCLOCK 波内一次口径）+ WORDS_TIDE 重随申请（A3 §5「每波开始时」）
	elite_kill_done_this_wave = false
	if _listens(&"REL_EF_CARD_REROLL", &"wave_started"):
		reroll_pending = true
	# R252 血税契约：波开扣费置波内有效位（金币不足本波失效不报错——金币为局内态）
	_tithe_paid_wave = false
	if _listens(&"REL_EF_BLOOD_TITHE", &"wave_started") and player != null \
			and is_instance_valid(player):
		var cost := int(_effect_param(&"REL_EF_BLOOD_TITHE", "cost", 10.0))
		var gold_now: int = player.get("gold")
		if cost > 0 and gold_now >= cost:
			player.set("gold", gold_now - cost)
			_tithe_paid_wave = true


func _on_wave_cleared(p_wave: int) -> void:
	# R252 低息存款：波末利息（每持有 per 金币 +gain，cap 封顶——floor 分档不进位）
	if _listens(&"REL_EF_WAVE_INTEREST", &"wave_cleared") and player != null \
			and is_instance_valid(player):
		var per := _effect_param(&"REL_EF_WAVE_INTEREST", "per", 100.0)
		var gold_now: int = player.get("gold")
		if per > 0.0 and gold_now > 0:
			var interest := int(minf(floor(float(gold_now) / per)
				* _effect_param(&"REL_EF_WAVE_INTEREST", "gain", 5.0),
				_effect_param(&"REL_EF_WAVE_INTEREST", "cap", 30.0)))
			if interest > 0:
				player.set("gold", gold_now + interest)
	# R252 战地医师：波末回复 heal_pct × max_hp（HARVEST 回血同形钳制）
	if _listens(&"REL_EF_WAVE_HEAL", &"wave_cleared") and player != null \
			and is_instance_valid(player):
		var heal_pct := _effect_param(&"REL_EF_WAVE_HEAL", "heal_pct", 0.08)
		var max_hp: float = player.get("max_hp")
		player.set("hp", minf(float(player.get("hp")) + max_hp * heal_pct, max_hp))
	# REL_BLACK_MARKET：w35 起每 10 波追加商店波（A3 §6.5 商店占位——本期仅排程计数）
	if not _listens(&"REL_EF_BLACK_MARKET", &"wave_cleared"):
		return
	if p_wave < int(_effect_param(&"REL_EF_BLACK_MARKET", "start_wave", 35)):
		return
	if (p_wave - int(_effect_param(&"REL_EF_BLACK_MARKET", "start_wave", 35))) \
			% maxi(int(_effect_param(&"REL_EF_BLACK_MARKET", "interval", 10)), 1) == 0:
		pending_shop_waves += 1
		DebugStats.count(&"relic_shop_scheduled")


func _on_enemy_killed(p_enemy: Node2D) -> void:
	# REL_HARVEST 击杀回血 + REL_OVERCLOCK 精英首杀稀有度保底（A3 §5）
	if not (p_enemy is Enemy):
		return                                  # 探针/裸实体防御（pkg4 HUD 探针等）
	if _listens(&"REL_EF_KILL_HEAL", &"enemy_killed") and player != null \
			and is_instance_valid(player):
		var pct := float(_effect_param(&"REL_EF_KILL_HEAL", "heal_pct_max_hp", 0.004))
		var max_hp: float = player.get("max_hp")
		var hp: float = player.get("hp")
		player.set("hp", minf(hp + max_hp * pct, max_hp))
	# R72 连杀狂热：击杀 +1 层（窗口刷新；上限 param）——伤害乘区在命中时点注入
	if _listens(&"REL_EF_KILL_FRENZY", &"enemy_killed"):
		_frenzy_stacks = mini(_frenzy_stacks + 1,
			int(_effect_param(&"REL_EF_KILL_FRENZY", "max_stacks", 5)))
		_frenzy_left = float(_effect_param(&"REL_EF_KILL_FRENZY", "dur", 3.0))
	if _listens(&"REL_EF_ELITE_KILL_LUCK", &"enemy_killed") and not elite_kill_done_this_wave:
		if (int(p_enemy.get("tags")) & GameConst.TAG_ELITE) != 0:
			elite_kill_done_this_wave = true
			rarity_floor_next = maxi(int(_effect_param(&"REL_EF_ELITE_KILL_LUCK",
				"min_rarity", 2)), 0)
	# ── R252 遗物扩容击杀链（无瑕叠层 / 葬列火种 / 弑王回响 / 猎杀时刻 / 猎首金冠）──
	if _listens(&"REL_EF_FAULTLESS", &"enemy_killed"):
		_faultless_stacks = mini(_faultless_stacks + 1,
			int(_effect_param(&"REL_EF_FAULTLESS", "cap", 15.0)))
	if _listens(&"REL_EF_ELITE_WINDOW", &"enemy_killed") \
			and ((p_enemy as Enemy).is_boss() or (p_enemy as Enemy).is_elite()):
		_elite_window_left = _effect_param(&"REL_EF_ELITE_WINDOW", "window", 4.0)
	if _listens(&"REL_EF_CROWN_GOLD", &"enemy_killed") and player != null \
			and is_instance_valid(player):
		var crown_gold := 0
		if (p_enemy as Enemy).is_boss():
			crown_gold = int(_effect_param(&"REL_EF_CROWN_GOLD", "boss_gold", 80.0))
		elif (p_enemy as Enemy).is_elite():
			crown_gold = int(_effect_param(&"REL_EF_CROWN_GOLD", "elite_gold", 30.0))
		if crown_gold > 0:
			player.set("gold", int(player.get("gold")) + crown_gold)
	if _listens(&"REL_EF_PYRE_BLAST", &"enemy_killed") and _pyre_cd_left <= 0.0 \
			and rng.randf() < _effect_param(&"REL_EF_PYRE_BLAST", "chance", 0.25) \
			and player != null and is_instance_valid(player):
		var pyre := _owned_effect(&"REL_EF_PYRE_BLAST")
		var pyre_wpn := _primary_weapon()
		if pyre != null and pyre_wpn != null:
			_pyre_cd_left = float(pyre.params.get("icd", 0.3))
			pyre_wpn.settle_aoe(p_enemy.global_position,
				float(pyre.params.get("radius", 120.0)),
				pyre_wpn.get_current_atk() * float(pyre.params.get("atk_ratio", 1.5)),
				false)
			DebugStats.count(&"relic_pyre")
	if _listens(&"REL_EF_KINGSLAY", &"enemy_killed") \
			and ((p_enemy as Enemy).is_boss() or (p_enemy as Enemy).is_elite()):
		var ks := _owned_effect(&"REL_EF_KINGSLAY")
		var ks_wpn := _primary_weapon()
		if ks != null and ks_wpn != null:
			ks_wpn.settle_aoe(p_enemy.global_position,
				float(ks.params.get("radius", 2000.0)),
				ks_wpn.get_current_atk() * float(ks.params.get("atk_ratio", 2.5)),
				false)
			DebugStats.count(&"relic_kingslay")


func _on_player_hit(_p_damage: float, _p_source_uid: int) -> void:
	# R252 无瑕链路：受击清零（必须先于本函数任何 return——含 PHOENIX 早退路径）
	if _listens(&"REL_EF_FAULTLESS", &"player_hit"):
		_faultless_stacks = 0
	# R72 荆棘王座：受击反击（周围 AoE，0.8s 内冷防高频接触刷屏）——先于 PHOENIX
	# 早退（两者可共存）
	if _listens(&"REL_EF_THORNS", &"player_hit") and _thorns_cd_left <= 0.0 			and player != null and is_instance_valid(player):
		var thorns := _owned_effect(&"REL_EF_THORNS")
		if thorns != null:
			_thorns_cd_left = float(thorns.params.get("icd", 0.8))
			var weapon := _primary_weapon()
			if weapon != null:
				weapon.settle_aoe(player.global_position,
					float(thorns.params.get("radius", 140.0)),
					weapon.get_current_atk() * float(thorns.params.get("atk_ratio", 1.2)),
					false)
				DebugStats.count(&"relic_thorns")
	# R253 霜寒守卫：实受伤（player_hit 只在 HP 实减路径发射——格挡/无敌早退不发）触发
	# 寒波冻结周围敌（PHOENIX 早退 return 之前——两者可共存；icd 防高频接触刷屏）
	if _listens(&"REL_EF_FROST_WARD", &"player_hit") and _frost_ward_cd_left <= 0.0:
		_frost_ward_cd_left = _effect_param(&"REL_EF_FROST_WARD", "icd", 8.0)
		_freeze_or_knock_enemies(
			_effect_param(&"REL_EF_FROST_WARD", "radius", 180.0),
			_effect_param(&"REL_EF_FROST_WARD", "freeze", 1.2), 0.0)
		DebugStats.count(&"relic_frost_ward")
	# REL_PHOENIX：致死伤害保留 1 HP + 清屏冲击（300% ATK / 半径 400；A3 §5）。
	# 时序：Player.take_contact_damage 先 emit player_hit 再判死——此处把 hp 拉回 1，
	# 同步事件派发保证其后的致死判定自然短路（uses 耗尽则放行死亡，E-16 仲裁不受影响）。
	if not _listens(&"REL_EF_DEATH_CHEAT", &"player_hit"):
		return
	if death_cheat_uses <= 0 or player == null or not is_instance_valid(player):
		return
	if float(player.get("hp")) > 0.0:
		return
	death_cheat_uses -= 1
	player.set("hp", 1.0)
	phoenix_triggered += 1
	DebugStats.count(&"relic_phoenix")
	var data := _owned_effect(&"REL_EF_DEATH_CHEAT")
	if data == null:
		return
	var atk_ratio := float(data.params.get("atk_ratio", 3.0))
	var radius := float(data.params.get("radius", 400.0))
	var weapon := _primary_weapon()
	if weapon != null:
		weapon.settle_aoe(player.global_position, radius,
			weapon.get_current_atk() * atk_ratio, false)


func on_attack_fired(p_fire_interval: float = 0.0) -> void:
	# R186 每击谐振 push 口（WeaponBase.tick try_fire 成功位调用——开火口径计费：一枪=一击，
	# 霰弹 9 丸仍 1 击；不走 damage_resolved：结算侧幂等键折叠同帧多弹丸、AOE_SECONDARY
	# 与直击不可区分且属风暴告警通道，设计案 §0 裁定）。守卫链：持有 → 玩家可用 →
	# 技能冷却中（就绪不计费不耗预算，存款留给下轮）→ 预算足额（<1 击预算整击丢弃）。
	# 预算扣减走 snappedf 整击网格：纯浮点连减会在满存款第 60 击处漂移出 0.00999… 假残量
	#（<cdp 被误丢第 60 击），网格化保证「满存款恰 60 击用尽」语义精确。
	# R198（二aw-2 口径 9）慢速武器间隔折算补偿：cdp_eff = cdp × clampf(开火间隔 ×
	# rate_per_sec, 1.0, fire_mult_max)——0.5s 武器单击计 10 击预算、0.1s 武器 2 击（两者
	# 每秒收益同为 20 击 ≈0.2s，与射速解耦）；下限 1.0 = 快速武器收益不低于改前；上限
	# fire_mult_max（.tres 新键默认 10.0）= 超慢速武器单击计费帽。预算守卫仍按 cdp
	#（<1 击预算丢整击——慢击慢付，存款不足时宁可下拍再计），扣减网格仍按 cdp 防浮点漂移。
	var data := _owned_effect(&"REL_EF_ATTACK_CDR")
	if data == null or player == null or not is_instance_valid(player):
		return
	var cd_left: float = player.get("skill_cd_left")
	if cd_left <= 0.0:
		return
	var cdp := float(data.params.get("cd_per_attack", 0.01))
	if cdp <= 0.0 or _atk_cdr_budget < cdp:
		return
	var rate := float(data.params.get("rate_per_sec", 20.0))
	var fire_mult_max := float(data.params.get("fire_mult_max", 10.0))
	var cdp_eff := cdp * clampf(p_fire_interval * rate, 1.0, fire_mult_max)
	_atk_cdr_budget = maxf(snappedf(_atk_cdr_budget - cdp_eff, cdp), 0.0)
	player.set("skill_cd_left", maxf(cd_left - cdp_eff, 0.0))
	attack_cdr_credits += 1
	attack_cdr_seconds += cdp_eff
	DebugStats.count(&"relic_attack_cdr")


func tick(p_game_delta: float) -> void:
	# R66 遗物内部冷却推进（GameLoop PLAYING ⑥——选卡/暂停期冻结，战斗时口径）
	_crit_chain_cd_left = maxf(_crit_chain_cd_left - p_game_delta, 0.0)
	# R72：连杀狂热窗口衰减 / 荆棘与汲血内冷
	if _frenzy_left > 0.0:
		_frenzy_left = maxf(_frenzy_left - p_game_delta, 0.0)
		if _frenzy_left <= 0.0:
			_frenzy_stacks = 0
	_thorns_cd_left = maxf(_thorns_cd_left - p_game_delta, 0.0)
	_lifesteal_cd_left = maxf(_lifesteal_cd_left - p_game_delta, 0.0)
	# R252：猎杀时刻窗口衰减 / 共鸣触媒窗口衰减（到期层清）/ 葬列火种内冷
	_elite_window_left = maxf(_elite_window_left - p_game_delta, 0.0)
	if _resonant_left > 0.0:
		_resonant_left = maxf(_resonant_left - p_game_delta, 0.0)
		if _resonant_left <= 0.0:
			_resonant_stacks = 0
	_pyre_cd_left = maxf(_pyre_cd_left - p_game_delta, 0.0)
	# ── R253 防御/控制向六件（霜寒内冷衰减 / 金钟罩节拍 / 减伤乘区维护） ──
	_frost_ward_cd_left = maxf(_frost_ward_cd_left - p_game_delta, 0.0)
	if _owned_effect(&"REL_EF_AEGIS_CLOCK") != null:
		if _aegis_clock_left <= 0.0:
			_aegis_clock_left = _effect_param(&"REL_EF_AEGIS_CLOCK", "every", 30.0)
		_aegis_clock_left -= p_game_delta
		if _aegis_clock_left <= 0.0 and player != null and is_instance_valid(player) \
				and not bool(player.get("_dead")):
			player.call(&"grant_temp_shield", true)   # 静默授予（独立计数 orange_gain_relic）
			# R253 评审 M3：磁守结界「每次获得闪避护盾时震开」文案闭环——金钟罩自动盾
			# 同享击退（原只挂 mine_dodged，自动盾不发该事件=组合断裂）；函数内自守卫
			# SAFE_ORBIT，未持零副作用
			_on_mine_dodged_relic((player as Node2D).global_position)
			DebugStats.count(&"relic_aegis_clock")
	_maintain_relic_dr()
	# R186 每击谐振：预算回充（rate×cdp 信用/游戏秒，存款帽封顶吸收齐射式爆发；
	# 仅 PLAYING 到达此处——与 skill_cd 同冻结，无暂停套利）
	var atk_cdr := _owned_effect(&"REL_EF_ATTACK_CDR")
	if atk_cdr != null:
		_atk_cdr_budget = minf(_atk_cdr_budget
			+ float(atk_cdr.params.get("rate_per_sec", 20.0))
			* float(atk_cdr.params.get("cd_per_attack", 0.01)) * p_game_delta,
			_attack_cdr_bank_cap(atk_cdr))


func frenzy_dmg_bonus() -> float:
	# R72 连杀狂热当前加成（命中时点乘区注入源）
	if _frenzy_stacks <= 0 or _frenzy_left <= 0.0:
		return 0.0
	return float(_effect_param(&"REL_EF_KILL_FRENZY", "per_stack", 0.08)) * float(_frenzy_stacks)


# ── R220 刀11：damage_resolved 消费 30Hz 降频门（R207 半频相位先例） ──
# mobile 门内隔帧消费：关门帧结果引用暂存（保序）、开门帧一并处理——暴击谐振掷骰/
# 汲血刻印/遥测计数的时序与累计语义不变（rng 序同序消费），只把 _listens×owned 双循环
# 的每帧执行频率压半。桌面/headless 与注入口 0=每帧原路径（既有测试同步断言不受扰）。
var dmg_half_freq_override: int = -1         # 测试注入口（-1=平台自动 / 0=每帧 / 1=半频）
var _dmg_subtick_left: int = 1               # 半频相位（1=本帧消费；R206 _ui_subtick 同款）
var _dmg_pending: Array[DamageResult] = []   # 关门帧暂存队列（开门帧保序消费）


func _dmg_half_freq() -> bool:
	if dmg_half_freq_override >= 0:
		return dmg_half_freq_override == 1
	return OS.has_feature("mobile")


func _on_damage_resolved(p_result: DamageResult) -> void:
	# R220 刀11：批化消费入口（EventBus 派发时点=⑧段前 game_loop dispatch——批内保序
	# 到达）；null 前置（暂存队列不收 null，原口径保持）。
	if p_result == null:
		return
	if _dmg_half_freq():
		_dmg_pending.append(p_result)
		_dmg_subtick_left -= 1
		if _dmg_subtick_left > 0:
			return                           # 关门帧：暂存（累计值不丢）
		_dmg_subtick_left = 2
		for r in _dmg_pending:
			_process_damage_resolved(r)
		_dmg_pending.clear()
		return
	_process_damage_resolved(p_result)


func _process_damage_resolved(p_result: DamageResult) -> void:
	# REL_CRIT_CHAIN 暴击重置冷却（15%）+ TROPHY/MOMENTUM 遥测（实际乘区在命中时点注入）
	# R66：内部冷却 30s——触发成功后 30s 内不再掷骰（用户反馈「逆天」：高暴击多段
	# 构筑下近乎连续重置角色技能/武器冷却）
	if p_result == null:
		return
	if _listens(&"REL_EF_CRIT_CHAIN", &"damage_resolved") and p_result.is_crit:
		var chance := float(_effect_param(&"REL_EF_CRIT_CHAIN", "chance", 0.15))
		if _crit_chain_cd_left <= 0.0 and rng.randf() < chance:
			# R15b（用户裁定）：暴击谐振的重置对象 = **角色技能冷却**（120s 大招——
			# 武器开火间隔的“冷却”玩家无感）+ 顺手重置暴击来源武器的开火冷却。
			# 生效全屏提示
			var weapon := _weapon_by_uid(p_result.source_uid)
			if weapon == null:
				weapon = _primary_weapon()
			if weapon != null:
				weapon.cooldown_left = 0.0
			if player != null and is_instance_valid(player):
				player.set("skill_cd_left", 0.0)   # skill_ready 由 cd<=0 派生
				crit_chain_resets += 1
				_crit_chain_cd_left = float(_effect_param(&"REL_EF_CRIT_CHAIN", "cd", 30.0))
				EventBus.emit_mechanics_intro("⚡ 暴击谐振：角色技能冷却已重置！")
			DebugStats.count(&"relic_crit_chain")
	# R72 汲血刻印：暴击回血（0.6s 内冷——高暴击多段构筑不无限奶）
	if _listens(&"REL_EF_CRIT_LIFESTEAL", &"damage_resolved") and p_result.is_crit 			and _lifesteal_cd_left <= 0.0 and player != null and is_instance_valid(player):
		_lifesteal_cd_left = float(_effect_param(&"REL_EF_CRIT_LIFESTEAL", "icd", 0.6))
		var heal_pct := float(_effect_param(&"REL_EF_CRIT_LIFESTEAL", "heal_pct_max_hp", 0.02))
		var mhp2: float = player.get("max_hp")
		player.set("hp", minf(float(player.get("hp")) + mhp2 * heal_pct, mhp2))
	if p_result.pool_breakdown.has(&"elite_dmg"):
		elite_dmg_hits += 1
	if p_result.pool_breakdown.has(&"bounce_dmg"):
		momentum_hits += 1
	# R252 断头台协议：结算（落血）后查目标血线 < 阈值 → 处决（apply_damage 走死亡
	# 管线唯一入口；已死/顺延占位结果短路；精英 12% / 首领 6% 双阈值）
	if _listens(&"REL_EF_GUILLOTINE", &"damage_resolved") and not p_result.deferred_merge \
			and not p_result.killed and p_result.target_uid != 0:
		var gtarget := _enemy_by_uid(p_result.target_uid)
		if gtarget != null and ((gtarget as Enemy).is_boss() or (gtarget as Enemy).is_elite()):
			var th := _effect_param(&"REL_EF_GUILLOTINE", "pct", 0.12)
			if (gtarget as Enemy).is_boss():
				th = _effect_param(&"REL_EF_GUILLOTINE", "boss_pct", 0.06)
			var g_max: float = gtarget.get("max_hp")
			if g_max > 0.0 and float(gtarget.get("hp")) / g_max < th:
				gtarget.apply_damage(float(gtarget.get("hp")))   # 阈值内抹平残余（死亡只执行一次）
				DebugStats.count(&"relic_guillotine")


func _on_card_chosen(p_card_id: StringName, p_kind: int) -> void:
	# 遗物卡激活通道 + REL_ECHO 回响复制（25% 复制该卡到另一把随机武器，A3 §5）
	if p_kind == CardGenerator.CardKind.RELIC:
		activate(p_card_id)
		return
	if not _listens(&"REL_EF_CARD_ECHO", &"card_chosen"):
		return
	if p_kind != CardGenerator.CardKind.TRAIT or player == null \
			or not is_instance_valid(player):
		return
	if rng.randf() >= float(_effect_param(&"REL_EF_CARD_ECHO", "chance", 0.25)):
		return
	var trait_data := registry.get_trait(p_card_id) if registry != null else null
	if trait_data == null:
		return                                  # FALLBACK 等运行期构造卡不复制
	# R187 §三.7 防回响绕门 P0 补挂：回响挂载必须过挂载侧统一适配门
	#（CardGenerator.mount_gate_allows——required_weapon/required_forms/requires_trait/
	# exclusive_group 全校验）。否则 MEC_HIVE_RACK(W6 专属) 经回响落 W7 → volley_eff
	# 白吃 +2（Boss 全中 ~235→~700 数值崩坏链）。全部武器不过门 → 本次回响不落卡。
	var target := _echo_weapon(trait_data)
	if target != null and target.attach_trait(trait_data):
		echo_copies += 1
		DebugStats.count(&"relic_echo")
	else:
		# R262b L17：复制失败出声（R238「选了没生效」静默家族同修）——目标池全满
		# 12 类帽时 25% proc 定向白吃，横幅明示
		DebugStats.count(&"relic_echo_rejected")
		EventBus.mechanics_intro.emit("回响：目标武器词条栏已满，%s 复制未生效" % trait_data.display_name)


# ── 内部 ──────────────────────────────────────────────────────────
func _effect_param(p_effect_id: StringName, p_key: String, p_default: float) -> float:
	var data := _owned_effect(p_effect_id)
	if data == null:
		return p_default
	return float(data.params.get(p_key, p_default))


func _attack_cdr_bank_cap(p_data: RelicData) -> float:
	# R186 存款帽 = rate_per_sec × cd_per_attack × bank_mult 信用，快照整击网格——
	# raw 浮点乘积 0.6000…01 ≠ 字面 0.6，网格化保证「激活拉满恰 60 击预算」；
	# 下限 1 击防退化数据（bank_mult 极小时帽归零）。
	var cdp := float(p_data.params.get("cd_per_attack", 0.01))
	var cap := snappedf(float(p_data.params.get("rate_per_sec", 20.0)) * cdp
		* float(p_data.params.get("bank_mult", 3.0)), cdp)
	return maxf(cap, cdp)


func _primary_weapon() -> WeaponBase:
	# 主武器（首个已装备槽；复活冲击/暴击谐振宿主）
	if player == null or not is_instance_valid(player):
		return null
	var slots: Variant = player.get("weapon_slots")
	if slots is Array:
		for w in (slots as Array):
			if w is WeaponBase and is_instance_valid(w):
				return w
	return null


func _echo_weapon(p_trait: TraitData) -> WeaponBase:
	# 回响宿主：随机一把「过挂载统一门」的武器（25% 复制目标；含主武器——A3「另一把
	# 随机武器」在单武器时退化为重挂）。R187 §三.7：挂载侧 mount_gate_allows 校验
	# required_weapon/required_forms/requires_trait/exclusive_group——不适配武器不入池
	#（防回响绕门 P0 前科）；全池不过门 → null（本次回响静默不落卡，不计数）
	if player == null or not is_instance_valid(player):
		return null
	var pool: Array[WeaponBase] = []
	var slots: Variant = player.get("weapon_slots")
	if slots is Array:
		for w in (slots as Array):
			if w is WeaponBase and is_instance_valid(w) \
					and CardGenerator.mount_gate_allows(p_trait, w):
				pool.append(w)
	if pool.is_empty():
		return null
	return pool[rng.randi_range(0, pool.size() - 1)]


# ── R253 遗物扩容回调与内部（共鸣触媒 / 跃升金库 / 注入公共尾部 / uid 解析） ──────
func _on_mine_dodged_relic(p_pos: Vector2) -> void:
	# R253 磁守结界：获得橙盾时刻震开周围敌（围殴拆解——与躲爆玩法同轴；击退力度随
	# 距离衰减 ×(1 - d/r×0.5)）。p_pos=爆炸位（授盾因果同源）。
	if _owned_effect(&"REL_EF_SAFE_ORBIT") == null:
		return
	_freeze_or_knock_enemies(
		_effect_param(&"REL_EF_SAFE_ORBIT", "radius", 220.0), 0.0,
		_effect_param(&"REL_EF_SAFE_ORBIT", "force", 340.0), p_pos)
	DebugStats.count(&"relic_safe_orbit")


func _freeze_or_knock_enemies(p_radius: float, p_freeze_s: float, p_force: float,
		p_center: Variant = null) -> void:
	# R253 范围控场公共口：freeze>0 → ElementalState.freeze_timer 续 max（Boss 免疫定身
	# 仅吃减速由 get_speed_factor 引擎侧处理 F-17）；force>0 → knockback（从中心向外，
	# 距离衰减）。敌查询走 player._deps enemy_grid.query_circle（weapon settle_aoe 同源）；
	# 触发频率受 icd/事件节拍约束，遍历开销可忽略。
	if player == null or not is_instance_valid(player):
		return
	var center: Vector2 = p_center if p_center is Vector2 else player.global_position
	var grid: Variant = player.get("_deps").get("enemy_grid")
	if grid == null:
		return
	for e in grid.query_circle(center, p_radius):
		if not (e is Enemy) or not is_instance_valid(e) or (e as Enemy).dead:
			continue
		if p_freeze_s > 0.0:
			var el: Variant = (e as Enemy).get("elemental")
			if el is ElementalState:
				(el as ElementalState).freeze_timer = maxf(
					float((el as ElementalState).freeze_timer), p_freeze_s)
		if p_force > 0.0:
			var d: float = (e as Enemy).global_position.distance_to(center)
			if d > 0.001:
				(e as Enemy).knockback(((e as Enemy).global_position - center).normalized()
					* p_force * (1.0 - d / p_radius * 0.5))


func _maintain_relic_dr() -> void:
	# R253 末路壁垒/守护本能/壁垒契约：条件减伤写入 player.relic_dr（独立乘区，与结晶
	# 护盾 dr 乘法复合——player.take_contact_damage 双闸串联；tick 驱动=PLAYING 常驻，
	# 暂停期敌同冻结无边界缺口）。三件取最大贡献（低血双档不叠乘，护盾流独立档）。
	if player == null or not is_instance_valid(player):
		return
	var target_dr := 0.0
	if _owned_effect(&"REL_EF_LAST_BULWARK") != null:
		var mhp: float = player.get("max_hp")
		if mhp > 0.0 and float(player.get("hp")) / mhp < _effect_param(&"REL_EF_LAST_BULWARK", "pct", 0.30):
			target_dr = maxf(target_dr, _effect_param(&"REL_EF_LAST_BULWARK", "dr", 0.25))
	if _owned_effect(&"REL_EF_GUARD_INSTINCT") != null:
		var mhp2: float = player.get("max_hp")
		if mhp2 > 0.0:
			var lost_pct := clampf(1.0 - float(player.get("hp")) / mhp2, 0.0, 1.0)
			var per := _effect_param(&"REL_EF_GUARD_INSTINCT", "per_pct", 0.10)
			if per > 0.0:
				target_dr = maxf(target_dr, minf(floor(lost_pct / per)
					* _effect_param(&"REL_EF_GUARD_INSTINCT", "step", 0.02),
					_effect_param(&"REL_EF_GUARD_INSTINCT", "cap", 0.20)))
	if _owned_effect(&"REL_EF_BULWARK_PACT") != null:
		var stacks := int(player.get("temp_shield_stacks"))
		var su: Variant = player.get("_shield_units")
		if su is Dictionary:
			for k in (su as Dictionary):
				var u: Dictionary = (su as Dictionary)[k]
				if u.ready:
					stacks += 1
		target_dr = maxf(target_dr, minf(float(stacks)
			* _effect_param(&"REL_EF_BULWARK_PACT", "per_stack", 0.03),
			_effect_param(&"REL_EF_BULWARK_PACT", "cap", 0.18)))
	player.set("relic_dr", target_dr)


func _on_reaction_triggered(_p_rxn: int, _p_pos: Vector2, _p_target_uid: int) -> void:
	# REL_RESONANT_TOUCH：反应置层（cap 封顶 + 窗口刷新；到期清层在 tick）
	if not _listens(&"REL_EF_RESONANT", &"reaction_triggered"):
		return
	_resonant_stacks = mini(_resonant_stacks + 1,
		int(_effect_param(&"REL_EF_RESONANT", "cap", 5.0)))
	_resonant_left = _effect_param(&"REL_EF_RESONANT", "window", 3.0)


func _on_level_up(_p_new_level: int) -> void:
	# REL_LEVEL_TREASURY 单级臂（.tres 声明 level_up → _listens 守卫成立）
	if not _listens(&"REL_EF_LEVEL_GOLD", &"level_up"):
		return
	_pay_level_gold(1)


func _on_level_up_batch(p_levels: int) -> void:
	# REL_LEVEL_TREASURY 批臂——★特判：level_up_batch 不在 DataValidator.EVENT_NAMES 表
	#（data_validator.gd:34-40），.tres 声明会被悬空剔除，故 bind_events 代码直连、
	# 守卫走 _owned_effect 直查（_listens 对本事件恒 false 的补位）。单级/批双臂由
	# player.gd:2318-2322 互斥发射（levels==1 走单级信号），两入口天然不重复计账。
	if _owned_effect(&"REL_EF_LEVEL_GOLD") == null:
		return
	_pay_level_gold(maxi(p_levels, 0))


func _pay_level_gold(p_levels: int) -> void:
	# 升级金币入账（25 × 批级数；与 R189「批级一次入账」语义同构）
	if p_levels <= 0 or player == null or not is_instance_valid(player):
		return
	var per := int(_effect_param(&"REL_EF_LEVEL_GOLD", "gold_per_level", 25.0))
	if per <= 0:
		return
	player.set("gold", int(player.get("gold")) + per * p_levels)
	DebugStats.count(&"relic_level_gold", p_levels)


func _push_inject_pool(p_ctx: DamageContext, p_pool: StringName, p_contrib: float) -> void:
	# R252 注入型乘区公共尾部（TROPHY/MOMENTUM 同款 7 行模板收敛 + has_mult_pool
	# 幂等去重——同 ctx 二次注入不重复入池）
	if p_ctx == null or p_contrib <= 0.0 or WeaponBase.has_mult_pool(p_ctx, p_pool):
		return
	p_ctx.mult_pools.append({
		"pool_id": p_pool,
		"source_uid": 0,
		"contrib": p_contrib,
		"cap_pool": p_contrib,
		"priority": 0,
	})


func _enemy_by_uid(p_uid: int) -> Enemy:
	# uid → 实体解析（inject 期捕获的引用记忆；池化复用 uid 变更/死亡态自失效）
	var v: Variant = _uid_target_refs.get(p_uid, null)
	if v is Enemy and is_instance_valid(v) and int((v as Enemy).uid) == p_uid \
			and not (v as Enemy).dead:
		return v
	return null
