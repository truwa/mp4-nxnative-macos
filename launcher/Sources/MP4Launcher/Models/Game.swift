import Foundation

/// A supported title. Other Switch games may be added later.
struct Game: Identifiable, Hashable {
    let id: String          // title id, used as the cache folder name
    let name: String
    let updateVersion: String   // folder under <cache>/rewritten/
    let expectedUpdate: String  // human-readable update version
    let mainBuildID: String     // main module build ID (first 8 bytes): the cheat file name in a mod folder

    static let metroidPrime4 = Game(
        id: "010019A01E2F2000",
        name: "Metroid Prime 4: Beyond",
        updateVersion: "v110",
        expectedUpdate: "1.1.0",
        mainBuildID: "8275FBE1EC5191C2"
    )

    static let all: [Game] = [.metroidPrime4]
}
