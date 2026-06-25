use std::env;

#[derive(Clone, Debug)]
enum NodeType {
    Leaf { pane: String },
    HSplit { children: Vec<Node> },
    VSplit { children: Vec<Node> },
}

#[derive(Clone, Debug)]
struct Node {
    w: i32,
    h: i32,
    x: i32,
    y: i32,
    node_type: NodeType,
}

struct Parser<'a> {
    ls: &'a str,
    pos: usize,
}

impl<'a> Parser<'a> {
    fn new(ls: &'a str) -> Self {
        Parser { ls, pos: 0 }
    }

    fn read_int_str(&mut self) -> String {
        let start = self.pos;
        while self.pos < self.ls.len() {
            let ch = self.ls.as_bytes()[self.pos];
            if ch.is_ascii_digit() {
                self.pos += 1;
            } else {
                break;
            }
        }
        self.ls[start..self.pos].to_string()
    }

    fn parse_cell(&mut self) -> Node {

        let w_str = self.read_int_str();
        let w = w_str.parse::<i32>().unwrap_or(0);
        if self.pos < self.ls.len() {
            self.pos += 1; // skip 'x'
        }

        let h_str = self.read_int_str();
        let h = h_str.parse::<i32>().unwrap_or(0);
        if self.pos < self.ls.len() {
            self.pos += 1; // skip ','
        }

        let x_str = self.read_int_str();
        let x = x_str.parse::<i32>().unwrap_or(0);
        if self.pos < self.ls.len() {
            self.pos += 1; // skip ','
        }

        let y_str = self.read_int_str();
        let y = y_str.parse::<i32>().unwrap_or(0);

        let mut pane = String::new();
        let mut children = Vec::new();
        let mut is_split = false;
        let mut vertical = false;

        if self.pos < self.ls.len() {
            let ch = self.ls.as_bytes()[self.pos];
            if ch == b',' {
                self.pos += 1;
                pane = self.read_int_str();
            } else if ch == b'{' || ch == b'[' {
                is_split = true;
                vertical = ch == b'[';
                self.pos += 1; // skip '{' or '['
                // Mirror bash's parse_cell loop exactly: always parse a child, then look
                // at the separator and advance pos by 1 regardless. ',' continues, anything
                // else (incl. end-of-string, byte 0) breaks. parse_cell is robust to pos
                // past end (returns an empty leaf), so an unterminated trailing comma yields
                // a trailing empty leaf — same degrade-to-leaf behaviour bash has.
                loop {
                    let kid = self.parse_cell();
                    children.push(kid);
                    let sep = if self.pos < self.ls.len() {
                        self.ls.as_bytes()[self.pos]
                    } else {
                        0
                    };
                    self.pos += 1; // skip ',' or the closing bracket '}' / ']' (or past end)
                    if sep != b',' {
                        break;
                    }
                }
            }
        }

        let node_type = if is_split {
            if vertical {
                NodeType::VSplit { children }
            } else {
                NodeType::HSplit { children }
            }
        } else {
            NodeType::Leaf { pane }
        };

        Node { w, h, x, y, node_type }
    }
}

impl Node {
    fn wants_min(&self, minset: &str) -> bool {
        match &self.node_type {
            NodeType::Leaf { pane } => {
                if pane.is_empty() {
                    false
                } else {
                    minset.contains(&format!(" {} ", pane))
                }
            }
            NodeType::HSplit { children } => {
                children.iter().any(|c| c.wants_min(minset))
            }
            NodeType::VSplit { children } => {
                children.iter().all(|c| c.wants_min(minset))
            }
        }
    }

    fn fully_min(&self, minset: &str) -> bool {
        match &self.node_type {
            NodeType::Leaf { pane } => {
                if pane.is_empty() {
                    false
                } else {
                    minset.contains(&format!(" {} ", pane))
                }
            }
            NodeType::HSplit { children } | NodeType::VSplit { children } => {
                children.iter().all(|c| c.fully_min(minset))
            }
        }
    }

    fn savedw_of(&self, savedw: &str) -> Option<i32> {
        match &self.node_type {
            NodeType::Leaf { pane } => {
                if pane.is_empty() {
                    None
                } else {
                    let pattern = format!(" {}:", pane);
                    if let Some(pos) = savedw.find(&pattern) {
                        let start = pos + pattern.len();
                        let rest = &savedw[start..];
                        let end = rest.find(' ').unwrap_or(rest.len());
                        rest[..end].parse::<i32>().ok()
                    } else {
                        None
                    }
                }
            }
            NodeType::HSplit { children } | NodeType::VSplit { children } => {
                for child in children {
                    if let Some(w) = child.savedw_of(savedw) {
                        return Some(w);
                    }
                }
                None
            }
        }
    }

