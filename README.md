# tote

**tote** is the official project build manager for the [t language](https://github.com/tlangroup),
in the spirit of Rust's cargo — but rebuilt from first principles.

It inherits the parts of cargo that are genuinely elegant
(convention over configuration, the manifest as source of truth, reproducibility,
first-class dependencies, a unified CLI) and drops the historical baggage
(`build.rs`, feature unification, `0.x` caret quirks, three-way dependency
split, unlocked libraries, hard-coded registry, externally pinned toolchains).

## The soul differentiator: `extend`

t's `extend` feature makes **the compiler itself a derivable, project-level
build input** — something cargo does not have and can never have.

The core invariant: `extend` always produces a **project-specific variant of
`tc` (`tc'`)**. The root `tc` (the language itself, including `std`) is
**immutable and is never touched by any third-party `extend`**. A variant is a
*derived* artifact of its parent, not a modification of it.

- Because variants are derived rather than mutated, **hermeticity holds
  structurally** (no policy needed): a dependency can never be compiled by this
  project's `tc'`; each dependency is compiled by its own root `tc` / its own
  variant. The root `tc` is never polluted.
- The compiler hooks exposed to `extend` live in `std.tc` as **open enums /
  open variant structs / open structs**. An `extend` module only needs to
  `import std` to override these open types (e.g. the semantics of some operator
  on a given struct type).

> **Status:** the MVP implements the *no-`extend`* path end-to-end. Variant
> derivation (the `[compiler].extend` pipeline) is designed and the seam is in
> place, but is not yet wired up. See `docs/` for the full design.

## What the MVP does

A normal t project (with `path` + `git` dependencies) can be taken from source
to a running executable:

1. Parse `tote.toml` (using tote's own pure-t TOML parser, `src/toml.tc`).
2. Resolve `[dependencies]` / `[dev-dependencies]`.
3. Fetch: `path` deps are used directly; `git` deps are cloned/checked out into
   a content-addressed store (`out/git/<name>`).
4. Compile each dependency into a `.tlib` via `tc build --lib`.
5. Compile the main project, linking against those `.tlib`s, via `tc build`.
6. Emit `tote.lock` (**always committed** — see design decision D10).

An **incremental, content-addressed cache** (FNV-1a keyed on a unit's own
source plus its direct `@import` dependency keys) means a clean rebuild skips
`tc` entirely for unchanged units, and editing a (transitive) dependency
cascades the rebuild correctly.

## Project layout

```
tote/
├── tote.toml              # the manifest (also a self-demonstrating schema)
├── .gitignore             # ignores out/, but never tote.lock
├── src/
│   ├── toml.tc            # pure-t TOML parser (doc-id namespaced)
│   └── tote.tc            # build manager / driver (delegates to tc)
├── tests/
│   ├── toml_test_main.tc  # TOML parser self-test
│   └── fixture/           # end-to-end project (path dep foo→bar, git dep baz)
└── docs/                  # DESIGN, HANDOFF, TC interface requests, cache notes
```

## The manifest (`tote.toml`)

tote follows convention over configuration. The binary target lives at
`src/<name>.tc` (declared as `entry`); `tests/`, `examples/`, `benches/` are
auto-discovered.

```toml
[package]
name        = "app"
version     = "0.1.0"
edition     = "2024"
entry       = "src/main.tc"

[build]
backend = "llvm"        # llvm | c
mode    = "dbg"         # dbg | rls
out_dir = "out"

# Path dependency: a local library
[dependencies.foo]
path    = "./libs/foo"
version = "0.1.0"

# Git dependency (here a local repo stands in for a remote)
[dependencies.baz]
git     = "./_repos/baz"
rev     = "main"

[profile.dev]           # overridable dev profile
opt-level = 0
debug     = true

[profile.release]       # overridable release profile
opt-level = 3
debug     = false
```

Dependency sources in the MVP are **only `path` and `git`** (registry support
is deferred). `tote.lock` is generated and **always committed** so builds are
reproducible.

> **Optional compiler variant.** If a project needs custom compiler semantics,
> declare it and tote triggers a two-step "derived variant" build:
> ```toml
> [compiler]
> extend = "src/extend.tc"   # this project's own tc variant source
> # base   = "tc@0.9"        # optional: pin the root tc version
> ```

## CLI

tote delegates all compilation and linking to `tc` (or, when `[compiler].extend`
is set, to the derived `tc'`).

| Command | Description |
|---|---|
| `tote init` | Scaffold a new project (`tote.toml` + `src/` entry). |
| `tote build` | Resolve, fetch, compile dependencies, and build the project. |
| `tote run` | Build, then run the produced executable. |
| `tote check` | Type-check the project (no codegen). |
| `tote metadata` | Print resolved package + build metadata. |
| `tote clean` | Remove build artifacts. |

## Building tote itself

tote is a normal t project. Build it with the root `tc`:

```sh
tc build --mode rls        # produces out/rls/tote.exe (or out/dbg/tote.exe)
```

tote locates `tc` via, in order: the `TC` environment variable, then
`out/{dbg,rls}/tc.exe` next to tote, then `tc` on `PATH`.

## Tests

- **TOML parser self-test:** `tests/toml_test_main.tc` exercises the parser
  against real and synthetic TOML (dependencies, dev-dependencies, authors,
  floats, dotted keys, sub-tables).
- **End-to-end fixture:** `tests/fixture/` is a full project with a path
  dependency (`foo` → transitive `bar`) and a git dependency (`baz`). After
  `tote build` inside the fixture, `./out/dbg/app.exe` prints
  `foo_add(2,3)=12 / bar_id()=7 / baz_val()=100`.

> The `baz` git dependency source (`tests/fixture/_repos/baz`) is a real git
> repository that is **git-ignored in this repo** to avoid a nested git repo /
> gitlink. Run `tests/fixture/setup.sh` to recreate it before running the
> fixture, so the git-dependency path is reproducible from a clean checkout.

## Design decisions (the "B-series")

A few deliberate choices that differ from cargo:

| Decision | Choice |
|---|---|
| B1 | Code generation via native `comptime` (lower) + `extend` (upper) — replaces `build.rs`. |
| B2 | No features by default; conditionals go through `comptime`. |
| B3 | Unified "leftmost non-zero segment" version rule — replaces `0.x` caret quirks. |
| B4 | Only `normal` / `dev` dependency kinds (`build` folded into `comptime`). |
| B5 | **Always commit `tote.lock`** (libraries are locked too). |
| B6 | `path` / `git` are first-class dependency sources (no registry hard-coding). |
| B7 | Root `tc` is the fixed base; per-project variants via `extend`. |

See `docs/design/DESIGN.md` for the complete rationale, and
`docs/TC_INTERFACE_REQUESTS.md` for the interface changes requested from the
`tc` side.

## License

MIT — see `tote.toml` (`license = "MIT"`).
