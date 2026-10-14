#include "space_grid_native.h"

#include <godot_cpp/core/class_db.hpp>

#include <cstring>

using namespace godot;

namespace {

// GDScript clampi(x, lo, hi) 语义复刻：x<lo→lo；x>hi→hi；否则 x（顺序敏感——lo>hi 时
// 大值取 hi，实测锚 clampi(0,0,-1)==-1）。
inline int32_t clampi_mirror(int32_t v, int32_t lo, int32_t hi) {
	return v < lo ? lo : (v > hi ? hi : v);
}

// GDScript int(double) 语义复刻：向零截断（cvttsd2si）；越界/NaN 为纯护栏（生产坐标
// 域远达不到，NaN→0 只为消除 UB，不与 GDScript NaN 行为对标——测试域全有限值）。
inline int32_t trunc_to_i32(double v) {
	if (!(v == v)) {
		return 0;
	}
	if (v >= 2147483647.0) {
		return 2147483647;
	}
	if (v <= -2147483648.0) {
		return -2147483648;
	}
	return static_cast<int32_t>(v);
}

} // namespace

void FissionSpaceGrid::_bind_methods() {
	ClassDB::bind_method(D_METHOD("configure", "cols", "rows", "origin_x", "origin_y", "max_entity_radius"), &FissionSpaceGrid::configure);
	ClassDB::bind_method(D_METHOD("feed_snapshot", "cells", "pos"), &FissionSpaceGrid::feed_snapshot);
	ClassDB::bind_method(D_METHOD("query_circle_snap_nodes", "items", "pos", "radius"), &FissionSpaceGrid::query_circle_snap_nodes);
	ClassDB::bind_method(D_METHOD("query_circle_snap_indices", "pos", "radius"), &FissionSpaceGrid::query_circle_snap_indices);
	ClassDB::bind_method(D_METHOD("get_candidate_count"), &FissionSpaceGrid::get_candidate_count);
}

void FissionSpaceGrid::configure(int32_t p_cols, int32_t p_rows, float p_origin_x, float p_origin_y, double p_max_entity_radius) {
	cols = p_cols > 0 ? p_cols : 0;
	rows = p_rows > 0 ? p_rows : 0;
	// 溢出护栏：cols*rows 超 int32 域（不可能的生产配置）→ 视为空网格（查询返回空）
	if (static_cast<int64_t>(cols) * static_cast<int64_t>(rows) > 2147483647LL) {
		cols = 0;
		rows = 0;
	}
	origin_x = p_origin_x;
	origin_y = p_origin_y;
	max_entity_radius = p_max_entity_radius;
	bucket_off.assign(static_cast<size_t>(cols) * static_cast<size_t>(rows) + 1, 0);
	bucket_flat.clear();
	snap_x.clear();
	snap_y.clear();
	// 结果缓冲定型为类型化 Array[Node2D]（空、未共享时设型——此后 resize/写入沿型传递，
	// GDScript 侧 typed return 校验直通）。
	result_nodes = Array();
	result_nodes.set_typed(Variant::OBJECT, StringName("Node2D"), Variant());
}

