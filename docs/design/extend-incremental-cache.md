# 设计文档：tote 侧 `extend` 增量缓存接线（跨文件 overload 合并）

> 范围：本文件只处理 `src/tote.tc` 附录（764–793 行）描述的 **`extend` 增量缓存正确性** 问题，
> 即「被扩展模块 + 其（传递）扩展模块」作为同一编译单元时的内容寻址缓存。
> **不**涉及 HANDOFF / DESIGN 中的「编译器变体派生」（`[compiler].extend` → tc'）——那件由 IR-1
> （tc 在 `std.tc` 暴露开放类型）承载，与本缓存问题正交，且当前 BLOCKED。

---

## 0. 结论先行

- 这是一个 **tc ↔ tote 协作特性**；tote 侧接缝已就位，硬骨头在 tc 侧（跨文件 `extend overload` 解析
  + `--emit-deps` 输出 `extended_by` 边 + `build --lib` 多文件入口）。

### 实施状态（2026-10-15 更新）

- ✅ **阶段 1（tote 能力）已落地**：`sys_capture` / `parse_extend_edges` / `load_extend_graph` /
  `transitive_closure` / `sorted_keys` 已加入 `src/tote.tc`。
- ✅ **阶段 2（tote 接线）已落地**：`process_dep` 在复制 entry 后、`key_of` 之前调用
  `load_extend_graph`；`tc build --lib` 命令按「传递闭包」拼装多文件单元。
- ✅ **阶段 4（回归）已验证**：无 extend 普通工程路径**零行为变化**——用 git HEAD 原始 `tote.tc`
  编出基线二进制与改动后二进制，在同一 fixture 上冷构建 / 热构建 / 运行的日志、`tote.lock`、
  `app.ll`、以及全部缓存键**逐字节一致**。
- ⏸ **阶段 3（端到端验证）BLOCKED on tc**：需 REQ-EXT-1/2/3 就位（见 §5）后才能构造
  §6 fixture 验证级联重建。
- 当前 MVP（无 extend）路径不受影响：tc 今日不输出 `kind:"extend"`，`g_extend_by` 恒为空表，
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
- `extend overload fn` 语法**仅同文件**生效（Route 1）：parse.tc:2800 起；跨文件引用触发
  `T-OVL-E980 EXTEND_NO_GROUP`（diag_table.gen.h:116）。
- 多文件编译单元底座 `tc_load_src(files)`（tc.tc:54）：把多份源码拼接进同一 `decl_list`，
  共享命名空间 → 跨文件同名 overload 子句按名合并。
- `check` 已支持多文件位置参数（tc.tc:285–291），经 `tc_load_src` 拼装。
- `--emit-deps`（sema.tc:11068）输出 JSON：`{"entry":..., "edges":[{"from":X,"to":Y}, ...]}`，
  **仅 import 边，无 `extended_by`**。

### 2.2 tc 今天缺什么（核心待提交 tc）
1. 跨文件 `extend overload fn` 解析（Route 2 的语义接通：在被扩展模块与扩展模块同单元时，
   把扩展子句并入被扩展模块的 overload 组）。
2. `--emit-deps` 额外输出 `extended_by` 边（见 §3.1）。
3. 确认 / 接线 `build --lib` 接受多文件参数（tote 拼装单元时需要）。

### 2.3 tote 今天有什么（接缝已就位）
- `g_extend_by: map[string]map[string]bool`（tote.tc:264）：单元名 → {扩展它的单元}。
- `key_of`（tote.tc:322）已在 337–344 行把 `g_extend_by[name]` 闭包源哈希并入单元键。
- `imports_of`（tote.tc:300）被注释为「输入集合的单一接缝」，extend 落地后在此并入 `extended_by` 闭包。
- `process_dep`（tote.tc:366）已有 `tc build --lib` 单文件调用骨架（429–441 行）。

### 2.4 tote 今天缺什么（待补两处）
1. **从不开 `g_extend_by`**：tote 全程未调用 `tc --emit-deps`，`g_extend_by` 永远空表。
2. **`process_dep` 只传单入口文件**：未被扩展闭包拼装成多文件单元。

---

## 3. tc ↔ tote 接口契约（核心待提交 tc 的部分）

