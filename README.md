# 3DGS Composer

動画または複数の写真から 3D Gaussian Splatting (3DGS) を生成する macOS アプリ。

```
動画 ──▶ フレーム抽出（ブレ判定で鮮明なフレームを選択）─┐
写真 ──▶ 取り込み（向き補正・縮小・EXIF 保持）────────┴▶ COLMAP 特徴点抽出 → マッチング → SfM → 歪み補正
  （iPhone の ARKit 姿勢があれば: 姿勢から選んだペアだけマッチング → 姿勢を固定して三角測量 → バンドル調整）
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
# SwiftPM でビルドし、.app にまとめて起動（build/3DGS Composer.app）
./scripts/run-app.sh

# または Xcode プロジェクトを生成
brew install xcodegen
xcodegen generate
open GSComposer.xcodeproj
```

`swift run GSComposer` でも起動できますが、.app になっていないためボタンやメニューが反応しないことがあります。その場合は `./scripts/run-app.sh` を使ってください。

## 使い方

1. 「動画を選択」または「写真を選択」（ウィンドウへのドラッグ＆ドロップも可）
2. 品質プリセット（プレビュー / 標準 / 高品質）と学習エンジンを選ぶ
3. 「3DGS を作成」(⌘↩)
4. 学習中は右側のビューアに途中結果が表示されます。完了後はツールバーの「書き出し」から `.ply`（学習結果そのまま）/ `.splat`（Web ビューア向け）で保存

### iPhone のカメラ姿勢（ARKit）を使う

[3DGS Material Collector](https://github.com/inai17ibar/3dgs-material-collector-ios) で撮影したフォルダ
（`video.mov` と `manifest.json`）をドロップするか、その中の `video.mov` / `images` を選ぶと `manifest.json` を検出し、
「iPhone で記録したカメラ姿勢を使う」がオンになります。この場合は COLMAP の SfM（カメラ姿勢推定）を行わず、

1. 動画のフレームをセンサーの向きのまま抜き出し、各フレームの時刻の ARKit 姿勢を補間して割り当て（姿勢の記録がない区間のフレームは除外）
2. ARKit の内部パラメータで PINHOLE カメラとして特徴点抽出
3. 視線方向が近い画像のペアだけをマッチング（`matches_importer`。高さの違う周回どうしもつながる）
4. 姿勢を固定して 3D 点を三角測量（`point_triangulator`）し、`bundle_adjuster` で ARKit のわずかなずれを補正

します。「カメラ姿勢を推定できたのは 150 枚中 20 枚のみ」のように SfM が失敗する撮影でも復元でき、重力方向もそろいます。
抽出フレーム数は撮影時間から自動で提案します（1 秒あたり約 1.7 枚。3 分なら約 300 枚）。姿勢のある画像が 3 割未満のときや
縦横比が合わないときは、自動で通常の SfM に切り替わります。`sqlite3`（macOS 標準）を使います。

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
# 既知のカメラ姿勢（KnownPoses JSON。画像名は ws/images 内のファイル名）で SfM を省略
swift run gscomposer-cli run --workspace ./ws --poses ./known_poses.json --video
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
