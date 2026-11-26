import Foundation
import SafeNetCore
@testable import SafeNetUI

private final class WBox<T> { var value: T? }
private func wait<T>(_ op: @escaping () async -> T) -> T {
    let sem = DispatchSemaphore(value: 0)
    let box = WBox<T>()
    Task { box.value = await op(); sem.signal() }
    sem.wait()
    return box.value!
}

private final class OneGeo: GeoSource {
    var calls = 0
    let map: [String: String]
    init(_ map: [String: String]) { self.map = map }
    var name: String { "geo.test" }
    func country(of ip: String) async throws -> String {
        calls += 1
        guard let c = map[ip] else { throw GeoError.badResponse }
        return c
    }
}

func registerGeoWiringTests() {
    test("testAnswersGetOneCountryPerAddress") {
        let src = OneGeo(["195.133.9.79": "NL", "46.138.81.39": "RU"])
        let geo = GeoResolver(sources: [src])
        let raw = [IPAnswer(ip: "195.133.9.79", country: ""), IPAnswer(ip: "195.133.9.79", country: ""),
                   IPAnswer(ip: "46.138.81.39", country: ""), IPAnswer(ip: "2001:db8::1", country: "DE")]
        let out = wait { await LiveSystem.withCountries(raw, geo: geo, lookUp: true) }
        expectEqual(out.map { $0.country }, ["NL", "NL", "RU", "DE"], "IPv6 keeps its own service's country")
        expectEqual(src.calls, 2, "one lookup per distinct IPv4 address")
        let cheap = wait { await LiveSystem.withCountries([IPAnswer(ip: "9.9.9.9", country: "")], geo: geo, lookUp: false) }
        expectEqual(cheap.first?.country, "", "cheap tick never asks a database")
        expectEqual(src.calls, 2)
        let quorum = Engine.confirmed(out.filter { !$0.ip.contains(":") }, minAgree: 2)
        expectEqual(quorum, IPAnswer(ip: "195.133.9.79", country: "NL"))
        expectEqual(Engine.splitIPs(out, confirmed: quorum), ["46.138.81.39"])
        expectEqual(Engine.splitIPs(out, confirmed: nil), [])
    }
}