### 3.1 `--emit-deps` 扩充：新增 `extended_by` 边
`sema.emit_deps()`（sema.tc:11068）在现有 `edges`（import 边）之外，额外输出 extend 边：
```json
{
  "entry": "out/lib/dbg/foo.tc",
  "edges": [
    {"from":"foo", "to":"bar", "kind":"import"},
    {"from":"baz", "to":"foo", "kind":"extend"}   // baz extend overload 指向 foo 的组
  ]
}
```
- `from` = 扩展模块单元名；`to` = 被扩展模块单元名；`kind:"extend"` 区分 import 边。
- 传递闭包由 tote 在 `g_extend_by` 上做闭包求解（§4.1），tc 只给直接边。

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

### 4.1 填充 `g_extend_by`（新增 `load_extend_graph`）
在 `cmd_build_or_run` / `cmd_check` 解析完主清单、进入依赖遍历**之前**调用一次：

```t
// 对某个已复制到 libdir 的单元，跑 tc --emit-deps 取边，并入 g_extend_by / dep_path(import)。
fn load_extend_graph(name: string) void {
    var f: string = str_concat5(g_libdir, "/", name, ".tc", "");
    if (path_exists(f) == false) { return; }
    var cmd = "\"<tc>\" check --emit-deps --lib-dir \"<libdir>\" \"<f>\"";
    var out: string = sys_capture(cmd);          // 需新增：取 stdout（tote 现有 sys_run 只返 rc）
    // JSON 极简解析：扫 {"from":"X","to":"Y","kind":"extend"} 片段
    for each edge in parse_edges(out):
        if edge.kind == "extend":
            if (map_has(g_extend_by, edge.to) == false) { var m: map[string]bool; g_extend_by[edge.to] = m; }
            g_extend_by[edge.to][edge.from] = true;
        // import 边可顺手回填 imports_of，但 tote 已自扫 @import，可忽略
}
```
- **依赖新增**：tote 需一个「捕获子进程 stdout」的能力（现有 `sys_run` 仅返回退出码）。可在 `src/tote.tc`
  加 `sys_capture(cmd) string`（Windows: `cmd /c <cmd> > tmpfile` 再 `file_read_all`，或直接调运行时）。
- 调用点：`process_dep` 把 entry 复制到 `libdir/<name>.tc` 之后（tote.tc:417 之后）调用一次
  `load_extend_graph(name)`，确保 `key_of` 在 423 行算键前 `g_extend_by` 已填。

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

## 5. tc 侧待补（请求信箱条目，详见 TC_INTERFACE_REQUESTS.md）

| 编号 | 需要 tc 改什么 | 建议位置 | 验收标准 |
|---|---|---|---|
| REQ-EXT-1 | `--emit-deps` 输出 `extended_by` 边（kind:"extend"） | `sema.emit_deps()`（sema.tc:11068） | `tc check --emit-deps` 对含跨文件 extend 的单元输出 extend 边 |
| REQ-EXT-2 | `build --lib` 接受多文件位置参数并拼为同一单元 | `tc.tc` build 分支（参考 check 的 285–291 行） | `tc build --lib a.tc b.tc` 与单文件拼接结果语义等价，无 EXTEND_NO_GROUP |
| REQ-EXT-3 | 跨文件 `extend overload fn` 解析接通（Route 2） | parse/sema 的 overload 合并（`desugar_func_clauses`） | a.tc 声明 overload 组，b.tc `extend overload` 同单元并入，运行期分发正确 |

> 注：REQ-EXT-3 与「编译器变体派生」所需的大 extend（开放类型）不同，此处只是 overload 子句跨文件合并，
> 工作量显著小于 IR-1。但二者共享 `extend` 关键字与 `tc_load_src` 多文件底座。

---

## 6. 验收标准（端到端，待 tc 三项就位后）

1. **构造 fixture**：`foo.tc` 声明 `overload fn op(...)` 组；`bar.tc` `extend overload fn op(...)`。
2. `tote build`：foo 与 bar 拼为同一单元 → 产出 `foo.tlib`，bar 不产生独立 `.tlib`。
3. **改 bar 源** → 仅 `key_of(foo)` 失效 → foo 重建、baz（未 extend foo）复用缓存。
4. **改 foo 源** → foo 自身重建；bar 因被拼入 foo 单元而随之重建。
5. `tote check` 对同一单元不报 `EXTEND_NO_GROUP`。

