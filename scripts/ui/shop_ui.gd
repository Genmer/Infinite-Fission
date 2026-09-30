# scripts/ui/shop_ui.gd
# M-20 战地黑市（META_ROADMAP M7 股市商店一期落地，用户反馈「股市设定」）：
# SHOP 波事件 → GameLoop 切 LEVEL_UP 态（复用弹卡仲裁/E-16 同源）→ 本面板上架。
# 行情定价：价格 = 基价 × 品质倍率 × 行情系数（0.7~1.3，波次+槽位确定性漂移——
# ▲ 抬价避开 / ▼ 抄底）。货架 = 词条 ×2（稀有度 roll + 数值缩放与卡池同源）+
# 治疗包 + 未持有遗物（可缺）；刷新花费金币重掷。金币 = 击杀 gold_drop 掉账。
# R188 黑市供给（market 组）：① 类目级 roll 以已持武器为 target 传 _trait_candidates
# 第 4 参（对齐 card_generator.gd 类目 roll 口径）+ 容量感知选货选宿主——展示 target 与
# 售卡 target 同源（购买经 target_weapon 透传，展示=实挂）；② buyable_count()/has_stock()
# 公开谓词（与行内按钮 disabled 同口径，供挂机项 R188-3 直接调用）+ 终兜底常青货
#（buyable_count()==0 时上架，运行期构造 stack_max=99 应急强化，E-08 不落盘不进注册表）
# + REL_BLACK_MARKET 金卡行（价读 .tres params.gold_card_price，SLOT_BONUS 通道，满槽不上架）；
# ③ 刷新钮 _wares 全空行置灰（窄口径，价曲线不动）。
# R195 刷新钮契约（用户反馈「不给刷就别显示」）：置灰改原位隐藏——三口径合一为
# can_refresh() 单源谓词，_refresh() 联动 refresh_btn.visible（disabled 写点删净，
# 几何 (211,802)210×56 原值不动）；黑市/战前补给共用（谓词零 _pre_boss 分支）。
class_name ShopUi
extends CanvasLayer

signal closed()                                # → GameLoop.request_resume（LEVEL_UP → PLAYING）

var card_generator: CardGenerator = null       # 注入（词条/遗物走 apply_choice 同链路）
var _player: Node = null
var _wave: int = 0
var _pre_boss: bool = false                    # 战前补给态（R5.12-P1：标题换「战前补给」）
var _title: Label = null
var _root: Control = null
var _list: VBoxContainer = null
var _gold_label: Label = null
var _wares: Array[Dictionary] = []


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	_build_ui()
	_root.visible = false
	_apply_safe_area()                             # R195 安全区首读（read_deferred 内部延迟 1 帧）
	SafeAreaHelper.bind_reread(get_window(), _apply_safe_area)  # resize/重获焦点重读


func _apply_safe_area() -> void:
	# R195 安全区接入：底座组 SafeAreaHelper 单源（守卫/换算/负钳/延迟读全在 helper，
	# 本屏只引用不复写）——根 FULL_RECT offset_* 内缩（左/上 +，右/下 −）。
	# 守卫外（桌面窗口化/headless）insets 恒零=零应用零回归；dim 随根内缩，黑边区
	# （aspect=keep 回退）天然免疫；黑市卡居中锚卡内父相对零改动不受牵连。
	var area: Rect2 = await SafeAreaHelper.read_deferred(get_window())
	if not is_instance_valid(_root):
		return
	_root.offset_left = area.position.x
	_root.offset_top = area.position.y
	_root.offset_right = -area.size.x
	_root.offset_bottom = -area.size.y


func is_shop_visible() -> bool:
	# 测试观测口
	return _root != null and _root.visible


var _refresh_count: int = 0                    # 本次开店已刷新次数（R7：价格倍数递增）
var _purchase_count: int = 0                   # 本次开店已购买次数（R188-idle 手动操作观测口）

func open(p_player: Node, p_wave: int, p_pre_boss: bool = false) -> void:
	_player = p_player
	_wave = p_wave
	_pre_boss = p_pre_boss
	if _title != null:
		_title.text = "战前补给" if p_pre_boss else "战地黑市"
	_refresh_count = 0
	_purchase_count = 0
	_reroll_wares(false)
	_root.visible = true
	_refresh()


func close() -> void:
	_root.visible = false
	closed.emit()


