# scripts/ui/menu_screen.gd
# 集成包 A：主菜单屏（MENU 状态宿主）—— 方向 C「晴空糖果」贴纸风重设计。
# 淡云天空底 + 「INFINITE FISSION」双色字母大 logo + 副题「∞ 链式裂变乐园」+ 哨兵-9
# 圆舰吉祥物漂浮 idle + 「出发！」果冻脉动按钮 + lore 引导文案。
# GameLoop 状态机（迁移矩阵冻结）MENU → PLAYING 唯一入口 start_run()——本屏仅申请：
# start_requested 信号 → GameLoop.start_run（仲裁权在 GameLoop，E-16 同源）。
# 可见性绑定 state_changed（仅 MENU 显示）。process_mode = ALWAYS（Q-14 口径）。
# 大厅扩展（META_ROADMAP M4+M6 落地，用户反馈「大厅、图鉴、成就」）：出发按钮下方
# 三入口（图鉴 / 成就 / 记录）→ 全屏详情面板（图鉴 = 怪物/武器/词条三页签，遇解锁口径）。
class_name MenuScreen
extends CanvasLayer

# R220 刀2（D3）：卡面描述预热器（preload——预热器不声明 class_name，防 headless
# -s 模式全局类缓存不重扫）
const CardDescPrewarm := preload("res://scripts/cards/card_desc_prewarm.gd")

# R252D P2：图鉴行描述测量缓存（desc 全文 → get_multiline_string_size 高度）。进程级
# static——codex 行 desc 为静态 .tres 字段或固定锁定句，跨局不变、无失效面。
static var _row_measure: Dictionary = {}

signal start_requested()                      # → GameLoop.start_run()（MENU → PLAYING，兼容口）
signal start_map_requested(map_id: StringName, difficulty: int)   # 选图启动（M2 多地图 + R72 难度档 → GameLoop._on_menu_start）
signal start_daily_requested()                # 每日挑战启动（P2 → GameLoop._on_menu_start_daily）
signal settings_requested()                   # 设置页打开（P3 → GameLoop 接线 SettingsPanel.open）
signal continue_requested()                   # 继续上次进度（局内存档 → GameLoop.continue_run，2026-08-31）

var registry: DataRegistry = null             # GameLoop Boot 期注入（图鉴全量清单）

var _root: Control = null
var _start_btn: Button = null
var _continue_btn: Button = null              # 继续上次进度（有局内存档时可见，2026-08-31）
var _pulse_tween: Tween = null                # 出发按钮果冻脉动（隐藏时暂停）
var _mascot: TextureRect = null
var name_tag: Label = null                    # 吉祥物名签（R13：随当前角色刷新）
var _bob_tween: Tween = null                  # 吉祥物漂浮 idle
var _lobby_btns: Dictionary = {}              # 入口按钮（kind → Button，刷新计数角标）
# 详情面板运行期
var _sel_difficulty: int = 0                   # R72 难度三档（0 普通/1 困难/2 地狱；选关面板内切换）
var _diff_btns: Array[Button] = []             # 难度三档切换按钮（选中态刷新）
var _export_log_btn: Button = null            # R205：诊断日志导出（左下角）
var _clear_log_btn: Button = null             # R208：诊断日志主动清空（导出右侧）
var _exporting: bool = false                  # R292：导出分段协程重入锁（进行中再按=无操作）
var _export_overlay: Control = null           # R292：导出进度覆盖层（遮罩+进度条+阶段文案）
var _export_bar: ProgressBar = null           # R292：覆盖层进度条（0-100 段阶：5/45/85/100）
var _export_stage_lbl: Label = null           # R292：覆盖层阶段文案（组装/剪贴板/预览/完成）
var _export_t0_msec: int = 0                  # R292-M1：按下时刻（最小展示时长的墙钟基准）

# R292-M1（评审）：快路径整程仅 3-4 帧，全屏遮罩 <0.1s 一闪而过会被当闪屏 bug——
# 不足此时长时覆盖层持有一瞬（100% 收尾帧再撤）；慢真机路径自然超时零影响。
const EXPORT_OVERLAY_MIN_MS := 300
var _panel_root: Control = null
var _panel_title: Label = null
var _panel_list: Control = null
var _hint_label: Label = null                 # R257：菜单顶一次性提示（出发拒绝可见化）
var _hint_left: float = 0.0                   # R257：提示剩余展示秒（_process 递减自隐）


func flash_hint(p_text: String) -> void:
	# R257：一次性可见反馈（出发被拒修前=静默 push_warning+return——真机「点了出发
	# 没反应/回主页」形态的可见化；GameLoop._on_menu_start 拒绝分支直调）。
	# 评审H1：move_to_front 每次闪现重申置顶——挂载序会被后续懒挂兄弟（面板/弹窗）
	# 压回去，靠创建顺序不可靠；此处幂等置顶=绘制序恒兄弟末位（盖一切菜单内容）
	if _hint_label == null:
		return
	_hint_label.text = p_text
	_hint_label.move_to_front()
	_hint_label.visible = true
	_hint_left = 3.0
var _codex_tabs: Dictionary = {}              # 页签按钮（页名 → Button）
var _codex_tab: String = "怪物"
# ── R254-1 图鉴页级行缓存（真机「菜单点一下卡一下」主源=切页全量重建行树：反应页
# 82ms/祝福页 52ms/图鉴首开 70ms——真机 2-4×慢=百毫秒级停顿）。缓存 tab→行数组，
# 切页只换挂树；失效口=回大厅（击杀数/解锁态每局变）+ codex_changed；菜单闲时
# 分帧预建五页（_process 预热泵同 CardDescPrewarm 模式），首开/首切全变挂树 ──
var _codex_page_cache: Dictionary = {}        # tab(String) → Array[Control]（缓存行）
# ── R259 大厅三面板行缓存（真机反馈「点击关卡/成就/图鉴掉帧严重」——直调实测
# 成就 13-14ms/选人 14-16ms/选关 10ms 超 60fps 预算 2-7 倍，真机渲染侧再 ×2-4。
# R254-1 图鉴行缓存模式推广：①成就=页缓存+完成态签名+desc 进度轻刷（sig=页码+done
# 位图；mark/name 色随 done 由 sig 涵盖，进度数字轻刷）；②选人=全量签名法（行内
# 全部动态输入入 sig——picked/解锁/购买力/自定义武器/图鉴计数/击杀总数/无尽深度，
# sig 同直挂、变则重建——无失效口=无陈旧数据风险）；③选关=分档缓存（难度→行数组，
# 行内锁定态/星标/难度过滤 note 静态 per 档；失效口=map_records_changed——R259 Meta
# 新信号，结算/通关喂入两写点 emit）。行名标 AchRow_/CharRow_/MapRow_ 入
# _recycle_panel_rows detach 白名单（detach 回缓存不 free——图鉴 CodexRow_ 同款）──
var _ach_page_cache: Dictionary = {}         # R259：成就行缓存（页码 → {sig, rows}）
var _char_rows_cache: Dictionary = {}        # R259：选人行缓存（{sig, rows}——单页全量）
var _map_rows_cache: Dictionary = {}         # R259：选关地图行缓存（难度 → Array[Control]）
# ── R267 刀P3：选卡外三面板行缓存（记录/养成/每日——r267_menu_probe 基线：记录
# 5668µs / 养成 11782µs / 每日 3233µs 每次开合全量重建行树，真机 ×2-4）。失效机制 =
# 开面板时指纹快照比对（纯读 Meta 现有接口，零信号——每日结算分支提前 return 不发
# 信号、结晶/星尘无货币信号，信号接线不可行＝设计 v2 评审④定谳）。指纹字段 = 面板
# 实际显示字段全集（v3 评审⑴构造规矩：漏字段=陈旧行）：
#   记录 = (best_wave/best_kills/best_level/total_runs/total_kills + 分图记录摘要 +
#           通关图数——「累计击杀」逐杀累加即变，每日局结算早退也覆盖)；
#   每日 = (daily_date_key + 当日 best_wave/best_kills)；
#   养成 = (crystals + stardust + 已购 id→lv 映射——星尘独立变（祝福扣费放弃未结算）
#           也命中，v3 评审⑴-② 字段级陈旧面)；行名标 RecRow_/UpgRow_/DlyRow_ 入
#   _recycle_panel_rows detach 白名单（R259 同构）。──
var _rec_rows_cache: Array = []              # RecRow_ 行缓存（records 面板全量行）
var _rec_fp: String = ""                     # 记录面板指纹（上次重建时的显示字段快照）
var _rec_row_seq: int = 0                    # RecRow_ 名标序号
var _upg_rows_cache: Array = []              # UpgRow_ 行缓存（行序 = Meta.UPGRADES 序）
var _upg_row_refs: Array = []                # R267 刀P3：行内动件引用（轻刷新用——
                                             # {name_l, buy, u}，与缓存行同序）
var _upg_fp: String = ""                     # 养成面板指纹
var _upg_head: Label = null                  # 结晶头行引用（轻刷新货币角标）
var _upg_sd: HBoxContainer = null            # 星尘行引用（轻刷新，其内 Label 刷文案）
var _upg_row_seq: int = 0                    # UpgRow_ 名标序号
var _dly_rows_cache: Array = []              # DlyRow_ 行缓存
var _dly_fp: String = ""                     # 每日面板指纹
var _dly_row_seq: int = 0                    # DlyRow_ 名标序号
# ── R260 弹层/面板模态期预热泵挂起（真机「祝福面板 Q 弹动画帧率低」主源：动画帧
# 叠加 CardDescPrewarm 4ms+图鉴泵 4ms 帧预算 + menu 渲染底噪 8.7-9.9ms ≈ 60fps 预算
# 爆表——泵产出（卡描述/图鉴行缓存）在面板关闭前无消费者，模态期全停零损失）──
var _lobby_detail_open := false              # 大厅详情面板开（成就/图鉴/选人/选关…）
var _panel_kind := ""                        # R260：当前详情面板 kind（图鉴泵豁免判据）
var _blessing_modal := false                 # 祝福弹层模态期（game_loop 面板 open/收口调）
var _settings_modal := false                 # R260 评审 MED-1：设置全屏弹层期（game_loop 调）
var _codex_prewarm_queue: Array[String] = []  # 待预建页序（闲时泵逐页消化；空=毕）
var _codex_row_seq: int = 0                   # CodexRow_ 名标序号（缓存行回收判据）
var _codex_pump_tab: String = ""              # R254 修轮#2：泵在建页（行级状态机——空=待取队首）
var _codex_pump_rows: Array = []              # 在建页半成品行（页毕入缓存；被抢建则整体弃置）
var _codex_pump_skip_frames: int = 0          # R262b M2：超支还账跳帧（冷行 10-25ms 后占空）
var _codex_pump_i: int = 0                    # 在建页行游标
# ── R191#6 成就面板类别页签 + 分页（成就扩容配套：页容量 24 控单页行构建成本） ──
var _ach_tabs: Dictionary = {}                # 类别页签（页名 → Button）
var _ach_tab: String = "全部"
var _ach_page: int = 0                        # 当前页（0 基）
var _ach_prev_btn: Button = null
var _ach_next_btn: Button = null
var _ach_page_label: Label = null
const ACH_PAGE_SIZE := 24                     # 成就分页页容量
# 成就类别归类真源（type 字段 → 页签名；未知 type 归「进阶」兜底——三类别页签遍历
# 累加恒等于全量，新族落地漏配也不丢行）
const ACH_TYPE_CATEGORY := {
	"total_kills": "猎杀", "boss_slain": "猎杀", "enemy_kills": "猎杀",
	"run_wave": "进阶", "run_level": "进阶", "total_runs": "进阶",
	"run_reactions": "进阶",                    # R192 反应族（单局触发反应数，run 域同进阶）
	"endless_depth": "进阶",                    # R247 无尽深度成就阶梯（_channels.md §2.2；未知
	                                           # type 兜底本就「进阶」，显式登记为可读性）
	# R245 B 组技巧/经历族 8 族（累计施放/阵亡/擦弹/格挡/质变/复活/刷新/告警——全 run 外
	# 累计口径归「进阶」；未知 type 兜底「进阶」，显式登记为可读性）
	"total_skill_casts": "进阶", "total_deaths": "进阶", "total_graze": "进阶",
	"total_blocks": "进阶", "total_milestones": "进阶", "total_revives": "进阶",
	"total_rerolls": "进阶", "total_alarms": "进阶",
	"run_weapons_drawn": "收集", "run_traits_drawn": "收集",
	"codex_weapons": "收集", "codex_traits": "收集", "maps_cleared": "收集",
	"codex_relics": "收集",                     # R245 遗物收集族（图鉴收录件数）
}
var _char_new_badge: bool = false             # R186：新角色解锁「·新」角标（打开选人面板清除）
var _panel_defer_open: bool = false           # R252D P6：大厅面板作用域批落盘包络在开标志


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	_build_ui()
	_build_lobby()
	_build_panel()
	_root.visible = false
	# R195 适配：安全区接入（底座组 SafeAreaHelper 单点引用，不复写）。守卫外
	# （桌面窗口化/headless）insets 恒零 → offset 写 0 = 默认窗逐位恒等；真机延迟
	# ≥1 帧重读兜首帧 transform 未定型，size_changed/重获焦点由 helper 重放回调。
	_apply_safe_area()
	if SafeAreaHelper.enabled(get_window()):          # 守卫外恒零→零协程悬挂（headless 全绿面）
		_apply_safe_area_deferred()                # 真值环境延迟重读（SafeAreaHelper 契约）
	SafeAreaHelper.bind_reread(get_window(), _apply_safe_area)
	EventBus.state_changed.connect(_on_state_changed)
	Meta.codex_changed.connect(_refresh_lobby_counts)
	Meta.codex_changed.connect(_invalidate_codex_cache)   # R254-1：解锁态变即失效（局内兑现边沿）
	Meta.map_records_changed.connect(_invalidate_map_rows_cache)   # R259：通关记录变→选关行缓存弃置
	_codex_prewarm_queue = _codex_tab_preset().duplicate()   # R254-1：闲时泵首次排程
	Meta.fissioner_unlocked.connect(_on_fissioner_unlocked)   # R186：普通通关解锁角标
	Meta.echo_unlocked.connect(_on_fissioner_unlocked)        # R198（二aw-6）：困难/地狱通关解锁角标（复用同处理器——两新角色「·新」角标统一）
	# R246(P2)：无尽深度成就门角色角标——medic/vortex 门与 endless_depth_20/50 成就
	# 同计数同阈值同刻兑现（_channels.md §2.4 等价性：结算 _check_achievements 边沿恰
	# 在角色解锁时刻发信号），订阅 achievements_changed 置位即得解锁边沿，无需新专属
	# 信号（noah 成就门现状亦无角标，行为一致仅新门补齐）
	Meta.achievements_changed.connect(_on_endless_depth_char_ach)


func _apply_safe_area() -> void:
	# R195 安全区应用（消费式契约=SafeAreaHelper.insets 注释）：根 FULL_RECT
	# offset 左/上取正、右/下取负；底色/云 FULL_RECT 子件随根，面板锚组在让位域内锚定。
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


func _on_fissioner_unlocked() -> void:
	# R186：改造者·枢解锁（结算兑现点派发）——「角色」入口加「·新」角标
	# R198（二aw-6）：echo_unlocked 同接本处理器（menu_screen _ready 连接区）——
	# 回响·伊可解锁角标语义统一（信号源 meta_manager 结算兑现点，恰发一次边沿）
	_char_new_badge = true
	_refresh_lobby_counts()


func _on_endless_depth_char_ach(p_ach_id: StringName) -> void:
	# R246(P2)：无尽深度成就阶梯解锁边沿（endless_depth_20→medic / _50→vortex）
	# ——门与成就同源同阈值，此刻即新角色解锁时刻，「角色」入口加「·新」角标
	#（打开选人面板清除，_char_new_badge 既有口径复用）
	if p_ach_id == &"endless_depth_20" or p_ach_id == &"endless_depth_50":
		_char_new_badge = true
		_refresh_lobby_counts()


func _process(p_delta: float) -> void:
	# R220 刀2（D3）：MENU 态驱动卡面描述预热器（CardDescPrewarm 12ms/帧分帧消化）。
	# 门 = _root.visible（_on_state_changed 联动——仅 MENU 真）：离开菜单自动暂停、
	# 回菜单继续（队列进度保留）；_built 幂等守卫使建队仅一次。选卡/战斗/结算期
	# 本回调一读即返——预热不占 game_loop 物理帧预算（契约 §1-D3/§8 裁定#5）。
	if _root == null or not _root.visible:
		return
	# R257：顶横幅提示自隐（flash_hint 3s）
	if _hint_left > 0.0:
		_hint_left -= p_delta
		if _hint_left <= 0.0 and _hint_label != null:
			_hint_label.visible = false
	# R260：模态期泵挂起（弹层动画/面板操作的每帧预算让给前景）。分泵口径：
	# CardDescPrewarm（卡面描述——菜单任何面板期无消费者）任一模态开即停；
	# 图鉴泵（R254 行级分帧预建=图鉴切页缓存的消费者）仅祝福弹层全遮期或非图鉴
	# 面板期停——图鉴面板开着时继续（切页预建不中断，目标页队首优先口径不变）
	var card_desc_ok := not _lobby_detail_open and not _blessing_modal and not _settings_modal
	var codex_pump_ok := not _blessing_modal and not _settings_modal \
			and (not _lobby_detail_open or _panel_kind == "codex")
	if card_desc_ok:
		CardDescPrewarm.ensure_built(registry)
		CardDescPrewarm.pump(CardDescPrewarm.BUDGET_US)
	if not codex_pump_ok:
		return
	# R262b M2：冷图标行 10-25ms 单行必超 4ms 预算——超支帧后跳帧还账
	#（对照 CardDescPrewarm.skip_frames_for 先例：ceil(成本/预算)−1 占空），
	# 图鉴浏览期连续冷行不再逐帧 10-25ms 顿挫。
	if _codex_pump_skip_frames > 0:
		_codex_pump_skip_frames -= 1
		return
	# R254-1 刀B + 修轮#2：菜单闲时分帧预建图鉴五页行缓存——行级状态机（4ms/帧
	# 预算逐行建，单行为最小原子）。修轮前整页原子：武器页冷图标一帧 310ms（真机
	# 外推 0.6-1.2s 冻结）；行级后最坏帧=单行成本（图标冷画 ~10-25ms），摊销到
	# 多帧。玩家同步路径（_rebuild_codex）若抢建了泵在建页：页毕发现缓存已有→
	# 半成品行整体弃置（不入缓存即防覆盖，逐行 free 防泄漏）
	if _codex_prewarm_queue.is_empty() and _codex_pump_tab == "":
		return
	var t0 := Time.get_ticks_usec()
	while Time.get_ticks_usec() - t0 < 4000:
		if _codex_pump_tab == "":
			if _codex_prewarm_queue.is_empty():
				return
			_codex_pump_tab = _codex_prewarm_queue.pop_front()
			_codex_pump_rows = []
			_codex_pump_i = 0
			if _codex_page_cache.has(_codex_pump_tab):   # 已被同步路径建好（竞态兜底）
				_codex_pump_tab = ""
				continue
		var pumped := _make_codex_entry_row(_codex_pump_tab, _codex_pump_i)
		if pumped == null:
			if not _codex_page_cache.has(_codex_pump_tab):
				_codex_page_cache[_codex_pump_tab] = _codex_pump_rows
			else:                                       # 同步抢建已入缓存：半成品弃置
				for ghost: Node in _codex_pump_rows:
					ghost.queue_free()
			_codex_pump_tab = ""
			_codex_pump_rows = []
			continue
		_codex_pump_rows.append(pumped)
		_codex_pump_i += 1
	# R262b M2 还账：循环退出时若在建行中且本帧超支（帧耗时含末次冷行），按
	# skip_frames_for 占空跳帧；行全热（桌面常态微秒级）恒不触发——零扰动。
	if _codex_pump_tab != "":
		var frame_us := int(Time.get_ticks_usec() - t0)
		if frame_us > 4000:
			_codex_pump_skip_frames = CardDescPrewarm.skip_frames_for(frame_us, 4000)


