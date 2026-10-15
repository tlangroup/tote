# tote — t 语言项目构建管理器 · 设计

> 状态：**阶段一·设计稿（待用户确认过闸门①）**
> 定位：类似 Rust 的 cargo，但从第一性原理重做，贯彻 cargo 设计精神、抛弃其历史包袱。
> 关键差异化：t 语言的 `extend` 特性让**编译器本身成为可派生的工程级构建输入**——这是 cargo 完全没有的能力。

---

## 1. 背景与目标

- t 是一个自托管编译器（`src/tc.tc`，C + LLVM 双后端），已有 `tote.tc` 作为薄 driver：把 `build/run/check/...` 转发给 `tc`、注入 lib 搜索路径、用字符串扫描硬抠 `entry`/`deps`。
- 现有 tote 缺的是 cargo 形状的**另一半真功夫**：依赖解析、lockfile、fetch、真正的构建图。
- 目标：从基础重做 tote，使其成为 t 的官方项目构建管理器——约定优于配置、声明式清单、可复现构建、依赖一等公民、统一 CLI，并且在 `extend` 这一 t 独有特性上做出 cargo 做不到的架构。

**设计原则（总纲）**：凡是 cargo 因历史包袱而别扭的地方，一律重新设计；凡是 cargo 真正优雅的精神（约定、清单即真相、可复现、统一接口），原样继承。

---

## 2. 设计哲学

### 2.1 继承的 cargo 精神（要保留）

| 精神 | 含义 |
|---|---|
| 约定优于配置 | 目录即配置。`src/` 放库，`src/bin/`、`tests/`、`examples/`、`benches/` 自动发现，不列文件清单。 |
| 单一声明式清单 | `tote.toml` 是真相源；`tote.lock` 钉版本。 |
| 可复现构建 | lockfile + 内容寻址缓存 + 确定性解析。 |
| 依赖一等公民 | 声明式版本区间 + 解析 + 锁文件 + 多源（path / git / registry）。 |
| 统一 CLI | `build/test/run/doc/check` 到处可用，行为一致。 |
| Profiles | `dev` / `release` 可覆盖（opt-level、debug 等）。 |
| Workspace | 多包共享一个 lockfile。 |

### 2.2 丢弃的 cargo 包袱（及替代）

| # | cargo 包袱 | tote 的替代 |
|---|---|---|
| B1 | **`build.rs` 任意脚本**：难沙箱、难缓存、拖慢构建、不可复现 | 由两层**原生机制**取代——`comptime`（编译期内计算/代码生成，下层）+ `extend`（改写编译器自身语义，上层）。无 shell 逃逸、可哈希缓存。 |
| B2 | **feature unification 地狱**：同一 feature 开启会全局影响所有依赖的解析 | 默认**无 feature**；条件编译走 `comptime`。如未来引入 feature，则必须是**加性（additive）且按依赖独立解析**，绝不做全局统一。 |
| B3 | **0.x 的 caret 怪癖**：`^0.2.3`→`<0.3.0`，但 `^0`→`<1.0.0`，跨度不一致 | **统一 caret 规则**：caret 永远作用于"最左非零版本段"。`^0` 表示 `<0.1.0`（与 `^0.2` 一致），不再跨越到 `<1.0.0`。 |
| B4 | **normal / dev / build 三重依赖分裂** | 合并 `build` 进 `comptime`，只留 **normal / dev** 两重。 |
| B5 | **库不强制 lockfile**（应用提交、库不提交，造成不一致） | **永远提交 `tote.lock`**，库与应用一视同仁。 |
| B6 | **registry 硬编码 crates.io** | registry 只是若干源之一；**path / git 一等公民**，registry 可后置。 |
| B7 | **工具链外部固定**（`rust-toolchain.toml` 是半吊子方案） | 根 tc 是固定、可版本钉定的基础（其来源 / bootstrap 是独立问题，MVP 用已知 seed）；但**可扩展面在 `std.tc`**——tc 把对外暴露的编译器钩子移入标准库（开放枚举 / 开放变量体 / 开放结构体），`extend` 只需 `import std` 即可改写这些开放类型（见 §3.2）。无需把 tc 当包来管理内部。 |

