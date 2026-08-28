# scripts/entities/wave/wave_director.gd
# M-04 WaveDirector（架构 §2.13）：波表驱动 + 公式 fallback + 窗口/清空/叠波调度 + 事件波。
# 数据源：WaveTableData（M-14 注入，表缺失/缺波 → 公式回退，E-08 降级不崩溃）。
# 事件波调度（A3 §2.4）：精英散布 {8,12,16,22,24,26,28}（fallback 常量）/ Boss 逢 10；
# 无尽段（w>30，A3 §2.6）：TP=110×1.03^(w−30)、窗口 min(30+0.2(w−30),40)、精英 w mod 4==0、Boss w mod 10==0。
# 编排说明（§2.17）：tick(game_delta) 由 GameLoop ⑥ 驱动；内部驱动 EnemySpawner 节流出队。
class_name WaveDirector
extends Node

var wave_table: WaveTableData = null          # M-14 注入（null → 公式 fallback）
var spawner: EnemySpawner = null
var registry: DataRegistry = null             # 注入（fallback 构成/敌人 id 解析）
var enemy_grid: SpaceGrid = null              # 注入（spawner.tick 转递；E-10 预留）
var current_wave: int = 0
var tp_budget: float = 0.0                    # TP = 14 + 3.2w（无尽段 110×1.03^(w−30)）
var window_left: float = 0.0                  # 18 + 0.4w（无尽段 min(30+0.2(w−30), 40)）
var buffer_left: float = 0.0                  # 波间缓冲 1s + loot_buffer 3s
var enemies_alive: int = 0
var wave_first_kill_done: bool = false        # SYN_FIRST_STRIKE 重置位

enum WavePhase { IDLE, SPAWNING, CLEARING, BUFFER }

var _phase: int = WavePhase.IDLE
var _wave_elapsed: float = 0.0
var _hard_cap_left: float = 0.0
var _boss_wave: bool = false
var _trickle_left: float = 0.0
var _escort_interval: float = BOSS_TRICKLE_INTERVAL   # 本波伴随怪节奏（start_wave 解析）
var _escort_cap: int = BOSS_TRICKLE_CAP
var _escort_mix: Array[EnemyData] = []                # 本波伴随敌池（空 = 最便宜敌 fallback）
var _escort_cursor: int = 0                           # 混合轮转游标（确定性）

const HARD_CAP_BONUS := 8.0                   # wave_hard_cap = spawn_window + 8s（A3 §1.3）
const INTER_WAVE_BUFFER := 1.0                # 波间缓冲 1s
const LOOT_BUFFER := 3.0                       # 全清后拾取缓冲 3s
const BOSS_TRICKLE_INTERVAL := 2.5             # Boss 伴随怪节奏 fallback（A3 §2.4 w10 行：×1/2.5s 场上≤12）
const BOSS_TRICKLE_CAP := 12
# Boss 波伴随怪分波节奏（包 4 遗留项；真源 A3 §2.4 波表行原文：w10「Boss1+G×1/2.5s（场上≤12）」、
# w20「Boss2+R×1/2.5s（场上≤12）」、w30「Boss3+混合怪×1/2s（场上≤14）」；无尽段 Boss（w>30）沿用 w30。
# 敌种按波表 composition 首现序的基础敌池驱动（_base_enemy_pool）；表缺/池空 → 最便宜敌 fallback
#（行为与 pkg2 冻结用例一致）。
const ESCORT_RUNNER_WAVE := 20                # w20 起：伴 R（波表基础敌池第 2 首现敌）
const ESCORT_MIX_WAVE := 30                   # w30 起：混合怪 ×1/2s 场上≤14
const ESCORT_MIX_INTERVAL := 2.0
const ESCORT_MIX_CAP := 14
const ELITE_SCATTER: Array[int] = [8, 12, 16, 22, 24, 26, 28]   # A3 §2.4 精英散布（fallback）
const TP_FALLBACK := {"base": 14.0, "slope": 3.2, "elite_wave_mult": 1.25}   # A3 §1.4
const ENDLESS_FALLBACK := {
	"tp_base": 110.0, "tp_growth": 1.03, "window_base": 30.0, "window_slope": 0.2,
	"window_cap": 40.0, "elite_mod": 4, "boss_mod": 10,
}


func _ready() -> void:
	EventBus.enemy_killed.connect(_on_enemy_killed_event)


