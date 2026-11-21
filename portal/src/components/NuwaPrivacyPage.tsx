interface NuwaPrivacyPageProps {
  onNavigate: (path: string) => void;
}

export function NuwaPrivacyPage({ onNavigate }: NuwaPrivacyPageProps) {
  return (
    <div className="bg-white">
      {/* Header */}
      <section className="site-container pt-[64px] pb-[48px] max-[680px]:pt-[44px] max-[680px]:pb-[36px]">
        <div className="max-w-[820px] mx-auto">
          <button
            type="button"
            onClick={() => onNavigate('/nuwa')}
            className="inline-flex items-center gap-1.5 text-[13px] font-medium text-[#686d74] hover:text-[#18181b] transition-colors cursor-pointer mb-6"
          >
            <span aria-hidden="true">←</span>
            <span>返回 Nuwa</span>
          </button>

          <p className="eyebrow">PRIVACY POLICY</p>
          <h1 className="mt-3 text-[clamp(36px,4.2vw,52px)] font-medium tracking-[-1.4px] leading-[1.1] text-[#18181b]">
            Nuwa 隐私政策
          </h1>

          <div className="mt-5 flex flex-wrap gap-x-6 gap-y-2 text-[13px] text-[#686d74]">
            <span>更新日期：2026年11月21日</span>
            <span>生效日期：2026年11月21日</span>
          </div>

          <p className="mt-6 text-[15px] leading-[1.85] text-[#4b4f55]">
            Nuwa（含 Nuwa AI 客户端及其系统分享扩展，以下简称“本应用”）由{' '}
            <strong className="font-medium text-[#18181b]">广州秩弦科技有限公司</strong>
            （以下简称“我们”）提供，是一款本地优先的 AI
            对话客户端，用于连接用户自选的模型服务（如 DeepSeek 开放平台及 OpenAI / Anthropic
            兼容接口）并管理本地会话记录。
          </p>

          <div className="mt-6 rounded-[16px] border border-[#e8e8e8] bg-[#f6f6f6] p-6 space-y-3">
            <p className="text-[14px] font-medium text-[#18181b] m-0">
              我们非常重视您的个人信息与隐私保护。核心隐私承诺如下：
            </p>
            <ul className="list-disc pl-5 space-y-2 text-[14px] leading-[1.8] text-[#4b4f55] m-0">
              <li>
                <strong className="font-medium text-[#18181b]">本地优先，不收集数据：</strong>
                我们不设立对话中转服务器，不收集、不存储、不追踪、不出售您的对话内容、附件、API
                Key、账号令牌或个人身份信息，亦不接入任何第三方广告或跨应用追踪 SDK。
              </li>
              <li>
                <strong className="font-medium text-[#18181b]">直连您所选的服务商：</strong>
                您的对话内容及凭据仅保存在您的设备本地，且仅在您主动发起请求时直接发送至您自行配置或授权的第三方
                AI 服务商。
              </li>
            </ul>
          </div>
        </div>
      </section>

      {/* Chinese Body */}
      <section className="border-t border-[#e8e8e8] py-[56px] max-[680px]:py-[40px]">
        <div className="site-container">
          <div className="max-w-[820px] mx-auto space-y-11 text-[15px] leading-[1.85] text-[#4b4f55]">
            {/* 1 */}
            <section className="space-y-4">
              <h2 className="text-[22px] font-medium tracking-[-0.4px] text-[#18181b]">
                1. 我们如何处理您的信息
              </h2>
              <p className="m-0">
                我们仅在实现您主动使用的功能所必需的最小范围内，在本地设备处理或按您的指令向目标服务商转发以下信息：
              </p>

              <div className="space-y-2.5 pt-1">
                <h3 className="text-[16px] font-medium text-[#18181b]">
                  1.1 AI 对话与模型接口调用
                </h3>
                <p className="m-0">
                  当您发送消息时，本应用会将您的输入文本、当前会话上下文、模型参数设置（如深度思考、联网搜索开关）、您手动选择的地区偏好（如有），以及您主动附加的图片或文件，直接发送至您所选的模型接口服务商。
                </p>
                <p className="m-0">
                  若您选择将压缩包（.zip）用于对话，本应用会在您的设备本地自动解压并筛选可读取的文档、代码或图片，仅将您确认发送的附件提交至所选模型接口。
                </p>
                <p className="m-0">
                  验证和调用接口时，应用会向对应服务商发送您提供的 API Key 或授权令牌。
                </p>
              </div>

              <div className="space-y-2.5 pt-1">
                <h3 className="text-[16px] font-medium text-[#18181b]">
                  1.2 DeepSeek 开放平台账号授权与余额查询
                </h3>
                <p className="m-0">
                  当您主动选择通过 DeepSeek 开放平台登录时，应用会打开 DeepSeek
                  官方授权流程，并使用授权参数、应用本地生成的随机设备标识、设备型号、系统版本、语言与时区信息完成鉴权。
                </p>
                <p className="m-0">
                  授权完成后，应用仅在您设备本地安全存储（如 iOS
                  Keychain）中保存访问令牌及用于界面展示的账号信息（昵称、脱敏手机号或邮箱），并可按需直接向
                  DeepSeek 开放平台查询 API 余额。
                </p>
              </div>

              <div className="space-y-2.5 pt-1">
                <h3 className="text-[16px] font-medium text-[#18181b]">
                  1.3 历史对话迁移、导入、备份与会话分享
                </h3>
                <ul className="list-disc pl-5 space-y-2 m-0">
                  <li>
                    <strong className="font-medium text-[#18181b]">
                      官方历史迁移与本地导入：
                    </strong>
                    当您使用一键迁移或导入 .zip / .json / .nuwa
                    文件时，本应用在设备本地完成解析、去重与增量合并，所有会话及图片均仅保存在您的设备本地。
                  </li>
                  <li>
                    <strong className="font-medium text-[#18181b]">
                      系统分享扩展（Share Extension）：
                    </strong>
                    当您在微信、文件、相册或浏览器等应用中主动通过系统分享面板将文件、压缩包或文本发送至
                    Nuwa 时，扩展程序会通过系统本地安全共享容器（App
                    Group）将内容传递给主应用，主应用读取完成后立即自动清理临时缓存，不会上传至我们的服务器。
                  </li>
                  <li>
                    <strong className="font-medium text-[#18181b]">
                      隔空投送 / 碰一碰会话分享：
                    </strong>
                    当您主动触发会话分享或将两台设备靠近共享时，应用会在本机按需打包当前会话为
                    .nuwa 文件并交由操作系统点对点传输，我们不经过也不留存任何分享内容。
                  </li>
                  <li>
                    <strong className="font-medium text-[#18181b]">可选云备份（默认关闭）：</strong>
                    若您在 iOS 设置中手动开启 iCloud
                    自动备份，本应用仅会将导出的备份压缩包写入您个人 Apple 账户的 iCloud Drive
                    目录，相关同步与安全由 Apple 隐私政策约束。
                  </li>
                </ul>
              </div>

              <div className="space-y-2.5 pt-1">
                <h3 className="text-[16px] font-medium text-[#18181b]">
                  1.4 语音输入、朗读与版本更新检测
                </h3>
                <ul className="list-disc pl-5 space-y-2 m-0">
                  <li>
                    <strong className="font-medium text-[#18181b]">语音输入与朗读：</strong>
                    当您主动使用语音输入或朗读功能时，录音或朗读文本会交由设备本地语音引擎或您所选的语音服务接口处理。
                  </li>
                  <li>
                    <strong className="font-medium text-[#18181b]">版本更新检测：</strong>
                    为提醒新版本，本应用会向官方应用商店公开查询接口（如 Apple iTunes Lookup
                    API）获取最新版本号与更新日志，该过程不上传任何个人身份信息。
                  </li>
                  <li>
                    <strong className="font-medium text-[#18181b]">本地诊断日志：</strong>
                    为便于排查异常，应用可能在本地记录脱敏的运行错误日志（不含您的 API Key
                    与聊天正文），仅保存在本机并由您自主查看或清除。
                  </li>
                </ul>
              </div>
            </section>

            {/* 2 */}
            <section className="space-y-3 border-t border-[#e8e8e8] pt-9">
              <h2 className="text-[22px] font-medium tracking-[-0.4px] text-[#18181b]">
                2. 设备权限调用说明
              </h2>
              <p className="m-0">
                我们遵循最小必要原则，仅在您主动触发对应功能时申请权限；拒绝权限不影响其他核心功能使用：
              </p>
              <ul className="list-disc pl-5 space-y-2 m-0">
                <li>
                  <strong className="font-medium text-[#18181b]">麦克风权限：</strong>
                  仅用于「语音输入」功能。仅在您主动点击或按住语音输入按钮时开启录音，绝不在后台静默录音，也不用于任何其他用途。
                </li>
                <li>
                  <strong className="font-medium text-[#18181b]">语音识别权限（iOS）：</strong>
                  配合麦克风使用 Apple
                  系统语音识别服务（SFSpeechRecognizer），将您的语音实时转换为文字填入输入框。若拒绝授权，您仍可正常使用文字输入。
                </li>
                <li>
                  <strong className="font-medium text-[#18181b]">图片与文件选择：</strong>
                  本应用调用操作系统原生图片/文件选择器，仅读取您当次主动勾选的单张图片或文件，不申请访问您的完整相册库或系统全盘文件。
                </li>
                <li>
                  <strong className="font-medium text-[#18181b]">网络访问：</strong>
                  用于向您选定的 AI 服务商发起模型请求、鉴权、余额查询、网页内容读取及应用版本检查。
                </li>
                <li>
                  <strong className="font-medium text-[#18181b]">位置信息：</strong>
                  本应用不申请 GPS
                  定位权限；对话上下文中的城市/地区信息完全来自您在设置中的手动选择。
                </li>
              </ul>
            </section>

            {/* 3 */}
            <section className="space-y-3 border-t border-[#e8e8e8] pt-9">
              <h2 className="text-[22px] font-medium tracking-[-0.4px] text-[#18181b]">
                3. 第三方服务及数据流向
              </h2>
              <p className="m-0">
                当您主动使用 DeepSeek 模型、DeepSeek 开放平台授权或 DeepSeek
                历史迁移时，本应用会直接连接由{' '}
                <strong className="font-medium text-[#18181b]">
                  杭州深度求索人工智能基础技术研究有限公司
                </strong>{' '}
                运营的官方服务（登录与导出页面由第三方服务提供，第三方网页可能使用 Cookie
                维持登录状态）：
              </p>
              <ul className="list-disc pl-5 space-y-2 m-0">
                <li>
                  DeepSeek 开放平台隐私政策：
                  <a
                    href="https://cdn.deepseek.com/policies/zh-CN/deepseek-open-platform-privacy-policy.html"
                    target="_blank"
                    rel="noreferrer"
                    className="text-[#18181b] underline underline-offset-4 hover:opacity-65 break-all"
                  >
                    https://cdn.deepseek.com/policies/zh-CN/deepseek-open-platform-privacy-policy.html
                  </a>
                </li>
                <li>
                  DeepSeek 网页服务隐私政策：
                  <a
                    href="https://cdn.deepseek.com/policies/zh-CN/deepseek-privacy-policy.html"
                    target="_blank"
                    rel="noreferrer"
                    className="text-[#18181b] underline underline-offset-4 hover:opacity-65 break-all"
                  >
                    https://cdn.deepseek.com/policies/zh-CN/deepseek-privacy-policy.html
                  </a>
                </li>
              </ul>
              <p className="m-0">
                当您自行配置其他 OpenAI / Anthropic
                兼容接口或自部署模型服务时，您的请求内容、附件与凭据将直接发送至您填写的接口地址。请在配置前自行核对该服务商的运营主体、服务器所在地及隐私政策。
              </p>
            </section>

            {/* 4 */}
            <section className="space-y-3 border-t border-[#e8e8e8] pt-9">
              <h2 className="text-[22px] font-medium tracking-[-0.4px] text-[#18181b]">
                4. 信息存储地点与保存期限
              </h2>
              <ul className="list-disc pl-5 space-y-2 m-0">
                <li>
                  <strong className="font-medium text-[#18181b]">本地数据：</strong>
                  您的历史对话、附件、模型配置及偏好设置均保存在您的设备本地（API
                  凭据通过系统安全存储加密保存），保存至您主动删除相应对话、清除应用数据或卸载应用为止。
                </li>
                <li>
                  <strong className="font-medium text-[#18181b]">第三方服务商数据：</strong>
                  由您主动发送至 DeepSeek
                  或其他自定义接口的数据，其存储地点与保存期限以对应服务商公布的隐私政策为准（DeepSeek
                  官方服务位于中国境内）。
                </li>
                <li>
                  <strong className="font-medium text-[#18181b]">用户自行导出的备份：</strong>
                  历史导出的 .zip 或分享的 .nuwa 文件不含您的 API Key /
                  授权令牌，但包含会话文本与本地图片，请妥善保管并按需自行删除。
                </li>
              </ul>
            </section>

            {/* 5 */}
            <section className="space-y-3 border-t border-[#e8e8e8] pt-9">
              <h2 className="text-[22px] font-medium tracking-[-0.4px] text-[#18181b]">
                5. 管理您的信息与权利
              </h2>
              <p className="m-0">您可以随时自主控制和管理您的全部数据：</p>
              <ul className="list-disc pl-5 space-y-2 m-0">
                <li>
                  <strong className="font-medium text-[#18181b]">查看与删除会话：</strong>
                  在会话列表中可单个删除、批量删除，或在「设置 →
                  数据管理」中一键导出备份或清空全部本地历史记录与附件。
                </li>
                <li>
                  <strong className="font-medium text-[#18181b]">管理与退出账号：</strong>
                  在「设置 → 账号管理」中随时修改、清空 API Key，或退出 DeepSeek
                  授权（退出时会清除本机令牌与账号信息，并向 DeepSeek 请求撤销授权令牌）。
                </li>
                <li>
                  <strong className="font-medium text-[#18181b]">撤回系统权限：</strong>
                  您可随时在设备系统设置中关闭 Nuwa 的麦克风或语音识别权限。
                </li>
                <li>
                  <strong className="font-medium text-[#18181b]">清除全部本地数据：</strong>
                  卸载本应用或在系统设置中清除应用数据，即可彻底移除本机保存的全部记录与设置。
                </li>
              </ul>
              <p className="m-0">
                如您对本政策或个人信息权利（查阅、更正、删除、撤回同意等）有任何疑问或请求，均可通过下方联系方式与我们联系。对于由第三方
                AI 服务商保存的数据，请直接向对应服务商提出请求。
              </p>
            </section>

            {/* 6 */}
            <section className="space-y-3 border-t border-[#e8e8e8] pt-9">
              <h2 className="text-[22px] font-medium tracking-[-0.4px] text-[#18181b]">
                6. 未成年人保护与政策更新
              </h2>
              <p className="m-0">
                未成年人请在监护人指导下阅读本政策并使用本应用。若涉及不满十四周岁未成年人的个人信息，我们将严格按照适用法律法规处理。
              </p>
              <p className="m-0">
                本政策如有更新，我们将在本页面（
                <a
                  href="https://rankchord.com/nuwa/privacy"
                  className="text-[#18181b] underline underline-offset-4 hover:opacity-65"
                >
                  https://rankchord.com/nuwa/privacy
                </a>
                ）及应用内公布最新版本与更新日期。如涉及重大变更，我们将以显著方式提示您。
              </p>
            </section>

            {/* 7 */}
            <section className="space-y-3 border-t border-[#e8e8e8] pt-9">
              <h2 className="text-[22px] font-medium tracking-[-0.4px] text-[#18181b]">
                7. 如何联系我们
              </h2>
              <p className="m-0">
                如您对本隐私政策有任何疑问、意见、建议或隐私权利请求，请通过以下方式联系我们，我们将在核实后尽快回复：
              </p>
              <div className="rounded-[14px] border border-[#e8e8e8] bg-[#f6f6f6] p-5 space-y-1.5 text-[14px]">
                <p className="m-0">
                  <strong className="font-medium text-[#18181b]">运营主体：</strong>
                  广州秩弦科技有限公司
                </p>
                <p className="m-0">
                  <strong className="font-medium text-[#18181b]">电子邮箱：</strong>
                  <a
                    href="mailto:yaoyulin@rankchord.com"
                    className="text-[#18181b] underline underline-offset-4 hover:opacity-65"
                  >
                    yaoyulin@rankchord.com
                  </a>
                </p>
                <p className="m-0">
                  <strong className="font-medium text-[#18181b]">联系电话：</strong>
                  +86 13711125206
                </p>
                <p className="m-0">
                  <strong className="font-medium text-[#18181b]">官方网站：</strong>
                  <a
                    href="https://rankchord.com/nuwa"
                    className="text-[#18181b] underline underline-offset-4 hover:opacity-65"
                  >
                    https://rankchord.com/nuwa
                  </a>
                </p>
                <p className="m-0">
                  <strong className="font-medium text-[#18181b]">公司地址：</strong>
                  广州市番禺区大龙街市新路新水坑段1号B座420
                </p>
              </div>
              <p className="m-0 text-[14px] text-[#686d74]">
                如您对我们的回复不满意，特别是认为个人信息处理行为损害了您的合法权益，您还可以通过向有管辖权的人民法院提起诉讼，或向相关监管机构投诉等外部途径解决。
              </p>
            </section>
          </div>
        </div>
      </section>

      {/* English Summary */}
      <section className="border-t border-[#e8e8e8] bg-[#fafafa] py-[56px] max-[680px]:py-[40px]">
        <div className="site-container">
          <div className="max-w-[820px] mx-auto space-y-6 text-[14px] leading-[1.8] text-[#4b4f55]">
            <div>
              <p className="eyebrow">ENGLISH SUMMARY</p>
              <h2 className="mt-2.5 text-[24px] font-medium tracking-[-0.5px] text-[#18181b]">
                Nuwa Privacy Policy (English Summary)
              </h2>
              <div className="mt-3 flex flex-wrap gap-x-6 gap-y-1 text-[13px] text-[#686d74]">
                <span>Last Updated: November 21, 2026</span>
                <span>Effective Date: November 21, 2026</span>
              </div>
            </div>

            <p className="m-0">
              Nuwa (including the Nuwa AI app and its Share Extension) is developed by Canton
              RankChord Technology Co., Ltd. (&ldquo;we&rdquo;, &ldquo;us&rdquo;). Nuwa is a
              local-first, bring-your-own-key (BYOK) AI chat client that connects directly to
              user-selected AI providers (such as DeepSeek Open Platform or user-configured
              OpenAI/Anthropic-compatible APIs).
            </p>

            <div className="space-y-2">
              <h3 className="text-[16px] font-medium text-[#18181b]">Key Commitments</h3>
              <ul className="list-disc pl-5 space-y-1.5 m-0">
                <li>
                  <strong className="font-medium text-[#18181b]">
                    No Developer Data Collection or Tracking:
                  </strong>{' '}
                  We do not operate relay servers, and we do not collect, store, sell, or track your
                  conversations, attachments, API keys, auth tokens, or personal data. No
                  third-party advertising or tracking SDKs are integrated.
                </li>
                <li>
                  <strong className="font-medium text-[#18181b]">
                    Direct Connection to Your Chosen Provider:
                  </strong>{' '}
                  Conversations, attachments, manual region preference (if set), and API credentials
                  are stored locally on your device (credentials in Apple Keychain on iOS) and sent
                  directly to the AI provider you choose only when you initiate a request.
                </li>
              </ul>
            </div>

            <div className="space-y-2">
              <h3 className="text-[16px] font-medium text-[#18181b]">Permissions &amp; Features</h3>
              <ul className="list-disc pl-5 space-y-1.5 m-0">
                <li>
                  <strong className="font-medium text-[#18181b]">
                    Microphone &amp; Speech Recognition (iOS):
                  </strong>{' '}
                  Requested solely when you actively use voice input (SFSpeechRecognizer / on-device
                  or configured speech service). Never used in the background.
                </li>
                <li>
                  <strong className="font-medium text-[#18181b]">Photos &amp; Files:</strong>{' '}
                  Accessed strictly via native system pickers for items you explicitly select; full
                  photo library access is never requested.
                </li>
                <li>
                  <strong className="font-medium text-[#18181b]">
                    Share Extension &amp; Local App Group:
                  </strong>{' '}
                  Files, ZIP archives, or text shared to Nuwa from other apps are passed locally via
                  the device App Group container (<code>group.com.rankchord.nuwa</code>) and deleted
                  immediately after processing.
                </li>
                <li>
                  <strong className="font-medium text-[#18181b]">
                    AirDrop / Proximity Sharing &amp; Optional iCloud Backup:
                  </strong>{' '}
                  Session packages (.nuwa) shared via AirDrop are transferred peer-to-peer by iOS.
                  Optional iCloud backup (disabled by default) writes only to your own Apple iCloud
                  Drive.
                </li>
                <li>
                  <strong className="font-medium text-[#18181b]">Third-Party Providers:</strong>{' '}
                  When using DeepSeek services, data sent to DeepSeek is governed by DeepSeek&apos;s
                  privacy policies (
                  <a
                    href="https://cdn.deepseek.com/policies/zh-CN/deepseek-open-platform-privacy-policy.html"
                    target="_blank"
                    rel="noreferrer"
                    className="text-[#18181b] underline underline-offset-4 hover:opacity-65"
                  >
                    Open Platform
                  </a>{' '}
                  /{' '}
                  <a
                    href="https://cdn.deepseek.com/policies/zh-CN/deepseek-privacy-policy.html"
                    target="_blank"
                    rel="noreferrer"
                    className="text-[#18181b] underline underline-offset-4 hover:opacity-65"
                  >
                    Web Service
                  </a>
                  ). Custom endpoints are governed by their respective operators.
                </li>
              </ul>
            </div>

            <div className="space-y-2">
              <h3 className="text-[16px] font-medium text-[#18181b]">Data Control &amp; Contact</h3>
              <p className="m-0">
                You can export or delete individual/all local chats in Settings → Data Management,
                revoke/clear credentials in Settings → Account Management, or uninstall the app to
                remove all local data.
              </p>
              <div className="rounded-[14px] border border-[#e8e8e8] bg-white p-5 space-y-1 text-[13px]">
                <p className="m-0">
                  <strong className="font-medium text-[#18181b]">Developer:</strong> Canton
                  RankChord Technology Co., Ltd.
                </p>
                <p className="m-0">
                  <strong className="font-medium text-[#18181b]">Email:</strong>{' '}
                  <a
                    href="mailto:yaoyulin@rankchord.com"
                    className="text-[#18181b] underline underline-offset-4 hover:opacity-65"
                  >
                    yaoyulin@rankchord.com
                  </a>
                </p>
                <p className="m-0">
                  <strong className="font-medium text-[#18181b]">Phone:</strong> +86 13711125206
                </p>
                <p className="m-0">
                  <strong className="font-medium text-[#18181b]">Website:</strong>{' '}
                  <a
                    href="https://rankchord.com/nuwa"
                    className="text-[#18181b] underline underline-offset-4 hover:opacity-65"
                  >
                    https://rankchord.com/nuwa
                  </a>
                </p>
                <p className="m-0">
                  <strong className="font-medium text-[#18181b]">Address:</strong> Room 420,
                  Building B, No. 1 Xinshuikeng Section, Shixin Road, Dalong Street, Panyu District,
                  Guangzhou, China
                </p>
              </div>
            </div>
          </div>
        </div>
      </section>
    </div>
  );
}
