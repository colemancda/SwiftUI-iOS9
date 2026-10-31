import CSwiftUIBackend

/// The app's entry point. Mark a conforming type `@main`.
@MainActor
public protocol App {
    associatedtype Body: Scene

    @SceneBuilder var body: Body { get }

    init()
}

extension App {
    nonisolated public static func main() {
        MainActor.assumeIsolated {
            let app = Self()
            currentRenderer = Renderer { nodes, context in
                app.body._render(into: &nodes, context: context)
            }
        }
        sui_run(nil, { _ in
            MainActor.assumeIsolated { currentRenderer?.render() }
        })
    }
}

@MainActor
public protocol Scene {
    func _render(into nodes: inout [_Node], context: _RenderContext)
}

/// The app's single window.
public struct WindowGroup<Content: View>: Scene {
    let content: () -> Content

    public init(@ViewBuilder content: @escaping () -> Content) {
        self.content = content
    }

    public func _render(into nodes: inout [_Node], context: _RenderContext) {
        let scope = context.renderer.enterScope()
        content()._render(into: &nodes, context: context)
        context.renderer.exitScope(scope)
    }
}

@resultBuilder
public enum SceneBuilder {
    public static func buildBlock<Content: Scene>(_ content: Content) -> Content {
        content
    }
}
