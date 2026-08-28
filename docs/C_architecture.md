# Infinite Fission · C 架构设计书（Architecture Design）v1.0

| 项 | 内容 |
|---|---|
| 文档版本 | v1.0（2026-08-28） |
| 产出角色 | 阶段 C 首席架构师 |
| 输入依据（按序） | `docs/B_spec.md`（单一事实源，全部裁定已定）；`docs/00_user_requirement.md`（最终依据）；`docs/analysis/A1_requirements.md` §2 模块清单 / §4 边界风险；`docs/analysis/A2_numeric_framework.md` §7 公式到代码映射（全文公式族参照）；`docs/analysis/A3_numbers.md`（数字真源） |
| 下游消费者 | 阶段 D 编码派发（§七）、阶段 E 审查测试 |
| 约束 | Godot 4.3 稳定 API；GDScript 静态类型标注全覆盖；`class_name` 与文件名/目录对应；不引入任何外部插件依赖；本文不产出任何 .gd 实现文件，仅为骨架级契约 |
| 冲突裁决规则 | 本文与 B_spec 冲突时以 B_spec 为准；B_spec 内部 §2.3（九步）与 §2.2（字段简表）存在粒度差时，以 §2.3 的职责要求为准对 §2.2 做结构性细化（见 §4.1 说明，语义不变） |

---

## 0. 设计总则与全局约定

### 0.1 语言与工程约定（Godot 4.3 落地口径）

1. **静态类型全覆盖**：所有函数声明带返回类型（`-> void` / `-> float` / `-> DamageResult` 等）；所有成员变量带类型标注；容器用类型化数组 `Array[Enemy]`。**Godot 4.3 不支持类型化 Dictionary**（4.4 特性），所有 `Dictionary` 为非类型化，键/值契约在本文档中以注释表格约定。
2. **class_name 与文件名对应**：`class_name FooBar` ⇔ 文件 `foo_bar.gd`（snake_case）。目录与分层对应见 §1.4。
3. **autoload 例外**：Godot 4 中 autoload 注册名若与脚本 `class_name` 同名会产生冲突。因此 `event_bus.gd` / `game_config.gd` / `debug_stats.gd` 三个 autoload 脚本**不声明 class_name**，以注册单例名（`EventBus` / `GameConfig` / `DebugStats`）全局访问。这是唯一不满足"class_name 与文件名对应"的例外集合，已在文件映射表中标注。
4. **GDScript 无 abstract 关键字**：基类虚方法默认实现为 `push_error("<抽象方法未实现>") + 返回默认值`，子类必须覆写；文档中标注「抽象」的方法即此契约。
5. **RNG 可注入**：所有影响结算确定性的掷骰（暴击、掉落、波次 jitter）走 `RandomNumberGenerator` 实例流，种子可注入（AC-12.5、模式 A/B/C 回归前提）。
6. **不引入外部插件**：对象池/网格/事件总线/测试框架全部自研（测试用 `godot --headless -s` 脚本入口，不用 GUT）。
7. **节点树纪律**：跨模块运行时通信只走两条路——**EventBus**（松耦合广播）或**显式构造注入**（构造/`setup()` 传入引用）。禁止 `get_node("../..")` 式向上爬树取依赖。
8. **数值单向流动**（A2 §1.9 守门）：结算管线内数值只能沿「加算池 → 面板段 → 乘区段 → Local 段 → 暴击 → 抗性」单向流动，禁止反向引用。

### 0.2 帧驱动模型（全局时间语义，M-01 契约）

- **唯一权威帧**：`GameLoop._physics_process`（120Hz 物理帧，与渲染帧率解耦）按固定顺序驱动全部子系统 tick；子系统**不自带** `_physics_process` 逻辑（场景树节点顺序不构成执行顺序保证）。`_process` 仅用于纯表现（UI 动画、DebugStats 采样）。
- **双时间通道**：
  - `game_delta = raw_delta * time_scale`：一切游戏逻辑（运动/冷却/DOT/寿命/波次）的唯一时间源。顿帧时 `time_scale=0.05`，`game_delta≈0`，所有计时自然冻结，**无"时间债"跳变**（E-11）。
  - `raw_delta`：UI 动画、GameFeel 衰减（trauma/色差）、顿帧自身计时使用，不受缩放（Q-14）。
- **time_scale 唯一持有者**：`GameLoop.time_scale`。任何子系统（含 GameFeelDirector）**只能申请**（`request_hit_stop`），不能写 `Engine.time_scale` 或 GameLoop 内部状态。LevelUp/Paused 冻结用 `get_tree().paused = true`（UI 层 `process_mode = PROCESS_MODE_ALWAYS`），与顿帧通道正交。
- **帧号**：`GameConfig.frame_stamp`（每物理帧 +1），作为幂等键、审计与确定性日志的公共帧标识。

### 0.3 数据加载与运行时纪律

- **启动期一次性加载**：全部 .tres/.cfg 在 Boot 状态加载并校验；**运行期零 .tres 加载**（E-08）。DataRegistry 是运行期唯一数据入口。
- **降级不崩溃**：单条数据非法 → 剔除该条 + 错误清单；致命配置（池容量 0 等）→ 拒绝启动并展示清单（§六）。
- **池化纪律**：战斗实体（投射物/敌人/跳字/粒子发射器/光束/经验碎片）运行期 `instantiate()` / `queue_free()` 计数必须为 0（AC-14.1，DebugStats 断言）。

---

## 一、模块依赖关系图与目录布局

### 1.1 分层依赖图（M-01~M-19，L0~L5）

依赖方向严格自底向上（箭头 = "依赖"）。**禁止反向依赖**：L(n) 不得 import / 类型引用 / get_node 访问 L(n+1) 及以上任何模块。

```
                    ┌────────────────────────── L5 表现与编排 ──────────────────────────┐
                    │  M-01 GameLoop   M-15 GameFeel   M-16 UI(HUD/跳字)  M-17 卡牌流    │
                    └────────────────────────────────┬─────────────────────────────────┘
                                                   │（宿主/驱动/注入）
                    ┌───────────────────────────── L4 实体编排 ───────────────────────────┐
                    │  M-02 Player                          M-04 WaveDirector(+Spawner) │
                    └────────────────────────────────┬─────────────────────────────────┘
                                                   │
      ┌──────────────────────────── L3 玩法实体 ─────────────────────────────┐
      │  M-05 WeaponBase+Ballistic   M-06 Laser   M-07 Homing   M-08 Melee   │
      │  M-03 Enemy                                                            │
      └──────────────────────────────┬────────────────────────────────────────┘
                                   │
        ┌──────────────────── L2 运行时系统 ────────────────────┐
        │  M-09 ProjectileBase    M-10 Trait/TraitStack    M-11 Elemental │
        └─────────────────────────┬─────────────────────────────┘
                                  │
      ┌─────────────────── L1 结算与资源 ───────────────────┐
      │  M-12 DamagePipeline   M-13 ObjectPool   M-14 Resource 层 │
      └──────────────────────────┬─────────────────────────┘
                                 │
      ┌──────────────── L0 基础设施（零依赖，最先启动）─────────────┐
      │  M-18 EventBus（autoload）      M-19 GameConfig（autoload）  │
      └────────────────────────────────────────────────────────────┘
```

### 1.2 模块依赖矩阵（逐模块：依赖 / 被依赖 / 通信通道）

| 模块 | 层 | 依赖（下层） | 被依赖（上层） | 对上通信通道 |
|---|---|---|---|---|
| M-18 EventBus | L0 | 无 | 几乎全部 | 自身即通道 |
| M-19 GameConfig | L0 | 无（加载 .tres/.cfg） | M-01/03/04/13/14/15/17 | 自身即通道（注入 BalanceTables） |
| M-12 DamagePipeline | L1 | M-18（广播）、M-19（护栏常数） | M-06~M-11 | `damage_resolved` / `damage_alarm` 事件 |
| M-13 ObjectPool | L1 | M-19（容量） | M-03/06/09/15/16/17 | `pool_exhausted` 事件 |
| M-14 Resource 层 | L1 | M-19（加载器） | M-03/05~08/10/11/15/17 | 注入 `DataRegistry` 引用 |
| M-09 Projectile | L2 | M-13（实例）、M-12（结算）、M-10（事件订阅者注入）、M-03（命中目标，白名单§1.3-3） | M-05/M-07 | 局部六事件派发（不走总线）+ 结算结果 |
| M-10 Trait 引擎 | L2 | M-09（事件契约）、M-12（乘区注入）、M-13（分裂实例）、M-11（附着接口）、M-14 | M-05~M-08、M-17 | `chain_fused` 事件（熔断遥测） |
| M-11 Elemental | L2 | M-12（DOT/反应独立结算）、M-18、M-03（状态宿主注入） | M-10、M-15 | `reaction_triggered` 事件 |
| M-03 Enemy | L3 | M-14、M-13、M-18、M-11 | M-04/09/12/16 | `enemy_killed` / `boss_spawned` 事件 |
| M-05~M-08 武器 | L3 | M-09（生成请求）、M-10、M-14、M-12、M-13；M-07 另索敌 M-03、全体持 M-02 宿主引用（白名单§1.3-3） | M-02 | 局部信号 + 结算事件 |
| M-02 Player | L4 | M-05~M-08、M-18 | M-04/17/16 | `player_hit` / `player_died` / `level_up` / `xp_gained` |
| M-04 WaveDirector | L4 | M-03、M-19、M-18、M-13 | M-01、M-16 | `wave_started` / `wave_cleared` / `boss_spawned` |
| M-01 GameLoop | L5 | M-18/M-19（Boot）、注入全部 | 宿主 | `state_changed` 事件（状态机仲裁） |
| M-15 GameFeel | L5 | M-13、M-18、M-01（time_scale 申请）、M-14 | M-01（帧序特效阶段） | 订阅 `damage_resolved`/`enemy_killed`/`reaction_triggered` |
| M-16 UI | L5 | M-18、M-13（跳字池）、M-12（数值源） | M-01、M-17 | 纯订阅者 |
| M-17 卡牌流 | L5 | M-14、M-10、M-02、M-18、M-16、M-01（暂停申请） | 无下游（终端） | `card_chosen` 事件 |

### 1.3 依赖规则（硬约束，阶段 E 审查项）

> 依据 B_spec §3 原文："分层依赖（自底向上，**禁止反向依赖**，跨层通信走 **EventBus 或显式注入**）"。据此把"反向依赖"精确定义为**控制流反向**，并把合法的跨层数据访问收敛为一张封闭白名单——规则可审查、可执行。

1. **禁止反向依赖（控制流）**：下层模块不得——① 调用上层模块的编排/生命周期方法（tick/setup 之外的驱动）；② 实例化（`instantiate`/`preload` 上层场景）；③ 向上 `get_node` 爬树；④ 订阅/持有上层服务再回调其方法。违规 = 审查阻塞项。
2. **跨层数据访问仅两条合法通道**（B_spec §3 原文授权）：
   - **EventBus 广播**（松耦合、一对多）；
   - **显式注入**（构造/`setup()` 注入的宿主引用或服务引用——被注入方持有引用读取数据，不反向驱动）。
   除此之外的任何"下层持上层引用"必须先进白名单（架构评审），否则审查阻塞。
3. **跨层引用白名单**（封闭集合；与 A1 §2 的"被依赖"列逐条对应，新增需架构评审）：

   | 引用方（下层） | 被引类型（上层） | 性质 | 授权来源 |
   |---|---|---|---|
   | EventBus / DebugStats（L0） | 信号/埋点载荷类型（`DamageResult`、`Enemy` 等） | **仅搬运/测量，不调用其方法**（总线是跨层数据的上行通道） | B_spec §3"跨层通信走 EventBus"的必然推论 |
   | DamageContext（M-12） | `target: Enemy` | 结算目标数据载荷 + **窄接口调用**（`take_result / apply_damage / get_resist / dead` 四个方法） | B_spec §2.2 原文契约；A1 M-03 被依赖"M-09/M-12（命中目标）" |
   | ProjectileBase（M-09） | `_submit_hit/_on_settled(target: Enemy)` | 命中目标实体（同上窄接口） | A1 M-03 被依赖（同上） |
   | TraitContext（M-10） | `target: Enemy`、`weapon: WeaponBase` | 词条条件自评载荷 | A1 M-10 被 M-05~M-08 依赖的双向数据面 |
   | ElementalSystem（M-11） | `register_host/tick(host: Enemy)` | 状态容器宿主 | A1 M-11 依赖"M-03（状态容器宿主）" |
   | WeaponBase（M-05~08） | `player: Player`（setup 注入） | 开火原点/HP 条件宿主 | B_spec"显式注入"；A1 M-05 被依赖 M-02（双向持有） |
   | WeaponBase（M-07） | 索敌返回 `Enemy` | 同层引用（M-07→M-03） | A1 M-07 依赖"M-03（索敌查询）" |

4. **同层解耦**：未列入上述白名单的同层模块之间不直接引用（如 M-02 不引用 M-04、M-16 不引用 M-17），一律经 EventBus 或经共同宿主（M-01）注入。
5. **EventBus 订阅白名单**：仅 **Node 派生类**可订阅 EventBus（RefCounted 订阅会造成连接持强引用 → 泄漏，E-12）。投射物词条（TraitStack，RefCounted）**不挂总线**，只挂 ProjectileBase 的局部事件派发（见 §2.7.1）。场景重开时执行 `EventBus.assert_subscription_baseline()` 断言订阅数回落（泄漏回归测试）。
6. **SpaceGrid 归属**：空间网格是 L1 级碰撞基础设施（M-13 协作件），由 GameLoop 持有两份实例（敌人格 / 敌弹格），供 M-09/M-07/M-08/M-04 查询——它不属于任何 L2+ 模块所有。
7. **time_scale 单一写者**：仅 `GameLoop.set_time_scale()` 可写；DebugStats 在 release 构建剥离（`OS.has_feature("release")` 守卫）。

### 1.4 目录布局设计（精确到子目录与文件名）

```
res://
├── project.godot                    # autoload 注册：EventBus / GameConfig / DebugStats
├── icon.svg
│
├── autoload/                        # ═══ 全局单例（不声明 class_name，§0.1-3）═══
│   ├── event_bus.gd                 # M-18 事件总线（注册名 EventBus）
│   ├── game_config.gd               # M-19 配置/数值表加载（注册名 GameConfig）
│   └── debug_stats.gd               # 验收测量面板（注册名 DebugStats，release 剥离）
│
├── scripts/
│   ├── core/                        # ═══ L0/L1 基础设施 ═══
│   │   ├── game_const.gd            # GameConst：全局枚举/位标志/共享常量（无状态）
│   │   ├── object_pool.gd           # M-13 ObjectPool 通用池基类
│   │   ├── pools/                   # M-13 特化池
│   │   │   ├── projectile_pool.gd   #   ProjectilePool（玩家弹+敌弹共用，team 区分）
│   │   │   ├── enemy_pool.gd        #   EnemyPool
│   │   │   ├── popup_pool.gd        #   PopupPool（跳字）
│   │   │   ├── particle_pool.gd     #   ParticlePool（GPUParticles2D 发射器）
│   │   │   ├── laser_pool.gd        #   LaserBeamPool（光束段实例）
│   │   │   └── xp_pool.gd           #   XPPool（经验碎片）
│   │   ├── space_grid.gd            # SpaceGrid：128px 哈希空间网格（可实例化×2）
│   │   ├── damage/                  # M-12 伤害结算
│   │   │   ├── damage_context.gd    #   DamageContext（结算请求输入）
│   │   │   ├── damage_result.gd     #   DamageResult（结算输出，跳字/遥测数据源）
│   │   │   ├── damage_audit.gd      #   DamageAudit（钳制/去重审计，§2.5 遥测源）
│   │   │   ├── modifier_stack.gd    #   ModifierStack（池聚合中间结构，A2 §7.2）
│   │   │   └── damage_pipeline.gd   #   DamagePipeline（九步结算，§四）
│   │   └── data/                    # M-14 Data-driven 层
│   │       ├── data_registry.gd     #   DataRegistry：目录扫描/按 ID 索引/注入
│   │       ├── data_validator.gd    #   DataValidator：启动校验 + 降级 + 错误清单
│   │       └── resources/           #   Resource 类定义（.gd 脚本，被 .tres 引用）
│   │           ├── weapon_data.gd           # WeaponData
│   │           ├── weapon_level_stats.gd    # WeaponLevelStats（升级表嵌套项）
│   │           ├── enemy_data.gd            # EnemyData
│   │           ├── trait_data.gd            # TraitData
│   │           ├── relic_data.gd            # RelicData
│   │           ├── synergy_rule_data.gd     # SynergyRuleData
│   │           ├── wave_table_data.gd       # WaveTableData
│   │           ├── wave_entry_data.gd       # WaveEntryData（波次嵌套项）
│   │           ├── game_feel_config.gd      # GameFeelConfig
│   │           └── balance_tables.gd        # BalanceTables（全局常数）
│   │
│   ├── combat/                      # ═══ L2/L3 战斗系统 ═══
│   │   ├── projectile/              # M-09
│   │   │   ├── projectile_base.gd   #   ProjectileBase（六事件派发/五路径回收）
│   │   │   ├── ballistic_projectile.gd #   BallisticProjectile（直线/穿透/反弹）
│   │   │   └── homing_projectile.gd #   HomingProjectile（转向/加速/爆炸）
│   │   ├── weapon/                  # M-05~M-08
│   │   │   ├── weapon_base.gd       #   M-05 WeaponBase（抽象）
│   │   │   ├── ballistic_weapon.gd  #   M-05 BallisticWeapon（手枪/加特林/霰弹）
│   │   │   ├── laser_weapon.gd      #   M-06 LaserWeapon（光束调度）
│   │   │   ├── laser_beam.gd        #   M-06 LaserBeam（射线实体，池化）
│   │   │   ├── homing_weapon.gd     #   M-07 HomingWeapon（导弹/火箭）
│   │   │   └── melee/               #   M-08
│   │   │       ├── orbit_weapon.gd  #     OrbitWeapon（近战形态调度）
│   │   │       ├── orbit_field.gd   #     OrbitField（环绕力场）
│   │   │       └── arc_slash.gd     #     ArcSlash（周期挥斩/消弹）
│   │   ├── trait/                   # M-10
│   │   │   ├── trait_base.gd        #   TraitBase（运行时词条实例）
│   │   │   ├── trait_stack.gd       #   TraitStack（词条引擎：挂载/继承/熔断）
│   │   │   ├── trait_context.gd     #   TraitContext（事件载荷）
│   │   │   └── builtin/             #   内置效果处理器（effect_id → 处理器）
│   │   │       ├── trait_effect.gd          # TraitEffect 处理器基类（抽象分发契约）
│   │   │       ├── trait_effect_size.gd      # 体积极限家族
│   │   │       ├── trait_effect_fractal.gd   # 几何分裂家族
│   │   │       ├── trait_effect_bounce.gd    # 反弹/折射家族
│   │   │       ├── trait_effect_elemental.gd # 元素附着家族
│   │   │       ├── trait_effect_stat.gd      # 加算属性家族
│   │   │       └── trait_effect_mech.gd      # 通用机制家族（死亡新星/格挡等）
│   │   └── elemental/               # M-11
│   │       ├── elemental_system.gd  #   ElementalSystem（全局服务）
│   │       └── elemental_state.gd   #   ElementalState（单敌三槽状态容器）
│   │
│   ├── entities/                    # ═══ L3/L4 实体 ═══
│   │   ├── enemy/
│   │   │   └── enemy.gd             # M-03 Enemy（状态容器宿主/行为机/死亡广播）
│   │   ├── player/
│   │   │   ├── player.gd            # M-02 Player
│   │   │   └── pickup.gd            # M-02 XpShard（经验碎片，Area2D）
│   │   └── wave/
│   │       ├── wave_director.gd     # M-04 WaveDirector
│   │       └── enemy_spawner.gd     # M-04 EnemySpawner（生成节流+池预热协作）
│   │
│   ├── loop/                        # ═══ L5 主循环 ═══
│   │   └── game_loop.gd             # M-01 GameLoop（状态机/帧序/time_scale）
│   │
│   ├── gamefeel/                    # ═══ M-15 GameFeel ═══
│   │   ├── game_feel_director.gd    # 顿帧/震屏/色差总调度
│   │   ├── camera_shake.gd          # trauma 模型震屏
│   │   └── particle_director.gd     # GPUParticles2D 统一池化管理
│   │
│   ├── ui/                          # ═══ M-16 UI ═══
│   │   ├── hud.gd                   # HP/经验/波次 HUD
│   │   ├── popup_manager.gd         # 跳字管理（合并/上限/分级）
│   │   ├── damage_popup.gd          # 跳字实体（池化）
│   │   ├── boss_bar.gd              # Boss 血条
│   │   └── game_over_screen.gd      # 结算界面（本局统计）
│   │
│   └── cards/                       # ═══ M-17 Roguelike 卡牌流 ═══
│       ├── card_generator.gd        # 三选一候选生成/过滤/fallback/应用
│       └── card_select_ui.gd        # 选卡界面
│
├── scenes/
│   ├── main.tscn                    # M-01 宿主：GameLoop + CanvasLayer 组织
│   ├── combat/
│   │   ├── battle_stage.tscn        # 战斗舞台（玩家/网格/池/导演节点挂载点）
│   │   ├── player/player.tscn
│   │   ├── enemies/                 # e1_grunt.tscn … e6_boss3.tscn（共用 enemy.gd）
│   │   ├── projectiles/             # ballistic_projectile.tscn / homing_projectile.tscn / enemy_bullet.tscn
│   │   ├── lasers/laser_beam.tscn
│   │   ├── melee/orbit_field.tscn / arc_slash.tscn
│   │   └── pickups/xp_shard.tscn
│   └── ui/
│       ├── hud.tscn / boss_bar.tscn / damage_popup.tscn
│       ├── card_select.tscn / game_over.tscn
│       └── boot_error.tscn          # 致命配置错误清单屏（§六）
│
├── resources/                       # ═══ 内容数据 .tres 实例（运行期只读）═══
│   ├── weapons/                     # w1_pistol.tres … w9_arc_slash.tres（9 把）
│   ├── enemies/                     # e1_grunt.tres … e6_boss3.tres + elite_template.tres
│   ├── traits/                      # aff_*.tres / syn_*.tres / mec_*.tres / ele_*.tres（28+条）
│   ├── relics/                      # rel_*.tres（11 件）
│   ├── synergies/                   # syn_rule_*.tres（乘区条件规则）
│   ├── waves/                       # wave_table_main.tres（30 波 + 无尽参数）
│   └── gamefeel/                    # game_feel_default.tres
│
├── data/                            # ═══ 全局配置（M-19 加载；唯一/致命级）═══
│   ├── balance/
│   │   ├── global_constants.cfg     # ConfigFile 键值对（分辨率/基础常量）
│   │   └── balance_tables.tres      # BalanceTables 实例（§三.8）
│   ├── manifest.cfg                 # 数据目录清单与加载顺序
│   └── version.cfg                  # 数据版本字段（AC-13.5，不匹配仅告警）
│
├── shaders/
│   ├── post/chromatic_aberration.gdshader   # 全屏色差后处理（hint_screen_texture）
│   ├── fx/hit_flash.gdshader                # 敌人受击闪白（共享材质，非逐实例）
│   └── beam/laser_beam.gdshader             # 光束流动纹理（占位）
│
└── tests/                           # ═══ 自动化回归（§五.5 / A2 §6.2 三模式）═══
    ├── runner/run_all.gd            # headless 总入口（非零退出码 = 失败）
    ├── formula/test_formula_pipeline.gd     # 模式 A：公式真源（秒级，每次提交）
    ├── sim/test_sim_battle.gd               # 模式 B：模拟战斗（数值表变更时）
    ├── sim/auto_battle_driver.gd            # 脚本化自动战斗（固定种子）
    ├── mc/test_monte_carlo.gd               # 模式 C：蒙特卡洛构筑模拟
    ├── unit/
    │   ├── test_object_pool.gd  test_space_grid.gd  test_event_bus.gd
    │   ├── test_data_validator.gd  test_trait_stack.gd  test_elemental.gd
    │   └── test_wave_director.gd
    └── stress/
        ├── test_perf_500p100e.gd            # AC-01.2 压力场景
        └── test_soak_10min.gd               # AC-12.6 / AC-14.1 soak
```

