# 腐化者·莽（mank）技能升华设计——「万毒噬界」

> buff 卡「技能升华」（红色传说，0.001% 爆率）命中后，本局角色技能升级为升华版。
> 本文只覆盖 mank；其余角色由对应设计师的文档负责。
> 设计基线代码：`repo/scripts/meta/character_table.gd`、`repo/scripts/entities/player/player.gd`（行号为本文撰写时快照）。

---

## 一、角色与技能现状（真源引用）

### 1.1 角色定义（character_table.gd:54-59）

| 键 | 值 |
|---|---|
| id | `mank` |
| name | 腐化者·莽 |
| 定位 | 毒沼共生体（血 58 / 攻 +12%），**终局毒核** |
| 解锁 | 通关⑤翠毒沼泽（`unlock_map: world_swamp`） |
| 技能名 | 毒沼绽放 |
| 技能描述 | 全屏毒爆：对所有敌人结算 150% 攻击 |
| cd | 120.0 |

### 1.2 现实现（player.gd:746-776 `_skill_poison_nova`）

- 全屏判定：`enemy_grid.query_circle(global_position, 4096.0)`（半径远超 720×1280 屏，等效全场）。
- 伤害底数：`weapon_slots[0]` 面板快照 `base_atk × 1.5`（player.gd:753）——吃武器等级/词条面板，但**不吃**角色 atk_pct（面板已在武器侧）。
- 结算通道：`DamageContext` 逐敌直交 `pipeline.resolve(ctx)`（player.gd:772-773）。
  - `element = KIN`（R199 D14 矫正：毒系无元素通道，原 FIR 会被火免疫敌 `elem_immune=2` 拦零——现口径**任何免疫都不零伤**）；
  - `hit_flags |= HIT_IS_AOE_SECONDARY`（次级通道，不吃主弹命中类词条触发）；
  - `crit_chance = 0.0`（不可暴击，稳定期望）；
  - `source_uid = 玩家实例 id + frame_stamp`（player.gd:759-763，管线幂等键）；
  - `_inject_relic_pools`（player.gd:736-743）注入遗物命中乘区。
- 分发：`activate_skill` 的 `&"mank"` 臂（player.gd:850-851）；CD 置于分发前（player.gd:828）。
- 表现：`_skill_fx_duration` 走缺省 0.8s 施放闪光（player.gd:868-882）+ `EventBus.emit_skill_cast` 金环（player.gd:863）。

### 1.3 已确认的管线事实（直接影响本设计）

| 事实 | 出处 | 对设计的约束 |
|---|---|---|
| `resolve(ctx)` **同步返回 `DamageResult`**，含 `killed: bool`、`source_uid` | damage_pipeline.gd:87、damage_result.gd:8/11 | 击杀归因零成本：现有代码丢弃返回值（player.gd:773），升华版接住即可 |
| 管线按 `(source_uid, target_uid, frame_stamp)` **幂等去重**，同帧同源同目标直接折返 | damage_pipeline.gd:108-113 | 尸爆若与毒爆共用玩家实例 id 作 source_uid，同帧打同一目标会被当 dupe 吞掉 → **尸爆必须用合成 UID**（先例：ground_axe_weapon.gd:196 `_shock_uid`） |
| 击杀即置 `dead=true` 再广播 `enemy_killed` | enemy.gd:866-869、1099 | 尸爆范围查询里 `dead` 守卫天然只打「毒爆后存活者」 |
| 敌人身份位：`tags: int`（`TAG_ELITE`/`TAG_BOSS`） | enemy.gd:15、597、611 | 喂层分档的判据，与 mank 循环现有 `e.get(...)` 鸭子口同风格 |
| 表现层爆炸环已有**多方复用通道** `EventBus.emit_kill_blast(pos, radius)` | enemy.gd:1242/1331/3329、trait_effect_mech.gd:46 | 尸爆特效零新信号成本 |
| 播报横幅通道 `EventBus.emit_mechanics_intro(text)` | player.gd:977（诺亚复制播报先例） | 层数里程碑播报复用 |

### 1.4 数量级取样（平衡建模用）

