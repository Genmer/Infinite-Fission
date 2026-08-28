# ⚡ INFINITE FISSION · 开发进度与交接文档（PROGRESS）

> **本文档是跨工具/跨会话交接的唯一入口。新会话/新工具接手后：先读完本文 → 按 §5「下一步行动」顺序执行。**
> 最后更新：2026-08-28 ｜ 更新人：主控 Agent（TRAE 会话，因工具迁移中断）
> 远程仓库：`https://github.com/Genmer/Infinite-Fission.git`（main 分支）

---

## 1. 项目一句话

竖屏高刷（120Hz）Roguelike 弹幕防御游戏，Godot 4.3 / GDScript。核心是**多乘区伤害公式 + 词缀协同（Synergy）系统 + 对象池海量弹幕**。当前交付物 = 可运行的游戏核心系统（M1 战斗闭环 + M2 词缀协同 + M3 卡牌数值的大部分）。

## 2. 当前状态一览（快照）

| 阶段 | 内容 | 状态 |
|---|---|---|
| A 需求/数值/数字（3 路并行） | A1 需求分析 / A2 数值框架 / A3 具体数值表 | ✅ 完成，已融合 |
| B 融合规格书 | 36 项裁定固化为单一事实源 | ✅ `docs/B_spec.md` |
| C 架构设计 | 19 模块/类骨架/Resource schema/九步管线/5 编码包派发边界 | ✅ `docs/C_architecture.md`（~2190 行） |
| D-包0 基座 | EventBus/池×6/SpaceGrid/ModifierStack/10 Resource 类/启动校验 | ✅ 自测 129/129 PASS |
| D-包1 伤害结算管线 | 九步 resolve/反应通道/幂等/审计/固定种子 | ✅ 自测 108/108 PASS |
| D-包2 实体基座 | ProjectileBase 六事件/Enemy/Player/WaveDirector/透传桩 | ✅ 自测 140/140 PASS |
| **D-包3 武器/词缀/元素/内容** | 四形态武器+TraitStack+内置词条+ElementalSystem | ⚠️ **编码中断点（见 §4）** |
| D-包4 GameLoop/GameFeel/UI/卡牌流 | 主循环/打击感/HUD/三选一 | ⬜ 未开始 |
| D-集成包 | main.tscn 组装/全链验收/压力 soak | ⬜ 未开始 |
| E 审查+测试（并行） | 独立代码审查 + 运行验证 | ⬜ 未开始 |
| F 交付报告 | 汇总判定+关键决策清单 | ⬜ 未开始 |

**仓库当前可编译（0 解析错误），回归 377/377 全 PASS（129+108+140）。**

## 3. 开发流水线（自创，非标准流水线）

```
阶段A（3 路并发：需求/数值框架/具体数字） → 自查 →
阶段B（主控融合成 B_spec 单一事实源） →
阶段C（架构师子代理 → C_architecture.md） → 主控自查 →
阶段D（编码，包间按依赖分波）：
    波1: 包0 基座（串行先行）
    波2: 包1 ∥ 包2（并行）
    波3: 包3（依赖 0/1/2）
    波4: 包4（依赖 0/2）—— 理论上可与包3 并行
    波5: 集成包（依赖全部）
阶段E（审查 ∥ 测试 并行把关） → 阶段F（汇总交付）
```
每阶段强制自查；子代理只写自己包的文件，跨包契约全部冻结在 C_architecture.md。

## 4. ⚠️ 包 3 中断点（最重要的交接信息）

**磁盘上已有的包 3 文件（代码已写完，通过编译）：**
- `scripts/combat/weapon/`：weapon_base.gd、ballistic_weapon.gd、homing_weapon.gd、laser_weapon.gd、laser_beam.gd、melee/{orbit_weapon.gd, orbit_field.gd, arc_slash.gd}
- `scripts/combat/trait/`：trait_base.gd、trait_context.gd、trait_stack.gd、synergy_rules.gd、builtin/（trait_effect.gd + stat/size/fractal/bounce/elemental/mech 六类内置词条）
- `scripts/combat/elemental/`：elemental_system.gd、elemental_state.gd
- `scenes/combat/lasers/laser_beam.tscn`

