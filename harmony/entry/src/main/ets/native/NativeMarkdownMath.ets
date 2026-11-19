/** Bounded TeX subset used by the native ArkUI equation components. */
export interface NativeMathNode {
  kind: string;
  text: string;
  parts: NativeMathNode[];
  high?: NativeMathNode;
  low?: NativeMathNode;
}

export interface NativeMathSpan {
  text: string;
  scale: number;
  offset: number;
  italic: boolean;
  bold: boolean;
}

export interface NativeMathMatch {
  start: number;
  end: number;
  formula: string;
}

const MAX_FORMULA = 2048;
const MAX_DEPTH = 12;
const MAX_NODES = 384;

const symbols = new Map<string, string>([
  ['alpha', 'α'], ['beta', 'β'], ['gamma', 'γ'], ['delta', 'δ'], ['epsilon', 'ϵ'], ['varepsilon', 'ε'],
  ['zeta', 'ζ'], ['eta', 'η'], ['theta', 'θ'], ['vartheta', 'ϑ'], ['iota', 'ι'], ['kappa', 'κ'], ['lambda', 'λ'],
  ['mu', 'μ'], ['nu', 'ν'], ['xi', 'ξ'], ['pi', 'π'], ['varpi', 'ϖ'], ['rho', 'ρ'], ['varrho', 'ϱ'], ['sigma', 'σ'],
  ['varsigma', 'ς'], ['tau', 'τ'], ['upsilon', 'υ'], ['phi', 'ϕ'], ['varphi', 'φ'], ['chi', 'χ'], ['psi', 'ψ'], ['omega', 'ω'],
  ['Gamma', 'Γ'], ['Delta', 'Δ'], ['Theta', 'Θ'], ['Lambda', 'Λ'], ['Xi', 'Ξ'], ['Pi', 'Π'], ['Sigma', 'Σ'],
  ['Upsilon', 'Υ'], ['Phi', 'Φ'], ['Psi', 'Ψ'], ['Omega', 'Ω'],
  ['infty', '∞'], ['partial', '∂'], ['nabla', '∇'], ['ell', 'ℓ'], ['hbar', 'ℏ'], ['Re', 'ℜ'], ['Im', 'ℑ'],
  ['forall', '∀'], ['exists', '∃'], ['neg', '¬'], ['emptyset', '∅'], ['varnothing', '∅'],
  ['in', '∈'], ['notin', '∉'], ['ni', '∋'], ['subset', '⊂'], ['supset', '⊃'], ['subseteq', '⊆'], ['supseteq', '⊇'],
  ['cap', '∩'], ['cup', '∪'], ['wedge', '∧'], ['vee', '∨'], ['land', '∧'], ['lor', '∨'], ['setminus', '∖'],
  ['sum', '∑'], ['prod', '∏'], ['int', '∫'], ['iint', '∬'], ['iiint', '∭'], ['oint', '∮'],
  ['times', '×'], ['div', '÷'], ['cdot', '·'], ['ast', '∗'], ['circ', '∘'], ['bullet', '•'], ['star', '⋆'],
  ['pm', '±'], ['mp', '∓'], ['le', '≤'], ['leq', '≤'], ['ge', '≥'], ['geq', '≥'], ['neq', '≠'], ['ne', '≠'], ['equiv', '≡'],
  ['approx', '≈'], ['sim', '∼'], ['simeq', '≃'], ['cong', '≅'], ['propto', '∝'], ['perp', '⊥'], ['parallel', '∥'],
  ['to', '→'], ['gets', '←'], ['rightarrow', '→'], ['leftarrow', '←'], ['leftrightarrow', '↔'], ['mapsto', '↦'],
  ['Rightarrow', '⇒'], ['Leftarrow', '⇐'], ['Leftrightarrow', '⇔'], ['implies', '⇒'], ['iff', '⇔'],
  ['longrightarrow', '⟶'], ['longleftarrow', '⟵'], ['Longrightarrow', '⟹'],
  ['ldots', '…'], ['dots', '…'], ['cdots', '⋯'], ['vdots', '⋮'], ['ddots', '⋱'], ['langle', '⟨'], ['rangle', '⟩'],
  ['lvert', '|'], ['rvert', '|'], ['vert', '|'], ['lVert', '‖'], ['rVert', '‖'], ['Vert', '‖'],
  ['lbrace', '{'], ['rbrace', '}'], ['lfloor', '⌊'], ['rfloor', '⌋'], ['lceil', '⌈'], ['rceil', '⌉'],
  ['prime', '′'], ['degree', '°'], ['angle', '∠'], ['triangle', '△'], ['checkmark', '✓'],
]);

