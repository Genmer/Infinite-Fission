# scripts/cards/card_select_ui.gd
# M-17 CardSelectUI（架构 §2.16）：选卡界面。
# process_mode = ALWAYS（tree.paused 冻结战斗时界面可用，AC-16.2）；仅 LEVEL_UP 状态可见。
# open()：GameLoop 仲裁后调用（E-16：死亡优先，GameOver 丢弃升级请求）；choice_made →
# CardGenerator.apply_choice → EventBus.emit_card_chosen → close() 请求恢复 → GameLoop 回 PLAYING。
# 方向 C「晴空糖果」贴纸卡牌：白卡 + 稀有度色顶带 + 类型圆章（ADD 菱/MULT 三角/LOCAL 方/
# MECH 六边/ELEM 圆环）+ 稀有度层级圆点 + 出场果冻弹跳（错峰）。
class_name CardSelectUI
extends CanvasLayer

signal choice_made(cards: Array)              # → GameLoop 逐张 apply_choice（R72 成对：同行两张；普通=单元素）
signal reroll_requested()                     # → GameLoop 仲裁（消耗刷新次数 + 重新发牌，2026-08-31）

var is_open: bool = false                     # 界面可见状态（GameLoop 状态联动）

var _root: Control = null
var _buttons: Array[Button] = []              # 卡牌宿主按钮（点击域；卡面为子节点贴纸装）
var _cards: Array[Dictionary] = []            # 当前货架（open 注入）
var _title: Label = null
var _card_faces: Array[Dictionary] = []       # 卡面子件 {band, stamp, kind, name, desc, dots}
var _reroll_btn: Button = null                # 换一批按钮（刷新机制；次数由 GameLoop 注入）

# R246：第 7 位「升华」对应 CardKind.SUBLIME=6（红品质「技能升华」卡——cards 泳道
# 枚举追加位，本表按位跟进；类别行 :247-248 单源拼接自动出「升华 · 传说」）
const KIND_NAMES: Array[String] = ["精通", "词条", "遗物", "保底", "新武器", "槽位", "升华"]
const CARD_SIZE := Vector2(600.0, 180.0)
const CARD_X := 60.0
const CARD_TOP := 264.0                       # 首卡 y（错峰果冻出场基准）
const CARD_STEP := 196.0                      # 卡距（含 16px 间隙）
# R72 成对抉择（地狱/困难 5%）：2 列 ×3 行 6 卡，点任一张 = 带走同行两张
const DUAL_CARD_SIZE := Vector2(324.0, 176.0)
const DUAL_X := [24.0, 372.0]                 # 双列 x
const DUAL_TOP := 300.0
const DUAL_STEP := 196.0
# R199(P05/P06/F15) 描述区自适应扩容的几何帽与栈重排参数（只改几何，零交互改动）：
# 卡体可随描述扩高，上限保证 4 卡栈 / 3 行双列在最坏全扩高时经间隙压缩仍落 720×1280 内
const CARD_H_MAX := 250.0                     # 普通卡高帽（4 卡栈 264..1272 红线内）
const DUAL_H_MAX := 310.0                     # 成对卡高帽（3 行 300..1272 红线内）
const STACK_GAP := 16.0                       # 卡距间隙（= CARD_STEP − CARD_SIZE.y 基准）
const DUAL_STACK_GAP := 20.0                  # 成对行距间隙（= DUAL_STEP − DUAL_CARD_SIZE.y）
const STACK_BOTTOM_MAX := 1272.0              # 卡栈下缘红线（1280 − 8px 余量）

var _dual: bool = false                       # 当前货架是否成对模式
var _highlight_slots: Array[int] = []         # R188-3 挂机预选描金槽位（highlight_candidate 落值；close 清除）

# ── R212 刀1：_fit_desc 量测结果静态缓存（全平台） ─────────────────────
# vc18 真机取证：升级/选卡瞬间 UI 段尖峰 77-247ms、感段 110-138ms、玩段 26-164ms
# 同源同帧——每 open 最多 4卡×7=28 / 6卡×5=30 次全中文 get_multiline_string_size
# wrap 量测（SystemFont 六级回退链在 Android 全 miss 落 sans-serif，单次排版远贵于
# 桌面）。键 = 描述文本+可用宽+紧凑位+行距（同键结果确定性一致——StickerTheme.font()
# 惰性缓存后字体实例不变），命中直返：同文案二次 open/reroll/连升重开零量测。
# 常驻卡文案有限（卡池文本 × 稀有度数值重写型），无淘汰必要；两计数器为测试观测口
#（r212_carddigest 断言「同文案重开新增量测 ==0 / 全新 open ≤30」）。
static var _fit_desc_cache: Dictionary = {}   # 键串 -> {fs, need}
static var fit_desc_measures: int = 0         # 观测口：get_multiline_string_size 实测次数（含梯底兜底）
static var fit_desc_cache_hits: int = 0       # 观测口：缓存命中次数

# ── 二cv#8 帧率：开窗卡片构建分帧（mobile 门） ────────────────────────
# vc48 真机尖峰开 40-47ms=每次升级开窗级联（generate_candidates+可能整段 reroll 二次
# 生成+change_state+本 open 逐卡装配）单帧；成长期升级以秒计频次，单次 40ms 级吞 2-3
# 帧→fps 均值塌陷再回弹（vc48 震荡形态）。刀=mobile 门内本帧只装配前 CARD_SPLIT_FIRST
# 张，余卡 _process 预算闸内续建。真链零感知：LEVEL_UP 态玩家输入被覆盖层挡住；R188
# 自动选卡窗 0.5s ≫ 续建 1-2 帧；choose/highlight_candidate 读 _cards 数据面不读按钮面。
static var card_split_override: int = -1      # 测试注入口（pool_valve_override 先例）：
                                              # -3=模拟 mobile（headless 驱分帧臂）/-2=强制关
const CARD_SPLIT_FIRST := 3                   # 首帧先出卡数（4/6 卡货架余 1/3 张续建）
const CARD_BUILD_BUDGET_US := 8000            # 续建单帧预算闸 µs（R212 刀4 8ms 同形）
var _build_left: int = 0                      # 待续建卡数（>0=分帧中；open 复位/close 清零）


