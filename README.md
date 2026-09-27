# trans-nvim

Neovim 上でコードや Markdown の文章を翻訳し、**元のバッファを変更せず表示だけ追加**する翻訳プラグイン。

翻訳バックエンドには [translate-shell](https://github.com/soimort/translate-shell) の `trans` CLI を使用します。

```cpp
// hello
// i am god
```

`:Trans` を実行すると、バッファはそのままでこう表示されます（`virt_lines` による仮想行）。

```cpp
// hello
// i am god
// こんにちは
// 私は神です
```

## 特徴

- **元のバッファは一切変更しない** — 翻訳結果は `extmark` の `virt_lines` だけに描画される
  - 保存しても翻訳結果は書き込まれない
  - ヤンク・編集の対象にならない
  - 元ファイルを汚染しない
- **Tree-sitter による翻訳対象の検出** — 解析（検出）・翻訳・表示をそれぞれ分離
- **ファイル形式ごとに翻訳単位を最適化**
  - コード: コメントブロック単位（連続した `//` は 1 ブロック、`/* ... */` はブロック全体）
  - Markdown: 見出し・段落・リスト・引用など**意味のある文章単位**（行単位では分割しない）
  - コードブロックなどの翻訳不要な部分は対象外
- **SHA-256 ベースの翻訳キャッシュ** — 同じ文章は 2 度と `trans` を実行しない（セッションを跨いで永続化）
- **バックエンド分離** — `trans` との通信は `translator.lua` の中だけ。差し替え可能

## 必要条件

- Neovim 0.10 以上
- [translate-shell](https://github.com/soimort/translate-shell)（`trans` コマンド）
  - `brew install translate-shell` など
- Tree-sitter パーサー（対象ファイル形式分）
  - コード: `c` / `cpp` など
  - Markdown: `markdown`

## イストール

[lazy.nvim](https://github.com/folke/lazy.nvim) の場合:

```lua
{
  "ryosei/trans-nvim",
  config = function()
    require("trans").setup({
      target = "ja",
    })
  end,
}
```

`setup()` は省略可能です（省略時はデフォルト設定で動作します）。

## 使い方

| コマンド           | 動作                                       |
| ------------------ | ------------------------------------------ |
| `:Trans`           | バッファを翻訳して仮想行を表示             |
| `:TransClear`      | 仮想行を削除                               |
| `:TransToggle`     | 表示中なら削除、非表示なら翻訳             |

## 設定

```lua
require("trans").setup({
  target = "ja",               -- trans の翻訳先 (":ja", "en:ja", "ja:en" なども可)
  cmd = "trans",               -- 翻訳コマンド
  extra_args = { "-b", "-no-ansi" },
  timeout = 10000,             -- 1 行あたりのタイムアウト (ms)
  max_concurrency = 6,         -- 同時に起動する trans プロセス数
  cache = {
    enabled = true,
    path = vim.fn.stdpath("cache") .. "/trans-nvim/cache.json",
  },
  highlight = "TransTranslated", -- 仮想行に使うハイライトグループ
  notify = true,                 -- 完了サマリを通知する
})
```

仮想行の色はデフォルトで `Comment` にリンクされます。

```lua
vim.api.nvim_set_hl(0, "TransTranslated", { fg = "#7f849c" })
```

## 仕組み

```text
コード / Markdown
      ↓
parser/        (Tree-sitter で翻訳対象を検出)
      ↓
翻訳単位 (unit)
      ↓
translator/    (trans CLI に委譲 / cache はここで参照)
      ↓
翻訳結果
      ↓
renderer/      (extmark + virt_lines で描画)
```

### 翻訳単位

**コード** — コメントを Tree-sitter で検出し、単位を生成します。

| 入力                                | 単位                          |
| ----------------------------------- | ----------------------------- |
| `// hello`                          | 単一行コメント                |
| `// hello` / `// i am god`（連続）  | 1 つのコメントブロック        |
| `/* ... */`                         | ブロック全体（内部は行ごとに翻訳） |
| `int x; // trailing`                | 行に食い込むコメントは独立した単位 |

連続したコメントは 1 つのブロックとして扱い、翻訳は**元の改行単位ごと**に行って結果をまとめて表示します。

**Markdown** — 見出し・段落・リスト項目・引用を翻訳単位とします。空行や Markdown の構造を境界として使い、1 行単位では分割しません（折り返された段落は結合してから 1 回だけ翻訳します）。`fenced_code_block` などコードを含むブロックは翻訳対象外です。

### 表示

翻訳結果は `nvim_buf_set_extmark()` の `virt_lines` で描画されます。見えている翻訳行はバッファ上には存在しないため:

- ファイル保存時に翻訳結果は書き込まれない
- コピー・編集の対象にならない
- 元ファイルを汚染しない

翻訳中にバッファが編集された場合は表示を破棄します（行がずれるのを防ぐため）。

### キャッシュ

```text
source text → SHA-256(lang + text) → cache → hit なら trans を呼ばない
```

キャッシュはメモリ上と `stdpath("cache")` 以下の JSON ファイルに保存され、Neovim 再起動後も有効です。

## 構成

Neovim のランタイム規約（`plugin/` は自動読み込み、モジュールは `lua/`）に合わせています。

```text
plugin/
└── trans.lua               # エントリポイント（コマンド登録・デフォルトハイライト）
lua/trans/
├── init.lua                # setup / translate / clear / toggle
├── parser.lua              # 形式ごとに検出器を選択
├── parser/
│   ├── code.lua            # Tree-sitter によるコメント検出 (C/C++ ほか)
│   └── markdown.lua        # 意味のある文章ブロックの検出
├── translator.lua          # trans CLI との通信（バックエンド分離）
├── renderer.lua            # virt_lines による表示
└── cache.lua               # 翻訳キャッシュ
tests/
└── run.lua                 # テストスイート
```

## テスト

```sh
nvim --headless -u NONE -c "luafile tests/run.lua" -c "qa!"
```

キャッシュ・C/C++ コメント検出（単一行 / 連続 / ブロック / 行内）・描画・Markdown 検出・実バックエンドを使った E2E（バッファ非改変・保存されないこと・キャッシュヒット）を検証します。

## MVP からの拡張予定

- [x] C/C++ のコメント検出
- [x] `trans` による翻訳
- [x] `virt_lines` による翻訳結果表示
- [x] 連続コメントの処理
- [x] 基本的なキャッシュ
- [x] Markdown への対応
- [ ] 編集時の自動更新（`TextChanged` / `InsertLeave` など）
- [ ] 翻訳対象言語・バックエンドの切り替え UI