### 1.5 文件 ↔ 模块映射表

| 文件 | class / 单例名 | 模块 | 层 |
|---|---|---|---|
| `autoload/event_bus.gd` | EventBus（autoload，无 class_name） | M-18 | L0 |
| `autoload/game_config.gd` | GameConfig（autoload，无 class_name） | M-19 | L0 |
| `autoload/debug_stats.gd` | DebugStats（autoload，无 class_name） | 验收工具 | L0 |
| `scripts/core/game_const.gd` | GameConst | M-19 附庸 | L0 |
| `scripts/core/object_pool.gd` | ObjectPool | M-13 | L1 |
| `scripts/core/pools/projectile_pool.gd` | ProjectilePool | M-13 | L1 |
| `scripts/core/pools/enemy_pool.gd` | EnemyPool | M-13 | L1 |
| `scripts/core/pools/popup_pool.gd` | PopupPool | M-13 | L1 |
| `scripts/core/pools/particle_pool.gd` | ParticlePool | M-13 | L1 |
| `scripts/core/pools/laser_pool.gd` | LaserBeamPool | M-13 | L1 |
| `scripts/core/pools/xp_pool.gd` | XPPool | M-13 | L1 |
| `scripts/core/space_grid.gd` | SpaceGrid | M-13 协作件 | L1 |
| `scripts/core/damage/damage_context.gd` | DamageContext | M-12 | L1 |
| `scripts/core/damage/damage_result.gd` | DamageResult | M-12 | L1 |
| `scripts/core/damage/damage_audit.gd` | DamageAudit | M-12 | L1 |
| `scripts/core/damage/modifier_stack.gd` | ModifierStack | M-12 | L1 |
| `scripts/core/damage/damage_pipeline.gd` | DamagePipeline | M-12 | L1 |
| `scripts/core/data/data_registry.gd` | DataRegistry | M-14 | L1 |
| `scripts/core/data/data_validator.gd` | DataValidator | M-14 | L1 |
| `scripts/core/data/resources/*.gd`（10 个） | WeaponData 等 | M-14 | L1 |
| `scripts/combat/projectile/projectile_base.gd` | ProjectileBase | M-09 | L2 |
| `scripts/combat/projectile/ballistic_projectile.gd` | BallisticProjectile | M-09 | L2 |
| `scripts/combat/projectile/homing_projectile.gd` | HomingProjectile | M-09 | L2 |
| `scripts/combat/trait/trait_base.gd` | TraitBase | M-10 | L2 |
| `scripts/combat/trait/trait_stack.gd` | TraitStack | M-10 | L2 |
| `scripts/combat/trait/trait_context.gd` | TraitContext | M-10 | L2 |
| `scripts/combat/trait/builtin/*.gd`（7 个，含基类） | TraitEffect / TraitEffectSize 等 | M-10 | L2 |
| `scripts/combat/elemental/elemental_system.gd` | ElementalSystem | M-11 | L2 |
| `scripts/combat/elemental/elemental_state.gd` | ElementalState | M-11 | L2 |
| `scripts/combat/weapon/weapon_base.gd` | WeaponBase | M-05 | L3 |
| `scripts/combat/weapon/ballistic_weapon.gd` | BallisticWeapon | M-05 | L3 |
| `scripts/combat/weapon/laser_weapon.gd` | LaserWeapon | M-06 | L3 |
| `scripts/combat/weapon/laser_beam.gd` | LaserBeam | M-06 | L3 |
| `scripts/combat/weapon/homing_weapon.gd` | HomingWeapon | M-07 | L3 |
| `scripts/combat/weapon/melee/orbit_weapon.gd` | OrbitWeapon | M-08 | L3 |
| `scripts/combat/weapon/melee/orbit_field.gd` | OrbitField | M-08 | L3 |
| `scripts/combat/weapon/melee/arc_slash.gd` | ArcSlash | M-08 | L3 |
| `scripts/entities/enemy/enemy.gd` | Enemy | M-03 | L3 |
| `scripts/entities/player/player.gd` | Player | M-02 | L4 |
| `scripts/entities/player/pickup.gd` | XpShard | M-02 | L4 |
| `scripts/entities/wave/wave_director.gd` | WaveDirector | M-04 | L4 |
| `scripts/entities/wave/enemy_spawner.gd` | EnemySpawner | M-04 | L4 |
| `scripts/loop/game_loop.gd` | GameLoop | M-01 | L5 |
| `scripts/gamefeel/game_feel_director.gd` | GameFeelDirector | M-15 | L5 |
| `scripts/gamefeel/camera_shake.gd` | CameraShake | M-15 | L5 |
| `scripts/gamefeel/particle_director.gd` | ParticleDirector | M-15 | L5 |
| `scripts/ui/hud.gd` | HUD | M-16 | L5 |
| `scripts/ui/popup_manager.gd` | PopupManager | M-16 | L5 |
| `scripts/ui/damage_popup.gd` | DamagePopup | M-16 | L5 |
| `scripts/ui/boss_bar.gd` | BossBar | M-16 | L5 |
| `scripts/ui/game_over_screen.gd` | GameOverScreen | M-16 | L5 |
| `scripts/cards/card_generator.gd` | CardGenerator | M-17 | L5 |
| `scripts/cards/card_select_ui.gd` | CardSelectUI | M-17 | L5 |

---

## 二、核心类定义（GDScript 骨架级）

> 约定：以下骨架仅含 `class_name` / `extends` / 导出与关键属性签名 / 公开方法签名 / 信号声明；方法体以一行注释说明职责，**不含实现**。所有枚举集中在 `GameConst`。

### 2.0 全局枚举与位标志（GameConst）

```gdscript
# scripts/core/game_const.gd
# M-19 附庸：全局枚举/位标志/共享常量。纯静态容器，禁止持有运行时状态。
class_name GameConst
extends RefCounted

enum Element { KIN, FIR, ICE, LTG }                       # 伤害/附着元素
enum PoolClass { ADD, MULT, LOCAL, MECH, ELEM }           # 词条池归类（B_spec §2.5）
enum TraitEvent { ON_SPAWN, ON_TICK, ON_HIT, ON_PIERCE, ON_BOUNCE, ON_EXPIRE }  # 六大生命周期
enum WeaponForm { BALLISTIC, LASER, HOMING, MELEE }       # 武器四形态
enum EnemyBehavior { CHASE, RANGED, DASHER, ORBIT, SENTRY }  # M1 只实现 CHASE/RANGED
enum GameStatus { BOOT, MENU, PLAYING, PAUSED, LEVEL_UP, GAME_OVER }
enum RecycleReason { EXPIRED, PIERCE_DEPLETED, BOUNCE_DEPLETED, NULLIFIED, FORCED }  # 回收五路径
enum PopupStyle { NORMAL, CRIT, REACTION, DOT, HEAL, XP }
enum FeelLevel { HIT, CRIT, CATALYST, BOSS_DEATH }        # GameFeel 分级（Q-12）
enum ReactionType { RXN_FIR_ICE, RXN_FIR_LTG, RXN_ICE_LTG }  # 碎裂/过载/超导（中性 ID）
enum TargetStrategy { NEAREST, FOREMOST, LOWEST_HP, LOCKED }  # 武器目标策略
enum ConditionId {                                        # 乘区条件封闭枚举（§三.5）
    TARGET_FROZEN, TARGET_BURNING, TARGET_SHOCKED, AFTER_BOUNCE,
    PIERCE_INDEX_GE, PLAYER_HP_BELOW, WAVE_FIRST_HIT, TARGET_TAG_IN,
    NONE,
}

# DamageContext.hit_flags 位标志
const HIT_IS_BOUNCE := 1            # 本次命中发生在反弹之后
const HIT_AFTER_PIERCE := 2         # 穿透序数 ≥2 的命中
const HIT_IS_SPLIT_CHILD := 4       # 分裂子代
const HIT_IS_REACTION := 8          # 元素反应独立结算（不掷暴击）
const HIT_IS_DOT := 16              # DOT 跳伤（不掷暴击）
const HIT_IS_AOE_SECONDARY := 32    # 爆炸溅射次级目标
const HIT_NO_CRIT := 24             # 掩码：HIT_IS_REACTION | HIT_IS_DOT

# Enemy tags / immune_mask 位标志
const TAG_ELITE := 1
const TAG_BOSS := 2
const IMMUNE_FREEZE := 1            # 定身免疫（Boss 默认置位，F-17）
const IMMUNE_CHILL := 2
const IMMUNE_BURN := 4
const IMMUNE_SHOCK := 8

static func next_uid() -> int:
    # 全局递增实例 UID（投射物/武器/词条实例幂等键组成部分）；线程安全性不需要（单主线程）
    return 0
```

### 2.1 M-18 EventBus（autoload 事件总线）

设计要点：① 原生类型化信号（最快派发路径）；② 每个信号配一个类型化 `emit_*` 包装方法，统一经过 `_track_dispatch`（事件风暴防护 + DebugStats 计数）；③ 仅 Node 可订阅（debug 断言，E-12）；④ 场景重开断言订阅回落基线。

```gdscript
# autoload/event_bus.gd —— 注册名 EventBus（不声明 class_name）
extends Node

signal state_changed(new_state: int)                       # GameStatus
signal config_fatal(errors: Array)                         # 启动致命错误清单（拒绝启动）
signal data_validated(report: Dictionary)                  # 校验报告：{total, rejected, errors[]}
signal damage_resolved(result: DamageResult)               # 每次结算（跳字/GameFeel/遥测共源）
signal damage_alarm(result: DamageResult)                  # ×500 告警线触发（一局一次/构筑）
signal enemy_killed(enemy: Enemy)                          # 死亡广播（含 tags/exp/位置）
signal boss_spawned(enemy: Enemy)                          # Boss 登场（HUD 血条/GameFeel）
signal player_hit(damage: float, source_uid: int)          # 简化路径受击（Q-16）
signal player_died()                                       # 死亡优先级最高（E-16 仲裁输入）
signal level_up(new_level: int)                            # 升级请求（GameLoop 仲裁）
signal xp_gained(amount: float)
signal wave_started(wave: int)
signal wave_cleared(wave: int)
signal slot_unlocked(slot: int)                            # 武器槽解锁（HUD 提示）
signal reaction_triggered(rxn: int, pos: Vector2, target_uid: int)
signal pool_exhausted(pool_id: StringName)                 # 池满降级计数（DebugStats）
signal chain_fused(depth: int, trait_id: StringName)       # 链式/分叉深度熔断遥测
signal card_chosen(card_id: StringName, target_kind: int)  # 选卡应用完成（遗物回响等）

var _dispatch_count: Dictionary = {}        # StringName(事件) -> int(本帧计数)
const STORM_WARN_THRESHOLD := 128           # 同事件同帧派发上限（§六.4）

func emit_damage_resolved(result: DamageResult) -> void:      # _track 后 emit damage_resolved
func emit_enemy_killed(enemy: Enemy) -> void:                 # 死亡唯一广播点
func emit_state_changed(new_state: int) -> void:
func emit_wave_started(wave: int) -> void:
# ……（其余事件同模式：类型化包装 → _track_dispatch → signal.emit）

func _track_dispatch(event: StringName) -> void:              # 帧计数 + 超阈值告警一次
func end_frame() -> void:                                     # GameLoop 帧末调用：清零计数
func get_dispatch_count(event: StringName) -> int:            # DebugStats 查询
func assert_subscription_baseline() -> void:                  # 断言订阅数回落（泄漏回归，E-12）
```

#### EventBus 事件清单表（载荷 / 谁发 / 谁收）

| 事件信号 | 载荷 | 发送者 | 订阅者 |
|---|---|---|---|
| `state_changed` | `(new_status: int)` | GameLoop | HUD、CardSelectUI、GameFeelDirector、DebugStats |
| `config_fatal` | `(errors: Array)` | GameConfig | GameLoop（拒绝启动→boot_error 屏） |
| `data_validated` | `(report: Dictionary)` | DataRegistry | DebugStats、GameLoop |
| `damage_resolved` | `(result: DamageResult)` | DamagePipeline | PopupManager、GameFeelDirector、DebugStats、HUD(总伤统计)、内置遗物效果 |
| `damage_alarm` | `(result: DamageResult)` | DamagePipeline | DebugStats（×500 告警计数） |
| `enemy_killed` | `(enemy: Enemy)` | Enemy | WaveDirector（清屏计数/解锁）、Player（经验掉落驱动）、GameFeelDirector（Boss 死亡分级）、HUD、遗物效果（收割/超频） |
| `boss_spawned` | `(enemy: Enemy)` | WaveDirector | BossBar、GameFeelDirector |
| `player_hit` | `(damage, source_uid)` | Player | HUD、GameFeelDirector（trauma 0.15） |
| `player_died` | `()` | Player | GameLoop（→GAME_OVER，优先级最高） |
| `level_up` | `(new_level: int)` | Player | GameLoop（仲裁→LEVEL_UP）、CardSelectUI |
| `xp_gained` | `(amount)` | Player | HUD（经验条） |
| `wave_started` | `(wave: int)` | WaveDirector | HUD、TraitStack 宿主（WAVE_FIRST_HIT 重置）、遗物（词缀潮汐） |
| `wave_cleared` | `(wave: int)` | WaveDirector | HUD、遗物（黑市排程）、WaveDirector（内部缓冲计时） |
| `slot_unlocked` | `(slot: int)` | Player | HUD |
| `reaction_triggered` | `(rxn, pos, target_uid)` | ElementalSystem | GameFeelDirector（质变级反馈）、PopupManager、DebugStats |
| `pool_exhausted` | `(pool_id)` | 各 ObjectPool | DebugStats |
| `chain_fused` | `(depth, trait_id)` | TraitStack / LaserWeapon | DebugStats（熔断计数） |
| `card_chosen` | `(card_id, target_kind)` | CardGenerator | 遗物效果（回响复制）、HUD（构筑统计） |

> M-15 不设独立 gamefeel 事件：顿帧/震屏/色差分级由 `damage_resolved` / `enemy_killed` / `reaction_triggered` / `player_hit` 四个既有事件派生（B_spec §3.1 M-15 契约），避免事件冗余。

