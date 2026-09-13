---
keywords: [cgwindowlist, hotkey, iterm2, nonactivating-panel, officewindow, sidebarpanel, stage-manager, window-level, ウィンドウ層, 前面アプリ]
category: context
---

# オフィス窓・サイドバー・iTerm2 の重なり順

## Entry: オフィス窓をホットキーで出すまでに踏んだ「ウィンドウの層」と「前面アプリ」の罠
keywords: [window-level, cgwindowlist, stage-manager, nonactivating-panel, hotkey, sidebarpanel, officewindow, iterm2, ウィンドウ層, 前面アプリ]
uid: 72bdd647dea0
project: syarihu/agent-proctor

オフィス窓 (`OfficeWindow`) を iTerm2 の hotkey window と同じ感覚で出せるようにしたときの記録。
**Stage Manager 対策として「アプリを前面に出さない窓」にしたが、結局やめて普通の窓に戻した。**
やめるまでに払った代償が本体なので、同じ道に入りかけたら読むこと。

## 結論: 普通のアプリの窓にする

`OfficeWindow` は `NSWindow`、`show()` で `.regular` に昇格して `NSApp.activate`。
層は `.normal` のまま、`collectionBehavior` も触らない。iTerm2 側に要求する設定も無い
(hotkey window を浮かせない。浮かせると焦点を取らなくなる。後述)。

**諦めたもの**: Stage Manager がオンだと、オフィス窓を出した時点でステージが入れ替わる。
覗きに来ただけなのに、覗いた先が片付く。**これ1点を諦めて、他を全部取った。**

## なぜ諦めたか

Stage Manager は「アプリのアクティブ化」でステージを入れ替える。避けるには
アプリを前面に出さなければよく、それは実際にできる。

- `NSPanel` + `.nonactivatingPanel` (押しても掴んでもアプリを前面に引き出さない)
- `collectionBehavior` に `.auxiliary` (「この窓は集合に加わらない」の印。macOS 13+)
- `NSApp.activate()` ではなく `orderFrontRegardless()`

**動く。ステージは入れ替わらなくなった。そこから後始末が10コミット続いた。**
前面に出ない窓は macOS の作法から外れるので、周りが軒並み外れる。

| 壊れたもの | なぜ |
| --- | --- |
| サイドバーの高さ | 「前面アプリが自分なら下げる」が、前面が iTerm2 のままで当たらない |
| 自動で隠す判定 | 端末が退いて裏のアプリに前面が返るのを「人が移った」と読む |
| 窓が埋まる | 同じ層にいる相手が持ち上がると後ろに回る。層で逃げると端末が下に潜る |
| 端末の焦点 | 層で逃げるために iTerm2 を浮かせたら、浮いた hotkey window は焦点を取らない |
| キーボード | 打鍵の宛先にならない。⌘1〜⌘9 を拾うには押して受け取る一手間が要る |
| 戻ってきた焦点 | ⌘N で端末を開いて閉じると、オフィス窓に焦点が返らない |

**「アプリを前面に出さない」を選ぶと、前面とキーボードに紐づく OS の仕組みを全部自前で数え直すことになる。**
その数え直しがどれも競争や取りこぼしを抱える。Stage Manager 1つのために払う額ではなかった。

## 残したもの (前面に出す作りでも正しい)

- `SidebarRoom.currentItermWindow()` は**層で絞らず、層を返す**。サイドバーはその +1 に立つ
  (下限 `.floating`)。決め打ちで外した経緯は下記
- 端末が通常より高い層にいるときは、前面アプリを問わずその上に立つ
- `scripts/setup-iterm-hotkey.py` は `Has Hotkey` を持つプロファイルを名前に関係なく拾う

## iTerm2 の hotkey window は層 22 にいる

`CGWindowListCopyWindowInfo` の `kCGWindowLayer` を見ると、浮かせた hotkey window は **22**。
`.floating` (3) ではない。`layer == 0` で絞っていたので、「Floating window」を入れた瞬間に
端末を見失い、サイドバーが**覆われるのではなく引っ込んでいた** (`itermBounds()` が nil → `orderOut`)。

**教訓: 他アプリのウィンドウ層を決め打ちしない。ウィンドウ一覧が教えてくれるので読んで相対で並ぶ。**
0 と 3 で2回外してから実機を覗いて分かった。

## 浮いた hotkey window は焦点を取らない

一度「Floating window」を入れてもらっていた。オフィス窓を `.normal + 1` に上げたせいで
端末がその下に潜ったためで、こちらの都合を iTerm2 の設定で埋め合わせていた。
**その代償が焦点。** 端末を呼んだ直後に打てない。
`Has Hotkey` のプロファイルに焦点を当て直す設定は iTerm2 に無い (実機の plist を全キー確認済み)。

**教訓: 他アプリの設定を要求して直すのは借金。その設定が向こうで何を意味するかを先に確かめる。**
「重なり順のための設定」だと思っていたものが、向こうでは「焦点を取らないモード」だった。

## 「埋まっている」を症状から見分ける

**ホットキーを1回押しても開かず、2回押すと開く。** これは窓が生きている証拠。
`toggle()` は `isVisible` で分岐するので、埋まっているだけの窓は「出ている」と判定され、
1回目が `hide()` に倒れる。閉じられていたなら1回で開く。
ついでに、この症状が出た時点で「隠す判定は効いている」ことまで確定する。