static func _card_split_on() -> bool:
	# 二cv#8 帧率门：mobile（哨兵同 _pool_valve_on 款：-2 恒关/-3 模拟真机）。不挂
	# 帧率档——升级开窗频次以秒计、分帧恒比整帧级联便宜（vc48 调3 全程尖峰开在册，
	# 挂档反而在 tier3 冻结态失能）。
	# R267 刀P2②：桌面翻门——缺省档全平台开分帧（vc71 用户体验「还是卡」升级弹卡
	# 19-33ms 桌面实测在案；桌面分帧缝见 _card_split_hide_tail 注——真机/mobile 行为
	# 零变化）。-2 强制关 / -3 模拟 mobile（隐卡整卡分帧原口径）注入口保留供测试。
	if card_split_override == -2:
		return false
	return true


static func _card_split_hide_tail() -> bool:
	# R267 刀P2②：分帧缝选档——mobile（含 -3 模拟）= 原整卡隐卡分帧口径（vc48 已验证
	# 路径零变化）；桌面 = 整卡同步装配（含顶带/名字/圆点/描述文本——全部廉价面），
	# 仅 _fit_desc 量测与变高几何（get_multiline_string_size 是级联尾段大头）延后到
	# _process 续建。桌面缝保同步廉价读（卡面名色/圆点显隐等既有测试口径）零破坏。
	if card_split_override == -3:
		return true
	return OS.has_feature("mobile")


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	_build_ui()
	# R195 适配：安全区接入（底座组 SafeAreaHelper 单点引用，不复写）。守卫外
	# （桌面窗口化/headless）insets 恒零 → offset 写 0 = 默认窗逐位恒等；真机延迟
	# ≥1 帧重读兜首帧 transform 未定型，size_changed/重获焦点由 helper 重放回调。
	_apply_safe_area()
	if SafeAreaHelper.enabled(get_window()):          # 守卫外恒零→零协程悬挂（headless 全绿面）
		_apply_safe_area_deferred()                # 真值环境延迟重读（SafeAreaHelper 契约）
	SafeAreaHelper.bind_reread(get_window(), _apply_safe_area)


func _apply_safe_area() -> void:
	# R195 安全区应用（消费式契约=SafeAreaHelper.insets 注释）：根 FULL_RECT
	# offset 左/上取正、右/下取负；dim FULL_RECT 子件随根，标题/卡栈锚组随根域。
	# 仅 realize/size_changed/焦点事件驱动，非每帧路径（R188 纪律）。
	var ins := SafeAreaHelper.insets(get_window())
	_root.offset_left = ins.position.x
	_root.offset_top = ins.position.y
	_root.offset_right = -ins.size.x
	_root.offset_bottom = -ins.size.y


func _apply_safe_area_deferred() -> void:
	# realize 后延迟 ≥1 帧重读（首帧查询为未 realize 真值——SafeAreaHelper 契约）；
	# 协程即发即续，不阻塞 _ready（调用方已守卫 enabled 才进来；二次应用幂等）
	await SafeAreaHelper.read_deferred(get_window())
	_apply_safe_area()


func open(p_candidates: Array[Dictionary], p_dual: bool = false) -> void:
	# 展示货架（candidates 由 CardGenerator.generate_candidates 产出）+ 果冻错峰出场。
	# R72 p_dual = 成对模式：双列 6 卡（槽 4~9），点任一张带走同行两张；普通模式槽 0~3
	_dual = p_dual
	_cards = p_candidates
	_highlight_slots.clear()                     # 新货架重开：上一局描金态作废（open 重上色机制兜底还原）
	var slot_base := 4 if _dual else 0
	var slot_cap := 10 if _dual else 4
	# 二cv#8 帧率：mobile 门内首帧只装配窗体+前 CARD_SPLIT_FIRST 张卡，余卡 _process
	# 续建（vc48 尖峰开 40-47ms=开窗级联单帧——逐卡装配含描述自适应量测是级联尾段
	# 大头）；门关=build_to 全量，下方循环与原口径逐位等价（idx < build_to 恒真）。
	# R267 刀P2② 桌面翻门：桌面缝下 build_to 仍全量（整卡同步装配），量测 fit_to 才
	# 分帧（首帧 CARD_SPLIT_FIRST 张已量测定稿，余卡 _process ≤8ms/帧续量测）——开窗
	# 帧成本 = 廉价装配全卡 + 前 3 卡量测，量测大头（梯 miss 7 次/卡 → 二分 ≤3 次/卡，
	# 刀P2①）+ 余卡延后双管齐下。
	var build_to := _cards.size()
	var fit_to := _cards.size()
	if _card_split_on():
		fit_to = mini(_cards.size(), CARD_SPLIT_FIRST)
		if _card_split_hide_tail():
			build_to = fit_to                # mobile 缝：整卡隐卡分帧（原口径零变化）
	# R267 刀P2：桌面缝旗位提升到环外（环内 4-10 次重复静态调 → 1 次）
	var fit_tail_seam := _card_split_on() and not _card_split_hide_tail()
	for s in range(_buttons.size()):
		var in_mode: bool = s >= slot_base and s < slot_cap
		var idx := s - slot_base
		var card: Dictionary = _cards[idx] if in_mode and idx < _cards.size() else {}
		if in_mode and idx >= build_to:
			card = {}                            # 分帧余卡位先空置（空卡=禁点，隐形）
		_setup_button(_buttons[s], card,
			fit_tail_seam and in_mode and idx >= fit_to)
		_buttons[s].visible = in_mode and idx < _cards.size() and idx < build_to
	_reflow_stack()                              # R199：变高卡栈防重叠重排（纯几何）
	_title.text = "成对抉择！带走同一行的两张" if _dual else "升级！选择一项"
	_root.visible = true
	is_open = true
	# 二cv#8 帧率：待续建计数（门关恒 0=零续建；重开/reroll 经 open 复位，close 清零）；
	# R267 桌面缝下计数语义 = 待量测卡数（mobile 缝 = 待装配卡数，原口径）
	_build_left = (_cards.size() - fit_to) if _card_split_on() else 0
	for i in range(mini(build_to, slot_cap - slot_base)):
		StickerTheme.squash_pop(_buttons[slot_base + i], 0.07 * float(i))


