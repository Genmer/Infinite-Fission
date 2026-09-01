# scripts/loop/meta_store.gd
# v1.0.0 MetaStore（A9 局外成长）：结晶货币 + 五条目强化等级 + 累计战绩的存档层。
# · 持久化：ConfigFile @ user://meta_save.cfg（SAVE_VERSION=1；损坏判定树见 load_save——
#   任何回退路径【不写回】，缺档/缺键静默或告警后按默认继续）。
# · 消费四通道（GameLoop 接线，A9 §3）：
#   ① hpg → CurseHandler.meta_hp_flat（recompute_max_hp prescale，run 开始注入）
#   ② atk/greed → ChipHandler.meta_stats（stat_bonus 赐福段之后加和，meta_stats_snapshot 只含
#     此二键——xp/seed/hpg 各走独立通道防双算）
#   ③ seed_gold → GameLoop._reset_run_state 直注入 gold（★不经 _add_gold，greed 不放大开局金）
#   ④ xp → GameLoop xp 链第 4 因子（meta_store.xp_mult）
# · 定价：100 起逐级 ×1.6 后 round（★逐级迭代，非 pow 一次算——round(655.36)=655≠冻结 656）。
# · 结转：GameLoop._settle_run（死亡一次闸）→ add_crystal(本局金币) + record_run + save。
class_name MetaStore
extends Node

const SAVE_VERSION: int = 1
const DEFAULT_SAVE_PATH: String = "user://meta_save.cfg"
const BASE_PRICE: int = 100                    # 全条目首级定价
const PRICE_GROWTH: float = 1.6                # 逐级复利系数（逐级 round，非 pow）
const START_GOLD_PER_LEVEL: int = 25           # seed_gold 每级开局金

# 五条目封闭表（行序 = MetaPanel 行序 = 存档 levels 键序；新增条目 = 表尾追加，旧档缺键 → 0）
const UPGRADES: Dictionary = {
	&"hpg": {"display": "生命强化", "max_level": 5, "per_level": 5.0, "effect_text": "最大生命 +5/级"},
	&"atk": {"display": "攻击强化", "max_level": 5, "per_level": 0.03, "effect_text": "攻击 +3%/级"},
	&"greed": {"display": "贪婪", "max_level": 5, "per_level": 0.05, "effect_text": "金币获取 +5%/级"},
	&"seed_gold": {"display": "启动资金", "max_level": 3, "per_level": 25.0, "effect_text": "开局携带 +25/级"},
	&"xp": {"display": "经验强化", "max_level": 5, "per_level": 0.05, "effect_text": "经验获取 +5%/级"},
}

var crystal: int = 0                           # 结晶余额（局外货币；购买扣减 / 死亡结转增加）
var total_runs: int = 0                        # 总局数（仅死亡结算计，A9 假设清单）
var total_kills: int = 0                       # 累计击杀
var best_wave: int = 0                         # 最佳波次（单调不回退）
var _levels: Dictionary = {}                   # {StringName id: int 等级}（键域 = UPGRADES 封闭表）
var _save_path: String = DEFAULT_SAVE_PATH     # 存档路径（测试可注入 set_save_path）


func _init() -> void:
	_reset_memory()


func set_save_path(p_path: String) -> void:
	# 测试/多档位注入：切路径 + 内存复位全默认（读档由 load_save 显式承担，不自动加载）
	_save_path = p_path
	_reset_memory()