const functions = new Set<string>([
  'arccos', 'arcsin', 'arctan', 'arg', 'cos', 'cosh', 'cot', 'csc', 'deg', 'det', 'dim',
  'exp', 'gcd', 'hom', 'inf', 'ker', 'lim', 'liminf', 'limsup', 'ln', 'log', 'max', 'min',
  'sec', 'sin', 'sinh', 'sup', 'tan', 'tanh',
]);

const spaces = new Map<string, string>([
  [',', ' '], [':', ' '], [';', ' '], ['!', ''], [' ', ' '], ['quad', ' '], ['qquad', '  '],
  ['enspace', ' '], ['thinspace', ' '], ['medspace', ' '], ['thickspace', ' '],
]);

const escaped = new Map<string, string>([
  ['{', '{'], ['}', '}'], ['%', '%'], ['$', '$'], ['#', '#'], ['_', '_'], ['&', '&'], ['|', '‖'],
]);

function node(kind: string, text: string = '', parts: NativeMathNode[] = []): NativeMathNode {
  return { kind, text, parts };
}

class MathParser {
  private pos: number = 0;
  private nodes: number = 0;
  private readonly source: string;

  constructor(source: string) {
    this.source = source;
  }

  parse(): NativeMathNode {
    return this.group('', 0);
  }

  private skipSpace(): void {
    while (/\s/.test(this.source.charAt(this.pos))) this.pos++;
  }

  private group(close: string, depth: number): NativeMathNode {
    if (depth > MAX_DEPTH) throw new Error('Math expression is too deep');
    const parts: NativeMathNode[] = [];
    this.skipSpace();
    while (this.pos < this.source.length && this.source.charAt(this.pos) !== close) {
      const item = this.atom(depth);
      this.skipSpace();
      let high: NativeMathNode | undefined;
      let low: NativeMathNode | undefined;
      if (this.source.charAt(this.pos) === "'") {
        const begin = this.pos;
        while (this.source.charAt(this.pos) === "'") this.pos++;
        high = node('text', '′'.repeat(this.pos - begin));
        this.skipSpace();
      }
      let next = this.source.charAt(this.pos);
      while (next === '^' || next === '_') {
        this.pos++;
        if (next === '^' && !high) high = this.atom(depth + 1);
        else if (next === '_' && !low) low = this.atom(depth + 1);
        else throw new Error('Repeated math script');
        this.skipSpace();
        next = this.source.charAt(this.pos);
      }
      if (high || low) {
        const script = node('script', '', [item]);
        script.high = high;
        script.low = low;
        parts.push(script);
      } else {
        parts.push(item);
      }
    }
    if (close) {
      if (this.source.charAt(this.pos) !== close) throw new Error('Incomplete math group');
      this.pos++;
    }
    return node('group', '', parts);
  }

  private atom(depth: number): NativeMathNode {
    if (++this.nodes > MAX_NODES || depth > MAX_DEPTH) throw new Error('Math expression is too large');
    this.skipSpace();
    const char = this.source.charAt(this.pos++);
    if (!char || char === '}' || char === '^' || char === '_' || char === '$' || char === '%' || char === '&') {
      throw new Error('Unsupported math atom');
    }
    if (char === '{') return this.group('}', depth + 1);
    if (char !== '\\') {
      if (/[+\-*=<>]/.test(char)) {
        const operator = char === '-' ? '−' : char === '*' ? '∗' : char;
        return node('text', ' ' + operator + ' ');
      }
      return node(/[A-Za-z]/.test(char) ? 'variable' : 'text', char);
    }

    const start = this.pos;
    while (/[A-Za-z]/.test(this.source.charAt(this.pos))) this.pos++;
    const command = this.pos === start ? this.source.charAt(this.pos++) : this.source.slice(start, this.pos);
    const value = symbols.get(command) ?? escaped.get(command) ?? spaces.get(command);
    if (value !== undefined) return node('text', value);
    if (functions.has(command)) return node('text', command);
    if (command === 'frac' || command === 'dfrac' || command === 'tfrac') {
      return node('fraction', '', [this.atom(depth + 1), this.atom(depth + 1)]);
    }
    if (command === 'sqrt') {
      this.skipSpace();
      let degree: NativeMathNode | undefined;
      if (this.source.charAt(this.pos) === '[') {
        this.pos++;
        degree = this.group(']', depth + 1);
      }
      const root = node('radical', '', [this.atom(depth + 1)]);
      root.high = degree;
      return root;
    }
    if (command === 'text' || command === 'operatorname') return this.textGroup();
    if (command === 'mathrm' || command === 'mathbf' || command === 'mathit') {
      return node(command, '', [this.atom(depth + 1)]);
    }
    if (command === 'left' || command === 'right' || command === 'middle' ||
      /^(?:[bB]ig{1,2})[lrm]?$/.test(command)) {
      this.skipSpace();
      if (this.source.charAt(this.pos) === '.') {
        this.pos++;
        return node('text');
      }
      return this.atom(depth + 1);
    }
    throw new Error('Unsupported math command');
  }