func start_wave(p_wave: int) -> void:
	# 读表/公式生成构成 → enqueue → 波窗口/硬上限计时 → wave_started 事件
	current_wave = p_wave
	wave_first_kill_done = false
	_boss_wave = _is_boss_wave(p_wave)
	var rhythm := _escort_rhythm(p_wave)
	_escort_interval = float(rhythm["interval"])
	_escort_cap = int(rhythm["cap"])
	_escort_mix.clear()
	_escort_mix.assign(rhythm["mix"])            # assign 搬运（Dictionary 取出为 untyped Array）
	_escort_cursor = 0
	tp_budget = _tp_for_wave(p_wave)
	window_left = _window_for_wave(p_wave)
	_wave_elapsed = 0.0
	_hard_cap_left = window_left + HARD_CAP_BONUS
	_trickle_left = _escort_interval
	_phase = WavePhase.SPAWNING
	if spawner != null:
		var composition := _roll_composition(p_wave)
		for entry in composition:
			spawner.enqueue(entry)
		if _boss_wave:
			_spawn_boss(p_wave)
	EventBus.emit_wave_started(p_wave)
	# F-19：w21 保底解锁武器槽5（Boss2 未击杀兜底；玩家侧 unlock_slot 幂等）
	if p_wave >= 21:
		EventBus.emit_slot_unlocked(5)


func tick(p_game_delta: float) -> void:
	# 窗口计时 → 硬上限强制叠波 → Boss 伴随怪流水 → 清空检测 → wave_cleared → 缓冲 → 下一波
	if spawner == null:
		return
	enemies_alive = spawner.active_count()
	match _phase:
		WavePhase.SPAWNING, WavePhase.CLEARING:
			_wave_elapsed += p_game_delta
			_hard_cap_left -= p_game_delta
			spawner.tick(p_game_delta, enemy_grid)
			window_left -= p_game_delta
			if window_left <= 0.0:
				window_left = 0.0
				_phase = WavePhase.CLEARING
			# Boss 波伴随怪持续刷（Boss 存活期间流水；节奏/上限/敌种按波分波驱动，A3 §2.4）
			if _boss_wave:
				_trickle_left -= p_game_delta
				if _trickle_left <= 0.0 and spawner.active_count() < _escort_cap:
					var companion := _next_companion()
					if companion != null:
						spawner.enqueue({"data_id": companion.id, "wave": current_wave, "tags": 0})
					_trickle_left = _escort_interval
			# 硬上限：到时未清完强制叠波（压力叠加，不清场直接开下一波）
			if _hard_cap_left <= 0.0:
				start_wave(current_wave + 1)
				return
			# 清空检测：窗口结束 + 队列排空 + 场上清空
			if _phase == WavePhase.CLEARING and spawner.queue_empty() and spawner.active_count() == 0:
				EventBus.emit_wave_cleared(current_wave)
				# F-19：w3 波后解锁槽2 / w7 波后解锁槽3
				if current_wave == 3:
					EventBus.emit_slot_unlocked(2)
				elif current_wave == 7:
					EventBus.emit_slot_unlocked(3)
				buffer_left = INTER_WAVE_BUFFER + LOOT_BUFFER
				_phase = WavePhase.BUFFER
		WavePhase.BUFFER:
			buffer_left -= p_game_delta
			if buffer_left <= 0.0:
				start_wave(current_wave + 1)
		_:
			pass


func on_enemy_killed(p_enemy: Node2D) -> void:
	# 存活计数由 tick 从 spawner 刷新（无漂移）；Boss 掉落武器槽（F-19）；首杀位重置
	if not wave_first_kill_done:
		wave_first_kill_done = true
	var enemy_tags := int(p_enemy.get("tags"))
	if (enemy_tags & GameConst.TAG_BOSS) != 0:
		if current_wave >= 20:
			EventBus.emit_slot_unlocked(5)      # Boss2 击杀提前解锁（F-19）
		elif current_wave >= 10:
			EventBus.emit_slot_unlocked(4)      # Boss1 掉落武器槽4（F-19）


func _on_enemy_killed_event(p_enemy: Node2D) -> void:
	on_enemy_killed(p_enemy)


