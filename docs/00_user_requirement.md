# Infinite Fission — 用户原始需求（基准文档）

> 本文件为用户原始需求的逐字存档，是所有后续设计/实现/验收的最终依据。
> 工作区：`/Users/genmer/Documents/Codes/Agent/Infinite Fission`（全新绿地项目，Godot 4.x / GDScript）

---

## 游戏定位

竖屏高刷 Roguelike 弹幕防御游戏，名字：**Infinite Fission**。
目标：高扩展性、高性能（目标 120Hz）、极具视觉反馈的竖屏 Roguelike 射击塔防游戏核心系统。
核心逻辑：基于**多乘区与高度模块化的词缀协同（Synergy）系统**，支持海量弹幕与质变构筑，**绝不能让数值在吃一两个基础 Buff 后直接崩坏**。

## 1. 武器形态与弹道基底架构（Weapon & Projectile System）

设计统一的 `WeaponBase` 和 `ProjectileBase` 抽象基类，支持四大形态及参数重写：

- **普通弹道类（Ballistic）**：如手枪、加特林、霰弹枪，具备基础初速度、射程、散射角与穿透计数。
- **持续光束类（Laser/Beam）**：射线检测机制（RayCast2D），支持持续照射叠加层数、接触点高频跳字与折射分叉。
- **智能追踪类（Homing Missile）**：具备角速度寻敌转向插值、加速度推进、碰撞范围爆炸与二段延时启动。
- **近战环绕/挥斩类（Melee/Orbit）**：环绕本体旋转的浮游力场或固定角度周期性弧形挥斩，具备击退、消弹或格挡判定。

## 2. 机制正交叠加系统（Universal Trait & Modifier Engine）

所有投射物与武器必须原生支持多维度的词缀链式反应（Chained Modifiers）。
每个投射物对象维护一个 Trait 列表，在发生生命周期事件（`OnSpawn, OnTick, OnHit, OnPierce, OnBounce, OnExpire`）时触发：

- **体积极限（Size Scaling）**：碰撞盒与精灵等比放大，结合"体积极大时附加额外冲击波/压制范围"的质变词条。
- **几何分裂（Fractal Split）**：在击中、穿透耗尽或消亡时，以特定夹角/环形向外分裂出次级投射物（继承一定比例的攻击力与特定词缀）。
- **边界与目标反弹（Bounce & Ricochet）**：撞击屏幕边缘或敌方单位后寻找新目标折射，反弹后附加增伤乘区。
- **属性附着与反应（Elemental Reaction）**：点燃（DOT）、冰冻（减速/易伤）、感电（连锁闪电传导），支持元素混合触发独立引爆。

## 3. 数值与多乘区计算公式（Damage Formula）

伤害计算必须严格区分加算池与独立乘算池，防止单一词缀造成数值失衡：

$$\text{Final Damage} = \Big(\text{Base ATK} \times (1 + \sum \text{Additive Buffs}) + \text{Flat Bonus}\Big) \times \prod (1 + \text{Independent Multipliers}) \times \text{Crit Factor}$$

- **加算池（Additive）**：普通攻击力+15%、基础射速提升等平庸词条，随层数递减边际效应。
- **独立乘区（Synergy Multipliers）**：特定条件触发（如：对冰冻目标伤害 ×1.5、反弹后下一次命中伤害 ×1.4、每穿透一个目标伤害 ×1.2）。

## 4. 代码结构与数据驱动要求

- **数据解耦**：使用 Godot 的 Custom Resource（如 `WeaponData.tres, RelicData.tres, SynergyRule.tres`）定义所有卡牌、遗物与武器升级路线，方便后续无缝扩展成百上千种升级。
- **对象池优化（Object Pooling）**：实现高性能 2D 弹幕对象池管理，杜绝运行时的频繁 `instantiate()` 和 `queue_free()`，保证低端移动端也能跑满高帧率。
- **视觉打击感接口（Game Feel Hook）**：预留击中顿帧（Hit-stop）微秒级时间缩放。暴击/质变触发时的全屏轻微震动（Camera Shake）与色差（Chromatic Aberration）着色器触发接口。统一的 GPUParticles2D 粒子生成管理。

## 交付顺序要求

首先输出：该系统完整的**模块依赖关系设计**、核心架构**伪代码/类定义**，以及最关键的 **Resource 数据结构与伤害结算管道**。

## 用户补充指示

- 项目全权交给 AI 团队，尽量做完善，设计可以设计好几天，不急，慢工出细活。
- 可以并行派发子任务。
- 需求分析、数值框架、具体数字设计可并发跑，然后融合。
- 现阶段即游戏**核心系统**（含可运行的游戏闭环验证核心手感与数值），完整内容（美术/关卡/存档等）后续迭代。
