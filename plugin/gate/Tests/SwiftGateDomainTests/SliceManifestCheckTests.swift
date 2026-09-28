import SwiftGateDomain
import Testing

@Suite("slice manifest check")
struct SliceManifestCheckTests {
  static func declared(_ targets: Set<String>, _ products: Set<String> = [])
    -> ManifestReading
  {
    .declared(ManifestDeclarations(targets: targets, products: products))
  }

  @Test(
    "a target or product the surface doesn't declare is named, sorted, and one it does is not — catches a slice's new Live target passing because its package already existed"
  )
  func newDeclarationsInAnExistingPackageAreNamed() {
    let findings = SliceManifestCheck.findings([
      SliceManifest(
        path: "Packages/ProfileClient/Package.swift",
        atSurface: Self.declared(["ProfileClient"], ["ProfileClient"]),
        atHead: Self.declared(
          ["ProfileClientLive", "ProfileClient", "Cache"], ["ProfileClientLive", "ProfileClient"])),
      SliceManifest(
        path: "Packages/ProfileFeature/Package.swift",
        atSurface: Self.declared(["ProfileCore"], ["ProfileCore"]),
        atHead: Self.declared(["ProfileCore"], ["ProfileCore"])),
    ])
    #expect(
      findings == [
        .undeclared(
          path: "Packages/ProfileClient/Package.swift", targets: ["Cache", "ProfileClientLive"],
          products: ["ProfileClientLive"])
      ])
  }

  @Test(
    "a package the surface lacks names every target and product it declares, and a deleted one names nothing — catches a new package read as adding nothing"
  )
  func aNewPackageNamesEverything() {
    let findings = SliceManifestCheck.findings([
      SliceManifest(
        path: "Packages/Extra/Package.swift", atSurface: nil,
        atHead: Self.declared(["Extra"], ["Extra"])),
      SliceManifest(
        path: "Packages/Gone/Package.swift", atSurface: Self.declared(["Gone"]), atHead: nil),
    ])
    #expect(
      findings == [
        .undeclared(path: "Packages/Extra/Package.swift", targets: ["Extra"], products: ["Extra"])
      ])
  }

  @Test(
    "a manifest unreadable at either commit is a finding naming the side — catches an unparsable manifest passed as declaring nothing new"
  )
  func unreadableManifestsAreFindings() {
    let findings = SliceManifestCheck.findings([
      SliceManifest(
        path: "A/Package.swift", atSurface: .unreadable("a syntax error"),
        atHead: Self.declared(["A"])),
      SliceManifest(
        path: "B/Package.swift", atSurface: Self.declared(["B"]),
        atHead: .unreadable("`targets:` isn't an array literal")),
      SliceManifest(path: "C/Package.swift", atSurface: nil, atHead: .unreadable("a syntax error")),
    ])
    #expect(
      findings == [
        .unreadable(path: "A/Package.swift", side: .surface, reason: "a syntax error"),
        .unreadable(
          path: "B/Package.swift", side: .head, reason: "`targets:` isn't an array literal"),
        .unreadable(path: "C/Package.swift", side: .head, reason: "a syntax error"),
      ])
  }

  @Test(
    "the message names the slice, each package, target and product, each unreadable manifest, and the fix — catches a refusal that doesn't say what to stub"
  )
  func messageNamesEachDeclarationAndTheFix() {
    let message = SliceManifestCheck.message(
      [
        .undeclared(
          path: "Packages/ProfileClient/Package.swift", targets: ["ProfileClientLive"],
          products: ["ProfileClientLive"]),
        .unreadable(path: "B/Package.swift", side: .head, reason: "a syntax error"),
      ], slice: 4, surface: "b12ac55", head: "1e3285e")
    #expect(
      message
        == "slice 4 at 1e3285e declares what the surface b12ac55 doesn't: "
        + "Packages/ProfileClient/Package.swift adds target ProfileClientLive and product "
        + "ProfileClientLive; B/Package.swift can't be read at 1e3285e (a syntax error). At the "
        + "surface a new target has no sources, so SwiftPM refuses its package and the ready "
        + "gate's prove can't build a test in it or a dependent. Amend the surface with a stub "
        + "for each target and product (its manifest entry and a source file that builds), then "
        + "rebuild the slices on it. Write each unreadable manifest's targets and products as "
        + "`.target(name: \"…\")`-style elements of the `targets:` and `products:` arrays in its "
        + "`Package(…)` call")
  }
}