func load_save() -> void:
	# 损坏判定树（A9 冻结）：FileAccess/cfg.load ERR_FILE_NOT_FOUND → 静默默认；其他错误 →
	# warning + 默认；save_version 缺失 → warning 按 1 继续；>SAVE_VERSION → warning 全默认
	# 不降读；<1 → 损坏默认；crystal 缺失 → 0+warning、负 → 钳 0+warning；levels 逐条目
	# 缺失 → 0、越界 → clampi(0,max_level)+warning；stats 三键同规则。任何回退【不写回】。
	_reset_memory()
	var cfg := ConfigFile.new()
	var err := cfg.load(_save_path)
	if err == ERR_FILE_NOT_FOUND:
		return                                  # 无档（首次运行）：静默默认
	if err != OK:
		push_warning("[MetaStore] 存档读取失败（err=%d），按全默认继续" % err)
		return
	if not cfg.has_section_key("meta", "save_version"):
		push_warning("[MetaStore] 存档缺 save_version，按 1 继续")
	else:
		var version := _int_or(cfg.get_value("meta", "save_version", SAVE_VERSION),
			SAVE_VERSION, "save_version")
		if version > SAVE_VERSION:
			push_warning("[MetaStore] 存档版本 %d 高于当前 %d，拒绝降读，按全默认继续"
				% [version, SAVE_VERSION])
			return
		if version < 1:
			push_warning("[MetaStore] 存档版本非法（%d），按损坏处理全默认" % version)
			return
	if not cfg.has_section_key("meta", "crystal"):
		push_warning("[MetaStore] 存档缺 crystal，按 0 继续")
	else:
		var stored_crystal := _int_or(cfg.get_value("meta", "crystal", 0), 0, "crystal")
		if stored_crystal < 0:
			push_warning("[MetaStore] crystal 负值（%d），钳 0" % stored_crystal)
		else:
			crystal = stored_crystal
	for id in UPGRADES:
		var max_level := _max_level_of(id)
		if not cfg.has_section_key("levels", String(id)):
			_levels[id] = 0                     # 缺失（旧档/新增条目）→ 0
			continue
		var raw := _int_or(cfg.get_value("levels", String(id), 0), 0, String(id))
		if raw < 0 or raw > max_level:
			push_warning("[MetaStore] 等级越界（%s=%d），钳 [0,%d]" % [String(id), raw, max_level])
			_levels[id] = clampi(raw, 0, max_level)
		else:
			_levels[id] = raw
	total_runs = _load_stat(cfg, "total_runs")
	total_kills = _load_stat(cfg, "total_kills")
	best_wave = _load_stat(cfg, "best_wave")


func save() -> bool:
	# 写档（失败 push_warning + false；内存态保留——读写路径解耦）。键布局冻结：
	# [meta] save_version/crystal；[levels] String(id) 五键；[stats] total_runs/total_kills/best_wave
	var cfg := ConfigFile.new()
	cfg.set_value("meta", "save_version", SAVE_VERSION)
	cfg.set_value("meta", "crystal", crystal)
	for id in UPGRADES:
		cfg.set_value("levels", String(id), level(id))
	cfg.set_value("stats", "total_runs", total_runs)
	cfg.set_value("stats", "total_kills", total_kills)
	cfg.set_value("stats", "best_wave", best_wave)
	var err := cfg.save(_save_path)
	if err != OK:
		push_warning("[MetaStore] 存档写入失败（err=%d），内存态保留" % err)
		return false
	return true


func wipe() -> void:
	# 内存全默认 + 删除存档文件（本无档静默——DirAccess.remove_absolute 对不存在文件在
	# macOS 返回 FAILED 而非 ERR_FILE_NOT_FOUND，先做 file_exists 预检保证「无档 = 删除
	# 语义已达」路径恒静默；ERR_FILE_NOT_FOUND 双保险）
	_reset_memory()
	if not FileAccess.file_exists(_save_path):
		return
	var err := DirAccess.remove_absolute(ProjectSettings.globalize_path(_save_path))
	if err != OK and err != ERR_FILE_NOT_FOUND:
		push_warning("[MetaStore] 存档删除失败（err=%d）" % err)


# ── 购买 / 查询 ───────────────────────────────────────────────────
func purchase(p_id: StringName) -> bool:
	# 购买仲裁：未知 id / 满级 / 余额不足 → false + push_warning（不扣款）；
	# 成功 → 扣款 + 升级 + save（失败仅告警，内存升级态保留）→ true
	if not UPGRADES.has(p_id):
		push_warning("[MetaStore] 购买拒绝：未知条目（%s）" % String(p_id))
		return false
	var cost := price(p_id)
	if cost < 0:
		push_warning("[MetaStore] 购买拒绝：已满级（%s）" % String(p_id))
		return false
	if crystal < cost:
		push_warning("[MetaStore] 购买拒绝：结晶不足（需 %d，有 %d）" % [cost, crystal])
		return false
	crystal -= cost
	_levels[p_id] = level(p_id) + 1
	save()                                      # 失败仅告警（save 内 push_warning）
	return true


func level(p_id: StringName) -> int:
	# 当前等级（未知 id → 0）
	if not UPGRADES.has(p_id):
		return 0
	return int(_levels.get(p_id, 0))


