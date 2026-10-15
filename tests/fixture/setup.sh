#!/usr/bin/env bash
# 重建 tote fixture 的 git 依赖源仓库 (tests/fixture/_repos/baz)。
# 该目录被 .gitignore 排除（避免在主仓库里嵌套 git 仓库 / gitlink），
# 此处按需重新生成为一个真实 git 仓库，供 tote 的 git 依赖端到端测试 clone。
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
BAZ="$ROOT/_repos/baz"

if [ -d "$BAZ/.git" ]; then
  echo "baz repo already exists, skip."
  exit 0
fi

rm -rf "$BAZ"
mkdir -p "$BAZ/src"

cat > "$BAZ/tote.toml" <<'EOF'
[package]
name = "baz"
version = "0.2.0"
entry = "src/baz.tc"
EOF

cat > "$BAZ/src/baz.tc" <<'EOF'
@module(pub)

// 注意：返回整数而非字符串字面量，避免 LLVM 后端把字符串符号(.tirll_tstr0)
// 编进每个 .tlib，导致多模块链接时符号重复定义（t 编译器已知限制）。
pub fn baz_val() i32 {
    return 100;
}
EOF

git init -q "$BAZ"
git -C "$BAZ" add -A
git -C "$BAZ" commit -q -m "baz v0.2.0"
echo "created baz git repo at $BAZ"
