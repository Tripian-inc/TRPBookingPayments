import UIKit
import StripePaymentSheet
import TRPBookingKit

/// Charges with Stripe's PaymentSheet, for providers that leave payment to us (Toristy).
///
/// Card details stay inside Stripe's sheet; the receipt keeps only the intent id, brand and last four.
public final class StripePaymentProcessor: PaymentProcessing {

    private let publishableKey: String
    private let merchantDisplayName: String
    private let intentSource: PaymentIntentSource
    private let returnURL: String?
    private let presentingViewController: @MainActor @Sendable () -> UIViewController?

    /// - Parameters:
    ///   - returnURL: the app's url scheme callback, needed by payment methods that redirect.
    ///   - presentingViewController: the screen the sheet is presented from.
    public init(publishableKey: String,
                merchantDisplayName: String,
                intentSource: PaymentIntentSource,
                returnURL: String? = nil,
                presentingViewController: @escaping @MainActor @Sendable () -> UIViewController?) {
        self.publishableKey = publishableKey
        self.merchantDisplayName = merchantDisplayName
        self.intentSource = intentSource
        self.returnURL = returnURL
        self.presentingViewController = presentingViewController
    }

    public func charge(_ request: PaymentRequest) async throws -> PaymentReceipt {
        let intent = try await intentSource.createPaymentIntent(for: request)
        try await present(intent, for: request)
        let card = await cardDetails(of: intent)
        return PaymentReceipt(chargeId: intent.id, amount: request.amount, currency: request.currency,
                              cardBrand: card?.brand, last4: card?.last4)
    }

    public func refund(_ receipt: PaymentReceipt, reason: String) async throws {
        try await intentSource.refund(paymentIntentId: receipt.chargeId, amount: receipt.amount, currency: receipt.currency, reason: reason)
    }

    @MainActor
    private func present(_ intent: StripePaymentIntent, for request: PaymentRequest) async throws {
        guard let presenter = presentingViewController() else {
            throw BookingError.paymentFailed("There is no screen to show the payment sheet on.")
        }
        var configuration = PaymentSheet.Configuration()
        configuration.apiClient = STPAPIClient(publishableKey: publishableKey)
        configuration.merchantDisplayName = merchantDisplayName
        configuration.defaultBillingDetails.email = request.customerEmail
        configuration.returnURL = returnURL
        let sheet = PaymentSheet(paymentIntentClientSecret: intent.clientSecret, configuration: configuration)
        let outcome: SheetOutcome = await withCheckedContinuation { continuation in
            sheet.present(from: presenter) { result in
                switch result {
                case .completed: continuation.resume(returning: .completed)
                case .canceled: continuation.resume(returning: .cancelled)
                case .failed(let error): continuation.resume(returning: .failed(error.localizedDescription))
                }
            }
        }
        switch outcome {
        case .completed: return
        case .cancelled: throw BookingError.paymentCancelled
        case .failed(let message): throw BookingError.paymentFailed(message)
        }
    }

    @MainActor
    private func cardDetails(of intent: StripePaymentIntent) async -> (brand: String, last4: String?)? {
        let client = STPAPIClient(publishableKey: publishableKey)
        return await withCheckedContinuation { continuation in
            client.retrievePaymentIntent(withClientSecret: intent.clientSecret, expand: ["payment_method"]) { paymentIntent, _ in
                guard let card = paymentIntent?.paymentMethod?.card else { return continuation.resume(returning: nil) }
                continuation.resume(returning: (STPCardBrandUtilities.stringFrom(card.brand) ?? "card", card.last4))
            }
        }
    }

    private enum SheetOutcome: Sendable {
        case completed
        case cancelled
        case failed(String)
    }
}
