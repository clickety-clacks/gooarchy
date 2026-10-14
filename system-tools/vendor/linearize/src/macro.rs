use {
    crate::{Linearize, StaticMap},
    core::{mem::MaybeUninit, ptr},
};

#[doc(hidden)]
#[macro_export]
macro_rules! static_map_internal_wrapper {
    ($builder_name:ident, $builder_val:expr, $($tt:tt)*) => {{
        let mut $builder_name = $builder_val;
        if false {
            unsafe {
                // SAFETY: This call is guarded by `if false` and therefore unreachable.
                ::core::hint::unreachable_unchecked();
                #[deny(unfulfilled_lint_expectations)]
                #[expect(unreachable_code)]
                // SAFETY: unreachable_unchecked returns !, therefore this line is
                // unreachable.
                //
                // NOTE: This branch exists so that type inference is dominated by the
                // return value of this function. Otherwise the inference of the key
                // parameter would be dominated by the match body which is bad UX.
                $builder_name.get()
            }
        } else {
            $($tt)*
        }
    }};
}

#[doc(hidden)]
#[macro_export]
macro_rules! static_map_internal {
    ($builder_name:ident, $builder_val:expr, $i:ident, $val:ident, $get_key:expr, $set_value:expr, $($tt:tt)*) => {{
        $crate::static_map_internal_wrapper! {
            $builder_name,
            $builder_val,
            let mut $i = 0;
            let len = $builder_name.len();
            while $i < len {
                struct PleaseDoNotUseBreakWithoutLabel;
                let please_do_not_use_continue_without_label;
                let $val;
                loop {
                    please_do_not_use_continue_without_label = ();
                    let key = $get_key;
                    $val = match key {
                        $($tt)*
                    };
                    break PleaseDoNotUseBreakWithoutLabel;
                };
                let _ = please_do_not_use_continue_without_label;
                $set_value;
                $i += 1;
            }
            unsafe {
                // SAFETY:
                // - The loop { } around the $tt ensures that no control flow
                //   statement in $tt can interact with the for i loop unless it
                //   early-exits this macro entirely.
                // - Therefore, if we reach this line, the builder.set line was reached
                //   for each i in 0..builder.len() which is L::LENGTH.
                $builder_name.get()
            }
        }
    }};
}

