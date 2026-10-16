# 设计文档：tote 侧 `extend` 增量缓存接线（跨文件 overload 合并）

> 范围：本文件只处理 `src/tote.tc` 附录（764–793 行）描述的 **`extend` 增量缓存正确性** 问题，
> 即「被扩展模块 + 其（传递）扩展模块」作为同一编译单元时的内容寻址缓存。
> **不**涉及 HANDOFF / DESIGN 中的「编译器变体派生」（`[compiler].extend` → tc'）——那件由 IR-1
> （tc 在 `std.tc` 暴露开放类型）承载，与本缓存问题正交，且当前 BLOCKED。

---

## 0. 结论先行

- 这是一个 **tc ↔ tote 协作特性**；tote 侧接缝已就位，硬骨头在 tc 侧（跨文件 `extend overload` 解析
  + `--emit-deps` 输出 `extended_by` 边 + `build --lib` 多文件入口）。

### 实施状态（2026-10-16 更新）

- ✅ **阶段 1（tote 能力）已落地**：`scan_overload_targets` / `scan_extend_targets` /
  `register_extend_edge` / `load_full_graph`（静态源码分析）/ `transitive_closure` / `sorted_keys`
  已加入 `src/tote.tc`。
- ✅ **阶段 2（tote 接线）已落地**：两趟拆分——`Pass 1`（`resolve_all_deps` + `load_full_graph`
  静态分析建图）与 `Pass 2`（`build_unit` 按拓扑序构建，被吸收单元跳过独立 `.tlib`）。
- ✅ **阶段 3（端到端验证）已通过**：`tests/extend_pkg` fixture 冷构建 / 改 ext 重建 /
  改 base 重建 / 全量缓存复用 全部正确（详见 §6 实测结论）。
- ✅ **阶段 4（回归）已验证**：无 extend 普通工程路径**零行为变化**——`tests/fixture` 冷构建
  输出 `foo_add=12 / bar_id=7 / baz_val=100`，热构建全量复用，改 bar 级联重建 foo+app、baz 复用。
- ⚠ **关键工程决策（2026-10-16）**：extend 边**不再依赖 tc `--emit-deps`**。实测证伪原假设——
  tc 的 `check --emit-deps` 在（合并或单文件）单元上均只输出 import 边，跨文件 extend 边任何
  场景都报不出（`emit_deps` 需被扩展 overload 组已进入当前单元 decl_list 才能匹配，而 per-unit
  探测时扩展者未把目标拉入同一单元）；且 `build --lib` 不接受 `--emit-deps`。故 tote 改用
  **Pass 1 静态源码分析**（按 overload 组名匹配扩展者↔被扩展者），零 tc 子进程、忠实于 tc 语义。
- 当前 MVP（无 extend）路径不受影响：静态扫描无 `overload`/`extend` ⇒ `g_extend_by` 恒空表，
  闭包为空 ⇒ 不追加任何文件、键不变，等价于原逻辑。

---

## 1. 为什么需要它（现象与根因）

被扩展模块的**自身源码未改**，但被别的模块 `extend overload fn` 扩展后，其编译产物的「有效输入」已变：
跨文件 `extend overload fn` 要求 **【被扩展模块 + 其所有（传递）扩展模块】作为同一个编译单元** 一起喂给 tc
（多文件 `tc_load_src` / Route 2），否则报 `EXTEND_NO_GROUP`（错误码 `T-OVL-E980`）。

因此被扩展模块的**缓存键必须包含「扩展它的模块的源」**：某扩展模块源变了 → 其键变 → 所有被它扩展的模
块的键跟着变 → 级联重建。否则会复用过期的 `.tlib`。

---

## 1.1 粒度约定（已决）：`extend` 以「函数」与「数据结构」为最小单位

