// Generated alongside scripts/update-script-modules.py conventions; versions and hashes are pinned.
import Foundation

/// An optional library the Scripting settings tab can download into the modules folder.
struct OptionalLibrary: Identifiable {
    struct File { var module: String; var path: String; var sha256: String }
    var id: String
    var title: String
    var detail: String
    var files: [File]
}

enum OptionalLibraries {
    /// jsDelivr serves npm packages at a fixed version; each file is checked against its SHA-256 before it is kept.
    static let baseURL = URL(string: "https://cdn.jsdelivr.net/npm/")!

    static let all: [OptionalLibrary] = [
        OptionalLibrary(id: "d3-scale", title: "d3-scale", detail: "Scales, ticks and color ramps (d3-scale with d3-interpolate, d3-format, d3-time, d3-time-format).", files: [
            .init(module: "d3-interpolate", path: "d3-interpolate@3.0.1/dist/d3-interpolate.min.js", sha256: "bfc321e4c3f3b3aadc88cfe15ccb5e443abfeadef8b75c65b41c33a4d78a98ae"),
            .init(module: "d3-format", path: "d3-format@3.1.0/dist/d3-format.min.js", sha256: "7d053f71a135100128802b6010ab58d1351ca412e2d7846c2f8c6fe155a66370"),
            .init(module: "d3-time", path: "d3-time@3.1.0/dist/d3-time.min.js", sha256: "0e67c6eed5832f4ac5bece0da0ea595860c4527d21c271a17013b7efe2665c00"),
            .init(module: "d3-time-format", path: "d3-time-format@4.1.0/dist/d3-time-format.min.js", sha256: "ce7c943affe8cbb049de1c4ee29ce98bd4cb4b393bd48cb0c7b4f8078c4752f5"),
            .init(module: "d3-scale", path: "d3-scale@4.0.2/dist/d3-scale.min.js", sha256: "e76a84839ffba3b94fef22ea1e39da8398fa0e039c7e6a0a93b7d938dbd50632"),
        ]),
        OptionalLibrary(id: "d3-shape", title: "d3-shape", detail: "Lines, arcs, areas and curves as path data (with d3-path).", files: [
            .init(module: "d3-path", path: "d3-path@3.1.0/dist/d3-path.min.js", sha256: "28d70841c60f313c3e6411fe0831e539ed6cea51eaee951d62d88908c40619c2"),
            .init(module: "d3-shape", path: "d3-shape@3.2.0/dist/d3-shape.min.js", sha256: "49236896e989f251dd36679ea4a879538e9ca2ece3a90a82740f953cac4a3fa5"),
        ]),
        OptionalLibrary(id: "d3-force", title: "d3-force", detail: "Force-directed graph layout (with d3-dispatch, d3-quadtree, d3-timer).", files: [
            .init(module: "d3-dispatch", path: "d3-dispatch@3.0.1/dist/d3-dispatch.min.js", sha256: "94b3bbdb6b98dc1325a15762b051013e8253999b0e0436b27d1da17b952ba0af"),
            .init(module: "d3-quadtree", path: "d3-quadtree@3.0.1/dist/d3-quadtree.min.js", sha256: "57e2ad12824ed82893ba447523f2a2fb9beeb9222aafb2c778a9f5b313348b0e"),
            .init(module: "d3-timer", path: "d3-timer@3.0.1/dist/d3-timer.min.js", sha256: "911ceda305f014b6b53ca68d5c896a9a387da120cfd56a421a2c60cca2fc9b36"),
            .init(module: "d3-force", path: "d3-force@3.0.0/dist/d3-force.min.js", sha256: "1e07b473241328795d5ea9ad479a7bbabd765012fa2ef95633c83b69868dff6b"),
        ]),
        OptionalLibrary(id: "chroma-js", title: "chroma-js", detail: "Color scales, mixing and contrast.", files: [
            .init(module: "chroma-js", path: "chroma-js@2.4.2/chroma.min.js", sha256: "a19aa0df3b7974028724b2666d8311a226acedc65a90947c7bc56eecb9a367ad"),
        ]),
        OptionalLibrary(id: "seedrandom", title: "seedrandom", detail: "Seeded random numbers, for repeatable layouts.", files: [
            .init(module: "seedrandom", path: "seedrandom@3.0.5/seedrandom.min.js", sha256: "d2eb17a05ada2abf19c8bcb1f0f1ae62bb6da5d59a69dc6414ced08704a88cd1"),
        ]),
        OptionalLibrary(id: "simple-statistics", title: "simple-statistics", detail: "Mean, median, regression and other statistics.", files: [
            .init(module: "simple-statistics", path: "simple-statistics@7.8.3/dist/simple-statistics.min.js", sha256: "f50f250731261071026a45c00e0c4bce6278da8041f09076e7b9e94163b28ad9"),
        ]),
    ]
}
