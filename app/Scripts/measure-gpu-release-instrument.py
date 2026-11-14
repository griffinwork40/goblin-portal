#!/usr/bin/env python3
"""Disposable vendor census, NOT a shipping patch. Exact anchors fail closed.
Adds read-only introspection under the owner's render-state lock after GPU idle.
No allocation policy changes; keep a diff beside each measurement's raw output.
"""
from pathlib import Path
root = Path(__file__).resolve().parents[2] / 'vendor/SwiftTerm/Sources/SwiftTerm'

def insert(path, anchor, addition):
    p = root / path
    text = p.read_text()
    if addition.strip() in text:
        return
    if text.count(anchor) != 1:
        raise SystemExit(f'census anchor mismatch: {p}')
    p.write_text(text.replace(anchor, addition + anchor))

insert('Apple/TerminalRenderOwner.swift', '    var completedMetalRenders: Int {', '''    // Measurement-only: detached, idle renderer; never a production API.
    func measurementMetalResources() -> [String: Int] {
        withRenderState { $0.renderer?.measurementResources() ?? [:] }
    }

''')
insert('Apple/Metal/GlyphAtlas.swift', '    func ensureRegion(width: Int, height: Int) -> AtlasRegion? {', '''    var measurementShadowBytes: Int { data.count }

''')
insert('Apple/Metal/MetalTerminalRenderer.swift', '    private let renderSurface: (any MetalRenderSurface)?', '''    // Measurement-only ownership census. allocatedSize is Metal accounting,
    // not residency; CPU shadow counts are payload, not malloc zone sizes.
    func measurementResources() -> [String: Int] {
        var result = [
            "grayTexture": grayscaleAtlas.texture.allocatedSize,
            "colorTexture": colorAtlas.texture.allocatedSize,
            "grayShadow": grayscaleAtlas.measurementShadowBytes,
            "colorShadow": colorAtlas.measurementShadowBytes,
            "pipelines": 6,
            "rendererID": Int(bitPattern: ObjectIdentifier(self))
        ]
        var seen = Set<ObjectIdentifier>()
        func collect(_ buffers: [MTLBuffer], _ label: String) {
            let unique = buffers.filter { seen.insert(ObjectIdentifier($0)).inserted }
            result[label + "Allocated"] = unique.reduce(0) { $0 + $1.allocatedSize }
            result[label + "Length"] = unique.reduce(0) { $0 + $1.length }
            result[label + "Count"] = unique.count
        }
        var rows: [MTLBuffer] = []
        for entry in rowCache.values {
            guard let b = entry.buffers else { continue }
            rows += [b.backgroundBuffer, b.powerlineJoinBuffer, b.glyphGrayBuffer,
                     b.glyphColorBuffer, b.decorationBuffer].compactMap { $0 }
            for list in [b.belowBackgroundImageBuffers, b.underImageBuffers,
                         b.placeholderImageBuffers, b.overImageBuffers, b.otherImageBuffers] {
                rows += list.map { $0.buffer }
            }
        }
        collect(rows, "rowBuffers")
        collect(bufferPool.measurementBuffers, "poolBuffers")
        result["imageTextures"] = imageTextureCache.objectEnumerator()?.allObjects
            .compactMap { $0 as? MTLTexture }.reduce(0) { $0 + $1.allocatedSize } ?? 0
        result["kittyTextures"] = kittyTextureCache.values.reduce(0) { $0 + $1.texture.allocatedSize }
        return result
    }

''')
insert('Apple/Metal/MetalTerminalRenderer.swift', '        var pendingBatchCount: Int {', '''        var measurementBuffers: [MTLBuffer] {
            state.withLock { Array($0.available.values).flatMap { $0 }
                + Array($0.pending.values).flatMap { $0 } }
        }

''')
insert('Apple/Metal/MetalTerminalRenderer.swift', '        private let alignment = 256', '''        var measurementBuffers: [MTLBuffer] { frameBuffers + recycler.measurementBuffers }
''')
insert('Apple/Metal/TerminalMetalLayerView.swift', '    private let publishedGeometry: Locked<MetalSurfaceGeometry>', '''    // Weak observation cannot pin a drawable or change the pool's lifetime.
    private final class MeasurementTexture {
        weak var value: (any MTLTexture)?
        init(_ value: any MTLTexture) { self.value = value }
    }
    private let measurementTextures = Locked([ObjectIdentifier: MeasurementTexture]())
    func measurementDrawableResources() -> [String: Int] {
        measurementTextures.withLock { values in
            let live = values.values.compactMap { $0.value }
            return ["observedLiveTextures": live.count,
                    "observedLiveAllocated": live.reduce(0) { $0 + $1.allocatedSize },
                    "observedLiveLogical": live.reduce(0) { $0 + $1.width * $1.height * 4 }]
        }
    }

''')
insert('Apple/Metal/TerminalMetalLayerView.swift', '        let descriptor = MTLRenderPassDescriptor()', '''        measurementTextures.withLock {
            $0[ObjectIdentifier(drawable.texture)] = MeasurementTexture(drawable.texture)
        }
''')
insert('Apple/Metal/TerminalMetalLayerView.swift', '    override init(frame frameRect: CGRect) {', '''    func measurementDrawableResources() -> [String: Int] {
        renderSurfaceStorage.measurementDrawableResources()
    }

''')
print('Installed measurement-only vendor census (no release policy changes).')
