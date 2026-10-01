import Foundation
var out: [String: Any] = [:]
for s in FormatStyle.all {
    out[s.id] = ["prompt": s.prompt, "examples": s.examples.map { [$0.transcript, $0.output] }]
}
let data = try! JSONSerialization.data(withJSONObject: out, options: [.prettyPrinted, .sortedKeys])
print(String(data: data, encoding: .utf8)!)
