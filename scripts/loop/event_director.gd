# scripts/loop/event_director.gd
# v0.8.0 EventDirector（A7 §V2/V3/V4 事件运行时；对齐 relic/chip/curse handler 模式）。
# · 四事件（金币面额全为基础值，入账走 GameLoop._add_gold 吃 K_gold；文案带「（基础值）」）：
#   EV_ALTAR 血色祭坛 / EV_TABLE 命运赌桌 / EV_MERCHANT 深渊商人 / EV_SHRINE 寂静神龛。
# · rng：自有 rng seed 888（reset_run 重播种）——赌桌 50% 判定专用（不借金币流/卡牌流）；
#   神龛遗物 roll 用卡牌流（同卡架口径）。
# · 效果两类（A7 冻结）：EV_EF_GRANT_CARD{floor} → 三选一管线单抽 + apply_choice；
#   EV_EF_GOLD_CURSE{gold,gambler,curse} → 金币经 _add_gold / gambler 逐次挂赌徒诅咒词条 /
#   curse 深渊层 add_curse（钳后）。
# · build_event 附 available 布尔（祭坛 HP 不足/赌桌金币<60/商人满层 → false，EventUI 禁用）。
class_name EventDirector
extends Node

const EVENT_RNG_SEED: int = 888                # 事件 rng（赌桌判定专用）
const TABLE_WIN_CHANCE: float = 0.50           # 赌桌翻倍判定
# 四事件表（label/detail 文案 + 效果参数；gold 全为「基础值」语义）
const EVENTS: Array[Dictionary] = [
	{
		"id": &"EV_ALTAR", "title": "血色祭坛",
		"desc": "古老的祭坛在黑暗中低语，渴望一份鲜血的贡品。",
		"options": [
			{"label": "献祭（−20% 当前 HP）", "detail": "奉献血肉，换取一枚紫色品质的卡片",
				"effect": &"sacrifice_card", "floor": 2, "hp_cost_pct": 0.2},
			{"label": "沐浴（满血 +50 金·基础值）", "detail": "受祭坛庇护，回复全部生命",
				"effect": &"heal_gold", "gold": 50},
		],
	},
	{
		"id": &"EV_TABLE", "title": "命运赌桌",
		"desc": "骰子在斑驳的桌面上旋转，命运悬于一线。",
		"options": [
			{"label": "下注（付 60 金）", "detail": "50% 翻倍得 120 金·基础值，否则全失",
				"effect": &"gamble", "stake": 60, "payout": 120},
			{"label": "孤注一掷（诅咒 +2）", "detail": "向深渊赊借 150 金·基础值",
				"effect": &"gold_curse", "gold": 150, "curse": 2},
		],
	},
	{
		"id": &"EV_MERCHANT", "title": "深渊商人",
		"desc": "兜帽下的商人拨弄着刻痕分明的金币。",
		"options": [
			{"label": "小额交易（诅咒 +1）", "detail": "换取 120 金·基础值",
				"effect": &"gold_curse", "gold": 120, "curse": 1},
			{"label": "大额交易（诅咒 +2）", "detail": "换取 260 金·基础值",
				"effect": &"gold_curse", "gold": 260, "curse": 2},
		],
	},
	{
		"id": &"EV_SHRINE", "title": "寂静神龛",
		"desc": "尘封的神龛中似乎遗落着什么。",
		"options": [
			{"label": "参拜（随机遗物）", "detail": "获得一件未持有的遗物（池空 → 50 金·基础值）",
				"effect": &"relic"},
			{"label": "离开（+30 金·基础值）", "detail": "拾起供桌上的零钱",
				"effect": &"gold", "gold": 30},
		],
	},
]

var registry: DataRegistry = null              # 注入（遗物 id → RelicData）
var player: Player = null                      # 注入（HP 满血/祭坛贡品宿主）
var card_generator: CardGenerator = null       # 注入（赐卡管线 + 诅咒词条构造 + 遗物 roll 流）
var curse_handler: CurseHandler = null         # 注入（深渊层 add_curse）
var chip_handler: ChipHandler = null           # 注入（主武器定位口径预留）
var popup_manager: PopupManager = null         # 注入（文本跳字）
var game_loop: GameLoop = null                 # 注入（金币 _add_gold 唯一口）
# ── 遥测（测试观测口） ──
var events_triggered: int = 0                  # 事件选项成功执行次数
var cards_granted: int = 0                     # 祭坛赐卡次数
var gold_granted_base: int = 0                 # 基础值金币发放累计（含赌桌赢面）
var curses_from_events: int = 0                # 事件深渊层累计

