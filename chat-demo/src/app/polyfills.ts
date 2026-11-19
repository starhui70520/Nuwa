type ObjectConstructorWithHasOwn = ObjectConstructor & {
  hasOwn?: (target: object, property: PropertyKey) => boolean
}

const objCtor = Object as ObjectConstructorWithHasOwn
if (typeof objCtor.hasOwn !== 'function') {
  objCtor.hasOwn = (target: object, property: PropertyKey): boolean =>
    Object.prototype.hasOwnProperty.call(target, property)
}

if (typeof Array.prototype.at !== 'function') {
  Object.defineProperty(Array.prototype, 'at', {
    value: function at<T>(this: T[], index: number): T | undefined {
      const len = this.length >>> 0
      const rel = Math.trunc(Number(index) || 0)
      const k = rel >= 0 ? rel : len + rel
      if (k < 0 || k >= len) {
        return undefined
      }
      return this[k]
    },
    writable: true,
    enumerable: false,
    configurable: true,
  })
}

if (typeof Array.prototype.toSorted !== 'function') {
  Object.defineProperty(Array.prototype, 'toSorted', {
    value: function toSorted<T>(this: T[], compareFn?: (a: T, b: T) => number): T[] {
      return [...this].sort(compareFn)
    },
    writable: true,
    enumerable: false,
    configurable: true,
  })
}

if (typeof Array.prototype.toReversed !== 'function') {
  Object.defineProperty(Array.prototype, 'toReversed', {
    value: function toReversed<T>(this: T[]): T[] {
      return [...this].reverse()
    },
    writable: true,
    enumerable: false,
    configurable: true,
  })
}

if (typeof Array.prototype.toSpliced !== 'function') {
  Object.defineProperty(Array.prototype, 'toSpliced', {
    value: function toSpliced<T>(
      this: T[],
      start: number,
      deleteCount?: number,
      ...items: T[]
    ): T[] {
      const copy = [...this]
      if (deleteCount === undefined) {
        copy.splice(start)
      } else {
        copy.splice(start, deleteCount, ...items)
      }
      return copy
    },
    writable: true,
    enumerable: false,
    configurable: true,
  })
}

if (typeof Array.prototype.with !== 'function') {
  Object.defineProperty(Array.prototype, 'with', {
    value: function withAt<T>(this: T[], index: number, value: T): T[] {
      const copy = [...this]
      const len = copy.length
      const rel = Math.trunc(Number(index) || 0)
      const actual = rel < 0 ? len + rel : rel
      if (actual < 0 || actual >= len) {
        throw new RangeError('Invalid index')
      }
      copy[actual] = value
      return copy
    },
    writable: true,
    enumerable: false,
    configurable: true,
  })
}

if (typeof Array.prototype.findLast !== 'function') {
  Object.defineProperty(Array.prototype, 'findLast', {
    value: function findLast<T>(
      this: T[],
      predicate: (value: T, index: number, obj: T[]) => boolean,
      thisArg?: unknown
    ): T | undefined {
      for (let i = this.length - 1; i >= 0; i--) {
        if (predicate.call(thisArg, this[i], i, this)) {
          return this[i]
        }
      }
      return undefined
    },
    writable: true,
    enumerable: false,
    configurable: true,
  })
}

if (typeof Array.prototype.findLastIndex !== 'function') {
  Object.defineProperty(Array.prototype, 'findLastIndex', {
    value: function findLastIndex<T>(
      this: T[],
      predicate: (value: T, index: number, obj: T[]) => boolean,
      thisArg?: unknown
    ): number {
      for (let i = this.length - 1; i >= 0; i--) {
        if (predicate.call(thisArg, this[i], i, this)) {
          return i
        }
      }
      return -1
    },
    writable: true,
    enumerable: false,
    configurable: true,
  })
}

if (typeof String.prototype.at !== 'function') {
  Object.defineProperty(String.prototype, 'at', {
    value: function at(this: string, index: number): string | undefined {
      const str = String(this)
      const len = str.length
      const rel = Math.trunc(Number(index) || 0)
      const k = rel >= 0 ? rel : len + rel
      if (k < 0 || k >= len) {
        return undefined
      }
      return str.charAt(k)
    },
    writable: true,
    enumerable: false,
    configurable: true,
  })
}

