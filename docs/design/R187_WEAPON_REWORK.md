# R187 武器五方向重做整案（W1 手枪 / W4 激光 / W5 棱镜 / W6+W7 双火箭 / W8 环绕力场）

> 收敛自 5 方向 × 3 提案（共 15 份）。收敛原则：**构筑深度优先；五武器定位两两不重叠；与 R183 诺亚僚机（临时 10s 复制且 copy_full 含全部 buff）读感严格区分**。
> 本文档为唯一定案，实现组照做；所有行号锚点已在 R187 收敛会话中实读核实，三条基线测试已实跑。

---

## 〇、收敛会话验证记录（本会话实跑/实读）

### 已实跑的基线测试（命令与输出）
| 命令 | 输出 |
|---|---|
| `tools/Godot_v4.3-stable_win64_console.exe --headless --path repo -s tests/runner/test_pkg3.gd` | `汇总：PASS 127 / FAIL 0（共 127 项）` |
| `tools/Godot_v4.3-stable_win64_console.exe --headless --path repo -s tests/runner/test_weapon_orbit.gd` | `汇总：PASS 42 / FAIL 0（共 42 项）` |
| `tools/Godot_v4.3-stable_win64_console.exe --headless --path repo -s tests/runner/test_p1_polish.gd` | `汇总：PASS 17 / FAIL 0（共 17 项）` |

### 已实读核实的关键锚点（节选）
- `repo/resources/weapons/W4_pulse_beam.tres`：L 表注释锚 tick_atk 6/7/7/9/11 × 8/8/9/9/9 跳/s（:13/22/31/40/49）；`laser` 段 `tick_rate=5.0`（:74，`laser_weapon.gd:97` 的 `_leveled_param("tick_rate", rof)` 只查 `tick_rate_levels`，此键确为死键）；`pulse_duration=0.5`（:75）；`refract_beams=0`（:77）；threshold_traits 含 3 条弹道死声明 + `TH_CRIT_SHARD` 0.6（:60-72）。
- `repo/resources/weapons/W5_prism.tres`：`refract_beams=2 / refract_ratio=0.6 / refract_depth=2`、`refract_beams_levels=[2,2,3,3,3]`、`refract_ratio_levels=[0.6,0.6,0.6,0.6,0.75]`（:76-78）；L5 注释三目标群 DPS 358（:49）。
- `repo/resources/weapons/W1_pistol.tres`：L4 `pierce=1` 倒退（:38，L3=2→L4=1）；L1/L2=14/16（:8/:17）；L5 pellets=2（:48）。
- `repo/resources/weapons/W6_micro_missile.tres` / `W7_cluster_rocket.tres`：W6 atk 18/22/22/27/32、cd 0.55→0.48、`blast_r_levels=[75,80,85,90,100]`、`proj_speed_init=240`；W7 atk 38/38/46/54/68、cd 3.2→2.6、`blast_r=110`、`sub_count_levels=[5,6,6,8,8]`；两武器 threshold_traits 四条完全相同（各自 :60-72）。
- `repo/resources/weapons/W8_orbit_field.tres`：melee 段 `cd=1.0`（轮询占位）、`hit_cd=0.5`、`max_targets=8`、`orbit_radius_levels=[90,90,100,108,120]`、`orbs_levels=[2,2,3,3,4]`、`angular_speed_levels=[240,240,270,300,335]`（:74-80）；threshold_traits 3 条投射物死声明（:60-68）。
- `repo/scripts/combat/weapon/laser_weapon.gd`：聚焦 +15%/s 封顶 ×2、换目标清零、focus_mult 仅注入主束（:45-64）；tick_rate 钳 [0.5,30]（:97-98）；折射调度 `_on_beam_refracted`/`_nearest_unhit`/`REFRACT_SEARCH_RADIUS=250`（:12-13, :127-170）；`_leveled_param` 通道（:173-178）。
- `repo/scripts/combat/weapon/laser_beam.gd`：`scorch_layers` 为**束实例私有池**（:34 附近声明，`_settle_one_tick` 按 beam 内字典叠层）；`ctx.element = GameConst.Element.KIN` 硬编码；跳伤路径无 `inject_relic_pools` 调用（全仓唯一调用点 `projectile_base.gd:310`）。
- `repo/scripts/combat/weapon/melee/orbit_field.gd`：R186 附着三件套 `attach_gate`/`attach_mult`/`_orb_element`（:34-35, :59-62, :212-233）；击退径向外推（:238-246）；逐球键 `"orb_idx:uid"` 冷却表（:32, :176-178）。
- `repo/scripts/combat/weapon/melee/orbit_weapon.gd`：`add_knock` 死接线（:189-193）、`knife_scale` 纯视觉（:145-151, :204）、`attach_gate/attach_mult` 注入（:201-202）。
- `repo/scripts/cards/card_generator.gd`：`MAX_WEAPON_TRAITS=12`（:50）、`COUNT_TRAIT_IDS=[AFF_PIERCE, AFF_MULTI, MEC_ORBIT_LINK]`（:225）、`_form_allows` 支持 `required_forms`/`required_weapon`（含数组）/`requires_trait`/`exclusive_group`（:435-500）。
- `repo/scripts/core/data/data_validator.gd`：`_validate_ballistic_segment` 只查 proj_speed/range/pierce/pellets∈[1,16]（:486-494）；`_validate_laser_segment` tick_rate∈(0,30]/scorch∈[1,8]/refract_depth≤2（:497-505）；`_validate_homing_segment` blast_r∈(0,128]/sub_count∈[0,8]（:507-517）；`_validate_melee_segment` arc/orbs∈[1,8]/hit_cd>0（:519-527）；**所有 `<key>_levels` 数组零校验**（补口任务）。
- `repo/scripts/entities/player/player.gd`：`SUMMON_COPIES=2`/`SUMMON_DURATION=10.0`（:110-111）；`refresh_weapon_intervals` 只扫 `weapon_slots`+`_summon_copies`（:515-523）；`_make_weapon_copy` 走 `copy_full` 全量拷贝 + ELE reaction_mult **按副本 uid 重注册**（:751-770）；横幅「召唤僚机：复制了 X」（:745-753）。
- `repo/data/balance/balance_tables.tres`：`cap_prod=8.0`（:8）、`add_pool_caps={add_atk:2.0, add_rof:1.5, add_cdr:0.6, ...}`（:13）、`cap_cdr_sum=0.6`（:14）、弹池 1500/2000（:21-22）、`pool_prewarm.laser=12`（:23）。
- `repo/scripts/core/pools/laser_pool.gd`：预热 12 / 软 16 / 硬 24（:2，注释级，不接线）。
- `repo/scripts/core/game_const.gd`：W5 文案「棱镜折射——弹道分光…」（:77-78）。
- `repo/autoload/event_bus.gd`：`mechanics_intro`（:48, :254）；`repo/autoload/debug_stats.gd`：`count/get_counter`（:61/:65）。
- 词条先例：`MEC_ORBIT_LINK.tres`（pool=3、value=1.45、stack_max=3、`params.required_weapon` 数组）、`AFF_MULTI.tres`（stat=pellets、required_forms=[0]、stack_max=2）、`AFF_ROF_UP.tres`（[0,1]×3）、`AFF_CDR.tres`（[1,2,3]×4）、`MEC_KNOCK.tres`（required_forms [0,2]，W8 form=3 被排除）。

---

## 一、定位矩阵（五武器两两不重叠）

| 武器 | 一句话定位 | 核心动词 | 节拍源 | 与邻位的硬分界 |
|---|---|---|---|---|
| **W1 手枪** | 中远距**确定性并排编队** + **跳弹增值**（弹道价值轴） | 阵宽 / 收束 / 反弹回场 | 武器 cd（5.5 发/s 点射） | vs W6：直射无爆炸无自导；vs W2 加特林：编队空间轴 vs 预热时间轴；vs W3：窄锥确定性 vs 随机扇面 |
| **W4 激光** | **常驻聚焦单体锚** + 构筑解锁至 3 束**裂片副激光**（承接原棱镜多光束定位） | 持续照射（聚焦 ×2 / 灼焦 / 分束拓扑） | 束内跳频（8~11 跳/s） | vs W5：W4 白板期即 1 束主激光、成长靠束数/拓扑；W5 本体退化为校准锚束、成长靠镜面军团；W5 峰值束段指纹=1 |
| **W5 棱镜** | **永久白板镜面军团**：随机映照其他武器，只吃棱镜自身 buff | 复制器（镜数 / 指向 / 攻速传导 / 元素涂装） | 被映照武器的节拍 | vs R183：永久 vs 10s 临时、白板 vs 全 buff、银白/冰青 vs 金色、「棱镜映照」vs「召唤僚机」；vs W4：无灼焦无聚焦、束段=1 |
| **W6 微型导弹 / W7 集束火箭** | W6=高频**齐射引发器**（30% 规格小爆多点铺场 + 引信标记）；W7=慢节拍**攻城引爆器**（1+8 集束事件） | AOE 事件 / 双武器引信连携 | W6 cd 0.48s / W7 cd 2.6s | W6 vs W1：自导+爆炸+存场；W6 vs W7：频率 vs 规模（阈值分叉 TH_SWARM_NOVA ↔ TH_SIZE_NOVA）；引爆动词的敌侧状态机归 W8，W6/W7 引信是**双武器连携标记**（无 W7 不引爆） |
| **W8 环绕力场** | **目标侧蓄能状态机**：接触蓄能→满档引爆的锯齿输出 + 切向塑场领地 | 蓄能 / 引爆 / 塑场（-clock 在敌人身上） | 无武器节拍（try_fire 恒 false） | vs W9：W8 时钟在敌人（蓄能满档触发）vs W9 时钟在武器（cd 1.8→1.5s 斩击、离体追击、消弹 nullify=true）；全场唯一禁元素武器（R186 附着路线拆除） |

