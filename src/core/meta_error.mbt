///|
/// Errors raised while decoding persisted metadata (segment index / manifest).
pub(all) suberror MetaError {
  BadMagic
  BadVersion(UInt32)
  Truncated(Int32)
  BadCrc(UInt32, UInt32)
}