# ── 行情与货架 ────────────────────────────────────────────────────
func market_mult(p_wave: int, p_slot: int) -> float:
	# 行情系数（确定性漂移；0.7~1.3 = ±30%，A3 §6.1 同风格收敛）
	return 1.0 + 0.3 * sin(float(p_wave * 17 + p_slot * 31))


func _reroll_wares(p_paid: bool) -> void:
	_wares.clear()
	if card_generator == null or _player == null:
		return
	var slot := 0
	for category in ["ADD", "MULT", "MECH", "ELEM"]:
		# R188-A 口径对齐（card_generator.gd:392-394 类目 roll 同源）：以「已持武器」为
		# target 传 _trait_candidates 第 4 参——候选即按该武器自身叠层计数 + 形态/武器
		# 适配门过滤（此前无 target 的全局合计口径会 roll 出「该武器挂不上」的死货）。
		# 容量感知选货选宿主：逐武器求「该武器可挂」的候选集，随机宿主起点、无候选
		# 换下一把，全武器皆空才跳过本类目
		var hosts: Array[WeaponBase] = []
		for w in _player.get("weapon_slots"):
			if w is WeaponBase and is_instance_valid(w):
				hosts.append(w)
		var host: WeaponBase = null
		var clean: Array[StringName] = []
		while not hosts.is_empty():
			var pick_i := randi() % hosts.size()
			var cand_host: WeaponBase = hosts[pick_i]
			var pool := card_generator._trait_candidates(category, _player, [], cand_host)
			# R37（用户反馈「黑市还有武器+经验获取这种异常 buff」）：玩家侧池词条
			# （经验/金币/磁吸/技能急速/血量上限）全局生效——混进黑市配武器前缀就是
			# 「【手枪】经验获取」错乱货。过滤：黑市只卖武器侧词条（玩家侧词条保留
			# 在升级卡池的【通用】语境）；再过一道栈容量门（同 ID 层<stack_max 或
			# 栈内条目<12——_trait_candidates 只查 stack_max 不查 12 条目帽）
			clean.clear()
			for tid in pool:
				var td: TraitData = card_generator.registry.get_trait(tid)
				if td != null and not (td.pool_id in GameConst.PLAYER_SIDE_POOLS) \
						and _can_mount_trait(td, cand_host):
					clean.append(tid)
			if clean.is_empty():
				hosts.remove_at(pick_i)        # 该武器挂不了本类目任何词条 → 换下一把
				continue
			host = cand_host
			break
		if host == null or clean.is_empty():
			continue                           # 无可挂 tid → 跳过本类目
		var tid2: StringName = clean[randi() % clean.size()]
		var t := card_generator.registry.get_trait(tid2)
		if t == null:
			continue
		var target_w := host                   # 展示 target = 售卡 target（同源）
		var rarity := card_generator._roll_rarity(_wave)
		_wares.append(_make_trait_ware(t, target_w, rarity, slot))
		slot += 1
	# R71 货架兜底（用户反馈「后期刷新黑市，没刷出东西」）：后期词条全叠满
	# stack_max → 四类别候选全空 → 货架只剩治疗包。词条槽不足 4 时补「武器强化」货
	#（未满级随机武器 level_up，Lv%d→%d）——有未满级武器则货架永远有货可刷；
	# 全武器满级才让位给治疗包/遗物
	while _wares.size() < 4:
		var up_w := _random_upgradable_weapon()
		if up_w == null:
			break                               # 全满级（真·终局）——不再补位
		var lv_now := int(up_w.get("level"))
		_wares.append({
			"kind": "weapon_up", "data": null, "rarity": 2, "target": up_w,
			"level_from": lv_now, "level_to": mini(lv_now + 1, WeaponBase.MAX_LEVEL),
			"base": 55.0, "mult": market_mult(_wave, 6 + _wares.size()),
		})
	_wares.append({
		"kind": "heal", "data": null, "rarity": 0,
		"base": 30.0, "mult": market_mult(_wave, 4),
	})
	var relics := card_generator._unowned_relic_ids()
	if not relics.is_empty():
		_wares.append({
			"kind": "relic", "data": card_generator.registry.get_relic(
				relics[randi() % relics.size()]),
			"rarity": 2, "base": 90.0, "mult": market_mult(_wave, 5),
		})
	_append_black_market_gold_card()
	# R188-B 终兜底常青货（buyable_count()==0 = 连武器强化都补不进/买不了的真终局）：
	# 上架运行期构造 stack_max=99 应急强化（仿 card_generator._fallback_stat_card，
	# E-08 纪律不落 .tres 不进注册表）——保证每次开店货架存在可购行
	if buyable_count() <= 0:
		_append_evergreen_fallback()