    fn minh_of(&self, minh: &str, global_min_h: i32) -> i32 {
        if let NodeType::Leaf { pane } = &self.node_type {
            if !pane.is_empty() {
                let pattern = format!(" {}:", pane);
                if let Some(pos) = minh.find(&pattern) {
                    let start = pos + pattern.len();
                    let rest = &minh[start..];
                    let end = rest.find(' ').unwrap_or(rest.len());
                    let val_str = &rest[..end];
                    if !val_str.is_empty() && val_str.chars().all(|c| c.is_ascii_digit()) {
                        if let Ok(val) = val_str.parse::<i32>() {
                            return val;
                        }
                    }
                }
            }
        }
        global_min_h
    }

    fn fixed_width(&self, minset: &str, savedw: &str, min_w: i32) -> i32 {
        if let NodeType::VSplit { .. } = &self.node_type {
            if self.fully_min(minset) {
                return min_w;
            }
            if self.w <= min_w + 2 {
                if let Some(sw) = self.savedw_of(savedw) {
                    return sw;
                }
            }
        }
        -1
    }

    fn recompute(&mut self, x: i32, y: i32, w: i32, h: i32, ot: bool, ob: bool, ctx: &RecomputeCtx) {
        self.x = x;
        self.y = y;
        self.w = w;
        self.h = h;

        match &mut self.node_type {
            NodeType::Leaf { .. } => {}
            NodeType::HSplit { children } => {
                let n = children.len();
                let avail = w - (n as i32 - 1);
                let mut flexsum = 0;
                let mut assigned = 0;
                let mut last_idx = None;

                for (idx, child) in children.iter().enumerate() {
                    let fw = child.fixed_width(ctx.minset, ctx.savedw, ctx.min_w);
                    if fw >= 0 {
                        assigned += fw;
                    } else {
                        flexsum += child.w;
                        last_idx = Some(idx);
                    }
                }

                let mut last_idx = last_idx;
                let allfix = last_idx.is_none();
                if allfix {
                    flexsum = 0;
                    for (idx, child) in children.iter().enumerate() {
                        flexsum += child.w;
                        last_idx = Some(idx);
                    }
                }
                let rest = if allfix {
                    avail
                } else {
                    let r = avail - assigned;
                    if r < 0 { 0 } else { r }
                };

                if flexsum <= 0 {
                    flexsum = 1;
                }

                let mut r_assigned = 0;
                let mut reconcile_items = Vec::with_capacity(n);

                for (idx, child) in children.iter().enumerate() {
                    let fw = child.fixed_width(ctx.minset, ctx.savedw, ctx.min_w);
                    let cw;
                    let fl;
                    if !allfix && fw >= 0 {
                        cw = fw;
                        fl = false;
                    } else if Some(idx) == last_idx {
                        let val = rest - r_assigned;
                        cw = if val < 1 { 1 } else { val };
                        fl = true;
                    } else {
                        // i64 intermediate: bash uses 64-bit arithmetic, so this multiply
                        // never wraps for tmux-sized dims; i32 here would silently overflow.
                        let val = (child.w as i64 * rest as i64 / flexsum as i64) as i32;
                        cw = if val < 1 { 1 } else { val };
                        r_assigned += cw;
                        fl = true;
                    }

                    reconcile_items.push(ReconcileItem {
                        sz: cw,
                        flex: fl,
                        floor: 1,
                        min: false,
                    });
                }

                reconcile(&mut reconcile_items, avail);

                let mut xx = x;
                for (idx, child) in children.iter_mut().enumerate() {
                    let sz = reconcile_items[idx].sz;
                    child.recompute(xx, y, sz, h, ot, ob, ctx);
                    xx += sz + 1;
                }
            }
            NodeType::VSplit { children } => {
                let n = children.len();
                let avail = h - (n as i32 - 1);
                
                let mut wsum = 0;
                for child in children.iter() {
                    if !child.wants_min(ctx.minset) {
                        wsum += 1;
                    }
                }
                let allmin = wsum == 0;

                let mut fixmin = 0;
                let mut fixf = 0;
                let mut rcount = 0;
                let mut rpresent = false;

                for (idx, child) in children.iter().enumerate() {
                    let first = idx == 0;
                    let lastp = idx == n - 1;
                    let mut wm = child.wants_min(ctx.minset);
                    if allmin {
                        wm = false;
                    }
                    if wm {
                        let eb = edge_bonus(true, first, lastp, ot, ob, ctx.border_pos);
                        let mh = child.minh_of(ctx.minh, ctx.min_h);
                        fixmin += mh + eb;
                        fixf += ctx.abs_min_h + eb;
                    } else if let NodeType::Leaf { pane } = &child.node_type {
                        if !ctx.wpane.is_empty() && pane == ctx.wpane && ctx.wval > 0 {
                            rpresent = true;
                        } else {
                            rcount += 1;
                        }
                    } else {
                        rcount += 1;
                    }
                }

                let mut rfix = false;
                let mut rtgt = 0;
                if rpresent {
                    rfix = true;
                    rtgt = ctx.wval;
                    if rtgt < ctx.min_h {
                        rtgt = ctx.min_h;
                    }
                    if rcount == 0 {
                        let fill = avail - fixmin;
                        if rtgt < fill {
                            rtgt = fill;
                        }
                    }
                    let mut cap = avail - fixf - rcount * ctx.min_h;
                    if cap < ctx.min_h {
                        cap = avail - fixf - rcount;
                    }
                    if rtgt > cap {
                        rtgt = cap;
                    }
                    if rtgt < 1 {
                        rtgt = 1;
                    }
                }

                let fixed = fixmin + if rfix { rtgt } else { 0 };

                let mut wsum = 0;
                let mut last_idx = None;
                for (idx, child) in children.iter().enumerate() {
                    let mut wm = child.wants_min(ctx.minset);
                    if allmin {
                        wm = false;
                    }
                    let mut isr = false;
                    if rfix {
                        if let NodeType::Leaf { pane } = &child.node_type {
                            if pane == ctx.wpane && !wm {
                                isr = true;
                            }
                        }
                    }
                    if !wm && !isr {
                        let mut weight = child.h;
                        if let NodeType::Leaf { pane } = &child.node_type {
                            if pane == ctx.wpane {
                                weight = ctx.wval;
                            }
                        }
                        wsum += weight;
                        last_idx = Some(idx);
                    }
                }

                let rest = {
                    let r = avail - fixed;
                    if r < 0 { 0 } else { r }
                };

                let wsum = if wsum <= 0 { 1 } else { wsum };

                let mut r_assigned = 0;
                let mut reconcile_items = Vec::with_capacity(n);
                let mut child_ot_ob = Vec::with_capacity(n);

                for (idx, child) in children.iter().enumerate() {
                    let mut otc = false;
                    let mut obc = false;
                    if idx == 0 { otc = ot; }
                    if idx == n - 1 { obc = ob; }
                    child_ot_ob.push((otc, obc));

                    let first = idx == 0;
                    let lastp = idx == n - 1;
                    let mut wm = child.wants_min(ctx.minset);
                    if allmin {
                        wm = false;
                    }
                    let mut isr = false;
                    if rfix {
                        if let NodeType::Leaf { pane } = &child.node_type {
                            if pane == ctx.wpane && !wm {
                                isr = true;
                            }
                        }
                    }

                    let mut flo = 1;
                    let mut mn = false;
                    let hc;
                    let fl;

                    if wm {
                        let eb = edge_bonus(true, first, lastp, ot, ob, ctx.border_pos);
                        let mh = child.minh_of(ctx.minh, ctx.min_h);
                        hc = mh + eb;
                        fl = false;
                        if rfix {
                            flo = ctx.abs_min_h + eb;
                            if flo > hc {
                                flo = hc;
                            }
                            mn = true;
                        }
                    } else if isr {
                        hc = rtgt;
                        fl = rcount == 0;
                    } else if Some(idx) == last_idx {
                        let val = rest - r_assigned;
                        hc = if val < 1 { 1 } else { val };
                        fl = true;
                        if rfix {
                            flo = ctx.min_h;
                        }
                    } else {
                        let mut weight = child.h;
                        if let NodeType::Leaf { pane } = &child.node_type {
                            if pane == ctx.wpane {
                                weight = ctx.wval;
                            }
                        }
                        // i64 intermediate: match bash's 64-bit arithmetic (see HSplit note).
                        let val = (weight as i64 * rest as i64 / wsum as i64) as i32;
                        hc = if val < 1 { 1 } else { val };
                        r_assigned += hc;
                        fl = true;
                        if rfix {
                            flo = ctx.min_h;
                        }
                    }

                    reconcile_items.push(ReconcileItem {
                        sz: hc,
                        flex: fl,
                        floor: flo,
                        min: mn,
                    });
                }

                reconcile(&mut reconcile_items, avail);

                let mut yy = y;
                for (idx, child) in children.iter_mut().enumerate() {
                    let sz = reconcile_items[idx].sz;
                    let (otc, obc) = child_ot_ob[idx];
                    child.recompute(x, yy, w, sz, otc, obc, ctx);
                    yy += sz + 1;
                }
            }
        }
    }

