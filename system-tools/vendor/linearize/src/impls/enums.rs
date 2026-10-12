macro_rules! impl_enum {
    ($ty:ty, $num:literal: $($name:ident => $idx:expr,)*) => {
        // SAFETY: The tests below test all conditions.
        unsafe impl crate::Linearize for $ty {
            type Storage<T> = [T; Self::LENGTH];
            type CopyStorage<T>
                = [T; Self::LENGTH]
            where
                T: Copy;
            const LENGTH: usize = $num;

            #[inline]
            fn linearize(&self) -> usize {
                match self {
                    $(<$ty>::$name => $idx,)*
                }
            }

            #[inline]
            unsafe fn from_linear_unchecked(linear: usize) -> Self
            where
                Self: Sized,
            {
                match linear {
                    $($idx => <$ty>::$name,)*
                    _ => unsafe {
                        // SAFETY: It's a precondition that linear < Self::LENGTH,
                        cold_unreachable!();
                    },
                }
            }
        }

        impl_assert!($ty, $num);

        #[test]
        fn test() {
            use crate::Linearize;
            $(
                assert_roundtrip!(<$ty>::$name, $idx);
            )*
            let variants = [$(<$ty>::$name),*];
            assert_eq!(variants.len(), $num);
            for (idx, variant) in variants.into_iter().enumerate() {
                assert_eq!(variant.linearize(), idx);
            }
        }
    };
}

mod core {
    mod cmp {
        mod ordering {
            impl_enum! {
                core::cmp::Ordering, 3:
                Less => 0,
                Equal => 1,
                Greater => 2,
            }
        }
    }

    mod fmt {
        mod alignment {
            impl_enum! {
                core::fmt::Alignment, 3:
                Left => 0,
                Right => 1,
                Center => 2,
            }
        }
    }

    mod num {
        mod fp_category {
            impl_enum! {
                core::num::FpCategory, 5:
                Nan => 0,
                Infinite => 1,
                Zero => 2,
                Subnormal => 3,
                Normal => 4,
            }
        }
    }
}

#[cfg(feature = "std")]
mod std {
    mod net {
        mod shutdown {
            impl_enum! {
                std::net::Shutdown, 3:
                Read => 0,
                Write => 1,
                Both => 2,
            }
        }
    }
}
