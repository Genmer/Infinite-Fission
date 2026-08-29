# scripts/meta/meta_manager.gd
# Meta 外部成长管理器（META_ROADMAP §1/§3 M4+M6 首批落地，用户反馈「大厅、图鉴、成就」）：
# · 图鉴：怪物（击杀解锁+累计计数）/ 武器（获得解锁）/ 词条（抽取解锁）——遇解锁口径。
# · 成就：定义表驱动（累计击杀 / 单局波次 / 单局等级 / 持有武器 / 单局词条 / 击败Boss /
#   完成局数），事件即时判定，解锁即存档。
# · 记录：历史最高（波次/击杀/单局等级）+ 累计（局数/击杀），GAME_OVER 结算落盘。
# 持久化：user://meta_save.cfg（ConfigFile 三段）；autoload 不声明 class_name（§九纪律）。
# 事件消费只读（enemy_killed 的敌人节点读 data.id / tags；card_chosen 读 kind——解锁写入
# 均在本管理器，零数值副作用）。
extends Node

signal codex_changed()                        # 图鉴解锁（大厅面板刷新用）
signal achievements_changed(ach_id: StringName)   # 成就解锁提示（大厅面板刷新用）

const SAVE_PATH := "user://meta_save.cfg"

# 成就定义表（id → {name, desc, type, target}；type: total_kills/run_wave/run_level/
# run_weapons_drawn/run_traits_drawn/boss_slain/total_runs）
const ACHIEVEMENTS: Array[Dictionary] = [
	{"id": &"first_blood", "name": "初次裂变", "desc": "累计击杀 1 只敌人", "type": "total_kills", "target": 1},
	{"id": &"kill_500", "name": "弹幕清道夫", "desc": "累计击杀 500 只敌人", "type": "total_kills", "target": 500},
	{"id": &"kill_2000", "name": "裂变风暴", "desc": "累计击杀 2000 只敌人", "type": "total_kills", "target": 2000},
	{"id": &"wave_10", "name": "站稳脚跟", "desc": "单局抵达第 10 波", "type": "run_wave", "target": 10},
	{"id": &"wave_20", "name": "深入敌阵", "desc": "单局抵达第 20 波", "type": "run_wave", "target": 20},
	{"id": &"wave_30", "name": "无尽之门", "desc": "单局抵达第 30 波", "type": "run_wave", "target": 30},
	{"id": &"level_15", "name": "成长曲线", "desc": "单局等级达到 15 级", "type": "run_level", "target": 15},
	{"id": &"weapons_3", "name": "军火大亨", "desc": "单局获得 2 把新武器（共持 3 把）", "type": "run_weapons_drawn", "target": 2},
	{"id": &"traits_8", "name": "词条收藏家", "desc": "单局获得 8 张词条卡", "type": "run_traits_drawn", "target": 8},
	{"id": &"boss_slay", "name": "屠戮聚合体", "desc": "击败首个 Boss", "type": "boss_slain", "target": 1},
	{"id": &"runs_10", "name": "不屈哨兵", "desc": "完成 10 局", "type": "total_runs", "target": 10},
]

# 运行期状态（存档落盘口径）
var codex_kills: Dictionary = {}              # enemy_id(String) → 累计击杀数
var codex_weapons: Dictionary = {}            # weapon_id(String) → true（获得解锁）
var codex_traits: Dictionary = {}             # trait_id(String) → true（抽取解锁）
var achievements_done: Dictionary = {}        # ach_id(String) → true
var records: Dictionary = {
	"best_wave": 0, "best_kills": 0, "best_level": 1,
	"total_runs": 0, "total_kills": 0,
}
# 单局计数（GAME_OVER 结算后清零）
var _run_kills: int = 0
var _run_max_wave: int = 0
var _run_max_level: int = 1
var _run_weapons_drawn: int = 0
var _run_traits_drawn: int = 0
var _run_boss_slain: int = 0


func _ready() -> void:
	_load()
	EventBus.enemy_killed.connect(_on_enemy_killed)
	EventBus.card_chosen.connect(_on_card_chosen)
	EventBus.wave_started.connect(_on_wave_started)
	EventBus.level_up.connect(_on_level_up)
	EventBus.state_changed.connect(_on_state_changed)


# ── 查询口（大厅 UI） ─────────────────────────────────────────────
func is_ach_done(p_id: StringName) -> bool:
	return achievements_done.has(String(p_id))


func achievement_count() -> Vector2i:
	# (已完成, 总数)
	var done := 0
	for a in ACHIEVEMENTS:
		if is_ach_done(a.id):
			done += 1
	return Vector2i(done, ACHIEVEMENTS.size())