- `extend` 的最小作用对象只有两类：**具名函数**（如 `extend overload fn op(...)`）与**具名数据结构**
  （如 `extend struct Vec3 { ... }`）。不针对模块、命名空间或任意代码块做整体 extend。
- **由此推出：extend 图不存在环。** 严格依据如下（注意：与 tote 的包级 resolver 无关）：
  - 一个函数 / 数据结构**只在其所属模块声明一次**（owner 唯一）。`extend` 是对「他人声明」的追加。
  - `extend` 要引用目标声明，目标必须已进入当前作用域——在 t 中这意味着**必须先 `@import` 其所属模块**
    （`extend overload` 引用的是已存在的 overload 组；跨文件时该组须经 import 入 scope：parse.tc:3583）。
    因此**每条 extend 边 A→B 必然伴随一条 import 边 A→B**。
  - t 的模块 import 图是 **DAG**：`handle_one_import`（sema.tc:10823）对已在加载栈的模块报
    `T-MOD-E551`「检测到循环依赖 / import 不能成环」（活跃栈 `g_mod_stack` 环检测，sema.tc:10823-10840）。
  - 于是 **extend 图 ⊆ import 图 ⊆ DAG ⇒ extend 图无环**。
- 推论（实现约束）：
  - `transitive_closure(g_extend_by, X)` 只需普通 DFS/BFS + visited 去重，**无需环检测 / DFS 栈**。
  - 正文 §4.2、§8 的「成环检测兜底」据此改为「可省」（见 §8 更新）。
- 旁注（与 resolver 的关系）：tote 的**包级 resolver**（`process_dep` 遍历 `tote.toml` 的 `[dependencies]`）
  是**另一张图**——它决定抓取 / 构建哪些包。它自身也应是 DAG，但它**不是** extend 无环的根据；
  extend 无环由上述 import 图保证。两者不要混为一谈。

---

## 2. 现状盘点（实证）

### 2.1 tc 今天有什么
- 跨文件 `extend overload fn` 解析已接通（REQ-EXT-3 落地）：被扩展模块与扩展模块**同单元**
  （`tc_load_src` 多文件）时，扩展子句并入被扩展模块的 overload 组，`tc build --lib a.tc b.tc`
  与单文件拼接语义等价、运行期分发正确（值模式跨 extend 生效；守卫模式 `when cond` 即使同文件
  也**不**参与运行期分发，故跨文件必须用值模式子句）。
- 多文件编译单元底座 `tc_load_src(files)`（tc.tc:54）：把多份源码拼接进同一 `decl_list`，
  共享命名空间 → 跨文件同名 overload 子句按名合并。
- `check` 已支持多文件位置参数（tc.tc:285–291），经 `tc_load_src` 拼装。
- `--emit-deps`（sema.tc:11068）输出 JSON：`{"entry":..., "edges":[{"from":X,"to":Y}, ...]}`，
  **仅 import 边**。⚠ **重要**：`check --emit-deps` 在跨文件 extend 场景下**不输出**
  `kind:"extend"` 边（见 §2.2 实测），`build --lib` 亦不接受 `--emit-deps` 开关。

### 2.2 tc 的 emit-deps 局限（实测 · 决定 tote 改用静态分析）
`emit_deps()`（sema.tc:11081）理论上在「被扩展 overload 组已进入当前单元 decl_list」时会
输出 `{from:Y, to:X, kind:"extend"}`。但**实测**：
- `tc check --emit-deps ext.tc`（ext 不 `@import` base）→ `{"edges":[]}`；
- `tc check --emit-deps base.tc ext.tc`（合并单元仍只给首文件 entry）→ 仍 `{"edges":[]}`；
- `tc build --lib --emit-deps ...` → 把 `--emit-deps` 当成文件路径报错。
根因：emit_deps 的 extend 边匹配依赖被扩展组已在本单元 decl_list，而 tote per-unit 探测时
扩展者并未把目标拉进同一单元，故永远匹配不到。`⇒ tote 不能在 Pass 1 依赖 tc 发现 extend 边`，
改为 tote 自做静态源码分析（§3 / §4.1）。tc 侧的 REQ-EXT-1（emit-deps 出 extend 边）对 tote
已非必需。