**包 3 缺失（下一个会话要补的）：**
1. `tests/runner/test_pkg3.gd`（+cases）——包 3 无自测。测试要点：四形态开火参数重写、TraitStack 挂载/复制/分裂继承（copy_for_split）、六事件派发顺序=挂载序、链式深度上限 3、体积极限质变阈值（≥3.0× 触发冲击波）、分裂三重闸门（代数≤3/单次≤8/全场软 1500）、反弹增伤乘区、点燃/冰冻/感电附着-衰减-反应（碎裂×2.0/过载 120%ATK/超导全抗−30%、反应 CD 2s）、激光叠层与折射分叉深度 2、环绕周期弧斩/消弹格挡
2. **内容 .tres 全部未建**：`resources/` 下 9 把武器、28 词条、11 遗物、敌表/波表等（数值真源 = `docs/analysis/A3_numbers.md`；schema = C_architecture §三；启动校验会自动剔除坏数据不崩溃）
3. 包 3 收紧位（包 2 代码里已用注释标明恢复点）：`_build_trait_ctx` 改构 TraitContext 实例、trait_stack/elemental/武器数组 duck-typing 收紧、`Player.add_weapon(data)` 形态工厂
4. 遗留小项：R_rxn 反应伤害独立告警线字段（现用 ×500 兜底）、易伤注入去重（管线注释有说明）、is_first_hit_of_wave 接线、敌间分离力 E-10、RANGED 敌弹池注入

**本次中断前的最后一笔修复**：`trait_effect_size.gd` L42 `var atk :=` → `var atk: float =`（Dictionary.get 返回 Variant 无法推断类型），已验证编译通过。

## 5. 下一步行动（按序执行）

1. **跑基线确认**：`bash` 下执行 §7 测试命令，确认 377 PASS 基线无损
2. **补包 3 自测**：写 `tests/runner/test_pkg3.gd`（要点见 §4.1），跑通全 PASS
3. **补包 3 内容 .tres**：按 A3 数值 + C_architecture schema 建全部资源文件；用 DataRegistry 启动加载验证 0 剔除
4. **收紧 duck-typing 恢复点**（包 2/包 0 代码内注释标明处）
5. **派发包 4**：GameLoop（状态机 Boot→Menu→Playing→Paused→LevelUp→GameOver、固定帧序①~⑧、game_delta 双时间通道——顿帧不写 Engine.time_scale！）、GameFeelDirector（顿帧/震屏 trauma/色差/粒子池）、HUD/跳字/三选一卡牌 UI
6. **集成包**：main.tscn 组装、切真管线（默认已是真件，桩仅 debug）、压力测试（500 弹+100 敌 P95<8.3ms、10 分钟 soak instantiate=0）、AC 验收矩阵（A1 §3）
7. **阶段 E**：并行派发独立代码审查 + 运行测试两路子代理
8. **阶段 F**：交付报告（含关键决策清单）
9. 每完成一个包：**git commit + push**（纪律！）

## 6. 关键文档地图（全部在工作区 docs/）

| 文档 | 作用 |
|---|---|
| `docs/00_user_requirement.md` | 用户原始需求（最终依据，一切冲突以它为准） |
| `docs/B_spec.md` | **单一事实源**：36 项融合裁定 + 全局常量 + 伤害管线契约 + 里程碑验收 |
| `docs/C_architecture.md` | **架构真源**：19 模块依赖图、类骨架签名、8 类 Resource schema、九步管线映射、性能预案、失败路径、5 编码包派发边界（§七） |
| `docs/analysis/A1_requirements.md` | 需求分析：M-01~M-19 模块清单、60+ 条可执行验收 AC、边界风险 E-01~E-17 |
| `docs/analysis/A2_numeric_framework.md` | 数值框架：公式 F1~F29、五层防崩护栏 |
| `docs/analysis/A3_numbers.md` | **数字真源**：9 武器/28 词条/11 遗物/敌表/波表/掉卡规则 |
| `docs/briefs/` | 各子代理派发单（过程档案） |

