# scripts/meta/run_save.gd
# 局内进度存档（2026-08-31 用户反馈「现在好像没存档机制，每次重开都是从头，新增一个
# 存档位置，回到菜单再进入可选择继续上次进度」）：单槽 user://run_save.cfg。
# · 写入时机：波次开始自动存档（GameLoop._on_wave_started_reroll_grant 同源订阅）+
#   暂停「回主菜单」落盘——存档粒度 = 波次边界，继续时从当波开头重打（波内进度不追溯）。
# · 清除时机：玩家死亡结算（局终）/ 重新开始（放弃旧档）。Meta 永久进度（图鉴/成就/
#   结晶/地图通关）不受本档影响——两条存档链互不干扰。
# · 结构（ConfigFile 单段 run）：map_id / daily / wave / kills / elapsed / character /
#   level / xp / hp / max_hp / gold / rerolls / free_reroll / unlocked_slots /
#   weapons[{id, level, traits[{id, layers}]}]——全部为可序列化基本类型/容器。
class_name RunSave
extends RefCounted

const SAVE_PATH := "user://run_save.cfg"


static func exists() -> bool:
	return FileAccess.file_exists(SAVE_PATH)


static func clear() -> void:
	# 局终/放弃旧档（无档静默——幂等）
	if exists():
		DirAccess.open("user://").remove(SAVE_PATH.trim_prefix("user://"))


static func save_run(p_data: Dictionary) -> void:
	# 落盘（空数据防御：拒绝写入空档——continue 语义保底）
	if p_data.is_empty():
		return
	var cfg := ConfigFile.new()
	for key in p_data:
		cfg.set_value("run", String(key), p_data[key])
	cfg.save(SAVE_PATH)


static func load_run() -> Dictionary:
	# 读档（无档/坏段 → 空 Dictionary；键值原样透传，消费侧 GameLoop 逐键防御取默认）
	var cfg := ConfigFile.new()
	if cfg.load(SAVE_PATH) != OK:
		return {}
	if not cfg.has_section("run"):
		return {}
	var out: Dictionary = {}
	for key in cfg.get_section_keys("run"):
		out[key] = cfg.get_value("run", key)
	return out