func _make_trait_ware(p_t: TraitData, p_target: WeaponBase, p_rarity: int,
		p_slot: int) -> Dictionary:
	# R199(F12/F13/F14) 黑市词条行构造（自 _reroll_wares 收口成函数，测试可直调）。
	# 品质落值/重写逐条对齐升级卡架 card_generator._apply_rarity_values 口径（只读引用
	# 其方法，不改其源）：
	# · F12 特例重写先问 _rarity_desc_mech（计数取整/护盾除法间隔/死亡新星直乘/元素裂变
	#   lv2 锚——card_generator.gd:250-289），非空才走通用 _scaled_description。黑市此前
	#   漏网：「+1」被写成非整数 +1.4（实得 round 后 +2）、护盾秒数恒 8s/5.5s（实得
	#   8/value）、死亡新星/虚空反应直读 value 而卡面 ×N 式重写，系统性失真；
	# · F12' 元素裂变 value_lv2 随品质同缩（对照 card_generator.gd:167-173；params 浅拷
	#   贝直改会写穿注册表真源 E-08——深复制后改）；
	# · F13 MULT/LOCAL 池上限随品质同缩（对照 card_generator.gd:177-180——「上限=白值」
	#   词条背水协议/反弹谱变的合并上限卡面如实）；
	# · F14 满层质变 ◆ 预告 + 超帽注记双写（对照 card_generator.gd:682-689：行描述与
	#   data 副本描述同追加——文案逐字对齐卡架原文；判据同 _make_trait_card）。
	var scale := float(CardGenerator.RARITY_VALUE_SCALE[clampi(p_rarity, 0, 3)])
	var data := p_t.duplicate() as TraitData
	data.rarity = p_rarity                   # R38 品级字段一致化（白品不再带源金字段）
	var custom_desc := card_generator._rarity_desc_mech(p_t, scale, p_rarity)
	if scale > 1.0:
		data.value = p_t.value * scale
		if data.params.has("value_lv2"):
			data.params = p_t.params.duplicate(true)   # E-08：深复制后改（防写穿 .tres）
			data.params["value_lv2"] = float(p_t.params["value_lv2"]) * scale
		data.description = custom_desc if custom_desc != "" \
			else card_generator._scaled_description(p_t.description, scale, p_rarity)
	if data.pool == GameConst.PoolClass.MULT:
		data.cap_pool_p = p_t.cap_pool_p * scale
	elif data.pool == GameConst.PoolClass.LOCAL:
		data.cap_local = p_t.cap_local * scale
	# F14：目标武器现层数 → 满层质变/超帽预告（判据与卡架 _make_trait_card 同式）
	var cur_layers := 0
	var tstack: Variant = p_target.get("trait_stack")
	if tstack != null and tstack.get("traits") != null:
		for tb: Variant in (tstack.get("traits") as Array):
			var td_e: Variant = tb.get("data")
			if td_e != null and StringName(str(td_e.get("id"))) == p_t.id:
				cur_layers = int(tb.get("layers"))
	var milestone: bool = (MechanicGate.milestone_unlocked() and data.stack_max >= 2
		and cur_layers + 1 >= data.stack_max)
	var overcap := cur_layers >= data.stack_max
	if milestone:
		data.description += "\n◆ 满层质变：该词条全部层数数值 ×1.6！"   # 卡架 :685 原文
	if overcap:
		data.description += "\n" + GameConst.OVERCAP_NOTE
	return {
		"kind": "trait", "data": data, "rarity": p_rarity, "target": p_target,
		"base": 40.0 * scale,
		"mult": market_mult(_wave, p_slot),
		"milestone": milestone, "overcap": overcap,
	}


func _price(p_ware: Dictionary) -> int:
	return int(ceil(float(p_ware["base"]) * float(p_ware["mult"])))


