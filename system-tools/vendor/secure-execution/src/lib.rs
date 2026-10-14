#![no_std]

//! This crate provides a cross-platform function to determine if the running executable
//! requires secure execution.
//!
//! See the documentation of [`requires_secure_execution`] for details.

use {
    cfg_if::cfg_if,
    core::sync::atomic::{AtomicUsize, Ordering::Relaxed},
};

/// Returns whether the running executable requires secure execution.
///
/// This property is relevant for code that might be executed as part of a set-user-ID or
/// set-group-ID binary or similar.
///
/// Quoting the glibc manual pages:
///
/// > The  GNU-specific `secure_getenv()` function is just like `getenv()` except that it
/// > returns `NULL` in cases where "secure execution" is required.
/// >
/// > The `secure_getenv()` function is intended for use in general-purpose libraries to
/// > avoid vulnerabilities that could occur if set-user-ID or set-group-ID programs
/// > accidentally trusted the environment.
///
/// Quoting the OpenBSD manual pages:
///
/// > In particular, it is wise to use \[this property] to determine if a pathname
/// > returned from a `getenv()` call may safely be used to `open()` the specified file.
///
/// How this function determines this property depends on the `target_os` value.
///
/// - If `target_os` is one of `linux` or `android`, the `AT_SECURE` value from
///   `getauxval` is used. See [`getauxval(3)`] for details.
///
///   [`getauxval(3)`]: https://man7.org/linux/man-pages/man3/getauxval.3.html
///
/// - Otherwise, if `target_os` is one of `macos`, `ios`, `watchos`, `tvos`, `visionos`,
///   `dragonfly`, `freebsd`, `illumos`, `netbsd`, `openbsd`, or `solaris`, the return
///   value of `issetugid` is used.
///
///   The behavior of this function differs between operating systems, but it is always
///   defined to be used for this purpose. See for example the manual pages of [OpenBSD]
///   and [FreeBSD].
///
///   Note that, on FreeBSD and other operating systems using the same model, the return
///   value of `issetugid` can change at runtime. But this function always caches the
///   result when it is called for the first time.
///
///   [OpenBSD]: https://man.openbsd.org/issetugid.2
///   [FreeBSD]: https://man.freebsd.org/cgi/man.cgi?query=issetugid
///
/// - Otherwise, if `cfg(unix)`, this function always returns `true`. As of this
///   writing, this affects the following `target_os` values:
///
///   `aix`, `emscripten`, `espidf`, `fuchsia`, `haiku`, `horizon`, `hurd`, `l4re`, `nto`,
///   `nuttx`, `redox`, `rtems`, `vita`, and `vxworks`
///
/// - Otherwise, this function always returns `false`. As of this writing, this affects
///   the following `target_os` values:
///
///   `cuda`, `hermit`, `psp`, `solid_asp3`, `teeos`, `trusty`, `uefi`, `wasi`, `windows`,
///   `xous`, and `zkvm`
#[inline(always)]
pub fn requires_secure_execution() -> bool {
    const FALSE: usize = 0;
    const TRUE: usize = 1;
    const TODO: usize = 2;
    static STATE: AtomicUsize = AtomicUsize::new(TODO);

    match STATE.load(Relaxed) {
        FALSE => false,
        TRUE => true,
        _ => {
            let state = requires_secure_execution_uncached();
            STATE.store(state as usize, Relaxed);
            state
        }
    }
}

fn requires_secure_execution_uncached() -> bool {
    cfg_if! {
        if #[cfg(any(
            target_os = "linux",
            target_os = "android",
        ))] {
            // https://man7.org/linux/man-pages/man3/getauxval.3.html
            //     AT_SECURE
            //            Has a nonzero value if this executable should be treated
            //            securely.  Most commonly, a nonzero value indicates that
            //            the process is executing a set-user-ID or set-group-ID
            //            binary (so that its real and effective UIDs or GIDs differ
            //            from one another), or that it gained capabilities by
            //            executing a binary file that has capabilities (see
            //            capabilities(7)).  Alternatively, a nonzero value may be
            //            triggered by a Linux Security Module.  When this value is
            //            nonzero, the dynamic linker disables the use of certain
            //            environment variables (see ld-linux.so(8)) and glibc
            //            changes other aspects of its behavior.  (See also
            //            secure_getenv(3).)
            use core::ffi::c_ulong;
            #[link(name = "c")]
            unsafe extern {
                safe fn getauxval(ty: c_ulong) -> c_ulong;
            }
            const AT_SECURE: c_ulong = 23;
            getauxval(AT_SECURE) != 0
        } else if #[cfg(any(
            target_os = "macos",
            target_os = "ios",
            target_os = "watchos",
            target_os = "tvos",
            target_os = "visionos",
            target_os = "dragonfly",
            target_os = "freebsd",
            target_os = "illumos",
            target_os = "netbsd",
            target_os = "openbsd",
            target_os = "solaris",
        ))] {
            // https://developer.apple.com/library/archive/documentation/System/Conceptual/ManPages_iPhoneOS/man2/issetugid.2.html
            //     The issetugid() system call returns 1 if the process environment or memory
            //     address space is considered ``tainted'', and returns 0 otherwise.
            //
            //     A process is tainted if it was created as a result of an execve(2) system
            //     call which had either of the setuid or setgid bits set (and extra privileges
            //     were given as a result) or if it has changed any of its real,
            //     effective or saved user or group ID's since it began execution.
            //
            //     This system call exists so that library routines (eg: libc, libtermcap)
            //     can reliably determine if it is safe to use information that was obtained
            //     from the user, in particular the results from getenv(3) should be viewed
            //     with suspicion if it is used to control operation.
            //
            // The behavior on OpenBSD and some other BSDs differs since it is not affected by id
            // changes at runtime. Either way, both families define that this function should be
            // used to determine the secure-execution status.
            //
            // https://man.openbsd.org/issetugid.2
            //     The issetugid() function returns 1 if the process was made setuid or setgid as
            //     the result of the last or other previous execve() system calls. Otherwise it
            //     returns 0.
            //
            //     This system call exists so that library routines (inside libtermlib, libc, or
            //     other libraries) can guarantee safe behavior when used inside setuid or setgid
            //     programs. Some library routines may be passed insufficient information and
            //     hence not know whether the current program was started setuid or setgid because
            //     higher level calling code may have made changes to the uid, euid, gid, or egid.
            //     Hence these low-level library routines are unable to determine if they are
            //     being run with elevated or normal privileges.
            //
            //     In particular, it is wise to use this call to determine if a pathname returned
            //     from a getenv() call may safely be used to open() the specified file. Quite
            //     often this is not wise because the status of the effective uid is not known.
            //
            //     The issetugid() system call's result is unaffected by calls to setuid(),
            //     setgid(), or other such calls. In case of a fork(), the child process inherits
            //     the same status.
            //
            //     The status of issetugid() is only affected by execve(). If a child process
            //     executes a new executable file, a new issetugid status will be determined. This
            //     status is based on the existing process's uid, euid, gid, and egid permissions
            //     and on the modes of the executable file. If the new executable file modes are
            //     setuid or setgid, or if the existing process is executing the new image with
            //     uid != euid or gid != egid, the new process will be considered issetugid.
            use core::ffi::c_int;
            #[link(name = "c")]
            unsafe extern {
                safe fn issetugid() -> c_int;
            }
            issetugid() != 0
        } else if #[cfg(unix)] {
            true
        } else {
            false
        }
    }
}
