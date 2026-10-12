//! Gooarchy's session lock client. Once requested, only successful PAM may unlock it.

mod pam;
mod render;

use kbvm::{Components, GroupIndex, Keycode, ModifierMask, lookup::LookupTable, syms, xkb};
use std::collections::HashMap;
use std::fs::File;
use std::io::Read;
use std::os::fd::{AsFd, AsRawFd};
use std::sync::mpsc::{self, Receiver, Sender};
use std::thread;
use wayland_client::protocol::{
    wl_buffer, wl_compositor, wl_keyboard, wl_output, wl_registry, wl_seat, wl_shm, wl_shm_pool,
    wl_surface,
};
use wayland_client::{Connection, Dispatch, EventQueue, Proxy, QueueHandle, WEnum, delegate_noop};
use wayland_protocols::ext::session_lock::v1::client::{
    ext_session_lock_manager_v1, ext_session_lock_surface_v1, ext_session_lock_v1,
};
use zeroize::{Zeroize, Zeroizing};

struct Output {
    proxy: wl_output::WlOutput,
    surface: Option<wl_surface::WlSurface>,
    lock_surface: Option<ext_session_lock_surface_v1::ExtSessionLockSurfaceV1>,
    size: Option<(u32, u32)>,
}

struct Keyboard {
    lookup: LookupTable,
    components: Components,
    compose: Option<(xkb::compose::ComposeTable, xkb::compose::State)>,
}

enum Worker {
    Auth(bool),
    Theme(render::Palette),
}

struct State {
    registry: Option<wl_registry::WlRegistry>,
    compositor: Option<wl_compositor::WlCompositor>,
    shm: Option<wl_shm::WlShm>,
    manager: Option<ext_session_lock_manager_v1::ExtSessionLockManagerV1>,
    lock: Option<ext_session_lock_v1::ExtSessionLockV1>,
    outputs: HashMap<u32, Output>,
    seat: Option<wl_seat::WlSeat>,
    keyboard_proxy: Option<wl_keyboard::WlKeyboard>,
    keyboard: Option<Keyboard>,
    focused: bool,
    locked: bool,
    unlocking: bool,
    failed: bool,
    authenticating: bool,
    password: Zeroizing<Vec<u8>>,
    account: String,
    status: &'static str,
    palette: render::Palette,
    worker_tx: Sender<Worker>,
}

impl State {
    fn new(account: String, worker_tx: Sender<Worker>) -> Self {
        Self {
            registry: None,
            compositor: None,
            shm: None,
            manager: None,
            lock: None,
            outputs: HashMap::new(),
            seat: None,
            keyboard_proxy: None,
            keyboard: None,
            focused: false,
            locked: false,
            unlocking: false,
            failed: false,
            authenticating: false,
            password: Zeroizing::new(Vec::new()),
            account,
            status: "Enter your password",
            palette: render::Palette::default(),
            worker_tx,
        }
    }

    fn add_output(&mut self, name: u32, qh: &QueueHandle<Self>) {
        let Some(output) = self.outputs.get_mut(&name) else {
            return;
        };
        if output.surface.is_some() {
            return;
        }
        let (Some(compositor), Some(lock)) = (&self.compositor, &self.lock) else {
            return;
        };
        let surface = compositor.create_surface(qh, ());
        let lock_surface = lock.get_lock_surface(&surface, &output.proxy, qh, ());
        // Protocol forbids committing this surface before the first configure.
        output.surface = Some(surface);
        output.lock_surface = Some(lock_surface);
    }

    fn repaint(&mut self, name: u32, qh: &QueueHandle<Self>) {
        let Some(output) = self.outputs.get(&name) else {
            return;
        };
        let (Some((width, height)), Some(surface)) = (output.size, output.surface.clone()) else {
            return;
        };
        let Ok(buffer) = render::buffer(self, width, height, qh) else {
            // Existing frame remains opaque. A first-frame failure leaves compositor blank.
            if output.size.is_some() && !self.locked {
                self.failed = true;
            }
            return;
        };
        surface.attach(Some(&buffer), 0, 0);
        surface.damage(0, 0, width as i32, height as i32);
        surface.commit();
    }

    fn repaint_all(&mut self, qh: &QueueHandle<Self>) {
        let names: Vec<_> = self.outputs.keys().copied().collect();
        for name in names {
            self.repaint(name, qh);
        }
    }

