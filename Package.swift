// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "TRPBookingPayments",
    platforms: [
        .iOS(.v15)
    ],
    products: [
        .library(name: "TRPBookingStripe", targets: ["TRPBookingStripe"]),
        .library(name: "TRPBookingBraintree", targets: ["TRPBookingBraintree"])
    ],
    dependencies: [
        .package(path: "../TRPBookingKit"),
        .package(url: "https://github.com/stripe/stripe-ios-spm", from: "26.0.0"),
        .package(url: "https://github.com/braintree/braintree-ios-drop-in", from: "9.9.0")
    ],
    targets: [
        .target(
            name: "TRPBookingStripe",
            dependencies: [
                "TRPBookingKit",
                .product(name: "StripePaymentSheet", package: "stripe-ios-spm")
            ]
        ),
        .target(
            name: "TRPBookingBraintree",
            dependencies: [
                "TRPBookingKit",
                .product(name: "BraintreeDropIn", package: "braintree-ios-drop-in")
            ]
        )
    ]
)