func price(p_id: StringName) -> int:
	# 下一级定价：100 起逐级 ×1.6 后 round（★逐级迭代——非 pow 一次算，
	# round(100×1.6^4)=round(655.36)=655 ≠ 冻结序列 656）。满级 / 未知 id → -1。
	if not UPGRADES.has(p_id):
		return -1
	var lv := level(p_id)
	if lv >= _max_level_of(p_id):
		return -1
	var p := BASE_PRICE
	for i in range(lv):
		p = int(round(float(p) * PRICE_GROWTH))
	return p


func is_maxed(p_id: StringName) -> bool:
	# 满级判定（未知 id → true，无可购语义）
	if not UPGRADES.has(p_id):
		return true
	return level(p_id) >= _max_level_of(p_id)


# ── 四通道查询（A9 §3） ───────────────────────────────────────────
func starting_gold() -> int:
	# ③ 开局金（GameLoop 直注入，不经 _add_gold）
	return START_GOLD_PER_LEVEL * level(&"seed_gold")


func xp_mult() -> float:
	# ④ 经验第 4 因子（与芯片 xp_gain 分立防双算）
	return 1.0 + 0.05 * float(level(&"xp"))


func meta_hp_flat() -> float:
	# ① 生命 flat（CurseHandler.meta_hp_flat 通道）
	return 5.0 * float(level(&"hpg"))


func meta_stats_snapshot() -> Dictionary:
	# ② 芯片消费段快照：仅 atk/greed 二键（xp/seed/hpg 不入——防双算，A9 §3）
	return {
		&"atk_pct": 0.03 * float(level(&"atk")),
		&"gold_gain": 0.05 * float(level(&"greed")),
	}


# ── 结转 / 汇总 ───────────────────────────────────────────────────
func add_crystal(p_amount: int) -> void:
	crystal += maxi(p_amount, 0)                # 负值钳 0（防御）


func record_run(p_kills: int, p_wave: int) -> void:
	# 局战绩结转（总局数仅死亡计；kills/wave 负值钳 0；best_wave 单调不回退）
	total_runs += 1
	total_kills += maxi(p_kills, 0)
	best_wave = maxi(best_wave, maxi(p_wave, 0))


func meta_summary() -> Dictionary:
	# 菜单统计行四值（MenuScreen.set_meta_summary 消费）
	return {
		"best_wave": best_wave,
		"total_runs": total_runs,
		"total_kills": total_kills,
		"crystal": crystal,
	}


# ── 内部 ──────────────────────────────────────────────────────────
static func _int_or(p_value: Variant, p_default: int, p_key: String) -> int:
	# v1.3.0（R4）档内数值键类型守卫：TYPE_INT 直用；TYPE_FLOAT 且为整数值且 |v|<2^53
	#（IEEE 安全整数域）→ int；其余脏型（字符串/数组等）→ push_warning + p_default
	# 单键回退——不整档作废、不写回（与损坏判定树「全回退不写回」口径一致）
	if typeof(p_value) == TYPE_INT:
		return int(p_value)
	if typeof(p_value) == TYPE_FLOAT:
		var f := float(p_value)
		if f == floorf(f) and absf(f) < 9007199254740992.0:
			return int(f)
	push_warning("[MetaStore] 数值键类型异常（%s=%s），按默认 %d 继续"
		% [p_key, str(p_value), p_default])
	return p_default


func _reset_memory() -> void:
	# 内存态全默认（set_save_path / load_save 入口 / wipe 共用）
	crystal = 0
	total_runs = 0
	total_kills = 0
	best_wave = 0
	for id in UPGRADES:
		_levels[id] = 0


func _max_level_of(p_id: StringName) -> int:
	# 条目等级上限（封闭表；未知 id → 0）
	if not UPGRADES.has(p_id):
		return 0
	return int((UPGRADES[p_id] as Dictionary).get("max_level", 0))


func _load_stat(p_cfg: ConfigFile, p_key: String) -> int:
	# stats 三键读取（缺失 → 0 静默；负值 → 钳 0 + warning——同 levels 缺失/越界口径）
	if not p_cfg.has_section_key("stats", p_key):
		return 0
	var v := _int_or(p_cfg.get_value("stats", p_key, 0), 0, p_key)
	if v < 0:
		push_warning("[MetaStore] 统计 %s 负值（%d），钳 0" % [p_key, v])
		return 0
	return v