func _on_state_changed(p_state: int) -> void:
	# 仅 MENU 态显示（PLAYING/LEVEL_UP/PAUSED/GAME_OVER 均隐藏）；动效随可见性启停
	var show := p_state == GameConst.GameStatus.MENU
	_root.visible = show
	if not show:
		# R260 评审 HIGH-1 防御层：离菜单=一切面板/弹层模态作废（出发直关两口已清位，
		# 此处兜底任何未来新增的绕关口——残留标志会让回大厅双泵永久停摆）
		_lobby_detail_open = false
		_panel_kind = ""
		_blessing_modal = false
		_settings_modal = false
	if show:
		_refresh_continue_btn()
		_refresh_lobby_counts()               # R254 评审#7：新敌首杀无信号——角标回菜单即刷
		if not _codex_page_cache.is_empty() or not _codex_prewarm_queue.is_empty() 				or _codex_pump_tab != "":
			# R254-1：回大厅=击杀数/解锁态已变（局内累积不逐事件广播），图鉴行
			# 缓存失效重备；反应页内容纯静态免重建（修轮#3a）。首进 MENU（缓存
			# 空+队列已排）不触发——_ready 排程不空转
			_invalidate_codex_cache(true)
	if _pulse_tween != null:
		if show:
			_pulse_tween.play()
		else:
			_pulse_tween.pause()
	if _bob_tween != null:
		if show:
			_bob_tween.play()
		else:
			_bob_tween.pause()


func _build_ui() -> void:
	_root = Control.new()
	_root.name = "MenuRoot"
	_root.theme = StickerTheme.theme()
	_root.set_anchors_preset(Control.PRESET_FULL_RECT)
	_root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_root)

	# R257：菜单顶横幅提示（出发拒绝等一次性可见反馈——GameLoop 直调 flash_hint）。
	# 评审H1：挂载序不可依赖（本块先挂、不透明 MenuBg 后挂画在其上=曾被整层盖住），
	# 置顶由 flash_hint() 内 move_to_front 每次闪现时重申；y=215 净空带（logo 258 起，
	# 修前 250 与其重叠 26px）+ R195 全宽锚（宽视口随动，同 logo 口径）；3s 自隐
	_hint_label = Label.new()
	_hint_label.name = "MenuHint"
	StickerTheme.label_sticker(_hint_label, 16, PopPalette.INK, 2, Color.WHITE, true)
	_hint_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_hint_label.set_anchors_preset(Control.PRESET_TOP_WIDE)
	_hint_label.offset_left = 0.0
	_hint_label.offset_right = 0.0
	_hint_label.offset_top = 215.0
	_hint_label.offset_bottom = 249.0
	_hint_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_hint_label.visible = false
	_root.add_child(_hint_label)

	# 淡云天空底（不透明 #EEF3FF，盖住战场）+ 漂移云层
	var bg := ColorRect.new()
	bg.name = "MenuBg"
	bg.color = PopPalette.BG
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_root.add_child(bg)
	var clouds := CloudBackdrop.new()
	clouds.name = "MenuClouds"
	clouds.base_z = 0                            # 菜单内：云层盖住底色（世界层则沉底）
	_root.add_child(clouds)

	# 大 logo：字母双色交替（天空蓝/珊瑚红）+ 白描边贴纸字
	# R195 适配分区：全宽拉伸锚（anchor_l=0/anchor_r=1、y 不变；720×1280 恒等，
	# 宽视口下满宽 + ALIGNMENT_CENTER 随动）
	var logo := HBoxContainer.new()
	logo.name = "Logo"
	logo.add_theme_constant_override("separation", 2)
	logo.anchor_right = 1.0
	logo.offset_left = 0.0
	logo.offset_right = 0.0
	logo.offset_top = 258.0
	logo.offset_bottom = 322.0
	logo.alignment = BoxContainer.ALIGNMENT_CENTER
	logo.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_root.add_child(logo)
	for i in range(Lore.LOGO.length()):
		var ch := Lore.LOGO[i]
		if ch == " ":
			var gap := Control.new()
			gap.custom_minimum_size = Vector2(14.0, 10.0)
			gap.mouse_filter = Control.MOUSE_FILTER_IGNORE
			logo.add_child(gap)
			continue
		var letter := Label.new()
		var fill := PopPalette.PLAYER if i % 2 == 0 else PopPalette.ENEMY
		StickerTheme.label_sticker(letter, 50, fill, 8, Color.WHITE, true)
		letter.text = ch
		logo.add_child(letter)

	# 副题 + lore 引导文案
	var subtitle := Label.new()
	StickerTheme.label_sticker(subtitle, 24, PopPalette.INK, 0, Color.WHITE, true)
	subtitle.text = Lore.SUBTITLE
	# R195 适配分区：全宽拉伸锚（y 不变恒等；宽视口下满宽居中）
	subtitle.anchor_right = 1.0
	subtitle.offset_left = 0.0
	subtitle.offset_right = 0.0
	subtitle.offset_top = 342.0
	subtitle.offset_bottom = 376.0
	subtitle.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_root.add_child(subtitle)
	for i in range(Lore.MENU_LINES.size()):
		var line := Label.new()
		StickerTheme.label_sticker(line, 16, PopPalette.INK_SOFT)
		line.text = Lore.MENU_LINES[i]
		# R10：上移给「继续上次进度」让位（原 660 与按钮重叠）
		# R195 适配分区：全宽拉伸锚（offset=现值−锚点设计位，y 行距恒等）
		line.anchor_right = 1.0
		line.offset_left = 0.0
		line.offset_right = 0.0
		line.offset_top = 636.0 + 26.0 * float(i)
		line.offset_bottom = 658.0 + 26.0 * float(i)
		line.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		_root.add_child(line)

	# 哨兵-9 圆舰吉祥物（漂浮 idle：上下浮动 + 轻微摇摆）
	_mascot = TextureRect.new()
	_mascot.name = "Sentinel9"
	_mascot.texture = TextureFactory.ship()
	# R195 适配分区：横向居中锚（offset=现值−锚点(360,0)：左 310−360、右沿 410−360
	# 贴中恒 ±50px；bob 补间仍写 position:y，宽视口下与全宽文字栈同随 vis 中心）
	_mascot.anchor_left = 0.5
	_mascot.anchor_right = 0.5
	_mascot.offset_left = -50.0
	_mascot.offset_right = 50.0
	_mascot.offset_top = 452.0
	_mascot.offset_bottom = 552.0
	_mascot.custom_minimum_size = Vector2(100.0, 100.0)
	_mascot.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_mascot.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	_mascot.pivot_offset = Vector2(50.0, 50.0)
	_mascot.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_root.add_child(_mascot)
	name_tag = Label.new()
	StickerTheme.label_sticker(name_tag, 15, PopPalette.PLAYER, 0, Color.WHITE, true)
	_refresh_mascot()
	# R195 适配分区：全宽拉伸锚（y 不变恒等）
	name_tag.anchor_right = 1.0
	name_tag.offset_left = 0.0
	name_tag.offset_right = 0.0
	name_tag.offset_top = 566.0
	name_tag.offset_bottom = 586.0
	name_tag.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_root.add_child(name_tag)

	# 出发！按钮（果冻脉动；贴纸四态由 Theme 承担）
	_start_btn = Button.new()
	_start_btn.name = "StartButton"
	_start_btn.text = Lore.START_BUTTON
	_start_btn.add_theme_font_size_override("font_size", 30)
	_start_btn.add_theme_font_override("font", StickerTheme.font_bold())
	# R195 适配分区：横向居中锚（offset=现值−锚点(360,0)：左 260−360、右沿 460−360
	# 恒 ±100px；R194 触控 200×84 几何与默认窗落位恒等，宽视口下随 vis 中心）
	_start_btn.anchor_left = 0.5
	_start_btn.anchor_right = 0.5
	_start_btn.offset_left = -100.0
	_start_btn.offset_right = 100.0
	_start_btn.offset_top = 790.0
	_start_btn.offset_bottom = 874.0
	_start_btn.pivot_offset = Vector2(100.0, 42.0)
	_start_btn.pressed.connect(_on_start_pressed)
	_start_btn.button_down.connect(func() -> void: StickerTheme.press_punch(_start_btn))
	_root.add_child(_start_btn)
	_pulse_tween = StickerTheme.pulse(_start_btn, 1.15, 0.045)

	# 继续上次进度（局内存档入口，2026-08-31 用户反馈「回到菜单再进入可选择继续上次进度」）：
	# 出发按钮上方；有档才可见（文案带地图/波次摘要），点击 → GameLoop.continue_run
	_continue_btn = Button.new()
	_continue_btn.name = "ContinueButton"
	_continue_btn.text = "继续上次进度"
	_continue_btn.add_theme_font_size_override("font_size", 17)
	_continue_btn.add_theme_font_override("font", StickerTheme.font_bold())
	# R195 适配分区：横向居中锚（offset=现值−锚点(360,0)：左 190−360、右沿 530−360
	# 恒 ±170px；R10 文案（至 ~712）与出发（790）之间落位恒等，宽视口下随 vis 中心）
	_continue_btn.anchor_left = 0.5
	_continue_btn.anchor_right = 0.5
	_continue_btn.offset_left = -170.0
	_continue_btn.offset_right = 170.0
	_continue_btn.offset_top = 722.0
	_continue_btn.offset_bottom = 770.0
	_continue_btn.pivot_offset = Vector2(170.0, 24.0)
	_continue_btn.pressed.connect(_on_continue_pressed)
	_continue_btn.button_down.connect(func() -> void: StickerTheme.press_punch(_continue_btn))
	_continue_btn.visible = false
	_root.add_child(_continue_btn)

	# 吉祥物漂浮 idle（正弦 bob + 摇摆）
	_bob_tween = _mascot.create_tween().set_loops()
	_bob_tween.tween_property(_mascot, "position:y", 440.0, 1.4) \
		.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
	_bob_tween.parallel().tween_property(_mascot, "rotation", 0.06, 1.4) \
		.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
	_bob_tween.tween_property(_mascot, "position:y", 464.0, 1.4) \
		.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
	_bob_tween.parallel().tween_property(_mascot, "rotation", -0.06, 1.4) \
		.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)

	# 版本脚注
	# R195 适配分区：全宽拉伸锚 + 下锚（offset=现值−锚点(0,1280)：上 1216−1280、
	# 底沿 1236−1280 恒 44px；高视口下贴 vis 底）
	var footer := Label.new()
	StickerTheme.label_sticker(footer, 13, PopPalette.INK_SOFT)
	footer.text = "竖屏弹幕防御 · Roguelike"
	footer.anchor_right = 1.0
	footer.anchor_top = 1.0
	footer.anchor_bottom = 1.0
	footer.offset_left = 0.0
	footer.offset_right = 0.0
	footer.offset_top = -64.0
	footer.offset_bottom = -44.0
	footer.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_root.add_child(footer)

	# R205 版本行（运行时真源 DebugStats.version_string——与 APK 文件名/诊断日志同口径；
	# 真机排障先对版本再读日志，防老数据混流）
	var vfooter := Label.new()
	vfooter.name = "VersionFooter"
	StickerTheme.label_sticker(vfooter, 13, PopPalette.INK_SOFT)
	vfooter.text = DebugStats.version_string()
	vfooter.anchor_right = 1.0
	vfooter.anchor_top = 1.0
	vfooter.anchor_bottom = 1.0
	vfooter.offset_left = 0.0
	vfooter.offset_right = 0.0
	vfooter.offset_top = -86.0
	vfooter.offset_bottom = -66.0
	vfooter.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_root.add_child(vfooter)

	# R205「导出日志」按钮（左下角；用户点名：主页面一键导出诊断日志发开发者——
	# 玩几分钟后返回大厅点此，全文已在剪贴板可直接粘贴发送）
	_export_log_btn = Button.new()
	_export_log_btn.name = "ExportLogButton"
	_export_log_btn.text = "导出日志"
	_export_log_btn.add_theme_font_size_override("font_size", 14)
	_export_log_btn.add_theme_font_override("font", StickerTheme.font_bold())
	_export_log_btn.anchor_top = 1.0
	_export_log_btn.anchor_bottom = 1.0
	_export_log_btn.offset_left = 14.0
	_export_log_btn.offset_right = 126.0
	_export_log_btn.offset_top = -108.0
	_export_log_btn.offset_bottom = -80.0
	_export_log_btn.pressed.connect(_on_export_log_pressed)
	_export_log_btn.button_down.connect(func() -> void: StickerTheme.press_punch(_export_log_btn))
	_root.add_child(_export_log_btn)

	# R208「清空日志」按钮（导出右侧；用户点名主动清空——开局清一次，导出只带
	# 怪多重载期的有效数据；按钮文字瞬时反馈「已清空N」1.5s 还原）
	_clear_log_btn = Button.new()
	_clear_log_btn.name = "ClearLogButton"
	_clear_log_btn.text = "清空日志"
	_clear_log_btn.add_theme_font_size_override("font_size", 14)
	_clear_log_btn.add_theme_font_override("font", StickerTheme.font_bold())
	_clear_log_btn.anchor_top = 1.0
	_clear_log_btn.anchor_bottom = 1.0
	_clear_log_btn.offset_left = 130.0
	_clear_log_btn.offset_right = 242.0
	_clear_log_btn.offset_top = -108.0
	_clear_log_btn.offset_bottom = -80.0
	_clear_log_btn.pressed.connect(_on_clear_log_pressed)
	_clear_log_btn.button_down.connect(func() -> void: StickerTheme.press_punch(_clear_log_btn))
	_root.add_child(_clear_log_btn)

	# R212：「记录日志」采样开关按钮已迁入设置页（settings_panel「记录日志」+「日志
	# 长度」两行——大厅设置按钮/暂停卡设置双入口，局中局外均可达，且每次 open 经
	# _sync_from_meta 回填不会显过期 ✓/✗ 态）；底带回到 R208 导出（14-126）/清空
	#（130-242）两枚。


func _on_clear_log_pressed() -> void:
	# R208：主动清空诊断环形缓冲（开局清一次——导出只带怪多重载期数据）
	var n: int = DebugStats.diag_clear()
	_clear_log_btn.text = "已清空%d" % n
	get_tree().create_timer(1.5).timeout.connect(func() -> void:
		if is_instance_valid(_clear_log_btn):
			_clear_log_btn.text = "清空日志")


func _on_export_log_pressed() -> void:
	# R205：导出诊断日志（DebugStats 1Hz 环形缓冲 15 分钟）——写 user:// 文件 +
	# 全文进剪贴板（微信/QQ 直接粘贴发送）+ 滚动预览对话框（尾部最关键：卡点在最后）
	# R292：分段跨帧+进度覆盖层（用户反馈：真机一键导出「跟卡了一样」——组装/写盘、
	# 剪贴板大字符串、弹预览框全挤在按下那一帧同步跑且零反馈）。拆三段，段间
	# await 让覆盖层先行渲染；进行中按钮禁用+重入锁，双击不叠开第二个对话框。
	# 产物不变：同一 DebugStats.diag_export()/diag_copy_to_clipboard()，文件/剪贴板/
	# 对话框口径逐位同前（runner r205 迁移为帧泵收敛后查框）。
	if _exporting:
		return
	_exporting = true
	_export_t0_msec = Time.get_ticks_msec()
	if _export_log_btn != null:
		_export_log_btn.disabled = true
	_build_export_overlay()
	_set_export_stage(5, "正在组装日志…")
	await get_tree().process_frame
	var res: Dictionary = DebugStats.diag_export()
	_set_export_stage(45, "正在复制到剪贴板…")
	await get_tree().process_frame
	var copied := DebugStats.diag_copy_to_clipboard(str(res["text"]))
	_set_export_stage(85, "正在打开预览…")
	await get_tree().process_frame
	# R292-M1：最小展示时长——快路径在 100% 收尾帧上持有一瞬再弹框撤层；
	# R292-L1：阶段文案保持中性（不宣称「已写入/复制完成」——写盘失败/剪贴板
	# 不可用时对话框才是如实口径，覆盖层不先撒谎）。
	var held_ms := Time.get_ticks_msec() - _export_t0_msec
	_set_export_stage(100, "导出完成")
	if held_ms < EXPORT_OVERLAY_MIN_MS:
		await get_tree().create_timer((EXPORT_OVERLAY_MIN_MS - held_ms) / 1000.0).timeout
	_show_export_dialog(res, copied)
	_remove_export_overlay()
	if _export_log_btn != null and is_instance_valid(_export_log_btn):
		_export_log_btn.disabled = false
	_exporting = false


func _show_export_dialog(p_res: Dictionary, p_copied: bool) -> void:
	# R292：从 _on_export_log_pressed 抽出的预览对话框构建（内容口径逐位同 R205）。
	var text := str(p_res["text"])
	var dlg := AcceptDialog.new()
	dlg.name = "DiagExportDialog"                # 定名（脚本建节点缺省 @类@id 名，测试/定位需稳定名）
	dlg.title = "诊断日志 · %s" % DebugStats.version_string()
	dlg.ok_button_text = "关闭"
	var head := "文件: %s\n剪贴板: %s（去聊天框粘贴即可发送）\n%s\n────────\n" % [
		str(p_res["path"]),
		"已复制全文" if p_copied else "本机不可用",
		"尾部 24 行（完整内容见文件/剪贴板）:",
	]
	var lines := text.split("\n")
	var tail := "\n".join(lines.slice(maxi(lines.size() - 24, 0))) if lines.size() > 24 else text
	var sc := ScrollContainer.new()
	sc.custom_minimum_size = Vector2(600.0, 560.0)
	var lbl := Label.new()
	lbl.name = "DiagPreviewLabel"
	lbl.text = head + tail
	lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	lbl.custom_minimum_size = Vector2(580.0, 0.0)
	sc.add_child(lbl)
	dlg.add_child(sc)
	add_child(dlg)
	dlg.popup_centered_ratio(0.8)
	dlg.visibility_changed.connect(func() -> void:
		if not dlg.visible:
			dlg.queue_free())


