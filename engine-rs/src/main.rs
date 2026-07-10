// tmux-min-transform — thin CLI wrapper over the pure engine in lib.rs.
//
// Mirrors the bash transform() call signature exactly, all positional:
//   tmux-min-transform MIN_H MIN_W ABS_MIN_H BORDER_POS LAYOUT MINSET SAVEDW WPANE WVAL MINH MINW
// MINW (optional 11th arg, defaults to empty) is the per-group custom-minimized-width map.
// Prints the new layout string (csum,geom) to stdout, nothing else, exit 0.
use std::env;
use tmux_min_transform::{Params, transform};

fn main() {
    let args: Vec<String> = env::args().collect();
    // --version/-V: printed for humans and used by ensure-engine.sh as a post-download
    // smoke test (proves the fetched binary actually executes on this platform).
    if args.len() == 2 && (args[1] == "--version" || args[1] == "-V") {
        println!("tmux-min-transform {}", env!("CARGO_PKG_VERSION"));
        return;
    }
    if args.len() < 11 {
        eprintln!(
            "Usage: tmux-min-transform MIN_H MIN_W ABS_MIN_H BORDER_POS LAYOUT MINSET SAVEDW WPANE WVAL MINH [MINW]"
        );
        std::process::exit(1);
    }

    let min_h: i32 = args[1].parse().unwrap_or(3);
    let min_w: i32 = args[2].parse().unwrap_or(30);
    let abs_min_h: i32 = args[3].parse().unwrap_or(1);
    let border_pos = &args[4];
    let layout = &args[5];
    let wval: i32 = args[9].parse().unwrap_or(0);
    // MINW is optional for back-compat; default to the empty map " ".
    let minw: &str = args.get(11).map(|s| s.as_str()).unwrap_or(" ");

    let params = Params {
        minset: &args[6],
        savedw: &args[7],
        minh: &args[10],
        minw,
        wpane: &args[8],
        wval,
        min_h,
        min_w,
        abs_min_h,
        border_pos,
    };

    println!("{}", transform(layout, &params));
}
