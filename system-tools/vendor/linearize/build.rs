fn main() {
    if version_check::is_min_version("1.83.0").unwrap_or(false) {
        println!("cargo:rustc-cfg=more_const_functions");
    }
}