func _random_upgradable_weapon() -> WeaponBase:
	# 未满级武器随机取一（R71 货架兜底数据源；全满级返回 null）
	if _player == null:
		return null
	var slots: Array = _player.get("weapon_slots")
	var pool: Array[WeaponBase] = []
	for w in slots:
		if w != null and is_instance_valid(w) and (w as WeaponBase).data != null \
				and int((w as WeaponBase).get("level")) < WeaponBase.MAX_LEVEL:
			pool.append(w)
	if pool.is_empty():
		return null
	return pool[randi() % pool.size()]


# ── R188-B 可购谓词（公开——供挂机项 R188-3 直接调用，不需逆向解析 _wares） ──
func buyable_count() -> int:
	# 可购行数（与行内 buy.disabled 逐位同口径）：金价可付 + 非 heal 或 heal 未满血
	# + trait 可挂载（形态门 + 栈容量）+ 金卡未满槽
	if _player == null:
		return 0
	var n := 0
	for ware in _wares:
		if not ware.is_empty() and _ware_buyable(ware):
			n += 1
	return n


func has_stock() -> bool:
	# 有无真实可购货（不含金价层——买不起但货真价实仍算有货）：
	# 满血维修包 / 不可挂词条 / 满槽金卡不算有货；空行（已售下架）跳过
	if _player == null:
		return false
	for ware in _wares:
		if ware.is_empty():
			continue
		if _ware_stocked(ware):
			return true
	return false


func can_refresh() -> bool:
	# R195 三口径合一单源谓词（用户反馈「不给刷就别显示」，与 R71 金价层/R188-C 空架层/
	# R189 has_stock 收紧口径逐位同源）：金币可付 + 有货真价实行才可刷。纯只读——
	# 不扣金、不重掷、无副作用（_refresh 可见性联动与测试直调共用一个真源）；
	# 黑市/战前补给共用（零 _pre_boss 分支，两开店源同汇 game_loop 同一入口）。
	# _player!=null 相对 has_stock 的 null 兜底是显式冗余，保留自文档化（勿精简）。
	return _player != null and int(_player.get("gold")) >= refresh_cost() and has_stock()


func _ware_stocked(p_ware: Dictionary) -> bool:
	# 货真价实层（不含金价）：kind 侧可购谓词——buyable_count/has_stock/行置灰共用真源
	if _player == null:
		return false
	match String(p_ware.get("kind", "")):
		"heal":
			# 夜间R6 满血禁购口径（与 _make_ware_row 行内特殊分支同阈值）
			return float(_player.get("hp")) < float(_player.get("max_hp")) - 0.5
		"trait":
			return _can_mount_trait(p_ware.get("data"), p_ware.get("target"))
		"weapon_up":
			var w: Variant = p_ware.get("target")
			# 目标等级复验：行上架后目标经其他路径满级 → 拒买不扣金（level_up 封顶
			# MAX_LEVEL 内——买了不生效的付费空买同源堵法）
			return w != null and is_instance_valid(w) \
				and int(w.get("level")) < WeaponBase.MAX_LEVEL
		"gold_card":
			return _slot_bonus_available()
		_:
			return true                              # relic 等：上架即真货


func _ware_buyable(p_ware: Dictionary) -> bool:
	# 全口径可购（金价层 + 货真价实层）——与行内按钮 disabled / _buy 买前复验同一谓词
	return _player != null and not p_ware.is_empty() \
		and int(_player.get("gold")) >= _price(p_ware) and _ware_stocked(p_ware)


func _can_mount_trait(p_t: TraitData, p_weapon: Variant) -> bool:
	# 词条可挂载复验（与 TraitStack.attach 拒绝线同口径，堵「先扣金 + attach 静默拒」）：
	# ① 形态/武器适配门（R187 mount_gate_allows 统一真源）；② 同 ID 层<stack_max，
	# 或新条目时栈内条目<12（TraitStack.MAX_TRAITS——_trait_candidates 不查这道帽）
	if p_t == null or p_weapon == null or not (p_weapon is WeaponBase) \
			or not is_instance_valid(p_weapon):
		return false
	if not CardGenerator.mount_gate_allows(p_t, p_weapon):
		return false
	var tstack: Variant = p_weapon.get("trait_stack")
	if tstack == null or tstack.get("traits") == null:
		return true                                  # 空栈恒可挂（防御）
	var entries: Array = tstack.get("traits")
	for tb: Variant in entries:
		var td: Variant = tb.get("data")
		if td != null and StringName(str(td.get("id"))) == p_t.id:
			# R196 有意契约变更：ADD 池帽放宽至 stack_max + OVERCAP_EXT_MAX（超质变叠层，
			# 与 TraitStack.attach 拒绝线同口径）；非 ADD 池保持原帽
			var cap: int = p_t.stack_max \
				+ (TraitStack.OVERCAP_EXT_MAX if p_t.pool == GameConst.PoolClass.ADD else 0)
			return int(tb.get("layers")) < cap
	return entries.size() < TraitStack.MAX_TRAITS