var _event_rng: RandomNumberGenerator = RandomNumberGenerator.new()   # 赌桌判定流（seed 888）


func setup(p_deps: Dictionary) -> void:
	# Boot 注入（GameLoop._boot_build_presentation 段）
	registry = p_deps.get("registry")
	player = p_deps.get("player")
	card_generator = p_deps.get("card_generator")
	curse_handler = p_deps.get("curse_handler")
	chip_handler = p_deps.get("chip_handler")
	popup_manager = p_deps.get("popup_manager")
	game_loop = p_deps.get("game_loop")
	reset_run()


func reset_run() -> void:
	# 重开清零（GameLoop._reset_run_state 调用）：遥测清零 + rng 重播种
	events_triggered = 0
	cards_granted = 0
	gold_granted_base = 0
	curses_from_events = 0
	_event_rng.seed = EVENT_RNG_SEED


func event_count() -> int:
	return EVENTS.size()


func build_event(p_index: int) -> Dictionary:
	# 事件构建（EventUI.open 消费）：{id,title,desc,options:[{label,detail,available}]}；
	# 越界钳到 [0, count-1]。available：祭坛 HP 不足 / 赌桌金币<60 / 商人满层 → false。
	var idx := clampi(p_index, 0, EVENTS.size() - 1)
	var src: Dictionary = EVENTS[idx]
	var options: Array = []
	for raw in src["options"]:
		var option: Dictionary = (raw as Dictionary).duplicate()
		option["available"] = _option_available(idx, option)
		options.append(option)
	return {
		"id": src["id"],
		"title": src["title"],
		"desc": src["desc"],
		"options": options,
	}


func apply_option(p_event_index: int, p_option: int) -> Dictionary:
	# 选项应用（GameLoop._on_event_choice 仲裁后调用）：{ok, message}；效果两类分派。
	var out := {"ok": false, "message": ""}
	if p_event_index < 0 or p_event_index >= EVENTS.size():
		return out
	var src: Dictionary = EVENTS[p_event_index]
	var options: Array = src["options"]
	if p_option < 0 or p_option >= options.size():
		return out
	var option: Dictionary = options[p_option]
	if not _option_available(p_event_index, option):
		out["message"] = "选项当前不可用"
		return out
	match StringName(String(option.get("effect", ""))):
		&"sacrifice_card":
			out = _apply_sacrifice_card(option)
		&"heal_gold":
			out = _apply_heal_gold(option)
		&"gamble":
			out = _apply_gamble(option)
		&"gold_curse":
			out = _apply_gold_curse(option)
		&"relic":
			out = _apply_relic()
		&"gold":
			out = _apply_gold(int(option.get("gold", 0)), "拾获 %d 金币（基础值）")
		_:
			out["message"] = "未知效果"
			return out
	if bool(out.get("ok", false)):
		events_triggered += 1
	return out


# ── 内部：效果实现 ────────────────────────────────────────────────
func _option_available(p_event_index: int, p_option: Dictionary) -> bool:
	# available 判定（build/apply 双侧共用）：祭坛 HP 不足（钳后≤1 无法再献）/ 赌桌金币<60 /
	# 商人满层 → false
	match StringName(String(p_option.get("effect", ""))):
		&"sacrifice_card":
			return player != null and player.hp > 1.0
		&"gamble":
			return game_loop != null and game_loop.gold >= int(p_option.get("stake", 0))
		&"gold_curse":
			return curse_handler != null and not curse_handler.is_maxed()
	return true


func _apply_sacrifice_card(p_option: Dictionary) -> Dictionary:
	# 献祭 20% 当前 HP（钳后 ≥1）→ min_rarity_floor 卡单抽 + apply_choice → 跳字「祭坛赐卡：[名]」
	var cost: float = maxf(player.hp * float(p_option.get("hp_cost_pct", 0.2)), 1.0)
	player.hp = maxf(player.hp - cost, 1.0)
	var wave := 1
	if game_loop != null and game_loop.wave_director != null:
		wave = game_loop.wave_director.current_wave
	var cards := card_generator.generate_candidates({
		"player": player, "wave": wave,
		"min_rarity_floor": int(p_option.get("floor", 2)),
	})
	var card: Dictionary = cards[0]
	card_generator.apply_choice(card, player)
	cards_granted += 1
	var msg := "祭坛赐卡：%s" % String(card.get("display_name", ""))
	_popup(msg)
	return {"ok": true, "message": msg}


