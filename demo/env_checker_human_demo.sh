#!/usr/bin/env bash

# デモ用スクリプト: それっぽければとりあえず止めて、人の認証を挟むpre-commit フック
# - 一時リポジトリを作成し、pre-commit を導入
# - 違反あり/なし、承認あり/なしの挙動を実演
# 依存: Bash 4+（連想配列使用）, Git

set -euo pipefail
IFS=$'\n\t'
LC_ALL=C

# 表示ユーティリティです。
GREEN='\033[0;32m'; RED='\033[0;31m'; YELLOW='\033[1;33m'; NC='\033[0m'
ok()   { printf "${GREEN}✔ %s${NC}\n" "$*"; }
ng()   { printf "${RED}✖ %s${NC}\n" "$*"; }
info() { printf "${YELLOW}— %s${NC}\n" "$*"; }

# 一時的にリポジトリを作成します。
TMPDIR="$(mktemp -d 2>/dev/null || mktemp -d -t envchecker)"
trap 'rm -rf "$TMPDIR"' EXIT
REPO="$TMPDIR/repo"
mkdir -p "$REPO"
cd "$REPO"

# gitの初期化を行ます
git init -q
git config user.name  "EnvChecker Demo"
git config user.email "demo@example.com"

# pre-commit フック: 違反があれば停止。ただし「承認」があれば警告付きで通過させる。
# 承認手段:
#   - 環境変数 ALLOW_SECRET_COMMIT=1
#   - 承認ファイル .git/secret-approval （内容にレビュア名など残すと良い）
mkdir -p .git/hooks
cat > .git/hooks/pre-commit <<'HOOK'
#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'
LC_ALL=C

# 表示ユーティリティです。
ok() { printf "✔ %s\n" "$*"; }
ng() { printf "✖ %s\n" "$*"; }
sep(){ printf -- "— %s —\n" "$*"; }

# ルールを定義します。
ENV_TEMPLATES_REGEX='(^|/)\.env\.(example|sample|template|dist)(\.|$)'
ENV_VALUE_LINE_REGEX='^\+([A-Z0-9_]+)=(.+)$'
SECRET_FINGERPRINTS='(-----BEGIN [A-Z ]*PRIVATE KEY-----)|((^|[^A-Za-z0-9_])AKIA[0-9A-Z]{16}($|[^A-Za-z0-9_]))|((^|[^A-Za-z0-9_])ghp_[A-Za-z0-9]{36}($|[^A-Za-z0-9_]))|((^|[^A-Za-z0-9_])AIza[0-9A-Za-z_\-]{30,}($|[^A-Za-z0-9_]))|((^|[^A-Za-z0-9_])xox[baprs]\-[A-Za-z0-9\-]{10,}($|[^A-Za-z0-9_]))|((^|[^A-Za-z0-9_])sk_(test|live)_[A-Za-z0-9]{20,}($|[^A-Za-z0-9_]))|(([A-Za-z0-9_\-]{10,})\.([A-Za-z0-9_\-]{10,})\.([A-Za-z0-9_\-]{10,}))|((^|[^A-Za-z0-9_])eyJ[A-Za-z0-9_\-]{10,}\.[A-Za-z0-9_\-]{10,}\.[A-Za-z0-9_\-]{10,}($|[^A-Za-z0-9_]))|((^|[^A-Za-z0-9_])jwt[[:space:]]+[A-Za-z0-9_\-]+\.[A-Za-z0-9_\-]+\.[A-Za-z0-9_\-]+)'
TEXT_EXT_REGEX='\.(env|txt|json|ya?ml|toml|ini|conf|cfg|js|ts|tsx|jsx|php|rb|py|go|rs|java|kt|cs|c|h|cpp|hpp|md)$'
: "${ALLOW_SECRET_COMMIT:=0}"

# 承認確認を行います。
has_approval() {
  # 1) 環境変数による承認
  [[ "${ALLOW_SECRET_COMMIT}" == "1" ]] && return 0
  # 2) 承認ファイルによる承認
  [[ -f ".git/secret-approval" ]] && return 0
  return 1
}

