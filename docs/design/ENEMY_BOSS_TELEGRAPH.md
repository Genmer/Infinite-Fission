# BOSS/精英攻击模式与全游戏预警（Telegraph）体系

- 版本：v1.0（2026-09-13）
- 适用：Godot 4.3 竖屏 720×1280《核式裂变乐园》
- 真源关系：本文是 `META_ROADMAP.md` P1 待办「聚合体/Boss 弹幕攻击」与「Boss 击退闪退」的实现规格；数值口径沿用 `docs/analysis/A3_numbers.md`（玩家基准 HP 60）与 `resources/enemies/*.tres` 既有 `boss` 字段结构。
- 代码锚点：
  - `scripts/entities/enemy/enemy.gd`：Enemy / FuseRing（爆虫警示圈）/ PoisonSplash（毒圈）/ `_check_boss_phase()`（现有 50% 二阶段）/ `knockback()`（击退闪退根因）/ `_tick_boss()`（二阶段变脸+卫星公转）
  - `scripts/core/data/resources/enemy_data.gd`：`boss: Dictionary`（已有 `phases / bullet_patterns / summons / charge / phase2_resist`）
  - `scripts/combat/projectile/projectile_base.gd`：敌弹 `team=1`，`_check_player_hit()` → `player.take_contact_damage(base_atk)`
  - `scripts/gamefeel/game_feel_director.gd`：`request_hit_stop()`（HIT 0 / CRIT 30 / CATALYST 50 / BOSS_DEATH 120 ms）
  - `scripts/gamefeel/sfx_bank.gd`：`play(name)`（70ms 节流，可扩音色）
  - `scripts/ui/boss_bar.gd`：血条 + 相位点 + 登场横幅

---

## 0. 现状盘点与核心问题

| # | 现状 | 问题 | 本文对策 |
|---|------|------|---------|
| 1 | Boss（E6_boss1~3 / E17~20）只有 CHASE 追击，`boss.bullet_patterns` 数据在 .tres 里但无消费者 | Boss 零弹幕压力，Boss 战=「追着打靶」 | §3 技能库 + §5 barrage 配置 + `_tick_boss_barrage()` 消费者 |
| 2 | Boss 被近战击退 `knockback()` 即时位移，一巴掌拍出半屏 | 俗称「闪退」，节奏崩坏 | §7 质量分级击退（Boss 位移×0） |
| 3 | 非触碰伤害源仅爆虫自爆有警示圈（FuseRing）；E12 毒爆无前摇预警 | 预警语言不统一 | §2 全游戏 telegraph 总规范（含存量收编） |
| 4 | Boss 阶段只有 50% 二阶段（全抗 +0.2 + 变脸） | 阶段感弱 | §4 三阶段模板（60%/30%） |
| 5 | 所有 Boss `immune_mask` 均含 IMMUNE_FREEZE(=1)，F-17 定身免疫已置位 | 「冻结打断 Boss 技能」此路不通 | §3 打断统一走「韧性条」；冻结打断只对精英/小怪词缀技生效 |

玩家侧硬约束（数值前提）：
- 基准 HP **60**（`player_base_hp`，AFF_HP_UP 每层 +25 ×4 层 → 满配 160）。
- 玩家命中盒半径 16px；受击后无敌帧 `contact_tick = 0.6s`，敌弹走 `take_contact_damage` **共享同一无敌帧通道** → 0.6s 内多发命中只结算 1 发。本表所有「伤害」都受此保护，允许单发数值偏高。
- 玩家 1:1 拖动，全屏瞬时重定位 → 弹幕压力应来自**区域封锁与走位限制**，弹速取中低值即可，过快反而不可读。

---

## 1. 预警（Telegraph）体系总规范

### 1.1 铁律：所有非触碰伤害必有预警

- **触碰伤害**（敌人本体 Area2D 接触）是唯一豁免项，受 0.6s 无敌帧节流兜底。
- **其余一切伤害源**（敌弹、爆炸、激光、地雷、毒区、召唤物入场冲击等）在结算前必须有可见前摇。
- 落地为两层防线：
  1. **Schema 校验**：`DataValidator` 对 `EnemyData.boss.barrage[]` 与精英 `elite_affix` 逐条断言——缺 `telegraph` / `telegraph_s` 字段即报错拒绝加载；
  2. **代码契约**：所有伤害结算 API 必须由「预警完成回调」触发（`Telegraph.finished → _fire()`），不存在绕过预警直接结算的入口。
- 存量收编：E4 爆虫（FuseRing 1.2s）已合规；E12 死亡毒爆为「死亡即时释放」，归属尸体惩罚类，补一圈 0.38s 收束毒环（现 PoisonSplash 渲染扩用）即可视为预警；新伤害源一律走 §1.2 组件。

