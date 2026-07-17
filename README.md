# EventSource

[Server-Sent Events (SSE)](https://html.spec.whatwg.org/multipage/server-sent-events.html) のクライアント実装（Swift）。WHATWG HTML Standard のイベントストリーム解釈に準拠したパーサと、自動再接続・`Last-Event-ID` の自動送出を備えます。callback ベースの API と、AsyncSequence（`for await`）ベースの API の両方が使えます。

## 対応環境

- Swift 6 (swift-tools-version 6.0) / Swift 6 言語モード（strict concurrency）でビルド
- 利用側は Swift 5 モードでも使用可能
- iOS 15+ / macOS 12+ / tvOS 15+ / watchOS 8+ / visionOS 1+

## インストール (Swift Package Manager)

```swift
dependencies: [
    .package(url: "https://github.com/yisogai/EventSource.git", from: "1.0.0"),
],
```

## 使い方

### callback API

```swift
import EventSource

let config = Configuration(
    headers: ["Authorization": "Bearer ..."],  // 追加ヘッダ
    lastEventId: nil,                           // 再開位置（任意）
    retryTime: 3                                // 再接続間隔の初期値（秒）
)

// init が自動で接続を開始します
let source = EventSource(url: URL(string: "https://example.com/stream")!,
                         configuration: config)

source.onOpen { print("opened") }
source.onMessage { event in
    // type == "message" のイベントのみ
    print(event.data, event.lastEventId ?? "-")
}
source.addEventListener("update") { event in
    // event: update の名前付きイベント
}
source.onError { error in print("error:", error ?? "server closed") }
source.onReadyStateChanged { state in print(state) }

// 終了するとき
source.close()
```

すべてのハンドラは**メインスレッド**で呼ばれます。

### async/await API

```swift
let source = EventSource(url: url, configuration: config)

for await event in source.events {          // 全 type のイベントが流れます
    switch event.type {
    case "message": print(event.data)
    case "update":  handleUpdate(event)
    default:        break
    }
}
// ループを抜けるのは close() されたか、EventSource が解放されたとき
```

`readyState` の変化も同様に購読できます:

```swift
for await state in source.stateChanges { print(state) }
```

#### async API のセマンティクス（重要）

- `events` はアクセスするたびに**独立した購読**を返します（マルチキャスト。複数の `for await` が同時に全イベントを受け取れます）。
- **自動再接続はストリームに対して透過**です。エラーや再接続でストリームは終了しません。終了するのは `close()` を呼んだとき、または EventSource が解放されたときだけです。
- **購読タスクのキャンセルは接続を切りません**。その購読が外れるだけです。接続のライフサイクルは `connect()` / `close()` / deinit が支配します。
- 既定のバッファリングは `.unbounded` で、イベントは欠落しませんが、消費が止まった購読はメモリを消費し続けます。必要なら `events(bufferingPolicy: .bufferingNewest(64))` のように調整してください。
- エラーはストリームには流れません（throwing ではありません）。`onError` または `stateChanges` で観測してください。

## 動作仕様

- **接続**: `init` が自動で `connect()` します。レスポンスが `200 OK` + `Content-Type: text/event-stream` の場合のみ open になります。500/502/503/504 は `retryTime` 経過後に自動再接続し、その他の非 200 や Content-Type 不一致は `EventSourceError.unacceptableResponse` を `onError` に通知して停止します。
- **再接続**: ネットワークエラーやサーバ切断時は `retryTime`（サーバの `retry:` フィールドで変更可能）後に自動再接続し、既知の `Last-Event-ID` をヘッダで送出します。`close()` 後は再接続しません。
- **パーサ**: WHATWG 準拠（CR/LF/CRLF の行終端、コメント行、フィールドごとの規則、先頭 BOM 除去、不正 UTF-8 の U+FFFD 置換）。詳細な準拠内容と旧バージョンからの挙動差分は [BEHAVIOR_CHANGES.md](BEHAVIOR_CHANGES.md) を参照してください。
- **メモリ管理**: 最後の参照を手放すと deinit で接続を閉じます（`close()` の呼び忘れでリークしません）。明示的な `close()` も推奨します。

## v0.0.5 からの移行

公開 API はソース互換（追加のみ）です。ただし SSE 仕様準拠に伴い受信結果が変わるケースがあります。**[BEHAVIOR_CHANGES.md](BEHAVIOR_CHANGES.md) に全差分を旧挙動 → 新挙動の形で列挙**しています。主なもの:

- 非 200 レスポンスや誤った Content-Type で open しなくなった
- コロンなし行・タブ・空の `id:`・負の `retry:` などの解釈が仕様準拠に変わった
- `EventSource` クラスは `@unchecked Sendable` になりました。Swift 6 モードでサブクラス化する場合は Sendable 要件が伝播します

## Example

`EventSource.xcodeproj` の `Example` スキームに iOS のデモアプリがあります（callback / async 両方の使用例）。

## テスト

```sh
swift test
```

WHATWG 仕様から導出したパーサテスト、チャンク分割の全バイト位置総当たり、シード固定 fuzz、URLProtocol モックによる接続ライフサイクルテスト、並行ストレステストを含みます。CI（GitHub Actions）では macOS での `swift test`・Thread Sanitizer・iOS Simulator・tvOS/watchOS/visionOS ビルド・Example ビルドを検証します。

## License

[MIT](LICENSE)
