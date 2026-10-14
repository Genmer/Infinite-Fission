# scripts/cards/card_desc_prewarm.gd
# R220 刀2（D4）：卡面描述量测菜单期全量预热器（R219 方案书刀2 / R220 契约 §1-D4）。
# vc26 真机取证：选卡窗 104-188ms 尖峰本体 = _fit_desc 缓存 miss 全量梯量测
#（SystemFont 回退链 Android 全 miss 单次排版远贵于桌面，深局每窗 21-30 次量测）。
# 本预热器在 MENU 态把「卡面描述文本变体全清单」提前调 CardSelectUI._fit_desc 入
# 缓存——开窗只余缓存命中（预期每开窗增量测 ≤2：MASTERY 窗外语料残余）。
# 排版结果逐位不变（同键同值——缓存键与命中路径零改动，预热只提前不改变结果）。
#
# 分帧口径（R215 菜单期贴图预热同款、独立通道）：12ms/帧预算消化（BUDGET_US），
# 队列空 = 零成本早退；单项（一条变体的全梯量测）为原子粒度，预算用尽即停在项边界
#（单项可超预算——梯量测不可分割，与 R215 _process_tex_prewarm 同语义）。菜单期
# 消化不完即开局的剩余变体走原惰性路径（不劣于现状）。驱动在 menu_screen._process
#（MENU 态门、离开菜单暂停/回菜单继续——D3），不占 game_loop 物理帧预算（契约
# §8 裁定#5：不复用 R215 贴图通道——那在 game_loop.gd（B 包文件），自建同口径）。
#
# 变体全清单（漏拼任一即部分稀有度全 miss——方案书刀2-怎么做①-④）：
# ① TRAIT：_scaled_description ×4 稀有度数值重写 × {plain/milestone}尾注态（R226 超帽尾注态退役）；
# ② MASTERY 等级文案（等级域生成 = 当前持有武器等级 ±2 近窗的超集——描述与武器名
#    /等级无关，只含 boosts 数与品质名）；
# ③ 双列 ⇄ 行文案 × ④ value_scale>1 品质尾行各档——经 compose_desc_text 单源拼接；
# ⑤ 以上 × 宽档（普通 600 非紧凑 / 双列 324 紧凑——开窗仅有的两个有效组合）× 行距
#    （prewarm_line_spacing 探针读值，与量测调用点同 theme 环境同读法）。
# 前置：StickerTheme.font() 已初始化（ensure_built 首步触发——SystemFont 构建不占
# 首条量测的帧预算读数）。
# 注：不声明 class_name——消费方（menu_screen / 测试）preload 引用，规避 headless
# -s 模式全局类缓存不重扫的加载风险。
extends RefCounted

const BUDGET_US := 4000                      # R252D P5：4ms/帧——与 game_loop _process_tex_prewarm
                                             # (4000) + menu_screen 图鉴行级预建泵（R254 修轮#3b
                                             # 起 4000）三泵合计 12ms < 60Hz 16.6ms，点击响应
                                             # ~4.6ms 余量（修前双泵 24ms/帧预算超支，点击帧与
                                             # 预热帧排队=菜单点击卡的系统性放大器；P3/P4 已
                                             # 把队内单项成本打下来，排空时长 ×3 菜单停留期可
                                             # 消化完，进战即停泵零战斗期开销）
                                             # R262b L6 口径注记：12ms 与菜单渲染底噪
                                             # 8.7-9.9ms（menu_screen R260 问题陈述自记）
                                             # 是否相加未实测——若相加，队列消化期菜单
                                             # ≈45fps 属有意排空取舍（排空即恢复；模态期
                                             # R260 已全停）。调参前先真机复测再压。）

static var _queue: Array = []                # 预热项 {text, cw, compact, ls}
static var _built: bool = false
static var _total_built: int = 0             # 建队总项数（进度分母观测口）
static var _pumped_frames: int = 0           # 非零消化帧计数（分帧节奏观测口）
static var _skip_frames: int = 0             # R221 Fix A：超支还账跳帧余额（>0 时泵零成本直返）
static var _last_item_us: int = 0            # 最近单项实际耗时 µs（观测口——跳帧折算源）


