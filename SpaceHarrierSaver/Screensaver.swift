//
//  Screensaver.swift
//  SpaceHarrierSaver
//
//  Created by TY on 03-09-2025.
//

import ScreenSaver
import AppKit
import QuartzCore

final class SpaceHarrierSaverView: ScreenSaverView {
    private var cameraZ: CGFloat = 0
    private var worldZ: CGFloat = 0 // unwrapped forward distance for sprites
    private let tileSize: CGFloat = 0.60
    private let speed: CGFloat = 0.065
    private let zBias: CGFloat = -4 // shift plane along Z axis (negative = closer)

    private let objectSpeedMult: CGFloat = 1.15 // objects advance faster than ground
    private var nextIsBush: Bool = true         // alternate spawn kind
    private let harrierZ: CGFloat = 1.25        // just in front of camera
    private let harrierBasePx: CGFloat = 120    // base pixel height
    private let harrierMaxHFrac: CGFloat = 0.26 // max ~26% of screen height
    private let harrierBobAmpFrac: CGFloat = 0.020
    private let harrierBobSpeed: CGFloat = 2.2

    // Harrier autonomous movement (screen-space normalized X)
    private var harrierNormX: CGFloat = 0.0            // -1..1-ish, but we clamp tighter via max
    private var harrierTargetNormX: CGFloat = 0.0
    private var harrierVX: CGFloat = 0.0
    private var harrierStateFrames: Int = 0
    private var harrierIsWaiting: Bool = true
    private let harrierMaxNormX: CGFloat = 0.82        // keep inside screen margins
    private let harrierMaxSpeed: CGFloat = 0.025       // per-frame normalized speed
    private let harrierAccel: CGFloat = 0.0022
    private let harrierStopEps: CGFloat = 0.008
    private let harrierWaitFramesMin = 30
    private let harrierWaitFramesMax = 90
    private let harrierMoveFramesMin = 45
    private let harrierMoveFramesMax = 120

    // Vertical movement state (up/down)
    private var harrierNormY: CGFloat = 0.0
    private var harrierTargetNormY: CGFloat = 0.0
    private var harrierVY: CGFloat = 0.0
    private let harrierMaxNormY: CGFloat = 0.35       // keep vertical move within margins
    private let harrierMaxSpeedY: CGFloat = 0.018
    private let harrierAccelY: CGFloat = 0.0016
    private let harrierStopEpsY: CGFloat = 0.008
    
    private let skyTop = NSColor(calibratedRed: 0.24, green: 1.00, blue: 0.72, alpha: 1.0)   // sky blue
    
    private let skyBottom = NSColor(calibratedRed: 0.79, green: 0.32, blue: 0.98, alpha: 1.0) // near horizon
    private let horizonGlow = NSColor(calibratedRed: 1.00, green: 1.00, blue: 1.00, alpha: 0.25)
    
    private lazy var skyGradient: NSGradient? = NSGradient(starting: skyTop, ending: skyBottom)
    private lazy var glowGradient: NSGradient? = NSGradient(starting: horizonGlow, ending: .clear)

    private enum SpriteKind { case bush, column, shot }
    private struct Sprite { var kind: SpriteKind; var x: CGFloat; var z: CGFloat; var size: CGFloat; var y: CGFloat; var age: Int }

    private var sprites: [Sprite] = []
    private var imgBush: NSImage? = NSImage(named: "bush") // optional, falls back to vector
    private var imgColumn: NSImage? = NSImage(named: "column")
    private var imgHarrier: NSImage? = NSImage(named: "harrier")
    private var imgParticle: NSImage? = NSImage(named: "particle")
    private lazy var ciContext = CIContext(options: nil)
    private var ciParticle: CIImage?
    private var cachedHueParticle: CGImage? = nil
    private var cachedHueParity: Int = -1
    private lazy var hueFilter = CIFilter(name: "CIHueAdjust")
    private var lastTick: CFTimeInterval = CACurrentMediaTime()
    private var smoothedDt: CGFloat = 1.0 / 60.0
    private let dtSmoothAlpha: CGFloat = 0.22 // EMA smoothing (lower = smoother)

    private var triedLoadImages = false

    private func ensureImagesLoaded() {
        guard !triedLoadImages else { return }
        triedLoadImages = true
        let bundle = Bundle(for: type(of: self))

        if imgBush == nil {
            if let url = bundle.url(forResource: "bush", withExtension: "png") {
                imgBush = NSImage(contentsOf: url)
            }
            if imgBush == nil { imgBush = NSImage(named: "bush") }
        }

        if imgColumn == nil {
            if let url = bundle.url(forResource: "column", withExtension: "png") {
                imgColumn = NSImage(contentsOf: url)
            }
            if imgColumn == nil { imgColumn = NSImage(named: "column") }
        }
        if imgHarrier == nil {
            if let url = Bundle(for: type(of: self)).url(forResource: "harrier", withExtension: "png") {
                imgHarrier = NSImage(contentsOf: url)
            }
            if imgHarrier == nil { imgHarrier = NSImage(named: "harrier") }
        }
        if imgParticle == nil {
            if let url = bundle.url(forResource: "particle", withExtension: "png") {
                imgParticle = NSImage(contentsOf: url)
            }
            if imgParticle == nil { imgParticle = NSImage(named: "particle") }
        }
        if ciParticle == nil, let tiff = imgParticle?.tiffRepresentation { ciParticle = CIImage(data: tiff) }
    }

