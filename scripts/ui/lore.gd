# scripts/ui/lore.gd
# 方向 A 剧情文案单源（视觉包装派发单 = 文案真源）。
# 世界观：2087 年，深空裂变堆「普罗米修斯-9」堆芯失控；玩家 = 弹道防御 AI「哨兵-9」。
# 纯文案常量：不进任何逻辑路径；界面组装处按状态取行。
class_name Lore
extends RefCounted

# ── 主菜单 ───────────────────────────────────────────────────────
const TITLE := "INFINITE FISSION"
const SUBTITLE := "∞ 链式裂变"
const MENU_LORE: Array[String] = [
	"2087 年，深空裂变堆「普罗米修斯-9」堆芯失控。",
	"你是它最后的防线——弹道防御 AI「哨兵-9」。",
	"子弹即誓言。链式反应，就此斩断。",
]
const MENU_START := "启 动 协 议"

# ── 波次 toast ───────────────────────────────────────────────────
const WAVE_TOAST_FORMAT := "第 %d 波 · %s"
const WAVE_TOAST_DEFAULT := "裂变密度上升"
# 每 5 波递进词（w5/w10/w15…依序循环取用——无尽段回到风暴，密度感知循环）
const WAVE_TIERS: Array[String] = ["质子风暴逼近", "反应临界", "链式失控"]

# ── Boss 预警横幅（前缀 + Boss 名，按波次） ─────────────────────
const BOSS_ALERT_PREFIX := "⚠ 高能反应体接近 —— "
# 波次 → Boss 名（w10/w20/w30；无尽段 Boss 沿用 w30 口径）
const BOSS_NAMES: Dictionary = {10: "质子洪流", 20: "重核壁垒", 30: "裂变之心"}
const BOSS_NAME_FALLBACK := "裂变之心"

# ── 结算屏 ───────────────────────────────────────────────────────
const GAMEOVER_TITLE := "链式反应未被阻止。"
const GAMEOVER_QUOTES: Array[String] = [
	"哨兵会再次醒来。",
	"裂变从未停止，守望亦然。",
	"下一次，链式将被斩断。",
]
const GAMEOVER_RESTART := "重 启 协 议"

# ── 取值辅助 ─────────────────────────────────────────────────────
static func wave_toast_text(p_wave: int) -> String:
	# 第 N 波 · 后缀（每 5 波递进词，其后循环；浮点除后取整规避整除告警）
	var suffix := WAVE_TOAST_DEFAULT
	if p_wave > 0 and p_wave % 5 == 0:
		suffix = WAVE_TIERS[(floori(p_wave / 5.0) - 1) % WAVE_TIERS.size()]
	return WAVE_TOAST_FORMAT % [p_wave, suffix]


static func boss_alert_text(p_wave: int) -> String:
	# 预警横幅：前缀 + Boss 名（表内波次直取；其余 fallback）
	var name := BOSS_NAME_FALLBACK
	if BOSS_NAMES.has(p_wave):
		name = String(BOSS_NAMES.get(p_wave, BOSS_NAME_FALLBACK))
	return BOSS_ALERT_PREFIX + name


static func gameover_quote(p_index: int) -> String:
	# 结算引言（顺序取用稳定轮换，避免结算瞬态随机）
	return GAMEOVER_QUOTES[absi(p_index) % GAMEOVER_QUOTES.size()]