func _process(_delta: float) -> void:
	# 二cv#8 帧率：分帧续建消费点（本类 process_mode=ALWAYS——LEVEL_UP 暂停期照跑；
	# 非分帧期成本=两次 bool 读）。单帧预算闸=R212 刀4 形态（帧内已耗超闸即停，余量
	# 下帧续）；续建序=货架序追加，_reflow_stack 收敛与整帧装配同一终局布局。
	if _build_left <= 0 or not is_open or _cards.is_empty():
		return
	var t0 := Time.get_ticks_usec()
	var slot_base := 4 if _dual else 0
	while _build_left > 0:
		var idx: int = _cards.size() - _build_left
		var s: int = slot_base + idx
		# R267 刀P2② 桌面缝：续建=补量测/变高几何（整卡装配已完成——_setup_button
		# 全量重跑幂等，廉价面重做成本可忽略且两缝共用同一装配单源零漂移）；mobile
		# 缝原口径：整卡装配 + 显卡 + 果冻出场。
		_setup_button(_buttons[s], _cards[idx])
		if _card_split_hide_tail():
			_buttons[s].visible = true
			StickerTheme.squash_pop(_buttons[s], 0.0)
		_build_left -= 1
		if _build_left > 0 and Time.get_ticks_usec() - t0 > CARD_BUILD_BUDGET_US:
			break
	_reflow_stack()                              # 续建批落位（已建卡位不回退，追加排栈）


func close() -> void:
	# 选卡完成收起（GameLoop 切回 PLAYING 时调用）；描金预选随收起清除（还原稀有度色）
	_clear_highlight()
	_root.visible = false
	is_open = false
	_cards = []
	_build_left = 0                              # 二cv#8 帧率：防 _process 悬空续建（卡数据已清）


func choose(p_index: int) -> void:
	# 选择入口（按钮 pressed / 测试直调）；无效索引忽略。
	# R72 成对模式：p_index = 槽位（4~9），映射到行（同行两张一起 emit）；普通单张
	if not is_open:
		return
	if _dual:
		var local := p_index - 4                 # 槽 4~9 → 0~5
		if local < 0 or local >= _cards.size():
			return
		var row := local / 2                     # 同行两张 = [row*2, row*2+1]
		var pair: Array = []
		for k in range(2):
			if row * 2 + k < _cards.size():
				pair.append(_cards[row * 2 + k])
		if pair.is_empty():
			return
		choice_made.emit(pair)
		return
	if p_index < 0 or p_index >= _cards.size():
		return
	choice_made.emit([_cards[p_index]])


func candidate_count() -> int:
	# 测试观测口
	return _cards.size()


func highlight_candidate(p_index: int) -> void:
	# R188-3 挂机自动选择预选描金：欲选卡顶带改金色（复用 open 期 _apply_band_color
	# 重上色机制——duplicate StyleBoxFlat 后改 bg，不落共享态）；成对模式 p_index 为
	# 槽位（4~9），同行两张同亮（整行 = 一次选择语义）；未开店/越界忽略；再次调用
	# 先还原上一次描金（单预选口）。close() 清除还原。
	if not is_open or p_index < 0:
		return
	_clear_highlight()
	var slots: Array[int] = []
	if _dual:
		var local := p_index - 4                 # 槽 4~9 → 卡 0~5（choose 同映射）
		if local < 0 or local >= _cards.size():
			return
		var row := local / 2
		for k in range(2):
			if row * 2 + k < _cards.size():
				slots.append(4 + row * 2 + k)
	else:
		if p_index >= _cards.size():
			return
		slots.append(p_index)
	for s in slots:
		# R246 D11：红卡（rarity==4 升华卡）槽位跳过描金——红顶带+5 珠自带全货架最高
		# 视觉优先级，被金覆盖=读感降级；仅记录槽位保持 highlighted_slots() 观测口语义
		#（挂机预选链 pick 仍指它）。_clear_highlight 对未描色槽位重上稀有度色幂等无害
		var ci := s - (4 if _dual else 0)
		if ci >= 0 and ci < _cards.size() and int(_cards[ci].get("rarity", 0)) == 4:
			_highlight_slots.append(s)
			continue
		_apply_band_color(s, PopPalette.GOLD)
		_highlight_slots.append(s)


func highlighted_slots() -> Array[int]:
	# 测试观测口：当前描金槽位快照
	return _highlight_slots.duplicate()


func _clear_highlight() -> void:
	# 描金还原（_highlight_slots 逐槽按卡面稀有度色重上色后清表；open/close 双入口）
	for s in _highlight_slots:
		var card_idx := s - (4 if _dual else 0)
		if s < 0 or s >= _buttons.size() or card_idx < 0 or card_idx >= _cards.size():
			continue
		var card: Dictionary = _cards[card_idx]
		if card.is_empty():
			continue                             # 已售出/空槽：open 重上色时自然归位
		_apply_band_color(s, PopPalette.rarity_color(int(card.get("rarity", 0))))
	_highlight_slots.clear()


func _apply_band_color(p_slot: int, p_color: Color) -> void:
	# 顶带重上色唯一通道（原 _setup_button :136-138 机制收口）：duplicate 当前
	# StyleBoxFlat → 改 bg_color → override。稀有度色与描金高亮共用。
	if p_slot < 0 or p_slot >= _card_faces.size():
		return
	var band: Panel = _card_faces[p_slot]["band"]
	var band_style: StyleBoxFlat = band.get_theme_stylebox("panel").duplicate() as StyleBoxFlat
	band_style.bg_color = p_color
	band.add_theme_stylebox_override("panel", band_style)


func _on_pressed(p_index: int) -> void:
	choose(p_index)


