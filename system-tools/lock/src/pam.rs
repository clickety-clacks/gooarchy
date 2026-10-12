//! Dedicated, fail-closed password authentication. No PAM error text reaches the lock screen.

use std::ffi::{CStr, CString, c_char, c_int, c_void};
use std::fs;
use std::mem;
use std::os::unix::fs::MetadataExt;
use std::ptr;
use zeroize::Zeroizing;

const SERVICE: &str = "/etc/pam.d/gooarchy-lock";
const SERVICE_CONTENT: &[u8] = b"auth     required pam_unix.so\naccount  required pam_unix.so\n";
const PAM_SUCCESS: c_int = 0;
const PAM_CONV_ERR: c_int = 19;
const PAM_PROMPT_ECHO_OFF: c_int = 1;
const PAM_USER: c_int = 2;
const PAM_DISALLOW_NULL_AUTHTOK: c_int = 1;

#[repr(C)]
struct PamMessage {
    msg_style: c_int,
    msg: *const c_char,
}

#[repr(C)]
struct PamResponse {
    resp: *mut c_char,
    resp_retcode: c_int,
}

#[repr(C)]
struct PamConv {
    conv: unsafe extern "C" fn(
        c_int,
        *const *const PamMessage,
        *mut *mut PamResponse,
        *mut c_void,
    ) -> c_int,
    appdata_ptr: *mut c_void,
}

#[repr(C)]
struct PamHandle {
    _private: [u8; 0],
}

#[link(name = "pam")]
unsafe extern "C" {
    fn pam_start(
        service_name: *const c_char,
        user: *const c_char,
        pam_conv: *const PamConv,
        pamh: *mut *mut PamHandle,
    ) -> c_int;
    fn pam_authenticate(pamh: *mut PamHandle, flags: c_int) -> c_int;
    fn pam_acct_mgmt(pamh: *mut PamHandle, flags: c_int) -> c_int;
    fn pam_get_item(pamh: *const PamHandle, item_type: c_int, item: *mut *const c_void) -> c_int;
    fn pam_end(pamh: *mut PamHandle, pam_status: c_int) -> c_int;
}

struct Secret {
    bytes: Zeroizing<Vec<u8>>,
    prompts: usize,
}

unsafe extern "C" fn converse(
    count: c_int,
    messages: *const *const PamMessage,
    responses: *mut *mut PamResponse,
    data: *mut c_void,
) -> c_int {
    if count <= 0 || messages.is_null() || responses.is_null() || data.is_null() {
        return PAM_CONV_ERR;
    }
    let secret = unsafe { &mut *(data.cast::<Secret>()) };
    let mut prompt = None;
    for index in 0..count as usize {
        let message = unsafe { *messages.add(index) };
        if message.is_null() {
            return PAM_CONV_ERR;
        }
        if unsafe { (*message).msg_style } == PAM_PROMPT_ECHO_OFF {
            if prompt.is_some() || secret.prompts != 0 {
                return PAM_CONV_ERR;
            }
            prompt = Some(index);
        } else {
            // No informational, echo-on or further secret prompts are part of this service.
            return PAM_CONV_ERR;
        }
    }
    let Some(index) = prompt else {
        return PAM_CONV_ERR;
    };
    let response = unsafe { libc::calloc(count as usize, mem::size_of::<PamResponse>()) }
        .cast::<PamResponse>();
    if response.is_null() {
        return PAM_CONV_ERR;
    }
    let password = unsafe { libc::malloc(secret.bytes.len() + 1) }.cast::<c_char>();
    if password.is_null() {
        unsafe { libc::free(response.cast()) };
        return PAM_CONV_ERR;
    }
    unsafe {
        ptr::copy_nonoverlapping(
            secret.bytes.as_ptr(),
            password.cast::<u8>(),
            secret.bytes.len(),
        );
        *password.add(secret.bytes.len()) = 0;
        (*response.add(index)).resp = password;
        *responses = response;
    }
    secret.prompts += 1;
    PAM_SUCCESS
}

fn valid_service() -> bool {
    let Ok(metadata) = fs::symlink_metadata(SERVICE) else {
        return false;
    };
    metadata.is_file()
        && metadata.uid() == 0
        && metadata.mode() & 0o022 == 0
        && fs::read(SERVICE).is_ok_and(|contents| contents == SERVICE_CONTENT)
}

pub fn account_name() -> Option<String> {
    let uid = unsafe { libc::getuid() };
    let mut buffer = vec![0u8; 16 * 1024];
    let mut entry = unsafe { mem::zeroed::<libc::passwd>() };
    let mut result = ptr::null_mut();
    let status = unsafe {
        libc::getpwuid_r(
            uid,
            &mut entry,
            buffer.as_mut_ptr().cast(),
            buffer.len(),
            &mut result,
        )
    };
    if status != 0 || result.is_null() || entry.pw_name.is_null() {
        return None;
    }
    let name = unsafe { CStr::from_ptr(entry.pw_name) }
        .to_str()
        .ok()?
        .to_owned();
    (!name.is_empty()).then_some(name)
}

pub fn authenticate(account: &str, password: Zeroizing<Vec<u8>>) -> bool {
    if password.is_empty() || password.contains(&0) || !valid_service() {
        return false;
    }
    let Ok(account) = CString::new(account) else {
        return false;
    };
    let service = c"gooarchy-lock";
    let mut secret = Secret {
        bytes: password,
        prompts: 0,
    };
    let conversation = PamConv {
        conv: converse,
        appdata_ptr: (&mut secret as *mut Secret).cast(),
    };
    let mut handle = ptr::null_mut();
    let start = unsafe {
        pam_start(
            service.as_ptr(),
            account.as_ptr(),
            &conversation,
            &mut handle,
        )
    };
    if start != PAM_SUCCESS || handle.is_null() {
        if !handle.is_null() {
            unsafe { pam_end(handle, start) };
        }
        return false;
    }
    let mut status = unsafe { pam_authenticate(handle, PAM_DISALLOW_NULL_AUTHTOK) };
    if status == PAM_SUCCESS {
        status = unsafe { pam_acct_mgmt(handle, PAM_DISALLOW_NULL_AUTHTOK) };
    }
    let mut item = ptr::null();
    let same_user = unsafe { pam_get_item(handle, PAM_USER, &mut item) } == PAM_SUCCESS
        && !item.is_null()
        && unsafe { CStr::from_ptr(item.cast::<c_char>()) } == account.as_c_str();
    let ended = unsafe { pam_end(handle, status) } == PAM_SUCCESS;
    status == PAM_SUCCESS && same_user && secret.prompts == 1 && ended && valid_service()
}