    fn serialize(&self) -> String {
        let mut s = format!("{}x{},{},{}", self.w, self.h, self.x, self.y);
        match &self.node_type {
            NodeType::Leaf { pane } => {
                s.push_str(&format!(",{}", pane));
            }
            NodeType::HSplit { children } => {
                let parts: Vec<String> = children.iter().map(|c| c.serialize()).collect();
                s.push_str(&format!("{{{}}}", parts.join(",")));
            }
            NodeType::VSplit { children } => {
                let parts: Vec<String> = children.iter().map(|c| c.serialize()).collect();
                s.push_str(&format!("[{}]", parts.join(",")));
            }
        }
        s
    }
}

struct RecomputeCtx<'a> {
    minset: &'a str,
    savedw: &'a str,
    minh: &'a str,
    wpane: &'a str,
    wval: i32,
    min_h: i32,
    min_w: i32,
    abs_min_h: i32,
    border_pos: &'a str,
}

struct ReconcileItem {
    sz: i32,
    flex: bool,
    floor: i32,
    min: bool,
}

fn reconcile(items: &mut [ReconcileItem], avail: i32) {
    let n = items.len();
    if n == 0 {
        return;
    }

    for item in items.iter_mut() {
        if item.sz < item.floor {
            item.sz = item.floor;
        }
    }

    let s: i32 = items.iter().map(|item| item.sz).sum();
    let mut delta = avail - s;

    if delta > 0 {
        let mut bi = -1;
        for (i, item) in items.iter().enumerate() {
            if item.flex {
                bi = i as i32;
            }
        }
        if bi < 0 {
            bi = (n - 1) as i32;
        }
        items[bi as usize].sz += delta;
    } else if delta < 0 {
        delta = -delta;
        while delta > 0 {
            let mut best = 0;
            let mut bi = -1;

            for (i, item) in items.iter().enumerate() {
                if item.min && item.sz > item.floor && item.sz > best {
                    best = item.sz;
                    bi = i as i32;
                }
            }

            if bi < 0 {
                for (i, item) in items.iter().enumerate() {
                    if item.flex && item.sz > item.floor && item.sz > best {
                        best = item.sz;
                        bi = i as i32;
                    }
                }
            }

            if bi < 0 {
                for (i, item) in items.iter().enumerate() {
                    if item.sz > item.floor && item.sz > best {
                        best = item.sz;
                        bi = i as i32;
                    }
                }
            }

            if bi < 0 {
                for (i, item) in items.iter().enumerate() {
                    if item.sz > 1 && item.sz > best {
                        best = item.sz;
                        bi = i as i32;
                    }
                }
            }

            if bi < 0 {
                break;
            }

            items[bi as usize].sz -= 1;
            delta -= 1;
        }
    }
}

