# 検証結果

## 2026年10月29日：Xcode警告の修正

- iPad用の画面方向を4方向に設定。iPhone用の設定は維持。
- WebLoginのローカルサーバー起動を、一度だけ再開できるロック保護済み継続に変更。入れ子のクロージャーでweakキャプチャを明示。
- Debug構成でCOPY_PHASE_STRIP / STRIP_INSTALLED_PRODUCTをNOに設定。
- iOS実機SDK向け（Watch版を含む）とmacOS向けの署名なしDebugビルドが成功。コンパイラ・ビルド設定の警告なし。Simulatorサービス関連の環境ログは別途出力される。
- 既存テスト、100個の同時完了イベント、キャンセル後の遅延完了を検証して成功。
- 署名付きビルドでのstrip警告の再現確認、実アカウントでのWebログイン再検証は未実施。

## 2026年10月29日：Apple Watch対応

- watchOS Simulator向けアプリ・WidgetKit拡張の署名なしDebugビルド成功。
- Watchアプリを内包したiOS Simulator向けアプリと既存macOS版の署名なしDebugビルド成功。
- 既存の使用量解析・OAuthテストを再実行して成功。
- WatchSnapshotの往復変換、認証情報が含まれないこと、サービスと期間の選択、空データによる消去、古い通信・重複通信の判定、異常なサービス重複・バージョンの拒否をテストして成功。
- 今回はWatch実機の署名・インストール・WatchConnectivity通信・表示を検証していません。Simulatorサービスの制約により画面確認も未実施です。

## 以前の検証記録

実施日: 2026年10月12日（日本時間）

- Xcode 27.0で、iOS Simulator向けアプリ・WidgetKit拡張のDebugビルド成功（署名なし）。iPhone・iPad共通ターゲットです。
- 同じXcodeで、macOS向けアプリ・WidgetKit拡張のDebugビルド成功（署名なし）。
- Codexのused_percentから残量への変換、5時間枠・週間枠、0%使用時の100%残量をテスト。
- Claudeの小数のutilizationから残量への変換、ミリ秒あり・なしのISO日時をテスト。
- 空レスポンス、nullの枠、範囲外の使用率を正常値として表示しないことをテスト。
- 2026年10月13日追記: Webログイン（OAuth PKCE）追加後、macOS / iOS Simulator向けにDebugビルド成功（署名なし、警告なし）。PKCEのchallenge計算（opensslの計算値と照合）、認可URL、コールバックURL・「code#state」の解釈、拒否時のエラー、Codexのid_tokenからのAccount ID取得、有効期限と自動更新判定をテスト。
- 2026年10月13日追記: 無料のApple ID対応のためApp Groupsを廃止し、使用量もKeychain共有で受け渡すよう変更。macOS / iOS Simulator / iOS実機（iphoneos）向けにDebugビルド成功（署名なし）、テスト再実行で成功。
- テストコードはTests/main.swift。Tests/run.shで再実行できます。

未実施: 実際のアカウントを使う通信（Webログイン・トークン交換・自動更新を含む）、署名後のKeychain共有（無料アカウントでの署名を含む）、実機インストール、ウィジェットの画面表示・自動更新頻度、認証情報の期限切れ後の再登録。

この環境ではSimulatorサービスに接続できなかったため、シミュレーターの起動・画面確認は行っていません。ビルド成功は、実データ接続や実機動作の成功を意味しません。
