# scripts/ui/palette.gd
# 方向 C「晴空糖果」调色板单源（美术方向 C 派发单）：
# 明亮底 + 厚描边 + 高饱和敌我区分。所有视觉层取色只经本表——禁止散落字面量色值。
# 纯常量容器（RefCounted，无运行时状态）。
class_name PopPalette
extends RefCounted

# ── 世界基调 ──────────────────────────────────────────────────────
const BG := Color("eef3ff")                   # 淡云蓝白（默认清屏色/菜单底）
const CLOUD := Color(1.0, 1.0, 1.0, 0.55)     # 云朵白（低对比，不抢弹幕）
const CLOUD_FAR := Color(1.0, 1.0, 1.0, 0.32)

# ── 敌我/功能色（高饱和区分） ─────────────────────────────────────
const PLAYER := Color("3d8bff")               # 我方 = 天空蓝
const ENEMY := Color("ff5d5d")                # 敌方 = 珊瑚红
const XP := Color("ffc93c")                   # 经验 = 柠檬黄
const SUCCESS := Color("2ed573")              # 成功 = 薄荷绿
const SHOCK := Color("8b5dff")                # 感电 = 葡萄紫
const ENEMY_DEEP := Color("ff4040")           # 爆虫充能警示（更深的红）
const GOLD := Color("ffc93c")                 # 精英皇冠/传说金

# ── 描边/文字 ─────────────────────────────────────────────────────
const OUTLINE := Color("22254a")              # 统一深藏青描边（实体/UI 3~4px）
const INK := Color("22254a")                  # 正文
const INK_SOFT := Color("8a90b8")             # 弱化文字
const PANEL := Color("ffffff")                # 面板纯白（圆角 20 + 藏青描边 + 厚投影）
const PANEL_PRESS := Color("e2e7fb")          # 按下下沉变暗
const DIM := Color(0.133, 0.145, 0.29, 0.55)  # 全屏压暗（藏青半透）

# ── 稀有度（普通灰蓝 / 稀有天蓝 / 史诗葡萄紫 / 传说柠檬金） ─────────
const RARITY_NORMAL := Color("8a90b8")
const RARITY_RARE := Color("3fa9ff")
const RARITY_EPIC := Color("8b5dff")
const RARITY_LEGEND := Color("ffc93c")

const RARITY_COLORS: Array[Color] = [RARITY_NORMAL, RARITY_RARE, RARITY_EPIC, RARITY_LEGEND]
const RARITY_NAMES: Array[String] = ["普通", "稀有", "史诗", "传说"]

# ── 彩纸屑（Boss 死亡签名瞬间；多色小矩形/圆） ────────────────────
const CONFETTI: Array[Color] = [PLAYER, ENEMY, XP, SUCCESS, SHOCK, Color("ff9f43")]


static func rarity_color(p_rarity: int) -> Color:
	# 稀有度取色（越界钳制——fallback 卡/坏数据安全）
	return RARITY_COLORS[clampi(p_rarity, 0, RARITY_COLORS.size() - 1)]


static func rarity_name(p_rarity: int) -> String:
	return RARITY_NAMES[clampi(p_rarity, 0, RARITY_NAMES.size() - 1)]


static func hp_fill(p_pct: float) -> Color:
	# HP 条填充色：满 → 薄荷绿，中段 → 柠檬黄，低 → 珊瑚红（纯渐变无表情，方向 C 口径）
	var pct := clampf(p_pct, 0.0, 1.0)
	if pct > 0.5:
		return SUCCESS.lerp(XP, (1.0 - pct) * 2.0)
	return XP.lerp(ENEMY, (0.5 - pct) * 2.0)
