import AppKit
import SwiftUI

struct ContentView: View {
    @EnvironmentObject var sessionStore: SessionStore
    @EnvironmentObject var settings: SettingsStore

    @State private var selectedID: UUID?
    @State private var showSidebar = true
    @State private var showSettings = false

    var body: some View {
        Group {
            if showSettings {
                SettingsView(onClose: { showSettings = false })
            } else {
                HStack(spacing: 0) {
                    if showSidebar {
                        SidebarView(
                            selectedID: $selectedID,
                            showSettings: $showSettings
                        )
                        .frame(width: 176)
                        .background(Color(nsColor: .controlBackgroundColor))
                    }
                    ChatView(
                        selectedID: $selectedID,
                        onOpenSettings: { showSettings = true },
                        onToggleSidebar: { showSidebar.toggle() }
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .onAppear {
            if selectedID == nil {
                selectedID = sessionStore.sessions.first?.id
            }
        }
    }
}

/// 面板顶部拖拽条：鼠标按下即拖动整个窗口
struct DragHandleStrip: View {
    var body: some View {
        DragHandleView()
            .frame(height: 22)
    }
}

private struct DragHandleView: NSViewRepresentable {
    func makeNSView(context: Context) -> DragView {
        DragView()
    }

    func updateNSView(_ nsView: DragView, context: Context) {}

    final class DragView: NSView {
        override var isFlipped: Bool { true }

        override func mouseDown(with event: NSEvent) {
            window?.performDrag(with: event)
        }

        override func draw(_ dirtyRect: NSRect) {
            let capsule = NSRect(x: bounds.midX - 18, y: 9, width: 36, height: 4)
            NSColor.secondaryLabelColor.withAlphaComponent(0.25).setFill()
            NSBezierPath(roundedRect: capsule, xRadius: 2, yRadius: 2).fill()
        }
    }
}
