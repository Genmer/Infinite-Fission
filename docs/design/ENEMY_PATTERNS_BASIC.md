# 普通怪与精英怪攻击模式体系（Behavior Family / Elite Affix）

> 文档定位：**普通怪（小怪 + 精英模板）的行为族与攻击模式设计真源**。
> 状态：设计定稿（待实装）。关联真源：A3 数值表、`docs/design/ENEMY_BOSS_TELEGRAPH.md`（下称 Boss 文档）、
> `scripts/entities/enemy/enemy.gd`、`scripts/core/data/resources/enemy_data.gd`、`resources/waves/wave_table_main.tres`。
> 数值口径：玩家基准 HP **60**、无敌帧 0.6s；伤害一律写成「百分比（平值）」，平值 = 百分比 × 60 取整。
> 波次成长沿用既有四条曲线（HP ×1.12^w、DMG ×1.06^w、SPD 线性 +0.8%/波、EXP ×1.085^w，`GameConfig.balance`）。

---

## 0. 现状盘点与核心问题

| 现状 | 事实（代码锚点） |
|---|---|
| 行为枚举 | `GameConst.EnemyBehavior { CHASE, RANGED, DASHER, ORBIT, SENTRY }`；**M1 仅实现 CHASE / RANGED**，其余经 DataValidator 告警降级为 CHASE（`enemy.gd spawn()` L186） |
| 已有行为特化 | E2 疾冲冲刺状态机（巡航→蓄力0.3s→冲刺×1.9→回弹，`_tick_dart_chase`）；E4 爆虫自爆（FuseRing 警示圈 1.2s，可被击退打断）；E12 毒泡死亡毒爆 |
| 已有 RANGED | `_tick_ranged` + `_fire_at`：射程外逼近、射程内驻停、**瞄准单发 + 随机散角 spread**（E7 喷吐者 / E11 水泡怪 / E13 毒沼喷手） |
| 核心痛点 | 除 E2/E4/E7 等零星特化外，**绝大多数怪只有近战触碰伤害**——玩家感知「太匮乏」，走位没有意义 |
| 已有可复用基建 | 敌弹池 `ProjectilePool`（team=1，近战弧斩可消弹）、警示圈 `FuseRing`（爆虫同款）、死亡毒爆（半径伤害）、击退（Boss 免疫 / 精英 ×0.35）、顿帧震屏（`GameFeelDirector.request_hit_stop`）、元素状态（点燃/寒滞冻结/感电连锁/超导）、追踪弹 `HomingProjectile` |

**设计目标**：让每只怪都有「一件事」，每件事都有预警，每件事都能被玩家用某种武器/元素反制。

---

## 1. 与《ENEMY_BOSS_TELEGRAPH.md》的分工（必读）

本文**不重复** Boss 文档内容，两者按下列边界协作：

| 归属 | 内容 |
|---|---|
| **Boss 文档独有** | Boss 弹幕技能库 B1~B8、Boss 阶段模板、扫场/地雷/激光等处决级机制、**技能型精英词缀**（affix_ring 环爆体 / affix_sniper 狙击手 / affix_charger 冲锋者 / affix_trapper 布雷者 / affix_caller 唤潮者）、预警组件规范 §1.2（四类警示件 + 五色语义）、三档前摇时长 §1.3（400/700/1000ms）、伤害档位（12%轻 / 22%标准 / 35%重 / 50%处决） |
| **本文独有** | 普通怪九大行为族（含 tick 伪代码与数值系数）、**属性型精英词缀**（§4：疾风/坚盾/裂殖/汲血/弹幕强化/元素亲和）、五大关解锁节奏表（§5）、`EnemyData` schema 扩展（§6：`special` 参数包 / `ranged.pattern` / `affixes`） |
| **两者共享（以 Boss 文档为准，本文只引用）** | 预警件实现载体（`TelegraphCircle / TelegraphLine / TelegraphFan / TelegraphSwell`，其中 TelegraphCircle 由 FuseRing 泛化）、前摇走 game_delta 通道、敌弹统一 `ProjectilePool.acquire() + spawn({team:1, ...})`、同屏敌弹 ≤120 预算、冻结期停摆（冻结中的怪不发弹/不冲锋/不闪现） |

**词缀体系分工**：Boss 文档 §6 的技能型词缀 = 「怪会放一个弱化 Boss 技」；本文 §4 的属性型词缀 = 「怪本体变强/变异」。两者**可共存但每只怪总词缀数 ≤2**（投放规则见 §4.3）。

---

## 2. 设计总纲

1. **一族一件事**：每个行为族只做一种威胁，玩家 0.5s 内能从外观+预警读出它要干什么。外观分型沿用方向 C 规范（`TextureFactory.enemy_tex` 按 `_kind` 取图）。
2. **一切非触碰伤害必有预警**：复用 Boss 文档 §1.2 警示件与 §1.3 三档时长（400/700/1000ms），本文各族的预警时长**直接引用档位**，不再另立档。
3. **反制闭环**：每族设计时同步回答「玩家怎么破」——走位（闪现/狙击）、消弹（弹幕族）、击退打断（自爆/冲锋）、元素反应（点燃跳伤打高血、冻结打断施法、感电连锁清召唤海）。
4. **小关内只爬数量/数值**：新机制只在**大关首见**（§5），同关内用波表 `count` 与既有成长曲线做难度坡，不做新行为（既有的「每大关一个新体验」哲学）。