### 2.3 tote 今天有什么（接缝已就位）
- `g_extend_by: map[string]map[string]bool`：单元名 → {扩展它的单元}（入边）。
- `g_extends: map[string]map[string]bool`：单元名 → {本单元 extend 的单元}（出边，吸收判定）。
- `key_of`（tote.tc:328）已把 `transitive_closure(name)` 闭包源哈希并入单元键。
- `imports_of`（tote.tc:306）仍是「输入集合的单一接缝」。
- 两趟骨架：`resolve_all_deps` / `load_full_graph`（静态分析建图）/ `build_unit`（拓扑序构建）。

### 2.4 tote 今天缺什么（已补）
1. ~~**从不开 `g_extend_by`**~~：已由 `load_full_graph` 的静态分析填充（不依赖 tc `--emit-deps`）。
2. ~~**`process_dep` 只传单入口文件**~~：已改为两趟，`build_unit` 按 `transitive_closure`
   拼装多文件单元，被吸收单元跳过独立 `.tlib`。

---

## 3. tc ↔ tote 接口契约（核心待提交 tc 的部分）

### 3.1 extend 边来源（tote 静态分析，不依赖 tc `--emit-deps`）
> ⚠ 原设计拟让 tc 的 `--emit-deps` 输出 `extended_by` 边（见旧 §3.1）。**实测该路径在跨文件
> extend 下取不到边**（§2.2），故 tote 改为静态分析，tc 的 emit-deps 对 tote 已非必需。

tote 在 Pass 1 对 `out/lib/<mode>` 下每个已复制的单元源码做轻量扫描：
- `overload fn NAME`（前一词非 `extend`）⇒ 该单元「声明」名为 `NAME` 的 overload 组；
- `extend overload fn NAME` ⇒ 该单元「扩展」名为 `NAME` 的 overload 组。
把「扩展名 `NAME`」按名匹配到「声明 `NAME` 的其他单元」，即得边
`{from: 扩展者单元, to: 被扩展单元}`。这与 tc 内部按名合并 overload 组的口径一致（跨文件
extend 本就是同单元内按名合并），忠实于 tc 语义；纯字符串扫描、零 tc 子进程。

- `from` = 扩展模块单元名；`to` = 被扩展模块单元名。
- 传递闭包由 tote 在 `g_extend_by` 上做闭包求解（§4.1），静态分析只给直接边。

### 3.2 多文件编译单元入口
`tote` 把「被扩展模块 + 其扩展闭包」按 `tc build --lib` 的**多个位置参数**传入：
```
tc build --lib --mode <m> --output out/lib/<m>/<name> --lib-dir out/lib/<m> \
    out/lib/<m>/<name>.tc [out/lib/<m>/<ext1>.tc ...]
```
- 要求 `build --lib` 像 `check` 一样把所有位置参数经 `tc_load_src` 拼为同一单元（tc.tc:285–291 已有范式）。
- 单元名取**被扩展模块**名（`<name>`），`.tlib` 落在该名上；扩展模块**不再单独**产出 `.tlib`，其源仅作拼装输入。

### 3.3 闭包传递语义
- `g_extend_by[X]` = {直接 extend X 的单元}。
- 被扩展模块 X 的「有效输入」= X 自身源 + `transitive_closure(g_extend_by, X)` 的源。
- `key_of(X)` 已按此实现（tote.tc:337–344），只需把 `g_extend_by` 从 emit-deps 结果填实。

---

## 4. tote 侧待补两处接线（具体改动 + 伪代码）