/// Macro to create a [StaticMap](StaticMap).
///
/// # Example
///
/// ```rust
/// # use linearize::static_map;
/// let map = static_map! {
///     false => 0,
///     true => 0,
/// };
/// ```
///
/// # Variants
///
/// This macro has three variants:
///
/// 1. ```rust
///    macro_rules! static_map {
///        ($($tt:tt)*) => { /* ... */ }
///    }
///    ```
///
///    The body of the macro invocation should be the body of a match statement. It will be
///    called once for each possible variant. For example:
///
///    ```rust
///    # use linearize::{StaticMap, static_map};
///    let map: StaticMap<u8, u32> = static_map! {
///        n if n % 2 == 0 => n as u32 / 2,
///        n => 3 * n as u32 + 1,
///    };
///    ```
///
///    Disadvantages:
///    
///    - Cannot be used in constants or statics.
///    - It must be possible to move out of the values on the right-hand-side.
///      The following example does not compile:
///
///      ```rust,compile_fail
///       # use linearize::{StaticMap, static_map};
///       let on_false = "this is false".to_string();
///       let on_true = "this is true".to_string();
///       let map = static_map! {
///           false => on_false,
///           true => on_true,
///       };
///      ```
/// 2. ```rust
///    macro_rules! static_map {
///        (of type $ty:ty: $($tt:tt)*) => { /* ... */ }
///    }
///    ```
///
///    The body of the macro invocation should be the body of a match statement. It will be
///    called once for each possible variant. For example:
///
#[cfg_attr(more_const_functions, doc = "    ```rust")]
#[cfg_attr(not(more_const_functions), doc = "    ```rust,ignore")]
///    # use linearize::{StaticMap, static_map, Linearize};
///    #[derive(Linearize)]
///    #[linearize(const)]
///    enum Key {
///        False,
///        True,
///    }
///
///    const MAP: StaticMap<Key, u32> = static_map! {
///        of type Key:
///        Key::False => 0,
///        Key::True => 1,
///    };
///    assert_eq!(MAP[Key::False], 0);
///    assert_eq!(MAP[Key::True], 1);
#[doc = "    ```"]
///
///    Disadvantages:
///
///    - Requires rust 1.83 or later.
///    - The key type must be a concrete type. This variant cannot be used in code that is
///      generic over the key type.
///    - Cannot be used with keys containing any of the core types `bool`, `u8`, etc.
///    - Can only be used with keys that use the derive macro and enable the `linearize(const)`
///      feature.
///    - It must be possible to move out of the values on the right-hand-side.
///
///    Advantages:
///
///    - Can be used in constants and statics.
/// 3. ```rust
///    macro_rules! static_map {
///        (constants of type $ty:ty: $($key:expr => $val:expr),*$(,)?) => { /* ... */ }
///    }
///    ```
///
///    The body of the macro invocation should be an exhaustive map from constant keys to values.
///    For example:
///
#[cfg_attr(more_const_functions, doc = "    ```rust")]
#[cfg_attr(not(more_const_functions), doc = "    ```rust,ignore")]
///    # use linearize::{StaticMap, static_map, Linearize};
///    #[derive(Linearize)]
///    #[linearize(const)]
///    enum Key {
///        False,
///        True,
///    }
///
///    let on_false = "this is false".to_string();
///    let on_true = "this is true".to_string();
///
///    let map = static_map! {
///        constants of type Key:
///        Key::False => on_false,
///        Key::True => on_true,
///    };
///
///    assert_eq!(map[Key::False], "this is false");
///    assert_eq!(map[Key::True], "this is true");
#[doc = "    ```"]
///
///    Disadvantages:
///    
///    - Requires rust 1.83 or later.
///    - The key type must be a concrete type. This variant cannot be used in code that is
///      generic over the key type.
///    - Cannot be used with keys containing any of the core types `bool`, `u8`, etc.
///    - Can only be used with keys that use the derive macro and enable the `linearize(const)`
///      feature.
///    - The keys must be constants.
///
///    Advantages:
///
///    - Can be used in constants and statics.
///    - Each value will only be accessed once, allowing them to move out of variables.
#[macro_export]
macro_rules! static_map {
    (constants of type $ty:ty: $($key:expr => $val:expr),*$(,)?) => {
        $crate::static_map_internal_wrapper! {
            builder,
            $crate::Builder::<$ty, _>::new(),
            const {
                let mut init = [false; <$ty as $crate::Linearize>::LENGTH];
                $(
                    let i = <$ty>::__linearize_d66aa8fa_6974_4651_b2b7_75291a9e7105(&$key);
                    init[i] = true;
                )*
                let mut i = 0;
                while i < <$ty as $crate::Linearize>::LENGTH {
                    if !init[i] {
                        core::panic!("Not all keys are initialized");
                    }
                    i += 1;
                }
            }
            const fn write<T>(builder: &mut $crate::Builder<$ty, T>, i: usize, v: T) {
                unsafe {
                    // SAFETY:
                    // - StaticMap<$ty, T> is a transparent wrapper around $ty::Storage<$ty, T>.
                    // - $ty::Storage<$ty, T> is required to be [T; $ty::LENGTH].
                    // - Therefore, builder.0.as_mut_ptr() is morally a dereferencable
                    //   mut pointer to [MaybeUninit<T>; $ty::LENGTH].
                    // - i is $key.__linearize_d66aa8fa_6974_4651_b2b7_75291a9e7105().
                    // - The const block above would panic if i >= $ty::LENGTH.
                    // - Therefore i < $ty::LENGTH and the `add` is in bounds.
                    // - And the pointer is aligned an in bounds for `write`.
                    core::ptr::write(builder.0.as_mut_ptr().cast::<T>().add(i), v);
                }
            }
            $(
                let i = <$ty>::__linearize_d66aa8fa_6974_4651_b2b7_75291a9e7105(&$key);
                write(&mut builder, i, $val);
            )*
            unsafe {
                // SAFETY:
                // - The const block above proves that, init[i] == true for all
                //   i < $ty::LENGTH.
                // - Initially init[i] == false for all i.
                // - init[i] is set to true iff there is at least one $key that linearizes
                //   to i.
                // - Above we call write(linearize($key)) for each $key.
                // - The body of write initializes the i'th element of the array.
                builder.get()
            }
        }
    };
    (of type $ty:ty: $($tt:tt)*) => {
        $crate::static_map_internal! {
            builder,
            $crate::Builder::<$ty, _>::new(),
            i,
            val,
            unsafe {
                // SAFETY: i is less than builder.len() which is L::LENGTH.
                <$ty>::__from_linear_unchecked_fb2f0b31_5b5a_48b4_9264_39d0bdf94f1d(i)
            },
            {
                const fn write<T>(builder: &mut $crate::Builder<$ty, T>, i: usize, v: T) {
                    unsafe {
                        // SAFETY:
                        // - StaticMap<$ty, T> is a transparent wrapper around L::Storage<$ty, T>.
                        // - $ty::Storage<$ty, T> is required to be [T; $ty::LENGTH].
                        // - Therefore, builder.0.as_mut_ptr() is morally a dereferencable
                        //   mut pointer to [MaybeUninit<T>; $ty::LENGTH].
                        // - Therefore, since i < $ty::LENGTH, the `add` is in bounds.
                        // - And the pointer is aligned an in bounds for `write`.
                        core::ptr::write(builder.0.as_mut_ptr().cast::<T>().add(i), v);
                    }
                }
                write(&mut builder, i, val);
            },
            $($tt)*
        }
    };
    ($($tt:tt)*) => {
        $crate::static_map_internal! {
            builder,
            $crate::Builder::new(),
            i,
            val,
            unsafe {
                // SAFETY: i is less than builder.len() which is L::LENGTH.
                builder.key(i)
            },
            unsafe {
                // SAFETY: i is less than builder.len() which is L::LENGTH.
                builder.set(i, val);
            },
            $($tt)*
        }
    };
}