**引爆动词分布裁定**：W8（蓄能满档，敌侧状态机）、W6→W7（引信连携，双卡 required_weapon 锁定）、激光**不取**焦爆清算轴（避免第三处引爆）、手枪**不取**装药引爆轴（提案 2 整轴落选，理由：与 W8/W6W7 引爆动词三重撞车）。**多束/数量动词分布**：W1 并排弹（弹道）、W4 副激光（光束）、W6 齐射（自导爆）、W5 镜面（武器级镜像）——载体互斥、词条池 required_forms/required_weapon 互不上架。

**R183 区分总裁定（统一表，全部写进验收）**：

| 场景 | 裁定 |
|---|---|
| 复制 W1 | 副本执行同 lane 几何参数 + **独立弹幕态计时器** + 金色染色 |
| 复制 W4 | 副本 `sub_beams` 强制 0（只出主束）+ 灰染；经新 EventBus 信号 `laser_subbeam_spawned` 的归属字段（本体/僚机）断言 |
| 复制池源 | **复制池排除 `W5_prism`**（临时件永不产出永久件）；镜面独立数组 `_mirror_images`，永不进 `_summon_copies` |
| 复制 W6 / W7 | 副本 `volley_eff=1`（W6）/ `sub_eff=min(sub,3)`（W7）；复制弹按 weapon_uid tint（钢蓝/橙红+金边） |
| 复制 W8 | 蓄能池以**目标 uid 为全局单例**（复制体只加速蓄能、永不复制引爆当量）；复制体固定 BASE 单环阵 + 相位偏移 45° |

---

## 二、五方向定案 DirectionSpec

### 2.1 激光（W4_pulse_beam）——「裂片棱镜」多光束方案（以提案 1 为骨架，吸收提案 2 的目标侧单池与 CDR 换挂）

**Design（实现组照做）**
1. **主束常驻化**：W4 `.tres` laser 段删除 `pulse_duration` 键（spawn lifetime 走缺省 0=常驻，`laser_weapon.gd:103-104` 现成通道）与死键 `tick_rate=5.0`（`_leveled_param` 从不读它，实际跳频=L 表 rof 8/9）。占空比 31%→100%，W4 从脉冲聚焦变成常驻聚焦单体锚。
2. **数值兑现注释锚**：五级 `base_atk` 改为 **6/7/7/9/11**（正是 W4_pulse_beam.tres:13/22/31/40/49 注释里躺着未兑现的 A3 tick_atk 锚），rof 8/8/9/9/9 不变（`cd` 键对常驻束失去意义，保留原值不动、validator 不新增告警）。
3. **副激光计数词条**（本提案身份卡）：新词条 `MEC_SPLIT_PRISM`「裂片棱镜」——pool=3（MECH）、value=1.45 进 `COUNT_TRAIT_IDS`（card_generator.gd:225）品质梯 白+1/蓝+2/紫+3、`stack_max=3`、`params.required_forms=[1]`。**不走 add 池**：`LaserWeapon.try_fire` 直读词条栈计数（仿 `orbit_weapon.gd:213-226` 消费 MEC_ORBIT_LINK 的先例），挂载与消费同在武器侧防 R69 死卡。计数键显式豁免满层质变 ×1.6 与乘区名额（计数键≠伤害键）。
4. **副束行为**：`_spawn_beam(depth=0, dmg_mult=主束×ratio, target_uid=寻的, exclusions)` 复用现成签名（`laser_weapon.gd:72-124`）；副束 250px 内最近未被锁定目标（`_nearest_unhit` + 兄弟互斥排除集，`laser_weapon.gd:127-170` 现成）；目标不足时并入主束目标但 `dmg_mult ×0.5`、**不叠灼焦、不附着元素**（重叠回退，保残局 50% 下限收益）；副束**永不继承聚焦**（focus_mult 恒 1.0）。
5. **束间拓扑**（exclusive_group=`laser_topology`，三选一唯一卡，R19 互斥闸 card_generator.gd:484-493 现成）：
   - `MEC_BEAM_TRACK`「追踪棱」（默认风格）：副束独立寻的（第 4 条行为）；
   - `MEC_BEAM_FAN`「扇形棱」：副束固定角随主束朝向出束（±25°/±50°），不索敌、命中即结算——把站位权重压回去的反挂机解；
   - `MEC_BEAM_COFOCUS`「共焦棱」：副束全部钉主束目标、重叠回退关闭、灼焦仍只由主束注入（单体爆发路线）。
6. **相位同步轴**：新词条 `MEC_PHASE_SYNC`「相位同步」stack_max=1——副束≥2 时主束聚焦爬坡速率 15%/s→30%/s（×2 封顶不变、6.7s→3.35s 满），数量投资反哺单体锚，拆掉「多束=聚焦废卡」的身份互斥。
7. **跳频轴**：AFF_ROF_UP 现卡继续生效（消费点 `laser_weapon.gd:97-98` tick_rate 乘区，钳 [0.5,30]）；新词条 `MEC_BEAM_LAG`「分光延迟」——每束存活副激光主束跳频 +0.5 跳/s（同一钳制内）。
8. **CDR 换挂**：AFF_CDR（required_forms [1,2,3] 现成，stack_max=4）消费点从脉冲 cd（常驻化后死属性）改写为**换目标保留聚焦进度 12.5%×层数**（4 层=50%）；cd 键对常驻束作废（validator 不再对 W4 断言 cd 行为，cd_pace 用例翻转）。
9. **分光谱**：新词条 `MEC_BEAM_SPECTRA`「分光棱镜」——副束按锁定次序从玩家元素池轮转取元素（束数=同屏铺开的元素种类数，喂 2s 反应网络 cd_rxn）；顺带删除 `ctx.element=KIN` 硬编码（laser_beam.gd `_settle_one_tick`），元素跳字配色复活。
10. **质变**：W4 threshold_traits 删除 3 条弹道死声明（TH_SIZE_NOVA/TH_FRACTAL_ECHO/TH_BOUNCE_ETERNAL），替换 `TH_PRISM_CHOIR`（metric=`sub_beam_count`、threshold=3、effect_id=`EF_CHOIR` 新 EF，入 data_validator TECH_EFFECT_IDS 白名单）——副束≥3 时副束跳频 +2 跳/s（钳 30）；`TH_CRIT_SHARD` 0.6→0.35（全武器共享死节点修复，见共享改动）。
11. **N=2 束质变**：副束索敌半径 250→350px（复用 `REFRACT_SEARCH_RADIUS` 键位语义，读词条层数）。
12. **灼焦目标侧单池**（本方向前置修复，与 W5 共享）：`scorch_layers` 从束实例私有池迁到目标侧单池（键=target_uid，快照随束携带 cap），同目标多束叠层速率=单束口径（0.25s/层、≤scorch_max_layers），封死 N 束 ×N 份乘区超线性。
13. **前置修复**：激光跳伤路径接通 `inject_relic_pools`（接线点在共享组 `projectile_base.gd` 同源通道；激光侧在 `_settle_one_tick` 的 ctx 构造处调用）——否则 5 件命中遗物对激光全无效，「抽了没反应」。
14. **表现**（与功能同版本交付，非打磨项）：副束解锁走 `EventBus.mechanics_intro` 横幅 + HUD 束数徽标；副束=第三谱系束色（细束），复制体灰染；元素跳字随 MEC_BEAM_SPECTRA 着色。

**BuildAxes**：① 束数（MEC_SPLIT_PRISM ×3）→ ② 束间拓扑（laser_topology 三选一）→ ③ 同步/节奏（MEC_PHASE_SYNC + MEC_BEAM_LAG + AFF_ROF_UP + AFF_CDR 换挂）→ ④ 元素铺场（MEC_BEAM_SPECTRA）。