- 敌方：杂兵 debut 血 45~75（E1 72 / E15 50）、中坚 140~320（E26 140 / E14 320）、Boss ~15~16k（E17~E20），波次成长 `×1.12^w`（enemy.gd:604-613）。→ 毒爆对杂兵是「清屏级」，对 Boss 是「小额跳伤」（满配面板下约 1~3% Boss 血）。
- 我方：W1 手枪 L1 面板 14 → L5 每发 12×3 线（W1_pistol.tres）；局内面板随词条/遗物乘区继续放大。
- 结论：普通毒沼绽放的真实战力定位 = **杂兵清场 + 终局对 Boss 的稳定补伤**（无免疫死角、不暴击、期望稳定）。升华设计必须保留这个身份，而非改角色。

---

## 二、升华技能总览

| 项 | 内容 |
|---|---|
| **升华名** | 万毒噬界 |
| **一句话** | 全屏毒爆提至 210% 并随「腐化精华」层数成长（每层 +2%，上限 30 层→满层 270%）；被毒爆击杀的敌人原地腐沼爆裂，对周围结算 50% 攻击。 |
| **卡片描述文案**（供 character_table/卡牌展示用） | 万毒噬界：全屏毒爆结算 210% 攻击；毒爆击杀喂养毒核（精华每层 +2%，上限 30 层，精英 ×2 / 首领 ×5）；被毒爆击杀的敌人原地毒沼爆裂（50% 攻击）。 |
| **CD** | 120s（不变。理由：本设计全部增益走「轮内数值 + 击杀链」，无任何时长窗；杀人书式成长的意义就在于放得克制——缩 CD 会同时放大喂层速率，双重超模，故不动 CD 基准） |

设计主轴：普通版的身份是「一次性全屏绽放」；升华不是把它变成持续领域（那是 vera 毒云的身份，player.gd:892-933——刻意避开同质化），而是把「绽放→凋零→再绽放」的腐化轮回做进一次按键里：**爆得更高（数值）、死者回馈毒核（成长）、尸体再绽放（链）**——三个层次全部长在「毒沼吞噬腐肉」这一个意象上。

---

## 三、新机制详解

### 3.1 机制一：腐化精华（杀人书 · 层数转化）

> 毒沼吞噬腐肉，滋养毒核——莽的身份就是「终局毒核」，越到终局越接近完全体。

- **喂层**：毒沼绽放（升华版）或其腐沼爆裂**直接击杀**的每个敌人，使毒核获得「腐化精华」：
  - 普通敌 +1 层；带 `TAG_ELITE` 的 +2 层；带 `TAG_BOSS`/`TAG_FINAL_BOSS` 的 +5 层。
- **转化**：每层使**下一次**毒沼绽放倍率 +2%（加算进倍率系数，非独立乘区——不吃遗物乘区二次放大）。
  - 0 层 210% → 满层 30 层 210% + 60% = **270%**。
- **节奏预估**：全屏毒爆在杂兵波一次收割 10~20 层，通常第 2~3 次施放（开局 4~6 分钟）即满层——前期是成长曲线，中后期稳定在满层（「终局毒核孕育完全体」的叙事顺序与局内时间线一致）。
- **归属**：层数是**局内会话态**（层数不进存档，零键污染——卡系统存档键 `"sublime"` 裁定仅含 `on`/`fission_layers` 两成员，mank 层数刻意不入键），换角色/重开随 `_reset_skill_temp_state`（player.gd:809-820）清零。
- **继续局语义**（对齐卡系统修订）：暂停→继续局经 set_character 重建 Player（game_loop.gd:2911-2915 恢复序先例，R212 skill_cd 随档），随后 `_restore_run_state` clampf/幂等回填——升华**位**由卡系统统一键 `"sublime".on` 保真（回填 `enable_sublime()`）；层数**不在保真键内**：重建后归零、倍率回 210% 基线，第 1~2 轮施放即回满层（见上方节奏预估），损失有界、换取零键污染，属刻意取舍（位保真、层数不保，两者分离）。
- **播报**：10/20/30 层时 `EventBus.emit_mechanics_intro` 横幅（先例 player.gd:977），30 层文案「毒核完全体：万毒噬界 270%」。
- **归因口径（防蹭层）**：只认 `resolve` 返回的 `killed` 位——即「这一发毒爆/这一枚腐沼爆裂打死的」。武器击杀、其它角色技能击杀**不喂层**（莽的毒核只吞自己毒死的腐肉）。

