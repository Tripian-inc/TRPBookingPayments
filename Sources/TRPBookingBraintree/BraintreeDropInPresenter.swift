import UIKit
import BraintreeDropIn
import TRPBookingKit

extension BraintreeTokenizationKey: BraintreeClientTokenProviding {
    /// The tokenization key, which Drop-in accepts wherever it takes a client token.
    public func clientToken() async throws -> String {
        try await authorization()
    }
}

/// Collects a card in Braintree's Drop-in and answers with a single-use nonce and the device data: the sheet behind
/// the booking contract's `braintree_dropin` action. Neither value is stored.
@MainActor
public final class BraintreeDropInPresenter {

    private let requiresThreeDSecure: Bool

    /// - Parameter requiresThreeDSecure: runs a 3-D Secure check for the amount before the nonce is returned.
    public init(requiresThreeDSecure: Bool = false) {
        self.requiresThreeDSecure = requiresThreeDSecure
    }

    /// The nonce and device data, or nil when the customer closed the sheet; throws when Drop-in failed.
    /// - Parameters:
    ///   - amount: the amount to verify with 3-D Secure, when it is required.
    ///   - currency: ISO 4217 code of `amount`.
    public func collect(clientToken: String, amount: Decimal?, currency: String?,
                        from presenter: UIViewController) async throws -> (nonce: String, deviceData: String)? {
        let request = BTDropInRequest()
        request.vaultManager = false
        request.paypalDisabled = true
        request.venmoDisabled = true
        request.applePayDisabled = true
        request.cardholderNameSetting = .required
        if requiresThreeDSecure, let amount {
            let threeDSecure = BTThreeDSecureRequest()
            threeDSecure.amount = NSDecimalNumber(decimal: amount)
            threeDSecure.versionRequested = .version2
            request.threeDSecureRequest = threeDSecure
        }
        return try await withCheckedThrowingContinuation { continuation in
            let controller = BTDropInController(authorization: clientToken, request: request) { controller, result, error in
                controller.dismiss(animated: true)
                if let error {
                    continuation.resume(throwing: error)
                } else if let nonce = result?.paymentMethod?.nonce, result?.isCanceled == false {
                    continuation.resume(returning: (nonce, result?.deviceData ?? ""))
                } else {
                    continuation.resume(returning: nil)
                }
            }
            guard let controller else {
                return continuation.resume(throwing: BookingError.paymentFailed("The Braintree authorization was not accepted."))
            }
            presenter.present(controller, animated: true)
        }
    }
}