### 1.2 统一前摇语言（四类警示件 + 色彩语义）

| 警示件 | 形态 | 色彩语义 | 使用场景 |
|--------|------|---------|---------|
| **地面警示圈** TelegraphCircle | 虚线圆 + 淡填充 + 进度弧（FuseRing 同款程序化绘制，泛化半径/颜色/进度） | **红** (1.0, 0.36, 0.36) = 爆炸/定点 AOE；**橙** (1.0, 0.62, 0.2) = 冲撞落点；**金** (1.0, 0.85, 0.3) = 召唤（信息性，非伤害）；**绿**（PoisonSplash 现配色）= 持续毒区 | 爆虫自爆、地雷落点、毒池、召唤阵、狂暴冲击 |
| **直线警示带** TelegraphLine | 矩形长带，端点起自施法者，宽度=判定线宽；进度=沿带充能流动 | **紫** (0.7, 0.5, 1.0) = 狙击线/激光 | 藤蔓横扫、激光扫场、直射狙击 |
| **扇形警示** TelegraphFan | 扇面（圆弧 + 两半径边），随 Boss 朝向锁定 | **橙** = 冲撞方向；**紫** = 扇形狙击 | 扇射、冲锋方向条 |
| **本体闪色/膨胀** TelegraphSwell | 本体 self_modulate 闪红 + scale 膨胀（复用爆虫 `grow = 1 + 0.5·prog²` 二次缓动语言，上限 ×1.35） | 闪红=即将齐射；膨胀幅度=技能量级 | ring/spiral 齐射前摇 |

色彩纪律：红/橙/紫/金/绿五色**只**表达上表语义，全局不混用；同一技能的前摇色 = 结算表现色（红圈爆红花、紫线放紫激光），玩家可建立「颜色→后果」条件反射。

### 1.3 三档时长（全局唯一档位表）

| 档位 | 时长 | 适用 | 附加表现 |
|------|------|------|---------|
| **快** | **400ms** | 高频低伤技（环形、高速直射）、精英词缀技 | 本体膨胀 ×1.2 + 闪红 1 次；释放瞬间 `request_hit_stop(30)`（CRIT 档）+ `sfx_cast_snap` |
| **标准** | **700ms** | 默认档：扇射、地雷、旋转火舌、精英召唤 | 警示件进度弧完整走完；释放 30ms 顿帧 + `sfx_telegraph_warn`（出现时）|
| **慢** | **1000ms** | 处决级/全屏级：激光扫场、三段冲锋每段、Boss 召唤、狂暴触发 | 出现 `sfx_laser_charge`（或 warn 加深）；释放 50ms 顿帧（CATALYST 档）+ 震屏 trauma 0.4 |

- 狂暴（P3）期间所有前摇 **×0.85**，下限 340ms（保证最速反应窗）。
- 前摇计时走 **game_delta 通道**（与爆虫 FuseRing 同口径）：顿帧/冻结/暂停时预警与技能计时自然停摆——Boss 被冻结期间不发弹、不动预警，天然公平。
- 音效一律过 `SfxBank.play()`（70ms 节流内置防刷屏）。

### 1.4 实现载体

- 新组件 `scripts/entities/enemy/telegraph.gd`：`TelegraphCircle / TelegraphLine / TelegraphFan`（程序化 `_draw()`，挂 Boss 或世界层，绘制序遵守「禁 z_index 负值」现状——按添加顺序压在敌人之上，可读性优先）。
- **TelegraphCircle 直接由 FuseRing 泛化而来**：抽 `radius / color / progress` 三参，爆虫调用点改为泛化件（零行为变化，pkg 验收锁定）。
- Boss 施法状态机并入 `Enemy`：`cast_id / cast_left / casting` 三状态位；`_tick_boss_barrage()` 在 CHASE 分支内调用（roadmap 原案），**不改 behavior、与 fire_range 语义解耦**（追击中齐射）。
- 敌弹统一走 `ProjectilePool.acquire()` + `spawn({velocity, lifetime:5.0, pierce:1, bounces:0, hitbox_radius:5.0, team:1, panel_snapshot:{base_atk}})` 既有通道，伤害 = `panel_snapshot.base_atk`。

---

## 2. Boss 弹幕技能库（B1~B8）

伤害列 = 对基准 60 HP 的百分比（括号内为 .tres `dmg` 平值 = 60 × pct）。所有技能受玩家 0.6s 无敌帧保护。