# ヘルパー関数です。
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

# 検査を行います。（各項目 OK/NG を必ず表示）
violations=()
for file in "${STAGED[@]}"; do
  sep "検査対象: $file"

  if [[ "$file" =~ $ENV_TEMPLATES_REGEX ]]; then
    ok "テンプレート .env と判定（検査対象外）"
    continue
  else
    ok "テンプレート .env ではありません"
  fi

  if is_text_like "$file"; then
    ok "テキストとして検査対象です"
  else
    ok "バイナリ/非テキストと判定（検査対象外）"
    continue
  fi

  added="$(git diff --cached -U0 -- "$file" | grep -E '^\+' | grep -vE '^\+\+\+' || true)"
  if [[ -z "$added" ]]; then
    ok "追加行はありません（以降の検査は該当なし）"
    continue
  else
    ok "追加行を検出しました"
  fi

  if [[ "${IS_ADDED[$file]+x}" == "x" || "$file" =~ (^|/)\.env(\.|$) ]]; then
    if grep -Eq "$ENV_VALUE_LINE_REGEX" <<<"$added"; then
      ng ".env に値付き行の追加を検出"
      violations+=(" ${file}: .env に値付き行の追加")
    else
      ok ".env の値付き行の追加はありません"
    fi
  else
    ok ".env 値行チェックの適用対象ではありません"
  fi

  if grep -Eqi "$SECRET_FINGERPRINTS" <<<"$added"; then
    ng "代表的なシークレット指紋に一致"
    violations+=(" ${file}: 代表的なシークレット指紋に一致")
  else
    ok "機密情報の既知パターンに不一致"
  fi

  echo
done

# 結果を表示します。
if ((${#violations[@]} > 0)); then
  if has_approval; then
    echo "検知あり。ただし承認により通過します。"
    printf '   -%s\n' "${violations[@]}"
    # 承認ファイルは使い捨て推奨：存在したら削除します。
    [[ -f .git/secret-approval ]] && rm -f .git/secret-approval || true
    exit 0
  fi
  echo "commit 中止: 機密情報の混入を検出しました"
  printf ' -%s\n' "${violations[@]}"
  echo "※ 承認する場合: 環境変数 ALLOW_SECRET_COMMIT=1 を付けるか、.git/secret-approval を作成して再実行してください。"
  exit 1
fi

echo "検査OKです。"
exit 0
HOOK
chmod +x .git/hooks/pre-commit

# デモ用の最小ケースです。
printf "# Demo Repo\n" > README.md
git add README.md
git commit -m "chore: init" >/dev/null

info "ケースA: 正常（許可される想定）"
echo 'export const ENV = process.env.NODE_ENV;' > index.ts
git add index.ts
git commit -m "feat: add index.ts" && ok "commit 成功（許可）" || ng "commit 失敗（想定外）"
echo

info "ケースB: .env に値を追加（ブロックされる想定）"
printf "API_KEY=secret123\n" > .env
git add .env
git commit -m "feat: add .env with value" && ng "commit 成功（想定外）" || ok "commit 失敗（ブロック想定どおり）"
echo

info "ケースC: 人が承認 → 承認ファイルで通過"
# レビュアが承認した体で承認ファイルを置きます。
echo "approved by Reviewer A" > .git/secret-approval
git commit -m "feat: add .env with value (approved by reviewer)" && ok "commit 成功（承認により通過）" || ng "commit 失敗（想定外）"
echo

info "ケースD: 人が承認 → 環境変数で通過"
printf "DB_PASSWORD=hunter2\n" >> .env
git add .env
ALLOW_SECRET_COMMIT=1 git commit -m "feat: append env value (ALLOW_SECRET_COMMIT=1)" && ok "commit 成功（承認により通過）" || ng "commit 失敗（想定外）"
echo

echo "==================== DEMO SUMMARY ===================="
echo " - ケースA: 許可"
echo " - ケースB: ブロック"
echo " - ケースC: 承認ファイルで通過"
echo " - ケースD: 環境変数で通過"
echo "======================================================"
