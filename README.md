# AI使用量ウィジェット（個人用試作版）

**Apple Watch対応を追加しました。** watchOS 10以降で、ペアリングしたiPhoneの取得済みデータを表示します。インストールと文字盤の設定は[WATCH_SETUP.md](WATCH_SETUP.md)を参照してください。

Mac・iPhone・iPadからCodex / Claude Codeの残量を直接取得するSwiftUI / WidgetKitアプリです。中継サーバーやMacからの定期転送は使いません。対応はiOS / iPadOS 17以降、macOS 14以降です。

## この版でできること

- アプリの「更新」で、この端末から両サービスへ直接通信。
- 5時間枠・週間枠の残量、バー、リセット日時、最終取得日時の表示。取得できた枠のみ表示。
- 両サービスを並べる中・大ウィジェット、および単独の小・中ウィジェット。小サイズも5時間枠・週間枠のバーとリセット日時を表示（取得日時は省略）。
- ウィジェット自身もこの端末の認証情報で取得し、30分後以降の更新をOSに依頼。正確な30分間隔は保証されません。
- 「認証情報を設定」→「Webでログイン」で、ChatGPT / Claudeのログイン画面からアクセストークンを自動取得。更新用トークンも保存し、期限切れ前・401時にアプリ／ウィジェットが自動更新します。
- 認証情報と取得した数値は、どちらも端末内の共有Keychainに保存（App Groupは不使用）。認証情報は端末間で共有しません。ペアリング済みのApple Watchには、iPhoneから表示用の数値と取得日時を送ります。
- 取得失敗時は古い数値と取得日時を保持し、エラーを表示。リセット時刻経過後も、再取得するまでは勝手に100%へ戻しません。

## 未実装・未確認

**完成品ではなく、実データ接続のための試作版です。** Webログインは各端末で1回ずつ行います（端末間でトークンを共有しません）。手動登録したトークンは更新用トークンを持たないため自動更新されません。

Webログインは、Codex CLI / Claude Codeの公式ログインと同じOAuth設定（クライアントID・接続先、`Shared/OAuth.swift`の`OAuthConfig`）を使います。これらは外部アプリ向けに公開・保証されたものではなく、各社の規約上の扱いも明確ではありません。CLI側の変更で使えなくなった場合は`OAuthConfig`の値を更新してください。

- ログイン後のリダイレクトはアプリ内の一時的なlocalhostサーバー（ループバックのみ）で受け取ります。Codexは登録上ポート1455固定のため、同じ端末でCodex CLIのログインを同時に行うと失敗します。
- 自動で戻らない場合は、ログイン後のページのURL（Claudeの場合は`コード#state`形式も可）を貼り付けて完了できます。
- 同じアカウントでCLIや他端末からもログインしている場合、更新用トークンのローテーションにより一方が再ログインを求められる可能性があります。

使用量のURLは既存のCodexBar実装を参考にした非公開の接続先で、外部アプリ向けの安定した公開APIとして保証されていません。サーバー側の変更、トークンの権限不足や失効で取得できなくなる場合があります。本プロジェクトではユーザーの認証情報を読んでおらず、実アカウントによる成功確認は未実施です。App Store公開を前提にしていません。

## Xcodeで実行する

無料のApple ID（Personal Team）でも署名できるよう、App Groupsは使わずKeychain Sharingだけを使っています。

1. Xcode → Settings → AccountsでApple IDにサインインします（無料アカウントで可）。
2. Bundle Identifierは`com.s-ueki7.aiusage`を基準に設定済みです（Bundle IDにアンダースコアは使えないため`s-ueki7`としています）。別の識別子に変える場合は、重複しない値に置き換えます。Bundle Identifierは他人と重複できないため、重複すると署名に失敗します。`work/generate_project.py`の`BASE`を書き換えて実行すると、4ターゲットのBundle ID・entitlements・Info.plistをまとめて変更できます（プロジェクトファイルを作り直すため、Teamは選び直しになります）。手作業で変える場合は、各ターゲットのBundle Identifier、entitlementsの`keychain-access-groups`、Info.plistの`SharedKeychainGroup`をそろえてください。
3. 使うターゲットのSigning & Capabilitiesで、ご自身のTeam（無料なら「(お名前) (Personal Team)」）を選びます。iPhone / iPadは`AIUsageiOS`と`AIUsageWidgetsiOS`の2つ、Macは`AIUsagemacOS`と`AIUsageWidgetsmacOS`の2つです。
4. iPhone / iPadはScheme `AIUsageiOS`、Macは`AIUsagemacOS`を選び、実行します。iPhoneでは「設定 → プライバシーとセキュリティ → デベロッパモード」をオンにし、初回は「設定 → 一般 → VPNとデバイス管理」で開発元を信頼します。
5. 各端末のアプリで「認証情報を設定」→「Webでログイン」（または手動登録）を行い、実際の使用量画面と数値が一致するか確認します。
6. 各端末で「AI使用量」のウィジェットを追加します。

無料アカウントの制限: インストールしたアプリは**7日で期限切れ**になり、再度Xcodeから実行する必要があります。また、同時に入れられるアプリ数や、1週間に作れるApp ID数にも上限があります。署名していないビルドでは、Keychain共有の成功を確認できません。

## 認証情報について

通常のOpenAI APIキーやAnthropic APIキーではなく、契約アカウントのアクセストークンを使います。通常は「Webでログイン」で自動取得できます。以下は手動登録する場合の取得元です。

- **Codex:** 既存のCLIログインの`~/.codex/auth.json`（CODEX_HOMEを設定している場合はそのディレクトリ）の`tokens.access_token`。必要な場合は同じtokens内の`account_id`をアプリのChatGPT Account ID欄に登録します。`OPENAI_API_KEY`や`refresh_token`を入れる欄ではありません。
- **Claude Code:** 既存のログイン情報の`claudeAiOauth.accessToken`。macOSではKeychainの`Claude Code-credentials`などに保存される場合があります。環境により`~/.claude/.credentials.json`に保存されます。使用量取得には`user:profile`などの適切な権限が必要です。`claude setup-token`で作成したトークンは使用量取得用とは限りません。

認証情報はこのアプリにだけ入力してください。チャット、スクリーンショット、Gitリポジトリへ載せないでください。アプリに保存したトークンはCLIの更新と連動しないため、失効したら元のサービスで再認証し、アプリへ再登録します。他端末の情報を更新・削除する操作はありません。

この版はCLIの認証情報ファイルの自動読み取り・自動転送を行いません。同じアカウントを各端末へ登録すると、各端末はそのアカウント全体の残量を取得します。端末別の消費量を集計するものではありません。

## 検証

ビルド結果と実施済みテストは同梱の`VALIDATION.md`を参照してください。署名・実機・実アカウントでの確認は別途必要です。

## 参考資料

- [Codex公式認証資料](https://learn.chatgpt.com/docs/auth)
- [CodexBarのCodex取得方法](https://github.com/steipete/CodexBar/blob/main/docs/codex.md)
- [CodexBarのClaude取得方法](https://github.com/steipete/CodexBar/blob/main/docs/claude.md)
- [Apple: ウィジェットの更新](https://developer.apple.com/documentation/widgetkit/keeping-a-widget-up-to-date)

CodexBarのソースコードはコピーせず、公開された接続方法を参考に独自実装しています。
