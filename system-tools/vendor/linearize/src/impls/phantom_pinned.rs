use {crate::Linearize, core::marker::PhantomPinned};

unsafe impl Linearize for PhantomPinned {
    type Storage<T> = [T; 1];
    type CopyStorage<T>
        = [T; 1]
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
        PhantomPinned
    }
}

impl_assert!(PhantomPinned, 1);

#[test]
fn test() {
    assert_roundtrip!(PhantomPinned, 0);
}
