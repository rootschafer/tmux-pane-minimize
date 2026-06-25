//! tmux-pane-minimize — pure layout transform engine (Rust port of scripts/transform.sh).
//!
//! `transform()` is a referentially-transparent function of (layout, Params): no I/O, no
//! time, no randomness — the same inputs always yield the same layout string. It reproduces
//! scripts/transform.sh byte-for-byte (validated by tests/diff_test.sh) and is exercised
//! directly by the `#[cfg(test)]` oracle cases at the bottom of this file.

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

    /// The custom minimized width for a fully-minimized group (shared by the stack, stored
    /// per-pane in the MINW map). Mirrors bash `_minw_of`: searches the node's leaves and
    /// returns the first digits-only value found, else None.
    fn minw_of(&self, minw: &str) -> Option<i32> {
        match &self.node_type {
            NodeType::Leaf { pane } => {
                if pane.is_empty() {
                    None
                } else {
                    let pattern = format!(" {}:", pane);
                    if let Some(pos) = minw.find(&pattern) {
                        let start = pos + pattern.len();
                        let rest = &minw[start..];
                        let end = rest.find(' ').unwrap_or(rest.len());
                        let val_str = &rest[..end];
                        if !val_str.is_empty() && val_str.chars().all(|c| c.is_ascii_digit()) {
                            return val_str.parse::<i32>().ok();
                        }
                    }
                    None
                }
            }
            NodeType::HSplit { children } | NodeType::VSplit { children } => {
                for child in children {
                    if let Some(w) = child.minw_of(minw) {
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

    fn fixed_width(&self, minset: &str, savedw: &str, minw: &str, min_w: i32) -> i32 {
        if let NodeType::VSplit { .. } = &self.node_type {
            // The group's custom minimized width (any leaf carries it), else the global MIN_W.
            // Used both as the fully-minimized width and the narrowed-detection threshold.
            let mw = self.minw_of(minw).unwrap_or(min_w);
            if self.fully_min(minset) {
                return mw;
            }
            if self.w <= mw + 2 {
                if let Some(sw) = self.savedw_of(savedw) {
                    return sw;
                }
            }
        }
        -1
    }

    fn recompute(&mut self, x: i32, y: i32, w: i32, h: i32, ot: bool, ob: bool, ctx: &Params) {
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
                    let fw = child.fixed_width(ctx.minset, ctx.savedw, ctx.minw, ctx.min_w);
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
                    let fw = child.fixed_width(ctx.minset, ctx.savedw, ctx.minw, ctx.min_w);
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

/// Inputs to [`transform`]: the same six the bash `transform()` took (minset, savedw, minh,
/// wpane, wval) plus the four globals it read (min_h, min_w, abs_min_h, border_pos). All the
/// space-padded map strings (`minset`/`savedw`/`minh`) use the exact format the bash takes
/// (e.g. `" 1 4 "`, `" 1:80 "`); `border_pos` is one of `off`/`top`/`bottom`.
pub struct Params<'a> {
    pub minset: &'a str,
    pub savedw: &'a str,
    pub minh: &'a str,
    pub minw: &'a str,
    pub wpane: &'a str,
    pub wval: i32,
    pub min_h: i32,
    pub min_w: i32,
    pub abs_min_h: i32,
    pub border_pos: &'a str,
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

/// Transform a tmux layout string under the given [`Params`], returning the new layout
/// (`csum,geom`). Pure: mirrors bash `transform()` — strip checksum, parse the cell tree,
/// recompute geometry, re-serialize, recompute the checksum.
pub fn transform(layout: &str, p: &Params) -> String {
    let ls = match layout.find(',') {
        Some(comma_pos) => &layout[comma_pos + 1..],
        None => layout,
    };

    let mut parser = Parser::new(ls);
    let mut root = parser.parse_cell();

    root.recompute(root.x, root.y, root.w, root.h, true, true, p);

    let geom = root.serialize();
    let cs = checksum(&geom);
    format!("{},{}", cs, geom)
}

#[cfg(test)]
mod tests {
    use super::{Params, transform};

    // Drive transform() with the CLI-style positional inputs (same order as the binary).
    #[allow(clippy::too_many_arguments)]
    fn run(
        min_h: i32,
        min_w: i32,
        abs_min_h: i32,
        border_pos: &str,
        layout: &str,
        minset: &str,
        savedw: &str,
        wpane: &str,
        wval: i32,
        minh: &str,
        minw: &str,
    ) -> String {
        transform(
            layout,
            &Params { minset, savedw, minh, minw, wpane, wval, min_h, min_w, abs_min_h, border_pos },
        )
    }

    type Args = (i32, i32, i32, &'static str, &'static str, &'static str, &'static str, &'static str, i32, &'static str, &'static str);

    // Expected outputs captured from the bash oracle (scripts/transform.sh via
    // tests/transform_cli.sh) — the same reference tests/diff_test.sh diffs against. Covers
    // every engine feature plus the two fixed regressions (i32 overflow, parse trailing-comma)
    // and the custom group min-width. Regenerate after an INTENTIONAL bash change with
    // tests/gen_oracle_cases.sh.
    #[rustfmt::skip]
    const CASES: &[(Args, &'static str)] = &[
        // h-split, minimize pane 1
        ((3, 15, 1, "off", "0000,80x24,0,0{39x24,0,0,1,40x24,41,0,2}", " 1 ", " ", "", 0, " ", " "), "09fa,80x24,0,0{39x24,0,0,1,40x24,40,0,2}"),
        // v-split, minimize pane 1
        ((3, 15, 1, "off", "0000,80x24,0,0[80x12,0,0,1,80x11,0,13,2]", " 1 ", " ", "", 0, " ", " "), "ac0d,80x24,0,0[80x3,0,0,1,80x20,0,4,2]"),
        // empty minset (no-op reflow)
        ((3, 15, 1, "off", "0000,80x24,0,0{39x24,0,0,1,40x24,41,0,2}", " ", " ", "", 0, " ", " "), "09fa,80x24,0,0{39x24,0,0,1,40x24,40,0,2}"),
        // single leaf
        ((3, 15, 1, "off", "0000,80x24,0,0,1", " 1 ", " ", "", 0, " ", " "), "b25e,80x24,0,0,1"),
        // full v-stack min -> width collapse
        ((3, 30, 1, "off", "02c6,254x67,0,0{127x67,0,0,95,126x67,128,0[126x16,128,0,96,126x16,128,17,98,126x33,128,34,97]}", " 96 98 97 ", " ", "", 0, " ", " "), "b708,254x67,0,0{223x67,0,0,95,30x67,224,0[30x16,224,0,96,30x16,224,17,98,30x33,224,34,97]}"),
        // height-only nested min (96,97)
        ((3, 30, 1, "off", "02c6,254x67,0,0{127x67,0,0,95,126x67,128,0[126x16,128,0,96,126x16,128,17,98,126x33,128,34,97]}", " 96 97 ", " ", "", 0, " ", " "), "2b8c,254x67,0,0{127x67,0,0,95,126x67,128,0[126x3,128,0,96,126x59,128,4,98,126x3,128,64,97]}"),
        // per-pane custom minh 96:10
        ((3, 30, 1, "off", "02c6,254x67,0,0{127x67,0,0,95,126x67,128,0[126x16,128,0,96,126x16,128,17,98,126x33,128,34,97]}", " 96 97 ", " ", "", 0, " 96:10 ", " "), "9525,254x67,0,0{127x67,0,0,95,126x67,128,0[126x10,128,0,96,126x52,128,11,98,126x3,128,64,97]}"),
        // border-pos top edge bonus
        ((3, 15, 1, "top", "0000,80x24,0,0[80x12,0,0,1,80x11,0,13,2]", " 1 ", " ", "", 0, " ", " "), "fd0d,80x24,0,0[80x4,0,0,1,80x19,0,5,2]"),
        // border-pos bottom edge bonus
        ((3, 15, 1, "bottom", "0000,80x24,0,0[80x12,0,0,1,80x11,0,13,2]", " 2 ", " ", "", 0, " ", " "), "cba7,80x24,0,0[80x19,0,0,1,80x4,0,20,2]"),
        // peek/unminimize wval=10
        ((3, 15, 1, "off", "0000,80x24,0,0[80x12,0,0,1,80x11,0,13,2]", " 1 2 ", " 1:80 ", "1", 10, " ", " "), "e399,80x24,0,0[80x10,0,0,1,80x13,0,11,2]"),
        // restore fairness wval=20
        ((3, 15, 1, "off", "0000,100x50,0,0[100x10,0,0,0,100x9,0,11,1,100x9,0,21,2,100x9,0,31,3,100x9,0,41,4]", " 0 1 3 ", " ", "4", 20, " ", " "), "1db2,100x50,0,0[100x3,0,0,0,100x3,0,4,1,100x17,0,8,2,100x3,0,26,3,100x20,0,30,4]"),
        // peek expansion abs_min_h=2
        ((3, 15, 2, "off", "0000,100x20,0,0[100x3,0,0,0,100x3,0,4,1,100x3,0,8,2,100x1,0,12,3,100x1,0,14,4,100x3,0,16,5]", " 0 1 2 3 4 ", " ", "5", 100, " ", " "), "1e67,100x20,0,0[100x2,0,0,0,100x2,0,3,1,100x2,0,6,2,100x2,0,9,3,100x2,0,12,4,100x5,0,15,5]"),
        // savedw width restore
        ((3, 30, 1, "off", "02c6,254x67,0,0{127x67,0,0,95,126x67,128,0[126x16,128,0,96,126x16,128,17,98,126x33,128,34,97]}", " 96 98 97 ", " 96:120 ", "", 0, " ", " "), "b708,254x67,0,0{223x67,0,0,95,30x67,224,0[30x16,224,0,96,30x16,224,17,98,30x33,224,34,97]}"),
        // i32-overflow regression (vsplit)
        ((3, 15, 1, "off", "0000,60000x60000,0,0[60000x59996,0,0,1,60000x1,0,59997,2]", " ", " ", "", 0, " ", " "), "f856,60000x60000,0,0[60000x59997,0,0,1,60000x2,0,59998,2]"),
        // i32-overflow regression (hsplit)
        ((3, 15, 1, "off", "0000,60000x60000,0,0{59996x60000,0,0,1,1x60000,59997,0,2}", " ", " ", "", 0, " ", " "), "cc3e,60000x60000,0,0{59997x60000,0,0,1,2x60000,59998,0,2}"),
        // parse trailing-comma regression
        ((3, 15, 1, "off", "0000,10x10,0,0{5x10,0,0,1,5x10,6,0,2,", " ", " ", "", 0, " ", " "), "d1a0,10x10,0,0{3x10,0,0,1,4x10,4,0,2,1x10,9,0,}"),
        // all-columns-minimized (no flex)
        ((3, 15, 1, "off", "0000,80x24,0,0{40x24,0,0,1,39x24,41,0,2}", " 1 2 ", " ", "", 0, " ", " "), "020a,80x24,0,0{40x24,0,0,1,39x24,41,0,2}"),
        // tiny window degrade
        ((3, 15, 1, "off", "0000,4x4,0,0[4x2,0,0,1,4x1,0,3,2]", " 1 2 ", " ", "", 0, " ", " "), "85ef,4x4,0,0[4x2,0,0,1,4x1,0,3,2]"),
        // custom group min width 96:50
        ((3, 30, 1, "off", "02c6,254x67,0,0{127x67,0,0,95,126x67,128,0[126x16,128,0,96,126x16,128,17,98,126x33,128,34,97]}", " 96 98 97 ", " ", "", 0, " ", " 96:50 "), "9150,254x67,0,0{203x67,0,0,95,50x67,204,0[50x16,204,0,96,50x16,204,17,98,50x33,204,34,97]}"),
        // custom min width ignored if not fully-min
        ((3, 30, 1, "off", "02c6,254x67,0,0{127x67,0,0,95,126x67,128,0[126x16,128,0,96,126x16,128,17,98,126x33,128,34,97]}", " 96 ", " ", "", 0, " ", " 96:50 "), "3a09,254x67,0,0{127x67,0,0,95,126x67,128,0[126x3,128,0,96,126x20,128,4,98,126x42,128,25,97]}"),
    ];

    #[test]
    fn matches_bash_oracle() {
        for (i, (a, expected)) in CASES.iter().enumerate() {
            let got = run(a.0, a.1, a.2, a.3, a.4, a.5, a.6, a.7, a.8, a.9, a.10);
            assert_eq!(&got.as_str(), expected, "oracle case {i}: args={a:?}");
        }
    }

    #[test]
    fn checksum_is_stable_and_four_hex() {
        // The checksum is the first field; it must be 4 lowercase hex chars and deterministic.
        let out = run(3, 15, 1, "off", "0000,80x24,0,0{39x24,0,0,1,40x24,41,0,2}", " 1 ", " ", "", 0, " ", " ");
        let cs = out.split(',').next().unwrap();
        assert_eq!(cs.len(), 4);
        assert!(cs.chars().all(|c| c.is_ascii_hexdigit() && !c.is_ascii_uppercase()));
    }
}
