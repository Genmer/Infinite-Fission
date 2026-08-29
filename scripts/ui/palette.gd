# scripts/ui/palette.gd
# 方向 B「街机 CRT · 矢量磷光」调色板常量单源（美术方向真源，主控派发单 §调色板）。
# 世界基调：SENTINEL-9 弹道防御终端——磷光矢量线框 + 扫描线 + 终端文案。
# 只放常量与纯函数；任何节点/资源引用禁止（headless 自测安全）。
class_name Palette
extends RefCounted

# ── 屏底 / 双主色 ─────────────────────────────────────────────────
const BG := Color("050805")                 # 屏底近黑
const PHOS := Color("7CFF6B")               # 磷光主绿（己方/系统）
const AMBER := Color("FFB000")              # 琥珀（经验/警告/史诗）
const HOT_RED := Color("FF4444")            # 敌方热红
const WHITE_HOT := Color("FFFFFF")          # 白热（传说/Boss 核心）

# ── 文本层级 ──────────────────────────────────────────────────────
const TEXT_BODY := Color("A8FFB0")          # 正文磷光绿（微辉光感）
const TEXT_DIM := Color("3F5C42")           # 弱化（注脚/次要信息）

# ── 稀有度（磷光亮度阶梯，非色相） ────────────────────────────────
const RARITY_COMMON := Color("4E7A52")      # 普通 = 暗绿
const RARITY_RARE := Color("7CFF6B")        # 稀有 = 亮绿
const RARITY_EPIC := Color("FFB000")        # 史诗 = 琥珀
const RARITY_LEGEND := Color("FFFFFF")      # 传说 = 白热
const RARITY_COLORS: Array[Color] = [RARITY_COMMON, RARITY_RARE, RARITY_EPIC, RARITY_LEGEND]


static func rarity_color(p_rarity: int) -> Color:
	# 稀有度 → 磷光亮度（越界钳到普通档）
	return RARITY_COLORS[clampi(p_rarity, 0, RARITY_COLORS.size() - 1)]


# ── 实体语言（亮描边 + 暗半透明填充） ─────────────────────────────
const STROKE_PLAYER := PHOS                 # 玩家矢量箭形
const FILL_PLAYER := Color(0.12, 0.32, 0.12, 0.28)
const STROKE_ENEMY := HOT_RED               # 敌方线框
const FILL_ENEMY := Color(0.28, 0.05, 0.05, 0.30)
const STROKE_ELITE := AMBER                 # 精英 = 琥珀线框（警告族）
const FILL_ELITE := Color(0.30, 0.18, 0.02, 0.30)
const STROKE_BOSS := WHITE_HOT              # Boss 白热 → 红（随 HP 位移）
const FILL_BOSS := Color(0.34, 0.06, 0.06, 0.34)
const STROKE_XP := AMBER                    # 经验 = 琥珀小方碎块
const STROKE_WARN := AMBER                  # 警示圈（闪烁琥珀）

# ── 玩家弹元素着色（语义微移至磷光族；敌弹统一热红） ──────────────
const ELEMENT_TINTS: Array[Color] = [
	Color("F2FFF2"),                            # KIN 动能 = 白热
	Color("FFB000"),                            # FIR 灼烧 = 琥珀
	Color("8CE8D0"),                            # ICE 寒滞 = 磷光青
	Color("D0C8FF"),                            # LTG 过载 = 电紫
]
const ENEMY_BULLET := HOT_RED


static func element_tint(p_element: int) -> Color:
	if p_element < 0 or p_element >= ELEMENT_TINTS.size():
		return ELEMENT_TINTS[0]
	return ELEMENT_TINTS[p_element]
