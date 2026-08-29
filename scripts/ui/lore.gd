# scripts/ui/lore.gd
# 方向 C「晴空糖果」剧情文案单源（美术派发单：真源 = 本文件常量）。
# 「哨兵-9」是台有点话痨的防御机器人，守护反应堆乐园——轻快元气 Pop 腔调。
class_name Lore
extends RefCounted

# ── 主菜单 ────────────────────────────────────────────────────────
const LOGO := "INFINITE FISSION"
const SUBTITLE := "∞ 链式裂变乐园"
const MENU_LINES: Array[String] = [
	"反应堆今天也在打喷嚏。",
	"防御机器人「哨兵-9」决定用弹幕帮它冷静一下。",
	"出发吧——链式反应，一根也不许 runaway！",
]
const START_BUTTON := "出发！"

# ── 波次 toast（递进：普通 → 热闹 → 蹦迪） ─────────────────────────
static func wave_toast(p_wave: int) -> String:
	if p_wave >= 20:
		return "第 %d 波！反应堆开始蹦迪了！" % p_wave
	if p_wave >= 10:
		return "第 %d 波！越来越热闹了…" % p_wave
	return "第 %d 波！反应堆有点兴奋" % p_wave


# ── Boss 预警（名字取数据真源 display_name——resources 不可改，保持一致） ──
const BOSS_WARNING_FMT := "大家伙登场 —— %s！"

static func boss_warning(p_display_name: String) -> String:
	return BOSS_WARNING_FMT % p_display_name


# ── 结算屏 ────────────────────────────────────────────────────────
const GAME_OVER_TITLE := "哎呀，被链式反应冲跑了…"
const GAME_OVER_BUTTON := "再来一局！"
const GAME_OVER_QUOTES: Array[String] = [
	"哨兵-9 拍拍灰：再来！",
	"今天的弹幕也尽力了。",
	"下次一定斩断它！",
]

static func game_over_quote() -> String:
	# 随机引言（纯表现随机，不涉数值确定性）
	return GAME_OVER_QUOTES[randi() % GAME_OVER_QUOTES.size()]


# ── Boss 死亡签名瞬间 ─────────────────────────────────────────────
const BOSS_DING := "叮！"
