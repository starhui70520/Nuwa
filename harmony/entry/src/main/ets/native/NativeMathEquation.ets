import { NativeMathNode } from './NativeMarkdownMath';

function expressionWidth(expression: NativeMathNode, size: number): number {
  if (expression.text) return Array.from(expression.text).length * size * 0.63;
  if (expression.kind === 'fraction') {
    return Math.max(expressionWidth(expression.parts[0], size * 0.8),
      expressionWidth(expression.parts[1], size * 0.8)) + 8;
  }
  if (expression.kind === 'script') {
    const high = expression.high ? expressionWidth(expression.high, size * 0.68) : 0;
    const low = expression.low ? expressionWidth(expression.low, size * 0.68) : 0;
    return expressionWidth(expression.parts[0], size) + Math.max(high, low);
  }
  if (expression.kind === 'radical') return size + expressionWidth(expression.parts[0], size);
  return expression.parts.reduce((width: number, part: NativeMathNode): number =>
    width + expressionWidth(part, size), 0);
}

@Component
struct MathNodeView {
  @Prop expression: NativeMathNode = { kind: 'text', text: '', parts: [] };
  @Prop formulaFontSize: number = 17;
  @Prop font: string = '';

  private childFont(): string {
    const kind = this.expression.kind;
    return kind === 'mathbf' || kind === 'mathrm' || kind === 'mathit' ? kind : this.font;
  }

  build() {
    if (this.expression.kind === 'fraction') {
      Column({ space: 2 }) {
        MathNodeView({ expression: this.expression.parts[0], formulaFontSize: this.formulaFontSize * 0.8, font: this.font })
        Row()
          .width(Math.max(this.formulaFontSize * 0.7, expressionWidth(this.expression, this.formulaFontSize)))
          .height(1)
          .backgroundColor($r('app.color.native_chat_primary'))
        MathNodeView({ expression: this.expression.parts[1], formulaFontSize: this.formulaFontSize * 0.8, font: this.font })
      }
      .padding({ left: 2, right: 2 })
      .alignItems(HorizontalAlign.Center)
    } else if (this.expression.kind === 'radical') {
      Row() {
        if (this.expression.high) {
          MathNodeView({ expression: this.expression.high, formulaFontSize: this.formulaFontSize * 0.6, font: this.font })
            .alignSelf(ItemAlign.Start)
        }
        Text('√')
          .fontColor($r('app.color.native_chat_primary'))
          .fontSize(this.formulaFontSize * 1.25)
          .alignSelf(ItemAlign.End)
        Row() {
          MathNodeView({ expression: this.expression.parts[0], formulaFontSize: this.formulaFontSize, font: this.font })
        }
        .padding({ top: 2, right: 2 })
        .border({ width: { top: 1 }, color: $r('app.color.native_chat_primary') })
      }
      .alignItems(VerticalAlign.Center)
    } else if (this.expression.kind === 'script') {
      Row() {
        MathNodeView({ expression: this.expression.parts[0], formulaFontSize: this.formulaFontSize, font: this.font })
        Column() {
          if (this.expression.high) {
            MathNodeView({ expression: this.expression.high, formulaFontSize: this.formulaFontSize * 0.68, font: this.font })
          }
          if (this.expression.low) {
            MathNodeView({ expression: this.expression.low, formulaFontSize: this.formulaFontSize * 0.68, font: this.font })
          }
        }
        .alignItems(HorizontalAlign.Start)
        .alignSelf(this.expression.low && this.expression.high ? ItemAlign.Center :
          this.expression.low ? ItemAlign.End : ItemAlign.Start)
      }
      .alignItems(VerticalAlign.Center)
    } else if (this.expression.parts.length) {
      Row() {
        ForEach(this.expression.parts, (part: NativeMathNode) => {
          MathNodeView({ expression: part, formulaFontSize: this.formulaFontSize, font: this.childFont() })
        }, (part: NativeMathNode, index: number): string => index + ':' + part.kind)
      }
      .alignItems(VerticalAlign.Center)
    } else if (this.expression.text) {
      Text(this.expression.text)
        .fontColor($r('app.color.native_chat_primary'))
        .fontFamily('serif')
        .fontSize(this.formulaFontSize)
        .fontStyle(this.font === 'mathit' || (this.font !== 'mathrm' && this.expression.kind === 'variable') ?
          FontStyle.Italic : FontStyle.Normal)
        .fontWeight(this.font === 'mathbf' ? FontWeight.Bold : FontWeight.Regular)
        .maxLines(1)
    }
  }
}

@Component
export struct NativeMathEquation {
  @Prop expression: NativeMathNode | null = null;
  @Prop source: string = '';
  @Prop formulaFontSize: number = 17;

  build() {
    if (this.expression) {
      Scroll() {
        Row() {
          MathNodeView({ expression: this.expression, formulaFontSize: this.formulaFontSize })
        }
        .padding({ top: 7, bottom: 7, left: 4, right: 4 })
        .accessibilityGroup(true)
        .accessibilityText(this.source)
      }
      .scrollable(ScrollDirection.Horizontal)
      .scrollBar(BarState.Auto)
      .align(Alignment.Center)
      .width('100%')
    } else {
      Text(this.source)
        .fontColor($r('app.color.native_chat_primary'))
        .fontSize(this.formulaFontSize)
        .width('100%')
        .copyOption(CopyOptions.LocalDevice)
    }
  }
}