---

## 3. 行为族清单

> 系数基准 = 杂兵 grunt（hp 72 / spd 75 / contact 8 = 1.0 / 1.0 / 1.0）。
> 「弹伤」列的百分比基于玩家 60 HP，档位对齐 Boss 文档（12% / 22% / 35%）。
> 所有族的计时一律走 **game_delta 通道**（顿帧/冻结自然停摆），速度一律乘状态效果因子 `sf`（寒滞 0.6 / 冻结 0.0）。

### 3.0 CHASE · 蚁群族（基线，已实现）

- **成员**：E1 杂兵、E8 恶魔小鬼（1.4×速）、E3 堡垒（4.4×血 0.56×速 2.2×伤，KIN/FIR/ICE 抗 0.4）、E14 沼泽卫士、E16 沼泽巨口。
- **行为逻辑**：现状不动——直线追击 + Area2D 低频接触。
- **数值**：杂兵 1.0/1.0/1.0；高速型 0.75 血 / 1.4~1.7 速 / 1.5 伤；重装型 4.4 血 / 0.55 速 / 2.2 伤（接触 18 = 30%）。
- **反制**：霰弹枪击退撕口、任意 AoE。它是其他所有族的「背景压力」。
- **角色化**：E4 爆虫（接触后 1.2s 自爆，红圈警示）保留为 CHASE 分支特化，不另立族——BLINK 族（§3.3）即它的「远程化升级」。

### 3.1 DASHER · 冲锋撞击族

把 E2 已验证的冲刺状态机**从 CHASE 分支提出、升格为正式行为 + 数据驱动**，供重装冲锋怪复用。

- **行为逻辑（tick 伪代码，四态机）**：
```gdscript
DASHER:  # _dash_state: 0巡航/1蓄力/2冲刺/3回弹（E2 同款，抽出 _tick_dasher）
    _dash_left -= dt
    if _dash_left <= 0.0:
        match _dash_state:
            0: _dash_state = 1; _dash_left = data.special.get("charge", 0.35)   # 蓄力前摇
            1: _dash_dir = (player.pos - pos).normalized(); _dash_state = 2     # 期末采样锁定
               _dash_left = data.special.get("go", 0.4)
            2: _dash_state = 3; _dash_left = data.special.get("recover", 0.25)
            _: _dash_state = 0; _dash_left = data.special.get("cruise", 0.9)
    match _dash_state:
        0: pos += chase_dir * speed * sf * dt            # 巡航吃减速
        1: pass                                          # 原地 telegraph（表现层压扁微抖）
        2: pos += _dash_dir * speed * special.get("dash_mult", 2.0) * dt   # 冲刺不吃 sf（E2 口径）
           # 撞界反弹 / 贴身收势（照抄 _tick_dart_chase L365-380）
        3: pos += away_dir * speed * 0.5 * sf * dt       # 回弹
```
- **攻击方式**：冲刺期间接触伤害 ×1.25（重装型冲刺 22 = **37%**，普通型 12 = 20%）；冲刺本身不发射弹幕。
- **前摇预警**：TelegraphSwell——本体压扁 ×0.78 + 高频微抖（E2 现行表现，0.3~0.4s）+ 身前短橙条（TelegraphFan 15°，400ms，仅重装型）。
- **数值**：普通型 0.7 血 / 1.5 速 / 1.5 伤；重装型 2.2 血 / 1.1 速 / 2.75 伤、冲刺 ×2.2 速、蓄力 0.4s。
- **成员**：E2 疾冲（草原，现状）、E10 林间飞雀（树海，巡航改螺旋逼近）、E15 毒跳蛙（沼泽，冲刺改抛物线跳）、**E29 荆棘冲犀（树海新增，重装型）**。
- **反制**：**冻结 = 打断蓄力**（`_dash_state` 冻结期不推进即天然打断）；KIN 击退在蓄力期撞偏锁定方向；横向走位躲锁定（方向在蓄力期末采样，冲刺中不追踪）。

### 3.2 RANGED · 远程弹幕族（4 种弹幕形状，数据驱动）

现状 `_fire_at` 升格为 `_fire_pattern()`，弹幕形状由 `ranged.pattern` 字段驱动。**移动规则不变**：射程外逼近、射程内驻停。

- **弹幕形状库**：

| pattern | 形状 | 参数（ranged 字典新增键） | 弹伤档 | 代表怪 |
|---|---|---|---|---|
| `aim` | 瞄准单发（现状） | spread=随机散角 | 轻弹 12%（7） | E7 喷吐者（草原 w6）/ E11 水泡怪（冰原，改双连发 interval 0.15） |
| `burst` | 三连发（快照同向 + 2° 微散，0.12s 间隔） | `count:3, interval:0.12` | 轻弹 12%（7）×3 | E11 水泡怪（冰原 w1）、E13 毒沼喷手（沼泽，弹速 210） |
| `fan` | 扇形 3~5 发（中心瞄准，等角展开） | `count:3~5, arc_deg:36~60` | 标准 22%（13） | E22 霜扇吐息者（冰原 w6 新增，5 发 52°）；E13 升级版（3 发） |
| `ring` | 环形 12~16 发（360° 均匀，相位随机防齐刷） | `count:12~16` | 轻弹 12%（7） | E25 魔瞳浮眼（魔域 w6 新增，12 发） |
| `snipe` | 延迟狙击线：TelegraphLine 紫线 700ms → 沿线 430px/s 高速弹 | `telegraph_s:0.7` | 重击 35%（21） | E28 藤蔓狙击手（树海 w3 新增，射程 460） |

