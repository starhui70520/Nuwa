import { common } from '@kit.AbilityKit';
import { privacyManager } from '@kit.AppGalleryKit';
import { url } from '@kit.ArkTS';

const HOSTED_PRIVACY_POLICY_URL =
  'https://agreement-drcn.hispace.dbankcloud.cn/index.html?lang=zh&agreementId=2086009982511225600';

export async function openNuwaPrivacyPolicy(context: common.UIAbilityContext): Promise<void> {
  let policyUrl = HOSTED_PRIVACY_POLICY_URL;
  try {
    const policy = privacyManager.getAppPrivacyMgmtInfo().privacyInfo.find(
      (link) => link.type === privacyManager.AppPrivacyLinkType.PRIVACY_STATEMENT_LINK
    );
    if (policy?.url) {
      const managedUrl = url.URL.parseURL(policy.url);
      if (managedUrl.protocol === 'https:') {
        policyUrl = managedUrl.href;
      }
    }
  } catch {
    // Sideloaded builds can lack AppGallery privacy metadata.
  }
  await context.openLink(policyUrl, { appLinkingOnly: false });
}