| ID | 技能 | 型（barrage type） | 前摇表现与时长 | 弹幕参数 | 伤害 | 冷却 | 打断 |
|----|------|--------------------|----------------|----------|------|------|------|
| B1 | 聚能环爆 | `ring` | 本体膨胀 ×1.35 + 闪红，**400ms** | 360° 均匀环；count 18~26；speed 165~210 px/s；1 波 | **12%**（7） | 5.0~6.0s | 韧性条 |
| B2 | 锁定扇射 | `aimed_spread` | 扇形警示（紫，44°±），锁定玩家当前位置，**700ms** | count 5~7；speed 330~360；扇心=前摇结束瞬间朝向（前摇内不追踪）；waves 1~2（波间隔 0.25s） | **22%**（13） | 4.5s | 韧性条；精英版可被**冻结**打断 |
| B3 | 旋转火舌 | `spiral` | 本体膨胀 + 双卫星球亮起，**700ms** | 双臂（P3 三臂）；每 0.09s 每臂 1 发；步进 15~17°/发；持续 2.4~2.6s；speed 200~240 | **10%**（6） | 8~9s | 韧性条 |
| B4 | 裂变召唤 | `summons`（既有 key） | Boss 脚下金圈 + 小怪预生成虚影，**1000ms** | 沿用现有 schema（interval_s / enemy_id / hp_ratio 0.08 / count 2~4）；**在场小怪上限 4**，超上限跳过 | 无直接伤害（小怪自带接触伤害） | 9~12s | 不可打断；冻结期计时停摆 |
| B5 | 破裂冲锋 | `charge`（既有 key，扩展） | 每段：橙向条 + 本体压扁 0.78（复用 E2 疾冲 telegraph 语言），**400ms/段 ×3 段** | speed 520~580 px/s；0.45s/段；段间回弹 0.55s；方向=前摇末采样锁定；撞界/贴身提前收势（E2 现行逻辑） | **35%**（21，接触通道） | 9s | **段与段之间**被冻结 → 取消剩余段数（Boss 免疫定身不改：冻结只在段间隙窗口生效的规则例外走 chill 判定，见 §2.1） |
| B6 | 荆棘雷区 | `mine` | 每颗落点红圈（半径=爆半径）缩圈，**700ms** | count 5~8；以 Boss 前方扇区 + 玩家预测位混合布点；触发半径 42；爆炸半径 90；落地 0.8s 激活；存活 8s；**可被玩家弹幕打爆**（HP=1，无连锁伤害，不伤 Boss） | **35%**（21） | 10~12s | 韧性条 |
| B7 | 湮灭扫线 | `laser_sweep` | **紫色直线警示带 1000ms**（锁定起角，带内不追踪），端点自 Boss | 起 0°→扫 100~120°；扫完 1.6~1.8s（≈65°/s）；判定线宽 26px；命中=0.6s 一次 | **50%**（30，处决级） | 11~13s | **不可打断**（处决技，韧性条对 B7 无效——给玩家保留 1 个「必须走位」的绝对命题） |
| B8 | 狂暴化 | `enrage`（新 key，阈值触发非冷却技） | 登场横幅复用（BossBar banner）+ **120ms 顿帧**（BOSS_DEATH 档）+ 变脸贴图（复用 `_boss_angry`）+ 全身红染 2s | cd ×0.8、弹速 ×1.2~1.25、齐射频率 ×1.3、前摇 ×0.85 | — | 血量 **30%** 触发，**一次性**（`enrage_done` 锁存，防回血词缀循环） | — |

### 2.1 打断规则统一裁定

- **Boss 免疫冻结是既定事实**（E17=3 / E18=5 / E19=1 / E20=1 全部含 IMMUNE_FREEZE）。因此 Boss 技能打断**不走冻结**，走 **韧性条（Poise）**：
  - Boss 受击积累韧性伤害 = `final_value × 0.01`；韧性条满 → **硬直 1.2s**：当前前摇取消（警示件收起）、cd 退 50%、韧性条清空并进入 6s 韧性免疫；
  - 数值锚点：玩家 DPS ~500 基准下 ≈10s 打满一次，Boss 战节奏 =「每 10 秒一次主动压制窗口」，DPS 越高打断越频繁（奖励输出）。
  - B7 激光免疫韧性打断。
- **精英/小怪词缀技可被冻结打断**（精英默认不带 IMMUNE_FREEZE）：冻结瞬间若在 telegraph 期 → 技能取消、cd 退 50%。这是「冰系控制流」对精英的差异化价值。
- 所有打断统一入口 `Enemy.cancel_cast()`（清 cast 状态 + 警示件收起），冻结打断与韧性硬直共用。

---

## 3. Boss 战阶段模板