func _build_export_overlay() -> void:
	# R292：导出进度覆盖层——全屏半透遮罩挡底层点击（导出中不可再点其他按钮），
	# 中心竖排 标题/进度条/阶段文案。挂 _root 尾部=兄弟绘制序最顶（同层后挂者盖上；
	# 与 R257 hint 同款「靠创建顺序不可靠」问题不存在——覆盖层生命周期即导出期，
	# 期间无懒挂兄弟入树）。防泄漏：残留旧覆盖层（异常路径）先清。
	if _export_overlay != null and is_instance_valid(_export_overlay):
		_remove_export_overlay()
	var ov := Control.new()
	ov.name = "DiagExportProgressOverlay"
	ov.set_anchors_preset(Control.PRESET_FULL_RECT)
	var dim := ColorRect.new()
	dim.name = "DiagExportDim"
	dim.color = Color(0.0, 0.0, 0.0, 0.45)
	dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	dim.mouse_filter = Control.MOUSE_FILTER_STOP
	ov.add_child(dim)
	var box := VBoxContainer.new()
	box.name = "DiagExportProgressBox"
	box.set_anchors_preset(Control.PRESET_CENTER)
	box.grow_horizontal = Control.GROW_DIRECTION_BOTH
	box.grow_vertical = Control.GROW_DIRECTION_BOTH
	box.add_theme_constant_override("separation", 10)
	var title := Label.new()
	title.name = "DiagExportTitleLabel"
	title.text = "正在导出日志"
	title.add_theme_font_size_override("font_size", 20)
	title.add_theme_font_override("font", StickerTheme.font_bold())
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	box.add_child(title)
	_export_bar = ProgressBar.new()
	_export_bar.name = "DiagExportProgressBar"
	_export_bar.min_value = 0.0
	_export_bar.max_value = 100.0
	_export_bar.value = 0.0
	_export_bar.show_percentage = false
	_export_bar.custom_minimum_size = Vector2(340.0, 16.0)
	# R292-L3（评审）：贴纸风格式——引擎默认灰蓝条游离于全局 UI 之外
	var bar_bg := StyleBoxFlat.new()
	bar_bg.bg_color = Color(0.13, 0.14, 0.18, 0.92)
	bar_bg.corner_radius_top_left = 8
	bar_bg.corner_radius_top_right = 8
	bar_bg.corner_radius_bottom_left = 8
	bar_bg.corner_radius_bottom_right = 8
	_export_bar.add_theme_stylebox_override("background", bar_bg)
	var bar_fill := StyleBoxFlat.new()
	bar_fill.bg_color = Color(0.36, 0.78, 0.46)
	bar_fill.corner_radius_top_left = 8
	bar_fill.corner_radius_top_right = 8
	bar_fill.corner_radius_bottom_left = 8
	bar_fill.corner_radius_bottom_right = 8
	_export_bar.add_theme_stylebox_override("fill", bar_fill)
	box.add_child(_export_bar)
	_export_stage_lbl = Label.new()
	_export_stage_lbl.name = "DiagExportStageLabel"
	_export_stage_lbl.add_theme_font_size_override("font_size", 14)
	_export_stage_lbl.add_theme_font_override("font", StickerTheme.font_bold())
	_export_stage_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	box.add_child(_export_stage_lbl)
	ov.add_child(box)
	_root.add_child(ov)
	_export_overlay = ov


func _set_export_stage(p_pct: int, p_text: String) -> void:
	# R292：段阶推进（进度条+文案一体刷新——文案自带百分数，进度条不显内嵌百分比）
	if _export_bar != null and is_instance_valid(_export_bar):
		_export_bar.value = float(p_pct)
	if _export_stage_lbl != null and is_instance_valid(_export_stage_lbl):
		_export_stage_lbl.text = "%s（%d%%）" % [p_text, p_pct]


func _remove_export_overlay() -> void:
	# R292：收尾撤覆盖层（queue_free 延迟释放——引用即清防悬挂）
	if _export_overlay != null and is_instance_valid(_export_overlay):
		_export_overlay.queue_free()
	_export_overlay = null
	_export_bar = null
	_export_stage_lbl = null


func _refresh_mascot() -> void:
	# 大厅吉祥物 = 当前选中角色（R13 用户反馈「大厅应显示当前选中的角色」）
	var def := CharacterTable.get_character(Meta.character_id)
	var tints := {
		&"sentinel": Color(1.0, 1.0, 1.0), &"veles": Color(1.0, 0.72, 0.72),
		&"bulwark": Color(0.72, 0.84, 1.0), &"ranger": Color(0.66, 1.0, 0.92),
		&"zero": Color(0.85, 0.72, 1.0), &"mank": Color(0.66, 1.0, 0.55),
		&"vera": Color(0.72, 1.0, 0.72), &"noah": Color(1.0, 0.93, 0.62),
		&"fission": Color(0.62, 0.9, 1.0), &"echo": Color(0.82, 0.66, 1.0),   # R186 新角色
	}
	_mascot.modulate = tints.get(Meta.character_id, Color.WHITE)
	name_tag.text = String(def.get("name", "哨兵-9"))


func _on_start_pressed() -> void:
	_open_map_select()                        # 出发 → 选关面板（M2 多地图，用户反馈）


func _on_continue_pressed() -> void:
	# 继续上次进度（仲裁在 GameLoop.continue_run：无档/坏档 false 兜底）
	continue_requested.emit()


func _refresh_continue_btn() -> void:
	# 有档可见 + 摘要文案（地图 · 第 N 波 · Lv）；无档隐藏
	if _continue_btn == null:
		return
	var data := RunSave.load_run()
	if data.is_empty():
		_continue_btn.visible = false
		return
	var map_name := String(MapTable.get_map(StringName(String(data.get("map_id", "")))).get("name", "?"))
	_continue_btn.text = "继续上次进度：%s · 第%d波 · Lv%d" % [map_name,
		int(data.get("wave", 1)), int(data.get("level", 1))]
	_continue_btn.visible = true


# ── 选关面板（出发按钮打开；通关链解锁——用户反馈「第一大关通关后打后面的」） ──
func _open_map_select() -> void:
	_panel_begin_defer()      # R252D P6：选关面板共用详情壳——同入批落盘包络
	_panel_root.visible = true
	_panel_title.text = "选择关卡"
	_lobby_detail_open = true                # R260：选关面板独立开口（不经 _on_lobby_pressed）
	_panel_kind = "map"
	for kind: String in _codex_tabs:
		(_codex_tabs[kind] as Button).visible = false
	for kind: String in _ach_tabs:
		(_ach_tabs[kind] as Button).visible = false
	_set_ach_pager_visible(false)
	_build_map_select_rows()
	StickerTheme.squash_pop(_panel_root.get_node("LobbyPanel") as Control)


func _build_map_select_rows() -> void:
	# 选关列表体（难度行 + 地图行）：开面板与切难度共用重建——R245 星标随所选
	# 难度分档（maps_cleared 不分难度，星标错亮三档）。同帧重建须先离树再释放，
	# 防 get_node_or_null 命中未释放的同名旧行（DifficultyRow/DiffDesc）
	# R262e ② 同档重开快路径：_on_panel_close 不拆行（行留树）、无
	# map_records_changed 失效信号=解锁/星标数据未变——recycle+重挂+难度行重建
	# 纯浪费（桌面探针 open≈7.5ms 大头；真机 2-4×=「点击后卡一堆才跳出」第一现场）。
	# 判据=当前档缓存非空且行仍在树；切档（recycle 已拆旧行）/通关失效
	# （缓存被弃置+行被 free）天然不命中走全量重建。
	# R267 修轮1（r259 既有红「选关：切回复用首套实例」根因）：原判据只查
	# MapRow_0 在树——切档后树上挂的是**另一档**的 MapRow_0（同名不同实例），
	# 快路径误命中 → 切回旧档显示错档行（生产级陈旧显示 bug：选中档与地图行
	# 星标/锁定态/解锁链不符）。补档位同一性：树上首行必须**就是**当前档缓存
	# 首行（指针直比）才可直跳；否则走 recycle+分档缓存直挂（<2ms 正路）。
	var _cur_cache: Array = _map_rows_cache.get(_sel_difficulty, [])
	if not _cur_cache.is_empty() \
			and _panel_list.get_node_or_null("MapRow_0") == _cur_cache[0] \
			and _panel_list.get_node_or_null("DifficultyRow") != null:
		return
	_recycle_panel_rows()                   # R254-1：统一回收口（缓存行 detach 回缓存，其余照旧 free）
	_build_difficulty_row()
	# R259 分档行缓存：难度 → 行数组（行内锁定态/星标/难度过滤 note 静态 per 档）；
	# 切难度=另一档缓存直挂（10ms→<2ms）。失效口=Meta.map_records_changed（通关
	# 记录变化→锁定态/星标过期，全档弃置——结算/通关喂入两写点 emit）
	var cached_maps: Array = _map_rows_cache.get(_sel_difficulty, [])
	if not cached_maps.is_empty():
		for r_v: Variant in cached_maps:
			_panel_list.add_child(r_v)
		return
	var map_rows: Array = []
	for i in range(MapTable.count()):
		var def := MapTable.MAPS[i]
		var mid: StringName = def.id
		var unlocked := Meta.is_map_unlocked(mid, _sel_difficulty)   # 二cs：解锁链分档
		var cleared := Meta.is_map_cleared_at(mid, _sel_difficulty)
		var status := ("已通关 ★" if cleared else "可挑战") if unlocked else "通关上一关解锁"
		var row := Panel.new()
		row.name = "MapRow_%d" % i                   # R259：缓存行名标（回收口 detach 白名单）
		row.add_theme_stylebox_override("panel", StickerTheme.panel_style(14.0, 3, false))
		row.custom_minimum_size = Vector2(576.0, 118.0)
		row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		row.mouse_filter = Control.MOUSE_FILTER_IGNORE
		var idx_l := Label.new()
		StickerTheme.label_sticker(idx_l, 24, PopPalette.PLAYER if unlocked else PopPalette.INK_SOFT,
			0, Color.WHITE, true)
		idx_l.text = "%d" % (i + 1)
		idx_l.position = Vector2(18.0, 32.0)
		idx_l.size = Vector2(40.0, 34.0)
		idx_l.mouse_filter = Control.MOUSE_FILTER_IGNORE
		row.add_child(idx_l)
		var name_l := Label.new()
		StickerTheme.label_sticker(name_l, 19, PopPalette.INK if unlocked else PopPalette.INK_SOFT,
			0, Color.WHITE, true)
		name_l.text = "%s（%d 波 · %s）" % [String(def.name), int(def.final_wave), status]
		name_l.position = Vector2(64.0, 14.0)
		name_l.size = Vector2(500.0, 26.0)
		name_l.mouse_filter = Control.MOUSE_FILTER_IGNORE
		row.add_child(name_l)
		var desc_l := Label.new()
		StickerTheme.label_sticker(desc_l, 12, PopPalette.INK_SOFT)
		desc_l.text = String(def.desc)
		desc_l.position = Vector2(64.0, 40.0)
		desc_l.size = Vector2(500.0, 18.0)
		desc_l.mouse_filter = Control.MOUSE_FILTER_IGNORE
		row.add_child(desc_l)
		# 词缀二期：双词缀两行小字（兆 = 薄荷绿 / 诅 = 珊瑚红；数值真源 map_table.gd）。
					# R253 消歧：词缀前缀「祝」→「兆」（吉兆）——「祝福」一词让位 R252 开局祝福系统
		var bless_l := Label.new()
		StickerTheme.label_sticker(bless_l, 12, PopPalette.SUCCESS)
		bless_l.text = "兆　%s" % String(def.get("bless_name", ""))
		bless_l.position = Vector2(64.0, 58.0)
		bless_l.size = Vector2(500.0, 18.0)
		bless_l.mouse_filter = Control.MOUSE_FILTER_IGNORE
		row.add_child(bless_l)
		var curse_l := Label.new()
		StickerTheme.label_sticker(curse_l, 12, PopPalette.ENEMY)
		curse_l.text = "诅　%s" % String(def.get("curse_name", ""))
		curse_l.position = Vector2(64.0, 76.0)
		curse_l.size = Vector2(500.0, 18.0)
		curse_l.mouse_filter = Control.MOUSE_FILTER_IGNORE
		row.add_child(curse_l)
		# 大关新机制行（2026-09-13 解锁节奏表：MechanicGate 真源——选关即见本关主题）
		var note_l := Label.new()
		StickerTheme.label_sticker(note_l, 12, PopPalette.GOLD)
		note_l.text = "✦ %s" % MechanicGate.intro_for_map(i, _sel_difficulty)   # 二dc H1：选关行随所选难度过滤族武器名
		note_l.position = Vector2(64.0, 94.0)
		note_l.size = Vector2(500.0, 18.0)
		note_l.mouse_filter = Control.MOUSE_FILTER_IGNORE
		row.add_child(note_l)
		if unlocked:
			var play_btn := Button.new()
			play_btn.text = "出发"
			play_btn.add_theme_font_size_override("font_size", 15)
			play_btn.add_theme_font_override("font", StickerTheme.font_bold())
			play_btn.position = Vector2(486.0, 32.0)   # R194 触控目标放大 76×52（选关行 118 内，32+52=84 留底距）
			play_btn.size = Vector2(76.0, 52.0)
			play_btn.focus_mode = Control.FOCUS_NONE
			play_btn.pressed.connect(_on_map_pick.bind(mid))
			play_btn.button_down.connect(func() -> void: StickerTheme.press_punch(play_btn))
			row.add_child(play_btn)
		_panel_list.add_child(row)
		map_rows.append(row)
	_map_rows_cache[_sel_difficulty] = map_rows   # R259：入缓存（分档）


func selected_difficulty() -> int:
	# 测试观测口（R72）
	return _sel_difficulty


func _build_difficulty_row() -> void:
	# R72 难度选择行（选关面板顶部）：普通 / 困难 / 地狱 三档单选——出发时随图携带
	var row := Panel.new()
	row.name = "DifficultyRow"
	row.add_theme_stylebox_override("panel", StickerTheme.panel_style(14.0, 3, false))
	row.custom_minimum_size = Vector2(576.0, 112.0)
	row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var title := Label.new()
	StickerTheme.label_sticker(title, 15, PopPalette.GOLD, 0, Color.WHITE, true)
	title.text = "◈ 难度"
	title.position = Vector2(16.0, 8.0)
	title.size = Vector2(544.0, 20.0)
	title.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_child(title)
	_diff_btns.clear()
	for d in range(3):
		var btn := Button.new()
		btn.text = GameConst.difficulty_name(d)
		btn.add_theme_font_size_override("font_size", 17)
		btn.add_theme_font_override("font", StickerTheme.font_bold())
		btn.position = Vector2(16.0 + d * 188.0, 34.0)
		btn.size = Vector2(176.0, 50.0)
		btn.focus_mode = Control.FOCUS_NONE
		btn.pressed.connect(_on_difficulty_pick.bind(d))
		btn.button_down.connect(func() -> void: StickerTheme.press_punch(btn))
		row.add_child(btn)
		_diff_btns.append(btn)
	var desc := Label.new()
	StickerTheme.label_sticker(desc, 12, PopPalette.INK_SOFT)
	desc.text = GameConst.difficulty_desc(_sel_difficulty)
	desc.name = "DiffDesc"
	desc.position = Vector2(16.0, 90.0)
	desc.size = Vector2(544.0, 18.0)
	desc.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_child(desc)
	_panel_list.add_child(row)
	_refresh_difficulty_row()


func _on_difficulty_pick(p_d: int) -> void:
	_sel_difficulty = p_d
	_build_map_select_rows()   # R245：星标分档——切难度重建地图行（含难度行按钮态刷新）


func _refresh_difficulty_row() -> void:
	# 选中态：选中档高亮描边 + 描述行同步（图鉴口径文案）。
	# R88 解锁门：困难/地狱需普通通关（任意图）——未解锁置灰禁用
	var unlocked_hard := Meta.normal_cleared()
	for d in range(_diff_btns.size()):
		var btn := _diff_btns[d]
		var locked := d >= 1 and not unlocked_hard
		btn.disabled = locked
		if locked and _sel_difficulty >= 1:
			_sel_difficulty = 0              # 当前选中档被锁 → 回落普通
		btn.modulate = Color(0.45, 0.45, 0.5) if locked 			else (Color.WHITE if d == _sel_difficulty else Color(0.62, 0.62, 0.66))
	var desc_l := _panel_list.get_node_or_null("DifficultyRow/DiffDesc") as Label
	if desc_l == null and not _diff_btns.is_empty():
		# 行名为默认 Panel（无 name 时按子树找）——直接从按钮父级取
		desc_l = _diff_btns[0].get_parent().get_node_or_null("DiffDesc") as Label
	if desc_l != null:
		desc_l.text = GameConst.difficulty_desc(_sel_difficulty)
		if not unlocked_hard:
			# R245 修裸换行（原 python 续行残留致 18px 单行 Label 塞两行溢出）——单行中点连接
			desc_l.text = "普通通关后解锁困难 / 地狱（当前：普通）· " + desc_l.text


func _on_map_pick(p_map_id: StringName) -> void:
	_panel_end_defer()        # R252D P6：落盘先于离菜单（§4.4-1——面板内出发钮路径）
	_close_panel_core()       # R260 评审 HIGH-1：出发直关=挂起标志随清（防回大厅双泵停摆）
	# R257 评审M2：UI 层 tap 直证——若病灶是上层吞点击（如祝福 dim 残留 MOUSE_FILTER_STOP），
	# 玩家导出将呈「无此行」而非「有行但链断」，假说 f（吞 tap）从反推变直证
	DebugStats.event("选关出发钮：map=%s 难度=%d" % [String(p_map_id), _sel_difficulty])
	start_map_requested.emit(p_map_id, _sel_difficulty)


func is_menu_visible() -> bool:
	# 测试观测口
	return _root != null and _root.visible


# ── 大厅入口（图鉴 / 成就 / 记录） ────────────────────────────────
func _build_lobby() -> void:
	# 出发按钮下方入口行（按钮文案带完成度角标——图鉴 x/y、成就 x/y）
	var defs := [
		{"kind": "codex", "text": "图鉴", "pos": Vector2(44.0, 900.0)},
		{"kind": "ach", "text": "成就", "pos": Vector2(265.0, 900.0)},
		{"kind": "records", "text": "记录", "pos": Vector2(486.0, 900.0)},
		{"kind": "char", "text": "角色", "pos": Vector2(155.0, 988.0)},
		{"kind": "upgrade", "text": "养成", "pos": Vector2(375.0, 988.0)},
		{"kind": "daily", "text": "每日挑战", "pos": Vector2(265.0, 1076.0)},
		{"kind": "settings", "text": "设置", "pos": Vector2(486.0, 1076.0)},
	]
	for d in defs:
		var btn := Button.new()
		btn.name = "Lobby_%s" % String(d.kind)
		btn.text = String(d.text)                # 基础文案（动态角标由 _refresh_lobby_counts 覆盖）
		btn.add_theme_font_size_override("font_size", 22)
		btn.add_theme_font_override("font", StickerTheme.font_bold())
		if String(d.kind) == "upgrade":
			# R196：结晶 emoji 字面量 → ui_gem 贴纸 icon（Android 系统字体链缺 emoji
			# 字形只出字不出图——apk_menu_no_icons 定案；Button.icon 原生排版，
			# icon_max_width 钳贴纸宽与 22 号字对齐不乱）
			btn.icon = TextureFactory.ui_gem()
			btn.add_theme_constant_override("icon_max_width", 26)
		btn.position = d.pos
		btn.size = Vector2(190.0, 74.0)
		btn.pivot_offset = btn.size * 0.5
		btn.pressed.connect(_on_lobby_pressed.bind(String(d.kind)))
		btn.button_down.connect(func() -> void: StickerTheme.press_punch(btn))
		_root.add_child(btn)
		_lobby_btns[String(d.kind)] = btn
	_refresh_lobby_counts()


