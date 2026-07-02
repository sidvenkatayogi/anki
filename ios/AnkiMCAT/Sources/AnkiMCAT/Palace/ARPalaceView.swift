// Copyright: Ankitects Pty Ltd and contributors
// License: GNU AGPL, version 3 or later; http://www.gnu.org/licenses/agpl.html
//
// ARPalaceView — the immersive, on-device memory palace. Wraps an ARSCNView in
// world-tracking mode: tap a real surface to drop a card "pin" as a persistent
// ARAnchor (capture), or relocalize into a saved room and tap the pins
// (study). The room is saved as an ARWorldMap blob so pins reappear in the same
// physical spots across sessions. LiDAR, when present, adds a denser scene
// mesh; everything degrades to feature-point tracking on non-LiDAR devices.
//
// Requires a real device/camera at runtime (ARKit produces no frames in the
// Simulator) — the capture/study screens fall back to PhotoPalaceView there.
// This file still compiles for the Simulator so the whole app builds.
//
// Threading: the Coordinator is a plain (non-@MainActor) NSObject. ARKit/
// SceneKit invoke the delegate callbacks on a background render/session thread,
// so those callbacks do ALL of their SwiftUI-state, shared-map, and scene-graph
// work inside a hop to the main queue. Everything else (makeUIView/
// updateUIView, tap gestures) already runs on main.

import SwiftUI
import ARKit
import SceneKit

enum ARPalaceMode {
    case capture   // tap surfaces to place new pins
    case study     // relocalize + tap pins to answer
}

struct ARPalaceView: UIViewRepresentable {
    let mode: ARPalaceMode
    let loci: [Locus]
    var highlightedLocusID: UUID?
    /// Bump to request a world-map + snapshot capture (see onWorldMapCaptured).
    var saveToken: Int = 0
    var initialWorldMapData: Data?