if (typeof String.prototype.replaceAll !== 'function') {
  Object.defineProperty(String.prototype, 'replaceAll', {
    value: function replaceAll(
      this: string,
      searchValue: string | RegExp,
      replaceValue: string | ((substring: string, ...args: unknown[]) => string)
    ): string {
      const str = String(this)
      if (searchValue instanceof RegExp) {
        if (!searchValue.global) {
          throw new TypeError('String.prototype.replaceAll called with a non-global RegExp')
        }
        return str.replace(searchValue, replaceValue as string)
      }
      const search = String(searchValue)
      if (search === '') {
        if (typeof replaceValue === 'function') {
          let out = replaceValue('', 0, str)
          for (let i = 0; i < str.length; i++) {
            out += str.charAt(i) + replaceValue('', i + 1, str)
          }
          return out
        }
        const rep = String(replaceValue)
        return rep + str.split('').join(rep) + rep
      }
      if (typeof replaceValue === 'function') {
        let result = ''
        let pos = 0
        for (;;) {
          const idx = str.indexOf(search, pos)
          if (idx === -1) {
            result += str.slice(pos)
            break
          }
          result += str.slice(pos, idx) + replaceValue(search, idx, str)
          pos = idx + search.length
        }
        return result
      }
      return str.split(search).join(String(replaceValue))
    },
    writable: true,
    enumerable: false,
    configurable: true,
  })
}

if (typeof crypto !== 'undefined' && typeof crypto.randomUUID !== 'function') {
  Object.defineProperty(crypto, 'randomUUID', {
    value: (): `${string}-${string}-${string}-${string}-${string}` => {
      const bytes = crypto.getRandomValues(new Uint8Array(16))
      bytes[6] = (bytes[6] & 0x0f) | 0x40
      bytes[8] = (bytes[8] & 0x3f) | 0x80
      const hex = Array.from(bytes, (b) => b.toString(16).padStart(2, '0')).join('')
      return `${hex.slice(0, 8)}-${hex.slice(8, 12)}-${hex.slice(12, 16)}-${hex.slice(16, 20)}-${hex.slice(20)}`
    },
    writable: true,
    enumerable: false,
    configurable: true,
  })
}

const g = (typeof globalThis !== 'undefined'
  ? globalThis
  : typeof window !== 'undefined'
    ? window
    : typeof self !== 'undefined'
      ? self
      : {}) as Record<string, unknown>

if (typeof g.globalThis === 'undefined') {
  g.globalThis = g
}

if (typeof Symbol !== 'undefined' && !(Symbol as unknown as Record<string, unknown>).asyncIterator) {
  Object.defineProperty(Symbol, 'asyncIterator', {
    value: Symbol('Symbol.asyncIterator'),
    configurable: true,
  })
}

if (typeof g.queueMicrotask !== 'function') {
  g.queueMicrotask = (cb: () => void) => {
    Promise.resolve().then(cb)
  }
}

if (typeof Object.fromEntries !== 'function') {
  Object.defineProperty(Object, 'fromEntries', {
    value: function fromEntries(iterable: Iterable<readonly [PropertyKey, unknown]>) {
      const obj: Record<PropertyKey, unknown> = {}
      for (const entry of iterable) {
        if (entry != null) {
          obj[entry[0]] = entry[1]
        }
      }
      return obj
    },
    writable: true,
    enumerable: false,
    configurable: true,
  })
}

if (typeof Array.prototype.flat !== 'function') {
  Object.defineProperty(Array.prototype, 'flat', {
    value: function flat<T>(this: T[], depth = 1): unknown[] {
      const flatten = (arr: unknown[], d: number): unknown[] => {
        const out: unknown[] = []
        for (let i = 0; i < arr.length; i++) {
          if (!(i in arr)) {
            continue
          }
          const item = arr[i]
          if (d > 0 && Array.isArray(item)) {
            out.push(...flatten(item, d - 1))
          } else {
            out.push(item)
          }
        }
        return out
      }
      return flatten(this, Number(depth))
    },
    writable: true,
    enumerable: false,
    configurable: true,
  })
}

if (typeof Array.prototype.flatMap !== 'function') {
  Object.defineProperty(Array.prototype, 'flatMap', {
    value: function flatMap<T, U>(
      this: T[],
      callback: (value: T, index: number, array: T[]) => U | readonly U[],
      thisArg?: unknown
    ): U[] {
      const out: U[] = []
      for (let i = 0; i < this.length; i++) {
        if (!(i in this)) {
          continue
        }
        const mapped = callback.call(thisArg, this[i], i, this)
        if (Array.isArray(mapped)) {
          out.push(...mapped)
        } else {
          out.push(mapped as U)
        }
      }
      return out
    },
    writable: true,
    enumerable: false,
    configurable: true,
  })
}

if (typeof Promise.prototype.finally !== 'function') {
  Object.defineProperty(Promise.prototype, 'finally', {
    value: function finallyPolyfill<T>(this: Promise<T>, onFinally?: (() => unknown) | null) {
      const handler = typeof onFinally === 'function' ? onFinally : () => {}
      return this.then(
        (value) => Promise.resolve(handler()).then(() => value),
        (reason) =>
          Promise.resolve(handler()).then(() => {
            throw reason
          })
      )
    },
    writable: true,
    enumerable: false,
    configurable: true,
  })
}

