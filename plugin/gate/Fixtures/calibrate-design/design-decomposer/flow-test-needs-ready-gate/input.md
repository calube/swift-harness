This run gives you no tools. Your context pack is inline below, and it holds everything you
would otherwise read from disk.

Prompt: plan slug `checkout-receipt`, repo `shopapp`.

# Decomposer pack

## Requirements

- req-receipt-shows-after-purchase: after a purchase completes, the receipt screen shows the order total.

## Module kinds

| Module | Kind | Reason |
|---|---|---|
| ReceiptFeature | feature | reducer and view for the receipt screen |

## Test plan by tier

- test-purchase-flow-ends-on-receipt: a purchase from cart to receipt screen shows the total — tier T3

## Module graph

- ReceiptFeature: `Packages/Checkout/Sources/ReceiptFeature/`, tests `Packages/Checkout/Tests/ReceiptFeatureTests/`; depends on OrdersClient.

## Bounds

est_lines_max 400, est_lines_min 40, max_modules_per_task 2, max_tests_per_task 6, worker_pack_token_budget 15000.