void FissionSpaceGrid::feed_snapshot(const PackedInt32Array &p_cells, const PackedVector2Array &p_pos) {
	// R239 修轮：空喂/失配同样全量复位桶前缀——v1 在此早退不复位，遗留陈旧 CSR 前缀
	// 使后续查询越界读已清空数组（0xC0000005 根因）。不变量：bucket_off 恒为当前快照
	// 的完整前缀和，bucket_off.back() == bucket_flat.size()。
	for (int32_t &v : bucket_off) {
		v = 0;
	}
	const int64_t n_pos = p_pos.size();
	const int64_t n_cells_in = p_cells.size();
	const int64_t n = n_pos < n_cells_in ? n_pos : n_cells_in; // 失配护栏（GDScript 侧恒同长）
	const int64_t n_cells = static_cast<int64_t>(bucket_off.size()) - 1;
	if (n <= 0 || n_cells <= 0) {
		bucket_flat.clear();
		snap_x.clear();
		snap_y.clear();
		return;
	}
	const int32_t *cells = p_cells.ptr();
	const godot::Vector2 *pos = p_pos.ptr();
	int32_t *off = bucket_off.data();
	// 计数（非法 cell 护栏：GDScript _cell_index 已钳制，恒不可达）→ 前缀和 → 按插入序
	// 散布（散布序=快照索引升序=GDScript 桶内 append 序）；bucket_flat 精确尺寸 = 有效
	// 条目数，保证 bucket_off.back() == bucket_flat.size() 不变量。
	int64_t valid = 0;
	for (int64_t i = 0; i < n; i++) {
		const int64_t cell = cells[i];
		if (cell < 0 || cell >= n_cells) {
			continue;
		}
		off[cell + 1]++;
		valid++;
	}
	for (int64_t c = 0; c < n_cells; c++) {
		off[c + 1] += off[c];
	}
	bucket_flat.resize(static_cast<size_t>(valid));
	snap_x.resize(static_cast<size_t>(n));
	snap_y.resize(static_cast<size_t>(n));
	cursor_scratch.assign(bucket_off.begin(), bucket_off.end() - 1);
	int32_t *flat = bucket_flat.data();
	for (int64_t i = 0; i < n; i++) {
		const int64_t cell = cells[i];
		if (cell < 0 || cell >= n_cells) {
			continue;
		}
		flat[cursor_scratch[cell]++] = static_cast<int32_t>(i);
	}
	for (int64_t i = 0; i < n; i++) {
		snap_x[static_cast<size_t>(i)] = pos[i].x;
		snap_y[static_cast<size_t>(i)] = pos[i].y;
	}
}

void FissionSpaceGrid::_collect_hits(const Vector2 &p_pos, double p_radius, std::vector<int32_t> &r_out) const {
	// 覆盖格扫描 + 距离精判（两查询口共用：nodes 生产口 / indices 纯几何口——同源同序）。
	r_out.clear();
	// 入口一致性护栏（防御性——feed 恒维持不变量；破坏时返回空而非产出脏数据/越界读，
	// 旧 v1 即因缺此闸+空喂不复位而崩）：
	//   cols/rows>0 ∧ bucket_off 恰为 cols*rows+1 ∧ 前缀总和==桶内容数 ∧ 位置 SoA 同长
	const size_t n_cells_u = bucket_off.empty() ? 0 : bucket_off.size() - 1;
	if (cols <= 0 || rows <= 0 || bucket_off.empty() ||
			n_cells_u != static_cast<size_t>(cols) * static_cast<size_t>(rows) ||
			static_cast<int64_t>(bucket_off.back()) != static_cast<int64_t>(bucket_flat.size()) ||
			snap_x.size() != snap_y.size()) {
		return;
	}
	// reach 全 double 域（maxf double 原生实测锚——header 注释）；同 GDScript
	// query_circle_snap 的 reach 与 _cells_in_range 内部重算值天然同值。
	const double reach = (p_radius > 0.0 ? p_radius : 0.0) + max_entity_radius;
	const double reach_sq = reach * reach;
	// 覆盖格：((pos.x ± reach) - origin.x) / 128.0 —— double 域、左结合同式、
	// 向零截断、clampi（同 _cells_in_range 同序）。
	const int32_t hi_c = cols - 1;
	const int32_t hi_r = rows - 1;
	const double div = 128.0; // float(CELL_SIZE)，CELL_SIZE=128 跨语言契约常量
	const double px = static_cast<double>(p_pos.x);
	const double py = static_cast<double>(p_pos.y);
	const double ox = static_cast<double>(origin_x);
	const double oy = static_cast<double>(origin_y);
	const int32_t c0 = clampi_mirror(trunc_to_i32((px - reach - ox) / div), 0, hi_c);
	const int32_t c1 = clampi_mirror(trunc_to_i32((px + reach - ox) / div), 0, hi_c);
	const int32_t r0 = clampi_mirror(trunc_to_i32((py - reach - oy) / div), 0, hi_r);
	const int32_t r1 = clampi_mirror(trunc_to_i32((py + reach - oy) / div), 0, hi_r);
	// 行主序 × 桶内插入序扫描；距离精判同 Vector2.distance_squared_to 公式
	// ((sx-px)²+(sy-py)² float32 域，-ffp-contract=off 禁收缩)，升 double 与 reach_sq 比。
	for (int32_t row = r0; row <= r1; row++) {
		const int64_t row_base = static_cast<int64_t>(row) * cols;
		for (int32_t col = c0; col <= c1; col++) {
			const int64_t cell = row_base + col;
			int64_t k = bucket_off[static_cast<size_t>(cell)];
			const int64_t end = bucket_off[static_cast<size_t>(cell) + 1];
			for (; k < end; k++) {
				const int32_t i = bucket_flat[static_cast<size_t>(k)];
				const float dx = snap_x[static_cast<size_t>(i)] - p_pos.x;
				const float dy = snap_y[static_cast<size_t>(i)] - p_pos.y;
				const float d2 = dx * dx + dy * dy;
				if (static_cast<double>(d2) <= reach_sq) {
					r_out.push_back(i);
				}
			}
		}
	}
}

