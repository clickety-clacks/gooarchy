use crate::Linearize;

// SAFETY:
// - Storage and CopyStorage have the required type.
// - linearize and from_linear_unchecked behave as required.
unsafe impl Linearize for () {
    type Storage<T> = [T; Self::LENGTH];
    type CopyStorage<T>
        = [T; Self::LENGTH]
    where
        T: Copy;
    const LENGTH: usize = 1;

    #[inline]
    fn linearize(&self) -> usize {
        0
    }

    #[inline]
    unsafe fn from_linear_unchecked(_linear: usize) -> Self
    where
        Self: Sized,
    {
    }
}

impl_assert!((), 1);

#[test]
fn test() {
    assert_roundtrip!((), 0);
}