func _refresh_lobby_counts() -> void:
	# 入口角标：图鉴解锁数 / 成就完成数（Meta 无档时显示 0）
	# R245 §4.4-2：图鉴分母（115→133：29 怪 + 13 武 + 73 词条 + 18 遗物）；
	# R252 需求③遗物扩容 18→34 件 → 分母 133→149（29 怪 + 13 武 + 73 祝福 + 34 遗物），
	# 分子同口径 + codex_relics 收录数（获得口径与其余三页一致）。分母动态求和（:687）。
	# R253 防御六遗物 34→40 件 → 分母 149→155（29+13+73+40——评审 M7 尾注同步）。
	if registry == null:
		return
	# R262b L14：图鉴计数剔除阈值型镜像词条（TH_* 永不可抽不入解锁面——与祝福页行源
	# 同口径，7 条虚数归零）
	var codex_traits_total := 0
	for tid_v: Variant in registry.traits.keys():
		var td_s: TraitData = registry.get_trait(tid_v)
		if td_s != null and not bool(td_s.params.get("threshold_only", false)):
			codex_traits_total += 1
	var codex_total := registry.enemies.size() + registry.weapons.size() \
		+ codex_traits_total + registry.relics.size()
	var codex_got := Meta.codex_kills.size() + Meta.codex_weapons.size() \
		+ Meta.codex_traits.size() + Meta.codex_relics.size()
	var ach := Meta.achievement_count()
	(_lobby_btns["codex"] as Button).text = "图鉴 %d/%d" % [codex_got, codex_total]
	(_lobby_btns["ach"] as Button).text = "成就 %d/%d" % [ach.x, ach.y]
	(_lobby_btns["records"] as Button).text = "记录"
	var char_txt := "角色"
	if _char_new_badge:
		char_txt = "角色 ·新"                     # R186：新角色解锁角标（打开选人面板清除）
	(_lobby_btns["char"] as Button).text = char_txt
	(_lobby_btns["upgrade"] as Button).text = "养成 %d" % Meta.crystals   # R196：结晶符号 → ui_gem icon（构建期已挂）
	var dbest: Dictionary = Meta.daily_record()
	var dbest_txt := "每日挑战" if dbest.is_empty() \
		else "每日挑战 %d波" % int(dbest.get("best_wave", 0))
	(_lobby_btns["daily"] as Button).text = dbest_txt


func _on_lobby_pressed(p_kind: String) -> void:
	if p_kind == "settings":
		# 设置页为独立全屏面板（不占大厅详情壳；GameLoop 接线 SettingsPanel.open）
		settings_requested.emit()
		return
	_panel_begin_defer()      # R252D P6：面板作用域批落盘开包络（写口即时生效、_save 抑制）
	_panel_root.visible = true
	var titles := {"codex": "图鉴", "ach": "成就", "records": "历史记录",
		"char": "选择角色", "upgrade": "局外养成", "daily": "每日挑战"}
	_panel_title.text = String(titles.get(p_kind, ""))
	for kind: String in _codex_tabs:
		(_codex_tabs[kind] as Button).visible = p_kind == "codex"
	for kind: String in _ach_tabs:
		(_ach_tabs[kind] as Button).visible = p_kind == "ach"
	_set_ach_pager_visible(p_kind == "ach")
	match p_kind:
		"codex":
			_rebuild_codex()
		"ach":
			_ach_page = 0                    # 重开成就面板回第一页（防跨类别页码越界残留）
			_rebuild_achievements()
		"records":
			_rebuild_records()
		"char":
			_panel_title.text = "选择角色"
			_char_new_badge = false            # R186：打开选人面板即清除「·新」角标
			_refresh_lobby_counts()
			_rebuild_char_select()
		"upgrade":
			_panel_title.text = "局外养成"
			_rebuild_upgrades()
		"daily":
			_panel_title.text = "每日挑战"
			_rebuild_daily()
	_lobby_detail_open = true                # R260：大厅详情面板开=CardDesc 泵挂起（图鉴泵豁免见 _process）
	_panel_kind = p_kind
	StickerTheme.squash_pop(_panel_root.get_node("LobbyPanel") as Control)


# ── 全屏详情面板（三入口共用壳） ──────────────────────────────────
func _build_panel() -> void:
	_panel_root = Control.new()
	_panel_root.name = "LobbyPanelRoot"
	_panel_root.theme = StickerTheme.theme()
	_panel_root.set_anchors_preset(Control.PRESET_FULL_RECT)
	_panel_root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_panel_root.visible = false
	_root.add_child(_panel_root)
	var dim := ColorRect.new()
	dim.color = PopPalette.BG                                  # 大厅内不透明白底（盖住 menu）
	dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	dim.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_panel_root.add_child(dim)
	var card := Panel.new()
	card.name = "LobbyPanel"
	card.add_theme_stylebox_override("panel", StickerTheme.panel_style(24.0, 4, true))
	card.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_panel_root.add_child(card)
	# R195 适配分区：大厅卡左右居中锚（inset 36 恒等）+ 顶部 96 上锚 + 纵向拉伸
	# （offset=现值−锚点设计位：上 96、底沿 1176=1280−104；720×1280 恒等，
	# 宽视口下左右各收 36px、高视口下卡体随高拉伸——滚动区/底行随卡内锚联动）
	card.anchor_left = 0.0
	card.anchor_right = 1.0
	card.anchor_top = 0.0
	card.anchor_bottom = 1.0
	card.offset_left = 36.0
	card.offset_right = -36.0
	card.offset_top = 96.0
	card.offset_bottom = -104.0
	card.pivot_offset = card.size * 0.5
	_panel_title = Label.new()
	StickerTheme.label_sticker(_panel_title, 32, PopPalette.INK, 0, Color.WHITE, true)
	_panel_title.text = "图鉴"
	_panel_title.position = Vector2(0.0, 28.0)
	_panel_title.size = Vector2(648.0, 42.0)
	_panel_title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	card.add_child(_panel_title)
	# 图鉴页签（仅图鉴模式可见；行 = [页名, x]。R191#5：+「反应」页共 4 枚；R245 +「遗物」
	# 页共 5 枚，宽 126→108 重排（步距 117）——末沿 504+108=612 与右距 36 均不变）
	# R252D（需求②）：原「词条」页签改名「祝福」——开局祝福档位池数据读口不变（仍
	# registry.traits 全量 + Meta.is_trait_unlocked 既有解锁标记），仅页签名与锁定态
	# 文案换语义（几何 108/x 位置不动，rxn_codex A1b 数值锁保持）
	var tabs := [["怪物", 36.0], ["武器", 153.0], ["祝福", 270.0], ["反应", 387.0], ["遗物", 504.0]]
	for t in tabs:
		var tab := Button.new()
		tab.name = "Tab_%s" % String(t[0])
		tab.text = String(t[0])
		tab.add_theme_font_size_override("font_size", 18)
		tab.add_theme_font_override("font", StickerTheme.font_bold())
		tab.position = Vector2(float(t[1]), 84.0)
		tab.size = Vector2(108.0, 54.0)
		tab.pivot_offset = tab.size * 0.5
		tab.pressed.connect(_on_codex_tab.bind(String(t[0])))
		card.add_child(tab)
		_codex_tabs[String(t[0])] = tab
	# 成就类别页签（仅成就模式可见；R191#6，复用图鉴页签按钮先例，同行错峰显隐）
	var ach_tabs_def := [["全部", 36.0], ["猎杀", 186.0], ["进阶", 336.0], ["收集", 486.0]]
	for t in ach_tabs_def:
		var atab := Button.new()
		atab.name = "AchTab_%s" % String(t[0])
		atab.text = String(t[0])
		atab.add_theme_font_size_override("font_size", 18)
		atab.add_theme_font_override("font", StickerTheme.font_bold())
		atab.position = Vector2(float(t[1]), 84.0)
		atab.size = Vector2(126.0, 54.0)
		atab.pivot_offset = atab.size * 0.5
		atab.visible = false
		atab.pressed.connect(_on_ach_tab.bind(String(t[0])))
		atab.button_down.connect(func() -> void: StickerTheme.press_punch(atab))
		card.add_child(atab)
		_ach_tabs[String(t[0])] = atab
	# 成就分页（上一页/下一页 + 页码读数；返回大厅按钮两侧让位——页容量 24）
	_ach_prev_btn = Button.new()
	_ach_prev_btn.name = "AchPrevButton"
	_ach_prev_btn.text = "◀ 上一页"
	_ach_prev_btn.add_theme_font_size_override("font_size", 15)
	_ach_prev_btn.add_theme_font_override("font", StickerTheme.font_bold())
	_ach_prev_btn.position = Vector2(36.0, 986.0)
	_ach_prev_btn.size = Vector2(132.0, 64.0)
	# R195 适配分区：底行下锚（offset=现值−锚点(0,1080)：上 986−1080、底沿 1050−1080
	# 随卡底恒 30px；横向保持左 inset 36）
	_ach_prev_btn.anchor_top = 1.0
	_ach_prev_btn.anchor_bottom = 1.0
	_ach_prev_btn.offset_top = -94.0
	_ach_prev_btn.offset_bottom = -30.0
	_ach_prev_btn.pivot_offset = _ach_prev_btn.size * 0.5
	_ach_prev_btn.visible = false
	_ach_prev_btn.pressed.connect(_on_ach_page_prev)
	_ach_prev_btn.button_down.connect(func() -> void: StickerTheme.press_punch(_ach_prev_btn))
	card.add_child(_ach_prev_btn)
	_ach_next_btn = Button.new()
	_ach_next_btn.name = "AchNextButton"
	_ach_next_btn.text = "下一页 ▶"
	_ach_next_btn.add_theme_font_size_override("font_size", 15)
	_ach_next_btn.add_theme_font_override("font", StickerTheme.font_bold())
	_ach_next_btn.position = Vector2(480.0, 986.0)
	_ach_next_btn.size = Vector2(132.0, 64.0)
	# R195 适配分区：底行下锚 + 右锚（offset=现值−锚点(648,1080)：左 480−648、右沿
	# 612−648 随卡宽恒 inset 36——与左页签对称；默认窗 (480,986) 恒等）
	_ach_next_btn.anchor_left = 1.0
	_ach_next_btn.anchor_right = 1.0
	_ach_next_btn.anchor_top = 1.0
	_ach_next_btn.anchor_bottom = 1.0
	_ach_next_btn.offset_left = -168.0
	_ach_next_btn.offset_right = -36.0
	_ach_next_btn.offset_top = -94.0
	_ach_next_btn.offset_bottom = -30.0
	_ach_next_btn.pivot_offset = _ach_next_btn.size * 0.5
	_ach_next_btn.visible = false
	_ach_next_btn.pressed.connect(_on_ach_page_next)
	_ach_next_btn.button_down.connect(func() -> void: StickerTheme.press_punch(_ach_next_btn))
	card.add_child(_ach_next_btn)
	_ach_page_label = Label.new()
	_ach_page_label.name = "AchPageLabel"
	StickerTheme.label_sticker(_ach_page_label, 13, PopPalette.INK_SOFT)
	# 坐标落在 ◀上一页(36~168) 与 返回大厅(211~) 之间 43px 空当内——旧位 136 压进按钮描边 30px
	_ach_page_label.position = Vector2(170.0, 1004.0)
	_ach_page_label.size = Vector2(39.0, 28.0)
	# R195 适配分区：底行下锚（offset=现值−锚点(0,1080)：上 1004−1080、底沿 1032−1080；
	# 横向固定随左页签——页码读数属翻页器）
	_ach_page_label.anchor_top = 1.0
	_ach_page_label.anchor_bottom = 1.0
	_ach_page_label.offset_top = -76.0
	_ach_page_label.offset_bottom = -48.0
	_ach_page_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_ach_page_label.visible = false
	card.add_child(_ach_page_label)
	var scroll := ScrollContainer.new()
	scroll.name = "LobbyScroll"
	scroll.position = Vector2(28.0, 156.0)
	scroll.size = Vector2(592.0, 812.0)
	# R195 适配分区：滚动列表区纵向拉伸（上锚 156 固定/下锚随卡底：底沿 968=1080−112；
	# 720×1280 恒等，高视口下随卡体拉伸多显行）
	# R198（r195-4）：横向改居中锚——父卡 720 设计域宽 648、锚 0.5=324 → 324±296=28..620
	# 逐位恒等（720 域零变化）；宽画布域下滚动列随卡居中，消除右侧 ~268px 留白（960 宽
	# 画布域卡宽 888 → 列左缘 28→148 卡内居中）。图鉴 4 页签/选关/记录三屏共用本列自动受益。
	scroll.anchor_left = 0.5
	scroll.anchor_right = 0.5
	scroll.offset_left = -296.0
	scroll.offset_right = 296.0
	scroll.anchor_top = 0.0
	scroll.anchor_bottom = 1.0
	scroll.offset_top = 156.0
	scroll.offset_bottom = -112.0
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	card.add_child(scroll)
	_panel_list = VBoxContainer.new()
	_panel_list.name = "LobbyList"
	_panel_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_panel_list.add_theme_constant_override("separation", 8)
	scroll.add_child(_panel_list)
	var close_btn := Button.new()
	close_btn.name = "LobbyCloseButton"
	close_btn.text = "返回大厅"
	close_btn.add_theme_font_size_override("font_size", 20)
	close_btn.add_theme_font_override("font", StickerTheme.font_bold())
	close_btn.position = Vector2(211.0, 986.0)
	close_btn.size = Vector2(226.0, 64.0)
	# R195 适配分区：底行下锚 + 横向居中锚（offset=现值−锚点(324,1080)：左 211−324、
	# 右 437−324——卡宽变化下保持行内居中；默认窗恒等）
	close_btn.anchor_left = 0.5
	close_btn.anchor_right = 0.5
	close_btn.anchor_top = 1.0
	close_btn.anchor_bottom = 1.0
	close_btn.offset_left = -113.0
	close_btn.offset_right = 113.0
	close_btn.offset_top = -94.0
	close_btn.offset_bottom = -30.0
	close_btn.pivot_offset = close_btn.size * 0.5
	close_btn.pressed.connect(_on_panel_close)
	close_btn.button_down.connect(func() -> void: StickerTheme.press_punch(close_btn))
	card.add_child(close_btn)


func _panel_begin_defer() -> void:
	# R252D P6：大厅详情面板作用域批落盘——open → Meta.begin_persist_defer()（R189 既有
	# 批收口 API），面板内点击路径写口（buy_upgrade/set_character_id/set_setting 等）
	# 应用即时、_save 被深度门抑制；关闭/出发/退出树统一 end 一次落盘（设置滑条 14 步
	# 拖动 = 1 次写盘）。标志守卫严格配对（end 在深度 0 也会强制落盘——绝不空 begin）。
	if not _panel_defer_open:
		Meta.begin_persist_defer()
		_panel_defer_open = true


func _panel_end_defer() -> void:
	# R252D P6：包络收口（幂等——无包络时零副作用，不触 Meta.end_persist_defer 的
	# 深度 0 强制落盘分支）
	if _panel_defer_open:
		_panel_defer_open = false
		Meta.end_persist_defer()


func _notification(p_what: int) -> void:
	# R252D P6：带开包络销毁 → 强制结清（不许把 _save 抑制态带出面板作用域）
	if p_what == NOTIFICATION_EXIT_TREE:
		_panel_end_defer()


func set_blessing_modal(p_open: bool) -> void:
	# R260：祝福弹层模态期（game_loop 面板 open/三收口唯一调点）。
	# 注：本函数只记模态位；「面板开着时仍挂起」的条件合并语义住在两个
	# pump_paused 谓词里（R260 评审 LOW-3 口径）
	_blessing_modal = p_open
	# R267 刀P1：模态开帧位图暖——门开（mobile/测试 override）且图集未就绪时，
	# layout+未烤 cell 一次性做掉（≈42ms 菜单过渡帧），出发帧 ensure 恒短路。
	# 模态期 tex 泵被 R260 挂起（挂起谓词含 _blessing_modal）→ 暖必须在本帧同步。
	# 桌面自动门恒关 → 零扰动；ready 后幂等零成本。
	if p_open:
		PopupGlyphAtlas.warm_runstart_cells()


func set_settings_modal(p_open: bool) -> void:
	# R260 评审 MED-1：设置全屏弹层期（game_loop 开面板/closed 信号调点）——设置卡
	# 同款 squash_pop 动画，模态期双泵挂起口径与祝福弹层一致
	_settings_modal = p_open


func card_desc_pump_paused() -> bool:
	# 测试观测口（R260）：CardDescPrewarm 挂起态（任一模态开=true）
	return _lobby_detail_open or _blessing_modal or _settings_modal


func codex_pump_paused() -> bool:
	# 测试观测口（R260）：图鉴泵挂起态（祝福/设置弹层或非图鉴面板期=true）
	return _blessing_modal or _settings_modal \
			or (_lobby_detail_open and _panel_kind != "codex")


func _on_panel_close() -> void:
	_panel_end_defer()        # R252D P6：回大厅 = 面板作用域结束，统一落盘
	_panel_root.visible = false
	_lobby_detail_open = false   # R260：回大厅=泵恢复（模态全清）
	_panel_kind = ""
	_refresh_lobby_counts()


func _on_codex_tab(p_tab: String) -> void:
	_codex_tab = p_tab
	# R254-1：目标页提到预建队首（玩家即将看的页最先备好——闲时泵同帧内消费）
	var qi := _codex_prewarm_queue.find(p_tab)
	if qi >= 0:
		_codex_prewarm_queue.remove_at(qi)
		_codex_prewarm_queue.push_front(p_tab)
	_rebuild_codex()


func _rows_attached_in_order(p_cache: Array, p_extra: int = 0) -> bool:
	# R267 刀P3：缓存组已按序挂树判定（指针直比，O(n)≈µs 级）——面板关闭只隐藏
	# _panel_root 不卸行，同态重开（关→开同面板/同面板连按）无需 detach+reattach，
	# 逐行重进树 ~90-195µs/行的挂载成本整段跳过（显示态等价：行/序/内容均未变）
	if _panel_list == null or p_cache.is_empty() \
			or _panel_list.get_child_count() != p_cache.size() + p_extra:
		return false
	for i in range(p_cache.size()):
		if _panel_list.get_child(i) != p_cache[i]:
			return false
	return true


func _free_cached_rows(p_rows: Array) -> void:
	# R259 评审 HIGH-1：缓存行数组释放共用口——Node 非 RefCounted，失去引用不释放
	# （孤儿行泄漏）。挂树防御同 _invalidate_map_rows_cache（被覆盖的旧行通常已被
	# _recycle_panel_rows detach，但仍可能有挂树路径）。
	for r_v: Variant in p_rows:
		var r: Node = r_v as Node
		if r != null and is_instance_valid(r):
			if r.get_parent() != null:
				r.get_parent().remove_child(r)
			r.queue_free()


func _invalidate_map_rows_cache() -> void:
	# R259：选关地图行缓存失效（Meta.map_records_changed——结算/通关喂入写点）。
	# 行内锁定态/星标随记录变=旧行不可复用，全档弃置（行尚挂树=选关面板开着的
	# 防御路径：一并 detach 再 free，下次打开重建）。
	for d_v: Variant in _map_rows_cache.keys():
		_free_cached_rows(_map_rows_cache[d_v])
	_map_rows_cache.clear()


func _recycle_panel_rows() -> void:
	# R254-1：面板行统一回收口（R252D P1 先离树再释放语义不变）——图鉴缓存行
	#（CodexRow_/RxnRow_ 名标）与 R259 三面板缓存行（AchRow_/CharRow_/MapRow_），
	# R267 刀P3 三面板缓存行（RecRow_/UpgRow_/DlyRow_）同入 detach 白名单；
	# 只 detach 回缓存复用不 free；其余页行照旧 remove+queue_free。
	# 六 rebuild 开头共用（切面板互切时对方页行各归各位）
	for c in _panel_list.get_children():
		_panel_list.remove_child(c)
		var nm := String(c.name)
		if not (nm.begins_with("CodexRow_") or nm.begins_with("RxnRow_")
				or nm.begins_with("AchRow_") or nm.begins_with("CharRow_")
				or nm.begins_with("MapRow_")
				or nm.begins_with("RecRow_") or nm.begins_with("UpgRow_")
				or nm.begins_with("DlyRow_")):
			c.queue_free()


