use {
    crate::{static_map, Linearize, StaticCopyMap, StaticMap},
    arbitrary_1::{size_hint, Arbitrary, MaxRecursionReached, Unstructured},
};

impl<'a, L, T> Arbitrary<'a> for StaticMap<L, T>
where
    L: Linearize,
    T: Arbitrary<'a>,
{
    fn arbitrary(u: &mut Unstructured<'a>) -> arbitrary_1::Result<Self> {
        Ok(static_map! {
            _ => T::arbitrary(u)?,
        })
    }

    fn size_hint(depth: usize) -> (usize, Option<usize>) {
        Self::try_size_hint(depth).unwrap_or_default()
    }

    fn try_size_hint(
        depth: usize,
    ) -> arbitrary_1::Result<(usize, Option<usize>), MaxRecursionReached> {
        size_hint::try_recursion_guard(depth, |depth| {
            let (lo, hi) = T::try_size_hint(depth)?;
            Ok((
                lo.saturating_mul(L::LENGTH),
                hi.and_then(|hi| hi.checked_mul(L::LENGTH)),
            ))
        })
    }
}

impl<'a, L, T> Arbitrary<'a> for StaticCopyMap<L, T>
where
    L: Linearize,
    T: Arbitrary<'a> + Copy,
{
    fn arbitrary(u: &mut Unstructured<'a>) -> arbitrary_1::Result<Self> {
        StaticMap::arbitrary(u).map(|v| v.into_copy())
    }

    fn size_hint(depth: usize) -> (usize, Option<usize>) {
        StaticMap::<L, T>::size_hint(depth)
    }

    fn try_size_hint(
        depth: usize,
    ) -> arbitrary_1::Result<(usize, Option<usize>), MaxRecursionReached> {
        StaticMap::<L, T>::try_size_hint(depth)
    }
}