### 2.2 M-19 GameConfig / BalanceTables（autoload 配置加载与降级）

```gdscript
# autoload/game_config.gd —— 注册名 GameConfig（不声明 class_name）
extends Node

const PATH_BALANCE := "res://data/balance/balance_tables.tres"
const PATH_CONSTANTS := "res://data/balance/global_constants.cfg"
const PATH_VERSION := "res://data/version.cfg"

var balance: BalanceTables                    # 校验后的全局常数（§三.8）
var frame_stamp: int = 0                      # 全局帧号（幂等键/审计公共帧标识）
var fatal_errors: Array = []                  # 致命级错误（池容量 0 等）

signal config_ready()

func _ready() -> void:
    # 加载顺序（最优先，其它模块 Boot 前置）：读 version → cfg → .tres → 校验 → 降级/致命 → emit config_ready
func _load_constants() -> void:               # ConfigFile → 内存表（缺失键 → 默认值 + 告警）
func _load_balance() -> void:                 # ResourceLoader.load → DataValidator 校验
func get_constant(key: StringName, default: float) -> float:   # cfg 键值查询（带默认）
func get_pool_capacity(pool_id: StringName) -> int:            # 池容量（致命校验项：≤0 拒绝启动）
func advance_frame() -> void:                 # GameLoop 每物理帧调用：frame_stamp += 1
func is_fatal() -> bool:                      # true → GameLoop 拒绝进入 MENU，展示错误清单
```

`BalanceTables`（Resource 类）schema 见 §三.8；`GameConfig` 本体不持有业务常数，全部委托 `balance` 字段（单一数据源）。

### 2.3 M-13 ObjectPool（通用池 + 四特化）

```gdscript
# scripts/core/object_pool.gd
class_name ObjectPool
extends Node

signal exhausted(pool_id: StringName)         # 转发 EventBus.pool_exhausted

var pool_id: StringName = &""                 # 池标识（遥测键）
var _scene: PackedScene                       # 池化场景模板
var _free_list: Array[Node] = []              # 空闲栈
var _capacity: int = 0                        # 硬容量（= 硬上限）
var _live_count: int = 0                      # 当前在外实例数
var _hits: int = 0                            # 命中（未触发增长）计数
var _misses: int = 0                          # 满池拒绝/丢弃计数

func setup(p_id: StringName, p_scene: PackedScene, p_capacity: int) -> void:  # 绑定模板与容量
func prewarm(count: int) -> void:             # 启动预热：instantiate 到 count 个入 _free_list
func acquire() -> Node:                       # 取出（空返回 null → 调用方丢弃 + 计数，不阻塞不崩溃）
func release(node: Node) -> void:             # 归还：断言清洁 → 压回 _free_list
func stats() -> Dictionary:                   # {hits, misses, live, free, capacity}（DebugStats 源）
func _assert_clean(node: Node) -> void:       # 开发期池污染断言（AC-14.3：取出实例必须"干净"）
```

> 归还契约（E-04/E-05）：**清零责任在实例自身**（`node._reset_state()`），池在 `release` 前调用；清零后任何词条回调被 `_assert_clean` 拦截（push_error）。GDScript 无泛型，类型安全由特化子类收窄（`acquire() -> ProjectileBase`）。

```gdscript
# scripts/core/pools/projectile_pool.gd
class_name ProjectilePool
extends ObjectPool

const SOFT_LIMIT_FIELD := &"projectile_soft_limit"    # 全场软上限 1500
var soft_limit: int = 1500

func acquire() -> ProjectileBase:             # 类型收窄；超软上限 → null + 计数（调用方丢弃）
func release(p: ProjectileBase) -> void:      # 归还前调用 p._reset_state()（唯一清零入口）
func force_recycle_oldest() -> void:          # 硬上限 2000 触达时：回收最老存活弹（FORCED 路径）
func total_active() -> int:                   # 全场投射物计数（软/硬闸门判据）
```

```gdscript
# scripts/core/pools/enemy_pool.gd
class_name EnemyPool
extends ObjectPool
func acquire() -> Enemy:                      # 敌人实体取出
func release(e: Enemy) -> void:               # 尸体表现完成后归还（清零含状态容器/词条/订阅）
```

```gdscript
# scripts/core/pools/popup_pool.gd
class_name PopupPool
extends ObjectPool
func acquire() -> DamagePopup:                # 跳字取出（满池由 PopupManager 合并降级，§六.3）
func release(p: DamagePopup) -> void:
```

```gdscript
# scripts/core/pools/particle_pool.gd
class_name ParticlePool
extends ObjectPool
func acquire() -> GPUParticles2D:             # 一次性发射器（播放完成信号 → 自动归还）
func burst(scene_id: StringName, pos: Vector2, priority: int) -> void:  # 优先级裁剪 + ≤64 发射器（AC-15.5）
func release(e: GPUParticles2D) -> void:
```

```gdscript
# scripts/core/pools/laser_pool.gd  /  xp_pool.gd（同模式，略）
class_name LaserBeamPool / XPPool
extends ObjectPool
```

### 2.4 SpaceGrid（128px 哈希空间网格，弹-敌碰撞主路径）

实现要点见 §五.2；类契约如下。GameLoop 持有两实例：`enemy_grid`（敌人）与 `enemy_bullet_grid`（敌方弹，供消弹查询）。

```gdscript
# scripts/core/space_grid.gd
class_name SpaceGrid
extends RefCounted

const CELL_SIZE: int = 128                    # Q-15 裁定格边

var _cols: int = 0                            # 列数（含出屏余量，默认 8）
var _rows: int = 0                            # 行数（默认 13）
var _buckets: Array[Array] = []               # 固定桶数组（_cols×_rows，预分配空 Array）
var _occupied: Array[int] = []                # 本帧被写过的桶索引（O(used) 清空）
var _query_buffer: Array[Node2D] = []         # 复用查询缓冲（零 GC 分配）

func configure(world_size: Vector2, margin: float) -> void:  # 计算列行数并预分配桶
func rebuild(p_items: Array[Node2D]) -> void:  # 每帧重建：按 _occupied 清桶（O(used)）→ 全量插入（O(n)）
func insert(item: Node2D, radius: float) -> void:            # 增量插入（按中心坐标入桶，索引钳制防越界；供波内补插）
func query_circle(pos: Vector2, radius: float) -> Array[Node2D]:  # 覆盖格扫描 + 距离精判（复用缓冲）
func query_nearest(pos: Vector2, radius: float, exclude: Node2D) -> Node2D:  # 折射寻的/索敌
func query_arc(pos: Vector2, radius: float, dir_from: float, half_arc: float) -> Array[Node2D]:  # 挥斩扇形
func _cell_index(pos: Vector2) -> int:        # 坐标 → 桶索引（位运算除法 + 边界钳制）
func _for_each_cell_in_range(pos: Vector2, radius: float, cb: Callable) -> void:  # 遍历覆盖格
```

### 2.5 M-12 DamagePipeline（九步结算；方法级细节见 §四）

```gdscript
# scripts/core/damage/damage_pipeline.gd
class_name DamagePipeline
extends RefCounted

var _idempotent_cache: Dictionary = {}        # int64 键 -> DamageResult（每帧清空）
var _rng_streams: Dictionary = {}             # stream_id -> RandomNumberGenerator（种子可注入）
var _stats: Dictionary = {}                   # {settles, dropped_dead, dropped_dupe, alarms...}

func bind_rng_stream(stream_id: int, seed: int) -> void:     # AC-12.5 固定种子回归
func begin_frame() -> void:                   # GameLoop 投射物阶段前调用：清幂等缓存
func end_frame() -> void:                     # 帧末：遥测计数落 DebugStats
func resolve(ctx: DamageContext) -> DamageResult:            # ★ 唯一公共入口（§4.2 九步序列）
func resolve_reaction(p_ctx: DamageContext) -> DamageResult: # F21 独立结算通道（ElementalSystem 预构造 ctx：HIT_IS_REACTION、快照面板、空乘区；跨层引用仅 DamageContext.target 白名单载荷）
func stats() -> Dictionary:                   # DebugStats 查询

# —— 九步私有方法（顺序即 B_spec §2.3，禁止重排）——
func _sanitize(ctx: DamageContext) -> bool:                  # 0. NaN/Inf/负数防御（§六.4，不改九步语义）
func _check_idempotent(ctx: DamageContext) -> DamageResult:  # 1. 幂等检查（命中返回缓存结果）
func _target_alive(ctx: DamageContext) -> bool:              # 2. 目标存活（死亡短路 + 丢弃计数）
func _aggregate_add(ctx: DamageContext, stack: ModifierStack) -> void:  # 3. Add 池聚合（F3 衰减 + 负贡献全额 + F4 池钳）
func _apply_flat(ctx: DamageContext, stack: ModifierStack) -> void:     # 4. Flat 加入（f_flat 比例钳制）
func _aggregate_mults(ctx: DamageContext, stack: ModifierStack) -> void:  # 5. 乘区聚合（双层规则/单区 cap/名额≤8/整体钳 8.0）
func _aggregate_local(ctx: DamageContext, stack: ModifierStack) -> void: # 6. Local 池独立聚合（不入名额）
func _roll_crit(ctx: DamageContext) -> bool:                 # 7. 暴击掷骰（独立 RNG 流；DOT/反应跳过）
func _populate_result(ctx: DamageContext, stack: ModifierStack, crit: bool, result: DamageResult) -> void:  # 7b. 四段中间量落字段（S/M/L/C + 派生 feel_level/popup_style）
func _apply_target_side(ctx: DamageContext, stack: ModifierStack, result: DamageResult) -> void:  # 8. 抗性 × 状态易伤
func _finalize(ctx: DamageContext, stack: ModifierStack, result: DamageResult) -> void:  # 9a+9b. 终值钳制 + R_alarm + 审计落字段 + killed 判定
func _broadcast(result: DamageResult) -> void:               # 9c. EventBus 双事件（damage_resolved / damage_alarm）
func _cache_result(ctx: DamageContext, result: DamageResult) -> void:    # 9d. 幂等缓存写入（位拼接键）
```

数据结构（M-12 契约三件套）：

```gdscript
# scripts/core/damage/damage_context.gd
class_name DamageContext
extends RefCounted
# B_spec §2.2 的实现级细化：add_ids[] 细化为 add_entries（携带层数/δ/原始贡献，
# 因 B_spec §2.3 步骤 3 的衰减职责发生在管线内，需要层数信息；语义不变）。
var source_uid: int = 0                       # 来源实例 UID（投射物/光束/武器/反应源）
var target_uid: int = 0
var target: Enemy = null
var frame_stamp: int = 0                      # 幂等键第三元
var rng_stream_id: int = 0
# 面板段
var base_atk: float = 0.0                     # F2 结果（武器表终值 × g_global）
var add_entries: Array[Dictionary] = []       # {trait_id, pool_id, layer, contrib, decay_delta, is_curse}
var flat_bonus: float = 0.0
# 乘区段
var mult_pools: Array[Dictionary] = []        # {pool_id, source_uid, contrib, cap_pool}
var local_pools: Array[Dictionary] = []       # {local_id, contrib, cap_local}
# 暴击
var crit_chance: float = 0.0
var crit_mult: float = 2.0
# 类型与目标
var element: int = GameConst.Element.KIN
var hit_flags: int = 0                        # GameConst.HIT_* 位标志
var target_resist: float = 0.0                # 快照读取（含超导削抗后的当前值）
# 条件求值上下文快照（A2 §7.1，乘区 contrib 已在来源侧求值，此为审计/词条自评用）
var bounce_count: int = 0
var pierce_index: int = 0
var generation: int = 0
var is_first_hit_of_wave: bool = false
var player_hp_pct: float = 1.0
var pos: Vector2 = Vector2.ZERO               # 跳字锚点

static func make() -> DamageContext:          # 工厂（测试/运行共用，字段默认值即安全值）
```

```gdscript
# scripts/core/damage/modifier_stack.gd
class_name ModifierStack
extends RefCounted
# A2 §7.2：聚合与护栏的唯一执行点（步骤 3~6 的产物，只算不改语义）
var add_pool_sum: Dictionary = {}             # pool_id -> 衰减后有效和 Σ_add（F3+F4 后）
var flat_clamped: float = 0.0
var mult_pools: Dictionary = {}               # pool_id -> {contrib_sum, cap_pool, merged_M}
var resolved_mults: Array[Dictionary] = []    # top-N（≤8）截断后的有序乘区表
var product_clamped: float = 1.0              # min(∏ M_p, 8.0)（F9）
var local_product: float = 1.0                # ∏ L_l（独立段）
var audit: DamageAudit = null                 # 审计（只记录不改结果）
```

```gdscript
# scripts/core/damage/damage_audit.gd
class_name DamageAudit
extends RefCounted
# §2.5 遥测唯一数据源；"恒空为健康"的字段见健康线注释
var clamped_add: Array[StringName] = []       # F4 触发池（正常不可达）
var clamped_flat: bool = false
var truncated_mults: Array[StringName] = []   # 名额截断（接近 0 为健康）
var compressed: bool = false                  # F9 整体钳制触发（M1=0，M2+ <0.5%）
var dedup_defense: Array[Dictionary] = []     # 防御层去重 [{pool_id, source_uid}]（>0 即 bug）
var alarm: bool = false                       # R_alarm 触发（=0 为健康）
var ratio: float = 0.0                        # final / base_atk（抗性前口径）
var pool_count: int = 0                       # 参与乘区数
var mult_product: float = 1.0
```

```gdscript
# scripts/core/damage/damage_result.gd
class_name DamageResult
extends RefCounted
# 跳字/遥测/GameFeel 共源（B_spec M-12 契约）
var final_value: float = 0.0
var is_crit: bool = false
var killed: bool = false
var element: int = 0
var source_uid: int = 0
var target_uid: int = 0
var frame_stamp: int = 0
var pos: Vector2 = Vector2.ZERO               # 跳字位置
var panel_snapshot: float = 0.0               # S（面板段终值；反应/DOT 快照源）
var mult_product: float = 1.0                 # 钳制后乘区段
var local_product: float = 1.0
var target_factor: float = 1.0                # (1−r) × 状态修正
var pool_breakdown: Dictionary = {}           # pool_id -> agg（乘区明细，M2 HUD 峰值统计）
var feel_level: int = 0                       # GameConst.FeelLevel（HIT/CRIT/CATALYST）
var popup_style: int = 0                      # GameConst.PopupStyle
var audit: DamageAudit = null
```

### 2.6 M-14 DataRegistry / DataValidator（数据注册表与启动校验）

```gdscript
# scripts/core/data/data_registry.gd
class_name DataRegistry
extends RefCounted

var weapons: Dictionary = {}                  # StringName(id) -> WeaponData
var enemies: Dictionary = {}                  # StringName(id) -> EnemyData
var traits: Dictionary = {}                   # StringName(id) -> TraitData
var relics: Dictionary = {}
var synergies: Dictionary = {}
var wave_table: WaveTableData = null
var game_feel: GameFeelConfig = null
var report: Dictionary = {}                   # 校验报告（剔除清单 + 错误明细）

func load_all(manifest: String) -> float:     # 按 manifest.cfg 顺序扫描目录加载；返回耗时秒（AC-13.4）
func get_weapon(id: StringName) -> WeaponData:        # 未命中返回 null（调用方 fail-fast）
func get_trait(id: StringName) -> TraitData:
func get_enemy(id: StringName) -> EnemyData:
# ……（get_relic / get_synergy / get_wave_table / get_game_feel 同模式）
func trait_ids_by_pool(pool: int) -> Array[StringName]:  # 卡池构成 roll 的数据源
```

```gdscript
# scripts/core/data/data_validator.gd
class_name DataValidator
extends RefCounted

func validate_all(registry: DataRegistry) -> Dictionary:      # 全量校验 → {fatal[], rejected[], warnings[]}
func validate_weapon(w: WeaponData) -> Array:                # 单类校验（规则见 §三.1）
func validate_enemy(e: EnemyData) -> Array:
func validate_trait(t: TraitData) -> Array:                  # B_spec §2.5 L1 守门（pool 合法/δ≤0.92/cap_pool_p）
func validate_relic(r: RelicData) -> Array:
func validate_synergy(s: SynergyRuleData) -> Array:
func validate_wave_table(t: WaveTableData) -> Array:
func check_references(registry: DataRegistry) -> Array:      # 引用完整性（AC-13.3：悬空 TraitData id → 剔除宿主）
```

### 2.7 M-09 ProjectileBase（投射物系统）

#### 2.7.1 ProjectileBase（抽象基类）

```gdscript
# scripts/combat/projectile/projectile_base.gd
class_name ProjectileBase
extends Node2D
# Q-15：弹-敌碰撞走 SpaceGrid 自管查询 —— 不用 Area2D 回调，故基类为 Node2D（Sprite2D 子节点渲染）。

var uid: int = 0                              # GameConst.next_uid()
var team: int = 0                             # 0=玩家弹 1=敌方弹（消弹/命中判定分流）
var velocity: Vector2 = Vector2.ZERO
var lifetime_left: float = 0.0                # 寿命（超程/超时 → EXPIRED）
var pierce_left: int = 0                      # 穿透计数器
var bounces_left: int = 0                     # 反弹计数器
var generation: int = 0                       # 分裂代数（≤3）
var hitbox_radius: float = 6.0
var element: int = GameConst.Element.KIN
var attach_value: float = 0.0                 # 元素附着负载（命中时提交 ElementalSystem）
var size_mult: float = 1.0                    # 体积极限累计（碰撞盒/精灵等比）
var weapon_uid: int = 0                       # 来源武器（面板快照归属）
var panel_snapshot: Dictionary = {}           # 武器面板快照 {base_atk, crit_rate, crit_mult, add模板...}
var trait_stack: TraitStack = null            # 本弹词条（挂载序 = 派发序）
var damage_pipeline: DamagePipeline = null    # 注入（结算入口）
var hits_this_frame: Dictionary = {}          # target_uid -> true（帧聚合，E-03：一帧一目标一条）
var enemy_grid: SpaceGrid = null              # 注入（碰撞查询）
var is_clean: bool = true                     # 池清洁标记（归还/取出双向断言）

func spawn(p_params: Dictionary) -> void:     # 池取出后统一初始化（参数字典契约见本块下方注）
func tick(p_game_delta: float) -> void:       # 运动学 → 出界/寿命 → 网格查询 → 帧聚合命中提交
func _move(p_game_delta: float) -> void:      # 抽象：子类运动模型（直线/转向插值）
func _check_collision() -> void:              # enemy_grid.query_circle(自身 r) → _submit_hit 逐个
func _submit_hit(target: Enemy) -> void:      # 构建 ctx → 派发 ON_HIT（词条注入乘区）→ pipeline.resolve → 后处理
func _on_settled(target: Enemy, result: DamageResult) -> void:  # 结算后：附着/穿透计数/OnPierce 或回收判定
func _dispatch_event(event: int, tctx: TraitContext) -> void:    # ★ 六大事件唯一派发点（挂载序确定性）
func request_split(p_count: int, p_spread_deg: float, p_inherit_ratio: float) -> void:  # 分裂（三重闸门 §六.3）
func _apply_bounce(normal: Vector2) -> void:  # 边界反弹（反射角镜像）+ bounces_left-- + ON_BOUNCE
func _recycle(p_reason: int) -> void:         # ★ 回收五路径统一收束（E-04 契约：OnExpire → 清零 → 归还）
func _reset_state() -> void:                  # 归还清零契约：速度/计数/词条/订阅/计时器（池断言调用）
func is_player_projectile() -> bool:          # team == 0
```