    // Spawn tuning
    private let maxSprites = 6            // legacy (not used for obstacles anymore)
    private let maxObstacles = 5          // bushes + columns budget (excludes shots)
    private let spawnDistance: CGFloat = 68 // farther so they start tiny; higher speed brings them in fast
    private let laneWidth: CGFloat = 2.0 // wider lanes for more horizontal spread

    private let lanesIdx: [Int] = [-6,-5,-4,-3,-2,-1,0,1,2,3,4,5,6]
    private var laneNextAllowedZ: [Int: CGFloat] = [:]
    private var lastRowZ: CGFloat = .leastNonzeroMagnitude
    private let rowSpacing: CGFloat = 3.2   // slightly sparser obstacle rows
    private let laneMinSpacing: CGFloat = 7.0 // larger per‑lane Z gap
    private let emptyRowChance: UInt32 = 25 // % chance to skip a row for occasional gaps

    // Shots (turbo fire)
    private let maxShots = 12
    private var shotFrameCounter = 0
    private var shotCooldown = 0
    private let shotRelNetSpeed: CGFloat = 0.030 // net relative-Z gain per frame → guaranteed zoom-out
    private let shotCooldownFrames = 25 // keep user’s cadence
    private let shotRelMin: CGFloat = 0.55  // spawn close to Harrier but visible
    private let shotRelMax: CGFloat = 1.60  // finish sooner so zoom-out reads clearly
    private let shotDriftStart: CGFloat = 0.00   // start drifting to center immediately
    private let shotDriftEnd:   CGFloat = 0.90   // reach center before end of life
    private let shotFollowLerp: CGFloat = 0.56  // track Harrier tightly

    // Hue cache optimization
    private let hueFrames: Int = 6 // update hue every 6 frames

    override init?(frame: NSRect, isPreview: Bool) {
        super.init(frame: frame, isPreview: isPreview)
        self.animationTimeInterval = 1.0 / 60.0
    }

    required init?(coder: NSCoder) { super.init(coder: coder) }

    override func draw(_ rect: NSRect) {
        // Background will be drawn by drawCheckerboardPerspective (sky + ground)

        // Space Harrier–ish ground: scrolling checker “towards” you
        if let ctx = NSGraphicsContext.current {
            let prev = ctx.shouldAntialias
            ctx.shouldAntialias = false
            drawCheckerboardPerspective(in: rect)
            let horizonY = rect.height * 0.65
            let focal: CGFloat = rect.height * 0.95
            self.ensureImagesLoaded()
            self.drawSprites(in: rect, horizonY: horizonY, focal: focal) // obstacles only (shots skipped inside)
            self.drawShots(in: rect, horizonY: horizonY, focal: focal)
            self.drawHarrier(in: rect, horizonY: horizonY, focal: focal)
            ctx.shouldAntialias = prev
        } else {
            drawCheckerboardPerspective(in: rect)
            let horizonY = rect.height * 0.65
            let focal: CGFloat = rect.height * 0.95
            self.ensureImagesLoaded()
            self.drawSprites(in: rect, horizonY: horizonY, focal: focal) // obstacles only (shots skipped inside)
            self.drawShots(in: rect, horizonY: horizonY, focal: focal)
            self.drawHarrier(in: rect, horizonY: horizonY, focal: focal)
        }
        
        // (Later) draw sprites/enemies here…
    }

