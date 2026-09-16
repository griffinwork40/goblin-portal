# Third-party licenses

Goblin Portal itself is MIT — see [`LICENSE`](LICENSE). This file covers everything Goblin Portal
**redistributes**: the code compiled into the shipping binary, and the colour palettes
transcribed into its source.

Everything here is MIT. There is no copyleft anywhere in the graph, and the one
Apache-2.0 package SwiftPM resolves is not linked — see "Resolved but not shipped" below,
which shows the work rather than asserting the conclusion.

---

## Compiled into the Goblin Portal binary

| Component | Version | License | Copyright |
|---|---|---|---|
| [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm) | v1.15.0 + 6 local patches | MIT | Miguel de Icaza; the xterm.js authors; SourceLair; Christopher Jeffrey |

### SwiftTerm

Vendored at `vendor/SwiftTerm` (gitignored; materialise it with
`app/Scripts/bootstrap-vendor.sh`). Goblin Portal applies **six local patches** from
`patches/swiftterm/`, which are modifications to the original work: three fix upstream
defects (scrollback corruption on narrowing, an alt-buffer resize bleed, and an ungated
release-build `abort()`), one repackages the Metal shader as a copy resource, one adds
DCS Ptmux passthrough, and one gates linefeed's selection-clear on mouse mode. The patches
are themselves MIT under this notice, and each carries its rationale in `SwiftTerm.pin`.

```
Copyright (c) 2019-2022 Miguel de Icaza (https://github.com/migueldeicaza)
Copyright (c) 2017-2019, The xterm.js authors (https://github.com/xtermjs/xterm.js)
Copyright (c) 2014-2016, SourceLair Private Company (https://www.sourcelair.com)
Copyright (c) 2012-2013, Christopher Jeffrey (https://github.com/chjj/)

Permission is hereby granted, free of charge, to any person obtaining
a copy of this software and associated documentation files (the
"Software"), to deal in the Software without restriction, including
without limitation the rights to use, copy, modify, merge, publish,
distribute, sublicense, and/or sell copies of the Software, and to
permit persons to whom the Software is furnished to do so, subject to
the following conditions:

The above copyright notice and this permission notice shall be
included in all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND,
EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF
MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND
NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE
LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION
OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION
WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
```

---

## Resolved but not shipped

One package appears in dependency metadata without reaching the binary. It is listed
here so that a reader who finds it in a checkout directory can see it was considered
rather than missed.

**[swift-argument-parser](https://github.com/apple/swift-argument-parser) 1.8.2 —
Apache-2.0 with the Swift Runtime Library Exception.** This is the only non-MIT package
SwiftPM resolves, so it is the one worth being sure about. It is pulled in by the
*vendored SwiftTerm's* own `Package.swift`, where its only consumer is `Termcast`, an
example CLI target inside that package. Goblin Portal's executable target depends on
exactly `SwiftTerm` (`app/Package.swift`), and the `SwiftTerm` **library** target declares
no dependencies of its own.

Verified against the built product rather than inferred from the manifest:

```
$ nm -a app/build/GoblinPortal.app/Contents/MacOS/GoblinPortal | grep -ci ArgumentParser
0
$ nm -a app/build/GoblinPortal.app/Contents/MacOS/GoblinPortal | grep -ci SwiftTerm
24249
```

The second number is the control: it is what makes the first one mean "absent" rather than
"the grep is broken". No `NOTICE` file exists in the package, so Apache-2.0 §4(d) — whose
trigger is conditional on one existing — never fires either way.

---

## Colour palettes

Not code, but transcribed values, and three of the five came from somewhere. The source
comments in `app/Sources/GoblinPortal/ThemeValues.swift` describe each palette's provenance; this
is where the licences for that provenance live.

| Preset | Origin | License |
|---|---|---|
| `umber` | Designed for this app — derived and measured in `.afk/research/theme-design-2026-08-03/`. No external source. | — (this project) |
| `afk-light` | A verbatim port of **GitHub's Light Default**, whose colour primitives are published in [primer/primitives](https://github.com/primer/primitives). | MIT |
| `afk-dark` | A 1:1 port of the `terminal` block of `afk-dark.terax-theme` in the [agent-afk](https://github.com/griffinwork40/agent-afk) repo — a GitHub-Dark skeleton with that project's warm-orange accent. | MIT |
| `tokyo-night` | Transcribed verbatim from [enkia/tokyo-night-vscode-theme](https://github.com/enkia/tokyo-night-vscode-theme). | MIT |
| `classic-repaired` | macOS Terminal.app "Basic" as SwiftTerm encodes it (`Color.terminalAppColors`), with two measured defects repaired. | MIT (SwiftTerm, above) |

`classic` installs no palette at all, so it attributes nothing.

---

## Re-deriving this list

```sh
cat vendor/SwiftTerm/LICENSE                          # after ./app/Scripts/bootstrap-vendor.sh
cat app/.build/checkouts/*/LICENSE*                   # after swift build
nm -a app/build/GoblinPortal.app/Contents/MacOS/GoblinPortal | grep -ci <symbol>
```

If a dependency is added, removed, or bumped, update this file in the same commit — a
notices file that lags the manifest is worse than none, because it reads as verified.
