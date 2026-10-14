//! This crate provides an adapter that allows you to turn any closure
//! `Fn(&mut Formatter<'_>) -> fmt::Result` into a type that implements `Display` and
//! `Debug`.
//!
//! # Example
//!
//! ```
//! use core::fmt;
//! use core::fmt::Formatter;
//! use debug_fn::debug_fn;
//!
//! fn hello(f: &mut Formatter<'_>, user_id: Option<u64>) -> fmt::Result {
//!     if let Some(user_id) = user_id {
//!         write!(f, "user number {}", user_id)
//!     } else {
//!         write!(f, "anonymous user")
//!     }
//! }
//!
//! assert_eq!(format!("Hello {}", debug_fn(|f| hello(f, Some(1234)))), "Hello user number 1234");
//! assert_eq!(format!("Hello {}", debug_fn(|f| hello(f, None))), "Hello anonymous user");
//! ```

#![no_std]

use core::{
    fmt,
    fmt::{Debug, Display, Formatter},
};

/// A type that implements `Display` and `Debug`.
pub struct DebugFn<F>(F)
where
    F: Fn(&mut Formatter<'_>) -> fmt::Result;

/// Creates a type that implements `Display` and `Debug` from a closure.
///
/// # Example
///
/// ```
/// use core::fmt::Display;
/// use debug_fn::debug_fn;
///
/// fn format_string(s: &str) -> impl Display + use<'_> {
///     debug_fn(move |f| f.write_str(s))
/// }
/// ```
#[inline(always)]
pub fn debug_fn<F>(f: F) -> DebugFn<F>
where
    F: Fn(&mut Formatter<'_>) -> fmt::Result,
{
    DebugFn(f)
}

impl<F> Debug for DebugFn<F>
where
    F: Fn(&mut Formatter<'_>) -> fmt::Result,
{
    #[inline]
    fn fmt(&self, f: &mut Formatter<'_>) -> fmt::Result {
        self.0(f)
    }
}

impl<F> Display for DebugFn<F>
where
    F: Fn(&mut Formatter<'_>) -> fmt::Result,
{
    #[inline]
    fn fmt(&self, f: &mut Formatter<'_>) -> fmt::Result {
        self.0(f)
    }
}

#[cfg(test)]
mod tests {
    extern crate alloc;

    use {crate::debug_fn, alloc::format};

    #[test]
    fn test() {
        let res = format!("{}", debug_fn(|f| f.write_str("test")));
        assert_eq!(res, "test");

        let res = format!("{:?}", debug_fn(|f| f.write_str("test")));
        assert_eq!(res, "test");
    }
}
