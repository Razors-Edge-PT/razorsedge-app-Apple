/// Pure, plugin-free decision layer for GoodLift membership purchase updates.
///
/// `MembershipGate._onPurchaseUpdate` talks directly to the store plugin and to
/// Firestore, which makes the surrounding widget impractical to unit-test. The
/// *decisions* it makes, however, are pure: given a [PurchaseStatus] and
/// whether the store still needs the purchase completed, what should the app
/// do? Those decisions live here so they can be tested without faking a real
/// Google Play or StoreKit transaction.
///
/// This file deliberately contains no store calls, no Firestore calls and no
/// UI — only the policy. Behaviour is unchanged from the original inline
/// branching; it has simply been made addressable.
library;

import 'package:in_app_purchase/in_app_purchase.dart';

/// What the app must do about a single purchase update.
enum MembershipPurchaseOutcome {
  /// The purchase is good: activate membership for this account.
  activate,

  /// Play/StoreKit has parked the purchase (e.g. cash or voucher payment).
  /// Access must NOT be granted, but the CTA must be released so it is never
  /// permanently disabled while the payment settles.
  awaitPayment,

  /// The purchase failed.
  failed,

  /// The user backed out of the store sheet.
  cancelled,
}

/// The full resolution of one purchase update.
class MembershipPurchaseDecision {
  const MembershipPurchaseDecision({
    required this.outcome,
    required this.grantsAccess,
    required this.releasesLoading,
    this.userMessage,
  });

  final MembershipPurchaseOutcome outcome;

  /// Whether membership should be marked active. ONLY true for a completed or
  /// restored purchase — never for pending, failed or cancelled.
  final bool grantsAccess;

  /// Whether the purchase CTA should stop showing its busy state.
  final bool releasesLoading;

  /// Message to surface to the user, or null when nothing should be shown.
  final String? userMessage;
}

/// Resolves what to do about a purchase update with [status].
///
/// Note that `purchased` and `restored` are treated identically: both mean the
/// user is entitled, which is what keeps restore/recovery working.
MembershipPurchaseDecision decideMembershipPurchase(PurchaseStatus status) {
  switch (status) {
    case PurchaseStatus.purchased:
    case PurchaseStatus.restored:
      return const MembershipPurchaseDecision(
        outcome: MembershipPurchaseOutcome.activate,
        grantsAccess: true,
        releasesLoading: true,
        userMessage: 'Membership activated.',
      );
    case PurchaseStatus.pending:
      return const MembershipPurchaseDecision(
        outcome: MembershipPurchaseOutcome.awaitPayment,
        grantsAccess: false,
        releasesLoading: true,
        userMessage: 'Waiting for payment confirmation…',
      );
    case PurchaseStatus.error:
      return const MembershipPurchaseDecision(
        outcome: MembershipPurchaseOutcome.failed,
        grantsAccess: false,
        releasesLoading: true,
        userMessage: 'Purchase failed. Please try again.',
      );
    case PurchaseStatus.canceled:
      return const MembershipPurchaseDecision(
        outcome: MembershipPurchaseOutcome.cancelled,
        grantsAccess: false,
        releasesLoading: true,
        userMessage: 'Purchase cancelled.',
      );
  }
}

/// Whether the store still needs this purchase acknowledged/completed.
///
/// Both StoreKit and Google Play Billing auto-refund a purchase that is never
/// completed, so this must be honoured even when our own membership write
/// failed — hence it is a function of the purchase alone, never of whether
/// anything else succeeded.
bool shouldCompletePurchase(PurchaseDetails purchase) =>
    purchase.pendingCompletePurchase;

/// Whether [productId] is one of the GoodLift membership products this app
/// acts on. Unrelated products (past SKUs, other stores' test SKUs) are
/// ignored entirely.
bool isMembershipProduct(String productId, Set<String> membershipProductIds) =>
    membershipProductIds.contains(productId);