### 3.2 机制二：腐沼爆裂（击杀链绽放 · 深度 1）

> 毒沼里倒下的东西会烂开——尸体在原地炸出第二圈毒。

- **触发**：本轮毒沼绽放结算中 `killed == true` 的每个敌人，死后原地爆开 **140px** 腐沼。
- **结算**：对半径内存活敌人各结算 **50% 主武器面板 ATK**——通道口径与毒爆主体完全一致（`KIN` 元素免疫零伤优势保留 / `HIT_IS_AOE_SECONDARY` / 不暴击 / `_inject_relic_pools` 注入遗物乘区）。
- **三条护栏**（全部为机制语义，不是拍脑袋削数值）：
  1. **每目标每轮至多一次**：同一轮绽放的多枚腐沼爆裂对同一敌人只结算一次（玩家侧 `blasted` 去重集合）——语义「同源毒沼不叠加」，同时把聚怪收益硬封顶在 +50% ATK/目标。
  2. **深度 1，不再连锁**：腐沼爆裂打死的敌人不再引发新的爆裂（防指数链 + 防同帧结算尖峰）。
  3. **合成 source_uid**：每轮爆裂用一个 `玩家实例id + 轮内序号` 的合成 UID（先例 ground_axe_weapon.gd:196 `_shock_uid`），规避管线 `(source,target,frame)` 幂等键与毒爆主体撞车（damage_pipeline.gd:108-113——同帧同源同目标会被折返吞掉）。
- **闭环**：腐沼爆裂的击杀同样喂腐化精华（3.1）——「爆裂收残血 → 残血喂毒核 → 毒核强化下一次绽放」。
- **表现**：每枚爆裂 `EventBus.emit_kill_blast(pos, 140.0)`（复用爆炸环通道，先例 enemy.gd:1242），叠在绿色毒爆金环上形成「一环扫屏 + 多点溃烂」的层次；可选后续项：fx 层给 kill_blast 加绿色染色参数（非本设计必需）。

### 3.3 刻意不做的事（设计边界）

- **不做持续毒领域**：vera 的身份就是毒云（player.gd:892-933，300px/6s/8%/跳）；mank 若加全屏 DoT 等于抢同生态位，且把「瞬时爆发」的技能手感稀释成buff 窗。拒绝。
- **不改元素/暴击口径**：KIN 不暴击是 R199 D14 + 期望稳定的既有裁定，升华版全通道沿用（升华改口径 = 引入新的免疫死角回归，违背矫正初衷）。
- **层数不进存档**：精华层数是本局成长，重开归零；继续局亦随 set_character 重建清零（升华**位**本身由卡系统 `"sublime"` 键保真，见 3.1 继续局语义——位保真、层数不保，两者刻意分离）。

---

## 四、数值对照表与平衡核算

### 4.1 普通 → 升华对照表

| 维度 | 普通版（现状） | 升华版（万毒噬界） |
|---|---|---|
| 毒爆基础倍率（主武器面板 ATK） | 150% | **210%** |
| 腐化精华层 | — | 毒爆/腐沼爆裂击杀：普通 +1 / 精英 +2 / Boss +5，**上限 30 层** |
| 每层增益 | — | **+2%** 毒爆倍率（加算），满层 +60% |
| 满层毒爆倍率 | — | **270%** |
| 腐沼爆裂 | — | **50% ATK × 140px**，每目标每轮 1 次，深度 1 |
| 元素通道 | KIN（免疫敌不零伤） | 同左（毒爆+爆裂全通道同口径） |
| 暴击 | 不可暴击 | 同左 |
| 遗物命中乘区 | `_inject_relic_pools` 注入 | 同左（爆裂同样注入） |
| 幂等键 | 玩家实例 id | 毒爆同左；爆裂用合成 UID |
| CD | 120s | **120s（不变）** |
| 战力定位 | 全屏清杂 + Boss 稳定补伤 | 同定位强化 + 局内成长曲线 |