Array FissionSpaceGrid::query_circle_snap_nodes(const Array &p_items, const Vector2 &p_pos, double p_radius) {
	// 生产口：items 由调用方每次传入（引擎 Array COW 共享——本侧零持久持有，调用返回
	// 即释放；对象生命周期窗口=单次同步调用）。命中索引就地取实体写入成员类型化缓冲
	// 直返（零逐命中 GDScript 解析）。护栏：条目数必须与快照一致（失配=调用方错误 →
	// 返回空，绝不按越界索引取实体）。
	if (static_cast<int64_t>(p_items.size()) != static_cast<int64_t>(snap_x.size())) {
		result_nodes.resize(0);
		return result_nodes;
	}
	_collect_hits(p_pos, p_radius, result_scratch);
	const int64_t m = static_cast<int64_t>(result_scratch.size());
	// 空结果也必须返回类型化缓冲（GDScript typed return 校验对空数组同样生效——
	// 返回裸 Array() 会触发 per-query SCRIPT ERROR，实测锚 _tmp_r239_typed_probe）。
	if (m <= 0) {
		result_nodes.resize(0);
		return result_nodes;
	}
	if (result_nodes.resize(m) != 0) {
		result_nodes.resize(0);
		return result_nodes; // resize 失败护栏（OOM ERR 路径，不产出错数据）
	}
	for (int64_t j = 0; j < m; j++) {
		result_nodes[j] = p_items[result_scratch[static_cast<size_t>(j)]]; // 引擎 Variant 赋值
	}
	return result_nodes;
}

PackedInt32Array FissionSpaceGrid::query_circle_snap_indices(const Vector2 &p_pos, double p_radius) {
	// 纯几何诊断口：与 nodes 版同源同序（_collect_hits 共用），返回快照索引而非实体引用
	// （不经手对象——供等价对拍/后续 id 化消费）。
	_collect_hits(p_pos, p_radius, result_scratch);
	const int64_t m = static_cast<int64_t>(result_scratch.size());
	if (m <= 0) {
		result_ids.resize(0);
		return result_ids;
	}
	result_ids.resize(static_cast<int>(m));
	if (static_cast<int64_t>(result_ids.size()) != m) {
		result_ids.resize(0);
		return result_ids; // resize 失败护栏（OOM ERR_FAIL 路径，不产出错数据）
	}
	memcpy(result_ids.ptrw(), result_scratch.data(), static_cast<size_t>(m) * sizeof(int32_t));
	return result_ids;
}

int64_t FissionSpaceGrid::get_candidate_count() const {
	return static_cast<int64_t>(snap_x.size());
}

FissionSpaceGrid::FissionSpaceGrid() {}

FissionSpaceGrid::~FissionSpaceGrid() {}
