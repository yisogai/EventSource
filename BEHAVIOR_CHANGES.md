# 挙動差分カタログ（v0.0.5 → 本メンテナンス）

このドキュメントは、WHATWG HTML Standard の [Server-sent events](https://html.spec.whatwg.org/multipage/server-sent-events.html) 仕様への準拠修正・並行性修正で**観測可能な挙動が変わった箇所**の完全な一覧です。各差分はテストと 1:1 で対応します（テスト名 `spec_<領域>_<条件>_was<旧>_now<新>`、`Tests/EventSourceTests/`）。

## パーサ（EventBuffer）

| # | 対象 | 旧挙動 (v0.0.5) | 新挙動 | 対応テスト |
|---|---|---|---|---|
| (a) | 先頭 BOM | `String(data:encoding:)` の副作用で偶然除去されていた | バイトレベルで意図的にストリーム先頭の BOM (EF BB BF) を1回だけ除去。チャンク分割された BOM も正しく処理。2個目以降は本文扱い | `leadingBOM_isStrippedOncePerStream`, `leadingBOM_splitAcrossChunks_isStillStripped`, `secondBOM_isNotStripped` |
| (b) | 改行スタイル混在時の境界 | 固定優先順位（`\r\n\r\n` → `\n\n` → `\r\r`）の区切り検索で、混在時に境界を誤検出。例: `data: a\n\rdata: b\n\n` → 1イベント `"a\nb"` | 仕様通り CR/LF/CRLF を行単位で解釈し、空行で dispatch。同入力 → 2イベント `"a"`, `"b"` | `spec_boundary_mixedLFCR_wasJoined_nowTwoEvents` |
| (c) | コロンなし行 | 正規表現不一致で黙って無視 | 行全体をフィールド名・値は空文字として処理。`data` 単独行は空 data 行になる（例: `data\n\n` → data `""` のイベントが配送される） | `spec_line_noColon_wasIgnored_nowFieldWithEmptyValue` |
| (d) | 値先頭の空白除去 | `\s?` により空白1文字（タブ含む）を除去 | 仕様通り U+0020 スペースをちょうど1個だけ除去。タブは値の一部として保持 | `spec_value_leadingTab_wasStripped_nowPreserved` |
| (e) | `retry:` の値検証 | `Int(value)` で符号付き数値も受理（`retry: -1` → -0.001秒） | ASCII 数字のみ受理。符号・非数字を含む値はフィールドごと無視 | `spec_retry_negative_wasAccepted_nowIgnored` |
| (f) | `id:` フィールド | NUL 含みも受理。空値 `id:` は lastEventId を `nil` にリセット | NUL (U+0000) を含む値は無視。空値は空文字 `""` をセット（`nil` にはならない） | `spec_id_withNUL_wasAccepted_nowIgnored`, `spec_id_emptyValue_wasNil_nowEmptyString` |
| (g) | U+2028/U+2029 | `enumerateLines` が行区切り扱いし、後続がコロンなし行として**データ欠落**（`data: a\u{2028}b` → `"a"`） | 行区切りは CR/LF/CRLF のみ。U+2028/U+2029 は値にそのまま保持（→ `"a\u{2028}b"`） | `spec_lineSep_u2028_wasTruncated_nowPreserved`, `spec_lineSep_u2029_wasTruncated_nowPreserved` |
| (i) | 不正 UTF-8 | イベント全体を無通知で破棄（正常なフィールドも巻き添え） | U+FFFD 置換で継続（Encoding Standard 準拠） | `spec_invalidUTF8_wasDiscarded_nowReplacementCharacter` |
| (j) | CR 単独終端の確定タイミング | `\r\r` 受信で即 dispatch | 末尾 CR は次バイトで CRLF になる可能性があるため、**次のバイト到着かストリーム終端まで行確定を保留**（Chromium と同挙動）。接続完了時に保留分をフラッシュ | `spec_delimiter_CRCR_wasImmediate_nowHeldUntilNextByteOrEOF`, `delimiter_CRCR_unblockedByNextByte` |

### パーサの細部（仕様準拠に伴う二次的な変更）

- **lastEventId の更新タイミング**: 旧実装は `id:` 行の処理時に即座に更新。新実装は仕様通り**空行（dispatch）時**に更新する。`id:` 受信後・空行前に接続が切れた場合、旧実装では次回接続の `Last-Event-ID` ヘッダに反映されたが、新実装では反映されない（仕様準拠）。
- **id バッファのシード**: 再接続時、パーサの ID バッファは既知の lastEventId で初期化される（Chromium と同方式）。これにより `Configuration(lastEventId:)` で与えた値が、`id:` を持たないイベントの `MessageEvent.lastEventId` にも反映されるようになった（旧実装では `id:` 受信までイベントの lastEventId は `nil`）。
- 同一値への重複更新は `lastEventIdHandler` に再通知しない（観測上の差はなし）。

## 接続（EventSource）

| # | 対象 | 旧挙動 (v0.0.5) | 新挙動 | 対応テスト |
|---|---|---|---|---|
| (h) | HTTP レスポンス検証 | ステータス・Content-Type を見ず全レスポンスで `.open` になり本文を SSE としてパース（500 の HTML エラーページも対象） | 200 + `text/event-stream` のみ open。**500/502/503/504** は `onError` に `EventSourceError.unacceptableResponse` を通知し retryTime 後に再接続。**その他の非200・Content-Type 不一致**は同エラー通知の上、再接続せず終了 | `spec_non200Response_wasOpened_nowFailsAndReconnects`, `spec_wrongContentType_wasParsed_nowFatalFailure` |
| — | メモリ管理 | URLSession が delegate (EventSource) を強参照するため、`close()` を呼ばない限りインスタンスがリークし deinit 不到達 | 弱参照プロキシ経由にし、最後の参照を手放すと deinit → 接続クローズが走る | `droppingLastReference_deallocatesEventSource` |
| — | delegate コールバックの並行性 | delegate キューが並列（無制限）で、チャンク直後のエラー時などにデータ消失・順序不定が起きうる（実測で確認済み） | 直列キュー化により順序保証。全共有状態はロック保護（Swift 6 strict concurrency 準拠） | `ThreadSafetyStressTests` ほか全接続テスト |
| (k) | 旧セッションからのコールバック | 現行セッション判定がなく、(1) `close()` 直後に自身のキャンセルが `onError`(NSURLErrorCancelled) として通知される (2) **稼働中に `connect()` を呼ぶと旧セッションのキャンセル完了が新接続の readyState を破壊し、以後のイベントを全て取りこぼす**（v0.0.5 から存在した潜在バグ、反証レビューで決定的に再現） | delegate 3入口で「現行セッション由来か」を判定し、旧セッションのコールバックを無視。close() 後の偽 cancelled エラー通知は行われなくなり、稼働中の `connect()`（強制再接続）が安全になった | `spec_close_wasCancelledErrorReported_nowSilent`, `manualConnect_whileOpen_replacementConnectionSurvives` |
| (f2) | 空の lastEventId とヘッダ | 空文字でも `Last-Event-ID` ヘッダを送出しうる | 仕様通り、last event ID が空でない場合のみヘッダを送出 | `reconnect_afterEmptyId_omitsLastEventIdHeader` |

## 追加された公開 API（互換・追加のみ）

- `EventSourceError.unacceptableResponse(statusCode:contentType:)` — レスポンス検証失敗の通知用
- `init(url:configuration:sessionProvider:)` の第3引数（省略可、テスト用 DI）
- `MessageEvent` の public init / `Equatable` / `Sendable`、`Configuration` プロパティの public 化・`Sendable`、`ReadyState` の `Sendable`

### 接続の細部

- **Content-Type 判定**は MIME タイプ部分の完全一致（`; charset=utf-8` 等のパラメータは無視、大文字小文字非区別）。
- **値先頭スペースの除去はバイトレベル**で行う（スペース直後に結合文字が続く病的入力でも仕様通り除去される）。

## 変わらないもの（明示）

- callback API（`onOpen`/`onError`/`onMessage`/`onReadyStateChanged`/`addEventListener`）のシグネチャと配送スレッド（メインスレッド）
- `init` が自動で `connect()` する挙動
- エラー・サーバ切断時の自動再接続と `retry:` による間隔変更
- `data:` 単独行（空値）が data `""` のイベントとして配送される挙動（仕様と一致していたため据え置き）