func _slot_bonus_available() -> bool:
	# 金卡上架/复验门：帽内还有可提前解锁的槽（满槽不上架不收钱——R185 语义）
	if _player == null or not is_instance_valid(_player):
		return false
	if not _player.has_method(&"slot_cap_total"):
		return false
	return int(_player.get("unlocked_slots")) < int(_player.call(&"slot_cap_total"))


func refresh_count_used() -> int:
	# 本次开店已刷新次数读口（GameLoop 挂机自动出货「玩家手动刷新即重置倒计时」消费）
	return _refresh_count


func purchase_count() -> int:
	# 本次开店已购买次数读口（R188-idle：玩家手动买货 → GameLoop 重置自动出击倒计时）
	return _purchase_count


# ── R188-B 终兜底 / 金卡行 ────────────────────────────────────────
func _append_black_market_gold_card() -> void:
	# REL_BLACK_MARKET 金卡行：价读 .tres params.gold_card_price（数据驱动无硬编码），
	# 走 CardKind.SLOT_BONUS 通道（card_generator._make_slot_bonus_card + apply_choice）；
	# 未持有遗物或帽内已满槽 → 不上架不收钱
	if card_generator == null or _player == null:
		return
	if not card_generator.owned_relics.has(&"REL_BLACK_MARKET"):
		return
	if not _slot_bonus_available():
		return
	var bm_price := 260
	var bm: RelicData = card_generator.registry.get_relic(&"REL_BLACK_MARKET") \
		if card_generator.registry != null else null
	if bm != null:
		bm_price = maxi(int(bm.params.get("gold_card_price", 260)), 1)
	_wares.append({
		"kind": "gold_card", "data": null, "rarity": 3,
		"base": float(bm_price), "mult": 1.0,    # 金卡一口价——不走行情漂移
	})


func _append_evergreen_fallback() -> void:
	# 终兜底常青货：运行期构造 stack_max=99 应急强化（仿 card_generator._fallback_stat_card
	# 的 FALLBACK_ATK——同 id 同池，与升级卡池的保底卡天然同层叠加；E-08 纪律：
	# 内存对象，不落 .tres 不进注册表）。宿主容量感知：选可挂武器。
	# R189 死角修复（评审#9）：全武器栈 12/12 满且无 FALLBACK_ATK 层时任何宿主都
	# 挂不上——原「回退 _primary_weapon 照样上架」会造出置灰死行（buyable 依旧 0，
	# 且非空行使刷新钮可点 → 死架纯烧金）。改为：无任何可挂宿主 → 不上架死货；
	# 此时货架若整体无货真价实行（has_stock()==false）刷新钮一并禁刷（R195 起置灰改
	# 原位隐藏），金币不烧。
	if _player == null:
		return
	var data := TraitData.new()
	data.id = &"FALLBACK_ATK"
	data.display_name = "应急强化"
	data.description = "攻击力 +5%"
	data.pool = GameConst.PoolClass.ADD
	data.pool_id = &"add_atk"
	data.effect_id = &"EF_STAT"
	data.value = CardGenerator.FALLBACK_ATK_PCT
	data.decay_delta = 0.85
	data.params = {"stat": "atk_pct"}
	data.stack_max = 99                           # 终兜底：永不满层（应急通道）
	data.rarity = 0
	var host: WeaponBase = null
	for w in _player.get("weapon_slots"):
		if w is WeaponBase and is_instance_valid(w) and _can_mount_trait(data, w):
			host = w
			break
	if host == null and card_generator != null:
		var primary: WeaponBase = card_generator._primary_weapon(_player)
		if primary != null and _can_mount_trait(data, primary):
			host = primary                          # 兜底宿主必须复验可挂——不可挂不虚设死行
	if host == null:
		return                                      # R189：全栈饱和真终局——宁缺毋滥（死行=烧金入口）
	_wares.append({
		"kind": "trait", "data": data, "rarity": 0, "target": host,
		"base": 25.0, "mult": 1.0,               # 常青保底一口价（全货架最低位）
		"evergreen": true,                       # 购买走 CardKind.FALLBACK 通道（不入词条图鉴）
	})


