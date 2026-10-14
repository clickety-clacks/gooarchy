# debug-fn

[![crates.io](https://img.shields.io/crates/v/debug-fn.svg)](http://crates.io/crates/debug-fn)
[![docs.rs](https://docs.rs/debug-fn/badge.svg)](http://docs.rs/debug-fn)

This crate provides an adapter that allows you to turn any closure
`Fn(&mut Formatter<'_>) -> fmt::Result` into a type that implements `Display` and
`Debug`.

## Example

```rust
use core::fmt;
use core::fmt::Formatter;
use debug_fn::debug_fn;

fn hello(f: &mut Formatter<'_>, user_id: Option<u64>) -> fmt::Result {
    if let Some(user_id) = user_id {
        write!(f, "user number {}", user_id)
    } else {
        write!(f, "anonymous user")
    }
}

assert_eq!(format!("Hello {}", debug_fn(|f| hello(f, Some(1234)))), "Hello user number 1234");
assert_eq!(format!("Hello {}", debug_fn(|f| hello(f, None))), "Hello anonymous user");
```

## License

This project is licensed under either of

- Apache License, Version 2.0
- MIT License

at your option.
