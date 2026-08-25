// Billing-compliance coverage for the GoodLift membership purchase flow.
//
// These tests pin the LOGICAL handling of every purchase status across the
// Google Play Billing Library 7 -> 8 upgrade (in_app_purchase 3.2.3 -> 3.3.0,
// in_app_purchase_android 0.4.0+10 -> 0.5.0). They deliberately do NOT fake a
// real Google Play or StoreKit transaction — they exercise the pure policy the
// widget delegates to, so the monetisation rules stay verifiable without a
// store connection.

import 'package:flutter_test/flutter_test.dart';
import 'package:in_app_purchase/in_app_purchase.dart';
import 'package:localtest222/membership_purchase_policy.dart';

/// The GoodLift membership products, mirroring MembershipGate.
const _iosProductId = 'goodlift.membership.monthly';
const _androidProductId = 'goodlift_monthly';
const _membershipProductIds = {_iosProductId, _androidProductId};

PurchaseDetails _purchase({
  required PurchaseStatus status,
  String productId = _androidProductId,
  bool pendingCompletePurchase = false,
}) {
  final details = PurchaseDetails(
    purchaseID: 'purchase-1',
    productID: productId,
    verificationData: PurchaseVerificationData(
      localVerificationData: 'local',
      serverVerificationData: 'server',
      source: 'google_play',
    ),
    transactionDate: '1755000000000',
    status: status,
  );
  details.pendingCompletePurchase = pendingCompletePurchase;
  return details;
}

void main() {
  group('purchased', () {
    test('grants access and confirms to the user', () {
      final d = decideMembershipPurchase(PurchaseStatus.purchased);
      expect(d.outcome, MembershipPurchaseOutcome.activate);
      expect(d.grantsAccess, isTrue);
      expect(d.releasesLoading, isTrue);
      expect(d.userMessage, 'Membership activated.');
    });
  });

  group('restored', () {
    test('grants access exactly like a fresh purchase', () {
      final restored = decideMembershipPurchase(PurchaseStatus.restored);
      final purchased = decideMembershipPurchase(PurchaseStatus.purchased);
      expect(restored.outcome, MembershipPurchaseOutcome.activate);
      expect(restored.grantsAccess, isTrue);
      expect(restored.userMessage, purchased.userMessage);
    });

    test('restore/recovery is therefore preserved', () {
      // The restore button funnels PurchaseStatus.restored through the same
      // path; if this ever stopped granting access, recovery would break.
      expect(
        decideMembershipPurchase(PurchaseStatus.restored).grantsAccess,
        isTrue,
      );
    });
  });

  group('pending', () {
    test('stays pending and must NOT grant access', () {
      final d = decideMembershipPurchase(PurchaseStatus.pending);
      expect(d.outcome, MembershipPurchaseOutcome.awaitPayment);
      expect(d.grantsAccess, isFalse,
          reason: 'a parked cash/voucher payment must never unlock the app');
      expect(d.userMessage, 'Waiting for payment confirmation…');
    });

    test('still releases the CTA so it is never permanently disabled', () {
      // Play can park a purchase for days; the button must not stay stuck.
      expect(
        decideMembershipPurchase(PurchaseStatus.pending).releasesLoading,
        isTrue,
      );
    });
  });

  group('error', () {
    test('does not grant access and reports failure', () {
      final d = decideMembershipPurchase(PurchaseStatus.error);
      expect(d.outcome, MembershipPurchaseOutcome.failed);
      expect(d.grantsAccess, isFalse);
      expect(d.releasesLoading, isTrue);
      expect(d.userMessage, 'Purchase failed. Please try again.');
    });
  });

  group('cancelled', () {
    test('does not grant access', () {
      final d = decideMembershipPurchase(PurchaseStatus.canceled);
      expect(d.outcome, MembershipPurchaseOutcome.cancelled);
      expect(d.grantsAccess, isFalse,
          reason: 'backing out of the store sheet must never unlock the app');
      expect(d.releasesLoading, isTrue);
      expect(d.userMessage, 'Purchase cancelled.');
    });
  });

  group('access is granted for exactly two statuses', () {
    test('purchased and restored only', () {
      final granting = PurchaseStatus.values
          .where((s) => decideMembershipPurchase(s).grantsAccess)
          .toSet();
      expect(granting, {PurchaseStatus.purchased, PurchaseStatus.restored});
    });

    test('every status is handled and always releases the CTA', () {
      for (final s in PurchaseStatus.values) {
        final d = decideMembershipPurchase(s);
        expect(d.releasesLoading, isTrue, reason: 'status $s');
        expect(d.userMessage, isNotNull, reason: 'status $s');
      }
    });
  });

  group('completePurchase / acknowledgement', () {
    test('is required when pendingCompletePurchase is true', () {
      expect(
        shouldCompletePurchase(_purchase(
          status: PurchaseStatus.purchased,
          pendingCompletePurchase: true,
        )),
        isTrue,
      );
    });

    test('is skipped when the store does not need it', () {
      expect(
        shouldCompletePurchase(_purchase(
          status: PurchaseStatus.purchased,
          pendingCompletePurchase: false,
        )),
        isFalse,
      );
    });

    test('depends only on the purchase, never on our own write succeeding', () {
      // Play and StoreKit auto-refund an unacknowledged purchase, so this must
      // hold regardless of anything else that happened in the handler.
      for (final status in PurchaseStatus.values) {
        expect(
          shouldCompletePurchase(
              _purchase(status: status, pendingCompletePurchase: true)),
          isTrue,
          reason: 'status $status must still be completable',
        );
      }
    });

    test('a restored purchase awaiting acknowledgement is completed', () {
      expect(
        shouldCompletePurchase(_purchase(
          status: PurchaseStatus.restored,
          pendingCompletePurchase: true,
        )),
        isTrue,
      );
    });
  });

  group('product filtering', () {
    test('both GoodLift membership SKUs are acted on', () {
      expect(isMembershipProduct(_androidProductId, _membershipProductIds),
          isTrue);
      expect(isMembershipProduct(_iosProductId, _membershipProductIds), isTrue);
    });

    test('unrelated products are ignored', () {
      expect(isMembershipProduct('some_other_sku', _membershipProductIds),
          isFalse);
      expect(isMembershipProduct('', _membershipProductIds), isFalse);
    });
  });
}