func _invalidate_codex_cache(p_keep_reaction: bool = false) -> void:
	# R254-1：缓存失效（击杀数/解锁态已变——行文案随档漂移，旧行不可复用）。
	# 行尚挂树时一并 detach（面板开着的防御路径：codex_changed 局内解锁可先于回
	# 大厅达）。清缓存后重排预建队列，闲时泵重新备五页。
	# R254 修轮#3a：p_keep_reaction=true 保留「反应」页——行源纯静态（枚举序+
	# 运行期静态表+固定文案，零 Meta 态），进菜单失效口对它是白建（回菜单五连
	# 小卡的三成白费源）；codex_changed 口不保留（防御未来反应行接 Meta 态）。
	# R254 修轮#2：泵在建半成品一并弃置（防跨失效期的孤儿行）。
	for ghost: Node in _codex_pump_rows:
		ghost.queue_free()
	_codex_pump_tab = ""
	_codex_pump_rows = []
	var keep_tab: StringName = &"反应" if p_keep_reaction else &""
	var kept_rows: Variant = _codex_page_cache.get(keep_tab, null) if keep_tab != &"" else null
	if _panel_list == null:                    # _build_panel 前的信号边界（防御——只清数据不碰树）
		_codex_page_cache.clear()
		_codex_prewarm_queue = _codex_tab_preset().duplicate()
		if kept_rows != null:
			_codex_page_cache[keep_tab] = kept_rows
			_codex_prewarm_queue.erase(String(keep_tab))
		return
	var cached_rows: Array = []
	for tab_v: Variant in _codex_page_cache.keys():
		if String(tab_v) == String(keep_tab):
			continue
		for row_v: Variant in _codex_page_cache[tab_v]:
			cached_rows.append(row_v)
	for c in _panel_list.get_children():
		if c in cached_rows:
			_panel_list.remove_child(c)
	for row_v: Variant in cached_rows:
		(row_v as Node).queue_free()
	_codex_page_cache.clear()
	if kept_rows != null:
		_codex_page_cache[keep_tab] = kept_rows
	_codex_prewarm_queue = _codex_tab_preset().duplicate()
	if kept_rows != null:
		_codex_prewarm_queue.erase(String(keep_tab))


func _codex_tab_preset() -> Array[String]:
	# 武器页压尾（修轮#2）：武器图标 tex 预热项排 boss 段后，先建四轻页为其留
	# 消化时窗——泵到武器页时图标热、单行成本回落常态档
	return ["怪物", "祝福", "遗物", "反应", "武器"]


# ── 图鉴内容（怪物击杀解锁 / 武器获得解锁 / 祝福=开局词条解锁） ────
func _rebuild_codex() -> void:
	_recycle_panel_rows()
	if registry == null:
		return
	# R254-1：页级行缓存——命中直挂（切页从全量重建 82ms 降到挂树+VBox 排版）；
	# 未命中建页入缓存（首开该页仍一次构建，闲时泵已把常见路径预建掉）
	if not _codex_page_cache.has(_codex_tab):
		_codex_page_cache[_codex_tab] = _build_codex_rows(_codex_tab)
		var qi := _codex_prewarm_queue.find(_codex_tab)
		if qi >= 0:
			_codex_prewarm_queue.remove_at(qi)
	for row: Control in (_codex_page_cache[_codex_tab] as Array):
		_panel_list.add_child(row)
	_sticker_active_tab()


func _build_codex_rows(p_tab: String) -> Array:
	# 纯构建（不挂树——玩家点未缓存页的同步路径）：行序真源 = _make_codex_entry_row
	# 逐行聚合（R254 修轮#2：泵行粒度化后单行工厂是唯一行源，本函数与闲时泵共用）
	var rows: Array = []
	var i := 0
	while true:
		var row := _make_codex_entry_row(p_tab, i)
		if row == null:
			break
		rows.append(row)
		i += 1
	return rows


func _make_codex_entry_row(p_tab: String, p_i: int) -> Control:
	# 单行工厂（R254 修轮#2）：p_i 越界返 null（页毕哨兵）。五页行源：
	# 怪物/武器/祝福/遗物 = registry 数组序；反应 = 枚举声明序 + 尾 blank 行。
	# 泵按行消费（4ms 预算内逐行建），同步路径整页循环调——同一行真源零漂移
	var src_arr: Array = []                   # 行源序（registry 四族是 Dictionary——keys() 保插入序）
	match p_tab:
		"怪物":
			src_arr = registry.enemies.keys()
		"武器":
			src_arr = registry.weapons.keys()
		"祝福":
			# R262b L14：阈值型镜像词条（TH_*）五池滤全过但图鉴全目录扫入——它们永不可抽
			#（局内不进卡池），挂在祝福页=恒锁「？？？」假行。行源滤除，计数随之归真。
			for tid_v: Variant in registry.traits.keys():
				var td_c: TraitData = registry.get_trait(tid_v)
				if td_c != null and not bool(td_c.params.get("threshold_only", false)):
					src_arr.append(tid_v)
		"遗物":
			src_arr = registry.relics.keys()
		"反应":
			src_arr = GameConst.ReactionType.keys()
	var blank_idx: int = src_arr.size()          # 反应页尾 blank 行位（其余页=越界哨兵位）
	if p_i >= src_arr.size() + (1 if p_tab == "反应" else 0):
		return null
	match p_tab:
		"怪物":
			var eid: Variant = src_arr[p_i]
			var ed: EnemyData = registry.get_enemy(eid)
			if ed == null:
				return _make_codex_entry_row(p_tab, p_i + 1)   # 脏数据跳行（递进到下一合法行）
			var kills := Meta.codex_kill_count(eid)
			var atk_note := GameConst.enemy_attack_note(String(eid))
			return _make_codex_row(
				_enemy_icon_tex(eid), kills > 0,
				ed.display_name if kills > 0 else "？？？",
				"累计击杀 %d · HP %d · 经验 %d%s" % [kills, int(ed.hp_base),
					int(ed.exp_base), atk_note]
					if kills > 0 else "未解锁：击杀一只后展示详情")
		"武器":
			# R196 三态（定案 wunlock）：①已获得 = got 现状（机制一句话 + 形态数值）；
			# ②可获取 = 门开未获得（显示名 + 局内抽卡提示）；③未解锁 = 门未开（隐名 +
			# 「通关『X』后开放」——句式单源 MechanicGate.weapon_locked_line，UI 禁手抄；
			# 锁徽记走 ui_lock 贴纸，行压暗读感同 RxnRow 锁定态手法）。
			# 「图鉴 %d/%d」计数保持获得口径不动（_refresh_lobby_counts）。
			var wid: Variant = src_arr[p_i]
			var wd: WeaponData = registry.get_weapon(wid)
			if wd == null:
				return _make_codex_entry_row(p_tab, p_i + 1)   # 脏数据跳行
			var got := Meta.is_weapon_unlocked(wid)
			# R196 评审修复：三态门态改进度派生（weapon_allowed_progress）——
			# weapon_allowed 读 run_map（上一局地图残留），大厅冷启动全亮「可获取」
			# 假话、局后按末局地图漂移；进度门 = 已通关大关数派生，与选关页一致
			var allowed := MechanicGate.weapon_allowed_progress(wid)
			# R190：解锁行副文案加机制一句话（图鉴直接可见，不靠 hover）——
			# 万镜回廊/蓄能轨道等 R187 特殊机制读图标猜不出
			var w_desc := ""
			var w_name := wd.display_name
			if got:
				var w_note := GameConst.weapon_note(String(wid))
				w_desc = ("%s\n%s" % [w_note, _form_stat_line(wd)]) if w_note != "" \
					else _form_stat_line(wd)
			elif allowed:
				# 二dc M1（评审）：可获取态补难度尾注——纯大关进度派生（progress 门）
				# 不含难度维度，普通玩家照「可获取」去抽永远抽不到族武器（门在卡池侧）
				var gd_min := MechanicGate.weapon_difficulty_min(wid)
				var gd_note := ""
				if gd_min >= 2:
					gd_note = "（仅地狱难度对局可获取）"
				elif gd_min == 1:
					gd_note = "（困难起可获取；地狱全开）"
				w_desc = "可获取：局内抽到「新武器」卡解锁%s" % gd_note
			else:
				w_name = "？？？"
				w_desc = MechanicGate.weapon_locked_line(wid)
			var w_row := _make_codex_row(
				TextureFactory.weapon_icon(wid), got or allowed,
				w_name, w_desc)
			if not allowed and not got:
				# 未解锁三态：压暗 + 右上角锁徽贴纸（观察名 WeaponLockBadge）。
				# R196 wunlock 定案 P6「获得优先于门」：门外已获得的武器按已获得态
				# 展示（显示名 + 无锁徽 + 不压暗）——只拦「未获得 ∧ 门外」，老档无损
				w_row.modulate.a = 0.55
				var w_lock := TextureRect.new()
				w_lock.name = "WeaponLockBadge"
				w_lock.texture = TextureFactory.ui_lock()
				w_lock.position = Vector2(536.0, 8.0)
				w_lock.size = Vector2(26.0, 24.0)
				w_lock.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
				w_lock.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
				w_lock.mouse_filter = Control.MOUSE_FILTER_IGNORE
				w_row.add_child(w_lock)
			return w_row
		"祝福":
			# R252D（需求②）：页签改名「词条」→「祝福」——本页=开局祝福（blessing_trait）
			# 候选池的全集图鉴；解锁口径不变（Meta.is_trait_unlocked = codex_traits 既有
			# 读口，「局内获得过该词条」），锁定态文案对齐新语义（含「开局祝福」）
			var tid: Variant = src_arr[p_i]
			var td: TraitData = registry.get_trait(tid)
			if td == null:
				return _make_codex_entry_row(p_tab, p_i + 1)   # 脏数据跳行
			var got := Meta.is_trait_unlocked(tid)
			return _make_codex_row(
				TextureFactory.type_icon(1, int(td.pool)), got,
				td.display_name if got else "？？？",
				td.description if got else "未解锁：抽到该词条卡后解锁对应开局祝福")
		"遗物":
			# R245 §4.4-1 遗物页：18 件全量行（resources/relics 目录真源经 registry.relics），
			# 解锁口径 = 获得过该遗物（Meta.codex_relics——RELIC 卡应用即收录，接线在
			# meta_manager._on_card_chosen，本文件零写口）。锁定态：名「？？？」+ 统一句式
			# （同词条页先例）；图标复用 ui_gem 贴纸（遗物=局外珍贵收集品语义，零新贴纸）。
			var rid_v: Variant = src_arr[p_i]
			var rdata: RelicData = registry.get_relic(StringName(String(rid_v)))
			if rdata == null:
				return _make_codex_entry_row(p_tab, p_i + 1)   # 脏数据跳行
			var rgot := Meta.is_relic_unlocked(rdata.id)
			return _make_codex_row(
				TextureFactory.ui_gem(), rgot,
				rdata.display_name if rgot else "？？？",
				rdata.description if rgot else "未解锁：获得后展示详情")
		"反应":
			# R191#5 图鉴「反应」页：枚举全键全量可见（无解锁过滤——不设 codex 门、零新增
			# 存档键；页面不出现难度门文案，条件句写代码真条件）。倍率运行时读
			# GameConfig.balance.reaction_table 格式化（禁止硬编码数值）。
			# R192 wire T2 rid 无关化：行建遍历 ReactionType 枚举声明序（keys() 即序——
			# 枚举字典 = 名→int，keys() 给名字串，int 值经 ReactionType[名] 反查），逐键查
			# reaction_table 成员过滤——缺键 push_error+跳过（半接线启动期报红，禁静默落行）；
			# 行序 = 枚举声明序（构建序定位保留）。冰+草留白标注行（21 配对唯一空格）在循环
			# 后单独追加——不计入枚举行数。
			if p_i == blank_idx:
				return _make_codex_blank_row()               # 尾行：冰+草留白标注
			var rid_key: String = src_arr[p_i]
			if GameConfig.balance == null \
					or not GameConfig.balance.reaction_table.has(rid_key):
				push_error("[MenuScreen] reaction_table 缺键（半接线）：%s——行跳过" % rid_key)
				return _make_codex_entry_row(p_tab, p_i + 1)   # 缺键跳行
			return _make_codex_reaction_row(int(GameConst.ReactionType[rid_key]))
	return null


func _form_stat_line(p_wd: WeaponData) -> String:
	# 武器条目副文案：形态 + Lv1 攻击（升级表首档）
	var form_names := ["弹道", "激光", "自导", "近战"]
	var atk := 0.0
	if p_wd.upgrade_table.size() > 0:
		atk = float(p_wd.upgrade_table[0].get("base_atk"))
	return "%s形态 · Lv1 攻击 %.0f" % [form_names[clampi(int(p_wd.form), 0, 3)], atk]


func _enemy_icon_tex(p_eid: Variant) -> ImageTexture:
	# 怪物 id 前缀 → 分型贴图（enemy.gd _visual_kind 同映射的菜单侧轻副本）
	var sid := String(p_eid)
	# R72 新形态（E25~E30 先于 E2/E3 短前缀——begins_with 撞前缀）
	if sid.begins_with("E25"):
		return TextureFactory.enemy_tex(&"phase")
	if sid.begins_with("E26"):
		return TextureFactory.enemy_tex(&"shieldlancer")
	if sid.begins_with("E27"):
		return TextureFactory.enemy_tex(&"warden")
	if sid.begins_with("E28"):
		return TextureFactory.enemy_tex(&"hexcaster")
	if sid.begins_with("E29"):
		return TextureFactory.enemy_tex(&"longbow")
	if sid.begins_with("E30"):
		return TextureFactory.enemy_tex(&"revenant")
	if sid.begins_with("E17"):
		return TextureFactory.enemy_tex(&"boss4")
	if sid.begins_with("E18"):
		return TextureFactory.enemy_tex(&"boss5")
	if sid.begins_with("E19"):
		return TextureFactory.enemy_tex(&"boss6")
	if sid.begins_with("E20"):
		return TextureFactory.enemy_tex(&"boss7")
	if sid.begins_with("E6_boss2"):
		return TextureFactory.enemy_tex(&"boss2")
	if sid.begins_with("E6_boss3"):
		return TextureFactory.enemy_tex(&"boss3")
	if sid.begins_with("E6"):
		return TextureFactory.enemy_tex(&"boss1")
	if sid.begins_with("E2"):
		return TextureFactory.enemy_tex(&"dart")
	if sid.begins_with("E3"):
		return TextureFactory.enemy_tex(&"bastion_core")
	if sid.begins_with("E4"):
		return TextureFactory.enemy_tex(&"volatile")
	if sid.begins_with("E5"):
		return TextureFactory.enemy_tex(&"elite")
	if sid.begins_with("E7"):
		return TextureFactory.enemy_tex(&"spitter")
	if sid.begins_with("E8"):
		return TextureFactory.enemy_tex(&"imp")
	if sid.begins_with("E9"):
		return TextureFactory.enemy_tex(&"frostling")
	if sid.begins_with("E10"):
		return TextureFactory.enemy_tex(&"woodbird")
	if sid.begins_with("E11"):
		return TextureFactory.enemy_tex(&"aquasquirt")
	if sid.begins_with("E12"):
		return TextureFactory.enemy_tex(&"bogslime")
	if sid.begins_with("E13"):
		return TextureFactory.enemy_tex(&"bogspitter")
	if sid.begins_with("E14"):
		return TextureFactory.enemy_tex(&"boguard")
	if sid.begins_with("E15"):
		return TextureFactory.enemy_tex(&"bogleaper")
	if sid.begins_with("E16"):
		return TextureFactory.enemy_tex(&"marshmaw")
	return TextureFactory.enemy_tex(&"grunt")


func _make_codex_row(p_tex: ImageTexture, p_unlocked: bool, p_name: String,
		p_desc: String) -> Control:
	# 图鉴行：章形图标 + 名称 + 副文案（未解锁 = 剪影灰 + 问号）
	# R254-1：CodexRow_ 名标 = 页级缓存行回收判据（_recycle_panel_rows 只 detach 不 free）
	var row := Panel.new()
	row.name = "CodexRow_%d" % _codex_row_seq
	_codex_row_seq += 1
	row.add_theme_stylebox_override("panel", StickerTheme.panel_style(12.0, 2, false))
	row.custom_minimum_size = Vector2(576.0, 64.0)
	row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var icon := TextureRect.new()
	icon.texture = p_tex
	icon.position = Vector2(12.0, 12.0)
	icon.custom_minimum_size = Vector2(40.0, 40.0)
	icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	icon.modulate = Color.WHITE if p_unlocked else Color(0.25, 0.27, 0.4, 0.6)
	icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_child(icon)
	var name_l := Label.new()
	StickerTheme.label_sticker(name_l, 17, PopPalette.INK if p_unlocked else PopPalette.INK_SOFT,
		0, Color.WHITE, true)
	name_l.text = p_name
	name_l.position = Vector2(64.0, 10.0)
	name_l.size = Vector2(490.0, 24.0)
	name_l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_child(name_l)
	var desc_l := Label.new()
	StickerTheme.label_sticker(desc_l, 13, PopPalette.INK_SOFT)
	desc_l.text = p_desc
	# P07(R199)：图鉴描述 autowrap + 按实测需求扩高——单行 500×22 定格把最长描述
	#（风域 1263px）拦屏截断，被裁的恰是图鉴要解释的元素反应族。行高用 StickerTheme
	# 字型排版实测（同 card_select_ui._measured_desc_h 口径：wrap 高 + 行距，禁拍值），
	# 行体随描述扩高
	desc_l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	# R252D P2：行高测量缓存（进程级 static）——get_multiline_string_size 按描述全文
	# 键入缓存（宽 500/字号 13 为常量不进键），命中直返。锁定态行全是同一句固定文案
	#（祝福页 73 行同句=73 次排版测量 → 1 次），跨页重复描述（遗物/武器锁定句）同样
	# 命中。codex 行 desc 为静态 .tres 字段或固定句，无失效面（M1 首建上限的直接支撑；
	# 页签重建仍逐行走，仅测量命中缓存——同页重建语义不受影响）。
	var _raw_need: float = 0.0
	if _row_measure.has(p_desc):
		_raw_need = float(_row_measure[p_desc])
	else:
		_raw_need = StickerTheme.font().get_multiline_string_size(p_desc,
			HORIZONTAL_ALIGNMENT_LEFT, 500.0, 13, -1, 7).y
		_row_measure[p_desc] = _raw_need
	var _lines := maxi(1, roundi(_raw_need / maxf(StickerTheme.font().get_height(13), 1.0)))
	var desc_need: float = _raw_need + float(_lines - 1) \
		* float(desc_l.get_theme_constant("line_spacing"))
	desc_l.position = Vector2(64.0, 34.0)
	desc_l.size = Vector2(500.0, maxf(22.0, desc_need))
	desc_l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_child(desc_l)
	row.custom_minimum_size = Vector2(576.0, maxf(64.0, 34.0 + desc_need + 10.0))
	return row