func update_reroll(p_charges: int, p_free_left: bool = false) -> void:
	# 换一批按钮态刷新（GameLoop 注入）：免费态（本局首次）优先显示；0 次 + 无免费 →
	# 置灰仍可见——刷新机制的可发现性口径
	if _reroll_btn == null:
		return
	if p_free_left:
		_reroll_btn.text = "换一批（本局首次免费）"
		_reroll_btn.disabled = false
	elif p_charges > 0:
		_reroll_btn.text = "换一批 ×%d" % p_charges
		_reroll_btn.disabled = false
	else:
		_reroll_btn.text = "换一批 ×0"
		_reroll_btn.disabled = true


func _on_reroll_pressed() -> void:
	# 刷新申请（仲裁在 GameLoop：次数/免费位扣减 + 重新发牌 + 重开本界面）
	if is_open:
		reroll_requested.emit()


func _setup_button(p_btn: Button, p_card: Dictionary, p_defer_fit: bool = false) -> void:
	# 卡面装配（贴纸装：稀有度顶带 + 类型圆章 + 类别行 + 名称 + 描述 + 层级圆点）
	# R267 刀P2②：p_defer_fit=true = 桌面分帧缝——廉价面（顶带/章/类别/名字/描述文本/
	# 圆点显隐换纹）同步装配，_fit_desc 量测与变高几何延后（_process 续建收口）。
	var idx := _buttons.find(p_btn)
	var face: Dictionary = _card_faces[idx] if idx >= 0 and idx < _card_faces.size() else {}
	if p_card.is_empty():
		p_btn.disabled = true
		(face.get("maxed") as Label).visible = false   # R262e ①：空卡清徽标（槽复用残留防御）
		return
	p_btn.disabled = false
	# R262e ①：已满层徽标显隐（生成侧 "maxed" flag——显示=实挂同仲裁源）
	(face.get("maxed") as Label).visible = bool(p_card.get("maxed", false))
	var kind: int = int(p_card.get("kind", 0))
	var rarity: int = int(p_card.get("rarity", 0))
	var rarity_color := PopPalette.rarity_color(rarity)
	# 顶带 = 稀有度色（重上色走 _apply_band_color 唯一通道——描金高亮共用同一机制）
	# QA-heal r1：二cv#8 分帧续建竞态收口——自动窗首拍描金（game_loop 展示窗首帧
	# highlight_candidate）可能先于本槽续建落位，此处无条件重上稀有度色会把预落在
	# 未建卡上的金顶带冲掉（金视觉丢失至窗结束；仅 mobile 分帧门内可达——桌面/
	# headless 门关零续建，逐位等价）。落位时槽位在描金表且非红卡（R246 D11 与
	# highlight_candidate 同判式）→ 按描金态重上金色，金视觉与数据面锁步。
	var band_color := rarity_color
	if _highlight_slots.has(idx) and rarity != 4:
		band_color = PopPalette.GOLD
	_apply_band_color(idx, band_color)
	# 类型圆章
	var stamp: TextureRect = face["stamp"]
	var pool := -1
	if kind == CardGenerator.CardKind.TRAIT and p_card.get("data") != null:
		pool = int((p_card.get("data") as Object).get("pool"))
	stamp.texture = TextureFactory.type_icon(kind, pool)
	# 类别行（类别 · 稀有度名，稀有度色加深可读）
	var kind_label: Label = face["kind"]
	kind_label.text = "%s · %s" % [KIND_NAMES[clampi(kind, 0, KIND_NAMES.size() - 1)],
		PopPalette.rarity_name(rarity)]
	kind_label.add_theme_color_override("font_color", rarity_color)
	# 名称 + 描述（高稀有度数值强化 → 描述内已重写真实数值；尾行标注品质倍率作为解释）
	var name_label: Label = face["name"]
	name_label.text = String(p_card.get("display_name", ""))
	# QA-R242-P05：槽复用色残留清——先无条件落墨基色（同键 override 即覆盖），再按态
	# 覆写；否则上一货架的质变金/诅咒红名残留到本货架普通卡（金残留系 2026-08-31
	# 既有病，红残留为本轮诅咒面新增——一并根治）
	name_label.add_theme_color_override("font_color", PopPalette.INK)
	# 满层质变卡（2026-08-31）：名称金色高亮（「到什么程度会质变」卡面预览）
	if bool(p_card.get("milestone", false)):
		name_label.add_theme_color_override("font_color", PopPalette.GOLD)
	# REL_GAMBLER 诅咒卡显性化（用户 2026-10-07 反馈「第 4 张必带诅咒页面看起来
	# 差不多」——cursed 键此前零 UI 呈现）：名字警示红（ENEMY=r230 语义钉同源）
	# + 类别行插「诅咒」段，描述尾行代价经 compose_desc_text 单源（预热键契约 R220
	# 不破——诅咒卡开窗时预热 miss 至多 1 条/窗，_fit_desc 现场量测回退可忽略）
	if bool(p_card.get("cursed", false)):
		name_label.add_theme_color_override("font_color", PopPalette.ENEMY)
		# 评审 LOW-4：类别行整行改警示红（原插「诅咒」段后仍稀有度色——传说诅咒卡
		# 上「词条 · 诅咒 · 传说」整行金色=警告词被高级色稀释）
		kind_label.text = String(kind_label.text).replace(" · ", " · 诅咒 · ")
		kind_label.add_theme_color_override("font_color", PopPalette.ENEMY)
	var desc_label: Label = face["desc"]
	var desc_text := compose_desc_text(String(p_card.get("description", "")),
		float(p_card.get("value_scale", 1.0)), _dual,
		bool(p_card.get("cursed", false)))
	desc_label.text = desc_text
	# 层级圆点（rarity+1 枚稀有度色圆珠）——R212 刀1 附带微刀：预建 5 珠按 rarity
	# 显隐复用（原每次 open queue_free 全清 + 逐珠 new 1-4 个 TextureRect/卡；珠纹理
	# 走 TextureFactory.bead 静态缓存，换纹理零重生成）。rarity 域 0..4（R246 红档 [4]
	# 升华卡，PopPalette 扩档后取色放行），5 珠全覆盖；HBox 对隐藏子件不占位 →
	# 行内恒显 rarity+1 枚（红卡 5 珠全红，:303 显隐逻辑零改动自动跟随）
	# R267 刀P2②：圆点显隐/换纹前移为廉价面（桌面缝首帧同步装配——同步读口径不破）；
	# dots.position 随量测几何在 fit 段定（量测延后时先落基位 150）
	var dots: HBoxContainer = face["dots"]
	var bead_tex := TextureFactory.bead(rarity_color, 22, false)
	var bead_i := 0
	for child_v: Variant in dots.get_children():
		var bead: TextureRect = child_v as TextureRect
		if bead == null:
			continue                              # 防御：非珠子子件不动（现状无此形态）
		var show_i := bead_i < rarity + 1
		bead.visible = show_i
		if show_i:
			bead.texture = bead_tex
		bead_i += 1
	if p_defer_fit:
		dots.position = Vector2(18.0, 150.0)
		return                                   # R267 刀P2②：量测/变高几何延后（续建收口）
	# R199(P05/P06/F15) 描述区自适应扩容：58px 定高+clip 改为按 StickerTheme 实测行高
	# 适配——字号梯从大到小取首个装得下的档，框高=实测需求高（含行距），卡体随描述
	# 扩高（≤设计帽），层级圆点让位下移；超长描述（元素族全反应列举）在梯底钳帽由
	# clip_text 兜底。体检实测 18pt≈54px 宿主相关（禁拍值）；文案内容零改动
	# （源在 tres/GameConst）
	var is_compact := _dual
	var fit := _fit_desc(desc_text, p_btn.size.x, is_compact,
		float(desc_label.get_theme_constant("line_spacing")))
	desc_label.add_theme_font_size_override("font_size", int(fit["fs"]))
	var desc_need := float(fit["need"])
	desc_label.size = Vector2(p_btn.size.x - 36.0, maxf(58.0, desc_need))
	var h_base: float = DUAL_CARD_SIZE.y if is_compact else CARD_SIZE.y
	var dots_y := maxf(150.0, 88.0 + desc_need + 4.0)
	var h_new: float = minf(maxf(h_base, dots_y + h_base - 150.0),
		DUAL_H_MAX if is_compact else CARD_H_MAX)
	p_btn.size = Vector2(p_btn.size.x, h_new)
	dots.position = Vector2(18.0, minf(dots_y, h_new - 30.0))


