import { MessageEvents, worker } from '@kit.ArkTS';
import { NativeCodeHighlightReply, NativeCodeHighlightRequest } from '../native/NativeCodeHighlightQueue';
import { tokenizePrism } from '../native/prism/PrismNative';

const port = worker.workerPort;

port.onmessage = (event: MessageEvents): void => {
  const request = event.data as NativeCodeHighlightRequest;
  let payload = '';
  try {
    payload = tokenizePrism(request.language, request.source);
  } catch {
    // Unknown or failed grammars are rendered as the original unstyled source.
  }
  const reply: NativeCodeHighlightReply = { id: request.id, payload: payload };
  port.postMessage(reply);
};