fn edge_bonus(wm: bool, first: bool, last: bool, ot: bool, ob: bool, border_pos: &str) -> i32 {
    if !wm {
        return 0;
    }
    let mut ret = 0;
    if ot && first && border_pos == "top" {
        ret += 1;
    }
    if ob && last && border_pos == "bottom" {
        ret += 1;
    }
    ret
}

fn checksum(s: &str) -> String {
    let mut cs: u16 = 0;
    for ch in s.chars() {
        let code = ch as u16;
        let rotated = (cs >> 1) | ((cs & 1) << 15);
        cs = rotated.wrapping_add(code);
    }
    format!("{:04x}", cs)
}

fn main() {
    let args: Vec<String> = env::args().collect();
    if args.len() < 11 {
        eprintln!("Usage: tmux-min-transform MIN_H MIN_W ABS_MIN_H BORDER_POS LAYOUT MINSET SAVEDW WPANE WVAL MINH");
        std::process::exit(1);
    }

    let min_h: i32 = args[1].parse().unwrap_or(3);
    let min_w: i32 = args[2].parse().unwrap_or(30);
    let abs_min_h: i32 = args[3].parse().unwrap_or(1);
    let border_pos = &args[4];
    let layout = &args[5];
    let minset = &args[6];
    let savedw = &args[7];
    let wpane = &args[8];
    let wval: i32 = args[9].parse().unwrap_or(0);
    let minh = &args[10];

    let ls = if let Some(comma_pos) = layout.find(',') {
        &layout[comma_pos + 1..]
    } else {
        layout
    };

    let mut parser = Parser::new(ls);
    let mut root = parser.parse_cell();

    let ctx = RecomputeCtx {
        minset,
        savedw,
        minh,
        wpane,
        wval,
        min_h,
        min_w,
        abs_min_h,
        border_pos,
    };

    root.recompute(root.x, root.y, root.w, root.h, true, true, &ctx);

    let geom = root.serialize();
    let cs = checksum(&geom);
    println!("{},{}", cs, geom);
}