### 4.2 战力核算（普通版单次施放期望 = 1.0×，面板/遗物乘区两侧同吃故约去）

| 场景（单次施放） | 计算 | 相对普通版 |
|---|---|---|
| 首放 0 层 · 纯单体 Boss（无击杀无爆裂） | 210 / 150 | 1.40×（起势让利，下见说明） |
| 首放 0 层 · 有击杀（含爆裂 +50%） | (210+50) / 150 | 1.73× |
| 中期 ~20 层 · 单体 | (210+40) / 150 | 1.67× |
| 中期 ~20 层 · 密集怪（爆裂吃到） | (250+50) / 150 | 2.00× |
| 满配 30 层 · 单体 | 270 / 150 | 1.80× |
| **满配 30 层 · 单轮理论上限（爆裂命中）** | **(270+50) / 150** | **2.13×** |
| 全程时间加权期望 | — | **≈1.85×** |

- 区间校验：满配上限 2.13× ≤ 2.2× ✓；全程期望 ≈1.85× 落在 1.6~2.2 ✓。
- 首放 1.40× 低于区间下限的说明：这是全程最低点且只存在于**第一次施放**（此时无任何击杀累积）——首放即开始喂层，第 2 放起进入区间。杀人书式设计的固有起势，刻意保留（若抬首放数值，满配必破 2.2 上限）。
- **爆裂强度对标**：R13 死亡新星词条 = 30% ATK × 70px、随击杀弹**常驻**触发（trait_effect_mech.gd:3,44-45）；本设计 50% × 140px 高于它，但触发源仅 120s 一轮的毒爆击杀、且每目标封顶一次——单轮总量有界（见护栏 3.2-1），不构成对词条生态的碾压。
- **喂层速率校验**：最肥场景（全屏 20 杂兵全灭 + 爆裂补杀）单轮 +20~24 层 → 第 2 放即近满层。上限 30 保证 4 分钟后成长曲线封顶、倍率恒定 270%，不再随波次膨胀（与 1.12^w 的敌方成长对位的是面板/遗物成长，不是技能倍率）。

---

## 五、实现方案

### 5.1 挂点清单（implAnchors）

| # | 挂点 | 动作 |
|---|---|---|
| 1 | `player.gd` `_skill_poison_nova`（746-776） | 主改造：升华分支读层数定倍率；接住 `resolve` 返回值收集 `killed` 者并即时喂层 |
| 2 | `player.gd` 新函数 `_resolve_corpse_blasts`（置于 `_skill_poison_nova` 后） | 腐沼爆裂结算（合成 UID / 去重 / 深度 1 / 喂层闭环） |
| 3 | `player.gd` 新函数 `_gain_mank_essence` | 喂层分档（tags 位判精英/Boss）+ 上限钳制 + 里程碑播报 |
| 4 | `player.gd` `_reset_skill_temp_state`（809-820） | 追加 `_mank_essence = 0`（换角/重开收口，同毒云清零先例） |
| 5 | `player.gd` `_inject_relic_pools`（736-743） | 不改，爆裂 ctx 复用注入 |
| 6 | `player.gd` `activate_skill` mank 分发臂（850-851） | 不改（升华分支收在 `_skill_poison_nova` 内部，分发零改动） |
| 7 | EventBus | 零新信号：爆裂复用 `emit_kill_blast`，播报复用 `emit_mechanics_intro` |
| 8 | （卡系统泳道，非本文范围）game_loop.gd `serialize_run`（2738）/ `_restore_run_state` 恢复序（2911-2915 先例） | 新增单键 `"sublime": {on: bool, fission_layers: int}`；set_character 之后 clampf/幂等回填 `enable_sublime()`（`fission_layers` 按枢上限钳制——沿 R212 skill_cd 同款「set_character 之后 + clamp 防脏档」语义）；旧档无键零迁移——mank 仅消费契约（见 3.1 继续局语义） |