## 7. 环境与测试命令

- **Godot 二进制**：`/Users/genmer/Documents/Codes/Tools/godot/Godot.app/Contents/MacOS/Godot`（4.3-stable universal，已装好）
- 导入：`"$G" --headless --path "<项目根>" --import`
- 跑测试：`"$G" --headless --path "<项目根>" -s tests/runner/test_pkg0.gd`（pkg1/pkg2 同理）
- 注意：`-s` 模式下入口脚本编译早于 autoload 注册，测试用「入口引导 + 运行时 load 用例体」两段式（pkg0/pkg1/pkg2 都是这个模式，新测试照抄）
- 当前基线：**pkg0 129 / pkg1 108 / pkg2 140，全 PASS**

## 8. 冻结契约速查（跨包接口，改动需全包评估）

1. **spawn(params) 参数字典**（武器→投射物）：基础键 velocity/lifetime/pierce/bounces/hitbox_radius/element/attach_value/generation/weapon_uid/panel_snapshot/trait_stack/team；Homing 追加 8 键（target_uid/turn_rate/speed_init/speed_max/accel/arm_delay/blast_radius/blast_falloff）；完整定义见包 2 交付报告与 projectile_base.gd 头注释
2. **DamagePipeline 接口**：`resolve(ctx)->DamageResult`（九步）/ `resolve_reaction(snapshot_atk, coefficient, ctx)` / `begin_frame()/end_frame()` / `set_rng_seed()`；透传桩 `damage_pipeline_stub.gd` 同接口，`get_pipeline()` 工厂自动切换
3. **六大生命周期事件**：OnSpawn/OnTick/OnHit/OnPierce/OnBounce/OnExpire，派发顺序=挂载顺序；回收五路径统一收束 `_recycle`（OnExpire→清零→归还，顺序不可变）
4. **池 API**：`acquire()/release(node: Node)`，特化池收窄返回值；满池丢弃+计数，不阻塞
5. **SpaceGrid**：`rebuild()/query_circle()/query_nearest()/query_arc()`，128px 桶，弹-敌碰撞主路径（不用 Area2D 回调）
6. **数值红线**：乘区段整体钳 8.0、×500 保险钳+一局一次告警、δ≤0.92、链式深度≤3、分裂代数≤3/单次≤8/软 1500 硬 2000、单武器射速≤30/s
7. **顿帧实现**：GameLoop 手动 `game_delta = raw × time_scale` 双时间通道，**禁止写 Engine.time_scale**（架构 §2.17 裁定）

## 9. 工程铁律（全程有效）

- 不修改 `docs/` 下任何文件；发现文档矛盾以 C_architecture > B_spec > 用户需求链裁决并记录
- GDScript 静态类型全覆盖；无 TODO 桩；Godot 4.3 API（无 abstract/无泛型/无类型化 Dictionary）；autoload 不声明 class_name
- 窄参数覆写非法（仅返回值协变）；`Dictionary.get()` 返回 Variant 需显式类型标注（本次中断就是它）
- 不用外部插件；美术全用程序化占位（纯色/PrimitiveShape），正式美术后续迭代
- 测试全绿才允许合入下一包；每包完成必须 git commit + push

## 10. Git 约定

- 远程：`origin = https://github.com/Genmer/Infinite-Fission.git`，主分支 `main`
- `.gitignore`：`.godot/`、`.DS_Store`（Godot 导入缓存不入库）
- 提交信息格式：`<包号>: <一句话>`（如 `pkg3: weapon/trait/elemental core + builtin traits`）