    override func animateOneFrame() {
        // --- Smooth delta-time ---
        let now = CACurrentMediaTime()
        var dt = now - lastTick
        lastTick = now
        // clamp unreasonable spikes
        if dt < (1.0/240.0) { dt = 1.0/240.0 }
        if dt > (1.0/20.0)  { dt = 1.0/20.0 }
        // exponential moving average for stability
        smoothedDt += (CGFloat(dt) - smoothedDt) * dtSmoothAlpha
        let fscale = smoothedDt * 60.0 // normalize to 60fps units
        // --- end Smooth delta-time ---
        cameraZ += speed * fscale
        worldZ += speed * objectSpeedMult * fscale
        if cameraZ >= tileSize { cameraZ -= tileSize }

        // Recycle sprites that passed the camera
        let despawnZ: CGFloat = 0.45
        sprites.removeAll { spr in
            let relZ: CGFloat = spr.z - worldZ + (spr.kind == .shot ? 0 : zBias)
            return relZ < despawnZ || (spr.kind == .shot && (relZ > spawnDistance * 0.95 || spr.age > 300))
        }

        // Initialize row marker once
        if lastRowZ == .leastNonzeroMagnitude { lastRowZ = worldZ }

        // Count only obstacles for row spawning
        let obstacleCount = sprites.reduce(into: 0) { acc, s in if s.kind != .shot { acc += 1 } }
        // Spawn rows at fixed Z intervals (Space Harrier style)
        var currentObstacles = obstacleCount
        while (worldZ - lastRowZ) >= rowSpacing && currentObstacles < maxObstacles {
            if arc4random_uniform(100) >= emptyRowChance { // most rows spawn
                let spawned = spawnRow()
                currentObstacles += spawned
            }
            lastRowZ += rowSpacing
        }

        // --- Shots spawn & advance ---
        shotFrameCounter += 1
        if shotCooldown > 0 { shotCooldown -= 1 }

        // Harrier screen X/Y for anchoring
        let rect = self.bounds
        let centerX = rect.midX
        let centerY = rect.midY
        let focal = rect.height * 0.95
        let xSpan = rect.width * 0.38
        let ySpan = rect.height * 0.20
        let xPix = centerX + harrierNormX * xSpan
        let yPix = centerY + harrierNormY * ySpan
        let muzzleOffsetX = rect.width * 0.012   // ~1.2% of width to the right (farther gap)
        let muzzleOffsetY = rect.height * 0.024  // ~2.4% of height upward
        let xPixMuzzle = xPix + muzzleOffsetX
        let yPixMuzzle = yPix + muzzleOffsetY

        if shotCooldown == 0 {
            // Spawn just ahead of Harrier in Z, and compute world X from Harrier’s muzzle offset
            let zRelStart: CGFloat = shotRelMin
            let scaleAtShot = focal / zRelStart
            let worldX = (xPixMuzzle - centerX) / scaleAtShot

            if sprites.filter({ $0.kind == .shot }).count < maxShots {
                let s = Sprite(kind: .shot, x: worldX, z: worldZ + zRelStart, size: 0.20, y: yPixMuzzle, age: 0)
                sprites.append(s)
                shotCooldown = shotCooldownFrames
            }
        }

        // Advance shots and have them drift toward screen center as they zoom out
        if !sprites.isEmpty {
            for i in 0..<sprites.count {
                if sprites[i].kind == .shot {
                    sprites[i].age += 1
                    // Advance absolute Z by world step + net zoom speed so relative Z always grows
                    let worldStep = speed * objectSpeedMult * fscale
                    sprites[i].z += worldStep + shotRelNetSpeed * fscale

                    // Clamp to the travel window in relative-Z
                    var rel = sprites[i].z - worldZ
                    if rel < shotRelMin {
                        rel = shotRelMin
                        sprites[i].z = worldZ + rel
                    }
                    if rel > shotRelMax {
                        rel = shotRelMax
                        sprites[i].z = worldZ + rel
                    }

                    // Progress 0..1 based on depth window
                    let span = max(0.001, shotRelMax - shotRelMin)
                    let t = min(1.0, max(0.0, (rel - shotRelMin) / span))

                    // Hold near Harrier first, then start drifting to center after shotDriftStart..shotDriftEnd
                    let driftPhase = (t - shotDriftStart) / max(0.001, (shotDriftEnd - shotDriftStart))
                    let drift = max(0.0, min(1.0, driftPhase))
                    let driftSmoothed = drift * drift * (3 - 2 * drift) // smoothstep

                    // Target in screen space
                    let targetSX = xPixMuzzle * (1 - driftSmoothed) + centerX * driftSmoothed
                    let targetSY = yPixMuzzle * (1 - driftSmoothed) + centerY * driftSmoothed

                    // Convert screen X to world X at current depth
                    let zRel = max(0.001, sprites[i].z - worldZ)
                    let s = focal / zRel
                    let desiredWorldX = (targetSX - centerX) / s

                    // Smoothly chase the target; if we fall far behind in screen space, snap closer
                    let k = shotFollowLerp
                    // current screen position of the shot (for snap test)
                    let curS = focal / max(0.001, zRel)
                    let curSX = centerX + sprites[i].x * curS
                    let curSY = sprites[i].y
                    let dx = targetSX - curSX
                    let dy = targetSY - curSY
                    let dist = sqrt(dx*dx + dy*dy)
                    let snapThreshold: CGFloat = max(12.0, self.bounds.width * 0.01) // ~1% width or 12px
                    if dist > snapThreshold {
                        // snap most of the way to avoid visible lag
                        sprites[i].x = sprites[i].x + (desiredWorldX - sprites[i].x) * max(k, 0.9)
                        sprites[i].y = sprites[i].y + (targetSY - sprites[i].y) * max(k, 0.9)
                    } else {
                        sprites[i].x += (desiredWorldX - sprites[i].x) * k
                        sprites[i].y += (targetSY - sprites[i].y) * k
                    }
                }
            }
        }
        // --- end Shots ---

        // --- Harrier autonomous movement ---
        if harrierStateFrames <= 0 {
            if harrierIsWaiting {
                // pick a new target away from current side; avoid tiny moves
                let sign: CGFloat = (arc4random_uniform(2) == 0) ? -1.0 : 1.0
                let mag = 0.20 + 0.60 * rand01() // 0.20..0.80 of max
                harrierTargetNormX = sign * mag * harrierMaxNormX
                // also pick a vertical target (up/down), modest magnitude
                let ySign: CGFloat = (arc4random_uniform(2) == 0) ? -1.0 : 1.0
                let yMag = 0.10 + 0.60 * rand01() // 0.10..0.70 of max
                harrierTargetNormY = ySign * yMag * harrierMaxNormY
                harrierStateFrames = harrierMoveFramesMin + Int(rand01() * CGFloat(harrierMoveFramesMax - harrierMoveFramesMin))
                harrierIsWaiting = false
            } else {
                // waiting period after a move
                harrierStateFrames = harrierWaitFramesMin + Int(rand01() * CGFloat(harrierWaitFramesMax - harrierWaitFramesMin))
                harrierIsWaiting = true
            }
        }

        if harrierIsWaiting {
            // friction to come to rest
            harrierVX *= 0.90
            harrierVY *= 0.90
        } else {
            // accelerate toward target with a bit of ease near the destination
            let dx = harrierTargetNormX - harrierNormX
            let dir: CGFloat = (dx >= 0) ? 1.0 : -1.0
            var a = harrierAccel
            if abs(dx) < 0.06 { a *= 0.5 }
            if abs(dx) < 0.03 { a *= 0.5 }
            harrierVX += a * dir
            // clamp speed
            if harrierVX > harrierMaxSpeed { harrierVX = harrierMaxSpeed }
            if harrierVX < -harrierMaxSpeed { harrierVX = -harrierMaxSpeed }

            // vertical control toward target
            let dy = harrierTargetNormY - harrierNormY
            let dirY: CGFloat = (dy >= 0) ? 1.0 : -1.0
            var aY = harrierAccelY
            if abs(dy) < 0.06 { aY *= 0.5 }
            if abs(dy) < 0.03 { aY *= 0.5 }
            harrierVY += aY * dirY
            if harrierVY > harrierMaxSpeedY { harrierVY = harrierMaxSpeedY }
            if harrierVY < -harrierMaxSpeedY { harrierVY = -harrierMaxSpeedY }
        }

        // integrate
        harrierNormX += harrierVX
        // keep within margins
        if harrierNormX > harrierMaxNormX { harrierNormX = harrierMaxNormX; harrierVX = 0 }
        if harrierNormX < -harrierMaxNormX { harrierNormX = -harrierMaxNormX; harrierVX = 0 }
        // integrate/clamp Y
        harrierNormY += harrierVY
        if harrierNormY > harrierMaxNormY { harrierNormY = harrierMaxNormY; harrierVY = 0 }
        if harrierNormY < -harrierMaxNormY { harrierNormY = -harrierMaxNormY; harrierVY = 0 }

        // if we reached target while moving, end move phase early
        if !harrierIsWaiting,
           abs(harrierTargetNormX - harrierNormX) < harrierStopEps,
           abs(harrierTargetNormY - harrierNormY) < harrierStopEpsY {
            harrierStateFrames = 0
            harrierIsWaiting = true
        }

        // countdown state frames
        if harrierStateFrames > 0 { harrierStateFrames -= 1 }
        // --- end Harrier movement ---

        needsDisplay = true
    }