# ── 购买 ──────────────────────────────────────────────────────────
func _buy(p_index: int) -> void:
	if p_index >= _wares.size() or _player == null:
		return
	var ware: Dictionary = _wares[p_index]
	if ware.is_empty():
		return
	# R188-A 买前同口径复验（堵 shop_ui 旧链「先扣金 + attach 静默拒」的付费空买）：
	# 与行内按钮 disabled 同一谓词——不可挂/满血/满槽/买不起一律不扣金
	if not _ware_buyable(ware):
		return
	var price := _price(ware)
	_player.set("gold", int(_player.get("gold")) - price)
	_purchase_count += 1
	match String(ware["kind"]):
		"trait", "relic":
			var card := {
				"kind": (CardGenerator.CardKind.FALLBACK if bool(ware.get("evergreen", false))
					else CardGenerator.CardKind.TRAIT) if String(ware["kind"]) == "trait"
					else CardGenerator.CardKind.RELIC,
				"id": ware["data"].id, "rarity": int(ware["rarity"]),
				"data": ware["data"], "value_scale": 1.0,
				"display_name": ware["data"].display_name,
				"description": ware["data"].description,
				# R188-A：展示=实挂（apply_choice 消费 target_weapon——card_generator.gd
				# 挂载分支已支持；无此键时退随机选宿主，展示与实挂漂移的旧根因）
				"target_weapon": ware.get("target"),
			}
			card_generator.apply_choice(card, _player)
		"heal":
			_player.set("hp", minf(float(_player.get("hp")) + float(_player.get("max_hp")) * 0.4,
				float(_player.get("max_hp"))))
		"weapon_up":
			# R71 兜底货：直接升 1 级（WeaponBase.level_up 封顶在 MAX_LEVEL 内）
			var up_target: Variant = ware.get("target")
			if up_target != null and is_instance_valid(up_target) \
					and up_target.has_method(&"level_up"):
				up_target.call(&"level_up")
		"gold_card":
			# R188-B 黑市金卡：SLOT_BONUS 通道复用（提前解锁帽内下一槽；上架与买前
			# 已过 _slot_bonus_available 门——apply_choice 侧 grant_slot_bonus 幂等兜底）
			card_generator.apply_choice(card_generator._make_slot_bonus_card(), _player)
	_wares[p_index] = {}                          # 售出下架
	_refresh()


func refresh_cost() -> int:
	# 刷新价 = 15 × 行情系数 × 1.5^已刷新次数（R7 用户反馈「应倍数提升，不该固定 15」：
	# 同一次开店内累进 15→23→34→51…，关店重置）
	return int(ceil(15.0 * market_mult(_wave, 9) * pow(1.5, float(_refresh_count))))


func _on_refresh_pressed() -> void:
	var cost := refresh_cost()
	if _player != null and int(_player.get("gold")) >= cost:
		_player.set("gold", int(_player.get("gold")) - cost)
		_refresh_count += 1
		_reroll_wares(true)
		_refresh()


func _on_leave_pressed() -> void:
	close()