func _make_codex_reaction_row(p_rxn: int) -> Control:
	# R191#5 反应行（576×150 高行——既有 64 行装不下 54px+12px 描边的预览大字）：
	# 左配方双色环 +「+」/ 名称 / 效果与条件 / 解锁 / 倍率（运行时读表）/ 右 54px 预览。
	# 预览复刻 DamagePopup._apply_reaction_look 五项 override（不走 label_sticker——
	# 会覆写 font 破坏反应专属字型）；文案单源 GameConst.reaction_note。
	var rid := String(GameConst.ReactionType.find_key(p_rxn))
	var note: Dictionary = GameConst.reaction_note(rid)
	var row := Panel.new()
	row.name = "RxnRow_%s" % rid
	row.add_theme_stylebox_override("panel", StickerTheme.panel_style(12.0, 2, false))
	row.custom_minimum_size = Vector2(576.0, 150.0)
	row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	# 配方双色环（元素色单源 PopPalette.ELEMENT_COLORS——R192 M2 改引：与跳字同表同源，
	# 改表即跳字+图鉴环自动跟随；36px 环）
	var elems: Array = note.get("elements", [])
	var ring_xs := [14.0, 78.0]
	for e_i in range(mini(elems.size(), 2)):
		var ring := TextureRect.new()
		ring.texture = TextureFactory.ring_tex(
			PopPalette.ELEMENT_COLORS.get(int(elems[e_i]), Color.WHITE), 36, 5.0)
		ring.position = Vector2(float(ring_xs[e_i]), 18.0)
		ring.custom_minimum_size = Vector2(36.0, 36.0)
		ring.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		ring.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		ring.mouse_filter = Control.MOUSE_FILTER_IGNORE
		row.add_child(ring)
	var plus_l := Label.new()
	StickerTheme.label_sticker(plus_l, 17, PopPalette.INK_SOFT)
	plus_l.text = "+"
	plus_l.position = Vector2(50.0, 24.0)
	plus_l.size = Vector2(28.0, 24.0)
	plus_l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	row.add_child(plus_l)
	var name_l := Label.new()
	StickerTheme.label_sticker(name_l, 17, PopPalette.INK, 0, Color.WHITE, true)
	name_l.name = "RxnName"
	name_l.text = String(note.get("name", rid))
	name_l.position = Vector2(128.0, 16.0)
	name_l.size = Vector2(280.0, 28.0)
	row.add_child(name_l)
	var desc_l := Label.new()
	StickerTheme.label_sticker(desc_l, 13, PopPalette.INK_SOFT)
	desc_l.name = "RxnDesc"
	desc_l.text = String(note.get("effect", ""))
	desc_l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART   # 条件句估宽 417~441px 超 400px 格——超宽折行（3 行 57px ≤ 60px 格）
	desc_l.position = Vector2(14.0, 62.0)
	desc_l.size = Vector2(400.0, 60.0)
	row.add_child(desc_l)
	var unlock_l := Label.new()
	StickerTheme.label_sticker(unlock_l, 12, PopPalette.GOLD)
	unlock_l.name = "RxnUnlock"
	unlock_l.text = String(note.get("unlock", ""))
	unlock_l.position = Vector2(14.0, 124.0)
	unlock_l.size = Vector2(396.0, 18.0)
	row.add_child(unlock_l)
	var mult_l := Label.new()
	StickerTheme.label_sticker(mult_l, 12, PopPalette.PLAYER)
	mult_l.name = "RxnMult"
	mult_l.text = _rxn_multiplier_text(rid)
	mult_l.position = Vector2(414.0, 124.0)
	# R198（R192-low8）：绽放（RXN_HYD_DEN）mult_fmt 三段串估宽超 148px 格——autowrap
	# 折两行 + 高 18→34（宽 148/右对齐保持；其余反应单段串单行不受影响。文案真源
	# GameConst mult_fmt 不动——口径 4，UI 侧承宽；R191 收口2 desc_l autowrap 同族）
	mult_l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	mult_l.size = Vector2(148.0, 34.0)
	mult_l.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	row.add_child(mult_l)
	# 坏 ID 兜底改报红（R192 wire T2：禁静默——LOOKS 缺键 = 表现半接线，落首键观感防崩）
	var look: Dictionary = DamagePopup.REACTION_LOOKS.get(p_rxn, {})
	if look.is_empty():
		push_error("[MenuScreen] REACTION_LOOKS 缺键（半接线）：rxn=%d——落首键观感" % p_rxn)
		look = DamagePopup.REACTION_LOOKS.values()[0]
	var prev := Label.new()
	prev.name = "RxnPreview"
	# R192 收口2：样张与实机跳字同源组合（用户口径「反应名+数字（包括图鉴）」）——
	# dmg 型 = 反应名+样张数值段（note.sample 仅此型渲染）；pct/stat 型 = 反应名+
	# DamagePopup.reaction_stat_text 读表统计段（与跳字同一函数，超导-30%/激化+25%…）；
	# 无统计段反应（感电/扩散族）只显名（链伤/扩散一击走自身伤害通道另跳数字）。
	prev.text = String(look["name"]) + (String(note.get("sample", "")) if String(look["fmt"]) == "dmg" \
		else DamagePopup.reaction_stat_text(p_rxn))
	prev.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	prev.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	# 五项 override 逐项对齐 DamagePopup._apply_reaction_look（damage_popup.gd 五连装）
	prev.add_theme_color_override("font_color", look["fill"])
	prev.add_theme_color_override("font_outline_color", look["outline"])
	prev.add_theme_constant_override("outline_size", DamagePopup.OUTLINE_PX_REACTION)
	prev.add_theme_font_override("font", StickerTheme.font_reaction(int(look["variant"])))
	prev.add_theme_font_size_override("font_size", DamagePopup.FONT_SIZE_REACTION)
	prev.position = Vector2(420.0, 18.0)
	prev.size = Vector2(140.0, 78.0)
	row.add_child(prev)
	# R192 visual 批1：预览缩放 CODEX_PREVIEW_SCALE 单源 + pivot 居中（54px 样张缩半适配
	# 140×78 格——不改字号不加宽格，五项对位断言契约不变）。54px 反应字型的最小行高把
	# size.y 顶过 78 设定值（实测 →108）且钳制时机延迟不定——挂 resized 单发跟随：任何
	# 一次尺寸变化（含延迟钳制）都即刻重算 pivot，恒等式 pivot_offset == size×0.5 在任意
	# 时点成立（fx_quality 预览缩放断言口径）。行随页签重建 queue_free，连接随节点销毁。
	prev.resized.connect(func() -> void:
		prev.pivot_offset = prev.size * DamagePopup.CODEX_PREVIEW_SCALE)
	prev.pivot_offset = prev.size * DamagePopup.CODEX_PREVIEW_SCALE
	prev.scale = Vector2.ONE * DamagePopup.CODEX_PREVIEW_SCALE
	prev.mouse_filter = Control.MOUSE_FILTER_IGNORE
	# R196 图鉴锁：未触发反应行锁定态（只读 Meta.is_reaction_seen——标记接线在 Meta 侧
	# _on_reaction_triggered，本文件零写入口）。锁定只改样式不改行集合：全枚举行仍全量
	# 可见（A5/D0 行数断言口径不动），解锁关提示单源复用上方 RxnUnlock 行（note.unlock
	# 已含「第 N 关起」，零新文案、零 GameConst 改动）；行随页签 queue_free 重建 → 战斗内
	# 首次触发后下次进图鉴自然解锁（持久化在 Meta codex/reaction_seen，旧档缺键 → 空表
	# 全锁定，降级不崩）。
	if not Meta.is_reaction_seen(StringName(rid)):
		row.modulate.a = 0.55                    # 降透明读感（_make_codex_blank_row 同族手法）
		# R196：锁徽记 emoji 字面量 → ui_lock 程序贴纸（Android 系统字体链缺 emoji 字形——
		# apk_menu_no_icons 定案；观察名 RxnLockBadge 保留，图鉴武器行锁徽同款贴纸）
		var lock_l := TextureRect.new()
		lock_l.name = "RxnLockBadge"
		lock_l.texture = TextureFactory.ui_lock()
		lock_l.position = Vector2(536.0, 6.0)    # 预览格右上角（格 420..560×18..96）
		lock_l.size = Vector2(26.0, 24.0)
		lock_l.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		lock_l.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		lock_l.mouse_filter = Control.MOUSE_FILTER_IGNORE
		var seen_l := Label.new()
		StickerTheme.label_sticker(seen_l, 12, PopPalette.INK_SOFT)
		seen_l.name = "RxnLockNote"
		seen_l.text = "未触发"
		seen_l.position = Vector2(520.0, 104.0)  # 预览格下方（y96）与 RxnMult（y124）之间——不压倍率
		seen_l.size = Vector2(56.0, 18.0)
		seen_l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		row.add_child(lock_l)
		row.add_child(seen_l)
	return row


func _rxn_multiplier_text(p_rid: String) -> String:
	# R192 wire T2：倍率行 token 格式化器（rid 无关——零 per-rid 分支，新反应零新代码）。
	# 模板单源 GameConst.reaction_note[p_rid].mult_fmt（数值一律不进文案）；数值运行时读
	# GameConfig.balance.reaction_table（禁硬编码数值，禁 rule.get 硬兜底默认——半接线
	# 必须报红不可静默出数）。
	# token 语法（reaction_note.mult_fmt 契约，validator 锁 mult_fmt token 键 ⊆ rule 键）：
	# · {key:spec}     → rule[key] 按 spec printf（spec 如 .1f / .0f）
	# · {key_pc:spec}  → rule[key 剥 _pc 后缀] × 100 后按 spec（resist_delta 等百分比口径）
	# 不可解析 token（键不在表 / 语法残缺）→ push_error + 返空串（D 组行级断言 mult 非空
	# 同红——缺件在页面读得见，不可静默空行）。
	var rule: Dictionary = {}
	if GameConfig.balance != null:
		rule = GameConfig.balance.reaction_table.get(p_rid, {})
	var note: Dictionary = GameConst.reaction_note(p_rid)
	if note.is_empty() or not note.has("mult_fmt"):
		return ""                                 # 坏 id / 模板缺键（validator 闸上游报红）
	var out := ""
	var rest: String = String(note["mult_fmt"])
	while true:
		var open := rest.find("{")
		if open < 0:
			out += rest
			break
		var close := rest.find("}", open)
		if close < 0:                             # 模板残缺（无闭括号）——余段原样落行
			out += rest
			break
		out += rest.substr(0, open)
		var token := rest.substr(open + 1, close - open - 1)
		var sep := token.find(":")
		var key := token.substr(0, sep) if sep >= 0 else ""
		var spec := token.substr(sep + 1) if sep >= 0 else ""
		var rule_key := key.trim_suffix("_pc")
		if key.is_empty() or spec.is_empty() or not rule.has(rule_key):
			push_error("[MenuScreen] mult_fmt token 不可解析：rid=%s token={%s}" % [p_rid, token])
			return ""
		var value := float(rule[rule_key])
		if key.ends_with("_pc"):
			value *= 100.0                        # 百分比口径（×100 后按 spec）
		out += ("%" + spec) % value
		rest = rest.substr(close + 1)
	return out


func _make_codex_blank_row() -> Control:
	# R192 M3 冰+草留白标注行（21 配对唯一空格；R191#4『选了没反应』误报教训——把空白变
	# 规则）。循环后单独追加、不计入枚举行数（A5/D0/X3 行数口径 = 全枚举 或 全枚举+1）；
	# 文案单源 GameConst.REACTION_BLANK_NOTE（数值不进文案，本行不承载任何表值）；
	# 降透明样式 = 全行 modulate 半透（非活动页签同族读感——如实标注非图鉴遗漏）。
	var row := Panel.new()
	row.name = "RxnRow_BLANK"
	row.add_theme_stylebox_override("panel", StickerTheme.panel_style(12.0, 2, false))
	row.custom_minimum_size = Vector2(576.0, 56.0)
	row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.modulate = Color(1.0, 1.0, 1.0, 0.5)
	var note_l := Label.new()
	StickerTheme.label_sticker(note_l, 13, PopPalette.INK_SOFT)
	note_l.name = "RxnBlankNote"
	note_l.text = GameConst.REACTION_BLANK_NOTE
	note_l.position = Vector2(18.0, 18.0)
	note_l.size = Vector2(540.0, 22.0)
	note_l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_child(note_l)
	return row


func _sticker_active_tab() -> void:
	# 活动页签高亮（非活动降透明）
	for kind: String in _codex_tabs:
		(_codex_tabs[kind] as Button).modulate = Color.WHITE \
			if kind == _codex_tab else Color(1.0, 1.0, 1.0, 0.55)


# ── 成就内容（R191#6：类别页签 + 分页——全量行数上百，页容量 24 控单次行构建成本；
#    行构建逻辑复用原 :732-759 不动） ─────────────────────────────────
func _ach_filtered() -> Array:
	# 类别过滤（type 字段单源归类 ACH_TYPE_CATEGORY；未知 type 归「进阶」兜底——
	# 三类别页签遍历累加恒等于全量）
	var out: Array = []
	for a in Meta.ACHIEVEMENTS:
		if _ach_tab == "全部" or String(ACH_TYPE_CATEGORY.get(String(a.type), "进阶")) == _ach_tab:
			out.append(a)
	return out


func _ach_page_count() -> int:
	# 当前页签总页数（≥1——空类别也保持「1/1」读数与翻页按钮可用语义）
	return maxi(1, ceili(float(_ach_filtered().size()) / float(ACH_PAGE_SIZE)))


func _on_ach_tab(p_tab: String) -> void:
	_ach_tab = p_tab
	_ach_page = 0                              # 切类别回第一页
	_rebuild_achievements()


func _on_ach_page_next() -> void:
	_ach_page = mini(_ach_page + 1, _ach_page_count() - 1)
	_rebuild_achievements()


func _on_ach_page_prev() -> void:
	_ach_page = maxi(_ach_page - 1, 0)
	_rebuild_achievements()


func _set_ach_pager_visible(p_visible: bool) -> void:
	# 翻页控件显隐（页签行与返回大厅按钮同排错峰——选关面板/其他页签下不可见）
	if _ach_prev_btn != null:
		_ach_prev_btn.visible = p_visible
		_ach_next_btn.visible = p_visible
		_ach_page_label.visible = p_visible


func _sticker_ach_tab() -> void:
	# 成就活动页签高亮（非活动降透明；_sticker_active_tab 同款）
	for kind: String in _ach_tabs:
		(_ach_tabs[kind] as Button).modulate = Color.WHITE \
			if kind == _ach_tab else Color(1.0, 1.0, 1.0, 0.55)


func _ach_desc_text(p_a: Dictionary, p_done: bool) -> String:
	# R259：成就行 desc 文本单源（建行与缓存轻刷共用——防双源漂移，R245 同教训）。
	# R245 §4.4-3 行内进度：未完成行尾追加「x/y」（当前值经 Meta._counter_value
	# 逐条取）。已完成行维持「　已完成」；desc 已含进度语义（「当前」字样）不重复显示。
	var dtext := String(p_a.desc)
	if p_done:
		dtext += "　已完成"
	elif not dtext.contains("当前"):
		dtext += "　%d/%d" % [int(Meta._counter_value(String(p_a.type), p_a)), int(p_a.target)]
	return dtext


func _ach_key() -> String:
	# R259 评审 MED-2：成就缓存键单源=页签|页码——四页签列表长不等，键漏页签维度
	# 则切签恒 miss+旧页签 rows 被同键覆盖泄漏（且位图长恰等时潜伏 sig 撞车串页）。
	return "%s|%d" % [_ach_tab, _ach_page]


func _rebuild_achievements() -> void:
	var list := _ach_filtered()
	var pages := maxi(1, ceili(float(list.size()) / float(ACH_PAGE_SIZE)))
	_ach_page = clampi(_ach_page, 0, pages - 1)
	# R259 行缓存：sig=页码+全表完成位图（mark/name 色随 done——sig 变则整页重建）；
	# desc 尾进度数字不入 sig（高频变化防抖动），命中时逐行轻刷文本（<0.5ms）
	var done_sig := ""
	for i in range(list.size()):
		done_sig += "1" if Meta.is_ach_done(list[i].id) else "0"
	var sig := "%d|%s" % [_ach_page, done_sig]
	var cached: Dictionary = _ach_page_cache.get(_ach_key(), {})
	# R267 修轮1：同态直跳——当前页行已按序挂树、sig 一致（done 位图未变=行色/勾
	# 不变）且逐行 desc 文本全等（含进度 x/y——纯读比对，字符串级，零 Label 工作）
	# 则显示态已等价，跳过 detach+reattach 整段（逐行重进树 ~85-195µs/行是「成就
	# 重开 5ms」大头——P3 三面板同款直跳，r259 ④ 性能门的贴脸抖动根治）。
	if not cached.is_empty() and String(cached.get("sig", "")) == sig \
			and _rows_attached_in_order(cached.get("rows", [])):
		var fresh := true
		for r_f_v: Variant in cached["rows"]:
			var row_f: Control = r_f_v
			var a_f: Dictionary = row_f.get_meta("ach", {})
			var desc_f: Label = row_f.get_node_or_null("DescL") as Label
			if desc_f == null or a_f.is_empty() \
					or desc_f.text != _ach_desc_text(a_f,
						Meta.is_ach_done(a_f.get(&"id", &""))):
				fresh = false
				break
		if fresh:
			_sticker_ach_tab()
			if _ach_page_label != null:
				_ach_page_label.text = "%d/%d" % [_ach_page + 1, pages]
				if _ach_prev_btn != null:
					_ach_prev_btn.disabled = _ach_page <= 0
				_ach_next_btn.disabled = _ach_page >= pages - 1
			return
	_recycle_panel_rows()                   # R254-1：统一回收口（缓存行 detach 回缓存，其余照旧 free）
	if not cached.is_empty() and String(cached.get("sig", "")) == sig:
		for r_v: Variant in cached["rows"]:
			var row_c: Control = r_v
			var a_c: Dictionary = row_c.get_meta("ach", {})
			var desc_l: Label = row_c.get_node_or_null("DescL") as Label
			if desc_l != null and not a_c.is_empty():
				desc_l.text = _ach_desc_text(a_c, Meta.is_ach_done(a_c.get("id", &"")))
			_panel_list.add_child(row_c)
		_sticker_ach_tab()
		if _ach_page_label != null:
			_ach_page_label.text = "%d/%d" % [_ach_page + 1, pages]
			if _ach_prev_btn != null:
				_ach_prev_btn.disabled = _ach_page <= 0
			_ach_next_btn.disabled = _ach_page >= pages - 1
		return
	var rows: Array = []
	for i in range(_ach_page * ACH_PAGE_SIZE, mini((_ach_page + 1) * ACH_PAGE_SIZE, list.size())):
		var a: Dictionary = list[i]
		var done := Meta.is_ach_done(a.id)
		var row := Panel.new()
		row.name = "AchRow_%d" % i                   # R259：缓存行名标（回收口 detach 白名单）
		row.set_meta("ach", a)                       # 轻刷取成就定义（Dictionary 引用轻拷）
		row.add_theme_stylebox_override("panel", StickerTheme.panel_style(12.0, 2, false))
		row.custom_minimum_size = Vector2(576.0, 60.0)
		row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		row.mouse_filter = Control.MOUSE_FILTER_IGNORE
		var mark := Label.new()
		mark.name = "Mark"
		StickerTheme.label_sticker(mark, 24, PopPalette.SUCCESS if done else PopPalette.INK_SOFT,
			0, Color.WHITE, true)
		mark.text = "✓" if done else "·"
		mark.position = Vector2(18.0, 14.0)
		mark.size = Vector2(36.0, 32.0)
		mark.mouse_filter = Control.MOUSE_FILTER_IGNORE
		row.add_child(mark)
		var name_l := Label.new()
		name_l.name = "NameL"
		StickerTheme.label_sticker(name_l, 17, PopPalette.INK if done else PopPalette.INK_SOFT,
			0, Color.WHITE, true)
		name_l.text = String(a.name)
		name_l.position = Vector2(60.0, 8.0)
		name_l.size = Vector2(480.0, 24.0)
		name_l.mouse_filter = Control.MOUSE_FILTER_IGNORE
		row.add_child(name_l)
		var desc_l := Label.new()
		desc_l.name = "DescL"
		StickerTheme.label_sticker(desc_l, 13, PopPalette.INK_SOFT)
		desc_l.text = _ach_desc_text(a, done)   # R259：文本单源（轻刷同款口径）
		desc_l.position = Vector2(60.0, 32.0)
		desc_l.size = Vector2(500.0, 22.0)
		desc_l.mouse_filter = Control.MOUSE_FILTER_IGNORE
		row.add_child(desc_l)
		_panel_list.add_child(row)
		rows.append(row)
	# R259 评审 HIGH-1：覆盖前释放旧 rows（旧键行已被 _recycle_panel_rows detach，
	# 整键覆盖后失去全部引用——Node 非 RefCounted 不 free 即孤儿泄漏）
	_free_cached_rows(_ach_page_cache.get(_ach_key(), {}).get("rows", []))
	_ach_page_cache[_ach_key()] = {"sig": sig, "rows": rows}   # R259：入缓存（键=页签|页码，评审 MED-2）
	_sticker_ach_tab()
	if _ach_page_label != null:
		_ach_page_label.text = "%d/%d" % [_ach_page + 1, pages]
		if _ach_prev_btn != null:
			_ach_prev_btn.disabled = _ach_page <= 0
			_ach_next_btn.disabled = _ach_page >= pages - 1


