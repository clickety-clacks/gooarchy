use {crate::Linearize, core::convert::Infallible};

// SAFETY:
// - Storage and CopyStorage have the required type.
// - linearize and from_linear_unchecked behave as required.
unsafe impl Linearize for Infallible {
    type Storage<T> = [T; Self::LENGTH];
    type CopyStorage<T>
        = [T; Self::LENGTH]
    where
        T: Copy;
    const LENGTH: usize = 0;

    #[inline]
    fn linearize(&self) -> usize {
        unsafe {
            // SAFETY: Infallible is uninhabited.
            cold_unreachable!();
        }
    }

    #[inline]
    unsafe fn from_linear_unchecked(_linear: usize) -> Self
    where
        Self: Sized,
    {
        unsafe {
            // SAFETY: It's a precondition that _linear < Self::LENGTH = 0.
            cold_unreachable!();
        }
    }
}

impl_assert!(Infallible, 0);
