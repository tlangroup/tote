# tc 工程接口修改建议 + 请求信箱（tote ↔ t 编译器 协作契约）

> 本文件是 **tote 工程** 与 **t 编译器工程（C:\seesaw\codebuddy\t）** 之间的接口契约与异步协作信箱。
>
> - **Part A（基线建议）**：由 t 编译器工程当前会话（2026-10-15）先行给出的「tc 侧该改哪里、改成什么样」建议。
>   这是"你的建议"——tote 新空间据此细化，不必从零设计。
> - **Part B（请求信箱）**：tote 新空间在实现中确定要 tc 改的具体、可执行请求，追加至此；
>   t 工程当前会话读取后落地接口修改，并回写状态。
>
> 两空间通过本文件异步协作，互不阻塞。

---

## Part A — tc 侧接口修改建议（基线）

> 状态图例：🔴 BLOCKED（依赖 extend 语法等未落地）｜🟡 建议（待 tote 细化）｜🟢 现有可用（仅需补契约）

### IR-1 · std.tc 开放类型钩子（extend 可扩展面） 🔴
- **动机**：D2 要求 tc 把"可被子项目改写的编译器行为"暴露为开放类型，extend 只需 `import std`。
- **建议修改位置（t 工程）**：
  - 新建/扩展 **`src/std.tc`**（t 语言标准库）：以**开放枚举 / 开放变量体 / 开放结构体**声明编译器钩子
    （如运算符语义分派表、类型 kind 扩展点、pass/desugar 插件挂载点）。
  - tc 编译器内部消费这些开放类型的地方（目前散落在 `src/sema.tc` / `src/codegen_*.tc` / `src/parse.tc`）
    改为"从 std 的开放类型读取扩展"，而非硬编码。
- **建议接口形态**：
  - `extend` 模块示例（概念，待 t 语言 extend 语法正式确定后回填）：
    ```t
    import std
    extend struct Vec3 { fn len(self) f64 { ... } }   // 向 std 开放结构体追加成员/语义
    ```
  - tote 侧**只需消费 `[compiler].extend` 指向的模块路径**，不关心内部机制。
- **依赖**：t 语言的 `extend` 特性（开放枚举/开放变量体/开放结构体）必须先落地。
- **状态**：🔴 BLOCKED on extend 语法；建议的"钩子落点"待 tc 工程在 IR-1 细化。

### IR-2 · 派生变体构建入口 🟡
- **动机**：MVP 步骤 5（变体派生流水线）需要"用 root tc 把 extend 模块编译成 tc' 可执行"。
- **建议修改位置（t 工程）**：tc 的构建/启动路径（`src/tc.tc` 及 bootstrap 脚本）。
- **建议接口形态**（概念）：
  - `tc --extend src/extend.tc -o out/compiler/<hash>/tc'` —— 以"扩展后 std"构建一个可替换 std 的编译器变体可执行。
  - 或：tote 在 bootstrap 阶段用 root tc 把 `extend.tc` + 扩展后 `std` 编译为可执行 `tc'`（复用现有 `tc build` 能力）。
- **鸡生蛋（D5）**：extend 模块及其依赖**必须由 root tc 编译**（tc' 尚未存在）。
- **状态**：🟡 待 tote 与 tc 共同确定变体构建入口命令。

### IR-3 · .tlib 制品契约 🟢
- **动机**：tote 复用依赖的 `.tlib`（target 级增量），需要稳定的格式/命名/ABI 契约。
- **建议修改位置（t 工程）**：`src/codegen_*.tc` 的 `.tlib` 产出逻辑（已存在）。
- **建议接口形态**：
  - 固化 `.tlib` 的产出路径（如 `out/<mode>/<pkg>.tlib`）、内容结构、ABI 版本字段。
  - 新增一份契约文档（建议放 `docs/compiler/tlib-format.md`）供 tote 消费。
- **状态**：🟢 tc 现有即可用；建议补契约文档，无需改代码。

### IR-4 · TOML 解析归属（非 tc 改动） 🟢
- **动机**：tote 需解析 `tote.toml`。
- **建议**：**tote 自带纯 t 实现的 TOML parser**（如 `src/toml.tc` 或 `lib/toml.tc`），不依赖 tc 改动。
  避免 tote 与编译器耦合。
- **状态**：🟢 tote 侧自行实现，tc 无改动。

### IR-5 · comptime build.tc 入口约定 🟡
- **动机**：B1 用 `comptime` 取代 build.rs；`build.tc` 做沙箱化代码生成。
- **建议修改位置（t 工程）**：tc 的 `comptime` 机制（已支持），需约定 build.tc 的入口形态。
- **建议接口形态**：
  - `build.tc` 导出约定入口，如 `comptime fn build(ctx: BuildCtx) { ... }`，返回生成代码或写出文件列表。
  - tote 调用 `tc` 在 comptime 上下文执行 `build.tc`，产物按内容哈希缓存。