    @inline(__always) private func rand01() -> CGFloat {
        return CGFloat(Double(arc4random()) / Double(UInt32.max))
    }

    // MARK: - Pixel snapping helpers
    @inline(__always) private func backingScale() -> CGFloat {
        if let s = self.window?.backingScaleFactor { return s }
        if let s = NSScreen.main?.backingScaleFactor { return s }
        return 2.0 // assume Retina if unknown
    }

    @inline(__always) private func snap(_ v: CGFloat, _ scale: CGFloat) -> CGFloat {
        return (v * scale).rounded() / scale
    }

    @inline(__always) private func snapRect(x: CGFloat, y: CGFloat, w: CGFloat, h: CGFloat, scale: CGFloat) -> NSRect {
        return NSRect(x: snap(x, scale), y: snap(y, scale), width: max(1, snap(w, scale)), height: max(1, snap(h, scale)))
    }

    private func randomLaneX() -> CGFloat {
        // pick a lane from -6 ... 6
        let lanes = [-6,-5,-4,-3,-2,-1,0,1,2,3,4,5,6]
        let idx = Int(arc4random_uniform(UInt32(lanes.count)))
        return CGFloat(lanes[idx]) * laneWidth
    }

    private func spawnSprite() {
        let kind: SpriteKind = (arc4random_uniform(100) < 75) ? .bush : .column
        let size: CGFloat = (kind == .bush) ? 0.9 : 1.2
        let s = Sprite(kind: kind, x: randomLaneX(), z: worldZ + spawnDistance, size: size, y: 0, age: 0)
        sprites.append(s)
    }