func _build_ui() -> void:
	# 程序化贴纸卡牌竖排（720×1280 竖屏中带；4 槽 = REL_GAMBLER 四选一上限）
	_root = Control.new()
	_root.name = "CardSelectRoot"
	_root.theme = StickerTheme.theme()
	_root.set_anchors_preset(Control.PRESET_FULL_RECT)
	_root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_root.visible = false
	add_child(_root)
	var dim := ColorRect.new()
	dim.color = PopPalette.DIM
	dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	dim.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_root.add_child(dim)
	# R195 适配分区：标题全宽拉伸锚（anchor_l=0/anchor_r=1、y 不变；(0,148)720×46
	# 720 宽恒等，宽视口下满宽居中）
	_title = StickerTheme.label_sticker(Label.new(), 34, PopPalette.INK, 12, Color.WHITE, true)
	_title.text = "升级！选择一项"
	_title.anchor_right = 1.0
	_title.offset_left = 0.0
	_title.offset_right = 0.0
	_title.offset_top = 148.0
	_title.offset_bottom = 194.0
	_title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_root.add_child(_title)
	# 换一批按钮（刷新机制，2026-08-31 用户反馈「新增 buff 刷新机制」）：标题与首卡间右侧；
	# 次数/免费态由 GameLoop 注入（update_reroll），0 次 + 无免费 → 置灰仍可见（机制可发现）
	_reroll_btn = Button.new()
	_reroll_btn.name = "RerollButton"
	_reroll_btn.text = "换一批"
	_reroll_btn.add_theme_font_size_override("font_size", 19)
	_reroll_btn.add_theme_font_override("font", StickerTheme.font_bold())
	_reroll_btn.position = Vector2(452.0, 196.0)
	_reroll_btn.size = Vector2(208.0, 56.0)
	# R195 适配分区：reroll 钮 x 同卡栈水平居中锚（offset=现值−设计中心 x360——
	# 宽视口下随中心随动，栈内相对位恒等；_reflow_stack 只直写 y，卡 x 仍随中心缩放）
	_reroll_btn.anchor_left = 0.5
	_reroll_btn.anchor_right = 0.5
	# R202①（换一批按钮遮挡修复）：y 锚对齐视觉组——title（anchor_top=0，148..194）
	# 与卡栈（_reflow_stack 自 CARD_TOP=264 直写 position → 绝对 y）整组均为绝对
	# 设计域 y 语义；原 y 挂 0.5 中心锚在 ≠1280 高视口下随中心平移（1440→y276、
	# 1680→y396）撞入卡区（按钮与组锚语义错配，探针实证）。绝对 y 下相对几何
	# 不随视口变化，全矩阵尺寸恒等
	_reroll_btn.anchor_top = 0.0
	_reroll_btn.anchor_bottom = 0.0
	_reroll_btn.offset_left = 92.0
	_reroll_btn.offset_right = 300.0
	# R202①：设计位整体上提 2px（原 0.5 锚 -442/-388 ≡ y198..254 → 绝对 y196..252）
	# ——对标题底 194 留 2px 缝；极端字体档（min 高 79 溢出设计 56）下最坏重叠
	# 13→11px，正常档（min 高 56）全矩阵尺寸零重叠（按钮底 252 与卡顶 264 恒 12px
	# 缝）。position 镜像值 198→196 同步（anchors+offsets 显式覆盖后为纯注释性自洽，
	# 不参与最终布局）
	_reroll_btn.offset_top = 196.0
	_reroll_btn.offset_bottom = 252.0
	_reroll_btn.pivot_offset = _reroll_btn.size * 0.5
	_reroll_btn.focus_mode = Control.FOCUS_NONE
	_reroll_btn.pressed.connect(_on_reroll_pressed)
	_reroll_btn.button_down.connect(func() -> void: StickerTheme.press_punch(_reroll_btn))
	# 4 卡槽位（open() 按货架数显隐——三选一时第 4 槽隐藏）
	# R195 适配分区：卡栈整体居中锚——各卡 offset=设计位−设计中心(360,640)（等效包一层
	# 居中容器，免重挂父子），CARD_TOP/CARD_STEP/DUAL_* 设计位公式原样父相对恒等；
	# 720×1280 逐位恒等，宽/高视口下整栈随中心随动
	for i in range(4):
		var btn := Button.new()
		btn.name = "Card%d" % i
		btn.focus_mode = Control.FOCUS_NONE
		var card_pos := Vector2(CARD_X, CARD_TOP + CARD_STEP * float(i))
		btn.anchor_left = 0.5
		btn.anchor_right = 0.5
		btn.anchor_top = 0.5
		btn.anchor_bottom = 0.5
		btn.offset_left = card_pos.x - 360.0
		btn.offset_right = card_pos.x + CARD_SIZE.x - 360.0
		btn.offset_top = card_pos.y - 640.0
		btn.offset_bottom = card_pos.y + CARD_SIZE.y - 640.0
		btn.size = CARD_SIZE
		btn.pressed.connect(_on_pressed.bind(i))
		btn.button_down.connect(func() -> void: StickerTheme.press_punch(btn))
		_root.add_child(btn)
		_buttons.append(btn)
		_card_faces.append(_build_card_face(btn))
	# R72 成对模式 6 槽（4~9：双列三行；初始隐藏，open(…, true) 启用）
	for d in range(6):
		var dbtn := Button.new()
		dbtn.name = "DualCard%d" % d
		dbtn.focus_mode = Control.FOCUS_NONE
		var dual_pos := Vector2(DUAL_X[d % 2], DUAL_TOP + DUAL_STEP * float(d / 2))
		dbtn.anchor_left = 0.5
		dbtn.anchor_right = 0.5
		dbtn.anchor_top = 0.5
		dbtn.anchor_bottom = 0.5
		dbtn.offset_left = dual_pos.x - 360.0
		dbtn.offset_right = dual_pos.x + DUAL_CARD_SIZE.x - 360.0
		dbtn.offset_top = dual_pos.y - 640.0
		dbtn.offset_bottom = dual_pos.y + DUAL_CARD_SIZE.y - 640.0
		dbtn.size = DUAL_CARD_SIZE
		dbtn.visible = false
		dbtn.pressed.connect(_on_pressed.bind(4 + d))
		dbtn.button_down.connect(func() -> void: StickerTheme.press_punch(dbtn))
		_root.add_child(dbtn)
		_buttons.append(dbtn)
		_card_faces.append(_build_card_face(dbtn, true))
	# R202③（换一批按钮遮挡修复）：reroll 钮 add 推迟到全部卡之后（树序兜底）——
	# 极端字体档按钮 min 高 79 溢出设计 56（> 卡顶 264 上方 70px 走廊）时，重叠表现
	# 为按钮盖卡顶边 ≤11px（按钮恒可见可点），而非原卡后 add 树序盖按钮（点击落入
	# 卡区 → 误选卡）。正常字体档（min 高 56）零重叠，树序变化无副作用（dim 仍是
	# _root 首个 ColorRect 子节点，first_color_rect 观测口恒等）
	_root.add_child(_reroll_btn)