**Numbers**（对齐基准：W4 .tres 注释 A3 锚、L1=0.8× 手枪锚 60、旧棱镜满链 873）
- 基线·主束（常驻）：单跳 6/7/7/9/11 × 跳频 8/8/9/9/9 → 主束 DPS **48/56/63/81/99**（×2.06 成长，L1=0.8×手枪锚）；满灼焦 ×1.4（L1-4 五层）/×1.64（L5 八层）→ 67.2/78.4/88.2/113.4/162.4（逐项等于 .tres 注释锚）；满聚焦 ×2（6.7s）→ L5 单体满配 **324.8**。
- 成长·副束：单跳=主束×0.6（L1-4）/×0.75（L5，`sub_ratio_levels=[0.6,0.6,0.6,0.6,0.75]` 迁自 W5 原值）；L5 曲线：0 卡 99（单体）→+1 束 173.3（二目标）→+2 束 247.5→+3 束 321.8（四目标），每张束数卡 ≈+74 铺场 DPS；满配（3 副束+棱镜核心继承 0.5，全目标满灼焦、主束满聚焦、共焦外拓扑 ×1.5 反射上限不启用）4 目标 ≈**873**——与旧棱镜 L5 密集群满链 873 持平，不破全局预算；共焦拓扑单体 ≈659 vs 互换后棱镜单体 105，一头一尾错开。
- 上限：池容量 12 不扩（W4 峰值 1+3=4 段；W5 换位后束段指纹=1；双激光同持 ≤8 段 ≤12，现 W5 L3+ 13 段超池隐性 bug 随互换消亡）；副束 stack_max=3、词条 ≤12/武器；跳频钳 [0.5,30]、灼焦 ≤8 层（目标侧单池）、聚焦 ×2 仅主束、副束反射 ≤×1.5；add 池帽与 cap_prod 8.0/名额 8 沿用 balance_tables.tres:8-16。
- 池预算账（最坏）：W4 满配 4 + W5 本体 1 + 激光镜 ≤2（镜面激光帽）+ W4 复制体 1（只主束）= **8 ≤ 12**。

**Acceptance（可自动化）**
1. 默认单束：seed(42)+静止敌夹具（仿 pkg3_cases.gd:779 模式），W4 新数据下 try_fire 后场景内 laser 段计数==1、锁定最近敌、lifetime==0（常驻）；`test_pkg3.gd` 须 PASS 且含翻转用例。
2. 叠束与硬帽：真 registry 挂 3 张 MEC_SPLIT_PRISM → 段数==4；副束 dmg_mult==主×0.6（L5 ×0.75）±1e-6；副束目标与主束及其余副束两两互斥（exclusions 集断言）；第 4 张被 stack_max=3 拒绝且 DebugStats 计数 +1。
3. 聚焦归属：主束同目标 6.7s focus_mult==2.0±0.05；副束 focus_mult 恒 1.0；挂 MEC_PHASE_SYNC 后 3.35s 即达 2.0；AFF_CDR×4 换目标保留 50%±2% 聚焦进度（手动推进 beam.tick 计帧）。
4. 灼焦单池：两束共照同目标 2s → 层数曲线与单束对照相等（≤8 封顶，目标侧单池断言）；重叠回退：无多余目标时副束并入主束目标且伤害 ×0.5、不叠灼焦。
5. 预算与超线性：双激光同持满配全场 laser 段峰值 ≤12、每秒结算次数 ≤束数×30；L5 单体满配 DPS 324.8±5 数值断言。
6. R183：诺亚复制持满构 W4 → 复制体并发束==1、灰染 flag==true，经 `laser_subbeam_spawned` 归属字段在 DebugStats 断言；同场 W5 束段指纹==1。
7. 回归翻转：pkg3_cases.gd 激光段、verify_feedback_cases.gd:4330-4383（R91）、cd_pace_cases.gd:103-119 按新契约更新后三套件全绿。

---

### 2.2 棱镜（W5_prism）——「万镜回廊」永久白板镜面枢纽（提案 2/3 杂交 + 存档纪律修正）

**Design**
1. **本体退役折射**：W5 .tres laser 段**真删** `refract_beams/refract_ratio/refract_depth/refract_beams_levels/refract_ratio_levels` 五键（validator 同步剔除语义，data_validator.gd:504 迁移），保留单束「校准锚束」（tick_atk 7/9/11/14/15 ×5 跳/s 不动，单体 DPS 35/45/55/70/75）；R91 旧折射行为测试（verify_feedback_cases.gd:4330-4383）随重写退役。
2. **镜面生成**：从场上**其他真实武器**（排除自身与空槽）随机锁定一面——新实体类 `MirrorImage`（镜面），沿用源武器 WeaponData+等级面板开火，但词条栈=**棱镜自身栈的 copy_full**（拷贝源=棱镜，`trait_stack.gd:87-97` 通道）——白板语义：源武器词条零拷贝、只随挂到棱镜上的卡而变；「一张棱镜卡=N 镜生效」。镜面独立数组 `_mirror_images`，不占武器槽、**永不进 `_summon_copies`**（换角色/重生清空逻辑不受污染）。
3. **镜数轴**：W5 laser 段新增 `mirrors_count_levels=[1,1,2,2,3]`（L3=2、L5=3，等级质变感）；新词条 `MEC_MIRROR_SPLIT`「分光镜」——镜子 +1/层、`stack_max=2`、`params.required_weapon=[&"W5_prism"]`、入 `COUNT_TRAIT_IDS` 品质梯（白+1/蓝+2）；**绝对帽 5**（等级 3+卡 2，clamp）。
4. **强度轴**：`mirror_ratio_levels=[0.40,0.45,0.50,0.55,0.60]`（骨架迁自原 refract_ratio_levels）；镜面伤害=源 data 面板 × mirror_ratio × 棱镜栈增益。
5. **指向轴**（随机性代理权，exclusive_group=`prism_pointer` 二选一）：`MEC_MIRROR_LOCK`「镜面锁定」（不再重掷，随机→确定性）vs `MEC_MIRROR_WEIGHT`「最肥镜像」（镜面恒指向面板 DPS 最高武器）；基础规则=波首/获得新武器时空闲镜位重掷（走卡池同款确定性 RNG 流）。
6. **攻速传导轴**：AFF_ROF_UP/AFF_CDR 挂棱镜即全体镜面生效——接线点=共享组 `refresh_weapon_intervals` 扩扫 `_mirror_images`（player.gd:515-523 现成模板）；新词条 `MEC_MIRROR_TEMPO`「镜面奏鸣」——仅镜面攻速 +15%/层 ×2（「本体熄灯、全灌镜子」专精分叉）。单镜 rof 帽 30/s、CDR 池帽 0.6 逐镜独立。
7. **元素涂装轴**：镜面元素读自身栈=棱镜栈（`weapon_base.gd` dominant_element 通道现成）；棱镜挂一张 ELE 卡=全部镜面统一涂该元素，与源武器元素错开即稳定双元素反应。**硬裁定：ELE 反应乘区只在棱镜本体 uid 单源注册一次，镜面只继承元素色不注册乘区**（对照 R183 逐副本重注册先例 player.gd:761-769——永久件逐镜注册=×4.7^N 雪球，R183 曾因此出 P1 泄漏）。
8. **质变**：W5 threshold_traits 删 3 条弹道死声明，替换 `TH_MIRROR_CHOIR`（metric=`mirror_count`、threshold=3）——mirror_ratio+0.1（有效帽 0.7）；`TH_CRIT_SHARD` 0.6→0.35。
9. **读感区分（强制）**：镜面银白/冰青染色（禁用金色调性）、常驻化身无金色剪影；横幅句式「棱镜映照：镜面承接了 X」（对照 R183「召唤僚机：复制了 X」）；镜面弹体加镜像描边/色相标识（弹体贴图按 weapon_ref 分派会与本体同貌）。
10. **存档纪律修正（对三份提案的统一否决）**：工程纪律冻结 `scripts/meta/`（RunSave/MetaManager）与 user:// 口径——**不新增 mirrors/mirror_seed 存档键**。镜面集合为会话态：读档/波首按确定性规则（武器槽序 + 固定哈希(武器 id)）重推导指向，局内重掷卡只影响会话内状态；文档明示「镜面不做逐帧还原」，构筑漂移由 LOCK 卡（确定性出口）兜底。
11. **性能护栏**：镜面组发射预算 ≤600 发/s（超预算该拍静默跳过 + DebugStats 计数）；指向激光武器的镜面共享 laser 池，**激光镜 ≤2 面**、池满静默降级为锚束标记。

**BuildAxes**：① 镜数（等级曲线 + MEC_MIRROR_SPLIT，帽 5）→ ② 强度（mirror_ratio 精通 + TH_MIRROR_CHOIR）→ ③ 指向（prism_pointer 二选一）→ ④ 节奏（AFF_ROF_UP/AFF_CDR 全镜传导 + MEC_MIRROR_TEMPO）→ ⑤ 元素涂装（ELE 单源）。

