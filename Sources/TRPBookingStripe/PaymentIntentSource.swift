import Foundation
import TRPBookingKit

/// A Stripe PaymentIntent the customer is about to pay.
public struct StripePaymentIntent: Sendable, Hashable {
    public let id: String
    public let clientSecret: String

    public init(id: String, clientSecret: String) {
        self.id = id
        self.clientSecret = clientSecret
    }
}

/// Creates and refunds PaymentIntents. Both need Stripe's secret key, so a release build
/// implements this against the host's backend.
public protocol PaymentIntentSource: Sendable {
    func createPaymentIntent(for request: PaymentRequest) async throws -> StripePaymentIntent
    func refund(paymentIntentId: String, amount: Decimal?, currency: String, reason: String) async throws
}

#if DEBUG
/// Talks to Stripe with a test secret key from the device, so the flow can be tried before a
/// backend exists. Only compiled into debug builds and only accepts `sk_test_` keys.
public struct StripeTestModeIntentSource: PaymentIntentSource {

    public enum KeyError: Error {
        case notATestKey
    }

    private let secretKey: String
    private let session: URLSession
    private let baseURL = URL(string: "https://api.stripe.com/v1")!

    public init(secretKey: String, session: URLSession = .shared) throws {
        guard secretKey.hasPrefix("sk_test_") else { throw KeyError.notATestKey }
        self.secretKey = secretKey
        self.session = session
    }

    public func createPaymentIntent(for request: PaymentRequest) async throws -> StripePaymentIntent {
        var fields = [
            ("amount", String(request.minorUnitAmount)),
            ("currency", request.currency.lowercased()),
            ("description", request.description),
            ("automatic_payment_methods[enabled]", "true"),
            ("metadata[provider]", request.reference.provider.rawValue),
            ("metadata[reference]", request.reference.primary)
        ]
        if let email = request.customerEmail { fields.append(("receipt_email", email)) }
        let intent: IntentResponse = try await post("payment_intents", fields)
        guard let clientSecret = intent.clientSecret else { throw BookingError.paymentFailed("Stripe returned no client secret.") }
        return StripePaymentIntent(id: intent.id, clientSecret: clientSecret)
    }

    public func refund(paymentIntentId: String, amount: Decimal?, currency: String, reason: String) async throws {
        var fields = [
            ("payment_intent", paymentIntentId),
            ("reason", "requested_by_customer"),
            ("metadata[detail]", reason)
        ]
        if let amount {
            fields.append(("amount", String(PaymentRequest.minorUnits(of: amount, currency: currency))))
        }
        let _: RefundResponse = try await post("refunds", fields)
    }

    private func post<T: Decodable>(_ path: String, _ fields: [(String, String)]) async throws -> T {
        var request = URLRequest(url: baseURL.appendingPathComponent(path))
        request.httpMethod = "POST"
        request.setValue("Bearer \(secretKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(Self.formEncoded(fields).utf8)
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            let error = try? JSONDecoder().decode(ErrorResponse.self, from: data)
            throw BookingError.server(status: status, code: error?.error.code, message: error?.error.message)
        }
        return try JSONDecoder().decode(T.self, from: data)
    }

    static func formEncoded(_ fields: [(String, String)]) -> String {
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        return fields
            .map { "\($0.0.addingPercentEncoding(withAllowedCharacters: allowed) ?? $0.0)=\($0.1.addingPercentEncoding(withAllowedCharacters: allowed) ?? $0.1)" }
            .joined(separator: "&")
    }

    private struct IntentResponse: Decodable {
        let id: String
        let clientSecret: String?

        enum CodingKeys: String, CodingKey {
            case id
            case clientSecret = "client_secret"
        }
    }

    private struct RefundResponse: Decodable {
        let id: String
    }

    private struct ErrorResponse: Decodable {
        struct Detail: Decodable {
            let code: String?
            let message: String?
        }
        let error: Detail
    }
}
#endif
