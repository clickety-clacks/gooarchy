use {
    crate::{Linearize, StaticCopyMap, StaticMap},
    bytemuck_1::{AnyBitPattern, NoUninit, TransparentWrapper, Zeroable},
};

unsafe impl<L, T> Zeroable for StaticCopyMap<L, T>
where
    L: Linearize + ?Sized,
    T: Copy + Zeroable,
{
}

unsafe impl<L, T> NoUninit for StaticCopyMap<L, T>
where
    L: Linearize + ?Sized + 'static,
    T: Copy + NoUninit,
{
}

unsafe impl<L, T> AnyBitPattern for StaticCopyMap<L, T>
where
    L: Linearize + ?Sized + 'static,
    T: Copy + AnyBitPattern,
{
}

unsafe impl<L, T> TransparentWrapper<L::CopyStorage<T>> for StaticCopyMap<L, T>
where
    L: Linearize + ?Sized,
    T: Copy,
{
}

unsafe impl<L, T> TransparentWrapper<L::Storage<T>> for StaticMap<L, T> where L: Linearize + ?Sized {}