**前置依赖**（卡牌系统侧，非本文实现范围；总监已裁定全角色归一）：统一字段名 **`skill_sublime: bool`**（本文原口径即此，多数派，不改）+ 统一入口 **`enable_sublime() -> void`**（幂等：内部置 `skill_sublime=true` 并分发角色初始化，含 fission 层数回填）；HUD 技能键红描边读口统一 `player.get("skill_sublime")`。本文所有升华分支以 `skill_sublime` 为开关；该口未就位时按 false 走普通路径，零回归。

### 5.2 伪代码

```gdscript
# ── player.gd 常量/成员（mank 技能段附近） ─────────────────────────
const SUBLIME_NOVA_PCT      := 2.10   # 升华毒爆基础倍率 210%
const SUBLIME_ESSENCE_MAX   := 30     # 腐化精华上限
const SUBLIME_ESSENCE_PCT   := 0.02   # 每层 +2%（加算入倍率）
const SUBLIME_ESSENCE_ELITE := 2      # 精英击杀喂层
const SUBLIME_ESSENCE_BOSS  := 5      # Boss 击杀喂层
const SUBLIME_BLAST_PCT     := 0.50   # 腐沼爆裂 50% ATK
const SUBLIME_BLAST_RADIUS  := 140.0  # 爆裂半径（R13 死亡新星 70px 的 2 倍）

var _mank_essence := 0                # 腐化精华（会话态；_reset_skill_temp_state 清零）
var _blast_uid_seq := 0               # 爆裂合成 UID 轮内序号


func _skill_poison_nova() -> void:
	# 毒沼绽放 → 万毒噬界（升华）：普通路径逐位不动，升华分支加 [倍率/喂层/爆裂]
	var grid: Variant = _deps.get("enemy_grid")
	var pipeline: Variant = _deps.get("pipeline")
	var w0: Variant = weapon_slots[0] if weapon_slots.size() > 0 else null
	if grid == null or w0 == null:
		return
	var sublime := skill_sublime                     # 前置依赖：升华卡统一读口
	var panel := float((w0 as WeaponBase).build_panel_snapshot().get("base_atk", 0.0))
	var pct := 1.5                                   # 普通版口径（回归锚点）
	if sublime:
		pct = SUBLIME_NOVA_PCT + float(_mank_essence) * SUBLIME_ESSENCE_PCT
	var base := panel * pct
	var settled := 0
	var blast_pos: Array[Vector2] = []               # 升华：本轮击杀者的爆裂锚点
	for e in (grid as SpaceGrid).query_circle(global_position, 4096.0):
		if e == null or bool(e.get("dead")):
			continue
		var ctx := DamageContext.make()
		ctx.source_uid = int(get_instance_id())      # 毒爆主体幂等键（现状不动）
		ctx.target = e
		ctx.target_uid = int(e.get("uid"))
		ctx.frame_stamp = GameConfig.frame_stamp
		ctx.base_atk = base
		ctx.element = GameConst.Element.KIN          # R199 D14 口径保留
		ctx.hit_flags |= GameConst.HIT_IS_AOE_SECONDARY
		ctx.crit_chance = 0.0
		ctx.pos = (e as Node2D).global_position
		_inject_relic_pools(ctx, e)
		var res: Variant = null
		if pipeline != null and (pipeline as Object).has_method(&"resolve"):
			res = (pipeline as Object).call(&"resolve", ctx)   # ★ 接住返回值（原来丢弃）
			settled += 1
		if sublime and res is DamageResult and (res as DamageResult).killed:
			_gain_mank_essence(e)                    # 机制一：毒爆击杀喂层
			blast_pos.append((e as Node2D).global_position)
	if settled > 0:
		DebugStats.count(&"poison_nova")
	if sublime and not blast_pos.is_empty():
		_resolve_corpse_blasts(blast_pos, panel, grid, pipeline)


func _resolve_corpse_blasts(p_anchors: Array[Vector2], p_panel: float,
		p_grid: Variant, p_pipeline: Variant) -> void:
	# 机制二：腐沼爆裂——深度 1（本函数内击杀不回流 blast_pos）、每目标每轮 1 次
	_blast_uid_seq += 1
	# 合成 UID（先例 ground_axe _shock_uid）：与毒爆主体同帧同目标不撞幂等键
	var blast_uid := int(get_instance_id()) + _blast_uid_seq * 1000000
	var blasted := {}                                # target_uid -> true（去重封顶）
	for anchor in p_anchors:
		EventBus.emit_kill_blast(anchor, SUBLIME_BLAST_RADIUS)   # 表现：复用爆炸环
		DebugStats.count(&"poison_blast")
		for e in (p_grid as SpaceGrid).query_circle(anchor, SUBLIME_BLAST_RADIUS):
			if e == null or bool(e.get("dead")):     # 毒爆阵亡者(dead=true)天然跳过 → 只打存活者
				continue
			var uid := int(e.get("uid"))
			if blasted.has(uid):                     # 护栏①：每目标每轮一次
				continue
			blasted[uid] = true
			var ctx := DamageContext.make()
			ctx.source_uid = blast_uid               # 护栏③：合成 UID
			ctx.target = e
			ctx.target_uid = uid
			ctx.frame_stamp = GameConfig.frame_stamp
			ctx.base_atk = p_panel * SUBLIME_BLAST_PCT
			ctx.element = GameConst.Element.KIN      # 与毒爆全通道同口径
			ctx.hit_flags |= GameConst.HIT_IS_AOE_SECONDARY
			ctx.crit_chance = 0.0
			ctx.pos = (e as Node2D).global_position
			_inject_relic_pools(ctx, e)              # 遗物乘区同注
			var res: Variant = null
			if p_pipeline != null and (p_pipeline as Object).has_method(&"resolve"):
				res = (p_pipeline as Object).call(&"resolve", ctx)
			if res is DamageResult and (res as DamageResult).killed:
				_gain_mank_essence(e)                # 闭环：爆裂击杀同样喂层
				# 护栏②：不 append 爆裂锚点——深度 1，不再连锁


func _gain_mank_essence(p_enemy: Variant) -> void:
	# 机制一喂层：tags 位分档（enemy.gd:15 TAG_ELITE/TAG_BOSS；鸭子读与 mank 循环同风格）
	var add := 1
	var tags := int(p_enemy.get("tags", 0))
	if (tags & (GameConst.TAG_BOSS | GameConst.TAG_FINAL_BOSS)) != 0:
		add = SUBLIME_ESSENCE_BOSS
	elif (tags & GameConst.TAG_ELITE) != 0:
		add = SUBLIME_ESSENCE_ELITE
	var before := _mank_essence
	_mank_essence = mini(_mank_essence + add, SUBLIME_ESSENCE_MAX)
	if _mank_essence == SUBLIME_ESSENCE_MAX and before < SUBLIME_ESSENCE_MAX:
		EventBus.emit_mechanics_intro("毒核完全体：万毒噬界 270%")
		DebugStats.count(&"mank_essence_capped")
	elif _mank_essence in [10, 20] and before < _mank_essence:
		EventBus.emit_mechanics_intro("毒核吞噬：腐化精华 %d/%d" % [_mank_essence, SUBLIME_ESSENCE_MAX])
```

