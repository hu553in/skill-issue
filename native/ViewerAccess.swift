import Foundation
import SimpleKeychain

struct ViewerEndpoint: Equatable, Sendable {
    let url: URL
    let origin: String

    init(_ text: String) throws {
        guard
            var components = URLComponents(
                string: text.trimmingCharacters(in: .whitespacesAndNewlines)),
            let scheme = components.scheme?.lowercased(),
            let host = components.host?.lowercased(), !host.isEmpty,
            components.user == nil, components.password == nil,
            components.query == nil, components.fragment == nil,
            components.path.isEmpty || components.path == "/",
            components.port.map({ (1...65535).contains($0) }) ?? true,
            scheme == "https" || scheme == "http" && ["127.0.0.1", "localhost"].contains(host)
        else { throw ViewerFailure.invalidEndpoint }
        components.scheme = scheme
        components.host = host
        components.path = ""
        if components.port == (scheme == "https" ? 443 : 80) { components.port = nil }
        guard let url = components.url else { throw ViewerFailure.invalidEndpoint }
        self.url = url
        origin = url.absoluteString
    }
}

struct ViewerAccessCredentials: Codable, Equatable, Sendable {
    var origin: String
    var clientID: String
    var clientSecret: String

    func validate(for endpoint: ViewerEndpoint) throws {
        guard origin == endpoint.origin else { throw ViewerFailure.setupRequired }
        for (value, failure) in [
            (clientID, ViewerFailure.invalidClientID), (clientSecret, .invalidClientSecret),
        ] {
            guard !value.isEmpty && value.utf8.allSatisfy({ (33...126).contains($0) }) else {
                throw failure
            }
        }
    }
}

struct ViewerAccessStorage: Sendable {
    var load: @Sendable (String) throws -> ViewerAccessCredentials?
    var save: @Sendable (ViewerAccessCredentials) throws -> Void

    static let keychain = Self(
        load: { origin in
            do {
                let endpoint = try ViewerEndpoint(origin)
                guard endpoint.origin == origin else { throw ViewerFailure.credentialsUnavailable }
                let data = try credentialKeychain.data(forKey: "viewer-access:\(origin)")
                let value = try JSONDecoder().decode(ViewerAccessCredentials.self, from: data)
                try value.validate(for: endpoint)
                return value
            } catch SimpleKeychainError.itemNotFound {
                return nil
            } catch { throw ViewerFailure.credentialsUnavailable }
        },
        save: { value in
            do {
                let endpoint = try ViewerEndpoint(value.origin)
                try value.validate(for: endpoint)
                try credentialKeychain.set(
                    JSONEncoder().encode(value), forKey: "viewer-access:\(value.origin)")
            } catch { throw ViewerFailure.credentialsNotSaved }
        })
}

enum ViewerFailure: Error, Equatable, Sendable {
    case invalidEndpoint, setupRequired, invalidClientID, invalidClientSecret,
        credentialsUnavailable,
        credentialsNotSaved, accessDenied, generic

    var message: String {
        switch self {
        case .invalidEndpoint:
            return
                "Enter a Viewer endpoint using HTTPS with no path, username, query or fragment. Local development can use HTTP on localhost or 127.0.0.1."
        case .setupRequired:
            return
                "Configure Cloudflare Access with a Client ID and Client secret for this Viewer endpoint before starting a session."
        case .invalidClientID:
            return
                "Copy the Client ID from your Cloudflare service token again. It contains an unsupported character."
        case .invalidClientSecret:
            return
                "Copy the Client secret from your Cloudflare service token again. It contains an unsupported character."
        case .credentialsUnavailable:
            return
                "Could not read Cloudflare Access credentials from Keychain. Restore Keychain access, then open Configure and try again."
        case .credentialsNotSaved:
            return
                "Could not save Cloudflare Access credentials to Keychain. Restore Keychain access, then choose Save again."
        case .accessDenied:
            return
                "The Viewer endpoint denied access. Check its Cloudflare Access policies and service token, then configure access and start a new session."
        case .generic:
            return
                "Could not connect to the Viewer endpoint. Check the endpoint and your network connection, then try again."
        }
    }

    var stopsSession: Bool { self == .accessDenied }
}