  private textGroup(): NativeMathNode {
    this.skipSpace();
    if (this.source.charAt(this.pos++) !== '{') throw new Error('Expected text group');
    const start = this.pos;
    while (this.pos < this.source.length) {
      const char = this.source.charAt(this.pos++);
      if (char === '}') return node('text', this.source.slice(start, this.pos - 1));
      if (char === '{' || char === '\\') break;
    }
    throw new Error('Unsupported TeX text group');
  }
}

export function parseNativeMath(source: string): NativeMathNode | null {
  if (!source.trim() || source.length > MAX_FORMULA) return null;
  try {
    return new MathParser(source).parse();
  } catch {
    return null;
  }
}

function appendInline(result: NativeMathSpan[], text: string, scale: number, offset: number,
  italic: boolean = false, bold: boolean = false): void {
  if (!text) return;
  const last = result[result.length - 1];
  if (last && last.scale === scale && last.offset === offset && last.italic === italic && last.bold === bold) {
    last.text += text;
  } else {
    result.push({ text, scale, offset, italic, bold });
  }
}

function flattenMath(item: NativeMathNode, result: NativeMathSpan[], scale: number, offset: number,
  font: string): void {
  if (item.kind === 'text' || item.kind === 'variable') {
    appendInline(result, item.text, scale, offset, font === 'mathit' || (font !== 'mathrm' &&
      item.kind === 'variable'), font === 'mathbf');
    return;
  }
  if (item.kind === 'script') {
    flattenMath(item.parts[0], result, scale, offset, font);
    if (item.low) flattenMath(item.low, result, scale * 0.72, offset - 0.20 * scale, font);
    if (item.high) flattenMath(item.high, result, scale * 0.72, offset + 0.38 * scale, font);
    return;
  }
  if (item.kind === 'fraction') {
    flattenOperand(item.parts[0], result, scale, offset, font);
    appendInline(result, '⁄', scale, offset);
    flattenOperand(item.parts[1], result, scale, offset, font);
    return;
  }
  if (item.kind === 'radical') {
    if (item.high) flattenMath(item.high, result, scale * 0.60, offset + 0.35 * scale, font);
    appendInline(result, '√', scale, offset);
    flattenOperand(item.parts[0], result, scale, offset, font);
    return;
  }
  const nextFont = item.kind === 'mathbf' || item.kind === 'mathrm' || item.kind === 'mathit' ? item.kind : font;
  for (const part of item.parts) flattenMath(part, result, scale, offset, nextFont);
}

function flattenOperand(item: NativeMathNode, result: NativeMathSpan[], scale: number, offset: number,
  font: string): void {
  if (item.kind === 'group' && item.parts.length === 1) {
    flattenOperand(item.parts[0], result, scale, offset, font);
    return;
  }
  const wrap = item.kind !== 'text' && item.kind !== 'variable';
  if (wrap) appendInline(result, '(', scale, offset);
  flattenMath(item, result, scale, offset, font);
  if (wrap) appendInline(result, ')', scale, offset);
}

export function nativeMathSpans(root: NativeMathNode): NativeMathSpan[] {
  const result: NativeMathSpan[] = [];
  flattenMath(root, result, 1, 0, '');
  return result;
}