func _roll_composition(p_wave: int) -> Array[Dictionary]:
	# 表驱动优先，表缺失回退公式（TP 逐类扣减）；返回逐敌生成请求数组
	var out: Array[Dictionary] = []
	var entry := _table_entry(p_wave)
	if entry != null:
		for comp in entry.composition:
			var id := StringName(String(comp.get("enemy_id", "")))
			var count := int(comp.get("count", 0))
			var tags := int(comp.get("tags", 0))
			for i in range(count):
				out.append({"data_id": id, "wave": p_wave, "tags": tags})
		return out
	# —— 公式 fallback：最便宜敌填满 TP 预算（floor 扣减）；Boss 波伴随怪由 tick 流水补 ——
	if _boss_wave:
		return out
	var cheapest := _cheapest_enemy()
	if cheapest == null:
		push_warning("[WaveDirector] 注册表无敌人数据，波 %d 公式构成为空（降级不崩溃）" % p_wave)
		return out
	var count := int(tp_budget / maxf(cheapest.tp_cost, 0.01))
	for i in range(count):
		out.append({"data_id": cheapest.id, "wave": p_wave, "tags": 0})
	# 精英散布（fallback 按 A3 §2.4 常量集；精英模板乘区在 Enemy.spawn 生效）
	if _is_elite_wave(p_wave):
		out.append({"data_id": cheapest.id, "wave": p_wave, "tags": GameConst.TAG_ELITE})
	return out


func _tp_for_wave(p_wave: int) -> float:
	# 波威胁预算：表 tp_override 优先 → 公式（14+3.2w；精英波 ×1.25）→ 无尽段 110×1.03^(w−30)
	var entry := _table_entry(p_wave)
	if entry != null and entry.tp_override > 0.0:
		return entry.tp_override
	var base := float(TP_FALLBACK["base"])
	var slope := float(TP_FALLBACK["slope"])
	var elite_mult := float(TP_FALLBACK["elite_wave_mult"])
	if wave_table != null and not wave_table.tp_formula.is_empty():
		base = float(wave_table.tp_formula.get("base", base))
		slope = float(wave_table.tp_formula.get("slope", slope))
		elite_mult = float(wave_table.tp_formula.get("elite_wave_mult", elite_mult))
	if p_wave > 30:
		var endless := _endless_params(p_wave)
		return float(endless["tp_base"]) * pow(float(endless["tp_growth"]), float(p_wave - 30))
	var tp := base + slope * float(p_wave)
	if _is_elite_wave(p_wave):
		tp *= elite_mult                     # 含精英的波 ×1.25（A3 §1.4）
	return tp


func _window_for_wave(p_wave: int) -> float:
	# 波窗口：表 window 优先 → 18+0.4w → 无尽段 min(30+0.2(w−30), 40)
	var entry := _table_entry(p_wave)
	if entry != null and entry.window > 0.0:
		return entry.window
	if p_wave > 30:
		var endless := _endless_params(p_wave)
		return minf(float(endless["window_base"]) + float(endless["window_slope"]) * float(p_wave - 30),
			float(endless["window_cap"]))
	return 18.0 + 0.4 * float(p_wave)


func _endless_params(p_wave: int) -> Dictionary:
	# 无尽段参数（w>30；A3 §2.6）：表 endless 覆写 fallback 常量
	var endless := ENDLESS_FALLBACK.duplicate()
	if wave_table != null and not wave_table.endless.is_empty():
		for key in wave_table.endless:
			endless[key] = wave_table.endless[key]
	return endless


func _is_boss_wave(p_wave: int) -> bool:
	# Boss 逢 10：表 events 含 BOSS 标记优先；表缺波/无表 → w mod 10 == 0
	var entry := _table_entry(p_wave)
	if entry != null:
		return entry.events.has(&"BOSS")
	return p_wave > 0 and p_wave % 10 == 0


func _is_elite_wave(p_wave: int) -> bool:
	# 精英散布：表驱动时由表构成承载（此处不判）；fallback 按 A3 §2.4 集合 / 无尽段 w mod 4==0
	if _table_entry(p_wave) != null:
		return false
	if p_wave > 30:
		var elite_mod := int(ENDLESS_FALLBACK["elite_mod"])
		if wave_table != null and not wave_table.endless.is_empty():
			elite_mod = int(wave_table.endless.get("elite_mod", elite_mod))
		return p_wave % elite_mod == 0 and not _is_boss_wave(p_wave)
	return ELITE_SCATTER.has(p_wave)


func _table_entry(p_wave: int) -> WaveEntryData:
	# 波表条目（缺失 → null → 调用方走公式 fallback；剔除波同口径，E-08）
	if wave_table == null:
		return null
	for entry in wave_table.entries:
		if entry.index == p_wave:
			return entry
	return null


