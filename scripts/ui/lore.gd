# scripts/ui/lore.gd
# 方向 B「街机 CRT」剧情/终端文案常量单源（真源 = 主控派发单 §剧情文案）。
# 菜单启动序列 / 波次 toast / Boss 预警 / 结算战报 全部在此；界面层只取用不内联。
# 纯静态容器；随机引言用全局 RNG（纯表现层，不进数值链路）。
class_name Lore
extends RefCounted

# ── 主菜单 · 终端启动序列（逐行打字机输出，标题后浮现） ───────────
const TITLE := "SENTINEL-9"
const TITLE_SUFFIX := "// 防御协议 v9.0"
const BOOT_LINES: Array[String] = [
	"SENTINEL-9 // 防御协议 v9.0 初始化…",
	"> 深空裂变堆「普罗米修斯-9」堆芯失控",
	"> 反应堆状态：失稳",
	"> 链式反应预计 T-0 贯穿防御网",
	"> 弹道解算：在线",
	"> 最后防线：弹道解算核心（本机）",
	"> 等待操作员指令_",
]
const START_BUTTON := "[ 启动协议 ]"
const SUBTITLE := "弹幕防御 · ROGUELIKE"

# ── 波次 toast ────────────────────────────────────────────────────
const WAVE_TOAST_FMT := "> 第 %02d 波 · 裂变密度 +Δ"


static func wave_toast(p_wave: int) -> String:
	return WAVE_TOAST_FMT % maxi(p_wave, 1)


# ── Boss 预警（波次代号；Boss 名闪烁由 BossBar 承担） ─────────────
const BOSS_ALERT_PREFIX := "!! ALERT !! 高能聚合体接近 ——"
# w10 / w20 / w30 代号（派发单 §剧情文案；.tres display_name 不动）
const BOSS_CODENAMES: Dictionary = {10: "质子洪流", 20: "重核壁垒", 30: "裂变之心"}
const BOSS_CODENAME_FALLBACK := "未知聚合体"


static func boss_codename(p_wave: int) -> String:
	var key := p_wave - (p_wave % 10)           # 10~19 → 10 档
	var name_v: Variant = BOSS_CODENAMES.get(key, null)
	return String(name_v) if name_v != null else BOSS_CODENAME_FALLBACK


static func boss_alert(p_wave: int) -> String:
	return "%s %s" % [BOSS_ALERT_PREFIX, boss_codename(p_wave)]


# ── 结算 · 战报 ───────────────────────────────────────────────────
const GAME_OVER_TITLE := "// SESSION TERMINATED"
const GAME_OVER_LINE := "链式反应未被阻止。"
const REPORT_FMT := "// 战报：存活 %d 波 / 击杀 %d / 总输出 %d"
const RESTART_BUTTON := "[ 重启协议 ]"
const QUOTES: Array[String] = [
	"哨兵不休眠，只待重启。",
	"日志将续写于下一次防御。",
]


static func battle_report(p_wave: int, p_kills: int, p_total_damage: float) -> String:
	# 含「击杀」字样——pkg5 结算断言锚点（summary_text().contains("击杀")），不可改名
	return REPORT_FMT % [p_wave, p_kills, int(p_total_damage)]


static func random_quote() -> String:
	return QUOTES[randi() % QUOTES.size()]


# ── 选卡 · 终端文件列表 ───────────────────────────────────────────
const CARD_TITLE := "> SELECT UPGRADE MODULE"
# 类型代号（trait pool 类别 + 形态特例；显示层代号，不影响数值）
const CODE_MASTERY := "[WPN]"
const CODE_RELIC := "[REL]"
const CODE_FALLBACK := "[BASE]"


# ── HUD · 终端状态栏 ──────────────────────────────────────────────
const HUD_HEADER := "SENTINEL-9 // DEFENSE TERMINAL"
const HP_ASCII_CELLS := 8


static func hp_ascii(p_pct: float) -> String:
	# ASCII 式血条 [■■■■□□□□]（配合真实血条；pct 0~1）
	var cells := clampi(int(round(clampf(p_pct, 0.0, 1.0) * float(HP_ASCII_CELLS))), 0, HP_ASCII_CELLS)
	var bar := ""
	for i in range(HP_ASCII_CELLS):
		bar += "■" if i < cells else "□"
	return "[%s]" % bar
