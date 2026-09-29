import UIKit
import BraintreeDropIn
import TRPBookingKit

/// Where Drop-in's authorization comes from: a client token from the host's backend, or a
/// tokenization key from the host's config.
public protocol BraintreeAuthorizationSource: Sendable {
    func authorization() async throws -> String
}

/// A tokenization key read from the host's config; it can tokenize cards but not vault them.
public struct BraintreeTokenizationKey: BraintreeAuthorizationSource {
    private let key: String

    public init(_ key: String) {
        self.key = key
    }

    public func authorization() async throws -> String { key }
}

/// Collects a card in Braintree's native Drop-in and answers with a single-use nonce, for
/// Victory, where Ticket Evolution charges the card. The nonce is never stored.
public final class BraintreeDropInNonceProvider: PaymentNonceProviding {

    private let authorizationSource: BraintreeAuthorizationSource
    private let requiresThreeDSecure: Bool
    private let presentingViewController: @MainActor @Sendable () -> UIViewController?

    /// - Parameter requiresThreeDSecure: runs a 3-D Secure check for the amount before the nonce is returned.
    public init(authorization: BraintreeAuthorizationSource,
                requiresThreeDSecure: Bool = false,
                presentingViewController: @escaping @MainActor @Sendable () -> UIViewController?) {
        authorizationSource = authorization
        self.requiresThreeDSecure = requiresThreeDSecure
        self.presentingViewController = presentingViewController
    }

    public func nonce(amount: Decimal, currency: String) async throws -> String {
        let authorization = try await authorizationSource.authorization()
        let outcome = try await present(authorization: authorization, amount: amount)
        switch outcome {
        case .nonce(let nonce): return nonce
        case .cancelled: throw BookingError.paymentCancelled
        case .failed(let message): throw BookingError.paymentFailed(message)
        }
    }

    @MainActor
    private func present(authorization: String, amount: Decimal) async throws -> DropInOutcome {
        guard let presenter = presentingViewController() else {
            throw BookingError.paymentFailed("There is no screen to show the card form on.")
        }
        let request = BTDropInRequest()
        request.vaultManager = false
        request.paypalDisabled = true
        request.venmoDisabled = true
        request.applePayDisabled = true
        request.cardholderNameSetting = .required
        if requiresThreeDSecure {
            let threeDSecure = BTThreeDSecureRequest()
            threeDSecure.amount = NSDecimalNumber(decimal: amount)
            threeDSecure.versionRequested = .version2
            request.threeDSecureRequest = threeDSecure
        }
        return try await withCheckedThrowingContinuation { continuation in
            let controller = BTDropInController(authorization: authorization, request: request) { controller, result, error in
                controller.dismiss(animated: true)
                if let error {
                    continuation.resume(returning: .failed(error.localizedDescription))
                } else if let nonce = result?.paymentMethod?.nonce, result?.isCanceled == false {
                    continuation.resume(returning: .nonce(nonce))
                } else {
                    continuation.resume(returning: .cancelled)
                }
            }
            guard let controller else {
                return continuation.resume(throwing: BookingError.paymentFailed("The Braintree authorization was not accepted."))
            }
            presenter.present(controller, animated: true)
        }
    }

    private enum DropInOutcome: Sendable {
        case nonce(String)
        case cancelled
        case failed(String)
    }
}
