import Foundation
import Testing

@testable import SkillIssue

@Test func viewerEndpointsCanonicalizeOnlyTheSameOrigin() throws {
    let endpoint = try ViewerEndpoint(" HTTPS://VIEWER.EXAMPLE.INVALID:443/ ")
    #expect(endpoint.origin == "https://viewer.example.invalid")
    #expect(endpoint.url.absoluteString == endpoint.origin)
    #expect(try ViewerEndpoint("http://LOCALHOST:80/").origin == "http://localhost")
    #expect(try ViewerEndpoint("http://127.0.0.1:8123").origin == "http://127.0.0.1:8123")
    #expect(
        try ViewerEndpoint("https://viewer.example.invalid:8443").origin
            == "https://viewer.example.invalid:8443")
}

@Test(arguments: [
    "", "viewer.example.invalid", "https://", "http://viewer.example.invalid",
    "http://localhost.example.invalid", "http://127.0.0.2", "ftp://viewer.example.invalid",
    "https://viewer.example.invalid/rooms", "https://viewer.example.invalid?query",
    "https://viewer.example.invalid#key", "https://user@viewer.example.invalid",
    "https://user:secret@viewer.example.invalid", "https://viewer.example.invalid:0",
    "https://viewer.example.invalid:65536", "https://viewer.example.invalid?",
    "https://viewer.example.invalid#", "https://@viewer.example.invalid",
    "https://viewer.example.invalid/%2F", "https://viewer.example.invalid/..",
])
func viewerEndpointsRejectNonOriginsAndCredentialBearingURLs(_ text: String) {
    #expect(throws: ViewerFailure.invalidEndpoint) { try ViewerEndpoint(text) }
}

@Test func viewerCredentialsCannotMoveToAnotherOriginOrInjectHeaders() throws {
    let endpoint = try ViewerEndpoint("https://viewer.example.invalid")
    let credentials = ViewerAccessCredentials(
        origin: endpoint.origin, clientID: "test.access", clientSecret: "test-secret")
    try credentials.validate(for: endpoint)
    try credentials.validate(for: ViewerEndpoint("HTTPS://VIEWER.EXAMPLE.INVALID:443/"))
    for other in [
        "https://other.example.invalid", "https://viewer.example.invalid:8443",
        "http://localhost",
    ] {
        #expect(throws: ViewerFailure.setupRequired) {
            try credentials.validate(for: ViewerEndpoint(other))
        }
    }
    for invalid in ["", "secret\r\nAuthorization: forged", "secret\n", "token secret", "секрет"] {
        for clientID in [true, false] {
            var changed = credentials
            if clientID { changed.clientID = invalid } else { changed.clientSecret = invalid }
            #expect(throws: clientID ? ViewerFailure.invalidClientID : .invalidClientSecret) {
                try changed.validate(for: endpoint)
            }
        }
    }
    var noncanonical = credentials
    noncanonical.origin = "https://viewer.example.invalid:443/"
    #expect(throws: ViewerFailure.setupRequired) { try noncanonical.validate(for: endpoint) }
}

@Test func viewerCredentialsDecodeTheExplicitStorageContract() throws {
    let data = Data(
        "{\"origin\":\"https://viewer.example.invalid\",\"clientID\":\"test.access\",\"clientSecret\":\"test-secret\"}"
            .utf8)
    let credentials = try JSONDecoder().decode(ViewerAccessCredentials.self, from: data)
    #expect(credentials.origin == "https://viewer.example.invalid")
    #expect(credentials.clientID == "test.access")
    #expect(credentials.clientSecret == "test-secret")
    let encoded =
        try JSONSerialization.jsonObject(with: JSONEncoder().encode(credentials))
        as? [String: String]
    #expect(
        encoded == [
            "origin": "https://viewer.example.invalid", "clientID": "test.access",
            "clientSecret": "test-secret",
        ])
}