- **行为逻辑（tick 伪代码）**：
```gdscript
RANGED:
    if dist > fire_range: pos += chase_dir * speed * sf * dt     # 射程外逼近（现状）
    fire_cd_left -= dt
    if fire_cd_left <= 0.0 and dist <= fire_range:
        if pattern == "snipe":
            TelegraphLine.spawn(self→player, width=10, color=紫, t=telegraph_s)
            yield telegraph.finished → _fire_line(dir_locked)    # 结算必须由预警回调触发
        else:
            _fire_pattern(pattern, count, arc_deg)               # 走既有 projectile_pool.acquire()
        fire_cd_left = fire_cd * (randf_range(0.9, 1.1))         # ±10% 抖动防齐射
```
- **前摇预警**：aim/burst/fan/ring = TelegraphSwell 闪红 400ms（高频低伤，快档）；snipe = TelegraphLine 700ms（标准档，**先预警后锁定方向**，锁定时机 = 预警进度 50%，给玩家走位窗）。
- **数值**：1.1 血 / 0.85 速 / 接触 1.5 伤；弹伤按上表档位；射程 340~460。
- **反制**：**近战弧斩消弹**（既有 W9，弧内 team=1 弹直接回收）是全族通解；冻结停火；snipe 的紫线反向指示狙击手位置 → 转火优先级教学。

### 3.3 BLINK · 闪现爆炸族（用户点名）

**设计核心**：惩罚「原地站桩输出」。闪现目标是**施法瞬间玩家位置的快照**，落点预警给足，玩家移出红圈即可——走位永远有解。

- **行为逻辑（tick 伪代码）**：
```gdscript
BLINK:  # 三态：巡航 / 施法读条 / 落地引信
    _blink_cd -= dt
    match _blink_state:
        CRUISE:                                     # 普通追击（0.85×速，制造「追不太上」的错觉）
            pos += chase_dir * speed * 0.85 * sf * dt
            if _blink_cd <= 0.0 and dist <= special.get("blink_range", 340.0):
                _target = player.global_position    # 快照！落点=玩家当前位置
                _blink_state = CHARGING; _blink_left = special.get("blink_prep", 0.35)
        CHARGING:                                   # 前摇 0.35s：本体闪紫 + 收缩（TelegraphSwell 变体）
            if _blink_left <= 0.0:
                global_position = _target + rand_offset(24)   # 落点随机偏移 ≤24px 防贴脸重合
                _blink_state = FUSED
                _fuse_left = special.get("fuse", 0.8)
                FuseRing(radius=blast_r).show(progress=0)     # 落点红圈（爆虫同款泛化件）
        FUSED:                                      # 复用爆虫 fuse 管线：进度环 0.8s → 引爆
            _fuse_left -= dt; ring.progress = 1 - _fuse_left / fuse
            if _fuse_left <= 0.0: _explode(radius=blast_r, dmg=contact_dmg)   # 结算+死亡
    # 击退打断：FUSED 态被击退 → 复用 _cancel_fuse()（爆虫口径）；CHARGING 态被冻结 → 回 CRUISE
```
- **攻击方式**：定点爆炸，半径 110px，伤害 **30%（18）**——高于爆虫（20/33%→这里走重击下沿），因为落点可预读可逃。
- **前摇预警**：两段式——①出手：本体闪紫 + 收缩 0.35s（快档）；②落点：**红色警示圈 0.8s**（虚线圈 + 进度弧，FuseRing 泛化件挂在**世界层**而非怪本体——闪现后怪已位移）。释放瞬间 `request_hit_stop(30)` + trauma 0.3。
- **数值**：**0.65 血 / 1.1 速**（血薄速中，鼓励抢杀）、爆伤 30%、闪现 cd 3.2s、射程 340。
- **成员**：**E24 裂隙爆魔（魔域 w3 新增，本族首发）**；E4 爆虫为其「接触版近亲」（不重复投放于同波，防红圈海）。
- **反制**：**感电连锁打断施法**（CHARGING 态吃到感电硬直 → 施法失败进 2s cd）；冻结在 CHARGING 态打断；击退在 FUSED 态打断引信（爆虫既有口径）；持续走位让红圈落空。
- **为什么放在魔域（第三关）**：第一关教走位躲触碰，第二关教躲弹幕，第三关才引入「位移威胁」——玩家此时已具备消弹/走位肌肉记忆，能读懂红圈=离开。

### 3.4 ORBIT · 环绕牵制族

