# ENV-CHECKER

## 概要
Git コミット時に **機密情報の混入を防ぐ** ための `pre-commit` フック  

特徴

- `.env` ファイルやその派生ファイルへの **値付き行の追加** を検知してブロック
- API Key / Token / 秘密鍵 などの **既知のシークレットパターン検知**
- それっぽければ一旦止める仕様とし、その後、人による承認があれば通過可能
- 承認方法は **環境変数** または **承認ファイル** の 2 種類
- 対象はテキストファイルのみ（バイナリ除外）

---

## ファイル構成

### 1. `env_checker_human.sh`
本番運用用の pre-commit フックスクリプト。  
`.git/hooks/pre-commit` に配置して実行権限を付与することで動作します。

主な機能:
- **ENV ファイル検知**: `.env` およびサブディレクトリの `.env.*` をチェック
- **テンプレート除外**: `.env.example` や `.env.sample` は許可
- **シークレットパターン検知**: AWS Key, GitHub Token, Google API Key, Slack Token, Stripe Key, JWT, PEM 鍵など、追加したくなった時はいくらでも
- **承認モード**:  
  - 環境変数 `ALLOW_SECRET_COMMIT=1`  
  - `.git/secret-approval` ファイルの存在
- **詳細なログ出力**: 各チェック項目の OK/NG を明示

設置手順:
```bash
cp env_checker_human.sh .git/hooks/pre-commit
chmod +x .git/hooks/pre-commit
```

### 2. `env_checker_human_demo.sh`
本番用フックの挙動を確認するための デモスクリプト。
一時的な Git リポジトリを作成し、想定されるケースを自動実行します。

実演されるケース:
- 許可されるコード変更（正常）
- .env に値追加 → ブロック
- .env に値追加（承認ファイルあり） → 通過
- .env に値追加（環境変数承認） → 通過

- **実行例**

```bash
./env_checker_human_demo.sh
```

- **出力例**

```bash
— 検査対象: index.ts —
✔ テンプレート .env ではありません
✔ テキストとして検査対象です
...
✔ commit 成功（許可）

— 検査対象: .env —
✖ .env に値付き行の追加を検出
commit 中止: 機密情報の混入を検出しました
...
```

### 承認方法
検知があっても 人間の判断で通す ことが可能です。

- **方法1: 環境変数で承認**

```bash
ALLOW_SECRET_COMMIT=1 git commit -m "allow secret commit"
```

- **方法2: 承認ファイルで承認**

```bash
echo "approved by Reviewer" > .git/secret-approval
git commit -m "allow secret commit"
# 承認ファイルは自動削除されます
```

## 注意事項
- SECRET_FINGERPRINTS は既知のパターンのみ対応。必要に応じて拡張すること。
- 検出は「それっぽいもの」を対象にしているため、誤検知する場合あり。
- 誤検知でも承認機構で回避可能ですが、承認時には必ず内容の確認を。