    fn submit(&mut self, qh: &QueueHandle<Self>) {
        if !self.locked || self.authenticating || self.password.is_empty() {
            return;
        }
        self.authenticating = true;
        self.status = "Checking password";
        let password = std::mem::replace(&mut self.password, Zeroizing::new(Vec::new()));
        let account = self.account.clone();
        let tx = self.worker_tx.clone();
        let started = thread::Builder::new()
            .name("gooarchy-pam".into())
            .spawn(move || {
                let success = std::panic::catch_unwind(|| pam::authenticate(&account, password))
                    .unwrap_or(false);
                let _ = tx.send(Worker::Auth(success));
            });
        if started.is_err() {
            self.authenticating = false;
            self.status = "Authentication failed";
        }
        self.repaint_all(qh);
    }

    fn key(&mut self, key: u32, qh: &QueueHandle<Self>) {
        if !self.locked || !self.focused || self.authenticating {
            return;
        }
        let Some(keyboard) = self.keyboard.as_mut() else {
            return;
        };
        let outputs: Vec<_> = keyboard
            .lookup
            .lookup(
                keyboard.components.group,
                keyboard.components.mods,
                Keycode::from_evdev(key),
            )
            .into_iter()
            .collect();
        let mut changed = false;
        for output in outputs {
            let symbol = output.keysym();
            if symbol == syms::Return || symbol == syms::KP_Enter {
                self.submit(qh);
                return;
            }
            if symbol == syms::BackSpace {
                if let Ok(value) = std::str::from_utf8(&self.password) {
                    let len = value
                        .char_indices()
                        .last()
                        .map(|(offset, _)| offset)
                        .unwrap_or(0);
                    self.password[len..].zeroize();
                    self.password.truncate(len);
                    changed = true;
                }
                continue;
            }
            if symbol == syms::Escape {
                self.password.zeroize();
                changed = true;
                continue;
            }
            let mut text = None;
            if let Some((table, state)) = keyboard.compose.as_mut() {
                match table.feed(state, symbol) {
                    Some(xkb::compose::FeedResult::Pending) => continue,
                    Some(xkb::compose::FeedResult::Composed { string, .. }) => {
                        text = string.map(str::to_owned)
                    }
                    Some(xkb::compose::FeedResult::Aborted) | None => {}
                }
            }
            if text.is_none() {
                text = output.char().map(|ch| ch.to_string());
            }
            if let Some(text) = text {
                if text.chars().all(|ch| !ch.is_control())
                    && self.password.len() + text.len() <= 1024
                {
                    self.password.extend_from_slice(text.as_bytes());
                    changed = true;
                }
            }
        }
        if changed {
            self.status = "Enter your password";
            self.repaint_all(qh);
        }
    }

    fn handle_worker(&mut self, worker: Worker, qh: &QueueHandle<Self>) {
        match worker {
            Worker::Auth(success) if self.authenticating => {
                self.authenticating = false;
                if success && self.locked && !self.failed {
                    self.unlocking = true;
                    if let Some(lock) = self.lock.take() {
                        lock.unlock_and_destroy();
                    }
                } else {
                    self.status = "Authentication failed";
                    self.repaint_all(qh);
                }
            }
            Worker::Theme(palette) if self.locked && !self.unlocking => {
                self.palette = palette;
                self.repaint_all(qh);
            }
            _ => {}
        }
    }
}

impl Dispatch<wl_registry::WlRegistry, ()> for State {
    fn event(
        state: &mut Self,
        registry: &wl_registry::WlRegistry,
        event: wl_registry::Event,
        _: &(),
        _: &Connection,
        qh: &QueueHandle<Self>,
    ) {
        match event {
            wl_registry::Event::Global {
                name,
                interface,
                version,
            } => match interface.as_str() {
                "wl_compositor" => {
                    state.compositor = Some(registry.bind(name, version.min(4), qh, ()))
                }
                "wl_shm" => state.shm = Some(registry.bind(name, 1, qh, ())),
                "ext_session_lock_manager_v1" => {
                    state.manager = Some(registry.bind(name, 1, qh, ()))
                }
                "wl_seat" if state.seat.is_none() => {
                    state.seat = Some(registry.bind(name, version.min(5), qh, ()))
                }
                "wl_output" => {
                    let proxy = registry.bind(name, version.min(3), qh, ());
                    state.outputs.insert(
                        name,
                        Output {
                            proxy,
                            surface: None,
                            lock_surface: None,
                            size: None,
                        },
                    );
                    if state.lock.is_some() {
                        state.add_output(name, qh);
                    }
                }
                _ => {}
            },
            wl_registry::Event::GlobalRemove { name } => {
                if let Some(mut output) = state.outputs.remove(&name) {
                    if let Some(lock_surface) = output.lock_surface.take() {
                        lock_surface.destroy();
                    }
                    if let Some(surface) = output.surface.take() {
                        surface.destroy();
                    }
                    if output.proxy.version() >= 3 {
                        output.proxy.release();
                    }
                }
            }
            _ => {}
        }
    }
}

