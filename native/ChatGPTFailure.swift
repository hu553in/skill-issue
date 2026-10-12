import Foundation

struct ChatGPTFailure: Error, Sendable {
    enum Recovery: Sendable {
        case signIn, enablePlan, usage, settings, retry, restore, save, configuration, none
    }
    private enum LocalReason: Sendable {
        case signIn, signInAttempt, planConsentAttempt, planDisabled, localSignOut, tokenRemoval
        case wrongAccount, storage, credentialStorage, generic
    }

    var status: Int?
    var code: String?
    var parameter: String?
    var requestID: String?
    var responseBody: Data?
    private var localReason: LocalReason?
    private var detail: String?

    init(status: Int? = nil, body: Data? = nil, requestID: String? = nil) {
        self.status = status
        self.requestID = requestID
        responseBody = body
        if let body, let fields = try? JSONSerialization.jsonObject(with: body) as? [String: Any] {
            let response = fields["response"] as? [String: Any]
            let error =
                fields["error"] as? [String: Any] ?? response?["error"] as? [String: Any] ?? fields
            code = error["code"] as? String ?? fields["error"] as? String
            parameter = error["param"] as? String
            if let value = fields["detail"] as? String {
                let text = value.trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty { detail = String(text.prefix(1000)) }
            }
        }
    }

    private init(_ reason: LocalReason) { localReason = reason }
    static let signInRequired = Self(.signIn)
    static let planDisabled = Self(.planDisabled)
    static let remoteSignOutUnconfirmed = Self(.localSignOut)
    static let tokenRemovalFailed = Self(.tokenRemoval)
    static let wrongAccount = Self(.wrongAccount)
    static let accountStorageUnavailable = Self(.storage)
    static let credentialsNotSaved = Self(.credentialStorage)
    static let generic = Self(.generic)

    func authorizationCodeFailure(requestPlanConsent: Bool) -> Self {
        var failure = self
        failure.localReason = requestPlanConsent ? .planConsentAttempt : .signInAttempt
        return failure
    }

    var isWarning: Bool { localReason == .localSignOut || localReason == .planDisabled }

    private func display(_ value: String) -> String {
        String(value.filter { !$0.isNewline && !$0.isWhitespace }.prefix(200))
    }

    var isTerminalRefresh: Bool {
        localReason == nil
            && [
                "invalid_grant", "invalid_refresh_token", "token_expired", "refresh_token_expired",
                "refresh_token_invalidated", "refresh_token_reused",
            ].contains(code ?? "")
    }

    var recovery: Recovery {
        switch localReason {
        case .signIn, .signInAttempt: return .signIn
        case .planDisabled, .planConsentAttempt: return .enablePlan
        case .localSignOut: return .settings
        case .tokenRemoval: return .configuration
        case .wrongAccount: return .none
        case .storage: return .restore
        case .credentialStorage: return .save
        case .generic: return .retry
        case nil: break
        }
        switch code {
        case "subscription_sharing_usage_limit_exceeded": return .usage
        case "subscription_sharing_user_not_eligible": return .none
        case "subscription_sharing_usage_unavailable", "subscription_sharing_user_unavailable":
            return .retry
        case "invalid_client", "subscription_sharing_invalid_user",
            "subscription_sharing_unsupported_capability",
            "subscription_sharing_route_not_supported", "chatpass_v2_scope_not_authorized",
            "chatpass_v2_invalid_authorization_context":
            return .configuration
        default:
            if isTerminalRefresh { return .signIn }
            if let status, (400..<500).contains(status), status != 429 { return .configuration }
            return .retry
        }
    }

