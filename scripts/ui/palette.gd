# scripts/ui/palette.gd
# 方向 A「深空核裂变 · 霓虹矢量」色彩单源（视觉包装真源）。
# 全部程序化视觉（UI/实体/跳字/背景）取色一律经本表——禁止散落硬编码色值。
# 数值红线无涉：纯表现层常量，不进任何结算/手感路径。
class_name Palette
extends RefCounted

# ── 基调（深空） ──────────────────────────────────────────────────
const BG_DEEP := Color("0b0e1a")              # 背景深空
const PANEL_GLASS := Color("131a2e")          # 面板玻璃
const PANEL_EDGE := Color("2a3654")           # 面板描边
const PANEL_SHADOW := Color(0.0, 0.0, 0.0, 0.35)  # 微阴影

# ── 阵营/语义色 ──────────────────────────────────────────────────
const CYAN := Color("4fe3ff")                 # 主色（我方/哨兵）
const MAGENTA := Color("ff4fd8")              # 敌方
const AMBER := Color("ffc24f")                # 经验/稀有
const RED := Color("ff5252")                  # Boss/警报
const GREEN := Color("54ff9f")                # 成功
const VIOLET := Color("b47cff")               # 感电

# 元素语义色（弹丸/反应跳字共用：FIR 点燃橙 / ICE 冰冻青 / LTG 感电紫）
const FIR := Color("ff9c4f")
const ICE := Color("4fd8ff")
const LTG := Color("b47cff")

# ── 文本 ─────────────────────────────────────────────────────────
const TEXT_MAIN := Color("e8eeff")            # 正文
const TEXT_DIM := Color("8a96b8")             # 弱化/注释

# ── 稀有度（灰/青/品红/琥珀） ────────────────────────────────────
const RARITY_GRAY := Color("8a96b8")
const RARITY_COMMON := RARITY_GRAY
const RARITY_RARE := CYAN
const RARITY_EPIC := MAGENTA
const RARITY_LEGEND := AMBER

# ── 字号（SystemFont 中文黑体；数值等宽） ────────────────────────
# 硬性要求（方向 B 实测教训）：字重 ≥600（标题 800）、正文 ≥17px、标题 ≥30px——
# 细字/小字在竖屏高刷实机上不可读 = 返工。
const FONT_TITLE := 30                        # 界面标题（下限 30）
const FONT_HERO := 56                         # 主菜单大标题
const FONT_BODY := 17                         # 正文（下限 17）
const FONT_CAPTION := 14                      # 注释/辅助（仅限非关键信息）
const FONT_NUM := 18                          # 数值（等宽）
const FONT_POPUP := 21                        # 跳字基数（比正文大一档；CRIT 再放大）

# ── 描边（游戏内文字可读性——深色描边统一走此常量，size 4~6） ────
const OUTLINE_COLOR := Color(0.02, 0.03, 0.08, 0.92)
const OUTLINE_SIZE := 5

# ── 取值辅助 ─────────────────────────────────────────────────────
static func rarity_color(p_rarity: int) -> Color:
	# 稀有度 → 语义色（0 灰 / 1 青 / 2 品红 / 3+ 琥珀）
	match clampi(p_rarity, 0, 3):
		0:
			return RARITY_COMMON
		1:
			return RARITY_RARE
		2:
			return RARITY_EPIC
		_:
			return RARITY_LEGEND


static func element_color(p_element: int) -> Color:
	# GameConst.Element（KIN/FIR/ICE/LTG）→ 语义色（KIN = 正文近白）
	match p_element:
		1:
			return FIR
		2:
			return ICE
		3:
			return LTG
		_:
			return TEXT_MAIN
