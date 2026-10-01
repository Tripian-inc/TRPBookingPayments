import Foundation
import StripePaymentSheet
import TRPBookingKit

/// Stripe for the booking contract's local checkout: creates the PaymentIntent the device confirms in the
/// `stripe_payment_intent` action, then charges by reading that confirmed intent back instead of taking money again.
///
/// Pass the same instance as `TRPBooking`'s `toristyPayment` and as the local checkout's `stripe`. Intents are held in
/// memory, keyed by their payment request, only until they are charged.
public final class StripeIntentPayments: StripePaymentIntentProviding, @unchecked Sendable {

    private let publishableKey: String
    private let merchantDisplayName: String
    private let intentSource: PaymentIntentSource
    private let lock = NSLock()
    private var intents: [PaymentRequest: StripePaymentIntent] = [:]

    public init(publishableKey: String, merchantDisplayName: String, intentSource: PaymentIntentSource) {
        self.publishableKey = publishableKey
        self.merchantDisplayName = merchantDisplayName
        self.intentSource = intentSource
    }

    public func paymentIntent(for request: PaymentRequest) async throws -> TRPBookingKit.StripePaymentIntent {
        let intent = try await intentSource.createPaymentIntent(for: request)
        remember(intent, for: request)
        return TRPBookingKit.StripePaymentIntent(id: intent.id, clientSecret: intent.clientSecret,
                                                 publishableKey: publishableKey, merchantName: merchantDisplayName)
    }

    /// Throws `BookingError.paymentFailed` when no intent was created for `request` or Stripe has not taken the money.
    public func charge(_ request: PaymentRequest) async throws -> PaymentReceipt {
        guard let intent = take(for: request) else {
            throw BookingError.paymentFailed("No payment was confirmed for this booking.")
        }
        let confirmed = await retrieve(intent)
        guard let confirmed, [.succeeded, .requiresCapture].contains(confirmed.status) else {
            throw BookingError.paymentFailed("The payment was not completed.")
        }
        return PaymentReceipt(chargeId: intent.id, amount: request.amount, currency: request.currency,
                              cardBrand: confirmed.cardBrand, last4: confirmed.last4)
    }

    public func refund(_ receipt: PaymentReceipt, reason: String) async throws {
        try await intentSource.refund(paymentIntentId: receipt.chargeId, amount: receipt.amount, currency: receipt.currency, reason: reason)
    }

    private func remember(_ intent: StripePaymentIntent, for request: PaymentRequest) {
        lock.lock()
        defer { lock.unlock() }
        intents[request] = intent
    }

    private func take(for request: PaymentRequest) -> StripePaymentIntent? {
        lock.lock()
        defer { lock.unlock() }
        return intents.removeValue(forKey: request)
    }

    @MainActor
    private func retrieve(_ intent: StripePaymentIntent) async -> ConfirmedIntent? {
        let client = STPAPIClient(publishableKey: publishableKey)
        return await withCheckedContinuation { continuation in
            client.retrievePaymentIntent(withClientSecret: intent.clientSecret, expand: ["payment_method"]) { paymentIntent, _ in
                guard let paymentIntent else { return continuation.resume(returning: nil) }
                let card = paymentIntent.paymentMethod?.card
                continuation.resume(returning: ConfirmedIntent(status: paymentIntent.status,
                                                               cardBrand: card.map { STPCardBrandUtilities.stringFrom($0.brand) ?? "card" },
                                                               last4: card?.last4))
            }
        }
    }

    private struct ConfirmedIntent: @unchecked Sendable {
        let status: STPPaymentIntentStatus
        let cardBrand: String?
        let last4: String?
    }
}