func _apply_heal_gold(p_option: Dictionary) -> Dictionary:
	# 沐浴：满血 + 基础值金币
	player.hp = player.max_hp
	var gold := int(p_option.get("gold", 0))
	var msg := ""
	if gold > 0 and game_loop != null:
		game_loop._add_gold(gold)
		gold_granted_base += gold
		msg = "沐浴净化：满血 + %d 金币（基础值）" % gold
		_popup(msg)
	else:
		msg = "沐浴净化：生命全部回复"
	return {"ok": true, "message": msg}


func _apply_gamble(p_option: Dictionary) -> Dictionary:
	# 下注：付 stake → 50%（自有 rng 888）翻倍 payout 或全失
	var stake := int(p_option.get("stake", 0))
	var payout := int(p_option.get("payout", 0))
	if game_loop == null or game_loop.gold < stake:
		return {"ok": false, "message": "金币不足"}
	game_loop._add_gold(-stake)
	if _event_rng.randf() < TABLE_WIN_CHANCE:
		game_loop._add_gold(payout)
		gold_granted_base += payout
		var win := "命运眷顾：+ %d 金币（基础值）" % payout
		_popup(win)
		return {"ok": true, "message": win}
	var lose := "骰子背弃：60 金币尽失"
	_popup(lose)
	return {"ok": true, "message": lose}


func _apply_gold_curse(p_option: Dictionary) -> Dictionary:
	# 金币 + 深渊层（add_curse 钳后跳字「诅咒层 n/5」）；gambler>0 → 主武器逐次挂赌徒诅咒词条
	var gold := int(p_option.get("gold", 0))
	var curse := int(p_option.get("curse", 0))
	var gambler := int(p_option.get("gambler", 0))
	var actual := 0
	if curse > 0 and curse_handler != null:
		actual = curse_handler.add_curse(curse)
		if actual <= 0:
			return {"ok": false, "message": "诅咒已满 5 层"}
		curses_from_events += actual
	if gambler > 0 and card_generator != null:
		var weapon := card_generator._primary_weapon(player)
		if weapon != null:
			for i in range(gambler):
				weapon.attach_trait(card_generator._make_curse_trait())
	if gold > 0 and game_loop != null:
		game_loop._add_gold(gold)
		gold_granted_base += gold
	var msg := "深渊契约成立：+ %d 金币（基础值）" % gold \
		if gold > 0 else "深渊注视着你"
	if curse_handler != null and curse > 0:
		msg += "｜诅咒层 %d/5" % curse_handler.curse_count
		_popup("诅咒层 %d/5" % curse_handler.curse_count)
	return {"ok": true, "message": msg}


func _apply_relic() -> Dictionary:
	# 参拜：未持有遗物排除后 roll（卡牌流）→ relic_handler.activate 口径；池空 → fallback 50 金
	if registry == null or card_generator == null or game_loop == null:
		return {"ok": false, "message": "遗物数据缺失"}
	var relic_handler: RelicHandler = game_loop.relic_handler
	var unowned: Array[StringName] = []
	for rid in registry.relics:
		if relic_handler == null or not relic_handler.has_relic(rid):
			unowned.append(rid)
	if unowned.is_empty():
		game_loop._add_gold(50)
		gold_granted_base += 50
		var fallback := "神龛空空：+ 50 金币（基础值）"
		_popup(fallback)
		return {"ok": true, "message": fallback}
	var rid: StringName = unowned[card_generator.rng.randi_range(0, unowned.size() - 1)]
	var data := registry.get_relic(rid)
	if relic_handler != null:
		relic_handler.activate(rid)
	var msg := "神龛赐福：遗物 [%s]" % (data.display_name if data != null else String(rid))
	_popup(msg)
	return {"ok": true, "message": msg}


func _apply_gold(p_gold: int, p_template: String) -> Dictionary:
	# 通用基础值金币入账（神龛离开 +30 等）
	if p_gold <= 0 or game_loop == null:
		return {"ok": false, "message": "无效果"}
	game_loop._add_gold(p_gold)
	gold_granted_base += p_gold
	var msg := p_template % p_gold
	_popup(msg)
	return {"ok": true, "message": msg}


func _popup(p_text: String) -> void:
	if popup_manager != null and player != null and is_instance_valid(player):
		popup_manager.show_text_popup(player.global_position + Vector2(0.0, -60.0), p_text)
