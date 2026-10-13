import Foundation
import MCP

let instructions = """
Dottie draws sketchy or clean diagrams stored as .dottie JSON files. Every tool takes an absolute \
`path` ending in .dottie. For a new diagram, call build_diagram with nodes and edges: it lays them out \
automatically and creates connectors that stay attached. Then call export_png to LOOK at the result \
and fix anything that reads badly. Use list_elements to get element ids for update_element, \
delete_element and add_connector. Set sketchy=false for a precise, clean look.
"""

let server = Server(
    name: "dottie",
    version: "0.1.0",
    instructions: instructions,
    capabilities: .init(tools: .init(listChanged: false))
)
let tools = DottieTools()

await server.withMethodHandler(ListTools.self) { _ in
    .init(tools: DottieTools.definitions)
}

await server.withMethodHandler(CallTool.self) { params in
    await tools.call(name: params.name, arguments: params.arguments ?? [:])
}

try await server.start(transport: StdioTransport())
await server.waitUntilCompleted()
