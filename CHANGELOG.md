# Changelog

このプロジェクトは [Semantic Versioning](https://semver.org/lang/ja/) に従います。

## [1.0.0] - 2026-07-17

2017 年の初版以来の大規模メンテナンス。公開 API はソース互換（追加のみ）ですが、SSE 仕様準拠に伴い受信結果が変わるケースがあります。**全挙動差分は [BEHAVIOR_CHANGES.md](BEHAVIOR_CHANGES.md) を参照してください。**

### Added
- AsyncSequence ベースの API: `events` / `stateChanges`（マルチキャスト、再接続透過、`for await` で購読）
- `EventSourceError.unacceptableResponse` — HTTP レスポンス検証失敗の通知
- テスト用 DI: `init(url:configuration:sessionProvider:)` の第3引数（省略可）
- `MessageEvent` の public init と `Equatable`/`Sendable`、`Configuration` プロパティの公開と `Sendable`、`ReadyState` の `Sendable`
- テストスイート 68 件（WHATWG 仕様テスト・チャンク分割全バイト位置総当たり・シード固定 fuzz・URLProtocol モック統合・並行ストレス）
- GitHub Actions CI（macOS テスト / Thread Sanitizer / iOS Simulator テスト / tvOS・watchOS・visionOS ビルド / Example ビルド）

### Changed
- swift-tools-version 6.0 / Swift 6 言語モード（strict concurrency）へ移行、SPM 標準レイアウト化
- 対応プラットフォームを iOS 15+ / macOS 12+ / tvOS 15+ / watchOS 8+ / visionOS 1+ に拡張
- パーサを WHATWG Server-sent events 準拠のバイトベース行パーサへ全面書き換え
- HTTP レスポンス検証を追加（200 + `text/event-stream` のみ open。5xx は自動再接続、他は失敗）
- delegate コールバックを直列化し、全共有状態をロック保護

### Fixed
- URLSession の delegate 強参照によるインスタンスリーク（`close()` 忘れで解放されない問題）
- 稼働中の `connect()` 呼び出しで旧セッションのキャンセル完了が新接続を破壊し、以後のイベントを取りこぼす問題（v0.0.5 以前から存在）
- 改行スタイル混在時のイベント境界誤検出、U+2028/U+2029 によるデータ欠落、不正 UTF-8 でのイベント丸ごと破棄 ほか（詳細は BEHAVIOR_CHANGES.md）

## [0.0.5] - 2025-04-10
- Swift Package Manager 対応（Package.swift 追加）、Xcode プロジェクトのフォルダ構成化

## [0.0.4] - 2023-11-09
- Swift 5 へ更新、iOS Deployment Target を 15 に引き上げ

## [0.0.3] - 2018-02-07
- 絵文字を含むイベントのカウント問題を修正

## [0.0.2] - 2017-12-07
- Example の修正

## [0.0.1] - 2017-12-07
- 初版（iOS 向け SSE クライアント）