### 4.1 填充 `g_extend_by`（Pass 1 静态分析 · `load_full_graph`）
在两趟的 Pass 1 内、`cmd_build_or_run` / `cmd_check` 解析完主清单、复制全部 entry 到 libdir
**之后**、进入任何构建**之前**调用一次：

```t
// 对全部已复制到 libdir 的单元做静态分析，建出完整 extend 图（不依赖 tc --emit-deps）。
fn load_full_graph() void {
    // 阶段 ①：建「overload 组名 -> {声明该组的单元}」索引 g_decl_units
    for u in g_all_units:
        decls = scan_overload_targets(read(libdir/"u.tc"))
        for nm in decls: g_decl_units[nm][u] = true
    // 阶段 ②：匹配扩展名到其他声明单元，登记边
    for u in g_all_units:
        exts = scan_extend_targets(read(libdir/"u.tc"))
        for nm in exts:
            for tv in g_decl_units[nm]:
                if tv != u: register_extend_edge(u, tv)   // from=u(扩展者) to=tv(被扩展)
}
```
- `scan_overload_targets`：找 `overload fn NAME`（前词非 `extend`）。
- `scan_extend_targets`：找 `extend [pub] overload fn NAME`。
- `register_extend_edge(from, to)`：同时填 `g_extend_by[to][from]`（入边）与
  `g_extends[from][to]`（出边，吸收判定），并作废相关缓存键。
- **零 tc 子进程**：纯字符串扫描，无 extend 的普通工程也无任何开销（扫描无匹配即退出）。
- 调用点：`resolve_all_deps(doc); load_full_graph();` 之后才进入 `Pass 2` 的 `build_unit` 循环，
  保证 `key_of` 算键前 `g_extend_by` 已全图填实（根治旧单趟的「已构建产物无法回滚」问题）。

### 4.2 `process_dep` 多文件拼装
当 `map_has(g_extend_by, name)` 为真时，把闭包内各单元文件追加到 `tc build --lib` 位置参数：

```t
// 在 tote.tc:429 的 cmd 拼接处，把单文件 fullentry 换成「闭包文件列表」
var unit_files: []string;
append(unit_files, fullentry);
if (map_has(g_extend_by, name)) {
    for (e in transitive_closure(g_extend_by, name)) {
        append(unit_files, str_concat5(g_libdir, "/", e, ".tc", ""));
    }
}
// 逐文件拼进 cmd（每个文件一个引号包裹的位置参数）
```
- 需要新增 `transitive_closure(g_extend_by, root) map[string]bool`（普通 DFS/BFS + visited 去重即可；
  extend 图结构上无环，见 §1.1，故**无需**环检测 / DFS 栈）。

---

## 5. tc 侧（与 tote 职责划分）

| 编号 | 内容 | 状态 |
|---|---|---|
| REQ-EXT-1 | `--emit-deps` 输出 `extended_by` 边 | ⚠ **对 tote 已非必需**：实测跨文件 extend 下取不到边（§2.2），tote 改用静态分析 |
| REQ-EXT-2 | `build --lib` 接受多文件位置参数并拼为同一单元 | ✅ 已落地（`tc build --lib a.tc b.tc` 语义等价） |
| REQ-EXT-3 | 跨文件 `extend overload fn` 解析接通（Route 2） | ✅ 已落地（值模式跨文件分发正确） |

> 注：REQ-EXT-3 与「编译器变体派生」所需的大 extend（开放类型）不同，此处只是 overload 子句跨文件合并。
> tote 仅依赖 REQ-EXT-2/3（`build --lib` 多文件 + 跨文件 extend 解析）；REQ-EXT-1 因 tote 侧改用
> 静态分析而不再是 tote 的硬依赖。

---

## 6. 验收标准（端到端 · 2026-10-16 实测结论：全部通过）

fixture：`tests/extend_pkg`
- `libs/base/src/base.tc`：`pub overload fn op(a,b){a+b}`
- `libs/ext/src/ext.tc`：`extend overload fn op(0, b: i64) i64 { return b * 100; }`（**值模式**，跨文件分发）
- `src/main.tc`：`@import("base")`，打印 `op(0,5)` 与 `op(2,3)`