> `spawn(p_params)` 参数字典键契约（**阶段 D 包 2/包 3 的冻结接口**）：`{velocity, lifetime, pierce, bounces, hitbox_radius, element, attach_value, generation, weapon_uid, panel_snapshot, trait_stack, team}`——由武器侧构造并打包（Homing 形态另含 `{target_uid, turn_rate, speed_init, speed_max, accel, arm_delay, blast_radius, blast_falloff}`）；池化要求"一个入口参数化全部初值"。

#### 2.7.2 子类差异签名

```gdscript
# scripts/combat/projectile/ballistic_projectile.gd
class_name BallisticProjectile
extends ProjectileBase

var acceleration: float = 0.0                 # 加特林变体可 >0；手枪/霰弹 = 0（匀速直线）

func _move(p_game_delta: float) -> void:      # 匀速/加速直线 + 屏幕四边反射判定（bounces_left>0 时）
func _check_range() -> void:                  # 超射程（range 快照）→ EXPIRED 回收
```

```gdscript
# scripts/combat/projectile/homing_projectile.gd
class_name HomingProjectile
extends ProjectileBase

var target_uid: int = 0                       # 锁定目标（死亡 0.2s 内重索敌，AC-05.4）
var turn_rate: float = 480.0                  # 最大角速度 °/s
var speed_init: float = 240.0
var speed_max: float = 720.0
var accel: float = 900.0
var arm_delay: float = 0.15                   # 二段延时启动（直飞段无追踪，AC-05.1）
var blast_radius: float = 45.0                # 命中范围爆炸
var blast_falloff: float = 0.6                # 中心 100% → 边缘 60%（线性）

func _move(p_game_delta: float) -> void:      # arm 计时 → 转向插值 clamp 角速度 → 加速度积分 clamp 末速
func _on_settled(target: Enemy, result: DamageResult) -> void:  # 命中即爆炸：AOE 次级结算（IS_AOE_SECONDARY）
func _retarget() -> void:                     # enemy_grid.query_nearest（原目标半径内 ≠ 原目标）
```

### 2.8 M-05~M-08 WeaponBase 与四形态子类

#### 2.8.1 WeaponBase（抽象）

```gdscript
# scripts/combat/weapon/weapon_base.gd
class_name WeaponBase
extends Node2D

signal leveled(new_level: int)

@export var data: WeaponData                  # 形态参数（M-14 注入）

var uid: int = 0
var level: int = 1                            # L1~L5（升级表终值口径）
var player: Player = null                     # 宿主注入
var trait_stack: TraitStack = null            # 武器级词条（常驻面板聚合 + OnHit 注入源）
var target_strategy: int = 0                  # 目标策略枚举（NEAREST / FOREMOST / LOWEST_HP / LOCKED）
var cooldown_left: float = 0.0
var damage_pipeline: DamagePipeline = null    # 注入
var projectile_pool: ProjectilePool = null    # 注入
var enemy_grid: SpaceGrid = null              # 注入（索敌）

func setup(p_data: WeaponData, p_player: Player, p_deps: Dictionary) -> void:  # 绑定数据/宿主/依赖注入包
func tick(p_game_delta: float) -> void:       # 冷却推进 → 满足节拍时 try_fire（射速上限 30/s 双护栏）
func try_fire() -> bool:                      # ★ 开火入口（抽象：子类实现开火行为；软上限检查在 ProjectilePool）
func attach_trait(p_trait: TraitData) -> void:  # 词条挂载（单武器 ≤12，超出拒绝+计数；卡牌流前置过滤）
func get_stat(p_key: StringName) -> float:    # 当前等级终值（upgrade_table[level-1]）
func get_current_atk() -> float:              # F2：get_stat("base_atk") × g_global（g_global 当前=1）
func build_panel_snapshot() -> Dictionary:    # 面板段快照（分裂继承比例的母本，F-13）
func build_damage_context(p_target: Enemy) -> DamageContext:  # 武器侧聚合 ctx（add/flat/暴击参数 + 词条乘区预聚合）
func _level_up() -> void:                     # 武器精通卡应用 → leveled 信号
```

#### 2.8.2 BallisticWeapon（M-05 形态 A：手枪/加特林/霰弹同构）

```gdscript
# scripts/combat/weapon/ballistic_weapon.gd
class_name BallisticWeapon
extends WeaponBase

var spin_up_left: float = 0.0                 # 加特林预热计时（0 = 非加特林变体）
var rof_current: float = 0.0                  # F11：rof × (1+ΣAdd_ROF) clamp 30

func try_fire() -> bool:                      # N=pellets 发 × 散射锥均匀分布 → ProjectilePool.acquire
func _spread_angle(i: int) -> float:          # 第 i 丸在总锥内的均匀角度
func _spin_progress(p_game_delta: float) -> void:  # 加特林 rof 斜坡（预热→满热→冷却重置，F11 分段）
```

#### 2.8.3 LaserWeapon + LaserBeam（M-06 形态 B）

```gdscript
# scripts/combat/weapon/laser_weapon.gd
class_name LaserWeapon
extends WeaponBase

var beam_pool: LaserBeamPool = null           # 注入
var active_beams: Array[LaserBeam] = []       # 本武器存活光束段
var tick_accumulator: float = 0.0             # tick_rate 节拍

func try_fire() -> bool:                      # 维持主光束指向（目标策略：最近/最前）
func _spawn_beam(p_origin: Vector2, p_dir: Vector2, p_depth: int) -> LaserBeam:  # 深度>2 拒绝+chain_fused 计数
func _on_beam_refracted(p_hit_pos: Vector2, p_parent: LaserBeam) -> void:  # 命中带折射词条 → 分叉子光束
func build_tick_context(p_target: Enemy, p_scorch: int) -> DamageContext:  # 每跳 ctx：scorch Local 池注入（F-15）
```

```gdscript
# scripts/combat/weapon/laser_beam.gd
class_name LaserBeam
extends Node2D
# 光束不是 M-09 投射物（B_spec M-06），独立实体但共享 M-10 词条与 M-12 结算。

var depth: int = 0                            # 0=主光束；折射分叉深度上限 2
var scorch_layers: Dictionary = {}            # target_uid -> 灼焦层数（≤scorch_max_layers）
var tick_left: float = 0.0                    # tick_rate 节拍剩余
var popup_throttle: Dictionary = {}           # target_uid -> 跳字下次可发时刻（≤15Hz/目标，AC-04.2）
var raycast: RayCast2D                        # 子节点（首敌命中）
var line: Line2D                              # 子节点（线段渲染）

func spawn(p_params: Dictionary) -> void:     # 池取出初始化（origin/dir/depth/武器快照）
func tick(p_game_delta: float) -> void:       # RayCast 投射 → 灼焦叠层管理 → 节拍结算 → 跳字节流
func _on_hit_target(p_target: Enemy) -> void: # 叠层 +1（1 层/0.25s，上限 8）→ 结算（Local 池注入）
func request_refract(p_count: int) -> void:   # 分叉请求（深度>2 拒绝并计数，AC-04.3）
func _reset_state() -> void:                  # 归还清零（层数表/节流表/订阅）
```

#### 2.8.4 HomingWeapon（M-07 形态 C）

```gdscript
# scripts/combat/weapon/homing_weapon.gd
class_name HomingWeapon
extends WeaponBase

var sub_warheads_left: int = 0                # 集束火箭变体：子弹头待发数

func try_fire() -> bool:                      # cd 制 → 索敌 → 发射 HomingProjectile（锁定 uid）
func _acquire_target() -> Enemy:              # enemy_grid.query_nearest（目标策略）
func _on_missile_impact(p_pos: Vector2, p_radius: float) -> void:  # AOE：圆查询逐敌结算（幂等保护）
func _launch_sub_warheads(p_pos: Vector2) -> void:  # 主弹爆开 → sub_count 枚延时寻的子弹头
```

#### 2.8.5 OrbitWeapon + OrbitField + ArcSlash（M-08 形态 D）

```gdscript
# scripts/combat/weapon/melee/orbit_weapon.gd
class_name OrbitWeapon
extends WeaponBase

var orbit_field: OrbitField = null            # 环绕力场实体（池化）
var arc_slash: ArcSlash = null                # 周期挥斩实体（池化）

func try_fire() -> bool:                      # 近战形态"开火"= 周期性判定调度（hit_cd / cd）
func _orbit_hit(p_orb_index: int, p_target: Enemy) -> void:   # 环绕体周期结算（每目标独立 hit_cd）+ 击退
func _slash_window() -> void:                 # 挥斩窗口开启（持续 0.15s，窗口外无判定）
```

```gdscript
# scripts/combat/weapon/melee/orbit_field.gd
class_name OrbitField
extends Node2D

var orbs: int = 2                             # 浮游球数
var orbit_radius: float = 90.0
var angular_speed: float = 240.0              # °/s
var orb_radius: float = 16.0
var angle: float = 0.0
var target_hit_cd: Dictionary = {}            # "orb_idx:target_uid" -> 剩余冷却

func spawn(p_params: Dictionary) -> void:     # 池取出初始化
func tick(p_game_delta: float, p_center: Vector2) -> void:  # 公转推进 + 球位更新 + 判定调度
func _apply_knockback(p_target: Enemy, p_force: Vector2) -> void:  # 击退（可打断自爆引导）
func _reset_state() -> void:
```

```gdscript
# scripts/combat/weapon/melee/arc_slash.gd
class_name ArcSlash
extends Node2D

var slash_radius: float = 150.0
var arc_deg: float = 120.0                    # 扇形角
var facing: float = 0.0                       # 固定角度窗口中心
var window_left: float = 0.0                  # 判定窗口剩余（0.15s）
var max_targets: int = 8                      # 单斩目标上限
var enemy_bullet_grid: SpaceGrid = null       # 注入（消弹查询）

func spawn(p_params: Dictionary) -> void:
func tick(p_game_delta: float, p_center: Vector2) -> void:  # 窗口内：扇形判定（query_arc）+ 消弹
func _nullify_enemy_bullets() -> void:        # 弧内敌方弹 → OnExpire(NULLIFIED) 路径销毁（AC-06.2）
func _reset_state() -> void:
```

### 2.9 M-10 TraitBase / TraitStack（词条引擎）

#### 2.9.1 TraitBase（运行时词条实例）

```gdscript
# scripts/combat/trait/trait_base.gd
class_name TraitBase
extends RefCounted

var data: TraitData = null                    # 定义（.tres，只读共享）
var layers: int = 1                           # 当前叠层（运行时状态，独立于数据，AC-07.4）
var cooldown_left: float = 0.0
var proc_rng: RandomNumberGenerator = null    # 触发概率掷骰流（种子可注入）
var frame_triggered: bool = false             # 本帧已触发（E-03 重入标记）
var in_dispatch: bool = false                 # 链式重入保护位
var effect: TraitEffect = null                # effect_id → builtin 处理器（§2.9.2）

func setup(p_data: TraitData) -> void:        # 绑定定义 + 解析 effect 处理器
func can_trigger(p_ctx: TraitContext) -> bool:  # 冷却 + 概率 + frame_triggered 三闸
func on_event(p_event: int, p_ctx: TraitContext) -> void:  # 效果入口（内置处理器分发）
func get_contribution(p_ctx: TraitContext) -> float:      # 乘区贡献（条件自评，注入 DamageContext）
func get_decay_sum() -> float:                # F3 预览值 T(layers)（仅供卡牌 tooltip/DebugStats；结算真源唯一在管线步骤 3）
func reset_runtime() -> void:                 # 分裂继承时的状态重置（层数保留/冷却清零——按继承规则）
```

```gdscript
# scripts/combat/trait/trait_context.gd
class_name TraitContext
extends RefCounted
# 事件载荷：词条自评与效果执行的全部上下文
var event: int = 0                            # GameConst.TraitEvent
var projectile: ProjectileBase = null         # 六事件宿主（光束/近战时为 null）
var beam: LaserBeam = null
var melee: Node2D = null
var weapon: WeaponBase = null
var target: Enemy = null
var damage_ctx: DamageContext = null          # ON_HIT 期可注入乘区（contrib 通道）
var game_delta: float = 0.0
var split_request: Dictionary = {}            # ON_EXPIRE 期分裂请求输出（由引擎执行）
var attach_request: Dictionary = {}           # 元素附着请求输出 {element, value}
```

#### 2.9.2 内置效果处理器（trait/builtin/，effect_id → 类映射）

```gdscript
# scripts/combat/trait/builtin/trait_effect.gd（基类）
class_name TraitEffect
extends RefCounted
func handle(p_trait: TraitBase, p_ctx: TraitContext) -> void:      # 抽象：效果执行
func evaluate_contribution(p_trait: TraitBase, p_ctx: TraitContext) -> float:  # 条件乘区贡献
# 六个子类（size/fractal/bounce/elemental/stat/mech）签名同构，按 effect_id 分派：
#   trait_effect_size.gd      → 体积极限：size_mult 累计 + ≥3.0× 触发 TH_SIZE_NOVA 冲击波
#   trait_effect_fractal.gd   → 几何分裂：split_request 输出（三重闸门在引擎侧）
#   trait_effect_bounce.gd    → 反弹/折射：bounces_left 增量 + 增伤乘区注入
#   trait_effect_elemental.gd → 元素附着：attach_request 输出
#   trait_effect_stat.gd      → 加算属性：面板段聚合（build ctx 时求值）
#   trait_effect_mech.gd      → 通用机制（死亡新星/格挡/谐振轨道）
```

#### 2.9.3 TraitStack（引擎核心）

```gdscript
# scripts/combat/trait/trait_stack.gd
class_name TraitStack
extends RefCounted

const MAX_CHAIN_DEPTH: int = 3                # 链式反应深度上限（B_spec M-10）
const MAX_TRAITS: int = 12                    # 单投射物词条上限（B_spec §1.2）

var traits: Array[TraitBase] = []             # 挂载序 = 派发序（确定性，AC-07.2）
var _depth: int = 0                           # 当前派发链深度
var _dispatching: bool = false
var _fused_count: int = 0                     # 熔断计数

func attach(p_data: TraitData) -> bool:       # 挂载：同 ID 叠层 / 新建；超 12 拒绝
func dispatch(p_event: int, p_ctx: TraitContext) -> void:  # ★ 按挂载序派发；深度+1；>3 熔断+chain_fused
func copy_for_split(p_generation: int) -> TraitStack:  # F-13：inheritable 定义复制 + 运行时状态重置（引用复制非深拷贝，E-13）
func aggregate_panel(p_base_atk: float) -> Dictionary:  # 常驻加算聚合 {add_sum, flat_sum, crit_rate, crit_mult, ...}
func collect_mult_pools(p_ctx: TraitContext) -> Array[Dictionary]:  # 乘区预聚合（贡献自评）
func clear() -> void:                         # 归还清零（池断言前置）
func is_empty() -> bool:
func size() -> int:
```

### 2.10 M-11 ElementalSystem / ElementalState（元素系统）

```gdscript
# scripts/combat/elemental/elemental_system.gd
class_name ElementalSystem
extends Node

var pipeline: DamagePipeline = null            # 注入（DOT/连锁/反应独立结算）
var enemy_grid: SpaceGrid = null               # 注入（连锁传导/范围扩散目标查询）
var _hosts: Array[Enemy] = []                  # 已挂载状态容器的敌人（§1.3-3 白名单：状态宿主）

func register_host(p_enemy: Enemy) -> void:    # 敌人出生时挂载 ElementalState
func unregister_host(p_enemy: Enemy) -> void:  # 死亡/回收时移除（清 DOT，AC-11.1）
func apply_attach(p_enemy: Enemy, p_element: int, p_value: float) -> void:  # 附着入口（immune_mask 检查）
func tick(p_game_delta: float) -> void:        # 全敌：λ 比例衰减（F19）→ 状态计时 → DOT 跳伤调度
func detect_reactions() -> void:               # ★ 帧末统一检测（敌人阶段末调用，E-07）：优先级 碎裂>过载>超导；一帧一反应
func _trigger_reaction(p_enemy: Enemy, p_rxn: int) -> void:  # 构造反应 ctx（HIT_IS_REACTION + 快照面板）→ pipeline.resolve_reaction + cd_rxn + 清双槽
func _dot_tick(p_enemy: Enemy) -> void:        # 构造 DOT ctx（HIT_IS_DOT + 快照）→ pipeline 独立结算（不掷暴击）
func _shock_chain(p_origin: Enemy, p_snapshot: float) -> void:  # 感电连锁：网格 query 3 目标/160px/35%每跳/深度 2 衰减 60%（同周期同目标去重）
```

```gdscript
# scripts/combat/elemental/elemental_state.gd
class_name ElementalState
extends RefCounted
# 单敌三槽状态容器（A2 §4.1 附着—衰减—触发—消耗）

var gauges: Array[float] = [0.0, 0.0, 0.0]     # FIR / ICE / LTG 附着计量 G
const GAUGE_MAX: float = 100.0
var immune_mask: int = 0                       # 宿主 Enemy 注入
# 状态运行时
var burn_layers: int = 0                       # ≤5（第 6 次附着拒绝）
var burn_timer: float = 0.0
var dot_tick_left: float = 0.5                 # 每 0.5s 一跳
var chill_timer: float = 0.0                   # 寒滞 2.5s（移速 −40%）
var freeze_timer: float = 0.0                  # 完全冻结 1.2s（定身，受 immune_mask）
var vuln_timer: float = 0.0                    # 易伤 ×1.25 3s（目标侧独立乘区）
var shock_chain_cd: float = 0.0
var reaction_cd: Dictionary = {}               # rxn -> 剩余（cd_rxn=2s）

func apply(p_element: int, p_value: float) -> bool:  # 附着：满槽触发状态并清空该槽（F19/F20 稳态免疫线）
func tick(p_game_delta: float, p_decay_lambdas: Array[float]) -> void:  # λ 比例衰减 + 全部状态计时
func get_speed_factor() -> float:              # 寒滞/冻结 → 0.6 / 0.0（行为修正）
func get_vuln_factor() -> float:               # 易伤激活 → 1.25（乘区注入）
func is_state_active(p_element: int) -> bool:  # 条件乘区词条自评（SYN_FROST_EXEC 等）
func has_both(p_a: int, p_b: int) -> bool:     # 反应条件（帧末检测）
func clear_element(p_element: int) -> void:    # 反应消耗/死亡清理
func reset() -> void:                          # 归还清零
```

### 2.11 M-03 Enemy + EnemySpawner