/// Macro to create a [StaticCopyMap](crate::StaticCopyMap).
///
/// This macro is a thin wrapper around [static_map](crate::static_map). The behavior is
/// identical except that is creates a [StaticCopyMap](crate::StaticCopyMap) instead of
/// a [StaticMap].
#[macro_export]
macro_rules! static_copy_map {
    (constants of type $ty:ty: $($key:expr => $val:expr),*$(,)?) => {
        $crate::StaticCopyMap($crate::static_map!(constants of type $ty: $($key => $val,)*).0)
    };
    (of type $ty:ty: $($tt:tt)*) => {
        $crate::StaticCopyMap($crate::static_map!(of type $ty: $($tt)*).0)
    };
    ($($tt:tt)*) => {
        $crate::StaticCopyMap::from_static_map($crate::static_map!($($tt)*))
    };
}

/// A builder for a [`StaticMap`].
///
/// This type should only be used via the [`static_map!`] macro.
pub struct Builder<L, T>(pub MaybeUninit<StaticMap<L, T>>)
where
    L: Linearize;

impl<L, T> Builder<L, T>
where
    L: Linearize,
{
    /// Creates a new builder.
    #[allow(clippy::new_without_default)]
    #[inline]
    pub const fn new() -> Self {
        Self(MaybeUninit::uninit())
    }

    /// Returns [`L::LENGTH`].
    #[allow(clippy::len_without_is_empty)]
    #[inline]
    pub const fn len(&self) -> usize {
        L::LENGTH
    }

    /// Returns [`L::from_linear_unchecked(i)`](L::from_linear_unchecked).
    ///
    /// # Safety
    ///
    /// Same as [`L::from_linear_unchecked`].
    #[inline]
    pub unsafe fn key(&self, i: usize) -> L {
        unsafe {
            // SAFETY: The requirements are forwarded to the caller.
            L::from_linear_unchecked(i)
        }
    }

    /// Sets the `i`th element of the map.
    ///
    /// # Safety
    ///
    /// `i` must be less than [`L::LENGTH`].
    #[inline]
    pub unsafe fn set(&mut self, i: usize, v: T) {
        unsafe {
            // SAFETY:
            // - StaticMap<L, T> is a transparent wrapper around L::Storage<L, T>.
            // - L::Storage<L, T> is required to be [T; L::LENGTH].
            // - Therefore, self.0.as_mut_ptr() is morally a dereferencable mut pointer to
            //   [MaybeUninit<T>; L::LENGTH].
            // - Therefore, since i < L::LENGTH, the `add` is in bounds.
            // - And the pointer is aligned an in bounds for `write`.
            ptr::write(self.0.as_mut_ptr().cast::<T>().add(i), v);
        }
    }

    /// # Safety
    ///
    /// All elements of the array must have initialized before calling this function.
    ///
    /// [`Self::set`] can be used to initialized an element.
    #[inline]
    pub const unsafe fn get(self) -> StaticMap<L, T> {
        unsafe {
            // SAFETY:
            // - StaticMap<L, T> is a transparent wrapper around L::Storage<L, T>.
            // - L::Storage<L, T> is required to be [T; L::LENGTH].
            // - Therefore, self.0 is morally [MaybeUninit<T>; L::LENGTH].
            // - self.set(i) initializes the ith element of this array.
            // - By the requirements of this function, every element of the array has been
            //   initialized.
            self.0.assume_init()
        }
    }

    /// Returns `StaticMap::<L, bool>::default()`.
    pub fn init_map(&self) -> StaticMap<L, bool> {
        StaticMap::default()
    }
}