    /// Placement result: (transform floats, anchorID, normalized tap point).
    var onPlaced: ((_ transform: [Float], _ anchorID: String, _ point: PalacePoint) -> Void)?
    /// A pin was tapped (study).
    var onSelected: ((UUID) -> Void)?
    /// A relocalization/tracking status message for UI coaching.
    var onStatus: ((String) -> Void)?
    var onWorldMapCaptured: ((Data) -> Void)?
    var onSnapshotCaptured: ((Data) -> Void)?

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> ARSCNView {
        let view = ARSCNView(frame: .zero)
        view.delegate = context.coordinator
        view.session.delegate = context.coordinator
        view.automaticallyUpdatesLighting = true
        view.scene = SCNScene()
        context.coordinator.sceneView = view

        let tap = UITapGestureRecognizer(target: context.coordinator,
                                         action: #selector(Coordinator.handleTap(_:)))
        view.addGestureRecognizer(tap)

        context.coordinator.start()
        return view
    }

    func updateUIView(_ uiView: ARSCNView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.syncLoci()
        context.coordinator.applyPinStyling()
        context.coordinator.handleSaveTokenIfNeeded()
    }

    static func dismantleUIView(_ uiView: ARSCNView, coordinator: Coordinator) {
        uiView.session.pause()
    }

    // MARK: - Coordinator

    final class Coordinator: NSObject, ARSCNViewDelegate, ARSessionDelegate {
        var parent: ARPalaceView
        weak var sceneView: ARSCNView?
        /// anchorID (== ARAnchor.name) → locusID. Touched only on the main queue.
        private var anchorToLocus: [String: UUID] = [:]
        /// anchorIDs already added to (or restored into) the session. Main only.
        private var placedAnchors: Set<String> = []
        private var lastSaveToken = 0

        init(_ parent: ARPalaceView) {
            self.parent = parent
        }

        func start() {
            guard ARWorldTrackingConfiguration.isSupported else {
                parent.onStatus?("AR isn't supported on this device.")
                return
            }
            let config = ARWorldTrackingConfiguration()
            config.planeDetection = [.horizontal, .vertical]
            config.environmentTexturing = .automatic
            // LiDAR enhancement: a denser mesh when the device supports it.
            if ARWorldTrackingConfiguration.supportsSceneReconstruction(.mesh) {
                config.sceneReconstruction = .mesh
            }
            if let data = parent.initialWorldMapData,
               let map = try? NSKeyedUnarchiver.unarchivedObject(ofClass: ARWorldMap.self, from: data) {
                config.initialWorldMap = map
                parent.onStatus?("Look around your room to line it up…")
            }
            sceneView?.session.run(config, options: [.resetTracking, .removeExistingAnchors])
        }

        // MARK: Placement (capture) — gesture callbacks arrive on main.

        @objc func handleTap(_ gesture: UITapGestureRecognizer) {
            guard let view = sceneView else { return }
            let point = gesture.location(in: view)

            // Study: tapping an existing pin answers "where is it?".
            if parent.mode == .study {
                if let locusID = locusID(at: point, in: view) {
                    parent.onSelected?(locusID)
                }
                return
            }

            guard parent.mode == .capture else { return }
            guard let query = view.raycastQuery(from: point,
                                                allowing: .estimatedPlane,
                                                alignment: .any),
                  let result = view.session.raycast(query).first else {
                parent.onStatus?("Point at a surface, then tap to place.")
                return
            }
            // Report the placement but DON'T add the anchor here — the anchor is
            // added in syncLoci once the locus (with this id) exists, so the
            // anchor→locus mapping is in place before ARKit's didAdd renders the
            // pin. Cancelling the card picker therefore leaves no orphan anchor.
            let anchorID = UUID().uuidString
            let floats = PalaceLogic.floats(from: result.worldTransform)
            let norm = PalacePoint(
                x: Float(max(0, min(1, point.x / max(view.bounds.width, 1)))),
                y: Float(max(0, min(1, point.y / max(view.bounds.height, 1)))))
            parent.onPlaced?(floats, anchorID, norm)
        }

        private func locusID(at point: CGPoint, in view: ARSCNView) -> UUID? {
            let hits = view.hitTest(point, options: [SCNHitTestOption.searchMode: SCNHitTestSearchMode.all.rawValue])
            for hit in hits {
                var node: SCNNode? = hit.node
                while let n = node {
                    if let name = n.name, let id = UUID(uuidString: name),
                       parent.loci.contains(where: { $0.id == id }) {
                        return id
                    }
                    node = n.parent
                }
            }
            return nil
        }

        // MARK: Loci ↔ anchors ↔ nodes (main only, from updateUIView)

        /// Reconcile the session's anchors with the current loci: register the
        /// anchor→locus map, add anchors for loci not yet in the session (new
        /// placements, or ones loaded from disk that the world map didn't
        /// restore), and remove anchors for loci that were deleted.
        func syncLoci() {
            guard let view = sceneView else { return }

            // Always keep the anchor→locus map current (didAdd uses it) — and do
            // this BEFORE adding any anchor so didAdd can resolve the new node.
            for locus in parent.loci {
                if let anchorID = locus.anchorID { anchorToLocus[anchorID] = locus.id }
            }

            // Study relocalizes into the SAVED ARWorldMap, which re-adds the
            // anchors itself; adding them again here would create a SECOND node
            // per locus. So only add/remove anchors while capturing.
            guard parent.mode == .capture else { return }

            for locus in parent.loci {
                guard let anchorID = locus.anchorID else { continue }
                if !placedAnchors.contains(anchorID), let m = PalaceLogic.matrix(from: locus.transform) {
                    let anchor = ARAnchor(name: anchorID, transform: m)
                    view.session.add(anchor: anchor)
                    placedAnchors.insert(anchorID)
                }
            }

            // Remove anchors/pins for loci that no longer exist.
            let current = Set(parent.loci.compactMap { $0.anchorID })
            let orphaned = placedAnchors.subtracting(current)
            if !orphaned.isEmpty {
                for anchor in (view.session.currentFrame?.anchors ?? [])
                where anchor.name.map({ orphaned.contains($0) }) ?? false {
                    view.session.remove(anchor: anchor)  // also removes its pin subtree
                }
                for name in orphaned {
                    placedAnchors.remove(name)
                    anchorToLocus.removeValue(forKey: name)
                }
            }
        }

        /// Restyle every pin for the current highlight/learned state. Runs when
        /// SwiftUI pushes updated loci (e.g. the study target moves).
        func applyPinStyling() {
            guard let root = sceneView?.scene.rootNode else { return }
            for locus in parent.loci {
                if let node = root.childNode(withName: locus.id.uuidString, recursively: true) {
                    styleNode(node, locusID: locus.id)
                }
            }
        }

        /// Color + emphasize a single pin. The highlighted spot is bright orange,
        /// glows, and pulses in scale so it's unmistakable in 3-D; others are
        /// green (recalled) or blue, static.
        private func styleNode(_ node: SCNNode, locusID: UUID) {
            let highlighted = locusID == parent.highlightedLocusID
            let learned = parent.loci.first { $0.id == locusID }?.learned ?? false
            let material = node.geometry?.firstMaterial
            material?.diffuse.contents = highlighted
                ? UIColor.systemOrange
                : (learned ? UIColor.systemGreen : UIColor.systemBlue)
            material?.emission.contents = highlighted ? UIColor.systemYellow : UIColor.black

            if highlighted {
                if node.action(forKey: "pulse") == nil {
                    let up = SCNAction.scale(to: 1.6, duration: 0.55)
                    let down = SCNAction.scale(to: 1.0, duration: 0.55)
                    up.timingMode = .easeInEaseOut
                    down.timingMode = .easeInEaseOut
                    node.runAction(.repeatForever(.sequence([up, down])), forKey: "pulse")
                }
            } else {
                node.removeAction(forKey: "pulse")
                node.scale = SCNVector3(1, 1, 1)
            }
        }

        // ARKit gives us a node for each added/restored anchor — build its pin.
        // This callback runs off the main thread, so hop before touching maps,
        // parent, or the scene graph.
        func renderer(_ renderer: SCNSceneRenderer, didAdd node: SCNNode, for anchor: ARAnchor) {
            guard let name = anchor.name else { return }
            DispatchQueue.main.async { [weak self] in
                guard let self, let locusID = self.locus(for: name) else { return }
                self.placedAnchors.insert(name)
                let index = (self.parent.loci.firstIndex { $0.id == locusID } ?? 0) + 1
                let learned = self.parent.loci.first { $0.id == locusID }?.learned ?? false
                let pin = Coordinator.makePin(number: index, learned: learned)
                pin.name = locusID.uuidString
                node.addChildNode(pin)
                // Style immediately: a restored anchor can appear AFTER the
                // current highlight was applied, so it must pick it up on creation.
                self.styleNode(pin, locusID: locusID)
            }
        }

        /// Main-queue only. Resolve a locus for an anchor name, learning the
        /// mapping for anchors restored from a saved world map.
        private func locus(for anchorName: String) -> UUID? {
            if let id = anchorToLocus[anchorName] { return id }
            if let locus = parent.loci.first(where: { $0.anchorID == anchorName }) {
                anchorToLocus[anchorName] = locus.id
                return locus.id
            }
            return nil
        }

        // MARK: Tracking status (callback is off-main → hop)

        func session(_ session: ARSession, cameraDidChangeTrackingState camera: ARCamera) {
            let mode = parent.mode
            let message: String
            switch camera.trackingState {
            case .normal:
                message = mode == .study ? "Ready — tap a pin." : "Tap a surface to place a card."
            case .notAvailable:
                message = "Starting AR…"
            case let .limited(reason):
                switch reason {
                case .relocalizing: message = "Finding your room — keep looking around…"
                case .initializing: message = "Move your phone slowly to map the space…"
                case .excessiveMotion: message = "Slow down a little."
                case .insufficientFeatures: message = "Point at a more textured area."
                @unknown default: message = "Adjusting…"
                }
            @unknown default:
                return
            }
            DispatchQueue.main.async { [weak self] in self?.parent.onStatus?(message) }
        }

        // MARK: Save (world map + snapshot) — invoked on main from updateUIView.

        func handleSaveTokenIfNeeded() {
            guard parent.saveToken != lastSaveToken else { return }
            lastSaveToken = parent.saveToken
            captureWorldMapAndSnapshot()
        }

        private func captureWorldMapAndSnapshot() {
            guard let view = sceneView else { return }
            // Hide the pin overlays so the saved snapshot is a clean room photo
            // (the 2-D fallback should show the room, not baked-in pins).
            let pins = view.scene.rootNode.childNodes(passingTest: { node, _ in
                node.name.flatMap(UUID.init) != nil
            })
            pins.forEach { $0.isHidden = true }
            let snapshot = view.snapshot()
            pins.forEach { $0.isHidden = false }
            if let jpeg = snapshot.jpegData(compressionQuality: 0.7) {
                parent.onSnapshotCaptured?(jpeg)
            }

            view.session.getCurrentWorldMap { [weak self] map, _ in
                guard let self, let map,
                      let data = try? NSKeyedArchiver.archivedData(withRootObject: map,
                                                                   requiringSecureCoding: true) else { return }
                DispatchQueue.main.async { self.parent.onWorldMapCaptured?(data) }
            }
        }

        // MARK: Pin geometry

        static func makePin(number: Int, learned: Bool) -> SCNNode {
            let sphere = SCNSphere(radius: 0.03)
            let mat = SCNMaterial()
            mat.diffuse.contents = learned ? UIColor.systemGreen : UIColor.systemBlue
            mat.lightingModel = .physicallyBased
            sphere.materials = [mat]
            let node = SCNNode(geometry: sphere)

            let text = SCNText(string: "\(number)", extrusionDepth: 0.5)
            text.font = .boldSystemFont(ofSize: 8)
            text.firstMaterial?.diffuse.contents = UIColor.white
            let textNode = SCNNode(geometry: text)
            textNode.scale = SCNVector3(0.004, 0.004, 0.004)
            textNode.position = SCNVector3(-0.012, 0.04, 0)
            textNode.constraints = [SCNBillboardConstraint()]
            node.addChildNode(textNode)
            return node
        }
    }
}