- **行为逻辑**：绕玩家固定半径切向绕行，偶尔吐弹。
```gdscript
ORBIT:
    _orbit_r = move_toward(_orbit_r, special.get("orbit_r", 170.0), 200.0 * dt)   # 半径内外收敛
    _orbit_ang += special.get("orbit_ang", 1.6) * dt * (sf 冻结=0 口径)
    global_position = player.pos + Vector2.from_angle(_orbit_ang) * _orbit_r
    fire_cd_left -= dt; if <= 0: _fire_pattern("aim"); fire_cd_left = fire_cd   # 2.5s 一发轻弹
```
- **攻击方式**：瞄准单发轻弹 12%（7），cd 2.5s；本体接触 13%（8）。
- **前摇预警**：TelegraphSwell 闪红 400ms（与 RANGED 快档一致）。
- **数值**：0.9 血 / 1.3 速 / 接触 0.8 伤；hitbox 12（小而滑）。
- **成员**：**E25 魔瞳浮眼（魔域 w6 新增）**——ORBIT + ring 12 混合技（绕行中每 4s 一轮环形弹）。
- **反制**：**追踪弹（HomingProjectile 既有）** 是天敌；FIR 点燃挂 DoT 后拉开（点燃不依赖命中持续跳伤）；冻结半径圈住它。

### 3.5 SENTRY · 哨戒炮台族

- **行为逻辑**：入场后扎根不动，周期性连发。
```gdscript
SENTRY:
    if _deploy_left > 0.0: _deploy_left -= dt; return   # 入场 0.7s 金圈（信息性，波表落点）
    fire_cd_left -= dt
    if fire_cd_left <= 0.0:
        if player 冻结我们: return                       # 冻结期停摆总则
        for i in special.get("burst_count", 3):          # 旋转步进连发：每发错 12°
            _fire_pattern("aim", jitter_deg = -12.0 + 12.0 * i)
        fire_cd_left = fire_cd                            # 2.2s
    # 无位移、免疫击退（扎根）；可被冻结（停火）/ 点燃（DoT）
```
- **攻击方式**：三连步进弹（标准 22%（13）/发，弹速 240）或环形 12 发轻弹（毒区变体：落点生成绿色毒圈，PoisonSplash 语义，伤害 12%/0.8s 踩踏 DoT，圈存在 3s）。
- **前摇预警**：TelegraphSwell 闪红 400ms（首发 700ms 教学窗）；毒区变体 = 绿色地面警示圈 700ms。
- **数值**：**2.4 血 / 0.1 速**（40 血级在 1.12^w 曲线下即现堡垒观感）/ 接触 0.8 伤；hitbox 16。
- **成员**：**E21 冰晶哨塔（冰原 w3 新增，本族首发）**；**E31 孢子炮台（沼泽 w3，毒区变体）**。
- **反制**：**点燃跳伤**（高血单体最佳解）；冻结停火争取输出窗；绕背（步进 12° 的覆盖盲区）；毒区变体提示「别站圈里」。
- **反直觉保护**：免疫击退但**保留受击 wobble**（Boss 文档 §7 同口径）——打击感不丢。

### 3.6 SUMMON · 召唤族

- **行为逻辑**：
```gdscript
SUMMON:
    # 缓慢逼近（0.3×速）保持威胁存在，但不主动贴脸
    pos += chase_dir * speed * 0.3 * sf * dt
    _summon_cd -= dt
    if _summon_cd <= 0.0 and _count_minions() < special.get("summon_cap", 4):
        TelegraphCircle(金, r=60, t=0.7, informational=true).show()
        yield telegraph.finished → for i in special.get("summon_count", 2):
            EnemySpawner.spawn_minion(special.summon_id, pos + ring_offset(48), hp_ratio=0.5)
        _summon_cd = special.get("summon_cd", 6.0)
```
- **攻击方式**：本体不攻击（接触 1.0×，纯自保）；威胁 = 召唤物数量。召唤物 = 现有怪 0.5 血模板（不给金币，EXP ×0.5）。
- **前摇预警**：**金色召唤圈 700ms**（Boss 文档五色语义：金=信息性）。本体死亡时，场上召唤物**不消失**（奖励转火玩家的决策）。
- **数值**：**3.6 血 / 0.3 速** / 接触 1.0 伤；EXP 高（12 基准）——「杀不杀召唤师」是资源决策。
- **成员**：**E26 深渊魔门（魔域 w9 新增，召唤 E8 小鬼）**；**E30 孢子母巢（树海备选变体）**。
- **反制**：**感电连锁清召唤海**（连锁天生克数量）；FIR 转火本体（DoT 磨 3.6× 血）；召唤圈位置 = 本体位置 → 顺藤摸瓜。

### 3.7 SUPPORT · 护盾/治疗辅助族