---

## 3. 核心不变式：extend 与派生变体（tote 的灵魂）

> **不变式（Invariant）**：`extend` 永远只产出"**本工程专属的 tc 变体（variant）**"；**根 tc 不可变、永不被任何第三方 extend 触碰**。变体与其父（根 tc）是**派生关系，不是修改关系**。

依据用户澄清：`extend` 未来范围很广——可扩展 tc 编译库的**开放枚举、开放变量体（open variant body）、开放结构体**。但无论扩展多深，第三方 extend **只生成一个适应本工程的 tc 变体**，绝不回写根 tc。

**这一不变式的架构威力**：因为变体在机制上是"派生"而非"修改"，**hermetic（封闭性）是结构性成立、无需政策强制的**——

- 依赖永远不可能被本工程的 tc 变体编译（依赖各由"自己的根 tc / 自己的变体"编译）；
- 根 tc 永远不被污染；
- 多工程的变体是根 tc 的兄弟派生，彼此隔离。

这直接消弭了 cargo 世界里"全局 feature 影响依赖"那类问题：在我们的模型里它**在结构上不可能发生**。

### 3.1 派生变体构建流水线

```
root tc（语言本身，含 std，不可变基础）
  ├─ 项目P: extend 模块 ──(root tc 编译)──► tc_P'  变体
  │     └─ tc_P' 编译 P 自身源码      ──► 制品
  ├─ 依赖D: 各自 extend ──(root tc 编译)──► tc_D'  变体
  │     └─ tc_D' 编译 D 自身源码      ──► .tlib（供 P 链接）
  └─ 无 extend 的包：直接用 root tc 编译
```

要点：
- **两阶段**：第一阶段用 root tc 编译 "extend 模块" → 得到 `tc_P'`；第二阶段用 `tc_P'` 编译本工程自身代码。
- **鸡生蛋规则**：extend 模块本身（及它的依赖）必须由 **root tc** 编译——因为 `tc_P'` 此时尚未存在。extend 模块使用编译器内部 API，不属于"本工程普通 target"。
- **变体缓存**：`tc_P'` 按 `(root tc 版本 + extend 源码)` 的内容哈希缓存（见 §5），切换工程/extend 零成本，且天然增量。
- **绝大多数工程无 extend**：缺省直接用 root tc，无两阶段，与 cargo 一样简单。

### 3.2 extend 的实现机制：std.tc 中的开放类型

用户指定：**tc 把需要对外暴露的编译器钩子移入 `std.tc`**（标准库）。这些钩子以**开放枚举 / 开放变量体（open variant body）/ 开放结构体**的形式声明在 std 中。`extend` 模块只需 `import std`，然后向这些开放类型追加变体 / 字段 / 子句，即可改变 tc 的行为（例如某结构体类型某运算符的语义）。

由此：
- **extend 不需要把 tc 当包依赖**：可扩展面是 std（标准库，始终可用），extend 只是普通的"对 std 开放类型做扩展"。
- **根 tc 仍是固定、可钉版本的基础**：其二进制来源（seed / 发行）是 bootstrap 层面的独立问题；但"改写编译器行为"这件事完全通过 std 的开放类型表达，与 tc 内部实现解耦。
- 这与 §3 不变式一致：extend 产出的是"导入了扩展后 std 的 tc 变体"，根 tc（及其原始 std）永不被修改。

---

## 4. 架构分层

