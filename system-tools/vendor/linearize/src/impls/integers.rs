#![allow(unexpected_cfgs)]

use {crate::Linearize, cfg_if::cfg_if};

macro_rules! impls {
    ($unsigned:ty, $signed:ty, $test:ident) => {
        // SAFETY:
        // - Storage and CopyStorage have the required type.
        // - linearize and from_linear_unchecked behave as required.
        unsafe impl Linearize for $unsigned {
            type Storage<T> = [T; Self::LENGTH];
            type CopyStorage<T>
                = [T; Self::LENGTH]
            where
                T: Copy;
            const LENGTH: usize = <$unsigned>::MAX as usize + 1;

            #[inline]
            fn linearize(&self) -> usize {
                *self as usize
            }

            #[inline]
            unsafe fn from_linear_unchecked(linear: usize) -> Self
            where
                Self: Sized,
            {
                linear as $unsigned
            }
        }

        // SAFETY:
        // - Storage and CopyStorage have the required type.
        // - linearize and from_linear_unchecked behave as required.
        unsafe impl Linearize for $signed {
            type Storage<T> = [T; Self::LENGTH];
            type CopyStorage<T>
                = [T; Self::LENGTH]
            where
                T: Copy;
            const LENGTH: usize = <$unsigned>::MAX as usize + 1;

            #[inline]
            fn linearize(&self) -> usize {
                (*self as $unsigned).wrapping_sub(<$signed>::MIN as $unsigned) as usize
            }

            #[inline]
            unsafe fn from_linear_unchecked(linear: usize) -> Self {
                (linear as $unsigned).wrapping_add(<$signed>::MIN as $unsigned) as $signed
            }
        }

        impl_assert!($unsigned);
        impl_assert!($signed);

        #[cfg(test)]
        static_assertions::const_assert_eq! {
            <$unsigned>::LENGTH,
            <$unsigned>::MAX as usize + 1,
        }

        #[cfg(test)]
        static_assertions::const_assert_eq! {
            <$signed>::LENGTH,
            <$unsigned>::MAX as usize + 1,
        }

        #[test]
        fn $test() {
            let umin = <$unsigned>::MIN;
            let umax = <$unsigned>::MAX;
            let umid = umax / 2;
            assert_eq!(umin.linearize(), umin as usize);
            assert_eq!(umax.linearize(), umax as usize);
            assert_eq!(umid.linearize(), umid as usize);
            unsafe {
                assert_eq!(<$unsigned>::from_linear_unchecked(umin.linearize()), umin);
                assert_eq!(<$unsigned>::from_linear_unchecked(umax.linearize()), umax);
                assert_eq!(<$unsigned>::from_linear_unchecked(umid.linearize()), umid);
            }
            let imin = <$signed>::MIN;
            let imax = <$signed>::MAX;
            let imid = 0 as $signed;
            let imin_lin = imin.linearize();
            let imax_lin = imax.linearize();
            let imid_lin = imid.linearize();
            assert_eq!(imax_lin, umax as usize);
            assert_eq!(imin_lin, umin as usize);
            assert_eq!(imid_lin, umid as usize + 1);
            unsafe {
                assert_eq!(<$signed>::from_linear_unchecked(imax_lin), imax);
                assert_eq!(<$signed>::from_linear_unchecked(imin_lin), imin);
                assert_eq!(<$signed>::from_linear_unchecked(imid_lin), imid);
            }
        }
    };
}

cfg_if! {
    if #[cfg(not(target_pointer_width = "8"))] {
        impls!(u8, i8, test_u8);
        cfg_if! {
            if #[cfg(not(target_pointer_width = "16"))] {
                impls!(u16, i16, test_u16);
                cfg_if! {
                    if #[cfg(not(target_pointer_width = "32"))] {
                        impls!(u32, i32, test_u32);
                        cfg_if! {
                            if #[cfg(not(target_pointer_width = "64"))] {
                                impls!(u64, i64, test_u64);
                                cfg_if! {
                                    if #[cfg(not(target_pointer_width = "128"))] {
                                        impls!(u128, i128, test_u128);
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}
