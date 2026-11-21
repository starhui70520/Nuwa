import { sendableContextManager } from '@kit.AbilityKit';

export interface HarmonyOfflineEnglishCommand {
  type: 'open' | 'audio' | 'finish';
  context?: sendableContextManager.SendableContext;
  pcm?: ArrayBuffer;
}

export interface HarmonyOfflineEnglishReply {
  type: 'opened' | 'result' | 'error';
  text?: string;
}