    private func choosePattern() -> [Int] {
        // Lane indices to fill this row; keep it light to avoid overload
        let patterns: [[Int]] = [
            [-6,-4,-2,2,4,6],
            [-5,-3,3,5],
            [-4,-2,2,4],
            [-6,-2,2,6],
            [-5,-3,3,5],
            [-4,4],
            [-6,6]
        ]
        let idx = Int(arc4random_uniform(UInt32(patterns.count)))
        return patterns[idx]
    }

    @discardableResult
    private func spawnRow() -> Int {
        let z = worldZ + spawnDistance
        var lanes = choosePattern()

        lanes = lanes.filter { abs($0) >= 2 }

        // Filter by per‑lane spacing and budget
        var spawned = 0
        lanes = lanes.filter { lane in
            if (sprites.filter { $0.kind != .shot }.count + spawned) >= maxObstacles { return false }
            if let nextZ = laneNextAllowedZ[lane], z < nextZ { return false }
            return true
        }

        for lane in lanes {
            if (sprites.filter { $0.kind != .shot }.count + spawned) >= maxObstacles { break }
            let kind: SpriteKind = nextIsBush ? .bush : .column
            nextIsBush.toggle()
            let sizeJitter: CGFloat = 0.80 + rand01() * 0.30 // 0.80..1.10
            let spr = Sprite(kind: kind,
                             x: CGFloat(lane) * laneWidth,
                             z: z,
                             size: (kind == .bush ? 0.40 : 0.65) * sizeJitter,
                             y: 0,
                             age: 0)
            sprites.append(spr)
            spawned += 1
            laneNextAllowedZ[lane] = z + laneMinSpacing
        }
        return spawned
    }

    private func drawSky(in rect: NSRect, horizonY: CGFloat) {
        // Sky gradient (top to just above horizon)
        let skyOverlap: CGFloat = 12.0 // extend well below the horizon
        let skyRect = NSRect(x: rect.minX, y: max(rect.minY, horizonY - (rect.height * 0.25) - skyOverlap), width: rect.width, height: rect.maxY - max(rect.minY, horizonY - (rect.height * 0.25) - skyOverlap))
        if let grad = skyGradient {
            grad.draw(in: skyRect, angle: 90)
        } else {
            skyTop.setFill(); skyRect.fill()
        }

        // Horizon glow band (soft fade)
        let glowHeight = rect.height * 0.06
        let glowRect = NSRect(x: rect.minX, y: max(rect.minY, horizonY - glowHeight - skyOverlap), width: rect.width, height: glowHeight + skyOverlap)
        glowGradient?.draw(in: glowRect, angle: 90)
    }

    // MARK: - Retro ground with proper Space Harrier-style perspective
    private func y(fromZ z: CGFloat, horizonY: CGFloat, focal: CGFloat) -> CGFloat {
        // Ground plane mapping: screen Y grows as 1/z below the horizon
        return horizonY - focal / z
    }

    private func drawCheckerboardPerspective(in rect: NSRect) {
        let centerX = rect.midX
        let horizonY = rect.height * 0.65 // push horizon higher for more ground
        let focal: CGFloat = rect.height * 0.95 // perspective strength

        // Background sky behind the ground
        drawSky(in: rect, horizonY: horizonY)

        // Compute the nearest Z that maps to the bottom of the screen
        let bottomY = rect.minY
        let denom = max(1.0, (horizonY - bottomY))
        let zNear = max(0.01, focal / denom)

        var kStart = Int(floor((cameraZ + zNear - zBias) / tileSize))
        let maxBands = 90
        let minBandPx: CGFloat = 2.3
        let overlapPx: CGFloat = 0.75 // small vertical overlap to hide seams
        let skirtPx: CGFloat = 12.0 // extend near edge below the screen to avoid pop

        let bright = NSColor(calibratedRed: 0.78, green: 1, blue: 0.74, alpha: 1.0)
        let dark   = NSColor(calibratedRed: 0.6, green: 0.78, blue: 0.57, alpha: 1.0)

        // Probe forward to find the farthest band still below the horizon
        var kProbe = kStart
        var steps = 0
        while steps < maxBands {
            let zAprobe = CGFloat(kProbe + 1) * tileSize - cameraZ + zBias
            let zBprobe = CGFloat(kProbe + 2) * tileSize - cameraZ + zBias
            if zAprobe <= 0 { kProbe += 1; steps += 1; continue }
            let yTopProbe = y(fromZ: zBprobe, horizonY: horizonY, focal: focal)
            if yTopProbe > horizonY + 1 { break }
            kProbe += 1
            steps += 1
        }
        let kFar = kProbe // exclusive upper bound

        var k = kFar - 1 // draw far -> near so near covers any gaps
        var bandsDrawn = 0
        // Precompute horizontal cull bounds and reusable path
        let minX = rect.minX - 2
        let maxX = rect.maxX + 2
        let quadPath = NSBezierPath()
        while k >= kStart && bandsDrawn < maxBands {
            // Depth band between two successive world tile edges (near zA, far zB)
            let zA = CGFloat(k + 1) * tileSize - cameraZ + zBias // nearer edge with bias
            let zB = CGFloat(k + 2) * tileSize - cameraZ + zBias // farther edge with bias

            if zA <= 0 { k -= 1; continue }

            let yBot = y(fromZ: zA, horizonY: horizonY, focal: focal)
            let yTop = y(fromZ: zB, horizonY: horizonY, focal: focal)

            // Stop if the band is fully above the horizon
            if yTop > horizonY + 1 { break }

            // Skip ultra-thin far bands, but keep drawing nearer ones
            if (yTop - yBot) < minBandPx { k -= 1; continue }

            // Projected tile widths at near/far edges
            let wNear = focal * tileSize / zA
            let wFar  = focal * tileSize / zB
            let halfCols = Int(ceil(rect.width / max(1.0, wNear))) / 2 + 4

            for xi in (-halfCols)...halfCols {
                let leftNear  = centerX + CGFloat(xi) * wNear
                let rightNear = centerX + CGFloat(xi + 1) * wNear
                let leftFar   = centerX + CGFloat(xi) * wFar
                let rightFar  = centerX + CGFloat(xi + 1) * wFar

                // Quick horizontal cull
                let quadMinX = min(min(leftNear, rightNear), min(leftFar, rightFar))
                let quadMaxX = max(max(leftNear, rightNear), max(leftFar, rightFar))
                if quadMaxX < minX || quadMinX > maxX {
                    continue
                }

                let isBright = ((k + xi) & 1) == 0
                (isBright ? bright : dark).setFill()

                var yBotClamped = min(yBot - skirtPx, rect.minY - skirtPx) // push slightly below the bottom so it fully exits
                var yTopClamped = min(max(yTop, rect.minY), horizonY)

                // Add a little overlap for non-nearest bands so seams never show
                if k > kStart { yTopClamped += overlapPx }

                quadPath.removeAllPoints()
                quadPath.move(to: NSPoint(x: leftNear,  y: yBotClamped))
                quadPath.line(to: NSPoint(x: rightNear, y: yBotClamped))
                quadPath.line(to: NSPoint(x: rightFar,  y: yTopClamped))
                quadPath.line(to: NSPoint(x: leftFar,   y: yTopClamped))
                quadPath.close()
                quadPath.fill()
            }

            k -= 1
            bandsDrawn += 1
        }
    }