# ── UI 组装 ───────────────────────────────────────────────────────
func _build_ui() -> void:
	_root = Control.new()
	_root.name = "ShopRoot"
	_root.theme = StickerTheme.theme()
	_root.set_anchors_preset(Control.PRESET_FULL_RECT)  # R195 安全区内缩见 _apply_safe_area
	_root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_root)
	var dim := ColorRect.new()
	dim.color = PopPalette.DIM
	dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	dim.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_root.add_child(dim)
	var card := Panel.new()
	card.name = "ShopCard"
	card.add_theme_stylebox_override("panel", StickerTheme.panel_style(24.0, 4, true))
	# R195 适配锚定（恒等校准）：黑市卡设计位 (44,150)632×950 → 父居中锚，offset =
	# 卡矩形 − 设计中心 (360,640)（中心偏移 (0,−15) 内含于 top/bottom）；默认窗
	# 720×1280 下落位逐位不变，卡内子件父相对零改动（scroll/刷新钮/出击钮几何红线原值）
	card.anchor_left = 0.5
	card.anchor_top = 0.5
	card.anchor_right = 0.5
	card.anchor_bottom = 0.5
	card.offset_left = -316.0                      # 44 − 360
	card.offset_top = -490.0                       # 150 − 640
	card.offset_right = 316.0                      # 676 − 360
	card.offset_bottom = 460.0                     # 1100 − 640
	card.pivot_offset = Vector2(316.0, 475.0)      # 原 size*0.5 恒等（卡片动画中心）
	card.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_root.add_child(card)
	var title := Label.new()
	StickerTheme.label_sticker(title, 30, PopPalette.INK, 0, Color.WHITE, true)
	title.text = "战地黑市"
	title.position = Vector2(0.0, 30.0)
	title.size = Vector2(632.0, 40.0)
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	card.add_child(title)
	_title = title
	_gold_label = Label.new()
	StickerTheme.label_sticker(_gold_label, 19, PopPalette.XP, 0, Color.WHITE, true)
	_gold_label.text = "金币 0"
	_gold_label.position = Vector2(0.0, 74.0)
	_gold_label.size = Vector2(632.0, 26.0)
	_gold_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	card.add_child(_gold_label)
	var scroll := ScrollContainer.new()
	scroll.position = Vector2(28.0, 116.0)
	scroll.size = Vector2(576.0, 700.0)
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	card.add_child(scroll)
	_list = VBoxContainer.new()
	_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_list.add_theme_constant_override("separation", 10)
	scroll.add_child(_list)
	var refresh_btn := Button.new()
	refresh_btn.name = "ShopRefreshButton"
	refresh_btn.add_theme_font_size_override("font_size", 17)
	refresh_btn.add_theme_font_override("font", StickerTheme.font_bold())
	refresh_btn.position = Vector2(211.0, 802.0)   # R194 触控目标放大 210×56（下移 4px，与出击钮 868 仍留 10px 空隙）
	refresh_btn.size = Vector2(210.0, 56.0)
	refresh_btn.pressed.connect(_on_refresh_pressed)
	refresh_btn.button_down.connect(func() -> void: StickerTheme.press_punch(refresh_btn))
	card.add_child(refresh_btn)
	var leave_btn := Button.new()
	leave_btn.name = "ShopLeaveButton"
	leave_btn.text = "出击！"
	leave_btn.add_theme_font_size_override("font_size", 20)
	leave_btn.add_theme_font_override("font", StickerTheme.font_bold())
	leave_btn.position = Vector2(211.0, 868.0)
	leave_btn.size = Vector2(210.0, 60.0)
	leave_btn.pressed.connect(_on_leave_pressed)
	leave_btn.button_down.connect(func() -> void: StickerTheme.press_punch(leave_btn))
	card.add_child(leave_btn)


func _refresh() -> void:
	_gold_label.text = "金币 %d　·　第 %d 波行情" % [int(_player.get("gold")) if _player != null else 0, _wave]
	for c in _list.get_children():
		(c as Node).queue_free()
	var idx := 0
	for ware in _wares:
		if ware.is_empty():
			idx += 1
			continue
		_list.add_child(_make_ware_row(idx, ware))
		idx += 1
	var refresh_btn := _root.get_node("ShopCard/ShopRefreshButton") as Button
	refresh_btn.text = "刷新货架 (%d)" % refresh_cost()
	# 价签保持无条件刷新：隐藏期也保新价，重显不闪旧价（R195 契约）。
	# R71（用户反馈「刷新黑市没刷出东西」的另一半：金币不足时按钮静默无效——点了
	# 没有任何反馈）。与购买按钮同口径：买不起就禁点（刷新价 15×1.5ⁿ 后期轻松上百金）。
	# R188-C 窄口径补位：_wares 全空行（全部售罄的死架）也禁刷——纯烧金重掷无意义；
	# 有货可掷时刷新保留，15×market_mult×1.5ⁿ 价曲线不动。
	# R189（评审#9）：禁刷口径从「全空行」收紧为「无货真价实行」has_stock()==false——
	# 行存在但全部不可购（词条栈满/满血/满槽/Lv5）的重掷同样烧金无所得，一并禁刷。
	# R195 演进（用户反馈 tracker「不给刷就别显示」）：置灰→原位隐藏（visible=false
	# 留空，可刷恢复）。三口径合一为 can_refresh() 单源谓词（与上述 R71/R188-C/R189
	# 逐位同源），随 _refresh() 三入口（open/_buy/_on_refresh_pressed）全状态覆盖；
	# 黑市/战前补给共用。disabled 写点删净——disabled 与 visible 不并存，禁止
	# 「既灰又藏」混合态（几何 (211,802)210×56 原值不动，仅 visible 翻转）。
	refresh_btn.visible = can_refresh()