**Numbers**（对齐基准：现 L5 群体 358、R183 定价锚）
- 基线 L1：锚束单体 35（7×5）+ 1 镜 ×0.40×源面板（照 L1 手枪 70 → 28）→ 系统常态 ≈63。
- 成长：mirror_ratio 0.40→0.60；L5 标定：3 镜照 L5 手枪=3×154×0.60≈277+本体 75≈**352**，与现 L5 群体第一档 358 持平（重做前后总输出曲线不断裂）；镜面白板不吃源 buff（玻璃大炮等挂源词条对镜面无效）天然压住「喂肥武器」的套利。
- 上限：5 镜×0.60×(1+36% ROF)×满层质变 1.6≈×3.3 源出厂面板（按 L5 加特林 254 标定 ≈840 阵列+本体）；五重兜底=单镜 30/s 帽、CDR 池 0.6、add_pool_caps、cap_prod 8.0、600 发/s 镜面预算；激光池：锚束 1+激光镜 ≤2 ≤3 段。
- R183 对照：诺亚=瞬时 2.0×/平均 ≈0.17×（2 副本×10s/120s）；棱镜=永久、每镜 0.40~0.60、满投入 ≈3.0×——「免费 10s 爆发」vs「全卡池经济灌出的永续阵列」。

**Acceptance**
1. 白板反向断言（R183 反义）：源武器挂玻璃大炮+ELE 卡后生成镜面 → 镜面 trait_stack 与**棱镜栈**逐层一致（含 layer_values/layer_rarities）、与源武器栈条目**零交集**（对照 verify_feedback_cases.gd:2146-2159 全量拷贝断言的镜像反向）。
2. 永久反义：驱动 11s（>SUMMON_DURATION）镜面仍在场、指向不变、且不在 `_summon_copies`；`_reset_skill_temp_state` 后 `_summon_copies` 空而 `_mirror_images` 原样。
3. 吃棱镜 buff 逐层一致：棱镜挂 add_atk +15%×2 → 镜面 aggregate_panel 同 id 同层；满 3 层断言镜面伤害含 ×1.6 满层质变。
4. ELE 单源防泄漏：棱镜挂金 ELE 反应卡+3 镜 → 反应乘区注册源数==1（仅棱镜 uid）；驱动 120s 注册数不增长。
5. 数量帽：挂 MEC_MIRROR_SPLIT×2 → `_mirror_images.size()==3`（L5 基线）+再挂钳制在 5；镜面 ∉ weapon_slots、WEAPON 卡候选集零污染。
6. 攻速传导：`refresh_weapon_intervals` 后镜面 `_fire_interval` 与本体同倍率更新（扩扫断言）、镜面 rof 钳 30/s；镜面组发射率 ≤600 发/s 压力子测试。
7. 指向轴：MEC_MIRROR_WEIGHT 生效时镜面指向面板 DPS 最高武器；同 seed 重放逐项一致；LOCK 后波首不重掷。
8. R183 互斥：场上有镜面时施放诺亚技能 → 复制池排除 W5_prism（或复制体为哑枢纽）、`_mirror_images` 与 `_summon_copies` 互不包含；R183 段（:2094-2182）原样全绿。
9. 表现退役：W5 图标=棱形镜子且与其余 9 武器像素互异；`GameConst.weapon_note("W5_prism")` 不再含「折射/分光」且含「镜」；镜面为银白/冰青染色断言。

---

### 2.3 双火箭（W6_micro_missile / W7_cluster_rocket）——「蜂群与攻城锤」（提案 2 骨架 + 提案 3 的溅射口径与引信连携）

**Design**
1. **30% 规格裁定（溅射口径，对三提案数值分歧的最终裁决）**：需求原文「爆炸范围与伤害约为大火箭的 30%」→ **爆径 ≈30% + 爆炸（溅射）伤害 ≈30%**；W6 直击是精度生态位**不参与缩放**（直击砍到 30% 会让 L1-L2 塌 33-41%，与「前期可用」冲突）。W6 新键 `blast_atk_ratio=0.6`（W7=1.0）：溅射伤=0.6×W6 atk，对 W7 atk 逐级 28.4/34.7/28.7/30.0/28.2% 均值 **30.0%**。
2. **W6 齐射轴**：homing 段新增 `volley_count_levels=[1,1,2,2,3]`（L3 小质变并排双发、L5 大质变三联，`_leveled_param` 通道 homing_weapon.gd:121-126 现成）；消费点=`HomingWeapon.try_fire` 发射循环（现硬编码单发 :25-69）；出膛 ±10° 扇形利用 arm_delay 0.15s 直飞段做「并排→汇聚」可读弧；分散规则=第 i 发锁第 i 近目标（query_nearest 带 exclude 迭代），目标不足时余弹退回最近目标且直击 ×0.6^j 递减。手感修正：`proj_speed_init` 240→420（修「小火箭反而比 W7 慢」矛盾，speed_max≥speed_init 校验通过）。
3. **W6 专属卡**：`MEC_HIVE_RACK`「蜂巢挂架」——volley +1/层 ×2、`params.required_weapon=[&"W6_micro_missile"]` → 硬顶 5 枚/轮（运行时 clamp [1,5]）。
4. **阈值分叉（身份线，不可裁）**：现 W6/W7 四条 threshold_traits 逐字相同。W6 换出 `TH_SIZE_NOVA` → 新 `TH_SWARM_NOVA`（metric=`volley_count`、threshold=5、新 `EF_SWARM_NOVA` 入白名单）——每枚空爆 1.2×blast_r 冲击波 30%ATK；W7 保留 `TH_SIZE_NOVA`+`TH_FRACTAL_ECHO`+`TH_BOUNCE_ETERNAL`，W6 留 `TH_SWARM_NOVA`+`TH_FRACTAL_ECHO`+`TH_BOUNCE_ETERNAL`+`TH_CRIT_SHARD`(0.35)。
5. **引信连携轴（双武器独占，构筑深度增量）**：`MEC_FUSE_COAT`「引信涂层」（required_weapon=[W6]，stack_max=2）——W6 直击为敌挂引信 4s（幂等刷新，敌身通用标记通道，共享组 `enemy.gd` 新字段 `fuse_left`）；引信目标受到的**自导爆炸**伤害 +20%/层。`MEC_FUSE_DETONATE`「定向爆破」（required_weapon=[W7]，stack_max=2）——W7 爆炸命中引信目标时消耗之，追加 0.5/层×W7 atk 余波（半径 0.5×blast_r），每敌 0.5s 护栏防同帧双爆双吃。卡面明示「需引信涂层」；W6 单持自爆也吃 +40% 增伤（单卡自洽）。
6. **W7 攻城轴（保有）**：atk/cd/sub 全不动；`blast_r` 冻结 110（距校验帽 128 余 18）；慢节拍 3.2→2.6s 单次清屏事件；CDR 帽 0.6 → 1.04s 节拍与 REL_CRIT_CHAIN「暴击即再装填」路线自然成立，不为 W7 写新专属成长。
7. **表现分档**：爆径 <50 的爆炸 → HIT 档震屏 + 小爆独立音效名（现状爆炸一律 CRIT 级震屏无节流，齐射满配 26 爆/s 必糊屏；顺带解决 W6 旧爆径 100 撞 radius≥100 大爆门的误读）。
8. **validator 补口（随数据同步落地）**：`volley_count∈[1,5]`、`blast_r_levels` 逐级 ∈(0,128]、`blast_atk_ratio∈(0,1]`、所有 homing `_levels` 数组长度==5（现 `_validate_homing_segment` 只查 4 键不查数组，必须补规则防静默越界）。
9. **R183**：复制体 W6 `volley_eff=1`、W7 `sub_eff=min(sub,3)`（copy_full 后叠加折减）；引信幂等+0.5s 护栏保证复制放大覆盖不放大指数。

**BuildAxes**：① 齐射数量（等级 1→3 + 蜂巢挂架 →5）→ ② 节拍（AFF_CDR 帽 0.6 → 0.192s；高频小爆=REL_ATTACK_CDR 计费/暴击弹片最优载体）→ ③ 引信连携（FUSE_COAT + FUSE_DETONATE 双卡成套）→ ④ W7 规模（SIZE_NOVA + MEC_FRACTAL 分裂链，现有三闸 gen≤3/单次≤8/池软上限）。

**Numbers**（对齐基准：W6/W7 .tres 现网值、A3 单体曲线）
- W6 直击不动：单体 DPS 32.7/40.0/45.8/56.3/66.7；爆径 `blast_r_levels=[30,32,34,36,38]`（对 W7 110 = 27.3~34.5% 均值 30.9%）；`blast_atk_ratio=0.6`；齐射成长：L3 双发双锁 ×1.6 铺场、L5 三联同目标 1.0+0.6+0.36=×1.96 → 130.7（3 目标 ×3=200，为 W7 Boss 全中 235.4 的 55%~85%，不越界打桩）。
- W7 完全不动：Boss 全中 (1+sub)×atk/cd = 71.2/83.1/100.6/151.9/235.4（×3.30 全武器最陡，原样保有）。
- 上限：W6 满配 volley 5×CDR 0.6 → cd 0.192s ≈26 发/s，in-flight ≈39 < homing 池 soft 64（game_loop.gd:975-976 口径）；引信满配 ≈×1.6 W7 裸（+40%×每轮 ≤2 次引爆）≈ Boss 全中 ~382——本方向设计天花板，测试断言死这个数；全场弹池 1500/2000 不动。

