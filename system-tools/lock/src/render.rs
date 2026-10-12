use font8x8::{BASIC_FONTS, UnicodeFonts};
use std::fs::File;
use std::io::{self, Read, Write};
use std::os::fd::{AsFd, FromRawFd};
use std::process::{Command, Stdio};
use std::thread;
use std::time::{Duration, Instant};
use wayland_client::QueueHandle;
use wayland_client::protocol::{wl_buffer, wl_shm};

use crate::State;

#[derive(Clone, Copy)]
pub struct Palette {
    pub background: [u8; 3],
    pub foreground: [u8; 3],
    pub accent: [u8; 3],
}

impl Default for Palette {
    fn default() -> Self {
        Self {
            background: [0x0c, 0x26, 0x31],
            foreground: [0xef, 0xd1, 0xae],
            accent: [0x4f, 0x80, 0xb6],
        }
    }
}

pub fn parse_palette(contents: &str) -> Option<Palette> {
    let mut palette = Palette::default();
    let mut found = [false; 3];
    for line in contents.lines() {
        let Some((key, value)) = line.split_once('=') else {
            continue;
        };
        let field = match key.trim() {
            "background" => 0,
            "foreground" => 1,
            "accent" => 2,
            _ => continue,
        };
        let value = value.trim().trim_matches('"');
        if value.len() != 7 || !value.starts_with('#') {
            continue;
        }
        let color = [
            u8::from_str_radix(&value[1..3], 16).ok()?,
            u8::from_str_radix(&value[3..5], 16).ok()?,
            u8::from_str_radix(&value[5..7], 16).ok()?,
        ];
        match field {
            0 => palette.background = color,
            1 => palette.foreground = color,
            _ => palette.accent = color,
        }
        found[field] = true;
    }
    found.iter().all(|&value| value).then_some(palette)
}

pub fn lookup_theme() -> Option<Palette> {
    let mut child = Command::new("/usr/lib/gooarchy-flavorings/gooarchy-theme-lookup")
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .spawn()
        .ok()?;
    let deadline = Instant::now() + Duration::from_secs(5);
    loop {
        match child.try_wait() {
            Ok(Some(status)) if status.success() => break,
            Ok(Some(_)) => return None,
            Err(_) => {
                let _ = child.kill();
                let _ = child.wait();
                return None;
            }
            Ok(None) if Instant::now() < deadline => thread::sleep(Duration::from_millis(10)),
            _ => {
                let _ = child.kill();
                let _ = child.wait();
                return None;
            }
        }
    }
    let mut path = String::new();
    child
        .stdout
        .take()?
        .take(4096)
        .read_to_string(&mut path)
        .ok()?;
    let path = std::path::Path::new(path.trim());
    if !path.is_absolute() {
        return None;
    }
    let mut colors = String::new();
    File::open(path.join("colors.toml"))
        .ok()?
        .take(65536)
        .read_to_string(&mut colors)
        .ok()?;
    parse_palette(&colors)
}

fn draw_rect(
    pixels: &mut [u8],
    width: usize,
    height: usize,
    x: usize,
    y: usize,
    w: usize,
    h: usize,
    color: [u8; 3],
) {
    for row in y.min(height)..y.saturating_add(h).min(height) {
        for col in x.min(width)..x.saturating_add(w).min(width) {
            let at = (row * width + col) * 4;
            pixels[at..at + 4].copy_from_slice(&[color[2], color[1], color[0], 0xff]);
        }
    }
}

fn draw_text(
    pixels: &mut [u8],
    width: usize,
    height: usize,
    x: usize,
    y: usize,
    text: &str,
    scale: usize,
    color: [u8; 3],
) {
    for (index, ch) in text.chars().take(80).enumerate() {
        let glyph = BASIC_FONTS
            .get(ch)
            .or_else(|| BASIC_FONTS.get('?'))
            .unwrap_or([0; 8]);
        for (row, bits) in glyph.iter().enumerate() {
            for bit in 0..8 {
                if bits & (1 << bit) != 0 {
                    draw_rect(
                        pixels,
                        width,
                        height,
                        x + (index * 8 + bit) * scale,
                        y + row * scale,
                        scale,
                        scale,
                        color,
                    );
                }
            }
        }
    }
}

pub fn buffer(
    state: &State,
    width: u32,
    height: u32,
    qh: &QueueHandle<State>,
) -> io::Result<wl_buffer::WlBuffer> {
    let width = width as usize;
    let height = height as usize;
    let bytes = width
        .checked_mul(height)
        .and_then(|n| n.checked_mul(4))
        .filter(|&n| n <= 128 * 1024 * 1024 && n <= i32::MAX as usize)
        .ok_or_else(|| io::Error::new(io::ErrorKind::InvalidInput, "lock surface too large"))?;
    let mut pixels = vec![0u8; bytes];
    draw_rect(
        &mut pixels,
        width,
        height,
        0,
        0,
        width,
        height,
        state.palette.background,
    );
    let scale = if width >= 1280 { 3 } else { 2 };
    let left = width.saturating_sub(480) / 2;
    let top = height.saturating_sub(180) / 2;
    draw_text(
        &mut pixels,
        width,
        height,
        left,
        top,
        "Gooarchy",
        scale,
        state.palette.accent,
    );
    draw_text(
        &mut pixels,
        width,
        height,
        left,
        top + 46,
        &state.account,
        2,
        state.palette.foreground,
    );
    draw_rect(
        &mut pixels,
        width,
        height,
        left,
        top + 80,
        width.saturating_sub(left * 2).min(480),
        42,
        state.palette.accent,
    );
    let dots = "*".repeat(state.password.len().min(48));
    draw_text(
        &mut pixels,
        width,
        height,
        left + 12,
        top + 90,
        &dots,
        2,
        state.palette.background,
    );
    draw_text(
        &mut pixels,
        width,
        height,
        left,
        top + 138,
        state.status,
        2,
        state.palette.foreground,
    );

    let fd = unsafe { libc::memfd_create(c"gooarchy-lock-frame".as_ptr(), libc::MFD_CLOEXEC) };
    if fd < 0 {
        return Err(io::Error::last_os_error());
    }
    let mut file = unsafe { File::from_raw_fd(fd) };
    file.write_all(&pixels)?;
    let shm = state
        .shm
        .as_ref()
        .ok_or_else(|| io::Error::other("wl_shm unavailable"))?;
    let pool = shm.create_pool(file.as_fd(), bytes as i32, qh, ());
    let buffer = pool.create_buffer(
        0,
        width as i32,
        height as i32,
        (width * 4) as i32,
        wl_shm::Format::Argb8888,
        qh,
        (),
    );
    pool.destroy();
    Ok(buffer)
}