impl Dispatch<ext_session_lock_v1::ExtSessionLockV1, ()> for State {
    fn event(
        state: &mut Self,
        _: &ext_session_lock_v1::ExtSessionLockV1,
        event: ext_session_lock_v1::Event,
        _: &(),
        _: &Connection,
        _: &QueueHandle<Self>,
    ) {
        match event {
            ext_session_lock_v1::Event::Locked => {
                state.locked = true;
                state.status = "Enter your password";
                let tx = state.worker_tx.clone();
                let _ = thread::Builder::new()
                    .name("gooarchy-theme".into())
                    .spawn(move || {
                        if let Some(palette) = render::lookup_theme() {
                            let _ = tx.send(Worker::Theme(palette));
                        }
                    });
            }
            ext_session_lock_v1::Event::Finished => {
                // This event is a refusal or a post-unlock notification, never authentication.
                if !state.unlocking {
                    state.failed = true;
                }
            }
            _ => {}
        }
    }
}

impl Dispatch<ext_session_lock_surface_v1::ExtSessionLockSurfaceV1, ()> for State {
    fn event(
        state: &mut Self,
        surface: &ext_session_lock_surface_v1::ExtSessionLockSurfaceV1,
        event: ext_session_lock_surface_v1::Event,
        _: &(),
        _: &Connection,
        qh: &QueueHandle<Self>,
    ) {
        if let ext_session_lock_surface_v1::Event::Configure {
            serial,
            width,
            height,
        } = event
        {
            let Some(name) = state
                .outputs
                .iter()
                .find(|(_, output)| {
                    output
                        .lock_surface
                        .as_ref()
                        .is_some_and(|candidate| candidate.id() == surface.id())
                })
                .map(|(&name, _)| name)
            else {
                return;
            };
            if width == 0 || height == 0 {
                state.failed = true;
                return;
            }
            surface.ack_configure(serial);
            if let Some(output) = state.outputs.get_mut(&name) {
                output.size = Some((width, height));
            }
            state.repaint(name, qh);
        }
    }
}

impl Dispatch<wl_seat::WlSeat, ()> for State {
    fn event(
        state: &mut Self,
        seat: &wl_seat::WlSeat,
        event: wl_seat::Event,
        _: &(),
        _: &Connection,
        qh: &QueueHandle<Self>,
    ) {
        if let wl_seat::Event::Capabilities {
            capabilities: WEnum::Value(capabilities),
        } = event
        {
            if capabilities.contains(wl_seat::Capability::Keyboard) {
                if state.keyboard_proxy.is_none() {
                    state.keyboard_proxy = Some(seat.get_keyboard(qh, ()));
                }
            } else {
                if let Some(keyboard) = state.keyboard_proxy.take() {
                    if keyboard.version() >= 3 {
                        keyboard.release();
                    }
                }
                state.keyboard = None;
                state.focused = false;
            }
        }
    }
}

impl Dispatch<wl_keyboard::WlKeyboard, ()> for State {
    fn event(
        state: &mut Self,
        keyboard_proxy: &wl_keyboard::WlKeyboard,
        event: wl_keyboard::Event,
        _: &(),
        _: &Connection,
        qh: &QueueHandle<Self>,
    ) {
        if state
            .keyboard_proxy
            .as_ref()
            .is_none_or(|current| current.id() != keyboard_proxy.id())
        {
            return;
        }
        match event {
            wl_keyboard::Event::Keymap {
                format: WEnum::Value(wl_keyboard::KeymapFormat::XkbV1),
                fd,
                size,
            } => {
                if size == 0 || size > 4 * 1024 * 1024 {
                    state.keyboard = None;
                    return;
                }
                let mut bytes = Vec::new();
                let Ok(()) = File::from(fd)
                    .take(size as u64)
                    .read_to_end(&mut bytes)
                    .map(|_| ())
                else {
                    state.keyboard = None;
                    return;
                };
                if bytes.len() != size as usize {
                    state.keyboard = None;
                    return;
                }
                let context = xkb::Context::default();
                let Ok(keymap) =
                    context.keymap_from_bytes(xkb::diagnostic::WriteToLog, None, &bytes)
                else {
                    state.keyboard = None;
                    return;
                };
                let table = context
                    .compose_table_builder()
                    .build(xkb::diagnostic::WriteToLog);
                let compose = table.map(|table| {
                    let state = table.create_state();
                    (table, state)
                });
                state.keyboard = Some(Keyboard {
                    lookup: keymap.to_builder().build_lookup_table(),
                    components: Components::default(),
                    compose,
                });
            }
            wl_keyboard::Event::Keymap { .. } => state.keyboard = None,
            wl_keyboard::Event::Enter { surface, .. } => {
                state.focused = state.outputs.values().any(|output| {
                    output
                        .surface
                        .as_ref()
                        .is_some_and(|own| own.id() == surface.id())
                });
            }
            wl_keyboard::Event::Leave { .. } => state.focused = false,
            wl_keyboard::Event::Modifiers {
                mods_depressed,
                mods_latched,
                mods_locked,
                group,
                ..
            } => {
                if let Some(keyboard) = state.keyboard.as_mut() {
                    keyboard.components.mods_pressed = ModifierMask(mods_depressed);
                    keyboard.components.mods_latched = ModifierMask(mods_latched);
                    keyboard.components.mods_locked = ModifierMask(mods_locked);
                    keyboard.components.group_locked = GroupIndex(group);
                    keyboard.components.update_effective();
                }
            }
            wl_keyboard::Event::Key {
                key,
                state: WEnum::Value(wl_keyboard::KeyState::Pressed),
                ..
            } => state.key(key, qh),
            _ => {}
        }
    }
}

