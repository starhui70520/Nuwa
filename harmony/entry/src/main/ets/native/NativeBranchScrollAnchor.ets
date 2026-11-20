import { LengthMetrics, UIContext } from '@kit.ArkUI';

const LAYOUT_FRAME_MS = 16;
const MAX_LAYOUT_ATTEMPTS = 4;

export function nativeBranchControlsId(messageId: string): string {
  return 'nuwa-branch-controls-' + messageId;
}

export function nativeBranchControlsTop(context: UIContext, messageId: string): number | undefined {
  try {
    const area = context.getComponentUtils().getRectangleById(nativeBranchControlsId(messageId));
    if (area.size.height <= 0 || !Number.isFinite(area.windowOffset.y)) return undefined;
    return context.px2vp(area.windowOffset.y);
  } catch {
    // A version can be outside the viewport while the lazy list is replacing it.
    return undefined;
  }
}

export class NativeBranchScrollAnchor {
  private timer: number = -1;

  cancel(): void {
    if (this.timer >= 0) clearTimeout(this.timer);
    this.timer = -1;
  }

  restore(context: UIContext, scroller: Scroller, messageId: string, listIndex: number, top: number,
    isCurrent: () => boolean): void {
    this.cancel();
    let attempt = 0;
    const align = (): void => {
      this.timer = -1;
      if (!isCurrent()) return;
      const currentTop = nativeBranchControlsTop(context, messageId);
      const row = scroller.getItemRect(listIndex);
      if (currentTop !== undefined && row.height > 0) {
        const distance = currentTop - top;
        if (Math.abs(distance) < 0.5) return;
        // The list can discard its previous absolute scroll offset when this row changes height.
        scroller.scrollToIndex(listIndex, false, ScrollAlign.START, {
          extraOffset: LengthMetrics.vp(distance - row.y),
        });
      } else if (attempt === 0) {
        scroller.scrollToIndex(listIndex, false, ScrollAlign.START);
      }
      if (++attempt < MAX_LAYOUT_ATTEMPTS) this.timer = setTimeout(align, LAYOUT_FRAME_MS);
    };
    this.timer = setTimeout(align, LAYOUT_FRAME_MS);
  }
}