func _escort_rhythm(p_wave: int) -> Dictionary:
	# Boss 波伴随怪节奏（分波驱动；真源 A3 §2.4 波表三行，见常量块注释）。
	# 敌种：波表基础敌池切片；表缺/池空 → mix 空 → _next_companion 走最便宜敌 fallback（pkg2 兼容）。
	var pool := _base_enemy_pool()
	if pool.is_empty():
		return {"interval": BOSS_TRICKLE_INTERVAL, "cap": BOSS_TRICKLE_CAP, "mix": []}
	if p_wave >= ESCORT_MIX_WAVE:
		# w30+（含无尽 Boss）：混合怪 ×1/2s 场上≤14（全池轮转）
		return {"interval": ESCORT_MIX_INTERVAL, "cap": ESCORT_MIX_CAP, "mix": pool}
	if p_wave >= ESCORT_RUNNER_WAVE:
		# w20~29：伴 R（波表基础敌池第 2 首现敌 = 疾冲者；池不足 2 种时取末位）×1/2.5s ≤12
		return {"interval": BOSS_TRICKLE_INTERVAL, "cap": BOSS_TRICKLE_CAP,
			"mix": [pool[mini(1, pool.size() - 1)]]}
	# w10~19（及其它 Boss 波）：伴 G（池首个基础敌）×1/2.5s ≤12
	return {"interval": BOSS_TRICKLE_INTERVAL, "cap": BOSS_TRICKLE_CAP, "mix": [pool[0]]}


func _base_enemy_pool() -> Array[EnemyData]:
	# 波表 composition 首现序的基础敌池（排除 Boss / 精英模板敌；悬空 id 跳过）
	var out: Array[EnemyData] = []
	if wave_table == null or registry == null:
		return out
	var seen: Dictionary = {}
	var entries: Array = wave_table.entries.duplicate()
	entries.sort_custom(func(a: WaveEntryData, b: WaveEntryData) -> bool: return a.index < b.index)
	for entry in entries:
		for comp in entry.composition:
			var id := StringName(String(comp.get("enemy_id", "")))
			if seen.has(id):
				continue
			seen[id] = true
			var e := registry.get_enemy(id)
			if e == null or (e.tags & GameConst.TAG_BOSS) != 0:
				continue
			if not e.elite_mult.is_empty():
				continue                       # 精英模板敌不入伴随池（A3 波表伴随仅基础怪）
			out.append(e)
	return out


func _next_companion() -> EnemyData:
	# 伴随怪选取：mix 池轮转（混合怪/单一种类）；池空 → 最便宜敌 fallback（pkg2 冻结行为）
	if not _escort_mix.is_empty():
		var e := _escort_mix[_escort_cursor % _escort_mix.size()]
		_escort_cursor += 1
		return e
	return _cheapest_enemy()


func _cheapest_enemy() -> EnemyData:
	# 注册表内 tp_cost 最低敌人（同价按 id 排序——确定性）
	if registry == null:
		return null
	var best: EnemyData = null
	for id in registry.enemies:
		var e: EnemyData = registry.enemies[id]
		if e == null or e.tp_cost <= 0.0:
			continue
		if best == null or e.tp_cost < best.tp_cost or (e.tp_cost == best.tp_cost and String(e.id) < String(best.id)):
			best = e
	return best


func _spawn_boss(p_wave: int) -> void:
	# Boss 波：Boss 入列（boss_spawned 事件由 spawner 实际生成时派发）
	var boss := _find_boss_data(p_wave)
	if boss == null:
		push_warning("[WaveDirector] Boss 数据缺失（波 %d）：降级为伴随怪流水波" % p_wave)
		return
	var size := Vector2(720.0, 1280.0)
	if GameConfig.balance != null:
		size = Vector2(GameConfig.balance.res_logic)
	spawner.enqueue({
		"data_id": boss.id,
		"wave": p_wave,
		"tags": boss.tags | GameConst.TAG_BOSS,
		"pos": Vector2(size.x * 0.5, size.y * 0.12),
	})


func _find_boss_data(p_wave: int) -> EnemyData:
	# Boss 数据选取：TAG_BOSS 敌按 id 排序，逢 10 轮换（10→首、20→次、30→三）
	if registry == null:
		return null
	var bosses: Array[EnemyData] = []
	for id in registry.enemies:
		var e: EnemyData = registry.enemies[id]
		if e != null and (e.tags & GameConst.TAG_BOSS) != 0:
			bosses.append(e)
	if bosses.is_empty():
		return null
	bosses.sort_custom(func(a: EnemyData, b: EnemyData) -> bool: return String(a.id) < String(b.id))
	var slot := (p_wave / 10 - 1) % bosses.size()
	return bosses[slot]
