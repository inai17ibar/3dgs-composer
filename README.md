# 3DGS Composer

動画または複数の写真から 3D Gaussian Splatting (3DGS) を生成する macOS アプリ。

```
動画 ──▶ フレーム抽出（ブレ判定で鮮明なフレームを選択）─┐
写真 ──▶ 取り込み（向き補正・縮小・EXIF 保持）────────┴▶ COLMAP 特徴点抽出 → マッチング → SfM → 歪み補正
                                                          ▶ Brush / OpenSplat で 3DGS 学習（途中経過をライブ表示）
                                                          ▶ .ply / .splat 書き出し・内蔵 Metal ビューア
```

## 必要なもの

- macOS 15 以降（Apple silicon 推奨）
- [COLMAP](https://colmap.github.io/) — `brew install colmap`
- 学習エンジン（どちらか）
  - [Brush](https://github.com/ArthurBrussee/brush/releases)（推奨）— macOS 版の `brush_app` を PATH か任意の場所に置く
  - [OpenSplat](https://github.com/pierotofy/OpenSplat) — Metal (MPS) 対応でビルド
- 任意: [GLOMAP](https://github.com/colmap/glomap)（大量画像の SfM を高速化）

ツールは PATH・`/opt/homebrew/bin`・`/usr/local/bin` から自動検出されます。別の場所にある場合はアプリの「設定」(⌘,) でパスを指定してください。

## ビルド

```sh
# SwiftPM で直接ビルド・起動
swift run GSComposer

# または Xcode プロジェクトを生成
brew install xcodegen
xcodegen generate
open GSComposer.xcodeproj
```

## 使い方

1. 「動画を選択」または「写真を選択」（ウィンドウへのドラッグ＆ドロップも可）
2. 品質プリセット（プレビュー / 標準 / 高品質）と学習エンジンを選ぶ
3. 「3DGS を作成」(⌘↩)
4. 学習中は右側のビューアに途中結果が表示されます。完了後はツールバーの「書き出し」から `.ply`（学習結果そのまま）/ `.splat`（Web ビューア向け）で保存

プロジェクトは `~/Documents/3DGS Composer/<名前>-<日時>/` に作られます。「再学習」でカメラ姿勢推定を再利用し、学習設定だけ変えてやり直せます。

ビューア操作: ドラッグで回転、⌥ドラッグ / 右ドラッグ / 2 本指スクロールで移動、ピンチ / ⌘スクロールでズーム、ダブルクリックでリセット、`F` で上下反転。既存の `.ply` / `.splat` をドロップして表示することもできます。

### 撮影のコツ

- 被写体の周りをゆっくり一周し、隣り合う写真同士が 60〜80% 重なるように撮る
- 露出・ピントを固定し、ブレや反射・透明物を避ける
- 写真なら 50〜200 枚程度、動画なら 30〜90 秒程度が目安

## CLI

同じパイプラインをコマンドラインから実行できます（Linux でも動作）。

```sh
swift run gscomposer-cli run --images ./photos --workspace ./ws --preset preview --trainer-path /path/to/brush_app
swift run gscomposer-cli convert scene.ply scene.splat
swift run gscomposer-cli info scene.ply
```

## 構成

| パス | 内容 |
| --- | --- |
| `Sources/GSComposerCore` | プラットフォーム非依存のコア（PLY/.splat 入出力、COLMAP/学習コマンド生成、進捗解析、パイプライン、深度ソート） |
| `Sources/GSComposer` | SwiftUI アプリ（AVFoundation フレーム抽出、ImageIO 取り込み、Metal 3DGS ビューア） |
| `Sources/gscomposer-cli` | CLI |
| `Tests/GSComposerCoreTests` | コアのユニットテスト (`swift test`) |
| `project.yml` | XcodeGen 設定 |

COLMAP はバージョンによってオプション名が異なる（例: `SiftExtraction.*` → `FeatureExtraction.*`）ため、実行前に `colmap <command> -h` を解析して対応するオプション名でコマンドを組み立てます。