func _build_card_face(p_btn: Button, p_compact: bool = false) -> Dictionary:
	# 卡面子件组装（一次装配，open 期仅换色/换文/换点——零重建）。
	# p_compact = 成对窄卡（324 宽）：子件尺寸跟随按钮实际宽度，字号收缩
	var cw := p_btn.size.x
	var band := Panel.new()
	var band_style := StyleBoxFlat.new()
	band_style.bg_color = PopPalette.RARITY_NORMAL
	band_style.set_corner_radius_all(20)
	band_style.corner_radius_bottom_left = 0
	band_style.corner_radius_bottom_right = 0
	band.add_theme_stylebox_override("panel", band_style)
	band.position = Vector2(4.0, 4.0)
	band.size = Vector2(cw - 8.0, 14.0)
	band.mouse_filter = Control.MOUSE_FILTER_IGNORE
	p_btn.add_child(band)
	# R262e ①：已满层徽标（用户「如果 buff 满了，出现的 buff 左上角加个提示」）——
	# 左上角深底白字角标，_setup_button 按 "maxed" flag 显隐（一次装配零重建）
	var maxed_badge := Label.new()
	maxed_badge.name = "MaxedBadge"
	maxed_badge.text = "已满层"
	var badge_style := StyleBoxFlat.new()
	badge_style.bg_color = PopPalette.INK
	badge_style.set_corner_radius_all(8)
	badge_style.content_margin_left = 8.0
	badge_style.content_margin_right = 8.0
	badge_style.content_margin_top = 2.0
	badge_style.content_margin_bottom = 2.0
	maxed_badge.add_theme_stylebox_override("normal", badge_style)
	maxed_badge.add_theme_font_size_override("font_size", 13)
	maxed_badge.add_theme_color_override("font_color", Color.WHITE)
	maxed_badge.position = Vector2(8.0, 20.0)
	maxed_badge.mouse_filter = Control.MOUSE_FILTER_IGNORE
	maxed_badge.visible = false
	p_btn.add_child(maxed_badge)
	var kind_label := StickerTheme.label_sticker(Label.new(), 15, PopPalette.RARITY_NORMAL)
	kind_label.name = "KindChip"
	kind_label.position = Vector2(18.0, 26.0)
	kind_label.size = Vector2(cw - 120.0, 20.0)
	if p_compact:
		kind_label.add_theme_font_size_override("font_size", 13)
	p_btn.add_child(kind_label)
	var stamp := TextureRect.new()
	stamp.name = "TypeStamp"
	stamp.position = Vector2(cw - 66.0, 26.0)
	stamp.custom_minimum_size = Vector2(46.0, 46.0) if p_compact else Vector2(52.0, 52.0)
	stamp.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	stamp.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	stamp.mouse_filter = Control.MOUSE_FILTER_IGNORE
	p_btn.add_child(stamp)
	var name_label := StickerTheme.label_sticker(Label.new(), 22, PopPalette.INK, 0, Color.WHITE, true)
	name_label.name = "CardName"
	name_label.position = Vector2(18.0, 50.0)
	name_label.size = Vector2(cw - 90.0, 30.0)
	if p_compact:
		name_label.add_theme_font_size_override("font_size", 18)
	name_label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	p_btn.add_child(name_label)
	# R200（真机反馈「buff 字很小」）：描述基准 18→20 / 紧凑 14→15（梯顶同步）——
	# 3 倍密度手机上 18pt ≈ 10.5dp 偏小；名称 22 / 紧凑 18 保持层级差
	var desc_label := StickerTheme.label_sticker(Label.new(), 20, PopPalette.INK_SOFT)
	desc_label.name = "CardDesc"
	desc_label.position = Vector2(18.0, 88.0)
	desc_label.size = Vector2(cw - 36.0, 58.0)
	if p_compact:
		desc_label.add_theme_font_size_override("font_size", 15)
	desc_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	desc_label.clip_text = true
	p_btn.add_child(desc_label)
	var dots := HBoxContainer.new()
	dots.name = "RarityDots"
	dots.position = Vector2(18.0, 150.0)
	dots.size = Vector2(160.0, 16.0)
	dots.add_theme_constant_override("separation", 6)
	dots.mouse_filter = Control.MOUSE_FILTER_IGNORE
	p_btn.add_child(dots)
	# R212 刀1 附带微刀：5 珠预建（装配期一次），open 期仅显隐+换纹理——零 queue_free/
	# 零 new（原每次 open 1-4 个 TextureRect 实例化/卡 ×10 槽）
	# R246：4→5 珠（rarity=4 升华红卡显 5 珠；r212 量测缓存断言对 0..3 卡保持绿——
	# 显隐口径 rarity+1 未动，仅预建上限扩一）
	for d in range(5):
		var bead := TextureRect.new()
		bead.name = "RarityDot%d" % d
		bead.custom_minimum_size = Vector2(14.0, 14.0)
		bead.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		bead.stretch_mode = TextureRect.STRETCH_SCALE
		bead.mouse_filter = Control.MOUSE_FILTER_IGNORE
		bead.visible = false
		dots.add_child(bead)
	return {"band": band, "stamp": stamp, "kind": kind_label,
		"name": name_label, "desc": desc_label, "dots": dots, "maxed": maxed_badge}


