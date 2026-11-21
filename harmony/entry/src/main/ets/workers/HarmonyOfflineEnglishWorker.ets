import { sendableContextManager } from '@kit.AbilityKit';
import { MessageEvents, worker } from '@kit.ArkTS';
import { OnlineModelConfig, OnlineRecognizer, OnlineRecognizerConfig, OnlineStream } from 'sherpa_onnx';
import { HarmonyOfflineEnglishCommand, HarmonyOfflineEnglishReply } from '../speech/HarmonyOfflineEnglishMessages';
import { HARMONY_ASR_SAMPLE_RATE } from '../speech/HarmonySpeechWav';

const port = worker.workerPort;
let recognizer: OnlineRecognizer | undefined;
let stream: OnlineStream | undefined;
let hasAudio = false;

function reply(message: HarmonyOfflineEnglishReply): void {
  port.postMessage(message);
}

function open(context: sendableContextManager.SendableContext): void {
  const manager = sendableContextManager.convertToUIAbilityContext(context).resourceManager;
  const model = new OnlineModelConfig();
  model.transducer.encoder = 'en-model/encoder-epoch-99-avg-1.int8.onnx';
  model.transducer.decoder = 'en-model/decoder-epoch-99-avg-1.onnx';
  model.transducer.joiner = 'en-model/joiner-epoch-99-avg-1.onnx';
  model.tokens = 'en-model/tokens.txt';
  model.modelType = 'zipformer';
  model.numThreads = 2;

  const config = new OnlineRecognizerConfig();
  config.modelConfig = model;
  recognizer = new OnlineRecognizer(config, manager);
  stream = recognizer.createStream();
  reply({ type: 'opened' });
}

function decodePending(model: OnlineRecognizer, utterance: OnlineStream): void {
  while (model.isReady(utterance)) {
    model.decode(utterance);
  }
}

function appendAudio(model: OnlineRecognizer, utterance: OnlineStream, data: ArrayBuffer): void {
  const samples = new Float32Array(Math.floor(data.byteLength / 2));
  const pcm = new DataView(data);
  for (let index = 0; index < samples.length; index++) {
    samples[index] = pcm.getInt16(index * 2, true) / 32768;
  }
  if (samples.length > 0) {
    utterance.acceptWaveform({ samples: samples, sampleRate: HARMONY_ASR_SAMPLE_RATE });
    hasAudio = true;
    decodePending(model, utterance);
  }
}

function finish(model: OnlineRecognizer, utterance: OnlineStream): void {
  let text = '';
  if (hasAudio) {
    // Pad the encoder lookahead so the last spoken words are decoded.
    utterance.acceptWaveform({ samples: new Float32Array(HARMONY_ASR_SAMPLE_RATE / 2), sampleRate: HARMONY_ASR_SAMPLE_RATE });
    utterance.inputFinished();
    decodePending(model, utterance);
    text = model.getResult(utterance).text.trim();
  }
  stream = undefined;
  recognizer = undefined;
  reply({ type: 'result', text: text });
}

port.onmessage = (event: MessageEvents): void => {
  const command = event.data as HarmonyOfflineEnglishCommand;
  try {
    if (command.type === 'open' && command.context) {
      open(command.context);
    } else if (command.type === 'audio' && command.pcm && recognizer && stream) {
      appendAudio(recognizer, stream, command.pcm);
    } else if (command.type === 'finish' && recognizer && stream) {
      finish(recognizer, stream);
    }
  } catch {
    stream = undefined;
    recognizer = undefined;
    reply({ type: 'error' });
  }
};

port.onmessageerror = (): void => { reply({ type: 'error' }); };
