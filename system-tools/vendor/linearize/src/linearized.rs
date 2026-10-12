use {
    crate::Linearize,
    core::{
        cmp::Ordering,
        fmt::{Debug, Formatter},
        hash::{Hash, Hasher},
        marker::PhantomData,
    },
};

/// Pre-computed output of [Linearize::linearize].
///
/// [StaticMap] and [StaticCopyMap] can be index directly with a [Linearize] type.
/// That operation computes the output of [linearize] ad-hoc. While the linearize function
/// is zero cost for many types, you might be using types for which the cost is non-zero
/// or unknown.
///
/// In such situations, the `Linearized` type allows you to cache the output of
/// [linearize].
///
/// It is guaranteed that the value cached by this type is the output of the linearize
/// function. In particular, the value is less than [LENGTH].
///
/// # Example
///
/// ```rust
/// # use linearize::{Linearize, LinearizeExt, StaticMap};
/// fn add_one<L: Linearize>(map: &mut StaticMap<L, u8>, key: L) {
///     let key = key.linearized();
///     let v = map[key];
///     map[key] = v + 1;
/// }
/// ```
///
/// # Trait Implementations
///
/// This type implements traits such as [Debug], [Hash], etc. These implementations
/// operate on the pre-computed `usize`. In particular, the [Debug] implementation does
/// not print the name of the original value used to create this object.
///
/// [StaticMap]: crate::StaticMap
/// [StaticCopyMap]: crate::StaticCopyMap
/// [linearize]: Linearize::linearize
/// [LENGTH]: Linearize::LENGTH
#[repr(transparent)]
pub struct Linearized<L>
where
    L: ?Sized,
{
    index: usize,
    _phantom: PhantomData<L>,
}

impl<L> Linearized<L>
where
    L: ?Sized,
{
    /// Pre-computes the linearized value.
    ///
    /// This function pre-computes the output of [linearize](Linearize::linearize).
    ///
    /// The [LinearizeExt](crate::LinearizeExt) extension trait provides the
    /// [linearized](crate::LinearizeExt::linearized) function which does the same.
    ///
    /// # Example
    ///
    /// ```rust
    /// # use linearize::{Linearize, LinearizeExt, Linearized, StaticMap};
    /// fn get_value<L: Linearize>(map: &StaticMap<L, u8>, key: L) -> u8 {
    ///     map[Linearized::new(&key)]
    ///     // Or: map[key.linearized()]
    /// }
    /// ```
    pub fn new(l: &L) -> Self
    where
        L: Linearize,
    {
        unsafe {
            // SAFETY: l.linearize() guarantees that it is less than L::LENGTH.
            Self::new_unchecked(l.linearize())
        }
    }

    /// Wraps an already computed values.
    ///
    /// # Safety
    ///
    /// The index must be less than `L::LENGTH`.
    pub const unsafe fn new_unchecked(index: usize) -> Self {
        Self {
            index,
            _phantom: PhantomData,
        }
    }

    /// Returns the linearized value.
    ///
    /// This function returns the output of [linearize](Linearize::linearize) that was
    /// computed when this object was created.
    ///
    /// # Example
    ///
    /// ```rust
    /// # use linearize::{Linearize, LinearizeExt};
    /// fn get<L: Linearize>(key: L) {
    ///     assert_eq!(key.linearized().get(), key.linearize());
    /// }
    /// ```
    pub fn get(self) -> usize {
        self.index
    }

    /// Returns the value that was used to create this object.
    ///
    /// This function returns the output of
    /// [from_linear_unchecked](Linearize::from_linear_unchecked). This value is required
    /// to be the same that was used to create this object.
    ///
    /// # Example
    ///
    /// ```rust
    /// # use std::fmt::Debug;
    /// # use linearize::{Linearize, LinearizeExt};
    /// fn get<L: Linearize + Eq + Debug>(key: L) {
    ///     assert_eq!(key.linearized().delinearize(), key);
    /// }
    /// ```
    pub fn delinearize(self) -> L
    where
        L: Linearize + Sized,
    {
        unsafe {
            // SAFETY: self.index is only written by Self::new_unchecked which requires
            // that it is less than L::LENGTH.
            L::from_linear_unchecked(self.index)
        }
    }
}

impl<L> Copy for Linearized<L> where L: ?Sized {}

impl<L> Clone for Linearized<L>
where
    L: ?Sized,
{
    fn clone(&self) -> Self {
        *self
    }
}

impl<L> Debug for Linearized<L>
where
    L: ?Sized,
{
    fn fmt(&self, f: &mut Formatter<'_>) -> core::fmt::Result {
        self.index.fmt(f)
    }
}

impl<L> Hash for Linearized<L>
where
    L: ?Sized,
{
    fn hash<H: Hasher>(&self, state: &mut H) {
        self.index.hash(state)
    }
}

impl<L> PartialEq for Linearized<L>
where
    L: ?Sized,
{
    fn eq(&self, other: &Self) -> bool {
        self.index == other.index
    }
}

impl<L> PartialEq<usize> for Linearized<L>
where
    L: ?Sized,
{
    fn eq(&self, other: &usize) -> bool {
        self.index == *other
    }
}

impl<L> Eq for Linearized<L> where L: ?Sized {}

impl<L> PartialOrd for Linearized<L>
where
    L: ?Sized,
{
    fn partial_cmp(&self, other: &Self) -> Option<Ordering> {
        Some(self.cmp(other))
    }
}

impl<L> PartialOrd<usize> for Linearized<L>
where
    L: ?Sized,
{
    fn partial_cmp(&self, other: &usize) -> Option<Ordering> {
        self.index.partial_cmp(other)
    }
}

impl<L> Ord for Linearized<L>
where
    L: ?Sized,
{
    fn cmp(&self, other: &Self) -> Ordering {
        self.index.cmp(&other.index)
    }
}
