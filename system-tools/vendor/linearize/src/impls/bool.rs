use crate::Linearize;

// SAFETY:
// - Storage and CopyStorage have the required type.
// - linearize and from_linear_unchecked behave as required.
unsafe impl Linearize for bool {
    type Storage<T> = [T; Self::LENGTH];
    type CopyStorage<T>
        = [T; Self::LENGTH]
    where
        T: Copy;
    const LENGTH: usize = 2;

    #[inline]
    fn linearize(&self) -> usize {
        *self as usize
    }

    #[inline]
    unsafe fn from_linear_unchecked(linear: usize) -> Self
    where
        Self: Sized,
    {
        linear != 0
    }
}

impl_assert!(bool, 2);

#[test]
fn test() {
    assert_roundtrip!(false, 0);
    assert_roundtrip!(true, 1);
}
