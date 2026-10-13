import Foundation
import SimpleKeychain

struct ChatGPTSession: Codable, Sendable {
    var idToken: String
    var accessToken: String?
    var refreshToken: String?
    var expires: Date?
    var scopes: [String]
    var canUsePlan: Bool { scopes.contains("chatgpt.tokens.use.direct") }
}

struct ChatGPTAccount: Codable, Sendable {
    var clientID: String
    var subject: String
    var email: String
    var session: ChatGPTSession?
    var pendingSession: ChatGPTSession?

    init(clientID: String, subject: String, email: String, session: ChatGPTSession?) {
        self.clientID = clientID
        self.subject = subject
        self.email = email
        self.session = session
    }

    private enum CodingKeys: String, CodingKey {
        case clientID, subject, email, session, pendingSession, idToken, accessToken, refreshToken,
            expires
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        clientID = try values.decode(String.self, forKey: .clientID)
        subject = try values.decode(String.self, forKey: .subject)
        email = try values.decode(String.self, forKey: .email)
        pendingSession = try values.decodeIfPresent(ChatGPTSession.self, forKey: .pendingSession)
        if values.contains(.idToken) {
            // Existing Keychain records were written only after direct plan permission was verified.
            session = ChatGPTSession(
                idToken: try values.decode(String.self, forKey: .idToken),
                accessToken: try values.decode(String.self, forKey: .accessToken),
                refreshToken: try values.decode(String.self, forKey: .refreshToken),
                expires: try values.decode(Date.self, forKey: .expires),
                scopes: ["chatgpt.tokens.use.direct"])
        } else {
            session = try values.decodeIfPresent(ChatGPTSession.self, forKey: .session)
        }
    }

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(clientID, forKey: .clientID)
        try values.encode(subject, forKey: .subject)
        try values.encode(email, forKey: .email)
        try values.encodeIfPresent(session, forKey: .session)
        try values.encodeIfPresent(pendingSession, forKey: .pendingSession)
    }
}

struct ChatGPTAccounts: Codable, Sendable {
    var accounts: [ChatGPTAccount] = []
    var selectedClientID: String?
    var selected: ChatGPTAccount? { accounts.first { $0.clientID == selectedClientID } }

    init() {}
    init(account: ChatGPTAccount) {
        accounts = [account]
        selectedClientID = account.clientID
    }
    private enum CodingKeys: String, CodingKey { case accounts, selectedClientID }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        if values.contains(.accounts) {
            self.init()
            accounts = try values.decode([ChatGPTAccount].self, forKey: .accounts)
            selectedClientID = try values.decodeIfPresent(String.self, forKey: .selectedClientID)
        } else {
            self.init(account: try ChatGPTAccount(from: decoder))
        }
    }
}

struct AccountStorage: Sendable {
    var load: @Sendable () throws -> ChatGPTAccounts?
    var save: @Sendable (ChatGPTAccounts) throws -> Void

    static let keychain = Self(
        load: {
            let data: Data
            do { data = try credentialKeychain.data(forKey: "chatgpt") } catch SimpleKeychainError
                .itemNotFound
            { return nil } catch { throw AppFailure.failed }
            return try JSONDecoder().decode(ChatGPTAccounts.self, from: data)
        },
        save: { value in
            let data = try JSONEncoder().encode(value)
            do { try credentialKeychain.set(data, forKey: "chatgpt") } catch {
                throw AppFailure.failed
            }
        })
}
