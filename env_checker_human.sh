#!/usr/bin/env bash

# pre-commit hook
# 目的: それっぽい機密が混入した場合、コミットを一旦停止し、人の承認がある場合のみ通過させるようにすること。
# 承認手段:
#   1) 環境変数 ALLOW_SECRET_COMMIT=1 を付けて commit 実行します。
#   2) .git/secret-approval ファイルを作成して commit 実行します。（使い捨てを推奨）
# 依存: Bash 4+ / Git

# ================================================
# 個人レビューのメモ
#
# ルールの“過検知/過小検知”
# ENV_VALUE_LINE_REGEX='^\+([A-Z0-9_]+)=(.+)$' は
# 小文字キー（db_password=）を見逃す
# 先頭/末尾スペース・export KEY=...・値が空/引用符/継続行（\）を見逃す
# JWT 検出は広めの base64 断片で誤検知しがち（テストデータやドキュメントの例文までヒットする）
# grep -Eqi "$SECRET_FINGERPRINTS" の -i は余計かな？
# 個別トークンごとに大/小区別を決め、基本は -Eq かな？
#
# パフォーマンス懸念
# 各ファイルごとに git diff … | grep を2回実行しており、大きいコミットで遅くなる
# 大容量テキスト（ログ等）での全行スキャンは重い
#
# バイナリ判定の頑健性
# git diff … | head -n 1 | grep -q 'Binary files' 頼りは diff 表示仕様に依存
#
# 例外/許可の運用
# .git/secret-approval は承認ログが残らない（誰が/いつ/何に対して承認したか不明）
# 便利な一方で組織ポリシー上「環境変数でバイパス」は嫌われがち
#
# 対象ファイル範囲の設計
# TEXT_EXT_REGEX は拡張子網羅してるが、最終行 return 0 があるため「拡張子に該当しなくてもバイナリでなければ検査対象」になっている
# .env.* は ENV_FILE_REGEX で拾えるが、env.local.example はテンプレとみなす？例外ルールの明文化が必要
#
# 差分だけ検査する方針
# 既存の秘密がリポジトリ内に残存していても、差分がなければ通す設計
#
# メッセージと UX
# どの正規表現にヒットしたのかが出ない（「代表的なシークレットパターンに一致」だけ）
# 提案：ヒット種別を表示（AWS、GitHub Token、JWT など）。grep -o -E でサンプルの一部をマスク表示
# “どの行が原因か” 1–2行だけ抜粋があると素早く修正できる
#
# 保守性/テスタビリティ
# 巨大な1ファイルにロジック＋ルールが直書き
# ================================================

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
