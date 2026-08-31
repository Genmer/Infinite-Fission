# scripts/core/data/data_registry.gd
# M-14 DataRegistry：目录扫描 / 按 ID 索引 / 注入（架构 §2.6/§六.2）。
# 启动期一次性加载（运行期零 .tres 加载，E-08）；坏数据剔除 + 错误清单（文件名+字段名），
# 降级不崩溃；加载完成 emit data_validated（DebugStats/控制台消费）。
class_name DataRegistry
extends RefCounted

var weapons: Dictionary = {}                  # StringName(id) -> WeaponData
var enemies: Dictionary = {}                  # StringName(id) -> EnemyData
var traits: Dictionary = {}                   # StringName(id) -> TraitData
var relics: Dictionary = {}
var synergies: Dictionary = {}
var chips: Dictionary = {}                    # v0.7.0：StringName(id) -> ChipData
var wave_table: WaveTableData = null
var game_feel: GameFeelConfig = null
var report: Dictionary = {}                   # 校验报告（剔除清单 + 错误明细）

# id → 文件路径溯源（错误清单含文件名，AC-13.2/13.3；键 "category/id"）
var _sources: Dictionary = {}


func load_all(manifest: String) -> float:
	# 按 manifest.cfg 顺序扫描目录加载；返回耗时秒（AC-13.4）。
	# 目录缺失 → 告警跳过（降级不崩溃，§六.2）。
	var t0 := Time.get_ticks_usec()
	var cfg := ConfigFile.new()
	if cfg.load(manifest) != OK:
		push_warning("[DataRegistry] manifest 缺失（%s）：无内容数据可加载" % manifest)
	_scan_category(&"weapons", cfg, "weapons", WeaponData, weapons)
	_scan_category(&"enemies", cfg, "enemies", EnemyData, enemies)
	_scan_category(&"traits", cfg, "traits", TraitData, traits)
	_scan_category(&"relics", cfg, "relics", RelicData, relics)
	_scan_category(&"synergies", cfg, "synergies", SynergyRuleData, synergies)
	_scan_category(&"chips", cfg, "chips", ChipData, chips)   # v0.7.0：芯片类目
	_scan_single(&"wave_table", cfg, "waves", WaveTableData)
	_scan_single(&"game_feel", cfg, "gamefeel", GameFeelConfig)
	_validate_and_report()
	return float(Time.get_ticks_usec() - t0) / 1000000.0


func get_weapon(id: StringName) -> WeaponData:
	# 未命中返回 null（调用方 fail-fast）
	return weapons.get(id)


func get_trait(id: StringName) -> TraitData:
	return traits.get(id)


func get_enemy(id: StringName) -> EnemyData:
	return enemies.get(id)


func get_relic(id: StringName) -> RelicData:
	return relics.get(id)


func get_synergy(id: StringName) -> SynergyRuleData:
	return synergies.get(id)


func get_chip(id: StringName) -> ChipData:
	# v0.7.0：芯片查询（未命中返回 null，调用方 fail-fast）
	return chips.get(id)


func get_wave_table() -> WaveTableData:
	return wave_table


func get_game_feel() -> GameFeelConfig:
	return game_feel


func get_source(category: StringName, id: StringName) -> String:
	# 错误清单溯源：条目来源文件（内存构造/未溯源 → "<memory>"）
	return String(_sources.get("%s/%s" % [category, id], "<memory>"))


func trait_ids_by_pool(pool: int) -> Array[StringName]:
	# 卡池构成 roll 的数据源（按 PoolClass 过滤）
	var out: Array[StringName] = []
	for id in traits:
		var t: TraitData = traits[id]
		if t.pool == pool:
			out.append(id)
	return out


# ── 内部 ──────────────────────────────────────────────────────────
func _scan_category(category: StringName, cfg: ConfigFile, manifest_key: String, expected: Script, table: Dictionary) -> void:
	# 目录扫描 → 类型检查 → id 唯一性（重复 → 后者剔除）→ 入表
	var dir_path := String(cfg.get_value("directories", manifest_key, ""))
	if dir_path == "":
		push_warning("[DataRegistry] manifest 未声明 %s 目录（跳过）" % manifest_key)
		return
	if not DirAccess.dir_exists_absolute(dir_path):
		push_warning("[DataRegistry] 数据目录缺失（跳过）：%s" % dir_path)
		return
	var files := DirAccess.get_files_at(dir_path)
	files.sort()   # 文件名序 = 确定性加载顺序
	for file_name in files:
		if not String(file_name).ends_with(".tres"):
			continue
		var path := dir_path + "/" + String(file_name)
		var res: Resource = load(path)
		if res == null or res.get_script() != expected:
			push_warning("[DataRegistry] 类型不符（剔除）：%s 期望 %s" % [path, expected.resource_path])
			continue
		var rid: StringName = res.get("id")
		if rid == &"":
			push_warning("[DataRegistry] id 为空（剔除）：%s" % path)
			continue
		if table.has(rid):
			# §三.1：非空、全局唯一；重复 → 后者剔除
			push_warning("[DataRegistry] id 重复（后者剔除）：%s ← %s" % [rid, path])
			continue
		table[rid] = res
		_sources["%s/%s" % [category, rid]] = path


func _scan_single(category: StringName, cfg: ConfigFile, manifest_key: String, expected: Script) -> void:
	# 单件类目（波表 / GameFeel）：首个有效件胜出，多余件告警剔除
	var dir_path := String(cfg.get_value("directories", manifest_key, ""))
	if dir_path == "":
		push_warning("[DataRegistry] manifest 未声明 %s 目录（跳过）" % manifest_key)
		return
	if not DirAccess.dir_exists_absolute(dir_path):
		push_warning("[DataRegistry] 数据目录缺失（跳过）：%s" % dir_path)
		return
	var files := DirAccess.get_files_at(dir_path)
	files.sort()
	for file_name in files:
		if not String(file_name).ends_with(".tres"):
			continue
		var path := dir_path + "/" + String(file_name)
		var res: Resource = load(path)
		if res == null or res.get_script() != expected:
			push_warning("[DataRegistry] 类型不符（剔除）：%s 期望 %s" % [path, expected.resource_path])
			continue
		if category == &"wave_table":
			if wave_table != null:
				push_warning("[DataRegistry] 多余波表（后者剔除）：%s" % path)
				continue
			wave_table = res
		else:
			if game_feel != null:
				push_warning("[DataRegistry] 多余 GameFeel 配置（后者剔除）：%s" % path)
				continue
			game_feel = res
		var rid = res.get("id")
		_sources["%s/%s" % [category, rid if rid != null else &""]] = path


func _validate_and_report() -> void:
	# DataValidator 全量校验 → 应用剔除 → 汇总报告 → emit data_validated（§六.2）
	var validator := DataValidator.new()
	var result: Dictionary = validator.validate_all(self)
	for r in result["rejected"]:
		var category: StringName = r["category"]
		var rid: StringName = r["id"]
		match category:
			&"weapons":
				weapons.erase(rid)
			&"enemies":
				enemies.erase(rid)
			&"traits":
				traits.erase(rid)
			&"relics":
				relics.erase(rid)
			&"synergies":
				synergies.erase(rid)
			&"chips":
				chips.erase(rid)
			&"wave_table":
				wave_table = null
			&"game_feel":
				game_feel = null
	report = {
		"total": int(result["total"]),
		"rejected": (result["rejected"] as Array).size(),
		"errors": result["errors"],
		"warnings": result["warnings"],
	}
	EventBus.emit_data_validated(report)
