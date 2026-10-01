import UIKit
import StripePaymentSheet

/// Confirms a PaymentIntent the server created, in Stripe's PaymentSheet: the sheet behind the booking contract's
/// `stripe_payment_intent` action. Card details never leave Stripe's sheet.
@MainActor
public final class StripePaymentSheetPresenter {

    private let returnURL: String?

    /// - Parameter returnURL: the app's url scheme callback, needed by payment methods that redirect.
    public init(returnURL: String? = nil) {
        self.returnURL = returnURL
    }

    /// True when the payment succeeded, false when the customer closed the sheet; throws when Stripe declined it.
    public func confirm(clientSecret: String, publishableKey: String, merchantName: String,
                        from presenter: UIViewController) async throws -> Bool {
        var configuration = PaymentSheet.Configuration()
        configuration.apiClient = STPAPIClient(publishableKey: publishableKey)
        configuration.merchantDisplayName = merchantName
        configuration.returnURL = returnURL
        let sheet = PaymentSheet(paymentIntentClientSecret: clientSecret, configuration: configuration)
        return try await withCheckedThrowingContinuation { continuation in
            sheet.present(from: presenter) { result in
                switch result {
                case .completed: continuation.resume(returning: true)
                case .canceled: continuation.resume(returning: false)
                case .failed(let error): continuation.resume(throwing: error)
                }
            }
        }
    }
}
