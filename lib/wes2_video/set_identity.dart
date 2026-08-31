/// Stable identity for a WES2 set.
///
/// Kept in its own library so the model layer stays free of package imports and
/// so tests can substitute a deterministic generator.
library;

import 'package:uuid/uuid.dart';

const Uuid _uuid = Uuid();

/// Mints a fresh, collision-resistant set identity.
///
/// Plain RFC 4122 v4 with no prefix: the value travels straight through to the
/// showcase reducers' `setKey`, which compare and sort it as an opaque trimmed
/// string on both platforms, so anything decorative here would only end up
/// baked into record fingerprints for good.
String newWes2SetId() => _uuid.v4();
