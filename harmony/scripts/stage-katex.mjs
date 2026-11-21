import { copyFile, readFile, writeFile } from 'node:fs/promises'

// The Android v0.1.31 lockfile pins KaTeX, including its mhchem extension.
const source = new URL('../../chat-demo/node_modules/katex/', import.meta.url)
const destination = new URL('../entry/src/main/resources/rawfile/math/', import.meta.url)
const manifest = JSON.parse(await readFile(new URL('package.json', source), 'utf8'))
if (manifest.version !== '0.16.22') {
  throw new Error('Harmony math requires the Android v0.1.31 KaTeX version 0.16.22')
}

const css = await readFile(new URL('dist/katex.min.css', source), 'utf8')
const fonts = Array.from(css.matchAll(/url\((fonts\/[A-Za-z0-9_-]+\.woff2)\) format\("woff2"\)(?:,url\([^)]*\) format\("[^"]*"\))*/g))
if (fonts.length === 0) throw new Error('KaTeX font URLs were not recognized')
let embedded = css
for (const [match, name] of fonts) {
  const font = await readFile(new URL('dist/' + name, source))
  embedded = embedded.replace(match, 'url(data:font/woff2;base64,' + font.toString('base64') + ') format("woff2")')
}
if (embedded.includes('url(fonts/')) throw new Error('KaTeX stylesheet still has external font references')

await Promise.all([
  copyFile(new URL('dist/katex.min.js', source), new URL('katex.min.js', destination)),
  copyFile(new URL('dist/contrib/mhchem.min.js', source), new URL('mhchem.min.js', destination)),
  copyFile(new URL('LICENSE', source), new URL('KATEX-LICENSE.txt', destination)),
  writeFile(new URL('fonts.js', destination), 'window.NuwaKaTeXStyles = ' + JSON.stringify(embedded) + ';\n'),
])
console.log('Staged KaTeX ' + manifest.version + ', mhchem, ' + fonts.length + ' embedded fonts, and the MIT license')
