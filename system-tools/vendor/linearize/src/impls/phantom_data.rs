use {crate::Linearize, core::marker::PhantomData};

unsafe impl<X> Linearize for PhantomData<X>
where
    X: ?Sized,
{
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
        PhantomData
    }
}

impl_assert!(PhantomData<u8>, 1);

#[test]
fn test() {
    assert_roundtrip!(PhantomData::<u8>, 0);
}
