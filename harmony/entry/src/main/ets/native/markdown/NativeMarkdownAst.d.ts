export interface NativeMarkdownAstPoint {
  offset?: number;
}

export interface NativeMarkdownAstPosition {
  start: NativeMarkdownAstPoint;
  end: NativeMarkdownAstPoint;
}

export interface NativeMarkdownAstSource {
  index: number;
}

export interface NativeMarkdownAstNode {
  type: string;
  children?: NativeMarkdownAstNode[];
  value?: string;
  depth?: number;
  ordered?: boolean;
  start?: number | null;
  checked?: boolean | null;
  lang?: string | null;
  url?: string;
  alt?: string | null;
  align?: (string | null)[];
  position?: NativeMarkdownAstPosition;
  source?: NativeMarkdownAstSource;
}

export function toNativeMarkdownAst(input: string, sourceIndices: number[] | undefined,
  disableLink: boolean): NativeMarkdownAstNode;
