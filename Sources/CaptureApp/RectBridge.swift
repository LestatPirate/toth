// Copyright © 2026 Alex Felizardo.
// Licença MIT: ver LICENSE. MIT License: see LICENSE.

import CoreGraphics
import CaptureCore

extension Rect {
    var cg: CGRect { CGRect(x: x, y: y, width: width, height: height) }
}