func codex_kill_count(p_enemy_id: StringName) -> int:
	return int(codex_kills.get(String(p_enemy_id), 0))


func is_weapon_unlocked(p_id: StringName) -> bool:
	return codex_weapons.has(String(p_id))


func is_trait_unlocked(p_id: StringName) -> bool:
	return codex_traits.has(String(p_id))


# ── 事件消费 ──────────────────────────────────────────────────────
func _on_enemy_killed(p_enemy: Node2D) -> void:
	var data: Variant = p_enemy.get("data")
	var eid := StringName(str(data.get("id"))) if data != null else &""
	_run_kills += 1
	records["total_kills"] = int(records["total_kills"]) + 1
	if eid != &"":
		codex_kills[String(eid)] = codex_kill_count(eid) + 1
	if (int(p_enemy.get("tags")) & GameConst.TAG_BOSS) != 0:
		_run_boss_slain += 1
	_check_achievements()
	# 击杀侧不落盘（高频事件；计数随 GAME_OVER 结算统一落盘——防测试/高频帧 IO 风暴）


func _on_card_chosen(p_card_id: StringName, p_kind: int) -> void:
	# kind = CardGenerator.CardKind（1=TRAIT / 4=WEAPON；菜单图鉴解锁口径）
	match p_kind:
		4:
			if String(p_card_id) != "" and not codex_weapons.has(String(p_card_id)):
				codex_weapons[String(p_card_id)] = true
				_run_weapons_drawn += 1
				codex_changed.emit()
		1:
			if String(p_card_id) != "" and not codex_traits.has(String(p_card_id)):
				codex_traits[String(p_card_id)] = true
				_run_traits_drawn += 1
				codex_changed.emit()
	_check_achievements()
	_save()


func _on_wave_started(p_wave: int) -> void:
	_run_max_wave = maxi(_run_max_wave, p_wave)
	_check_achievements()


func _on_level_up(p_level: int) -> void:
	_run_max_level = maxi(_run_max_level, p_level)
	_check_achievements()


func _on_state_changed(p_state: int) -> void:
	if p_state != GameConst.GameStatus.GAME_OVER:
		return
	# 局结算：最高记录 + 局数 + 成就 + 落盘 + 单局计数复位
	records["best_wave"] = maxi(int(records["best_wave"]), _run_max_wave)
	records["best_kills"] = maxi(int(records["best_kills"]), _run_kills)
	records["best_level"] = maxi(int(records["best_level"]), _run_max_level)
	records["total_runs"] = int(records["total_runs"]) + 1
	_check_achievements()
	_save()
	_run_kills = 0
	_run_max_wave = 0
	_run_max_level = 1
	_run_weapons_drawn = 0
	_run_traits_drawn = 0
	_run_boss_slain = 0


func _check_achievements() -> void:
	var counters := {
		"total_kills": int(records["total_kills"]),
		"run_wave": _run_max_wave,
		"run_level": _run_max_level,
		"run_weapons_drawn": _run_weapons_drawn,
		"run_traits_drawn": _run_traits_drawn,
		"boss_slain": _run_boss_slain,
		"total_runs": int(records["total_runs"]),
	}
	for a in ACHIEVEMENTS:
		var aid := String(a.id)
		if achievements_done.has(aid):
			continue
		if int(counters.get(String(a.type), 0)) >= int(a.target):
			achievements_done[aid] = true
			achievements_changed.emit(a.id)
			_save()


# ── 持久化 ────────────────────────────────────────────────────────
func _save() -> void:
	var cfg := ConfigFile.new()
	cfg.set_value("codex", "kills", codex_kills)
	cfg.set_value("codex", "weapons", codex_weapons.keys())
	cfg.set_value("codex", "traits", codex_traits.keys())
	cfg.set_value("achievements", "done", achievements_done.keys())
	for key in records:
		cfg.set_value("records", key, records[key])
	cfg.save(SAVE_PATH)


func _load() -> void:
	var cfg := ConfigFile.new()
	if cfg.load(SAVE_PATH) != OK:
		return                                  # 首启无档（默认值起步）
	var kills: Variant = cfg.get_value("codex", "kills", {})
	if kills is Dictionary:
		codex_kills = kills
	for wid in cfg.get_value("codex", "weapons", []):
		codex_weapons[String(wid)] = true
	for tid in cfg.get_value("codex", "traits", []):
		codex_traits[String(tid)] = true
	for aid in cfg.get_value("achievements", "done", []):
		achievements_done[String(aid)] = true
	for key in records:
		records[key] = int(cfg.get_value("records", key, records[key]))
