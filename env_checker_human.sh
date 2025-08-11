#!/usr/bin/env bash

# pre-commit hook
# 目的: それっぽい機密が混入した場合、コミットを一旦停止し、人の承認がある場合のみ通過させるようにすること。
# 承認手段:
#   1) 環境変数 ALLOW_SECRET_COMMIT=1 を付けて commit 実行します。
#   2) .git/secret-approval ファイルを作成して commit 実行します。（使い捨てを推奨）
# 依存: Bash 4+ / Git

set -euo pipefail
IFS=$'\n\t'
LC_ALL=C

# 表示ユーティリティです。
ok()  { printf "✔ %s\n" "$*"; }
ng()  { printf "✖ %s\n" "$*"; }
sep() { printf -- "— %s —\n" "$*"; }

# ルールを定義します。
ENV_FILE_REGEX='(^|/)\.env($|(\.|/))'
ENV_TEMPLATES_REGEX='(^|/)\.env\.(example|sample|template|dist)(\.|$)'
ENV_VALUE_LINE_REGEX='^\+([A-Z0-9_]+)=(.+)$'
SECRET_FINGERPRINTS='(-----BEGIN [A-Z ]*PRIVATE KEY-----)|((^|[^A-Za-z0-9_])AKIA[0-9A-Z]{16}($|[^A-Za-z0-9_]))|((^|[^A-Za-z0-9_])ghp_[A-Za-z0-9]{36}($|[^A-Za-z0-9_]))|((^|[^A-Za-z0-9_])AIza[0-9A-Za-z_\-]{30,}($|[^A-Za-z0-9_]))|((^|[^A-Za-z0-9_])xox[baprs]\-[A-Za-z0-9\-]{10,}($|[^A-Za-z0-9_]))|((^|[^A-Za-z0-9_])sk_(test|live)_[A-Za-z0-9]{20,}($|[^A-Za-z0-9_]))|(([A-Za-z0-9_\-]{10,})\.([A-Za-z0-9_\-]{10,})\.([A-Za-z0-9_\-]{10,}))|((^|[^A-Za-z0-9_])eyJ[A-Za-z0-9_\-]{10,}\.[A-Za-z0-9_\-]{10,}\.[A-Za-z0-9_\-]{10,}($|[^A-Za-z0-9_]))|((^|[^A-Za-z0-9_])jwt[[:space:]]+[A-Za-z0-9_\-]+\.[A-Za-z0-9_\-]+\.[A-Za-z0-9_\-]+)'
TEXT_EXT_REGEX='\.(env|txt|json|ya?ml|toml|ini|conf|cfg|js|ts|tsx|jsx|php|rb|py|go|rs|java|kt|cs|c|h|cpp|hpp|md)$'
: "${ALLOW_SECRET_COMMIT:=0}"

# 承認確認を行います。
has_approval() {
  [[ "${ALLOW_SECRET_COMMIT}" == "1" ]] && return 0
  [[ -f ".git/secret-approval" ]] && return 0
  return 1
}

# ヘルパー: テキスト類の判定（拡張子 or diff先頭が Binary でない）
is_text_like() {
  local path="$1"
  [[ "$path" =~ $TEXT_EXT_REGEX ]] && return 0
  git diff --cached -- "$path" | head -n 1 | grep -q 'Binary files' && return 1
  return 0
}

# 収集を行います。
STAGED=()
while IFS= read -r -d '' f; do STAGED+=("$f"); done \
  < <(git diff --cached --name-only -z --diff-filter=ACMR)

declare -A IS_ADDED=()
while IFS= read -r -d '' f; do [[ -n "$f" ]] && IS_ADDED["$f"]=1; done \
  < <(git diff --cached --name-only -z --diff-filter=A || true)

# セキュリティチェックを行います。（各項目の OK/NG を必ず出す）
violations=()
for file in "${STAGED[@]}"; do
  sep "確認対象: $file"

  if [[ "$file" =~ $ENV_TEMPLATES_REGEX ]]; then
    ok "テンプレート .env と判定（確認対象外）"
    continue
  else
    ok "テンプレート .env ではありません"
  fi

  if is_text_like "$file"; then
    ok "テキストとして確認対象です"
  else
    ok "バイナリ/非テキストと判定（確認対象外）"
    continue
  fi

  added="$(git diff --cached -U0 -- "$file" | grep -E '^\+' | grep -vE '^\+\+\+' || true)"
  if [[ -z "$added" ]]; then
    ok "追加行はありません（以降の確認は該当なし）"
    continue
  else
    ok "追加行を確認しました"
  fi

  if [[ "$file" =~ $ENV_FILE_REGEX ]]; then
    if grep -Eq "$ENV_VALUE_LINE_REGEX" <<<"$added"; then
      ng ".env に値付き行の追加を確認"
      violations+=(" ${file}: .env に値付き行の追加")
    else
      ok ".env の値付き行の追加はありません"
    fi
  else
    ok ".env 値行確認の適用対象ではありません"
  fi

  if grep -Eqi "$SECRET_FINGERPRINTS" <<<"$added"; then
    ng "代表的なシークレットパターンに一致"
    violations+=(" ${file}: 代表的なシークレットパターンに一致")
  else
    ok "機密情報の既知パターンに不一致"
  fi

  echo
done

# 結果を出力します。
if ((${#violations[@]} > 0)); then
  if has_approval; then
    echo "機密情報の混入を検出しました。ただし承認により通過"
    printf '   -%s\n' "${violations[@]}"
    [[ -f .git/secret-approval ]] && rm -f .git/secret-approval || true
    exit 0
  fi
  echo "commit 中止: 機密情報の混入を検出しました。"
  printf ' -%s\n' "${violations[@]}"
  echo "※ 承認する場合: ALLOW_SECRET_COMMIT=1 を付けて再実行、または .git/secret-approval を作成してください。"
  exit 1
fi

echo "セキュリティチェック終了 - 問題なし"
exit 0