**Acceptance**
1. 比例断言（新套件 `test_w67_rocket.gd`+`w67_rocket_cases.gd`，seed(42)+DT=1/120 两段式）：逐级 W6.blast_r_levels[i]/110∈[0.25,0.36] 均值∈[0.27,0.34]；(0.6×W6.atk[i])/W7.atk[i] 逐级 ≤0.40 且均值∈[0.28,0.33]；W7 全字段等于现网（38/38/46/54/68、sub [5,6,6,8,8]、blast_r 110、阈值含 TH_SIZE_NOVA）；W6 阈值含 TH_SWARM_NOVA 且不含 TH_SIZE_NOVA。
2. 齐射行为：L5 volley=3 对 3 dummy → 单节拍恰 3 弹 target_uid 互异；对 1 dummy → 3 弹同锁且伤害序列=atk×[1.0,0.6,0.36]±1；挂 MEC_HIVE_RACK×2 → 5 弹（clamp [1,5]）；同卡对 W7/W1 合成体出弹数不变；homing 池取空 try_fire 返回 false 不崩。
3. 引信/引爆：挂 MEC_FUSE_COAT×2 → 命中后敌 `fuse_left>0` 且重复命中幂等；引信敌受自导爆炸伤 ×1.4；挂 MEC_FUSE_DETONATE×2 的 W7 爆炸命中引信敌 → 追加恰一次 2×0.5×atk 结算且 fuse 清零，0.5s 内第二次爆炸无追加；无卡对照零增伤。
4. validator：volley_count∈[1,5]/blast_r_levels 逐级∈(0,128]/blast_atk_ratio∈(0,1]/_levels 长度≠5 均报 error（负例用例），非法值武器被剔除。
5. R183 折减：`_make_weapon_copy` 后副本 volley_eff==1（W6）/sub_eff==min(sub,3)（W7）；满配双火箭+双副本 tick 10s → homing 在场弹峰值 ≤64、丢弃计数可读、无崩溃。
6. 表现分档：blast_r<50 爆炸事件震屏档位==HIT 档（驱动分档实现）。
7. 回归：既有套件零放宽（pkg3/pkg2 基线 127/141 保持）。

---

### 2.4 手枪（W1_pistol）——「并行弹幕 ×跳弹增值」双路线（提案 1 骨架 + 提案 3 跳弹轴；提案 2 节拍引爆轴落选）

**Design**
1. **五级表重排（修两点回归）**：L1 14×5.0 穿1（70 面板 DPS，p1_polish 锚不动）、L2 16×5.0（80）不变 → **L3「双管并排」**11×5.5×2=121（旧 L5 双发前移+真横向偏移）→ **L4** 13×5.5×2 穿2=143（**修 :38 pierce 2→1 倒退**）→ **L5「三线收束」**12×5.5×3 穿2=198（落霰弹 201.6 的 98%）。曲线 ×2.83；同步修 L1/L2 过期 note（.tres:13/:22 仍写 60/70）。
2. **阵型几何轴（W1 专属，纯数据驱动）**：ballistic 段新增 `lateral_gap_levels`（L3=±6px / L5=±12px 出膛横向偏移，spawn 契约 position 侧实现）与 `converge_pct_levels`（L5 起在 55% 射程向瞄准线收束——唯一新增弹体行为，steer 通道由共享组在 projectile 侧开放，武器组只传参）；新词条 `MEC_PARALLEL_CAL`「平行校准」add_gap +4px×3 层 → ±24px 覆盖态，且收束点 55%→70%——覆盖↑则打单时窗↓的真实取舍，杜绝「加丸不扩锥、行为不变」换皮。
3. **数量底盘**：AFF_MULTI 现成（pellets +1×2 层 ×1.45 计数梯）+第 4 关满层质变 ×1.6 → 全链 clamp [1,16]（validator 合法域内）至 15~16 管。
4. **跳弹增值轴（提案 3 杂交）**：ballistic 段新增 `bounce_levels=[0,0,1,1,2]`（L3 起弹丸自带反弹预算，把 ballistic_weapon.gd:76 硬编码 `"bounces":0` 改读 `_leveled_param`）+ `bounce_amp=0.12`/`bounce_amp_cap=1.0`（L5 大质变「跳弹增值」每次反弹后命中伤害 +12%，加算 cap +100%）；复用现成乘区链 MEC_BOUNCE→TH_BOUNCE_ETERNAL(≥5 永存)→SYN_BOUNCE_SPEC→REL_MOMENTUM；新组合卡 `MEC_RICOCHET_HALL`「回廊弹幕」（`requires_trait=MEC_BOUNCE` 门，card_generator.gd:459-481 现成）——反弹后 offset 镜像保持编队回场（散弹变回廊弹幕）。
5. **终局质变**：`TH_BANK_SHOT`「黄金弹」（metric=`bounce_count`、threshold=12）——单弹累计反弹≥12 升格黄金弹（后续反弹必暴 + 落点弹片），金色弹染 + 永存弹标记补表现（现永存态零视觉）。
6. **弹幕态**：`TH_VOLLEY_STATE`（metric=`pellets`、threshold=6、新 `EF_VOLLEY` 入白名单）——激活 4s 内开火间隔 ×0.8、并排 +2（超 16 帽部分转阵宽 +50% 补偿）→ 3s 散热；净 rof ×1.14 占空比自平衡；首次激活派发 EventBus 信号 + hud toast（顺带修「四质变触发零表现」）。永存弹同屏配额 240（达满后新弹不再获永续 lifetime）。
7. **落选声明**：提案 2「六发装填·装药引爆」整轴不采纳——引爆动词已归 W8（敌侧状态机）与 W6/W7（引信连携），手枪再上「挂层-引爆」即三重撞车；其 pierce 修复、TH_CRIT_SHARD 0.35、validator 补口、性能先扩压测四项已被本整案吸收。
8. **共享修复依赖**：`MEC_FRACTAL.tres` inheritable=false→true（激活 W1 自带 TH_FRACTAL_ECHO——split_depth≥3 现因子代不继承而结构性永不可达）；仍受分裂三闸（gen≤3/子≤8/池软上限 1500）约束。
9. **R183**：副本执行同 lane 参数 + 独立弹幕态计时 + 金色染色；本质分工=R183 是任意武器的临时全局放大器，W1 是永久构筑行为，二者叠加是增益而非重复。

**BuildAxes**：① 编队数量（等级 2→3 丸 + AFF_MULTI → 15~16 帽）→ ② 几何取舍（lateral_gap/converge + 平行校准）→ ③ 跳弹增值（bounce 预算 + 回廊弹幕 + 黄金弹）→ ④ 弹幕节奏（TH_VOLLEY_STATE）。

**Numbers**（对齐基准：60×1.12^(w-1) 对齐线、TTK 目标 1.2s、加特林 254 终盘）
- 面板 DPS：70/80/121/143/198（L1 TTK≈0.82s 达标；L4@w10 143 vs 期望 166 −14%，如实标注中期略欠由质变行为补齐；L5≈霰弹 201.6 的 98%）。
- 上限：并排全链硬帽 16（validator [1,16] 域内）；rof 满配 8.7/s ≪ 30/s 帽（本路线不碰 rof 轴）；弹幕态净乘区 ×1.14；永存弹配额 240 → 满配稳态活弹 ≈510 ≪ 软上限 1500（正面堵死数量路线 2000+ 活弹池满自锁）；跳弹乘区链 ×1.3×1.8×2.0×1.8≈×8.4 被 cap_prod 8.0 截断。
- 性能前置：**先扩 800 弹档压测锚（P95<8.3ms）再做弹幕化**（现压测仅 500 弹=软上限 1/3）。