`_check_boss_phase()` 扩展为三档：阈值读 `boss.phase2_hp`（默认 0.6）/ `boss.phase3_hp`（默认 0.3）；草原 E6 系列可退化两阶段（`phases:2, phase2_hp:0.5`，兼容现状）。

| 阶段 | 血量 | 行为模板 | 技能池 | 表现 |
|------|------|---------|--------|------|
| **P1 引入期** | 100% → 60% | 追击 0.85× 速（留输出窗口），2 个基础技轮换 | B1 + B2（各 Boss 微调型） | 相位点 1 亮；标准前摇 |
| **P2 压制期** | 60% → 30% | 追击 1.0× 速；**新增专属技 1~2 个**；全抗 +0.2（既有 `phase2_resist`） | P1 全部 + B3 / B5 / B6 / B7（按主题，见 §5） | 相位点 2 亮 + 怒相变脸（既有）+ 卫星公转提速（既有 `_tick_boss`） |
| **P3 狂暴期** | 30% → 0% | **B8 触发**；全技能池 + cd ×0.8；前摇 ×0.85 | 全部 | 横幅 + 120ms 顿帧 + 红染；弹幕密度峰值 |

设计原则：
1. **每阶段恰好新增 1~2 件新事物**——玩家在 P1 学会本体语言，P2 学主题技，P3 只经历「密度放大」而非新机制（降低学习曲线）。
2. 阶段切换瞬间：清空当前 cast、全部技能 cd 重置为 `max(cd×0.5, 1.5s)`（防止切阶段瞬间无缝连放）。
3. P3 狂暴后**不再新增机制**，只做数值放大——死血阶段是执行考而非学习考。

---

## 4. barrage 配置 Schema（.tres 直接可抄）

`EnemyData.boss` 字段扩展（`scripts/core/data/resources/enemy_data.gd` 注释同步更新）：

```
boss = {
  "phases": 2|3,
  "phase2_hp": 0.6,          # 阶段2 阈值（缺省 0.6；E6 系列填 0.5 兼容现状）
  "phase3_hp": 0.3,          # 阶段3 阈值（phases==3 必填）
  "phase2_resist": 0.2,      # 既有
  "barrage": [               # 新增：弹幕技能数组（消费端 _tick_boss_barrage）
    {"type": "ring|aimed_spread|spiral|mine|laser_sweep",
     "id": "frost_lock",      # 可选，同型多技时区分
     "phase": 1,              # 起用阶段（≥该阶段可用）
     "cd": 5.0,               # 冷却 s（P3 ×enrage.cd_mult）
     "telegraph": "swell|circle|line|fan",
     "telegraph_s": 0.4,      # 0.4 / 0.7 / 1.0 三档
     "count": 22,             # 弹数/雷数（可选 count_phase2/3 覆写）
     "speed": 190.0,          # px/s
     "dmg": 7.0,              # 平值 = 60 × pct（DataValidator 按 pct∈[8,50] 校验）
     "arc_deg": 44.0,         # aimed_spread 扇角 / laser_sweep 扫角
     "waves": 1, "wave_gap_s": 0.25,
     "step_deg": 17.0,        # spiral 步进
     "emit_s": 2.6,           # spiral 持续
     "arms": 2,               # spiral 臂数（P3 +1）
     "trigger_r": 42.0, "blast_r": 90.0, "arm_s": 0.8, "life_s": 8.0,   # mine
     "width_px": 26.0, "sweep_s": 1.6,                                  # laser_sweep
     "flavor": "frost|venom|thorn",                                     # 主题皮（仅表现）
     "poison_pool": {"radius": 85.0, "life_s": 6.0, "dps_pct": 8.0},    # 毒皮附加
     "slow_pool": {"radius": 70.0, "life_s": 2.5, "drag_mult": 0.65}}   # 冰皮附加
  ],
  "summons": {...},          # 既有
  "charge": {"segments": 3, "seg_time": 0.45, "gap_s": 0.55,
             "telegraph_s": 0.4, "dmg_pct": 35.0, ...},   # 既有 key 扩展
  "enrage": {"hp_threshold": 0.3, "cd_mult": 0.8,
             "speed_mult": 1.25, "rate_mult": 1.3}
}
```

**旧字段迁移**：`bullet_patterns`（interval_s/pattern 单条式）→ 读入时折算为 `barrage[0]`（pattern 映射 ring/fan→ring|aimed_spread/spiral），`DataValidator` 对含 `bullet_patterns` 的新改动告警（存量 tres 由本表 §5 直接替换，不留双轨）。

性能预算：同屏敌弹峰值 ≤ **120**（当前池按需获取 + `force_recycle_oldest()` 兜底已就绪）；spiral 长喷与 ring 叠加时优先回收 `lifetime` 最长者。

