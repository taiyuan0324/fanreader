# FanReader(翻页)

自建 iOS 阅读器。全部代码为本项目原创实现,不包含任何第三方应用的反编译产物、资源或凭据。

[![build](https://github.com/taiyuan0324/fanreader/actions/workflows/build.yml/badge.svg)](https://github.com/taiyuan0324/fanreader/actions/workflows/build.yml)

当前版本 **0.5.0**。CI:macos-15 + Xcode 16,约 2 分钟产出未签名 IPA,零编译警告。

## 功能

**导入通道(三条,互为兜底)**
1. App 内 + 号 → `UIDocumentPickerViewController(asCopy: true)`,系统先复制进沙盒,任意文件可选
2. 「文件」App 里选中文件 → 共享 → 翻页(`CFBundleDocumentTypes` + `onOpenURL`)
3. 把文件拖进「文件 App → 我的 iPhone → 翻页」,再在设置里点「扫描『翻页』文件夹」

出问题可在 设置 → 查看导入日志 看每一步记录(`Documents/import.log`)。

**书架**
- 导入 TXT / EPUB / PDF,支持多选批量导入;任意类型可选(`public.item`),无扩展名文件按魔数嗅探
- EPUB 自动提取书名、作者、封面(meta cover / properties=cover-image)
- 搜索(书名/作者)、排序(最近阅读/导入时间/书名)、只看收藏
- 阅读进度条、长按菜单(收藏/重命名/删除)、删除二次确认

**主题与排版**
- 7 套主题:纸白 / 米黄 / 护眼 / 灰调 / 夜间 / 纯黑 / 跟随系统,整套配色(含状态栏)跟随切换
- 5 种字体(系统/宋体/楷体/黑体/等宽)、字号 12–32
- 行高倍数 1.1–2.4、段间距 0–24、首行缩进 0–3 字、页边距 8–44、左对齐/两端对齐
- 分页与渲染共用同一份 `NSAttributedString`(CoreText),切页位置与屏幕像素一致
- 两种翻页模式:左右翻页(TabView 分页)、上下滚动(整章连续滚动)
- 可开关页眉(书名/章节)与页脚(章节序号/页码/百分比),工具栏隐藏时才出现

**朗读**
- 五种引擎:**微软语音(自建)**、**豆包(自建)**、系统离线、Azure 语音、OpenAI 兼容 `/audio/speech`
- 微软语音自建:指向服务器上的 `edge-tts-server`(`GET /api/synthesis`),微软的 v2 校验在服务端处理
- 豆包自建:在设置里填你自己的服务地址(如 `http://<主机>:3456`),音色列表自动拉取、支持连接检测,按 260 字合并请求
- Edge 语音内置 10 个中文音色(晓晓/云希/云健/粤语/台湾…),基于 WebSocket 协议独立实现;微软已升级 v2 token 校验,该通道标记为实验性
- 系统朗读支持挑选已下载的「增强/高级」音色(完全离线、免费),未选择时自动取最优
- 在线引擎按句切分、逐句请求播放,失败自动回退系统语音
- 密钥存 Keychain;设置页可试听

**阅读**
- CoreText 分页:字号 12–30、行距 2–16、页边距 8–40、四种字体(系统/宋体/圆体/等宽)
- 三种主题:纸白 / 牛皮纸 / 夜间
- 点击左右三分之一翻页、点中间呼出工具条;沉浸式隐藏状态栏
- 章节跳转、进度精确到页并持久化
- 全书搜索:定位到章节并跳到命中页
- 书签:按页保存,可滑动删除

**EPUB**
- 目录优先用 EPUB3 `nav.xhtml`,回退 EPUB2 NCX,再回退标题推导
- 自写 ZIP 读取器(中央目录 + `compression_decode_buffer` 解 deflate),零第三方依赖

**PDF**
- PDFKit 渲染、横向翻页、内置大纲(outline)当目录

**朗读**
- AVSpeechSynthesizer 中文,语速 0.35–0.7
- 逐页朗读,读完自动翻页续读

**数据**
- 本地备份为 zip(书库索引 + 书签 + 书籍 + 封面),可分享到「文件」/iCloud
- 从备份恢复,恢复后即时刷新书架

## 目录结构

```
FanReader/
  project.yml                 XcodeGen 工程描述(CI 里生成 .xcodeproj)
  .github/workflows/build.yml GitHub Actions:构建 + 打包 + Release
  Sources/
    App/                      入口、书架、全局设置
    Models/                   Book / LibraryStore / BookmarkStore / ReadingSettings
    Parsing/                  ZIP 读写、EPUB(OPF+TOC)、TXT 章节切分、HTML→文本
    Reading/                  分页器、阅读视图、PDF 视图、TTS
    Sync/                     备份/恢复、云盘 Provider 协议
```

## 本地构建

需要 macOS + Xcode 16:

```bash
brew install xcodegen
cd FanReader
xcodegen generate
open FanReader.xcodeproj
```

## CI 构建(无需 mac)

推送到 `main` 即触发(约 2 分钟),产物在 Actions 的 Artifacts 里:

- `FanReader-unsigned-ipa`:`Payload/FanReader.app` 打成的未签名 IPA
- `FanReader-simulator-app`:模拟器可直接运行的 `.app`

产物只留在 Actions Artifacts,不再发布 GitHub Release。

## 装到设备

未签名 IPA 无法直接安装,iOS 强制代码签名。合法路径:

| 方式 | 说明 |
|---|---|
| 自己的 Apple ID 重签 | Xcode 选团队 → `xcodebuild archive`;或用 Sideloadly 重签,免费账号 7 天有效 |
| 开发者账号 Ad Hoc | 付费账号可签 1 年,需登记设备 UDID |
| 越狱 / TrollStore | 不推荐,系统风险自负 |

## 路线图

- [x] PDF 渲染(PDFKit)+ 大纲目录
- [x] EPUB 目录(nav.xhtml / NCX)
- [x] 主题 / 行距 / 页边距 / 字体
- [x] 书签、全书搜索
- [x] 本地备份与恢复
- [ ] 文字选中、复制、划线批注
- [ ] 云盘真实同步(需自建应用 client_id)
- [ ] 多语言朗读音色选择
- [ ] 单元测试(Paginator / EPUB 解析)
