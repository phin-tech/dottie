import Foundation
import DottieKit
import MCP

let instructions = """
Dottie draws sketchy or clean diagrams stored as .dottie JSON files. Every tool takes an absolute \
`path` ending in .dottie. For a new diagram, call build_diagram with nodes and edges: it lays them out \
automatically and creates connectors that stay attached. Then call export_png to LOOK at the result \
and fix anything that reads badly. Use list_elements to get element ids for update_element, \
delete_element and add_connector. Set sketchy=false for a precise, clean look. For loops, conditionals \
or many computed edits, write one JavaScript program and call run_script; script_api (or the resource \
dottie://script-api) documents the `dottie` object it uses. For interactive pages (states, traffic, \
capacity, gauges), start from a worked example: script_api with example, or the resources dottie://examples/<name>. \
Dottie presents scenarios: choose numbers that make the story clear.
"""

let server = Server(
    name: "dottie",
    version: DottieVersion.current,
    instructions: instructions,
    capabilities: .init(resources: .init(subscribe: false, listChanged: false), tools: .init(listChanged: false))
)
let tools = DottieTools()

await server.withMethodHandler(ListTools.self) { _ in
    .init(tools: DottieTools.definitions)
}

let scriptAPIURI = "dottie://script-api"
let scriptTypesURI = "dottie://dottie.d.ts"

await server.withMethodHandler(ListResources.self) { _ in
    .init(resources: [Resource(name: "script-api", uri: scriptAPIURI, title: "Dottie JavaScript API",
                               description: "Reference for the `dottie` object used by the run_script tool",
                               mimeType: "text/plain"),
                      Resource(name: "dottie.d.ts", uri: scriptTypesURI, title: "Dottie script types",
                               description: "TypeScript declarations for run_script's `dottie` object; run_script checks "
                                + "scripts against them when TypeScript is installed",
                               mimeType: "application/typescript")]
        + ScriptExamples.all.map { e in
            Resource(name: "example \(e.name)", uri: "dottie://examples/\(e.name)", title: e.title,
                     description: e.summary + " A run_script program for an empty page.", mimeType: "application/javascript")
        })
}

await server.withMethodHandler(ReadResource.self) { params in
    if params.uri == scriptTypesURI {
        return .init(contents: [.text(DottieScript.typeDefinitions, uri: scriptTypesURI, mimeType: "application/typescript")])
    }
    if params.uri.hasPrefix("dottie://examples/"), let e = ScriptExamples.named(String(params.uri.dropFirst("dottie://examples/".count))) {
        return .init(contents: [.text(e.code, uri: params.uri, mimeType: "application/javascript")])
    }
    guard params.uri == scriptAPIURI else { throw MCPError.invalidParams("Unknown resource \(params.uri)") }
    let installed = DottieScript.installedModules()
    let text = DottieScript.apiReference + "\n\nInstalled modules for require(): "
        + (installed.isEmpty ? "none" : installed.joined(separator: ", "))
    return .init(contents: [.text(text, uri: scriptAPIURI, mimeType: "text/plain")])
}

await server.withMethodHandler(CallTool.self) { params in
    await tools.call(name: params.name, arguments: params.arguments ?? [:])
}

try await server.start(transport: StdioTransport())
await server.waitUntilCompleted()
