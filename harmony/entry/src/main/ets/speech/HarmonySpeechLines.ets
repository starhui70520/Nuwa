const LINE_LIMIT = 52;
const MIN_CLAUSE_LENGTH = 16;

function appendBoundedLines(lines: string[], text: string): void {
  let start = 0;
  while (start < text.length) {
    let end = Math.min(text.length, start + LINE_LIMIT);
    if (end < text.length) {
      const minimum = start + Math.floor(LINE_LIMIT / 2);
      for (let index = end - 1; index >= minimum; index--) {
        if (/\s/.test(text[index])) {
          end = index + 1;
          break;
        }
      }
      const unit = text.charCodeAt(end - 1);
      if (unit >= 0xd800 && unit <= 0xdbff) end--;
    }
    const line = text.slice(start, end).trim();
    if (line) lines.push(line);
    start = end;
  }
}

function appendClauses(lines: string[], sentence: string): void {
  if (sentence.length <= LINE_LIMIT) {
    if (sentence) lines.push(sentence);
    return;
  }
  let start = 0;
  for (let index = 0; index < sentence.length; index++) {
    const character = sentence[index];
    const next = sentence[index + 1] ?? '';
    const canBreak = '，、：'.includes(character) ||
      (',:'.includes(character) && (!next || /\s/.test(next)));
    if (canBreak && index + 1 - start >= MIN_CLAUSE_LENGTH) {
      appendBoundedLines(lines, sentence.slice(start, index + 1).trim());
      start = index + 1;
    }
  }
  appendBoundedLines(lines, sentence.slice(start).trim());
}

export function splitHarmonySpeechLines(text: string): string[] {
  const clauses: string[] = [];
  let start = 0;
  for (let index = 0; index < text.length; index++) {
    const character = text[index];
    const next = text[index + 1] ?? '';
    if ('。！？；\n'.includes(character) || ('.!?;'.includes(character) && (!next || /\s/.test(next)))) {
      appendClauses(clauses, text.slice(start, index + 1).trim());
      start = index + 1;
    }
  }
  appendClauses(clauses, text.slice(start).trim());
  const lines: string[] = [];
  for (const clause of clauses) {
    const index = lines.length - 1;
    const previous = lines[index];
    if (previous && (previous.length < 8 || clause.length < 8) && previous.length + clause.length + 1 <= 56) {
      const needsSpace = previous.charCodeAt(previous.length - 1) <= 127 && clause.charCodeAt(0) <= 127;
      lines[index] = previous + (needsSpace ? ' ' : '') + clause;
    } else {
      lines.push(clause);
    }
  }
  return lines;
}

function speechUnits(line: string): number {
  let units = 0;
  for (let index = 0; index < line.length; index++) {
    const character = line[index];
    if (line.charCodeAt(index) > 127) {
      units += /[\u3000-\u303f\uff00-\uffef]/.test(character) ? 0.4 : 1;
    } else if (!/\s/.test(character)) {
      units += /[.,!?;:]/.test(character) ? 0.35 : 0.45;
    }
  }
  return Math.max(1, units);
}

/** The cloud endpoint streams raw PCM. Estimate cue positions using the same speech weights as Android. */
export class HarmonySpeechLineTimeline {
  private readonly lines: string[];
  private readonly thresholds: number[] = [];
  private readonly estimatedSeconds: number;
  private index: number = 0;

  constructor(lines: string[]) {
    this.lines = lines;
    let total = 0;
    for (const line of lines) {
      this.thresholds.push(total);
      total += speechUnits(line);
    }
    for (let index = 0; index < this.thresholds.length; index++) {
      this.thresholds[index] /= total;
    }
    this.estimatedSeconds = Math.max(1.2, total * 0.24);
  }

  advance(playedSeconds: number, bufferedSeconds: number, streamEnded: boolean): string | undefined {
    const duration = streamEnded ? Math.max(0.5, bufferedSeconds) :
      Math.max(this.estimatedSeconds, bufferedSeconds + 0.8);
    const ratio = Math.min(0.999, Math.max(0, playedSeconds / duration));
    const before = this.index;
    while (this.index + 1 < this.thresholds.length && this.thresholds[this.index + 1] <= ratio) {
      this.index++;
    }
    return this.index > before ? this.lines[this.index] : undefined;
  }
}