    private func drawSprites(in rect: NSRect, horizonY: CGFloat, focal: CGFloat) {
        guard !sprites.isEmpty else { return }
        let centerX = rect.midX
        let objYOffsetPx: CGFloat = rect.height * 0.06 // push sprites lower on screen
        let scaleGamma: CGFloat = 0.95 // damp growth so objects stay smaller near the camera
        let objPitchPx: CGFloat = rect.height * 0.10 // LOWER angle so sprites are flatter

        if let ctx = NSGraphicsContext.current {
            let prev = ctx.shouldAntialias
            ctx.shouldAntialias = false
            let prevInterp = ctx.imageInterpolation
            ctx.imageInterpolation = .none
            defer {
                ctx.shouldAntialias = prev
                ctx.imageInterpolation = prevInterp
            }
        }

        let maxZConsider = spawnDistance * 1.4
        let xMargin = rect.width * 0.20

        // Early cull: keep only sprites that are plausibly visible in X/Z, and skip shots
        let prefiltered: [Sprite] = sprites.filter { spr in
            let z = spr.z - worldZ + (spr.kind == .shot ? 0 : zBias)
            if z <= 0.001 || z > maxZConsider { return false }
            let s = focal / z
            let x = centerX + spr.x * s
            return spr.kind != .shot && x > rect.minX - xMargin && x < rect.maxX + xMargin
        }

        // Sort far → near for correct overdraw
        let ordered = prefiltered.sorted { (a, b) -> Bool in
            let za = a.z - worldZ + (a.kind == .shot ? 0 : zBias)
            let zb = b.z - worldZ + (b.kind == .shot ? 0 : zBias)
            return za > zb
        }

        let scaleFactor = backingScale()
        for spr in ordered {
            // For shots, their depth ignores zBias so they shrink as they move away from the camera.
            let z = spr.z - worldZ + (spr.kind == .shot ? 0 : zBias)
            if z <= 0.001 { continue }

            let scale = focal / z
            let scaleAdj = pow(scale, scaleGamma)

            var screenX = centerX + spr.x * scale
            // Keep center clear for obstacles only (do NOT push shots)
            if spr.kind != .shot {
                let deadZonePx: CGFloat = rect.width * 0.06 // ~6% of width on each side of center
                let dx = screenX - centerX
                if abs(dx) < deadZonePx {
                    let pushDir: CGFloat = (dx == 0) ? 1 : (dx > 0 ? 1 : -1)
                    screenX = centerX + pushDir * deadZonePx
                }
            }

            let groundY: CGFloat
            if spr.kind == .shot {
                groundY = spr.y
            } else {
                groundY = y(fromZ: z, horizonY: horizonY, focal: focal) - (objPitchPx / z) - objYOffsetPx // lower on screen
            }

            // Base pixel size and caps per kind
            let basePxShot: CGFloat = 6
            let maxWShot: CGFloat = rect.height * 0.3
            let basePxOther: CGFloat = 8
            let maxWOther: CGFloat = rect.height * 0.30

            let isShot = (spr.kind == .shot)
            let basePx = isShot ? basePxShot : basePxOther
            let maxW = isShot ? maxWShot : maxWOther
            let w = min(maxW, max(4, basePx * spr.size * (isShot ? scale : scaleAdj)))
            let h = w * ((spr.kind == .column) ? 1.6 : (isShot ? 1.0 : 0.9))
            let spriteRect = snapRect(x: screenX - w/2, y: groundY, w: w, h: h, scale: scaleFactor)

            // Simple fog toward the horizon
            let fogStart: CGFloat = spawnDistance * 0.5
            let fogEnd: CGFloat = spawnDistance * 1.1
            var alpha: CGFloat = 1.0
            if z > fogStart { alpha = max(0.0, 1.0 - (z - fogStart) / max(0.001, fogEnd - fogStart)) }

            if alpha <= 0 { continue }

            NSGraphicsContext.saveGraphicsState()

            if spr.kind == .bush, let img = imgBush {
                img.draw(in: spriteRect, from: .zero, operation: .sourceOver, fraction: alpha, respectFlipped: true, hints: nil)
            } else if spr.kind == .column, let img = imgColumn {
                img.draw(in: spriteRect, from: .zero, operation: .sourceOver, fraction: alpha, respectFlipped: true, hints: nil)
            } else {
                // Vector fallback for bushes/columns
                if spr.kind == .bush {
                    let p = NSBezierPath(ovalIn: spriteRect)
                    NSColor(calibratedRed: 0.22, green: 0.85, blue: 0.38, alpha: alpha).setFill()
                    p.fill()
                } else {
                    let p = NSBezierPath(roundedRect: spriteRect, xRadius: w*0.08, yRadius: w*0.08)
                    NSColor(calibratedRed: 0.75, green: 0.75, blue: 0.82, alpha: alpha).setFill()
                    p.fill()
                }
            }
            NSGraphicsContext.restoreGraphicsState()
        }
    }