---

## 5. 四主题（+草原）Boss 配置表

> 以下为**直接可抄进 .tres 的 `boss` 段**。dmg 均为 60HP 基准平值；弹速 px/s；cd 秒。

### 5.1 草原 · E6_boss1~3 聚合体（教学级，两阶段，无狂暴）

主题：最小技能集教会玩家全部前摇语言。E6_boss2/3 复制后 cd ±0.3s、count ±2 微调。

```
boss = {"phases": 2, "phase2_hp": 0.5, "phase2_resist": 0.2,
  "barrage": [
    {"type": "ring", "phase": 1, "cd": 6.0, "telegraph": "swell", "telegraph_s": 0.4, "count": 14, "count_phase2": 20, "speed": 170.0, "dmg": 7.0},
    {"type": "aimed_spread", "phase": 2, "cd": 5.0, "telegraph": "fan", "telegraph_s": 0.7, "count": 3, "speed": 330.0, "arc_deg": 30.0, "dmg": 13.0}
  ],
  "summons": {"interval_s": 12.0, "enemy_id": "E1_grunt", "count": 4}
}
```

### 5.2 冰原 · E17 霜魄君王（15800 HP / spd 55）——慢速减速弹幕 + 冰锁

主题：弹多、速慢（165~200），伤害在「冰锁圈」里。冰锁弹命中在落点生成减速场（拖动映射 ×0.65，P3 接 player 消费点）。

```
boss = {"phases": 3, "phase2_hp": 0.6, "phase3_hp": 0.3, "phase2_resist": 0.2,
  "barrage": [
    {"type": "ring", "phase": 1, "cd": 5.0, "telegraph": "swell", "telegraph_s": 0.4, "count": 22, "speed": 180.0, "dmg": 7.0, "flavor": "frost"},
    {"type": "aimed_spread", "phase": 1, "cd": 4.5, "telegraph": "fan", "telegraph_s": 0.7, "count": 5, "speed": 340.0, "arc_deg": 40.0, "waves": 2, "wave_gap_s": 0.25, "dmg": 13.0, "flavor": "frost"},
    {"type": "spiral", "phase": 2, "cd": 9.0, "telegraph": "swell", "telegraph_s": 0.7, "arms": 2, "step_deg": 17.0, "emit_s": 2.6, "speed": 205.0, "dmg": 6.0, "flavor": "frost"},
    {"type": "aimed_spread", "id": "frost_lock", "phase": 3, "cd": 10.0, "telegraph": "fan", "telegraph_s": 1.0, "count": 1, "speed": 260.0, "dmg": 21.0, "flavor": "frost", "slow_pool": {"radius": 70.0, "life_s": 2.5, "drag_mult": 0.65}}
  ],
  "summons": {"interval_s": 10.0, "mode": "split", "enemy_id": "E9_frostling", "hp_ratio": 0.08, "count": 2, "count_phase2": 3},
  "enrage": {"hp_threshold": 0.3, "cd_mult": 0.85, "speed_mult": 1.2, "rate_mult": 1.25}
}
```

### 5.3 魔域 · E18 熔核魔尊（16740 HP / spd 68）——高速弹幕 + 召唤 + 三连冲锋

主题：压迫感来自**弹速**（430）与**本体冲锋**；既有 `charge` key 升级为三连段。

```
boss = {"phases": 3, "phase2_hp": 0.6, "phase3_hp": 0.3, "phase2_resist": 0.2,
  "barrage": [
    {"type": "aimed_spread", "phase": 1, "cd": 3.6, "telegraph": "fan", "telegraph_s": 0.4, "count": 3, "speed": 430.0, "arc_deg": 18.0, "dmg": 13.0},
    {"type": "ring", "phase": 2, "cd": 6.5, "telegraph": "swell", "telegraph_s": 0.4, "count": 18, "speed": 210.0, "dmg": 7.0},
    {"type": "spiral", "phase": 2, "cd": 8.0, "telegraph": "swell", "telegraph_s": 0.7, "arms": 3, "step_deg": 13.0, "emit_s": 2.4, "speed": 240.0, "dmg": 6.0}
  ],
  "summons": {"interval_s": 9.0, "mode": "split", "enemy_id": "E8_imp", "hp_ratio": 0.08, "count": 3, "count_phase2": 4},
  "charge": {"phase": 2, "spd": 560.0, "segments": 3, "seg_time": 0.45, "gap_s": 0.55, "telegraph_s": 0.4, "dmg_pct": 35.0},
  "enrage": {"hp_threshold": 0.3, "cd_mult": 0.8, "speed_mult": 1.25, "rate_mult": 1.3}
}
```