**Acceptance**
1. 锚点不破：`test_p1_polish.gd` 保持 PASS 17/0（L1=14/L2=16 锁存活，本会话已实跑基线）；新套件 `test_w1_volley.gd` 断言直读新表面板 DPS=70/80/121/143/198±0.5、L4/L5 pierce==2、upgrade_table 恰 5 项。
2. 并排几何确定性：L3 一次 try_fire 产 2 弹 offset={-6,+6}px；L5 产 3 弹 offset={-12,0,+12}px；seed(42) 重复 10 次一致；L5 弹步进模拟至 55% 射程处三弹距瞄准线 <10px，L3 对照弹全程 12px 间距。
3. 跳弹：L1/L2 出弹 bounces_left==0、L3==1、L5==2；挂金 MEC_BOUNCE 1 层后 L5 预算==7；模拟 5 次 ON_BOUNCE 触发 TH_BOUNCE_ETERNAL（lifetime≥999）、4 次不触发；增值乘区经 cap_prod 8.0 截断断言；反弹累计≥12 黄金弹必暴断言。
4. TH_VOLLEY_STATE：pellets=6 触发/5 不触发；触发后 `_fire_interval`×0.8 持续 4.0s → 3.0s 恢复；首发激活 EventBus 信号计数 + toast 断言。
5. 上限阀压测：满配（15 丸+MEC_BOUNCE+弹幕态）30s 连射：永存弹峰值 ≤240、稳态全场活弹 <600、pool.acquire 拒收率 <1%；800 弹档 P95<8.3ms。
6. 区分度：诺亚副本 try_fire 产同阵型弹且副本弹幕态计时独立；REL_ECHO 把「平行校准」挂到 W2 时 add_gap 不生效（挂载侧 required_weapon 校验，防回响绕门 P0 前科）。
7. validator：ballistic 段 lateral_gap_levels/converge_pct_levels/bounce_levels 长度≠5 报 error；EF_VOLLEY/EF_BANK 未入白名单时被剔除的反证用例。

---

### 2.5 环绕力场（W8_orbit_field）——「蓄能轨道」目标侧状态机（提案 2 主干 + 提案 3 的数量语义与复制体裁定）

**Design**
1. **拆 R186 附着位（需求硬约束）**：径直删除 `orbit_field.gd` 的 attach 三件套（:34-36 声明、:59-62 注入、:208-233 附着链）与 `orbit_weapon.gd:201-202` 注入——本会话已 grep 核实 `attach_gate|attach_mult|_orb_element` 在 tests/ 零命中，拆除零契约阻力。W8 成为全场唯一禁元素武器。
2. **蓄能状态机（新核心）**：保留常驻公转+周期接触判定骨架（无敌人也在场、try_fire 恒 false）；每次接触对目标 +1 蓄能（接触伤不变，输出底），同目标蓄能获取共享内冷却 `charge_gain_cd`（替代全场无敌人也能触发的死数值 hit_cd 语义）；蓄满 `charge_max=5` 档 → 以目标为圆心引爆 `detonate_mult×atk` 的 `detonate_radius=90px` 环形 AoE 并清零重蓄。**时钟在敌人身上**——全 10 武器无人占位的「锯齿输出」。蓄能池以**目标 uid 为全局单例**（敌身通用标记通道 `charge_stacks`，敌亡回收），本体+复制体共享加速、引爆当量不复制。
3. **引力脉冲（死键激活）**：melee 段 `cd=1.0`（自记「轮询节拍占位」）改义为 `pulse_cd=3.0`——每拍给环内全部已蓄能目标 +1 蓄能，公式走 `weapon_base.gd:378-391` 的 cd×(1−ΣCDR)/rof_mult 通道——AFF_CDR 对 W8 首次生效（现全构筑 add_cdr 仅 W9 在吃）。
4. **引爆预算三道闸**：全局引爆共享 ICD `detonate_global_icd=0.5s`；单目标引爆 ICD 0.25s；单目标有效伤害刀数帽 `effective_blade_cap=8`（对齐 melee 段现成但无人消费的 max_targets:8）——数量词条语义从「单体乘法器」转为「环带覆盖面+提前饱和」。
5. **形态卡改义（exclusive_group 现成三卡，全部从死数值改真数值）**：`MEC_ORBIT_SWORD`「刃舞」hit_cd×0.75（接触窗 0.16s≪0.5s，0% 实效的死数值）→ `charge_gain_cd×0.7`（唯一抬蓄能天花板的卡）；`MEC_ORBIT_AXE` 维持现有乘区（带+25%/球径×1.15/击退×1.6/转速×0.85——控场换节奏）并追加引爆半径 +15%/层；`MEC_ORBIT_BOLT` 转速 ×1.5 维持（=蓄能率 +50%）。`MEC_GIANT_BLADE` 巨刃从纯视觉 knife_scale 改义：保留视觉 + 引爆半径 +15%/层×2。
6. **当量/传导新卡**：`MEC_CRITICAL_MASS`「临界质量」——引爆倍率 5×→7×、半径 70→85px（stack_max=2）；`MEC_CHAIN_DETONATE`「链式引爆」——引爆时转移 floor(charge_max×0.4)=2 档蓄能给 160px 内最近敌（纯物理通道，构成「先打谁、传给谁」的清场排序）；AoE 溅射**不回灌蓄能**（防滚雪球）。
7. **塑场轴**：击退从径向外推（现把敌人推出伤害带=反 DPS 源）改**切向 60%+径向归环 40%**；共享组修 `MEC_KNOCK.tres` required_forms [0,2]→[0,2,3]（W8 form=3 是全工程唯一 add_knock 消费点 orbit_weapon.gd:192-193，现被排除=死接线）；自爆引信打断契约（AC-06.1）原样保留。
8. **阈值重写**：删 3 条投射物死声明（TH_SIZE_NOVA/TH_FRACTAL_ECHO/TH_BOUNCE_ETERNAL），保留 `TH_CRIT_SHARD`（0.35）；新增 `TH_DETONATION_ECHO`（metric=`detonation_count`≥8 → 下次引爆 ×1.5）、`TH_RING_PRESSURE`（metric=`charged_hits`≥60 → 本局引爆半径 +20%）——消费走 `weapon_base.get_threshold` 现成通道。
9. **数据键全落 .tres melee 段**（吸取 attach_mult 只在代码缺省未落 .tres 的教训，FEEDBACK_TRACKER R186 段）：`charge_max=5`、`charge_gain_cd_levels=[0.5,0.45,0.4,0.35,0.3]`、`detonate_mult=5.0`、`detonate_radius=90.0`、`detonate_global_icd=0.5`、`pulse_cd=3.0`、`effective_blade_cap=8`。
10. **表现（R186 挨骂的直接教训——表现是验收项）**：新 `PopupStyle.CHARGE_BURST` 专用跳字样式（现 7 种样式且同 uid 同桶合并会把引爆大数字吞进白字）；蓄能目标头顶「蓄能 x/5」档位读数；首获横幅重写为「蓄能撞击·满档引爆」（现 game_const.gd:84 文案承诺了从未实现的护盾）。
11. **R183**：蓄能池目标 uid 单例（复制体只加速蓄能、永不复制引爆当量）——整个蓄能周期恰 1 次引爆断言；复制体固定 BASE 单环阵 + 相位偏移 45°、节点计数按实例独立。

**BuildAxes**：① 蓄能速率（转速/orbs/LINK 梯/SWORD 改义/BOLT）→ ② 引爆当量（MEC_CRITICAL_MASS + 巨刃/斧改义 + 双阈值质变）→ ③ 拍频（pulse_cd + AFF_CDR 首次生效）→ ④ 传导排序（MEC_CHAIN_DETONATE）→ ⑤ 塑场（切向击退 + MEC_KNOCK 解锁）。

**Numbers**（对齐基准：探索员锚 L1≥25、L5≥110；夹 W6 66.7 与 W1 132 之间；单体帽 254=W2 满热）
- 公式（写死进实现与测试）：蓄能速率 `R = min(orbs×angular/360 + 1/pulse_cd, 1/charge_gain_cd)`；引爆周期 `T = charge_max/R`；合计单体 DPS `= atk×R + detonate_mult×atk/T`。
- 裸装曲线（含默认脉冲 +1/3s）：L1 R=min(1.33+0.33, 2.0)=1.66 → 33.3；L2 43.3；L3（R 饱和 2.5）65.0；L4 96.3；L5（cap=1/0.3=3.33）**113.3**——×3.4 成长，锚点 L1≥25 ✓ L5≥110 ✓。
- 上限：满配 LINK 16 刀受 effective_blade_cap=8（接触 DPS ≤190）+ 单体 254 帽（帽外对 ≤8 目标内次级敌人 50% 分流）；引爆流全局 ICD 0.5s → 引爆 ≤2 次/s；群体 max_targets=8 并行蓄能；词条预算：现 5（互斥组 3+LINK+巨刃改义）+新 2（CRITICAL_MASS/CHAIN_DETONATE）+MEC_KNOCK=8 ≤12 帽。
- 与 W9 数值身份错开：W9 单体 15.6→36.7/群 8 目标≈293 低频高机动斩；W8=33→113 持续+周期引爆带内压制。