- **状态**：🟡 入口约定待定；tc 侧 comptime 已可用。

### IR-6 · 编译器能力查询接口 🟡
- **动机**：tote 需要查询 root tc 的版本、支持特性（是否支持 extend、.tlib 版本、双后端等）做能力协商。
- **建议修改位置（t 工程）**：tc 的 CLI 入口（`src/tc.tc`）。
- **建议接口形态**：
  - `tc --version` → 版本字符串。
  - `tc --capabilities` → JSON：`{ "version": "...", "extend": true/false, "tlib_abi": 1, "backends": ["llvm","c"] }`。
- **状态**：🟡 建议新增。

### IR-7 · 确定性/可复现构建 🟡
- **动机**：tote 的内容寻址缓存要求"同输入 → 同输出哈希"。
- **建议修改位置（t 工程）**：`src/codegen_*.tc` 的输出顺序 / 元数据。
- **建议接口形态**：
  - 保证 `.tlib` 与编译产物输出顺序稳定（不依赖哈希遍历序 / 并发调度序）。
  - 可选 `--deterministic` 开关；meta 中剔除时间戳等非确定字段。
- **状态**：🟡 建议；需实测 tc 当前产物是否已确定性。

---

## Part B — CONCRETE REQUESTS（请求信箱）

> **tote 新空间**在此追加"我需要 tc 工程改的具体、可执行请求"。每条给：编号、需要改什么、建议文件/函数、验收标准。
> t 工程当前会话读取后落地，并把状态从 `OPEN` 改为 `DONE` 并注明 commit。

### 模板
```
### REQ-001 · <一句话标题>
- 需要 tc 改什么：<具体描述>
- 建议位置（t 工程）：<文件/函数>
- 接口形态：<期望的输入/输出/命令>
- 验收标准：<如何验证改对了>
- 关联 IR：IR-x
- 状态：OPEN
```

### REQ-EXT-1 · `--emit-deps` 输出 extended_by 边
- 需要 tc 改什么：在 `sema.emit_deps()`（src/sema.tc:11068）现有 import 边之外，额外输出 extend 边
  `{from:Y, to:X, kind:"extend"}`（Y 为扩展模块、X 为被扩展模块）。
- 建议位置（t 工程）：`src/sema.tc` 的 `emit_deps()`；边数据来源为 overload 合并阶段记录的 extend 关系。
- 接口形态：`tc check --emit-deps --lib-dir <dir> <entry>` 的 JSON 中 `edges[]` 含 `kind` 字段，
  import 边 `kind:"import"`，extend 边 `kind:"extend"`。
- 验收标准：对含跨文件 `extend overload fn` 的同一编译单元，输出 extend 边；tote 据此填 `g_extend_by`。
- 关联 IR：附录「extend 与增量缓存」职责划分
- 状态：OPEN

### REQ-EXT-2 · `build --lib` 接受多文件位置参数
- 需要 tc 改什么：`build --lib` 子命令把所有位置参数（仿 `check` 的 tc.tc:285–291）经 `tc_load_src`
  拼为同一编译单元，而非只吃单个 entry。
- 建议位置（t 工程）：`src/tc.tc` 的 `build` 分支。
- 接口形态：`tc build --lib --mode <m> --output <o> --lib-dir <d> a.tc b.tc ...`。
- 验收标准：多文件调用与「先拼接再单文件」语义等价，且跨文件 `extend overload` 不报 EXTEND_NO_GROUP。
- 关联 IR：R2 多文件编译单元（tc.tc:46–78）
- 状态：OPEN

### REQ-EXT-3 · 跨文件 `extend overload fn` 解析接通（Route 2）
- 需要 tc 改什么：在被扩展模块与扩展模块同单元（`tc_load_src` 拼装）时，把扩展子句并入被扩展模块的
  overload 组；解除当前「`extend overload` 仅限同文件」（错误 `T-OVL-E980 EXTEND_NO_GROUP`）。
- 建议位置（t 工程）：`src/parse.tc`（2770+ extend overload 解析）与 overload 合并（`desugar_func_clauses`）；
  跨文件时同单元内按名合并即自然并入。
- 接口形态：无需新 CLI；依赖 REQ-EXT-2 的多文件同单元。
- 验收标准：a.tc 声明 overload 组、b.tc `extend overload` 同单元并入，`check` 无 EXTEND_NO_GROUP，运行期分发正确。
- 关联 IR：附录「extend 与增量缓存」（区别于 IR-1 的大 extend / 开放类型）
- 状态：OPEN

### 待填写（tote 实现中追加）
<!-- tote 新空间在此写入具体请求 -->
