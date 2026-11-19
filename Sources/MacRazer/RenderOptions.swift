// SPDX-License-Identifier: GPL-2.0-or-later
// Part of MacRazer, a control app for Razer mice on macOS. See LICENSE and NOTICE.md.

import CoreGraphics

/// Set by the `render-*` commands (main.swift) before they draw anything.
///
/// Statics rather than top-level `var`s in main.swift: that file runs top to bottom, so a
/// top-level one would be set to nil again when execution reached its declaration.
enum RenderOptions {
    /// This process is drawing a screenshot from preview data. Anything that would read this
    /// Mac's real state (permissions, login item, running apps) or open a real mouse checks it
    /// and keeps the preview instead. Hosted renders run in a window, so `onAppear` and its
    /// refreshes run just as they do in the app.
    nonisolated(unsafe) static var isActive = false

    /// From a `render-*` command's `crop=x,y,width,height` argument, in points from the top
    /// left: only that part of a hosted render is written. For the website's feature cards.
    nonisolated(unsafe) static var crop: CGRect?
}
