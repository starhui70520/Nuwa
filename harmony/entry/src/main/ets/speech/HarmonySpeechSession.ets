import { common, wantAgent } from '@kit.AbilityKit';
import { avSession } from '@kit.AVSessionKit';
import { backgroundTaskManager } from '@kit.BackgroundTasksKit';

const MAX_TITLE_LENGTH = 80;

function speechTitle(text: string, fallback: string): string {
  const sentence = /[^。！？.!?\n]+[。！？.!?]?/.exec(text)?.[0] ?? '';
  const title = sentence.replace(/\s+/g, ' ').trim() || fallback;
  const characters = Array.from(title);
  return characters.length <= MAX_TITLE_LENGTH ? title : characters.slice(0, MAX_TITLE_LENGTH - 1).join('').trim() + '…';
}

async function silently(action: () => Promise<void>): Promise<void> {
  try {
    await action();
  } catch {
    // The system can release media resources before the app clears its own state.
  }
}

export class HarmonySpeechSession {
  private pending: Promise<void> = Promise.resolve();
  private generation = 0;
  private session?: avSession.AVSession;
  private backgroundContext?: common.UIAbilityContext;
  private title: string = '';

  start(context: common.UIAbilityContext, id: string, line: string, artist: string, terminal: () => void): void {
    this.title = speechTitle(line, artist);
    const generation = ++this.generation;
    this.pending = this.pending.then(async (): Promise<void> => {
      await this.release();
      if (generation !== this.generation) return;
      try {
        const session = await avSession.createAVSession(context, 'NuwaReadAloud', 'audio');
        this.session = session;
        if (generation !== this.generation) return;
        const playing: avSession.AVPlaybackState = { state: avSession.PlaybackState.PLAYBACK_STATE_PLAY, speed: 1 };
        const stop = (): void => { if (generation === this.generation) terminal(); };
        // HarmonyOS enables its combined button when both handlers exist. Play is idempotent while speaking.
        session.on('play', (): void => {
          if (generation === this.generation) void silently((): Promise<void> => session.setAVPlaybackState(playing));
        });
        session.on('pause', stop);
        session.on('stop', stop);
        await session.setAVMetadata({ assetId: id, title: this.title, artist });
        if (generation !== this.generation) return;
        await session.setAVPlaybackState(playing);
        if (generation !== this.generation) return;
        await session.activate();
      } catch {
        await this.release();
        return;
      }
      if (generation !== this.generation) return;
      try {
        const launch = await wantAgent.getWantAgent({
          wants: [{ bundleName: context.abilityInfo.bundleName, abilityName: context.abilityInfo.name }],
          actionType: wantAgent.OperationType.START_ABILITY,
          requestCode: 0,
          wantAgentFlags: [wantAgent.WantAgentFlags.UPDATE_PRESENT_FLAG],
        });
        if (generation !== this.generation) return;
        const session = this.session;
        if (session) await silently((): Promise<void> => session.setLaunchAbility(launch));
        if (generation !== this.generation) return;
        await backgroundTaskManager.startBackgroundRunning(context, backgroundTaskManager.BackgroundMode.AUDIO_PLAYBACK, launch);
        this.backgroundContext = context;
      } catch {
        // Foreground read-aloud and its own media controls remain available without a continuous task.
      }
    });
  }

  updateTitle(id: string, line: string, artist: string): void {
    const title = speechTitle(line, artist);
    if (this.title === title) return;
    this.title = title;
    const generation = this.generation;
    this.pending = this.pending.then(async (): Promise<void> => {
      const session = this.session;
      if (generation === this.generation && this.title === title && session) {
        await silently((): Promise<void> => session.setAVMetadata({ assetId: id, title, artist }));
      }
    });
  }

  stop(): void {
    this.generation++;
    this.title = '';
    this.pending = this.pending.then((): Promise<void> => this.release());
  }

  private async release(): Promise<void> {
    const session = this.session;
    const context = this.backgroundContext;
    this.session = undefined;
    this.backgroundContext = undefined;
    if (session) {
      await silently((): Promise<void> => session.setAVPlaybackState({ state: avSession.PlaybackState.PLAYBACK_STATE_STOP, speed: 0 }));
      await silently((): Promise<void> => session.deactivate());
      await silently((): Promise<void> => session.destroy());
    }
    if (context) await silently((): Promise<void> => backgroundTaskManager.stopBackgroundRunning(context));
  }
}