    private func drawShots(in rect: NSRect, horizonY: CGFloat, focal: CGFloat) {
        // Draw only shot sprites (bullets) on top of Harrier
        let centerX = rect.midX
        let objYOffsetPx: CGFloat = rect.height * 0.06
        let objPitchPx: CGFloat = rect.height * 0.10

        if let ctx = NSGraphicsContext.current {
            let prev = ctx.shouldAntialias
            ctx.shouldAntialias = false
            let prevInterp = ctx.imageInterpolation
            ctx.imageInterpolation = .none
            defer {
                ctx.shouldAntialias = prev
                ctx.imageInterpolation = prevInterp
            }
        }

        let maxZConsider = spawnDistance * 1.4
        let xMargin = rect.width * 0.20

        // Prefilter ONLY shots
        let prefiltered: [Sprite] = sprites.filter { spr in
            guard spr.kind == .shot else { return false }
            let z = spr.z - worldZ // shots ignore zBias
            if z <= 0.001 || z > maxZConsider { return false }
            let s = focal / z
            let x = centerX + spr.x * s
            return x > rect.minX - xMargin && x < rect.maxX + xMargin
        }

        // Sort far → near (not super critical for shots but consistent)
        let ordered = prefiltered.sorted { (a, b) -> Bool in
            let za = a.z - worldZ
            let zb = b.z - worldZ
            return za > zb
        }

        // Hue-shifted particle image (cached) — reduce CI work by updating every `hueFrames` frames
        let tNow = CGFloat(CACurrentMediaTime())
        var cgHuedParticle: CGImage? = nil
        let parity = shotFrameCounter % hueFrames
        if let ci = ciParticle {
            if parity != cachedHueParity {
                if let hf = hueFilter {
                    let hueAngle = Float((tNow * 3.0).truncatingRemainder(dividingBy: 6.28318530718))
                    hf.setValue(ci, forKey: kCIInputImageKey)
                    hf.setValue(hueAngle, forKey: kCIInputAngleKey)
                    if let out = hf.outputImage {
                        cachedHueParticle = ciContext.createCGImage(out, from: out.extent)
                        cachedHueParity = parity
                    }
                }
            }
            cgHuedParticle = cachedHueParticle
        }

        let spinAngle = CGFloat(tNow * 6.0)

        let scaleFactor = backingScale()
        for spr in ordered {
            let z = spr.z - worldZ
            if z <= 0.001 { continue }

            let scale = focal / z
            // Shots use linear scale for a clear shrink
            var screenX = centerX + spr.x * scale
            // Shots are allowed at center; no dead-zone push

            // Shots draw at their anchored screen Y (spawned)
            let groundY: CGFloat = spr.y

            // Size for shots — explicit 1/z mapping so shrink is obvious
            let minWShot: CGFloat = 9
            let maxWShot: CGFloat = rect.height * 0.16
            let kShot: CGFloat = maxWShot * shotRelMin // when z == shotRelMin, width hits max cap
            let w = max(minWShot, min(maxWShot, kShot / z))
            let h = w // square particle
            let spriteRect = snapRect(x: screenX - w/2, y: groundY, w: w, h: h, scale: scaleFactor)

            // Fog/alpha
            let fogStart: CGFloat = spawnDistance * 0.5
            let fogEnd: CGFloat = spawnDistance * 1.1
            var alpha: CGFloat = 1.0
            if z > fogStart { alpha = max(0.0, 1.0 - (z - fogStart) / max(0.001, fogEnd - fogStart)) }
            // Additional fade once the shot has reached the center (past drift end)
            let spanT = max(0.001, shotRelMax - shotRelMin)
            let zRelShot = z // shots ignore zBias here
            let tShot = min(1.0, max(0.0, (zRelShot - shotRelMin) / spanT))
            if tShot > shotDriftEnd {
                let fade = max(0.0, 1.0 - (tShot - shotDriftEnd) / max(0.001, 1.0 - shotDriftEnd))
                alpha *= fade
            }
            if alpha <= 0 { continue }

            // Draw shot bitmap spinning with fast hue shift
            if let cgimg = cgHuedParticle {
                NSGraphicsContext.saveGraphicsState()
                let cx = spriteRect.midX
                let cy = spriteRect.midY
                let angle = spinAngle
                let tx = NSAffineTransform()
                tx.translateX(by: cx, yBy: cy)
                tx.rotate(byRadians: angle)
                tx.translateX(by: -cx, yBy: -cy)
                tx.concat()
                if let ctx = NSGraphicsContext.current?.cgContext { ctx.setAlpha(alpha) }
                NSGraphicsContext.current?.cgContext.draw(cgimg, in: spriteRect)
                NSGraphicsContext.restoreGraphicsState()
            } else if let img = imgParticle {
                NSGraphicsContext.saveGraphicsState()
                let cx = spriteRect.midX
                let cy = spriteRect.midY
                let angle = spinAngle
                let tx = NSAffineTransform()
                tx.translateX(by: cx, yBy: cy)
                tx.rotate(byRadians: angle)
                tx.translateX(by: -cx, yBy: -cy)
                tx.concat()
                img.draw(in: spriteRect, from: .zero, operation: .sourceOver, fraction: alpha, respectFlipped: true, hints: nil)
                NSGraphicsContext.restoreGraphicsState()
            } else {
                // Vector fallback
                NSGraphicsContext.saveGraphicsState()
                let cx = spriteRect.midX
                let cy = spriteRect.midY
                let angle = spinAngle
                let tx = NSAffineTransform()
                tx.translateX(by: cx, yBy: cy)
                tx.rotate(byRadians: angle)
                tx.translateX(by: -cx, yBy: -cy)
                tx.concat()
                NSColor.white.setFill()
                NSBezierPath(rect: spriteRect).fill()
                NSGraphicsContext.restoreGraphicsState()
            }
        }
    }