**Acceptance**
1. 回归门：`test_weapon_orbit.gd` 保持 PASS 42/0（本会话已实跑基线；W9 追击/LINK 梯/巨刃/攻速既有契约零波及，巨刃改义用例随翻转清单迁移）。
2. R186 移除负向断言（新套件 `test_w8_charge.gd`+`w8_charge_cases.gd`）：挂 ELE 词条 tick 240 帧 → 目标 elemental 状态恒空、apply_attach 经 W8 路径零调用。
3. 蓄能确定性（静止敌+DT=1/120）：逐 tick 断言蓄能增量、满 5 档恰触发 1 次引爆、池清零、AoE 落伤=5×atk、DebugStats `w8_detonations` 逐一吻合；同帧双球触达同目标蓄能仅 +1（charge_gain_cd 生效）；两目标同帧满档 → 第 2 次引爆延后 ≥0.5s（全局 ICD）。
4. 帽与复制：16 刀单体 40 tick 命中事件数 ≤ 8 刀等价位（effective_blade_cap）；本体+R183 复制体打同一目标 → 整个蓄能周期恰 1 次引爆（目标 uid 单例断言）；复制体阵形=BASE+相位 45°。
5. 脉冲与 CDR：已蓄能目标每 pulse_cd +1；挂 AFF_CDR×2 → 脉冲间隔=3.0×(1−0.2)；MEC_KNOCK 改 [0,2,3] 后 W8 货架可出该卡且 add_knock 进击退终值。
6. 塑场：命中后敌速度切向分量>0、径向外移 ≤8px/击；自爆引信打断用例保持 PASS。
7. 数值探针：headless 静止敌 10s 模拟 L1 裸装 33±10%、L5 裸装 113±10%、满配 ≤254。
8. 性能：`tests/stress/test_perf_500p100e.gd` 帧耗不回退（蓄能字典随敌死亡回收键）；全量套件电池退出码全 0。

---

## 三、共享系统改动清单（sharedChanges）

