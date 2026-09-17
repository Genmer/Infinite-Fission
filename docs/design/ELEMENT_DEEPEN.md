# 元素系统深化规划（元素免疫 / 数字元素配色 / 反应特效补全）

- 版本：v1.0（2026-09-18，R22）
- 来源：用户反馈「确认元素反应机制；反应触发有没有专属特效，新增；反馈数字改为对应元素颜色；
  新增机制如燃烧打火怪没用、冰冻无法冰冻冰怪；自己扩展」
- 关联：`scripts/combat/elemental/elemental_system.gd`（反应检测/结算）、
  `scripts/core/damage/damage_pipeline.gd`（⑧目标侧修正）、`scripts/ui/damage_popup.gd`（跳字配色）、
  `scripts/gamefeel/elemental_fx_layer.gd`（反应特效）

---

## 0. 现状盘点（调查结论）

| # | 现状 | 事实锚点 | 结论 |
|---|---|---|---|
| 1 | 三元素两两反应：碎裂（火+冰 ×2 点燃DOT总额）/ 过载（火+雷 120%ATK 90px 爆炸）/ 超导（冰+雷 全抗-30% 6s） | elemental_system.detect_reactions（帧末检测、反应 cd 2s、ELE_REACTION_VOID ×1.8 强化） | 机制完整 ✓ |
| 2 | 反应特效**只有碎裂有专属橙环**；过载/超导仅走 GameFeel 通用 CATALYST 档（无专属视觉） | elemental_fx_layer._on_reaction_triggered 仅处理 RXN_FIR_ICE | **缺口 → P3 补全** |
| 3 | 敌方 resist[-0.8,0.8] 减伤 + immune_mask（FREEZE/CHILL/BURN/SHOCK 状态免疫位）存在，但**无元素伤害免疫/吸收概念** | damage_pipeline ⑧ `target_factor = (1-resist)×(1+易伤)` | **缺口 → P1 元素免疫** |
| 4 | 跳字配色按「量级档」（白/蓝/紫/金），与命中元素无关；DamageResult.element 字段在册但未消费 | damage_popup.TIER_COLORS | **缺口 → P2 元素配色** |
| 5 | E9 冰霜仔已带 IMMUNE_FREEZE 位；E4 爆虫 FIR 抗 0.5 | resources/enemies/*.tres | 免疫标注数据基础就绪 |

---

## 1. P1 元素免疫机制（用户点名「燃烧打火怪没用 / 冰冻无法冰冻冰怪」）

### 1.1 数据层
- `GameConst` 新增位常量（bit = 1 << Element，KIN=0 无位 → **物理恒有效保底**）：
  - `ELEM_IMMUNE_FIR = 2`（bit1）/ `ELEM_IMMUNE_ICE = 4`（bit2）/ `ELEM_IMMUNE_LTG = 8`（bit3）
- `EnemyData` 新增 `@export var elem_immune: int = 0`（位掩码）；DataValidator 范围校验
  （`elem_immune & ~14 != 0` 报错——只允许 FIR/ICE/LTG 三位组合）
- `Enemy` spawn 期快照 + `is_elem_immune(p_element) -> bool` 查询口

### 1.2 结算层（管线 ⑧ 目标侧修正）
- 免疫命中：`target_factor = 0`（伤害归零）→ 跳字显示「免疫」灰字（PopupStyle.IMMUNE 新样式）
- 免疫命中**不结算元素附着**（点燃火怪不燃、冰弹不附冰）——由管线 9b 附着提交前置守卫 +
  ElementalSystem.apply_attachment 双重守卫
- 免疫命中无顿帧/无受击白闪（打不动就是打不动，反馈明确而非奖励打击感）

### 1.3 状态层
- 元素免疫附带状态免疫语义：FIR 免疫怪不进点燃（IMMUNE_BURN 位语义对齐）、
  ICE 免疫怪不进寒滞/冻结——immune_mask 位与 elem_immune 位在数据侧成对标注

### 1.4 配置（首发标注，刻意不含 Boss——避免构建被硬克）
| 怪 | 免疫 | 依据 |
|---|---|---|
| E4 爆虫（火虫） | FIR | 火属性自爆虫；immune_mask += IMMUNE_BURN |
| E8 恶魔小鬼（紫晶火鬼） | FIR | 魔域火鬼 |
| E9 冰霜仔（寒霜冰原） | ICE | 冰怪；immune_mask |= IMMUNE_CHILL（已有 FREEZE=1 → 3） |

Boss 不设元素免疫（E17 已有 ICE 抗 0.4、E18 后续可评），保多构筑可玩性。

---

## 2. P2 反馈数字元素配色（用户点名「反馈数字改为对应颜色」）

- 跳字颜色改为**元素色优先**：KIN 白 / FIR 橙（PopPalette.ENEMY 派生橙）/ ICE 淡冰蓝
  （PLAYER 派生）/ LTG 葡萄紫（SHOCK）
- 量级档保留：字号乘区（白/蓝/紫/金 ×1.0~1.6）+ 档音/档震不变——「颜色读元素、大小读暴击量级」
- DOT/REACTION/HEAL/XP 沿既有配色；免疫 = 新 PopupStyle.IMMUNE 灰蓝「免疫」字
- DamageResult.element → PopupManager → popup.show_popup 透传（池复位清零）

---

## 3. P3 反应专属特效补全（用户点名「新增一个」→ 三系补齐）

| 反应 | 现状 | 新增 |
|---|---|---|
| 碎裂 FIR+ICE | 橙色冲击环 ✓ | 保留 |
| 过载 FIR+LTG | 无专属 | **紫橙双环冲击**（火橙外环+雷紫内环，0.32s 扩散） |
| 超导 ICE+LTG | 无专属 | **冰紫雾环**（减益光环读感，0.5s 慢扩散+雾点） |

实现载体：ElementalFxLayer 既有 _rings 槽池扩展（按 rxn 选色/形状），零新节点类。

---

## 4. P4 测试锁定（test_elem_immune.gd）

1. 火伤打 FIR 免疫怪 → final=0 + result.immune + 不点燃（burn_timer=0）
2. 冰伤打 ICE 免疫怪 → final=0 + 不寒滞/不冻结
3. 物理打免疫怪 → 正常结算（物理保底）
4. 非免疫元素打同怪 → 正常（火打冰霜仔照常）
5. 免疫命中跳字 = IMMUNE 样式「免疫」；跳字元素色 = 元素映射
6. 反应过载/超导触发 → FX 层对应槽池激活
7. 回归：全量套件无破坏

---

## 5. 明确不做（防 scope 膨胀）
- 不新增第四元素（毒未元素化——沼泽毒走直结算通道，单独立项）
- 不给 Boss 上元素免疫（构建硬反制风险；Boss 用既有 resist/immune_mask 表达）
- 不做元素吸收转治疗（原神式）——免疫即归零，反馈最直白