static func compose_desc_text(p_desc: String, p_value_scale: float, p_dual: bool,
		p_cursed: bool = false) -> String:
	# R220 刀2（D1）：卡面描述最终文本拼接单源（原 _setup_button :256-264 内联段提取，
	# 逐字节等价——value_scale>1 尾行 + 成对 ⇄ 行）。产品 _setup_button 与卡面预热器
	#（card_desc_prewarm.gd）共用本口——预热键文本与开窗实拼文本必然逐位一致，
	# 杜绝两处格式串漂移导致的「预热键 miss」。
	# p_cursed（R242 诅咒显性化）：REL_GAMBLER 第 4 张尾行明示代价——预热器不传此参
	# （默认 false，变体枚举无诅咒档），诅咒卡开窗预热 miss 至多 1 条/窗可忽略。
	var out := p_desc
	# c8②：二元拓扑卡假尾注抑制——生成侧（_scaled_description）已给这类卡追加
	#「（品质不影响效果）」字样，本口按同一字样判同（单源标记：产品与预热器两路
	# desc 同源，键天然逐位一致，无需加参传旗），不再拼「品质加成 ×N」假话行。
	if p_value_scale > 1.0 and not p_desc.contains("品质不影响效果"):
		out += "\n品质加成：该词条效果 ×%.1f（已计入上行数字）" % p_value_scale
	# F3 成对抉择行内提示（self-evolution）：窄卡空间小——组合语义就地说明
	#（标题有全局说明，但首见玩家视线落在卡上）
	if p_dual:
		out += "\n⇄ 点这张会同时带走同一行另一张"
	if p_cursed:
		var curse_pct := int(round(-float(CardGenerator.CARD_EXTRA_CURSE_PARAMS
			.get("curse_atk_pct", -0.1)) * 100.0))
		# ※（U+203B 参考记号）CJK 字体单色字形广泛收录——评审 MED-2：⚠（U+26A0）在
		# 部分 Android 设备回退彩色 emoji 字体（贴纸卡面冒彩三角+量纲撑行），弃用
		out += "\n※ 代价：攻击力 -%d%%" % curse_pct
	return out


static func prewarm_line_spacing() -> float:
	# R220 刀2（D1）：行距探针（卡面预热器建队用）——与 _setup_button 量测调用点
	#（:272 desc_label.get_theme_constant("line_spacing")）同 theme 环境：树外探针
	# 显式挂 StickerTheme.theme()（与 _root.theme 同一实例），两路径查找序一致
	#（theme 常量 → 引擎默认 theme）→ 读值恒等，预热键行距维与开窗实拼键逐位一致。
	var probe := Label.new()
	probe.theme = StickerTheme.theme()
	var ls := float(probe.get_theme_constant("line_spacing"))
	probe.free()
	return ls