static func ensure_built(p_registry) -> void:
	# 建队（幂等——_built 早退，菜单期每帧调用零成本）。变体文本一律走
	# CardGenerator.enumerate_prewarm_variants 真路径（与开窗同代码同源）。
	if _built:
		return
	_built = true
	# 前置：字体实例初始化（冷开 SystemFont 构建 ≠ 首条量测预算）
	StickerTheme.font()
	if p_registry == null:
		return
	var gen := CardGenerator.new()
	gen.setup(p_registry)
	var variants: Array[Dictionary] = gen.enumerate_prewarm_variants([])
	var ls := CardSelectUI.prewarm_line_spacing()
	for v in variants:
		var desc := String(v["desc"])
		var vs := float(v["value_scale"])
		# 普通货架档（600 宽 / 非紧凑 / 无 ⇄ 行）
		_queue.append({"text": CardSelectUI.compose_desc_text(desc, vs, false),
			"cw": CardSelectUI.CARD_SIZE.x, "compact": false, "ls": ls})
		# 双列货架档（324 宽 / 紧凑 / 带 ⇄ 行）——开窗仅有的两个 (宽, 紧凑) 有效组合
		_queue.append({"text": CardSelectUI.compose_desc_text(desc, vs, true),
			"cw": CardSelectUI.DUAL_CARD_SIZE.x, "compact": true, "ls": ls})
	_total_built = _queue.size()
	DebugStats.count(&"fit_desc_prewarm_variants", variants.size())
	DebugStats.count(&"fit_desc_prewarm_keys", _total_built)


static func pump(p_budget_us: int = BUDGET_US) -> int:
	# 帧驱动消化：逐项调 CardSelectUI._fit_desc（miss → 量测入缓存；已缓存 → 零成本
	# 早退），预算用尽停在项边界；返回本帧消化项数（队列空返回 0——零成本早退）。
	# R221 Fix A（vc27 回归 #1）：成本自适应占空——单项原子（整条字号梯）在真机
	# 3.7-6.7ms/次 × 7 次 ≈ 25-47ms 远超 12ms 预算，逐帧连泵把菜单期钉在 fps17-26。
	# 还账口径：末项实际耗时超预算 → 后续帧按 ceil(cost/budget)−1 跳帧零成本直返
	#（跳帧期间菜单帧空载回弹），占空比摊还后等效预算仍 12ms/帧。桌面单项 ~0.9ms
	# 恒不触发跳帧——零扰动。
	if _queue.is_empty():
		return 0
	if _skip_frames > 0:
		_skip_frames -= 1
		return 0
	_pumped_frames += 1
	var done := 0
	var t0 := Time.get_ticks_usec()
	while not _queue.is_empty():
		var job: Dictionary = _queue[0]
		var it0 := Time.get_ticks_usec()
		CardSelectUI._fit_desc(String(job["text"]), float(job["cw"]),
			bool(job["compact"]), float(job["ls"]))
		_queue.pop_front()
		_last_item_us = int(Time.get_ticks_usec() - it0)
		done += 1
		if Time.get_ticks_usec() - t0 >= p_budget_us:
			break
	_skip_frames = skip_frames_for(_last_item_us, p_budget_us)
	return done


static func skip_frames_for(p_cost_us: int, p_budget_us: int) -> int:
	# 纯函数（可测）：单项成本超预算 → 跳帧数 = ceil(cost/budget) − 1（还账占空）；
	# 预算内（桌面常态）返回 0。p_budget_us ≤ 0 视为无预算约束（pump(0) 语义=恰 1 项，
	# 不折算跳帧）。
	if p_budget_us <= 0 or p_cost_us <= p_budget_us:
		return 0
	var frames := int(ceil(float(p_cost_us) / float(p_budget_us)))
	return frames - 1


static func remaining() -> int:
	# 测试观测口：未消化项数
	return _queue.size()


static func total_built() -> int:
	# 测试观测口：建队总项数（0 = 未建队）
	return _total_built


static func reset_for_tests() -> void:
	# 测试隔离口：清队复位（产品路径不调）
	_queue.clear()
	_built = false
	_total_built = 0
	_pumped_frames = 0
	_skip_frames = 0
	_last_item_us = 0