if (typeof Promise.allSettled !== 'function') {
  Promise.allSettled = function allSettled<T>(
    iterable: Iterable<T | PromiseLike<T>>
  ): Promise<PromiseSettledResult<Awaited<T>>[]> {
    return Promise.all(
      Array.from(iterable, (item) =>
        Promise.resolve(item).then(
          (value) => ({ status: 'fulfilled' as const, value: value as Awaited<T> }),
          (reason) => ({ status: 'rejected' as const, reason })
        )
      )
    )
  } as typeof Promise.allSettled
}

if (typeof String.prototype.trimStart !== 'function') {
  Object.defineProperty(String.prototype, 'trimStart', {
    value: function trimStart(this: string) {
      return String(this).replace(/^\s+/, '')
    },
    writable: true,
    enumerable: false,
    configurable: true,
  })
}

if (typeof String.prototype.trimEnd !== 'function') {
  Object.defineProperty(String.prototype, 'trimEnd', {
    value: function trimEnd(this: string) {
      return String(this).replace(/\s+$/, '')
    },
    writable: true,
    enumerable: false,
    configurable: true,
  })
}

if (typeof Intl !== 'undefined' && typeof (Intl as unknown as Record<string, unknown>).DisplayNames !== 'function') {
  class FallbackDisplayNames {
    of(code: string): string {
      return String(code)
    }
  }
  ;(Intl as unknown as Record<string, unknown>).DisplayNames = FallbackDisplayNames
}

if (typeof g.AbortController !== 'function') {
  class FallbackAbortSignal {
    aborted = false
    reason: unknown = undefined
    onabort: ((ev: Event) => void) | null = null
    private listeners = new Set<EventListenerOrEventListenerObject>()

    addEventListener(type: string, listener: EventListenerOrEventListenerObject | null) {
      if (type === 'abort' && listener) {
        this.listeners.add(listener)
      }
    }

    removeEventListener(type: string, listener: EventListenerOrEventListenerObject | null) {
      if (type === 'abort' && listener) {
        this.listeners.delete(listener)
      }
    }

    dispatchEvent(event: Event): boolean {
      if (this.onabort) {
        try {
          this.onabort(event)
        } catch {
          // 忽略单个监听异常
        }
      }
      for (const listener of Array.from(this.listeners)) {
        try {
          if (typeof listener === 'function') {
            listener(event)
          } else if (typeof listener.handleEvent === 'function') {
            listener.handleEvent(event)
          }
        } catch {
          // 忽略单个监听异常
        }
      }
      return true
    }

    throwIfAborted() {
      if (this.aborted) {
        throw this.reason ?? new Error('Aborted')
      }
    }
  }

  class FallbackAbortController {
    signal = new FallbackAbortSignal()
    abort(reason?: unknown) {
      if (this.signal.aborted) {
        return
      }
      this.signal.aborted = true
      this.signal.reason = reason ?? new Error('Aborted')
      const ev = typeof Event === 'function' ? new Event('abort') : ({ type: 'abort' } as Event)
      this.signal.dispatchEvent(ev)
    }
  }

  g.AbortSignal = FallbackAbortSignal
  g.AbortController = FallbackAbortController
}

if (typeof g.ResizeObserver !== 'function') {
  class FallbackResizeObserver {
    private cb: ResizeObserverCallback
    private targets = new Set<Element>()
    private timer: ReturnType<typeof setTimeout> | null = null
    private onResize = () => {
      if (this.timer) {
        clearTimeout(this.timer)
      }
      this.timer = setTimeout(() => this.notify(), 50)
    }

    constructor(cb: ResizeObserverCallback) {
      this.cb = cb
    }

    private notify() {
      if (this.targets.size === 0) {
        return
      }
      const entries = Array.from(this.targets).map((target) => {
        const rect = target.getBoundingClientRect()
        return {
          target,
          contentRect: rect,
          borderBoxSize: [{ inlineSize: rect.width, blockSize: rect.height }],
          contentBoxSize: [{ inlineSize: rect.width, blockSize: rect.height }],
          devicePixelContentBoxSize: [{ inlineSize: rect.width, blockSize: rect.height }],
        } as unknown as ResizeObserverEntry
      })
      try {
        this.cb(entries, this as unknown as ResizeObserver)
      } catch {
        // 忽略回调异常
      }
    }

    observe(target: Element) {
      if (this.targets.size === 0 && typeof window !== 'undefined') {
        window.addEventListener('resize', this.onResize)
      }
      this.targets.add(target)
      this.onResize()
    }

    unobserve(target: Element) {
      this.targets.delete(target)
      if (this.targets.size === 0 && typeof window !== 'undefined') {
        window.removeEventListener('resize', this.onResize)
      }
    }

    disconnect() {
      this.targets.clear()
      if (this.timer) {
        clearTimeout(this.timer)
      }
      if (typeof window !== 'undefined') {
        window.removeEventListener('resize', this.onResize)
      }
    }
  }

  g.ResizeObserver = FallbackResizeObserver
}

export {}