```gdscript
# scripts/entities/enemy/enemy.gd
class_name Enemy
extends Node2D
# Node2D + 子 Area2D（接触伤害，低频）+ Sprite2D（共享受击闪白材质）。
# 弹-敌命中由投射物侧 SpaceGrid 查询完成；敌间分离力走网格 10Hz（E-10）。

var uid: int = 0
var data: EnemyData = null
var tags: int = 0                             # TAG_ELITE / TAG_BOSS
var hp: float = 1.0
var max_hp: float = 1.0
var speed: float = 75.0                       # 波次成长后终值
var contact_dmg: float = 8.0
var exp_value: float = 3.0
var behavior: int = GameConst.EnemyBehavior.CHASE
var resist: Array[float] = [0.0, 0.0, 0.0, 0.0]  # KIN/FIR/ICE/LTG 快照（超导 −30% 实时改写）
var immune_mask: int = 0
var elemental: ElementalState = null          # 状态容器（M-11 注入）
var dead: bool = false                        # 死亡短路标志（E-06：首次致死立即置位）
var boss_phase: int = 0                       # Boss 阶段（HP<50% → 2 等）
var fire_cd_left: float = 0.0                 # RANGED 行为射击冷却

func spawn(p_data: EnemyData, p_wave: int, p_tags: int) -> void:  # 波次成长缩放（F27 四条曲线）
func tick(p_game_delta: float) -> void:       # 行为机（追击/远程/环绕）+ 状态效果速度因子 + Boss 阶段检查
func apply_damage(p_value: float) -> bool:    # 管线写血的唯一入口；返回 killed（死亡只执行一次）
func take_result(p_result: DamageResult) -> void:  # pipeline 步骤 9 调用：apply + 死亡广播 + 掉落触发
func get_resist(p_element: int) -> float:     # 快照读取（含超导削抗当前值）
func knockback(p_force: Vector2) -> void:     # 近战击退（可打断自爆引导）
func _on_died() -> void:                      # 一次性死亡：置 dead → EventBus.emit_enemy_killed → 尸体表现 → 池归还
func _reset_state() -> void:                  # 归还清零（状态容器/词条/计时/位标志）
func is_boss() -> bool: / func is_elite() -> bool:
```

```gdscript
# scripts/entities/wave/enemy_spawner.gd
class_name EnemySpawner
extends Node

var pool: EnemyPool = null                    # 注入
var spawn_queue: Array[Dictionary] = []       # 待生成队列 {data_id, wave, tags, pos}
const SPAWN_PER_FRAME: int = 8                # 单帧生成节流（B_spec M-04）
const MAX_ONSCREEN: int = 120                 # 同屏敌人上限（超出排队，波次不卡死）

func prewarm() -> void:                       # 启动预热：pool.prewarm(容量)（AC-14.2，Boot 期完成）
func enqueue(p_entry: Dictionary) -> void:    # WaveDirector 投放生成请求
func tick(p_game_delta: float, p_grid: SpaceGrid) -> void:  # 节流出队 → pool.acquire → enemy.spawn → 注册网格
func on_enemy_killed(p_enemy: Enemy) -> void: # 死亡通知：_reset_state + pool.release（尸体表现完成后）
```

### 2.12 M-02 Player

```gdscript
# scripts/entities/player/player.gd
class_name Player
extends Area2D
# Area2D：玩家命中盒（低频，Q-15 例外通道）+ 磁吸拾取区（120px + pickup_pct 词条加成）。

var max_hp: float = 100.0
var hp: float = 100.0
var move_speed: float = 280.0
var pickup_radius: float = 120.0              # Q-13 磁吸半径
var invuln_left: float = 0.0                  # 受击无敌帧（contact_tick=0.6s 口径）
var weapon_slots: Array[WeaponBase] = []      # ≤5
var unlocked_slots: int = 1                   # w3→2 / w7→3 / Boss1→4 / Boss2 或 w21→5（F-19）
var level: int = 1
var xp: float = 0.0
var xp_need: float = 14.0                     # 14 × lv^1.4

func setup(p_deps: Dictionary) -> void:       # 注入 pipeline/pools/grid/registry
func tick(p_game_delta: float, p_move_delta: Vector2) -> void:  # 相对拖动 + 活动区钳制（下 40% 屏，E-15）
func take_contact_damage(p_dmg: float) -> void:  # ★ 简化路径：无敌帧判定 → 直接扣 HP → 事件（不入 M-12，Q-16）
func add_weapon(p_data: WeaponData) -> WeaponBase:  # 槽位检查 → 实例化（形态工厂）→ setup
func gain_xp(p_amount: float) -> void:        # xp_gained → 升级 → EventBus.emit_level_up（GameLoop 仲裁 E-16）
func attach_player_trait(p_trait: TraitData) -> void:  # 玩家侧常驻词条（磁力吸附/生存本能等）
func unlock_slot(p_slot: int) -> void:        # slot_unlocked 事件
func get_hp_pct() -> float:                   # 背水协议条件（SYN_LOWHP_FURY ctx）
func _on_died() -> void:                      # EventBus.emit_player_died（优先级最高）
```

### 2.13 M-04 WaveDirector

```gdscript
# scripts/entities/wave/wave_director.gd
class_name WaveDirector
extends Node

var wave_table: WaveTableData = null          # M-14 注入
var spawner: EnemySpawner = null
var current_wave: int = 0
var tp_budget: float = 0.0                    # TP = 14 + 3.2w（无尽段 110×1.03^(w−30)）
var window_left: float = 0.0                  # 18 + 0.4w（无尽段 min(30+0.2(w−30), 40)）
var buffer_left: float = 0.0                  # 波间缓冲 1s + loot_buffer 3s
var enemies_alive: int = 0
var wave_first_kill_done: bool = false        # SYN_FIRST_STRIKE 重置位

func start_wave(p_wave: int) -> void:         # 读表/公式生成构成 → enqueue → wave_started 事件
func tick(p_game_delta: float) -> void:       # 窗口计时 → 强制叠波（hard cap）→ 清空检测 → wave_cleared
func on_enemy_killed(p_enemy: Enemy) -> void: # 存活计数 −1；Boss 掉落武器槽（F-19）；首杀位重置
func _roll_composition(p_wave: int) -> Array[Dictionary]:  # 表驱动优先，表缺失回退公式（TP 逐类扣减）
func _endless_params(p_wave: int) -> Dictionary:  # w>30：TP/窗口/精英（w mod 4==0 ×2）/Boss（w mod 10==0）
func _spawn_boss(p_wave: int) -> void:        # Boss 波：boss_spawned 事件 + 伴随怪持续刷（场上≤12）
```

### 2.14 M-15 GameFeelDirector

```gdscript
# scripts/gamefeel/game_feel_director.gd
class_name GameFeelDirector
extends Node

var feel_config: GameFeelConfig = null        # M-14 注入
var shake: CameraShake = null
var particles: ParticleDirector = null
var hit_stop_left: float = 0.0                # 顿帧剩余（raw 通道计时）
var hit_stop_active_ms: float = 0.0           # 当前激活时长（合并比较基准）
var merge_window: float = 0.03                # 30ms 内多触发取最大不叠加（AC-15.2）
var chromatic_rect: ColorRect = null          # 全屏色差 ColorRect（shaders/post）

func setup(p_deps: Dictionary) -> void:       # 注入 config/particle_pool/Camera2D/后处理 ColorRect
func on_damage_resolved(p_result: DamageResult) -> void:  # feel_level 分级入口（0/30/50ms 顿帧 + trauma）
func on_enemy_killed(p_enemy: Enemy) -> void: # Boss 死亡 → 120ms 顿帧 + trauma 1.0
func on_reaction_triggered(p_rxn: int, p_pos: Vector2) -> void:  # 质变级：50ms + trauma 0.4 + 色差
func on_player_hit(p_damage: float) -> void:  # trauma 0.15
func request_hit_stop(p_duration_ms: float) -> void:  # 向 GameLoop 申请（唯一出口，不直写 time_scale）
func tick(p_raw_delta: float) -> void:        # raw 通道：顿帧剩余衰减 / trauma 衰减 0.4s / 色差 0.15s 线性归零
func desired_time_scale() -> float:           # 返回 0.05（顿帧激活中）或 1.0 —— GameLoop 每帧拉取
func _apply_chromatic(p_intensity: float) -> void:  # shader uniform 触发（0.004 起跳分级放大）
```

```gdscript
# scripts/gamefeel/camera_shake.gd
class_name CameraShake
extends RefCounted
var trauma: float = 0.0                       # 0~1（trauma² 映射偏移）
func add(p_amount: float) -> void:            # clamp 1.0
func offset_and_rotation() -> Vector3:        # 输出 (offset: Vector2, rot: float)：最大 8px + 1.5°（Q-12）
func tick(p_raw_delta: float) -> void:        # 0.4s 衰减到 0
```

```gdscript
# scripts/gamefeel/particle_director.gd
class_name ParticleDirector
extends Node
func burst(p_scene_id: StringName, p_pos: Vector2, p_priority: int) -> void:  # 优先级裁剪（击杀>暴击>普命中>环境），≤64
```

### 2.15 M-16 HUD / PopupManager / DamagePopup

```gdscript
# scripts/ui/hud.gd
class_name HUD
extends CanvasLayer
# process_mode = ALWAYS（暂停/顿帧期间 UI 照常）

func bind_events() -> void:                   # 订阅 player_hit/xp_gained/wave_started/enemy_killed/state_changed
func refresh_stats() -> void:                 # HP/经验/等级/波次/击杀/计时（事件驱动 + 1Hz 兜底刷新）
```

```gdscript
# scripts/ui/popup_manager.gd
class_name PopupManager
extends Node

var popup_pool: PopupPool = null
var merge_window: float = 0.12                # 同目标短窗合并（E-17）
var active_popups: int = 0
const MAX_ACTIVE: int = 80                    # 同屏上限（超限合并到既有跳字，E-09）

func on_damage_resolved(p_result: DamageResult) -> void:  # 主入口：合并判断 → 池取出 → 样式分级
func tick(p_raw_delta: float) -> void:        # 跳字动画（raw 通道，顿帧期间照常）
```

```gdscript
# scripts/ui/damage_popup.gd
class_name DamagePopup
extends Node2D
var merged_value: float = 0.0                 # 合并累加值
var style: int = 0
func show_popup(p_pos: Vector2, p_value: float, p_style: int) -> void:  # 池取出后初始化 + 动画启动
func merge(p_value: float) -> void:           # 合并：数值累加 + 重置漂浮计时
func _reset_state() -> void:                  # 归还清零
```

### 2.16 M-17 CardSelectUI / CardGenerator

```gdscript
# scripts/cards/card_generator.gd
class_name CardGenerator
extends RefCounted

var registry: DataRegistry = null
var rarity_weights: Dictionary = {}           # {WHITE:58, BLUE:30, PURPLE:10, GOLD:2}（A3 §6.1 波次修正）
var category_weights: Dictionary = {}         # {MASTERY:12, ADD:40, MULT:18, MECH:14, ELEM:10, RELIC:6}

func generate_candidates(p_context: Dictionary) -> Array[Dictionary]:  # ★ 三选一：稀有度 roll → 类别 roll → 过滤 → 不足补 fallback
func _filter_candidates(p_pool: Array[Dictionary], p_context: Dictionary) -> Array:  # 叠层上限/槽位/词条≤12 过滤
func _fallback_stat_card() -> Dictionary:     # 卡池耗尽 → "+5% 攻击"类属性卡（AC-16.4，界面永不空）
func apply_choice(p_card: Dictionary, p_player: Player) -> void:  # 应用：词条挂载/遗物生效/精通升级/属性成长
```

```gdscript
# scripts/cards/card_select_ui.gd
class_name CardSelectUI
extends CanvasLayer
# process_mode = ALWAYS；仅 LEVEL_UP 状态可见

func open(p_candidates: Array[Dictionary]) -> void:  # GameLoop 仲裁后调用（E-16：死亡优先，GameOver 丢弃升级请求）
func close() -> void:                         # 选卡完成 → 请求恢复 → GameLoop 切回 PLAYING
signal choice_made(card: Dictionary)          # → CardGenerator.apply_choice → EventBus.emit_card_chosen
```

### 2.17 M-01 GameLoop（主场景 / 状态机 / 帧序 / time_scale）

```gdscript
# scripts/loop/game_loop.gd —— main.tscn 根节点
class_name GameLoop
extends Node2D

enum State { BOOT, MENU, PLAYING, PAUSED, LEVEL_UP, GAME_OVER }

var state: int = State.BOOT
var time_scale: float = 1.0                   # ★ 唯一持有者（写入口仅 set_time_scale）
var frame_stamp: int = 0                      # GameConfig.advance_frame 同步源
var pipeline: DamagePipeline
var enemy_grid: SpaceGrid                     # 敌人格（弹-敌碰撞主路径）
var enemy_bullet_grid: SpaceGrid              # 敌弹格（消弹查询）
var player: Player
var wave_director: WaveDirector
var elemental: ElementalSystem
var game_feel: GameFeelDirector
var pools: Dictionary = {}                    # {projectile, enemy, popup, particle, laser, xp}

func _ready() -> void:                        # Boot 序列：GameConfig → DataRegistry 校验 → 池预热 → MENU（<3s 预算）
func _physics_process(p_raw_delta: float) -> void:  # ★ 固定帧序（见下）
func _game_delta(p_raw_delta: float) -> float:      # raw × time_scale（子系统唯一时间源）
func set_time_scale(p_value: float, p_source: StringName) -> void:  # 唯一写入口（audit 调用者）
func change_state(p_new: int) -> void:        # 仲裁：GAME_OVER 优先级最高（E-16）；tree.paused 与 UI 可见性联动
func request_pause() / request_resume() -> void:   # M-17/M-16 暂停申请（仲裁后生效）
```

`_physics_process` 固定帧序（B_spec M-01 契约，顺序禁止重排）：

```
_physics_process(raw_delta):
    GameConfig.advance_frame()                        # 帧号 +1
    pipeline.begin_frame()                            # 清幂等缓存
    match state:
      PLAYING:
        gd = _game_delta(raw_delta)                   # time_scale 注入点
        ① 输入采样（缓冲本帧首触点，E-15 单指针锁定）
        ② player.tick(gd, move_delta)                 # 移动/受击/拾取
        ③ weapons.tick(gd)                            # 冷却推进 + try_fire（近战消弹用上一帧敌弹格）
        ④ enemy_grid.rebuild(活跃敌列表) → enemy_bullet_grid.rebuild(敌弹列表)
           projectiles.tick(gd)                       # 运动 → 网格查询 → 帧聚合 → resolve 提交
           （网格内容 = 上一敌 AI 帧位置的确定性快照；新敌出队于⑥，下一帧④起可见）
        ⑤ enemies.tick(gd) → elemental.tick(gd) → elemental.detect_reactions()  # 帧末反应检测（E-07）
        ⑥ wave_director.tick(gd)                      # 生成节流（单帧 ≤8）/ 窗口计时
        ⑦ game_feel.tick(raw_delta)                   # 特效衰减（raw 通道）
           set_time_scale(game_feel.desired_time_scale(), &"gamefeel")  # 顿帧唯一申请出口
        ⑧ ui.tick(raw_delta)                          # HUD/跳字（raw 通道）
      LEVEL_UP / PAUSED: tree.paused=true；仅 ⑦⑧ 以 raw 通道运行
    pipeline.end_frame()                              # 遥测落 DebugStats
    EventBus.end_frame()                              # 事件风暴计数清零
```

---

## 三、Resource 数据结构（.tres schema）

> 约定：全部 Resource 类位于 `scripts/core/data/resources/`；字段用 `@export`（编辑器可配）+ `@export_range` / `@export_enum` 范围提示（编辑期防线）；校验列给出 DataValidator 的启动期规则（运行期防线见 §六）。**示例 .tres 数值取自 A3 表**（数字真源）。

### 3.1 WeaponData（武器：四形态参数重写字段集）

| 字段 | 类型 | 默认值 | 校验规则（DataValidator） |
|---|---|---|---|
| `id` | StringName | `&""` | 非空、全局唯一；重复 → 后者剔除 |
| `display_name` | String | `""` | 非空（仅告警） |
| `form` | int（WeaponForm 枚举） | 0 | ∈ {0,1,2,3} |
| `crit_rate` | float | 0.05 | [0, 1] |
| `crit_dmg` | float | 2.0 | [1, 5]（F-30 基线 ×2.0） |
| `hitbox_r` | float | 6.0 | (0, 64] |
| `unlock_rarity` | int | 1 | 稀有度（卡池展示） |
| `upgrade_table` | Array[WeaponLevelStats] | [] | **恰好 5 项**；每项 L 终值校验（base_atk>0 等） |
| `threshold_traits` | Array[Dictionary] | [] | 每项 {threshold_id, metric, threshold, effect_id, params}；metric ∈ 封闭枚举 |
| `ballistic.*` | 见下（形态专属段） | — | form=BALLISTIC 必填且合法 |
| `laser.*` / `homing.*` / `melee.*` | 见下 | — | 对应 form 必填且合法 |

形态专属段（同一 .tres 内四段并存，按 form 取用；未启用段忽略校验）：

| 段 | 字段（类型/默认） | 校验 |
|---|---|---|
| BALLISTIC | `proj_speed: float=620`、`range: float=680`、`spread_deg: float=2.0`、`pierce: int=1`、`pellets: int=1`、`spin_up_time: float=0.0`（>0 = 加特林变体）、`rof_hot: float=0.0` | proj_speed>0；range>0；pierce≥0；pellets∈[1,16]；rof（在 L 表）≤30（cap_rof） |
| LASER | `beam_length: float=560`、`beam_width: float=14`、`tick_rate: float=8`、`scorch_max_layers: int=5`、`scorch_per_layer: float=0.08`、`refract_beams: int=0`、`refract_ratio: float=0.6`、`refract_depth: int=2` | tick_rate∈(0,30]；scorch_max_layers∈[1,8]；refract_depth ≤2（B_spec 上限，超限剔除） |
| HOMING | `proj_speed_init: float=240`、`proj_speed_max: float=720`、`accel: float=900`、`turn_rate: float=480`、`arm_delay: float=0.15`、`blast_r: float=45`、`blast_falloff: float=0.6`、`sub_count: int=0`、`sub_delay: float=0.4` | speed_max ≥ speed_init；turn_rate>0；blast_r∈(0,128]；sub_count∈[0,8] |
| MELEE | `orbit_radius: float=90`、`angular_speed: float=240`、`orbs: int=2`、`hit_cd: float=0.5`、`knockback: float=40`、`slash_radius: float=150`、`arc_deg: float=120`、`max_targets: int=8`、`nullify: bool=false` | arc_deg∈(0,360]；orbs∈[1,8]；hit_cd>0 |

WeaponLevelStats（嵌套 Resource）：

| 字段 | 类型 | 默认 | 校验 |
|---|---|---|---|
| `base_atk` | float | 10.0 | >0（负射速/负攻 → 剔除宿主，AC-13.2） |
| `rof` | float | 5.0 | (0, 30]（cap_rof 双护栏） |
| `cd` | float | 0.0 | LASER/HOMING/MELEE 形态：>0 |
| `pierce` | int | 1 | ≥0 |
| `pellets` | int | 1 | ≥1 |
| `note` | String | `""` | — |

示例 .tres（W1 手枪）：