### 5.4 树海 · E19 古树守卫（15320 HP / spd 45）——藤蔓狙击线 + 荆棘种荚

主题：本体慢（spd 45），压力来自**藤蔓横扫线**（P1 即上线，本图签名技）与种荚地雷的区域封锁。藤蔓扫线留毒尾迹（P3）。

```
boss = {"phases": 3, "phase2_hp": 0.6, "phase3_hp": 0.3, "phase2_resist": 0.2,
  "barrage": [
    {"type": "ring", "phase": 1, "cd": 5.5, "telegraph": "swell", "telegraph_s": 0.4, "count": 20, "speed": 165.0, "dmg": 7.0, "flavor": "thorn"},
    {"type": "laser_sweep", "phase": 1, "cd": 11.0, "telegraph": "line", "telegraph_s": 1.0, "arc_deg": 100.0, "sweep_s": 1.6, "width_px": 26.0, "dmg": 30.0, "flavor": "vine"},
    {"type": "mine", "phase": 2, "cd": 12.0, "telegraph": "circle", "telegraph_s": 0.7, "count": 6, "count_phase3": 8, "trigger_r": 42.0, "blast_r": 90.0, "arm_s": 0.8, "life_s": 8.0, "dmg": 21.0, "flavor": "thorn"},
    {"type": "aimed_spread", "phase": 2, "cd": 5.0, "telegraph": "fan", "telegraph_s": 0.7, "count": 5, "speed": 330.0, "arc_deg": 38.0, "dmg": 13.0}
  ],
  "summons": {"interval_s": 9.0, "mode": "split", "enemy_id": "E12_bogslime", "hp_ratio": 0.08, "count": 2, "count_phase2": 3},
  "enrage": {"hp_threshold": 0.3, "cd_mult": 0.85, "speed_mult": 1.15, "rate_mult": 1.2}
}
```

### 5.5 沼泽 · E20 九头沼龙（16480 HP / spd 50）——毒区 + 毒泡地雷

主题：**持续区域**压制（毒池吃 8%/0.5s），毒泡雷爆炸后留毒潭；P3 扫线拖毒尾。

```
boss = {"phases": 3, "phase2_hp": 0.6, "phase3_hp": 0.3, "phase2_resist": 0.2,
  "barrage": [
    {"type": "ring", "phase": 1, "cd": 5.0, "telegraph": "swell", "telegraph_s": 0.4, "count": 24, "speed": 185.0, "dmg": 7.0},
    {"type": "mine", "phase": 1, "cd": 10.0, "telegraph": "circle", "telegraph_s": 0.7, "count": 5, "count_phase2": 7, "trigger_r": 42.0, "blast_r": 95.0, "arm_s": 0.8, "life_s": 8.0, "dmg": 21.0, "flavor": "venom", "poison_pool": {"radius": 85.0, "life_s": 6.0, "dps_pct": 8.0}},
    {"type": "aimed_spread", "phase": 2, "cd": 4.5, "telegraph": "fan", "telegraph_s": 0.7, "count": 7, "speed": 330.0, "arc_deg": 50.0, "waves": 2, "wave_gap_s": 0.25, "dmg": 13.0},
    {"type": "laser_sweep", "phase": 3, "cd": 13.0, "telegraph": "line", "telegraph_s": 1.0, "arc_deg": 110.0, "sweep_s": 1.8, "width_px": 26.0, "dmg": 30.0, "flavor": "venom", "poison_pool": {"radius": 40.0, "life_s": 3.0, "dps_pct": 8.0}}
  ],
  "summons": {"interval_s": 10.0, "mode": "split", "enemy_id": "E13_bogspitter", "hp_ratio": 0.08, "count": 2, "count_phase2": 3},
  "enrage": {"hp_threshold": 0.3, "cd_mult": 0.8, "speed_mult": 1.2, "rate_mult": 1.3}
}
```

---

## 6. 精英词缀 = Boss 技能的弱化版

`EnemyData` 新增 `@export var elite_affix: StringName`；E5_elite 模板复用 `elite_mult` 数值乘区不变，词缀只加「一个弱化技」。词缀技前摇一律 **+150ms**（精英血量低，读技窗口要更宽），伤害沿用平值。