# ── 角色选择 ──────────────────────────────────────────────────────
func _rebuild_char_select() -> void:
	_recycle_panel_rows()                   # R254-1：统一回收口（缓存行 detach 回缓存，其余照旧 free）
	# R259 全量签名缓存：行内全部动态输入入 sig（picked/解锁位图/购买力位图/结晶值/
	# 自定义武器/图鉴武器计数/击杀总数/无尽深度/所选难度——锁定 hint 与按钮出现消失
	# 全随之变；第九项难度=评审 MED-1：_custom_weapon_label 读 _sel_difficulty，
	# 漏项则切难度后重开选人武器钮文本陈旧）。
	# sig 同=直挂缓存行（<1ms）；sig 变=整页重建。无失效口=无陈旧数据风险（R254-D1 同型防御）
	var unlock_bits := ""
	var buy_bits := ""
	for i in range(CharacterTable.count()):
		var def_i := CharacterTable.CHARACTERS[i]
		unlock_bits += "1" if Meta.is_character_unlocked(def_i.id) else "0"
		buy_bits += "1" if int(def_i.get("unlock_price", 0)) > 0 \
			and Meta.crystals >= int(def_i.get("unlock_price", 0)) else "0"
	var best_depth := int(Meta.call(&"best_endless_depth")) \
		if Meta.has_method(&"best_endless_depth") else 0
	var sig := "%s|%s|%s|%d|%s|%d|%d|%d|%d" % [String(Meta.character_id), unlock_bits, buy_bits,
		Meta.crystals, String(Meta.custom_weapon()), Meta.codex_weapons.size(),
		int(Meta.records.get("total_kills", 0)), best_depth, _sel_difficulty]
	var cached_rows: Array = _char_rows_cache.get("rows", [])
	if String(_char_rows_cache.get("sig", "")) == sig and not cached_rows.is_empty():
		for r_v: Variant in cached_rows:
			_panel_list.add_child(r_v)
		return
	var rows: Array = []
	for i in range(CharacterTable.count()):
		var def := CharacterTable.CHARACTERS[i]
		var picked: bool = Meta.character_id == def.id
		var unlocked: bool = Meta.is_character_unlocked(def.id)
		var row := Panel.new()
		row.name = "CharRow_%d" % i                   # R259：缓存行名标（回收口 detach 白名单）
		row.add_theme_stylebox_override("panel", StickerTheme.panel_style(14.0, 3, false))
		row.custom_minimum_size = Vector2(576.0, 140.0)   # R194 触控目标放大联动（118→140，行底容纳 92+48 武器循环钮）
		row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		row.mouse_filter = Control.MOUSE_FILTER_IGNORE
		# 技能图标（2026-08-31 用户反馈「技能好歹画个对应的图标」）：行首 48px 程序化图标
		var skill_ico := TextureRect.new()
		skill_ico.name = "SkillIcon"
		skill_ico.texture = TextureFactory.skill_icon(def.id)
		skill_ico.position = Vector2(14.0, 24.0)
		skill_ico.custom_minimum_size = Vector2(48.0, 48.0)
		skill_ico.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		skill_ico.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		skill_ico.modulate.a = 1.0 if unlocked else 0.3
		skill_ico.mouse_filter = Control.MOUSE_FILTER_IGNORE
		row.add_child(skill_ico)
		var name_l := Label.new()
		name_l.name = "NameL"
		StickerTheme.label_sticker(name_l, 20, PopPalette.PLAYER if picked else (PopPalette.INK if unlocked else PopPalette.INK_SOFT),
			0, Color.WHITE, true)
		var unlock_hint := ""
		if not unlocked:
			unlock_hint = _locked_hint(def)
		name_l.text = String(def.name) + ("　✓ 当前" if picked else "") + unlock_hint
		name_l.position = Vector2(74.0, 12.0)
		name_l.size = Vector2(406.0, 28.0)
		# R198（二aw-7）：锁定句溢出兜底折行（高度 28 不变；theme.gd label_sticker 默认不加
		# autowrap——调用点显式设避免全站涟漪；防未来文案漂移再裁字）
		name_l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		name_l.mouse_filter = Control.MOUSE_FILTER_IGNORE
		row.add_child(name_l)
		var stat_l := Label.new()
		StickerTheme.label_sticker(stat_l, 14, PopPalette.INK_SOFT)
		stat_l.text = "生命 %d　攻击 %s%.0f%%" % [int(def.hp),
			"+" if float(def.atk_pct) >= 0.0 else "", float(def.atk_pct) * 100.0]
		stat_l.position = Vector2(74.0, 46.0)
		stat_l.size = Vector2(346.0, 20.0)
		stat_l.mouse_filter = Control.MOUSE_FILTER_IGNORE
		row.add_child(stat_l)
		# 技能行（R186：改 def.get() 读法 + no_skill 分支——全项目唯一点读
		# def.skill_name/skill_desc/cd 处，fission 无技能键不崩）
		# R198（P2-skillcopy）：noah desc 尾补 12% 括注后长文案溢出 486px 单行格——
		# 换行区自检落位：skill_l 补 autowrap（行底 72..108 有空，140 行高内二行可容；
		# 短文案角色单行不变。调用点显式设——同二aw-7 name_l 口径，不动 label_sticker）
		var has_skill := CharacterTable.has_skill(def.id)
		var skill_l := Label.new()
		StickerTheme.label_sticker(skill_l, 14, PopPalette.ENEMY)
		if has_skill:
			skill_l.text = "技能【%s】%s（CD %.0fs）" % [String(def.get("skill_name", "")),
				String(def.get("skill_desc", "")), float(def.get("cd", 120.0))]
		else:
			skill_l.text = "无技能 · 初始武器自定义（开局前选定）"
		skill_l.position = Vector2(74.0, 72.0)
		skill_l.size = Vector2(486.0, 36.0)
		skill_l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		skill_l.mouse_filter = Control.MOUSE_FILTER_IGNORE
		row.add_child(skill_l)
		if not has_skill:
			# R186 改造者·枢：行内首发武器循环（候选 = 手枪白名单 ∪ 图鉴已解锁，registry 序）
			var wcycle := Button.new()
			wcycle.name = "CustomWeaponCycle"
			wcycle.text = "初始武器：%s ▸" % _custom_weapon_label()
			wcycle.add_theme_font_size_override("font_size", 13)
			wcycle.add_theme_font_override("font", StickerTheme.font_bold())
			wcycle.position = Vector2(74.0, 92.0)
			wcycle.size = Vector2(300.0, 48.0)   # R194 触控目标放大（300×24→300×48，行底 92+48=140 恰齐）
			wcycle.focus_mode = Control.FOCUS_NONE
			# R190：武器效果 hover 说明——循环切换按钮只改名不解释，玩家不知道每把枪
			# 干嘛的（尤其棱镜「万镜回廊」这类特殊机制）；note 取 GameConst 真源，
			# cycle 后 _rebuild_char_select 重建按钮 → tooltip 随新武器刷新
			var cw_note := GameConst.weapon_note(String(Meta.custom_weapon())) if String(Meta.custom_weapon()) != "" \
				else GameConst.weapon_note("W1_pistol")
			wcycle.tooltip_text = "点击切换初始武器\n%s" % cw_note if cw_note != "" \
				else "点击切换初始武器"
			wcycle.mouse_filter = Control.MOUSE_FILTER_STOP
			wcycle.pressed.connect(_on_custom_weapon_cycle)
			wcycle.button_down.connect(func() -> void: StickerTheme.press_punch(wcycle))
			row.add_child(wcycle)
			var codex_l := Label.new()
			StickerTheme.label_sticker(codex_l, 12, PopPalette.INK_SOFT)
			codex_l.text = "图鉴 %d/%d · 局内抽到新枪可解选" % [
				Meta.codex_weapons.size(),
				registry.weapons.size() if registry != null else 0]
			codex_l.position = Vector2(382.0, 118.0)   # R194 联动下移（96→118，避让放大后的武器循环钮 92-140）
			codex_l.size = Vector2(180.0, 18.0)
			codex_l.mouse_filter = Control.MOUSE_FILTER_IGNORE
			row.add_child(codex_l)
		if not picked and unlocked:
			var pick_btn := Button.new()
			pick_btn.text = "选用"
			pick_btn.add_theme_font_size_override("font_size", 16)
			pick_btn.add_theme_font_override("font", StickerTheme.font_bold())
			pick_btn.position = Vector2(478.0, 38.0)
			pick_btn.size = Vector2(84.0, 56.0)   # R194 触控目标放大（84×44→84×56，角色行 140 内）
			pick_btn.focus_mode = Control.FOCUS_NONE
			pick_btn.pressed.connect(_on_char_pick.bind(def.id))
			pick_btn.button_down.connect(func() -> void: StickerTheme.press_punch(pick_btn))
			row.add_child(pick_btn)
		elif not picked and int(def.get("unlock_price", 0)) > 0:
			# 购买门：解锁按钮（结晶不足置灰——purchase_character 不足返回 false 口径）
			# R196：结晶符号 → ui_gem 贴纸 icon（Button.icon 原生排版，84px 钮内 icon_max_width 钳宽防挤）
			var price := int(def.get("unlock_price", 0))
			var buy_btn := Button.new()
			buy_btn.text = "解锁 %d" % price
			buy_btn.icon = TextureFactory.ui_gem()
			buy_btn.add_theme_constant_override("icon_max_width", 20)
			buy_btn.add_theme_font_size_override("font_size", 14)
			buy_btn.add_theme_font_override("font", StickerTheme.font_bold())
			buy_btn.position = Vector2(478.0, 38.0)
			buy_btn.size = Vector2(84.0, 56.0)   # R194 触控目标放大（84×44→84×56，角色行 140 内）
			buy_btn.focus_mode = Control.FOCUS_NONE
			buy_btn.disabled = Meta.crystals < price
			buy_btn.pressed.connect(_on_char_buy.bind(def.id))
			buy_btn.button_down.connect(func() -> void: StickerTheme.press_punch(buy_btn))
			row.add_child(buy_btn)
		_panel_list.add_child(row)
		rows.append(row)
	_free_cached_rows(_char_rows_cache.get("rows", []))   # R259 评审 HIGH-1：覆盖前释放旧 rows（防孤儿泄漏）
	_char_rows_cache = {"sig": sig, "rows": rows}   # R259：入缓存


func _locked_hint(p_def: Dictionary) -> String:
	# R246：锁定角色解锁条件文案单源（_rebuild_char_select 原内联链提取，分支逐字节
	# 等价 + 新增 endless_depth 门）。链序与 Meta.is_character_unlocked 判定链
	# （meta_manager.gd）平行同位同序——漏改任一侧则锁定角色 hint 空串/判定错门。
	# R196：锁/奖杯/结晶 emoji 前缀删除（Android 系统字体链缺 SMP 字形只出字不出图——
	# apk_menu_no_icons 定案 T7；仅删符号不动词，行首全角空格保留）
	var umap: StringName = p_def.get("unlock_map", &"")
	if umap != &"":
		return "　通关「%s」解锁" % String(MapTable.get_map(umap).get("name", "?"))
	if bool(p_def.get("unlock_normal_clear", false)):
		# R186：改造者·枢——任一地图常规局普通通关（每日局结算分流不解锁）
		# R198（二aw-7）：锁定句压缩——删「任一地图常规局 · 当前最佳 %d 波」段（当前最佳
		# 波次已由记录/成就面可见，此处冗余）。规划拟句「（首关需 %d 波）」连同角色名前缀
		# 实测仍溢 406px 格（≈21.5 全角 ≈430px → name_l autowrap 折两行压 stat/skill 行），
		# 再省「需」字 + 数字前空格（语义不变）→ 估宽 400px（真字型 396px）单行可容；
		# 兜底见 _rebuild_char_select name_l autowrap。
		return "　通关普通难度解锁（首关%d 波）" % [
			int(MapTable.get_map(MapTable.FIRST_MAP_ID).get("final_wave", 10))]
	if bool(p_def.get("unlock_hard_clear", false)):
		return "　任意地图·困难难度通关解锁"   # R186：回响·伊可
	if int(p_def.get("unlock_endless_depth", 0)) > 0:
		# R246：无尽深度成就门（medic 20 层 / vortex 50 层，_channels.md §3/§4 单源句式，
		# 插入位=hard_clear 之后 kills 之前，与 meta 判定链同位同序）。M=历史最深无尽深度
		# ——跨泳道依赖 Meta.best_endless_depth()（meta 泳道 R247 聚合读口：跨地图 × 跨
		# #1/#2 分档键取最大），has_method 守卫（R186 同式）保证并行窗口期本文件可编译
		# 可跑（读 0），meta 合入后同口直读自动生效；打开面板即读属查询非解锁动作
		var best_depth := int(Meta.call(&"best_endless_depth")) \
			if Meta.has_method(&"best_endless_depth") else 0
		return "　任意无尽模式深入 %d 层解锁（当前 %d）" % [
			int(p_def.get("unlock_endless_depth", 0)), best_depth]
	if int(p_def.get("unlock_kills", 0)) > 0:
		return "　图鉴累计击杀 %d 解锁" % int(p_def.get("unlock_kills", 0))
	if p_def.get("unlock_achievement", &"") != &"":
		var uach: StringName = p_def.get("unlock_achievement", &"")
		var aname := String(uach)
		for a in Meta.ACHIEVEMENTS:
			if a.id == uach:
				aname = String(a.name)
		return "　成就「%s」解锁" % aname
	if int(p_def.get("unlock_price", 0)) > 0:
		return "　结晶解锁 %d（当前 %d）" % [int(p_def.get("unlock_price", 0)), Meta.crystals]
	return ""


func _custom_weapon_candidates() -> Array[StringName]:
	# R186：fission 首发候选集 = W1_pistol 白名单（W1 被卡池永久排除，必须放行）∪
	# 图鉴已解锁武器（registry 序，去重）。
	# R196：准入门只设在「来源侧」（卡池上架 + echo 双武装池——mechanic_gate.gd wunlock
	# 注释块）；到达本处的候选必已获得（上行 is_weapon_unlocked 过滤），按「获得优先于门」
	# 照常入选——R196 评审修复：原 weapon_allowed 过滤在菜单态读 run_map 残留（冷启动
	# =world_grass → map_index()==0），把老档已获得∧门外武器全滤掉（10→3 把）且循环钮
	# 把存档非初始批首发静默降级手枪落盘——定案 P6「老档无损」被破，整段门滤除。
	# R253（二dc L2 缓办清账）难度门：地狱限定的近战/法器不再作为首发候选（用户难度
	# 层意图「普通见不到近战/法器」优先于「获得优先于门」——后者仅在卡池/echo 生效）；
	# 按选关面板当前所选难度 _sel_difficulty 过滤（非 Meta.run_gate_difficulty 哨兵——
	# 菜单态未进局恒 -1 全开）。白名单首元素恒在 → 结果恒非空。
	var cands: Array[StringName] = [&"W1_pistol"]
	if registry != null:
		for wid_v: Variant in registry.weapons.keys():
			var sid := StringName(String(wid_v))
			if sid == &"W1_pistol" or cands.has(sid) or not Meta.is_weapon_unlocked(sid):
				continue
			if MechanicGate.weapon_difficulty_min(sid) > _sel_difficulty:
				continue
			cands.append(sid)
	return cands


func _custom_weapon_label() -> String:
	# R186：当前首发展示名（空键 → 手枪；脏 id → 原样 id 文本）
	# R253 评审 M5 诚实化：门外武器（超当前所选难度）显示实际回落——开局
	# _starting_weapon_id 同门兜底回落手枪，原样显示存档名 = 按钮说谎
	var wid := Meta.custom_weapon()
	if wid == &"":
		return "手枪"
	var wd: WeaponData = registry.get_weapon(wid) if registry != null else null
	var disp := String(wd.display_name) if wd != null else String(wid)
	if MechanicGate.weapon_difficulty_min(wid) > _sel_difficulty:
		return "%s（本档未开→手枪）" % disp
	return disp


func _on_custom_weapon_cycle() -> void:
	# R186：首发循环按钮——候选序取当前下一项（缺项/脏键 → 回首候选），写口自校验
	#（未解锁 push_warning 忽略）+ 写即落盘，重建面板即时刷新
	var cands := _custom_weapon_candidates()
	if cands.is_empty():
		return
	var idx := cands.find(Meta.custom_weapon())
	var next: StringName = cands[0] if idx < 0 else cands[(idx + 1) % cands.size()]
	Meta.set_custom_weapon(next)
	_rebuild_char_select()


func _on_char_pick(p_id: StringName) -> void:
	Meta.set_character_id(p_id)
	_rebuild_char_select()
	_refresh_lobby_counts()
	_refresh_mascot()


func _on_char_buy(p_id: StringName) -> void:
	# 结晶购买角色（Meta 扣费 + 永久记录；成功音同「换一批次数」金币音——购买爽感反馈）
	if Meta.purchase_character(p_id):
		if SfxBank.I != null:
			SfxBank.I.play(&"coin")
	_rebuild_char_select()
	_refresh_lobby_counts()


# ── 局外养成（结晶 + 永久升级） ──────────────────────────────────
func _rebuild_upgrades() -> void:
	# R267 刀P3：同态直跳（行已按序挂树且指纹一致——购买轻刷新已重算 fp，关→开
	# 同面板零成本；行序含头/星尘/升级行/注，见 _build_upgrades_rows）
	if _rows_attached_in_order(_upg_rows_cache) and _upgrades_fp() == _upg_fp:
		return
	_recycle_panel_rows()                   # R254-1：统一回收口（图鉴缓存行 detach 回缓存，其余照旧 free）
	# R267 刀P3：指纹比对复用——货币量与各级别不变（纯读快照）则整组行直挂（基线
	# 11782µs/次 → 直挂量级）；购买路径另走 _refresh_upgrades_rows 轻刷（只改文案/态）
	var fp := _upgrades_fp()
	if _upg_rows_cache.is_empty() or fp != _upg_fp:
		_free_cached_rows(_upg_rows_cache)
		_upg_rows_cache = _build_upgrades_rows()
		_upg_fp = fp
	# 轻刷新引用随组重建/直挂重抓（防旧组引用悬空）
	_refresh_upg_refs()
	for row_v: Variant in _upg_rows_cache:
		_panel_list.add_child(row_v)