- **行为逻辑**：
```gdscript
SUPPORT:
    # 风筝：与玩家保持 ≥260px（比射程远，躲玩家近战弧）
    if dist < 260.0: pos += away_dir * speed * sf * dt
    else: pos += chase_dir * speed * 0.7 * sf * dt   # 跟随友军质心
    _heal_cd -= dt
    if _heal_cd <= 0.0:
        allies = enemy_grid.query_radius(pos, special.get("aura_r", 140.0))
        if 护盾型: for a in allies: a.apply_shield(a.max_hp * 0.12, cap=0.3*max_hp)
        if 治疗型: for a in allies: a.apply_damage(-a.max_hp * special.get("heal_pct", 0.03))
        _heal_cd = special.get("heal_cd", 2.0)
```
- **攻击方式**：本体不攻击（接触 1.25× 自保）；威胁 = 延长全场怪的存活时间。护盾型给 140px 内友军叠盾（单怪盾上限 30% max_hp，白环表现）；治疗型每跳 +3% max_hp。
- **前摇预警**：无伤害结算 → **豁免预警铁律**；但给信息性金色十字/光环脉冲 0.5s（复用 Sparkle 微光语言）。
- **数值**：1.6 血 / 0.85 速 / 接触 1.25 伤。
- **成员**：**E23 霜壳卫（冰原 w9 新增，护盾型）**；**E30 林愈树灵（树海 w9 新增，治疗型）**。
- **反制**：**点燃减疗 50%**（元素反应体系新条目：燃烧目标受到的治疗减半——给 FIR 一个明确的辅助对策位）；**转火优先级教学**（经验高 + 金币掉落 1.0，奖励先杀）；感电连锁跳到它。
- **数值红线**：治疗对满血友军无效、单目标 DPS 上限 = 3% max_hp / 2s——保证团战不会无限拖长（防「打不死墙」）。

### 3.8 SPLIT · 分裂族

- **行为逻辑**：
```gdscript
SPLIT:  # 移动 = CHASE（复用基线追击）；差异全在死亡钩子
    pos += chase_dir * speed * sf * dt        # 即 CHASE 逻辑
# _on_died() 挂钩（复用 E12 死亡毒爆的挂点位置）：
func _on_split_death() -> void:
    if _split_gen <= 0: return
    for i in special.get("split_count", 2):
        var child = EnemySpawner.spawn_minion(data.id, pos + ring_offset(hitbox_r * 1.4))
        child._split_gen = _split_gen - 1
        child.hp = child.max_hp * special.get("split_hp_ratio", 0.35)
        child.scale_hitbox(0.7); child.contact_dmg *= 0.6
    # 子代走既有 SPAWN_TIME 0.35s 弹入（信息性，无伤害）——尸体惩罚类按 Boss 文档 §1.1 口径豁免
```
- **攻击方式**：接触伤害（1.25×）；威胁 = 死亡增殖。子代**不继承元素状态、不再次分裂**（`_split_gen` 递减到 0，防指数爆炸）。
- **前摇预警**：死亡即释放属「尸体惩罚类」（E12 先例）；子代 0.35s 弹入即公平窗口——期间无碰撞伤害（弹入期接触判定关闭，加一行 `_spawn_left > 0` 短路）。
- **数值**：本体 1.2 血 / 0.95 速 / 1.25 伤；子代 0.35 血 / 1.6 速 / 0.75 伤。
- **成员**：**E27 晶簇兽（魔域 w12 新增，1 级分裂）**；**E12 毒泡史莱姆升级（沼泽 w6，新增 split_gen=1，保留死亡毒爆——先毒爆再分裂，双重尸体惩罚）**；E11 水泡怪在无尽池挂 `裂殖` 词缀。
- **反制**：**高爆发一击秒本体**（不给分裂机会——奖励爆发构建）；FIR 点燃的持续跳伤会在子代身上续挂（点燃向子代传染 30% 槽位，反应体系联动）；冰冻控场把分裂海冻住再 AoE。

### 3.9 系数总表（可直接抄进数值表）

| 行为族 | HP | 速度 | 接触伤 | 特色攻击 | 预警档 | 克制（元素/武器） |
|---|---|---|---|---|---|---|
| CHASE 蚁群 | 1.0（重装 4.4） | 1.0（重装 0.55） | 1.0（重装 2.2） | 触碰 | 豁免（触碰） | 霰弹击退 / 任意 |
| DASHER 冲锋 | 0.7（重装 2.2） | 1.5（重装 1.1） | 1.5 | 冲刺接触 ×1.25 | Swell 0.3~0.4s | 冻结打断 / 击退撞偏 |
| RANGED 弹幕 | 1.1 | 0.85 | 1.5 | 弹 12%~35% | Swell 0.4s / 紫线 0.7s | 近战消弹 / 冻结停火 |
| BLINK 闪爆 | 0.65 | 1.1 | 0.8 | 爆炸 30% r110 | 闪紫 0.35s + 红圈 0.8s | 感电断施法 / 走位 / 击退断引信 |
| ORBIT 环绕 | 0.9 | 1.3 | 0.8 | 弹 12% | Swell 0.4s | 追踪弹 / 点燃 DoT |
| SENTRY 哨戒 | 2.4 | 0.1 | 0.8 | 弹 22% ×3 步进 | Swell 0.4~0.7s | 点燃 / 冻结停火 / 绕背 |
| SUMMON 召唤 | 3.6 | 0.3 | 1.0 | 召唤物 ×4 | 金圈 0.7s | 感电连锁 / FIR 转火 |
| SUPPORT 辅助 | 1.6 | 0.85 | 1.25 | 盾/治疗 | 信息性金光 | 点燃减疗 / 转火 |
| SPLIT 分裂 | 1.2（子 0.35） | 0.95（子 1.6） | 1.25（子 0.75） | 死亡 ×2 | 子代弹入 0.35s | 爆发秒杀 / 点燃传染 / 冻场 |

---

## 4. 精英词缀系统（属性型，与 Boss 文档技能型词缀并行）

### 4.1 词缀表

在任意普通怪上叠加（E5 精英模板的 `elite_mult` 数值乘区**保留不变**，词缀是乘区之外的机制层）：

