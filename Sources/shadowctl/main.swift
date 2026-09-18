import Foundation
import ShadowAPI

// Headless parity CLI for ShadowAPI. Commands are filled in with M2.
let args = Array(CommandLine.arguments.dropFirst())
switch args.first ?? "help" {
case "config":
    let c = ShadowConfig.fromEnvironment()
    print("issuer:   \(c.oauthIssuer.absoluteString)")
    print("api base: \(c.apiBase.absoluteString)")
    print("redirect: \(c.redirectURI)")
default:
    print("usage: shadowctl <config>")
}
