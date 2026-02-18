import Lake
open Lake DSL

package mpfsCage where
  leanOptions := #[
    ⟨`autoImplicit, false⟩
  ]

@[default_target]
lean_lib MpfsCage where
  roots := #[`MpfsCage.Phases]