```
[gd_resource type="Resource" script_class="WeaponData" load_steps=8 format=3]

[ext_resource type="Script" path="res://scripts/core/data/resources/weapon_data.gd" id="1_wd"]
[ext_resource type="Script" path="res://scripts/core/data/resources/weapon_level_stats.gd" id="2_wls"]

[sub_resource type="Resource" id="WeaponLevelStats_l1"]
script = ExtResource("2_wls")
base_atk = 12.0
rof = 5.0
pierce = 1
pellets = 1

[sub_resource type="Resource" id="WeaponLevelStats_l5"]
script = ExtResource("2_wls")
base_atk = 24.0
rof = 5.5
pierce = 2
pellets = 1

[resource]
script = ExtResource("1_wd")
id = &"W1_pistol"
display_name = "手枪"
form = 0
crit_rate = 0.05
crit_dmg = 2.0
hitbox_r = 6.0
unlock_rarity = 1
ballistic = {
    "proj_speed": 620.0, "range": 680.0, "spread_deg": 2.0,
    "pierce": 1, "pellets": 1, "spin_up_time": 0.0, "rof_hot": 0.0
}
upgrade_table = [SubResource("WeaponLevelStats_l1"), SubResource("WeaponLevelStats_l2"),
    SubResource("WeaponLevelStats_l3"), SubResource("WeaponLevelStats_l4"), SubResource("WeaponLevelStats_l5")]
threshold_traits = [
    {"threshold_id": &"TH_CRIT_SHARD", "metric": "crit_rate", "threshold": 0.6,
     "effect_id": &"EF_CRIT_SHARD", "params": {"ratio": 0.5}}
]
```

> 注：l2~l4 子资源省略展示；形态段以嵌套 Dictionary 存储（`ballistic/laser/homing/melee` 四个 `@export var xxx: Dictionary`），DataValidator 按 form 校验必填键——比 4 个平铺字段组更利于扩展第五形态（AC-02.1 仅新增键，不改类）。

### 3.2 EnemyData（敌人）

| 字段 | 类型 | 默认 | 校验 |
|---|---|---|---|
| `id` | StringName | `&""` | 非空唯一 |
| `display_name` | String | `""` | — |
| `behavior` | int（EnemyBehavior） | 0 | ∈ 枚举；M1 仅支持 CHASE/RANGED（其余告警降级为 CHASE） |
| `hp_base` | float | 72.0 | >0 |
| `spd_base` | float | 75.0 | [0, 600] |
| `dmg_base` | float | 8.0 | [0, 200]（接触伤害） |
| `exp_base` | float | 3.0 | ≥0 |
| `tp_cost` | float | 1.0 | >0 |
| `resist` | Array[float] | [0,0,0,0] | 每项 ∈ [-0.8, 0.8]（KIN/FIR/ICE/LTG，A3 §2.3） |
| `immune_mask` | int | 0 | 已知位组合（Boss 置 IMMUNE_FREEZE，F-17） |
| `tags` | int | 0 | TAG_ELITE/TAG_BOSS 位 |
| `hitbox_r` | float | 14.0 | (0, 64] |
| `ranged` | Dictionary | `{}` | behavior=RANGED 必填 {bullet_speed, fire_cd, bullet_atk_ratio, spread}；fire_cd>0 |
| `elite_mult` | Dictionary | `{}` | 精英模板 {hp:4.2, spd:0.92, dmg:1.5, exp:8.0}；仅 elite_template.tres 使用 |
| `boss` | Dictionary | `{}` | tags 含 BOSS 必填 {phases, bullet_patterns, summons, phase2_resist:0.2} |
| `gold_drop` | Dictionary | `{}` | {chance, min, max}（M3 商店） |

示例 .tres（E3 重甲）：

```
[gd_resource type="Resource" script_class="EnemyData" load_steps=2 format=3]

[ext_resource type="Script" path="res://scripts/core/data/resources/enemy_data.gd" id="1_ed"]

[resource]
script = ExtResource("1_ed")
id = &"E3_bastion"
display_name = "重甲"
behavior = 0
hp_base = 180.0
spd_base = 45.0
dmg_base = 15.0
exp_base = 10.0
tp_cost = 4.0
resist = [0.3, 0.0, 0.0, 0.0]
immune_mask = 0
tags = 0
hitbox_r = 22.0
ranged = {}
elite_mult = {}
boss = {}
gold_drop = {"chance": 0.25, "min": 15, "max": 20}
```

### 3.3 TraitData（词条：B_spec §2.5 注册契约）

| 字段 | 类型 | 默认 | 校验（L1 守门，非法 → 剔除） |
|---|---|---|---|
| `id` | StringName | `&""` | 非空唯一 |
| `display_name` / `description` | String | `""` | — |
| `pool` | int（PoolClass） | 0 | ∈ {ADD, MULT, LOCAL, MECH, ELEM} |
| `pool_id` | StringName | `&""` | ADD/MULT/LOCAL 类**必填**且 ∈ 封闭枚举注册表（add_atk/add_rof/…；frost_dmg/bounce_dmg/…）；MECH/ELEM 可空 |
| `effect_id` | StringName | `&""` | 必填且 ∈ builtin 处理器注册表（悬空 → 剔除，AC-13.3） |
| `value` | float | 0.0 | 数值字段（单层基础值 c_i；语义随 pool/effect） |
| `value2` | float | 0.0 | 次数值（如分裂夹角/继承比例） |
| `params` | Dictionary | `{}` | 效果参数包（effect_id 契约键） |
| `event_hooks` | Array[int] | `[]` | TraitEvent 集合；空 = 常驻 |
| `stack_max` | int | 1 | ≥1；卡牌流叠层过滤依据 |
| `decay_delta` | float | 0.0 | **pool=ADD 必填**且 ∈ (0, 0.92]（F-21 硬约束） |
| `cap_pool_p` | float | 0.0 | **pool=MULT 必填**且 >0（F-14 单区硬顶） |
| `cap_local` | float | 0.0 | pool=LOCAL 必填且 >0 |
| `inheritable` | bool | false | 分裂继承标记（分裂词条自身默认 false，E-01） |
| `proc_chance` | float | 1.0 | (0, 1] |
| `cooldown` | float | 0.0 | ≥0（词条触发冷却） |
| `rarity` | int | 0 | 白/蓝/紫/金 |
| `tags` | int | 0 | TAG 位（CURSE 等，F-23 诅咒净化通道占位） |
| `condition` | Dictionary | `{}` | MULT 类条件 {condition_id, params}（见 SynergyRuleData） |

示例 .tres（AFF_ATK_UP 加算）：

```
[gd_resource type="Resource" script_class="TraitData" load_steps=2 format=3]

[ext_resource type="Script" path="res://scripts/core/data/resources/trait_data.gd" id="1_td"]

[resource]
script = ExtResource("1_td")
id = &"AFF_ATK_UP"
display_name = "攻击强化"
description = "攻击力 +15%"
pool = 0
pool_id = &"add_atk"
effect_id = &"EF_STAT"
value = 0.15
value2 = 0.0
params = {"stat": "atk_pct"}
event_hooks = []
stack_max = 3
decay_delta = 0.85
cap_pool_p = 0.0
inheritable = false
proc_chance = 1.0
cooldown = 0.0
rarity = 0
tags = 0
condition = {}
```

### 3.4 RelicData（遗物：全局规则）

| 字段 | 类型 | 默认 | 校验 |
|---|---|---|---|
| `id` | StringName | `&""` | 非空唯一 |
| `display_name` / `description` | String | `""` | — |
| `rarity` | int | 3 | =金（统一）；每场每件唯一 |
| `listen_events` | Array[StringName] | `[]` | 每项 ∈ EventBus 事件名注册表（悬空 → 剔除，AC-13.3） |
| `effect_id` | StringName | `&""` | ∈ 遗物效果处理器注册表 |
| `params` | Dictionary | `{}` | 效果参数（处理器契约校验必填键） |
| `unique` | bool | true | 抽中后移出卡池 |

示例 .tres（REL_MIDAS 点金手）：

```
[gd_resource type="Resource" script_class="RelicData" load_steps=2 format=3]

[ext_resource type="Script" path="res://scripts/core/data/resources/relic_data.gd" id="1_rd"]

[resource]
script = ExtResource("1_rd")
id = &"REL_MIDAS"
display_name = "点金手"
description = "全部经验获取 +20%"
rarity = 3
listen_events = [&"xp_gained"]
effect_id = &"REL_EF_XP_MULT"
params = {"mult": 1.2}
unique = true
```

### 3.5 SynergyRuleData（独立乘区条件规则）

| 字段 | 类型 | 默认 | 校验 |
|---|---|---|---|
| `id` | StringName | `&""` | 非空唯一；= pool_id 的规则条目 |
| `pool_id` | StringName | `&""` | ∈ 乘区封闭枚举（frost_dmg / burn_dmg / bounce_dmg / pierce_dmg / fury_dmg / opening_dmg / elite_dmg / vuln …） |
| `condition_id` | int（ConditionId 枚举） | 8（NONE） | ∈ 枚举（封闭，新增需框架评审，A2 §1.9） |
| `condition_params` | Dictionary | `{}` | 条件参数（PIERCE_INDEX_GE→{min:2}；PLAYER_HP_BELOW→{pct:0.35}；TARGET_TAG_IN→{tags:[1,2]}） |
| `contribution_expr` | String | `"value"` | **建议求值方式**：不用运行时 `Expression` 解析（性能 + 注入安全）；实现为「`value`（常量）/ `"value * (ctx.pierce_index - 1)"` 两个白名单模板」→ 编译期映射到 ConditionId 绑定的内置求值函数（switch 分发）。`Expression` 类仅允许出现在开发期工具脚本 |
| `cap_pool_p` | float | 1.0 | >0 必填（F-14） |
| `priority` | int | 0 | 名额截断时的稳定排序破序键（同 (M_p−1) 降序时按 priority 决胜，保证确定性） |

示例 .tres（SYN_PIERCE_EVO 贯穿协鸣）：

```
[gd_resource type="Resource" script_class="SynergyRuleData" load_steps=2 format=3]

[ext_resource type="Script" path="res://scripts/core/data/resources/synergy_rule_data.gd" id="1_srd"]

[resource]
script = ExtResource("1_srd")
id = &"SYN_PIERCE_EVO"
pool_id = &"pierce_dmg"
condition_id = 5
condition_params = {"min": 2}
contribution_expr = "value * (ctx.pierce_index - 1)"
cap_pool_p = 1.6
priority = 0
```

### 3.6 WaveTableData（波次表）

| 字段 | 类型 | 默认 | 校验 |
|---|---|---|---|
| `id` | StringName | `&"main"` | 非空 |
| `entries` | Array[WaveEntryData] | [] | 每项 index 唯一连续（1~30）；缺失波 → 剔除该波 + 回退公式生成（降级不崩溃） |
| `endless` | Dictionary | `{}` | {tp_base:110, tp_growth:1.03, window_base:30, window_slope:0.2, window_cap:40, elite_mod:4, boss_mod:10} |
| `tp_formula` | Dictionary | `{}` | {base:14, slope:3.2, jitter:0.1, elite_wave_mult:1.25}（表缺失波的回退真源） |

WaveEntryData（嵌套）：`index:int`（>0）、`composition:Array[Dictionary]`（每项 {enemy_id, count}；enemy_id 悬空 → 剔除该敌条目+告警）、`tp_override:float`（≤0 = 用公式）、`window:float`（>0）、`events:Array[StringName]`（SHOP / UNLOCK_SLOT / BOSS 等）。

示例 .tres（节选）：

```
[gd_resource type="Resource" script_class="WaveTableData" load_steps=3 format=3]

[ext_resource type="Script" path="res://scripts/core/data/resources/wave_table_data.gd" id="1_wtd"]
[ext_resource type="Script" path="res://scripts/core/data/resources/wave_entry_data.gd" id="2_wed"]

[sub_resource type="Resource" id="WaveEntryData_w3"]
script = ExtResource("2_wed")
index = 3
composition = [{"enemy_id": &"E1_grunt", "count": 19}, {"enemy_id": &"E2_runner", "count": 4}]
tp_override = 23.8
window = 19.2
events = [&"UNLOCK_SLOT_2"]

[resource]
script = ExtResource("1_wtd")
id = &"main"
entries = [SubResource("WaveEntryData_w1"), SubResource("WaveEntryData_w2"), SubResource("WaveEntryData_w3")]
endless = {"tp_base": 110.0, "tp_growth": 1.03, "window_base": 30.0, "window_slope": 0.2,
    "window_cap": 40.0, "elite_mod": 4, "boss_mod": 10}
tp_formula = {"base": 14.0, "slope": 3.2, "jitter": 0.1, "elite_wave_mult": 1.25}
```

### 3.7 GameFeelConfig（顿帧/震屏/色差分级）

| 字段 | 类型 | 默认 | 校验 |
|---|---|---|---|
| `hit_stop_ms` | Array[int] | [0, 30, 50, 120] | 恰好 4 项（FeelLevel 索引）；每项 ∈ [0, 200] |
| `hit_stop_scale` | float | 0.05 | (0, 1) |
| `hit_stop_merge_ms` | int | 30 | >0（合并窗口，AC-15.2） |
| `shake_trauma` | Array[float] | [0.15, 0.4, 0.5, 1.0] | 4 项；每项 ∈ [0, 1] |
| `shake_max_offset_px` | float | 8.0 | (0, 32]（Q-12 上限） |
| `shake_max_rot_deg` | float | 1.5 | (0, 8] |
| `shake_decay_s` | float | 0.4 | (0, 2] |
| `ca_base_intensity` | float | 0.004 | >0（Q-12 色差起跳） |
| `ca_decay_s` | float | 0.15 | (0, 1] |
| `ca_level_mult` | Array[float] | [1.0, 2.0, 4.0, 6.0] | 4 项（分级放大） |
| `particle_max_emitters` | int | 64 | >0（AC-15.5） |
| `particle_priorities` | Dictionary | {KILL:4, CRIT:3, HIT:2, AMBIENT:1} | 值 ∈ [1, 5] |

示例 .tres：

```
[gd_resource type="Resource" script_class="GameFeelConfig" load_steps=2 format=3]

[ext_resource type="Script" path="res://scripts/core/data/resources/game_feel_config.gd" id="1_gfc"]

[resource]
script = ExtResource("1_gfc")
hit_stop_ms = [0, 30, 50, 120]
hit_stop_scale = 0.05
hit_stop_merge_ms = 30
shake_trauma = [0.15, 0.4, 0.5, 1.0]
shake_max_offset_px = 8.0
shake_max_rot_deg = 1.5
shake_decay_s = 0.4
ca_base_intensity = 0.004
ca_decay_s = 0.15
ca_level_mult = [1.0, 2.0, 4.0, 6.0]
particle_max_emitters = 64
particle_priorities = {"KILL": 4, "CRIT": 3, "HIT": 2, "AMBIENT": 1}
```

### 3.8 BalanceTables（全局常数，唯一 .tres）

| 字段 | 类型 | 默认 | 校验 |
|---|---|---|---|
| `res_logic: Vector2i` | Vector2i | (720, 1280) | F-01 裁定；错误 → 致命（拒绝启动） |
| `cap_prod` | float | 8.0 | F-16；∈ [2, 32] |
| `r_alarm_ratio` | float | 500.0 | ×500 告警线；>0 |
| `cap_mul_count` | int | 8 | 名额上限；∈ [4, 16] |
| `cap_proj_traits` | int | 12 | 单投射物词条；>0 |
| `flat_ratio_cap` | float | 0.5 | f_flat 比例钳制；∈ (0, 2] |
| `add_pool_caps` | Dictionary | {add_atk:2.0, add_rof:1.5, add_cdr:0.6, add_crit:1.0, add_critdmg:2.0} | F4 保险丝；每值 >0 |
| `cap_cdr_sum` | float | 0.6 | F-11 |
| `cap_rof_per_weapon` | float | 30.0 | 性能双护栏；>0 |
| `cap_crit_rate` | float | 1.0 | — |
| `decay_delta_max` | float | 0.92 | F-21 词条校验上限 |
| `split_max_generation` | int | 3 | E-01 三闸之一 |
| `split_max_children` | int | 8 | 三闸之二 |
| `split_inherit_ratio` | float | 0.5 | 逐代 ×0.5（Q-9） |
| `projectile_soft_limit` | int | 1500 | 软上限（丢弃+计数） |
| `projectile_hard_limit` | int | 2000 | 硬上限（回收最老） |
| `pool_prewarm` | Dictionary | {projectile:640, enemy:128, popup:80, particle:64, laser:12, xp:160} | **每值 >0（=0 → 致命拒绝启动）** |
| `frame_budget_ms` | float | 8.3 | §五.4 预算锚 |
| `contact_tick` | float | 0.6 | 受击无敌帧（F-35） |
| `pickup_radius` | float | 120.0 | 磁吸（Q-13） |
| `hp_growth_per_wave` | float | 1.12 | 敌成长核心锚 |
| `dmg_growth_per_wave` / `spd_growth_per_wave` / `exp_inflation_per_wave` | float | 1.06 / 0.008 / 1.085 | F-27 |
| `xp_curve` | Dictionary | {base:14, power:1.4} | >0 |
| `rarity_weights` | Dictionary | {WHITE:58, BLUE:30, PURPLE:10, GOLD:2} | 权重和 >0 |
| `category_weights` | Dictionary | {MASTERY:12, ADD:40, MULT:18, MECH:14, ELEM:10, RELIC:6} | 同上 |
| `cd_rxn` | float | 2.0 | 反应 CD（F-34） |
| `element_decay_lambda` | Array[float] | [0.35, 0.30, 0.40] | FIR/ICE/LTG 比例衰减 λ（F-22） |
| `element_states` | Dictionary | {burn:{...}, freeze:{...}, shock:{...}} | 状态参数（§2.10 契约键） |
| `reaction_table` | Dictionary | {RXN_FIR_ICE:{coef:2.0}, RXN_FIR_LTG:{coef:1.2, radius:90}, RXN_ICE_LTG:{resist_delta:-0.3, duration:6.0}} | 系数 >0 |
| `event_storm_threshold` | int | 128 | §六.4 |
| `data_version` | int | 1 | 与 version.cfg 不匹配 → 告警（AC-13.5） |

示例 .tres（节选）：

```
[gd_resource type="Resource" script_class="BalanceTables" load_steps=2 format=3]

[ext_resource type="Script" path="res://scripts/core/data/resources/balance_tables.gd" id="1_bt"]

[resource]
script = ExtResource("1_bt")
res_logic = Vector2i(720, 1280)
cap_prod = 8.0
r_alarm_ratio = 500.0
cap_mul_count = 8
cap_proj_traits = 12
flat_ratio_cap = 0.5
add_pool_caps = {"add_atk": 2.0, "add_rof": 1.5, "add_cdr": 0.6, "add_crit": 1.0, "add_critdmg": 2.0}
cap_cdr_sum = 0.6
cap_rof_per_weapon = 30.0
cap_crit_rate = 1.0
decay_delta_max = 0.92
split_max_generation = 3
split_max_children = 8
split_inherit_ratio = 0.5
projectile_soft_limit = 1500
projectile_hard_limit = 2000
pool_prewarm = {"projectile": 640, "enemy": 128, "popup": 80, "particle": 64, "laser": 12, "xp": 160}
frame_budget_ms = 8.3
contact_tick = 0.6
pickup_radius = 120.0
hp_growth_per_wave = 1.12
dmg_growth_per_wave = 1.06
spd_growth_per_wave = 0.008
exp_inflation_per_wave = 1.085
xp_curve = {"base": 14.0, "power": 1.4}
rarity_weights = {"WHITE": 58, "BLUE": 30, "PURPLE": 10, "GOLD": 2}
category_weights = {"MASTERY": 12, "ADD": 40, "MULT": 18, "MECH": 14, "ELEM": 10, "RELIC": 6}
cd_rxn = 2.0
element_decay_lambda = [0.35, 0.3, 0.4]
element_states = {"burn": {"dot_ratio": 0.15, "tick": 0.5, "duration": 3.0, "max_layers": 5},
    "freeze": {"chill_slow": 0.4, "chill_dur": 2.5, "freeze_dur": 1.2, "vuln_mult": 1.25, "vuln_dur": 3.0},
    "shock": {"chain_targets": 3, "chain_radius": 160, "chain_ratio": 0.35, "chain_depth": 2, "chain_decay": 0.6}}
reaction_table = {"RXN_FIR_ICE": {"coef": 2.0}, "RXN_FIR_LTG": {"coef": 1.2, "radius": 90.0},
    "RXN_ICE_LTG": {"resist_delta": -0.3, "duration": 6.0}}
event_storm_threshold = 128
data_version = 1
```