static func _fit_desc(p_text: String, p_cw: float, p_compact: bool, p_line_spacing: float) -> Dictionary:
	# R199(P05/P06/F15) 描述框自适应量测：按 StickerTheme 实测行高排版测高（体检实测
	# 18pt≈54px 宿主相关——禁拍值，get_multiline_string_size 同参口径），字号梯从大到
	# 小取首个「需求高 ≤ 框帽」的档；梯底仍超 → 梯底字号 + 需求钳帽（clip_text 兜底）。
	# 实测高不含 Label 行距——按行数补 (n−1)×line_spacing（行数 = 需求高 ÷ 实测行高，
	# get_multiline_string_size 高 = n×get_height 整除口径）。框帽 = 卡高帽 − 基准卡高
	# + 54（描述顶 88 + 圆点/底距 34 的反解，与 _setup_button 落位公式同源）。
	# 返回 {fs: 字号, need: 实测需求高含行距（已钳帽）}。
	# R200：梯顶 18→20 / 紧凑 14→15、梯底 10→12——真机可读下限（10pt≈6dp 不可读）；
	# P05 整卡可见优先级不变：梯底仍超 → 梯底字号 + 需求钳帽 clip_text 兜底
	# R212 刀1：键=文本+宽度(0.1px 粒度)+紧凑位+行距(0.1px 粒度)——同键结果确定
	# 性一致，命中直返（同文案二次 open/reroll/连升重开零 get_multiline_string_size）
	# R220 刀2（D1）：静态化（函数体纯参数无实例依赖，缓存 :52 本就是 static）——供
	# 卡面描述预热器（card_desc_prewarm.gd）菜单期直调同函数入缓存；缓存键与命中
	# 路径逐位不变（预热只提前不改变排版结果）。
	var cache_key := "%s|%d|%d|%d" % [p_text, roundi(p_cw * 10.0),
		1 if p_compact else 0, roundi(p_line_spacing * 10.0)]
	if _fit_desc_cache.has(cache_key):
		fit_desc_cache_hits += 1
		return _fit_desc_cache[cache_key]
	var ladder: Array = [15, 14, 13, 12] if p_compact \
		else [20, 18, 16, 14, 13, 12]
	var h_cap: float = DUAL_H_MAX if p_compact else CARD_H_MAX
	var h_base: float = DUAL_CARD_SIZE.y if p_compact else CARD_SIZE.y
	var max_h := h_cap - h_base + 54.0
	var width := p_cw - 36.0
	var font: Font = StickerTheme.font()
	# R267 刀P2①：字号梯二分定档（原梯全走 miss 最多 7 次量测——梯底预量 1 + 逐档
	# 至多 6；Android SystemFont 六级回退链单次排版远贵桌面，量测次数即成本主源）。
	# 二分在降序梯上找「最大装得下字号」：⌈log2(6)⌉=3 次（4 档梯 ≤3）封顶，选中档
	# 的 need 即该档实测高（与原口径同值同源）；全超帽时收敛到梯底（need=梯底实测，
	# minf(need,max_h) 钳帽 clip 兜底——与原梯底语义逐位一致）。定档结果与原「从大
	# 到小取首个 fit」同解（最大 fit 档唯一），缓存键与命中路径零改动（刀P2 契约）。
	var lo := 0
	var hi := ladder.size() - 1
	var best: int = int(ladder[ladder.size() - 1])
	var need := 0.0
	while lo <= hi:
		var mid := (lo + hi) / 2
		var h := _measured_desc_h(font, p_text, width, int(ladder[mid]), p_line_spacing)
		if h <= max_h:
			best = int(ladder[mid])
			need = h
			hi = mid - 1                      # 再试更大字号（降序梯更小下标）
		else:
			if mid == ladder.size() - 1:
				need = h                      # 梯底实测在案（全超帽路径的 need 源——免二次量）
			lo = mid + 1
	if need <= 0.0:
		# 全档超帽且二分未触梯底（数学上仅 1 档梯可达）——补量恰 1 次（总次数 ≤3+1）；
		# 与原「梯底预量测」路径同值
		need = _measured_desc_h(font, p_text, width, int(ladder[ladder.size() - 1]),
			p_line_spacing)
	var out := {"fs": best, "need": minf(need, max_h)}
	_fit_desc_cache[cache_key] = out
	return out


static func _measured_desc_h(p_font: Font, p_text: String, p_width: float, p_fs: int,
		p_line_spacing: float) -> float:
	# 实测描述排版高：wrap 需求高（= n×行高）+ 行间行距 (n−1)×line_spacing
	# R212 刀1：计数器为测试观测口（量测缓存命中断言——未命中路径每调用 +1）
	# R220 刀2（D1）：同步静态化（随 _fit_desc）；DebugStats.count 写点=每次真实量测
	#（get_multiline_string_size 本体）+1——只在本函数即缓存 miss 路径被调，命中路径
	# 零计数；预热期的量测同样计数（量测本体口径，预热不豁免）——R220_COUNTER_KEYS
	# 审计键（debug_stats.gd R220 块），把方案书 1.R3 的拟合带转为实测。
	fit_desc_measures += 1
	DebugStats.count(&"fit_desc_measures")
	var raw: float = p_font.get_multiline_string_size(p_text,
		HORIZONTAL_ALIGNMENT_LEFT, p_width, p_fs, -1, 7).y
	var line_h := maxf(p_font.get_height(p_fs), 1.0)
	var lines := maxi(1, roundi(raw / line_h))
	return raw + float(lines - 1) * p_line_spacing


func _reflow_stack() -> void:
	# R199(P05/P06/F15) 变高卡栈防重叠重排（纯几何，open 期一次）：普通模式逐卡、成对
	# 模式逐行（同行顶对齐，行距取行内最高卡）；基准间隙 = STEP − SIZE.y（16/20），
	# 无卡扩高时落位与 CARD_TOP/CARD_STEP/DUAL_* 设计位逐位恒等；栈底越红线
	# （STACK_BOTTOM_MAX）则压缩间隙重排一遍（下限 4px，再越线属极限超帽接受裁切）。
	var gap := DUAL_STACK_GAP if _dual else STACK_GAP
	var top := DUAL_TOP if _dual else CARD_TOP
	for pass_i in range(2):
		var y := top
		var placed := 0
		if _dual:
			for r in range(3):
				var row_h := 0.0
				var any_visible := false
				for k in range(2):
					var b := _buttons[4 + r * 2 + k]
					if b.visible:
						b.position.y = y
						any_visible = true
						row_h = maxf(row_h, b.size.y)
				if any_visible:
					y += row_h + gap
					placed += 1
		else:
			for i in range(4):
				var b := _buttons[i]
				if b.visible:
					b.position.y = y
					y += b.size.y + gap
					placed += 1
		var bottom := y - gap
		if placed < 2 or bottom <= STACK_BOTTOM_MAX:
			return
		gap = maxf(4.0, gap - (bottom - STACK_BOTTOM_MAX) / float(placed - 1))