| 词缀 | 机制 | 数值 | 表现 | 克制 |
|---|---|---|---|---|
| 疾风 haste | 速度+前摇 | spd ×1.35；自身前摇 ×0.9（下限 340ms，Boss 文档红线） | 蓝色残影拖尾 | 冻结（0.6 因子直接抵消加速） |
| 坚盾 shield | 伤害吸收层 | 护盾 = 30% max_hp；破盾前免疫击退；8s 未受击重铸 | 白色描边环（复用 frost_ring 绘制语言，改白色） | FIR 灼烧跳伤磨盾；破盾瞬间 30ms 顿帧反馈 |
| 裂殖 proliferate | 死亡分裂 | 死亡 → 2 只 35% 血缩小版（不再分裂，防连锁） | 死亡瞬间两颗绿色弹入 | 爆发秒杀（同 SPLIT 族反制） |
| 汲血 leech | 攻击吸血 | 其攻击命中玩家 → 自身 +8% max_hp，且 160px 内友军各 +4%；自身点燃期吸血减半 | 命中时红色血线飞回 | 点燃（减半窗口）；速杀 |
| 弹幕强化 barrage+ | 弹幕增幅 | 自适应：fan/ring → count +2；aim/burst → fire_cd ×0.8；snipe → 弹伤 +25%（22%→27.5%，仍 <35% 重击档） | 弹色加深 + 弹径 ×1.2 | 消弹弧（弹多一样清） |
| 元素亲和 attune | 抗性变异 | 随机一系 resist +0.45 且免疫对应异常（ICE→免疫冻结 / FIR→免疫点燃 / LTG→免疫感电） | 体色染对应元素色（self_modulate） | 换元素打 / 超导削抗（既有 −30% 实时改写通道） |

### 4.2 叠加与投放规则

- **每只精英 1~2 词缀**，同名词缀不叠；互斥对：`裂殖 × 坚盾`（双保险太难杀）、`汲血 × 元素亲和`（吸血怪打不动还免疫——拖时间）。其余任意组合。
- 属性词缀与 Boss 文档技能型词缀（affix_ring/sniper/charger/trapper/caller）**可混搭**：每只总词缀 ≤2。
- 投放节奏（与 Boss 文档 §6 对齐）：草原 wave 8+ 出 1 词缀；**魔域（第三关）wave 12+ 开始双词缀**；无尽 wave 15+ 双词缀且 20% 概率三选二加权。
- 词缀注入走波表条目（现有 `composition` 条目已支持 `"tags": 1`，扩展 `"affixes": ["haste","barrage"]`）；波表未指定时按 `WaveDirector` 加权随机（保证同一精英波不重复同词缀 ≥2 只）。
- 精英判定复用 `TAG_ELITE`：皇冠/底影/微光三件套（`_ensure_crown/_ensure_shadow/_ensure_sparkles`）已就位，词缀另加上面的小标识。

### 4.3 词缀解锁节奏（随大关解锁新词缀）

| 大关 | 新解锁词缀 | 设计意图 |
|---|---|---|
| 晴空草原 | 疾风、弹幕强化 | 教学期：只改数值，不引入新规则 |
| 寒霜冰原 | 坚盾 | 教「先破盾」的转火直觉（配合 FIR 流） |
| 紫晶魔域 | 裂殖 | 双词缀期开启；分裂海配感电流 |
| 翡翠树海 | 汲血 | 强制速杀/点燃减疗构建 |
| 翠毒沼泽 | 元素亲和 | 毕业考：玩家必须有多元素手段或超导削抗 |

---

## 5. 各大关解锁节奏表

> 哲学：**每大关一个新体验**——新行为族只在关口首见，小关内只做数量/数值爬坡（波表 count + 四条成长曲线）。
> 大关内新怪投放锚点：w3（新体验首秀，Boss 前教学）/ w6（第二件）/ w9（第三件）/ w12+（组合与词缀升级）。Boss 波（w10/w20）不投新族。

### 5.1 晴空草原（30 波）——「触碰与走位」

| 波 | 新增 | 族 | 教学目标 |
|---|---|---|---|
| w1~2 | E1 杂兵 | CHASE | 拖动走位躲触碰 |
| w3 | E2 疾冲（现状落表） | DASHER | 第一次读前摇（压扁蓄力） |
| w6 | E3 堡垒 + E7 喷吐者（现状落表） | CHASE 重装 / RANGED aim | 高血目标 + 第一颗敌弹（消弹教学） |
| w7~8 | E5 精英（词缀：疾风/弹幕强化）+ E4 爆虫 | 精英 / 自爆 | 精英词缀首见 + 红圈引信 |
| w9~29 | 数量/数值爬坡；w12+ 爆虫成群 | — | 波表 count：17→31 杂兵、4→14 疾冲 |
| w10/20/30 | Boss1~3（Boss 文档 §5.1） | — | — |

### 5.2 寒霜冰原（20 波）——「火力网」（哨戒炮台 + 扇形弹幕）

