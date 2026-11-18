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

export {}