`_reset_skill_temp_state`（player.gd:809-820）追加一行：

```gdscript
	_mank_essence = 0        # 万毒噬界层数收口（换角/重开共用，同毒云清零先例）
```

### 5.3 边界与已知坑对照

| 边界 | 处理 |
|---|---|
| 测试裸 Player（无 pipeline） | `res` 恒 null → 不喂层不爆裂，`settled` 路径照旧——与现有防御同构（player.gd:751-752,772-773） |
| 元素免疫敌（E4/E8 类） | KIN 通道本就免疫零伤不拦（R199 D14）——`immune` 结果 `killed=false`，自然不爆裂 |
| 同帧结算尖峰 | 爆裂次数 = 本轮毒爆击杀数（有界）；每目标去重后总结算数 ≤ 毒爆数 + 屏上敌数——远低于既有弹幕峰值口径 |
| GDScript 类型化赋值先于 `is_instance_valid` | 伪代码沿用 `var x: Variant = ...` 先赋值后判断的现役风格（player.gd:750-753 同款），不引入新的先类型化后判活路径 |
| 池化节点 | 爆裂只持 `Vector2` 锚点与 uid，**不持有 Enemy 引用**（击杀者已 dead/待回收，取 global_position 后即弃）——规避「测试勿 add_child 池化节点」与悬挂引用 |
| 幂等 | 毒爆主体 source_uid 不变（回归）；爆裂合成 UID 每轮唯一——`dropped_dupe` 不应增长（测试断言点） |