---

## 四、伤害结算管道（B_spec §2.3 九步 → 方法级调用序列）

### 4.1 契约说明

- **输入**：`DamageContext`（§2.5，B_spec §2.2 的实现级细化——`add_ids[]` 细化为 `add_entries`，因步骤 3 的衰减职责发生在管线内，需要层数与 δ 信息；`mult_pools[]/local_pools[]` 与 B_spec 完全一致）。
- **输出**：`DamageResult`（§2.5，跳字/遥测/GameFeel 共源）。
- **顺序不可重排**：九步顺序即护栏顺序（L5 幂等 → L2 衰减 → L3 结构钳制 → L4 总量封顶 → 审计广播）；同输入必同输出（配合固定 RNG 种子支撑模式 A/B/C 回归）。
- **幂等缓存**：键 = `int64` 位拼接 `(source_uid:20bit) << 44 | (target_uid:20bit) << 24 | (frame_stamp:24bit)`；UID/帧号超出位宽在 GameConst 分配器层面钳制（UID < 2^20，帧号回绕清零——120Hz 下 2^24 帧 ≈ 38.6 小时，一局安全）。缓存每帧 `begin_frame()` 清空。
- **死亡短路**：返回 `null` 表示"已丢弃"（死亡目标/幂等重复不产生新结果）；调用方（ProjectileBase）对 null 直接跳过后续。

### 4.2 九步调用序列（伪代码级）

```gdscript
func resolve(ctx: DamageContext) -> DamageResult:
    # 0. 入口防御（§六.4，先于九步，不改语义）：NaN/Inf/负 base_atk → sanitize + 计数
    if not _sanitize(ctx):
        return null

    # ① 幂等检查：(source_uid, target_uid, frame_stamp) 已结算 → 短路返回缓存结果
    var cached := _check_idempotent(ctx)
    if cached != null:
        _stats["dropped_dupe"] += 1
        return cached

    # ② 目标存活检查：dead → 丢弃 + 计数（E-06 死亡短路，AC-12.7）
    if not _target_alive(ctx):
        _stats["dropped_dead"] += 1
        return null

    var stack := ModifierStack.new()
    stack.audit = DamageAudit.new()

    # ③ Add 池聚合：同 ID 叠层过 F3 几何衰减 → 跨 ID 线性求和 → 负贡献（诅咒）全额不衰减 → F4 池钳
    _aggregate_add(ctx, stack)          # T(n) = δ×(1−δ^n)/(1−δ)；Σ ≤ cap_add_*

    # ④ Flat 加入：Σ_flat ≤ f_flat × base_atk 比例钳制（超限截断 + audit.clamped_flat）
    _apply_flat(ctx, stack)

    # ⑤ 乘区聚合（四层，顺序固定）：
    #    a. 聚合层：按 pool_id 分组 → 贡献加算合并（F6，多实例合法来源）
    #    b. 防御层：同 (pool_id, source_uid) 多条 → 去重取最大 + audit.dedup_defense（恒空为健康）
    #    c. 单区钳制：每区 agg ≤ cap_pool_p（截断 + 审计）
    #    d. 名额截断：按 (M_p − 1) 降序取 top-8（同值按 SynergyRuleData.priority 决胜）
    #    e. 整体钳制：∏ M_p ≤ cap_prod=8.0（min 截断 + audit.compressed，F9/F-16）
    _aggregate_mults(ctx, stack)

    # ⑥ Local 池独立聚合：∏ L_l（光束灼焦等），不入名额、不受 cap_prod，自有 cap_local（F-15）
    _aggregate_local(ctx, stack)

    # ⑦ 暴击掷骰：独立 RNG 流 Bernoulli(crit_chance)；C ∈ {1, crit_mult}
    #    排除项：hit_flags 含 HIT_NO_CRIT（DOT/反应）→ C = 1（A2 §1.7）
    var crit := _roll_crit(ctx)

    # —— 结果对象组装（A2 F1 展开顺序；先落四段中间量，⑧⑨继续写 result）——
    # S = base_atk × (1 + Σ_add) + flat_clamped            （面板段）
    # M = min(∏ M_p, 8.0)                                   （乘区段，钳后）
    # L = ∏ L_l                                              （私有段）
    # C = crit ? crit_mult : 1.0                             （暴击因子，最外层独立因子 F-12）
    var result := DamageResult.new()          # 落字段：panel_snapshot=S / mult_product=M / local_product=L / is_crit / element / source/target/frame / pos / audit
    _populate_result(ctx, stack, crit, result)            # ⑦b 中间量落字段（feel_level/popup_style 派生）

    # ⑧ 目标侧修正：V = (1 − resist[element]) × 状态修正（易伤已作为 vuln 乘区在⑤入池）
    _apply_target_side(ctx, stack, result)   # result.target_factor = V

    # ⑨ 终值钳制 + 审计遥测 + 广播（三段）：
    #    9a. raw = S × M × L × C × V → clamp(raw, 0, base_atk × r_alarm_ratio)（保险钳制）
    #        R_alarm 检查（抗性前口径）：S × M × L × C / base_atk > 500 → audit.alarm + 一局一次告警
    #    9b. result 落终字段（final_value/pool_breakdown…）
    #        killed 判定：target.take_result(result)（apply_damage → 死亡只执行一次）
    #    9c. _broadcast(result)：EventBus.emit_damage_resolved；alarm → EventBus.emit_damage_alarm
    _finalize(ctx, stack, result)
    _broadcast(result)
    _cache_result(ctx, result)               # 幂等缓存写入（本帧内重复请求命中①）
    return result
```

独立结算通道（F20/F21，不入乘区管线）：

```gdscript
func resolve_reaction(p_ctx: DamageContext) -> DamageResult:
    # 反应/DOT/连锁统一走此通道（ctx 由 ElementalSystem 预构造）：
    # D = χ_rxn × φ × S_snap（快照面板，不含乘区/Local/暴击）
    # 预设：hit_flags = HIT_IS_REACTION（→⑦ 跳过掷骰）；mult_pools/local_pools 为空
    # 上界：D ≤ R_rxn × S_snap（独立告警线）；结算成功 → reaction_triggered 事件
```

### 4.3 DamageResult 与事件广播清单

DamageResult 字段清单见 §2.5（跳字需要：`final_value / is_crit / popup_style / pos / target_uid`；遥测需要：`audit / pool_breakdown / mult_product / pool_count / frame_stamp`；GameFeel 需要：`feel_level / killed`；反应快照需要：`panel_snapshot`）。

**管道广播清单**（唯一广播点，禁止绕过）：

| 广播 | 触发条件 | 载荷要点 | 下游 |
|---|---|---|---|
| `EventBus.damage_resolved` | 每次成功结算（步骤 9c） | DamageResult 全量 | 跳字 / GameFeel / DebugStats / HUD 统计 / 遗物 |
| `EventBus.damage_alarm` | R_alarm 触发（一局一次/构筑） | DamageResult（audit.alarm=true） | DebugStats 告警计数 |
| `EventBus.reaction_triggered` | 反应独立结算成功 | rxn / pos / target_uid | GameFeel 质变级 / 跳字 / DebugStats |
| （间接）`EventBus.enemy_killed` | result.killed → `Enemy._on_died()` 一次性广播 | enemy 实例 | WaveDirector / Player / GameFeel / HUD / 遗物 |

### 4.4 单次结算的调用方时序（投射物命中路径，E-03 帧聚合）

```
ProjectileBase._check_collision()                       # 网格查询候选敌
  → for each target（帧内去重：hits_this_frame）
      _submit_hit(target)
        ① ctx = weapon.panel_snapshot 展开 + projectile 运行态（bounce/pierce/generation/hit_flags）
        ② ctx.mult_pools ← trait_stack.collect_mult_pools(tctx)   # 词条 ON_HIT 注入（条件自评）
        ③ _dispatch_event(ON_HIT, tctx)                          # 六事件派发点（挂载序）
        ④ result = damage_pipeline.resolve(ctx)                  # §4.2 九步
        ⑤ result != null → _on_settled：
             elemental.apply_attach(element, attach_value)       # 元素附着（§2.10）
             pierce_left > 0 → _dispatch_event(ON_PIERCE) + 继续飞行
             否则 → _recycle(PIERCE_DEPLETED)                    # 回收统一收束
             result.killed →（enemy 侧一次性死亡广播）
```

---

## 五、性能预案

### 5.1 池预热容量表（Boot 期完成，AC-14.2）

| 池 | 预热容量 | 运行软上限 | 硬上限 | 满池降级行为（§六.3） |
|---|---|---|---|---|
| ProjectilePool（玩家弹+敌弹共用） | 640 | 1500（全场投射物，软） | 2000 | 软：新弹请求丢弃 + 计数；硬：`force_recycle_oldest()` 强制回收最老（FORCED 路径） |
| EnemyPool | 128 | 120（同屏） | 150 | 生成排队（不丢弃，波次不卡死） |
| PopupPool | 80 | 80（同屏跳字） | 96 | 合并到目标已有跳字（merge） |
| ParticlePool | 64 | 64（同屏发射器） | 96 | 优先级裁剪（KILL > CRIT > HIT > AMBIENT） |
| LaserBeamPool | 12 | 16 | 24 | 拒绝新光束段 + chain_fused 计数 |
| XPPool | 160 | 240 | 320 | 合并为大面值碎片（数值守恒） |

> 预热容量口径：AC-01.2 负载场景（500 弹 + 100 敌 + 60 发射器 + 40 跳字）加 20~28% 余量；软/硬上限与 B_spec §1.2 一致。`instantiate()` 仅发生在池预热与容量内懒增长，运行期稳态计数为 0（DebugStats 断言）。

### 5.2 SpaceGrid 实现要点（Q-15）

1. **固定桶数组**：`_buckets: Array[Array]` 预分配（8 列 × 13 行 = 104 桶，覆盖 720×1280 世界 + ±192px 出屏余量），索引钳制防越界。无 Dictionary 哈希、无每帧分配。
2. **每帧重建 O(n)**：敌人按中心坐标插入单桶（n = 活跃敌数 ≈ 100）；清空走 `_occupied` 列表只清用过的桶（O(used)），不做全量 104 桶清空。
3. **查询半径**：`query_circle(pos, r)` 覆盖格数 = `ceil((r + max_target_radius) / 128)`，弹-敌常规判定为 3×3 = 9 桶；桶内候选再做精确距离判定（AABB 预筛 → 圆判定）。查询缓冲 `_query_buffer` 复用（零分配）。
4. **双网格**：`enemy_grid`（敌人，弹-敌碰撞主路径）+ `enemy_bullet_grid`（敌方弹，供 ArcSlash 消弹/OrbitField 格挡查询）；两格均在投射物阶段开头重建（用上一帧实体位置，确定性可复现）。
5. **附加用途**：HomingWeapon 索敌、折射寻的（`query_nearest`，250px 半径内 ≠ 原目标）、敌间分离力（10Hz 降频查询，E-10）。
6. **不走物理引擎**：弹-敌判定零 Area2D 回调（2000×100 = 20 万对/帧的 O(n²) 路径被消除）；物理层只保留玩家受击/拾取/敌接触等低频 Area2D。

### 5.3 弹幕渲染方案

**默认方案（M1/M2 落地）：Sprite2D 节点池 + 共享纹理自动合批**

- 全部投射物 Sprite2D 共享同一 `CompressedTexture2D`（单图集/同纹理），同一 material；Godot 2D 渲染器对同纹理+同材质的 sprite 自动合批，draw call 与弹数解耦。
- **禁用逐实例 shader**：弹体无独立 ShaderMaterial；受击闪白为敌人侧共享材质；色差是全屏后处理（CanvasLayer 顶层 ColorRect + `hint_screen_texture`），与弹体无关。
- 池化节点回收用 `visible = false` + `set_physics_process(false)`，不 `queue_free`。
- 体积放大词条用 `scale` 等比（Sprite2D + 自管 `hitbox_radius` 同乘，AC-08.1 判定/视觉比值恒定）。

**MultiMesh 升级路径（预留，默认关闭）**

- 升级动机：>1500 弹时节点遍历与变换传播开销成为瓶颈；MultiMesh 一次 draw 全量实例。
- **接口缝**：ProjectileBase 渲染与逻辑分离——池仍管理逻辑对象；`render_mode` 配置位（BalanceTables 预留）切换「Sprite2D 模式 / MultiMesh 同步模式」；后者在帧末将全部存活弹 transform/可见性写入一个 `MultiMeshInstance2D`（instance_count = 池容量，回收弹 scale=0）。
- 该路径仅做接口预留（§七 包 0 的池接口已按此设计：池与渲染解耦），M2 性能数据不达标时启动实验，不影响既有代码（AC-02.1 同款"仅新增"原则）。

### 5.4 帧预算分解（8.3ms @ 120Hz，500 弹 + 100 敌负载）

| 帧序阶段 | 目标 ms | 预算说明 |
|---|---|---|
| ① 输入 + 状态机 + 帧头（缓存清理/网格重建入口） | 0.1 | 常数开销 |
| ② 玩家 + 5 武器 tick（冷却/开火决策） | 0.6 | 射速 ≤30/s × 5 武器上界 |
| ③ SpaceGrid 双网格重建 | 0.3 | O(n) n=100 敌 + 敌弹 |
| ④ 投射物运动 + 碰撞查询 | 2.2 | 500 弹 × 9 桶扫描 + 距离精判；零分配（复用缓冲） |
| ⑤ 伤害结算 | 1.6 | 最坏口径 500 次 resolve/帧（含词条乘区注入） |
| ⑥ 敌人 AI + 元素 tick + 帧末反应检测 | 1.2 | 100 敌行为机 + 状态容器 + 分离力 10Hz |
| ⑦ 波次/生成节流 | 0.1 | 单帧 ≤8 生成 |
| ⑧ GameFeel + 粒子管理 | 0.5 | trauma/色差衰减 + 64 发射器管理 |
| ⑨ UI / 跳字 | 0.4 | 事件驱动刷新 + 80 跳字动画 |
| ⑩ 引擎提交 + GC 余量 | 0.3 | 逻辑总预算 |
| **合计（逻辑侧）** | **7.3** | 留 1.0ms 渲染管线余量 → 总预算 8.3ms |
| 渲染（引擎侧） | ≈1.0（含在余量） | 合批 draw call < 60；全屏色差 shader 开启时复测（AC-15.4） |

> 超预算处置：DebugStats 每帧分阶段采样（§5.5），P95 超线时按阶段定位：④超 → 弹数软闸收紧 / MultiMesh 实验启动；⑤超 → 结算条目护栏（§六.4 事件风暴同款告警）；渲染超 → 色差 shader 降级关闭开关（GameFeelConfig 预留 `ca_enabled`）。

### 5.5 性能埋点（DebugStats autoload，验收测量源）

```gdscript
# autoload/debug_stats.gd —— 注册名 DebugStats（release 构建剥离，A1 §3 口径）
extends Node

var _frame_times: Array[float] = []             # 环形缓冲语义（固定容量覆盖写，60s 逐帧序列 → P50/P95/P99）
var _stage_times: Dictionary = {}               # 帧序阶段名 → Array[float]（环形覆盖写，§5.4 预算对账）
var _counters: Dictionary = {}                  # 全部计数器（instantiate/free/池命中/结算/事件）

func begin_stage(p_stage: StringName) -> void:  # GameLoop 帧序各阶段计时入口
func end_stage(p_stage: StringName) -> void:
func count(p_key: StringName, p_delta: int = 1) -> void:   # 计数器通道（池/管线/总线共用）
func get_counter(p_key: StringName) -> int: 
func frame_report() -> Dictionary:              # {p50, p95, p99, stage_breakdown}（每 60 帧聚合）
func export_csv(p_path: String) -> void:        # 模式 B 回归与验收归档（CSV 导出）
func assert_zero_instantiations() -> bool:      # AC-14.1 断言（运行期实例化计数 = 0）
func assert_pools_clean() -> bool:              # AC-14.3 断言（池污染）
```

| 埋点 | 采集点 | 验收口径 |
|---|---|---|
| 帧时间 P50/P95/P99 | `_frame_times` 环形缓冲（60s 窗口） | AC-01.2：P95 < 8.3ms；AC-01.3：P95 < 16.6ms |
| 帧序阶段分解 | `begin_stage/end_stage`（§5.4 的 ①~⑩ 细分口径，比帧序 ①~⑧ 更细） | §5.4 预算对账（超线阶段定位） |
| 池命中率/丢弃数 | ObjectPool.stats() 聚合 | misses = 0（M1）；软闸触发有计数无崩溃 |
| 运行期实例化/free 计数 | ObjectPool 计数器 | AC-14.1 = 0（10 分钟 soak） |
| 结算次数/帧 | DamagePipeline._stats | 乘区审计指标源（A2 §2.5 全表） |
| 事件派发计数 | EventBus._dispatch_count | 风暴告警 + 订阅泄漏回归（E-12） |
| 乘区审计 | DamageAudit 聚合（compress/dedup/truncate/alarm） | dedup_defense = 0；alarm = 0；compress M1 = 0 |
| RSS 内存 | 30s 周期采样 | AC-01.3 增幅 < 3%；AC-01.5 < 400MB |

---

## 六、失败路径设计（fail-fast 三层防御）

### 6.1 层 1：参数校验（编辑期 + 构造期）

- **编辑期**：全部 .tres 字段用 `@export_range` / `@export_enum` 范围提示（负射速/0 池容量在编辑器内即标红）。
- **构造期**：`spawn()/setup()` 入口断言关键参数（null data / 负值 → `push_error` + 安全默认值），开发期 `assert()`（release 剥离）。
- 运行期不重复校验（信任内部契约，性能优先）。

### 6.2 层 2：启动校验与降级（.tres 缺失/字段非法，E-08）

