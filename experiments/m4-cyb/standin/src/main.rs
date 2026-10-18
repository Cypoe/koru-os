//! STAND-IN for `/bin/ascii-animator` (DESIGN-0001 §0.2 T-CYB, Q18).
//! It is NOT boot-animator. It plays a `.anim` asset with the plex-libs `anim.rs`
//! decoder (copied verbatim into src/anim.rs by build.sh, sha256-pinned; not committed).
//!
//! Contract exercised (the boot-animator contract from T-CYB):
//!   - prints `Detected TTY size: CxR` (TIOCGWINSZ on fd 1, else $COLUMNS/$LINES, else 80x24);
//!   - stats and reads the asset from the filesystem (`/assets/80x24.anim` by default);
//!   - presents frames with ANSI cursor-home at the asset fps, looping;
//!   - on SIGUSR1: writes `ESC[2J ESC[1;1H` and exits 0.
//! Every frame is followed by a `STAND-IN frame i/N` trailer line so the log can be checked.

mod anim;

use std::io::Write;
use std::sync::atomic::{AtomicBool, Ordering};
use std::time::{Duration, Instant};

static GOT_USR1: AtomicBool = AtomicBool::new(false);

#[repr(C)]
struct Winsize { ws_row: u16, ws_col: u16, ws_xpixel: u16, ws_ypixel: u16 }

extern "C" {
    fn ioctl(fd: i32, req: u64, ...) -> i32;
    fn signal(sig: i32, handler: extern "C" fn(i32)) -> usize;
    fn __errno_location() -> *mut i32;
}
const TIOCGWINSZ: u64 = 0x5413;
const SIGUSR1: i32 = 10;
const SIG_ERR: usize = usize::MAX;

extern "C" fn on_usr1(_s: i32) { GOT_USR1.store(true, Ordering::SeqCst); }

fn tty_size() -> (usize, usize, String) {
    let mut ws = Winsize { ws_row: 0, ws_col: 0, ws_xpixel: 0, ws_ypixel: 0 };
    let r = unsafe { ioctl(1, TIOCGWINSZ, &mut ws as *mut Winsize) };
    if r == 0 && ws.ws_col > 0 && ws.ws_row > 0 {
        return (ws.ws_col as usize, ws.ws_row as usize, "TIOCGWINSZ".into());
    }
    let why = if r == 0 { "TIOCGWINSZ returned 0x0".to_string() }
              else { format!("TIOCGWINSZ failed errno={}", unsafe { *__errno_location() }) };
    let env = |k: &str| std::env::var(k).ok().and_then(|v| v.parse::<usize>().ok()).filter(|v| *v > 0);
    if let (Some(c), Some(l)) = (env("COLUMNS"), env("LINES")) {
        return (c, l, format!("$COLUMNS/$LINES; {}", why));
    }
    (80, 24, format!("default; {}", why))
}

fn main() {
    let path = std::env::args().nth(1).unwrap_or_else(|| "/assets/80x24.anim".into());
    let mut out = std::io::stdout().lock();
    let _ = writeln!(out, "STAND-IN ascii-animator (plex-libs anim.rs player; not boot-animator, Q18)");
    let (cols, rows, src) = tty_size();
    let _ = writeln!(out, "Detected TTY size: {}x{} ({})", cols, rows, src);
    if unsafe { signal(SIGUSR1, on_usr1) } == SIG_ERR {
        let _ = writeln!(out, "STAND-IN ascii-animator: signal(SIGUSR1) failed");
        std::process::exit(2);
    }
    if !std::path::Path::new(&path).exists() {
        let _ = writeln!(out, "STAND-IN ascii-animator: {} does not exist", path);
        std::process::exit(3);
    }
    let raw = match std::fs::read_to_string(&path) {
        Ok(s) => s,
        Err(e) => { let _ = writeln!(out, "STAND-IN ascii-animator: read {}: {}", path, e); std::process::exit(4); }
    };
    let stream = anim::AnimStream::parse(&raw);
    let n = stream.frames.len();
    let fps = stream.target_fps.max(1);
    let _ = writeln!(out, "STAND-IN ascii-animator: {} {} bytes, {} frames, {} fps", path, raw.len(), n, fps);
    if n == 0 { std::process::exit(5); }
    let period = Duration::from_micros(1_000_000 / fps as u64);
    let t0 = Instant::now();
    let mut shown: u64 = 0;
    let mut buf = String::with_capacity(8192);
    'outer: loop {
        for f in &stream.frames {
            if GOT_USR1.load(Ordering::SeqCst) { break 'outer; }
            let due = t0 + period * shown as u32;
            let now = Instant::now();
            if due > now { std::thread::sleep(due - now); }
            buf.clear();
            buf.push_str("\x1b[H");
            for (i, l) in f.lines.iter().enumerate() {
                if i >= rows { break; }
                let clipped: String = l.chars().take(cols).collect();
                buf.push_str(&clipped);
                buf.push_str("\x1b[K\r\n");
            }
            buf.push_str(&format!("STAND-IN frame {}/{}\r\n", f.index, n));
            let _ = out.write_all(buf.as_bytes());
            let _ = out.flush();
            shown += 1;
        }
    }
    let el = t0.elapsed();
    let _ = out.write_all(b"\x1b[2J\x1b[1;1H");
    let _ = writeln!(out, "STAND-IN ascii-animator: SIGUSR1 after {} frames in {:.3} s, exit 0", shown, el.as_secs_f64());
    let _ = out.flush();
    std::process::exit(0);
}
