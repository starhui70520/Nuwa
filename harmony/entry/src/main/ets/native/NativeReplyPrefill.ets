/** Ordered assistant content used for chat history and Continue requests. */
export interface NativePrefillBlock {
  type: 'text' | 'thinking' | 'separator';
  text: string;
  signature?: string;
}

/** Recover the best ordered prefix available in local snapshots predating block preservation. */
export function nativeReplyPrefillBlocks(text: string, reasoning: string,
  thinkingSignature: string): NativePrefillBlock[] {
  const blocks: NativePrefillBlock[] = [];
  if (reasoning.trim()) {
    blocks.push({ type: 'thinking', text: reasoning, signature: thinkingSignature });
  }
  if (text !== '') {
    blocks.push({ type: 'text', text: text });
  }
  return blocks;
}

export function copyNativePrefillBlocks(blocks: NativePrefillBlock[] | undefined): NativePrefillBlock[] | undefined {
  return blocks?.map((block: NativePrefillBlock): NativePrefillBlock => ({
    type: block.type,
    text: block.text,
    signature: block.signature,
  }));
}

export function validNativePrefillBlocks(blocks: NativePrefillBlock[]): boolean {
  return Array.isArray(blocks) && blocks.every((block: NativePrefillBlock): boolean =>
    !!block && (block.type === 'text' || block.type === 'thinking' ||
      (block.type === 'separator' && block.text === '')) && typeof block.text === 'string' &&
    (block.signature === undefined || (block.type === 'thinking' && typeof block.signature === 'string')));
}
