// NOTE: This macro exists because LLVM will not properly optimize from_linear_unchecked
// implementations that use the hint directly as their terminating branch.
macro_rules! cold_unreachable {
    () => {{
        #[cold]
        unsafe fn unreachable() -> ! {
            unsafe {
                core::hint::unreachable_unchecked();
            }
        }
        unreachable()
    }};
}

macro_rules! impl_assert {
    ($ty:ty) => {
        #[cfg(test)]
        static_assertions::assert_type_eq_all! {
            <$ty as $crate::Linearize>::Storage<u8>,
            <$ty as $crate::Linearize>::CopyStorage<u8>,
            [u8; <$ty as $crate::Linearize>::LENGTH],
        }
    };
    ($ty:ty, $length:expr) => {
        impl_assert!($ty);

        #[cfg(test)]
        static_assertions::const_assert_eq! {
            <$ty as $crate::Linearize>::LENGTH,
            $length,
        }
    };
}

#[cfg(test)]
fn test_delinearize<T: crate::Linearize>(_base: &T, v: usize) -> T {
    unsafe { T::from_linear_unchecked(v) }
}

#[cfg(test)]
macro_rules! assert_roundtrip {
    ($t:expr) => {{
        let t = $t;
        let l = t.linearize();
        assert_eq!(crate::impls::test_delinearize(&t, l), t);
    }};
    ($t:expr, $l:expr) => {{
        let t = $t;
        let l = t.linearize();
        assert_eq!(l, $l);
        assert_eq!(crate::impls::test_delinearize(&t, l), t);
    }};
}

mod bool;
mod enums;
mod infallible;
mod integers;
mod phantom_data;
mod phantom_pinned;
mod unit;