func _make_ware_row(p_index: int, p_ware: Dictionary) -> Control:
	var kind := String(p_ware["kind"])
	var rarity := int(p_ware["rarity"])
	var price := _price(p_ware)
	# R188-A 行内可购口径统一走 _ware_buyable（金价 + 满血/可挂载/满槽同谓词）：
	# 词条行目标武器栈满/形态不合 → 按钮直接置灰（与 _buy 买前复验同源）
	var affordable: bool = _ware_buyable(p_ware)
	var row := Panel.new()
	row.add_theme_stylebox_override("panel", StickerTheme.panel_style(12.0, 2, false))
	row.custom_minimum_size = Vector2(576.0, 86.0)
	row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var name_l := Label.new()
	StickerTheme.label_sticker(name_l, 17, PopPalette.rarity_color(rarity)
		if kind == "trait" or kind == "gold_card" else PopPalette.INK, 0, Color.WHITE, true)
	var display := ""
	var desc := ""
	match kind:
		"trait":
			var td: TraitData = p_ware["data"]
			var tw: Object = p_ware.get("target")
			var wtag := ("【%s】" % card_generator._weapon_short_name(tw)) if tw != null else ""
			# F14(R199)：满层质变行名 ◆ 前缀（对齐卡架 card_generator.gd:673-674 口径）
			var ms_prefix := "◆质变◆" if bool(p_ware.get("milestone", false)) else ""
			display = ms_prefix + wtag + String(td.display_name)
			desc = String(td.description)
		"relic":
			var rd: RelicData = p_ware["data"]
			display = String(rd.display_name) if rd != null else "遗物"
			desc = String(rd.description) if rd != null else ""
		"heal":
			display = "维修包"
			desc = "回复 40% 最大生命"
		"gold_card":
			# R188-B 黑市金卡（REL_BLACK_MARKET 特供）：SLOT_BONUS 同义卡面
			display = "金卡 · 武器槽 +1"
			desc = "提前解锁下一个武器槽（黑市特供一口价；总槽位数不变）"
		"weapon_up":
			# R71 兜底货：后期词条池枯竭时的常青货（武器永远可升到 MAX_LEVEL）
			var uw := p_ware.get("target") as WeaponBase
			var uname := card_generator._weapon_short_name(uw)
			display = "武器强化【%s】" % uname
			desc = "Lv%d→Lv%d：按升级表成长（攻击/弹速等）" % [
				int(p_ware.get("level_from", 0)), int(p_ware.get("level_to", 0))]
	var trend := "—"
	if float(p_ware["mult"]) > 1.08:
		trend = "▲ 行情高"
	elif float(p_ware["mult"]) < 0.92:
		trend = "▼ 行情低（抄底）"
	name_l.text = display + "　" + trend
	name_l.position = Vector2(16.0, 10.0)
	name_l.size = Vector2(400.0, 26.0)
	name_l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_child(name_l)
	var desc_l := Label.new()
	StickerTheme.label_sticker(desc_l, 13, PopPalette.INK_SOFT)
	desc_l.text = desc
	desc_l.position = Vector2(16.0, 38.0)
	desc_l.size = Vector2(400.0, 34.0)
	desc_l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	desc_l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_child(desc_l)
	var buy := Button.new()
	buy.text = "%d 金币" % price
	buy.add_theme_font_size_override("font_size", 15)
	buy.add_theme_font_override("font", StickerTheme.font_bold())
	buy.position = Vector2(440.0, 16.0)          # R194 触控目标放大 132×56（行高 86 内居中）
	buy.size = Vector2(132.0, 56.0)
	buy.focus_mode = Control.FOCUS_NONE
	buy.disabled = not affordable
	# 夜间R6：满血禁购维修包（此前满血仍可买=白花金币，无提示）
	if kind == "heal" and _player != null 			and float(_player.get("hp")) >= float(_player.get("max_hp")) - 0.5:
		buy.disabled = true
		buy.text = "已满血"
	buy.pressed.connect(_buy.bind(p_index))
	buy.button_down.connect(func() -> void: StickerTheme.press_punch(buy))
	row.add_child(buy)
	return row
