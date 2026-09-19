# Evolution State
> 由 /self-evolution 维护的唯一事实来源。每轮开始读，结束前更新并提交。

## 项目档案
- 一句话：竖屏单手割草 roguelike（Godot 4.3），晴空糖果美术，难度三档 × 成对抉择构筑深度
- 技术栈/入口：GDScript；scenes/main.tscn → GameLoop（scripts/loop/game_loop.gd 编排一切）
- 运行：`../tools/Godot_v4.3-stable_win64_console.exe --path .`（已验证可跑）
- 检查：25 套件 headless（tests/runner/test_*.gd）+ verify_feedback 472 断言（无 lint）
- 核心体验：割草爽感 + 局内构筑滚雪球 + 走位反制（telegraph/盾面/法术圈走位有解）
- 红线与坑：E-04~E-08 池化清零契约；.tres 注册表禁运行期落改（深拷贝）；测试直调无 add_child
  （池化实体本就是池节点子节点）；-s 入口两文件模式；写测试输出到日志文件防管道挂死

## 当前焦点
用户指令：玩法/逻辑/画面/打击感/特效/性能全维度探索 10 轮，不停

## Backlog
<!-- 格式：- [Pn][类型][状态] ID: 标题 — 一行描述 -->
- [P1][feature][todo] E1: 难度风险回报闭环 — 困难/地狱金币与经验全局加成（×1.5/×2.5）+ HUD 显示
- [P1][feature][todo] E2: 复活演出 — 复活瞬间全屏光圈冲击 + 「复活！」跳字 + 无敌余晖（现静默满血）
- [P1][effect][todo] E3: 升级瞬间波纹 — 选卡确认回 PLAYING 时以玩家为心的清爽扩散环（Level-up burst）
- [P2][perf][todo] E4: 彩纸 GPUParticles 化排查 — 90 Sprite2D 逐帧 _process vs 单发射器（先测后改）
- [P2][feature][todo] E5: 首遇新怪提示条 — E25~E30 首次登场屏幕上方机制一句话（图鉴行复用）
- [P2][effect][todo] E6: Boss 血条打击反馈 — 受击端闪 + 段位刻度（当前静态条）
- [P3][perf][todo] E7: enemy_grid rebuild 频率审查 — 每帧全量 rebuild vs 增量（先 profile）
- [P3][effect][todo] E8: 地狱难度画面氛围 — 云层红移 tint + 地图名后缀已有（补氛围）

## 验收记录
- E1: ① 困难/地狱局金币·经验拾取实测 ×1.5/×2.5 ② HUD 或结算可见加成来源 ③ 测试断言乘区
- E2: ① 复活触发有可视觉确认的演出（截图/渲染探针）② 不阻塞死亡→复活链路时序 ③ 测试仍绿
- E3: ① 升级确认后波纹可见且 ≤0.5s 自清 ② 粒子/绘制零每帧分配 ③ 回归绿

## 决策记录
- 2026-09-20 自主进化 10 轮启动；每轮一任务，实现+真实验证+提交；state.md 并入每轮提交

## Round Log
- R0 2026-09-20 初始化 state（待办列表已清：R72 三片 5ddfeca/8ec0c3a/fb0e822 全推送）
