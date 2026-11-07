import Core
import Foundation

/// Issue references (`#123`, `ENG-123`) as branch names (`123-fix-login`, `eng-123-fix-login`).
public enum IssueRef {
    public static func branchName(_ ref: String, title: String) -> String {
        let words = title.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil).lowercased()
            .split { !($0.isASCII && ($0.isLetter || $0.isNumber)) }.prefix(6)
        return ([ref.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "#"))] + words.map(String.init))
            .joined(separator: "-")
    }
}

/// What Jira, Linear and Bitbucket say went wrong.
public struct IntegrationError: Error, CustomStringConvertible, Sendable { public var description: String }

/// Jira's and Bitbucket's REST calls: Basic auth (`login` is "user:token"), a JSON body, a 2xx answer (else
/// "<service> <code>: <start of the reply>").
func basicAuthRequest(_ service: String, _ method: String, _ url: URL, login: String, body: [String: Any]?) async throws
    -> Data
{
    var request = URLRequest(url: url)
    request.httpMethod = method
    request.setValue("Basic " + Data(login.utf8).base64EncodedString(), forHTTPHeaderField: "Authorization")
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    if let body {
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    }
    let (data, resp) = try await URLSession.shared.data(for: request)
    let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
    guard (200..<300).contains(code) else {
        throw IntegrationError(description: "\(service) \(code): \(String(decoding: data.prefix(300), as: UTF8.self))")
    }
    return data
}