    var message: String {
        switch localReason {
        case .signIn: return "Your ChatGPT session has expired or was revoked. Sign in again."
        case .signInAttempt: return "Could not complete ChatGPT sign-in. Sign in again."
        case .planConsentAttempt:
            return "Could not complete the permission request. Enable ChatGPT plan usage again."
        case .planDisabled: return "ChatGPT plan usage is not enabled for Skill Issue."
        case .localSignOut:
            return
                "Signed out on this Mac. Remote access revocation could not be confirmed. In ChatGPT Settings, open Security and login > Sign in with ChatGPT > Skill Issue > Disconnect."
        case .tokenRemoval:
            return
                "Could not remove ChatGPT tokens from Keychain. Skill Issue has stopped using them. Sign in again to replace them."
        case .wrongAccount:
            return
                "This sign-in belongs to a different ChatGPT account. Use the selected account in your browser. To use another account, sign out if needed, select Another account, and choose Sign in."
        case .storage:
            return
                "Could not read saved ChatGPT accounts from Keychain. Retry to restore them before signing in."
        case .credentialStorage:
            return
                "Could not save ChatGPT credentials to Keychain. Restore Keychain access, then try again. You may need to sign in again after restarting Skill Issue."
        case .generic: return failureMessage
        case nil: break
        }
        switch code {
        case "subscription_sharing_usage_limit_exceeded":
            return
                "Skill Issue has reached a ChatGPT usage limit. Check your app and plan limits in ChatGPT Settings before choosing Request answer again."
        case "subscription_sharing_user_not_eligible":
            return
                "ChatGPT plan usage is unavailable for this account or workspace. Stop the session, sign out, and sign in with an eligible account."
        case "subscription_sharing_usage_unavailable", "subscription_sharing_user_unavailable":
            return "ChatGPT is temporarily unavailable. Try again later."
        case "subscription_sharing_unsupported_capability":
            return
                "ChatGPT does not support the requested setting\(parameter.map { ": \(display($0))" } ?? ""). Choose another model or reasoning effort, then request an answer again."
        case "invalid_client":
            return
                "The ChatGPT client registration was not accepted. Stop any active session and sign out if needed. Select Another account if available, then sign in again to register."
        case "subscription_sharing_route_not_supported":
            return
                "ChatGPT does not support this request route. Update Skill Issue or report the problem with the error details before trying again."
        case "chatpass_v2_scope_not_authorized", "chatpass_v2_invalid_authorization_context":
            return
                "ChatGPT permissions do not authorize this request. Stop the session and check Skill Issue's permissions in ChatGPT Settings. If the permissions are correct, report the problem with the error details."
        case "subscription_sharing_invalid_user":
            return
                "ChatGPT could not verify this account's authorization. Stop the session, sign out, and sign in again."
        default:
            if isTerminalRefresh { return Self.signInRequired.message }
            if status == 401 {
                return
                    "ChatGPT could not verify this account's authorization. Stop the session, sign out, and sign in again."
            }
            if status == 403 {
                return
                    "ChatGPT denied this request because of a permission or policy restriction. Check Details for the restriction. If access should be allowed, report the problem."
            }
            if status == 429 { return "ChatGPT is receiving too many requests. Try again later." }
            if let status, status >= 500 {
                return "ChatGPT is temporarily unavailable. Try again later."
            }
            if let status, (400..<500).contains(status) {
                return "ChatGPT rejected this request. Check the error details."
            }
            return failureMessage
        }
    }

    var diagnostic: String {
        [
            status.map { "HTTP \($0)" }, code.map { "Code: \(display($0))" },
            parameter.map { "Setting: \(display($0))" },
            requestID.map { "Request ID: \(display($0))" },
            detail.map { "Detail: \($0)" },
        ].compactMap { $0 }.joined(separator: "\n")
    }

    var catalogMessage: String {
        if localReason == .credentialStorage { return message }
        switch code {
        case "subscription_sharing_usage_limit_exceeded":
            return
                "Could not load ChatGPT models because Skill Issue has reached a usage limit. Check your app and plan limits in ChatGPT Settings, then choose Retry."
        case "subscription_sharing_user_not_eligible":
            return
                "ChatGPT models are unavailable for this account or workspace. Sign out and sign in with an eligible account."
        case "subscription_sharing_unsupported_capability",
            "subscription_sharing_route_not_supported":
            return
                "ChatGPT rejected the model catalog request. Update Skill Issue or report the problem with the error details."
        case "subscription_sharing_invalid_user":
            return
                "ChatGPT could not verify this account's authorization. Sign out and sign in again."
        case "invalid_client":
            return
                "The ChatGPT client registration was not accepted. Sign out if needed, select Another account if available, then sign in again to register."
        case "chatpass_v2_scope_not_authorized", "chatpass_v2_invalid_authorization_context":
            return
                "ChatGPT permissions do not allow model loading. Check Skill Issue's permissions in ChatGPT Settings. If they are correct, report the problem with the error details."
        default:
            if status == 401 && !isTerminalRefresh {
                return
                    "ChatGPT could not verify this account's authorization. Sign out and sign in again."
            }
            if recovery == .retry {
                if status == 429 {
                    return
                        "Could not load ChatGPT models. ChatGPT is receiving too many requests. Retry later."
                }
                if let status, status >= 500 {
                    return
                        "Could not load ChatGPT models. ChatGPT is temporarily unavailable. Retry later."
                }
                return "Could not load ChatGPT models. Check your connection and choose Retry."
            }
            return message
        }
    }
}
