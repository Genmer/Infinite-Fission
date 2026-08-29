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
var echo_copies: int = 0
var elite_dmg_hits: int = 0                   # pool_breakdown 含 elite_dmg 的结算数
var momentum_hits: int = 0                    # pool_breakdown 含 bounce_dmg 的结算数

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
	elite_kill_done_this_wave = false
	pending_shop_waves = 0
	phoenix_triggered = 0
	crit_chain_resets = 0
	echo_copies = 0
	elite_dmg_hits = 0
	momentum_hits = 0


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


func _listens(p_effect_id: StringName, p_event: StringName) -> bool:
	# owned 中存在该 effect 且其 listen_events 声明了本事件（.tres 契约）
	for data in owned:
		if data.effect_id == p_effect_id:
			return data.listen_events.has(p_event)
	return false


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
		_:
			pass                                # 事件驱动型遗物无常驻位


func _on_wave_started(_p_wave: int) -> void:
	# 波开行重置（OVERCLOCK 波内一次口径）+ WORDS_TIDE 重随申请（A3 §5「每波开始时」）
	elite_kill_done_this_wave = false
	if _listens(&"REL_EF_CARD_REROLL", &"wave_started"):
		reroll_pending = true


func _on_wave_cleared(p_wave: int) -> void:
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
	if _listens(&"REL_EF_ELITE_KILL_LUCK", &"enemy_killed") and not elite_kill_done_this_wave:
		if (int(p_enemy.get("tags")) & GameConst.TAG_ELITE) != 0:
			elite_kill_done_this_wave = true
			rarity_floor_next = maxi(int(_effect_param(&"REL_EF_ELITE_KILL_LUCK",
				"min_rarity", 2)), 0)


func _on_player_hit(_p_damage: float, _p_source_uid: int) -> void:
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


func _on_damage_resolved(p_result: DamageResult) -> void:
	# REL_CRIT_CHAIN 暴击重置冷却（15%）+ TROPHY/MOMENTUM 遥测（实际乘区在命中时点注入）
	if p_result == null:
		return
	if _listens(&"REL_EF_CRIT_CHAIN", &"damage_resolved") and p_result.is_crit:
		var chance := float(_effect_param(&"REL_EF_CRIT_CHAIN", "chance", 0.15))
		if rng.randf() < chance:
			var weapon := _primary_weapon()
			if weapon != null:
				weapon.cooldown_left = 0.0
				crit_chain_resets += 1
				DebugStats.count(&"relic_crit_chain")
	if p_result.pool_breakdown.has(&"elite_dmg"):
		elite_dmg_hits += 1
	if p_result.pool_breakdown.has(&"bounce_dmg"):
		momentum_hits += 1


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
	var target := _echo_weapon()
	if target != null and target.attach_trait(trait_data):
		echo_copies += 1
		DebugStats.count(&"relic_echo")


# ── 内部 ──────────────────────────────────────────────────────────
func _effect_param(p_effect_id: StringName, p_key: String, p_default: float) -> float:
	var data := _owned_effect(p_effect_id)
	if data == null:
		return p_default
	return float(data.params.get(p_key, p_default))


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


func _echo_weapon() -> WeaponBase:
	# 回响宿主：随机一把武器（25% 复制目标；含主武器——A3「另一把随机武器」在单武器时退化为重挂）
	if player == null or not is_instance_valid(player):
		return null
	var pool: Array[WeaponBase] = []
	var slots: Variant = player.get("weapon_slots")
	if slots is Array:
		for w in (slots as Array):
			if w is WeaponBase and is_instance_valid(w):
				pool.append(w)
	if pool.is_empty():
		return null
	return pool[rng.randi_range(0, pool.size() - 1)]