| 词缀 | 复用 | 弱化参数 | 前摇 | 打断 |
|------|------|---------|------|------|
| 环爆体 affix_ring | B1 | count 8 / speed 170 / dmg 12%（7）/ cd 7s | swell 550ms | 冻结 ✓ |
| 狙击手 affix_sniper | B2 | count 3 / arc 24° / speed 300 / dmg 18%（11）/ cd 6s | fan 850ms | 冻结 ✓ |
| 冲锋者 affix_charger | B5 | 单段 / spd 1.9× 自身（直接复用 E2 疾冲状态机）/ dmg 25%（15） | 压扁 450ms（E2 现行 0.3s+0.15） | 冻结 ✓ |
| 布雷者 affix_trapper | B6 | count 2 / blast 80 / dmg 25%（15）/ cd 9s | circle 850ms | 冻结 ✓ |
| 唤潮者 affix_caller | B4 | 1 只 / hp_ratio 0.5 / cd 14s / 在场上限 2 | 金圈 1150ms | 冻结 ✓ |
| ~~扫线~~ / ~~狂暴~~ | B7/B8 | **永不下发精英**（处决级与形态级机制是 Boss 专属威慑） | — | — |

投放节奏：词缀精英 wave 8+ 开始出现（1 词缀），无尽模式 wave 15+ 可双词缀（互斥对：charger×trapper 禁叠）。冷却共享独立计时器（不与 Boss 系统冲突），词缀技伤害受玩家 0.6s 无敌帧同口径。

---

## 7. 附带修复：Boss 击退「闪退」（质量分级免疫）

根因：`Enemy.knockback()` 对所有敌人做 `global_position += p_force` 即时位移，Boss hitbox_r=14 与小怪无异。

修复（roadmap「按质量分级」裁定）：

```
func knockback(p_force: Vector2) -> void:
    var mult := 1.0
    if is_boss():        mult = 0.0    # Boss：位移免疫（含 TAG_FINAL_BOSS）
    elif is_elite():     mult = 0.3    # 精英：30% 位移
    global_position += p_force * mult
    if mult > 0.0 and _fuse_armed:
        _cancel_fuse()                 # 击退打断自爆仅对可位移单位（爆虫是小怪，不受影响）
    # Boss 位移免疫但保留受击 wobble（现有表现层已覆盖）→ 近战打击感不丢失
```

验收锚：近战满配连打 Boss，Boss 中心点位移 ≤ 2px/次；E2/E4 行为回归不变。

---

## 8. 参考与借鉴

### 8.1 吸血鬼幸存者（Vampire Survivors）
- 其「死神/Reaper」体系**几乎不做可躲弹幕**：超速贴脸 + 即死级接触压力，反制靠构筑（Crimson Shroud 10 点伤害帽）而非操作。
- 可借鉴：**压力分层**——本作 Boss 弹幕不需要「全躲掉」，B7 处决线+狂暴密度即「Reaper 位」，允许玩家用走位+构筑双通道解题；最终 Boss（The Director）的三阶段「新攻击引用旧 Boss 招式」结构印证本表 §3「P2 才上主题技」的节奏。
- 不照搬：VS 的无预警即死接触与本作「铁律」冲突，本作保持全预警。

### 8.2 土豆兄弟（Brotato）
- 精英/隐藏 Boss 的攻击全部走**地面危险区（红/橙圈）**，社区共识是「移速 ≥20 后大多数 Boss 攻击可躲」——**速度是通用的躲技货币**。本作拖动 1:1 操控下玩家「速度」无限，因此本表用**弹速 165~430 px/s + 前摇时长**而非玩家速度做难度旋钮（§0 硬约束）。
- Brotato wave11 精英比 wave20 最终 Boss 体感更难（构筑时序问题）→ 本作词缀精英锁定 wave 8+ 且强度按「当前波构筑均值」校准，避免中期断崖。
- 可借鉴：精英掉落保底传说箱（对应本作 REL_BOSS_TROPHY / 经验碎片雨已有），词缀精英追加掉落金袋 +0.5% 概率遗物。

### 8.3 弓箭传说（Archero）
- 教科书级**红线预警**：Boss 出招前地面先画红线/红圈（如龙卷风三连红线），「攻击序列 → 停顿 → 重复」的**固定循环**让玩家背版。
- 可借鉴三点：① 前摇与弹道**1:1 同形同色**（红线画在哪弹飞哪）——本表 §1.2「前摇色=结算色」的来源；② 循环固定 + 波间隔恒定，支持背版——本表各技能 cd 固定不随机化；③ 站定射击的博弈 = 本作拖动 1:1 的对应物：**走位窗口由前摇档位给足，攻击永远自动**。
- 参考：Archero 端游 Boss 攻击循环平均 2.5~4s 一轮，与本表 cd 4.5~6s + 移动追加技的密度相当。

