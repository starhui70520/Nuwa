import { NativeLocale } from './NativeLocation';

export type NativeReplyFailureKind = 'network' | 'upload' | 'response' | 'unsupported-image';

export interface NativeReplyFailure {
  kind: NativeReplyFailureKind;
  detail: string;
  status?: number;
}

export interface NativeReplyNotice {
  text: string;
  action?: 'api-key' | 'top-up';
}

export function nativeRefusalText(locale: NativeLocale): string {
  return locale === 'en-US' ? "Sorry, that's beyond my current scope. Let's talk about something else." :
    '你好，这个问题我暂时无法回答，让我们换个话题再聊聊吧。';
}

export function describeNativeReplyFailure(failure: NativeReplyFailure, locale: NativeLocale): NativeReplyNotice {
  const english = locale === 'en-US';
  switch (failure.kind) {
    case 'network':
      return { text: english ? 'Network error. Please check your network connection.' : '网络异常，请检查你的网络状况' };
    case 'upload':
      return { text: failure.detail || (english ? 'Upload failed' : '上传失败') };
    case 'unsupported-image':
      return {
        text: english ? 'Unsupported or corrupted image format. Use JPG, PNG, or WebP and try again.' :
          '图片格式不受支持或已损坏，请换用 JPG、PNG 或 WebP 图片后重试',
      };
  }
  switch (failure.status) {
    case 401:
      return {
        text: english ? 'The API Key is invalid or has been deleted. Replace it and try again.' :
          'API Key 无效或已被删除，请更换后重试', action: 'api-key',
      };
    case 402:
      return {
        text: english ? 'Insufficient account balance. Top up and try again.' : '账户余额不足，请充值后重试',
        action: 'top-up',
      };
    case 429:
      return { text: english ? 'Too many requests. Please try again later.' : '请求过于频繁，请稍后再试' };
  }
  if ((failure.status ?? 0) >= 500) {
    return { text: english ? 'Server busy. Please try again later.' : '服务器繁忙，请稍后再试' };
  }
  return { text: failure.detail || (english ? 'Reply failed. Please try again.' : '回复失败，请重试') };
}
