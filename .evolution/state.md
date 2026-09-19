# Evolution State
> 由 /self-evolution 维护的唯一事实来源。每轮开始读，结束前更新并提交。

## 项目档案
- 一句话：竖屏单手割草 roguelike（Godot 4.3），晴空糖果美术，难度三档 × 成对抉择构筑深度
- 技术栈/入口：GDScript；scenes/main.tscn → GameLoop（scripts/loop/game_loop.gd 编排一切）
- 运行：`../tools/Godot_v4.3-stable_win64_console.exe --path .`（已验证可跑）
- 检查：24 套件 headless（tests/runner/test_*.gd）+ verify_feedback 508 断言（无 lint）
- 核心体验：割草爽感 + 局内构筑滚雪球 + 走位反制（telegraph/盾面/法术圈走位有解）
- 红线与坑：E-04~E-08 池化清零契约；.tres 注册表禁运行期落改（深拷贝）；测试直调无 add_child
  （池化实体本就是池节点子节点）；-s 入口两文件模式；写测试输出到日志文件防管道挂死

## 当前焦点
用户指令：玩法/逻辑/画面/打击感/特效/性能全维度探索 10 轮，不停

## Backlog
<!-- 格式：- [Pn][类型][状态] ID: 标题 — 一行描述 -->
- [P3][perf][skip] F1: _collect_enemy_bullets 快照 O(总弹) 扫描 — 评估后放弃：反弹盾（E27）翻转 team 破坏池侧计数不变量，收益小风险大
- [P3][effect][done] F2: 玩家受击方向指示 — HurtIndicator 双弧红光（4cd8af0）
- [P3][feature][done] F3: 成对抉择行内提示 — 「⇄ 点这张会同时带走同一行另一张」（后续 G 批提交内）

## 验收记录
- E1: ① 困难/地狱局金币·经验拾取实测 ×1.5/×2.5 ② HUD 或结算可见加成来源 ③ 测试断言乘区
- E2: ① 复活触发有可视觉确认的演出（截图/渲染探针）② 不阻塞死亡→复活链路时序 ③ 测试仍绿
- E3: ① 升级确认后波纹可见且 ≤0.5s 自清 ② 粒子/绘制零每帧分配 ③ 回归绿

## 决策记录
- 2026-09-20 自主进化 10 轮启动；每轮一任务，实现+真实验证+提交；state.md 并入每轮提交

## Round Log
- R0 2026-09-20 初始化 state（待办列表已清：R72 三片 5ddfeca/8ec0c3a/fb0e822 全推送）
- G1 2026-09-19 连杀音调爬升（sfx pitch ×combo 1.0→1.5 钳制）+ G5 元素死亡迸色（DeathPop 按 F/I/L 主元素染色）（af70156）
- G2 2026-09-19 F2 受击方向双弧指示 HurtIndicator + F3 双选行内提示 + E11 图鉴「普/困/狱」三难度记录列（同批提交）
- G3 2026-09-19 W10 回旋刃新武器：出程指数减速→翻转→回程加速返航双程伤害；金色新月刃贴图+自旋；L5 双刃齐掷；图鉴 icon；verify 508/508