### 8.4 综合落点
| 借鉴 | 落进本表 |
|------|---------|
| VS 压力分层 | B7 处决线 + P3 狂暴 = 构筑/操作双解 |
| Brotato 速度货币 | 换轴为「弹速+前摇」难度旋钮 |
| Archero 同形同色 | §1.2 色彩纪律三色法 |
| Archero 固定循环 | 全技能 cd 定值、前摇三档定值，不掷随机 |

---

## 9. 分阶段实装计划

### P1 —— 弹幕三件套 + 预警圈复用 + 击退修复（地基）
**范围**：`_tick_boss_barrage()`（ring / aimed_spread / spiral 三型）+ TelegraphCircle（FuseRing 泛化）+ TelegraphSwell + B8 之外的施法状态机 + §7 击退分级 + DataValidator barrage 必填校验 + §5.1/5.2/5.3 的 .tres 更新（P1 只上 phase 1 技）。
**验收要点**：
1. E6_boss1 / E17 / E18 在 30% 血以上至少各出 1 次 ring/aimed_spread，弹数与 arc 误差 ≤1 发/1°（pkg 用例断言齐射 count/角度分布）；
2. 敌弹 team=1 命中走 0.6s 无敌帧：0.6s 内多弹只扣 1 次（soak 用例）；
3. Boss 击退位移=0、精英 30%、E2/E4 回归不变（既有 runner 用例 + 新增 3 断言）；
4. DataValidator：barrage 条目缺 telegraph/telegraph_s/dmg 越界（pct 8~50）→ 报错；
5. 冻结 Boss 期间无新弹、无预警推进（game_delta 通道验证：顿帧注入测试）；
6. 同屏敌弹峰值 ≤120（perf 用例：P3 双 Boss 压力场景）；
7. dmg 平值与 pct 换算表一致（7/13/6 三值抽查）。

### P2 —— 扫场 / 地雷 / 主题皮（空间封锁）
**范围**：TelegraphLine + TelegraphFan 组件、laser_sweep、mine（可打爆/毒池/减速池）、B5 三连冲锋（E18）、flavor 主题皮、§5.4/5.5 全量 .tres、SfxBank 4 新音色。
**验收要点**：
1. 警示带 1000ms 内路径锁定不追踪玩家（用例：前摇中横移玩家，扫线起终点不变）；
2. 扫线命中每 0.6s 结算一次（贴线站桩 3s = 5 次伤害）；
3. 地雷可被玩家弹引爆、不伤 Boss、毒池 tick 0.5s 复用 PoisonSplash 渲染；
4. E18 三连冲锋：3 段完整、撞界收势、段间隙被冻结 → 剩余段取消；
5. 音效三档齐备且 70ms 节流不炸耳（手动 + 遥测计数）；
6. 出屏弹幕 1.5 屏距强制回收（防池耗尽）。

### P3 —— 阶段狂暴 + 韧性打断 + 词缀复用（深度）
**范围**：三阶段阈值（60/30）+ B8 enrage + 韧性条（积累/硬直/免疫窗）+ `cancel_cast()` 统一打断 + 精英词缀五件套与投放节奏 + BossBar 相位点 2/3。
**验收要点**：
1. 60%/30% 两次阶段切换各触发一次：变脸 + 相位点 + cd 重置（不无缝连放）；
2. enrage 一次性锁存：血量不再回升（若未来加回血词缀，重复跨阈值不重复触发）；
3. 韧性条：DPS 500 基准 ≈10s 一硬直，硬直 1.2s 取消当前 cast、退 cd 50%、B7 免疫；
4. 词缀精英 wave 8+ 出现、词缀技前摇 +150ms、冻结可打断（精英无 IMMUNE_FREEZE 断言）；
5. 全量回归：500 敌 100 弹压力场景帧耗时无劣化（现有 perf 基线 ±5%）；
6. 五 Boss 全流程通关遥测：P3 平均时长 ≤ P1+P2 时长之和的 50%（狂暴期应是收尾而非耗血库）。

---

## 附：数值速查卡

| 项 | 值 |
|----|----|
| 玩家基准 HP / 无敌帧 | 60 / 0.6s（敌弹共享） |
| 弹幕伤害档 | 12%（7）轻弹 · 22%（13）标准 · 35%（21）重击 · 50%（30）处决 |
| 弹速区间 | 165~430 px/s（主题：冰最慢、魔域最快） |
| 前摇三档 | 400 / 700 / 1000 ms（狂暴 ×0.85，下限 340ms） |
| 弹幕 hitbox / lifetime | 5px / 5s |
| 敌弹池预算 | 同屏 ≤120 |
| 顿帧 | 释放 30ms / 激光 50ms / 狂暴 120ms |
| Boss HP（现状保留） | E6 5324 / E17 15800 / E18 16740 / E19 15320 / E20 16480 |