func _upgrades_fp() -> String:
	# R267 刀P3：养成面板指纹 = 双货币 + 各升级 id:lv（决定行文案/按钮态的字段全集，
	# v3 评审⑴构造规矩）。UPGRADES 静态序即展示序，级别串按 Meta.UPGRADES 序拼接。
	var lvs := ""
	for u: Dictionary in Meta.UPGRADES:
		lvs += "%s:%d;" % [String(u.get("id", "")), Meta.upgrade_level(u.id)]
	return "%d|%d|%s" % [Meta.crystals, Meta.stardust, lvs]


func _build_upgrades_rows() -> Array:
	# R267 刀P3：养成行纯构建（原 _rebuild_upgrades 主体不变，产出改入数组 + 名标）
	var rows: Array = []
	var head := Label.new()
	head.name = "UpgRow_%d" % _upg_row_seq          # R267 刀P3：缓存行名标
	_upg_row_seq += 1
	StickerTheme.label_sticker(head, 20, PopPalette.XP, 0, Color.WHITE, true)
	head.text = "裂变结晶：%d（每局结算产出：波次 + 击杀）" % Meta.crystals
	head.custom_minimum_size = Vector2(576.0, 36.0)
	head.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	head.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	rows.append(head)
	# R263 星尘行（结晶头行下追加——双轨货币双行披露；星尘=祝福携带消耗/每局结算产出，
	# 与结晶互不兑换）。四芒星图标（TextureFactory.stardust_icon）+ 居中文案。
	var sd_box := HBoxContainer.new()
	sd_box.name = "UpgRow_%d" % _upg_row_seq
	_upg_row_seq += 1
	sd_box.alignment = BoxContainer.ALIGNMENT_CENTER
	sd_box.add_theme_constant_override("separation", 6)
	sd_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var sd_icon := TextureRect.new()
	sd_icon.texture = TextureFactory.stardust_icon()
	sd_icon.custom_minimum_size = Vector2(20.0, 20.0)
	sd_icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	sd_icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	sd_icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
	sd_box.add_child(sd_icon)
	var sd_label := Label.new()
	StickerTheme.label_sticker(sd_label, 15, PopPalette.GOLD, 0, Color.WHITE, true)
	sd_label.text = "星尘：%d（每局结算产出 · 祝福携带消耗）" % Meta.stardust
	sd_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	sd_box.add_child(sd_label)
	rows.append(sd_box)
	for u in Meta.UPGRADES:
		var lv := Meta.upgrade_level(u.id)
		var maxed := lv >= int(u.max_lv)
		var cost := Meta.upgrade_cost(u.id)
		var row := Panel.new()
		row.name = "UpgRow_%d" % _upg_row_seq
		_upg_row_seq += 1
		row.add_theme_stylebox_override("panel", StickerTheme.panel_style(12.0, 2, false))
		row.custom_minimum_size = Vector2(576.0, 68.0)
		row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		row.mouse_filter = Control.MOUSE_FILTER_IGNORE
		var name_l := Label.new()
		StickerTheme.label_sticker(name_l, 17, PopPalette.INK, 0, Color.WHITE, true)
		name_l.text = "%s  Lv%d/%d" % [String(u.name), lv, int(u.max_lv)]
		name_l.position = Vector2(18.0, 8.0)
		name_l.size = Vector2(320.0, 26.0)
		name_l.mouse_filter = Control.MOUSE_FILTER_IGNORE
		row.add_child(name_l)
		var desc_l := Label.new()
		StickerTheme.label_sticker(desc_l, 13, PopPalette.INK_SOFT)
		desc_l.text = String(u.desc)
		desc_l.position = Vector2(18.0, 36.0)
		desc_l.size = Vector2(340.0, 20.0)
		desc_l.mouse_filter = Control.MOUSE_FILTER_IGNORE
		row.add_child(desc_l)
		var buy := Button.new()
		# R196：结晶符号 → ui_gem 贴纸 icon（已满级无花费 → 不挂贴纸；140px 钮内排版余量足）
		buy.text = "已满级" if maxed else "升级 (%d)" % cost
		buy.icon = null if maxed else TextureFactory.ui_gem()
		if not maxed:
			buy.add_theme_constant_override("icon_max_width", 22)
		buy.add_theme_font_size_override("font_size", 15)
		buy.add_theme_font_override("font", StickerTheme.font_bold())
		buy.position = Vector2(420.0, 6.0)   # R194 触控目标放大 140×56（养成行 68 内居中：6+56=62）
		buy.size = Vector2(140.0, 56.0)
		buy.focus_mode = Control.FOCUS_NONE
		buy.disabled = maxed or Meta.crystals < cost
		buy.pressed.connect(_on_buy_upgrade.bind(u.id))
		buy.button_down.connect(func() -> void: StickerTheme.press_punch(buy))
		row.add_child(buy)
		rows.append(row)
	var note := Label.new()
	note.name = "UpgRow_%d" % _upg_row_seq
	_upg_row_seq += 1
	StickerTheme.label_sticker(note, 13, PopPalette.INK_SOFT)
	note.text = "养成永久生效：开局自动应用（生命/攻击/磁吸/技能冷却）"
	note.custom_minimum_size = Vector2(576.0, 24.0)
	note.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	note.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	rows.append(note)
	return rows


func _refresh_upg_refs() -> void:
	# R267 刀P3：轻刷新引用重抓——缓存组内节点序 = [head, sd_box, 升级行×N, note]，
	# 引用按序落位（组重建/直挂后统一调用，防跨组悬空引用）
	_upg_row_refs = []
	_upg_head = null
	_upg_sd = null
	if _upg_rows_cache.size() < 2:
		return
	_upg_head = _upg_rows_cache[0] as Label
	_upg_sd = _upg_rows_cache[1] as HBoxContainer
	var idx := 2
	for u: Dictionary in Meta.UPGRADES:
		if idx >= _upg_rows_cache.size():
			break
		var row: Panel = _upg_rows_cache[idx] as Panel
		var refs := {
			"name_l": row.get_child(0) as Label,
			"buy": row.get_child(row.get_child_count() - 1) as Button,
			"u": u,
		}
		_upg_row_refs.append(refs)
		idx += 1


func _refresh_upgrades_rows() -> void:
	# R267 刀P3：购买轻刷新——不重建行（零 Label/Button 新建），只刷货币双行 + 每行
	# Lv 文案/按钮文案/icon/禁用态，尾段重算指纹（下次开面板直挂命中）。行序 =
	# Meta.UPGRADES 序（静态），与 _upg_row_refs 逐位对齐。
	if _upg_head != null:
		_upg_head.text = "裂变结晶：%d（每局结算产出：波次 + 击杀）" % Meta.crystals
	if _upg_sd != null and _upg_sd.get_child_count() >= 2:
		(_upg_sd.get_child(1) as Label).text = "星尘：%d（每局结算产出 · 祝福携带消耗）" % Meta.stardust
	for r_v: Variant in _upg_row_refs:
		var refs: Dictionary = r_v
		var u: Dictionary = refs.get("u", {})
		var lv := Meta.upgrade_level(u.id)
		var maxed := lv >= int(u.max_lv)
		var cost := Meta.upgrade_cost(u.id)
		(refs.get("name_l") as Label).text = "%s  Lv%d/%d" % [String(u.name), lv, int(u.max_lv)]
		var buy: Button = refs.get("buy")
		buy.text = "已满级" if maxed else "升级 (%d)" % cost
		buy.icon = null if maxed else TextureFactory.ui_gem()
		if not maxed:
			buy.add_theme_constant_override("icon_max_width", 22)
		buy.disabled = maxed or Meta.crystals < cost
	_upg_fp = _upgrades_fp()


func _on_buy_upgrade(p_id: StringName) -> void:
	if Meta.buy_upgrade(p_id):
		_refresh_upgrades_rows()      # R267 刀P3：面板内轻刷替代全量重建（行不换实例）
		_refresh_lobby_counts()


# ── 每日挑战（P2：当日固定种子 + 三词缀 + daily_best——全玩家同日同配置口径） ──
func _rebuild_daily() -> void:
	# R267 刀P3：同态直跳（缓存行 + 出发钮共挂树且指纹一致；p_extra=1 = 钮在尾）
	if _rows_attached_in_order(_dly_rows_cache, 1) and _daily_fp() == _dly_fp:
		return
	_recycle_panel_rows()                   # R254-1：统一回收口（图鉴缓存行 detach 回缓存，其余照旧 free）
	# R267 刀P3：指纹比对复用——日期键（词缀源）与当日最佳不变则整组行直挂（基线
	# 3233µs/次 → 直挂量级）。词缀由日期键纯函数派生，故日期入指纹即覆盖词缀行。
	# 出发按钮不缓存（保留语义名 DailyStartButton——verify_feedback 可达性断言用；
	# 名不入 detach 白名单会被回收口释放，单 Button 重建仅 µs 级，不入缓存组）
	var fp := _daily_fp()
	if _dly_rows_cache.is_empty() or fp != _dly_fp:
		_free_cached_rows(_dly_rows_cache)
		_dly_rows_cache = _build_daily_rows()
		_dly_fp = fp
	for row_v: Variant in _dly_rows_cache:
		_panel_list.add_child(row_v)
	_panel_list.add_child(_build_daily_go_button())


func _daily_fp() -> String:
	# R267 刀P3：每日面板指纹 = 日期键（词缀/日期文案源）+ 当日 best_wave/best_kills
	# （最佳行文案源，v3 评审⑴构造规矩——显示字段全集）
	var key := Meta.daily_date_key()
	var best := Meta.daily_record(key)
	return "%s|%d|%d" % [key, int(best.get("best_wave", 0)), int(best.get("best_kills", 0))]


func _build_daily_rows() -> Array:
	# R267 刀P3：每日行纯构建（原 _rebuild_daily 主体不变，产出改入数组 + 名标）
	var rows: Array = []
	var key := Meta.daily_date_key()
	var date_disp := "%s-%s-%s" % [key.substr(0, 4), key.substr(4, 2), key.substr(6, 2)]
	var affixes := Meta.daily_affixes(key)
	# 当日词缀行（诅咒 ×2 珊瑚红 / 吉兆 ×1 薄荷绿——名称复用 map_table 单源；R253 前缀消歧「祝」→「兆」）
	for cid: Variant in affixes.get("curses", []):
		rows.append(_make_daily_row("诅",
			Meta.affix_name(StringName(String(cid))), PopPalette.ENEMY))
	var bless: StringName = StringName(String(affixes.get("bless", "")))
	rows.append(_make_daily_row("兆", Meta.affix_name(bless), PopPalette.SUCCESS))
	# 当日最佳（daily_best：波次 + 击杀——独立口径不混常规记录）
	var best := Meta.daily_record(key)
	rows.append(_make_daily_row("最佳", "波次 %d · 击杀 %d" % [
		int(best.get("best_wave", 0)), int(best.get("best_kills", 0))], PopPalette.PLAYER))
	var note := Label.new()
	note.name = "DlyRow_%d" % _dly_row_seq
	_dly_row_seq += 1
	StickerTheme.label_sticker(note, 13, PopPalette.INK_SOFT)
	note.text = "%s · 锁定晴空草原 · 全玩家同日同词缀" % date_disp
	note.custom_minimum_size = Vector2(576.0, 24.0)
	note.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	note.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	rows.append(note)
	return rows


func _build_daily_go_button() -> Button:
	# R267 刀P3：出发按钮逐次新建（语义名 DailyStartButton 不入缓存白名单——
	# verify_feedback find_child 可达性断言锁名，保名优先于缓存）
	var go := Button.new()
	go.name = "DailyStartButton"
	go.text = "出发挑战"
	go.add_theme_font_size_override("font_size", 20)
	go.add_theme_font_override("font", StickerTheme.font_bold())
	go.custom_minimum_size = Vector2(240.0, 64.0)
	go.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	go.focus_mode = Control.FOCUS_NONE
	go.pressed.connect(_on_daily_start)
	go.button_down.connect(func() -> void: StickerTheme.press_punch(go))
	return go


func _make_daily_row(p_mark: String, p_text: String, p_color: Color) -> Control:
	# 每日挑战信息行：字标（诅/兆/最佳——R253 祝→兆消歧）+ 内容
	var row := Panel.new()
	row.name = "DlyRow_%d" % _dly_row_seq           # R267 刀P3：缓存行名标
	_dly_row_seq += 1
	row.add_theme_stylebox_override("panel", StickerTheme.panel_style(12.0, 2, false))
	row.custom_minimum_size = Vector2(576.0, 60.0)
	row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var mark := Label.new()
	StickerTheme.label_sticker(mark, 20, p_color, 0, Color.WHITE, true)
	mark.text = p_mark
	mark.position = Vector2(18.0, 15.0)
	mark.size = Vector2(60.0, 30.0)
	mark.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_child(mark)
	var text_l := Label.new()
	StickerTheme.label_sticker(text_l, 15, PopPalette.INK)
	text_l.text = p_text
	text_l.position = Vector2(86.0, 19.0)
	text_l.size = Vector2(470.0, 24.0)
	text_l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_child(text_l)
	return row


func _on_daily_start() -> void:
	# 出发挑战：关面板 → 申请启动（仲裁权在 GameLoop._on_menu_start_daily，E-16 同源）
	_panel_end_defer()        # R252D P6：落盘先于离菜单（每日出发行同 §4.4-1 口径）
	_close_panel_core()       # R260 评审 HIGH-1：出发直关=挂起标志随清（防回大厅双泵停摆）
	start_daily_requested.emit()


func _close_panel_core() -> void:
	# R260 评审 HIGH-1：绕过 _on_panel_close 的直关面板统一口（出发路径两口）——
	# 挂起标志不清则打完一局回大厅时双泵永久停摆（恢复唯一途径=再开面板手动关）
	_panel_root.visible = false
	_lobby_detail_open = false
	_panel_kind = ""


# ── 记录内容 ──────────────────────────────────────────────────────
func _rebuild_records() -> void:
	# R267 刀P3：同态直跳——行已按序挂树且指纹一致（纯读快照），显示态已等价，
	# 跳过回收+直挂整段（面板关→开同面板/同面板连按的主路径）
	if _rows_attached_in_order(_rec_rows_cache) and _records_fp() == _rec_fp:
		return
	_recycle_panel_rows()                   # R254-1：统一回收口（图鉴缓存行 detach 回缓存，其余照旧 free）
	# R267 刀P3：指纹比对复用——显示字段与上次重建一致（纯读快照）则整组行直挂，
	# 不符才全量重建（基线 5668µs/次开合 → 直挂量级）
	var fp := _records_fp()
	if _rec_rows_cache.is_empty() or fp != _rec_fp:
		_free_cached_rows(_rec_rows_cache)
		_rec_rows_cache = _build_records_rows()
		_rec_fp = fp
	for row_v: Variant in _rec_rows_cache:
		_panel_list.add_child(row_v)


func _records_fp() -> String:
	# R267 刀P3：记录面板指纹 = 显示字段全集（v3 评审⑴构造规矩）——五全局记录 +
	# 分图记录摘要（best_wave/endless_depth 决定星标/无尽位）+ 通关图数。摘要键序
	# 排序走 Array[String]（红线 4：StringName 排序静默无效）。
	var mk: Array[String] = []
	for k_v: Variant in Meta.map_records.keys():
		mk.append(String(k_v))
	mk.sort()
	var mrs := ""
	for k: String in mk:
		var mr: Dictionary = Meta.map_records.get(k, {})
		mrs += "%s:%d/%d;" % [k, int(mr.get("best_wave", 0)), int(mr.get("endless_depth", 0))]
	var ck: Array[String] = []
	for k_v: Variant in Meta.maps_cleared.keys():
		ck.append(String(k_v))
	ck.sort()
	return "%d|%d|%d|%d|%d|%s|%s" % [int(Meta.records["best_wave"]),
		int(Meta.records["best_kills"]), int(Meta.records["best_level"]),
		int(Meta.records["total_runs"]), int(Meta.records["total_kills"]),
		mrs, ",".join(ck)]


func _build_records_rows() -> Array:
	# R267 刀P3：记录行纯构建（原 _rebuild_records 主体不变，产出改入数组 + 名标）
	var lines := [
		["历史最高波次（全图）", "%d" % int(Meta.records["best_wave"])],
		["单局最高击杀", "%d" % int(Meta.records["best_kills"])],
		["单局最高等级", "%d" % int(Meta.records["best_level"])],
		["累计完成局数", "%d" % int(Meta.records["total_runs"])],
		["累计击杀", "%d" % int(Meta.records["total_kills"])],
		["· 分图最佳 ·", ""],
	]
	for i in range(MapTable.count()):
		var def := MapTable.MAPS[i]
		var mr: Dictionary = Meta.map_records.get(String(def.id), {})
		var depth := int(mr.get("endless_depth", 0))
		# E11 分档战绩：困/狱任一有记录 → 三档并列展示（一眼看到难度进度差）
		var mr_h: Dictionary = Meta.map_records.get(String(def.id) + "#1", {})
		var mr_l: Dictionary = Meta.map_records.get(String(def.id) + "#2", {})
		if mr_h.is_empty() and mr_l.is_empty():
			lines.append(["%s 最高波次" % String(def.name),
				"%d%s%s" % [int(mr.get("best_wave", 0)),
					" ★" if Meta.is_map_cleared_at(def.id, 0) else "",
					" · 无尽 %d" % depth if depth > 0 else ""]])
		else:
			# R245 星标分档：三列各挂各的星（普/困/狱独立判据——与选关面板同口径，
			# 旧 is_map_cleared 任意难度通关即真，会把困/狱通关错挂到普通列）
			lines.append(["%s 最高波次（普/困/狱）" % String(def.name),
				"%d%s / %d%s / %d%s" % [int(mr.get("best_wave", 0)),
					"★" if Meta.is_map_cleared_at(def.id, 0) else "",
					int(mr_h.get("best_wave", 0)),
					"★" if Meta.is_map_cleared_at(def.id, 1) else "",
					int(mr_l.get("best_wave", 0)),
					"★" if Meta.is_map_cleared_at(def.id, 2) else ""]])
	lines.append(["通关进度", "%d/%d 图" % [Meta.cleared_count(), MapTable.count()]])
	var rows: Array = []
	for l in lines:
		var row := Panel.new()
		row.name = "RecRow_%d" % _rec_row_seq           # R267 刀P3：缓存行名标
		_rec_row_seq += 1
		row.add_theme_stylebox_override("panel", StickerTheme.panel_style(12.0, 2, false))
		row.custom_minimum_size = Vector2(576.0, 56.0)
		row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		row.mouse_filter = Control.MOUSE_FILTER_IGNORE
		var name_l := Label.new()
		StickerTheme.label_sticker(name_l, 18, PopPalette.INK, 0, Color.WHITE, true)
		name_l.text = String(l[0])
		name_l.position = Vector2(24.0, 15.0)
		name_l.size = Vector2(300.0, 26.0)
		name_l.mouse_filter = Control.MOUSE_FILTER_IGNORE
		row.add_child(name_l)
		var val_l := Label.new()
		StickerTheme.label_sticker(val_l, 22, PopPalette.PLAYER, 0, Color.WHITE, true)
		val_l.text = String(l[1])
		val_l.position = Vector2(400.0, 13.0)
		val_l.size = Vector2(150.0, 30.0)
		val_l.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
		val_l.mouse_filter = Control.MOUSE_FILTER_IGNORE
		row.add_child(val_l)
		rows.append(row)
	return rows