1. **texture_factory 图标**（scripts/ui/texture_factory.gd）：W5 → 棱形镜子图案（与其余 9 武器像素互异，vf 互异断言先例）；W6/W7 → 尺寸/弹头数区分强化（R184 已分色钢蓝/橙红，补大小差）；W4 → 分束视觉（副束细束第三谱系色）；镜面弹体镜像描边；W1 黄金弹金染。
2. **卡池与词条**（scripts/cards/card_generator.gd + resources/traits/*.tres）：22 个新词条 id 全局唯一上架（见 §五命名表）；`COUNT_TRAIT_IDS` 增补 MEC_SPLIT_PRISM / MEC_MIRROR_SPLIT / MEC_HIVE_RACK；`MEC_KNOCK.tres` required_forms [0,2]→[0,2,3]；`MEC_FRACTAL.tres` inheritable false→true；新 EF（EF_CHOIR/EF_SWARM_NOVA/EF_VOLLEY/EF_BANK/EF_DETONATION_ECHO/EF_RING_PRESSURE）入 TECH_EFFECT_IDS 白名单；权重审计：新专属卡全部带 required_weapon/required_forms 门，AFF_MULTI 保持 [0] 不越界。
3. **DataValidator**（scripts/core/data/data_validator.gd）：laser 段 `sub_ratio∈(0,0.75]`/`mirrors_count∈[0,5]`/`mirror_ratio∈(0,0.7]`；ballistic 段 `lateral_gap_levels/converge_pct_levels/bounce_levels` 长度==5、`bounce∈[0,5]`；homing 段 `volley_count∈[1,5]`、`blast_r_levels` 逐级∈(0,128]、`blast_atk_ratio∈(0,1]`；melee 段 `charge_max∈[3,8]`、`charge_gain_cd∈(0,1]`、`detonate_mult∈(0,10]`、`detonate_radius∈(0,128]`、`pulse_cd∈(0,30]`、`effective_blade_cap∈[1,16]`；**通用补口：任何 `<key>_levels` 数组长度≠upgrade_table 长度报 error**；W5 删 refract_* 键后零告警、W4 删 pulse_duration/tick_rate 后零告警。
4. **HUD / EventBus / 文案**（scripts/ui/hud.gd、autoload/event_bus.gd、autoload/debug_stats.gd、scripts/core/game_const.gd）：新信号 `laser_subbeam_spawned(owner_kind: 本体/僚机)`、`mirror_formed(text)`、`w8_detonated`；HUD 束数徽标（W4）+ 镜面 ×N 角标（W5）+ W8 蓄能读数位；新 `PopupStyle.CHARGE_BURST`；weapon_note 重写：W4（裂片棱镜多束）、W5（镜面枢纽，禁「折射/分光」）、W6（齐射引发器）、W7（攻城引爆器）、W8（蓄能撞击·满档引爆，禁「护盾」）、W1（并行弹幕/跳弹）。
5. **player.gd（跨组热点，归共享组）**：`_mirror_images` 独立数组 + 镜面生成/重掷/读档确定性重推导；`refresh_weapon_intervals` 扩扫镜面数组；R183 复制池排除 W5_prism + 各武器复制体折减裁定（W4 sub_beams=0 / W6 volley_eff=1 / W7 sub_eff=min(sub,3) / W8 蓄能单例+BASE 阵 / W1 同 lane）+ 复制体染色字段。
6. **enemy.gd 敌侧通用标记通道**（归共享组）：`fuse_left`（W6/W7 引信）与 `charge_stacks`（W8 蓄能）字段 + 死亡回收（防 tracker:424 只减不清前科）。
7. **projectile_base.gd（归共享组）**：激光跳伤接通 `inject_relic_pools` 的公共入口；W1 converge steer 通道开放；REL_ECHO 挂载侧 required_weapon 校验补挂（防回响绕门 P0 前科 META_ROADMAP.md:126）。
8. **balance_tables.tres**：池参数不动（cap_prod 8.0 / add_pool_caps / 弹池 1500/2000 / laser 12 全沿用）；如需镜面预算键 `mirror_budget_per_s` 落 W5 .tres 不落全局表。
9. **压测扩锚**（tests/stress/）：新增 800 弹档（P95<8.3ms 门）——**先扩锚后弹幕化**，手枪弹幕态与 W6 齐射满配依赖此门。
10. **存档层冻结**：`scripts/meta/`（run_save/meta_manager）与本轮**零改动**——W5 镜面为会话态+读档确定性重推导（§2.2 第 10 条），三份提案的 mirrors 存档键全部否决。
11. **既有测试翻转（归共享组，禁止放宽/删除既有断言语义，只能按新契约翻转）**：pkg3_cases.gd 激光段（:779-906）、verify_feedback_cases.gd R91（:4330-4383 重写）与 R183 段（:2094-2182 **原样保留**）、cd_pace_cases.gd:103-119（W4 CDR 换挂）、pkg5_cases.gd TH_CRIT_SHARD 用例（0.6→0.35）、weapon_orbit_cases.gd（W8 附着用例删→蓄能用例增）、pool_wiring_cases.gd（新词条上架审计）。

---

## 四、实现分组（文件互斥，组间绝不重叠）

> 规则：武器组只准改自己武器相关文件；一切共享文件（texture_factory/cards/traits/validator/HUD/EventBus/player.gd/enemy.gd/projectile_base.gd/balance_tables/既有套件翻转）一律归共享系统组。`scripts/meta/` 任何组都不准改。

### 共享系统组（1 组）
**files**：`repo/scripts/ui/texture_factory.gd`、`repo/scripts/ui/hud.gd`、`repo/scripts/ui/popup_manager.gd`、`repo/scripts/cards/card_generator.gd`、`repo/scripts/core/data/data_validator.gd`、`repo/scripts/core/game_const.gd`、`repo/autoload/event_bus.gd`、`repo/autoload/debug_stats.gd`、`repo/scripts/entities/player/player.gd`、`repo/scripts/entities/player/weapon_orbit_avatars.gd`、`repo/scripts/entities/enemy/enemy.gd`、`repo/scripts/combat/projectile/projectile_base.gd`、`repo/data/balance/balance_tables.tres`、`repo/resources/traits/`（全部新词条 .tres + MEC_KNOCK/MEC_FRACTAL 修改）、`repo/tests/runner/pkg3_cases.gd`、`repo/tests/runner/verify_feedback_cases.gd`、`repo/tests/runner/cd_pace_cases.gd`、`repo/tests/runner/pkg5_cases.gd`、`repo/tests/runner/weapon_orbit_cases.gd`、`repo/tests/runner/pool_wiring_cases.gd`、`repo/tests/stress/`（800 弹档）
**tasks**：§三全部 11 项；既有套件按 §三.11 翻转；聚合各组的 validator 新键规则并统一实现（避免五组各写一遍）。

### 激光组（W4）
**files**：`repo/resources/weapons/W4_pulse_beam.tres`、`repo/scripts/combat/weapon/laser_weapon.gd`、`repo/scripts/combat/weapon/laser_beam.gd`、`repo/tests/runner/test_w4_prism.gd`（新）、`repo/tests/runner/w4_prism_cases.gd`（新）
**tasks**：§2.1 全部；数值落地（base_atk 6/7/7/9/11、删 pulse_duration/tick_rate、sub_ratio_levels）；验收 1-7 映射成 test_w4_prism 用例；灼焦目标侧单池重构在本组文件内完成（W5 组依赖此裁定，落地顺序激光组先行）。

### 棱镜组（W5）
**files**：`repo/resources/weapons/W5_prism.tres`、`repo/scripts/combat/weapon/mirror_weapon.gd`（新）、`repo/scripts/combat/weapon/mirror_image.gd`（新）、`repo/tests/runner/test_w5_mirror.gd`（新）、`repo/tests/runner/w5_mirror_cases.gd`（新）
**tasks**：§2.2 全部；依赖共享组完成 `_mirror_images` 数组与 refresh 扩扫后接线验收 6；W5 laser 段真删 refract 五键+新增 mirror 四键。

### 双火箭组（W6+W7）
**files**：`repo/resources/weapons/W6_micro_missile.tres`、`repo/resources/weapons/W7_cluster_rocket.tres`、`repo/scripts/combat/weapon/homing_weapon.gd`、`repo/scripts/combat/projectile/homing_projectile.gd`、`repo/tests/runner/test_w67_rocket.gd`（新）、`repo/tests/runner/w67_rocket_cases.gd`（新）
**tasks**：§2.3 全部；blast_atk_ratio 消费点在 homing_projectile 爆炸结算内（本组文件）；W6 volley 循环+第 i 近索敌；W7 仅加 blast_atk_ratio=1.0 与阈值保留声明。

### 手枪组（W1）
**files**：`repo/resources/weapons/W1_pistol.tres`、`repo/scripts/combat/weapon/ballistic_weapon.gd`、`repo/tests/runner/test_w1_volley.gd`（新）、`repo/tests/runner/w1_volley_cases.gd`（新）
**tasks**：§2.4 全部；五级表重排+pierce 修复；lateral_gap/converge/bounce 消费点（converge 的弹体 steer 执行走共享组开放的通道，本组只传参与断言）；依赖共享组 MEC_FRACTAL inheritable 修改后验证 TH_FRACTAL_ECHO 激活。

### W8 组
**files**：`repo/resources/weapons/W8_orbit_field.tres`、`repo/scripts/combat/weapon/melee/orbit_weapon.gd`、`repo/scripts/combat/weapon/melee/orbit_field.gd`、`repo/tests/runner/test_w8_charge.gd`（新）、`repo/tests/runner/w8_charge_cases.gd`（新）
**tasks**：§2.5 全部；拆附着三件套；蓄能状态机+脉冲+三道闸；形态卡改义（MEC_ORBIT_SWORD/AXE/BOLT 的 .tres 改动若归 traits 目录则由共享组执行，改义参数由本组提供）；击退塑场重构。

**落地顺序建议**：共享组（validator/词条/标记通道）→ 激光组（灼焦单池是 W5 依赖）→ W8 组 → 双火箭组 → 手枪组 → 棱镜组（依赖面最广）→ 共享组收尾（测试翻转+压测）。

---

## 五、新词条 / 新数据键统一命名表（全局唯一，已对照 resources/traits/ 现有 28 个 id 去重）

### 新词条（22 个）
| id | 中文 | 方向 | 关键 params |
|---|---|---|---|
| MEC_SPLIT_PRISM | 裂片棱镜 | 激光 | required_forms=[1], stack_max=3, 入 COUNT_TRAIT_IDS |
| MEC_BEAM_TRACK / MEC_BEAM_FAN / MEC_BEAM_COFOCUS | 追踪棱/扇形棱/共焦棱 | 激光 | exclusive_group="laser_topology", stack_max=1 |
| MEC_PHASE_SYNC | 相位同步 | 激光 | required_forms=[1], stack_max=1 |
| MEC_BEAM_LAG | 分光延迟 | 激光 | required_forms=[1], stack_max=2 |
| MEC_BEAM_SPECTRA | 分光棱镜 | 激光 | required_forms=[1], stack_max=1 |
| TH_PRISM_CHOIR | 棱镜合唱（阈值） | 激光 | metric=sub_beam_count, threshold=3, effect=EF_CHOIR |
| MEC_MIRROR_SPLIT | 分光镜 | 棱镜 | required_weapon=[W5_prism], stack_max=2, 入 COUNT_TRAIT_IDS |
| MEC_MIRROR_LOCK / MEC_MIRROR_WEIGHT | 镜面锁定/最肥镜像 | 棱镜 | exclusive_group="prism_pointer", stack_max=1 |
| MEC_MIRROR_TEMPO | 镜面奏鸣 | 棱镜 | required_weapon=[W5_prism], stack_max=2 |
| TH_MIRROR_CHOIR | 万镜同调（阈值） | 棱镜 | metric=mirror_count, threshold=3 |
| MEC_HIVE_RACK | 蜂巢挂架 | 火箭 | required_weapon=[W6_micro_missile], stack_max=2 |
| MEC_FUSE_COAT | 引信涂层 | 火箭 | required_weapon=[W6_micro_missile], stack_max=2 |
| MEC_FUSE_DETONATE | 定向爆破 | 火箭 | required_weapon=[W7_cluster_rocket], stack_max=2 |
| TH_SWARM_NOVA | 蜂群新星（阈值） | 火箭 | metric=volley_count, threshold=5, effect=EF_SWARM_NOVA |
| MEC_PARALLEL_CAL | 平行校准 | 手枪 | required_forms=[0], stack_max=3 |
| MEC_RICOCHET_HALL | 回廊弹幕 | 手枪 | requires_trait=MEC_BOUNCE, required_forms=[0], stack_max=1 |
| TH_VOLLEY_STATE | 弹幕态（阈值） | 手枪 | metric=pellets, threshold=6, effect=EF_VOLLEY |
| TH_BANK_SHOT | 黄金弹（阈值） | 手枪 | metric=bounce_count, threshold=12, effect=EF_BANK |
| MEC_CRITICAL_MASS | 临界质量 | W8 | required_weapon=[W8_orbit_field], stack_max=2 |
| MEC_CHAIN_DETONATE | 链式引爆 | W8 | required_weapon=[W8_orbit_field], stack_max=1 |
| TH_DETONATION_ECHO / TH_RING_PRESSURE | 引爆回响/环压（阈值） | W8 | metric=detonation_count≥8 / charged_hits≥60 |

### 新数据键（全部过 DataValidator 必填/范围校验，见 §三.3）
- **laser 段**：`sub_ratio_levels=[0.6,0.6,0.6,0.6,0.75]`、`mirrors_count_levels=[1,1,2,2,3]`、`mirror_ratio_levels=[0.40,0.45,0.50,0.55,0.60]`、`mirror_budget_per_s=600.0`、`mirror_laser_cap=2`；删除：W4 `pulse_duration`/`tick_rate`（死键）、W5 `refract_beams/refract_ratio/refract_depth/refract_beams_levels/refract_ratio_levels`。
- **ballistic 段**：`lateral_gap_levels`、`converge_pct_levels`、`bounce_levels=[0,0,1,1,2]`、`bounce_amp=0.12`、`bounce_amp_cap=1.0`。
- **homing 段**：`volley_count_levels=[1,1,2,2,3]`、`blast_atk_ratio`（W6=0.6 / W7=1.0）、`blast_r_levels` 改值 [30,32,34,36,38]；`proj_speed_init` 240→420。
- **melee 段**：`charge_max=5`、`charge_gain_cd_levels=[0.5,0.45,0.4,0.35,0.3]`、`detonate_mult=5.0`、`detonate_radius=90.0`、`detonate_global_icd=0.5`、`pulse_cd=3.0`、`effective_blade_cap=8`；`cd` 改义 pulse（占位注释退役）。

### 新 EventBus / DebugStats
信号：`laser_subbeam_spawned(owner_kind)`、`mirror_formed(text)`、`w8_detonated`；计数：`w8_detonations`、`laser_subbeam_rejected`、`mirror_rejected`、`homing_volley_dropped`、`volley_state_active`。

---

## 六、工程纪律（全程有效）

1. 沿用 repo 现有代码风格与 §九纪律；新数据键/新词条过 DataValidator 必填与范围校验（§三.3 全量规则表）。
2. 新词条 id 全局唯一（§五命名表已对照现有 28 个 traits 去重）。
3. **禁止改存档层**：`scripts/meta/`（RunSave/MetaManager）与 user:// 口径冻结——W5 镜面会话态+确定性重推导是本整案对三份棱镜提案的强制修正。
4. 既有断言不许放宽或删除——只允许按新契约**翻转**（翻转清单见 §三.11）；R183 段（verify_feedback_cases.gd:2094-2182）原样保留作为读感分界的回归锁。
5. 类型化赋值注意时序（先判有效再赋值，如 `_main_beam`/镜面/蓄能键的 is_instance_valid 守卫）。
6. 表现与功能同版本交付（W4 束色徽标/W5 镜染/W8 蓄能读数/W6 爆炸分档/W1 黄金弹染——均为验收项非打磨项，R186「重构了啥」的直接教训）。
7. 回归门禁：交付时全量套件电池（tests/runner/ 下 25 个 test_*.gd）退出码全 0；基线 pkg3 127/0、weapon_orbit 42/0、p1_polish 17/0 已由本会话实跑锁定。