```
┌─────────────────────────────────────────────┐
│ CLI 层   new/init build run test check doc …  │
├─────────────────────────────────────────────┤
│ Scheduler  增量（内容哈希缓存）+ 并行，调 tc   │
├─────────────────────────────────────────────┤
│ Build Graph 包内 target + 依赖；每 target 单元 │
├─────────────────────────────────────────────┤
│ Fetcher   path 软链 / git checkout / registry  │
│           → 物化进内容寻址 store               │
├─────────────────────────────────────────────┤
│ Resolver  manifest + lock → 精确版本图          │
│           → 写/更新 tote.lock                  │
├─────────────────────────────────────────────┤
│ Manifest  tote.toml（需真正的 TOML parser；     │
│           替换现有字符串扫描 hack）             │
└─────────────────────────────────────────────┘
```

- **tote 自身不实现编译器**：它把 lex/check/compile/emit/link 全部委托给 tc（或其派生变体）。tote 的职责是"包 + 构建编排"。
- **真正的 TOML parser**：现有 `tote.tc` 的 `toml_string_value` / `deps_start` 字符串扫描是 hack，必须替换为一次性、正确的 TOML 解析（t 已有/将有一个 TOML 库，或 tote 内置最小 parser）。

---

## 5. 构建流水线细节

1. **解析清单**：读 `tote.toml`，得到 package / compiler / dependencies / profile。
2. **解析依赖图**：结合 `tote.lock`（若有）解析出每个依赖的精确版本与源 → 必要时更新 `tote.lock`。
3. **物化依赖**：path → 软链；git → checkout 到内容寻址 store；registry → 下载（后置）。
4. **派生编译器（若声明 extend）**：用 root tc 编译 `extend` 模块 → 得到 `out/compiler/<hash>/tc'`。hash = `H(root_tc_version, extend_source)`。
5. **编译依赖**：用 root tc（或依赖各自的变体）把每个依赖编译为 `.tlib`，缓存。
6. **编译本工程 target**：用 `tc'`（或 root tc）编译本工程自身 lib/bin/test → 制品。
7. **链接 / 运行 / 测试**：按 target 类型执行。

**增量粒度（待决，推荐 target 级）**：每个 bin/lib 作为整体由 tc 一次性编译，复用依赖的 `.tlib`；tc 自身已有模块级 `.tlib` 缓存，故 tote 的增量主要来自"依赖 .tlib 未变则跳过" + "变体哈希命中则跳过"。模块级制品缓存（每 `.t`→obj 全并行）更快但需 tc 暴露逐模块 emit，MVP 不做。

---

## 6. 清单格式 `tote.toml`（schema 草案）

```toml
[package]
name        = "myapp"      # 必填，包唯一标识
version     = "0.1.0"      # 语义化，采用 §2.2-B3 的干净 caret 规则
edition     = "2026"       # 可选，语言 edition（按需引入）
description = "..."
license     = "MIT"
authors     = ["seesaw"]
entry       = "src/main.tc" # 二进制入口（约定优于配置，可省略）

[compiler]                 # 可选；缺省=直接用 root tc，无变体派生
extend = "src/extend.tc"   # 声明本项目 extend 模块 → 触发派生变体
# base   = "tc@0.9"        # 可选：指定根 tc 版本（默认解析最新兼容）

[dependencies]             # 进入制品的普通依赖（源以前缀区分）
"path:./libs/foo"  = "1.0"
"git:https://github.com/x/y" = "rev:abc123"
"tote:serde"       = "1.2" # registry 源（MVP 后置）

[dev-dependencies]         # 仅 test/bench/examples 需要（无 build-deps，见 B4）

[build]
backend = "llvm"           # llvm | c
mode    = "rls"            # rls | dbg
out_dir = "out"

[profile.dev]              # 可覆盖
opt-level = 0
debug     = true
[profile.release]
opt-level = 3
debug     = false

[scripts]                  # 可选 comptime 代码生成（取代 build.rs，见 B1）
gen = "build.tc"           # 沙箱化、按内容哈希缓存
```

**源前缀约定**：`path:` / `git:` / `tote:`（registry）内联在依赖键上，避免引入复杂的嵌套表语法；MVP 仅实现 `path` + `git`。

---

## 7. 依赖模型