    private func drawHarrier(in rect: NSRect, horizonY: CGFloat, focal: CGFloat) {
        let z = harrierZ // player sits at a fixed Z relative to camera; ignore ground zBias
        guard z > 0 else { return }

        let scale = focal / z
        let centerX = rect.midX
        let centerY = rect.midY

        // Perspective size, clamped to a sane fraction of screen height
        let h0 = harrierBasePx * scale
        let maxH = rect.height * harrierMaxHFrac
        let h = min(maxH, max(24, h0))
        let w: CGFloat
        if let img = imgHarrier {
            let ar = img.size.width / max(1.0, img.size.height)
            w = h * ar
        } else {
            w = h * 0.75 // fallback aspect
        }

        // Subtle vertical bob so it feels alive
        let t = CACurrentMediaTime() * harrierBobSpeed
        let bob = sin(t) * (rect.height * harrierBobAmpFrac)

        let xSpan = rect.width * 0.38   // horizontal travel span (keeps within margins)
        let ySpan = rect.height * 0.20  // vertical travel span
        let xPix = centerX + harrierNormX * xSpan
        let yPix = centerY + harrierNormY * ySpan
        let scaleFactor = backingScale()
        let dst = snapRect(x: xPix - w/2, y: yPix - h/2 + bob, w: w, h: h, scale: scaleFactor)

        if let ctx = NSGraphicsContext.current {
            let prevAA = ctx.shouldAntialias
            ctx.shouldAntialias = false
            let prevInterp = ctx.imageInterpolation
            ctx.imageInterpolation = .none
            defer {
                ctx.shouldAntialias = prevAA
                ctx.imageInterpolation = prevInterp
            }
        }

        if let img = imgHarrier {
            img.draw(in: dst, from: .zero, operation: .sourceOver, fraction: 1.0, respectFlipped: true, hints: nil)
        } else {
            // Vector fallback if the image is missing
            let p = NSBezierPath(roundedRect: dst, xRadius: w*0.12, yRadius: w*0.12)
            NSColor.white.setFill(); p.fill()
            NSColor.black.setStroke(); p.lineWidth = 1; p.stroke()
        }
    }
}