| 波 | 新增 | 族 | 教学目标 |
|---|---|---|---|
| w1 | E9 冰霜仔（ICE 抗 0.6）+ E11 水泡怪改 burst | CHASE / RANGED burst | 元素抗性首见；连发节奏 |
| w3 | **E21 冰晶哨塔** | **SENTRY 首见** | 驻场威胁：学会绕背与清点 |
| w6 | **E22 霜扇吐息者**（fan 5 发 52°） | RANGED fan | 扇形弹幕走位（缝隙穿越） |
| w9 | **E23 霜壳卫**（护盾型） | **SUPPORT 首见** | 先杀辅助的优先级教学 |
| w12 | E21+E22 组合波（炮台驻场 + 扇弹压制） | 组合 | 火力网下走位 |
| w10/20 | E17 霜魄君王（Boss 文档 §5.2） | — | — |

### 5.3 紫晶魔域（20 波）——「瞬袭」（闪现爆炸 + 环绕 + 召唤）

| 波 | 新增 | 族 | 教学目标 |
|---|---|---|---|
| w1 | E8 恶魔小鬼（1.4 速 CHASE） | CHASE 高速 | 高速目标的手感 |
| w3 | **E24 裂隙爆魔** | **BLINK 首见（用户点名）** | 闪现落点红圈 → 移动出圈 |
| w6 | **E25 魔瞳浮眼**（ORBIT + ring 12） | **ORBIT 首见** + 首个环形弹幕 | 环形弹幕 + 追踪弹价值 |
| w9 | **E26 深渊魔门**（召唤 E8，cap 4） | **SUMMON 首见** | 感电连锁清场 + 转火召唤师 |
| w12 | **E27 晶簇兽**（SPLIT 1 级） | **SPLIT 首见** | 爆发秒杀 / 点燃传染 |
| w15+ | 双词缀精英开启（§4.2） | — | 词缀深度 |
| w10/20 | E18 熔核魔尊（Boss 文档 §5.3） | — | — |

### 5.4 翡翠树海（20 波）——「狙杀与续航」（狙击线 + 治疗）

| 波 | 新增 | 族 | 教学目标 |
|---|---|---|---|
| w1 | E10 林间飞雀（DASHER 螺旋巡航） | DASHER 变体 | 快节奏复习 |
| w3 | **E28 藤蔓狙击手**（snipe：紫线 0.7s → 430 弹速重击 35%） | RANGED snipe 首见 | 读紫线、垂直走位 |
| w6 | **E29 荆棘冲犀**（重装 DASHER：2.2 血、冲刺 22=37%） | DASHER 重装 | 冲刺红线 + 硬抗不行 |
| w9 | **E30 林愈树灵**（治疗型） | SUPPORT 治疗首见 | 点燃减疗（FIR 流高光） |
| w12 | ring 16 升级（E25 树海变体）+ 狙击手双驻场 | 弹幕升级 | 弹幕密度爬坡 |
| w10/20 | E19 古树守卫（Boss 文档 §5.4） | — | — |

### 5.5 翠毒沼泽（20 波）——「失控增殖」（分裂 + 毒域）

| 波 | 新增 | 族 | 教学目标 |
|---|---|---|---|
| w1 | E12 毒泡史莱姆（现状毒爆） | 尸体惩罚 | 复习：别贴着尸体 |
| w3 | **E31 孢子炮台**（SENTRY 毒区变体） | SENTRY 升级 | 绿圈 = 持续毒区，别站 |
| w6 | **E12 升级：死亡毒爆 + 分裂**（split_gen=1） | SPLIT 升级 | 双重尸体惩罚，点燃流毕业考 |
| w9 | BLINK+SUMMON 组合波（裂隙爆魔护深渊魔门） | 组合 | 优先级大考：先杀谁 |
| w12 | E14 沼泽卫士 + E16 沼泽巨口成群 + 三词缀池解锁 | CHASE 重装 + 词缀 | 终局压力 |
| w10/20 | E20 九头沼龙（Boss 文档 §5.5） | — | — |

### 5.6 无尽模式

各图无尽池 = 本图全族混编，`WaveDirector` TP 公式（base 14 + slope 3.2）持续加压；w15+ 双词缀；每 4 波精英、每 10 波轮换池 Boss（`BOSS_ROTATION` 既有）。新族不进无尽首秀，只做密度。

---

## 6. 实现注意（Godot 4.3）

### 6.1 枚举与数据 Schema 扩展

```gdscript
# game_const.gd（枚举增项——enemy.gd 头注明示「需框架评审」，一次性提审）
enum EnemyBehavior { CHASE, RANGED, DASHER, ORBIT, SENTRY, BLINK, SUMMON, SUPPORT, SPLIT }

# enemy_data.gd 扩展：
@export_enum("CHASE","RANGED","DASHER","ORBIT","SENTRY","BLINK","SUMMON","SUPPORT","SPLIT") var behavior: int = 0
@export var special: Dictionary = {}     # 行为专属参数包（与 ranged 同级；mirror ranged 的做法）
@export var affixes: Array[StringName] = []   # 波表/生成器注入；.tres 留空 = 进默认加权池

# ranged 字典新增键（向后兼容：缺省走现状 aim）：
#   pattern: "aim"|"burst"|"fan"|"ring"|"snipe", count, arc_deg, interval, telegraph_s

# special 键位约定（各族只读自己那组）：
#   DASHER:  {charge, go, recover, cruise, dash_mult}          # 缺省 = E2 现行常量值
#   BLINK:   {blink_cd, blink_prep, fuse, blast_r, blink_range}
#   ORBIT:   {orbit_r, orbit_ang}
#   SENTRY:  {burst_count, burst_step_deg}
#   SUMMON:  {summon_id, summon_count, summon_cd, summon_cap, minion_hp_ratio}
#   SUPPORT: {aura_r, shield_pct, heal_pct, heal_cd}
#   SPLIT:   {split_count, split_hp_ratio, split_gen, child_scale}
```