- **源**：`path`（本地目录，软链）、`git`（指定 rev/branch/tag，checkout 到内容寻址 store）、`tote`（registry，后置）。
- **解析**：给定 manifest 的版本区间 + lock（若有）→ 选出精确版本。确定性、可复现。
- **锁文件**：`tote.lock` 永远提交（B5）。记录每个依赖的精确版本 + 源 + 内容哈希。
- **版本规则**：采用 §2.2-B3 的统一 caret（最左非零段），消除 0.x 怪癖。
- **feature**：默认无（B2）。条件代码走 `comptime`。如未来引入，必为加性 + 按依赖独立解析。

---

## 8. Target 分类

| target | 目录（约定） | 说明 |
|---|---|---|
| library | `src/lib/*.tc` 或 `src/<name>.tc` | 库，产出 `.tlib` |
| binary | `src/main.tc` / `src/bin/*.tc` | 可执行，含 `@main` |
| test | `tests/` | `check` + 运行；dev-deps 可见 |
| example | `examples/` | 可运行示例（`.tc` + 同名 `.expected.txt`） |
| bench | `benches/` | 基准测试 |
| plugin | `src/plugin/*.tc` 或 `[compiler].extend` | t 特有的 `@pass`/`@desugar` 代码生成插件 / extend 变体源 |

---

## 9. CLI 命令集

| 命令 | 作用 |
|---|---|
| `tote new <name>` / `init` | 生成 `tote.toml` + `src/main.tc` 骨架 |
| `tote build [target]` | 构建（无 target 取 entry）；自动处理变体派生 |
| `tote run [target]` | 构建并运行 |
| `tote test` | 跑 `tests/` |
| `tote check` | 仅类型检查（不生成代码） |
| `tote doc` | 生成文档 |
| `tote clean` | 清 `out/` |
| `tote update` | 更新依赖 / 重写 lock |
| `tote add <dep>` / `remove <dep>` | 登记/移除依赖 |
| `tote bench` | 跑 `benches/` |
| `tote metadata` | 输出构建图（JSON），供 IDE / 工具消费 |
| `tote compile/emit-ll/lex/deps` | 透传给 tc 的底层命令（兼容现有 driver 行为） |

---

## 10. 与 cargo 的关键差异（总表）

| 维度 | cargo | tote |
|---|---|---|
| 工具链 | 外部固定 rustc（`rust-toolchain.toml` 半吊子） | 根 tc 是包；`extend` 派生 per-project 变体 |
| 编译期代码生成 | `build.rs` 任意脚本 | `comptime`（下层）+ `extend`（上层），无 shell 逃逸 |
| feature | 全局 unification 地狱 | 无 feature；条件走 `comptime`；引入则加性+独立 |
| 版本规则 | 0.x caret 怪癖 | 统一最左非零段 |
| 依赖分类 | normal/dev/build 三重 | normal/dev 两重（build 并入 comptime） |
| lockfile | 库可选 | 永远提交 |
| registry | 硬编码 crates.io | 仅是若干源之一，path/git 一等 |

---

## 11. 待决项清单