---

## 7. 分阶段落地计划

- ⏸ **阶段 0（tc）**：REQ-EXT-1/2/3 由 tc 工程落地（见 TC_INTERFACE_REQUESTS.md 请求信箱）。**未开始**。
- ✅ **阶段 1（tote 能力）已完成**：已加 `sys_capture` + `parse_extend_edges` + `load_extend_graph` +
  `transitive_closure` + `sorted_keys`（§4.1/4.2），默认不触发（extend 边为空时与原逻辑一致）。
- ✅ **阶段 2（tote 接线）已完成**：`process_dep` 复制 entry 后调 `load_extend_graph`（在 `key_of` 之前）；
  `tc build --lib` 命令按传递闭包拼装多文件。另加「源中无 `extend` 关键字则跳过探测」的前置过滤，
  使无 extend 的普通工程**不付出任何 tc 子进程开销**。
- ⏸ **阶段 3（验证）BLOCKED**：待阶段 0 就位后跑 §6 fixture，确认级联重建正确、无误复用。
- ✅ **阶段 4（回归）已完成**：无 extend 普通工程零行为变化（见 §0 实施状态，逐字节对比验证）。

> 阶段 3 还需补一处（§6.2）：「扩展者不再单独产出 `.tlib`」。这要求在任何依赖被构建之前就把
> extend 图完整加载（即依赖解析与构建拆成两趟），当前 `process_dep` 是「边解析边构建」的单趟结构，
> 故该条推迟到阶段 3 与真实 extend 边一并处理。

---

## 8. 风险 / 未决

- **extend 环（已决 · 无环）**：`extend` 粒度限定为函数与数据结构（§1.1）。每条 extend 边 A→B 必伴随
  import 边 A→B（目标须先 import 入 scope）；t 的 import 图为 DAG（拒绝 `T-MOD-E551` 循环依赖，
  sema.tc:10823-10840），故 extend 图 ⊆ import 图 ⇒ 无环。tote 的 `transitive_closure` 只需 visited
  去重，**不实现环检测**。此无环性由 t 的 import 环检测保证，与 tote 包级 resolver 是否为 DAG 无关。
- **诊断溯源**：`tc_load_src` 多文件时诊断 `file` 统一指向首文件（tc.tc:53 注释），extend 报错时
  行号对应扩展模块可能不准——需 tc 在 R2 下完善 `g_file` 溯源（非 tote 阻塞项）。
- **确定性**：多文件拼接顺序必须稳定（被扩展模块恒为首），否则内容哈希抖动。当前约定被扩展模块为
  单元名且排第一，已稳定。
- **与变体派生的关系**：本设计仅解决「同一工程内被依赖库的跨文件 extend 缓存」，不涉及 `tc'` 派生；
  二者在 `[compiler].extend` 引入后再统一考量。
- ⚠ **`sys_capture` 的 cmd 引号陷阱（已踩坑 · 已修复）**：`t_system`（`runtime/t_runtime.c`）对
  **以引号开头**的命令串会【自动再包一层引号】以绕开 cmd.exe 的引号剥离怪癖。因此捕获 stdout 时
  **绝不能自己再加 `cmd /c ` 前缀**——否则变成 cmd 套 cmd、引号被二次剥离，程序路径被破坏、
  子进程起不来，而 stderr 又被 `2>nul` 吞掉，最终表现为「静默捕获到 0 字节」，整条链路看似正常实则已死。
  正确写法：把「命令 + `> tmp`」直接交给 `sys_run`，由 `t_system` 统一处理。
- **探测顺序的边界**：`load_extend_graph(X)` 只能得知「X 自己 extend 了谁」（X 的出边）。若扩展者 Y
  在被扩展者 X **之后**才被处理，`key_of(X)` 可能已先算完并命中缓存。代码已对新发现的边做
  `map_del(g_key_cache, to)` 失效处理，但**已构建完成的产物无法回滚**。彻底解法是把「解析/加载图」
  与「构建」拆成两趟（即阶段 3 的 §6.2 改造），当前因 extend 边恒空而不触发。