```
Boot 序列（GameLoop._ready）：
  GameConfig._ready（最先）:
    ├─ version.cfg 不匹配 → 告警（不迁移，AC-13.5）
    ├─ global_constants.cfg 缺失键 → 默认值 + 告警（非致命）
    ├─ balance_tables.tres 缺失/字段非法：
    │    ├─ 致命集（res_logic 错 / pool_prewarm 任一 ≤0 / cap_prod ≤0）→ config_fatal
    │    │    → GameLoop 停在 BOOT，展示 boot_error.tscn 错误清单（拒绝启动）
    │    └─ 非致命 → 字段级回退默认值 + 告警
    └─ emit config_ready
  DataRegistry.load_all（manifest 顺序，目录扫描）:
    ├─ 单条 .tres 加载失败（文件损坏/字段非法/引用悬空）→ 剔除该条 + 错误清单（文件名+字段名，AC-13.2/13.3）
    │    例：WeaponData 引用不存在的 trait id → 剔除宿主武器卡；TraitData δ>0.92 → 剔除词条
    ├─ 波表条目缺失 → 剔除该波 + 回退 TP 公式生成（游戏可继续）
    └─ emit data_validated（report: {total, rejected, errors[]}）→ DebugStats/控制台
  池预热 → MENU
```

**原则**：内容数据（resources/）"剔除 + 清单"不崩溃；全局配置（data/）区分致命/非致命；**运行期零 .tres 加载**（全部启动期注入）。

### 6.3 层 3：运行时护栏

| 风险 | 护栏机制 | 落点 |
|---|---|---|
| **池满**（AC-14.4） | `acquire()` 返回 null → 调用方丢弃 + `pool_exhausted` 计数；单帧处理 < 0.1ms、无弹窗无尖刺 | ObjectPool / 各调用方 |
| **全场投射物软/硬上限** | 软 1500：新弹请求（含分裂/多重装填）丢弃 + 计数；硬 2000：`force_recycle_oldest()` 回收最老（FORCED 路径，走统一收束） | ProjectilePool |
| **分裂递归**（E-01） | 三重闸门：代数 ≤3（`generation` 递增检查）+ 单次子数 ≤8（`request_split` 拒绝）+ 全场软上限；`inheritable` 默认 false（分裂词条自身不继承） | ProjectileBase.request_split / TraitStack.copy_for_split |
| **词条链式反应**（M-10） | 派发深度 >3 熔断（`chain_fused` 事件 + 计数）；`in_dispatch` 重入保护位；`frame_triggered` 本帧已触发标记（E-03） | TraitStack.dispatch |
| **光束折射分叉** | 深度 >2 拒绝 + 计数（不出第 3 代射线，AC-04.3） | LaserWeapon._spawn_beam |
| **反应竞态**（E-07） | 帧末统一检测 + 固定优先级（碎裂>过载>超导）+ 一帧一反应 + cd_rxn=2s | ElementalSystem.detect_reactions |
| **同帧重入/死亡重复结算**（E-03/E-06） | 幂等键缓存（§4.1）+ 投射物帧聚合 `hits_this_frame` + `dead` 标志短路 | DamagePipeline / ProjectileBase / Enemy |
| **NaN/Inf/负数** | `_sanitize` 入口防御：`is_finite` 检查 base_atk/flat/各 contrib；负 base_atk → 0 + 计数；NaN/Inf → 丢弃该结算 + 告警计数（结算前 sanitize，§4.2 步骤 0） | DamagePipeline |
| **数值溢出** | 终值 clamp [0, base_atk×500]（保险钳制）+ R_alarm 一局一次告警（F-16 双闸） | DamagePipeline._finalize |
| **事件风暴** | 同事件同帧派发 >128 → 告警一次 + DebugStats 计数；`damage_resolved` >600/帧 告警（结算条目过多定位） | EventBus._track_dispatch |
| **跳字/粒子刷屏**（E-09/E-17） | 跳字 ≤80（超限合并）；粒子发射器 ≤64（优先级裁剪） | PopupManager / ParticleDirector |
| **死亡/升级竞态**（E-16） | GameLoop 单线程仲裁：同帧先处理 `player_died`（GAME_OVER 优先级最高），GameOver 状态下 level_up 请求丢弃 + 计数 | GameLoop.change_state |
| **池污染**（E-05） | 取出/归还双向 `_assert_clean`；清零后词条回调被断言拦截（E-04 契约：OnExpire → 清零 → 归还） | ObjectPool._assert_clean |
| **卡池耗尽**（E-14） | fallback 属性卡（+5% 攻击），界面永不空 | CardGenerator._fallback_stat_card |
| **空输入/极端输入**（E-15） | 单指针锁定；位置钳制活动区（下 40% 屏）；静止时自动开火持续 | Player.tick |

---

## 七、阶段 D 并行编码派发边界

### 7.1 派发总览（5 编码包 + 1 集成包）

```
包 0（基座，硬序最先，必须完成并合入后其余包才启动）
  EventBus / GameConfig / DebugStats / GameConst
  ObjectPool + 6 特化池 / SpaceGrid
  数据契约冻结件：DamageContext/Result/Audit/ModifierStack + 10 个 Resource 类
  DataRegistry / DataValidator + res://data 骨架配置
        │
        ├────────────► 包 1（结算管线，可立即并行）
        │                DamagePipeline 九步 + 独立结算通道 + 模式 A 公式回归
        │
        ├────────────► 包 2（实体基座，可立即并行）
        │                ProjectileBase/两子类 + Enemy/Spawner + Player + WaveDirector
        │                （对 DamagePipeline 用"透传桩"：ctx → 最小 result，接口同真件）
        │
        ▼（包 2 实体接口冻结后）
包 3（武器与词缀，与包 1/2 尾部并行）
  WeaponBase + 四形态 + LaserBeam/OrbitField/ArcSlash
  TraitBase/TraitStack/builtin 六家族 + ElementalSystem
        │
        ▼
包 4（表现与流程，与包 3 中后期并行）
  GameLoop 状态机/帧序 + GameFeel 三件 + HUD/跳字/Boss 条/结算屏 + 卡牌流
        │
        ▼（硬序最后）
集成包（收尾）：main.tscn 组装 + Boot 全链 + M1 验收压力场景 + soak/性能测试场景
```

**硬序依赖（不可违反）**：
1. **包 0 必须先行**：EventBus / GameConfig / ObjectPool / 数据契约是全部包的编译期依赖（B_spec 阶段 C 输入要求 #7 的落地）。
2. **包 3 依赖包 2 的实体接口**（ProjectileBase.spawn 参数字典契约、Enemy 生命周朽数据流）与包 1 的 `resolve()` 真实签名——两者以包 0 冻结的数据契约为准，接口先行冻结后允许并行。
3. **包 4 依赖包 0~3 的运行实例**，但其 UI 流可用桩武器先行（选卡流用假数据）。
4. **集成包最后**：全部包合入后组装验收。

### 7.2 各包明细

#### 包 0 · 基座（硬序先行）

| 项 | 内容 |
|---|---|
| 文件清单 | `autoload/event_bus.gd`、`autoload/game_config.gd`、`autoload/debug_stats.gd`、`scripts/core/game_const.gd`、`object_pool.gd` + `pools/*.gd`（6）、`space_grid.gd`、`damage/{damage_context, damage_result, damage_audit, modifier_stack}.gd`、`data/{data_registry, data_validator}.gd`、`data/resources/*.gd`（10）、`res://data/**` 骨架、`project.godot` autoload 注册 |
| 依赖包 | 无 |
| 集成点 | ① 数据契约（DamageContext/Result 字段集）= 包 1/2/3 的编译期接口，**冻结后不得单方变更**；② 事件名清单（§2.1 表）冻结；③ Resource schema（§三）冻结 = A3 填表与包 1~4 的共同契约 |
| 自测清单 | 池预热满容量/取出归还/满池丢弃+计数/清洁断言触发（AC-14.2/14.3 单元级）；SpaceGrid 插入-查询正确性（固定用例：边界/出屏/多桶半径）；EventBus 订阅/退订/风暴计数/订阅回落断言（E-12）；DataValidator 对故意注入的坏 .tres（负射速/δ>0.92/悬空引用/缺字段）输出含文件名+字段名的清单并剔除（AC-13.2/13.3 单元级）；1000 条假卡加载 < 1s（AC-13.4 骨架验证） |

#### 包 1 · 结算管线

| 项 | 内容 |
|---|---|
| 文件清单 | `scripts/core/damage/damage_pipeline.gd`、`tests/formula/test_formula_pipeline.gd`（模式 A）、`tests/mc/test_monte_carlo.gd`（模式 C） |
| 依赖包 | 包 0（数据契约 + GameConfig 护栏常数 + EventBus 广播） |
| 集成点 | `resolve(ctx) -> DamageResult` / `resolve_reaction()` 签名冻结；`begin_frame/end_frame` 挂入 GameLoop 帧序（包 4 集成）；RNG 流种子注入 API（模式 A/B 共用） |
| 自测清单 | **AC-12.1**：Base=100 / +20%+30%（异 ID 各 1 层）/ flat+10 / ×1.5×1.4 / 非暴击 → **336**；**AC-12.2**：防御层注入两条同 ID ×1.5 → **150** 而非 225；衰减不等式族（首层全额 / n≥2 严格递减 / T(5) ≤ 4.3c / δ=0.92 边界）；F4 池钳、单区 cap、名额 top-8（含 priority 决胜确定性）、F9 整体钳 8.0、R_alarm 保险钳制与一局一次告警；暴击固定种子复现；幂等/死亡短路/NaN sanitize；负贡献（诅咒）全额不衰减；反应独立结算快照口径；**同输入同输出确定性**（随机种子固定连跑 1000 次哈希一致） |

#### 包 2 · 实体基座

| 项 | 内容 |
|---|---|
| 文件清单 | `scripts/combat/projectile/{projectile_base, ballistic_projectile, homing_projectile}.gd`、`scripts/entities/enemy/enemy.gd`、`entities/wave/{wave_director, enemy_spawner}.gd`、`entities/player/{player, pickup}.gd`、`scenes/combat/**` 对应场景 |
| 依赖包 | 包 0（池/网格/契约）；**对 DamagePipeline 用透传桩**（ctx → 最小 result，接口与包 1 真件完全一致，合入即替换） |
| 集成点 | `ProjectileBase.spawn(params)` 参数字典契约（§2.7.1 注）冻结 = 包 3 武器侧构造器契约；`Enemy.take_result` 生命周朽数据流冻结；波表驱动接口（WaveTableData）对接 |
| 自测清单 | 六大事件派发顺序 = 挂载序（记录序测试词条，AC-07.2）；回收五路径全部收束到 `_recycle` 且 OnExpire → 清零 → 归还顺序断言（E-04）；帧聚合（同帧同目标一条，E-03）；穿透计数/反弹反射角镜像 < 2°（AC-03.3/10.1）；Homing 角速度 clamp/二段延时/重索敌 0.2s（AC-05.1/05.4）；波次 TP 公式与表驱动一致 + 单帧 ≤8 + 同屏 ≤120 排队（AC-16.3）；玩家相对拖动 + 边界钳制 + 无敌帧 contact_tick（Q-3/Q-6） |

#### 包 3 · 武器与词缀

| 项 | 内容 |
|---|---|
| 文件清单 | `scripts/combat/weapon/{weapon_base, ballistic_weapon, laser_weapon, laser_beam, homing_weapon}.gd`、`weapon/melee/{orbit_weapon, orbit_field, arc_slash}.gd`、`combat/trait/{trait_base, trait_stack, trait_context}.gd` + `builtin/*.gd`（7，含 TraitEffect 基类）、`combat/elemental/{elemental_system, elemental_state}.gd`、对应 `scenes/combat/{lasers, melee}` |
| 依赖包 | 包 0 + 包 1（真实管线）+ 包 2（实体接口） |
| 集成点 | `WeaponBase.setup(deps)` 注入包（pipeline/pool/grid）契约冻结 = 包 4 Player 组装点；TraitStack → DamageContext 注入通道（§4.4 时序）冻结；ElementalSystem.detect_reactions 挂入帧序⑤（包 4 集成） |
| 自测清单 | AC-02.1（Dummy 第五形态仅新增文件）；AC-02.2/02.3（参数重写 + 词条跨形态）；Ballistic 三条（AC-03.1~03.3）；Laser 四条（叠层 1 层/0.25s 上限 8、跳字 ≤15Hz、折射深度 ≤2 拒绝、池化零实例化，AC-04.1~04.4）；Homing 四条（AC-05.1~05.4）；Melee 三条（公转角速度、格挡消弹走 OnExpire、挥斩窗口 ±1°，AC-06.1~06.3）；Trait 链式深度 3 熔断 + 重入保护 + 词条状态独立（AC-07.1~07.4）；分裂三重闸门与继承（AC-09.1~09.5，代数 ≤3/单次 ≤8/软 1500）；元素五条（AC-11.1~11.5，含帧末优先级与 cd_rxn）；防崩坏三条（AC-12.3/12.4/12.6 用包 1 真管线复测） |

#### 包 4 · 表现与流程

| 项 | 内容 |
|---|---|
| 文件清单 | `scripts/loop/game_loop.gd`、`gamefeel/{game_feel_director, camera_shake, particle_director}.gd`、`ui/{hud, popup_manager, damage_popup, boss_bar, game_over_screen}.gd`、`cards/{card_generator, card_select_ui}.gd`、`shaders/**`、对应 `scenes/ui/**` |
| 依赖包 | 包 0~2 全量 + 包 3 中后期（武器实例）；选卡流前期可用桩武器 |
| 集成点 | GameLoop 帧序（§2.17）= 全部子系统 tick 的唯一编排点（集成包 0~3 的运行实例）；状态机仲裁规则（E-16）冻结；time_scale 唯一写入口；DebugStats 帧阶段采样埋点 |
| 自测清单 | GameFeel 五条（AC-15.1~15.5：顿帧 ≤1 帧生效/±1 帧恢复、30ms 合并不叠加、trauma 上限 8px+1.5°/0.4s 衰减、色差 0.004 起 0.15s 归零、粒子 ≤64 优先级裁剪）；顿帧期间 DOT/投射物冻结无跳变（E-11，time 一致性用例）；升级冻结（AC-16.2 投射物逐帧静止）；卡池 fallback（AC-16.4）；跳字合并窗口 0.12s + 同屏 80；完整一局链路（AC-16.1，含 GameOver 统计） |

#### 集成包（硬序最后）

| 项 | 内容 |
|---|---|
| 文件清单 | `scenes/main.tscn` 组装、Boot 全链（config → registry → prewarm → menu < 3s）、`tests/stress/{test_perf_500p100e, test_soak_10min}.gd`、`tests/sim/**`（模式 B）、`tests/runner/run_all.gd` |
| 依赖包 | 全部 |
| 集成点 | M1 验收矩阵执行：AC-01.1/01.2/01.4/01.5（性能预算）+ AC-14.1~14.4（池四条，10 分钟 soak 0 实例化）+ E-08/E-09/E-10 降级与网格碰撞压力验证 |
| 自测清单 | 500 弹+100 敌 60s 固定种子 P95 < 8.3ms / P99 < 10ms（release 模板）；2000 弹+150 敌 30s P95 < 16.6ms 且 RSS 增幅 < 3%；冷启动 < 3s；soak 无池污染断言失败、无报错日志 |

### 7.3 并行编排时间线（建议）

```
T0:  包 0（基座）────────────┐
T1:  ├─ 包 1（管线）────────┤
     └─ 包 2（实体）────────┤（与包 1 全程并行，桩管线）
T2:              包 3（武器/词缀/元素）（包 2 实体接口冻结后启动，与包 1 复测并行）
T3:                   包 4（表现/流程）（包 3 中后期启动，桩武器先行）
T4:                        集成包（全部合入 → M1 验收矩阵 → 冻结基线）
```

> 并行安全性来自三份"冻结契约"：**① 数据契约**（包 0 的 DamageContext/Result/Resource schema）、**② 实体接口**（包 2 的 spawn 参数字典与 Enemy 数据流）、**③ 帧序与事件清单**（包 0 的 EventBus 表 + 本文 §2.17 帧序）。任何契约变更必须回写本文档并同步全部在途包（架构师仲裁权）。

---

## 附录 A：B_spec 关键裁定 → 架构落点追溯表

| B_spec 裁定 | 架构落点 |
|---|---|
| F-01 720×1280 / canvas_items+keep | GameConfig（res_logic，致命校验）→ GameLoop Boot 应用 |
| F-10 主公式五段 | DamagePipeline 九步（§4.2）；段顺序即步序 |
| F-11 双层乘区合并 | `_aggregate_mults` 步骤 5a/5b（聚合层/防御层） |
| F-12 暴击最外层独立因子 | 步骤 7 独立掷骰，不进池不占名额；HIT_NO_CRIT 排除 |
| F-13 分裂继承面板快照比例 + inheritable 定义复制 | `WeaponBase.build_panel_snapshot` + `TraitStack.copy_for_split`（引用复制非深拷贝，E-13） |
| F-14 单区硬顶 cap_pool_p | TraitData 必填字段 + 步骤 5c |
| F-15 光束灼焦 Local 私有池 | `LaserBeam.scorch_layers` → ctx.local_pools → 步骤 6 |
| F-16 乘区段整体钳 8.0 + ×500 双闸 | 步骤 5e（F9）+ 步骤 9a（R_alarm）+ DamageAudit |
| F-17 immune_mask 免疫矩阵 | EnemyData.immune_mask → ElementalState（Boss 免疫定身） |
| F-18 敌 HP 指数 ×1.12 / TP 线性 | Enemy.spawn 波次缩放（F27 四曲线）/ WaveDirector TP 公式 |
| F-19 武器槽 5 解锁 | Player.unlocked_slots（Boss2 击杀提前 / w21 保底） |
| F-20 反应独立结算 | `resolve_reaction`（F21 快照通道） |
| F-21 加算几何衰减 δ≤0.92 | 步骤 3（F3）+ TraitData 校验 |
| F-22 元素 λ 比例衰减 | ElementalState.tick（λ 数组在 BalanceTables） |
| F-23 诅咒负贡献全额 | 步骤 3 分支（is_curse 不衰减） |
| Q-15 空间网格碰撞 | SpaceGrid（§5.2），物理层仅低频 Area2D |
| Q-16 玩家受击简化路径 | Player.take_contact_damage（不经管线） |
| M-10 链式深度 3 + 重入 | TraitStack.MAX_CHAIN_DEPTH=3 + in_dispatch |
| M-13 归还契约/池污染断言 | ObjectPool._assert_clean + 实例._reset_state |
| M-15 GameFeel 事件驱动分级 | GameFeelDirector 订阅四既有事件（无独立 gamefeel 事件） |
| E-01~E-17 全部边界风险 | §六.3 护栏表逐条落点 |

## 附录 B：待阶段 D 前最终确认的开放项（不阻塞派发）

1. `GameConst.next_uid()` 的 UID 位宽与幂等键位拼接（§4.1）在集成包实测帧号回绕行为——120Hz 下单局安全，超长 soak（>38h）需回绕清零验证。
2. MultiMesh 实验的启动判据（M2 性能数据 P95 > 8.3ms 且阶段④占超）与接口缝验证用例。
3. `element_decay_lambda`（FIR/ICE/LTG = 0.35/0.30/0.40）为架构侧建议初值，最终以 A3/模式 B 联调标定（稳态免疫线 G* = a/λ 校验）。
4. 敌弹网格与近战消弹的一帧延迟（§5.2-4）在手感验收中确认无感知；若有感知，将敌弹网格重建挪至武器阶段前（帧序微调需架构师仲裁）。