| 项 | 问题 | 原因 | 影响 | 建议选项 | 状态 |
|---|---|---|---|---|---|
| D1 | extend 在 tote.toml 怎么声明 | 需显式、可选、不污染 package 段 | 影响清单 schema | `[compiler] extend = "src/extend.tc"`（推荐） | **已决（推荐）** |
| D2 | extend 的可扩展面如何对外部暴露 | tc 内部钩子须可被子项目改写 | 影响 extend 机制与 base 来源 | 对外暴露的编译器钩子移入 `std.tc`（开放枚举 / 变量体 / 结构体）；`extend` 只需 `import std` 改写这些开放类型，无需把 tc 当包。根 tc 仍是固定、可钉版本的基础（bootstrap 来源独立，MVP 用已知 seed） | **已决（用户指定）** |
| D3 | 变体缓存位置 | 切换工程零成本 | 影响 out/ 布局 | 内容寻址 `out/compiler/<hash>/tc'`（推荐） | **已决（推荐）** |
| D4 | 依赖是否被 tc' 编译 | hermetic 边界 | 影响可复现/安全 | 结构性不可能（不变式已决）：依赖各由 root tc / 自身变体编译 | **已决（不变式）** |
| D5 | extend 模块鸡生蛋 | bootstrap 顺序 | 影响流水线 | extend 模块及其依赖由 root tc 编译（推荐） | **已决（推荐）** |
| D6 | MVP 依赖源 | 从基础开始 | 影响 MVP 范围 | 仅 path + git，registry 后置（推荐） | **已决（采纳推荐）** |
| D7 | feature 模型 | 避免 unification 地狱 | 影响依赖语义 | 无 feature，条件走 comptime（推荐） | **已决（推荐）** |
| D8 | comptime 代码生成机制 | 取代 build.rs | 影响 scripts 设计 | `build.tc` 沙箱 comptime 脚本（推荐） | **已决（推荐）** |
| D9 | 增量粒度 | 构建速度 vs 复杂度 | 影响 Scheduler | target 级（推荐）；模块级后置 | **已决（采纳推荐）** |
| D10 | lockfile 策略 | 一致性 | 影响仓库约定 | 永远提交（推荐） | **已决（推荐）** |
| D11 | 干净版本 caret 具体规则 | 消除 0.x 怪癖 | 影响解析器 | 统一最左非零段（见 §2.2-B3） | **已决（推荐）** |

---

## 12. MVP 范围与任务规划（指向闸门②）

**MVP（建议）**：
1. 真正的 TOML parser（替换字符串扫描 hack）。
2. 清单 schema v1（`[package]` / `[dependencies]` path+git / `[build]` / `[profile]`）。
3. Resolver + `tote.lock`（永远提交）。
4. Fetcher（path 软链 + git checkout 到内容寻址 store）。
5. 变体派生流水线（若 `[compiler].extend`）。
6. Scheduler（target 级增量 + 并行，调 tc）。
7. CLI：`new/init/build/run/test/check/clean/update/add/remove/metadata`。
8. 约定优于配置目录发现（src/bin/tests/examples/benches）。

**任务规划**：过闸门①后，按 `docs/AGENT_WORKFLOW.md` 阶段二，逐节点确认流程图（依赖解析→fetch→变体派生→编译→链接→测试），不一次性跑完。

---

## 13. 示例与测试代码评审（草案）

### 13.1 普通工程（无 extend）

`tote.toml`：
```toml
[package]
name = "hello"
version = "0.1.0"
entry = "src/main.tc"
[dependencies]
"path:../libs/greet" = "1.0"
```
`src/main.tc`：
```t
main fn() -> i32 @main {
    println("hello from tote");
    return 0;
}
```
运行：`tote run` → 用 root tc 编译 `src/main.tc` + 依赖 `greet` → 执行。

### 13.2 带 extend 的工程（派生变体）

`tote.toml`：
```toml
[package]
name = "phys"
version = "0.1.0"
entry = "src/main.tc"
[compiler]
extend = "src/extend.tc"
```
`src/extend.tc`（概念示意——向编译器开放类型追加语义）：
```t
// 扩展编译库的开放结构体 / 开放枚举 / 开放变量体
// （具体 extend 语法随 t 语言 extend 特性落地而确定）
extend struct Vec3 { fn len(self) f64 { ... } }
```
构建：`tote build` → root tc 编译 `src/extend.tc` → `out/compiler/<hash>/tc'` → `tc'` 编译 `src/main.tc` → 制品。本工程以外的依赖仍由 root tc 编译，互不污染。

> 注：13.2 的 extend 语法为**概念示意**，待 t 语言 extend 特性正式语法确定后回填；tote 侧只需消费 `[compiler].extend` 指向的模块路径。

---

## 14. 偏离记录（编码阶段追加）

| 子任务 | 偏离描述 | 合理性 | 处置 |
|---|---|---|---|
| （空） | | | |