impl Dispatch<wl_buffer::WlBuffer, ()> for State {
    fn event(
        _: &mut Self,
        buffer: &wl_buffer::WlBuffer,
        event: wl_buffer::Event,
        _: &(),
        _: &Connection,
        _: &QueueHandle<Self>,
    ) {
        if let wl_buffer::Event::Release = event {
            buffer.destroy();
        }
    }
}

delegate_noop!(State: ignore wl_compositor::WlCompositor);
delegate_noop!(State: ignore wl_surface::WlSurface);
delegate_noop!(State: ignore wl_output::WlOutput);
delegate_noop!(State: ignore wl_shm::WlShm);
delegate_noop!(State: ignore wl_shm_pool::WlShmPool);
delegate_noop!(State: ignore ext_session_lock_manager_v1::ExtSessionLockManagerV1);

fn event_loop(
    mut queue: EventQueue<State>,
    mut state: State,
    rx: Receiver<Worker>,
) -> Result<(), String> {
    loop {
        queue
            .dispatch_pending(&mut state)
            .map_err(|e| e.to_string())?;
        if state.failed {
            return Err("compositor refused or lock failed".into());
        }
        while let Ok(worker) = rx.try_recv() {
            state.handle_worker(worker, &queue.handle());
        }
        if state.unlocking {
            // ext-session-lock requires a sync before exiting after unlock_and_destroy.
            queue.roundtrip(&mut state).map_err(|e| e.to_string())?;
            return Ok(());
        }
        queue.flush().map_err(|e| e.to_string())?;
        let Some(guard) = queue.prepare_read() else {
            continue;
        };
        let mut fd = libc::pollfd {
            fd: queue.as_fd().as_raw_fd(),
            events: libc::POLLIN,
            revents: 0,
        };
        let result = unsafe { libc::poll(&mut fd, 1, 50) };
        if result > 0 {
            guard.read().map_err(|e| e.to_string())?;
        } else if result < 0
            && std::io::Error::last_os_error().kind() != std::io::ErrorKind::Interrupted
        {
            return Err("Wayland poll failed".into());
        }
    }
}

fn run() -> Result<(), String> {
    let account = pam::account_name().ok_or("cannot identify login account")?;
    let connection = Connection::connect_to_env().map_err(|e| e.to_string())?;
    let mut queue = connection.new_event_queue();
    let (tx, rx) = mpsc::channel();
    let mut state = State::new(account, tx);
    state.registry = Some(connection.display().get_registry(&queue.handle(), ()));
    queue.roundtrip(&mut state).map_err(|e| e.to_string())?;
    let manager = state
        .manager
        .as_ref()
        .ok_or("compositor has no session-lock protocol")?;
    if state.compositor.is_none()
        || state.shm.is_none()
        || state.seat.is_none()
        || state.outputs.is_empty()
    {
        return Err("compositor is missing required lock surfaces".into());
    }
    state.lock = Some(manager.lock(&queue.handle(), ()));
    for name in state.outputs.keys().copied().collect::<Vec<_>>() {
        state.add_output(name, &queue.handle());
    }
    event_loop(queue, state, rx)
}

fn main() {
    if let Err(error) = run() {
        eprintln!("gooarchy-lock: {error}");
        std::process::exit(1);
    }
}
