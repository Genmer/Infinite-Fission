#ifndef FISSION_SPACE_GRID_NATIVE_H
#define FISSION_SPACE_GRID_NATIVE_H

#include <godot_cpp/classes/ref_counted.hpp>
#include <godot_cpp/variant/packed_int32_array.hpp>
#include <godot_cpp/variant/packed_vector2_array.hpp>
#include <godot_cpp/variant/vector2.hpp>

#include <vector>

namespace godot {

// R239 原生第一刀（修轮 v2）：SpaceGrid.query_circle_snap 的 C++ 等价实现——**只算几何、零持久对象引用**。
//
// 桥接设计（详见 docs/qa/2026-10-07-R239-原生第一刀-报告.md §9 修轮）：
//   GDScript SpaceGrid 在 rebuild/insert 期同步维护"原生镜像"（_nat_cells 插入序 cell
//   索引 + _nat_pos 平行位置数组），首次原生查询前一次性喂入 feed_snapshot——本侧只存
//   几何（CSR 桶前缀+散布+位置 SoA），**不存任何 Object*/Array 实体引用**（v1 的
//   snap_items 成员已整体移除）。查询两个口：
//     · query_circle_snap_nodes(items, pos, radius)——生产口：items 由调用方**每次调用
//       传入**（引擎 Array COW 共享，本侧零持久持有；调用返回即释放），命中索引就地
//       从 items 取实体写入成员类型化缓冲直返（零逐命中 GDScript 解析→保住 ≥3× 门）；
//       护栏：items.size() 必须等于快照条目数（不等=调用方失配 → 返回空，绝不越界）。
//     · query_circle_snap_indices(pos, radius)——纯几何诊断口：返回 PackedInt32Array
//       快照索引（同源同序），供等价对拍/后续 id 化消费；不经手对象。
//   C++ 侧对象生命周期窗口 = 单次同步调用内（无跨帧持有），v1 崩溃面（空喂残留 CSR
//   前缀 → 越界读已清空数组）已按根因修复：空喂同样全量复位桶前缀 + 查询入口不变量闸。
//
// 修轮根因（v1 崩溃 0xC0000005 实录）：feed_snapshot 对空喂（n<=0）早退时**不复位
//   bucket_off**，而 bucket_flat/snap_* 已清空——下一查询按陈旧前缀扫描（k ∈ 旧桶区间），
//   越界读已清空数组 → 脏 Variant 索引 → 访问违例。真实负载必现路径：敌全灭/回池 →
//   空 rebuild（镜像清空）→ 下一帧弹体照常查询（r235 ④ 空网格段 / 全量电池 4 套件）。
//
// 等价口径（与 GDScript 实现逐位对齐，R239 等价性测试实证）：
//   · reach = maxf(radius, 0.0) + max_entity_radius 全 double 域（实测锚：GDScript
//     maxf 为 double 原生，无 float32 往返）；radius 参数绑定为 double（Variant FLOAT
//     原样透传，不做边界 float32 截断）。
//   · 覆盖格与 _cells_in_range 同式同序：((pos.x ± reach) - origin.x) / 128.0 在
//     double 域计算 → 向零截断（GDScript int() 语义）→ clampi（min>max 时 max 胜出）
//     → 行主序扫描。
//   · 距离精判 = Vector2.distance_squared_to 同式：(sx-px)²+(sy-py)² float32 域
//     （real_t=float；SConstruct -ffp-contract=off 禁 FMA 收缩），升 double 与
//     reach_sq 比较。
//   · 候选序 = 格行主序 × 桶内插入序（CSR 散布序天然=插入序），与 GDScript 双循环
//     append 序逐位一致——调用方窄相裁定口径不变（候选超集语义）。
class FissionSpaceGrid : public RefCounted {
	GDCLASS(FissionSpaceGrid, RefCounted)

private:
	int32_t cols = 0;
	int32_t rows = 0;
	float origin_x = 0.0f;              // Vector2 分量同宽 float32（GDScript _origin.x）
	float origin_y = 0.0f;
	double max_entity_radius = 64.0;    // 脚本 float 成员在 Variant 中为 double——按 double 存
	// 镜像快照（feed_snapshot 一次写入；容量复用稳态零分配）——纯几何 SoA，无对象引用
	std::vector<int32_t> bucket_off;    // 行前缀（cols*rows+1）；空喂同样复位（CSR 不变量）
	std::vector<int32_t> bucket_flat;   // 桶内容（快照索引，插入序）——size == bucket_off.back()
	std::vector<float> snap_x;          // 快照位置 SoA（索引 = 喂入序 i）
	std::vector<float> snap_y;
	std::vector<int32_t> cursor_scratch;  // 散布游标（容量复用）
	std::vector<int32_t> result_scratch;  // 查询结果快照索引暂存（std clear 保容量）
	// 查询结果成员缓冲（引擎 COW 共享返回；复用容量——调用方释放后原地重写）
	Array result_nodes;                 // 类型化 Array[Node2D]（configure 时 set_typed）
	PackedInt32Array result_ids;        // 纯几何口结果缓冲（快照索引）

	void _collect_hits(const Vector2 &p_pos, double p_radius, std::vector<int32_t> &r_out) const;

protected:
	static void _bind_methods();

public:
	void configure(int32_t p_cols, int32_t p_rows, float p_origin_x, float p_origin_y, double p_max_entity_radius);
	void feed_snapshot(const PackedInt32Array &p_cells, const PackedVector2Array &p_pos);
	Array query_circle_snap_nodes(const Array &p_items, const Vector2 &p_pos, double p_radius);
	PackedInt32Array query_circle_snap_indices(const Vector2 &p_pos, double p_radius);
	int64_t get_candidate_count() const;

	FissionSpaceGrid();
	~FissionSpaceGrid();
};

} // namespace godot

#endif // FISSION_SPACE_GRID_NATIVE_H