## 参考: アクティブにならない窓は「通知を出さない」

前面に出ない作りを再び検討するなら、ここが一番効く。
**「前面アプリが誰か」「どの窓がキーか」で分岐しているコードが全部外れる。**

- `NSWorkspace.didActivateApplicationNotification` が飛ばない
- `NSWindow.didBecomeKeyNotification` も飛ばない
- `SidebarPanel.updateLevel()` は「前面が自分なら下げる」で書かれていたので、
  前面が iTerm2 のままになり、サイドバーがオフィス窓の上に取り残された

→ 出し入れした側から明示的に知らせる (`SidebarPanel.refreshLevel()`)。
→ 「オフィス窓が**出ているか**」ではなく「**手前か**」を持つ。出しただけで下げっぱなしにすると、
   そのあと端末へ移ったときにサイドバーが端末の上へ戻れない。
   手前かどうかは尋ねる相手がいないので、`AppDelegate` が数える
   (出したとき true、どれかのアプリが前に出たら false)。

## 3. 「消えた」の正体が「埋まった」だった

> iTerm2 を引っ込めるとオフィス窓も閉じる。ただし前面に別のアプリがいないときは期待通り。

この食い違いが決め手。**隠す判定が悪いなら、他のアプリがいてもいなくても同じように隠れるはず。**
差が出るのは「持ち上がってくる窓が他にあるか」だけ。つまり閉じてはおらず、
前面を返されたアプリが自分の窓を持ち上げて、その下に回っていた。

**見分け方: 前面に別アプリのウィンドウがあるかどうかで挙動が変わるなら、隠されたのではなく埋まっている。**

## 4. iTerm2 の hotkey window は層 22 にいる

`CGWindowListCopyWindowInfo` の `kCGWindowLayer` を見ると、浮かせた hotkey window は **22**。
`.floating` (3) ではない。`SidebarRoom.currentItermBounds()` は `layer == 0` で絞っていたので、
「Floating window」を入れた瞬間に端末を見失い、サイドバーが**覆われるのではなく引っ込んでいた**
(`itermBounds()` が nil → `panel.orderOut`)。

→ 層で絞るのをやめ、`SidebarRoom.currentItermWindow()` が **層も返す**。
  サイドバーはその +1 に立つ。下限は `.floating` (端末が 0 にいるとき一緒に降りないため)。
  小さいパネル (補完候補など) は後段の「幅400・高さ300以上」で落ちる。

**教訓: 他アプリのウィンドウ層を決め打ちしない。ウィンドウ一覧が教えてくれるので読んで相対で並ぶ。**

## 5. hotkey window を引っ込めると、裏のアプリに前面が返る

それが `didActivateApplicationNotification` で届くので、「人が別のアプリへ移った」と読める。
実際は端末が退いた穴を埋めただけ。
→ `AppDelegate` は窓を出したときに前にいたアプリ (`officeHostApp`) を覚え、iTerm2 と並べて例外にする。
   メニューバーから開くとクリックで自分が前に出てしまうので、自分以外で最後に前へ出たアプリ
   (`lastForeignApp`) を控えて、そのときはそちらを使う。

## 6. 浮いている端末が相手なら「前面アプリか」を訊かなくていい

ホットキーで呼んだ直後は、**窓はもう出ているのに前面がまだ入れ替わっていない**。
そこで高さを決めると低いほうを選び、22 の下に潜ったままクリックするまで出てこない。

「別のアプリに移ったら下げる」は**居座る窓への気遣い**であって、
自分で引っ込む hotkey window には要らない (別アプリへ移れば端末ごと消え、こちらも見失って引っ込む)。
→ 端末が通常より高い層にいるときは前面を問わずその上に立つ。

## 調べ方 (次も同じ手を使う)

推測を止めたのはこの2つ。どちらも `swiftc` で小さく書いて `/tmp` に置いた。

```swift
// 1. いま画面に出ている iTerm2 の窓を、層と大きさごと出す
CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
//   → kCGWindowOwnerName / kCGWindowLayer / kCGWindowBounds を並べるだけ

// 2. アプリの前面交代を届いた順に出す
NSWorkspace.shared.notificationCenter.addObserver(
    forName: NSWorkspace.didActivateApplicationNotification, ...)
//   didDeactivateApplicationNotification も一緒に見る
```

ユーザーからの「設定画面を開くと出てくる」という報告も決め手になった。
設定画面にフォーカスが移ると iTerm2 が非アクティブになって層が 0 に戻り、探索が見つけられるようになる
——つまり「覆われている」ではなく「見失っている」と分かった。
**症状の食い違いは、当てずっぽうを消すための情報として読む。**

## ついでに見つかった別のバグ

`scripts/setup-iterm-hotkey.py` は `Name == "proctor"` のプロファイルしか探しておらず、
iTerm2 が勧める名前 (`Hotkey Window`) で先に作ってあると**誰も使わない2枚目**を作って
そこに設定を書いていた。適用したつもりで、実際に押す窓には一度も届いていなかった。
→ `Has Hotkey` を持つプロファイルを名前に関係なく拾うようにした。