1. ✅ `tote build`：base 与 ext 拼为同一单元 → 产出 `base.tlib`，ext **不产出**独立 `.tlib`（被吸收）。
2. ✅ 运行：`op(0,5)=500`（ext 值模式子句）、`op(2,3)=5`（base 子句）——跨文件 extend 合并 + 运行期分发正确。
3. ✅ **改 ext 源** → `key_of(base)` 失效（闭包含 ext 源）→ base 重建（折叠新 ext）、main 重建；baz 类无关单元若存则复用。
4. ✅ **改 base 源** → base 自身重建（仍折叠 ext）；main 随之重建。
5. ✅ **未改动时全量复用**：BUILD#2 全部命中缓存键，无任何 tc 调用。
6. ✅ **非 extend 回归**（`tests/fixture`）：冷构建 `foo_add=12/bar_id=7/baz_val=100`，热构建全量复用，
   改 bar 级联重建 foo+app、baz 复用——零行为变化。

---

## 7. 分阶段落地计划（2026-10-16 全部完成）

- ✅ **阶段 0（tc）**：REQ-EXT-2/3 落地；REQ-EXT-1 经实测证伪「tote 可用」，tote 改静态分析。
- ✅ **阶段 1（tote 能力）已完成**：`scan_overload_targets` + `scan_extend_targets` + `register_extend_edge`
  + `load_full_graph`（静态分析）+ `transitive_closure` + `sorted_keys`，无 extend 时零开销。
- ✅ **阶段 2（tote 接线）已完成**：两趟拆分——`Pass 1`（`resolve_all_deps` + `load_full_graph` 建图）
  与 `Pass 2`（`build_unit` 拓扑序构建，被吸收单元跳过独立 `.tlib`，`tc build --lib` 按传递闭包多文件拼装）。
- ✅ **阶段 3（验证）已完成**：§6 fixture 级联重建、吸收、运行期分发全部正确。
- ✅ **阶段 4（回归）已完成**：无 extend 普通工程零行为变化（`tests/fixture` 验证）。

---

## 8. 风险 / 未决

- **extend 环（已决 · 无环）**：`extend` 粒度限定为函数与数据结构（§1.1）。`transitive_closure`
  只需 visited 去重，**不实现环检测**。若真出现 t 层未被拦住的 extend 环，tc 自身 build 会报错，
  属可接受的非阻塞项。
- **诊断溯源**：`tc_load_src` 多文件时诊断 `file` 统一指向首文件，extend 报错行号可能不准——tc 侧完善项（非 tote 阻塞）。
- **确定性**：多文件拼接顺序稳定（被扩展模块恒为首，闭包按名升序追加），内容哈希不抖动。
- **与变体派生的关系**：本设计仅解决「同一工程内被依赖库的跨文件 extend 缓存」，不涉及 `tc'` 派生。
- ⚠ **静态分析按名匹配的限制（已知近似）**：`scan_extend_targets` 把扩展名按 overload 组**名**
  匹配到「声明该名的其他单元」。若不同模块声明了**同名** overload 组，扩展者可能被折叠进错误单元。
  overload 组名按惯例模块内唯一，MVP 下可接受；后续如需精确，可再结合 tc 的单元归属信息（届时
  REQ-EXT-1 的 emit-deps 边反而可作为精确来源）。
- **守卫模式不分发（跨文件须用值模式）**：t 的 overload 守卫（`when cond`）即使同文件也不参与运行期
  分发，跨文件 extend 必须用**值模式**子句（如 `extend overload fn op(0, b: i64)`）才能触发分发。
  fixture 已据此采用值模式；若用户误用守卫模式，运行期会静默走首声明子句，属 t 语言语义，非 tote bug。
