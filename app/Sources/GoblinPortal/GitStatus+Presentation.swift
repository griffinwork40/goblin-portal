//
//  GitStatus+Presentation.swift
//  How a `GitFileStatus` *looks* in the sidebar: one colour.
//
//  Narrowed 2026-08-02. The wording used to live here too, but `accessibilityDescription`
//  and `GitFileEntry.statusPhrase`/`.tooltip` touch no AppKit type at all, and keeping
//  them behind this file's `import AppKit` put deterministic string logic outside the
//  reach of `check-git-status.sh` — the repo's only mechanical gate, which compiles
//  Foundation-only files standalone. They now live in `GitStatus+Phrasing.swift`, where
//  the gate can pin them. What is left here is the one thing that genuinely needs AppKit.
//
//  Its own file, rather than riding along in `FileTreeViewController+OutlineView.swift`,
//  because it extends a DIFFERENT type — exactly the argument
//  `DocumentStatus+Presentation.swift` makes for itself. `GitFileStatus` is declared in
//  `GitStatus.swift` and belongs to the parser, which must stay `Foundation`-only so
//  `check-git-status.sh` can compile it alone; the moment an `NSColor` appeared in that
//  file the gate would stop working. So the dependency runs one way only: the tree
//  renders the status enum, the status enum knows nothing about AppKit.
//
//  This is also the file that would grow if a second surface ever wants to show git
//  state — a tab-strip badge, a Space-level indicator — instead of that surface reaching
//  into the outline view's drawing code.
//

import AppKit

extension GitFileStatus {
    /// The row's tint, and the badge's.
    ///
    /// System colours, not hex literals, for the same three reasons the tab strip's dot
    /// uses them (`DocumentStatus.dotColour`): they adapt to Increase Contrast, they
    /// follow the window's effective appearance, and they keep this app's chrome derived
    /// rather than hardcoded. VS Code's own `gitDecoration.*` defaults were deliberately
    /// **not** copied — the hex values circulating for them are unverified third-party
    /// transcriptions, and pasting six magic numbers to imitate another app's dark theme
    /// would look wrong in light mode and wrong again under Increase Contrast.
    ///
    /// The ANSI palette was also considered and refused. At `theme == nil` — the default
    /// — no palette is installed at all, so there would be nothing to read; and once a
    /// theme *is* set, its "green" is whatever hex that preset names, which on a light
    /// preset is a dark green picked to sit on white. Sidebar chrome is not terminal
    /// content and should not borrow its colours.
    ///
    /// The semantic mapping follows VS Code's *tokens* (which are stable and documented)
    /// rather than its pixels: modified is warm, new-content is green, gone-or-broken is
    /// red, ignored recedes.
    var decorationColour: NSColor {
        switch self {
        case .modified, .typeChanged:
            // Warm rather than green: a modified file is the one state that is neither
            // good news nor bad, and orange is the platform's "in progress" weight.
            // Type-changed shares it because a mode/symlink flip *is* a modification —
            // it earns its own letter (T) but not its own colour.
            return .systemOrange
        case .added, .renamed, .copied, .untracked:
            // All four are "content that is new here", which is what VS Code's green
            // family means. Untracked shares it deliberately: to a reader scanning the
            // tree, "new file" and "new staged file" are the same category, and the
            // letters (U vs A) carry the distinction for anyone who needs it.
            return .systemGreen
        case .deleted:
            return .systemRed
        case .conflicted:
            // Distinct from `.deleted`'s red on purpose. A conflict is the one state
            // where continuing to work without noticing destroys information, so it must
            // not be confusable with the merely-removed — and `.systemPink` is the
            // platform colour closest to the pink-red VS Code reserves for it.
            return .systemPink
        case .ignored:
            // A label colour, not a grey literal: ignored rows should recede to whatever
            // "de-emphasised text" means in the current appearance, which is precisely
            // what the tertiary label role is defined as.
            return .tertiaryLabelColor
        }
    }
}