### 6.2 tick 分支挂接（enemy.gd）

- `tick()` 的 `match behavior` 增分支，每族逻辑独立成 `_tick_<family>(dt, player, sf)`（对齐 `_tick_dart_chase` / `_tick_volatile_fuse` 先例），CHASE 分支内的 E2/E4 特化代码逐步迁出。
- 新状态变量全部在 `_reset_state()` 归零（池归还清零契约，E-04/E-05——漏一个就是复用串味 bug）；`_split_gen`、`_blink_state`、`_deploy_left` 等记得补。
- E2x 新 id 的 `_visual_kind()` 前缀表（enemy.gd L689-714）同步补行。
- 接触伤害通道不变（Area2D 低频）；SPLIT 子代弹入期（`_spawn_left > 0`）短路接触判定。

### 6.3 弹幕与预警

- 弹幕一律走既有通道：`projectile_pool.acquire() → bullet.spawn({velocity, lifetime:5.0, pierce:1, bounces:0, hitbox_radius:5.0, team:1, panel_snapshot:{base_atk}})`，伤害 = `contact_dmg × bullet_atk_ratio`（近战弧斩按 team=1 消弹，零新管线）。
- 预警组件直接使用 Boss 文档 §1.4 的 `telegraph.gd`（TelegraphCircle/Line/Fan 由 FuseRing 泛化）；BLINK 落点红圈挂**世界层**（怪会位移），其余挂怪本体。
- 结算契约：一切非触碰伤害由 `Telegraph.finished` 回调触发（Boss 文档 §1.1 铁律），BLINK 引爆、snipe 发弹、SUMMON 落地均是。
- 打击感：BLINK 引爆 / 破盾 / SENTRY 入场 → `GameFeelDirector.request_hit_stop(30)`（CRIT 档）；爆炸加 trauma 0.3~0.4。全部走 game_delta 通道，顿帧时前摇自然冻结。

### 6.4 DataValidator 校验（加载期拦截）

- behavior ∈ 枚举全集后**移除 M1 降级**（spawn L186-187），改为逐族必填断言：BLINK 必填 `special.fuse/blast_r`；SUMMON 的 `summon_id` 必须存在于敌人注册表；SENTRY 必填 `burst_count`；含 `pattern:snipe` 必填 `telegraph_s`；`affixes.size() <= 2` 且互斥对校验（§4.2）。
- 波表条目新增 `affixes` 键校验：词缀名必须在 §4.1 表内。

### 6.5 性能预算

- 同屏敌弹 ≤120（Boss 文档口径）：ring 16 × 3 只哨戒 = 48，加召唤海弹幕仍安全；`WaveDirector` 生成时按弹预算降频 ring 类。
- 召唤物同屏 ≤8（SUMMON cap 4 × 2 门）；召唤物复用 Enemy 池（`EnemySpawner.spawn_minion` 走既有 spawner 通道，不走独立类）。
- SENTRY/ORBIT 的友军查询走既有 `SpaceGrid`（10Hz 通道，E-10 口径），不用逐帧 O(n²)。
- 预警件按 Boss 文档 §1.4：程序化 `_draw()`、挂件随池实例存活惰性创建（照抄 `_ensure_armor` 模式），禁止运行期 instantiate。

### 6.6 测试锚（tests/ 回归锁定）

- E2 疾冲 / E4 爆虫 / E12 毒爆行为回归不变（DASHER 抽取后 dash 参数缺省值 = 现行常量）。
- BLINK：落点 = 施法帧玩家位置（±24px）；冻结/感电/击退三路打断各一条用例。
- SPLIT：`split_gen` 递减（无指数）；子代 `_spawn_left` 期间无接触伤害。
- SUPPORT：治疗对满血无效；点燃目标治疗 ×0.5。
- 词缀：互斥对拒绝；`affixes.size() > 2` 拒绝。

---

## 7. 附：数值速查卡

| 项 | 值 |
|---|---|
| 玩家基准 HP / 无敌帧 | 60 / 0.6s（与 Boss 文档同口径） |
| 接触伤档 | 8（13%）轻 · 12（20%）标 · 16（27%）重 · 20（33%）重装 |
| 弹伤档 | 12%（7）轻弹 · 22%（13）标准 · 35%（21）重击（Boss 文档同款，本文只消费） |
| 爆炸档 | 30%（18）r110（BLINK）· 33%（20）r110（爆虫现状） |
| 前摇档 | 400 / 700 / 1000 ms（Boss 文档 §1.3；BLINK 出手 350ms 属快档变体） |
| 敌弹预算 / 召唤上限 | 同屏 ≤120 / 同屏 ≤8 |
| 新增枚举 | BLINK=5, SUMMON=6, SUPPORT=7, SPLIT=8（提审后写入 game_const.gd） |
| 新增怪编号 | E21~E31（续接现表；E17~E20 为各图 Boss 已占用） |