function dollarRun(input: string, offset: number): number {
  let end = offset;
  while (input.charAt(end) === '$') end++;
  return end - offset;
}

function codeEnd(input: string, start: number, ticks: string): number {
  const run = /\x60+/g;
  run.lastIndex = start;
  let match = run.exec(input);
  while (match) {
    if (match[0].length === ticks.length) return match.index + ticks.length;
    match = run.exec(input);
  }
  return -1;
}

export function findNativeInlineMath(input: string, offset: number = 0): NativeMathMatch | null {
  const marker = /\\[$\\\x60]|\\[([]|\$+|\x60+/g;
  marker.lastIndex = offset;
  let opening = marker.exec(input);
  while (opening) {
    const start = opening.index;
    const delimiter = opening[0];
    const contentStart = start + delimiter.length;
    if (delimiter.charCodeAt(0) === 96) {
      const end = codeEnd(input, contentStart, delimiter);
      if (end >= 0) marker.lastIndex = end;
      opening = marker.exec(input);
      continue;
    }
    const closing = delimiter === '\\(' ? '\\)' : delimiter === '\\[' ? '\\]' : delimiter;
    if (!delimiter.startsWith('\\') || delimiter === '\\(' || delimiter === '\\[') {
      const end = findClosingMath(input, contentStart, delimiter, closing);
      if (end >= 0) {
        const formula = input.slice(contentStart, end).trim();
        if (formula && (delimiter !== '$' || !isCurrencyPair(input, contentStart, end))) {
          return { start, end: end + closing.length, formula };
        }
      }
    }
    opening = marker.exec(input);
  }
  return null;
}

function findClosingMath(input: string, start: number, opening: string, closing: string): number {
  const limit = Math.min(input.length, start + MAX_FORMULA + closing.length);
  for (let cursor = start; cursor < limit; cursor++) {
    const char = input.charAt(cursor);
    if (char.charCodeAt(0) === 96 || (char === '\n' && input.charAt(cursor + 1) === '\n')) return -1;
    if (input.startsWith(closing, cursor)) {
      if (closing.charAt(0) === '\\') return cursor;
      const run = dollarRun(input, cursor);
      if (run === opening.length) return cursor;
      cursor += run - 1;
    } else if (char === '\\') {
      // Escaped dollars and escaped backslashes cannot close a math span.
      cursor++;
    }
  }
  return -1;
}

function isCurrencyPair(input: string, begin: number, end: number): boolean {
  const after = input.charAt(end + 1);
  if (/\d/.test(after)) return true;
  return /^\d+(?:[.,]\d+)*[,.:;!?]?\s/.test(input.slice(begin, end)) && /\s/.test(input.charAt(end - 1));
}

/** A complete flow fence matches a standalone Markdown display equation. */
export function findNativeDisplayMath(lines: string[], index: number): NativeMathMatch | null {
  const first = lines[index].trim();
  const dollarFence = first.match(/^\$\$+/)?.[0] ?? '';
  const texFence = first.startsWith('\\[');
  if (!dollarFence && !texFence) return null;
  const sameLine = findNativeInlineMath(first);
  if (sameLine?.start === 0) {
    // The tagged Markdown parser treats paired dollars on one line as inline math.
    return texFence && sameLine.end === first.length ?
      { start: index, end: index + 1, formula: sameLine.formula } : null;
  }
  let length = texFence ? first.length - 2 : 0;
  for (let end = index + 1; end < lines.length; end++) {
    const line = lines[end];
    const last = line.trimEnd();
    const texClose = texFence && last.endsWith('\\]') &&
      findClosingMath(last, 0, '\\[', '\\]') === last.length - 2;
    const dollarClose = !texFence && /^\$\$+$/.test(last.trim()) && last.trim().length >= dollarFence.length;
    if (texClose || dollarClose) {
      const formulaLines = lines.slice(index + 1, end);
      if (texClose) {
        formulaLines.unshift(first.slice(2));
        formulaLines.push(last.slice(0, -2));
      }
      const formula = formulaLines.join('\n').trim();
      if (formula.length > MAX_FORMULA) return null;
      return formula ? { start: index, end: end + 1, formula } : null;
    }
    length += line.length + 1;
    if (length > MAX_FORMULA) return null;
  }
  return null;
}
