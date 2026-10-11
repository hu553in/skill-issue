struct ChatGPTModel: Identifiable, Sendable {
    let slug: String
    let displayName: String
    let efforts: [String]
    var id: String { slug }
    var defaultEffort: String { efforts.contains("low") ? "low" : efforts.first ?? "" }

    init(fields: [String: Any]) throws {
        guard let slug = fields["slug"] as? String, !slug.isEmpty,
            let name = fields["display_name"] as? String, !name.isEmpty
        else { throw AppFailure.failed }
        self.slug = slug
        displayName = name
        var efforts: [String] = []
        if let levels = fields["supported_reasoning_levels"] {
            guard let levels = levels as? [[String: Any]] else { throw AppFailure.failed }
            for level in levels {
                guard let effort = level["effort"] as? String else { throw AppFailure.failed }
                // Direct Responses values only: ultra requires agent delegation.
                if ["none", "minimal", "low", "medium", "high", "xhigh", "max"].contains(effort),
                    !efforts.contains(effort)
                {
                    efforts.append(effort)
                }
            }
        }
        self.efforts = efforts
    }
}
