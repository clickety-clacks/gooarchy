#[allow(unused_imports)]
use crate::LinearizeExt;
use {
    crate::Linearize,
    core::{marker::PhantomData, ops::Range},
};

/// An iterator over all values of `L`.
///
/// Construct it with [`L::variants`][LinearizeExt::variants].
pub struct Variants<L> {
    iter: Range<usize>,
    _phantom: PhantomData<fn() -> L>,
}

impl<L> Variants<L>
where
    L: Linearize,
{
    pub(super) fn new() -> Self {
        Self {
            iter: 0..L::LENGTH,
            _phantom: Default::default(),
        }
    }
}

impl<L> Clone for Variants<L>
where
    L: Linearize,
{
    fn clone(&self) -> Self {
        Self {
            iter: self.iter.clone(),
            _phantom: Default::default(),
        }
    }
}

impl<L> Iterator for Variants<L>
where
    L: Linearize,
{
    type Item = L;

    fn next(&mut self) -> Option<Self::Item> {
        self.iter.next().map(|v| unsafe {
            // SAFETY: self.iter only returns values in 0..L::LENGTH
            L::from_linear_unchecked(v)
        })
    }

    fn size_hint(&self) -> (usize, Option<usize>) {
        self.iter.size_hint()
    }

    fn count(self) -> usize
    where
        Self: Sized,
    {
        self.iter.count()
    }

    fn last(self) -> Option<Self::Item>
    where
        Self: Sized,
    {
        self.iter.last().map(|v| unsafe {
            // SAFETY: self.iter only returns values in 0..L::LENGTH
            L::from_linear_unchecked(v)
        })
    }

    fn nth(&mut self, n: usize) -> Option<Self::Item> {
        self.iter.nth(n).map(|v| unsafe {
            // SAFETY: self.iter only returns values in 0..L::LENGTH
            L::from_linear_unchecked(v)
        })
    }
}

impl<L> ExactSizeIterator for Variants<L> where L: Linearize {}

impl<L> DoubleEndedIterator for Variants<L>
where
    L: Linearize,
{
    fn next_back(&mut self) -> Option<Self::Item> {
        self.iter.next_back().map(|v| unsafe {
            // SAFETY: self.iter only returns values in 0..L::LENGTH
            L::from_linear_unchecked(v)
        })
    }

    fn nth_back(&mut self, n: usize) -> Option<Self::Item> {
        self.iter.nth_back(n).map(|v| unsafe {
            // SAFETY: self.iter only returns values in 0..L::LENGTH
            L::from_linear_unchecked(v)
        })
    }
}