---

## 六、表现与播报

| 时机 | 通道 | 内容 |
|---|---|---|
| 施放 | `emit_skill_cast`（现状不动） | 金环爆发 0.8s |
| 每枚腐沼爆裂 | `emit_kill_blast(pos, 140)`（复用） | 爆炸环——多点溃烂层次感 |
| 10 / 20 层 | `emit_mechanics_intro` | 「毒核吞噬：腐化精华 10/30」 |
| 满层 30 | `emit_mechanics_intro` | 「毒核完全体：万毒噬界 270%」 |
| DebugStats | `poison_nova`（存）/ `poison_blast` / `mank_essence_capped` | 遥测 |

---

## 七、测试要点（tests/runner 惯例：`-s` 入口 + cases 体，入口只 load cases 体）

新建 `tests/runner/sublime_mank_cases.gd` + 入口 `test_sublime_mank.gd`（命名沿 cd_pace 先例）。核心断言：

1. **普通路径零回归**：`skill_sublime=false` 时——倍率恒 1.5、`resolve` 返回值被忽略行为不变（击杀不喂层、不爆裂）、CD 120、`poison_nova` 计数口径不变。
2. **升华基础倍率**：0 层对单敌结算 = 面板 × 2.1。
3. **喂层分档与钳制**：毒爆击杀 N 只普通敌 → `_mank_essence == N`；带 `TAG_ELITE` +2、`TAG_BOSS` +5；总层不超 30。
4. **层数转化**：20 层时毒爆 = 面板 × (2.1 + 0.4)；30 层 = ×2.7。
5. **腐沼爆裂**：毒爆击杀者周围 140px 内存活敌各受面板 × 0.5；140px 外不受；同一目标处于多枚爆裂范围只结算**一次**（去重）；爆裂击杀的敌人**不再**产生新爆裂（深度 1）；爆裂击杀同样 +1 层。
6. **幂等键不撞**：同帧毒爆+爆裂打同一存活目标，管线 `dropped_dupe` 计数不增长（合成 UID 生效）。
7. **遗物乘区**：爆裂 ctx 经 `_inject_relic_pools` 注入（deps 含 relic_handler 时乘区生效；缺省零操作）。
8. **收口**：`_reset_skill_temp_state` 后 `_mank_essence == 0`；换角再回 mank 层数归零。
9. **无 pipeline 防御**：裸 Player 施放升华毒爆不报错、零爆裂零喂层。
10. **继续局语义**（对齐卡系统修订，见 3.1）：模拟暂停→继续（set_character 重建 + `_restore_run_state` 回填 `enable_sublime()`）后——`skill_sublime == true`（升华位保真；`"sublime"` 键往返保真断言归 r212_skillresume 套件）、`_mank_essence == 0`（层数清零）、下次施放倍率 = 面板 × 2.1（210% 基线）。
11. **测试体注意**（项目已知坑）：cases 体只由入口在 autoload 就绪后加载；不 add_child 池化敌节点——用非池夹具敌或真 GameLoop 拉起。

---

## 八、落地清单（项目惯例）

- [ ] 实现时按惯例取新 R 编号注释（沿 player.gd 现有 R### 风格），头注引用本文档路径。
- [ ] FEEDBACK_TRACKER.md 登记本条（技能升华 · mank 万毒噬界）。
- [ ] 卡牌系统侧按归一裁定落地：`skill_sublime: bool` + `enable_sublime()` 入口、HUD 红描边读口 `player.get("skill_sublime")`、`"sublime"` 存档键往返（前置依赖，见 5.1）。
- [ ] 数值表如有调档，同步本文 4.1/4.2（本文为设计真源）。
