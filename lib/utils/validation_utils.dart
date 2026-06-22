/// Clamps a user-supplied PIM value to a safe range.
///
/// The native PBKDF2 iteration formula is:
///   iter = (pim > 0) ? (15_000 + pim * 1_000) : 500_000
///
/// An unclamped pim of, say, 2_000_000 would produce ~2_000_015_000
/// iterations — effectively a denial-of-service against the user's own
/// device. Capping at 2_000 gives a generous maximum of ~2_015_000
/// iterations, which is still far above VeraCrypt's own recommended range.
int clampPim(int value) {
  if (value < 0) return 0;
  if (value > 2000) return 2000;
  return value;
}